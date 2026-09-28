--!strict
--[[
	Module: MobBase.lua
	Description: Base class for every enemy mob. Owns:
	  * 4-state machine (Roaming / Chase / Attacking / Dead)
	  * Per-attack pipeline (genericAttacks + uniqueAttacks)
	  * LOS-first pathfinding
	  * Death pipeline (knockback, ragdoll, relic side-effects, drops,
	    EXP grant, gear-drop trigger, despawn)
	  * Attribute reactions (Jailed, Slowed, etc.)

	Per-mob configuration lives in Shared/Data/ZombieData.lua. See that
	file's header for the post-refactor shape.

	==========================================================
	State machine
	==========================================================

	  Roaming  ── player enters detectionRange ──> Chase
	  Roaming  ── 2-3s elapses ──> Roaming (pick new point, indefinitely)
	  Chase    ── target enters chosenAttack.attackRange ──> Attacking
	  Chase    ── target escapes detectionRange ──> Roaming
	  Attacking ── attack timeline completes ──> Roaming (2-3s cooldown)
	  any      ── humanoid dies ──> Dead (terminal)

	==========================================================
	Attack selection
	==========================================================

	On Chase entry, the mob picks ONE attack from
	(genericAttacks ∪ uniqueAttacks) uniformly at random. The picked
	attack's `attackRange` becomes the Chase→Attacking trigger threshold.
	The mob STICKS with that pick for the whole chase — re-picks only on
	the next Chase entry (i.e., after Roaming → Chase fires again).

	==========================================================
	Pathfinding (Chase only)
	==========================================================

	  LOS clear → Humanoid:MoveTo(target.HRP.Position) directly.
	  LOS blocked → PathfindingService:CreatePath, walk waypoints,
	                recompute every ~1s.

	No jumping (SetStateEnabled(Jumping, false) in _applyHumanoidProperties).

	==========================================================
	Performance notes (deferred to a separate pass)
	==========================================================

	  * UPDATE_DELAY is 0.1s = 10Hz AI tick. With many mobs alive this
	    is the hot loop. Could lower to 0.15-0.2s with no gameplay
	    impact if perf gets tight.
	  * `cachedAlivePlayerEntries` shared across mobs amortizes player
	    eligibility filtering to O(zombies + players) instead of
	    O(zombies × players). Keep.
	  * `_ensureLOSRaycastParams` shared across all mobs avoids
	    re-allocating RaycastParams per-tick. Keep.
	  * Pathfinding recompute is throttled per-mob via _lastPathComputeAt,
	    AND gated on the target having moved PATH_RECOMPUTE_MOVE_STUDS since
	    the current path was computed (or the path being gone / stuck).
	  * Each mob's tick is phase-offset by a random fraction of UPDATE_DELAY
	    (_startAILoop) so a wave spawned in one frame doesn't tick in
	    lock-step on the same frame forever.
	  * Line of sight is raycast at most ONCE per tick (_chaseStep).
]]

--[ Roblox Services ]--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PathfindingService = game:GetService("PathfindingService")
local ServerScriptService = game:GetService("ServerScriptService")

--[ Imports ]--

local Janitor = require(ReplicatedStorage.Submodules.Core.Packages.Janitor)
local ZombieSpawnService = require(ServerScriptService.Services.ZombieSpawnService)
local ZombieService = require(ServerScriptService.Services.ZombieService)
local RagdollService = require(ServerScriptService.Services.RagdollService)
local DropService = require(ServerScriptService.Services.DropService)
local RelicService = require(ServerScriptService.Services.RelicService)
local RoundStatisticsService = require(ServerScriptService.Services.RoundStatisticsService)
local AuraService = require(ServerScriptService.Services.AuraService)
local VFXService = require(ServerScriptService.Services.VFXService)
local IgnoreListService = require(ServerScriptService.Services.IgnoreListService)
local GearDropService = require(ServerScriptService.Services.GearDropService)
local DamageService = require(ServerScriptService.Services.DamageService)
local StatusConditionService = require(ServerScriptService.Services.StatusConditionService)
local EncounterService = require(ServerScriptService.Services.EncounterService)
local EnemyScalingService = require(ServerScriptService.Services.EnemyScalingService)
local ExpRewardService = require(ServerScriptService.Services.ExpRewardService)
local DungeonService = require(ServerScriptService.Services.DungeonService)
local MagicService = require(ServerScriptService.Services.MagicService)
local RelicNetwork = require(ServerScriptService.Submodules.Core.Source.Network.Relic)
local CombatNetwork = require(ServerScriptService.Submodules.Core.Source.Network.Combat)
local ZombieData = require(ReplicatedStorage.Submodules.Core.Shared.Data.ZombieData)
local MobFadeData = require(ReplicatedStorage.Submodules.Core.Shared.Data.MobFadeData)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local ValueNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ValueNames)
local DropTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.DropTypes)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local EnemyType = require(ReplicatedStorage.Submodules.Core.Shared.Enums.EnemyTypes)
local AuraNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.AuraNames)
local MagicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.MagicNames)
local StatusConditions = require(ReplicatedStorage.Submodules.Core.Shared.Enums.StatusConditions)
local getPlayerLevel = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Player.getPlayerLevel)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local RoomTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RoomTypes)
local MagicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.MagicData)
local onHitboxDamage = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Hitbox.onHitboxDamage)
local getRoot = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Character.getRoot)
local forEachEnemyInRadius = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Combat.forEachEnemyInRadius)
local snapToGround = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Combat.snapToGround)

--[ Constants ]--

-- Midnight Sword: fraction of Maximum Mana restored per takedown (its old
-- Overcharged-at-full-mana half died with that aura).
-- Takedown -> aura grants. Chance comes from each relic's callback, so
-- RelicData stays the one source and the cards cannot drift from this.
local TAKEDOWN_AURA_RELICS = {
	{ relicName = RelicNames["Flaming Mace"], aura = AuraNames.Enflamed },
	{ relicName = RelicNames["Ice Cream"], aura = AuraNames.Frostburst },
	{ relicName = RelicNames["Poison Picnic"], aura = AuraNames.Blighted },
	{ relicName = RelicNames["Ninja Whip"], aura = AuraNames.Stormcharged },
	{ relicName = RelicNames["Space Sandwich"], aura = AuraNames.Stonebound },
}

local MIDNIGHT_SWORD_MANA_FRACTION = 0.05
-- Assist credit EXPIRES: a player counts as an assister on this mob only
-- while their last damaging hit was within this many seconds (every hit
-- refreshes the window). Applies to the WHOLE assist registry -- relic
-- takedown procs, orb rolls, kill statistics, gear drops.
local ASSIST_WINDOW_SECONDS = 5

local UPDATE_DELAY = 0.1
local DESPAWN_TIMER = 5
local BOSS_DESPAWN_TIMER = 30
local DEFAULT_KNOCKBACK = 2.5
local MODEL_LOAD_DURATION = 0.25
local START_GRACE_DELAY = 1
local MINIBOSS_ATTRIBUTE = Attributes.IsMiniBoss
local BOSS_ATTRIBUTE = Attributes.IsBoss
local DEAD_FACE_ID = "rbxassetid://11401431671"
local FACE_IDS = {
	"rbxassetid://3065188986",
	"rbxassetid://13542531090",
	"rbxassetid://15590506766",
}
-- Lobbed bombs (Trick Or Trap's pumpkins, the Fuse Bomb): the client's
-- arc flies for BOMB_FLIGHT_SECONDS; the server hitbox fires the margin
-- after that, so the blast never lands before the bomb visibly does.
local BOMB_FLIGHT_SECONDS = 0.75
local BOMB_DETONATION_MARGIN_SECONDS = 0.25
-- Each bomb lands within this many studs (per axis) of the corpse's
-- ground point.
local BOMB_SCATTER_STUDS = 5
-- Lift above the ground point so the bomb (and its hitbox) rests ON the
-- floor rather than half inside it.
local BOMB_REST_HEIGHT_STUDS = 3.25 / 2
-- CONCURRENT bomb cap, PER RELIC and SERVER-WIDE (the counter lives in
-- RelicService's limit registry, keyed by relic name and shared by every
-- player). Trick Or Trap and Fuse Bomb each get their own 15, so at most
-- 30 bombs are ever in flight at once — a frame-rate guard, not a
-- balance one. A slot is held only from the lob to the detonation
-- (BOMB_FLIGHT_SECONDS + BOMB_DETONATION_MARGIN_SECONDS), so the cap bites
-- only on a genuine pile-up.
local BOMB_LIMIT_PER_RELIC = 15

-- One lobbed-bomb relic. `_lobBombs` runs the recipe both share (ground
-- the corpse, roll the count, claim a cap slot per bomb, broadcast the
-- arc, detonate a hitbox after the fuse); these fields are everything the
-- two relics differ in.
type BombSpec = {
	relicName: string,
	magicName: string,
	-- How many bombs this takedown lobs. A closure rather than a maximum so
	-- the Fuse Bomb's fixed 1 never touches the RNG, exactly as before.
	rollBombCount: () -> number,
	-- The blast's damage lane, per struck mob.
	onHit: (killer: Player, model: Model, targetCFrame: CFrame) -> (),
}

-- Trick Or Trap: 1-3 pumpkins. ANY takedown drops them. The
-- Burning-target requirement came off in the 2026-08 pass when the relic
-- became NC: gating an opener behind a Burn the player might have no way
-- to apply made it dead on pickup. The pumpkins apply Burn themselves
-- now, so this is what STARTS the Blaze chain rather than paying it off.
local TRICK_OR_TRAP_BOMBS: BombSpec = {
	relicName = RelicNames["Trick Or Trap"],
	magicName = MagicNames["Pumpkin Explosion"],
	rollBombCount = function()
		return math.random(1, 3)
	end,
	onHit = function(killer, model, targetCFrame)
		-- isRelicSourced = true rides the UNTYPED lane now: unqualified
		-- Damage bonuses scale the blast, typed relics/crits never apply.
		-- Still rolls the WEAPON applier hub via onHitboxDamage
		-- (isMagic = false).
		onHitboxDamage(model, targetCFrame, killer, MagicData[MagicNames["Pumpkin Explosion"]], false, true)

		-- "...and burning them": the blast applies Burn outright rather
		-- than rolling for it, which is what lets Trick Or Trap open the
		-- Blaze tree on its own.
		-- The cast: StatusConditionService's own helper signatures disagree
		-- on Player vs Player?, which fails its self type on any method
		-- call from a strict file.
		if StatusConditionService then
			(StatusConditionService :: any):ApplyStatus(killer, model, StatusConditions.Burn)
		end
	end,
}

-- Fuse Bomb (Neutral Rare): the pumpkin recipe — same fuse, same cap
-- machinery (its OWN BOMB_LIMIT_PER_RELIC counter, not one shared with the
-- pumpkins), same hitbox — but ONE bomb per takedown (no 1-3 roll), the
-- Fuse Bomb model (relicName rides the client payload), and the blast is
-- PLAIN damage: neither weapon nor magic — the raw path, no amplifiers /
-- crit / appliers (Summer Fireworks' recipe). No Burn either.
local FUSE_BOMBS: BombSpec = {
	relicName = RelicNames["Fuse Bomb"],
	magicName = MagicNames["Fuse Bomb Explosion"],
	rollBombCount = function()
		return 1
	end,
	onHit = function(killer, model, _targetCFrame)
		-- UNTYPED relic lane (isRelicSourced): unqualified Damage bonuses
		-- scale the blast; Weapon/Magic-typed relics and crits never apply.
		local targetHumanoid = model:FindFirstChildOfClass("Humanoid")
		if not targetHumanoid or not DamageService then
			return
		end
		local config = MagicData[MagicNames["Fuse Bomb Explosion"]]
		local damageRoll = if config.runtimeDamageCallback then config.runtimeDamageCallback(killer) else config.damage
		DamageService:TakeDamage(killer, targetHumanoid, damageRoll, false, false, false, true, true)
	end,
}

-- Zombie Bomb (Venom Legendary): a takedown on a POISONED mob leaves a
-- Poison Cloud at the corpse (the Blighted clause was dropped in the
-- 2026-09 un-gating pass) -- (callback x level) damage per tick for the
-- duration, and each tick has
-- CLOUD_STATUS_CHANCE to Poison everything inside (the sheet's "+30%
-- Status Chance"). LIMIT bounds live clouds PER PLAYER, same shape as
-- the pumpkin cap.
local ZOMBIE_BOMB_CLOUD_DURATION = 5
local ZOMBIE_BOMB_CLOUD_TICK_SECONDS = 1
local ZOMBIE_BOMB_CLOUD_RADIUS = 7
local ZOMBIE_BOMB_CLOUD_LIMIT = 3
local ZOMBIE_BOMB_CLOUD_FADE_SECONDS = 1.5
local ROAM_DURATION_MIN = 2
local ROAM_DURATION_MAX = 4
local ROAM_RADIUS_MIN = 20
local ROAM_RADIUS_MAX = 25
local ROAM_PICK_ATTEMPTS = 5
local PATH_RECOMPUTE_INTERVAL = 1
-- A live path is only recomputed once the target has moved this far from
-- where the path was computed to; the 1 s interval above still applies.
local PATH_RECOMPUTE_MOVE_STUDS = 4
local STUCK_DETECTION_WINDOW = 1
local STUCK_MOVE_THRESHOLD = 0.5
local STATE_ROAMING = "roaming"
local STATE_CHASE = "chase"
local STATE_ATTACKING = "attacking"
local STATE_DEAD = "dead"

--[ Rig lookups ]--

-- The rig parts a mob reads by NAME. A mob asset missing one is an
-- authoring error, so these throw exactly as the dotted lookups they
-- replace did (`model.Head.Face`), only with the mob's name attached.
local function getHead(model: Model): Instance
	local head = model:FindFirstChild("Head")
	if not head then
		error("[MobBase] No Head on mob: " .. model.Name)
	end
	return head
end

local function getFaceDecal(model: Model): Decal
	local face = getHead(model):FindFirstChild("Face")
	if not face or not face:IsA("Decal") then
		error("[MobBase] No Head.Face decal on mob: " .. model.Name)
	end
	return face
end

local function getRagdollTrigger(model: Model): BoolValue
	local trigger = model:FindFirstChild(ValueNames.RagdollTrigger)
	if not trigger or not trigger:IsA("BoolValue") then
		error("[MobBase] No " .. ValueNames.RagdollTrigger .. " BoolValue on mob: " .. model.Name)
	end
	return trigger
end

--[ Shared per-tick caches ]--

-- One RaycastParams reused across all mobs for LOS checks.
local cachedLOSRaycastParams: RaycastParams? = nil

local function _ensureLOSRaycastParams(): RaycastParams
	if cachedLOSRaycastParams then
		return cachedLOSRaycastParams
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {
		workspace.IgnoreInstances.Zombies,
		workspace.IgnoreInstances.DeadZombies,
		workspace.PlayerBaseplates,
		workspace.Terrain,
		workspace.IgnoreInstances.Boundaries,
		workspace.IgnoreInstances.ActBarriers,
		workspace.IgnoreInstances.CameraPoints,
		workspace.IgnoreInstances.MagicSpells,
		workspace.IgnoreInstances.MapMarkers,
		workspace.IgnoreInstances.Regions,
		workspace.IgnoreInstances.Terrain,
	}
	cachedLOSRaycastParams = params
	return params
end

-- One alive-players cache rebuilt per tick, shared across all mobs.
local cachedAlivePlayerEntries: { { character: Model, hrp: BasePart } } = {}
local cachedAlivePlayerEntriesAt: number = -1

local function _refreshAlivePlayersCache()
	local now = tick()
	if now - cachedAlivePlayerEntriesAt < UPDATE_DELAY * 0.9 then
		return
	end
	table.clear(cachedAlivePlayerEntries)
	-- Players parked under workspace.DesyncedPlayers haven't walked through
	-- the currently-open Dungeon Gate (DungeonService gate cycle) — the
	-- wave ahead must not target them. Every mob's targeting flows through
	-- this cache, so this one filter covers melee, ranged, and boss aggro
	-- alike. Resolved once per refresh — this is the 10Hz hot loop.
	local desyncedPlayers = workspace:FindFirstChild("DesyncedPlayers")
	for _, player in Players:GetPlayers() do
		local character = player.Character
		if not character then
			continue
		end
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if not humanoid or humanoid.Health < 1 then
			continue
		end
		if character:GetAttribute(Attributes.Death) == true then
			continue
		end
		if desyncedPlayers and character:IsDescendantOf(desyncedPlayers) then
			continue
		end
		local hrp = getRoot(character)
		if not hrp then
			continue
		end
		table.insert(cachedAlivePlayerEntries, { character = character, hrp = hrp })
	end
	cachedAlivePlayerEntriesAt = now
end

--[ Class ]--

-- One entry of the unified attack pool (_buildAttackPool / _addAttacks):
-- `entry` + `genericIndex` for a generic attack, `run` for a unique one.
type AttackPoolEntry = {
	kind: string,
	attackRange: number,
	recoveryDuration: number?,
	-- The ZombieData generic attack; absent on a unique entry.
	entry: any,
	genericIndex: number?,
	-- run(mob, target) -> active duration (seconds); see _buildAttackPool.
	run: ((mob: Model, target: Model) -> number?)?,
}

-- One ZombieData entry: the table ZombieData[name] resolves to.
type ZombieEntry = typeof(ZombieData[""])

local MobBase = {}
MobBase.__index = MobBase

-- Every field a mob carries, so the checker can follow the state bag the
-- subclasses (Miniboss / Boss) extend. Optional fields are the ones that
-- are genuinely nil until a state sets them (a target, a live path, the
-- overhead bar that encounter mobs never get).
type Fields = {
	_model: Model,
	_rootPart: BasePart,
	_humanoid: Humanoid,
	_animator: Animator,
	_janitor: typeof(Janitor.new()),
	_data: ZombieEntry,

	-- Cached config (flat for speed)
	_health: number | () -> number,
	_defaultWalkSpeed: number,
	_baseWalkSpeed: number,
	_detectionRange: number,
	_hipHeight: number,
	_enemyType: string,
	_agentRadius: number?,
	_minDropRate: number,
	_maxDropRate: number,
	_minCoins: number,
	_maxCoins: number,
	_idleAnimation: Animation,
	_runAnimation: Animation,
	_damagedAnimation: Animation,
	_deathSound: Sound,

	_attackPool: { AttackPoolEntry },
	_loadedGenericAnimations: { [number]: AnimationTrack },
	_genericAttackCounter: number,
	_runTrack: AnimationTrack,
	_idleTrack: AnimationTrack,
	_damagedTrack: AnimationTrack,
	_mobHighlight: Highlight,
	_healthInterface: BillboardGui?,

	-- Runtime state
	_walking: boolean,
	_currentTarget: Model?,
	_currentTargetHRP: BasePart?,
	_playerAssistRegistry: { [string]: number },
	_lastCreditedHealth: number?,
	_state: string,
	_stateEndTime: number,
	_nextRoamPickAt: number,
	_chosenAttack: AttackPoolEntry?,
	_attackGeneration: number,

	-- Pathfinding state
	_path: Path?,
	_waypoints: { PathWaypoint }?,
	_nextWaypointIndex: number?,
	_reachedConnection: RBXScriptConnection?,
	_blockedConnection: RBXScriptConnection?,
	_lastPathComputeAt: number,
	_lastPathDestination: Vector3?,

	-- Stuck detection
	_lastStuckSamplePos: Vector3,
	_lastStuckSampleAt: number,
}

export type MobBase = typeof(setmetatable({} :: Fields, MobBase))

--[ Construction ]--

function MobBase.new(model: Model): MobBase
	local self = setmetatable({} :: Fields, MobBase)

	self._model = model
	local rootPart = getRoot(model)
	assert(rootPart, "[MobBase] No HumanoidRootPart on mob: " .. model.Name)
	self._rootPart = rootPart
	self._humanoid = model:FindFirstChildOfClass("Humanoid") :: Humanoid
	self._animator = self._humanoid:FindFirstChildOfClass("Animator") :: Animator
	self._janitor = Janitor.new()

	local data = ZombieData[model.Name]
	assert(data, "[MobBase] No data entry for mob: " .. model.Name)
	self._data = data

	-- Cached config (flat for speed)
	self._health = data.health
	self._defaultWalkSpeed = data.walkSpeed
	-- The CURRENT state's intended walk speed before status modifiers —
	-- roam sets defaultWalkSpeed/3, chase the full default, attacking 0.
	-- _resyncWalkSpeed derives the real WalkSpeed from THIS × the Chill
	-- slow, so status changes mid-state never snap the mob to the wrong
	-- state's speed.
	self._baseWalkSpeed = data.walkSpeed
	self._detectionRange = data.detectionRange or 60
	self._hipHeight = data.hipHeight
	self._enemyType = data.enemyType
	self._agentRadius = data.agentRadius
	-- Coin scatter, ChestCoinData's vocabulary: DropRate = pickup count
	-- range, Coins = value-per-pickup range.
	self._minDropRate = data.minDropRate
	self._maxDropRate = data.maxDropRate
	self._minCoins = data.minCoins
	self._maxCoins = data.maxCoins
	self._idleAnimation = data.idle
	self._runAnimation = data.run
	self._damagedAnimation = data.damaged
	self._deathSound = data.deathSound

	self._attackPool = self:_buildAttackPool(data)

	self._loadedGenericAnimations = {}
	for i, attack in ipairs(data.genericAttacks or {}) do
		if attack.animation then
			self._loadedGenericAnimations[i] = self._animator:LoadAnimation(attack.animation)
		end
	end

	self._genericAttackCounter = #(data.genericAttacks or {})

	self._runTrack = self._animator:LoadAnimation(self._runAnimation)
	self._idleTrack = self._animator:LoadAnimation(self._idleAnimation)
	self._damagedTrack = self._animator:LoadAnimation(self._damagedAnimation)

	self._mobHighlight = Instance.new("Highlight")
	self._mobHighlight.Name = "MobHighlight"
	self._mobHighlight.FillColor = Color3.fromRGB(255, 255, 255)
	self._mobHighlight.FillTransparency = 1
	self._mobHighlight.OutlineTransparency = 1
	self._mobHighlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	self._mobHighlight.Parent = model
	self._janitor:Add(self._mobHighlight)

	-- Runtime state
	self._walking = true
	self._currentTarget = nil :: Model?
	self._currentTargetHRP = nil :: BasePart?
	self._playerAssistRegistry = {}

	-- State machine state
	self._state = STATE_ROAMING
	self._stateEndTime = 0 -- when current (timed) state expires
	self._nextRoamPickAt = 0 -- when Roaming should pick its next point

	self._chosenAttack = nil

	self._attackGeneration = 0

	-- Pathfinding state
	self._path = nil
	self._waypoints = nil
	self._nextWaypointIndex = nil
	self._reachedConnection = nil
	self._blockedConnection = nil
	self._lastPathComputeAt = 0
	self._lastPathDestination = nil :: Vector3?

	-- Stuck detection
	self._lastStuckSamplePos = self._rootPart and self._rootPart.Position or Vector3.zero
	self._lastStuckSampleAt = tick()

	return self
end

-- Builds the unified attack pool table. Pool entries are uniform shape
-- so attack selection + dispatch don't branch on source. See comment
-- in MobBase.new where this is called.
function MobBase._buildAttackPool(_self: MobBase, data)
	local pool: { AttackPoolEntry } = {}

	for i, attack in ipairs(data.genericAttacks or {}) do
		table.insert(pool, {
			kind = "generic",
			attackRange = attack.attackRange,
			-- Hoisted to the pool entry so _runAttack reads it uniformly (the raw
			-- attack lives under `entry`). Without this hoist the recovery wait
			-- saw nil and collapsed to ~1 frame regardless of the authored value.
			recoveryDuration = attack.recoveryDuration,
			entry = attack,
			genericIndex = i, -- for animation lookup
		})
	end

	for _, attack in ipairs(data.uniqueAttacks or {}) do
		-- uniqueAttacks contract: { attackRange = N, recoveryDuration = N?, run = fn }.
		-- run(zombieModel, target) returns the ACTIVE attack duration (seconds);
		-- MobBase waits that, THEN recoveryDuration, before leaving Attacking — the
		-- same two-stage clock a generic attack runs on.
		table.insert(pool, {
			kind = "unique",
			attackRange = attack.attackRange,
			recoveryDuration = attack.recoveryDuration,
			run = attack.run,
		})
	end

	if #pool == 0 then
		warn(
			("[MobBase] Mob '%s' has NO attacks (genericAttacks + uniqueAttacks both empty)"):format(
				data and "?" or "?"
			)
		)
	end

	return pool
end

-- Appends new attacks to the LIVE pool at runtime. Boss phase changes call
-- this to grow the move set (each phase introduces new generic + unique
-- attacks). Generic attacks get their animation pre-loaded + a fresh index
-- so the Attacking dispatch resolves them exactly like the originals built
-- in MobBase.new.
function MobBase._addAttacks(self: MobBase, genericAttacks: { any }?, uniqueAttacks: { any }?)
	for _, attack in ipairs(genericAttacks or {}) do
		self._genericAttackCounter += 1
		local genericIndex = self._genericAttackCounter
		if attack.animation then
			self._loadedGenericAnimations[genericIndex] = self._animator:LoadAnimation(attack.animation)
		end
		table.insert(self._attackPool, {
			kind = "generic",
			attackRange = attack.attackRange,
			recoveryDuration = attack.recoveryDuration,
			entry = attack,
			genericIndex = genericIndex,
		})
	end

	for _, attack in ipairs(uniqueAttacks or {}) do
		table.insert(self._attackPool, {
			kind = "unique",
			attackRange = attack.attackRange,
			recoveryDuration = attack.recoveryDuration,
			run = attack.run,
		})
	end
end

--[ Lifecycle ]--

function MobBase.Start(self: MobBase)
	self:_fadeInOnSpawn()

	RagdollService:Setup(self._model)

	self:_resetAttributes()
	self:_applyHumanoidProperties()
	self:_buildHealthUI()
	self:_prepareDeathSound()
	self:_setupAnimations()
	self:_setupListeners()
	self:_setNetworkOwner(nil)

	self._janitor:Add(function()
		self:_cleanupPathConnections()
	end)

	task.wait(START_GRACE_DELAY)

	if self._model:GetAttribute(MINIBOSS_ATTRIBUTE) or self._model:GetAttribute(BOSS_ATTRIBUTE) then
		print("[MobBase] Detected miniboss/boss; skipping initial AI tick until intro ends.")
		task.wait(10)
	end

	self:_startAILoop()
end

function MobBase.Stop(self: MobBase)
	self._janitor:Destroy()
end

--[ Setup helpers ]--

function MobBase._resetAttributes(self: MobBase)
	self._model:SetAttribute(Attributes.ZombieIsAttacking, false)
	self._model:SetAttribute(Attributes.SuperArmor, false)
	self._model:SetAttribute(Attributes.SlainBy, "")
	self._model:SetAttribute(Attributes.Jailed, false)
	self._model:SetAttribute(Attributes.Slowed, false)
	self._model:SetAttribute(Attributes.CCDebounce, false)
	self._model:SetAttribute(Attributes.EnemyType, self._enemyType)
end

function MobBase._applyHumanoidProperties(self: MobBase)
	-- ZombieData carries the BASE health (a function-valued entry is still
	-- honoured and resolved here). The live player multiplier, the two
	-- scaling attributes and the MaxHealth / Health write all belong to
	-- EnemyScalingService, which also rescales this mob later when the
	-- party changes shape.
	local health = self._health
	local resolvedHealth: number = if type(health) == "function" then health() else health
	self._health = resolvedHealth

	EnemyScalingService:ApplyToMob(self._model, self._humanoid, resolvedHealth)
	self:_setBaseWalkSpeed(self._defaultWalkSpeed)
	self._humanoid.HipHeight = self._hipHeight
	self._humanoid.MaxSlopeAngle = 89
	self._humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
	self._humanoid:SetStateEnabled(Enum.HumanoidStateType.Climbing, false)
	self._humanoid:SetStateEnabled(Enum.HumanoidStateType.Flying, false)

	getFaceDecal(self._model).Texture = FACE_IDS[math.random(1, #FACE_IDS)]
end

-- Overhead health bar -- REGULAR MOBS ONLY. Minibosses and bosses show their
-- health in the encounter HUD instead (EncounterService.Client.EncounterData
-- -> EncounterBarInterfaceController), so an overhead bar would be a second,
-- smaller copy of the same number. The role attributes are stamped before the
-- model is parented (ZombieSpawnService:SpawnMinibossInRoom), so they are
-- readable here at construction. _healthInterface stays nil for them; every
-- use site nil-guards.
--
-- The bar's FILL is animated by every CLIENT: ZombieController watches this
-- mob's Humanoid.HealthChanged and tweens RedBar locally. The server only
-- clones the billboard, enables it on first damage and disables it on
-- death -- one replicated write each -- instead of streaming a tweened
-- UDim2 to everyone on every hit.
function MobBase._buildHealthUI(self: MobBase)
	if
		self._model:GetAttribute(Attributes.IsBoss) == true
		or self._model:GetAttribute(Attributes.IsMiniBoss) == true
	then
		return
	end
	local healthInterface = ReplicatedStorage.GameAssets.BillboardGuis.HealthInterface:Clone() :: BillboardGui
	healthInterface.Parent = getHead(self._model)
	self._healthInterface = healthInterface
end

function MobBase._prepareDeathSound(self: MobBase)
	self._deathSound = self._deathSound:Clone()
	self._deathSound.Parent = self._rootPart
end

function MobBase._setupAnimations(self: MobBase)
	self._idleTrack:Play()
end

function MobBase._setNetworkOwner(self: MobBase, owner: Player?)
	for _, basepart in self._model:GetChildren() do
		if basepart:IsA("BasePart") or basepart:IsA("MeshPart") then
			basepart:SetNetworkOwner(owner)
		end
	end
end

-- Sets the state machine's intended base speed and re-derives the real
-- WalkSpeed through the modifier pipe. EVERY state transition must use
-- this instead of writing Humanoid.WalkSpeed raw — raw writes bypassed
-- the Chill multiplier (chilled mobs snapped back to full speed on chase
-- entry / roam ticks), and raw resyncs assumed chase speed (a chill
-- applying or expiring mid-roam launched the mob at 3× its roam speed
-- until the next roam tick).
function MobBase._setBaseWalkSpeed(self: MobBase, baseSpeed: number)
	self._baseWalkSpeed = baseSpeed
	self:_resyncWalkSpeed()
end

function MobBase._resyncWalkSpeed(self: MobBase)
	-- Chill status slow (0..1 multiplier, stamped by StatusConditionService;
	-- nil = no chill). Composes MULTIPLICATIVELY with the binary Slowed
	-- state so a chilled + slowed mob is slower than either alone. Jailed
	-- stays a hard 0. Derived from the CURRENT state's base speed, so a
	-- status flip mid-roam / mid-attack keeps that state's pace.
	local baseSpeed = self._baseWalkSpeed or self._defaultWalkSpeed
	local statusSlowAttribute = self._model:GetAttribute("StatusSlowMultiplier")
	local statusSlow: number = if type(statusSlowAttribute) == "number" then statusSlowAttribute else 1
	if self._model:GetAttribute(Attributes.Jailed) then
		self._humanoid.WalkSpeed = 0
	elseif self._model:GetAttribute(Attributes.Slowed) then
		self._humanoid.WalkSpeed = (baseSpeed / 2.5) * statusSlow
	else
		self._humanoid.WalkSpeed = baseSpeed * statusSlow
	end
end

--[ Listeners ]--

function MobBase._setupListeners(self: MobBase)
	self._janitor:Add(self._model:GetAttributeChangedSignal(Attributes.Jailed):Connect(function()
		self:_resyncWalkSpeed()
	end))

	self._janitor:Add(self._model:GetAttributeChangedSignal(Attributes.Slowed):Connect(function()
		self:_resyncWalkSpeed()
	end))

	self._janitor:Add(self._model:GetAttributeChangedSignal("StatusSlowMultiplier"):Connect(function()
		self:_resyncWalkSpeed()
	end))

	-- HealthChanged: show the bar + play the damaged anim (unless SuperArmor).
	-- The bar's fill is tweened on every client off this same signal (see
	-- _buildHealthUI); here only the Enabled flip, and only when it changes,
	-- so a mob under fire costs one replicated write for its whole life.
	--
	-- The damaged track also restarts on every status-condition tick. Telling
	-- a DoT tick from a hit needs a signal DamageService does not expose yet
	-- (its DoT path writes nothing distinguishable on the mob), so that stays.
	self._janitor:Add(self._humanoid.HealthChanged:Connect(function()
		-- nil for minibosses / bosses (see _buildHealthUI).
		if self._healthInterface and not self._healthInterface.Enabled then
			self._healthInterface.Enabled = true
		end
		if self._model:GetAttribute(Attributes.SuperArmor) then
			return
		end
		self._damagedTrack:Play()
	end))

	self._janitor:Add(self._humanoid.Running:Connect(function(speed)
		local isAttacking = self._model:GetAttribute(Attributes.ZombieIsAttacking) == true

		if isAttacking then
			return
		end

		if speed > 0 and self._walking then
			self._walking = false
			self:_stopNonAttackTracks()
			self._runTrack:Play()
		elseif speed < 1 and not self._walking then
			self._walking = true
			self:_stopNonAttackTracks()
			self._idleTrack:Play()
		end
	end))

	-- ASSIST CREDIT, refreshed on EVERY damage instance.
	--
	-- This used to hang off GetAttributeChangedSignal(SlainBy) alone, which
	-- is a trap: DamageService writes SlainBy on every hit, but the signal
	-- only fires when the value CHANGES. A solo player therefore stamped a
	-- timestamp on their FIRST hit and never again, so credit expired
	-- ASSIST_WINDOW_SECONDS later -- mid-fight. Every miniboss and boss
	-- outlives that window, which silently killed their gear drops, their
	-- kill/assist stats, and every takedown proc that gates on
	-- _assistedRecently.
	--
	-- HealthChanged fires per damage instance regardless of who dealt it,
	-- so pairing it with the attribute read keeps the window live for as
	-- long as a player is actually fighting.
	local function creditCurrentAttacker()
		local slainBy = self._model:GetAttribute(Attributes.SlainBy)
		if type(slainBy) == "string" and slainBy ~= "" then
			self._playerAssistRegistry[slainBy] = os.clock()
		end
	end

	self._janitor:Add(self._model:GetAttributeChangedSignal(Attributes.SlainBy):Connect(creditCurrentAttacker))

	self._janitor:Add(self._humanoid.HealthChanged:Connect(function(newHealth: number)
		-- Damage only; a heal must not extend an attacker's credit.
		if newHealth < (self._lastCreditedHealth or self._humanoid.MaxHealth) then
			creditCurrentAttacker()
		end
		self._lastCreditedHealth = newHealth
	end))

	self._janitor:Add(self._humanoid.Died:Connect(function()
		self:OnDeath()
	end))
end

function MobBase._stopNonAttackTracks(self: MobBase)
	for _, track in self._animator:GetPlayingAnimationTracks() do
		if not track.Name:match("Attack") then
			track:Stop()
		end
	end
end

--[ Fade-in on spawn ]--

-- The parts the spawn fade covers: every BasePart except the ones
-- MobFadeData excludes (authored invisible, or an emitter carrier).
local function forEachSpawnFadePart(model: Model, callback: (BasePart) -> ())
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") and not MobFadeData.SpawnFadeExcludedParts[part.Name] then
			callback(part)
		end
	end
end

-- The body blooms in on every CLIENT (Combat.MobFade -> ZombieController).
-- The server writes each part's Transparency exactly twice: 1 here, so
-- the model never shows a frame before its hitbox and humanoid exist,
-- and 0 once the clients' fade has run, so a late joiner (or a part
-- streaming back in) sees the landed body. In between it fires ONE cue
-- instead of tweening every part itself, which streamed a property per
-- part per frame to every client.
function MobBase._fadeInOnSpawn(self: MobBase)
	forEachSpawnFadePart(self._model, function(part)
		part.Transparency = 1
	end)

	task.delay(MODEL_LOAD_DURATION, function()
		-- Bail once the mob is gone: death destroys the RaycastHitbox and
		-- despawn destroys the model, so a mob that died inside the load
		-- window could never satisfy the condition and this polled forever.
		repeat
			task.wait(MODEL_LOAD_DURATION)
		until (self._model:FindFirstChild("RaycastHitbox") and self._model:FindFirstChildOfClass("Humanoid"))
			or self._state == STATE_DEAD
			or not self._model.Parent
		if self._state == STATE_DEAD or not self._model.Parent then
			return
		end

		CombatNetwork.MobFade.FireAll({
			Mob = self._model,
			Phase = "In",
			Duration = MobFadeData.SpawnFadeSeconds,
		})

		ZombieSpawnService:IncrementZombieCount(self._model)

		-- Land the value the clients' tween ends on. A mob that died in the
		-- meantime lands too: its corpse is meant to be opaque, and the
		-- despawn dissolve (DESPAWN_TIMER later) starts from there.
		task.wait(MobFadeData.SpawnFadeSeconds + MobFadeData.SpawnLandingMarginSeconds)
		if not self._model.Parent then
			return
		end
		forEachSpawnFadePart(self._model, function(part)
			part.Transparency = 0
		end)
	end)
end

--[ Targeting ]--

function MobBase.FindTarget(self: MobBase): boolean
	self._currentTarget = nil
	self._currentTargetHRP = nil

	_refreshAlivePlayersCache()

	local nearestPlayer = nil
	local nearestPlayerHRP = nil
	local nearestPlayerDistance = self._detectionRange

	for _, entry in cachedAlivePlayerEntries do
		local distance = (entry.hrp.Position - self._rootPart.Position).Magnitude
		if distance < nearestPlayerDistance then
			nearestPlayer = entry.character
			nearestPlayerHRP = entry.hrp
			nearestPlayerDistance = distance
		end
	end

	self._currentTarget = nearestPlayer
	self._currentTargetHRP = nearestPlayerHRP
	return self._currentTarget ~= nil
end

--[ Line of sight ]--

function MobBase._hasLineOfSight(self: MobBase): boolean
	if not self._currentTargetHRP or not self._currentTargetHRP.Parent then
		return false
	end

	local rayOrigin = self._rootPart.Position - Vector3.new(0, self._rootPart.Size.Y, 0)
	local rayDirection = Vector3.new(self._currentTargetHRP.Position.X, rayOrigin.Y, self._currentTargetHRP.Position.Z)
		- rayOrigin

	-- Target essentially on top of us — LOS is trivially true.
	if rayDirection.Magnitude < 0.05 then
		return true
	end

	local hit = workspace:Raycast(rayOrigin, rayDirection, _ensureLOSRaycastParams())
	if not hit then
		-- No obstruction along the ray AT ALL. LOS clear.
		return true
	end
	-- We hit something. If it's part of the target's character, LOS clear.
	-- (the target's body parts will register as the first hit.)
	return hit.Instance:IsDescendantOf(self._currentTargetHRP.Parent)
end

--[ Pathfinding ]--

function MobBase._cleanupPathConnections(self: MobBase)
	if self._blockedConnection then
		self._blockedConnection:Disconnect()
		self._blockedConnection = nil
	end
	if self._reachedConnection then
		self._reachedConnection:Disconnect()
		self._reachedConnection = nil
	end
end

-- The mob's one Path object, created on first use and owned by the janitor.
function MobBase._ensurePath(self: MobBase): Path
	local existing = self._path
	if existing then
		return existing
	end
	local path = PathfindingService:CreatePath({
		AgentRadius = self._agentRadius or 2,
		AgentHeight = 5,
		AgentCanJump = false,
		WaypointSpacing = 1,
		Costs = {
			SmoothPlastic = 1,
			Plastic = math.huge,
		},
	})
	self._path = path
	self._janitor:Add(path)
	return path
end

function MobBase._followPath(self: MobBase, destination: Vector3)
	local now = tick()
	if now - self._lastPathComputeAt < PATH_RECOMPUTE_INTERVAL then
		return
	end

	-- Still walking a path towards (roughly) where the target still is:
	-- keep it. Only a target that moved PATH_RECOMPUTE_MOVE_STUDS, a
	-- finished / never-computed path, or a stuck or Blocked signal (both
	-- zero the throttle) pays for another ComputeAsync.
	local walkingPath = self._reachedConnection ~= nil and self._waypoints ~= nil
	if
		walkingPath
		and self._lastPathComputeAt > 0
		and self._lastPathDestination ~= nil
		and (destination - self._lastPathDestination).Magnitude <= PATH_RECOMPUTE_MOVE_STUDS
	then
		return
	end
	self._lastPathComputeAt = now

	local path = self:_ensurePath()
	local ok = pcall(path.ComputeAsync, path, self._rootPart.Position, destination)
	if not ok or path.Status ~= Enum.PathStatus.Success then
		return
	end

	local waypoints = path:GetWaypoints()
	self._waypoints = waypoints
	if #waypoints < 2 then
		return
	end
	self._lastPathDestination = destination

	self:_cleanupPathConnections()

	self._blockedConnection = path.Blocked:Connect(function(blockedWaypointIndex)
		-- `_nextWaypointIndex` is nil until the first path is walked;
		-- treat that as "nothing ahead to block".
		if blockedWaypointIndex >= (self._nextWaypointIndex or math.huge) then
			if self._blockedConnection then
				self._blockedConnection:Disconnect()
			end
			-- Force a recompute on the next tick by zeroing the throttle.
			self._lastPathComputeAt = 0
		end
	end)

	self._nextWaypointIndex = 2

	self._reachedConnection = self._humanoid.MoveToFinished:Connect(function(reached)
		local nextWaypointIndex = self._nextWaypointIndex
		if reached and nextWaypointIndex and nextWaypointIndex < #waypoints then
			nextWaypointIndex += 1
			self._nextWaypointIndex = nextWaypointIndex
			self._humanoid:MoveTo(waypoints[nextWaypointIndex].Position)
		else
			self:_cleanupPathConnections()
		end
	end)

	self._humanoid:MoveTo(waypoints[2].Position)
end

function MobBase._checkStuck(self: MobBase)
	local now = tick()
	if now - self._lastStuckSampleAt < STUCK_DETECTION_WINDOW then
		return
	end

	local pos = self._rootPart.Position
	local moved = (pos - self._lastStuckSamplePos).Magnitude

	if moved < STUCK_MOVE_THRESHOLD then
		-- Stuck. Force path recompute on the next chase tick.
		self._lastPathComputeAt = 0
	end

	self._lastStuckSamplePos = pos
	self._lastStuckSampleAt = now
end

--[ Roam point picking ]--

function MobBase._pickRoamPosition(self: MobBase): Vector3?
	if not self._rootPart then
		return nil
	end
	local angle = math.random() * math.pi * 2
	local distance = math.random(ROAM_RADIUS_MIN, ROAM_RADIUS_MAX)
	local origin = self._rootPart.Position
	return origin + Vector3.new(math.cos(angle) * distance, 0, math.sin(angle) * distance)
end

function MobBase._isPointReachable(self: MobBase, point: Vector3): boolean
	if not self._rootPart then
		return false
	end
	local origin = self._rootPart.Position
	local direction = point - origin
	if direction.Magnitude < 0.05 then
		return true
	end
	local hit = workspace:Raycast(origin, direction, _ensureLOSRaycastParams())
	return hit == nil
end

--[ State transitions ]--

function MobBase._enterRoaming(self: MobBase)
	self._state = STATE_ROAMING
	-- Roam pace = default/3, through the status pipe (Jailed→0 handled
	-- inside the resync; Chill keeps its bite while roaming).
	self:_setBaseWalkSpeed(self._defaultWalkSpeed / 2)
	self._stateEndTime = tick() + math.random(ROAM_DURATION_MIN, ROAM_DURATION_MAX)
	self._chosenAttack = nil

	local point = nil

	for _ = 1, ROAM_PICK_ATTEMPTS do
		local candidate = self:_pickRoamPosition()
		if candidate and self:_isPointReachable(candidate) then
			point = candidate
			break
		end
	end

	if point then
		self._humanoid:MoveTo(point)
	end
end

function MobBase._enterChase(self: MobBase)
	self._state = STATE_CHASE
	self._chosenAttack = self:_pickAttack()
	self._lastPathComputeAt = 0 -- allow first recompute immediately
	self:_setBaseWalkSpeed(self._defaultWalkSpeed)
end

function MobBase._pickAttack(self: MobBase)
	local pool = self._attackPool
	if #pool == 0 then
		return nil
	end
	return pool[math.random(1, #pool)]
end

--[ Chase step ]--

function MobBase._chaseStep(self: MobBase)
	if self._model:GetAttribute(Attributes.Jailed) then
		return
	end
	if not self._currentTarget or not self._currentTargetHRP or not self._currentTargetHRP.Parent then
		-- Target lost. Fall back to Roaming.
		self:_enterRoaming()
		return
	end

	-- ONE raycast per tick: the LOS-gated attack check and the chase branch
	-- below share the answer instead of each casting their own.
	local lineOfSight: boolean? = nil
	local function hasLineOfSight(): boolean
		if lineOfSight == nil then
			lineOfSight = self:_hasLineOfSight()
		end
		return lineOfSight :: boolean
	end

	if self._chosenAttack then
		local distance = (self._rootPart.Position - self._currentTargetHRP.Position).Magnitude
		if distance <= self._chosenAttack.attackRange then
			local entry = self._chosenAttack.entry
			local needsLOS = entry and entry.requiresLineOfSight
			if not needsLOS or hasLineOfSight() then
				self:_runAttack(self._chosenAttack)
				return
			end
			-- In range but the attack is LOS-gated and sight is blocked.
			-- Fall through to chase — pathfinder picks up below.
		end
	end

	if hasLineOfSight() then
		self._humanoid:MoveTo(self._currentTargetHRP.Position, self._currentTargetHRP)
	else
		self:_followPath(self._currentTargetHRP.Position)
	end

	self:_checkStuck()
end

--[ Attack pipeline ]--

function MobBase._runAttack(self: MobBase, chosenAttack: AttackPoolEntry)
	if self._state == STATE_ATTACKING then
		return -- re-entry guard
	end
	self._state = STATE_ATTACKING

	local generation = self._attackGeneration

	task.spawn(function()
		self._model:SetAttribute("AttackInterrupted", false)
		self._model:SetAttribute(Attributes.ZombieIsAttacking, true)
		self._model:SetAttribute(Attributes.SuperArmor, true)
		self._humanoid:MoveTo(self._rootPart.Position) -- cancel in-flight MoveTo
		self:_setBaseWalkSpeed(0)
		self._humanoid.AutoRotate = false

		self._model:SetAttribute("MobHighlightAttackActive", true)

		local targetHRP = self._currentTargetHRP
		if targetHRP and targetHRP.Parent then
			local root = self._rootPart
			local targetPos = targetHRP.Position
			local flatTarget = Vector3.new(targetPos.X, root.Position.Y, targetPos.Z)
			if (flatTarget - root.Position).Magnitude > 0.05 then
				root.CFrame = CFrame.lookAt(root.Position, flatTarget)
			end
		end

		-- Dispatch on attack kind. Each path handles its own timing.
		if chosenAttack.kind == "generic" then
			self:_runGenericAttack(chosenAttack)
		elseif chosenAttack.kind == "unique" then
			self:_runUniqueAttack(chosenAttack)
		end

		if self._attackGeneration ~= generation then
			return
		end

		self._model:SetAttribute("MobHighlightAttackActive", false)

		-- Post-attack recovery pause, hoisted onto the pool entry for BOTH kinds
		-- (_buildAttackPool / _addAttacks). `or 0` keeps an attack that omits it at
		-- "next frame" instead of erroring on task.wait(nil).
		task.wait(chosenAttack.recoveryDuration or 0)

		if self._attackGeneration ~= generation then
			return
		end

		self._humanoid.AutoRotate = true
		-- Restore mobility from the attack's 0 base. _afterAttack →
		-- _enterRoaming re-bases to roam pace right after; this covers the
		-- gap (and death skips _afterAttack entirely, where 0 is fine).
		self:_setBaseWalkSpeed(self._defaultWalkSpeed)
		self._model:SetAttribute(Attributes.SuperArmor, false)
		self._model:SetAttribute(Attributes.ZombieIsAttacking, false)

		if self._humanoid.Health > 0 then
			self:_afterAttack()
		end
	end)
end

function MobBase._runGenericAttack(self: MobBase, chosenAttack: AttackPoolEntry)
	local entry = chosenAttack.entry
	local genericIndex = chosenAttack.genericIndex

	local animTrack = if genericIndex then self._loadedGenericAnimations[genericIndex] else nil
	if animTrack then
		animTrack:Play()
	end

	if self._humanoid.Health <= 0 then
		return
	end

	local kind = entry.kind or "melee"
	if kind == "ranged" then
		self:_runRangedSwing(entry)
	else
		ZombieService:ExecuteMobAttack(self._model, entry)
	end
end

function MobBase._runRangedSwing(self: MobBase, entry)
	-- Aim BEFORE the attack: snap to face the current target, THEN wind
	-- up, then fire STRAIGHT AHEAD — FireMobRangedAttack derives the
	-- shot from the mob's facing at cast time, not the target's
	-- position. AutoRotate is off and walkspeed is 0 for the whole
	-- attack, so the aim is locked in here and sidestepping during the
	-- windup genuinely dodges the shot.
	if self._currentTargetHRP and self._currentTargetHRP.Parent then
		local rootPosition = self._rootPart.Position
		local targetPosition = self._currentTargetHRP.Position
		local flatTarget = Vector3.new(targetPosition.X, rootPosition.Y, targetPosition.Z)
		if (flatTarget - rootPosition).Magnitude > 0.001 then
			self._rootPart.CFrame = CFrame.lookAt(rootPosition, flatTarget)
		end
	end

	task.wait(entry.windUpDuration)

	if self._humanoid.Health <= 0 then
		return -- died during windup
	end
	if not self._currentTarget or not self._currentTargetHRP or not self._currentTargetHRP.Parent then
		return -- target lost during windup
	end

	if self._model:GetAttribute(Attributes.Jailed) then
		return
	end

	if entry.requiresLineOfSight and not self:_hasLineOfSight() then
		return
	end

	local targetPlayer = Players:GetPlayerFromCharacter(self._currentTarget)
	if not targetPlayer then
		return
	end

	ZombieService:FireMobRangedAttack(self._model, targetPlayer, entry)
end

-- Unique attack pipeline: hand off to the callback, block for the ACTIVE
-- duration it returns. The callback owns its whole active timeline (windup,
-- VFX, hit-frames — typically via ZombieService:SpawnHitbox); _runAttack then
-- applies chosenAttack.recoveryDuration after this returns.
function MobBase._runUniqueAttack(self: MobBase, chosenAttack: AttackPoolEntry)
	local target = self._currentTarget
	if not target then
		return
	end

	if self._model:GetAttribute(Attributes.Jailed) then
		return
	end
	local run = chosenAttack.run
	assert(run, "[MobBase] Unique attack without a `run` callback on mob: " .. self._model.Name)
	local duration = run(self._model, target) or 0
	task.wait(duration)
end

function MobBase._afterAttack(self: MobBase)
	self:_enterRoaming()
end

function MobBase._interruptAttack(self: MobBase)
	self._attackGeneration += 1
	self._model:SetAttribute("AttackInterrupted", true)
	self._model:SetAttribute("MobHighlightAttackActive", false)
	self._model:SetAttribute(Attributes.ZombieIsAttacking, false)
	self._model:SetAttribute(Attributes.SuperArmor, false)
	self._humanoid.AutoRotate = true
	for _, track in self._animator:GetPlayingAnimationTracks() do
		track:Stop()
	end
end

--[ Main AI loop ]--

function MobBase._startAILoop(self: MobBase)
	task.spawn(function()
		-- Phase offset: mobs spawned in the same frame would otherwise tick
		-- on the same frame forever, landing the whole wave's AI work as one
		-- spike every UPDATE_DELAY. A random fraction of the tick spreads
		-- them across frames.
		task.wait(math.random() * UPDATE_DELAY)
		while
			self._model
			and self._model:FindFirstChildOfClass("Humanoid")
			and self._humanoid.Health > 0
			and task.wait(UPDATE_DELAY)
		do
			if self._state == STATE_DEAD then
				break
			end
			if not self._model:GetAttribute(Attributes.Enabled) then
				continue
			end
			if not self._rootPart then
				continue
			end
			if getRagdollTrigger(self._model).Value then
				continue
			end

			-- Refresh target each tick.
			local hasTarget = self:FindTarget()

			-- Attacking: hands-off in main loop; the attack coroutine
			-- transitions state when done.
			if self._state == STATE_ATTACKING then
				continue
			end

			if self._state == STATE_ROAMING then
				if tick() < self._stateEndTime then
					-- Still in the cooldown window. Hold here.
					continue
				end

				if hasTarget then
					self:_enterChase()
				else
					-- No target + timer expired → pick a new roam point
					-- (this also resets _stateEndTime for the next cycle).
					self:_enterRoaming()
				end
				continue
			end

			-- Chase: pursue + maybe attack.
			if self._state == STATE_CHASE then
				local targetHRP = self._currentTargetHRP
				if not hasTarget or not targetHRP then
					self:_enterRoaming()
					continue
				end
				-- Target escaped detection? Back to Roaming.
				local distance = (self._rootPart.Position - targetHRP.Position).Magnitude
				if distance > self._detectionRange then
					self:_enterRoaming()
					continue
				end
				self:_chaseStep()
				continue
			end
		end
	end)
end

--[ Death ]--

function MobBase.OnDeath(self: MobBase)
	self._state = STATE_DEAD
	ZombieSpawnService:DecrementZombieCount(self._model)
	self._janitor:Cleanup()

	self:_interruptAttack()

	getFaceDecal(self._model).Texture = DEAD_FACE_ID

	-- A player's kill pays EXP to the whole living party (ExpRewardService),
	-- whether or not the killer is still here.
	local slainBy = self._model:GetAttribute(Attributes.SlainBy)
	if type(slainBy) == "string" and slainBy ~= "" then
		ExpRewardService:GrantKill(self._enemyType)
	end

	if self._model:GetAttribute(Attributes.SlainBy) ~= "" then
		local killer = Players:FindFirstChild(self._model:GetAttribute(Attributes.SlainBy))
		if killer and killer.Character then
			self:_applyDeathImpulse(killer)
			self:_lobBombs(killer, TRICK_OR_TRAP_BOMBS)
			self:_lobBombs(killer, FUSE_BOMBS)
			self:_runZombieBombCloud(killer)
			self:_handleAssists() -- stats + auras (immediate, regardless of mob tier)

			if self:_isEncounterMob() then
				self:_deferEncounterRewards(killer)
			else
				self:_dropGear()
				self:_dropCoins(killer)
			end
		end
	end

	self:_playDeathSound()
	self:_applyForwardKnockback()
	self:_relocateToDeadFolder()
	self:_scheduleDespawn()
end

function MobBase._applyDeathImpulse(self: MobBase, killer: Player)
	local killerRoot = getRoot.fromPlayer(killer)
	if not killerRoot then
		return
	end
	local direction = (self._rootPart.Position - killerRoot.Position).Unit
	direction = Vector3.new(direction.X, 0, direction.Z).Unit
	self._rootPart:ApplyImpulse((direction + Vector3.new(0, 1, 0)) * self._rootPart.AssemblyMass * (200 * 0.35))
end

-- The lobbed-bomb recipe both bomb relics share (TRICK_OR_TRAP_BOMBS,
-- FUSE_BOMBS). Every bomb claims a slot against its relic's global cap
-- (BOMB_LIMIT_PER_RELIC) before spawning, and simply does not spawn when
-- the cap is full. The claim is read-then-write with no yield between, so
-- the bombs of one takedown cannot over-claim each other.
function MobBase._lobBombs(self: MobBase, killer: Player, spec: BombSpec)
	local owned = RelicService:GetSpecificRelicRegistry(killer, spec.relicName)
	if not owned or owned <= 0 then
		return
	end

	local groundPosition = snapToGround(self._rootPart.Position) or self._rootPart.Position
	local cachedCFrame = CFrame.new(groundPosition) + Vector3.new(0, BOMB_REST_HEIGHT_STUDS, 0)
	local magicName = spec.magicName

	for _ = 1, spec.rollBombCount() do
		task.spawn(function()
			local currentLimit = RelicService:GetRelicLimitRegistry(spec.relicName) or 0
			if currentLimit >= BOMB_LIMIT_PER_RELIC then
				return
			end

			RelicService:SetRelicLimitRegistry(spec.relicName, currentLimit + 1)
			local targetCFrame = cachedCFrame
				+ Vector3.new(
					math.random(-BOMB_SCATTER_STUDS, BOMB_SCATTER_STUDS),
					0,
					math.random(-BOMB_SCATTER_STUDS, BOMB_SCATTER_STUDS)
				)

			RelicNetwork.ThrownRelicLaunched.FireAll({
				Position = self._rootPart.Position,
				TargetPosition = targetCFrame.Position,
				StartTime = workspace:GetServerTimeNow(),
				Duration = BOMB_FLIGHT_SECONDS,
				MagicName = magicName,
				RelicName = spec.relicName,
			})

			task.delay(BOMB_FLIGHT_SECONDS + BOMB_DETONATION_MARGIN_SECONDS, function()
				-- Slot released FIRST, before the blast: this bomb is detonating,
				-- so its slot is spent either way, and a hitbox that ERRORS must
				-- never strand it — the counter is server-wide and nothing ever
				-- resets it, so a leaked slot would starve the relic for the life
				-- of the server.
				RelicService:SetRelicLimitRegistry(
					spec.relicName,
					(RelicService:GetRelicLimitRegistry(spec.relicName) or 0) - 1
				)
				VFXService:CreateHitbox(
					magicName,
					killer,
					targetCFrame,
					TagList.Zombie,
					IgnoreListService:GetWeaponIgnoreList(),
					function(model: Model)
						spec.onHit(killer, model, targetCFrame)
					end,
					MagicData[magicName].hitboxSize.X
				)
			end)
		end)
	end
end

function MobBase._runZombieBombCloud(self: MobBase, killer: Player)
	local damagePerLevel = RelicService:GetRelicEffect(killer, RelicNames["Zombie Bomb"])
	if not damagePerLevel or RelicService:GetSpecificRelicRegistry(killer, RelicNames["Zombie Bomb"]) <= 0 then
		return
	end
	-- Gate: the mob died POISONED (family read -- Noxious Venom counts;
	-- any player's stacks, read before the stack watchers release).
	if not (StatusConditionService and StatusConditionService:IsPoisoned(self._model)) then
		return
	end

	local limitKey = RelicNames["Zombie Bomb"] .. "_" .. killer.UserId
	local liveClouds = RelicService:GetRelicLimitRegistry(limitKey) or 0
	if liveClouds >= ZOMBIE_BOMB_CLOUD_LIMIT then
		return
	end
	RelicService:SetRelicLimitRegistry(limitKey, liveClouds + 1)

	local cloudTemplate = ReplicatedStorage.GameAssets.VFX:FindFirstChild("PoisonCloud")
	local cloudPosition = self._rootPart.Position
	local cloud
	if cloudTemplate then
		cloud = cloudTemplate:Clone()
		cloud:PivotTo(CFrame.new(cloudPosition))
		for _, part in cloud:GetDescendants() do
			if part:IsA("BasePart") then
				part.Anchored = true
				part.CanCollide = false
				part.CanQuery = false
				part.CanTouch = false
			end
		end
		cloud.Parent = workspace.IgnoreInstances.MagicSpells
	else
		warn("[MobBase] Missing ReplicatedStorage.GameAssets.VFX.PoisonCloud")
	end

	local tickDamage = math.round(damagePerLevel * getPlayerLevel(killer))
	task.spawn(function()
		local elapsed = 0
		while elapsed < ZOMBIE_BOMB_CLOUD_DURATION do
			task.wait(ZOMBIE_BOMB_CLOUD_TICK_SECONDS)
			elapsed += ZOMBIE_BOMB_CLOUD_TICK_SECONDS

			forEachEnemyInRadius(cloudPosition, ZOMBIE_BOMB_CLOUD_RADIUS, function(model, targetHumanoid)
				-- Relic damage, NEUTRAL type (isMagic = false): no magic
				-- amplifiers, no magic resist, white number — the same bucket
				-- as TNT / tremor / Ghost Dragon. Full amp chain + crit roll
				-- (isRelicSourced = true).
				if DamageService and tickDamage > 0 then
					DamageService:TakeDamage(killer, targetHumanoid, tickDamage, false, false, nil, true)
				end
				-- "...and applies Poison": every tick, no roll. The card dropped
				-- its Status Chance clause in the 2026-08 pass, so the cloud is
				-- now a guaranteed Poison field rather than a chance to seed one.
				if StatusConditionService then
					-- Cast: see TRICK_OR_TRAP_BOMBS.
					(StatusConditionService :: any):ApplyStatus(killer, model, StatusConditions.Poison, false)
				end
			end)
		end

		RelicService:SetRelicLimitRegistry(limitKey, (RelicService:GetRelicLimitRegistry(limitKey) or 1) - 1)

		if cloud then
			for _, emitter in cloud:GetDescendants() do
				if emitter:IsA("ParticleEmitter") then
					emitter.Enabled = false
				end
			end
			task.delay(ZOMBIE_BOMB_CLOUD_FADE_SECONDS, function()
				cloud:Destroy()
			end)
		end
	end)
end

-- True while `name` still holds live assist credit on this mob (last hit
-- within ASSIST_WINDOW_SECONDS).
function MobBase._assistedRecently(self: MobBase, name: string): boolean
	local lastHitAt = self._playerAssistRegistry[name]
	return lastHitAt ~= nil and (os.clock() - lastHitAt) <= ASSIST_WINDOW_SECONDS
end

function MobBase._handleAssists(self: MobBase)
	for name, _ in self._playerAssistRegistry do
		if not self:_assistedRecently(name) then
			continue
		end
		local player = Players:FindFirstChild(name)
		if not player then
			continue
		end

		RoundStatisticsService.Signals.OnKillOrAssist:Fire(player, 1)

		local enemyType = self._model:GetAttribute(Attributes.EnemyType)

		if enemyType == EnemyType.Elite then
			RoundStatisticsService.Signals.OnEliteChanged:Fire(player, 1)
		elseif enemyType == EnemyType.Miniboss then
			RoundStatisticsService.Signals.OnMinibossChanged:Fire(player, 3)
		elseif enemyType == EnemyType.Boss then
			-- The count is REQUIRED (the handler adds it). Omitting it here
			-- threw on every boss kill, so the boss tally never moved.
			-- Continues the elite 1 / miniboss 3 weighting.
			RoundStatisticsService.Signals.OnBossChanged:Fire(player, 5)
		end

		-- Takedown procs roll per killer/assister — anyone in this mob's
		-- _playerAssistRegistry whose credit is still live (the 5s window),
		-- INCLUDING the player who landed the killing blow.

		-- Takedown aura grants — one relic per element tree, all rolling off
		-- the same kill. These are each tree's THIRD ungated opener, added in
		-- the 2026-08 pass so a run does not always begin with the same two
		-- status/aura enablers.
		--
		-- Rolled per killer/assister like everything else here, and routed
		-- through SetAura so the Sword of Eternal Abyss lockout, the duration
		-- bonuses and the extend-only rule all apply for free.
		if AuraService and player.Character then
			for _, row in TAKEDOWN_AURA_RELICS do
				if RelicService:GetSpecificRelicRegistry(player, row.relicName) > 0 then
					local chance = RelicService:GetRelicEffect(player, row.relicName) or 0
					if chance > 0 and math.random() <= chance then
						AuraService:SetAura(player, row.aura, player.Character)
					end
				end
			end
		end

		-- Midnight Sword: takedowns restore 5% of Maximum Mana.
		if RelicService:GetSpecificRelicRegistry(player, RelicNames["Midnight Sword"]) > 0 then
			local magicData = MagicService:GetPlayerMagicData(player)
			if magicData and magicData.maxMana and magicData.mana < magicData.maxMana then
				local refunded =
					math.min(magicData.mana + magicData.maxMana * MIDNIGHT_SWORD_MANA_FRACTION, magicData.maxMana)
				MagicService:SetPlayerMagicData(player, refunded, magicData.maxMana)
			end
		end

		-- Mana orb roll per killer/assister. Gear Recycler: +10pp drop
		-- chance (its orb-restore half lives in DropService).
		local manaDropChance = 5

		if RelicService:GetSpecificRelicRegistry(player, RelicNames["Gear Recycler"]) > 0 then
			manaDropChance += 10
		end

		if math.random() * 100 <= manaDropChance then
			DropService.OnDropRequested:Fire(self._rootPart, DropTypes.Mana, 1, 1, 1, 1, false)
		end

		-- Health orb roll per killer/assister. (Regeneration Coil's old
		-- +2.5pp here left when it became an any-source healing amp.)
		local healthDropChance = 5

		if math.random() * 100 <= healthDropChance then
			DropService.OnDropRequested:Fire(self._rootPart, DropTypes.Health, 1, 1, 1, 1, false)
		end

		-- Personal-loot gear roll lives in _dropGear now (called by OnDeath),
		-- so encounter mobs can DEFER it to after the outro cinematic while
		-- regular mobs still drop immediately. Stats + auras above stay here
		-- (they fire on death regardless).
	end
end

-- Personal-loot gear roll for every player in the assist registry. Split out
-- of _handleAssists so encounter mobs can DEFER it to after the outro
-- cinematic; regular mobs call it inline in OnDeath.
function MobBase._dropGear(self: MobBase)
	if not GearDropService then
		return
	end
	for name, _ in self._playerAssistRegistry do
		local player = Players:FindFirstChild(name)
		if player and self:_assistedRecently(name) then
			GearDropService:DropGear(player, self._rootPart.Position, self._enemyType)
		end
	end
end

-- True for minibosses + bosses (the encounter-tier mobs whose death plays an
-- outro cinematic). Their coin + gear rewards come from the reward chest
-- (see _deferEncounterRewards).
--
-- Deliberately the spawn-side IsBoss / IsMiniboss flags ZombieSpawnService
-- stamps, NOT Shared/Functions/Mob/isEncounterEnemy (the EnemyType tier
-- from ZombieData): the outro, the long despawn and the reward chest
-- belong to the ROLE this mob was spawned in, and the same model can serve
-- either role across difficulties (Components/Zombie).
function MobBase._isEncounterMob(self: MobBase): boolean
	return self._model:GetAttribute(Attributes.IsMiniBoss) == true
		or self._model:GetAttribute(Attributes.IsBoss) == true
end

-- Encounter-tier mobs (miniboss / boss) pay through the reward chest, not
-- the corpse -- see the seam note inside. Without EncounterService
-- (defensive) they drop like a regular mob.
function MobBase._deferEncounterRewards(self: MobBase, killer)
	if not EncounterService then
		-- Defensive: no EncounterService → drop immediately.
		self:_dropGear()
		self:_dropCoins(killer)
		return
	end
	-- NOTHING drops at the corpse any more. An encounter's gear and coins
	-- are the reward CHEST's contents (EncounterChestService, off the same
	-- outro beat), so dropping them here as well would pay the player
	-- twice. This is the seam where corpse-side rewards would go if any
	-- are ever added back: EncounterService.OnEncounterOutroFinished
	-- (kind, room, mob) fires once THIS mob's outro cinematic ends, and the
	-- corpse persists through it (encounter despawn timer, see
	-- _scheduleDespawn), so _rootPart would still be a valid drop origin.
end

-- GUARANTEED on every mob (design call — the old 25% roll is gone;
-- big mobs were already guaranteed). Same signal shape the treasure
-- chest uses: DropRate = pickup count, Coins = value per pickup.
-- (Pot Of Gold's +25% coins-gain is collector-side at credit time in
-- DropService; its auto-collect is the client Drop component's
-- distance bypass.)
--
-- EXCEPT in a Miniboss / Boss room: those pay in relics and gear, not
-- coins. The gate is the ROOM, not the mob, so the adds a miniboss
-- wave spawns are covered too — every mob carries the RoomId its
-- spawner stamped (ZombieSpawnService).
function MobBase._dropCoins(self: MobBase, _killer)
	local roomId = self._model:GetAttribute("RoomId")
	local dungeon = DungeonService and DungeonService:GetActiveDungeon()
	local room = if dungeon and type(roomId) == "number" then dungeon.roomsById[roomId] else nil
	if room and (room.roomType == RoomTypes.Miniboss or room.roomType == RoomTypes.Boss) then
		return
	end

	DropService.OnDropRequested:Fire(
		self._rootPart,
		DropTypes.Coins,
		self._minDropRate,
		self._maxDropRate,
		self._minCoins,
		self._maxCoins,
		false
	)
end

function MobBase._playDeathSound(self: MobBase)
	self._deathSound:Play()
end

function MobBase._applyForwardKnockback(self: MobBase)
	self._rootPart:ApplyImpulse(-self._rootPart.CFrame.LookVector * (DEFAULT_KNOCKBACK * self._rootPart.AssemblyMass))
end

-- Death-style hooks (overridable). Default mobs collapse via ragdoll
-- physics; minibosses/bosses override _ragdollOnDeath to stay upright and
-- _onDeathAnimation to play a death animation in place (placeholder print
-- until the animation asset exists).
function MobBase._ragdollOnDeath(_self: MobBase): boolean
	return true
end

function MobBase._onDeathAnimation(_self: MobBase) end

function MobBase._relocateToDeadFolder(self: MobBase)
	self._model.Parent = workspace.IgnoreInstances.DeadZombies

	local zombieHitbox = self._model:FindFirstChild("ZombieHitbox")
	if zombieHitbox then
		zombieHitbox:Destroy()
	end

	-- Destroy combat hitboxes; the dead body shouldn't deal or receive damage.
	local raycastHitbox = self._model:FindFirstChild("RaycastHitbox")
	if raycastHitbox then
		raycastHitbox:Destroy()
	end

	if self._healthInterface then
		self._healthInterface.Enabled = false
	end
	-- Base 0 through the pipe so a status expiring post-death can't
	-- resync a stale (living) base speed onto the corpse.
	self:_setBaseWalkSpeed(0)

	-- Stop locomotion tracks regardless of death style.
	for _, animation in self._animator:GetPlayingAnimationTracks() do
		animation:Stop()
	end

	if self:_ragdollOnDeath() then
		-- Trigger the ragdoll AFTER the collision group is locked in.
		getRagdollTrigger(self._model).Value = true
	else
		-- Non-ragdoll death (minibosses / bosses): stay upright in place and
		-- play a death animation instead of collapsing. The existing
		-- _scheduleDespawn fade removes the body on the spot afterwards.
		self._humanoid.AutoRotate = false
		self:_onDeathAnimation()
	end
end

function MobBase._scheduleDespawn(self: MobBase)
	-- Minibosses + bosses use the long despawn so the corpse survives its
	-- outro cinematic (the camera holds on it).
	local longDespawn = self:_isEncounterMob()
	local timer = if longDespawn then BOSS_DESPAWN_TIMER else DESPAWN_TIMER

	task.delay(timer, function()
		if not self._model or not self._model.Parent then
			return
		end

		-- Emitters stop here (one replicated bool each); the dissolve itself
		-- runs on every client off ONE cue (Combat.MobFade -> ZombieController)
		-- instead of a server tween per part. The server only waits it out.
		for _, descendant in self._model:GetDescendants() do
			if descendant:IsA("ParticleEmitter") then
				descendant.Enabled = false
			end
		end
		CombatNetwork.MobFade.FireAll({
			Mob = self._model,
			Phase = "Out",
			Duration = MobFadeData.DespawnFadeSeconds,
		})

		task.wait(MobFadeData.DespawnFadeSeconds)
		if self._model then
			self._model:Destroy()
		end
	end)
end

return MobBase
