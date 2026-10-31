--!strict
--[[
	Module: BreakableLootService.lua
	Description:
	Places LOOT BREAKABLES as a floor is built and pays them out when they
	break (2026-10-29). Every Combat room, and every Event room but the
	shop (BreakableLootData.ExcludedEventPrefabs), and pots (no vein) in
	every Treasure branch; never a Miniboss or Boss arena.

	  * crystal VEINS -> Forge Ore, private per player, a fixed amount per
	    vein by floor (scaled by tier) ON TOP of the chests, bursting out
	    as several pickups. One in about half the rooms.
	  * POTS -> a public Gem pickup, a rare public Health / Mana orb,
	    and a rare private Gold handful per
	    player. 4-7 a room, in short rows.

	WHERE (the Hades rule: breakables hug the walls, never the fight): a
	ray from a random point on the room's floor out to one of its Walls
	gives a wall face and its inward normal; a pot row stands along it,
	`wallInset` studs in so nothing touches the wall, and a vein sits alone
	a little further in. Every spot must land on THIS room's Floor and
	overlap nothing but floor, and keeps clear of other loot and of every
	doorway (ExitGates and DungeonBarricades, entrances and exits alike).

	Numbers live in Shared/Data/BreakableLootData. Each piece is a plain
	Breakable model (tagged; BreakHits / ArcaneHits / BreakStyle /
	ShardColor stamped), so melee, bullets and spells hit it with no extra
	wiring, and BreakableController plays its flash, shake, sparks and the
	shatter / sink. Breakable.Signals.Broken tells this service when one
	breaks. The model is GameAssets.Breakables.<model>.

	Spawned on DungeonService.OnDungeonGenerated, which fires just BEFORE
	OnFloorReady -- so FogOfWarService hides the loot with the rest of its
	room and reveals it on entry. Parented under the room model, so the
	floor teardown destroys whatever was not broken.
]]

--[ Roblox Services ]--

local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

--[ Imports ]--

local Blitz = require(ReplicatedStorage.Submodules.Core.Shared.Blitz)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local DropTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.DropTypes)
local RoomTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RoomTypes)
local BreakableLootData = require(ReplicatedStorage.Submodules.Core.Shared.Data.BreakableLootData)
local DifficultyData = require(ReplicatedStorage.Submodules.Core.Shared.Data.DifficultyData)
local DropService = require(ServerScriptService.Services.DropService)
local Breakable = require(ServerScriptService.Components.Breakable)
local Log = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Log)

--[ Constants ]--

local FLOOR_NAME = "Floor"
local WALL_NAME = "Wall"
local EXIT_GATE_NAME = "ExitGate"
local BARRICADE_NAME = "DungeonBarricade"
local LOOT_FOLDER_NAME = "BreakableLoot"
-- Wall rays start this high off the floor (above props' feet, below roofs).
local WALL_RAY_HEIGHT = 3
-- Ground snaps: from this far above a spot, this far down.
local GROUND_RAY_HEIGHT = 10
local GROUND_RAY_DEPTH = 25
-- A pot faces out from its wall, give or take this many degrees.
local POT_YAW_JITTER = 25
-- Seconds the drop origin outlives the break (DropService paces pickups
-- out over a short delay).
local DROP_ORIGIN_LIFETIME = 6

local VEIN = BreakableLootData.Vein
local POT = BreakableLootData.Pot
local PLACEMENT = BreakableLootData.Placement

--[ Types ]--

type VeinState = { units: number }
type WallHit = { position: Vector3, normal: Vector3 }

--[ Module ]--

local BreakableLootService = {
	Name = "BreakableLootService",
	Dependencies = { DropService } :: { any },

	-- This floor's live loot, keyed by model.
	_veins = {} :: { [Model]: VeinState },
	_pots = {} :: { [Model]: boolean },
	-- What one vein UNIT pays in Ore (VEIN.oreShare x the tier's
	-- chestOre), and one Gold handful in Gold, on the current floor (set when
	-- the floor is built).
	_oreUnitValue = 0,
	_goldHandfulValue = 0,
	_warnedMissing = {} :: { [string]: boolean },
	-- Why placements failed this floor, for the Studio debug line:
	-- [reason] = count, plus the names of parts that blocked a spot.
	_placementMisses = {} :: { [string]: number },
	_blockers = {} :: { [string]: number },
}

--[ Private Functions ]--

-- A stochastic round: 2.3 is 2 seven times in ten and 3 the rest, so a
-- floor's take is exact on average however small each piece's share.
local function roundStochastic(value: number): number
	local whole = math.floor(value)
	return whole + (if math.random() < value - whole then 1 else 0)
end

local function weightedPick<T>(entries: { T }, weightOf: (T) -> number): T
	local total = 0
	for _, entry in entries do
		total += weightOf(entry)
	end
	local roll = math.random() * total
	for _, entry in entries do
		roll -= weightOf(entry)
		if roll <= 0 then
			return entry
		end
	end
	return entries[#entries]
end

local function roomFloors(roomModel: Model): { BasePart }
	local floors = {}
	for _, descendant in roomModel:GetDescendants() do
		if descendant:IsA("BasePart") and descendant.Name == FLOOR_NAME then
			table.insert(floors, descendant)
		end
	end
	return floors
end

-- A random point on top of one of the room's floors, larger floors likelier.
local function randomFloorPoint(floors: { BasePart }): Vector3
	local floor = weightedPick(floors, function(part)
		return part.Size.X * part.Size.Z
	end)
	local x = (math.random() - 0.5) * floor.Size.X
	local z = (math.random() - 0.5) * floor.Size.Z
	return floor.CFrame:PointToWorldSpace(Vector3.new(x, floor.Size.Y / 2, z))
end

-- The point straight below `position` on THIS room's floor, or nil.
local function groundOnRoom(roomModel: Model, position: Vector3): Vector3?
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { roomModel }
	local hit =
		workspace:Raycast(position + Vector3.new(0, GROUND_RAY_HEIGHT, 0), Vector3.new(0, -GROUND_RAY_DEPTH, 0), params)
	if not hit or hit.Instance.Name ~= FLOOR_NAME then
		return nil
	end
	return hit.Position
end

-- The first wall a horizontal ray from `from` meets, with its inward
-- (flattened) normal, or nil. Walls live in Map.DungeonRooms.Walls, not
-- in their room, so the ray looks at the whole walls folder; the callers'
-- ground check is what keeps the spot inside this room.
local function wallFrom(roomModel: Model, from: Vector3): WallHit?
	local runtimeFolder = roomModel.Parent
	local walls = runtimeFolder and runtimeFolder:FindFirstChild("Walls")
	if not walls then
		return nil
	end
	local angle = math.random() * math.pi * 2
	local direction = Vector3.new(math.cos(angle), 0, math.sin(angle)) * PLACEMENT.wallRayLength
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { walls }
	local hit = workspace:Raycast(from + Vector3.new(0, WALL_RAY_HEIGHT, 0), direction, params)
	if not hit or hit.Instance.Name ~= WALL_NAME then
		return nil
	end
	local normal = hit.Normal * Vector3.new(1, 0, 1)
	if normal.Magnitude < 0.5 then
		return nil
	end
	return { position = hit.Position, normal = normal.Unit }
end

-- True when a footprint of `size` at `ground` overlaps nothing in the
-- dungeon but floor (walls, props, pillars, gate barricades, other loot).
-- The first blocker's name is handed to `onBlocked` (the debug tally).
local function spotIsClear(roomModel: Model, ground: Vector3, size: Vector3, onBlocked: ((string) -> ())?): boolean
	local runtimeFolder = roomModel.Parent
	if not runtimeFolder then
		return false
	end
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { runtimeFolder }
	local parts = workspace:GetPartBoundsInBox(
		CFrame.new(ground + Vector3.new(0, size.Y / 2 + 0.3, 0)),
		Vector3.new(size.X, size.Y, size.Z),
		params
	)
	for _, part in parts do
		if part.Name ~= FLOOR_NAME then
			if onBlocked then
				onBlocked(part.Name)
			end
			return false
		end
	end
	return true
end

local function farFromAll(position: Vector3, others: { Vector3 }, spacing: number): boolean
	for _, other in others do
		if ((position - other) * Vector3.new(1, 0, 1)).Magnitude < spacing then
			return false
		end
	end
	return true
end

-- An invisible anchored stand-in at `position` for DropService to throw
-- pickups from: the broken model is going away.
local function dropOrigin(position: Vector3): BasePart
	local part = Instance.new("Part")
	part.Name = "BreakableLootOrigin"
	part.Size = Vector3.new(1, 1, 1)
	part.Transparency = 1
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Position = position + Vector3.new(0, 1.5, 0)
	part.Parent = workspace.IgnoreInstances
	Debris:AddItem(part, DROP_ORIGIN_LIFETIME)
	return part
end

-- Private pickups of one currency for every player, `totalFor` each,
-- spread over at most `maxPickups` pickups whose values sum to it (a
-- total of 8 over 6 pickups is four 1s and two 2s).
local function dropPrivate(origin: BasePart, dropType: string, maxPickups: number, totalFor: (Player) -> number)
	for _, player in Players:GetPlayers() do
		local total = totalFor(player)
		if total <= 0 then
			continue
		end
		local pickups = math.min(total, maxPickups)
		local base = total // pickups
		local bigger = total - base * pickups
		local small = pickups - bigger
		if small > 0 then
			DropService.OnDropRequested:Fire(origin, dropType, small, small, base, base, false, player.UserId, true)
		end
		if bigger > 0 then
			DropService.OnDropRequested:Fire(
				origin,
				dropType,
				bigger,
				bigger,
				base + 1,
				base + 1,
				false,
				player.UserId,
				true
			)
		end
	end
end

-- What loot a room gets: "all" (a vein roll and pots) for Combat and
-- Event rooms but the shop, "pots" for a Treasure branch, nil otherwise.
local function lootFor(room: any): string?
	if not room.model then
		return nil
	end
	if room.roomType == RoomTypes.Combat then
		return "all"
	end
	if room.roomType == RoomTypes.Treasure then
		return "pots"
	end
	if room.roomType == RoomTypes.Event then
		local prefab = room.model:GetAttribute("PrefabName")
		return if type(prefab) == "string" and BreakableLootData.ExcludedEventPrefabs[prefab] then nil else "all"
	end
	return nil
end

-- Every doorway on the floor: each ExitGate (one room's exit is the next
-- one's entrance) and each DungeonBarricade, the treasure branches'
-- included. Loot keeps PLACEMENT.doorwayClearance from all of them.
local function doorwaysIn(runtimeFolder: Instance): { Vector3 }
	local spots = {}
	for _, descendant in runtimeFolder:GetDescendants() do
		if descendant.Name == EXIT_GATE_NAME and descendant:IsA("BasePart") then
			table.insert(spots, descendant.Position)
		elseif descendant.Name == BARRICADE_NAME and descendant:IsA("Model") then
			table.insert(spots, descendant:GetPivot().Position)
		end
	end
	return spots
end

--[ Spawning ]--

-- A clone of GameAssets.Breakables.<modelName>, scaled, with a
-- PrimaryPart (Breakable reads it), or nil when the asset is missing.
function BreakableLootService._makeModel(self: typeof(BreakableLootService), modelName: string, scale: number?): Model?
	local assets = ReplicatedStorage:FindFirstChild("GameAssets")
	local folder = assets and assets:FindFirstChild("Breakables")
	local template = folder and folder:FindFirstChild(modelName)
	if not template or not template:IsA("Model") then
		if not self._warnedMissing[modelName] then
			self._warnedMissing[modelName] = true
			warn("[BreakableLootService] Missing ReplicatedStorage.GameAssets.Breakables." .. modelName)
		end
		return nil
	end
	local model = template:Clone()
	if not model.PrimaryPart then
		model.PrimaryPart = model:FindFirstChildWhichIsA("BasePart", true)
	end
	if not model.PrimaryPart then
		model:Destroy()
		return nil
	end
	if scale then
		model:ScaleTo(scale)
	end
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = true
			-- Walk-through for players and mobs (the mob sim's walk casts
			-- respect CanCollide), but still queryable, so weapon, bullet
			-- and spell hitboxes find it.
			part.CanCollide = false
			part.CanQuery = true
		end
	end
	return model
end

-- Stands `model` on `ground` facing `facing`, stamps it and parents it.
local function placeModel(model: Model, ground: Vector3, facing: Vector3, folder: Instance, stamps: { [string]: any })
	model:PivotTo(CFrame.lookAt(ground, ground + facing))
	local boxCFrame, boxSize = model:GetBoundingBox()
	local lift = ground.Y - (boxCFrame.Position.Y - boxSize.Y / 2)
	model:PivotTo(model:GetPivot() + Vector3.new(0, lift, 0))
	for name, value in stamps do
		model:SetAttribute(name, value)
	end
	CollectionService:AddTag(model, TagList.Breakable)
	-- Atomic: the client shakes, shatters and sinks the model as a unit.
	model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
	model.Parent = folder
end

function BreakableLootService._spawnRoom(
	self: typeof(BreakableLootService),
	roomModel: Model,
	withVein: boolean,
	doorways: { Vector3 }
): (number, number)
	local floors = roomFloors(roomModel)
	if #floors == 0 then
		return 0, 0
	end
	local taken: { Vector3 } = {}

	local folder = Instance.new("Folder")
	folder.Name = LOOT_FOLDER_NAME
	folder.Parent = roomModel

	local misses = self._placementMisses
	local function miss(reason: string)
		misses[reason] = (misses[reason] or 0) + 1
	end
	local function blocked(partName: string)
		miss("blocked")
		self._blockers[partName] = (self._blockers[partName] or 0) + 1
	end

	-- A spot `inset` studs in from some wall of this room, `along` studs
	-- along it from the hit, on this room's floor and clear for `size`.
	local function spotByWall(wall: WallHit, inset: number, along: number, size: Vector3): Vector3?
		local tangent = wall.normal:Cross(Vector3.yAxis).Unit
		local ground = groundOnRoom(roomModel, wall.position + wall.normal * inset + tangent * along)
		if not ground then
			miss("offRoom")
			return nil
		end
		if spotIsClear(roomModel, ground, size, blocked) then
			return ground
		end
		return nil
	end

	local function wallSpot(inset: number, size: Vector3): (Vector3?, WallHit?)
		for _ = 1, PLACEMENT.attempts do
			local wall = wallFrom(roomModel, randomFloorPoint(floors))
			if not wall then
				miss("noWall")
				continue
			end
			local spot = spotByWall(wall, inset, 0, size)
			if not spot then
				continue
			end
			if
				not farFromAll(spot, taken, PLACEMENT.minSpacing)
				or not farFromAll(spot, doorways, PLACEMENT.doorwayClearance)
			then
				miss("spacing")
				continue
			end
			return spot, wall
		end
		return nil, nil
	end

	-- The vein: one, in about half the rooms.
	local veinUnits = 0
	if withVein and math.random() < VEIN.chancePerRoom then
		local size = weightedPick(VEIN.sizes, function(entry)
			return entry.weight
		end)
		local model = self:_makeModel(size.model, size.scale)
		if model then
			local spot, wall = wallSpot(VEIN.wallInset, model:GetExtentsSize())
			if spot and wall then
				table.insert(taken, spot)
				placeModel(model, spot, wall.normal, folder, {
					[Attributes.BreakHits] = size.hits,
					-- One spell breaks a crystal of any size.
					[Attributes.ArcaneHits] = size.hits,
					[Attributes.BreakStyle] = "Sink",
					[Attributes.ShardColor] = VEIN.shardColor,
				})
				self._veins[model] = { units = size.units }
				veinUnits += size.units
			else
				miss("veinGaveUp")
				model:Destroy()
			end
		end
	end

	-- The pots: rows of 2-3 standing along a wall.
	local pots = 0
	local remaining = math.random(POT.minPerRoom, POT.maxPerRoom)
	local retries = POT.rowRetries
	while remaining > 0 do
		local rowSize = math.min(remaining, math.random(POT.minPerCluster, POT.maxPerCluster))
		remaining -= rowSize
		local probe = self:_makeModel(weightedPick(POT.models, function(row)
			return row.weight
		end).model)
		if not probe then
			break
		end
		local extents = probe:GetExtentsSize()
		local centre, wall = wallSpot(POT.wallInset, extents)
		probe:Destroy()
		if not centre or not wall then
			-- No room for this row: its pots try again in another row.
			if retries > 0 then
				retries -= 1
				remaining += rowSize
			end
			continue
		end
		table.insert(taken, centre)
		for index = 1, rowSize do
			local along = (index - (rowSize + 1) / 2) * POT.rowSpacing
			local spot = spotByWall(wall, POT.wallInset, along, extents)
			local model = spot
				and self:_makeModel(weightedPick(POT.models, function(row)
					return row.weight
				end).model)
			if not spot or not model then
				continue
			end
			local yaw = math.rad((math.random() * 2 - 1) * POT_YAW_JITTER)
			local facing = CFrame.Angles(0, yaw, 0):VectorToWorldSpace(wall.normal)
			placeModel(model, spot, facing, folder, {
				[Attributes.BreakHits] = POT.hits,
				-- A spell breaks a pot outright too.
				[Attributes.ArcaneHits] = POT.hits,
				[Attributes.BreakStyle] = "Shatter",
				[Attributes.ShardColor] = POT.shardColor,
			})
			self._pots[model] = true
			pots += 1
		end
	end

	return veinUnits, pots
end

function BreakableLootService._spawnFloor(self: typeof(BreakableLootService), dungeon: any)
	table.clear(self._veins)
	table.clear(self._pots)
	table.clear(self._placementMisses)
	table.clear(self._blockers)

	local totalUnits, totalPots = 0, 0
	local doorways: { Vector3 }? = nil
	local function spawnIn(room: any)
		local loot = lootFor(room)
		if not loot then
			return
		end
		doorways = doorways or doorwaysIn(room.model.Parent or workspace)
		local units, pots = self:_spawnRoom(room.model, loot == "all", doorways :: { Vector3 })
		totalUnits += units
		totalPots += pots
	end
	for _, room in dungeon.rooms do
		spawnIn(room)
		-- A Treasure branch hangs off its host room, not dungeon.rooms.
		if room.branch then
			spawnIn(room.branch)
		end
	end

	-- The floor's budgets, split over what was actually placed.
	local dungeonService = Blitz.OptionalService("DungeonService")
	local tier = if dungeonService then dungeonService:GetDifficultyScale() else nil
	local floor = if dungeonService then dungeonService:GetFloor() else 1
	local floorShare = if tier then DifficultyData.FloorShare(tier, floor) else 0
	local goldBudget = (if tier then DifficultyData.RunGoldTake(tier) else 0) * POT.goldShare * floorShare
	-- Ore is a fixed share of the tier's run chestOre per vein unit
	-- (BreakableLootData.Vein.oreShare); the dungeon's rewardScale is
	-- applied on collect (DropService).
	self._oreUnitValue = (if tier then tier.chestOre or 0 else 0) * VEIN.oreShare
	self._goldHandfulValue = if totalPots > 0 then goldBudget / (totalPots * POT.goldChance) else 0

	local missText, blockerText = {}, {}
	for reason, count in self._placementMisses do
		table.insert(missText, reason .. "=" .. count)
	end
	for name, count in self._blockers do
		table.insert(blockerText, name .. "=" .. count)
	end
	Log.debug(
		("[BreakableLootService] Floor loot: %d vein(s), %d pot(s), %.2f ore/vein unit. Misses: %s. Blockers: %s"):format(
			totalUnits,
			totalPots,
			self._oreUnitValue,
			if #missText > 0 then table.concat(missText, ", ") else "none",
			if #blockerText > 0 then table.concat(blockerText, ", ") else "none"
		)
	)
end

--[ Payouts ]--

function BreakableLootService._onBroken(self: typeof(BreakableLootService), model: Model)
	local primary = model.PrimaryPart
	if not primary then
		self._veins[model] = nil
		self._pots[model] = nil
		return
	end

	local vein = self._veins[model]
	if vein then
		self._veins[model] = nil
		-- Every player in the run gets their OWN Ore from it, whoever broke
		-- it (private pickups, DropService).
		dropPrivate(dropOrigin(primary.Position), DropTypes.ForgeOre, VEIN.maxOrePickups, function()
			return roundStochastic(vein.units * self._oreUnitValue)
		end)
		return
	end

	if not self._pots[model] then
		return
	end
	self._pots[model] = nil
	local origin = dropOrigin(primary.Position)

	-- Gems: one public pickup, like a mob's (the tier's GemScale applies
	-- when it is collected).
	DropService.OnDropRequested:Fire(origin, DropTypes.Gems, 1, 1, POT.minGems, POT.maxGems, false)

	-- Gold: one roll per pot; on a hit, every player gets their own handful.
	if math.random() < POT.goldChance and self._goldHandfulValue > 0 then
		for _, player in Players:GetPlayers() do
			local value = math.max(roundStochastic(self._goldHandfulValue), 1)
			DropService.OnDropRequested:Fire(origin, DropTypes.Coins, 1, 1, value, value, false, player.UserId, true)
		end
	end

	-- Orb: one roll per pot; on a hit, one public Health or Mana orb, a
	-- coin flip between them, exactly as a grunt's corpse drops them.
	if math.random() < POT.orbChance then
		local orbType = if math.random() < 0.5 then DropTypes.Health else DropTypes.Mana
		DropService.OnDropRequested:Fire(origin, orbType, 1, 1, 1, 1, false)
	end
end

--[ Lifecycle ]--

function BreakableLootService.Start(self: typeof(BreakableLootService))
	Breakable.Signals.Broken:Connect(function(model: Model)
		self:_onBroken(model)
	end)

	local dungeonService = Blitz.OptionalService("DungeonService")
	if not dungeonService then
		return
	end
	-- OnDungeonGenerated fires just before OnFloorReady, where the fog
	-- hides each room's contents -- loot placed here is hidden with them.
	dungeonService.Signals.OnDungeonGenerated:Connect(function(dungeon)
		self:_spawnFloor(dungeon)
	end)
	dungeonService.Signals.OnFloorTeardown:Connect(function()
		table.clear(self._veins)
		table.clear(self._pots)
	end)
end

return BreakableLootService
