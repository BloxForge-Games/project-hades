-- Teddy Trap (sustain side): heals its owner for 1% of their MAXIMUM
-- HEALTH on every direct hit they land. The other two thirds of the relic
-- live elsewhere:
--   * +100% damage TAKEN -- DamageService:PlayerTakeDamage, which reads the
--     relic callback (2.0) directly.
--   * no normal healing at all -- PlayerStatsService:ApplyHealing, which
--     refuses every non-lifesteal restore for an owner.
-- Together they make it a pure sustain-through-aggression relic: the only
-- way you get health back is by hitting something.
--
-- Called once per DIRECT hit from TakeDamage, NOT summed into the damage
-- amplifiers like it used to be (the relic no longer grants damage at all).
-- Its call site sits after the isStatusConditionDamage early-return, so
-- Burn/Poison ticks deliberately do not feed it -- lifesteal is for swings
-- and casts. An AoE that hits ten mobs calls TakeDamage ten times and so
-- heals ten times, which is intended.
--
-- isLifesteal = true on the ApplyHealing call is load-bearing: without it
-- the relic's own heal block would swallow the relic's own heal.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)

local RelicService
local PlayerStatsService

Knit.OnStart():andThen(function()
	RelicService = Knit.GetService("RelicService")
	PlayerStatsService = Knit.GetService("PlayerStatsService")
end)

-- Hardcoded rather than read from the callback: the callback owns the
-- INCOMING damage multiplier (2.0), the same primary-in-data /
-- secondary-in-module split Murder Knife and Volleyball use.
local LIFESTEAL_MAX_HEALTH_FRACTION = 0.01

return function(player: Player)
	if not RelicService or not PlayerStatsService then
		return
	end
	-- Presence check, not GetRelicEffect: the callback returns 2.0, which is
	-- a valid effect value rather than a "0 = not owned" sentinel.
	if RelicService:GetSpecificRelicRegistry(player, RelicNames["Teddy Trap"]) <= 0 then
		return
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	PlayerStatsService:ApplyHealing(player, humanoid.MaxHealth * LIFESTEAL_MAX_HEALTH_FRACTION, nil, true)
end
