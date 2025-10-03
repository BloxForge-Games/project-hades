--[[
	 Author(s): 
	 Module: TestController.lua
	 Description:
]]

--[ Roblox Services ]--

local ReplicatedStorage = game:GetService("ReplicatedStorage")

--[ Exports & Types & Defaults ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)

local TestController = Knit.CreateController({
	Name = "TestController",
	Client = {},
})

--[ Imports ]--

--[ Constants ]--

--[ Properties ]--

--[ Private Functions ]--

--[ Public Functions ]--

--[ Initializers ]--

function TestController:KnitStart()
	print("TestController Started")
end

function TestController:KnitInit()
	print("TestController Initialized")
end

return TestController
