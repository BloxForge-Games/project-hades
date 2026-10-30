--!strict
--[[
	Module: DamageService/AuraDamage.lua
	Description:
	The AURA-driven additive damage bonuses, folded into one module so the
	orchestrator's sum stays flat:

	  Enflamed      +50% Weapon Damage while up (AuraData owns it).
	  Faux          +15% MORE Weapon Damage while Enflamed (relic callback).
	  Firebrand
	  Frostburst    +50% Magic Damage while up (AuraData).
	  Blizzard      +15% MORE Magic Damage while Frostburst (relic callback).
	  Wand
	  Golden        +20% while any Barrier is up (relic callback).
	  Steampunk
	  Gloves
	  Stonebound    +damage payload from the marker attributes (base 25% +
	                the owner's Leland and Spartan riders), weapon AND arcane.

	Returns BONUS damage (damage x summed fractions + flats) for the
	orchestrator's additive pool.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local AuraService = require(ServerScriptService.Services.AuraService)
local DamageService = require(script.Parent)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local AuraNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.AuraNames)
local AuraData = require(ReplicatedStorage.Submodules.Core.Shared.Data.AuraData)
local getRoot = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Character.getRoot)

-- ShieldService's live Barrier total on the character.
local SHIELD_ATTRIBUTE = "ShieldValue"

type RelicSnapshot = DamageService.RelicSnapshot

return function(player: Player, snapshot: RelicSnapshot, damage: number, isMagic: boolean)
	local character: Model? = player.Character

	local hrp = getRoot(character)
	if not character or not hrp then
		return 0
	end

	local fraction = 0

	if not isMagic and hrp:FindFirstChild(AuraNames.Enflamed) then
		fraction += (AuraData[AuraNames.Enflamed].weaponDamagePercent or 0) * DamageService.AuraScale(snapshot)

		-- Faux Firebrand rides the same window. Raw fraction, not a
		-- multiplier: its callback returns 0.20, not 1.20.
		if DamageService.RelicCount(snapshot, RelicNames["Faux Firebrand"]) > 0 then
			fraction += DamageService.RelicEffect(snapshot, RelicNames["Faux Firebrand"]) or 0
		end
	end

	if isMagic and hrp:FindFirstChild(AuraNames.Frostburst) then
		fraction += (AuraData[AuraNames.Frostburst].magicDamagePercent or 0) * DamageService.AuraScale(snapshot)

		-- Blizzard Wand rides the same window. Raw fraction like Faux
		-- Firebrand, its Frost-side counterpart.
		if DamageService.RelicCount(snapshot, RelicNames["Blizzard Wand"]) > 0 then
			fraction += DamageService.RelicEffect(snapshot, RelicNames["Blizzard Wand"]) or 0
		end
	end

	-- Golden Steampunk Gloves (2026-10-29, back from its Shockwave Fist):
	-- its callback's fraction while any Barrier is up, weapon and arcane.
	if
		(character:GetAttribute(SHIELD_ATTRIBUTE) or 0) > 0
		and DamageService.RelicCount(snapshot, RelicNames["Golden Steampunk Gloves"]) > 0
	then
		fraction += DamageService.RelicEffect(snapshot, RelicNames["Golden Steampunk Gloves"]) or 0
	end

	-- Stonebound: damage payload straight off the marker (owner riders
	-- already folded in by AuraService).
	if AuraService then
		local stoneboundDamage = AuraService:GetStoneboundPayload(character)
		fraction += stoneboundDamage
	end

	return math.round(damage * fraction)
end
