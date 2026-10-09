--!strict
--[[
     Author(s): 
     Module: ArcaneService.lua
     Description:
]]

--[ Roblox Services ]--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

--[ Exports & Types & Defaults ]--

local PlayerEventService = require(ServerScriptService.Submodules.Core.Source.Services.PlayerEventService)
local PlayerNetwork = require(ServerScriptService.Submodules.Core.Source.Network.Player)
local RemoteProperty = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Network.RemoteProperty)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local combatProximity = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Combat.combatProximity)

local ArcaneService = {
	Name = "ArcaneService",
	Dependencies = { PlayerEventService } :: { any },

	_playerArcaneRegistry = {},
	_playerArcaneCooldownRegistry = {},
}

-- Mana / max mana per player, replicated (was a replicated property).
ArcaneService._arcaneDataProperty = RemoteProperty.Server({
	changed = PlayerNetwork.ArcaneDataChanged,
	get = PlayerNetwork.GetArcaneData,
}, nil)

--[ Imports ]--

--[ Constants ]--

-- Passive mana regeneration. Every tick, each IN-COMBAT player gains
-- (PASSIVE_MANA_REGEN_RATE * maxMana) mana, clamped to maxMana.
-- 0.01 = 1% of max per tick; INTERVAL = 1s means 1%/sec → 100% in
-- 100 seconds from empty. Tunable here without touching the loop.
--
-- COMBAT-ONLY (design-locked): mana is a combat resource, so it only
-- flows while there is a fight to spend it on. "In combat" is
-- PROXIMITY to living zombies — the same rule that dims the
-- player's ground relics — so the bar starts moving exactly when
-- the game already tells them they are in a fight. Away from enemies
-- the bar holds still and mana orbs (and Korblox Mage Staff hits)
-- become the only way to climb.
local PASSIVE_MANA_REGEN_RATE = 0.01
local PASSIVE_MANA_REGEN_INTERVAL = 0.5

--[ Properties ]--

--[ Private Functions ]--

-- Single shared tick that applies passive regen to every player. One
-- task.wait loop rather than per-player threads — cheaper and easier
-- to reason about. Fired from Start; loop runs for the lifetime
-- of the server (no shutdown hook needed since it's a daemon thread).
--
-- Guards against players whose arcane data hasn't been initialized
-- yet (joined mid-tick) by reading GetPlayerArcaneData and bailing on
-- nil. Players whose mana is already at max no-op early so we don't
-- burn cycles firing identical SetPlayerArcaneData writes.
-- True while a living zombie is within combatProximity.RADIUS of the
-- player — the SAME check that drives the client's InCombat
-- attribute and the relic dim, so regen and that visual cue switch
-- together.
--
-- Deliberately NOT read off the character's InCombat attribute: that
-- is written by Client/Controllers/InCombatController, and client-set
-- attributes never replicate to the server. Running the shared check
-- here keeps the server authoritative over what it grants.
--
-- Replaces a room-based gate (spawn queue live / room roster
-- non-empty), which regenerated anywhere inside an uncleared room —
-- including well away from the fight, where the relics had already
-- un-dimmed.
function ArcaneService._isPlayerInCombat(_self: typeof(ArcaneService), player: Player): boolean
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return false
	end
	return combatProximity.isNearLivingZombie(hrp.Position)
end

function ArcaneService._runPassiveManaRegenLoop(self: typeof(ArcaneService))
	task.spawn(function()
		while true do
			task.wait(PASSIVE_MANA_REGEN_INTERVAL)
			for _, player in Players:GetPlayers() do
				local data = self:GetPlayerArcaneData(player)
				if data == nil then
					continue
				end

				if not data or not data.mana or not data.maxMana then
					continue
				end
				if data.mana >= data.maxMana then
					continue -- already topped off — skip the write
				end
				if not self:_isPlayerInCombat(player) then
					continue -- out of combat: the bar holds still
				end
				local regenAmount = data.maxMana * PASSIVE_MANA_REGEN_RATE
				local newMana = math.min(data.mana + regenAmount, data.maxMana)
				self:SetPlayerArcaneData(player, newMana, data.maxMana)
			end
		end
	end)
end

-- Baseline maximum mana before relic bonuses. PlayerStatsService's
-- RecomputeMana adds the flat relic total on top of this — keep it as
-- the single source so the two can't drift.
ArcaneService.BASE_MAX_MANA = 100

--[ Public Functions ]--

function ArcaneService.SetPlayerArcaneLastUsed(
	self: typeof(ArcaneService),
	player: Player,
	vfxName: string,
	lastUsed: number
)
	if self._playerArcaneCooldownRegistry[player][vfxName] == nil then
		self._playerArcaneCooldownRegistry[player][vfxName] = {
			lastUsed = 0,
			cooldown = 0,
		}
	end

	self._playerArcaneCooldownRegistry[player][vfxName].lastUsed = lastUsed
end

function ArcaneService.SetPlayerArcaneCooldown(
	self: typeof(ArcaneService),
	player: Player,
	vfxName: string,
	cooldown: number
)
	if self._playerArcaneCooldownRegistry[player][vfxName] == nil then
		self._playerArcaneCooldownRegistry[player][vfxName] = {
			lastUsed = 0,
			cooldown = 0,
		}
	end

	self._playerArcaneCooldownRegistry[player][vfxName].cooldown = cooldown
end

function ArcaneService.GetPlayerArcaneLastUsed(self: typeof(ArcaneService), player: Player, vfxName: string)
	if self._playerArcaneCooldownRegistry[player][vfxName] == nil then
		self._playerArcaneCooldownRegistry[player][vfxName] = {
			lastUsed = 0,
			cooldown = 0,
		}
	end

	return self._playerArcaneCooldownRegistry[player][vfxName].lastUsed
end

function ArcaneService.GetPlayerArcaneCooldown(self: typeof(ArcaneService), player: Player, vfxName: string)
	if self._playerArcaneCooldownRegistry[player][vfxName] == nil then
		self._playerArcaneCooldownRegistry[player][vfxName] = {
			lastUsed = 0,
			cooldown = 0,
		}
	end

	return self._playerArcaneCooldownRegistry[player][vfxName].cooldown
end

-- Overcharged is NO LONGER granted here. It used to fire whenever mana hit
-- full while holding Korblox Spell Book, but that relic was redesigned to
-- "+25 Maximum Mana / Spellburst also grants +25% Cooldown Reduction" and no
-- longer touches Overcharged at all. Its sources are now proc-based —
-- Korblox Mage Staff on cast, Lightblox Jar on mana-orb pickup — so
-- Overcharged is something you build toward rather than something a full
-- mana bar hands you for free.
function ArcaneService.SetPlayerArcaneData(self: typeof(ArcaneService), player: Player, mana: number, maxMana: number)
	self._arcaneDataProperty:SetFor(player, { mana = mana, maxMana = maxMana })
	self:_stampManaAttributes(player)
end

-- Mirror the current mana onto the character as replicated attributes so
-- every client can draw it (ManaBillboardGui). See Attributes.Mana.
function ArcaneService._stampManaAttributes(self: typeof(ArcaneService), player: Player)
	local character = player.Character
	local data = self._arcaneDataProperty:GetFor(player)
	if not character or not data then
		return
	end
	character:SetAttribute(Attributes.Mana, data.mana)
	character:SetAttribute(Attributes.MaxMana, data.maxMana)
end

-- Returns nil before OnPlayerAdded has seeded the player's data. The
-- declared return type stays non-optional because several callers index
-- the result directly; nil-check where a mid-join race is possible.
-- nil until the player's arcane data has been seeded (join-frame callers).
function ArcaneService.GetPlayerArcaneData(self: typeof(ArcaneService), player: Player): { [any]: any }?
	local data = self._arcaneDataProperty:GetFor(player)
	if data == nil then
		return nil
	end

	return table.clone(data)
end

--[ Initializers ]--

function ArcaneService.Start(self: typeof(ArcaneService))
	PlayerEventService.OnPlayerAdded:Connect(function(player: Player)
		self:SetPlayerArcaneData(player, self.BASE_MAX_MANA, self.BASE_MAX_MANA)

		self._playerArcaneCooldownRegistry[player] = {}
	end)

	-- A fresh character has no attributes: re-stamp the current mana onto it
	-- (the property is per-PLAYER and survives respawn, the character doesn't).
	PlayerEventService.OnCharacterAdded:Connect(function(player: Player, _character: Model)
		self:_stampManaAttributes(player)
	end)

	PlayerEventService.OnPlayerRemoved:Connect(function(player: Player)
		self._playerArcaneRegistry[player] = nil
		self._playerArcaneCooldownRegistry[player] = nil
	end)

	-- Passive 1%/sec regen for every player. Runs as a daemon thread for
	-- the lifetime of the server; spawned once here. Regen is a fraction of
	-- maxMana, so a +Maximum Mana relic speeds up absolute refill too.
	self:_runPassiveManaRegenLoop()
end

return ArcaneService
