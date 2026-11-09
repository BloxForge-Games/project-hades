--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DodgeController = require(ReplicatedStorage.Submodules.Core.Source.Controllers.DodgeController)
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

-- The Roblox type definitions no longer allow indexing the root part off
-- the character; the cast keeps a missing one erroring where the old index did.
local function getRootPart(character: Model): BasePart
	return character:FindFirstChild("HumanoidRootPart") :: BasePart
end

return function(player: Player, preload: boolean?)
	local character = player.Character :: Model

	-- Claimed, so only THIS cast's restore below can undo it (see claimWalkSpeed).
	local walkSpeedClaim = claimWalkSpeed(character, CASTING_HUMANOID_WALK_SPEED)

	local windbombAnimation = loadOneShotAnimation(
		character:WaitForChild("Humanoid"):FindFirstChildOfClass("Animator") :: Animator,
		ReplicatedStorage.GameAssets.Animations:FindFirstChild("WindBombAnimation")
	)

	local animationConnection

	windbombAnimation:Play(0.25)

	if not preload and character then
		animationConnection = windbombAnimation:GetMarkerReachedSignal("MagicRelease"):Connect(function()
			animationConnection:Disconnect()

			if player == Players.LocalPlayer then
				-- 15 -> 12 studs (2026-11-08: 20% shorter).
				DodgeController:SetDodgeCFrame(12, 0.35, true)
			end
		end)
	end

	local windbombVFX = ReplicatedStorage.GameAssets.VFX[ArcaneNames["Wind Bomb"]].CastFX:Clone()
	windbombVFX.Parent = character:FindFirstChild("Right Arm")

	if not preload then
		local windBombSound = ReplicatedStorage.GameAssets.Sounds.WindBombCast:Clone()
		windBombSound.Parent = getRootPart(character)
		windBombSound:Play()
		GameClock.Debris(windBombSound, 5)
	end

	-- Where the bomb LANDS: the hitbox CFrame, taken on every viewer at the
	-- request beat (the caster's client sends it; the others compute the
	-- same point from the replicated root) so the ground dust below falls
	-- where the damage did, not where the explosion mesh is drawn.
	local impactCFrame: CFrame? = nil

	GameClock.Delay(0.75, function()
		local hitboxCFrame = getRootPart(character).CFrame
			+ getRootPart(character).CFrame.LookVector * ArcaneData[ArcaneNames["Wind Bomb"]].range
		impactCFrame = hitboxCFrame
		if player == Players.LocalPlayer and not preload then
			Arcane.HitboxRequested.Fire({ ArcaneName = ArcaneNames["Wind Bomb"], CFrame = hitboxCFrame })
		end
	end)

	GameClock.Delay(0.85, function()
		local windbombExplosionVFX = ReplicatedStorage.GameAssets.VFX[ArcaneNames["Wind Bomb"]].ExplosionFX:Clone()
		windbombExplosionVFX.Parent = workspace.IgnoreInstances.ArcaneSpells
		windbombExplosionVFX.CFrame = getRootPart(character).CFrame + getRootPart(character).CFrame.LookVector * 5

		if not preload then
			windbombExplosionVFX.Explosion:Play()
		end

		for _, particle in pairs(windbombExplosionVFX.Attachment:GetDescendants()) do
			vfxBudget.emit(particle, 35)
		end

		GameClock.Debris(windbombExplosionVFX, 5)

		GameClock.Delay(0.15, function()
			-- The combat pack's dust at the landing point, on the explosion beat.
			emitVFXPart(
				"GroundDust",
				impactCFrame or windbombExplosionVFX.CFrame,
				nil,
				{ GroundSnapDistance = 10, GroundLift = 5 }
			)
		end)

		for _, particle in pairs(windbombVFX:GetDescendants()) do
			particle.Enabled = false
		end

		GameClock.Debris(windbombVFX, 1)

		GameClock.Wait(0.2)

		-- Only if this cast still OWNS the slow: weaving a swing (or
		-- another spell) in takes the slow over, and that owner restores
		-- it on its own timer. See Shared/Functions/Movement/
		-- restoreWalkSpeed.
		restoreWalkSpeed(character, CASTING_HUMANOID_WALK_SPEED, walkSpeedClaim)
	end)
end
