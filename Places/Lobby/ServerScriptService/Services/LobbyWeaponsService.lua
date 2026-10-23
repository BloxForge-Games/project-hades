--!strict
--[[
	Module: LobbyWeaponsService.lua
	Description:
	Switches weapons OFF in the hub (2026-10-23). Every character that
	spawns here gets Attributes.WeaponsDisabled = true: the core weapon
	components refuse to start a swing / shot loop while it is set, and the
	server refuses the swing and projectile requests behind them. The
	weapons still equip, weld and animate idle / run as normal -- only the
	attack is gated, so a future dummies / training zone can hand combat
	back by clearing the attribute on the characters inside it
	(SetWeaponsEnabled below) without any of the combat code moving.
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

-- Flips combat for one character. `enabled = true` clears the attribute
-- (a training zone's entry), `false` re-stamps it (its exit / the spawn
-- default).
function LobbyWeaponsService.SetWeaponsEnabled(_self: typeof(LobbyWeaponsService), character: Model, enabled: boolean)
	character:SetAttribute(Attributes.WeaponsDisabled, if enabled then nil else true)
end

--[ Lifecycle ]--

function LobbyWeaponsService.Start(self: typeof(LobbyWeaponsService))
	local function onPlayer(player: Player)
		if player.Character then
			self:SetWeaponsEnabled(player.Character, false)
		end
		player.CharacterAdded:Connect(function(character)
			self:SetWeaponsEnabled(character, false)
		end)
	end
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
	Players.PlayerAdded:Connect(onPlayer)
end

return LobbyWeaponsService
