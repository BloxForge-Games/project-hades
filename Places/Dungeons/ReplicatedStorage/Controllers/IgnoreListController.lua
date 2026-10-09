--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DungeonNetwork = require(ReplicatedStorage.Submodules.Core.Source.Network.Dungeon)
local RemoteProperty = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Network.RemoteProperty)

local IgnoreListController = {
	Name = "IgnoreListController",
}

-- Blink delivers instance arrays as `{ Instance? }` (an entry that was
-- destroyed in transit arrives nil); the stored lists keep the `{ Instance }`
-- shape every raycast / overlap filter consumes.
IgnoreListController.WeaponIgnoreList = {} :: { Instance }
IgnoreListController.BuildingTransparencyIgnoreList = {} :: { Instance }
IgnoreListController.ArcaneSpellIgnoreList = {} :: { Instance }
IgnoreListController.ProximityRayIgnoreList = {} :: { Instance }
IgnoreListController.ZombieArcaneSpellIgnoreList = {} :: { Instance }

function IgnoreListController.GetWeaponIgnoreList(self: typeof(IgnoreListController)): { Instance }
	return table.clone(self.WeaponIgnoreList)
end

function IgnoreListController.GetBuildingTransparencyIgnoreList(self: typeof(IgnoreListController)): { Instance }
	return table.clone(self.BuildingTransparencyIgnoreList)
end

function IgnoreListController.GetArcaneSpellIgnoreList(self: typeof(IgnoreListController)): { Instance }
	return table.clone(self.ArcaneSpellIgnoreList)
end

function IgnoreListController.GetProximityRayIgnoreList(self: typeof(IgnoreListController)): { Instance }
	return table.clone(self.ProximityRayIgnoreList)
end

function IgnoreListController.GetZombieArcaneSpellIgnoreList(self: typeof(IgnoreListController)): { Instance }
	return table.clone(self.ZombieArcaneSpellIgnoreList)
end

function IgnoreListController.Start(self: typeof(IgnoreListController))
	RemoteProperty.Client({ changed = DungeonNetwork.WeaponIgnoreListChanged, get = DungeonNetwork.GetWeaponIgnoreList })
		:Observe(function(ignoreList: { Instance? })
			self.WeaponIgnoreList = ignoreList :: { Instance }
		end)

	RemoteProperty.Client({
		changed = DungeonNetwork.BuildingTransparencyIgnoreListChanged,
		get = DungeonNetwork.GetBuildingTransparencyIgnoreList,
	}):Observe(function(ignoreList: { Instance? })
		self.BuildingTransparencyIgnoreList = ignoreList :: { Instance }
	end)

	RemoteProperty.Client({
		changed = DungeonNetwork.ArcaneSpellIgnoreListChanged,
		get = DungeonNetwork.GetArcaneSpellIgnoreList,
	}):Observe(function(ignoreList: { Instance? })
		self.ArcaneSpellIgnoreList = ignoreList :: { Instance }
	end)

	RemoteProperty.Client({
		changed = DungeonNetwork.ProximityRayIgnoreListChanged,
		get = DungeonNetwork.GetProximityRayIgnoreList,
	}):Observe(function(ignoreList: { Instance? })
		self.ProximityRayIgnoreList = ignoreList :: { Instance }
	end)

	RemoteProperty.Client({
		changed = DungeonNetwork.ZombieArcaneSpellIgnoreListChanged,
		get = DungeonNetwork.GetZombieArcaneSpellIgnoreList,
	}):Observe(function(ignoreList: { Instance? })
		self.ZombieArcaneSpellIgnoreList = ignoreList :: { Instance }
	end)
end

return IgnoreListController
