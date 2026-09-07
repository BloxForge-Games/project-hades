--[[
     Author(s): 
     Module: BuildService.lua
     Description:
]]

--[ Roblox Services ]--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--[ Exports & Types & Defaults ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local BuildNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.BuildNames)
local BuildData = require(ReplicatedStorage.Submodules.Core.Shared.Data.BuildData)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local InventoryType = require(ReplicatedStorage.Submodules.Core.Shared.Enums.InventoryType)

local PlayerEventService
local DataService

local BuildService = Knit.CreateService({
	Name = "BuildService",
	Client = {
		BuildRegistry = Knit.CreateProperty(),
		BuildLevelRegistry = Knit.CreateProperty(),
		PlayerCharacters = Knit.CreateProperty({}),

		OnBuildDamaged = Knit.CreateSignal(),
	},

	_playerCharacters = {},
	_playerBuildRegistry = {},
	_playerBuildLevelRegistry = {},
})

--[ Imports ]--

--[ Constants ]--

--[ Properties ]--

--[ Private Functions ]--

function BuildService:_canPlace(model: Model): boolean
	local boundingBox = model.BoundingBox

	local touching = workspace:GetPartsInPart(boundingBox, self._overlapParams)

	for _, hit in touching do
		if hit:IsDescendantOf(self._placementSurface) then
			continue
		end

		if hit:IsDescendantOf(model) then
			continue
		end

		if hit:IsA("BasePart") then
			return false
		end
	end

	return true
end

--[ Public Functions ]--

function BuildService:GetEntireBuildRegistry(): table
	return table.clone(self._playerBuildRegistry)
end

function BuildService:GetBuildRegistry(player: Player): table
	return self.Client.BuildRegistry:GetFor(player) and table.clone(self.Client.BuildRegistry:GetFor(player)) or {}
end

function BuildService:GetBuildLevel(player: Player, buildName: BuildNames.BuildNames): number
	return self.Client.BuildLevelRegistry:GetFor(player) and self.Client.BuildLevelRegistry:GetFor(player)[buildName]
		or 0
end

function BuildService:SetBuildRegistry(player: Player, buildName: BuildNames.BuildNames, value: number)
	self._playerBuildRegistry[player.UserId][buildName] = value

	self.Client.BuildRegistry:SetFor(player, self._playerBuildRegistry[player.UserId])
end

function BuildService.Client:RequestPlaceBuild(
	player: Player,
	buildName: BuildNames.BuildNames,
	cframe: CFrame,
	serverTime: number,
	duration: number
)
	if not BuildNames[buildName] then
		warn(`[BuildService] Invalid build name received from ${player.Name}: ${buildName}`)
		return
	end

	if ReplicatedStorage.GameAssets.Buildables:FindFirstChild(buildName) then
		if
			self.Server._playerBuildRegistry[player.UserId][buildName]
			and self.Server._playerBuildRegistry[player.UserId][buildName] == BuildData[buildName].maxQuantity
		then
			warn(`[BuildService] Player ${player.Name} has reached max quantity for build: ${buildName}`)
			return
		end

		local buildTemplate = ReplicatedStorage.GameAssets.Buildables[buildName]:Clone()
		buildTemplate:SetPrimaryPartCFrame(cframe)
		buildTemplate:SetAttribute(Attributes.CachedCFrame, cframe)
		buildTemplate:SetAttribute(Attributes.OwnerId, player.UserId)

		buildTemplate.CollisionBox.Parent = workspace.IgnoreInstances.MagicSpells
		buildTemplate.Parent = workspace.IgnoreInstances.Map.Buildables

		if self.Server:_canPlace(buildTemplate) then
			buildTemplate.PrimaryPart.Anchored = true
		else
			warn(`[BuildService] Build placement failed for player ${player.Name} - space is occupied`)
			buildTemplate:Destroy()
			return
		end

		local buildRegistry = self.Server:GetBuildRegistry(player)

		self.Server:SetBuildRegistry(player, buildName, buildRegistry[buildName] and buildRegistry[buildName] + 1 or 1)

		local latency = workspace:GetServerTimeNow() - serverTime
		local adjustedDuration = math.max(0, duration - latency)

		task.delay(adjustedDuration, function()
			for _, part in pairs(buildTemplate.Model:GetDescendants()) do
				if part:IsA("BasePart") then
					part.Transparency = 0
				end
			end

			if buildName == BuildNames.Turret then
				buildTemplate:AddTag("Turret")
			elseif buildName == BuildNames["Spike Trap"] then
				buildTemplate:AddTag("Trap")
			end
		end)
	else
		warn(`[BuildService] Build template not found for build name: ${buildName}`)
	end
end

function BuildService.Client:RequestUpdateBuild(player: Player, buildName: string)
	if not BuildNames[buildName] then
		warn(`[BuildService] Invalid build name received from ${player.Name} for update request: ${buildName}`)
		return
	end

	if self.Server._playerBuildLevelRegistry[player.UserId][buildName] then
		self.Server._playerBuildLevelRegistry[player.UserId][buildName] += 1
	else
		warn(
			`[BuildService] Player ${player.Name} does not have an existing level for build ${buildName} - cannot update`
		)
	end
end

--[ Initializers ]--

function BuildService:KnitStart()
	PlayerEventService = Knit.GetService("PlayerEventService")
	DataService = Knit.GetService("DataService")

	local characters = {}

	for _, player in pairs(Players:GetPlayers()) do
		table.insert(characters, player.Character or player.CharacterAdded:Wait())
	end

	self.Client.PlayerCharacters:Set(characters)

	self._overlapParams = OverlapParams.new()
	self._overlapParams.FilterType = Enum.RaycastFilterType.Include
	self._overlapParams.FilterDescendantsInstances =
		{ workspace.IgnoreInstances.Map, unpack(self.Client.PlayerCharacters:Get()) }

	DataService.Signals.OnPlayerDataLoaded:Connect(function(player: Player, data: table)
		local buildData = data.Inventory and data.Inventory[InventoryType.Builds] or {}

		for _, buildEntry in pairs(buildData) do
			if buildEntry.name and buildEntry.level then
				self._playerBuildLevelRegistry[player.UserId] = self._playerBuildLevelRegistry[player.UserId] or {}
				self._playerBuildLevelRegistry[player.UserId][buildEntry.name] = buildEntry.level
			end
		end

		-- print(
		-- 	`[BuildService] Loaded build levels for player ${player.Name}: ${game:GetService("HttpService"):JSONEncode(
		-- 		self._playerBuildLevelRegistry[player.UserId]
		-- 	)}`
		-- )

		self.Client.BuildLevelRegistry:SetFor(player, self._playerBuildLevelRegistry[player.UserId])
	end)

	PlayerEventService.OnPlayerAdded:Connect(function(player: Player)
		self._playerBuildRegistry[player.UserId] = {}

		local characterPropertyTable = self.Client.PlayerCharacters:Get()
		table.insert(characterPropertyTable, player.Character or player.CharacterAdded:Wait())
		self.Client.PlayerCharacters:Set(characterPropertyTable)

		self._overlapParams.FilterDescendantsInstances =
			{ workspace.IgnoreInstances.Map, unpack(self.Client.PlayerCharacters:Get()) }
	end)

	PlayerEventService.OnPlayerRemoved:Connect(function(player: Player)
		if self._playerBuildRegistry[player.UserId] then
			self._playerBuildRegistry[player.UserId] = nil
		end

		if self._playerBuildLevelRegistry[player.UserId] then
			self._playerBuildLevelRegistry[player.UserId] = nil
		end

		local characterPropertyTable = self.Client.PlayerCharacters:Get()
		table.remove(characterPropertyTable, table.find(characterPropertyTable, player.Character))
		self.Client.PlayerCharacters:Set(characterPropertyTable)

		self._overlapParams.FilterDescendantsInstances =
			{ workspace.IgnoreInstances.Map, unpack(self.Client.PlayerCharacters:Get()) }
	end)
end

function BuildService:KnitInit() end

return BuildService
