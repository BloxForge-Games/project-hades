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

	RUN-LENGTH CUT (design call, 2026-10-30): a run's EXP stays what it
	was before floors lost their Miniboss and the mob ladder was trimmed.
	  * A grunt kill (Normal / Elite) is multiplied by the tier's
	    DifficultyData `gruntExpScale` (old mobs per run over new). The
	    fraction is carried per player, so the total is exact rather than
	    rounded away kill by kill.
	  * A Boss on a floor with no Miniboss (DifficultyData.FloorHasMiniboss)
	    also pays the Miniboss's kill EXP.

	LifeService and DungeonService are reached at call time
	(Blitz.OptionalService): this service is a consumer of both.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local ExperienceService =
	require(ServerScriptService.Submodules.Core.Source.Services.DataService.SubServices.ExperienceService)
local ExpRewardData = require(ReplicatedStorage.Submodules.Core.Shared.Data.ExpRewardData)
local DifficultyData = require(ReplicatedStorage.Submodules.Core.Shared.Data.DifficultyData)
local EnemyTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.EnemyTypes)
local Blitz = require(ReplicatedStorage.Submodules.Core.Shared.Blitz)

-- The kill tiers `gruntExpScale` applies to.
local GRUNT_TYPES: { [string]: boolean } = {
	[EnemyTypes.Normal] = true,
	[EnemyTypes.Elite] = true,
}

local ExpRewardService = {
	Name = "ExpRewardService",
	Dependencies = { ExperienceService } :: { any },
	-- Per player: the fraction of a point of EXP not yet granted.
	_carry = {} :: { [Player]: number },
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

-- The pre-cut grant for one kill of `enemyType` (rounded per kill, as
-- it always was), then the run-length cut's correction (see the
-- header). Fractional; _grant carries what does not round.
function ExpRewardService._killExp(self: typeof(ExpRewardService), enemyType: string, bonus: number): number
	local multiplier = self:_multiplier()
	local amount = math.round(ExpRewardData.PerKill[enemyType] * multiplier * bonus)
	local dungeonService = Blitz.OptionalService("DungeonService")
	if not dungeonService or not dungeonService:GetRun() then
		return amount
	end
	local tier = dungeonService:GetDifficultyScale()
	if GRUNT_TYPES[enemyType] then
		return amount * (tier.gruntExpScale or 1)
	end
	if enemyType == EnemyTypes.Boss and not DifficultyData.FloorHasMiniboss(tier, dungeonService:GetFloor()) then
		amount += math.round((ExpRewardData.PerKill[EnemyTypes.Miniboss] or 0) * multiplier * bonus)
	end
	return amount
end

-- Grants `exact` EXP, carrying the fraction to the player's next grant.
function ExpRewardService._grant(self: typeof(ExpRewardService), player: Player, exact: number)
	local total = (self._carry[player] or 0) + exact
	local whole = math.floor(total)
	self._carry[player] = total - whole
	if whole > 0 then
		ExperienceService:GrantExp(player, whole)
	end
end

--[ Public ]--

-- A player killed a mob of `enemyType`: pay the whole living party.
-- `bonus` scales this one kill on top of the run multiplier (a corrupted
-- mob's CorruptionData.RewardMultiplier); default 1.
function ExpRewardService.GrantKill(self: typeof(ExpRewardService), enemyType: string?, bonus: number?)
	if not enemyType or not ExpRewardData.PerKill[enemyType] then
		return
	end
	local amount = self:_killExp(enemyType, bonus or 1)
	for _, player in Players:GetPlayers() do
		if self:_isLiving(player) then
			self:_grant(player, amount)
		end
	end
end

--[ Lifecycle ]--

function ExpRewardService.Start(self: typeof(ExpRewardService))
	Players.PlayerRemoving:Connect(function(player: Player)
		self._carry[player] = nil
	end)
	local dungeonService = Blitz.OptionalService("DungeonService")
	if not dungeonService then
		return
	end
	dungeonService.Signals.OnPlayerExtracted:Connect(function(player: Player)
		ExperienceService:GrantExp(player, math.round(ExpRewardData.ClearBonus * self:_multiplier()))
	end)
end

return ExpRewardService
