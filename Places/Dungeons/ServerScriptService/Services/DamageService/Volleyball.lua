-- Volleyball: now does TWO things on ranged weapon attacks.
--   1) Always-on +25 damage bonus (immediate, returned as a number
--      so the orchestrator's totalDamage sum picks it up alongside
--      Linked Sword + friends).
--   2) Every 3rd hit, a delayed +150% spike (kept as the original
--      task.delay-into-humanoid:TakeDamage pattern so the spike VFX
--      lands a beat after the original hit).
--
-- Gating: ranged-only. isMagic = bail. isMelee = bail. Anything left
-- over is a ranged weapon hit. The relic's design moved from
-- weapon-wide to ranged-specific, which is why isMelee gets its own
-- early return.
--
-- Signature gained an isMelee param vs the prior implementation; the
-- orchestrator now passes both isMagic and isMelee through.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)

local RelicService
local DamageIndicatorService
local ArmorSetBonusService
local DamageService

local VOLLEY_BALL_DESYNC_DELAY = 0.5
local SPIKE_INTERVAL = 3

-- PRIVATE ranged-only hit counter. The orchestrator's shared _onHitRegistry
-- counts EVERY damage event — melee swings, magic hits, relic procs — so
-- reading it made "every 3rd ranged attack" fire on the 3rd damage event of
-- any type. A melee-and-gun player got spikes at effectively random points in
-- their gun's cadence, and a pure-magic player advanced the counter without
-- ever being able to trigger it. Same fix GeneralsFortyFive already carries
-- for its 6th-shot bonus.
--
-- Only incremented on hits that PASS the ranged gate below, so the first
-- spike lands exactly 3 ranged attacks after pickup.
local rangedHitCounts: { [number]: number } = {}

Players.PlayerRemoving:Connect(function(player: Player)
	rangedHitCounts[player.UserId] = nil
end)

Knit.OnStart():andThen(function()
	RelicService = Knit.GetService("RelicService")
	DamageIndicatorService = Knit.GetService("DamageIndicatorService")
	ArmorSetBonusService = Knit.GetService("ArmorSetBonusService")
	DamageService = Knit.GetService("DamageService")
end)

return function(
	player: Player,
	humanoid: Humanoid,
	damage: number,
	-- Kept in the signature so the orchestrator's call site stays unchanged,
	-- but deliberately UNUSED — see rangedHitCounts above for why the shared
	-- registry can't drive a "3rd ranged attack" cadence.
	_onhitRegistry: { [number]: number },
	isMagic: boolean,
	isMelee: boolean
)
	if isMagic then
		return 0
	end

	local volleyballEffect = RelicService:GetRelicEffect(player, RelicNames["Volleyball"]) or 1
	if volleyballEffect == 1 then
		return 0
	end

	-- The element rework dropped the flat Weapon Damage half -- the every-
	-- 3rd-hit spike is the whole relic now, and it stays ranged-only.
	if isMelee then
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

		RelicService.Client.OnVolleyballEffectActivated:FireAll(
			player.Character,
			humanoid.Parent,
			workspace:GetServerTimeNow(),
			0.5
		)

		task.delay(VOLLEY_BALL_DESYNC_DELAY, function()
			-- Re-check liveness — the original hit may have already
			-- brought the mob to 0 HP, in which case the spike is a
			-- no-op (don't show the indicator either).
			if humanoid.Health <= 0 or humanoid.Parent:GetAttribute(Attributes.Invulnerable) == true then
				return
			end
			DamageIndicatorService:ShowIndicator(player, humanoid.Parent, spikeDamage, false)
			humanoid:TakeDamage(spikeDamage)

			-- Direct-damage path (bypasses TakeDamage's exits). Kept wired to
			-- TryExecute, but the spike is not a Critical Hit so it passes no
			-- `wasCrit` and never executes -- correct under the crit-gated Ban
			-- Hammer. The call stays so a future crit-capable spike only needs
			-- to pass the flag.
			DamageService:TryExecute(player, humanoid)
		end)
	end

	return 0
end
