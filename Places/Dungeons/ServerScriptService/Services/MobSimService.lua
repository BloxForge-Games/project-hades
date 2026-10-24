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
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local mobPath = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Mob.mobPath)
local getRoot = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Character.getRoot)
local snapToGround = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Combat.snapToGround)

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
local DESPAWN_SECONDS = 5

-- Roaming (MobBase's numbers): a point 20-25 studs away at half speed, a
-- fresh one every 2-4 s. A candidate needs a clear ray from the root and a
-- floor under it, so a mob never roams off a ledge.
local ROAM_DURATION_MIN = 2
local ROAM_DURATION_MAX = 4
local ROAM_RADIUS_MIN = 20
local ROAM_RADIUS_MAX = 25
local ROAM_PICK_ATTEMPTS = 5
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
local CHASE_SEPARATION_STEP = math.rad(35)

-- A sim mob has no physics, so nothing but these checks keeps a straight
-- leg out of walls and off ledges. A leg is walkable when a sphere of the
-- mob's half agent radius (clamped) clears the way at root height, and a
-- floor sits within WALK_STEP_STUDS of the straight line every
-- WALK_FLOOR_SAMPLE_STUDS (at most WALK_FLOOR_SAMPLES_MAX probes). Only
-- checked when a leg is about to be sent; a failed check is not retried
-- for WALK_RECHECK_SECONDS.
local WALK_PROBE_RADIUS_MIN = 0.5
local WALK_PROBE_RADIUS_MAX = 2
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
	attackPool: { any },
	detectionRange: number,
	walkSpeed: number,
	approachAngle: number,

	state: string,
	alive: boolean,
	stateEndTime: number,
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
	walkParams = params
	return params
end

-- What counts as floor: everything solid except mobs, effects, the
-- invisible walls (a probe must never land on a barrier's top) and the
-- living players' characters, which refreshAlivePlayers keeps in the
-- filter as they come and go.
local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Exclude
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

-- Can the mob walk a straight leg from `fromGround` to `toGround` (both
-- ground points)? See the WALK_* constants.
local function canWalkStraight(record: Record, fromGround: Vector3, toGround: Vector3): boolean
	local lift = Vector3.new(0, record.rootOffset, 0)
	local delta = toGround - fromGround
	local flatLength = flat(delta).Magnitude
	if flatLength < 0.05 then
		return true
	end

	local radius = math.clamp(
		(record.data.agentRadius or 2) * 0.5,
		WALK_PROBE_RADIUS_MIN,
		math.max(math.min(WALK_PROBE_RADIUS_MAX, record.rootOffset - 0.5), WALK_PROBE_RADIUS_MIN)
	)
	local hit = workspace:Spherecast(fromGround + lift, radius, delta, getWalkParams())
	if hit and not isCharacterPart(hit.Instance) then
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
			AgentRadius = record.data.agentRadius or 2,
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

function MobSimService._enterRoaming(self: typeof(MobSimService), record: Record, now: number)
	record.state = STATE_ROAMING
	record.chosenAttack = nil
	record.chaseGoal = nil
	record.baseSpeed = record.walkSpeed / 2
	record.stateEndTime = now + math.random(ROAM_DURATION_MIN, ROAM_DURATION_MAX)

	local origin = rootPosition(record)
	for _ = 1, ROAM_PICK_ATTEMPTS do
		local angle = math.random() * math.pi * 2
		local distance = math.random(ROAM_RADIUS_MIN, ROAM_RADIUS_MAX)
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
	local pool = record.attackPool
	if #pool > 0 then
		record.chosenAttackIndex = math.random(1, #pool)
		record.chosenAttack = pool[record.chosenAttackIndex]
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

	local attack = record.chosenAttack
	if attack and (from - targetPosition).Magnitude <= attack.attackRange then
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
		local needsLeg = record.moveKind ~= "direct"
			or (not moving and not arrived)
			or chaseGoal == nil
			or record.chaseTargetAt == nil
			or flat(targetPosition - (record.chaseTargetAt :: Vector3)).Magnitude > regoal
		if not needsLeg then
			return
		end

		if now >= record.walkCheckAt then
			local goal = self:_pickChaseGoal(record, targetPosition, away, stopDistance)
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
	local generation = record.attackGeneration

	-- Aim BEFORE the wind-up: the swing's hitbox and the ranged shot both
	-- read the root's facing (MobData hitboxCFrame / muzzleOffset).
	record.ground = (mobPath.sample(record.move, now))
	local facing = mobPath.yawFromDirection(targetRoot.Position - rootPosition(record))
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
			MobService:ExecuteMobAttack(record.model, attack)
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
		self:_enterRoaming(record, resumeAt)
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

	-- Chill / Jail landed or wore off mid-leg: re-send the rest of the leg
	-- at the new speed. A leg frozen at speed 0 (jailed) still has every
	-- point ahead of it, so it resumes the same way.
	local move = record.move
	local frozen = move.speed == 0 and #move.points > 0
	if (moving or frozen) and math.abs(effectiveSpeed(record) - move.speed) > 0.01 then
		self:_issueMove(record, now, remainingPoints(move), record.moveKind)
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
			self:_chaseStep(record, now)
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
		self:_chaseStep(record, now)
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
		MobDeath.RunKillerRewards(deathContext, killer)
	end

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

	local ground = snapToGround(position) or position
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

	local health = data.health
	EnemyScalingService:ApplyToMob(proxy, humanoid, if type(health) == "function" then health() else health)

	local now = workspace:GetServerTimeNow()
	local attackPool = {}
	for _, attack in data.genericAttacks or {} do
		table.insert(attackPool, attack)
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
		attackPool = attackPool,
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

-- True when `model` is a live sim mob's proxy.
function MobSimService.IsSimMob(self: typeof(MobSimService), model: Model): boolean
	return self._byModel[model] ~= nil
end

-- Live sim mob count.
function MobSimService.GetCount(self: typeof(MobSimService)): number
	return self._count
end

return MobSimService
