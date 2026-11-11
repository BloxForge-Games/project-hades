--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local CutsceneController = require(ReplicatedStorage.Controllers.CutsceneController)
local ArcaneAmbienceController = require(ReplicatedStorage.Controllers.ArcaneAmbienceController)

-- The screen tint is CLAIMED through ArcaneAmbienceController, not written
-- to Lighting here: one global property cannot be owned by two casts, and
-- writing it directly meant a Susanoo landing inside a Domain Expansion
-- repainted the screen and then handed it back to the AUTHORED grade
-- rather than to the domain that still owned it. First claim holds.
-- 2026-11-09: only while the armour is up (its rise at appearSeconds to
-- its lifetime), not from the cast.
-- 2026-11-09: the authored grade with more contrast (purple 217, 156,
-- 255 before): white tint, contrast 0.4. 2026-11-10: purple again.
local SUSANOO_TINT_COLOR = Color3.fromRGB(217, 156, 255)
local SUSANOO_CONTRAST = 0.4
-- Named too, so the rise also lifts the cutscene's darker grade (-0.1
-- each until 9 s) back to the authored 0 rather than leaving it on.
local SUSANOO_BRIGHTNESS = 0
local SUSANOO_SATURATION = 0
-- How long after the cutscene's grade is put back the filter claims.
local FILTER_AFTER_GRADE_SECONDS = 0.05
-- Bumped per local cast: one claim id per caster, so a recast takes the
-- filter over (and re-applies it) and only the latest cast releases it.
local filterToken = 0

local ArcaneNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ArcaneNames)
local ArcaneData = require(ReplicatedStorage.Submodules.Core.Shared.Data.ArcaneData)
local restoreWalkSpeed = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Movement.restoreWalkSpeed)
local claimWalkSpeed = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Movement.claimWalkSpeed)
local emitVFXPart = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.emitVFXPart)
local CameraShakePresets = require(ReplicatedStorage.Submodules.Core.Shared.Enums.CameraShakePresets)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local CameraShakeController = require(ReplicatedStorage.Controllers.CameraShakeController)
local GameClock = require(ReplicatedStorage.Submodules.Core.Shared.GameClock)

-- The RISE IMPACT (2026-11-10: the rise read as anticlimactic), on the
-- spawn burst's beat, from existing assets.
-- Everyone: a purple shockwave and dust on the floor, and a purple light
-- flaring on the caster and dying away.
-- The caster's own screen: a purple-white flash, a blur pulse, an eased
-- rumble (CinematicImpact) and a soft FOV punch.
-- (The ground smash sound, the cracked-floor debris and the Large shake
-- went the same day.)
local RISE_SHOCKWAVE_VFX = "StormchargedShockwave"
local RISE_DUST_VFX = "GroundDust"
local RISE_GROUND_SNAP_STUDS = 12
local RISE_GLOW_COLOR = Color3.fromRGB(190, 110, 255)
local RISE_GLOW_BRIGHTNESS = 6
local RISE_GLOW_RANGE = 22
local RISE_GLOW_IN_SECONDS = 0.15
local RISE_GLOW_OUT_SECONDS = 1.2
local RISE_FLASH_COLOR = Color3.fromRGB(235, 205, 255)
local RISE_FLASH_TRANSPARENCY = 0.3
local RISE_FLASH_SECONDS = 0.35
local RISE_BLUR_SIZE = 16
local RISE_BLUR_SECONDS = 0.45
-- Eased in and out (2026-11-10; a 0.07 s linear snap read as a jolt).
local RISE_FOV_PUNCH = 8
local RISE_FOV_IN_SECONDS = 0.15
local RISE_FOV_OUT_SECONDS = 0.55

-- The spawn burst: GameAssets.VFX["Susanoo Armor"].SpawnPart, whose
-- attachment emitters carry their own EmitCount / EmitDelay /
-- EmitDuration (emitVFXPart reads them). Played on every client ON THE
-- SAME FRAME the server's CastPart lands: the server clones that part
-- into IgnoreInstances.ArcaneSpells at the caster's root once the rig
-- has risen (VFXServer/SusanooArmor), and it reaches each client a
-- replication hop later, so a fixed delay here always drifted from it.
-- This watches the folder for a CastPart arriving within
-- SPAWN_VFX_MATCH_STUDS of the caster and bursts a stud under it. If
-- none shows inside SPAWN_VFX_FALLBACK_SECONDS (the cast was refused,
-- or the part streamed elsewhere), the burst plays at the root anyway.
-- SPAWN only: the window closes long before the despawn CastPart.
-- The CastPart's own emitters burst here too (2026-11-10): the server's
-- Emit on it never reaches a client (ParticleEmitter:Emit draws only where
-- it is called), so it was never seen. CAST_PART_EMIT_COUNT each, unless
-- an emitter names its own EmitCount.
local CAST_PART_EMIT_COUNT = 5
-- On the CASTER's screen its particles are this size (2026-11-10): up to
-- 15 studs across, with the cutscene camera a few studs off, it overflowed
-- the screen. Everyone else sees it at full size from the normal camera.
local CAST_PART_OWN_SCALE = 0.4
local SPAWN_VFX_PATH = "Susanoo Armor/SpawnPart"
local SPAWN_VFX_OFFSET = CFrame.new(0, -1, 0)
local SPAWN_VFX_CAST_PART_NAME = "CastPart"
local SPAWN_VFX_MATCH_STUDS = 10
-- Past the rise (ArcaneData appearSeconds; 2 s when it rose at 0.5).
local SPAWN_VFX_FALLBACK_SECONDS = (ArcaneData[ArcaneNames["Susanoo Armor"]].appearSeconds or 0.5) + 1.5

-- The TORSO PARTICLES (2026-11-11): GameAssets.VFX["Susanoo Armor"]
-- .TorsoParticles (from the Sasuke model), two attachments cloned onto the
-- caster's torso, timed from the cast (the cutscene starts with it):
-- both from 1 s after waypoint 3 starts (1.75 + 1 = 2.75 s; 2026-11-11,
-- after trying waypoint 3 itself, the cast and 2 s); GroundParticles until the
-- rig rises from the ground (ArcaneData appearSeconds), SusanooParticle
-- until the Susanoo ends (lifetime). Each fades in and out: its emitters' Rate and
-- Transparency ease together, so the particles already out fade too.
local TORSO_PARTICLES_FOLDER = "TorsoParticles"
local WAYPOINT_3_AT = 1.75
local GROUND_PARTICLES_AT = WAYPOINT_3_AT + 1
local SUSANOO_PARTICLE_AT = WAYPOINT_3_AT + 1
local TORSO_PARTICLES_FADE_IN_SECONDS = 0.5
local TORSO_PARTICLES_FADE_OUT_SECONDS = 0.6
-- GroundParticles sits this far above the floor under the caster, found
-- by a ray (2026-11-11: its authored 3.18 studs under the torso came out
-- underground with the cast's pose).
local GROUND_PARTICLES_NAME = "GroundParticles"
local GROUND_PARTICLES_LIFT = 0.25
-- The relic trigger's wind (RelicTriggerController LOOP_SOUND_ID) loops
-- with GroundParticles, fading in and out with them (2026-11-11): on the
-- caster's camera for the caster (not muted by the cutscene's isolation),
-- on the caster's torso for everyone else.
local GROUND_WIND_SOUND_ID = "rbxassetid://128646536104501"
local GROUND_WIND_VOLUME = 0.35

-- Clones TorsoParticles' `name` onto `character`'s torso at `startAt`
-- seconds, fades it in, and from `stopAt` fades it out and removes it once
-- its last particles are gone.
local function playTorsoParticles(player: Player, character: Model, name: string, startAt: number, stopAt: number)
	local vfx = ReplicatedStorage.GameAssets:FindFirstChild("VFX")
	local armor = vfx and vfx:FindFirstChild("Susanoo Armor")
	local folder = armor and armor:FindFirstChild(TORSO_PARTICLES_FOLDER)
	local template = folder and folder:FindFirstChild(name)
	if not template then
		return
	end
	GameClock.Delay(startAt, function()
		local torso = character:FindFirstChild("Torso") or character:FindFirstChild("UpperTorso")
		if not character.Parent or not torso or not torso:IsA("BasePart") then
			return
		end
		local copy = template:Clone()
		local emitters: { { emitter: ParticleEmitter, rate: number, transparency: NumberSequence } } = {}
		local longestLife = 0
		for _, emitter in copy:GetDescendants() do
			if emitter:IsA("ParticleEmitter") then
				table.insert(emitters, { emitter = emitter, rate = emitter.Rate, transparency = emitter.Transparency })
				longestLife = math.max(longestLife, emitter.Lifetime.Max)
				emitter.Rate = 0
				emitter.Enabled = true
			end
		end
		-- 0 = unseen, 1 = as authored.
		local function setStrength(strength: number)
			for _, entry in emitters do
				entry.emitter.Rate = entry.rate * strength
				local points = {}
				for _, point in entry.transparency.Keypoints do
					local value = point.Value + (1 - point.Value) * (1 - strength)
					local envelope = math.min(point.Envelope, value, 1 - value)
					table.insert(points, NumberSequenceKeypoint.new(point.Time, value, envelope))
				end
				entry.emitter.Transparency = NumberSequence.new(points)
			end
		end
		setStrength(0)
		copy.Parent = torso
		local wind: Sound? = nil
		if name == GROUND_PARTICLES_NAME then
			local own = player == Players.LocalPlayer
			local sound = Instance.new("Sound")
			sound.Name = "SusanooGroundWind"
			sound.SoundId = GROUND_WIND_SOUND_ID
			sound.Looped = true
			sound.Volume = 0
			if own then
				sound:SetAttribute(Attributes.CutsceneAudio, true)
			end
			sound.Parent = if own then workspace.CurrentCamera else torso
			sound:Play()
			wind = sound
		end
		if name == GROUND_PARTICLES_NAME and copy:IsA("Attachment") then
			local params = RaycastParams.new()
			params.FilterType = Enum.RaycastFilterType.Exclude
			local ignore: { Instance } = { character }
			local ignoreFolder = workspace:FindFirstChild("IgnoreInstances")
			if ignoreFolder then
				for _, child in ignoreFolder:GetChildren() do
					if child.Name ~= "Map" then
						table.insert(ignore, child)
					end
				end
			end
			local baseplates = workspace:FindFirstChild("PlayerBaseplates")
			if baseplates then
				table.insert(ignore, baseplates)
			end
			params.FilterDescendantsInstances = ignore
			params.RespectCanCollide = true
			local hit = workspace:Raycast(torso.Position, Vector3.new(0, -20, 0), params)
			if hit then
				local at = copy.WorldPosition
				copy.WorldPosition = Vector3.new(at.X, hit.Position.Y + GROUND_PARTICLES_LIFT, at.Z)
			end
		end
		local elapsed = startAt
		local fadeOutEnd = stopAt + TORSO_PARTICLES_FADE_OUT_SECONDS
		local driver: RBXScriptConnection
		driver = RunService.Heartbeat:Connect(function(dt: number)
			elapsed += GameClock.Dt(dt)
			if not copy.Parent then
				driver:Disconnect()
				if wind then
					wind:Destroy()
				end
				return
			end
			if elapsed >= fadeOutEnd then
				driver:Disconnect()
				setStrength(0)
				if wind then
					wind:Destroy()
				end
				for _, entry in emitters do
					entry.emitter.Enabled = false
				end
				GameClock.Debris(copy, longestLife + 0.1)
				return
			end
			local fadeIn = math.clamp((elapsed - startAt) / TORSO_PARTICLES_FADE_IN_SECONDS, 0, 1)
			local fadeOut = 1 - math.clamp((elapsed - stopAt) / TORSO_PARTICLES_FADE_OUT_SECONDS, 0, 1)
			local strength = math.min(fadeIn, fadeOut)
			local eased = strength * strength * (3 - 2 * strength)
			setStrength(eased)
			if wind then
				wind.Volume = GROUND_WIND_VOLUME * eased
			end
		end)
	end)
end

-- The caster's screen part of the impact.
local function playOwnRiseImpact()
	-- SusanooActivate: the server plays it on the rig, but the caster's own
	-- cutscene mutes every world sound (CutsceneIsolationController), so
	-- the caster hears this local copy instead (2026-11-10).
	local folder = ReplicatedStorage.GameAssets.VFX:FindFirstChild("Susanoo Armor")
	local armor = folder and folder:FindFirstChild("Armor")
	local template = armor and armor:FindFirstChild("SusanooActivate", true)
	if template and template:IsA("Sound") then
		local activate = template:Clone()
		activate:SetAttribute(Attributes.CutsceneAudio, true)
		activate.Parent = workspace.CurrentCamera
		activate:Play()
		GameClock.Debris(activate, math.max(activate.TimeLength, 3) + 1)
	end

	if CameraShakeController then
		CameraShakeController:Shake(CameraShakePresets.CinematicImpact)
	end

	local playerGui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if playerGui then
		local gui = Instance.new("ScreenGui")
		gui.Name = "SusanooRiseFlash"
		gui.IgnoreGuiInset = true
		gui.DisplayOrder = 50
		local frame = Instance.new("Frame")
		frame.Size = UDim2.fromScale(1, 1)
		frame.BorderSizePixel = 0
		frame.BackgroundColor3 = RISE_FLASH_COLOR
		frame.BackgroundTransparency = RISE_FLASH_TRANSPARENCY
		frame.Parent = gui
		gui.Parent = playerGui
		TweenService:Create(frame, TweenInfo.new(RISE_FLASH_SECONDS, Enum.EasingStyle.Quad), {
			BackgroundTransparency = 1,
		}):Play()
		GameClock.Debris(gui, RISE_FLASH_SECONDS + 0.1)
	end

	local blur = Instance.new("BlurEffect")
	blur.Name = "SusanooRiseBlur"
	blur.Size = RISE_BLUR_SIZE
	blur.Parent = Lighting
	TweenService:Create(blur, TweenInfo.new(RISE_BLUR_SECONDS, Enum.EasingStyle.Quad), { Size = 0 }):Play()
	GameClock.Debris(blur, RISE_BLUR_SECONDS + 0.1)

	-- An offset on top of whatever writes the FOV (the cutscene's tween,
	-- or nothing): last frame's offset is taken off before this frame's
	-- goes on, so it never piles up.
	-- If something ELSE set the FOV since our last write (the cutscene
	-- restoring the player's FOV as it ends), that value is the clean base
	-- and our offset is no longer in it (2026-11-11: taking it off anyway
	-- left the camera zoomed in by the punch after the cutscene).
	local started = GameClock.Now()
	local applied = 0
	local lastWritten: number? = nil
	local connection: RBXScriptConnection
	connection = RunService.RenderStepped:Connect(function()
		local camera = workspace.CurrentCamera
		local elapsed = GameClock.Now() - started
		local offset = 0
		if elapsed < RISE_FOV_IN_SECONDS then
			local alpha = elapsed / RISE_FOV_IN_SECONDS
			offset = RISE_FOV_PUNCH * (1 - (1 - alpha) ^ 2)
		elseif elapsed < RISE_FOV_IN_SECONDS + RISE_FOV_OUT_SECONDS then
			local alpha = (elapsed - RISE_FOV_IN_SECONDS) / RISE_FOV_OUT_SECONDS
			offset = RISE_FOV_PUNCH * (1 - alpha * alpha * (3 - 2 * alpha))
		end
		if camera then
			local current = camera.FieldOfView
			local base = if lastWritten and math.abs(current - lastWritten) < 1e-3 then current - applied else current
			camera.FieldOfView = base + offset
			lastWritten = camera.FieldOfView
		end
		applied = offset
		if elapsed >= RISE_FOV_IN_SECONDS + RISE_FOV_OUT_SECONDS then
			connection:Disconnect()
		end
	end)
end

-- The whole impact at `at` (the caster's root frame) for `caster`.
local function playRiseImpact(caster: Player, at: CFrame)
	local ground = { GroundSnapDistance = RISE_GROUND_SNAP_STUDS }
	emitVFXPart(RISE_SHOCKWAVE_VFX, at, nil, ground)
	emitVFXPart(RISE_DUST_VFX, at, nil, ground)

	local root = caster.Character and caster.Character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		local glow = Instance.new("PointLight")
		glow.Name = "SusanooRiseGlow"
		glow.Color = RISE_GLOW_COLOR
		glow.Range = RISE_GLOW_RANGE
		glow.Brightness = 0
		glow.Parent = root
		TweenService:Create(glow, TweenInfo.new(RISE_GLOW_IN_SECONDS), { Brightness = RISE_GLOW_BRIGHTNESS }):Play()
		GameClock.Delay(RISE_GLOW_IN_SECONDS, function()
			TweenService:Create(glow, TweenInfo.new(RISE_GLOW_OUT_SECONDS, Enum.EasingStyle.Quad), {
				Brightness = 0,
			}):Play()
		end)
		GameClock.Debris(glow, RISE_GLOW_IN_SECONDS + RISE_GLOW_OUT_SECONDS + 0.1)
	end

	if caster == Players.LocalPlayer then
		playOwnRiseImpact()
	end
end

return function(player: Player, preload: boolean?)
	local character = player.Character :: Model

	-- The spawn warm-up (PreloadController runs every effect module once
	-- with preload) has nothing to warm here any more, and must not root:
	-- the claim below ran on preload too and held the player in place for
	-- the cast's root on every spawn (2026-11-09).
	if preload then
		return
	end

	-- Claimed, so only THIS cast's restore below can undo it (see claimWalkSpeed).
	local walkSpeedClaim = claimWalkSpeed(character, 0)

	-- No character animation since 2026-11-09 (SusanooArmorAnimation at 0.3x
	-- before; a replacement is coming). ArcaneData keeps castAnimation set:
	-- arcaneIndex.isCastable needs it. No cast line or voice line either:
	-- the cutscene's own sound cues (CutsceneController/Cutscenes/Susanoo)
	-- carry it.

	if not preload then
		local armorData = ArcaneData[ArcaneNames["Susanoo Armor"]]
		local riseAt = armorData.appearSeconds or 0.5
		playTorsoParticles(player, character, GROUND_PARTICLES_NAME, GROUND_PARTICLES_AT, riseAt)
		playTorsoParticles(player, character, "SusanooParticle", SUSANOO_PARTICLE_AT, armorData.lifetime)

		-- Spawn burst, on the CastPart's own frame (see SPAWN_VFX_PATH).
		local ignoreInstances = workspace:FindFirstChild("IgnoreInstances")
		local spellsFolder = ignoreInstances and ignoreInstances:FindFirstChild("ArcaneSpells")
		local burstPlayed = false
		local castPartWatch: RBXScriptConnection? = nil
		local function playSpawnBurst(at: CFrame)
			if burstPlayed then
				return
			end
			burstPlayed = true
			if castPartWatch then
				castPartWatch:Disconnect()
			end
			emitVFXPart(SPAWN_VFX_PATH, at * SPAWN_VFX_OFFSET)
			playRiseImpact(player, at)
		end
		if spellsFolder then
			castPartWatch = spellsFolder.ChildAdded:Connect(function(child: Instance)
				if child.Name ~= SPAWN_VFX_CAST_PART_NAME or not child:IsA("BasePart") then
					return
				end
				local root = character:FindFirstChild("HumanoidRootPart")
				if
					root
					and root:IsA("BasePart")
					and (child.Position - root.Position).Magnitude <= SPAWN_VFX_MATCH_STUDS
				then
					local own = player == Players.LocalPlayer
					for _, emitter in child:GetDescendants() do
						if emitter:IsA("ParticleEmitter") then
							if own then
								local points = {}
								for _, point in emitter.Size.Keypoints do
									table.insert(
										points,
										NumberSequenceKeypoint.new(
											point.Time,
											point.Value * CAST_PART_OWN_SCALE,
											point.Envelope * CAST_PART_OWN_SCALE
										)
									)
								end
								emitter.Size = NumberSequence.new(points)
								emitter.Speed = NumberRange.new(
									emitter.Speed.Min * CAST_PART_OWN_SCALE,
									emitter.Speed.Max * CAST_PART_OWN_SCALE
								)
							end
							emitter:Emit(tonumber(emitter:GetAttribute("EmitCount")) or CAST_PART_EMIT_COUNT)
						end
					end
					playSpawnBurst(child.CFrame)
				end
			end)
		end
		GameClock.Delay(SPAWN_VFX_FALLBACK_SECONDS, function()
			if burstPlayed then
				return
			end
			local root = character:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") and character.Parent then
				playSpawnBurst(root.CFrame)
			elseif castPartWatch then
				castPartWatch:Disconnect()
			end
		end)
	end

	if player == Players.LocalPlayer and not preload then
		task.defer(function()
			-- ArcaneData.cutscene names the "Susanoo" camera path (two
			-- waypoints pivoted to the caster, GameAssets.CutsceneWaypoints
			-- .SusanooWaypoints). Going through the data index rather than
			-- PlayCutscene directly keeps the camera move and the server's
			-- invulnerability window reading the same numbers.
			CutsceneController:PlayArcaneCutscene(ArcaneNames["Susanoo Armor"])
		end)

		-- The viewer's OWN Susanoo, so no proximity: it is on their body.
		-- From the rise to the despawn.
		local data = ArcaneData[ArcaneNames["Susanoo Armor"]]
		local appearSeconds = data.appearSeconds or 0.5
		-- With the Sharingan (ArcaneData filterAt, 2026-11-10): it fades
		-- over the cutscene's darker grade, which CutsceneController then
		-- leaves alone (it only puts back what still holds its own value).
		-- Without one: once the cutscene's grade is put back (its end plus
		-- gradeHoldSeconds), a beat after it so the put-back lands first.
		local cutscene = data.cutscene
		local filterAt = appearSeconds
		if typeof(data.filterAt) == "number" then
			filterAt = data.filterAt
		elseif cutscene and cutscene.enabled == true and typeof(cutscene.duration) == "number" then
			filterAt =
				math.max(filterAt, cutscene.duration + (cutscene.gradeHoldSeconds or 0) + FILTER_AFTER_GRADE_SECONDS)
		end
		if ArcaneAmbienceController and data.lifetime > filterAt then
			local ambienceId = "Susanoo_" .. tostring(player.UserId)
			filterToken += 1
			local token = filterToken
			GameClock.Delay(filterAt, function()
				if token ~= filterToken then
					return
				end
				ArcaneAmbienceController:Claim(ambienceId, {
					tint = SUSANOO_TINT_COLOR,
					contrast = SUSANOO_CONTRAST,
					brightness = SUSANOO_BRIGHTNESS,
					saturation = SUSANOO_SATURATION,
				})
			end)
			-- The rig sinks for 1 s after its lifetime before the server
			-- destroys it (VFXServer/SusanooArmor); the grade holds 1 s
			-- past that (2026-11-09: it came back too soon).
			GameClock.Delay(data.lifetime + 2, function()
				if token ~= filterToken then
					return
				end
				ArcaneAmbienceController:Release(ambienceId)
			end)
		end
	end

	-- Rooted until the cast AND its cutscene are over (2026-11-09; the
	-- cast's 2.25 s alone before, which freed the caster mid-cutscene).
	local data = ArcaneData[ArcaneNames["Susanoo Armor"]]
	local rootedSeconds = math.max(data.duration or 0, (data.cutscene and data.cutscene.duration) or 0)
	GameClock.Delay(rootedSeconds, function()
		-- Only if this cast still OWNS the slow: weaving a swing (or
		-- another spell) in takes the slow over, and that owner restores
		-- it on its own timer. See Shared/Functions/Movement/
		-- restoreWalkSpeed.
		--
		-- The claim is 0 because that is what this cast WROTE (above), not
		-- the 2 its sibling spells use. Claiming 2 here could never match
		-- the humanoid's 0, so the restore would silently never fire and
		-- the player would stay rooted. Domain Expansion, the other spell
		-- that roots fully, claims 0 for the same reason.
		restoreWalkSpeed(character, 0, walkSpeedClaim)
	end)
end
