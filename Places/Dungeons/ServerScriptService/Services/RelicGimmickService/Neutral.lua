--!strict
--[[
	Module: RelicGimmickService/Neutral
	Description:
	Neutral's gimmick relics that ride the combat hooks:
	  Midnight Sword  MANA ON HIT: a melee swing that connects, or a gun
	                  shot that lands, restores manaFraction of the owner's
	                  max Mana. Per hit EVENT, never per enemy: a cleave
	                  through five mobs is one restore, five bullets are
	                  five. (Korblox Mage Staff's free cast lives in
	                  VFXService's cast path, not here.)
	The numbers are the relic's RelicData `data`.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local ArcaneService = require(ServerScriptService.Services.ArcaneService)
local helpers = require(script.Parent.Lib.gimmickHelpers)

local MIDNIGHT = RelicNames["Midnight Sword"]

local Neutral = {}

local function restoreMana(player: Player)
	if not helpers.owns(player, MIDNIGHT) then
		return
	end
	local data = ArcaneService:GetPlayerArcaneData(player)
	if not data or not data.maxMana or data.mana >= data.maxMana then
		return
	end
	local fraction = helpers.data(MIDNIGHT, "manaFraction", 0.03)
	ArcaneService:SetPlayerArcaneData(player, math.min(data.mana + data.maxMana * fraction, data.maxMana), data.maxMana)
end

-- Once per swing, only when it connected with something.
function Neutral.onMeleeSwing(
	player: Player,
	_origin: Vector3,
	_look: Vector3,
	_swingDamage: number,
	connected: boolean,
	_weaponType: string?
)
	if connected then
		restoreMana(player)
	end
end

-- Once per gun shot that lands.
function Neutral.onRangedHit(player: Player, _model: Model, _dealt: number, _wasCrit: boolean)
	restoreMana(player)
end

return Neutral
