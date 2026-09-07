local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)

local MagicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.MagicNames)
local MagicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.MagicData)
local restoreWalkSpeed = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Movement.restoreWalkSpeed)

local VFXService
local IgnoreListController

local CASTING_HUMANOID_WALK_SPEED = 2

Knit.OnStart():andThen(function()
	VFXService = Knit.GetService("VFXService")
	IgnoreListController = Knit.GetController("IgnoreListController")
end)

return function(player: Player, preload: boolean, cframe: CFrame)
	local character = player.Character

	character.Humanoid.WalkSpeed = CASTING_HUMANOID_WALK_SPEED

	local fireBlastAnimation = character:WaitForChild("Humanoid"):FindFirstChildOfClass("Animator"):LoadAnimation(
		ReplicatedStorage.GameAssets.Animations:FindFirstChild("FireBlastAnimation")
	)

	fireBlastAnimation:Play(0.25)

	local animationConnection

	animationConnection = fireBlastAnimation:GetMarkerReachedSignal("MagicRelease"):Connect(function()
		animationConnection:Disconnect()

		if not preload then
			local fireBlastSound = ReplicatedStorage.GameAssets.Sounds.FireBlastCast:Clone()
			fireBlastSound.Parent = character.HumanoidRootPart
			fireBlastSound.TimePosition = 0.1
			fireBlastSound:Play()
			Debris:AddItem(fireBlastSound, 5)
		end

		local castFX = ReplicatedStorage.GameAssets.VFX[MagicNames["Fire Blast"]].CastFX:Clone()
		castFX:PivotTo(cframe + Vector3.new(0, 1, 0))
		castFX.Parent = workspace.IgnoreInstances.MagicSpells

		local projectile = castFX

		local overlapParams = OverlapParams.new()
		overlapParams.FilterDescendantsInstances = IgnoreListController:GetMagicSpellIgnoreList()
		overlapParams.FilterType = Enum.RaycastFilterType.Exclude

		for _ = 0, MagicData[MagicNames["Fire Blast"]].travelDistance, 0.35 do
			task.wait(0.01)

			projectile.CFrame = projectile.CFrame + projectile.CFrame.LookVector * 1

			local partsArray = workspace:GetPartBoundsInRadius(
				projectile.Position,
				MagicData[MagicNames["Fire Blast"]].triggerRange,
				overlapParams
			)

			if #partsArray > 0 then
				break
			end
		end

		if player == Players.LocalPlayer and not preload then
			VFXService:OnVFXHitboxRequested(player, MagicNames["Fire Blast"], projectile.CFrame)
		end

		local fireBlastExplosionVFX = ReplicatedStorage.GameAssets.VFX[MagicNames["Fire Blast"]].ExplosionFX:Clone()
		fireBlastExplosionVFX.Parent = workspace.IgnoreInstances.MagicSpells
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
		restoreWalkSpeed(character, CASTING_HUMANOID_WALK_SPEED)
	end)
end
