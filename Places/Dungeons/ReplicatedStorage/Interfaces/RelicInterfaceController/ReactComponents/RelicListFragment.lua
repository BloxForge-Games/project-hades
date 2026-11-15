local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage.Submodules.Core.Packages.React)
local RelicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicData)
local RelicEntryContainer = require(script.Parent.RelicEntryContainer)

-- NO RELIC CAP (2026-11-12): the tray is columns of COLUMN_SIZE boxes.
-- It starts as the one column it always was; the relic after a full
-- column opens the next one, drawn whole (owned relics first, then empty
-- boxes to the column's end), so the panel only ever grows a full
-- column at a time.
local COLUMN_SIZE = 6

-- One slot box in a column. The wrapper is identical for every slot;
-- only the entry inside changes. Six to the column: 6 x 0.14 + 5 x 0.045
-- of the column's height; the aspect constraint squares it off that.
local function slotBox(layoutOrder: number, entryProps: { [any]: any })
	return React.createElement("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 0.14),
		BackgroundTransparency = 1,
		LayoutOrder = layoutOrder,
	}, {
		UIAspectRatioConstraint = React.createElement("UIAspectRatioConstraint", {
			AspectRatio = 1,
		}),

		RelicEntryContainer = React.createElement(RelicEntryContainer, entryProps),
	})
end

-- How many columns `relicData` fills (one at least). Counts only names
-- RelicData knows, exactly as the boxes below are drawn.
local function columnsFor(relicData: any): number
	local owned = 0
	if relicData ~= nil then
		for _, relicName in relicData.list do
			if RelicData[relicName] then
				owned += 1
			end
		end
	end
	return math.max(1, math.ceil(owned / COLUMN_SIZE))
end

-- Draws the tray's columns, left to right: owned relics in pickup order,
-- then EMPTY boxes to the end of the last column. props.columnWidth is
-- one column's width in pixels (the Container sizes the panel from the
-- same number); 0 before the screen is measured, when the one column
-- fills the list frame instead.
local function RelicListFragment(props: any)
	local relicData = props.relicData
	local selectedRelic = props.selectedRelic
	-- A click on the box that is ALREADY selected unselects it (the
	-- description card retracts); any other box selects.
	local setSelectedRelic = props.setSelectedRelic
	local function toggleSelected(selectedData: { [any]: any })
		local same = selectedRelic ~= nil and selectedRelic.name == selectedData.name
		setSelectedRelic(if same then nil else selectedData)
	end

	local boxes: { { [any]: any } } = {}
	if relicData ~= nil then
		for _, relicName in relicData.list do
			local relicInfo = RelicData[relicName]
			if relicInfo then
				table.insert(boxes, {
					relicInfo = relicInfo,
					relicName = relicName,
					count = relicData.hashmap[relicName] or 0,
					selectedRelic = selectedRelic,

					onClick = toggleSelected,
					onHover = props.onHover,
				})
			end
		end
	end
	local columns = columnsFor(relicData)
	-- EMPTY boxes: inert (RelicEntryContainer leaves a countless,
	-- handler-less entry non-interactable).
	while #boxes < columns * COLUMN_SIZE do
		table.insert(boxes, { relicName = "", count = 0 })
	end

	local columnWidth: number = props.columnWidth or 0
	local fragment = {}
	for column = 1, columns do
		local children: { [string]: any } = {
			UIListLayout = React.createElement("UIListLayout", {
				SortOrder = Enum.SortOrder.LayoutOrder,
				FillDirection = Enum.FillDirection.Vertical,
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				Padding = UDim.new(0.045, 0),
			}),
		}
		for row = 1, COLUMN_SIZE do
			local index = (column - 1) * COLUMN_SIZE + row
			children["Slot" .. index] = slotBox(row, boxes[index])
		end
		fragment["Column" .. column] = React.createElement("Frame", {
			BackgroundTransparency = 1,
			LayoutOrder = column,
			Size = if columnWidth > 0 then UDim2.new(0, columnWidth, 1, 0) else UDim2.fromScale(1, 1),
		}, children)
	end
	return fragment
end

return {
	Component = RelicListFragment,
	ColumnsFor = columnsFor,
	ColumnSize = COLUMN_SIZE,
}
