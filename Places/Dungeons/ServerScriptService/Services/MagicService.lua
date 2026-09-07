--[[
     Author(s): 
     Module: MagicService.lua
     Description:
]]

--[ Roblox Services ]--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--[ Exports & Types & Defaults ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local combatProximity = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Combat.combatProximity)

local MagicService = Knit.CreateService({
	Name = "MagicService",
	Client = { MagicData = Knit.CreateProperty() },

	_playerMagicRegistry = {},
	_playerMagicCooldownRegistry = {},
})

--[ Imports ]--

local PlayerEventService

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
-- to reason about. Fired from KnitStart; loop runs for the lifetime
-- of the server (no shutdown hook needed since it's a daemon thread).
--
-- Guards against players whose magic data hasn't been initialized
-- yet (joined mid-tick) by reading GetPlayerMagicData and bailing on
-- nil. Players whose mana is already at max no-op early so we don't
-- burn cycles firing identical SetPlayerMagicData writes.
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
function MagicService:_isPlayerInCombat(player: Player): boolean
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return false
	end
	return combatProximity.isNearLivingZombie(hrp.Position)
end

function MagicService:_runPassiveManaRegenLoop()
	task.spawn(function()
		while true do
			task.wait(PASSIVE_MANA_REGEN_INTERVAL)
			for _, player in Players:GetPlayers() do
				local data = self:GetPlayerMagicData(player)
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
				self:SetPlayerMagicData(player, newMana, data.maxMana)
			end
		end
	end)
end

-- Baseline maximum mana before relic bonuses. PlayerStatsService's
-- RecomputeMana adds the flat relic total on top of this — keep it as
-- the single source so the two can't drift.
MagicService.BASE_MAX_MANA = 100

--[ Public Functions ]--

function MagicService:SetPlayerMagicLastUsed(player: Player, vfxName: string, lastUsed: number)
	if self._playerMagicCooldownRegistry[player][vfxName] == nil then
		self._playerMagicCooldownRegistry[player][vfxName] = {
			lastUsed = 0,
			cooldown = 0,
		}
	end

	self._playerMagicCooldownRegistry[player][vfxName].lastUsed = lastUsed
end

function MagicService:SetPlayerMagicCooldown(player: Player, vfxName: string, cooldown: number)
	if self._playerMagicCooldownRegistry[player][vfxName] == nil then
		self._playerMagicCooldownRegistry[player][vfxName] = {
			lastUsed = 0,
			cooldown = 0,
		}
	end

	self._playerMagicCooldownRegistry[player][vfxName].cooldown = cooldown
end

function MagicService:GetPlayerMagicLastUsed(player: Player, vfxName: string)
	if self._playerMagicCooldownRegistry[player][vfxName] == nil then
		self._playerMagicCooldownRegistry[player][vfxName] = {
			lastUsed = 0,
			cooldown = 0,
		}
	end

	return self._playerMagicCooldownRegistry[player][vfxName].lastUsed
end

function MagicService:GetPlayerMagicCooldown(player: Player, vfxName: string)
	if self._playerMagicCooldownRegistry[player][vfxName] == nil then
		self._playerMagicCooldownRegistry[player][vfxName] = {
			lastUsed = 0,
			cooldown = 0,
		}
	end

	return self._playerMagicCooldownRegistry[player][vfxName].cooldown
end

-- Overcharged is NO LONGER granted here. It used to fire whenever mana hit
-- full while holding Korblox Spell Book, but that relic was redesigned to
-- "+25 Maximum Mana / Spellburst also grants +25% Cooldown Reduction" and no
-- longer touches Overcharged at all. Its sources are now proc-based —
-- Korblox Mage Staff on cast, Lightblox Jar on mana-orb pickup — so
-- Overcharged is something you build toward rather than something a full
-- mana bar hands you for free.
function MagicService:SetPlayerMagicData(player: Player, mana: number, maxMana: number)
	self.Client.MagicData:SetFor(player, { mana = mana, maxMana = maxMana })
	self:_stampManaAttributes(player)
end

-- Mirror the current mana onto the character as replicated attributes so
-- every client can draw it (ManaBillboardGui). See Attributes.Mana.
function MagicService:_stampManaAttributes(player: Player)
	local character = player.Character
	local data = self.Client.MagicData:GetFor(player)
	if not character or not data then
		return
	end
	character:SetAttribute(Attributes.Mana, data.mana)
	character:SetAttribute(Attributes.MaxMana, data.maxMana)
end

function MagicService:GetPlayerMagicData(player: Player): table
	if self.Client.MagicData:GetFor(player) == nil then
		return nil
	end

	return table.clone(self.Client.MagicData:GetFor(player))
end

--[ Initializers ]--

function MagicService:KnitStart()
	PlayerEventService = Knit.GetService("PlayerEventService")

	PlayerEventService.OnPlayerAdded:Connect(function(player: Player)
		self:SetPlayerMagicData(player, self.BASE_MAX_MANA, self.BASE_MAX_MANA)

		self._playerMagicCooldownRegistry[player] = {}
	end)

	-- A fresh character has no attributes: re-stamp the current mana onto it
	-- (the property is per-PLAYER and survives respawn, the character doesn't).
	PlayerEventService.OnCharacterAdded:Connect(function(player: Player, _character: Model)
		self:_stampManaAttributes(player)
	end)

	PlayerEventService.OnPlayerRemoved:Connect(function(player: Player)
		self._playerMagicRegistry[player] = nil
		self._playerMagicCooldownRegistry[player] = nil
	end)

	-- Passive 1%/sec regen for every player. Runs as a daemon thread for
	-- the lifetime of the server; spawned once here. Regen is a fraction of
	-- maxMana, so a +Maximum Mana relic speeds up absolute refill too.
	self:_runPassiveManaRegenLoop()
end

function MagicService:KnitInit() end

return MagicService
