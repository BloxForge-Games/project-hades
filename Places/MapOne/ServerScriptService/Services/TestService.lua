--[[
     Author(s): 
     Module: TestService.lua
     Description:
]]

--[ Roblox Services ]--

local ReplicatedStorage = game:GetService("ReplicatedStorage")

--[ Exports & Types & Defaults ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)

local TestService = Knit.CreateService({
	Name = "TestService",
	Client = {},
})

--[ Imports ]--

--[ Constants ]--

--[ Properties ]--

--[ Private Functions ]--

--[ Public Functions ]--

--[ Initializers ]--

function TestService:KnitStart()
	print("TestService Started")
end

function TestService:KnitInit()
	print("TestService Initialized")
end

return TestService
