--!strict
--[[
     Module: EncounterLobbyInterfaceController.lua
     Description:
     UI root for the pre-fight encounter lobby HUD (used by both miniboss and
     final boss). Observes the replicated EncounterLobbyData and renders a
     top-of-screen widget showing the countdown + party-ready state until the
     cinematic fires.
       data == nil                       → hidden
       data == { remainingSeconds, ... } → visible, ticks down each property update
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local DungeonNetwork = require(ReplicatedStorage.Submodules.Core.Source.Network.Dungeon)
local RemoteProperty = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Network.RemoteProperty)
local React = require(ReplicatedStorage.Submodules.Core.Packages.React)
local ReactRoblox = require(ReplicatedStorage.Submodules.Core.Packages["React-Roblox"])

local Container = require(script.ReactComponents.Container)

local INTERFACE_ID = "EncounterLobbyInterfaceController"

export type EncounterLobbyData = {
	kind: "Miniboss" | "Boss",
	remainingSeconds: number,
	totalSeconds: number,
	playersOnPad: number,
	totalPlayers: number,
	accelerated: boolean,
	padPosition: Vector3,
	readyLabel: string?,
}

local EncounterLobbyInterfaceController = {
	Name = "EncounterLobbyInterfaceController",
}

-- The pre-fight lobby countdown, nil when no lobby is active (was
-- EncounterService.EncounterLobbyData).
EncounterLobbyInterfaceController.EncounterLobbyData = RemoteProperty.Client({
	changed = DungeonNetwork.EncounterLobbyDataChanged,
	get = DungeonNetwork.GetEncounterLobbyData,
})

function EncounterLobbyInterfaceController._render(_self: typeof(EncounterLobbyInterfaceController))
	return function()
		local lobbyData, setLobbyData = React.useState(nil :: EncounterLobbyData?)

		React.useEffect(function()
			local disconnect = EncounterLobbyInterfaceController.EncounterLobbyData:Observe(
				-- The wire payload is structural (`kind: string`); EncounterLobbyData narrows it.
				function(data)
					setLobbyData(data :: any)
				end
			)

			return disconnect
		end, {})

		return React.createElement("ScreenGui", {
			ResetOnSpawn = false,
			IgnoreGuiInset = true,
			Name = INTERFACE_ID,
			ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
			ClipToDeviceSafeArea = true,
		}, {
			-- Container takes a generic `data` prop so the same widget pattern
			-- handles both miniboss and boss approach lobbies.
			Container = React.createElement(Container, {
				data = lobbyData,
			}),
		})
	end
end

--[ Lifecycle ]--

function EncounterLobbyInterfaceController.Init(self: typeof(EncounterLobbyInterfaceController))
	local root = ReactRoblox.createRoot(Instance.new("Folder"))
	root:render(ReactRoblox.createPortal(React.createElement(self:_render()), Players.LocalPlayer.PlayerGui))
end

return EncounterLobbyInterfaceController
