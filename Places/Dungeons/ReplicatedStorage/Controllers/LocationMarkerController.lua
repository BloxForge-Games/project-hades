--!strict
--[[
     Author(s):
     Module: LocationMarkerController.lua
     Description: Blitz module that initializes the
                  LocationMarkerSystem library on client start. The library
                  itself lives in Libraries/LocationMarkerSystem and is
                  framework-agnostic; this controller is the glue that wires
                  it into the client's startup sequence so the rest of it
                  doesn't have to know about it.
]]

--[ Roblox Services ]--

local ReplicatedStorage = game:GetService("ReplicatedStorage")

--[ Exports & Types & Defaults ]--

local LocationMarkerSystem = require(ReplicatedStorage.Submodules.Core.Libraries.LocationMarkerSystem)

local LocationMarkerController = {
	Name = "LocationMarkerController",
}

--[ Initializers ]--

function LocationMarkerController.Start(_self: typeof(LocationMarkerController))
	LocationMarkerSystem:Init()
end

return LocationMarkerController
