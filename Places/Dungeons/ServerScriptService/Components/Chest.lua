local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local Component = require(ReplicatedStorage.Submodules.Core.Packages.Component)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local ChestCoinData = require(ReplicatedStorage.Submodules.Core.Shared.Data.ChestCoinData)
local PlaceIdData = require(ReplicatedStorage.Submodules.Core.Shared.Data.PlaceIdData)
local DropTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.DropTypes)

local INTERACT_PROXIMITY_PROMPT_DURATION = 0

-- The lid swing itself is CLIENT-side (Client/Components/Chest), played
-- off this attribute — a server-stepped lid replicates at network rate
-- and reads as lag. The server only flips the attribute. The attribute
-- REPLICATES, so every client (late joiners included) swings the lid
-- and plays the open sound; the chest then stays in the room, open,
-- for the rest of the floor (a fade-out was tried and removed).
local OPENED_ATTRIBUTE = "Opened"

-- Treasure chests cough up orbs alongside their coins: 1-5 Health and 1-5
-- Mana, both GUARANTEED (a chest is a deliberate, rare reward, so a dud
-- roll would read as a bug). SHARED loot -- the count does NOT scale with
-- party size, matching the chest's coin drop, so a chest stays a fixed
-- prize rather than a per-head payout.
--
-- Value is 1/1 like every mob-dropped orb: the restore is a FRACTION of the
-- collector's max (DropService's pickup branch -- 10% mana, 5% health), so
-- DropValue goes unused for these types. Collector-side relic effects (Gear
-- Recycler's +50% mana, Regeneration Coil's +50% heal, Lightblox Jar's
-- Overcharged proc) all resolve at pickup, so they apply to chest orbs for
-- free. The bezier scatter is likewise automatic -- Client/Components/Drop
-- animates every Drop-tagged instance the same way.
local MIN_ORB_DROP = 1
local MAX_ORB_DROP = 3

local DropService

Knit.OnStart()
	:andThen(function()
		DropService = Knit.GetService("DropService")
	end)
	:catch(warn)

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
		if self._playerRegistry[playerWhoTriggered] then
			return
		end

		self._playerRegistry[playerWhoTriggered] = true

		self.Instance.ProximityPrompt.Enabled = false

		-- Every client's Chest component swings the lid off this edge.
		self.Instance:SetAttribute(OPENED_ATTRIBUTE, true)

		local coinData = ChestCoinData[PlaceIdData[game.PlaceId]]

		if not coinData then
			return warn("[Chest] Indexed `coinData` returned as incorrect datatype.")
		end

		DropService.OnChestCoinsRequested:Fire(playerWhoTriggered)

		-- Shared party loot, so no ownerId — but the coins still blip out
		-- one at a time (the trailing `true`).
		DropService.OnDropRequested:Fire(
			self.Instance.PrimaryPart,
			DropTypes.Coins,
			coinData.minDropRate,
			coinData.maxDropRate,
			coinData.minCoins,
			coinData.maxCoins,
			false,
			nil,
			true
		)

		DropService.OnDropRequested:Fire(self.Instance.PrimaryPart, DropTypes.Health, MIN_ORB_DROP, MAX_ORB_DROP, 1, 1)

		DropService.OnDropRequested:Fire(self.Instance.PrimaryPart, DropTypes.Mana, MIN_ORB_DROP, MAX_ORB_DROP, 1, 1)
	end)
end

return Chest
