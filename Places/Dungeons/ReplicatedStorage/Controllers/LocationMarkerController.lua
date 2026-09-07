--[[
     Author(s):
     Module: LocationMarkerController.lua
     Description: Knit controller wrapper that initializes the
                  LocationMarkerSystem library on client start. The library
                  itself lives in Libraries/LocationMarkerSystem and is
                  framework-agnostic; this controller is the glue that wires
                  it into Knit's startup sequence so the rest of the client
                  doesn't have to know about it.
]]

--[ Roblox Services ]--

local ReplicatedStorage = game:GetService("ReplicatedStorage")

--[ Exports & Types & Defaults ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local LocationMarkerSystem = require(ReplicatedStorage.Submodules.Core.Libraries.LocationMarkerSystem)

local LocationMarkerController = Knit.CreateController({
	Name = "LocationMarkerController",
	Client = {},
})

--[ Initializers ]--

function LocationMarkerController:KnitInit() end

function LocationMarkerController:KnitStart()
	LocationMarkerSystem:Init()
end

return LocationMarkerController
