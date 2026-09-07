local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage.Submodules.Core.Packages.React)
local ToolFrame = require(script.Parent.ToolFrame)

return function(props: any)
	local activeIndex = props.activeIndex
	local toolbarData = props.toolbarData
	local buildClicked = props.buildClicked
	local screenName = props.screenName
	local setActiveBuild = props.setActiveBuild
	local buildLevelData = props.buildLevelData

	local toolbarFrames = {}

	for i, data in toolbarData do
		table.insert(
			toolbarFrames,
			React.createElement(ToolFrame, {
				LayoutOrder = i,

				data = data,
				activeIndex = activeIndex,
				buildClicked = buildClicked,
				setActiveBuild = setActiveBuild,
				screenName = screenName,
				buildLevelData = buildLevelData,
			})
		)
	end

	return toolbarFrames
end
