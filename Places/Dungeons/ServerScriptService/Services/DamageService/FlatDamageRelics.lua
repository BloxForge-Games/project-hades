-- The flat, always-on damage sticks — Neutral stat relics whose ONLY gate
-- is which side of the damage split the hit is on:
--   Linked Sword          +20% Weapon Damage
--   Newtrat's Tuskinator  +10% Weapon Damage (its +20 Ammo Capacity half
--                         is a PlayerStatsService stat row)
--   Wizard Orb            +20% Magic Damage
-- Each callback returns the FRACTION; this module converts the summed
-- fractions to the flat bonus the orchestrator's additive amplifier sum
-- expects, so the sticks join base × (1 + Σ bonuses) like everything else.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)

local RelicService

Knit.OnStart():andThen(function()
	RelicService = Knit.GetService("RelicService")
end)

local WEAPON_RELICS = { RelicNames["Linked Sword"], RelicNames["Newtrat's Tuskinator"] }
local MAGIC_RELICS = { RelicNames["Wizard Orb"] }

return function(player: Player, damage: number, isMagic: boolean): number
	local totalFraction = 0
	for _, relicName in (if isMagic then MAGIC_RELICS else WEAPON_RELICS) do
		if RelicService:GetSpecificRelicRegistry(player, relicName) > 0 then
			totalFraction += RelicService:GetRelicEffect(player, relicName) or 0
		end
	end
	if totalFraction <= 0 then
		return 0
	end
	return math.round(damage * totalFraction)
end
