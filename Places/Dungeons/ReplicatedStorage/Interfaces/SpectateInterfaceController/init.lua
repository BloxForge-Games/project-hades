--[[
     Module: SpectateInterfaceController.lua
     Description:
     Spectate HUD overlay. Visible while the local player is in
     LifeService.DeathState. Shows:
       - "Now Viewing: <PlayerName>" centered near the top with left/right
         arrow hints (cycle via arrow keys, wired in SpectateController)
       - A REVIVE button in the bottom-right corner that calls
         LifeService:PromptRevivePurchase → MarketplaceService prompt

     Auto-hides the moment the local player's DeathState entry clears
     (revive successful).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local React = require(ReplicatedStorage.Submodules.Core.Packages.React)
local ReactRoblox = require(ReplicatedStorage.Submodules.Core.Packages["React-Roblox"])

local Container = require(script.ReactComponents.Container)

local INTERFACE_ID = "SpectateInterfaceController"

local LifeService
local LifeController
local SpectateService

local SpectateInterfaceController = Knit.CreateController({
	Name = "SpectateInterfaceController",
})

function SpectateInterfaceController:_render()
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
				LifeService = LifeService,
				LifeController = LifeController,
				SpectateService = SpectateService,
			}),
		})
	end
end

--[ Lifecycle ]--

function SpectateInterfaceController:KnitInit()
	LifeService = Knit.GetService("LifeService")
	SpectateService = Knit.GetService("SpectateService")
end

function SpectateInterfaceController:KnitStart()
	-- LifeController is needed for the OnSpectateStateChanged signal that
	-- gates visibility (visible only after the death-fade completes).
	-- Resolved in KnitStart because controller-to-controller deps aren't
	-- safe to read during KnitInit.
	LifeController = Knit.GetController("LifeController")

	local root = ReactRoblox.createRoot(Instance.new("Folder"))
	root:render(ReactRoblox.createPortal(React.createElement(self:_render()), Players.LocalPlayer.PlayerGui))
end

return SpectateInterfaceController
