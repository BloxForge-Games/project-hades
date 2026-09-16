--!strict
--[[
     Module: EncounterBarInterfaceController.lua
     Description:
     UI root for the encounter HP bar (used by both miniboss and final boss).
     Observes the replicated EncounterData and renders the Container component
     whenever an encounter is active.
       data == nil                                  → hidden
       { kind, name, level, currentHP, maxHP }      → visible, animates HP

     One bar, one controller — `kind` ("Miniboss" | "Boss") is just metadata on
     the payload, available to the Container if it ever wants to differentiate
     theming.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local DungeonNetwork = require(ReplicatedStorage.Submodules.Core.Source.Network.Dungeon)
local RemoteProperty = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Network.RemoteProperty)
local React = require(ReplicatedStorage.Submodules.Core.Packages.React)
local ReactRoblox = require(ReplicatedStorage.Submodules.Core.Packages["React-Roblox"])

local Container = require(script.ReactComponents.Container)

local INTERFACE_ID = "EncounterBarInterfaceController"

export type EncounterData = {
	kind: "Miniboss" | "Boss",
	name: string,
	level: number,
	currentHP: number,
	maxHP: number,
}

local EncounterBarInterfaceController = {
	Name = "EncounterBarInterfaceController",
}

-- The active encounter's HUD data, nil between encounters (was
-- EncounterService.EncounterData).
EncounterBarInterfaceController.EncounterData = RemoteProperty.Client({
	changed = DungeonNetwork.EncounterDataChanged,
	get = DungeonNetwork.GetEncounterData,
})

function EncounterBarInterfaceController._render(_self: typeof(EncounterBarInterfaceController))
	return function()
		local encounterData, setEncounterData = React.useState(nil :: EncounterData?)
		-- True while a boss phase-change cutscene is playing. The Container
		-- slides the bar up off-screen for the duration, then back down.
		local phaseHidden, setPhaseHidden = React.useState(false)

		React.useEffect(function()
			-- The wire payload is structural (`kind: string`); EncounterData narrows it.
			local disconnect = EncounterBarInterfaceController.EncounterData:Observe(function(data)
				setEncounterData(data :: any)
			end)

			-- Hide the bar during boss phase-change cutscenes, reveal it after.
			local phaseStart = DungeonNetwork.EncounterPhaseStart.On(function()
				setPhaseHidden(true)
			end)
			local phaseEnd = DungeonNetwork.EncounterPhaseEnd.On(function()
				setPhaseHidden(false)
			end)

			return function()
				disconnect()
				phaseStart()
				phaseEnd()
			end
		end, {})

		return React.createElement("ScreenGui", {
			ResetOnSpawn = false,
			IgnoreGuiInset = true,
			Name = INTERFACE_ID,
			ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
			ClipToDeviceSafeArea = true,
		}, {
			-- `data` shape is generic (kind / name / level / currentHP / maxHP)
			-- so the same Container handles both miniboss and boss encounters.
			Container = React.createElement(Container, {
				data = encounterData,
				phaseHidden = phaseHidden,
			}),
		})
	end
end

--[ Lifecycle ]--

function EncounterBarInterfaceController.Init(self: typeof(EncounterBarInterfaceController))
	local root = ReactRoblox.createRoot(Instance.new("Folder"))
	root:render(ReactRoblox.createPortal(React.createElement(self:_render()), Players.LocalPlayer.PlayerGui))
end

return EncounterBarInterfaceController
