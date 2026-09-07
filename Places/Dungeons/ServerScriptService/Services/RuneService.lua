--[[
	Module: Server/Services/RuneService.lua
	Description:
	The stat-rune system (element rework). Runes are NOT relics: no
	ownership cap, no distinct-once rule — every copy stacks additively
	with the rest of its kind. Rune machines drop in EVEN dungeon rooms
	(RelicMachineService owns the alternation); the machine dispenses
	physical rune models (Server/Components/Rune picks them up into the
	registry here).

	Registry shape: [userId][runeName][rarity] = count. The SUMS are what
	the rest of the game reads (GetRuneSums):

	  damage            fraction — multiplies OVER the relic damage sum
	                    (DamageService's rune factor).
	  health            fraction — joins the relic-base HP composition.
	  mana              RETIRED, always 0 (rune cut). FLAT points when live.
	                    Historical note: added onto the constant
	                    100 base (MagicService.BASE_MAX_MANA).
	  critChance        FRACTION (PlayerStatsService x100s it onto the
	                    0-100 roll).
	  critDamage        RETIRED, always 0 (rune cut). Kept so consumers
	                    that read it unconditionally still work.

	PlayerStatsService listens to Signals.OnRunesUpdated and re-stamps the
	replicated attributes; nothing else should read the registry raw.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local Signal = require(ReplicatedStorage.Submodules.Core.Packages.Signal)
local RuneNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RuneNames)
local RuneData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RuneData)

local RuneService = Knit.CreateService({
	Name = "RuneService",
	Client = {
		-- Full registry replication for the owner's UI:
		-- { [runeName] = { [rarity] = count } }.
		OnReplicateRunes = Knit.CreateSignal(),
	},
})

RuneService.Signals = {
	OnRunesUpdated = Signal.new(),
}

-- [userId] = { [runeName] = { [rarity] = count } }
RuneService._runeRegistry = {}

--[ Public API ]--

function RuneService:AddRune(player: Player, runeName: string, rarity: string)
	if not RuneData[runeName] then
		warn("[RuneService] Unknown rune: " .. tostring(runeName))
		return
	end
	if not RuneData[runeName].effects[rarity] then
		warn("[RuneService] Rune " .. runeName .. " has no tier for rarity: " .. tostring(rarity))
		return
	end

	local registry = self._runeRegistry[player.UserId]
	if not registry then
		registry = {}
		self._runeRegistry[player.UserId] = registry
	end
	local tiers = registry[runeName]
	if not tiers then
		tiers = {}
		registry[runeName] = tiers
	end
	tiers[rarity] = (tiers[rarity] or 0) + 1

	self.Signals.OnRunesUpdated:Fire(player)
	self.Client.OnReplicateRunes:Fire(player, registry)
end

function RuneService:GetRuneRegistry(player: Player)
	return self._runeRegistry[player.UserId] or {}
end

-- Total copies of one rune (any rarity) — UI convenience.
function RuneService:GetRuneCount(player: Player, runeName: string): number
	local tiers = (self._runeRegistry[player.UserId] or {})[runeName]
	if not tiers then
		return 0
	end
	local count = 0
	for _, n in tiers do
		count += n
	end
	return count
end

-- The summed rune magnitudes for one player — see the header. Abyss
-- doubling applied HERE, once, for every consumer.
function RuneService:GetRuneSums(player: Player)
	local sums = {
		damage = 0,
		health = 0,
		-- RETIRED (2026-08): the Mana and Critical Damage runes were cut
		-- from the pool. These two keys are KEPT and always zero so the
		-- shape of the returned table is unchanged — PlayerStatsService
		-- reads `critDamage` unconditionally, and a nil there would break
		-- the stat totals rather than simply contributing nothing.
		mana = 0,
		critChance = 0,
		critDamage = 0,
	}

	local registry = self._runeRegistry[player.UserId]
	if registry then
		for runeName, tiers in registry do
			local data = RuneData[runeName]
			if not data then
				continue
			end
			for rarity, count in tiers do
				local effect = (data.effects[rarity] or 0) * count
				if runeName == RuneNames.Health then
					sums.health += effect
				elseif runeName == RuneNames.Damage then
					sums.damage += effect
				elseif runeName == RuneNames["Critical Hit Chance"] then
					-- Stored as whole percentage points in RuneData; keep the
					-- sums contract in FRACTIONS.
					sums.critChance += effect / 100
				end
			end
		end
	end

	return sums
end

--[ Lifecycle ]--

function RuneService:KnitStart()
	Players.PlayerRemoving:Connect(function(player: Player)
		self._runeRegistry[player.UserId] = nil
	end)
end

return RuneService
