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
	            x (1 + rune damage sum)             <- RuneDamagePercent attr
	                                                   (PlayerStatsService
	                                                   stamps it, Abyss-doubled)
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

--[ Exports & Types & Defaults ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local AuraNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.AuraNames)
local AuraData = require(ReplicatedStorage.Submodules.Core.Shared.Data.AuraData)
local StatusConditions = require(ReplicatedStorage.Submodules.Core.Shared.Enums.StatusConditions)
local getPlayerLevel = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Player.getPlayerLevel)
local EnemyType = require(ReplicatedStorage.Submodules.Core.Shared.Enums.EnemyTypes)
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

local DamageIndicatorService
local ShieldService
local RelicService
local StatusConditionService
local PlayerStatsService
local TextIndicatorService
local PlayerEventService
local RagdollService
local LifeService
local ArmorSetBonusService
local AuraService
local MagicService

local DamageService = Knit.CreateService({
	Name = "DamageService",
	Client = {},
})

--[ Constants ]--

-- Baseline crit chance every hit has before any rune, relic or aura.
local DEFAULT_CRITICAL_CHANCE = 5
local DEFAULT_CRITICAL_MULTIPLIER = 1.5
-- Double-Bladed Scythe (Cursed): "-50% less Magic Damage". Its callback owns
-- the +50% WEAPON half, so this drawback lives here as its own knob.
local BONE_SCYTHE_MAGIC_MULTIPLIER = 0.5
local RESISTED_COLOR3 = DamageIndicatorColors.Resisted
local MAGIC_COLOR3 = DamageIndicatorColors.Magic
local WEAPON_COLOR3 = DamageIndicatorColors.Weapon
local RAGDOLL_VELOCITY = 25

-- Status attributes stamped on mob models by StatusConditionService.
-- Direct reads are fine for single statuses; the FAMILY questions ("is it
-- burning / poisoned / shocked") must go through StatusConditionService's
-- IsBurning / IsPoisoned / IsShocked — the upgraded variants (Black Flame,
-- Noxious Venom, Coil Shocked) stamp their own attributes.
local STATUS_ATTRIBUTE_PREFIX = "Status"

-- Rune sums, stamped as replicated attributes by PlayerStatsService (Sword
-- of Eternal Abyss's doubling already applied there).
-- Ceiling on Greater Shrine "Bulwark": nothing stacks it today (one
-- blessing per run), but a per-floor exclusion rule later would, and
-- damage immunity should never be reachable from a free pickup.
local GREATER_SHRINE_MAX_REDUCTION = 0.60
local RUNE_DAMAGE_ATTRIBUTE = "RuneDamagePercent"
local RUNE_CRIT_CHANCE_ATTRIBUTE = "RuneCritChanceBonus"
local RUNE_CRIT_DAMAGE_ATTRIBUTE = "RuneCritDamagePercent"

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

-- How long a last-hit record stays valid.
local LAST_HIT_VALID_SECONDS = 0.25

-- Ban Hammer (Legendary) execute threshold: a CRITICAL HIT finishes a normal
-- enemy at/below this health fraction. Minibosses and bosses are immune.
local EXECUTE_THRESHOLD = 0.15

local PROJECTILE_RESISTANCE_SCALAR = 0.25

-- Ice Dragon Slayer: the "+25% vs Chilled" only counts above this fraction
-- of Maximum Mana.

-- Phoenix / Katana health gates.

--[ Properties ]--

DamageService._onHitRegistry = {}
DamageService._onDamageModules = {}

-- Lightning Horn fan-out latch: [userId] = os.clock() of the last strike.
DamageService._lightningStrikeLast = {}
DamageService._shurikenLastRefund = {}

-- Last FINAL (post-amplifier, post-crit) damage this player dealt, and to
-- whom. [userId] = { model, amount, t }.
DamageService._lastHitDamage = {}

-- Rolling per-player log of damage that actually reached HEALTH (post
-- shield / post-mitigation) — Astral Cloak's dodge heal consumes it.
DamageService._recentDamageTaken = {}

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
function DamageService:PlayerTakeDamage(
	player: Player,
	model: Model,
	damage: number,
	canRagdoll: boolean,
	fixedDamage: boolean?
)
	local character = player.Character
	local humanoid = character and character:FindFirstChild("Humanoid")

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
		TextIndicatorService:ShowIndicator(player, character.Head, "Invulnerable!")
		return
	end

	-- Held so the modifier block below can be UNDONE in one line for a
	-- fixedDamage hit. Restoring afterwards rather than wrapping fifty
	-- lines of relic and aura maths in a conditional: every one of those
	-- reads state and none of them writes any, so letting them compute a
	-- number that is then discarded costs nothing and leaves the block
	-- readable as one continuous mitigation pipeline.
	local fixedAmount = if fixedDamage then damage else nil

	-- ±10% variance on every mob → player hit. Keep intermediate values as
	-- floats; the final humanoid:TakeDamage below rounds once.
	damage = rollDamageVariance(damage)

	if character:GetAttribute(Attributes.SusanooEnabled) == true then
		damage = damage * 0.5
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
		damage = damage * StatusConditionService:GetPoisonWeakenMultiplier(model)
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
		local auraHrp = character:FindFirstChild("HumanoidRootPart")
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

	local zombieHit = character:FindFirstChild("HumanoidRootPart"):FindFirstChild("ZombieHit")

	if zombieHit == nil then
		zombieHit = ReplicatedStorage.GameAssets.Sounds.ZombieHit:Clone()
		zombieHit.Parent = character.HumanoidRootPart
	end

	zombieHit.TimePosition = 0.2
	zombieHit:Play()

	local hitVFX = character:FindFirstChild("HumanoidRootPart"):FindFirstChild("HitFX")

	if hitVFX == nil then
		hitVFX = ReplicatedStorage.GameAssets.VFX.SwordSlash.HitFX:Clone()
		hitVFX.Parent = character.HumanoidRootPart
	end

	for _, particle in pairs(hitVFX:GetChildren()) do
		if not particle:IsA("ParticleEmitter") then
			continue
		end

		if particle.Name == "Hit" then
			particle:Emit(2)
		else
			particle:Emit(6)
		end
	end

	-- Fully absorbed: the hit feedback above still plays, but a shielded
	-- player neither ragdolls nor loses health.
	if damage <= 0 then
		return
	end

	-- Dragon Lantern's coin tax — health damage only.
	if RelicService:GetSpecificRelicRegistry(player, RelicNames["Dragon Lantern"]) > 0 then
		local RunEscrowService = Knit.GetService("RunEscrowService")
		RunEscrowService:TaxCoins(player, DRAGON_LANTERN_COIN_TAX)
	end

	if canRagdoll and character.RagdollTrigger.Value == false then
		if character:GetAttribute(Attributes.SuperArmor) == false then
			RagdollService:Ragdoll(character)

			local direction = (model.HumanoidRootPart.Position - character.HumanoidRootPart.Position).Unit

			local bodyVelocity = Instance.new("BodyVelocity")
			bodyVelocity.MaxForce = Vector3.new(math.huge, math.huge, math.huge)
			bodyVelocity.Velocity = -(direction * RAGDOLL_VELOCITY) + Vector3.new(0, RAGDOLL_VELOCITY, 0)
			bodyVelocity.Parent = character.HumanoidRootPart

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

function DamageService:_recordDamageTaken(player: Player, amount: number)
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
function DamageService:ConsumeRecentDamageTaken(player: Player, windowSeconds: number): number
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
function DamageService:TryExecute(player: Player, humanoid: Humanoid, wasCrit: boolean?)
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

	local enemyType = model:GetAttribute(Attributes.EnemyType)
	if enemyType == EnemyType.Miniboss or enemyType == EnemyType.Boss then
		return
	end

	if (humanoid.Health / humanoid.MaxHealth) > EXECUTE_THRESHOLD then
		return
	end

	-- Guard against a same-frame second damage path executing a corpse.
	model:SetAttribute("BanHammerExecuted", true)

	local indicatorPart = model:FindFirstChild("Head") or model:FindFirstChild("HumanoidRootPart")
	if indicatorPart then
		TextIndicatorService:ShowIndicator(player, indicatorPart, "Banned!", Color3.fromRGB(255, 85, 85), true)
	end

	humanoid:TakeDamage(humanoid.Health)
end

-- Post-damage hub — runs after EVERY damage application inside TakeDamage.
-- `isRelicSourced` blocks the Lightning Strike from re-triggering off
-- relic damage — a strike's own crits can never chain another strike.
function DamageService:_postDamage(player: Player, humanoid: Humanoid, wasCrit: boolean?, isRelicSourced: boolean?)
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

-- Stamps the FINAL damage of the hit that just landed.
function DamageService:_recordLastHit(player: Player, humanoid: Humanoid, amount: number)
	if not player or amount <= 0 then
		return
	end
	self._lastHitDamage[player.UserId] = {
		model = humanoid.Parent,
		amount = amount,
		t = os.clock(),
	}
end

-- The final damage `player` last dealt to `targetModel`, or 0 if their most
-- recent hit was on something else or is too old to trust.
function DamageService:GetLastHitDamage(player: Player, targetModel: Model): number
	local record = self._lastHitDamage[player.UserId]
	if not record or record.model ~= targetModel then
		return 0
	end
	if (os.clock() - record.t) > LAST_HIT_VALID_SECONDS then
		return 0
	end
	return record.amount
end

-- Lightning Orb (Storm Rare): ANY damage — weapon or magic, per TARGET (an
-- AoE hitting three mobs rolls three times), relic procs included — has a
-- chance to grant Stormcharged. TWO TIERS: the callback's base normally,
-- and this when the hit CRIT. "increased to", so they replace each other
-- rather than stacking. Deliberately UNLATCHED, per the design call.
-- Routed through SetAura, so the Abyss lockout and duration bonuses apply
-- for free.

function DamageService:_tryLightningOrbStormcharge(player: Player, wasCrit: boolean?)
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
function DamageService:_tryLightningHornStrike(player: Player, humanoid: Humanoid)
	if RelicService:GetSpecificRelicRegistry(player, RelicNames["Lightning Horn of the Heavens"]) <= 0 then
		return
	end

	local targetModel = humanoid.Parent
	if not targetModel or not StatusConditionService or not StatusConditionService:IsShocked(targetModel) then
		return
	end

	-- The roll, before the latch: a failed roll must not spend the fan-out
	-- window for the other targets of the same AoE crit.
	local hornData = RelicData[RelicNames["Lightning Horn of the Heavens"]]
	local strikeChance = (hornData and hornData.data and hornData.data.strikeChance) or 0.50
	if math.random() > strikeChance then
		return
	end

	local hrp = targetModel:FindFirstChild("HumanoidRootPart")
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
	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = {
		workspace.IgnoreInstances.Zombies,
		workspace.IgnoreInstances.DeadZombies,
	}
	local hit = workspace:Raycast(hrp.Position, Vector3.new(0, -500, 0), raycastParams)
	local strikePosition = hit and hit.Position or hrp.Position

	if RelicService.Client and RelicService.Client.OnLightningStrikeActivated then
		RelicService.Client.OnLightningStrikeActivated:FireAll(strikePosition)
	end

	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Include
	overlapParams.FilterDescendantsInstances = { workspace.IgnoreInstances.Zombies }

	local struck = {}
	for _, part in workspace:GetPartBoundsInRadius(strikePosition, LIGHTNING_STRIKE_RADIUS, overlapParams) do
		local model = part:FindFirstAncestorWhichIsA("Model")
		if not model or struck[model] then
			continue
		end
		local targetHumanoid = model:FindFirstChildOfClass("Humanoid")
		if not targetHumanoid or targetHumanoid.Health <= 0 then
			continue
		end
		struck[model] = true
		-- Full pipeline, relic-sourced: amp chain and crit roll apply, but
		-- relic-sourced damage can never trigger ANOTHER strike, and the
		-- appliers roll per target like any relic magic.
		-- isMagic = false: the strike rides the untyped relic lane; a
		-- magic flag would wrongly pick up Painted's magic vulnerability.
		self:TakeDamage(player, targetHumanoid, strikeDamage, false, false, nil, true)
		if StatusConditionService then
			StatusConditionService:ApplyMagicOnHitStatuses(player, model)
		end
	end
end

-- Shuriken of the Crescent Moon: refund 1% of Maximum Mana on a critical
-- ATTACK. Latched so one AoE crit refunds once.
function DamageService:_tryShurikenManaRefund(player: Player)
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
--   chance = runes + Shuriken (+5) + Ban Hammer (+25) + Stormcharged (+15)
--            + Sparkle Time (+50, magic while Stormcharged)
--            + Ninja Whip (+10 vs Shocked targets)
--   multiplier = 1.5 + runes + Stormcharged (+0.15)
--                + Dragon's Flame Sword (+0.35 vs Burning)
--                + Lightning Bolt Sword (+0.30 vs Shocked)
-- `targetModel` is optional — target-conditional rows skip without one.
function DamageService:GetCritParameters(
	player: Player,
	isMagic: boolean?,
	_isMelee: boolean?,
	targetModel: Model?
): (number, number)
	local critChance = DEFAULT_CRITICAL_CHANCE

	-- Critical Hit Chance runes (attribute already Abyss-doubled).
	critChance += player:GetAttribute(RUNE_CRIT_CHANCE_ATTRIBUTE) or 0

	-- Greater Shrine "Precision". Pooled as a fraction like every other
	-- blessing; crit CHANCE is in points here, so x100.
	critChance += PlayerStatsService:GetGreaterShrineEffect(player, "CritChance") * 100

	-- Ban Hammer: +25% (callback fraction).
	local banHammerEffect = RelicService:GetRelicEffect(player, RelicNames["Ban Hammer"]) or 0
	critChance += banHammerEffect * 100

	-- Silver Ninja Star: flat +15 points, no gate (callback = points).
	if RelicService:GetSpecificRelicRegistry(player, RelicNames["Silver Ninja Star"]) > 0 then
		critChance += RelicService:GetRelicEffect(player, RelicNames["Silver Ninja Star"]) or 0
	end

	-- Shuriken of the Crescent Moon: flat +5 points, from `data` — its
	-- callback slot carries the crit-mana-refund fraction instead.
	if RelicService:GetSpecificRelicRegistry(player, RelicNames["Shuriken of the Crescent Moon"]) > 0 then
		critChance += relicData(RelicNames["Shuriken of the Crescent Moon"], "critChanceBonus", 5)
	end

	local casterHrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	local isStormcharged = casterHrp ~= nil and casterHrp:FindFirstChild(AuraNames.Stormcharged) ~= nil

	-- Stormcharged: crit chance while up (AuraData owns the number).
	if isStormcharged then
		critChance += AuraData[AuraNames.Stormcharged].critChanceBonus or 0

		-- Katana deepens the SAME window, both halves. Its crit-chance half
		-- is the callback (percentage points); the damage half is the
		-- constant below, since a callback returns only one value.
		if RelicService:GetSpecificRelicRegistry(player, RelicNames.Katana) > 0 then
			critChance += RelicService:GetRelicEffect(player, RelicNames.Katana) or 0
		end
	end

	-- Sparkle Time Hoverboard on MAGIC hits while Stormcharged. Read from
	-- the relic callback (percentage points) -- the old local constant
	-- silently stayed at 25 when the relic was buffed to 50, which is
	-- exactly the drift a single source prevents.
	if
		isMagic
		and isStormcharged
		and RelicService:GetSpecificRelicRegistry(player, RelicNames["Sparkle Time Hoverboard"]) > 0
	then
		critChance += RelicService:GetRelicEffect(player, RelicNames["Sparkle Time Hoverboard"]) or 0
	end

	local targetShocked = targetModel ~= nil
		and StatusConditionService ~= nil
		and StatusConditionService:IsShocked(targetModel)

	-- Throwing Bolts vs Shocked targets (callback = percentage points).
	-- This slot used to be Ninja Whip's; the 2026-08 pass turned Ninja Whip
	-- into a takedown proc and moved the crit-chance role here.
	if targetShocked and RelicService:GetSpecificRelicRegistry(player, RelicNames["Throwing Bolts"]) > 0 then
		critChance += RelicService:GetRelicEffect(player, RelicNames["Throwing Bolts"]) or 0
	end

	local critMultiplier = DEFAULT_CRITICAL_MULTIPLIER

	-- Critical Damage runes (attribute already Abyss-doubled).
	critMultiplier += player:GetAttribute(RUNE_CRIT_DAMAGE_ATTRIBUTE) or 0

	-- Greater Shrine "Ferocity". Crit DAMAGE is already a fraction, so
	-- the pooled value adds as-is.
	critMultiplier += PlayerStatsService:GetGreaterShrineEffect(player, "CritDamage")

	-- Stormcharged carries a crit-DAMAGE half again (AuraData owns it, as a
	-- FRACTION -- its crit-CHANCE sibling is in points).
	if isStormcharged then
		critMultiplier += AuraData[AuraNames.Stormcharged].critDamageBonus or 0

		-- Lightning Wand: the Rare crit-damage rider on the same window.
		if RelicService:GetSpecificRelicRegistry(player, RelicNames["Lightning Wand"]) > 0 then
			critMultiplier += RelicService:GetRelicEffect(player, RelicNames["Lightning Wand"]) or 0
		end

		-- Katana deepens the same window's crit-damage half.
		if RelicService:GetSpecificRelicRegistry(player, RelicNames.Katana) > 0 then
			critMultiplier += relicData(RelicNames.Katana, "critDamageBonus", 0.20)
		end
	end

	-- Dragon's Flame Sword: +35% crit damage vs Burning targets (family —
	-- Black Flame counts).
	if
		targetModel
		and StatusConditionService
		and StatusConditionService:IsBurning(targetModel)
		and RelicService:GetSpecificRelicRegistry(player, RelicNames["Dragon's Flame Sword"]) > 0
	then
		critMultiplier += RelicService:GetRelicEffect(player, RelicNames["Dragon's Flame Sword"]) or 0
	end

	-- Lightning Bolt Sword: +25% crit damage always, +50% instead against a
	-- Shocked target. The Shocked value REPLACES the base, it does not add.
	if RelicService:GetSpecificRelicRegistry(player, RelicNames["Lightning Bolt Sword"]) > 0 then
		critMultiplier += if targetShocked
			then relicData(RelicNames["Lightning Bolt Sword"], "shockedBonus", 0.50)
			else RelicService:GetRelicEffect(player, RelicNames["Lightning Bolt Sword"]) or 0
	end

	return critChance, critMultiplier
end

-- The additive TARGET-CONDITIONAL relic bonuses for one hit, as a summed
-- FRACTION (joins the same additive pool as the damage modules).
-- `skipTyped` = the untyped relic lane: rows whose card names Weapon
-- or Magic damage are excluded (magic-gated rows are already out via
-- isMagic = false; weapon-gated rows need the explicit skip).
function DamageService:_sumTargetConditionalBonuses(
	player: Player,
	targetModel: Model,
	isMagic: boolean,
	skipTyped: boolean?
): number
	local bonus = 0

	local humanoid = targetModel:FindFirstChildOfClass("Humanoid")
	local healthFraction = if humanoid and humanoid.MaxHealth > 0 then humanoid.Health / humanoid.MaxHealth else 1

	local isBurning = StatusConditionService ~= nil and StatusConditionService:IsBurning(targetModel)
	local isPoisoned = StatusConditionService ~= nil and StatusConditionService:IsPoisoned(targetModel)
	local isChilled = targetModel:GetAttribute(STATUS_ATTRIBUTE_PREFIX .. StatusConditions.Chill) == true

	-- Blaze payoffs (burning family — Black Flame counts).
	-- Fire Breathing Dragon Friend is WEAPON-only per its card.
	if
		isBurning
		and not isMagic
		and not skipTyped
		and RelicService:GetSpecificRelicRegistry(player, RelicNames["Fire Breathing Dragon Friend"]) > 0
	then
		bonus += (RelicService:GetRelicEffect(player, RelicNames["Fire Breathing Dragon Friend"]) or 1) - 1
	end

	-- Phoenix: below the health gate it pays on ANY target now, with the
	-- Burning value REPLACING the base rather than stacking on it.
	if RelicService:GetSpecificRelicRegistry(player, RelicNames.Phoenix) > 0 then
		if healthFraction < relicData(RelicNames.Phoenix, "healthFraction", 0.5) then
			bonus += if isBurning
				then relicData(RelicNames.Phoenix, "burningBonus", 0.25)
				else (RelicService:GetRelicEffect(player, RelicNames.Phoenix) or 1) - 1
		end
	end

	-- Venom payoffs.
	if isPoisoned and RelicService:GetSpecificRelicRegistry(player, RelicNames["Poisonous Butterfly"]) > 0 then
		bonus += (RelicService:GetRelicEffect(player, RelicNames["Poisonous Butterfly"]) or 1) - 1
	end

	-- Foul Poison Fowl: bonus damage equal to the target's TOTAL live
	-- Weaken, from every applier and every Noxious Venom stack, already
	-- clamped to the weaken cap by the service. Its OTHER half (+10% on
	-- the owner's own Poison) is a relicModifier in StatusConditionData,
	-- so a solo player's own Poison feeds this loop on its own.
	if StatusConditionService and RelicService:GetSpecificRelicRegistry(player, RelicNames["Foul Poison Fowl"]) > 0 then
		bonus += StatusConditionService:GetPoisonWeakenFraction(targetModel)
	end

	-- Mechatronic Spider: pays on every enemy, more on a Poisoned one.
	-- The Poisoned value REPLACES the base.
	if RelicService:GetSpecificRelicRegistry(player, RelicNames["Mechatronic Spider"]) > 0 then
		bonus += if isPoisoned
			then relicData(RelicNames["Mechatronic Spider"], "poisonedBonus", 0.25)
			else (RelicService:GetRelicEffect(player, RelicNames["Mechatronic Spider"]) or 1) - 1
	end

	-- Frost payoffs. Frozen Flail is MAGIC-only per its card.
	if isChilled and isMagic and RelicService:GetSpecificRelicRegistry(player, RelicNames["Frozen Flail"]) > 0 then
		bonus += (RelicService:GetRelicEffect(player, RelicNames["Frozen Flail"]) or 1) - 1
	end

	-- Ice Dragon Slayer: gated on MANA, not on the target. The Chilled
	-- value REPLACES the base.
	if RelicService:GetSpecificRelicRegistry(player, RelicNames["Ice Dragon Slayer"]) > 0 and MagicService then
		local magicData = MagicService:GetPlayerMagicData(player)
		if
			magicData
			and magicData.maxMana
			and magicData.maxMana > 0
			and magicData.mana / magicData.maxMana > relicData(RelicNames["Ice Dragon Slayer"], "manaFraction", 0.5)
		then
			bonus += if isChilled
				then relicData(RelicNames["Ice Dragon Slayer"], "chilledBonus", 0.25)
				else (RelicService:GetRelicEffect(player, RelicNames["Ice Dragon Slayer"]) or 1) - 1
		end
	end

	-- Distinct-status counting, shared by the two per-status payoffs. The
	-- attribute is "at least one instance", so a mob burned by three
	-- players still counts Burn once; every upgraded variant (Black Flame,
	-- Noxious Venom, Coil Shocked) stamps its own attribute and therefore
	-- counts as its own status.
	local statusCount = 0
	for _, status in StatusConditions do
		if status ~= StatusConditions.None and targetModel:GetAttribute(STATUS_ATTRIBUTE_PREFIX .. status) == true then
			statusCount += 1
		end
	end

	-- Neon Rainbow Phoenix: +25% per distinct status, additive.
	if statusCount > 0 and RelicService:GetSpecificRelicRegistry(player, RelicNames["Neon Rainbow Phoenix"]) > 0 then
		local perStatus = (RelicService:GetRelicEffect(player, RelicNames["Neon Rainbow Phoenix"]) or 1) - 1
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
		local attackerHrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		if attackerHrp and attackerHrp:FindFirstChild(AuraNames.Blighted) then
			local perStatus = AuraData[AuraNames.Blighted].damagePerUniqueStatus or 0
			if RelicService:GetSpecificRelicRegistry(player, RelicNames["Overseer's Battleaxe"]) > 0 then
				perStatus += (RelicService:GetRelicEffect(player, RelicNames["Overseer's Battleaxe"]) or 1) - 1
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
function DamageService:_targetVulnerabilityMultiplier(player: Player, targetModel: Model, isMagic: boolean): number
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
				StatusConditionService
				and StatusConditionService:GetStatusSourcePlayer(targetModel, StatusConditions.Paint) == player
			)
		then
			multiplier *= paintConfig.incomingMagicDamageMultiplier or 1
		end
	end

	return multiplier
end

function DamageService:TakeDamage(
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
	-- Cutscene / scripted invulnerability: NO damage of any kind lands.
	if humanoid.Parent and humanoid.Parent:GetAttribute(Attributes.Invulnerable) == true then
		return
	end

	humanoid.Parent:SetAttribute(Attributes.SlainBy, player.Name)

	-- Status condition damage (DoT) bypasses the whole pipeline: no
	-- amplifiers, no crit, no appliers, no hit sparks.
	if isStatusConditionDamage then
		if showHitVFX then
			DamageIndicatorService:ShowIndicator(player, humanoid.Parent, damage, false, indicatorColor, nil, nil, true)
		else
			DamageIndicatorService:ShowIndicatorNoHitVFX(
				player,
				humanoid.Parent,
				damage,
				false,
				indicatorColor,
				nil,
				nil,
				true
			)
		end
		humanoid:TakeDamage(damage)
		self:_postDamage(player, humanoid, false, true)
		return
	end

	-- ±10% per-hit variance, centralized so every caller gets it and the
	-- relic modules read the post-variance damage.
	damage = rollDamageVariance(damage)

	self._onHitRegistry[player.UserId] += 1
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
	if isGunShot and RelicService:GetSpecificRelicRegistry(player, RelicNames["Orinthian Blaster 3777"]) > 0 then
		isConvertedRanged = true
		isMagic = true
	end

	-- UNTYPED-ONLY LANE (design call 2026-08-31): every relic-sourced
	-- burst — pumpkins, Fuse Bomb, Summer Fireworks, Ghost Dragon,
	-- Super Stomp Boots, Golem's Hammer tremors + barrier blast, Bundle
	-- of TNT, Lightning Horn, Zombie Bomb, Ice Breaker — scales with
	-- UNQUALIFIED "Damage" bonuses only (Mechatronic Spider, Phoenix,
	-- Forbidden Box, the hyperlasers, Abyss, runes, target
	-- vulnerability). Weapon Damage / Magic Damage relics, the armor
	-- set's weapon amp, and CRITS never touch relic bursts.
	local untypedOnly = isRelicSourced == true

	-- Weapon-only on-hit side effects (Jail). Relic bursts don't jail.
	if not untypedOnly then
		self._onDamageModules["Jail"](player, humanoid, isMagic)
	end

	-- ADDITIVE RELIC SUM. Each module internally gates itself and returns
	-- `damage x its fraction`, so the sum realizes base x (1 + Σ bonuses).
	local totalDamage = damage
		+ self._onDamageModules["FluffyUnicorn"](player, humanoid, damage)
		+ self._onDamageModules["BlueHyperLaser"](player, damage, isMagic)
		+ self._onDamageModules["RedHyperlaserGun"](player, damage, isMagic)
		+ self._onDamageModules["MurderKnife"](player, humanoid, damage, isMagic)
		+ self._onDamageModules["ForbiddenBox"](player, damage, isMagic)
		-- The five TYPED modules below zero out on the untyped lane.
		+ (if untypedOnly then 0 else self._onDamageModules["GloriousSword"](player, damage, isMagic))
		+ (if untypedOnly then 0 else self._onDamageModules["FlatDamageRelics"](player, damage, isMagic))
		+ (if untypedOnly then 0 else self._onDamageModules["MysticalSigil"](player, damage, isMagic))
		+ (if untypedOnly then 0 else self._onDamageModules["LaserScythes"](player, damage, isMagic))
		+ (if untypedOnly then 0 else self._onDamageModules["AuraDamage"](player, damage, isMagic))
		-- Sword of Eternal Abyss: flat +50%, weapon and magic alike. Inline
		-- rather than a module because it is one unconditional multiplier
		-- with no gating of its own.
		+ (if RelicService:GetSpecificRelicRegistry(player, RelicNames["Sword of Eternal Abyss"]) > 0
			then damage * ((RelicService:GetRelicEffect(player, RelicNames["Sword of Eternal Abyss"]) or 1) - 1)
			else 0)
		+ (
			if untypedOnly
				then 0
				else self._onDamageModules["Volleyball"](
					player,
					humanoid,
					damage,
					self._onHitRegistry,
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

	local targetModel = humanoid.Parent
	if targetModel then
		-- Target-conditional relic bonuses join the SAME additive pool.
		totalDamage += damage * self:_sumTargetConditionalBonuses(player, targetModel, isMagic, untypedOnly)

		-- Then the mob's own vulnerability factor multiplies the total.
		totalDamage *= self:_targetVulnerabilityMultiplier(player, targetModel, isMagic)
	end

	-- Double-Bladed Scythe (Cursed): magic halved, weapon +50%,
	-- multiplicative on the amplified total (a Cursed override, not part of
	-- the additive pool). A TYPED relic, so it obeys the untyped lane like
	-- the modules above — relic bursts arrive as isMagic=false and were
	-- silently taking the weapon +50%.
	if not untypedOnly and RelicService:GetSpecificRelicRegistry(player, RelicNames["Double-Bladed Scythe"]) > 0 then
		if isMagic then
			totalDamage *= BONE_SCYTHE_MAGIC_MULTIPLIER
		else
			totalDamage *= 1 + (RelicService:GetRelicEffect(player, RelicNames["Double-Bladed Scythe"]) or 0)
		end
	end

	-- RUNE FACTOR: multiplies over the whole relic-amplified number (see
	-- the header formula). PlayerStatsService stamps the attribute with
	-- Rune sums arrive final; the Abyss no longer touches them.
	totalDamage *= 1 + (player:GetAttribute(RUNE_DAMAGE_ATTRIBUTE) or 0)

	-- Greater Shrine "Power": one multiplier over the whole number, on
	-- EVERY lane -- weapon, magic and relic bursts alike (it sits after
	-- the untyped-lane branches above on purpose). Run-scoped, stacks.
	totalDamage *= 1 + PlayerStatsService:GetGreaterShrineEffect(player, "Damage")

	local critChance, critMultiplier = self:GetCritParameters(player, isMagic, isMelee, targetModel)
	if untypedOnly then
		critChance = -1 -- relic bursts never crit on the untyped lane
	end

	local mobName = humanoid.Parent.Name
	local isProjectileResistant = ZombieData[mobName] and ZombieData[mobName].isProjectileResistant or false
	local isMagicResistant = ZombieData[mobName] and ZombieData[mobName].isMagicResistant or false

	if self._onHitRegistry[player.UserId] == 100 then
		self._onHitRegistry[player.UserId] = 0
	end

	-- Damage-type resistances (ZombieData flags): x0.5 vs the resisted
	-- type, grey number, matching resist sound on the client. RELIC-SOURCED
	-- damage bypasses both: a relic's listed number is what it deals —
	-- previously TNT / tremor / Ghost Dragon (neither melee nor magic) were
	-- silently halved by projectile-resistant mobs via the not-melee-not-
	-- magic bucket below.
	local isMagicResistedHit = isMagicResistant and isMagic and not isRelicSourced
	local isResistedHit = (isProjectileResistant and not isMelee and not isMagic and not isRelicSourced)
		or isMagicResistedHit

	-- Number colour by damage kind: resisted grey > magic purple > weapon
	-- orange (melee and ranged both — anything that isn't relic-sourced)
	-- > relic white. Crit gold overrides all of these on the client.
	local hitColor: Color3? = if isResistedHit
		then RESISTED_COLOR3
		elseif isMagic then MAGIC_COLOR3
		elseif not isRelicSourced then WEAPON_COLOR3
		else nil
	local resistKind: string? = if isMagicResistedHit then "Magic" elseif isResistedHit then "Projectile" else nil

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
		resist: string?
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

	-- Teddy Trap's lifesteal: the single direct-hit hook — once per landed
	-- hit, once per target for an AoE, never for a DoT tick.
	self._onDamageModules["TeddyTrap"](player)

	if isResistedHit then
		if math.random() * 100 <= critChance then
			local combinedDamage = math.round(totalDamage * critMultiplier)
			showIndicator(
				player,
				humanoid.Parent,
				math.round(combinedDamage * PROJECTILE_RESISTANCE_SCALAR),
				true,
				hitColor,
				isMelee,
				resistKind
			)

			humanoid:TakeDamage(math.round(combinedDamage * PROJECTILE_RESISTANCE_SCALAR))
			self:_recordLastHit(player, humanoid, math.round(combinedDamage * PROJECTILE_RESISTANCE_SCALAR))
			self:_postDamage(player, humanoid, true, isRelicSourced)
			return
		end

		showIndicator(
			player,
			humanoid.Parent,
			math.round(totalDamage * PROJECTILE_RESISTANCE_SCALAR),
			false,
			hitColor,
			isMelee,
			resistKind
		)
		humanoid:TakeDamage(math.round(totalDamage * PROJECTILE_RESISTANCE_SCALAR))
		self:_recordLastHit(player, humanoid, math.round(totalDamage * PROJECTILE_RESISTANCE_SCALAR))
		self:_postDamage(player, humanoid, false, isRelicSourced)
	else
		if math.random() * 100 <= critChance then
			local combinedDamage = math.round(totalDamage * critMultiplier)

			showIndicator(player, humanoid.Parent, combinedDamage, true, hitColor, isMelee)
			humanoid:TakeDamage(combinedDamage)
			self:_recordLastHit(player, humanoid, combinedDamage)
			self:_postDamage(player, humanoid, true, isRelicSourced)
			return
		end

		showIndicator(player, humanoid.Parent, math.round(totalDamage), false, hitColor, isMelee)

		humanoid:TakeDamage(math.round(totalDamage))
		self:_recordLastHit(player, humanoid, math.round(totalDamage))
		self:_postDamage(player, humanoid, false, isRelicSourced)
	end
end

--[ Initializers ]--

function DamageService:KnitStart()
	RelicService = Knit.GetService("RelicService")
	PlayerStatsService = Knit.GetService("PlayerStatsService")
	StatusConditionService = Knit.GetService("StatusConditionService")
	ShieldService = Knit.GetService("ShieldService")
	DamageIndicatorService = Knit.GetService("DamageIndicatorService")
	PlayerEventService = Knit.GetService("PlayerEventService")
	RagdollService = Knit.GetService("RagdollService")
	TextIndicatorService = Knit.GetService("TextIndicatorService")
	LifeService = Knit.GetService("LifeService")
	ArmorSetBonusService = Knit.GetService("ArmorSetBonusService")
	AuraService = Knit.GetService("AuraService")
	MagicService = Knit.GetService("MagicService")

	for _, damageModule in (script:GetChildren()) do
		self._onDamageModules[damageModule.Name] = require(damageModule)
	end

	PlayerEventService.OnPlayerAdded:Connect(function(player: Player)
		self._onHitRegistry[player.UserId] = 0
	end)

	PlayerEventService.OnPlayerRemoved:Connect(function(player: Player)
		self._onHitRegistry[player.UserId] = nil
	end)
end

return DamageService
