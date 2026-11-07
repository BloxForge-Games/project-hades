--!strict
--[[
	Module: GuideBeamController.lua
	Description:
	The hub's guide (2026-11-06; golden wisps since 2026-11-07): every
	WISP_INTERVAL seconds a golden wisp leaves the local player, arcs up
	and drifts along the walkable path to the destination like a gust of
	fairy wind, trailing gold and shedding star sparkles, and fades out
	there.

	  PATH    PathfindingService, on this client, from the player's feet to
	          the destination (stopped STOP_SHORT_STUDS short of it, on the
	          player's side, so an NPC's own collider never blocks it).
	          Recomputed every RECOMPUTE_SECONDS while the player or the
	          target moves; never per frame. A failed path falls back to a
	          straight line. Waypoints go through a Catmull-Rom spline and
	          are cut into points SPACING apart, each raycast to the ground.
	  WISP    Each wisp takes a snapshot of the path when it launches and
	          flies it start to finish on its own: from the player's
	          HumanoidRootPart, ARC_RISE above the path at its middle (an arc, lower
	          on short paths), gently swaying sideways and bobbing, eased
	          in and out, at about WISP_SPEED studs a second. A neon mote
	          with a gold Trail, a star ParticleEmitter (the VIP star image,
	          gold) and a soft light. At the end it stops emitting and its
	          trail and sparkles die out.
	  ARRIVE  Within ARRIVE_STUDS of the destination no more wisps launch
	          and OnArrived fires.

	Public: PointTo(target: Instance | Vector3), Clear(), IsActive(),
	OnArrived (fires with the target). The future tutorial drives it
	through these. /guide (LobbyChatCommandsService) drives it through the
	player's GuideTarget attribute: "<NPC name>|<stamp>", "" for none; the
	NPC is looked up under workspace.IgnoreInstances.NPCs.

	Client-only and local: the parts live on this client and replicate
	nowhere. CanQuery is off, so nothing else's raycasts hit them.
]]

--[ Roblox Services ]--

local PathfindingService = game:GetService("PathfindingService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

--[ Imports ]--

local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local Signal = require(ReplicatedStorage.Submodules.Core.Packages.Signal)

--[ Constants ]--

local IGNORE_INSTANCES_NAME = "IgnoreInstances"
local NPC_FOLDER_NAME = "NPCs"

-- One wisp every WISP_INTERVAL seconds while guiding.
local WISP_INTERVAL = 2
-- Flight speed (studs a second) and its bounds on the whole flight.
-- (2026-11-07: slowed from 22 and 0.9-4 s, to linger.)
local WISP_SPEED = 13
local WISP_DURATION = NumberRange.new(1.6, 6)
-- Heights above the ground: where it arrives (an NPC's chest), and the
-- arc's extra height at the middle (ARC_RISE_PER_STUD of the path's
-- length, capped). It leaves from your HumanoidRootPart.
local END_HEIGHT = 3.5
local ARC_RISE_PER_STUD = 0.12
local ARC_RISE = NumberRange.new(1.5, 7)
-- The wind: sideways sway and a bob (studs; waves along the flight).
-- (2026-11-07: fewer, wider waves for a smoother, lazier swirl; were
-- 2.5 and 4.)
local SWAY = 1.1
local SWAY_WAVES = 1.25
local BOB = 0.4
local BOB_WAVES = 1.75

local GOLD = Color3.fromRGB(255, 205, 90)
local GOLD_DEEP = Color3.fromRGB(255, 170, 0)
local MOTE_SIZE = 0.45
local STAR_IMAGE = "rbxassetid://14488863746"
-- Seconds the trail and the sparkles outlive the wisp.
-- (2026-11-07: longer, were 0.7 and 0.5-1.)
local TRAIL_LIFETIME = 1.4
local SPARKLE_LIFETIME = NumberRange.new(0.8, 1.6)
local SPARKLE_RATE = 45

-- Studs between path points.
local SPACING = 1.6
local GROUND_LIFT = 0.12

local RECOMPUTE_SECONDS = 0.12
-- A recompute is skipped while neither end moved this much.
local MOVE_STUDS = 0.3
local STOP_SHORT_STUDS = 3.5
local ARRIVE_STUDS = 6
-- Spline samples per stud before the resample.
local SPLINE_DENSITY = 2
local RAY_UP = 4
local RAY_DOWN = 14

local AGENT_PARAMS = {
	AgentRadius = 2,
	AgentHeight = 5,
	AgentCanJump = true,
	WaypointSpacing = 4,
}

--[ Types ]--

type Wisp = {
	-- The flight: ground points from the player to the destination, and the
	-- running distance at each.
	points: { Vector3 },
	distances: { number },
	length: number,
	duration: number,
	rise: number,
	-- Height above the ground it leaves from: the HumanoidRootPart's.
	startHeight: number,
	seed: number,
	age: number,
	mote: BasePart,
	sparkles: ParticleEmitter,
	trail: Trail,
	light: PointLight,
	done: boolean,
}

--[ Controller ]--

local GuideBeamController = {
	Name = "GuideBeamController",
}

GuideBeamController.OnArrived = Signal.new()

GuideBeamController._target = nil :: Instance | Vector3 | nil
-- The newest path, keyed by distance-from-destination index (0 = at it).
GuideBeamController._goal = {} :: { [number]: Vector3 }
GuideBeamController._goalNormal = {} :: { [number]: Vector3 }
GuideBeamController._goalCount = 0
GuideBeamController._wisps = {} :: { Wisp }
GuideBeamController._folder = nil :: Folder?
GuideBeamController._sinceWisp = math.huge
GuideBeamController._computing = false
GuideBeamController._lastCompute = -math.huge
GuideBeamController._lastFrom = nil :: Vector3?
GuideBeamController._lastTo = nil :: Vector3?
GuideBeamController._arrived = false

--[ Helpers ]--

local function flat(vector: Vector3): Vector3
	return Vector3.new(vector.X, 0, vector.Z)
end

local function targetPosition(target: Instance | Vector3): Vector3?
	if typeof(target) == "Vector3" then
		return target
	end
	local instance = target :: Instance
	if not instance.Parent then
		return nil
	end
	if instance:IsA("Model") then
		local root = instance.PrimaryPart or instance:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			return root.Position
		end
		return instance:GetPivot().Position
	elseif instance:IsA("BasePart") then
		return instance.Position
	elseif instance:IsA("Attachment") then
		return instance.WorldPosition
	end
	return nil
end

local function rootPart(): BasePart?
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function feet(root: BasePart): Vector3
	local character = root.Parent
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local hipHeight = if humanoid then humanoid.HipHeight else 2
	return root.Position - Vector3.new(0, root.Size.Y / 2 + hipHeight, 0)
end

-- Centripetal-free uniform Catmull-Rom through `points`, sampled densely.
local function spline(points: { Vector3 }): { Vector3 }
	local count = #points
	if count < 3 then
		return points
	end
	local out = { points[1] }
	for i = 1, count - 1 do
		local p0 = points[math.max(i - 1, 1)]
		local p1 = points[i]
		local p2 = points[i + 1]
		local p3 = points[math.min(i + 2, count)]
		local steps = math.max(2, math.ceil((p2 - p1).Magnitude * SPLINE_DENSITY))
		for step = 1, steps do
			local t = step / steps
			local t2 = t * t
			local t3 = t2 * t
			table.insert(
				out,
				0.5
					* (
						(2 * p1)
						+ (p2 - p0) * t
						+ (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2
						+ (3 * p1 - p0 - 3 * p2 + p3) * t3
					)
			)
		end
	end
	return out
end

-- Points SPACING apart along `line`, starting at line[1] (the destination).
local function resample(line: { Vector3 }): { Vector3 }
	local out = { line[1] }
	local carried = 0
	for i = 1, #line - 1 do
		local a = line[i]
		local b = line[i + 1]
		local length = (b - a).Magnitude
		local along = SPACING - carried
		while along <= length do
			table.insert(out, a:Lerp(b, along / length))
			along += SPACING
		end
		carried = length - (along - SPACING)
	end
	local last = line[#line]
	if (out[#out] - last).Magnitude > SPACING * 0.25 then
		table.insert(out, last)
	end
	return out
end

-- 0 -> 1 eased at both ends.
local function easeInOut(t: number): number
	return 0.5 - math.cos(math.pi * math.clamp(t, 0, 1)) / 2
end

--[ Private ]--

function GuideBeamController._ensureFolder(self: typeof(GuideBeamController)): Folder
	local folder = self._folder
	if folder and folder.Parent then
		return folder
	end
	local newFolder = Instance.new("Folder")
	newFolder.Name = "GuideWisps"
	newFolder.Parent = workspace
	self._folder = newFolder
	return newFolder
end

-- A mote with its trail, sparkles and glow.
function GuideBeamController._newMote(
	self: typeof(GuideBeamController),
	at: Vector3
): (BasePart, ParticleEmitter, Trail, PointLight)
	local mote = Instance.new("Part")
	mote.Name = "Wisp"
	mote.Shape = Enum.PartType.Ball
	mote.Size = Vector3.one * MOTE_SIZE
	mote.Material = Enum.Material.Neon
	mote.Color = GOLD
	mote.Transparency = 0.15
	mote.Anchored = true
	mote.CanCollide = false
	mote.CanQuery = false
	mote.CanTouch = false
	mote.CastShadow = false
	mote.CFrame = CFrame.new(at)

	local top = Instance.new("Attachment")
	top.Position = Vector3.new(0, 0.18, 0)
	top.Parent = mote
	local bottom = Instance.new("Attachment")
	bottom.Position = Vector3.new(0, -0.18, 0)
	bottom.Parent = mote
	local trail = Instance.new("Trail")
	trail.Attachment0 = top
	trail.Attachment1 = bottom
	trail.FaceCamera = true
	trail.Lifetime = TRAIL_LIFETIME
	trail.MinLength = 0.05
	trail.LightEmission = 1
	trail.LightInfluence = 0
	trail.Color = ColorSequence.new(GOLD, GOLD_DEEP)
	trail.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(0.6, 0.6),
		NumberSequenceKeypoint.new(1, 1),
	})
	trail.WidthScale = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(1, 0),
	})
	trail.Parent = mote

	local sparkles = Instance.new("ParticleEmitter")
	sparkles.Texture = STAR_IMAGE
	sparkles.Color = ColorSequence.new(GOLD)
	sparkles.LightEmission = 1
	sparkles.LightInfluence = 0
	sparkles.Rate = SPARKLE_RATE
	sparkles.Lifetime = SPARKLE_LIFETIME
	sparkles.Speed = NumberRange.new(0.3, 1.4)
	sparkles.SpreadAngle = Vector2.new(180, 180)
	sparkles.Drag = 2
	sparkles.Acceleration = Vector3.new(0, -1.2, 0)
	sparkles.Rotation = NumberRange.new(0, 360)
	sparkles.RotSpeed = NumberRange.new(-90, 90)
	sparkles.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.32),
		NumberSequenceKeypoint.new(1, 0),
	})
	sparkles.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.7, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	sparkles.Parent = mote

	local light = Instance.new("PointLight")
	light.Color = GOLD
	light.Brightness = 1.5
	light.Range = 6
	light.Shadows = false
	light.Parent = mote

	mote.Parent = self:_ensureFolder()
	return mote, sparkles, trail, light
end

-- Launches one wisp along the current path (player side first).
function GuideBeamController._launch(self: typeof(GuideBeamController), root: BasePart)
	local count = self._goalCount
	if count < 2 then
		return
	end
	local points: { Vector3 } = { feet(root) }
	for key = count - 2, 0, -1 do
		table.insert(points, self._goal[key])
	end
	local distances = { 0 }
	for index = 2, #points do
		distances[index] = distances[index - 1] + (points[index] - points[index - 1]).Magnitude
	end
	local length = distances[#distances]
	if length < 1 then
		return
	end
	-- Leaves from the HumanoidRootPart (2026-11-07; was a fixed 4.5 studs,
	-- about head height).
	local startHeight = root.Position.Y - points[1].Y
	local mote, sparkles, trail, light = self:_newMote(root.Position)
	table.insert(self._wisps, {
		points = points,
		distances = distances,
		length = length,
		duration = math.clamp(length / WISP_SPEED, WISP_DURATION.Min, WISP_DURATION.Max),
		rise = math.clamp(length * ARC_RISE_PER_STUD, ARC_RISE.Min, ARC_RISE.Max),
		startHeight = startHeight,
		seed = math.random() * 100,
		age = 0,
		mote = mote,
		sparkles = sparkles,
		trail = trail,
		light = light,
		done = false,
	})
end

-- Where a wisp is at `u` (0 at the player, 1 at the destination).
local function wispPosition(wisp: Wisp, u: number): Vector3
	local at = u * wisp.length
	local points, distances = wisp.points, wisp.distances
	local index = 1
	while index < #points - 1 and distances[index + 1] < at do
		index += 1
	end
	local a, b = points[index], points[index + 1]
	local span = distances[index + 1] - distances[index]
	local ground = if span > 0 then a:Lerp(b, (at - distances[index]) / span) else a
	local along = b - a
	along = if along.Magnitude > 1e-3 then along.Unit else Vector3.zAxis
	local across = along:Cross(Vector3.yAxis)
	across = if across.Magnitude > 1e-3 then across.Unit else Vector3.xAxis

	-- The arc, and the wind on it (both settle to nothing at the ends).
	local settle = math.sin(math.pi * u)
	local height = wisp.startHeight + (END_HEIGHT - wisp.startHeight) * u + wisp.rise * settle
	local sway = math.sin((u * SWAY_WAVES + wisp.seed) * math.pi * 2) * SWAY * settle
	local bob = math.sin((u * BOB_WAVES + wisp.seed) * math.pi * 2) * BOB * settle
	return ground + Vector3.new(0, height + bob, 0) + across * sway
end

function GuideBeamController._stepWisps(self: typeof(GuideBeamController), dt: number)
	for index = #self._wisps, 1, -1 do
		local wisp = self._wisps[index]
		wisp.age += dt
		if not wisp.done then
			local t = wisp.age / wisp.duration
			wisp.mote.CFrame = CFrame.new(wispPosition(wisp, easeInOut(t)))
			-- Fade in over the first tenth, out over the last.
			local fade = math.min(1, t * 10, (1 - t) * 10)
			wisp.mote.Transparency = 1 - 0.85 * math.clamp(fade, 0, 1)
			wisp.light.Brightness = 1.5 * math.clamp(fade, 0, 1)
			if t >= 1 then
				-- Arrived: stop shedding and let the trail and sparkles die.
				wisp.done = true
				wisp.age = 0
				wisp.sparkles.Enabled = false
				wisp.mote.Transparency = 1
				wisp.light.Enabled = false
			end
		elseif wisp.age > math.max(TRAIL_LIFETIME, SPARKLE_LIFETIME.Max) then
			wisp.mote:Destroy()
			table.remove(self._wisps, index)
		end
	end
end

function GuideBeamController._raycastParams(_self: typeof(GuideBeamController)): RaycastParams
	local exclude: { Instance } = {}
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(exclude, player.Character)
		end
	end
	local ignore = workspace:FindFirstChild(IGNORE_INSTANCES_NAME)
	local npcs = ignore and ignore:FindFirstChild(NPC_FOLDER_NAME)
	if npcs then
		table.insert(exclude, npcs)
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = exclude
	params.IgnoreWater = true
	return params
end

-- The destination, on the player's side of the target.
function GuideBeamController._destination(self: typeof(GuideBeamController), from: Vector3): Vector3?
	local target = self._target
	local position = target and targetPosition(target)
	if not position then
		return nil
	end
	local away = flat(from - position)
	if away.Magnitude > 0.01 then
		position += away.Unit * STOP_SHORT_STUDS
	end
	return position
end

function GuideBeamController._compute(self: typeof(GuideBeamController), from: Vector3, to: Vector3)
	local waypoints: { Vector3 } = {}
	local path = PathfindingService:CreatePath(AGENT_PARAMS)
	local ok = pcall(function()
		path:ComputeAsync(from, to)
	end)
	if ok and path.Status == Enum.PathStatus.Success then
		for _, waypoint in path:GetWaypoints() do
			table.insert(waypoints, waypoint.Position)
		end
	end
	if #waypoints < 2 then
		waypoints = { from, to }
	end

	-- Destination first, so the resample is anchored there.
	local reversed: { Vector3 } = {}
	for i = #waypoints, 1, -1 do
		table.insert(reversed, waypoints[i])
	end
	local points = resample(spline(reversed))

	local params = self:_raycastParams()
	local goal: { [number]: Vector3 } = {}
	local normals: { [number]: Vector3 } = {}
	for index, point in points do
		local hit =
			workspace:Raycast(point + Vector3.new(0, RAY_UP, 0), Vector3.new(0, -(RAY_UP + RAY_DOWN), 0), params)
		local key = index - 1
		if hit then
			goal[key] = Vector3.new(point.X, hit.Position.Y + GROUND_LIFT, point.Z)
			normals[key] = hit.Normal
		else
			goal[key] = point + Vector3.new(0, GROUND_LIFT, 0)
			normals[key] = Vector3.yAxis
		end
	end
	self._goal = goal
	self._goalNormal = normals
	self._goalCount = #points
end

function GuideBeamController._requestCompute(self: typeof(GuideBeamController), root: BasePart)
	if self._computing then
		return
	end
	local now = os.clock()
	if now - self._lastCompute < RECOMPUTE_SECONDS then
		return
	end
	local from = feet(root)
	local to = self:_destination(from)
	if not to then
		return
	end
	local lastFrom = self._lastFrom
	local lastTo = self._lastTo
	if
		lastFrom
		and lastTo
		and (lastFrom - from).Magnitude < MOVE_STUDS
		and (lastTo - to).Magnitude < MOVE_STUDS
		and self._goalCount > 0
	then
		return
	end
	self._computing = true
	self._lastCompute = now
	self._lastFrom = from
	self._lastTo = to
	local target = self._target
	task.spawn(function()
		self:_compute(from, to)
		self._computing = false
		-- Cleared or retargeted while the path was computing.
		if self._target ~= target then
			self._goal = {}
			self._goalNormal = {}
			self._goalCount = 0
			self._lastFrom = nil
		end
	end)
end

function GuideBeamController._step(self: typeof(GuideBeamController), dt: number)
	self:_stepWisps(dt)

	local root = rootPart()
	if self._target == nil or root == nil or self._arrived then
		return
	end
	self:_requestCompute(root)
	local target = self._target
	local position = target and targetPosition(target)
	if position and (flat(root.Position) - flat(position)).Magnitude <= ARRIVE_STUDS then
		self._arrived = true
		self.OnArrived:Fire(target)
		return
	end

	-- The first wisp as soon as there is a path, then one every interval.
	self._sinceWisp += dt
	if self._sinceWisp >= WISP_INTERVAL and self._goalCount >= 2 then
		self._sinceWisp = 0
		self:_launch(root)
	end
end

function GuideBeamController._findNpc(_self: typeof(GuideBeamController), name: string): Instance?
	local ignore = workspace:FindFirstChild(IGNORE_INSTANCES_NAME)
	local npcs = ignore and ignore:FindFirstChild(NPC_FOLDER_NAME)
	return npcs and npcs:FindFirstChild(name)
end

function GuideBeamController._onGuideTarget(self: typeof(GuideBeamController))
	local value = Players.LocalPlayer:GetAttribute(Attributes.GuideTarget)
	local name = if typeof(value) == "string" then string.match(value, "^([^|]*)") else nil
	if not name or name == "" then
		self:Clear()
		return
	end
	local npc = self:_findNpc(name)
	if npc then
		self:PointTo(npc)
	else
		self:Clear()
	end
end

--[ Public ]--

-- Guides the player to `target` (a model, part, attachment or position).
function GuideBeamController.PointTo(self: typeof(GuideBeamController), target: Instance | Vector3)
	self._target = target
	self._arrived = false
	self._goal = {}
	self._goalNormal = {}
	self._goalCount = 0
	self._lastFrom = nil
	self._lastTo = nil
	self._lastCompute = -math.huge
	self._sinceWisp = math.huge
end

-- Stops launching wisps (those in flight finish).
function GuideBeamController.Clear(self: typeof(GuideBeamController))
	self._target = nil
	self._lastFrom = nil
	self._lastTo = nil
end

function GuideBeamController.IsActive(self: typeof(GuideBeamController)): boolean
	return self._target ~= nil and not self._arrived
end

--[ Lifecycle ]--

function GuideBeamController.Start(self: typeof(GuideBeamController))
	Players.LocalPlayer:GetAttributeChangedSignal(Attributes.GuideTarget):Connect(function()
		self:_onGuideTarget()
	end)
	self:_onGuideTarget()

	RunService.RenderStepped:Connect(function(dt: number)
		self:_step(dt)
	end)
end

return GuideBeamController
