--[[
     Module: LivesInterfaceController.lua
     Description:
     Top-of-HP-bar HUD widget that visualizes the local player's remaining
     lives (server-authoritative count published via LifeService.LivesData).
     One heart icon per slot; filled = alive, dimmed = lost. Animates the
     specific heart that just changed (shrink-fade on loss, pop-in on gain)
     instead of redrawing the whole row.

     Hidden when the local player has no lives entry yet (pre-dungeon-init).

     Data shape consumed:
       LifeService.LivesData = { [userId] = { current: number, max: number } }
       We filter to LocalPlayer.UserId; the rest of the map is for spectate
       UI in Chunk D.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local React = require(ReplicatedStorage.Submodules.Core.Packages.React)
local ReactRoblox = require(ReplicatedStorage.Submodules.Core.Packages["React-Roblox"])
local Signal = require(ReplicatedStorage.Submodules.Core.Packages.Signal)

local Container = require(script.ReactComponents.Container)

local INTERFACE_ID = "LivesInterfaceController"

local LifeService

local LivesInterfaceController = Knit.CreateController({
	Name = "LivesInterfaceController",
})

-- Public signals other controllers fire to drive this interface. SetVisible
-- toggles ScreenGui.Enabled-equivalent via the React render (we drive a
-- `visible` state on the top-level ScreenGui). LifeController uses it to
-- hide the lives row during the death + revive lifecycle without touching
-- PlayerGui directly.
LivesInterfaceController.Signals = {
	SetVisible = Signal.new(), -- (visible: boolean)
}

function LivesInterfaceController:_render()
	return function()
		-- Top-level visibility flag. Driven by the SetVisible signal — we
		-- toggle ScreenGui.Enabled rather than a child Frame.Visible so
		-- the entire UI tree (including any future heart-row offspring)
		-- vanishes in one hit and doesn't run layout while hidden.
		local visible, setVisible = React.useState(true)

		React.useEffect(function()
			local conn = self.Signals.SetVisible:Connect(function(value: boolean)
				setVisible(value)
			end)
			return function()
				conn:Disconnect()
			end
		end, {})

		return React.createElement("ScreenGui", {
			ResetOnSpawn = false,
			IgnoreGuiInset = true,
			Name = INTERFACE_ID,
			ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
			ClipToDeviceSafeArea = true,
			Enabled = visible,
		}, {
			Container = React.createElement(Container, {
				LifeService = LifeService,
			}),
		})
	end
end

--[ Lifecycle ]--

function LivesInterfaceController:KnitInit()
	LifeService = Knit.GetService("LifeService")

	local root = ReactRoblox.createRoot(Instance.new("Folder"))
	root:render(ReactRoblox.createPortal(React.createElement(self:_render()), Players.LocalPlayer.PlayerGui))
end

return LivesInterfaceController
