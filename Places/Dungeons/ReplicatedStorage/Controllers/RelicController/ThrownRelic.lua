--[[
	Module: Client/Controllers/RelicController/ThrownRelic.lua
	Description:
	The shared client visual for a relic that is LOBBED from a corpse onto the
	ground and detonates: Trick Or Trap's Explosive Pumpkins and Fuse
	Bomb's bombs both run through here.

	Flow (identical for every user -- the only difference is which model is
	thrown):
	  1. Take the relic's display model (pooled), fade it in at the corpse.
	  2. Arc it along a quadratic bezier to the ground target, spinning on a
	     random per-throw rate, timed off the SERVER's start stamp so every
	     client sees the same flight.
	  3. On landing: kill the trail particles, then after a short beat play
	     the shared ExplosionFX (sound + burst) and fade the model out.

	Damage is NOT this module's job -- MobBase already fires the real hitbox
	server-side on the same clock. This is purely presentation, so a missing
	asset degrades to "no visual" instead of breaking the kill.

	The model is resolved from RelicData's rarity (GameAssets.Relics.<rarity>
	.<relicName>), the same convention the relic drop path uses.

	PERFORMANCE (2026-10-30: a chain of takedown bombs lagged clients):
	  * the thrown models (per relic name and scale, ScaleTo'd once) and the
	    ExplosionFX are POOLED -- reused, never cloned per bomb;
	  * every live bomb flies off ONE shared RenderStepped connection, held
	    only while a bomb is in the air;
	  * a used model / blast goes back to the pool once its longest particle
	    (ParticleEmitter Lifetime.Max) and its sound have run out, instead of
	    a fixed 5 s;
	  * the clones never collide, touch or answer queries;
	  * at most MAX_AUDIBLE_EXPLOSIONS blasts play their sound at once.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local getRelicModelTemplate = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Relic.getRelicModelTemplate)

--[ Constants ]--

local DEFAULT_SCALE = 1.35
local FADE_SECONDS = 0.25
local ARC_APEX_STUDS = 10 -- height the bezier's control point sits above the midpoint
local LAND_TO_BLAST_SECONDS = 0.25
local EXPLOSION_VOLUME = 0.05
-- The second explosion layer starts this far in (its attack is silence).
local EXPLOSION2_START_SECONDS = 0.25
local LANDING_EMIT_COUNT = 5
local BLAST_EMIT_COUNT = 10
-- A used model / blast returns to its pool this long after its longest
-- particle lifetime (or sound) has run out.
local CLEANUP_MARGIN_SECONDS = 0.25
-- Never held longer than the old fixed cleanup.
local MAX_HOLD_SECONDS = 5
-- Blasts whose sound plays at the same time (each is a two-layer sound);
-- the rest go off silently. A chain of bombs was dozens of overlapping
-- explosions, all at the same low volume anyway.
local MAX_AUDIBLE_EXPLOSIONS = 4
-- Idle entries kept per pool; extras are destroyed on release.
local MAX_IDLE_PER_POOL = 12

local FADE_INFO = TweenInfo.new(FADE_SECONDS, Enum.EasingStyle.Cubic)

--[ Types ]--

type ModelEntry = {
	key: string,
	model: Model,
	handle: BasePart?,
	-- The ActiveAttachment trail emitters and their authored Enabled state,
	-- restored on every reuse.
	trail: { ParticleEmitter },
	trailEnabled: { boolean },
	-- Seconds past the blast before the model may go back to the pool.
	holdSeconds: number,
}

type BlastEntry = {
	part: BasePart,
	emitters: { ParticleEmitter },
	explosion: Sound?,
	explosion2: Sound?,
	-- Seconds the burst's particles live (Lifetime.Max + margin).
	particleSeconds: number,
}

type Flight = {
	entry: ModelEntry,
	startTime: number,
	duration: number,
	origin: Vector3,
	control: Vector3,
	target: Vector3,
	rotation: number,
	spinRate: number,
	bezier: any,
}

--[ State ]--

local modelPools: { [string]: { ModelEntry } } = {}
local blastPool: { BlastEntry } = {}
local flights: { Flight } = {}
local stepConnection: RBXScriptConnection? = nil
local audibleExplosions = 0

local ThrownRelic = {}
ThrownRelic.__index = ThrownRelic

--[ Helpers ]--

local function spellsFolder(): Instance
	return workspace.IgnoreInstances.ArcaneSpells
end

-- Resolves a relic's display model (tree-aware folder layout). Returns nil
-- (with a warn) rather than erroring, so a missing asset can't break a
-- takedown.
local function resolveModel(relicName: string): Model?
	local template = getRelicModelTemplate(relicName)
	if not template then
		warn("[ThrownRelic] Missing relic model for " .. tostring(relicName))
	end
	return template
end

local function resolveBlastTemplate(): BasePart?
	local vfxFolder = ReplicatedStorage.GameAssets:FindFirstChild("VFX")
	local fireBlast = vfxFolder and vfxFolder:FindFirstChild("Fire Blast")
	local template = fireBlast and fireBlast:FindFirstChild("ExplosionFX")
	return if template and template:IsA("BasePart") then template else nil
end

-- Pure visuals: nothing a clone holds collides, fires Touched or turns up
-- in a raycast / spatial query.
local function makeInert(root: Instance)
	local parts = root:GetDescendants()
	table.insert(parts, root)
	for _, descendant in parts do
		if descendant:IsA("BasePart") then
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
		end
	end
end

local function longestLifetime(emitters: { ParticleEmitter }): number
	local longest = 0
	for _, emitter in emitters do
		longest = math.max(longest, emitter.Lifetime.Max)
	end
	return longest
end

-- True while `instance` is still where we parented it -- false once
-- something else destroyed or moved it (then it is not pooled again).
local function stillOurs(instance: Instance): boolean
	return instance.Parent == spellsFolder()
end

--[ Model pool ]--

local function poolKey(relicName: string, scale: number): string
	return relicName .. "@" .. tostring(scale)
end

local function newModelEntry(key: string, relicName: string, scale: number): ModelEntry?
	local template = resolveModel(relicName)
	if not template then
		return nil
	end
	local model = template:Clone()

	-- The idle "pick me up" sparkle belongs to the ground pickup, not to a
	-- thrown projectile. Guarded: not every relic model carries one.
	local primary = model.PrimaryPart
	local idleParticles = primary and primary:FindFirstChild("RelicParticleAttachment")
	if idleParticles then
		idleParticles:Destroy()
	end

	-- Once per pooled model, never per throw.
	model:ScaleTo(scale)
	makeInert(model)

	local trail: { ParticleEmitter } = {}
	local trailEnabled: { boolean } = {}
	local activeAttachment = primary and primary:FindFirstChild("ActiveAttachment")
	if activeAttachment then
		for _, particle in activeAttachment:GetChildren() do
			if particle:IsA("ParticleEmitter") then
				table.insert(trail, particle)
				table.insert(trailEnabled, particle.Enabled)
			end
		end
	end

	local handle = model:FindFirstChild("Handle") or primary
	-- The landing puff is emitted LAND_TO_BLAST_SECONDS before the blast;
	-- the fade-out runs FADE_SECONDS after it.
	local trailTail = math.max(longestLifetime(trail) - LAND_TO_BLAST_SECONDS, FADE_SECONDS)

	return {
		key = key,
		model = model,
		handle = if handle and handle:IsA("BasePart") then handle else nil,
		trail = trail,
		trailEnabled = trailEnabled,
		holdSeconds = math.min(trailTail + CLEANUP_MARGIN_SECONDS, MAX_HOLD_SECONDS),
	}
end

local function acquireModel(relicName: string, scale: number): ModelEntry?
	local key = poolKey(relicName, scale)
	local pool = modelPools[key]
	local entry = pool and table.remove(pool)
	if not entry then
		entry = newModelEntry(key, relicName, scale)
	end
	if not entry then
		return nil
	end
	for index, particle in entry.trail do
		particle:Clear()
		particle.Enabled = entry.trailEnabled[index]
	end
	return entry
end

local function releaseModel(entry: ModelEntry)
	if not stillOurs(entry.model) then
		return
	end
	local pool = modelPools[entry.key]
	if not pool then
		pool = {}
		modelPools[entry.key] = pool
	end
	if #pool >= MAX_IDLE_PER_POOL then
		entry.model:Destroy()
		return
	end
	entry.model.Parent = nil
	table.insert(pool, entry)
end

--[ Blast pool ]--

local function acquireBlast(): BlastEntry?
	local entry = table.remove(blastPool)
	if entry then
		return entry
	end
	local template = resolveBlastTemplate()
	if not template then
		return nil
	end
	local part = template:Clone()
	makeInert(part)
	local emitters: { ParticleEmitter } = {}
	local attachment = part:FindFirstChild("Attachment")
	if attachment then
		for _, descendant in attachment:GetChildren() do
			if descendant:IsA("ParticleEmitter") then
				table.insert(emitters, descendant)
			end
		end
	end
	local explosion = part:FindFirstChild("Explosion")
	local explosion2 = part:FindFirstChild("Explosion2")
	return {
		part = part,
		emitters = emitters,
		explosion = if explosion and explosion:IsA("Sound") then explosion else nil,
		explosion2 = if explosion2 and explosion2:IsA("Sound") then explosion2 else nil,
		particleSeconds = longestLifetime(emitters) + CLEANUP_MARGIN_SECONDS,
	}
end

local function releaseBlast(entry: BlastEntry)
	if not stillOurs(entry.part) then
		return
	end
	if #blastPool >= MAX_IDLE_PER_POOL then
		entry.part:Destroy()
		return
	end
	entry.part.Parent = nil
	table.insert(blastPool, entry)
end

-- Plays the blast's two-layer sound when fewer than MAX_AUDIBLE_EXPLOSIONS
-- are already sounding. Returns how long the sound runs (0 when skipped).
local function playExplosionSound(entry: BlastEntry): number
	if audibleExplosions >= MAX_AUDIBLE_EXPLOSIONS then
		return 0
	end
	local seconds = 0
	local explosion = entry.explosion
	if explosion then
		explosion.Volume = EXPLOSION_VOLUME
		explosion.TimePosition = 0
		explosion:Play()
		seconds = math.max(seconds, explosion.TimeLength)
	end
	local explosion2 = entry.explosion2
	if explosion2 then
		explosion2.Volume = EXPLOSION_VOLUME
		explosion2.TimePosition = EXPLOSION2_START_SECONDS
		explosion2:Play()
		seconds = math.max(seconds, explosion2.TimeLength - EXPLOSION2_START_SECONDS)
	end
	-- An unloaded sound reports TimeLength 0: count it for the whole hold.
	if seconds <= 0 then
		seconds = MAX_HOLD_SECONDS
	end
	seconds = math.min(seconds, MAX_HOLD_SECONDS)
	audibleExplosions += 1
	task.delay(seconds, function()
		audibleExplosions -= 1
	end)
	return seconds
end

local function playBlast(position: Vector3)
	local entry = acquireBlast()
	if not entry then
		return
	end
	entry.part.CFrame = CFrame.new(position)
	for _, emitter in entry.emitters do
		emitter:Clear()
	end
	entry.part.Parent = spellsFolder()

	local soundSeconds = playExplosionSound(entry)
	for _, emitter in entry.emitters do
		emitter:Emit(BLAST_EMIT_COUNT)
	end

	local hold = math.min(math.max(entry.particleSeconds, soundSeconds + CLEANUP_MARGIN_SECONDS), MAX_HOLD_SECONDS)
	task.delay(hold, releaseBlast, entry)
end

--[ Flight ]--

local function land(flight: Flight)
	local entry = flight.entry
	for _, particle in entry.trail do
		particle.Enabled = false
		particle:Emit(LANDING_EMIT_COUNT)
	end

	task.delay(LAND_TO_BLAST_SECONDS, function()
		playBlast(flight.target)

		local handle = entry.handle
		if handle then
			TweenService:Create(handle, FADE_INFO, { Transparency = 1 }):Play()
		end
		task.delay(entry.holdSeconds, releaseModel, entry)
	end)
end

-- The ONE RenderStepped for every bomb in the air.
local function step(deltaTime: number)
	-- Alpha comes off the SERVER clock, so every client's arc lands at the
	-- same moment the server's hitbox fires.
	local now = workspace:GetServerTimeNow()
	for index = #flights, 1, -1 do
		local flight = flights[index]
		local alpha = if flight.duration > 0 then math.clamp((now - flight.startTime) / flight.duration, 0, 1) else 1
		flight.rotation += deltaTime * flight.spinRate

		local pos = flight.bezier:GenerateBezierCurve(alpha, flight.origin, flight.control, flight.target)
		flight.entry.model:PivotTo(CFrame.new(pos) * CFrame.Angles(0, flight.rotation, 0))

		if alpha >= 1 then
			-- Swap-remove: the tail was already stepped (backwards loop).
			flights[index] = flights[#flights]
			flights[#flights] = nil
			land(flight)
		end
	end
	if #flights == 0 and stepConnection then
		stepConnection:Disconnect()
		stepConnection = nil
	end
end

--[ Public ]--

function ThrownRelic.new(
	relicName: string,
	position: Vector3,
	targetPosition: Vector3,
	startTime: number,
	duration: number,
	quadraticBezierController: any,
	scale: number?
)
	local self = setmetatable({}, ThrownRelic)
	self.relicName = relicName
	self.position = position
	self.targetPosition = targetPosition
	self.startTime = startTime
	self.duration = duration
	self.quadraticBezierController = quadraticBezierController
	self.scale = scale or DEFAULT_SCALE
	return self
end

function ThrownRelic:PlayEffect()
	local entry = acquireModel(self.relicName, self.scale)
	if not entry then
		return
	end

	local model = entry.model
	model:PivotTo(CFrame.new(self.position))

	local handle = entry.handle
	if handle then
		handle.Transparency = 1
		TweenService:Create(handle, FADE_INFO, { Transparency = 0 }):Play()
	end
	model.Parent = spellsFolder()

	local originPosition = self.position
	local targetPosition = self.targetPosition
	table.insert(flights, {
		entry = entry,
		startTime = self.startTime,
		duration = self.duration,
		origin = originPosition,
		control = (originPosition + targetPosition) / 2 + Vector3.new(0, ARC_APEX_STUDS, 0),
		target = targetPosition,
		rotation = 0,
		spinRate = if self.duration > 0 then math.rad(math.random(-360, 360)) / self.duration else 0,
		bezier = self.quadraticBezierController,
	})
	if not stepConnection then
		stepConnection = RunService.RenderStepped:Connect(step)
	end
end

return ThrownRelic
