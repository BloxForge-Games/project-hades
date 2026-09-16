--!strict
--[[
	Module: Controllers/RagdollController.lua
	Description:
	The local player's ragdoll state as the server toggles it
	(Combat.RagdollToggled): a kick on the way down, and two signals for
	the systems that pause on it.

	A Blitz module with no dependencies.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Combat = require(ReplicatedStorage.Submodules.Core.Source.Network.Combat)
local Signal = require(ReplicatedStorage.Submodules.Core.Shared.Types.Signal)

local RagdollController = {
	Name = "RagdollController",

	OnRagdollRequested = Signal.new() :: Signal.Signal<>,
	OnUnragdollRequested = Signal.new() :: Signal.Signal<>,
}

function RagdollController.Start(self: typeof(RagdollController))
	Combat.RagdollToggled.On(function(toggle: boolean)
		if toggle then
			self.OnRagdollRequested:Fire()
			local character = Players.LocalPlayer.Character
			local rootPart = character and character:FindFirstChild("HumanoidRootPart")
			if rootPart and rootPart:IsA("BasePart") then
				rootPart:ApplyAngularImpulse(Vector3.new(-200, 0, 0))
			end
		else
			self.OnUnragdollRequested:Fire()
		end
	end)
end

return RagdollController
