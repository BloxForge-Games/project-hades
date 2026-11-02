--!strict
--[[
	Module: Services/EnemyScalingService.lua
	Description:
	LIVE mob HP scaling. MobData holds each mob's BASE health; this
	service owns the player multiplier and applies it twice over:

	  * ApplyToMob, at spawn (MobBase:_applyHumanoidProperties): stamps
	    BaseMaxHealth + HealthScaleMultiplier on the model and sets
	    MaxHealth = Health = base * multiplier.
	  * RescaleAll, whenever the ACTIVE player count moves (join, leave,
	    a full death, a revive): every living mob's MaxHealth is recomputed
	    from its BaseMaxHealth and its health PERCENTAGE is preserved, so a
	    mob at 5% stays at 5% and never dies (or heals to full) because the
	    party changed shape.

	The multiplier is (1 + 0.5 x (active players - 1)) x the run's
	difficulty health x the floor's growth (DifficultyData): each extra
	player adds HALF a solo's worth: duo 1.5x solo, trio 2x, a full party
	2.5x (design call, 2026-10-30; it was a whole solo's worth from
	2026-10-25, which with the +2 mobs a chunk per extra player
	(DungeonData mobQueue.perPlayer) left a duo chewing ~30% more HP per
	head than a solo). The same curve applies to mobs, minibosses and
	bosses alike. "Active" is LifeService's count:
	alive or DOWNED (a downed player may yet buy a revive); fully dead
	players no longer count, which is why a party of two fighting a boss
	sees it shrink the moment one of them is truly gone.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local LifeService = require(ServerScriptService.Services.LifeService)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local EnemyTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.EnemyTypes)
local Log = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Log)
local Blitz = require(ReplicatedStorage.Submodules.Core.Shared.Blitz)

local EnemyScalingService = {
	Name = "EnemyScalingService",
	Dependencies = { LifeService } :: { any },
}

--[ Private helpers ]--

-- The live mob container. Nil before the map has built it; a rescale then
-- has nothing to walk.
local function getMobsFolder(): Instance?
	local ignore = workspace:FindFirstChild("IgnoreInstances")
	return ignore and ignore:FindFirstChild("Mobs")
end

--[ Public API ]--

-- The run's difficulty health multiplier for a mob of `enemyType`; 1
-- outside a run. DungeonService is reached at call time (this service is
-- a consumer of it). Grunts (every type but Miniboss and Boss) carry the
-- tier's gruntHealth on top (DifficultyData, 2026-11-01).
local function difficultyHealthMultiplier(enemyType: string?): number
	local dungeonService = Blitz.OptionalService("DungeonService")
	if not dungeonService then
		return 1
	end
	local scale = dungeonService:GetDifficultyScale()
	-- The tier's multiplier x the floor's (DifficultyData's health growth).
	local multiplier = scale.enemyHealth * dungeonService:GetFloorMultiplier("health")
	if enemyType ~= EnemyTypes.Miniboss and enemyType ~= EnemyTypes.Boss then
		multiplier *= scale.gruntHealth or 1
	end
	return multiplier
end

-- Health added per active player past the first, as a fraction of base
-- (1 -> 0.5, 2026-10-30; see the header).
local HEALTH_PER_EXTRA_PLAYER = 0.5

-- (1 + 0.5 x (active players - 1)) x difficulty x floor, for a mob of
-- `enemyType` (the model's EnemyType attribute; nil reads as a grunt).
-- `excluding` is a player mid PlayerRemoving, still listed by
-- Players:GetPlayers() while its handlers run.
function EnemyScalingService.GetHealthMultiplier(
	_self: typeof(EnemyScalingService),
	excluding: Player?,
	enemyType: string?
): number
	local extraPlayers = math.max(LifeService:GetActivePlayerCount(excluding) - 1, 0)
	return (1 + HEALTH_PER_EXTRA_PLAYER * extraPlayers) * difficultyHealthMultiplier(enemyType)
end

-- The model's EnemyType stamp (MobBase, before ApplyToMob), or nil.
local function enemyTypeOf(model: Model): string?
	local value = model:GetAttribute(Attributes.EnemyType)
	return if type(value) == "string" then value else nil
end

-- Spawn-time scaling. `baseHealth` is the MobData number (already
-- resolved if it was a function). Stamps the two attributes RescaleAll
-- keys off and fills the mob to its scaled maximum.
function EnemyScalingService.ApplyToMob(
	self: typeof(EnemyScalingService),
	model: Model,
	humanoid: Humanoid,
	baseHealth: number
)
	local multiplier = self:GetHealthMultiplier(nil, enemyTypeOf(model))
	local scaled = baseHealth * multiplier

	model:SetAttribute(Attributes.BaseMaxHealth, baseHealth)
	model:SetAttribute(Attributes.HealthScaleMultiplier, multiplier)
	humanoid.MaxHealth = scaled
	humanoid.Health = scaled
end

-- Re-derives every living mob's MaxHealth from BaseMaxHealth at the
-- current multiplier, keeping its health fraction. MaxHealth is written
-- BEFORE Health so the HealthChanged listeners (overhead bar,
-- EncounterService's HP stream) read a consistent pair. Mobs already at
-- this multiplier are skipped, so a no-op trigger touches nothing.
function EnemyScalingService.RescaleAll(self: typeof(EnemyScalingService), excluding: Player?)
	local activePlayers = LifeService:GetActivePlayerCount(excluding)
	-- Logged for the grunt case; each mob below gets its own.
	local multiplier = self:GetHealthMultiplier(excluding)

	local rescaled = 0
	local mobs = getMobsFolder()
	if mobs then
		for _, model in mobs:GetChildren() do
			if not model:IsA("Model") then
				continue
			end
			local base = model:GetAttribute(Attributes.BaseMaxHealth)
			if type(base) ~= "number" then
				continue
			end
			local humanoid = model:FindFirstChildOfClass("Humanoid")
			if not humanoid or humanoid.Health <= 0 then
				continue
			end
			local mobMultiplier = self:GetHealthMultiplier(excluding, enemyTypeOf(model))
			if model:GetAttribute(Attributes.HealthScaleMultiplier) == mobMultiplier then
				continue
			end

			local oldMax = humanoid.MaxHealth
			local fraction = if oldMax > 0 then humanoid.Health / oldMax else 1
			local newMax = base * mobMultiplier
			-- Never below 1 HP (a mob must not die of a rescale) and never
			-- above the new maximum.
			local newHealth = math.clamp(newMax * fraction, math.min(1, newMax), newMax)

			model:SetAttribute(Attributes.HealthScaleMultiplier, mobMultiplier)
			humanoid.MaxHealth = newMax
			humanoid.Health = newHealth
			rescaled += 1
		end
	end

	Log.debug(
		("[EnemyScalingService] x%.2f for %d active players; %d mobs rescaled"):format(
			multiplier,
			activePlayers,
			rescaled
		)
	)
end

--[ Lifecycle ]--

function EnemyScalingService.Start(self: typeof(EnemyScalingService))
	Players.PlayerAdded:Connect(function()
		self:RescaleAll()
	end)

	-- The leaver is still in Players:GetPlayers() here, so it is excluded
	-- explicitly rather than trusting handler order against LifeService's
	-- own PlayerRemoving cleanup.
	Players.PlayerRemoving:Connect(function(player: Player)
		self:RescaleAll(player)
	end)

	-- A DOWNED player still counts (they may come back); only the window
	-- closing, and a revive, move the count.
	LifeService.OnPlayerFullyDied:Connect(function()
		self:RescaleAll()
	end)

	LifeService.OnPlayerRevived:Connect(function()
		self:RescaleAll()
	end)
end

return EnemyScalingService
