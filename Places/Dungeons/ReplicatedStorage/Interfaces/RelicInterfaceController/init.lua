--!strict
--[[
     Module: RelicInterfaceController.lua
     Description:
     UI root / React bridge
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

--[ Imports ]--

local RelicController = require(ReplicatedStorage.Controllers.RelicController)
local InterfaceManagerController =
	require(ReplicatedStorage.Submodules.Core.Source.Controllers.InterfaceManagerController)
local RelicNetwork = require(ReplicatedStorage.Submodules.Core.Source.Network.Relic)
local React = require(ReplicatedStorage.Submodules.Core.Packages.React)
local ReactRoblox = require(ReplicatedStorage.Submodules.Core.Packages["React-Roblox"])
local Signal = require(ReplicatedStorage.Submodules.Core.Packages.Signal)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local InterfaceScopes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.InterfaceScopes)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local RelicCapData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicCapData)

local Container = require(script.ReactComponents.Container)

-- EventController requires this module at load, so this side reaches it
-- lazily: required on first use, once both modules exist.
local eventControllerLazy: any = nil
local function getEventController(): any
	if eventControllerLazy == nil then
		eventControllerLazy = (require :: any)(ReplicatedStorage.Controllers.EventController)
	end
	return eventControllerLazy
end

local INTERFACE_ID = "RelicInterfaceController"

-- The run's OPEN relic slot count, stamped on the Player by RelicService.
-- The default is only a pre-stamp fallback: the attribute lands with the
-- relic registry on join, before the tray is ever opened.
local function readRelicSlots(): number
	local slots = Players.LocalPlayer:GetAttribute(Attributes.RelicSlots)
	return if typeof(slots) == "number" then slots else RelicCapData.DefaultSlots
end

export type RelicList = {
	[RelicNames.RelicNames]: number,
}

--[ App Component ]--

local RelicInterfaceController = {
	Name = "RelicInterfaceController",
	Dependencies = { RelicController, InterfaceManagerController } :: { any },
}

RelicInterfaceController.Signals = {
	OnPulseGradient = Signal.new(),
	-- (visible: boolean) — drives the Container's slide-out. This interface
	-- had no visibility API at all before (Visible was hardcoded true and
	-- the panel was only ever toggled by its own button), so registering it
	-- in a scope meant giving it one. Passed DOWN to Container as a prop
	-- rather than required there, which would be a circular require.
	SetVisible = Signal.new(),
	-- (active: boolean) — the Merchant's sell session. True lights the
	-- tray's Sell button; Container flips it false itself whenever the
	-- tray closes, so a session can never outlive the window.
	SetSellMode = Signal.new(),
	-- (active: boolean) — the Forge's reforge session. Same shape as
	-- SetSellMode: true lights the tray's Reforge button, and Container
	-- clears it itself whenever the tray closes.
	SetReforgeMode = Signal.new(),
}

function RelicInterfaceController._render(_self: typeof(RelicInterfaceController))
	return function()
		local relicData, setRelicData = React.useState(nil :: { hashmap: RelicList, list: { RelicNames.RelicNames } }?)
		local relicSlots, setRelicSlots = React.useState(readRelicSlots())

		-- Re-render the tray whenever the server moves the open count (a
		-- future shop unlock), so the locked boxes follow it live.
		React.useEffect(function()
			local conn = Players.LocalPlayer:GetAttributeChangedSignal(Attributes.RelicSlots):Connect(function()
				setRelicSlots(readRelicSlots())
			end)
			-- Catch a stamp that landed between the initial read and the connect.
			setRelicSlots(readRelicSlots())

			return function()
				conn:Disconnect()
			end
		end, {})

		React.useEffect(function()
			local onRelicUpdateConn

			onRelicUpdateConn = RelicController.Signals.OnRelicsUpdated:Connect(
				function(userId: number, hashmap: RelicList, list: { RelicNames.RelicNames })
					if userId == Players.LocalPlayer.UserId then
						setRelicData({ hashmap = hashmap, list = list })
					end
				end
			)

			return function()
				onRelicUpdateConn:Disconnect()
			end
		end, {})

		-- ScreenInsets = DeviceSafeInsets replaces the old IgnoreGuiInset +
		-- ClipToDeviceSafeArea pair: the tray lays out against the device's
		-- safe area (notches / rounded corners) rather than the raw viewport.
		return React.createElement("ScreenGui", {
			ResetOnSpawn = false,
			Name = INTERFACE_ID,
			ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets,
			ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		}, {
			Container = React.createElement(Container, {
				Visible = true,

				relicData = relicData,
				relicSlots = relicSlots,
				setVisibleSignal = RelicInterfaceController.Signals.SetVisible,
				sellModeSignal = RelicInterfaceController.Signals.SetSellMode,
				reforgeModeSignal = RelicInterfaceController.Signals.SetReforgeMode,

				-- Server round-trips for the tray's action row.
				onDropRelic = function(relicName: string): boolean
					return RelicNetwork.DropRelic.Invoke(relicName)
				end,
				-- Routed through EventController rather than straight to the
				-- service: the controller counts sales for the merchant's
				-- post-sale dialogue (sold vs browsed-and-left lines).
				onSellRelic = function(relicName: string): number
					return getEventController():SellRelicViaMerchant(relicName)
				end,
				onSellModeEnded = function()
					getEventController():OnSellUIClosed()
				end,
				-- The Forge's anvil. Returns true once the swap landed; the
				-- controller closes the tray and advances the dialogue itself.
				onReforgeRelic = function(relicName: string): boolean
					return getEventController():ReforgeRelicViaForge(relicName)
				end,
				onReforgeModeEnded = function()
					getEventController():OnReforgeUIClosed()
				end,
				onBlockedAction = function()
					getEventController():ShowBlockedActionNotification()
				end,
			}),
		})
	end
end

--[ Lifecycle ]--

function RelicInterfaceController.Init(self: typeof(RelicInterfaceController))
	-- Windows scope, NON-restoring: closing the scope slides the tray shut,
	-- but reopening the scope must not slide it back out — it only unlocks
	-- the tray's own toggle button.
	InterfaceManagerController:Register(INTERFACE_ID, {
		scope = InterfaceScopes.Windows,
		restoreOnScopeOpen = false,
		onClose = function()
			-- The Container tweens its position off this state, so a scope
			-- close slides out exactly like pressing the tray's toggle.
			RelicInterfaceController.Signals.SetVisible:Fire(false)
		end,
	})

	local root = ReactRoblox.createRoot(Instance.new("Folder"))
	root:render(ReactRoblox.createPortal(React.createElement(self:_render()), Players.LocalPlayer.PlayerGui))
end

function RelicInterfaceController.Start(self: typeof(RelicInterfaceController))
	-- The Merchant's "sell relics" option: force the tray open with the
	-- Sell button lit. Closing the tray (any path) ends the session.
	getEventController().Signals.OnSellModeRequested:Connect(function()
		self.Signals.SetVisible:Fire(true)
		self.Signals.SetSellMode:Fire(true)
	end)

	-- The Forge's "Reforge" option: same force-open, Reforge lit instead.
	getEventController().Signals.OnReforgeModeRequested:Connect(function()
		self.Signals.SetVisible:Fire(true)
		self.Signals.SetReforgeMode:Fire(true)
	end)
end

return RelicInterfaceController
