--[[
     Author(s): 
     Module: MeleeWeaponVFXController.lua
     Description:
]]

--[ Roblox Services ]--

local ReplicatedStorage = game:GetService("ReplicatedStorage")

--[ Exports & Types & Defaults ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local MeleeWeaponVFXData = require(ReplicatedStorage.Submodules.Core.Shared.Data.MeleeWeaponVFXData)
local MeleeWeaponTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.MeleeWeaponTypes)

local MeleeWeaponVFXService

local MeleeWeaponVFXController = Knit.CreateController({
	Name = "MeleeWeaponVFXController",
	Client = {},
})

--[ Imports ]--

--[ Constants ]--

--[ Properties ]--

--[ Private Functions ]--

--[ Public Functions ]--

--[ Initializers ]--

function MeleeWeaponVFXController:KnitStart()
	MeleeWeaponVFXService = Knit.GetService("MeleeWeaponVFXService")

	MeleeWeaponVFXService.OnReplicateFXRequested:Connect(
		function(character: Model, iteration: number, weaponType: MeleeWeaponTypes.MeleeWeaponTypes)
			MeleeWeaponVFXData[iteration](character, false, nil, weaponType)
		end
	)
end

function MeleeWeaponVFXController:KnitInit() end

return MeleeWeaponVFXController
