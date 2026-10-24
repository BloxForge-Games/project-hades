--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local ServerScriptService = game:GetService("ServerScriptService")

local Component = require(ReplicatedStorage.Submodules.Core.Packages.Component)
local Blitz = require(ReplicatedStorage.Submodules.Core.Shared.Blitz)
local DropService = require(ServerScriptService.Services.DropService)
local DungeonNetwork = require(ServerScriptService.Submodules.Core.Source.Network.Dungeon)
local InstanceRouter = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Network.InstanceRouter)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local DropData = require(ReplicatedStorage.Submodules.Core.Shared.Data.DropData)
local DropTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.DropTypes)
local LifeService = require(ServerScriptService.Services.LifeService)
local withinPickupReach = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Drop.withinPickupReach)

-- The client collects inside its PICKUP_RADIUS (10); this is that with
-- margin for the trigger's latency (QA 2026-10-21, P0 #3).
local PICKUP_REACH = 24
local DESTROY_DELAY = 25
local MANA_DESTROY_DELAY = 10

-- Gems and the two orbs are ROOM-BOUND (2026-10-22): their fade timer
-- does not start at spawn but when the room is done -- the next segment
-- clear (a gate opening) or the dungeon completing -- so nothing that
-- dropped mid-fight is lost to the clock while the fight is still on.
-- Coins and Ore keep the plain timer. DungeonService is reached through
-- OptionalService, never required (see Docs/Architecture.md); without
-- it (no run) the plain timer applies.
local ROOM_BOUND_TYPES: { [string]: boolean } = {
	[DropTypes.Gems] = true,
	[DropTypes.Mana] = true,
	[DropTypes.Health] = true,
}

-- The one emitter DropData `particleScale` resizes (Base.Attachment.Shine);
-- the drop sparkle and the Collected burst keep their authored size.
local SHINE_EMITTER_NAME = "Shine"

-- Multiplies every keypoint of a NumberSequence (and its envelope).
local function scaleSequence(sequence: NumberSequence, factor: number): NumberSequence
	local keypoints = {}
	for _, keypoint in sequence.Keypoints do
		table.insert(
			keypoints,
			NumberSequenceKeypoint.new(keypoint.Time, keypoint.Value * factor, keypoint.Envelope * factor)
		)
	end
	return NumberSequence.new(keypoints)
end

local collectedRouter = InstanceRouter.Server(DungeonNetwork.CoinDropCollected)

local Drop = Component.new({
	Tag = TagList.Drop,
})

function Drop:Construct()
	self._playerRegistry = {} :: { [Players]: boolean }
	self._connections = {} :: { RBXScriptConnection }
	self._dropValue = self.Instance:GetAttribute(Attributes.DropValue)
	self._dropType = self.Instance:GetAttribute(Attributes.DropType)
	self._imageId = self.Instance:GetAttribute(Attributes.ImageId)
end

function Drop:Start()
	self.Instance.PrimaryPart.BillboardGui.Image.Image = self._imageId
	self.Instance.PrimaryPart.BillboardGui.Image.ImageColor3 = DropData[self._dropType].color
	self.Instance.PrimaryPart.BillboardGui.Size = DropData[self._dropType].size

	-- DropData `particleScale` (1 / absent = authored) resizes the Shine
	-- emitter only.
	local particleScale = DropData[self._dropType].particleScale or 1
	for _, descendant in self.Instance:GetDescendants() do
		if not descendant:IsA("ParticleEmitter") then
			continue
		end

		descendant.Color = ColorSequence.new(DropData[self._dropType].color)
		if particleScale ~= 1 and descendant.Name == SHINE_EMITTER_NAME then
			descendant.Size = scaleSequence(descendant.Size, particleScale)
		end
	end

	-- Update drop image if updated
	self.Instance.AttributeChanged:Connect(function(attributeName: string)
		if attributeName ~= Attributes.ImageId then
			return
		end

		self.Instance.PrimaryPart.BillboardGui.Image.Image = self._imageId
	end)

	-- The fade-out, DESTROY_DELAY (MANA_DESTROY_DELAY for mana) after it
	-- is armed: at spawn for coins and ore, at room completion for the
	-- room-bound types (ROOM_BOUND_TYPES).
	local fadeDelay = if self._dropType == DropTypes.Mana then MANA_DESTROY_DELAY else DESTROY_DELAY
	local fadeArmed = false
	local function armFade()
		if fadeArmed then
			return
		end
		fadeArmed = true
		task.delay(fadeDelay, function()
			local primary = self.Instance and self.Instance.PrimaryPart
			if not primary or not primary.Parent then
				return -- collected or torn down already
			end
			local coinImageTransparencyTween = TweenService:Create(
				primary.BillboardGui.Image,
				TweenInfo.new(1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ ImageTransparency = 1 }
			)

			for _, descendant in primary:GetDescendants() do
				if descendant:IsA("ParticleEmitter") then
					descendant.Enabled = false
				end
			end

			coinImageTransparencyTween:Play()

			coinImageTransparencyTween.Completed:Connect(function()
				self.Instance:Destroy()
			end)
		end)
	end

	local dungeonService = if ROOM_BOUND_TYPES[self._dropType] then Blitz.OptionalService("DungeonService") else nil
	if dungeonService then
		-- The room is done when its gate opens (a segment clear) or, for
		-- the last room, when the dungeon completes; any one of these arms
		-- the fade once.
		for _, signal in
			{
				dungeonService.Signals.OnSegmentCleared,
				dungeonService.Signals.OnDungeonCompleted,
				dungeonService.Signals.OnFinalDungeonCompleted,
			}
		do
			table.insert(self._connections, signal:Connect(armFade))
		end
	else
		armFade()
	end

	collectedRouter:Bind(self.Instance, function(player: Player)
		-- A dead player collects nothing: the run gear that spilled out of the
		-- corpse is for the living (or for this player after a revive).
		if LifeService:IsDeathState(player) then
			return
		end
		if not withinPickupReach(player, self.Instance, PICKUP_REACH) then
			return
		end
		-- PRIVATE drop (chest loot): only its owner banks it. The client
		-- already hides it from everyone else, but the credit is real
		-- currency — it gets checked HERE, where it cannot be faked.
		local ownerId = self.Instance:GetAttribute(Attributes.OwnerId)
		if ownerId and player.UserId ~= ownerId then
			return
		end

		if self._playerRegistry[player] then
			return
		end

		self._playerRegistry[player] = true

		DropService.OnDropCollected:Fire(player, self._dropType, self._dropValue)
	end)
end

function Drop:Stop()
	for _, connection in self._connections do
		connection:Disconnect()
	end
	table.clear(self._connections)
end

return Drop
