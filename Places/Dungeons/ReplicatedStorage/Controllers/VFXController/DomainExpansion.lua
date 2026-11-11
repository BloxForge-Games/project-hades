--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

--[[
	SCREEN EFFECTS ARE CLAIMED, NOT WRITTEN. The tint, Sukuna's theme and
	the ambient shake all go through ArcaneAmbienceController under one
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

local CutsceneController = require(ReplicatedStorage.Controllers.CutsceneController)
local ArcaneAmbienceController = require(ReplicatedStorage.Controllers.ArcaneAmbienceController)
local CameraShakeController = require(ReplicatedStorage.Controllers.CameraShakeController)
local Arcane = require(ReplicatedStorage.Submodules.Core.Source.Network.Arcane)

local ArcaneNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ArcaneNames)
local CameraShakePresets = require(ReplicatedStorage.Submodules.Core.Shared.Enums.CameraShakePresets)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)

-- Both shakes go through the PRESET system (Shared/Data/CameraShakeData),
-- where their feel is tuned. `DomainAmbient` is the sustained rumble held
-- while you stand in the domain; `Medium` is the one-shot as the shrine
-- breaks the ground. It fires mid-cutscene, on top of the cinematic bob
-- (CameraShakeController's overlay composes after it).
local DOMAIN_AMBIENT_SHAKE = CameraShakePresets.DomainAmbient
-- The slow, eased cinematic rumble (2026-11-10; Medium before: too sharp
-- for the rise).
local SHRINE_SCALE = 1.1
-- How far short of its end the cast animation freezes (a non-looped track
-- that reaches its end stops and falls back to the idle): one frame.
local CAST_ANIMATION_END_MARGIN = 1 / 60
local DOMAIN_RISE_SHAKE = CameraShakePresets.CinematicImpact
local ArcaneData = require(ReplicatedStorage.Submodules.Core.Shared.Data.ArcaneData)
local restoreWalkSpeed = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Movement.restoreWalkSpeed)
local claimWalkSpeed = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Movement.claimWalkSpeed)
local emitVFXPart = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.emitVFXPart)
local GameClock = require(ReplicatedStorage.Submodules.Core.Shared.GameClock)
local vfxBudget = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.vfxBudget)
local loadOneShotAnimation = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Character.loadOneShotAnimation)

-- The Roblox type definitions no longer allow indexing the root part off
-- the character; the cast keeps a missing one erroring where the old index did.
local function getRootPart(character: Model): BasePart
	return character:FindFirstChild("HumanoidRootPart") :: BasePart
end

return function(player: Player, preload: boolean, cframe: CFrame)
	local character = player.Character :: Model

	if preload then
		return
	end

	-- Claimed, so only THIS cast's restore below can undo it (see claimWalkSpeed).
	local walkSpeedClaim = claimWalkSpeed(character, 0)

	local domainExpansionAnimation = loadOneShotAnimation(
		character:WaitForChild("Humanoid"):FindFirstChildOfClass("Animator") :: Animator,
		ReplicatedStorage.GameAssets.Animations:FindFirstChild("DomainExpansionAnimation")
	)

	if player == Players.LocalPlayer then
		cframe = getRootPart(character).CFrame
	end

	-- The cast's GROUND burst (2026-11-11): GameAssets.VFX["Domain
	-- Expansion"].Ground on the floor under the caster, the moment the cast
	-- (and the cutscene) starts. Each emitter bursts its EmitCount, 1 when
	-- it names none.
	emitVFXPart("Domain Expansion/Ground", cframe, nil, {
		GroundSnapDistance = 10,
		GroundFallbackDrop = 3,
		DefaultEmitCount = 1,
	})

	-- One ambience claim per cast (see the header): unique so two domains,
	-- from the same caster or different ones, never collide.
	local ambienceId = ("DomainExpansion_%d_%s"):format(player.UserId, tostring(GameClock.Now()))

	local shrineModel = ReplicatedStorage.GameAssets.VFX:FindFirstChild("Domain Expansion").Shrine:Clone()
	-- The shrine's Camera folder (Eyes, Flames) is the caster's cutscene
	-- screen effects (Cutscenes/DomainExpansion), not part of the shrine
	-- in the world.
	local screenEffects = shrineModel:FindFirstChild("Camera")
	if screenEffects then
		screenEffects:Destroy()
	end
	-- 10% bigger (2026-11-11; 20% briefly). It scales about its pivot (its main part,
	-- mid-height), which would sink its base: it is lifted by what the base
	-- dropped, so it stands on the same ground.
	local primary = shrineModel.PrimaryPart
	local baseDrop = if primary then (SHRINE_SCALE - 1) * primary.Size.Y / 2 else 0
	shrineModel:ScaleTo(shrineModel:GetScale() * SHRINE_SCALE)
	shrineModel:PivotTo(
		cframe * CFrame.Angles(0, math.rad(90), 0) + cframe.LookVector * -11 + Vector3.new(0, -15 + baseDrop, 0)
	)
	-- The caster hears their own shrine through their cutscene's isolation,
	-- which mutes the world's sounds (2026-11-10).
	if player == Players.LocalPlayer then
		for _, sound in shrineModel:GetDescendants() do
			if sound:IsA("Sound") then
				sound:SetAttribute(Attributes.CutsceneAudio, true)
			end
		end
	end
	shrineModel.Parent = workspace.IgnoreInstances.Map.ArcaneSpells

	shrineModel.AppearPart.Position = getRootPart(character).Position + Vector3.new(0, -5, 0)
	shrineModel.AppearPart.Transparency = 1

	GameClock.Delay(0.15, function()
		-- Silent on the preload pass, like every other sound in here.
		if not preload then
			shrineModel.AppearPart.CastShockwave:Play()
		end

		for _, particle in ipairs(shrineModel.AppearPart:GetChildren()) do
			if particle:IsA("ParticleEmitter") then
				vfxBudget.emit(particle, 10)
			end
		end
	end)

	domainExpansionAnimation:Play()
	GameClock.SetAnimationSpeed(domainExpansionAnimation, 0.35)

	if preload then
		domainExpansionAnimation:Stop()
		return
	end

	-- Frozen on its LAST frame, held for the domain (2026-11-11). It froze
	-- at a flat 1 s before, which at 0.35x is under half of the 0.72 s
	-- animation: the cast pose never finished.
	-- Watched every frame and frozen on its very last frame (2026-11-11:
	-- a timer froze it a little early). A track that runs past its end
	-- stops and falls back to the idle, so the freeze lands one frame short.
	local holdLastFrame: RBXScriptConnection
	holdLastFrame = RunService.Heartbeat:Connect(function(deltaTime: number)
		local length = domainExpansionAnimation.Length
		if not domainExpansionAnimation.IsPlaying or length <= 0 then
			if not domainExpansionAnimation.IsPlaying then
				holdLastFrame:Disconnect()
			end
			return
		end
		local nextPosition = domainExpansionAnimation.TimePosition + deltaTime * domainExpansionAnimation.Speed
		if nextPosition >= length then
			GameClock.SetAnimationSpeed(domainExpansionAnimation, 0)
			domainExpansionAnimation.TimePosition = length - CAST_ANIMATION_END_MARGIN
			holdLastFrame:Disconnect()
		end
	end)

	if not preload then
		task.spawn(function()
			task.spawn(function()
				if not preload then
					ReplicatedStorage.GameAssets.Sounds.DomainExpansionCast:Play()
				end
				-- "Domain Expansion..." / "...Malevolent Shrine!" are
				-- ArcaneData.dialogue beats (PlayerDialogueInterface), timed
				-- to this script's waits.
			end)
			GameClock.Wait(1)
			if not preload then
				ReplicatedStorage.GameAssets.Sounds.DomainCastSound:Play()
			end

			shrineModel.Torso.Position = shrineModel.PrimaryPart.Position + Vector3.new(0, 12.5, 0)

			local torsoAttachment = shrineModel.Torso:FindFirstChildOfClass("Attachment")

			-- The Attachment is a captured local, so it never goes nil on its
			-- own: stop when the shrine is destroyed (Debris, below) or this
			-- thread spins every frame for the rest of the session.
			task.spawn(function()
				-- 45 degrees a GAME second (it was 0.75 a frame: faster at a high
				-- frame rate, and blind to slow motion).
				while torsoAttachment and torsoAttachment.Parent do
					local dt = game:GetService("RunService").Heartbeat:Wait()
					torsoAttachment.Orientation += Vector3.new(0, 45 * GameClock.Dt(dt), 0)
				end
			end)

			for _, particle in ipairs(shrineModel.Torso.Main:GetChildren()) do
				if particle:IsA("ParticleEmitter") then
					particle.Enabled = true
				end
			end

			GameClock.Wait(1)

			if player == Players.LocalPlayer and not preload then
				ReplicatedStorage.GameAssets.Sounds.DomainExpansionRelease:Play()
			end

			GameClock.Wait(0.5)

			-- The combat pack's eruption where the shrine breaks the surface:
			-- its root's XZ at floor level, upright, on the rise beat. The
			-- floor ray starts at the CASTER's height -- the shrine itself is
			-- still 15 studs under the ground here.
			local shrineRootPosition: Vector3 = shrineModel.PrimaryPart.Position
			emitVFXPart(
				"ShrineAppear",
				cframe.Rotation + Vector3.new(shrineRootPosition.X, cframe.Position.Y, shrineRootPosition.Z),
				nil,
				-- Lifted a few studs: the eruption is authored to rise from its
				-- pivot, and resting on the floor read as buried on screen.
				{ GroundSnapDistance = 10, GroundFallbackDrop = 3, GroundLift = 0.25 }
			)

			GameClock.Tween(
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
					GameClock.Tween(
						shrinePart,
						TweenInfo.new(1.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
						{ Transparency = 0 }
					):Play()
				end
			end

			for _, particle in ipairs(shrineModel.AppearPart:GetChildren()) do
				if particle:IsA("ParticleEmitter") then
					vfxBudget.emit(particle, 15)
				end
			end

			GameClock.Wait(0.15)

			-- The shrine breaking through the ground.
			if CameraShakeController then
				CameraShakeController:Shake(DOMAIN_RISE_SHAKE)
			end

			shrineModel.AppearPart.Shockwave:Play()

			GameClock.Wait(0.35)

			GameClock.Delay(1.5, function()
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
				if ArcaneAmbienceController then
					ArcaneAmbienceController:ClaimAtPosition(ambienceId, {
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
				-- The caster's own domain is heard through their cutscene's
				-- isolation (it mutes the world's sounds, 2026-11-10).
				if player == Players.LocalPlayer then
					slashes:SetAttribute(Attributes.CutsceneAudio, true)
				end
				slashes.Parent = shrineModel.PrimaryPart
				slashes:Play()

				-- Both slash parts (SlashesPart2 added 2026-11-10), each
				-- optional so a model without the second still plays.
				for _, partName in { "SlashesPart", "SlashesPart2" } do
					local slashesPart = shrineModel:FindFirstChild(partName)
					if not slashesPart then
						continue
					end
					for _, particle in slashesPart:GetChildren() do
						if particle:IsA("ParticleEmitter") then
							particle.Enabled = true
						end
					end
				end
			end)

			GameClock.Wait(1)

			for _, particle in ipairs(shrineModel.Torso.Main:GetChildren()) do
				if particle:IsA("ParticleEmitter") then
					particle.ZOffset = 1
				end
			end

			Arcane.PersistentHitboxRequested.Fire({
				ArcaneName = ArcaneNames["Domain Expansion"],
				CFrame = shrineModel.PrimaryPart.CFrame,
			})

			GameClock.Delay(ArcaneData[ArcaneNames["Domain Expansion"]].hitboxDuration, function()
				-- Wait few extra seconds to account for delay from cutscenes and dialogues
				if player ~= Players.LocalPlayer then
					GameClock.Wait(2.5)
				end

				-- Tint / theme / shake let go together. Another domain still
				-- running keeps all three: the controller only lifts an
				-- effect when its LAST claim is released.
				if ArcaneAmbienceController then
					ArcaneAmbienceController:Release(ambienceId)
				end

				local slashes = shrineModel.PrimaryPart:FindFirstChild("Slashes")
				if slashes and slashes:IsA("Sound") then
					slashes:Stop()
				end

				GameClock.Debris(shrineModel, 1)

				GameClock.Tween(
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
						GameClock.Tween(
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
			-- Via the ArcaneData index (which names the "DomainExpansion"
			-- camera path), so the cutscene and the server's invulnerability
			-- window read the same numbers.
			CutsceneController:PlayArcaneCutscene(ArcaneNames["Domain Expansion"])
		end)
	end

	GameClock.Delay(ArcaneData[ArcaneNames["Domain Expansion"]].duration, function()
		domainExpansionAnimation:Stop()

		-- Only if this cast still OWNS the slow: weaving a swing (or
		-- another spell) in takes the slow over, and that owner restores
		-- it on its own timer. See Shared/Functions/Movement/
		-- restoreWalkSpeed.
		restoreWalkSpeed(character, 0, walkSpeedClaim)
	end)
end
