--!strict
--[[
	Module: DungeonProgressService.lua
	Description:
	The profile's per-dungeon progress (DataTemplate DungeonProgress, rules
	in Shared/Functions/Dungeon/dungeonProgress):

	  * Records a clear for every player still in the server when the
	    run's final boss falls (DungeonService.Signals.OnFinalDungeonCompleted):
	    clear count, highest cleared rank, the Keystone on a Hard-or-
	    above clear, and the tier's Dungeon Mastery XP (MasteryData).
	  * Pays the tier's miniboss / elite Mastery XP to the player credited
	    with the kill or assist (RoundStatisticsService's OnMinibossChanged
	    / OnEliteChanged), 2026-10-30.
	  * Answers what a player has unlocked, which RunFlowService uses to
	    clamp the difficulty a party arrives with.
	  * Keeps the profile's RUN HISTORY (DataTemplate RunHistory,
	    2026-10-31): one row per run a player finishes here, cleared or
	    not, newest first, capped at RUN_HISTORY_LIMIT. The Profile window
	    lists them. A clear is recorded from OnFinalDungeonCompleted; a
	    loss from the full death (LifeService.OnPlayerFullyDied) or the
	    leave (PlayerEventService.OnPlayerLeaving) that ends the run for
	    that player, once per run per player.

	DungeonService is reached at call time (Blitz.OptionalService): this
	service is a consumer of it.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local DataService = require(ServerScriptService.Submodules.Core.Source.Services.DataService)
local DifficultyData = require(ReplicatedStorage.Submodules.Core.Shared.Data.DifficultyData)
local MasteryData = require(ReplicatedStorage.Submodules.Core.Shared.Data.MasteryData)
local dungeonProgress = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Dungeon.dungeonProgress)
local Blitz = require(ReplicatedStorage.Submodules.Core.Shared.Blitz)
local Log = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Log)

local PROGRESS_KEY = "DungeonProgress"
local HISTORY_KEY = "RunHistory"
-- Rows kept per profile (the Profile window shows this many).
local RUN_HISTORY_LIMIT = 5
local PROFILE_POLL_SECONDS = 0.25

local DungeonProgressService = {
	Name = "DungeonProgressService",
	Dependencies = { DataService } :: { any },
}

-- The run clock and who already has a history row for this run.
DungeonProgressService._runStartedAt = nil :: number?
DungeonProgressService._historyRecorded = {} :: { [number]: boolean }

--[ Public ]--

-- The player's profile, waiting up to `timeout` seconds for it to load.
function DungeonProgressService.WaitForProfile(
	_self: typeof(DungeonProgressService),
	player: Player,
	timeout: number
): { [string]: any }?
	-- GetProfileData returns an EMPTY table (never nil) until the profile
	-- loads, so "loaded" is read off the template's Version field.
	local function loaded(): { [string]: any }?
		local profile = DataService:GetProfileData(player)
		return if profile.Version ~= nil then profile else nil
	end
	local waited = 0
	local profile = loaded()
	while not profile and player.Parent and waited < timeout do
		waited += task.wait(PROFILE_POLL_SECONDS)
		profile = loaded()
	end
	return profile
end

-- Highest DifficultyData rank `player` may start `dungeonId` at. Nil when
-- their profile did not load within `timeout`.
function DungeonProgressService.GetHighestUnlockedRank(
	self: typeof(DungeonProgressService),
	player: Player,
	dungeonId: string,
	timeout: number
): number?
	local profile = self:WaitForProfile(player, timeout)
	if not profile then
		return nil
	end
	return dungeonProgress.getHighestUnlockedRank(profile[PROGRESS_KEY], dungeonId)
end

--[ Private ]--

function DungeonProgressService._recordClear(
	_self: typeof(DungeonProgressService),
	player: Player,
	dungeonId: string,
	rank: number,
	difficulty: string
)
	local profile = DataService:GetProfileData(player)
	if not profile then
		return
	end
	local progress = profile[PROGRESS_KEY]
	if type(progress) ~= "table" then
		progress = {}
	end
	local keystone = dungeonProgress.recordClear(progress, dungeonId, rank)
	-- Dungeon Mastery: the clear pays the tier's XP into the same entry.
	-- The level is derived, so a level-up is just the two reads differing.
	local masteryXp = MasteryData.XpForClear(difficulty)
	local masteryBefore, masteryAfter = dungeonProgress.addMasteryXp(progress, dungeonId, masteryXp)
	-- Written back through DataService so the change pushes and saves.
	DataService:SetProfileValue(player, PROGRESS_KEY, progress)
	Log.debug(
		("[DungeonProgressService] %s cleared %s at rank %d%s; +%d Mastery XP (level %d -> %d)"):format(
			player.Name,
			dungeonId,
			rank,
			if keystone then " -- Keystone earned" else "",
			masteryXp,
			masteryBefore,
			masteryAfter
		)
	)
end

-- Appends this run's row to `player`'s RunHistory, once per run: the
-- dungeon, the difficulty, whether it was cleared, how long it took
-- (nil when the run clock never started) and when it ended.
function DungeonProgressService._recordRun(
	self: typeof(DungeonProgressService),
	player: Player,
	dungeonId: string,
	difficulty: string,
	cleared: boolean
)
	if self._historyRecorded[player.UserId] then
		return
	end
	local profile = DataService:GetProfileData(player)
	if not profile or profile.Version == nil then
		return
	end
	self._historyRecorded[player.UserId] = true
	local history = profile[HISTORY_KEY]
	if type(history) ~= "table" then
		history = {}
	end
	local now = os.time()
	table.insert(history, 1, {
		DungeonId = dungeonId,
		Difficulty = difficulty,
		Cleared = cleared,
		Seconds = if self._runStartedAt then math.max(now - self._runStartedAt, 0) else nil,
		EndedAt = now,
	})
	while #history > RUN_HISTORY_LIMIT do
		table.remove(history)
	end
	DataService:SetProfileValue(player, HISTORY_KEY, history)
end

-- The active run's dungeon id and difficulty, or nil outside a run.
local function activeRun(): (string?, string?)
	local dungeonService = Blitz.OptionalService("DungeonService")
	local dungeon = dungeonService and dungeonService:GetActiveDungeon()
	local run = dungeonService and dungeonService:GetRun()
	if not dungeon or not run then
		return nil, nil
	end
	return dungeon.id, run.difficulty
end

-- A miniboss or elite kill / assist by `player` pays `xpFor(difficulty)`
-- of Mastery XP into the active dungeon's entry.
function DungeonProgressService._awardKillXp(
	_self: typeof(DungeonProgressService),
	player: Player,
	xpFor: (string) -> number
)
	local dungeonService = Blitz.OptionalService("DungeonService")
	local dungeon = dungeonService and dungeonService:GetActiveDungeon()
	local run = dungeonService and dungeonService:GetRun()
	if not dungeon or not run or player.Parent ~= Players then
		return
	end
	local xp = xpFor(run.difficulty)
	if xp <= 0 then
		return
	end
	local profile = DataService:GetProfileData(player)
	if not profile or profile.Version == nil then
		return
	end
	local progress = profile[PROGRESS_KEY]
	if type(progress) ~= "table" then
		progress = {}
	end
	dungeonProgress.addMasteryXp(progress, dungeon.id, xp)
	DataService:SetProfileValue(player, PROGRESS_KEY, progress)
end

--[ Lifecycle ]--

function DungeonProgressService.Start(self: typeof(DungeonProgressService))
	local roundStatistics = Blitz.OptionalService("RoundStatisticsService")
	if roundStatistics and roundStatistics.Signals then
		roundStatistics.Signals.OnMinibossChanged:Connect(function(player: Player)
			self:_awardKillXp(player, MasteryData.XpForMiniboss)
		end)
		roundStatistics.Signals.OnEliteChanged:Connect(function(player: Player)
			self:_awardKillXp(player, MasteryData.XpForElite)
		end)
	end

	local dungeonService = Blitz.OptionalService("DungeonService")
	if not dungeonService then
		return
	end
	dungeonService.Signals.OnFinalDungeonCompleted:Connect(function(dungeon, run)
		if not dungeon or not run then
			return
		end
		local rank = DifficultyData.Rank(run.difficulty)
		if not rank then
			return
		end
		for _, player in Players:GetPlayers() do
			self:_recordClear(player, dungeon.id, rank, run.difficulty)
			self:_recordRun(player, dungeon.id, run.difficulty, true)
		end
	end)

	-- The run clock: the first floor's ready signal of a run starts it
	-- (OnRunStarted where the service fires it, OnFloorReady otherwise), and
	-- the history rows reset with it.
	local function startClock()
		if self._runStartedAt == nil then
			self._runStartedAt = os.time()
			self._historyRecorded = {}
		end
	end
	if dungeonService.Signals.OnRunStarted then
		dungeonService.Signals.OnRunStarted:Connect(startClock)
	end
	if dungeonService.Signals.OnFloorReady then
		dungeonService.Signals.OnFloorReady:Connect(startClock)
	end

	-- A loss: the full death that ends the run for this player, or a leave
	-- before the clear. After the clear both are no-ops (the row exists).
	local lifeService = Blitz.OptionalService("LifeService")
	if lifeService and lifeService.OnPlayerFullyDied then
		lifeService.OnPlayerFullyDied:Connect(function(player: Player)
			local dungeonId, difficulty = activeRun()
			if dungeonId and difficulty and not (dungeonService:IsRunCleared() == true) then
				self:_recordRun(player, dungeonId, difficulty, false)
			end
		end)
	end
	local playerEventService = Blitz.OptionalService("PlayerEventService")
	if playerEventService and playerEventService.OnPlayerLeaving then
		playerEventService.OnPlayerLeaving:Connect(function(player: Player)
			local dungeonId, difficulty = activeRun()
			if dungeonId and difficulty and not (dungeonService:IsRunCleared() == true) then
				self:_recordRun(player, dungeonId, difficulty, false)
			end
			self._historyRecorded[player.UserId] = nil
		end)
	end
end

return DungeonProgressService
