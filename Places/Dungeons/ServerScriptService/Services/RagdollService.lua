--!strict
--[[
	Module: Services/RagdollService.lua
	Description:
	Builds the ragdoll rig (attachments, BallSocketConstraints, the Motor6D
	list and the RagdollTrigger value) on every player character, and
	flips it on the trigger: motors off, PlatformStand on, the client told
	through Combat.RagdollToggled. Ragdoll / Unragdoll take a character
	model so NPCs can use them too.

	A Blitz module depending on PlayerEventService.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Combat = require(ServerScriptService.Submodules.Core.Source.Network.Combat)
local Signal = require(ReplicatedStorage.Submodules.Core.Shared.Types.Signal)
local ValueNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ValueNames)
local PlayerEventService = require(ServerScriptService.Submodules.Core.Source.Services.PlayerEventService)

local ragdollAttachments = ReplicatedStorage.GameAssets.Attachments.RagdollAttachments:GetChildren()

local RAGDOLL_TRIGGER_STRING = ValueNames.RagdollTrigger

-- Anti-jitter tuning for the BallSocketConstraints. With MaxFrictionTorque = 0
-- (Roblox default) the joint freely rotates with no internal resistance, so
-- once the character settles into a low-energy pose the constraint solver
-- keeps trading tiny rotational impulses between body parts forever — visible
-- as the character "jittering" on the ground. MaxFrictionTorque is the
-- constraint-solver's own internal friction at the joint (think of it as
-- how "rusty" the hinge is); a small positive value tells the solver to
-- absorb that residual rotational energy instead of bouncing it around.
--
-- 5 is the community-recommended starting value. Bump per-constraint
-- selectively if specific joints still wobble (the head joint is often
-- worst; ~30 is typical for that one).
local BALL_SOCKET_MAX_FRICTION_TORQUE = 30
-- 0 = joint stops dead when it hits an angular limit (no bounce-back).
-- Was previously 1 — at full elasticity, joints at their limits bounced
-- back with full energy on every micro-disturbance (gravity, floor normal
-- force corrections), producing the mild persistent shake on the ground
-- after an awkward landing where joints settled close to their limits.
-- MaxFrictionTorque above damps motion INSIDE the joint range; Restitution
-- controls behavior AT the limits — both knobs are needed.
local BALL_SOCKET_RESTITUTION = 0

local RagdollService = {
	Name = "RagdollService",
	Dependencies = { PlayerEventService } :: { any },

	OnRagdollRequested = Signal.new() :: Signal.Signal<Model>,
	OnUnragdollRequested = Signal.new() :: Signal.Signal<Model>,
}

function RagdollService.Setup(self: typeof(RagdollService), character: Model)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local head = character:FindFirstChild("Head")
	local torso = character:FindFirstChild("Torso")
	if not humanoid or not head or not head:IsA("BasePart") or not torso then
		warn("[RagdollService] Cannot set up ragdoll on " .. character:GetFullName())
		return
	end

	head.Size = Vector3.new(1, 1, 1)
	humanoid.BreakJointsOnDeath = false
	humanoid.RequiresNeck = false

	local attachmentsTable: { [string]: Instance } = {}

	for _, template in ragdollAttachments do
		attachmentsTable[template.Name] = template:Clone()
	end

	local ragdollConstraintsFolder = Instance.new("Folder")
	ragdollConstraintsFolder.Name = "RagdollConstraints"

	for _, clone in attachmentsTable do
		if clone:IsA("Attachment") then
			clone.Parent = character:FindFirstChild(clone:GetAttribute("Parent") :: string)
		elseif clone:IsA("BallSocketConstraint") then
			clone.Attachment0 = attachmentsTable[clone:GetAttribute("0") :: string] :: Attachment
			clone.Attachment1 = attachmentsTable[clone:GetAttribute("1") :: string] :: Attachment
			-- Inject anti-jitter properties at construction. Applied here
			-- (not in the trigger handler) because constraint properties
			-- can be set before parenting and persist through the lifetime
			-- of the constraint — Motor6Ds being enabled/disabled doesn't
			-- affect them.
			clone.MaxFrictionTorque = BALL_SOCKET_MAX_FRICTION_TORQUE
			clone.Restitution = BALL_SOCKET_RESTITUTION
			clone.Parent = ragdollConstraintsFolder
		end
	end

	ragdollConstraintsFolder.Parent = character

	local motorsFolder = Instance.new("Folder")
	motorsFolder.Name = "Motors"

	local motors: { Motor6D } = {}
	for _, child in torso:GetChildren() do
		if child:IsA("Motor6D") then
			table.insert(motors, child)
			local value = Instance.new("ObjectValue")
			value.Value = child
			value.Parent = motorsFolder
		end
	end

	motorsFolder.Parent = ragdollConstraintsFolder

	-- Ragdoll trigger
	local triggerPrompt = Instance.new("BoolValue")
	triggerPrompt.Name = RAGDOLL_TRIGGER_STRING
	triggerPrompt.Parent = character

	triggerPrompt.Changed:Connect(function(bool: boolean)
		humanoid.AutoRotate = not bool

		-- PlatformStand fully detaches the Humanoid's motion controller —
		-- no more balance forces, no walk-target ticking, no idle drift.
		-- Previously the Humanoid kept its internal balance loop running
		-- while ragdolled (Motor6Ds were disabled but the Humanoid itself
		-- was still trying to stabilize the character), which layered a
		-- second source of micro-motion on top of any joint instability.
		-- Belt-and-suspenders with the Restitution=0 change above.
		--
		-- Goes true on ragdoll, false on unragdoll — the existing AutoRotate
		-- / Motor6D toggling already follows the same shape so this fits
		-- the pattern.
		humanoid.PlatformStand = bool

		for _, motor in motors do
			motor.Enabled = not bool
		end

		if bool then
			self.OnRagdollRequested:Fire(character)
		else
			self.OnUnragdollRequested:Fire(character)
		end

		local player = Players:GetPlayerFromCharacter(character)

		if player then
			Combat.RagdollToggled.Fire(player, bool)
		end
	end)
end

local function setTrigger(character: Model, value: boolean)
	local trigger = character:FindFirstChild(RAGDOLL_TRIGGER_STRING)
	if trigger and trigger:IsA("BoolValue") then
		trigger.Value = value
	end
end

function RagdollService.Ragdoll(_self: typeof(RagdollService), character: Model)
	setTrigger(character, true)
end

function RagdollService.Unragdoll(_self: typeof(RagdollService), character: Model)
	setTrigger(character, false)
end

function RagdollService.Start(self: typeof(RagdollService))
	--[[ We reference character model instead of Player object,
	 	because these methods are used for NPC's as well]]
	PlayerEventService.OnPlayerAdded:Connect(function(player: Player)
		local character = player.Character or player.CharacterAdded:Wait()

		self:Setup(character)
	end)
end

return RagdollService
