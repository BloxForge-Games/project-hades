--!strict
--[[
	Module: FriendBonusInterfaceController.lua
	Description:
	The in-run friend bonus chip (2026-11-08): a small "Friends +20%" badge
	just above the health bar while the local player's run earns a friend
	bonus (Attributes.FriendBonus, written by FriendBonusService; see
	Shared/Data/FriendBonusData). Hidden with no friends in the run.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage.Submodules.Core.Packages.React)
local ReactRoblox = require(ReplicatedStorage.Submodules.Core.Packages["React-Roblox"])
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local FriendBonusData = require(ReplicatedStorage.Submodules.Core.Shared.Data.FriendBonusData)

-- Where the (hidden) lives row sits: just above the health bar.
local CHIP_ANCHOR = Vector2.new(0.5, 1)
local CHIP_POSITION = UDim2.fromScale(0.5, 0.78)
local CHIP_SIZE = UDim2.fromOffset(150, 26)
local CHIP_COLOR = Color3.fromRGB(20, 28, 22)
local BONUS_COLOR = Color3.fromRGB(85, 255, 127)

local FriendBonusInterfaceController = {
	Name = "FriendBonusInterfaceController",
}

local function readBonus(): number
	local bonus = Players.LocalPlayer:GetAttribute(Attributes.FriendBonus)
	return if type(bonus) == "number" then bonus else 0
end

local function Chip()
	local bonus, setBonus = React.useState(readBonus)

	React.useEffect(function()
		local connection = Players.LocalPlayer:GetAttributeChangedSignal(Attributes.FriendBonus):Connect(function()
			setBonus(readBonus())
		end)
		return function()
			connection:Disconnect()
		end
	end, {})

	return React.createElement("ScreenGui", {
		Name = "FriendBonusInterface",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ClipToDeviceSafeArea = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Enabled = bonus > 0,
	}, {
		Chip = React.createElement("TextLabel", {
			AnchorPoint = CHIP_ANCHOR,
			Position = CHIP_POSITION,
			Size = CHIP_SIZE,
			BackgroundColor3 = CHIP_COLOR,
			BackgroundTransparency = 0.25,
			BorderSizePixel = 0,
			FontFace = Font.new("rbxasset://fonts/families/Montserrat.json", Enum.FontWeight.Bold),
			RichText = true,
			Text = string.format(
				'Friends <font color="#%s">%s</font>',
				BONUS_COLOR:ToHex(),
				FriendBonusData.Format(bonus)
			),
			TextColor3 = Color3.new(1, 1, 1),
			TextSize = 15,
		}, {
			Corner = React.createElement("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
			Stroke = React.createElement("UIStroke", {
				ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
				Color = BONUS_COLOR,
				Transparency = 0.4,
				Thickness = 1.5,
			}),
		}),
	})
end

--[ Lifecycle ]--

function FriendBonusInterfaceController.Init(_self: typeof(FriendBonusInterfaceController))
	local root = ReactRoblox.createRoot(Instance.new("Folder"))
	root:render(ReactRoblox.createPortal(React.createElement(Chip), Players.LocalPlayer.PlayerGui))
end

return FriendBonusInterfaceController
