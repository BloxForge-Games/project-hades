--!strict
-- The flat, always-on damage sticks whose ONLY gate is which side of the
-- damage split the hit is on:
--   Linked Sword          +20% Weapon Damage (Blaze since 2026-10-30)
--   Wizard Orb            +25% Arcane Damage (Frost since 2026-10-30)
-- (Newtrat's Tuskinator moved to RangedRelics, ranged only, 2026-10-30.)
-- Each callback returns the FRACTION; this module converts the summed
-- fractions to the flat bonus the orchestrator's additive amplifier sum
-- expects, so the sticks join base × (1 + Σ bonuses) like everything else.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DamageService = require(script.Parent)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)

type RelicSnapshot = DamageService.RelicSnapshot

local WEAPON_RELICS: { string } = { RelicNames["Linked Sword"] }
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
