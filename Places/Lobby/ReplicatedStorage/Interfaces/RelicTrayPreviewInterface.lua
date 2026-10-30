--!strict
--[[
	Module: RelicTrayPreviewInterface.lua (Lobby)
	Description:
	DEBUG (2026-10-29): shows the dungeon's relic tray in the hub so its
	look can be worked on without starting a run. Turn it off with
	SHOW_IN_LOBBY below; delete this module and the DebugRelicTray entry in
	lobby.project.json when done.

	It mounts the Dungeons place's own tray components (mapped into the
	Lobby as ReplicatedStorage.DebugRelicTray) with SAMPLE relics, so
	nothing here talks to the server: Drop, Sell and Reforge do nothing.
	The toggle sits under the hub menu, and hides with the HUD.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local InterfaceManagerController =
	require(ReplicatedStorage.Submodules.Core.Source.Controllers.InterfaceManagerController)
local React = require(ReplicatedStorage.Submodules.Core.Packages.React)
local ReactRoblox = require(ReplicatedStorage.Submodules.Core.Packages["React-Roblox"])
local Signal = require(ReplicatedStorage.Submodules.Core.Packages.Signal)
local RelicCapData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicCapData)
local RelicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicData)
local InterfaceScopes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.InterfaceScopes)

-- Flip to false to hide the preview.
local SHOW_IN_LOBBY = false

local INTERFACE_ID = "RelicTrayPreviewInterface"
-- How many sample relics the tray holds.
local SAMPLE_COUNT = 6
-- The toggle's height on screen: just under the hub menu's buttons.
local TOGGLE_Y = 0.73

local RelicTrayPreviewInterface = {
	Name = "RelicTrayPreviewInterface",
	Dependencies = { InterfaceManagerController } :: { any },
}

-- A spread of rarities from the relic catalogue, the same every time.
local function sampleRelics(): { hashmap: { [string]: number }, list: { string } }
	local byRarity: { [string]: { string } } = {}
	local rarities: { string } = {}
	for name, info in RelicData do
		if type(info) == "table" and type(info.rarity) == "string" then
			if not byRarity[info.rarity] then
				byRarity[info.rarity] = {}
				table.insert(rarities, info.rarity)
			end
			table.insert(byRarity[info.rarity], name)
		end
	end
	table.sort(rarities)
	for _, names in byRarity do
		table.sort(names)
	end
	local list: { string } = {}
	local round = 1
	while #list < SAMPLE_COUNT do
		local added = false
		for _, rarity in rarities do
			local name = byRarity[rarity][round]
			if name and #list < SAMPLE_COUNT then
				table.insert(list, name)
				added = true
			end
		end
		if not added then
			break
		end
		round += 1
	end
	local hashmap: { [string]: number } = {}
	for _, name in list do
		hashmap[name] = 1
	end
	return { hashmap = hashmap, list = list }
end

function RelicTrayPreviewInterface.Start(_self: typeof(RelicTrayPreviewInterface))
	local components = ReplicatedStorage:FindFirstChild("DebugRelicTray")
	if not SHOW_IN_LOBBY or not components then
		return
	end
	local Container = (require :: any)(components:WaitForChild("Container"))

	local setVisible = Signal.new()
	local toggleVisible = Signal.new()
	InterfaceManagerController:Register(INTERFACE_ID, {
		scope = InterfaceScopes.HUD,
		restoreOnScopeOpen = true,
		onOpen = function()
			toggleVisible:Fire(true)
		end,
		onClose = function()
			toggleVisible:Fire(false)
			setVisible:Fire(false)
		end,
	})

	local relics = sampleRelics()
	local app = React.createElement("ScreenGui", {
		DisplayOrder = 60,
		Name = INTERFACE_ID,
		ResetOnSpawn = false,
		ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	}, {
		Container = React.createElement(Container, {
			Visible = true,
			relicData = relics,
			relicSlots = RelicCapData.DefaultSlots,
			toggleY = TOGGLE_Y,
			setVisibleSignal = setVisible,
			toggleVisibleSignal = toggleVisible,
			onDropRelic = function(): boolean
				return false
			end,
			onSellRelic = function(): number
				return 0
			end,
			onReforgeRelic = function(): boolean
				return false
			end,
		}),
	})

	local root = ReactRoblox.createRoot(Instance.new("Folder"))
	root:render(ReactRoblox.createPortal(app, Players.LocalPlayer.PlayerGui))
end

return RelicTrayPreviewInterface
