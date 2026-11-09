--!strict
--[[
	FriendBonusService (2026-11-08): the friend bonus for a run
	(Shared/Data/FriendBonusData). A dungeon server holds one run's party,
	so each player's bonus counts their Roblox friends among the other
	players in this server, recounted whenever someone joins or leaves.

	The one writer of Attributes.FriendBonus on each Player (the bonus
	share, e.g. 0.2; nil with no friends here). RunEscrowService applies it
	to the run loot it banks, ExperienceService to EXP, and every client
	draws its HUD chip from it (FriendBonusInterfaceController).

	Player:IsFriendsWithAsync is a web call that can yield or fail, so each pair
	is asked once (pcall'd) and cached for the server's life; a failed ask
	counts as not friends and is tried again on the next recount.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local FriendBonusData = require(ReplicatedStorage.Submodules.Core.Shared.Data.FriendBonusData)

local FriendBonusService = {
	Name = "FriendBonusService",
	-- ["lowId:highId"] = are those two friends (only answered asks).
	_friendCache = {} :: { [string]: boolean },
	-- Bumped per recount, so a slower, older recount never writes last.
	_generation = 0,
}

local function pairKey(a: number, b: number): string
	return if a < b then a .. ":" .. b else b .. ":" .. a
end

-- Whether `player` and `other` are friends (cached; yields on a miss).
function FriendBonusService._areFriends(self: typeof(FriendBonusService), player: Player, other: Player): boolean
	local key = pairKey(player.UserId, other.UserId)
	local cached = self._friendCache[key]
	if cached ~= nil then
		return cached
	end
	local ok, result = pcall(player.IsFriendsWithAsync, player, other.UserId)
	if not ok then
		return false
	end
	self._friendCache[key] = result == true
	return result == true
end

-- Recounts every player's friends in this server and restamps the bonus.
function FriendBonusService._recount(self: typeof(FriendBonusService))
	self._generation += 1
	local generation = self._generation
	local players = Players:GetPlayers()
	local bonuses: { [Player]: number } = {}
	for _, player in players do
		local friends = 0
		for _, other in players do
			if other ~= player and other.Parent == Players and self:_areFriends(player, other) then
				friends += 1
			end
		end
		bonuses[player] = FriendBonusData.BonusFor(friends)
	end
	if generation ~= self._generation then
		return
	end
	for player, bonus in bonuses do
		if player.Parent == Players then
			player:SetAttribute(Attributes.FriendBonus, if bonus > 0 then bonus else nil)
		end
	end
end

-- The bonus share `player` earns with right now (0 with none).
function FriendBonusService.GetBonus(_self: typeof(FriendBonusService), player: Player): number
	local bonus = player:GetAttribute(Attributes.FriendBonus)
	return if type(bonus) == "number" then bonus else 0
end

function FriendBonusService.Start(self: typeof(FriendBonusService))
	Players.PlayerAdded:Connect(function()
		task.spawn(self._recount, self)
	end)
	Players.PlayerRemoving:Connect(function()
		-- After the leaver is gone from GetPlayers.
		task.defer(self._recount, self)
	end)
	task.spawn(self._recount, self)
end

return FriendBonusService
