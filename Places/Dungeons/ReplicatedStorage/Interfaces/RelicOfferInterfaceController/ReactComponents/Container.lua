--[[
	Module: Container.lua
	Description:
	The relic-offer overlay: "Pick a Relic" with the auto-pick countdown
	under it (this ScreenGui), and the hand of OfferCards standing in 3D
	in front of the camera (CardStage: one part per card, drawn through a
	SurfaceGui). No buttons: the hand stays up until a card is picked or
	the countdown runs out and the server picks. The last
	COUNTDOWN_URGENT_SECONDS tick in red with a pulse and a tick sound.

	NO DIM BACKDROP in this ScreenGui. An AlwaysOnTop SurfaceGui draws
	under every ScreenGui, so a full-screen frame here would paint over
	the cards and swallow their input. Instead the WORLD recedes while a
	hand is up (the scene helpers below): a DepthOfFieldEffect focused on
	the card plane blurs the dungeon behind, and the stage's dim plane
	(CardStage.setDim, a black part behind the cards) darkens it to the
	old backdrop's level. Both tween in with the deal and out on finish.
	Nothing touches the Atmosphere: a haze boost read differently at every
	zoom level and perspective (owner, 2026-10-22).

	The relic tray (RelicInterfaceController) draws ABOVE this overlay, so
	a player can open it mid-offer to read their relics or drop one to free
	a slot for a pick. A capped player who does neither is skipped by the
	server when the countdown ends.

	While the hand is up the HUD scope is held closed (reference-counted
	through InterfaceManagerController, so a cutscene or death fade still
	composes). The relic tray is a Windows interface, so it stays usable.
	On mobile the combat controls hide with it (MobileActionButtonInterface:
	Roll, Swap Weapon and the tagged arcane sticks); the movement and aim
	sticks stay.

	The SERVER owns the offer (RelicOfferService): this component draws
	what it was dealt, sends the click, and animates the OUTCOME the
	server reports back -- a pick is never animated on the click alone, so
	a refused pick (cap, dead) cannot leave the screen out of step. The
	press itself gets an instant dip so the click still feels immediate.

	Motion (all imperative, on the OfferCard handles; the part poses go
	through handle.tweenPose, CardStage):
	  * deal:    the cards fly in ONE BY ONE straight up from below the
	             bottom edge of the view to their slots, each turning
	             exactly once about its spine as it rises. Both faces show
	             the card back until the turn passes edge-on at
	             DEAL_REVEAL_YAW, when the front's cover drops, so the
	             player sees back, edge, back, edge, front. A light sweep
	             crosses each as it lands (and again on the card's own
	             timer, OfferCard)
	  * hover:   the card comes toward the camera, leans toward the cursor
	             and gains its stroke; the others go under their black veil
	  * idle:    a slow sine bob per card (OfferCard's own looping tween)
	  * taken:   the others flip back over and drop out of view; the
	             chosen card flashes white, a ring in its tier colour
	             ripples out, its stroke lights, it holds a beat, then
	             flies toward the camera while fading
	  * skipped / cancelled: every card flips back over and drops away
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local Lighting = game:GetService("Lighting")
local Debris = game:GetService("Debris")

local React = require(ReplicatedStorage.Submodules.Core.Packages.React)
local InterfaceManagerController =
	require(ReplicatedStorage.Submodules.Core.Source.Controllers.InterfaceManagerController)
local InterfaceScopes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.InterfaceScopes)
local Blitz = require(ReplicatedStorage.Submodules.Core.Shared.Blitz)

local OfferCard = require(script.Parent.OfferCard)
local CardStage = require(script.Parent.CardStage)

-- The HUD scope hold while the hand is up.
local HUD_HIDE_SOURCE = "RelicOffer"

--[ Tuning ]--

local FONT_BOLD = Font.new("rbxasset://fonts/families/Montserrat.json", Enum.FontWeight.Bold)

local TITLE_TEXT = "Pick a Relic"

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
-- follows from the card's aspect ratio (CardStage.FACE_ASPECT). The stage
-- lays the faces out on screen exactly as the old 2D row did: centred as
-- a group, CARD_GAP of the width apart, centred on ROW_Y.
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
local TITLE_POSITION = Vector2.new(0.498268, 0.170443)
local TITLE_SIZE = UDim2.fromScale(0.318, 0.058)
local COUNTDOWN_POSITION = Vector2.new(0.498, 0.226089)
local COUNTDOWN_SIZE = UDim2.fromScale(0.063, 0.049)
-- The bar under the number: a thin neutral track that drains left to
-- right with the seconds left (design call, 2026-10-21). A SIBLING of the
-- number's label (its UIScale pulse must not scale the bar), placed where
-- it sat as the label's child: top at 1.22643 label heights under the
-- label's top, 1.3 label widths wide, 0.1 label heights tall. It rides
-- the countdown's entry / exit glide and fades with it; its fill goes
-- red with the number on the urgent ticks.
local COUNTDOWN_BAR_POSITION =
	Vector2.new(COUNTDOWN_POSITION.X, COUNTDOWN_POSITION.Y + 0.72643 * COUNTDOWN_SIZE.Y.Scale)
local COUNTDOWN_BAR_SIZE = UDim2.fromScale(1.3 * COUNTDOWN_SIZE.X.Scale, 0.16 * COUNTDOWN_SIZE.Y.Scale)
local COUNTDOWN_BAR_TRACK_COLOR = Color3.fromRGB(255, 255, 255)
local COUNTDOWN_BAR_TRACK_TRANSPARENCY = 0.8
local COUNTDOWN_BAR_FILL_COLOR = Color3.fromRGB(255, 255, 255)
local COUNTDOWN_BAR_FILL_TRANSPARENCY = 0.1
-- The server's hand length, for the bar's full width; a hand that reads
-- longer on its first tick stretches it (the max seen wins).
local COUNTDOWN_BAR_FULL_SECONDS = 30
local HEADER_RISE = 0.03
local COUNTDOWN_ENTRY_DELAY = 0.08
local HEADER_IN_MOVE_TWEEN = TweenInfo.new(0.5, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local HEADER_IN_FADE_TWEEN = TweenInfo.new(0.5, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
local HEADER_OUT_MOVE_TWEEN = TweenInfo.new(0.4, Enum.EasingStyle.Quint, Enum.EasingDirection.In)
local HEADER_OUT_FADE_TWEEN = TweenInfo.new(0.35, Enum.EasingStyle.Sine, Enum.EasingDirection.In)

-- The deal: each card starts just below the bottom edge of the view
-- (OFFSCREEN_MARGIN face heights under it), one card every STAGGER after
-- a LEAD beat, and rises straight up to its slot on a Quad-Out (no
-- overshoot, x never moves) while turning DEAL_SPIN degrees about its
-- spine on a Quad-InOut, pivoting on the face centre, with no pitch or
-- roll. Its front wears the card-back COVER until the turn passes
-- DEAL_REVEAL_YAW (edge-on), so the turn reads as one spin that reveals
-- the card. The front fades in under the cover and sweeps as it lands.
local DEAL_STAGGER = 0.14
local DEAL_LEAD_SECONDS = 0.12
local DEAL_MOVE_TWEEN = TweenInfo.new(1.05, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local DEAL_SPIN_TWEEN = TweenInfo.new(1.05, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
local DEAL_SPIN = 360
local DEAL_REVEAL_YAW = 270
local DEAL_FADE_TWEEN = TweenInfo.new(0.6, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
local OFFSCREEN_MARGIN = 0.1
-- Leaving (the dismissed cards, and the others when one is taken): each
-- flips back over (DISMISS_FLIP degrees) while dropping below the view.
local DISMISS_FLIP = 180
local DISMISS_FLIP_TWEEN = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
local DISMISS_DROP_TWEEN = TweenInfo.new(0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
-- The chosen card: stroke lit, a held beat, then it flies this far toward
-- the camera (studs, of CardStage.STAGE_DISTANCE) while fading out.
local CHOSEN_HOLD_SECONDS = 0.45
local TAKEN_FLY_DEPTH = 5
local TAKEN_FLY_RISE = -0.1
local RISE_TWEEN = TweenInfo.new(0.65, Enum.EasingStyle.Quint, Enum.EasingDirection.In)
local RISE_FADE_TWEEN = TweenInfo.new(0.5, Enum.EasingStyle.Sine, Enum.EasingDirection.In)
-- The press: a quick dip, instantly, while the server answers.
local PRESS_SCALE = 0.975
local PRESS_TWEEN = TweenInfo.new(0.28, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)

-- The world behind the hand: a depth of field focused on the card plane
-- (CardStage.STAGE_DISTANCE out, the cards sharp, the dungeon soft) and
-- the stage's dim plane behind the cards. Both ease over SCENE_TWEEN.
local SCENE_DOF_NAME = "RelicOfferDepthOfField"
local SCENE_DOF_IN_FOCUS_RADIUS = 6
local SCENE_DOF_FAR_INTENSITY = 0.75
local SCENE_TWEEN = TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)

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

--[ Scene ]--

-- ONE scene state for this client. `token` is the owner of the current
-- transition: an out that has been overtaken by a new in (a hand dealt
-- while the last one is closing) finds its token stale and leaves the
-- effects alone, so nothing double-applies and nothing restores early.
-- The dim plane keeps its own generation the same way (CardStage.setDim).
local scene = {
	token = 0,
	active = false,
	dof = nil :: DepthOfFieldEffect?,
}

local function sceneDof(): DepthOfFieldEffect
	local existing = scene.dof
	if existing and existing.Parent == Lighting then
		return existing
	end
	local found = Lighting:FindFirstChild(SCENE_DOF_NAME)
	local dof: DepthOfFieldEffect
	if found and found:IsA("DepthOfFieldEffect") then
		dof = found
	else
		dof = Instance.new("DepthOfFieldEffect")
		dof.Name = SCENE_DOF_NAME
		dof.NearIntensity = 0
		dof.FarIntensity = 0
		dof.Parent = Lighting
	end
	dof.FocusDistance = CardStage.STAGE_DISTANCE
	dof.InFocusRadius = SCENE_DOF_IN_FOCUS_RADIUS
	scene.dof = dof
	return dof
end

local function sceneIn()
	scene.token += 1
	scene.active = true
	local dof = sceneDof()
	dof.Enabled = true
	tween(dof, SCENE_TWEEN, { FarIntensity = SCENE_DOF_FAR_INTENSITY })
	CardStage.setDim(true, SCENE_TWEEN)
end

-- `immediate` (unmount) restores on the spot instead of easing out.
local function sceneOut(immediate: boolean?)
	if not scene.active then
		return
	end
	scene.token += 1
	local token = scene.token
	local dof = scene.dof

	local function restore()
		if scene.token ~= token then
			return
		end
		scene.active = false
		if dof then
			dof.FarIntensity = 0
			dof.Enabled = false
		end
	end

	if immediate then
		CardStage.destroyDim()
		restore()
		return
	end
	CardStage.setDim(false, SCENE_TWEEN)
	local out = if dof then tween(dof, SCENE_TWEEN, { FarIntensity = 0 }) else nil
	if out then
		out.Completed:Once(restore)
	else
		restore()
	end
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

	local panelRef = React.useRef(nil)
	local titleRef = React.useRef(nil)
	local countdownRef = React.useRef(nil)
	local countdownScaleRef = React.useRef(nil)
	local countdownBarTrackRef = React.useRef(nil)
	local countdownBarFillRef = React.useRef(nil)
	-- The seconds the bar reads as full for this hand (see
	-- COUNTDOWN_BAR_FULL_SECONDS); reset by the deal.
	local countdownBarFullRef = React.useRef(COUNTDOWN_BAR_FULL_SECONDS)
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
	-- The card the cursor is over per MouseEnter / MouseLeave, kept through
	-- EVERY phase. Hover is only honoured once the hand is open, and a
	-- card that slid under the cursor during the deal fires no second
	-- MouseEnter when it opens -- so the open replays this instead.
	local cursorOverRef = React.useRef(nil)
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

	-- The face's offset (in face heights) that puts its top edge just under
	-- the bottom of the view: the deal's start and the dismissed drop's end.
	local function offscreenBelow(): number
		return (1 - ROW_Y) / cardHeight + 0.5 + OFFSCREEN_MARGIN
	end

	-- The title and countdown arrive: each starts HEADER_RISE lower and
	-- invisible, then glides up into place while fading in, the countdown
	-- COUNTDOWN_ENTRY_DELAY behind the title.
	local function headerIn(forOffer)
		-- `alphaValue` nil: the object fades on another's value (the bar
		-- on the countdown's) and only glides here.
		local function enter(label: GuiObject?, alphaValue: NumberValue?, rest: Vector2, delay: number)
			if not label then
				return
			end
			label.Position = UDim2.fromScale(rest.X, rest.Y + HEADER_RISE)
			if alphaValue then
				alphaValue.Value = 1
			end
			task.delay(delay, function()
				if offerRef.current ~= forOffer or phaseRef.current == "resolving" then
					return
				end
				tween(label, HEADER_IN_MOVE_TWEEN, { Position = UDim2.fromScale(rest.X, rest.Y) })
				if alphaValue then
					tween(alphaValue, HEADER_IN_FADE_TWEEN, { Value = 0 })
				end
			end)
		end
		enter(titleRef.current, titleAlphaRef.current, TITLE_POSITION, 0)
		enter(countdownRef.current, countdownAlphaRef.current, COUNTDOWN_POSITION, COUNTDOWN_ENTRY_DELAY)
		enter(countdownBarTrackRef.current, nil, COUNTDOWN_BAR_POSITION, COUNTDOWN_ENTRY_DELAY)
	end

	-- The reverse on close: both sink back down while fading out.
	local function headerOut()
		local function leave(label: GuiObject?, alphaValue: NumberValue?, rest: Vector2)
			if label then
				tween(label, HEADER_OUT_MOVE_TWEEN, { Position = UDim2.fromScale(rest.X, rest.Y + HEADER_RISE) })
			end
			if alphaValue then
				tween(alphaValue, HEADER_OUT_FADE_TWEEN, { Value = 1 })
			end
		end
		leave(titleRef.current, titleAlphaRef.current, TITLE_POSITION)
		leave(countdownRef.current, countdownAlphaRef.current, COUNTDOWN_POSITION)
		leave(countdownBarTrackRef.current, nil, COUNTDOWN_BAR_POSITION)
	end

	-- One urgent second: red flash settling to a deeper red (the number and
	-- the bar's fill), a pulse on the number alone, the tick.
	local function tickCountdown()
		local countdown = countdownRef.current
		if countdown then
			countdown.TextColor3 = COUNTDOWN_FLASH_COLOR
			tween(countdown, COUNTDOWN_FLASH_TWEEN, { TextColor3 = COUNTDOWN_URGENT_COLOR })
		end
		local fill = countdownBarFillRef.current
		if fill then
			fill.BackgroundColor3 = COUNTDOWN_FLASH_COLOR
			tween(fill, COUNTDOWN_FLASH_TWEEN, { BackgroundColor3 = COUNTDOWN_URGENT_COLOR })
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
		-- up for a frame between two hands (and the world stays receded).
		if queuedOfferRef.current == nil then
			holdHud(false)
			sceneOut()
		end
		pressedRef.current = nil
		hoveredRef.current = nil
		cursorOverRef.current = nil
		local panel = panelRef.current
		if panel then
			panel.Visible = false
		end
		local queued = queuedOfferRef.current
		queuedOfferRef.current = nil
		offerRef.current = queued
		setOffer(queued)
	end

	-- Defined with the selection helpers below; the deal's open edge calls it.
	local applyPendingHover

	-- The deal: every card is parked below the view, back-facing and
	-- invisible, then flies up to its slot in hand order, spinning to face
	-- up, fading in and sweeping as it lands. The stage owns the slots, so
	-- nothing has to be measured first.
	local function deal()
		local thisOffer = offerRef.current
		phaseRef.current = "dealing"
		shownSecondRef.current = nil
		countdownBarFullRef.current = COUNTDOWN_BAR_FULL_SECONDS
		holdHud(true)
		local panel = panelRef.current
		if panel then
			panel.Visible = true
		end
		local countdown = countdownRef.current
		if countdown then
			countdown.TextColor3 = COUNTDOWN_COLOR
		end
		local fill = countdownBarFillRef.current
		if fill then
			fill.BackgroundColor3 = COUNTDOWN_BAR_FILL_COLOR
		end
		sceneIn()
		headerIn(thisOffer)

		local entries = {}
		forEachHandle(function(relicName, handle)
			-- Parked out of view below the bottom edge, front toward the
			-- camera but under its back cover.
			handle.alpha.Value = 1
			handle.setScale(1)
			handle.setOffset(UDim2.new())
			handle.setCover(true)
			handle.setPose({ x = 0, y = offscreenBelow(), depth = 0, yaw = 0, pitch = 0, roll = 0 })
			table.insert(entries, { name = relicName, handle = handle })
		end)
		if #entries == 0 then
			phaseRef.current = "open"
			return
		end
		table.sort(entries, function(a, b)
			return orderOf(a.name) < orderOf(b.name)
		end)

		for index, entry in entries do
			local handle = entry.handle
			task.delay(DEAL_LEAD_SECONDS + (index - 1) * DEAL_STAGGER, function()
				if offerRef.current ~= thisOffer or phaseRef.current == "closed" then
					return
				end
				local move = handle.tweenPose({ y = 0 }, DEAL_MOVE_TWEEN)
				handle.revealAtYaw(DEAL_REVEAL_YAW)
				local spin = handle.tweenPose({ yaw = DEAL_SPIN }, DEAL_SPIN_TWEEN)
				tween(handle.alpha, DEAL_FADE_TWEEN, { Value = 0 })
				-- The text follows the art in, a beat later (OfferCard).
				handle.revealDescription()
				if spin then
					-- A full turn is where it started: rest at 0 so the later
					-- flip-back turns half, not one and a half.
					spin.Completed:Once(function()
						if offerRef.current == thisOffer then
							handle.setCover(false)
							handle.setPose({ yaw = 0 })
						end
					end)
				end
				if move then
					move.Completed:Once(function()
						if offerRef.current == thisOffer then
							handle.sweep()
						end
					end)
				end
			end)
		end

		-- Open only once the LAST card's flight and spin have completed:
		-- a hover before that would add its depth and tilt to the spin.
		task.delay(DEAL_LEAD_SECONDS + (#entries - 1) * DEAL_STAGGER + DEAL_MOVE_TWEEN.Time + 0.05, function()
			if offerRef.current == thisOffer and phaseRef.current == "dealing" then
				phaseRef.current = "open"
				applyPendingHover()
			end
		end)
	end

	-- Every card but `except` (all when nil) flips back over and drops out
	-- of the view. Returns the longest tween, for the caller's finish.
	local function dismiss(except: string?): Tween?
		local last: Tween? = nil
		forEachHandle(function(relicName, handle)
			if relicName == except then
				return
			end
			handle.setHover(false)
			handle.setDim(false)
			handle.hideTooltip()
			handle.tweenPose({ yaw = DISMISS_FLIP, depth = 0 }, DISMISS_FLIP_TWEEN)
			last = handle.tweenPose({ y = offscreenBelow() }, DISMISS_DROP_TWEEN) or last
		end)
		return last
	end

	-- A pick landed: the others leave, the chosen card holds, then flies
	-- into the camera.
	local function animateTaken(relicName: string)
		local thisOffer = offerRef.current
		phaseRef.current = "resolving"
		playUiSound(PICK_SOUND_NAME)
		dismiss(relicName)
		headerOut()

		local handle = handlesRef.current[relicName]
		if not handle then
			task.delay(DISMISS_DROP_TWEEN.Time, function()
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
			local fly = handle.tweenPose({ depth = TAKEN_FLY_DEPTH, y = TAKEN_FLY_RISE }, RISE_TWEEN)
			tween(handle.alpha, RISE_FADE_TWEEN, { Value = 1 })
			-- The keyword column leaves with the card instead of lingering.
			handle.hideTooltip()
			if fly then
				fly.Completed:Wait()
			end
			finish(thisOffer)
		end)
	end

	-- Nothing taken: everything leaves together.
	local function animateDismissed()
		local thisOffer = offerRef.current
		phaseRef.current = "resolving"
		headerOut()
		local out = dismiss(nil)
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
			-- One hover at a time. A cursor crossing straight from one card
			-- onto the next can land the new MouseEnter before the old
			-- MouseLeave, which left the first card lifted with its keyword
			-- column still sliding out. Every other card is dropped here,
			-- unconditionally, before the new one lifts: its column tweens
			-- back and its lift and stroke go with it (setHover is a no-op
			-- on a card that is not hovered).
			forEachHandle(function(otherName, other)
				if otherName ~= relicName then
					other.setHover(false)
				end
			end)
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
		if on then
			cursorOverRef.current = relicName
		elseif cursorOverRef.current == relicName then
			cursorOverRef.current = nil
		end
		setSelection(relicName, on)
	end

	-- The hand just opened: select the card the cursor is already on.
	-- MouseEnter that fired during the deal was ignored (not interactable
	-- yet) and will not fire again; a cursor that never moved while the
	-- cards dealt in under it never got one at all, so when nothing was
	-- tracked the slots are hit-tested against the cursor directly.
	function applyPendingHover()
		if IS_TOUCH or not isInteractable() then
			return
		end
		local under = cursorOverRef.current
		if not under then
			local inset = GuiService:GetGuiInset()
			local cursor = UserInputService:GetMouseLocation() - inset
			forEachHandle(function(relicName, handle)
				if under == nil and handle.containsPoint(cursor) then
					under = relicName
				end
			end)
		end
		if under and hoveredRef.current ~= under then
			setSelection(under, true)
		end
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
			-- Unmounting mid-hand must not leave the HUD held or the world
			-- receded.
			holdHud(false)
			sceneOut(true)
		end
	end, {})

	-- The relic tray opening or closing gates the cards.
	React.useEffect(function()
		local connection = props.relicTrayChanged:Connect(onRelicTrayChanged)
		return function()
			connection:Disconnect()
		end
	end, {})

	-- TOUCH ONLY: a tap anywhere off the hand clears the selection (see the
	-- two-tap in onActivated). A tap on a card is game-processed by its
	-- ImageButton and skipped here. Absent on desktop, where the cursor
	-- leaving a card already clears it. (A full-screen catcher frame would
	-- sit in this ScreenGui, above the cards' SurfaceGuis, and eat their
	-- taps.)
	React.useEffect(function()
		if not IS_TOUCH then
			return nil
		end
		local connection = UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
			if processed or input.UserInputType ~= Enum.UserInputType.Touch then
				return
			end
			clearSelection()
		end)
		return function()
			connection:Disconnect()
		end
	end, {})

	-- The stage lays the faces out from the platform's card height.
	React.useEffect(function()
		CardStage.setLayout({ cardHeight = cardHeight, rowY = ROW_Y, gap = CARD_GAP })
	end, { cardHeight })

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
			local secondsLeft = math.max(0, current.ExpiresAt - workspace:GetServerTimeNow())
			-- The bar drains continuously, every frame, on the exact time.
			local fill = countdownBarFillRef.current
			if fill then
				local full = math.max(countdownBarFullRef.current, secondsLeft)
				countdownBarFullRef.current = full
				fill.Size = UDim2.fromScale(if full > 0 then math.clamp(secondsLeft / full, 0, 1) else 0, 1)
			end
			local remaining = math.ceil(secondsLeft)
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

	-- The title and countdown each fade on their own value.
	React.useEffect(function()
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
		local function applyCountdownAlpha(a: number)
			applyLabelAlpha(countdownRef.current, a)
			-- The bar fades with the number (its own transparencies, lerped
			-- from fully drawn to gone).
			local track = countdownBarTrackRef.current
			if track then
				track.BackgroundTransparency = COUNTDOWN_BAR_TRACK_TRANSPARENCY
					+ (1 - COUNTDOWN_BAR_TRACK_TRANSPARENCY) * a
			end
			local fill = countdownBarFillRef.current
			if fill then
				fill.BackgroundTransparency = COUNTDOWN_BAR_FILL_TRANSPARENCY
					+ (1 - COUNTDOWN_BAR_FILL_TRANSPARENCY) * a
			end
		end
		local countdownConnection = countdownValue.Changed:Connect(applyCountdownAlpha)
		applyCountdownAlpha(1)

		return function()
			titleConnection:Disconnect()
			countdownConnection:Disconnect()
			titleValue:Destroy()
			countdownValue:Destroy()
			titleAlphaRef.current = nil
			countdownAlphaRef.current = nil
		end
	end, {})

	-- The cards. Each OfferCard draws itself on the stage (its own part in
	-- front of the camera); this ScreenGui holds only their React nodes,
	-- not their pixels.
	local cardChildren = {}
	if offer then
		for index, relicName in offer.Relics do
			cardChildren[relicName] = React.createElement(OfferCard, {
				relicName = relicName,
				index = index,
				count = #offer.Relics,
				isPhone = isPhone,
				tilt = not IS_TOUCH,
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

			-- The time-left bar: a track with a fill that drains to the left
			-- edge (anchored left). Under the number but NOT inside it, so the
			-- number's pulse leaves it still. Both start invisible with the
			-- number and fade with it.
			SecondsBar = React.createElement("Frame", {
				ref = countdownBarTrackRef,
				AnchorPoint = Vector2.new(0.5, 0),
				Position = UDim2.fromScale(COUNTDOWN_BAR_POSITION.X, COUNTDOWN_BAR_POSITION.Y),
				Size = COUNTDOWN_BAR_SIZE,
				BackgroundColor3 = COUNTDOWN_BAR_TRACK_COLOR,
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				ZIndex = 2,
			}, {
				UICorner = React.createElement("UICorner", { CornerRadius = UDim.new(1, 0) }),
				Fill = React.createElement("Frame", {
					ref = countdownBarFillRef,
					AnchorPoint = Vector2.new(0, 0.5),
					Position = UDim2.fromScale(0, 0.5),
					Size = UDim2.fromScale(1, 1),
					BackgroundColor3 = COUNTDOWN_BAR_FILL_COLOR,
					BackgroundTransparency = 1,
					BorderSizePixel = 0,
					ZIndex = 3,
				}, {
					UICorner = React.createElement("UICorner", { CornerRadius = UDim.new(1, 0) }),
				}),
			}),

			Cards = React.createElement("Folder", {}, cardChildren),
		}),
	})
end

return Container
