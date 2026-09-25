--!strict
--[[
	Module: OcclusionController.lua
	Description:
	ONE camera-occlusion pass per tick for everything on this client that
	wants to know "is something between the camera and X". Three systems
	used to ask on their own schedules with their own ignore lists:
	WallsTransparencyController every frame (cloning its ignore list each
	time), BuildingTransparencyController at 0.15 s, and
	CharacterHighlightController at 40 Hz with one
	Camera:GetPartsObscuringTarget PER ZOMBIE -- 30-50 mobs came to well
	over a thousand queries a second. They read from here now.

	Per pass, at OCCLUSION_HZ:
	  * the LOCAL PLAYER: one query on the head (what the wall fade and
	    the through-wall highlight key on) and one on the body points
	    (root, chest, legs -- so a pillar covering only the legs still
	    counts for the building fade). The occluding parts are published
	    as lists for the fade consumers.
	  * every TRACKED target (the mobs, one point each): ONE batched query
	    over all their points. Empty -- nothing between the camera and any
	    of them, the common case in the open -- and every target is clear
	    with no further work. Otherwise each target is attributed with a
	    single raycast restricted (Include filter) to the parts that query
	    returned, which is a first-hit raycast against a handful of parts
	    rather than another full obscuring-parts collection per target.

	ONE ignore list, shared: the folders every consumer skips plus the
	local character, rebuilt only when the character changes (a respawn
	used to leave the old body baked into the highlight's list forever).
	Other players' characters are deliberately NOT in it -- a teammate
	stepping between the camera and you should light your highlight -- so
	the wall fade filters them out of its hits instead.

	Results are a snapshot of the last pass: IsOccluded(target) and the
	player occluder lists read what the last tick found, and OnPass fires
	once per tick after they are updated for consumers that act on the
	pass itself.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.Submodules.Core.Shared.Types.Signal)

--[ Constants ]--

-- Pass cadence. 30 Hz: the wall fade tween is 0.25 s and the highlight
-- ramps run on their own 40 Hz tick, so a third of a frame of latency on
-- the occlusion answer is invisible, and it is a quarter fewer queries
-- than the highlight loop alone used to make.
local OCCLUSION_HZ = 30
local OCCLUSION_INTERVAL = 1 / OCCLUSION_HZ

-- The extra body points (relative to the root) the building / pillar
-- fade casts on, so a pillar covering only the legs or only the chest
-- still counts as occluding. The head is its own query.
local PLAYER_BODY_CAST_OFFSETS = { Vector3.new(0, -2.5, 0), Vector3.new(0, 1.5, 0) }

-- Everything no consumer ever wants as an occluder, by path under
-- workspace. Resolved once per ignore-list build.
local IGNORED_FOLDER_PATHS = {
	{ "IgnoreInstances", "Terrain" },
	{ "IgnoreInstances", "Boundaries" },
	{ "IgnoreInstances", "MapMarkers" },
	{ "IgnoreInstances", "MagicSpells" },
	{ "IgnoreInstances", "Drops" },
	{ "IgnoreInstances", "Zombies" },
	{ "IgnoreInstances", "DeadZombies" },
	{ "PlayerBaseplates" },
}

--[ Controller ]--

local OcclusionController = {
	Name = "OcclusionController",

	-- Fired once per pass, after every result below is updated.
	OnPass = Signal.new() :: Signal.Signal<>,

	-- [tracked instance] = the part whose position is tested.
	_targets = {} :: { [Instance]: BasePart },
	-- [tracked instance | local character] = last pass's answer.
	_occluded = {} :: { [Instance]: boolean },
	-- Parts between the camera and the local player's HEAD, last pass.
	_playerHeadOccluders = {} :: { BasePart },
	-- Parts between the camera and ANY of the local player's points (head
	-- and body), last pass. May repeat a part the head list has.
	_playerOccluders = {} :: { BasePart },

	_ignoreList = {} :: { Instance },
	-- The character the ignore list was built for; a mismatch rebuilds it.
	_ignoreListCharacter = nil :: Model?,
}

--[ Private ]--

-- Scratch lists reused across passes so a tick allocates nothing but the
-- engine's own result arrays.
local castPoints: { Vector3 } = {}
local castTargets: { Instance } = {}
local bodyPoints: { Vector3 } = {}

-- The attribution raycast: restricted to the parts the batched query
-- found, so it is a first hit against a handful of candidates.
local attributionParams = RaycastParams.new()
attributionParams.FilterType = Enum.RaycastFilterType.Include

local function resolvePath(path: { string }): Instance?
	local current: Instance? = workspace
	for _, name in path do
		current = if current then current:FindFirstChild(name) else nil
	end
	return current
end

function OcclusionController._rebuildIgnoreList(self: typeof(OcclusionController), character: Model?)
	local list: { Instance } = { workspace.Terrain, workspace.CurrentCamera }
	for _, path in IGNORED_FOLDER_PATHS do
		local folder = resolvePath(path)
		if folder then
			table.insert(list, folder)
		end
	end
	if character then
		table.insert(list, character)
	end
	-- The body this list was built for is gone (respawn): its answer too.
	if self._ignoreListCharacter and self._ignoreListCharacter ~= character then
		self._occluded[self._ignoreListCharacter] = nil
	end
	self._ignoreList = list
	self._ignoreListCharacter = character
end

function OcclusionController._pass(self: typeof(OcclusionController))
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local cameraPosition = camera.CFrame.Position

	local character = Players.LocalPlayer.Character
	if character ~= self._ignoreListCharacter or #self._ignoreList == 0 then
		self:_rebuildIgnoreList(character)
	end
	local ignoreList = self._ignoreList

	-- THE LOCAL PLAYER. Head first (its own answer), then the body points.
	local head = character and character:FindFirstChild("Head")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local headOccluders: { BasePart } = {}
	local allOccluders: { BasePart } = {}
	if head and head:IsA("BasePart") then
		headOccluders = camera:GetPartsObscuringTarget({ head.Position }, ignoreList)
		table.move(headOccluders, 1, #headOccluders, 1, allOccluders)
	end
	if root and root:IsA("BasePart") then
		table.clear(bodyPoints)
		table.insert(bodyPoints, root.Position)
		for _, offset in PLAYER_BODY_CAST_OFFSETS do
			table.insert(bodyPoints, root.Position + offset)
		end
		local bodyOccluders = camera:GetPartsObscuringTarget(bodyPoints, ignoreList)
		table.move(bodyOccluders, 1, #bodyOccluders, #allOccluders + 1, allOccluders)
	end
	self._playerHeadOccluders = headOccluders
	self._playerOccluders = allOccluders
	if character then
		self._occluded[character] = #headOccluders > 0
	end

	-- THE TRACKED TARGETS: one batched query, then attribution only when
	-- it found anything.
	table.clear(castPoints)
	table.clear(castTargets)
	for target, part in self._targets do
		if not part.Parent then
			self:Untrack(target)
			continue
		end
		table.insert(castPoints, part.Position)
		table.insert(castTargets, target)
	end
	if #castPoints == 0 then
		self.OnPass:Fire()
		return
	end

	local candidates = camera:GetPartsObscuringTarget(castPoints, ignoreList)
	if #candidates == 0 then
		for _, target in castTargets do
			self._occluded[target] = false
		end
	else
		attributionParams.FilterDescendantsInstances = candidates
		for index, target in castTargets do
			local point = castPoints[index]
			local hit = workspace:Raycast(cameraPosition, point - cameraPosition, attributionParams)
			self._occluded[target] = hit ~= nil
		end
	end

	self.OnPass:Fire()
end

--[ Public ]--

-- Adds `instance` to the pass; `part` is the point tested (a mob's Head).
-- Until the next pass IsOccluded answers false for it.
function OcclusionController.Track(self: typeof(OcclusionController), instance: Instance, part: BasePart)
	self._targets[instance] = part
	if self._occluded[instance] == nil then
		self._occluded[instance] = false
	end
end

function OcclusionController.Untrack(self: typeof(OcclusionController), instance: Instance)
	self._targets[instance] = nil
	self._occluded[instance] = nil
end

-- Last pass's answer for a tracked instance or the local character.
-- False for anything untracked.
function OcclusionController.IsOccluded(self: typeof(OcclusionController), instance: Instance): boolean
	return self._occluded[instance] == true
end

-- Parts between the camera and the local player's head, last pass. The
-- returned table is the controller's own snapshot: read it, do not keep
-- or mutate it.
function OcclusionController.GetPlayerHeadOccluders(self: typeof(OcclusionController)): { BasePart }
	return self._playerHeadOccluders
end

-- Parts between the camera and any of the local player's cast points
-- (head, root, chest, legs), last pass. Same snapshot rule as above.
function OcclusionController.GetPlayerOccluders(self: typeof(OcclusionController)): { BasePart }
	return self._playerOccluders
end

--[ Lifecycle ]--

function OcclusionController.Init(self: typeof(OcclusionController))
	self:_rebuildIgnoreList(Players.LocalPlayer.Character)
end

function OcclusionController.Start(self: typeof(OcclusionController))
	-- Own thread, fixed cadence, like the building loop it replaces.
	task.spawn(function()
		while task.wait(OCCLUSION_INTERVAL) do
			self:_pass()
		end
	end)
end

return OcclusionController
