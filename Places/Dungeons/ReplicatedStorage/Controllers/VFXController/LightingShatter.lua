--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Arcane = require(ReplicatedStorage.Submodules.Core.Source.Network.Arcane)

local ArcaneNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ArcaneNames)
local ArcaneData = require(ReplicatedStorage.Submodules.Core.Shared.Data.ArcaneData)
local restoreWalkSpeed = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Movement.restoreWalkSpeed)
local claimWalkSpeed = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Movement.claimWalkSpeed)
local radialGroundFracture = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.radialGroundFracture)
local emitVFXPart = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.emitVFXPart)
local GameClock = require(ReplicatedStorage.Submodules.Core.Shared.GameClock)
local vfxBudget = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.vfxBudget)
local loadOneShotAnimation = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Character.loadOneShotAnimation)

local CASTING_HUMANOID_WALK_SPEED = 2

return function(player: Player, preload: boolean, cframe: CFrame)
	local character = player.Character :: Model

	-- Claimed, so only THIS cast's restore below can undo it (see claimWalkSpeed).
	local walkSpeedClaim = claimWalkSpeed(character, CASTING_HUMANOID_WALK_SPEED)

	local lightingShatterAnimation = loadOneShotAnimation(
		character:WaitForChild("Humanoid"):FindFirstChildOfClass("Animator") :: Animator,
		ReplicatedStorage.GameAssets.Animations:FindFirstChild("LightingShatterAnimation")
	)

	lightingShatterAnimation:Play()

	local lightingShatterVFX = ReplicatedStorage.GameAssets.VFX[ArcaneNames["Lighting Shatter"]].Model:Clone()
	lightingShatterVFX.Parent = workspace.IgnoreInstances.ArcaneSpells
	-- Gone even if the cast is interrupted before MagicRelease (2026-11-05:
	-- the only cleanup was inside the marker, so a cut-off cast left the
	-- model in the workspace for good).
	GameClock.Debris(lightingShatterVFX, math.max(lightingShatterAnimation.Length, 1) + 8)

	-- The model's emitters, found once (each strike walked the model twice).
	local starterEmitters: { ParticleEmitter } = {}
	local bodyEmitters: { ParticleEmitter } = {}
	local starter = lightingShatterVFX:FindFirstChild("Starter")
	for _, descendant in lightingShatterVFX:GetDescendants() do
		if descendant:IsA("ParticleEmitter") then
			if starter and descendant:IsDescendantOf(starter) then
				table.insert(starterEmitters, descendant)
			end
			if descendant.Parent and descendant.Parent.Name ~= "StarterAttachment" then
				table.insert(bodyEmitters, descendant)
			end
		end
	end

	--TODO: REWRITE THIS, MAKE SERVER AUTHORATIVE ON SETTING THE CFRAME OF HITBOXES
	local cachedFrames = {
		cframe + cframe.LookVector * (ArcaneData[ArcaneNames["Lighting Shatter"]].range - 12) - Vector3.new(0, 1, 0),
		cframe + cframe.LookVector * (ArcaneData[ArcaneNames["Lighting Shatter"]].range - 6) - Vector3.new(0, 1, 0),
		cframe + cframe.LookVector * ArcaneData[ArcaneNames["Lighting Shatter"]].range - Vector3.new(0, 1, 0),
	}

	local animationConnection

	if not preload then
		ReplicatedStorage.GameAssets.Sounds.LightingShatterCast:Play()
	end

	GameClock.Delay(lightingShatterAnimation.Length - 0.1, function()
		-- Only if this cast still OWNS the slow: weaving a swing (or
		-- another spell) in takes the slow over, and that owner restores
		-- it on its own timer. See Shared/Functions/Movement/
		-- restoreWalkSpeed.
		restoreWalkSpeed(character, CASTING_HUMANOID_WALK_SPEED, walkSpeedClaim)
	end)

	animationConnection = lightingShatterAnimation:GetMarkerReachedSignal("MagicRelease"):Connect(function()
		animationConnection:Disconnect()

		task.spawn(function()
			for i = 1, 3, 1 do
				if player == Players.LocalPlayer and not preload then
					Arcane.HitboxRequested.Fire({
						ArcaneName = ArcaneNames["Lighting Shatter"],
						CFrame = cachedFrames[i],
					})
				end

				GameClock.Delay(0.1, function()
					lightingShatterVFX:PivotTo(cachedFrames[i])

					radialGroundFracture:Spawn(cachedFrames[i].Position, 6.5)

					-- The combat pack's dust under each strike, with its fracture.
					emitVFXPart(
						"GroundDust",
						cachedFrames[i],
						nil,
						-- Half again the pack size: each strike is a bigger impact
						-- than the other spells' single burst.
						{ GroundSnapDistance = 10, Scale = 1.5 }
					)

					for _, particle in starterEmitters do
						vfxBudget.emit(particle, 15)
					end

					GameClock.Delay(0.1, function()
						for _, particle in bodyEmitters do
							if particle.Parent then
								vfxBudget.emit(particle, if particle.Parent.Name ~= "ImpactAttachment" then 15 else 10)
							end
						end
					end)

					if not preload then
						lightingShatterVFX.GroundImpact.ElectricExplosion:Play()
						lightingShatterVFX.GroundImpact.ElectricExplosion2:Play()
					end
				end)

				GameClock.Wait(0.5)
			end
		end)
	end)
end
