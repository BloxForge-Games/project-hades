local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local IgnoreListData = require(ReplicatedStorage.Submodules.Core.Shared.Data.IgnoreListData)

local PlayerEventService

local IgnoreListService = Knit.CreateService({
	Name = "IgnoreListService",
	Client = {
		WeaponIgnoreList = Knit.CreateProperty(table.clone(IgnoreListData)),
		BuildingTransparencyIgnoreList = Knit.CreateProperty(table.clone(IgnoreListData)),
		MagicSpellIgnoreList = Knit.CreateProperty(table.clone(IgnoreListData)),
		ProximityRayIgnoreList = Knit.CreateProperty({}),
		ZombieMagicSpellIgnoreList = Knit.CreateProperty({
			workspace.IgnoreInstances:FindFirstChild("Zombies") or nil,
			workspace.IgnoreInstances:FindFirstChild("DeadZombies") or nil,
			workspace.IgnoreInstances:FindFirstChild("Terrain") or nil,
			workspace.IgnoreInstances:FindFirstChild("MapMarkers") or nil,
			workspace.IgnoreInstances:FindFirstChild("Boundaries") or nil,
			workspace.IgnoreInstances:FindFirstChild("Regions") or nil,
			workspace.IgnoreInstances:FindFirstChild("MagicSpells") or nil,
			workspace.IgnoreInstances:FindFirstChild("Chests") or nil,
			workspace:FindFirstChild("PlayerBaseplates") or nil,
			workspace:FindFirstChild("Terrain") or nil,
		}),
	},
})

function IgnoreListService:SetWeaponIgnoreList(newIgnoreList: { Instance })
	self.Client.WeaponIgnoreList:Set(newIgnoreList)
end

function IgnoreListService:SetBuildingTransparencyIgnoreList(newIgnoreList: { Instance })
	self.Client.BuildingTransparencyIgnoreList:Set(newIgnoreList)
end

function IgnoreListService:SetMagicSpellIgnoreList(newIgnoreList: { Instance })
	self.Client.MagicSpellIgnoreList:Set(newIgnoreList)
end

function IgnoreListService:SetProximityRayIgnoreList(newIgnoreList: { Instance })
	self.Client.ProximityRayIgnoreList:Set(newIgnoreList)
end

function IgnoreListService:SetZombieMagicSpellIgnoreList(newIgnoreList: { Instance })
	self.Client.ZombieMagicSpellIgnoreList:Set(newIgnoreList)
end

function IgnoreListService:GetWeaponIgnoreList(): { Instance }
	return table.clone(self.Client.WeaponIgnoreList:Get())
end

function IgnoreListService:GetBuildingTransparencyIgnoreList(): { Instance }
	return table.clone(self.Client.BuildingTransparencyIgnoreList:Get())
end

function IgnoreListService:GetMagicSpellIgnoreList(): { Instance }
	return table.clone(self.Client.MagicSpellIgnoreList:Get())
end

function IgnoreListService:GetProximityRayIgnoreList(): { Instance }
	return table.clone(self.Client.ProximityRayIgnoreList:Get())
end

function IgnoreListService:GetZombieMagicSpellIgnoreList(): { Instance }
	return table.clone(self.Client.ZombieMagicSpellIgnoreList:Get())
end

-- Per-zombie hookup that adds the mob's RaycastHitbox to the weapon
-- ignore list the moment it's available on the model, and removes it
-- the moment the part is destroyed (or the zombie is reparented out).
--
-- Why this is keyed on Zombies.ChildAdded + WaitForChild rather than
-- ZombieSpawnService.OnZombieSpawn:
--   The OnZombieSpawn signal fires from MobBase only AFTER the fade-in
--   delay (~0.25s + the spawn animation). During that window the
--   zombie's RaycastHitbox already exists in workspace but isn't in
--   the ignore list yet, and any projectile fired into that window
--   takes a snapshot of the list that doesn't include the new hitbox
--   — so the projectile hits the (invisible, aim-assist-only)
--   RaycastHitbox instead of the actual zombie geometry.
--
--   ChildAdded fires the instant the model is parented, and
--   WaitForChild blocks until the part appears, so the registration
--   races the projectile pipeline reliably.
function IgnoreListService:_registerZombieRaycastHitbox(zombie: Instance)
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
	-- Guard against the zombie having been reparented out (e.g. early
	-- death) while we were waiting.
	if not zombie:IsDescendantOf(workspace.IgnoreInstances.Zombies) then
		return
	end

	local weaponIgnoreList = self:GetWeaponIgnoreList()
	if not table.find(weaponIgnoreList, hitbox) then
		table.insert(weaponIgnoreList, hitbox)
		self:SetWeaponIgnoreList(weaponIgnoreList)
	end

	-- Drop the entry the moment the part is destroyed. Previously the
	-- de-register path ran on OnZombieDespawn, but MobBase destroys
	-- the RaycastHitbox during _relocateToDeadFolder which runs BEFORE
	-- the despawn signal — so `zombie:FindFirstChild("RaycastHitbox")`
	-- returned nil and the original reference leaked in the list.
	-- Listening to Destroying on the part itself sidesteps that race.
	hitbox.Destroying:Connect(function()
		local list = self:GetWeaponIgnoreList()
		local idx = table.find(list, hitbox)
		if idx then
			table.remove(list, idx)
			self:SetWeaponIgnoreList(list)
		end
	end)
end

function IgnoreListService:_InitWeaponIgnoreList()
	-- ORDER MATTERS. Every WeaponIgnoreList mutation in this file
	-- is a read-modify-write on the RemoteProperty (Get → mutate
	-- clone → Set). The static inserts below MUST happen and commit
	-- BEFORE any async zombie registration kicks off — otherwise the
	-- async tasks Set their list, then this code Sets a stale local
	-- snapshot, and the async additions are lost.
	--
	-- This was the actual reason RaycastHitbox was still being hit
	-- after the first pass at this fix: the existing-zombies loop
	-- task.spawn'd registrations whose WaitForChild yielded; this
	-- function then continued, snapshotted a list that didn't yet
	-- include those zombies' hitboxes, appended the static folders,
	-- and Set the property — clobbering the registrations that were
	-- in flight.
	local weaponIgnoreList = self:GetWeaponIgnoreList()

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

	-- Now (and only now) register zombies. Each registration is a
	-- self-contained Get → insert → Set, so as long as no other write
	-- racer exists outside this file, they layer cleanly on top of
	-- the static commit above.
	--
	-- Using Zombies.ChildAdded (instead of
	-- ZombieSpawnService.OnZombieSpawn) closes the spawn-window race
	-- described in _registerZombieRaycastHitbox above.
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

function IgnoreListService:_InitBuildingTransparencyIgnoreList()
	local buildingTransparencyIgnoreList = self:GetBuildingTransparencyIgnoreList()

	table.insert(buildingTransparencyIgnoreList, workspace.IgnoreInstances.Zombies)
	table.insert(buildingTransparencyIgnoreList, workspace.IgnoreInstances.MagicSpells)
	table.insert(buildingTransparencyIgnoreList, workspace.IgnoreInstances.Terrain)
	table.insert(buildingTransparencyIgnoreList, workspace.IgnoreInstances:FindFirstChild("EscortObjects") or nil)

	self:SetBuildingTransparencyIgnoreList(buildingTransparencyIgnoreList)
end

function IgnoreListService:_InitMagicSpellIgnoreList()
	local magicSpellIgnoreList = self:GetMagicSpellIgnoreList()

	table.insert(magicSpellIgnoreList, workspace.IgnoreInstances.Terrain)
	table.insert(magicSpellIgnoreList, workspace.IgnoreInstances:FindFirstChild("EscortObjects") or nil)
	table.insert(magicSpellIgnoreList, workspace.IgnoreInstances.Map.MagicSpells)
	table.insert(magicSpellIgnoreList, workspace.IgnoreInstances.Map.Buildables)

	self:SetMagicSpellIgnoreList(magicSpellIgnoreList)
end

function IgnoreListService:_InitProximityRayIgnoreList()
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

function IgnoreListService:KnitInit()
	PlayerEventService = Knit.GetService("PlayerEventService")
end

function IgnoreListService:KnitStart()
	self:_InitWeaponIgnoreList()
	self:_InitBuildingTransparencyIgnoreList()
	self:_InitMagicSpellIgnoreList()
	self:_InitProximityRayIgnoreList()

	-- Initialize players into ignore list. NEVER yield between Get
	-- and Set on these lists — `CharacterAdded:Wait()` is a yield,
	-- and while it's parked other tasks (e.g. the deferred zombie
	-- RaycastHitbox registrations spawned by _InitWeaponIgnoreList)
	-- run and write the list. If we Get pre-yield and Set post-yield
	-- we clobber their additions with our stale snapshot. Resolving
	-- the character FIRST keeps Get→insert→Set yield-free.
	for _, player in Players:GetPlayers() do
		local character = player.Character or player.CharacterAdded:Wait()

		local weaponIgnoreList = self:GetWeaponIgnoreList()
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

		local weaponIgnoreList = self:GetWeaponIgnoreList()
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

	PlayerEventService.OnPlayerRemoved:Connect(function(_: Player)
		local weaponIgnoreList = self:GetWeaponIgnoreList()

		for i, value in weaponIgnoreList do
			if value.Parent == nil then
				table.remove(weaponIgnoreList, i)
			end
		end

		self:SetWeaponIgnoreList(weaponIgnoreList)

		local magicSpellIgnoreList = self:GetMagicSpellIgnoreList()

		for i, value in magicSpellIgnoreList do
			if value.Parent == nil then
				table.remove(magicSpellIgnoreList, i)
			end
		end

		self:SetMagicSpellIgnoreList(magicSpellIgnoreList)

		local proximityRayList = self:GetProximityRayIgnoreList()

		for i, value in proximityRayList do
			if value.Parent == nil then
				table.remove(proximityRayList, i)
			end
		end

		self:SetProximityRayIgnoreList(proximityRayList)
	end)
end

return IgnoreListService
