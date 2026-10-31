--!strict
--[[
	Module: RelicGimmickFXController
	Description:
	Draws the relic GIMMICK effects (RelicGimmickService) on every client:
	the server sends one RelicNetwork.GimmickEffect per effect and owns
	every hit and position check; this only animates, on RenderStepped, so
	waves, shards and orbs move smoothly instead of stepping with server
	replication. StartTime (server clock) lets a late packet start part
	way through, in step with the server's own hit timing.

	The persistent ones are keyed by their caster and kept alive by the
	server re-sending them:
	  * the Ice Dragon Slayer's FROST WYRM, a neon ice cube that follows
	    its caster like a larger Spirit Companion (the same spring follow,
	    shoulder-to-shoulder drift and bob, on Heartbeat; 2026-10-30), fades
	    in and out and turns to face each FrostOrb it fires. Its orbs home
	    on their Target as the server's do;
	  * the Spartan Sword and Shield's ORBITING SHIELD, whose angle comes
	    from the server clock, so it sits where the server hits with it;
	  * the Korblox Ice Claws duo's SHELL, a translucent ice sphere around its
	    caster while they hold a Barrier.

	MELTED mobs (Fire Breathing Friend, Attributes.Melted) wear green fire
	while the attribute is set; that one is watched here, not sent.

	The 2026-10-30 relics (ranged and duo) are PROTOTYPE visuals: simple
	parts and the status emitters, to be replaced with authored VFX.

	See bfg-core/Network/Relic.blink (GimmickEffectPayload) for the kinds.
]]

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local RelicNetwork = require(ReplicatedStorage.Submodules.Core.Source.Network.Relic)
local RelicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicData)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local AuraNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.AuraNames)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local SpiritCompanionData = require(ReplicatedStorage.Submodules.Core.Shared.Data.SpiritCompanionData)

--[ Constants ]--

local FIRE_COLOR = Color3.fromRGB(255, 120, 35)
local ICE_COLOR = Color3.fromRGB(120, 210, 255)
local TOXIC_COLOR = Color3.fromRGB(120, 230, 90)
local BOLT_COLOR = Color3.fromRGB(150, 210, 255)
local STONE_COLOR = Color3.fromRGB(150, 140, 120)
local GOLD_COLOR = Color3.fromRGB(255, 205, 80)
local BLACK_FLAME_COLOR = Color3.fromRGB(70, 35, 80)
local BAN_COLOR = Color3.fromRGB(255, 85, 85)
local PLASMA_COLOR = Color3.fromRGB(255, 120, 200)
local SHOCK_COLOR = Color3.fromRGB(185, 87, 255)

local BURST_COLORS: { [string]: Color3 } = {
	FireBurst = FIRE_COLOR,
	FrostBurst = ICE_COLOR,
	ToxicBurst = TOXIC_COLOR,
	BlackBurst = BLACK_FLAME_COLOR,
	-- 2026-10-30 prototypes.
	ShockBurst = SHOCK_COLOR,
	PlasmaNova = PLASMA_COLOR,
}
local BURST_SECONDS = 0.3

-- The travelling slashes.
local FLAME_WAVE_SIZE = Vector3.new(9, 0.6, 2.2)
local THUNDER_BLADE_SIZE = Vector3.new(8, 0.5, 1.4)
local SLASH_FADE_SECONDS = 0.2
-- Chance per frame of a stray spark around a Thunder Blade.
local THUNDER_SPARK_CHANCE = 0.35

-- Phoenix Dash embers.
local TRAIL_SPACING = 3
local TRAIL_DROP = 2.5

-- Lightning bolts: a white-hot core inside a wider blue glow, a fork or
-- two off the main line, and a flash where it lands.
local BOLT_SEGMENTS = 6
local BOLT_JITTER = 1.1
local BOLT_FADE_SECONDS = 0.22
local BOLT_CORE_COLOR = Color3.fromRGB(235, 248, 255)
local BOLT_CORE_THICKNESS = 0.18
local BOLT_GLOW_THICKNESS = 0.55
local BOLT_FORK_CHANCE = 0.35
local BOLT_FLASH_RADIUS = 1.6

-- Lobbed bubbles arc high; Blizzard's ice shards hop fast and low (a
-- quadratic bezier with its control point just above the line).
local ARC_HEIGHT = 6
local SHARD_ARC_HEIGHT = 1.5

-- Frost Wyrm: the cube and its fade. It follows like a Spirit Companion
-- WYRM_SCALE times the size (SpiritCompanionData's orbit, drift, spring
-- and bob), a touch lazier so it trails a run or a roll.
local WYRM_SIZE = Vector3.new(3, 3, 3)
local WYRM_TRANSPARENCY = 0.15
local WYRM_FADE_SECONDS = 0.35
local WYRM_SCALE = 2
local WYRM_SMOOTH_TIME = 0.45
-- How long the wyrm keeps facing a shot before it turns back to your look.
local WYRM_FACE_SECONDS = 0.8
local FROST_ORB_SIZE = 1.4
-- The orb bursts this close to its target's root, or after ORB_MAX_SECONDS
-- (the server's FrostOrb rules, RelicGimmickService/Frost).
local ORB_CONTACT_STUDS = 2.5
local ORB_MAX_SECONDS = 1.5
-- The companion's orbit centre (directly behind, at SHOULDER_OFFSET's
-- radius and height), scaled up.
local WYRM_ORBIT_BASE = Vector3.new(
	0,
	SpiritCompanionData.SHOULDER_OFFSET.Y,
	Vector3.new(SpiritCompanionData.SHOULDER_OFFSET.X, 0, SpiritCompanionData.SHOULDER_OFFSET.Z).Magnitude
) * WYRM_SCALE

-- Ban Hammer: the drop starts this high over the target, at this scale
-- of the relic's display model.
local BAN_HAMMER_DROP_HEIGHT = 18
local BAN_HAMMER_SCALE = 3
local BAN_HAMMER_LINGER_SECONDS = 0.5

-- Orbiting Shield: its slab and how it fades in and out.
local SHIELD_SIZE = Vector3.new(3, 3.4, 0.6)
local SHIELD_FADE_SECONDS = 0.35
-- How fast the local clock is eased onto the server's: GetServerTimeNow
-- steps a little frame to frame, and an angle read straight off it
-- jitters the slab.
local SHIELD_CLOCK_RATE = 2

-- The 2026-10-30 prototypes: War Rocks's boulder, the Static Charge,
-- Hailstorm's cloud and shards, and the Korblox Ice Claws.
local BOULDER_SIZE = Vector3.new(2.2, 2.2, 2.2)
local STATIC_CHARGE_SIZE = 1.2
local HAIL_SHARD_SIZE = Vector3.new(0.5, 1.6, 0.5)
local HAIL_CLOUD_HEIGHT = 16
local ICE_SHELL_SIZE = 8
local ICE_SHELL_TRANSPARENCY = 0.75
local ICE_SHELL_FADE_SECONDS = 0.3

--[ Types ]--

type Payload = {
	Kind: string,
	Caster: Player?,
	Target: Model?,
	From: Vector3,
	To: Vector3,
	Radius: number,
	Duration: number,
	StartTime: number,
}

type Wyrm = {
	part: BasePart,
	expiresAt: number,
	facing: Vector3?,
	faceUntil: number,
	fading: boolean,
	-- The spring follow (SpiritCompanion's): carried velocity, the drift
	-- angle and its next target, and the bob phase.
	velocity: Vector3,
	orbitAngle: number,
	orbitTarget: number,
	orbitNextMoveAt: number,
	bobPhase: number,
}

type Shield = { parts: { BasePart }, expiresAt: number, fading: boolean }

type Shell = { part: BasePart, expiresAt: number, fading: boolean }

--[ Module ]--

local RelicGimmickFXController = {
	Name = "RelicGimmickFXController",
}

local wyrms: { [Player]: Wyrm } = {}
local orbitRandom = Random.new()
local shields: { [Player]: Shield } = {}
local shells: { [Player]: Shell } = {}
-- Melted mobs' green fire, by mob.
local meltedFire: { [Model]: { ParticleEmitter } } = {}

--[ Helpers ]--

local function effectsFolder(): Instance
	return workspace.IgnoreInstances:FindFirstChild("ArcaneSpells") or workspace.IgnoreInstances
end

local function makePart(name: string, size: Vector3, color: Color3, material: Enum.Material?): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.Material = material or Enum.Material.Neon
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	return part
end

-- The status visual's emitters (GameAssets.Auras.<visualKey>, the rig a
-- Burning mob wears) cloned onto `part`.
local function statusEmitters(visualKey: string, part: BasePart): { ParticleEmitter }
	local auras = ReplicatedStorage.GameAssets:FindFirstChild("Auras")
	local template = auras and auras:FindFirstChild(visualKey)
	local emitters = {}
	if not template then
		return emitters
	end
	for _, descendant in template:GetDescendants() do
		if descendant:IsA("ParticleEmitter") then
			local clone = descendant:Clone()
			clone.Enabled = true
			clone.Parent = part
			table.insert(emitters, clone)
		end
	end
	return emitters
end

-- Fades `part` out, stops its emitters, and removes it once they clear.
local function retire(part: BasePart, emitters: { ParticleEmitter }?, fadeSeconds: number, linger: number?)
	if emitters then
		for _, emitter in emitters do
			emitter.Enabled = false
		end
	end
	TweenService:Create(part, TweenInfo.new(fadeSeconds), { Transparency = 1 }):Play()
	Debris:AddItem(part, fadeSeconds + (linger or 0.1))
end

local function elapsedOf(payload: Payload): number
	return math.max(workspace:GetServerTimeNow() - payload.StartTime, 0)
end

-- Calls `step(alpha)` every frame from `startElapsed` into `duration`
-- until alpha reaches 1, then `done()`.
local function animate(duration: number, startElapsed: number, step: (number) -> (), done: (() -> ())?)
	local began = os.clock() - startElapsed
	local connection: RBXScriptConnection
	connection = RunService.RenderStepped:Connect(function()
		local alpha = if duration > 0 then math.clamp((os.clock() - began) / duration, 0, 1) else 1
		step(alpha)
		if alpha >= 1 then
			connection:Disconnect()
			if done then
				done()
			end
		end
	end)
end

--[ Effects ]--

local function burst(position: Vector3, radius: number, color: Color3)
	local ball = makePart("GimmickBurst", Vector3.one, color)
	ball.Shape = Enum.PartType.Ball
	ball.Transparency = 0.35
	ball.Position = position
	ball.Parent = effectsFolder()
	TweenService:Create(ball, TweenInfo.new(BURST_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.one * radius * 2,
		Transparency = 1,
	}):Play()
	Debris:AddItem(ball, BURST_SECONDS + 0.1)
end

local function boltPoints(from: Vector3, to: Vector3, segments: number, jitter: number): { Vector3 }
	local points = { from }
	for index = 1, segments - 1 do
		local offset = Vector3.new(
			(math.random() * 2 - 1) * jitter,
			(math.random() * 2 - 1) * jitter,
			(math.random() * 2 - 1) * jitter
		)
		table.insert(points, from:Lerp(to, index / segments) + offset)
	end
	table.insert(points, to)
	return points
end

-- One zig-zag line through `points`, `thickness` wide, flashing out.
local function drawLine(points: { Vector3 }, thickness: number, color: Color3, transparency: number)
	for index = 1, #points - 1 do
		local a, b = points[index], points[index + 1]
		local length = (b - a).Magnitude
		if length < 0.05 then
			continue
		end
		local segment = makePart("GimmickBolt", Vector3.new(thickness, thickness, length), color)
		segment.Transparency = transparency
		segment.CFrame = CFrame.lookAt(a:Lerp(b, 0.5), b)
		segment.Parent = effectsFolder()
		TweenService
			:Create(segment, TweenInfo.new(BOLT_FADE_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				Transparency = 1,
				Size = Vector3.new(thickness * 0.3, thickness * 0.3, length),
			})
			:Play()
		Debris:AddItem(segment, BOLT_FADE_SECONDS + 0.05)
	end
end

local function bolt(from: Vector3, to: Vector3)
	local points = boltPoints(from, to, BOLT_SEGMENTS, BOLT_JITTER)
	drawLine(points, BOLT_GLOW_THICKNESS, BOLT_COLOR, 0.55)
	drawLine(points, BOLT_CORE_THICKNESS, BOLT_CORE_COLOR, 0)
	-- A short fork off a middle point.
	if math.random() < BOLT_FORK_CHANCE and #points > 3 then
		local root = points[math.random(2, #points - 2)]
		local tip = root
			+ ((to - from).Unit + Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5)).Unit
				* (to - from).Magnitude
				* 0.25
		drawLine(boltPoints(root, tip, 3, BOLT_JITTER * 0.6), BOLT_CORE_THICKNESS, BOLT_CORE_COLOR, 0.2)
	end
	-- The landing flash: a quick bright pop and a light.
	local flash = makePart("GimmickBoltFlash", Vector3.one * 0.4, BOLT_CORE_COLOR)
	flash.Shape = Enum.PartType.Ball
	flash.Position = to
	local light = Instance.new("PointLight")
	light.Color = BOLT_COLOR
	light.Brightness = 4
	light.Range = 10
	light.Parent = flash
	flash.Parent = effectsFolder()
	TweenService:Create(flash, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.one * BOLT_FLASH_RADIUS * 2,
		Transparency = 1,
	}):Play()
	TweenService:Create(light, TweenInfo.new(0.25), { Brightness = 0 }):Play()
	Debris:AddItem(flash, 0.3)
end

-- A slash travelling From -> To over Duration (Flame Wave, Thunder Blade).
local function travellingSlash(payload: Payload, size: Vector3, color: Color3, visualKey: string?, sparks: boolean)
	local from, to = payload.From, payload.To
	local direction = to - from
	if direction.Magnitude < 0.05 then
		return
	end
	local look = direction.Unit
	local slash = makePart("GimmickSlash", size, color)
	slash.Transparency = 0.25
	slash.CFrame = CFrame.lookAt(from, from + look)
	slash.Parent = effectsFolder()
	local emitters = if visualKey then statusEmitters(visualKey, slash) else nil
	local light = Instance.new("PointLight")
	light.Color = color
	light.Brightness = 2
	light.Range = 10
	light.Parent = slash
	animate(payload.Duration, elapsedOf(payload), function(alpha: number)
		local position = from:Lerp(to, alpha)
		slash.CFrame = CFrame.lookAt(position, position + look)
		if sparks and math.random() < THUNDER_SPARK_CHANCE then
			local side = slash.CFrame.RightVector * (math.random() * 2 - 1) * size.X * 0.5
			bolt(position + side, position + side + look * 2.5 + Vector3.new(0, math.random() * 1.5, 0))
		end
	end, function()
		retire(slash, emitters, SLASH_FADE_SECONDS, 1.2)
	end)
end

local function phoenixTrail(payload: Payload)
	local from, to = payload.From, payload.To
	local flat = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
	local steps = math.max(1, math.floor(flat.Magnitude / TRAIL_SPACING))
	local remaining = math.max(payload.Duration - elapsedOf(payload), 0.2)
	for index = 0, steps do
		local ember = makePart("PhoenixTrail", Vector3.new(2, 0.2, 2), FIRE_COLOR)
		ember.Transparency = 0.6
		ember.Position = from:Lerp(to, index / steps) - Vector3.new(0, TRAIL_DROP, 0)
		ember.Parent = effectsFolder()
		local emitters = statusEmitters("Burn", ember)
		task.delay(remaining, function()
			retire(ember, emitters, 0.4, 1.5)
		end)
	end
end

local function frostField(payload: Payload)
	local radius = payload.Radius
	local disc = makePart("FrostField", Vector3.new(0.3, radius * 2, radius * 2), ICE_COLOR)
	disc.Shape = Enum.PartType.Cylinder
	disc.Transparency = 1
	disc.CFrame = CFrame.new(payload.From + Vector3.new(0, 0.2, 0)) * CFrame.Angles(0, 0, math.rad(90))
	disc.Parent = effectsFolder()
	TweenService:Create(disc, TweenInfo.new(0.25), { Transparency = 0.7 }):Play()
	local emitters = statusEmitters("Chill", disc)
	task.delay(math.max(payload.Duration - elapsedOf(payload), 0.2), function()
		retire(disc, emitters, 0.4, 1.5)
	end)
end

-- A lobbed shard or bubble arcing From -> To, bursting where it lands.
local function lob(payload: Payload, part: BasePart, burstColor: Color3, spins: boolean, arcHeight: number)
	local from, to = payload.From, payload.To
	part.Position = from
	part.Parent = effectsFolder()
	local last = from
	animate(payload.Duration, elapsedOf(payload), function(alpha: number)
		local point = from:Lerp(to, alpha) + Vector3.new(0, math.sin(alpha * math.pi) * arcHeight, 0)
		local heading = point - last
		part.CFrame = if spins and heading.Magnitude > 0.01
			then CFrame.lookAt(point, point + heading)
			else CFrame.new(point)
		last = point
	end, function()
		part:Destroy()
		burst(to, payload.Radius, burstColor)
	end)
end

--[ Frost Wyrm ]--

-- SpiritCompanion's critically damped spring: the new position and the
-- velocity to carry into the next frame.
local function smoothDamp(
	current: Vector3,
	target: Vector3,
	velocity: Vector3,
	smoothTime: number,
	deltaTime: number
): (Vector3, Vector3)
	local omega = 2 / math.max(smoothTime, 0.0001)
	local x = omega * deltaTime
	local expTerm = 1 / (1 + x + 0.48 * x * x + 0.235 * x * x * x)
	local change = current - target
	local temp = (velocity + change * omega) * deltaTime
	return target + (change + temp) * expTerm, (velocity - temp * omega) * expTerm
end

-- What the wyrm follows: the animated Torso's POSITION, like a Spirit
-- Companion, so it sways with the walk instead of riding the rigid root
-- -- but the root's YAW for its facing and orbit (2026-10-30): the Torso
-- pitches and rolls through the dodge roll, and an orbit hung off its
-- full rotation swung the wyrm in a 360 around the player on every dodge.
local function wyrmAnchorPart(character: Model): BasePart?
	local part = character:FindFirstChild("Torso")
		or character:FindFirstChild("UpperTorso")
		or character:FindFirstChild("HumanoidRootPart")
	return if part and part:IsA("BasePart") then part else nil
end

-- The anchor's position with the character's yaw only (the root's look
-- flattened; the anchor's own if there is no root).
local function wyrmFrame(character: Model?, anchor: BasePart): CFrame
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local look = (if root and root:IsA("BasePart") then root.CFrame.LookVector else anchor.CFrame.LookVector)
		* Vector3.new(1, 0, 1)
	if look.Magnitude < 1e-3 then
		look = Vector3.zAxis
	end
	return CFrame.lookAt(anchor.Position, anchor.Position + look.Unit)
end

local function wyrmHome(frame: CFrame, orbitAngle: number): Vector3
	return (frame * CFrame.Angles(0, orbitAngle, 0) * CFrame.new(WYRM_ORBIT_BASE)).Position
end

-- The next drift angle: near one shoulder or the other, usually the
-- other (SpiritCompanion:_pickOrbitTarget).
local function pickOrbitTarget(current: number): number
	local halfSweep = math.rad(SpiritCompanionData.IDLE_ORBIT_DEGREES)
	local sign = if current >= 0 then 1 else -1
	if orbitRandom:NextNumber() >= SpiritCompanionData.IDLE_ORBIT_SAME_SIDE_CHANCE then
		sign = -sign
	end
	return sign * halfSweep * orbitRandom:NextNumber(SpiritCompanionData.IDLE_ORBIT_MIN_MAGNITUDE, 1)
end

local function dismissWyrm(caster: Player)
	local wyrm = wyrms[caster]
	if not wyrm or wyrm.fading then
		return
	end
	wyrm.fading = true
	TweenService:Create(wyrm.part, TweenInfo.new(WYRM_FADE_SECONDS), { Transparency = 1 }):Play()
	local light = wyrm.part:FindFirstChildOfClass("PointLight")
	if light then
		TweenService:Create(light, TweenInfo.new(WYRM_FADE_SECONDS), { Brightness = 0 }):Play()
	end
	task.delay(WYRM_FADE_SECONDS, function()
		if wyrms[caster] == wyrm then
			wyrms[caster] = nil
		end
		wyrm.part:Destroy()
	end)
end

local function summonWyrm(payload: Payload)
	local caster = payload.Caster
	local character = caster and caster.Character
	local root = character and wyrmAnchorPart(character)
	if not caster or not root then
		return
	end
	local expiresAt = os.clock() + math.max(payload.Duration - elapsedOf(payload), 0)
	local existing = wyrms[caster]
	if existing and not existing.fading then
		existing.expiresAt = expiresAt
		return
	end
	local part = makePart("FrostWyrm", WYRM_SIZE, ICE_COLOR)
	part.Transparency = 1
	local home = wyrmHome(wyrmFrame(character, root), 0)
	part.CFrame = CFrame.lookAt(home, home + root.CFrame.LookVector)
	local light = Instance.new("PointLight")
	light.Color = ICE_COLOR
	light.Brightness = 0
	light.Range = 14
	light.Parent = part
	part.Parent = effectsFolder()
	TweenService:Create(part, TweenInfo.new(WYRM_FADE_SECONDS), { Transparency = WYRM_TRANSPARENCY }):Play()
	TweenService:Create(light, TweenInfo.new(WYRM_FADE_SECONDS), { Brightness = 2 }):Play()
	wyrms[caster] = {
		part = part,
		expiresAt = expiresAt,
		facing = nil,
		faceUntil = 0,
		fading = false,
		velocity = Vector3.zero,
		orbitAngle = 0,
		orbitTarget = 0,
		orbitNextMoveAt = 0,
		bobPhase = orbitRandom:NextNumber() * 2 * math.pi,
	}
end

local function frostOrb(payload: Payload)
	local caster = payload.Caster
	local wyrm = caster and wyrms[caster]
	local from = if wyrm then wyrm.part.Position else payload.From
	local to = payload.To
	if wyrm then
		local flat = (to - from) * Vector3.new(1, 0, 1)
		if flat.Magnitude > 0.05 then
			wyrm.facing = flat.Unit
			wyrm.faceUntil = os.clock() + WYRM_FACE_SECONDS
		end
	end
	local launched = os.clock()
	local orb = makePart("FrostOrb", Vector3.one * FROST_ORB_SIZE, ICE_COLOR)
	orb.Shape = Enum.PartType.Ball
	orb.Position = from
	orb.Parent = effectsFolder()
	local emitters = statusEmitters("Chill", orb)
	local light = Instance.new("PointLight")
	light.Color = ICE_COLOR
	light.Brightness = 2
	light.Range = 8
	light.Parent = orb
	-- Home on the Target's root (where it last was once it is gone), at
	-- the server's speed, starting as far along as the packet is late.
	local target = payload.Target
	local targetRoot = target and target:FindFirstChild("HumanoidRootPart")
	local speed = (RelicData[RelicNames["Ice Dragon Slayer"]].data or {}).orbSpeed or 55
	local position = from
	local aim = to
	local flown = elapsedOf(payload)
	local connection: RBXScriptConnection
	connection = RunService.RenderStepped:Connect(function(deltaTime: number)
		local step = speed * (deltaTime + flown)
		flown = 0
		if targetRoot and targetRoot:IsA("BasePart") and targetRoot.Parent then
			aim = targetRoot.Position
		end
		local gap = aim - position
		local done = gap.Magnitude <= step + ORB_CONTACT_STUDS
		position = if done then aim else position + gap.Unit * step
		orb.Position = position
		if done or os.clock() - launched >= ORB_MAX_SECONDS then
			connection:Disconnect()
			burst(position, payload.Radius, ICE_COLOR)
			retire(orb, emitters, 0.1, 1)
		end
	end)
end

local function stepWyrms(deltaTime: number)
	local now = os.clock()
	local turn = 1 - math.exp(-SpiritCompanionData.TURN_LERP_PER_SECOND * deltaTime)
	local orbitEase = 1 - math.exp(-SpiritCompanionData.IDLE_ORBIT_EASE_PER_SECOND * deltaTime)
	for caster, wyrm in wyrms do
		local character = caster.Character
		local anchor = character and wyrmAnchorPart(character)
		if not anchor or not caster.Parent then
			dismissWyrm(caster)
			continue
		end
		if now >= wyrm.expiresAt then
			dismissWyrm(caster)
		end

		-- Dwell near a shoulder, then drift to the other (the companion's
		-- idle orbit).
		if now >= wyrm.orbitNextMoveAt then
			wyrm.orbitTarget = pickOrbitTarget(wyrm.orbitAngle)
			wyrm.orbitNextMoveAt = now
				+ orbitRandom:NextNumber(
					SpiritCompanionData.IDLE_ORBIT_DWELL_MIN_SECONDS,
					SpiritCompanionData.IDLE_ORBIT_DWELL_MAX_SECONDS
				)
		end
		wyrm.orbitAngle += (wyrm.orbitTarget - wyrm.orbitAngle) * orbitEase
		local frame = wyrmFrame(character, anchor)
		local home = wyrmHome(frame, wyrm.orbitAngle)

		-- Strip last frame's bob, spring toward home, bob again on top.
		local bobAmplitude = SpiritCompanionData.BOB_AMPLITUDE * WYRM_SCALE
		local current = wyrm.part.CFrame
		local unbobbed = current.Position - Vector3.new(0, math.sin(wyrm.bobPhase) * bobAmplitude, 0)
		local position
		if (home - unbobbed).Magnitude > SpiritCompanionData.TELEPORT_SNAP_DISTANCE then
			wyrm.velocity = Vector3.zero
			position = home
		else
			position, wyrm.velocity = smoothDamp(unbobbed, home, wyrm.velocity, WYRM_SMOOTH_TIME, deltaTime)
		end
		wyrm.bobPhase += deltaTime * (2 * math.pi / SpiritCompanionData.BOB_CYCLE_SECONDS)
		position += Vector3.new(0, math.sin(wyrm.bobPhase) * bobAmplitude, 0)

		local look = if wyrm.facing and now < wyrm.faceUntil then wyrm.facing else frame.LookVector
		local desired = CFrame.lookAt(Vector3.zero, look * Vector3.new(1, 0, 1) + Vector3.new(0, 0, 1e-4))
		wyrm.part.CFrame = CFrame.new(position) * current.Rotation:Lerp(desired, turn)
	end
end

--[ Orbiting Shield ]--

local function orbitConfig(): (number, number, number)
	local row = RelicData[RelicNames["Spartan Sword and Shield"]]
	local data = (row and row.data) or {}
	return data.orbitRadius or 9, data.orbitSecondsPerTurn or 2.6, data.shields or 2
end

local function destroyShield(shield: Shield)
	for _, part in shield.parts do
		part:Destroy()
	end
end

local function keepShield(payload: Payload)
	local caster = payload.Caster
	if not caster then
		return
	end
	local expiresAt = os.clock() + math.max(payload.Duration - elapsedOf(payload), 0)
	local shield = shields[caster]
	if shield and not shield.fading then
		shield.expiresAt = expiresAt
		return
	end
	if shield then
		destroyShield(shield)
	end
	local _, _, count = orbitConfig()
	local parts: { BasePart } = {}
	for _ = 1, count do
		local part = makePart("OrbitingShield", SHIELD_SIZE * 0.4, STONE_COLOR, Enum.Material.Slate)
		part.Transparency = 1
		part.Parent = effectsFolder()
		TweenService:Create(
			part,
			TweenInfo.new(SHIELD_FADE_SECONDS, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Transparency = 0, Size = SHIELD_SIZE }
		):Play()
		table.insert(parts, part)
	end
	shields[caster] = { parts = parts, expiresAt = expiresAt, fading = false }
end

-- The local clock's offset onto the server's, eased (SHIELD_CLOCK_RATE).
local clockOffset: number? = nil

local function stepShields(deltaTime: number)
	local now = os.clock()
	local radius, secondsPerTurn = orbitConfig()
	local target = workspace:GetServerTimeNow() - now
	clockOffset = if clockOffset
		then clockOffset + (target - clockOffset) * (1 - math.exp(-SHIELD_CLOCK_RATE * deltaTime))
		else target
	-- The server's angle, from the shared clock; the slabs spread evenly.
	local base = ((now + (clockOffset :: number)) / secondsPerTurn) * math.pi * 2
	for caster, shield in shields do
		local character = caster.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not root or not root:IsA("BasePart") then
			shields[caster] = nil
			destroyShield(shield)
			continue
		end
		-- Gone with Stonebound at once, not at the keep-alive's end; they
		-- keep orbiting while they fade.
		if not shield.fading and (now >= shield.expiresAt or not root:FindFirstChild(AuraNames.Stonebound)) then
			shield.fading = true
			for _, part in shield.parts do
				TweenService:Create(
					part,
					TweenInfo.new(SHIELD_FADE_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
					{ Transparency = 1, Size = SHIELD_SIZE * 0.4 }
				):Play()
			end
			task.delay(SHIELD_FADE_SECONDS, function()
				if shields[caster] == shield then
					shields[caster] = nil
				end
				destroyShield(shield)
			end)
		end
		for index, part in shield.parts do
			local angle = base + (index - 1) * (math.pi * 2 / #shield.parts)
			local offset = Vector3.new(math.cos(angle), 0, math.sin(angle)) * radius
			local position = root.Position + offset
			part.CFrame = CFrame.lookAt(position, position + offset)
		end
	end
end

--[ 2026-10-30 prototypes ]--

-- Witches Brew's puddle: Frost Field's disc in poison green.
local function toxicPuddle(payload: Payload)
	local radius = payload.Radius
	local disc = makePart("ToxicPuddle", Vector3.new(0.3, radius * 2, radius * 2), TOXIC_COLOR)
	disc.Shape = Enum.PartType.Cylinder
	disc.Transparency = 1
	disc.CFrame = CFrame.new(payload.From + Vector3.new(0, 0.15, 0)) * CFrame.Angles(0, 0, math.rad(90))
	disc.Parent = effectsFolder()
	TweenService:Create(disc, TweenInfo.new(0.25), { Transparency = 0.6 }):Play()
	local emitters = statusEmitters("Poison", disc)
	task.delay(math.max(payload.Duration - elapsedOf(payload), 0.2), function()
		retire(disc, emitters, 0.4, 1.5)
	end)
end

-- Rubber Chicken Launcher: a crackling ball stuck to its Target for the
-- fuse (the server's ShockBurst packet is the detonation).
local function staticCharge(payload: Payload)
	local target = payload.Target
	local targetRoot = target and target:FindFirstChild("HumanoidRootPart")
	local ball = makePart("StaticCharge", Vector3.one * STATIC_CHARGE_SIZE, SHOCK_COLOR)
	ball.Shape = Enum.PartType.Ball
	ball.Transparency = 0.2
	ball.Position = payload.From
	ball.Parent = effectsFolder()
	local light = Instance.new("PointLight")
	light.Color = SHOCK_COLOR
	light.Brightness = 3
	light.Range = 8
	light.Parent = ball
	local emitters = statusEmitters("Shock", ball)
	local lastSpark = 0
	animate(payload.Duration, elapsedOf(payload), function(alpha: number)
		local anchor = if targetRoot
				and targetRoot:IsA("BasePart")
				and targetRoot.Parent
			then targetRoot.Position
			else ball.Position
		-- Swells and flickers faster as the fuse runs out.
		local pulse = 1 + 0.25 * math.sin(alpha * alpha * 60)
		ball.Size = Vector3.one * STATIC_CHARGE_SIZE * (1 + alpha * 0.8) * pulse
		ball.Position = anchor + Vector3.new(0, 1.5, 0)
		if os.clock() - lastSpark > 0.25 - alpha * 0.18 then
			lastSpark = os.clock()
			local spark = ball.Position
				+ Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5).Unit * 3
			bolt(ball.Position, spark)
		end
	end, function()
		retire(ball, emitters, 0.1, 1)
	end)
end

-- Hailstorm: a dark cloud over the zone and a frosted ring on the ground
-- for its Duration; each shard is its own HailShard packet.
local function hailstorm(payload: Payload)
	local radius = payload.Radius
	local ring = makePart("HailstormRing", Vector3.new(0.2, radius * 2, radius * 2), ICE_COLOR)
	ring.Shape = Enum.PartType.Cylinder
	ring.Transparency = 1
	ring.CFrame = CFrame.new(payload.From + Vector3.new(0, 0.12, 0)) * CFrame.Angles(0, 0, math.rad(90))
	ring.Parent = effectsFolder()
	local cloud = makePart("HailstormCloud", Vector3.new(radius * 2.2, 2.5, radius * 2.2), Color3.fromRGB(70, 90, 120))
	cloud.Material = Enum.Material.SmoothPlastic
	cloud.Shape = Enum.PartType.Ball
	cloud.Transparency = 1
	cloud.Position = payload.From + Vector3.new(0, HAIL_CLOUD_HEIGHT, 0)
	cloud.Parent = effectsFolder()
	TweenService:Create(ring, TweenInfo.new(0.3), { Transparency = 0.8 }):Play()
	TweenService:Create(cloud, TweenInfo.new(0.3), { Transparency = 0.35 }):Play()
	local emitters = statusEmitters("Chill", cloud)
	task.delay(math.max(payload.Duration - elapsedOf(payload), 0.2), function()
		retire(ring, nil, 0.4)
		retire(cloud, emitters, 0.5, 1.5)
	end)
end

local function hailShard(payload: Payload)
	local shard = makePart("HailShard", HAIL_SHARD_SIZE, ICE_COLOR)
	shard.Transparency = 0.1
	shard.CFrame = CFrame.new(payload.From)
	shard.Parent = effectsFolder()
	local from, to = payload.From, payload.To
	animate(payload.Duration, elapsedOf(payload), function(alpha: number)
		shard.CFrame = CFrame.new(from:Lerp(to, alpha * alpha))
	end, function()
		shard:Destroy()
		burst(to, payload.Radius * 0.6, ICE_COLOR)
	end)
end

-- Korblox Ice Claws: a translucent ice sphere on its caster, kept alive by the
-- server's once-a-second re-send like the Orbiting Shield.
local function dismissShell(caster: Player)
	local shell = shells[caster]
	if not shell or shell.fading then
		return
	end
	shell.fading = true
	TweenService:Create(shell.part, TweenInfo.new(ICE_SHELL_FADE_SECONDS), { Transparency = 1 }):Play()
	task.delay(ICE_SHELL_FADE_SECONDS, function()
		if shells[caster] == shell then
			shells[caster] = nil
		end
		shell.part:Destroy()
	end)
end

local function keepIceShell(payload: Payload)
	local caster = payload.Caster
	if not caster then
		return
	end
	local expiresAt = os.clock() + math.max(payload.Duration - elapsedOf(payload), 0)
	local shell = shells[caster]
	if shell and not shell.fading then
		shell.expiresAt = expiresAt
		return
	end
	local part = makePart("IceShell", Vector3.one * ICE_SHELL_SIZE * 0.6, ICE_COLOR, Enum.Material.Glass)
	part.Shape = Enum.PartType.Ball
	part.Transparency = 1
	part.Position = payload.From
	part.Parent = effectsFolder()
	TweenService:Create(
		part,
		TweenInfo.new(ICE_SHELL_FADE_SECONDS, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Transparency = ICE_SHELL_TRANSPARENCY, Size = Vector3.one * ICE_SHELL_SIZE }
	):Play()
	shells[caster] = { part = part, expiresAt = expiresAt, fading = false }
end

local function stepShells()
	local now = os.clock()
	for caster, shell in shells do
		local character = caster.Character
		local found = character and character:FindFirstChild("HumanoidRootPart")
		local root: BasePart? = if found and found:IsA("BasePart") then found else nil
		if not root or not caster.Parent or now >= shell.expiresAt then
			dismissShell(caster)
		end
		if root then
			shell.part.Position = root.Position
		end
	end
end

-- The shatter: a big frost burst and a ring of shards flung outward.
local function iceShellShatter(payload: Payload)
	burst(payload.From, payload.Radius, ICE_COLOR)
	for index = 1, 10 do
		local angle = index / 10 * math.pi * 2
		local outward = Vector3.new(math.cos(angle), 0.15, math.sin(angle))
		local shard = makePart("IceShellShard", Vector3.new(0.6, 0.6, 2), ICE_COLOR)
		shard.Transparency = 0.1
		local from = payload.From
		local to = from + outward * payload.Radius
		shard.CFrame = CFrame.lookAt(from, to)
		shard.Parent = effectsFolder()
		animate(0.3, 0, function(alpha: number)
			shard.CFrame = CFrame.lookAt(from:Lerp(to, alpha), to)
		end, function()
			retire(shard, nil, 0.2)
		end)
	end
end

-- Melted (Fire Breathing Friend): GameAssets.Auras.Melted on the mob while
-- the attribute is set (a temporary green-fire stand-in for now).
local function setMelted(model: Model, melted: boolean)
	local existing = meltedFire[model]
	if melted and not existing then
		local root = model:FindFirstChild("HumanoidRootPart")
		if not root or not root:IsA("BasePart") then
			return
		end
		meltedFire[model] = statusEmitters("Melted", root)
	elseif not melted and existing then
		meltedFire[model] = nil
		for _, emitter in existing do
			emitter.Enabled = false
			Debris:AddItem(emitter, 1.5)
		end
	end
end

local function watchMelted(model: Model)
	model:GetAttributeChangedSignal(Attributes.Melted):Connect(function()
		setMelted(model, model:GetAttribute(Attributes.Melted) == true)
	end)
	model.AncestryChanged:Connect(function()
		if not model.Parent then
			meltedFire[model] = nil
		end
	end)
	if model:GetAttribute(Attributes.Melted) == true then
		setMelted(model, true)
	end
end

--[ Ban Hammer ]--

-- The Ban Hammer relic model (GameAssets.Relics.Legendary["Ban Hammer"])
-- drops onto the executed enemy head-first and slams down in Duration,
-- then bursts and fades. A plain red block stands in if the asset is gone.
local function banHammer(payload: Payload)
	local relics = ReplicatedStorage.GameAssets:FindFirstChild("Relics")
	local legendary = relics and relics:FindFirstChild("Legendary")
	local template = legendary and legendary:FindFirstChild(RelicNames["Ban Hammer"])
	local hammer: PVInstance
	if template and (template:IsA("Model") or template:IsA("BasePart")) then
		local clone = template:Clone()
		if clone:IsA("Model") then
			clone:ScaleTo(clone:GetScale() * BAN_HAMMER_SCALE)
		end
		hammer = clone :: any
	else
		hammer = makePart("BanHammer", Vector3.new(3, 6, 3), BAN_COLOR, Enum.Material.SmoothPlastic)
	end
	for _, descendant in (hammer :: Instance):GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
		end
	end
	if hammer:IsA("BasePart") then
		hammer.Anchored = true
		hammer.CanCollide = false
		hammer.CanQuery = false
		hammer.CanTouch = false
	end
	-- Lands with its head on the floor, not buried to the pivot.
	local size = if hammer:IsA("Model") then hammer:GetExtentsSize() else (hammer :: BasePart).Size
	local landing = payload.From + Vector3.new(0, size.Y * 0.35, 0)
	local top = landing + Vector3.new(0, BAN_HAMMER_DROP_HEIGHT, 0)
	-- Head down, tipping forward as it falls.
	local tilt = CFrame.Angles(0, math.random() * math.pi * 2, 0) * CFrame.Angles(math.rad(180), 0, 0)
	hammer:PivotTo(CFrame.new(top) * tilt)
	hammer.Parent = effectsFolder()
	animate(payload.Duration, elapsedOf(payload), function(alpha: number)
		local eased = alpha * alpha
		hammer:PivotTo(CFrame.new(top:Lerp(landing, eased)) * tilt)
	end, function()
		burst(payload.From, payload.Radius, BAN_COLOR)
		burst(payload.From, payload.Radius * 0.5, GOLD_COLOR)
		Debris:AddItem(hammer, BAN_HAMMER_LINGER_SECONDS)
	end)
end

--[ Dispatch ]--

local HANDLERS: { [string]: (Payload) -> () } = {
	FlameWave = function(payload)
		travellingSlash(payload, FLAME_WAVE_SIZE, FIRE_COLOR, "Burn", false)
	end,
	ThunderBlade = function(payload)
		travellingSlash(payload, THUNDER_BLADE_SIZE, BOLT_COLOR, nil, true)
	end,
	BanHammer = banHammer,
	PhoenixTrail = phoenixTrail,
	FrostField = frostField,
	IceShard = function(payload)
		local shard = makePart("BlizzardShard", Vector3.new(0.8, 2.2, 0.8), ICE_COLOR)
		shard.Transparency = 0.1
		lob(payload, shard, ICE_COLOR, true, SHARD_ARC_HEIGHT)
	end,
	ToxicBubble = function(payload)
		local bubble = makePart("ToxicBubble", Vector3.one * 1.1, TOXIC_COLOR)
		bubble.Shape = Enum.PartType.Ball
		bubble.Transparency = 0.25
		lob(payload, bubble, TOXIC_COLOR, false, ARC_HEIGHT)
	end,
	Bolt = function(payload)
		bolt(payload.From, payload.To)
	end,
	WyrmSummon = summonWyrm,
	FrostOrb = frostOrb,
	OrbitShield = keepShield,
	-- 2026-10-30 prototypes.
	Boulder = function(payload)
		local rock = makePart("Boulder", BOULDER_SIZE, STONE_COLOR, Enum.Material.Slate)
		rock.Shape = Enum.PartType.Ball
		lob(payload, rock, STONE_COLOR, true, ARC_HEIGHT)
	end,
	StaticCharge = staticCharge,
	ToxicPuddle = toxicPuddle,
	Hailstorm = hailstorm,
	HailShard = hailShard,
	IceShell = keepIceShell,
	IceShellShatter = iceShellShatter,
}

function RelicGimmickFXController.Start(_self: typeof(RelicGimmickFXController))
	RelicNetwork.GimmickEffect.On(function(payload: Payload)
		local color = BURST_COLORS[payload.Kind]
		if color then
			burst(payload.From, payload.Radius, color)
			return
		end
		local handler = HANDLERS[payload.Kind]
		if handler then
			handler(payload)
		end
	end)

	RunService.RenderStepped:Connect(stepShields)
	RunService.RenderStepped:Connect(stepShells)

	-- Melted: every mob under the Mobs folder, as it arrives.
	task.spawn(function()
		local ignore = workspace:WaitForChild("IgnoreInstances")
		local mobs = ignore:WaitForChild("Mobs")
		local function onDescendant(descendant: Instance)
			local model = descendant.Parent
			if descendant:IsA("Humanoid") and model and model:IsA("Model") then
				watchMelted(model)
			end
		end
		mobs.DescendantAdded:Connect(onDescendant)
		for _, descendant in mobs:GetDescendants() do
			onDescendant(descendant)
		end
	end)
	-- Heartbeat, as SpiritCompanion: after physics, so the anchor holds
	-- this frame's position rather than last frame's.
	RunService.Heartbeat:Connect(stepWyrms)
end

return RelicGimmickFXController
