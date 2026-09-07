--[[
     Module: EncounterIntroController.lua
     Description:
     Client-side cinematic runner for the miniboss / final boss reveal. The
     server (EncounterService) drives the timeline by firing three signals;
     this controller translates each one into the right local UI / character /
     camera changes. All visual sub-systems already exist — this is just glue.

     Signal sequence (server-driven):
       1. EncounterIntroFade { phase = "in", duration }
          → fade screen to black (ScreenFadeInterfaceController), lock controls
       2. EncounterIntroFade { phase = "out", duration }
          → server has already teleported the player + spawned the mob;
            cinematic bars are up, fade back from black.
       3. EncounterIntroWalk { targetPosition }
          → Humanoid:MoveTo(targetPosition). The target is computed on the
            server in world space (from the teleport position) so we don't
            read the client's local HRP — that read would race the
            just-replicated teleport CFrame and could resolve to the OLD
            position, sending the player walking backward. The server's
            authoritative timer (ENCOUNTER_INTRO_WALK_UP_DURATION) determines
            when the next phase fires; the walk just needs to roughly fit
            in that window.
          (Server then fires IsometricCameraService.OnCameraTargetChanged to
           sweep the camera onto the mob — handled by IsometricCameraController.)
       4. EncounterIntroEnd
          → re-enable controls, drop CutscenePlaying, lower the cinematic bars.

     Control locking strategy:
       - PlayerModule:GetControls():Disable()  → blocks WASD + mobile thumbstick
                                                 input. Player can't walk on their
                                                 own, but Humanoid:MoveTo still
                                                 drives them since it bypasses the
                                                 ControlScript entirely.
       - Humanoid:Move(Vector3.zero)           → clears any residual MoveDirection
                                                 carried over from pre-cinematic
                                                 input (Disable() halts ControlScript
                                                 updates but doesn't zero the move
                                                 vector — without this the player
                                                 drifts through the cinematic).
       - Humanoid.AutoRotate = true            → AimController normally pins this
                                                 to false every frame so the
                                                 character can face the mouse. Once
                                                 AimController early-returns (it sees
                                                 CutscenePlaying) it stops touching
                                                 the property — but the LAST value
                                                 it wrote (false) sticks. Forcing it
                                                 back to true lets Humanoid:MoveTo
                                                 rotate the character toward the
                                                 walk target.
       - Attributes.CutscenePlaying = true     → blocks aim / general / magic
                                                 actions via PlayerStateController.

     WalkSpeed / JumpPower are intentionally left untouched: the cinematic walk
     uses Humanoid:MoveTo, which respects the player's normal WalkSpeed. Zeroing
     it would freeze them in place.

     Note: we deliberately do NOT call IsometricCameraController:Pause(). The
     server drives the camera via IsometricCameraService.OnCameraTargetChanged /
     OnCameraTargetReset (which uses the camera library's own setOriginPart),
     and pausing the camera would fight that mechanism. Q / E rotation during
     the intro is mildly janky but acceptable; can be locked via
     ContextActionService later if it becomes a polish issue.

     Why client-side walk: player Characters have network ownership on the
     client, so Humanoid:MoveTo from the server would get overridden by client
     physics. Driving the walk locally is both standard and ping-responsive;
     the server's task.wait keeps the cinematic clock authoritative.
]]

--[ Roblox Services ]--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--[ Imports ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)

local EncounterService
local ScreenFadeInterfaceController
local CinematicInterfaceController
local CutsceneController

--[ Controller ]--

local EncounterIntroController = Knit.CreateController({
	Name = "EncounterIntroController",
})

--[ Properties ]--

-- Cached PlayerModule:GetControls() handle. Resolved lazily on first lock to
-- avoid taking a require dependency on PlayerScripts at controller boot.
EncounterIntroController._playerControls = nil

--[ Private Functions ]--

function EncounterIntroController:_getHumanoid(): Humanoid?
	local character = Players.LocalPlayer.Character
	if not character then
		return nil
	end
	return character:FindFirstChildOfClass("Humanoid")
end

-- Lazy-loads PlayerModule:GetControls(). Returns nil if the module isn't ready
-- yet (e.g. cinematic fires before PlayerScripts streams in) — callers no-op.
function EncounterIntroController:_getPlayerControls()
	if self._playerControls then
		return self._playerControls
	end
	local playerScripts = Players.LocalPlayer:FindFirstChild("PlayerScripts")
	if not playerScripts then
		return nil
	end
	local playerModuleScript = playerScripts:FindFirstChild("PlayerModule")
	if not playerModuleScript then
		return nil
	end
	local ok, playerModule = pcall(require, playerModuleScript)
	if not ok or not playerModule then
		return nil
	end
	self._playerControls = playerModule:GetControls()
	return self._playerControls
end

-- Locks player input: disables the ControlScript, zeroes residual movement,
-- forces AutoRotate on (AimController leaves it false), marks the cutscene
-- attribute, raises the cinematic bars. WalkSpeed / JumpPower are left
-- untouched so the upcoming Humanoid:MoveTo walk-up can actually move the
-- character. Idempotent.
--
-- Also cancels any in-flight ability cutscene (Susanoo / Domain Expansion)
-- via CutsceneController:CancelActiveAbility, which bundles the camera-tween
-- cancel + the wind-up-animation stop into a single call. The whitelist of
-- ability animation names lives in CutsceneController as the single source
-- of truth — shared with LifeController's death sequence.
--
-- Order matters: we set CutscenePlaying=true FIRST so that when the cancelled
-- cutscene's PlayCutscene resumes and checks ownership, it sees the lock as
-- externally owned and skips its own release. CancelActiveAbility's
-- preserveLock=true is belt-and-suspenders for the case where the cutscene
-- was already mid-Play when we lock.
function EncounterIntroController:_lockControls()
	self._stageLocked = true
	local character = Players.LocalPlayer.Character
	local humanoid = self:_getHumanoid()
	if not character then
		return
	end

	local controls = self:_getPlayerControls()
	if controls then
		controls:Disable()
	end

	if humanoid then
		humanoid:Move(Vector3.zero, false)
		humanoid.AutoRotate = true
	end

	-- Claim the cutscene lock BEFORE cancelling any active ability cutscene,
	-- so PlayCutscene's externallyOwned check sees us as the owner and won't
	-- release on its way out.
	character:SetAttribute(Attributes.CutscenePlaying, true)

	if CutsceneController then
		CutsceneController:CancelActiveAbility(true)
	end

	if CinematicInterfaceController then
		CinematicInterfaceController.Signals.OnCinematicStart:Fire()
	end
end

-- Reverses _lockControls. Safe to call from any state.
function EncounterIntroController:_unlockControls()
	self._stageLocked = false
	local character = Players.LocalPlayer.Character

	local controls = self:_getPlayerControls()
	if controls then
		controls:Enable()
	end

	if character then
		character:SetAttribute(Attributes.CutscenePlaying, false)
	end

	if CinematicInterfaceController then
		CinematicInterfaceController.Signals.OnCinematicEnd:Fire()
	end
end

-- True while ANY encounter cutscene (intro / outro / boss phase
-- change) holds the control lock. EventController's dialogue teardown
-- checks this: the encounter's teleport is what CLOSES an open event
-- dialogue, and that teardown must HAND OVER the lock instead of
-- releasing it — otherwise the player roams the boss intro freely.
function EncounterIntroController:IsStageLocked(): boolean
	return self._stageLocked == true
end

-- Walks the character to an absolute world-space target.
function EncounterIntroController:_runWalkUp(targetPosition: Vector3)
	local humanoid = self:_getHumanoid()
	if not humanoid then
		return
	end
	humanoid:MoveTo(targetPosition)
end

--[ Lifecycle ]--

function EncounterIntroController:KnitInit()
	EncounterService = Knit.GetService("EncounterService")
end

function EncounterIntroController:KnitStart()
	ScreenFadeInterfaceController = Knit.GetController("ScreenFadeInterfaceController")
	CinematicInterfaceController = Knit.GetController("CinematicInterfaceController")
	CutsceneController = Knit.GetController("CutsceneController")

	EncounterService.EncounterIntroFade:Connect(function(payload: { phase: string, duration: number })
		if not payload or not ScreenFadeInterfaceController then
			return
		end
		if payload.phase == "in" then
			self:_lockControls()
			ScreenFadeInterfaceController.Signals.FadeIn:Fire(payload.duration)
		elseif payload.phase == "out" then
			ScreenFadeInterfaceController.Signals.FadeOut:Fire(payload.duration)
		end
	end)

	EncounterService.EncounterIntroWalk:Connect(function(payload: { targetPosition: Vector3 })
		if not payload or not payload.targetPosition then
			return
		end
		self:_runWalkUp(payload.targetPosition)
	end)

	EncounterService.EncounterIntroEnd:Connect(function()
		self:_unlockControls()
	end)

	-- Cinematic OUTRO (mob defeated). No screen fade — _lockControls raises
	-- the bars + locks controls + cancels in-flight dashes / ability cutscenes
	-- (identical to the intro's lock), and the server pans the camera onto the
	-- dead mob via IsometricCameraService directly. _unlockControls on
	-- EncounterOutroEnd lowers the bars + restores controls once the camera
	-- has returned to the player.
	EncounterService.EncounterOutroStart:Connect(function()
		self:_lockControls()
	end)

	EncounterService.EncounterOutroEnd:Connect(function()
		self:_unlockControls()
	end)

	-- Boss PHASE-CHANGE cutscene (mid-fight at HP thresholds). Identical
	-- client treatment to the outro: _lockControls raises the bars + locks
	-- controls + cancels in-flight dashes / ability cutscenes, and the server
	-- pans the camera onto the transforming boss via IsometricCameraService.
	-- _unlockControls on EncounterPhaseEnd restores everything.
	EncounterService.EncounterPhaseStart:Connect(function()
		self:_lockControls()
	end)

	EncounterService.EncounterPhaseEnd:Connect(function()
		self:_unlockControls()
	end)
end

return EncounterIntroController
