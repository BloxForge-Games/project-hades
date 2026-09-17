--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

local DodgeController = require(ReplicatedStorage.Submodules.Core.Source.Controllers.DodgeController)
local Magic = require(ReplicatedStorage.Submodules.Core.Source.Network.Magic)

local MagicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.MagicNames)
local MagicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.MagicData)
local restoreWalkSpeed = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Movement.restoreWalkSpeed)
local emitVFXPart = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.emitVFXPart)

local CASTING_HUMANOID_WALK_SPEED = 2

-- The Roblox type definitions no longer allow indexing the root part off
-- the character; the cast keeps a missing one erroring where the old index did.
local function getRootPart(character: Model): BasePart
	return character:FindFirstChild("HumanoidRootPart") :: BasePart
end

return function(player: Player, preload: boolean?)
	local character = player.Character :: Model

	(character:FindFirstChildOfClass("Humanoid") :: Humanoid).WalkSpeed = CASTING_HUMANOID_WALK_SPEED

	local windbombAnimation = (character:WaitForChild("Humanoid"):FindFirstChildOfClass("Animator") :: Animator):LoadAnimation(
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
	windbombVFX.Parent = character:FindFirstChild("Right Arm")

	if not preload then
		local windBombSound = ReplicatedStorage.GameAssets.Sounds.WindBombCast:Clone()
		windBombSound.Parent = getRootPart(character)
		windBombSound:Play()
		Debris:AddItem(windBombSound, 5)
	end

	-- Where the bomb LANDS: the hitbox CFrame, taken on every viewer at the
	-- request beat (the caster's client sends it; the others compute the
	-- same point from the replicated root) so the ground dust below falls
	-- where the damage did, not where the explosion mesh is drawn.
	local impactCFrame: CFrame? = nil

	task.delay(0.75, function()
		local hitboxCFrame = getRootPart(character).CFrame
			+ getRootPart(character).CFrame.LookVector * MagicData[MagicNames["Wind Bomb"]].range
		impactCFrame = hitboxCFrame
		if player == Players.LocalPlayer and not preload then
			Magic.HitboxRequested.Fire({ MagicName = MagicNames["Wind Bomb"], CFrame = hitboxCFrame })
		end
	end)

	task.delay(0.85, function()
		local windbombExplosionVFX = ReplicatedStorage.GameAssets.VFX[MagicNames["Wind Bomb"]].ExplosionFX:Clone()
		windbombExplosionVFX.Parent = workspace.IgnoreInstances.MagicSpells
		windbombExplosionVFX.CFrame = getRootPart(character).CFrame + getRootPart(character).CFrame.LookVector * 5

		if not preload then
			windbombExplosionVFX.Explosion:Play()
		end

		for _, particle in pairs(windbombExplosionVFX.Attachment:GetDescendants()) do
			particle:Emit(35)
		end

		Debris:AddItem(windbombExplosionVFX, 5)

		-- The combat pack's dust at the landing point, on the explosion beat.
		emitVFXPart(
			"GroundDust",
			impactCFrame or windbombExplosionVFX.CFrame,
			nil,
			{ GroundSnapDistance = 10, GroundLift = 5 }
		)

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
