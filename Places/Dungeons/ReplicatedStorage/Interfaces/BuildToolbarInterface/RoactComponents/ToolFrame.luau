local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage.Submodules.Core.Packages.React)
local ScreenSizes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ScreenSizes)
local BuildData = require(ReplicatedStorage.Submodules.Core.Shared.Data.BuildData)

return function(props: any)
	local layoutOrder = props.LayoutOrder
	local activeIndex = props.activeIndex
	local buildClicked = props.buildClicked
	local screenName = props.screenName
	local data = props.data
	local setActiveBuild = props.setActiveBuild
	local buildLevelData = props.buildLevelData

	local containerRef = React.useRef(nil)

	local cost = if data and data.name then BuildData[data.name].cost else "N/A"
	local buildLevel = if data and data.name and buildLevelData[data.name] then buildLevelData[data.name] else 0
	cost = cost * buildLevel

	-- local costText = if buildLevel > 0 then "(Lvl. " .. tostring(buildLevel) .. ") " .. tostring(cost) else "N/A"

	React.useEffect(function()
		if not containerRef.current then
			return
		end

		if activeIndex == layoutOrder then
			containerRef.current:TweenSize(
				UDim2.fromScale(1.15, 1.15),
				Enum.EasingDirection.Out,
				Enum.EasingStyle.Quad,
				0.15,
				true
			)

			setActiveBuild(data.name)
		else
			containerRef.current:TweenSize(
				UDim2.fromScale(1, 1),
				Enum.EasingDirection.Out,
				Enum.EasingStyle.Quad,
				0.15,
				true
			)
		end
	end, { activeIndex })

	React.useEffect(function()
		if screenName == ScreenSizes.Mobile then
			containerRef.current.Parent.Size = UDim2.fromOffset(46, 36)
			containerRef.current.BuildCostTextLabel.TextSize = 11
			containerRef.current.BuildNumberTextLabel.TextSize = 9
		else
			containerRef.current.Parent.Size = UDim2.fromOffset(69, 57)
			containerRef.current.BuildCostTextLabel.TextSize = 18
			containerRef.current.BuildNumberTextLabel.TextSize = 14
		end
	end, { screenName })

	React.useEffect(function()
		if screenName == ScreenSizes.Mobile then
			containerRef.current.Parent.Size = UDim2.fromOffset(46, 36)
			containerRef.current.BuildCostTextLabel.TextSize = 11
			containerRef.current.BuildNumberTextLabel.TextSize = 9
		else
			containerRef.current.Parent.Size = UDim2.fromOffset(69, 57)
			containerRef.current.BuildCostTextLabel.TextSize = 18
			containerRef.current.BuildNumberTextLabel.TextSize = 14
		end
	end, {})

	-- React.useEffect(function()
	-- 	if not containerRef.current then
	-- 		return
	-- 	end

	-- 	if activeIndex == layoutOrder then
	-- 		if screenName == ScreenSizes.Mobile then
	-- 			containerRef.current.Parent.Size = UDim2.fromOffset(46, 36)
	-- 			containerRef.current.BuildCostTextLabel.TextSize = 10
	-- 			containerRef.current.BuildNumberTextLabel.TextSize = 9
	-- 		else
	-- 			containerRef.current.Parent.Size = UDim2.fromOffset(69, 57)
	-- 			containerRef.current.BuildCostTextLabel.TextSize = 15
	-- 			containerRef.current.BuildNumberTextLabel.TextSize = 14
	-- 		end
	-- 	else
	-- 		if screenName == ScreenSizes.Mobile then
	-- 			containerRef.current.Parent.Size = UDim2.fromOffset(46, 36)
	-- 			containerRef.current.BuildCostTextLabel.TextSize = 11
	-- 			containerRef.current.BuildNumberTextLabel.TextSize = 9
	-- 		else
	-- 			containerRef.current.Parent.Size = UDim2.fromOffset(69, 57)
	-- 			containerRef.current.BuildCostTextLabel.TextSize = 18
	-- 			containerRef.current.BuildNumberTextLabel.TextSize = 14
	-- 		end
	-- 	end
	-- end, { activeIndex })

	return React.createElement("Frame", {
		LayoutOrder = layoutOrder,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(69, 57),
		BackgroundTransparency = 1,
		ZIndex = 1,
	}, {
		ContainerFrame = React.createElement("ImageButton", {
			ref = containerRef,

			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = Color3.fromRGB(30, 30, 30),
			BackgroundTransparency = 0.25,
			ZIndex = 1,

			[React.Event.Activated] = function()
				buildClicked(layoutOrder)
			end,
		}, {
			UIAspectRatioConstraint = React.createElement("UIAspectRatioConstraint", {
				AspectRatio = 1,
				AspectType = Enum.AspectType.FitWithinMaxSize,
			}),

			UICorner = React.createElement("UICorner", {
				CornerRadius = UDim.new(0.125, 0),
			}),

			OuterOutlineImageLabel = React.createElement("ImageLabel", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromScale(1, 1),
				BackgroundTransparency = 1,
				Image = "rbxassetid://6096768861",
				ScaleType = Enum.ScaleType.Stretch,
				ImageColor3 = Color3.fromRGB(255, 255, 255),
				ImageTransparency = if activeIndex == layoutOrder then 0.35 else 0.1,
				ZIndex = 10,
			}, {
				UICorner = React.createElement("UICorner", {
					CornerRadius = UDim.new(0.125, 0),
				}),
			}),

			BuildIconImageLabel = React.createElement("ImageLabel", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromScale(0.7, 0.7),
				BackgroundTransparency = 1,
				Image = "rbxassetid://72334652371090",
				ScaleType = Enum.ScaleType.Fit,
				ZIndex = 5,
			}),

			BuildCostTextLabel = React.createElement("TextLabel", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.953),
				Size = UDim2.fromScale(1.25, 0.471),
				BackgroundTransparency = 1,
				Text = cost, --if activeIndex == layoutOrder then costText else cost,
				TextColor3 = if activeIndex == layoutOrder
					then Color3.fromRGB(255, 255, 255)
					else Color3.fromRGB(175, 175, 175),
				TextWrapped = true,
				TextSize = 18,
				TextStrokeTransparency = 0.5,
				TextXAlignment = Enum.TextXAlignment.Center,
				TextYAlignment = Enum.TextYAlignment.Center,
				FontFace = Font.new(
					"rbxasset://fonts/families/Montserrat.json",
					Enum.FontWeight.ExtraBold,
					Enum.FontStyle.Normal
				),
				ZIndex = 20,
			}),

			BuildNumberTextLabel = React.createElement("TextLabel", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.18, 0.19),
				Size = UDim2.fromScale(0.271, 0.271),
				BackgroundTransparency = 1,
				Text = tostring(layoutOrder),
				TextColor3 = Color3.fromRGB(255, 255, 255),
				TextWrapped = true,
				TextSize = 14,
				TextStrokeTransparency = 0.5,
				TextXAlignment = Enum.TextXAlignment.Center,
				TextYAlignment = Enum.TextYAlignment.Center,
				FontFace = Font.new(
					"rbxasset://fonts/families/Montserrat.json",
					Enum.FontWeight.ExtraBold,
					Enum.FontStyle.Normal
				),
				ZIndex = 20,
			}),

			UnequipFrame = React.createElement("CanvasGroup", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromScale(1, 1),
				BackgroundColor3 = Color3.fromRGB(0, 0, 0),
				BackgroundTransparency = if activeIndex == layoutOrder then 1 else 0.5,
				ZIndex = 15,
				Visible = true,
			}, {
				UIAspectRatioConstraint = React.createElement("UIAspectRatioConstraint", {
					AspectRatio = 1,
					AspectType = Enum.AspectType.FitWithinMaxSize,
				}),

				UICorner = React.createElement("UICorner", {
					CornerRadius = UDim.new(0.125, 0),
				}),
			}),
		}),
	})
end
