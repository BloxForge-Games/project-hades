--[[
	 Author(s): 
	 Module: DebugController.lua
	 Description:
]]

--[ Roblox Services ]--

local ReplicatedStorage = game:GetService("ReplicatedStorage")

--[ Exports & Types & Defaults ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local DebugTools = require(ReplicatedStorage.Submodules.DebugTools)

local DebugController = Knit.CreateController({
	Name = "DebugController",
	Client = {},
})

--[ Imports ]--

--[ Constants ]--

--[ Properties ]--

--[ Private Functions ]--

--[ Public Functions ]--

--[ Initializers ]--

function DebugController:KnitStart()
	print("DebugController Started")
end

function DebugController:KnitInit()
	DebugTools:Init()
end

return DebugController
