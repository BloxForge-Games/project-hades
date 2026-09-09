local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)

local MagicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.MagicNames)
local MagicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.MagicData)
local restoreWalkSpeed = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Movement.restoreWalkSpeed)
local radialGroundFracture = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.radialGroundFracture)

local VFXService

local CASTING_HUMANOID_WALK_SPEED = 2

Knit.OnStart():andThen(function()
	VFXService = Knit.GetService("VFXService")
end)

return function(player: Player, preload: boolean, cframe: CFrame)
	local character = player.Character

	character.Humanoid.WalkSpeed = CASTING_HUMANOID_WALK_SPEED

	local lightingShatterAnimation = character:WaitForChild("Humanoid"):FindFirstChildOfClass("Animator"):LoadAnimation(
		ReplicatedStorage.GameAssets.Animations:FindFirstChild("LightingShatterAnimation")
	)

	lightingShatterAnimation:Play()

	local lightingShatterVFX = ReplicatedStorage.GameAssets.VFX[MagicNames["Lighting Shatter"]].Model:Clone()
	lightingShatterVFX.Parent = workspace.IgnoreInstances.MagicSpells

	--TODO: REWRITE THIS, MAKE SERVER AUTHORATIVE ON SETTING THE CFRAME OF HITBOXES
	local cachedFrames = {
		cframe + cframe.LookVector * (MagicData[MagicNames["Lighting Shatter"]].range - 12) - Vector3.new(0, 1, 0),
		cframe + cframe.LookVector * (MagicData[MagicNames["Lighting Shatter"]].range - 6) - Vector3.new(0, 1, 0),
		cframe + cframe.LookVector * MagicData[MagicNames["Lighting Shatter"]].range - Vector3.new(0, 1, 0),
	}

	local animationConnection

	if not preload then
		ReplicatedStorage.GameAssets.Sounds.LightingShatterCast:Play()
	end

	task.delay(lightingShatterAnimation.Length - 0.1, function()
		-- Only if this cast still OWNS the slow: weaving a swing (or
		-- another spell) in takes the slow over, and that owner restores
		-- it on its own timer. See Shared/Functions/Movement/
		-- restoreWalkSpeed.
		restoreWalkSpeed(character, CASTING_HUMANOID_WALK_SPEED)
	end)

	animationConnection = lightingShatterAnimation:GetMarkerReachedSignal("MagicRelease"):Connect(function()
		animationConnection:Disconnect()

		task.spawn(function()
			for i = 1, 3, 1 do
				if player == Players.LocalPlayer and not preload then
					VFXService:OnVFXHitboxRequested(player, MagicNames["Lighting Shatter"], cachedFrames[i])
				end

				task.delay(0.1, function()
					lightingShatterVFX:PivotTo(cachedFrames[i])

					radialGroundFracture:Spawn(cachedFrames[i].Position, 6.5)

					for _, particle in pairs(lightingShatterVFX:WaitForChild("Starter"):GetDescendants()) do
						if particle:IsA("ParticleEmitter") then
							particle:Emit(15)
						end
					end

					task.delay(0.1, function()
						for _, particle in pairs(lightingShatterVFX:GetDescendants()) do
							if particle:IsA("ParticleEmitter") and particle.Parent.Name ~= "StarterAttachment" then
								particle:Emit(if particle.Parent.Name ~= "ImpactAttachment" then 15 else 10)
							end
						end
					end)

					if not preload then
						lightingShatterVFX.GroundImpact.ElectricExplosion:Play()
						lightingShatterVFX.GroundImpact.ElectricExplosion2:Play()
					end

					Debris:AddItem(lightingShatterVFX, 5)
				end)

				task.wait(0.5)
			end
		end)
	end)
end
