--[[
     Module: Container.lua
     Description:
     Top-of-screen lobby HUD for the pre-encounter countdown (miniboss + boss
     share this widget). Element-by-element transparency fade on show / hide
     (no CanvasGroup) so it composes cleanly with other HUD overlays. Updates
     the displayed seconds every time the server pushes a new EncounterLobbyData
     snapshot.

     Generic by design: takes a single `data` prop with
     { kind, remainingSeconds, totalSeconds, playersOnPad, totalPlayers, accelerated }.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local React = require(ReplicatedStorage.Submodules.Core.Packages.React)

--[ Tuning ]--

local FADE_DURATION = 0.5
local FADE_STYLE = Enum.EasingStyle.Quad
local FADE_DIR = Enum.EasingDirection.Out

-- Resting transparencies (the visible target for each animated element).
local SECONDS_TEXT_VISIBLE = 0
local SECONDS_STROKE_VISIBLE = 0
local READY_TEXT_VISIBLE = 0
local READY_STROKE_VISIBLE = 0
local PROGRESS_BG_VISIBLE = 0
local PROGRESS_FILL_VISIBLE = 0

-- Color shift when the lobby goes into accelerated mode (all players on pad).
local DEFAULT_ACCENT = Color3.fromRGB(186, 101, 255) -- matches the pad
local ACCELERATED_ACCENT = Color3.fromRGB(120, 230, 120) -- green

--[ Helpers ]--

local function tweenProperty(instance: Instance?, duration: number, properties: { [string]: any })
	if not instance then
		return nil
	end
	local tween = TweenService:Create(instance, TweenInfo.new(duration, FADE_STYLE, FADE_DIR), properties)
	tween:Play()
	return tween
end

local function formatSeconds(seconds: number?): string
	if not seconds then
		return "0"
	end
	-- Show one decimal under 100s so the urgency reads, integer otherwise.
	if seconds < 100 then
		return string.format("%.1f", math.max(seconds, 0))
	end
	return tostring(math.ceil(seconds))
end

--[ Component ]--

local function Container(props: any)
	local data = props.data

	local secondsRef = React.useRef(nil)
	local secondsStrokeRef = React.useRef(nil)
	local minibossStrokeRef = React.useRef(nil)
	local readyRef = React.useRef(nil)
	local readyStrokeRef = React.useRef(nil)
	local progressBgRef = React.useRef(nil)
	local progressFillRef = React.useRef(nil)
	local levelStrokeRef = React.useRef(nil)
	local progressStrokeRef = React.useRef(nil)
	local shadowImageRef = React.useRef(nil)

	-- Hold the last non-nil snapshot so the widget keeps its text during fade-out.
	local displayData, setDisplayData = React.useState(nil)

	-- Token-guarded transition: bumped on each visibility flip so back-to-back
	-- toggles abort their counterparts cleanly.
	local transitionTokenRef = React.useRef(0)

	React.useEffect(function()
		if data then
			setDisplayData(data)
		end
	end, { data })

	-- Visibility transitions.
	React.useEffect(function()
		transitionTokenRef.current += 1
		local myToken = transitionTokenRef.current

		if data and not displayData then
			-- Wait one render for refs to populate before fading in.
			task.defer(function()
				if transitionTokenRef.current ~= myToken then
					return
				end

				tweenProperty(secondsRef.current, FADE_DURATION, { TextTransparency = SECONDS_TEXT_VISIBLE })
				tweenProperty(secondsStrokeRef.current, FADE_DURATION, { Transparency = SECONDS_STROKE_VISIBLE })
				tweenProperty(readyRef.current, FADE_DURATION, { TextTransparency = READY_TEXT_VISIBLE })
				tweenProperty(readyStrokeRef.current, FADE_DURATION, { Transparency = READY_STROKE_VISIBLE })
				tweenProperty(progressBgRef.current, FADE_DURATION, { BackgroundTransparency = PROGRESS_BG_VISIBLE })
				tweenProperty(minibossStrokeRef.current, FADE_DURATION, { Transparency = READY_STROKE_VISIBLE })
				tweenProperty(
					progressFillRef.current,
					FADE_DURATION,
					{ BackgroundTransparency = PROGRESS_FILL_VISIBLE }
				)
				tweenProperty(progressStrokeRef.current, FADE_DURATION, { Transparency = READY_STROKE_VISIBLE })
				tweenProperty(levelStrokeRef.current, FADE_DURATION, { Transparency = READY_STROKE_VISIBLE })
				tweenProperty(shadowImageRef.current, FADE_DURATION + 0.5, { ImageTransparency = 0.75 })
			end)
		elseif not data and displayData then
			task.defer(function()
				if transitionTokenRef.current ~= myToken then
					return
				end

				tweenProperty(secondsRef.current, FADE_DURATION, { TextTransparency = 1 })
				tweenProperty(secondsStrokeRef.current, FADE_DURATION, { Transparency = 1 })
				tweenProperty(readyRef.current, FADE_DURATION, { TextTransparency = 1 })
				tweenProperty(readyStrokeRef.current, FADE_DURATION, { Transparency = 1 })
				tweenProperty(progressBgRef.current, FADE_DURATION, { BackgroundTransparency = 1 })
				tweenProperty(progressFillRef.current, FADE_DURATION, { BackgroundTransparency = 1 })
				tweenProperty(minibossStrokeRef.current, FADE_DURATION, { Transparency = 1 })
				tweenProperty(levelStrokeRef.current, FADE_DURATION, { Transparency = 1 })
				tweenProperty(progressStrokeRef.current, FADE_DURATION, { Transparency = 1 })
				tweenProperty(shadowImageRef.current, FADE_DURATION, { ImageTransparency = 1 })

				task.wait(FADE_DURATION)
				if transitionTokenRef.current ~= myToken then
					return
				end
				setDisplayData(nil)
			end)
		end
	end, { data })

	-- Progress bar fill tracks remaining / total.
	React.useEffect(function()
		local fill = progressFillRef.current
		if not fill or not data then
			return
		end
		local ratio = math.clamp(data.remainingSeconds / math.max(data.totalSeconds, 0.001), 0, 1)
		TweenService:Create(
			fill,
			TweenInfo.new(0.15, Enum.EasingStyle.Linear, Enum.EasingDirection.Out),
			{ Size = UDim2.fromScale(ratio, 1) }
		):Play()
	end, { data and data.remainingSeconds, data and data.totalSeconds })

	local remaining = formatSeconds(displayData and displayData.remainingSeconds)
	local onPad = displayData and displayData.playersOnPad or 0
	local totalPlayers = displayData and displayData.totalPlayers or 0
	local accelerated = displayData and displayData.accelerated or false
	local accent = accelerated and ACCELERATED_ACCENT or DEFAULT_ACCENT

	return React.createElement("Frame", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.085),
		Size = UDim2.fromScale(0.256, 0.122),
		BackgroundTransparency = 1,
		Visible = displayData ~= nil,
	}, {
		PlayersReadyLabel = React.createElement("TextLabel", {
			ref = readyRef,

			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.fromScale(0.5, 0.488),
			Size = UDim2.fromScale(0.939, 0.243),
			BackgroundTransparency = 1,
			-- `readyLabel` is an optional server-authored override (the Coffin
			-- challenge shows kills, not a pad count).
			Text = (data and data.readyLabel) or ("(" .. onPad .. " / " .. totalPlayers .. " Ready)"),
			TextColor3 = if onPad == totalPlayers then Color3.fromRGB(85, 255, 127) else Color3.fromRGB(255, 255, 255),
			TextScaled = true,
			TextTransparency = 1,
			FontFace = Font.new(
				"rbxasset://fonts/families/Montserrat.json",
				Enum.FontWeight.Bold,
				Enum.FontStyle.Normal
			),
			ZIndex = 3,
		}, {
			UIStroke = React.createElement("UIStroke", {
				ref = readyStrokeRef,

				Color = Color3.fromRGB(20, 20, 20),
				StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize,
				Thickness = 0.05,
				Transparency = 1,
			}),
		}),

		MinibossRoomLabel = React.createElement("TextLabel", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.068),
			Size = UDim2.fromScale(0.672, 0.299),
			BackgroundTransparency = 1,
			-- `label` is server-authored ("Miniboss Room", "Next Dungeon");
			-- kind is the fallback for older payloads.
			Text = data and "- " .. (data.label or (data.kind .. " Room")) .. " -" or "",
			TextColor3 = if onPad == totalPlayers then Color3.fromRGB(85, 255, 127) else Color3.fromRGB(255, 255, 255),
			TextScaled = true,
			FontFace = Font.new(
				"rbxasset://fonts/families/Montserrat.json",
				Enum.FontWeight.Bold,
				Enum.FontStyle.Normal
			),
			ZIndex = 2,
		}, {
			UIStroke = React.createElement("UIStroke", {
				ref = minibossStrokeRef,

				Color = Color3.fromRGB(20, 20, 20),
				StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize,
				Thickness = 0.06,
				Transparency = 1,
			}),
		}),

		SecondsLabel = React.createElement("TextLabel", {
			ref = secondsRef,

			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.659),
			Size = UDim2.fromScale(0.405, 0.275),
			BackgroundTransparency = 1,
			Text = remaining .. "s",
			TextColor3 = if onPad == totalPlayers then Color3.fromRGB(85, 255, 127) else Color3.fromRGB(255, 255, 255),
			TextScaled = true,
			TextTransparency = 1,
			FontFace = Font.new(
				"rbxasset://fonts/families/Montserrat.json",
				Enum.FontWeight.Bold,
				Enum.FontStyle.Normal
			),
			ZIndex = 3,
		}, {
			UIStroke = React.createElement("UIStroke", {
				ref = secondsStrokeRef,

				Color = Color3.fromRGB(20, 20, 20),
				StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize,
				Thickness = 0.05,
				Transparency = 1,
			}),
		}),

		ShadowBackgroundImageLabel = React.createElement("ImageLabel", {
			ref = shadowImageRef,

			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.4),
			Size = UDim2.fromScale(1.418, 2.077),
			BackgroundTransparency = 1,
			Image = "rbxassetid://90190541001824",
			ScaleType = Enum.ScaleType.Stretch,
			ImageTransparency = 1,
			ZIndex = 1,
		}),

		ProgressBarBg = React.createElement("Frame", {
			ref = progressBgRef,

			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.fromScale(0.5, 0.708),
			Size = UDim2.fromScale(0.95, 0.08),
			BackgroundColor3 = Color3.fromRGB(50, 50, 50),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			ZIndex = 2,
		}, {
			UICorner = React.createElement("UICorner", {
				CornerRadius = UDim.new(0.15, 0),
			}),

			ShadowGradientImageLabel = React.createElement("ImageLabel", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromScale(1, 1),
				BackgroundTransparency = 1,
				Image = "rbxassetid://6096768861",
				ScaleType = Enum.ScaleType.Stretch,
				ImageTransparency = 0.8,
				ZIndex = 10,
			}, {
				UICorner = React.createElement("UICorner", {
					CornerRadius = UDim.new(0.15, 0),
				}),
			}),

			UIStroke = React.createElement("UIStroke", {
				ref = levelStrokeRef,

				Color = Color3.fromRGB(20, 20, 20),
				StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize,
				Thickness = 0.125,
				Transparency = 1,
			}),

			ProgressFill = React.createElement("Frame", {
				ref = progressFillRef,

				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.fromScale(0, 0.5),
				Size = UDim2.fromScale(1, 1), -- animated by the progress effect above
				BackgroundColor3 = accent,
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				ZIndex = 3,
			}, {

				UIStroke = React.createElement("UIStroke", {
					ref = progressStrokeRef,

					Color = Color3.fromRGB(20, 20, 20),
					StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize,
					Thickness = 0.125,
					Transparency = 1,
				}),

				UICorner = React.createElement("UICorner", {
					CornerRadius = UDim.new(0.15, 0),
				}),
			}),
		}),
	})
end

return Container
