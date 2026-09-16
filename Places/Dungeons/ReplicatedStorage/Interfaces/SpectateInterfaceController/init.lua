--!strict
--[[
     Module: SpectateInterfaceController.lua
     Description:
     Spectate HUD overlay. Visible while the local player is in
     LifeService.DeathState. Shows:
       - "Now Viewing: <PlayerName>" centered near the top with left/right
         arrow hints (cycle via arrow keys, wired in SpectateController)
       - A REVIVE button in the bottom-right corner that calls
         PlayerNetwork.PromptRevivePurchase → MarketplaceService prompt

     Auto-hides the moment the local player's DeathState entry clears
     (revive successful).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local LifeController = require(ReplicatedStorage.Controllers.LifeController)
local SpectateController = require(ReplicatedStorage.Controllers.SpectateController)
local React = require(ReplicatedStorage.Submodules.Core.Packages.React)
local ReactRoblox = require(ReplicatedStorage.Submodules.Core.Packages["React-Roblox"])

local Container = require(script.ReactComponents.Container)

local INTERFACE_ID = "SpectateInterfaceController"

local SpectateInterfaceController = {
	Name = "SpectateInterfaceController",
	Dependencies = { LifeController, SpectateController } :: { any },
}

function SpectateInterfaceController._render(_self: typeof(SpectateInterfaceController))
	return function()
		return React.createElement("ScreenGui", {
			ResetOnSpawn = false,
			IgnoreGuiInset = true,
			Name = INTERFACE_ID,
			ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
			-- Above the HUD bars but below the screen fade overlay
			-- (ScreenFade uses DisplayOrder=9999) — so the death/revive
			-- fades cleanly cover this UI.
			DisplayOrder = 4,
			ClipToDeviceSafeArea = true,
		}, {
			Container = React.createElement(Container, {
				LifeController = LifeController,
				SpectateTargets = SpectateController.SpectateTargets,
			}),
		})
	end
end

--[ Lifecycle ]--

function SpectateInterfaceController.Start(self: typeof(SpectateInterfaceController))
	-- LifeController is needed for the OnSpectateStateChanged signal that
	-- gates visibility (visible only after the death-fade completes).
	-- Resolved in Start because controller-to-controller deps aren't
	-- safe to read during Init.

	local root = ReactRoblox.createRoot(Instance.new("Folder"))
	root:render(ReactRoblox.createPortal(React.createElement(self:_render()), Players.LocalPlayer.PlayerGui))
end

return SpectateInterfaceController
