--!strict
--[[
	Module: DamageService/RangedRelics.lua
	Description:
	The ranged relics' additive damage halves (2026-10-30), on gun shots
	only:
	  Red Hyperlaser Gun    (Blaze) +data.burningBonus against Burning enemies.
	  Hyperlaser Gun        (Frost) +data.frostburstBonus while Frostburst.
	  Newtrat's Tuskinator  (Neutral) its callback, always.
	Their status halves are StatusConditionService rangedOnly rows; the
	gimmick ranged relics (War Rocks, Rubber Chicken Launcher, Toxic
	Mortar) are RelicGimmickService/Ranged. Returns BONUS damage for the
	orchestrator's additive pool.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DamageService = require(script.Parent)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local AuraNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.AuraNames)
local RelicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicData)
local getRoot = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Character.getRoot)

type RelicSnapshot = DamageService.RelicSnapshot

local function dataOf(relicName: string, field: string, fallback: number): number
	local row = RelicData[relicName]
	local value = row and row.data and row.data[field]
	return if type(value) == "number" then value else fallback
end

return function(
	player: Player,
	snapshot: RelicSnapshot,
	damage: number,
	isGunShot: boolean,
	statuses: DamageService.TargetStatuses
): number
	if not isGunShot then
		return 0
	end
	local fraction = 0
	if statuses.isBurning and DamageService.RelicCount(snapshot, RelicNames["Red Hyperlaser Gun"]) > 0 then
		fraction += dataOf(RelicNames["Red Hyperlaser Gun"], "burningBonus", 0.20)
	end
	if DamageService.RelicCount(snapshot, RelicNames["Hyperlaser Gun"]) > 0 then
		local root = getRoot.fromPlayer(player)
		if root and root:FindFirstChild(AuraNames.Frostburst) then
			fraction += dataOf(RelicNames["Hyperlaser Gun"], "frostburstBonus", 0.30)
		end
	end
	if DamageService.RelicCount(snapshot, RelicNames["Newtrat's Tuskinator"]) > 0 then
		fraction += DamageService.RelicEffect(snapshot, RelicNames["Newtrat's Tuskinator"]) or 0
	end
	if fraction <= 0 then
		return 0
	end
	return math.round(damage * fraction)
end
