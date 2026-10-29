--!strict
--[[
	Module: DungeonRosterService.lua (Dungeons)
	Description:
	Keeps a reserved dungeon server to the players matched into it
	(2026-10-28).

	The hub's MatchmakingService writes each reserved server's roster
	(MatchmakingData ROSTER_MAP, keyed by the server's PrivateServerId).
	Here:
	  * A player not on the roster is kicked as they arrive.
	  * A player who leaves cannot come back: no rejoining a run.
	  * A server with no roster (the hub's /tp test command, or a failed
	    roster write) admits whoever arrives within ROSTER_FALLBACK_WINDOW
	    of the first player, and nobody after.

	Public servers and Studio are left alone.
]]

local MemoryStoreService = game:GetService("MemoryStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local MatchmakingData = require(ReplicatedStorage.Submodules.Core.Shared.Data.MatchmakingData)

local READ_ATTEMPTS = 3
local READ_RETRY_DELAY = 1

local NOT_INVITED_MESSAGE = "This dungeon is private to the party matched into it."
local LEFT_MESSAGE = "You left this run, so you can't rejoin it."

local DungeonRosterService = {
	Name = "DungeonRosterService",
}

-- nil until read; false when there is none (fallback window).
DungeonRosterService._roster = nil :: { [number]: boolean } | false | nil
DungeonRosterService._rosterReady = false
DungeonRosterService._left = {} :: { [number]: boolean }
-- Fallback: when the first player arrived.
DungeonRosterService._firstArrival = nil :: number?
DungeonRosterService._admitted = {} :: { [number]: boolean }
-- Players let in this session, so leaving counts against them.
DungeonRosterService._present = {} :: { [number]: boolean }

local function isReservedServer(): boolean
	return game.PrivateServerId ~= "" and game.PrivateServerOwnerId == 0
end

function DungeonRosterService._readRoster(self: typeof(DungeonRosterService))
	local map = MemoryStoreService:GetSortedMap(MatchmakingData.ROSTER_MAP)
	for attempt = 1, READ_ATTEMPTS do
		local ok, roster = pcall(function()
			return map:GetAsync(game.PrivateServerId)
		end)
		if ok then
			if type(roster) == "table" and type(roster.userIds) == "table" then
				local set = {}
				for _, userId in roster.userIds do
					set[userId] = true
				end
				self._roster = set
			else
				self._roster = false
			end
			break
		end
		warn(("[DungeonRosterService] Roster read %d failed: %s"):format(attempt, tostring(roster)))
		task.wait(READ_RETRY_DELAY)
	end
	if self._roster == nil then
		self._roster = false
	end
	self._rosterReady = true
end

-- Why `player` may not be here, or nil.
function DungeonRosterService._refusal(self: typeof(DungeonRosterService), player: Player): string?
	local userId = player.UserId
	if self._left[userId] then
		return LEFT_MESSAGE
	end
	local roster = self._roster
	if type(roster) == "table" then
		return if roster[userId] then nil else NOT_INVITED_MESSAGE
	end
	-- No roster: the fallback window.
	local first = self._firstArrival
	if not first then
		self._firstArrival = os.clock()
		first = os.clock()
	end
	if self._admitted[userId] then
		return nil
	end
	if os.clock() - (first :: number) <= MatchmakingData.ROSTER_FALLBACK_WINDOW then
		self._admitted[userId] = true
		return nil
	end
	return NOT_INVITED_MESSAGE
end

function DungeonRosterService._onPlayerAdded(self: typeof(DungeonRosterService), player: Player)
	while not self._rosterReady do
		task.wait(0.1)
	end
	local refused = self:_refusal(player)
	if refused then
		if player.Parent == Players then
			player:Kick(refused)
		end
		return
	end
	self._present[player.UserId] = true
end

function DungeonRosterService.Start(self: typeof(DungeonRosterService))
	if RunService:IsStudio() or not isReservedServer() then
		return
	end
	task.spawn(self._readRoster, self)

	Players.PlayerAdded:Connect(function(player: Player)
		self:_onPlayerAdded(player)
	end)
	for _, player in Players:GetPlayers() do
		task.spawn(self._onPlayerAdded, self, player)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		-- Only someone who was let in counts as having left.
		if self._present[player.UserId] then
			self._present[player.UserId] = nil
			self._left[player.UserId] = true
		end
	end)
end

return DungeonRosterService
