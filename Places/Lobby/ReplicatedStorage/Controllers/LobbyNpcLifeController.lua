--!strict
--[[
	Module: LobbyNpcLifeController.lua
	Description:
	Brings the hub's NPCs to life on this client (2026-11-03):

	  IDLE   each NPC under workspace.IgnoreInstances.NPCs plays the
	         PLAYERS' idle on loop (the player Animate script's "idle"),
	         not the stock one its own Animate script carries.
	  LOOK   while the local player is within LOOK_STUDS, the NPC's head
	         turns toward them, eased. It turns at most LOOK_MAX_YAW either
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

--[ Types ]--

type NpcState = {
	model: Model,
	torso: BasePart,
	neck: Motor6D,
	restC0: CFrame,
	yaw: number,
	pitch: number,
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
	loosenRig(model)
	playIdle(humanoid)
	self._npcs[model] = {
		model = model,
		torso = torso,
		neck = neck,
		restC0 = neck.C0,
		yaw = 0,
		pitch = 0,
	}
	model.AncestryChanged:Connect(function()
		if not model:IsDescendantOf(workspace) then
			self._npcs[model] = nil
		end
	end)
end

-- The yaw and pitch (torso space) the head should take toward `target`,
-- or 0, 0 when the player is out of range or behind.
local function lookAngles(state: NpcState, target: Vector3?): (number, number)
	if not target then
		return 0, 0
	end
	local neckPoint = state.torso.CFrame * state.restC0.Position
	if (target - neckPoint).Magnitude > LOOK_STUDS then
		return 0, 0
	end
	local direction = state.torso.CFrame:VectorToObjectSpace(target - neckPoint)
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
	for model, state in self._npcs do
		if not model.Parent or not state.neck.Parent then
			self._npcs[model] = nil
			continue
		end
		local yaw, pitch = lookAngles(state, target)
		state.yaw += (yaw - state.yaw) * blend
		state.pitch += (pitch - state.pitch) * blend
		-- The turn in torso space, about the neck: pre-multiplied onto the
		-- rest C0's rotation, its position kept.
		local turn = CFrame.Angles(0, state.yaw, 0) * CFrame.Angles(state.pitch, 0, 0)
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
