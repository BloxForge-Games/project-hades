local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local React = require(ReplicatedStorage.Submodules.Core.Packages.React)
local RelicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicData)
local RelicStackData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicStackData)
local tweenGui = require(ReplicatedStorage.Submodules.Core.Shared.Functions.UI.tweenGui)
local uiSound = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.uiSound)
local shineStroke = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.shineStroke)
local RarityColors = require(ReplicatedStorage.Submodules.Core.Shared.Data.RarityColors)

-- A FILLED slot's ring (2026-10-22): the inventory tiles' animated shine
-- outline in the relic's RARITY colour, at the resting stroke's own
-- thickness, on an anchor above the box's blue-grey border. Resting it
-- sweeps slowly with a faint band; picked, it brightens and speeds up
-- to the tiles' own look. Empty and locked boxes keep the static border.
local RING_THICKNESS = 0.03
local RING_RESTING = { speed = 25, shine = 0.3 }
local RING_SELECTED = { speed = 50, shine = 0.6 }
local BORDER_COLOR = Color3.fromRGB(43, 65, 85)

-- A LOCKED slot: a padlock on a dark box, past the run's open count. The
-- tray look is the default; the description card passes its own lighter
-- tint through `lockedLook`, since it sits on a lighter panel.
local LOCK_ICON = "rbxassetid://4830959937"
-- The relic art's share of the tile, and the most a RelicData.iconScale
-- may grow it to (a corner-to-corner weapon may just touch the frame).
local SLOT_ICON_SIZE = 0.85
local SLOT_ICON_MAX = 1
-- The padlock keeps its own size.
local LOCK_ICON_SIZE = 0.75
-- A FILLED slot (2026-11-04): the tile is the rarity colour taken most of
-- the way to near-black, so the art reads on it (a gold sword on a solid
-- gold box vanished); the rarity still shows in the bright ring
-- (shineStroke) and in the sheen, tinted the rarity colour.
local FILLED_TILE_DARK = Color3.fromRGB(14, 18, 26)
local FILLED_TILE_DARKEN = 0.7
local FILLED_SHEEN_TRANSPARENCY = 0.6
-- A soft GLOW behind the art (filled slots, 2026-11-04): a round frame at
-- BACKDROP_SIZE of the tile, itself invisible, whose blurred UIShadow in
-- the relic's rarity colour is the halo the icon sits on. (Black first: it
-- vanished on the dark tile.)
local BACKDROP_SIZE = 0.6
local BACKDROP_TRANSPARENCY = 1
local BACKDROP_BLUR = UDim.new(0, 14)
local BACKDROP_SPREAD = UDim2.fromOffset(4, 4)
local BACKDROP_SHADOW_TRANSPARENCY = 0.45
-- Darker than an open slot (2026-10-29; was 42, 66, 85, lighter than
-- one), with the padlock lifted so it still reads on the dark box.
local DEFAULT_LOCKED_LOOK = {
	background = Color3.fromRGB(17, 26, 34),
	icon = Color3.fromRGB(58, 80, 98),
	shadowVisible = true,
}

-- Props:
--   relicName, count      the relic path (unchanged).
--   locked, slotIndex     a LOCKED slot instead of a relic. Clickable
--                         (unlike an empty open slot) so the card can
--                         explain how to open it; the click reports
--                         { locked = true, slotIndex = n }, and the slot
--                         reads as selected when the selection carries
--                         that same index.
--   lockedLook            optional { background, icon, shadowVisible }
--                         override for the locked look.
--   onHover               optional (relicName: string?, slot: GuiObject?)
--                         -> (): the tray's hover tooltip. Called with
--                         the relic and the box on MouseEnter of a FILLED
--                         slot, with nils on MouseLeave; empty and locked
--                         boxes never call it.
local function RelicEntryContainer(props: any)
	local relicName = props.relicName
	local count = props.count
	local relicInfo = RelicData[relicName]
	local selectedRelic = props.selectedRelic
	local locked = props.locked == true
	local slotIndex = props.slotIndex
	local lockedLook = props.lockedLook or DEFAULT_LOCKED_LOOK
	local iconScale: number = if not locked and relicInfo and relicInfo.icon then relicInfo.iconScale or 1 else 1
	local slotIconSize = if locked then LOCK_ICON_SIZE else math.min(SLOT_ICON_SIZE * iconScale, SLOT_ICON_MAX)
	local filled = not locked and relicInfo ~= nil
	local rarityColor: Color3? = if filled and relicInfo then relicInfo.color else nil
	local iconImage = if locked then LOCK_ICON else relicInfo and relicInfo.icon or "rbxassetid://72334652371090"
	local containerRef = React.useRef(nil)
	local selectionAnchorRef = React.useRef(nil)

	-- A locked slot matches the selection by INDEX; a relic by name. The
	-- relic comparison is the original one, untouched: a locked selection
	-- carries no name, so it can never match a relic box (or an empty one).
	local isSelected
	if locked then
		isSelected = selectedRelic ~= nil and selectedRelic.locked == true and selectedRelic.slotIndex == slotIndex
	else
		isSelected = selectedRelic and selectedRelic.name == relicName
	end

	React.useEffect(function()
		if isSelected then
			tweenGui.size(
				containerRef.current,
				UDim2.fromScale(1.25, 1.25),
				Enum.EasingDirection.Out,
				Enum.EasingStyle.Quad,
				0.25,
				true
			)
		else
			tweenGui.size(
				containerRef.current,
				UDim2.fromScale(1.1, 1.1),
				Enum.EasingDirection.Out,
				Enum.EasingStyle.Quad,
				0.25,
				true
			)
		end
	end, { selectedRelic })

	local hasRing = not locked and count > 0 and relicInfo ~= nil
	local ringColor = RarityColors:Get(relicInfo and relicInfo.rarity)
	React.useEffect(function()
		local anchor = selectionAnchorRef.current
		if not hasRing or not anchor then
			return nil
		end
		return shineStroke(anchor, RING_THICKNESS, ringColor, if isSelected then RING_SELECTED else RING_RESTING)
	end, { hasRing, isSelected, ringColor })

	-- Empty OPEN boxes stay inert (nothing to say about them); locked
	-- boxes take clicks whenever a handler exists.
	local interactable
	if locked then
		interactable = props.onClick ~= nil
	else
		interactable = if count == 0 or props.onClick == nil then false else true
	end

	return React.createElement("ImageButton", {
		ref = containerRef,

		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1.1, 1.1),
		BackgroundColor3 = if locked
			then lockedLook.background
			elseif rarityColor then rarityColor:Lerp(FILLED_TILE_DARK, FILLED_TILE_DARKEN)
			-- An open, empty slot: the palette's dim blue-grey, a step
			-- lighter than a locked box so it reads as available but unused.
			else Color3.fromRGB(33, 52, 67),
		BackgroundTransparency = 0,
		ImageTransparency = 1,
		Active = interactable,
		Interactable = interactable,

		[React.Event.MouseEnter] = function()
			-- The inventory's sounds: a hover tick on any slot you can click
			-- (a relic or a locked box); empty open boxes stay silent.
			if interactable then
				uiSound:PlayHover()
			end
			if props.onHover and hasRing then
				props.onHover(relicName, containerRef.current)
			end
			-- TweenService:Create(
			-- 	containerRef.current,
			-- 	TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			-- 	{ Rotation = if math.random(1, 2) == 1 then -5 else 5 }
			-- ):Play()

			tweenGui.size(
				containerRef.current,
				UDim2.fromScale(1.175, 1.175),
				Enum.EasingDirection.Out,
				Enum.EasingStyle.Quad,
				0.25,
				true
			)
		end,

		[React.Event.MouseLeave] = function()
			if props.onHover and hasRing then
				props.onHover(nil, nil)
			end
			TweenService:Create(
				containerRef.current,
				TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Rotation = 0 }
			):Play()

			tweenGui.size(
				containerRef.current,
				UDim2.fromScale(1.1, 1.1),
				Enum.EasingDirection.Out,
				Enum.EasingStyle.Quad,
				0.25,
				true
			)
		end,

		[React.Event.Activated] = function()
			uiSound:PlayClick()
			if locked then
				props.onClick({
					locked = true,
					slotIndex = slotIndex,
				})
				return
			end
			props.onClick({
				name = relicName,
				count = count,
			})
		end,
	}, {
		UICorner = React.createElement("UICorner", {
			CornerRadius = UDim.new(0.05, 0),
		}),

		UIStroke = React.createElement("UIStroke", {
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			Color = BORDER_COLOR,
			StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize,
			Thickness = RING_THICKNESS,
			ZIndex = 1,
		}),

		-- The rarity ring's anchor (see RING_*).
		SelectionAnchor = React.createElement("Frame", {
			ref = selectionAnchorRef,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			ZIndex = 3,
		}, {
			UICorner = React.createElement("UICorner", {
				CornerRadius = UDim.new(0.05, 0),
			}),
		}),

		ShadowBackgroundImageLabel = React.createElement("ImageLabel", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(1, 1),
			Image = "rbxassetid://6096768861",
			BackgroundTransparency = 1,
			ImageColor3 = rarityColor or Color3.fromRGB(255, 255, 255),
			ImageTransparency = if rarityColor then FILLED_SHEEN_TRANSPARENCY else 0.35,
			ScaleType = Enum.ScaleType.Stretch,
			Visible = if locked then lockedLook.shadowVisible ~= false else true,
			ZIndex = 2,
		}, {
			UICorner = React.createElement("UICorner", {
				CornerRadius = UDim.new(0.05, 0),
			}),
		}),

		-- The blurred rarity glow behind the art (filled slots only).
		RelicIconBackdrop = React.createElement("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(BACKDROP_SIZE, BACKDROP_SIZE),
			BackgroundColor3 = rarityColor or Color3.new(1, 1, 1),
			BackgroundTransparency = BACKDROP_TRANSPARENCY,
			Visible = filled,
			ZIndex = 3,
		}, {
			UICorner = React.createElement("UICorner", {
				CornerRadius = UDim.new(0.5, 0),
			}),
			UIShadow = React.createElement("UIShadow", {
				Color = rarityColor or Color3.new(1, 1, 1),
				BlurRadius = BACKDROP_BLUR,
				Spread = BACKDROP_SPREAD,
				Transparency = BACKDROP_SHADOW_TRANSPARENCY,
			}),
		}),

		-- 0.85 of the tile (0.75 until 2026-11-04: the art read small), times
		-- the relic's RelicData.iconScale, never past SLOT_ICON_MAX. Straight
		-- on the glow (the black drop-shadow copy was removed 2026-11-04).
		RelicIcon = React.createElement("ImageLabel", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(slotIconSize, slotIconSize),
			Image = iconImage,
			ImageColor3 = if locked then lockedLook.icon else Color3.fromRGB(255, 255, 255),
			BackgroundTransparency = 1,
			ScaleType = Enum.ScaleType.Fit,
			Visible = locked or relicInfo ~= nil,
			ZIndex = 5,
		}),

		-- Count badge ("1/1") kept in the tree but hidden — toggle Visible back
		-- on if stacking ever returns. With max stack = 1 the number is noise.
		-- A locked slot has no count either way.
		RelicCountTextLabel = React.createElement("TextLabel", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.926),
			Size = UDim2.fromScale(0.782, 0.32),
			BackgroundTransparency = 1,
			Text = tostring(count) .. "/" .. tostring(relicInfo and RelicStackData[relicInfo.rarity] or 0),
			TextColor3 = if relicInfo and count == RelicStackData[relicInfo.rarity]
				then Color3.fromRGB(85, 255, 127)
				else Color3.fromRGB(255, 255, 255),
			TextStrokeColor3 = Color3.fromRGB(22, 22, 22),
			TextStrokeTransparency = 0.5,
			FontFace = Font.new(
				"rbxasset://fonts/families/Montserrat.json",
				Enum.FontWeight.Bold,
				Enum.FontStyle.Normal
			),
			TextScaled = true,
			Visible = false,
			ZIndex = 6,
		}),
	})
end

return RelicEntryContainer
