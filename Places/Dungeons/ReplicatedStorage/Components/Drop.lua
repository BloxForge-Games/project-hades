--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Component = require(ReplicatedStorage.Submodules.Core.Packages.Component)
local waitForPrimaryPart = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Drop.waitForPrimaryPart)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local JanitorAdder = require(ReplicatedStorage.Submodules.Core.Source.ComponentExtensions.JanitorAdder)
local DropIndicatorController = require(ReplicatedStorage.Controllers.DropIndicatorController)
local DropFloatController = require(ReplicatedStorage.Controllers.DropFloatController)
local DropPickupSweepController = require(ReplicatedStorage.Controllers.DropPickupSweepController)
local DungeonNetwork = require(ReplicatedStorage.Submodules.Core.Source.Network.Dungeon)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local lootSound = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.lootSound)
local arcPath = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Drop.arcPath)
local privateDropVisibility = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Drop.privateDropVisibility)

-- Studs from the local player's root within which a landed drop is
-- collected (DropPickupSweepController tests it). Pot Of Gold owners skip
-- the gate for coins and orbs; that rule lives in the sweep.
local PICKUP_RADIUS = 10

-- Set by the server on loot that came out of a chest (Miniboss, Boss
-- or Treasure). Those drops get a blip each as they pop; mob death
-- loot deliberately does not.
local CHEST_DROP_ATTRIBUTE = "ChestDrop"

local PICKUP_DELAY = 0.25
local DEFAULT_X_Z_DISTANCE = 8
local BOSS_X_Z_DISTANCE = 20
local Y_POS_OFFSET = -1
-- How long Construct waits for a streamed-in descendant before giving up.
local STREAM_WAIT_SECONDS = 10

-- The landed float (DropFloatController): a gentle sine bob about the
-- landing pose. The old 0.01-0.015 was a PER-FRAME increment added to
-- wherever the coin already was, which integrated to roughly a third of a
-- stud at 60 fps (and less at lower frame rates); these are the studs the
-- fixed bob actually travels, sized to read the same.
local BOB_AMPLITUDE_MIN = 0.15
local BOB_AMPLITUDE_MAX = 0.35
local BOB_CYCLE_MIN = 2
local BOB_CYCLE_MAX = 3.5

local Drop = Component.new({
	Tag = TagList.Drop,
	Extensions = { JanitorAdder } :: { any },
})

-- The pickup. Runs once, from the shared sweep, with the root that walked
-- into range (resolved on that tick, so a respawned character collects
-- just like the first one did).
function Drop:_collect(root: BasePart)
	-- Takes the drop out of the float (and the sweep, if it is still there).
	self._janitor:Cleanup()

	DropIndicatorController.OnDropIndicatorRequested:Fire(
		Players.LocalPlayer.Character,
		self.Instance:GetAttribute(Attributes.DropType),
		self.Instance:GetAttribute(Attributes.DropValue)
	)

	for _, descendant in self.Instance.PrimaryPart:GetDescendants() do
		if descendant:IsA("ParticleEmitter") then
			descendant.Enabled = false
		end
	end

	for _, v in pairs(self._collected:GetChildren()) do
		v:Emit(1)
	end

	local coinCFrameTween = TweenService:Create(self.Instance.PrimaryPart, TweenInfo.new(0.5), { CFrame = root.CFrame })

	local coinImageTransparencyTween = TweenService:Create(
		self._billboardImage,
		TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, false, 0.25),
		{ ImageTransparency = 1 }
	)

	coinCFrameTween:Play()
	coinImageTransparencyTween:Play()

	DungeonNetwork.CoinDropCollected.Fire(self.Instance)

	coinCFrameTween.Completed:Connect(function()
		self.Instance:Destroy()
	end)
end

function Drop:Construct()
	self._gone = false
	self._amplitude = Random.new():NextNumber(BOB_AMPLITUDE_MIN, BOB_AMPLITUDE_MAX)
	self._durationPerCycle = Random.new():NextNumber(BOB_CYCLE_MIN, BOB_CYCLE_MAX)
	-- The parts can stream in after the tagged Model does; wait for them.
	self._primaryPart = waitForPrimaryPart(self.Instance)
	if not self._primaryPart then
		-- Taken / expired while still streaming in: nothing to build, and
		-- Start checks _gone. Anything else is a real failure.
		if self.Instance.Parent == nil then
			self._gone = true
			return
		end
		error("[Drop] PrimaryPart never replicated for " .. self.Instance:GetFullName())
	end
	-- Start (and what runs after it) reads these directly. The server
	-- spawns the model atomic, so they normally arrive with it; the waits
	-- cover an asset that is not, and turn a random "not a valid member"
	-- crash into a clear timeout. Nil only when the model left the
	-- DataModel mid-wait (taken / expired while streaming in): Construct
	-- then bails and Start checks _gone.
	local function need(parent: Instance?, name: string): Instance?
		if parent == nil or self._gone then
			return nil
		end
		local child = parent:WaitForChild(name, STREAM_WAIT_SECONDS)
		if child == nil and self.Instance.Parent == nil then
			self._gone = true
			return nil
		end
		assert(child, ("[Drop] %s never replicated under %s"):format(name, parent:GetFullName()))
		return child
	end
	self._dropParticles = need(need(self._primaryPart, "DropAttachment"), "DropParticles")
	self._collected = need(self._primaryPart, "Collected")
	self._billboardImage = need(need(self._primaryPart, "BillboardGui"), "Image")
	if self._gone then
		return
	end
	-- A drop with no OwnerId is SHARED (mob death loot — everyone
	-- collects it). One WITH an OwnerId is private chest loot: only that
	-- player sees it or can pick it up.
	local ownerId = self.Instance:GetAttribute(Attributes.OwnerId)
	self._isMine = ownerId == nil or ownerId == Players.LocalPlayer.UserId
	self._isBoss = self.Instance:GetAttribute(Attributes.IsBoss)
	self._originPosition = self.Instance:GetPivot().Position
	self._intermediatePosition = self._originPosition + Vector3.new(0, math.random(10, 25), 0)
	self._endPosition = self._originPosition
		+ Vector3.new(
			math.random(
				if not self._isBoss then -DEFAULT_X_Z_DISTANCE else -BOSS_X_Z_DISTANCE,
				if not self._isBoss then DEFAULT_X_Z_DISTANCE else BOSS_X_Z_DISTANCE
			),
			Y_POS_OFFSET,
			math.random(
				if not self._isBoss then -DEFAULT_X_Z_DISTANCE else -BOSS_X_Z_DISTANCE,
				if not self._isBoss then DEFAULT_X_Z_DISTANCE else BOSS_X_Z_DISTANCE
			)
		)
	-- Server-picked landing (DropService), when stamped: everyone sees the
	-- coin settle in the SAME spot, and a wall in the way has already been
	-- turned into a ricochet (BouncePosition). The local scatter above is
	-- only the fallback for a drop spawned without one.
	local serverTarget = self.Instance:GetAttribute("TargetPosition")
	if typeof(serverTarget) == "Vector3" then
		self._endPosition = serverTarget + Vector3.new(0, Y_POS_OFFSET, 0)
	end
	self._arc, self._arcDurationScale = arcPath(
		self._originPosition,
		self._intermediatePosition,
		self._endPosition,
		self.Instance:GetAttribute(Attributes.BouncePosition)
	)
end

function Drop:Start()
	if self._gone then
		return
	end
	-- Someone else's private loot. The server spawned it invisible
	-- (privateDropVisibility.hide) and only the owner reveals it, so there
	-- is nothing to do here; the local hide below is a fallback for a spawn
	-- path that forgot, so at worst a coin flashes rather than lingers.
	if not self._isMine then
		for _, descendant in self.Instance:GetDescendants() do
			if descendant:IsA("BasePart") then
				descendant.LocalTransparencyModifier = 1
			elseif descendant:IsA("ParticleEmitter") or descendant:IsA("Trail") or descendant:IsA("BillboardGui") then
				descendant.Enabled = false
			end
		end
		return
	end

	-- Ours: put the authored look back before the flight. A no-op on a
	-- shared drop, which was never hidden.
	privateDropVisibility.reveal(self.Instance)

	if self.Instance:GetAttribute(CHEST_DROP_ATTRIBUTE) then
		lootSound:PlayCoin()
	end

	-- Finer step for a ricochet (arcPath's durationScale): same pace as a
	-- plain arc over the longer path.
	for i = 0, 1, 0.02 / (self._arcDurationScale or 1) do
		RunService.RenderStepped:Wait()

		self._primaryPart.Position = self._arc(i)
	end

	self._dropParticles.Enabled = false

	-- Settled. The float (one shared Heartbeat, DropFloatController) runs
	-- from the landing pose at once; the pickup sweep takes the drop after
	-- the grace delay. Both leave with the janitor: a collect, an expire or
	-- a destroy unregisters them.
	DropFloatController:Register(self.Instance, {
		base = self.Instance:GetPivot(),
		bobAmplitude = self._amplitude,
		bobCycle = self._durationPerCycle,
		phase = math.random() * 2 * math.pi,
	})
	self._janitor:Add(function()
		DropFloatController:Unregister(self.Instance)
		DropPickupSweepController:Unregister(self.Instance)
	end, true)

	task.delay(PICKUP_DELAY, function()
		-- Gone during the delay (destroyed / expired): nothing to sweep.
		if self._gone or not self.Instance.Parent then
			return
		end
		DropPickupSweepController:Register(self.Instance, {
			part = self._primaryPart,
			radius = PICKUP_RADIUS,
			dropType = self.Instance:GetAttribute(Attributes.DropType) :: string?,
			onPickup = function(root: BasePart)
				self:_collect(root)
			end,
		})
	end)
end

return Drop
