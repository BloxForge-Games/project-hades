--!strict
--[[
	Module: LobbyNpcLifeController.lua
	Description:
	Brings the hub's NPCs to life on this client (2026-11-03):

	  IDLE   each NPC under workspace.IgnoreInstances.NPCs plays the
	         PLAYERS' idle on loop (the player Animate script's "idle"),
	         not the stock one its own Animate script carries.
	  GLOW   within HIGHLIGHT_STUDS the NPC gets a soft warm outline and
	         a faint glow (a client-side Highlight), faded in and out.
	  LOOK   while the local player is within LOOK_STUDS, the NPC turns
	         toward them, eased: the torso a little (TORSO_SHARE), the head
	         the rest. It turns at most LOOK_MAX_YAW either
	         way (a half circle in all), and once the player is behind
	         that, the head eases back to straight ahead; walk round to its
	         other side and it picks the player up again. The head also
	         tips up or down toward them, up to LOOK_MAX_PITCH.

	The hub rigs are authored with EVERY part anchored, and an anchored
	part ignores its joints (no idle, no head turn); on this client the
	parts jointed to the root are unanchored, the root alone kept anchored
	(loosenRig). Client-only and local: the server's rig is never touched,
	so nothing replicates. The head turn writes the Neck's C0 from the rig's own
	resting C0, so the idle (which drives the Neck's Transform) still plays
	under it.
]]

--[ Roblox Services ]--

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

--[ Constants ]--

local IGNORE_INSTANCES_NAME = "IgnoreInstances"
local NPC_FOLDER_NAME = "NPCs"
local RIG_WAIT_SECONDS = 10

-- The plain R6 idle, only if the players' idle cannot be found.
local DEFAULT_IDLE_ID = "rbxassetid://180435571"

-- How close the player must be for an NPC to look (studs).
local LOOK_STUDS = 18
-- The furthest the head turns either side of straight ahead; past it the
-- player is behind and the head returns forward.
local LOOK_MAX_YAW = math.rad(90)
-- The furthest the head tips up or down.
local LOOK_MAX_PITCH = math.rad(25)
-- How fast the head eases toward its target (per second; higher is
-- snappier).
local LOOK_EASE = 6
-- How much of the turn the torso takes (the root joint); the head (the
-- neck) takes the rest, so the face still points at the player
-- (2026-11-03).
local TORSO_SHARE = 0.3
-- The torso's own, gentler ease (per second; LOOK_EASE is the head's), so
-- the body swings round slowly while the head keeps up (2026-11-03).
local TORSO_EASE = 2

-- A soft highlight while the player is near (2026-11-03): within
-- HIGHLIGHT_STUDS (a little past the talk prompt's 8) a warm outline and
-- a faint glow fade in, and fade out on the way off.
local HIGHLIGHT_STUDS = 12
local HIGHLIGHT_OUTLINE_COLOR = Color3.fromRGB(255, 226, 150)
local HIGHLIGHT_FILL_COLOR = Color3.fromRGB(255, 240, 200)
local HIGHLIGHT_OUTLINE_TRANSPARENCY = 0.35
local HIGHLIGHT_FILL_TRANSPARENCY = 0.88
local HIGHLIGHT_TWEEN = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

--[ Types ]--

type NpcState = {
	model: Model,
	root: BasePart,
	torso: BasePart,
	neck: Motor6D,
	restC0: CFrame,
	rootJoint: Motor6D?,
	rootRestC0: CFrame,
	yaw: number,
	pitch: number,
	torsoYaw: number,
	highlight: Highlight,
	highlighted: boolean,
}

--[ Module ]--

local LobbyNpcLifeController = {
	Name = "LobbyNpcLifeController",
	_npcs = {} :: { [Model]: NpcState },
}

--[ Private ]--

-- The idle the PLAYERS use (2026-11-03): the "idle" Animation of the
-- player's own Animate script -- the local character's, or the one
-- StarterCharacterScripts hands out -- so the NPCs idle like everyone
-- else. The NPC rigs' own Animate scripts carry Roblox's stock idle, which
-- is not the game's. The plain R6 idle only if neither can be found.
local function animateIdle(animate: Instance?): Animation?
	local idle = animate and animate:FindFirstChild("idle")
	if idle then
		for _, child in idle:GetChildren() do
			if child:IsA("Animation") and child.AnimationId ~= "" then
				return child
			end
		end
	end
	return nil
end

local function idleAnimation(): Animation
	local character = Players.LocalPlayer.Character
	local starter = game:GetService("StarterPlayer"):FindFirstChild("StarterCharacterScripts")
	local found = animateIdle(character and character:FindFirstChild("Animate"))
		or animateIdle(starter and starter:FindFirstChild("Animate"))
	if found then
		return found
	end
	local fallback = Instance.new("Animation")
	fallback.AnimationId = DEFAULT_IDLE_ID
	return fallback
end

-- Keeps only the root anchored, so the joints (the idle's and the head
-- turn's) can move the limbs. Only parts jointed to the root are freed:
-- anything else in the model stays anchored where it was placed.
local function loosenRig(model: Model)
	local root = model:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return
	end
	root.Anchored = true
	for _, part in root:GetConnectedParts(true) do
		if part ~= root then
			part.Anchored = false
		end
	end
end

local function playIdle(humanoid: Humanoid)
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		local created = Instance.new("Animator")
		created.Parent = humanoid
		animator = created
	end
	local ok, track = pcall(function()
		return (animator :: Animator):LoadAnimation(idleAnimation())
	end)
	if ok and track then
		track.Looped = true
		track.Priority = Enum.AnimationPriority.Idle
		track:Play()
	end
end

-- The NPC's highlight, hidden until the player comes near (client only).
local function makeHighlight(model: Model): Highlight
	local highlight = Instance.new("Highlight")
	highlight.Name = "NearHighlight"
	highlight.Adornee = model
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.OutlineColor = HIGHLIGHT_OUTLINE_COLOR
	highlight.FillColor = HIGHLIGHT_FILL_COLOR
	highlight.OutlineTransparency = 1
	highlight.FillTransparency = 1
	highlight.Parent = model
	return highlight
end

function LobbyNpcLifeController._addNpc(self: typeof(LobbyNpcLifeController), model: Model)
	if self._npcs[model] then
		return
	end
	local humanoid = model:WaitForChild("Humanoid", RIG_WAIT_SECONDS)
	local torso = model:WaitForChild("Torso", RIG_WAIT_SECONDS)
	if not humanoid or not humanoid:IsA("Humanoid") or not torso or not torso:IsA("BasePart") then
		return
	end
	local neck = torso:WaitForChild("Neck", RIG_WAIT_SECONDS)
	if not neck or not neck:IsA("Motor6D") then
		return
	end
	local root = model:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return
	end
	local rootJoint = root:FindFirstChild("RootJoint")
	local rootMotor = if rootJoint and rootJoint:IsA("Motor6D") then rootJoint else nil
	loosenRig(model)
	playIdle(humanoid)
	self._npcs[model] = {
		model = model,
		root = root,
		torso = torso,
		neck = neck,
		restC0 = neck.C0,
		rootJoint = rootMotor,
		rootRestC0 = if rootMotor then rootMotor.C0 else CFrame.new(),
		yaw = 0,
		pitch = 0,
		torsoYaw = 0,
		highlight = makeHighlight(model),
		highlighted = false,
	}
	model.AncestryChanged:Connect(function()
		if not model:IsDescendantOf(workspace) then
			self._npcs[model] = nil
		end
	end)
end

-- Fades the NPC's highlight in or out.
local function setHighlighted(state: NpcState, on: boolean)
	if state.highlighted == on then
		return
	end
	state.highlighted = on
	TweenService:Create(state.highlight, HIGHLIGHT_TWEEN, {
		OutlineTransparency = if on then HIGHLIGHT_OUTLINE_TRANSPARENCY else 1,
		FillTransparency = if on then HIGHLIGHT_FILL_TRANSPARENCY else 1,
	}):Play()
end

-- The yaw and pitch the NPC turns toward `target` -- measured in the
-- anchored ROOT's space, so the torso's own turn never feeds back into it
-- -- or 0, 0 when the player is out of range or behind.
local function lookAngles(state: NpcState, target: Vector3?): (number, number)
	if not target then
		return 0, 0
	end
	local neckPoint = state.torso.CFrame * state.restC0.Position
	if (target - neckPoint).Magnitude > LOOK_STUDS then
		return 0, 0
	end
	local direction = state.root.CFrame:VectorToObjectSpace(target - neckPoint)
	-- Straight ahead is -Z; yaw turns it toward -X for a positive angle.
	local yaw = math.atan2(-direction.X, -direction.Z)
	if math.abs(yaw) > LOOK_MAX_YAW then
		return 0, 0
	end
	local flat = math.sqrt(direction.X * direction.X + direction.Z * direction.Z)
	local pitch = math.clamp(math.atan2(direction.Y, flat), -LOOK_MAX_PITCH, LOOK_MAX_PITCH)
	return yaw, pitch
end

function LobbyNpcLifeController._step(self: typeof(LobbyNpcLifeController), dt: number)
	local character = Players.LocalPlayer.Character
	local head = character and character:FindFirstChild("Head")
	local target = if head and head:IsA("BasePart") then head.Position else nil
	local blend = 1 - math.exp(-LOOK_EASE * dt)
	local torsoBlend = 1 - math.exp(-TORSO_EASE * dt)
	for model, state in self._npcs do
		if not model.Parent or not state.neck.Parent then
			self._npcs[model] = nil
			continue
		end
		setHighlighted(state, target ~= nil and (target - state.root.Position).Magnitude <= HIGHLIGHT_STUDS)
		local yaw, pitch = lookAngles(state, target)
		state.yaw += (yaw - state.yaw) * blend
		state.pitch += (pitch - state.pitch) * blend
		-- Split the turn: the torso takes TORSO_SHARE of the yaw (about the
		-- root), the head the rest plus all the pitch (about the neck), so
		-- the face ends up pointing at the player. Each is pre-multiplied
		-- onto its joint's rest rotation, its position kept.
		-- The torso eases toward its share of the turn more slowly; the head
		-- takes up whatever it has not reached yet.
		state.torsoYaw += (state.yaw * TORSO_SHARE - state.torsoYaw) * torsoBlend
		local torsoYaw = state.torsoYaw
		if state.rootJoint then
			state.rootJoint.C0 = CFrame.new(state.rootRestC0.Position)
				* CFrame.Angles(0, torsoYaw, 0)
				* state.rootRestC0.Rotation
		end
		local headYaw = if state.rootJoint then state.yaw - torsoYaw else state.yaw
		local turn = CFrame.Angles(0, headYaw, 0) * CFrame.Angles(state.pitch, 0, 0)
		state.neck.C0 = CFrame.new(state.restC0.Position) * turn * state.restC0.Rotation
	end
end

--[ Lifecycle ]--

function LobbyNpcLifeController.Start(self: typeof(LobbyNpcLifeController))
	task.spawn(function()
		local ignore = workspace:WaitForChild(IGNORE_INSTANCES_NAME, RIG_WAIT_SECONDS)
		local folder = ignore and ignore:WaitForChild(NPC_FOLDER_NAME, RIG_WAIT_SECONDS)
		if not folder then
			return
		end
		folder.ChildAdded:Connect(function(child: Instance)
			if child:IsA("Model") then
				task.spawn(self._addNpc, self, child)
			end
		end)
		for _, child in folder:GetChildren() do
			if child:IsA("Model") then
				task.spawn(self._addNpc, self, child)
			end
		end
	end)
	RunService.RenderStepped:Connect(function(dt: number)
		self:_step(dt)
	end)
end

return LobbyNpcLifeController
