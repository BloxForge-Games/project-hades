--[[
     Author(s): 
     Module: DebugService.lua
     Description:
]]

--[ Roblox Services ]--

local ReplicatedStorage = game:GetService("ReplicatedStorage")

--[ Exports & Types & Defaults ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)

local DebugService = Knit.CreateService({
	Name = "DebugService",
	Client = {},
})

--[ Imports ]--

--[ Constants ]--

--[ Properties ]--

--[ Private Functions ]--

--[ Public Functions ]--

--[ Initializers ]--

function DebugService:KnitStart() end

function DebugService:KnitInit() end

return DebugService
