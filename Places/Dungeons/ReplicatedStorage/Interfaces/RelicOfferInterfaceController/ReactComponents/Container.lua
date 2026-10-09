--[[
	Module: Container.lua
	Description:
	The relic-offer overlay: a dimmed backdrop, "Pick a Relic" with the
	auto-pick countdown under it, and the hand of OfferCards in a row.
	No buttons: the hand stays up until a card is picked or the countdown
	runs out and the server picks. The last COUNTDOWN_URGENT_SECONDS tick
	in red with a pulse and a tick sound.

	The relic tray (RelicInterfaceController) draws ABOVE this overlay, so
	a player can open it mid-offer to read their relics or drop one to free
	a slot for a pick. A capped player who does neither is skipped by the
	server when the countdown ends.

	While the hand is up the HUD scope is held closed (reference-counted
	through InterfaceManagerController, so a cutscene or death fade still
	composes). The relic tray is a Windows interface, so it stays usable.
	On mobile the combat controls hide with it (MobileActionButtonInterface:
	Roll, Swap Weapon and the tagged magic sticks); the movement and aim
	sticks stay.

	The SERVER owns the offer (RelicOfferService): this component draws
	what it was dealt, sends the click, and animates the OUTCOME the
	server reports back -- a pick is never animated on the click alone, so
	a refused pick (cap, dead) cannot leave the screen out of step. The
	press itself gets an instant dip so the click still feels immediate.

	Motion (all imperative, on the OfferCard handles):
	  * deal:    the cards start stacked at the row's centre, a little low
	             and small, and fan out to their slots one after another,
	             fading in; a light sweep crosses each as it lands (and
	             again on the card's own timer, OfferCard)
	  * hover:   the card lifts and gains its stroke; the others go under
	             their black veil
	  * idle:    a slow sine bob per card (OfferCard's own looping tween)
	  * taken:   the others sink and fade; the chosen card flashes white, a
	             ring in its tier colour ripples out, its stroke goes white,
	             it holds a beat, then rises away while fading
	  * skipped / cancelled: everything sinks and fades
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Debris = game:GetService("Debris")

local React = require(ReplicatedStorage.Submodules.Core.Packages.React)
local InterfaceManagerController =
	require(ReplicatedStorage.Submodules.Core.Source.Controllers.InterfaceManagerController)
local InterfaceScopes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.InterfaceScopes)
local Blitz = require(ReplicatedStorage.Submodules.Core.Shared.Blitz)

local OfferCard = require(script.Parent.OfferCard)

-- The HUD scope hold while the hand is up.
local HUD_HIDE_SOURCE = "RelicOffer"

--[ Tuning ]--

local FONT_BOLD = Font.new("rbxasset://fonts/families/Montserrat.json", Enum.FontWeight.Bold)

local TITLE_TEXT = "Pick a Relic"

local BACKDROP_COLOR = Color3.fromRGB(0, 0, 0)
local BACKDROP_TRANSPARENCY = 0.45
local TEXT_COLOR = Color3.fromRGB(255, 255, 255)

-- The countdown. For the last COUNTDOWN_URGENT_SECONDS each new second
-- flashes bright red and settles to a deeper red, pulses the number, and
-- plays the tick.
local COUNTDOWN_COLOR = Color3.fromRGB(208, 208, 208)
local COUNTDOWN_URGENT_SECONDS = 10
local COUNTDOWN_FLASH_COLOR = Color3.fromRGB(255, 72, 72)
local COUNTDOWN_URGENT_COLOR = Color3.fromRGB(205, 50, 50)
local COUNTDOWN_FLASH_TWEEN = TweenInfo.new(0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
local COUNTDOWN_PULSE_SCALE = 1.35
local COUNTDOWN_PULSE_TWEEN = TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local COUNTDOWN_TICK_SOUND_ID = "rbxassetid://134410911353980"
local COUNTDOWN_TICK_VOLUME = 0.6

-- Card row: height as a fraction of the screen, by platform. The width
-- follows from the card's aspect ratio (OfferCard).
-- Phones use the desktop height (their fixed card text is tuned for it);
-- touch tablets get the larger cards.
-- TOUCH, by the project's own definition (ScreenSizeController): a
-- touchscreen with no mouse. Phones AND tablets, since the two-tap below
-- is about the absence of a cursor, not about screen size.
local IS_TOUCH = UserInputService.TouchEnabled and not UserInputService.MouseEnabled

local CARD_HEIGHT_DESKTOP = 0.46
local CARD_HEIGHT_TABLET = 0.6
local CARD_GAP = 0.028
local ROW_Y = 0.541

-- The title and countdown: where they rest, and how they arrive and leave.
-- They rise HEADER_RISE (fraction of the screen) into place while fading
-- in, the countdown a beat behind the title; on close they sink back down
-- while fading out.
local TITLE_POSITION = Vector2.new(0.499, 0.19)
local TITLE_SIZE = UDim2.fromScale(0.318, 0.058)
local COUNTDOWN_POSITION = Vector2.new(0.499, 0.254)
local COUNTDOWN_SIZE = UDim2.fromScale(0.063, 0.049)
local HEADER_RISE = 0.03
local COUNTDOWN_ENTRY_DELAY = 0.08
local HEADER_IN_MOVE_TWEEN = TweenInfo.new(0.5, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local HEADER_IN_FADE_TWEEN = TweenInfo.new(0.5, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
local HEADER_OUT_MOVE_TWEEN = TweenInfo.new(0.4, Enum.EasingStyle.Quint, Enum.EasingDirection.In)
local HEADER_OUT_FADE_TWEEN = TweenInfo.new(0.35, Enum.EasingStyle.Sine, Enum.EasingDirection.In)

-- The deal: from the row's centre, this far below the slots (fraction
-- of the card height) and this small, one card every STAGGER, each
-- gliding to its slot on a Quint and sweeping as it lands.
local DEAL_FROM_SCALE = 0.85
local DEAL_DROP = 0.15
local DEAL_STAGGER = 0.14
-- A beat after the backdrop lands before the first card moves.
local DEAL_LEAD_SECONDS = 0.12
local DEAL_MOVE_TWEEN = TweenInfo.new(1.05, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local DEAL_FADE_TWEEN = TweenInfo.new(0.6, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
-- Leaving: the cards sink this far (fraction of the card height) while
-- fading. The fade beats the sink, so the drop is never watched to the
-- end.
local SINK = 0.06
local SINK_TWEEN = TweenInfo.new(0.45, Enum.EasingStyle.Quint, Enum.EasingDirection.In)
local SINK_FADE_TWEEN = TweenInfo.new(0.3, Enum.EasingStyle.Sine, Enum.EasingDirection.In)
-- The chosen card: stroke to white, a held beat, then it rises this far
-- while fading out.
local CHOSEN_HOLD_SECONDS = 0.45
local RISE = -0.06
local RISE_TWEEN = TweenInfo.new(0.65, Enum.EasingStyle.Quint, Enum.EasingDirection.In)
local RISE_FADE_TWEEN = TweenInfo.new(0.5, Enum.EasingStyle.Sine, Enum.EasingDirection.In)
-- The press: a quick dip, instantly, while the server answers.
local PRESS_SCALE = 0.975
local PRESS_TWEEN = TweenInfo.new(0.28, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)

-- Panel-wide fades: backdrop and copy.
local PANEL_FADE_TWEEN = TweenInfo.new(0.4, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
local PANEL_CLOSE_TWEEN = TweenInfo.new(0.5, Enum.EasingStyle.Sine, Enum.EasingDirection.In)

local PICK_SOUND_NAME = "RelicPickup"
-- No hover asset yet: set an id here to give the cards a hover tick.
local HOVER_SOUND_ID: string? = nil

--[ Helpers ]--

local function playUiSound(soundName: string)
	local sounds = ReplicatedStorage:FindFirstChild("GameAssets")
	sounds = sounds and sounds:FindFirstChild("Sounds")
	local template = sounds and sounds:FindFirstChild(soundName)
	if not template or not template:IsA("Sound") then
		return
	end
	local sound = template:Clone()
	sound.Parent = SoundService
	sound:Play()
	Debris:AddItem(sound, 5)
end

local function playSoundId(soundId: string?, volume: number)
	if not soundId then
		return
	end
	local sound = Instance.new("Sound")
	sound.SoundId = soundId
	sound.Volume = volume
	sound.Parent = SoundService
	sound:Play()
	Debris:AddItem(sound, 3)
end

local function tween(instance: Instance?, info: TweenInfo, goal: { [string]: any }): Tween?
	if not instance then
		return nil
	end
	local t = TweenService:Create(instance, info, goal)
	t:Play()
	return t
end

-- A text label's own fade (0 drawn, 1 invisible), stroke included.
local function applyLabelAlpha(label: TextLabel?, a: number)
	if not label then
		return
	end
	label.TextTransparency = a
	label.TextStrokeTransparency = 0.5 + 0.5 * a
end

--[ Component ]--

-- Props:
--   offeredSignal   fires (payload) when the server deals a hand
--   resolvedSignal  fires (payload) when the server reports an outcome
--   onChoose        (offerId, relicName | nil)
--   isMobile        () -> boolean  any touch device (tablet card height)
--   isPhone         () -> boolean  a phone (desktop card height, fixed card text)
--   screenSizeChanged  signal: re-reads isPhone (rotation, resize)
--   isRelicTrayOpen () -> boolean  the relic tray is open: no hover, no pick
--   relicTrayChanged  signal (open: boolean)
local function Container(props: any)
	local offer, setOffer = React.useState(nil)

	local isPhone, setIsPhone = React.useState(props.isPhone())
	local cardHeight = if isPhone
		then CARD_HEIGHT_DESKTOP
		elseif props.isMobile() then CARD_HEIGHT_TABLET
		else CARD_HEIGHT_DESKTOP

	local backdropRef = React.useRef(nil)
	local panelRef = React.useRef(nil)
	local panelAlphaRef = React.useRef(nil)
	local titleRef = React.useRef(nil)
	local countdownRef = React.useRef(nil)
	local countdownScaleRef = React.useRef(nil)
	local titleAlphaRef = React.useRef(nil)
	local countdownAlphaRef = React.useRef(nil)

	-- Per-card handles (OfferCard.onRegister), keyed by relic name.
	local handlesRef = React.useRef({})
	-- The live offer for the per-frame loop and the signal handlers,
	-- which must not close over a stale render.
	local offerRef = React.useRef(nil)
	-- "closed" | "dealing" | "open" | "resolving"
	local phaseRef = React.useRef("closed")
	local pressedRef = React.useRef(nil)
	local hoveredRef = React.useRef(nil)
	local hudHeldRef = React.useRef(false)

	-- The HUD hold, reference counted and never double-held.
	local function holdHud(hold: boolean)
		if hudHeldRef.current == hold then
			return
		end
		hudHeldRef.current = hold
		-- Resolved at call time: a core interface, mounted on every platform.
		local mobileButtons = Blitz.OptionalController("MobileActionButtonInterface")
		if hold then
			InterfaceManagerController:Hide(InterfaceScopes.HUD, HUD_HIDE_SOURCE)
			if mobileButtons then
				mobileButtons:HideCombatControls(HUD_HIDE_SOURCE)
			end
		else
			InterfaceManagerController:Show(InterfaceScopes.HUD, HUD_HIDE_SOURCE)
			if mobileButtons then
				mobileButtons:ShowCombatControls(HUD_HIDE_SOURCE)
			end
		end
	end
	-- True while the relic tray is open over the cards (no hover, no pick).
	local trayOpenRef = React.useRef(props.isRelicTrayOpen())
	-- The second the countdown last showed, so each new second fires once.
	local shownSecondRef = React.useRef(nil)
	-- A hand dealt while the previous one is still animating out waits
	-- here and is dealt by finish().
	local queuedOfferRef = React.useRef(nil)

	local function forEachHandle(callback)
		for relicName, handle in handlesRef.current do
			callback(relicName, handle)
		end
	end

	local function orderOf(relicName: string): number
		local current = offerRef.current
		return (current and table.find(current.Relics, relicName)) or 1
	end

	-- Panel alpha (0 drawn, 1 invisible): the backdrop. The title and
	-- countdown fade on their own values (headerIn / headerOut).
	local function applyPanelAlpha(a: number)
		local backdrop = backdropRef.current
		if backdrop then
			backdrop.BackgroundTransparency = BACKDROP_TRANSPARENCY + (1 - BACKDROP_TRANSPARENCY) * a
		end
	end

	local function tweenPanelAlpha(a: number, info: TweenInfo): Tween?
		return tween(panelAlphaRef.current, info, { Value = a })
	end

	-- The title and countdown arrive: each starts HEADER_RISE lower and
	-- invisible, then glides up into place while fading in, the countdown
	-- COUNTDOWN_ENTRY_DELAY behind the title.
	local function headerIn(forOffer)
		local function enter(label: TextLabel?, alphaValue: NumberValue?, rest: Vector2, delay: number)
			if not label or not alphaValue then
				return
			end
			label.Position = UDim2.fromScale(rest.X, rest.Y + HEADER_RISE)
			alphaValue.Value = 1
			task.delay(delay, function()
				if offerRef.current ~= forOffer or phaseRef.current == "resolving" then
					return
				end
				tween(label, HEADER_IN_MOVE_TWEEN, { Position = UDim2.fromScale(rest.X, rest.Y) })
				tween(alphaValue, HEADER_IN_FADE_TWEEN, { Value = 0 })
			end)
		end
		enter(titleRef.current, titleAlphaRef.current, TITLE_POSITION, 0)
		enter(countdownRef.current, countdownAlphaRef.current, COUNTDOWN_POSITION, COUNTDOWN_ENTRY_DELAY)
	end

	-- The reverse on close: both sink back down while fading out.
	local function headerOut()
		local function leave(label: TextLabel?, alphaValue: NumberValue?, rest: Vector2)
			if label then
				tween(label, HEADER_OUT_MOVE_TWEEN, { Position = UDim2.fromScale(rest.X, rest.Y + HEADER_RISE) })
			end
			if alphaValue then
				tween(alphaValue, HEADER_OUT_FADE_TWEEN, { Value = 1 })
			end
		end
		leave(titleRef.current, titleAlphaRef.current, TITLE_POSITION)
		leave(countdownRef.current, countdownAlphaRef.current, COUNTDOWN_POSITION)
	end

	-- One urgent second: red flash settling to a deeper red, a pulse, the tick.
	local function tickCountdown()
		local countdown = countdownRef.current
		if countdown then
			countdown.TextColor3 = COUNTDOWN_FLASH_COLOR
			tween(countdown, COUNTDOWN_FLASH_TWEEN, { TextColor3 = COUNTDOWN_URGENT_COLOR })
		end
		local scale = countdownScaleRef.current
		if scale then
			scale.Scale = COUNTDOWN_PULSE_SCALE
			tween(scale, COUNTDOWN_PULSE_TWEEN, { Scale = 1 })
		end
		playSoundId(COUNTDOWN_TICK_SOUND_ID, COUNTDOWN_TICK_VOLUME)
	end

	-- Everything gone: the hand is over. `forOffer` is the hand this call
	-- belongs to: a deferred step of an older hand must not close a newer
	-- one.
	local function finish(forOffer)
		if forOffer ~= nil and offerRef.current ~= forOffer then
			return
		end
		phaseRef.current = "closed"
		offerRef.current = nil
		-- Kept held when another hand is queued, so the HUD does not flash
		-- up for a frame between two hands.
		if queuedOfferRef.current == nil then
			holdHud(false)
		end
		pressedRef.current = nil
		hoveredRef.current = nil
		local panel = panelRef.current
		if panel then
			panel.Visible = false
		end
		local queued = queuedOfferRef.current
		queuedOfferRef.current = nil
		offerRef.current = queued
		setOffer(queued)
	end

	-- The deal: every card starts on the row's centre, low and small and
	-- invisible, then glides to its slot in hand order, fading in and
	-- sweeping as it lands. The slots' screen positions are read one
	-- frame in, once the row has laid them out.
	local function deal()
		local thisOffer = offerRef.current
		phaseRef.current = "dealing"
		shownSecondRef.current = nil
		holdHud(true)
		local panel = panelRef.current
		if panel then
			panel.Visible = true
		end
		local countdown = countdownRef.current
		if countdown then
			countdown.TextColor3 = COUNTDOWN_COLOR
		end
		local alpha = panelAlphaRef.current
		if alpha then
			alpha.Value = 1
		end
		tweenPanelAlpha(0, PANEL_FADE_TWEEN)
		headerIn(thisOffer)

		-- Hidden until the positions are known, so nothing flashes in place.
		forEachHandle(function(_, handle)
			handle.alpha.Value = 1
			handle.setScale(DEAL_FROM_SCALE)
		end)

		task.spawn(function()
			RunService.RenderStepped:Wait()
			if offerRef.current ~= thisOffer then
				return
			end

			local entries = {}
			local centerSum = 0
			forEachHandle(function(relicName, handle)
				local center = handle.slotCenter()
				table.insert(entries, { name = relicName, handle = handle, center = center })
				centerSum += center.X
			end)
			if #entries == 0 then
				phaseRef.current = "open"
				return
			end
			local rowCenterX = centerSum / #entries
			table.sort(entries, function(a, b)
				return orderOf(a.name) < orderOf(b.name)
			end)

			for index, entry in entries do
				local handle = entry.handle
				handle.setOffset(UDim2.new(0, rowCenterX - entry.center.X, DEAL_DROP, 0))
				task.delay(DEAL_LEAD_SECONDS + (index - 1) * DEAL_STAGGER, function()
					if offerRef.current ~= thisOffer or phaseRef.current == "closed" then
						return
					end
					local move = handle.tweenOffset(UDim2.new(), DEAL_MOVE_TWEEN)
					handle.tweenScale(1, DEAL_MOVE_TWEEN)
					tween(handle.alpha, DEAL_FADE_TWEEN, { Value = 0 })
					move.Completed:Once(function()
						if offerRef.current == thisOffer then
							handle.sweep()
						end
					end)
				end)
			end

			task.delay(DEAL_LEAD_SECONDS + (#entries - 1) * DEAL_STAGGER + DEAL_MOVE_TWEEN.Time * 0.6, function()
				if offerRef.current == thisOffer and phaseRef.current == "dealing" then
					phaseRef.current = "open"
				end
			end)
		end)
	end

	-- Every card but `except` (all when nil) sinks and fades.
	local function sink(except: string?)
		forEachHandle(function(relicName, handle)
			if relicName == except then
				return
			end
			handle.setHover(false)
			handle.setDim(false)
			handle.tweenOffset(UDim2.fromScale(0, SINK), SINK_TWEEN)
			tween(handle.alpha, SINK_FADE_TWEEN, { Value = 1 })
		end)
	end

	-- A pick landed: the others sink, the chosen card holds, then rises away.
	local function animateTaken(relicName: string)
		local thisOffer = offerRef.current
		phaseRef.current = "resolving"
		playUiSound(PICK_SOUND_NAME)
		sink(relicName)
		tweenPanelAlpha(1, PANEL_CLOSE_TWEEN)
		headerOut()

		local handle = handlesRef.current[relicName]
		if not handle then
			task.delay(PANEL_CLOSE_TWEEN.Time, function()
				finish(thisOffer)
			end)
			return
		end
		handle.tweenScale(1, PRESS_TWEEN)
		handle.setDim(false)
		handle.brightenStroke()
		handle.flash()
		handle.shockwave()
		task.spawn(function()
			task.wait(CHOSEN_HOLD_SECONDS)
			if offerRef.current ~= thisOffer then
				return
			end
			local rise = handle.tweenOffset(UDim2.fromScale(0, RISE), RISE_TWEEN)
			tween(handle.alpha, RISE_FADE_TWEEN, { Value = 1 })
			rise.Completed:Wait()
			finish(thisOffer)
		end)
	end

	-- Nothing taken: everything leaves together.
	local function animateDismissed()
		local thisOffer = offerRef.current
		phaseRef.current = "resolving"
		sink(nil)
		headerOut()
		local out = tweenPanelAlpha(1, PANEL_CLOSE_TWEEN)
		if out then
			out.Completed:Once(function()
				finish(thisOffer)
			end)
		else
			finish(thisOffer)
		end
	end

	local function isInteractable(): boolean
		return phaseRef.current == "open" and offerRef.current ~= nil and not trayOpenRef.current
	end

	-- The relic tray opened: drop any hover so no card stays lifted or
	-- veiled underneath it. Closing it needs nothing; the next mouse move
	-- hovers again.
	local function onRelicTrayChanged(open: boolean)
		trayOpenRef.current = open
		if not open then
			return
		end
		hoveredRef.current = nil
		forEachHandle(function(_, handle)
			handle.setHover(false)
			handle.setDim(false)
		end)
	end

	-- SELECTION. The selected card lifts, gains its stroke and slides its
	-- keyword tooltips out; every other card goes under its black veil so
	-- the selected one is the focus (a veil, not a fade: the card stays
	-- fully drawn). Deselecting lifts every veil.
	--
	-- Separate from onHover below because touch and cursor reach it
	-- differently: a cursor hovers, a finger taps.
	local function setSelection(relicName: string, on: boolean)
		if not isInteractable() then
			return
		end
		local handle = handlesRef.current[relicName]
		if not handle then
			return
		end
		if on then
			hoveredRef.current = relicName
			handle.setHover(true)
			playSoundId(HOVER_SOUND_ID, 0.4)
		else
			if hoveredRef.current == relicName then
				hoveredRef.current = nil
			end
			handle.setHover(false)
		end
		local focused = hoveredRef.current
		forEachHandle(function(otherName, other)
			other.setDim(focused ~= nil and otherName ~= focused)
		end)
	end

	-- The CURSOR path, straight off the card's MouseEnter / MouseLeave.
	--
	-- Dropped entirely on touch. A touchscreen still fires MouseEnter and
	-- MouseLeave around a tap, which would select the card under the
	-- finger and then drop it again on release -- collapsing the two-tap
	-- in onActivated back into a one-tap pick, and making it impossible
	-- to read a keyword without choosing the relic. On touch the only
	-- thing that selects is a tap.
	local function onHover(relicName: string, on: boolean)
		if IS_TOUCH then
			return
		end
		setSelection(relicName, on)
	end

	-- Clears the selection: the card drops its lift, stroke and tooltips
	-- and every veil lifts. Touch only in practice -- on desktop the
	-- cursor leaving the card does this through onHover.
	local function clearSelection()
		local focused = hoveredRef.current
		if focused then
			setSelection(focused, false)
		end
	end

	local function onActivated(relicName: string)
		if not isInteractable() or pressedRef.current then
			return
		end
		-- TOUCH TWO-TAP. There is no hover on a touchscreen, so the first
		-- tap SELECTS (lifting the card and sliding its keyword tooltips
		-- out) and only a second tap on the same card commits the pick.
		-- Without this a player cannot read a keyword without choosing
		-- the relic that mentions it.
		--
		-- Selecting a different card has to retire the old selection by
		-- hand: setSelection(_, true) only raises the new card, and with no
		-- cursor there is no MouseLeave to lower the old one.
		if IS_TOUCH and hoveredRef.current ~= relicName then
			local previous = hoveredRef.current
			if previous then
				setSelection(previous, false)
			end
			setSelection(relicName, true)
			return
		end
		local current = offerRef.current
		local handle = handlesRef.current[relicName]
		if not current or not handle then
			return
		end
		pressedRef.current = relicName
		-- Instant feedback; the real animation waits for the server.
		handle.tweenScale(PRESS_SCALE, PRESS_TWEEN)
		props.onChoose(current.OfferId, relicName)
	end

	-- Server -> this component.
	React.useEffect(function()
		local offeredConnection = props.offeredSignal:Connect(function(payload)
			-- The server deals one hand at a time, but its next deal can
			-- land while the last outcome is still animating: that hand
			-- waits for finish().
			if phaseRef.current ~= "closed" then
				queuedOfferRef.current = payload
				return
			end
			offerRef.current = payload
			setOffer(payload)
		end)
		local resolvedConnection = props.resolvedSignal:Connect(function(payload)
			local current = offerRef.current
			if not current or payload.OfferId ~= current.OfferId then
				return
			end
			local outcome = payload.Outcome
			if outcome == "Refused" then
				local pressed = pressedRef.current
				pressedRef.current = nil
				local handle = pressed and handlesRef.current[pressed]
				if handle then
					handle.tweenScale(1, PRESS_TWEEN)
					handle.wobble()
				end
				return
			end
			if outcome == "Taken" and payload.RelicName then
				animateTaken(payload.RelicName)
			else
				animateDismissed()
			end
		end)
		return function()
			offeredConnection:Disconnect()
			resolvedConnection:Disconnect()
			-- Unmounting mid-hand must not leave the HUD held.
			holdHud(false)
		end
	end, {})

	-- The relic tray opening or closing gates the cards.
	React.useEffect(function()
		local connection = props.relicTrayChanged:Connect(onRelicTrayChanged)
		return function()
			connection:Disconnect()
		end
	end, {})

	-- Phone or not is re-read live (rotation, window resize).
	React.useEffect(function()
		local connection = props.screenSizeChanged:Connect(function()
			setIsPhone(props.isPhone())
		end)
		return function()
			connection:Disconnect()
		end
	end, {})

	-- A new hand mounted its cards (their register effects ran before
	-- this one): deal it.
	React.useEffect(function()
		if offer then
			deal()
		end
	end, { offer })

	-- Per frame: the countdown. Each new second updates the number once;
	-- the last COUNTDOWN_URGENT_SECONDS also tick (red flash, pulse, sound)
	-- while the hand is still up.
	React.useEffect(function()
		local connection = RunService.RenderStepped:Connect(function()
			local current = offerRef.current
			local countdown = countdownRef.current
			if not current or not countdown then
				return
			end
			local remaining = math.max(0, math.ceil(current.ExpiresAt - workspace:GetServerTimeNow()))
			if remaining == shownSecondRef.current then
				return
			end
			shownSecondRef.current = remaining
			countdown.Text = tostring(remaining)
			local live = phaseRef.current == "open" or phaseRef.current == "dealing"
			if live and remaining > 0 and remaining <= COUNTDOWN_URGENT_SECONDS then
				tickCountdown()
			end
		end)
		return function()
			connection:Disconnect()
		end
	end, {})

	-- The panel alpha value: one tween drives every panel transparency.
	React.useEffect(function()
		local value = Instance.new("NumberValue")
		value.Value = 1
		panelAlphaRef.current = value
		local connection = value.Changed:Connect(applyPanelAlpha)
		applyPanelAlpha(1)

		-- The title and countdown each fade on their own value.
		local titleValue = Instance.new("NumberValue")
		titleValue.Value = 1
		titleAlphaRef.current = titleValue
		local titleConnection = titleValue.Changed:Connect(function(a: number)
			applyLabelAlpha(titleRef.current, a)
		end)
		applyLabelAlpha(titleRef.current, 1)

		local countdownValue = Instance.new("NumberValue")
		countdownValue.Value = 1
		countdownAlphaRef.current = countdownValue
		local countdownConnection = countdownValue.Changed:Connect(function(a: number)
			applyLabelAlpha(countdownRef.current, a)
		end)
		applyLabelAlpha(countdownRef.current, 1)

		return function()
			connection:Disconnect()
			titleConnection:Disconnect()
			countdownConnection:Disconnect()
			value:Destroy()
			titleValue:Destroy()
			countdownValue:Destroy()
			panelAlphaRef.current = nil
			titleAlphaRef.current = nil
			countdownAlphaRef.current = nil
		end
	end, {})

	local cardChildren = {
		UIListLayout = React.createElement("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(CARD_GAP, 0),
		}),
	}
	if offer then
		for index, relicName in offer.Relics do
			cardChildren[relicName] = React.createElement(OfferCard, {
				relicName = relicName,
				index = index,
				isPhone = isPhone,
				onRegister = function(name: string, handle)
					handlesRef.current[name] = handle
				end,
				onHover = onHover,
				onActivated = onActivated,
			})
		end
	end

	return React.createElement("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
	}, {
		Panel = React.createElement("Frame", {
			ref = panelRef,
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Visible = false,
		}, {
			-- Swallows clicks under the cards while the hand is open.
			Backdrop = React.createElement("Frame", {
				ref = backdropRef,
				Size = UDim2.fromScale(1, 1),
				BackgroundColor3 = BACKDROP_COLOR,
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				Active = true,
				ZIndex = 0,
			}),

			-- TOUCH ONLY: a tap anywhere off the hand clears the selection
			-- (see the two-tap in onActivated). Above the backdrop and
			-- BELOW the cards (ZIndex 2), so a tap on a card still reaches
			-- the card. Absent entirely on desktop, where the cursor
			-- leaving a card already clears it.
			DeselectCatcher = if IS_TOUCH
				then React.createElement("ImageButton", {
					Size = UDim2.fromScale(1, 1),
					BackgroundTransparency = 1,
					ImageTransparency = 1,
					AutoButtonColor = false,
					ZIndex = 1,
					[React.Event.Activated] = clearSelection,
				})
				else nil,

			Title = React.createElement("TextLabel", {
				ref = titleRef,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(TITLE_POSITION.X, TITLE_POSITION.Y),
				Size = TITLE_SIZE,
				BackgroundTransparency = 1,
				Text = TITLE_TEXT,
				TextColor3 = TEXT_COLOR,
				TextStrokeColor3 = Color3.fromRGB(0, 0, 0),
				TextTransparency = 1,
				TextStrokeTransparency = 1,
				FontFace = FONT_BOLD,
				TextScaled = true,
				ZIndex = 2,
			}, {
				UITextSizeConstraint = React.createElement("UITextSizeConstraint", { MaxTextSize = 50 }),
			}),

			-- Seconds until the server picks for the player, under the title.
			Seconds = React.createElement("TextLabel", {
				ref = countdownRef,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(COUNTDOWN_POSITION.X, COUNTDOWN_POSITION.Y),
				Size = COUNTDOWN_SIZE,
				BackgroundTransparency = 1,
				Text = "",
				TextColor3 = COUNTDOWN_COLOR,
				TextStrokeColor3 = Color3.fromRGB(0, 0, 0),
				TextTransparency = 1,
				TextStrokeTransparency = 1,
				FontFace = FONT_BOLD,
				TextScaled = true,
				ZIndex = 2,
			}, {
				UITextSizeConstraint = React.createElement("UITextSizeConstraint", { MaxTextSize = 44 }),
				UIScale = React.createElement("UIScale", {
					ref = countdownScaleRef,
					Scale = 1,
				}),
			}),

			Cards = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, ROW_Y),
				Size = UDim2.fromScale(1, cardHeight),
				BackgroundTransparency = 1,
				ZIndex = 2,
			}, cardChildren),
		}),
	})
end

return Container
