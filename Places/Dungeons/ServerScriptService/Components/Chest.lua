--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local DropService = require(ServerScriptService.Services.DropService)
local Blitz = require(ReplicatedStorage.Submodules.Core.Shared.Blitz)
local Component = require(ReplicatedStorage.Submodules.Core.Packages.Component)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local ChestCoinData = require(ReplicatedStorage.Submodules.Core.Shared.Data.ChestCoinData)
local DifficultyData = require(ReplicatedStorage.Submodules.Core.Shared.Data.DifficultyData)
local getPlaceDungeonId = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Dungeon.getPlaceDungeonId)
local DropTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.DropTypes)
local EnemyTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.EnemyTypes)
local LifeService = require(ServerScriptService.Services.LifeService)
local GearDropService = require(ServerScriptService.Services.GearDropService)
local EnchantmentScrollService = require(ServerScriptService.Services.EnchantmentScrollService)
local UserNotificationService = require(ServerScriptService.Submodules.Core.Source.Services.UserNotificationService)
local NotificationColors = require(ReplicatedStorage.Submodules.Core.Shared.Data.NotificationColors)

local INTERACT_PROXIMITY_PROMPT_DURATION = 0

-- The lid swing itself is CLIENT-side (Client/Components/Chest), played
-- off this attribute — a server-stepped lid replicates at network rate
-- and reads as lag. The server only flips the attribute. The attribute
-- REPLICATES, so every client (late joiners included) swings the lid
-- and plays the open sound; the chest then stays in the room, open,
-- for the rest of the floor (a fade-out was tried and removed).
local OPENED_ATTRIBUTE = "Opened"

-- THE MIMIC (2026-11-13; replaces the shelved Mimic Vault event): any
-- treasure chest has MIMIC_CHANCE to be one. It pays NOTHING: it shakes,
-- bursts (no gear, no enchantment scroll), and a corrupted pack of the
-- dungeon's own mobs pours out
-- (MIMIC_BASE_MOBS + MIMIC_MOBS_PER_PLAYER per living player, at most
-- MIMIC_MAX_MOBS). Rolled when the chest is opened.
local MIMIC_CHANCE = 0.1
local MIMIC_BASE_MOBS = 2
local MIMIC_MOBS_PER_PLAYER = 1
local MIMIC_MAX_MOBS = 6
local MIMIC_SHAKE_SECONDS = 0.8
local MIMIC_SHAKE_DEGREES = 8

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

local function livingCount(): number
	local count = 0
	for _, player in Players:GetPlayers() do
		if not LifeService:IsDeathState(player) then
			count += 1
		end
	end
	return count
end

-- The mimic: shake, burst, the pack. Nothing drops.
local function springMimic(chest: Model, opener: Player)
	UserNotificationService:RequestAllNotification({
		titleText = "It's a Mimic!",
		titleTextFont = Enum.Font.SourceSansBold,
		titleTextColor3 = NotificationColors.Error,
		titleTextTransparency = 0,
		text = opener.Name .. " woke something hungry...",
		textFont = Enum.Font.SourceSansBold,
		textColor3 = Color3.fromRGB(255, 255, 255),
		textTransparency = 0,
	})
	local pivot = chest:GetPivot()
	local shakes = 6
	for index = 1, shakes do
		local sign = if index % 2 == 0 then 1 else -1
		chest:PivotTo(pivot * CFrame.Angles(0, 0, math.rad(MIMIC_SHAKE_DEGREES * sign)))
		task.wait(MIMIC_SHAKE_SECONDS / shakes)
	end
	chest:PivotTo(pivot)
	if not chest.Parent then
		return
	end
	local position = if chest.PrimaryPart then chest.PrimaryPart.Position else pivot.Position
	local explosion = Instance.new("Explosion")
	explosion.BlastPressure = 0
	explosion.BlastRadius = 0
	explosion.DestroyJointRadiusPercent = 0
	explosion.Position = position
	explosion.Parent = workspace
	chest:SetAttribute(OPENED_ATTRIBUTE, true)

	local dungeonService = Blitz.OptionalService("DungeonService")
	local mobSpawnService = Blitz.OptionalService("MobSpawnService")
	local room = dungeonService and dungeonService:GetPlayerRoom(opener)
	if room and mobSpawnService then
		local count = math.min(MIMIC_BASE_MOBS + MIMIC_MOBS_PER_PLAYER * livingCount(), MIMIC_MAX_MOBS)
		mobSpawnService:SpawnMobsAt(room, position, count, true)
	end
end

-- THE FLOOR'S CHEST COUNT (2026-11-14): how many treasure chests stand on
-- the floor and how many the party has opened, published on workspace
-- (Attributes.TreasureChestsTotal / Found) for the minimap's "Chests x / y"
-- and the run summary. Counted from the chests that really exist (a
-- branch the generator could not fit places none), and a chest leaving
-- with its floor takes its share back out.
local chestsTotal = 0
local chestsFound = 0

local function publishChestCount()
	workspace:SetAttribute(Attributes.TreasureChestsTotal, chestsTotal)
	workspace:SetAttribute(Attributes.TreasureChestsFound, chestsFound)
end

local Chest = Component.new({
	Tag = TagList.Chest,
	Extensions = {},
})

function Chest:Construct()
	self._proximityPrompt = Instance.new("ProximityPrompt")
	self._playerRegistry = {} :: { [Players]: boolean }
	self._counted = false
	self._found = false
end

function Chest:Stop()
	if self._counted then
		self._counted = false
		chestsTotal = math.max(chestsTotal - 1, 0)
		if self._found then
			chestsFound = math.max(chestsFound - 1, 0)
		end
		publishChestCount()
	end
end

function Chest:Start()
	self._counted = true
	chestsTotal += 1
	publishChestCount()

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

		-- Found, mimic or not: the first opening counts it once.
		if not self._found then
			self._found = true
			chestsFound += 1
			publishChestCount()
		end

		if math.random() < MIMIC_CHANCE then
			springMimic(self.Instance, playerWhoTriggered)
			return
		end

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
		-- EnemyTypes.Treasure row, 10%), like a corpse drop.
		local origin = self.Instance.PrimaryPart.Position
		for _, player in Players:GetPlayers() do
			if not LifeService:IsDeathState(player) then
				task.spawn(GearDropService.DropGear, GearDropService, player, origin, EnemyTypes.Treasure, true)
				-- An enchantment scroll: the same personal roll, at the
				-- treasure chest's chance (EnchantmentScrollData
				-- .ChanceByEnemyType, 10%). A mimic returned above.
				EnchantmentScrollService:RollChestScroll(player, origin, EnemyTypes.Treasure)
			end
		end
	end)
end

return Chest
