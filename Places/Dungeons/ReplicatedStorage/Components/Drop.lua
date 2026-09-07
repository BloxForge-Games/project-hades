local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Component = require(ReplicatedStorage.Submodules.Core.Packages.Component)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local CommAdder = require(ReplicatedStorage.Submodules.Core.Source.ComponentExtensions.CommAdder)
local JanitorAdder = require(ReplicatedStorage.Submodules.Core.Source.ComponentExtensions.JanitorAdder)
local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local DropTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.DropTypes)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local lootSound = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.lootSound)
local arcPath = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Drop.arcPath)

local MAX_STUD_RAYCAST_DIST = 8

-- Set by the server on loot that came out of a chest (Miniboss, Boss
-- or Treasure). Those drops get a blip each as they pop; mob death
-- loot deliberately does not.
local CHEST_DROP_ATTRIBUTE = "ChestDrop"

-- Pot Of Gold: these drop types are collected from ANY distance for owners --
-- the 8-stud proximity gate is skipped and the existing fly-to-player tween
-- runs from wherever the drop sits. Gear drops are deliberately absent:
-- they are a deliberate choice the player should walk to.
local COMPASS_DROP_TYPES = {
	[DropTypes.Coins] = true,
	[DropTypes.Health] = true,
	[DropTypes.Mana] = true,
	[DropTypes.SuperMana] = true,
}
local PICKUP_DELAY = 0.25
local DEFAULT_X_Z_DISTANCE = 8
local BOSS_X_Z_DISTANCE = 20
local Y_POS_OFFSET = -1
local DropIndicatorController

local Drop = Component.new({
	Tag = TagList.Drop,
	Extensions = { CommAdder, JanitorAdder },
})

-- True when Pot Of Gold should pull THIS drop in regardless of distance.
-- Reads the replicated relic registry, so it costs no round trip; a missing
-- controller (pre-KnitStart) simply falls back to the normal radius.
local function potOfGoldCollects(dropType: string?): boolean
	if not dropType or not COMPASS_DROP_TYPES[dropType] then
		return false
	end
	local ok, controller = pcall(Knit.GetController, "RelicController")
	if not ok or not controller then
		return false
	end
	local owned = controller:GetRelicsFromUserId(Players.LocalPlayer.UserId)
	return owned ~= nil and (owned[RelicNames["Pot Of Gold"]] or 0) > 0
end

function Drop:_HeartbeatUpdate()
	self.Instance:PivotTo(
		self.Instance:GetPivot()
			+ Vector3.new(0, self._amplitude * math.sin((tick() * 2) * (math.pi / self._durationPerCycle)), 0)
	)

	-- Pot Of Gold owners skip the proximity check entirely for Coins / Orbs;
	-- everything else still needs the character inside MAX_STUD_RAYCAST_DIST.
	local inRange = potOfGoldCollects(self.Instance:GetAttribute(Attributes.DropType))
	if not inRange then
		local partsBoundArray =
			workspace:GetPartBoundsInRadius(self._primaryPart.Position, MAX_STUD_RAYCAST_DIST, self._overlapParams)
		inRange = #partsBoundArray > 0
	end

	if not inRange or not self._canPickup or not self._isMine then
		return
	end

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

	for _, v in pairs(self.Instance.PrimaryPart:FindFirstChild("Collected"):GetChildren()) do
		v:Emit(1)
	end

	local coinCFrameTween = TweenService:Create(
		self.Instance.PrimaryPart,
		TweenInfo.new(0.5),
		{ CFrame = Players.LocalPlayer.Character.HumanoidRootPart.CFrame }
	)

	local coinImageTransparencyTween = TweenService:Create(
		self.Instance.PrimaryPart.BillboardGui.Image,
		TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, false, 0.25),
		{ ImageTransparency = 1 }
	)

	coinCFrameTween:Play()
	coinImageTransparencyTween:Play()

	self._onCoinCollected:Fire()

	coinCFrameTween.Completed:Connect(function()
		self.Instance:Destroy()
	end)
end

function Drop:Construct()
	DropIndicatorController = Knit.GetController("DropIndicatorController")

	self._amplitude = Random.new():NextNumber(0.01, 0.015)
	self._durationPerCycle = Random.new():NextNumber(2, 3.5)
	self._primaryPart = self.Instance.PrimaryPart
	self._onCoinCollected = self._comm:GetSignal("OnCoinCollected")
	self._overlapParams = OverlapParams.new()
	-- Set overlap params
	self._overlapParams.FilterDescendantsInstances = {
		Players.LocalPlayer.Character,
	}
	self._overlapParams.FilterType = Enum.RaycastFilterType.Include
	self._canPickup = false
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
	-- Someone else's private loot: hide it outright rather than leaving
	-- coins on the floor that this player can walk over but never pick
	-- up. Local-only, so it never touches the owner's view.
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

	if self.Instance:GetAttribute(CHEST_DROP_ATTRIBUTE) then
		lootSound:PlayCoin()
	end

	-- Finer step for a ricochet (arcPath's durationScale): same pace as a
	-- plain arc over the longer path.
	for i = 0, 1, 0.02 / (self._arcDurationScale or 1) do
		RunService.RenderStepped:Wait()

		self._primaryPart.Position = self._arc(i)
	end

	self._primaryPart.DropAttachment.DropParticles.Enabled = false

	task.delay(PICKUP_DELAY, function()
		self._canPickup = true
	end)

	self._janitor:Add(RunService.Heartbeat:Connect(function()
		self:_HeartbeatUpdate()
	end))
end

return Drop
