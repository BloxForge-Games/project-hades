--[[
     Author(s): 
     Module: RoundStatisticsService.lua
     Description:
]]

--[ Roblox Services ]--

local ReplicatedStorage = game:GetService("ReplicatedStorage")

--[ Exports & Types & Defaults ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local Signal = require(ReplicatedStorage.Submodules.Core.Packages.Signal)

local PlayerEventService

local RoundStatisticsService = Knit.CreateService({
	Name = "RoundStatisticsService",
	Client = {},
})

--[ Imports ]--

--[ Constants ]--

--[ Properties ]--

RoundStatisticsService._roundStats = {} -- [roundNumber] = { playerId = { kills = number, assists = number } }
RoundStatisticsService.Signals = {
	OnKillOrAssist = Signal.new(), -- (player: Player, isKill: boolean)
	OnEliteChanged = Signal.new(), -- (player: Player, eliteCount: number)
	OnMinibossChanged = Signal.new(), -- (player: Player, minibossCount: number)
	OnBossChanged = Signal.new(), -- (player: Player, bossCount: number)
}

--[ Private Functions ]--

-- Adds `count` to one of the player's round tallies.
--
-- Both arguments are checked rather than assumed. A firer that omitted
-- its count (the boss kill did, for a while) used to raise "attempt to
-- perform arithmetic (add) on number and nil" from inside a Signal's
-- free thread — which does NOT interrupt whatever fired it, so the only
-- visible symptom was a stack trace and a stat that silently stopped
-- counting. A warn naming the field is far easier to act on.
function RoundStatisticsService:_indexRoundRegistry(player: Player, registryIndex: string, count: number)
	local playerStats = self._roundStats[player.UserId]

	if not playerStats then
		return
	end

	if type(count) ~= "number" then
		warn(
			("[RoundStatisticsService] '%s' fired for %s with no count (got %s) " .. "-- tally not advanced"):format(
				tostring(registryIndex),
				player.Name,
				typeof(count)
			)
		)
		return
	end

	if type(playerStats[registryIndex]) ~= "number" then
		warn(
			("[RoundStatisticsService] '%s' is not a tally on %s's round stats"):format(
				tostring(registryIndex),
				player.Name
			)
		)
		return
	end

	playerStats[registryIndex] += count
end

--[ Public Functions ]--

function RoundStatisticsService:GetTotalKillsAndAssists(player: Player): number
	return self._roundStats[player.UserId] and self._roundStats[player.UserId].totalKillsAndAssists or 0
end

function RoundStatisticsService:GetTotalElites(player: Player): number
	return self._roundStats[player.UserId] and self._roundStats[player.UserId].totalElites or 0
end

function RoundStatisticsService:GetTotalMinibosses(player: Player): number
	return self._roundStats[player.UserId] and self._roundStats[player.UserId].totalMinibosses or 0
end

function RoundStatisticsService:GetTotalBosses(player: Player): number
	return self._roundStats[player.UserId] and self._roundStats[player.UserId].totalBosses or 0
end

--[ Initializers ]--

function RoundStatisticsService:KnitStart()
	PlayerEventService = Knit.GetService("PlayerEventService")

	self.Signals.OnKillOrAssist:Connect(function(player: Player, count: number)
		self:_indexRoundRegistry(player, "totalKillsAndAssists", count)
	end)

	self.Signals.OnEliteChanged:Connect(function(player: Player, count: number)
		self:_indexRoundRegistry(player, "totalElites", count)
	end)

	self.Signals.OnMinibossChanged:Connect(function(player: Player, count: number)
		self:_indexRoundRegistry(player, "totalMinibosses", count)
	end)

	self.Signals.OnBossChanged:Connect(function(player: Player, count: number)
		self:_indexRoundRegistry(player, "totalBosses", count)
	end)

	PlayerEventService.OnPlayerAdded:Connect(function(player: Player)
		self._roundStats[player.UserId] = {
			totalKillsAndAssists = 0,
			totalElites = 0,
			totalMinibosses = 0,
			totalBosses = 0,
			deaths = 0,
			coinsCollected = 0,
		}
	end)

	PlayerEventService.OnPlayerRemoved:Connect(function(player: Player)
		self._roundStats[player.UserId] = nil
	end)
end

function RoundStatisticsService:KnitInit()
	print("RoundStatisticsService Initialized")
end

return RoundStatisticsService
