local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local Signal = require(ReplicatedStorage.Submodules.Core.Packages.Signal)
local ValueNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ValueNames)

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
--
-- Restitution = 0 means the joint doesn't "bounce" off its angular limits.
-- Belt-and-suspenders alongside MaxFrictionTorque; not always strictly
-- needed but harmless.
local BALL_SOCKET_MAX_FRICTION_TORQUE = 30
-- 0 = joint stops dead when it hits an angular limit (no bounce-back).
-- Was previously 1 — at full elasticity, joints at their limits bounced
-- back with full energy on every micro-disturbance (gravity, floor normal
-- force corrections), producing the mild persistent shake on the ground
-- after an awkward landing where joints settled close to their limits.
-- MaxFrictionTorque above damps motion INSIDE the joint range; Restitution
-- controls behavior AT the limits — both knobs are needed.
local BALL_SOCKET_RESTITUTION = 0

local PlayerEventService

local RagdollService = Knit.CreateService({
	Name = "RagdollService",
	Client = { OnRagdollToggled = Knit.CreateSignal() },
})

RagdollService.OnRagdollRequested = Signal.new()
RagdollService.OnUnragdollRequested = Signal.new()

function RagdollService:Setup(character: Model)
	local humanoid = character.Humanoid
	character.Head.Size = Vector3.new(1, 1, 1)
	humanoid.BreakJointsOnDeath = false
	humanoid.RequiresNeck = false

	local attachmentsTable = {}

	for _, v in ragdollAttachments do
		attachmentsTable[v.Name] = v:Clone()
	end

	local ragdollConstraintsFolder = Instance.new("Folder")
	ragdollConstraintsFolder.Name = "RagdollConstraints"

	for _, v in pairs(attachmentsTable) do
		if v:IsA("Attachment") then
			v.Parent = character[v:GetAttribute("Parent")]
		elseif v:IsA("BallSocketConstraint") then
			v.Attachment0 = attachmentsTable[v:GetAttribute("0")]
			v.Attachment1 = attachmentsTable[v:GetAttribute("1")]
			-- Inject anti-jitter properties at construction. Applied here
			-- (not in the trigger handler) because constraint properties
			-- can be set before parenting and persist through the lifetime
			-- of the constraint — Motor6Ds being enabled/disabled doesn't
			-- affect them.
			v.MaxFrictionTorque = BALL_SOCKET_MAX_FRICTION_TORQUE
			v.Restitution = BALL_SOCKET_RESTITUTION
			v.Parent = ragdollConstraintsFolder
		end
	end

	ragdollConstraintsFolder.Parent = character

	local motorsFolder = Instance.new("Folder")
	motorsFolder.Name = "Motors"

	for _, v in ipairs(character.Torso:GetChildren()) do
		if v:IsA("Motor6D") then
			local value = Instance.new("ObjectValue")
			value.Value = v
			value.Parent = motorsFolder
		end
	end

	motorsFolder.Parent = ragdollConstraintsFolder

	-- Ragdoll trigger
	local triggerPrompt = Instance.new("BoolValue")
	triggerPrompt.Name = RAGDOLL_TRIGGER_STRING
	triggerPrompt.Parent = character

	triggerPrompt.Changed:Connect(function(bool: boolean)
		character.Humanoid.AutoRotate = not bool

		-- PlatformStand fully detaches the Humanoid's motion controller —
		-- no more balance forces, no walk-target ticking, no idle drift.
		-- Previously the Humanoid kept its internal balance loop running
		-- while ragdolled (Motor6Ds were disabled but the Humanoid itself
		-- was still trying to stabilize the character), which layered a
		-- second source of micro-motion on top of any joint instability.
		-- Belt-and-suspenders with the Restitution=0 change above; if the
		-- BallSocket fix doesn't fully kill the shake, this should close
		-- the remaining gap.
		--
		-- Goes true on ragdoll, false on unragdoll — the existing AutoRotate
		-- / Motor6D toggling already follows the same shape so this fits
		-- the pattern.
		character.Humanoid.PlatformStand = bool

		for _, v in ipairs(character.RagdollConstraints.Motors:GetChildren()) do
			v.Value.Enabled = not bool
		end

		if bool then
			self.OnRagdollRequested:Fire(character)
		else
			self.OnUnragdollRequested:Fire(character)
		end

		local player = Players:GetPlayerFromCharacter(character)

		if player then
			self.Client.OnRagdollToggled:Fire(player, bool)
		end
	end)
end

function RagdollService:Ragdoll(character: Model)
	if character:FindFirstChild(RAGDOLL_TRIGGER_STRING) then
		character:FindFirstChild(RAGDOLL_TRIGGER_STRING).Value = true
	end
end

function RagdollService:Unragdoll(character: Model)
	if character:FindFirstChild(RAGDOLL_TRIGGER_STRING) then
		character:FindFirstChild(RAGDOLL_TRIGGER_STRING).Value = false
	end
end

function RagdollService:KnitInit()
	PlayerEventService = Knit.GetService("PlayerEventService")
end

function RagdollService:KnitStart()
	--[[ We reference character model instead of Player object,
	 	because these methods are used for NPC's as well]]
	PlayerEventService.OnPlayerAdded:Connect(function(player: Player)
		local character = player.Character or player.CharacterAdded:Wait()

		self:Setup(character)
	end)
end

return RagdollService
