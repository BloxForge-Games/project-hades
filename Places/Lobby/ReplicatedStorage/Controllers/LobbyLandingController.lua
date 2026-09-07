--[[
	Module: LobbyLandingController
	Description:
	Client half of the Lobby join "landing" -- the Dungeons LandingController
	on the same structure, driven by LobbyLandingService instead of
	DungeonService:

	  1. Character loads -> controls locked, loading screen up (PreloadInterface
	     shows itself at KnitInit; only a PLACE controller ever hides it).
	  2. PreloadController preloads GameAssets (skipped in Studio -- see
	     PRELOAD_IN_STUDIO in PreloadController; the bar reads 0/0 there).
	  3. PlayerEventController calls the server's SetupCharacter; the server
	     stages the character in the landing pose over LobbySpawnPoint, then:
	       OnLandingStart  -> lock controls + drop the loading screen (the
	                          player sees themselves fall in)
	       OnLandingImpact -> (broadcast) VFX hook, not consumed here
	       OnLandingEnd    -> restore controls
	  4. Fallback: FALLBACK_SECONDS after preload completes with no cue, reveal
	     + unlock anyway so a fault never strands the player behind the loader.

	The cinematic bars slide in 0.75s after the reveal and out 1s after the
	landing ends, same timing as the Dungeons landing (CinematicInterfaceController
	is core). No relic hiding: relics are a Dungeons-place system.
]]

--[ Roblox Services ]--

local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--[ Imports ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local InterfaceScopes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.InterfaceScopes)

local LobbyLandingService

local PlayerEventController
local PreloadController
local PreloadInterface
local CinematicInterfaceController
local InterfaceManagerController

--[ Constants ]--

-- The landing pose the SERVER freezes you in. A server-played track
-- replicates its playback, but this client still has to download the
-- animation ASSET before it can render the pose; the preloader covers
-- Animations but is bypassed in Studio, so this warms the one animation
-- that matters on every character regardless.
local ANIMATIONS_FOLDER_NAME = "Animations"
local LANDING_ANIMATION_NAME = "LandingAnimation"

-- Hard ceiling on how long the loading screen may stay up after preload
-- completes without the server cue (same value as the Dungeons place).
local FALLBACK_SECONDS = 15

-- InterfaceManagerController hide source held on the HUD scope from join
-- until the landing cutscene ends, so the toolbar (and the rest of the HUD)
-- never appears and tweens away in front of the cutscene. Released together
-- with OnCinematicEnd, and by the fallback. Same as Dungeons.
local LANDING_SOURCE = "Landing"

--[ Controller ]--

local LobbyLandingController = Knit.CreateController({
	Name = "LobbyLandingController",
})

-- Cached PlayerModule:GetControls() handle (lazy). Resolved on first lock.
LobbyLandingController._playerControls = nil
-- True once the loading screen has been dismissed (server cue or fallback).
LobbyLandingController._revealed = false

--[ Private Functions ]--

function LobbyLandingController:_getPlayerControls()
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
-- default); `false` = don't touch the bars (the pre-reveal lock, where the
-- loading screen still covers everything). Same contract as Dungeons.
function LobbyLandingController:_lockControls(barsDelay: (number | boolean)?)
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

	if character then
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			-- Clear any residual MoveDirection so the character doesn't drift
			-- while the ControlScript is disabled.
			humanoid:Move(Vector3.zero, false)
		end
		-- Same flag the Dungeons landing sets; blocks dodge / abilities that
		-- read it while the character is mid-fall.
		character:SetAttribute(Attributes.CutscenePlaying, true)
	end
end

function LobbyLandingController:_unlockControls()
	local character = Players.LocalPlayer.Character

	local controls = self:_getPlayerControls()
	if controls then
		controls:Enable()
	end

	if character then
		-- Bars out + lock flag cleared a beat after touchdown, as in Dungeons.
		task.delay(1, function()
			CinematicInterfaceController.Signals.OnCinematicEnd:Fire()

			character:SetAttribute(Attributes.CutscenePlaying, false)
		end)
	end

	-- Same beat as the bars going out: the HUD comes up once, after the
	-- cutscene.
	task.delay(1, function()
		InterfaceManagerController:Show(InterfaceScopes.HUD, LANDING_SOURCE)
	end)
end

-- Dismisses the loading screen. Idempotent: safe to call from both the
-- server cue and the fallback.
function LobbyLandingController:_reveal()
	if self._revealed then
		return
	end
	self._revealed = true

	PreloadInterface:ToggleInterface(false)
end

--[ Lifecycle ]--

function LobbyLandingController:KnitInit()
	LobbyLandingService = Knit.GetService("LobbyLandingService")

	PlayerEventController = Knit.GetController("PlayerEventController")
	PreloadController = Knit.GetController("PreloadController")
	PreloadInterface = Knit.GetController("PreloadInterface")
	CinematicInterfaceController = Knit.GetController("CinematicInterfaceController")

	-- KnitInit, not KnitStart: the HUD interfaces mount during their own
	-- KnitInit and read this scope for their initial state.
	InterfaceManagerController = Knit.GetController("InterfaceManagerController")
	InterfaceManagerController:Hide(InterfaceScopes.HUD, LANDING_SOURCE)
end

function LobbyLandingController:KnitStart()
	-- First character only: respawns after the reveal keep their controls.
	-- No bars here -- the loading screen still covers the view; they come in
	-- with the reveal on OnLandingStart.
	PlayerEventController.OnCharacterLoaded:Connect(function()
		if not self._revealed then
			self:_lockControls(false)
		end
	end)

	LobbyLandingService.OnLandingStart:Connect(function()
		self:_lockControls()
		self:_reveal()
	end)

	LobbyLandingService.OnLandingEnd:Connect(function()
		self:_unlockControls()
	end)

	-- Warm the landing pose for THIS character before the server can ask
	-- for it: fetch the asset, and load a track on our own Animator so the
	-- keyframes are resident. The track is never played -- the server's
	-- own track drives the pose.
	local function warmLandingPose(character: Model)
		task.spawn(function()
			local animations = ReplicatedStorage.GameAssets:FindFirstChild(ANIMATIONS_FOLDER_NAME)
			local landing = animations and animations:FindFirstChild(LANDING_ANIMATION_NAME)
			if not landing or not landing:IsA("Animation") then
				warn(
					"[LobbyLandingController] GameAssets.Animations.LandingAnimation missing -- landing pose may pop in"
				)
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

	-- Fallback: never strand the player behind the loader.
	PreloadController.OnPreloadComplete:Connect(function()
		task.delay(FALLBACK_SECONDS, function()
			if self._revealed then
				return
			end
			self:_reveal()
			self:_unlockControls()
		end)
	end)
end

return LobbyLandingController
