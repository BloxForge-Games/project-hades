--!strict
--[[
	Module: Services/RunParticlesService.lua
	Description:
	The sprint smoke under a running character: the client asks for the
	part once (RunParticlesCreate) and toggles its emitter with its own
	speed (RunParticlesToggle); the server owns the part so everyone sees it.

	A Blitz module. WeldConstraintService is
	required directly and used in Start.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local PlayerNetwork = require(ServerScriptService.Submodules.Core.Source.Network.Player)
local WeldConstraintService = require(ServerScriptService.Submodules.Core.Source.Services.WeldConstraintService)

local SPRINT_PART_NAME = "SprintSmoke"

local RunParticlesService = {
	Name = "RunParticlesService",
	Dependencies = { WeldConstraintService } :: { any },
}

function RunParticlesService.Start(_self: typeof(RunParticlesService))
	PlayerNetwork.RunParticlesCreate.On(function(player: Player)
		local character = player.Character
		if not character then
			return
		end
		local rootPart = character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not rootPart then
			return
		end

		if character:FindFirstChild(SPRINT_PART_NAME) == nil then
			local template = ReplicatedStorage.GameAssets.Particles:FindFirstChild(SPRINT_PART_NAME) :: BasePart
			local smokeClone = template:Clone()
			smokeClone.Anchored = false
			smokeClone.CFrame = rootPart.CFrame * CFrame.new(0, -2.5, 0)
			smokeClone.Parent = character

			WeldConstraintService:CreateWeldConstraint(smokeClone, rootPart)
		end
	end)

	PlayerNetwork.RunParticlesToggle.On(function(player: Player, enabled: boolean)
		local character = player.Character
		local smoke = character and character:FindFirstChild(SPRINT_PART_NAME)
		local particles = smoke and smoke:FindFirstChild("SprintParticles") :: ParticleEmitter?
		if particles then
			particles.Enabled = enabled
		end
	end)
end

return RunParticlesService
