--[[
	Module: DamageService/AuraDamage.lua
	Description:
	The AURA-driven additive damage bonuses, folded into one module so the
	orchestrator's sum stays flat:

	  Enflamed      +50% Weapon Damage while up (AuraData owns it).
	  Faux          +15% MORE Weapon Damage while Enflamed (relic callback).
	  Firebrand
	  Berserker's   +30% MORE Weapon Damage while Enflamed (relic callback),
	  Claymore      on top of the aura's own 50.
	  Frostburst    +50% Magic Damage while up (AuraData).
	  Blizzard      +15% MORE Magic Damage while Frostburst (relic callback).
	  Wand
	  Icy Arctic    +30% damage on MAGIC hits while Frostburst is up (relic
	  Fowl          callback; its mana-cost half lives in the cost chains).
	  Staff of      +25% MORE Magic Damage while Frostburst (relic callback)
	  Azure Ever    — the element-rework replacement for its Frost Crater.
	  Ice
	  Stonebound    +damage payload from the marker attributes (base 25% +
	                the owner's Leland and Spartan riders), weapon AND magic.
	  Golden        +35% while any Barrier bucket is live, weapon AND magic.
	  Steampunk     A plain multiplier since the 2026-08 pass — it used to
	  Gloves        be a level + max-health FLAT term.

	Returns BONUS damage (damage x summed fractions + flats) for the
	orchestrator's additive pool.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local AuraNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.AuraNames)
local AuraData = require(ReplicatedStorage.Submodules.Core.Shared.Data.AuraData)

local RelicService
local AuraService

Knit.OnStart():andThen(function()
	RelicService = Knit.GetService("RelicService")
	AuraService = Knit.GetService("AuraService")
end)

local SHIELD_ATTRIBUTE = "ShieldValue"
return function(player: Player, damage: number, isMagic: boolean)
	if not RelicService then
		return 0
	end

	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return 0
	end

	local fraction = 0

	if not isMagic and hrp:FindFirstChild(AuraNames.Enflamed) then
		fraction += AuraData[AuraNames.Enflamed].weaponDamagePercent or 0

		-- Faux Firebrand rides the same window. Raw fraction, not a
		-- multiplier: its callback returns 0.20, not 1.20.
		if (RelicService:GetSpecificRelicRegistry(player, RelicNames["Faux Firebrand"]) or 0) > 0 then
			fraction += RelicService:GetRelicEffect(player, RelicNames["Faux Firebrand"]) or 0
		end

		-- Berserker's Claymore rides the same window.
		if (RelicService:GetSpecificRelicRegistry(player, RelicNames["Berserker's Claymore"]) or 0) > 0 then
			fraction += (RelicService:GetRelicEffect(player, RelicNames["Berserker's Claymore"]) or 1) - 1
		end
	end

	if isMagic and hrp:FindFirstChild(AuraNames.Frostburst) then
		fraction += AuraData[AuraNames.Frostburst].magicDamagePercent or 0

		-- Blizzard Wand rides the same window. Raw fraction like Faux
		-- Firebrand, its Frost-side counterpart.
		if (RelicService:GetSpecificRelicRegistry(player, RelicNames["Blizzard Wand"]) or 0) > 0 then
			fraction += RelicService:GetRelicEffect(player, RelicNames["Blizzard Wand"]) or 0
		end

		-- Icy Arctic Fowl's damage half rides Frostburst too.
		if (RelicService:GetSpecificRelicRegistry(player, RelicNames["Icy Arctic Fowl"]) or 0) > 0 then
			fraction += (RelicService:GetRelicEffect(player, RelicNames["Icy Arctic Fowl"]) or 1) - 1
		end

		-- Staff of Azure Ever Ice: +25% Magic Damage in the same window.
		if (RelicService:GetSpecificRelicRegistry(player, RelicNames["Staff of Azure Ever Ice"]) or 0) > 0 then
			fraction += (RelicService:GetRelicEffect(player, RelicNames["Staff of Azure Ever Ice"]) or 1) - 1
		end
	end

	-- Stonebound: damage payload straight off the marker (owner riders
	-- already folded in by AuraService).
	if AuraService then
		local stoneboundDamage = AuraService:GetStoneboundPayload(character)
		fraction += stoneboundDamage
	end

	-- Golden Steampunk Gloves: a flat PERCENTAGE while any Barrier bucket is
	-- live. It used to be a level + max-health flat term; the 2026-08 pass
	-- made it a plain multiplier, so it joins `fraction` with the other
	-- percentage bonuses instead of `flat`.
	if
		(character:GetAttribute(SHIELD_ATTRIBUTE) or 0) > 0
		and (RelicService:GetSpecificRelicRegistry(player, RelicNames["Golden Steampunk Gloves"]) or 0) > 0
	then
		fraction += (RelicService:GetRelicEffect(player, RelicNames["Golden Steampunk Gloves"]) or 1) - 1
	end

	return math.round(damage * fraction)
end
