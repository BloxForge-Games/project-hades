--[[
     Author(s):
     Module: CutsceneController.lua
     Description:
]]

--[ Roblox Services ]--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

--[ Exports & Types & Defaults ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local MagicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.MagicData)

local IsometricCameraController
local CinematicInterfaceController
local AmbientGradientInterfaceController

local CutsceneController = Knit.CreateController({
	Name = "CutsceneController",
	Client = {},
})

--[ Constants ]--

local BOB_OFFSET_STRENGTH = 0.25
local BOB_ROLL_STRENGTH = 1.5
local BOB_SPEED = 0.5

-- A magic entry that opts in (MagicData.cutscene.enabled) without giving
-- a duration gets this.
-- How long past a magic cutscene's own length a repeat request for the
-- SAME magic is treated as the same cast (see PlayMagicCutscene).
local MAGIC_CUTSCENE_GUARD_EXTRA_SECONDS = 1

local DEFAULT_MAGIC_CUTSCENE_SECONDS = 2

-- Animation names belonging to cutscene abilities (Susanoo, Domain Expansion,
-- etc.). CancelActiveAbility stops any of these currently playing on the
-- local character's Animator so the wind-up pose doesn't continue past the
-- cutscene cancel. Whitelisted by Name so non-cutscene ability animations
-- (FireBlast, LightingShatter, idle/walk, etc.) are left alone.
--
-- Add new cutscene-ability animation names here as more land — this is the
-- ONE source of truth (LifeController + EncounterIntroController + any
-- future caller all go through CancelActiveAbility, which reads this list).
local ABILITY_CUTSCENE_ANIMATION_NAMES = {
	["SusanooArmorAnimation"] = true,
	["DomainExpansionAnimation"] = true,
}

--[ Properties ]--

CutsceneController._cutscenes = {}
CutsceneController._cinematicBobConnection = nil
CutsceneController._cinematicBobEnabled = false
CutsceneController._bobTime = 0

-- The cutscene module currently inside PlayCutscene's yield. Set just before
-- :Play() is called, cleared just after. CancelActive uses this to know which
-- cutscene to :Stop. nil when no cutscene is running.
CutsceneController._activeCutscene = nil

-- Set by CancelActive(preserveLock=true). When true, PlayCutscene's cleanup
-- skips releasing CutscenePlaying / firing OnCinematicEnd, so the entity that
-- cancelled us (e.g. EncounterIntroController) can keep the player locked
-- through the rest of its own cinematic. One-shot — cleared after each
-- PlayCutscene cleanup.
CutsceneController._suppressUnlockOnEnd = false

--[ Private Functions ]--

function CutsceneController:_startCinematicBob()
	if self._cinematicBobConnection then
		return
	end

	self._cinematicBobEnabled = true
	self._bobTime = 0

	-- RenderStepped on purpose: CameraShakeController's overlay is a
	-- RenderStepped connection made at boot, and connections fire
	-- most-recent-first, so this bob (connected now) writes BEFORE the
	-- shake multiplies on top of it. Move this to BindToRenderStep and a
	-- shake fired mid-cutscene stops showing.
	self._cinematicBobConnection = RunService.RenderStepped:Connect(function(dt)
		if not self._cinematicBobEnabled then
			return
		end

		self._bobTime += dt

		local camera = workspace.CurrentCamera
		local baseCFrame = camera.CFrame

		local t = self._bobTime * BOB_SPEED

		local offsetX = math.noise(t, 0, 0) * BOB_OFFSET_STRENGTH
		local offsetY = math.noise(0, t, 0) * BOB_OFFSET_STRENGTH
		local roll = math.noise(0, 0, t) * BOB_ROLL_STRENGTH

		local offset = CFrame.new(offsetX, offsetY, 0) * CFrame.Angles(0, 0, math.rad(roll))

		camera.CFrame = baseCFrame * offset
	end)
end

function CutsceneController:_stopCinematicBob()
	self._cinematicBobEnabled = false

	if self._cinematicBobConnection then
		self._cinematicBobConnection:Disconnect()
		self._cinematicBobConnection = nil
	end
end

--[ Public Functions ]--

function CutsceneController:Shake(strength: number, speed: number, duration: number)
	self._shakeTime = 0
	self._shakeStrength = strength
	self._shakeSpeed = speed
	self._currentShakeOffset = CFrame.new()

	local SMOOTHNESS = 15 -- higher = smoother

	local shakeConnection

	shakeConnection = RunService.RenderStepped:Connect(function(dt)
		self._shakeTime += dt

		local camera = workspace.CurrentCamera
		local baseCFrame = camera.CFrame

		local t = self._shakeTime * self._shakeSpeed

		local offsetX = math.noise(t, 1, 0) * self._shakeStrength
		local offsetY = math.noise(0, t, 1) * self._shakeStrength
		local roll = math.noise(1, 0, t) * self._shakeStrength * 2

		local targetOffset = CFrame.new(offsetX, offsetY, 0) * CFrame.Angles(0, 0, math.rad(roll))

		-- Smooth interpolation
		self._currentShakeOffset = self._currentShakeOffset:Lerp(targetOffset, dt * SMOOTHNESS)

		camera.CFrame = baseCFrame * self._currentShakeOffset
	end)

	task.delay(duration, function()
		if shakeConnection then
			shakeConnection:Disconnect()
			shakeConnection = nil
		end
	end)
end

function CutsceneController:PlayCutscene(cutsceneName: string)
	local cutscene = self._cutscenes[cutsceneName]
	if not cutscene then
		warn("[CutsceneController] Cutscene not found:", cutsceneName)
		return
	end

	local character = Players.LocalPlayer.Character
	if not character then
		return
	end

	-- If something else (e.g. EncounterIntroController) already holds the
	-- cutscene lock when we get here — possible because Susanoo / Domain
	-- Expansion launch PlayCutscene via task.defer, so the encounter
	-- cinematic can have already taken the lock by the time we run — leave
	-- the lock alone for the whole call. We won't take it on entry, we
	-- won't release it on exit. Same reasoning for OnCinematicStart /
	-- OnCinematicEnd: the owner fires the matched pair, we stay silent.
	local externallyOwned = character:GetAttribute(Attributes.CutscenePlaying) == true

	IsometricCameraController:Pause()

	if not externallyOwned then
		CinematicInterfaceController.Signals.OnCinematicStart:Fire()
		character:SetAttribute(Attributes.CutscenePlaying, true)
	end

	self:_startCinematicBob()

	-- Wall occlusion stays ON for the whole cutscene. It used to be
	-- switched off here, which is why a camera path that clipped into a
	-- wall filled the frame with stone: the fade follows the CAMERA, so it
	-- is exactly the thing a moving cutscene camera needs.

	-- Expose the active module so CancelActive can :Stop it.
	self._activeCutscene = cutscene
	cutscene:Play()
	self._activeCutscene = nil

	-- One-shot flag set by CancelActive(true) — used by an external system
	-- that wants the player to STAY locked after we exit (the encounter
	-- intro takes ownership of the lock at that point).
	local suppressUnlock = self._suppressUnlockOnEnd
	self._suppressUnlockOnEnd = false

	self:_stopCinematicBob()

	if not externallyOwned and not suppressUnlock then
		character:SetAttribute(Attributes.CutscenePlaying, false)
		CinematicInterfaceController.Signals.OnCinematicEnd:Fire()
	end

	-- SNAP back to the isometric view: the camera path ends a few studs
	-- from the character, and gliding out from there was a whip-zoom.
	IsometricCameraController:Resume(true)
end

-- A BEAT cutscene: no camera move at all. Implements the same Play / Stop
-- surface the Cutscenes modules do (Play yields for the duration, Stop
-- makes it return early), so CancelActive / CancelActiveAbility cut it
-- short exactly as they would a camera path.
local function newCinematicBeat(duration: number)
	local beat = { _cancelled = false }
	function beat:Play()
		local startedAt = os.clock()
		while not self._cancelled and os.clock() - startedAt < duration do
			task.wait()
		end
	end
	function beat:Stop()
		self._cancelled = true
	end
	return beat
end

-- The cast cutscene for a magic that opts in through MagicData.cutscene
-- ({ enabled, duration, path }) — the ONE entry point for both kinds, so
-- a caster's invulnerability window (VFXService reads the same index)
-- cannot disagree with what actually plays.
--
--   * `path` set: hand off to PlayCutscene, which plays that camera-path
--     module with its own bars, camera pause, bob and wall hide.
--   * no `path`: cinematic bars up, the CutscenePlaying lock taken, the
--     ambient vignette pulled strong, held for the duration, then all
--     three released — no camera pause, bob or wall hiding, the frame
--     stays where the player left it.
--
-- Ownership and unlock rules are PlayCutscene's, verbatim — an external
-- owner of the lock (an encounter intro) keeps it, and CancelActive(true)
-- leaves it held on exit. No-op for magic without the index.
--
-- Either branch also raises Attributes.MagicCutscenePlaying for its whole
-- length: that is what empties the world of billboards
-- (CutsceneBillboardController) and swallows damage / text indicators, and
-- it is deliberately NOT CutscenePlaying, which every other cinematic
-- takes and which dresses the screen differently.
function CutsceneController:PlayMagicCutscene(magicName: string)
	local data = MagicData[magicName]
	local config = data and data.cutscene
	if not config or config.enabled ~= true then
		return
	end

	-- ONE cutscene per cast. The caster starts this LOCALLY the moment they
	-- cast (MagicController, so the cinematic is not held for a server
	-- round trip), and the effect module asks again when the cast
	-- replicates back -- the second ask must no-op. The guard window is the
	-- cutscene's own length plus a beat, far below any cutscene magic's
	-- cooldown, so a legitimate re-cast is never swallowed.
	local now = os.clock()
	local guardUntil = self._magicCutsceneGuard and self._magicCutsceneGuard[magicName]
	local guardWindow = (
		if typeof(config.duration) == "number" then config.duration else DEFAULT_MAGIC_CUTSCENE_SECONDS
	) + MAGIC_CUTSCENE_GUARD_EXTRA_SECONDS
	if guardUntil and now < guardUntil then
		return
	end
	self._magicCutsceneGuard = self._magicCutsceneGuard or {}
	self._magicCutsceneGuard[magicName] = now + guardWindow

	local character = Players.LocalPlayer.Character
	if not character then
		return
	end

	character:SetAttribute(Attributes.MagicCutscenePlaying, true)
	if typeof(config.path) == "string" then
		-- PlayCutscene yields for the whole camera path.
		self:PlayCutscene(config.path)
		character:SetAttribute(Attributes.MagicCutscenePlaying, false)
		return
	end
	local duration = if typeof(config.duration) == "number" then config.duration else DEFAULT_MAGIC_CUTSCENE_SECONDS

	local externallyOwned = character:GetAttribute(Attributes.CutscenePlaying) == true
	if not externallyOwned then
		CinematicInterfaceController.Signals.OnCinematicStart:Fire()
		character:SetAttribute(Attributes.CutscenePlaying, true)
	end
	if AmbientGradientInterfaceController then
		AmbientGradientInterfaceController:SetStrong(true)
	end

	local beat = newCinematicBeat(duration)
	self._activeCutscene = beat
	beat:Play()
	self._activeCutscene = nil

	if AmbientGradientInterfaceController then
		AmbientGradientInterfaceController:SetStrong(false)
	end
	local suppressUnlock = self._suppressUnlockOnEnd
	self._suppressUnlockOnEnd = false
	if not externallyOwned and not suppressUnlock then
		character:SetAttribute(Attributes.CutscenePlaying, false)
		CinematicInterfaceController.Signals.OnCinematicEnd:Fire()
	end
	character:SetAttribute(Attributes.MagicCutscenePlaying, false)
end

-- Cancels whatever cutscene is currently inside PlayCutscene's yield. No-op
-- when no cutscene is active. preserveLock=true tells PlayCutscene's cleanup
-- to skip releasing CutscenePlaying / OnCinematicEnd, so the caller can keep
-- the player locked through its own cinematic. The underlying cutscene
-- module's :Stop cancels the active TweenService tween, which lets its :Play
-- loop see Enabled=false and return — at which point PlayCutscene resumes
-- and runs cleanup.
--
-- This method ONLY cancels the camera tween. To also stop the ability's
-- wind-up animation pose, call CancelActiveAbility — it bundles both
-- operations into one call for the common "kill a cutscene ability
-- cleanly" use case.
function CutsceneController:CancelActive(preserveLock: boolean?)
	local active = self._activeCutscene
	if not active then
		return
	end
	if preserveLock then
		self._suppressUnlockOnEnd = true
	end
	active:Stop(active.CutsceneHashmap)
end

-- Stops any cutscene-ability animation tracks currently playing on the
-- local character's Animator. Whitelisted by Name via
-- ABILITY_CUTSCENE_ANIMATION_NAMES so non-cutscene animations (idle, walk,
-- Fire Blast, etc.) are left alone. Idempotent — no-op when nothing
-- matches. Private; the public surface is CancelActiveAbility.
function CutsceneController:_stopAbilityCutsceneAnimations()
	local character = Players.LocalPlayer.Character
	if not character then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		return
	end
	for _, track in animator:GetPlayingAnimationTracks() do
		local animation = track.Animation
		if animation and ABILITY_CUTSCENE_ANIMATION_NAMES[animation.Name] then
			track:Stop(0)
		end
	end
end

-- One-call helper for the common "kill a cutscene ability cleanly" pattern:
-- cancel the camera cutscene AND stop the wind-up animation pose. Used by:
--   * EncounterIntroController._lockControls   (preserveLock=true; encounter
--                                               takes over the CutscenePlaying lock)
--   * LifeController death sequence            (preserveLock=false; death
--                                               cleans up everything)
--
-- Adding a new caller? Just call this — no need to maintain a local copy
-- of the animation whitelist or duplicate the Animator-iteration boilerplate.
function CutsceneController:CancelActiveAbility(preserveLock: boolean?)
	self:CancelActive(preserveLock)
	self:_stopAbilityCutsceneAnimations()
end

--[ Initializers ]--

function CutsceneController:KnitStart()
	CinematicInterfaceController = Knit.GetController("CinematicInterfaceController")
	IsometricCameraController = Knit.GetController("IsometricCameraController")
	AmbientGradientInterfaceController = Knit.GetController("AmbientGradientInterfaceController")

	for _, cutsceneModule in pairs(script.Cutscenes:GetChildren()) do
		if cutsceneModule:IsA("ModuleScript") then
			local cutscene = require(cutsceneModule)
			self._cutscenes[cutsceneModule.Name] = cutscene
		end
	end

	Players.LocalPlayer.Character:SetAttribute(Attributes.CutscenePlaying, false)
	-- The world UI comes back with it: a hard clear must not leave the
	-- screen stripped of billboards and swallowing indicators.
	Players.LocalPlayer.Character:SetAttribute(Attributes.MagicCutscenePlaying, false)
end

function CutsceneController:KnitCutsceneController() end

return CutsceneController
