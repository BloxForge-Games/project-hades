--!strict
local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local PlayerEventService = require(ServerScriptService.Submodules.Core.Source.Services.PlayerEventService)
local DungeonNetwork = require(ServerScriptService.Submodules.Core.Source.Network.Dungeon)
local RemoteProperty = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Network.RemoteProperty)
local IgnoreListData = require(ReplicatedStorage.Submodules.Core.Shared.Data.IgnoreListData)
local CollisionGroups = require(ReplicatedStorage.Submodules.Core.Shared.Enums.CollisionGroups)

-- Mob RaycastHitbox parts (the invisible aim-assist boxes on every mob)
-- used to be appended to the replicated weapon ignore list one by one:
-- every spawn and every death was a read-clone-mutate-Set that rebroadcast
-- the whole array to every client. They are kept out of weapon queries
-- STRUCTURALLY now: each one is moved into CollisionGroups.MobRaycastHitbox,
-- which is registered as non-collidable with CollisionGroups.WeaponQuery,
-- and every weapon / magic OverlapParams (MeleeWeapon, VFXService) sets the
-- latter as its CollisionGroup — an overlap query skips parts whose group
-- cannot collide with its own. Nothing else changes for the part: the
-- client's aim ray queries with the Default group, which still collides
-- with it, and the new group collides with every other group exactly as
-- Default does.
local IgnoreListService = {
	Name = "IgnoreListService",
	Dependencies = { PlayerEventService } :: { any },

	-- The CollisionGroup weapon / magic overlap queries must use so that mob
	-- RaycastHitbox parts are skipped (see the note above).
	WeaponQueryCollisionGroup = CollisionGroups.WeaponQuery,
}

-- Blink sends arrays by length, so a list must have no holes: folders
-- missing from this place are skipped instead of leaving a nil slot.
local function existing(...: Instance?): { Instance }
	local list = {}
	for index = 1, select("#", ...) do
		local instance = select(index, ...)
		if instance then
			table.insert(list, instance)
		end
	end
	return list
end

-- The five replicated ignore lists (were replicated properties).
IgnoreListService._weaponIgnoreList = RemoteProperty.Server({
	changed = DungeonNetwork.WeaponIgnoreListChanged,
	get = DungeonNetwork.GetWeaponIgnoreList,
}, table.clone(IgnoreListData))
IgnoreListService._buildingTransparencyIgnoreList = RemoteProperty.Server({
	changed = DungeonNetwork.BuildingTransparencyIgnoreListChanged,
	get = DungeonNetwork.GetBuildingTransparencyIgnoreList,
}, table.clone(IgnoreListData))
IgnoreListService._magicSpellIgnoreList = RemoteProperty.Server({
	changed = DungeonNetwork.MagicSpellIgnoreListChanged,
	get = DungeonNetwork.GetMagicSpellIgnoreList,
}, table.clone(IgnoreListData))
IgnoreListService._proximityRayIgnoreList = RemoteProperty.Server({
	changed = DungeonNetwork.ProximityRayIgnoreListChanged,
	get = DungeonNetwork.GetProximityRayIgnoreList,
}, {})
IgnoreListService._zombieMagicSpellIgnoreList = RemoteProperty.Server(
	{
		changed = DungeonNetwork.ZombieMagicSpellIgnoreListChanged,
		get = DungeonNetwork.GetZombieMagicSpellIgnoreList,
	},
	existing(
		workspace.IgnoreInstances:FindFirstChild("Zombies"),
		workspace.IgnoreInstances:FindFirstChild("DeadZombies"),
		workspace.IgnoreInstances:FindFirstChild("Terrain"),
		workspace.IgnoreInstances:FindFirstChild("MapMarkers"),
		workspace.IgnoreInstances:FindFirstChild("Boundaries"),
		workspace.IgnoreInstances:FindFirstChild("Regions"),
		workspace.IgnoreInstances:FindFirstChild("MagicSpells"),
		workspace.IgnoreInstances:FindFirstChild("Chests"),
		workspace:FindFirstChild("PlayerBaseplates"),
		workspace:FindFirstChild("Terrain")
	)
)

function IgnoreListService.SetWeaponIgnoreList(self: typeof(IgnoreListService), newIgnoreList: { Instance })
	self._weaponIgnoreList:Set(newIgnoreList)
end

function IgnoreListService.SetBuildingTransparencyIgnoreList(
	self: typeof(IgnoreListService),
	newIgnoreList: { Instance }
)
	self._buildingTransparencyIgnoreList:Set(newIgnoreList)
end

function IgnoreListService.SetMagicSpellIgnoreList(self: typeof(IgnoreListService), newIgnoreList: { Instance })
	self._magicSpellIgnoreList:Set(newIgnoreList)
end

function IgnoreListService.SetProximityRayIgnoreList(self: typeof(IgnoreListService), newIgnoreList: { Instance })
	self._proximityRayIgnoreList:Set(newIgnoreList)
end

function IgnoreListService.SetZombieMagicSpellIgnoreList(self: typeof(IgnoreListService), newIgnoreList: { Instance })
	self._zombieMagicSpellIgnoreList:Set(newIgnoreList)
end

-- READ-ONLY: this is the live replicated array, not a copy. Every caller
-- that just hands it to an OverlapParams (which copies it) reads it
-- directly; a caller that needs to append must table.clone it first, and
-- the writers in this file do.
function IgnoreListService.GetWeaponIgnoreList(self: typeof(IgnoreListService)): { Instance }
	return self._weaponIgnoreList:Get() :: { Instance }
end

function IgnoreListService.GetBuildingTransparencyIgnoreList(self: typeof(IgnoreListService)): { Instance }
	return table.clone(self._buildingTransparencyIgnoreList:Get()) :: { Instance }
end

function IgnoreListService.GetMagicSpellIgnoreList(self: typeof(IgnoreListService)): { Instance }
	return table.clone(self._magicSpellIgnoreList:Get()) :: { Instance }
end

function IgnoreListService.GetProximityRayIgnoreList(self: typeof(IgnoreListService)): { Instance }
	return table.clone(self._proximityRayIgnoreList:Get()) :: { Instance }
end

function IgnoreListService.GetZombieMagicSpellIgnoreList(self: typeof(IgnoreListService)): { Instance }
	return table.clone(self._zombieMagicSpellIgnoreList:Get()) :: { Instance }
end

-- Registers the two collision groups and makes them mutually
-- non-collidable. Idempotent: a place that already defines them keeps
-- its definitions.
function IgnoreListService._registerCollisionGroups(_self: typeof(IgnoreListService))
	for _, groupName in { CollisionGroups.MobRaycastHitbox, CollisionGroups.WeaponQuery } do
		if not PhysicsService:IsCollisionGroupRegistered(groupName) then
			PhysicsService:RegisterCollisionGroup(groupName)
		end
	end
	PhysicsService:CollisionGroupSetCollidable(CollisionGroups.MobRaycastHitbox, CollisionGroups.WeaponQuery, false)
end

-- Per-zombie hookup that moves the mob's RaycastHitbox into the
-- MobRaycastHitbox collision group the moment it's available on the
-- model. The part needs no de-registration: the group travels with it,
-- and death destroys it.
--
-- Why this is keyed on Zombies.ChildAdded + WaitForChild rather than
-- ZombieSpawnService.OnZombieSpawn:
--   The OnZombieSpawn signal fires from MobBase only AFTER the fade-in
--   delay (~0.25s + the spawn animation). During that window the
--   zombie's RaycastHitbox already exists in workspace, and a weapon
--   query in that window would hit the (invisible, aim-assist-only)
--   RaycastHitbox instead of the actual zombie geometry.
--
--   ChildAdded fires the instant the model is parented, and
--   WaitForChild blocks until the part appears, so the hookup races
--   the first swing reliably.
function IgnoreListService._registerZombieRaycastHitbox(_self: typeof(IgnoreListService), zombie: Instance)
	if not zombie:IsA("Model") then
		return
	end
	-- WaitForChild blocks on the per-zombie task; doesn't stall the
	-- ChildAdded handler for other zombies. 5s is a generous safety —
	-- if a model spawn never lands a RaycastHitbox in that window
	-- something else is broken.
	local hitbox = zombie:WaitForChild("RaycastHitbox", 5)
	if not hitbox or not hitbox:IsA("BasePart") then
		return
	end

	hitbox.CollisionGroup = CollisionGroups.MobRaycastHitbox
end

function IgnoreListService._initWeaponIgnoreList(self: typeof(IgnoreListService))
	-- Every WeaponIgnoreList mutation in this file is a read-clone-mutate-
	-- Set on the RemoteProperty, with no yield between the Get and the
	-- Set. The static inserts below are the only thing that ever grows the
	-- list besides player characters: mob RaycastHitbox parts are handled
	-- by collision group (see the top of the file), so the list no longer
	-- churns per mob.
	local weaponIgnoreList = table.clone(self:GetWeaponIgnoreList())

	-- Not the Client folder since we want the player to hit those for realistic collisions
	if workspace.IgnoreInstances:FindFirstChild("EscortObjects") then
		table.insert(weaponIgnoreList, workspace.IgnoreInstances.EscortObjects.Nodes)
		table.insert(weaponIgnoreList, workspace.IgnoreInstances.EscortObjects.Server)
	end

	table.insert(weaponIgnoreList, workspace.IgnoreInstances.MagicSpells)
	table.insert(weaponIgnoreList, workspace.IgnoreInstances.Regions)
	table.insert(weaponIgnoreList, workspace.IgnoreInstances.Map.MagicSpells)
	table.insert(weaponIgnoreList, workspace.IgnoreInstances.Map.Buildables)

	self:SetWeaponIgnoreList(weaponIgnoreList)

	-- Mob RaycastHitbox parts: collision group per mob, for every mob
	-- already present and every one parented from now on. Using
	-- Zombies.ChildAdded (instead of ZombieSpawnService.OnZombieSpawn)
	-- closes the spawn-window race described in
	-- _registerZombieRaycastHitbox above.
	for _, zombie in workspace.IgnoreInstances.Zombies:GetChildren() do
		task.spawn(function()
			self:_registerZombieRaycastHitbox(zombie)
		end)
	end
	workspace.IgnoreInstances.Zombies.ChildAdded:Connect(function(zombie)
		task.spawn(function()
			self:_registerZombieRaycastHitbox(zombie)
		end)
	end)
end

function IgnoreListService._initBuildingTransparencyIgnoreList(self: typeof(IgnoreListService))
	local buildingTransparencyIgnoreList = self:GetBuildingTransparencyIgnoreList()

	table.insert(buildingTransparencyIgnoreList, workspace.IgnoreInstances.Zombies)
	table.insert(buildingTransparencyIgnoreList, workspace.IgnoreInstances.MagicSpells)
	table.insert(buildingTransparencyIgnoreList, workspace.IgnoreInstances.Terrain)
	table.insert(buildingTransparencyIgnoreList, workspace.IgnoreInstances:FindFirstChild("EscortObjects") or nil)

	self:SetBuildingTransparencyIgnoreList(buildingTransparencyIgnoreList)
end

function IgnoreListService._initMagicSpellIgnoreList(self: typeof(IgnoreListService))
	local magicSpellIgnoreList = self:GetMagicSpellIgnoreList()

	table.insert(magicSpellIgnoreList, workspace.IgnoreInstances.Terrain)
	table.insert(magicSpellIgnoreList, workspace.IgnoreInstances:FindFirstChild("EscortObjects") or nil)
	table.insert(magicSpellIgnoreList, workspace.IgnoreInstances.Map.MagicSpells)
	table.insert(magicSpellIgnoreList, workspace.IgnoreInstances.Map.Buildables)

	self:SetMagicSpellIgnoreList(magicSpellIgnoreList)
end

function IgnoreListService._initProximityRayIgnoreList(self: typeof(IgnoreListService))
	local proximityRayIgnoreList = self:GetProximityRayIgnoreList()

	table.insert(proximityRayIgnoreList, workspace.IgnoreInstances.Map)
	table.insert(proximityRayIgnoreList, workspace.IgnoreInstances.MagicSpells)
	table.insert(proximityRayIgnoreList, workspace.IgnoreInstances.DeadZombies)
	table.insert(proximityRayIgnoreList, workspace.IgnoreInstances:FindFirstChild("EscortObjects") or nil)
	table.insert(proximityRayIgnoreList, workspace.IgnoreInstances.Chests)
	table.insert(proximityRayIgnoreList, workspace.IgnoreInstances.Map.MagicSpells)
	table.insert(proximityRayIgnoreList, workspace.IgnoreInstances.Map.Buildables)

	self:SetProximityRayIgnoreList(proximityRayIgnoreList)
end

-- Drops every entry whose instance has left the game. Reverse iteration:
-- table.remove inside a forward loop skips the element after each hit.
local function removeDestroyed(list: { Instance })
	for i = #list, 1, -1 do
		if list[i].Parent == nil then
			table.remove(list, i)
		end
	end
end

-- No yields between each Get and Set (see the note in Start).
function IgnoreListService._pruneDestroyedEntries(self: typeof(IgnoreListService))
	local weaponIgnoreList = table.clone(self:GetWeaponIgnoreList())
	removeDestroyed(weaponIgnoreList)
	self:SetWeaponIgnoreList(weaponIgnoreList)

	local magicSpellIgnoreList = self:GetMagicSpellIgnoreList()
	removeDestroyed(magicSpellIgnoreList)
	self:SetMagicSpellIgnoreList(magicSpellIgnoreList)

	local proximityRayList = self:GetProximityRayIgnoreList()
	removeDestroyed(proximityRayList)
	self:SetProximityRayIgnoreList(proximityRayList)
end

function IgnoreListService.Start(self: typeof(IgnoreListService))
	self:_registerCollisionGroups()
	self:_initWeaponIgnoreList()
	self:_initBuildingTransparencyIgnoreList()
	self:_initMagicSpellIgnoreList()
	self:_initProximityRayIgnoreList()

	-- Initialize players into ignore list. NEVER yield between Get
	-- and Set on these lists — `CharacterAdded:Wait()` is a yield,
	-- and while it's parked other tasks (e.g. the deferred zombie
	-- RaycastHitbox registrations spawned by _InitWeaponIgnoreList)
	-- run and write the list. If we Get pre-yield and Set post-yield
	-- we clobber their additions with our stale snapshot. Resolving
	-- the character FIRST keeps Get→insert→Set yield-free.
	for _, player in Players:GetPlayers() do
		local character = player.Character or player.CharacterAdded:Wait()

		local weaponIgnoreList = table.clone(self:GetWeaponIgnoreList())
		table.insert(weaponIgnoreList, character)
		self:SetWeaponIgnoreList(weaponIgnoreList)

		local magicSpellIgnoreList = self:GetMagicSpellIgnoreList()
		table.insert(magicSpellIgnoreList, character)
		self:SetMagicSpellIgnoreList(magicSpellIgnoreList)

		local proximityRayIgnoreList = self:GetProximityRayIgnoreList()
		table.insert(proximityRayIgnoreList, character)
		self:SetProximityRayIgnoreList(proximityRayIgnoreList)
	end

	PlayerEventService.OnPlayerAdded:Connect(function(player: Player)
		local character = player.Character or player.CharacterAdded:Wait()

		local weaponIgnoreList = table.clone(self:GetWeaponIgnoreList())
		local magicSpellIgnoreList = self:GetMagicSpellIgnoreList()
		local proximityRayIgnoreList = self:GetProximityRayIgnoreList()

		if not table.find(weaponIgnoreList, character) then
			table.insert(weaponIgnoreList, character)
			self:SetWeaponIgnoreList(weaponIgnoreList)
		end

		if not table.find(magicSpellIgnoreList, character) then
			table.insert(magicSpellIgnoreList, character)
			self:SetMagicSpellIgnoreList(magicSpellIgnoreList)
		end

		if not table.find(proximityRayIgnoreList, character) then
			table.insert(proximityRayIgnoreList, character)
			self:SetProximityRayIgnoreList(proximityRayIgnoreList)
		end
	end)

	-- Sweep destroyed characters out of the lists. On leave, and on every
	-- respawn: OnPlayerAdded fires once per join, so the previous life's
	-- (destroyed) character stayed in all three lists otherwise.
	PlayerEventService.OnPlayerRemoved:Connect(function(_: Player)
		self:_pruneDestroyedEntries()
	end)
	PlayerEventService.OnCharacterAdded:Connect(function(_player: Player, _character: Model)
		self:_pruneDestroyedEntries()
	end)
end

return IgnoreListService
