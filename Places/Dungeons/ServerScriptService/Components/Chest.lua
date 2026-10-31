--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local DropService = require(ServerScriptService.Services.DropService)
local Blitz = require(ReplicatedStorage.Submodules.Core.Shared.Blitz)
local Component = require(ReplicatedStorage.Submodules.Core.Packages.Component)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local ChestCoinData = require(ReplicatedStorage.Submodules.Core.Shared.Data.ChestCoinData)
local DifficultyData = require(ReplicatedStorage.Submodules.Core.Shared.Data.DifficultyData)
local getPlaceDungeonId = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Dungeon.getPlaceDungeonId)
local DropTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.DropTypes)
local EnemyTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.EnemyTypes)
local LifeService = require(ServerScriptService.Services.LifeService)
local GearDropService = require(ServerScriptService.Services.GearDropService)

local INTERACT_PROXIMITY_PROMPT_DURATION = 0

-- The lid swing itself is CLIENT-side (Client/Components/Chest), played
-- off this attribute — a server-stepped lid replicates at network rate
-- and reads as lag. The server only flips the attribute. The attribute
-- REPLICATES, so every client (late joiners included) swings the lid
-- and plays the open sound; the chest then stays in the room, open,
-- for the rest of the floor (a fade-out was tried and removed).
local OPENED_ATTRIBUTE = "Opened"

-- A treasure chest is Gold first and a few Gems second. The Gold is the
-- TIER's: DifficultyData.TreasureChestPayout, the treasure slice of the
-- run's chestCoins on this floor over the chests a floor places, split
-- into ChestCoinData's pickup count -- so a run's Gold lands on the
-- Blacksmith's anchors whatever it finds. No Health / Mana orbs (design
-- call, 2026-10-21): the chest is a purse, not a fountain. The scatter is
-- SHARED loot -- the counts do NOT scale with party size, so a chest
-- stays a fixed prize rather than a per-head payout; the bezier scatter
-- is automatic (Client/Components/Drop).

-- The run's tier and floor, for the payout (1 / Normal with no run).
local function treasurePayout(): number
	local dungeonService = Blitz.OptionalService("DungeonService")
	local tier = if dungeonService
		then dungeonService:GetDifficultyScale()
		else DifficultyData.Resolve(DifficultyData.Order[1])
	local floor = if dungeonService then dungeonService:GetFloor() else 1
	return DifficultyData.TreasureChestPayout(tier, floor)
end

local Chest = Component.new({
	Tag = TagList.Chest,
	Extensions = {},
})

function Chest:Construct()
	self._proximityPrompt = Instance.new("ProximityPrompt")
	self._playerRegistry = {} :: { [Players]: boolean }
end

function Chest:Start()
	self._proximityPrompt.ActionText = "Interact"
	self._proximityPrompt.ObjectText = self.Instance.Name
	self._proximityPrompt.KeyboardKeyCode = Enum.KeyCode.F
	self._proximityPrompt.Exclusivity = Enum.ProximityPromptExclusivity.OnePerButton
	self._proximityPrompt.HoldDuration = INTERACT_PROXIMITY_PROMPT_DURATION
	self._proximityPrompt.Style = Enum.ProximityPromptStyle.Custom
	self._proximityPrompt.RequiresLineOfSight = false
	self._proximityPrompt.MaxActivationDistance = 8
	self._proximityPrompt.Parent = self.Instance
	self._proximityPrompt.UIOffset = Vector2.new(0, 0)
	self._proximityPrompt.ObjectText = "Treasure Chest"

	self._proximityPrompt:SetAttribute("Style", "DefaultCustom")

	self._proximityPrompt.Triggered:Connect(function(playerWhoTriggered: Player)
		-- A dead player collects nothing: the run gear that spilled out of the
		-- corpse is for the living (or for this player after a revive).
		if LifeService:IsDeathState(playerWhoTriggered) then
			return
		end
		if self._playerRegistry[playerWhoTriggered] then
			return
		end

		self._playerRegistry[playerWhoTriggered] = true

		self.Instance.ProximityPrompt.Enabled = false

		-- Every client's Chest component swings the lid off this edge.
		self.Instance:SetAttribute(OPENED_ATTRIBUTE, true)

		local coinData = ChestCoinData[getPlaceDungeonId()] or ChestCoinData.Default

		if not coinData then
			return warn("[Chest] Indexed `coinData` returned as incorrect datatype.")
		end

		DropService.OnChestCoinsRequested:Fire(playerWhoTriggered)

		-- Shared party loot, so no ownerId — but the coins still blip out
		-- one at a time (the trailing `true`). The payout splits into the
		-- row's pickup count, rounded up so it never pays under the tier.
		local pickups = math.random(coinData.minDropRate, coinData.maxDropRate)
		local coinValue = math.max(1, math.ceil(treasurePayout() / pickups))
		DropService.OnDropRequested:Fire(
			self.Instance.PrimaryPart,
			DropTypes.Coins,
			pickups,
			pickups,
			coinValue,
			coinValue,
			false,
			nil,
			true
		)

		-- A few Gems, the run currency, from the entry's own row (ChestCoinData
		-- `gems`), the same shared, blip-per-pickup scatter as the coins.
		local gemData = coinData.gems
		if gemData then
			DropService.OnDropRequested:Fire(
				self.Instance.PrimaryPart,
				DropTypes.Gems,
				gemData.minDropRate,
				gemData.maxDropRate,
				gemData.minGems,
				gemData.maxGems,
				false,
				nil,
				true
			)
		end

		-- Gear: a personal roll for every living player (DungeonData
		-- EnemyTypes.Treasure row, 15%), like a corpse drop.
		local origin = self.Instance.PrimaryPart.Position
		for _, player in Players:GetPlayers() do
			if not LifeService:IsDeathState(player) then
				task.spawn(GearDropService.DropGear, GearDropService, player, origin, EnemyTypes.Treasure, true)
			end
		end
	end)
end

return Chest
