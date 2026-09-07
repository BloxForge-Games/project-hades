--[[
	Module: StatusConditionService.lua
	Description:
	Data-driven status conditions on MOBS (Burn / Black Flame / Chill /
	Shock / Coil Shocked / Poison / Noxious Venom / Painted). Tuning lives
	in Shared/Data/StatusConditionData.lua; this service owns application,
	refresh, the DoT loops, the aura VFX, and the attribute contract the
	rest of combat reads.

	STACKING (2026 element-tree rework):
	  * Burn / Poison are PER-PLAYER stacks: each player owns at most ONE
	    instance of each on a mob.
	  * NoxiousVenom is per-player up to StatusConditionData.stackLimit (3):
	    applications past the cap refresh ALL of that player's stacks.
	  * BlackFlame stacks per player ALONGSIDE that player's Burn.
	  * Chill / Shock / Paint: one shared instance per mob, refresh by
	    anyone. CoilShocked: one shared instance, alongside Shock.

	REDIRECTS (decided per APPLICATION, owner-relic gated; only Black Flame
	also needs an aura, because only its card names one):
	  Burn   -> BlackFlame    while Enflamed     (Flame Ronin Katana)
	  Poison -> NoxiousVenom  unconditional      (Skeletal Scythe)
	  Shock  -> CoilShocked   unconditional      (Deluxe Coil Gun)
	Redirected, never doubled — the upgraded status lands INSTEAD of the
	base one. Drop out of the aura and your next application is the base
	status again, while upgraded stacks tick out their timers.

	FAMILIES: payoffs that ask "is this target Burning / Poisoned /
	Shocked" must use IsBurning / IsPoisoned / IsShocked — the upgraded
	variants stamp their OWN attribute, so a raw StatusBurn read misses a
	Black Flame. Each variant still counts as its own DISTINCT status for
	per-status counting (Overseer's Battleaxe, Neon Rainbow Phoenix).

	Poison weaken: each player's PILE of Poison/Noxious stacks weakens
	the mob's outgoing damage ONCE, at the pile's strongest record —
	"(Weaken does not stack)" per Skeletal Scythe's card. Different
	players' piles sum additively, capped at POISON_WEAKEN_CAP.

	Attribute contract (on the mob MODEL):
	  "Status<Name>" (boolean)        -- >=1 live instance of that status.
	  "StatusSlowMultiplier" (number) -- 0..1 walk-speed multiplier from
	                                     Chill.

	VFX: ONE emitter rig per unique VISUAL per mob, refcounted — stacks
	read through damage ticks, never through duplicate rigs.

	Appliers: RELIC_HIT_STATUSES rows (chances for the same status sum
	additively into ONE roll per hit), RELIC_HIT_AURAS rows (chance to
	GRANT the owner an aura on hit), plus the Status Chance bonus —
	percentage points added to every status the player already has a
	qualifying applier row for (Blighted's +15, Mechatronic Spider's +15).
	Direct weapon/magic hits and relic procs roll appliers; DoT ticks do
	NOT.
]]

--[ Roblox Services ]--

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

--[ Exports & Types & Defaults ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local StatusConditions = require(ReplicatedStorage.Submodules.Core.Shared.Enums.StatusConditions)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local AuraNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.AuraNames)
local RelicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicData)
local StatusConditionData = require(ReplicatedStorage.Submodules.Core.Shared.Data.StatusConditionData)
local getPlayerLevel = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Player.getPlayerLevel)

local DataService
local DamageService
local DamageIndicatorService
local RelicService
local AuraService

local StatusConditionService = Knit.CreateService({
	Name = "StatusConditionService",
	Client = {},
})

--[ Constants ]--

local STATUS_ATTRIBUTE_PREFIX = "Status"
local SLOW_ATTRIBUTE = "StatusSlowMultiplier"
local VFX_FADE_SECONDS = 1.5
local EXPIRY_POLL_SECONDS = 0.1

-- The DoT statuses stack PER PLAYER (default one stack each;
-- StatusConditionData.stackLimit raises it — NoxiousVenom's 3). Everything
-- else is one shared instance per mob.
local STACKABLE: { [string]: boolean } = {
	[StatusConditions.Burn] = true,
	[StatusConditions.BlackFlame] = true,
	[StatusConditions.Poison] = true,
	[StatusConditions.NoxiousVenom] = true,
}

-- Family sets: the upgraded variants ARE their base status for every
-- "is this target X" payoff, while remaining distinct statuses.
local BURN_FAMILY: { [string]: boolean } = {
	[StatusConditions.Burn] = true,
	[StatusConditions.BlackFlame] = true,
}
local POISON_FAMILY: { [string]: boolean } = {
	[StatusConditions.Poison] = true,
	[StatusConditions.NoxiousVenom] = true,
}
local SHOCK_FAMILY: { [string]: boolean } = {
	[StatusConditions.Shock] = true,
	[StatusConditions.CoilShocked] = true,
}

-- Poison weaken cap across every stack on one mob. Balance lever.
local POISON_WEAKEN_CAP = 0.50

-- Upgrade redirects: applying `from` while the OWNER has `aura` up and owns
-- `relicName` lands `to` instead. Checked at the top of ApplyStatus.
local STATUS_REDIRECTS = {
	[StatusConditions.Burn] = {
		to = StatusConditions.BlackFlame,
		relicName = RelicNames["Flame Ronin Katana"],
		aura = AuraNames.Enflamed,
	},
	-- No aura gate: both cards dropped their aura clause in the 2026-08
	-- pass and became NC openers. Owning the relic is the whole condition,
	-- so the upgrade is available from the moment the relic is picked up.
	[StatusConditions.Poison] = {
		to = StatusConditions.NoxiousVenom,
		relicName = RelicNames["Skeletal Scythe"],
	},
	[StatusConditions.Shock] = {
		to = StatusConditions.CoilShocked,
		relicName = RelicNames["Deluxe Coil Gun"],
	},
}

-- Ice Breaker: applying Chill to an already-Chilled mob CONSUMES the Chill
-- and Shatters for a flat per-level burst. Keep in sync with RelicData.
local ICE_BREAKER_DAMAGE_PER_LEVEL = 75

-- Staff of Azure Ever Ice: while Frostburst is up the owner's Shatters are
-- AoE (this radius) and DOUBLE VFX size, matching the card. An older
-- comment here claimed triple; the code has always fired 2x, so the
-- comment was the wrong half.
--
-- (Its Frost Crater was cut in the element rework — the staff's damage
-- half is now a flat Magic Damage rider in DamageService/AuraDamage.)
local AZURE_SHATTER_RADIUS = 10

-- Minimum gap between two plays of the SAME status sound, globally across
-- every mob — an AoE fresh-applying one status to eight mobs in a frame
-- would phase-stack eight identical stings without it.
local SOUND_DEBOUNCE_SECONDS = 0.1

--[ Properties ]--

-- Active statuses per mob: [model] = { [status] = value } where value is
--   * shared statuses (Chill/Shock/CoilShocked/Paint): the live record
--   * stackable statuses: { [userId] = { record, ... } } — an ARRAY per
--     player, length capped by StatusConditionData.stackLimit (default 1).
-- A record:
--   { expiresAt, sourcePlayer, dotTickDamageCap, dotMultiplier,
--     slowFraction, weakenFraction, visualKey }
StatusConditionService._active = {}

-- Refcounted visuals per mob: [model] = { [visualKey] = { count, emitters } }.
-- visualKey is the GameAssets.Auras folder name ("Burn", "BlackFlame",
-- "Poison", "NoxiousPoison", ...). Four burn stacks = one rig at count 4.
StatusConditionService._visuals = {}

--[ Private Functions ]--

local function ownerHasAura(player: Player?, auraName: string?): boolean
	if not player or not auraName then
		return false
	end
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	return hrp ~= nil and hrp:FindFirstChild(auraName) ~= nil
end

-- Modifiers that apply to EVERY status, not one entry's relicModifiers.
-- EMPTY since the 2026-08 pass: Foul Poison Fowl was the only entry, and
-- its card is now a Weaken relic rather than a duration one. Kept because
-- the resolver reads it unconditionally and a future global modifier
-- belongs here rather than in every status entry.
local GLOBAL_RELIC_MODIFIERS = {}

-- Resolves the effective duration / magnitudes for THIS application from
-- the base config plus the applier's owned-relic modifiers. Mods with
-- `requiresAura` only count while the APPLIER has that aura up (Foul
-- Poison Fowl's Blighted gate).
function StatusConditionService:_resolveApplication(sourcePlayer: Player, config)
	local duration = config.duration
	local dotMultiplier = 1
	local slowFraction = config.slowFraction or 0
	local weakenFraction = 1 - (config.outgoingDamageMultiplier or 1)

	if RelicService then
		for relicName, mods in GLOBAL_RELIC_MODIFIERS do
			if (RelicService:GetSpecificRelicRegistry(sourcePlayer, relicName) or 0) > 0 then
				if not (mods.requiresAura and not ownerHasAura(sourcePlayer, mods.requiresAura)) then
					duration *= mods.durationMultiplier or 1
				end
			end
		end
	end

	if config.relicModifiers and RelicService then
		for relicName, mods in config.relicModifiers do
			if (RelicService:GetSpecificRelicRegistry(sourcePlayer, relicName) or 0) > 0 then
				if mods.requiresAura and not ownerHasAura(sourcePlayer, mods.requiresAura) then
					continue
				end
				duration += mods.bonusDuration or 0
				duration *= mods.durationMultiplier or 1
				dotMultiplier *= mods.dotMultiplier or 1
				slowFraction += mods.bonusSlowFraction or 0
				weakenFraction += mods.bonusWeaken or 0
			end
		end
	end

	return duration, dotMultiplier, slowFraction, weakenFraction
end

-- Per-tick DoT cap, resolved once per application/refresh (cap follows the
-- APPLIER's level).
function StatusConditionService:_resolveTickCap(sourcePlayer: Player, config): number
	local profile = DataService and DataService:GetProfileData(sourcePlayer)
	local playerLevel = (profile and profile.Level) or 1
	return playerLevel * (config.dotTickCapPerLevel or 25)
end

-- The redirect decision for THIS application (see STATUS_REDIRECTS).
-- Tolerates a nil applier — it runs ahead of ApplyStatus's own guards.
function StatusConditionService:_resolveRedirect(sourcePlayer: Player?, status: string): string
	local redirect = STATUS_REDIRECTS[status]
	if not redirect or not sourcePlayer or not RelicService then
		return status
	end
	if (RelicService:GetSpecificRelicRegistry(sourcePlayer, redirect.relicName) or 0) <= 0 then
		return status
	end
	-- Aura clause only when the redirect HAS one (Black Flame). The
	-- unconditional redirects (Noxious Venom, Coil Shocked) carry aura =
	-- nil, and ownerHasAura(nil) is false — the old bare check silently
	-- disabled BOTH of them.
	if redirect.aura and not ownerHasAura(sourcePlayer, redirect.aura) then
		return status
	end
	return redirect.to
end

-- Clones the visual's ParticleEmitters into the mob's HRP (emitters must
-- live under a BasePart to render — same recipe as AuraService).
local function spawnStatusEmitters(visualKey: string, hrp: BasePart): { ParticleEmitter }
	local aurasFolder = ReplicatedStorage.GameAssets:FindFirstChild("Auras")
	local auraTemplate = aurasFolder and aurasFolder:FindFirstChild(visualKey)
	if not auraTemplate then
		warn("[StatusConditionService] Missing ReplicatedStorage.GameAssets.Auras." .. tostring(visualKey))
		return {}
	end

	local emitters = {}
	for index, particle in auraTemplate:GetDescendants() do
		if particle:IsA("ParticleEmitter") then
			local clone = particle:Clone()
			clone.Name = STATUS_ATTRIBUTE_PREFIX .. visualKey .. tostring(index)
			clone.Enabled = true
			clone.Parent = hrp
			table.insert(emitters, clone)
		end
	end
	return emitters
end

-- Refcounted visual up: first stack of a visual spawns its rig, later
-- stacks just bump the count — ONE rig per visual regardless of stacks.
function StatusConditionService:_incrementVisual(model: Model, hrp: BasePart, visualKey: string)
	local visuals = self._visuals[model]
	if not visuals then
		visuals = {}
		self._visuals[model] = visuals
	end
	local slot = visuals[visualKey]
	if slot then
		slot.count += 1
		return
	end
	visuals[visualKey] = {
		count = 1,
		emitters = spawnStatusEmitters(visualKey, hrp),
	}
end

-- Refcounted visual down: the LAST stack of a visual fades its rig
-- (disable -> wait -> destroy). `keepEmitters` is the death path — the
-- corpse keeps its auras and MobBase's despawn sweep owns the fade.
function StatusConditionService:_decrementVisual(model: Model, visualKey: string, keepEmitters: boolean?)
	local visuals = self._visuals[model]
	local slot = visuals and visuals[visualKey]
	if not slot then
		return
	end
	slot.count -= 1
	if slot.count > 0 then
		return
	end
	visuals[visualKey] = nil
	if next(visuals) == nil then
		self._visuals[model] = nil
	end
	if keepEmitters then
		return
	end

	for _, emitter in slot.emitters do
		if emitter.Parent then
			emitter.Enabled = false
		end
	end
	task.delay(VFX_FADE_SECONDS, function()
		for _, emitter in slot.emitters do
			emitter:Destroy()
		end
	end)
end

-- Last play time per status name, keyed globally. See
-- SOUND_DEBOUNCE_SECONDS.
local lastSoundPlayAt: { [string]: number } = {}

-- One-shot flourish planted where a status LANDS, for statuses shipping an
-- authored model under GameAssets.VFX (StatusConditionData.applyVFXName).
-- Fires alongside the proc sting, on the same mob-level-fresh gate.
local APPLY_VFX_EMIT_COUNT = 10
local APPLY_VFX_LIFETIME = 5

local function playApplyVFX(vfxName: string?, hrp: BasePart)
	if vfxName == nil then
		return
	end

	local vfxFolder = ReplicatedStorage.GameAssets:FindFirstChild("VFX")
	local template = vfxFolder and vfxFolder:FindFirstChild(vfxName)
	if not template then
		warn("[StatusConditionService] Missing ReplicatedStorage.GameAssets.VFX." .. vfxName)
		return
	end

	local burst = template:Clone()
	for _, part in burst:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = true
			part.CanCollide = false
			part.CanQuery = false
		end
	end

	if burst:IsA("PVInstance") then
		burst:PivotTo(hrp.CFrame)
	else
		warn("[StatusConditionService] GameAssets.VFX." .. vfxName .. " is not a Model or Part -- cannot place it")
	end

	burst.Parent = workspace.IgnoreInstances.MagicSpells

	-- Parent FIRST, burst SECOND -- :Emit on an unparented emitter is
	-- silently discarded.
	for _, descendant in burst:GetDescendants() do
		if descendant:IsA("ParticleEmitter") then
			descendant:Emit(APPLY_VFX_EMIT_COUNT)
		end
	end

	Debris:AddItem(burst, APPLY_VFX_LIFETIME)
end

-- Plays the status's proc sting at the mob. The clone is CACHED on the HRP
-- rather than cloned per proc.
local function playStatusSound(status: string, soundName: string?, hrp: BasePart)
	if soundName == nil then
		return
	end

	local now = os.clock()
	if now - (lastSoundPlayAt[status] or -math.huge) < SOUND_DEBOUNCE_SECONDS then
		return
	end
	lastSoundPlayAt[status] = now

	local sound = hrp:FindFirstChild(soundName)
	if sound == nil then
		local soundsFolder = ReplicatedStorage.GameAssets:FindFirstChild("Sounds")
		local template = soundsFolder and soundsFolder:FindFirstChild(soundName)
		if not template then
			warn("[StatusConditionService] Missing ReplicatedStorage.GameAssets.Sounds." .. soundName)
			return
		end
		sound = template:Clone()
		sound.Parent = hrp
	end

	sound:Play()
end

-- Count of live instances of `status` on the mob (stack count for
-- stackables, 0/1 for the shared statuses).
function StatusConditionService:_countInstances(model: Model, status: string): number
	local entry = self._active[model]
	local value = entry and entry[status]
	if not value then
		return 0
	end
	if not STACKABLE[status] then
		return 1
	end
	local count = 0
	for _, stack in value do
		count += #stack
	end
	return count
end

-- Shared bookkeeping after any instance is removed: clear the mob
-- attribute when the LAST instance of that status went away.
function StatusConditionService:_afterInstanceRemoved(model: Model, status: string, slowFraction: number?)
	local entry = self._active[model]
	if entry then
		local value = entry[status]
		if value and STACKABLE[status] then
			for userId, stack in value do
				if #stack == 0 then
					value[userId] = nil
				end
			end
			if next(value) == nil then
				entry[status] = nil
			end
		end
		if next(entry) == nil then
			self._active[model] = nil
		end
	end

	if self:_countInstances(model, status) == 0 and model.Parent then
		model:SetAttribute(STATUS_ATTRIBUTE_PREFIX .. status, nil)
		if slowFraction and slowFraction > 0 then
			model:SetAttribute(SLOW_ATTRIBUTE, nil)
		end
	end
end

-- Removes ONE record from the books, returning true if it was live.
-- Shared statuses ignore `record` (there is only one).
local function detachRecord(entry, status: string, userId: number?, record): boolean
	local value = entry and entry[status]
	if not value then
		return false
	end
	if STACKABLE[status] then
		local stack = userId and value[userId]
		if not stack then
			return false
		end
		local index = table.find(stack, record)
		if not index then
			return false
		end
		table.remove(stack, index)
		return true
	end
	if record ~= nil and value ~= record then
		return false
	end
	entry[status] = nil
	return true
end

-- Drops one instance WITHOUT touching its visuals' emitters — the death
-- path. Auras persist on the corpse by design; MobBase's despawn sweep
-- owns the fade.
function StatusConditionService:_releaseInstanceKeepEmitters(model: Model, status: string, userId: number?, record)
	local entry = self._active[model]
	if not entry or not detachRecord(entry, status, userId, record) then
		return
	end
	self:_decrementVisual(model, record.visualKey, true)
	self:_afterInstanceRemoved(model, status, record.slowFraction)
end

-- Tears down one instance: attribute off (when it was the last), slow
-- released, visual refcount down.
function StatusConditionService:_expireInstance(model: Model, status: string, userId: number?, record)
	local entry = self._active[model]
	if not entry or not detachRecord(entry, status, userId, record) then
		return
	end
	self:_decrementVisual(model, record.visualKey, false)
	self:_afterInstanceRemoved(model, status, record.slowFraction)
end

--[ Public Functions ]--

-- True while `status` is active on the mob (any player's stack counts).
function StatusConditionService:IsStatusActive(model: Model, status: string): boolean
	return model:GetAttribute(STATUS_ATTRIBUTE_PREFIX .. status) == true
end

local function anyFamilyAttribute(model: Model, family: { [string]: boolean }): boolean
	if not model then
		return false
	end
	for status in family do
		if model:GetAttribute(STATUS_ATTRIBUTE_PREFIX .. status) == true then
			return true
		end
	end
	return false
end

-- Family queries — the single answers to "is this target burning /
-- poisoned / shocked". Callers must not read the base attribute directly:
-- the upgraded variants stamp their own.
function StatusConditionService:IsBurning(model: Model): boolean
	return anyFamilyAttribute(model, BURN_FAMILY)
end

function StatusConditionService:IsPoisoned(model: Model): boolean
	return anyFamilyAttribute(model, POISON_FAMILY)
end

function StatusConditionService:IsShocked(model: Model): boolean
	return anyFamilyAttribute(model, SHOCK_FAMILY)
end

-- The live applier of a SHARED status instance (Shock, CoilShocked, Chill,
-- Paint) — nil when the status isn't up or is stackable. Owner-conditional
-- payoffs read this (Throwing Bolts' +5%, Painted's "+20% from you").
function StatusConditionService:GetStatusSourcePlayer(model: Model, status: string): Player?
	local entry = self._active[model]
	local value = entry and entry[status]
	if not value or STACKABLE[status] then
		return nil
	end
	return value.sourcePlayer
end

-- Outgoing-damage multiplier for a poisoned mob: each Poison AND Noxious
-- Venom stack contributes its record's weakenFraction (10pp base, +10pp
-- when the applier owns Poisonous Butterfly), additive, capped. 1 when
-- unpoisoned.
-- The TOTAL live Weaken on a target, from every applier and every stack,
-- clamped to the cap. Foul Poison Fowl's damage half reads this directly;
-- the multiplier below is the same number expressed as a scalar.
function StatusConditionService:GetPoisonWeakenFraction(model: Model): number
	local entry = self._active[model]
	if not entry then
		return 0
	end

	local totalWeaken = 0
	for status in POISON_FAMILY do
		local stacks = entry[status]
		if stacks then
			for _, stack in stacks do
				-- "(Weaken does not stack)" — Skeletal Scythe's card. One
				-- player's pile weakens once, at its strongest record;
				-- different players' piles still sum.
				local strongest = 0
				for _, record in stack do
					strongest = math.max(strongest, record.weakenFraction or 0)
				end
				totalWeaken += strongest
			end
		end
	end

	return math.min(totalWeaken, POISON_WEAKEN_CAP)
end

function StatusConditionService:GetPoisonWeakenMultiplier(model: Model): number
	return 1 - self:GetPoisonWeakenFraction(model)
end

-- Relic -> on-hit status appliers, rolled by BOTH damage paths. Chances
-- for the SAME status stack ADDITIVELY; the hub sums them and makes ONE
-- roll per status per hit.
-- Row conditions:
--   weaponOnly / rangedOnly : Magenta Paintball Gun paints on ranged
--                             weapon hits only.
--   auraGate                : row counts only while the OWNER has that
--                             aura up (the "While <aura>..." relics).
-- CHANCE RESOLUTION: a row WITHOUT `chance` reads the relic's callback at
-- roll time (GetRelicEffect), so RelicData — the description's home — is
-- the single source of truth. `chance` remains ONLY for relics whose
-- callback means something else (Magenta Paintball Gun's is its Painted
-- damage multiplier, so its apply chance must live here).
local RELIC_HIT_STATUSES = {
	-- The four tree status enablers (NC).
	{ relicName = RelicNames["Ye Olde Fire Breath Potion"], status = StatusConditions.Burn },
	{ relicName = RelicNames["Frozen Blue Ice Crossbow"], status = StatusConditions.Chill },
	{ relicName = RelicNames["Zombie Axe"], status = StatusConditions.Poison },
	{ relicName = RelicNames["Static Shock Sheep"], status = StatusConditions.Shock },
	-- Deluxe Coil Gun's applier half. Its OTHER half is the Shock ->
	-- Coil Shocked redirect above; this row is what lets an NC pickup
	-- actually produce the Shock it then upgrades.
	{ relicName = RelicNames["Deluxe Coil Gun"], status = StatusConditions.Shock },
	-- Skeletal Scythe's applier half: +10% Poison chance on every hit
	-- (the roll-time callback read), so the NC pickup PRODUCES the
	-- Poison it then upgrades — Deluxe Coil Gun's exact pattern.
	{ relicName = RelicNames["Skeletal Scythe"], status = StatusConditions.Poison },
	-- The four aura-gated chance boosters that used to live here (Faux
	-- Firebrand, Blizzard Wand, Lightning Wand, Overseer's Short Sword)
	-- are all gone: the 2026-08 pass turned the first three into damage
	-- relics, and Short Sword's boost now covers EVERY elemental status
	-- rather than Poison alone, so it lives in _getStatusChanceBonus.
	-- Magenta Paintball Gun: 35% on ranged weapon hits.
	{
		relicName = RelicNames["Magenta Paintball Gun"],
		status = StatusConditions.Paint,
		chance = 0.35,
		weaponOnly = true,
		rangedOnly = true,
	},
}

-- Relic -> on-hit AURA grants, rolled at the damage entry points (per HIT
-- per TARGET — a fireball clipping three mobs rolls three times; DoT ticks
-- never roll). Each row is an independent roll gated to its damage side;
-- the grant routes through AuraService:SetAura so duration bonuses and the
-- Abyss lockout apply for free.
--
-- Lightning Orb is deliberately NOT here: its trigger is CRITICAL HITS
-- (any instance, either damage side), which only DamageService can see —
-- it rolls from _postDamage's crit branch instead.
local RELIC_HIT_AURAS = {
	{ relicName = RelicNames["Flaming Bo Staff"], aura = AuraNames.Enflamed, weaponOnly = true },
	{ relicName = RelicNames["Korblox Spell Book"], aura = AuraNames.Frostburst, magicOnly = true },
}

-- Status Chance: percentage points added to EVERY status the player
-- already has at least one qualifying applier row for. Owning no appliers
-- means it grants nothing — it boosts, it never enables.
-- Blighted itself no longer grants status CHANCE — the 2026-08 pass made
-- the aura a damage bonus instead, because a chance multiplier granted
-- literally nothing to a player owning no status appliers. Overseer's
-- Short Sword inherited the role, where it can be gated properly.
--
-- Mechatronic Spider used to add here too; it is a damage relic now and
-- DamageService owns it.
-- "Your Elemental Statuses" = the five tree statuses and their upgrades.
-- Painted is deliberately absent: it belongs to a Neutral relic, and a
-- Venom card should not quietly buff Magenta Paintball Gun.
local ELEMENTAL_STATUSES: { [string]: boolean } = {
	[StatusConditions.Burn] = true,
	[StatusConditions.BlackFlame] = true,
	[StatusConditions.Chill] = true,
	[StatusConditions.Poison] = true,
	[StatusConditions.NoxiousVenom] = true,
	[StatusConditions.Shock] = true,
	[StatusConditions.CoilShocked] = true,
}

function StatusConditionService:_getStatusChanceBonus(sourcePlayer: Player): number
	if not RelicService or not ownerHasAura(sourcePlayer, AuraNames.Blighted) then
		return 0
	end
	if (RelicService:GetSpecificRelicRegistry(sourcePlayer, RelicNames["Overseer's Short Sword"]) or 0) <= 0 then
		return 0
	end
	return RelicService:GetRelicEffect(sourcePlayer, RelicNames["Overseer's Short Sword"]) or 0
end

-- Sums the qualifying rows for one hit into { [status] = chance }.
function StatusConditionService:_sumApplierChances(
	sourcePlayer: Player,
	isWeaponHit: boolean,
	isRanged: boolean?
): { [string]: number }
	local character = sourcePlayer.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")

	local chanceByStatus: { [string]: number } = {}
	for _, row in RELIC_HIT_STATUSES do
		if row.weaponOnly and not isWeaponHit then
			continue
		end
		if row.rangedOnly and not isRanged then
			continue
		end
		if row.auraGate and (not hrp or hrp:FindFirstChild(row.auraGate) == nil) then
			continue
		end
		if RelicService:GetSpecificRelicRegistry(sourcePlayer, row.relicName) > 0 then
			local chance = row.chance or RelicService:GetRelicEffect(sourcePlayer, row.relicName) or 0
			chanceByStatus[row.status] = (chanceByStatus[row.status] or 0) + chance
		end
	end

	-- Korblox Mage Staff: ADDITIVE Chill chance, raised while Frostburst is
	-- up. Lives in the shared hub because its card says "on ALL damage" —
	-- it sat in the MAGIC-only path until this pass, a leftover from when it
	-- read "your Magic Damage has triple the Chill chance".
	--
	-- Additive, not a multiplier: x3 of nothing is still nothing, so the old
	-- shape granted zero to a player with no Chill applier and could never
	-- have been the NC opener the card now makes it.
	if (RelicService:GetSpecificRelicRegistry(sourcePlayer, RelicNames["Korblox Mage Staff"]) or 0) > 0 then
		local staffData = RelicData[RelicNames["Korblox Mage Staff"]]
		local raised = staffData and staffData.data and staffData.data.frostburstChance
		local chance = if ownerHasAura(sourcePlayer, AuraNames.Frostburst)
			then raised or 0.50
			else RelicService:GetRelicEffect(sourcePlayer, RelicNames["Korblox Mage Staff"]) or 0
		chanceByStatus[StatusConditions.Chill] = (chanceByStatus[StatusConditions.Chill] or 0) + chance
	end

	-- Status Chance bonus: +pp on every status that already has a chance —
	-- applied AFTER the sum so it can never conjure a status from nothing.
	local statusChanceBonus = self:_getStatusChanceBonus(sourcePlayer)
	if statusChanceBonus > 0 then
		for status, chance in chanceByStatus do
			if ELEMENTAL_STATUSES[status] then
				chanceByStatus[status] = chance + statusChanceBonus
			end
		end
	end

	return chanceByStatus
end

-- Rolls the aura-grant rows for one hit. `isWeaponHit` picks which side's
-- rows qualify (Flaming Bo Staff is weapon-only, Korblox Spell Book
-- magic-only).
function StatusConditionService:_rollAuraGrants(sourcePlayer: Player, isWeaponHit: boolean)
	if not RelicService or not AuraService then
		return
	end
	local character = sourcePlayer.Character
	if not character then
		return
	end
	for _, row in RELIC_HIT_AURAS do
		if row.weaponOnly and not isWeaponHit then
			continue
		end
		if row.magicOnly and isWeaponHit then
			continue
		end
		local chance = row.chance or RelicService:GetRelicEffect(sourcePlayer, row.relicName) or 0
		if RelicService:GetSpecificRelicRegistry(sourcePlayer, row.relicName) > 0 and math.random() <= chance then
			AuraService:SetAura(sourcePlayer, row.aura, character)
		end
	end
end

-- Korblox Evil Eye: ONE roll per hit to Blight the owner. The chance is
-- the relic callback's base normally, and RelicData's `onStatusChance`
-- when the same hit actually landed a status — "increased TO", so the
-- two REPLACE each other rather than stacking. Rolled once per hit, not
-- once per status, so a hit that applies two statuses is not two chances.

function StatusConditionService:_rollEvilEyeBlight(sourcePlayer: Player, appliedStatus: boolean)
	if not AuraService or not RelicService or not sourcePlayer.Character then
		return
	end
	if (RelicService:GetSpecificRelicRegistry(sourcePlayer, RelicNames["Korblox Evil Eye"]) or 0) <= 0 then
		return
	end

	local eyeData = RelicData[RelicNames["Korblox Evil Eye"]]
	local onStatus = eyeData and eyeData.data and eyeData.data.onStatusChance
	local chance = if appliedStatus
		then onStatus or 0.25
		else RelicService:GetRelicEffect(sourcePlayer, RelicNames["Korblox Evil Eye"]) or 0
	if chance > 0 and math.random() <= chance then
		-- Through SetAura, so the Abyss lockout, duration bonuses and the
		-- extend-only rule all apply for free.
		AuraService:SetAura(sourcePlayer, AuraNames.Blighted, sourcePlayer.Character)
	end
end

-- Weapon-hit status entry point — the ONE call both weapon damage paths
-- make after landing a hit on a mob.
function StatusConditionService:ApplyWeaponOnHitStatuses(
	sourcePlayer: Player,
	_weaponModel: Instance?,
	targetModel: Model,
	isRanged: boolean?
)
	if not RelicService then
		return
	end

	self:_rollAuraGrants(sourcePlayer, true)

	local chanceByStatus = self:_sumApplierChances(sourcePlayer, true, isRanged)
	local appliedStatus = false
	for status, chance in chanceByStatus do
		if math.random() <= chance then
			self:ApplyStatus(sourcePlayer, targetModel, status, true)
			appliedStatus = true
		end
	end

	-- AFTER the status rolls resolve: the Evil Eye chance depends on
	-- whether this hit landed one.
	self:_rollEvilEyeBlight(sourcePlayer, appliedStatus)
end

-- Magic-hit status entry point — called by onHitboxDamage after a spell's
-- damage lands on a mob (covers regular spells and relic-cast magic).
function StatusConditionService:ApplyMagicOnHitStatuses(sourcePlayer: Player, targetModel: Model)
	if not RelicService then
		return
	end

	self:_rollAuraGrants(sourcePlayer, false)

	local chanceByStatus = self:_sumApplierChances(sourcePlayer, false, false)

	local appliedStatus = false
	for status, chance in chanceByStatus do
		if math.random() <= chance then
			self:ApplyStatus(sourcePlayer, targetModel, status, false)
			appliedStatus = true
		end
	end

	self:_rollEvilEyeBlight(sourcePlayer, appliedStatus)
end

-- Starts the per-instance DoT loop + expiry watcher. `getLive` verifies
-- the record still sits in its slot so a superseded/expired instance stops
-- its threads.
function StatusConditionService:_startInstanceThreads(
	model: Model,
	humanoid: Humanoid,
	status: string,
	config,
	record,
	userId: number?
)
	local function getLive(): boolean
		local entry = self._active[model]
		local value = entry and entry[status]
		if not value then
			return false
		end
		if STACKABLE[status] then
			local stack = userId and value[userId]
			return stack ~= nil and table.find(stack, record) ~= nil
		end
		return value == record
	end

	-- DoT loop. Per-tick damage = total % of max health spread over the
	-- BASE duration's ticks — refresh/bonus-duration extends the ticking
	-- at the same rate. Each STACK runs its own loop on its own applier's
	-- magnitudes. DoT ticks sit OUTSIDE the damage amplifier chain and can
	-- never crit or roll appliers.
	if config.dotPercentOfMaxHealth then
		local tickInterval = config.tickInterval or 1
		local ticksInBaseDuration = math.max(1, math.floor(config.duration / tickInterval))
		local percentPerTick = config.dotPercentOfMaxHealth / ticksInBaseDuration

		task.spawn(function()
			while true do
				if not getLive() or not model.Parent or humanoid.Health <= 0 then
					break
				end
				if os.clock() >= record.expiresAt then
					break
				end
				local damage = math.floor(
					math.clamp(humanoid.MaxHealth * percentPerTick * record.dotMultiplier, 1, record.dotTickDamageCap)
				)
				-- Tick number renders in THIS status's colour — the same
				-- StatusConditionData tint the proc burst uses.
				DamageService:TakeDamage(
					record.sourcePlayer,
					humanoid,
					damage,
					false,
					true,
					nil,
					nil,
					nil,
					config.color
				)

				-- A status with its own authored hit VFX (Black Flame) bursts
				-- per tick, not just on landing.
				if config.hitVFXName and DamageIndicatorService then
					DamageIndicatorService:ShowStatusVFX(model, config.color, config.hitVFXName)
				end

				task.wait(tickInterval)
			end
		end)
	end

	-- Expiry watcher. Polls instead of task.delay so refreshes extend the
	-- SAME instance.
	task.spawn(function()
		while model.Parent do
			if not getLive() then
				return -- superseded / already cleaned up
			end
			-- Death: the aura STAYS on the corpse (no fade) — MobBase's
			-- despawn sweep owns the fade. Release just the bookkeeping.
			if humanoid.Health <= 0 then
				self:_releaseInstanceKeepEmitters(model, status, userId, record)
				return
			end
			if os.clock() >= record.expiresAt then
				break
			end
			task.wait(EXPIRY_POLL_SECONDS)
		end
		if getLive() then
			self:_expireInstance(model, status, userId, record)
		end
	end)
end

-- Applies (or refreshes) `status` on `targetModel`, attributed to
-- `sourcePlayer` for DoT credit, level caps, and relic modifiers.
--
-- Stackables: refresh the SOURCE PLAYER's own stack(s); NoxiousVenom
-- appends up to its stackLimit, then refreshes all of that player's
-- stacks. Shared statuses: one instance, refreshed by anyone.
--
-- Returns true on a FRESH application, false on a REFRESH, nil when
-- nothing was applied. Relic hooks split on that seam (Ice Breaker's
-- Shatter consumes a re-Chilled target).
function StatusConditionService:ApplyStatus(
	sourcePlayer: Player,
	targetModel: Model,
	status: string?,
	_isWeaponHit: boolean?
)
	if status == nil or status == StatusConditions.None then
		return
	end

	-- Sword of Eternal Abyss (Cursed): its owner applies NO statuses, full
	-- stop. Ahead of everything else so no applier row, relic hook or
	-- redirect can slip past it.
	if
		sourcePlayer
		and RelicService
		and RelicService:GetSpecificRelicRegistry(sourcePlayer, RelicNames["Sword of Eternal Abyss"]) > 0
	then
		return
	end

	-- Upgrade redirects (Burn -> Black Flame, Poison -> Noxious Venom,
	-- Shock -> Coil Shocked): decided per application, before anything else
	-- resolves, so the target lands ONE status and everything downstream
	-- treats it as the ordinary status it is.
	status = self:_resolveRedirect(sourcePlayer, status)

	local config = StatusConditionData[status]
	if not config then
		warn("[StatusConditionService] No StatusConditionData entry for status: " .. tostring(status))
		return
	end

	local humanoid = targetModel:FindFirstChildOfClass("Humanoid")
	local hrp = targetModel:FindFirstChild("HumanoidRootPart")
	if not humanoid or not hrp or humanoid.Health <= 0 then
		return
	end

	-- Ice Breaker: a Chill landing on an ALREADY-Chilled target (anyone's
	-- chill) consumes it and Shatters INSTEAD of refreshing. Checked before
	-- the ordinary refresh path so the consumed chill can't be re-stamped.
	if status == StatusConditions.Chill and self:_countInstances(targetModel, status) > 0 then
		if self:_tryIceBreakerShatter(sourcePlayer, targetModel) then
			return false
		end
	end

	local duration, dotMultiplier, slowFraction, weakenFraction = self:_resolveApplication(sourcePlayer, config)
	local isStackable = STACKABLE[status] == true
	local userId = sourcePlayer.UserId
	local stackLimit = config.stackLimit or 1

	local entry = self._active[targetModel]
	if not entry then
		entry = {}
		self._active[targetModel] = entry
	end

	local hadAnyInstance = self:_countInstances(targetModel, status) > 0

	local function refreshRecord(record)
		record.expiresAt = os.clock() + duration
		record.sourcePlayer = sourcePlayer
		record.dotMultiplier = dotMultiplier
		record.dotTickDamageCap = self:_resolveTickCap(sourcePlayer, config)
		record.weakenFraction = weakenFraction
		if slowFraction > 0 then
			record.slowFraction = slowFraction
			targetModel:SetAttribute(SLOW_ATTRIBUTE, 1 - slowFraction)
		end
	end

	-- REFRESH paths.
	if isStackable then
		local stacks = entry[status]
		local stack = stacks and stacks[userId]
		if stack and #stack >= stackLimit then
			-- At this player's cap: refresh ALL their stacks — the timer
			-- resets, never a fourth instance.
			for _, record in stack do
				refreshRecord(record)
			end
			return false
		end
	else
		local existing = entry[status]
		if existing then
			refreshRecord(existing)
			return false
		end
	end

	-- FRESH application (a new stack for stackables below the limit).
	local visualKey = config.auraName
	local record = {
		expiresAt = os.clock() + duration,
		sourcePlayer = sourcePlayer,
		dotMultiplier = dotMultiplier,
		dotTickDamageCap = self:_resolveTickCap(sourcePlayer, config),
		slowFraction = slowFraction,
		weakenFraction = weakenFraction,
		visualKey = visualKey,
	}

	if isStackable then
		local stacks = entry[status]
		if not stacks then
			stacks = {}
			entry[status] = stacks
		end
		local stack = stacks[userId]
		if not stack then
			stack = {}
			stacks[userId] = stack
		end
		table.insert(stack, record)
	else
		entry[status] = record
	end

	self:_incrementVisual(targetModel, hrp, visualKey)

	targetModel:SetAttribute(STATUS_ATTRIBUTE_PREFIX .. status, true)
	if slowFraction > 0 then
		targetModel:SetAttribute(SLOW_ATTRIBUTE, 1 - slowFraction)
	end

	-- Proc sting + spark burst: MOB-LEVEL fresh applications only (the mob
	-- had no instance of this status at all) — per-stack stings would
	-- machine-gun in co-op.
	if not hadAnyInstance then
		playStatusSound(status, config.soundName, hrp)
		playApplyVFX(config.applyVFXName, hrp)
		if config.color and DamageIndicatorService then
			DamageIndicatorService:ShowStatusVFX(targetModel, config.color, config.hitVFXName)
		end
	end

	self:_startInstanceThreads(targetModel, humanoid, status, config, record, if isStackable then userId else nil)

	return true
end

-- Ice Breaker's Shatter: consume the Chill, burst the target, and — with
-- Staff of Azure Ever Ice while Frostburst — turn the burst into an AoE.
-- Returns true when a Shatter actually fired
-- (the caller then swallows the application that triggered it).
--
-- Damage is applied RAW (humanoid:TakeDamage) — the number is authored as
-- a final per-level value, and routing it through TakeDamage would run the
-- full amplifier chain over it and re-enter the applier hub.
function StatusConditionService:_tryIceBreakerShatter(sourcePlayer: Player, targetModel: Model): boolean
	if (RelicService:GetSpecificRelicRegistry(sourcePlayer, RelicNames["Ice Breaker"]) or 0) <= 0 then
		return false
	end

	local humanoid = targetModel:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return false
	end

	local shatterDamage = math.round(ICE_BREAKER_DAMAGE_PER_LEVEL * getPlayerLevel(sourcePlayer))
	if shatterDamage <= 0 then
		return false
	end

	-- CONSUME the chill — the element rework made Shatter spend its fuel.
	local entry = self._active[targetModel]
	local chillRecord = entry and entry[StatusConditions.Chill]
	if chillRecord then
		self:_expireInstance(targetModel, StatusConditions.Chill, nil, chillRecord)
	end

	local hrp = targetModel:FindFirstChild("HumanoidRootPart")

	-- Azure: while Frostburst is up the Shatter's VFX doubles in size and
	-- hits everything nearby.
	local isAzure = ownerHasAura(sourcePlayer, AuraNames.Frostburst)
		and (RelicService:GetSpecificRelicRegistry(sourcePlayer, RelicNames["Staff of Azure Ever Ice"]) or 0) > 0

	if hrp and RelicService.Client and RelicService.Client.OnShatterActivated then
		RelicService.Client.OnShatterActivated:FireAll(hrp.Position, if isAzure then 2 else 1)
	end

	local function dealShatter(targetHumanoid: Humanoid, model: Model)
		if model:GetAttribute(Attributes.Invulnerable) == true then
			return
		end
		-- UNTYPED relic lane: Shatter scales with unqualified Damage
		-- bonuses like every other relic burst. TakeDamage owns the
		-- indicator now (relic-white number).
		if DamageService then
			DamageService:TakeDamage(sourcePlayer, targetHumanoid, shatterDamage, false, false, nil, true)
		else
			targetHumanoid:TakeDamage(shatterDamage)
		end
	end

	dealShatter(humanoid, targetModel)

	if isAzure and hrp then
		-- AoE half: every OTHER mob in radius takes the same burst.
		local zombiesFolder = workspace.IgnoreInstances:FindFirstChild("Zombies")
		if zombiesFolder then
			for _, mob in zombiesFolder:GetChildren() do
				if mob ~= targetModel and mob:IsA("Model") then
					local mobHrp = mob:FindFirstChild("HumanoidRootPart")
					local mobHumanoid = mob:FindFirstChildOfClass("Humanoid")
					if
						mobHrp
						and mobHumanoid
						and mobHumanoid.Health > 0
						and (mobHrp.Position - hrp.Position).Magnitude <= AZURE_SHATTER_RADIUS
					then
						dealShatter(mobHumanoid, mob)
					end
				end
			end
		end
	end

	return true
end

--[ Initializers ]--

function StatusConditionService:KnitStart()
	DataService = Knit.GetService("DataService")
	DamageService = Knit.GetService("DamageService")
	DamageIndicatorService = Knit.GetService("DamageIndicatorService")
	RelicService = Knit.GetService("RelicService")
	AuraService = Knit.GetService("AuraService")
end

return StatusConditionService
