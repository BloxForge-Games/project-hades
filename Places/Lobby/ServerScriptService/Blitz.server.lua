--[[
	Server bootstrap. Loads every module through the Blitz
	(Shared/Blitz): each gets its Init / Start lifecycle. Core tier
	first, then the place tier, so a place module may require a core one
	at load.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Blitz = require(ReplicatedStorage.Submodules.Core.Shared.Blitz)

local Services = ServerScriptService:WaitForChild("Services")
local CoreServices = ServerScriptService.Submodules.Core.Source.Services
local ServerComponents = ServerScriptService.Submodules.Core.Source.Components

local clockOffset: number = os.clock()

-- Every Blink server module is required up front so its remotes exist in
-- THIS place before any client asks for them, whether or not the service
-- that fires them is mounted here (the Lobby has no casts, but its clients
-- still load the Magic client module).
for _, network in ServerScriptService.Submodules.Core.Source.Network:GetChildren() do
	if network:IsA("ModuleScript") then
		require(network)
	end
end

Blitz.Load(CoreServices)
-- DataService's sub-services (Currency, Experience, Settings) are their own
-- tier: DataService itself no longer registers them as a side effect.
Blitz.Load(CoreServices.DataService.SubServices)
Blitz.Load(Services)

-- Components are a tier like any other: requiring a component module
-- registers its class with CollectionService. FindFirstChild for the place
-- folder: a place may ship none, and Load treats nil as a no-op.
Blitz.Load(ServerComponents)
Blitz.Load(ServerScriptService:FindFirstChild("Components"))

Blitz.Start()
print(string.format("[Server-Blitz]: Framework Initiated [%.1fms]", (os.clock() - clockOffset) * 1000))
