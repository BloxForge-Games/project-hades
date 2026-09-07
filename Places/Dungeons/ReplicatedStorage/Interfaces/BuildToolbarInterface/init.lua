--[[
     Module: BuildToolbarInterface.lua
     Description:
     UI root / React bridge
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

--[ Imports ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local React = require(ReplicatedStorage.Submodules.Core.Packages.React)
local BuildNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.BuildNames)

local Container = require(script.RoactComponents.Container)

--[ App Component ]--

local ToolBarController
local BuildController
local CinematicInterfaceController
local ScreenSizeController
local BuildLoadoutController

local BuildToolbarInterface = Knit.CreateController({
	Name = "BuildToolbarInterface",
})

function BuildToolbarInterface:_render()
	return function()
		local visible, setVisible = React.useState(false)
		local activeIndex, setActiveToolIndex = React.useState(1)
		local toolbarData, setToolBarData = React.useState(BuildLoadoutController:GetBuildLoadoutRegistry())
		local buildLevelData, setBuildLevelData = React.useState({ BuildController:GetBuildLevelRegistry() })

		React.useEffect(function()
			local conn = BuildController.Signals.OnBuildModeToggled:Connect(function(toggle: boolean)
				setVisible(toggle)
			end)

			return function()
				conn:Disconnect()
			end
		end, {})

		React.useEffect(function()
			local conn = BuildLoadoutController.Signals.OnBuildLoadoutUpdated:Connect(function(toolBarData: table)
				setToolBarData(toolBarData)
			end)

			return function()
				conn:Disconnect()
			end
		end, {})

		React.useEffect(function()
			local conn = ToolBarController.Signals.OnActiveToolUpdated:Connect(function(index: number)
				if BuildController:GetBuildMode() then
					setActiveToolIndex(index)
				end
			end)

			return function()
				conn:Disconnect()
			end
		end, {})

		React.useEffect(function()
			local conn = CinematicInterfaceController.Signals.OnCinematicStart:Connect(function()
				setVisible(false)
			end)

			local conn2 = CinematicInterfaceController.Signals.OnCinematicEnd:Connect(function()
				if BuildController:GetBuildMode() then
					setVisible(true)
				end
			end)

			return function()
				conn:Disconnect()
				conn2:Disconnect()
			end
		end, {})

		React.useEffect(function()
			local conn = BuildController.Signals.OnBuildLevelChanged:Connect(function(buildLevelRegistry: table)
				setBuildLevelData(buildLevelRegistry)
			end)

			return function()
				conn:Disconnect()
			end
		end, { visible })

		return React.createElement("ScreenGui", {
			ResetOnSpawn = false,
			IgnoreGuiInset = true,
			ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		}, {
			Container = React.createElement(Container, {
				Visible = visible,
				ScreenSizeController = ScreenSizeController,

				activeIndex = activeIndex,
				toolbarData = toolbarData,
				buildLevelData = buildLevelData,

				setActiveBuild = function(name: BuildNames.BuildNames)
					BuildController:SetActiveBuild(name)
				end,

				buildClicked = function(index: number)
					print("Build clicked:", index)
				end,

				setBuildMode = function(toggle: boolean)
					BuildController:ToggleBuildMode(toggle)
				end,
			}),
		})
	end
end

--[ Lifecycle ]--

function BuildToolbarInterface:KnitStart()
	ToolBarController = Knit.GetController("ToolBarController")
	BuildController = Knit.GetController("BuildController")
	CinematicInterfaceController = Knit.GetController("CinematicInterfaceController")
	ScreenSizeController = Knit.GetController("ScreenSizeController")
	BuildLoadoutController = Knit.GetController("BuildLoadoutController")

	-- local root = ReactRoblox.createRoot(Instance.new("Folder"))
	-- root:render(
	-- 	ReactRoblox.createPortal(
	-- 		{ [INTERFACE_ID] = React.createElement(self:_render()) },
	-- 		Players.LocalPlayer.PlayerGui
	-- 	)
	-- )
end

return BuildToolbarInterface
