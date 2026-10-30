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
	  * the Ice Dragon Slayer's FROST WYRM, a neon ice cube hovering above
	    its caster's shoulder (a smooth follow and bob, like a spirit
	    companion) that fades in and out and turns to face each FrostOrb
	    it fires;
	  * the Spartan Sword and Shield's ORBITING SHIELD, whose angle comes
	    from the server clock, so it sits where the server hits with it.

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

--[ Constants ]--

local FIRE_COLOR = Color3.fromRGB(255, 120, 35)
local ICE_COLOR = Color3.fromRGB(120, 210, 255)
local TOXIC_COLOR = Color3.fromRGB(120, 230, 90)
local BOLT_COLOR = Color3.fromRGB(150, 210, 255)
local STONE_COLOR = Color3.fromRGB(150, 140, 120)

local BURST_COLORS: { [string]: Color3 } = {
	FireBurst = FIRE_COLOR,
	FrostBurst = ICE_COLOR,
	ToxicBurst = TOXIC_COLOR,
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

-- Lobbed shards / bubbles.
local ARC_HEIGHT = 6

-- Frost Wyrm: the cube, where it hovers in its caster's frame, how
-- quickly it follows and turns, and how long it fades.
local WYRM_SIZE = Vector3.new(3, 3, 3)
local WYRM_TRANSPARENCY = 0.15
local WYRM_OFFSET = Vector3.new(-3.5, 7, 2)
local WYRM_FOLLOW_RATE = 8
local WYRM_TURN_RATE = 10
local WYRM_FADE_SECONDS = 0.35
local WYRM_BOB_AMPLITUDE = 0.35
local WYRM_BOB_SPEED = 2.2
-- How long the wyrm keeps facing a shot before it turns back to your look.
local WYRM_FACE_SECONDS = 0.8
local FROST_ORB_SIZE = 1.4

-- Orbiting Shield: its slab and how it fades in and out.
local SHIELD_SIZE = Vector3.new(3, 3.4, 0.6)
local SHIELD_FADE_SECONDS = 0.35
-- How fast the local clock is eased onto the server's: GetServerTimeNow
-- steps a little frame to frame, and an angle read straight off it
-- jitters the slab.
local SHIELD_CLOCK_RATE = 2

--[ Types ]--

type Payload = {
	Kind: string,
	Caster: Player?,
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
}

type Shield = { part: BasePart, expiresAt: number, fading: boolean }

--[ Module ]--

local RelicGimmickFXController = {
	Name = "RelicGimmickFXController",
}

local wyrms: { [Player]: Wyrm } = {}
local shields: { [Player]: Shield } = {}

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
local function lob(payload: Payload, part: BasePart, burstColor: Color3, spins: boolean)
	local from, to = payload.From, payload.To
	part.Position = from
	part.Parent = effectsFolder()
	local last = from
	animate(payload.Duration, elapsedOf(payload), function(alpha: number)
		local point = from:Lerp(to, alpha) + Vector3.new(0, math.sin(alpha * math.pi) * ARC_HEIGHT, 0)
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

local function wyrmHome(root: BasePart): Vector3
	return (root.CFrame * CFrame.new(WYRM_OFFSET)).Position
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
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not caster or not root or not root:IsA("BasePart") then
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
	part.CFrame = CFrame.lookAt(wyrmHome(root), wyrmHome(root) + root.CFrame.LookVector)
	local light = Instance.new("PointLight")
	light.Color = ICE_COLOR
	light.Brightness = 0
	light.Range = 14
	light.Parent = part
	part.Parent = effectsFolder()
	TweenService:Create(part, TweenInfo.new(WYRM_FADE_SECONDS), { Transparency = WYRM_TRANSPARENCY }):Play()
	TweenService:Create(light, TweenInfo.new(WYRM_FADE_SECONDS), { Brightness = 2 }):Play()
	wyrms[caster] = { part = part, expiresAt = expiresAt, facing = nil, faceUntil = 0, fading = false }
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
	animate(payload.Duration, elapsedOf(payload), function(alpha: number)
		orb.Position = from:Lerp(to, alpha)
	end, function()
		burst(to, payload.Radius, ICE_COLOR)
		retire(orb, emitters, 0.1, 1)
	end)
end

local function stepWyrms(deltaTime: number)
	local now = os.clock()
	local follow = 1 - math.exp(-WYRM_FOLLOW_RATE * deltaTime)
	local turn = 1 - math.exp(-WYRM_TURN_RATE * deltaTime)
	for caster, wyrm in wyrms do
		local character = caster.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not root or not root:IsA("BasePart") or not caster.Parent then
			dismissWyrm(caster)
			continue
		end
		if now >= wyrm.expiresAt then
			dismissWyrm(caster)
		end
		local current = wyrm.part.CFrame
		local bob = Vector3.new(0, math.sin(now * WYRM_BOB_SPEED) * WYRM_BOB_AMPLITUDE, 0)
		local position = current.Position:Lerp(wyrmHome(root) + bob, follow)
		local look = if wyrm.facing and now < wyrm.faceUntil then wyrm.facing else root.CFrame.LookVector
		local desired = CFrame.lookAt(Vector3.zero, look * Vector3.new(1, 0, 1) + Vector3.new(0, 0, 1e-4))
		local rotation = current.Rotation:Lerp(desired, turn)
		wyrm.part.CFrame = CFrame.new(position) * rotation
	end
end

--[ Orbiting Shield ]--

local function orbitConfig(): (number, number)
	local row = RelicData[RelicNames["Spartan Sword and Shield"]]
	local data = (row and row.data) or {}
	return data.orbitRadius or 7.5, data.orbitSecondsPerTurn or 2.6
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
		shield.part:Destroy()
	end
	local part = makePart("OrbitingShield", SHIELD_SIZE * 0.4, STONE_COLOR, Enum.Material.Slate)
	part.Transparency = 1
	part.Parent = effectsFolder()
	TweenService:Create(
		part,
		TweenInfo.new(SHIELD_FADE_SECONDS, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Transparency = 0, Size = SHIELD_SIZE }
	):Play()
	shields[caster] = { part = part, expiresAt = expiresAt, fading = false }
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
	-- The server's angle, from the shared clock.
	local angle = ((now + (clockOffset :: number)) / secondsPerTurn) * math.pi * 2
	for caster, shield in shields do
		local character = caster.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not root or not root:IsA("BasePart") then
			shields[caster] = nil
			shield.part:Destroy()
			continue
		end
		-- Gone with Stonebound at once, not at the keep-alive's end; it
		-- keeps orbiting while it fades.
		if not shield.fading and (now >= shield.expiresAt or not root:FindFirstChild(AuraNames.Stonebound)) then
			shield.fading = true
			TweenService:Create(
				shield.part,
				TweenInfo.new(SHIELD_FADE_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				{ Transparency = 1, Size = SHIELD_SIZE * 0.4 }
			):Play()
			task.delay(SHIELD_FADE_SECONDS, function()
				if shields[caster] == shield then
					shields[caster] = nil
				end
				shield.part:Destroy()
			end)
		end
		local offset = Vector3.new(math.cos(angle), 0, math.sin(angle)) * radius
		local position = root.Position + offset
		shield.part.CFrame = CFrame.lookAt(position, position + offset)
	end
end

--[ Dispatch ]--

local HANDLERS: { [string]: (Payload) -> () } = {
	FlameWave = function(payload)
		travellingSlash(payload, FLAME_WAVE_SIZE, FIRE_COLOR, "Burn", false)
	end,
	ThunderBlade = function(payload)
		travellingSlash(payload, THUNDER_BLADE_SIZE, BOLT_COLOR, nil, true)
	end,
	PhoenixTrail = phoenixTrail,
	FrostField = frostField,
	IceShard = function(payload)
		local shard = makePart("BlizzardShard", Vector3.new(0.8, 2.2, 0.8), ICE_COLOR)
		shard.Transparency = 0.1
		lob(payload, shard, ICE_COLOR, true)
	end,
	ToxicBubble = function(payload)
		local bubble = makePart("ToxicBubble", Vector3.one * 1.1, TOXIC_COLOR)
		bubble.Shape = Enum.PartType.Ball
		bubble.Transparency = 0.25
		lob(payload, bubble, TOXIC_COLOR, false)
	end,
	Bolt = function(payload)
		bolt(payload.From, payload.To)
	end,
	WyrmSummon = summonWyrm,
	FrostOrb = frostOrb,
	OrbitShield = keepShield,
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

	RunService.RenderStepped:Connect(function(deltaTime: number)
		stepWyrms(deltaTime)
		stepShields(deltaTime)
	end)
end

return RelicGimmickFXController
