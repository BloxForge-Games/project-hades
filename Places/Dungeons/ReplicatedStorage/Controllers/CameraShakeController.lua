--[[
	Module: CameraShakeController.lua
	Description:
	Custom camera shake — replaces the old CameraShaker-library wrapper.
	Listens to CameraShakeService.OnShakeRequested and exposes :Shake(preset)
	for client-side callers. Presets (Small / Medium / Large) are tuned in
	Shared/Data/CameraShakeData.lua.

	Why custom, and why it's built this way:

	* ONE shake at a time. A new shake replaces the active one only when its
	  rank is >= the active rank — bigger interrupts, smaller is dropped.
	  This kills the old library's unlimited stacking (shakes layering into
	  unreadable chaos).

	* Overlay, never state. The offset is multiplied onto the camera every
	  RenderStep at Camera.Value + 1 — AFTER the IsometricCamera's own
	  write — and the IsometricCamera smooths from its INTERNAL CFrame (see
	  its _smoothedCFrame), so the shake can never leak into the camera's
	  base position. The old system fed the shaken CFrame back through the
	  isometric lerp, which ate or compounded the offset depending on frame
	  rate — the "sometimes invisible, sometimes violent" bug.

	* Platform parity. Motion is view-space POSITION (studs) plus a small
	  roll, sampled from time-based sine blends — no frame-rate or FOV
	  dependence, so PC and mobile read the same. Phases are randomized per
	  shake so repeats don't look stamped.
]]

--[ Roblox Services ]--

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

--[ Imports ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local CameraShakeData = require(ReplicatedStorage.Submodules.Core.Shared.Data.CameraShakeData)

local CameraShakeService

--[ Constants ]--

local RENDER_BIND_NAME = "CameraShakeOverlay"
-- One step after the camera pipeline so the offset lands on top of
-- whatever wrote the camera this frame.
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 1

local TAU = math.pi * 2

--[ Controller ]--

local CameraShakeController = Knit.CreateController({
	Name = "CameraShakeController",
})

-- The single active shake: { config, startClock, phaseX/Y/Roll }, or nil.
CameraShakeController._active = nil

--[ Private ]--

-- Smooth deterministic "noise": a primary sine plus a LIGHT off-harmonic
-- detail sine, normalized to [-1, 1]. Time-based, so the waveform is
-- identical at any frame rate. The detail weight is kept low (0.25) on
-- purpose — it breaks up the sine's regularity without reading as
-- high-frequency jitter; raise it for grittier, buzzier shakes.
local function sampleAxis(t: number, frequency: number, phase: number): number
	local angle = t * frequency * TAU + phase
	return (math.sin(angle) + 0.25 * math.sin(angle * 2.63 + 1.7)) / 1.25
end

--[ Public API ]--

-- Play a shake by preset name (CameraShakePresets.Small/Medium/Large).
-- Rank-gated: ignored while a HIGHER-rank shake is still playing;
-- equal-or-higher rank replaces the active shake and restarts.
function CameraShakeController:Shake(preset: string)
	local config = CameraShakeData[preset]
	if not config then
		warn(("[CameraShakeController] Unknown shake preset %q"):format(tostring(preset)))
		return
	end

	local now = os.clock()
	local active = self._active
	if active and now < active.endClock then
		if active.config.rank > config.rank then
			return
		end
		if active.config == config then
			-- Same preset re-triggered mid-play: EXTEND instead of
			-- restarting. A restart resets the fade-in envelope, so rapid
			-- re-triggers (e.g. a piercing beam damaging several enemies
			-- back-to-back) strangled the shake to near-zero amplitude
			-- until the spam stopped — it looked "delayed". Extending
			-- keeps the oscillation + envelope continuous and just pushes
			-- the end (and its fade-out) later.
			active.endClock = now + config.duration
			return
		end
	end

	self._active = {
		config = config,
		startClock = now,
		endClock = now + config.duration,
		phaseX = math.random() * TAU,
		phaseY = math.random() * TAU,
		phaseRoll = math.random() * TAU,
	}
end

--[ Private ]--

function CameraShakeController:_update()
	local active = self._active
	if not active then
		return
	end

	local now = os.clock()
	local config = active.config
	local elapsed = now - active.startClock
	if now >= active.endClock then
		self._active = nil
		return
	end

	-- Amplitude envelope: ramp in, hold, ramp out — the camera always
	-- settles cleanly instead of hard-cutting mid-oscillation. The linear
	-- ramps are smoothstepped below so the shake eases in and bleeds off
	-- with no perceptible corner at either end.
	local envelope = 1
	if config.fadeIn > 0 and elapsed < config.fadeIn then
		envelope = elapsed / config.fadeIn
	end
	local remaining = active.endClock - now
	if config.fadeOut > 0 and remaining < config.fadeOut then
		envelope = math.min(envelope, remaining / config.fadeOut)
	end
	envelope = envelope * envelope * (3 - 2 * envelope)

	-- Per-axis frequency detuning (×1.31 / ×0.87) keeps X, Y and roll out
	-- of phase so the motion reads as jitter, not a circular orbit.
	local x = sampleAxis(elapsed, config.frequency, active.phaseX) * config.magnitude * envelope
	local y = sampleAxis(elapsed, config.frequency * 1.31, active.phaseY) * config.magnitude * envelope
	local roll = sampleAxis(elapsed, config.frequency * 0.87, active.phaseRoll) * config.roll * envelope

	local camera = workspace.CurrentCamera
	camera.CFrame = camera.CFrame * CFrame.new(x, y, 0) * CFrame.Angles(0, 0, math.rad(roll))
end

--[ Lifecycle ]--

function CameraShakeController:KnitInit()
	CameraShakeService = Knit.GetService("CameraShakeService")
end

function CameraShakeController:KnitStart()
	RunService:BindToRenderStep(RENDER_BIND_NAME, RENDER_PRIORITY, function()
		self:_update()
	end)

	CameraShakeService.OnShakeRequested:Connect(function(preset: string)
		self:Shake(preset)
	end)
end

return CameraShakeController
