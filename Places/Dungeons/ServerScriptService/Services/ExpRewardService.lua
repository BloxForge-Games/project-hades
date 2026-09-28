--!strict
--[[
	Module: ExpRewardService.lua
	Description:
	Grants EXP during a dungeon run (values in Shared/Data/ExpRewardData,
	scaled by the run's difficulty). Saved immediately through
	ExperienceService, so a failed run keeps what it earned.

	  * Kills: every mob a player kills pays its tier's EXP to EVERY living
	    party member (MobBase.OnDeath calls GrantKill). Downed, dead and
	    extracted players get nothing for that kill.
	  * Clear: a player who extracts through the exit portal gets the
	    clear bonus (DungeonService.Signals.OnPlayerExtracted).

	LifeService and DungeonService are reached at call time
	(Blitz.OptionalService): this service is a consumer of both.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local ExperienceService =
	require(ServerScriptService.Submodules.Core.Source.Services.DataService.SubServices.ExperienceService)
local ExpRewardData = require(ReplicatedStorage.Submodules.Core.Shared.Data.ExpRewardData)
local Blitz = require(ReplicatedStorage.Submodules.Core.Shared.Blitz)

local ExpRewardService = {
	Name = "ExpRewardService",
	Dependencies = { ExperienceService } :: { any },
}

--[ Private ]--

-- The run's difficulty EXP multiplier; 1 outside a run.
function ExpRewardService._multiplier(_self: typeof(ExpRewardService)): number
	local dungeonService = Blitz.OptionalService("DungeonService")
	return if dungeonService then dungeonService:GetDifficultyScale().exp else 1
end

-- Alive, not downed, still in the run.
function ExpRewardService._isLiving(_self: typeof(ExpRewardService), player: Player): boolean
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return false
	end
	local lifeService = Blitz.OptionalService("LifeService")
	if lifeService and lifeService:IsDeathState(player) then
		return false
	end
	local dungeonService = Blitz.OptionalService("DungeonService")
	if dungeonService and dungeonService:IsPlayerExited(player) then
		return false
	end
	return true
end

--[ Public ]--

-- A player killed a mob of `enemyType`: pay the whole living party.
function ExpRewardService.GrantKill(self: typeof(ExpRewardService), enemyType: string?)
	local base = enemyType and ExpRewardData.PerKill[enemyType]
	if not base then
		return
	end
	local amount = math.round(base * self:_multiplier())
	for _, player in Players:GetPlayers() do
		if self:_isLiving(player) then
			ExperienceService:GrantExp(player, amount)
		end
	end
end

--[ Lifecycle ]--

function ExpRewardService.Start(self: typeof(ExpRewardService))
	local dungeonService = Blitz.OptionalService("DungeonService")
	if not dungeonService then
		return
	end
	dungeonService.Signals.OnPlayerExtracted:Connect(function(player: Player)
		ExperienceService:GrantExp(player, math.round(ExpRewardData.ClearBonus * self:_multiplier()))
	end)
end

return ExpRewardService
