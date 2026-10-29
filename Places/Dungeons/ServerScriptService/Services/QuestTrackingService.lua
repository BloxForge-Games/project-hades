--!strict
--[[
	Module: QuestTrackingService.lua (Dungeons)
	Description:
	Reports what players do in a run to QuestService (2026-10-28), as the
	stats in Shared/Data/QuestData:

	  Kills / Elites / Minibosses / Bosses
	      RoundStatisticsService's kill-or-assist signals: everyone credited
	      for a kill (the killer and live assisters) counts it.
	  Runs / FlawlessRuns / PartyRuns
	      walking out the exit portal after the boss (OnPlayerExtracted);
	      flawless when the player never went down this run, party when
	      another player was in the server.
	  Floors      every descent for everyone in the server, and the last
	              floor on extraction.
	  Chests      the player who opened the chest.
	  Relics      every relic offer that granted a relic.
	  Dodges      every dodge landed.
	  CoinPickups / ManaPickups
	      each coin or mana drop picked up.

	Every source is optional (resolved at Start), so a missing service
	only stops its own stats.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Blitz = require(ReplicatedStorage.Submodules.Core.Shared.Blitz)
local QuestService = require(ServerScriptService.Submodules.Core.Source.Services.QuestService)
local QuestData = require(ReplicatedStorage.Submodules.Core.Shared.Data.QuestData)
local DropTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.DropTypes)

local Stats = QuestData.Stats

local QuestTrackingService = {
	Name = "QuestTrackingService",
	Dependencies = { QuestService } :: { any },
}

-- Players who went down this run (no flawless clear for them).
QuestTrackingService._wentDown = {} :: { [Player]: boolean }

local function record(player: Player?, stat: string, amount: number?)
	if player and player:IsA("Player") and player.Parent == Players then
		QuestService:Record(player, stat, amount)
	end
end

local function connect(signal: any, handler: (...any) -> ())
	if signal and type(signal.Connect) == "function" then
		signal:Connect(handler)
	end
end

function QuestTrackingService.Start(self: typeof(QuestTrackingService))
	local roundStatistics = Blitz.OptionalService("RoundStatisticsService")
	local dungeonService = Blitz.OptionalService("DungeonService")
	local lifeService = Blitz.OptionalService("LifeService")
	local dropService = Blitz.OptionalService("DropService")
	local relicOfferService = Blitz.OptionalService("RelicOfferService")
	local dodgeService = Blitz.OptionalService("DodgeService")

	if roundStatistics then
		local signals = roundStatistics.Signals
		connect(signals.OnKillOrAssist, function(player: Player)
			record(player, Stats.Kills)
		end)
		connect(signals.OnEliteChanged, function(player: Player)
			record(player, Stats.Elites)
		end)
		connect(signals.OnMinibossChanged, function(player: Player)
			record(player, Stats.Minibosses)
		end)
		connect(signals.OnBossChanged, function(player: Player)
			record(player, Stats.Bosses)
		end)
	end

	if lifeService then
		connect(lifeService.OnPlayerDied, function(player: Player)
			self._wentDown[player] = true
		end)
	end

	if dungeonService then
		local signals = dungeonService.Signals
		connect(signals.OnFloorTeardown, function()
			for _, player in Players:GetPlayers() do
				record(player, Stats.Floors)
			end
		end)
		connect(signals.OnPlayerExtracted, function(player: Player)
			record(player, Stats.Floors)
			record(player, Stats.Runs)
			if not self._wentDown[player] then
				record(player, Stats.FlawlessRuns)
			end
			if #Players:GetPlayers() > 1 then
				record(player, Stats.PartyRuns)
			end
		end)
	end

	if dropService then
		connect(dropService.OnChestCoinsRequested, function(player: Player)
			record(player, Stats.Chests)
		end)
		connect(dropService.OnDropCollected, function(player: Player, dropType: string)
			if dropType == DropTypes.Coins then
				record(player, Stats.CoinPickups)
			elseif dropType == DropTypes.Mana or dropType == DropTypes.SuperMana then
				record(player, Stats.ManaPickups)
			end
		end)
	end

	if relicOfferService then
		connect(relicOfferService.Signals.OnOfferResolved, function(player: Player, granted: any)
			if granted then
				record(player, Stats.Relics)
			end
		end)
	end

	if dodgeService then
		connect(dodgeService.Signals.OnDodgeLanded, function(player: Player)
			record(player, Stats.Dodges)
		end)
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		self._wentDown[player] = nil
	end)
end

return QuestTrackingService
