--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local IgnoreListController = require(ReplicatedStorage.Submodules.Core.Source.Controllers.IgnoreListController)
local Arcane = require(ReplicatedStorage.Submodules.Core.Source.Network.Arcane)

local ArcaneNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ArcaneNames)
local ArcaneData = require(ReplicatedStorage.Submodules.Core.Shared.Data.ArcaneData)
local restoreWalkSpeed = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Movement.restoreWalkSpeed)
local claimWalkSpeed = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Movement.claimWalkSpeed)
local emitVFXPart = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.emitVFXPart)
local GameClock = require(ReplicatedStorage.Submodules.Core.Shared.GameClock)
local vfxBudget = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.vfxBudget)
local loadOneShotAnimation = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Character.loadOneShotAnimation)

local CASTING_HUMANOID_WALK_SPEED = 2

-- The cast sound shared by Fire Blast, Lighting Shatter and Shadow Clone
-- Barrage (2026-11-11): a 3D sound on the caster, so only players nearby
-- hear it.
local CAST_SOUND_ID = "rbxassetid://147722098"
local CAST_SOUND_VOLUME = 0.8
local CAST_SOUND_MIN_DISTANCE = 15
local CAST_SOUND_MAX_DISTANCE = 90
local CAST_SOUND_LIFETIME = 5

local function playCastSound(character: Model)
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end
	local sound = Instance.new("Sound")
	sound.Name = "CastSound"
	sound.SoundId = CAST_SOUND_ID
	sound.Volume = CAST_SOUND_VOLUME
	sound.RollOffMode = Enum.RollOffMode.InverseTapered
	sound.RollOffMinDistance = CAST_SOUND_MIN_DISTANCE
	sound.RollOffMaxDistance = CAST_SOUND_MAX_DISTANCE
	sound.Parent = root
	sound:Play()
	GameClock.Debris(sound, CAST_SOUND_LIFETIME)
end

-- The Roblox type definitions no longer allow indexing the root part off
-- the character; the cast keeps a missing one erroring where the old index did.
local function getRootPart(character: Model): BasePart
	return character:FindFirstChild("HumanoidRootPart") :: BasePart
end

return function(player: Player, preload: boolean, cframe: CFrame)
	local character = player.Character :: Model

	-- Claimed, so only THIS cast's restore below can undo it (see claimWalkSpeed).
	local walkSpeedClaim = claimWalkSpeed(character, CASTING_HUMANOID_WALK_SPEED)

	local fireBlastAnimation = loadOneShotAnimation(
		character:WaitForChild("Humanoid"):FindFirstChildOfClass("Animator") :: Animator,
		ReplicatedStorage.GameAssets.Animations:FindFirstChild("FireBlastAnimation")
	)

	fireBlastAnimation:Play(0.25)
	if not preload then
		playCastSound(character)
	end

	local animationConnection

	animationConnection = fireBlastAnimation:GetMarkerReachedSignal("MagicRelease"):Connect(function()
		animationConnection:Disconnect()

		if not preload then
			local fireBlastSound = ReplicatedStorage.GameAssets.Sounds.FireBlastCast:Clone()
			fireBlastSound.Parent = getRootPart(character)
			fireBlastSound.TimePosition = 0.1
			fireBlastSound:Play()
			GameClock.Debris(fireBlastSound, 5)
		end

		local castFX = ReplicatedStorage.GameAssets.VFX[ArcaneNames["Fire Blast"]].CastFX:Clone()
		castFX:PivotTo(cframe + Vector3.new(0, 1, 0))
		castFX.Parent = workspace.IgnoreInstances.ArcaneSpells

		local projectile = castFX

		local overlapParams = OverlapParams.new()
		overlapParams.FilterDescendantsInstances = IgnoreListController:GetArcaneSpellIgnoreList()
		overlapParams.FilterType = Enum.RaycastFilterType.Exclude

		-- One step per 60 fps frame (2026-11-05): a slower frame takes as
		-- many steps as frames it spans, so the blast flies as fast on a
		-- phone at 30 fps as on a PC (it was a step per frame: half speed).
		local totalSteps = math.floor(ArcaneData[ArcaneNames["Fire Blast"]].travelDistance / 0.35) + 1
		local stepsTaken = 0
		local blocked = false
		while stepsTaken < totalSteps and not blocked do
			local frameSeconds = GameClock.Wait(0.01) * GameClock.Scale()
			for _ = 1, math.clamp(math.floor(frameSeconds * 60 + 0.5), 1, 4) do
				stepsTaken += 1
				projectile.CFrame = projectile.CFrame + projectile.CFrame.LookVector * 1

				local partsArray = workspace:GetPartBoundsInRadius(
					projectile.Position,
					ArcaneData[ArcaneNames["Fire Blast"]].triggerRange,
					overlapParams
				)

				if #partsArray > 0 or stepsTaken >= totalSteps then
					blocked = #partsArray > 0
					break
				end
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
			vfxBudget.emit(particle, 25)
		end

		GameClock.Debris(fireBlastExplosionVFX, 5)

		-- The combat pack's dust where the projectile detonated.
		emitVFXPart("GroundDust", projectile.CFrame, nil, { GroundSnapDistance = 10 })

		for _, particle in pairs(castFX:GetDescendants()) do
			if particle:IsA("ParticleEmitter") then
				particle.Enabled = false
			end
		end

		GameClock.Debris(castFX, 1)
	end)

	GameClock.Delay(0.85, function()
		-- Only if this cast still OWNS the slow: weaving a swing (or
		-- another spell) in takes the slow over, and that owner restores
		-- it on its own timer. See Shared/Functions/Movement/
		-- restoreWalkSpeed.
		restoreWalkSpeed(character, CASTING_HUMANOID_WALK_SPEED, walkSpeedClaim)
	end)
end
