--!strict
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

local DamageService = require(script.Parent)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)

type RelicSnapshot = DamageService.RelicSnapshot

local WEAPON_RELICS: { string } = { RelicNames["Linked Sword"], RelicNames["Newtrat's Tuskinator"] }
local MAGIC_RELICS: { string } = { RelicNames["Wizard Orb"] }

return function(_player: Player, snapshot: RelicSnapshot, damage: number, isMagic: boolean): number
	local totalFraction = 0
	local relics: { string } = if isMagic then MAGIC_RELICS else WEAPON_RELICS
	for _, relicName in relics do
		if DamageService.RelicCount(snapshot, relicName) > 0 then
			totalFraction += DamageService.RelicEffect(snapshot, relicName) or 0
		end
	end
	if totalFraction <= 0 then
		return 0
	end
	return math.round(damage * totalFraction)
end
