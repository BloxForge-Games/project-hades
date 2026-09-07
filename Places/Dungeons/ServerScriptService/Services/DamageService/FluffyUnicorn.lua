local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local EnemyTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.EnemyTypes)
local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)

local RelicService

Knit.OnStart():andThen(function()
	RelicService = Knit.GetService("RelicService")
end)

return function(player: Player, humanoid: Humanoid, damage: number)
	local fluffyUnicornEffect = RelicService:GetRelicEffect(player, RelicNames["Fluffy Unicorn"]) or 1

	if fluffyUnicornEffect == 1 then
		return 0
	end

	local character = humanoid.Parent
	local enemyType = character:GetAttribute(Attributes.EnemyType)

	-- Minibosses + Bosses only. Elite tier USED to be included, but
	-- per the relic description ("+25% damage to Minibosses and Bosses")
	-- the design intent is to exclude Elites — Elite mobs are common
	-- enough that including them turned this into a near-universal
	-- damage relic instead of an anti-big-target one.
	if enemyType ~= EnemyTypes.Miniboss and enemyType ~= EnemyTypes.Boss then
		return 0
	end

	return math.round(damage * fluffyUnicornEffect) - damage
end
