--!strict
--[[
	Module: Services/RelicUnlockService.lua
	Description:
	The one writer of the Codex and the relic counters (2026-11-06; rules
	in Shared/Data/RelicUnlockData, reads in Shared/Functions/Relic/
	relicUnlocks). Since 2026-11-08 relics unlock by player LEVEL alone
	(RelicUnlockData.ByLevel, read straight off profile.Level), so nothing
	here unlocks a relic any more except /unlockrelics. It keeps three
	profile keys:
	  RelicUnlocks   relics earned beyond the starting pool under the old
	                 rules (still honoured) or by /unlockrelics
	  RelicProgress  Found (relics picked up), Seen (relics shown: offer
	                 cards, merchant shelves, floor fans), Feats (lifetime
	                 counts, kept as stats), CursedBargains
	  Codex          Monsters: lifetime takedowns per mob (0 = met only)

	What feeds it, each through Blitz.OptionalService at call time:
	  * a relic picked up (RelicService.OnRelicsUpdated): Found;
	  * a takedown (MobDeath.RunTakedownRewards, killer and assisters):
	    the Codex count and the Ranged / Arcane / boss takedown counts;
	  * a monster hit for the first time (DamageService): met;
	  * a Perfect Dodge (RelicService), a fresh Status (StatusCondition
	    Service), a committed spell (VFXService): their counts;
	  * a Cursed Shrine bargain (EventService): the bargain count.

	Counter writes are pushed to the client every FLUSH_SECONDS at most
	(the profile is sent whole). The client announces level unlocks by
	diffing profile.Level (RelicUnlockController).
]]

--[ Roblox Services ]--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

--[ Imports ]--

local DataService = require(ServerScriptService.Submodules.Core.Source.Services.DataService)
local DamageService = require(ServerScriptService.Services.DamageService)
local RelicService = require(ServerScriptService.Services.RelicService)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local EnemyTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.EnemyTypes)
local MobData = require(ReplicatedStorage.Submodules.Core.Shared.Data.MobData)
local RelicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicData)
local RelicUnlockData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicUnlockData)
local Log = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Log)
local relicUnlocks = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Relic.relicUnlocks)

--[ Constants ]--

-- The longest a counter write waits before the profile is pushed.
local FLUSH_SECONDS = 3
-- A takedown counts as Ranged / Arcane when the player's last weapon or
-- spell hit on the mob was that kind, this recently (the assist window).
local TAKEDOWN_HIT_WINDOW = 5

--[ Module ]--

local RelicUnlockService = {
	Name = "RelicUnlockService",
	Dependencies = { DataService, RelicService } :: { any },
	_flushScheduled = {} :: { [Player]: boolean },
}

--[ Profile access ]--

-- The loaded profile, or nil while it loads (no write lands on it then).
local function profileOf(player: Player): any?
	local data = DataService:GetProfileData(player)
	if next(data) == nil then
		return nil
	end
	return data
end

-- The profile's RelicProgress, its tables made sure of.
local function progressOf(data: any): any
	local progress = data.RelicProgress
	if type(progress) ~= "table" then
		progress = {}
		data.RelicProgress = progress
	end
	if type(progress.Found) ~= "table" then
		progress.Found = {}
	end
	if type(progress.Seen) ~= "table" then
		progress.Seen = {}
	end
	if type(progress.Feats) ~= "table" then
		progress.Feats = {}
	end
	if type(progress.CursedBargains) ~= "number" then
		progress.CursedBargains = 0
	end
	return progress
end

local function earnedOf(data: any): { [string]: boolean }
	if type(data.RelicUnlocks) ~= "table" then
		data.RelicUnlocks = {}
	end
	return data.RelicUnlocks
end

local function monstersOf(data: any): { [string]: number }
	if type(data.Codex) ~= "table" then
		data.Codex = {}
	end
	if type(data.Codex.Monsters) ~= "table" then
		data.Codex.Monsters = {}
	end
	return data.Codex.Monsters
end

--[ Private ]--

-- Pushes the profile now (an unlock) or within FLUSH_SECONDS (a counter).
function RelicUnlockService._push(self: typeof(RelicUnlockService), player: Player, now: boolean?)
	local function flush()
		self._flushScheduled[player] = nil
		local data = profileOf(player)
		if data and player:IsDescendantOf(Players) then
			DataService:SetProfileValue(player, "RelicProgress", data.RelicProgress)
		end
	end
	if now then
		flush()
		return
	end
	if self._flushScheduled[player] then
		return
	end
	self._flushScheduled[player] = true
	task.delay(FLUSH_SECONDS, flush)
end

--[ Public API ]--

function RelicUnlockService.IsUnlocked(_self: typeof(RelicUnlockService), player: Player, relicName: string): boolean
	return relicUnlocks.isUnlocked(DataService:GetProfileData(player), relicName)
end

-- Unlocks `relicName` for good. True when it was locked until now.
function RelicUnlockService.Unlock(self: typeof(RelicUnlockService), player: Player, relicName: string): boolean
	local data = profileOf(player)
	if not data or not RelicData[relicName] or relicUnlocks.isUnlocked(data, relicName) then
		return false
	end
	earnedOf(data)[relicName] = true
	Log.debug("[RelicUnlockService] " .. player.Name .. " unlocked " .. relicName)
	self:_push(player, true)
	return true
end

-- A relic picked up, in any run: Found (the Codex's discovered list).
function RelicUnlockService.RecordRelicFound(self: typeof(RelicUnlockService), player: Player, relicName: string)
	local data = profileOf(player)
	local relic = RelicData[relicName]
	if not data or not relic or relic.retired then
		return
	end
	local found = progressOf(data).Found
	if found[relicName] then
		return
	end
	found[relicName] = true
	-- Pushed at once: the client toasts the discovery off the snapshot.
	self:_push(player, true)
end

-- Relics shown to the player (an offer's cards, a merchant's shelf, an
-- event's floor fan). Batched: the cards dealt now already chose their
-- badges from the snapshot they arrived with.
function RelicUnlockService.RecordSeen(self: typeof(RelicUnlockService), player: Player, relicNames: { string })
	local data = profileOf(player)
	if not data then
		return
	end
	local seen = progressOf(data).Seen
	local changed = false
	for _, relicName in relicNames do
		if type(relicName) == "string" and RelicData[relicName] and not seen[relicName] then
			seen[relicName] = true
			changed = true
		end
	end
	if changed then
		self:_push(player)
	end
end

-- Adds to a lifetime count (Perfect Dodges, Statuses applied, ...). A
-- stat only since 2026-11-08: no relic unlocks from it.
function RelicUnlockService.AddFeat(self: typeof(RelicUnlockService), player: Player, featId: string, amount: number?)
	local data = profileOf(player)
	if not data or type(featId) ~= "string" then
		return
	end
	local feats = progressOf(data).Feats
	feats[featId] = (tonumber(feats[featId]) or 0) + (amount or 1)
	self:_push(player)
end

-- The first hit on a kind of monster: the Codex lists it as met.
function RelicUnlockService.MarkMonsterSeen(self: typeof(RelicUnlockService), player: Player, mobName: string)
	if not MobData[mobName] then
		return
	end
	local data = profileOf(player)
	if not data then
		return
	end
	local monsters = monstersOf(data)
	if monsters[mobName] == nil then
		monsters[mobName] = 0
		-- Pushed at once: the client toasts the discovery off the snapshot.
		self:_push(player, true)
	end
end

-- A takedown (the killing blow or a live assist) on `model`.
function RelicUnlockService.OnTakedown(self: typeof(RelicUnlockService), player: Player, model: Model)
	local data = profileOf(player)
	if not data then
		return
	end
	local mobName = model.Name
	if MobData[mobName] then
		local monsters = monstersOf(data)
		monsters[mobName] = (monsters[mobName] or 0) + 1
	end

	local kind = DamageService:LastHitKind(model, player.Name, TAKEDOWN_HIT_WINDOW)
	if kind == "Ranged" then
		self:AddFeat(player, "RangedTakedowns")
	elseif kind == "Arcane" then
		self:AddFeat(player, "ArcaneTakedowns")
	end

	if model:GetAttribute(Attributes.EnemyType) == EnemyTypes.Boss then
		self:AddFeat(player, "BossesDefeated")
	end
	self:_push(player)
end

-- A Cursed Shrine bargain accepted: the count (a stat since 2026-11-08;
-- the Cursed relics unlock by level).
function RelicUnlockService.OnCursedBargain(self: typeof(RelicUnlockService), player: Player)
	local data = profileOf(player)
	if not data then
		return
	end
	progressOf(data).CursedBargains += 1
	self:_push(player)
end

-- /unlockrelics: every relic unlocked (`all`), or back to the starting
-- pool with every counter cleared (`reset`).
function RelicUnlockService.DebugSet(_self: typeof(RelicUnlockService), player: Player, all: boolean): boolean
	local data = profileOf(player)
	if not data then
		return false
	end
	local earned = {}
	if all then
		for relicName, relic in RelicData do
			if not relic.retired and not RelicUnlockData.Start[relicName] then
				earned[relicName] = true
			end
		end
	else
		data.RelicProgress = nil
		progressOf(data)
		monstersOf(data)
		table.clear(data.Codex.Monsters)
	end
	data.RelicUnlocks = earned
	DataService:SetProfileValue(player, "RelicUnlocks", earned)
	return true
end

--[ Lifecycle ]--

function RelicUnlockService.Start(self: typeof(RelicUnlockService))
	RelicService.Signals.OnRelicsUpdated:Connect(function(player: Player, relicName: string?, count: number?)
		if type(relicName) == "string" and type(count) == "number" and count > 0 then
			self:RecordRelicFound(player, relicName)
		end
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		self._flushScheduled[player] = nil
	end)
end

return RelicUnlockService
