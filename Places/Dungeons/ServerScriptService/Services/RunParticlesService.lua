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
-- Stronger than the authored asset (2026-11-05): more puffs, a little
-- denser, a little longer-lived (1.75 / 1.5 / 1.2 that afternoon, too
-- strong).
local SMOKE_RATE_SCALE = 1.4
local SMOKE_OPACITY_SCALE = 1.25
local SMOKE_LIFETIME_SCALE = 1.1

-- The asset's emitter made stronger on the clone (the asset is untouched):
-- the rate and lifetime scaled up, and every transparency keypoint pulled
-- toward opaque (1 - (1 - t) x scale), the fade-out end left at 1.
local function strengthen(emitter: ParticleEmitter)
	emitter.Rate *= SMOKE_RATE_SCALE
	emitter.Lifetime =
		NumberRange.new(emitter.Lifetime.Min * SMOKE_LIFETIME_SCALE, emitter.Lifetime.Max * SMOKE_LIFETIME_SCALE)
	local keypoints = {}
	for _, keypoint in emitter.Transparency.Keypoints do
		local value = if keypoint.Value >= 1
			then 1
			else math.clamp(1 - (1 - keypoint.Value) * SMOKE_OPACITY_SCALE, 0, 1)
		table.insert(keypoints, NumberSequenceKeypoint.new(keypoint.Time, value, keypoint.Envelope))
	end
	emitter.Transparency = NumberSequence.new(keypoints)
end

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
			for _, descendant in smokeClone:GetDescendants() do
				if descendant:IsA("ParticleEmitter") then
					strengthen(descendant)
					-- Starts off: the client's controller turns it on.
					descendant.Enabled = false
				end
			end
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
