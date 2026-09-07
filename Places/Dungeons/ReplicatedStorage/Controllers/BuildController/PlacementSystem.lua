local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local BuildNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.BuildNames)
local BuildData = require(ReplicatedStorage.Submodules.Core.Shared.Data.BuildData)
local Janitor = require(ReplicatedStorage.Submodules.Core.Packages.Janitor)
local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)

local buildPlaceSound = ReplicatedStorage.GameAssets.Sounds.BuildPlace

local BuildService

Knit.OnStart():andThen(function()
	BuildService = Knit.GetService("BuildService")
end)

local DEFAULT_GRID_SIZE = 1
local TWEEN_DURATION = 0.65
local PLACEMENT_Y_OFFSET = 0.1

local player = Players.LocalPlayer
local mouse = player:GetMouse()

local PlacementSystem = {}
PlacementSystem.__index = PlacementSystem

function PlacementSystem.new(placementSurface: BasePart)
	local self = setmetatable({}, PlacementSystem)

	self._janitor = Janitor.new()
	self._placementSurface = placementSurface
	self._gridSize = DEFAULT_GRID_SIZE
	self._rotation = 0
	self._isPlacing = false
	self._previewModel = nil
	self._activeSelectionBox = nil
	self._rayParams = RaycastParams.new()
	self._rayParams.FilterType = Enum.RaycastFilterType.Include
	self._rayParams.FilterDescendantsInstances = { self._placementSurface }
	self._previewHeight = 0
	self._previewSize = Vector3.new(0, 0, 0)
	self._pivotYOffset = 0
	self._buildRegistry = {}
	self._billboardGui = nil
	self._atMaxQuantity = false
	self._particleEmitter = nil
	self._characters = {}
	self._zombieRegistry = {}
	self._buildLevel = 1

	-- Set up overlap params for placement validation
	self._overlapParams = OverlapParams.new()
	self._overlapParams.FilterType = Enum.RaycastFilterType.Include
	self._overlapParams.FilterDescendantsInstances = { workspace.IgnoreInstances.Map }

	return self
end

function PlacementSystem:_snapToGrid(x: number, z: number)
	local origin = self._placementSurface.Position

	local localX = x - origin.X
	local localZ = z - origin.Z

	local snappedX = math.floor(localX / self._gridSize + 0.5) * self._gridSize
	local snappedZ = math.floor(localZ / self._gridSize + 0.5) * self._gridSize

	return origin.X + snappedX, origin.Z + snappedZ
end

function PlacementSystem:_clampToCanvas(x: number, z: number): (number, number)
	local halfCanvasX = self._placementSurface.Size.X / 2
	local halfCanvasZ = self._placementSurface.Size.Z / 2

	local sizeX, sizeZ = self:_getRotatedFootprint()

	local halfModelX = sizeX / 2
	local halfModelZ = sizeZ / 2

	local minX = self._placementSurface.Position.X - halfCanvasX + halfModelX
	local maxX = self._placementSurface.Position.X + halfCanvasX - halfModelX

	local minZ = self._placementSurface.Position.Z - halfCanvasZ + halfModelZ
	local maxZ = self._placementSurface.Position.Z + halfCanvasZ - halfModelZ

	x = math.clamp(x, minX, maxX)
	z = math.clamp(z, minZ, maxZ)

	return x, z
end

function PlacementSystem:_canPlace(model: Model): boolean
	local boundingBox = model.BoundingBox

	local touching = workspace:GetPartsInPart(boundingBox, self._overlapParams)

	for _, hit in touching do
		if hit:IsDescendantOf(self._placementSurface) then
			continue
		end

		if hit:IsDescendantOf(model) then
			continue
		end

		if hit:IsA("BasePart") then
			return false
		end
	end

	return true
end

function PlacementSystem:_getRotatedFootprint()
	local size = self._previewSize
	local rot = self._rotation % 180

	if rot == 90 then
		return size.Z, size.X
	end

	return size.X, size.Z
end

function PlacementSystem:_onRenderStepped()
	if not self._isPlacing or not self._previewModel then
		return
	end

	local ray = workspace.CurrentCamera:ScreenPointToRay(mouse.X, mouse.Y)

	local result = workspace:Raycast(ray.Origin, ray.Direction * 500, self._rayParams)

	if not result then
		local planeY = self._placementSurface.Position.Y + self._placementSurface.Size.Y / 2
		local dirY = ray.Direction.Y

		if math.abs(dirY) < 1e-4 then
			return
		end

		local t = (planeY - ray.Origin.Y) / dirY

		if t < 0 then
			return
		end

		local pos = ray.Origin + ray.Direction * t
		result = {
			Position = Vector3.new(pos.X, planeY, pos.Z),
		}
	end

	local x = result.Position.X
	local z = result.Position.Z

	x, z = self:_snapToGrid(x, z)
	x, z = self:_clampToCanvas(x, z)

	local y = self._placementSurface.Position.Y
		+ self._placementSurface.Size.Y / 2
		+ self._previewHeight / 2
		- self._pivotYOffset
		+ PLACEMENT_Y_OFFSET

	local cf = CFrame.new(x, y, z) * CFrame.Angles(0, math.rad(self._rotation), 0)

	self._previewModel:PivotTo(cf)

	if self:_canPlace(self._previewModel) and self._atMaxQuantity == false then
		if self._activeSelectionBox and self._activeSelectionBox.Color3 ~= Color3.fromRGB(66, 153, 251) then
			self._activeSelectionBox.Color3 = Color3.fromRGB(66, 153, 251)
			self._activeSelectionBox.SurfaceColor3 = Color3.fromRGB(66, 153, 251)
		end
	else
		if
			(self._activeSelectionBox or self._atMaxQuantity == true)
			and self._activeSelectionBox.Color3 ~= Color3.fromRGB(255, 92, 92)
		then
			self._activeSelectionBox.Color3 = Color3.fromRGB(255, 92, 92)
			self._activeSelectionBox.SurfaceColor3 = Color3.fromRGB(255, 92, 92)
		end
	end
end

function PlacementSystem:_updateBuildQuantity(modelName: BuildNames.BuildNames)
	self._billboardGui.BuildName.Text = "Lvl. " .. tostring(self._buildLevel) .. " " .. modelName

	if self._buildRegistry[modelName] then
		self._billboardGui.BuildQuantity.Text = tostring(self._buildRegistry[modelName])
			.. "/"
			.. BuildData[modelName].maxQuantity
	else
		self._billboardGui.BuildQuantity.Text = "0" .. "/" .. BuildData[modelName].maxQuantity
	end

	if self._buildRegistry[modelName] and self._buildRegistry[modelName] >= BuildData[modelName].maxQuantity then
		self._atMaxQuantity = true
		self._billboardGui.BuildQuantity.TextColor3 = Color3.fromRGB(255, 92, 92)
		self._billboardGui.BuildName.TextColor3 = Color3.fromRGB(255, 92, 92)
	else
		self._atMaxQuantity = false
		self._billboardGui.BuildQuantity.TextColor3 = Color3.fromRGB(255, 255, 255)
		self._billboardGui.BuildName.TextColor3 = Color3.fromRGB(255, 255, 255)
	end
end

function PlacementSystem:UpdateZombieRegistry(zombieRegistry: table)
	self._zombieRegistry = zombieRegistry

	self._overlapParams.FilterDescendantsInstances =
		{ workspace.IgnoreInstances.Map, unpack(self._characters), unpack(self._zombieRegistry) }
end

function PlacementSystem:UpdateCharacterList(characterTable: table)
	self._characters = characterTable

	self._overlapParams.FilterDescendantsInstances = { workspace.IgnoreInstances.Map, unpack(self._characters) }
end

function PlacementSystem:UpdateBuildRegistry(buildRegistry: table)
	self._buildRegistry = buildRegistry

	self:_updateBuildQuantity(self._previewModel.Name)
end

function PlacementSystem:UpdateBuildLevel(buildLevelRegistry: table)
	if self._previewModel == nil then
		return warn("[PlacementSystem] Attempted to update build level with no active preview model")
	end

	local buildLevel = buildLevelRegistry[self._previewModel.Name] or 1

	self._buildLevel = buildLevel

	self._billboardGui.BuildName.Text = "Lvl. "
		.. tostring(self._buildLevel)
		.. " "
		.. BuildData[self._previewModel.Name].name
end

function PlacementSystem:SetBuild(modelName: BuildNames.BuildNames)
	if self._previewModel then
		self._previewModel:Destroy()
	end

	local model = ReplicatedStorage.GameAssets.Buildables:FindFirstChild(modelName):Clone()

	if self._activeSelectionBox then
		self._activeSelectionBox:Destroy()
		self._activeSelectionBox = nil
	end

	self._activeSelectionBox = Instance.new("SelectionBox")
	self._activeSelectionBox.Adornee = model.BoundingBox
	self._activeSelectionBox.Color3 = Color3.fromRGB(66, 153, 251)
	self._activeSelectionBox.SurfaceColor3 = Color3.fromRGB(66, 153, 251)
	self._activeSelectionBox.LineThickness = 0.05
	self._activeSelectionBox.SurfaceTransparency = 0.85
	self._activeSelectionBox.Transparency = 0
	self._activeSelectionBox.Parent = model

	self._billboardGui = ReplicatedStorage.GameAssets.BillboardGuis.BuildQuantity:Clone()
	self._billboardGui.Adornee = model
	self._billboardGui.Parent = model
	self._billboardGui.Enabled = false

	task.delay(0.05, function()
		self._billboardGui.Enabled = true
	end)

	self:_updateBuildQuantity(modelName)

	self._particleEmitter = ReplicatedStorage.GameAssets.Particles.PlacementEffect:Clone()
	self._particleEmitter.Parent = model.BoundingBox

	self._janitor:Add(self._particleEmitter)
	self._janitor:Add(self._billboardGui)
	self._janitor:Add(self._activeSelectionBox)

	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			part.CanCollide = false
			if part ~= model.PrimaryPart and part.Name ~= "CollisionBox" then
				part.Transparency = 0.25
			end
		end
	end

	local cf, size = model:GetBoundingBox()

	self._previewHeight = size.Y
	self._previewSize = size

	-- compute pivot offset from bounding box center
	self._pivotYOffset = cf.Position.Y - model:GetPivot().Position.Y

	self._janitor:Add(model)

	model.Parent = workspace.IgnoreInstances.Map.Buildables

	self._previewModel = model
	self._isPlacing = true
end

function PlacementSystem:Init()
	self._janitor:Add(RunService.RenderStepped:Connect(function()
		self:_onRenderStepped()
	end))

	self._janitor:Add(UserInputService.InputBegan:Connect(function(input, gpe)
		if gpe then
			return
		end

		if input.KeyCode == Enum.KeyCode.R then
			self._rotation = (self._rotation + 90) % 360
		end

		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			if not self._previewModel then
				return
			end

			if self._atMaxQuantity then
				return
			end

			if self:_canPlace(self._previewModel) then
				local modelName = self._previewModel.Name
				local pivot = self._previewModel:GetPivot()

				self._previewModel:Destroy()

				self._previewModel = nil
				self._isPlacing = false

				buildPlaceSound:Play()

				self:SetBuild(modelName)

				local buildTemplate = ReplicatedStorage.GameAssets.Buildables:FindFirstChild(modelName):Clone()

				for _, part in pairs(buildTemplate:GetDescendants()) do
					if part:IsA("BasePart") then
						part.CanCollide = false
					end
				end

				local numberScale = Instance.new("NumberValue")
				numberScale.Name = "PlacementPreview"
				numberScale.Value = 0.15
				numberScale.Parent = buildTemplate

				buildTemplate:ScaleTo(0.15)

				numberScale:GetPropertyChangedSignal("Value"):Connect(function()
					buildTemplate:ScaleTo(numberScale.Value)
				end)

				local targetPivot = pivot

				local randomY = math.rad(math.random(-0, 0))
				local randomX = math.rad(math.random(-180, 180))
				local randomZ = math.rad(math.random(-180, 180))
				local randomRotation = CFrame.Angles(randomX, randomY, randomZ)

				local startPivot = pivot * CFrame.new(0, -10, 0) * randomRotation

				buildTemplate:PivotTo(startPivot)

				buildTemplate.Parent = workspace.IgnoreInstances.Map.Buildables

				local tweenInfo = TweenInfo.new(TWEEN_DURATION, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

				TweenService:Create(buildTemplate.PrimaryPart, tweenInfo, { CFrame = targetPivot }):Play()

				TweenService:Create(numberScale, TweenInfo.new(TWEEN_DURATION, Enum.EasingStyle.Back), { Value = 1 })
					:Play()

				self._particleEmitter:Emit(10)

				BuildService:RequestPlaceBuild(modelName, pivot, workspace:GetServerTimeNow(), TWEEN_DURATION)

				Debris:AddItem(buildTemplate, TWEEN_DURATION + 0.5)
			end
		end
	end))
end

function PlacementSystem:Destroy()
	self._previewModel = nil
	self._isPlacing = false

	self._janitor:Destroy()
end

return PlacementSystem
