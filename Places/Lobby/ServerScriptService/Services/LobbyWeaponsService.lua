--!strict
--[[
	Module: LobbyWeaponsService.lua
	Description:
	Switches RANGED weapons off in the hub. Every character that spawns here
	gets Attributes.RangedWeaponsDisabled = true: the core ProjectileWeapon
	refuses to start a shot loop while it is set. Melee is LEFT ALONE
	(2026-10-24) -- swinging a sword in the hub is harmless and reads as
	alive, where a bullet has nothing to hit and carries into the NPCs and
	the queue.

	Weapons still equip, weld and animate idle / run as normal; only the
	shot is gated. A dummies / training zone can hand ranged combat back by
	clearing the attribute on the characters inside it (SetRangedEnabled
	below), or switch combat off wholesale with SetWeaponsEnabled, without
	any of the combat code moving.
]]

--[ Roblox Services ]--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--[ Imports ]--

local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)

--[ Service ]--

local LobbyWeaponsService = {
	Name = "LobbyWeaponsService",
	Dependencies = {} :: { any },
}

--[ Public ]--

-- Flips ALL combat for one character -- melee included. Not used on spawn
-- any more; kept for a zone that wants the hub's old no-combat rule.
function LobbyWeaponsService.SetWeaponsEnabled(_self: typeof(LobbyWeaponsService), character: Model, enabled: boolean)
	character:SetAttribute(Attributes.WeaponsDisabled, if enabled then nil else true)
end

-- Flips RANGED combat for one character. `enabled = true` clears the
-- attribute (a shooting range's entry), `false` re-stamps it (its exit /
-- the spawn default).
function LobbyWeaponsService.SetRangedEnabled(_self: typeof(LobbyWeaponsService), character: Model, enabled: boolean)
	character:SetAttribute(Attributes.RangedWeaponsDisabled, if enabled then nil else true)
end

--[ Lifecycle ]--

function LobbyWeaponsService.Start(self: typeof(LobbyWeaponsService))
	-- Ranged off, melee on. SetWeaponsEnabled(true) is called explicitly
	-- rather than left implicit: a character that walked out of a zone
	-- holding the all-combat flag would otherwise keep it across a respawn.
	local function arm(character: Model)
		self:SetWeaponsEnabled(character, true)
		self:SetRangedEnabled(character, false)
	end

	local function onPlayer(player: Player)
		if player.Character then
			arm(player.Character)
		end
		player.CharacterAdded:Connect(arm)
	end
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
	Players.PlayerAdded:Connect(onPlayer)
end

return LobbyWeaponsService
