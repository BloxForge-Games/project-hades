local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")

local ColorCorrectionDefaults = require(ReplicatedStorage.Submodules.Core.Shared.Data.ColorCorrectionDefaults)

-- AUTHORED ColorCorrection tint, from ColorCorrectionDefaults (the one
-- source every grade-bending effect restores to). This effect tints the
-- screen and then puts it back; restoring to a literal would stomp the
-- place's own grade the moment it is authored as anything else.
local AUTHORED_TINT_COLOR = ColorCorrectionDefaults.TintColor
local Debris = game:GetService("Debris")

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)

local MagicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.MagicNames)
local MagicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.MagicData)
local restoreWalkSpeed = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Movement.restoreWalkSpeed)

local CutsceneController
local VFXService

Knit.OnStart():andThen(function()
	CutsceneController = Knit.GetController("CutsceneController")
	VFXService = Knit.GetService("VFXService")
end)

return function(player: Player, preload: boolean, cframe: CFrame)
	local character = player.Character

	if preload then
		return
	end

	character.Humanoid.WalkSpeed = 0

	local domainExpansionAnimation = character:WaitForChild("Humanoid"):FindFirstChildOfClass("Animator"):LoadAnimation(
		ReplicatedStorage.GameAssets.Animations:FindFirstChild("DomainExpansionAnimation")
	)

	if player == Players.LocalPlayer then
		cframe = character.HumanoidRootPart.CFrame
	end

	local shrineModel = ReplicatedStorage.GameAssets.VFX:FindFirstChild("Domain Expansion").Shrine:Clone()
	shrineModel:PivotTo(cframe * CFrame.Angles(0, math.rad(90), 0) + cframe.LookVector * -11 + Vector3.new(0, -15, 0))
	shrineModel.Parent = workspace.IgnoreInstances.Map.MagicSpells

	shrineModel.AppearPart.Position = character.HumanoidRootPart.Position + Vector3.new(0, -5, 0)
	shrineModel.AppearPart.Transparency = 1

	task.delay(0.15, function()
		-- Silent on the preload pass, like every other sound in here.
		if not preload then
			shrineModel.AppearPart.CastShockwave:Play()
		end

		for _, particle in ipairs(shrineModel.AppearPart:GetChildren()) do
			if particle:IsA("ParticleEmitter") then
				particle:Emit(10)
			end
		end
	end)

	domainExpansionAnimation:Play()
	domainExpansionAnimation:AdjustSpeed(0.35)

	if preload then
		domainExpansionAnimation:Stop()
		return
	end

	task.delay(1, function()
		domainExpansionAnimation:AdjustSpeed(0)
	end)

	if not preload then
		task.spawn(function()
			task.spawn(function()
				if player == Players.LocalPlayer and not preload then
					ReplicatedStorage.GameAssets.Sounds.DomainExpansionCast:Play()
				end
				-- "Domain Expansion..." / "...Malevolent Shrine!" are
				-- MagicData.dialogue beats (PlayerDialogueInterface), timed
				-- to this script's waits.
			end)
			task.wait(1)
			if player == Players.LocalPlayer and not preload then
				ReplicatedStorage.GameAssets.Sounds.DomainCastSound:Play()
			end

			shrineModel.Torso.Position = shrineModel.PrimaryPart.Position + Vector3.new(0, 12.5, 0)

			local torsoAttachment = shrineModel.Torso:FindFirstChildOfClass("Attachment")

			task.spawn(function()
				while torsoAttachment do
					torsoAttachment.Orientation += Vector3.new(0, 0.75, 0)
					task.wait()
				end
			end)

			for _, particle in ipairs(shrineModel.Torso.Main:GetChildren()) do
				if particle:IsA("ParticleEmitter") then
					particle.Enabled = true
				end
			end

			task.wait(1)

			if player == Players.LocalPlayer and not preload then
				ReplicatedStorage.GameAssets.Sounds.DomainExpansionRelease:Play()
			end

			task.wait(0.5)

			TweenService:Create(
				shrineModel.PrimaryPart,
				TweenInfo.new(1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ CFrame = shrineModel.PrimaryPart.CFrame + Vector3.new(0, 18, 0) }
			):Play()

			for _, shrinePart in pairs(shrineModel:GetDescendants()) do
				if shrinePart:IsA("MeshPart") then
					shrinePart.Transparency = 1
				end
			end

			for _, shrinePart in pairs(shrineModel:GetDescendants()) do
				if
					shrinePart:IsA("MeshPart")
					and shrinePart.Name ~= "DomainAttachmentPart"
					and shrinePart.Name ~= "Torso"
					and shrinePart.Name ~= "HighlightDetection"
				then
					TweenService:Create(
						shrinePart,
						TweenInfo.new(1.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
						{ Transparency = 0 }
					):Play()
				end
			end

			for _, particle in ipairs(shrineModel.AppearPart:GetChildren()) do
				if particle:IsA("ParticleEmitter") then
					particle:Emit(15)
				end
			end

			task.wait(0.15)

			CutsceneController:Shake(3.5, 20, 0.6)

			shrineModel.AppearPart.Shockwave:Play()

			task.wait(0.35)

			task.delay(1.5, function()
				CutsceneController:Shake(1, 20, MagicData[MagicNames["Domain Expansion"]].hitboxDuration + 2)

				for _, particle in shrineModel.DomainAttachmentPart.Attachment:GetChildren() do
					if particle:IsA("ParticleEmitter") then
						particle.Enabled = true
					end
				end

				for _, particle in shrineModel.Shrine.Main:GetChildren() do
					if particle:IsA("ParticleEmitter") then
						particle.Enabled = true
					end
				end

				TweenService:Create(
					Lighting.ColorCorrection,
					TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
					{ TintColor = Color3.fromRGB(236, 144, 146) }
				):Play()

				ReplicatedStorage.GameAssets.Sounds.Slashes:Play()

				for _, particle in pairs(shrineModel.SlashesPart:GetChildren()) do
					if particle:IsA("ParticleEmitter") then
						particle.Enabled = true
					end
				end
			end)

			task.wait(1)

			for _, particle in ipairs(shrineModel.Torso.Main:GetChildren()) do
				if particle:IsA("ParticleEmitter") then
					particle.ZOffset = 1
				end
			end

			local sukunaTheme = ReplicatedStorage.GameAssets.Sounds.SukunaTheme

			sukunaTheme.Volume = 0
			sukunaTheme:Play()
			sukunaTheme.TimePosition = 96

			TweenService
				:Create(
					sukunaTheme,
					TweenInfo.new(1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
					{ Volume = 0.1 }
				)
				:Play()

			VFXService:OnVFXPersistentHitboxRequested(
				player,
				MagicNames["Domain Expansion"],
				shrineModel.PrimaryPart.CFrame
			)

			task.delay(MagicData[MagicNames["Domain Expansion"]].hitboxDuration, function()
				-- Wait few extra seconds to account for delay from cutscenes and dialogues
				if player ~= Players.LocalPlayer then
					task.wait(2.5)
				end

				ReplicatedStorage.GameAssets.Sounds.Slashes:Stop()

				Debris:AddItem(shrineModel, 1)

				TweenService:Create(
					Lighting.ColorCorrection,
					TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
					{ TintColor = AUTHORED_TINT_COLOR }
				):Play()

				TweenService:Create(
					ReplicatedStorage.GameAssets.Sounds.SukunaTheme,
					TweenInfo.new(1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
					{ Volume = 0 }
				):Play()

				TweenService:Create(
					shrineModel.PrimaryPart,
					TweenInfo.new(1, Enum.EasingStyle.Quint, Enum.EasingDirection.In),
					{ CFrame = shrineModel.PrimaryPart.CFrame - Vector3.new(0, 18, 0) }
				):Play()

				for _, shrinePart in pairs(shrineModel:GetDescendants()) do
					if
						shrinePart:IsA("MeshPart")
						and shrinePart.Name ~= "DomainAttachmentPart"
						and shrinePart.Name ~= "Torso"
						and shrinePart.Name ~= "HighlightDetection"
					then
						TweenService:Create(
							shrinePart,
							TweenInfo.new(1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
							{ Transparency = 1 }
						):Play()
					end
				end

				for _, particle in pairs(shrineModel:GetDescendants()) do
					if particle:IsA("ParticleEmitter") then
						particle.Enabled = false
					end
				end
			end)
		end)
	end

	if player == Players.LocalPlayer and not preload then
		task.defer(function()
			CutsceneController:PlayCutscene("DomainExpansion")
		end)
	end

	task.delay(MagicData[MagicNames["Domain Expansion"]].duration, function()
		domainExpansionAnimation:Stop()

		-- Only if this cast still OWNS the slow: weaving a swing (or
		-- another spell) in takes the slow over, and that owner restores
		-- it on its own timer. See Shared/Functions/Movement/
		-- restoreWalkSpeed.
		restoreWalkSpeed(character, 0)
	end)
end
