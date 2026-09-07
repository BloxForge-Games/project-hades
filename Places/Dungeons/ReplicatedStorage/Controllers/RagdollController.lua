local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local Signal = require(ReplicatedStorage.Submodules.Core.Packages.Signal)

local RagdollService

local RagdollController = Knit.CreateController({
	Name = "RagdollController",
})

RagdollController.OnRagdollRequested = Signal.new()
RagdollController.OnUnragdollRequested = Signal.new()

function RagdollController:KnitInit()
	RagdollService = Knit.GetService("RagdollService")
end

function RagdollController:KnitStart()
	RagdollService.OnRagdollToggled:Connect(function(toggle: boolean)
		if toggle then
			self.OnRagdollRequested:Fire()
			Players.LocalPlayer.Character.HumanoidRootPart:ApplyAngularImpulse(Vector3.new(-200, 0, 0))
		else
			self.OnUnragdollRequested:Fire()
		end
	end)
end

return RagdollController
