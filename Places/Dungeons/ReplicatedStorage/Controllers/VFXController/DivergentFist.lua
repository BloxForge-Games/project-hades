--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

local DodgeController = require(ReplicatedStorage.Submodules.Core.Source.Controllers.DodgeController)
local Magic = require(ReplicatedStorage.Submodules.Core.Source.Network.Magic)

local MagicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.MagicNames)
local MagicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.MagicData)
local restoreWalkSpeed = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Movement.restoreWalkSpeed)
local claimWalkSpeed = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Movement.claimWalkSpeed)
local emitVFXPart = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.emitVFXPart)
local emitAttributeVFX = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.emitAttributeVFX)

local CASTING_HUMANOID_WALK_SPEED = 2

-- The Roblox type definitions no longer allow indexing the root part off
-- the character; the cast keeps a missing one erroring where the old index did.
local function getRootPart(character: Model): BasePart
	return character:FindFirstChild("HumanoidRootPart") :: BasePart
end

return function(player: Player, preload: boolean, _: CFrame)
	local character = player.Character :: Model

	-- Claimed, so only THIS cast's restore below can undo it (see claimWalkSpeed).
	local walkSpeedClaim = claimWalkSpeed(character, CASTING_HUMANOID_WALK_SPEED)

	local divergentFistAnimation = (character:WaitForChild("Humanoid"):FindFirstChildOfClass("Animator") :: Animator):LoadAnimation(
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
	divergentFistRight.Parent = character:FindFirstChild("Right Arm")

	local divergentFistLeft = ReplicatedStorage.GameAssets.VFX[MagicNames["Divergent Fist"]].Fists:Clone()
	divergentFistLeft.Parent = character:FindFirstChild("Left Arm")

	if not preload then
		local divergentFistSound = ReplicatedStorage.GameAssets.Sounds.DivergentFistCast:Clone()
		divergentFistSound.Parent = getRootPart(character)
		divergentFistSound:Play()
		Debris:AddItem(divergentFistSound, 5)
	end

	-- Where the punch LANDS: the hitbox CFrame, taken on every viewer at the
	-- request beat (the caster's client sends it; the others compute the
	-- same point from the replicated root) so the ground dust below falls
	-- where the damage did, not where the explosion mesh is drawn.
	local impactCFrame: CFrame? = nil

	task.delay(0.9, function()
		local hitboxCFrame = getRootPart(character).CFrame
			+ getRootPart(character).CFrame.LookVector * MagicData[MagicNames["Divergent Fist"]].range
		impactCFrame = hitboxCFrame
		if player == Players.LocalPlayer and not preload then
			Magic.HitboxRequested.Fire({ MagicName = MagicNames["Divergent Fist"], CFrame = hitboxCFrame })
		end
	end)

	task.delay(1, function()
		local divergentFistExplosion =
			ReplicatedStorage.GameAssets.VFX[MagicNames["Divergent Fist"]].ExplosionFX:Clone()
		divergentFistExplosion.Parent = workspace.IgnoreInstances.MagicSpells
		divergentFistExplosion:PivotTo(getRootPart(character).CFrame + getRootPart(character).CFrame.LookVector * 5)

		if not preload then
			divergentFistExplosion.PrimaryPart.Explosion:Play()
		end

		task.delay(0.05, function()
			-- Attachment2's emitters are ATTRIBUTE-driven (EmitCount / EmitDelay
			-- authored on each in Studio) and play on this same beat; the rest of
			-- the explosion keeps its hand-tuned burst, so those are skipped in
			-- the fixed loop below.
			local attributeAttachment = divergentFistExplosion:FindFirstChild("Attachment2", true)

			for _, particle in pairs(divergentFistExplosion:GetDescendants()) do
				if
					particle:IsA("ParticleEmitter")
					and not (attributeAttachment and particle:IsDescendantOf(attributeAttachment))
				then
					particle:Emit(15)
				end
			end

			if attributeAttachment then
				emitAttributeVFX(attributeAttachment)
			end
		end)

		Debris:AddItem(divergentFistExplosion, 5)

		-- The combat pack's dust at the landing point, on the explosion beat.
		emitVFXPart(
			"GroundDust",
			impactCFrame or divergentFistExplosion:GetPivot(),
			nil,
			{ GroundSnapDistance = 10, GroundLift = 5 }
		)

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
		restoreWalkSpeed(character, CASTING_HUMANOID_WALK_SPEED, walkSpeedClaim)
	end)
end
