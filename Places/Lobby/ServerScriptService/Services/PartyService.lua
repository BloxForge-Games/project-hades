--!strict
--[[
	Module: PartyService.lua (Lobby)
	Description:
	Parties within this hub server (2026-10-28), invite only.

	  * A party is a leader and up to MAX_PARTY_SIZE - 1 members, all in
	    this server. Inviting someone while in no party starts one.
	  * An invite lasts INVITE_SECONDS. Accepting leaves the player's old
	    party first; a full or vanished party refuses it.
	  * The leader may kick. When the leader leaves, the longest-standing
	    member leads. A party left with one player stays a party of one.
	  * Any change to a party's members fires OnPartyChanged, which the
	    queue (MatchmakingService) listens to: a party that changes while
	    queued leaves the queue.

	Every client sees its own party (PartyUpdated) and its own invites
	(InvitesUpdated, InviteReceived for the toast).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local NotificationColors = require(ReplicatedStorage.Submodules.Core.Shared.Data.NotificationColors)
local PartyNetwork = require(ServerScriptService.Submodules.Core.Source.Network.Party)
local UserNotificationService = require(ServerScriptService.Submodules.Core.Source.Services.UserNotificationService)
local MatchmakingData = require(ReplicatedStorage.Submodules.Core.Shared.Data.MatchmakingData)
local Signal = require(ReplicatedStorage.Submodules.Core.Packages.Signal)

export type Party = {
	leader: Player,
	-- The leader first, then the others in the order they joined.
	members: { Player },
}

local PartyService = {
	Name = "PartyService",
	Dependencies = { UserNotificationService } :: { any },
}

PartyService._partyOf = {} :: { [Player]: Party }
-- invitee -> leader UserId -> expiry (server time)
PartyService._invites = {} :: { [Player]: { [number]: number } }
-- (party, previous members) after any change to a party's members.
PartyService.OnPartyChanged = Signal.new()

--[ Helpers ]--

local function notify(player: Player, title: string, text: string, color: Color3?)
	UserNotificationService:RequestUserNotification(player, {
		titleText = title,
		titleTextColor3 = color or NotificationColors.Error,
		text = text,
	})
end

--[ Public API ]--

-- The player's party, or nil.
function PartyService.GetParty(self: typeof(PartyService), player: Player): Party?
	return self._partyOf[player]
end

-- The players who would queue with `player`: their party's members, or
-- just them.
function PartyService.GetGroup(self: typeof(PartyService), player: Player): { Player }
	local party = self._partyOf[player]
	return if party then table.clone(party.members) else { player }
end

function PartyService.IsLeader(self: typeof(PartyService), player: Player): boolean
	local party = self._partyOf[player]
	return party == nil or party.leader == player
end

--[ Replication ]--

function PartyService._sendParty(self: typeof(PartyService), player: Player)
	local party = self._partyOf[player]
	if not party then
		PartyNetwork.PartyUpdated.Fire(player, nil)
		return
	end
	local members = {}
	for _, member in party.members do
		table.insert(members, member.UserId)
	end
	PartyNetwork.PartyUpdated.Fire(player, { LeaderUserId = party.leader.UserId, Members = members })
end

function PartyService._sendInvites(self: typeof(PartyService), player: Player)
	local list = {}
	local now = workspace:GetServerTimeNow()
	local invites: { [number]: number } = self._invites[player] or {}
	for leaderUserId, expiresAt in invites do
		if expiresAt > now then
			table.insert(list, { LeaderUserId = leaderUserId, ExpiresAt = expiresAt })
		end
	end
	table.sort(list, function(a, b)
		return a.ExpiresAt < b.ExpiresAt
	end)
	PartyNetwork.InvitesUpdated.Fire(player, list)
end

-- Tells everyone in `players` their party, and fires OnPartyChanged.
function PartyService._changed(self: typeof(PartyService), party: Party?, previous: { Player })
	local everyone: { [Player]: boolean } = {}
	for _, player in previous do
		everyone[player] = true
	end
	if party then
		for _, player in party.members do
			everyone[player] = true
		end
	end
	for player in everyone do
		if player.Parent == Players then
			self:_sendParty(player)
		end
	end
	self.OnPartyChanged:Fire(party, previous)
end

--[ Membership ]--

function PartyService._create(self: typeof(PartyService), leader: Player): Party
	local existing = self._partyOf[leader]
	if existing then
		return existing
	end
	local party: Party = { leader = leader, members = { leader } }
	self._partyOf[leader] = party
	self:_changed(party, {})
	return party
end

function PartyService._remove(self: typeof(PartyService), player: Player)
	local party = self._partyOf[player]
	if not party then
		return
	end
	local previous = table.clone(party.members)
	local index = table.find(party.members, player)
	if index then
		table.remove(party.members, index)
	end
	self._partyOf[player] = nil
	if #party.members == 0 then
		self:_changed(nil, previous)
		return
	end
	if party.leader == player then
		party.leader = party.members[1]
		if party.leader.Parent == Players then
			notify(party.leader, "Party", "You lead the party now.", NotificationColors.System)
		end
	end
	self:_changed(party, previous)
end

function PartyService._join(self: typeof(PartyService), player: Player, party: Party): boolean
	if #party.members >= MatchmakingData.MAX_PARTY_SIZE then
		notify(player, "Party Full", "That party has no room left.")
		return false
	end
	if self._partyOf[player] == party then
		return true
	end
	self:_remove(player)
	local previous = table.clone(party.members)
	table.insert(party.members, player)
	self._partyOf[player] = party
	self:_changed(party, previous)
	return true
end

--[ Requests ]--

function PartyService._onInvite(self: typeof(PartyService), player: Player, targetUserId: number)
	local target = Players:GetPlayerByUserId(targetUserId)
	if not target or target == player then
		return
	end
	local party = self._partyOf[player]
	if party and party.leader ~= player then
		notify(player, "Party", "Only your party leader can invite.")
		return
	end
	if party and table.find(party.members, target) then
		return
	end
	if party and #party.members >= MatchmakingData.MAX_PARTY_SIZE then
		notify(player, "Party Full", ("A party holds %d players."):format(MatchmakingData.MAX_PARTY_SIZE))
		return
	end
	self:_create(player)

	local invites = self._invites[target]
	if not invites then
		invites = {}
		self._invites[target] = invites
	end
	local expiresAt = workspace:GetServerTimeNow() + MatchmakingData.INVITE_SECONDS
	invites[player.UserId] = expiresAt
	self:_sendInvites(target)
	PartyNetwork.InviteReceived.Fire(target, { LeaderUserId = player.UserId, ExpiresAt = expiresAt })
	notify(player, "Invite Sent", ("Invited %s to your party."):format(target.DisplayName), NotificationColors.System)

	task.delay(MatchmakingData.INVITE_SECONDS + 0.5, function()
		local current = self._invites[target]
		if current and current[player.UserId] == expiresAt then
			current[player.UserId] = nil
			if target.Parent == Players then
				self:_sendInvites(target)
			end
		end
	end)
end

function PartyService._onRespond(self: typeof(PartyService), player: Player, leaderUserId: number, accept: boolean)
	local invites = self._invites[player]
	local expiresAt = invites and invites[leaderUserId]
	if not invites or not expiresAt then
		return
	end
	invites[leaderUserId] = nil
	self:_sendInvites(player)
	if not accept then
		return
	end
	if expiresAt < workspace:GetServerTimeNow() then
		notify(player, "Invite Expired", "That invite has run out.")
		return
	end
	local leader = Players:GetPlayerByUserId(leaderUserId)
	local party = leader and self._partyOf[leader]
	if not leader or not party then
		notify(player, "Party Gone", "That party no longer exists.")
		return
	end
	if self:_join(player, party) then
		for _, member in party.members do
			if member ~= player then
				notify(member, "Party", ("%s joined the party."):format(player.DisplayName), NotificationColors.System)
			end
		end
	end
end

function PartyService._onKick(self: typeof(PartyService), player: Player, targetUserId: number)
	local party = self._partyOf[player]
	if not party or party.leader ~= player then
		return
	end
	local target = Players:GetPlayerByUserId(targetUserId)
	if not target or target == player or self._partyOf[target] ~= party then
		return
	end
	self:_remove(target)
	notify(target, "Party", "You were removed from the party.", NotificationColors.System)
end

function PartyService._onPlayerRemoving(self: typeof(PartyService), player: Player)
	self:_remove(player)
	self._invites[player] = nil
	-- Invites this player sent lapse with them.
	for invitee, invites in self._invites do
		if invites[player.UserId] then
			invites[player.UserId] = nil
			self:_sendInvites(invitee)
		end
	end
end

--[ Lifecycle ]--

function PartyService.Start(self: typeof(PartyService))
	PartyNetwork.CreateParty.On(function(player: Player)
		self:_create(player)
	end)
	PartyNetwork.InvitePlayer.On(function(player: Player, targetUserId: number)
		self:_onInvite(player, targetUserId)
	end)
	PartyNetwork.RespondInvite.On(function(player: Player, response)
		self:_onRespond(player, response.LeaderUserId, response.Accept)
	end)
	PartyNetwork.LeaveParty.On(function(player: Player)
		self:_remove(player)
	end)
	PartyNetwork.KickMember.On(function(player: Player, targetUserId: number)
		self:_onKick(player, targetUserId)
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		self:_onPlayerRemoving(player)
	end)
end

return PartyService
