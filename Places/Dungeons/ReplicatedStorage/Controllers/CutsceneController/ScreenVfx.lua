--!strict
--[[
	Module: Controllers/CutsceneController/ScreenVfx.lua
	Description:
	SCREEN EFFECTS for a cutscene (2026-11-10, from Susanoo's; shared with
	Domain Expansion's): parts held `distance` studs in front of the camera
	with their front face toward it, re-placed every frame right after the
	camera moves (so they stay put through the waypoint moves and the
	hand-back), emitted `at` seconds after Start (their emitters' EmitCount
	/ EmitDelay attributes, emitAttributeVFX). Only the local player's
	screen: the parts live under the camera.

	Per cue:
	  name         the part's name in the folder handed to Start.
	  at           seconds after Start.
	  distance     studs from the camera (nearer = bigger on screen).
	  emitScale    multiplies every emitter's EmitCount.
	  sustain      after its burst it keeps streaming (each emitter's own
	               Rate x streamScale, from its EmitDelay) until
	               EndSustained (the camera handed back), then tapers to
	               nothing over SUSTAIN_TAIL_SECONDS.
	  streamScale  see sustain.
	  delayShift   added to every emitter's EmitDelay (clamped at 0).
	  layer        added to every emitter's ZOffset (studs toward the
	               camera): which effect draws over which. Kept small: at
	               0.9 studs it also nudges the size a few percent.
	  openFrom     optional: the effect OPENS -- every particle's size
	               starts at this share, swells just past full and settles
	               over openSeconds (a Back ease), instead of popping in.
	  openSeconds  see openFrom.
	  warm         keep its textures warm from Start (below). Off for an
	               effect whose faint warm copy shows (2026-11-10: the
	               Sharingan's could be seen).

	An emitter directly on a part spawns anywhere in its box, so the copy
	is flattened to DEPTH and trimmed to the screen's size at its distance
	(Susanoo's flames were 2 studs deep and 4 wide: at 0.9 studs half of
	them spawned behind the camera or off screen).

	WARM-UP: preloading only fetches a texture; the GPU keeps a sharp copy
	only of what it has drawn recently and at size, and a cutscene pours
	new textures in. So from Start each effect also streams a few particles
	at full size in the same spot, WARM_TRANSPARENCY see-through, until a
	beat after its real burst (Susanoo's Sharingan came in pixelated).

	  local session = ScreenVfx.new("Susanoo")
	  session:Start(folder, cues, isCurrent)  -- at the cutscene's start
	  session:EndSustained()                  -- as the camera is handed back
	  session:StopAll()                       -- the cutscene was cut short
]]

local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local GameClock = require(ReplicatedStorage.Submodules.Core.Shared.GameClock)
local emitAttributeVFX = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.emitAttributeVFX)

export type Cue = {
	name: string,
	at: number,
	distance: number,
	emitScale: number,
	sustain: boolean,
	streamScale: number,
	delayShift: number,
	layer: number,
	warm: boolean,
	openFrom: number?,
	openSeconds: number?,
	-- Optional: every emitter's Brightness times this (2026-11-11).
	brightness: number?,
	-- Optional: at the hand-back (EndSustained) a sustained effect eases
	-- back to this distance over endDistanceSeconds (2026-11-11).
	endDistance: number?,
	endDistanceSeconds: number?,
}

-- `rates`: each emitter's authored Rate (before streamScale), for Ramp.
type Entry = {
	part: BasePart,
	bind: string,
	sustained: boolean,
	rates: { [ParticleEmitter]: number },
	-- Read every frame by its placement (it can ease).
	distance: { value: number },
	cue: Cue,
}

local SUSTAIN_TAIL_SECONDS = 0.5
local DEPTH = 0.05
local WARM_TRANSPARENCY = 0.985
local WARM_RATE = 4
local WARM_OVERLAP_SECONDS = 0.2

local ScreenVfx = {}
ScreenVfx.__index = ScreenVfx

export type Session = typeof(setmetatable({} :: { _prefix: string, _entries: { Entry }, _serial: number }, ScreenVfx))

local function facing(distance: number): CFrame?
	local camera = workspace.CurrentCamera
	if not camera then
		return nil
	end
	-- Front face (-Z) toward the camera: in front of it, turned round.
	return camera.CFrame * CFrame.new(0, 0, -distance) * CFrame.Angles(0, math.pi, 0)
end

-- How long `part`'s bursts take to play out.
local function burstSeconds(part: Instance): number
	local longest = 0
	for _, emitter in part:GetDescendants() do
		if emitter:IsA("ParticleEmitter") then
			local delay = tonumber(emitter:GetAttribute("EmitDelay")) or 0
			local loops = tonumber(emitter:GetAttribute("EmitLoopCount")) or 1
			local loopDelay = tonumber(emitter:GetAttribute("EmitLoopDelay")) or 0
			longest = math.max(longest, delay + math.max(loops - 1, 0) * loopDelay + emitter.Lifetime.Max)
		end
	end
	return longest + 0.2
end

local function emittersOf(part: Instance): { ParticleEmitter }
	local out = {}
	for _, emitter in part:GetDescendants() do
		if emitter:IsA("ParticleEmitter") then
			table.insert(out, emitter)
		end
	end
	return out
end

function ScreenVfx.new(prefix: string): Session
	return setmetatable({ _prefix = prefix, _entries = {}, _serial = 0 }, ScreenVfx)
end

function ScreenVfx._bind(self: Session, part: BasePart, distance: { value: number }): string
	self._serial += 1
	local bind = self._prefix .. "ScreenVfx" .. self._serial
	local function place()
		local frame = facing(distance.value)
		if frame then
			part.CFrame = frame
		end
	end
	place()
	part.Parent = workspace.CurrentCamera
	RunService:BindToRenderStep(bind, Enum.RenderPriority.Camera.Value + 1, place)
	return bind
end

function ScreenVfx._remove(self: Session, entry: Entry)
	local index = table.find(self._entries, entry)
	if not index then
		return
	end
	table.remove(self._entries, index)
	RunService:UnbindFromRenderStep(entry.bind)
	entry.part:Destroy()
end

function ScreenVfx._warm(self: Session, template: BasePart, distance: number, untilSeconds: number)
	local warm = template:Clone()
	warm.Name = template.Name .. "Warm"
	for _, child in warm:GetDescendants() do
		if child:IsA("ParticleEmitter") then
			child.Transparency = NumberSequence.new(WARM_TRANSPARENCY)
			child.Rate = WARM_RATE
			child.Enabled = true
		elseif child:IsA("Sound") then
			child:Destroy()
		end
	end
	local bind = self:_bind(warm, { value = distance })
	GameClock.Delay(untilSeconds + WARM_OVERLAP_SECONDS, function()
		RunService:UnbindFromRenderStep(bind)
		warm:Destroy()
	end)
end

-- Every emitter's Size (which its live particles read every frame) eased
-- from `from` of its authored size, just past it and back, over `seconds`.
function ScreenVfx._open(emitters: { ParticleEmitter }, from: number, seconds: number)
	local authored: { [ParticleEmitter]: NumberSequence } = {}
	for _, emitter in emitters do
		authored[emitter] = emitter.Size
	end
	local function apply(scale: number)
		for emitter, sequence in authored do
			local points = {}
			for _, point in sequence.Keypoints do
				table.insert(
					points,
					NumberSequenceKeypoint.new(point.Time, point.Value * scale, point.Envelope * scale)
				)
			end
			emitter.Size = NumberSequence.new(points)
		end
	end
	apply(from)
	local started = GameClock.Now()
	local connection: RBXScriptConnection
	connection = RunService.RenderStepped:Connect(function()
		local alpha = math.clamp((GameClock.Now() - started) / seconds, 0, 1)
		-- Back out: overshoots ~10% before settling at 1.
		local eased = TweenService:GetValue(alpha, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		apply(from + (1 - from) * eased)
		if alpha >= 1 then
			connection:Disconnect()
			for emitter, sequence in authored do
				emitter.Size = sequence
			end
		end
	end)
end

function ScreenVfx._play(self: Session, template: BasePart, cue: Cue)
	local part = template:Clone()
	local camera = workspace.CurrentCamera
	if camera then
		local viewport = camera.ViewportSize
		local visibleHeight = 2 * cue.distance * math.tan(math.rad(camera.FieldOfView) / 2)
		local visibleWidth = visibleHeight * viewport.X / math.max(viewport.Y, 1)
		part.Size = Vector3.new(math.min(part.Size.X, visibleWidth), math.min(part.Size.Y, visibleHeight), DEPTH)
	end
	local emitters = emittersOf(part)
	for _, emitter in emitters do
		emitter.ZOffset += cue.layer
		if cue.brightness then
			emitter.Brightness *= cue.brightness
		end
		if cue.delayShift ~= 0 then
			local delay = tonumber(emitter:GetAttribute("EmitDelay")) or 0
			emitter:SetAttribute("EmitDelay", math.max(delay + cue.delayShift, 0))
		end
		local count = tonumber(emitter:GetAttribute("EmitCount"))
		if count and cue.emitScale ~= 1 then
			emitter:SetAttribute("EmitCount", math.max(math.round(count * cue.emitScale), 1))
		end
	end
	local rates: { [ParticleEmitter]: number } = {}
	for _, emitter in emitters do
		rates[emitter] = emitter.Rate
	end
	local distance = { value = cue.distance }
	local entry: Entry = {
		part = part,
		bind = self:_bind(part, distance),
		sustained = cue.sustain,
		rates = rates,
		distance = distance,
		cue = cue,
	}
	table.insert(self._entries, entry)
	emitAttributeVFX(part)
	local openFrom = cue.openFrom
	if openFrom then
		ScreenVfx._open(emitters, openFrom, cue.openSeconds or 0.25)
	end
	if not cue.sustain then
		GameClock.Delay(burstSeconds(part), function()
			self:_remove(entry)
		end)
		return
	end
	-- The stream, each emitter from its own delay; EndSustained stops it.
	for _, emitter in emitters do
		emitter.Rate *= cue.streamScale
		GameClock.Delay(tonumber(emitter:GetAttribute("EmitDelay")) or 0, function()
			if table.find(self._entries, entry) then
				emitter.Enabled = true
			end
		end)
	end
end

-- Schedules every cue from now; `isCurrent` false at a cue's time (the
-- cutscene was stopped or replayed) skips it.
function ScreenVfx.Start(self: Session, folder: Instance, cues: { Cue }, isCurrent: () -> boolean)
	-- Fetched again in case the boot preload's copy was dropped.
	task.spawn(function()
		ContentProvider:PreloadAsync({ folder })
	end)
	for _, cue in cues do
		local template = folder:FindFirstChild(cue.name)
		if not template or not template:IsA("BasePart") then
			continue
		end
		if cue.warm then
			self:_warm(template, cue.distance, cue.at)
		end
		GameClock.Delay(cue.at, function()
			if isCurrent() then
				self:_play(template, cue)
			end
		end)
	end
end

-- The camera is handed back: the streams taper to nothing over
-- `tailSeconds` (default SUSTAIN_TAIL_SECONDS), and each part goes once its
-- last particles are gone.
-- The streams swell to `scale` x their authored Rate over `seconds` (a
-- transition building toward the hand-back, 2026-11-11), with one more of
-- each part's bursts when `burst`.
function ScreenVfx.RampSustained(self: Session, scale: number, seconds: number, burst: boolean?)
	for _, entry in self._entries do
		if not entry.sustained then
			continue
		end
		for emitter, rate in entry.rates do
			GameClock.Tween(emitter, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				Rate = rate * scale,
			}):Play()
		end
		if burst then
			emitAttributeVFX(entry.part)
		end
	end
end

function ScreenVfx.EndSustained(self: Session, tailSeconds: number?)
	local tail = tailSeconds or SUSTAIN_TAIL_SECONDS
	for _, entry in self._entries do
		if not entry.sustained then
			continue
		end
		entry.sustained = false
		local endDistance = entry.cue.endDistance
		if endDistance then
			local from = entry.distance.value
			local seconds = math.max(entry.cue.endDistanceSeconds or tail, 0.01)
			local started = GameClock.Now()
			local easing: RBXScriptConnection
			easing = RunService.RenderStepped:Connect(function()
				local alpha = math.clamp((GameClock.Now() - started) / seconds, 0, 1)
				local eased = TweenService:GetValue(alpha, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
				entry.distance.value = from + (endDistance - from) * eased
				if alpha >= 1 or not table.find(self._entries, entry) then
					easing:Disconnect()
				end
			end)
		end
		local emitters = emittersOf(entry.part)
		for _, emitter in emitters do
			GameClock.Tween(emitter, TweenInfo.new(tail, Enum.EasingStyle.Quad), { Rate = 0 }):Play()
		end
		GameClock.Delay(tail, function()
			if not table.find(self._entries, entry) then
				return
			end
			local longest = 0
			for _, emitter in emitters do
				emitter.Enabled = false
				longest = math.max(longest, emitter.Lifetime.Max)
			end
			GameClock.Delay(longest + 0.2, function()
				self:_remove(entry)
			end)
		end)
	end
end

-- Everything up now goes at once.
function ScreenVfx.StopAll(self: Session)
	for index = #self._entries, 1, -1 do
		self:_remove(self._entries[index])
	end
end

return ScreenVfx
