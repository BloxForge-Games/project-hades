--[[
     Author(s):
     Module: InCombatController.lua
     Description: Toggles the local character's InCombat attribute based on whether
                  any living zombie under workspace.IgnoreInstances.Zombies is within
                  COMBAT_DISTANCE_THRESHOLD of the player.
]]

--[ Roblox Services ]--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--[ Exports & Types & Defaults ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local Signal = require(ReplicatedStorage.Submodules.Core.Packages.Signal)
local combatProximity = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Combat.combatProximity)

local InCombatController = Knit.CreateController({
	Name = "InCombatController",
	Client = {},
})

InCombatController.Signals = {
	InCombatStatusChanged = Signal.new(),
}

--[ Imports ]--

--[ Constants ]--

local COMBAT_CHECK_INTERVAL = 0.25
local STARTUP_DELAY = 10

--[ Properties ]--

--[ Private Functions ]--

-- Delegates to the SHARED proximity check so the server's mana-regen gate
-- (MagicService._isPlayerInCombat) and this visual state can never drift
-- apart on radius or on what counts as a live zombie.
function InCombatController:_isNearLivingZombie(playerPosition: Vector3): boolean
	return combatProximity.isNearLivingZombie(playerPosition)
end

--[ Public Functions ]--

--[ Initializers ]--

function InCombatController:KnitInit() end

function InCombatController:KnitStart()
	task.spawn(function()
		task.wait(STARTUP_DELAY)

		local currentState = false

		while task.wait(COMBAT_CHECK_INTERVAL) do
			local character = Players.LocalPlayer.Character
			local hrp = character and character:FindFirstChild("HumanoidRootPart")
			if not hrp then
				continue
			end

			local inCombat = self:_isNearLivingZombie(hrp.Position)
			if inCombat ~= currentState then
				currentState = inCombat
				character:SetAttribute(Attributes.InCombat, inCombat)
				self.Signals.InCombatStatusChanged:Fire(inCombat)
			end
		end
	end)
end

return InCombatController
