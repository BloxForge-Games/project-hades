--[[
	Module: Container.luau
	Description:
	Run-inventory UI root. Structural + behavioural clone of the
	InventoryInterface Container, scoped to the DUNGEON DROPS held in
	RunEscrowService's escrow (banked when you walk out through the exit
	portal, lost on death — beating the boss alone banks nothing).
	Hard-capped at MAX_RUN_SLOTS server-side, so the grid IS the cap.

	Relics deliberately live elsewhere: RelicInterfaceController owns that
	panel. This one has a single category, so there's no tab strip and no
	category crossfade -- just the grid.

	The grid always renders MAX_RUN_SLOTS tiles: owned items first, then
	inert "Empty" slots for the remainder.

	INFORMATION RULES (hardcore design -- the run hides what a bank would
	tell you, but never lies about what it shows):
	  * Main stat   -> "Health: ???" / "Damage: ???". The number is only
	                  revealed once the item is banked into the profile.
	  * Quality     -> the star tier and its colour ARE shown (the player
	                  can see roughly how good the roll was), the percent
	                  is masked: "Quality: ???% (***)".
	  * Enchantment -> shown in full.
	  * Set Bonus   -> shown in full. No "(X/3)" equipped count: run gear
	                  isn't equippable, so there's nothing to count.

	Everything else -- motion vocabulary, fade-swap-fade detail pane,
	open/close tweens, viewport framing -- is lifted verbatim from the
	Inventory so both panels feel identical.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local React = require(ReplicatedStorage.Submodules.Core.Packages.React)

local RunItemFrame = require(script.Parent.RunItemFrame)
-- Shared with the Inventory rather than duplicated: ItemViewport is
-- item-agnostic (it takes an entry + layout props) and its camera-fit
-- maths is subtle enough that a second copy would inevitably drift.
local ItemViewport = require(
	ReplicatedStorage.Submodules.Core.Source.Interfaces.InventoryInterfaceController.RoactComponents.ItemViewport
)

local InventoryType = require(ReplicatedStorage.Submodules.Core.Shared.Enums.InventoryType)
local ItemRarity = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ItemRarity)
local EnchantmentNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.EnchantmentNames)
local MeleeWeaponTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.MeleeWeaponTypes)
local RarityColors = require(ReplicatedStorage.Submodules.Core.Shared.Data.RarityColors)
local MeleeWeaponData = require(ReplicatedStorage.Submodules.Core.Shared.Data.MeleeWeaponData)
local RangedWeaponData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RangedWeaponData)
local ArmorPieceData = require(ReplicatedStorage.Submodules.Core.Shared.Data.ArmorPieceData)
local ArmorSetBonusData = require(ReplicatedStorage.Submodules.Core.Shared.Data.ArmorSetBonusData)
local getWeaponCategory = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Inventory.getWeaponCategory)
local getQualityInfo = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Inventory.getQualityInfo)
local getItemDescription = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Inventory.getItemDescription)
local getItemImageId = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Inventory.getItemImageId)
local INTRO_POP_SECONDS = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.useIntroPop).INTRO_POP_SECONDS
local uiSound = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.uiSound)

--[ Constants ]--

-- Matches RunEscrowService.MAX_RUN_ITEMS. The grid renders exactly this
-- many tiles, so a full grid reads as "no more room".
local MAX_RUN_SLOTS = 15

-- OPENING SWEEP, lifted from the Inventory: every tile (empty slots
-- included — the grid arrives as one object) grows and fades in on a
-- diagonal from the top-left, the last landing at INTRO_TILE_SWEEP_SECONDS.
-- Open only: there are no tabs to switch. The category pill is a static
-- heading and deliberately does NOT sweep. Close is untouched.
local INTRO_TILE_SWEEP_SECONDS = 0.75
-- Grid columns: feeds the UIGridLayout AND the diagonal math.
local GRID_COLUMNS = 5
local INTRO_TILE_SPREAD_SECONDS = INTRO_TILE_SWEEP_SECONDS - INTRO_POP_SECONDS

-- The single category pill's palette, in the ACTIVE state it never leaves.
local CATEGORY_ACTIVE_COLOR = Color3.fromRGB(217, 121, 4)
local CATEGORY_ACTIVE_STROKE_COLOR = Color3.fromRGB(74, 40, 1)
local CATEGORY_SELECTED_OVERLAY_T = 0.75

-- Timings / easing — identical to the Inventory's.
local INFO_PANE_FADE_DURATION = 0.12
local INFO_PANE_INVISIBLE_HOLD = 0.05
local INFO_PANE_TWEEN_INFO = TweenInfo.new(INFO_PANE_FADE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local OPEN_CLOSE_POSITION_DURATION = 0.65
local OPEN_CLOSE_TRANSPARENCY_DURATION = 0.45
local OPEN_CLOSE_POSITION_TWEEN_INFO =
	TweenInfo.new(OPEN_CLOSE_POSITION_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
local OPEN_CLOSE_TRANSPARENCY_TWEEN_INFO =
	TweenInfo.new(OPEN_CLOSE_TRANSPARENCY_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PANEL_OPEN_POSITION = UDim2.fromScale(0.5, 0.5)
local PANEL_CLOSED_POSITION = UDim2.fromScale(0.5, 0.6)
local PANEL_OPEN_TRANSPARENCY = 0
local PANEL_CLOSED_TRANSPARENCY = 1

local BUTTON_HOVER_TWEEN_INFO = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local BUTTON_PULSE_UP_TWEEN_INFO = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local BUTTON_PULSE_DOWN_TWEEN_INFO = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local BUTTON_PULSE_UP_DURATION = 0.08
local BUTTON_HOVER_SCALE = 1.075
local BUTTON_PEAK_SCALE = 1.15

-- "Close" button. A wide pill hanging BELOW the panel body (it lives in
-- InnerContainerFrame, which doesn't clip), not the Inventory's square X.
-- Authored Size = (0.23191, 0.0821221); hover / peak are re-derived from
-- that so the motion beat matches the tiles and category tabs.
local EXIT_BUTTON_BASE_SIZE = UDim2.fromScale(0.23191, 0.0821221)
local EXIT_BUTTON_HOVER_SIZE = UDim2.fromScale(0.23191 * BUTTON_HOVER_SCALE, 0.0821221 * BUTTON_HOVER_SCALE)
local EXIT_BUTTON_PEAK_SIZE = UDim2.fromScale(0.23191 * BUTTON_PEAK_SCALE, 0.0821221 * BUTTON_PEAK_SCALE)

local BUTTON_SELECTED_OVERLAY_VISIBLE_T = 0.75
local BUTTON_SELECTED_OVERLAY_HIDDEN_T = 1

local STAT_COLOR_NEUTRAL = Color3.fromRGB(200, 200, 200)
local STAT_COLOR_INACTIVE = Color3.fromRGB(150, 150, 150)
local ENCHANTMENT_COLOR = Color3.fromRGB(209, 117, 255)

-- Masked stat value. The run shows you WHAT you're carrying, never how
-- good it is — that's the reveal you buy by surviving to the bank.
local MASKED_VALUE = "???"

-- Empty-escrow copy for the detail pane. Dimmer than a real item's white
-- so it reads as a prompt rather than as something you're carrying. The
-- rarity line reuses STAT_COLOR_NEUTRAL, which is already 200,200,200.
local EMPTY_DETAIL_NAME = "THE SPIRE'S BOUNTY"
local EMPTY_DETAIL_NAME_COLOR = Color3.fromRGB(173, 173, 173)
local EMPTY_DETAIL_RARITY = "..."
local EMPTY_DETAIL_DESCRIPTION = "Conquer the dungeon’s final chamber and earn the Spire’s favor."

local ITEM_NAME_COLOR = Color3.new(1, 1, 1)

local VIEWPORT_ARMOR_ANGLE = math.rad(45)

-- Dungeon-drop viewport frames. The run panel's detail rows sit lower
-- than the Inventory's (no Equip button down the bottom), so these are
-- authored for THIS layout rather than derived from the Inventory's
-- per-kind table. Two buckets only: armor and everything else.
local DROP_ARMOR_VIEWPORT_POSITION = UDim2.fromScale(0.5, 0.652)
local DROP_ARMOR_VIEWPORT_SIZE = UDim2.fromScale(0.767, 0.419)
local DROP_WEAPON_VIEWPORT_POSITION = UDim2.fromScale(0.497, 0.65)
local DROP_WEAPON_VIEWPORT_SIZE = UDim2.fromScale(0.839, 0.487)

-- Detail-pane layout. Every one of these lives inside ItemInfoContainer,
-- which the selection pipeline fades to GroupTransparency = 1 before
-- swapping content, so they reposition while nobody can see them and need
-- no tween of their own.
local DROP_LINE_POSITION = UDim2.fromScale(0.499, 0.234403)
local DROP_LINE_SIZE = UDim2.fromScale(0.891313, 0.00709769)
local DROP_NAME_POSITION = UDim2.fromScale(0.466304, 0.189159)
local DROP_NAME_SIZE = UDim2.fromScale(0.824736, 0.053185)
local DROP_RARITY_POSITION = UDim2.fromScale(0.466304, 0.130349)
local DROP_RARITY_SIZE = UDim2.fromScale(0.824735, 0.0459941)
local DROP_DESCRIPTION_POSITION = UDim2.fromScale(0.51149, 0.296388)
local DROP_DESCRIPTION_SIZE = UDim2.fromScale(0.888, 0.0760802)
-- The Drop button. Geometry and palette are authored in Studio and
-- pasted here, so they are the mock's numbers rather than the main
-- inventory's Equip button's.
local DROP_BUTTON_POSITION = UDim2.fromScale(0.5, 0.845)
local DROP_BUTTON_SIZE = UDim2.fromScale(0.27, 0.062)
-- Same red family as the relic tray's Drop button, so the two panels
-- read as one action.
local DROP_BUTTON_COLOR = Color3.fromRGB(255, 99, 99)
local DROP_BUTTON_TEXT_COLOR = Color3.fromRGB(66, 11, 11)
local DROP_BUTTON_STROKE_COLOR = Color3.fromRGB(175, 59, 59)
local DROP_INFO_BACKGROUND_POSITION = UDim2.fromScale(1.011, 0.485)
local DROP_INFO_BACKGROUND_SIZE = UDim2.fromScale(0.627787, 0.835495)

--[ Helpers ]--

local function getRarityColor(rarity: string?): Color3
	return RarityColors:Get(rarity)
end

local function formatColor(text: string, color: Color3): string
	return string.format(
		'<font color="rgb(%d,%d,%d)">%s</font>',
		math.floor(color.R * 255),
		math.floor(color.G * 255),
		math.floor(color.B * 255),
		text
	)
end

-- Dungeon-drop tiles, straight off the escrow snapshot in acquisition
-- order. `escrowItem.item` is the fully-rolled inventory entry the server
-- will insert verbatim on bank, so what the player inspects here is
-- exactly what they keep.
local function buildDropItems(escrowData: { [string]: any }?): { { [string]: any } }
	local out = {}
	if not escrowData or not escrowData.items then
		return out
	end
	for _, escrowItem in escrowData.items do
		local item = escrowItem.item
		if not item or not item.uuid then
			continue
		end
		local armorSlot = escrowItem.armorSlot
		table.insert(out, {
			uuid = item.uuid,
			name = item.name,
			rarity = item.rarity,
			level = item.level or 1,
			upgrades = item.upgrades or 0,
			enchantment = item.enchantment,
			scalarMultiplier = item.scalarMultiplier,
			armorSlot = armorSlot,
			kind = if armorSlot then armorSlot else getWeaponCategory(item.name),
		})
	end
	return out
end

local function findItemByUuid(items: { { [string]: any } }, uuid: string?): { [string]: any }?
	if not uuid then
		return nil
	end
	for _, entry in items do
		if entry.uuid == uuid then
			return entry
		end
	end
	return nil
end

--[ Sub-components ]--

local function DropGrid(props: any)
	local items = props.dropItems
	local introGeneration = props.introGeneration

	-- Diagonal sweep step. The grid ALWAYS holds MAX_RUN_SLOTS tiles, so
	-- the furthest diagonal is fixed.
	local rows = math.ceil(MAX_RUN_SLOTS / GRID_COLUMNS)
	local maxDiagonal = (GRID_COLUMNS - 1) + math.max(rows - 1, 0)
	local diagonalStep = INTRO_TILE_SPREAD_SECONDS / math.max(maxDiagonal, 1)
	local function introDelayFor(slot: number): number
		return (((slot - 1) % GRID_COLUMNS) + math.floor((slot - 1) / GRID_COLUMNS)) * diagonalStep
	end

	local tileChildren = {
		IGridLayout = React.createElement("UIGridLayout", {
			CellPadding = UDim2.fromScale(-0.05, -0.03),
			CellSize = UDim2.fromScale(0.24, 0.32),
			FillDirectionMaxCells = GRID_COLUMNS,
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	}

	-- Always MAX_RUN_SLOTS tiles. Owned items fill from the top; the rest
	-- render as inert "Empty" slots so the grid reads as a fixed carry
	-- capacity rather than a list that happens to be short.
	for slot = 1, MAX_RUN_SLOTS do
		local packed = items[slot]
		if packed then
			tileChildren["item_" .. tostring(packed.uuid)] = React.createElement(RunItemFrame, {
				itemEntry = packed,
				LayoutOrder = slot,
				selected = packed.uuid == props.selectedUuid,
				rarityColor = getRarityColor(packed.rarity),
				imageId = getItemImageId(packed.name),
				visible = props.visible,
				onSelect = props.onItemSelected,
				introGeneration = introGeneration,
				introDelay = introDelayFor(slot),
			})
		else
			tileChildren["empty_" .. tostring(slot)] = React.createElement(RunItemFrame, {
				itemEntry = nil,
				LayoutOrder = slot,
				visible = props.visible,
				introGeneration = introGeneration,
				introDelay = introDelayFor(slot),
			})
		end
	end

	-- Single category, so no crossfade and no per-tab CanvasGroup bookkeeping
	-- -- the group exists only to give the grid its own render bounds.
	return React.createElement("CanvasGroup", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromScale(0.151426, 0.587545),
		Size = UDim2.fromScale(0.96631, 0.822984),
	}, {
		ScrollingFrame = React.createElement("ScrollingFrame", {
			Active = true,
			AnchorPoint = Vector2.new(0.5, 0.5),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			CanvasSize = UDim2.new(),
			Position = UDim2.fromScale(0.5, 0.5),
			ScrollBarImageColor3 = Color3.fromRGB(204, 204, 204),
			ScrollBarThickness = 5,
			ScrollingDirection = Enum.ScrollingDirection.Y,
			Size = UDim2.fromScale(1, 1),
		}, tileChildren),
	})
end

--[ Main Container ]--

local function Container(props: any)
	local RunEscrowService = props.RunEscrowService
	local onClose = props.onClose

	-- Opening-sweep generation, derived DURING RENDER from the Visible prop
	-- flipping true (refs, not state) so the tiles see it in the same
	-- commit that shows the panel and snap to 0 before it paints. 0 =
	-- never opened, so tiles mount at rest. (Same device as the
	-- Inventory's Container.)
	local prevVisibleRef = React.useRef(false)
	local openCountRef = React.useRef(0)
	if props.Visible == true and prevVisibleRef.current ~= true then
		openCountRef.current += 1
	end
	prevVisibleRef.current = props.Visible == true
	local introGeneration: number = openCountRef.current

	local escrowData, setEscrowData = React.useState(nil :: { [string]: any }?)
	local selectedUuid, setSelectedUuid = React.useState(nil :: string?)
	-- Drives ALL detail-pane content — text rows AND the 3D viewport model.
	-- Everything swaps in one shot while the pane is fully transparent.
	local displayedSelectedUuid, setDisplayedSelectedUuid = React.useState(nil :: string?)

	local itemInfoContainerRef = React.useRef(nil)
	local wrapperRef = React.useRef(nil)
	-- Fade-timeline generation token; stale timelines self-cancel.
	local fadeGenerationRef = React.useRef(0)

	local exitButtonHovered, setExitButtonHovered = React.useState(false)
	local exitButtonClickToken, setExitButtonClickToken = React.useState(0)
	local exitButtonFrameRef = React.useRef(nil)
	local exitButtonSelectedFrameRef = React.useRef(nil)

	React.useEffect(function()
		if not RunEscrowService then
			return
		end
		local conn = RunEscrowService.EscrowData:Observe(function(snapshot: { [string]: any })
			setEscrowData(snapshot)
		end)
		return function()
			conn:Disconnect()
		end
	end, {})

	local dropItems = buildDropItems(escrowData)

	-- Auto-select the first item whenever nothing is selected (fresh open,
	-- category swap into a populated tab, first pickup of the run). An empty
	-- tab leaves the selection nil and the detail pane blank.
	React.useEffect(function()
		if selectedUuid then
			-- The selected item can vanish underneath us (relic list
			-- re-replicated, escrow discarded on death). Fall back to the
			-- first remaining item rather than showing a stale pane.
			if findItemByUuid(dropItems, selectedUuid) then
				return
			end
		end
		setSelectedUuid(if #dropItems > 0 then dropItems[1].uuid else nil)
		-- Counts + "" sentinels, never raw nils: a nil hole truncates a Lua
		-- dep array and React would silently stop re-running this effect.
	end, { #dropItems, selectedUuid or "" })

	-- Fade out → swap ALL pane content → hold invisible → fade back in.
	-- Latest-wins: a newer selection bumps the generation and any pending
	-- timeline dies at its next checkpoint, so rapid clicks coalesce into
	-- ONE fade that lands on the last clicked item.
	React.useEffect(function()
		if displayedSelectedUuid == selectedUuid then
			return
		end
		local instance = itemInfoContainerRef.current
		if not instance then
			setDisplayedSelectedUuid(selectedUuid)
			return
		end

		fadeGenerationRef.current += 1
		local generation = fadeGenerationRef.current

		task.spawn(function()
			TweenService:Create(instance, INFO_PANE_TWEEN_INFO, { GroupTransparency = 1 }):Play()
			task.wait(INFO_PANE_FADE_DURATION)
			if generation ~= fadeGenerationRef.current or not itemInfoContainerRef.current then
				return
			end

			setDisplayedSelectedUuid(selectedUuid)

			-- Hold at full transparency so the re-render flushes AND the
			-- freshly cloned viewport model streams its meshes while hidden.
			task.wait(INFO_PANE_INVISIBLE_HOLD)
			if generation ~= fadeGenerationRef.current or not itemInfoContainerRef.current then
				return
			end
			TweenService:Create(itemInfoContainerRef.current, INFO_PANE_TWEEN_INFO, { GroupTransparency = 0 }):Play()
		end)
	end, { selectedUuid or "" })

	React.useEffect(function()
		local instance = wrapperRef.current
		if not instance then
			return
		end
		instance.Interactable = props.Visible == true

		TweenService:Create(instance, OPEN_CLOSE_POSITION_TWEEN_INFO, {
			Position = if props.Visible then PANEL_OPEN_POSITION else PANEL_CLOSED_POSITION,
		}):Play()
		TweenService:Create(instance, OPEN_CLOSE_TRANSPARENCY_TWEEN_INFO, {
			GroupTransparency = if props.Visible then PANEL_OPEN_TRANSPARENCY else PANEL_CLOSED_TRANSPARENCY,
		}):Play()
	end, { props.Visible })

	-- Mount-only seeding. Position / GroupTransparency are deliberately
	-- omitted from the JSX below so React can't re-apply a declarative
	-- value mid-tween and snap the property back.
	React.useEffect(function()
		if wrapperRef.current then
			wrapperRef.current.Position = PANEL_CLOSED_POSITION
			wrapperRef.current.GroupTransparency = PANEL_CLOSED_TRANSPARENCY
		end
	end, {})

	React.useEffect(function()
		local instance = exitButtonFrameRef.current
		if not instance then
			return
		end
		local target = if exitButtonHovered then EXIT_BUTTON_HOVER_SIZE else EXIT_BUTTON_BASE_SIZE
		TweenService:Create(instance, BUTTON_HOVER_TWEEN_INFO, { Size = target }):Play()
	end, { exitButtonHovered })

	React.useEffect(function()
		local instance = exitButtonSelectedFrameRef.current
		if not instance then
			return
		end
		local target = if exitButtonHovered then BUTTON_SELECTED_OVERLAY_VISIBLE_T else BUTTON_SELECTED_OVERLAY_HIDDEN_T
		TweenService:Create(instance, BUTTON_HOVER_TWEEN_INFO, { BackgroundTransparency = target }):Play()
	end, { exitButtonHovered })

	React.useEffect(function()
		if exitButtonClickToken == 0 then
			return
		end
		local instance = exitButtonFrameRef.current
		if not instance then
			return
		end
		local resting = if exitButtonHovered then EXIT_BUTTON_HOVER_SIZE else EXIT_BUTTON_BASE_SIZE
		task.spawn(function()
			TweenService:Create(instance, BUTTON_PULSE_UP_TWEEN_INFO, { Size = EXIT_BUTTON_PEAK_SIZE }):Play()
			task.wait(BUTTON_PULSE_UP_DURATION)
			if not exitButtonFrameRef.current then
				return
			end
			TweenService:Create(exitButtonFrameRef.current, BUTTON_PULSE_DOWN_TWEEN_INFO, { Size = resting }):Play()
		end)
	end, { exitButtonClickToken })

	--[ Detail-pane derived state ]--

	-- The pane renders from displayedSelectedUuid, NOT selectedUuid, so
	-- every row swaps together inside the invisible window above.
	local selectedItem = findItemByUuid(dropItems, displayedSelectedUuid)

	local selectedKind: string? = selectedItem and selectedItem.kind or nil
	local isSelectionArmor = selectedKind == InventoryType.Helmet
		or selectedKind == InventoryType.Chestplate
		or selectedKind == InventoryType.Greaves
	local isSelectionWeapon = selectedKind == "Sword" or selectedKind == "Gun"

	local detailNameText = ""
	local detailNameColor = ITEM_NAME_COLOR
	local detailLevelRarityText = ""
	local detailLevelRarityColor = STAT_COLOR_NEUTRAL
	local detailDescription = ""
	local detailMainStatText = ""
	local detailQualityText = ""
	local detailEnchantmentText = ""
	local detailArmorSetText = ""
	local showEnchantmentFrame = false
	local showArmorSetBonusFrame = false

	if selectedItem then
		detailLevelRarityColor = getRarityColor(selectedItem.rarity)

		local upgrades = selectedItem.upgrades or 0
		local upgradeSuffix = if upgrades > 0 then string.format(" (+%d)", upgrades) else ""
		detailNameText = tostring(selectedItem.name) .. upgradeSuffix
		detailLevelRarityText = string.format(
			"Level %d  •  %s",
			selectedItem.level or 1,
			tostring(selectedItem.rarity or ItemRarity.Common)
		)
		detailDescription = getItemDescription(selectedItem.name)

		-- Main stat: label is real, number is masked until the bank.
		detailMainStatText = string.format("%s: %s", if isSelectionArmor then "Health" else "Damage", MASKED_VALUE)

		-- Quality: the star tier and its colour ARE the reveal — they
		-- tell the player roughly how good the roll is. Only the exact
		-- percent stays hidden.
		local quality = getQualityInfo(selectedItem.scalarMultiplier)
		detailQualityText = "Quality: "
			.. formatColor(string.format("%s%% (%s)", MASKED_VALUE, quality.label), quality.color)

		showEnchantmentFrame = isSelectionWeapon
		if isSelectionWeapon then
			local enchantment = selectedItem.enchantment
			if enchantment == nil or enchantment == "" or enchantment == EnchantmentNames.None then
				detailEnchantmentText = "Enchantment: " .. formatColor("None", STAT_COLOR_INACTIVE)
			else
				detailEnchantmentText = "Enchantment: " .. formatColor(tostring(enchantment), ENCHANTMENT_COLOR)
			end
		end

		-- Set bonus: shown in full, but WITHOUT the Inventory's "(X/3)"
		-- equipped counter — run gear isn't equippable, so there's no
		-- set to be partway through.
		if isSelectionArmor then
			local pieceMeta = ArmorPieceData[selectedItem.name]
			local setName = pieceMeta and pieceMeta.setName
			local bonusData = setName and ArmorSetBonusData[setName]
			if bonusData then
				detailArmorSetText = "Set Bonus: " .. formatColor(tostring(bonusData.bonus), ENCHANTMENT_COLOR)
				showArmorSetBonusFrame = true
			end
		end
	elseif #dropItems == 0 then
		-- Nothing banked yet, so the pane becomes a prompt instead of a
		-- blank slab. Gated on the escrow being empty rather than on
		-- "nothing selected": the auto-select effect above always holds a
		-- selection while items exist, so a populated grid can never land
		-- here and flash this copy mid-swap.
		detailNameText = EMPTY_DETAIL_NAME
		detailNameColor = EMPTY_DETAIL_NAME_COLOR
		detailLevelRarityText = EMPTY_DETAIL_RARITY
		detailDescription = EMPTY_DETAIL_DESCRIPTION
	end

	-- Stats block is drops-only: relics carry no rolled stats, so the whole
	-- frame goes away and the viewport takes the space.
	local showItemStatsFrame = selectedItem ~= nil

	--[ Viewport framing ]--

	local viewportItem = selectedItem
	local viewportKind = selectedKind
	local isViewportArmor = isSelectionArmor
	-- Daggers categorize as "Sword" (the melee slot), so kind alone can't
	-- tell them apart -- read the melee weaponType for the dual-wield case.
	local isDropSelection = viewportItem ~= nil
	local viewportMelee = if isDropSelection then MeleeWeaponData[viewportItem.name] else nil
	local isViewportDagger = viewportMelee ~= nil and viewportMelee.weaponType == MeleeWeaponTypes.Daggers
	local viewportRanged = if isDropSelection then RangedWeaponData[viewportItem.name] else nil
	local viewportArmorMeta = if isDropSelection then ArmorPieceData[viewportItem.name] else nil
	local viewportScaleOverride = (viewportArmorMeta and viewportArmorMeta.viewportScale)
		or (viewportRanged and viewportRanged.viewportScale)
	local viewportYOffsetOverride = (viewportArmorMeta and viewportArmorMeta.viewportYOffset)
		or (viewportRanged and viewportRanged.viewportYOffset)
	local viewportRotationExtra = math.rad((viewportRanged and viewportRanged.viewportRotation) or 0)

	local viewportPosition: UDim2
	if isViewportArmor then
		viewportPosition = DROP_ARMOR_VIEWPORT_POSITION
	else
		viewportPosition = DROP_WEAPON_VIEWPORT_POSITION
	end

	local viewportSize: UDim2
	if isViewportArmor then
		viewportSize = DROP_ARMOR_VIEWPORT_SIZE
	else
		viewportSize = DROP_WEAPON_VIEWPORT_SIZE
	end

	local viewportInitialRotation: number
	if viewportKind == InventoryType.Helmet or viewportKind == InventoryType.Chestplate then
		viewportInitialRotation = math.pi + VIEWPORT_ARMOR_ANGLE
	elseif isViewportArmor then
		viewportInitialRotation = VIEWPORT_ARMOR_ANGLE
	elseif viewportKind == "Gun" then
		viewportInitialRotation = math.pi + viewportRotationExtra
	else
		viewportInitialRotation = 0
	end

	local viewportScaleMultiplier: number
	if viewportScaleOverride then
		viewportScaleMultiplier = viewportScaleOverride
	elseif isViewportDagger then
		viewportScaleMultiplier = 0.8
	elseif viewportKind == InventoryType.Greaves then
		viewportScaleMultiplier = 0.75
	else
		viewportScaleMultiplier = 1
	end

	return React.createElement("CanvasGroup", {
		ref = wrapperRef,
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(0.9, 0.9),
		Interactable = false,
	}, {
		InnerContainerFrame = React.createElement("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			BackgroundTransparency = 1,
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(0.489, 0.697),
		}, {
			UIAspectRatioConstraint = React.createElement("UIAspectRatioConstraint", {
				AspectRatio = 1.25,
			}),

			InventoryBackgroundFrame = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				BackgroundColor3 = Color3.fromRGB(20, 20, 20),
				Interactable = false,
				Position = UDim2.fromScale(0.165, 0.493324),
				Size = UDim2.fromScale(0.993, 0.89),
				ZIndex = 0,
			}, {
				ICorner1 = React.createElement("UICorner", {
					BottomLeftRadius = UDim.new(0.015, 0),
					BottomRightRadius = UDim.new(0.015, 0),
					TopLeftRadius = UDim.new(0.015, 0),
					TopRightRadius = UDim.new(0.015, 0),
				}),

				UIStroke = React.createElement("UIStroke", {
					StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize,
					Thickness = 0.007,
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

			ScrollingGradientFrame = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				BackgroundColor3 = Color3.fromRGB(20, 20, 20),
				LayoutOrder = 6,
				Position = UDim2.fromScale(0.171955, 0.881224),
				Size = UDim2.fromScale(0.97, 0.0728559),
				ZIndex = 2,
			}, {
				ICorner1 = React.createElement("UICorner", {
					BottomLeftRadius = UDim.new(0.08, 0),
					BottomRightRadius = UDim.new(0.08, 0),
					TopLeftRadius = UDim.new(0.08, 0),
					TopRightRadius = UDim.new(0.08, 0),
				}),

				IGradient = React.createElement("UIGradient", {
					Rotation = -90,
					Transparency = NumberSequence.new({
						NumberSequenceKeypoint.new(0, 0),
						NumberSequenceKeypoint.new(1, 1),
					}),
				}),
			}),

			DropGrid = React.createElement(DropGrid, {
				dropItems = dropItems,
				selectedUuid = selectedUuid,
				-- Open state, threaded to each tile so the EasyVisuals
				-- shine/shimmer only tick while the panel is open.
				visible = props.Visible,
				introGeneration = introGeneration,
				onItemSelected = function(uuid: string)
					setSelectedUuid(uuid)
				end,
			}),

			-- Category strip, kept from the two-tab layout but now holding a
			-- single permanently-active pill. It's a heading, not a control:
			-- there's nothing to switch to, so no hover grow, no click pulse
			-- and no detector -- a tab that reacts to the cursor but does
			-- nothing reads as broken.
			--
			-- Centered rather than left-aligned now that it's a lone heading:
			-- the strip was sized and offset for two pills, so a single one
			-- pinned left read as lopsided.
			CategoryContainerFrame = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				BackgroundTransparency = 1,
				Position = UDim2.fromScale(0.151426, 0.123028),
				Size = UDim2.fromScale(0.892409, 0.1),
			}, {
				UIListLayout = React.createElement("UIListLayout", {
					FillDirection = Enum.FillDirection.Horizontal,
					HorizontalAlignment = Enum.HorizontalAlignment.Center,
					Padding = UDim.new(0.025, 0),
					SortOrder = Enum.SortOrder.LayoutOrder,
				}),

				UIPadding = React.createElement("UIPadding", {
					PaddingBottom = UDim.new(0.1, 0),
					PaddingLeft = UDim.new(0.015, 0),
					PaddingRight = UDim.new(0.015, 0),
					PaddingTop = UDim.new(0.1, 0),
				}),

				DungeonDrops = React.createElement("Frame", {
					AnchorPoint = Vector2.new(0.5, 0.5),
					BackgroundTransparency = 1,
					LayoutOrder = 1,
					Position = UDim2.fromScale(0.5, 0.5),
					Size = UDim2.fromScale(0.175, 1),
				}, {
					InnerFrame = React.createElement("Frame", {
						AnchorPoint = Vector2.new(0.5, 0.5),
						BackgroundColor3 = CATEGORY_ACTIVE_COLOR,
						Position = UDim2.fromScale(0.5, 0.5),
						Size = UDim2.fromScale(1.69655, 1),
					}, {
						UICorner = React.createElement("UICorner", {
							BottomLeftRadius = UDim.new(0.08, 0),
							BottomRightRadius = UDim.new(0.08, 0),
							TopLeftRadius = UDim.new(0.08, 0),
							TopRightRadius = UDim.new(0.08, 0),
						}),

						-- Pinned at the selected wash rather than tweened, since
						-- it can never be deselected.
						SelectedFrame = React.createElement("Frame", {
							AnchorPoint = Vector2.new(0.5, 0.5),
							BackgroundColor3 = Color3.new(1, 1, 1),
							BackgroundTransparency = CATEGORY_SELECTED_OVERLAY_T,
							Position = UDim2.fromScale(0.5, 0.5),
							Size = UDim2.fromScale(1, 1),
							ZIndex = 5,
						}, {
							UICorner = React.createElement("UICorner", {
								BottomLeftRadius = UDim.new(0.08, 0),
								BottomRightRadius = UDim.new(0.08, 0),
								TopLeftRadius = UDim.new(0.08, 0),
								TopRightRadius = UDim.new(0.08, 0),
							}),
						}),

						TextLabel = React.createElement("TextLabel", {
							AnchorPoint = Vector2.new(0.5, 0.5),
							BackgroundTransparency = 1,
							FontFace = Font.new(
								"rbxasset://fonts/families/Montserrat.json",
								Enum.FontWeight.ExtraBold,
								Enum.FontStyle.Normal
							),
							Position = UDim2.fromScale(0.5, 0.5),
							Size = UDim2.fromScale(1, 0.5),
							Text = "Spire's Bounty",
							TextColor3 = Color3.new(1, 1, 1),
							TextScaled = true,
						}, {
							UIStroke = React.createElement("UIStroke", {
								Color = CATEGORY_ACTIVE_STROKE_COLOR,
								StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize,
								Thickness = 0.05,
							}),
						}),
					}),
				}),
			}),

			-- Shorter than the grid's background: with MainStatFrame hidden the
			-- detail pane needs less height, and the Close button moved out of
			-- here to InnerContainerFrame. Static now that there's only one
			-- layout -- nothing resizes it at runtime any more.
			ItemInfoContainerBackground = React.createElement("CanvasGroup", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				BackgroundColor3 = Color3.fromRGB(20, 20, 20),
				Position = DROP_INFO_BACKGROUND_POSITION,
				Size = DROP_INFO_BACKGROUND_SIZE,
				ZIndex = -1,
			}, {
				ICorner1 = React.createElement("UICorner", {
					BottomLeftRadius = UDim.new(0.015, 0),
					BottomRightRadius = UDim.new(0.015, 0),
					TopLeftRadius = UDim.new(0.015, 0),
					TopRightRadius = UDim.new(0.015, 0),
				}),

				UIStroke = React.createElement("UIStroke", {
					StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize,
					Thickness = 0.007,
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

			-- Close pill. Parented to InnerContainerFrame (not the info-pane
			-- background) and positioned past Y = 1, so it hangs BELOW the whole
			-- panel — InnerContainerFrame doesn't clip. Living out here also
			-- keeps it clear of ItemInfoContainer's per-selection fade; it only
			-- fades with the panel's own open/close tween.
			ExitButtonFrame = React.createElement("Frame", {
				ref = exitButtonFrameRef,
				AnchorPoint = Vector2.new(0.5, 0.5),
				BackgroundColor3 = Color3.fromRGB(217, 90, 90),
				LayoutOrder = 6,
				Position = UDim2.fromScale(0.518777, 1.04726),
				-- Hardcoded BASE_SIZE constant: React's diff sees the same
				-- value across renders and won't re-apply, so TweenService
				-- stays the sole runtime writer (no mid-tween snap-back).
				Size = EXIT_BUTTON_BASE_SIZE,
				ZIndex = 2,
			}, {
				ICorner1 = React.createElement("UICorner", {
					BottomLeftRadius = UDim.new(0.08, 0),
					BottomRightRadius = UDim.new(0.08, 0),
					TopLeftRadius = UDim.new(0.08, 0),
					TopRightRadius = UDim.new(0.08, 0),
				}),

				-- White hover overlay at ZIndex 2, with the label bumped to
				-- ZIndex 3 so the wash never paints over the text.
				SelectedFrame = React.createElement("Frame", {
					ref = exitButtonSelectedFrameRef,
					Active = false,
					AnchorPoint = Vector2.new(0.5, 0.5),
					BackgroundColor3 = Color3.new(1, 1, 1),
					BackgroundTransparency = BUTTON_SELECTED_OVERLAY_HIDDEN_T,
					BorderSizePixel = 0,
					Position = UDim2.fromScale(0.503935, 0.513531),
					Size = UDim2.fromScale(1.00787, 0.973074),
					ZIndex = 2,
				}, {
					UICorner = React.createElement("UICorner", {
						CornerRadius = UDim.new(0.08, 0),
					}),
				}),

				ExitButton = React.createElement("TextLabel", {
					AnchorPoint = Vector2.new(0.5, 0.5),
					BackgroundTransparency = 1,
					FontFace = Font.new(
						"rbxasset://fonts/families/Montserrat.json",
						Enum.FontWeight.ExtraBold,
						Enum.FontStyle.Normal
					),
					Position = UDim2.fromScale(0.508321, 0.513531),
					Size = UDim2.fromScale(1.01664, 0.632498),
					Text = "Close",
					TextColor3 = Color3.fromRGB(255, 245, 234),
					TextScaled = true,
					ZIndex = 3,
				}, {
					IStroke2 = React.createElement("UIStroke", {
						Color = Color3.fromRGB(25, 25, 25),
						LineJoinMode = Enum.LineJoinMode.Bevel,
						StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize,
						Thickness = 0.05,
					}),
				}),

				UIStroke = React.createElement("UIStroke", {
					StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize,
					Thickness = 0.04,
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

			ExitButtonDetector = React.createElement("ImageButton", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				BackgroundTransparency = 1,
				ImageTransparency = 1,
				Position = UDim2.fromScale(0.518871, 1.04727),
				Size = UDim2.fromScale(0.231541, 0.0825226),
				ZIndex = 10,

				[React.Event.Activated] = function()
					uiSound:PlayClick()
					-- Bump the click token BEFORE closing so the pulse has
					-- a chance to start; it runs in a task.spawn and
					-- self-cancels once the ref clears.
					setExitButtonClickToken(function(t)
						return t + 1
					end)
					if onClose then
						onClose()
					end
				end,
				[React.Event.MouseEnter] = function()
					uiSound:PlayHover()
					setExitButtonHovered(true)
				end,
				[React.Event.MouseLeave] = function()
					setExitButtonHovered(false)
				end,
			}),

			ItemInfoContainer = React.createElement("CanvasGroup", {
				ref = itemInfoContainerRef,
				AnchorPoint = Vector2.new(0.5, 0.5),
				BackgroundTransparency = 1,
				Position = UDim2.fromScale(1.01071, 0.5),
				Size = UDim2.fromScale(0.627787, 1),
				Interactable = true,
				-- Starts visible; the fade-swap-fade effect drives every
				-- subsequent transition.
				GroupTransparency = 0,
			}, {
				ICorner1 = React.createElement("UICorner", {
					BottomLeftRadius = UDim.new(0.02, 0),
					BottomRightRadius = UDim.new(0.02, 0),
					TopLeftRadius = UDim.new(0.02, 0),
					TopRightRadius = UDim.new(0.02, 0),
				}),

				-- Throws the selected item on the floor as a PUBLIC drop:
				-- anyone can pick it up, including the player who dropped
				-- it. Single click, no confirm -- the item is recoverable
				-- off the floor, and a drop nobody takes stays there.
				-- Hidden while nothing is selected, like the main
				-- inventory's Equip button.
				DropButton = React.createElement("TextButton", {
					AnchorPoint = Vector2.new(0.5, 0.5),
					AutoButtonColor = true,
					BackgroundColor3 = DROP_BUTTON_COLOR,
					FontFace = Font.new(
						"rbxasset://fonts/families/Montserrat.json",
						Enum.FontWeight.Bold,
						Enum.FontStyle.Normal
					),
					Position = DROP_BUTTON_POSITION,
					Size = DROP_BUTTON_SIZE,
					Text = "Drop",
					TextColor3 = DROP_BUTTON_TEXT_COLOR,
					TextScaled = true,
					Visible = selectedItem ~= nil,
					ZIndex = 2,
					[React.Event.Activated] = function()
						local uuid = displayedSelectedUuid
						if not uuid or not RunEscrowService then
							return
						end
						uiSound:PlayClick()
						-- Fire and forget: the escrow property observer
						-- re-renders the grid, and the selection effect
						-- moves off the item that just left.
						task.spawn(function()
							RunEscrowService:DropItem(uuid)
						end)
					end,
				}, {
					DropButtonStroke = React.createElement("UIStroke", {
						ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
						Color = DROP_BUTTON_STROKE_COLOR,
						StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize,
						Thickness = 0.05,
					}),

					DropButtonCorner = React.createElement("UICorner", {
						BottomLeftRadius = UDim.new(0.15, 0),
						BottomRightRadius = UDim.new(0.15, 0),
						TopLeftRadius = UDim.new(0.15, 0),
						TopRightRadius = UDim.new(0.15, 0),
					}),

					DropButtonPadding = React.createElement("UIPadding", {
						PaddingBottom = UDim.new(0.1, 0),
						PaddingTop = UDim.new(0.1, 0),
					}),
				}),

				LineFrame = React.createElement("Frame", {
					AnchorPoint = Vector2.new(0.5, 0),
					BackgroundColor3 = Color3.fromRGB(75, 75, 75),
					Position = DROP_LINE_POSITION,
					Size = DROP_LINE_SIZE,
				}, {
					ICorner = React.createElement("UICorner", {
						BottomLeftRadius = UDim.new(0, 6),
						BottomRightRadius = UDim.new(0, 6),
						TopLeftRadius = UDim.new(0, 6),
						TopRightRadius = UDim.new(0, 6),
					}),

					IGradient = React.createElement("UIGradient", {
						Transparency = NumberSequence.new({
							NumberSequenceKeypoint.new(0, 0),
							NumberSequenceKeypoint.new(0.445828, 0),
							NumberSequenceKeypoint.new(1, 0.975),
						}),
					}),

					IPadding = React.createElement("UIPadding", {
						PaddingBottom = UDim.new(0, 16),
						PaddingLeft = UDim.new(0, 16),
						PaddingRight = UDim.new(0, 16),
						PaddingTop = UDim.new(0, 16),
					}),
				}),

				ItemLevelAndRarityTextLabel = React.createElement("TextLabel", {
					AnchorPoint = Vector2.new(0.5, 0.5),
					BackgroundTransparency = 1,
					FontFace = Font.new(
						"rbxasset://fonts/families/Montserrat.json",
						Enum.FontWeight.ExtraBold,
						Enum.FontStyle.Normal
					),
					Position = DROP_RARITY_POSITION,
					Size = DROP_RARITY_SIZE,
					Text = detailLevelRarityText,
					TextColor3 = detailLevelRarityColor,
					TextScaled = true,
					TextXAlignment = Enum.TextXAlignment.Left,
				}, {
					IStroke2 = React.createElement("UIStroke", {
						Color = Color3.fromRGB(25, 25, 25),
						LineJoinMode = Enum.LineJoinMode.Bevel,
						StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize,
						Thickness = 0.05,
					}),
				}),

				ItemNameTextLabel = React.createElement("TextLabel", {
					AnchorPoint = Vector2.new(0.5, 0.5),
					BackgroundTransparency = 1,
					FontFace = Font.new(
						"rbxasset://fonts/families/Montserrat.json",
						Enum.FontWeight.ExtraBold,
						Enum.FontStyle.Normal
					),
					Position = DROP_NAME_POSITION,
					Size = DROP_NAME_SIZE,
					Text = detailNameText,
					TextColor3 = detailNameColor,
					TextScaled = true,
					TextXAlignment = Enum.TextXAlignment.Left,
				}, {
					IStroke2 = React.createElement("UIStroke", {
						Color = Color3.fromRGB(25, 25, 25),
						LineJoinMode = Enum.LineJoinMode.Bevel,
						StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize,
						Thickness = 0.05,
					}),
				}),

				DescriptionTextLabel = React.createElement("TextLabel", {
					AnchorPoint = Vector2.new(0.5, 0.5),
					BackgroundTransparency = 1,
					FontFace = Font.new(
						"rbxasset://fonts/families/Montserrat.json",
						Enum.FontWeight.SemiBold,
						Enum.FontStyle.Italic
					),
					Position = DROP_DESCRIPTION_POSITION,
					RichText = true,
					Size = DROP_DESCRIPTION_SIZE,
					Text = detailDescription,
					TextColor3 = Color3.fromRGB(203, 203, 203),
					TextScaled = true,
					TextXAlignment = Enum.TextXAlignment.Left,
				}, {
					IStroke2 = React.createElement("UIStroke", {
						Color = Color3.fromRGB(25, 25, 25),
						LineJoinMode = Enum.LineJoinMode.Bevel,
						StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize,
						Thickness = 0.05,
					}),
				}),

				ItemStatsFrame = React.createElement("Frame", {
					AnchorPoint = Vector2.new(0.5, 0.5),
					BackgroundColor3 = Color3.fromRGB(35, 35, 35),
					BackgroundTransparency = 0.99,
					BorderSizePixel = 0,
					LayoutOrder = 6,
					Position = UDim2.fromScale(0.533391, 0.401425),
					Size = UDim2.fromScale(0.963303, 0.0833282),
					ZIndex = 2,
					-- Hidden when nothing is selected, so an empty grid shows a
					-- blank pane rather than empty stat rows.
					Visible = showItemStatsFrame,
				}, {
					IListLayout = React.createElement("UIListLayout", {
						Padding = UDim.new(0.2, 0),
						SortOrder = Enum.SortOrder.LayoutOrder,
					}),

					-- Hidden: the row could only ever read "Health: ???" /
					-- "Damage: ???", which is noise rather than information.
					-- Kept in the tree (and detailMainStatText kept computing) so
					-- flipping it back on is a one-line change if masked stats
					-- ever earn their space. UIListLayout skips invisible
					-- children, so QualityFrame slides up into slot 1.
					MainStatFrame = React.createElement("Frame", {
						AnchorPoint = Vector2.new(0.5, 0.5),
						BackgroundColor3 = Color3.fromRGB(50, 50, 50),
						LayoutOrder = 1,
						Position = UDim2.fromScale(0.467157, 2.36716),
						Size = UDim2.fromScale(0.737, 0.686),
						Visible = false,
						ZIndex = 2,
					}, {
						ICorner1 = React.createElement("UICorner", {
							BottomLeftRadius = UDim.new(0.15, 0),
							BottomRightRadius = UDim.new(0.15, 0),
							TopLeftRadius = UDim.new(0.15, 0),
							TopRightRadius = UDim.new(0.15, 0),
						}),

						IGradient = React.createElement("UIGradient", {
							Transparency = NumberSequence.new({
								NumberSequenceKeypoint.new(0, 0.1125),
								NumberSequenceKeypoint.new(0.424658, 0),
								NumberSequenceKeypoint.new(1, 0.975),
							}),
						}),

						StatTextLabel = React.createElement("TextLabel", {
							AnchorPoint = Vector2.new(0.5, 0.5),
							BackgroundTransparency = 1,
							FontFace = Font.new(
								"rbxasset://fonts/families/Montserrat.json",
								Enum.FontWeight.Bold,
								Enum.FontStyle.Normal
							),
							Position = UDim2.fromScale(0.932, 0.5),
							RichText = true,
							Size = UDim2.fromScale(1.815, 0.65),
							Text = detailMainStatText,
							TextColor3 = STAT_COLOR_NEUTRAL,
							TextScaled = true,
							TextXAlignment = Enum.TextXAlignment.Left,
						}, {
							IStroke2 = React.createElement("UIStroke", {
								Color = Color3.fromRGB(25, 25, 25),
								LineJoinMode = Enum.LineJoinMode.Bevel,
								StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize,
								Thickness = 0.05,
							}),
						}),
					}),

					QualityFrame = React.createElement("Frame", {
						AnchorPoint = Vector2.new(0.5, 0.5),
						BackgroundColor3 = Color3.fromRGB(50, 50, 50),
						LayoutOrder = 2,
						Position = UDim2.fromScale(0.467157, 2.36716),
						Size = UDim2.fromScale(0.737, 0.686),
						ZIndex = 2,
					}, {
						ICorner1 = React.createElement("UICorner", {
							BottomLeftRadius = UDim.new(0.15, 0),
							BottomRightRadius = UDim.new(0.15, 0),
							TopLeftRadius = UDim.new(0.15, 0),
							TopRightRadius = UDim.new(0.15, 0),
						}),

						IGradient = React.createElement("UIGradient", {
							Transparency = NumberSequence.new({
								NumberSequenceKeypoint.new(0, 0.1125),
								NumberSequenceKeypoint.new(0.424658, 0),
								NumberSequenceKeypoint.new(1, 0.975),
							}),
						}),

						QualityTextLabel = React.createElement("TextLabel", {
							AnchorPoint = Vector2.new(0.5, 0.5),
							BackgroundTransparency = 1,
							FontFace = Font.new(
								"rbxasset://fonts/families/Montserrat.json",
								Enum.FontWeight.Bold,
								Enum.FontStyle.Normal
							),
							Position = UDim2.fromScale(0.975, 0.5),
							RichText = true,
							Size = UDim2.fromScale(1.901, 0.65),
							Text = detailQualityText,
							TextColor3 = STAT_COLOR_NEUTRAL,
							TextScaled = true,
							TextXAlignment = Enum.TextXAlignment.Left,
						}, {
							IStroke2 = React.createElement("UIStroke", {
								Color = Color3.fromRGB(25, 25, 25),
								LineJoinMode = Enum.LineJoinMode.Bevel,
								StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize,
								Thickness = 0.05,
							}),
						}),
					}),

					EnchantmentFrame = React.createElement("Frame", {
						AnchorPoint = Vector2.new(0.5, 0.5),
						BackgroundColor3 = Color3.fromRGB(50, 50, 50),
						LayoutOrder = 3,
						Position = UDim2.fromScale(0.467157, 3.36644),
						Size = UDim2.fromScale(0.737, 0.686),
						ZIndex = 2,
						-- Weapons only — armor entries hide the row.
						Visible = showEnchantmentFrame,
					}, {
						ICorner1 = React.createElement("UICorner", {
							BottomLeftRadius = UDim.new(0.15, 0),
							BottomRightRadius = UDim.new(0.15, 0),
							TopLeftRadius = UDim.new(0.15, 0),
							TopRightRadius = UDim.new(0.15, 0),
						}),

						IGradient = React.createElement("UIGradient", {
							Transparency = NumberSequence.new({
								NumberSequenceKeypoint.new(0, 0.1125),
								NumberSequenceKeypoint.new(0.424658, 0),
								NumberSequenceKeypoint.new(1, 0.975),
							}),
						}),

						EnchantmentTextLabel = React.createElement("TextLabel", {
							AnchorPoint = Vector2.new(0.5, 0.5),
							BackgroundTransparency = 1,
							FontFace = Font.new(
								"rbxasset://fonts/families/Montserrat.json",
								Enum.FontWeight.Bold,
								Enum.FontStyle.Normal
							),
							Position = UDim2.fromScale(0.975, 0.5),
							RichText = true,
							Size = UDim2.fromScale(1.901, 0.65),
							Text = detailEnchantmentText,
							TextColor3 = STAT_COLOR_NEUTRAL,
							TextScaled = true,
							TextXAlignment = Enum.TextXAlignment.Left,
						}, {
							IStroke2 = React.createElement("UIStroke", {
								Color = Color3.fromRGB(25, 25, 25),
								LineJoinMode = Enum.LineJoinMode.Bevel,
								StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize,
								Thickness = 0.05,
							}),
						}),
					}),

					-- ONLY FOR ARMOR PIECES
					ArmorSetBonusFrame = React.createElement("Frame", {
						AnchorPoint = Vector2.new(0.5, 0.5),
						BackgroundColor3 = Color3.fromRGB(50, 50, 50),
						LayoutOrder = 3,
						Position = UDim2.fromScale(0.467157, 3.36644),
						Size = UDim2.fromScale(0.737, 0.686),
						ZIndex = 2,
						Visible = showArmorSetBonusFrame,
					}, {
						ICorner1 = React.createElement("UICorner", {
							BottomLeftRadius = UDim.new(0.15, 0),
							BottomRightRadius = UDim.new(0.15, 0),
							TopLeftRadius = UDim.new(0.15, 0),
							TopRightRadius = UDim.new(0.15, 0),
						}),

						IGradient = React.createElement("UIGradient", {
							Transparency = NumberSequence.new({
								NumberSequenceKeypoint.new(0, 0.1125),
								NumberSequenceKeypoint.new(0.424658, 0),
								NumberSequenceKeypoint.new(1, 0.975),
							}),
						}),

						ArmorSetTextLabel = React.createElement("TextLabel", {
							AnchorPoint = Vector2.new(0.5, 0.5),
							BackgroundTransparency = 1,
							FontFace = Font.new(
								"rbxasset://fonts/families/Montserrat.json",
								Enum.FontWeight.Bold,
								Enum.FontStyle.Normal
							),
							Position = UDim2.fromScale(0.975, 0.5),
							RichText = true,
							Size = UDim2.fromScale(1.901, 0.65),
							Text = detailArmorSetText,
							TextColor3 = STAT_COLOR_NEUTRAL,
							TextScaled = true,
							TextXAlignment = Enum.TextXAlignment.Left,
						}, {
							IStroke2 = React.createElement("UIStroke", {
								Color = Color3.fromRGB(25, 25, 25),
								LineJoinMode = Enum.LineJoinMode.Bevel,
								StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize,
								Thickness = 0.05,
							}),
						}),
					}),
				}),

				ViewportFrame = React.createElement(ItemViewport, {
					-- Driven by the DISPLAYED selection so the model swaps
					-- together with the text at full transparency, then
					-- streams its meshes during the invisible hold.
					itemEntry = viewportItem,

					AnchorPoint = Vector2.new(0.5, 0.5),
					BackgroundColor3 = Color3.fromRGB(50, 50, 50),
					BackgroundTransparency = 0.99,
					BorderColor3 = Color3.new(),
					BorderSizePixel = 0,
					Position = viewportPosition,
					Rotation = if viewportKind == "Sword" then 90 else 0,
					Size = viewportSize,
					ZIndex = 0,

					scaleMultiplier = viewportScaleMultiplier,
					viewportYOffset = viewportYOffsetOverride,
					initialRotation = viewportInitialRotation,
				}),
			}),
		}),
	})
end

return Container
