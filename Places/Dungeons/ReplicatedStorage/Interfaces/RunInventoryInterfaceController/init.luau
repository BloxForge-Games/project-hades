--[[
	Module: RunInventoryInterfaceController/init.luau
	Description:
	UI root for the RUN inventory -- the Dungeon Drops sitting in
	RunEscrowService's escrow (banked when you walk out through the exit
	portal, lost on death — beating the boss alone banks nothing).
	Relics have their own panel: RelicInterfaceController.

	Owns, mirroring InventoryInterfaceController:
	  * Visibility state + the React subscription wrapper that re-renders
	    on visibility flips.
	  * The dim backdrop, hoisted OUT of Container's CanvasGroup so its
	    Size 2x2 isn't clipped by the wrapper's render bounds.
	  * A HUD hide source held on InterfaceManagerController for as long as
	    the panel is up (reference counted, so a cutscene or a manual
	    CloseInterface holding the HUD survives this panel closing).
	  * Registration in the Windows scope, which is what closes this panel
	    during cutscenes and blocks :Open while that scope is shut.

	==========================================================
	Openers
	==========================================================

	Two, and they are NOT symmetric:

	  C key      -- a true toggle. Opens AND closes.
	  Toolbar    -- the RunInventory slot in ToolBarInterface. Open-only in
	                practice: opening hides the HUD, which takes the toolbar
	                (and therefore that button) with it. Closing is the C key
	                or the panel's own Close button.

	The notification pip lives on that toolbar slot, but the STATE lives
	here -- see OnNotificationChanged. Keeping it controller-side means the
	badge survives the toolbar unmounting while the HUD is hidden, and it
	spares ToolBarInterface a second subscription to the escrow property.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

--[ Imports ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local React = require(ReplicatedStorage.Submodules.Core.Packages.React)
local ReactRoblox = require(ReplicatedStorage.Submodules.Core.Packages["React-Roblox"])
local Signal = require(ReplicatedStorage.Submodules.Core.Packages.Signal)
local InterfaceScopes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.InterfaceScopes)
local uiSound = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.uiSound)

local Container = require(script.RoactComponents.Container)

local INTERFACE_ID = "RunInventoryInterface"
local TOGGLE_KEY = Enum.KeyCode.C

-- Dim backdrop tween targets. Same reasoning as the Inventory's: the
-- 2x2 Frame lives at this level so it's a SIBLING of the Container's
-- CanvasGroup and doesn't get chopped to the wrapper's bounds.
local BACKGROUND_OPEN_TRANSPARENCY = 0.25
local BACKGROUND_CLOSED_TRANSPARENCY = 1
local BACKGROUND_TWEEN_DURATION = 0.3
local BACKGROUND_TWEEN_INFO = TweenInfo.new(BACKGROUND_TWEEN_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

--[ Controller ]--

local RunInventoryInterfaceController = Knit.CreateController({
	Name = "RunInventoryInterfaceController",
})

RunInventoryInterfaceController._visible = false
RunInventoryInterfaceController._visibilityChanged = Signal.new() :: (visible: boolean) -> ()

-- Unseen-drop pip, consumed by ToolBarInterface's RunInventory slot.
RunInventoryInterfaceController._hasNotification = false
RunInventoryInterfaceController.Signals = {
	OnNotificationChanged = Signal.new() :: (hasNotification: boolean) -> (),
}

local RunEscrowService
local InterfaceManagerController

-- Stable source name for the manager's reference-counted hide map on the
-- HUD scope, so it can tell "run inventory is hiding the HUD" apart from
-- other hiders (a cutscene, a manual CloseInterface, the other windows).
local HUD_HIDE_SOURCE = "RunInventoryInterface"

--[ Public API ]--

function RunInventoryInterfaceController:HasNotification(): boolean
	return self._hasNotification
end

function RunInventoryInterfaceController:_setNotification(hasNotification: boolean)
	if self._hasNotification == hasNotification then
		return
	end
	self._hasNotification = hasNotification
	self.Signals.OnNotificationChanged:Fire(hasNotification)
end

function RunInventoryInterfaceController:Open()
	-- Permission gate. Replaces the old `_locked` flag: the Windows scope
	-- being closed is what blocks an open now, and the manager warns so a
	-- swallowed keypress is visible rather than looking like a dead keybind.
	if not InterfaceManagerController:RequestOpen(INTERFACE_ID) then
		return
	end
	if self._visible then
		return
	end
	self._visible = true
	self._visibilityChanged:Fire(true)
	uiSound:PlayOpen()
	-- Opening IS the "seen" event, so the pip clears here rather than in a
	-- click handler -- the C key and the toolbar button both benefit.
	self:_setNotification(false)
	-- Take a HUD hide source for as long as we're up. Reference counted, so
	-- if the HUD is ALSO being held down by a manual CloseInterface or a
	-- cutscene, our release below won't bring it back early.
	InterfaceManagerController:Hide(InterfaceScopes.HUD, HUD_HIDE_SOURCE)
end

function RunInventoryInterfaceController:Close()
	if not self._visible then
		return
	end
	self._visible = false
	self._visibilityChanged:Fire(false)
	InterfaceManagerController:Show(InterfaceScopes.HUD, HUD_HIDE_SOURCE)
end

function RunInventoryInterfaceController:Toggle()
	if self._visible then
		self:Close()
	else
		self:Open()
	end
end

-- `SetLocked` is gone. Cutscene locking is now just the Windows scope
-- closing: InterfaceManagerController hides that scope on OnCinematicStart,
-- which invokes the onClose registered in KnitStart (closing this panel and
-- releasing its HUD hide source), and blocks :Open until the scope reopens.

--[ React wrapper ]--

local function App(props: any)
	local controller = props.controller
	local visible, setVisible = React.useState(controller._visible)

	local backgroundFrameRef = React.useRef(nil)

	React.useEffect(function()
		local conn = controller._visibilityChanged:Connect(function(newVisible: boolean)
			setVisible(newVisible)
		end)
		return function()
			conn:Disconnect()
		end
	end, {})

	-- Mount-only: seed the closed-state backdrop transparency.
	-- BackgroundTransparency is deliberately OMITTED from the element props
	-- so React can't re-apply a declarative value mid-tween.
	React.useEffect(function()
		if backgroundFrameRef.current then
			backgroundFrameRef.current.BackgroundTransparency = BACKGROUND_CLOSED_TRANSPARENCY
		end
	end, {})

	React.useEffect(function()
		if backgroundFrameRef.current then
			TweenService:Create(backgroundFrameRef.current, BACKGROUND_TWEEN_INFO, {
				BackgroundTransparency = if visible
					then BACKGROUND_OPEN_TRANSPARENCY
					else BACKGROUND_CLOSED_TRANSPARENCY,
			}):Play()
		end
	end, { visible })

	-- Fragment so the backdrop and the panel mount as direct siblings under
	-- the ScreenGui. ZIndexBehavior = Sibling means the backdrop's
	-- ZIndex = -1 reliably renders behind the panel.
	return React.createElement(React.Fragment, nil, {
		BackgroundFrame = React.createElement("Frame", {
			ref = backgroundFrameRef,
			AnchorPoint = Vector2.new(0.5, 0.5),
			BackgroundColor3 = Color3.fromRGB(25, 25, 25),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(2, 2),
			ZIndex = -1,
		}),

		Container = React.createElement(Container, {
			Visible = visible,
			RunEscrowService = props.RunEscrowService,
			onClose = function()
				controller:Close()
			end,
		}),
	})
end

function RunInventoryInterfaceController:_render()
	local controller = self
	return function()
		return React.createElement("ScreenGui", {
			ResetOnSpawn = false,
			IgnoreGuiInset = true,
			Name = INTERFACE_ID,
			DisplayOrder = 100,
			ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		}, {
			App = React.createElement(App, {
				controller = controller,
				RunEscrowService = RunEscrowService,
			}),
		})
	end
end

--[ Lifecycle ]--

function RunInventoryInterfaceController:KnitStart()
	InterfaceManagerController = Knit.GetController("InterfaceManagerController")
	RunEscrowService = Knit.GetService("RunEscrowService")

	-- Windows scope, NON-restoring: closing the scope shuts this panel, but
	-- reopening the scope must not fling it back open — it only unlocks the
	-- C keybind / toolbar button so the player can summon it again.
	InterfaceManagerController:Register(INTERFACE_ID, {
		scope = InterfaceScopes.Windows,
		restoreOnScopeOpen = false,
		onClose = function()
			-- Close() runs the existing fade/tween, so a scope close looks
			-- identical to the player pressing the panel's own X.
			RunInventoryInterfaceController:Close()
		end,
	})

	local root = ReactRoblox.createRoot(Instance.new("Folder"))
	root:render(ReactRoblox.createPortal(React.createElement(self:_render()), Players.LocalPlayer.PlayerGui))

	-- Unseen-drop pip. Fires on GROWTH only: an escrow discard on death
	-- shouldn't read as "you have something new". Lives here rather than in
	-- App so the state survives the toolbar unmounting with the HUD.
	local lastDropCount = 0
	RunEscrowService.EscrowData:Observe(function(snapshot: { [string]: any }?)
		local count = if snapshot and snapshot.items then #snapshot.items else 0
		if count > lastDropCount and not self._visible then
			self:_setNotification(true)
		end
		lastDropCount = count
	end)

	-- C toggles. gameProcessedEvent gates it so typing a "c" into chat or any
	-- focused TextBox doesn't pop the panel; Open() refuses (and warns) while
	-- the Windows scope is closed, and Close() is deliberately NOT gated so a
	-- scope close mid-panel can still shut it.
	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessedEvent: boolean)
		if gameProcessedEvent then
			return
		end
		if input.KeyCode == TOGGLE_KEY then
			self:Toggle()
		end
	end)

	-- Cinematic subscriptions removed: InterfaceManagerController closes the
	-- whole Windows scope on OnCinematicStart and reopens it on
	-- OnCinematicEnd, which drives the onClose above and the :Open gate.
end

function RunInventoryInterfaceController:KnitInit() end

return RunInventoryInterfaceController
