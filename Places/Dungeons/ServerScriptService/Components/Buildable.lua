--[[
     Author(s): ryanisawesome25
     Module: Buildable.luau
     Description:
]]

--[ Exports & Types & Defaults ]--

--[ Roblox Services ]--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

--[ Imports ]--

local Component = require(ReplicatedStorage.Submodules.Core.Packages.Component)
local BuildData = require(ReplicatedStorage.Submodules.Core.Shared.Data.BuildData)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local Janitor = require(ReplicatedStorage.Submodules.Core.Packages.Janitor)

local BuildService

Knit.OnStart():andThen(function()
	BuildService = Knit.GetService("BuildService")
end)

--[ Component Root ]--

local Buildable = Component.new({
	Tag = "Buildable",
})

--[ Constants ]--

--[ Properties ]--

--[ Private Functions ]--

--[ Public Functions ]--

--[ Initializers ]--

function Buildable:Construct()
	self._janitor = Janitor.new()
	self._buildName = self.Instance.Name
	self._buildTemplate = self.Instance
	self._ownerId = self.Instance:GetAttribute(Attributes.OwnerId)
	self._player = Players:GetPlayerByUserId(self._ownerId)
end

function Buildable:Start()
	local buildInterface = ReplicatedStorage.GameAssets.BillboardGuis.BuildInterface:Clone()
	buildInterface.Parent = self._buildTemplate.PrimaryPart
	buildInterface.Adornee = self._buildTemplate.PrimaryPart
	buildInterface.StudsOffset = Vector3.new(0, 1, 0)

	local healthNumberValue = Instance.new("NumberValue")
	healthNumberValue.Name = "MaxHealth"
	healthNumberValue.Value = BuildData[self._buildName].maxHealth
	healthNumberValue.Parent = self._buildTemplate.PrimaryPart

	local currentHealthValue = Instance.new("NumberValue")
	currentHealthValue.Name = "CurrentHealth"
	currentHealthValue.Value = BuildData[self._buildName].maxHealth
	currentHealthValue.Parent = self._buildTemplate.PrimaryPart

	buildInterface.InnerFrame.BackgroundColor3 = Color3.fromRGB(45, 45, 45)
	buildInterface.InnerFrame.RedBar.BackgroundColor3 = Color3.fromRGB(225, 225, 225)

	buildInterface.PlayerName.Text = "(" .. self._player.Name .. ")"
	buildInterface.BuildName.Text = "Lvl."
		.. BuildService:GetBuildLevel(self._player, self._buildName)
		.. " "
		.. self._buildName

	self._janitor:Add(currentHealthValue.Changed:Connect(function(value: number)
		if value <= 0 then
			self._buildTemplate:Destroy()
			self._janitor:Cleanup()
			currentHealthValue:Destroy()

			local buildRegistry = BuildService:GetBuildRegistry(self._player)

			if buildRegistry[self._buildName] and buildRegistry[self._buildName] ~= 0 then
				buildRegistry[self._buildName] -= 1

				BuildService:SetBuildRegistry(self._player, self._buildName, buildRegistry[self._buildName])
			end

			return
		end

		buildInterface.InnerFrame.Visible = true

		TweenService:Create(
			buildInterface.InnerFrame.RedBar,
			TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Size = UDim2.fromScale(value / healthNumberValue.Value, 1.3) }
		):Play()

		BuildService.Client.OnBuildDamaged:FireAll(self._buildTemplate)
	end))

	for _, part in pairs(self._buildTemplate:GetDescendants()) do
		if part:IsA("BasePart") and part ~= self._buildTemplate.PrimaryPart and part.Name ~= "CollisionBox" then
			part.Transparency = 1
		end
	end
end

function Buildable:Stop()
	self._janitor:Cleanup()
end

return Buildable
