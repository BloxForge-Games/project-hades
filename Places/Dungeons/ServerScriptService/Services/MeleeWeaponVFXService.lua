--[[
     Author(s): 
     Module: MeleeWeaponVFXService.lua
     Description:
]]

--[ Roblox Services ]--

local ReplicatedStorage = game:GetService("ReplicatedStorage")

--[ Exports & Types & Defaults ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local MeleeWeaponTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.MeleeWeaponTypes)

local MeleeWeaponVFXService = Knit.CreateService({
	Name = "MeleeWeaponVFXService",
	Client = {
		OnFXRequested = Knit.CreateSignal(),
		OnReplicateFXRequested = Knit.CreateSignal(),
	},
})

--[ Imports ]--

--[ Constants ]--

--[ Properties ]--

--[ Private Functions ]--

--[ Public Functions ]--

--[ Initializers ]--

function MeleeWeaponVFXService:KnitStart()
	self.Client.OnFXRequested:Connect(
		function(player: Player, character: Model, iteration: number, weaponType: MeleeWeaponTypes.MeleeWeaponTypes)
			self.Client.OnReplicateFXRequested:FireExcept(player, character, iteration, weaponType)
		end
	)
end

return MeleeWeaponVFXService
