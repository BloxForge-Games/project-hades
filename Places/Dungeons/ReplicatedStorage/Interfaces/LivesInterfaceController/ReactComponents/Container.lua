--[[
     Module: Container.lua
     Description:
     Renders the local player's lives row. One HeartIcon per slot up to max;
     filled or dimmed based on current. Tracks the previous `current` value
     across LifeService.LivesData updates so we know which specific heart
     just changed — only that one animates (shrink-fade on loss, pop-in on
     gain), the others sit still.

]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local React = require(ReplicatedStorage.Submodules.Core.Packages.React)

--[ Tuning ]--

-- TODO: replace with project's final heart asset.
local HEART_IMAGE_ID = "rbxassetid://323045990"

local ROW_ANCHOR = Vector2.new(0.5, 1)
local ROW_POSITION = UDim2.fromScale(0.5, 0.78)
local ROW_SIZE = UDim2.fromOffset(324, 36)
local HEART_PADDING_PX = 6
local HEART_SIZE = UDim2.fromOffset(28, 28)
-- Alive / lost visual states.
local ALIVE_COLOR = Color3.fromRGB(255, 92, 92)
local ALIVE_TRANSPARENCY = 0
local LOST_COLOR = Color3.fromRGB(70, 70, 70)
local LOST_TRANSPARENCY = 0.45
-- Animation tunings.
local LOST_ANIM_DURATION = 0.35
local GAIN_ANIM_DURATION = 0.3
local CHANGE_CLEAR_DELAY = 0.6 -- how long after the change we clear the "just changed" flag

--[ Helpers ]--

local function tweenProperty(
	instance: Instance?,
	duration: number,
	properties: { [string]: any },
	easingStyle: Enum.EasingStyle?,
	easingDir: Enum.EasingDirection?
)
	if not instance then
		return nil
	end
	local tween = TweenService:Create(
		instance,
		TweenInfo.new(duration, easingStyle or Enum.EasingStyle.Quad, easingDir or Enum.EasingDirection.Out),
		properties
	)
	tween:Play()
	return tween
end

--[ HeartIcon ]--

local function HeartIcon(props: any)
	local isAlive = props.isAlive
	local justChanged = props.justChanged

	local imageRef = React.useRef(nil)

	React.useEffect(function()
		if not justChanged then
			return
		end
		local image = imageRef.current
		if not image then
			return
		end

		if justChanged == "lost" then
			image.Size = HEART_SIZE
			tweenProperty(image, LOST_ANIM_DURATION, {
				ImageColor3 = LOST_COLOR,
				ImageTransparency = LOST_TRANSPARENCY,
			})
			-- Settle back to base size after the punch.
			task.delay(LOST_ANIM_DURATION, function()
				tweenProperty(image, 0.15, { Size = HEART_SIZE })
			end)
		elseif justChanged == "gained" then
			-- Pop in from zero with a back-easing overshoot.
			image.Size = UDim2.fromOffset(0, 0)
			image.ImageColor3 = ALIVE_COLOR
			image.ImageTransparency = ALIVE_TRANSPARENCY
			tweenProperty(
				image,
				GAIN_ANIM_DURATION,
				{ Size = HEART_SIZE },
				Enum.EasingStyle.Back,
				Enum.EasingDirection.Out
			)
		end
	end, { justChanged })

	return React.createElement("ImageLabel", {
		ref = imageRef,
		Size = HEART_SIZE,
		BackgroundTransparency = 1,
		Image = HEART_IMAGE_ID,
		ImageColor3 = isAlive and ALIVE_COLOR or LOST_COLOR,
		ImageTransparency = isAlive and ALIVE_TRANSPARENCY or LOST_TRANSPARENCY,
		ScaleType = Enum.ScaleType.Fit,
		LayoutOrder = props.LayoutOrder,
		BorderSizePixel = 0,
	})
end

--[ Container ]--

local function Container(props: any)
	local LifeService = props.LifeService

	local livesData, setLivesData = React.useState(nil)
	local prevCurrentRef = React.useRef(nil)

	local justChangedState, setJustChangedState = React.useState(nil)

	React.useEffect(function()
		local observer = LifeService.LivesData:Observe(function(data: { [any]: any }?)
			local localId = Players.LocalPlayer.UserId

			local entry = data and (data[localId] or data[tostring(localId)])

			local change = nil
			local previous = prevCurrentRef.current
			if entry and previous ~= nil and entry.current ~= previous then
				if entry.current < previous then
					-- Index of the slot that JUST went out = the old current.
					change = { index = previous, direction = "lost" }
				else
					-- Index of the slot that JUST filled in = the new current.
					change = { index = entry.current, direction = "gained" }
				end
			end

			prevCurrentRef.current = entry and entry.current or nil
			setLivesData(entry)

			if change then
				setJustChangedState(change)
				task.delay(CHANGE_CLEAR_DELAY, function()
					setJustChangedState(nil)
				end)
			end
		end)

		return function()
			if observer then
				observer:Disconnect()
			end
		end
	end, {})

	-- Hide entirely until the server initializes lives for us.
	if not livesData or not livesData.max or livesData.max <= 0 then
		return nil
	end

	local children = {
		UIListLayout = React.createElement("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Left,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = UDim.new(0, HEART_PADDING_PX),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	}

	for i = 1, livesData.max do
		local justChanged = nil
		if justChangedState and justChangedState.index == i then
			justChanged = justChangedState.direction
		end
		children["Heart_" .. i] = React.createElement(HeartIcon, {
			isAlive = i <= livesData.current,
			justChanged = justChanged,
			LayoutOrder = i,
		})
	end

	return React.createElement("Frame", {
		AnchorPoint = ROW_ANCHOR,
		Position = ROW_POSITION,
		Size = ROW_SIZE,
		BackgroundTransparency = 1,
		Visible = false,
	}, children)
end

return Container
