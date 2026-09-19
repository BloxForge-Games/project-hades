local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local React = require(ReplicatedStorage.Submodules.Core.Packages.React)
local RelicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicData)
local RelicStackData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicStackData)
local tweenGui = require(ReplicatedStorage.Submodules.Core.Shared.Functions.UI.tweenGui)

-- A LOCKED slot: a padlock on a dark box, past the run's open count. The
-- tray look is the default; the description card passes its own lighter
-- tint through `lockedLook`, since it sits on a lighter panel.
local LOCK_ICON = "rbxassetid://4830959937"
local DEFAULT_LOCKED_LOOK = {
	background = Color3.fromRGB(63, 63, 63),
	icon = Color3.fromRGB(35, 35, 35),
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
local function RelicEntryContainer(props: any)
	local relicName = props.relicName
	local count = props.count
	local relicInfo = RelicData[relicName]
	local selectedRelic = props.selectedRelic
	local locked = props.locked == true
	local slotIndex = props.slotIndex
	local lockedLook = props.lockedLook or DEFAULT_LOCKED_LOOK
	local containerRef = React.useRef(nil)

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
			else relicInfo and relicInfo.color or Color3.fromRGB(95, 95, 95),
		BackgroundTransparency = 0,
		ImageTransparency = 1,
		Active = interactable,
		Interactable = interactable,

		[React.Event.MouseEnter] = function()
			TweenService:Create(
				containerRef.current,
				TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Rotation = if math.random(1, 2) == 1 then -5 else 5 }
			):Play()

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
			CornerRadius = UDim.new(1, 0),
		}),

		UIStroke = React.createElement("UIStroke", {
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			Color = if isSelected then Color3.fromRGB(200, 200, 200) else Color3.fromRGB(22, 22, 22),
			StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize,
			Thickness = 0.03,
			ZIndex = 1,
		}),

		ShadowBackgroundImageLabel = React.createElement("ImageLabel", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(1, 1),
			Image = "rbxassetid://6096768861",
			BackgroundTransparency = 1,
			ImageColor3 = Color3.fromRGB(255, 255, 255),
			ImageTransparency = 0.35,
			ScaleType = Enum.ScaleType.Stretch,
			Visible = if locked then lockedLook.shadowVisible ~= false else true,
			ZIndex = 2,
		}, {
			UICorner = React.createElement("UICorner", {
				CornerRadius = UDim.new(1, 0),
			}),
		}),

		RelicIcon = React.createElement("ImageLabel", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(0.75, 0.75),
			Image = if locked then LOCK_ICON else relicInfo and relicInfo.icon or "rbxassetid://72334652371090",
			ImageColor3 = if locked then lockedLook.icon else Color3.fromRGB(255, 255, 255),
			BackgroundTransparency = 1,
			ScaleType = Enum.ScaleType.Fit,
			Visible = locked or relicInfo ~= nil,
			ZIndex = 3,
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
			ZIndex = 4,
		}),
	})
end

return RelicEntryContainer
