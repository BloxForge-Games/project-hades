--[[
     Module: Container.lua
     Description:
     Props screen UI
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")
local TweenService = game:GetService("TweenService")

local React = require(ReplicatedStorage.Submodules.Core.Packages.React)
local RelicListFragment = require(script.Parent.RelicListFragment)
local RelicEntryContainer = require(script.Parent.RelicEntryContainer)
local RelicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicData)
local ItemRarity = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ItemRarity)
local RelicCapData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicCapData)
local getRelicDescription = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Relic.getRelicDescription)
local tweenGui = require(ReplicatedStorage.Submodules.Core.Shared.Functions.UI.tweenGui)
local shineStroke = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.shineStroke)
local ShineRing = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.ShineRing)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)

local localPlayer = Players.LocalPlayer

--[ Selection ]--

-- The tray's selection is ONE of two shapes, and the description card
-- renders either through the same fade / slide:
--   { name = relicName, count = n }      an owned relic.
--   { locked = true, slotIndex = n }     a LOCKED slot (past the run's open
--                                        count). It has no name, so every
--                                        handler that acts on a relic must
--                                        check `locked` first -- Sell,
--                                        Reforge and Drop all refuse it.
-- The toggle plate's ring (see the effect in Container): the inventory
-- tiles' animated shine outline in the tray's accent blue, at the plate
-- stroke's own thickness, for as long as the toggle exists.
local TOGGLE_RING_COLOR = Color3.fromRGB(105, 158, 186)
local TOGGLE_RING_THICKNESS = 0.04
local LOCKED_SLOT_NAME = "Relic Slot"
local LOCKED_SLOT_RARITY = "Locked"
local LOCKED_SLOT_RARITY_COLOR = Color3.fromRGB(141, 141, 141)
-- Rich text, the relic-description blue for the two nouns.
-- Every relic description renders at ONE size (2026-10-29): TextScaled
-- shrank the longer ones to squeeze them in, so cards disagreed. The size
-- is the largest at which the LONGEST card -- DESCRIPTION_REFERENCE_RELIC's,
-- the length budget every description is written to -- fits the label,
-- measured with TextService for the label's live size, so it follows the
-- card on any screen, phones included. A description longer than that
-- budget shrinks to fit instead of spilling.
local DESCRIPTION_REFERENCE_RELIC = "Spartan Sword and Shield"
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

local LOCKED_SLOT_DESCRIPTION =
	"You can unlock this <font color='rgb(108,196,255)'>Relic Slot</font> by purchasing it from the <font color='rgb(108,196,255)'>Merchant Shop</font> event."
-- The card's own copy of the locked box sits on a lighter panel than the
-- tray, so it carries its own tints, and drops the shadow.
local LOCKED_CARD_LOOK = {
	background = Color3.fromRGB(52, 80, 102),
	icon = Color3.fromRGB(20, 31, 40),
	shadowVisible = false,
}
-- Drop on a locked slot masks itself like Sell / Reroll do ("???"), in a
-- dim red that reads as unavailable rather than refused.
local DROP_MASKED_BACKGROUND = Color3.fromRGB(122, 47, 47)
local DROP_MASKED_COLOR = Color3.fromRGB(61, 26, 23)

--[ Layout ]--

-- The description card slides RIGHT as it fades in. Authored positions --
-- keep these two in step with the card's own Position below, which is the
-- resting pose it is re-snapped to before each slide.
local DESCRIPTION_HIDDEN_POSITION = UDim2.fromScale(0.444, 0.372)
local DESCRIPTION_SHOWN_POSITION = UDim2.fromScale(0.48401, 0.372)
-- The appear: the slide keeps its quick-then-settle Quint, but the fade
-- rides a Sine curve -- a Quint fade front-loads two thirds of the
-- opacity into the first few frames and reads as a snap. The retract
-- (below) stays fast on purpose.
local DESCRIPTION_APPEAR_SLIDE_SECONDS = 0.75
local DESCRIPTION_APPEAR_FADE_SECONDS = 0.6

-- Tray slide: the whole Container shifts left to park the relic list
-- off-screen, and the toggle button counter-shifts so it stays reachable.
local CONTAINER_SHOWN_POSITION = UDim2.fromScale(0.5, 0.5)
local CONTAINER_HIDDEN_POSITION = UDim2.fromScale(0.27, 0.5)
local TOGGLE_SHOWN_POSITION = UDim2.fromScale(0.222694, 0.486962)
local TOGGLE_HIDDEN_POSITION = UDim2.fromScale(0.272694, 0.486962)

local taskConnection = nil

local function Container(props: any)
	local visible, setVisible = React.useState(false)
	local selectedRelic, setSelectedRelic = React.useState(nil)
	local descriptionSelectedRelic, setDescriptionSelectedRelic = React.useState(nil)
	local notificationVisible, setNotificationVisible = React.useState(false)
	-- Merchant sell session. Only ever true between the Merchant's
	-- "sell relics" dialogue option and this tray closing.
	local sellMode, setSellMode = React.useState(false)
	-- Forge reforge session. Mutually exclusive with sellMode in practice
	-- (the two events cannot run at once), but tracked separately so each
	-- button only ever answers to its own event.
	local reforgeMode, setReforgeMode = React.useState(false)
	-- The toggle button hides for a cutscene (2026-10-23), following the
	-- local character's CutscenePlaying attribute the same way the topbar
	-- icons do. The tray itself is already slid shut by the Windows scope
	-- lock; this is the one piece of relic chrome that stayed on screen.
	--
	-- EXCEPT during a sell / reforge session: the Merchant and the Forge
	-- run their dialogue under the same cutscene flag, force the tray open,
	-- and wait on the tray CLOSING to move their "..." node on. The toggle
	-- is the only way to close it, so hiding it there trapped the player
	-- in the conversation (the first cut of this did exactly that).
	local cutscenePlaying, setCutscenePlaying = React.useState(false)
	-- The toggle also hides while the local player is downed or dead
	-- (LifeController's death HUD hide, through toggleVisibleSignal).
	local toggleAllowed, setToggleAllowed = React.useState(true)

	React.useEffect(function()
		local signal = props.toggleVisibleSignal
		if not signal then
			return nil
		end
		local connection = signal:Connect(function(allowed: boolean)
			setToggleAllowed(allowed)
		end)
		return function()
			connection:Disconnect()
		end
	end, {})

	React.useEffect(function()
		local connections: { RBXScriptConnection } = {}
		local function bind(character: Model)
			local function refresh()
				setCutscenePlaying(character:GetAttribute(Attributes.CutscenePlaying) == true)
			end
			table.insert(connections, character:GetAttributeChangedSignal(Attributes.CutscenePlaying):Connect(refresh))
			refresh()
		end
		table.insert(connections, localPlayer.CharacterAdded:Connect(bind))
		if localPlayer.Character then
			bind(localPlayer.Character)
		end
		return function()
			for _, connection in connections do
				connection:Disconnect()
			end
		end
	end, {})

	-- Unavailable buttons keep a DIM of their identity color (gold Sell,
	-- blue Reforge) and mask their label as "???" until their event
	-- makes them live. Inert clicks do NOTHING.
	local function greyed(color: Color3): Color3
		return color:Lerp(Color3.fromRGB(50, 50, 50), 0.55)
	end

	-- DROP is live whenever no event session owns the row, the selection is
	-- a relic (not a locked slot) and that relic is not Cursed (a curse is
	-- the price of its payoff, so it is the one thing you cannot shed).
	-- Greyed like the others when it is not.
	local selectedIsLocked = descriptionSelectedRelic ~= nil and descriptionSelectedRelic.locked == true
	local selectedRelicName = if selectedIsLocked
		then nil
		else descriptionSelectedRelic and descriptionSelectedRelic.name
	local selectedIsCursed = selectedRelicName ~= nil
		and RelicData[selectedRelicName] ~= nil
		and RelicData[selectedRelicName].rarity == ItemRarity.Cursed
	local dropLive = not sellMode and not reforgeMode and not selectedIsCursed and not selectedIsLocked

	-- A Cursed relic reads LOCKED rather than masked. The other unavailable
	-- buttons say "???" in a dim tint, because they are waiting on an event
	-- that will eventually arrive — Sell needs the Merchant, Reforge needs
	-- the Forge. Dropping a curse is not pending anything: it is refused
	-- outright, forever, so it states the reason legibly instead of hiding
	-- it behind a placeholder the player is invited to keep checking.
	local DROP_LOCKED_BACKGROUND = Color3.fromRGB(142, 72, 72)
	local DROP_LOCKED_COLOR = Color3.fromRGB(80, 7, 7)

	local relicData = props.relicData
	-- OPEN slots this run (the Player's RelicSlots attribute, read by the
	-- controller). Boxes past it are locked.
	local relicSlots = props.relicSlots or RelicCapData.DefaultSlots

	local containerRef = React.useRef(nil)
	local backgroundFrameRef = React.useRef(nil)
	local descriptionFrameRef = React.useRef(nil)
	local descriptionLabelRef = React.useRef(nil)
	local descriptionTextSize, setDescriptionTextSize = React.useState(14)
	local toggleButtonRef = React.useRef(nil)
	local toggleRingAnchorRef = React.useRef(nil)
	local notificationButtonRef = React.useRef(nil)

	local visibleRef = React.useRef(visible)

	-- The toggle's ring (TOGGLE_RING_*).
	React.useEffect(function()
		local anchor = toggleRingAnchorRef.current
		if not anchor then
			return nil
		end
		return shineStroke(anchor, TOGGLE_RING_THICKNESS, TOGGLE_RING_COLOR)
	end, {})
	local selectedRelicRef = React.useRef(selectedRelic)

	React.useEffect(function()
		setNotificationVisible(true)
	end, { relicData })

	-- A selected LOCKED slot that has since become open (a future unlock
	-- raised the count) is no longer the thing the card describes: clear
	-- it, and let the card retract as it does for any deselect.
	React.useEffect(function()
		if selectedRelic and selectedRelic.locked and selectedRelic.slotIndex <= relicSlots then
			setSelectedRelic(nil)
		end
	end, { relicData, relicSlots })

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
					descriptionFrameRef.current.Position = DESCRIPTION_HIDDEN_POSITION

					tweenGui.position(
						descriptionFrameRef.current,
						DESCRIPTION_SHOWN_POSITION,
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
				DESCRIPTION_HIDDEN_POSITION,
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

			tweenGui.position(
				toggleButtonRef.current,
				TOGGLE_SHOWN_POSITION,
				Enum.EasingDirection.Out,
				Enum.EasingStyle.Quint,
				0.5,
				true
			)
		else
			tweenGui.position(
				containerRef.current,
				CONTAINER_HIDDEN_POSITION,
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

			tweenGui.position(
				toggleButtonRef.current,
				TOGGLE_HIDDEN_POSITION,
				Enum.EasingDirection.Out,
				Enum.EasingStyle.Quint,
				0.25,
				true
			)
		end
	end, { visible })

	React.useEffect(function()
		-- Stopped on unmount; the loop used to outlive the component.
		local cancelled = false
		task.spawn(function()
			while not cancelled and task.wait(1) do
				local button = notificationButtonRef.current
				if not button then
					continue
				end
				TweenService
					:Create(
						button,
						TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
						{ Rotation = 15 }
					)
					:Play()
				task.wait(0.15)
				TweenService:Create(
					button,
					TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
					{ Rotation = -15 }
				):Play()
				task.wait(0.15)
				TweenService
					:Create(
						button,
						TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
						{ Rotation = 15 }
					)
					:Play()
				task.wait(0.15)
				TweenService:Create(
					button,
					TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
					{ Rotation = -15 }
				):Play()
				task.wait(0.15)
				TweenService
					:Create(
						button,
						TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
						{ Rotation = 0 }
					)
					:Play()
			end
		end)
		return function()
			cancelled = true
		end
	end, {})

	-- Resolve the description for the currently-hovered relic ONCE per
	-- render and reuse across the 4 label / visibility sites below.
	-- Routes through getRelicDescription so level-scaled relics (Super
	-- Stomp Boots, Summer Fireworks, Trick Or Trap) show the concrete
	-- damage at the player's current level instead of the static
	-- "(N × PlayerLevel)" formula text. Static relics fall back to
	-- RelicData[name].description unchanged.
	local descriptionText = ""
	if selectedIsLocked then
		descriptionText = LOCKED_SLOT_DESCRIPTION
	elseif descriptionSelectedRelic and RelicData[descriptionSelectedRelic.name] then
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

		RelicDescriptionFrame = React.createElement("CanvasGroup", {
			ref = descriptionFrameRef,

			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.48401, 0.372),
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
					Text = if selectedIsLocked
						then LOCKED_SLOT_RARITY
						else descriptionSelectedRelic
								and RelicData[descriptionSelectedRelic.name]
								and RelicData[descriptionSelectedRelic.name].rarity
							or "",
					TextColor3 = if selectedIsLocked
						then LOCKED_SLOT_RARITY_COLOR
						else descriptionSelectedRelic
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
					Text = if selectedIsLocked
						then LOCKED_SLOT_NAME
						else descriptionSelectedRelic and descriptionSelectedRelic.name or "",
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
						relicName = if selectedIsLocked
							then ""
							else descriptionSelectedRelic and descriptionSelectedRelic.name or "",
						count = if selectedIsLocked
							then 0
							else descriptionSelectedRelic and descriptionSelectedRelic.count or 0,
						locked = selectedIsLocked,
						lockedLook = LOCKED_CARD_LOOK,
					}),
				}),

				-- The action bar lives in the old Set Bonus slot (the mock keeps
				-- the SetBonusFrame name). Drop leads the row and is always live
				-- outside an event session (see dropLive). Sell and Reforge
				-- always render: dim identity tint + "???" while their event is
				-- absent, full color + real label inside it (Sell = the
				-- Merchant's sell session; Reforge = the Forge's anvil).
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
					-- and inert for a Cursed relic, matching the Sell/Reforge
					-- masking language.
					Drop = React.createElement("TextButton", {
						AnchorPoint = Vector2.new(0.5, 0.5),
						AutoButtonColor = dropLive,
						BackgroundColor3 = if dropLive
							then Color3.fromRGB(255, 99, 99)
							elseif selectedIsLocked then DROP_MASKED_BACKGROUND
							elseif selectedIsCursed then DROP_LOCKED_BACKGROUND
							else greyed(Color3.fromRGB(255, 99, 99)),
						FontFace = Font.new(
							"rbxasset://fonts/families/GothamSSm.json",
							Enum.FontWeight.Bold,
							Enum.FontStyle.Normal
						),
						LayoutOrder = 1,
						Size = UDim2.fromScale(0.332418, 0.739654),
						Text = if selectedIsLocked then "???" elseif selectedIsCursed then "Locked" else "Drop",
						TextColor3 = if dropLive
							then Color3.fromRGB(79, 34, 30)
							elseif selectedIsLocked then DROP_MASKED_COLOR
							elseif selectedIsCursed then DROP_LOCKED_COLOR
							else greyed(Color3.fromRGB(79, 34, 30)),
						TextScaled = true,
						-- Only the locked label carries a stroke: it is the one
						-- unavailable state meant to be READ rather than glossed over.
						TextStrokeTransparency = if selectedIsCursed then 1 else 1,
						[React.Event.Activated] = function()
							if not dropLive or selectedIsLocked then
								return -- greyed, or a locked slot; inert
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

					Sell = React.createElement("TextButton", {
						AnchorPoint = Vector2.new(0.5, 0.5),
						AutoButtonColor = sellMode,
						BackgroundColor3 = if sellMode
							then Color3.fromRGB(255, 170, 0)
							else greyed(Color3.fromRGB(255, 170, 0)),
						FontFace = Font.new(
							"rbxasset://fonts/families/GothamSSm.json",
							Enum.FontWeight.Bold,
							Enum.FontStyle.Normal
						),
						LayoutOrder = 2,
						Size = UDim2.fromScale(0.291985, 0.739654),
						Text = if sellMode then "Sell" else "???",
						TextColor3 = if sellMode then Color3.fromRGB(79, 53, 0) else greyed(Color3.fromRGB(79, 53, 0)),
						TextScaled = true,
						[React.Event.Activated] = function()
							if not sellMode or selectedIsLocked then
								return -- greyed outside a sell session, or a locked slot; inert
							end
							local relicName = descriptionSelectedRelic and descriptionSelectedRelic.name
							if relicName and props.onSellRelic then
								task.spawn(function()
									props.onSellRelic(relicName)
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
							-- Identity dark-red while live (sell session), black while greyed.
							Color = if sellMode then Color3.fromRGB(59, 20, 20) else Color3.fromRGB(25, 25, 25),
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
						LayoutOrder = 3,
						Size = UDim2.fromScale(0.299576, 0.739654),
						Text = if reforgeMode then "Reforge" else "???",
						TextColor3 = if reforgeMode
							then Color3.fromRGB(24, 60, 79)
							else greyed(Color3.fromRGB(24, 60, 79)),
						TextScaled = true,
						[React.Event.Activated] = function()
							if not reforgeMode or selectedIsLocked then
								return -- masked outside a Forge session, or a locked slot; inert
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

		-- Sized for the slot ceiling (Shared/Data/RelicCapData.MaxSlots),
		-- wrapped by the list layout. RelicListFragment draws exactly that
		-- many boxes -- owned, empty, then locked past the run's open count.
		RelicListFrame = React.createElement("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.161879, 0.496712),
			Size = UDim2.fromScale(0.287337, 0.512406),
			BackgroundTransparency = 1,
			ZIndex = 1,
		}, {
			-- Square, so the 3 x 5 wrap of square boxes fills it exactly.
			UIAspectRatioConstraint = React.createElement("UIAspectRatioConstraint", {
				AspectRatio = 1,
			}),

			-- FillDirection / alignments are left at their defaults (Vertical,
			-- Left, Top) -- the authored layout relies on exactly those.
			UIListLayout = React.createElement("UIListLayout", {
				SortOrder = Enum.SortOrder.LayoutOrder,
				Padding = UDim.new(0.05, 0),
				Wraps = true,
			}),

			RelicListFragment = React.createElement(RelicListFragment, {
				relicData = relicData,
				relicSlots = relicSlots,
				selectedRelic = selectedRelic,

				setSelectedRelic = function(selectedData: { [any]: any })
					setSelectedRelic(selectedData)
				end,
			}),
		}),

		ToggleButtonFrame = React.createElement("Frame", {
			ref = toggleButtonRef,

			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = TOGGLE_SHOWN_POSITION,
			Size = UDim2.fromScale(0.035, 0.062),
			BackgroundTransparency = 1,
			Visible = toggleAllowed and (not cutscenePlaying or sellMode or reforgeMode),
			ZIndex = 1,
		}, {
			UIAspectRatioConstraint = React.createElement("UIAspectRatioConstraint", {
				AspectRatio = 1,
			}),

			NotificationButtonFrame = React.createElement("Frame", {
				ref = notificationButtonRef,

				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.968, -0.01),
				Rotation = -15,
				Size = UDim2.fromScale(0.575, 0.575),
				BackgroundTransparency = 0,
				BackgroundColor3 = Color3.fromRGB(255, 102, 102),
				ZIndex = 6,
				Visible = notificationVisible,
			}, {
				UICorner = React.createElement("UICorner", {
					CornerRadius = UDim.new(1, 0),
				}),

				UIStroke = React.createElement("UIStroke", {
					ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
					Color = Color3.fromRGB(22, 22, 22),
					StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize,
					Thickness = 0.075,
					ZIndex = 6,
				}),

				TextLabel = React.createElement("TextLabel", {
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.fromScale(0.5, 0.5),
					Size = UDim2.fromScale(0.85, 0.85),
					Text = "!",
					TextColor3 = Color3.fromRGB(255, 255, 255),
					TextScaled = true,
					BackgroundTransparency = 1,
					FontFace = Font.new(
						"rbxasset://fonts/families/Montserrat.json",
						Enum.FontWeight.Bold,
						Enum.FontStyle.Normal
					),
				}),
			}),

			-- The tray toggle wears the toolbar's slot plate (2026-10-22): the
			-- same flat blue-grey square, black border and bevel overlay as a
			-- weapon slot, with the relic icon in it and no number.
			ToggleImageButton = React.createElement("ImageButton", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromScale(1.15, 1.15),
				BackgroundColor3 = Color3.fromRGB(43, 65, 85),
				BackgroundTransparency = 0,
				Image = "",
				ImageColor3 = Color3.fromRGB(255, 255, 255),
				ImageTransparency = 0,
				ScaleType = Enum.ScaleType.Stretch,
				ZIndex = 6,

				[React.Event.Activated] = function()
					setNotificationVisible(false)

					setVisible(not visible)
				end,
			}, {
				UIAspectRatioConstraint = React.createElement("UIAspectRatioConstraint", {
					AspectRatio = 1,
					AspectType = Enum.AspectType.FitWithinMaxSize,
				}),

				UICorner = React.createElement("UICorner", {
					CornerRadius = UDim.new(0.1, 0),
				}),

				UIStroke = React.createElement("UIStroke", {
					ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
					Color = Color3.fromRGB(0, 0, 0),
					StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize,
					Thickness = 0.04,
					ZIndex = 6,
				}),

				-- The ring's anchor (see TOGGLE_RING_*): a child frame's stroke
				-- draws above the plate's own black border.
				RingAnchor = React.createElement("Frame", {
					ref = toggleRingAnchorRef,
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.fromScale(0.5, 0.5),
					Size = UDim2.fromScale(1, 1),
					BackgroundTransparency = 1,
					ZIndex = 8,
				}, {
					UICorner = React.createElement("UICorner", {
						CornerRadius = UDim.new(0.1, 0),
					}),
				}),

				OuterOutlineImageLabel = React.createElement("ImageLabel", {
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.fromScale(0.5, 0.5),
					Size = UDim2.fromScale(1, 1),
					BackgroundTransparency = 1,
					Image = "rbxassetid://6096768861",
					ScaleType = Enum.ScaleType.Stretch,
					ImageColor3 = Color3.fromRGB(255, 255, 255),
					ImageTransparency = 0.6,
					ZIndex = 7,
				}, {
					UICorner = React.createElement("UICorner", {
						CornerRadius = UDim.new(0.1, 0),
					}),
				}),

				ToggleImageLabel = React.createElement("ImageLabel", {
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.fromScale(0.5, 0.5),
					Size = UDim2.fromScale(0.8, 0.8),
					BackgroundTransparency = 1,
					Image = "rbxassetid://72334652371090",
					ImageColor3 = Color3.fromRGB(255, 255, 255),
					ImageTransparency = 0,
					ScaleType = Enum.ScaleType.Fit,
					ZIndex = 5,
				}),
			}),
		}),

		RelicBackgroundFrame = React.createElement("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.106003, 0.496374),
			Size = UDim2.fromScale(0.233005, 0.580662),
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
				thickness = 0.008,
				cornerRadius = UDim.new(0.025, 0),
				active = visible,
			}),
			UICorner = React.createElement("UICorner", {
				CornerRadius = UDim.new(0.025, 0),
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
					CornerRadius = UDim.new(0.025, 0),
				}),
			}),

			UIStroke = React.createElement("UIStroke", {
				Color = Color3.fromRGB(43, 65, 85),
				StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize,
				Thickness = 0.008,
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
