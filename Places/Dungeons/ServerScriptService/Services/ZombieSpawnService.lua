local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local LootPlan = require(ReplicatedStorage.Submodules.Core.Libraries.LootPlan)
local ZombieData = require(ReplicatedStorage.Submodules.Core.Shared.Data.ZombieData)
local DungeonData = require(ReplicatedStorage.Submodules.Core.Shared.Data.DungeonData)
local Signal = require(ReplicatedStorage.Submodules.Core.Packages.Signal)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local RoomTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RoomTypes)

local SPAWN_DELAY = 0.5

-- Combat-room queue tuning. Each combat CHUNK, at ACTIVATION time (first
-- player crossing in), snapshots the player count and builds:
--   * a total QUEUE of zombies it will spawn over its lifetime:
--         QUEUE_SEGMENT_ONE + ((combatSegmentIndex - 1) × QUEUE_PER_SEGMENT)
--                           + (players × QUEUE_PER_PLAYER)
--     where combatSegmentIndex is the room's dungeon-wide COMBAT SEGMENT
--     ordinal, stamped at generation by DungeonService. Miniboss/Boss and
--     Treasure/Shrine segments do NOT consume an ordinal, so the ramp
--     stays continuous across the miniboss.
--
--     The ordinal counts SEGMENTS, not chunks. DungeonData's
--     chunksPerRoom explodes each Combat segment into 2-3 physical rooms,
--     and every chunk of one segment fields the SAME queue — a 3-chunk
--     segment 1 is three separate 8-zombie fights, not 8 then 9 then 10.
--     Solo, that ladders 8/9/10/.../15 across Normal's eight combat
--     segments.
--   * a CONCURRENT cap of how many can be alive in the chunk at once:
--         CONCURRENT_BASE + (players × CONCURRENT_PER_PLAYER)
--     clamped at CONCURRENT_MAX (4 base, +2/player → 6 solo, 12 at 4
--     players) — the anti-swarm clamp.
-- Both are FROZEN at activation: a player dying or leaving mid-room
-- never shrinks the room's budget. A per-room thread tops the room back
-- up to the concurrent cap from the queue as zombies die, until the
-- queue is dry. The segment's exit gate only opens when every combat
-- room's queue is exhausted AND every spawned zombie is dead
-- (DungeonService:_areSegmentZombiesCleared).
-- DEFAULTS. Every dungeon overrides these through DungeonData[id].zombieQueue
-- (segmentOne / perSegment / perPlayer, optional concurrent*), read at chunk
-- activation via _queueTuning -- so deeper dungeons of a run field bigger
-- queues through their data, not a carried ordinal. Rooms with no active
-- dungeon (hand-placed test rooms) fall back to these.
local QUEUE_SEGMENT_ONE = 5 -- first combat segment, BEFORE the player term
local QUEUE_PER_SEGMENT = 4
local QUEUE_PER_PLAYER = 2
local CONCURRENT_BASE = 4
local CONCURRENT_PER_PLAYER = 2
local CONCURRENT_MAX = 12
local QUEUE_POLL_SECONDS = 0.5
local QUEUE_START_DELAY = 1 -- matches the old pre-spawn beat after gate crossing

-- ANTI-KITE spawn placement (see _PickSpawnPoints).
--
-- A chunk's queue used to spawn ONLY at that chunk's SpawnPoints. Players
-- learned to open chunk 3, then fall back and kite through the already-
-- cleared chunks 1-2, where nothing ever spawns -- the more chunks in a
-- segment, the more free room to kite. Now, once a chunk's FIRST WAVE is
-- down (the initial fill up to its concurrent cap, always entirely in the
-- chunk itself), every top-up spawn is placed round-robin: the owning chunk
-- FIRST, then one in each PREVIOUS chunk of the same segment that players
-- are physically standing in. Kite back into chunk 1 and chunk 3's queue
-- starts landing zombies in chunk 1 too; kite into 1 and 2 and all three
-- get spawns. The owning chunk keeps its slot even when nobody is in it, so
-- falling back never fully quiets the room you're meant to clear.
--
-- NOTHING about the queue changes: budget, concurrent cap, roster and
-- segment-clear all still belong to the owning chunk -- a zombie chunk 3's
-- queue drops into chunk 1 is still chunk 3's zombie. Only WHERE it appears
-- moves. Presence is a real physical check (HRP over one of the chunk's
-- Floor parts) -- DungeonService's room cursor is party-wide, not per player.
local FLOOR_NAME = "Floor"
local PRESENCE_MAX_HEIGHT_ABOVE_FLOOR = 25
local PRESENCE_MAX_DEPTH_BELOW_FLOOR = 3

local SPAWN_POINTS_FOLDER_NAME = "SpawnPoints"
local ROOM_SPAWN_HEIGHT_OFFSET = 2
local ROOM_ATTRIBUTE = "RoomId"
local MAX_ACTIVE_ZOMBIES = 75
local MAX_MINIBOSS_WAVE_ZOMBIES = 8

local MINIBOSS_SPAWN_POINT_NAME = "MinibossSpawnPoint"
local MINIBOSS_WAVE_INTERVAL = 45

local DungeonService

local ZombieSpawnService = Knit.CreateService({
	Name = "ZombieSpawnService",
	_zombiePlan = LootPlan.new("single"), -- rebuilt per dungeon (BuildZombiePlanForDungeon)
	_zombiePlanDungeonId = nil :: string?,
	_zombiesRegistry = {},
	_zombiesByRoom = {}, -- [roomId]: { Model, ... } — populated by the room queue
	_roomQueues = {}, -- [roomId]: { remaining: number, concurrentCap: number } — see SpawnZombiesInRoom
	_activeMinibossWaves = {}, -- [roomId]: thread — running wave spawner per miniboss room
	_minibossWavesPaused = {}, -- [roomId]: true — wave spawner frozen (boss phase cutscene)

	Client = {
		ZombieRegistry = Knit.CreateProperty({}),
	},
})

ZombieSpawnService.OnZombieSpawn = Signal.new()
ZombieSpawnService.OnZombieDespawn = Signal.new()

function ZombieSpawnService:GetZombieRegistry(): { Model }
	return self._zombiesRegistry
end

function ZombieSpawnService:IncrementZombieCount(zombie: Model)
	self.OnZombieSpawn:Fire(zombie)

	table.insert(self._zombiesRegistry, zombie)

	self.Client.ZombieRegistry:Set(self._zombiesRegistry)
end

function ZombieSpawnService:DecrementZombieCount(zombie: Model)
	-- Update all registries BEFORE firing the signal so every listener observes
	-- a fully-consistent post-death state (e.g. DungeonService's segment-clear
	-- check would otherwise see the dying zombie still in _zombiesByRoom and
	-- never trigger the gate-open).
	local roomId = zombie:GetAttribute(ROOM_ATTRIBUTE)
	if roomId then
		local roomList = self._zombiesByRoom[roomId]
		if roomList then
			local roomIdx = table.find(roomList, zombie)
			if roomIdx then
				table.remove(roomList, roomIdx)
			end
		end
	end

	local index = table.find(self._zombiesRegistry, zombie)
	if index then
		table.remove(self._zombiesRegistry, index)
	end

	self.Client.ZombieRegistry:Set(self._zombiesRegistry)

	self.OnZombieDespawn:Fire(zombie)
end

--[ Per-dungeon zombie pool ]--

-- ReplicatedStorage.GameAssets.Zombies.<dungeonId> -- each dungeon has its
-- own folder of mob templates. Falls back to the flat Zombies folder (with
-- a warn) so a missing folder degrades to "same mobs everywhere" instead
-- of a dead dungeon.
function ZombieSpawnService:_zombieFolder(dungeonId: string?): Instance
	local root = ReplicatedStorage.GameAssets.Zombies
	if dungeonId then
		local folder = root:FindFirstChild(dungeonId)
		if folder then
			return folder
		end
		warn(("[ZombieSpawnService] No zombie folder GameAssets.Zombies.%s -- using the flat folder"):format(dungeonId))
	end
	return root
end

function ZombieSpawnService:_activeDungeonId(): string?
	local dungeon = DungeonService and DungeonService:GetActiveDungeon()
	return dungeon and dungeon.id or nil
end

-- Template for `zombieName` in the ACTIVE dungeon's pool (nil + warn if
-- absent -- a name that isn't in this dungeon's folder is a data error, not
-- a reason to spawn a mob from another dungeon).
function ZombieSpawnService:_zombieTemplate(zombieName: string): Model?
	local folder = self:_zombieFolder(self:_activeDungeonId())
	local template = folder:FindFirstChild(zombieName)
	if not template then
		warn(("[ZombieSpawnService] No zombie template '%s' under %s"):format(zombieName, folder:GetFullName()))
		return nil
	end
	return template
end

-- Queue tuning for the active dungeon (DungeonData[id].zombieQueue), with
-- the module defaults filling any gap.
function ZombieSpawnService:_queueTuning()
	local dungeonId = self:_activeDungeonId()
	local config = dungeonId and DungeonData[dungeonId]
	local tuning = config and config.zombieQueue or {}
	return {
		segmentOne = tuning.segmentOne or QUEUE_SEGMENT_ONE,
		perSegment = tuning.perSegment or QUEUE_PER_SEGMENT,
		perPlayer = tuning.perPlayer or QUEUE_PER_PLAYER,
		concurrentBase = tuning.concurrentBase or CONCURRENT_BASE,
		concurrentPerPlayer = tuning.concurrentPerPlayer or CONCURRENT_PER_PLAYER,
		concurrentMax = tuning.concurrentMax or CONCURRENT_MAX,
	}
end

-- Rebuilds the random-spawn plan from DungeonData[dungeonId].zombiePool: the
-- explicit list of ZombieNames that spawn in this dungeon, each weighted by
-- ZombieData[name].spawnWeight (0 / no data = skipped + warned). Every name
-- must ALSO have a template in the dungeon's GameAssets.Zombies folder --
-- checked here so a typo warns at generation, not on the first spawn.
-- Called by DungeonService on every generation.
function ZombieSpawnService:BuildZombiePlanForDungeon(dungeonId: string)
	local plan = LootPlan.new("single")
	local added = 0
	local config = DungeonData[dungeonId]
	local pool = config and config.zombiePool or {}
	local folder = self:_zombieFolder(dungeonId)
	for _, zombieName in pool do
		local data = ZombieData[zombieName]
		local weight = data and data.spawnWeight or 0
		if weight <= 0 then
			warn(
				("[ZombieSpawnService] %s.zombiePool: '%s' has no ZombieData spawnWeight > 0 -- skipped"):format(
					dungeonId,
					tostring(zombieName)
				)
			)
			continue
		end
		if not folder:FindFirstChild(zombieName) then
			warn(
				("[ZombieSpawnService] %s.zombiePool: no template '%s' under %s -- skipped"):format(
					dungeonId,
					tostring(zombieName),
					folder:GetFullName()
				)
			)
			continue
		end
		plan:AddLoot(zombieName, weight)
		added += 1
	end
	if added == 0 then
		warn(
			("[ZombieSpawnService] Zombie pool for %s is EMPTY -- nothing will spawn from its combat queues"):format(
				dungeonId
			)
		)
	end
	self._zombiePlan = plan
	self._zombiePlanDungeonId = dungeonId
end

-- Full reset between dungeons of a run: every live zombie is destroyed and
-- every per-room record dropped. REQUIRED before generating the next
-- dungeon -- room ids restart at 1 in every generation, so a stale
-- _roomQueues[1] from dungeon 1 would make dungeon 2's room 1 read as
-- "already activated" and never spawn. Queue threads still running notice
-- their room model is gone and drain themselves.
function ZombieSpawnService:ResetForNewDungeon()
	for _, waveThread in pairs(table.clone(self._activeMinibossWaves)) do
		if typeof(waveThread) == "thread" then
			pcall(task.cancel, waveThread)
		end
	end
	table.clear(self._activeMinibossWaves)
	table.clear(self._minibossWavesPaused)
	for _, queue in pairs(self._roomQueues) do
		queue.remaining = 0
	end
	table.clear(self._roomQueues)
	table.clear(self._zombiesByRoom)

	for _, zombie in workspace.IgnoreInstances.Zombies:GetChildren() do
		zombie:Destroy()
	end
	table.clear(self._zombiesRegistry)
	self.Client.ZombieRegistry:Set(self._zombiesRegistry)
end

-- Collect every Attachment under the room's "SpawnPoints" folder. Each
-- attachment is a deterministic spawn location for one zombie.
function ZombieSpawnService:_GetRoomSpawnPoints(roomModel: Model): { Attachment }
	local folder = roomModel:FindFirstChild(SPAWN_POINTS_FOLDER_NAME)
	if not folder then
		return {}
	end
	local points = {}
	for _, child in folder:GetChildren() do
		if child:IsA("Attachment") then
			table.insert(points, child)
		end
	end
	return points
end

-- Every Floor part under a room model (cached per chunk at activation).
local function getRoomFloors(roomModel: Model): { BasePart }
	local floors = {}
	for _, descendant in roomModel:GetDescendants() do
		if descendant:IsA("BasePart") and descendant.Name == FLOOR_NAME then
			table.insert(floors, descendant)
		end
	end
	return floors
end

-- Is a world position standing over one of these floors (XZ footprint,
-- within the vertical slop)?
local function positionOverFloors(position: Vector3, floors: { BasePart }): boolean
	for _, floor in floors do
		local localPos = floor.CFrame:PointToObjectSpace(position)
		local halfSize = floor.Size * 0.5
		if
			math.abs(localPos.X) <= halfSize.X
			and math.abs(localPos.Z) <= halfSize.Z
			and localPos.Y >= -halfSize.Y - PRESENCE_MAX_DEPTH_BELOW_FLOOR
			and localPos.Y <= halfSize.Y + PRESENCE_MAX_HEIGHT_ABOVE_FLOOR
		then
			return true
		end
	end
	return false
end

-- The PREVIOUS combat chunks of `room`'s segment (lower chunkIndex, same
-- segmentId), each with its spawn points + floors cached, ordered by
-- chunkIndex. Empty for a first chunk, for rooms with no segment stamp
-- (hand-placed test rooms), or when no dungeon is active.
function ZombieSpawnService:_GetPreviousChunks(room): { any }
	local previous = {}
	if room.segmentId == nil or room.chunkIndex == nil then
		return previous
	end
	local dungeon = DungeonService and DungeonService:GetActiveDungeon()
	if not dungeon then
		return previous
	end
	for _, candidate in dungeon.rooms do
		if
			candidate ~= room
			and candidate.model
			and candidate.roomType == RoomTypes.Combat
			and candidate.segmentId == room.segmentId
			and (candidate.chunkIndex or 0) < room.chunkIndex
		then
			local spawnPoints = self:_GetRoomSpawnPoints(candidate.model)
			if #spawnPoints > 0 then
				table.insert(previous, {
					room = candidate,
					spawnPoints = spawnPoints,
					floors = getRoomFloors(candidate.model),
				})
			end
		end
	end
	table.sort(previous, function(a, b)
		return (a.room.chunkIndex or 0) < (b.room.chunkIndex or 0)
	end)
	return previous
end

-- Previous chunks that at least one ALIVE player is physically standing in.
function ZombieSpawnService:_GetOccupiedChunks(previousChunks: { any }): { any }
	local occupied = {}
	if #previousChunks == 0 then
		return occupied
	end
	local seen = {}
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local hrp = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not hrp or not humanoid or humanoid.Health <= 0 then
			continue
		end
		for _, chunk in previousChunks do
			if not seen[chunk] and chunk.room.model and chunk.room.model.Parent then
				if positionOverFloors(hrp.Position, chunk.floors) then
					seen[chunk] = true
					table.insert(occupied, chunk)
				end
			end
		end
	end
	-- Keep segment order (chunk 1 before chunk 2) for a stable round-robin.
	table.sort(occupied, function(a, b)
		return (a.room.chunkIndex or 0) < (b.room.chunkIndex or 0)
	end)
	return occupied
end

-- Spawns one queued zombie at a random SpawnPoints attachment (pure
-- random reuse — attachments host any number of spawns over the room's
-- lifetime). Tagged with the room's id and registered under
-- _zombiesByRoom[room.id] so :GetZombiesInRoom returns them in O(1).
function ZombieSpawnService:_SpawnQueuedZombie(room, spawnPoints: { Attachment })
	local attachment = spawnPoints[math.random(#spawnPoints)]

	local zombieName = self._zombiePlan:GetRandomLoot(1)
	local template = zombieName and self:_zombieTemplate(zombieName)
	if not template then
		return
	end
	local zombie = template:Clone()
	zombie:SetAttribute(ROOM_ATTRIBUTE, room.id)

	local hrp = zombie:FindFirstChild("HumanoidRootPart")
	if hrp then
		hrp.CFrame = CFrame.new(attachment.WorldPosition + Vector3.new(0, ROOM_SPAWN_HEIGHT_OFFSET, 0))
	end

	task.delay(0.5, function()
		local particle = attachment:FindFirstChild("SpawnParticle")
		if particle then
			particle:Emit(35)
		end
	end)

	zombie.Parent = workspace.IgnoreInstances.Zombies

	table.insert(self._zombiesByRoom[room.id], zombie)
end

-- Activates a combat room's zombie QUEUE. Snapshots the player count
-- (frozen — see the constants block), then runs a per-room thread that
-- keeps the room topped up to its concurrent cap from the queue until
-- the queue is dry:
--   queue 10, cap 5 → 5 spawn in → kill 3 → thread tops back up to 5
--   (3 more spawn, queue 2) → ... → queue 0 and all dead = room done.
-- Idempotent: re-activating an already-activated room is a no-op, so a
-- double gate-crossing can't double a room's budget. The thread outlives
-- players leaving the room by design — an abandoned queue keeps spawning
-- and its zombies hunt the party (skipping ahead is punished; the
-- segment gate stays locked either way).
function ZombieSpawnService:SpawnZombiesInRoom(room)
	if not room or not room.model then
		warn("[ZombieSpawnService] SpawnZombiesInRoom called with nil room or no model")
		return
	end

	if self._roomQueues[room.id] then
		return -- already activated
	end

	local spawnPoints = self:_GetRoomSpawnPoints(room.model)
	if #spawnPoints == 0 then
		warn(
			("[ZombieSpawnService] Room %s has no Attachments under '%s' folder"):format(
				room.model.Name,
				SPAWN_POINTS_FOLDER_NAME
			)
		)
		return
	end

	local playerCount = math.max(#Players:GetPlayers(), 1)
	-- Depth-scaled queue, LOCKED per combat segment: every chunk of the same
	-- logical combat room resolves the same ordinal here, so they all field
	-- an identical queue. Fallback 1 for rooms that predate the stamp
	-- (hand-spawned test rooms).
	local combatSegmentIndex = room.combatSegmentIndex or 1
	local tuning = self:_queueTuning()
	local queue = {
		remaining = tuning.segmentOne
			+ ((combatSegmentIndex - 1) * tuning.perSegment)
			+ (playerCount * tuning.perPlayer),
		concurrentCap = math.min(
			tuning.concurrentBase + (playerCount * tuning.concurrentPerPlayer),
			tuning.concurrentMax
		),
	}
	self._roomQueues[room.id] = queue
	self._zombiesByRoom[room.id] = self._zombiesByRoom[room.id] or {}

	-- Anti-kite placement state (see the FLOOR_NAME constants block).
	-- previousChunks is fixed for the room's lifetime; which of them are
	-- OCCUPIED is re-read per spawn.
	local previousChunks = self:_GetPreviousChunks(room)
	local firstWaveDone = false
	local roundRobinIndex = 1

	task.spawn(function()
		task.wait(QUEUE_START_DELAY)

		while queue.remaining > 0 do
			-- Room model destroyed (dungeon regenerated / encounter reset)
			-- → drain the queue so the thread dies and clear-checks that
			-- somehow still reference this room see it exhausted.
			if not room.model or not room.model.Parent then
				queue.remaining = 0
				break
			end

			local alive = #(self._zombiesByRoom[room.id] or {})

			-- Global hard cap: never push the server past MAX_ACTIVE_ZOMBIES
			-- live + still-initializing. Counts the Zombies folder directly so
			-- it stays accurate during the window before IncrementZombieCount.
			if
				alive < queue.concurrentCap
				and #workspace.IgnoreInstances.Zombies:GetChildren() < MAX_ACTIVE_ZOMBIES
			then
				queue.remaining -= 1

				-- FIRST WAVE: the initial fill up to the concurrent cap lands
				-- entirely in THIS chunk. After that, top-ups go round-robin:
				-- this chunk first, then each previous chunk players are
				-- kiting in. The zombie is still THIS room's (queue, cap,
				-- roster) wherever it lands.
				local placementPoints = spawnPoints
				if firstWaveDone then
					local candidates = { spawnPoints }
					for _, chunk in self:_GetOccupiedChunks(previousChunks) do
						table.insert(candidates, chunk.spawnPoints)
					end
					if roundRobinIndex > #candidates then
						roundRobinIndex = 1
					end
					placementPoints = candidates[roundRobinIndex]
					roundRobinIndex += 1
				end

				self:_SpawnQueuedZombie(room, placementPoints)

				-- The wave is 'down' the moment the chunk first reaches its cap
				-- (or the queue runs dry before it can).
				if not firstWaveDone and (alive + 1 >= queue.concurrentCap or queue.remaining <= 0) then
					firstWaveDone = true
				end

				task.wait(SPAWN_DELAY)
			else
				task.wait(QUEUE_POLL_SECONDS)
			end
		end
	end)
end

-- CHALLENGE queue (CoffinEventService): `waves` zombies per SpawnPoint in
-- `room`, poured in under `concurrentCap` from the dungeon's own pool,
-- every spawn at a random attachment. Registers in _roomQueues /
-- _zombiesByRoom exactly like a combat queue, so IsRoomQueueExhausted,
-- GetZombiesInRoom and DespawnZombiesInRoom all work on it. Unlike
-- SpawnZombiesInRoom it is NOT latched — an event room never runs the
-- combat queue, and a re-run just replaces the queue — and it does no
-- anti-kite placement: the room is sealed, everyone is inside. Returns
-- the total it will spawn, or nil when the room has no SpawnPoints.
function ZombieSpawnService:StartChallengeQueue(room, waves: number, concurrentCap: number): number?
	if not room or not room.model then
		warn("[ZombieSpawnService] StartChallengeQueue called with nil room or no model")
		return nil
	end

	local spawnPoints = self:_GetRoomSpawnPoints(room.model)
	if #spawnPoints == 0 then
		warn(
			("[ZombieSpawnService] Room %s has no Attachments under '%s' folder"):format(
				room.model.Name,
				SPAWN_POINTS_FOLDER_NAME
			)
		)
		return nil
	end

	local total = math.max(math.floor(waves), 0) * #spawnPoints
	local queue = {
		remaining = total,
		concurrentCap = math.max(math.floor(concurrentCap), 1),
	}
	self._roomQueues[room.id] = queue
	self._zombiesByRoom[room.id] = self._zombiesByRoom[room.id] or {}

	task.spawn(function()
		while queue.remaining > 0 do
			if not room.model or not room.model.Parent then
				queue.remaining = 0
				break
			end

			local alive = #(self._zombiesByRoom[room.id] or {})
			if
				alive < queue.concurrentCap
				and #workspace.IgnoreInstances.Zombies:GetChildren() < MAX_ACTIVE_ZOMBIES
			then
				queue.remaining -= 1
				self:_SpawnQueuedZombie(room, spawnPoints)
				task.wait(SPAWN_DELAY)
			else
				task.wait(QUEUE_POLL_SECONDS)
			end
		end
	end)

	return total
end

-- True when the room's queue has spawned everything it ever will. A room
-- is fully CLEARED when this is true AND :GetZombiesInRoom is empty —
-- DungeonService:_areSegmentZombiesCleared checks both, so the exit gate
-- can never open while a queue still holds unspawned zombies.
function ZombieSpawnService:IsRoomQueueExhausted(room): boolean
	if not room then
		return false
	end
	local queue = self._roomQueues[room.id]
	return queue ~= nil and queue.remaining <= 0
end

-- Remaining unspawned zombies in the room's queue (0 if exhausted or
-- never activated). Exposed for future UI ("X zombies remaining").
function ZombieSpawnService:GetRoomQueueRemaining(room): number
	if not room then
		return 0
	end
	local queue = self._roomQueues[room.id]
	return queue and queue.remaining or 0
end

-- Returns the list of zombies currently alive in the given room. Updates
-- automatically as zombies die (cleaned up on OnZombieDespawn).
function ZombieSpawnService:GetZombiesInRoom(room): { Model }
	if not room then
		return {}
	end
	return self._zombiesByRoom[room.id] or {}
end

-- Returns true if SpawnZombiesInRoom has activated this room's queue at
-- least once (regardless of how many zombies are currently alive). Used
-- by segment clear-checks to tell "never spawned" apart from "all dead".
function ZombieSpawnService:WasRoomSpawned(room): boolean
	if not room then
		return false
	end
	return self._roomQueues[room.id] ~= nil
end

--[ Miniboss fight ]--

-- Finds the MinibossSpawnPoint attachment in the room's SpawnPoints folder.
function ZombieSpawnService:_GetMinibossSpawnPoint(roomModel: Model): Attachment?
	local folder = roomModel:FindFirstChild(SPAWN_POINTS_FOLDER_NAME)
	if not folder then
		return nil
	end
	local attachment = folder:FindFirstChild(MINIBOSS_SPAWN_POINT_NAME)
	if attachment and attachment:IsA("Attachment") then
		return attachment
	end
	return nil
end

-- Returns every Attachment under SpawnPoints EXCEPT MinibossSpawnPoint. Used
-- for the regular wave spawning during a miniboss fight.
function ZombieSpawnService:_GetRoomRegularSpawnPoints(roomModel: Model): { Attachment }
	local folder = roomModel:FindFirstChild(SPAWN_POINTS_FOLDER_NAME)
	if not folder then
		return {}
	end
	local points = {}
	for _, child in folder:GetChildren() do
		if child:IsA("Attachment") and child.Name ~= MINIBOSS_SPAWN_POINT_NAME then
			table.insert(points, child)
		end
	end
	return points
end

-- Spawns the named zombie at the room's MinibossSpawnPoint, tags it with
-- IsMiniboss for downstream detection, and registers it in _zombiesByRoom.
-- Returns the miniboss model, or nil if the room is missing the attachment.
function ZombieSpawnService:SpawnMinibossInRoom(room, minibossName: string, isBoss: boolean?): Model?
	if not room or not room.model then
		warn("[ZombieSpawnService] SpawnMinibossInRoom: nil room or no model")
		return nil
	end

	local attachment = self:_GetMinibossSpawnPoint(room.model)

	if not attachment then
		warn(
			("[ZombieSpawnService] Room %s has no '%s' Attachment under '%s'"):format(
				room.model.Name,
				MINIBOSS_SPAWN_POINT_NAME,
				SPAWN_POINTS_FOLDER_NAME
			)
		)
		return nil
	end

	local template = self:_zombieTemplate(minibossName)
	if not template then
		return nil
	end

	local miniboss = template:Clone()
	miniboss:SetAttribute(ROOM_ATTRIBUTE, room.id)
	-- Stamp the encounter role BEFORE parenting so the Zombie Component's
	-- Construct (fires on parent + tag) dispatches the right mob class. Boss
	-- and Miniboss are kept mutually exclusive — the Component checks IsBoss
	-- first, but exclusivity keeps downstream IsMiniboss readers unambiguous.
	if isBoss then
		miniboss:SetAttribute(Attributes.IsBoss, true)
	else
		miniboss:SetAttribute(Attributes.IsMiniBoss, true)
	end

	local hrp = miniboss:FindFirstChild("HumanoidRootPart")
	if hrp then
		hrp.CFrame = CFrame.new(attachment.WorldPosition + Vector3.new(0, ROOM_SPAWN_HEIGHT_OFFSET, 0))
	end

	self._zombiesByRoom[room.id] = self._zombiesByRoom[room.id] or {}
	table.insert(self._zombiesByRoom[room.id], miniboss)

	miniboss.Parent = workspace.IgnoreInstances.Zombies

	return miniboss
end

-- Begins a periodic wave spawner for the miniboss room. Every
-- MINIBOSS_WAVE_INTERVAL seconds, spawns one zombie at each regular
-- SpawnPoint attachment (skipping MinibossSpawnPoint). Stops when
-- StopMinibossWaves is called or the room model is destroyed.
function ZombieSpawnService:StartMinibossWaves(room)
	if not room or not room.model then
		return
	end

	-- Cancel any existing waves for this room first (defensive).
	self:StopMinibossWaves(room)

	self._activeMinibossWaves[room.id] = task.spawn(function()
		while task.wait() do
			if not room.model or not room.model.Parent then
				break
			end

			-- Frozen during a boss phase-change cutscene — don't start a wave.
			if self._minibossWavesPaused[room.id] then
				continue
			end

			if #workspace.IgnoreInstances.Zombies:GetChildren() >= MAX_MINIBOSS_WAVE_ZOMBIES then
				warn(
					("[ZombieSpawnService] Hit %d-zombie cap for miniboss waves; skipping this wave for room %s"):format(
						MAX_MINIBOSS_WAVE_ZOMBIES,
						room.model.Name
					)
				)
				continue
			end

			local points = self:_GetRoomRegularSpawnPoints(room.model)

			for _, attachment in points do
				if #workspace.IgnoreInstances.Zombies:GetChildren() >= MAX_ACTIVE_ZOMBIES then
					break
				end
				-- Phase change started mid-wave → exit the spawn loop early so
				-- no more zombies appear during the cutscene.
				if self._minibossWavesPaused[room.id] then
					break
				end

				local zombieName = self._zombiePlan:GetRandomLoot(1)
				local waveTemplate = zombieName and self:_zombieTemplate(zombieName)
				if not waveTemplate then
					continue
				end
				local zombie = waveTemplate:Clone()
				zombie:SetAttribute(ROOM_ATTRIBUTE, room.id)

				local hrp = zombie:FindFirstChild("HumanoidRootPart")
				if hrp then
					hrp.CFrame = CFrame.new(attachment.WorldPosition + Vector3.new(0, ROOM_SPAWN_HEIGHT_OFFSET, 0))
				end

				task.delay(0.5, function()
					if attachment.Parent then
						local particle = attachment:FindFirstChild("SpawnParticle")
						if particle then
							particle:Emit(35)
						end
					end
				end)

				zombie.Parent = workspace.IgnoreInstances.Zombies
				table.insert(self._zombiesByRoom[room.id], zombie)
				task.wait(SPAWN_DELAY)
			end

			task.wait(MINIBOSS_WAVE_INTERVAL)
		end
	end)
end

function ZombieSpawnService:StopMinibossWaves(room)
	if not room then
		return
	end
	local thread = self._activeMinibossWaves[room.id]
	if thread then
		task.cancel(thread)
		self._activeMinibossWaves[room.id] = nil
	end
	self._minibossWavesPaused[room.id] = nil
end

-- Freezes / unfreezes the room's wave spawner WITHOUT tearing down its thread.
-- Used to halt add spawns during a boss phase-change cutscene: the spawner
-- exits any in-progress wave early and skips new waves while paused, then
-- resumes cleanly afterward.
function ZombieSpawnService:PauseMinibossWaves(room)
	if room then
		self._minibossWavesPaused[room.id] = true
	end
end

function ZombieSpawnService:ResumeMinibossWaves(room)
	if room then
		self._minibossWavesPaused[room.id] = nil
	end
end

-- Kills every tracked zombie in the room (sets Humanoid.Health = 0 so the
-- normal death pipeline fires — drops, despawn registry, etc.). Used to
-- clean up wave minions when the miniboss is defeated, and to clear adds on a
-- boss phase change. Pass `exceptModel` to spare one mob (the boss itself
-- during a phase cutscene).
function ZombieSpawnService:DespawnZombiesInRoom(room, exceptModel: Model?)
	if not room then
		return
	end

	-- Drain the room's queue so its spawner thread exits — an encounter
	-- reset that clears a room must not leave a spawner trickling new
	-- zombies into the emptied room.
	local queue = self._roomQueues[room.id]
	if queue then
		queue.remaining = 0
	end

	local list = self._zombiesByRoom[room.id]
	if not list then
		return
	end
	-- Snapshot since the despawn signal mutates the underlying table.
	local snapshot = table.clone(list)
	for _, zombie in snapshot do
		if zombie == exceptModel then
			continue
		end
		local humanoid = zombie:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health > 0 then
			humanoid.Health = 0
		end
	end
end

function ZombieSpawnService:KnitInit()
	-- The spawn plan is built PER DUNGEON from that dungeon's zombie folder
	-- (BuildZombiePlanForDungeon, called by DungeonService on generation).
	-- Nothing static here.
end

function ZombieSpawnService:KnitStart()
	DungeonService = Knit.GetService("DungeonService")
end

return ZombieSpawnService
