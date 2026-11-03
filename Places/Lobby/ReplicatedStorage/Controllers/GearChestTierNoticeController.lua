--!strict
--[[
	Module: GearChestTierNoticeController.lua
	Description:
	The client half of the "Stronger Gear Chest!" notice (2026-11-03,
	GearChestTierNoticeService). The server sends a request card through
	the notification system; this acts on its answer:

	  Yes  the character is moved to stand in front of Valencia, facing
	       her, and her gear chest window opens.
	  No   nothing (the card has already closed).

	Valencia is found by name in workspace.IgnoreInstances.NPCs (a name
	containing "valencia" or "bandit", LobbyNPCService's rule).
]]

--[ Roblox Services ]--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--[ Imports ]--

local UserNotificationSystem = require(ReplicatedStorage.Submodules.Core.Libraries.UserNotificationSystem).Controller
local GearChestInterfaceController =
	require(ReplicatedStorage.Submodules.Core.Source.Interfaces.GearChestInterfaceController)

--[ Controller ]--

local GearChestTierNoticeController = {
	Name = "GearChestTierNoticeController",
	Dependencies = { GearChestInterfaceController } :: { any },
}

--[ Constants ]--

local ACTION = "GearChestTier"
local NPC_KEYWORDS = { "valencia", "bandit" }
-- Where the player stands: this far in front of her, facing her.
local STAND_DISTANCE = 7

--[ Private ]--

local function findValencia(): BasePart?
	local ignoreInstances = workspace:FindFirstChild("IgnoreInstances")
	local folder = ignoreInstances and ignoreInstances:FindFirstChild("NPCs")
	if not folder then
		return nil
	end
	for _, model in folder:GetChildren() do
		local lowered = string.lower(model.Name)
		for _, keyword in NPC_KEYWORDS do
			if string.find(lowered, keyword, 1, true) and model:IsA("Model") then
				local root = model.PrimaryPart or model:FindFirstChild("HumanoidRootPart")
				if root and root:IsA("BasePart") then
					return root
				end
			end
		end
	end
	return nil
end

local function goToValencia()
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local valencia = findValencia()
	if character and root and root:IsA("BasePart") and valencia then
		local front = valencia.CFrame * CFrame.new(0, 0, -STAND_DISTANCE)
		local standAt = Vector3.new(front.Position.X, valencia.Position.Y, front.Position.Z)
		local faceTo = Vector3.new(valencia.Position.X, standAt.Y, valencia.Position.Z)
		character:PivotTo(CFrame.lookAt(standAt, faceTo))
		root.AssemblyLinearVelocity = Vector3.zero
	end
	GearChestInterfaceController:Open()
end

--[ Lifecycle ]--

function GearChestTierNoticeController.Start(_self: typeof(GearChestTierNoticeController))
	UserNotificationSystem.OnRequestAnswered:Connect(function(action: string, _args: any, accepted: boolean)
		if action == ACTION and accepted then
			goToValencia()
		end
	end)
end

return GearChestTierNoticeController
