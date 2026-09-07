-- CLIENT Turret.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Component = require(ReplicatedStorage.Submodules.Core.Packages.Component)
local CommAdder = require(ReplicatedStorage.Submodules.Core.Source.ComponentExtensions.CommAdder)

local Turret = Component.new({
	Tag = "Turret",
	Extensions = { CommAdder },
})

function Turret:Construct()
	self._onTurretCFrameChanged = self._comm:GetSignal("OnTurretCFrameChanged") :: table
	self._clientModel = nil
	self._activeTween = nil
end

function Turret:Start()
	local clientModel = self.Instance:Clone()
	clientModel.Name = self.Instance.Name .. "_Client"

	for _, tag in clientModel:GetTags() do
		clientModel:RemoveTag(tag)
	end

	clientModel.__comm__:Destroy()
	clientModel.BoundingBox:Destroy()
	clientModel.PrimaryPart.BuildInterface.Enabled = false
	clientModel.Parent = workspace.IgnoreInstances.MagicSpells.ClientBuildables

	self._clientModel = clientModel

	-- Hide server-side model parts
	for _, part in pairs(self.Instance.Model:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Transparency = 1
		end
	end

	self._onTurretCFrameChanged:Connect(function(turretInstance: Model, newCFrame: CFrame)
		if turretInstance ~= self.Instance then
			return
		end

		if not self._clientModel or not self._clientModel.PrimaryPart then
			return
		end

		if self._activeTween then
			self._activeTween:Cancel()
			self._activeTween = nil
		end

		self._activeTween = TweenService:Create(
			self._clientModel.PrimaryPart,
			TweenInfo.new(0.5, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out),
			{ CFrame = newCFrame }
		)

		self._activeTween:Play()

		self._activeTween.Completed:Connect(function(playbackState)
			if playbackState == Enum.PlaybackState.Completed then
				self._activeTween = nil
			end
		end)
	end)
end

function Turret:Stop()
	if self._activeTween then
		self._activeTween:Cancel()
		self._activeTween = nil
	end

	if self._clientModel then
		self._clientModel:Destroy()
		self._clientModel = nil
	end
end

return Turret
