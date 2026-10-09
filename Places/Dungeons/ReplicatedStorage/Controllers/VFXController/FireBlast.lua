--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

local IgnoreListController = require(ReplicatedStorage.Controllers.IgnoreListController)
local Arcane = require(ReplicatedStorage.Submodules.Core.Source.Network.Arcane)

local ArcaneNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ArcaneNames)
local ArcaneData = require(ReplicatedStorage.Submodules.Core.Shared.Data.ArcaneData)
local restoreWalkSpeed = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Movement.restoreWalkSpeed)
local claimWalkSpeed = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Movement.claimWalkSpeed)
local emitVFXPart = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.emitVFXPart)

local CASTING_HUMANOID_WALK_SPEED = 2

-- The Roblox type definitions no longer allow indexing the root part off
-- the character; the cast keeps a missing one erroring where the old index did.
local function getRootPart(character: Model): BasePart
	return character:FindFirstChild("HumanoidRootPart") :: BasePart
end

return function(player: Player, preload: boolean, cframe: CFrame)
	local character = player.Character :: Model

	-- Claimed, so only THIS cast's restore below can undo it (see claimWalkSpeed).
	local walkSpeedClaim = claimWalkSpeed(character, CASTING_HUMANOID_WALK_SPEED)

	local fireBlastAnimation = (character:WaitForChild("Humanoid"):FindFirstChildOfClass("Animator") :: Animator):LoadAnimation(
		ReplicatedStorage.GameAssets.Animations:FindFirstChild("FireBlastAnimation")
	)

	fireBlastAnimation:Play(0.25)

	local animationConnection

	animationConnection = fireBlastAnimation:GetMarkerReachedSignal("MagicRelease"):Connect(function()
		animationConnection:Disconnect()

		if not preload then
			local fireBlastSound = ReplicatedStorage.GameAssets.Sounds.FireBlastCast:Clone()
			fireBlastSound.Parent = getRootPart(character)
			fireBlastSound.TimePosition = 0.1
			fireBlastSound:Play()
			Debris:AddItem(fireBlastSound, 5)
		end

		local castFX = ReplicatedStorage.GameAssets.VFX[ArcaneNames["Fire Blast"]].CastFX:Clone()
		castFX:PivotTo(cframe + Vector3.new(0, 1, 0))
		castFX.Parent = workspace.IgnoreInstances.ArcaneSpells

		local projectile = castFX

		local overlapParams = OverlapParams.new()
		overlapParams.FilterDescendantsInstances = IgnoreListController:GetArcaneSpellIgnoreList()
		overlapParams.FilterType = Enum.RaycastFilterType.Exclude

		for _ = 0, ArcaneData[ArcaneNames["Fire Blast"]].travelDistance, 0.35 do
			task.wait(0.01)

			projectile.CFrame = projectile.CFrame + projectile.CFrame.LookVector * 1

			local partsArray = workspace:GetPartBoundsInRadius(
				projectile.Position,
				ArcaneData[ArcaneNames["Fire Blast"]].triggerRange,
				overlapParams
			)

			if #partsArray > 0 then
				break
			end
		end

		if player == Players.LocalPlayer and not preload then
			Arcane.HitboxRequested.Fire({ ArcaneName = ArcaneNames["Fire Blast"], CFrame = projectile.CFrame })
		end

		local fireBlastExplosionVFX = ReplicatedStorage.GameAssets.VFX[ArcaneNames["Fire Blast"]].ExplosionFX:Clone()
		fireBlastExplosionVFX.Parent = workspace.IgnoreInstances.ArcaneSpells
		fireBlastExplosionVFX.CFrame = projectile.CFrame

		if not preload then
			fireBlastExplosionVFX.Explosion:Play()
			fireBlastExplosionVFX.Explosion2.TimePosition = 0.25
			fireBlastExplosionVFX.Explosion2:Play()
		end

		for _, particle in pairs(fireBlastExplosionVFX.Attachment:GetDescendants()) do
			particle:Emit(25)
		end

		Debris:AddItem(fireBlastExplosionVFX, 5)

		-- The combat pack's dust where the projectile detonated.
		emitVFXPart("GroundDust", projectile.CFrame, nil, { GroundSnapDistance = 10 })

		for _, particle in pairs(castFX:GetDescendants()) do
			if particle:IsA("ParticleEmitter") then
				particle.Enabled = false
			end
		end

		Debris:AddItem(castFX, 1)
	end)

	task.delay(0.85, function()
		-- Only if this cast still OWNS the slow: weaving a swing (or
		-- another spell) in takes the slow over, and that owner restores
		-- it on its own timer. See Shared/Functions/Movement/
		-- restoreWalkSpeed.
		restoreWalkSpeed(character, CASTING_HUMANOID_WALK_SPEED, walkSpeedClaim)
	end)
end
