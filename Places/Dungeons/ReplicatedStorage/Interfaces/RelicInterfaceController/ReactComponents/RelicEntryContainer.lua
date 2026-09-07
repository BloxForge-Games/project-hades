local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local React = require(ReplicatedStorage.Submodules.Core.Packages.React)
local RelicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicData)
local RelicStackData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicStackData)

local function RelicEntryContainer(props: any)
	local relicName = props.relicName
	local count = props.count
	local relicInfo = RelicData[relicName]
	local selectedRelic = props.selectedRelic
	local containerRef = React.useRef(nil)

	React.useEffect(function()
		if selectedRelic and selectedRelic.name == relicName then
			containerRef.current:TweenSize(
				UDim2.fromScale(1.25, 1.25),
				Enum.EasingDirection.Out,
				Enum.EasingStyle.Quad,
				0.25,
				true
			)
		else
			containerRef.current:TweenSize(
				UDim2.fromScale(1.1, 1.1),
				Enum.EasingDirection.Out,
				Enum.EasingStyle.Quad,
				0.25,
				true
			)
		end
	end, { selectedRelic })

	return React.createElement("ImageButton", {
		ref = containerRef,

		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1.1, 1.1),
		BackgroundColor3 = relicInfo and relicInfo.color or Color3.fromRGB(95, 95, 95),
		BackgroundTransparency = 0,
		ImageTransparency = 1,
		Active = if count == 0 or props.onClick == nil then false else true,
		Interactable = if count == 0 or props.onClick == nil then false else true,

		[React.Event.MouseEnter] = function()
			TweenService:Create(
				containerRef.current,
				TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Rotation = if math.random(1, 2) == 1 then -5 else 5 }
			):Play()

			containerRef.current:TweenSize(
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

			containerRef.current:TweenSize(
				UDim2.fromScale(1.1, 1.1),
				Enum.EasingDirection.Out,
				Enum.EasingStyle.Quad,
				0.25,
				true
			)
		end,

		[React.Event.Activated] = function()
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
			Color = if selectedRelic and selectedRelic.name == relicName
				then Color3.fromRGB(200, 200, 200)
				else Color3.fromRGB(22, 22, 22),
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
			Image = relicInfo and relicInfo.icon or "rbxassetid://72334652371090",
			BackgroundTransparency = 1,
			ScaleType = Enum.ScaleType.Fit,
			Visible = relicInfo ~= nil,
			ZIndex = 3,
		}),

		-- Count badge ("1/1") kept in the tree but hidden — toggle Visible back
		-- on if stacking ever returns. With max stack = 1 the number is noise.
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
