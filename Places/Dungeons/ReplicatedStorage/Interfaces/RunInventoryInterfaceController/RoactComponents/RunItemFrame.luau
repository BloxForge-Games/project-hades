--[[
	Module: RunItemFrame.luau
	Description:
	Single slot tile in the run-inventory grid. Same motion vocabulary as
	InventoryItemFrame (hover-grow, click-pulse, hover/selected white
	overlay, selection UIStroke, EasyVisuals rarity outline, Shime
	shimmer) with one addition: an EMPTY state.

	The run inventory always renders MAX_RUN_SLOTS tiles; slots past the
	player's item count render empty. Empty tiles are fully INERT — no
	hover, no click, no outline/shimmer effects — and read grey with an
	"Empty" label, matching the authored Empty frame in the layout.

	Props:
	  itemEntry     : resolved entry, or nil for an empty slot. Shape:
	                  { uuid, name, rarity, level?, upgrades?,
	                    enchantment? }
	  LayoutOrder   : grid position.
	  selected      : this tile is the active selection.
	  rarityColor   : resolved rarity tint for the tile background.
	  imageId       : icon asset id (nil → DEFAULT_ICON_ID).
	  showLevel     : false for relics (they have no level), true for drops.
	  visible       : panel open state — gates the per-tile effects so they
	                  don't tick while the panel is closed.
	  onSelect      : (uuid) -> (). nil/ignored on empty slots.
	  introGeneration / introDelay : the opening sweep (useIntroPop). Empty
	                  slots sweep too — the grid arrives as one object.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local React = require(ReplicatedStorage.Submodules.Core.Packages.React)
local EnchantmentData = require(ReplicatedStorage.Submodules.Core.Shared.Data.EnchantmentData)
local EnchantmentNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.EnchantmentNames)
local ItemRarity = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ItemRarity)
local EasyVisuals = require(ReplicatedStorage.Submodules.Core.Libraries.EasyVisuals)
local Shime = require(ReplicatedStorage.Submodules.Core.Libraries.Shime)
local useIntroPop = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.useIntroPop).useIntroPop
local uiSound = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.uiSound)

local DEFAULT_ICON_ID = "rbxassetid://6781733111"

-- Tile-size palette — identical scalars to InventoryItemFrame so both
-- grids feel the same under the cursor.
local BASE_TILE_SCALE = 0.75
local HOVER_SCALE_MULT = 1.06
local CLICK_PEAK_MULT = 1.12

local BASE_TILE_SIZE = UDim2.fromScale(BASE_TILE_SCALE, BASE_TILE_SCALE)
local HOVER_TILE_SIZE = UDim2.fromScale(BASE_TILE_SCALE * HOVER_SCALE_MULT, BASE_TILE_SCALE * HOVER_SCALE_MULT)
local CLICK_PEAK_TILE_SIZE = UDim2.fromScale(BASE_TILE_SCALE * CLICK_PEAK_MULT, BASE_TILE_SCALE * CLICK_PEAK_MULT)

local HOVER_TWEEN_DURATION = 0.2
local CLICK_PULSE_UP_DURATION = 0.08
local CLICK_PULSE_DOWN_DURATION = 0.12
local SELECTED_FADE_DURATION = 0.2
local EQUIP_STROKE_FADE_DURATION = 0.2

local SELECTED_OVERLAY_VISIBLE_T = 0.75
local SELECTED_OVERLAY_HIDDEN_T = 1
local EQUIP_STROKE_VISIBLE_T = 0
local EQUIP_STROKE_HIDDEN_T = 1

local FADE_TWEEN_INFO = TweenInfo.new(SELECTED_FADE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local EQUIP_TWEEN_INFO = TweenInfo.new(EQUIP_STROKE_FADE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local HOVER_TWEEN_INFO = TweenInfo.new(HOVER_TWEEN_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PULSE_UP_TWEEN_INFO = TweenInfo.new(CLICK_PULSE_UP_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PULSE_DOWN_TWEEN_INFO = TweenInfo.new(CLICK_PULSE_DOWN_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local OUTLINE_SPEED = 50
local OUTLINE_SIZE_DESKTOP = 3.5
local OUTLINE_SIZE_MOBILE = 1.5

-- Outline thickness in PIXELS (both the EasyVisuals rarity outline and the
-- empty slot's static stroke are FixedSize), so it has to be stepped down on
-- touch or it swamps the smaller tiles. Read live rather than cached at
-- require time — Studio's device emulator flips TouchEnabled after this
-- module is already loaded.
local function getOutlineSize(): number
	return if UserInputService.TouchEnabled then OUTLINE_SIZE_MOBILE else OUTLINE_SIZE_DESKTOP
end
local SHIMMER_TIME = 5
local TOP_RARITY = ItemRarity.Mythic

-- Empty-slot palette, matching the authored Empty frame: flat grey
-- body with a static grey outline gradient (no rarity animation).
local EMPTY_TILE_COLOR = Color3.fromRGB(80, 80, 80)
local EMPTY_STROKE_COLOR = Color3.fromRGB(152, 152, 152)
local EMPTY_OUTLINE_COLOR = Color3.fromRGB(148, 148, 148)

-- Icon geometry: full-bleed, inherited from InventoryItemFrame (where the
-- icon rode directly on the ImageButton). Drop icons are authored to fill
-- the tile.
local FULL_ICON_ANCHOR = Vector2.new(0, 0)
local FULL_ICON_POSITION = UDim2.fromScale(0.01, 0)
local FULL_ICON_SIZE = UDim2.fromScale(0.983461, 0.983461)

local function RunItemFrame(props: any)
	local itemEntry = props.itemEntry
	local isEmpty = itemEntry == nil

	local layoutOrder = props.LayoutOrder
	local selected = props.selected == true and not isEmpty
	local visible = props.visible ~= false
	local showLevel = props.showLevel ~= false
	local rarity = itemEntry and itemEntry.rarity
	local rarityColor = props.rarityColor or Color3.fromRGB(220, 196, 154)
	local imageId = props.imageId or DEFAULT_ICON_ID
	local enchantmentName = itemEntry and itemEntry.enchantment
	local onSelect = props.onSelect
	local introGeneration = props.introGeneration
	local introDelay = props.introDelay

	local hovered, setHovered = React.useState(false)
	local clickToken, setClickToken = React.useState(0)

	local containerRef = React.useRef(nil)
	local selectedFrameRef = React.useRef(nil)
	local equipStrokeRef = React.useRef(nil)
	local outlineAnchorRef = React.useRef(nil)
	local introScaleRef = React.useRef(nil)
	local introGroupRef = React.useRef(nil)
	useIntroPop(introScaleRef, introGroupRef, introGeneration, introDelay)

	-- Hover grow. Empty slots never enter hover state (the handlers
	-- below early-return), so this rests at BASE for them permanently.
	React.useEffect(function()
		local instance = containerRef.current
		if not instance then
			return
		end
		local targetSize = if hovered then HOVER_TILE_SIZE else BASE_TILE_SIZE
		TweenService:Create(instance, HOVER_TWEEN_INFO, { Size = targetSize }):Play()
	end, { hovered })

	React.useEffect(function()
		if clickToken == 0 then
			return
		end
		local instance = containerRef.current
		if not instance then
			return
		end
		local restingSize = if hovered then HOVER_TILE_SIZE else BASE_TILE_SIZE

		task.spawn(function()
			TweenService:Create(instance, PULSE_UP_TWEEN_INFO, { Size = CLICK_PEAK_TILE_SIZE }):Play()
			task.wait(CLICK_PULSE_UP_DURATION)
			if not containerRef.current then
				return
			end
			TweenService:Create(containerRef.current, PULSE_DOWN_TWEEN_INFO, { Size = restingSize }):Play()
		end)
	end, { clickToken })

	React.useEffect(function()
		local instance = selectedFrameRef.current
		if not instance then
			return
		end
		local shown = hovered or selected
		local target = if shown then SELECTED_OVERLAY_VISIBLE_T else SELECTED_OVERLAY_HIDDEN_T
		TweenService:Create(instance, FADE_TWEEN_INFO, { BackgroundTransparency = target }):Play()
	end, { hovered, selected })

	React.useEffect(function()
		local instance = equipStrokeRef.current
		if not instance then
			return
		end
		local target = if selected then EQUIP_STROKE_VISIBLE_T else EQUIP_STROKE_HIDDEN_T
		TweenService:Create(instance, EQUIP_TWEEN_INFO, { Transparency = target }):Play()
	end, { selected })

	-- Per-tile effects: EasyVisuals animated rarity outline (on a dedicated
	-- anchor so the effect's FindFirstChildWhichIsA("UIStroke") can't grab
	-- the selection stroke) + a Shime UIShimmer sweeping across the tile.
	-- Same construction as InventoryItemFrame. Skipped entirely for empty
	-- slots (they keep the static grey gradient below) and while the panel
	-- is closed, so nothing ticks off-screen.
	React.useEffect(function()
		if isEmpty or not visible then
			return
		end

		local outlineAnchor = outlineAnchorRef.current
		local container = containerRef.current
		if not outlineAnchor or not container then
			return
		end

		local outlineSize = getOutlineSize()
		local outlinePreset = if rarity == TOP_RARITY then "RainbowOutline" else "ShineOutline"

		local outlineEffect =
			EasyVisuals.new(outlineAnchor, outlinePreset, OUTLINE_SPEED, outlineSize, false, rarityColor)

		-- Shime spawns a "UIShimmer" frame inside the tile (inheriting its
		-- corner radius). It has no :Destroy(), so cancel the tween and drop
		-- the frame ourselves.
		local shimmer = Shime.new(
			container,
			math.random(3, SHIMMER_TIME),
			Enum.EasingStyle.Quad,
			Enum.EasingDirection.InOut,
			-1,
			false,
			0
		)
		shimmer:Play()

		return function()
			outlineEffect:Destroy()
			shimmer:Cancel()
			local shimmerFrame = shimmer:GetFrame()
			if shimmerFrame then
				shimmerFrame:Destroy()
			end
		end
		-- `rarity` is nil on empty slots and a nil hole would truncate this
		-- dep array, so it goes in as a string key.
	end, { isEmpty, visible, tostring(rarity), rarityColor })

	-- Enchantment icon (weapons that rolled one). Armor + relics fall
	-- through to nil and the icon stays hidden.
	local enchantmentEntry = nil
	if enchantmentName and enchantmentName ~= EnchantmentNames.None then
		enchantmentEntry = EnchantmentData[enchantmentName]
	end

	-- The grid cell is a CanvasGroup so the opening sweep can fade the WHOLE
	-- tile with one GroupTransparency (same reasoning as InventoryItemFrame;
	-- the inner container never reaches the cell's edge, so the clip is
	-- harmless). GroupTransparency left undeclared: the hook owns it.
	return React.createElement("CanvasGroup", {
		ref = introGroupRef,
		BackgroundTransparency = 1,
		LayoutOrder = layoutOrder,
		Size = UDim2.fromScale(0.168, 0.418168),
		ZIndex = 6,
	}, {
		IAspectRatioConstraint = React.createElement("UIAspectRatioConstraint"),

		Container = React.createElement("Frame", {
			ref = containerRef,
			AnchorPoint = Vector2.new(0.5, 0.5),
			BackgroundColor3 = if isEmpty then EMPTY_TILE_COLOR else rarityColor,
			Position = UDim2.fromScale(0.5, 0.5),
			Size = BASE_TILE_SIZE,
			ZIndex = 6,
		}, {
			-- Opening-sweep scale; Scale left undeclared so only the hook
			-- writes it.
			introScale = React.createElement("UIScale", {
				ref = introScaleRef,
			}),

			ICorner2 = React.createElement("UICorner", {
				BottomLeftRadius = UDim.new(0.05, 0),
				BottomRightRadius = UDim.new(0.05, 0),
				TopLeftRadius = UDim.new(0.05, 0),
				TopRightRadius = UDim.new(0.05, 0),
			}),

			BackgroundShadow = React.createElement("ImageLabel", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				BackgroundTransparency = 1,
				Image = "rbxassetid://96152661142870",
				ImageTransparency = 0.25,
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromScale(1.75, 1.75),
				ZIndex = 0,
			}, {
				ICorner2 = React.createElement("UICorner", {
					BottomLeftRadius = UDim.new(0.05, 0),
					BottomRightRadius = UDim.new(0.05, 0),
					TopLeftRadius = UDim.new(0.05, 0),
					TopRightRadius = UDim.new(0.05, 0),
				}),
			}),

			-- Dedicated anchor for the EasyVisuals outline so its
			-- FindFirstChildWhichIsA("UIStroke") can't grab the selection
			-- stroke on Anchor2. Empty slots keep the static grey gradient.
			Anchor = React.createElement("Frame", {
				ref = outlineAnchorRef,
				AnchorPoint = Vector2.new(0.5, 0.5),
				BackgroundTransparency = 1,
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromScale(1, 1),
			}, {
				UICorner = React.createElement("UICorner", {
					BottomLeftRadius = UDim.new(0.05, 0),
					BottomRightRadius = UDim.new(0.05, 0),
					TopLeftRadius = UDim.new(0.05, 0),
					TopRightRadius = UDim.new(0.05, 0),
				}),

				-- Thickness comes off the SAME touch switch EasyVisuals gets
				-- for filled tiles below. It's FixedSize (pixels), so a flat
				-- 3.5 here would read roughly twice as heavy as the filled
				-- tile sitting next to it on a phone.
				UIStroke = if isEmpty
					then React.createElement("UIStroke", {
						Color = EMPTY_STROKE_COLOR,
						Thickness = getOutlineSize(),
					}, {
						UIGradient = React.createElement("UIGradient", {
							Color = ColorSequence.new({
								ColorSequenceKeypoint.new(0, EMPTY_OUTLINE_COLOR),
								ColorSequenceKeypoint.new(1, EMPTY_OUTLINE_COLOR),
							}),
							Rotation = 1240.65,
						}),
					})
					else nil,
			}),

			-- Selection stroke (tweened by the `selected` effect above).
			Anchor2 = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				BackgroundTransparency = 1,
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromScale(1, 1),
				ZIndex = 2,
			}, {
				UICorner = React.createElement("UICorner", {
					BottomLeftRadius = UDim.new(0.05, 0),
					BottomRightRadius = UDim.new(0.05, 0),
					TopLeftRadius = UDim.new(0.05, 0),
					TopRightRadius = UDim.new(0.05, 0),
				}),

				Stroke = React.createElement("UIStroke", {
					ref = equipStrokeRef,
					Color = Color3.new(1, 1, 1),
					Enabled = true,
					StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize,
					Thickness = 0.035,
					Transparency = EQUIP_STROKE_HIDDEN_T,
				}),
			}),

			-- The icon renders on its own ImageLabel rather than on the
			-- ImageButton below, so `iconScale` callers can inset the art
			-- without shrinking the button's hit area. Lower ZIndex than the
			-- button (7) — the button is fully transparent and still hit-tests
			-- its whole rect, so it keeps owning hover / click.
			IconImageLabel = React.createElement("ImageLabel", {
				AnchorPoint = FULL_ICON_ANCHOR,
				BackgroundTransparency = 1,
				Image = if isEmpty then "" else imageId,
				Position = FULL_ICON_POSITION,
				ScaleType = Enum.ScaleType.Stretch,
				Size = FULL_ICON_SIZE,
				ZIndex = 6,
			}),

			Button = React.createElement("ImageButton", {
				Active = not isEmpty,
				Interactable = not isEmpty,
				BackgroundTransparency = 1,
				-- Icon lives on IconImageLabel above; this stays art-free and
				-- exists purely as the input surface.
				Image = "",
				Position = UDim2.fromScale(0.01, 0),
				Size = UDim2.fromScale(0.983461, 0.983461),
				ZIndex = 7,

				[React.Event.MouseEnter] = function()
					if isEmpty then
						return
					end
					uiSound:PlayHover()
					setHovered(true)
				end,

				[React.Event.MouseLeave] = function()
					if isEmpty then
						return
					end
					setHovered(false)
				end,

				[React.Event.Activated] = function()
					if isEmpty or not onSelect then
						return
					end
					uiSound:PlayClick()
					setClickToken(function(t)
						return t + 1
					end)
					onSelect(itemEntry.uuid)
				end,
			}, {
				ICorner1 = React.createElement("UICorner", {
					BottomLeftRadius = UDim.new(0.05, 0),
					BottomRightRadius = UDim.new(0.05, 0),
					TopLeftRadius = UDim.new(0.05, 0),
					TopRightRadius = UDim.new(0.05, 0),
				}),
			}),

			OutlineImageLabel = React.createElement("ImageLabel", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				BackgroundTransparency = 1,
				Image = "rbxassetid://6096768861",
				ImageTransparency = 0.5,
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromScale(1, 1),
				ZIndex = 9,
			}, {
				ICorner2 = React.createElement("UICorner", {
					BottomLeftRadius = UDim.new(0.05, 0),
					BottomRightRadius = UDim.new(0.05, 0),
					TopLeftRadius = UDim.new(0.05, 0),
					TopRightRadius = UDim.new(0.05, 0),
				}),
			}),

			-- Enchantment badge (weapons only).
			ImageLabel = React.createElement("ImageLabel", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				BackgroundTransparency = 1,
				Image = (enchantmentEntry and enchantmentEntry.imageId) or "",
				Position = UDim2.fromScale(0.204, 0.211),
				Size = UDim2.fromScale(0.324, 0.324),
				Visible = enchantmentEntry ~= nil,
				ZIndex = 9,
			}),

			-- Hover / selected white wash.
			SelectedFrame = React.createElement("Frame", {
				ref = selectedFrameRef,
				AnchorPoint = Vector2.new(0.5, 0.5),
				BackgroundColor3 = Color3.new(1, 1, 1),
				BackgroundTransparency = SELECTED_OVERLAY_HIDDEN_T,
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromScale(1, 1),
				ZIndex = 10,
			}, {
				ICorner2 = React.createElement("UICorner", {
					BottomLeftRadius = UDim.new(0.05, 0),
					BottomRightRadius = UDim.new(0.05, 0),
					TopLeftRadius = UDim.new(0.05, 0),
					TopRightRadius = UDim.new(0.05, 0),
				}),
			}),

			-- Bottom label: "Empty" for empty slots, "Lvl. N" for drops.
			LevelTextLabel = React.createElement("TextLabel", {
				AnchorPoint = Vector2.new(0.5, 0),
				BackgroundColor3 = Color3.new(),
				BackgroundTransparency = 0.4,
				FontFace = Font.new(
					"rbxasset://fonts/families/Montserrat.json",
					Enum.FontWeight.ExtraBold,
					Enum.FontStyle.Normal
				),
				Position = UDim2.fromScale(0.5, 0.69),
				Size = UDim2.fromScale(0.648076, 0.241814),
				Text = if isEmpty then "Empty" else ("Lvl. " .. tostring((itemEntry and itemEntry.level) or 1)),
				TextColor3 = Color3.new(1, 1, 1),
				TextScaled = true,
				TextStrokeColor3 = Color3.fromRGB(27, 27, 27),
				TextStrokeTransparency = 0.5,
				Visible = isEmpty or showLevel,
				ZIndex = 8,
			}, {
				ICorner = React.createElement("UICorner", {
					BottomLeftRadius = UDim.new(0.15, 0),
					BottomRightRadius = UDim.new(0.15, 0),
					TopLeftRadius = UDim.new(0.15, 0),
					TopRightRadius = UDim.new(0.15, 0),
				}),

				IPadding = React.createElement("UIPadding", {
					PaddingBottom = UDim.new(0.15, 0),
					PaddingLeft = UDim.new(0.15, 0),
					PaddingRight = UDim.new(0.15, 0),
					PaddingTop = UDim.new(0.15, 0),
				}),
			}),

			-- Upgrade count ("+N"), drops only and only when > 0.
			UpgradeTextLabel = React.createElement("TextLabel", {
				BackgroundTransparency = 1,
				FontFace = Font.new(
					"rbxasset://fonts/families/Montserrat.json",
					Enum.FontWeight.ExtraBold,
					Enum.FontStyle.Normal
				),
				Position = UDim2.fromScale(0.2, 0.03),
				Size = UDim2.fromScale(0.75, 0.2),
				Text = "+ " .. tostring((itemEntry and itemEntry.upgrades) or 0),
				TextColor3 = Color3.new(1, 1, 1),
				TextScaled = true,
				TextStrokeColor3 = Color3.fromRGB(27, 27, 27),
				TextStrokeTransparency = 0,
				TextXAlignment = Enum.TextXAlignment.Right,
				Visible = (not isEmpty) and ((itemEntry and itemEntry.upgrades) or 0) > 0,
				ZIndex = 9,
			}, {
				ICorner = React.createElement("UICorner", {
					BottomLeftRadius = UDim.new(0.15, 0),
					BottomRightRadius = UDim.new(0.15, 0),
					TopLeftRadius = UDim.new(0.15, 0),
					TopRightRadius = UDim.new(0.15, 0),
				}),

				IStroke = React.createElement("UIStroke", {
					StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize,
					Thickness = 0.1,
					Transparency = 0.5,
				}),
			}),
		}),
	})
end

return RunItemFrame
