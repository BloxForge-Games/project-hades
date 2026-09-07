--[[
     Module: EncounterLobbyInterfaceController.lua
     Description:
     UI root for the pre-fight encounter lobby HUD (used by both miniboss and
     final boss). Observes EncounterService.EncounterLobbyData and renders a
     top-of-screen widget showing the countdown + party-ready state until the
     cinematic fires.
       data == nil                       → hidden
       data == { remainingSeconds, ... } → visible, ticks down each property update
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
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
}

local EncounterService

local EncounterLobbyInterfaceController = Knit.CreateController({
	Name = "EncounterLobbyInterfaceController",
})

function EncounterLobbyInterfaceController:_render()
	return function()
		local lobbyData, setLobbyData = React.useState(nil)

		React.useEffect(function()
			local observer = EncounterService.EncounterLobbyData:Observe(function(data: EncounterLobbyData?)
				setLobbyData(data)
			end)

			return function()
				if observer then
					observer:Disconnect()
				end
			end
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

function EncounterLobbyInterfaceController:KnitInit()
	EncounterService = Knit.GetService("EncounterService")

	local root = ReactRoblox.createRoot(Instance.new("Folder"))
	root:render(ReactRoblox.createPortal(React.createElement(self:_render()), Players.LocalPlayer.PlayerGui))
end

return EncounterLobbyInterfaceController
