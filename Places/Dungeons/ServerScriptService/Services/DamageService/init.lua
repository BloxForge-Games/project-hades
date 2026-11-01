--!strict
--[[
	Module: DamageService.lua
	Description:
	The damage pipeline, both directions.

	OUTGOING (TakeDamage) — the element-rework formula:

	    final = base
	            x (1 + Σ relic damage bonuses)      <- additive: modules +
	                                                   target-conditionals
	            x (1 + Σ target vulnerabilities)    <- Shock / Coil Shocked /
	                                                   Throwing Bolts / Paint
	            x crit multiplier (rolled)

	  Every relic bonus is ADDITIVE inside its sum; the three groups compose
	  multiplicatively. DoT ticks bypass all of it (isStatusConditionDamage)
	  and can never crit or roll appliers.

	INCOMING (PlayerTakeDamage): variance -> Susanoo -> Teddy Trap ->
	armor set -> poison weaken -> Slateskin -> Stonebound (the weapon
	enchantment, then the aura's) DR -> Flaming Orb
	-> shield absorb -> Space Sandwich proc -> ragdoll/lethal-clamp.
]]

--[ Roblox Services ]--

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

--[ Exports & Types & Defaults ]--

local RelicService = require(ServerScriptService.Services.RelicService)
local Breakable = require(ServerScriptService.Components.Breakable)
local PlayerStatsService = require(ServerScriptService.Submodules.Core.Source.Services.PlayerStatsService)
local ShieldService = require(ServerScriptService.Services.ShieldService)
local DamageIndicatorService = require(ServerScriptService.Services.DamageIndicatorService)
local PlayerEventService = require(ServerScriptService.Submodules.Core.Source.Services.PlayerEventService)
local RagdollService = require(ServerScriptService.Services.RagdollService)
local RunEscrowService = require(ServerScriptService.Services.RunEscrowService)
local TextIndicatorService = require(ServerScriptService.Submodules.Core.Source.Services.TextIndicatorService)
local LifeService = require(ServerScriptService.Services.LifeService)
local ArmorSetBonusService = require(ServerScriptService.Submodules.Core.Source.Services.ArmorSetBonusService)
local AuraService = require(ServerScriptService.Services.AuraService)
local ArcaneService = require(ServerScriptService.Services.ArcaneService)
local RelicNetwork = require(ServerScriptService.Submodules.Core.Source.Network.Relic)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local ArcaneData = require(ReplicatedStorage.Submodules.Core.Shared.Data.ArcaneData)
local ArcaneNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ArcaneNames)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local AuraNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.AuraNames)
local AuraData = require(ReplicatedStorage.Submodules.Core.Shared.Data.AuraData)
local StatusConditions = require(ReplicatedStorage.Submodules.Core.Shared.Enums.StatusConditions)
local getRelicLevel = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Player.getRelicLevel)
local getGunProcCoefficient = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Combat.getGunProcCoefficient)
local isEncounterEnemy = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Mob.isEncounterEnemy)
local getRoot = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Character.getRoot)
local forEachEnemyInRadius = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Combat.forEachEnemyInRadius)
local snapToGround = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Combat.snapToGround)
local MobData = require(ReplicatedStorage.Submodules.Core.Shared.Data.MobData)
local StatusConditionData = require(ReplicatedStorage.Submodules.Core.Shared.Data.StatusConditionData)
local RelicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicData)

-- Second-value reader. Relics whose card reads "base X, increased to Y"
-- keep X in the callback and Y in RelicData's `data` table, because a
-- callback returns exactly one number. Reading Y here rather than
-- redeclaring it as a local is what keeps the card and the code from
-- drifting -- four such constants used to live in this file.
local function relicData(relicName: string, field: string, fallback: number): number
	local entry = RelicData[relicName]
	local data = entry and entry.data
	return (data and data[field]) or fallback
end
local DamageIndicatorColors = require(ReplicatedStorage.Submodules.Core.Shared.Enums.DamageIndicatorColors)
local rollDamageVariance = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Damage.rollDamageVariance)
local Blitz = require(ReplicatedStorage.Submodules.Core.Shared.Blitz)

-- Knockback on regular mobs (MobSimService.ApplyKnockback), studs per
-- hit by what landed it. DoT / aura ticks never push (they return
-- before it); minibosses and bosses never move. Arcane covers every
-- hitbox burst (onHitboxDamage hands its centre over), relic bombs
-- included; "relic" is the rest of the relic procs.
-- 2026-10-27: melee 2 -> 2.5, arcane 3 -> 4, relic 1 -> 2.
-- 2026-10-30: melee 2.5 -> 1.5, arcane 4 -> 3, relic 2 -> 1.
local KNOCKBACK_MELEE_STUDS = 1.5
-- Bullets do not push (2026-10-25); below MobSimService's minimum.
local KNOCKBACK_BULLET_STUDS = 0
local KNOCKBACK_ARCANE_STUDS = 3
local KNOCKBACK_RELIC_STUDS = 1

-- The run's difficulty damage multiplier on mob hits; 1 outside a run.
-- DungeonService is reached at call time (this service is a consumer).
local function difficultyDamageMultiplier(): number
	local dungeonService = Blitz.OptionalService("DungeonService")
	if not dungeonService then
		return 1
	end
	-- The tier's multiplier x the floor's (DifficultyData's damage growth).
	return dungeonService:GetDifficultyScale().enemyDamage * dungeonService:GetFloorMultiplier("damage")
end

-- The attacker's owned relics for ONE hit, from RelicService (re-exported
-- so the on-hit modules can name it without their own RelicService import).
export type RelicSnapshot = RelicService.RelicSnapshot

-- The target's status picture for ONE hit, resolved once in TakeDamage and
-- handed to the conditional-bonus and crit resolvers, which used to each
-- re-derive it (three family lookups plus the distinct-status count).
export type TargetStatuses = {
	isBurning: boolean,
	isPoisoned: boolean,
	isShocked: boolean,
	isChilled: boolean,
	statusCount: number,
}

-- A one-shot guaranteed crit a relic armed (ForceNextCrit): when it lapses
-- unspent, and what to do to the target as it is spent.
type ForcedCrit = { expiresAt: number?, onHit: ((targetModel: Model) -> ())? }

local DamageService = {
	Name = "DamageService",
	Dependencies = {
		PlayerEventService,
		DamageIndicatorService,
		TextIndicatorService,
		RagdollService,
		ArmorSetBonusService,
	} :: { any },

	_onDamageModules = {} :: { [string]: any },
	-- Lightning Horn / Shuriken fan-out latches: [userId] = os.clock() of the last proc.
	_lightningStrikeLast = {} :: { [number]: number },
	-- [userId] = true while that player's Lightning Strike deals its damage,
	-- so the strike's own hits cannot roll another.
	_lightningStrikeResolving = {} :: { [number]: boolean },
	_shurikenLastRefund = {} :: { [number]: number },
	-- Lightning Horn's crit Stormcharged extension latch: [userId] = os.clock().
	_stormExtendLast = {} :: { [number]: number },
	-- Rolling per-player log of damage that actually reached HEALTH (post
	-- shield / post-mitigation) — Astral Cloak's dodge heal consumes it.
	_recentDamageTaken = {} :: { [number]: { { t: number, amount: number } } },
	-- Forced crits (2026-11-01): [userId][lane] = the one-shot a relic armed
	-- (ForceNextCrit). "Melee" is spent by the next melee weapon hit,
	-- "Arcane" by the next spell / arcane hit; TakeDamage consumes them.
	_forcedCrits = {} :: { [number]: { [string]: ForcedCrit } },
}

-- StatusConditionService requires this module at load (its DoT ticks land
-- through TakeDamage), so this side reaches it lazily: required on first
-- use, once both modules exist.
local statusConditionService: any = nil
local function getStatusConditionService(): any
	if statusConditionService == nil then
		-- A require inside a function is opaque to the analyzer, so the
		-- table is `any` here.
		statusConditionService = (require :: any)(ServerScriptService.Services.StatusConditionService)
	end
	return statusConditionService
end

--[ Constants ]--

-- Baseline crit chance every hit has before any relic or aura.
-- 5 -> 10 (2026-11-01): with guaranteed crits in every tree, ordinary hits
-- crit often enough for the Critical Damage line to be felt.
local DEFAULT_CRITICAL_CHANCE = 10
-- x1.5 -> x1.75 (2026-10-28) so crit chance is worth taking.
local DEFAULT_CRITICAL_MULTIPLIER = 1.75
local RESISTED_COLOR3 = DamageIndicatorColors.Resisted
local MAGIC_COLOR3 = DamageIndicatorColors.Arcane
local WEAPON_COLOR3 = DamageIndicatorColors.Weapon
local RAGDOLL_VELOCITY = 25

-- Status attributes stamped on mob models by getStatusConditionService().
-- Direct reads are fine for single statuses; the FAMILY questions ("is it
-- burning / poisoned / shocked") must go through getStatusConditionService()'s
-- IsBurning / IsPoisoned / IsShocked — the upgraded variants (Black Flame,
-- Death Venom, Coil Shocked) stamp their own attributes.
local STATUS_ATTRIBUTE_PREFIX = "Status"

-- Ceiling on Greater Shrine "Bulwark": nothing stacks it today (one
-- blessing per run), but a per-floor exclusion rule later would, and
-- damage immunity should never be reachable from a free pickup.
local GREATER_SHRINE_MAX_REDUCTION = 0.60
-- The most ALL reductions together may take off a mob hit (2026-10-31):
-- Slateskin, Stonebound, the gear lines, the set bonus and the shrine
-- multiply freely up to here, never to immunity.
local MAX_TOTAL_DAMAGE_REDUCTION = 0.75

-- Flaming Orb of Divine Pain (Cursed): +50% damage TAKEN while any of
-- these auras is up -- the price of doubling their base effects. The
-- numbers are the relic's `data` (auraScale, damageTakenBonus).
local FLAMING_ORB_AURA_MARKERS = {
	AuraNames.Enflamed,
	AuraNames.Frostburst,
	AuraNames.Blighted,
	AuraNames.Stormcharged,
	AuraNames.Stonebound,
}

-- Dragon Lantern (Cursed): every hit that reaches HEALTH strips 10% of
-- the owner's unbanked run coins.
local DRAGON_LANTERN_TAX = 0.10

-- Storm tree crit riders (percentage points on the 0-100 roll / fractions
-- on the multiplier). Chances/fractions that live in relic callbacks are
-- read at the use site; these are the hardcoded halves.

-- Lightning Horn of the Heavens: a Critical Hit on a Shocked enemy calls
-- down a Lightning Strike (damage per level from the relic callback) in
-- this radius (see _tryLightningHornStrike). Latched so a strike never
-- chains another off its own damage.
local LIGHTNING_STRIKE_RADIUS = 11

-- Katana's crit-DAMAGE half (its callback carries the crit-chance half).
-- Keep in sync with the relic's card.

-- Shuriken of the Crescent Moon: a critical ATTACK on a Shocked enemy
-- refunds its callback's fraction of Maximum Mana (2026-10-30), fan-out
-- latched so an AoE crit refunds once.
local SHURIKEN_FANOUT_SECONDS = 0.1

-- 0.25 -> 0.5 (2026-10-30): guns kept a quarter against the Robombie,
-- the one Elite, which read as a dead weapon class on floors 2+.
local PROJECTILE_RESISTANCE_SCALAR = 0.5

-- Ceiling on the target-vulnerability factor (Shock, Coil Shocked and
-- Painted together), 2026-10-27.
local VULNERABILITY_CAP = 1.5

-- Every on-hit module name the hit path indexes by string. Checked once
-- at boot (Start) so a renamed or missing module file fails there rather
-- than on the first hit.
local REQUIRED_DAMAGE_MODULES = {
	"TeddyTrap",
	"Jail",
	"FluffyUnicorn",
	"MurderKnife",
	"MoreDamage",
	"FlatDamageRelics",
	"MysticalSigil",
	"LaserScythes",
	"AuraDamage",
	"Volleyball",
	"RangedRelics",
}

--[ Relic snapshot readers ]--

-- The hit path used to make ~80-100 RelicService calls per hit across the
-- on-hit modules and the two resolvers, each GetRelicEffect invoking the
-- relic callback again. One GetRelicSnapshot per hit replaces them; these
-- two readers are what the modules and resolvers use instead.
-- `live` entries (the hyperlasers — their callbacks read the owner's
-- current health) still resolve through RelicService on every read.

function DamageService.RelicCount(snapshot: RelicSnapshot, relicName: string): number
	local entry = snapshot.relics[relicName]
	return if entry then entry.count else 0
end

-- Same contract as RelicService:GetRelicEffect: the callback's value when
-- owned, `false` otherwise (callers `or` their default).
-- Flaming Orb of Divine Pain: how many times over the player's auras pay
-- their AuraData base (1 without the relic).
function DamageService.AuraScale(snapshot: RelicSnapshot): number
	if DamageService.RelicCount(snapshot, RelicNames["Flaming Orb of Divine Pain"]) <= 0 then
		return 1
	end
	return relicData(RelicNames["Flaming Orb of Divine Pain"], "auraScale", 2)
end

function DamageService.RelicEffect(snapshot: RelicSnapshot, relicName: string): any?
	local entry = snapshot.relics[relicName]
	if not entry then
		return false
	end
	if entry.live then
		return RelicService:GetRelicEffect(snapshot.player, relicName)
	end
	return entry.effect
end

-- The target's statuses as the hit path reads them (see TargetStatuses).
-- A nil target reads as "no statuses" so the crit resolver keeps its
-- optional-target contract.
function DamageService.GetTargetStatuses(_self: typeof(DamageService), targetModel: Model?): TargetStatuses
	local statuses: TargetStatuses = {
		isBurning = false,
		isPoisoned = false,
		isShocked = false,
		isChilled = false,
		statusCount = 0,
	}
	if not targetModel then
		return statuses
	end

	local statusService = getStatusConditionService()
	if statusService then
		statuses.isBurning = statusService:IsBurning(targetModel)
		statuses.isPoisoned = statusService:IsPoisoned(targetModel)
		statuses.isShocked = statusService:IsShocked(targetModel)
	end
	statuses.isChilled = targetModel:GetAttribute(STATUS_ATTRIBUTE_PREFIX .. StatusConditions.Chill) == true

	-- Distinct-status count, shared by the per-status payoffs. The
	-- attribute is "at least one instance", so a mob burned by three
	-- players still counts Burn once; every upgraded variant (Black Flame,
	-- Death Venom, Coil Shocked) stamps its own attribute and therefore
	-- counts as its own status.
	for _, status in StatusConditions do
		if
			status ~= StatusConditions.None
			and targetModel:GetAttribute(STATUS_ATTRIBUTE_PREFIX .. (status :: string)) == true
		then
			statuses.statusCount += 1
		end
	end

	return statuses
end

--[ Public Functions ]--

-- `fixedDamage` means the caller has already decided the exact number
-- and nothing may scale it: no variance, no relic reduction, no set
-- bonus, no aura. For hazards whose whole design is a KNOWN fraction of
-- the victim (the spike trap's 20% of max health, where five steps must
-- kill anyone), a mitigated hit would quietly turn that into six or ten
-- depending on their build.
--
-- The shield pool still spends against it. A shield is a resource being
-- consumed, not a modifier scaling the hit, so it stays in play.
function DamageService.PlayerTakeDamage(
	self: typeof(DamageService),
	player: Player,
	model: Model,
	damage: number,
	canRagdoll: boolean,
	fixedDamage: boolean?
)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")

	if not character or not humanoid then
		warn("[DamageService] Player or humanoid not found for player:", player.Name)
		return
	end

	-- Already in the 10s revive window (or fully dead and spectating) —
	-- absorb the hit silently.
	if character:GetAttribute(Attributes.Death) == true then
		return
	end

	if character:GetAttribute(Attributes.Invulnerable) == true then
		local head = character:FindFirstChild("Head")
		if head and head:IsA("BasePart") then
			TextIndicatorService:ShowIndicator(player, head, "Invulnerable!")
		end
		return
	end

	-- Held so the modifier block below can be UNDONE in one line for a
	-- fixedDamage hit. Restoring afterwards rather than wrapping fifty
	-- lines of relic and aura maths in a conditional: every one of those
	-- reads state and none of them writes any, so letting them compute a
	-- number that is then discarded costs nothing and leaves the block
	-- readable as one continuous mitigation pipeline.
	local fixedAmount = if fixedDamage then damage else nil

	-- Difficulty (DifficultyData): every mob hit scales with the run's tier.
	damage *= difficultyDamageMultiplier()

	-- ±10% variance on every mob → player hit. Keep intermediate values as
	-- floats; the final humanoid:TakeDamage below rounds once.
	damage = rollDamageVariance(damage)
	-- What the reductions below work from, for the total cap after them.
	local mitigationBase = damage

	-- Susanoo Armor: its damageReduction (ArcaneData, shown on the card).
	if character:GetAttribute(Attributes.SusanooEnabled) == true then
		local susanoo = ArcaneData[ArcaneNames["Susanoo Armor"]]
		damage = damage * (1 - (susanoo and susanoo.damageReduction or 0))
	end

	-- Teddy Trap (incoming side): +100% damage taken if owned. Callback
	-- returns 2.0; nil → 1 (no-op when not owned). Its lifesteal half is
	-- TeddyTrap.lua; its heal block is DropService's health-orb branch.
	damage = damage * (RelicService:GetRelicEffect(player, RelicNames["Teddy Trap"]) or 1)

	-- Protection set bonus (all 3 Enforcer pieces): −10% damage taken.
	damage = damage * ArmorSetBonusService:GetDamageTakenMultiplier(player)

	-- Poison weaken: additive per poison/noxious STACK on the attacking mob,
	-- capped — per-player state the attribute can't express, so this reads
	-- the service (1 when unpoisoned).
	if model then
		damage = damage * getStatusConditionService():GetPoisonWeakenMultiplier(model)
	end

	-- Slateskin Potion (Cursed): +50% Damage Reduction, unconditional (the
	-- callback owns the 0.50 multiplier).
	if RelicService:GetSpecificRelicRegistry(player, RelicNames["Slateskin Potion"]) > 0 then
		damage = damage * (RelicService:GetRelicEffect(player, RelicNames["Slateskin Potion"]) or 1)
	end

	-- Gear lines (BonusStatData "DamageReduction"): the worn armor's summed
	-- fraction, one multiplier.
	damage = damage * (1 - PlayerStatsService:GetGearStat(player, "DamageReduction"))

	-- Stonebound: its damage reduction (plus the owner's Leland rider), read
	-- straight off the marker's replicated payload.
	local stoneboundReduction = 0
	if AuraService then
		local _, payloadReduction = AuraService:GetStoneboundPayload(character)
		stoneboundReduction = payloadReduction
	end

	-- Flaming Orb of Divine Pain (Cursed): while ANY aura is up, +50% damage
	-- taken, SUBTRACTED from the Stonebound reduction (one sum, not two
	-- multipliers); its doubled Stonebound adds the aura's base once more.
	-- So 30% -> 60% reduction - 50% = 10% less damage while Stonebound.
	local orbPenalty = 0
	if RelicService:GetSpecificRelicRegistry(player, RelicNames["Flaming Orb of Divine Pain"]) > 0 then
		local auraHrp = getRoot(character)
		if auraHrp then
			for _, markerName in FLAMING_ORB_AURA_MARKERS do
				if auraHrp:FindFirstChild(markerName) then
					orbPenalty = relicData(RelicNames["Flaming Orb of Divine Pain"], "damageTakenBonus", 0.50)
					break
				end
			end
		end
		if stoneboundReduction > 0 then
			local scale = relicData(RelicNames["Flaming Orb of Divine Pain"], "auraScale", 2)
			stoneboundReduction += (AuraData[AuraNames.Stonebound].damageReduction or 0) * (scale - 1)
		end
	end
	if stoneboundReduction > 0 or orbPenalty > 0 then
		damage = damage * math.max(1 - stoneboundReduction + orbPenalty, 0)
	end

	-- Greater Shrine "Bulwark". Deliberately ABOVE the fixedDamage
	-- override, so a trap's flat percentage still ignores it exactly as
	-- it ignores every other mitigation. Capped so a future stack can
	-- never reach immunity.
	local bulwark = PlayerStatsService:GetGreaterShrineEffect(player, "DamageReduction")
	if bulwark > 0 then
		damage = damage * (1 - math.min(bulwark, GREATER_SHRINE_MAX_REDUCTION))
	end

	-- The total cap (MAX_TOTAL_DAMAGE_REDUCTION): whatever the chain above
	-- multiplied down to, at least this share of the hit lands.
	damage = math.max(damage, mitigationBase * (1 - MAX_TOTAL_DAMAGE_REDUCTION))

	-- Everything above is discarded for a fixedDamage hit (see the top of
	-- this function): the caller's number is the number.
	if fixedAmount then
		damage = fixedAmount
	end

	-- Shield pool spends LAST, against the fully mitigated number.
	damage = ShieldService:AbsorbShieldDamage(player, damage)
	-- Space Sandwich: a hit taken while Stonebound grants a Barrier (after
	-- the absorb, so it guards the NEXT hit, not this one).
	ShieldService:TrySpaceSandwichBarrier(player)
	-- Cheezburger: any hit taken grants a Barrier, on its own cooldown.
	ShieldService:TryPebblePouchBarrier(player)
	-- Golem's Hammer (2026-10-31): any hit taken grants its Barrier, on its
	-- own cooldown.
	ShieldService:TryGolemBarrier(player)

	local rootPart = getRoot(character)
	if rootPart then
		local mobHit: Sound = (rootPart:FindFirstChild("ZombieHit") :: Sound?)
			or ReplicatedStorage.GameAssets.Sounds.ZombieHit:Clone()
		if mobHit.Parent ~= rootPart then
			mobHit.Parent = rootPart
		end
		mobHit.TimePosition = 0.2
		mobHit:Play()

		local hitVFX: Instance = rootPart:FindFirstChild("HitFXNew")
			or ReplicatedStorage.GameAssets.VFX.SwordSlash.HitFXNew:Clone()
		if hitVFX.Parent ~= rootPart then
			hitVFX.Parent = rootPart
		end

		for _, particle in hitVFX:GetChildren() do
			if not particle:IsA("ParticleEmitter") then
				continue
			end

			particle:Emit(2)
		end
	end

	-- Fully absorbed: the hit feedback above still plays, but a shielded
	-- player neither ragdolls nor loses health.
	if damage <= 0 then
		return
	end

	-- Dragon Lantern's Gems + Coins tax — health damage only.
	if RelicService:GetSpecificRelicRegistry(player, RelicNames["Dragon Lantern"]) > 0 then
		RunEscrowService:TaxCurrencies(player, DRAGON_LANTERN_TAX)
	end

	local ragdollTrigger = character:FindFirstChild("RagdollTrigger")
	local characterRoot = getRoot(character)
	local attackerRoot = getRoot(model)
	if
		canRagdoll
		and ragdollTrigger
		and ragdollTrigger:IsA("BoolValue")
		and ragdollTrigger.Value == false
		and characterRoot
		and attackerRoot
	then
		if character:GetAttribute(Attributes.SuperArmor) == false then
			RagdollService:Ragdoll(character)

			local direction = (attackerRoot.Position - characterRoot.Position).Unit

			local bodyVelocity = Instance.new("BodyVelocity")
			bodyVelocity.MaxForce = Vector3.new(math.huge, math.huge, math.huge)
			bodyVelocity.Velocity = -(direction * RAGDOLL_VELOCITY) + Vector3.new(0, RAGDOLL_VELOCITY, 0)
			bodyVelocity.Parent = characterRoot

			Debris:AddItem(bodyVelocity, 0.15)

			task.delay(1.5, function()
				RagdollService:Unragdoll(character)
			end)
		end
	end

	-- Lethal-damage clamp: never let Humanoid.Health hit 0. Round DAMAGE
	-- first, then compare and apply using the same value; `< 1`, NOT
	-- `<= 0`, because health can be fractional while applied damage is
	-- rounded — the design promise is you always END at exactly 1.
	local appliedDamage = math.round(damage)
	-- Log for Astral Cloak's dodge heal BEFORE the lethal branch.
	self:_recordDamageTaken(player, appliedDamage)
	if LifeService and humanoid.Health - appliedDamage < 1 then
		humanoid.Health = 1
		LifeService:LoseLife(player)
		return
	end

	humanoid:TakeDamage(appliedDamage)
end

-- Astral Cloak's heal source. Every hit that reaches health appends here;
-- ConsumeRecentDamageTaken sums the trailing window THEN CLEARS the log.
local RECENT_DAMAGE_KEEP_SECONDS = 5 -- write-time prune ceiling

function DamageService._recordDamageTaken(self: typeof(DamageService), player: Player, amount: number)
	if amount <= 0 then
		return
	end

	local log = self._recentDamageTaken[player.UserId]
	if not log then
		log = {}
		self._recentDamageTaken[player.UserId] = log
	end

	local now = tick()
	for i = #log, 1, -1 do
		if now - log[i].t > RECENT_DAMAGE_KEEP_SECONDS then
			table.remove(log, i)
		end
	end

	table.insert(log, { t = now, amount = amount })
end

-- Sum of damage taken in the trailing `windowSeconds`, then the whole log
-- is cleared (consume-on-use).
function DamageService.ConsumeRecentDamageTaken(
	self: typeof(DamageService),
	player: Player,
	windowSeconds: number
): number
	local log = self._recentDamageTaken[player.UserId]
	if not log then
		return 0
	end

	local now = tick()
	local total = 0
	for _, entry in log do
		if now - entry.t <= windowSeconds then
			total += entry.amount
		end
	end

	self._recentDamageTaken[player.UserId] = nil
	return total
end

-- Ban Hammer (Legendary, 2026-10-30): an ATTACK hit that leaves an enemy
-- at/below its execute line (data.executeThreshold; data.encounterThreshold
-- on Minibosses and Bosses) brings the Ban Hammer down on it: every client
-- drops the hammer model (GimmickEffect "BanHammer"), and when it lands
-- the target dies and everything within data.slamRadius takes per-level
-- damage (its stun and "Banned!" text left 2026-10-30). Bursts and DoT
-- ticks (relic-sourced) never execute.
-- PUBLIC: bypass damage paths (Volleyball's delayed spike) call it too.
function DamageService.TryExecute(
	self: typeof(DamageService),
	player: Player,
	humanoid: Humanoid,
	isRelicSourced: boolean?
)
	if isRelicSourced then
		return
	end
	if RelicService:GetSpecificRelicRegistry(player, RelicNames["Ban Hammer"]) <= 0 then
		return
	end

	local model = humanoid.Parent
	if not model or not model:IsA("Model") or model:GetAttribute("BanHammerExecuted") then
		return
	end
	if humanoid.Health <= 0 or humanoid.MaxHealth <= 0 then
		return
	end
	local threshold = if isEncounterEnemy(model)
		then relicData(RelicNames["Ban Hammer"], "encounterThreshold", 0.05)
		else relicData(RelicNames["Ban Hammer"], "executeThreshold", 0.2)
	if (humanoid.Health / humanoid.MaxHealth) > threshold then
		return
	end
	local root = getRoot(model)
	if not root then
		return
	end

	-- Guard against a same-frame second damage path executing it twice.
	model:SetAttribute("BanHammerExecuted", true)
	local fallSeconds = relicData(RelicNames["Ban Hammer"], "fallSeconds", 0.35)
	local radius = relicData(RelicNames["Ban Hammer"], "slamRadius", 10)
	local slamPosition = snapToGround(root.Position) or root.Position
	RelicNetwork.GimmickEffect.FireAll({
		Kind = "BanHammer",
		Caster = player,
		From = slamPosition,
		To = slamPosition,
		Radius = radius,
		Duration = fallSeconds,
		StartTime = workspace:GetServerTimeNow(),
	})

	task.delay(fallSeconds, function()
		if humanoid.Parent and humanoid.Health > 0 then
			humanoid:TakeDamage(humanoid.Health)
		end
		local slamDamage =
			math.round((RelicService:GetRelicEffect(player, RelicNames["Ban Hammer"]) or 0) * getRelicLevel(player))
		Breakable.HitInRadius(slamPosition, radius, player)
		forEachEnemyInRadius(slamPosition, radius, function(other: Model, otherHumanoid: Humanoid)
			if other == model then
				return
			end
			if slamDamage > 0 then
				self:WithRelicKnockback(function()
					self:TakeDamage(player, otherHumanoid, slamDamage, false, false, nil, true)
				end)
			end
		end)
	end)
end

-- Runs `fn` with relic knockback: TakeDamage calls inside it push only
-- KNOCKBACK_RELIC_STUDS. The relic gimmicks' typed hits (melee waves,
-- arcane orbs) go through here, since their lanes would otherwise carry
-- weapon / spell knockback.
DamageService._relicPushDepth = 0
function DamageService.WithRelicKnockback(_self: typeof(DamageService), fn: () -> ())
	DamageService._relicPushDepth += 1
	local ok, err: any = pcall(fn :: any)
	DamageService._relicPushDepth -= 1
	if not ok then
		error(err, 0)
	end
end

--[ Forced crits ]--

-- Arms a one-shot guaranteed Critical Strike for `player` (2026-11-01):
-- the next damage instance on `lane` -- "Melee" (a melee weapon hit,
-- isMelee) or "Arcane" (a spell or other arcane hit, isMagic) -- rolls its
-- crit at 100, and the arm is spent. Relic bursts (the untyped lane) and
-- the gimmicks' own typed hits (made under WithRelicKnockback: Flame Wave,
-- the frost orbs) never consume it, so the Flaming Bo Staff's Nth weapon
-- hit and the Katana's next spell hit are exactly the hits that crit.
-- `seconds` lapses an unspent arm (nil = until spent); `onHit` runs with
-- the target as the arm is spent, before the damage lands, for the status
-- the relic rides on the crit. Re-arming a lane replaces its arm.
function DamageService.ForceNextCrit(
	self: typeof(DamageService),
	player: Player,
	lane: "Melee" | "Arcane",
	seconds: number?,
	onHit: ((targetModel: Model) -> ())?
)
	local lanes = self._forcedCrits[player.UserId] or {}
	self._forcedCrits[player.UserId] = lanes
	lanes[lane] = {
		expiresAt = if seconds then os.clock() + seconds else nil,
		onHit = onHit,
	}
end

-- Drops an unspent arm on `lane`.
function DamageService.ClearForcedCrit(self: typeof(DamageService), player: Player, lane: "Melee" | "Arcane")
	local lanes = self._forcedCrits[player.UserId]
	if lanes then
		lanes[lane] = nil
	end
end

-- The live arm on `lane`, if any (a lapsed one is dropped here).
function DamageService._liveForcedCrit(self: typeof(DamageService), player: Player, lane: string): ForcedCrit?
	local lanes = self._forcedCrits[player.UserId]
	local arm = if lanes then lanes[lane] else nil
	if not arm then
		return nil
	end
	if arm.expiresAt and os.clock() >= arm.expiresAt then
		lanes[lane] = nil
		return nil
	end
	return arm
end

-- True while `player` has an unspent arm on `lane`.
function DamageService.HasForcedCrit(self: typeof(DamageService), player: Player, lane: "Melee" | "Arcane"): boolean
	return self:_liveForcedCrit(player, lane) ~= nil
end

-- Spends the arm this hit matches -- Melee for a melee hit, else Arcane for
-- an arcane one -- and returns it, or nil when none is up.
function DamageService._consumeForcedCrit(
	self: typeof(DamageService),
	player: Player,
	isMelee: boolean,
	isMagic: boolean
): ForcedCrit?
	local lanes = self._forcedCrits[player.UserId]
	if not lanes then
		return nil
	end
	local lane: string? = if isMelee and self:_liveForcedCrit(player, "Melee")
		then "Melee"
		elseif isMagic and self:_liveForcedCrit(player, "Arcane") then "Arcane"
		else nil
	if not lane then
		return nil
	end
	local arm = lanes[lane]
	lanes[lane] = nil
	return arm
end

-- Pushes a regular sim mob away from the hit (see KNOCKBACK_*). Called
-- once per landed hit, before the damage branches split, with the hit's
-- kind read BEFORE any conversion flips it.
function DamageService._knockback(
	_self: typeof(DamageService),
	player: Player,
	targetModel: Model,
	isMelee: boolean,
	isGunShot: boolean,
	isArcane: boolean,
	hitOrigin: Vector3?
)
	-- Relic hits push only KNOCKBACK_RELIC_STUDS (2026-10-30), typed gimmick
	-- hits included (RelicGimmickService routes them through
	-- WithRelicKnockback, which would otherwise carry a weapon / spell push).
	local relicPush = DamageService._relicPushDepth > 0
	if isEncounterEnemy(targetModel) then
		return
	end
	local mobSimService = Blitz.OptionalService("MobSimService")
	if not mobSimService then
		return
	end
	local character = player.Character
	local attackerRoot = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local attackerAt = attackerRoot and attackerRoot.Position
	local origin = hitOrigin or attackerAt
	if not origin then
		return
	end
	local distance = if relicPush
		then KNOCKBACK_RELIC_STUDS
		elseif isMelee then KNOCKBACK_MELEE_STUDS
		elseif isArcane then KNOCKBACK_ARCANE_STUDS
		elseif isGunShot then KNOCKBACK_BULLET_STUDS
		else KNOCKBACK_RELIC_STUDS
	mobSimService:ApplyKnockback(targetModel, origin, distance, attackerAt)
end

-- Post-damage hub — runs after EVERY damage application inside TakeDamage:
-- weapon, arcane, relic bursts and DoT ticks.
function DamageService._postDamage(
	self: typeof(DamageService),
	player: Player,
	humanoid: Humanoid,
	wasCrit: boolean?,
	isRelicSourced: boolean?,
	isGunShot: boolean?,
	isMelee: boolean?,
	isMagic: boolean?,
	-- What the hit dealt (after crit and resistance), for the gimmicks
	-- that pay a share of it.
	dealt: number?
)
	self:TryExecute(player, humanoid, isRelicSourced)

	-- A bullet rolls the chance relics below at its gun's proc
	-- coefficient; everything else at 1.
	local procCoefficient = if isGunShot then getGunProcCoefficient(player) else 1

	-- Lightning Orb rolls on EVERY hit now, not just crits — `wasCrit` only
	-- selects which of its two chances applies.
	self:_tryLightningOrbStormcharge(player, wasCrit, procCoefficient)

	-- "All damage" relics (2026-10-25): every damage instance rolls them.
	self._onDamageModules["Jail"](player, humanoid, procCoefficient, isMagic == true)
	-- Lightning Horn (2026-10-31; crits only before): ANY damage instance
	-- has data.strikeChance (arcaneStrikeChance on a spell) to call a strike
	-- (data.cooldown paces it). 2026-11-01: a Critical Strike ALWAYS calls
	-- one when data.critAlways is set, the same cooldown pacing it.
	local hornChance = relicData(
		RelicNames["Lightning Horn of the Heavens"],
		if isMagic == true then "arcaneStrikeChance" else "strikeChance",
		0.2
	)
	local hornRow: any = RelicData[RelicNames["Lightning Horn of the Heavens"]]
	local hornCritAlways = hornRow ~= nil and hornRow.data ~= nil and hornRow.data.critAlways == true
	if (wasCrit and hornCritAlways) or math.random() < hornChance then
		self:_tryLightningHornStrike(player, humanoid)
	end

	if wasCrit then
		self:_tryShurikenManaRefund(player, humanoid)
		self:_tryNinjaWhipShock(player, humanoid)
		local targetModel = humanoid.Parent
		local gimmicks = Blitz.OptionalService("RelicGimmickService")
		if gimmicks and targetModel and targetModel:IsA("Model") then
			gimmicks:OnCrit(player, targetModel, isMelee, dealt or 0, isGunShot == true)
		end
	end

	-- Every ATTACK hit -- weapon or spell, not a relic burst or a DoT tick
	-- (both relic-sourced) -- for the on-hit gimmicks (Katana's Chain
	-- Lightning). Relic bolts are relic-sourced, so they never re-trigger.
	if not isRelicSourced then
		local targetModel = humanoid.Parent
		local gimmicks = Blitz.OptionalService("RelicGimmickService")
		if gimmicks and targetModel and targetModel:IsA("Model") then
			gimmicks:OnAttackHit(player, targetModel, isMagic == true)
			-- The ranged relics (2026-10-30): every gun shot that lands.
			if isGunShot then
				gimmicks:OnRangedHit(player, targetModel, dealt or 0, wasCrit == true)
			end
		end
	end
end

-- Lightning Orb (Storm Rare): ANY damage — weapon or arcane, per TARGET (an
-- AoE hitting three mobs rolls three times), relic procs included — has a
-- chance to grant Stormcharged. TWO TIERS: the callback's base normally,
-- and this when the hit CRIT. "increased to", so they replace each other
-- rather than stacking. Deliberately UNLATCHED, per the design call.
-- Routed through SetAura, so the Abyss lockout and duration bonuses apply
-- for free.

function DamageService._tryLightningOrbStormcharge(
	_self: typeof(DamageService),
	player: Player,
	wasCrit: boolean?,
	procCoefficient: number?
)
	if not AuraService or RelicService:GetSpecificRelicRegistry(player, RelicNames["Lightning Orb"]) <= 0 then
		return
	end
	local character = player.Character
	if not character then
		return
	end
	local chance = if wasCrit
		then relicData(RelicNames["Lightning Orb"], "critChance", 0.20)
		else RelicService:GetRelicEffect(player, RelicNames["Lightning Orb"]) or 0
	chance *= procCoefficient or 1
	if chance > 0 and math.random() <= chance then
		AuraService:SetAura(player, AuraNames.Stormcharged, character)
	end
end

-- Ninja Whip (Storm bridge Rare): while its owner is Stormcharged, a
-- Critical Hit Shocks its target (Deluxe Coil Gun's redirect included,
-- through ApplyStatus). Relic bursts and DoT ticks never crit, so only
-- weapon and spell hits reach this.
function DamageService._tryNinjaWhipShock(_self: typeof(DamageService), player: Player, humanoid: Humanoid)
	if RelicService:GetSpecificRelicRegistry(player, RelicNames["Ninja Whip"]) <= 0 then
		return
	end
	local hrp = getRoot.fromPlayer(player)
	if not hrp or not hrp:FindFirstChild(AuraNames.Stormcharged) then
		return
	end
	local targetModel = humanoid.Parent
	if targetModel and targetModel:IsA("Model") and getStatusConditionService() then
		getStatusConditionService():ApplyStatus(player, targetModel, StatusConditions.Shock)
	end
end

-- Lightning Horn of the Heavens (Legendary), THUNDERLORD (2026-10-31): any
-- damage instance has data.strikeChance to call down a Lightning Strike,
-- at most once per data.cooldown -- per-level damage from the relic
-- callback, in a radius, every enemy inside, each Shocked. The strike
-- rolls its OWN crit (it rides the untyped lane, which never crits). The
-- resolving latch stops a strike's own damage chaining another.
function DamageService._tryLightningHornStrike(self: typeof(DamageService), player: Player, humanoid: Humanoid)
	if self._lightningStrikeResolving[player.UserId] then
		return
	end
	if RelicService:GetSpecificRelicRegistry(player, RelicNames["Lightning Horn of the Heavens"]) <= 0 then
		return
	end

	local targetModel = humanoid.Parent
	if not targetModel then
		return
	end

	local hrp = getRoot(targetModel)
	if not hrp then
		return
	end

	-- The once-per-cooldown latch (also collapses an AoE crit to one).
	local now = os.clock()
	local lastStrike = self._lightningStrikeLast[player.UserId]
	if lastStrike and (now - lastStrike) < relicData(RelicNames["Lightning Horn of the Heavens"], "cooldown", 1) then
		return
	end
	self._lightningStrikeLast[player.UserId] = now

	local damagePerLevel = RelicService:GetRelicEffect(player, RelicNames["Lightning Horn of the Heavens"]) or 0
	local strikeDamage = math.round(damagePerLevel * getRelicLevel(player))
	if strikeDamage <= 0 then
		return
	end
	local critChance, critMultiplier =
		self:GetCritParameters(player, false, false, if targetModel:IsA("Model") then targetModel else nil)
	if math.random() * 100 <= critChance then
		strikeDamage = math.round(strikeDamage * critMultiplier)
	end

	-- Ground the strike under the target so the bolt lands on the floor.
	local strikePosition = snapToGround(hrp.Position) or hrp.Position

	RelicNetwork.LightningStrikeEffect.FireAll(strikePosition)

	self._lightningStrikeResolving[player.UserId] = true
	-- Relic damage breaks breakables too.
	Breakable.HitInRadius(strikePosition, LIGHTNING_STRIKE_RADIUS, player)
	forEachEnemyInRadius(strikePosition, LIGHTNING_STRIKE_RADIUS, function(model, targetHumanoid)
		-- Full pipeline, relic-sourced: amp chain and crit roll apply, but
		-- the resolving latch keeps it from triggering ANOTHER strike, and
		-- the appliers roll per target like any relic arcane.
		-- isMagic = false: the strike rides the untyped relic lane; a
		-- arcane flag would wrongly pick up Painted's arcane vulnerability.
		self:TakeDamage(player, targetHumanoid, strikeDamage, false, false, nil, true)
		if getStatusConditionService() then
			getStatusConditionService():ApplyStatus(player, model, StatusConditions.Shock)
			getStatusConditionService():ApplyArcaneOnHitStatuses(player, model)
		end
	end)
	self._lightningStrikeResolving[player.UserId] = nil
end

-- Shuriken of the Crescent Moon: refund 1% of Maximum Mana on a critical
-- ATTACK. Latched so one AoE crit refunds once.
function DamageService._tryShurikenManaRefund(self: typeof(DamageService), player: Player, humanoid: Humanoid)
	if RelicService:GetSpecificRelicRegistry(player, RelicNames["Shuriken of the Crescent Moon"]) <= 0 then
		return
	end
	local targetModel = humanoid.Parent
	local statusService = getStatusConditionService()
	if not targetModel or not statusService or not statusService:IsShocked(targetModel :: Model) then
		return
	end

	local now = os.clock()
	local lastRefund = self._shurikenLastRefund[player.UserId]
	if lastRefund and (now - lastRefund) < SHURIKEN_FANOUT_SECONDS then
		return
	end
	self._shurikenLastRefund[player.UserId] = now

	local arcaneData = ArcaneService:GetPlayerArcaneData(player)
	if not arcaneData or not arcaneData.maxMana or arcaneData.mana >= arcaneData.maxMana then
		return
	end

	local fraction = RelicService:GetRelicEffect(player, RelicNames["Shuriken of the Crescent Moon"]) or 0
	local restored = math.min(arcaneData.mana + arcaneData.maxMana * fraction, arcaneData.maxMana)
	ArcaneService:SetPlayerArcaneData(player, restored, arcaneData.maxMana)
end

-- The player's crit CHANCE (0-100) and crit MULTIPLIER for one hit.
-- Composition:
--   chance = 5 + Shuriken (+5) + Stormcharged (+15)
--            + Ninja Whip (+10 vs Shocked targets)
--   multiplier = 1.5 + Stormcharged (+0.15)
-- `targetModel` is optional — target-conditional rows skip without one.
-- `snapshot` / `statuses` are the per-hit tables TakeDamage already holds;
-- a caller without them gets them resolved here.
function DamageService.GetCritParameters(
	self: typeof(DamageService),
	player: Player,
	_isMagic: boolean?,
	_isMelee: boolean?,
	targetModel: Model?,
	snapshot: RelicSnapshot?,
	statuses: TargetStatuses?
): (number, number)
	local relics: RelicSnapshot = snapshot or RelicService:GetRelicSnapshot(player)
	local targetStatuses: TargetStatuses = statuses or self:GetTargetStatuses(targetModel)

	local critChance = DEFAULT_CRITICAL_CHANCE

	-- Greater Shrine "Precision". Pooled as a fraction like every other
	-- blessing; crit CHANCE is in points here, so x100.
	critChance += PlayerStatsService:GetGreaterShrineEffect(player, "CritChance") * 100
	-- Gear lines (BonusStatData "CritChance"): a fraction, so x100 too.
	critChance += PlayerStatsService:GetGearStat(player, "CritChance") * 100

	-- Silver Ninja Star: flat points, no gate (callback = points); its
	-- Critical Damage half, while Stormcharged, is in the multiplier block.
	if DamageService.RelicCount(relics, RelicNames["Silver Ninja Star"]) > 0 then
		critChance += DamageService.RelicEffect(relics, RelicNames["Silver Ninja Star"]) or 0
	end

	-- Shuriken of the Crescent Moon: flat +5 points, from `data` — its
	-- callback slot carries the crit-mana-refund fraction instead.
	if DamageService.RelicCount(relics, RelicNames["Shuriken of the Crescent Moon"]) > 0 then
		critChance += relicData(RelicNames["Shuriken of the Crescent Moon"], "critChanceBonus", 5)
	end

	-- Stormcharged, the weapon enchantment (2026-11-01 rules): points on
	-- every hit, both equipped weapons adding (PlayerStatsService).
	critChance += PlayerStatsService:GetEnchantmentStat(player, "CritChance")

	local casterHrp = getRoot.fromPlayer(player)
	local isStormcharged = casterHrp ~= nil and casterHrp:FindFirstChild(AuraNames.Stormcharged) ~= nil

	-- Stormcharged: crit chance while up (AuraData owns the number).
	if isStormcharged then
		critChance += (AuraData[AuraNames.Stormcharged].critChanceBonus or 0) * DamageService.AuraScale(relics)
	end

	local targetShocked = targetStatuses.isShocked

	-- Throwing Bolts vs Shocked targets (callback = percentage points).
	-- This slot used to be Ninja Whip's; the 2026-08 pass turned Ninja Whip
	-- into a takedown proc and moved the crit-chance role here.
	if targetShocked and DamageService.RelicCount(relics, RelicNames["Throwing Bolts"]) > 0 then
		critChance += DamageService.RelicEffect(relics, RelicNames["Throwing Bolts"]) or 0
	end

	local critMultiplier = DEFAULT_CRITICAL_MULTIPLIER

	-- Greater Shrine "Ferocity". Crit DAMAGE is already a fraction, so
	-- the pooled value adds as-is.
	critMultiplier += PlayerStatsService:GetGreaterShrineEffect(player, "CritDamage")
	-- Gear lines (BonusStatData "CritDamage"): the same additive fraction.
	critMultiplier += PlayerStatsService:GetGearStat(player, "CritDamage")

	-- Stormcharged itself is crit CHANCE only (AuraData); the crit-DAMAGE
	-- on its window is the relic riders below.
	if isStormcharged then
		-- Silver Ninja Star's Critical Damage half (2026-10-30: Stormcharged
		-- only; it was ungated).
		if DamageService.RelicCount(relics, RelicNames["Silver Ninja Star"]) > 0 then
			critMultiplier += relicData(RelicNames["Silver Ninja Star"], "stormCritDamage", 0.30)
		end
		-- Lightning Wand: the Rare crit-damage rider on the same window.
		if DamageService.RelicCount(relics, RelicNames["Lightning Wand"]) > 0 then
			critMultiplier += DamageService.RelicEffect(relics, RelicNames["Lightning Wand"]) or 0
		end
	end

	-- Crit chance past 100% is not wasted (2026-10-27): every point over
	-- becomes +1% Critical Damage, so a full crit build keeps scaling.
	if critChance > 100 then
		critMultiplier += (critChance - 100) / 100
		critChance = 100
	end

	return critChance, critMultiplier
end

-- The additive TARGET-CONDITIONAL relic bonuses for one hit, as a summed
-- FRACTION (joins the same additive pool as the damage modules).
-- `skipTyped` = the untyped relic lane: rows whose card names Weapon
-- or Magic damage are excluded (arcane-gated rows are already out via
-- isMagic = false; weapon-gated rows need the explicit skip).
function DamageService._sumTargetConditionalBonuses(
	_self: typeof(DamageService),
	player: Player,
	snapshot: RelicSnapshot,
	_targetModel: Model,
	statuses: TargetStatuses,
	isMagic: boolean?,
	skipTyped: boolean?
): number
	local bonus = 0

	local isBurning = statuses.isBurning
	local isPoisoned = statuses.isPoisoned
	local isChilled = statuses.isChilled

	-- Blaze payoffs (burning family — Black Flame counts).
	-- Fire Breathing Dragon Friend is WEAPON-only per its card.
	if
		isBurning
		and not isMagic
		and not skipTyped
		and DamageService.RelicCount(snapshot, RelicNames["Fire Breathing Dragon Friend"]) > 0
	then
		bonus += (DamageService.RelicEffect(snapshot, RelicNames["Fire Breathing Dragon Friend"]) or 1) - 1
	end

	-- Venom payoffs.
	if isPoisoned and DamageService.RelicCount(snapshot, RelicNames["Poisonous Butterfly"]) > 0 then
		bonus += (DamageService.RelicEffect(snapshot, RelicNames["Poisonous Butterfly"]) or 1) - 1
	end

	-- Frost payoffs. Frozen Flail is ARCANE-only per its card.
	if isChilled and isMagic and DamageService.RelicCount(snapshot, RelicNames["Frozen Flail"]) > 0 then
		bonus += (DamageService.RelicEffect(snapshot, RelicNames["Frozen Flail"]) or 1) - 1
	end

	-- Distinct-status count, shared by the two per-status payoffs (resolved
	-- once per hit in GetTargetStatuses).
	local statusCount = statuses.statusCount

	-- BLIGHTED: +15% damage, and +15% more per unique status on the target
	-- (AuraData owns both numbers; the flat half arrived 2026-10-31).
	-- Overseer's Battleaxe (2026-10-29) adds its own per-status rate below,
	-- always on.
	--
	-- Gated on the ATTACKER's aura, not on the target being Poisoned: the
	-- aura is what the card names. Damage-type agnostic.
	--
	-- WHAT COUNTS:
	--   * EVERY unique status, INCLUDING Poison — Venom's own status must
	--     not be the one thing that fails to feed its aura.
	--   * Every UPGRADED variant counts as its own status ON TOP of the
	--     base one, because each stamps a separate attribute: Burn +
	--     Black Flame is 2, Shock + Coil Shocked is 2.
	--   * Death Venom counts ONCE however many stacks are on the target
	--     — the attribute is "at least one instance", not a tally.
	local attackerHrp = getRoot.fromPlayer(player)
	if attackerHrp and attackerHrp:FindFirstChild(AuraNames.Blighted) then
		local blighted = AuraData[AuraNames.Blighted]
		local auraScale = DamageService.AuraScale(snapshot)
		bonus += (blighted.damagePercent or 0) * auraScale
		bonus += (blighted.damagePerUniqueStatus or 0) * auraScale * statusCount
	end
	-- Overseer's Battleaxe: +data.damagePerStatus per distinct status,
	-- no aura gate.
	if statusCount > 0 and DamageService.RelicCount(snapshot, RelicNames["Overseer's Battleaxe"]) > 0 then
		bonus += relicData(RelicNames["Overseer's Battleaxe"], "damagePerStatus", 0.10) * statusCount
	end

	local _ = isMagic -- damage-type-agnostic today; kept for future gates

	return bonus
end

-- The multiplicative TARGET-VULNERABILITY factor: what the mob's statuses
-- make it take extra, additively composed (+10% Shock +10% Coil Shocked
-- +5% Throwing Bolts = x1.25, never compounding), with Painted on top,
-- capped at VULNERABILITY_CAP so stacked debuffs cannot run away.
function DamageService._targetVulnerabilityMultiplier(
	_self: typeof(DamageService),
	player: Player,
	targetModel: Model,
	isMagic: boolean?,
	_statuses: TargetStatuses?
): number
	local vulnerability = 0

	local shockConfig = StatusConditionData[StatusConditions.Shock]
	local coilConfig = StatusConditionData[StatusConditions.CoilShocked]
	local shocked = targetModel:GetAttribute(STATUS_ATTRIBUTE_PREFIX .. StatusConditions.Shock) == true
	local coilShocked = targetModel:GetAttribute(STATUS_ATTRIBUTE_PREFIX .. StatusConditions.CoilShocked) == true

	if shocked then
		vulnerability += (shockConfig.incomingDamageMultiplier or 1) - 1
	end
	if coilShocked then
		vulnerability += (coilConfig.incomingDamageMultiplier or 1) - 1
	end

	-- Throwing Bolts used to ride the TARGET here as "+5% from all
	-- sources". The 2026-08 pass made it the attacker's crit-chance bonus
	-- vs Shocked enemies, which lives in the crit resolver instead.

	local multiplier = 1 + vulnerability

	-- Painted: +20% ARCANE damage from everyone (2026-10-31; the applier
	-- only before -- StatusConditionData's `applierOnly` keeps the seam).
	if isMagic and targetModel:GetAttribute(STATUS_ATTRIBUTE_PREFIX .. StatusConditions.Paint) == true then
		local paintConfig = StatusConditionData[StatusConditions.Paint]
		if
			not paintConfig.applierOnly
			or (
				getStatusConditionService()
				and getStatusConditionService():GetStatusSourcePlayer(targetModel, StatusConditions.Paint) == player
			)
		then
			multiplier *= paintConfig.incomingMagicDamageMultiplier or 1
		end
	end

	multiplier = math.min(multiplier, VULNERABILITY_CAP)

	-- Petrified (Medusa Head, 2026-10-30): its row's incoming multiplier,
	-- outside the cap like Melted.
	if targetModel:GetAttribute(STATUS_ATTRIBUTE_PREFIX .. StatusConditions.Petrified) == true then
		multiplier *= StatusConditionData[StatusConditions.Petrified].incomingDamageMultiplier or 1
	end

	-- Melted (Fire Breathing Friend, 2026-10-30): Burning and Poisoned with one
	-- of them from a Fire Breathing Friend owner. Outside the cap: it is the
	-- duo's whole payoff.
	if targetModel:GetAttribute(Attributes.Melted) == true then
		multiplier *= 1 + relicData(RelicNames["Fire Breathing Friend"], "meltedBonus", 0.40)
	end

	-- Blight, the weapon enchantment (2026-10-31): +15% to a target carrying
	-- ANY Status, every lane, outside the Shock cap like Petrified.
	return multiplier
end

-- GEAR in the ADDITIVE pool (2026-10-31), beside the relic modules: the
-- weapon enchantments and the gear lines (BonusStatData).
--   Weapon lane: Enflamed and the Weapon Damage lines of the weapon that
--   landed the hit (the melee or the gun slot).
--   Arcane lane: Frostburst and the Arcane Damage lines while equipped.
-- A spell Sword of the Epicredness made Weapon Damage is neither weapon's
-- hit; a shot Orinthian made Arcane reads as a spell here (isMagic already
-- flipped). Returns BONUS damage, like the modules.
function DamageService._gearDamageBonus(
	_self: typeof(DamageService),
	player: Player,
	damage: number,
	isMagic: boolean,
	isMelee: boolean,
	isConvertedSpell: boolean
): number
	-- Enchantment stats (2026-11-01 rules): always on from both equipped
	-- weapons, adding, whichever weapon is drawn (PlayerStatsService).
	local fraction = 0
	if isMagic then
		fraction += PlayerStatsService:GetEnchantmentStat(player, "ArcaneDamage")
		fraction += PlayerStatsService:GetGearStat(player, "ArcaneDamage")
	elseif not isConvertedSpell then
		fraction += PlayerStatsService:GetEnchantmentStat(player, "WeaponDamage")
		fraction += PlayerStatsService:GetWeaponLineDamage(player, isMelee)
	end
	return damage * fraction
end

function DamageService.TakeDamage(
	self: typeof(DamageService),
	player: Player,
	humanoid: Humanoid,
	damage: number,
	isMagic: boolean?,
	isStatusConditionDamage: boolean?,
	isMelee: boolean?,
	isRelicSourced: boolean?,
	-- Raw-damage callers (isStatusConditionDamage) normally suppress the
	-- on-hit particles; a caller that ticks slowly enough to want the
	-- normal impact feedback (Ghost Dragon, 1/sec) opts back in.
	showHitVFX: boolean?,
	-- Floating-number colour override for the raw-damage path.
	indicatorColor: Color3?,
	-- Sword of the Epicredness marker (set ONLY by onHitboxDamage): this
	-- weapon-flagged hit is a CONVERTED SPELL, so Orinthian's ranged
	-- conversion below must not touch it.
	isConvertedSpell: boolean?,
	-- Where the hit came from, for the knockback (a hitbox burst's
	-- centre, from onHitboxDamage). Nil = the attacker's position.
	hitOrigin: Vector3?
)
	if humanoid.Health <= 0 then
		return
	end
	local targetModel = humanoid.Parent
	if not targetModel or not targetModel:IsA("Model") then
		return
	end
	-- Cutscene / scripted invulnerability: NO damage of any kind lands.
	if targetModel:GetAttribute(Attributes.Invulnerable) == true then
		return
	end

	-- Kill credit. Written only when it CHANGES: MobBase credits assists off
	-- HealthChanged by reading the attribute, so a same-value rewrite on
	-- every DoT tick was pure replication churn.
	if targetModel:GetAttribute(Attributes.SlainBy) ~= player.Name then
		targetModel:SetAttribute(Attributes.SlainBy, player.Name)
	end

	-- Status condition damage (DoT) bypasses the whole pipeline: no
	-- amplifiers, no crit, no appliers, no hit sparks.
	if isStatusConditionDamage then
		if showHitVFX then
			DamageIndicatorService:ShowIndicator(player, targetModel, damage, false, indicatorColor, nil, nil, true)
		else
			DamageIndicatorService:ShowIndicatorNoHitVFX(
				player,
				targetModel,
				damage,
				false,
				indicatorColor,
				nil,
				nil,
				true
			)
		end
		humanoid:TakeDamage(damage)
		-- Teddy Trap: "on ALL damage" -- a DoT tick is damage you dealt.
		self._onDamageModules["TeddyTrap"](player, damage)
		self:_postDamage(player, humanoid, false, true)
		return
	end

	-- ±10% per-hit variance, centralized so every caller gets it and the
	-- relic modules read the post-variance damage.
	damage = rollDamageVariance(damage)
	local relicSourced: boolean = isRelicSourced == true

	-- ONE relic snapshot and ONE target-status read for the whole hit; the
	-- modules and resolvers below read these instead of RelicService and
	-- the status attributes each.
	local snapshot = RelicService:GetRelicSnapshot(player)
	local statuses = self:GetTargetStatuses(targetModel)

	isMelee = isMelee or false

	-- Exactly "a gun shot": not arcane, not melee, not a relic burst, not a
	-- status tick (those returned above), and not a spell already converted
	-- the OTHER way by Sword of the Epicredness. Read once, BEFORE the
	-- Orinthian conversion flips isMagic, because a converted shot is still
	-- a bullet for everything below that cares about bullets.
	local isGunShot = not isMagic and not isMelee and not isRelicSourced and not isConvertedSpell

	self:_knockback(player, targetModel, isMelee == true, isGunShot, isMagic == true or hitOrigin ~= nil, hitOrigin)

	-- Orinthian Blaster 3777: ranged weapon hits are CONVERTED to Arcane
	-- Damage. Orinthian Blaster 3777: the shot deals Arcane; `isGunShot`
	-- stays true, so the ranged-conditional procs (Volleyball, Paint, the
	-- gun relics) keep seeing a shot.
	if isGunShot and DamageService.RelicCount(snapshot, RelicNames["Orinthian Blaster 3777"]) > 0 then
		isMagic = true
	end

	-- Blue Laser Scythe (2026-10-30): while Frostburst, a MELEE weapon hit
	-- becomes Arcane Damage (isMelee stays set, so LaserScythes can pay
	-- its +30% on exactly these hits).
	if
		isMelee
		and not isMagic
		and not isRelicSourced
		and DamageService.RelicCount(snapshot, RelicNames["Blue Laser Scythe"]) > 0
	then
		local casterRoot = getRoot.fromPlayer(player)
		if casterRoot and casterRoot:FindFirstChild(AuraNames.Frostburst) then
			isMagic = true
		end
	end

	-- UNTYPED-ONLY LANE (design call 2026-08-31): every relic-sourced
	-- burst — pumpkins, Fuse Bomb, Summer Fireworks, Ghost Dragon,
	-- Super Stomp Boots, Golem's Hammer tremors + barrier blast, Bundle
	-- of TNT, Lightning Horn, Zombie Bomb, Ice Breaker — scales with
	-- UNQUALIFIED "Damage" bonuses only (
	-- the hyperlasers, Abyss, target
	-- vulnerability). Weapon Damage / Magic Damage relics, the armor
	-- set's weapon amp, and CRITS never touch relic bursts.
	local untypedOnly = isRelicSourced == true

	-- ADDITIVE RELIC SUM. Each module internally gates itself and returns
	-- `damage x its fraction`, so the sum realizes base x (1 + Σ bonuses).
	local totalDamage = damage
		+ self._onDamageModules["FluffyUnicorn"](player, snapshot, humanoid, damage)
		+ self._onDamageModules["MurderKnife"](player, snapshot, humanoid, damage, isMagic)
		-- The TYPED modules below zero out on the untyped lane.
		+ (if untypedOnly then 0 else self._onDamageModules["FlatDamageRelics"](player, snapshot, damage, isMagic))
		+ (if untypedOnly then 0 else self._onDamageModules["MysticalSigil"](player, snapshot, damage, isMagic))
		+ (if untypedOnly then 0 else self._onDamageModules["LaserScythes"](player, snapshot, damage, isMagic, isMelee))
		+ (if untypedOnly then 0 else self._onDamageModules["AuraDamage"](player, snapshot, damage, isMagic, isMelee))
		+ (if untypedOnly
			then 0
			else self._onDamageModules["RangedRelics"](player, snapshot, damage, isGunShot, statuses))
		+ (
			if untypedOnly
				then 0
				else self._onDamageModules["Volleyball"](
					player,
					snapshot,
					humanoid,
					damage,
					-- A GUN SHOT, converted (Orinthian) or not; a spell made
					-- Weapon Damage by Sword of the Epicredness is not one
					-- (audit 2026-10-30: it used to count and spike).
					isGunShot
				)
		)

	-- Weapon Mastery set bonus (all 3 Ruinseeker pieces): +10% weapon
	-- damage, additive with the relic sum. Typed — skipped on the
	-- untyped lane.
	if not untypedOnly then
		totalDamage += ArmorSetBonusService:GetWeaponDamageAmplifier(player, damage, isMagic)
	end

	-- Gear: the weapon enchantments (Enflamed / Frostburst) and the damage
	-- lines, additive like the set bonus and typed the same way.
	if not untypedOnly then
		totalDamage += self:_gearDamageBonus(player, damage, isMagic == true, isMelee == true, isConvertedSpell == true)
	end

	do
		-- Target-conditional relic bonuses join the SAME additive pool.
		totalDamage += damage * self:_sumTargetConditionalBonuses(
			player,
			snapshot,
			targetModel,
			statuses,
			isMagic,
			untypedOnly
		)

		-- Then the mob's own vulnerability factor multiplies the total.
		totalDamage *= self:_targetVulnerabilityMultiplier(player, targetModel, isMagic, statuses)
	end

	-- TRUE "more" multipliers: Legendary and Cursed damage relics multiply
	-- the amplified total instead of joining the additive pool, so they are
	-- worth what their card says on any floor (MoreDamage.lua has the list).
	totalDamage *= self._onDamageModules["MoreDamage"](player, snapshot, isMagic == true, untypedOnly, isMelee == true)

	-- Greater Shrine "Power": one multiplier over the whole number, on
	-- EVERY lane -- weapon, arcane and relic bursts alike (it sits after
	-- the untyped-lane branches above on purpose). Run-scoped, stacks.
	totalDamage *= 1 + PlayerStatsService:GetGreaterShrineEffect(player, "Damage")

	local critChance, critMultiplier = self:GetCritParameters(player, isMagic, isMelee, targetModel, snapshot, statuses)
	if untypedOnly then
		critChance = -1 -- relic bursts never crit on the untyped lane
	elseif DamageService._relicPushDepth == 0 then
		-- A forced crit (ForceNextCrit): a weapon's or a spell's own hit
		-- spends the arm its lane matches and crits for certain. The
		-- gimmicks' typed hits run under WithRelicKnockback and pass it by.
		local forced = self:_consumeForcedCrit(player, isMelee == true, isMagic == true)
		if forced then
			critChance = 100
			if forced.onHit then
				forced.onHit(targetModel)
			end
		end
	end

	local mobName = targetModel.Name
	local isProjectileResistant = MobData[mobName] and MobData[mobName].isProjectileResistant or false
	local isMagicResistant = MobData[mobName] and MobData[mobName].isMagicResistant or false

	-- Damage-type resistances (MobData flags): x0.5 vs the resisted
	-- type, grey number, matching resist sound on the client. RELIC-SOURCED
	-- damage bypasses both: a relic's listed number is what it deals —
	-- previously TNT / tremor / Ghost Dragon (neither melee nor arcane) were
	-- silently halved by projectile-resistant mobs via the not-melee-not-
	-- arcane bucket below. Projectile resistance is against BULLETS: a spell
	-- Sword of the Epicredness turned into weapon damage is not one, and it
	-- landed in the not-melee-not-arcane bucket the same way until it was
	-- excluded here.
	local isMagicResistedHit = isMagicResistant and isMagic and not isRelicSourced
	local isResistedHit = (
		isProjectileResistant
		and not isMelee
		and not isMagic
		and not isRelicSourced
		and not isConvertedSpell
	) or isMagicResistedHit

	-- Number colour by damage kind: resisted grey > arcane purple > weapon
	-- orange (melee and ranged both — anything that isn't relic-sourced)
	-- > relic white. Crit gold overrides all of these on the client.
	local hitColor: Color3? = if isResistedHit
		then RESISTED_COLOR3
		elseif isMagic then MAGIC_COLOR3
		elseif not isRelicSourced then WEAPON_COLOR3
		else nil
	local resistKind: ("Magic" | "Projectile")? = if isMagicResistedHit
		then "Magic"
		elseif isResistedHit then "Projectile"
		else nil

	-- A gun shot draws its own BulletImpact where the bullet landed, so the
	-- generic HitFX sparks are dropped for it: two bursts on one hit read
	-- as a double impact. Melee and arcane keep the sparks.
	--
	-- Done with a trailing `sparks = false` on the normal ShowIndicator,
	-- NOT via ShowIndicatorNoHitVFX: that one never fires the VFX signal
	-- at all, and the client does its damage highlight FLASH inside that
	-- same signal's handler -- so bullets lost the flash along with the
	-- sparks. Explicit parameters rather than varargs, so the flag lands
	-- in its slot even when a caller omits resistKind.
	local function showIndicator(
		indicatorPlayer: Player,
		model: Model,
		shownDamage: number,
		critical: boolean,
		color: Color3?,
		melee: boolean?,
		resist: ("Magic" | "Projectile")?
	)
		local sparks = if isGunShot then false else nil
		DamageIndicatorService:ShowIndicator(
			indicatorPlayer,
			model,
			shownDamage,
			critical,
			color,
			melee,
			resist,
			nil,
			sparks
		)
	end

	if isResistedHit then
		if math.random() * 100 <= critChance then
			local combinedDamage = math.round(totalDamage * critMultiplier)
			showIndicator(
				player,
				targetModel,
				math.round(combinedDamage * PROJECTILE_RESISTANCE_SCALAR),
				true,
				hitColor,
				isMelee,
				resistKind
			)

			humanoid:TakeDamage(math.round(combinedDamage * PROJECTILE_RESISTANCE_SCALAR))
			-- Teddy Trap lifesteal reads the amount that actually landed.
			self._onDamageModules["TeddyTrap"](player, math.round(combinedDamage * PROJECTILE_RESISTANCE_SCALAR))
			self:_postDamage(
				player,
				humanoid,
				true,
				relicSourced,
				isGunShot,
				isMelee,
				isMagic,
				math.round(combinedDamage * PROJECTILE_RESISTANCE_SCALAR)
			)
			return
		end

		showIndicator(
			player,
			targetModel,
			math.round(totalDamage * PROJECTILE_RESISTANCE_SCALAR),
			false,
			hitColor,
			isMelee,
			resistKind
		)
		humanoid:TakeDamage(math.round(totalDamage * PROJECTILE_RESISTANCE_SCALAR))
		self._onDamageModules["TeddyTrap"](player, math.round(totalDamage * PROJECTILE_RESISTANCE_SCALAR))
		self:_postDamage(
			player,
			humanoid,
			false,
			relicSourced,
			isGunShot,
			isMelee,
			isMagic,
			math.round(totalDamage * PROJECTILE_RESISTANCE_SCALAR)
		)
	else
		if math.random() * 100 <= critChance then
			local combinedDamage = math.round(totalDamage * critMultiplier)

			showIndicator(player, targetModel, combinedDamage, true, hitColor, isMelee)
			humanoid:TakeDamage(combinedDamage)
			self._onDamageModules["TeddyTrap"](player, combinedDamage)
			self:_postDamage(player, humanoid, true, relicSourced, isGunShot, isMelee, isMagic, combinedDamage)
			return
		end

		showIndicator(player, targetModel, math.round(totalDamage), false, hitColor, isMelee)

		humanoid:TakeDamage(math.round(totalDamage))
		self._onDamageModules["TeddyTrap"](player, math.round(totalDamage))
		self:_postDamage(player, humanoid, false, relicSourced, isGunShot, isMelee, isMagic, math.round(totalDamage))
	end
end

--[ Initializers ]--

function DamageService.Start(self: typeof(DamageService))
	for _, damageModule in (script:GetChildren()) do
		self._onDamageModules[damageModule.Name] = (require :: any)(damageModule)
	end
	for _, moduleName in REQUIRED_DAMAGE_MODULES do
		assert(
			self._onDamageModules[moduleName] ~= nil,
			`[DamageService] on-hit module "{moduleName}" is missing under DamageService`
		)
	end

	PlayerEventService.OnPlayerRemoved:Connect(function(player: Player)
		self._lightningStrikeLast[player.UserId] = nil
		self._shurikenLastRefund[player.UserId] = nil
		self._stormExtendLast[player.UserId] = nil
		self._recentDamageTaken[player.UserId] = nil
		self._forcedCrits[player.UserId] = nil
	end)
end

return DamageService
