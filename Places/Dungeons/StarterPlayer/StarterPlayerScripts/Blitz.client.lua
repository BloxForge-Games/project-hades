--[[
	Client bootstrap. Loads every module through the Blitz
	(Shared/Blitz): each gets its Init / Start lifecycle. Core tier
	first, then the place tier, so a place module may require a core one
	at load.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Blitz = require(ReplicatedStorage.Submodules.Core.Shared.Blitz)

local UniqueControllers = ReplicatedStorage:WaitForChild("Controllers")
local CoreControllers = ReplicatedStorage.Submodules.Core.Source.Controllers
local CoreInterface = ReplicatedStorage.Submodules.Core.Source.Interfaces
local ClientComponents = ReplicatedStorage.Submodules.Core.Source.Components

local clockOffset = os.clock()

repeat
	task.wait()
until Players.LocalPlayer.Character

-- Components are a tier like any other: requiring a component module
-- registers its class with CollectionService. FindFirstChild for the place
-- folder: a place may ship none, and Load treats nil as a no-op.
Blitz.Load(ClientComponents)
Blitz.Load(ReplicatedStorage:FindFirstChild("Components"))

Blitz.Load(CoreControllers)
Blitz.Load(CoreInterface)
Blitz.Load(UniqueControllers)
-- RelicController's sub-controllers are their own tier: the controller no
-- longer registers them as a side effect.
Blitz.Load(UniqueControllers.RelicController.SubControllers)

-- Place-specific interfaces (Places/<place>/ReplicatedStorage/Interfaces),
-- added AFTER the core set so core interfaces they depend on exist.
local PlaceInterfaces = ReplicatedStorage:FindFirstChild("Interfaces")
if PlaceInterfaces then
	Blitz.Load(PlaceInterfaces)
end

Blitz.Start()
print(string.format("[Client-Blitz]: Framework Initiated [%.1fms]", (os.clock() - clockOffset) * 1000))
