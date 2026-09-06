local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)

local Services = ServerScriptService:WaitForChild("Services")
local CoreServices = ServerScriptService.Submodules.Core.Source.Services
local ServerComponents = ServerScriptService.Submodules.Core.Source.Components

local clockOffset: number = os.clock()

Knit.AddServices(CoreServices)
Knit.AddServices(Services)

for _, component in pairs(ServerComponents:GetChildren()) do
	require(component)
end

Knit.Start()
	:andThen(function()
		print(string.format("[Server-Knit]: Framework Initiated [%sms]", os.clock() - clockOffset))
	end)
	:catch(warn)
