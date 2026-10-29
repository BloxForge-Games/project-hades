--!strict
--[[
	Module: MatchmakingService.lua (Lobby)
	Description:
	The cross-server dungeon queue (2026-10-28). A party (or a solo
	player) queues for a dungeon, a difficulty and a squad size; players
	queued for the same three across every hub server are grouped until the
	squad is full, then sent together into a reserved server only they can
	enter (DungeonRosterService in the Dungeons place enforces that).

	  TICKET   one per queued party, in MemoryStore (MatchmakingData
	           QUEUE_MAP_PREFIX): its size, its user ids, its server and
	           when it queued. Its server refreshes it every TICKET_REFRESH
	           seconds; a dead server's tickets lapse on their own.
	  MATCHER  every MATCH_INTERVAL seconds, for each queue its players are
	           in, a server tries to take that queue's lock (LOCK_MAP). The
	           holder reads the queue oldest first and forms squads that
	           fill exactly: the oldest ticket, then the next ones that fit.
	           It claims each ticket (an UpdateAsync that fails if the
	           ticket was cancelled or claimed), reserves a server, writes
	           its roster (ROSTER_MAP), stamps the match on the tickets and
	           announces it (MessagingService MATCH_TOPIC).
	  LAUNCH   the server owning a ticket teleports its players with the
	           access code, from the announcement or, if that is lost, from
	           the stamp its next refresh finds.

	A party whose size equals the squad skips the queue and launches at
	once. A queue waits until it fills; the X on the pill leaves it. A
	party that changes while queued leaves the queue.

	Studio cannot teleport: a match there is announced and the queue
	cleared instead.
]]

local HttpService = game:GetService("HttpService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local MessagingService = game:GetService("MessagingService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local TeleportService = game:GetService("TeleportService")

local NotificationColors = require(ReplicatedStorage.Submodules.Core.Shared.Data.NotificationColors)
local PartyNetwork = require(ServerScriptService.Submodules.Core.Source.Network.Party)
local UserNotificationService = require(ServerScriptService.Submodules.Core.Source.Services.UserNotificationService)
local DifficultyData = require(ReplicatedStorage.Submodules.Core.Shared.Data.DifficultyData)
local DungeonData = require(ReplicatedStorage.Submodules.Core.Shared.Data.DungeonData)
local MatchmakingData = require(ReplicatedStorage.Submodules.Core.Shared.Data.MatchmakingData)
local getPlayerLevel = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Player.getPlayerLevel)

local PartyService = require(script.Parent.PartyService)

-- Seconds the "Match found" pill shows before the teleport.
local LAUNCH_DELAY = 1.5

type Ticket = {
	id: string,
	queueKey: string,
	dungeonId: string,
	difficulty: string,
	squad: number,
	players: { Player },
	leader: Player,
	startedAt: number,
	-- Set once a match was found for it: it no longer refreshes or cancels.
	launched: boolean,
	-- The match it is launching into.
	launchedMatch: string?,
}

-- What a ticket holds in MemoryStore.
type StoredTicket = {
	size: number,
	userIds: { number },
	leaderUserId: number,
	jobId: string,
	createdAt: number,
	claim: string?,
	claimedAt: number?,
	match: Match?,
}

type Match = {
	matchId: string,
	placeId: number,
	accessCode: string,
	dungeonId: string,
	difficulty: string,
	leaderUserId: number,
	tickets: { string },
}

local MatchmakingService = {
	Name = "MatchmakingService",
	Dependencies = { PartyService, UserNotificationService } :: { any },
}

-- Tickets this server owns, by id.
MatchmakingService._tickets = {} :: { [string]: Ticket }
MatchmakingService._ticketOf = {} :: { [Player]: Ticket }

--[ Helpers ]--

local function notify(player: Player, title: string, text: string, color: Color3?)
	UserNotificationService:RequestUserNotification(player, {
		titleText = title,
		titleTextColor3 = color or NotificationColors.Error,
		text = text,
	})
end

local function queueKey(dungeonId: string, difficulty: string, squad: number): string
	return ("%s|%s|%d"):format(dungeonId, difficulty, squad)
end

local function queueMap(key: string): MemoryStoreSortedMap
	return MemoryStoreService:GetSortedMap(MatchmakingData.QUEUE_MAP_PREFIX .. key)
end

local function now(): number
	return workspace:GetServerTimeNow()
end

--[ Queue state to clients ]--

function MatchmakingService._sendState(
	_self: typeof(MatchmakingService),
	ticket: Ticket,
	status: string,
	matched: number
)
	local state = {
		DungeonId = ticket.dungeonId,
		Difficulty = ticket.difficulty,
		Squad = ticket.squad,
		StartedAt = ticket.startedAt,
		Matched = matched,
		Status = status :: any,
	}
	for _, player in ticket.players do
		if player.Parent == Players then
			PartyNetwork.QueueUpdated.Fire(player, state)
		end
	end
end

-- Forgets a ticket locally and tells its players they are out of queue.
function MatchmakingService._drop(self: typeof(MatchmakingService), ticket: Ticket)
	if self._tickets[ticket.id] ~= ticket then
		return
	end
	self._tickets[ticket.id] = nil
	for _, player in ticket.players do
		if self._ticketOf[player] == ticket then
			self._ticketOf[player] = nil
		end
		if player.Parent == Players then
			PartyNetwork.QueueUpdated.Fire(player, nil)
		end
	end
end

--[ Starting and leaving ]--

-- Why `players` may not queue this run, or nil.
local function refusal(players: { Player }, dungeonId: string, difficulty: string): string?
	local dungeon = DungeonData[dungeonId]
	local tier = DifficultyData.Tiers[difficulty]
	for _, player in players do
		local level = getPlayerLevel(player)
		if level < (dungeon.unlockLevel or 1) then
			return ("%s needs Level %d for %s."):format(player.DisplayName, dungeon.unlockLevel, dungeon.displayName)
		end
		if level < (tier.minPlayerLevel or 1) then
			return ("%s needs Level %d for %s."):format(player.DisplayName, tier.minPlayerLevel, difficulty)
		end
	end
	return nil
end

function MatchmakingService.StartQueue(
	self: typeof(MatchmakingService),
	player: Player,
	dungeonId: string,
	difficulty: string,
	squad: number
)
	local dungeon = DungeonData[dungeonId]
	if not dungeon or type(dungeon.placeId) ~= "number" or not DifficultyData.IsValid(difficulty) then
		return
	end
	if squad < MatchmakingData.MIN_SQUAD or squad > MatchmakingData.MAX_SQUAD then
		return
	end
	if not PartyService:IsLeader(player) then
		notify(player, "Party", "Only your party leader can start the queue.")
		return
	end
	local players = PartyService:GetGroup(player)
	if #players > squad then
		notify(player, "Squad Too Small", ("Your party has %d players: pick a bigger squad."):format(#players))
		return
	end
	local refused = refusal(players, dungeonId, difficulty)
	if refused then
		notify(player, "Can't Queue", refused)
		return
	end

	-- A new queue replaces the party's old one.
	local old = self._ticketOf[player]
	if old then
		self:CancelQueue(player)
	end

	local ticket: Ticket = {
		id = HttpService:GenerateGUID(false),
		queueKey = queueKey(dungeonId, difficulty, squad),
		dungeonId = dungeonId,
		difficulty = difficulty,
		squad = squad,
		players = players,
		leader = player,
		startedAt = now(),
		launched = false,
		launchedMatch = nil,
	}
	self._tickets[ticket.id] = ticket
	for _, member in players do
		self._ticketOf[member] = ticket
	end

	-- Already a full squad: no one else to wait for.
	if #players == squad then
		ticket.launched = true
		self:_sendState(ticket, "Found", squad)
		task.spawn(function()
			local match = self:_reserve(dungeonId, difficulty, player.UserId, { ticket.id }, self:_userIds(players))
			if match then
				self:_launch(ticket, match)
			else
				for _, member in players do
					notify(member, "Queue Failed", "Couldn't open a dungeon server. Try again.")
				end
				self:_drop(ticket)
			end
		end)
		return
	end

	self:_sendState(ticket, "Searching", #players)
	task.spawn(function()
		self:_writeTicket(ticket)
	end)
end

-- Leaves the queue for `player`'s whole party.
function MatchmakingService.CancelQueue(self: typeof(MatchmakingService), player: Player)
	local ticket = self._ticketOf[player]
	if not ticket or ticket.launched then
		return
	end
	self:_drop(ticket)
	task.spawn(function()
		pcall(function()
			queueMap(ticket.queueKey):RemoveAsync(ticket.id)
		end)
	end)
	for _, member in ticket.players do
		if member ~= player and member.Parent == Players then
			notify(member, "Queue", ("%s left the queue."):format(player.DisplayName), NotificationColors.System)
		end
	end
end

--[ MemoryStore tickets ]--

function MatchmakingService._userIds(_self: typeof(MatchmakingService), players: { Player }): { number }
	local ids = {}
	for _, player in players do
		table.insert(ids, player.UserId)
	end
	return ids
end

function MatchmakingService._writeTicket(self: typeof(MatchmakingService), ticket: Ticket)
	local stored: StoredTicket = {
		size = #ticket.players,
		userIds = self:_userIds(ticket.players),
		leaderUserId = ticket.leader.UserId,
		jobId = game.JobId,
		createdAt = ticket.startedAt,
	}
	local ok, err = pcall(function()
		queueMap(ticket.queueKey):SetAsync(ticket.id, stored, MatchmakingData.TICKET_SECONDS, ticket.startedAt)
	end)
	if not ok then
		warn(("[MatchmakingService] Ticket write failed: %s"):format(tostring(err)))
	end
end

-- Refreshes a ticket's lifetime, picks up a match stamped on it, and frees
-- a claim whose matcher died. Recreates a ticket that lapsed.
function MatchmakingService._refreshTicket(self: typeof(MatchmakingService), ticket: Ticket)
	local found: Match? = nil
	local ok, err = pcall(function()
		queueMap(ticket.queueKey):UpdateAsync(ticket.id, function(stored: StoredTicket?, sortKey)
			if self._tickets[ticket.id] ~= ticket or ticket.launched then
				return nil
			end
			if stored == nil then
				return {
					size = #ticket.players,
					userIds = self:_userIds(ticket.players),
					leaderUserId = ticket.leader.UserId,
					jobId = game.JobId,
					createdAt = ticket.startedAt,
				},
					ticket.startedAt
			end
			if stored.match then
				found = stored.match
				return nil
			end
			if stored.claim and (stored.claimedAt or 0) + MatchmakingData.CLAIM_SECONDS < now() then
				stored.claim = nil
				stored.claimedAt = nil
			end
			return stored, sortKey
		end, MatchmakingData.TICKET_SECONDS)
	end)
	if not ok then
		warn(("[MatchmakingService] Ticket refresh failed: %s"):format(tostring(err)))
	end
	if found then
		self:_launch(ticket, found)
	end
end

--[ Matching ]--

-- Takes (or keeps) the queue's lock for this server. True when held.
local function takeLock(key: string): boolean
	local held = false
	local ok = pcall(function()
		MemoryStoreService:GetSortedMap(MatchmakingData.LOCK_MAP):UpdateAsync(key, function(owner: string?)
			if owner == nil or owner == game.JobId then
				held = true
				return game.JobId
			end
			held = false
			return nil
		end, MatchmakingData.LOCK_SECONDS)
	end)
	return ok and held
end

-- Squads that fill exactly, oldest tickets first.
local function formSquads(entries: { { key: string, value: StoredTicket } }, squad: number): { { string } }
	local open = {}
	for _, entry in entries do
		local stored = entry.value
		if type(stored) == "table" and not stored.claim and not stored.match and (stored.size or 0) <= squad then
			table.insert(open, entry)
		end
	end
	local used: { [string]: boolean } = {}
	local squads = {}
	for anchorIndex, anchor in open do
		if used[anchor.key] then
			continue
		end
		local picked = { anchor.key }
		local filled = anchor.value.size
		for index = anchorIndex + 1, #open do
			if filled == squad then
				break
			end
			local entry = open[index]
			if not used[entry.key] and filled + entry.value.size <= squad then
				table.insert(picked, entry.key)
				filled += entry.value.size
			end
		end
		if filled == squad then
			for _, key in picked do
				used[key] = true
			end
			table.insert(squads, picked)
		end
	end
	return squads
end

-- Claims every ticket of a squad, or none of them. Returns the claimed
-- tickets' stored values in order, or nil.
local function claimSquad(map: MemoryStoreSortedMap, ids: { string }, claim: string): { StoredTicket }?
	local claimed: { string } = {}
	local values: { StoredTicket } = {}
	for _, id in ids do
		local value: StoredTicket? = nil
		pcall(function()
			map:UpdateAsync(id, function(stored: StoredTicket?, sortKey)
				if stored == nil or stored.claim or stored.match then
					value = nil
					return nil
				end
				stored.claim = claim
				stored.claimedAt = now()
				value = stored
				return stored, sortKey
			end, MatchmakingData.TICKET_SECONDS)
		end)
		if not value then
			-- Release the ones taken so far.
			for _, takenId in claimed do
				pcall(function()
					map:UpdateAsync(takenId, function(stored: StoredTicket?, sortKey)
						if stored and stored.claim == claim then
							stored.claim = nil
							stored.claimedAt = nil
							return stored, sortKey
						end
						return nil
					end, MatchmakingData.TICKET_SECONDS)
				end)
			end
			return nil
		end
		table.insert(claimed, id)
		table.insert(values, value :: StoredTicket)
	end
	return values
end

function MatchmakingService._matchQueue(self: typeof(MatchmakingService), key: string)
	if not takeLock(key) then
		return
	end
	local dungeonId, difficulty, squadText = string.match(key, "^(.-)|(.-)|(%d+)$")
	local squad = tonumber(squadText)
	if not dungeonId or not difficulty or not squad then
		return
	end
	local map = queueMap(key)
	local ok, entries = pcall(function()
		return map:GetRangeAsync(Enum.SortDirection.Ascending, MatchmakingData.QUEUE_READ_COUNT)
	end)
	if not ok or type(entries) ~= "table" then
		return
	end
	for _, ids in formSquads(entries, squad) do
		local matchId = HttpService:GenerateGUID(false)
		local values = claimSquad(map, ids, matchId)
		if not values then
			continue
		end
		local userIds = {}
		for _, value in values do
			for _, userId in value.userIds do
				table.insert(userIds, userId)
			end
		end
		-- The oldest ticket's leader leads the run (its unlocks bound it).
		local match = self:_reserve(dungeonId, difficulty, values[1].leaderUserId, ids, userIds, matchId)
		if not match then
			continue
		end
		for _, id in ids do
			pcall(function()
				map:UpdateAsync(id, function(stored: StoredTicket?, sortKey)
					if stored and stored.claim == matchId then
						stored.match = match
						return stored, sortKey
					end
					return nil
				end, MatchmakingData.TICKET_SECONDS)
			end)
		end
		pcall(function()
			MessagingService:PublishAsync(MatchmakingData.MATCH_TOPIC, match)
		end)
		self:_onMatch(match)
	end
end

-- Reserves a dungeon server and writes its roster. Returns the match, or
-- nil when reserving failed. In Studio nothing is reserved.
function MatchmakingService._reserve(
	_self: typeof(MatchmakingService),
	dungeonId: string,
	difficulty: string,
	leaderUserId: number,
	ticketIds: { string },
	userIds: { number },
	matchId: string?
): Match?
	local placeId = DungeonData[dungeonId].placeId
	local accessCode = ""
	if not RunService:IsStudio() then
		local ok, code, privateServerId = pcall(function()
			return TeleportService:ReserveServer(placeId)
		end)
		if not ok then
			warn(("[MatchmakingService] ReserveServer failed: %s"):format(tostring(code)))
			return nil
		end
		accessCode = code
		local rosterOk, err = pcall(function()
			MemoryStoreService:GetSortedMap(MatchmakingData.ROSTER_MAP):SetAsync(privateServerId, {
				userIds = userIds,
				leaderUserId = leaderUserId,
				difficulty = difficulty,
			}, MatchmakingData.ROSTER_SECONDS)
		end)
		if not rosterOk then
			-- The dungeon falls back to admitting its first arrivals.
			warn(("[MatchmakingService] Roster write failed: %s"):format(tostring(err)))
		end
	end
	return {
		matchId = matchId or HttpService:GenerateGUID(false),
		placeId = placeId,
		accessCode = accessCode,
		dungeonId = dungeonId,
		difficulty = difficulty,
		leaderUserId = leaderUserId,
		tickets = ticketIds,
	}
end

--[ Launching ]--

-- A match was announced: launch the tickets this server owns.
function MatchmakingService._onMatch(self: typeof(MatchmakingService), match: Match)
	if type(match) ~= "table" or type(match.tickets) ~= "table" then
		return
	end
	for _, id in match.tickets do
		local ticket = self._tickets[id]
		if ticket then
			self:_launch(ticket, match)
		end
	end
end

function MatchmakingService._launch(self: typeof(MatchmakingService), ticket: Ticket, match: Match)
	-- Gone, or already launching (the announcement and the refresh can
	-- both deliver the match).
	if self._tickets[ticket.id] ~= ticket or ticket.launchedMatch ~= nil then
		return
	end
	ticket.launched = true
	ticket.launchedMatch = match.matchId
	self:_sendState(ticket, "Found", ticket.squad)

	task.delay(LAUNCH_DELAY, function()
		task.spawn(function()
			pcall(function()
				queueMap(ticket.queueKey):RemoveAsync(ticket.id)
			end)
		end)
		local players = {}
		for _, player in ticket.players do
			if player.Parent == Players then
				table.insert(players, player)
			end
		end
		if #players == 0 then
			self:_drop(ticket)
			return
		end
		if RunService:IsStudio() then
			for _, player in players do
				notify(
					player,
					"Match Found",
					("%s (%s): Studio can't teleport."):format(
						DungeonData[match.dungeonId].displayName,
						match.difficulty
					),
					NotificationColors.Success
				)
			end
			self:_drop(ticket)
			return
		end
		local options = Instance.new("TeleportOptions")
		options.ReservedServerAccessCode = match.accessCode
		options:SetTeleportData({
			partyLeaderUserId = match.leaderUserId,
			Difficulty = match.difficulty,
			MatchId = match.matchId,
		})
		local ok, err = pcall(function()
			TeleportService:TeleportAsync(match.placeId, players, options)
		end)
		if not ok then
			warn(("[MatchmakingService] Teleport failed: %s"):format(tostring(err)))
			for _, player in players do
				notify(player, "Teleport Failed", "Couldn't reach the dungeon. Queue again.")
			end
		end
		self:_drop(ticket)
	end)
end

--[ Lifecycle ]--

function MatchmakingService.Start(self: typeof(MatchmakingService))
	PartyNetwork.StartQueue.On(function(player: Player, request)
		self:StartQueue(player, request.DungeonId, request.Difficulty, request.Squad)
	end)
	PartyNetwork.CancelQueue.On(function(player: Player)
		self:CancelQueue(player)
	end)

	-- A party that changes while queued leaves the queue.
	PartyService.OnPartyChanged:Connect(function(_party, previous: { Player })
		for _, player in previous do
			local ticket = self._ticketOf[player]
			if ticket and not ticket.launched then
				self:_drop(ticket)
				task.spawn(function()
					pcall(function()
						queueMap(ticket.queueKey):RemoveAsync(ticket.id)
					end)
				end)
				for _, member in ticket.players do
					if member.Parent == Players then
						notify(member, "Queue", "Your party changed, so it left the queue.", NotificationColors.System)
					end
				end
			end
		end
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		local ticket = self._ticketOf[player]
		if ticket and not ticket.launched then
			self:CancelQueue(player)
		end
	end)
	-- A teleport can fail after TeleportAsync returned (the dungeon server
	-- never came up, the player's client refused): tell the player, who is
	-- still here with no queue.
	TeleportService.TeleportInitFailed:Connect(function(player: Player, result: Enum.TeleportResult, message: string)
		warn(("[MatchmakingService] Teleport of %s failed: %s %s"):format(player.Name, tostring(result), message))
		notify(player, "Teleport Failed", "Couldn't reach the dungeon. Queue again.")
	end)

	task.spawn(function()
		local ok, err = pcall(function()
			MessagingService:SubscribeAsync(MatchmakingData.MATCH_TOPIC, function(message)
				self:_onMatch(message.Data)
			end)
		end)
		if not ok then
			warn(("[MatchmakingService] Subscribe failed (polling only): %s"):format(tostring(err)))
		end
	end)

	-- Refresh this server's tickets.
	task.spawn(function()
		while true do
			task.wait(MatchmakingData.TICKET_REFRESH)
			for _, ticket in table.clone(self._tickets) do
				if not ticket.launched then
					task.spawn(self._refreshTicket, self, ticket)
				end
			end
		end
	end)

	-- Form matches for the queues this server's players are in.
	task.spawn(function()
		while true do
			task.wait(MatchmakingData.MATCH_INTERVAL)
			local keys: { [string]: boolean } = {}
			for _, ticket in self._tickets do
				if not ticket.launched then
					keys[ticket.queueKey] = true
				end
			end
			for key in keys do
				task.spawn(self._matchQueue, self, key)
			end
		end
	end)
end

return MatchmakingService
