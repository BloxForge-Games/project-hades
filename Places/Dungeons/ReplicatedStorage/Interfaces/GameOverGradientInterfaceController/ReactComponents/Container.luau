--[[
     Module: Container.lua
     Description:
     Game Over screen layout + animation. Near-identical to the death
     screen's Container but with three intentional differences:

       1. YouDiedTextLabel → GameOverTextLabel ("Game Over")
       2. DeathReasonTextLabel → SubtitleTextLabel (fixed string
          "Teleporting all players back to the Lobby...")
       3. Timing sourced from DeathCinematicData.GameOverDuration /
          GameOverStartupDelay / GameOverTextStaggerDelay — independent
          knobs from the death screen so each can tune separately.
       4. The bar counts down the REVIVE DECISION WINDOW. props.reviveWindow
          ({ endsAt, startedAt } in server time, or nil) comes from the
          replicated DeathState via LifeController; the fill starts at the
          fraction still remaining and tweens to zero over exactly the
          seconds left on the SERVER clock. Without a window (the wipe
          screen for a player who was already fully dead) the bar falls
          back to the fixed GameOverDuration countdown.
       5. A REVIVE button, shown with the bar while the window is open,
          that prompts the paid dev product (PlayerNetwork.PromptRevivePurchase;
          the server refuses it once the window is closed).

     Everything else (gradient pulse, text fly-in, progress bar
     countdown, token race protection) is byte-for-byte the same
     pattern as the death Container. They started as a copy on
     purpose — if they diverge meaningfully later, extract a shared
     visual sub-component then.

     TEXT RENDERS THROUGH HYPERTEXT (Libraries/HyperText), not TextLabels:
     both lines WIGGLE (a slow sine wave rippling along each line), each
     with its own shape. Each line lives in a CanvasGroup so the
     original fly-in envelope is untouched — GroupTransparency + Position
     tween exactly as TextTransparency + Position did, fading text and
     stroke together. Glyphs print instantly (no interval, no entrance
     animation); the wiggle is the only motion.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local React = require(ReplicatedStorage.Submodules.Core.Packages.React)
local PlayerNetwork = require(ReplicatedStorage.Submodules.Core.Source.Network.Player)
local DeathCinematicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.DeathCinematicData)
local HyperText = require(ReplicatedStorage.Submodules.Core.Libraries.HyperText)

local PULSE_HIDDEN_TRANSPARENCY = 1

-- Text rise animation. Identical envelope to the death screen's so the
-- two cinematics read as the same visual language. Only the durations
-- (sourced from DeathCinematicData below) differ between the screens.
local TEXT_TWEEN_INFO = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TEXT_FADE_OUT_TWEEN_INFO = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TEXT_RISE_OFFSET = 0.03 -- Y scale offset; +Y = lower start, tween toward 0

local SUBTITLE_STAGGER_DELAY = DeathCinematicData.GameOverTextStaggerDelay

local GAME_OVER_TARGET_POSITION = UDim2.fromScale(0.5, 0.485)
local SUBTITLE_TARGET_POSITION = UDim2.fromScale(0.5, 0.57)

local GAME_OVER_START_POSITION = UDim2.fromScale(0.5, 0.485 + TEXT_RISE_OFFSET)
local SUBTITLE_START_POSITION = UDim2.fromScale(0.5, 0.57 + TEXT_RISE_OFFSET)

local PROGRESS_BAR_TARGET_POSITION = UDim2.fromScale(0.5, 0.535)
local PROGRESS_BAR_START_POSITION = UDim2.fromScale(0.5, 0.535 + TEXT_RISE_OFFSET)
local PROGRESS_BAR_SIZE = UDim2.fromScale(0.25, 0.012)

local PROGRESS_BAR_BG_COLOR = Color3.fromRGB(0, 0, 0)

local PROGRESS_BAR_BG_VISIBLE_TRANSPARENCY = 0.35
local PROGRESS_BAR_FILL_VISIBLE_TRANSPARENCY = 0

local GAME_OVER_PULSE_DURATION = DeathCinematicData.GameOverDuration
local BAR_STARTUP_DELAY = DeathCinematicData.GameOverStartupDelay
-- Fallback only: the wipe screen for a client with no open revive window.
-- A downed player's bar is driven by the server window instead.
local BAR_COUNTDOWN_DURATION = GAME_OVER_PULSE_DURATION - BAR_STARTUP_DELAY

-- REVIVE button, under the subtitle. Same footprint the spectate UI's
-- button had, so it reads as the same control moved to where the
-- decision is actually made.
local REVIVE_BUTTON_POSITION = UDim2.fromScale(0.5, 0.65)
-- Where the button's CanvasGroup rests while hidden: a little BELOW its
-- seat, so it rises into place on the fade-in and sinks away on the
-- fade-out, the same motion the title and subtitle make.
local REVIVE_BUTTON_START_POSITION = UDim2.fromScale(0.5, 0.65 + TEXT_RISE_OFFSET)
local REVIVE_BUTTON_SIZE = UDim2.fromScale(0.105, 0.047)
local REVIVE_BUTTON_FONT = Font.new("rbxasset://fonts/families/Montserrat.json", Enum.FontWeight.Bold)

-- Fixed subtitle per spec. No randomization (the death screen picks
-- from DEATH_REASON_TEXTS); Game Over has a single deterministic line
-- because it represents a specific server event (lobby teleport).
local TITLE_PLAIN = "Eternal Damnation"
local SUBTITLE_PLAIN = "The Spire claims the eternally damned, but never the determined."

-- Typography, carried over from the TextLabels these replaced. Stroke
-- thickness is in the same ScaledSize units HyperText uses per glyph.
local TEXT_FONT = "rbxasset://fonts/families/Montserrat.json"
local TITLE_COLOR = Color3.fromRGB(255, 72, 72)
local TITLE_STROKE_THICKNESS = 0.035
local TITLE_STROKE_TRANSPARENCY = 0.5
local SUBTITLE_COLOR = Color3.fromRGB(220, 220, 220)
local SUBTITLE_STROKE_THICKNESS = 0.025
local SUBTITLE_STROKE_TRANSPARENCY = 0

-- The effect (a decode on the title was tried and removed in favour of
-- this). It loops, since the screen holds.
--   WIGGLE, both lines: HyperText's <anim=wiggle> — a sine wave along
--   the line. amp is a fraction of glyph height, freq in Hz, offset the
--   phase step between neighbouring characters (smaller = longer, calmer
--   waves across the sentence), rot tilts glyphs along the wave. Library
--   defaults (0.3 / 0.75 / 0.12 / true) are tuned for big dialogue text
--   and read as a jelly on a subtitle, hence these. (A sinister shake on
--   one word was layered on top and removed — two motions on one word
--   read as noise.)
-- The title is 17 big glyphs; the subtitle is 65 small ones. Same wave
-- shape on both reads wrong — at the subtitle's phase step the title
-- would rise and fall almost in unison — so the title gets a larger
-- step (a visible ripple across it) and a smaller amplitude (its glyphs
-- are big, and it is the thing the eye lands on).
local TITLE_WIGGLE_AMP = 0
local TITLE_WIGGLE_FREQ = 0
local TITLE_WIGGLE_OFFSET = 0
local TITLE_WIGGLE_ROT = false
local SUBTITLE_WIGGLE_AMP = 0.075
local SUBTITLE_WIGGLE_FREQ = 0.65
local SUBTITLE_WIGGLE_OFFSET = 0.05
local SUBTITLE_WIGGLE_ROT = false

-- `text` wrapped in HyperText's looping wiggle, with the given shape.
local function wiggle(text: string, amp: number, freq: number, offset: number, rot: boolean): string
	return ("<anim=wiggle loop=true amp=%s freq=%s offset=%s rot=%s>%s</anim>"):format(
		tostring(amp),
		tostring(freq),
		tostring(offset),
		tostring(rot),
		text
	)
end

local TITLE_MARKUP = wiggle(TITLE_PLAIN, TITLE_WIGGLE_AMP, TITLE_WIGGLE_FREQ, TITLE_WIGGLE_OFFSET, TITLE_WIGGLE_ROT)
local SUBTITLE_MARKUP =
	wiggle(SUBTITLE_PLAIN, SUBTITLE_WIGGLE_AMP, SUBTITLE_WIGGLE_FREQ, SUBTITLE_WIGGLE_OFFSET, SUBTITLE_WIGGLE_ROT)

-- HyperText has no TextScaled. The glyph size is derived from the LIVE
-- container: filled to its height, capped by its width so a narrow
-- screen cannot wrap the title onto two lines. HyperText's own
-- proportional rescale (scaleDimension "Y") tracks resizes from there.
local TEXT_HEIGHT_FILL = 0.85
local TEXT_WIDTH_PER_CHAR = 0.62
-- A CanvasGroup renders to a texture the size of its bounds and CLIPS
-- anything outside them. The wiggle lifts glyphs above the line, so each
-- group is made this much taller than the line it holds, while the glyph
-- size is still derived from the LINE height — nothing changes on screen
-- except that the wave's crests survive instead of being flattened.
local LINE_GROUP_HEADROOM = 1.6

-- One line's style as HyperText markups. Built against a live container
-- (for the size), so only once the screen is actually showing.
local function buildLineMarkups(
	container: GuiObject,
	weight: Enum.FontWeight,
	color: Color3,
	strokeThickness: number,
	strokeTransparency: number,
	charCount: number
)
	local markups = HyperText.newMarkups()
	markups.font.value = TEXT_FONT
	markups.weight.value = weight
	markups.color.value = color
	local byHeight = (container.AbsoluteSize.Y / LINE_GROUP_HEADROOM) * TEXT_HEIGHT_FILL
	local byWidth = container.AbsoluteSize.X / (charCount * TEXT_WIDTH_PER_CHAR)
	markups.size.value = math.max(1, math.floor(math.min(byHeight, byWidth)))
	markups.interval.value = 0
	markups.scaleDimension.value = "Y"
	markups.horizontalAlignment.value = Enum.HorizontalAlignment.Center
	markups.verticalAlignment.value = Enum.VerticalAlignment.Center
	markups.stroke.value = true
	markups.stroke.attributes.thickness = strokeThickness
	markups.stroke.attributes.color = Color3.new(0, 0, 0)
	markups.stroke.attributes.trans = strokeTransparency
	-- Instant, fully opaque glyphs: the CanvasGroup owns the fade, and the
	-- wiggle is the only motion.
	markups.anim.value = HyperText.DELETE
	markups.soundId.value = HyperText.DELETE
	markups.trans.value = 0
	return markups
end

local function Container(props: any)
	local gradientImageLabelRef1 = React.useRef(nil)

	-- Text refs. Named for the Game Over content but the tween + token
	-- pattern is identical to the death screen — easy to grep across
	-- both files when debugging timing.
	local gameOverRef = React.useRef(nil)
	local subtitleRef = React.useRef(nil)

	-- The HyperText objects behind each CanvasGroup. Built lazily at the
	-- first pulse-in: HyperText captures the container's AbsoluteSize at
	-- construction as its rescale basis and refuses a zero-size one, and a
	-- screen that has never shown can still measure zero.
	local titleHtRef = React.useRef(nil)
	local subtitleHtRef = React.useRef(nil)

	local function ensureTitle()
		local container = gameOverRef.current
		if container and not titleHtRef.current and container.AbsoluteSize.Y > 0 then
			titleHtRef.current = HyperText.new(
				container,
				buildLineMarkups(
					container,
					Enum.FontWeight.Bold,
					TITLE_COLOR,
					TITLE_STROKE_THICKNESS,
					TITLE_STROKE_TRANSPARENCY,
					#TITLE_PLAIN
				)
			)
		end
		return titleHtRef.current
	end

	local function ensureSubtitle()
		local container = subtitleRef.current
		if container and not subtitleHtRef.current and container.AbsoluteSize.Y > 0 then
			subtitleHtRef.current = HyperText.new(
				container,
				buildLineMarkups(
					container,
					Enum.FontWeight.SemiBold,
					SUBTITLE_COLOR,
					SUBTITLE_STROKE_THICKNESS,
					SUBTITLE_STROKE_TRANSPARENCY,
					#SUBTITLE_PLAIN
				)
			)
		end
		return subtitleHtRef.current
	end

	-- Token refs. Same dual-token pattern as the death Container:
	-- outerFlyInToken guards (0, startup-delay), subtitleToken guards
	-- (startup-delay, startup-delay + stagger). Either token getting
	-- nilled in the pulse-out branch invalidates the corresponding
	-- pending task.delay.
	local outerFlyInTokenRef = React.useRef(nil)
	local subtitleTokenRef = React.useRef(nil)

	-- Progress bar refs + tween handle. Identical pattern to the death
	-- Container — barCountdownTweenRef gets :Cancel()ed on every
	-- pulse-in before snapping Size back to (1, 1) so re-fires of the
	-- Game Over screen start fresh.
	local progressBarBgRef = React.useRef(nil)
	local progressBarFillRef = React.useRef(nil)
	local barCountdownTweenRef = React.useRef(nil)
	-- The REVIVE button's CanvasGroup (tweened as one: GroupTransparency +
	-- Position) and the token that cancels a fly-in still waiting on the
	-- subtitle when the button is told to hide first.
	local reviveGroupRef = React.useRef(nil)
	local reviveShowTokenRef = React.useRef(nil)

	local imageColor3 = props.ImageColor3

	-- The revive window, mirrored into a ref so the pulse effect (whose
	-- closure is built once per pulse edge) reads the latest one.
	local reviveWindow = props.reviveWindow
	local reviveWindowRef = React.useRef(nil)
	reviveWindowRef.current = reviveWindow

	-- True from the bar's fly-in until pulse-out: the button shows with
	-- the bar, never before the title lands.
	local barShown, setBarShown = React.useState(false)
	-- True once the window's remaining time has run out on this client,
	-- as a belt-and-braces hide: the server flips the phase to "dead" on
	-- the same beat, which nils the window through props anyway.
	local windowExpired, setWindowExpired = React.useState(false)
	local expiryTokenRef = React.useRef(nil)

	-- (Re)starts the fill countdown. With a window: the fill snaps to the
	-- fraction of the window still remaining on the SERVER clock and tweens
	-- to zero over exactly the seconds left, so every client -- including
	-- one that pulsed in late -- reads the same remainder. Without one:
	-- the fixed fallback countdown.
	local function startCountdown()
		local fill = progressBarFillRef.current
		if not fill then
			return
		end
		if barCountdownTweenRef.current then
			barCountdownTweenRef.current:Cancel()
			barCountdownTweenRef.current = nil
		end

		local window = reviveWindowRef.current
		local remaining = BAR_COUNTDOWN_DURATION
		local fraction = 1
		-- Seconds until the drain may begin: the window's opening is the
		-- bar's fly-in beat, and a bar that is on screen a hair early (clock
		-- skew) holds full until then rather than starting down.
		local holdFor = 0
		if window then
			local now = workspace:GetServerTimeNow()
			local total = math.max(window.endsAt - window.startedAt, 0.01)
			holdFor = math.max(window.startedAt - now, 0)
			remaining = math.max(window.endsAt - math.max(now, window.startedAt), 0)
			fraction = math.clamp(remaining / total, 0, 1)
		end

		fill.Size = UDim2.fromScale(fraction, 1)
		if remaining <= 0 then
			return
		end

		local countdownTween = TweenService:Create(
			fill,
			TweenInfo.new(remaining, Enum.EasingStyle.Linear, Enum.EasingDirection.Out, 0, false, holdFor),
			{ Size = UDim2.fromScale(0, 1) }
		)
		barCountdownTweenRef.current = countdownTween
		countdownTween:Play()
	end

	-- Window edge: arm the local expiry and, if the bar is already on
	-- screen, re-sync it to the new window (a window that arrives after
	-- the pulse, or is replaced by a later death).
	React.useEffect(function()
		local token = {}
		expiryTokenRef.current = token

		if not reviveWindow then
			setWindowExpired(false)
			return
		end

		local remaining = reviveWindow.endsAt - workspace:GetServerTimeNow()
		if remaining <= 0 then
			setWindowExpired(true)
		else
			setWindowExpired(false)
			task.delay(remaining, function()
				if expiryTokenRef.current ~= token then
					return
				end
				setWindowExpired(true)
			end)
		end

		if barShown then
			startCountdown()
		end
		return nil
	end, { reviveWindow })

	React.useEffect(function()
		if props.pulseGradient then
			-- Pulse-in. Same orchestration as the death screen, just
			-- with Game Over text + the GameOver-specific timings:
			--   t=0:                       outer token stamped, startup delay starts
			--   t=startup:                 GameOver text + bar fade in, countdown begins
			--   t=startup+stagger:         Subtitle fades in
			--   t=startup+countdown:       Bar reaches 0, pulse auto-resets
			local outerToken = {}
			outerFlyInTokenRef.current = outerToken

			task.delay(BAR_STARTUP_DELAY, function()
				if outerFlyInTokenRef.current ~= outerToken then
					return -- pulse-out happened during the startup pause
				end

				if gameOverRef.current then
					-- Re-fires re-render: a Render clears the previous print.
					local titleHt = ensureTitle()
					if titleHt then
						-- Render(text, yield?, wrapped?): wrapped=false so a narrow
						-- screen can never break the title onto two lines — the
						-- width cap in buildLineMarkups keeps it inside the
						-- container instead. The subtitle keeps default wrapping.
						titleHt:Render(TITLE_MARKUP, nil, false)
					end
					TweenService:Create(gameOverRef.current, TEXT_TWEEN_INFO, {
						GroupTransparency = 0,
						Position = GAME_OVER_TARGET_POSITION,
					}):Play()
				end

				if progressBarBgRef.current then
					TweenService:Create(progressBarBgRef.current, TEXT_TWEEN_INFO, {
						BackgroundTransparency = PROGRESS_BAR_BG_VISIBLE_TRANSPARENCY,
						Position = PROGRESS_BAR_TARGET_POSITION,
					}):Play()
				end
				if progressBarFillRef.current then
					TweenService:Create(progressBarFillRef.current, TEXT_TWEEN_INFO, {
						BackgroundTransparency = PROGRESS_BAR_FILL_VISIBLE_TRANSPARENCY,
					}):Play()
				end
				startCountdown()
				setBarShown(true)

				-- Subtitle stagger. Token-guarded so a pulse-out that
				-- lands during (startup, startup + stagger) can cancel
				-- the deferred subtitle fly-in.
				local token = {}
				subtitleTokenRef.current = token

				task.delay(SUBTITLE_STAGGER_DELAY, function()
					if subtitleTokenRef.current ~= token then
						return
					end

					if subtitleRef.current then
						local subtitleHt = ensureSubtitle()
						if subtitleHt then
							subtitleHt:Render(SUBTITLE_MARKUP)
						end
						TweenService:Create(subtitleRef.current, TEXT_TWEEN_INFO, {
							GroupTransparency = 0,
							Position = SUBTITLE_TARGET_POSITION,
						}):Play()
					end
				end)
			end)
		else
			-- Pulse-out. In practice the Game Over screen pulse-out
			-- coincides with TeleportAsync (the place is about to
			-- unload), so this branch mostly runs for late-cancel
			-- safety: a teleport-fail recovery or admin command that
			-- clears the Game Over state would land here.
			outerFlyInTokenRef.current = nil
			subtitleTokenRef.current = nil
			setBarShown(false)

			-- Kill the countdown tween too. It is not visible once the bar fades,
			-- but leaving it running means it keeps writing Size behind a
			-- transparent frame and can still be mid-flight when the next death
			-- pulses in.
			if barCountdownTweenRef.current then
				barCountdownTweenRef.current:Cancel()
				barCountdownTweenRef.current = nil
			end

			-- Fade the group out, THEN clear its glyphs — clearing first would
			-- pop the text. Guarded so a pulse-in that re-fires mid-fade (and
			-- re-renders) is not wiped by the earlier fade finishing.
			local function fadeOutLine(container: GuiObject?, htRef, startPosition: UDim2)
				if not container then
					return
				end
				local tween = TweenService:Create(container, TEXT_FADE_OUT_TWEEN_INFO, {
					GroupTransparency = 1,
					Position = startPosition,
				})
				tween.Completed:Once(function()
					if outerFlyInTokenRef.current == nil and htRef.current then
						htRef.current:Clear(true)
					end
				end)
				tween:Play()
			end
			fadeOutLine(gameOverRef.current, titleHtRef, GAME_OVER_START_POSITION)
			fadeOutLine(subtitleRef.current, subtitleHtRef, SUBTITLE_START_POSITION)

			-- Bar fade-out. Same intentional "leave Size mid-countdown"
			-- choice as the death screen — snapping to 0 or 1 here would
			-- visually pop the bar during the fade.
			if progressBarBgRef.current then
				TweenService:Create(progressBarBgRef.current, TEXT_FADE_OUT_TWEEN_INFO, {
					BackgroundTransparency = 1,
					Position = PROGRESS_BAR_START_POSITION,
				}):Play()
			end
			if progressBarFillRef.current then
				TweenService:Create(progressBarFillRef.current, TEXT_FADE_OUT_TWEEN_INFO, {
					BackgroundTransparency = 1,
				}):Play()
			end
		end
	end, { props.pulseGradient })

	-- REVIVE button visibility, as a tween rather than a Visible flip. It
	-- rises in after the subtitle has finished its own fly-in (stagger +
	-- the tween's length, measured from the bar appearing, which is what
	-- flips barShown) and sinks out the moment the window closes, the
	-- player revives, or the screen pulses out.
	local reviveShown = barShown and reviveWindow ~= nil and not windowExpired
	React.useEffect(function()
		local group = reviveGroupRef.current
		if not group then
			return
		end
		if reviveShown then
			local token = {}
			reviveShowTokenRef.current = token
			task.delay(SUBTITLE_STAGGER_DELAY + TEXT_TWEEN_INFO.Time, function()
				if reviveShowTokenRef.current ~= token or not group.Parent then
					return
				end
				TweenService:Create(group, TEXT_TWEEN_INFO, {
					GroupTransparency = 0,
					Position = REVIVE_BUTTON_POSITION,
				}):Play()
			end)
		else
			reviveShowTokenRef.current = nil
			TweenService:Create(group, TEXT_FADE_OUT_TWEEN_INFO, {
				GroupTransparency = 1,
				Position = REVIVE_BUTTON_START_POSITION,
			}):Play()
		end
	end, { reviveShown })

	return React.createElement("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Visible = props.Visible,
	}, {

		-- Gradient image kept as a hidden placeholder so the JSX
		-- structure mirrors the death screen (the death overlay's
		-- gradient is actually painted by ScreenGradientInterface's
		-- SetHold path now — this ImageLabel exists for layout parity
		-- and is invisible by default).
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

		-- "Eternal Damnation" headline. A CanvasGroup that HyperText prints
		-- into (see the header); GroupTransparency carries the fly-in so the
		-- envelope matches the death screen's exactly.
		GameOverTitle = React.createElement("CanvasGroup", {
			ref = gameOverRef,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = GAME_OVER_START_POSITION,
			Size = UDim2.fromScale(0.5, 0.065 * LINE_GROUP_HEADROOM),
			BackgroundTransparency = 1,
			GroupTransparency = 1,
			BorderSizePixel = 0,
			ZIndex = 2,
		}),

		-- Countdown bar — visually identical to the death screen's bar.
		-- Inner Fill scales Size.X 1 → 0 over BAR_COUNTDOWN_DURATION
		-- so it empties the moment LifeService's TeleportAsync fires.
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

		-- Fixed subtitle. Same typography as the death screen's reason text
		-- (SemiBold Montserrat in dim gray), printed by HyperText with a slow
		-- wiggle along the whole line.
		Subtitle = React.createElement("CanvasGroup", {
			ref = subtitleRef,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = SUBTITLE_START_POSITION,
			Size = UDim2.fromScale(0.75, 0.0265 * LINE_GROUP_HEADROOM),
			BackgroundTransparency = 1,
			GroupTransparency = 1,
			BorderSizePixel = 0,
			ZIndex = 2,
		}),

		--[ REVIVE button (paid) ]--
		-- Only while the bar is up AND the local player's revive window is
		-- open. Fires PlayerNetwork.PromptRevivePurchase; the server checks
		-- the player is still DOWNED and prompts the dev product. On
		-- purchase, ProcessReceipt -> :Revive stands the player up in place
		-- and LifeController tears this screen down. Once the window has
		-- closed the player is fully dead: no button, and the server would
		-- refuse the prompt anyway.
		-- Wrapped in a CanvasGroup so the whole control (fill, strokes,
		-- text) fades as one; the group is what the effect above tweens.
		-- The button stays mounted and only becomes clickable while shown,
		-- so a click cannot land on an invisible button mid-fade.
		ReviveGroup = React.createElement("CanvasGroup", {
			ref = reviveGroupRef,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = REVIVE_BUTTON_START_POSITION,
			Size = REVIVE_BUTTON_SIZE,
			BackgroundTransparency = 1,
			GroupTransparency = 1,
			BorderSizePixel = 0,
			ZIndex = 3,
		}, {
			ReviveButton = React.createElement("TextButton", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromScale(1, 1),
				BackgroundColor3 = Color3.fromRGB(85, 255, 127),
				Text = "REVIVE",
				TextColor3 = Color3.fromRGB(255, 255, 255),
				TextScaled = true,
				FontFace = REVIVE_BUTTON_FONT,
				BorderSizePixel = 0,
				AutoButtonColor = true,
				Interactable = reviveShown,
				[React.Event.Activated] = function()
					PlayerNetwork.PromptRevivePurchase.Fire()
				end,
			}, {
				UICorner = React.createElement("UICorner", { CornerRadius = UDim.new(0.2, 0) }),
				UIStroke = React.createElement("UIStroke", {
					Color = Color3.fromRGB(31, 94, 46),
					Thickness = 0.06,
					ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
					StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize,
				}),
				BorderStroke = React.createElement("UIStroke", {
					Color = Color3.fromRGB(31, 94, 46),
					Thickness = 0.075,
					ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
					StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize,
				}),
				UIPadding = React.createElement("UIPadding", {
					PaddingLeft = UDim.new(0, 0),
					PaddingRight = UDim.new(0, 0),
					PaddingTop = UDim.new(0.15, 0),
					PaddingBottom = UDim.new(0.15, 0),
				}),
			}),
		}),
	})
end

return Container
