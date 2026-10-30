--!strict
--[[
	Module: DamageService/LaserScythes.lua
	Description:
	The Laser Scythe twins (Neutral Epics), flat always-on sticks synced to
	their cards (2026-10-28; they used to convert bonus Max Health / Mana
	percentages, which paid nothing without HP or mana bonuses):

	  Red Laser Scythe   +30% on MELEE weapon hits.
	  Blue Laser Scythe  +40% on ARCANE hits.

	Each callback is the fraction. Returns BONUS damage (damage x fraction)
	for the orchestrator's additive pool.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DamageService = require(script.Parent)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)

type RelicSnapshot = DamageService.RelicSnapshot

return function(_player: Player, snapshot: RelicSnapshot, damage: number, isMagic: boolean, isMelee: boolean)
	local fraction = 0

	if isMelee and not isMagic and DamageService.RelicCount(snapshot, RelicNames["Red Laser Scythe"]) > 0 then
		fraction += DamageService.RelicEffect(snapshot, RelicNames["Red Laser Scythe"]) or 0
	end

	if isMagic and DamageService.RelicCount(snapshot, RelicNames["Blue Laser Scythe"]) > 0 then
		fraction += DamageService.RelicEffect(snapshot, RelicNames["Blue Laser Scythe"]) or 0
	end

	if fraction <= 0 then
		return 0
	end

	return math.round(damage * fraction)
end
