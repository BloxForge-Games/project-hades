local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)

local WeldConstraintService

local SPRINT_PART_NAME = "SprintSmoke"

local RunParticlesService = Knit.CreateService({
	Name = "RunParticlesService",
	Client = { CreateRunParticles = Knit.CreateSignal(), ToggleRunParticles = Knit.CreateSignal() },
})

function RunParticlesService:KnitInit()
	WeldConstraintService = Knit.GetService("WeldConstraintService")
end

function RunParticlesService:KnitStart()
	self.Client.CreateRunParticles:Connect(function(player: Player)
		local character = player.Character

		if character:FindFirstChild(SPRINT_PART_NAME) == nil then
			local smokeClone: Part = game.ReplicatedStorage.GameAssets.Particles[SPRINT_PART_NAME]:Clone()
			smokeClone.Anchored = false
			smokeClone.CFrame = character.HumanoidRootPart.CFrame * CFrame.new(0, -2.5, 0)
			smokeClone.Parent = character

			WeldConstraintService:CreateWeldConstraint(smokeClone, character.HumanoidRootPart)
		end
	end)

	self.Client.ToggleRunParticles:Connect(function(player: Player, enabled: boolean)
		if player.Character:FindFirstChild(SPRINT_PART_NAME) then
			player.Character:FindFirstChild(SPRINT_PART_NAME)["SprintParticles"].Enabled = enabled
		end
	end)
end

return RunParticlesService
