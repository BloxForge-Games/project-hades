--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local isEncounterEnemy = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Mob.isEncounterEnemy)
local DamageService = require(script.Parent)

type RelicSnapshot = DamageService.RelicSnapshot

return function(_player: Player, snapshot: RelicSnapshot, humanoid: Humanoid, damage: number)
	local fluffyUnicornEffect = DamageService.RelicEffect(snapshot, RelicNames["Fluffy Unicorn"]) or 1

	if fluffyUnicornEffect == 1 then
		return 0
	end

	local character = humanoid.Parent :: Instance

	-- Minibosses + Bosses only. Elite tier USED to be included, but
	-- per the relic description ("+25% damage to Minibosses and Bosses")
	-- the design intent is to exclude Elites — Elite mobs are common
	-- enough that including them turned this into a near-universal
	-- damage relic instead of an anti-big-target one.
	if not isEncounterEnemy(character) then
		return 0
	end

	return math.round(damage * fluffyUnicornEffect) - damage
end
