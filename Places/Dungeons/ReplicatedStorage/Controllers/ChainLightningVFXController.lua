--!strict
--[[
	Module: Controllers/ChainLightningVFXController.lua
	Description:
	Lightning Bolt Sword's Chain Lightning, one link at a time (2026-11-04,
	built from xander22's Chain Lightning pack). The server fires one
	"Bolt" gimmick effect per jump (RelicGimmickService/Storm.lua) with the
	jump's start, its end and the enemy it hit; RelicGimmickFXController
	hands it here. Each link:

	  1. TRAVEL: the beam (three Beams between two attachments) grows from
	     the previous enemy to this one at BEAM_SPEED studs a game second,
	     sparks streaming from its head.
	  2. SHOCK: on arrival a ring and a burst of sparks at the head, and the
	     shock (lightning crackle, spikes, a flickering light) on the
	     enemy's body for SHOCK_SECONDS. Both ends keep following the two
	     bodies as they move.
	  3. AFTER: the beams fade over BEAM_FADE_SECONDS, the spark tail and
	     the crackle stop, and a puff of smoke rises off the body. Every
	     particle lives at most MAX_PARTICLE_SECONDS, so the whole link is
	     gone about a second after it lands: it marks the damage, it is
	     not a lingering effect (2026-11-04).

	COLOUR. Shock's purple (StatusConditionData), the colour of the status
	the bolt applies; the pack's own yellow only for a caster who owns
	Deluxe Coil Gun, whose Shocks become the yellow Coil Shocked. The grey
	smoke and the black under-beam keep their colour.

	(The body lookup and anchor are MobRenderController's TrackBody.)

	The pack's skeleton overlay, black highlight and electrocution
	animation are left out on purpose: they are R6 / R15 only.

	ANY RIG. The effect sits on the body this client DRAWS: a sim mob's
	rig (MobRenderController:GetRig), else the model itself. On that body
	it uses, in order:
	  * a descendant Attachment named "ChainLightningAttachment" (put one
	    in a custom rig to choose the exact spot);
	  * the UpperTorso, Torso or HumanoidRootPart;
	  * the PrimaryPart.
	The shock and the beam's head are scaled to the body's height (an R6
	rig, REFERENCE_HEIGHT studs, is 1), clamped to MIN_SCALE..MAX_SCALE; a
	"ChainLightningScale" number attribute on the rig overrides it.

	The assets are place-side: ReplicatedStorage.GameAssets.VFX.ChainLightning
	holds "Beam" (the pack's Lightning part) and "Shock" (its Effect part).
	Everything runs on game time, so slow motion slows it too.

	A Blitz module with no dependencies (MobRenderController is required
	directly and only read at play time).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Blitz = require(ReplicatedStorage.Submodules.Core.Shared.Blitz)
local GameClock = require(ReplicatedStorage.Submodules.Core.Shared.GameClock)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local StatusConditionData = require(ReplicatedStorage.Submodules.Core.Shared.Data.StatusConditionData)
local StatusConditions = require(ReplicatedStorage.Submodules.Core.Shared.Enums.StatusConditions)
local MobRenderController = require(script.Parent.MobRenderController)

--[ Tuning ]--

-- Studs a game second the beam's head travels (the pack's Speed).
local BEAM_SPEED = 200
-- How long each enemy is shocked, and the beam held, after the head lands
-- (0.2 since 2026-11-04; 0.25 before, the pack's 1.25 lingered).
local SHOCK_SECONDS = 0.2
-- No particle in the effect lives longer than this (the pack's embers and
-- smoke lived up to 2 s).
local MAX_PARTICLE_SECONDS = 0.3
-- The beams fade over this once the shock ends (gone 0.3 s after the
-- head lands).
local BEAM_FADE_SECONDS = 0.1
-- After the fade, how long the parts stay for their last particles.
local CLEANUP_SECONDS = MAX_PARTICLE_SECONDS + 0.1
-- The shock light flickers up to this and back every FLICKER_SECONDS.
local LIGHT_FLICKER_BRIGHTNESS = 20
local LIGHT_FLICKER_SECONDS = 0.1
local LIGHT_FADE_SECONDS = 0.175
-- Particle counts: every burst emits BURST_COUNT (2026-11-04; the
-- pack's 15-35 were too strong).
local BURST_COUNT = 5
local HEAD_SPARK_RATE = 200
local HEAD_IDLE_SPARK_RATE = 5
-- The previous enemy is the mob whose root is within this of the jump's
-- start (the server sends the position, not the model).
local ORIGIN_MATCH_STUDS = 3
-- Size: an R6 rig is about this tall and draws the effect at 1.
local REFERENCE_HEIGHT = 5
local MIN_SCALE = 0.75
local MAX_SCALE = 2.5
-- Per-emitter size on top of that (2026-11-04): the pulse ring and the
-- shock's crackle and spikes drawn smaller than the pack authored them.
-- An emitter not listed keeps its authored size.
local EMITTER_SIZE_SCALE: { [string]: number } = {
	Ring = 0.6,
	Lightning1 = 0.6,
	Spikes = 0.6,
	SpikesStart = 0.6,
}

local COIL_GUN = RelicNames["Deluxe Coil Gun"]
local SHOCK_COLOR: Color3 = StatusConditionData[StatusConditions.Shock].color
-- A colour this saturated or more is the pack's yellow (the smoke is grey
-- and the under-beam black: both stay).
local TINT_MIN_SATURATION = 0.3
-- The black under-beam the bright one is drawn over: never tinted.
local DARK_BEAM_NAME = "DarkBeam"

local ANCHOR_ATTACHMENT_NAME = "ChainLightningAttachment"
local SCALE_ATTRIBUTE = "ChainLightningScale"

local ChainLightningVFXController = {
	Name = "ChainLightningVFXController",
}

--[ Helpers ]--

local function assets(): Folder?
	local gameAssets = ReplicatedStorage:FindFirstChild("GameAssets")
	local vfx = gameAssets and gameAssets:FindFirstChild("VFX")
	local folder = vfx and vfx:FindFirstChild("ChainLightning")
	return if folder and folder:IsA("Folder") then folder else nil
end

local function effectParent(): Instance
	local ignore = workspace:FindFirstChild("IgnoreInstances")
	return (ignore and ignore:FindFirstChild("ArcaneSpells")) or ignore or workspace
end

local function effectScale(model: Model?): number
	if not model then
		return 1
	end
	local body = MobRenderController:GetVisualModel(model)
	local override = body:GetAttribute(SCALE_ATTRIBUTE)
	if typeof(override) == "number" then
		return override
	end
	return math.clamp(body:GetExtentsSize().Y / REFERENCE_HEIGHT, MIN_SCALE, MAX_SCALE)
end

local function scaleSequence(sequence: NumberSequence, scale: number): NumberSequence
	local keypoints = {}
	for _, keypoint in sequence.Keypoints do
		table.insert(
			keypoints,
			NumberSequenceKeypoint.new(keypoint.Time, keypoint.Value * scale, keypoint.Envelope * scale)
		)
	end
	return NumberSequence.new(keypoints)
end

local function isTinted(sequence: ColorSequence): boolean
	local _, saturation = sequence.Keypoints[1].Value:ToHSV()
	return saturation >= TINT_MIN_SATURATION
end

-- Every emitter, beam and light under `root` made ready to play: drawn
-- `scale` times its size, no particle living past MAX_PARTICLE_SECONDS,
-- and the pack's yellow swapped for `color` (nil keeps it).
local function prepareEffects(root: Instance, scale: number, color: Color3?)
	local tint = if color then ColorSequence.new(color) else nil
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("ParticleEmitter") then
			local emitterScale = scale * (EMITTER_SIZE_SCALE[descendant.Name] or 1)
			if math.abs(emitterScale - 1) >= 0.01 then
				descendant.Size = scaleSequence(descendant.Size, emitterScale)
			end
			local lifetime = descendant.Lifetime
			descendant.Lifetime = NumberRange.new(
				math.min(lifetime.Min, MAX_PARTICLE_SECONDS),
				math.min(lifetime.Max, MAX_PARTICLE_SECONDS)
			)
			if tint and isTinted(descendant.Color) then
				descendant.Color = tint
			end
		elseif descendant:IsA("Beam") then
			if descendant.Name == DARK_BEAM_NAME then
				-- The under-beam is ALWAYS black, whatever the colour.
				descendant.Color = ColorSequence.new(Color3.new(0, 0, 0))
			elseif tint and isTinted(descendant.Color) then
				descendant.Color = tint
			end
		elseif descendant:IsA("PointLight") then
			if math.abs(scale - 1) >= 0.01 then
				descendant.Range *= scale
			end
			if color then
				descendant.Color = color
			end
		end
	end
end

-- Shock's purple, or nil (the pack's yellow) for a Deluxe Coil Gun owner.
local function colorFor(caster: Player?): Color3?
	if caster then
		local RelicController = Blitz.OptionalController("RelicController")
		local relics = RelicController and RelicController:GetRelicsFromUserId(caster.UserId)
		if relics and (relics[COIL_GUN] or 0) > 0 then
			return nil
		end
	end
	return SHOCK_COLOR
end

-- `base` faded toward invisible by `fade` (0 = as authored, 1 = gone).
local function fadeSequence(base: NumberSequence, fade: number): NumberSequence
	local keypoints = {}
	for _, keypoint in base.Keypoints do
		table.insert(keypoints, NumberSequenceKeypoint.new(keypoint.Time, keypoint.Value + (1 - keypoint.Value) * fade))
	end
	return NumberSequence.new(keypoints)
end

local function emitter(parent: Instance?, name: string): ParticleEmitter?
	local found = parent and parent:FindFirstChild(name)
	return if found and found:IsA("ParticleEmitter") then found else nil
end

-- The mob (other than `exclude`) whose pivot is nearest `position`, within
-- ORIGIN_MATCH_STUDS.
local function mobNear(position: Vector3, exclude: Model?): Model?
	local ignore = workspace:FindFirstChild("IgnoreInstances")
	local mobs = ignore and ignore:FindFirstChild("Mobs")
	if not mobs then
		return nil
	end
	local best: Model? = nil
	local bestDistance = ORIGIN_MATCH_STUDS
	for _, child in mobs:GetChildren() do
		if child:IsA("Model") and child ~= exclude then
			local distance = (child:GetPivot().Position - position).Magnitude
			if distance < bestDistance then
				best, bestDistance = child, distance
			end
		end
	end
	return best
end

--[ Shock ]--

type Shock = {
	part: BasePart,
	light: PointLight?,
	flicker: GameClock.Tween?,
}

local function startShock(template: BasePart, at: Vector3, scale: number, color: Color3?): Shock
	local part = template:Clone()
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CFrame = CFrame.new(at)
	for _, child in part:GetChildren() do
		if child:IsA("WeldConstraint") then
			child:Destroy()
		end
	end
	prepareEffects(part, scale, color)
	part.Parent = effectParent()

	local particles = part:FindFirstChild("Particles")
	local spikesStart = emitter(particles, "SpikesStart")
	if spikesStart then
		spikesStart:Emit(BURST_COUNT)
	end
	for _, name in { "Lightning1", "Spikes" } do
		local continuous = emitter(particles, name)
		if continuous then
			continuous.Enabled = true
		end
	end

	local light = part:FindFirstChildOfClass("PointLight")
	local flicker: GameClock.Tween? = nil
	if light then
		light.Enabled = true
		local tween = GameClock.Tween(
			light,
			TweenInfo.new(LIGHT_FLICKER_SECONDS, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, -1, true),
			{ Brightness = LIGHT_FLICKER_BRIGHTNESS }
		)
		tween:Play()
		flicker = tween
	end
	return { part = part, light = light, flicker = flicker }
end

local function endShock(shock: Shock)
	local particles = shock.part:FindFirstChild("Particles")
	for _, name in { "Lightning1", "Spikes" } do
		local continuous = emitter(particles, name)
		if continuous then
			continuous.Enabled = false
		end
	end
	local puff = emitter(particles, "Smoke")
	if puff then
		puff:Emit(1)
	end
	if shock.flicker then
		shock.flicker:Cancel()
	end
	local light = shock.light
	if light then
		GameClock.Tween(light, TweenInfo.new(LIGHT_FADE_SECONDS, Enum.EasingStyle.Linear), { Brightness = 0 }):Play()
	end
	GameClock.Debris(shock.part, CLEANUP_SECONDS)
end

--[ Public ]--

-- One link of the chain: from the jump's start (`from`, the previous
-- enemy) to `target`, which stood at `to` when the server fired.
-- `caster` picks the colour (see the header).
function ChainLightningVFXController.Play(
	_self: typeof(ChainLightningVFXController),
	from: Vector3,
	target: Model?,
	to: Vector3,
	caster: Player?
)
	local folder = assets()
	local beamTemplate = folder and folder:FindFirstChild("Beam")
	local shockTemplate = folder and folder:FindFirstChild("Shock")
	if not (beamTemplate and beamTemplate:IsA("BasePart") and shockTemplate and shockTemplate:IsA("BasePart")) then
		warn("[ChainLightningVFXController] Missing GameAssets.VFX.ChainLightning.Beam / Shock")
		return
	end

	local originAt = MobRenderController:TrackBody(mobNear(from, target), from, ANCHOR_ATTACHMENT_NAME)
	local targetAt = MobRenderController:TrackBody(target, to, ANCHOR_ATTACHMENT_NAME)
	local scale = effectScale(target)
	local color = colorFor(caster)

	local beamPart = beamTemplate:Clone()
	beamPart.Anchored = true
	beamPart.CFrame = CFrame.new(from)
	local attachment0 = beamPart:FindFirstChild("Attachment0")
	local attachment1 = beamPart:FindFirstChild("Attachment1")
	if not (attachment0 and attachment0:IsA("Attachment") and attachment1 and attachment1:IsA("Attachment")) then
		beamPart:Destroy()
		return
	end
	local beams: { Beam } = {}
	local baseTransparency: { [Beam]: NumberSequence } = {}
	for _, child in beamPart:GetChildren() do
		if child:IsA("Beam") then
			table.insert(beams, child)
			baseTransparency[child] = child.Transparency
		end
	end
	prepareEffects(beamPart, scale, color)
	attachment0.WorldCFrame = CFrame.new(from)
	attachment1.WorldCFrame = CFrame.new(from)
	beamPart.Parent = effectParent()

	local headSparks = emitter(attachment1, "Sparks")
	if headSparks then
		headSparks.Rate = HEAD_SPARK_RATE
		headSparks.Enabled = true
	end

	local travelSeconds = math.max((to - from).Magnitude / BEAM_SPEED, 1 / 60)
	local startedAt = GameClock.Now()

	task.spawn(function()
		local shock: Shock? = nil
		local shockEnded = false
		while beamPart.Parent do
			RunService.RenderStepped:Wait()
			local elapsed = GameClock.Now() - startedAt
			local origin = originAt()
			local head = targetAt()
			local progress = math.min(elapsed / travelSeconds, 1)
			attachment0.WorldCFrame = CFrame.new(origin)
			attachment1.WorldCFrame = CFrame.new(origin:Lerp(head, progress))

			if not shock and progress >= 1 then
				local ring = emitter(attachment1, "Ring")
				if ring then
					ring:Emit(1)
				end
				if headSparks then
					headSparks:Emit(BURST_COUNT)
					headSparks.Rate = HEAD_IDLE_SPARK_RATE
				end
				local embers = emitter(attachment1, "Embers")
				if embers then
					embers.Enabled = true
				end
				shock = startShock(shockTemplate, head, scale, color)
			end

			if shock and not shockEnded then
				shock.part.CFrame = CFrame.new(head)
			end

			local sinceArrival = elapsed - travelSeconds
			if shock and not shockEnded and sinceArrival >= SHOCK_SECONDS then
				shockEnded = true
				endShock(shock)
				local sparksEnd = emitter(attachment1, "SparksEnd")
				if sparksEnd then
					sparksEnd:Emit(BURST_COUNT)
				end
				if headSparks then
					headSparks.Enabled = false
				end
				local embers = emitter(attachment1, "Embers")
				if embers then
					embers.Enabled = false
				end
			end

			if shockEnded then
				local fade = math.min((sinceArrival - SHOCK_SECONDS) / BEAM_FADE_SECONDS, 1)
				for _, beam in beams do
					beam.Transparency = fadeSequence(baseTransparency[beam], fade)
				end
				if fade >= 1 then
					break
				end
			end
		end
		GameClock.Debris(beamPart, CLEANUP_SECONDS)
	end)
end

return ChainLightningVFXController
