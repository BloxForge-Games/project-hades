local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)

local MagicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.MagicNames)
local MagicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.MagicData)
local restoreWalkSpeed = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Movement.restoreWalkSpeed)
local groundFracture = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.groundFracture)

local VFXService

local CASTING_HUMANOID_WALK_SPEED = 2

Knit.OnStart():andThen(function()
	VFXService = Knit.GetService("VFXService")
end)

return function(player: Player, preload: boolean, cframe: CFrame)
	local character = player.Character

	character.Humanoid.WalkSpeed = CASTING_HUMANOID_WALK_SPEED

	local fireBlastAnimation = character:WaitForChild("Humanoid"):FindFirstChildOfClass("Animator"):LoadAnimation(
		ReplicatedStorage.GameAssets.Animations:FindFirstChild("HollowPurpleAnimation")
	)

	fireBlastAnimation:Play(0.25)

	local castFX = ReplicatedStorage.GameAssets.VFX[MagicNames["Hollow Purple"]].CastFX.Model:Clone()
	castFX:PivotTo(cframe + Vector3.new(0, 4, 0))
	castFX.Parent = workspace.IgnoreInstances.MagicSpells

	TweenService:Create(
		castFX.Blue,
		TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ CFrame = castFX.Merged.CFrame }
	):Play()

	TweenService:Create(
		castFX.Red,
		TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ CFrame = castFX.Merged.CFrame }
	):Play()

	task.delay(0.25, function()
		for _, v in pairs(castFX:GetDescendants()) do
			if v:IsA("ParticleEmitter") or v:IsA("Trail") then
				v.Enabled = false
			end
		end

		-- Silent on the preload pass: the sound sits on the HRP, so it is
		-- heard no matter where the off-screen preload cast is placed.
		if not preload then
			local hollowPurpleMergeSound = ReplicatedStorage.GameAssets.Sounds.HollowPurpleMerge:Clone()
			hollowPurpleMergeSound.Parent = character.HumanoidRootPart
			hollowPurpleMergeSound.TimePosition = 0.1
			hollowPurpleMergeSound:Play()
			Debris:AddItem(hollowPurpleMergeSound, 5)
		end

		for _, v in pairs(castFX.Merged:GetDescendants()) do
			if v:IsA("ParticleEmitter") then
				v:Emit(20)
			end
		end

		task.delay(0.5, function()
			local chargedFX = ReplicatedStorage.GameAssets.VFX[MagicNames["Hollow Purple"]].ChargeFX.Attachment:Clone()
			chargedFX.Parent = character["Right Arm"]

			task.delay(0.5, function()
				for _, v in pairs(chargedFX:GetDescendants()) do
					if v:IsA("ParticleEmitter") then
						v.Enabled = false
					end
				end

				Debris:AddItem(chargedFX, 1)
			end)
		end)

		Debris:AddItem(castFX, 1)
	end)

	local animationConnection

	animationConnection = fireBlastAnimation:GetMarkerReachedSignal("MagicRelease"):Connect(function()
		animationConnection:Disconnect()

		local projectile = ReplicatedStorage.GameAssets.VFX[MagicNames["Hollow Purple"]].Projectile.Part:Clone()
		projectile.CFrame = cframe + Vector3.new(0, 1, 0)
		projectile.Parent = workspace.IgnoreInstances.MagicSpells

		local origin = cframe
		local direction = origin.LookVector

		local STEP_LENGTH = MagicData[MagicNames["Hollow Purple"]].stepDistance
		local TRAVEL_DISTANCE = MagicData[MagicNames["Hollow Purple"]].travelDistance

		-- SERVER HIT VALIDATION
		if player == Players.LocalPlayer and not preload then
			VFXService:OnVFXSweepHitboxRequested(player, MagicNames["Hollow Purple"], origin)
		end

		task.delay(0.1, function()
			local colorCorrection = Instance.new("ColorCorrectionEffect")
			colorCorrection.Parent = Lighting
			colorCorrection.TintColor = Color3.fromRGB(255, 255, 255)
			colorCorrection.Brightness = 0.5
			TweenService:Create(
				colorCorrection,
				TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Brightness = 0 }
			):Play()

			Debris:AddItem(colorCorrection, 0.5)

			-- Silent on the preload pass, same reason as the merge sound above.
			if not preload then
				local hollowPurpleBlast1Sound = ReplicatedStorage.GameAssets.Sounds.HollowPurpleBlast1:Clone()
				hollowPurpleBlast1Sound.Parent = character.HumanoidRootPart
				hollowPurpleBlast1Sound:Play()
				Debris:AddItem(hollowPurpleBlast1Sound, 5)

				local hollowPurpleBlast2Sound = ReplicatedStorage.GameAssets.Sounds.HollowPurpleBlast2:Clone()
				hollowPurpleBlast2Sound.Parent = character.HumanoidRootPart
				hollowPurpleBlast2Sound:Play()
				Debris:AddItem(hollowPurpleBlast2Sound, 5)
			end

			task.delay(1, function()
				for _, particleEmitter in projectile:GetDescendants() do
					if particleEmitter:IsA("ParticleEmitter") then
						particleEmitter.Enabled = false
					end
				end

				Debris:AddItem(projectile, 1)
			end)

			for distance = 0, TRAVEL_DISTANCE, STEP_LENGTH do
				task.wait(0.01)

				local position = origin.Position + direction * distance

				local hitboxCFrame = CFrame.lookAt(position, position + direction)

				projectile.CFrame = hitboxCFrame

				if math.random(1, 3) == 1 then
					groundFracture:Spawn(
						projectile.Position,
						direction,
						MagicData[MagicNames["Hollow Purple"]].hitboxSize.Z
					)
				end
			end
		end)
	end)

	task.delay(1.5, function()
		-- Only if this cast still OWNS the slow: weaving a swing (or
		-- another spell) in takes the slow over, and that owner restores
		-- it on its own timer. See Shared/Functions/Movement/
		-- restoreWalkSpeed.
		restoreWalkSpeed(character, CASTING_HUMANOID_WALK_SPEED)
	end)
end
