-- Teddy Trap (sustain side): heals its owner for LIFESTEAL_FRACTION of
-- every point of damage they deal. The other two thirds of the relic live
-- elsewhere:
--   * +150% damage TAKEN -- DamageService:PlayerTakeDamage, which reads the
--     relic callback (2.5) directly.
--   * Health Orbs never heal an owner -- DropService's health-orb branch.
-- Together they make it a pure sustain-through-aggression relic: the only
-- way you get health back is by hurting something.
--
-- "On ALL damage": called with the FINAL applied amount from every path
-- that lands damage -- each direct hit (_recordLastHit: crit, resisted,
-- plain) AND every status DoT tick. An AoE that hits ten mobs calls
-- TakeDamage ten times and so heals ten times, which is intended.
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
-- INCOMING damage multiplier (2.5), the same primary-in-data /
-- secondary-in-module split Murder Knife and Volleyball use.
-- Keep in sync with the "+5% Lifesteal" on the card.
local LIFESTEAL_FRACTION = 0.05

return function(player: Player, damageDealt: number?)
	if not RelicService or not PlayerStatsService then
		return
	end
	if typeof(damageDealt) ~= "number" or damageDealt <= 0 then
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

	PlayerStatsService:ApplyHealing(player, damageDealt * LIFESTEAL_FRACTION, nil, true)
end
