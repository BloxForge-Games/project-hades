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
	  * Pathfinding recompute is throttled per-mob via _lastPathComputeAt.
]]

--[ Roblox Services ]--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PathfindingService = game:GetService("PathfindingService")
local TweenService = game:GetService("TweenService")

--[ Imports ]--

local Janitor = require(ReplicatedStorage.Submodules.Core.Packages.Janitor)
local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local ZombieData = require(ReplicatedStorage.Submodules.Core.Shared.Data.ZombieData)
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

local AuraService
local ZombieSpawnService
local RagdollService
local ZombieService
local DropService
local RelicService
local RoundStatisticsService
local VFXService
local IgnoreListService
local GearDropService
local EncounterService
local DungeonService
local DamageService
local StatusConditionService

Knit.OnStart()
	:andThen(function()
		ZombieSpawnService = Knit.GetService("ZombieSpawnService")
		ZombieService = Knit.GetService("ZombieService")
		RagdollService = Knit.GetService("RagdollService")
		DropService = Knit.GetService("DropService")
		RelicService = Knit.GetService("RelicService")
		RoundStatisticsService = Knit.GetService("RoundStatisticsService")
		AuraService = Knit.GetService("AuraService")
		VFXService = Knit.GetService("VFXService")
		IgnoreListService = Knit.GetService("IgnoreListService")
		GearDropService = Knit.GetService("GearDropService")
		DamageService = Knit.GetService("DamageService")
		StatusConditionService = Knit.GetService("StatusConditionService")
		EncounterService = Knit.GetService("EncounterService")
		DungeonService = Knit.GetService("DungeonService")
	end)
	:catch(warn)

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
local PUMPKIN_DELAY = 0.75
-- CONCURRENT bomb cap, PER RELIC and SERVER-WIDE (the counter lives in
-- RelicService's limit registry, keyed by relic name and shared by every
-- player). Trick Or Trap and Fuse Bomb each get their own 15, so at most
-- 30 bombs are ever in flight at once — a frame-rate guard, not a
-- balance one. A slot is held only from the lob to the detonation
-- (PUMPKIN_DELAY + 0.25), so the cap bites only on a genuine pile-up.
local BOMB_LIMIT_PER_RELIC = 15

-- Zombie Bomb (Venom Legendary): a takedown on a POISONED mob while the
-- killer is BLIGHTED leaves a Poison Cloud at the corpse -- (callback x
-- level) damage per tick for the duration, and each tick has
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
local STUCK_DETECTION_WINDOW = 1
local STUCK_MOVE_THRESHOLD = 0.5
local STATE_ROAMING = "roaming"
local STATE_CHASE = "chase"
local STATE_ATTACKING = "attacking"
local STATE_DEAD = "dead"

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
		local hrp = character:FindFirstChild("HumanoidRootPart")
		if not hrp then
			continue
		end
		table.insert(cachedAlivePlayerEntries, { character = character, hrp = hrp })
	end
	cachedAlivePlayerEntriesAt = now
end

--[ Class ]--

local MobBase = {}
MobBase.__index = MobBase

-- model -> live mob instance. Lets systems that only hold a Model (chiefly
-- DamageService, which sees a Humanoid on hit) reach the behaviour object
-- without reversing into the Component layer. Populated in .new, cleared in
-- :Stop — weak-keyed so a model destroyed without a clean :Stop can't pin the
-- instance in memory.
MobBase._activeByModel = setmetatable({}, { __mode = "k" }) :: { [Model]: any }

function MobBase.FromModel(model: Model?): any?
	if not model then
		return nil
	end
	return MobBase._activeByModel[model]
end

--[ Construction ]--

function MobBase.new(model: Model)
	local self = setmetatable({}, MobBase)

	self._model = model
	self._rootPart = model:FindFirstChild("HumanoidRootPart") :: BasePart
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
	self._density = data.density
	self._hipHeight = data.hipHeight
	self._enemyType = data.enemyType
	self._exp = data.exp or 0
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

	self._chosenAttack = nil :: { kind: string, attackRange: number }?

	self._attackGeneration = 0

	-- Pathfinding state
	self._path = nil
	self._waypoints = nil
	self._nextWaypointIndex = nil
	self._reachedConnection = nil
	self._blockedConnection = nil
	self._lastPathComputeAt = 0

	-- Stuck detection
	self._lastStuckSamplePos = self._rootPart and self._rootPart.Position or Vector3.zero
	self._lastStuckSampleAt = tick()

	MobBase._activeByModel[model] = self

	return self
end

-- Builds the unified attack pool table. Pool entries are uniform shape
-- so attack selection + dispatch don't branch on source. See comment
-- in MobBase.new where this is called.
function MobBase:_buildAttackPool(data)
	local pool = {}

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
function MobBase:_addAttacks(genericAttacks: { any }?, uniqueAttacks: { any }?)
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

function MobBase:Start()
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

function MobBase:Stop()
	MobBase._activeByModel[self._model] = nil
	self._janitor:Destroy()
end

--[ Setup helpers ]--

function MobBase:_resetAttributes()
	self._model:SetAttribute(Attributes.ZombieIsAttacking, false)
	self._model:SetAttribute(Attributes.SuperArmor, false)
	self._model:SetAttribute(Attributes.SlainBy, "")
	self._model:SetAttribute(Attributes.Jailed, false)
	self._model:SetAttribute(Attributes.Slowed, false)
	self._model:SetAttribute(Attributes.CCDebounce, false)
	self._model:SetAttribute(Attributes.EnemyType, self._enemyType)
end

function MobBase:_applyHumanoidProperties()
	-- for _, descendant in self._model:GetChildren() do
	-- 	if descendant:IsA("BasePart") or descendant:IsA("MeshPart") then
	-- 		descendant.CustomPhysicalProperties = PhysicalProperties.new(self._density, 2, 0, 1, 1)
	-- 	end
	-- end

	if type(self._health) == "function" then
		self._health = self._health()
	end

	self._humanoid.MaxHealth = self._health
	self._humanoid.Health = self._health
	self:_setBaseWalkSpeed(self._defaultWalkSpeed)
	self._humanoid.HipHeight = self._hipHeight
	self._humanoid.MaxSlopeAngle = 89
	self._humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
	self._humanoid:SetStateEnabled(Enum.HumanoidStateType.Climbing, false)
	self._humanoid:SetStateEnabled(Enum.HumanoidStateType.Flying, false)

	self._model.Head.Face.Texture = FACE_IDS[math.random(1, #FACE_IDS)]
end

-- Overhead health bar -- REGULAR MOBS ONLY. Minibosses and bosses show their
-- health in the encounter HUD instead (EncounterService.Client.EncounterData
-- -> EncounterBarInterfaceController), so an overhead bar would be a second,
-- smaller copy of the same number. The role attributes are stamped before the
-- model is parented (ZombieSpawnService:SpawnMinibossInRoom), so they are
-- readable here at construction. _healthInterface stays nil for them; every
-- use site nil-guards.
function MobBase:_buildHealthUI()
	if
		self._model:GetAttribute(Attributes.IsBoss) == true
		or self._model:GetAttribute(Attributes.IsMiniBoss) == true
	then
		return
	end
	self._healthInterface = ReplicatedStorage.GameAssets.BillboardGuis.HealthInterface:Clone()
	self._healthInterface.Parent = self._model.Head
end

function MobBase:_prepareDeathSound()
	self._deathSound = self._deathSound:Clone()
	self._deathSound.Parent = self._rootPart
end

function MobBase:_setupAnimations()
	self._idleTrack:Play()
end

function MobBase:_setNetworkOwner(owner: Player?)
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
function MobBase:_setBaseWalkSpeed(baseSpeed: number)
	self._baseWalkSpeed = baseSpeed
	self:_resyncWalkSpeed()
end

function MobBase:_resyncWalkSpeed()
	-- Chill status slow (0..1 multiplier, stamped by StatusConditionService;
	-- nil = no chill). Composes MULTIPLICATIVELY with the binary Slowed
	-- state so a chilled + slowed mob is slower than either alone. Jailed
	-- stays a hard 0. Derived from the CURRENT state's base speed, so a
	-- status flip mid-roam / mid-attack keeps that state's pace.
	local baseSpeed = self._baseWalkSpeed or self._defaultWalkSpeed
	local statusSlow = self._model:GetAttribute("StatusSlowMultiplier") or 1
	if self._model:GetAttribute(Attributes.Jailed) then
		self._humanoid.WalkSpeed = 0
	elseif self._model:GetAttribute(Attributes.Slowed) then
		self._humanoid.WalkSpeed = (baseSpeed / 2.5) * statusSlow
	else
		self._humanoid.WalkSpeed = baseSpeed * statusSlow
	end
end

--[ Listeners ]--

function MobBase:_setupListeners()
	self._janitor:Add(self._model:GetAttributeChangedSignal(Attributes.Jailed):Connect(function()
		self:_resyncWalkSpeed()
	end))

	self._janitor:Add(self._model:GetAttributeChangedSignal(Attributes.Slowed):Connect(function()
		self:_resyncWalkSpeed()
	end))

	self._janitor:Add(self._model:GetAttributeChangedSignal("StatusSlowMultiplier"):Connect(function()
		self:_resyncWalkSpeed()
	end))

	-- HealthChanged: update bar + play damaged anim (unless SuperArmor)
	self._janitor:Add(self._humanoid.HealthChanged:Connect(function()
		-- nil for minibosses / bosses (see _buildHealthUI).
		if self._healthInterface then
			self._healthInterface.Enabled = true
			self._healthInterface.InnerFrame.RedBar:TweenSize(
				UDim2.fromScale(self._humanoid.Health / self._humanoid.MaxHealth, 1.3),
				Enum.EasingDirection.Out,
				Enum.EasingStyle.Quad,
				0.1
			)
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
		if slainBy and slainBy ~= "" then
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

function MobBase:_stopNonAttackTracks()
	for _, track in self._humanoid.Animator:GetPlayingAnimationTracks() do
		if not track.Name:match("Attack") then
			track:Stop()
		end
	end
end

--[ Fade-in on spawn ]--

function MobBase:_fadeInOnSpawn()
	for _, part in self._model:GetDescendants() do
		if
			part:IsA("BasePart")
			and part.Name ~= "RaycastHitbox"
			and part.Name ~= "HumanoidRootPart"
			and part.Name ~= "ParticlePart"
		then
			part.Transparency = 1
		end
	end

	task.delay(MODEL_LOAD_DURATION, function()
		repeat
			task.wait(MODEL_LOAD_DURATION)
		until self._model:FindFirstChild("RaycastHitbox") and self._model:FindFirstChild("Humanoid")

		for _, part in self._model:GetDescendants() do
			if
				part:IsA("BasePart")
				and part.Name ~= "RaycastHitbox"
				and part.Name ~= "HumanoidRootPart"
				and part.Name ~= "ParticlePart"
			then
				TweenService:Create(
					part,
					TweenInfo.new(0.75, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut),
					{ Transparency = 0 }
				):Play()
			end
		end

		ZombieSpawnService:IncrementZombieCount(self._model)
	end)
end

--[ Targeting ]--

function MobBase:FindTarget(): boolean
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

function MobBase:_hasLineOfSight(): boolean
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

function MobBase:_cleanupPathConnections()
	if self._blockedConnection then
		self._blockedConnection:Disconnect()
		self._blockedConnection = nil
	end
	if self._reachedConnection then
		self._reachedConnection:Disconnect()
		self._reachedConnection = nil
	end
end

function MobBase:_followPath(destination: Vector3)
	local now = tick()
	if now - self._lastPathComputeAt < PATH_RECOMPUTE_INTERVAL then
		return
	end
	self._lastPathComputeAt = now

	if not self._path then
		self._path = PathfindingService:CreatePath({
			AgentRadius = self._agentRadius or 2,
			AgentHeight = 5,
			AgentCanJump = false,
			WaypointSpacing = 1,
			Costs = {
				SmoothPlastic = 1,
				Plastic = math.huge,
			},
		})
		self._janitor:Add(self._path)
	end

	local ok = pcall(function()
		self._path:ComputeAsync(self._rootPart.Position, destination)
	end)
	if not ok or self._path.Status ~= Enum.PathStatus.Success then
		return
	end

	self._waypoints = self._path:GetWaypoints()
	if #self._waypoints < 2 then
		return
	end

	self:_cleanupPathConnections()

	self._blockedConnection = self._path.Blocked:Connect(function(blockedWaypointIndex)
		if blockedWaypointIndex >= self._nextWaypointIndex then
			if self._blockedConnection then
				self._blockedConnection:Disconnect()
			end
			-- Force a recompute on the next tick by zeroing the throttle.
			self._lastPathComputeAt = 0
		end
	end)

	self._nextWaypointIndex = 2

	self._reachedConnection = self._humanoid.MoveToFinished:Connect(function(reached)
		if reached and self._nextWaypointIndex < #self._waypoints then
			self._nextWaypointIndex += 1
			self._humanoid:MoveTo(self._waypoints[self._nextWaypointIndex].Position)
		else
			self:_cleanupPathConnections()
		end
	end)

	self._humanoid:MoveTo(self._waypoints[self._nextWaypointIndex].Position)
end

function MobBase:_checkStuck()
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

function MobBase:_pickRoamPosition(): Vector3?
	if not self._rootPart then
		return nil
	end
	local angle = math.random() * math.pi * 2
	local distance = math.random(ROAM_RADIUS_MIN, ROAM_RADIUS_MAX)
	local origin = self._rootPart.Position
	return origin + Vector3.new(math.cos(angle) * distance, 0, math.sin(angle) * distance)
end

function MobBase:_isPointReachable(point: Vector3): boolean
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

function MobBase:_enterRoaming()
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

function MobBase:_enterChase()
	self._state = STATE_CHASE
	self._chosenAttack = self:_pickAttack()
	self._lastPathComputeAt = 0 -- allow first recompute immediately
	self:_setBaseWalkSpeed(self._defaultWalkSpeed)
end

function MobBase:_pickAttack()
	local pool = self._attackPool
	if #pool == 0 then
		return nil
	end
	return pool[math.random(1, #pool)]
end

--[ Chase step ]--

function MobBase:_chaseStep()
	if self._model:GetAttribute(Attributes.Jailed) then
		return
	end
	if not self._currentTarget or not self._currentTargetHRP or not self._currentTargetHRP.Parent then
		-- Target lost. Fall back to Roaming.
		self:_enterRoaming()
		return
	end

	if self._chosenAttack then
		local distance = (self._rootPart.Position - self._currentTargetHRP.Position).Magnitude
		if distance <= self._chosenAttack.attackRange then
			local entry = self._chosenAttack.entry
			local needsLOS = entry and entry.requiresLineOfSight
			if not needsLOS or self:_hasLineOfSight() then
				self:_runAttack(self._chosenAttack)
				return
			end
			-- In range but the attack is LOS-gated and sight is blocked.
			-- Fall through to chase — pathfinder picks up below.
		end
	end

	if self:_hasLineOfSight() then
		self._humanoid:MoveTo(self._currentTargetHRP.Position, self._currentTargetHRP)
	else
		self:_followPath(self._currentTargetHRP.Position)
	end

	self:_checkStuck()
end

--[ Attack pipeline ]--

function MobBase:_runAttack(chosenAttack)
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

function MobBase:_runGenericAttack(chosenAttack)
	local entry = chosenAttack.entry
	local genericIndex = chosenAttack.genericIndex

	local animTrack = self._loadedGenericAnimations[genericIndex]
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

function MobBase:_runRangedSwing(entry)
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
function MobBase:_runUniqueAttack(chosenAttack)
	local target = self._currentTarget
	if not target then
		return
	end

	if self._model:GetAttribute(Attributes.Jailed) then
		return
	end
	local duration = chosenAttack.run(self._model, target) or 0
	task.wait(duration)
end

function MobBase:_afterAttack()
	self:_enterRoaming()
end

function MobBase:_interruptAttack()
	self._attackGeneration += 1
	self._model:SetAttribute("AttackInterrupted", true)
	self._model:SetAttribute("MobHighlightAttackActive", false)
	self._model:SetAttribute(Attributes.ZombieIsAttacking, false)
	self._model:SetAttribute(Attributes.SuperArmor, false)
	self._humanoid.AutoRotate = true
	for _, track in self._humanoid:GetPlayingAnimationTracks() do
		track:Stop()
	end
end

--[ Main AI loop ]--

function MobBase:_startAILoop()
	task.spawn(function()
		while
			self._model
			and self._model:FindFirstChild("Humanoid")
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
			if self._model[ValueNames.RagdollTrigger].Value then
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
				if not hasTarget then
					self:_enterRoaming()
					continue
				end
				-- Target escaped detection? Back to Roaming.
				local distance = (self._rootPart.Position - self._currentTargetHRP.Position).Magnitude
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

function MobBase:OnDeath()
	self._state = STATE_DEAD
	ZombieSpawnService:DecrementZombieCount(self._model)
	self._janitor:Cleanup()

	self:_interruptAttack()

	self._model.Head.Face.Texture = DEAD_FACE_ID

	if self._model:GetAttribute(Attributes.SlainBy) ~= "" then
		local killer = Players:FindFirstChild(self._model:GetAttribute(Attributes.SlainBy))
		if killer and killer.Character then
			self:_applyDeathImpulse(killer)
			self:_runPumpkinExplosion(killer)
			self:_runFuseBombDrop(killer)
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

function MobBase:_applyDeathImpulse(killer: Player)
	local direction = (self._rootPart.Position - killer.Character.HumanoidRootPart.Position).Unit
	direction = Vector3.new(direction.X, 0, direction.Z).Unit
	self._rootPart:ApplyImpulse((direction + Vector3.new(0, 1, 0)) * self._rootPart.AssemblyMass * (200 * 0.35))
end

function MobBase:_runPumpkinExplosion(killer: Player)
	local pumpkinCount = RelicService:GetSpecificRelicRegistry(killer, RelicNames["Trick Or Trap"])
	if not pumpkinCount or pumpkinCount <= 0 then
		return
	end
	-- ANY takedown drops pumpkins. The Burning-target requirement came off
	-- in the 2026-08 pass when the relic became NC: gating an opener behind
	-- a Burn the player might have no way to apply made it dead on pickup.
	-- The pumpkins apply Burn themselves now, so this is what STARTS the
	-- Blaze chain rather than paying it off.

	local rayOrigin = self._rootPart.Position
	local rayDirection = Vector3.new(0, -500, 0)
	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = {
		workspace.IgnoreInstances.Zombies,
		workspace.IgnoreInstances.DeadZombies,
	}
	local raycastResult = workspace:Raycast(rayOrigin, rayDirection, raycastParams)
	local groundPosition = raycastResult and raycastResult.Position or self._rootPart.Position
	local cachedCFrame = CFrame.new(groundPosition) + Vector3.new(0, 3.25 / 2, 0)

	local magicName = MagicNames["Pumpkin Explosion"]

	-- Drops 1-3 pumpkins; each one claims a slot against the global Trick Or
	-- Trap cap (BOMB_LIMIT_PER_RELIC) before spawning, and simply does not
	-- spawn when the cap is full. The claim is read-then-write with no yield
	-- between, so the three cannot over-claim each other.
	for _ = 1, math.random(1, 3) do
		task.spawn(function()
			local currentLimit = RelicService:GetRelicLimitRegistry(RelicNames["Trick Or Trap"]) or 0
			if currentLimit >= BOMB_LIMIT_PER_RELIC then
				return
			end

			RelicService:SetRelicLimitRegistry(RelicNames["Trick Or Trap"], currentLimit + 1)
			local targetCFrame = cachedCFrame + Vector3.new(math.random(-5, 5), 0, math.random(-5, 5))

			RelicService.Client.OnPumpkinEffectActivated:FireAll(
				self._rootPart.Position,
				targetCFrame.Position,
				workspace:GetServerTimeNow(),
				PUMPKIN_DELAY,
				magicName,
				RelicNames["Trick Or Trap"]
			)

			task.delay(PUMPKIN_DELAY + 0.25, function()
				-- Slot released FIRST, before the blast: this bomb is detonating,
				-- so its slot is spent either way, and a hitbox that ERRORS must
				-- never strand it — the counter is server-wide and nothing ever
				-- resets it, so a leaked slot would starve the relic for the life
				-- of the server.
				RelicService:SetRelicLimitRegistry(
					RelicNames["Trick Or Trap"],
					(RelicService:GetRelicLimitRegistry(RelicNames["Trick Or Trap"]) or 0) - 1
				)
				VFXService:CreateHitbox(
					magicName,
					killer,
					targetCFrame,
					TagList.Zombie,
					IgnoreListService:GetWeaponIgnoreList(),
					function(model: Model)
						-- isRelicSourced = true rides the UNTYPED lane now:
						-- unqualified Damage bonuses scale the blast, typed
						-- relics/crits never apply. Still rolls the WEAPON
						-- applier hub via onHitboxDamage (isMagic = false).
						onHitboxDamage(model, targetCFrame, killer, MagicData[magicName], false, true)

						-- "...and burning them": the blast applies Burn outright
						-- rather than rolling for it, which is what lets Trick Or
						-- Trap open the Blaze tree on its own.
						if StatusConditionService then
							StatusConditionService:ApplyStatus(killer, model, StatusConditions.Burn)
						end
					end,
					MagicData[magicName].hitboxSize.X
				)
			end)
		end)
	end
end

-- Fuse Bomb (Neutral Rare): the Pumpkin Explosion recipe — same fuse
-- delay, same cap machinery (its OWN BOMB_LIMIT_PER_RELIC counter, not
-- one shared with the pumpkins), same hitbox — but ONE lobbed
-- bomb per takedown (no 1-3 roll), with the Fuse Bomb model (relicName
-- rides the client payload), and the blast is PLAIN damage: neither
-- weapon nor magic — the raw path, no amplifiers / crit / appliers
-- (Summer Fireworks' recipe). No Burn either.
function MobBase:_runFuseBombDrop(killer: Player)
	local bombCount = RelicService:GetSpecificRelicRegistry(killer, RelicNames["Fuse Bomb"])
	if not bombCount or bombCount <= 0 then
		return
	end

	local rayOrigin = self._rootPart.Position
	local rayDirection = Vector3.new(0, -500, 0)
	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = {
		workspace.IgnoreInstances.Zombies,
		workspace.IgnoreInstances.DeadZombies,
	}
	local raycastResult = workspace:Raycast(rayOrigin, rayDirection, raycastParams)
	local groundPosition = raycastResult and raycastResult.Position or self._rootPart.Position
	local cachedCFrame = CFrame.new(groundPosition) + Vector3.new(0, 3.25 / 2, 0)

	local magicName = MagicNames["Fuse Bomb Explosion"]

	-- ONE bomb per takedown — a plain do-block where the pumpkin rolls
	-- its 1-3 loop, so the shared body keeps its shape.
	do
		task.spawn(function()
			local currentLimit = RelicService:GetRelicLimitRegistry(RelicNames["Fuse Bomb"]) or 0
			if currentLimit >= BOMB_LIMIT_PER_RELIC then
				return
			end

			RelicService:SetRelicLimitRegistry(RelicNames["Fuse Bomb"], currentLimit + 1)
			local targetCFrame = cachedCFrame + Vector3.new(math.random(-5, 5), 0, math.random(-5, 5))

			RelicService.Client.OnPumpkinEffectActivated:FireAll(
				self._rootPart.Position,
				targetCFrame.Position,
				workspace:GetServerTimeNow(),
				PUMPKIN_DELAY,
				magicName,
				RelicNames["Fuse Bomb"]
			)

			task.delay(PUMPKIN_DELAY + 0.25, function()
				-- Slot released FIRST — see the pumpkin's note above.
				RelicService:SetRelicLimitRegistry(
					RelicNames["Fuse Bomb"],
					(RelicService:GetRelicLimitRegistry(RelicNames["Fuse Bomb"]) or 0) - 1
				)
				VFXService:CreateHitbox(
					magicName,
					killer,
					targetCFrame,
					TagList.Zombie,
					IgnoreListService:GetWeaponIgnoreList(),
					function(model: Model)
						-- UNTYPED relic lane (isRelicSourced): unqualified
						-- Damage bonuses scale the blast; Weapon/Magic-typed
						-- relics and crits never apply.
						local targetHumanoid = model:FindFirstChild("Humanoid")
						if not targetHumanoid or not DamageService then
							return
						end
						local config = MagicData[magicName]
						local damageRoll = if config.runtimeDamageCallback
							then config.runtimeDamageCallback(killer)
							else config.damage
						DamageService:TakeDamage(killer, targetHumanoid, damageRoll, false, false, false, true, true)
					end,
					MagicData[magicName].hitboxSize.X
				)
			end)
		end)
	end
end

function MobBase:_runZombieBombCloud(killer: Player)
	local damagePerLevel = RelicService:GetRelicEffect(killer, RelicNames["Zombie Bomb"])
	if not damagePerLevel or RelicService:GetSpecificRelicRegistry(killer, RelicNames["Zombie Bomb"]) <= 0 then
		return
	end
	-- Gates: the mob died POISONED (family read -- Noxious Venom counts;
	-- any player's stacks, read before the stack watchers release) AND the
	-- killer is Blighted right now.
	if not (StatusConditionService and StatusConditionService:IsPoisoned(self._model)) then
		return
	end
	local killerHrp = killer.Character and killer.Character:FindFirstChild("HumanoidRootPart")
	if not killerHrp or killerHrp:FindFirstChild(AuraNames.Blighted) == nil then
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
		local overlapParams = OverlapParams.new()
		overlapParams.FilterType = Enum.RaycastFilterType.Include
		overlapParams.FilterDescendantsInstances = { workspace.IgnoreInstances.Zombies }

		local elapsed = 0
		while elapsed < ZOMBIE_BOMB_CLOUD_DURATION do
			task.wait(ZOMBIE_BOMB_CLOUD_TICK_SECONDS)
			elapsed += ZOMBIE_BOMB_CLOUD_TICK_SECONDS

			local struck = {}
			for _, part in workspace:GetPartBoundsInRadius(cloudPosition, ZOMBIE_BOMB_CLOUD_RADIUS, overlapParams) do
				local model = part:FindFirstAncestorWhichIsA("Model")
				if not model or struck[model] then
					continue
				end
				local targetHumanoid = model:FindFirstChildOfClass("Humanoid")
				if not targetHumanoid or targetHumanoid.Health <= 0 then
					continue
				end
				struck[model] = true
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
					StatusConditionService:ApplyStatus(killer, model, StatusConditions.Poison, false)
				end
			end
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
function MobBase:_assistedRecently(name: string): boolean
	local lastHitAt = self._playerAssistRegistry[name]
	return lastHitAt ~= nil and (os.clock() - lastHitAt) <= ASSIST_WINDOW_SECONDS
end

function MobBase:_handleAssists()
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
			local MagicService = Knit.GetService("MagicService")
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

		-- TODO: EXP drop, currently disabled until we have a solid design for it. The main
		-- if ExperienceService and self._exp > 0 then
		-- 	ExperienceService:GrantExp(player, self._exp)
		-- end
	end
end

-- Personal-loot gear roll for every player in the assist registry. Split out
-- of _handleAssists so encounter mobs can DEFER it to after the outro
-- cinematic; regular mobs call it inline in OnDeath.
function MobBase:_dropGear()
	if not GearDropService then
		return
	end
	for name, _ in self._playerAssistRegistry do
		local player = Players:FindFirstChild(name)
		if player and self:_assistedRecently(name) then
			GearDropService:DropGear(player, self._rootPart.Position, self._model:GetAttribute(Attributes.EnemyType))
		end
	end
end

-- True for minibosses + bosses (the encounter-tier mobs whose death plays an
-- outro cinematic). Their coin + gear rewards are held until that cinematic
-- finishes (see _deferEncounterRewards).
function MobBase:_isEncounterMob(): boolean
	return self._model:GetAttribute(Attributes.IsMiniBoss) == true
		or self._model:GetAttribute(Attributes.IsBoss) == true
end

-- Holds the coin + gear drops until EncounterService finishes the outro
-- cinematic, then drops them at the corpse — so the rewards "rain down" when
-- control returns to the player instead of landing mid-cinematic. The corpse
-- persists through the outro (encounter despawn timer, see _scheduleDespawn),
-- so _rootPart is still a valid drop origin when the signal fires. One-shot —
-- disconnects once its own mob's outro fires.
function MobBase:_deferEncounterRewards(killer)
	if not EncounterService then
		-- Defensive: no EncounterService → drop immediately.
		self:_dropGear()
		self:_dropCoins(killer)
		return
	end
	-- NOTHING drops at the corpse any more. An encounter's gear and coins
	-- are the reward CHEST's contents (EncounterChestService, off the same
	-- outro beat), so dropping them here as well would pay the player
	-- twice. The listener is kept as the seam where corpse-side rewards
	-- would go if any are ever added back.
	local conn
	conn = EncounterService.OnEncounterOutroFinished:Connect(function(_kind, _room, mob)
		if mob ~= self._model then
			return
		end
		conn:Disconnect()
	end)
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
function MobBase:_dropCoins(_killer)
	local roomId = self._model:GetAttribute("RoomId")
	local dungeon = DungeonService and DungeonService:GetActiveDungeon()
	local room = dungeon and roomId and dungeon.roomsById[roomId]
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

function MobBase:_playDeathSound()
	self._deathSound:Play()
end

function MobBase:_applyForwardKnockback()
	self._rootPart:ApplyImpulse(-self._rootPart.CFrame.LookVector * (DEFAULT_KNOCKBACK * self._rootPart.AssemblyMass))
end

-- Death-style hooks (overridable). Default mobs collapse via ragdoll
-- physics; minibosses/bosses override _ragdollOnDeath to stay upright and
-- _onDeathAnimation to play a death animation in place (placeholder print
-- until the animation asset exists).
function MobBase:_ragdollOnDeath(): boolean
	return true
end

function MobBase:_onDeathAnimation() end

function MobBase:_relocateToDeadFolder()
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
	for _, animation in self._humanoid:GetPlayingAnimationTracks() do
		animation:Stop()
	end

	if self:_ragdollOnDeath() then
		-- Trigger the ragdoll AFTER the collision group is locked in.
		self._model[ValueNames.RagdollTrigger].Value = true
	else
		-- Non-ragdoll death (minibosses / bosses): stay upright in place and
		-- play a death animation instead of collapsing. The existing
		-- _scheduleDespawn fade removes the body on the spot afterwards.
		self._humanoid.AutoRotate = false
		self:_onDeathAnimation()
	end
end

function MobBase:_scheduleDespawn()
	-- Minibosses + bosses use the long despawn so the corpse survives its
	-- outro cinematic (the camera holds on it) AND the deferred coin/gear
	-- drops fire while _rootPart is still a valid origin (_deferEncounterRewards).
	local longDespawn = self._model:GetAttribute(Attributes.BattleTask) or self:_isEncounterMob()
	local timer = if longDespawn then BOSS_DESPAWN_TIMER else DESPAWN_TIMER

	task.delay(timer, function()
		if not self._model or not self._model.Parent then
			return
		end

		for _, descendant in self._model:GetDescendants() do
			if descendant:IsA("BasePart") or descendant:IsA("Decal") then
				TweenService:Create(
					descendant,
					TweenInfo.new(1.5, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut),
					{ Transparency = 1 }
				):Play()
			elseif descendant:IsA("ParticleEmitter") then
				descendant.Enabled = false
			end
		end

		task.wait(1.5)
		if self._model then
			self._model:Destroy()
		end
	end)
end

return MobBase
