--!strict
--[[
	Module: MobRenderController.lua
	Description:
	Client half of the CLIENT-SIMULATED mob (server half: MobSimService).

	The server keeps an invisible, anchored proxy per sim mob (hitbox parts
	plus a dormant Humanoid holding health) and streams its movement as
	legs (Mob.blink MobMove). This controller gives every proxy a body:
	  * a local clone of the real rig (the proxy's MobTemplate under
	    GameAssets.Mobs), parented UNDER the proxy, so everything that
	    walks a mob model's descendants (the despawn dissolve, the cutscene
	    dim, the MobHighlight) covers it, and it dies with the proxy
	  * walked every frame along the current leg on the server clock
	    (Shared/Functions/Mob/mobPath), with the proxy's replicated CFrame
	    as the correction: a leg that was lost or drifted gives way to
	    following the proxy
	  * idle / run / damaged / attack animations on a local Animator, the
	    lunge, the face, the death sound and a local ragdoll
	  * the MobHighlight CharacterHighlightController drives, and the
	    overhead health bar MobController tweens (parented on the proxy's
	    Head, drawn on the rig's)
	Nothing here replicates.
]]

--[ Roblox Services ]--

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

--[ Imports ]--

local MobNetwork = require(ReplicatedStorage.Submodules.Core.Source.Network.Mob)
local Combat = require(ReplicatedStorage.Submodules.Core.Source.Network.Combat)
local MobData = require(ReplicatedStorage.Submodules.Core.Shared.Data.MobData)
local MobFadeData = require(ReplicatedStorage.Submodules.Core.Shared.Data.MobFadeData)
local MobFaceData = require(ReplicatedStorage.Submodules.Core.Shared.Data.MobFaceData)
local CorruptionData = require(ReplicatedStorage.Submodules.Core.Shared.Data.CorruptionData)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local CollisionGroups = require(ReplicatedStorage.Submodules.Core.Shared.Enums.CollisionGroups)
local mobPath = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Mob.mobPath)
local attachCorruptVFX = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Mob.attachCorruptVFX)
local fadeSubtree = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.fadeSubtree)
local Log = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Log)

local MobRenderController = {
	Name = "MobRenderController",
}

--[ Constants ]--

local MOBS_FOLDER = workspace.IgnoreInstances.Mobs
local RIG_NAME = "Rig"
local HEALTH_INTERFACE_NAME = "HealthInterface"
-- The bar inside it, and its authored height scale (MobController's names).
local HEALTH_BAR_INNER_FRAME_NAME = "InnerFrame"
local HEALTH_BAR_NAME = "RedBar"
local HEALTH_BAR_HEIGHT_SCALE = 1.3
local HIGHLIGHT_NAME = "MobHighlight"

-- Rig parts the proxy already provides; the local copy drops them.
local PROXY_ONLY_PARTS: { [string]: boolean } = { RaycastHitbox = true, MobHitbox = true }

-- A fresh leg starts where the server says the mob is, which can sit a
-- little off where this client drew it -- or, for a knockback, a few
-- studs away on purpose; the gap is carried as an offset
-- that decays at this rate (1/s) instead of snapping. A gap wider than
-- MAX_BLEND_STUDS snaps.
local OFFSET_DECAY_RATE = 10
local MAX_BLEND_STUDS = 8
-- A KNOCKBACK leg (MobSimService: it starts ahead of now, after the
-- stagger) slides its gap out on a timed sine ease-out instead: the
-- decay above puts ~63% of a push on screen in the first 0.1 s, which
-- reads as a snap; this starts at about half that speed and settles.
-- A leg counts as a knockback when it starts more than
-- KNOCKBACK_LEAD_SECONDS ahead (ordinary legs start at or before now).
local KNOCKBACK_SLIDE_SECONDS = 0.3
local KNOCKBACK_LEAD_SECONDS = 0.03
-- How fast the drawn facing turns toward the leg's (1/s).
local TURN_RATE = 14
-- With no usable leg the rig eases toward the proxy's replicated CFrame.
local FOLLOW_RATE = 12
-- Correction: the proxy is the server's truth. Near players the server
-- moves it every frame; further out only on its thinks (up to
-- CORRECTION_STALE_SECONDS apart), so a walking mob's proxy can
-- legitimately trail the leg by speed x that, plus latency. A leg
-- that keeps this client more than CORRECTION_STUDS past that allowance
-- from the proxy for CORRECTION_SECONDS is dropped.
local CORRECTION_STUDS = 6
local CORRECTION_STALE_SECONDS = 0.5
local CORRECTION_SECONDS = 0.4
-- A leg that arrives for a proxy this client cannot see yet waits this long.
local PENDING_MOVE_SECONDS = 10
-- The cosmetic lunge (MobController's number).
local LUNGE_SECONDS = 0.4

-- Death: the push off the killer and the forward topple (MobBase's
-- impulse and knockback, applied to the local copy).
local DEATH_IMPULSE_PER_MASS = 200 * 0.35
local DEATH_KNOCKBACK_PER_MASS = 2.5

--[ Types ]--

type Lunge = {
	startCFrame: CFrame,
	goalCFrame: CFrame,
	startedAt: number,
	serverTime: number,
}

type Entry = {
	id: number,
	proxy: Model,
	proxyRoot: BasePart,
	rootOffset: number,
	rig: Model?,
	rigRoot: BasePart?,
	animator: Animator?,
	tracks: { [string]: AnimationTrack },
	attackTracks: { [number]: AnimationTrack },
	move: mobPath.Move?,
	offset: Vector3,
	-- A knockback slide in progress: the gap it started from and when
	-- (os.clock()); drives `offset` while set (KNOCKBACK_SLIDE_SECONDS).
	slideGap: Vector3?,
	slideStartedAt: number?,
	position: Vector3?,
	yaw: number,
	running: boolean?,
	divergedFor: number,
	lunge: Lunge?,
	dead: boolean,
	lastHealth: number,
	connections: { RBXScriptConnection },
}

--[ State ]--

MobRenderController._entries = {} :: { [number]: Entry }
MobRenderController._byProxy = {} :: { [Model]: Entry }
MobRenderController._pendingMoves = {} :: { [number]: { move: mobPath.Move, receivedAt: number } }
MobRenderController._warnedTemplates = {} :: { [string]: boolean }

--[ Helpers ]--

local function lerpAngle(from: number, to: number, alpha: number): number
	local delta = (to - from + math.pi) % (2 * math.pi) - math.pi
	return from + delta * alpha
end

local function moveFromPayload(payload): mobPath.Move
	return mobPath.new(payload.StartTime, payload.Speed, payload.Start, payload.Points, payload.Yaw)
end

function MobRenderController._findTemplate(self: typeof(MobRenderController), path: string): Model?
	local node: Instance? = ReplicatedStorage.GameAssets.Mobs
	for _, segment in string.split(path, "/") do
		node = node and node:FindFirstChild(segment)
	end
	if node and node:IsA("Model") then
		return node
	end
	if not self._warnedTemplates[path] then
		self._warnedTemplates[path] = true
		warn("[MobRenderController] No mob template at GameAssets.Mobs/" .. path)
	end
	return nil
end

--[ Rig ]--

-- The local copy of the real rig: anchored at the root, every other part
-- hanging off it by its joints, nothing collidable or queryable, no tags
-- (it must never read as a second mob), the proxy-only parts dropped.
function MobRenderController._buildRig(self: typeof(MobRenderController), entry: Entry)
	local proxy = entry.proxy
	local templatePath = proxy:GetAttribute(Attributes.MobTemplate)
	if type(templatePath) ~= "string" then
		return
	end
	local template = self:_findTemplate(templatePath)
	if not template then
		return
	end

	local rig = template:Clone()
	rig.Name = RIG_NAME
	for _, tag in rig:GetTags() do
		rig:RemoveTag(tag)
	end
	for name in PROXY_ONLY_PARTS do
		local part = rig:FindFirstChild(name)
		if part then
			part:Destroy()
		end
	end

	local rigRoot = rig:FindFirstChild("HumanoidRootPart")
	if not rigRoot or not rigRoot:IsA("BasePart") then
		rig:Destroy()
		return
	end
	for _, descendant in rig:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = descendant == rigRoot
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
		end
	end
	rig.PrimaryPart = rigRoot

	local humanoid = rig:FindFirstChildOfClass("Humanoid")
	local animator: Animator? = nil
	if humanoid then
		humanoid.EvaluateStateMachine = false
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
		animator = humanoid:FindFirstChildOfClass("Animator")
		if not animator then
			local created = Instance.new("Animator")
			created.Parent = humanoid
			animator = created
		end
	end

	local head = rig:FindFirstChild("Head")
	local face = head and head:FindFirstChild("Face")
	if face and face:IsA("Decal") then
		face.Texture = MobFaceData.Alive[entry.id % #MobFaceData.Alive + 1]
	end

	-- Born invisible, bloomed in (MobBase's spawn fade, run locally).
	for _, descendant in rig:GetDescendants() do
		if descendant:IsA("BasePart") and not MobFadeData.SpawnFadeExcludedParts[descendant.Name] then
			descendant.Transparency = 1
		end
	end

	local cframe = entry.proxyRoot.CFrame
	rigRoot.CFrame = cframe
	entry.position = cframe.Position
	local look = cframe.LookVector
	entry.yaw = mobPath.yawFromDirection(look) or 0
	rig.Parent = proxy

	entry.rig = rig
	entry.rigRoot = rigRoot
	entry.animator = animator

	fadeSubtree(rig, {
		targetTransparency = 0,
		tweenInfo = TweenInfo.new(MobFadeData.SpawnFadeSeconds, MobFadeData.EasingStyle, MobFadeData.EasingDirection),
		skip = function(part)
			return MobFadeData.SpawnFadeExcludedParts[part.Name] == true
		end,
	})

	self:_loadAnimations(entry)
	self:_dressProxy(entry, head)
	if proxy:GetAttribute(Attributes.Corrupted) == true then
		attachCorruptVFX(rig, rigRoot)
	end

	-- Status emitters (StatusConditionService clones them into the mob's
	-- root) ride the rig's root here instead: the proxy root only moves
	-- when the server thinks, so world-space particles would trail the body
	-- in steps. A local reparent; the server's Destroy still removes them.
	local function adoptEmitter(child: Instance)
		if child:IsA("ParticleEmitter") and rig.Parent then
			child.Parent = rigRoot
		end
	end
	for _, child in entry.proxyRoot:GetChildren() do
		adoptEmitter(child)
	end
	table.insert(entry.connections, entry.proxyRoot.ChildAdded:Connect(adoptEmitter))
end

function MobRenderController._loadAnimations(_self: typeof(MobRenderController), entry: Entry)
	local animator = entry.animator
	local data = MobData[entry.proxy.Name]
	if not animator or not data then
		return
	end
	local locomotion: { [string]: Animation? } = { idle = data.idle, run = data.run, damaged = data.damaged }
	for key, animation in locomotion do
		if animation then
			entry.tracks[key] = animator:LoadAnimation(animation)
		end
	end
	for index, attack in data.genericAttacks or {} do
		if attack.animation then
			entry.attackTracks[index] = animator:LoadAnimation(attack.animation)
		end
	end
	local idle = entry.tracks.idle
	if idle then
		idle:Play()
	end
	entry.running = false
end

-- The two client-side pieces other controllers look for on the proxy:
-- the MobHighlight (CharacterHighlightController waits for it, and with
-- no Adornee it covers the rig underneath) and the overhead bar
-- (MobController tweens it; it lives on the proxy's Head and is drawn on
-- the rig's).
function MobRenderController._dressProxy(_self: typeof(MobRenderController), entry: Entry, rigHead: Instance?)
	local proxy = entry.proxy
	if not proxy:FindFirstChild(HIGHLIGHT_NAME) then
		local highlight = Instance.new("Highlight")
		highlight.Name = HIGHLIGHT_NAME
		highlight.FillColor = Color3.fromRGB(255, 255, 255)
		highlight.FillTransparency = 1
		highlight.OutlineTransparency = 1
		highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		highlight.Parent = proxy
	end

	local proxyHead = proxy:FindFirstChild("Head")
	if proxyHead and not proxyHead:FindFirstChild(HEALTH_INTERFACE_NAME) then
		local healthInterface = ReplicatedStorage.GameAssets.BillboardGuis.HealthInterface:Clone() :: BillboardGui
		if rigHead and rigHead:IsA("BasePart") then
			healthInterface.Adornee = rigHead
		end
		healthInterface.Enabled = false
		-- Sized to the live health now: MobController sizes the bar when it
		-- first sees the mob, which can be before this billboard exists, and
		-- otherwise only on the next hit (a late joiner saw a full bar).
		local humanoid = proxy:FindFirstChildOfClass("Humanoid")
		local inner = healthInterface:FindFirstChild(HEALTH_BAR_INNER_FRAME_NAME)
		local bar = inner and inner:FindFirstChild(HEALTH_BAR_NAME)
		if humanoid and bar and bar:IsA("GuiObject") then
			local ratio = if humanoid.MaxHealth > 0 then humanoid.Health / humanoid.MaxHealth else 0
			bar.Size = UDim2.fromScale(math.clamp(ratio, 0, 1), HEALTH_BAR_HEIGHT_SCALE)
			healthInterface.Enabled = ratio < 1
		end
		healthInterface.Parent = proxyHead
	end
end

function MobRenderController._healthInterface(_self: typeof(MobRenderController), entry: Entry): BillboardGui?
	local proxyHead = entry.proxy:FindFirstChild("Head")
	local interface = proxyHead and proxyHead:FindFirstChild(HEALTH_INTERFACE_NAME)
	return if interface and interface:IsA("BillboardGui") then interface else nil
end

--[ Tracking ]--

function MobRenderController._track(self: typeof(MobRenderController), proxy: Instance)
	if not proxy:IsA("Model") or self._byProxy[proxy] then
		return
	end
	local id = proxy:GetAttribute(Attributes.MobSimId)
	if type(id) ~= "number" then
		return
	end
	local root = proxy.PrimaryPart or proxy:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return
	end
	local offsetAttribute = proxy:GetAttribute(Attributes.MobRootOffset)
	local humanoid = proxy:FindFirstChildOfClass("Humanoid")

	local entry: Entry = {
		id = id,
		proxy = proxy,
		proxyRoot = root,
		rootOffset = if type(offsetAttribute) == "number" then offsetAttribute else 3,
		rig = nil,
		rigRoot = nil,
		animator = nil,
		tracks = {},
		attackTracks = {},
		move = nil,
		offset = Vector3.zero,
		position = nil,
		yaw = 0,
		running = nil,
		divergedFor = 0,
		lunge = nil,
		dead = false,
		lastHealth = if humanoid then humanoid.Health else 0,
		connections = {},
	}

	-- A proxy that streams back in after its mob died has no body to draw.
	if humanoid and humanoid.Health <= 0 then
		return
	end

	-- An older entry for the same id (the proxy streamed out and back in
	-- as a new instance) gives way.
	local stale = self._entries[id]
	if stale then
		self:_untrack(stale)
	end
	self._entries[id] = entry
	self._byProxy[proxy] = entry

	local pending = self._pendingMoves[id]
	if pending then
		self._pendingMoves[id] = nil
		entry.move = pending.move
	end

	self:_buildRig(entry)

	if humanoid then
		table.insert(
			entry.connections,
			humanoid.HealthChanged:Connect(function(health: number)
				self:_onHealthChanged(entry, health)
			end)
		)
	end
	table.insert(
		entry.connections,
		proxy.AncestryChanged:Connect(function()
			if not proxy:IsDescendantOf(workspace) then
				self:_untrack(entry)
			end
		end)
	)
end

function MobRenderController._untrack(self: typeof(MobRenderController), entry: Entry)
	if self._entries[entry.id] == entry then
		self._entries[entry.id] = nil
	end
	if self._byProxy[entry.proxy] == entry then
		self._byProxy[entry.proxy] = nil
	end
	for _, connection in entry.connections do
		connection:Disconnect()
	end
	table.clear(entry.connections)

	-- The rig goes with the entry (a replaced entry must not leave a frozen
	-- second body behind). Status emitters it adopted go back to the proxy
	-- root first, while the proxy is still in the world.
	local rig, rigRoot = entry.rig, entry.rigRoot
	if rig then
		if rigRoot and entry.proxy:IsDescendantOf(workspace) then
			for _, child in rigRoot:GetChildren() do
				if child:IsA("ParticleEmitter") then
					child.Parent = entry.proxyRoot
				end
			end
		end
		rig:Destroy()
		entry.rig = nil
		entry.rigRoot = nil
	end
end

--[ Reactions ]--

function MobRenderController._onHealthChanged(self: typeof(MobRenderController), entry: Entry, health: number)
	local wasHealth = entry.lastHealth
	entry.lastHealth = health
	if health >= wasHealth or entry.dead then
		return
	end
	local interface = self:_healthInterface(entry)
	if interface and not interface.Enabled and health > 0 then
		interface.Enabled = true
	end
	-- The flinch, unless the mob is mid-swing (SuperArmor), as MobBase did.
	if health > 0 and entry.proxy:GetAttribute(Attributes.SuperArmor) ~= true then
		local damaged = entry.tracks.damaged
		if damaged then
			damaged:Play()
		end
	end
end

function MobRenderController._onMove(self: typeof(MobRenderController), payload)
	local move = moveFromPayload(payload)
	local entry = self._entries[payload.Id]
	if not entry then
		local pending = self._pendingMoves[payload.Id]
		if not pending or pending.move.startTime <= move.startTime then
			self._pendingMoves[payload.Id] = { move = move, receivedAt = os.clock() }
		end
		return
	end
	-- Unreliable: an older leg can arrive after a newer one.
	local current = entry.move
	if current and move.startTime < current.startTime then
		return
	end

	-- Carry the gap between where this client drew the mob and where the
	-- new leg says it is, and let it decay (no snap on every new leg).
	local position = entry.position
	if position then
		local now = workspace:GetServerTimeNow()
		local ground = mobPath.sample(move, now)
		local gap = position - (ground + Vector3.new(0, entry.rootOffset, 0))
		entry.offset = if gap.Magnitude <= MAX_BLEND_STUDS then gap else Vector3.zero
		if move.startTime > now + KNOCKBACK_LEAD_SECONDS and entry.offset ~= Vector3.zero then
			entry.slideGap = entry.offset
			entry.slideStartedAt = os.clock()
		else
			entry.slideGap = nil
			entry.slideStartedAt = nil
		end
	end
	entry.move = move
	entry.divergedFor = 0
	local lunge = entry.lunge
	if lunge and move.startTime >= lunge.serverTime then
		entry.lunge = nil
	end
end

function MobRenderController._onAction(self: typeof(MobRenderController), payload)
	local entry = self._entries[payload.Id]
	if not entry then
		return
	end
	if payload.Kind == "Attack" then
		-- The swing replaces locomotion (MobBase stopped every non-attack
		-- track): no legs running under it. Cleared so the next frame after
		-- the attack picks run or idle afresh.
		for _, key in { "run", "idle" } do
			local locomotion = entry.tracks[key]
			if locomotion then
				locomotion:Stop()
			end
		end
		entry.running = nil
		local track = entry.attackTracks[payload.AttackIndex]
		if track then
			track:Play()
		end
	elseif payload.Kind == "Death" then
		self:_die(entry, payload.Direction)
	end
end

function MobRenderController._onLunge(
	self: typeof(MobRenderController),
	payload: { Mob: Model?, StartCFrame: CFrame, GoalCFrame: CFrame, ServerTime: number }
)
	local proxy = payload.Mob
	local entry = proxy and self._byProxy[proxy]
	if not entry or entry.dead then
		return
	end
	entry.slideGap = nil
	entry.slideStartedAt = nil
	entry.lunge = {
		startCFrame = payload.StartCFrame,
		goalCFrame = payload.GoalCFrame,
		startedAt = os.clock(),
		serverTime = payload.ServerTime,
	}
	entry.offset = Vector3.zero
end

-- The local ragdoll: every Motor6D becomes a ball socket at the same joint,
-- the root lets go, and the body takes MobBase's death push.
function MobRenderController._die(self: typeof(MobRenderController), entry: Entry, direction: Vector3?)
	if entry.dead then
		return
	end
	entry.dead = true
	entry.lunge = nil

	local interface = self:_healthInterface(entry)
	if interface then
		interface.Enabled = false
	end
	local highlight = entry.proxy:FindFirstChild(HIGHLIGHT_NAME)
	if highlight then
		highlight:Destroy()
	end

	local rig, rigRoot = entry.rig, entry.rigRoot
	if not rig or not rigRoot then
		return
	end
	local animator = entry.animator
	if animator then
		for _, track in animator:GetPlayingAnimationTracks() do
			track:Stop(0)
		end
	end

	local head = rig:FindFirstChild("Head")
	local face = head and head:FindFirstChild("Face")
	if face and face:IsA("Decal") then
		face.Texture = MobFaceData.Dead
	end

	-- A corrupted corpse stops burning.
	local corruption = rig:FindFirstChild(CorruptionData.VFXName)
	if corruption then
		for _, emitter in corruption:GetDescendants() do
			if emitter:IsA("ParticleEmitter") then
				emitter.Enabled = false
			end
		end
	end

	local data = MobData[entry.proxy.Name]
	if data and data.deathSound then
		local sound = (data.deathSound :: Sound):Clone()
		sound.Parent = rigRoot
		sound:Play()
	end

	for _, joint in rig:GetDescendants() do
		if joint:IsA("Motor6D") and joint.Part0 and joint.Part1 then
			local attachment0 = Instance.new("Attachment")
			attachment0.CFrame = joint.C0
			attachment0.Parent = joint.Part0
			local attachment1 = Instance.new("Attachment")
			attachment1.CFrame = joint.C1
			attachment1.Parent = joint.Part1
			local socket = Instance.new("BallSocketConstraint")
			socket.Attachment0 = attachment0
			socket.Attachment1 = attachment1
			socket.LimitsEnabled = true
			socket.TwistLimitsEnabled = true
			socket.Parent = joint.Parent
			joint.Enabled = false
		end
	end
	-- The body's limbs collide as a ragdoll; the corruption aura's parts
	-- (welded on, massless) stay out of the physics.
	local aura = rig:FindFirstChild(CorruptionData.VFXName)
	for _, part in rig:GetDescendants() do
		if part:IsA("BasePart") and not (aura and part:IsDescendantOf(aura)) then
			part.CollisionGroup = CollisionGroups.Ragdoll
			part.CanCollide = part ~= rigRoot
		end
	end
	rigRoot.Anchored = false

	local mass = rigRoot.AssemblyMass
	if direction then
		rigRoot:ApplyImpulse((direction + Vector3.yAxis) * mass * DEATH_IMPULSE_PER_MASS)
	end
	rigRoot:ApplyImpulse(-rigRoot.CFrame.LookVector * (DEATH_KNOCKBACK_PER_MASS * mass))
end

--[ Per frame ]--

-- Plays run or idle off whether the drawn mob is walking; an attack or
-- flinch track plays over either (MobBase's Running handler).
local function setRunning(entry: Entry, running: boolean)
	if entry.running == running then
		return
	end
	entry.running = running
	local stop = if running then entry.tracks.idle else entry.tracks.run
	local play = if running then entry.tracks.run else entry.tracks.idle
	if stop then
		stop:Stop()
	end
	if play then
		play:Play()
	end
end

local movedParts: { BasePart } = {}
local movedCFrames: { CFrame } = {}

function MobRenderController._step(self: typeof(MobRenderController), dt: number)
	local now = workspace:GetServerTimeNow()
	local clock = os.clock()
	local offsetKeep = math.exp(-OFFSET_DECAY_RATE * dt)
	local turnAlpha = 1 - math.exp(-TURN_RATE * dt)
	local followAlpha = 1 - math.exp(-FOLLOW_RATE * dt)

	for _, entry in self._entries do
		local rigRoot = entry.rigRoot
		if entry.dead or not rigRoot then
			continue
		end
		local slideGap, slideStartedAt = entry.slideGap, entry.slideStartedAt
		if slideGap and slideStartedAt then
			local alpha = math.min((clock - slideStartedAt) / KNOCKBACK_SLIDE_SECONDS, 1)
			entry.offset = slideGap * (1 - math.sin(alpha * math.pi / 2))
			if alpha >= 1 then
				entry.slideGap = nil
				entry.slideStartedAt = nil
			end
		end
		local proxyCFrame = entry.proxyRoot.CFrame
		local position: Vector3
		local targetYaw: number
		local running = false

		local lunge = entry.lunge
		if lunge then
			local alpha = math.clamp((clock - lunge.startedAt) / LUNGE_SECONDS, 0, 1)
			local eased = 1 - (1 - alpha) ^ 3
			local cframe = lunge.startCFrame:Lerp(lunge.goalCFrame, eased)
			position = cframe.Position
			targetYaw = mobPath.yawFromDirection(lunge.startCFrame.LookVector) or entry.yaw
		else
			local move = entry.move
			if move then
				local ground, yaw, moving = mobPath.sample(move, now)
				position = ground + Vector3.new(0, entry.rootOffset, 0) + entry.offset
				targetYaw = yaw
				-- A leg that starts ahead of now is a knockback's stagger hold
				-- (MobSimService): the mob stands while it slides, not runs.
				running = moving and now >= move.startTime

				local flatGap = position - proxyCFrame.Position
				local allowance = CORRECTION_STUDS + move.speed * CORRECTION_STALE_SECONDS
				if Vector3.new(flatGap.X, 0, flatGap.Z).Magnitude > allowance then
					entry.divergedFor += dt
					if entry.divergedFor > CORRECTION_SECONDS then
						Log.debug("[MobRenderController] Mob " .. entry.id .. " drifted; following the proxy")
						entry.move = nil
					end
				else
					entry.divergedFor = 0
				end
			else
				local previous = entry.position or proxyCFrame.Position
				position = previous:Lerp(proxyCFrame.Position, followAlpha)
				targetYaw = mobPath.yawFromDirection(proxyCFrame.LookVector) or entry.yaw
				running = (proxyCFrame.Position - previous).Magnitude > 0.05
			end
		end

		if not entry.slideGap then
			entry.offset *= offsetKeep
		end
		entry.yaw = lerpAngle(entry.yaw, targetYaw, turnAlpha)
		entry.position = position

		-- Locomotion tracks hold still mid-swing (MobIsAttacking).
		if entry.proxy:GetAttribute(Attributes.MobIsAttacking) ~= true then
			setRunning(entry, running)
		end

		table.insert(movedParts, rigRoot)
		table.insert(movedCFrames, CFrame.new(position) * CFrame.Angles(0, entry.yaw, 0))
	end

	if #movedParts > 0 then
		workspace:BulkMoveTo(movedParts, movedCFrames, Enum.BulkMoveMode.FireCFrameChanged)
		table.clear(movedParts)
		table.clear(movedCFrames)
	end

	-- Legs for proxies that never showed up.
	for id, pending in self._pendingMoves do
		if clock - pending.receivedAt > PENDING_MOVE_SECONDS then
			self._pendingMoves[id] = nil
		end
	end
end

--[ Lifecycle ]--

function MobRenderController.Start(self: typeof(MobRenderController))
	MobNetwork.MobMove.On(function(payload)
		self:_onMove(payload)
	end)
	MobNetwork.MobAction.On(function(payload)
		self:_onAction(payload)
	end)
	Combat.MobLunge.On(function(payload)
		self:_onLunge(payload)
	end)

	for _, proxy in MOBS_FOLDER:GetChildren() do
		self:_track(proxy)
	end
	MOBS_FOLDER.ChildAdded:Connect(function(proxy: Instance)
		self:_track(proxy)
	end)

	RunService.RenderStepped:Connect(function(dt: number)
		self:_step(dt)
	end)
end

return MobRenderController
