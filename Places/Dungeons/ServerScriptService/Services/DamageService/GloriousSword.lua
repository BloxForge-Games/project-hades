-- Glorious Sword (Legendary): +50% Weapon Damage on EVERY weapon hit --
-- melee AND ranged (the description's "Weapon Damage" is unqualified,
-- same convention as The General's .45 passive). The +6 stud Melee Range
-- half is a MeleeRangeBonus row in PlayerStatsService, flat-additive
-- with Farmer's Revenge's +3.
--
-- The callback returns the multiplier (1.50); this module converts it to
-- a flat bonus for the orchestrator's additive amplifier sum.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)

local RelicService

Knit.OnStart():andThen(function()
	RelicService = Knit.GetService("RelicService")
end)

return function(player: Player, damage: number, isMagic: boolean)
	if isMagic then
		return 0
	end

	if RelicService:GetSpecificRelicRegistry(player, RelicNames["Glorious Sword"]) <= 0 then
		return 0
	end

	local effect = RelicService:GetRelicEffect(player, RelicNames["Glorious Sword"]) or 1
	return math.round(damage * (effect - 1))
end
