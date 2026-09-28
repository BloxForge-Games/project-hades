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
	armor set -> poison weaken -> Slateskin -> Stonebound DR -> Flaming Orb
	-> shield absorb -> Space Sandwich proc -> ragdoll/lethal-clamp.
]]

--[ Roblox Services ]--

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

--[ Exports & Types & Defaults ]--

local RelicService = require(ServerScriptService.Services.RelicService)
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
local MagicService = require(ServerScriptService.Services.MagicService)
local RelicNetwork = require(ServerScriptService.Submodules.Core.Source.Network.Relic)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local AuraNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.AuraNames)
local AuraData = require(ReplicatedStorage.Submodules.Core.Shared.Data.AuraData)
local StatusConditions = require(ReplicatedStorage.Submodules.Core.Shared.Enums.StatusConditions)
local getPlayerLevel = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Player.getPlayerLevel)
local isEncounterEnemy = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Mob.isEncounterEnemy)
local getRoot = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Character.getRoot)
local forEachEnemyInRadius = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Combat.forEachEnemyInRadius)
local snapToGround = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Combat.snapToGround)
local ZombieData = require(ReplicatedStorage.Submodules.Core.Shared.Data.ZombieData)
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

-- The run's difficulty damage multiplier on mob hits; 1 outside a run.
-- DungeonService is reached at call time (this service is a consumer).
local function difficultyDamageMultiplier(): number
	local dungeonService = Blitz.OptionalService("DungeonService")
	return if dungeonService then dungeonService:GetDifficultyScale().enemyDamage else 1
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
	_shurikenLastRefund = {} :: { [number]: number },
	-- Rolling per-player log of damage that actually reached HEALTH (post
	-- shield / post-mitigation) — Astral Cloak's dodge heal consumes it.
	_recentDamageTaken = {} :: { [number]: { { t: number, amount: number } } },
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
local DEFAULT_CRITICAL_CHANCE = 5
local DEFAULT_CRITICAL_MULTIPLIER = 1.5
-- Double-Bladed Scythe (Cursed): "-50% less Magic Damage". Its callback owns
-- the +50% WEAPON half, so this drawback lives here as its own knob.
local BONE_SCYTHE_MAGIC_MULTIPLIER = 0.5
local RESISTED_COLOR3 = DamageIndicatorColors.Resisted
local MAGIC_COLOR3 = DamageIndicatorColors.Magic
local WEAPON_COLOR3 = DamageIndicatorColors.Weapon
local RAGDOLL_VELOCITY = 25

-- Status attributes stamped on mob models by getStatusConditionService().
-- Direct reads are fine for single statuses; the FAMILY questions ("is it
-- burning / poisoned / shocked") must go through getStatusConditionService()'s
-- IsBurning / IsPoisoned / IsShocked — the upgraded variants (Black Flame,
-- Noxious Venom, Coil Shocked) stamp their own attributes.
local STATUS_ATTRIBUTE_PREFIX = "Status"

-- Ceiling on Greater Shrine "Bulwark": nothing stacks it today (one
-- blessing per run), but a per-floor exclusion rule later would, and
-- damage immunity should never be reachable from a free pickup.
local GREATER_SHRINE_MAX_REDUCTION = 0.60

-- Flaming Orb of Divine Pain (Cursed): +25% damage TAKEN while any aura is
-- up — the price of its x1.5 aura-duration extension (AuraService).
local FLAMING_ORB_DAMAGE_TAKEN_MULTIPLIER = 1.25
local FLAMING_ORB_AURA_MARKERS = {
	AuraNames.Enflamed,
	AuraNames.Frostburst,
	AuraNames.Blighted,
	AuraNames.Stormcharged,
	AuraNames.Stonebound,
}

-- Dragon Lantern (Cursed): every hit that reaches HEALTH strips 10% of
-- the owner's unbanked run coins.
local DRAGON_LANTERN_COIN_TAX = 0.10

-- Storm tree crit riders (percentage points on the 0-100 roll / fractions
-- on the multiplier). Chances/fractions that live in relic callbacks are
-- read at the use site; these are the hardcoded halves.

-- Lightning Horn of the Heavens: a CRIT on a Shocked enemy has the relic's
-- data.strikeChance to call down a Lightning Strike (damage per level from
-- the relic callback) in this radius. Latched so one strike can never
-- chain another off its own crits, and relic-sourced damage can never
-- trigger one. (The Stormcharged clause was dropped in the 2026-09 pass.)
local LIGHTNING_STRIKE_RADIUS = 11
local LIGHTNING_STRIKE_FANOUT_SECONDS = 0.1

-- Katana's crit-DAMAGE half (its callback carries the crit-chance half).
-- Keep in sync with the relic's card.

-- Shuriken of the Crescent Moon: a critical ATTACK refunds this fraction of
-- Maximum Mana, fan-out latched so an AoE crit refunds once.
local SHURIKEN_MANA_FRACTION = 0.01
local SHURIKEN_FANOUT_SECONDS = 0.1

-- Ban Hammer (Legendary) execute threshold: a CRITICAL HIT finishes a normal
-- enemy at/below this health fraction. Minibosses and bosses are immune.
local EXECUTE_THRESHOLD = 0.15

local PROJECTILE_RESISTANCE_SCALAR = 0.25

-- Every on-hit module name the hit path indexes by string. Checked once
-- at boot (Start) so a renamed or missing module file fails there rather
-- than on the first hit.
local REQUIRED_DAMAGE_MODULES = {
	"TeddyTrap",
	"Jail",
	"FluffyUnicorn",
	"BlueHyperLaser",
	"RedHyperlaserGun",
	"MurderKnife",
	"ForbiddenBox",
	"GloriousSword",
	"FlatDamageRelics",
	"MysticalSigil",
	"LaserScythes",
	"AuraDamage",
	"Volleyball",
}

-- Ice Dragon Slayer: the "+25% vs Chilled" only counts above this fraction
-- of Maximum Mana.

-- Phoenix / Katana health gates.

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
	-- Noxious Venom, Coil Shocked) stamps its own attribute and therefore
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

	if character:GetAttribute(Attributes.SusanooEnabled) == true then
		damage = damage * 0.5
	end

	-- Teddy Trap (incoming side): +150% damage taken if owned. Callback
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

	-- Sword of Eternal Abyss (Cursed): +50% Damage Reduction, the defensive
	-- half of the trade it makes for locking out auras and statuses. Its
	-- callback carries the OFFENSIVE half, so the reduction lives in `data`.
	if RelicService:GetSpecificRelicRegistry(player, RelicNames["Sword of Eternal Abyss"]) > 0 then
		damage = damage * (1 - relicData(RelicNames["Sword of Eternal Abyss"], "damageReduction", 0.50))
	end

	-- Stonebound: -10% damage taken (plus the owner's Leland rider), read
	-- straight off the marker's replicated payload.
	if AuraService then
		local _, stoneboundReduction = AuraService:GetStoneboundPayload(character)
		if stoneboundReduction > 0 then
			damage = damage * (1 - stoneboundReduction)
		end
	end

	-- Flaming Orb of Divine Pain (Cursed): +25% taken while ANY aura is up.
	if RelicService:GetSpecificRelicRegistry(player, RelicNames["Flaming Orb of Divine Pain"]) > 0 then
		local auraHrp = getRoot(character)
		if auraHrp then
			for _, markerName in FLAMING_ORB_AURA_MARKERS do
				if auraHrp:FindFirstChild(markerName) then
					damage = damage * FLAMING_ORB_DAMAGE_TAKEN_MULTIPLIER
					break
				end
			end
		end
	end

	-- Greater Shrine "Bulwark". Deliberately ABOVE the fixedDamage
	-- override, so a trap's flat percentage still ignores it exactly as
	-- it ignores every other mitigation. Capped so a future stack can
	-- never reach immunity.
	local bulwark = PlayerStatsService:GetGreaterShrineEffect(player, "DamageReduction")
	if bulwark > 0 then
		damage = damage * (1 - math.min(bulwark, GREATER_SHRINE_MAX_REDUCTION))
	end

	-- Everything above is discarded for a fixedDamage hit (see the top of
	-- this function): the caller's number is the number.
	if fixedAmount then
		damage = fixedAmount
	end

	-- Shield pool spends LAST, against the fully mitigated number.
	damage = ShieldService:AbsorbShieldDamage(player, damage)

	local rootPart = getRoot(character)
	if rootPart then
		local zombieHit: Sound = (rootPart:FindFirstChild("ZombieHit") :: Sound?)
			or ReplicatedStorage.GameAssets.Sounds.ZombieHit:Clone()
		if zombieHit.Parent ~= rootPart then
			zombieHit.Parent = rootPart
		end
		zombieHit.TimePosition = 0.2
		zombieHit:Play()

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

	-- Dragon Lantern's coin tax — health damage only.
	if RelicService:GetSpecificRelicRegistry(player, RelicNames["Dragon Lantern"]) > 0 then
		RunEscrowService:TaxCoins(player, DRAGON_LANTERN_COIN_TAX)
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

-- Ban Hammer (Legendary): a CRITICAL HIT finishes a normal enemy sitting
-- at/below EXECUTE_THRESHOLD. Minibosses and bosses can never be executed.
-- PUBLIC on purpose: bypass damage paths (Volleyball's delayed spike) call
-- it directly, passing no `wasCrit`, and therefore never execute.
function DamageService.TryExecute(_self: typeof(DamageService), player: Player, humanoid: Humanoid, wasCrit: boolean?)
	if not wasCrit then
		return
	end

	if RelicService:GetSpecificRelicRegistry(player, RelicNames["Ban Hammer"]) <= 0 then
		return
	end

	local model = humanoid.Parent
	if not model or model:GetAttribute("BanHammerExecuted") then
		return
	end

	if humanoid.Health <= 0 or humanoid.MaxHealth <= 0 then
		return
	end

	if isEncounterEnemy(model) then
		return
	end

	if (humanoid.Health / humanoid.MaxHealth) > EXECUTE_THRESHOLD then
		return
	end

	-- Guard against a same-frame second damage path executing a corpse.
	model:SetAttribute("BanHammerExecuted", true)

	local indicatorPart = model:FindFirstChild("Head") or getRoot(model)
	if indicatorPart and indicatorPart:IsA("BasePart") then
		TextIndicatorService:ShowIndicator(player, indicatorPart, "Banned!", Color3.fromRGB(255, 85, 85), true)
	end

	humanoid:TakeDamage(humanoid.Health)
end

-- Post-damage hub — runs after EVERY damage application inside TakeDamage.
-- `isRelicSourced` blocks the Lightning Strike from re-triggering off
-- relic damage — a strike's own crits can never chain another strike.
function DamageService._postDamage(
	self: typeof(DamageService),
	player: Player,
	humanoid: Humanoid,
	wasCrit: boolean?,
	isRelicSourced: boolean?
)
	self:TryExecute(player, humanoid, wasCrit)

	-- Lightning Orb rolls on EVERY hit now, not just crits — `wasCrit` only
	-- selects which of its two chances applies.
	self:_tryLightningOrbStormcharge(player, wasCrit)

	if wasCrit then
		self:_tryShurikenManaRefund(player)
		if not isRelicSourced then
			self:_tryLightningHornStrike(player, humanoid)
		end
	end
end

-- Lightning Orb (Storm Rare): ANY damage — weapon or magic, per TARGET (an
-- AoE hitting three mobs rolls three times), relic procs included — has a
-- chance to grant Stormcharged. TWO TIERS: the callback's base normally,
-- and this when the hit CRIT. "increased to", so they replace each other
-- rather than stacking. Deliberately UNLATCHED, per the design call.
-- Routed through SetAura, so the Abyss lockout and duration bonuses apply
-- for free.

function DamageService._tryLightningOrbStormcharge(_self: typeof(DamageService), player: Player, wasCrit: boolean?)
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
	if chance > 0 and math.random() <= chance then
		AuraService:SetAura(player, AuraNames.Stormcharged, character)
	end
end

-- Lightning Horn of the Heavens (Legendary): a crit on a Shocked enemy
-- (Coil Shocked counts) has data.strikeChance to call down a Lightning
-- Strike — per-level damage from the relic callback, in a radius, every
-- enemy inside. The fan-out latch collapses an AoE crit into ONE strike,
-- and _postDamage's isRelicSourced gate stops a strike's own crits from
-- chaining another.
function DamageService._tryLightningHornStrike(self: typeof(DamageService), player: Player, humanoid: Humanoid)
	if RelicService:GetSpecificRelicRegistry(player, RelicNames["Lightning Horn of the Heavens"]) <= 0 then
		return
	end

	local targetModel = humanoid.Parent
	if not targetModel or not getStatusConditionService() or not getStatusConditionService():IsShocked(targetModel) then
		return
	end

	-- The roll, before the latch: a failed roll must not spend the fan-out
	-- window for the other targets of the same AoE crit.
	local hornData = RelicData[RelicNames["Lightning Horn of the Heavens"]]
	local strikeChance = (hornData and hornData.data and hornData.data.strikeChance) or 0.50
	if math.random() > strikeChance then
		return
	end

	local hrp = getRoot(targetModel)
	if not hrp then
		return
	end

	-- Fan-out latch: only the FIRST qualifying crit of an attack strikes.
	local now = os.clock()
	local lastStrike = self._lightningStrikeLast[player.UserId]
	if lastStrike and (now - lastStrike) < LIGHTNING_STRIKE_FANOUT_SECONDS then
		return
	end
	self._lightningStrikeLast[player.UserId] = now

	local damagePerLevel = RelicService:GetRelicEffect(player, RelicNames["Lightning Horn of the Heavens"]) or 0
	local strikeDamage = math.round(damagePerLevel * getPlayerLevel(player))
	if strikeDamage <= 0 then
		return
	end

	-- Ground the strike under the target so the bolt lands on the floor.
	local strikePosition = snapToGround(hrp.Position) or hrp.Position

	RelicNetwork.LightningStrikeEffect.FireAll(strikePosition)

	forEachEnemyInRadius(strikePosition, LIGHTNING_STRIKE_RADIUS, function(model, targetHumanoid)
		-- Full pipeline, relic-sourced: amp chain and crit roll apply, but
		-- relic-sourced damage can never trigger ANOTHER strike, and the
		-- appliers roll per target like any relic magic.
		-- isMagic = false: the strike rides the untyped relic lane; a
		-- magic flag would wrongly pick up Painted's magic vulnerability.
		self:TakeDamage(player, targetHumanoid, strikeDamage, false, false, nil, true)
		if getStatusConditionService() then
			getStatusConditionService():ApplyMagicOnHitStatuses(player, model)
		end
	end)
end

-- Shuriken of the Crescent Moon: refund 1% of Maximum Mana on a critical
-- ATTACK. Latched so one AoE crit refunds once.
function DamageService._tryShurikenManaRefund(self: typeof(DamageService), player: Player)
	if RelicService:GetSpecificRelicRegistry(player, RelicNames["Shuriken of the Crescent Moon"]) <= 0 then
		return
	end

	local now = os.clock()
	local lastRefund = self._shurikenLastRefund[player.UserId]
	if lastRefund and (now - lastRefund) < SHURIKEN_FANOUT_SECONDS then
		return
	end
	self._shurikenLastRefund[player.UserId] = now

	local magicData = MagicService:GetPlayerMagicData(player)
	if not magicData or not magicData.maxMana or magicData.mana >= magicData.maxMana then
		return
	end

	local restored = math.min(magicData.mana + magicData.maxMana * SHURIKEN_MANA_FRACTION, magicData.maxMana)
	MagicService:SetPlayerMagicData(player, restored, magicData.maxMana)
end

-- The player's crit CHANCE (0-100) and crit MULTIPLIER for one hit.
-- Composition:
--   chance = 5 + Shuriken (+5) + Ban Hammer (+25) + Stormcharged (+15)
--            + Sparkle Time (+50, magic while Stormcharged)
--            + Ninja Whip (+10 vs Shocked targets)
--   multiplier = 1.5 + Stormcharged (+0.15)
--                + Dragon's Flame Sword (+0.35 vs Burning)
--                + Lightning Bolt Sword (+0.30 vs Shocked)
-- `targetModel` is optional — target-conditional rows skip without one.
-- `snapshot` / `statuses` are the per-hit tables TakeDamage already holds;
-- a caller without them gets them resolved here.
function DamageService.GetCritParameters(
	self: typeof(DamageService),
	player: Player,
	isMagic: boolean?,
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

	-- Ban Hammer: +25% (callback fraction).
	local banHammerEffect = DamageService.RelicEffect(relics, RelicNames["Ban Hammer"]) or 0
	critChance += banHammerEffect * 100

	-- Silver Ninja Star: flat +15 points, no gate (callback = points).
	if DamageService.RelicCount(relics, RelicNames["Silver Ninja Star"]) > 0 then
		critChance += DamageService.RelicEffect(relics, RelicNames["Silver Ninja Star"]) or 0
	end

	-- Shuriken of the Crescent Moon: flat +5 points, from `data` — its
	-- callback slot carries the crit-mana-refund fraction instead.
	if DamageService.RelicCount(relics, RelicNames["Shuriken of the Crescent Moon"]) > 0 then
		critChance += relicData(RelicNames["Shuriken of the Crescent Moon"], "critChanceBonus", 5)
	end

	local casterHrp = getRoot.fromPlayer(player)
	local isStormcharged = casterHrp ~= nil and casterHrp:FindFirstChild(AuraNames.Stormcharged) ~= nil

	-- Stormcharged: crit chance while up (AuraData owns the number).
	if isStormcharged then
		critChance += AuraData[AuraNames.Stormcharged].critChanceBonus or 0

		-- Katana deepens the SAME window, both halves. Its crit-chance half
		-- is the callback (percentage points); the damage half is the
		-- constant below, since a callback returns only one value.
		if DamageService.RelicCount(relics, RelicNames.Katana) > 0 then
			critChance += DamageService.RelicEffect(relics, RelicNames.Katana) or 0
		end
	end

	-- Sparkle Time Hoverboard on MAGIC hits while Stormcharged. Read from
	-- the relic callback (percentage points) -- the old local constant
	-- silently stayed at 25 when the relic was buffed to 50, which is
	-- exactly the drift a single source prevents.
	if isMagic and isStormcharged and DamageService.RelicCount(relics, RelicNames["Sparkle Time Hoverboard"]) > 0 then
		critChance += DamageService.RelicEffect(relics, RelicNames["Sparkle Time Hoverboard"]) or 0
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

	-- Stormcharged carries a crit-DAMAGE half again (AuraData owns it, as a
	-- FRACTION -- its crit-CHANCE sibling is in points).
	if isStormcharged then
		critMultiplier += AuraData[AuraNames.Stormcharged].critDamageBonus or 0

		-- Lightning Wand: the Rare crit-damage rider on the same window.
		if DamageService.RelicCount(relics, RelicNames["Lightning Wand"]) > 0 then
			critMultiplier += DamageService.RelicEffect(relics, RelicNames["Lightning Wand"]) or 0
		end

		-- Katana deepens the same window's crit-damage half.
		if DamageService.RelicCount(relics, RelicNames.Katana) > 0 then
			critMultiplier += relicData(RelicNames.Katana, "critDamageBonus", 0.20)
		end
	end

	-- Dragon's Flame Sword: +35% crit damage vs Burning targets (family —
	-- Black Flame counts).
	if targetStatuses.isBurning and DamageService.RelicCount(relics, RelicNames["Dragon's Flame Sword"]) > 0 then
		critMultiplier += DamageService.RelicEffect(relics, RelicNames["Dragon's Flame Sword"]) or 0
	end

	-- Lightning Bolt Sword: +25% crit damage always, +50% instead against a
	-- Shocked target. The Shocked value REPLACES the base, it does not add.
	if DamageService.RelicCount(relics, RelicNames["Lightning Bolt Sword"]) > 0 then
		critMultiplier += if targetShocked
			then relicData(RelicNames["Lightning Bolt Sword"], "shockedBonus", 0.50)
			else DamageService.RelicEffect(relics, RelicNames["Lightning Bolt Sword"]) or 0
	end

	return critChance, critMultiplier
end

-- The additive TARGET-CONDITIONAL relic bonuses for one hit, as a summed
-- FRACTION (joins the same additive pool as the damage modules).
-- `skipTyped` = the untyped relic lane: rows whose card names Weapon
-- or Magic damage are excluded (magic-gated rows are already out via
-- isMagic = false; weapon-gated rows need the explicit skip).
function DamageService._sumTargetConditionalBonuses(
	_self: typeof(DamageService),
	player: Player,
	snapshot: RelicSnapshot,
	targetModel: Model,
	statuses: TargetStatuses,
	isMagic: boolean?,
	skipTyped: boolean?
): number
	local bonus = 0

	local humanoid = targetModel:FindFirstChildOfClass("Humanoid")
	local healthFraction = if humanoid and humanoid.MaxHealth > 0 then humanoid.Health / humanoid.MaxHealth else 1

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

	-- Phoenix: below the health gate it pays on ANY target now, with the
	-- Burning value REPLACING the base rather than stacking on it.
	if DamageService.RelicCount(snapshot, RelicNames.Phoenix) > 0 then
		if healthFraction < relicData(RelicNames.Phoenix, "healthFraction", 0.5) then
			bonus += if isBurning
				then relicData(RelicNames.Phoenix, "burningBonus", 0.25)
				else (DamageService.RelicEffect(snapshot, RelicNames.Phoenix) or 1) - 1
		end
	end

	-- Venom payoffs.
	if isPoisoned and DamageService.RelicCount(snapshot, RelicNames["Poisonous Butterfly"]) > 0 then
		bonus += (DamageService.RelicEffect(snapshot, RelicNames["Poisonous Butterfly"]) or 1) - 1
	end

	-- Foul Poison Fowl: bonus damage equal to the target's TOTAL live
	-- Weaken, from every applier and every Noxious Venom stack, already
	-- clamped to the weaken cap by the service. Its OTHER half (+10% on
	-- the owner's own Poison) is a relicModifier in StatusConditionData,
	-- so a solo player's own Poison feeds this loop on its own.
	if getStatusConditionService() and DamageService.RelicCount(snapshot, RelicNames["Foul Poison Fowl"]) > 0 then
		bonus += getStatusConditionService():GetPoisonWeakenFraction(targetModel)
	end

	-- Mechatronic Spider: pays on every enemy, more on a Poisoned one.
	-- The Poisoned value REPLACES the base.
	if DamageService.RelicCount(snapshot, RelicNames["Mechatronic Spider"]) > 0 then
		bonus += if isPoisoned
			then relicData(RelicNames["Mechatronic Spider"], "poisonedBonus", 0.25)
			else (DamageService.RelicEffect(snapshot, RelicNames["Mechatronic Spider"]) or 1) - 1
	end

	-- Frost payoffs. Frozen Flail is MAGIC-only per its card.
	if isChilled and isMagic and DamageService.RelicCount(snapshot, RelicNames["Frozen Flail"]) > 0 then
		bonus += (DamageService.RelicEffect(snapshot, RelicNames["Frozen Flail"]) or 1) - 1
	end

	-- Ice Dragon Slayer: gated on MANA, not on the target. The Chilled
	-- value REPLACES the base.
	if DamageService.RelicCount(snapshot, RelicNames["Ice Dragon Slayer"]) > 0 and MagicService then
		local magicData = MagicService:GetPlayerMagicData(player)
		if
			magicData
			and magicData.maxMana
			and magicData.maxMana > 0
			and magicData.mana / magicData.maxMana > relicData(RelicNames["Ice Dragon Slayer"], "manaFraction", 0.5)
		then
			bonus += if isChilled
				then relicData(RelicNames["Ice Dragon Slayer"], "chilledBonus", 0.25)
				else (DamageService.RelicEffect(snapshot, RelicNames["Ice Dragon Slayer"]) or 1) - 1
		end
	end

	-- Distinct-status count, shared by the two per-status payoffs (resolved
	-- once per hit in GetTargetStatuses).
	local statusCount = statuses.statusCount

	-- Neon Rainbow Phoenix: +25% per distinct status, additive.
	if statusCount > 0 and DamageService.RelicCount(snapshot, RelicNames["Neon Rainbow Phoenix"]) > 0 then
		local perStatus = (DamageService.RelicEffect(snapshot, RelicNames["Neon Rainbow Phoenix"]) or 1) - 1
		bonus += perStatus * statusCount
	end

	-- BLIGHTED: +10% per unique status on the target, and Overseer's
	-- Battleaxe raises that same RATE to 15% rather than adding a second
	-- bonus on top — so the player follows one number, not two.
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
	--   * Noxious Venom counts ONCE however many stacks are on the target
	--     — the attribute is "at least one instance", not a tally.
	if statusCount > 0 then
		local attackerHrp = getRoot.fromPlayer(player)
		if attackerHrp and attackerHrp:FindFirstChild(AuraNames.Blighted) then
			local perStatus = AuraData[AuraNames.Blighted].damagePerUniqueStatus or 0
			if DamageService.RelicCount(snapshot, RelicNames["Overseer's Battleaxe"]) > 0 then
				perStatus += (DamageService.RelicEffect(snapshot, RelicNames["Overseer's Battleaxe"]) or 1) - 1
			end
			bonus += perStatus * statusCount
		end
	end

	local _ = isMagic -- damage-type-agnostic today; kept for future gates

	return bonus
end

-- The multiplicative TARGET-VULNERABILITY factor: what the mob's statuses
-- make it take extra, additively composed (+10% Shock +10% Coil Shocked
-- +5% Throwing Bolts = x1.25, never compounding).
function DamageService._targetVulnerabilityMultiplier(
	_self: typeof(DamageService),
	player: Player,
	targetModel: Model,
	isMagic: boolean?
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

	-- Painted: +20% MAGIC damage, from the APPLIER only (Magenta Paintball
	-- Gun's "from you").
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

	return multiplier
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
	isConvertedSpell: boolean?
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

	-- Exactly "a gun shot": not magic, not melee, not a relic burst, not a
	-- status tick (those returned above), and not a spell already converted
	-- the OTHER way by Sword of the Epicredness. Read once, BEFORE the
	-- Orinthian conversion flips isMagic, because a converted shot is still
	-- a bullet for everything below that cares about bullets.
	local isGunShot = not isMagic and not isMelee and not isRelicSourced and not isConvertedSpell

	-- Orinthian Blaster 3777: ranged weapon hits are CONVERTED to Magic
	-- Damage. `isConvertedRanged` keeps the shot's RANGED identity alive
	-- for the ranged-conditional procs.
	local isConvertedRanged = false
	if isGunShot and DamageService.RelicCount(snapshot, RelicNames["Orinthian Blaster 3777"]) > 0 then
		isConvertedRanged = true
		isMagic = true
	end

	-- UNTYPED-ONLY LANE (design call 2026-08-31): every relic-sourced
	-- burst — pumpkins, Fuse Bomb, Summer Fireworks, Ghost Dragon,
	-- Super Stomp Boots, Golem's Hammer tremors + barrier blast, Bundle
	-- of TNT, Lightning Horn, Zombie Bomb, Ice Breaker — scales with
	-- UNQUALIFIED "Damage" bonuses only (Mechatronic Spider, Phoenix,
	-- Forbidden Box, the hyperlasers, Abyss, target
	-- vulnerability). Weapon Damage / Magic Damage relics, the armor
	-- set's weapon amp, and CRITS never touch relic bursts.
	local untypedOnly = isRelicSourced == true

	-- Weapon-only on-hit side effects (Jail). Relic bursts don't jail.
	if not untypedOnly then
		self._onDamageModules["Jail"](player, snapshot, humanoid, isMagic)
	end

	-- ADDITIVE RELIC SUM. Each module internally gates itself and returns
	-- `damage x its fraction`, so the sum realizes base x (1 + Σ bonuses).
	local totalDamage = damage
		+ self._onDamageModules["FluffyUnicorn"](player, snapshot, humanoid, damage)
		+ self._onDamageModules["BlueHyperLaser"](player, snapshot, damage, isMagic)
		+ self._onDamageModules["RedHyperlaserGun"](player, snapshot, damage, isMagic)
		+ self._onDamageModules["MurderKnife"](player, snapshot, humanoid, damage, isMagic)
		+ self._onDamageModules["ForbiddenBox"](player, snapshot, damage, isMagic)
		-- The five TYPED modules below zero out on the untyped lane.
		+ (if untypedOnly then 0 else self._onDamageModules["GloriousSword"](player, snapshot, damage, isMagic))
		+ (if untypedOnly then 0 else self._onDamageModules["FlatDamageRelics"](player, snapshot, damage, isMagic))
		+ (if untypedOnly then 0 else self._onDamageModules["MysticalSigil"](player, snapshot, damage, isMagic))
		+ (if untypedOnly then 0 else self._onDamageModules["LaserScythes"](player, snapshot, damage, isMagic))
		+ (if untypedOnly then 0 else self._onDamageModules["AuraDamage"](player, snapshot, damage, isMagic))
		-- Sword of Eternal Abyss: flat +50%, weapon and magic alike. Inline
		-- rather than a module because it is one unconditional multiplier
		-- with no gating of its own.
		+ (if DamageService.RelicCount(snapshot, RelicNames["Sword of Eternal Abyss"]) > 0
			then damage * ((DamageService.RelicEffect(snapshot, RelicNames["Sword of Eternal Abyss"]) or 1) - 1)
			else 0)
		+ (
			if untypedOnly
				then 0
				else self._onDamageModules["Volleyball"](
					player,
					snapshot,
					humanoid,
					damage,
					-- Converted ranged shots keep their RANGED identity for the
					-- spike counter.
					isMagic and not isConvertedRanged,
					isMelee
				)
		)

	-- Weapon Mastery set bonus (all 3 Ruinseeker pieces): +10% weapon
	-- damage, additive with the relic sum. Typed — skipped on the
	-- untyped lane.
	if not untypedOnly then
		totalDamage += ArmorSetBonusService:GetWeaponDamageAmplifier(player, damage, isMagic)
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
		totalDamage *= self:_targetVulnerabilityMultiplier(player, targetModel, isMagic)
	end

	-- Double-Bladed Scythe (Cursed): magic halved, weapon +50%,
	-- multiplicative on the amplified total (a Cursed override, not part of
	-- the additive pool). A TYPED relic, so it obeys the untyped lane like
	-- the modules above — relic bursts arrive as isMagic=false and were
	-- silently taking the weapon +50%.
	if not untypedOnly and DamageService.RelicCount(snapshot, RelicNames["Double-Bladed Scythe"]) > 0 then
		if isMagic then
			totalDamage *= BONE_SCYTHE_MAGIC_MULTIPLIER
		else
			totalDamage *= 1 + (DamageService.RelicEffect(snapshot, RelicNames["Double-Bladed Scythe"]) or 0)
		end
	end

	-- Greater Shrine "Power": one multiplier over the whole number, on
	-- EVERY lane -- weapon, magic and relic bursts alike (it sits after
	-- the untyped-lane branches above on purpose). Run-scoped, stacks.
	totalDamage *= 1 + PlayerStatsService:GetGreaterShrineEffect(player, "Damage")

	local critChance, critMultiplier = self:GetCritParameters(player, isMagic, isMelee, targetModel, snapshot, statuses)
	if untypedOnly then
		critChance = -1 -- relic bursts never crit on the untyped lane
	end

	local mobName = targetModel.Name
	local isProjectileResistant = ZombieData[mobName] and ZombieData[mobName].isProjectileResistant or false
	local isMagicResistant = ZombieData[mobName] and ZombieData[mobName].isMagicResistant or false

	-- Damage-type resistances (ZombieData flags): x0.5 vs the resisted
	-- type, grey number, matching resist sound on the client. RELIC-SOURCED
	-- damage bypasses both: a relic's listed number is what it deals —
	-- previously TNT / tremor / Ghost Dragon (neither melee nor magic) were
	-- silently halved by projectile-resistant mobs via the not-melee-not-
	-- magic bucket below. Projectile resistance is against BULLETS: a spell
	-- Sword of the Epicredness turned into weapon damage is not one, and it
	-- landed in the not-melee-not-magic bucket the same way until it was
	-- excluded here.
	local isMagicResistedHit = isMagicResistant and isMagic and not isRelicSourced
	local isResistedHit = (
		isProjectileResistant
		and not isMelee
		and not isMagic
		and not isRelicSourced
		and not isConvertedSpell
	) or isMagicResistedHit

	-- Number colour by damage kind: resisted grey > magic purple > weapon
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
	-- as a double impact. Melee and magic keep the sparks.
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
			self:_postDamage(player, humanoid, true, relicSourced)
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
		self:_postDamage(player, humanoid, false, relicSourced)
	else
		if math.random() * 100 <= critChance then
			local combinedDamage = math.round(totalDamage * critMultiplier)

			showIndicator(player, targetModel, combinedDamage, true, hitColor, isMelee)
			humanoid:TakeDamage(combinedDamage)
			self._onDamageModules["TeddyTrap"](player, combinedDamage)
			self:_postDamage(player, humanoid, true, relicSourced)
			return
		end

		showIndicator(player, targetModel, math.round(totalDamage), false, hitColor, isMelee)

		humanoid:TakeDamage(math.round(totalDamage))
		self._onDamageModules["TeddyTrap"](player, math.round(totalDamage))
		self:_postDamage(player, humanoid, false, relicSourced)
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
		self._recentDamageTaken[player.UserId] = nil
	end)
end

return DamageService
