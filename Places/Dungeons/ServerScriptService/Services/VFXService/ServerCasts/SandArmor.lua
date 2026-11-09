--!strict
--[[
	Sand Armor, server side (PROTOTYPE, 2026-11-07; Stone Body until
	2026-11-08).

	For `armorSeconds` the caster takes `damageReduction` less damage
	(DamageService:AddTimedReduction) and every mob within `tauntRadius`
	chases them (TauntService). When it ends the armor BURSTS through
	VFXService's shared hitbox (2026-11-08; its own mob loop before): every
	mob within half the hitbox takes the spell's `damage` through the
	spell-hit path (x Arcane Rank, crits and Arcane bonuses), the same
	however much the caster took, and breakables in it break like any
	spell's (canBreakBuildings).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local ArcaneData = require(ReplicatedStorage.Submodules.Core.Shared.Data.ArcaneData)
local ArcaneNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ArcaneNames)
local Blitz = require(ReplicatedStorage.Submodules.Core.Shared.Blitz)
local GameClock = require(ReplicatedStorage.Submodules.Core.Shared.GameClock)
local getRoot = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Character.getRoot)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local IgnoreListService = require(ServerScriptService.Submodules.Core.Source.Services.IgnoreListService)

local SPELL = ArcaneNames["Sand Armor"]

return function(vfxService: any, player: Player, _cframe: CFrame)
	local data = ArcaneData[SPELL]
	local seconds = data.armorSeconds or 10
	local damageService = Blitz.OptionalService("DamageService")
	if not damageService then
		return
	end
	damageService:AddTimedReduction(player, SPELL, data.damageReduction or 0.4, seconds)
	local taunts = Blitz.OptionalService("TauntService")
	if taunts then
		taunts:Taunt(player, data.tauntRadius or 20, seconds)
	end

	GameClock.Delay(seconds, function()
		local character = player.Character
		local root = character and getRoot(character)
		if not root then
			return
		end
		-- Wind Bomb's explosion hitbox exactly (VFXService._onHitboxRequested):
		-- a fresh registry, CreateHitbox at hitboxSize.X, _spellHit.
		local radius = data.hitboxSize.X
		local burstCFrame = CFrame.new(root.Position)
		local registry = vfxService._playerDetectedPartsRegistry[player.UserId]
		if registry then
			registry[SPELL] = nil
		end
		vfxService:CreateHitbox(
			SPELL,
			player,
			burstCFrame,
			TagList.Zombie,
			IgnoreListService:GetWeaponIgnoreList(),
			function(model: Model)
				vfxService:_spellHit(model, burstCFrame, player, SPELL, data)
			end,
			radius
		)
	end)
end
