--!strict
--[[
	Module: GuideBeamController.lua
	Description:
	The hub's guide path (2026-11-06): a ribbon of chevrons on the ground
	from the local player to a destination, scrolling toward it, bending
	round whatever is in the way.

	  PATH    PathfindingService, on this client, from the player's feet to
	          the destination (stopped STOP_SHORT_STUDS short of it, on the
	          player's side, so an NPC's own collider never blocks it).
	          Recomputed every RECOMPUTE_SECONDS while the player or the
	          target moves; never per frame. A failed path falls back to a
	          straight line.
	  SMOOTH  The waypoints go through a Catmull-Rom spline, then are cut
	          into points SPACING apart measured FROM THE DESTINATION. A
	          point is keyed by its distance from the destination, so the
	          same key lands in about the same place each recompute and
	          the drawn point eases toward it (POINT_EASE): the ribbon
	          re-angles smoothly instead of snapping.
	  DRAW    One Beam per pair of points (MAX_POINTS at most, nearest the
	          player), lying flat on the ground (each point raycast down,
	          lifted GROUND_LIFT), FaceCamera off, plus a thin rail along
	          each edge. The texture is the mobile skillshot arrow
	          (GameAssets.MobileHitMarkers.ArrowBeamPart's chevron), one
	          chevron per segment, scrolling toward the destination. The
	          end at the player fades in over FADE_SEGMENTS; points behind
	          the player are dropped every frame, so the tail keeps up
	          between recomputes.
	  ARRIVE  Within ARRIVE_STUDS of the destination the path fades out
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

-- The chevron (the mobile skillshot arrow's texture). Read off the asset
-- when it is there, so a re-skin of that arrow re-skins this too.
local FALLBACK_TEXTURE = "rbxassetid://6798365555"

-- Studs between drawn points (one chevron each).
local SPACING = 1.6
-- The most points drawn (the ones nearest the player); 60 covers ~96 studs.
local MAX_POINTS = 60
local WIDTH = 2.6
local RAIL_WIDTH = 0.14
local GROUND_LIFT = 0.12
local COLOR = Color3.fromRGB(255, 255, 255)
-- The tail by the player is warmer, the head white.
local TAIL_COLOR = Color3.fromRGB(255, 214, 120)
local LIGHT_EMISSION = 0.6
local BRIGHTNESS = 1.6
-- Chevrons per second, toward the destination (negative: the texture runs
-- from Attachment1, the player's side, to Attachment0).
local TEXTURE_SPEED = -1.2
-- Segments over which the end at the player fades in.
local FADE_SEGMENTS = 5
-- Base transparency of the ribbon and the rails.
local RIBBON_TRANSPARENCY = 0.05
local RAIL_TRANSPARENCY = 0.15

local RECOMPUTE_SECONDS = 0.12
-- A recompute is skipped while neither end moved this much.
local MOVE_STUDS = 0.3
local STOP_SHORT_STUDS = 3.5
local ARRIVE_STUDS = 6
-- How fast a drawn point eases toward its place on the newest path (per
-- second; higher is snappier).
local POINT_EASE = 18
-- How fast the whole path fades in and out (per second).
local FADE_EASE = 6
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

type Slot = {
	center: Attachment,
	left: Attachment,
	right: Attachment,
	ribbon: Beam,
	leftRail: Beam,
	rightRail: Beam,
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
-- The drawn points, easing toward _goal.
GuideBeamController._drawn = {} :: { [number]: Vector3 }
GuideBeamController._drawnNormal = {} :: { [number]: Vector3 }
GuideBeamController._slots = {} :: { Slot }
GuideBeamController._holder = nil :: BasePart?
GuideBeamController._texture = FALLBACK_TEXTURE
GuideBeamController._opacity = 0
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

local function newAttachment(holder: BasePart): Attachment
	local attachment = Instance.new("Attachment")
	attachment.Parent = holder
	return attachment
end

local function newBeam(holder: BasePart, a0: Attachment, a1: Attachment, width: number): Beam
	local beam = Instance.new("Beam")
	beam.Attachment0 = a0
	beam.Attachment1 = a1
	beam.FaceCamera = false
	beam.Segments = 1
	beam.Width0 = width
	beam.Width1 = width
	beam.LightEmission = LIGHT_EMISSION
	beam.LightInfluence = 0
	beam.Brightness = BRIGHTNESS
	beam.Color = ColorSequence.new(COLOR)
	beam.Enabled = false
	beam.Parent = holder
	return beam
end

--[ Private ]--

function GuideBeamController._ensureHolder(self: typeof(GuideBeamController)): BasePart
	local holder = self._holder
	if holder and holder.Parent then
		return holder
	end
	local part = Instance.new("Part")
	part.Name = "GuidePath"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Size = Vector3.one
	part.CFrame = CFrame.new()
	part.Parent = workspace
	self._holder = part
	self._slots = {}
	return part
end

function GuideBeamController._slot(self: typeof(GuideBeamController), index: number): Slot
	local slot = self._slots[index]
	if slot then
		return slot
	end
	local holder = self:_ensureHolder()
	local center = newAttachment(holder)
	local left = newAttachment(holder)
	local right = newAttachment(holder)
	local newSlot: Slot = {
		center = center,
		left = left,
		right = right,
		ribbon = newBeam(holder, center, center, WIDTH),
		leftRail = newBeam(holder, left, left, RAIL_WIDTH),
		rightRail = newBeam(holder, right, right, RAIL_WIDTH),
	}
	newSlot.ribbon.Texture = self._texture
	newSlot.ribbon.TextureMode = Enum.TextureMode.Stretch
	newSlot.ribbon.TextureLength = 1
	newSlot.ribbon.TextureSpeed = TEXTURE_SPEED
	self._slots[index] = newSlot
	return newSlot
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

function GuideBeamController._hideFrom(self: typeof(GuideBeamController), first: number)
	for index = first, #self._slots do
		local slot = self._slots[index]
		slot.ribbon.Enabled = false
		slot.leftRail.Enabled = false
		slot.rightRail.Enabled = false
	end
end

function GuideBeamController._step(self: typeof(GuideBeamController), dt: number)
	local root = rootPart()
	local active = self._target ~= nil and root ~= nil and not self._arrived

	if active and root then
		self:_requestCompute(root)
		local target = self._target
		local position = target and targetPosition(target)
		if position and (flat(root.Position) - flat(position)).Magnitude <= ARRIVE_STUDS then
			self._arrived = true
			active = false
			self.OnArrived:Fire(target)
		end
	end

	self._opacity += ((if active then 1 else 0) - self._opacity) * math.min(1, dt * FADE_EASE)
	if self._opacity < 0.02 and not active then
		self._opacity = 0
		self:_hideFrom(1)
		if self._target == nil or self._arrived then
			self._drawn = {}
			self._drawnNormal = {}
		end
		return
	end

	local count = self._goalCount
	if count < 2 or not root then
		self:_hideFrom(1)
		return
	end

	-- Ease every drawn point toward the newest path.
	local ease = math.min(1, dt * POINT_EASE)
	local drawn = self._drawn
	local drawnNormal = self._drawnNormal
	for key = 0, count - 1 do
		local goalPoint = self._goal[key]
		local goalNormal = self._goalNormal[key]
		local current = drawn[key]
		if current then
			drawn[key] = current:Lerp(goalPoint, ease)
			drawnNormal[key] = (drawnNormal[key] or goalNormal):Lerp(goalNormal, ease)
		else
			-- A new key grows out of its neighbour toward the destination.
			local neighbour = drawn[key - 1]
			drawn[key] = if neighbour then neighbour:Lerp(goalPoint, 0.5) else goalPoint
			drawnNormal[key] = goalNormal
		end
	end
	for key in drawn do
		if key >= count then
			drawn[key] = nil
			drawnNormal[key] = nil
		end
	end

	-- Drop the points behind the player: the last kept key is the one
	-- nearest the player's feet.
	local playerAt = flat(root.Position)
	local nearestKey = count - 1
	local nearestDistance = math.huge
	for key = 0, count - 1 do
		local distance = (flat(drawn[key]) - playerAt).Magnitude
		if distance < nearestDistance then
			nearestDistance = distance
			nearestKey = key
		end
	end
	local lastKey = math.min(nearestKey, MAX_POINTS - 1)
	if lastKey < 1 then
		self:_hideFrom(1)
		return
	end

	-- The points drawn this frame: the path up to (not including) the
	-- point nearest the player, then the player's own feet, so the tail
	-- stays on the player every frame instead of waiting for a recompute.
	local points: { Vector3 } = {}
	local normals: { Vector3 } = {}
	for key = 0, lastKey - 1 do
		table.insert(points, drawn[key])
		table.insert(normals, drawnNormal[key])
	end
	local tail = points[#points]
	table.insert(points, Vector3.new(root.Position.X, tail.Y, root.Position.Z))
	table.insert(normals, normals[#normals])

	-- Place every point. A Beam with FaceCamera off spreads its width
	-- along its attachments' Y axis and faces their X axis, so X is the
	-- ground's normal and Y runs across the path (2026-11-06: it was the
	-- other way round, which stood the ribbon on its edge). The rails sit
	-- WIDTH/2 either side. Point `index` lives in slot `index`.
	for index, position in points do
		local along = if index > 1 then points[index - 1] - position else position - points[2]
		if along.Magnitude < 1e-3 then
			along = Vector3.zAxis
		end
		local up = normals[index]
		local across = along:Cross(up)
		across = if across.Magnitude < 1e-3 then Vector3.xAxis else across.Unit
		local frame = CFrame.fromMatrix(position, up, across)
		local slot = self:_slot(index)
		slot.center.CFrame = frame
		slot.left.CFrame = frame * CFrame.new(0, -WIDTH / 2, 0)
		slot.right.CFrame = frame * CFrame.new(0, WIDTH / 2, 0)
	end

	-- Segment `index` runs from point index - 1 (destination side,
	-- Attachment0, which the chevrons point at) to point index.
	local opacity = self._opacity
	local segments = #points - 1
	for index = 1, segments do
		local slot = self._slots[index]
		local nextSlot = self._slots[index + 1]
		slot.ribbon.Attachment1 = nextSlot.center
		slot.leftRail.Attachment1 = nextSlot.left
		slot.rightRail.Attachment1 = nextSlot.right

		-- Fade and warm the end at the player (segments counted from it).
		local fromTail = segments - index
		local nearAlpha = math.clamp((fromTail + 1) / FADE_SEGMENTS, 0, 1) * opacity
		local farAlpha = math.clamp(fromTail / FADE_SEGMENTS, 0, 1) * opacity
		slot.ribbon.Transparency =
			NumberSequence.new(1 - nearAlpha * (1 - RIBBON_TRANSPARENCY), 1 - farAlpha * (1 - RIBBON_TRANSPARENCY))
		local railSequence =
			NumberSequence.new(1 - nearAlpha * (1 - RAIL_TRANSPARENCY), 1 - farAlpha * (1 - RAIL_TRANSPARENCY))
		slot.leftRail.Transparency = railSequence
		slot.rightRail.Transparency = railSequence
		local nearWarmth = math.clamp(1 - (fromTail + 1) / (FADE_SEGMENTS * 2), 0, 1)
		local farWarmth = math.clamp(1 - fromTail / (FADE_SEGMENTS * 2), 0, 1)
		slot.ribbon.Color = ColorSequence.new(COLOR:Lerp(TAIL_COLOR, nearWarmth), COLOR:Lerp(TAIL_COLOR, farWarmth))
		slot.ribbon.Enabled = true
		slot.leftRail.Enabled = true
		slot.rightRail.Enabled = true
	end
	self:_hideFrom(segments + 1)
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

-- Points the path at `target` (a model, part, attachment or position).
function GuideBeamController.PointTo(self: typeof(GuideBeamController), target: Instance | Vector3)
	self._target = target
	self._arrived = false
	self._goal = {}
	self._goalNormal = {}
	self._goalCount = 0
	self._drawn = {}
	self._drawnNormal = {}
	self._lastFrom = nil
	self._lastTo = nil
	self._lastCompute = -math.huge
end

-- Fades the path out.
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
	local markers = ReplicatedStorage:FindFirstChild("GameAssets")
	markers = markers and markers:FindFirstChild("MobileHitMarkers")
	local arrowPart = markers and markers:FindFirstChild("ArrowBeamPart")
	local arrow = arrowPart and arrowPart:FindFirstChild("ArrowBeam")
	if arrow and arrow:IsA("Beam") and arrow.Texture ~= "" then
		self._texture = arrow.Texture
	end

	Players.LocalPlayer:GetAttributeChangedSignal(Attributes.GuideTarget):Connect(function()
		self:_onGuideTarget()
	end)
	self:_onGuideTarget()

	RunService.RenderStepped:Connect(function(dt: number)
		self:_step(dt)
	end)
end

return GuideBeamController
