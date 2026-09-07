local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)

local IgnoreListService

local IgnoreListController = Knit.CreateController({
	Name = "IgnoreListController",
	Client = {},
})

IgnoreListController.WeaponIgnoreList = {}
IgnoreListController.BuildingTransparencyIgnoreList = {}
IgnoreListController.MagicSpellIgnoreList = {}
IgnoreListController.ProximityRayIgnoreList = {}
IgnoreListController.ZombieMagicSpellIgnoreList = {}

function IgnoreListController:GetWeaponIgnoreList(): { Instance }
	return table.clone(self.WeaponIgnoreList)
end

function IgnoreListController:GetBuildingTransparencyIgnoreList(): { Instance }
	return table.clone(self.BuildingTransparencyIgnoreList)
end

function IgnoreListController:GetMagicSpellIgnoreList(): { Instance }
	return table.clone(self.MagicSpellIgnoreList)
end

function IgnoreListController:GetProximityRayIgnoreList(): { Instance }
	return table.clone(self.ProximityRayIgnoreList)
end

function IgnoreListController:GetZombieMagicSpellIgnoreList(): { Instance }
	return table.clone(self.ZombieMagicSpellIgnoreList)
end

function IgnoreListController:KnitInit()
	IgnoreListService = Knit.GetService("IgnoreListService")
end

function IgnoreListController:KnitStart()
	IgnoreListService.WeaponIgnoreList:Observe(function(ignoreList: { Instance })
		self.WeaponIgnoreList = ignoreList
	end)

	IgnoreListService.BuildingTransparencyIgnoreList:Observe(function(ignoreList: { Instance })
		self.BuildingTransparencyIgnoreList = ignoreList
	end)

	IgnoreListService.MagicSpellIgnoreList:Observe(function(ignoreList: { Instance })
		self.MagicSpellIgnoreList = ignoreList
	end)

	IgnoreListService.ProximityRayIgnoreList:Observe(function(ignoreList: { Instance })
		self.ProximityRayIgnoreList = ignoreList
	end)

	IgnoreListService.ZombieMagicSpellIgnoreList:Observe(function(ignoreList: { Instance })
		self.ZombieMagicSpellIgnoreList = ignoreList
	end)
end

return IgnoreListController
