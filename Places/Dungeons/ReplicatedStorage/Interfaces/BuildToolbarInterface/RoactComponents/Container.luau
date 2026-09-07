--[[
     Module: Container.lua
     Description:
     Props screen UI
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ToolBarFragment = require(script.Parent.ToolBarFragment)
local React = require(ReplicatedStorage.Submodules.Core.Packages.React)
local ScreenSizes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ScreenSizes)

local function scaleUI(screenName, toolbarContainerRef, buildFrameRef, visible)
	if screenName == ScreenSizes.Mobile then
		if visible then
			toolbarContainerRef.current.Position = UDim2.fromScale(0.5, 0.90)
		else
			toolbarContainerRef.current.Position = UDim2.fromScale(0.5, 1.2)
		end

		buildFrameRef.current.Parent.Size = UDim2.fromOffset(39, 31)
		buildFrameRef.current.CancelTextLabel.TextSize = 9
		buildFrameRef.current.CancelKeycodeTextLabel.TextSize = 9
	else
		if visible then
			toolbarContainerRef.current.Position = UDim2.fromScale(0.5, 0.89)
		else
			toolbarContainerRef.current.Position = UDim2.fromScale(0.5, 1.2)
		end

		buildFrameRef.current.Parent.Size = UDim2.fromOffset(58, 48)
		buildFrameRef.current.CancelTextLabel.TextSize = 15
		buildFrameRef.current.CancelKeycodeTextLabel.TextSize = 15
	end
end

local function Container(props: any)
	local ScreenSizeController = props.ScreenSizeController

	local screenName, setScreenName = React.useState(ScreenSizeController:GetScreenSizeData().name)

	local activeIndex = props.activeIndex
	local toolbarData = props.toolbarData
	local buildClicked = props.buildClicked
	local setActiveBuild = props.setActiveBuild
	local buildLevelData = props.buildLevelData

	local toolbarContainerRef = React.useRef(nil)
	local cancelButtonRef = React.useRef(nil)

	React.useEffect(function()
		local conn = ScreenSizeController.Signals.ScreenSizeChanged:Connect(function(screenSizeData: table)
			setScreenName(screenSizeData.name)
		end)

		return function()
			conn:Disconnect()
		end
	end, {})

	React.useEffect(function()
		scaleUI(screenName, toolbarContainerRef, cancelButtonRef, props.Visible)
	end, { screenName })

	React.useEffect(function()
		if not toolbarContainerRef.current then
			return
		end

		if props.Visible then
			local targetPosition = screenName == ScreenSizes.Mobile and UDim2.fromScale(0.5, 0.90)
				or UDim2.fromScale(0.5, 0.89)

			toolbarContainerRef.current:TweenPosition(
				targetPosition,
				Enum.EasingDirection.Out,
				Enum.EasingStyle.Quint,
				0.75,
				true
			)
		else
			toolbarContainerRef.current:TweenPosition(
				UDim2.fromScale(0.5, 1.2),
				Enum.EasingDirection.Out,
				Enum.EasingStyle.Quint,
				0.75,
				true
			)
		end
	end, { props.Visible })

	return React.createElement("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.505),
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Visible = true,
	}, {
		ToolBarFrame = React.createElement("Frame", {
			ref = toolbarContainerRef,

			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.89),
			Size = UDim2.fromScale(0.1, 0.177),
			BackgroundTransparency = 1,
		}, {
			UIAspectRatioConstraint = React.createElement("UIAspectRatioConstraint", {
				AspectRatio = 1,
				AspectType = Enum.AspectType.FitWithinMaxSize,
			}),

			UIListLayout = React.createElement("UIListLayout", {
				FillDirection = Enum.FillDirection.Horizontal,
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),

			ToolBarFragment = React.createElement(ToolBarFragment, {
				buildLevelData = buildLevelData,
				activeIndex = activeIndex,
				toolbarData = toolbarData,
				buildClicked = buildClicked,
				screenName = screenName,
				setActiveBuild = setActiveBuild,
			}),

			-- Cancel Icon
			CancelIconButton = React.createElement("Frame", {
				LayoutOrder = 5,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Size = UDim2.fromOffset(58, 48),
				BackgroundTransparency = 1,
				ZIndex = 1,
				Visible = if screenName == ScreenSizes.Mobile then false else true,
			}, {
				ContainerFrame = React.createElement("ImageButton", {
					ref = cancelButtonRef,

					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.fromScale(0.5, 0.5),
					Size = UDim2.fromScale(1, 1),
					BackgroundColor3 = Color3.fromRGB(30, 30, 30),
					BackgroundTransparency = 0.25,
					ZIndex = 1,

					[React.Event.Activated] = function()
						props.setBuildMode(not props.Visible)
					end,
				}, {
					UIAspectRatioConstraint = React.createElement("UIAspectRatioConstraint", {
						AspectRatio = 1,
						AspectType = Enum.AspectType.FitWithinMaxSize,
					}),

					UICorner = React.createElement("UICorner", {
						CornerRadius = UDim.new(0.5, 0),
					}),

					UIStroke = React.createElement("UIStroke", {
						Color = Color3.fromRGB(35, 35, 35),
						Transparency = 0,
						StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize,
						Thickness = 0.05,
					}),

					CancelImageLabel = React.createElement("ImageLabel", {
						AnchorPoint = Vector2.new(0.5, 0.5),
						Position = UDim2.fromScale(0.5, 0.5),
						Size = UDim2.fromScale(0.5, 0.5),
						BackgroundTransparency = 1,
						Image = "rbxassetid://10152135063",
						ImageColor3 = Color3.fromRGB(255, 255, 255),
						ScaleType = Enum.ScaleType.Fit,
						ZIndex = 5,
					}),

					CancelKeycodeTextLabel = React.createElement("TextLabel", {
						AnchorPoint = Vector2.new(0.5, 0.5),
						Position = UDim2.fromScale(0.5, -0.025),
						Size = UDim2.fromScale(0.271, 0.271),
						BackgroundTransparency = 1,
						Text = "B",
						TextColor3 = Color3.fromRGB(255, 255, 255),
						TextWrapped = true,
						TextSize = 17,
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

					CancelTextLabel = React.createElement("TextLabel", {
						AnchorPoint = Vector2.new(0.5, 0.5),
						Position = UDim2.fromScale(0.5, 0.953),
						Size = UDim2.fromScale(1.2, 0.471),
						BackgroundTransparency = 1,
						Text = "Cancel",
						TextColor3 = Color3.fromRGB(255, 255, 255),
						TextWrapped = true,
						TextSize = 15,
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
				}),
			}),
		}),
	})
end

return Container
