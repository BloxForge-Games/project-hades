--!strict
-- Volleyball: now does TWO things on ranged weapon attacks.
--   1) Always-on +25 damage bonus (immediate, returned as a number
--      so the orchestrator's totalDamage sum picks it up alongside
--      Linked Sword + friends).
--   2) Every 3rd hit, a delayed +150% spike (kept as the original
--      task.delay-into-humanoid:TakeDamage pattern so the spike VFX
--      lands a beat after the original hit).
--
-- Gating: gun shots only (the orchestrator's isGunShot, 2026-10-30; it
-- used to infer "ranged" as not-magic-and-not-melee, which let a
-- Sword-of-the-Epicredness spell count and spike).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local DamageIndicatorService = require(ServerScriptService.Services.DamageIndicatorService)
local ArmorSetBonusService = require(ServerScriptService.Submodules.Core.Source.Services.ArmorSetBonusService)
local DamageService = require(script.Parent)
local RelicNetwork = require(ServerScriptService.Submodules.Core.Source.Network.Relic)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)

type RelicSnapshot = DamageService.RelicSnapshot

local VOLLEY_BALL_DESYNC_DELAY = 0.5
local SPIKE_INTERVAL = 3

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

return function(player: Player, snapshot: RelicSnapshot, humanoid: Humanoid, damage: number, isGunShot: boolean)
	-- Ranged WEAPON attacks only: the orchestrator passes isGunShot (true
	-- for a bullet, Orinthian-converted or not; false for melee, spells and
	-- Epicredness-converted spells), so nothing else can advance the count.
	if not isGunShot then
		return 0
	end

	local volleyballEffect = DamageService.RelicEffect(snapshot, RelicNames["Volleyball"]) or 1
	if volleyballEffect == 1 then
		return 0
	end

	-- Every 3rd RANGED hit spikes. `damage` here is post-variance —
	-- TakeDamage rolled ±10% before fanning out, so the spike inherits
	-- the same roll via the multiplication (no double-rolling).
	local rangedCount = (rangedHitCounts[player.UserId] or 0) + 1
	rangedHitCounts[player.UserId] = rangedCount

	if rangedCount % SPIKE_INTERVAL == 0 then
		local spikeDamage = math.round(damage * volleyballEffect) - math.round(damage)

		-- Weapon Mastery set bonus: the spike is Weapon Damage (Ranged)
		-- per the relic description, but it lands via a direct
		-- humanoid:TakeDamage below (bypassing TakeDamage's amplifier
		-- sum), so the +10% has to be applied here explicitly. Returns 0
		-- when the set isn't active.
		spikeDamage += math.round(ArmorSetBonusService:GetWeaponDamageAmplifier(player, spikeDamage, false))

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
			DamageIndicatorService:ShowIndicator(player, humanoid.Parent :: Model, spikeDamage, false)
			humanoid:TakeDamage(spikeDamage)

			-- Direct-damage path (bypasses TakeDamage's exits), so it asks
			-- for Ban Hammer's execute itself: the spike is a weapon attack.
			DamageService:TryExecute(player, humanoid, false)
		end)
	end

	return 0
end
