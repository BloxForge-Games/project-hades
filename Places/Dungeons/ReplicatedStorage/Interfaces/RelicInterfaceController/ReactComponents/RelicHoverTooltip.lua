--!strict
--[[
	Module: RelicHoverTooltip.lua
	Description:
	The relic tray's HOVER card (2026-10-31): a compact panel beside the
	slot the mouse is over -- name in its rarity colour, "Rarity · Tree",
	and the description (the live runtime text where the relic has one,
	through getRelicDescription). Mouse only: touch taps a slot to open
	the description card, which already says all of this.

	Props:
	  hovered    nil, or { relicName, anchorPosition: Vector2,
	             anchorSize: Vector2 } -- the slot's absolute rect, in
	             PIXELS RELATIVE TO THE TRAY ROOT (Container converts).
	  rootSize   the tray root's AbsoluteSize, to keep the panel on screen.

	Placement: to the RIGHT of the slot, centred on it; flipped to the
	left when the right side would run off the root, and clamped
	vertically against an estimated height (the panel auto-sizes to its
	text, so the exact height is not known before it renders).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage.Submodules.Core.Packages.React)
local RelicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicData)
local RarityColors = require(ReplicatedStorage.Submodules.Core.Shared.Data.RarityColors)
local getRelicDescription = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Relic.getRelicDescription)

local localPlayer = Players.LocalPlayer

-- Pixels. The panel's width is fixed; its height follows the text.
local PANEL_WIDTH = 260
local PANEL_PADDING = 12
local PANEL_GAP = 10
local PANEL_ESTIMATED_HEIGHT = 150
local SCREEN_MARGIN = 8
-- The tray panel's dark blue-grey plate and stroke (Container).
local PANEL_COLOR = Color3.fromRGB(20, 31, 40)
local PANEL_STROKE_COLOR = Color3.fromRGB(43, 65, 85)
local BODY_TEXT_COLOR = Color3.fromRGB(235, 235, 235)
local META_TEXT_COLOR = Color3.fromRGB(165, 185, 200)
local NAME_TEXT_SIZE = 18
local META_TEXT_SIZE = 13
local BODY_TEXT_SIZE = 14
-- Above everything else at the tray root (the list and the card sit at
-- ZIndex 1; React-lua siblings at equal ZIndex draw in undefined order).
local PANEL_ZINDEX = 40

local TITLE_FONT = Font.new("rbxasset://fonts/families/Montserrat.json", Enum.FontWeight.Bold, Enum.FontStyle.Normal)
local META_FONT = Font.new("rbxasset://fonts/families/Montserrat.json", Enum.FontWeight.SemiBold, Enum.FontStyle.Normal)
local BODY_FONT = Font.new("rbxasset://fonts/families/Montserrat.json", Enum.FontWeight.Medium, Enum.FontStyle.Normal)

type Hovered = {
	relicName: string,
	anchorPosition: Vector2,
	anchorSize: Vector2,
}

-- "Rare · Blaze", or "Duo · Frost + Storm" for a duo relic.
local function metaLine(relicInfo: any): string
	local tree = tostring(relicInfo.tree or "")
	if relicInfo.duo then
		tree = tree .. " + " .. tostring(relicInfo.duo)
	end
	return tostring(relicInfo.rarity or "") .. " · " .. tree
end

local function RelicHoverTooltip(props: { hovered: Hovered?, rootSize: Vector2? })
	local hovered = props.hovered
	local relicInfo = hovered and RelicData[hovered.relicName]
	if not hovered or not relicInfo then
		return nil
	end

	local rootSize = props.rootSize or Vector2.new(1920, 1080)
	local anchorPosition = hovered.anchorPosition
	local anchorSize = hovered.anchorSize

	-- Right of the slot unless that runs off the root, then left of it.
	local x = anchorPosition.X + anchorSize.X + PANEL_GAP
	if x + PANEL_WIDTH + SCREEN_MARGIN > rootSize.X then
		x = anchorPosition.X - PANEL_GAP - PANEL_WIDTH
	end
	x = math.max(x, SCREEN_MARGIN)
	-- Centred on the slot, held inside the root by the estimated height.
	local y = anchorPosition.Y + anchorSize.Y / 2 - PANEL_ESTIMATED_HEIGHT / 2
	y = math.clamp(y, SCREEN_MARGIN, math.max(rootSize.Y - PANEL_ESTIMATED_HEIGHT - SCREEN_MARGIN, SCREEN_MARGIN))

	local description = getRelicDescription(localPlayer, hovered.relicName) or ""

	return React.createElement("Frame", {
		Position = UDim2.fromOffset(x, y),
		Size = UDim2.fromOffset(PANEL_WIDTH, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = PANEL_COLOR,
		BackgroundTransparency = 0.04,
		BorderSizePixel = 0,
		ZIndex = PANEL_ZINDEX,
	}, {
		UICorner = React.createElement("UICorner", {
			CornerRadius = UDim.new(0, 8),
		}),
		UIStroke = React.createElement("UIStroke", {
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			Color = PANEL_STROKE_COLOR,
			Thickness = 1.5,
		}),
		UIPadding = React.createElement("UIPadding", {
			PaddingTop = UDim.new(0, PANEL_PADDING),
			PaddingBottom = UDim.new(0, PANEL_PADDING),
			PaddingLeft = UDim.new(0, PANEL_PADDING),
			PaddingRight = UDim.new(0, PANEL_PADDING),
		}),
		UIListLayout = React.createElement("UIListLayout", {
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 4),
		}),

		Name = React.createElement("TextLabel", {
			LayoutOrder = 1,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			Text = hovered.relicName,
			TextColor3 = RarityColors:Get(relicInfo.rarity),
			TextSize = NAME_TEXT_SIZE,
			FontFace = TITLE_FONT,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			ZIndex = PANEL_ZINDEX + 1,
		}),

		Meta = React.createElement("TextLabel", {
			LayoutOrder = 2,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			Text = metaLine(relicInfo),
			TextColor3 = META_TEXT_COLOR,
			TextSize = META_TEXT_SIZE,
			FontFace = META_FONT,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			ZIndex = PANEL_ZINDEX + 1,
		}),

		Description = React.createElement("TextLabel", {
			LayoutOrder = 3,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			Text = description,
			RichText = true,
			TextColor3 = BODY_TEXT_COLOR,
			TextSize = BODY_TEXT_SIZE,
			FontFace = BODY_FONT,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			ZIndex = PANEL_ZINDEX + 1,
		}, {
			UIPadding = React.createElement("UIPadding", {
				PaddingTop = UDim.new(0, 4),
			}),
		}),
	})
end

return RelicHoverTooltip
