local TweenService = game:GetService("TweenService")
--[[
	Module: Miniboss.lua
	Description: Miniboss mob — MobBase with two behavioral changes, nothing
	more. Everything else (target selection, pathfinding, the whole attack
	pipeline) is inherited.

	  1. Aggressive cadence. After an attack it re-enters Chase (after a
	     short breather) instead of MobBase's 2-4s Roaming cooldown, so it
	     keeps pressuring the player rather than wandering off. Implemented
	     by overriding the _afterAttack seam.

	  2. No-ragdoll death. Minibosses don't collapse on death — they stay
	     upright, play a death animation (placeholder print until the asset
	     exists), and the existing _scheduleDespawn fade removes the body on
	     the spot. The death knockback + killer-directed impulse are
	     suppressed so the upright body doesn't slide.

	Per-attack behavior still lives entirely in ZombieData[name].genericAttacks
	/ uniqueAttacks — this class only changes lifecycle cadence + death style.

	Bosses extend THIS class (see Boss.lua) and add HP-threshold phase changes.
]]

local MobBase = require(script.Parent.MobBase)

local Miniboss = setmetatable({}, MobBase)
Miniboss.__index = Miniboss

-- Breather between attacks (seconds) before re-entering Chase. Replaces
-- MobBase's 2-4s Roaming cooldown so the miniboss attacks more often. The
-- per-attack recoveryDuration in ZombieData still runs BEFORE this.
local ATTACK_COOLDOWN = 0.75

function Miniboss.new(model: Model)
	local self = MobBase.new(model)
	setmetatable(self, Miniboss)
	return self
end

-- Aggressive post-attack behavior: short breather, then straight back to
-- Chase (re-pick an attack + pursue) instead of MobBase's Roaming wander.
function Miniboss:_afterAttack()
	task.wait(ATTACK_COOLDOWN)
	-- Don't resume pursuit if we died, or a boss phase cutscene froze us
	-- (Boss sets self._phasing), during the breather.
	if self._humanoid.Health <= 0 or self._phasing then
		return
	end
	self:_enterChase()
end

--[ No-ragdoll death ]--

function Miniboss:_ragdollOnDeath(): boolean
	return false
end

function Miniboss:_onDeathAnimation()
	-- TODO: load + play the miniboss/boss death animation track here.
	-- Placeholder until the animation asset exists.
	print(("[Miniboss] %s death animation placeholder"):format(self._model.Name))

	task.wait(7)

	self._model.PrimaryPart.Anchored = true

	for _, descendant in self._model:GetDescendants() do
		if descendant:IsA("ParticleEmitter") or descendant:IsA("Beam") then
			descendant.Enabled = false
		end
	end

	for _, descendant in self._model:GetDescendants() do
		if descendant:IsA("BasePart") or descendant:IsA("Decal") then
			TweenService:Create(
				descendant,
				TweenInfo.new(2, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut),
				{ Transparency = 1 }
			):Play()
		elseif descendant:IsA("ParticleEmitter") or descendant:IsA("Beam") then
			descendant.Enabled = false
		end
	end

	task.wait(5)

	if self._model then
		self._model:Destroy()
	end
end

-- Suppress death knockback + killer impulse so the upright (non-ragdolled)
-- body stays in place instead of sliding.
function Miniboss:_applyForwardKnockback() end
function Miniboss:_applyDeathImpulse(_killer: Player) end

return Miniboss
