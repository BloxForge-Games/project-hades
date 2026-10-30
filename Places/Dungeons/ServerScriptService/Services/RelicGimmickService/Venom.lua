--!strict
--[[
	Module: RelicGimmickService/Venom
	Description:
	Venom's gimmick epics (Status / Poison) that need a world effect:

	  Foul Poison Fowl  TOXIC SPIT: each tick of its owner's Poison (Noxious
	                    Venom included) has `spitChance` to lob a toxic
	                    bubble from the ticking enemy at another one nearby,
	                    damaging and Poisoning it where it lands. (Its +10% Weaken stays
	                    a StatusConditionData relicModifier.)

	The bubble is drawn by the clients (helpers.fx); the server waits out
	its flight and Poisons where it lands.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local StatusConditions = require(ReplicatedStorage.Submodules.Core.Shared.Enums.StatusConditions)
local getRoot = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Character.getRoot)
local forEachEnemyInRadius = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Combat.forEachEnemyInRadius)
local helpers = require(script.Parent.Lib.gimmickHelpers)

local FOWL = RelicNames["Foul Poison Fowl"]

-- Toxic Spit's reach and flight.
local SPIT_RANGE = 15
local SPIT_FLIGHT_SECONDS = 0.5
-- Enemies within this far of the landing are Poisoned.
local SPIT_SPLASH_RADIUS = 4

local POISON_FAMILY: { [string]: boolean } = {
	[StatusConditions.Poison] = true,
	[StatusConditions.NoxiousVenom] = true,
}

local Venom = {}

local function lobBubble(player: Player, fromModel: Model)
	local fromRoot = getRoot(fromModel)
	if not fromRoot then
		return
	end
	local candidates: { Model } = {}
	forEachEnemyInRadius(fromRoot.Position, SPIT_RANGE, function(model: Model)
		if model ~= fromModel then
			table.insert(candidates, model)
		end
	end)
	if #candidates == 0 then
		return
	end
	local target = candidates[math.random(#candidates)]
	local targetRoot = getRoot(target)
	if not targetRoot then
		return
	end

	local from = fromRoot.Position + Vector3.new(0, 2, 0)
	local to = targetRoot.Position
	helpers.fx("ToxicBubble", from, to, SPIT_SPLASH_RADIUS, SPIT_FLIGHT_SECONDS)
	task.delay(SPIT_FLIGHT_SECONDS, function()
		if not player.Parent then
			return
		end
		helpers.hitBreakables(player, to, SPIT_SPLASH_RADIUS)
		local damage = helpers.levelDamage(player, helpers.data(FOWL, "damagePerLevel", 10))
		forEachEnemyInRadius(to, SPIT_SPLASH_RADIUS, function(model: Model, humanoid: Humanoid)
			-- Untyped relic lane, like every relic burst.
			helpers.damageService():TakeDamage(player, humanoid, damage, false, false, nil, true)
			helpers.statusService():ApplyStatus(player, model, StatusConditions.Poison)
		end)
	end)
end

-- A DoT tick landed (StatusConditionService): Toxic Spit's roll.
function Venom.onStatusTick(player: Player, model: Model, status: string)
	if not POISON_FAMILY[status] or not helpers.owns(player, FOWL) then
		return
	end
	if math.random() < helpers.data(FOWL, "spitChance", 0.35) then
		lobBubble(player, model)
	end
end

return Venom
