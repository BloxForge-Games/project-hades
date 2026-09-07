local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local Janitor = require(ReplicatedStorage.Submodules.Core.Packages.Janitor)
local HumanoidProperties = require(ReplicatedStorage.Submodules.Core.Shared.Data.HumanoidProperties)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)

local player: Player = game.Players.LocalPlayer

local RunParticlesService
local PlayerEventController

local RunParticlesController = Knit.CreateController({
	Name = "RunParticlesController",
	Client = {},
	particlesEnabled = false :: boolean,
})

function RunParticlesController:KnitInit()
	self._janitor = Janitor.new()

	RunParticlesService = Knit.GetService("RunParticlesService")
	PlayerEventController = Knit.GetController("PlayerEventController")
end

function RunParticlesController:KnitStart()
	RunParticlesService.CreateRunParticles:Fire()

	PlayerEventController.OnCharacterLoaded:Connect(function(character: Model)
		self._janitor:Add(character.Humanoid.Running:Connect(function(speed: number)
			if speed <= HumanoidProperties.WalkSpeed and self.particlesEnabled then
				self.particlesEnabled = false

				if character:GetAttribute(Attributes.IsDodging) ~= true then
					RunParticlesService.ToggleRunParticles:Fire(false)
				end
			elseif speed >= HumanoidProperties.WalkSpeed - 1 and not self.particlesEnabled then
				self.particlesEnabled = true
				RunParticlesService.ToggleRunParticles:Fire(true)
			end
		end))

		self._janitor:Add(character.Humanoid.StateChanged:Connect(function(_, newState)
			if
				newState == Enum.HumanoidStateType.Jumping
				or newState == Enum.HumanoidStateType.Seated
				or newState == Enum.HumanoidStateType.Freefall
			then
				if player.Character:GetAttribute(Attributes.IsDodging) ~= true then
					RunParticlesService.ToggleRunParticles:Fire(false)
				end
			end
		end))
	end)
end

return RunParticlesController
