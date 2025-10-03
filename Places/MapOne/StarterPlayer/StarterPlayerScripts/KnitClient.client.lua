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

Knit.AddControllers(CoreControllers)
Knit.AddControllers(CoreInterface)
Knit.AddControllers(UniqueControllers)

for _, component in pairs(ClientComponents:GetChildren()) do
	require(component)
end

Knit.Start()
	:andThen(function()
		print(string.format("[Client-Knit]: Framework Initiated [%sms]", os.clock() - clockOffset))
	end)
	:catch(warn)
