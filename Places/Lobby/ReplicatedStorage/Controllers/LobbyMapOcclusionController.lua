--!strict
--[[
	Module: LobbyMapOcclusionController.lua
	Description:
	Keeps the local player readable behind the hub's map (2026-11-11), on
	this client only. Watches two folders under
	workspace.IgnoreInstances.Map:

	  BUILDINGS  Map.Buildings. While any visible part of one sits between
	             the camera and the player, the player's character gets a
	             see-through white wash drawn over everything
	             (MapOcclusionHighlight, AlwaysOnTop, the dungeon
	             occlusion look). The buildings themselves never fade.
	  TREES      Map.Tree (each direct child of the folder is a tree), its
	             two halves faded apart. The canopy (Leaves, to
	             max(authored, LEAVES_FADE_TRANSPARENCY)) while it covers
	             the player or fills LEAVES_SCREEN_SHARE of the screen; the
	             trunk and its decor (to max(authored,
	             TRUNK_FADE_TRANSPARENCY)) only while the trunk covers the
	             player. Either covering also lights the same wash. Each
	             comes back TREE_RELEASE_SECONDS after it stops.
	             Covering is tested against the tree's shape
	             (LEAVES_SHAPE_SCALE, TRUNK_CLEARANCE), not the canopy's
	             collision box.
	  WIND       Every "Leaves" part under Map.Tree gets the WindShake tag
	             (WindShakeController sways tagged parts; a tag on the tree
	             Model itself does nothing). Leaves added later are tagged
	             too. Per-part WindPower / WindSpeed attributes still tune
	             the sway.

	Buildings: camera:GetPartsObscuringTarget on the head, the root and
	the legs, every CHECK_INTERVAL, the local character ignored. Parts
	authored fully invisible (helpers, spots) never count.
]]

--[ Roblox Services ]--

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

--[ Constants ]--

local IGNORE_INSTANCES_NAME = "IgnoreInstances"
local MAP_NAME = "Map"
local BUILDINGS_NAME = "Buildings"
local TREES_NAME = "Tree"
local LEAVES_NAME = "Leaves"
local WIND_SHAKE_TAG = "WindShake"
local MAP_WAIT_SECONDS = 30

-- How often the camera is checked.
local CHECK_INTERVAL = 1 / 20
-- The points checked, relative to the HumanoidRootPart: head, chest, legs.
local BODY_OFFSETS = { Vector3.new(0, 1.5, 0), Vector3.new(0, 0, 0), Vector3.new(0, -2.5, 0) }
-- A part at least this transparent (as authored) never covers anyone.
local INVISIBLE_TRANSPARENCY = 0.95

-- A faded tree's parts go to at least these (2026-11-11: one 0.6, then
-- 0.75, for the whole tree hid the player under a dark canopy at night):
-- the Leaves nearly gone, the trunk and its decor half see-through.
local LEAVES_FADE_TRANSPARENCY = 0.95
local TRUNK_FADE_TRANSPARENCY = 0.5
-- A tree also fades, with no wash on the player, while its canopy fills
-- at least this share of the screen (2026-11-11: a canopy right under
-- the camera covering half the view while the player stood clear of it).
-- The share is the Leaves box's on-screen outline, clipped to the screen
-- (leavesScreenShare).
local LEAVES_SCREEN_SHARE = 0.2
-- Trees are tested against their SHAPE, not their parts' collision: the
-- leaves mesh is Box fidelity (a 40-stud block of air around the canopy)
-- and the trunk's hull takes in its roots, so a ray test faded a tree the
-- moment the player stood beside it. The canopy is the ellipsoid inside
-- the Leaves part's box, shrunk to LEAVES_SHAPE_SCALE; a trunk (a part
-- named "...Trunk") is raycast alone, on its own collision geometry
-- (segmentHitsTrunk), and a hit within TRUNK_CLEARANCE studs of the point
-- checked does not count.
local LEAVES_SHAPE_SCALE = 0.85
local TRUNK_CLEARANCE = 1.5
-- The canopy box's corners, for its screen outline.
local BOX_CORNERS: { Vector3 } = {}
for _, x in { -1, 1 } do
	for _, y in { -1, 1 } do
		for _, z in { -1, 1 } do
			table.insert(BOX_CORNERS, Vector3.new(x, y, z))
		end
	end
end
-- Its twelve edges (corner pairs differing on one axis), and the depth
-- in front of the camera it is clipped at.
local BOX_EDGES: { { number } } = {}
for a = 1, 8 do
	for b = a + 1, 8 do
		local difference = BOX_CORNERS[a] - BOX_CORNERS[b]
		if math.abs(difference.X) + math.abs(difference.Y) + math.abs(difference.Z) == 2 then
			table.insert(BOX_EDGES, { a, b })
		end
	end
end
local NEAR_DEPTH = 0.5
local trunkParams = RaycastParams.new()
trunkParams.FilterType = Enum.RaycastFilterType.Include
-- The fade in and out (2026-11-11: a slower Sine, was 0.2 s Quad).
local TREE_FADE_TWEEN = TweenInfo.new(0.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
-- A canopy or trunk stays faded this long after the last check that
-- wanted it faded, so walking along its edge does not strobe it.
local TREE_RELEASE_SECONDS = 0.5

-- The wash behind buildings: the dungeons' occlusion look (white fill at
-- 0.65, no outline, drawn through walls).
local HIGHLIGHT_NAME = "MapOcclusionHighlight"
local HIGHLIGHT_COLOR = Color3.fromRGB(255, 255, 255)
local HIGHLIGHT_FILL_TRANSPARENCY = 0.65

--[ Module ]--

local LobbyMapOcclusionController = {
	Name = "LobbyMapOcclusionController",
}

local player = Players.LocalPlayer

local buildingsFolder: Instance? = nil
local treesFolder: Instance? = nil

-- Each part's authored transparency, cached the first time it is faded.
local authored: { [BasePart]: number } = {}
-- Faded canopies and faded trunks, apart (2026-11-11: a canopy filling
-- the screen faded the trunk beside the player too): os.clock() of the
-- last check that wanted each one faded.
local fadedLeaves: { [Instance]: number } = {}
local fadedTrunks: { [Instance]: number } = {}

local highlight: Highlight? = nil

--[ Helpers ]--

local function authoredTransparency(part: BasePart): number
	local cached = authored[part]
	if cached then
		return cached
	end
	return part.Transparency
end

-- Fades (or restores) one half of `tree`: its Leaves, or everything
-- else (the trunk and its decor).
local function setTreeFaded(tree: Instance, leaves: boolean, faded: boolean)
	local fadeTo = if leaves then LEAVES_FADE_TRANSPARENCY else TRUNK_FADE_TRANSPARENCY
	for _, descendant in tree:GetDescendants() do
		if descendant:IsA("BasePart") and (descendant.Name == LEAVES_NAME) == leaves then
			if authored[descendant] == nil then
				authored[descendant] = descendant.Transparency
			end
			local base = authored[descendant]
			local goal = if faded then math.max(base, fadeTo) else base
			if descendant.Transparency ~= goal then
				TweenService:Create(descendant, TREE_FADE_TWEEN, { Transparency = goal }):Play()
			end
		end
	end
end

-- Marks one half of `tree` as wanted faded this check.
local function holdFaded(faded: { [Instance]: number }, tree: Instance, leaves: boolean, now: number)
	if faded[tree] == nil then
		setTreeFaded(tree, leaves, true)
	end
	faded[tree] = now
end

-- Restores the halves no check has wanted faded for TREE_RELEASE_SECONDS.
local function releaseFaded(faded: { [Instance]: number }, leaves: boolean, now: number)
	for tree, lastSeen in faded do
		if now - lastSeen > TREE_RELEASE_SECONDS or tree.Parent == nil then
			faded[tree] = nil
			if tree.Parent then
				setTreeFaded(tree, leaves, false)
			end
		end
	end
end

-- Whether the segment from `from` to `to` passes through the ellipsoid
-- at `cframe` with semi-axes `radii`.
local function segmentHitsEllipsoid(from: Vector3, to: Vector3, cframe: CFrame, radii: Vector3): boolean
	local a = cframe:PointToObjectSpace(from) / radii
	local b = cframe:PointToObjectSpace(to) / radii
	local d = b - a
	local dd = d:Dot(d)
	if dd < 1e-9 then
		return a.Magnitude <= 1
	end
	-- The closest point on the segment to the centre, inside the unit sphere.
	local t = math.clamp(-a:Dot(d) / dd, 0, 1)
	return (a + d * t).Magnitude <= 1
end

-- Whether the trunk `part` is between `from` (the camera) and `to`: a
-- ray against the trunk alone (2026-11-11; an upright column from its box
-- was wide enough with the roots to catch a player standing beside it).
-- The trunk's own collision geometry follows its mesh; a hit within
-- TRUNK_CLEARANCE of the player is the player's own spot, not cover.
local function segmentHitsTrunk(from: Vector3, to: Vector3, part: BasePart): boolean
	trunkParams.FilterDescendantsInstances = { part }
	local delta = to - from
	local hit = workspace:Raycast(from, delta, trunkParams)
	return hit ~= nil and (to - hit.Position).Magnitude > TRUNK_CLEARANCE
end

-- Whether `tree`'s canopy, and whether its trunk, sits between `from`
-- (the camera) and any of `points`.
local function treeCovers(tree: Instance, from: Vector3, points: { Vector3 }): (boolean, boolean)
	local leavesCover, trunkCovers = false, false
	for _, part in tree:GetDescendants() do
		if not part:IsA("BasePart") then
			continue
		end
		local isLeaves = part.Name == LEAVES_NAME
		local isTrunk = not isLeaves and string.find(string.lower(part.Name), "trunk", 1, true) ~= nil
		if not isLeaves and not isTrunk then
			continue
		end
		for _, point in points do
			if isLeaves and not leavesCover then
				leavesCover = segmentHitsEllipsoid(from, point, part.CFrame, part.Size / 2 * LEAVES_SHAPE_SCALE)
			elseif isTrunk and not trunkCovers then
				trunkCovers = segmentHitsTrunk(from, point, part)
			end
		end
	end
	return leavesCover, trunkCovers
end

-- 2D convex hull (monotone chain), counter-clockwise.
local function convexHull(points: { Vector2 }): { Vector2 }
	table.sort(points, function(a: Vector2, b: Vector2)
		return a.X < b.X or (a.X == b.X and a.Y < b.Y)
	end)
	local function cross(o: Vector2, a: Vector2, b: Vector2): number
		return (a.X - o.X) * (b.Y - o.Y) - (a.Y - o.Y) * (b.X - o.X)
	end
	local hull: { Vector2 } = {}
	for _, point in points do
		while #hull >= 2 and cross(hull[#hull - 1], hull[#hull], point) <= 0 do
			table.remove(hull)
		end
		table.insert(hull, point)
	end
	local lowerCount = #hull + 1
	for index = #points - 1, 1, -1 do
		local point = points[index]
		while #hull >= lowerCount and cross(hull[#hull - 1], hull[#hull], point) <= 0 do
			table.remove(hull)
		end
		table.insert(hull, point)
	end
	table.remove(hull)
	return hull
end

-- `polygon` clipped to the rectangle 0..size (Sutherland-Hodgman).
local function clipToRect(polygon: { Vector2 }, size: Vector2): { Vector2 }
	local edges = {
		function(p: Vector2): number
			return p.X
		end,
		function(p: Vector2): number
			return size.X - p.X
		end,
		function(p: Vector2): number
			return p.Y
		end,
		function(p: Vector2): number
			return size.Y - p.Y
		end,
	}
	local output = polygon
	for _, inside in edges do
		local input = output
		output = {}
		for index, current in input do
			local previous = input[if index == 1 then #input else index - 1]
			local currentIn, previousIn = inside(current) >= 0, inside(previous) >= 0
			if currentIn ~= previousIn then
				local a, b = inside(previous), inside(current)
				table.insert(output, previous:Lerp(current, a / (a - b)))
			end
			if currentIn then
				table.insert(output, current)
			end
		end
		if #output == 0 then
			break
		end
	end
	return output
end

local function polygonArea(polygon: { Vector2 }): number
	local area = 0
	for index, current in polygon do
		local nextPoint = polygon[if index == #polygon then 1 else index + 1]
		area += current.X * nextPoint.Y - nextPoint.X * current.Y
	end
	return math.abs(area) / 2
end

-- The share of the screen `tree`'s canopy covers: the Leaves part's box
-- projected, its outline (convex hull of the eight corners) clipped to
-- the screen. The canopy mesh fills nearly all of its box (2026-11-11: an
-- ellipsoid inside it read a canopy over half the view as 6%).
local function leavesScreenShare(tree: Instance, camera: Camera): number
	local leaves = tree:FindFirstChild(LEAVES_NAME, true)
	if not leaves or not leaves:IsA("BasePart") then
		return 0
	end
	local viewport = camera.ViewportSize
	if viewport.X <= 0 or viewport.Y <= 0 then
		return 0
	end
	local half = leaves.Size / 2
	local cframe = leaves.CFrame
	local cameraCFrame = camera.CFrame
	-- Corners in camera space, depth = distance in front of the camera.
	local points: { Vector3 } = {}
	local depths: { number } = {}
	for index, corner in BOX_CORNERS do
		local local_ = cameraCFrame:PointToObjectSpace(cframe:PointToWorldSpace(corner * half))
		points[index] = local_
		depths[index] = -local_.Z
	end
	-- The box clipped at the near plane: the corners in front, and where
	-- each edge crosses the plane. (A corner behind the camera projects
	-- nonsense; this box is often beside the camera, part behind it.)
	local front: { Vector3 } = {}
	for index, point in points do
		if depths[index] >= NEAR_DEPTH then
			table.insert(front, point)
		end
	end
	for _, edge in BOX_EDGES do
		local da, db = depths[edge[1]], depths[edge[2]]
		if (da >= NEAR_DEPTH) ~= (db >= NEAR_DEPTH) then
			table.insert(front, points[edge[1]]:Lerp(points[edge[2]], (NEAR_DEPTH - da) / (db - da)))
		end
	end
	if #front == 0 then
		return 0
	end
	local projected: { Vector2 } = {}
	for _, point in front do
		local screen = camera:WorldToViewportPoint(cameraCFrame:PointToWorldSpace(point))
		table.insert(projected, Vector2.new(screen.X, screen.Y))
	end
	local outline = clipToRect(convexHull(projected), viewport)
	if #outline < 3 then
		return 0
	end
	return polygonArea(outline) / (viewport.X * viewport.Y)
end

local function tagLeaves(instance: Instance)
	if instance.Name == LEAVES_NAME and instance:IsA("BasePart") and not instance:HasTag(WIND_SHAKE_TAG) then
		CollectionService:AddTag(instance, WIND_SHAKE_TAG)
	end
end

local function ensureHighlight(character: Model): Highlight
	local existing = highlight
	if existing and existing.Parent == character then
		return existing
	end
	local made = Instance.new("Highlight")
	made.Name = HIGHLIGHT_NAME
	made.Adornee = character
	made.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	made.FillColor = HIGHLIGHT_COLOR
	made.FillTransparency = HIGHLIGHT_FILL_TRANSPARENCY
	made.OutlineTransparency = 1
	made.Enabled = false
	made.Parent = character
	highlight = made
	return made
end

--[ The check ]--

local function check()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local camera = workspace.CurrentCamera
	if not character or not root or not root:IsA("BasePart") or not camera then
		return
	end

	local points = table.create(#BODY_OFFSETS)
	for _, offset in BODY_OFFSETS do
		table.insert(points, root.Position + offset)
	end
	local covering = camera:GetPartsObscuringTarget(points, { character })

	local covered = false
	local now = os.clock()
	for _, part in covering do
		if authoredTransparency(part) >= INVISIBLE_TRANSPARENCY then
			continue
		end
		if buildingsFolder and part:IsDescendantOf(buildingsFolder) then
			covered = true
			break
		end
	end

	-- Trees by shape (see LEAVES_SHAPE_SCALE), each half on its own: the
	-- canopy fades while it covers the player or fills the screen, the
	-- trunk only while IT covers the player. Either covering also lights
	-- the player's wash, so they read under the canopy.
	local trees = treesFolder
	if trees then
		local from = camera.CFrame.Position
		for _, tree in trees:GetChildren() do
			local leavesCover, trunkCovers = treeCovers(tree, from, points)
			if leavesCover or leavesScreenShare(tree, camera) >= LEAVES_SCREEN_SHARE then
				holdFaded(fadedLeaves, tree, true, now)
			end
			if trunkCovers then
				holdFaded(fadedTrunks, tree, false, now)
			end
			covered = covered or leavesCover or trunkCovers
		end
	end
	releaseFaded(fadedLeaves, true, now)
	releaseFaded(fadedTrunks, false, now)

	local wash = ensureHighlight(character)
	if wash.Enabled ~= covered then
		wash.Enabled = covered
	end
end

--[ Lifecycle ]--

function LobbyMapOcclusionController.Start(_self: typeof(LobbyMapOcclusionController))
	task.spawn(function()
		local ignore = workspace:WaitForChild(IGNORE_INSTANCES_NAME, MAP_WAIT_SECONDS)
		local map = ignore and ignore:WaitForChild(MAP_NAME, MAP_WAIT_SECONDS)
		if not map then
			return
		end
		buildingsFolder = map:FindFirstChild(BUILDINGS_NAME)
		treesFolder = map:FindFirstChild(TREES_NAME)

		local trees = treesFolder
		if trees then
			for _, descendant in trees:GetDescendants() do
				tagLeaves(descendant)
			end
			trees.DescendantAdded:Connect(tagLeaves)
		end

		while true do
			check()
			task.wait(CHECK_INTERVAL)
		end
	end)
end

return LobbyMapOcclusionController
