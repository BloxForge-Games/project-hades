local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage.Submodules.Core.Packages.React)
local RelicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicData)
local RelicEntryContainer = require(script.Parent.RelicEntryContainer)
local RelicCapData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicCapData)

local function RelicListFragment(props: any)
	local relicData = props.relicData
	local setSelectedRelic = props.setSelectedRelic
	local selectedRelic = props.selectedRelic

	local fragment = {}

	local indexCounter = 1

	if relicData ~= nil then
		for index, relicName in pairs(relicData.list) do
			local relicInfo = RelicData[relicName]

			if relicInfo then
				table.insert(
					fragment,
					React.createElement("Frame", {
						AnchorPoint = Vector2.new(0.5, 0.5),
						Position = UDim2.fromScale(0.5, 0.5),
						Size = UDim2.fromScale(0.224322, 0.179745),
						BackgroundTransparency = 1,
						LayoutOrder = index,
					}, {
						UIAspectRatioConstraint = React.createElement("UIAspectRatioConstraint", {
							AspectRatio = 1,
						}),

						RelicEntryContainer = React.createElement(RelicEntryContainer, {
							relicInfo = relicInfo,
							relicName = relicName,
							count = relicData.hashmap[relicName] or 0,
							selectedRelic = selectedRelic,

							onClick = function(selectedData: table)
								setSelectedRelic(selectedData)
							end,
						}),
					})
				)

				indexCounter += 1
			end
		end
	end

	-- Pad to the relic cap: exactly MaxOwnedRelics boxes, filled or empty.
	-- Read from the SHARED module, not a literal, so the debug cap toggle
	-- moves the UI with it instead of silently clipping the extra relics.
	if indexCounter <= RelicCapData.MaxOwnedRelics then
		for _ = indexCounter, RelicCapData.MaxOwnedRelics do
			table.insert(
				fragment,
				React.createElement("Frame", {
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.fromScale(0.5, 0.5),
					Size = UDim2.fromScale(0.224322, 0.179745),
					BackgroundTransparency = 1,
					LayoutOrder = indexCounter,
				}, {
					UIAspectRatioConstraint = React.createElement("UIAspectRatioConstraint", {
						AspectRatio = 1,
					}),

					RelicEntryContainer = React.createElement(RelicEntryContainer, {
						relicName = "",
						count = 0,
					}),
				})
			)

			indexCounter += 1
		end
	end

	return fragment
end

return RelicListFragment
