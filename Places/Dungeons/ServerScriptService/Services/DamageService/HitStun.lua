--!strict
--[[
	Module: Server/Services/DamageService/HitStun.lua
	Description:
	The on-hit HITSTUN. Fired by DamageService:TakeDamage for every DIRECT
	hit on a mob (weapon, magic, relic burst -- not a status-condition
	tick, which returns before the on-hit modules run). Locks the mob's
	HitStunned attribute on for HITSTUN_SECONDS; MobBase's _resyncWalkSpeed
	listener zeroes its WalkSpeed and _chaseStep holds it out of the attack
	decision, so a hit mob stands still for a beat instead of walking
	through the blow. Each fresh hit RESTARTS the window rather than
	stacking it, so a flurry keeps the mob planted for HITSTUN_SECONDS
	past the last blow.

	Gates (in order -- first failure short-circuits):
	  * Miniboss / Boss    -- immune; encounter pacing is never staggered.
	  * SuperArmor true    -- windup / unique attacks claim SuperArmor,
	                          which blocks the whole CC stack (Jail too):
	                          a hit does not interrupt a committed attack.
	  * Ragdolled          -- already locked out via knockback.
	  * Health <= 0        -- dead.

	HITSTUN_SECONDS is authored here so a tuning pass lands in one place.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local EnemyTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.EnemyTypes)
local ValueNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ValueNames)

local HITSTUN_SECONDS = 0.2

-- [model] = os.clock() deadline of the stun in flight. A fresh hit moves
-- it out; the release timer only fires for the deadline it was set for.
-- Weak keys: a despawned mob takes its entry with it.
local deadlines: { [Model]: number } = setmetatable({}, { __mode = "k" }) :: any

-- True when the mob is a Miniboss or Boss (the EnemyType attribute MobBase
-- stamps at spawn). A missing attribute reads as NON-boss.
local function isEncounterEnemy(mobModel: Model): boolean
	local enemyType = mobModel:GetAttribute(Attributes.EnemyType)
	return enemyType == EnemyTypes.Miniboss or enemyType == EnemyTypes.Boss
end

return function(humanoid: Humanoid)
	local mobModel = humanoid.Parent
	if not mobModel or not mobModel:IsA("Model") or humanoid.Health <= 0 then
		return
	end
	if isEncounterEnemy(mobModel) then
		return
	end
	if mobModel:GetAttribute(Attributes.SuperArmor) == true then
		return
	end
	local ragdollTrigger = mobModel:FindFirstChild(ValueNames.RagdollTrigger)
	if ragdollTrigger and ragdollTrigger:IsA("BoolValue") and ragdollTrigger.Value == true then
		return
	end

	local deadline = os.clock() + HITSTUN_SECONDS
	deadlines[mobModel] = deadline
	mobModel:SetAttribute(Attributes.HitStunned, true)

	task.delay(HITSTUN_SECONDS, function()
		-- A later hit moved the deadline: its own timer releases.
		if deadlines[mobModel] ~= deadline then
			return
		end
		deadlines[mobModel] = nil
		if mobModel.Parent then
			mobModel:SetAttribute(Attributes.HitStunned, false)
		end
	end)
end
