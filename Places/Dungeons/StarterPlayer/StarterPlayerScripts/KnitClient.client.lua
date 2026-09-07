local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)

local UniqueControllers = ReplicatedStorage:WaitForChild("Controllers")
local CoreControllers = ReplicatedStorage.Submodules.Core.Source.Controllers
local CoreInterface = ReplicatedStorage.Submodules.Core.Source.Interfaces
local ClientComponents = ReplicatedStorage.Submodules.Core.Source.Components

local clockOffset = os.clock()

repeat
	task.wait()
until Players.LocalPlayer.Character

for _, component in pairs(ClientComponents:GetChildren()) do
	require(component)
end

-- Place-specific components (Places/<place>/ReplicatedStorage/Components).
-- FindFirstChild: the Lobby's folder is empty and must not stall the boot.
local PlaceComponents = ReplicatedStorage:FindFirstChild("Components")
if PlaceComponents then
	for _, component in pairs(PlaceComponents:GetChildren()) do
		require(component)
	end
end

Knit.AddControllers(CoreControllers)
Knit.AddControllers(CoreInterface)
Knit.AddControllers(UniqueControllers)

-- Place-specific interfaces (Places/<place>/ReplicatedStorage/Interfaces),
-- added AFTER the core set so core interfaces they depend on exist.
local PlaceInterfaces = ReplicatedStorage:FindFirstChild("Interfaces")
if PlaceInterfaces then
	Knit.AddControllers(PlaceInterfaces)
end

Knit.Start()
	:andThen(function()
		print(string.format("[Client-Knit]: Framework Initiated [%sms]", os.clock() - clockOffset))
	end)
	:catch(warn)
