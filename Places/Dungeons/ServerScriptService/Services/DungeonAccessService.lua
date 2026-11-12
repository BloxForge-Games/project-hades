--!strict
--[[
	Module: DungeonAccessService.lua (Dungeons)
	Description:
	Closes the Dungeons place to everyone below the dev team's group rank
	(2026-11-12): Developer, Tester, Admin and Owner (rank
	Constants.QUEUE_MIN_GROUP_RANK in Constants.GROUP_ID) may play; anyone
	else is kicked as they arrive, however they got here (the hub queue,
	/tp, a direct launch, following a friend).

	The hub's MatchmakingService already refuses the queue below that rank;
	this is the server-side backstop. A rank that cannot be read after
	READ_ATTEMPTS fails CLOSED (kick). Studio is skipped: multi-client
	playtests use test UserIds that are in no group.
]]

local GroupService = game:GetService("GroupService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Constants = require(ReplicatedStorage.Submodules.Core.Shared.Data.Constants)

local READ_ATTEMPTS = 3
local READ_RETRY_DELAY = 1

local CLOSED_MESSAGE = "Dungeons are only open to the dev team right now."
local CHECK_FAILED_MESSAGE = "Couldn't check your group rank. Please rejoin from the hub."

local DungeonAccessService = {
	Name = "DungeonAccessService",
}

-- The player's rank in the game's group (0 when not a member), or nil
-- when every read failed.
local function readRank(player: Player): number?
	for attempt = 1, READ_ATTEMPTS do
		local ok, groups = pcall(function()
			return GroupService:GetGroupsAsync(player.UserId)
		end)
		if ok and typeof(groups) == "table" then
			for _, group in groups :: { any } do
				if group.Id == Constants.GROUP_ID then
					return tonumber(group.Rank) or 0
				end
			end
			return 0
		end
		warn(string.format("[DungeonAccessService] GetGroupsAsync failed for %s: %s", player.Name, tostring(groups)))
		if attempt < READ_ATTEMPTS then
			task.wait(READ_RETRY_DELAY)
		end
	end
	return nil
end

function DungeonAccessService._onPlayerAdded(_self: typeof(DungeonAccessService), player: Player)
	local rank = readRank(player)
	if rank ~= nil and rank >= Constants.QUEUE_MIN_GROUP_RANK then
		return
	end
	if player.Parent == Players then
		player:Kick(if rank == nil then CHECK_FAILED_MESSAGE else CLOSED_MESSAGE)
	end
end

function DungeonAccessService.Start(self: typeof(DungeonAccessService))
	if RunService:IsStudio() then
		return
	end
	Players.PlayerAdded:Connect(function(player: Player)
		self:_onPlayerAdded(player)
	end)
	for _, player in Players:GetPlayers() do
		task.spawn(self._onPlayerAdded, self, player)
	end
end

return DungeonAccessService
