--!strict
--[[
	Module: EventGuideController.lua
	Description:
	Draws the guide path to wherever the server says an Event room wants
	the local player (2026-11-19): the event itself, then the exit gate.
	EventGuideService publishes the target as the ObjectValue
	"EventGuideTarget" under the Player; this controller hands it to
	GuideBeamController (the hub's golden wisps) and clears the path when
	the value empties. Local only: each player sees their own path.

	The path stops by itself once the player stands at the target
	(GuideBeamController's arrival), and starts again when the target
	changes.
]]

--[ Roblox Services ]--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--[ Imports ]--

local GuideBeamController = require(ReplicatedStorage.Submodules.Core.Source.Controllers.GuideBeamController)

--[ Constants ]--

local TARGET_VALUE_NAME = "EventGuideTarget"
local TARGET_WAIT_SECONDS = 60

--[ Controller ]--

local EventGuideController = {
	Name = "EventGuideController",
	Dependencies = { GuideBeamController } :: { any },
}

function EventGuideController.Start(_self: typeof(EventGuideController))
	task.spawn(function()
		local value = Players.LocalPlayer:WaitForChild(TARGET_VALUE_NAME, TARGET_WAIT_SECONDS)
		if not value or not value:IsA("ObjectValue") then
			return
		end
		local function apply()
			local target = value.Value
			if target then
				GuideBeamController:PointTo(target)
			else
				GuideBeamController:Clear()
			end
		end
		value.Changed:Connect(apply)
		apply()
	end)
end

return EventGuideController
