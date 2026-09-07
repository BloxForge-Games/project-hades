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

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)

local RelicService

Knit.OnStart():andThen(function()
	RelicService = Knit.GetService("RelicService")
end)

local BONUS_HEALTH_PERCENT_ATTRIBUTE = "BonusHealthPercent"
local BONUS_MANA_PERCENT_ATTRIBUTE = "BonusManaPercent"

return function(player: Player, damage: number, isMagic: boolean)
	if not RelicService then
		return 0
	end

	local fraction = 0

	if not isMagic and (RelicService:GetSpecificRelicRegistry(player, RelicNames["Red Laser Scythe"]) or 0) > 0 then
		fraction += player:GetAttribute(BONUS_HEALTH_PERCENT_ATTRIBUTE) or 0
	end

	if isMagic and (RelicService:GetSpecificRelicRegistry(player, RelicNames["Blue Laser Scythe"]) or 0) > 0 then
		fraction += player:GetAttribute(BONUS_MANA_PERCENT_ATTRIBUTE) or 0
	end

	if fraction <= 0 then
		return 0
	end

	return math.round(damage * fraction)
end
