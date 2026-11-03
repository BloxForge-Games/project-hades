--!strict
--[[
	Module: GearChestTierNoticeService.lua
	Description:
	"Stronger gear chest" notice (2026-11-03). Valencia's chest for a
	dungeon rolls at the highest difficulty the player has cleared there
	(GearChestData.TierFor), so a new clear makes it a higher-Power chest.
	The FIRST time the player is in the hub after that, a request card asks
	whether to go and look: Yes teleports them to Valencia and opens her
	window (GearChestTierNoticeController, client), No just closes it.

	What was announced lives on the profile as GearChestSeenTiers
	({ [dungeonId]: difficulty }), written only here. A profile without it
	(every player before this shipped, and a brand-new one) is SEEDED with
	its current tiers silently, so nobody is told about a chest they already
	had. Optional and server-owned: not in DataTemplate, no migration.

	Only dungeons whose chest is open to the player count: released (an
	Index tab, not work in progress), a gear pool, and the player's level
	at the dungeon's unlock (the chest window's Open rule).
]]

--[ Roblox Services ]--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

--[ Imports ]--

local DataService = require(ServerScriptService.Submodules.Core.Source.Services.DataService)
local PlayerEventService = require(ServerScriptService.Submodules.Core.Source.Services.PlayerEventService)
local UserNotificationService = require(ServerScriptService.Submodules.Core.Source.Services.UserNotificationService)
local DifficultyData = require(ReplicatedStorage.Submodules.Core.Shared.Data.DifficultyData)
local GearChestData = require(ReplicatedStorage.Submodules.Core.Shared.Data.GearChestData)
local NotificationColors = require(ReplicatedStorage.Submodules.Core.Shared.Data.NotificationColors)
local arcaneIndex = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Arcane.arcaneIndex)
local getPlayerLevel = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Player.getPlayerLevel)

--[ Service ]--

local GearChestTierNoticeService = {
	Name = "GearChestTierNoticeService",
	Dependencies = { DataService, PlayerEventService, UserNotificationService } :: { any },
}

--[ Constants ]--

local SEEN_KEY = "GearChestSeenTiers"
-- The client acts on answers to this action (GearChestTierNoticeController).
local ACTION = "GearChestTier"
-- After the hub landing and its reveal, so the card is not lost under them.
local NOTICE_DELAY_SECONDS = 6
-- Between two cards when more than one chest rose at once.
local NOTICE_STAGGER_SECONDS = 1.5
local ANSWER_SECONDS = 25
local GOLD = "#FFAA00"

--[ Private ]--

local function rankOf(difficulty: string): number
	return table.find(DifficultyData.Order, difficulty) or 0
end

-- The dungeons whose chest the player can open now (the window's rule).
local function openChests(player: Player): { string }
	local tabbed: { [string]: boolean } = {}
	for _, id in arcaneIndex.getTabbedDungeons() do
		tabbed[id] = true
	end
	local level = getPlayerLevel(player)
	local ids: { string } = {}
	for _, dungeonId in arcaneIndex.getDungeonOrder() do
		if
			tabbed[dungeonId]
			and not arcaneIndex.isDungeonWip(dungeonId)
			and GearChestData.HasPool(dungeonId)
			and level >= arcaneIndex.getUnlockLevel(dungeonId)
		then
			table.insert(ids, dungeonId)
		end
	end
	return ids
end

function GearChestTierNoticeService._check(_self: typeof(GearChestTierNoticeService), player: Player)
	local profile = DataService:GetProfileData(player)
	if not profile or next(profile) == nil then
		return
	end
	local stored = profile[SEEN_KEY]
	local seeding = typeof(stored) ~= "table"
	local seen: { [string]: string } = if seeding then {} else table.clone(stored)

	local risen: { { dungeonId: string, tier: string } } = {}
	for _, dungeonId in openChests(player) do
		local tier = GearChestData.TierFor(profile, dungeonId)
		local before = seen[dungeonId]
		-- A chest new to the record (a dungeon just opened) is noted, not
		-- announced: the level-up notice already named it.
		if not seeding and before ~= nil and rankOf(tier) > rankOf(before) then
			table.insert(risen, { dungeonId = dungeonId, tier = tier })
		end
		if before == nil or rankOf(tier) > rankOf(before) then
			seen[dungeonId] = tier
		end
	end
	DataService:SetProfileValue(player, SEEN_KEY, seen)

	for index, rise in risen do
		task.delay((index - 1) * NOTICE_STAGGER_SECONDS, function()
			if not player.Parent then
				return
			end
			UserNotificationService:RequestUserNotification(player, {
				-- Short: the card shows two lines beside its buttons.
				titleText = "Stronger Gear Chest!",
				titleTextColor3 = NotificationColors.Reward,
				text = string.format(
					'<font color="%s">%s</font> now rolls Power %d gear. Check it out?',
					GOLD,
					arcaneIndex.getDisplayName(rise.dungeonId),
					GearChestData.PowerFor(rise.tier)
				),
				richText = true,
				request = {
					action = ACTION,
					args = { key = rise.dungeonId, dungeonId = rise.dungeonId },
					acceptText = "Yes",
					declineText = "No",
					seconds = ANSWER_SECONDS,
				},
			})
		end)
	end
end

--[ Lifecycle ]--

function GearChestTierNoticeService.Start(self: typeof(GearChestTierNoticeService))
	-- OnPlayerAdded: the profile is loaded and the client is set up.
	PlayerEventService.OnPlayerAdded:Connect(function(player: Player)
		task.delay(NOTICE_DELAY_SECONDS, function()
			if player.Parent == Players then
				self:_check(player)
			end
		end)
	end)
end

return GearChestTierNoticeService
