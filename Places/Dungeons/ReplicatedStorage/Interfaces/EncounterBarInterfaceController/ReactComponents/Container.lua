--[[
     Module: Container.lua
     Description:
     Boss-bar UI for the active miniboss / boss fight. Centered along the top
     of the screen, fades in element-by-element when `data` is set and fades
     out the same way when it clears. The first time it appears, the HP fill
     starts at 0 width and slowly fills up to its true ratio for a dramatic
     reveal; subsequent HP changes use a fast tween.

     Generic by design: takes a single `data = { name, level, currentHP, maxHP }`
     prop so the same component can power the boss interface later.

     No CanvasGroup wrapper — each animated element manages its own transparency
     so future siblings outside the bar (portrait icons, status pips, etc.) can
     fade independently without inheriting a group-clip.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local React = require(ReplicatedStorage.Submodules.Core.Packages.React)
local ZombieData = require(ReplicatedStorage.Submodules.Core.Shared.Data.ZombieData)

--[ Tuning ]--

-- All transparency tweens use this duration / easing for a consistent look.
local FADE_DURATION = 0.35
local FADE_STYLE = Enum.EasingStyle.Quint
local FADE_DIR = Enum.EasingDirection.Out

-- Slide-in / slide-out of the WHOLE bar. It tweens DOWN from above the screen
-- to its resting position when it should be visible, and UP off the top of the
-- screen when hidden — which happens both when the encounter ends AND while a
-- boss phase-change cutscene is playing (props.phaseHidden). Replaces the old
-- plain Visible toggle as the gross show/hide; the per-element fades still play
-- on top for the dramatic reveal. Duration matches FADE_DURATION so the slide
-- and the element fades finish together.
local SLIDE_VISIBLE_POSITION = UDim2.fromScale(0.5, 0.15)
local SLIDE_HIDDEN_POSITION = UDim2.fromScale(0.5, -0.3)
local SLIDE_DURATION = FADE_DURATION
local SLIDE_STYLE = Enum.EasingStyle.Quint
local SLIDE_DIR = Enum.EasingDirection.Out

-- First-show dramatic HP fill-up. Slow enough to read as a reveal beat.
local DRAMATIC_FILL_DURATION = 1
local DRAMATIC_FILL_STYLE = Enum.EasingStyle.Quint
local DRAMATIC_FILL_DIR = Enum.EasingDirection.Out

-- Per-tick HP change after the intro completes.
local HP_TWEEN_DURATION = 0.25
local HP_TWEEN_STYLE = Enum.EasingStyle.Quad
local HP_TWEEN_DIR = Enum.EasingDirection.Out

-- "Damage trail" white bar that sits behind the red HP fill and shrinks more
-- slowly, so each hit leaves a visible white sliver showing how much HP was
-- just lost before the trail catches up.
local HP_TRAIL_TWEEN_DURATION = 4
local HP_TRAIL_TWEEN_STYLE = Enum.EasingStyle.Quad
local HP_TRAIL_TWEEN_DIR = Enum.EasingDirection.Out

-- Resting transparencies — the "visible" target each element tweens to on
-- fade-in and from on fade-out. Centralized so retheming the bar doesn't
-- require touching the visibility effect below.
local NAME_TEXT_VISIBLE = 0
local NAME_STROKE_VISIBLE = 0
local LEVEL_TEXT_VISIBLE = 0
local LEVEL_STROKE_VISIBLE = 0
local HP_BG_VISIBLE = 0
local HP_BG_STROKE_VISIBLE = 0
local SHADOW_VISIBLE = 0.75 -- matches the original ImageTransparency
local HP_FILL_VISIBLE = 0
local HEALTH_COUNTER_TEXT_VISIBLE = 0
local HEALTH_COUNTER_STROKE_VISIBLE = 0

--[ Helpers ]--

local function tweenProperty(instance: Instance?, duration: number, properties: { [string]: any }, style, dir)
	if not instance then
		return nil
	end
	local tween = TweenService:Create(instance, TweenInfo.new(duration, style, dir), properties)
	tween:Play()
	return tween
end

local function clampRatio(currentHP: number?, maxHP: number?): number
	if not currentHP or not maxHP then
		return 0
	end
	return math.clamp(currentHP / math.max(maxHP, 1), 0, 1)
end

--[ Component ]--

local function Container(props: any)
	local data = props.data

	-- Refs for every animated element. No CanvasGroup — each one is tweened
	-- individually so future elements outside the bar can fade independently.
	local nameLabelRef = React.useRef(nil)
	local nameStrokeRef = React.useRef(nil)
	local levelLabelRef = React.useRef(nil)
	local levelStrokeRef = React.useRef(nil)
	local hpBgRef = React.useRef(nil)
	local hpBgStrokeRef = React.useRef(nil)
	local shadowRef = React.useRef(nil)
	local hpFillRef = React.useRef(nil)
	local subtitleNameLabelRef = React.useRef(nil)
	local subtitleNameStrokeRef = React.useRef(nil)
	local shadowImageRef = React.useRef(nil)

	-- Root frame, slid on/off screen by the visibility effect below.
	local rootRef = React.useRef(nil)

	-- White damage-trail bar that sits behind hpFill and lags one slower tween
	-- behind it. Same Size as hpFill at rest; visibly diverges only during a
	-- hit, when hpFill shrinks immediately and the trail catches up over
	-- HP_TRAIL_TWEEN_DURATION.
	local hpTrailRef = React.useRef(nil)
	-- "currentHP / maxHP" numeric counter centered on the HP bar.
	local healthCounterRef = React.useRef(nil)
	local healthCounterStrokeRef = React.useRef(nil)

	-- Held copy of the last non-nil data. Stays populated through fade-out so
	-- name / level don't blank mid-animation.
	local displayData, setDisplayData = React.useState(nil)

	-- Has the dramatic intro completed for the current "fight"? Reset to false
	-- when data goes nil so the next show plays the intro again.
	local hasShownRef = React.useRef(false)

	-- Tracks whether `data` was non-nil on the previous effect run. The
	-- visibility effect re-fires on every data identity change (the server
	-- sends a new EncounterData table on every HP tick), but we only want to
	-- run a show / hide transition when the *presence* of the data actually
	-- flips. Without this gate every mid-intro HP tick used to bump the
	-- transition token and abort the running intro, leaving hasShownRef
	-- stuck false and freezing the bar.
	local wasPresentRef = React.useRef(false)

	-- Counter bumped on every actual visibility transition (presence flip).
	-- The deferred intro / hide routines check it before each step so
	-- back-to-back toggles abort cleanly instead of fighting each other.
	local transitionTokenRef = React.useRef(0)

	-- Promote new data immediately. The fade-out effect clears displayData
	-- only after its animation finishes.
	React.useEffect(function()
		if data then
			setDisplayData(data)
		end
	end, { data })

	-- Fast HP tween on damage. Skipped during the dramatic intro — the intro
	-- routine drives the fill itself so this would fight it.
	React.useEffect(function()
		if not data then
			return
		end
		if not hasShownRef.current then
			return
		end
		local ratio = clampRatio(data.currentHP, data.maxHP)
		local targetSize = UDim2.fromScale(ratio, 1)

		local fill = hpFillRef.current
		if fill then
			tweenProperty(fill, HP_TWEEN_DURATION, { Size = targetSize }, HP_TWEEN_STYLE, HP_TWEEN_DIR)
		end
		-- White trail catches up to the new ratio on a slower tween, leaving
		-- a visible "damage taken" sliver behind the red bar in the meantime.
		local trail = hpTrailRef.current
		if trail then
			tweenProperty(
				trail,
				HP_TRAIL_TWEEN_DURATION,
				{ Size = targetSize },
				HP_TRAIL_TWEEN_STYLE,
				HP_TRAIL_TWEEN_DIR
			)
		end
	end, { data and data.currentHP, data and data.maxHP })

	-- Visibility transitions: dramatic intro on nil → present, reverse fade on
	-- present → nil. task.defer so refs are populated by the time the spawned
	-- routine reads them (the render with Visible=true commits first).
	--
	-- IMPORTANT: this effect runs whenever `data` identity changes, including
	-- per-tick HP updates from the server. We only want to *act* when the
	-- presence of the data actually flips (nil ↔ present). Otherwise every
	-- mid-intro HP tick would bump the transition token and abort the running
	-- intro (leaving hasShownRef stuck at false → the fast HP tween effect
	-- below skips forever → frozen bar).
	React.useEffect(function()
		local isPresent = data ~= nil
		local wasPresent = wasPresentRef.current
		wasPresentRef.current = isPresent

		if isPresent == wasPresent then
			return
		end

		transitionTokenRef.current += 1
		local myToken = transitionTokenRef.current

		if isPresent then
			-- nil → present: dramatic intro.
			if hasShownRef.current then
				return
			end

			task.defer(function()
				if transitionTokenRef.current ~= myToken then
					return
				end
				if not hpFillRef.current or not nameLabelRef.current then
					return
				end

				-- Snap HP fill (and its trail) to 0 BEFORE fading anything else
				-- in so the dramatic fill-up has somewhere to start from.
				hpFillRef.current.Size = UDim2.fromScale(0, 1)
				if hpTrailRef.current then
					hpTrailRef.current.Size = UDim2.fromScale(0, 1)
				end

				-- Stage 1: fade every element in to its visible resting value.
				tweenProperty(
					nameLabelRef.current,
					FADE_DURATION,
					{ TextTransparency = NAME_TEXT_VISIBLE },
					FADE_STYLE,
					FADE_DIR
				)
				tweenProperty(
					nameStrokeRef.current,
					FADE_DURATION,
					{ Transparency = NAME_STROKE_VISIBLE },
					FADE_STYLE,
					FADE_DIR
				)
				tweenProperty(
					levelLabelRef.current,
					FADE_DURATION,
					{ TextTransparency = LEVEL_TEXT_VISIBLE },
					FADE_STYLE,
					FADE_DIR
				)
				tweenProperty(
					levelStrokeRef.current,
					FADE_DURATION,
					{ Transparency = LEVEL_STROKE_VISIBLE },
					FADE_STYLE,
					FADE_DIR
				)
				tweenProperty(
					hpBgRef.current,
					FADE_DURATION,
					{ BackgroundTransparency = HP_BG_VISIBLE },
					FADE_STYLE,
					FADE_DIR
				)
				tweenProperty(
					hpBgStrokeRef.current,
					FADE_DURATION,
					{ Transparency = HP_BG_STROKE_VISIBLE },
					FADE_STYLE,
					FADE_DIR
				)
				tweenProperty(
					shadowRef.current,
					FADE_DURATION,
					{ ImageTransparency = SHADOW_VISIBLE },
					FADE_STYLE,
					FADE_DIR
				)
				tweenProperty(
					hpFillRef.current,
					FADE_DURATION,
					{ BackgroundTransparency = HP_FILL_VISIBLE },
					FADE_STYLE,
					FADE_DIR
				)
				tweenProperty(shadowImageRef.current, FADE_DURATION, { ImageTransparency = 0.75 }, FADE_STYLE, FADE_DIR)
				-- Trail fades in with the same timing as the red fill so they
				-- look like a single bar during the intro.
				tweenProperty(hpTrailRef.current, FADE_DURATION, { BackgroundTransparency = 0 }, FADE_STYLE, FADE_DIR)
				tweenProperty(
					healthCounterRef.current,
					FADE_DURATION,
					{ TextTransparency = HEALTH_COUNTER_TEXT_VISIBLE },
					FADE_STYLE,
					FADE_DIR
				)
				tweenProperty(
					healthCounterStrokeRef.current,
					FADE_DURATION,
					{ Transparency = HEALTH_COUNTER_STROKE_VISIBLE },
					FADE_STYLE,
					FADE_DIR
				)
				tweenProperty(
					subtitleNameLabelRef.current,
					FADE_DURATION,
					{ TextTransparency = NAME_TEXT_VISIBLE },
					FADE_STYLE,
					FADE_DIR
				)
				tweenProperty(
					subtitleNameStrokeRef.current,
					FADE_DURATION,
					{ Transparency = NAME_STROKE_VISIBLE },
					FADE_STYLE,
					FADE_DIR
				)

				task.wait(FADE_DURATION)
				if transitionTokenRef.current ~= myToken then
					return
				end

				-- Stage 2: dramatic HP fill from 0 to current ratio. Read data
				-- via the upvalue captured when the intro began. The trail
				-- tracks the same animation so they reach full ratio together;
				-- damage-trailing only becomes visible once the intro ends and
				-- HP actually changes.
				local ratio = clampRatio(data.currentHP, data.maxHP)
				local targetSize = UDim2.fromScale(ratio, 1)
				tweenProperty(
					hpFillRef.current,
					DRAMATIC_FILL_DURATION,
					{ Size = targetSize },
					DRAMATIC_FILL_STYLE,
					DRAMATIC_FILL_DIR
				)
				tweenProperty(
					hpTrailRef.current,
					DRAMATIC_FILL_DURATION,
					{ Size = targetSize },
					DRAMATIC_FILL_STYLE,
					DRAMATIC_FILL_DIR
				)

				task.wait(DRAMATIC_FILL_DURATION)
				if transitionTokenRef.current ~= myToken then
					return
				end

				-- Intro complete; further HP changes now use the fast tween.
				hasShownRef.current = true
			end)
		else
			-- present → nil: reverse fade. Skip if we never showed.
			if not displayData then
				return
			end

			task.defer(function()
				if transitionTokenRef.current ~= myToken then
					return
				end
				if not nameLabelRef.current then
					return
				end

				tweenProperty(shadowImageRef.current, FADE_DURATION, { ImageTransparency = 1 }, FADE_STYLE, FADE_DIR)
				tweenProperty(nameLabelRef.current, FADE_DURATION, { TextTransparency = 1 }, FADE_STYLE, FADE_DIR)
				tweenProperty(nameStrokeRef.current, FADE_DURATION, { Transparency = 1 }, FADE_STYLE, FADE_DIR)
				tweenProperty(levelLabelRef.current, FADE_DURATION, { TextTransparency = 1 }, FADE_STYLE, FADE_DIR)
				tweenProperty(levelStrokeRef.current, FADE_DURATION, { Transparency = 1 }, FADE_STYLE, FADE_DIR)
				tweenProperty(hpBgRef.current, FADE_DURATION, { BackgroundTransparency = 1 }, FADE_STYLE, FADE_DIR)
				tweenProperty(hpBgStrokeRef.current, FADE_DURATION, { Transparency = 1 }, FADE_STYLE, FADE_DIR)
				tweenProperty(shadowRef.current, FADE_DURATION, { ImageTransparency = 1 }, FADE_STYLE, FADE_DIR)
				tweenProperty(hpFillRef.current, FADE_DURATION, { BackgroundTransparency = 1 }, FADE_STYLE, FADE_DIR)
				tweenProperty(hpTrailRef.current, FADE_DURATION, { BackgroundTransparency = 1 }, FADE_STYLE, FADE_DIR)
				tweenProperty(healthCounterRef.current, FADE_DURATION, { TextTransparency = 1 }, FADE_STYLE, FADE_DIR)
				tweenProperty(healthCounterStrokeRef.current, FADE_DURATION, { Transparency = 1 }, FADE_STYLE, FADE_DIR)
				tweenProperty(
					subtitleNameLabelRef.current,
					FADE_DURATION,
					{ TextTransparency = 1 },
					FADE_STYLE,
					FADE_DIR
				)
				tweenProperty(subtitleNameStrokeRef.current, FADE_DURATION, { Transparency = 1 }, FADE_STYLE, FADE_DIR)
				task.wait(FADE_DURATION)
				if transitionTokenRef.current ~= myToken then
					return
				end

				-- Drop held data and reset intro flag so the next show replays
				-- the dramatic reveal.
				setDisplayData(nil)
				hasShownRef.current = false
			end)
		end
	end, { data })

	-- Slide the whole bar down into view when it should be visible, up off the
	-- top of the screen when not. "Visible" here = an encounter is active AND
	-- we're not in a boss phase-change cutscene (props.phaseHidden). Driven
	-- imperatively on rootRef so it composes with the per-element fades above;
	-- the static Position prop stays at SLIDE_HIDDEN_POSITION so React only
	-- applies it on mount and never fights this tween. Deps gate on the derived
	-- boolean, so per-tick HP updates (which don't flip it) don't re-slide.
	local shouldShow = data ~= nil and not props.phaseHidden
	React.useEffect(function()
		local root = rootRef.current
		if not root then
			return
		end
		local target = if shouldShow then SLIDE_VISIBLE_POSITION else SLIDE_HIDDEN_POSITION
		tweenProperty(root, SLIDE_DURATION, { Position = target }, SLIDE_STYLE, SLIDE_DIR)
	end, { shouldShow })

	local name = displayData and displayData.name or ""
	local level = displayData and displayData.level or 1

	-- Layout preserved from the original design. Only the root is changed
	-- from CanvasGroup to Frame so individual elements can fade independently.
	return React.createElement("Frame", {
		ref = rootRef,

		AnchorPoint = Vector2.new(0.5, 0.5),
		-- Static start position is OFF-SCREEN (slid up); the slide effect tweens
		-- it down to SLIDE_VISIBLE_POSITION. Keeping the prop static means React
		-- only applies it on mount and never fights the imperative slide tween.
		Position = SLIDE_HIDDEN_POSITION,
		Size = UDim2.fromScale(0.406, 0.072),
		BackgroundTransparency = 1,
		-- Rendered whenever there's data to show (held through the fade/slide
		-- out). The slide handles on-screen vs off-screen; this just avoids
		-- rendering the bar at all when fully idle between encounters.
		Visible = displayData ~= nil,
	}, {
		NameLabel = React.createElement("TextLabel", {
			ref = nameLabelRef,

			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.fromScale(0.5, -0.5),
			Size = UDim2.fromScale(0.905, 0.506),
			BackgroundTransparency = 1,
			Text = name,
			RichText = true,
			TextColor3 = Color3.fromRGB(255, 255, 255),
			TextScaled = true,
			TextTransparency = 1, -- starts invisible, fade-in tweens to 0
			FontFace = Font.new(
				"rbxasset://fonts/families/Montserrat.json",
				Enum.FontWeight.Bold,
				Enum.FontStyle.Normal
			),
			ZIndex = 3,
		}, {
			UIStroke = React.createElement("UIStroke", {
				ref = nameStrokeRef,

				Color = Color3.fromRGB(20, 20, 20),
				StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize,
				Thickness = 0.05,
				Transparency = 1, -- starts invisible
			}),
		}),

		SubtitleNameLabel = React.createElement("TextLabel", {
			ref = subtitleNameLabelRef,

			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.fromScale(0.5, 0.051),
			Size = UDim2.fromScale(0.905, 0.328),
			BackgroundTransparency = 1,
			Text = displayData and ZombieData[displayData.name].subtitle or "",
			RichText = true,
			TextColor3 = Color3.fromRGB(222, 222, 222),
			TextScaled = true,
			TextTransparency = 1, -- starts invisible, fade-in tweens to 0
			FontFace = Font.new(
				"rbxasset://fonts/families/Montserrat.json",
				Enum.FontWeight.Bold,
				Enum.FontStyle.Normal
			),
			ZIndex = 3,
		}, {
			UIStroke = React.createElement("UIStroke", {
				ref = subtitleNameStrokeRef,

				Color = Color3.fromRGB(20, 20, 20),
				StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize,
				Thickness = 0.05,
				Transparency = 1, -- starts invisible
			}),
		}),

		LevelLabel = React.createElement("TextLabel", {
			ref = levelLabelRef,

			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.fromScale(-0.056, 0.429),
			Size = UDim2.fromScale(0.159, 0.463),
			BackgroundTransparency = 1,
			Text = "Lv. " .. tostring(level),
			RichText = true,
			TextColor3 = Color3.fromRGB(255, 255, 255),
			TextScaled = true,
			TextTransparency = 1, -- starts invisible
			FontFace = Font.new(
				"rbxasset://fonts/families/Montserrat.json",
				Enum.FontWeight.Bold,
				Enum.FontStyle.Normal
			),
			TextXAlignment = Enum.TextXAlignment.Right,
			ZIndex = 3,
			Visible = false,
		}, {
			UIStroke = React.createElement("UIStroke", {
				ref = levelStrokeRef,

				Color = Color3.fromRGB(20, 20, 20),
				StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize,
				Thickness = 0.04,
				Transparency = 1, -- starts invisible
			}),
		}),

		ShadowBackgroundImageLabel = React.createElement("ImageLabel", {
			ref = shadowImageRef,

			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.374),
			Size = UDim2.fromScale(1.506, 2.205),
			BackgroundTransparency = 1,
			Image = "rbxassetid://90190541001824",
			ScaleType = Enum.ScaleType.Stretch,
			ImageTransparency = 1,
			ZIndex = 1,
		}),

		-- Health counter "currentHP / maxHP" centered over the HP bar. Reads
		-- from displayData so the value persists during fade-out. Properties
		-- mirror the authored TextLabel from Studio (Position {0.499, 0.429},
		-- Size {0.256, 0.463}, Montserrat Bold, TextScaled, RichText).
		HealthCounter = React.createElement("TextLabel", {
			ref = healthCounterRef,

			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.fromScale(0.5, 0.466),
			Size = UDim2.fromScale(0.256, 0.4),
			BackgroundTransparency = 1,
			Text = string.format(
				"%d / %d",
				math.floor((displayData and displayData.currentHP) or 0),
				math.floor((displayData and displayData.maxHP) or 0)
			),
			RichText = true,
			TextColor3 = Color3.fromRGB(255, 255, 255),
			TextScaled = true,
			TextWrapped = true,
			TextTransparency = 1, -- starts invisible, fade-in tweens to 0
			TextXAlignment = Enum.TextXAlignment.Center,
			TextYAlignment = Enum.TextYAlignment.Center,
			FontFace = Font.new(
				"rbxasset://fonts/families/Montserrat.json",
				Enum.FontWeight.Bold,
				Enum.FontStyle.Normal
			),
			ZIndex = 3,
		}, {
			UIStroke = React.createElement("UIStroke", {
				ref = healthCounterStrokeRef,

				Color = Color3.fromRGB(20, 20, 20),
				StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize,
				Thickness = 0.05,
				Transparency = 1, -- starts invisible
			}),
		}),

		HPBarBackground = React.createElement("Frame", {
			ref = hpBgRef,

			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.fromScale(0.5, 0.785),
			Size = UDim2.fromScale(1.25, 0.175),
			BackgroundColor3 = Color3.fromRGB(50, 50, 50),
			BackgroundTransparency = 1, -- starts invisible, fade-in tweens to 0
			BorderSizePixel = 0,
			ZIndex = 2,
		}, {
			UICorner = React.createElement("UICorner", {
				CornerRadius = UDim.new(0.1, 0),
			}),

			UIStroke = React.createElement("UIStroke", {
				ref = hpBgStrokeRef,

				ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
				Color = Color3.fromRGB(20, 20, 20),
				StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize,
				Thickness = 0.05,
				Transparency = 1, -- starts invisible
			}),

			ShadowGradientImageLabel = React.createElement("ImageLabel", {
				ref = shadowRef,

				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromScale(1, 1),
				BackgroundTransparency = 1,
				Image = "rbxassetid://6096768861",
				ScaleType = Enum.ScaleType.Stretch,
				ImageTransparency = 1, -- starts invisible, fade-in tweens to 0.65
				ZIndex = 10,
			}, {
				UICorner = React.createElement("UICorner", {
					CornerRadius = UDim.new(0.1, 0),
				}),
			}),

			-- White damage-trail bar. Drawn BEHIND HPFill (lower ZIndex) with
			-- identical AnchorPoint/Position/Size so it visually replaces the
			-- red bar at rest. After the intro it lags one slower tween behind
			-- HPFill, exposing a white "damage taken" sliver between the two
			-- bars for the duration of HP_TRAIL_TWEEN_DURATION.
			HPTrailFill = React.createElement("Frame", {
				ref = hpTrailRef,

				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.fromScale(0, 0.5),
				Size = UDim2.fromScale(1, 1),
				BackgroundColor3 = Color3.fromRGB(112, 33, 33),
				BackgroundTransparency = 1, -- starts invisible
				BorderSizePixel = 0,
				ZIndex = 2, -- below HPFill (3), above HPBarBackground (2 via parent)
			}, {
				UICorner = React.createElement("UICorner", {
					CornerRadius = UDim.new(0.1, 0),
				}),
			}),

			HPFill = React.createElement("Frame", {
				ref = hpFillRef,

				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.fromScale(0, 0.5),
				-- Size.X is snapped to 0 at intro time and animated up; this
				-- default of 1 only matters for hot-reload / re-mount cases.
				Size = UDim2.fromScale(1, 1),
				BackgroundColor3 = Color3.fromRGB(193, 54, 54),
				BackgroundTransparency = 1, -- starts invisible
				BorderSizePixel = 0,
				ZIndex = 3,
			}, {
				UICorner = React.createElement("UICorner", {
					CornerRadius = UDim.new(0.1, 0),
				}),
			}),
		}),
	})
end

return Container
