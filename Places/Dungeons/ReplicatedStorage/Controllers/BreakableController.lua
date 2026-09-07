--[[
     Author(s):
     Module: BreakableController.lua
     Description: Client-side hit feedback for Breakable models.

                  Each hit:
                   1. Flashes a red Highlight on the model (instance reused
                      across hits — see Shared/Functions/Highlight/onDamageIndicator).
                   2. Plays a short shake animation by tilting the model to a
                      random angle and back. Uses Model:PivotTo via Heartbeat
                      so unwelded parts move as a unit — no welds required.

                  Both effects override gracefully if a new hit lands during
                  the previous shake: the old shake is cancelled and the new
                  one starts from the model's current visual pose so there's
                  no jump.
]]

--[ Roblox Services ]--
local Debris = game:GetService("Debris")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

--[ Exports & Types & Defaults ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local onDamageIndicator = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Highlight.onDamageIndicator)

local BreakableController = Knit.CreateController({
	Name = "BreakableController",
	Client = {},
})

--[ Imports ]--

--[ Constants ]--

local ATTACK_HIGHLIGHT_NAME = "BuildDamageIndicator"

local SHAKE_OUT_DURATION = 0.12 -- time to tilt out to the random angle
local SHAKE_BACK_DURATION = 0.18 -- time to settle back to base
local SHAKE_ANGLE_MIN = -10 -- degrees
local SHAKE_ANGLE_MAX = 10

--[ Properties ]--

-- Per-instance active shake state. Keyed by the Breakable's instance (a Model
-- OR a single BasePart) so a new hit can cancel the previous shake before
-- starting its own.
type ShakeState = {
	cancelled: boolean,
	connection: RBXScriptConnection?,
}
BreakableController._activeShakes = {} :: { [Instance]: ShakeState }

--[ Private Functions ]--

function BreakableController:_baseCFrameOf(model: Instance): CFrame
	-- Prefer the cached "rest" CFrame set by the server when the breakable
	-- was placed. Fall back to the current pivot if no attribute exists.
	local cached = model:GetAttribute(Attributes.CachedCFrame)
	if typeof(cached) == "CFrame" then
		return cached
	end
	return (model :: PVInstance):GetPivot()
end

function BreakableController:_startShake(model: PVInstance, hitCount: number)
	if hitCount == 3 then
		return
	end

	-- Cancel any in-flight shake on this model so the new one doesn't fight it.
	local previous = self._activeShakes[model]
	if previous then
		previous.cancelled = true
		if previous.connection then
			previous.connection:Disconnect()
		end
	end

	local baseCFrame = self:_baseCFrameOf(model)

	-- Start from the model's CURRENT pose (mid-shake or rest), so overriding
	-- a previous shake doesn't snap. End on a fresh random angle.
	local startCFrame = model:GetPivot()
	local angleX = math.rad(math.random(SHAKE_ANGLE_MIN, SHAKE_ANGLE_MAX))
	local angleY = math.rad(math.random(SHAKE_ANGLE_MIN, SHAKE_ANGLE_MAX))
	local angleZ = math.rad(math.random(SHAKE_ANGLE_MIN, SHAKE_ANGLE_MAX))
	local targetCFrame = baseCFrame * CFrame.Angles(angleX, angleY, angleZ)

	local state: ShakeState = { cancelled = false, connection = nil }
	self._activeShakes[model] = state

	local startTime = tick()

	state.connection = RunService.Heartbeat:Connect(function()
		if state.cancelled then
			return
		end
		if not model.Parent then
			state.cancelled = true
			if state.connection then
				state.connection:Disconnect()
			end
			if self._activeShakes[model] == state then
				self._activeShakes[model] = nil
			end
			return
		end

		local elapsed = tick() - startTime
		local current: CFrame

		if elapsed < SHAKE_OUT_DURATION then
			local alpha = elapsed / SHAKE_OUT_DURATION
			local eased = TweenService:GetValue(alpha, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
			current = startCFrame:Lerp(targetCFrame, eased)
		elseif elapsed < SHAKE_OUT_DURATION + SHAKE_BACK_DURATION then
			local alpha = (elapsed - SHAKE_OUT_DURATION) / SHAKE_BACK_DURATION
			local eased = TweenService:GetValue(alpha, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
			current = targetCFrame:Lerp(baseCFrame, eased)
		else
			-- Settle exactly on the rest CFrame and finish.
			model:PivotTo(baseCFrame)
			if state.connection then
				state.connection:Disconnect()
			end
			if self._activeShakes[model] == state then
				self._activeShakes[model] = nil
			end
			return
		end

		model:PivotTo(current)
	end)
end

--[ Initializers ]--

function BreakableController:KnitInit() end

function BreakableController:KnitStart()
	local BreakableService = Knit.GetService("BreakableService")

	BreakableService.OnBreakableDamaged:Connect(
		function(buildTemplate: Instance, hitCount: number, isMelee: boolean?, hitPosition: Vector3?)
			if not buildTemplate or not buildTemplate.Parent then
				return
			end

			-- Highlight works on any Instance (Model or BasePart).
			onDamageIndicator(buildTemplate, ATTACK_HIGHLIGHT_NAME)

			-- The HitFX sparks are melee-only. A bullet draws its own BulletImpact
			-- where it landed, so a second burst here reads as a double impact.
			-- Magic never fires this signal (it breaks the model outright), so
			-- "not melee" here means a bullet. Highlight and shake still run.
			if isMelee then
				self:_playHitFX(buildTemplate, hitPosition)
			end

			-- Shake requires GetPivot/PivotTo, which exists on PVInstance (both
			-- Model and BasePart). Skip anything else just in case.
			if buildTemplate:IsA("Model") or buildTemplate:IsA("BasePart") then
				self:_startShake(buildTemplate, hitCount)
			end
		end
	)
end

-- The melee impact sparks on a breakable: the shared HitFX asset, every
-- emitter included -- the blade arc is right for a sword hit, and this
-- only runs for one.
--
-- Placed at `hitPosition` -- where the swing actually met the model, as
-- computed by the server from the part it overlapped -- so a crate hit
-- on its corner sparks on that corner. The pivot is only the fallback
-- for a caller that has no contact point.
function BreakableController:_playHitFX(buildTemplate: Instance, hitPosition: Vector3?)
	local partVFX = Instance.new("Part")
	partVFX.Size = Vector3.new(1, 1, 1)
	partVFX.Transparency = 1
	partVFX.Anchored = true
	partVFX.CanCollide = false
	partVFX.CanQuery = false
	partVFX.CanTouch = false
	partVFX.CFrame = if hitPosition
		then CFrame.new(hitPosition)
		else buildTemplate:GetPivot() + buildTemplate:GetPivot().LookVector * -1
	partVFX.Parent = workspace.IgnoreInstances.MagicSpells

	local hitVFX = ReplicatedStorage.GameAssets.VFX.SwordSlash.HitFX:Clone()
	hitVFX.Parent = partVFX

	for _, particle in pairs(hitVFX:GetDescendants()) do
		if not particle:IsA("ParticleEmitter") then
			continue
		end

		if particle.Name == "Hit" then
			particle:Emit(2)
		else
			particle:Emit(6)
		end
	end

	Debris:AddItem(hitVFX, 2)
	Debris:AddItem(partVFX, 2)
end

return BreakableController
