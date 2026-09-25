--!strict
--[[
	Module: DamageService/LaserScythes.lua
	Description:
	The Laser Scythe twins (Neutral Epics), element-rework edition:

	  Red Laser Scythe   your bonus MAXIMUM HEALTH percentage joins the
	                     WEAPON side of the additive relic sum at the same
	                     fraction (BonusHealthPercent attribute — the
	                     relic/rune HP sum PlayerStatsService stamps).
	  Blue Laser Scythe  your bonus MAXIMUM MANA percentage joins the
	                     MAGIC side the same way (BonusManaPercent — the
	                     mana-rune sum).

	Returns BONUS damage (damage x fraction) for the orchestrator's
	additive pool.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DamageService = require(script.Parent)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)

type RelicSnapshot = DamageService.RelicSnapshot

local BONUS_HEALTH_PERCENT_ATTRIBUTE = "BonusHealthPercent"
local BONUS_MANA_PERCENT_ATTRIBUTE = "BonusManaPercent"

return function(player: Player, snapshot: RelicSnapshot, damage: number, isMagic: boolean)
	local fraction = 0

	if not isMagic and DamageService.RelicCount(snapshot, RelicNames["Red Laser Scythe"]) > 0 then
		fraction += (player:GetAttribute(BONUS_HEALTH_PERCENT_ATTRIBUTE) :: number?) or 0
	end

	if isMagic and DamageService.RelicCount(snapshot, RelicNames["Blue Laser Scythe"]) > 0 then
		fraction += (player:GetAttribute(BONUS_MANA_PERCENT_ATTRIBUTE) :: number?) or 0
	end

	if fraction <= 0 then
		return 0
	end

	return math.round(damage * fraction)
end
