--[[
     Author(s): ryanisawesome25
     Module: RelicMachine.luau
     Description:
]]

--[ Exports & Types & Defaults ]--

--[ Roblox Services ]--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

--[ Imports ]--

local Component = require(ReplicatedStorage.Submodules.Core.Packages.Component)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local CameraShakePresets = require(ReplicatedStorage.Submodules.Core.Shared.Enums.CameraShakePresets)
local CommAdder = require(ReplicatedStorage.Submodules.Core.Source.ComponentExtensions.CommAdder)
local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local ScreenSizes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ScreenSizes)

local CameraShakeController
local ScreenSizeController

Knit.OnStart()
	:andThen(function()
		CameraShakeController = Knit.GetController("CameraShakeController")
		ScreenSizeController = Knit.GetController("ScreenSizeController")
	end)
	:catch(warn)

--[ Component Root ]--

local RelicMachine = Component.new({
	Tag = "RelicMachine",
	Extensions = { CommAdder },
})

--[ Constants ]--

local TRANSPARENCY = 0.85

-- The landing thud only shakes cameras of players standing near the drop
-- point. Local-only, like the rest of this component's landing FX.
local LANDING_SHAKE_RANGE_STUDS = 25

--[ Properties ]--

--[ Private Functions ]--

--[ Public Functions ]--

--[ Initializers ]--

function RelicMachine:Construct()
	-- DIAGNOSTIC (nil-PrimaryPart crash): print WHERE the tagged model
	-- lives before the index below throws, so the offending copy is
	-- identifiable in the output.
	if not self.Instance.PrimaryPart then
		warn(
			"[RelicMachine] Construct with nil PrimaryPart — parent: "
				.. tostring(self.Instance.Parent)
				.. " | full path: "
				.. self.Instance:GetFullName()
		)
	end

	self._proximityPrompt = self.Instance.PrimaryPart.Attachment:WaitForChild("ProximityPrompt")
	self._onPromptTriggered = self._comm:GetSignal("OnPromptTriggered")
	self._ownerId = self.Instance:GetAttribute(Attributes.OwnerId)
	self._numberValue = Instance.new("NumberValue")
	self._numberValue.Value = 1
	self._numberValue.Parent = self.Instance
	self._canClick = true
end

function RelicMachine:Start()
	if Players.LocalPlayer.UserId ~= self.Instance:GetAttribute(Attributes.OwnerId) then
		self.Instance.PrimaryPart.VendingMachineName.AlwaysOnTop = false
		self.Instance.PrimaryPart.VendingMachineName.Frame.NameText.TextTransparency = TRANSPARENCY
		self.Instance.PrimaryPart.VendingMachineName.Frame.NameText.UIStroke.Transparency = TRANSPARENCY
		self.Instance.PrimaryPart.VendingMachineName.Frame.VendingMachineText.TextTransparency = TRANSPARENCY
		self.Instance.PrimaryPart.VendingMachineName.Frame.VendingMachineText.UIStroke.Transparency = TRANSPARENCY
		self.Instance.Model.Transparency = TRANSPARENCY
		self.Instance.PrimaryPart.Attachment.PointLight.Enabled = false
		self.Instance.PrimaryPart.Attachment.Shine.Enabled = false
		self.Instance.PrimaryPart.Attachment.ProximityPrompt.Enabled = false
		self.Instance.PrimaryPart.Attachment1.ParticleEmitter.Enabled = false
		self.Instance.PrimaryPart.Layer.Enabled = false
		self.Instance.PrimaryPart.Spark.Enabled = false
		self.Instance.Model.CanCollide = false
	end

	local rayOrigin = self.Instance:GetBoundingBox().Position
	local rayDirection = Vector3.new(0, -1, 0)
	local raycastParams = RaycastParams.new()
	-- Include the dungeon room floors as well as decorative Terrain. Without
	-- DungeonRooms here, vending machines dropped inside dungeon rooms (e.g.
	-- after a miniboss defeat) miss the raycast → the landing tween + the
	-- ProximityPrompt:Enable() at the bottom of the if-block never run, so
	-- the player can't interact with the machine.
	raycastParams.FilterDescendantsInstances = {
		workspace.IgnoreInstances.Map.DungeonRooms,
		workspace.IgnoreInstances.Terrain,
	}
	raycastParams.FilterType = Enum.RaycastFilterType.Include

	local rayResult = workspace:Raycast(rayOrigin, rayDirection * 1000, raycastParams)

	if ScreenSizeController:GetScreenSizeData().name == ScreenSizes.Mobile then
		self.Instance.PrimaryPart.VendingMachineName.Frame.NameText.TextSize = 15
		self.Instance.PrimaryPart.VendingMachineName.Frame.VendingMachineText.TextSize = 12
	end

	if rayResult then
		local floorY = rayResult.Position.Y
		local offset = (self.Instance:GetExtentsSize().Y / 2) + 1
		local targetPosition = self.Instance.PrimaryPart.Position:Lerp(
			Vector3.new(self.Instance.PrimaryPart.Position.X, floorY + offset, self.Instance.PrimaryPart.Position.Z),
			1
		)
		TweenService:Create(
			self.Instance.PrimaryPart,
			TweenInfo.new(1, Enum.EasingStyle.Cubic, Enum.EasingDirection.InOut),
			{ Position = targetPosition }
		):Play()

		TweenService:Create(
			self.Instance.Model,
			TweenInfo.new(1, Enum.EasingStyle.Cubic, Enum.EasingDirection.InOut),
			{ Position = targetPosition }
		):Play()

		self._numberValue.Value = 0.75

		task.delay(0.5, function()
			TweenService:Create(
				self._numberValue,
				TweenInfo.new(2, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out),
				{ Value = 1 }
			):Play()

			task.delay(0.35, function()
				self.Instance.PrimaryPart.LandParticle:Emit(10)
				self.Instance.PrimaryPart.Landing:Play()

				-- Landing impact — small local shake for anyone near the
				-- drop (the owner is always ~8 studs away).
				local character = Players.LocalPlayer.Character
				local hrp = character and character:FindFirstChild("HumanoidRootPart")
				if
					CameraShakeController
					and hrp
					and (hrp.Position - self.Instance.PrimaryPart.Position).Magnitude <= LANDING_SHAKE_RANGE_STUDS
				then
					CameraShakeController:Shake(CameraShakePresets.Small)
				end
			end)

			task.delay(0.5, function()
				if Players.LocalPlayer.UserId ~= self.Instance:GetAttribute(Attributes.OwnerId) then
					return
				end

				self.Instance.PrimaryPart.Attachment.ProximityPrompt.Enabled = true
			end)
		end)
	end

	self._numberValue.Changed:Connect(function(value)
		self.Instance:ScaleTo(value)
	end)

	self._proximityPrompt.Triggered:Connect(function(player: Player)
		if self._ownerId == player.UserId and self._canClick then
			self._proximityPrompt.Enabled = false
			self._canClick = false

			self._numberValue.Value = 1.25

			TweenService:Create(
				self._numberValue,
				TweenInfo.new(1, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out),
				{ Value = 1 }
			):Play()

			self._onPromptTriggered:Fire(self.Instance.PrimaryPart.CFrame)
		end
	end)
end

function RelicMachine:Stop() end

return RelicMachine
