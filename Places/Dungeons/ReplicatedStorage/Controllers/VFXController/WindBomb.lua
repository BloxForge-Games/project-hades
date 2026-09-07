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

return function(player: Player, preload: boolean?)
	local character = player.Character

	character.Humanoid.WalkSpeed = CASTING_HUMANOID_WALK_SPEED

	local windbombAnimation = character:WaitForChild("Humanoid"):FindFirstChildOfClass("Animator"):LoadAnimation(
		ReplicatedStorage.GameAssets.Animations:FindFirstChild("WindBombAnimation")
	)

	local animationConnection

	windbombAnimation:Play(0.25)

	if not preload and character then
		animationConnection = windbombAnimation:GetMarkerReachedSignal("MagicRelease"):Connect(function()
			animationConnection:Disconnect()

			if player == Players.LocalPlayer then
				print("Wind Bomb released - apply dodge impulse to player")
				DodgeController:SetDodgeCFrame(15, 0.35, true)
			end
		end)
	end

	local windbombVFX = ReplicatedStorage.GameAssets.VFX[MagicNames["Wind Bomb"]].CastFX:Clone()
	windbombVFX.Parent = character["Right Arm"]

	if not preload then
		local windBombSound = ReplicatedStorage.GameAssets.Sounds.WindBombCast:Clone()
		windBombSound.Parent = character.HumanoidRootPart
		windBombSound:Play()
		Debris:AddItem(windBombSound, 5)
	end

	task.delay(0.75, function()
		if player == Players.LocalPlayer and not preload then
			VFXService:OnVFXHitboxRequested(
				player,
				MagicNames["Wind Bomb"],
				character.HumanoidRootPart.CFrame
					+ character.HumanoidRootPart.CFrame.LookVector * MagicData[MagicNames["Wind Bomb"]].range
			)
		end
	end)

	task.delay(0.85, function()
		local windbombExplosionVFX = ReplicatedStorage.GameAssets.VFX[MagicNames["Wind Bomb"]].ExplosionFX:Clone()
		windbombExplosionVFX.Parent = workspace.IgnoreInstances.MagicSpells
		windbombExplosionVFX.CFrame = character.HumanoidRootPart.CFrame
			+ character.HumanoidRootPart.CFrame.LookVector * 5

		if not preload then
			windbombExplosionVFX.Explosion:Play()
		end

		for _, particle in pairs(windbombExplosionVFX.Attachment:GetDescendants()) do
			particle:Emit(35)
		end

		Debris:AddItem(windbombExplosionVFX, 5)

		for _, particle in pairs(windbombVFX:GetDescendants()) do
			particle.Enabled = false
		end

		Debris:AddItem(windbombVFX, 1)

		task.wait(0.2)

		-- Only if this cast still OWNS the slow: weaving a swing (or
		-- another spell) in takes the slow over, and that owner restores
		-- it on its own timer. See Shared/Functions/Movement/
		-- restoreWalkSpeed.
		restoreWalkSpeed(character, CASTING_HUMANOID_WALK_SPEED)
	end)
end
