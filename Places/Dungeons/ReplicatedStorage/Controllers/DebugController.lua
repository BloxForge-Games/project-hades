--!strict
--[[
	 Author(s): 
	 Module: DebugController.lua
	 Description:
]]

--[ Roblox Services ]--

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

--[ Exports & Types & Defaults ]--

local DebugTools = require(ReplicatedStorage.Submodules.DebugTools)

local DebugController = {
	Name = "DebugController",
}

--[ Imports ]--

--[ Constants ]--

--[ Properties ]--

--[ Private Functions ]--

--[ Public Functions ]--

--[ Initializers ]--

function DebugController.Init(_self: typeof(DebugController))
	-- Studio-only: the debug HUD never ships to live players.
	if RunService:IsStudio() then
		DebugTools:Init()
	end
end

return DebugController
