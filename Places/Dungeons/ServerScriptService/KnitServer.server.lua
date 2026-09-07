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

-- Place-specific components (Places/<place>/ServerScriptService/Components).
-- FindFirstChild rather than WaitForChild: the Lobby has no components of
-- its own, and a missing folder must never stall the boot.
local PlaceComponents = ServerScriptService:FindFirstChild("Components")
if PlaceComponents then
	for _, component in pairs(PlaceComponents:GetChildren()) do
		require(component)
	end
end

Knit.Start()
	:andThen(function()
		print(string.format("[Server-Knit]: Framework Initiated [%sms]", os.clock() - clockOffset))
	end)
	:catch(warn)
