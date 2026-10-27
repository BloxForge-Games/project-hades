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
	  * Answers what a player has unlocked, which RunFlowService uses to
	    clamp the difficulty a party arrives with.

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
local PROFILE_POLL_SECONDS = 0.25

local DungeonProgressService = {
	Name = "DungeonProgressService",
	Dependencies = { DataService } :: { any },
}

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

--[ Lifecycle ]--

function DungeonProgressService.Start(self: typeof(DungeonProgressService))
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
		end
	end)
end

return DungeonProgressService
