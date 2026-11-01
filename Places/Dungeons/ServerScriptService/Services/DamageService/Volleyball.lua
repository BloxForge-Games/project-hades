--!strict
-- Volleyball (2026-10-31 shape): every data.spikeEvery-th gun shot that
-- lands drops a Volleyball on the target a beat later, for
-- data.powerMultiple x the owner's Power on the UNIVERSAL relic lane
-- (DamageService:TakeDamage with isRelicSourced: variance, Shock, Blight,
-- Abyss, never weapon lines, never a crit). Returns 0 to the additive
-- pool: the spike is its own hit now, not a share of the shot.
--
-- Gating: gun shots only (the orchestrator's isGunShot, 2026-10-30; it
-- used to infer "ranged" as not-magic-and-not-melee, which let a
-- Sword-of-the-Epicredness spell count and spike).
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local DamageService = require(script.Parent)
local RelicNetwork = require(ServerScriptService.Submodules.Core.Source.Network.Relic)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local RelicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicData)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local computePower = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Player.computePower)

type RelicSnapshot = DamageService.RelicSnapshot

local VOLLEY_BALL_DESYNC_DELAY = 0.5

local function volleyballData(key: string, default: number): number
	local row = RelicData[RelicNames["Volleyball"]]
	local value = row and row.data and row.data[key]
	return if typeof(value) == "number" then value else default
end

-- The owner's Power (PlayerStatsService stamps it), the reference before.
local function powerOf(player: Player): number
	local power = player:GetAttribute(Attributes.Power)
	return if typeof(power) == "number" and power > 0 then power else computePower.REFERENCE_POWER
end

-- PRIVATE ranged-only hit counter. The orchestrator used to hand every
-- module a shared counter of EVERY damage event — melee swings, arcane hits,
-- relic procs — so reading it made "every 3rd ranged attack" fire on the
-- 3rd damage event of any type. A melee-and-gun player got spikes at
-- effectively random points in their gun's cadence, and a pure-arcane player
-- advanced the counter without ever being able to trigger it. Same fix
-- GeneralsFortyFive already carries for its 6th-shot bonus.
--
-- Only incremented on hits that PASS the ranged gate below, so the first
-- spike lands exactly 3 ranged attacks after pickup.
local rangedHitCounts: { [number]: number } = {}

Players.PlayerRemoving:Connect(function(player: Player)
	rangedHitCounts[player.UserId] = nil
end)

return function(player: Player, snapshot: RelicSnapshot, humanoid: Humanoid, _damage: number, isGunShot: boolean)
	-- Ranged WEAPON attacks only: the orchestrator passes isGunShot (true
	-- for a bullet, Orinthian-converted or not; false for melee, spells and
	-- Epicredness-converted spells), so nothing else can advance the count.
	if not isGunShot then
		return 0
	end

	if DamageService.RelicCount(snapshot, RelicNames["Volleyball"]) <= 0 then
		return 0
	end

	-- Every spikeEvery-th RANGED hit spikes, for a multiple of Power.
	local rangedCount = (rangedHitCounts[player.UserId] or 0) + 1
	rangedHitCounts[player.UserId] = rangedCount

	if rangedCount % volleyballData("spikeEvery", 3) == 0 then
		local spikeDamage = math.round(powerOf(player) * volleyballData("powerMultiple", 2))

		RelicNetwork.VolleyballEffect.FireAll({
			Character = player.Character,
			Target = humanoid.Parent :: Model?,
			StartTime = workspace:GetServerTimeNow(),
			Duration = 0.5,
		})

		task.delay(VOLLEY_BALL_DESYNC_DELAY, function()
			-- Re-check liveness — the original hit may have already
			-- brought the mob to 0 HP, in which case the spike is a
			-- no-op (don't show the indicator either).
			if humanoid.Health <= 0 or (humanoid.Parent :: Instance):GetAttribute(Attributes.Invulnerable) == true then
				return
			end
			-- The universal relic lane (isRelicSourced): TakeDamage owns the
			-- indicator, the execute check and every universal multiplier.
			DamageService:TakeDamage(player, humanoid, spikeDamage, false, false, false, true)
		end)
	end

	return 0
end
