--!strict
--[[
     Author(s):
     Module: BreakableController.lua
     Description: Client-side hit feedback for Breakable models.

                  Each hit:
                   1. Flashes a red Highlight on the model (instance reused
                      across hits — see Shared/Functions/Highlight/onDamageIndicator),
                      eased in and out on the shake's own timing and easing
                      (HIGHLIGHT_TIMING) so flash and shake read as one
                      motion -- the same for pots, veins and barricades.
                   2. Plays a short shake animation by tilting the model to a
                      random angle and back. Uses Model:PivotTo via Heartbeat
                      so unwelded parts move as a unit — no welds required.

                  Both effects override gracefully if a new hit lands during
                  the previous shake: the old shake is cancelled and the new
                  one starts from the model's current visual pose so there's
                  no jump.

                  LOOT breakables (BreakStyle set: BreakableLootService's
                  pots and veins) do not fall apart on the server. Their
                  breaking hit plays here instead, on this client only:
                    "Shatter" (pots)  the model vanishes into a burst of
                                      small shards in its ShardColor.
                    "Sink"    (veins) glowing shards, a Medium camera shake
                                      for anyone close, a spray of ore
                                      chunks that arc out around it, land
                                      and fade (visual only -- the real
                                      Ore is the server's pickup), then the
                                      model sinks into the floor as it and
                                      its light fade; every hit before
                                      that shrinks it a little.
]]

--[ Roblox Services ]--

local Debris = game:GetService("Debris")
local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

--[ Exports & Types & Defaults ]--

local Combat = require(ReplicatedStorage.Submodules.Core.Source.Network.Combat)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local onDamageIndicator = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Highlight.onDamageIndicator)
local playHitBurst = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.playHitBurst)
local CollisionGroups = require(ReplicatedStorage.Submodules.Core.Shared.Enums.CollisionGroups)
local BreakableLootData = require(ReplicatedStorage.Submodules.Core.Shared.Data.BreakableLootData)
local CameraShakePresets = require(ReplicatedStorage.Submodules.Core.Shared.Enums.CameraShakePresets)
local CameraShakeController = require(ReplicatedStorage.Controllers.CameraShakeController)

local BreakableController = {
	Name = "BreakableController",
}

--[ Imports ]--

--[ Constants ]--

local ATTACK_HIGHLIGHT_NAME = "BuildDamageIndicator"

local SHAKE_OUT_DURATION = 0.1 -- time to tilt out to the random angle
local SHAKE_BACK_DURATION = 0.3 -- time to settle back to base
local SHAKE_ANGLE_MIN = -13 -- degrees
local SHAKE_ANGLE_MAX = 13

-- The hit flash rides the shake: in over the tilt out, out over the settle,
-- with the same easing styles as _startShake.
local HIGHLIGHT_TIMING: onDamageIndicator.Timing = {
	fadeIn = SHAKE_OUT_DURATION,
	fadeInStyle = Enum.EasingStyle.Back,
	fadeOut = SHAKE_BACK_DURATION,
	fadeOutStyle = Enum.EasingStyle.Quad,
}

-- Loot breaks (BreakStyle). Shards per break, their size range (studs)
-- and launch. A vein's glowing shards are bigger, so their Neon blooms.
local SHARD_COUNT = { Shatter = 9, Sink = 7 }
local SHARD_SIZE = {
	Shatter = { min = 0.25, max = 0.6 },
	-- Wide spread, so a crystal's pieces read as chunks of it, not dust.
	Sink = { min = 0.4, max = 1.1 },
}
local SHARD_OUT_SPEED_MIN = 8
local SHARD_OUT_SPEED_MAX = 16
local SHARD_UP_SPEED_MIN = 14
local SHARD_UP_SPEED_MAX = 22
-- Shards rest this long, then fade over SHARD_FADE.
local SHARD_LINGER = 1.6
local SHARD_FADE = 1.2
-- Eased so the fade starts gently and finishes soft, not a linear blink.
local SHARD_FADE_INFO = TweenInfo.new(SHARD_FADE, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
-- A vein sinks over this long when it breaks. (Its hits only shake and
-- flash it: scaling it per hit shifted it off its spot, 2026-10-29.)
local VEIN_SINK_SECONDS = 0.45
-- A one-hit pot still shows its hit: the red flash and a quick swell to
-- POP_SCALE over POP_SECONDS, THEN it shatters.
local POP_SCALE = 1.15
local POP_SECONDS = 0.08
-- A vein break bumps the camera of a player within this many studs.
local VEIN_BUMP_RADIUS = 18
-- The vein's ore chunks: how many, how big, and their arc -- thrown out
-- and up around the vein (studs/s), falling under CHUNK_GRAVITY to the
-- floor, where they rest CHUNK_LINGER and fade over CHUNK_FADE.
local CHUNK_COUNT = 7
local CHUNK_SIZE = 0.4
local CHUNK_OUT_SPEED_MIN = 7
local CHUNK_OUT_SPEED_MAX = 13
local CHUNK_UP_SPEED_MIN = 12
local CHUNK_UP_SPEED_MAX = 18
local CHUNK_GRAVITY = 60
local CHUNK_LINGER = 1.4
local CHUNK_FADE = 1
-- Past this many seconds a chunk is faded wherever it is (no floor hit).
local CHUNK_MAX_FLIGHT = 1.2
-- A vein's glowing shards and ore chunks each carry a small PointLight in
-- the crystal colour, dimming out over the bit's life.
local BIT_LIGHT_BRIGHTNESS = 1.2
local BIT_LIGHT_RANGE = 5
-- The break sounds are positional, heard fully within the style's
-- breakRollOffMin studs and gone past its breakRollOffMax
-- (BreakableLootData).
local BREAK_SOUND_LIFETIME = 4
-- A vein's hit clink keeps the closer roll-off.
local HIT_SOUND_MIN_DISTANCE = 10
local HIT_SOUND_MAX_DISTANCE = 90

--[ Properties ]--

-- Per-instance active shake state. Keyed by the Breakable's instance (a Model
-- OR a single BasePart) so a new hit can cancel the previous shake before
-- starting its own.
type ShakeState = {
	cancelled: boolean,
	connection: RBXScriptConnection?,
}
BreakableController._activeShakes = {} :: { [Instance]: ShakeState }

--[ Private Functions ]--

function BreakableController._baseCFrameOf(_self: typeof(BreakableController), model: Instance): CFrame
	-- Prefer the cached "rest" CFrame set by the server when the breakable
	-- was placed. Fall back to the current pivot if no attribute exists.
	local cached = model:GetAttribute(Attributes.CachedCFrame)
	if typeof(cached) == "CFrame" then
		return cached
	end
	return (model :: PVInstance):GetPivot()
end

function BreakableController._startShake(self: typeof(BreakableController), model: PVInstance, hitCount: number)
	-- The breaking hit does not shake (the model is coming apart).
	local breakHits = model:GetAttribute(Attributes.BreakHits)
	if hitCount >= (if type(breakHits) == "number" then breakHits else 3) then
		return
	end

	-- Cancel any in-flight shake on this model so the new one doesn't fight it.
	local previous = self._activeShakes[model]
	if previous then
		previous.cancelled = true
		if previous.connection then
			previous.connection:Disconnect()
		end
	end

	local baseCFrame = self:_baseCFrameOf(model)

	-- Start from the model's CURRENT pose (mid-shake or rest), so overriding
	-- a previous shake doesn't snap. End on a fresh random angle.
	local startCFrame = model:GetPivot()
	local angleX = math.rad(math.random(SHAKE_ANGLE_MIN, SHAKE_ANGLE_MAX))
	local angleY = math.rad(math.random(SHAKE_ANGLE_MIN, SHAKE_ANGLE_MAX))
	local angleZ = math.rad(math.random(SHAKE_ANGLE_MIN, SHAKE_ANGLE_MAX))
	local tilt = CFrame.Angles(angleX, angleY, angleZ)
	-- A pot or crystal rocks on its BASE, not around its pivot (a crystal's
	-- sits mid-height, and tilting there swung its foot across the floor).
	if model:IsA("Model") and model:GetAttribute(Attributes.BreakStyle) ~= nil then
		local boxCFrame, boxSize = model:GetBoundingBox()
		-- The foot as a pure offset in the rest pivot's space.
		local foot = CFrame.new(baseCFrame:PointToObjectSpace(boxCFrame.Position - Vector3.new(0, boxSize.Y / 2, 0)))
		tilt = foot * tilt * foot:Inverse()
	end
	local targetCFrame = baseCFrame * tilt

	local state: ShakeState = { cancelled = false, connection = nil }
	self._activeShakes[model] = state

	local startTime = os.clock()

	state.connection = RunService.Heartbeat:Connect(function()
		if state.cancelled then
			return
		end
		if not model.Parent then
			state.cancelled = true
			if state.connection then
				state.connection:Disconnect()
			end
			if self._activeShakes[model] == state then
				self._activeShakes[model] = nil
			end
			return
		end

		local elapsed = os.clock() - startTime
		local current: CFrame

		if elapsed < SHAKE_OUT_DURATION then
			local alpha = elapsed / SHAKE_OUT_DURATION
			local eased = TweenService:GetValue(alpha, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
			current = startCFrame:Lerp(targetCFrame, eased)
		elseif elapsed < SHAKE_OUT_DURATION + SHAKE_BACK_DURATION then
			local alpha = (elapsed - SHAKE_OUT_DURATION) / SHAKE_BACK_DURATION
			local eased = TweenService:GetValue(alpha, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
			current = targetCFrame:Lerp(baseCFrame, eased)
		else
			-- Settle exactly on the rest CFrame and finish.
			model:PivotTo(baseCFrame)
			if state.connection then
				state.connection:Disconnect()
			end
			if self._activeShakes[model] == state then
				self._activeShakes[model] = nil
			end
			return
		end

		model:PivotTo(current)
	end)
end

-- Stops any shake running on `model` (a break must not fight it).
function BreakableController._cancelShake(self: typeof(BreakableController), model: Instance)
	local shake = self._activeShakes[model]
	if not shake then
		return
	end
	shake.cancelled = true
	if shake.connection then
		shake.connection:Disconnect()
	end
	self._activeShakes[model] = nil
end

-- A small PointLight in `color` on `part`, dimming to nothing over
-- `seconds` (a vein's shards and ore chunks).
local function addFadingGlow(part: BasePart, color: Color3, seconds: number)
	local light = Instance.new("PointLight")
	light.Color = color
	light.Brightness = BIT_LIGHT_BRIGHTNESS
	light.Range = BIT_LIGHT_RANGE
	light.Shadows = false
	light.Parent = part
	TweenService:Create(light, TweenInfo.new(seconds, Enum.EasingStyle.Sine, Enum.EasingDirection.In), {
		Brightness = 0,
	}):Play()
end

-- A burst of small local shards from `position`: they fly out, bounce on
-- the floor, rest a moment and fade. `glow` gives each a fading light.
local function burstShards(
	position: Vector3,
	color: Color3,
	count: number,
	sizeRange: { min: number, max: number },
	material: Enum.Material,
	glow: boolean
)
	local parent = workspace.IgnoreInstances:FindFirstChild("ArcaneSpells") or workspace.IgnoreInstances
	for _ = 1, count do
		local size = sizeRange.min + math.random() * (sizeRange.max - sizeRange.min)
		local shard = Instance.new("Part")
		shard.Name = "LootShard"
		shard.Size = Vector3.new(size, size * (0.6 + math.random() * 0.8), size)
		shard.Color = color
		shard.Material = material
		shard.CollisionGroup = CollisionGroups.BrokenBuilding
		shard.CanQuery = false
		shard.CanTouch = false
		shard.CFrame = CFrame.new(position)
			* CFrame.Angles(math.random() * math.pi, math.random() * math.pi, math.random() * math.pi)
		local angle = math.random() * math.pi * 2
		local out = SHARD_OUT_SPEED_MIN + math.random() * (SHARD_OUT_SPEED_MAX - SHARD_OUT_SPEED_MIN)
		local up = SHARD_UP_SPEED_MIN + math.random() * (SHARD_UP_SPEED_MAX - SHARD_UP_SPEED_MIN)
		shard.AssemblyLinearVelocity = Vector3.new(math.cos(angle) * out, up, math.sin(angle) * out)
		shard.AssemblyAngularVelocity = Vector3.new(math.random(-15, 15), math.random(-15, 15), math.random(-15, 15))
		shard.Parent = parent
		if glow then
			addFadingGlow(shard, color, SHARD_LINGER + SHARD_FADE)
		end
		task.delay(SHARD_LINGER, function()
			if shard.Parent then
				TweenService:Create(shard, SHARD_FADE_INFO, { Transparency = 1 }):Play()
			end
		end)
		Debris:AddItem(shard, SHARD_LINGER + SHARD_FADE + 0.2)
	end
end

-- One LOADED Sound per loot sound id, kept under this script and cloned
-- per play: a fresh Sound with a new SoundId fetches its asset first, and
-- that fetch was the lag between the break and its sound. Preloaded on
-- Start (preloadLootSounds); a clone of a loaded Sound plays at once.
local soundTemplates: { [string]: Sound } = {}

local function templateFor(soundId: string): Sound
	local existing = soundTemplates[soundId]
	if existing then
		return existing
	end
	local template = Instance.new("Sound")
	template.Name = "LootSoundTemplate"
	template.SoundId = soundId
	template.Parent = script
	soundTemplates[soundId] = template
	return template
end

local function preloadLootSounds()
	local sounds: { Instance } = { templateFor(BreakableLootData.Vein.hitSound) }
	local function addLayers(layers: { BreakableLootData.BreakSound })
		for _, layer in layers do
			table.insert(sounds, templateFor(layer.id))
		end
	end
	addLayers(BreakableLootData.Vein.breakSounds)
	addLayers(BreakableLootData.Pot.breakSounds)
	task.spawn(function()
		ContentProvider:PreloadAsync(sounds)
	end)
end

-- Plays `soundId` from `position` as a 3D sound at `volume`, full within
-- `minDistance` studs and gone past `maxDistance`: a Sound only rolls off
-- with distance when it sits on a part, so it rides a throwaway anchor.
local function playBreakSound(
	soundId: string,
	position: Vector3,
	volume: number,
	minDistance: number,
	maxDistance: number
)
	local anchor = Instance.new("Part")
	anchor.Name = "LootBreakSound"
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Position = position
	local sound = templateFor(soundId):Clone()
	sound.Volume = volume
	sound.RollOffMode = Enum.RollOffMode.InverseTapered
	sound.RollOffMinDistance = minDistance
	sound.RollOffMaxDistance = maxDistance
	sound.Parent = anchor
	anchor.Parent = workspace.IgnoreInstances:FindFirstChild("ArcaneSpells") or workspace.IgnoreInstances
	sound:Play()
	Debris:AddItem(anchor, BREAK_SOUND_LIFETIME)
end

-- The vein's ore chunks (see the CHUNK_ constants): glowing bits thrown
-- out and up from `position` in every direction, arcing down to `floorY`,
-- where they rest a moment and fade. Anchored and moved by hand, so they
-- never touch physics.
local function sprayOreChunks(position: Vector3, floorY: number, color: Color3)
	local parent = workspace.IgnoreInstances:FindFirstChild("ArcaneSpells") or workspace.IgnoreInstances
	local restY = floorY + CHUNK_SIZE / 2

	type Chunk = { part: Part, position: Vector3, velocity: Vector3, landedAt: number? }
	local chunks: { Chunk } = {}
	for _ = 1, CHUNK_COUNT do
		local chunk = Instance.new("Part")
		chunk.Name = "OreChunk"
		chunk.Size = Vector3.one * CHUNK_SIZE
		chunk.Color = color
		chunk.Material = Enum.Material.Neon
		chunk.Anchored = true
		chunk.CanCollide = false
		chunk.CanQuery = false
		chunk.CanTouch = false
		chunk.CFrame = CFrame.new(position)
		chunk.Parent = parent
		addFadingGlow(chunk, color, CHUNK_MAX_FLIGHT + CHUNK_FADE)
		local angle = math.random() * math.pi * 2
		local out = CHUNK_OUT_SPEED_MIN + math.random() * (CHUNK_OUT_SPEED_MAX - CHUNK_OUT_SPEED_MIN)
		local up = CHUNK_UP_SPEED_MIN + math.random() * (CHUNK_UP_SPEED_MAX - CHUNK_UP_SPEED_MIN)
		table.insert(chunks, {
			part = chunk,
			position = position,
			velocity = Vector3.new(math.cos(angle) * out, up, math.sin(angle) * out),
			landedAt = nil,
		})
	end

	local began = os.clock()
	local connection: RBXScriptConnection
	connection = RunService.Heartbeat:Connect(function(deltaTime: number)
		local now = os.clock()
		local elapsed = now - began
		local allGone = true
		for _, entry in chunks do
			local landedAt = entry.landedAt
			if not landedAt then
				-- In flight: a simple ballistic arc down to the floor.
				entry.velocity -= Vector3.new(0, CHUNK_GRAVITY * deltaTime, 0)
				entry.position += entry.velocity * deltaTime
				if entry.position.Y <= restY and entry.velocity.Y < 0 then
					entry.position = Vector3.new(entry.position.X, restY, entry.position.Z)
					entry.landedAt = now
				elseif elapsed >= CHUNK_MAX_FLIGHT then
					entry.landedAt = now - CHUNK_LINGER
				end
				local spin = CFrame.Angles(elapsed * 9, elapsed * 7, 0)
				entry.part.CFrame = CFrame.new(entry.position) * spin
				allGone = false
			else
				-- Resting: hold, then fade out.
				local alpha = math.clamp((now - landedAt - CHUNK_LINGER) / CHUNK_FADE, 0, 1)
				-- Sine in-out, the shards' easing.
				entry.part.Transparency = (1 - math.cos(alpha * math.pi)) / 2
				if alpha < 1 then
					allGone = false
				end
			end
		end
		if allGone then
			connection:Disconnect()
			for _, entry in chunks do
				entry.part:Destroy()
			end
		end
	end)
end

local function setLocalTransparency(model: Instance, value: number)
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			part.LocalTransparencyModifier = value
		end
	end
end

-- The loot break (see the header): shards in the model's ShardColor, the
-- style's break sound (BreakableLootData), then gone ("Shatter") or sunk
-- into the floor as it fades ("Sink").
function BreakableController._playStyledBreak(self: typeof(BreakableController), model: Model, style: string)
	self:_cancelShake(model)
	-- The sound goes on the breaking hit itself, not after the pot's pop.
	local boxCFrame = model:GetBoundingBox()
	local data = if style == "Sink" then BreakableLootData.Vein else BreakableLootData.Pot
	local layers: { BreakableLootData.BreakSound } = data.breakSounds
	for _, layer in layers do
		playBreakSound(layer.id, boxCFrame.Position, layer.volume, data.breakRollOffMin, data.breakRollOffMax)
	end
	if style ~= "Sink" then
		-- The pot: swell for a beat under the hit's red flash, then burst.
		local baseScale = model:GetScale()
		local began = os.clock()
		local connection: RBXScriptConnection
		connection = RunService.Heartbeat:Connect(function()
			if not model.Parent then
				connection:Disconnect()
				return
			end
			local alpha = math.clamp((os.clock() - began) / POP_SECONDS, 0, 1)
			model:ScaleTo(baseScale * (1 + (POP_SCALE - 1) * math.sin(alpha * math.pi / 2)))
			if alpha >= 1 then
				connection:Disconnect()
				self:_finishStyledBreak(model, style)
			end
		end)
		return
	end
	self:_finishStyledBreak(model, style)
end

function BreakableController._finishStyledBreak(_self: typeof(BreakableController), model: Model, style: string)
	local boxCFrame, boxSize = model:GetBoundingBox()
	local color = model:GetAttribute(Attributes.ShardColor)
	local primary = model.PrimaryPart
	local shardColor: Color3 = if typeof(color) == "Color3"
		then color
		elseif primary then primary.Color
		else Color3.new(1, 1, 1)
	local isSink = style == "Sink"
	burstShards(
		boxCFrame.Position,
		shardColor,
		if isSink then SHARD_COUNT.Sink else SHARD_COUNT.Shatter,
		if isSink then SHARD_SIZE.Sink else SHARD_SIZE.Shatter,
		if isSink then Enum.Material.Neon else Enum.Material.Slate,
		isSink
	)

	if not isSink then
		setLocalTransparency(model, 1)
		return
	end

	local start = model:GetPivot()
	local depth = boxSize.Y
	local began = os.clock()
	-- The chunks land on the floor the vein stood on.
	sprayOreChunks(boxCFrame.Position, boxCFrame.Position.Y - boxSize.Y / 2, shardColor)
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root and (root.Position - boxCFrame.Position).Magnitude <= VEIN_BUMP_RADIUS then
		CameraShakeController:Shake(CameraShakePresets.Medium)
	end

	-- Its glow (the crystal's PointLight) dims out with the sink.
	local lights: { [Light]: number } = {}
	for _, light in model:GetDescendants() do
		if light:IsA("Light") then
			lights[light] = light.Brightness
		end
	end
	local connection: RBXScriptConnection
	connection = RunService.Heartbeat:Connect(function()
		local alpha = math.clamp((os.clock() - began) / VEIN_SINK_SECONDS, 0, 1)
		if not model.Parent then
			connection:Disconnect()
			return
		end
		model:PivotTo(start - Vector3.new(0, depth * alpha * alpha, 0))
		setLocalTransparency(model, alpha)
		for light, brightness in lights do
			light.Brightness = brightness * (1 - alpha)
		end
		if alpha >= 1 then
			connection:Disconnect()
		end
	end)
end

--[ Initializers ]--

function BreakableController.Start(self: typeof(BreakableController))
	preloadLootSounds()
	Combat.BreakableDamaged.On(function(payload)
		local buildTemplate = payload.Breakable
		local hitCount = payload.HitCount
		local isMelee = payload.IsMelee
		local hitPosition = payload.HitPosition
		if not buildTemplate or not buildTemplate.Parent then
			return
		end

		-- Highlight works on any Instance (Model or BasePart), timed to the
		-- shake (HIGHLIGHT_TIMING) for every breakable alike.
		onDamageIndicator(buildTemplate, ATTACK_HIGHLIGHT_NAME, HIGHLIGHT_TIMING)

		-- The HitFX sparks are melee-only. A bullet draws its own BulletImpact
		-- where it landed, so a second burst here reads as a double impact.
		-- Arcane never fires this signal (it breaks the model outright), so
		-- "not melee" here means a bullet. Highlight and shake still run.
		if isMelee then
			self:_playHitFX(buildTemplate, hitPosition)
		elseif buildTemplate:GetAttribute(Attributes.BreakStyle) ~= nil then
			-- A bullet on a pot or crystal: the same hit sound a bullet on a
			-- mob plays (DamageIndicatorController). The melee one is the
			-- weapon's own, played by MeleeWeapon.
			ReplicatedStorage.GameAssets.Sounds.BulletHit:Play()
		end

		-- Loot breakables: the breaking hit plays the break, every hit
		-- before it on a vein shrinks it a little.
		local style = buildTemplate:GetAttribute(Attributes.BreakStyle)
		if type(style) == "string" and buildTemplate:IsA("Model") then
			local breakHits = buildTemplate:GetAttribute(Attributes.BreakHits)
			if hitCount >= (if type(breakHits) == "number" then breakHits else 3) then
				self:_playStyledBreak(buildTemplate, style)
				return
			end
			if style == "Sink" then
				local vein = BreakableLootData.Vein
				playBreakSound(
					vein.hitSound,
					buildTemplate:GetPivot().Position,
					vein.hitSoundVolume,
					HIT_SOUND_MIN_DISTANCE,
					HIT_SOUND_MAX_DISTANCE
				)
			end
		end

		-- Shake requires GetPivot/PivotTo, which exists on PVInstance (both
		-- Model and BasePart). Skip anything else just in case.
		if buildTemplate:IsA("Model") or buildTemplate:IsA("BasePart") then
			self:_startShake(buildTemplate, hitCount)
		end
	end)
end

-- The melee impact sparks on a breakable: the shared hit burst
-- (playHitBurst), every emitter included -- the blade arc is right for
-- a sword hit, and this only runs for one.
--
-- Placed at `hitPosition` -- where the swing actually met the model, as
-- computed by the server from the part it overlapped -- so a crate hit
-- on its corner sparks on that corner. The pivot is only the fallback
-- for a caller that has no contact point.
function BreakableController._playHitFX(
	_self: typeof(BreakableController),
	buildTemplate: Instance,
	hitPosition: Vector3?
)
	local cframe = if hitPosition
		then CFrame.new(hitPosition)
		else (buildTemplate :: PVInstance):GetPivot() + (buildTemplate :: PVInstance):GetPivot().LookVector * -1
	playHitBurst(cframe)
end

return BreakableController
