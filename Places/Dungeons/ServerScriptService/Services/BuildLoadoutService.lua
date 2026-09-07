--[[
     Author(s): 
     Module: MagicLoadoutService.lua
     Description:
]]

--[ Roblox Services ]--

local ReplicatedStorage = game:GetService("ReplicatedStorage")

--[ Exports & Types & Defaults ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local InventoryType = require(ReplicatedStorage.Submodules.Core.Shared.Enums.InventoryType)

local DataService
local PlayerEventService

local BuildLoadoutService = Knit.CreateService({
	Name = "BuildLoadoutService",
	Client = {
		BuildLoadout = Knit.CreateProperty(),
	},

	playerLoadoutRegistry = {},
})

--[ Imports ]--

--[ Constants ]--

--[ Properties ]--

--[ Private Functions ]--

function BuildLoadoutService:_setLoadoutRegistry(player: Player)
	local profile = DataService:GetProfileData(player)

	if not profile["Inventory"] or not profile["Inventory"][InventoryType.Builds] then
		return
	end

	self.playerLoadoutRegistry[player] = {}

	for _, buildData in profile["Inventory"][InventoryType.Builds] do
		if buildData.equipSlot == 1 then
			if self.playerLoadoutRegistry[player][1] == buildData then
				continue
			end

			self.playerLoadoutRegistry[player][1] = buildData
		elseif buildData.equipSlot == 2 then
			if self.playerLoadoutRegistry[player][2] == buildData then
				continue
			end

			self.playerLoadoutRegistry[player][2] = buildData
		elseif buildData.equipSlot == 3 then
			if self.playerLoadoutRegistry[player][3] == buildData then
				continue
			end

			self.playerLoadoutRegistry[player][3] = buildData
		end
	end
end

--[ Public Functions ]--

function BuildLoadoutService:GetBuildLoadout(player: Player): table
	return table.clone(self.Client.BuildLoadout:GetFor(player))
end

function BuildLoadoutService:SetBuildLoadout(player: Player)
	self:_setLoadoutRegistry(player)

	self.Client.BuildLoadout:SetFor(player, self.playerLoadoutRegistry[player])
end

--[ Initializers ]--

function BuildLoadoutService:KnitStart()
	DataService = Knit.GetService("DataService")
	PlayerEventService = Knit.GetService("PlayerEventService")

	DataService.Signals.OnPlayerDataLoaded:Connect(function(player: Player)
		self:SetBuildLoadout(player)
	end)

	PlayerEventService.OnPlayerAdded:Connect(function(player: Player)
		self:SetBuildLoadout(player)
	end)

	PlayerEventService.OnPlayerRemoved:Connect(function(player: Player)
		self.playerLoadoutRegistry[player] = nil
	end)
end

function BuildLoadoutService:KnitInit() end

return BuildLoadoutService
