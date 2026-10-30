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

	Per-mob configuration lives in Shared/Data/MobData.lua. See that
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
	    eligibility filtering to O(mobs + players) instead of
	    O(mobs × players). Keep.
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
local MobSpawnService = require(ServerScriptService.Services.MobSpawnService)
local MobService = require(ServerScriptService.Services.MobService)
local RagdollService = require(ServerScriptService.Services.RagdollService)
local EnemyScalingService = require(ServerScriptService.Services.EnemyScalingService)
local CombatNetwork = require(ServerScriptService.Submodules.Core.Source.Network.Combat)
local MobData = require(ReplicatedStorage.Submodules.Core.Shared.Data.MobData)
local MobFadeData = require(ReplicatedStorage.Submodules.Core.Shared.Data.MobFadeData)
local MobFaceData = require(ReplicatedStorage.Submodules.Core.Shared.Data.MobFaceData)
local EnemyType = require(ReplicatedStorage.Submodules.Core.Shared.Enums.EnemyTypes)
local CorruptionData = require(ReplicatedStorage.Submodules.Core.Shared.Data.CorruptionData)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local ValueNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ValueNames)
local getRoot = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Character.getRoot)
local MobDeath = require(script.Parent.MobDeath)
local Blitz = require(ReplicatedStorage.Submodules.Core.Shared.Blitz)
local Difficulty = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Difficulty)
local DifficultyData = require(ReplicatedStorage.Submodules.Core.Shared.Data.DifficultyData)

--[ Constants ]--

local UPDATE_DELAY = 0.1
local DESPAWN_TIMER = 5
local BOSS_DESPAWN_TIMER = 30
local DEFAULT_KNOCKBACK = 2.5
local MODEL_LOAD_DURATION = 0.25
local START_GRACE_DELAY = 1
local MINIBOSS_ATTRIBUTE = Attributes.IsMiniBoss
local BOSS_ATTRIBUTE = Attributes.IsBoss
local ROAM_DURATION_MIN = 2
local ROAM_DURATION_MAX = 4
local ROAM_RADIUS_MIN = 20
local ROAM_RADIUS_MAX = 25
local ROAM_PICK_ATTEMPTS = 5
local PATH_RECOMPUTE_INTERVAL = 1
-- A live path is only recomputed once the target has moved this far from
-- where the path was computed to; the 1 s interval above still applies.
local PATH_RECOMPUTE_MOVE_STUDS = 4
-- QA 2026-10-21 #22 (MobSimService has the same numbers): one waypoint
-- per 4 studs, not per stud; Plastic strongly avoided rather than
-- impassable, which failed every compute on an all-Plastic floor; and
-- after a failed compute the next one waits PATH_RECOMPUTE_INTERVAL x 2^n
-- (capped at PATH_FAILURE_BACKOFF_MAX) instead of every second.
local PATH_WAYPOINT_SPACING = 4
local PATH_PLASTIC_COST = 25
local PATH_FAILURE_BACKOFF_MAX = 8
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
		workspace.IgnoreInstances.Mobs,
		workspace.IgnoreInstances.DeadMobs,
		workspace.PlayerBaseplates,
		workspace.Terrain,
		workspace.IgnoreInstances.Boundaries,
		workspace.IgnoreInstances.ActBarriers,
		workspace.IgnoreInstances.CameraPoints,
		workspace.IgnoreInstances.ArcaneSpells,
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
	-- The MobData generic attack; absent on a unique entry.
	entry: any,
	genericIndex: number?,
	-- run(mob, target) -> active duration (seconds); see _buildAttackPool.
	run: ((mob: Model, target: Model) -> number?)?,
	-- Selection rules (MobData closeRange / minRange / cooldown; see
	-- _selectAttack). readyAt is when a cooldown attack may fire again.
	closeRange: number?,
	minRange: number?,
	cooldown: number?,
	readyAt: number,
	-- Relative odds in the random pick (MobData `weight`, default 1).
	weight: number,
}

-- One pool entry from a MobData attack row. A cooldown attack first
-- becomes ready halfway through its cooldown, so it does not open a fight.
local function poolEntry(kind: string, attack: any, genericIndex: number?): AttackPoolEntry
	return {
		kind = kind,
		attackRange = attack.attackRange,
		-- Hoisted to the pool entry so _runAttack reads it uniformly (the raw
		-- attack lives under `entry`). Without this hoist the recovery wait
		-- saw nil and collapsed to ~1 frame regardless of the authored value.
		recoveryDuration = attack.recoveryDuration,
		entry = if kind == "generic" then attack else nil,
		genericIndex = genericIndex,
		run = if kind == "unique" then attack.run else nil,
		closeRange = attack.closeRange,
		minRange = attack.minRange,
		cooldown = attack.cooldown,
		readyAt = os.clock() + (attack.cooldown or 0) * 0.5,
		weight = attack.weight or 1,
	}
end

local function hasSelectionRule(entry: AttackPoolEntry): boolean
	return entry.closeRange ~= nil or entry.minRange ~= nil or entry.cooldown ~= nil
end

-- One MobData entry: the table MobData[name] resolves to.
type MobEntry = typeof(MobData[""])

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
	_data: MobEntry,

	-- Cached config (flat for speed)
	_health: number | () -> number,
	_defaultWalkSpeed: number,
	_baseWalkSpeed: number,
	_detectionRange: number,
	_hipHeight: number,
	_enemyType: string,
	_agentRadius: number?,
	_gems: MobDeath.GemsRow?,
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
	_state: string,
	_stateEndTime: number,
	_nextRoamPickAt: number,
	_chosenAttack: AttackPoolEntry?,
	-- The chase's pick among the attacks without a selection rule.
	_plainAttack: AttackPoolEntry?,
	-- The ruled pool's current random pick, held until it fires.
	_attackIntent: AttackPoolEntry?,
	_attackGeneration: number,

	-- Pathfinding state
	_path: Path?,
	_waypoints: { PathWaypoint }?,
	_nextWaypointIndex: number?,
	_reachedConnection: RBXScriptConnection?,
	_blockedConnection: RBXScriptConnection?,
	_lastPathComputeAt: number,
	_lastPathDestination: Vector3?,
	-- Failed computes in a row, and when the next compute is allowed after
	-- one (the stuck / Blocked throttle reset does not skip this).
	_pathFailures: number,
	_pathRetryAt: number,

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

	local data = MobData[model.Name]
	assert(data, "[MobBase] No data entry for mob: " .. model.Name)
	self._data = data

	-- Cached config (flat for speed). A mob spawned in the BOSS role that
	-- normally serves elsewhere (MobData bossHealth: a miniboss doubling as
	-- a placeholder boss) takes the boss's health and counts as a Boss.
	local isBossRole = model:GetAttribute(Attributes.IsBoss) == true
	self._health = if isBossRole and data.bossHealth then data.bossHealth else data.health
	self._defaultWalkSpeed = data.walkSpeed
	-- The CURRENT state's intended walk speed before status modifiers —
	-- roam sets defaultWalkSpeed/3, chase the full default, attacking 0.
	-- _resyncWalkSpeed derives the real WalkSpeed from THIS × the Chill
	-- slow, so status changes mid-state never snap the mob to the wrong
	-- state's speed.
	self._baseWalkSpeed = data.walkSpeed
	self._detectionRange = data.detectionRange or 60
	self._hipHeight = data.hipHeight
	self._enemyType = if isBossRole then EnemyType.Boss else data.enemyType
	self._agentRadius = data.agentRadius
	-- Gems scatter (MobData `gems`): DropRate = pickup count range,
	-- Gems = value-per-pickup range. nil on encounter mobs (chest-paid).
	self._gems = data.gems
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
	self._plainAttack = nil
	self._attackIntent = nil

	self._attackGeneration = 0

	-- Pathfinding state
	self._path = nil
	self._waypoints = nil
	self._nextWaypointIndex = nil
	self._reachedConnection = nil
	self._blockedConnection = nil
	self._lastPathComputeAt = 0
	self._lastPathDestination = nil :: Vector3?
	self._pathFailures = 0
	self._pathRetryAt = 0

	-- Stuck detection
	self._lastStuckSamplePos = self._rootPart and self._rootPart.Position or Vector3.zero
	self._lastStuckSampleAt = tick()

	return self
end

-- Is `attack` in play on this run's difficulty? An attack with a
-- `minDifficulty` (MobData) joins the pool only on that tier and up; the
-- run's tier comes from DungeonService (Normal outside a run).
local function attackAllowed(attack, runRank: number): boolean
	local minDifficulty = attack.minDifficulty
	if minDifficulty == nil then
		return true
	end
	return runRank >= (DifficultyData.Rank(minDifficulty) or 1)
end

local function runDifficultyRank(): number
	local dungeonService = Blitz.OptionalService("DungeonService")
	local run = dungeonService and dungeonService:GetRun()
	local difficulty = if run then run.difficulty else Difficulty.Normal
	return DifficultyData.Rank(difficulty) or 1
end

-- Builds the unified attack pool table. Pool entries are uniform shape
-- so attack selection + dispatch don't branch on source. See comment
-- in MobBase.new where this is called. Attacks above the run's
-- difficulty (`minDifficulty`) are left out.
function MobBase._buildAttackPool(_self: MobBase, data)
	local pool: { AttackPoolEntry } = {}
	local runRank = runDifficultyRank()

	for i, attack in ipairs(data.genericAttacks or {}) do
		-- genericIndex is for the animation lookup.
		if attackAllowed(attack, runRank) then
			table.insert(pool, poolEntry("generic", attack, i))
		end
	end

	for _, attack in ipairs(data.uniqueAttacks or {}) do
		-- uniqueAttacks contract: { attackRange = N, recoveryDuration = N?, run = fn }.
		-- run(mobModel, target) returns the ACTIVE attack duration (seconds);
		-- MobBase waits that, THEN recoveryDuration, before leaving Attacking — the
		-- same two-stage clock a generic attack runs on.
		if attackAllowed(attack, runRank) then
			table.insert(pool, poolEntry("unique", attack))
		end
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
		table.insert(self._attackPool, poolEntry("generic", attack, genericIndex))
	end

	for _, attack in ipairs(uniqueAttacks or {}) do
		table.insert(self._attackPool, poolEntry("unique", attack))
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
		-- The intro holds the AI. When it lets go, open the fight facing
		-- the nearest player rather than wherever the intro left the body.
		task.wait(10)
		if self._model.Parent and self:FindTarget() and self._currentTargetHRP then
			local rootPosition = self._rootPart.Position
			local targetPosition = self._currentTargetHRP.Position
			local flatTarget = Vector3.new(targetPosition.X, rootPosition.Y, targetPosition.Z)
			if (flatTarget - rootPosition).Magnitude > 0.05 then
				self._rootPart.CFrame = CFrame.lookAt(rootPosition, flatTarget)
			end
		end
	end

	self:_startAILoop()
end

function MobBase.Stop(self: MobBase)
	self._janitor:Destroy()
end

--[ Setup helpers ]--

function MobBase._resetAttributes(self: MobBase)
	self._model:SetAttribute(Attributes.MobIsAttacking, false)
	self._model:SetAttribute(Attributes.SuperArmor, false)
	self._model:SetAttribute(Attributes.SlainBy, "")
	self._model:SetAttribute(Attributes.Jailed, false)
	self._model:SetAttribute(Attributes.Slowed, false)
	self._model:SetAttribute(Attributes.CCDebounce, false)
	self._model:SetAttribute(Attributes.EnemyType, self._enemyType)
end

function MobBase._applyHumanoidProperties(self: MobBase)
	-- MobData carries the BASE health (a function-valued entry is still
	-- honoured and resolved here). The live player multiplier, the two
	-- scaling attributes and the MaxHealth / Health write all belong to
	-- EnemyScalingService, which also rescales this mob later when the
	-- party changes shape.
	local health = self._health
	local resolvedHealth: number = if type(health) == "function" then health() else health
	-- A CORRUPTED spawn (MobSpawnService.RollCorruption) is tougher.
	if self._model:GetAttribute(Attributes.Corrupted) == true then
		resolvedHealth *= CorruptionData.HealthMultiplier
	end
	self._health = resolvedHealth

	EnemyScalingService:ApplyToMob(self._model, self._humanoid, resolvedHealth)
	self:_setBaseWalkSpeed(self._defaultWalkSpeed)
	self._humanoid.HipHeight = self._hipHeight
	self._humanoid.MaxSlopeAngle = 89
	self._humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
	self._humanoid:SetStateEnabled(Enum.HumanoidStateType.Climbing, false)
	self._humanoid:SetStateEnabled(Enum.HumanoidStateType.Flying, false)

	getFaceDecal(self._model).Texture = MobFaceData.Alive[math.random(1, #MobFaceData.Alive)]
end

-- Overhead health bar -- REGULAR MOBS ONLY. Minibosses and bosses show their
-- health in the encounter HUD instead (EncounterService.Client.EncounterData
-- -> EncounterBarInterfaceController), so an overhead bar would be a second,
-- smaller copy of the same number. The role attributes are stamped before the
-- model is parented (MobSpawnService:SpawnMinibossInRoom), so they are
-- readable here at construction. _healthInterface stays nil for them; every
-- use site nil-guards.
--
-- The bar's FILL is animated by every CLIENT: MobController watches this
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
		local isAttacking = self._model:GetAttribute(Attributes.MobIsAttacking) == true

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

	-- Assist credit for the takedown rewards (MobDeath.TrackAssists).
	for _, connection in MobDeath.TrackAssists(self._model, self._humanoid, self._playerAssistRegistry) do
		self._janitor:Add(connection)
	end

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

-- The body blooms in on every CLIENT (Combat.MobFade -> MobController).
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

		MobSpawnService:IncrementMobCount(self._model)

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

	-- Root centre to root centre. The ray used to start one root-height
	-- BELOW the root and run dead flat at that height, so across a room it
	-- grazed the floor: a step, a root, the next chunk's floor at a
	-- different elevation all read as "blocked" (measured 2026-10-20: a
	-- Robombie's ray hit a Floor part 71 studs out), which sent every
	-- distant chase down the pathfinder and, when that found no path,
	-- left the mob standing until the player walked up to it.
	local rayOrigin = self._rootPart.Position
	local rayDirection = self._currentTargetHRP.Position - rayOrigin

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
		WaypointSpacing = PATH_WAYPOINT_SPACING,
		Costs = {
			SmoothPlastic = 1,
			Plastic = PATH_PLASTIC_COST,
		},
	})
	self._path = path
	self._janitor:Add(path)
	return path
end

function MobBase._followPath(self: MobBase, destination: Vector3)
	local now = tick()
	-- Backing off after a failed compute: keep walking straight at the
	-- target (the failure path's own fallback) rather than re-pathing.
	if now < self._pathRetryAt then
		self._humanoid:MoveTo(destination, self._currentTargetHRP)
		return
	end
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
		-- No path (the navmesh does not reach the spawn point, a Plastic
		-- prop walls the goal off, the target is on another chunk's
		-- floor): walk straight at the target instead of standing still,
		-- and back off before the next compute.
		self._pathFailures += 1
		self._pathRetryAt = now + math.min(PATH_RECOMPUTE_INTERVAL * 2 ^ self._pathFailures, PATH_FAILURE_BACKOFF_MAX)
		self:_cleanupPathConnections()
		self._waypoints = nil
		self._humanoid:MoveTo(destination, self._currentTargetHRP)
		return
	end
	self._pathFailures = 0

	local waypoints = path:GetWaypoints()
	self._waypoints = waypoints
	if #waypoints < 2 then
		self._humanoid:MoveTo(destination, self._currentTargetHRP)
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
	self._plainAttack = self:_pickAttack()
	self._chosenAttack = self._plainAttack
	self._lastPathComputeAt = 0 -- allow first recompute immediately
	self._pathFailures = 0
	self._pathRetryAt = 0
	self:_setBaseWalkSpeed(self._defaultWalkSpeed)
end

-- The chase's plain pick: one of the attacks WITHOUT a selection rule, at
-- random (every attack, for a pool with no rules at all -- the old pick).
function MobBase._pickAttack(self: MobBase)
	local plain = {}
	for _, entry in self._attackPool do
		if not hasSelectionRule(entry) then
			table.insert(plain, entry)
		end
	end
	if #plain == 0 then
		return nil
	end
	return plain[math.random(1, #plain)]
end

-- Whether a ruled attack may be chosen right now: off cooldown, the target
-- inside its closeRange (if it has one) and beyond its minRange (if it has
-- one).
local function eligible(entry: AttackPoolEntry, distance: number, now: number): boolean
	if entry.cooldown and now < entry.readyAt then
		return false
	end
	if entry.closeRange and distance > entry.closeRange then
		return false
	end
	if entry.minRange and distance < entry.minRange then
		return false
	end
	return true
end

-- A pool with selection rules (MobData closeRange / minRange / cooldown)
-- picks its next attack at RANDOM, by `weight`, among the attacks that make
-- sense right now (off cooldown, the target inside a closeRange / beyond a
-- minRange), then commits to it -- walking in when it is a melee pick --
-- until it fires. Only a pick that stops making sense (the target closed
-- inside a long-range attack's minRange, or left a close-range attack's
-- closeRange) re-rolls. Every attack clears the pick, so each one is a
-- fresh roll: no fixed rotation to read. A pool without rules keeps its one
-- pick for the whole chase.
function MobBase._selectAttack(self: MobBase, distance: number): AttackPoolEntry?
	local now = os.clock()
	local intent = self._attackIntent
	if intent and eligible(intent, distance, now) then
		return intent
	end

	local candidates: { AttackPoolEntry } = {}
	local totalWeight = 0
	for _, entry in self._attackPool do
		if eligible(entry, distance, now) then
			table.insert(candidates, entry)
			totalWeight += entry.weight
		end
	end
	if #candidates == 0 then
		self._attackIntent = nil
		return self._plainAttack
	end

	local roll = math.random() * totalWeight
	for _, entry in candidates do
		roll -= entry.weight
		if roll <= 0 then
			self._attackIntent = entry
			return entry
		end
	end
	self._attackIntent = candidates[#candidates]
	return self._attackIntent
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

	local distance = (self._rootPart.Position - self._currentTargetHRP.Position).Magnitude
	for _, poolEntryCandidate in self._attackPool do
		if hasSelectionRule(poolEntryCandidate) then
			self._chosenAttack = self:_selectAttack(distance)
			break
		end
	end

	if self._chosenAttack then
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
	-- A cooldown attack starts its clock the moment it fires, and the next
	-- attack is a fresh roll (_selectAttack).
	if chosenAttack.cooldown then
		chosenAttack.readyAt = os.clock() + chosenAttack.cooldown
	end
	self._attackIntent = nil

	local generation = self._attackGeneration

	task.spawn(function()
		self._model:SetAttribute("AttackInterrupted", false)
		self._model:SetAttribute(Attributes.MobIsAttacking, true)
		self._model:SetAttribute(Attributes.SuperArmor, true)
		self._humanoid:MoveTo(self._rootPart.Position) -- cancel in-flight MoveTo
		self:_setBaseWalkSpeed(0)
		self._humanoid.AutoRotate = false
		-- The chase's run / idle loop stops here: the Running handler skips
		-- every change while MobIsAttacking is set, so a run track left
		-- playing would loop under the whole attack (legs walking through a
		-- swing, or after the Mist Ambush's teleport).
		self:_stopNonAttackTracks()

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

		-- Settle into idle under whatever swing is still finishing (attack
		-- tracks play over it), and leave the locomotion state at "standing"
		-- so the next movement starts the run again.
		self._idleTrack:Play()
		self._walking = true

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
		self._model:SetAttribute(Attributes.MobIsAttacking, false)

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
		return
	end

	-- `strikes` swings in one attack (MobData; the sim mobs read the same
	-- fields): each follow-up re-faces the target from where the lunge left
	-- the mob, replays the swing and runs its own telegraph + hit frame.
	local strikes = math.max(entry.strikes or 1, 1)
	for strike = 1, strikes do
		if strike > 1 then
			if
				self._humanoid.Health <= 0
				or self._model:GetAttribute("AttackInterrupted") == true
				or self._model:GetAttribute(Attributes.Jailed)
			then
				return
			end
			local targetHRP = self._currentTargetHRP
			if targetHRP and targetHRP.Parent then
				local rootPosition = self._rootPart.Position
				local flatTarget = Vector3.new(targetHRP.Position.X, rootPosition.Y, targetHRP.Position.Z)
				if (flatTarget - rootPosition).Magnitude > 0.05 then
					self._rootPart.CFrame = CFrame.lookAt(rootPosition, flatTarget)
				end
			end
			if animTrack then
				animTrack:Play()
			end
		end
		MobService:ExecuteMobAttack(self._model, entry, if strike > 1 then entry.followUpWindUpDuration else nil)
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

	MobService:FireMobRangedAttack(self._model, targetPlayer, entry)
end

-- Unique attack pipeline: hand off to the callback, block for the ACTIVE
-- duration it returns. The callback owns its whole active timeline (windup,
-- VFX, hit-frames — typically via MobService:SpawnHitbox); _runAttack then
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
	self._model:SetAttribute(Attributes.MobIsAttacking, false)
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
			and self._model.Parent
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
			-- Looked up without the throwing getter: a floor advance destroys
			-- the model from under a live tick, and the trigger goes with it
			-- (QA 2026-10-21, P1 #5). The loop just ends with the model.
			local ragdollTrigger = self._model:FindFirstChild(ValueNames.RagdollTrigger)
			if not ragdollTrigger then
				break
			end
			if ragdollTrigger:IsA("BoolValue") and ragdollTrigger.Value then
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
	MobSpawnService:DecrementMobCount(self._model)
	self._janitor:Cleanup()

	self:_interruptAttack()

	getFaceDecal(self._model).Texture = MobFaceData.Dead

	-- The kill side (EXP, bombs, the Zombie Bomb cloud, assist payouts,
	-- corpse drops) is MobDeath's, shared with the client-simulated mobs.
	local deathContext: MobDeath.Context = {
		model = self._model,
		rootPart = self._rootPart,
		enemyType = self._enemyType,
		gems = self._gems,
		assists = self._playerAssistRegistry,
		isEncounter = self:_isEncounterMob(),
	}
	MobDeath.GrantKill(deathContext)
	local killer = MobDeath.ResolveKiller(self._model)
	if killer then
		self:_applyDeathImpulse(killer)
	end
	-- Every takedown (the killer and each recent assister), even when the
	-- killer has left.
	MobDeath.RunTakedownRewards(deathContext, killer)

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

-- True for minibosses + bosses (the encounter-tier mobs whose death plays an
-- outro cinematic). Their coin + gear rewards come from the reward chest
-- (see MobDeath.RunTakedownRewards).
--
-- Deliberately the spawn-side IsBoss / IsMiniboss flags MobSpawnService
-- stamps, NOT Shared/Functions/Mob/isEncounterEnemy (the EnemyType tier
-- from MobData): the outro, the long despawn and the reward chest
-- belong to the ROLE this mob was spawned in, and the same model can serve
-- either role across difficulties (Components/Mob).
function MobBase._isEncounterMob(self: MobBase): boolean
	return self._model:GetAttribute(Attributes.IsMiniBoss) == true
		or self._model:GetAttribute(Attributes.IsBoss) == true
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
	self._model.Parent = workspace.IgnoreInstances.DeadMobs

	local mobHitbox = self._model:FindFirstChild("MobHitbox")
	if mobHitbox then
		mobHitbox:Destroy()
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
		-- Trigger the ragdoll AFTER the collision group is locked in. A
		-- model torn down mid-death has no trigger left; nothing to ragdoll.
		local ragdollTrigger = self._model:FindFirstChild(ValueNames.RagdollTrigger)
		if ragdollTrigger and ragdollTrigger:IsA("BoolValue") then
			ragdollTrigger.Value = true
		end
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
		-- runs on every client off ONE cue (Combat.MobFade -> MobController)
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
