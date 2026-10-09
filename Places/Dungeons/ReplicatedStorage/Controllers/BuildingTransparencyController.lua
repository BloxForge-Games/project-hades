--!strict
--[[
	Module: BuildingTransparencyController.lua
	Description:
	Keeps the local player visible around map buildings (models tagged
	TagList.Building -- the static Map.Buildings set and every chunk's
	relocated Buildings, see DungeonGenerator._relocateChunkBuildings).

	Two fades, evaluated every THREAD_LOOP_WAIT (on OcclusionController's
	shared pass, throttled to that cadence):
	  * OCCLUDED  -- the building sits between the camera and the player
	                 (the parts covering the head, root, chest and legs,
	                 read from OcclusionController's single per-tick
	                 query). The WHOLE model goes semi-transparent,
	                 textures and decals included, so a pillar never
	                 hides the player.
	  * NEAR      -- the building is within MAX_STUD_RAYCAST_DIST of the
	                 player. Only its "Roof" parts fade (walking into a
	                 house shows the inside without dissolving the walls).
	Occluded wins when both apply.

	Every fade restores to the AUTHORED transparency, cached on first touch
	(a part authored at 0.4 comes back at 0.4, an invisible helper part
	stays invisible), never to a hard-coded 0 / 0.7.

	PILLARS (TagList.Pillar) are faded as ONE unit. Their parts are SET, not
	tweened -- every block and texture lands on the same value in the same
	frame, so no two blocks ever read differently mid-tween -- and the fade
	HOLDS for PILLAR_RELEASE_SECONDS after the last frame that saw the
	pillar occluding, so circling it (the cast flicking on and off at the
	edge) does not strobe the whole column. Pillars have no roof, so the
	near fade does nothing to them: occluded or not, nothing in between.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local IgnoreListController = require(ReplicatedStorage.Controllers.IgnoreListController)
local OcclusionController = require(ReplicatedStorage.Controllers.OcclusionController)
local Arcane = require(ReplicatedStorage.Submodules.Core.Source.Network.Arcane)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local onDamageIndicator = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Highlight.onDamageIndicator)

-- Faded transparency for parts and for their Textures / Decals. Applied as
-- max(authored, value): anything authored MORE transparent keeps its own.
local PART_FADE_TRANSPARENCY = 0.75
local SURFACE_FADE_TRANSPARENCY = 0.9
local MAX_STUD_RAYCAST_DIST = 10
local ROOF_STRING = "Roof"
local THREAD_LOOP_WAIT = 0.15
local FADE_TWEEN_INFO = TweenInfo.new(0.15, Enum.EasingStyle.Quad)
-- A pillar stays faded this long after the last tick that saw it between
-- the camera and the player. Longer than one loop so an edge flicker
-- (one tick occluded, next not) never reaches the parts.
local PILLAR_RELEASE_SECONDS = 0.4
-- (The extra cast heights -- so a pillar covering only the legs or only
-- the chest still counts as occluding -- are OcclusionController's body
-- points now.)

-- Cached authored transparency, stamped on the instance the first time a
-- fade touches it.
local AUTHORED_TRANSPARENCY_ATTRIBUTE = "AuthoredTransparency"

-- The ObjectValue CollisionGroupService:SetupBuilding leaves on a Base
-- part it moves to IgnoreInstances.Terrain, pointing back at its building.
local BUILDING_REF_NAME = "Building"

-- The Base-part index is keyed by building Models that die with the
-- floor: weak keys.
local WEAK_KEYS = { __mode = "k" }

-- Fade modes per building.
local MODE_WHOLE = "whole"
local MODE_ROOF = "roof"

local BuildingTransparencyController = {
	Name = "BuildingTransparencyController",
	Dependencies = { IgnoreListController, OcclusionController } :: { any },

	_buildingIgnoreList = {},
	-- [building Model] = MODE_WHOLE | MODE_ROOF for every building currently faded.
	_activeModes = {} :: { [Model]: string },
	-- [pillar Model] = os.clock() deadline the whole-fade holds until.
	_pillarHoldUntil = {},
	-- [building Model] = its Base parts under IgnoreInstances.Terrain (and
	-- their descendants), indexed ONCE as they arrive (see
	-- _watchTerrainParts) instead of re-walking the whole Terrain folder
	-- per held pillar per tick.
	_basePartsByBuilding = setmetatable({}, WEAK_KEYS) :: any,
	-- [Base part] = the building it was indexed under, for removal.
	_basePartBuilding = {} :: { [Instance]: Model },
	-- os.clock() of the last tick this controller ran on the shared pass.
	_lastTickAt = 0,
}

--[ Private ]--

local function isFadeable(instance: Instance): boolean
	return instance:IsA("BasePart") or instance:IsA("Texture") or instance:IsA("Decal")
end

local function isRoof(instance: Instance): boolean
	if instance:IsA("BasePart") then
		return instance.Name == ROOF_STRING
	end
	return instance.Parent ~= nil and instance.Parent.Name == ROOF_STRING
end

local function authoredTransparency(instance: Instance): number
	local cached = instance:GetAttribute(AUTHORED_TRANSPARENCY_ATTRIBUTE)
	if typeof(cached) == "number" then
		return cached
	end
	local current = (instance :: any).Transparency
	instance:SetAttribute(AUTHORED_TRANSPARENCY_ATTRIBUTE, current)
	return current
end

local function tweenTransparency(instance: Instance, target: number)
	if math.abs((instance :: any).Transparency - target) < 0.005 then
		return
	end
	TweenService:Create(instance, FADE_TWEEN_INFO, { Transparency = target }):Play()
end

local function isPillar(building: Model): boolean
	return building:HasTag(TagList.Pillar)
end

-- Applies `mode` to every fadeable descendant of `building` (and its Base
-- parts, `extras` -- see _basePartsByBuilding): the selected ones go to
-- their faded value, the rest back to authored. nil = restore all.
--
-- A PILLAR is written directly (no tween): one value, every part, this
-- frame. Tweens are what let two blocks of the same column disagree --
-- a block still easing toward 0.85 when the mode flipped back to restore
-- started its return from wherever it was, while its neighbour started
-- from 0.85.
local function applyMode(building: Model, mode: string?, extras: { Instance }?)
	local instant = isPillar(building)
	local instances = building:GetDescendants()
	if extras then
		table.move(extras, 1, #extras, #instances + 1, instances)
	end
	for _, instance in instances do
		if not isFadeable(instance) then
			continue
		end
		local authored = authoredTransparency(instance)
		local selected = mode == MODE_WHOLE or (mode == MODE_ROOF and isRoof(instance))
		local target = authored
		if selected then
			local fade = if instance:IsA("BasePart") then PART_FADE_TRANSPARENCY else SURFACE_FADE_TRANSPARENCY
			target = math.max(authored, fade)
		end
		if instant then
			(instance :: any).Transparency = target
		else
			tweenTransparency(instance, target)
		end
	end
end

-- The tagged Building this part belongs to. Walks EVERY ancestor rather
-- than stopping at the nearest Model: a pillar's torch sits in a nested
-- TorchModel, and the nearest-Model lookup resolved those parts to the
-- torch (untagged, so ignored) instead of the pillar.
local function buildingOf(part: BasePart): Model?
	local ancestor = part.Parent
	while ancestor and ancestor ~= workspace do
		if ancestor:IsA("Model") and ancestor:HasTag(TagList.Building) then
			-- Re-fogged locally (FogOfWarController): it is behind a sealed
			-- gate and its parts sit at the fog value on purpose. Fading or
			-- "restoring" it here would drag it back into view.
			if ancestor:GetAttribute(Attributes.LocalFogged) == true then
				return nil
			end
			return ancestor
		end
		ancestor = ancestor.Parent
	end
	return nil
end

-- A building's "Base" parts live under IgnoreInstances.Terrain (moved there
-- by CollisionGroupService:SetupBuilding, which leaves a `Building`
-- ObjectValue on each pointing back). They fade with the building, so each
-- is indexed under it the moment it arrives. The reference (and the
-- building it points at) can replicate a step after the part, so the
-- index waits for whichever is missing.
function BuildingTransparencyController._indexTerrainPart(self: typeof(BuildingTransparencyController), part: Instance)
	local ref = part:FindFirstChild(BUILDING_REF_NAME)
	if not (ref and ref:IsA("ObjectValue")) then
		local connection: RBXScriptConnection
		connection = part.ChildAdded:Connect(function(child)
			if child.Name == BUILDING_REF_NAME and child:IsA("ObjectValue") then
				connection:Disconnect()
				self:_indexTerrainPart(part)
			end
		end)
		return
	end
	local building = ref.Value
	if not (building and building:IsA("Model")) then
		ref:GetPropertyChangedSignal("Value"):Once(function()
			self:_indexTerrainPart(part)
		end)
		return
	end
	if self._basePartBuilding[part] then
		return
	end
	local parts = self._basePartsByBuilding[building] or {}
	self._basePartsByBuilding[building] = parts
	table.insert(parts, part)
	for _, descendant in part:GetDescendants() do
		table.insert(parts, descendant)
	end
	self._basePartBuilding[part] = building
end

function BuildingTransparencyController._unindexTerrainPart(
	self: typeof(BuildingTransparencyController),
	part: Instance
)
	local building = self._basePartBuilding[part]
	if not building then
		return
	end
	self._basePartBuilding[part] = nil
	local parts = self._basePartsByBuilding[building]
	if not parts then
		return
	end
	-- The part and everything indexed under it.
	for index = #parts, 1, -1 do
		local indexed = parts[index]
		if indexed == part or indexed:IsDescendantOf(part) then
			table.remove(parts, index)
		end
	end
	if #parts == 0 then
		self._basePartsByBuilding[building] = nil
	end
end

function BuildingTransparencyController._watchTerrainParts(self: typeof(BuildingTransparencyController))
	local terrain = workspace.IgnoreInstances:FindFirstChild("Terrain")
	if not terrain then
		return
	end
	for _, part in terrain:GetChildren() do
		self:_indexTerrainPart(part)
	end
	terrain.ChildAdded:Connect(function(part)
		self:_indexTerrainPart(part)
	end)
	terrain.ChildRemoved:Connect(function(part)
		self:_unindexTerrainPart(part)
	end)
end

function BuildingTransparencyController._buildingProximityFunction(
	self: typeof(BuildingTransparencyController),
	overlapParams: OverlapParams
)
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end

	local desired: { [Model]: string } = {}

	-- NEAR: roof-only fade for buildings around the player.
	for _, part in workspace:GetPartBoundsInRadius(root.Position, MAX_STUD_RAYCAST_DIST, overlapParams) do
		local building = buildingOf(part)
		if building then
			desired[building] = desired[building] or MODE_ROOF
		end
	end

	-- OCCLUDED: whole-model fade for anything between the camera and the
	-- player. The shared pass casts on several points (root, head, legs,
	-- chest) so a pillar covering only part of the body still counts.
	-- Wins over the roof fade.
	local now = os.clock()
	for _, part in OcclusionController:GetPlayerOccluders() do
		local building = buildingOf(part)
		if building then
			desired[building] = MODE_WHOLE
			if isPillar(building) then
				self._pillarHoldUntil[building] = now + PILLAR_RELEASE_SECONDS
			end
		end
	end

	-- PILLARS: no roof mode (nothing to fade), and the whole fade HOLDS
	-- through the release window after the last occluding tick.
	for building, mode in desired do
		if isPillar(building) and mode == MODE_ROOF then
			desired[building] = nil
		end
	end
	for pillar, holdUntil in self._pillarHoldUntil do
		if pillar.Parent and now < holdUntil then
			desired[pillar] = MODE_WHOLE
		else
			self._pillarHoldUntil[pillar] = nil
		end
	end

	-- Apply the changes: new / changed modes, then restores for buildings
	-- that dropped out.
	for building, mode in desired do
		if not building.Parent then
			continue
		end
		-- Apply on change -- and RE-ASSERT every tick while a pillar is
		-- held faded. The pillar set is instant and idempotent, so that
		-- costs a handful of property writes, and it means no other writer
		-- can leave a single block of a covering pillar visible for longer
		-- than one tick.
		local changed = self._activeModes[building] ~= mode
		local heldPillar = mode == MODE_WHOLE and isPillar(building)
		if changed or heldPillar then
			applyMode(building, mode, self._basePartsByBuilding[building])
		end
	end
	for building in self._activeModes do
		if not desired[building] and building.Parent then
			applyMode(building, nil, self._basePartsByBuilding[building])
		end
	end

	self._activeModes = desired
end

--[ Lifecycle ]--

function BuildingTransparencyController.Start(self: typeof(BuildingTransparencyController))
	self._buildingIgnoreList = IgnoreListController:GetBuildingTransparencyIgnoreList()

	local overlapParams = OverlapParams.new()
	overlapParams.FilterDescendantsInstances = self._buildingIgnoreList
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude

	-- A broken piece leaves its building (it is reparented to ArcaneSpells
	-- and flung): it comes back to its authored look on its own, whatever
	-- fade its building was under.
	Arcane.BuildingsBroken.On(function(parts)
		for _, part in parts do
			-- A piece destroyed before this arrived is nil in the list.
			if not part or not part.Parent then
				continue
			end
			part.Transparency = authoredTransparency(part)
			for _, instance in part:GetDescendants() do
				if instance:IsA("Texture") or instance:IsA("Decal") then
					TweenService:Create(
						instance,
						TweenInfo.new(0.25, Enum.EasingStyle.Quad),
						{ Transparency = authoredTransparency(instance) }
					):Play()
				end
			end

			onDamageIndicator(part)
		end
	end)

	self:_watchTerrainParts()

	-- Rides the shared occlusion pass, at this controller's own cadence:
	-- the pass runs faster than THREAD_LOOP_WAIT, and a held pillar is
	-- re-asserted (every part written) on every tick this runs, so it
	-- keeps the slower clock it was tuned at.
	OcclusionController.OnPass:Connect(function()
		local now = os.clock()
		if now - self._lastTickAt < THREAD_LOOP_WAIT then
			return
		end
		self._lastTickAt = now
		self:_buildingProximityFunction(overlapParams)
	end)
end

return BuildingTransparencyController
