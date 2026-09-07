local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)

local MagicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.MagicNames)
local MagicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.MagicData)
local restoreWalkSpeed = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Movement.restoreWalkSpeed)

local DodgeController
local VFXService

local CASTING_HUMANOID_WALK_SPEED = 2

Knit.OnStart():andThen(function()
	DodgeController = Knit.GetController("DodgeController")
	VFXService = Knit.GetService("VFXService")
end)

return function(player: Player, preload: boolean, _: CFrame)
	local character = player.Character

	character.Humanoid.WalkSpeed = CASTING_HUMANOID_WALK_SPEED

	local divergentFistAnimation = character:WaitForChild("Humanoid"):FindFirstChildOfClass("Animator"):LoadAnimation(
		ReplicatedStorage.GameAssets.Animations:FindFirstChild("DivergentFistAnimation")
	)

	local animationConnection

	divergentFistAnimation:Play(0.25)
	divergentFistAnimation:AdjustSpeed(1.35)

	if not preload and character then
		animationConnection = divergentFistAnimation:GetMarkerReachedSignal("MagicRelease"):Connect(function()
			animationConnection:Disconnect()

			if player == Players.LocalPlayer then
				DodgeController:SetDodgeCFrame(17, 0.4, true)
			end
		end)
	end

	local divergentFistRight = ReplicatedStorage.GameAssets.VFX[MagicNames["Divergent Fist"]].Fists:Clone()
	divergentFistRight.Parent = character["Right Arm"]

	local divergentFistLeft = ReplicatedStorage.GameAssets.VFX[MagicNames["Divergent Fist"]].Fists:Clone()
	divergentFistLeft.Parent = character["Left Arm"]

	if not preload then
		local divergentFistSound = ReplicatedStorage.GameAssets.Sounds.DivergentFistCast:Clone()
		divergentFistSound.Parent = character.HumanoidRootPart
		divergentFistSound:Play()
		Debris:AddItem(divergentFistSound, 5)
	end

	task.delay(0.9, function()
		if player == Players.LocalPlayer and not preload then
			VFXService:OnVFXHitboxRequested(
				player,
				MagicNames["Divergent Fist"],
				character.HumanoidRootPart.CFrame
					+ character.HumanoidRootPart.CFrame.LookVector * MagicData[MagicNames["Divergent Fist"]].range
			)
		end
	end)

	task.delay(1, function()
		local divergentFistExplosion =
			ReplicatedStorage.GameAssets.VFX[MagicNames["Divergent Fist"]].ExplosionFX:Clone()
		divergentFistExplosion.Parent = workspace.IgnoreInstances.MagicSpells
		divergentFistExplosion:PivotTo(
			character.HumanoidRootPart.CFrame + character.HumanoidRootPart.CFrame.LookVector * 5
		)

		if not preload then
			divergentFistExplosion.PrimaryPart.Explosion:Play()
		end

		for _, particle in pairs(divergentFistExplosion:GetDescendants()) do
			if particle:IsA("ParticleEmitter") then
				particle:Emit(15)
			end
		end

		Debris:AddItem(divergentFistExplosion, 5)

		for _, particle in pairs(divergentFistRight:GetDescendants()) do
			if particle:IsA("ParticleEmitter") then
				particle.Enabled = false
			end
		end

		for _, particle in pairs(divergentFistLeft:GetDescendants()) do
			if particle:IsA("ParticleEmitter") then
				particle.Enabled = false
			end
		end

		Debris:AddItem(divergentFistRight, 1)

		for _, particle in pairs(divergentFistLeft:GetDescendants()) do
			if particle:IsA("ParticleEmitter") then
				particle.Enabled = false
			end
		end

		Debris:AddItem(divergentFistLeft, 1)

		task.wait(0.2)

		-- Only if this cast still OWNS the slow: weaving a swing (or
		-- another spell) in takes the slow over, and that owner restores
		-- it on its own timer. See Shared/Functions/Movement/
		-- restoreWalkSpeed.
		restoreWalkSpeed(character, CASTING_HUMANOID_WALK_SPEED)
	end)
end
