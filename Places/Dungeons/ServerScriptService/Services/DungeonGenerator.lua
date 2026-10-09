--!strict
--[[
     Author(s):
     Module: DungeonGenerator.lua
     Description: Generates dungeon layouts. Snaps prefab chunks together via
                  EntryAnchor/ExitAnchor and produces a list of room models. Pure
                  placement only: no player state, no run state. RunFlowService
                  calls Generate, then wires the floor into the run (the exit
                  portal, the active-dungeon flip, the landing).

     Prefab contract — each room Model in ServerStorage.GameAssets.DungeonRooms.<pool>
     should have:
        - PrimaryPart set
        - Floor (BasePart, one or more) — used as the room's collision footprint
        - EntryAnchor (BasePart) — face the room is entered from
        - ExitAnchor (BasePart, optional for terminal rooms like Boss) — face the next
          room is glued to
        - BranchAnchor (BasePart, optional, may appear multiple times) — faces a
          Treasure branch can sprout from
]]

--[ Roblox Services ]--

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local ServerScriptService = game:GetService("ServerScriptService")

--[ Exports & Types & Defaults ]--

local DungeonService = require(ServerScriptService.Services.DungeonService)
local GateService = require(ServerScriptService.Services.GateService)
local CollisionGroupService = require(ServerScriptService.Submodules.Core.Source.Services.CollisionGroupService)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local DungeonData = require(ReplicatedStorage.Submodules.Core.Shared.Data.DungeonData)
local Planner = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Dungeon.Planner)
local RoomTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RoomTypes)
local EventWeights = require(ReplicatedStorage.Submodules.Core.Shared.Data.EventWeights)
local Log = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Log)

type Room = DungeonService.Room
type Dungeon = DungeonService.Dungeon

-- What Generate needs to place one floor. `forceShopAfterMiniboss` is the
-- Planner's first-floor rule (RunFlowService decides it from the run index).
export type GenerateDescriptor = {
	dungeonId: string,
	difficulty: string,
	seed: number?,
	originCFrame: CFrame?,
	forceShopAfterMiniboss: boolean?,
}

local DungeonGenerator = {
	Name = "DungeonGenerator",
	Dependencies = { DungeonService, GateService, CollisionGroupService } :: { any },
}

--[ Constants ]--

local PREFAB_FOLDER_NAME = "DungeonRooms"
local RUNTIME_FOLDER_NAME = "DungeonRooms"

local ENTRY_ANCHOR_NAME = "EntryAnchor"
local EXIT_ANCHOR_NAME = "ExitAnchor"
local BRANCH_ANCHOR_NAME = "BranchAnchor"
local EXIT_GATE_NAME = "ExitGate"
local BRANCH_WALL_NAME = "BranchWall"

local TRAPS_FOLDER_NAME = "Traps"
local TRAP_SPAWN_CHANCE = 0.75
-- Components/Trap's tag (not in TagList: the component declares it inline).
local TRAP_TAG = "Trap"
-- Same coin flip for the chunk's authored buildings (pillars): each one
-- spawns with this chance, before the survivors move to Map.Buildings
-- (_relocateChunkBuildings).
local BUILDING_SPAWN_CHANCE = TRAP_SPAWN_CHANCE

-- Runtime-folder children that are INFRASTRUCTURE, not dungeon content:
-- kept across teardown (Walls has its children cleared; the rest are left
-- entirely alone).
local RUNTIME_FOLDER_KEEP = { Walls = "clearChildren", Highlight = "keep" }
-- A chunk prefab may carry a "Buildings" folder of breakable building
-- Models. They are moved out to the map's Buildings folder at generation
-- (_relocateChunkBuildings) so they behave exactly like the static ones.
local BUILDINGS_FOLDER_NAME = "Buildings"

local FLOOR_NAME = "Floor"
local MAX_BACKTRACKS = 200 -- safety cap to prevent infinite loops on broken pools
-- The placement loop yields one frame (task.wait()) every this many
-- placements, where a placement is one prefab cloned and snapped into the
-- world to be tested -- a clone, a PivotTo, a floor scan and a
-- GetPartsInPart per candidate, whether or not it stays. A backtracking
-- floor burns hundreds of those; run without a break they stall every
-- other player's server tick for the whole swap. Callers already
-- tolerate GenerateDungeon yielding (its bounded character wait always
-- could): both run it from their own thread and read nothing back
-- until it returns.
local GENERATION_YIELD_EVERY_PLACEMENTS = 8

-- The prefabPools name for Event rooms (DungeonData). Only this pool is
-- weight-picked; every other pool stays uniform.
local EVENT_POOL_NAME = "Event"
-- The Planner forces one Event slot per floor to this prefab; placement
-- keeps it to AT MOST one (see the merchant rule in the placement loop).
local MERCHANT_SHOP_PREFAB_NAME = "MerchantShop"
local ROOM_ATTRIBUTE = "RoomId" -- set on each room model so encounter systems can map back to room data
local WALLS_PARENT_FOLDER = workspace.IgnoreInstances.Map.DungeonRooms.Walls

--[ Properties ]--

-- Set for the duration of Generate so prefab lookups resolve the dungeon
-- being built (before the active dungeon flips over to it).
DungeonGenerator._generatingDungeonId = nil :: string?
-- Buildings moved out of this floor's chunks (see _relocateChunkBuildings);
-- Map.Buildings sits outside the runtime folder, so DestroyFloor destroys
-- these explicitly or they pile up across floors.
DungeonGenerator._floorBuildings = {} :: { Model }

--[ Private Functions ]--

-- ServerStorage.GameAssets.DungeonRooms.<assetFolder> -- each dungeon has
-- its own prefab folder (Combat / Shrine / Miniboss / Boss / Treasure
-- pools + Start), named by its DungeonData assetFolder (placeholder
-- dungeons share one). Resolves the dungeon being GENERATED (or the active
-- one), and falls back to the flat DungeonRooms folder with a warn so an
-- unauthored dungeon still generates rather than asserting.
function DungeonGenerator._getPrefabRoot(self: typeof(DungeonGenerator)): Folder?
	local gameAssets = ServerStorage:FindFirstChild("GameAssets")
	local root = gameAssets and gameAssets:FindFirstChild(PREFAB_FOLDER_NAME)
	if not root then
		return nil
	end
	local active = DungeonService:GetActiveDungeon()
	local dungeonId = self._generatingDungeonId or (active and active.id)
	if dungeonId then
		local config = DungeonData[dungeonId]
		local folderName = if config and config.assetFolder then config.assetFolder else dungeonId
		local perDungeon = root:FindFirstChild(folderName)
		if perDungeon then
			return perDungeon
		end
		warn(
			("[DungeonGenerator] No prefab folder GameAssets.DungeonRooms.%s -- using the flat folder"):format(
				folderName
			)
		)
	end
	return root
end

function DungeonGenerator._pickPrefab(self: typeof(DungeonGenerator), poolName: string, rng: Random): Model
	local root = self:_getPrefabRoot()
	assert(root, "[DungeonGenerator] Missing ServerStorage.GameAssets." .. PREFAB_FOLDER_NAME)
	local folder = root:FindFirstChild(poolName)
	assert(folder, "[DungeonGenerator] Missing prefab pool folder: " .. poolName)
	local prefabs = folder:GetChildren()
	assert(#prefabs > 0, "[DungeonGenerator] Empty prefab pool: " .. poolName)
	return prefabs[rng:NextInteger(1, #prefabs)] :: Model
end

-- Picks a prefab from the pool, skipping any in `excluded`. Returns nil if
-- every variant has been tried.
-- Exact-name lookup in a pool folder, for Planner-forced prefabs.
function DungeonGenerator._findPrefabByName(
	self: typeof(DungeonGenerator),
	poolName: string,
	prefabName: string
): Model?
	local root = self:_getPrefabRoot()
	if not root then
		return nil
	end
	local folder = root:FindFirstChild(poolName)
	local model = folder and folder:FindFirstChild(prefabName)
	return if model and model:IsA("Model") then model else nil
end

-- Picks one prefab from `poolName`, skipping anything already tried for
-- this slot. Uniform for every pool EXCEPT Event, which is weighted by
-- Shared/Data/EventWeights so some events show up more than others.
--
-- The weighting re-normalises over what is actually available, so a
-- retry after a collision (the tried set grows) still spreads the
-- remaining prefabs by their authored ratios rather than falling back
-- to uniform. Weights are drawn from the SAME seeded rng as every other
-- layout roll, so a seed still reproduces its floor exactly.
function DungeonGenerator._pickPrefabExcluding(
	self: typeof(DungeonGenerator),
	poolName: string,
	excluded: { [Model]: true },
	rng: Random
): Model?
	local root = self:_getPrefabRoot()
	if not root then
		return nil
	end
	local folder = root:FindFirstChild(poolName)
	if not folder then
		return nil
	end
	local available: { Model } = {}
	for _, prefab in folder:GetChildren() do
		local prefabModel = prefab :: Model
		if not excluded[prefabModel] then
			table.insert(available, prefabModel)
		end
	end
	if #available == 0 then
		return nil
	end

	if poolName ~= EVENT_POOL_NAME then
		return available[rng:NextInteger(1, #available)]
	end

	local totalWeight = 0
	for _, prefab in available do
		totalWeight += EventWeights[prefab.Name] or EventWeights.DEFAULT_WEIGHT
	end
	if totalWeight <= 0 then
		return available[rng:NextInteger(1, #available)]
	end

	local roll = rng:NextNumber() * totalWeight
	for _, prefab in available do
		roll -= EventWeights[prefab.Name] or EventWeights.DEFAULT_WEIGHT
		if roll <= 0 then
			return prefab
		end
	end
	-- Float drift only; the loop above all but always returns.
	return available[#available]
end

function DungeonGenerator._getRoomFloors(_self: typeof(DungeonGenerator), model: Model): { BasePart }
	local floors = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") and descendant.Name == FLOOR_NAME then
			table.insert(floors, descendant)
		end
	end
	return floors
end

function DungeonGenerator._floorsOverlapAny(
	_self: typeof(DungeonGenerator),
	candidateFloors: { BasePart },
	placedFloors: { BasePart }
): boolean
	if #placedFloors == 0 then
		return false
	end
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = placedFloors :: { any }
	params.MaxParts = 1

	for _, floor in candidateFloors do
		local overlapping = workspace:GetPartsInPart(floor, params)
		if #overlapping > 0 then
			return true
		end
	end
	return false
end

-- World CFrame for either a BasePart (CFrame) or an Attachment (WorldCFrame).
function DungeonGenerator._anchorCFrame(_self: typeof(DungeonGenerator), anchor: Instance): CFrame?
	if anchor:IsA("BasePart") then
		return anchor.CFrame
	elseif anchor:IsA("Attachment") then
		return anchor.WorldCFrame
	end
	return nil
end

function DungeonGenerator._findAllAnchors(
	self: typeof(DungeonGenerator),
	instance: Instance,
	anchorName: string
): { Instance }
	local matches = {}
	for _, descendant in instance:GetDescendants() do
		if descendant.Name == anchorName and self:_anchorCFrame(descendant) then
			table.insert(matches, descendant)
		end
	end
	return matches
end

function DungeonGenerator._findAnchor(
	self: typeof(DungeonGenerator),
	instance: Instance,
	anchorName: string,
	optional: boolean?
): Instance?
	local direct = instance:FindFirstChild(anchorName)
	if direct and self:_anchorCFrame(direct) then
		return direct
	end
	local nested = instance:FindFirstChild(anchorName, true)
	if nested and self:_anchorCFrame(nested) then
		return nested
	end

	if optional then
		return nil
	end

	-- Diagnostic for required anchors: dump what we actually see so the user
	-- can tell whether the name has whitespace, the class is unexpected, or
	-- Archivable=false stripped the child during Clone.
	local wrongClass = direct or nested
	if wrongClass then
		warn(
			("[DungeonGenerator] Found something named %q in %s but it is a %s (need BasePart or Attachment)"):format(
				anchorName,
				instance.Name,
				wrongClass.ClassName
			)
		)
	else
		local childList = {}
		for _, child in instance:GetChildren() do
			table.insert(
				childList,
				("%q (%s, Archivable=%s)"):format(child.Name, child.ClassName, tostring(child.Archivable))
			)
		end
		warn(
			("[DungeonGenerator] %s has no child named %q. Direct children: [%s]"):format(
				instance.Name,
				anchorName,
				table.concat(childList, ", ")
			)
		)
	end
	return nil
end

function DungeonGenerator._snapPrefab(
	self: typeof(DungeonGenerator),
	prefab: Model,
	anchorOnNew: string,
	targetAnchorCFrame: CFrame,
	parentFolder: Instance
): Model
	-- ORDER: pivot BEFORE parenting into the workspace tree.
	--
	-- Parenting into workspace fires CollectionService tag signals
	-- for every tagged descendant, which causes Component-package
	-- components (Trap, Breakable, etc.) to queue their Construct
	-- + Start via task.defer. If any caller of _snapPrefab yields
	-- between this function returning and the next chunk being
	-- placed, those deferred Starts run at the prefab's TEMPLATE
	-- CFrame, not the dungeon-grid position — so e.g. Trap captures
	-- its zone bounds in the void where the prefab was originally
	-- stored, and never fires when a player or mob actually
	-- walks on the trap in its real dungeon location.
	--
	-- Pivoting an unparented Model is well-defined (CFrames are
	-- absolute), so we lock in the final transform first and only
	-- then enter the workspace tree, ensuring every tag-driven
	-- component sees the correct geometry.
	local clone = prefab:Clone()

	local newAnchor = self:_findAnchor(clone, anchorOnNew)
	assert(
		newAnchor,
		("[DungeonGenerator] Prefab %s missing BasePart/Attachment named %s (searched recursively)"):format(
			prefab.Name,
			anchorOnNew
		)
	)

	local newAnchorCFrame = self:_anchorCFrame(newAnchor) :: CFrame
	local targetCFrame = targetAnchorCFrame * CFrame.Angles(0, math.pi, 0)
	local anchorLocal = clone:GetPivot():Inverse() * newAnchorCFrame
	clone:PivotTo(targetCFrame * anchorLocal:Inverse())

	-- Randomize WHICH of the chunk's pre-placed traps actually spawn.
	-- Done BEFORE parenting so destroyed traps never enter the
	-- workspace tree, never tag-trigger the Trap Component, and never
	-- flash a one-tick existence before disappearing. No-op for
	-- prefabs that don't ship a Traps folder.
	self:_randomizeChunkTraps(clone)
	self:_randomizeChunkBuildings(clone)
	self:_atomizeComponentModels(clone)

	clone.Parent = parentFolder

	return clone
end

-- Stamps every Trap / Chest model in the chunk Atomic so each replicates
-- in one go: their client components read parts (the spikes, the chest's
-- PrimaryPart) that could otherwise stream in after the tagged Model
-- does. The same treatment the drop services give their models. Called
-- BEFORE parenting, like the trap randomisation.
function DungeonGenerator._atomizeComponentModels(_self: typeof(DungeonGenerator), chunk: Model)
	for _, descendant in chunk:GetDescendants() do
		if
			descendant:IsA("Model")
			and (CollectionService:HasTag(descendant, TRAP_TAG) or CollectionService:HasTag(descendant, TagList.Chest))
		then
			descendant.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
		end
	end
end

-- Randomly destroys children of the chunk's "Traps" folder so each
-- run's trap layout is a random subset of the designer-authored
-- positions. Positions stay deterministic (the chunk template owns
-- the placement); only the spawn/no-spawn coin flip is random.
--
-- Why per-child (not per-folder) randomization: gives the designer
-- the option to author a wider variety of trap layouts in one chunk
-- template — e.g. eight spike pads across a Combat room — and have
-- each run feel different without authoring eight separate chunk
-- variants.
function DungeonGenerator._randomizeChunkTraps(_self: typeof(DungeonGenerator), chunk: Model)
	local trapsFolder = chunk:FindFirstChild(TRAPS_FOLDER_NAME)
	if not trapsFolder then
		return
	end

	for _, trap in trapsFolder:GetChildren() do
		if math.random() > TRAP_SPAWN_CHANCE then
			trap:Destroy()
		end
	end
end

-- The traps' coin flip, for the chunk's "Buildings" folder: each authored
-- building (pillar) spawns with BUILDING_SPAWN_CHANCE, so a room's pillar
-- layout is a random subset of the designer's positions. Runs before the
-- chunk parents, and before _relocateChunkBuildings moves the survivors
-- out to Map.Buildings.
function DungeonGenerator._randomizeChunkBuildings(_self: typeof(DungeonGenerator), chunk: Model)
	local buildingsFolder = chunk:FindFirstChild(BUILDINGS_FOLDER_NAME)
	if not buildingsFolder then
		return
	end

	for _, building in buildingsFolder:GetChildren() do
		if math.random() > BUILDING_SPAWN_CHANCE then
			building:Destroy()
		end
	end
end

function DungeonGenerator._ensureRuntimeFolder(_self: typeof(DungeonGenerator)): Folder
	local map = workspace.IgnoreInstances:FindFirstChild("Map")
	assert(map, "[DungeonGenerator] workspace.IgnoreInstances.Map is missing")
	local folder = map:FindFirstChild(RUNTIME_FOLDER_NAME)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = RUNTIME_FOLDER_NAME
		folder.Parent = map
	end
	return folder
end

function DungeonGenerator._makeRoom(_self: typeof(DungeonGenerator), node: Planner.RoomNode, model: Model): Room
	model:SetAttribute(ROOM_ATTRIBUTE, node.id)
	return {
		id = node.id,
		roomType = node.roomType,
		segmentId = node.segmentId,
		chunkIndex = node.chunkIndex,
		chunkCount = node.chunkCount,
		isFirstChunk = node.chunkIndex == 1,
		isLastChunk = node.chunkIndex == node.chunkCount,
		model = model,
		branch = nil,
	}
end

-- Moves every building Model in the chunk's "Buildings" folder into
-- workspace.IgnoreInstances.Map.Buildings and gives it the static-building
-- setup (CollisionGroupService:SetupBuilding: tags, collision group, Base
-- to Terrain). Arcane with canBreakBuildings then breaks them through
-- VFXService's Destructable path, and BuildingTransparencyController fades
-- their roofs, with no code that knows they came from a chunk.
--
-- Recorded on `room.buildings` so FogOfWarService hides / reveals them with
-- the room they left, and on _floorBuildings so teardown destroys them.
function DungeonGenerator._relocateChunkBuildings(self: typeof(DungeonGenerator), room: Room, chunkModel: Model)
	local folder = chunkModel:FindFirstChild(BUILDINGS_FOLDER_NAME)
	if not folder then
		return
	end

	local map = workspace.IgnoreInstances:FindFirstChild("Map")
	if not map then
		return
	end
	local destination = map:FindFirstChild(BUILDINGS_FOLDER_NAME)
	if not destination then
		destination = Instance.new("Folder")
		destination.Name = BUILDINGS_FOLDER_NAME
		destination.Parent = map
	end

	local buildings = room.buildings or {}
	room.buildings = buildings
	for _, building in folder:GetChildren() do
		if not building:IsA("Model") then
			continue
		end
		building.Parent = destination
		if CollisionGroupService then
			CollisionGroupService:SetupBuilding(building)
		end
		table.insert(buildings, building)
		table.insert(self._floorBuildings, building)
	end

	folder:Destroy()
end

--[ Public Functions ]--

-- Anchor lookups, for the landing (the Start room's StartCFrame marker).
function DungeonGenerator.FindAnchor(
	self: typeof(DungeonGenerator),
	instance: Instance,
	anchorName: string,
	optional: boolean?
): Instance?
	return self:_findAnchor(instance, anchorName, optional)
end

function DungeonGenerator.AnchorCFrame(self: typeof(DungeonGenerator), anchor: Instance): CFrame?
	return self:_anchorCFrame(anchor)
end

-- Places one floor: the Start prefab at the origin, then every planned room
-- snapped on in sequence (with backtracking), branches, gates, buildings.
-- Returns the Dungeon record; nothing here touches the active dungeon, the
-- run or any player. May yield (see GENERATION_YIELD_EVERY_PLACEMENTS).
function DungeonGenerator.Generate(self: typeof(DungeonGenerator), descriptor: GenerateDescriptor): Dungeon
	local dungeonId = descriptor.dungeonId
	local difficulty = descriptor.difficulty
	local seed = descriptor.seed
	local originCFrame = descriptor.originCFrame

	local resolvedSeed: number = seed or (os.time() + math.random(1, 1_000_000))
	local resolvedOrigin: CFrame = originCFrame or CFrame.new(0, 0, 0)

	local dungeonConfig = DungeonData[dungeonId]
	assert(dungeonConfig, "[DungeonGenerator] Unknown dungeon: " .. tostring(dungeonId))

	self._generatingDungeonId = dungeonId

	local plan = Planner.Plan(dungeonId, difficulty, resolvedSeed, descriptor.forceShopAfterMiniboss)
	local rng = Random.new(resolvedSeed)
	local runtimeFolder = self:_ensureRuntimeFolder()

	-- Place start room
	local prefabRoot = self:_getPrefabRoot()
	assert(prefabRoot, "[DungeonGenerator] Missing ServerStorage.GameAssets." .. PREFAB_FOLDER_NAME)
	local startPrefab = prefabRoot:FindFirstChild(dungeonConfig.startPrefabName) :: Model?
	assert(startPrefab, "[DungeonGenerator] Missing start prefab: " .. dungeonConfig.startPrefabName)

	local startModel = startPrefab:Clone()
	startModel:PivotTo(resolvedOrigin)
	startModel.Name = "Start"
	self:_atomizeComponentModels(startModel)
	startModel.Parent = runtimeFolder

	for _, wall in startModel:GetChildren() do
		if wall:IsA("BasePart") and wall.Name == "Wall" then
			wall.Parent = WALLS_PARENT_FOLDER
		end
	end

	local roomsList: { Room } = {}
	local roomsById: { [number]: Room } = {}
	local startExitAnchor = self:_findAnchor(startModel, EXIT_ANCHOR_NAME)
	assert(startExitAnchor, "[DungeonGenerator] Start prefab missing BasePart/Attachment named " .. EXIT_ANCHOR_NAME)

	-- Track every placed room's Floor parts so we can reject placements whose
	-- own Floor would overlap any of them.
	local placedFloors: { BasePart } = {}
	for _, floor in self:_getRoomFloors(startModel) do
		table.insert(placedFloors, floor)
	end

	-- Per-slot state for backtracking. `tried` is preserved across backtracks
	-- so we never re-pick a prefab that already failed at this slot in the
	-- current context (cleared only when the *parent* slot picks a new variant,
	-- which changes the geometry).
	type SlotState = {
		tried: { [Model]: true },
		model: Model?,
		prefabName: string?, -- name of the prefab `model` was cloned from
		floors: { BasePart },
		branchModel: Model?,
		branchFloors: { BasePart },
	}
	local slots: { SlotState } = {}
	for i = 1, #plan.rooms do
		slots[i] = { tried = {}, model = nil, floors = {}, branchModel = nil, branchFloors = {} }
	end

	local function removeFloors(floors: { BasePart })
		for _, f in floors do
			local idx = table.find(placedFloors, f)
			if idx then
				table.remove(placedFloors, idx)
			end
		end
	end

	local function popSlot(slot: SlotState)
		if slot.branchModel then
			removeFloors(slot.branchFloors)
			slot.branchModel:Destroy()
			slot.branchModel = nil
			slot.branchFloors = {}
		end
		if slot.model then
			removeFloors(slot.floors)
			slot.model:Destroy()
			slot.model = nil
			slot.prefabName = nil
			slot.floors = {}
		end
	end

	local backtracks = 0
	local collisionsForced = 0
	local slotIdx = 1
	-- See GENERATION_YIELD_EVERY_PLACEMENTS: called once per candidate
	-- snapped into the world.
	local placements = 0
	local function countPlacement()
		placements += 1
		if placements % GENERATION_YIELD_EVERY_PLACEMENTS == 0 then
			task.wait()
		end
	end
	-- The Planner's forced MerchantShop slot could not fit the prefab: the
	-- force rolls forward to the next Event slot (see below) instead of
	-- silently leaving the floor without a shop.
	local shopCarryOver = false

	while slotIdx <= #plan.rooms do
		local slot = slots[slotIdx]
		local node = plan.rooms[slotIdx]

		-- Planner exclusion (floor 1's non-shop Event slots): pre-mark the
		-- blocked prefab as already-tried so the picker below can never
		-- roll it. Re-marked on every visit, so backtracking that resets
		-- the tried set cannot resurrect it.
		if node.blockedPrefabName then
			local blocked = self:_findPrefabByName(node.prefabPool, node.blockedPrefabName)
			if blocked then
				slot.tried[blocked] = true
			end
		end

		-- AT MOST ONE MerchantShop per floor, whichever Event slot it lands
		-- in. The Planner forces one slot to the shop; the OTHER slot rolls
		-- the pool and could roll a second shop by luck (its EventWeights
		-- share), which read as "two merchants most floors". So: if an
		-- earlier slot already holds the shop, this slot's shop force is
		-- dropped (it rolls the pool like any event) and the shop is
		-- excluded from that roll. Read per visit off the placed slots, so
		-- a backtrack that removes the earlier shop restores the guarantee
		-- here, and the Planner's node is never mutated.
		local forcedPrefabName = node.forcedPrefabName
		if node.roomType == RoomTypes.Event then
			-- An earlier forced slot failed to seat the shop: this slot takes
			-- the force, unless the Planner blocked the shop here (floor 1's
			-- pre-Miniboss event).
			if shopCarryOver and node.blockedPrefabName ~= MERCHANT_SHOP_PREFAB_NAME then
				forcedPrefabName = MERCHANT_SHOP_PREFAB_NAME
			end
			local merchantPlacedBefore = false
			for i = 1, slotIdx - 1 do
				if slots[i].prefabName == MERCHANT_SHOP_PREFAB_NAME then
					merchantPlacedBefore = true
					break
				end
			end
			if merchantPlacedBefore then
				if forcedPrefabName == MERCHANT_SHOP_PREFAB_NAME then
					forcedPrefabName = nil
				end
				local merchant = self:_findPrefabByName(node.prefabPool, MERCHANT_SHOP_PREFAB_NAME)
				if merchant then
					slot.tried[merchant] = true
				end
			end
		end

		-- Where does this slot snap from?
		local prevExitAnchor: Instance?
		if slotIdx == 1 then
			prevExitAnchor = startExitAnchor
		else
			prevExitAnchor = self:_findAnchor(slots[slotIdx - 1].model :: Model, EXIT_ANCHOR_NAME, true)
		end
		if not prevExitAnchor then
			warn(
				("[DungeonGenerator] Slot %d (%s) cannot place: previous room has no ExitAnchor"):format(
					slotIdx,
					node.roomType
				)
			)
			break
		end

		local exitAnchorCFrame = self:_anchorCFrame(prevExitAnchor) :: CFrame

		-- Try every untried variant until one fits. A node carrying a
		-- forcedPrefabName (the Planner's shop guarantee) tries THAT model
		-- first; if it cannot fit — collision on every approach — the slot
		-- falls back to the general pool rather than failing the floor, and
		-- the guarantee degrades gracefully instead of wedging generation.
		local placed = false
		while true do
			local prefab: Model?
			if forcedPrefabName then
				local forced = self:_findPrefabByName(node.prefabPool, forcedPrefabName)
				if forced and not slot.tried[forced] then
					prefab = forced
				elseif not forced then
					warn(
						(
							"[DungeonGenerator] Forced prefab '%s' not found in pool '%s' "
							.. "— rolling the pool instead"
						):format(forcedPrefabName, node.prefabPool)
					)
					forcedPrefabName = nil
				end
			end
			prefab = prefab or self:_pickPrefabExcluding(node.prefabPool, slot.tried, rng)
			if not prefab then
				break
			end
			slot.tried[prefab] = true

			local candidate = self:_snapPrefab(prefab, ENTRY_ANCHOR_NAME, exitAnchorCFrame, runtimeFolder)
			local candidateFloors = self:_getRoomFloors(candidate)
			countPlacement()

			if not self:_floorsOverlapAny(candidateFloors, placedFloors) then
				slot.model = candidate
				slot.prefabName = prefab.Name
				slot.floors = candidateFloors
				for _, f in candidateFloors do
					table.insert(placedFloors, f)
				end
				placed = true
				break
			end

			candidate:Destroy()
		end

		if placed then
			if slot.prefabName == MERCHANT_SHOP_PREFAB_NAME then
				shopCarryOver = false
			elseif forcedPrefabName == MERCHANT_SHOP_PREFAB_NAME then
				-- The shop was forced here and could not fit: carry the
				-- guarantee to the next Event slot.
				shopCarryOver = true
			end

			-- Optional branch off this room. Best-effort: if it can't fit, skip
			-- silently — branches don't affect downstream chain placement.
			--
			-- A prefab may have multiple BranchAnchors (one per wall, for example).
			-- We shuffle them so the same anchor isn't always tried first, then
			-- try each Treasure variant at each anchor until something fits.
			if node.branch then
				local branchAnchors = self:_findAllAnchors(slot.model :: Model, BRANCH_ANCHOR_NAME)
				-- Shuffle for variety across runs
				for i = #branchAnchors, 2, -1 do
					local j = rng:NextInteger(1, i)
					branchAnchors[i], branchAnchors[j] = branchAnchors[j], branchAnchors[i]
				end

				for _, branchHostAnchor in branchAnchors do
					local branchTried: { [Model]: true } = {}
					local branchPlaced = false
					while true do
						local bp = self:_pickPrefabExcluding(node.branch.prefabPool, branchTried, rng)
						if not bp then
							break
						end
						branchTried[bp] = true

						local bc = self:_snapPrefab(
							bp,
							ENTRY_ANCHOR_NAME,
							self:_anchorCFrame(branchHostAnchor) :: CFrame,
							runtimeFolder
						)
						local bcFloors = self:_getRoomFloors(bc)
						countPlacement()

						if not self:_floorsOverlapAny(bcFloors, placedFloors) then
							slot.branchModel = bc
							slot.branchFloors = bcFloors
							for _, f in bcFloors do
								table.insert(placedFloors, f)
							end
							branchPlaced = true
							break
						end

						bc:Destroy()
					end

					if branchPlaced then
						break
					end
				end
			end

			slotIdx += 1
		elseif backtracks >= MAX_BACKTRACKS then
			-- Safety net: stop backtracking, force-place this slot and continue.
			collisionsForced += 1
			-- Honour the slot's exclusions (floor-1 shop block, the one-shop
			-- rule) here too; the bare uniform pick is only the last resort.
			local fp = self:_pickPrefabExcluding(node.prefabPool, slot.tried, rng)
			if not fp then
				-- Last resort: any prefab -- but never a SECOND shop. The
				-- bare uniform pick below ignored the one-shop rule, and a
				-- floor that backtracked this far could seat two merchants.
				local shopOnly: { [Model]: true } = {}
				local merchant = self:_findPrefabByName(node.prefabPool, MERCHANT_SHOP_PREFAB_NAME)
				if merchant and slot.tried[merchant] then
					shopOnly[merchant] = true
				end
				fp = self:_pickPrefabExcluding(node.prefabPool, shopOnly, rng) or self:_pickPrefab(node.prefabPool, rng)
			end
			local forcedPrefab = fp :: Model
			local forcedModel = self:_snapPrefab(forcedPrefab, ENTRY_ANCHOR_NAME, exitAnchorCFrame, runtimeFolder)
			countPlacement()
			slot.model = forcedModel
			slot.prefabName = forcedPrefab.Name
			slot.floors = self:_getRoomFloors(forcedModel)
			for _, f in slot.floors do
				table.insert(placedFloors, f)
			end
			warn(
				("[DungeonGenerator] Max backtracks (%d) hit at slot %d (%s); force-placed."):format(
					MAX_BACKTRACKS,
					slotIdx,
					node.roomType
				)
			)
			slotIdx += 1
		elseif slotIdx == 1 then
			warn(
				("[DungeonGenerator] Cannot place first room (%s) — no Combat/Shrine variant fits start room's exit"):format(
					node.roomType
				)
			)
			break
		else
			-- Backtrack: clear THIS slot's tried list (parent will pick a new
			-- variant, changing the geometric context), pop parent, retry parent.
			backtracks += 1
			slot.tried = {}
			slotIdx -= 1
			popSlot(slots[slotIdx])
		end
	end

	-- Build the final room objects from the placed slots.
	for i, node in ipairs(plan.rooms) do
		local slot = slots[i]
		if not slot.model then
			break -- generation was aborted before reaching this slot
		end

		-- The rename erases WHICH prefab this room came from, but Event
		-- rooms are identified by prefab (SwordStone vs MerchantShop vs
		-- CursedShrine) — EventService wires interactables off this.
		local placedModel = slot.model :: Model
		placedModel:SetAttribute("PrefabName", placedModel.Name)
		placedModel.Name = ("Room_%d_%s"):format(node.id, node.roomType)
		local room = self:_makeRoom(node, slot.model :: Model)

		if slot.branchModel and node.branch then
			local placedBranchModel = slot.branchModel :: Model
			placedBranchModel:SetAttribute("PrefabName", placedBranchModel.Name)
			placedBranchModel.Name = ("Branch_%d_%s"):format(node.id, node.branch.roomType)
			local branchRoom = self:_makeRoom(node.branch, slot.branchModel :: Model)
			room.branch = branchRoom
			roomsById[node.branch.id] = branchRoom

			for _, wall in slot.branchModel:GetChildren() do
				if wall:IsA("BasePart") and wall.Name == "Wall" then
					wall.Parent = WALLS_PARENT_FOLDER
				end
			end

			local branchEntryAnchor = placedBranchModel:FindFirstChild(ENTRY_ANCHOR_NAME)
			if branchEntryAnchor then
				branchEntryAnchor:Destroy()
			end

			-- The host room had a BranchWall blocking the doorway to the branch.
			-- Now that a branch was actually placed, remove it so players can
			-- walk through. (If no branch was placed, the wall stays and the
			-- doorway remains sealed.)
			local branchWall = slot.model:FindFirstChild(BRANCH_WALL_NAME)
			if branchWall then
				branchWall:Destroy()
			end
		end

		for _, wall in slot.model:GetChildren() do
			if wall:IsA("BasePart") and wall.Name == "Wall" then
				wall.Parent = WALLS_PARENT_FOLDER
			end
		end

		self:_relocateChunkBuildings(room, slot.model)

		for _, anchorName in { ENTRY_ANCHOR_NAME, EXIT_ANCHOR_NAME, BRANCH_ANCHOR_NAME } do
			local anchor = placedModel:FindFirstChild(anchorName)
			if anchor then
				anchor:Destroy()
			end
		end

		-- Inner chunks' ExitGates serve as touch-triggers: when a player touches
		-- one, the gate is destroyed, mobs spawn in the next chunk, and every
		-- player's cursor advances. Last-chunk ExitGates are left alone for the
		-- external encounter system to lock/unlock manually.
		if not room.isLastChunk then
			GateService:SetupGateTrigger(room.model, room.id + 1)
		else
			-- The room's REAL gate. Tagged so every client dresses it with the
			-- chained ExitGateParticlePart rig (DungeonGateController); the
			-- touch-trigger doorways above are barricade doorways and stay bare.
			local lockedGate = room.model:FindFirstChild(EXIT_GATE_NAME)
			if lockedGate and lockedGate:IsA("BasePart") then
				CollectionService:AddTag(lockedGate, TagList.LockedExitGate)
			end
		end

		table.insert(roomsList, room)
		roomsById[node.id] = room
	end

	local startExitAnchorInstance = startModel:FindFirstChild(EXIT_ANCHOR_NAME)
	if startExitAnchorInstance then
		startExitAnchorInstance:Destroy()
	end

	-- Start room's ExitGate is also a touch trigger: walking out of Start
	-- spawns the first room's mobs and advances every player to room 1.
	GateService:SetupGateTrigger(startModel, 1)

	-- Which events this floor seated, in sequence order: the fastest way to
	-- see whether the one-shop rule held on a given seed.
	local eventNames = {}
	for _, placedRoom in roomsList do
		if placedRoom.roomType == RoomTypes.Event and placedRoom.model then
			table.insert(eventNames, tostring(placedRoom.model:GetAttribute("PrefabName") or placedRoom.model.Name))
		end
	end
	Log.debug(("[DungeonGenerator] Events this floor: %s"):format(table.concat(eventNames, ", ")))
	if not table.find(eventNames, MERCHANT_SHOP_PREFAB_NAME) then
		warn(
			"[DungeonGenerator] No MerchantShop this floor: the forced Event slot could not fit the prefab "
				.. "and no later Event slot could take it (seed "
				.. tostring(resolvedSeed)
				.. ")"
		)
	end

	Log.debug(
		("[DungeonGenerator] Generated %s/%s with %d rooms (seed %d, %d backtracks, %d forced)"):format(
			dungeonId,
			difficulty,
			#roomsList,
			resolvedSeed,
			backtracks,
			collisionsForced
		)
	)

	-- Stamp each COMBAT room's dungeon-wide SEGMENT ordinal (1..N in path
	-- order). Treasure/Shrine branches and Miniboss/Boss rooms don't consume
	-- an ordinal, so the ramp runs continuously across the miniboss.
	--
	-- Counts SEGMENTS, not chunks: chunksPerRoom explodes one Combat entry in
	-- the difficulty sequence into 2-3 physical rooms, and every chunk of a
	-- segment shares its segmentId — so they all get the same ordinal and
	-- therefore the same mob queue. A 3-chunk segment is three fights of
	-- equal size, not a ramp within itself. MobSpawnService's queue
	-- formula scales off this, so deeper SEGMENTS field bigger queues.
	--
	-- Relies on a segment's chunks being contiguous in roomsList, which the
	-- Planner guarantees (it emits chunkCount rooms per sequence entry before
	-- moving on). Non-Combat rooms between chunks are skipped without
	-- disturbing the run, since lastSegmentId only updates inside the branch.
	local combatSegmentOrdinal = 0
	local lastCombatSegmentId: number? = nil
	for _, room in roomsList do
		if room.roomType == RoomTypes.Combat then
			if room.segmentId ~= lastCombatSegmentId then
				combatSegmentOrdinal += 1
				lastCombatSegmentId = room.segmentId
			end
			room.combatSegmentIndex = combatSegmentOrdinal
		end
	end

	local dungeon: Dungeon = {
		id = dungeonId,
		difficulty = difficulty,
		seed = resolvedSeed,
		plan = plan,
		startModel = startModel,
		rooms = roomsList,
		roomsById = roomsById,
	}

	self._generatingDungeonId = nil

	return dungeon
end

-- Un-places the floor: every room model in the runtime folder (Walls has its
-- children cleared, Highlight is left alone -- see RUNTIME_FOLDER_KEEP) and
-- the chunk buildings relocated to Map.Buildings.
function DungeonGenerator.DestroyFloor(self: typeof(DungeonGenerator))
	local map = workspace.IgnoreInstances:FindFirstChild("Map")
	local runtimeFolder = map and map:FindFirstChild(RUNTIME_FOLDER_NAME)
	if runtimeFolder then
		for _, child in runtimeFolder:GetChildren() do
			local keep = RUNTIME_FOLDER_KEEP[child.Name]
			if child == WALLS_PARENT_FOLDER or keep == "clearChildren" then
				for _, wall in child:GetChildren() do
					wall:Destroy()
				end
			elseif keep == "keep" then
				continue
			else
				child:Destroy()
			end
		end
	end

	-- Chunk buildings live in Map.Buildings, outside the runtime folder.
	for _, building in self._floorBuildings do
		if building.Parent then
			building:Destroy()
		end
	end
	table.clear(self._floorBuildings)
end

return DungeonGenerator
