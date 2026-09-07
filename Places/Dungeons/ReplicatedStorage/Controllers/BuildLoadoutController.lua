--[[
     Author(s): 
     Module: BuildLoadoutController.lua
     Description:
]]

--[ Roblox Services ]--

local ReplicatedStorage = game:GetService("ReplicatedStorage")

--[ Exports & Types & Defaults ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local Signal = require(ReplicatedStorage.Submodules.Core.Packages.Signal)

local BuildLoadoutService

local BuildLoadoutController = Knit.CreateController({
	Name = "BuildLoadoutController",

	_buildLoadoutRegistry = {},
	_loadoutInitialized = false,

	Signals = {
		OnBuildLoadoutUpdated = Signal.new(),
	},
})

--[ Imports ]--

--[ Constants ]--

--[ Properties ]--

--[ Private Functions ]--

--[ Public Functions ]--

function BuildLoadoutController:GetBuildLoadoutRegistry(): table
	return self._buildLoadoutRegistry
end

--[ Initializers ]--

function BuildLoadoutController:KnitStart()
	BuildLoadoutService = Knit.GetService("BuildLoadoutService")

	BuildLoadoutService.BuildLoadout:Observe(function(buildLoadout: table)
		self._buildLoadoutRegistry = buildLoadout

		print("Build Loadout Updated:", buildLoadout)

		if buildLoadout == nil then
			warn("[BuildLoadoutController] Received nil build loadout from server")
			return
		end

		self.Signals.OnBuildLoadoutUpdated:Fire(self._buildLoadoutRegistry)
	end)
end

return BuildLoadoutController
