--[[
	Module: OfferCard.lua
	Description:
	ONE card of a relic offer, to the authored card design: the card art
	with the relic's name across the top, a tinted icon window (gradient
	to transparent, a tilted tile pattern scrolling under it) with the
	relic icon floating over it, the rarity as a coloured pill and the
	rich-text description. Every motion is imperative (TweenService on
	refs), driven from the Container through the HANDLE this component
	registers on mount:

	  handle.alpha              NumberValue, 0 = drawn, 1 = invisible. The
	                            card is a CanvasGroup, so this is ONE
	                            property (GroupTransparency) plus the
	                            shadow: every part fades together, always.
	  handle.setScale(s)        the card's size relative to its slot.
	  handle.tweenScale(s, info)
	  handle.setOffset(udim2)   the card's displacement from its slot
	  handle.tweenOffset(udim2, info)   (the deal-in, the sink, the rise).
	  handle.setHover(on)       the selected look: lift + SelectionUIStroke.
	  handle.setDim(on)         a black veil over the card (the unfocused
	                            look while another card is hovered).
	  handle.brightenStroke()   the chosen card's stroke goes white.
	  handle.sweep()            a light streak crosses the card once.
	  handle.flash()            the pick: the card flashes white for a beat.
	  handle.shockwave()        the pick: a ring in the tier colour expands
	                            from the card's edge and fades.
	  handle.wobble()           the refused shake.
	  handle.slotCenter()       the slot's centre on screen, for the deal.
	  handle.rarity             ItemRarity value.

	The card's own idle motion needs nothing from the Container: the bob
	(a looping tween on its Bob frame, phase-shifted by slot) and the
	tile scroll (the label sliding one tile along its tilted axis). None
	of it moves per frame from Lua.

	Frames, outermost in: Slot (laid out by the row) > Bob (idle tween) >
	Offset (deal / sink / rise) > Lift (hover) > Card (CanvasGroup: scale,
	fade, shadow) > Art (the button and everything drawn).

	Colours come from RarityColors:GetCard. Layout is in fractions of the
	card, so the same tree serves the desktop size and the larger mobile
	one.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local React = require(ReplicatedStorage.Submodules.Core.Packages.React)
local RelicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicData)
local RarityColors = require(ReplicatedStorage.Submodules.Core.Shared.Data.RarityColors)
local ItemRarity = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ItemRarity)
local ElementTrees = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ElementTrees)
local getRelicDescription = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Relic.getRelicDescription)

--[ Tuning ]--

-- The card frame art, stretched to the card: one image per element tree
-- (RelicData `tree`), tinted by the same tree (CARD_TINTS).
-- Each tree's art covers its status and aura (Blaze + Enflamed, Storm +
-- Stormcharged, Frost + Frostburst, Venom + Blighted, Earth + Stonebound
-- and shields). Neutral, which holds every Cursed relic, is the fallback.
local CARD_IMAGES: { [string]: string } = {
	[ElementTrees.Blaze] = "rbxassetid://105369649773171",
	[ElementTrees.Storm] = "rbxassetid://99232530276305",
	[ElementTrees.Frost] = "rbxassetid://77047957089894",
	[ElementTrees.Venom] = "rbxassetid://88646270168092",
	[ElementTrees.Earth] = "rbxassetid://79296494000202",
	[ElementTrees.Neutral] = "rbxassetid://130599641461508",
}
local DEFAULT_CARD_IMAGE = CARD_IMAGES[ElementTrees.Neutral]
-- The card art's ImageColor3, by element tree. A Cursed relic (every one
-- sits in Neutral) takes CURSED_CARD_TINT instead.
local CARD_TINTS: { [string]: Color3 } = {
	[ElementTrees.Blaze] = Color3.fromRGB(255, 102, 0),
	[ElementTrees.Frost] = Color3.fromRGB(126, 253, 255),
	[ElementTrees.Storm] = Color3.fromRGB(193, 94, 255),
	[ElementTrees.Venom] = Color3.fromRGB(13, 212, 93),
	[ElementTrees.Earth] = Color3.fromRGB(255, 183, 0),
	[ElementTrees.Neutral] = Color3.fromRGB(207, 207, 207),
}
local DEFAULT_CARD_TINT = CARD_TINTS[ElementTrees.Neutral]
local CURSED_CARD_TINT = Color3.fromRGB(255, 0, 0)
-- Every relic's icon until the per-relic art lands (RelicData.icon wins
-- when a relic has one).
local DEFAULT_ICON = "rbxassetid://91274990645548"

-- The tile pattern under the icon window: black at half, tilted, and
-- scrolling along its own tilted axis. The label slides EXACTLY one tile
-- along its local x per loop, so the wrap is invisible; it is oversized
-- (the authored 1.2 window-widths, scaled up) so the window stays
-- covered at both ends of the slide even through the tilt, and the tile
-- is shrunk by the same factor so the pattern's apparent size is the
-- authored 0.3 of the original label.
local TILE_IMAGE = "rbxassetid://7186797295"
local TILE_TRANSPARENCY = 0.5
local TILE_COLOR = Color3.fromRGB(0, 0, 0)
local TILE_ROTATION = 25
local TILE_POSITION = Vector2.new(0.48927, 0.498791)
local TILE_AUTHORED_LABEL = 1.21515
local TILE_AUTHORED_TILE = 0.3
local TILE_LABEL = 2.2
local TILE_SIZE = UDim2.fromScale(
	TILE_AUTHORED_TILE * TILE_AUTHORED_LABEL / TILE_LABEL,
	TILE_AUTHORED_TILE * TILE_AUTHORED_LABEL / TILE_LABEL
)
-- Seconds to slide one tile.
local TILE_SECONDS_PER_TILE = 2.5

local FONT_BOLD = Font.new("rbxasset://fonts/families/Montserrat.json", Enum.FontWeight.Bold)
local FONT_EXTRA_BOLD = Font.new("rbxasset://fonts/families/Montserrat.json", Enum.FontWeight.ExtraBold)

local TITLE_COLOR = Color3.fromRGB(255, 255, 255)
local TEXT_COLOR = Color3.fromRGB(235, 235, 235)
local TEXT_STROKE_COLOR = Color3.fromRGB(10, 10, 12)
local ICON_AREA_COLOR = Color3.fromRGB(14, 14, 18)
local PILL_TEXT_COLOR = Color3.fromRGB(7, 11, 15)

-- The name across the top: one line for a short name, two for a long
-- one. Anything longer than the reference string takes the tall box.
local TITLE_ONE_LINE_MAX_LENGTH = #"Regeneration Coilddd"
local TITLE_ONE_LINE_POSITION = UDim2.fromScale(0.492, 0.076)
local TITLE_ONE_LINE_SIZE = UDim2.fromScale(0.82, 0.061)
local TITLE_TWO_LINE_POSITION = UDim2.fromScale(0.488, 0.045)
local TITLE_TWO_LINE_SIZE = UDim2.fromScale(0.82, 0.136)

-- The rarity pill: authored widths per tier, a fit for the rest.
local PILL_WIDTHS: { [string]: number } = {
	[ItemRarity.Rare] = 0.239123,
	[ItemRarity.Epic] = 0.237693,
	[ItemRarity.Legendary] = 0.45186,
	[ItemRarity.Cursed] = 0.308248,
}
local PILL_WIDTH_BASE = 0.1
local PILL_WIDTH_PER_CHARACTER = 0.039

-- The selected look: SelectionUIStroke on the art (ScaledSize) while the
-- cursor is on the card; white on the card that was chosen.
local SELECTION_STROKE_COLOR = Color3.fromRGB(194, 232, 255)
local CHOSEN_STROKE_COLOR = Color3.fromRGB(255, 255, 255)
local SELECTION_STROKE_THICKNESS = 0.01
-- The art sits this much inside the CanvasGroup so the Border stroke
-- has room to draw without the group's bounds clipping it.
local ART_INSET = 0.975

-- The shadow behind the card (UIShadow, on the CanvasGroup so the group's
-- bounds never clip its blur). One steady, neutral dark shadow for every
-- tier; the tier colour lives in the card tint, the icon window and the
-- pick ring.
local CARD_SHADOW_COLOR = Color3.fromRGB(0, 0, 0)
local CARD_SHADOW_BLUR = UDim.new(0, 30)
local CARD_SHADOW_SPREAD = UDim2.fromOffset(3, 3)
local CARD_SHADOW_TRANSPARENCY = 0.4
-- The icon window's own shadow, steady.
local ICON_SHADOW_BLUR = UDim.new(0, 25)
local ICON_SHADOW_SPREAD = UDim2.fromOffset(6, 6)
local ICON_SHADOW_TRANSPARENCY = 0.5
-- The icon window's gradient: the tier colour at one corner running to
-- white, and opaque running to transparent, at 45 degrees.
local ICON_GRADIENT_ROTATION = 45
local ICON_GRADIENT_TRANSPARENCY = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0),
	NumberSequenceKeypoint.new(1, 1),
})

-- Hover: a soft lift (fraction of the card height) and the stroke.
local HOVER_LIFT = -0.02
local HOVER_TWEEN = TweenInfo.new(0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
-- The veil and the chosen stroke ease on a gentler curve than the lift.
local DIM_TWEEN = TweenInfo.new(0.45, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
local STROKE_TWEEN = TweenInfo.new(0.5, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
-- The unfocused veil: a black frame over the card, this opaque. The
-- card itself stays fully drawn underneath; only the veil moves.
local DIM_TRANSPARENCY = 0.45

-- The light sweep: a soft white streak crossing the card. Once as the
-- card lands (the Container), then on the card's own timer, every
-- SWEEP_PERIOD_MIN..MAX seconds while it is drawn.
local SWEEP_SECONDS = 0.9
local SWEEP_PERIOD_MIN_SECONDS = 5
local SWEEP_PERIOD_MAX_SECONDS = 8
local SWEEP_TRANSPARENCY = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 1),
	NumberSequenceKeypoint.new(0.42, 1),
	NumberSequenceKeypoint.new(0.5, 0.55),
	NumberSequenceKeypoint.new(0.58, 1),
	NumberSequenceKeypoint.new(1, 1),
})
local SWEEP_ROTATION = 35

-- The pick: a white flash over the card, and a ring in the tier colour
-- that grows out from the card's edge. Both short; the card's own hold and
-- rise carry the rest.
local FLASH_PEAK_TRANSPARENCY = 0.35
local FLASH_IN_TWEEN = TweenInfo.new(0.07, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
local FLASH_OUT_TWEEN = TweenInfo.new(0.4, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
-- The ring stays close to the card: a small growth on a gentle ease-out,
-- faded on an in-out curve so it melts away instead of cutting off.
local RING_END_SCALE = 1.18
local RING_START_THICKNESS = 3
local RING_TWEEN = TweenInfo.new(0.65, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local RING_FADE_TWEEN = TweenInfo.new(0.55, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)

-- Idle bob: a Sine there-and-back over this amplitude (fraction of the
-- card height) and period, each slot a beat behind the last.
-- Back easing: each leg overshoots its end a touch and settles, so the
-- float reads as a soft bounce rather than a pendulum.
local BOB_AMPLITUDE = 0.012
local BOB_SECONDS = 2.4
local BOB_PHASE_PER_CARD = 0.6
-- A near-zero rotation on the bob frame. Roblox snaps unrotated GUI to
-- whole pixels, so a few-pixel bob moves in visible one-pixel steps; any
-- rotation renders the subtree with sub-pixel placement instead.
local SUBPIXEL_ROTATION = 0.01

-- The orbit: glowing squares in the rarity colour circling just outside the
-- card's edge, behind it, spinning and pulsing. More for higher rarity.
-- They live in their own CanvasGroup (larger than the card, so it can hold
-- them) that fades with the card.
local ORBIT_COUNTS: { [string]: number } = {
	[ItemRarity.Rare] = 4,
	[ItemRarity.Epic] = 6,
	[ItemRarity.Legendary] = 8,
	[ItemRarity.Cursed] = 8,
}
local ORBIT_DEFAULT_COUNT = 4
-- The group's size relative to the card slot; the card fills the centre.
local ORBIT_GROUP_SCALE = 1.3
-- Path: the card's outline pushed out by this much (fraction of the card
-- width), with rounded corners of this radius (same unit).
local ORBIT_MARGIN = 0.035
local ORBIT_CORNER_RADIUS = 0.1
-- Seconds for one square to travel all the way round.
local ORBIT_LAP_SECONDS = 10
-- Square size (fraction of the card width), and its pulse.
local ORBIT_SQUARE_SIZE = 0.028
local ORBIT_PULSE_AMOUNT = 0.3
local ORBIT_PULSE_SPEED = 2.2
local ORBIT_SPIN_DEGREES_PER_SECOND = 90
local ORBIT_TRANSPARENCY_MIN = 0.1
local ORBIT_TRANSPARENCY_MAX = 0.45
local ORBIT_GLOW_BLUR = UDim.new(0, 8)
local ORBIT_GLOW_TRANSPARENCY = 0.35

-- Text caps so a 4K desktop does not blow the copy up with the card.
local TITLE_MAX_TEXT_SIZE = 22
local RARITY_MAX_TEXT_SIZE = 20
local DESCRIPTION_MAX_TEXT_SIZE = 15
-- Phones only (ScreenSizes.Mobile: touch, no mouse, a short viewport) pin
-- the title and description to one fixed size each. Tablets, PC and
-- console keep the scaled text above.
local PHONE_TITLE_TEXT_SIZE = 11
local PHONE_DESCRIPTION_TEXT_SIZE = 8

local localPlayer = Players.LocalPlayer

--[ Component ]--

-- Props:
--   relicName      the relic this card offers
--   index          1-based position in the hand (bob phase, layout order)
--   isPhone        true on a phone: fixed title / description sizes
--   onRegister     (relicName, handle | nil)
--   onHover        (relicName, on: boolean)
--   onActivated    (relicName)
local function OfferCard(props: any)
	local relicName: string = props.relicName
	local index: number = props.index or 1
	local isPhone: boolean = props.isPhone == true
	local relicInfo = RelicData[relicName]
	local rarity: string = relicInfo and relicInfo.rarity or ItemRarity.Common
	local colors = RarityColors:GetCard(rarity)
	local iconImage = relicInfo and relicInfo.icon or DEFAULT_ICON
	local cardImage = relicInfo and CARD_IMAGES[relicInfo.tree] or DEFAULT_CARD_IMAGE
	local cardTint = if rarity == ItemRarity.Cursed
		then CURSED_CARD_TINT
		else (relicInfo and CARD_TINTS[relicInfo.tree] or DEFAULT_CARD_TINT)

	local slotRef = React.useRef(nil)
	local groupRef = React.useRef(nil)
	local bobRef = React.useRef(nil)
	local offsetRef = React.useRef(nil)
	local liftRef = React.useRef(nil)
	local strokeRef = React.useRef(nil)
	local shadowRef = React.useRef(nil)
	local sweepRef = React.useRef(nil)
	local dimRef = React.useRef(nil)
	local flashRef = React.useRef(nil)
	local ringRef = React.useRef(nil)
	local tileRef = React.useRef(nil)
	local orbitRef = React.useRef(nil)
	local hoveredRef = React.useRef(false)

	local description = getRelicDescription(localPlayer, relicName) or ""
	local twoLineTitle = #relicName > TITLE_ONE_LINE_MAX_LENGTH
	local pillWidth = PILL_WIDTHS[rarity] or (PILL_WIDTH_BASE + PILL_WIDTH_PER_CHARACTER * #rarity)

	-- The handle: registered once the refs exist, withdrawn on unmount.
	React.useEffect(function()
		local group = groupRef.current
		local offsetFrame = offsetRef.current
		if not group or not offsetFrame then
			return nil
		end
		local alive = true

		local alpha = Instance.new("NumberValue")
		alpha.Value = 1

		local function applyAlpha(a: number)
			group.GroupTransparency = a
			local orbit = orbitRef.current
			if orbit then
				orbit.GroupTransparency = a
			end
			local shadow = shadowRef.current
			if shadow then
				shadow.Transparency = CARD_SHADOW_TRANSPARENCY + (1 - CARD_SHADOW_TRANSPARENCY) * a
			end
		end
		applyAlpha(1)
		local alphaConnection = alpha.Changed:Connect(applyAlpha)

		local function setScale(scale: number)
			group.Size = UDim2.fromScale(scale, scale)
		end

		local function tweenScale(scale: number, info: TweenInfo): Tween
			local tween = TweenService:Create(group, info, { Size = UDim2.fromScale(scale, scale) })
			tween:Play()
			return tween
		end

		local function setOffset(offset: UDim2)
			offsetFrame.Position = offset
		end

		local function tweenOffset(offset: UDim2, info: TweenInfo): Tween
			local tween = TweenService:Create(offsetFrame, info, { Position = offset })
			tween:Play()
			return tween
		end

		local function setHover(on: boolean)
			if hoveredRef.current == on then
				return
			end
			hoveredRef.current = on
			local lift = liftRef.current
			local stroke = strokeRef.current
			if lift then
				TweenService:Create(lift, HOVER_TWEEN, { Position = UDim2.fromScale(0, if on then HOVER_LIFT else 0) })
					:Play()
			end
			if stroke then
				TweenService:Create(stroke, STROKE_TWEEN, {
					Transparency = if on then 0 else 1,
					Color = SELECTION_STROKE_COLOR,
				}):Play()
			end
		end

		local function setDim(on: boolean)
			local dim = dimRef.current
			if dim then
				TweenService:Create(dim, DIM_TWEEN, { BackgroundTransparency = if on then DIM_TRANSPARENCY else 1 })
					:Play()
			end
		end

		local function brightenStroke()
			local stroke = strokeRef.current
			if stroke then
				TweenService:Create(stroke, STROKE_TWEEN, { Transparency = 0, Color = CHOSEN_STROKE_COLOR }):Play()
			end
		end

		-- The light sweep: the streak's gradient slides across once.
		local function sweep()
			local sweepFrame = sweepRef.current
			local gradient = sweepFrame and sweepFrame:FindFirstChildOfClass("UIGradient")
			if not sweepFrame or not gradient then
				return
			end
			gradient.Offset = Vector2.new(-1, 0)
			sweepFrame.Visible = true
			local tween = TweenService:Create(
				gradient,
				TweenInfo.new(SWEEP_SECONDS, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
				{ Offset = Vector2.new(1, 0) }
			)
			tween.Completed:Once(function()
				sweepFrame.Visible = false
			end)
			tween:Play()
		end

		-- The pick's flash: white in fast, out slow.
		local function flash()
			local flashFrame = flashRef.current
			if not flashFrame then
				return
			end
			flashFrame.BackgroundTransparency = 1
			local rise = TweenService:Create(flashFrame, FLASH_IN_TWEEN, {
				BackgroundTransparency = FLASH_PEAK_TRANSPARENCY,
			})
			rise.Completed:Once(function()
				TweenService:Create(flashFrame, FLASH_OUT_TWEEN, { BackgroundTransparency = 1 }):Play()
			end)
			rise:Play()
		end

		-- The pick's ring: grows from the card's edge while thinning and fading.
		-- It lives outside the card's CanvasGroup so it can grow past it.
		local function shockwave()
			local ring = ringRef.current
			local stroke = ring and ring:FindFirstChildOfClass("UIStroke")
			if not ring or not stroke then
				return
			end
			ring.Size = UDim2.fromScale(1, 1)
			ring.Visible = true
			stroke.Transparency = 0
			stroke.Thickness = RING_START_THICKNESS
			TweenService:Create(ring, RING_TWEEN, { Size = UDim2.fromScale(RING_END_SCALE, RING_END_SCALE) }):Play()
			-- Hidden once the fade has taken it fully transparent.
			local fade = TweenService:Create(stroke, RING_FADE_TWEEN, { Transparency = 1, Thickness = 1 })
			fade.Completed:Once(function()
				ring.Visible = false
			end)
			fade:Play()
		end

		-- The refused shake: a quick rotation wobble on the card itself.
		local function wobble()
			task.spawn(function()
				local step = TweenInfo.new(0.05, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
				for _, angle in { 5, -5, 3, -3, 0 } do
					local tween = TweenService:Create(group, step, { Rotation = angle })
					tween:Play()
					tween.Completed:Wait()
				end
			end)
		end

		local function slotCenter(): Vector2
			local slot = slotRef.current
			if not slot then
				return Vector2.zero
			end
			return slot.AbsolutePosition + slot.AbsoluteSize * 0.5
		end

		-- The idle bob: one looping there-and-back tween, forever. The
		-- per-slot phase is a delayed START, not the tween's DelayTime:
		-- TweenInfo repeats the delay before every repetition, which parked
		-- cards 2 and 3 at each end of the bob for a beat (a visible hitch).
		local bobTween: Tween? = nil
		local bob = bobRef.current
		if bob then
			bob.Position = UDim2.fromScale(0, -BOB_AMPLITUDE)
			local created = TweenService:Create(
				bob,
				TweenInfo.new(BOB_SECONDS, Enum.EasingStyle.Back, Enum.EasingDirection.InOut, -1, true),
				{ Position = UDim2.fromScale(0, BOB_AMPLITUDE) }
			)
			bobTween = created
			task.delay((index - 1) * BOB_PHASE_PER_CARD, function()
				if alive then
					created:Play()
				end
			end)
		end

		-- The tile scroll: the label slides one tile along its own x axis
		-- (rotated into the window's frame), forever, centred on the
		-- authored position so the slide never uncovers an edge.
		local tileTween: Tween? = nil
		local tile = tileRef.current
		if tile then
			local tileInWindow = TILE_SIZE.X.Scale * TILE_LABEL
			local radians = math.rad(TILE_ROTATION)
			local step = Vector2.new(math.cos(radians), math.sin(radians)) * tileInWindow
			local from = TILE_POSITION - step * 0.5
			local to = TILE_POSITION + step * 0.5
			tile.Position = UDim2.fromScale(from.X, from.Y)
			local created = TweenService:Create(
				tile,
				TweenInfo.new(TILE_SECONDS_PER_TILE, Enum.EasingStyle.Linear, Enum.EasingDirection.In, -1),
				{ Position = UDim2.fromScale(to.X, to.Y) }
			)
			created:Play()
			tileTween = created
		end

		-- The periodic shine: the card sweeps itself every few seconds,
		-- on its own random beat, only while it is actually on screen.
		task.spawn(function()
			while alive do
				task.wait(
					SWEEP_PERIOD_MIN_SECONDS + math.random() * (SWEEP_PERIOD_MAX_SECONDS - SWEEP_PERIOD_MIN_SECONDS)
				)
				if alive and alpha.Value < 0.5 then
					sweep()
				end
			end
		end)

		props.onRegister(relicName, {
			alpha = alpha,
			setScale = setScale,
			tweenScale = tweenScale,
			setOffset = setOffset,
			tweenOffset = tweenOffset,
			setHover = setHover,
			setDim = setDim,
			brightenStroke = brightenStroke,
			sweep = sweep,
			flash = flash,
			shockwave = shockwave,
			wobble = wobble,
			slotCenter = slotCenter,
			rarity = rarity,
		})

		return function()
			alive = false
			props.onRegister(relicName, nil)
			if bobTween then
				bobTween:Cancel()
			end
			if tileTween then
				tileTween:Cancel()
			end
			alphaConnection:Disconnect()
			alpha:Destroy()
		end
	end, {})

	-- The orbit: squares travel a rounded rectangle just outside the card,
	-- evenly spaced, each spinning and pulsing on its own phase. Positions
	-- are computed in pixels from the group's live size, so the speed is
	-- even along the straights and the corners on any card size.
	React.useEffect(function()
		local orbit = orbitRef.current
		if not orbit then
			return nil
		end
		local count = ORBIT_COUNTS[rarity] or ORBIT_DEFAULT_COUNT
		local squares = {}
		for i = 1, count do
			local square = Instance.new("Frame")
			square.Name = "OrbitSquare"
			square.AnchorPoint = Vector2.new(0.5, 0.5)
			square.BackgroundColor3 = colors.pill
			square.BorderSizePixel = 0
			square.Rotation = (i - 1) * 37
			local glow = Instance.new("UIShadow")
			glow.Color = colors.pill
			glow.BlurRadius = ORBIT_GLOW_BLUR
			glow.Transparency = ORBIT_GLOW_TRANSPARENCY
			glow.Parent = square
			square.Parent = orbit
			squares[i] = square
		end

		-- A rounded rectangle centred on (cx, cy) with half-extents (hw, hh)
		-- and corner radius r, as segments clockwise from the top edge's
		-- left end. Built once per frame, walked once per square.
		local function buildPath(cx: number, cy: number, hw: number, hh: number, r: number): { any }
			local straightX = 2 * (hw - r)
			local straightY = 2 * (hh - r)
			local arc = math.pi * r / 2
			local segments: { any } = {
				{
					kind = "line",
					length = straightX,
					from = Vector2.new(cx - hw + r, cy - hh),
					dir = Vector2.new(1, 0),
				},
				{ kind = "arc", length = arc, center = Vector2.new(cx + hw - r, cy - hh + r), start = -math.pi / 2 },
				{
					kind = "line",
					length = straightY,
					from = Vector2.new(cx + hw, cy - hh + r),
					dir = Vector2.new(0, 1),
				},
				{ kind = "arc", length = arc, center = Vector2.new(cx + hw - r, cy + hh - r), start = 0 },
				{
					kind = "line",
					length = straightX,
					from = Vector2.new(cx + hw - r, cy + hh),
					dir = Vector2.new(-1, 0),
				},
				{ kind = "arc", length = arc, center = Vector2.new(cx - hw + r, cy + hh - r), start = math.pi / 2 },
				{
					kind = "line",
					length = straightY,
					from = Vector2.new(cx - hw, cy + hh - r),
					dir = Vector2.new(0, -1),
				},
				{ kind = "arc", length = arc, center = Vector2.new(cx - hw + r, cy - hh + r), start = math.pi },
			}
			return segments
		end

		-- The point `s` pixels along `segments` (radius r for the arcs).
		local function pointOnPath(segments: { any }, s: number, r: number): Vector2
			for segmentIndex, segment in segments do
				if s <= segment.length or segmentIndex == #segments then
					if segment.kind == "line" then
						return segment.from + segment.dir * s
					end
					local angle = segment.start + (if r > 0 then s / r else 0)
					return segment.center + Vector2.new(math.cos(angle), math.sin(angle)) * r
				end
				s -= segment.length
			end
			return Vector2.zero
		end

		local clock = 0
		local connection = RunService.RenderStepped:Connect(function(deltaTime: number)
			clock += deltaTime
			local size = orbit.AbsoluteSize
			if size.X <= 0 or size.Y <= 0 then
				return
			end
			local cardWidth = size.X / ORBIT_GROUP_SCALE
			local cardHeight = size.Y / ORBIT_GROUP_SCALE
			local margin = cardWidth * ORBIT_MARGIN
			local hw = cardWidth / 2 + margin
			local hh = cardHeight / 2 + margin
			local r = math.min(cardWidth * ORBIT_CORNER_RADIUS + margin, hw, hh)
			local perimeter = 4 * (hw - r) + 4 * (hh - r) + 2 * math.pi * r
			local baseSize = cardWidth * ORBIT_SQUARE_SIZE
			local path = buildPath(size.X / 2, size.Y / 2, hw, hh, r)
			for i, square in squares do
				local progress = (clock / ORBIT_LAP_SECONDS + (i - 1) / count) % 1
				local point = pointOnPath(path, progress * perimeter, r)
				square.Position = UDim2.fromOffset(point.X, point.Y)
				local wave = math.sin(clock * ORBIT_PULSE_SPEED + i * 1.7)
				local side = baseSize * (1 + ORBIT_PULSE_AMOUNT * wave)
				square.Size = UDim2.fromOffset(side, side)
				square.BackgroundTransparency = ORBIT_TRANSPARENCY_MIN
					+ (ORBIT_TRANSPARENCY_MAX - ORBIT_TRANSPARENCY_MIN) * (0.5 - 0.5 * wave)
				square.Rotation += ORBIT_SPIN_DEGREES_PER_SECOND * deltaTime
			end
		end)
		return function()
			connection:Disconnect()
			for _, square in squares do
				square:Destroy()
			end
		end
	end, {})

	return React.createElement("Frame", {
		-- The SLOT: laid out by the row; its width follows its height.
		ref = slotRef,
		Name = relicName,
		LayoutOrder = index,
		Size = UDim2.fromScale(0, 1),
		BackgroundTransparency = 1,
	}, {
		UIAspectRatioConstraint = React.createElement("UIAspectRatioConstraint", {
			AspectRatio = 0.68,
			AspectType = Enum.AspectType.ScaleWithParentSize,
			DominantAxis = Enum.DominantAxis.Height,
		}),

		Bob = React.createElement("Frame", {
			ref = bobRef,
			Size = UDim2.fromScale(1, 1),
			Rotation = SUBPIXEL_ROTATION,
			BackgroundTransparency = 1,
		}, {
			Offset = React.createElement("Frame", {
				ref = offsetRef,
				Size = UDim2.fromScale(1, 1),
				BackgroundTransparency = 1,
			}, {
				Lift = React.createElement("Frame", {
					ref = liftRef,
					Size = UDim2.fromScale(1, 1),
					BackgroundTransparency = 1,
				}, {
					-- The orbiting squares, behind the card (see the orbit
					-- effect). Larger than the card so the squares fit.
					Orbit = React.createElement("CanvasGroup", {
						ref = orbitRef,
						AnchorPoint = Vector2.new(0.5, 0.5),
						Position = UDim2.fromScale(0.5, 0.5),
						Size = UDim2.fromScale(ORBIT_GROUP_SCALE, ORBIT_GROUP_SCALE),
						BackgroundTransparency = 1,
						GroupTransparency = 1,
						ZIndex = 0,
					}),

					-- The pick's shockwave ring (see shockwave()). Outside the
					-- card's CanvasGroup, whose bounds would clip it.
					Ring = React.createElement("Frame", {
						ref = ringRef,
						AnchorPoint = Vector2.new(0.5, 0.5),
						Position = UDim2.fromScale(0.5, 0.5),
						Size = UDim2.fromScale(1, 1),
						BackgroundTransparency = 1,
						Visible = false,
						ZIndex = 6,
					}, {
						UICorner = React.createElement("UICorner", {
							CornerRadius = UDim.new(0.07, 0),
						}),
						UIStroke = React.createElement("UIStroke", {
							ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
							Color = colors.shadow,
							Thickness = RING_START_THICKNESS,
							Transparency = 1,
						}),
					}),
					-- The card proper. A CanvasGroup: scale tweens run on it
					-- and GroupTransparency fades every descendant as one.
					Card = React.createElement("CanvasGroup", {
						ref = groupRef,
						AnchorPoint = Vector2.new(0.5, 0.5),
						Position = UDim2.fromScale(0.5, 0.5),
						Size = UDim2.fromScale(1, 1),
						BackgroundTransparency = 1,
						GroupTransparency = 1,
					}, {
						UIShadow = React.createElement("UIShadow", {
							ref = shadowRef,
							Color = CARD_SHADOW_COLOR,
							BlurRadius = CARD_SHADOW_BLUR,
							Spread = CARD_SHADOW_SPREAD,
							Transparency = 1,
						}),

						Art = React.createElement("ImageButton", {
							AnchorPoint = Vector2.new(0.5, 0.5),
							Position = UDim2.fromScale(0.5, 0.5),
							Size = UDim2.fromScale(ART_INSET, ART_INSET),
							BackgroundTransparency = 1,
							Image = cardImage,
							ImageColor3 = cardTint,
							ScaleType = Enum.ScaleType.Stretch,
							AutoButtonColor = false,

							[React.Event.MouseEnter] = function()
								props.onHover(relicName, true)
							end,
							[React.Event.MouseLeave] = function()
								props.onHover(relicName, false)
							end,
							[React.Event.Activated] = function()
								props.onActivated(relicName)
							end,
						}, {
							UICorner = React.createElement("UICorner", {
								CornerRadius = UDim.new(0.07, 0),
							}),

							SelectionUIStroke = React.createElement("UIStroke", {
								ref = strokeRef,
								ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
								Color = SELECTION_STROKE_COLOR,
								StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize,
								Thickness = SELECTION_STROKE_THICKNESS,
								Transparency = 1,
							}),

							Title = React.createElement("TextLabel", {
								AnchorPoint = Vector2.new(0.5, 0),
								Position = if twoLineTitle then TITLE_TWO_LINE_POSITION else TITLE_ONE_LINE_POSITION,
								Size = if twoLineTitle then TITLE_TWO_LINE_SIZE else TITLE_ONE_LINE_SIZE,
								BackgroundTransparency = 1,
								Text = relicName,
								TextColor3 = TITLE_COLOR,
								TextStrokeColor3 = TEXT_STROKE_COLOR,
								TextStrokeTransparency = 0.5,
								FontFace = FONT_EXTRA_BOLD,
								TextScaled = true,
								TextWrapped = true,
								ZIndex = 3,
							}, {
								UITextSizeConstraint = React.createElement("UITextSizeConstraint", {
									MaxTextSize = if isPhone then PHONE_TITLE_TEXT_SIZE else TITLE_MAX_TEXT_SIZE,
									MinTextSize = if isPhone then PHONE_TITLE_TEXT_SIZE else 1,
								}),
							}),

							-- The icon window: a square CanvasGroup tinted by its
							-- gradient (tier colour to white, opaque to clear) so
							-- the tilted tile pattern clips to its rounded rect and
							-- fades with it.
							IconArea = React.createElement("CanvasGroup", {
								AnchorPoint = Vector2.new(0.5, 0),
								Position = UDim2.fromScale(0.5, 0.217),
								Size = UDim2.fromScale(0.552, 0.407),
								BackgroundColor3 = ICON_AREA_COLOR,
								BackgroundTransparency = 0.25,
								ZIndex = 2,
							}, {
								UIAspectRatioConstraint = React.createElement("UIAspectRatioConstraint"),
								UICorner = React.createElement("UICorner", {
									CornerRadius = UDim.new(0.08, 0),
								}),
								UIStroke = React.createElement("UIStroke", {
									ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
									Color = colors.iconStroke,
									StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize,
									Thickness = 0.014,
								}),
								UIShadow = React.createElement("UIShadow", {
									Color = colors.iconShadow,
									BlurRadius = ICON_SHADOW_BLUR,
									Spread = ICON_SHADOW_SPREAD,
									Transparency = ICON_SHADOW_TRANSPARENCY,
								}),
								UIGradient = React.createElement("UIGradient", {
									Color = ColorSequence.new({
										ColorSequenceKeypoint.new(0, colors.gradient),
										ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 255, 255)),
									}),
									Rotation = ICON_GRADIENT_ROTATION,
									Transparency = ICON_GRADIENT_TRANSPARENCY,
								}),
								TiledImage = React.createElement("ImageLabel", {
									ref = tileRef,
									AnchorPoint = Vector2.new(0.5, 0.5),
									Position = UDim2.fromScale(TILE_POSITION.X, TILE_POSITION.Y),
									Size = UDim2.fromScale(TILE_LABEL, TILE_LABEL),
									Rotation = TILE_ROTATION,
									BackgroundTransparency = 1,
									Image = TILE_IMAGE,
									ImageColor3 = TILE_COLOR,
									ImageTransparency = TILE_TRANSPARENCY,
									ResampleMode = Enum.ResamplerMode.Pixelated,
									ScaleType = Enum.ScaleType.Tile,
									TileSize = TILE_SIZE,
									ZIndex = 3,
								}),
							}),

							-- The relic icon floats over the window, on the card.
							Icon = React.createElement("ImageLabel", {
								AnchorPoint = Vector2.new(0.5, 0.5),
								Position = UDim2.fromScale(0.499079, 0.405262),
								Size = UDim2.fromScale(0.486, 0.311),
								BackgroundTransparency = 1,
								Image = iconImage,
								ScaleType = Enum.ScaleType.Fit,
								ZIndex = 3,
							}, {
								UIAspectRatioConstraint = React.createElement("UIAspectRatioConstraint"),
							}),

							-- The rarity pill: tier fill, near-black text.
							Rarity = React.createElement("TextLabel", {
								AnchorPoint = Vector2.new(0.5, 0),
								Position = UDim2.fromScale(0.5, 0.645),
								Size = UDim2.fromScale(pillWidth, 0.0634),
								BackgroundColor3 = colors.pill,
								BorderSizePixel = 0,
								Text = rarity,
								TextColor3 = PILL_TEXT_COLOR,
								TextStrokeColor3 = TEXT_STROKE_COLOR,
								FontFace = FONT_BOLD,
								TextScaled = true,
								ZIndex = 3,
							}, {
								UITextSizeConstraint = React.createElement("UITextSizeConstraint", {
									MaxTextSize = RARITY_MAX_TEXT_SIZE,
								}),
								UICorner = React.createElement("UICorner", {
									CornerRadius = UDim.new(0.1, 0),
								}),
								UIPadding = React.createElement("UIPadding", {
									PaddingTop = UDim.new(0.1, 0),
									PaddingBottom = UDim.new(0.1, 0),
								}),
							}),

							Description = React.createElement("TextLabel", {
								AnchorPoint = Vector2.new(0.5, 0),
								Position = UDim2.fromScale(0.5, 0.735),
								Size = UDim2.fromScale(0.741272, 0.220031),
								BackgroundTransparency = 1,
								Text = description,
								RichText = true,
								TextColor3 = TEXT_COLOR,
								TextStrokeColor3 = TEXT_STROKE_COLOR,
								TextStrokeTransparency = 0.5,
								FontFace = FONT_BOLD,
								TextScaled = true,
								TextWrapped = true,
								TextYAlignment = Enum.TextYAlignment.Top,
								ZIndex = 3,
							}, {
								UITextSizeConstraint = React.createElement("UITextSizeConstraint", {
									MaxTextSize = if isPhone
										then PHONE_DESCRIPTION_TEXT_SIZE
										else DESCRIPTION_MAX_TEXT_SIZE,
									MinTextSize = if isPhone then PHONE_DESCRIPTION_TEXT_SIZE else 1,
								}),
							}),

							-- The pick's white flash, above the card's contents.
							Flash = React.createElement("Frame", {
								ref = flashRef,
								Size = UDim2.fromScale(1, 1),
								BackgroundColor3 = Color3.fromRGB(255, 255, 255),
								BackgroundTransparency = 1,
								BorderSizePixel = 0,
								ZIndex = 4,
							}, {
								UICorner = React.createElement("UICorner", {
									CornerRadius = UDim.new(0.07, 0),
								}),
							}),

							-- The unfocused veil, above everything but the sweep.
							Dim = React.createElement("Frame", {
								ref = dimRef,
								Size = UDim2.fromScale(1, 1),
								BackgroundColor3 = Color3.fromRGB(0, 0, 0),
								BackgroundTransparency = 1,
								BorderSizePixel = 0,
								ZIndex = 4,
							}, {
								UICorner = React.createElement("UICorner", {
									CornerRadius = UDim.new(0.07, 0),
								}),
							}),

							-- The light sweep: a white frame whose gradient is
							-- transparent except for one soft band, slid across
							-- by handle.sweep(). Above everything on the card.
							Sweep = React.createElement("Frame", {
								ref = sweepRef,
								Size = UDim2.fromScale(1, 1),
								BackgroundColor3 = Color3.fromRGB(255, 255, 255),
								BorderSizePixel = 0,
								Visible = false,
								ZIndex = 5,
							}, {
								UICorner = React.createElement("UICorner", {
									CornerRadius = UDim.new(0.07, 0),
								}),
								UIGradient = React.createElement("UIGradient", {
									Rotation = SWEEP_ROTATION,
									Transparency = SWEEP_TRANSPARENCY,
									Offset = Vector2.new(-1, 0),
								}),
							}),
						}),
					}),
				}),
			}),
		}),
	})
end

return OfferCard
