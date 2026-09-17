--!strict
--[[
     Author(s): ryanisawesome25
     Module: RelicMachine.luau
     Description:
]]

--[ Exports & Types & Defaults ]--

--[ Roblox Services ]--

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

--[ Imports ]--

local Component = require(ReplicatedStorage.Submodules.Core.Packages.Component)
local waitForPrimaryPart = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Drop.waitForPrimaryPart)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local CameraShakePresets = require(ReplicatedStorage.Submodules.Core.Shared.Enums.CameraShakePresets)
local CameraShakeController = require(ReplicatedStorage.Controllers.CameraShakeController)
local ScreenSizeController = require(ReplicatedStorage.Submodules.Core.Source.Controllers.ScreenSizeController)
local DungeonNetwork = require(ReplicatedStorage.Submodules.Core.Source.Network.Dungeon)
local ScreenSizes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ScreenSizes)

--[ Component Root ]--

local RelicMachine = Component.new({
	Tag = "RelicMachine",
})

--[ Constants ]--

local TRANSPARENCY = 0.85

-- How long Construct waits for a streamed-in descendant before giving up.
local STREAM_WAIT_SECONDS = 10

-- The landing thud only shakes cameras of players standing near the drop
-- point. Local-only, like the rest of this component's landing FX.
local LANDING_SHAKE_RANGE_STUDS = 25

--[ Properties ]--

--[ Private Functions ]--

--[ Public Functions ]--

--[ Initializers ]--

function RelicMachine:Construct()
	-- The parts can stream in after the tagged Model does; wait for them
	-- (this was the old nil-PrimaryPart crash).
	local primaryPart = waitForPrimaryPart(self.Instance)
	assert(primaryPart, "[RelicMachine] PrimaryPart never replicated for " .. self.Instance:GetFullName())
	-- Start reads all of these directly. The server spawns the machine
	-- atomic, so they normally arrive with the Model; the waits cover an
	-- asset that is not, and turn a random "not a valid member" crash (dead
	-- prompt, no landing) into a clear timeout.
	local function need(parent: Instance, name: string): Instance
		local child = parent:WaitForChild(name, STREAM_WAIT_SECONDS)
		assert(child, ("[RelicMachine] %s never replicated under %s"):format(name, parent:GetFullName()))
		return child
	end
	need(self.Instance, "Model")
	local attachment = need(primaryPart, "Attachment")
	need(attachment, "PointLight")
	need(attachment, "Shine")
	need(need(primaryPart, "Attachment1"), "ParticleEmitter")
	need(primaryPart, "VendingMachineName")
	need(primaryPart, "Layer")
	need(primaryPart, "Spark")
	need(primaryPart, "LandParticle")
	need(primaryPart, "Landing")
	self._proximityPrompt = need(attachment, "ProximityPrompt")
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

				-- The dodge landing burst at the machine's foot: the dust
				-- ring the roll leaves, here as the ground kick of the drop.
				-- Particles only; the machine has its own Landing sound and
				-- the burst's thud stays silent.
				local dustVFX = ReplicatedStorage.GameAssets.VFX.Dodge.Dodge:Clone() :: any
				local foot = self.Instance.PrimaryPart.Position
				dustVFX:PivotTo(CFrame.new(foot.X, floorY, foot.Z))
				dustVFX.Parent = workspace.IgnoreInstances.MagicSpells
				for _, particle in dustVFX.Part.Attachment:GetChildren() do
					if particle:IsA("ParticleEmitter") then
						particle:Emit(10)
					end
				end
				Debris:AddItem(dustVFX, 5)

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

			DungeonNetwork.RelicMachinePromptTriggered.Fire({
				Machine = self.Instance,
				CFrame = self.Instance.PrimaryPart.CFrame,
			})
		end
	end)
end

function RelicMachine:Stop() end

return RelicMachine
