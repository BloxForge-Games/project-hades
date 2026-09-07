--[[
	 Author(s): 
	 Module: DebugController.lua
	 Description:
]]

--[ Roblox Services ]--

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

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

function DebugController:KnitStart() end

function DebugController:KnitInit()
	-- Studio-only: the debug HUD never ships to live players.
	if RunService:IsStudio() then
		DebugTools:Init()
	end
end

return DebugController
