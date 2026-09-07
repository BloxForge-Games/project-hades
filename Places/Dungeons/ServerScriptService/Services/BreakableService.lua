--[[
     Author(s): 
     Module: BreakableService.lua
     Description:
]]

--[ Roblox Services ]--

local ReplicatedStorage = game:GetService("ReplicatedStorage")

--[ Exports & Types & Defaults ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)

local BreakableService = Knit.CreateService({
	Name = "BreakableService",
	Client = {
		OnBreakableDamaged = Knit.CreateSignal(),
	},
})

--[ Imports ]--

--[ Constants ]--

--[ Properties ]--

--[ Private Functions ]--

--[ Public Functions ]--

--[ Initializers ]--

return BreakableService
