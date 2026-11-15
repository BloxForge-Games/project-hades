--[[
     Module: Container.lua
     Description:
     Props screen UI
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local React = require(ReplicatedStorage.Submodules.Core.Packages.React)
local RelicListFragment = require(script.Parent.RelicListFragment)
local RelicEntryContainer = require(script.Parent.RelicEntryContainer)
local RelicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicData)
local ItemRarity = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ItemRarity)
local getRelicDescription = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Relic.getRelicDescription)
local tweenGui = require(ReplicatedStorage.Submodules.Core.Shared.Functions.UI.tweenGui)
local ShineRing = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.ShineRing)

local localPlayer = Players.LocalPlayer

--[ Selection ]--

-- The tray's selection is an owned relic: { name = relicName, count = n }.
-- There are no locked slots since the relic cap went (2026-11-12).
-- The toggle plate's ring (see the effect in Container): the inventory
-- tiles' animated shine outline in the tray's accent blue, at the plate
-- stroke's own thickness, for as long as the toggle exists.
-- Rich text, the relic-description blue for the two nouns.
-- Every relic description renders at ONE size (2026-10-29): TextScaled
-- shrank the longer ones to squeeze them in, so cards disagreed. The size
-- is the largest at which the LONGEST card -- DESCRIPTION_REFERENCE_RELIC's,
-- the length budget every description is written to -- fits the label,
-- measured with TextService for the label's live size, so it follows the
-- card on any screen, phones included. A description longer than that
-- budget shrinks to fit instead of spilling.
local DESCRIPTION_REFERENCE_RELIC = "Golem's Hammer"
local DESCRIPTION_FONT =
	Font.new("rbxasset://fonts/families/Montserrat.json", Enum.FontWeight.SemiBold, Enum.FontStyle.Normal)
local DESCRIPTION_MIN_TEXT_SIZE = 8
local DESCRIPTION_MAX_TEXT_SIZE = 60

-- The largest whole TextSize at which `text` (rich text) fits `box`.
-- Yields (TextService); cached per text and box.
local fitCache: { [string]: number } = {}
local function fitTextSize(text: string, box: Vector2): number
	local key = string.format("%d:%d:%s", box.X, box.Y, text)
	local cached = fitCache[key]
	if cached then
		return cached
	end
	local low, high = DESCRIPTION_MIN_TEXT_SIZE, DESCRIPTION_MAX_TEXT_SIZE
	while low < high do
		local size = math.ceil((low + high) / 2)
		local params = Instance.new("GetTextBoundsParams")
		params.Text = text
		params.Font = DESCRIPTION_FONT
		params.Size = size
		params.Width = box.X
		params.RichText = true
		local ok, bounds = pcall(TextService.GetTextBoundsAsync, TextService, params)
		if ok and bounds.Y <= box.Y then
			low = size
		else
			high = size - 1
		end
	end
	fitCache[key] = low
	return low
end

--[ Layout ]--

-- The description card slides RIGHT as it fades in. Authored positions --
-- keep these two in step with the card's own Position below, which is the
-- resting pose it is re-snapped to before each slide.
-- The card rests just right of the slim panel (2026-10-31; it sat at
-- 0.484 when the panel was a 3 x 5 grid) and slides in from 0.04 left.
-- Both take the panel's EXTRA width in pixels (every column past the
-- first, 2026-11-12), so the card always clears the panel's edge.
local function descriptionHiddenPosition(extra: number): UDim2
	return UDim2.new(0.34, extra, 0.372, 0)
end
local function descriptionShownPosition(extra: number): UDim2
	return UDim2.new(0.38, extra, 0.372, 0)
end
-- The appear: the slide keeps its quick-then-settle Quint, but the fade
-- rides a Sine curve -- a Quint fade front-loads two thirds of the
-- opacity into the first few frames and reads as a snap. The retract
-- (below) stays fast on purpose.
local DESCRIPTION_APPEAR_SLIDE_SECONDS = 0.75
local DESCRIPTION_APPEAR_FADE_SECONDS = 0.6

-- Tray slide: the whole Container shifts left to park the relic list
-- off-screen, and the toggle button counter-shifts so it stays reachable.
local CONTAINER_SHOWN_POSITION = UDim2.fromScale(0.5, 0.5)
-- The panel is one slim column (2026-10-31), so the park shift is a
-- tenth of the screen, plus the width of every extra column.
local function containerHiddenPosition(extra: number): UDim2
	return UDim2.new(0.38, -extra, 0.5, 0)
end

-- The relic list's share of the screen height, and one column's step
-- (box 0.14 + gap 0.045) as a share of the list's height: an extra
-- column is exactly as far from the last as the boxes are from each
-- other down a column.
local LIST_HEIGHT = 0.512406
local COLUMN_STEP = 0.185
-- How the panel widens (or narrows) when a column opens (or empties).
local GROW_INFO = TweenInfo.new(0.45, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)

local taskConnection = nil

local function Container(props: any)
	local visible, setVisible = React.useState(false)
	local selectedRelic, setSelectedRelic = React.useState(nil)
	local descriptionSelectedRelic, setDescriptionSelectedRelic = React.useState(nil)
	-- Merchant sell session. Only ever true between the Merchant's
	-- "sell relics" dialogue option and this tray closing.
	local sellMode, setSellMode = React.useState(false)
	-- Forge reforge session. Mutually exclusive with sellMode in practice
	-- (the two events cannot run at once), but tracked separately so each
	-- button only ever answers to its own event.
	local reforgeMode, setReforgeMode = React.useState(false)
	-- The tray has no toggle of its own since 2026-10-31: the toolbar's C
	-- button and the C key open it (RelicInterfaceController.Toggle), and
	-- the controller refuses while the player is downed or in a cutscene.

	-- Unavailable buttons keep a DIM of their identity color (gold Sell,
	-- blue Reforge) and mask their label as "???" until their event
	-- makes them live. Inert clicks do NOTHING.
	local function greyed(color: Color3): Color3
		return color:Lerp(Color3.fromRGB(50, 50, 50), 0.55)
	end

	-- DROP is live whenever no event session owns the row and the selected
	-- relic is not Cursed (a curse is the price of its payoff, so it is the
	-- one thing you cannot shed). Greyed like the others when it is not.
	local selectedRelicName = descriptionSelectedRelic and descriptionSelectedRelic.name
	local selectedIsCursed = selectedRelicName ~= nil
		and RelicData[selectedRelicName] ~= nil
		and RelicData[selectedRelicName].rarity == ItemRarity.Cursed
	local dropLive = not sellMode and not reforgeMode and not selectedIsCursed

	-- A Cursed relic reads LOCKED rather than masked. The other unavailable
	-- buttons say "???" in a dim tint, because they are waiting on an event
	-- that will eventually arrive — Sell needs the Merchant, Reforge needs
	-- the Forge. Dropping a curse is not pending anything: it is refused
	-- outright, forever, so it states the reason legibly instead of hiding
	-- it behind a placeholder the player is invited to keep checking.
	local DROP_LOCKED_BACKGROUND = Color3.fromRGB(142, 72, 72)
	local DROP_LOCKED_COLOR = Color3.fromRGB(80, 7, 7)

	local relicData = props.relicData

	-- THE COLUMNS (2026-11-12): one per six relics. A column's width is a
	-- share of the screen HEIGHT (the boxes are squares sized off it), so
	-- it is measured in pixels from the screen, and the panel, the list
	-- and the card move by `extra`, the width of every column past the
	-- first. `extraWidth` is the binding the panel and list are drawn
	-- from; it tweens to `extra` so the panel widens smoothly.
	local screenHeight, setScreenHeight = React.useState(0)
	local columns = RelicListFragment.ColumnsFor(relicData)
	local columnWidth = math.floor(screenHeight * LIST_HEIGHT * COLUMN_STEP + 0.5)
	local extra = (columns - 1) * columnWidth
	local extraWidth, setExtraWidth = React.useBinding(extra)

	local containerRef = React.useRef(nil)
	local backgroundFrameRef = React.useRef(nil)
	local descriptionFrameRef = React.useRef(nil)
	local descriptionLabelRef = React.useRef(nil)
	local descriptionTextSize, setDescriptionTextSize = React.useState(14)

	local visibleRef = React.useRef(visible)

	local selectedRelicRef = React.useRef(selectedRelic)

	local extraRef = React.useRef(extra)
	extraRef.current = extra

	-- The screen's height, for the column width. The Container fills the
	-- screen (it slides, never resizes), so its own height is the screen's.
	React.useEffect(function()
		local frame = containerRef.current
		if not frame then
			return
		end
		local function measure()
			setScreenHeight(frame.AbsoluteSize.Y)
		end
		measure()
		local connection = frame:GetPropertyChangedSignal("AbsoluteSize"):Connect(measure)
		return function()
			connection:Disconnect()
		end
	end, {})

	-- Widen (or narrow) the panel to `extra` over GROW_INFO, and carry the
	-- card and the parked pose along. Snaps while the screen is unmeasured.
	React.useEffect(function()
		local from = extraWidth:getValue()
		if screenHeight <= 0 or from == extra then
			setExtraWidth(extra)
		else
			local started = os.clock()
			local connection
			connection = RunService.RenderStepped:Connect(function()
				local alpha = math.clamp((os.clock() - started) / GROW_INFO.Time, 0, 1)
				local eased = TweenService:GetValue(alpha, GROW_INFO.EasingStyle, GROW_INFO.EasingDirection)
				setExtraWidth(from + (extra - from) * eased)
				if alpha >= 1 then
					connection:Disconnect()
				end
			end)
			return function()
				connection:Disconnect()
			end
		end
		return nil
	end, { extra })

	-- The card and the parked tray follow a new column (the slide uses the
	-- same Quint as the panel, so they move together).
	React.useEffect(function()
		local card = descriptionFrameRef.current
		local container = containerRef.current
		if not card or not container then
			return
		end
		if visibleRef.current then
			if selectedRelicRef.current then
				TweenService:Create(card, GROW_INFO, { Position = descriptionShownPosition(extra) }):Play()
			else
				card.Position = descriptionHiddenPosition(extra)
			end
		else
			container.Position = containerHiddenPosition(extra)
			card.Position = descriptionHiddenPosition(extra)
		end
	end, { extra })

	React.useEffect(function()
		visibleRef.current = visible
	end, { visible })

	-- InterfaceManagerController drives this through the controller's
	-- SetVisible signal, handed down as a prop (requiring the controller
	-- here would be circular). Everything below already tweens off
	-- `visible`, so a scope close slides the tray out exactly like the
	-- player pressing its own toggle button.
	React.useEffect(function()
		local signal = props.setVisibleSignal
		if not signal then
			return
		end
		local conn = signal:Connect(function(newVisible: boolean)
			setVisible(newVisible)
		end)
		local sellConn
		if props.sellModeSignal then
			sellConn = props.sellModeSignal:Connect(function(active: boolean)
				setSellMode(active)
			end)
		end
		local reforgeConn
		if props.reforgeModeSignal then
			reforgeConn = props.reforgeModeSignal:Connect(function(active: boolean)
				setReforgeMode(active)
			end)
		end
		return function()
			conn:Disconnect()
			if sellConn then
				sellConn:Disconnect()
			end
			if reforgeConn then
				reforgeConn:Disconnect()
			end
		end
	end, {})

	-- THE close hook for the Merchant's sell session. Keyed on `visible`
	-- so every close path lands here — the scope/signal close AND the
	-- tray's own toggle button, which flips state without firing any
	-- signal. Ending the session notifies EventController, which advances
	-- the waiting merchant dialogue (the "..." node).
	React.useEffect(function()
		if not visible and sellMode then
			setSellMode(false)
			if props.onSellModeEnded then
				task.spawn(props.onSellModeEnded)
			end
		end
		-- Same for the Forge: its "..." node is AwaitExternal, so closing
		-- the tray is one of the only two things that can move the
		-- blacksmith on (the other being an actual reforge).
		if not visible and reforgeMode then
			setReforgeMode(false)
			if props.onReforgeModeEnded then
				task.spawn(props.onReforgeModeEnded)
			end
		end
	end, { visible })

	-- Reports every open / close upward (the toggle button flips `visible`
	-- without firing any signal, so this is the one place that sees all
	-- of them).
	React.useEffect(function()
		if props.onVisibilityChanged then
			props.onVisibilityChanged(visible)
		end
	end, { visible })

	React.useEffect(function()
		selectedRelicRef.current = selectedRelic
	end, { selectedRelic })

	React.useEffect(function()
		if selectedRelic and visible then
			TweenService:Create(
				descriptionFrameRef.current,
				TweenInfo.new(0.05, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
				{ GroupTransparency = 1 }
			):Play()

			if taskConnection then
				task.cancel(taskConnection)
			end

			taskConnection = task.delay(0.05, function()
				setDescriptionSelectedRelic(selectedRelic)

				if visibleRef.current and selectedRelicRef.current then
					descriptionFrameRef.current.Position = descriptionHiddenPosition(extraRef.current)

					tweenGui.position(
						descriptionFrameRef.current,
						descriptionShownPosition(extraRef.current),
						Enum.EasingDirection.Out,
						Enum.EasingStyle.Quint,
						DESCRIPTION_APPEAR_SLIDE_SECONDS,
						true
					)

					TweenService
						:Create(
							descriptionFrameRef.current,
							TweenInfo.new(
								DESCRIPTION_APPEAR_FADE_SECONDS,
								Enum.EasingStyle.Sine,
								Enum.EasingDirection.Out
							),
							{ GroupTransparency = 0 }
						)
						:Play()
				end
			end)
		elseif visible then
			-- DESELECT (sell / destroy / future clears): retract with the
			-- same language the entry used — slide back to the hidden pose
			-- while fading out. The card's CONTENT (descriptionSelectedRelic)
			-- deliberately survives until the fade lands, so the sold relic's
			-- details never blink out of a still-visible card.
			TweenService:Create(
				descriptionFrameRef.current,
				TweenInfo.new(0.5, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
				{ GroupTransparency = 1 }
			):Play()
			tweenGui.position(
				descriptionFrameRef.current,
				descriptionHiddenPosition(extraRef.current),
				Enum.EasingDirection.Out,
				Enum.EasingStyle.Quint,
				0.5,
				true
			)

			if taskConnection then
				task.cancel(taskConnection)
			end
			taskConnection = task.delay(0.5, function()
				-- Only clear if nothing was re-selected during the retract.
				if not selectedRelicRef.current then
					setDescriptionSelectedRelic(nil)
				end
			end)
		end
	end, { selectedRelic, visible })

	React.useEffect(function()
		if visible then
			tweenGui.position(
				containerRef.current,
				CONTAINER_SHOWN_POSITION,
				Enum.EasingDirection.Out,
				Enum.EasingStyle.Quint,
				0.5,
				true
			)

			TweenService:Create(
				backgroundFrameRef.current,
				TweenInfo.new(0.5, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
				{ BackgroundTransparency = 0.5 }
			):Play()
		else
			tweenGui.position(
				containerRef.current,
				containerHiddenPosition(extraRef.current),
				Enum.EasingDirection.Out,
				Enum.EasingStyle.Quint,
				0.5,
				true
			)

			TweenService:Create(
				backgroundFrameRef.current,
				TweenInfo.new(0.5, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
				{ BackgroundTransparency = 1 }
			):Play()

			TweenService:Create(
				descriptionFrameRef.current,
				TweenInfo.new(0.5, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
				{ GroupTransparency = 1 }
			):Play()
		end
	end, { visible })

	-- Resolve the description for the currently-hovered relic ONCE per
	-- render and reuse across the 4 label / visibility sites below.
	-- Routes through getRelicDescription so level-scaled relics (Super
	-- Stomp Boots, Summer Fireworks, Trick Or Trap) show the concrete
	-- damage at the player's current level instead of the static
	-- "(N × PlayerLevel)" formula text. Static relics fall back to
	-- RelicData[name].description unchanged.
	local descriptionText = ""
	if descriptionSelectedRelic and RelicData[descriptionSelectedRelic.name] then
		descriptionText = getRelicDescription(localPlayer, descriptionSelectedRelic.name) or ""
	end

	-- The shared description size (see DESCRIPTION_REFERENCE_RELIC): the
	-- reference card's fit, or this card's if it is the longer one. Re-run
	-- when the label resizes or the text changes.
	React.useEffect(function()
		local label = descriptionLabelRef.current
		if not label then
			return
		end
		local cancelled = false
		local function refit()
			task.spawn(function()
				local box = label.AbsoluteSize
				if box.X < 1 or box.Y < 1 then
					return
				end
				local reference = getRelicDescription(localPlayer, DESCRIPTION_REFERENCE_RELIC) or ""
				local size = fitTextSize(reference, box)
				if descriptionText ~= "" then
					size = math.min(size, fitTextSize(descriptionText, box))
				end
				if not cancelled then
					setDescriptionTextSize(size)
				end
			end)
		end
		refit()
		local connection = label:GetPropertyChangedSignal("AbsoluteSize"):Connect(refit)
		return function()
			cancelled = true
			connection:Disconnect()
		end
	end, { descriptionText })

	return React.createElement("Frame", {
		ref = containerRef,

		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = CONTAINER_SHOWN_POSITION,
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Visible = true,
	}, {
		BackgroundBlurFrame = React.createElement("Frame", {
			ref = backgroundFrameRef,

			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(2, 2),
			BackgroundColor3 = Color3.fromRGB(25, 25, 25),
			BackgroundTransparency = 0.5,
			ZIndex = -1,
		}),

		-- Click-away close: a clear full-screen button under the tray that
		-- shuts it on any click outside the panel, the card or the toggle
		-- (each of those sits above it and sinks its own clicks). Only
		-- present while open, so it never eats input with the tray shut.
		-- Every close path runs through `visible`, so a Merchant / Forge
		-- session ends here exactly as it does on the toggle.
		ClickAwayButton = React.createElement("TextButton", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(2, 2),
			BackgroundTransparency = 1,
			AutoButtonColor = false,
			Text = "",
			Visible = visible,
			ZIndex = -1,
			[React.Event.Activated] = function()
				setVisible(false)
			end,
		}),

		-- The card sits just right of the panel (2026-10-31), past every
		-- extra column (2026-11-12).
		RelicDescriptionFrame = React.createElement("CanvasGroup", {
			ref = descriptionFrameRef,

			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = descriptionShownPosition(extraRef.current),
			Size = UDim2.fromScale(0.424019, 0.291),
			BackgroundTransparency = 1,
		}, {
			-- Sinks clicks on the card's empty space so they do not reach
			-- ClickAwayButton. Only while the card is showing: a faded-out
			-- card must not leave an invisible dead zone.
			ClickBlocker = React.createElement("TextButton", {
				Size = UDim2.fromScale(1, 1),
				BackgroundTransparency = 1,
				AutoButtonColor = false,
				Text = "",
				Visible = visible and selectedRelic ~= nil,
				ZIndex = 0,
			}),

			ContainerFrame = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.467, 0.5),
				Size = UDim2.fromScale(0.914, 0.914),
				BackgroundColor3 = Color3.fromRGB(22, 22, 22),
				BackgroundTransparency = 1,
			}, {
				BackgroundFrame = React.createElement("Frame", {
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.fromScale(0.536, 0.434178),
					Size = UDim2.fromScale(1.071, 0.838356),
					BackgroundColor3 = Color3.fromRGB(20, 31, 40),
					BackgroundTransparency = 0,
					ZIndex = -1,
				}, {
					UICorner = React.createElement("UICorner", {
						CornerRadius = UDim.new(0.05, 0),
					}),

					-- A soft top-down shade on the plate (the 2026-10-22 export).
					UIGradient = React.createElement("UIGradient", {
						Color = ColorSequence.new({
							ColorSequenceKeypoint.new(0, Color3.new(1, 1, 1)),
							ColorSequenceKeypoint.new(1, Color3.fromRGB(184, 184, 184)),
						}),
						Rotation = 90,
					}),

					-- The bag's panel stroke and its shine ring (ShineRing), so the
					-- card matches the tray panel beside it.
					UIStroke = React.createElement("UIStroke", {
						Color = Color3.fromRGB(43, 65, 85),
						StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize,
						Thickness = 0.008,
					}),

					ShineRing = React.createElement(ShineRing, {
						color = Color3.fromRGB(43, 65, 85),
						thickness = 0.015,
						cornerRadius = UDim.new(0.05, 0),
						active = visible and selectedRelic ~= nil,
					}),
				}),

				-- ShadowBackgroundImageLabelFrame = React.createElement("ImageLabel", {
				-- 	AnchorPoint = Vector2.new(0.5, 0.5),
				-- 	Position = UDim2.fromScale(0.536, 0.457319),
				-- 	Size = UDim2.fromScale(1.071, 0.884638),
				-- 	Image = "rbxassetid://6096768861",
				-- 	BackgroundTransparency = 1,
				-- 	ImageColor3 = Color3.fromRGB(255, 255, 255),
				-- 	ImageTransparency = 0.35,
				-- 	ScaleType = Enum.ScaleType.Stretch,
				-- 	ZIndex = -1,
				-- }, {
				-- 	UICorner = React.createElement("UICorner", {
				-- 		CornerRadius = UDim.new(0.05, 0),
				-- 	}),
				-- }),

				RelicRarityTextLabel = React.createElement("TextLabel", {
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.fromScale(0.348, 0.291),
					Size = UDim2.fromScale(0.168, 0.09),
					Text = descriptionSelectedRelic
							and RelicData[descriptionSelectedRelic.name]
							and RelicData[descriptionSelectedRelic.name].rarity
						or "",
					TextColor3 = descriptionSelectedRelic
							and RelicData[descriptionSelectedRelic.name]
							and RelicData[descriptionSelectedRelic.name].color
						or Color3.fromRGB(255, 255, 255),
					TextScaled = true,
					BackgroundTransparency = 1,
					FontFace = Font.new(
						"rbxasset://fonts/families/Montserrat.json",
						Enum.FontWeight.Bold,
						Enum.FontStyle.Normal
					),
					TextXAlignment = Enum.TextXAlignment.Left,
				}),

				-- One label, one size for every relic (DESCRIPTION_REFERENCE_RELIC).
				RelicDescriptionTextLabel = React.createElement("TextLabel", {
					ref = descriptionLabelRef,
					AnchorPoint = Vector2.new(0.5, 0),
					Position = UDim2.fromScale(0.64, 0.345),
					Size = UDim2.fromScale(0.752, 0.205),
					Text = descriptionText,
					TextColor3 = Color3.fromRGB(255, 255, 255),
					TextScaled = false,
					TextSize = descriptionTextSize,
					TextWrapped = true,
					RichText = true,
					TextXAlignment = Enum.TextXAlignment.Left,
					TextYAlignment = Enum.TextYAlignment.Top,
					BackgroundTransparency = 1,
					FontFace = DESCRIPTION_FONT,
				}),

				RelicNameTextLabel = React.createElement("TextLabel", {
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.fromScale(0.587, 0.186),
					Size = UDim2.fromScale(0.646, 0.1),
					Text = descriptionSelectedRelic and descriptionSelectedRelic.name or "",
					TextColor3 = Color3.fromRGB(255, 255, 255),
					TextScaled = true,
					BackgroundTransparency = 1,
					FontFace = Font.new(
						"rbxasset://fonts/families/Montserrat.json",
						Enum.FontWeight.Bold,
						Enum.FontStyle.Normal
					),
					TextXAlignment = Enum.TextXAlignment.Left,
				}),

				RelicEntryFrame = React.createElement("Frame", {
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.fromScale(0.138, 0.302),
					Size = UDim2.fromScale(0.158, 0.364),
					BackgroundTransparency = 1,
				}, {
					UIAspectRatioConstraint = React.createElement("UIAspectRatioConstraint", {
						AspectRatio = 1,
					}),

					RelicEntryContainer = React.createElement(RelicEntryContainer, {
						relicName = descriptionSelectedRelic and descriptionSelectedRelic.name or "",
						count = descriptionSelectedRelic and descriptionSelectedRelic.count or 0,
					}),
				}),

				-- The action bar lives in the old Set Bonus slot (the mock keeps
				-- the SetBonusFrame name). Drop leads the row and is always live
				-- outside an event session (see dropLive). Reforge always renders:
				-- dim identity tint + "???" outside the Forge's anvil, full color +
				-- real label inside it. (Sell left 2026-11-13: relics are never sold,
				-- only dropped, and the two buttons share the row.)
				SetBonusFrame = React.createElement("Frame", {
					AnchorPoint = Vector2.new(0.5, 0.5),
					BackgroundColor3 = Color3.fromRGB(45, 70, 90),
					Position = UDim2.fromScale(0.562, 0.676),
					Size = UDim2.fromScale(0.595079, 0.247),
				}, {
					UICorner = React.createElement("UICorner", {
						CornerRadius = UDim.new(0.1, 0),
					}),

					UIListLayout = React.createElement("UIListLayout", {
						FillDirection = Enum.FillDirection.Horizontal,
						HorizontalAlignment = Enum.HorizontalAlignment.Left,
						Padding = UDim.new(0.025, 0),
						SortOrder = Enum.SortOrder.LayoutOrder,
						VerticalAlignment = Enum.VerticalAlignment.Center,
					}),

					UIPadding = React.createElement("UIPadding", {
						PaddingBottom = UDim.new(0.05, 0),
						PaddingLeft = UDim.new(0.025, 0),
						PaddingTop = UDim.new(0.05, 0),
					}),

					-- FIRST in the row and live outside an event session: tosses
					-- the selected relic onto the floor ahead of the player as a
					-- PUBLIC drop anyone can pick up (RelicService.DropRelic). Greyed
					-- and inert for a Cursed relic, matching the Reforge masking
					-- language.
					Drop = React.createElement("TextButton", {
						AnchorPoint = Vector2.new(0.5, 0.5),
						AutoButtonColor = dropLive,
						BackgroundColor3 = if dropLive
							then Color3.fromRGB(255, 99, 99)
							elseif selectedIsCursed then DROP_LOCKED_BACKGROUND
							else greyed(Color3.fromRGB(255, 99, 99)),
						FontFace = Font.new(
							"rbxasset://fonts/families/GothamSSm.json",
							Enum.FontWeight.Bold,
							Enum.FontStyle.Normal
						),
						LayoutOrder = 1,
						Size = UDim2.fromScale(0.46, 0.739654),
						Text = if selectedIsCursed then "Cursed" else "Drop",
						TextColor3 = if dropLive
							then Color3.fromRGB(79, 34, 30)
							elseif selectedIsCursed then DROP_LOCKED_COLOR
							else greyed(Color3.fromRGB(79, 34, 30)),
						TextScaled = true,
						-- Only the locked label carries a stroke: it is the one
						-- unavailable state meant to be READ rather than glossed over.
						TextStrokeTransparency = if selectedIsCursed then 1 else 1,
						[React.Event.Activated] = function()
							if not dropLive then
								return -- greyed; inert
							end
							local relicName = descriptionSelectedRelic and descriptionSelectedRelic.name
							if relicName and props.onDropRelic then
								task.spawn(function()
									props.onDropRelic(relicName)
								end)
								-- Deselect only: the description effect retracts
								-- the card and clears its content AFTER the fade.
								setSelectedRelic(nil)
							end
						end,
					}, {
						UIStroke = React.createElement("UIStroke", {
							ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
							-- Near-black while greyed, identity dark-red while live.
							Color = if dropLive then Color3.fromRGB(59, 20, 20) else Color3.fromRGB(25, 25, 25),
						}),
						UIPadding1 = React.createElement("UIPadding", {
							PaddingBottom = UDim.new(0.2, 0),
							PaddingTop = UDim.new(0.2, 0),
						}),
						UICorner1 = React.createElement("UICorner", {
							CornerRadius = UDim.new(0.1, 0),
						}),
					}),

					Reroll = React.createElement("TextButton", {
						AnchorPoint = Vector2.new(0.5, 0.5),
						AutoButtonColor = reforgeMode,
						BackgroundColor3 = if reforgeMode
							then Color3.fromRGB(93, 150, 255)
							else greyed(Color3.fromRGB(93, 150, 255)),
						FontFace = Font.new(
							"rbxasset://fonts/families/GothamSSm.json",
							Enum.FontWeight.Bold,
							Enum.FontStyle.Normal
						),
						LayoutOrder = 2,
						Size = UDim2.fromScale(0.46, 0.739654),
						Text = if reforgeMode then "Reforge" else "???",
						TextColor3 = if reforgeMode
							then Color3.fromRGB(24, 60, 79)
							else greyed(Color3.fromRGB(24, 60, 79)),
						TextScaled = true,
						[React.Event.Activated] = function()
							if not reforgeMode then
								return -- masked outside a Forge session; inert
							end
							local relicName = descriptionSelectedRelic and descriptionSelectedRelic.name
							if relicName and props.onReforgeRelic then
								task.spawn(function()
									props.onReforgeRelic(relicName)
								end)
								-- Deselect only: the description effect retracts
								-- the card and clears its content AFTER the fade.
								setSelectedRelic(nil)
							end
						end,
					}, {
						UIPadding1 = React.createElement("UIPadding", {
							PaddingBottom = UDim.new(0.2, 0),
							PaddingTop = UDim.new(0.2, 0),
						}),
						UICorner1 = React.createElement("UICorner", {
							CornerRadius = UDim.new(0.1, 0),
						}),
						UIStroke = React.createElement("UIStroke", {
							ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
							-- Identity stroke while the Forge session is live, the
							-- near-black masked stroke otherwise.
							Color = if reforgeMode then Color3.fromRGB(59, 20, 20) else Color3.fromRGB(25, 25, 25),
						}),
					}),
				}),
			}),
		}),

		-- The columns, side by side (RelicListFragment: six boxes each, box
		-- height 0.14 + gap 0.045 of the list, the 2026-10-31 export). The
		-- list shares the panel's rect and its left edge; every extra column
		-- widens both by one column (`extraWidth`), centred, so the first
		-- column sits exactly where the single column always did.
		RelicListFrame = React.createElement("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = extraWidth:map(function(width: number)
				return UDim2.new(0.058, width / 2, 0.496712, 0)
			end),
			Size = extraWidth:map(function(width: number)
				return UDim2.new(0.095, width, LIST_HEIGHT, 0)
			end),
			BackgroundTransparency = 1,
			ZIndex = 1,
		}, {
			UIListLayout = React.createElement("UIListLayout", {
				SortOrder = Enum.SortOrder.LayoutOrder,
				FillDirection = Enum.FillDirection.Horizontal,
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				VerticalAlignment = Enum.VerticalAlignment.Center,
			}),

			RelicListFragment = React.createElement(RelicListFragment.Component, {
				relicData = relicData,
				columnWidth = if screenHeight > 0 then columnWidth else 0,
				selectedRelic = selectedRelic,

				setSelectedRelic = function(selectedData: { [any]: any })
					setSelectedRelic(selectedData)
				end,
			}),
		}),

		-- One slim column for the six boxes (2026-10-31), hugging the
		-- left edge, widened by every extra column (2026-11-12).
		RelicBackgroundFrame = React.createElement("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = extraWidth:map(function(width: number)
				return UDim2.new(0.058, width / 2, 0.499879, 0)
			end),
			Size = extraWidth:map(function(width: number)
				return UDim2.new(0.095, width, 0.6087, 0)
			end),
			BackgroundColor3 = Color3.fromRGB(20, 31, 40),
			BackgroundTransparency = 0,
			ZIndex = 0,
		}, {
			-- Sinks clicks on the panel's gaps so they do not reach
			-- ClickAwayButton. The tiles (RelicListFrame) draw above it.
			ClickBlocker = React.createElement("TextButton", {
				Size = UDim2.fromScale(1, 1),
				BackgroundTransparency = 1,
				AutoButtonColor = false,
				Text = "",
				ZIndex = 0,
			}),

			-- The animated shine ring (ShineRing), over the static stroke.
			ShineRing = React.createElement(ShineRing, {
				color = Color3.fromRGB(43, 65, 85),
				thickness = 0.02,
				cornerRadius = UDim.new(0.085, 0),
				active = visible,
			}),
			UICorner = React.createElement("UICorner", {
				CornerRadius = UDim.new(0.085, 0),
			}),

			-- A soft top-down shade on the plate (the 2026-10-22 export).
			UIGradient = React.createElement("UIGradient", {
				Color = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.new(1, 1, 1)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(184, 184, 184)),
				}),
				Rotation = 90,
			}),

			-- The bevel is kept but off (the 2026-10-22 export): the panel wears
			-- the bag's blue-grey stroke instead.
			ShadowBackgroundImageLabel = React.createElement("ImageLabel", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromScale(1, 1),
				Image = "rbxassetid://6096768861",
				BackgroundTransparency = 1,
				ImageTransparency = 0.35,
				ScaleType = Enum.ScaleType.Stretch,
				Visible = false,
				ZIndex = 2,
			}, {
				UICorner = React.createElement("UICorner", {
					CornerRadius = UDim.new(0.12, 0),
				}),
			}),

			UIStroke = React.createElement("UIStroke", {
				Color = Color3.fromRGB(43, 65, 85),
				StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize,
				Thickness = 0.005,
			}, {
				UIGradient = React.createElement("UIGradient", {
					Color = ColorSequence.new({
						ColorSequenceKeypoint.new(0, Color3.new(1, 1, 1)),
						ColorSequenceKeypoint.new(0.141623, Color3.fromRGB(206, 206, 206)),
						ColorSequenceKeypoint.new(0.499136, Color3.fromRGB(211, 211, 211)),
						ColorSequenceKeypoint.new(0.777202, Color3.fromRGB(206, 206, 206)),
						ColorSequenceKeypoint.new(1, Color3.new(1, 1, 1)),
					}),
					Rotation = 45,
					Transparency = NumberSequence.new({
						NumberSequenceKeypoint.new(0, 0),
						NumberSequenceKeypoint.new(0.625156, 0),
						NumberSequenceKeypoint.new(1, 0),
					}),
				}),
			}),
		}),
	})
end

return Container
