--!strict
--[[
	Module: Controllers/RunParticlesController.lua
	Description:
	Asks the server for the sprint smoke once, then toggles it from the
	local humanoid's speed and state (off while jumping, seated, falling,
	or dodging).

	A Blitz module depending on
	PlayerEventController.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlayerNetwork = require(ReplicatedStorage.Submodules.Core.Source.Network.Player)
local Janitor = require(ReplicatedStorage.Submodules.Core.Packages.Janitor)
local HumanoidProperties = require(ReplicatedStorage.Submodules.Core.Shared.Data.HumanoidProperties)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local PlayerEventController = require(ReplicatedStorage.Submodules.Core.Source.Controllers.PlayerEventController)

local RunParticlesController = {
	Name = "RunParticlesController",
	Dependencies = { PlayerEventController } :: { any },

	particlesEnabled = false :: boolean,
	_janitor = Janitor.new() :: any,
}

function RunParticlesController.Start(self: typeof(RunParticlesController))
	PlayerNetwork.RunParticlesCreate.Fire()

	PlayerEventController.OnCharacterLoaded:Connect(function(character: Model)
		-- One pair of listeners per character: without this the janitor
		-- grows by two dead entries every respawn.
		self._janitor:Cleanup()

		local humanoid = character:WaitForChild("Humanoid") :: Humanoid

		self._janitor:Add(humanoid.Running:Connect(function(speed: number)
			if speed <= HumanoidProperties.WalkSpeed and self.particlesEnabled then
				self.particlesEnabled = false

				if character:GetAttribute(Attributes.IsDodging) ~= true then
					PlayerNetwork.RunParticlesToggle.Fire(false)
				end
			elseif speed >= HumanoidProperties.WalkSpeed - 1 and not self.particlesEnabled then
				self.particlesEnabled = true
				PlayerNetwork.RunParticlesToggle.Fire(true)
			end
		end))

		self._janitor:Add(humanoid.StateChanged:Connect(function(_, newState: Enum.HumanoidStateType)
			if
				newState == Enum.HumanoidStateType.Jumping
				or newState == Enum.HumanoidStateType.Seated
				or newState == Enum.HumanoidStateType.Freefall
			then
				local current = Players.LocalPlayer.Character
				if current and current:GetAttribute(Attributes.IsDodging) ~= true then
					PlayerNetwork.RunParticlesToggle.Fire(false)
				end
			end
		end))
	end)
end

return RunParticlesController
