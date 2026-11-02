--!strict
--[[
	Module: StatusConditionService.lua
	Description:
	Data-driven status conditions on MOBS (Burn / Black Flame / Chill /
	Shock / Coil Shocked / Poison / Death Venom / Painted). Tuning lives
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
	  Burn   -> BlackFlame    (Flame Ronin Katana)
	  Poison -> NoxiousVenom  unconditional      (Skeletal Scythe)
	  Shock  -> CoilShocked   unconditional      (Deluxe Coil Gun)
	Redirected, never doubled — the upgraded status lands INSTEAD of the
	base one. Drop out of the aura and your next application is the base
	status again, while upgraded stacks tick out their timers.

	FAMILIES: payoffs that ask "is this target Burning / Poisoned /
	Shocked" must use IsBurning / IsPoisoned / IsShocked — the upgraded
	variants stamp their OWN attribute, so a raw StatusBurn read misses a
	Black Flame. Each variant still counts as its own DISTINCT status for
	per-status counting (Overseer's Battleaxe, Blighted).

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
	qualifying applier row for (Overseer's Short Sword while Blighted).
	Direct weapon/arcane hits and relic procs roll appliers; DoT ticks do
	NOT. The four tree status rares roll their RelicData `arcaneChance`
	on real spell hits instead of their weapon chance.

	Mechatronic Spider: every application by its owner has the relic's
	chance to ALSO apply a different random elemental status (ApplyStatus
	wraps _applyStatusOnce for it).
]]

--[ Roblox Services ]--

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")
local ServerScriptService = game:GetService("ServerScriptService")

--[ Exports & Types & Defaults ]--

local DataService = require(ServerScriptService.Submodules.Core.Source.Services.DataService)
local DamageService = require(ServerScriptService.Services.DamageService)
local DamageIndicatorService = require(ServerScriptService.Services.DamageIndicatorService)
local TextIndicatorService = require(ServerScriptService.Submodules.Core.Source.Services.TextIndicatorService)
local RelicService = require(ServerScriptService.Services.RelicService)
local RelicNetwork = require(ServerScriptService.Submodules.Core.Source.Network.Relic)
local StatusConditions = require(ReplicatedStorage.Submodules.Core.Shared.Enums.StatusConditions)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local AuraNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.AuraNames)
local RelicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicData)
local EnchantmentData = require(ReplicatedStorage.Submodules.Core.Shared.Data.EnchantmentData)
local StatusConditionData = require(ReplicatedStorage.Submodules.Core.Shared.Data.StatusConditionData)
local getRelicLevel = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Player.getRelicLevel)
local computePower = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Player.computePower)
local PlayerStatsService = require(ServerScriptService.Submodules.Core.Source.Services.PlayerStatsService)
local WeaponLoadoutService = require(ServerScriptService.Submodules.Core.Source.Services.WeaponLoadoutService)
local getGunProcCoefficient = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Combat.getGunProcCoefficient)
local Blitz = require(ReplicatedStorage.Submodules.Core.Shared.Blitz)

-- One relic's tweak to a status application (StatusConditionData
-- `relicModifiers` rows and GLOBAL_RELIC_MODIFIERS).
type RelicModifier = {
	requiresAura: string?,
	durationMultiplier: number?,
	bonusDuration: number?,
	dotMultiplier: number?,
	bonusSlowFraction: number?,
	bonusWeaken: number?,
}

-- A StatusConditionData row, as this service reads it.
type StatusConfig = {
	auraName: string,
	displayName: string?,
	soundName: string?,
	hitVFXName: string?,
	applyVFXName: string?,
	duration: number,
	tickInterval: number?,
	stackLimit: number?,
	dotPowerFractionPerSecond: number?,
	slowFraction: number?,
	outgoingDamageMultiplier: number?,
	incomingDamageMultiplier: number?,
	relicModifiers: { [string]: RelicModifier }?,
	color: Color3,
}

-- One refcounted status rig on a mob (see _visuals).
type VisualSlot = { count: number, emitters: { ParticleEmitter } }

-- One live status instance (see _active). The first block is the
-- gameplay record; the second is what the sweep needs to find the record
-- again and to run its DoT without a thread of its own.
type StatusRecord = {
	expiresAt: number,
	sourcePlayer: Player,
	dotMultiplier: number,
	slowFraction: number,
	weakenFraction: number,
	visualKey: string,
	model: Model,
	humanoid: Humanoid,
	status: string,
	userId: number?,
	config: StatusConfig,
	-- DoT records only.
	-- The fraction of the applier's Power one tick deals (DoT records).
	powerPerTick: number?,
	tickInterval: number?,
	nextTickAt: number?,
}

local StatusConditionService = {
	Name = "StatusConditionService",
	Dependencies = { DataService, DamageIndicatorService, TextIndicatorService } :: { any },
}

--[ Constants ]--

-- Melted and Petrified (the duo statuses, 2026-10-30) are hard to read
-- on a mob under everything else, so their APPLIER sees a floating label
-- over the mob the moment they land (TextIndicatorService; refreshes are
-- silent).
local MELTED_TEXT = "Melted!"
local MELTED_TEXT_COLOR = Color3.fromRGB(120, 255, 90)
local PETRIFIED_TEXT = "Petrified!"
local PETRIFIED_TEXT_COLOR = Color3.fromRGB(190, 180, 160)

local function showStatusText(player: Player, model: Model, text: string, color: Color3)
	local anchor = model:FindFirstChild("Head") or model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
	if anchor and anchor:IsA("BasePart") then
		TextIndicatorService:ShowIndicator(player, anchor, text, color)
	end
end

local STATUS_ATTRIBUTE_PREFIX = "Status"
local SLOW_ATTRIBUTE = "StatusSlowMultiplier"
local VFX_FADE_SECONDS = 1.5
-- Cadence of the ONE sweep that expires instances and lands DoT ticks
-- (_sweepActiveRecords). Expiry and tick timing resolve to this.
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

-- Upgrade redirects: applying `from` while the OWNER owns `relicName`
-- (and, if the row carries one, has `aura` up) lands `to` instead. Checked
-- at the top of ApplyStatus.
--
-- No aura gates today: Poison / Shock dropped theirs in the 2026-08 pass
-- and Burn's Enflamed clause went in the 2026-09 legendary un-gating pass.
-- Owning the relic is the whole condition, so each upgrade is available
-- from the moment the relic is picked up. The `aura` seam is kept.
local STATUS_REDIRECTS: { [string]: { to: string, relicName: string, aura: string? } } = {
	[StatusConditions.Burn] = {
		to = StatusConditions.BlackFlame,
		relicName = RelicNames["Flame Ronin Katana"],
	},
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
local ICE_BREAKER_DAMAGE_PER_LEVEL = 45

-- (Staff of Azure Ever Ice's Shatter AoE half was cut in the 2026-09
-- un-gating pass; its Chill chance lives in _sumApplierChances below and
-- its Magic Damage rider in DamageService/AuraDamage.)

-- Mechatronic Spider's pool: the four tree statuses (their upgrades come
-- from the redirects), and which base each status belongs to so the extra
-- one is never the status just applied.
local SPIDER_STATUSES = {
	StatusConditions.Burn,
	StatusConditions.Chill,
	StatusConditions.Poison,
	StatusConditions.Shock,
}
local SPIDER_BASE_STATUS: { [string]: string } = {
	[StatusConditions.BlackFlame] = StatusConditions.Burn,
	[StatusConditions.NoxiousVenom] = StatusConditions.Poison,
	[StatusConditions.CoilShocked] = StatusConditions.Shock,
}

-- Minimum gap between two plays of the SAME status sound, globally across
-- every mob — an AoE fresh-applying one status to eight mobs in a frame
-- would phase-stack eight identical stings without it.
local SOUND_DEBOUNCE_SECONDS = 0.1

--[ Properties ]--

-- Active statuses per mob: [model] = { [status] = value } where value is
--   * shared statuses (Chill/Shock/CoilShocked/Paint): the live record
--   * stackable statuses: { [userId] = { record, ... } } — an ARRAY per
--     player, length capped by StatusConditionData.stackLimit (default 1).
-- A record is a StatusRecord (see the type above).
StatusConditionService._active = {}

-- The sweep thread runs only while _active has something in it: it exits
-- when the books empty and ApplyStatus starts it again on the next
-- application. `_sweepBuffer` is the scratch array one sweep collects its
-- records into (reused, never reallocated).
StatusConditionService._sweepRunning = false
StatusConditionService._sweepBuffer = {} :: { StatusRecord }

-- Refcounted visuals per mob: [model] = { [visualKey] = { count, emitters } }.
-- visualKey is the GameAssets.Auras folder name ("Burn", "BlackFlame",
-- "Poison", "NoxiousPoison", ...). Four burn stacks = one rig at count 4.
StatusConditionService._visuals = {} :: { [Model]: { [string]: VisualSlot } }

-- [userId] = true while Mechatronic Spider's extra status is being
-- applied, so that application can never roll another.
StatusConditionService._spiderResolving = {} :: { [number]: boolean }

--[ Private Functions ]--

-- The applier's Power (PlayerStatsService stamps it); the starter's when
-- the stamp has not landed yet. Every DoT tick is a fraction of it.
local function powerOf(player: Player?): number
	local power = player and player:GetAttribute(Attributes.Power)
	return if typeof(power) == "number" and power > 0 then power else computePower.REFERENCE_POWER
end

-- One DoT tick's damage: the record's share of its applier's Power, the
-- relic multiplier on top, never under 1.
-- Corrosion (2026-11-01): the applier's summed Status Damage enchantment
-- stat multiplies every tick (PlayerStatsService, both weapons adding).
local function statusDamageMultiplier(player: Player?): number
	if not player then
		return 1
	end
	return 1 + PlayerStatsService:GetEnchantmentStat(player, "StatusDamage")
end

local function tickDamageOf(record: StatusRecord): number
	return math.max(
		1,
		math.floor(
			powerOf(record.sourcePlayer)
				* (record.powerPerTick or 0)
				* record.dotMultiplier
				* statusDamageMultiplier(record.sourcePlayer)
		)
	)
end

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
local GLOBAL_RELIC_MODIFIERS: { [string]: RelicModifier } = {}

-- Resolves the effective duration / magnitudes for THIS application from
-- the base config plus the applier's owned-relic modifiers. Mods with
-- `requiresAura` only count while the APPLIER has that aura up (Foul
-- Poison Fowl's Blighted gate).
function StatusConditionService:_resolveApplication(sourcePlayer: Player, config: StatusConfig)
	local duration: number = config.duration
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
	-- Aura clause only when the redirect HAS one (none do today; the seam
	-- stays). Unconditional redirects carry aura = nil, and
	-- ownerHasAura(nil) is false — the old bare check silently disabled
	-- them.
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
	local slot: VisualSlot? = visuals and visuals[visualKey]
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

	burst.Parent = workspace.IgnoreInstances.ArcaneSpells

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

	local existing = hrp:FindFirstChild(soundName) :: Sound?
	local sound: Sound
	if existing then
		sound = existing
	else
		local soundsFolder = ReplicatedStorage.GameAssets:FindFirstChild("Sounds")
		local template = soundsFolder and soundsFolder:FindFirstChild(soundName)
		if not template then
			warn("[StatusConditionService] Missing ReplicatedStorage.GameAssets.Sounds." .. soundName)
			return
		end
		sound = template:Clone() :: Sound
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
		if BURN_FAMILY[status] or POISON_FAMILY[status] then
			self:_refreshMelted(model)
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

-- Flame Ronin Katana's DETONATE (2026-10-30): consumes every Black Flame
-- stack `sourcePlayer` has on `model` and deals what they had left to
-- tick, at once (each stack's per-tick damage x its remaining ticks, the
-- tick cap applied per tick as it would have been). A black-fire burst
-- plays on every client. Returns the damage dealt (0 = nothing to burn).
function StatusConditionService:DetonateBlackFlame(sourcePlayer: Player, model: Model): number
	local entry = self._active[model]
	local value = entry and entry[StatusConditions.BlackFlame]
	local stack = value and value[sourcePlayer.UserId]
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not stack or #stack == 0 or not humanoid or humanoid.Health <= 0 then
		return 0
	end
	local now = os.clock()
	local total = 0
	local color: Color3? = nil
	for _, record: StatusRecord in table.clone(stack) :: { StatusRecord } do
		local tickInterval = record.tickInterval or 1
		local ticksLeft = math.max(1, math.ceil((record.expiresAt - now) / tickInterval))
		local perTick = tickDamageOf(record)
		total += perTick * ticksLeft
		color = record.config.color
		self:_expireInstance(model, StatusConditions.BlackFlame, sourcePlayer.UserId, record)
	end
	if total <= 0 then
		return 0
	end
	-- The DoT path (isStatusConditionDamage), as a tick lands: the number
	-- is already the burn's, not a hit to amplify again.
	DamageService:TakeDamage(sourcePlayer, humanoid, total, false, true, nil, nil, nil, color)
	local hrp = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	if hrp then
		RelicNetwork.GimmickEffect.FireAll({
			Kind = "BlackBurst",
			Caster = sourcePlayer,
			From = hrp.Position,
			To = hrp.Position,
			Radius = 5,
			Duration = 0,
			StartTime = workspace:GetServerTimeNow(),
		})
	end
	return total
end

-- Linked Sword (2026-10-30): pushes back the expiry of every Burn-family
-- stack `sourcePlayer` has on `model` by `seconds`, never past
-- `maxLeft` seconds remaining.
function StatusConditionService:ExtendBurn(sourcePlayer: Player, model: Model, seconds: number, maxLeft: number)
	local entry = self._active[model]
	if not entry then
		return
	end
	local now = os.clock()
	for status in BURN_FAMILY do
		local value = entry[status]
		local stack = value and value[sourcePlayer.UserId]
		if stack then
			for _, record: StatusRecord in stack :: { StatusRecord } do
				record.expiresAt = math.min(record.expiresAt + seconds, now + maxLeft)
			end
		end
	end
end

-- Fire Breathing Friend (2026-10-30): a mob is Melted while it is Burning AND
-- Poisoned, once a Fire Breathing Friend owner has applied either to it. The
-- one writer of Attributes.Melted: ApplyStatus passes the applier,
-- removals pass nil (they can only end it).
function StatusConditionService:_refreshMelted(model: Model, sourcePlayer: Player?)
	if not model.Parent then
		return
	end
	if not (self:IsBurning(model) and self:IsPoisoned(model)) then
		if model:GetAttribute(Attributes.Melted) ~= nil then
			model:SetAttribute(Attributes.Melted, nil)
		end
		return
	end
	if
		sourcePlayer
		and RelicService
		and (RelicService:GetSpecificRelicRegistry(sourcePlayer, RelicNames["Fire Breathing Friend"]) or 0) > 0
		and model:GetAttribute(Attributes.Melted) ~= true
	then
		model:SetAttribute(Attributes.Melted, true)
		showStatusText(sourcePlayer, model, MELTED_TEXT, MELTED_TEXT_COLOR)
	end
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
--   meleeOnly               : Skeletal Scythe Poisons on melee weapon hits
--   weaponOnly / rangedOnly : Magenta Paintball Gun paints on ranged
--                             weapon hits only.
--   auraGate                : row counts only while the OWNER has that
--                             aura up (the "While <aura>..." relics).
--   spellOnly               : arcane hits from a real SPELL only, never a
--                             relic's arcane burst (Ice Cream).
-- CHANCE RESOLUTION: a row WITHOUT `chance` reads the relic's callback at
-- roll time (GetRelicEffect), so RelicData — the description's home — is
-- the single source of truth. `chance` remains ONLY for relics whose
-- callback means something else (Magenta Paintball Gun's is its Painted
-- damage multiplier, so its apply chance must live here).
local RELIC_HIT_STATUSES: {
	{
		relicName: string,
		status: string,
		chance: number?,
		weaponOnly: boolean?,
		rangedOnly: boolean?,
		meleeOnly: boolean?,
		auraGate: string?,
		spellOnly: boolean?,
	}
} =
	{
		-- Skeletal Scythe (2026-11-01 evening): Venom's melee opener, 30% of
		-- melee weapon hits Poison (which its own redirect turns into Death
		-- Venom). Added so the Scythe works alone (NC) and Zombie Bomb is
		-- the tree's one C relic.
		{
			relicName = RelicNames["Skeletal Scythe"],
			status = StatusConditions.Poison,
			chance = 0.30,
			weaponOnly = true,
			meleeOnly = true,
		},
		-- The four tree openers left on 2026-11-01: statuses open from the
		-- weapon ENCHANTMENTS (EnchantmentData openerStatus / openerChance,
		-- read in ApplyWeaponOnHitStatuses) and from each tree's own relics
		-- (a wave, an arrow, a cloud, a strike, a shard).
		-- Magenta Paintball Gun: 15% of ranged weapon hits Paint (the
		-- callback is its damage multiplier, so the chance lives here).
		{
			relicName = RelicNames["Magenta Paintball Gun"],
			status = StatusConditions.Paint,
			chance = 0.15,
			weaponOnly = true,
			rangedOnly = true,
		},
	}

-- Status Chance: percentage points added to EVERY status the player
-- already has at least one qualifying applier row for. Owning no appliers
-- means it grants nothing — it boosts, it never enables.
-- Blighted itself no longer grants status CHANCE — the 2026-08 pass made
-- the aura a damage bonus instead, because a chance multiplier granted
-- literally nothing to a player owning no status appliers. Overseer's
-- Short Sword inherited the role, where it can be gated properly.
--
-- (Mechatronic Spider used to add here too; it rolls an extra status in
-- ApplyStatus now.)
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
	-- Overseer's Short Sword while Blighted: a fraction on every elemental
	-- status the player can already apply. (The Status Chance gear line
	-- that used to add here was removed 2026-11-01.)
	local bonus = 0
	if not RelicService or not ownerHasAura(sourcePlayer, AuraNames.Blighted) then
		return bonus
	end
	if (RelicService:GetSpecificRelicRegistry(sourcePlayer, RelicNames["Overseer's Short Sword"]) or 0) <= 0 then
		return bonus
	end
	return bonus + (RelicService:GetRelicEffect(sourcePlayer, RelicNames["Overseer's Short Sword"]) or 0)
end

-- Sums the qualifying rows for one hit into { [status] = chance }.
-- `procCoefficient` (a bullet's, getGunProcCoefficient; 1 otherwise)
-- scales every chance below 1. A row authored at 1 or more is a
-- guarantee (Magenta Paintball's Painted) and stays one.
function StatusConditionService:_sumApplierChances(
	sourcePlayer: Player,
	isWeaponHit: boolean,
	isRanged: boolean?,
	procCoefficient: number?,
	isSpell: boolean?
): { [string]: number }
	local coefficient = procCoefficient or 1
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
		if row.meleeOnly and (isRanged or not isWeaponHit) then
			continue
		end
		if row.spellOnly and not isSpell then
			continue
		end
		if row.auraGate and (not hrp or hrp:FindFirstChild(row.auraGate) == nil) then
			continue
		end
		if RelicService:GetSpecificRelicRegistry(sourcePlayer, row.relicName) > 0 then
			-- A real spell hit rolls the relic's `arcaneChance` when it has
			-- one (the four tree status rares); everything else the callback.
			local relicRow = RelicData[row.relicName]
			local arcaneChance = isSpell and relicRow and relicRow.data and relicRow.data.arcaneChance
			local chance = row.chance
				or (if type(arcaneChance) == "number" then arcaneChance else nil)
				or RelicService:GetRelicEffect(sourcePlayer, row.relicName)
				or 0
			-- The gun coefficient tempers status chances written for melee /
			-- spell cadence; a row authored FOR guns (rangedOnly: the
			-- Hyperlasers, Paintball) already is, so it is not scaled twice
			-- (audit 2026-10-30: "+25% chance to Burn" was landing at 12.5%).
			if chance < 1 and not row.rangedOnly then
				chance *= coefficient
			end
			chanceByStatus[row.status] = (chanceByStatus[row.status] or 0) + chance
		end
	end

	-- Status Chance bonus: +pp on every status that already has a chance —
	-- applied AFTER the sum so it can never conjure a status from nothing.
	local statusChanceBonus = self:_getStatusChanceBonus(sourcePlayer)
	if statusChanceBonus > 0 then
		for status, chance in chanceByStatus do
			if ELEMENTAL_STATUSES[status] then
				chanceByStatus[status] = chance + statusChanceBonus * coefficient
			end
		end
	end

	return chanceByStatus
end

-- Weapon-hit status entry point — the ONE call both weapon damage paths
-- make after landing a hit on a mob.
function StatusConditionService:ApplyWeaponOnHitStatuses(
	sourcePlayer: Player,
	weaponModel: Instance?,
	targetModel: Model,
	isRanged: boolean?
)
	if not RelicService then
		return
	end

	-- A bullet rolls every chance at its gun's proc coefficient.
	local procCoefficient = if isRanged
		then getGunProcCoefficient(sourcePlayer, weaponModel and weaponModel.Name)
		else 1

	local chanceByStatus = self:_sumApplierChances(sourcePlayer, true, isRanged, procCoefficient)

	-- The hitting weapon's enchantment opener (2026-11-01): its row's
	-- chance per hit, the gun's proc coefficient and the relic's status
	-- chance bonus on top, like a relic applier. Only the weapon that
	-- lands the hit.
	local enchantment = WeaponLoadoutService:GetEnchantmentForHit(sourcePlayer, not isRanged)
	local row = if enchantment then EnchantmentData[enchantment] else nil
	if row then
		local chance = (row.openerChance + self:_getStatusChanceBonus(sourcePlayer)) * procCoefficient
		chanceByStatus[row.openerStatus] = (chanceByStatus[row.openerStatus] or 0) + chance
	end

	for status, chance in chanceByStatus do
		if math.random() <= chance then
			self:ApplyStatus(sourcePlayer, targetModel, status, true)
		end
	end
end

-- Arcane-hit status entry point — called by onHitboxDamage after a spell's
-- damage lands on a mob (covers regular spells and relic-cast arcane).
-- `isSpell`: a real spell cast, not a relic's arcane burst (spellOnly rows).
function StatusConditionService:ApplyArcaneOnHitStatuses(sourcePlayer: Player, targetModel: Model, isSpell: boolean?)
	if not RelicService then
		return
	end

	local chanceByStatus = self:_sumApplierChances(sourcePlayer, false, false, 1, isSpell)
	for status, chance in chanceByStatus do
		if math.random() <= chance then
			self:ApplyStatus(sourcePlayer, targetModel, status, false)
		end
	end
end

-- True while the record still sits in its slot — a superseded or already
-- expired instance fails this and the sweep leaves it alone.
function StatusConditionService:_isRecordLive(record: StatusRecord): boolean
	local entry = self._active[record.model]
	local value = entry and entry[record.status]
	if not value then
		return false
	end
	if STACKABLE[record.status] then
		local stack = record.userId and value[record.userId]
		return stack ~= nil and table.find(stack, record) ~= nil
	end
	return (value :: any) == record
end

-- One DoT tick: a fraction of the APPLIER's Power (2026-10-31; a share of
-- the target's max health, capped, before). Each STACK ticks on its own
-- applier's magnitudes. DoT ticks sit OUTSIDE the damage amplifier chain
-- and can never crit or roll appliers.
function StatusConditionService:_dotTick(record: StatusRecord)
	local config = record.config
	local humanoid = record.humanoid
	local damage = tickDamageOf(record)
	-- Tick number renders in THIS status's colour — the same
	-- StatusConditionData tint the proc burst uses.
	DamageService:TakeDamage(record.sourcePlayer, humanoid, damage, false, true, nil, nil, nil, config.color)

	-- The tick gimmicks (Foul Poison Fowl's Toxic Spit).
	local gimmicks = Blitz.OptionalService("RelicGimmickService")
	if gimmicks then
		gimmicks:OnStatusTick(record.sourcePlayer, record.model, record.status)
	end

	-- A status with its own authored hit VFX (Black Flame) bursts per
	-- tick, not just on landing.
	if config.hitVFXName and DamageIndicatorService then
		DamageIndicatorService:ShowStatusVFX(record.model, config.color, config.hitVFXName)
	end
end

-- Hands a FRESH record to the sweep. A DoT record ticks once right here —
-- the per-instance loop this replaced dealt its first tick synchronously
-- on application — and schedules the next; then the sweep is started if
-- it isn't already running.
function StatusConditionService:_armRecord(record: StatusRecord)
	local config = record.config
	if config.dotPowerFractionPerSecond then
		local tickInterval = config.tickInterval or 1
		record.powerPerTick = config.dotPowerFractionPerSecond * tickInterval
		record.tickInterval = tickInterval
		self:_dotTick(record)
		record.nextTickAt = os.clock() + tickInterval
	end
	self:_ensureSweepRunning()
end

-- One record's share of a sweep: expire on model loss or timeout, release
-- (aura kept on the corpse) on death, otherwise land a DoT tick when one
-- is due. Refreshes extend the SAME record, because the sweep reads
-- `expiresAt` live rather than arming a task.delay.
function StatusConditionService:_sweepRecord(record: StatusRecord, now: number)
	-- Superseded, or removed earlier in this same sweep.
	if not self:_isRecordLive(record) then
		return
	end

	local model = record.model
	local humanoid = record.humanoid

	if not model.Parent then
		self:_expireInstance(model, record.status, record.userId, record)
		return
	end
	-- Death: the aura STAYS on the corpse (no fade) — MobBase's despawn
	-- sweep owns the fade. Release just the bookkeeping.
	if humanoid.Health <= 0 then
		self:_releaseInstanceKeepEmitters(model, record.status, record.userId, record)
		return
	end
	if now >= record.expiresAt then
		self:_expireInstance(model, record.status, record.userId, record)
		return
	end

	local nextTickAt = record.nextTickAt
	if nextTickAt and now >= nextTickAt then
		self:_dotTick(record)
		record.nextTickAt = now + (record.tickInterval or 1)
	end
end

-- ONE pass over every live record. Records are collected first and then
-- processed: expiring one rewrites _active, and a DoT tick can kill a mob
-- whose death hooks apply statuses elsewhere — a table must not gain keys
-- while it is being traversed.
function StatusConditionService:_sweepActiveRecords()
	local due = self._sweepBuffer
	table.clear(due)
	for _, entry in self._active do
		for status, value in entry do
			if STACKABLE[status] then
				for _, stack in value do
					for _, record in stack do
						table.insert(due, record)
					end
				end
			else
				table.insert(due, value)
			end
		end
	end

	local now = os.clock()
	for _, record in due do
		self:_sweepRecord(record, now)
	end
	table.clear(due)
end

-- The single 10 Hz sweep that replaced the two threads every instance
-- used to spawn (a DoT loop and an expiry poller, per mob x status x
-- player x stack). Runs only while something is active.
function StatusConditionService:_ensureSweepRunning()
	if self._sweepRunning then
		return
	end
	self._sweepRunning = true
	task.spawn(function()
		while next(self._active) ~= nil do
			task.wait(EXPIRY_POLL_SECONDS)
			self:_sweepActiveRecords()
		end
		self._sweepRunning = false
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
--
-- Mechatronic Spider: when anything was applied, its owner rolls the
-- relic's chance to also apply a random DIFFERENT elemental status. The
-- extra application runs latched, so it can never roll a third.
function StatusConditionService:ApplyStatus(
	sourcePlayer: Player,
	targetModel: Model,
	status: string?,
	isWeaponHit: boolean?
)
	local applied = self:_applyStatusOnce(sourcePlayer, targetModel, status, isWeaponHit)
	if applied ~= nil and status then
		self:_trySpiderExtraStatus(sourcePlayer, targetModel, status)
		self:_refreshMelted(targetModel, sourcePlayer)
		-- Medusa Head (duo, 2026-10-30): its owner's Poison, applied while
		-- Stonebound, also Petrifies (and refreshes a Petrified already up).
		if
			POISON_FAMILY[status]
			and RelicService
			and (RelicService:GetSpecificRelicRegistry(sourcePlayer, RelicNames["Medusa Head"]) or 0) > 0
			and ownerHasAura(sourcePlayer, AuraNames.Stonebound)
		then
			-- true = a FRESH Petrify (false is a refresh, nil blocked).
			if self:_applyStatusOnce(sourcePlayer, targetModel, StatusConditions.Petrified) == true then
				showStatusText(sourcePlayer, targetModel, PETRIFIED_TEXT, PETRIFIED_TEXT_COLOR)
			end
		end
	end
	return applied
end

-- The distinct statuses live on `model` right now (an upgraded variant
-- counts as its own: Burn + Black Flame is two).
function StatusConditionService:GetLiveStatuses(model: Model): { string }
	local live: { string } = {}
	for _, status: string in StatusConditions :: any do
		if status ~= StatusConditions.None and model:GetAttribute(STATUS_ATTRIBUTE_PREFIX .. status) == true then
			table.insert(live, status)
		end
	end
	return live
end

function StatusConditionService:_trySpiderExtraStatus(sourcePlayer: Player, targetModel: Model, status: string)
	if not sourcePlayer or not RelicService or self._spiderResolving[sourcePlayer.UserId] then
		return
	end
	if (RelicService:GetSpecificRelicRegistry(sourcePlayer, RelicNames["Mechatronic Spider"]) or 0) <= 0 then
		return
	end
	local chance = RelicService:GetRelicEffect(sourcePlayer, RelicNames["Mechatronic Spider"]) or 0
	if math.random() > chance then
		return
	end
	local base = SPIDER_BASE_STATUS[status] or status
	local choices = {}
	for _, candidate in SPIDER_STATUSES do
		if candidate ~= base then
			table.insert(choices, candidate)
		end
	end
	local extra = choices[math.random(#choices)]
	self._spiderResolving[sourcePlayer.UserId] = true
	self:_applyStatusOnce(sourcePlayer, targetModel, extra)
	self._spiderResolving[sourcePlayer.UserId] = nil
end

-- One application, without Mechatronic Spider's roll (see ApplyStatus).
function StatusConditionService:_applyStatusOnce(
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

	-- Upgrade redirects (Burn -> Black Flame, Poison -> Death Venom,
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
	local hrp = targetModel:FindFirstChild("HumanoidRootPart") :: BasePart?
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

	self:_applyPicnicPoison(sourcePlayer :: Player, targetModel, status)

	local duration, dotMultiplier, slowFraction, weakenFraction = self:_resolveApplication(sourcePlayer, config)
	local isStackable = STACKABLE[status] == true
	-- `sourcePlayer` is a plain Player; the Abyss guard's `sourcePlayer and`
	-- above leaves the checker thinking it may be nil.
	local userId = (sourcePlayer :: Player).UserId
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
		record.weakenFraction = weakenFraction
		if slowFraction > 0 then
			record.slowFraction = slowFraction
			targetModel:SetAttribute(SLOW_ATTRIBUTE, 1 - slowFraction)
		end
	end

	-- Proc feedback: the status sting + the coloured hit burst, on EVERY
	-- application — fresh, new stack, or refresh — so re-rolling Burn on
	-- a burning mob still reads as a Burn proc (orange burst, Burn sting;
	-- Black Flame its own). The sound is debounced per status
	-- (SOUND_DEBOUNCE_SECONDS), which is what keeps co-op from
	-- machine-gunning it. The authored apply model (the spark burst)
	-- stays MOB-LEVEL fresh-only below.
	local function playProcFeedback()
		playStatusSound(status, config.soundName, hrp)
		if config.color and DamageIndicatorService then
			DamageIndicatorService:ShowStatusVFX(targetModel, config.color, config.hitVFXName)
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
			playProcFeedback()
			return false
		end
	else
		local existing = entry[status]
		if existing then
			refreshRecord(existing)
			playProcFeedback()
			return false
		end
	end

	-- FRESH application (a new stack for stackables below the limit).
	local visualKey = config.auraName
	local record: StatusRecord = {
		expiresAt = os.clock() + duration,
		-- `sourcePlayer` is a plain Player (see the userId note above).
		sourcePlayer = sourcePlayer :: Player,
		dotMultiplier = dotMultiplier,
		slowFraction = slowFraction,
		weakenFraction = weakenFraction,
		visualKey = visualKey,
		model = targetModel,
		humanoid = humanoid,
		status = status,
		userId = if isStackable then userId else nil,
		config = config,
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

	playProcFeedback()
	-- Spark burst: MOB-LEVEL fresh applications only (the mob had no
	-- instance of this status at all).
	if not hadAnyInstance then
		playApplyVFX(config.applyVFXName, hrp)
	end

	self:_armRecord(record)

	return true
end

-- Poison Picnic (Venom bridge Rare): while its owner is Blighted, every
-- OTHER Status they apply (fresh or refresh) also applies their Poison.
-- The Poison goes through ApplyStatus, so Skeletal Scythe's Noxious
-- Venom redirect applies, and a Poison never re-triggers the rider.
function StatusConditionService:_applyPicnicPoison(sourcePlayer: Player, targetModel: Model, status: string)
	if status == StatusConditions.Poison or status == StatusConditions.NoxiousVenom then
		return
	end
	-- Petrified is Medusa Head's side effect OF a Poison, not a status the
	-- owner applied; riding it would Poison -> Petrify -> Poison forever
	-- (audit 2026-10-30).
	if status == StatusConditions.Petrified then
		return
	end
	if (RelicService:GetSpecificRelicRegistry(sourcePlayer, RelicNames["Poison Picnic"]) or 0) <= 0 then
		return
	end
	if not ownerHasAura(sourcePlayer, AuraNames.Blighted) then
		return
	end
	self:ApplyStatus(sourcePlayer, targetModel, StatusConditions.Poison)
end

-- Ice Breaker's Shatter: consume the Chill and burst the target.
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

	local shatterDamage = math.round(ICE_BREAKER_DAMAGE_PER_LEVEL * getRelicLevel(sourcePlayer))
	if shatterDamage <= 0 then
		return false
	end

	-- CONSUME the chill — the element rework made Shatter spend its fuel.
	local entry = self._active[targetModel]
	local chillRecord = entry and entry[StatusConditions.Chill]
	if chillRecord then
		self:_expireInstance(targetModel, StatusConditions.Chill, nil, chillRecord)
	end

	local hrp = targetModel:FindFirstChild("HumanoidRootPart") :: BasePart?

	if hrp then
		RelicNetwork.ShatterEffect.FireAll({ Position = hrp.Position, Scale = 1 })
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

	return true
end

--[ Initializers ]--

return StatusConditionService
