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

	The multiplier is (1 + 1 x (active players - 1)) x the run's
	difficulty health x the floor's growth (DifficultyData): solo Normal
	floor 1 is 1.5x base (Normal's enemyHealth), and each extra player adds
	one more solo's worth: duo 2x solo, trio 3x, a full party 4x (design call,
	2026-10-25: each extra player adds a whole mob's worth; was half). The same curve
	applies to mobs, minibosses and bosses alike. "Active" is LifeService's count:
	alive or DOWNED (a downed player may yet buy a revive); fully dead
	players no longer count, which is why a party of two fighting a boss
	sees it shrink the moment one of them is truly gone.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local LifeService = require(ServerScriptService.Services.LifeService)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
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

-- The run's difficulty health multiplier; 1 outside a run. DungeonService
-- is reached at call time (this service is a consumer of it).
local function difficultyHealthMultiplier(): number
	local dungeonService = Blitz.OptionalService("DungeonService")
	if not dungeonService then
		return 1
	end
	-- The tier's multiplier x the floor's (DifficultyData's health growth).
	return dungeonService:GetDifficultyScale().enemyHealth * dungeonService:GetFloorMultiplier("health")
end

-- Health added per active player past the first, as a fraction of base.
local HEALTH_PER_EXTRA_PLAYER = 1

-- (1 + 1 x (active players - 1)) x difficulty x floor. `excluding` is a
-- player mid PlayerRemoving, still listed by Players:GetPlayers() while
-- its handlers run.
function EnemyScalingService.GetHealthMultiplier(_self: typeof(EnemyScalingService), excluding: Player?): number
	local extraPlayers = math.max(LifeService:GetActivePlayerCount(excluding) - 1, 0)
	return (1 + HEALTH_PER_EXTRA_PLAYER * extraPlayers) * difficultyHealthMultiplier()
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
	local multiplier = self:GetHealthMultiplier()
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
			if model:GetAttribute(Attributes.HealthScaleMultiplier) == multiplier then
				continue
			end

			local oldMax = humanoid.MaxHealth
			local fraction = if oldMax > 0 then humanoid.Health / oldMax else 1
			local newMax = base * multiplier
			-- Never below 1 HP (a mob must not die of a rescale) and never
			-- above the new maximum.
			local newHealth = math.clamp(newMax * fraction, math.min(1, newMax), newMax)

			model:SetAttribute(Attributes.HealthScaleMultiplier, multiplier)
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
