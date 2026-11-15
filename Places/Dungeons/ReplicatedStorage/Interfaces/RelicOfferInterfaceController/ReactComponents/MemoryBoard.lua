--!strict
--[[
	Module: MemoryBoard.lua
	Description:
	The Memory Shrine's board (2026-11-13; Slay the Spire's Match and
	Keep), drawn with the relic offer's own 3D cards (OfferCard on the
	CardStage) so it looks and moves like the offer. Mounted by
	MemoryShrineController for one board and unmounted when it closes.

	The cards in rows of 5 (10 cards: 2 x 5), sized to the screen. The SERVER judges
	(MemoryShrineService): this draws what it was sent, asks to flip a
	SLOT and animates the answer.

	THE GRID lives in the card poses: every card sits on the stage's one
	centre slot (index 1 of 1) and its pose x / y (face widths / heights)
	puts it on its grid cell, so a card's travel during the shuffle is
	just a pose tween. The stage's layout (card height, row y) is set for
	the grid on mount and the relic offer's is put back on unmount.

	Motion (imperative, on the OfferCard handles):
	  * deal:      ROW BY ROW from the top, each row as a group (a small
	               stagger inside it): every card rises from below the view
	               to its cell, spinning about its spine like the offer's
	               deal -- a full turn to land face up (the cover drops
	               edge-on), or a half turn to land face down
	  * memorise:  a fresh board is dealt face up in REVEAL order (pairs
	               side by side), held, then every card turns face down
	  * shuffle:   the server's Order as SWAPS: two cards trade cells at
	               once on paths bowed to opposite sides, one toward the
	               camera and one away, so no cell ever holds two cards
	  * flip:      a half turn about the spine (face down = yaw 180, the
	               part's back gui; face up = yaw 0, the front)
	  * match:     both cards flash, ring and light their stroke (the
	               offer's pick look) with a small pop toward the camera,
	               and stay up
	  * miss:      both pause face up, then turn back down
	  * finish:    every card turns face up, a beat, then the deal out
	  * deal out:  ROW BY ROW from the bottom, staggered in each row, every
	               card settles and sinks out of the view on a gentle eased
	               curve while it fades, no turn-over.
	               The HUD comes back only once the last card is off
	               screen.

	INPUT: one full-screen catcher button in this ScreenGui, above the
	cards' SurfaceGuis, takes every click and tap (so nothing reaches the
	weapons) and hit-tests the cards itself (handle.containsPoint). The
	HUD scope is held closed while the board is up (as the relic offer
	does), which is also what keeps the weapons and spells quiet.
]]

local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local React = require(ReplicatedStorage.Submodules.Core.Packages.React)
local Blitz = require(ReplicatedStorage.Submodules.Core.Shared.Blitz)
local InterfaceManagerController =
	require(ReplicatedStorage.Submodules.Core.Source.Controllers.InterfaceManagerController)
local InterfaceScopes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.InterfaceScopes)
local ItemRarity = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ItemRarity)

local OfferCard = require(script.Parent.OfferCard)
local CardStage = require(script.Parent.CardStage)
local CardScene = require(script.Parent.CardScene)

local HUD_HIDE_SOURCE = "MemoryShrine"

--[ Tuning ]--

-- Columns per row; the rows follow from the board's card count (10
-- cards: 2 rows of 5). A short last row is centred.
local COLUMNS = 5
-- Gaps between cells, in face widths (across) and face heights (down).
local GAP_X = 0.12
local GAP_Y = 0.08
-- The grid's share of the screen: its height at most GRID_HEIGHT of the
-- view, its width at most GRID_WIDTH, centred on GRID_Y.
local GRID_HEIGHT = 0.72
local GRID_WIDTH = 0.94
local GRID_Y = 0.53
local OFFSCREEN_MARGIN = 0.15

-- The back every card shows face down: the neutral frame art in the
-- shrine's purple (one back for all, so no tier gives a card away).
local BACK_TINT = Color3.fromRGB(176, 120, 230)

-- The deal (the offer's motion), ROW BY ROW from the top: each row
-- arrives as a group, DEAL_ROW_STAGGER after the one above, its cards
-- DEAL_CARD_STAGGER apart left to right.
local DEAL_LEAD_SECONDS = 0.15
local DEAL_ROW_STAGGER = 0.38
local DEAL_CARD_STAGGER = 0.07
local DEAL_MOVE_TWEEN = TweenInfo.new(1.05, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local DEAL_SPIN_TWEEN = TweenInfo.new(1.05, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
local DEAL_FLIP_DELAY = 0.25
local DEAL_FADE_TWEEN = TweenInfo.new(0.6, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
local DEAL_REVEAL_YAW = 270
local DEAL_SOUND_VOLUME_SCALE = 0.5

-- How long a fresh board stays face up to be memorised.
local MEMORISE_SECONDS = 2.5

-- A flip: half a turn about the spine; the face turns up edge-on (the
-- cover drops at FLIP_REVEAL_YAW on the way from 180 to 360).
local FLIP_TWEEN = TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
local FLIP_REVEAL_YAW = 270
local FLIP_DOWN_STAGGER = 0.04

-- The shuffle: the server's Order played as SWAPS (each cycle of the
-- permutation as n - 1 transpositions), so two cards always trade places
-- and never stack in one cell. Swaps run up to SHUFFLE_PER_BATCH at once
-- (only swaps that share no cell), a batch every SHUFFLE_BATCH_SECONDS.
-- In a swap both cards move together on separated paths: they bow to
-- opposite sides of the line between their cells, one toward the camera
-- and the other away from it; a second swap in
-- the same batch uses its own, shallower depths, so no two moving cards
-- (and no resting card, at depth 0) ever share a depth mid-flight.
local SHUFFLE_LEAD_SECONDS = 0.45
local SHUFFLE_PER_BATCH = 2
local SHUFFLE_SWAP_SECONDS = 0.8
local SHUFFLE_BATCH_SECONDS = 0.88
-- Per batch lane: the over card's and the under card's depth (studs).
local SHUFFLE_LANES = {
	{ over = 0.9, under = -0.7 },
	{ over = 0.5, under = -0.35 },
}
-- The bow: each card's path bends this many face widths off the straight
-- line at the halfway point, perpendicular to it. The two cards of a swap
-- travel opposite ways, so the same bow side puts them on opposite sides.
local SHUFFLE_ARC = 0.22
local SHUFFLE_ROLL = 5
local SHUFFLE_TAIL_SECONDS = 0.35
local SHUFFLE_SOUND_VOLUME = 0.45

-- The match: the offer's pick look (flash, ring, lit stroke) on both,
-- and a small pop toward the camera.
local MATCH_POP = 0.5

-- The hover on a face-down card: it grows IN PLACE (comes HOVER_LIFT studs
-- toward the camera along the ray through its own centre, so its centre
-- never moves on screen) and its back glows softly. The stage's own
-- lift, shared with the relic offer's hand.
local HOVER_LIFT = CardStage.HOVER_LIFT
local HOVER_TWEEN = CardStage.HOVER_TWEEN
local MATCH_POP_TWEEN = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local MATCH_SETTLE_TWEEN = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
-- The match sound, by card kind: a GameAssets.Sounds template (`name`,
-- at `scale` of its volume) or an asset id (`id`, at `volume`). Relics
-- keep the relic pick's sound; Coins play the coin drop's pickup
-- (DropData); a crystal card (none yet) would play the crystal drop's.
local NEGATIVE_MATCH_SOUND = { id = "rbxassetid://137938748294875", volume = 0.8 }
local MATCH_SOUNDS: { [string]: { name: string?, scale: number?, id: string?, volume: number? } } = {
	Relic = { name = "RelicPickup", scale = 0.5 },
	Coins = { name = "CoinCollected", scale = 1 },
	Crystals = { name = "DropOre", scale = 1 },
	Cursed = NEGATIVE_MATCH_SOUND,
	LoseMaxHP = NEGATIVE_MATCH_SOUND,
	LoseMaxMana = NEGATIVE_MATCH_SOUND,
	LoseRelic = NEGATIVE_MATCH_SOUND,
}
local MATCH_HOLD_SECONDS = 0.45
-- The miss: both pause face up this long, then turn back down.
local MISS_HOLD_SECONDS = 0.9

-- The finish: a beat, every card face up, a longer beat to read the
-- board, then everything turns over and drops away.
local FINISH_LEAD_SECONDS = 0.6
local FINISH_FLIP_STAGGER = 0.06
local FINISH_HOLD_SECONDS = 1.6
-- The deal out, ROW BY ROW from the bottom: OUT_ROW_STAGGER between
-- rows, OUT_CARD_STAGGER between the cards of a row. No turn-over: each
-- card eases back toward its rest and sinks out of the view on a gentle
-- in-out curve while it fades.
local OUT_ROW_STAGGER = 0.32
local OUT_CARD_STAGGER = 0.08
local OUT_DROP_TWEEN = TweenInfo.new(1.1, Enum.EasingStyle.Cubic, Enum.EasingDirection.InOut)
local OUT_SETTLE_TWEEN = TweenInfo.new(0.5, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
local OUT_FADE_TWEEN = TweenInfo.new(0.8, Enum.EasingStyle.Sine, Enum.EasingDirection.In, 0, false, 0.3)

-- The header (title, status).
local FONT_BOLD = Font.new("rbxasset://fonts/families/Montserrat.json", Enum.FontWeight.Bold)
local FONT_EXTRA_BOLD = Font.new("rbxasset://fonts/families/Montserrat.json", Enum.FontWeight.ExtraBold)
local TITLE_TEXT = "Memory Shrine"
local TITLE_COLOR = Color3.fromRGB(201, 134, 255)
local STATUS_COLOR = Color3.fromRGB(235, 235, 235)
local HEADER_FADE_TWEEN = TweenInfo.new(0.4, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)

local STATUS_MEMORISE = "Memorise the cards..."
local STATUS_SHUFFLE = "Watch closely..."
local STATUS_DONE = "The stones fall silent."

-- The faces of the cards that are not relics: the relic card's frame,
-- in the gold of a reward or the red of a curse.
local BAD_WORD = "rgb(255,92,92)"
local FACES: { [string]: any } = {
	Coins = {
		title = "Gold",
		description = '<font color="rgb(255,170,0)">Gold coins</font> spill from the shrine for you.',
		icon = "rbxassetid://109290144082087",
		rarity = ItemRarity.Legendary,
		pill = "Reward",
	},
	LoseMaxHP = {
		title = "-10% Max HP",
		description = string.format(
			'Your <font color="%s">Max HP</font> drops by 10%% for the rest of this run.',
			BAD_WORD
		),
		icon = "rbxassetid://115509670864191",
		rarity = ItemRarity.Cursed,
		pill = "Curse",
	},
	LoseMaxMana = {
		title = "-10% Max Mana",
		description = string.format(
			'Your <font color="%s">Max Mana</font> drops by 10%% for the rest of this run.',
			BAD_WORD
		),
		icon = "rbxassetid://123177212770838",
		rarity = ItemRarity.Cursed,
		pill = "Curse",
	},
	LoseRelic = {
		title = "Lose a Relic",
		description = string.format('A random relic you hold is <font color="%s">taken</font> from you.', BAD_WORD),
		icon = "rbxassetid://78253288836399",
		rarity = ItemRarity.Cursed,
		pill = "Curse",
	},
}
local UNKNOWN_FACE = {
	title = "???",
	description = "",
	icon = "rbxassetid://78253288836399",
	rarity = ItemRarity.Cursed,
	pill = "Curse",
}

local IS_TOUCH = UserInputService.TouchEnabled and not UserInputService.MouseEnabled

--[ Types ]--

export type BoardCard = { Kind: string, Relic: string?, Matched: boolean }
export type Board = {
	Status: string,
	Cards: { BoardCard },
	Order: { number },
	Fresh: boolean,
	-- Named for misses on the wire; it carries the TRIES left.
	MissesLeft: number,
}
export type FlipResult = { Result: string, MissesLeft: number, Finished: boolean }

type Entry = {
	key: string,
	-- Index into Cards (the reveal order).
	reveal: number,
	-- The board slot this card ends in (what a flip names).
	slot: number,
	-- The cell the card stands in right now (its reveal cell until the
	-- shuffle has moved it): the deal out goes by it.
	cell: number,
	card: BoardCard,
	matched: boolean,
	up: boolean,
	handle: any,
}

--[ Layout ]--

-- The board on screen (one at a time): its card count and rows, set on
-- mount from #board.Cards.
local grid = { count = 10, rows = 2, columns = COLUMNS }

local function setGrid(count: number)
	grid.count = math.max(count, 1)
	grid.columns = math.min(COLUMNS, grid.count)
	grid.rows = math.ceil(grid.count / COLUMNS)
end

-- The face height (fraction of the view) that fits the grid on this
-- viewport: limited by the height, or on a narrow view by the width.
local function gridCardHeight(): number
	local camera = workspace.CurrentCamera
	local viewport = if camera then camera.ViewportSize else Vector2.new(16, 9)
	local aspect = if viewport.Y > 0 then viewport.X / viewport.Y else 16 / 9
	local rows, columns = grid.rows, grid.columns
	local byHeight = GRID_HEIGHT / (rows + (rows - 1) * GAP_Y)
	local byWidth = GRID_WIDTH * aspect / (CardStage.FACE_ASPECT * (columns + (columns - 1) * GAP_X))
	return math.min(byHeight, byWidth)
end

local function applyGridLayout(): number
	local cardHeight = gridCardHeight()
	CardStage.setLayout({ cardHeight = cardHeight, rowY = GRID_Y, gap = 0 })
	return cardHeight
end

-- A slot's cell as a pose offset from the centre slot. A short last
-- row is centred under the full ones.
local function cellPose(slot: number): (number, number)
	local column = (slot - 1) % COLUMNS
	local row = (slot - 1) // COLUMNS
	local inRow = math.min(COLUMNS, grid.count - row * COLUMNS)
	local x = (column - (inRow - 1) / 2) * (1 + GAP_X)
	local y = (row - (grid.rows - 1) / 2) * (1 + GAP_Y)
	return x, y
end

-- A cell's row (0 at the top) and column (0 at the left).
local function cellRowColumn(slot: number): (number, number)
	return (slot - 1) // COLUMNS, (slot - 1) % COLUMNS
end

-- One chance: the first miss ends the board (the server decides).
local STATUS_PLAY = "Find the pairs  -  one miss ends the trial"

--[ Component ]--

-- Props:
--   board     the MemoryBoard the server sent (Status "ok")
--   onFlip    (slot) -> FlipResult?   asks the server (yields)
--   onClosed  ()   the board has animated out: unmount it
--   onEnded   ()   the player left or the board finished: no more
--                  talking to this altar (MemoryShrineController)
local function MemoryBoard(props: any)
	local board: Board = props.board

	-- The grid's layout, applied before the cards rent their parts; the
	-- layout it replaced is put back on unmount.
	local layoutState = React.useState(function()
		local previous = CardStage.getLayout()
		setGrid(#board.Cards)
		local cardHeight = applyGridLayout()
		return { previous = previous, cardHeight = cardHeight }
	end)

	local handlesRef = React.useRef({} :: { [string]: any })
	local titleRef = React.useRef(nil :: TextLabel?)
	local statusRef = React.useRef(nil :: TextLabel?)
	-- The click handlers, wired by the flow effect.
	local pressRef = React.useRef(nil :: ((point: Vector2) -> ())?)
	-- A card's own button was clicked (when the card's gui, not the
	-- catcher, takes the click): the same press, by card key.
	local pressCardRef = React.useRef(nil :: ((key: string) -> ())?)

	-- The entries, in reveal order. The final slot of reveal index r is
	-- the s with Order[s] == r.
	local entries: { Entry } = React.useMemo(function()
		local list: { Entry } = {}
		local slotOf: { [number]: number } = {}
		for slot, reveal in board.Order do
			slotOf[reveal] = slot
		end
		for reveal, card in board.Cards do
			table.insert(list, {
				key = "Memory" .. reveal,
				reveal = reveal,
				slot = slotOf[reveal] or reveal,
				cell = reveal,
				card = card,
				matched = card.Matched,
				up = false,
				handle = nil,
			})
		end
		return list
	end, {})

	React.useEffect(function()
		local session = { stopped = false, unmounted = false }
		local cardHeight = layoutState.cardHeight
		local phase = "dealing"
		local busy = false
		local hovered: Entry? = nil
		local hudHeld = false
		local sceneHeld = false
		local connections: { RBXScriptConnection } = {}

		for _, entry in entries do
			entry.handle = handlesRef.current[entry.key]
		end

		local function holdHud(hold: boolean)
			if hudHeld == hold then
				return
			end
			hudHeld = hold
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

		local function setStatus(text: string, color: Color3?)
			local status = statusRef.current
			if status then
				status.Text = text
				status.TextColor3 = color or STATUS_COLOR
			end
		end

		-- The play line.
		local function setTries()
			setStatus(STATUS_PLAY, nil)
		end

		-- Waits; false once the flow has been stopped (unmount).
		local function hold(seconds: number): boolean
			task.wait(seconds)
			return not session.stopped
		end

		local function offscreenBelow(): number
			return (1 - GRID_Y) / cardHeight + 0.5 + OFFSCREEN_MARGIN
		end

		local function headerAlpha(alpha: number)
			local title = titleRef.current
			if title then
				TweenService:Create(title, HEADER_FADE_TWEEN, {
					TextTransparency = alpha,
					TextStrokeTransparency = 0.4 + 0.6 * alpha,
				}):Play()
			end
			local status = statusRef.current
			if status then
				TweenService:Create(status, HEADER_FADE_TWEEN, {
					TextTransparency = alpha,
					TextStrokeTransparency = 0.5 + 0.5 * alpha,
				}):Play()
			end
		end

		-- A cell's pose at `depth` studs toward the camera, moved along the
		-- ray through the face centre so the centre stays put on screen
		-- (the card only looks larger): CardStage.liftedPose, every card
		-- being on the stage's one centre slot.
		local function liftedPose(cell: number, depth: number): CardStage.Pose
			local x, y = cellPose(cell)
			return CardStage.liftedPose(1, 1, x, y, depth)
		end

		local function setHovered(entry: Entry?)
			if hovered == entry then
				return
			end
			local previous = hovered
			hovered = entry
			if previous and previous.handle then
				previous.handle.tweenPose(liftedPose(previous.cell, 0), HOVER_TWEEN)
				previous.handle.setBackGlow(false)
			end
			if entry and entry.handle then
				entry.handle.tweenPose(liftedPose(entry.cell, HOVER_LIFT), HOVER_TWEEN)
				entry.handle.setBackGlow(true)
			end
		end

		--[ Card motion ]--

		-- Face up from face down (yaw 180 -> 360, the cover dropping
		-- edge-on), resting at 0. Returns the tween.
		local function flipUp(entry: Entry, info: TweenInfo?): Tween?
			local handle = entry.handle
			if not handle then
				return nil
			end
			entry.up = true
			handle.setPose({ yaw = 180 })
			handle.setCover(true)
			handle.revealAtYaw(FLIP_REVEAL_YAW)
			local spin = handle.tweenPose({ yaw = 360 }, info or FLIP_TWEEN)
			CardScene.playSoundId(CardScene.CARD_FLIP_SOUND_ID, CardScene.CARD_FLIP_VOLUME * DEAL_SOUND_VOLUME_SCALE)
			if spin then
				spin.Completed:Once(function(state: Enum.PlaybackState)
					if state == Enum.PlaybackState.Completed and entry.up then
						handle.setCover(false)
						handle.setPose({ yaw = 0 })
					end
				end)
			end
			return spin
		end

		-- Face down from face up (yaw 0 -> 180, the back gui showing).
		local function flipDown(entry: Entry): Tween?
			local handle = entry.handle
			if not handle then
				return nil
			end
			entry.up = false
			local spin = handle.tweenPose({ yaw = 180 }, FLIP_TWEEN)
			if spin then
				spin.Completed:Once(function(state: Enum.PlaybackState)
					if state == Enum.PlaybackState.Completed and not entry.up then
						handle.setCover(true)
					end
				end)
			end
			return spin
		end

		-- The deal: every card parked below the view, then each rises to
		-- its cell (at `slotOf(entry)`) spinning to face up (`faceUp`) or
		-- down. Returns the seconds until the last card has landed.
		local function deal(slotOf: (Entry) -> number, faceUp: (Entry) -> boolean): number
			local below = offscreenBelow()
			for _, entry in entries do
				local handle = entry.handle
				if handle then
					entry.cell = slotOf(entry)
					local x = cellPose(entry.cell)
					handle.alpha.Value = 1
					handle.setScale(1)
					handle.setCover(true)
					handle.setPose({ x = x, y = below, depth = 0, yaw = 0, pitch = 0, roll = 0 })
				end
			end
			local last = 0
			for _, entry in entries do
				local handle = entry.handle
				if not handle then
					continue
				end
				local row, column = cellRowColumn(slotOf(entry))
				local start = DEAL_LEAD_SECONDS + row * DEAL_ROW_STAGGER + column * DEAL_CARD_STAGGER
				last = math.max(last, start)
				local up = faceUp(entry)
				local _, y = cellPose(slotOf(entry))
				task.delay(start, function()
					if session.stopped then
						return
					end
					local move = handle.tweenPose({ y = y }, DEAL_MOVE_TWEEN)
					CardScene.playSoundId(
						CardScene.CARD_SLIDE_SOUND_ID,
						CardScene.CARD_SLIDE_VOLUME * DEAL_SOUND_VOLUME_SCALE
					)
					TweenService:Create(handle.alpha, DEAL_FADE_TWEEN, { Value = 0 }):Play()
					handle.revealDescription()
					task.delay(DEAL_FLIP_DELAY, function()
						if session.stopped then
							return
						end
						entry.up = up
						if up then
							handle.revealAtYaw(DEAL_REVEAL_YAW)
						end
						local spin = handle.tweenPose({ yaw = if up then 360 else 180 }, DEAL_SPIN_TWEEN)
						if spin and up then
							spin.Completed:Once(function(state: Enum.PlaybackState)
								if state == Enum.PlaybackState.Completed and entry.up then
									handle.setCover(false)
									handle.setPose({ yaw = 0 })
								end
							end)
						end
					end)
					if move and up then
						move.Completed:Once(function(state: Enum.PlaybackState)
							if state == Enum.PlaybackState.Completed then
								handle.sweep()
							end
						end)
					end
				end)
			end
			return last + math.max(DEAL_MOVE_TWEEN.Time, DEAL_FLIP_DELAY + DEAL_SPIN_TWEEN.Time) + 0.05
		end

		-- Every card turns over (to its back) and drops out of the view,
		-- row by row from the bottom. Returns the seconds until the last
		-- card is below the view.
		local function dealOut(): number
			setHovered(nil)
			local below = offscreenBelow()
			local last = 0
			for _, entry in entries do
				local handle = entry.handle
				if not handle then
					continue
				end
				local row, column = cellRowColumn(entry.cell)
				local start = (grid.rows - 1 - row) * OUT_ROW_STAGGER + column * OUT_CARD_STAGGER
				last = math.max(last, start)
				task.delay(start, function()
					if session.unmounted then
						return
					end
					-- The face it shows stays (no turn-over): it settles, then
					-- sinks out of the view while fading.
					handle.tweenPose({ depth = 0, roll = 0, pitch = 0 }, OUT_SETTLE_TWEEN)
					handle.tweenPose({ y = below }, OUT_DROP_TWEEN)
					TweenService:Create(handle.alpha, OUT_FADE_TWEEN, { Value = 1 }):Play()
				end)
			end
			return last + OUT_DROP_TWEEN.Time + 0.05
		end

		-- Everything leaves; then the HUD comes back (only once the last
		-- card is off the screen) and the controller unmounts the board.
		local function close()
			if phase == "closing" then
				return
			end
			phase = "closing"
			session.stopped = true
			if props.onEnded then
				props.onEnded()
			end
			headerAlpha(1)
			local seconds = dealOut()
			if sceneHeld then
				sceneHeld = false
				CardScene.sceneOut()
			end
			task.delay(seconds, function()
				if not session.unmounted then
					holdHud(false)
					props.onClosed()
				end
			end)
		end

		local function finish()
			phase = "finishing"
			if props.onEnded then
				props.onEnded()
			end
			setHovered(nil)
			setStatus(STATUS_DONE)
			if not hold(FINISH_LEAD_SECONDS) then
				return
			end
			for _, entry in entries do
				if not entry.up then
					flipUp(entry)
					if not hold(FINISH_FLIP_STAGGER) then
						return
					end
				end
			end
			if not hold(FLIP_TWEEN.Time + FINISH_HOLD_SECONDS) then
				return
			end
			close()
		end

		--[ The shuffle ]--

		-- The server's Order as swaps of two cells, batched. The cell move
		-- (the card in cell c goes to the slot whose Order names it) splits
		-- into cycles; each cycle c0 -> c1 -> ... -> c(k-1) -> c0 is played
		-- as two rounds of disjoint swaps, the two reflections whose product
		-- is the cycle: round 1 trades c(i) with c(k - i), round 2 trades
		-- c(i) with c(k + 1 - i). That is k - 1 swaps per cycle, the cells
		-- end exactly as Order says, and every swap in a round is
		-- independent, so the rounds batch well.
		local function shuffleBatches(): { { { number } } }
			-- Where the card now in each cell must end.
			local target: { [number]: number } = {}
			local cellOfReveal: { [number]: number } = {}
			for _, entry in entries do
				cellOfReveal[entry.reveal] = entry.cell
			end
			for slot, reveal in board.Order do
				local cell = cellOfReveal[reveal]
				if cell then
					target[cell] = slot
				end
			end
			local roundOne: { { number } } = {}
			local roundTwo: { { number } } = {}
			local visited: { [number]: boolean } = {}
			for cell = 1, #entries do
				if visited[cell] or not target[cell] then
					continue
				end
				local cycle: { number } = {}
				local at: number? = cell
				while at and not visited[at] do
					visited[at] = true
					table.insert(cycle, at)
					at = target[at]
				end
				local k = #cycle
				-- cycle[i + 1] is c(i).
				for i = 1, (k - 1) // 2 do
					table.insert(roundOne, { cycle[i + 1], cycle[k - i + 1] })
				end
				for i = 1, k // 2 do
					table.insert(roundTwo, { cycle[i + 1], cycle[(k + 1 - i) % k + 1] })
				end
			end
			local swaps: { { number } } = roundOne
			for _, swap in roundTwo do
				table.insert(swaps, swap)
			end
			-- Each swap goes in the earliest batch after the last one that
			-- touched either of its cells (swaps on other cells commute), at
			-- most SHUFFLE_PER_BATCH to a batch.
			local batches: { { { number } } } = {}
			local lastBatch: { [number]: number } = {}
			for _, swap in swaps do
				local index = math.max(lastBatch[swap[1]] or 0, lastBatch[swap[2]] or 0) + 1
				while batches[index] and #batches[index] >= SHUFFLE_PER_BATCH do
					index += 1
				end
				local batch = batches[index]
				if not batch then
					batch = {}
					batches[index] = batch
				end
				table.insert(batch, swap)
				lastBatch[swap[1]] = index
				lastBatch[swap[2]] = index
			end
			return batches
		end

		-- One card's leg of a swap, driven by ONE eased progress value so the
		-- path is smooth end to end: the card travels the straight line to
		-- its new cell, bowed sideways by `side` (+1 or -1) times SHUFFLE_ARC
		-- perpendicular to that line (so the two cards of a swap bow apart,
		-- whatever the direction), while its depth swells to `depth` and back
		-- and it rolls a touch. Returns nothing; lands exactly on the cell.
		local function swapLeg(entry: Entry, toCell: number, depth: number, side: number, roll: number)
			entry.cell = toCell
			local handle = entry.handle
			if not handle then
				return
			end
			local pose = handle.card.pose
			local fromX, fromY = pose.x.Value, pose.y.Value
			local toX, toY = cellPose(toCell)
			-- The bow, in face units: perpendicular to the travel, scaled so
			-- it reads the same across and down (a face is taller than wide).
			local dx, dy = toX - fromX, (toY - fromY) / CardStage.FACE_ASPECT
			local length = math.sqrt(dx * dx + dy * dy)
			local bowX, bowY = 0, 0
			if length > 0 then
				bowX = -dy / length * SHUFFLE_ARC * side
				bowY = dx / length * SHUFFLE_ARC * side * CardStage.FACE_ASPECT
			end
			local progress = Instance.new("NumberValue")
			progress.Value = 0
			local connection = progress.Changed:Connect(function(t: number)
				if session.unmounted then
					return
				end
				local swell = math.sin(math.pi * t)
				handle.setPose({
					x = fromX + (toX - fromX) * t + bowX * swell,
					y = fromY + (toY - fromY) * t + bowY * swell,
					depth = depth * swell,
					roll = roll * swell,
				})
			end)
			local move = TweenService:Create(
				progress,
				TweenInfo.new(SHUFFLE_SWAP_SECONDS, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
				{ Value = 1 }
			)
			move.Completed:Once(function()
				connection:Disconnect()
				progress:Destroy()
				if not session.unmounted then
					handle.setPose({ x = toX, y = toY, depth = 0, roll = 0 })
				end
			end)
			move:Play()
		end

		-- Two cells trade cards: the first arcs over, the second under.
		local function playSwap(cellA: number, cellB: number, lane: { over: number, under: number })
			local cardA: Entry? = nil
			local cardB: Entry? = nil
			for _, entry in entries do
				if entry.cell == cellA then
					cardA = entry
				elseif entry.cell == cellB then
					cardB = entry
				end
			end
			if cardA then
				swapLeg(cardA, cellB, lane.over, 1, SHUFFLE_ROLL)
			end
			if cardB then
				swapLeg(cardB, cellA, lane.under, 1, -SHUFFLE_ROLL)
			end
		end

		--[ Play ]--

		local function pickAt(point: Vector2): Entry?
			for _, entry in entries do
				local handle = entry.handle
				if handle and not entry.matched and not entry.up and handle.containsPoint(point) then
					return entry
				end
			end
			return nil
		end

		local firstUp: Entry? = nil

		local function resolveFlip(entry: Entry)
			busy = true
			setHovered(nil)
			local spin = flipUp(entry)
			local spinDone = spin == nil
			if spin then
				spin.Completed:Once(function()
					spinDone = true
				end)
			end
			local ok, result = pcall(props.onFlip, entry.slot)
			while not spinDone and not session.stopped do
				task.wait()
			end
			if session.stopped then
				return
			end
			local answer: FlipResult? = if ok then result else nil
			if not answer or answer.Result == "invalid" then
				flipDown(entry)
				if firstUp then
					flipDown(firstUp)
					firstUp = nil
				end
				if answer and answer.Finished then
					finish()
				else
					busy = false
				end
				return
			end
			if answer.Result == "first" then
				firstUp = entry
			elseif answer.Result == "match" then
				local pair: { Entry } = { entry }
				if firstUp then
					table.insert(pair, firstUp)
				end
				firstUp = nil
				for _, matched in pair do
					matched.matched = true
					local handle = matched.handle
					if handle then
						handle.brightenStroke()
						handle.flash()
						handle.shockwave()
						local pop = handle.tweenPose(liftedPose(matched.cell, MATCH_POP), MATCH_POP_TWEEN)
						if pop then
							pop.Completed:Once(function()
								if not session.unmounted then
									handle.tweenPose(liftedPose(matched.cell, 0), MATCH_SETTLE_TWEEN)
								end
							end)
						end
					end
				end
				local sound = MATCH_SOUNDS[entry.card.Kind] or MATCH_SOUNDS.Relic
				if sound.id then
					CardScene.playSoundId(sound.id, sound.volume or 1)
				elseif sound.name then
					CardScene.playUiSound(sound.name, sound.scale)
				end
				setTries()
				-- The pick look plays out in full before anything else; the
				-- whole pop and settle when the board ends on this match.
				local matchHold = if answer.Finished
					then math.max(MATCH_HOLD_SECONDS, MATCH_POP_TWEEN.Time + MATCH_SETTLE_TWEEN.Time + 0.15)
					else MATCH_HOLD_SECONDS
				if not hold(matchHold) then
					return
				end
			elseif answer.Result == "miss" then
				local other = firstUp
				firstUp = nil
				setTries()
				if not hold(MISS_HOLD_SECONDS) then
					return
				end
				flipDown(entry)
				if other then
					flipDown(other)
				end
				if not hold(FLIP_TWEEN.Time) then
					return
				end
			end
			if answer.Finished then
				finish()
				return
			end
			busy = false
		end

		pressRef.current = function(point: Vector2)
			if phase ~= "play" or busy then
				return
			end
			local entry = pickAt(point)
			if entry then
				task.spawn(resolveFlip, entry)
			end
		end
		pressCardRef.current = function(key: string)
			if phase ~= "play" or busy then
				return
			end
			for _, entry in entries do
				if entry.key == key and entry.handle and not entry.matched and not entry.up then
					task.spawn(resolveFlip, entry)
					return
				end
			end
		end

		-- The cursor's hover: the face-down card under it lifts.
		if not IS_TOUCH then
			table.insert(
				connections,
				RunService.RenderStepped:Connect(function()
					if phase ~= "play" or busy then
						setHovered(nil)
						return
					end
					-- Viewport space, like handle.containsPoint (WorldToViewportPoint).
					local cursor = UserInputService:GetMouseLocation()
					setHovered(pickAt(cursor))
				end)
			)
		end

		-- A resize or rotation refits the grid (the poses are in face
		-- units, so the cards follow on their own).
		local camera = workspace.CurrentCamera
		if camera then
			table.insert(
				connections,
				camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
					cardHeight = applyGridLayout()
				end)
			)
		end

		--[ The flow ]--

		holdHud(true)
		CardScene.sceneIn()
		sceneHeld = true
		headerAlpha(0)

		task.spawn(function()
			if board.Fresh then
				-- Dealt face up in reveal order, pairs side by side.
				setStatus(STATUS_MEMORISE)
				local landed = deal(function(entry: Entry): number
					return entry.reveal
				end, function(): boolean
					return true
				end)
				if not hold(landed + MEMORISE_SECONDS) then
					return
				end
				for _, entry in entries do
					flipDown(entry)
					if not hold(FLIP_DOWN_STAGGER) then
						return
					end
				end
				if not hold(FLIP_TWEEN.Time + SHUFFLE_LEAD_SECONDS) then
					return
				end

				-- The shuffle, as swaps (see the SHUFFLE constants).
				phase = "shuffling"
				setStatus(STATUS_SHUFFLE)
				for _, batch in shuffleBatches() do
					for lane, swap in batch do
						playSwap(swap[1], swap[2], SHUFFLE_LANES[lane] or SHUFFLE_LANES[#SHUFFLE_LANES])
					end
					CardScene.playSoundId(CardScene.CARD_SLIDE_SOUND_ID, SHUFFLE_SOUND_VOLUME)
					if not hold(SHUFFLE_BATCH_SECONDS) then
						return
					end
				end
				if not hold(SHUFFLE_TAIL_SECONDS) then
					return
				end
			else
				-- Re-opened: already in its final order; found pairs face up.
				local landed = deal(function(entry: Entry): number
					return entry.slot
				end, function(entry: Entry): boolean
					return entry.matched
				end)
				if not hold(landed) then
					return
				end
			end
			for _, entry in entries do
				if entry.matched and entry.handle then
					entry.handle.brightenStroke()
				end
			end
			phase = "play"
			setTries()
		end)

		return function()
			session.stopped = true
			session.unmounted = true
			pressRef.current = nil
			pressCardRef.current = nil
			for _, connection in connections do
				connection:Disconnect()
			end
			holdHud(false)
			if sceneHeld then
				sceneHeld = false
				CardScene.sceneOut(true)
			end
			CardStage.setLayout(layoutState.previous)
		end
	end, {})

	local cardChildren = {}
	for _, entry in entries do
		local card = entry.card
		local isRelic = card.Relic ~= nil and card.Relic ~= "" and (card.Kind == "Relic" or card.Kind == "Cursed")
		cardChildren[entry.key] = React.createElement(OfferCard, {
			relicName = if isRelic then card.Relic else nil,
			face = if isRelic then nil else (FACES[card.Kind] or UNKNOWN_FACE),
			cardKey = entry.key,
			index = 1,
			count = 1,
			bobIndex = entry.reveal,
			isPhone = false,
			tilt = false,
			backTint = BACK_TINT,
			backGlow = true,
			onRegister = function(key: string, handle)
				handlesRef.current[key] = handle
			end,
			onHover = function() end,
			onActivated = function(key: string)
				local press = pressCardRef.current
				if press then
					press(key)
				end
			end,
		})
	end

	return React.createElement("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
	}, {
		-- Every click and tap on the screen lands here (above the cards'
		-- SurfaceGuis, so nothing reaches the world) and is hit-tested
		-- against the cards.
		Catcher = React.createElement("TextButton", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Text = "",
			AutoButtonColor = false,
			Selectable = false,
			ZIndex = 1,
			[React.Event.Activated] = function(_rbx: TextButton, input: InputObject)
				local press = pressRef.current
				if press and input then
					-- An input's Position excludes the top bar inset; the cards
					-- hit-test in viewport space.
					local inset = GuiService:GetGuiInset()
					press(Vector2.new(input.Position.X + inset.X, input.Position.Y + inset.Y))
				end
			end,
		}),

		Title = React.createElement("TextLabel", {
			ref = titleRef,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.075),
			Size = UDim2.fromScale(0.4, 0.06),
			BackgroundTransparency = 1,
			Text = TITLE_TEXT,
			TextColor3 = TITLE_COLOR,
			TextStrokeColor3 = Color3.fromRGB(0, 0, 0),
			TextTransparency = 1,
			TextStrokeTransparency = 1,
			FontFace = FONT_EXTRA_BOLD,
			TextScaled = true,
			ZIndex = 2,
		}, {
			UITextSizeConstraint = React.createElement("UITextSizeConstraint", { MaxTextSize = 44 }),
		}),

		Status = React.createElement("TextLabel", {
			ref = statusRef,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.13),
			Size = UDim2.fromScale(0.5, 0.04),
			BackgroundTransparency = 1,
			Text = "",
			TextColor3 = STATUS_COLOR,
			TextStrokeColor3 = Color3.fromRGB(0, 0, 0),
			TextTransparency = 1,
			TextStrokeTransparency = 1,
			FontFace = FONT_BOLD,
			TextScaled = true,
			ZIndex = 2,
		}, {
			UITextSizeConstraint = React.createElement("UITextSizeConstraint", { MaxTextSize = 26 }),
		}),

		Cards = React.createElement("Folder", {}, cardChildren),
	})
end

return MemoryBoard
