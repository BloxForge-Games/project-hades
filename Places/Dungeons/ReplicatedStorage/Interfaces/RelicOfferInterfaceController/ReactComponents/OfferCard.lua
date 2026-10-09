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
	  handle.setHover(on)       the selected look: lift + SelectionUIStroke,
	                            and slides the keyword tooltips out past
	                            the card's right edge.
	  handle.setDim(on)         a black veil over the card (the unfocused
	                            look while another card is hovered).
	  handle.brightenStroke()   the chosen card's stroke goes fully opaque.
	  handle.sweep()            a light streak crosses the card once.
	  handle.flash()            the pick: the card flashes white for a beat.
	  handle.shockwave()        the pick: a ring in the element colour expands
	                            from the card's edge and fades.
	  handle.wobble()           the refused shake.
	  handle.setDim(on) also fades this card's embers (see below).
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
local getRelicKeywords = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Relic.getRelicKeywords)
local KeywordData = require(ReplicatedStorage.Submodules.Core.Shared.Data.KeywordData)

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
	[ElementTrees.Earth] = "rbxassetid://104765754040829",
	[ElementTrees.Neutral] = "rbxassetid://130599641461508",
}
local DEFAULT_CARD_IMAGE = CARD_IMAGES[ElementTrees.Neutral]
-- The card art's ImageColor3, by element tree. A Cursed relic (every one
-- sits in Neutral) takes CURSED_CARD_TINT instead.
local CARD_TINTS: { [string]: Color3 } = {
	[ElementTrees.Blaze] = Color3.fromRGB(255, 102, 0),
	[ElementTrees.Frost] = Color3.fromRGB(126, 253, 255),
	[ElementTrees.Storm] = Color3.fromRGB(255, 85, 255),
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
-- cursor is on the card, in the relic's ELEMENT tint (cardTint, the same
-- tint the card art and the embers wear), so hovering reads as "this
-- element" rather than one shared highlight for every card. The chosen
-- card holds that same tint -- the pick is marked by the shockwave ring
-- and the stroke staying lit, never by a colour change.
-- Lit strokes stop HALF transparent rather than solid: at full opacity a
-- saturated element tint flares on the card edge. Hover, the chosen card
-- and the shockwave ring all start here, so the three read as one effect.
local LIT_STROKE_TRANSPARENCY = 0.5
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
-- Deeper than it needs to be for focus alone: the hovered card's keyword
-- tooltips extend over its neighbour, and the veil is what keeps that
-- card's art and embers from competing with the tooltip text.
local DIM_TRANSPARENCY = 0.3

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

-- The embers: small sparks in the relic's ELEMENT colour (cardTint, the
-- same tint the card art wears) drifting UP around the card,
-- swaying as they rise and shimmering on their own phase, like the lazy
-- top of a fire. Most sit BEHIND the card; a few pass in FRONT of it,
-- smaller and fainter, which is what sells the card as being inside the
-- effect rather than pasted on top of it.
--
-- Every card's embers are posed by ONE shared Heartbeat (see the driver
-- below), the same way DropFloatController poses every floating pickup --
-- three cards must not mean three connections.
local EMBER_BACK_COUNT = 8
local EMBER_FRONT_COUNT = 4
-- The field the embers travel, relative to the card. Wider and taller than
-- the card so they drift past its edges instead of stopping at them.
local EMBER_FIELD_WIDTH = 1.32
local EMBER_FIELD_HEIGHT = 1.28
-- Seconds for one ember to cross the field bottom to top. Randomised per
-- ember inside this range -- slow, so the effect reads as drift, not rain.
local EMBER_RISE_SECONDS_MIN = 6
local EMBER_RISE_SECONDS_MAX = 9.5
-- The sway as it rises: amplitude in field-widths, and how fast it weaves.
local EMBER_SWAY_MIN = 0.02
local EMBER_SWAY_MAX = 0.055
local EMBER_SWAY_SPEED_MIN = 0.25
local EMBER_SWAY_SPEED_MAX = 0.7
-- Ember size as a fraction of the field. Scale on BOTH axes against a
-- taller-than-wide field gives a slightly vertical spark, which is the
-- shape a rising ember should have -- so no aspect constraint per ember.
local EMBER_SIZE_MIN = 0.013
local EMBER_SIZE_MAX = 0.025
-- Front embers are smaller and fainter than the ones behind: that size and
-- opacity gap is the whole depth cue.
local EMBER_FRONT_SIZE_SCALE = 0.75
local EMBER_FRONT_OPACITY_SCALE = 0.75
-- Peak opacity, and the shimmer that rides on top of it. The shimmer
-- never swings to zero -- it dips to the FLOOR and back, so an ember
-- pulses rather than blinking out, and the field keeps its brightness
-- instead of averaging half of it away.
local EMBER_OPACITY_MIN = 0.55
local EMBER_OPACITY_MAX = 0.8
local EMBER_SHIMMER_FLOOR = 0.55
local EMBER_SHIMMER_SPEED_MIN = 1.4
local EMBER_SHIMMER_SPEED_MAX = 3.2
-- Fractions of the rise spent fading in at the bottom and out at the top,
-- so embers never pop into or out of existence.
local EMBER_FADE_IN = 0.18
local EMBER_FADE_OUT = 0.3
-- While ANOTHER card is hovered, this card's embers fade to here. The
-- hovered card's embers are left alone.
local EMBER_DIM_TRANSPARENCY = 0.5

-- Text caps so a 4K desktop does not blow the copy up with the card.
local TITLE_MAX_TEXT_SIZE = 22
local RARITY_MAX_TEXT_SIZE = 20
local DESCRIPTION_MAX_TEXT_SIZE = 15
-- Phones only (ScreenSizes.Mobile: touch, no mouse, a short viewport) pin
-- the title and description to one fixed size each. Tablets, PC and
-- console keep the scaled text above.
local PHONE_TITLE_TEXT_SIZE = 11
local PHONE_DESCRIPTION_TEXT_SIZE = 8

-- The KEYWORD TOOLTIPS: one plate per hoverable keyword in the card's
-- description (getRelicKeywords), stacked in a UIListLayout column that
-- slides out past the card's right edge on hover.
--
-- Always to the RIGHT, on every card, because a tooltip that switches
-- sides is a tooltip the player has to look for. On cards 1 and 2 the
-- column lands over the neighbouring card, which is why the hovered
-- card raises its SLOT's ZIndex (the row draws slots in order, so a
-- tooltip buried in slot 1 would otherwise be painted over by slot 2)
-- and why the other cards take a deeper veil while a card is hovered
-- (DIM_TRANSPARENCY in Container).
--
-- Sizes are fractions of the CARD, so the column scales with the card
-- on every viewport rather than needing its own platform cases. No
-- AutomaticSize anywhere: the plate heights are fixed and the text is
-- TextScaled inside them, exactly like the card's own title and
-- description, which keeps the column's height deterministic.
local TOOLTIP_WIDTH = 0.82
local TOOLTIP_GAP = 0.04
local TOOLTIP_ROW_HEIGHT = 0.17
local TOOLTIP_ROW_GAP = 0.028
-- A dark plate per row, not bare text: the column sits over card art and
-- ember particles, and unplated text is unreadable against the brighter
-- element tints (Frost's 126,253,255, Earth's 255,183,0).
local TOOLTIP_PLATE_COLOR = Color3.fromRGB(10, 10, 14)
local TOOLTIP_PLATE_TRANSPARENCY = 0.18
local TOOLTIP_PLATE_PADDING = 0.055
local TOOLTIP_TEXT_STROKE_TRANSPARENCY = 0.4
local TOOLTIP_MAX_TEXT_SIZE = 13
local PHONE_TOOLTIP_TEXT_SIZE = 8
-- Each plate starts tucked back toward the card and slides out to 0, so
-- the column reads as coming OUT of the card rather than appearing beside
-- it. Fraction of the plate's own width.
local TOOLTIP_SLIDE_FROM = -0.22
-- Plates arrive one after another rather than together.
local TOOLTIP_STAGGER = 0.06
local TOOLTIP_IN_TWEEN = TweenInfo.new(0.3, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local TOOLTIP_OUT_TWEEN = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
-- Above the front embers (ZIndex 7) within the card, and the slot ZIndex
-- the hovered card claims so its column clears the next card entirely.
local TOOLTIP_ZINDEX = 8
local HOVERED_SLOT_ZINDEX = 2

-- The keyword name is drawn in the same blue the card writes it in, so a
-- player maps the plate to the word that opened it.
local KEYWORD_TITLE_COLOR = string.format(
	"rgb(%d,%d,%d)",
	math.round(KeywordData.Color.R * 255),
	math.round(KeywordData.Color.G * 255),
	math.round(KeywordData.Color.B * 255)
)

-- ONE Heartbeat for every card's embers on this client. Cards register
-- their field here on mount and withdraw on unmount; the connection opens
-- with the first card and closes with the last, so an unmounted hand costs
-- nothing. Poses are written from each ember's OWN parameters against a
-- shared clock -- never accumulated frame over frame, so a dropped frame
-- can never drift the field out of its band.
local emberFields: { [any]: any } = {}
local emberConnection: RBXScriptConnection? = nil
local emberClock = 0

local function stepEmbers(deltaTime: number)
	emberClock += deltaTime
	for _, field in emberFields do
		for _, ember in field do
			-- 1 at the bottom of the field, 0 at the top.
			local progress = (emberClock / ember.riseSeconds + ember.offset) % 1
			local height = 1 - progress
			local drift = math.sin(emberClock * ember.swaySpeed + ember.phase) * ember.sway
			ember.frame.Position = UDim2.fromScale(ember.x + drift, height)

			-- Fade in off the bottom, out into the top.
			local entering = math.min(progress / EMBER_FADE_IN, 1)
			local leaving = math.min((1 - progress) / EMBER_FADE_OUT, 1)
			local wave = 0.5 + 0.5 * math.sin(emberClock * ember.shimmerSpeed + ember.phase)
			local shimmer = EMBER_SHIMMER_FLOOR + (1 - EMBER_SHIMMER_FLOOR) * wave
			local opacity = ember.opacity * entering * leaving * shimmer
			ember.frame.BackgroundTransparency = 1 - opacity
		end
	end
end

local function registerEmberField(key: any, embers: any)
	emberFields[key] = embers
	if not emberConnection then
		emberConnection = RunService.Heartbeat:Connect(stepEmbers)
	end
end

local function unregisterEmberField(key: any)
	emberFields[key] = nil
	if next(emberFields) == nil and emberConnection then
		emberConnection:Disconnect()
		emberConnection = nil
	end
end

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
	local tooltipRef = React.useRef(nil)
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
	local hoveredRef = React.useRef(false)
	local embersBackRef = React.useRef(nil)
	local embersFrontRef = React.useRef(nil)

	local description = getRelicDescription(localPlayer, relicName) or ""
	-- The card's hoverable keywords, read off the DESCRIPTION so the
	-- runtime-callback relics (Super Stomp Boots and friends) are covered
	-- too. Max 2 on any card today, but nothing here assumes a count.
	local keywords = getRelicKeywords(description)
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

		-- The embers answer to TWO independent fades: the card's own alpha
		-- (the deal in, the sink, the rise) and the hover dim (another card
		-- is focused). Whichever is hiding them more wins, so neither can
		-- undo the other -- a card sinking while a sibling is hovered stays
		-- gone rather than popping back to half.
		local embersDim = Instance.new("NumberValue")
		embersDim.Value = 0

		local function applyEmberAlpha()
			local hidden = math.max(alpha.Value, embersDim.Value)
			local back = embersBackRef.current
			if back then
				back.GroupTransparency = hidden
			end
			local front = embersFrontRef.current
			if front then
				front.GroupTransparency = hidden
			end
		end

		local function applyAlpha(a: number)
			group.GroupTransparency = a
			local shadow = shadowRef.current
			if shadow then
				shadow.Transparency = CARD_SHADOW_TRANSPARENCY + (1 - CARD_SHADOW_TRANSPARENCY) * a
			end
			applyEmberAlpha()
		end
		applyAlpha(1)
		local alphaConnection = alpha.Changed:Connect(applyAlpha)
		local embersDimConnection = embersDim.Changed:Connect(applyEmberAlpha)

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

		-- The keyword column. The plates are built by the renderer; this
		-- only poses them, so a card with no hoverable keywords has no
		-- Tooltip frame and every call here no-ops.
		--
		-- Each plate slides out and fades in on its own delay. The
		-- generation counter is what makes a fast hover-on-hover-off safe:
		-- a staggered step from an earlier pass finds its generation stale
		-- and does nothing, so an outgoing column can never be re-faded in
		-- by a delay left over from the incoming one.
		local tooltipGeneration = 0
		local function setTooltip(on: boolean)
			local tooltip = tooltipRef.current
			if not tooltip then
				return
			end

			tooltipGeneration += 1
			local generation = tooltipGeneration
			local info = if on then TOOLTIP_IN_TWEEN else TOOLTIP_OUT_TWEEN

			if on then
				tooltip.Visible = true
			end

			-- The UIListLayout is a child too, and a UILayout has no
			-- LayoutOrder -- sorting the raw GetChildren would throw on it.
			local rows: { GuiObject } = {}
			for _, child in tooltip:GetChildren() do
				if child:IsA("GuiObject") then
					table.insert(rows, child)
				end
			end
			-- GetChildren is unordered; LayoutOrder is the authored order.
			table.sort(rows, function(a: GuiObject, b: GuiObject)
				return a.LayoutOrder < b.LayoutOrder
			end)

			local lastTween: Tween? = nil
			local step = 0
			for _, row in rows do
				local plate = row:FindFirstChild("Plate")
				local label = plate and plate:FindFirstChild("Label")
				if not plate or not label then
					continue
				end

				local function pose()
					if not alive or generation ~= tooltipGeneration then
						return
					end
					TweenService:Create(plate, info, {
						Position = UDim2.fromScale(if on then 0 else TOOLTIP_SLIDE_FROM, 0),
						BackgroundTransparency = if on then TOOLTIP_PLATE_TRANSPARENCY else 1,
					}):Play()
					lastTween = TweenService:Create(label, info, {
						TextTransparency = if on then 0 else 1,
						TextStrokeTransparency = if on then TOOLTIP_TEXT_STROKE_TRANSPARENCY else 1,
					})
					lastTween:Play()
				end

				-- Only the arrival staggers. Leaving all at once stops the
				-- column lingering after the cursor has gone.
				if on and step > 0 then
					task.delay(step * TOOLTIP_STAGGER, pose)
				else
					pose()
				end
				step += 1
			end

			-- Hidden only once the last plate has actually faded, so the
			-- column is never cut off mid-tween.
			if not on and lastTween then
				lastTween.Completed:Once(function()
					if generation == tooltipGeneration then
						tooltip.Visible = false
					end
				end)
			end
		end

		local function setHover(on: boolean)
			if hoveredRef.current == on then
				return
			end
			hoveredRef.current = on
			setTooltip(on)
			local lift = liftRef.current
			local stroke = strokeRef.current
			-- Claim the row's top slot while hovered so this card's tooltip
			-- column draws over the neighbouring card instead of under it.
			local slot = slotRef.current
			if slot then
				slot.ZIndex = if on then HOVERED_SLOT_ZINDEX else 1
			end
			if lift then
				TweenService:Create(lift, HOVER_TWEEN, { Position = UDim2.fromScale(0, if on then HOVER_LIFT else 0) })
					:Play()
			end
			if stroke then
				TweenService:Create(stroke, STROKE_TWEEN, {
					Transparency = if on then LIT_STROKE_TRANSPARENCY else 1,
					Color = cardTint,
				}):Play()
			end
		end

		local function setDim(on: boolean)
			local dim = dimRef.current
			if dim then
				TweenService:Create(dim, DIM_TWEEN, { BackgroundTransparency = if on then DIM_TRANSPARENCY else 1 })
					:Play()
			end
			-- The embers dim with the card. The HOVERED card never gets
			-- setDim(true), so its embers stay at full.
			TweenService:Create(embersDim, DIM_TWEEN, {
				Value = if on then EMBER_DIM_TRANSPARENCY else 0,
			}):Play()
		end

		local function brightenStroke()
			local stroke = strokeRef.current
			if stroke then
				TweenService:Create(stroke, STROKE_TWEEN, {
					Transparency = LIT_STROKE_TRANSPARENCY,
					Color = cardTint,
				}):Play()
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
			stroke.Transparency = LIT_STROKE_TRANSPARENCY
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

		-- The ember field. Built once: every ember gets its own lane, rise
		-- time, sway and shimmer from a per-card seeded Random, so the three
		-- cards in a hand never drift in lockstep but a given card looks the
		-- same every time it is dealt.
		local embers = {}
		local emberRandom = Random.new(#relicName * 7919 + index * 104729)

		local function buildEmbers(layer: Instance?, count: number, isFront: boolean)
			if not layer then
				return
			end
			for _ = 1, count do
				local size = emberRandom:NextNumber(EMBER_SIZE_MIN, EMBER_SIZE_MAX)
					* (if isFront then EMBER_FRONT_SIZE_SCALE else 1)

				local frame = Instance.new("Frame")
				frame.Name = "Ember"
				frame.AnchorPoint = Vector2.new(0.5, 0.5)
				frame.BackgroundColor3 = cardTint
				frame.BorderSizePixel = 0
				frame.Size = UDim2.fromScale(size, size)
				frame.BackgroundTransparency = 1

				local corner = Instance.new("UICorner")
				corner.CornerRadius = UDim.new(1, 0)
				corner.Parent = frame

				frame.Parent = layer

				table.insert(embers, {
					frame = frame,
					x = emberRandom:NextNumber(0.08, 0.92),
					sway = emberRandom:NextNumber(EMBER_SWAY_MIN, EMBER_SWAY_MAX),
					swaySpeed = emberRandom:NextNumber(EMBER_SWAY_SPEED_MIN, EMBER_SWAY_SPEED_MAX),
					riseSeconds = emberRandom:NextNumber(EMBER_RISE_SECONDS_MIN, EMBER_RISE_SECONDS_MAX),
					shimmerSpeed = emberRandom:NextNumber(EMBER_SHIMMER_SPEED_MIN, EMBER_SHIMMER_SPEED_MAX),
					phase = emberRandom:NextNumber(0, math.pi * 2),
					-- Staggered start, so the field is already populated on
					-- the first frame instead of filling from the bottom.
					offset = emberRandom:NextNumber(0, 1),
					opacity = emberRandom:NextNumber(EMBER_OPACITY_MIN, EMBER_OPACITY_MAX)
						* (if isFront then EMBER_FRONT_OPACITY_SCALE else 1),
				})
			end
		end

		buildEmbers(embersBackRef.current, EMBER_BACK_COUNT, false)
		buildEmbers(embersFrontRef.current, EMBER_FRONT_COUNT, true)
		applyEmberAlpha()
		registerEmberField(embers, embers)

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
			unregisterEmberField(embers)
			embersDimConnection:Disconnect()
			embersDim:Destroy()
			for _, ember in embers do
				ember.frame:Destroy()
			end
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

	-- The keyword column, built only when the card HAS hoverable keywords
	-- (a card with none gets no Tooltip frame at all). setTooltip finds the plates by name rather than through refs,
	-- so the shape below is the contract: Row* -> Plate -> Label.
	local tooltip = nil
	if #keywords > 0 then
		-- Fixed plate heights make the column's height deterministic,
		-- which is what lets it centre on the card: the rows and the
		-- layout padding are expressed as fractions of that total.
		local columnHeight = #keywords * TOOLTIP_ROW_HEIGHT + (#keywords - 1) * TOOLTIP_ROW_GAP

		local rows: { [string]: any } = {
			UIListLayout = React.createElement("UIListLayout", {
				FillDirection = Enum.FillDirection.Vertical,
				SortOrder = Enum.SortOrder.LayoutOrder,
				Padding = UDim.new(TOOLTIP_ROW_GAP / columnHeight, 0),
			}),
		}

		for keywordIndex, entry in keywords do
			rows["Row" .. keywordIndex] = React.createElement("Frame", {
				-- The row is the LIST's child, so its position belongs to
				-- the layout. The plate inside it is what slides, which is
				-- how each plate gets its own arrival without fighting the
				-- UIListLayout for Position.
				LayoutOrder = keywordIndex,
				Size = UDim2.fromScale(1, TOOLTIP_ROW_HEIGHT / columnHeight),
				BackgroundTransparency = 1,
			}, {
				Plate = React.createElement("Frame", {
					Name = "Plate",
					Position = UDim2.fromScale(TOOLTIP_SLIDE_FROM, 0),
					Size = UDim2.fromScale(1, 1),
					BackgroundColor3 = TOOLTIP_PLATE_COLOR,
					BackgroundTransparency = 1,
					BorderSizePixel = 0,
				}, {
					UICorner = React.createElement("UICorner", {
						CornerRadius = UDim.new(0.18, 0),
					}),

					UIPadding = React.createElement("UIPadding", {
						PaddingTop = UDim.new(TOOLTIP_PLATE_PADDING, 0),
						PaddingBottom = UDim.new(TOOLTIP_PLATE_PADDING, 0),
						PaddingLeft = UDim.new(TOOLTIP_PLATE_PADDING, 0),
						PaddingRight = UDim.new(TOOLTIP_PLATE_PADDING, 0),
					}),

					Label = React.createElement("TextLabel", {
						Name = "Label",
						Size = UDim2.fromScale(1, 1),
						BackgroundTransparency = 1,
						-- The keyword in the blue the card wrote it in, so
						-- the player maps the plate to the word.
						Text = string.format(
							'<b><font color="%s">%s:</font></b> %s',
							KEYWORD_TITLE_COLOR,
							entry.keyword,
							entry.definition
						),
						RichText = true,
						TextColor3 = TEXT_COLOR,
						TextStrokeColor3 = TEXT_STROKE_COLOR,
						TextTransparency = 1,
						TextStrokeTransparency = 1,
						FontFace = FONT_BOLD,
						TextScaled = true,
						TextWrapped = true,
						TextXAlignment = Enum.TextXAlignment.Left,
					}, {
						UITextSizeConstraint = React.createElement("UITextSizeConstraint", {
							MaxTextSize = if isPhone then PHONE_TOOLTIP_TEXT_SIZE else TOOLTIP_MAX_TEXT_SIZE,
							MinTextSize = if isPhone then PHONE_TOOLTIP_TEXT_SIZE else 1,
						}),
					}),
				}),
			})
		end

		tooltip = React.createElement("Frame", {
			ref = tooltipRef,
			-- Hung off the card's right edge and centred on it. Hidden
			-- until setTooltip raises it, so a never-hovered card costs
			-- nothing to draw.
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.fromScale(1 + TOOLTIP_GAP, 0.5),
			Size = UDim2.fromScale(TOOLTIP_WIDTH, columnHeight),
			BackgroundTransparency = 1,
			Visible = false,
			ZIndex = TOOLTIP_ZINDEX,
		}, rows)
	end

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
					-- The embers BEHIND the card (see the ember constants).
					-- Its own CanvasGroup so the card alpha and the hover dim
					-- composite in one property instead of per ember.
					EmbersBack = React.createElement("CanvasGroup", {
						ref = embersBackRef,
						AnchorPoint = Vector2.new(0.5, 0.5),
						Position = UDim2.fromScale(0.5, 0.5),
						Size = UDim2.fromScale(EMBER_FIELD_WIDTH, EMBER_FIELD_HEIGHT),
						BackgroundTransparency = 1,
						GroupTransparency = 1,
						ZIndex = 0,
					}),

					-- The few that pass IN FRONT of the card. Above the card
					-- and its ring, so they read as nearest to the camera.
					EmbersFront = React.createElement("CanvasGroup", {
						ref = embersFrontRef,
						AnchorPoint = Vector2.new(0.5, 0.5),
						Position = UDim2.fromScale(0.5, 0.5),
						Size = UDim2.fromScale(EMBER_FIELD_WIDTH, EMBER_FIELD_HEIGHT),
						BackgroundTransparency = 1,
						GroupTransparency = 1,
						ZIndex = 7,
					}),

					-- The keyword tooltips (see the tooltip constants). Under
					-- Lift so the column rides the hover lift with the card,
					-- and OUTSIDE the card's CanvasGroup, whose bounds would
					-- clip anything hanging past the card's edge.
					Tooltip = tooltip,

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
							Color = cardTint,
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
								Color = cardTint,
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
