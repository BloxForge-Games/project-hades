--[[
	Module: LandingController.lua
	Description:
	Client half of the join "landing" sequence. The player spawns at a hidden,
	off-map staging SpawnLocation and stays behind the loading screen while their
	character + assets load. The server (DungeonService) then teleports them to
	the dungeon start, anchors them, plays the landing animation, and drives this
	controller through three signals:

	  OnLandingStart  → lock controls + fade the loading screen out (the
	                    isometric camera is already on the player at the landing
	                    spot, so the player sees themselves land). This is the
	                    server-cued screen fade — the screen stays up until the
	                    server has staged the player, so there's no gap.
	  OnLandingImpact → (broadcast) landing-impact VFX hook. NOT consumed here —
	                    listen to DungeonService.OnLandingImpact in your own VFX
	                    controller and spawn dust / shake at the landing player.
	  OnLandingEnd    → restore controls.

	Control-lock mirrors EncounterIntroController: disable the ControlScript,
	zero residual movement, set CutscenePlaying (blocks aim / magic / abilities).
	The server also anchors the HRP for the duration, so this is belt-and-
	suspenders against stray input.

	Fallback: if the server cue never arrives (no dungeon generated, lost packet)
	the loading screen is dismissed FALLBACK_SECONDS after preload completes, so
	a player is never stranded behind it.
]]

--[ Roblox Services ]--

local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--[ Imports ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local InterfaceScopes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.InterfaceScopes)

local DungeonService
local PreloadInterface
local ScreenFadeInterfaceController
local RelicRenderController
local WeaponLoadoutController
local ToolBarController
local PreloadController
local CinematicInterfaceController
local InterfaceManagerController

--[ Constants ]--

-- The landing pose the SERVER freezes you in (DungeonService's
-- _runPlayerLanding: Play at speed 0 from frame 0, then the drop). A
-- server-played track replicates its playback, but this client still
-- has to download the animation ASSET before it can render the pose —
-- until then it shows the Humanoid's default pose, which is the flash of
-- legs before the drop. The preloader now covers Animations, but it is
-- bypassed in Studio, so this warms the one animation that matters on
-- every character regardless.
local ANIMATIONS_FOLDER_NAME = "Animations"
local LANDING_ANIMATION_NAME = "LandingAnimation"

-- Hard ceiling on how long the loading screen may stay up after preload
-- completes without a server landing cue. Generous enough to cover the dev
-- auto-gen window; only hit on a genuine fault.
local FALLBACK_SECONDS = 15

-- InterfaceManagerController hide source held on the HUD scope from join
-- until the landing cutscene ends, so the toolbar (and the rest of the HUD)
-- never appears and tweens away in front of the cutscene. Released together
-- with OnCinematicEnd, and by the fallback.
local LANDING_SOURCE = "Landing"

--[ Controller ]--

local LandingController = Knit.CreateController({
	Name = "LandingController",
})

-- Cached PlayerModule:GetControls() handle (lazy, same pattern as
-- EncounterIntroController). Resolved on first lock.
LandingController._playerControls = nil
-- True once the loading screen has been dismissed (either by the server cue or
-- the fallback). Guards the fallback from re-hiding an already-gone screen.
LandingController._revealed = false
-- True between a run-transition fade-to-black and the next landing; the
-- landing's OnLandingStart fades the screen back in.
LandingController._transitionFadeActive = false

--[ Private Functions ]--

function LandingController:_getPlayerControls()
	if self._playerControls then
		return self._playerControls
	end
	local playerScripts = Players.LocalPlayer:FindFirstChild("PlayerScripts")
	local moduleScript = playerScripts and playerScripts:FindFirstChild("PlayerModule")
	if not moduleScript then
		return nil
	end
	local ok, playerModule = pcall(require, moduleScript)
	if not ok or not playerModule then
		return nil
	end
	self._playerControls = playerModule:GetControls()
	return self._playerControls
end

-- `barsDelay` = seconds until the cinematic bars slide in (nil = the join
-- default); `false` = don't touch the bars at all (used for the run-
-- transition fade-in, where the screen goes black anyway -- the bars come
-- in on the REVEAL instead, timed to the fade-out).
function LandingController:_lockControls(barsDelay: (number | boolean)?)
	local character = Players.LocalPlayer.Character

	local controls = self:_getPlayerControls()
	if controls then
		controls:Disable()
	end

	if barsDelay ~= false then
		local delay = if typeof(barsDelay) == "number" then barsDelay else 0.75
		task.delay(delay, function()
			CinematicInterfaceController.Signals.OnCinematicStart:Fire()
		end)
	end
	-- Relics vanish for the fall (models + particles), back once the
	-- landing cutscene releases (see _unlockControls).
	if RelicRenderController then
		RelicRenderController:SetLandingHidden(true)
	end

	if character then
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			-- Clear any residual MoveDirection so the character doesn't drift
			-- while the ControlScript is disabled.
			humanoid:Move(Vector3.zero, false)
		end
		-- Blocks aim / general / magic actions via PlayerStateController.
		character:SetAttribute(Attributes.CutscenePlaying, true)
	end
end

function LandingController:_unlockControls()
	local character = Players.LocalPlayer.Character

	local controls = self:_getPlayerControls()
	if controls then
		controls:Enable()
	end

	if character then
		task.delay(1, function()
			CinematicInterfaceController.Signals.OnCinematicEnd:Fire()

			character:SetAttribute(Attributes.CutscenePlaying, false)
			if RelicRenderController then
				RelicRenderController:SetLandingHidden(false)
			end
		end)
	end

	-- Same beat as the bars going out: the HUD comes up once, after the
	-- cutscene. No-op on run-transition landings (the source isn't held).
	task.delay(1, function()
		InterfaceManagerController:Show(InterfaceScopes.HUD, LANDING_SOURCE)
	end)
end

-- Dismisses the loading screen. Idempotent — safe to call from both the server
-- cue and the fallback.
function LandingController:_reveal()
	if self._revealed then
		return
	end
	self._revealed = true
	if PreloadInterface then
		PreloadInterface:ToggleInterface(false)
	end
end

--[ Lifecycle ]--

function LandingController:KnitInit()
	DungeonService = Knit.GetService("DungeonService")

	-- KnitInit, not KnitStart: the HUD interfaces mount during their own
	-- KnitInit and read this scope for their initial state.
	InterfaceManagerController = Knit.GetController("InterfaceManagerController")
	InterfaceManagerController:Hide(InterfaceScopes.HUD, LANDING_SOURCE)
end

function LandingController:KnitStart()
	PreloadInterface = Knit.GetController("PreloadInterface")
	PreloadController = Knit.GetController("PreloadController")
	CinematicInterfaceController = Knit.GetController("CinematicInterfaceController")
	ScreenFadeInterfaceController = Knit.GetController("ScreenFadeInterfaceController")
	RelicRenderController = Knit.GetController("RelicRenderController")
	WeaponLoadoutController = Knit.GetController("WeaponLoadoutController")
	ToolBarController = Knit.GetController("ToolBarController")

	DungeonService.OnLandingStart:Connect(function()
		if self._transitionFadeActive then
			-- Dungeon 2 / 3: the screen is black from the run transition; the
			-- landing brings it back, and the bars slide in AS that fade ends
			-- (delay = the fade-out duration) rather than under the black.
			self._transitionFadeActive = false
			local fadeDuration = ScreenFadeInterfaceController.DEFAULT_FADE_DURATION
			self:_lockControls(fadeDuration)
			ScreenFadeInterfaceController.Signals.FadeOut:Fire(fadeDuration)
		else
			self:_lockControls()
		end
		self:_reveal()
	end)

	-- Run loop: the vote passed. Lock controls + bars and fade to black; the
	-- map is torn down and rebuilt behind it, then OnLandingStart lands us
	-- and fades back in. Dead / extracted players don't land, so their fade
	-- is released on the "out" phase the server sends after generation.
	DungeonService.OnRunTransition:Connect(function(payload)
		if typeof(payload) ~= "table" then
			return
		end
		if payload.phase == "in" then
			self._transitionFadeActive = true
			-- Lock + relic hide only; NO bars here (they'd animate under the
			-- black and be sitting there at the reveal).
			self:_lockControls(false)
			ScreenFadeInterfaceController.Signals.FadeIn:Fire(payload.duration)
			-- Once fully black: swap to the PRIMARY weapon (same as pressing 1)
			-- so everyone lands in the next dungeon sword-out, unseen.
			task.delay(payload.duration or 0, function()
				local character = Players.LocalPlayer.Character
				local humanoid = character and character:FindFirstChildOfClass("Humanoid")
				if not humanoid or humanoid.Health <= 0 then
					return
				end
				if WeaponLoadoutController and ToolBarController then
					WeaponLoadoutController.Signals.OnEquipSecondaryWeapon:Fire(false)
					WeaponLoadoutController.Signals.OnEquipPrimaryWeapon:Fire(true)
					ToolBarController.Signals.OnToolActivated:Fire(1)
				end
			end)
		elseif payload.phase == "out" then
			if self._transitionFadeActive then
				self._transitionFadeActive = false
				ScreenFadeInterfaceController.Signals.FadeOut:Fire(payload.duration)
				self:_unlockControls()
			end
		end
	end)

	-- Warm the landing pose for THIS character before the server can ask
	-- for it: fetch the asset, and load a track on our own Animator so the
	-- keyframes are resident. The track is never played — the server's
	-- own track drives the pose; this only guarantees the first frame it
	-- shows is the pose, not the legs.
	local function warmLandingPose(character: Model)
		task.spawn(function()
			local animations = ReplicatedStorage.GameAssets:FindFirstChild(ANIMATIONS_FOLDER_NAME)
			local landing = animations and animations:FindFirstChild(LANDING_ANIMATION_NAME)
			if not landing or not landing:IsA("Animation") then
				warn("[LandingController] GameAssets.Animations.LandingAnimation missing — landing pose may pop in")
				return
			end
			pcall(ContentProvider.PreloadAsync, ContentProvider, { landing })

			local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 5)
			local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
			if animator and character.Parent then
				pcall(animator.LoadAnimation, animator, landing)
			end
		end)
	end
	if Players.LocalPlayer.Character then
		warmLandingPose(Players.LocalPlayer.Character)
	end
	Players.LocalPlayer.CharacterAdded:Connect(warmLandingPose)

	DungeonService.OnLandingEnd:Connect(function()
		self:_unlockControls()
	end)

	PreloadController.OnPreloadComplete:Connect(function()
		task.delay(FALLBACK_SECONDS, function()
			self:_reveal()
			-- No landing came: don't leave the HUD held down.
			InterfaceManagerController:Show(InterfaceScopes.HUD, LANDING_SOURCE)
		end)
	end)
end

return LandingController
