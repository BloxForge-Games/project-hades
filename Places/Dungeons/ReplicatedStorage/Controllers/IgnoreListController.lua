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
IgnoreListController.MagicSpellIgnoreList = {} :: { Instance }
IgnoreListController.ProximityRayIgnoreList = {} :: { Instance }
IgnoreListController.ZombieMagicSpellIgnoreList = {} :: { Instance }

function IgnoreListController.GetWeaponIgnoreList(self: typeof(IgnoreListController)): { Instance }
	return table.clone(self.WeaponIgnoreList)
end

function IgnoreListController.GetBuildingTransparencyIgnoreList(self: typeof(IgnoreListController)): { Instance }
	return table.clone(self.BuildingTransparencyIgnoreList)
end

function IgnoreListController.GetMagicSpellIgnoreList(self: typeof(IgnoreListController)): { Instance }
	return table.clone(self.MagicSpellIgnoreList)
end

function IgnoreListController.GetProximityRayIgnoreList(self: typeof(IgnoreListController)): { Instance }
	return table.clone(self.ProximityRayIgnoreList)
end

function IgnoreListController.GetZombieMagicSpellIgnoreList(self: typeof(IgnoreListController)): { Instance }
	return table.clone(self.ZombieMagicSpellIgnoreList)
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
		changed = DungeonNetwork.MagicSpellIgnoreListChanged,
		get = DungeonNetwork.GetMagicSpellIgnoreList,
	}):Observe(function(ignoreList: { Instance? })
		self.MagicSpellIgnoreList = ignoreList :: { Instance }
	end)

	RemoteProperty.Client({
		changed = DungeonNetwork.ProximityRayIgnoreListChanged,
		get = DungeonNetwork.GetProximityRayIgnoreList,
	}):Observe(function(ignoreList: { Instance? })
		self.ProximityRayIgnoreList = ignoreList :: { Instance }
	end)

	RemoteProperty.Client({
		changed = DungeonNetwork.ZombieMagicSpellIgnoreListChanged,
		get = DungeonNetwork.GetZombieMagicSpellIgnoreList,
	}):Observe(function(ignoreList: { Instance? })
		self.ZombieMagicSpellIgnoreList = ignoreList :: { Instance }
	end)
end

return IgnoreListController
