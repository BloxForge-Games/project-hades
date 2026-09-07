--[[
	Module: BuildingTransparencyController.lua
	Description:
	Keeps the local player visible around map buildings (models tagged
	TagList.Building -- the static Map.Buildings set and every chunk's
	relocated Buildings, see DungeonService:_relocateChunkBuildings).

	Two fades, evaluated every THREAD_LOOP_WAIT:
	  * OCCLUDED  -- the building sits between the camera and the player
	                 (Camera:GetPartsObscuringTarget on the head + root).
	                 The WHOLE model goes semi-transparent, textures and
	                 decals included, so a pillar never hides the player.
	  * NEAR      -- the building is within MAX_STUD_RAYCAST_DIST of the
	                 player. Only its "Roof" parts fade (walking into a
	                 house shows the inside without dissolving the walls).
	Occluded wins when both apply.

	Every fade restores to the AUTHORED transparency, cached on first touch
	(a part authored at 0.4 comes back at 0.4, an invisible helper part
	stays invisible), never to a hard-coded 0 / 0.7.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local onDamageIndicator = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Highlight.onDamageIndicator)

local camera: Camera = workspace.CurrentCamera

-- Faded transparency for parts and for their Textures / Decals. Applied as
-- max(authored, value): anything authored MORE transparent keeps its own.
local PART_FADE_TRANSPARENCY = 0.85
local SURFACE_FADE_TRANSPARENCY = 1
local MAX_STUD_RAYCAST_DIST = 10
local ROOF_STRING = "Roof"
local THREAD_LOOP_WAIT = 0.15
local FADE_TWEEN_INFO = TweenInfo.new(0.15, Enum.EasingStyle.Quad)

-- Cached authored transparency, stamped on the instance the first time a
-- fade touches it.
local AUTHORED_TRANSPARENCY_ATTRIBUTE = "AuthoredTransparency"

-- Fade modes per building.
local MODE_WHOLE = "whole"
local MODE_ROOF = "roof"

local IgnoreListController
local VFXService

local BuildingTransparencyController = Knit.CreateController({
	Name = "BuildingTransparencyController",
	_buildingIgnoreList = {},
	-- [building Model] = MODE_WHOLE | MODE_ROOF for every building currently faded.
	_activeModes = {},
})

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

-- A building's "Base" parts live under IgnoreInstances.Terrain (moved there
-- by CollisionGroupService:SetupBuilding, which leaves a `Building`
-- ObjectValue on each pointing back). They fade with the building.
local function basePartsOf(building: Model): { Instance }
	local out = {}
	local terrain = workspace.IgnoreInstances:FindFirstChild("Terrain")
	if not terrain then
		return out
	end
	for _, part in terrain:GetChildren() do
		local ref = part:FindFirstChild("Building")
		if ref and ref:IsA("ObjectValue") and ref.Value == building then
			table.insert(out, part)
			for _, descendant in part:GetDescendants() do
				table.insert(out, descendant)
			end
		end
	end
	return out
end

-- Applies `mode` to every fadeable descendant of `building` (and its Base
-- parts): the selected ones go to their faded value, the rest back to
-- authored. nil = restore all.
local function applyMode(building: Model, mode: string?)
	local instances = building:GetDescendants()
	for _, extra in basePartsOf(building) do
		table.insert(instances, extra)
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
		tweenTransparency(instance, target)
	end
end

local function buildingOf(part: BasePart): Model?
	local model = part:FindFirstAncestorOfClass("Model")
	if model and model:HasTag(TagList.Building) then
		return model
	end
	return nil
end

function BuildingTransparencyController:_BuildingProximityFunction(overlapParams: OverlapParams)
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local head = character and character:FindFirstChild("Head")
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
	-- player. Two cast points so a pillar covering only the body still
	-- counts. Wins over the roof fade.
	local castPoints = { root.Position }
	if head then
		table.insert(castPoints, head.Position)
	end
	for _, part in camera:GetPartsObscuringTarget(castPoints, self._buildingIgnoreList) do
		local building = buildingOf(part)
		if building then
			desired[building] = MODE_WHOLE
		end
	end

	-- Apply the changes: new / changed modes, then restores for buildings
	-- that dropped out.
	for building, mode in desired do
		if self._activeModes[building] ~= mode and building.Parent then
			applyMode(building, mode)
		end
	end
	for building in self._activeModes do
		if not desired[building] and building.Parent then
			applyMode(building, nil)
		end
	end

	self._activeModes = desired
end

--[ Lifecycle ]--

function BuildingTransparencyController:KnitInit()
	VFXService = Knit.GetService("VFXService")

	IgnoreListController = Knit.GetController("IgnoreListController")
end

function BuildingTransparencyController:KnitStart()
	self._buildingIgnoreList = IgnoreListController:GetBuildingTransparencyIgnoreList()

	local overlapParams = OverlapParams.new()
	overlapParams.FilterDescendantsInstances = self._buildingIgnoreList
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude

	-- A broken piece leaves its building (it is reparented to MagicSpells
	-- and flung): it comes back to its authored look on its own, whatever
	-- fade its building was under.
	VFXService.OnBuildingBroken:Connect(function(parts: { BasePart })
		for _, part in parts do
			if not part.Parent then
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

	-- Run on a separate thread so it never blocks anything else.
	task.spawn(function()
		while task.wait(THREAD_LOOP_WAIT) do
			self:_BuildingProximityFunction(overlapParams)
		end
	end)
end

return BuildingTransparencyController
