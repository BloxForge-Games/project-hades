--!strict
-- The TRUE "more" multipliers (2026-10-27 damage-formula pass).
--
-- Rare and Epic relics, auras and conditional bonuses ADD into one pool,
-- base x (1 + sum), so a run's power grows in a straight line that the
-- per-floor enemy growth (DifficultyData) is tuned against. Legendary and
-- Cursed damage relics are the deliberate spikes instead: each one
-- MULTIPLIES the amplified total here, so a late pick is worth exactly
-- what its card says rather than being watered down by the pool.
--
-- Card wording follows the split: "+X% Damage" adds, "X% more Damage"
-- multiplies here.
--
--   Glorious Sword           40% more Melee Weapon Damage     typed
--   Mystical Staff of Cyan   40% more Arcane Damage (owner)   typed; the
--                            Sigil's +25% stays additive (MysticalSigil)
--   Double-Bladed Scythe     100% more Weapon, Arcane deals 0 typed
--   Forbidden Box            100% more Arcane, Weapon 50% less typed
--   Sword of Eternal Abyss   50% more Damage                  every lane
--
-- "Typed" relics skip the untyped relic-burst lane like every Weapon /
-- Arcane bonus; the unqualified "Damage" ones apply on it too.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DamageService = require(script.Parent)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local RelicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicData)

type RelicSnapshot = DamageService.RelicSnapshot

-- The callback value of an owned relic, or nil when not owned.
local function effect(snapshot: RelicSnapshot, relicName: string): number?
	if DamageService.RelicCount(snapshot, relicName) <= 0 then
		return nil
	end
	local value = DamageService.RelicEffect(snapshot, relicName)
	return if type(value) == "number" then value else nil
end

return function(
	_player: Player,
	snapshot: RelicSnapshot,
	isMagic: boolean,
	untypedOnly: boolean,
	isMelee: boolean
): number
	local multiplier = 1

	-- Unqualified "Damage": every lane, relic bursts included.
	multiplier *= effect(snapshot, RelicNames["Sword of Eternal Abyss"]) or 1

	if untypedOnly then
		return multiplier
	end

	if isMagic then
		multiplier *= effect(snapshot, RelicNames["Forbidden Box"]) or 1

		local mystical = RelicData[RelicNames["Mystical Staff of Cyan"]]
		if DamageService.RelicCount(snapshot, RelicNames["Mystical Staff of Cyan"]) > 0 then
			local more = mystical and mystical.data and mystical.data.ownerArcaneMore
			multiplier *= 1 + (if type(more) == "number" then more else 0.40)
		end
	elseif isMelee then
		multiplier *= effect(snapshot, RelicNames["Glorious Sword"]) or 1
	end

	-- Forbidden Box's drawback (2026-10-31; a mana cost before): every
	-- weapon lane deals data.weaponLess less.
	if not isMagic and DamageService.RelicCount(snapshot, RelicNames["Forbidden Box"]) > 0 then
		local box = RelicData[RelicNames["Forbidden Box"]]
		local less = box and box.data and box.data.weaponLess
		multiplier *= 1 - (if type(less) == "number" then less else 0.5)
	end

	-- Double-Bladed Scythe: the callback is the magnitude (1.00), less on
	-- Arcane and more on Weapon.
	local scythe = effect(snapshot, RelicNames["Double-Bladed Scythe"])
	if scythe then
		multiplier *= if isMagic then math.max(1 - scythe, 0) else 1 + scythe
	end

	return multiplier
end
