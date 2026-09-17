--!strict
--[[
     Author(s): ryanisawesome25
     Module: Trap.luau
     Description:
     The spike trap's client half: the spike animation on a server
     trigger (Dungeon.TrapSpikesTriggered), and the RETIRE when the
     room is cleared -- the server stamps Attributes.TrapDisabled on a
     completed segment's traps, and a disabled trap's spikes go down and
     stay down, as if someone had just set it off and it never reset.
]]

--[ Exports & Types & Defaults ]--

--[ Roblox Services ]--

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

--[ Imports ]--

local Component = require(ReplicatedStorage.Submodules.Core.Packages.Component)
local waitForPrimaryPart = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Drop.waitForPrimaryPart)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local DungeonNetwork = require(ReplicatedStorage.Submodules.Core.Source.Network.Dungeon)
local InstanceRouter = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Network.InstanceRouter)

--[ Component Root ]--

local spikesRouter = InstanceRouter.Client(DungeonNetwork.TrapSpikesTriggered)

local Trap = Component.new({
	Tag = "Trap",
})

--[ Constants ]--

-- Studs a spike travels from its authored (resting) CFrame: UP when the
-- trap fires, DOWN (hidden in the base) when it retracts. The rest pose
-- sits between the two, which is why "down" is a separate place from
-- "resting".
local SPIKE_TRAVEL_STUDS = 1.25

local EXTEND_TWEEN = TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local RETRACT_TWEEN = TweenInfo.new(0.25, Enum.EasingStyle.Cubic, Enum.EasingDirection.In)
local RESET_TWEEN = TweenInfo.new(0.5, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out)
-- Seconds the spikes stay up before retracting, and seconds they stay
-- hidden before rising back to rest.
local EXTENDED_HOLD_SECONDS = 0.5
local RETRACTED_HOLD_SECONDS = 3

--[ Properties ]--

--[ Private Functions ]--

--[ Public Functions ]--

--[ Initializers ]--

function Trap:Construct()
	-- The parts can stream in after the tagged Model does; wait for them
	-- so the spike cache below is complete.
	waitForPrimaryPart(self.Instance)

	-- Cache spike parts and their original CFrames
	self._spikeOriginalCFrames = {} :: { [BasePart]: CFrame }
	-- True once the room is cleared: the spikes are down for good and
	-- every trigger sequence stops short of raising them.
	self._retired = false

	for _, part in pairs(self.Instance:GetDescendants()) do
		if part:IsA("BasePart") and part.Name == "Spike" then
			self._spikeOriginalCFrames[part] = part.CFrame
		end
	end
end

-- The hidden pose: fully down inside the base.
function Trap:_downCFrame(originalCFrame: CFrame): CFrame
	return originalCFrame * CFrame.new(0, -SPIKE_TRAVEL_STUDS, 0)
end

-- One trigger: up, hold, down, hold, back to rest. Each step re-checks
-- the retire flag so a room cleared mid-sequence leaves the spikes down
-- rather than bringing them back up on the timer.
function Trap:_playTrigger()
	if self._retired then
		return
	end

	for spikePart, originalCFrame in pairs(self._spikeOriginalCFrames) do
		spikePart.Transparency = 0

		local extendTween = TweenService:Create(
			spikePart,
			EXTEND_TWEEN,
			{ CFrame = originalCFrame * CFrame.new(0, SPIKE_TRAVEL_STUDS, 0) }
		)
		extendTween:Play()

		extendTween.Completed:Connect(function()
			task.delay(EXTENDED_HOLD_SECONDS, function()
				if not spikePart.Parent then
					return
				end
				-- Down happens whether or not the room cleared meanwhile:
				-- a retired trap wants the spikes down too.
				TweenService:Create(spikePart, RETRACT_TWEEN, { CFrame = self:_downCFrame(originalCFrame) }):Play()

				task.delay(RETRACTED_HOLD_SECONDS, function()
					-- Cleared while hidden: stay hidden.
					if self._retired or not spikePart.Parent then
						return
					end
					TweenService:Create(spikePart, RESET_TWEEN, { CFrame = originalCFrame }):Play()
				end)
			end)
		end)
	end
end

-- The room is cleared: every spike goes down as if the trap had just
-- fired, and nothing raises it again. `instant` skips the tween for a
-- trap that streams in already disabled (walking back through a cleared
-- chamber), so it never pops up and sinks on arrival.
function Trap:_retire(instant: boolean)
	if self._retired then
		return
	end
	self._retired = true

	for spikePart, originalCFrame in pairs(self._spikeOriginalCFrames) do
		if not spikePart.Parent then
			continue
		end
		local downCFrame = self:_downCFrame(originalCFrame)
		if instant then
			spikePart.CFrame = downCFrame
		else
			TweenService:Create(spikePart, RETRACT_TWEEN, { CFrame = downCFrame }):Play()
		end
	end
end

function Trap:Start()
	self._unbindSpikes = spikesRouter:Bind(self.Instance, function(trapInstance: Model)
		if trapInstance ~= self.Instance then
			warn("Spike trigger received for different trap instance:", trapInstance.Name)
			return
		end
		self:_playTrigger()
	end)

	-- Retire on the server's stamp -- now if it is already there (the
	-- room was cleared before this trap streamed in), else when it lands.
	if self.Instance:GetAttribute(Attributes.TrapDisabled) == true then
		self:_retire(true)
	end
	self._disabledConnection = self.Instance:GetAttributeChangedSignal(Attributes.TrapDisabled):Connect(function()
		if self.Instance:GetAttribute(Attributes.TrapDisabled) == true then
			self:_retire(false)
		end
	end)
end

function Trap:Stop()
	if self._unbindSpikes then
		self._unbindSpikes()
		self._unbindSpikes = nil
	end
	if self._disabledConnection then
		self._disabledConnection:Disconnect()
		self._disabledConnection = nil
	end
end

return Trap
