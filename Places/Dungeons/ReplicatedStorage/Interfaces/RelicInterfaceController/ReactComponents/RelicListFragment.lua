local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage.Submodules.Core.Packages.React)
local RelicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicData)
local RelicEntryContainer = require(script.Parent.RelicEntryContainer)
local RelicCapData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicCapData)

-- One slot box in the tray's wrapped list. The wrapper is identical for
-- every slot kind; only the entry inside changes.
local function slotBox(layoutOrder: number, entryProps: { [any]: any })
	return React.createElement("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.165319, 0.159165),
		BackgroundTransparency = 1,
		LayoutOrder = layoutOrder,
	}, {
		UIAspectRatioConstraint = React.createElement("UIAspectRatioConstraint", {
			AspectRatio = 1,
		}),

		RelicEntryContainer = React.createElement(RelicEntryContainer, entryProps),
	})
end

-- Draws exactly RelicCapData.MaxSlots boxes, LayoutOrder 1..MaxSlots:
-- owned relics first, then EMPTY boxes up to the run's open count
-- (props.relicSlots, the Player's RelicSlots attribute), then LOCKED
-- boxes for the rest. The ceiling comes from the shared module and the
-- open count from the server, so a future unlock moves the boundary with
-- no UI edit.
local function RelicListFragment(props: any)
	local relicData = props.relicData
	local selectedRelic = props.selectedRelic
	-- A click on the box that is ALREADY selected unselects it (the
	-- description card retracts); any other box selects. A relic matches
	-- by name, a locked slot by index -- the same rule the box uses to
	-- draw itself selected (RelicEntryContainer).
	local setSelectedRelic = props.setSelectedRelic
	local function toggleSelected(selectedData: { [any]: any })
		local current = selectedRelic
		local same = current ~= nil
			and (
				if selectedData.locked
					then current.locked == true and current.slotIndex == selectedData.slotIndex
					else current.locked ~= true and current.name == selectedData.name
			)
		setSelectedRelic(if same then nil else selectedData)
	end
	local relicSlots = math.clamp(props.relicSlots or RelicCapData.DefaultSlots, 0, RelicCapData.MaxSlots)

	local fragment = {}

	local indexCounter = 1

	if relicData ~= nil then
		for index, relicName in pairs(relicData.list) do
			local relicInfo = RelicData[relicName]

			if relicInfo then
				table.insert(
					fragment,
					slotBox(index, {
						relicInfo = relicInfo,
						relicName = relicName,
						count = relicData.hashmap[relicName] or 0,
						selectedRelic = selectedRelic,

						onClick = toggleSelected,
					})
				)

				indexCounter += 1
			end
		end
	end

	-- EMPTY open slots: inert boxes (RelicEntryContainer leaves a countless,
	-- handler-less entry non-interactable).
	while indexCounter <= relicSlots do
		table.insert(
			fragment,
			slotBox(indexCounter, {
				relicName = "",
				count = 0,
			})
		)

		indexCounter += 1
	end

	-- LOCKED slots: clickable, so the card can say how to open one. Keyed
	-- by slot index, which is what the selection carries for them.
	while indexCounter <= RelicCapData.MaxSlots do
		local slotIndex = indexCounter
		table.insert(
			fragment,
			slotBox(slotIndex, {
				relicName = "",
				count = 0,
				locked = true,
				slotIndex = slotIndex,
				selectedRelic = selectedRelic,

				onClick = toggleSelected,
			})
		)

		indexCounter += 1
	end

	return fragment
end

return RelicListFragment
