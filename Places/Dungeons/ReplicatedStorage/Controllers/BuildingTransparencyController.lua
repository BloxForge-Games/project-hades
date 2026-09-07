local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local onDamageIndicator = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Highlight.onDamageIndicator)

local camera: Camera = workspace.CurrentCamera

local TRANSPARENCY_VALUE = 0.75
local TEXTURE_TRANSPARENCY_VALUE = 0.7
local MAX_STUD_RAYCAST_DIST = 10
local ROOF_STRING = "Roof"
local THREAD_LOOP_WAIT = 0.15

local IgnoreListController
local VFXService

local BuildingTransparencyController = Knit.CreateController({
	Name = "BuildingTransparencyController",
	_buildingIgnoreList = {},
	_lastBuildings = {},
	_currentBuildings = {},
})

function BuildingTransparencyController:_BuildingProximityFunction(overlapParams: OverlapParams)
	local partsArray = workspace:GetPartBoundsInRadius(
		Players.LocalPlayer.Character.HumanoidRootPart.Position,
		MAX_STUD_RAYCAST_DIST,
		overlapParams
	)

	local cameraArray =
		camera:GetPartsObscuringTarget({ Players.LocalPlayer.Character.Head.Position }, self._buildingIgnoreList)

	if partsArray or cameraArray then
		for _, part in partsArray do
			local building = part:FindFirstAncestorOfClass("Model")

			if not building or not building:HasTag(TagList.Building) then
				continue
			end

			if self._lastBuildings[building] then
				-- Building still exists so we reiterate index and skip function below to save performance
				self._currentBuildings[building] = true

				continue
			end

			-- Store the part in the current buildings table
			self._currentBuildings[building] = true

			-- Make nearby parts visible
			for _, v in pairs(building:GetDescendants()) do
				if
					(v:IsA("BasePart") and v.Name == ROOF_STRING)
					or (v:IsA("Texture") and v.Parent.Name == ROOF_STRING)
				then
					if v.Transparency == TRANSPARENCY_VALUE then
						continue
					end

					TweenService:Create(
						v,
						TweenInfo.new(0.15, Enum.EasingStyle.Quad),
						{ Transparency = if v:IsA("Texture") then 1 else TRANSPARENCY_VALUE }
					):Play()
				end
			end
		end
	end

	-- Make previously visible parts invisible
	for instance, _ in pairs(self._lastBuildings) do
		if self._currentBuildings[instance] then
			continue
		end

		for _, v in pairs(instance:GetDescendants()) do
			if v:IsA("BasePart") and v.Transparency ~= 0 then
				TweenService:Create(v, TweenInfo.new(0.15, Enum.EasingStyle.Quad), { Transparency = 0 }):Play()
			elseif v:IsA("Texture") and v.Transparency ~= 0.7 then
				TweenService
					:Create(
						v,
						TweenInfo.new(0.15, Enum.EasingStyle.Quad),
						{ Transparency = TEXTURE_TRANSPARENCY_VALUE }
					)
					:Play()
			end
		end
	end

	-- Update the last buildings table
	self._lastBuildings = self._currentBuildings
	self._currentBuildings = {}
end

function BuildingTransparencyController:KnitInit()
	VFXService = Knit.GetService("VFXService")

	IgnoreListController = Knit.GetController("IgnoreListController")
end

function BuildingTransparencyController:KnitStart()
	self._buildingIgnoreList = IgnoreListController:GetBuildingTransparencyIgnoreList()

	local overlapParams = OverlapParams.new()
	overlapParams.FilterDescendantsInstances = self._buildingIgnoreList
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude

	VFXService.OnBuildingBroken:Connect(function(parts: table)
		for _, part in parts do
			part.Transparency = 0

			for _, v in pairs(part:GetDescendants()) do
				if v:IsA("Texture") then
					TweenService:Create(
						v,
						TweenInfo.new(0.25, Enum.EasingStyle.Quad),
						{ Transparency = TEXTURE_TRANSPARENCY_VALUE }
					):Play()
				end
			end

			onDamageIndicator(part)
		end
	end)

	-- Run on seperate thread so doesn't block any main threads
	coroutine.wrap(function()
		while task.wait(THREAD_LOOP_WAIT) do
			self:_BuildingProximityFunction(overlapParams)
		end
	end)()
end

return BuildingTransparencyController
