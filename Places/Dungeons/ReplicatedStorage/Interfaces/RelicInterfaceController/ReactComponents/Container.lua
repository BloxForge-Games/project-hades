--[[
     Module: Container.lua
     Description:
     Props screen UI
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local React = require(ReplicatedStorage.Submodules.Core.Packages.React)
local RelicListFragment = require(script.Parent.RelicListFragment)
local RelicEntryContainer = require(script.Parent.RelicEntryContainer)
local RelicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicData)
local ItemRarity = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ItemRarity)
local getRelicDescription = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Relic.getRelicDescription)

local localPlayer = Players.LocalPlayer

--[ Layout ]--

-- The description card slides RIGHT as it fades in. Authored positions --
-- keep these two in step with the card's own Position below, which is the
-- resting pose it is re-snapped to before each slide.
local DESCRIPTION_HIDDEN_POSITION = UDim2.fromScale(0.459, 0.372)
local DESCRIPTION_SHOWN_POSITION = UDim2.fromScale(0.48401, 0.372)

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

	local containerRef = React.useRef(nil)
	local backgroundFrameRef = React.useRef(nil)
	local descriptionFrameRef = React.useRef(nil)
	local toggleButtonRef = React.useRef(nil)
	local notificationButtonRef = React.useRef(nil)

	local visibleRef = React.useRef(visible)
	local selectedRelicRef = React.useRef(selectedRelic)

	React.useEffect(function()
		setNotificationVisible(true)
	end, { relicData })

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

					descriptionFrameRef.current:TweenPosition(
						DESCRIPTION_SHOWN_POSITION,
						Enum.EasingDirection.Out,
						Enum.EasingStyle.Quint,
						0.75,
						true
					)

					TweenService:Create(
						descriptionFrameRef.current,
						TweenInfo.new(0.75, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
						{ GroupTransparency = 0 }
					):Play()
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
			descriptionFrameRef.current:TweenPosition(
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
			containerRef.current:TweenPosition(
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

			toggleButtonRef.current:TweenPosition(
				TOGGLE_SHOWN_POSITION,
				Enum.EasingDirection.Out,
				Enum.EasingStyle.Quint,
				0.5,
				true
			)
		else
			containerRef.current:TweenPosition(
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

			toggleButtonRef.current:TweenPosition(
				TOGGLE_HIDDEN_POSITION,
				Enum.EasingDirection.Out,
				Enum.EasingStyle.Quint,
				0.25,
				true
			)
		end
	end, { visible })

	React.useEffect(function()
		task.spawn(function()
			while task.wait(1) do
				TweenService:Create(
					notificationButtonRef.current,
					TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
					{ Rotation = 15 }
				):Play()
				task.wait(0.15)
				TweenService:Create(
					notificationButtonRef.current,
					TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
					{ Rotation = -15 }
				):Play()
				task.wait(0.15)
				TweenService:Create(
					notificationButtonRef.current,
					TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
					{ Rotation = 15 }
				):Play()
				task.wait(0.15)
				TweenService:Create(
					notificationButtonRef.current,
					TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
					{ Rotation = -15 }
				):Play()
				task.wait(0.15)
				TweenService:Create(
					notificationButtonRef.current,
					TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
					{ Rotation = 0 }
				):Play()
			end
		end)
	end, {})

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
	-- Strip the rich-text tags once for the length-based size-tier
	-- visibility check below — the small label hides past 47 chars and
	-- the large label hides at/under 47.
	local descriptionPlainLength = string.len(string.gsub(descriptionText, "<[^>]+>", ""))

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
			BackgroundColor3 = Color3.fromRGB(38, 38, 38),
			BackgroundTransparency = 0.5,
			ZIndex = -1,
		}),

		RelicDescriptionFrame = React.createElement("CanvasGroup", {
			ref = descriptionFrameRef,

			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.48401, 0.372),
			Size = UDim2.fromScale(0.424019, 0.291),
			BackgroundTransparency = 1,
		}, {
			ContainerFrame = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.467, 0.5),
				Size = UDim2.fromScale(0.914, 0.914),
				BackgroundColor3 = Color3.fromRGB(22, 22, 22),
				BackgroundTransparency = 1,
			}, {
				BackgroundFrame = React.createElement("Frame", {
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.fromScale(0.536, 0.457319),
					Size = UDim2.fromScale(1.071, 0.884638),
					BackgroundColor3 = Color3.fromRGB(38, 38, 38),
					BackgroundTransparency = 0,
					ZIndex = -1,
				}, {
					UICorner = React.createElement("UICorner", {
						CornerRadius = UDim.new(0.05, 0),
					}),
				}),

				ShadowBackgroundImageLabelFrame = React.createElement("ImageLabel", {
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.fromScale(0.536, 0.457319),
					Size = UDim2.fromScale(1.071, 0.884638),
					Image = "rbxassetid://6096768861",
					BackgroundTransparency = 1,
					ImageColor3 = Color3.fromRGB(255, 255, 255),
					ImageTransparency = 0.35,
					ScaleType = Enum.ScaleType.Stretch,
					ZIndex = -1,
				}, {
					UICorner = React.createElement("UICorner", {
						CornerRadius = UDim.new(0.05, 0),
					}),
				}),

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

				RelicDescriptionTextLabel = React.createElement("TextLabel", {
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.fromScale(0.64, 0.436),
					Size = UDim2.fromScale(0.752, 0.159),
					Text = descriptionText,
					TextColor3 = Color3.fromRGB(255, 255, 255),
					TextScaled = true,
					TextWrapped = true,
					RichText = true,
					TextXAlignment = Enum.TextXAlignment.Left,
					BackgroundTransparency = 1,
					FontFace = Font.new(
						"rbxasset://fonts/families/Montserrat.json",
						Enum.FontWeight.SemiBold,
						Enum.FontStyle.Normal
					),
					Visible = descriptionPlainLength > 47,
				}),

				SmallRelicDescriptionTextLabel = React.createElement("TextLabel", {
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.fromScale(0.64, 0.395),
					Size = UDim2.fromScale(0.752, 0.08),
					Text = descriptionText,
					TextColor3 = Color3.fromRGB(255, 255, 255),
					TextScaled = true,
					TextWrapped = true,
					RichText = true,
					TextXAlignment = Enum.TextXAlignment.Left,
					BackgroundTransparency = 1,
					FontFace = Font.new(
						"rbxasset://fonts/families/Montserrat.json",
						Enum.FontWeight.SemiBold,
						Enum.FontStyle.Normal
					),
					Visible = descriptionPlainLength <= 47,
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
				-- outside an event session (see dropLive). Sell and Reforge
				-- always render: dim identity tint + "???" while their event is
				-- absent, full color + real label inside it (Sell = the
				-- Merchant's sell session; Reforge = the Forge's anvil).
				SetBonusFrame = React.createElement("Frame", {
					AnchorPoint = Vector2.new(0.5, 0.5),
					BackgroundColor3 = Color3.fromRGB(50, 50, 50),
					Position = UDim2.fromScale(0.561539, 0.699734),
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
							elseif selectedIsCursed then DROP_LOCKED_BACKGROUND
							else greyed(Color3.fromRGB(255, 99, 99)),
						FontFace = Font.new(
							"rbxasset://fonts/families/GothamSSm.json",
							Enum.FontWeight.Bold,
							Enum.FontStyle.Normal
						),
						LayoutOrder = 1,
						Size = UDim2.fromScale(0.332418, 0.739654),
						Text = if selectedIsCursed then "Locked" else "Drop",
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
							if not sellMode then
								return -- greyed outside a sell session; inert
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

		-- Sized for the relic cap (Shared/Data/RelicCapData.MaxOwnedRelics),
		-- wrapped by the list layout. RelicListFragment pads to exactly that
		-- many boxes, filled or empty, so the count follows the shared value.
		RelicListFrame = React.createElement("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.125, 0.521),
			Size = UDim2.fromScale(0.213684, 0.474946),
			BackgroundTransparency = 1,
			ZIndex = 1,
		}, {
			-- FillDirection / alignments are left at their defaults (Vertical,
			-- Left, Top) -- the authored layout relies on exactly those.
			UIListLayout = React.createElement("UIListLayout", {
				SortOrder = Enum.SortOrder.LayoutOrder,
				Padding = UDim.new(0.06, 0),
				Wraps = true,
			}),

			RelicListFragment = React.createElement(RelicListFragment, {
				relicData = relicData,
				selectedRelic = selectedRelic,

				setSelectedRelic = function(selectedData: table)
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
			ZIndex = 1,
		}, {
			UIAspectRatioConstraint = React.createElement("UIAspectRatioConstraint", {
				AspectRatio = 1,
			}),

			NotificationButtonFrame = React.createElement("Frame", {
				ref = notificationButtonRef,

				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.968, -0.01),
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

			ToggleImageButton = React.createElement("ImageButton", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromScale(1.15, 1.15),
				BackgroundColor3 = Color3.fromRGB(47, 47, 48),
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
				UICorner = React.createElement("UICorner", {
					CornerRadius = UDim.new(1, 0),
				}),

				UIStroke = React.createElement("UIStroke", {
					ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
					Color = Color3.fromRGB(22, 22, 22),
					StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize,
					Thickness = 0.1,
					ZIndex = 6,
				}),

				ToggleImageLabel = React.createElement("ImageLabel", {
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.fromScale(0.5, 0.5),
					Size = UDim2.fromScale(0.85, 0.85),
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
			Position = UDim2.fromScale(0.106003, 0.499309),
			Size = UDim2.fromScale(0.233005, 0.508926),
			BackgroundColor3 = Color3.fromRGB(38, 38, 38),
			BackgroundTransparency = 0,
			ZIndex = 0,
		}, {
			UICorner = React.createElement("UICorner", {
				CornerRadius = UDim.new(0.025, 0),
			}),

			ShadowBackgroundImageLabel = React.createElement("ImageLabel", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromScale(1, 1),
				Image = "rbxassetid://6096768861",
				BackgroundTransparency = 1,
				ImageColor3 = Color3.fromRGB(255, 255, 255),
				ImageTransparency = 0.35,
				ScaleType = Enum.ScaleType.Stretch,
				ZIndex = 2,
			}, {
				UICorner = React.createElement("UICorner", {
					CornerRadius = UDim.new(0.025, 0),
				}),
			}),
		}),
	})
end

return Container
