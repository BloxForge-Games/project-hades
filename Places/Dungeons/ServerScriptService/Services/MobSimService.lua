--!strict
--[[
	Module: MobSimService.lua
	Description:
	Server half of the CLIENT-SIMULATED mob (MobData `useMobSim`). The
	client half is MobRenderController; the movement maths both run is
	Shared/Functions/Mob/mobPath; the stream between them is Mob.blink.

	What the server keeps per mob is a PROXY, not a rig:
	  * a Model with the template's HumanoidRootPart (anchored), Torso,
	    Head, RaycastHitbox and MobHitbox, plus a Hurtbox sized to the body,
	    all invisible, CanCollide off and welded to the root, so every
	    existing hit query (melee boxes, bullets, arcane / relic radii,
	    traps, aim assist) finds it exactly as it found the old rig
	  * a DORMANT Humanoid (EvaluateStateMachine off, no joints, no
	    Animator) that only holds Health, so DamageService, status ticks,
	    EnemyScalingService and every HealthChanged reader keep working
	  * the template's attributes and tags (Zombie), plus MobSimId /
	    MobTemplate / MobRootOffset for the renderer
	No Humanoid physics, no server animations, no per-mob Highlight,
	billboard or sound: every client draws, animates and kills its own
	copy of the real rig.

	One Heartbeat drives every sim mob. Each mob THINKS on its own
	staggered clock (THINK_INTERVAL_NEAR, slower the further it is from
	the nearest player) and, when it thinks, the proxy root is moved to
	where its current Move puts it -- all roots in one BulkMoveTo. Between
	thinks the proxy holds still; the clients walk their copies smoothly
	along the same Move, and the proxy's replicated CFrame is their
	correction.

	State machine (same rules as MobBase):
	  Roaming  -- player within detectionRange, roam timer up --> Chase
	  Chase    -- target inside the picked attack's range (+ LOS) --> Attacking
	  Chase    -- target escapes detectionRange --> Roaming
	  Attacking -- wind-up, hit frame, recovery done --> Roaming (2-4 s)
	  any      -- Health <= 0 --> dead (MobDeath rewards, client ragdoll)

	Movement: line of sight to the target = one straight leg to a point
	beside it (each mob keeps its own approach angle so a pack surrounds
	the player instead of stacking). No line of sight = a PathfindingService
	path, through a server-wide queue (PATH_STARTS_PER_FRAME,
	PATH_MAX_IN_FLIGHT), at most once per PATH_RECOMPUTE_SECONDS per mob and
	only once the target has moved PATH_RECOMPUTE_MOVE_STUDS, backing off
	after failures. A leg is re-sent whenever its speed changes (Chill,
	Jail).

	Support mobs (MobData `support`, the Healer) chase HURT ALLIES, not
	players, the way the Wizard works a player: walk until a hurt ally is
	in range, cast the heal on it, then roam 2-4 s before the next one
	(_supportStep). With nobody hurt they trail their nearest allies.

	Knockback (ApplyKnockback, from DamageService): a hit queues a push;
	the next frame sums the queue, wall- and ledge-checks it, moves the
	mob there and sends ONE leg from the pushed spot that starts a
	stagger later, so it holds there before walking on. Every client
	eases its rig across the gap (MobRenderController's leg blend) and
	the proxy -- the hitboxes -- is already there.
]]

--[ Roblox Services ]--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local PathfindingService = game:GetService("PathfindingService")
local ServerScriptService = game:GetService("ServerScriptService")

--[ Imports ]--

local MobService = require(ServerScriptService.Services.MobService)
local MobSpawnService = require(ServerScriptService.Services.MobSpawnService)
local EnemyScalingService = require(ServerScriptService.Services.EnemyScalingService)
local MobDeath = require(ServerScriptService.Mobs.MobDeath)
local CombatNetwork = require(ServerScriptService.Submodules.Core.Source.Network.Combat)
local MobNetwork = require(ServerScriptService.Submodules.Core.Source.Network.Mob)
local MobData = require(ReplicatedStorage.Submodules.Core.Shared.Data.MobData)
local MobFadeData = require(ReplicatedStorage.Submodules.Core.Shared.Data.MobFadeData)
local CorruptionData = require(ReplicatedStorage.Submodules.Core.Shared.Data.CorruptionData)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local mobPath = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Mob.mobPath)
local getRoot = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Character.getRoot)

--[ Constants ]--

-- Think rate by distance to the nearest living player. A mob in the fight
-- keeps MobBase's 10 Hz; one a room away cannot reach anyone before its
-- next think anyway.
local THINK_INTERVAL_NEAR = 0.1
local THINK_INTERVAL_MID = 0.25
local THINK_INTERVAL_FAR = 0.5
local THINK_NEAR_STUDS = 60
local THINK_MID_STUDS = 150
-- Inside this range of a player the proxy follows its leg every frame, not
-- only on thinks (see _step).
local TRACK_EVERY_FRAME_STUDS = THINK_MID_STUDS

-- Spawn: the mob holds still this long before its first decision (MobBase's
-- START_GRACE_DELAY), while every client fades its body in.
local START_GRACE_SECONDS = 1
-- How far under a spawn point (attachment + 2 studs) to look for its floor.
local SPAWN_FLOOR_SEARCH_STUDS = 20

-- A sim mob's body has no physics to push it out of a pillar or off
-- another mob, so a spawn lands on the nearest CLEAR spot (no geometry
-- inside its body, no other sim mob closer than SPAWN_MOB_SPACING of their
-- combined radii) on rings of CLEAR_SEARCH_RINGS studs, CLEAR_SEARCH_DIRECTIONS
-- around. A standing mob that finds itself inside geometry anyway (a lunge
-- into a corner) walks out to the nearest clear spot; checked once per
-- UNSTICK_CHECK_SECONDS while it stands still.
local CLEAR_SEARCH_RINGS = { 2, 4, 6, 8 }
local CLEAR_SEARCH_DIRECTIONS = 8
local SPAWN_MOB_SPACING = 0.8
local UNSTICK_CHECK_SECONDS = 1
local DESPAWN_SECONDS = 5

-- Knockback: a pushed mob holds where it lands for this many seconds
-- per stud of push (melee 2 studs = 0.2 s), capped, before it walks on,
-- so a chasing mob visibly gives ground instead of walking straight
-- back through the push. A push the walk checks refuse is tried at
-- half length once, then dropped.
local KNOCKBACK_STAGGER_PER_STUD = 0.1
local KNOCKBACK_STAGGER_MAX = 0.35
local KNOCKBACK_MIN_STUDS = 0.1

-- Support mobs: how far they look for hurt allies to walk to, how far
-- short of a target spot they stop (inside the heal's range), how close
-- to a goal counts as there, and how far a goal may drift before a
-- walking mob re-aims.
local SUPPORT_HEAL_SEARCH_STUDS = 60
local SUPPORT_STANDOFF_STUDS = 8
local SUPPORT_ARRIVE_STUDS = 1.5
local SUPPORT_REGOAL_STUDS = 4

-- Roaming (MobBase's numbers): a point 20-25 studs away at half speed, a
-- fresh one every 2-4 s. A candidate needs a clear ray from the root and a
-- floor under it, so a mob never roams off a ledge.
local ROAM_DURATION_MIN = 2
local ROAM_DURATION_MAX = 4
local ROAM_RADIUS_MIN = 20
local ROAM_RADIUS_MAX = 25
local ROAM_PICK_ATTEMPTS = 6
-- Attempts past the first half try a shorter hop, so a mob boxed in by
-- walls still finds somewhere to wander instead of standing still.
local ROAM_SHORT_RADIUS_MIN = 8
local ROAM_SHORT_RADIUS_MAX = 15
local ROAM_FLOOR_SLOP_STUDS = 6
local DEFAULT_DETECTION_RANGE = 60

-- Chasing in the open: stop this far from the target (clamped to the
-- picked attack's reach), at the mob's own approach angle off the line
-- between them. A new leg goes out once the target has moved from the last
-- leg's goal by CHASE_REGOAL_STUDS, or by CHASE_REGOAL_DISTANCE_FRACTION of
-- the gap when that is larger: a mob across the room re-aims less often
-- than one about to swing, which is most of the leg traffic.
local CHASE_STOP_MIN_STUDS = 2.5
local CHASE_STOP_MAX_STUDS = 4
local CHASE_STOP_RANGE_FRACTION = 0.6
local CHASE_REGOAL_STUDS = 3
local CHASE_REGOAL_DISTANCE_FRACTION = 0.15
-- Two chasers never aim within this many studs of each other's goal: the
-- later one swings its approach angle by CHASE_SEPARATION_STEP (either
-- side, up to twice) so a pack fans out around the player.
local CHASE_SEPARATION_STUDS = 2.5
-- A re-aimed chase goal this close to where the mob stands is not sent.
local CHASE_SAME_SPOT_STUDS = 0.5
local CHASE_SEPARATION_STEP = math.rad(35)

-- A sim mob has no physics, so nothing but these checks keeps a straight
-- leg out of walls and off ledges. A leg is walkable when a sphere of the
-- mob's BODY radius (half its widest horizontal extent, so arms and
-- shoulders count, not just the centre line) clears the way at root
-- height, the same sphere fits at the end without touching anything, and
-- a floor sits within WALK_STEP_STUDS of the straight line every
-- WALK_FLOOR_SAMPLE_STUDS (at most WALK_FLOOR_SAMPLES_MAX probes). The
-- sphere is kept WALK_PROBE_FLOOR_GAP clear of the floor so it never reads
-- the ground as a wall. Only checked when a leg is about to be sent; a
-- failed check is not retried for WALK_RECHECK_SECONDS.
local WALK_PROBE_RADIUS_MIN = 0.5
local WALK_PROBE_FLOOR_GAP = 0.5
local WALK_FLOOR_SAMPLE_STUDS = 4
local WALK_FLOOR_SAMPLES_MAX = 8
local WALK_STEP_STUDS = 3
local WALK_RECHECK_SECONDS = 0.3
-- How far under a (possibly jumping) player's root to look for the floor
-- a chase leg ends on.
local GOAL_FLOOR_SEARCH_STUDS = 10
local APPROACH_ANGLE_MAX = math.rad(50)
-- A player's root sits about this high over the floor under them.
local PLAYER_ROOT_HEIGHT = 3

-- Pathfinding (QA 2026-10-21 #22): 4-stud waypoints instead of 1, Plastic
-- strongly avoided rather than impassable (an all-Plastic floor used to
-- fail every compute), a server-wide budget, and a per-mob back-off.
local PATH_WAYPOINT_SPACING = 4
local PATH_PLASTIC_COST = 25
local PATH_RECOMPUTE_SECONDS = 1
local PATH_RECOMPUTE_MOVE_STUDS = 4
local PATH_FAILURE_BACKOFF_MAX = 8
local PATH_STARTS_PER_FRAME = 2
local PATH_MAX_IN_FLIGHT = 6
-- Mob.blink caps a leg at this many points; a longer path is re-planned
-- when the mob reaches the end of the part it was sent.
local MAX_LEG_POINTS = 24

-- A proxy root moves (and replicates) only when it is this far off, or
-- turned this much.
local WRITE_EPSILON_STUDS = 0.05
local WRITE_EPSILON_YAW = math.rad(1)

-- Rig parts the proxy keeps, by name. Everything else in the template is
-- the clients' to draw.
local PROXY_PART_NAMES = { "HumanoidRootPart", "Torso", "Head", "RaycastHitbox", "MobHitbox" }
-- Parts that are not the body (excluded from the root offset and Hurtbox).
local NON_BODY_PART_NAMES = { HumanoidRootPart = true, RaycastHitbox = true, MobHitbox = true }
local HURTBOX_NAME = "Hurtbox"

local MAX_SIM_ID = 65535

local STATE_ROAMING = "roaming"
local STATE_CHASE = "chase"
local STATE_ATTACKING = "attacking"
local STATE_DEAD = "dead"

--[ Types ]--

-- What a template resolves to once: where its root sits over the floor, the
-- body box the Hurtbox copies, and its path under GameAssets.Mobs.
type TemplateInfo = {
	rootOffset: number,
	-- Half the body's widest horizontal extent: the clearance a leg keeps.
	bodyRadius: number,
	hurtboxSize: Vector3,
	hurtboxOffset: CFrame,
	templatePath: string,
}

type Record = {
	id: number,
	model: Model,
	root: BasePart,
	humanoid: Humanoid,
	data: any,
	rootOffset: number,
	bodyRadius: number,
	attackPool: { any },
	-- Indices into attackPool a chase may pick at random (everything but
	-- the close-range attacks), and the close-range ones (MobData
	-- `closeRange`), which take over whenever the target is that near.
	randomAttackIndices: { number },
	closeAttackIndices: { number },
	detectionRange: number,
	walkSpeed: number,
	approachAngle: number,

	state: string,
	alive: boolean,
	stateEndTime: number,
	-- When the current attack began (server time): MobData attackInterval
	-- rests the mob for what the attack did not use of its roll.
	attackStartedAt: number?,
	nextThink: number,
	attackGeneration: number,
	chosenAttack: any,
	chosenAttackIndex: number,

	-- Movement
	move: mobPath.Move,
	moveKind: string,
	baseSpeed: number,
	ground: Vector3,
	yaw: number,
	written: CFrame,
	chaseGoal: Vector3?,
	-- Where the target stood when the current chase leg was aimed.
	chaseTargetAt: Vector3?,
	-- No straight-leg walkability check before this (a failed one backs off).
	walkCheckAt: number,
	-- No stuck-in-geometry check before this (see UNSTICK_CHECK_SECONDS).
	unstickCheckAt: number,
	-- Knockback queued this frame (summed, flat) and the hold it earns;
	-- the mob makes no decisions before staggerUntil (ApplyKnockback).
	pushPending: Vector3,
	staggerPending: number,
	staggerUntil: number,
	-- Support mobs: this cast cycle's pick, "heal" or "player", rolled
	-- once (support.attackPlayerChance) and cleared after each cast.
	supportIntent: string?,

	-- Targeting
	target: Model?,
	targetRoot: BasePart?,
	nearestPlayerDistance: number,

	-- Pathfinding
	path: Path?,
	pathPending: boolean,
	lastPathAt: number,
	pathFailures: number,
	pathGoal: Vector3?,

	assists: { [string]: number },
	connections: { RBXScriptConnection },
}

--[ Service ]--

local MobSimService = {
	Name = "MobSimService",
	Dependencies = { MobService, MobSpawnService, EnemyScalingService } :: { any },

	_records = {} :: { [number]: Record },
	_byModel = {} :: { [Model]: Record },
	_count = 0,
	_nextId = 1,
	_templateInfo = {} :: { [Model]: TemplateInfo },
	_pathQueue = {} :: { Record },
	_pathsInFlight = 0,
	_heartbeat = nil :: RBXScriptConnection?,
}

--[ Shared caches ]--

-- One RaycastParams for every line-of-sight and roam ray (MobBase's list).
local losParams: RaycastParams? = nil

local function getLOSParams(): RaycastParams
	if losParams then
		return losParams
	end
	local ignore = workspace.IgnoreInstances
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {
		ignore.Mobs,
		ignore.DeadMobs,
		workspace.PlayerBaseplates,
		workspace.Terrain,
		ignore.Boundaries,
		ignore.ActBarriers,
		ignore.CameraPoints,
		ignore.ArcaneSpells,
		ignore.MapMarkers,
		ignore.Regions,
		ignore.Terrain,
	}
	losParams = params
	return params
end

-- What a straight leg must not pass through: the LOS list minus the
-- invisible walls (Boundaries, ActBarriers), which sight ignores but a
-- body never could. Player characters are allowed through (isCharacterPart).
local walkParams: RaycastParams? = nil

local function getWalkParams(): RaycastParams
	if walkParams then
		return walkParams
	end
	local ignore = workspace.IgnoreInstances
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {
		ignore.Mobs,
		ignore.DeadMobs,
		workspace.PlayerBaseplates,
		ignore.CameraPoints,
		ignore.ArcaneSpells,
		ignore.MapMarkers,
		ignore.Regions,
		ignore.Terrain,
	}
	-- Only what a body would actually bump into: dropped Gems and orbs,
	-- effects and trigger volumes are queryable but not collidable, and
	-- read as walls otherwise (a chaser refusing a free spot beside loot).
	params.RespectCanCollide = true
	walkParams = params
	return params
end

-- The same exclusions for the overlap test at a leg's end.
local walkOverlapParams: OverlapParams? = nil

local function getWalkOverlapParams(): OverlapParams
	if walkOverlapParams then
		return walkOverlapParams
	end
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = getWalkParams().FilterDescendantsInstances
	params.RespectCanCollide = true
	walkOverlapParams = params
	return params
end

-- What counts as floor: everything solid except mobs, effects, the
-- invisible walls (a probe must never land on a barrier's top) and the
-- living players' characters, which refreshAlivePlayers keeps in the
-- filter as they come and go.
local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Exclude
-- A floor is something you can stand on, not a pickup or a trigger volume.
groundParams.RespectCanCollide = true
local groundFilterCharacters: { Model } = {}

local function setGroundFilter(characters: { Model })
	local ignore = workspace.IgnoreInstances
	local filter: { Instance } = {
		ignore.Mobs,
		ignore.DeadMobs,
		ignore.Boundaries,
		ignore.ActBarriers,
		ignore.CameraPoints,
		ignore.ArcaneSpells,
		ignore.MapMarkers,
		ignore.Regions,
		ignore.Terrain,
	}
	for _, character in characters do
		table.insert(filter, character)
	end
	groundParams.FilterDescendantsInstances = filter
	groundFilterCharacters = characters
end

-- Living, targetable players, rebuilt at most once per frame for every mob.
type PlayerEntry = { character: Model, root: BasePart }
local alivePlayers: { PlayerEntry } = {}
local alivePlayersAt = -1

local function refreshAlivePlayers(now: number)
	if now == alivePlayersAt then
		return
	end
	alivePlayersAt = now
	table.clear(alivePlayers)
	-- Every character (alive or not) is kept out of the floor probes; the
	-- filter is only rebuilt when that set changes.
	local characters: { Model } = {}
	local charactersChanged = false
	-- Players parked under workspace.DesyncedPlayers haven't walked through
	-- the open Dungeon Gate yet; the wave ahead must not target them.
	local desyncedPlayers = workspace:FindFirstChild("DesyncedPlayers")
	for _, player in Players:GetPlayers() do
		local character = player.Character
		if not character then
			continue
		end
		table.insert(characters, character)
		if groundFilterCharacters[#characters] ~= character then
			charactersChanged = true
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
		local root = getRoot(character)
		if root then
			table.insert(alivePlayers, { character = character, root = root })
		end
	end
	if charactersChanged or #characters ~= #groundFilterCharacters then
		setGroundFilter(characters)
	end
end

local function isCharacterPart(instance: Instance): boolean
	for _, character in groundFilterCharacters do
		if instance:IsDescendantOf(character) then
			return true
		end
	end
	return false
end

-- The floor under `point` within `depth` studs, or nil.
local function floorBelow(point: Vector3, depth: number): Vector3?
	local hit = workspace:Raycast(point, Vector3.new(0, -depth, 0), groundParams)
	return if hit then hit.Position else nil
end

--[ Helpers ]--

local function flat(vector: Vector3): Vector3
	return Vector3.new(vector.X, 0, vector.Z)
end

-- Path of `template` under GameAssets.Mobs, "/"-separated, which is how
-- the renderer finds the same rig.
local function templatePathOf(template: Model): string
	local mobsFolder = ReplicatedStorage.GameAssets.Mobs
	local segments = {}
	local node: Instance? = template
	while node and node ~= mobsFolder do
		table.insert(segments, 1, node.Name)
		node = node.Parent
	end
	return table.concat(segments, "/")
end

-- The vertical half-extent of a (possibly rotated) part in world space.
local function halfHeight(part: BasePart): number
	local cframe, size = part.CFrame, part.Size
	return 0.5
		* (
			math.abs(cframe.RightVector.Y) * size.X
			+ math.abs(cframe.UpVector.Y) * size.Y
			+ math.abs(cframe.LookVector.Y) * size.Z
		)
end

function MobSimService._resolveTemplate(self: typeof(MobSimService), template: Model): TemplateInfo?
	local cached = self._templateInfo[template]
	if cached then
		return cached
	end
	local root = template:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		warn("[MobSimService] Template has no HumanoidRootPart: " .. template:GetFullName())
		return nil
	end

	local bottom = math.huge
	local boxMin = Vector3.one * math.huge
	local boxMax = -Vector3.one * math.huge
	for _, part in template:GetDescendants() do
		if not part:IsA("BasePart") or NON_BODY_PART_NAMES[part.Name] then
			continue
		end
		bottom = math.min(bottom, part.Position.Y - halfHeight(part))
		local half = part.Size / 2
		for _, corner in
			{
				Vector3.new(half.X, half.Y, half.Z),
				Vector3.new(-half.X, half.Y, half.Z),
				Vector3.new(half.X, -half.Y, half.Z),
				Vector3.new(half.X, half.Y, -half.Z),
				Vector3.new(-half.X, -half.Y, half.Z),
				Vector3.new(-half.X, half.Y, -half.Z),
				Vector3.new(half.X, -half.Y, -half.Z),
				Vector3.new(-half.X, -half.Y, -half.Z),
			}
		do
			local localCorner = root.CFrame:PointToObjectSpace(part.CFrame:PointToWorldSpace(corner))
			boxMin = boxMin:Min(localCorner)
			boxMax = boxMax:Max(localCorner)
		end
	end
	if bottom == math.huge then
		warn("[MobSimService] Template has no body parts: " .. template:GetFullName())
		return nil
	end

	local info: TemplateInfo = {
		rootOffset = root.Position.Y - bottom,
		hurtboxSize = boxMax - boxMin,
		hurtboxOffset = CFrame.new((boxMin + boxMax) / 2),
		bodyRadius = math.max(boxMax.X - boxMin.X, boxMax.Z - boxMin.Z) / 2,
		templatePath = templatePathOf(template),
	}
	self._templateInfo[template] = info
	return info
end

-- Builds the invisible proxy for `template`, standing at `rootCFrame`.
-- Returns the model, its root and its Humanoid, unparented.
local function buildProxy(template: Model, info: TemplateInfo, rootCFrame: CFrame): (Model, BasePart, Humanoid)
	local templateRoot = template:FindFirstChild("HumanoidRootPart") :: BasePart
	local proxy = Instance.new("Model")
	proxy.Name = template.Name
	proxy.ModelStreamingMode = Enum.ModelStreamingMode.Atomic

	local root: BasePart? = nil
	local function addPart(part: BasePart, offset: CFrame)
		for _, child in part:GetChildren() do
			if not child:IsA("Attachment") then
				child:Destroy()
			end
		end
		part.Transparency = 1
		part.CanCollide = false
		part.CanTouch = false
		part.CastShadow = false
		part.Massless = true
		part.CFrame = rootCFrame * offset
		if root then
			part.Anchored = false
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = root
			weld.Part1 = part
			weld.Parent = part
		else
			part.Anchored = true
			root = part
		end
		part.Parent = proxy
	end

	-- The root first, so every other part welds to it.
	for _, name in PROXY_PART_NAMES do
		local source = template:FindFirstChild(name)
		if source and source:IsA("BasePart") then
			addPart(source:Clone(), templateRoot.CFrame:ToObjectSpace(source.CFrame))
		end
	end

	-- One box over the whole body: the limbs the proxy drops are what a
	-- swing used to clip, so melee reach against a sim mob matches the rig.
	local hurtbox = Instance.new("Part")
	hurtbox.Name = HURTBOX_NAME
	hurtbox.Size = info.hurtboxSize
	local torso = template:FindFirstChild("Torso")
	if torso and torso:IsA("BasePart") then
		hurtbox.CollisionGroup = torso.CollisionGroup
	end
	addPart(hurtbox, info.hurtboxOffset)

	local humanoid = Instance.new("Humanoid")
	humanoid.EvaluateStateMachine = false
	humanoid.RequiresNeck = false
	humanoid.BreakJointsOnDeath = false
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	humanoid.Parent = proxy

	local proxyRoot = root :: BasePart
	proxy.PrimaryPart = proxyRoot

	for name, value in template:GetAttributes() do
		proxy:SetAttribute(name, value)
	end
	for _, tag in template:GetTags() do
		proxy:AddTag(tag)
	end
	proxy:AddTag(TagList.Zombie)

	return proxy, proxyRoot, humanoid
end

-- Walk speed after status: Jailed stops it, Slowed cuts it to 40%, and
-- the Chill multiplier (StatusConditionService) composes on top -- the
-- same pipe as MobBase._resyncWalkSpeed.
local function effectiveSpeed(record: Record): number
	local model = record.model
	if model:GetAttribute(Attributes.Jailed) then
		return 0
	end
	local slowAttribute = model:GetAttribute("StatusSlowMultiplier")
	local slow: number = if type(slowAttribute) == "number" then slowAttribute else 1
	if model:GetAttribute(Attributes.Slowed) then
		return (record.baseSpeed / 2.5) * slow
	end
	return record.baseSpeed * slow
end

local function rootPosition(record: Record): Vector3
	return record.ground + Vector3.new(0, record.rootOffset, 0)
end

local function hasLineOfSight(from: Vector3, targetRoot: BasePart): boolean
	local direction = targetRoot.Position - from
	if direction.Magnitude < 0.05 then
		return true
	end
	local hit = workspace:Raycast(from, direction, getLOSParams())
	return hit == nil or hit.Instance:IsDescendantOf(targetRoot.Parent :: Instance)
end

-- The body sphere every walk and fit check uses: the body radius, kept
-- WALK_PROBE_FLOOR_GAP off the floor so the ground never reads as a wall.
local function probeRadius(rootOffset: number, bodyRadius: number): number
	return math.clamp(
		bodyRadius,
		WALK_PROBE_RADIUS_MIN,
		math.max(rootOffset - WALK_PROBE_FLOOR_GAP, WALK_PROBE_RADIUS_MIN)
	)
end

-- Does a body of this size fit standing on `ground` (nothing solid inside
-- its sphere; players do not count)?
local function bodyFitsAt(rootOffset: number, bodyRadius: number, ground: Vector3): boolean
	local center = ground + Vector3.new(0, rootOffset, 0)
	local radius = probeRadius(rootOffset, bodyRadius)
	for _, part in workspace:GetPartBoundsInRadius(center, radius, getWalkOverlapParams()) do
		if not isCharacterPart(part) then
			return false
		end
	end
	return true
end

-- The nearest spot to `ground` (itself first) where the body fits, on a
-- floor, and `crowded` (when given) does not object; nil if none within
-- the last ring. See CLEAR_SEARCH_RINGS.
local function findClearGround(
	rootOffset: number,
	bodyRadius: number,
	ground: Vector3,
	crowded: ((Vector3) -> boolean)?
): Vector3?
	if bodyFitsAt(rootOffset, bodyRadius, ground) and not (crowded and crowded(ground)) then
		return ground
	end
	local lift = Vector3.new(0, rootOffset, 0)
	for _, ring in CLEAR_SEARCH_RINGS do
		for step = 0, CLEAR_SEARCH_DIRECTIONS - 1 do
			local angle = step * (2 * math.pi / CLEAR_SEARCH_DIRECTIONS)
			local probe = ground + lift + Vector3.new(math.cos(angle) * ring, 0, math.sin(angle) * ring)
			local floor = floorBelow(probe, rootOffset + WALK_STEP_STUDS)
			if floor and bodyFitsAt(rootOffset, bodyRadius, floor) and not (crowded and crowded(floor)) then
				return floor
			end
		end
	end
	return nil
end

-- Can the mob walk a straight leg from `fromGround` to `toGround` (both
-- ground points)? See the WALK_* constants.
local function canWalkStraight(record: Record, fromGround: Vector3, toGround: Vector3): boolean
	local lift = Vector3.new(0, record.rootOffset, 0)
	local delta = toGround - fromGround
	local flatLength = flat(delta).Magnitude
	if flatLength < 0.05 then
		return true
	end

	local radius = probeRadius(record.rootOffset, record.bodyRadius)
	local hit = workspace:Spherecast(fromGround + lift, radius, delta, getWalkParams())
	if hit and not isCharacterPart(hit.Instance) then
		return false
	end
	-- The body must FIT where the leg ends: a sweep stops at the goal, so a
	-- goal hugging a wall would otherwise park the mob half inside it.
	if not bodyFitsAt(record.rootOffset, record.bodyRadius, toGround) then
		return false
	end
	-- And back from the goal: a cast ignores any part it STARTS inside, so
	-- a mob already pressed into a wall would pass the forward check and
	-- walk out through it. From the far side the wall's face is hit.
	local back = workspace:Raycast(toGround + lift, -delta, getWalkParams())
	if back and not isCharacterPart(back.Instance) then
		return false
	end

	local samples = math.clamp(math.ceil(flatLength / WALK_FLOOR_SAMPLE_STUDS), 1, WALK_FLOOR_SAMPLES_MAX)
	local probeLift = Vector3.new(0, WALK_STEP_STUDS, 0)
	for index = 1, samples do
		local expected = fromGround:Lerp(toGround, index / samples)
		if not floorBelow(expected + probeLift, WALK_STEP_STUDS * 2) then
			return false
		end
	end
	return true
end

--[ Movement ]--

-- Starts a new leg from where the mob is now and tells every client.
function MobSimService._issueMove(
	_self: typeof(MobSimService),
	record: Record,
	now: number,
	points: { Vector3 },
	kind: string
)
	if #points > MAX_LEG_POINTS then
		points = table.move(points, 1, MAX_LEG_POINTS, 1, table.create(MAX_LEG_POINTS))
	end
	local speed = effectiveSpeed(record)
	record.move = mobPath.new(now, speed, record.ground, points, record.yaw)
	record.moveKind = kind
	MobNetwork.MobMove.FireAll({
		Id = record.id,
		StartTime = now,
		Speed = speed,
		Start = record.ground,
		Points = points,
		Yaw = record.yaw,
	})
end

function MobSimService._stop(self: typeof(MobSimService), record: Record, now: number)
	self:_issueMove(record, now, {}, "stop")
end

-- The points of the current leg still ahead of the mob.
local function remainingPoints(move: mobPath.Move): { Vector3 }
	local remaining = {}
	for index = move.hint, #move.points do
		table.insert(remaining, move.points[index])
	end
	return remaining
end

--[ Pathfinding ]--

function MobSimService._requestPath(self: typeof(MobSimService), record: Record, now: number, goal: Vector3)
	if record.pathPending then
		return
	end
	local backoff = math.min(PATH_RECOMPUTE_SECONDS * 2 ^ record.pathFailures, PATH_FAILURE_BACKOFF_MAX)
	if now - record.lastPathAt < backoff then
		return
	end
	-- Still walking a path to (roughly) where the target still is: keep it.
	local _, _, moving = mobPath.sample(record.move, now)
	if
		moving
		and record.moveKind == "path"
		and record.pathGoal
		and (goal - record.pathGoal).Magnitude <= PATH_RECOMPUTE_MOVE_STUDS
	then
		return
	end
	record.pathPending = true
	record.lastPathAt = now
	record.pathGoal = goal
	table.insert(self._pathQueue, record)
end

function MobSimService._computePath(self: typeof(MobSimService), record: Record)
	self._pathsInFlight += 1
	local path = record.path
	if not path then
		path = PathfindingService:CreatePath({
			-- Never narrower than the body, or a path would hug walls the
			-- body then clips into.
			AgentRadius = math.max(record.data.agentRadius or 2, record.bodyRadius),
			AgentHeight = 5,
			AgentCanJump = false,
			WaypointSpacing = PATH_WAYPOINT_SPACING,
			Costs = {
				SmoothPlastic = 1,
				Plastic = PATH_PLASTIC_COST,
			},
		})
		record.path = path
	end
	local goal = record.pathGoal :: Vector3
	local from = rootPosition(record)
	local ok = pcall(function()
		(path :: Path):ComputeAsync(from, goal)
	end)
	self._pathsInFlight -= 1
	record.pathPending = false

	-- The mob may have died, started an attack or lost its target while the
	-- compute yielded.
	if not record.alive or record.state ~= STATE_CHASE then
		return
	end
	local now = workspace:GetServerTimeNow()
	record.ground = (mobPath.sample(record.move, now))

	if ok and (path :: Path).Status == Enum.PathStatus.Success then
		local points = {}
		for index, waypoint in (path :: Path):GetWaypoints() do
			-- Waypoint 1 is where the mob already stands.
			if index > 1 then
				table.insert(points, waypoint.Position)
			end
		end
		if #points > 0 then
			record.pathFailures = 0
			self:_issueMove(record, now, points, "path")
			return
		end
	end

	-- No path (the navmesh does not reach, a prop walls the goal off): back
	-- off before asking the pathfinder again, and meanwhile walk straight
	-- at the target only if that leg is genuinely walkable. MobBase walked
	-- straight regardless and let the Humanoid bump into the wall; with no
	-- body to stop it, a sim mob would walk through, so it holds instead.
	record.pathFailures += 1
	local floor = floorBelow(goal, PLAYER_ROOT_HEIGHT + GOAL_FLOOR_SEARCH_STUDS)
	if floor and canWalkStraight(record, record.ground, floor) then
		record.chaseGoal = floor
		record.chaseTargetAt = goal
		self:_issueMove(record, now, { floor }, "direct")
	else
		self:_stop(record, now)
	end
end

function MobSimService._pumpPathQueue(self: typeof(MobSimService))
	local started = 0
	while #self._pathQueue > 0 and started < PATH_STARTS_PER_FRAME and self._pathsInFlight < PATH_MAX_IN_FLIGHT do
		local record = table.remove(self._pathQueue, 1) :: Record
		if record.alive and record.state == STATE_CHASE then
			started += 1
			task.spawn(self._computePath, self, record)
		else
			record.pathPending = false
		end
	end
end

--[ States ]--

-- `afterAttack`: the roam that follows an attack. A mob with a MobData
-- `attackInterval` (hit to hit, 2026-10-30) rests only what is left of a
-- roll in that range once the attack's own time is taken off; everything
-- else roams ROAM_DURATION_MIN-MAX.
function MobSimService._enterRoaming(self: typeof(MobSimService), record: Record, now: number, afterAttack: boolean?)
	record.state = STATE_ROAMING
	record.chosenAttack = nil
	record.chaseGoal = nil
	record.baseSpeed = record.walkSpeed / 2
	local interval = record.data and record.data.attackInterval
	if afterAttack and interval and record.attackStartedAt then
		local roll = interval[1] + math.random() * (interval[2] - interval[1])
		record.stateEndTime = now + math.max(roll - (now - record.attackStartedAt), 0)
	else
		record.stateEndTime = now + math.random(ROAM_DURATION_MIN, ROAM_DURATION_MAX)
	end

	local origin = rootPosition(record)
	for attempt = 1, ROAM_PICK_ATTEMPTS do
		local angle = math.random() * math.pi * 2
		local distance = if attempt <= ROAM_PICK_ATTEMPTS / 2
			then math.random(ROAM_RADIUS_MIN, ROAM_RADIUS_MAX)
			else math.random(ROAM_SHORT_RADIUS_MIN, ROAM_SHORT_RADIUS_MAX)
		local candidate = origin + Vector3.new(math.cos(angle) * distance, 0, math.sin(angle) * distance)
		local floor = floorBelow(candidate, record.rootOffset + ROAM_FLOOR_SLOP_STUDS)
		if floor and canWalkStraight(record, record.ground, floor) then
			self:_issueMove(record, now, { floor }, "roam")
			return
		end
	end
	self:_stop(record, now)
end

function MobSimService._enterChase(_self: typeof(MobSimService), record: Record)
	record.state = STATE_CHASE
	record.baseSpeed = record.walkSpeed
	record.chaseGoal = nil
	record.pathFailures = 0
	record.lastPathAt = 0
	local candidates = record.randomAttackIndices
	if #candidates > 0 then
		record.chosenAttackIndex = candidates[math.random(1, #candidates)]
		record.chosenAttack = record.attackPool[record.chosenAttackIndex]
	end
end

function MobSimService._chaseStep(self: typeof(MobSimService), record: Record, now: number)
	-- Jailed: no attack, no movement (MobBase._chaseStep's first gate).
	if record.model:GetAttribute(Attributes.Jailed) then
		return
	end
	local targetRoot = record.targetRoot :: BasePart
	local from = rootPosition(record)
	local targetPosition = targetRoot.Position

	-- ONE line-of-sight ray per think, shared by the attack gate and the
	-- movement choice below.
	local lineOfSight: boolean? = nil
	local function sight(): boolean
		if lineOfSight == nil then
			lineOfSight = hasLineOfSight(from, targetRoot)
		end
		return lineOfSight :: boolean
	end

	-- A close-range attack (the Wizard's slash) takes over from the chase's
	-- pick whenever the target is inside its closeRange.
	local targetDistance = (from - targetPosition).Magnitude
	local overridden = false
	for _, index in record.closeAttackIndices do
		local closeAttack = record.attackPool[index]
		if targetDistance <= closeAttack.closeRange then
			record.chosenAttack = closeAttack
			record.chosenAttackIndex = index
			overridden = true
			break
		end
	end
	-- The target backed out of every close range: hand the chase back to a
	-- random pick (the Wizard goes back to casting, not chasing to melee).
	local current = record.chosenAttack
	if not overridden and current and current.closeRange and #record.randomAttackIndices > 0 then
		record.chosenAttackIndex = record.randomAttackIndices[math.random(1, #record.randomAttackIndices)]
		record.chosenAttack = record.attackPool[record.chosenAttackIndex]
	end

	local attack = record.chosenAttack
	if attack and targetDistance <= attack.attackRange then
		if not attack.requiresLineOfSight or sight() then
			self:_startAttack(record, now)
			return
		end
	end

	if sight() then
		-- Where this mob would stand: beside the target at its own approach
		-- angle, at the target's FLOOR height (a jumping player must not
		-- lift the leg). Compared flat, so a jump does not re-aim either.
		local reach = if attack then attack.attackRange else CHASE_STOP_MAX_STUDS
		local stopDistance = math.clamp(reach * CHASE_STOP_RANGE_FRACTION, CHASE_STOP_MIN_STUDS, CHASE_STOP_MAX_STUDS)
		local away = flat(from - targetPosition)
		away = if away.Magnitude > 0.05 then away.Unit else Vector3.xAxis

		local _, _, moving = mobPath.sample(record.move, now)
		local chaseGoal = record.chaseGoal
		-- Standing on the goal already (the target is above or below the
		-- attack's reach): no zero-length leg every think.
		local arrived = not moving
			and chaseGoal ~= nil
			and flat(chaseGoal - record.ground).Magnitude < CHASE_REGOAL_STUDS
		local regoal = math.max(CHASE_REGOAL_STUDS, (from - targetPosition).Magnitude * CHASE_REGOAL_DISTANCE_FRACTION)
		-- Standing but out of reach: the target drifted a little since this
		-- leg was aimed (under the re-aim distance), which used to leave the
		-- mob waiting beside it until the player moved further. Re-aim now.
		local outOfReach = not moving and targetDistance > reach
		local needsLeg = record.moveKind ~= "direct"
			or (not moving and not arrived)
			or outOfReach
			or chaseGoal == nil
			or record.chaseTargetAt == nil
			or flat(targetPosition - (record.chaseTargetAt :: Vector3)).Magnitude > regoal
		if not needsLeg then
			return
		end

		if now >= record.walkCheckAt then
			local goal = self:_pickChaseGoal(record, targetPosition, away, stopDistance)
			-- A goal the mob already stands on is no leg at all (the target
			-- is straight above or below): nothing to send.
			if goal and flat(goal - record.ground).Magnitude < CHASE_SAME_SPOT_STUDS then
				return
			end
			if goal and canWalkStraight(record, record.ground, goal) then
				record.chaseGoal = goal
				record.chaseTargetAt = targetPosition
				self:_issueMove(record, now, { goal }, "direct")
				return
			end
			record.walkCheckAt = now + WALK_RECHECK_SECONDS
		end
		-- Seen but not walkable straight (a railing, a gap, a low wall):
		-- path around it below.
	end

	record.chaseGoal = nil
	record.chaseTargetAt = nil
	self:_requestPath(record, now, targetPosition)
end

-- The floor point this mob should stand on beside the target: its own
-- approach angle first, then swung CHASE_SEPARATION_STEP either way (twice)
-- while another sim mob already aims within CHASE_SEPARATION_STUDS of it,
-- so a pack spreads round the player instead of stacking on one spot.
-- nil when there is no floor there.
function MobSimService._pickChaseGoal(
	self: typeof(MobSimService),
	record: Record,
	targetPosition: Vector3,
	away: Vector3,
	stopDistance: number
): Vector3?
	local depth = PLAYER_ROOT_HEIGHT + GOAL_FLOOR_SEARCH_STUDS
	local fallback: Vector3? = nil
	for _, swing in { 0, 1, -1, 2, -2 } do
		local angle = record.approachAngle + swing * CHASE_SEPARATION_STEP
		local point = targetPosition + CFrame.Angles(0, angle, 0):VectorToWorldSpace(away) * stopDistance
		local floor = floorBelow(point, depth)
		if not floor then
			continue
		end
		fallback = fallback or floor
		local crowded = false
		for _, other in self._records do
			local otherGoal = other.chaseGoal
			if other ~= record and otherGoal and flat(otherGoal - floor).Magnitude < CHASE_SEPARATION_STUDS then
				crowded = true
				break
			end
		end
		if not crowded then
			return floor
		end
	end
	return fallback
end

--[ Attacks ]--

function MobSimService._setAttacking(_self: typeof(MobSimService), record: Record, attacking: boolean)
	local model = record.model
	if attacking then
		model:SetAttribute("AttackInterrupted", false)
	end
	model:SetAttribute(Attributes.MobIsAttacking, attacking)
	model:SetAttribute(Attributes.SuperArmor, attacking)
	model:SetAttribute("MobHighlightAttackActive", attacking)
end

-- Turns the standing mob to its target and pins it there: a stop leg with
-- the new facing for the clients, and the proxy written at once, because
-- the swing's hitbox and the ranged shot read the root's facing.
function MobSimService._faceTarget(self: typeof(MobSimService), record: Record, now: number)
	local targetRoot = record.targetRoot
	if targetRoot and targetRoot.Parent then
		local facing = mobPath.yawFromDirection(targetRoot.Position - rootPosition(record))
		if facing then
			record.yaw = facing
		end
	end
	self:_stop(record, now)
	local cframe = mobPath.rootCFrame(record.ground, record.yaw, record.rootOffset)
	record.root.CFrame = cframe
	record.written = cframe
end

-- One generic attack: face the target, stand still, wind up, strike
-- (MobService's shared melee hitbox, or the ranged cast), recover, roam.
-- Runs in its own thread; the think loop leaves an attacking mob alone.
function MobSimService._startAttack(self: typeof(MobSimService), record: Record, now: number)
	local attack = record.chosenAttack
	local targetRoot = record.targetRoot
	if not attack or not targetRoot then
		return
	end
	record.state = STATE_ATTACKING
	record.attackGeneration += 1
	record.attackStartedAt = workspace:GetServerTimeNow()
	local generation = record.attackGeneration
	local attackIndex = record.chosenAttackIndex

	-- Aim BEFORE the wind-up: the swing's hitbox and the ranged shot both
	-- read the root's facing (MobData hitboxCFrame / muzzleOffset).
	record.ground = (mobPath.sample(record.move, now))
	self:_faceTarget(record, now)

	self:_setAttacking(record, true)
	MobNetwork.MobAction.FireAll({
		Id = record.id,
		Kind = "Attack",
		AttackIndex = attackIndex,
	})

	task.spawn(function()
		if attack.kind == "ranged" then
			task.wait(attack.windUpDuration)
			local target = record.target
			local liveRoot = record.targetRoot
			if
				record.alive
				and record.attackGeneration == generation
				and target
				and liveRoot
				and liveRoot.Parent
				and not record.model:GetAttribute(Attributes.Jailed)
				and (not attack.requiresLineOfSight or hasLineOfSight(rootPosition(record), liveRoot))
			then
				local player = Players:GetPlayerFromCharacter(target)
				if player then
					MobService:FireMobRangedAttack(record.model, player, attack)
				end
			end
		else
			-- `strikes` swings in one attack (PotHead's double slash): each
			-- follow-up re-aims from where the last lunge left the mob, plays
			-- the swing again and runs its own telegraph + hit frame.
			local strikes = math.max(attack.strikes or 1, 1)
			for strike = 1, strikes do
				if strike > 1 then
					if
						not record.alive
						or record.attackGeneration ~= generation
						or record.model:GetAttribute(Attributes.Jailed)
					then
						break
					end
					record.ground = record.root.Position - Vector3.new(0, record.rootOffset, 0)
					self:_faceTarget(record, workspace:GetServerTimeNow())
					MobNetwork.MobAction.FireAll({
						Id = record.id,
						Kind = "Attack",
						AttackIndex = attackIndex,
					})
				end
				MobService:ExecuteMobAttack(
					record.model,
					attack,
					if strike > 1 then attack.followUpWindUpDuration else nil
				)
			end
		end

		if not record.alive or record.attackGeneration ~= generation then
			return
		end
		record.model:SetAttribute("MobHighlightAttackActive", false)
		task.wait(attack.recoveryDuration or 0)
		if not record.alive or record.attackGeneration ~= generation then
			return
		end
		self:_setAttacking(record, false)

		-- A lunge moved the proxy (MobService PivotTo); pick up from there.
		local resumeAt = workspace:GetServerTimeNow()
		record.ground = record.root.Position - Vector3.new(0, record.rootOffset, 0)
		record.written = record.root.CFrame
		self:_enterRoaming(record, resumeAt, true)
	end)
end

--[ Knockback ]--

-- Moves a mob by its queued push (see ApplyKnockback): the summed push,
-- or half of it, whichever the walk checks allow; nothing if neither.
function MobSimService._resolveKnockback(self: typeof(MobSimService), record: Record, now: number)
	local push = record.pushPending
	local stagger = record.staggerPending
	record.pushPending = Vector3.zero
	record.staggerPending = 0
	if not record.alive then
		return
	end

	local attacking = record.state == STATE_ATTACKING
	-- Mid-attack the proxy holds where the attack put it; otherwise the
	-- leg says where the mob is right now.
	local from = if attacking
		then record.root.Position - Vector3.new(0, record.rootOffset, 0)
		else (mobPath.sample(record.move, now))
	local lift = Vector3.new(0, record.rootOffset, 0)
	local landing: Vector3? = nil
	for _, scale in { 1, 0.5 } do
		local floor = floorBelow(
			from + push * scale + lift + Vector3.new(0, WALK_STEP_STUDS, 0),
			record.rootOffset + WALK_STEP_STUDS * 2
		)
		if floor and canWalkStraight(record, from, floor) then
			landing = floor
			break
		end
	end
	if not landing then
		return
	end

	record.ground = landing
	if attacking then
		-- The attack thread reads the proxy root when it resumes, and the
		-- step loop leaves an attacking mob's proxy alone: write it now.
		local cframe = mobPath.rootCFrame(landing, record.yaw, record.rootOffset)
		record.root.CFrame = cframe
		record.written = cframe
		self:_issueMove(record, now, {}, record.moveKind)
		return
	end

	-- Carry on with the same leg from the pushed spot, starting once the
	-- stagger is over; a chase re-aims on its first think after that.
	local resumeAt = now + stagger
	record.staggerUntil = resumeAt
	self:_issueMove(record, resumeAt, remainingPoints(record.move), record.moveKind)
end

--[ Support (the Healer) ]--

-- Every living mob model under the Mobs folder (sim proxies and MobBase
-- rigs alike), with its humanoid and root.
local function livingMobs(): { { model: Model, humanoid: Humanoid, root: BasePart } }
	local result = {}
	local folder = workspace.IgnoreInstances:FindFirstChild("Mobs")
	if not folder then
		return result
	end
	for _, model in folder:GetChildren() do
		if not model:IsA("Model") then
			continue
		end
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		local root = model:FindFirstChild("HumanoidRootPart")
		if humanoid and root and root:IsA("BasePart") and humanoid.Health > 0 then
			table.insert(result, { model = model, humanoid = humanoid, root = root })
		end
	end
	return result
end

-- The heal attack in a support mob's pool, and its index (the client
-- plays that index's animation).
local function healAttackOf(record: Record): (any, number)
	for index, attack in record.attackPool do
		if attack.kind == "heal" then
			return attack, index
		end
	end
	return nil, 0
end

-- Where to drop the heal square: centred on the hurt ally (under
-- hurtBelow of its max health, within SUPPORT_HEAL_SEARCH_STUDS of the
-- caster) whose square would cover the most hurt
-- allies; ties go to the most hurt. Its floor point and the hurt allies
-- that square covers (healed even if they step out during the wind-up),
-- or nil when nobody needs healing. Out of the heal's own range is the
-- caller's business (walk there first).
-- A sim ally is placed where its leg puts it when the square LANDS (a
-- chasing Walker crosses a 10-stud square during the wind-up).
-- The caster never aims at ITSELF while any other mob is that near
-- (hurt or not): only a Healer left on its own heals itself on purpose.
-- It still heals when it happens to stand in an ally's square.
local function pickHealCenter(
	record: Record,
	heal: any,
	records: { [Model]: Record },
	now: number
): (Vector3?, { Model })
	local from = rootPosition(record)
	local landsAt = now + (heal.windUpDuration or 0)
	local mobs = livingMobs()
	local alone = true
	for _, mob in mobs do
		if mob.model ~= record.model and flat(mob.root.Position - from).Magnitude <= SUPPORT_HEAL_SEARCH_STUDS then
			alone = false
			break
		end
	end
	local hurt = {}
	for _, mob in mobs do
		if mob.model == record.model and not alone then
			continue
		end
		local humanoid = mob.humanoid
		if mob.model:GetAttribute(Attributes.Invulnerable) == true then
			continue
		end
		local fraction = humanoid.Health / math.max(humanoid.MaxHealth, 1)
		if fraction >= heal.hurtBelow then
			continue
		end
		local position = mob.root.Position
		local ally = records[mob.model]
		if ally and ally.state ~= STATE_ATTACKING then
			position = (mobPath.sample(ally.move, landsAt)) + Vector3.new(0, ally.rootOffset, 0)
		end
		if flat(position - from).Magnitude <= SUPPORT_HEAL_SEARCH_STUDS then
			table.insert(hurt, { model = mob.model, position = position, fraction = fraction })
		end
	end
	if #hurt == 0 then
		return nil, {}
	end
	local halfX, halfZ = heal.hitbox.size.X / 2, heal.hitbox.size.Z / 2
	local best, bestCount, bestFraction = nil, 0, math.huge
	for _, candidate in hurt do
		local count = 0
		for _, other in hurt do
			local offset = other.position - candidate.position
			if math.abs(offset.X) <= halfX and math.abs(offset.Z) <= halfZ then
				count += 1
			end
		end
		if count > bestCount or (count == bestCount and candidate.fraction < bestFraction) then
			best, bestCount, bestFraction = candidate, count, candidate.fraction
		end
	end
	local position = (best :: any).position
	local covered = {}
	for _, other in hurt do
		local offset = other.position - position
		if math.abs(offset.X) <= halfX and math.abs(offset.Z) <= halfZ then
			table.insert(covered, other.model)
		end
	end
	return floorBelow(position, SPAWN_FLOOR_SEARCH_STUDS) or position, covered
end

-- Where a support mob walks: SUPPORT_STANDOFF_STUDS short of `anchor`
-- (the spot it wants to drop its square on but cannot reach yet), on
-- its own side. nil when no floor is found there.
function MobSimService._supportGoal(_self: typeof(MobSimService), record: Record, heal: any, anchor: Vector3): Vector3?
	local from = rootPosition(record)
	local standoff = math.min(SUPPORT_STANDOFF_STUDS, heal.attackRange)
	local side = flat(from - anchor)
	side = if side.Magnitude > 0.05 then side.Unit else Vector3.xAxis
	local lift = Vector3.new(0, record.rootOffset + WALK_STEP_STUDS, 0)
	local depth = record.rootOffset + WALK_STEP_STUDS * 3
	return floorBelow(anchor + side * standoff + lift, depth) or floorBelow(anchor + lift, depth)
end

-- A support mob's chase-state think, the Wizard's loop. Each cast cycle
-- it rolls ONE intent (supportIntent): "player" at
-- support.attackPlayerChance, otherwise "heal". Heal: a hurt ally in
-- the heal's range gets the square, one further out is walked toward.
-- Player, or a heal with NOBODY to heal (every ally above hurtBelow, or
-- it is the last mob and unhurt): the square drops on the player it is
-- chasing. Rolled once per cycle so it never flips mid-walk; cleared
-- after each cast, then it roams 2-4 s.
function MobSimService._supportStep(self: typeof(MobSimService), record: Record, now: number)
	if record.model:GetAttribute(Attributes.Jailed) then
		return
	end

	local heal, healIndex = healAttackOf(record)
	if not heal then
		return
	end
	if record.supportIntent == nil then
		local chance = record.data.support.attackPlayerChance or 0
		record.supportIntent = if math.random() < chance then "player" else "heal"
	end
	local center: Vector3?, covered: { Model } = nil, {}
	if record.supportIntent == "heal" then
		center, covered = pickHealCenter(record, heal, self._byModel, now)
	end
	if not center then
		local targetRoot = record.targetRoot
		if not targetRoot then
			self:_enterRoaming(record, now)
			return
		end
		center = floorBelow(targetRoot.Position, SPAWN_FLOOR_SEARCH_STUDS) or targetRoot.Position
	end
	local aimAt = center :: Vector3
	if flat(aimAt - rootPosition(record)).Magnitude <= heal.attackRange then
		record.chosenAttack = heal
		record.chosenAttackIndex = healIndex
		self:_startHeal(record, now, aimAt, covered)
		return
	end

	local goal = self:_supportGoal(record, heal, aimAt)
	if not goal then
		self:_enterRoaming(record, now)
		return
	end
	-- Already there, or already walking (straight or by path) to about
	-- this spot: nothing new to send. A goal it never managed to set off
	-- for (a refused walk, a failed path) is tried again.
	if flat(goal - record.ground).Magnitude < SUPPORT_ARRIVE_STUDS then
		record.chaseGoal = goal
		return
	end
	local _, _, moving = mobPath.sample(record.move, now)
	local current = record.chaseGoal
	if current and moving and flat(goal - current).Magnitude < SUPPORT_REGOAL_STUDS then
		return
	end
	record.chaseGoal = goal
	if now >= record.walkCheckAt then
		if canWalkStraight(record, record.ground, goal) then
			self:_issueMove(record, now, { goal }, "direct")
			return
		end
		record.walkCheckAt = now + WALK_RECHECK_SECONDS
	end
	self:_requestPath(record, now, goal)
end

-- The heal cast: face the square, stand, telegraph, then hurt and heal
-- (MobService.CastHealZone), recover, then roam 2-4 s like the Wizard
-- after a cast: that roam IS the gap between heals.
function MobSimService._startHeal(
	self: typeof(MobSimService),
	record: Record,
	now: number,
	center: Vector3,
	covered: { Model }
)
	local attack = record.chosenAttack
	record.state = STATE_ATTACKING
	record.attackGeneration += 1
	record.attackStartedAt = workspace:GetServerTimeNow()
	local generation = record.attackGeneration

	record.ground = (mobPath.sample(record.move, now))
	local facing = mobPath.yawFromDirection(center - rootPosition(record))
	if facing then
		record.yaw = facing
	end
	self:_stop(record, now)
	local cframe = mobPath.rootCFrame(record.ground, record.yaw, record.rootOffset)
	record.root.CFrame = cframe
	record.written = cframe

	self:_setAttacking(record, true)
	MobNetwork.MobAction.FireAll({
		Id = record.id,
		Kind = "Attack",
		AttackIndex = record.chosenAttackIndex,
	})

	task.spawn(function()
		MobService:CastHealZone(record.model, attack, CFrame.new(center), covered)
		if not record.alive or record.attackGeneration ~= generation then
			return
		end
		record.model:SetAttribute("MobHighlightAttackActive", false)
		task.wait(attack.recoveryDuration or 0)
		if not record.alive or record.attackGeneration ~= generation then
			return
		end
		self:_setAttacking(record, false)
		record.ground = record.root.Position - Vector3.new(0, record.rootOffset, 0)
		record.written = record.root.CFrame
		record.supportIntent = nil
		self:_enterRoaming(record, workspace:GetServerTimeNow(), true)
	end)
end

--[ Think ]--

function MobSimService._findTarget(_self: typeof(MobSimService), record: Record)
	local from = rootPosition(record)
	local nearest, nearestRoot, nearestDistance = nil, nil, math.huge
	for _, entry in alivePlayers do
		local distance = (entry.root.Position - from).Magnitude
		if distance < nearestDistance then
			nearest, nearestRoot, nearestDistance = entry.character, entry.root, distance
		end
	end
	record.nearestPlayerDistance = nearestDistance
	if nearestDistance < record.detectionRange then
		record.target, record.targetRoot = nearest, nearestRoot
	else
		record.target, record.targetRoot = nil, nil
	end
end

function MobSimService._think(self: typeof(MobSimService), record: Record, now: number)
	if record.state == STATE_ATTACKING then
		return
	end

	local ground, yaw, moving = mobPath.sample(record.move, now)
	record.ground, record.yaw = ground, yaw

	-- Knocked back: hold the pushed spot until the stagger ends (the leg
	-- already starts then).
	if now < record.staggerUntil then
		return
	end

	-- Chill / Jail landed or wore off mid-leg: re-send the rest of the leg
	-- at the new speed. A leg frozen at speed 0 (jailed) still has every
	-- point ahead of it, so it resumes the same way.
	local move = record.move
	local frozen = move.speed == 0 and #move.points > 0
	if (moving or frozen) and math.abs(effectiveSpeed(record) - move.speed) > 0.01 then
		self:_issueMove(record, now, remainingPoints(move), record.moveKind)
	end

	-- Standing inside geometry (spawned or lunged into a pillar)? Every
	-- walk check refuses a leg that starts in a wall, and the pathfinder
	-- cannot start inside a part, so the mob would stand there for good:
	-- walk it out to the nearest clear spot instead.
	if not moving and now >= record.unstickCheckAt then
		record.unstickCheckAt = now + UNSTICK_CHECK_SECONDS
		if not bodyFitsAt(record.rootOffset, record.bodyRadius, record.ground) then
			local clear = findClearGround(record.rootOffset, record.bodyRadius, record.ground)
			if clear then
				self:_issueMove(record, now, { clear }, "unstick")
				return
			end
		end
	end

	-- A mob without Enabled holds still, exactly as MobBase skips its tick
	-- (EncounterService freezes adds with it).
	if not record.model:GetAttribute(Attributes.Enabled) then
		return
	end

	self:_findTarget(record)

	if record.state == STATE_ROAMING then
		if now < record.stateEndTime then
			return
		end
		if record.target then
			self:_enterChase(record)
			if record.data.support then
				self:_supportStep(record, now)
			else
				self:_chaseStep(record, now)
			end
		else
			self:_enterRoaming(record, now)
		end
		return
	end

	if record.state == STATE_CHASE then
		local targetRoot = record.targetRoot
		if not targetRoot or not targetRoot.Parent then
			self:_enterRoaming(record, now)
			return
		end
		if record.data.support then
			self:_supportStep(record, now)
		else
			self:_chaseStep(record, now)
		end
	end
end

local function thinkInterval(record: Record): number
	local distance = record.nearestPlayerDistance
	if distance <= THINK_NEAR_STUDS then
		return THINK_INTERVAL_NEAR
	elseif distance <= THINK_MID_STUDS then
		return THINK_INTERVAL_MID
	end
	return THINK_INTERVAL_FAR
end

local movedParts: { BasePart } = {}
local movedCFrames: { CFrame } = {}

function MobSimService._step(self: typeof(MobSimService))
	local now = workspace:GetServerTimeNow()
	refreshAlivePlayers(now)

	for _, record in self._records do
		if record.pushPending ~= Vector3.zero then
			self:_resolveKnockback(record, now)
		end
		local thought = false
		if now >= record.nextThink then
			record.nextThink = now + thinkInterval(record)
			self:_think(record, now)
			thought = true
		end
		if record.state == STATE_ATTACKING then
			continue
		end
		if not thought then
			-- Between thinks, a mob within reach of a player still moves its
			-- proxy EVERY frame: melee boxes, bullets, arcane radii and aim
			-- assist all test the proxy, and must find it where the clients
			-- draw the body. Only the decisions run on the slow clock.
			if record.nearestPlayerDistance > TRACK_EVERY_FRAME_STUDS then
				continue
			end
			record.ground, record.yaw = mobPath.sample(record.move, now)
		end
		local cframe = mobPath.rootCFrame(record.ground, record.yaw, record.rootOffset)
		local written = record.written
		if
			(cframe.Position - written.Position).Magnitude > WRITE_EPSILON_STUDS
			or written.LookVector:Dot(cframe.LookVector) < math.cos(WRITE_EPSILON_YAW)
		then
			record.written = cframe
			table.insert(movedParts, record.root)
			table.insert(movedCFrames, cframe)
		end
	end

	if #movedParts > 0 then
		workspace:BulkMoveTo(movedParts, movedCFrames, Enum.BulkMoveMode.FireCFrameChanged)
		table.clear(movedParts)
		table.clear(movedCFrames)
	end

	self:_pumpPathQueue()
end

--[ Lifecycle per mob ]--

function MobSimService._allocateId(self: typeof(MobSimService)): number?
	for _ = 1, MAX_SIM_ID do
		local id = self._nextId
		self._nextId = if id >= MAX_SIM_ID then 1 else id + 1
		if not self._records[id] then
			return id
		end
	end
	return nil
end

function MobSimService._register(self: typeof(MobSimService), record: Record)
	self._records[record.id] = record
	self._byModel[record.model] = record
	self._count += 1
	if not self._heartbeat then
		self._heartbeat = RunService.Heartbeat:Connect(function()
			self:_step()
		end)
	end
end

function MobSimService._unregister(self: typeof(MobSimService), record: Record)
	if self._records[record.id] ~= record then
		return
	end
	self._records[record.id] = nil
	self._byModel[record.model] = nil
	self._count -= 1
	for _, connection in record.connections do
		connection:Disconnect()
	end
	table.clear(record.connections)
	if record.path then
		record.path:Destroy()
		record.path = nil
	end
	if self._count == 0 and self._heartbeat then
		self._heartbeat:Disconnect()
		self._heartbeat = nil
		table.clear(self._pathQueue)
	end
end

function MobSimService._die(self: typeof(MobSimService), record: Record)
	if not record.alive then
		return
	end
	record.alive = false
	record.state = STATE_DEAD
	record.attackGeneration += 1
	local model = record.model
	model:SetAttribute("AttackInterrupted", true)
	self:_setAttacking(record, false)
	self:_unregister(record)
	MobSpawnService:DecrementMobCount(model)

	local deathContext: MobDeath.Context = {
		model = model,
		rootPart = record.root,
		enemyType = record.data.enemyType,
		gems = record.data.gems,
		assists = record.assists,
		isEncounter = false,
	}
	MobDeath.GrantKill(deathContext)
	local killer = MobDeath.ResolveKiller(model)
	local direction: Vector3? = nil
	if killer then
		local killerRoot = getRoot.fromPlayer(killer)
		if killerRoot then
			local away = flat(record.root.Position - killerRoot.Position)
			direction = if away.Magnitude > 0.05 then away.Unit else nil
		end
	end
	-- Every takedown (the killer and each recent assister), even when the
	-- killer has left.
	MobDeath.RunTakedownRewards(deathContext, killer)

	MobNetwork.MobAction.FireAll({
		Id = record.id,
		Kind = "Death",
		AttackIndex = 0,
		Direction = direction,
	})

	-- The corpse leaves the live folder (forEachEnemyInRadius, the spawn
	-- caps and the highlight registry all key off it) and stops taking hits.
	for _, name in { "RaycastHitbox", "MobHitbox", HURTBOX_NAME } do
		local part = model:FindFirstChild(name)
		if part then
			part:Destroy()
		end
	end
	model.Parent = workspace.IgnoreInstances.DeadMobs

	task.delay(DESPAWN_SECONDS, function()
		if not model.Parent then
			return
		end
		CombatNetwork.MobFade.FireAll({
			Mob = model,
			Phase = "Out",
			Duration = MobFadeData.DespawnFadeSeconds,
		})
		task.wait(MobFadeData.DespawnFadeSeconds)
		model:Destroy()
	end)
end

--[ Public ]--

-- True when MobData asks for this mob to be client-simulated.
function MobSimService.UsesSim(_self: typeof(MobSimService), mobName: string): boolean
	local data = MobData[mobName]
	return data ~= nil and data.useMobSim == true
end

-- Spawns a sim mob from `template` near `position` (a spawn point; snapped
-- down to the floor) and parents its proxy under the live Mobs folder.
-- Returns the proxy, or nil (no MobData row, a broken template, the id
-- space full).
function MobSimService.Spawn(
	self: typeof(MobSimService),
	template: Model,
	mobName: string,
	position: Vector3,
	roomId: number?
): Model?
	local data = MobData[mobName]
	if not data then
		warn("[MobSimService] No MobData for " .. mobName)
		return nil
	end
	local info = self:_resolveTemplate(template)
	if not info then
		return nil
	end
	local id = self:_allocateId()
	if not id then
		warn("[MobSimService] Out of mob ids")
		return nil
	end

	-- The floor under the spawn point (a short probe that ignores players,
	-- spell parts and invisible volumes), never something far below it.
	refreshAlivePlayers(workspace:GetServerTimeNow())
	local ground = floorBelow(position, SPAWN_FLOOR_SEARCH_STUDS) or position
	-- Not inside a pillar, not on top of another mob (no physics will part
	-- them later). Falls back to the spawn point when nothing nearby is clear.
	ground = findClearGround(info.rootOffset, info.bodyRadius, ground, function(candidate: Vector3): boolean
		for _, other in self._records do
			local spacing = (info.bodyRadius + other.bodyRadius) * SPAWN_MOB_SPACING
			if flat(other.ground - candidate).Magnitude < spacing then
				return true
			end
		end
		return false
	end) or ground
	local yaw = math.random() * math.pi * 2
	local rootCFrame = mobPath.rootCFrame(ground, yaw, info.rootOffset)
	local proxy, root, humanoid = buildProxy(template, info, rootCFrame)

	proxy:SetAttribute(Attributes.MobSimId, id)
	proxy:SetAttribute(Attributes.MobTemplate, info.templatePath)
	proxy:SetAttribute(Attributes.MobRootOffset, info.rootOffset)
	if roomId then
		proxy:SetAttribute("RoomId", roomId)
	end
	-- MobBase._resetAttributes, so every reader sees the same defaults.
	proxy:SetAttribute(Attributes.MobIsAttacking, false)
	proxy:SetAttribute(Attributes.SuperArmor, false)
	proxy:SetAttribute(Attributes.SlainBy, "")
	proxy:SetAttribute(Attributes.Jailed, false)
	proxy:SetAttribute(Attributes.Slowed, false)
	proxy:SetAttribute(Attributes.CCDebounce, false)
	proxy:SetAttribute(Attributes.EnemyType, data.enemyType)

	-- CORRUPTION (Shared/Data/CorruptionData): the run's difficulty tier
	-- rolls it once, here. Stamped before parenting so every reader -- the
	-- damage scaling in MobService, the rewards in MobDeath, the clients'
	-- CorruptVFX -- sees it from the first frame.
	local corrupted = MobSpawnService:RollCorruption()
	if corrupted then
		proxy:SetAttribute(Attributes.Corrupted, true)
	end

	local health = data.health
	local baseHealth: number = if type(health) == "function" then health() else health
	if corrupted then
		baseHealth *= CorruptionData.HealthMultiplier
	end
	EnemyScalingService:ApplyToMob(proxy, humanoid, baseHealth)

	local now = workspace:GetServerTimeNow()
	local attackPool = {}
	local randomAttackIndices = {}
	local closeAttackIndices = {}
	for index, attack in data.genericAttacks or {} do
		table.insert(attackPool, attack)
		table.insert(if attack.closeRange then closeAttackIndices else randomAttackIndices, index)
	end
	if #attackPool == 0 then
		warn("[MobSimService] " .. mobName .. " has no generic attacks; it will only roam")
	end

	local record: Record = {
		id = id,
		model = proxy,
		root = root,
		humanoid = humanoid,
		data = data,
		rootOffset = info.rootOffset,
		bodyRadius = info.bodyRadius,
		attackPool = attackPool,
		randomAttackIndices = randomAttackIndices,
		closeAttackIndices = closeAttackIndices,
		detectionRange = data.detectionRange or DEFAULT_DETECTION_RANGE,
		walkSpeed = data.walkSpeed,
		approachAngle = (math.random() * 2 - 1) * APPROACH_ANGLE_MAX,

		state = STATE_ROAMING,
		alive = true,
		stateEndTime = now + START_GRACE_SECONDS,
		nextThink = now + math.random() * THINK_INTERVAL_NEAR,
		attackGeneration = 0,
		chosenAttack = nil,
		chosenAttackIndex = 0,

		move = mobPath.new(now, 0, ground, {}, yaw),
		moveKind = "stop",
		baseSpeed = data.walkSpeed,
		ground = ground,
		yaw = yaw,
		written = rootCFrame,
		chaseGoal = nil,
		chaseTargetAt = nil,
		walkCheckAt = 0,
		unstickCheckAt = 0,
		pushPending = Vector3.zero,
		staggerPending = 0,
		staggerUntil = 0,
		supportIntent = nil,

		target = nil,
		targetRoot = nil,
		nearestPlayerDistance = math.huge,

		path = nil,
		pathPending = false,
		lastPathAt = 0,
		pathFailures = 0,
		pathGoal = nil,

		assists = {},
		connections = {},
	}

	for _, connection in MobDeath.TrackAssists(proxy, humanoid, record.assists) do
		table.insert(record.connections, connection)
	end
	table.insert(
		record.connections,
		humanoid.HealthChanged:Connect(function(newHealth: number)
			if newHealth <= 0 then
				self:_die(record)
			end
		end)
	)
	-- Destroyed from outside (a floor teardown clears the Mobs folder):
	-- drop the record without a death.
	table.insert(
		record.connections,
		proxy.AncestryChanged:Connect(function()
			if record.alive and not proxy:IsDescendantOf(workspace) then
				record.alive = false
				self:_unregister(record)
			end
		end)
	)

	self:_register(record)
	proxy.Parent = workspace.IgnoreInstances.Mobs
	MobNetwork.MobMove.FireAll({
		Id = id,
		StartTime = now,
		Speed = 0,
		Start = ground,
		Points = {},
		Yaw = yaw,
	})
	-- Deferred so OnMobSpawn fires after the spawner has added the mob to
	-- its room list (MobSpawnService._spawnMobAt), the order MobBase's
	-- delayed fire always gave listeners.
	task.defer(function()
		if record.alive then
			MobSpawnService:IncrementMobCount(proxy)
		end
	end)
	return proxy
end

-- Queues a knockback of `distance` studs on a sim mob, flat and away from
-- `origin`; resolved on the next frame (_resolveKnockback), summed with
-- any other push that frame. `fallbackOrigin` (the attacker) is used
-- when `origin` sits on top of the mob, or would push it TOWARD the
-- fallback (a box spell centred past its near edge). Not a sim mob,
-- dead, jailed, or in an attack that lunges: no push. Minibosses and
-- bosses are kept out by DamageService.
function MobSimService.ApplyKnockback(
	self: typeof(MobSimService),
	model: Model,
	origin: Vector3,
	distance: number,
	fallbackOrigin: Vector3?
)
	local record = self._byModel[model]
	if not record or not record.alive or distance < KNOCKBACK_MIN_STUDS then
		return
	end
	-- Super armor (the Robombie's poise) does NOT stop a push: it only
	-- means no flinch. Encounter enemies are kept out by DamageService.
	if model:GetAttribute(Attributes.Jailed) then
		return
	end
	-- A lunge's own PivotTo lands mid hit-frame and would undo the push.
	if record.state == STATE_ATTACKING and record.chosenAttack and (record.chosenAttack.lungeDistance or 0) > 0 then
		return
	end

	local at = record.root.Position
	local direction = flat(at - origin)
	local fallback = if fallbackOrigin then flat(at - fallbackOrigin) else nil
	if fallback and fallback.Magnitude > 0.05 and (direction.Magnitude < 0.05 or direction:Dot(fallback) < 0) then
		direction = fallback
	end
	if direction.Magnitude < 0.05 then
		return
	end

	record.pushPending += direction.Unit * distance
	record.staggerPending =
		math.min(math.max(record.staggerPending, distance * KNOCKBACK_STAGGER_PER_STUD), KNOCKBACK_STAGGER_MAX)
end

-- True when `model` is a live sim mob's proxy.
function MobSimService.IsSimMob(self: typeof(MobSimService), model: Model): boolean
	return self._byModel[model] ~= nil
end

-- Live sim mob count.
function MobSimService.GetCount(self: typeof(MobSimService)): number
	return self._count
end

return MobSimService
