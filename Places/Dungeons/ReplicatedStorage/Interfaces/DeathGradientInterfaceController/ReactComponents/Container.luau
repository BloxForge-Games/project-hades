--[[
     Module: Container.lua
     Description:
     Death gradient overlay. Three stacked GradientImageLabels driven by the
     same pulseGradient prop + ImageColor3 — each gets its own ref so they
     can be tweaked independently (rotation, scale, image asset) without
     refactoring the tween logic. All three tween together to the same
     transparency so the pulse-in / pulse-out beat stays synchronized.

     YouDied / DeathReason text:
       Both labels share the same staggered fly-in: TextTransparency 1 → 0
       AND position-Y down → up. "You Died" starts on the same tick as the
       gradient pulse-in; "Death Reason" follows DEATH_REASON_DELAY seconds
       later for the dramatic beat.

       The labels' final (target) positions are authored in the JSX prop —
       initial positions are computed as target.Y + TEXT_RISE_OFFSET so the
       label starts lower than where it lands. AnchorPoint is (0.5, 0.5)
       so "Y bigger = lower on screen" and tweening Y back down to the
       authored value reads as a smooth rise.

       On pulse-out (gradient hiding) both labels fade together back to
       their lower start position so the NEXT pulse re-animates from a
       clean state. A pending DEATH_REASON delay is cancelled via the
       _deathReasonToken ref to prevent a stale flyer firing after the
       user revives.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local React = require(ReplicatedStorage.Submodules.Core.Packages.React)
local DeathCinematicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.DeathCinematicData)

local PULSE_HIDDEN_TRANSPARENCY = 1

-- Text rise animation. The labels start TEXT_RISE_OFFSET (in scale units)
-- BELOW their authored position and tween up to it as they fade in.
-- TEXT_TWEEN_INFO drives both the transparency AND position interp.
local TEXT_TWEEN_INFO = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TEXT_FADE_OUT_TWEEN_INFO = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TEXT_RISE_OFFSET = 0.03 -- Y scale offset; +Y = lower start, tween toward 0

-- Staggered beat between YouDied and DeathReason fly-ins. Sourced from
-- DeathCinematicData so the cinematic-wide timeline edits stay in lockstep.
local DEATH_REASON_DELAY = DeathCinematicData.TextStaggerDelay

local YOU_DIED_TARGET_POSITION = UDim2.fromScale(0.5, 0.482)
local DEATH_REASON_TARGET_POSITION = UDim2.fromScale(0.5, 0.576)

local YOU_DIED_START_POSITION = UDim2.fromScale(0.5, 0.482 + TEXT_RISE_OFFSET)
local DEATH_REASON_START_POSITION = UDim2.fromScale(0.5, 0.576 + TEXT_RISE_OFFSET)

local PROGRESS_BAR_TARGET_POSITION = UDim2.fromScale(0.5, 0.535)
local PROGRESS_BAR_START_POSITION = UDim2.fromScale(0.5, 0.535 + TEXT_RISE_OFFSET)
local PROGRESS_BAR_SIZE = UDim2.fromScale(0.25, 0.012)

-- Bar color per the user spec. White fill on a dark bg with a near-black
-- stroke matches the EncounterLobby pattern but reads cleanly on the
-- red-to-black death overlay.
local PROGRESS_BAR_BG_COLOR = Color3.fromRGB(0, 0, 0)

-- Steady-state visible transparencies. Match EncounterLobby's PROGRESS_BG_VISIBLE
-- / PROGRESS_FILL_VISIBLE values so the visual language reads the same.
local PROGRESS_BAR_BG_VISIBLE_TRANSPARENCY = 0.35
local PROGRESS_BAR_FILL_VISIBLE_TRANSPARENCY = 0

-- Death-pulse hold duration + fly-in startup pause. Both sourced from
-- DeathCinematicData (Shared/Data/DeathCinematicData.lua) — single source
-- of truth for the death cinematic timeline. LifeController, the parent
-- DeathGradientInterfaceController/init.luau pulse handler, and this
-- Container all read from there, so changing the timing in the data
-- module re-tunes everything atomically.
local DEATH_PULSE_DURATION = DeathCinematicData.VfxDuration
local BAR_STARTUP_DELAY = DeathCinematicData.FlyInStartupDelay
local BAR_COUNTDOWN_DURATION = DEATH_PULSE_DURATION - BAR_STARTUP_DELAY

-- Linear easing on the countdown — a Quad easing would visually accelerate
-- toward empty and disconnect from the player's mental "X seconds left"
-- read. EasingDirection.Out doesn't matter for Linear; kept for clarity.
local BAR_COUNTDOWN_TWEEN_INFO =
	TweenInfo.new(BAR_COUNTDOWN_DURATION, Enum.EasingStyle.Linear, Enum.EasingDirection.Out)

local DEATH_REASON_TEXTS = {
	"Maybe try wearing a helmet next time?",
	"Next time, maybe try not dying?",
	"Death is just a suggestion. Maybe try ignoring it next time?",
	"Have you considered... not doing that?",
	"Remember, practice makes perfect.",
	"Don't worry, it's not like you had anything to lose... oh wait.",
	"Well, that didn't go as planned...",
}

local function Container(props: any)
	local gradientImageLabelRef1 = React.useRef(nil)

	-- Refs for the staggered text fly-in. Each label tweens TextTransparency
	-- (1→0 on pulse-in) and Position (start-below → authored target).
	local youDiedRef = React.useRef(nil)
	local deathReasonRef = React.useRef(nil)

	-- Token ref guards the DEATH_REASON_DELAY task.delay against firing
	-- after the pulse has been cancelled (revive arrives within the 0.5s
	-- stagger window). Stamping a new token in the pulse-out branch makes
	-- any in-flight delay no-op when it eventually fires.
	local deathReasonTokenRef = React.useRef(nil)

	-- Outer-startup token ref. Guards the 1s task.delay that wraps the
	-- whole fly-in (the "dramatic pause" between pulse-in and YouDied
	-- appearing). Without this, a pulse-out that lands in (0, 1s)
	-- BEFORE the startup completes can't cancel the deferred fly-in —
	-- the fade-out branch runs against still-invisible text, then 1s
	-- later the fly-in runs anyway and the text gets stuck on screen
	-- with no future pulse-out edge to clear it on. The fade-out branch
	-- now also nils this token, so the pending task.delay no-ops when
	-- it eventually fires.
	local outerFlyInTokenRef = React.useRef(nil)

	-- Progress bar refs. Bg controls the position-rise + transparency
	-- fade-in; the Fill child handles the countdown shrink (Size.X 1 → 0).
	-- barCountdownTweenRef tracks the in-flight countdown Tween so the
	-- next pulse-in can Cancel it before snapping Size back to (1, 1) —
	-- without the Cancel, a direct Size write would race the still-
	-- running tween and resolve unpredictably.
	local progressBarBgRef = React.useRef(nil)
	local progressBarFillRef = React.useRef(nil)
	local barCountdownTweenRef = React.useRef(nil)

	local imageColor3 = props.ImageColor3

	React.useEffect(function()
		if props.pulseGradient then
			-- Pulse-in: "You Died" flies in immediately on the same tick
			-- as the gradient. "Death Reason" is gated behind a token-
			-- guarded task.delay so a mid-flight revive (pulse goes false
			-- within 0.5s) can cancel it cleanly.

			-- Stamp a fresh outer token BEFORE the startup delay so the
			-- pulse-out branch (or another pulse-in) can invalidate this
			-- pending fly-in even before YouDied has appeared.
			local outerToken = {}
			outerFlyInTokenRef.current = outerToken

			-- Startup pause matches DeathCinematicData.FlyInStartupDelay
			-- (aliased above as BAR_STARTUP_DELAY) so the bar countdown,
			-- YouDied fly-in, and LifeController's screen-fade timeline
			-- all advance off the same source value.
			task.delay(BAR_STARTUP_DELAY, function()
				if outerFlyInTokenRef.current ~= outerToken then
					return -- pulse-out happened during the startup pause
				end

				if youDiedRef.current then
					TweenService:Create(youDiedRef.current, TEXT_TWEEN_INFO, {
						TextTransparency = 0,
						Position = YOU_DIED_TARGET_POSITION,
					}):Play()

					TweenService:Create(youDiedRef.current.UIStroke, TEXT_TWEEN_INFO, {
						Transparency = 0.5,
					}):Play()
				end

				-- Progress bar: fade in + rise alongside YouDied, then
				-- countdown shrink from full to empty over the remaining
				-- death cinematic. Order matters:
				--   1. Cancel any leftover countdown tween from a prior
				--      cycle so its in-flight value doesn't race the
				--      Size reset on the next line.
				--   2. Snap Size.X back to 1 (full bar) on the Fill —
				--      idempotent for first-time death, required for
				--      revive→re-death cycles.
				--   3. Tween Bg transparency + Position to visible/target.
				--   4. Tween Fill transparency to visible, then start the
				--      Size countdown Tween (stored for the next cycle
				--      to cancel).
				if barCountdownTweenRef.current then
					barCountdownTweenRef.current:Cancel()
					barCountdownTweenRef.current = nil
				end

				if progressBarFillRef.current then
					progressBarFillRef.current.Size = UDim2.fromScale(1, 1)
				end
				if progressBarBgRef.current then
					TweenService:Create(progressBarBgRef.current, TEXT_TWEEN_INFO, {
						BackgroundTransparency = PROGRESS_BAR_BG_VISIBLE_TRANSPARENCY,
						Position = PROGRESS_BAR_TARGET_POSITION,
					}):Play()
					if progressBarBgRef.current:FindFirstChild("UIStroke") then
						TweenService:Create(progressBarBgRef.current.UIStroke, TEXT_TWEEN_INFO, {
							Transparency = 0.3,
						}):Play()
					end
				end
				if progressBarFillRef.current then
					TweenService:Create(progressBarFillRef.current, TEXT_TWEEN_INFO, {
						BackgroundTransparency = PROGRESS_BAR_FILL_VISIBLE_TRANSPARENCY,
					}):Play()

					-- The countdown. Tween stored in the ref so the next
					-- pulse-in can cancel it cleanly. Linear easing keeps
					-- the "time remaining" read honest.
					local countdownTween = TweenService:Create(
						progressBarFillRef.current,
						BAR_COUNTDOWN_TWEEN_INFO,
						{ Size = UDim2.fromScale(0, 1) }
					)
					barCountdownTweenRef.current = countdownTween
					countdownTween:Play()
				end

				local token = {}
				deathReasonTokenRef.current = token

				task.delay(DEATH_REASON_DELAY, function()
					if deathReasonTokenRef.current ~= token then
						return -- pulse-out or another pulse-in superseded us
					end

					deathReasonRef.current.Text = DEATH_REASON_TEXTS[math.random(1, #DEATH_REASON_TEXTS)]
					-- Set the death reason text on fly-in so the correct reason shows even if the player revives mid-stagger

					if deathReasonRef.current then
						TweenService:Create(deathReasonRef.current, TEXT_TWEEN_INFO, {
							TextTransparency = 0,
							Position = DEATH_REASON_TARGET_POSITION,
						}):Play()

						TweenService:Create(deathReasonRef.current.UIStroke, TEXT_TWEEN_INFO, {
							Transparency = 0,
						}):Play()
					end
				end)
			end)
		else
			-- Pulse-out: cancel the pending stagger AND the pending 1s
			-- startup pause, then fade both labels back to invisible AND
			-- back to their start positions so the next pulse-in animates
			-- from a clean state. Using the same Position target (start,
			-- not target) means even a half-finished rise gets returned
			-- to baseline.
			--
			-- Nil order doesn't matter — both tokens are independent
			-- guards on independent task.delays. Nilling the outer
			-- token covers (0, 1s); nilling the inner covers
			-- (1s, 1s + DEATH_REASON_DELAY).
			outerFlyInTokenRef.current = nil
			deathReasonTokenRef.current = nil

			if youDiedRef.current then
				TweenService:Create(youDiedRef.current, TEXT_FADE_OUT_TWEEN_INFO, {
					TextTransparency = 1,
					Position = YOU_DIED_START_POSITION,
				}):Play()

				TweenService:Create(youDiedRef.current.UIStroke, TEXT_FADE_OUT_TWEEN_INFO, {
					Transparency = 1,
				}):Play()
			end
			if deathReasonRef.current then
				TweenService:Create(deathReasonRef.current, TEXT_FADE_OUT_TWEEN_INFO, {
					TextTransparency = 1,
					Position = DEATH_REASON_START_POSITION,
				}):Play()

				TweenService:Create(deathReasonRef.current.UIStroke, TEXT_FADE_OUT_TWEEN_INFO, {
					Transparency = 1,
				}):Play()
			end

			-- Progress bar fade-out. We deliberately leave the Fill's Size
			-- where the countdown left it (somewhere between 1 and 0) —
			-- snapping to 0 or 1 here would visually "pop" the bar
			-- during the fade. The next pulse-in resets Size to 1 BEFORE
			-- the fade-in, so the starting state is correct for the
			-- next cycle. Bg slides back to start position so the
			-- next fly-in animates from the same offset as the text.
			if progressBarBgRef.current then
				TweenService:Create(progressBarBgRef.current, TEXT_FADE_OUT_TWEEN_INFO, {
					BackgroundTransparency = 1,
					Position = PROGRESS_BAR_START_POSITION,
				}):Play()
				if progressBarBgRef.current:FindFirstChild("UIStroke") then
					TweenService:Create(progressBarBgRef.current.UIStroke, TEXT_FADE_OUT_TWEEN_INFO, {
						Transparency = 1,
					}):Play()
				end
			end
			if progressBarFillRef.current then
				TweenService:Create(progressBarFillRef.current, TEXT_FADE_OUT_TWEEN_INFO, {
					BackgroundTransparency = 1,
				}):Play()
			end
		end
	end, { props.pulseGradient })

	return React.createElement("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Visible = props.Visible,
	}, {

		GradientImageLabel1 = React.createElement("ImageLabel", {
			ref = gradientImageLabelRef1,

			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(1, 1),
			ImageColor3 = imageColor3,
			Image = "rbxassetid://95194409279070",
			ImageTransparency = PULSE_HIDDEN_TRANSPARENCY,
			BorderSizePixel = 0,
			ZIndex = 1,
			ScaleType = Enum.ScaleType.Stretch,
			Visible = false,
		}),

		-- Position is set to YOU_DIED_START_POSITION (target.Y + offset) so
		-- the label mounts already lower than its final spot, then tweens
		-- up to YOU_DIED_TARGET_POSITION on pulse-in. TextTransparency = 1
		-- so the fade-in starts from invisible.
		YouDiedTextLabel = React.createElement("TextLabel", {
			ref = youDiedRef,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = YOU_DIED_START_POSITION,
			Size = UDim2.fromScale(0.5, 0.076),
			BackgroundTransparency = 1,
			Text = "You Died",
			TextColor3 = Color3.fromRGB(255, 90, 90),
			TextTransparency = 1,
			TextScaled = true,
			FontFace = Font.new("rbxasset://fonts/families/Montserrat.json", Enum.FontWeight.ExtraBold),
			ZIndex = 2,
		}, {
			UIStroke = React.createElement("UIStroke", {
				Color = Color3.fromRGB(0, 0, 0),
				Thickness = 0.035,
				Transparency = 0,
				StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize,
			}),
		}),

		-- Death-cinematic countdown bar. Same fly-in beat as YouDied
		-- (faded in inside the 1s startup task.delay above), positioned
		-- beneath DeathReason. The inner ProgressFill scales Size.X
		-- 1 → 0 over BAR_COUNTDOWN_DURATION so the bar empties just as
		-- the gradient pulse auto-resets and LifeController's ScreenFade
		-- begins fading the world to black. Style mirrors the bar in
		-- EncounterLobbyInterfaceController so the visual reads as the
		-- same UI element across both timed cinematics.
		ProgressBarBg = React.createElement("Frame", {
			ref = progressBarBgRef,

			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = PROGRESS_BAR_START_POSITION,
			Size = PROGRESS_BAR_SIZE,
			BackgroundColor3 = PROGRESS_BAR_BG_COLOR,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			ZIndex = 2,
		}, {
			UICorner = React.createElement("UICorner", {
				CornerRadius = UDim.new(0.15, 0),
			}),

			-- Bg stroke. Starts transparent (1) and tweens to 0.3 with
			-- the bar fade-in. Findable as `progressBarBgRef.current.UIStroke`
			-- by the tween logic above — no separate ref needed since
			-- there's only one stroke child.
			-- UIStroke = React.createElement("UIStroke", {
			-- 	Color = PROGRESS_BAR_STROKE_COLOR,
			-- 	StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize,
			-- 	Thickness = 0.125,
			-- 	Transparency = 1,
			-- }),

			-- The actual countdown fill. Anchored to the LEFT (0, 0.5)
			-- so as Size.X scales 1 → 0 the bar empties from the right —
			-- standard timer-bar convention. Color is white per the user
			-- spec.
			ProgressFill = React.createElement("Frame", {
				ref = progressBarFillRef,

				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.fromScale(0, 0.5),
				Size = UDim2.fromScale(1, 1), -- animated by the countdown tween
				BackgroundColor3 = Color3.fromRGB(255, 90, 90),
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				ZIndex = 3,
			}, {
				UICorner = React.createElement("UICorner", {
					CornerRadius = UDim.new(0.15, 0),
				}),
			}),
		}),

		-- Same fly-in as YouDied but DEATH_REASON_DELAY seconds delayed.
		-- The 0.5s stagger is enforced in the useEffect's task.delay, not
		-- in the tween itself, so the position+transparency interp keeps
		-- the same 0.5s duration as YouDied.
		DeathReasonTextLabel = React.createElement("TextLabel", {
			ref = deathReasonRef,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = DEATH_REASON_START_POSITION,
			Size = UDim2.fromScale(0.75, 0.03),
			BackgroundTransparency = 1,
			Text = "",
			TextColor3 = Color3.fromRGB(220, 220, 220),
			TextTransparency = 1,
			TextScaled = true,
			FontFace = Font.new(
				"rbxasset://fonts/families/Montserrat.json",
				Enum.FontWeight.Bold,
				Enum.FontStyle.Italic
			),
			ZIndex = 2,
		}, {
			UIStroke = React.createElement("UIStroke", {
				Color = Color3.fromRGB(0, 0, 0),
				Thickness = 0.025,
				Transparency = 0,
				StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize,
			}),
		}),
	})
end

return Container
