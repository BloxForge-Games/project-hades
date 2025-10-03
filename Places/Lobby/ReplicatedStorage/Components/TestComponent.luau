--[[
     Author(s): ryanisawesome25
     Module: TestComponent.luau
     Description:
]]

--[ Exports & Types & Defaults ]--

--[ Roblox Services ]--

local ReplicatedStorage = game:GetService("ReplicatedStorage")

--[ Imports ]--

local Component = require(ReplicatedStorage.Submodules.Core.Packages.Component)

--[ Component Root ]--

local TestComponent = Component.new({
	Tag = "TestComponent",
})

--[ Network References ]--

--[ Constants ]--

--[ Properties ]--

--[ Private Functions ]--

--[ Public Functions ]--

--[ Initializers ]--

function TestComponent:Construct() end

function TestComponent:Start() end

function TestComponent:Stop() end

return TestComponent
