--[[
     Module: RelicInterfaceController.lua
     Description:
     UI root / React bridge
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

--[ Imports ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local React = require(ReplicatedStorage.Submodules.Core.Packages.React)
local ReactRoblox = require(ReplicatedStorage.Submodules.Core.Packages["React-Roblox"])
local Signal = require(ReplicatedStorage.Submodules.Core.Packages.Signal)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local InterfaceScopes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.InterfaceScopes)

local Container = require(script.ReactComponents.Container)

local INTERFACE_ID = "RelicInterfaceController"

export type RelicList = {
	[RelicNames.RelicNames]: number,
}

--[ App Component ]--

local RelicController

local RelicInterfaceController = Knit.CreateController({
	Name = "RelicInterfaceController",
})

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

function RelicInterfaceController:_render()
	return function()
		local relicData, setRelicData = React.useState(nil)

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
				setVisibleSignal = RelicInterfaceController.Signals.SetVisible,
				sellModeSignal = RelicInterfaceController.Signals.SetSellMode,
				reforgeModeSignal = RelicInterfaceController.Signals.SetReforgeMode,

				-- Server round-trips for the tray's action row. Resolved
				-- lazily: Knit services exist by first render, but not at
				-- module scope (circular-require rule, same as the signals).
				onDropRelic = function(relicName: string): boolean
					return Knit.GetService("RelicService"):DropRelic(relicName):expect()
				end,
				-- Routed through EventController rather than straight to the
				-- service: the controller counts sales for the merchant's
				-- post-sale dialogue (sold vs browsed-and-left lines).
				onSellRelic = function(relicName: string): number
					return Knit.GetController("EventController"):SellRelicViaMerchant(relicName)
				end,
				onSellModeEnded = function()
					Knit.GetController("EventController"):OnSellUIClosed()
				end,
				-- The Forge's anvil. Returns true once the swap landed; the
				-- controller closes the tray and advances the dialogue itself.
				onReforgeRelic = function(relicName: string): boolean
					return Knit.GetController("EventController"):ReforgeRelicViaForge(relicName)
				end,
				onReforgeModeEnded = function()
					Knit.GetController("EventController"):OnReforgeUIClosed()
				end,
				onBlockedAction = function()
					Knit.GetController("EventController"):ShowBlockedActionNotification()
				end,
			}),
		})
	end
end

--[ Lifecycle ]--

function RelicInterfaceController:KnitInit()
	RelicController = Knit.GetController("RelicController")

	-- Windows scope, NON-restoring: closing the scope slides the tray shut,
	-- but reopening the scope must not slide it back out — it only unlocks
	-- the tray's own toggle button.
	Knit.GetController("InterfaceManagerController"):Register(INTERFACE_ID, {
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

function RelicInterfaceController:KnitStart()
	-- The Merchant's "sell relics" option: force the tray open with the
	-- Sell button lit. Closing the tray (any path) ends the session.
	Knit.GetController("EventController").Signals.OnSellModeRequested:Connect(function()
		self.Signals.SetVisible:Fire(true)
		self.Signals.SetSellMode:Fire(true)
	end)

	-- The Forge's "Reforge" option: same force-open, Reforge lit instead.
	Knit.GetController("EventController").Signals.OnReforgeModeRequested:Connect(function()
		self.Signals.SetVisible:Fire(true)
		self.Signals.SetReforgeMode:Fire(true)
	end)
end

return RelicInterfaceController
