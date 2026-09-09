local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Debris = game:GetService("Debris")

--[[
	SCREEN EFFECTS ARE CLAIMED, NOT WRITTEN. The tint, Sukuna's theme and
	the ambient shake all go through MagicAmbienceController under one
	claim id per cast, which means:
	  * two domains produce ONE tint, ONE theme and ONE shake, and they
	    lift only when the LAST domain ends -- the first one ending used to
	    restore the grade, stop the music and drop the shake out from under
	    the second;
	  * a Susanoo cast during a domain no longer repaints the screen and
	    hands it back to the authored grade;
	  * all three are PROXIMITY-gated (DOMAIN_AMBIENCE_RADIUS_STUDS): they
	    follow you in and out of the shrine's neighbourhood, and two
	    overlapping domains cross-fade rather than fighting.
	The shrine, its particles and its rise stay GLOBAL, so a domain going
	up across the room still telegraphs itself.
]]
local DOMAIN_AMBIENCE_RADIUS_STUDS = 40
local DOMAIN_TINT_COLOR = Color3.fromRGB(236, 144, 146)
local SUKUNA_THEME_SOUND_NAME = "SukunaTheme"
local SUKUNA_THEME_START_TIME = 96
local SUKUNA_THEME_VOLUME = 0.075

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)

local MagicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.MagicNames)
local CameraShakePresets = require(ReplicatedStorage.Submodules.Core.Shared.Enums.CameraShakePresets)

-- Both shakes go through the PRESET system (Shared/Data/CameraShakeData),
-- where their feel is tuned. `DomainAmbient` is the sustained rumble held
-- while you stand in the domain; `Medium` is the one-shot as the shrine
-- breaks the ground. It fires mid-cutscene, on top of the cinematic bob
-- (CameraShakeController's overlay composes after it).
local DOMAIN_AMBIENT_SHAKE = CameraShakePresets.DomainAmbient
local DOMAIN_RISE_SHAKE = CameraShakePresets.Medium
local MagicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.MagicData)
local restoreWalkSpeed = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Movement.restoreWalkSpeed)

local CutsceneController
local VFXService
local MagicAmbienceController
local CameraShakeController

Knit.OnStart():andThen(function()
	CutsceneController = Knit.GetController("CutsceneController")
	VFXService = Knit.GetService("VFXService")
	MagicAmbienceController = Knit.GetController("MagicAmbienceController")
	CameraShakeController = Knit.GetController("CameraShakeController")
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

	-- One ambience claim per cast (see the header): unique so two domains,
	-- from the same caster or different ones, never collide.
	local ambienceId = ("DomainExpansion_%d_%s"):format(player.UserId, tostring(os.clock()))

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
				if not preload then
					ReplicatedStorage.GameAssets.Sounds.DomainExpansionCast:Play()
				end
				-- "Domain Expansion..." / "...Malevolent Shrine!" are
				-- MagicData.dialogue beats (PlayerDialogueInterface), timed
				-- to this script's waits.
			end)
			task.wait(1)
			if not preload then
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

			-- The shrine breaking through the ground.
			if CameraShakeController then
				CameraShakeController:Shake(DOMAIN_RISE_SHAKE)
			end

			shrineModel.AppearPart.Shockwave:Play()

			task.wait(0.35)

			task.delay(1.5, function()
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

				-- Tint + theme + shake, as ONE proximity claim (see the header).
				if MagicAmbienceController then
					MagicAmbienceController:ClaimAtPosition(ambienceId, {
						tint = DOMAIN_TINT_COLOR,
						music = {
							soundName = SUKUNA_THEME_SOUND_NAME,
							volume = SUKUNA_THEME_VOLUME,
							startTime = SUKUNA_THEME_START_TIME,
						},
						shake = DOMAIN_AMBIENT_SHAKE,
					}, function(): Vector3?
						return if shrineModel.Parent then shrineModel.PrimaryPart.Position else nil
					end, DOMAIN_AMBIENCE_RADIUS_STUDS)
				end

				-- Slashes: a CLONE parented to the shrine, so it attenuates
				-- with distance and two domains genuinely layer. The shared
				-- template was played and stopped by every cast at once,
				-- which is how one domain ending silenced another.
				local slashes = ReplicatedStorage.GameAssets.Sounds.Slashes:Clone()
				slashes.Name = "Slashes"
				slashes.RollOffMaxDistance = 200
				slashes.Parent = shrineModel.PrimaryPart
				slashes:Play()

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

				-- Tint / theme / shake let go together. Another domain still
				-- running keeps all three: the controller only lifts an
				-- effect when its LAST claim is released.
				if MagicAmbienceController then
					MagicAmbienceController:Release(ambienceId)
				end

				local slashes = shrineModel.PrimaryPart:FindFirstChild("Slashes")
				if slashes and slashes:IsA("Sound") then
					slashes:Stop()
				end

				Debris:AddItem(shrineModel, 1)

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
			-- Via the MagicData index (which names the "DomainExpansion"
			-- camera path), so the cutscene and the server's invulnerability
			-- window read the same numbers.
			CutsceneController:PlayMagicCutscene(MagicNames["Domain Expansion"])
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
