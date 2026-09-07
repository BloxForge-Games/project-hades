--[[
     Author(s):
     Module: DungeonService.lua
     Description: Generates dungeon layouts. Snaps prefab chunks together via
                  EntryAnchor/ExitAnchor and produces a list of room models. Pure
                  generation only — encounter logic (gates, zombie spawns, room
                  state machine, clear detection) lives elsewhere.

                  OnRoomEntered / OnRoomCleared / OnRoomLeft signals are exposed
                  for external systems to drive; this service does not fire them.

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
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local TweenService = game:GetService("TweenService")

--[ Exports & Types & Defaults ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local Signal = require(ReplicatedStorage.Submodules.Core.Packages.Signal)
local DungeonData = require(ReplicatedStorage.Submodules.Core.Shared.Data.DungeonData)
local DungeonSequence = require(ReplicatedStorage.Submodules.Core.Shared.Data.DungeonSequence)
local CameraShakePresets = require(ReplicatedStorage.Submodules.Core.Shared.Enums.CameraShakePresets)
local Planner = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Dungeon.Planner)
local RoomTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RoomTypes)
local EventWeights = require(ReplicatedStorage.Submodules.Core.Shared.Data.EventWeights)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)

local ZombieSpawnService -- resolved in KnitStart
local EncounterService -- resolved in KnitStart
local UserNotificationService -- resolved in KnitStart
local LifeService -- resolved in KnitStart
local PlayerEventService
local RelicMachineService
local CameraShakeService
local RelicService

local DungeonService = Knit.CreateService({
	Name = "DungeonService",
	Client = {
		-- ({ phase = "in"|"out", duration }) run-loop screen fade (LandingController).
		OnRunTransition = Knit.CreateSignal(),
		OnDungeonGenerated = Knit.CreateSignal(),

		-- Join landing sequence (server-driven, per player). See
		-- _runPlayerLanding + the client-side LandingController.
		OnLandingStart = Knit.CreateSignal(), -- (to one player) fade loading screen + lock controls
		OnLandingImpact = Knit.CreateSignal(), -- (broadcast) landing-impact VFX hook → (landingPlayer)
		OnLandingEnd = Knit.CreateSignal(), -- (to one player) restore controls

		-- Dungeon Gate cycle (see _startGateCycle). Visuals are LOCAL:
		-- every client raises the opened gate; only the crossing player's
		-- client drops it back down + turns collision on locally.
		OnGateOpened = Knit.CreateSignal(), -- (broadcast) (gate, riseStuds, tweenSeconds)
		OnExitPortalRising = Knit.CreateSignal(), -- (broadcast) (portal: Model) -- the boss-room portal starts surfacing
		OnGateCrossed = Knit.CreateSignal(), -- (to one player) (gate, originalCFrame, tweenSeconds)
	},
})

--[ Imports ]--

--[ Constants ]--

local PREFAB_FOLDER_NAME = "DungeonRooms"
local RUNTIME_FOLDER_NAME = "DungeonRooms"

local ENTRY_ANCHOR_NAME = "EntryAnchor"
local EXIT_ANCHOR_NAME = "ExitAnchor"
local BRANCH_ANCHOR_NAME = "BranchAnchor"
local EXIT_GATE_NAME = "ExitGate"
local BRANCH_WALL_NAME = "BranchWall"
local START_SPAWN_NAME = "StartCFrame"
local START_SPAWN_FALLBACK_OFFSET = Vector3.new(0, 5, 0)

local BARRICADE_PREFAB_NAME = "DungeonBarricade"
local BARRICADE_DISTANCE_FROM_GATE = 2.5 -- studs into the room, on the player's side
local BARRICADE_RAYCAST_HEIGHT = 10 -- studs above the gate to start the ground ray
local BARRICADE_RAYCAST_DEPTH = 50 -- studs downward search distance

-- Dungeon Gate cycle — segment-final Combat→Combat ExitGates ONLY (the
-- indestructible door into the next CombatRoom20; NOT the breakable
-- DungeonBarricades between rooms of the same CombatRoom, and NOT the
-- Miniboss/Boss approach gates EncounterService owns). After a segment
-- clear the gate stays SOLID and shows a highlight + countdown billboard
-- (GameAssets.VFX.ActionHighlight) while players shop at their vending
-- machines. It opens after GATE_WAIT_SECONDS — or EARLY once every alive
-- player has collected a relic — then closes one-way PER PLAYER, locally,
-- as each walks through (DungeonGateController). Players still behind the
-- gate are parked under workspace.DesyncedPlayers so mob targeting ignores
-- them (filter in MobBase's alive-players cache).
local ACTION_HIGHLIGHT_NAME = "ActionHighlight"
local GATE_BILLBOARD_ACTION_TEXT = "Waiting for Players...(%d)"
local GATE_WAIT_SECONDS = 30
-- Event rooms hold their exit door LONGER — players are shopping or
-- bargaining, not just grabbing one relic. Countdown starts on the
-- FIRST player entering the event room and ends early once every
-- alive player has interacted with the event (EventService tracks).
local EVENT_GATE_WAIT_SECONDS = 60
-- Beat between the LAST player completing an event and its exit door
-- actually moving — an instant open on the final click reads glitchy.
local EVENT_GATE_OPEN_DELAY_SECONDS = 1
local GATE_COUNTDOWN_POLL_SECONDS = 0.25

-- An event hold's suspended-billboard text may be a string or a function
-- (re-read every poll, so the Coffin's line can carry live seconds). Lives
-- up here because _startGateCycle, defined above the hold API, calls it.
local function resolveSuspendedText(value: any): string?
	if type(value) == "function" then
		return value()
	end
	return value
end
local GATE_CROSS_BUFFER_STUDS = 7 -- "crossed" = this far past the gate plane (deeper than one dodge roll)
-- Crossing must ALSO happen within the doorway's width (+ this margin, in
-- studs) — the plane test alone is an INFINITE half-space, and rooms whose
-- floor extends past the gate's plane (alcoves, L-shapes, vending machines
-- near the exit wall) would falsely mark shopping players as "crossed",
-- slam their local gate, spawn the next wave, and eventually SEAL the gate
-- with everyone still inside (the relic-browsing lockout bug).
local GATE_CROSS_LATERAL_MARGIN_STUDS = 4
local GATE_CROSS_POLL_SECONDS = 0.15
local GATE_OPEN_TWEEN_SECONDS = 0.5
local GATE_CLOSE_TWEEN_SECONDS = 0.35
local GATE_RISE_EXTRA_STUDS = 2 -- raised height = gate height + this
local GATE_VISUALS_FADE_SECONDS = 0.3 -- highlight + billboard fade in / fade out
local GATE_HIGHLIGHT_FILL_TRANSPARENCY = 0.65
local GATE_HIGHLIGHT_OUTLINE_TRANSPARENCY = 0
local DESYNCED_PLAYERS_FOLDER_NAME = "DesyncedPlayers"

local NEXT_GATE_MARKER_NAME = "NextGateMarker"
local NEXT_GATE_MARKER_IMAGE = "rbxassetid://8239524757" -- urgent / objective icon
local NEXT_GATE_MARKER_COLOR = Color3.fromRGB(255, 170, 0)
local NEXT_GATE_MARKER_SIZE = 0.05

local AUTO_GENERATE_DELAY = 5

local TRAPS_FOLDER_NAME = "Traps"
local TRAP_SPAWN_CHANCE = 0.5
local AUTO_GENERATE_DIFFICULTY = "Normal"

-- Join landing timeline. The character spawns at the off-map staging spawn, is
-- posed into the animation's first (+25-stud) frame WHILE STILL THERE (hidden),
-- then teleported in already-posed so there's no default→+25 "snap", and dropped
-- via the animation. START_DELAY holds briefly so armor/weapons finish welding
-- before posing; POSE_SETTLE lets the frozen pose replicate to every client
-- before the teleport; DROP_SPEED is the playback speed of the drop; IMPACT /
-- DURATION are measured from the drop start (impact VFX, then unanchor + relic).
-- 1s (was 2): the loader is already down for the assets and the character's
-- gear welds well inside a second; the join felt slow behind the loader.
local LANDING_START_DELAY = 1
local LANDING_POSE_SETTLE = 0.2
-- How long the character HOLDS its frozen first frame, in place, before
-- the screen reveals and the drop begins. The settle above only gave
-- 0.2s between the freeze and the reveal — tight for a client that
-- is receiving the pose for the first time, which showed as a faint
-- flash of the default pose (legs) on the first visible frame.
-- 0.5s (was 1): still 2.5x the settle window above. Keep in sync with
-- LobbyLandingService.
local LANDING_POSE_HOLD_SECONDS = 0.5
local LANDING_DROP_SPEED = 0.75
local LANDING_IMPACT_DELAY = 1.6
local LANDING_DURATION = 1.7

-- RUN LOOP (see StartRun / AdvanceRun). After a boss: outro + rewards
-- (EncounterService) -> EXIT_PORTAL_DELAY -> the ExitPortal rises out of the
-- floor (Medium shake) and, unless this was the run's LAST dungeon, the
-- "next dungeon" vote pad appears (EncounterService lobby, kind NextDungeon:
-- 30s auto / 3s when everyone remaining is on it). Vote expiry ->
-- AdvanceRun: fade every screen to black, tear the whole map down,
-- generate the next DungeonSequence entry, land everyone (same landing as
-- a fresh join). Walking into the portal fires OnPlayerExtracted (bank
-- escrow there) and sends THAT player to the lobby place; they leave the
-- vote's required count. Last dungeon: NOTHING spawns; only
-- OnFinalDungeonCompleted fires (the ending is future work).
local EXIT_PORTAL_DELAY = 3
-- The ExitPortal is a Model AUTHORED INSIDE each Boss prefab, sitting
-- UNDERGROUND at its resting pose. After the boss it rises straight up by
-- its own Y extent (so its base ends level with where its top was) with a
-- MediumLong shake for everyone within EXIT_PORTAL_SHAKE_RADIUS studs.
local EXIT_PORTAL_MODEL_NAME = "ExitPortal"
local EXIT_PORTAL_RISE_SECONDS = 2
local EXIT_PORTAL_SHAKE_RADIUS = 80

-- Landing spread: players fan out sideways from the start CFrame so a
-- party doesn't land in one overlapping pile.
local LANDING_SPREAD_STUDS = 5
-- Horizontal drift from the landing spot past which the server snaps the
-- root back during the fall (see _holdLandingPosition).
local LANDING_HOLD_TOLERANCE_STUDS = 2

-- Runtime-folder children that are INFRASTRUCTURE, not dungeon content:
-- kept across teardown (Walls has its children cleared; the rest are left
-- entirely alone).
local RUNTIME_FOLDER_KEEP = { Walls = "clearChildren", Highlight = "keep" }
local RUN_TRANSITION_FADE_SECONDS = 0.6
local RUN_TRANSITION_BLACK_HOLD_SECONDS = 1.4 -- fully black before teardown starts
-- Transition landings (dungeon 2+): screen stays black through generation
-- and the teleport, then holds this long ON the new start room before the
-- reveal + drop -- so nobody ever sees the swap or a not-yet-replicated
-- teleport. The 2s join-time welding delay is skipped (gear is welded).
local RUN_TRANSITION_PRE_TELEPORT_SECONDS = 0.5
local RUN_TRANSITION_REVEAL_HOLD_SECONDS = 1
local GENERATE_CHARACTER_WAIT_SECONDS = 5 -- bounded wait for characterless players

local FLOOR_NAME = "Floor"
local MAX_BACKTRACKS = 200 -- safety cap to prevent infinite loops on broken pools
local DUNGEON_DONE_EMIT_STRENGTH = 500

-- The prefabPools name for Event rooms (DungeonData). Only this pool is
-- weight-picked; every other pool stays uniform.
local EVENT_POOL_NAME = "Event"
-- The Planner forces one Event slot per floor to this prefab; placement
-- keeps it to AT MOST one (see the merchant rule in the placement loop).
local MERCHANT_SHOP_PREFAB_NAME = "MerchantShop"
local ROOM_ATTRIBUTE = "RoomId" -- set on each room model so encounter systems can map back to room data
local WALLS_PARENT_FOLDER = workspace.IgnoreInstances.Map.DungeonRooms.Walls

--[ Properties ]--

DungeonService.Signals = {
	OnDungeonGenerated = Signal.new(), -- (dungeon)
	OnDungeonCompleted = Signal.new(), -- (dungeon) — fired when the Boss segment is opened
	OnSegmentCleared = Signal.new(), -- (dungeon, lastChunk) — fired when a non-Boss segment is opened
	OnCombatWaveStarted = Signal.new(), -- (room) — fired when a combat room's zombies spawn via the previous-room gate trigger
	-- (i.e., the player walked into combat and zombies began spawning).
	-- MusicService listens to this to swing the mainTheme volume back
	-- up after the downtime fade from OnSegmentCleared.
	-- (player) -- fired once the landing sequence ends, which is the FIRST
	-- moment the player is standing at their final dungeon CFrame. Anything
	-- that must be positioned RELATIVE to the settled player (Spirit
	-- Companions) has to wait for this: character spawn happens at the
	-- spawn point, and _runPlayerLanding teleports them away from it.
	OnPlayerLanded = Signal.new(),
	OnRoomEntered = Signal.new(), -- (player, room)
	OnRoomCleared = Signal.new(), -- (player, room)
	OnRoomLeft = Signal.new(), -- (player, room)

	-- RUN LOOP hooks.
	OnRunStarted = Signal.new(), -- (run) — first dungeon of a run is about to generate
	OnRunAdvancing = Signal.new(), -- (fromDungeon, toDungeonId) — vote passed, transition begins
	OnPlayerExtracted = Signal.new(), -- (player, dungeon) — walked into the ExitPortal (bank escrow here)
	OnFinalDungeonCompleted = Signal.new(), -- (dungeon, run) — last dungeon's boss down; nothing else spawns
	OnExitPortalRising = Signal.new(), -- (portal) — extraction portal surfacing (MusicService cues off this)
	OnEventHoldEnded = Signal.new(), -- (eventRoom) — an Event room's exit hold ran out: its gate opens, or the
	-- encounter approach beyond it begins. Event rooms never go through OpenSegmentGate, so this is the
	-- only "this room's exit is earned" edge they emit (ExitGateWindService lights the gate off it).
}

DungeonService._activeDungeon = nil
-- The RUN: which DungeonSequence entry we're on, the difficulty shared by
-- every dungeon in it, and who has already extracted through a portal (out
-- of the vote's required count, never re-landed).
DungeonService._run = nil :: { sequence: { string }, index: number, difficulty: string, exited: { [Player]: true } }?
DungeonService._exitPortal = nil :: Model?
DungeonService._transitioning = false
-- Players frozen (HRP anchored) for the map swap; released at their teleport.
DungeonService._transitionFrozen = {} :: { [Player]: true }
-- Set for the duration of GenerateDungeon so prefab lookups resolve the
-- dungeon being built (before _activeDungeon flips over to it).
DungeonService._generatingDungeonId = nil :: string?
DungeonService._playerRoomCursor = {} -- [Player]: number
DungeonService._openedSegments = {} -- [segmentId]: true
-- EVENT HOLD SUSPENSION (see SuspendEventHold). [roomId]: billboard text
-- while suspended; [roomId]: true once released.
DungeonService._suspendedEventHolds = {} :: { [number]: any }
DungeonService._releasedEventHolds = {} :: { [number]: true }
DungeonService._nextGateMarker = nil :: Model?
DungeonService._readyForLanding = {} -- [Player]: true — client preload finished (per join)
DungeonService._landed = {} -- [Player]: true — already landed in the CURRENT dungeon

--[ Private Functions ]--

-- ServerStorage.GameAssets.DungeonRooms.<dungeonId> -- each dungeon has its
-- own prefab folder (Combat / Shrine / Miniboss / Boss / Treasure pools +
-- Start). Resolves the dungeon being GENERATED (or the active one), and
-- falls back to the flat DungeonRooms folder with a warn so an unauthored
-- dungeon still generates rather than asserting.
function DungeonService:_getPrefabRoot(): Folder?
	local gameAssets = ServerStorage:FindFirstChild("GameAssets")
	local root = gameAssets and gameAssets:FindFirstChild(PREFAB_FOLDER_NAME)
	if not root then
		return nil
	end
	local dungeonId = self._generatingDungeonId or (self._activeDungeon and self._activeDungeon.id)
	if dungeonId then
		local perDungeon = root:FindFirstChild(dungeonId)
		if perDungeon then
			return perDungeon
		end
		warn(
			("[DungeonService] No prefab folder GameAssets.DungeonRooms.%s -- using the flat folder"):format(dungeonId)
		)
	end
	return root
end

function DungeonService:_pickPrefab(poolName: string, rng: Random): Model
	local root = self:_getPrefabRoot()
	assert(root, "[DungeonService] Missing ServerStorage.GameAssets." .. PREFAB_FOLDER_NAME)
	local folder = root:FindFirstChild(poolName)
	assert(folder, "[DungeonService] Missing prefab pool folder: " .. poolName)
	local prefabs = folder:GetChildren()
	assert(#prefabs > 0, "[DungeonService] Empty prefab pool: " .. poolName)
	return prefabs[rng:NextInteger(1, #prefabs)]
end

-- Picks a prefab from the pool, skipping any in `excluded`. Returns nil if
-- every variant has been tried.
-- Exact-name lookup in a pool folder, for Planner-forced prefabs.
function DungeonService:_findPrefabByName(poolName: string, prefabName: string): Model?
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
function DungeonService:_pickPrefabExcluding(poolName: string, excluded: { [Model]: true }, rng: Random): Model?
	local root = self:_getPrefabRoot()
	if not root then
		return nil
	end
	local folder = root:FindFirstChild(poolName)
	if not folder then
		return nil
	end
	local available = {}
	for _, prefab in folder:GetChildren() do
		if not excluded[prefab] then
			table.insert(available, prefab)
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

function DungeonService:_getRoomFloors(model: Model): { BasePart }
	local floors = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") and descendant.Name == FLOOR_NAME then
			table.insert(floors, descendant)
		end
	end
	return floors
end

function DungeonService:_floorsOverlapAny(candidateFloors: { BasePart }, placedFloors: { BasePart }): boolean
	if #placedFloors == 0 then
		return false
	end
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = placedFloors
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
function DungeonService:_anchorCFrame(anchor: Instance): CFrame?
	if anchor:IsA("BasePart") then
		return anchor.CFrame
	elseif anchor:IsA("Attachment") then
		return anchor.WorldCFrame
	end
	return nil
end

function DungeonService:_findAllAnchors(instance: Instance, anchorName: string): { Instance }
	local matches = {}
	for _, descendant in instance:GetDescendants() do
		if descendant.Name == anchorName and self:_anchorCFrame(descendant) then
			table.insert(matches, descendant)
		end
	end
	return matches
end

function DungeonService:_findAnchor(instance: Instance, anchorName: string, optional: boolean?): Instance?
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
			("[DungeonService] Found something named %q in %s but it is a %s (need BasePart or Attachment)"):format(
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
			("[DungeonService] %s has no child named %q. Direct children: [%s]"):format(
				instance.Name,
				anchorName,
				table.concat(childList, ", ")
			)
		)
	end
	return nil
end

function DungeonService:_snapPrefab(
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
	-- stored, and never fires when a player or zombie actually
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
		("[DungeonService] Prefab %s missing BasePart/Attachment named %s (searched recursively)"):format(
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

	clone.Parent = parentFolder

	return clone
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
function DungeonService:_randomizeChunkTraps(chunk: Model)
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

function DungeonService:_ensureRuntimeFolder(): Folder
	local map = workspace.IgnoreInstances:FindFirstChild("Map")
	assert(map, "[DungeonService] workspace.IgnoreInstances.Map is missing")
	local folder = map:FindFirstChild(RUNTIME_FOLDER_NAME)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = RUNTIME_FOLDER_NAME
		folder.Parent = map
	end
	return folder
end

function DungeonService:_makeRoom(node, model: Model)
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

function DungeonService:_placeGateBarricade(roomModel: Instance, gate: BasePart)
	local breakablesFolder = ReplicatedStorage:FindFirstChild("GameAssets")
		and ReplicatedStorage.GameAssets:FindFirstChild("Breakables")
	local template = breakablesFolder and breakablesFolder:FindFirstChild(BARRICADE_PREFAB_NAME)

	if not template then
		warn("[DungeonService] Missing ReplicatedStorage.GameAssets.Breakables." .. BARRICADE_PREFAB_NAME)
		return
	end

	-- Horizontal direction from the gate toward the room's center = the
	-- side of the gate where players approach from.
	local roomCenter = roomModel:GetPivot().Position
	local towardCenter = (roomCenter - gate.Position) * Vector3.new(1, 0, 1)
	if towardCenter.Magnitude <= 0 then
		-- Degenerate case (gate sits on the model's pivot). Fall back to
		-- the gate's own -LookVector so we still place something useful.
		towardCenter = -gate.CFrame.LookVector * Vector3.new(1, 0, 1)
	end
	local playerSide = towardCenter.Unit

	local barricadeXZ = gate.Position + (playerSide * BARRICADE_DISTANCE_FROM_GATE)

	-- Raycast straight down to ground the barricade on the dungeon floor.
	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Include
	raycastParams.FilterDescendantsInstances = { workspace.IgnoreInstances.Map.DungeonRooms }
	local rayOrigin = Vector3.new(barricadeXZ.X, barricadeXZ.Y + BARRICADE_RAYCAST_HEIGHT, barricadeXZ.Z)
	local hit = workspace:Raycast(rayOrigin, Vector3.new(0, -BARRICADE_RAYCAST_DEPTH, 0), raycastParams)
	local floorY = hit and hit.Position.Y or (gate.Position.Y - gate.Size.Y / 2)

	local barricade = template:Clone()
	local barricadeHeight = barricade:GetExtentsSize().Y
	local center = Vector3.new(barricadeXZ.X, floorY + (barricadeHeight / 2), barricadeXZ.Z)

	-- Face the player (look back toward the room center). Using lookAt avoids
	-- inheriting any pitch/roll from the gate's own CFrame.
	barricade:PivotTo(CFrame.lookAt(center, center - playerSide))
	barricade.Parent = workspace.IgnoreInstances.Map.DungeonRooms
end

function DungeonService:_setupGateTrigger(model: Instance, nextRoomId: number, placeBarricade: boolean?)
	local gate = model:FindFirstChild(EXIT_GATE_NAME)
	if not gate or not gate:IsA("BasePart") then
		return
	end

	gate.CanCollide = false
	gate.CanQuery = false
	gate.Transparency = 1

	for _, texture in pairs(gate:GetDescendants()) do
		if texture:IsA("Texture") or texture:IsA("Decal") then
			texture.Transparency = 1
		end
	end

	-- Spawn a Breakable barricade in front of the gate so players can't
	-- bump the gate's Touched trigger until they've destroyed it. Skipped
	-- for segment-final gates — those should just open after a clear.
	if placeBarricade ~= false then
		self:_placeGateBarricade(model, gate)
	end

	local fired = false
	local connection

	connection = gate.Touched:Connect(function(hit: BasePart)
		if fired then
			return
		end
		local character = hit:FindFirstAncestorOfClass("Model")
		local player = character and Players:GetPlayerFromCharacter(character)
		if not player then
			return
		end

		fired = true
		connection:Disconnect()

		local dungeon = self._activeDungeon
		local nextRoom = dungeon and dungeon.rooms[nextRoomId]

		-- Note: Miniboss / Boss next-rooms are intentionally NOT handled here.
		-- Those approaches go through OpenSegmentGate → EncounterService:StartEncounter
		-- when the previous combat segment is cleared, and the approach gate
		-- stays solid (never touch-triggered) so players can't bypass the lobby.
		if nextRoom and ZombieSpawnService and nextRoom.roomType == RoomTypes.Combat then
			ZombieSpawnService:SpawnZombiesInRoom(nextRoom)
			-- Fire the wave-started signal so MusicService can swing
			-- mainTheme back to FULL after the OnSegmentCleared
			-- downtime fade. Fires for the FIRST combat room too —
			-- the Start gate goes through this same code path.
			self.Signals.OnCombatWaveStarted:Fire(nextRoom)
		elseif nextRoom and nextRoom.roomType == RoomTypes.Event then
			-- First room is an EVENT (the Planner's debug first-room event,
			-- or any future layout that opens on one). The gate-cycle path
			-- starts the event's exit hold on first crossing; this touch
			-- path must do the same, or the event's exit gate never opens.
			task.spawn(function()
				self:_startEventGateHold(nextRoom)
			end)
		end

		gate:Destroy()

		-- Keep every player's cursor in sync — the whole party progresses
		-- together through the segment.
		for _, p in Players:GetPlayers() do
			self:AdvancePlayer(p)
		end
	end)
end

-- Alive, in-world players — the set the Dungeon Gate cycle waits on. Dead /
-- spectating (Death attribute) players never hold up the countdown or the
-- all-crossed check.
local function isGateEligible(player: Player): (boolean, Model?, BasePart?)
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not (character and hrp and humanoid) or humanoid.Health <= 0 then
		return false
	end
	if character:GetAttribute(Attributes.Death) == true then
		return false
	end
	return true, character, hrp
end

-- Fades the gate's ActionHighlight visuals in (to their authored look) or
-- out (to fully invisible, ahead of destroy). Tweened properties per the
-- design: TextLabel.TextTransparency + UIStroke.Transparency on the
-- billboard; FillTransparency (→0.65) + OutlineTransparency (→0) on the
-- highlight. Server-side tweens — a one-shot 0.3s fade replicates fine.
local function tweenGateVisuals(highlight: Instance?, billboard: Instance?, fadeIn: boolean)
	local tweenInfo = TweenInfo.new(GATE_VISUALS_FADE_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

	if highlight and highlight:IsA("Highlight") then
		if fadeIn then
			highlight.FillTransparency = 1
			highlight.OutlineTransparency = 1
		end
		TweenService:Create(highlight, tweenInfo, {
			FillTransparency = if fadeIn then GATE_HIGHLIGHT_FILL_TRANSPARENCY else 1,
			OutlineTransparency = if fadeIn then GATE_HIGHLIGHT_OUTLINE_TRANSPARENCY else 1,
		}):Play()
	end

	if billboard then
		for _, descendant in billboard:GetDescendants() do
			if descendant:IsA("TextLabel") then
				if fadeIn then
					descendant.TextTransparency = 1
				end
				TweenService:Create(descendant, tweenInfo, { TextTransparency = if fadeIn then 0 else 1 }):Play()
			elseif descendant:IsA("UIStroke") then
				if fadeIn then
					descendant.Transparency = 1
				end
				TweenService:Create(descendant, tweenInfo, { Transparency = if fadeIn then 0.5 else 1 }):Play()
			end
		end
	end
end

-- Horizontal unit vector pointing from `gate` toward the room's center —
-- the side players approach from. The crossing check's "past the gate"
-- direction is the negation.
function DungeonService:_gatePlayerSide(roomModel: Instance, gate: BasePart): Vector3
	local roomCenter = roomModel:GetPivot().Position
	local towardCenter = (roomCenter - gate.Position) * Vector3.new(1, 0, 1)
	if towardCenter.Magnitude <= 0 then
		towardCenter = -gate.CFrame.LookVector * Vector3.new(1, 0, 1)
	end
	return towardCenter.Unit
end

-- First player through the opened Dungeon Gate: spawn the next CombatRoom's
-- wave and advance every player's cursor — the same commitment the old
-- gate-touch trigger used to make.
function DungeonService:_onGateFirstCrossing(nextRoomId: number)
	local dungeon = self._activeDungeon
	local nextRoom = dungeon and dungeon.rooms[nextRoomId]

	if nextRoom and ZombieSpawnService and nextRoom.roomType == RoomTypes.Combat then
		ZombieSpawnService:SpawnZombiesInRoom(nextRoom)
		self.Signals.OnCombatWaveStarted:Fire(nextRoom)
	elseif nextRoom and nextRoom.roomType == RoomTypes.Event then
		-- First body through the door starts the event room's own exit
		-- hold (design call: the party's clock starts when someone
		-- actually walks in, not when the previous room was cleared).
		task.spawn(function()
			self:_startEventGateHold(nextRoom)
		end)
	end

	for _, p in Players:GetPlayers() do
		self:AdvancePlayer(p)
	end
end

-- The Dungeon Gate cycle for a cleared Combat segment (see the constants
-- block for the full design). Timeline:
--   1. Gate stays SOLID. ActionHighlight visuals go on it: a Highlight and
--      a countdown BillboardGui ("Waiting for Players...(x)").
--   2. Countdown: GATE_WAIT_SECONDS, ended EARLY once every alive player
--      has collected a relic (RelicService.Signals.OnRelicsUpdated).
--   3. OPEN: visuals removed, server CanCollide off, every client raises
--      the gate locally. All alive players are parked under
--      workspace.DesyncedPlayers — mobs ignore them until they commit.
--   4. Each player crossing — GATE_CROSS_BUFFER_STUDS past the gate plane
--      (deeper than a dodge roll, so rolling back at the doorway doesn't
--      count) AND within the doorway's horizontal span (the plane alone is
--      infinite; room floor past it must not count as crossing) — returns
--      to workspace.Players and gets a per-client cue to drop the gate +
--      enable LOCAL collision: one-way for them, still open for everyone
--      behind. The FIRST crossing spawns the next wave.
--   5. Once every alive player is through, the server re-verifies nobody
--      is still on the room side (seal guard — stale marks get unmarked
--      and their local gate re-opened), then makes the closed state
--      authoritative (CanCollide on) and stops tracking.
-- `countdownOverride` swaps the hold rules while keeping the ENTIRE
-- cycle (visuals, crossing watch, per-player one-way close, first-
-- crossing spawn) intact: { seconds: number, isDone: (Player) -> bool,
-- isSuspended: (() -> string?)?, isReleased: (() -> boolean)? }. While
-- isSuspended returns text the countdown freezes and the billboard
-- shows that text; isReleased true ends the hold at once.
-- Nil = the classic relic-shopping hold. The event exit uses this so a
-- shop between two combat rooms behaves EXACTLY like a combat gate
-- once its own 60s / all-interacted hold resolves.
function DungeonService:_startGateCycle(lastChunk, nextRoomId: number, countdownOverride: any?)
	local gate = lastChunk.model:FindFirstChild(EXIT_GATE_NAME)
	if not gate or not gate:IsA("BasePart") then
		return
	end

	local dungeon = self._activeDungeon

	-- 1) Highlight + countdown billboard. Prefer instances already on the
	-- gate (authored/testing), otherwise clone from the shared VFX asset.
	local vfxFolder = ReplicatedStorage.GameAssets:FindFirstChild("VFX")
	local template = vfxFolder and vfxFolder:FindFirstChild(ACTION_HIGHLIGHT_NAME)

	-- Darkened gate highlight while the door waits for players (back in the
	-- 2026-09 pass; it had been cut as "read as a glitch"). Prefer one
	-- authored on the gate, else clone the template's; tweenGateVisuals
	-- fades it in to GATE_HIGHLIGHT_*_TRANSPARENCY and out before destroy.
	local highlight = gate:FindFirstChildOfClass("Highlight")
	if not highlight and template then
		local highlightTemplate = template:FindFirstChildOfClass("Highlight")
		highlight = highlightTemplate and highlightTemplate:Clone()
		if highlight then
			highlight.Adornee = gate
			highlight.Parent = gate
		end
	end
	if highlight then
		-- Occluded: walls in front of the door hide it, so the darkening
		-- reads as the door itself rather than an X-ray through the room.
		highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	end

	local billboard = gate:FindFirstChildOfClass("BillboardGui")
	if not billboard and template then
		local billboardTemplate = template:FindFirstChildOfClass("BillboardGui")
		billboard = billboardTemplate and billboardTemplate:Clone()
		if billboard then
			billboard.Parent = gate
		end
	end
	if not template and not billboard then
		warn("[DungeonService] Missing ReplicatedStorage.GameAssets.VFX." .. ACTION_HIGHLIGHT_NAME)
	end

	local actionText = billboard and billboard:FindFirstChild("Frame") and billboard.Frame:FindFirstChild("ActionText")
	if actionText then
		actionText.Text =
			GATE_BILLBOARD_ACTION_TEXT:format((countdownOverride and countdownOverride.seconds) or GATE_WAIT_SECONDS)
	end

	tweenGateVisuals(highlight, billboard, true)

	-- 2) Countdown. Ends at the deadline or EARLY once every alive player
	-- has collected a relic from their vending machine.
	local chosen: { [number]: true } = {}
	local relicConnection
	if not countdownOverride then
		relicConnection = RelicService.Signals.OnRelicsUpdated:Connect(function(player: Player)
			chosen[player.UserId] = true
		end)
	end
	local isPlayerDone = if countdownOverride and countdownOverride.isDone
		then countdownOverride.isDone
		else function(player: Player)
			return chosen[player.UserId] == true
		end

	local brokeEarly = false
	local deadline = os.clock() + ((countdownOverride and countdownOverride.seconds) or GATE_WAIT_SECONDS)
	while os.clock() < deadline do
		if self._activeDungeon ~= dungeon or not gate.Parent then
			if relicConnection then
				relicConnection:Disconnect()
			end
			return
		end

		-- SUSPENDED (an event challenge is running): the countdown freezes
		-- and the billboard reads the challenge line. RELEASED: the hold is
		-- over now, whatever the clock says.
		local suspendedText = resolveSuspendedText(
			countdownOverride and countdownOverride.isSuspended and countdownOverride.isSuspended()
		)
		if suspendedText then
			deadline = os.clock() + GATE_COUNTDOWN_POLL_SECONDS * 4
			if actionText then
				actionText.Text = suspendedText
			end
			task.wait(GATE_COUNTDOWN_POLL_SECONDS)
			continue
		end
		if countdownOverride and countdownOverride.isReleased and countdownOverride.isReleased() then
			print("[DungeonService] Gate cycle: hold released, opening " .. gate:GetFullName())
			brokeEarly = true
			break
		end

		if actionText then
			actionText.Text = GATE_BILLBOARD_ACTION_TEXT:format(math.ceil(deadline - os.clock()))
		end

		local eligible = 0
		local allChosen = true
		for _, player in Players:GetPlayers() do
			if isGateEligible(player) then
				eligible += 1
				if not isPlayerDone(player) then
					allChosen = false
				end
			end
		end
		if eligible > 0 and allChosen then
			brokeEarly = true
			break
		end

		task.wait(GATE_COUNTDOWN_POLL_SECONDS)
	end
	if relicConnection then
		relicConnection:Disconnect()
	end

	-- Early-open pause (event holds only): everyone just finished — let
	-- the moment land for openDelaySeconds before the door moves. The
	-- staleness guard below re-checks after the wait.
	if brokeEarly and countdownOverride and countdownOverride.openDelaySeconds then
		task.wait(countdownOverride.openDelaySeconds)
	end

	if self._activeDungeon ~= dungeon or not gate.Parent then
		return
	end

	-- 3) OPEN. Visuals fade out while the door rises, then get destroyed.
	tweenGateVisuals(highlight, billboard, false)
	task.delay(GATE_VISUALS_FADE_SECONDS, function()
		if highlight then
			highlight:Destroy()
		end
		if billboard then
			billboard:Destroy()
		end
	end)

	gate.CanCollide = false
	gate:SetAttribute("GateState", "open")
	self.Client.OnGateOpened:FireAll(gate, gate.Size.Y + GATE_RISE_EXTRA_STUDS, GATE_OPEN_TWEEN_SECONDS)

	local desyncedFolder = workspace:FindFirstChild(DESYNCED_PLAYERS_FOLDER_NAME)
	if not desyncedFolder then
		warn("[DungeonService] workspace." .. DESYNCED_PLAYERS_FOLDER_NAME .. " missing — mob-desync disabled.")
	end

	-- 4) Crossing watch. Parent reconciliation runs every poll so respawned
	-- characters land back in the right folder automatically.
	local crossed: { [number]: true } = {}
	local waveStarted = false
	local forward = -self:_gatePlayerSide(lastChunk.model, gate)

	-- Doorway-bounded crossing test. "Crossed" means the player actually
	-- went THROUGH the doorway: past the gate plane by the depth buffer AND
	-- horizontally within the doorway's span. Depth alone is an infinite
	-- half-space — see GATE_CROSS_LATERAL_MARGIN_STUDS for the lockout bug
	-- that allowed. max(Size.X, Size.Z) keeps the span test agnostic to
	-- which local axis the gate part was authored wide on.
	local doorwayHalfSpan = math.max(gate.Size.X, gate.Size.Z) / 2 + GATE_CROSS_LATERAL_MARGIN_STUDS

	-- Depth-only half-space check (`forward` is XZ-planar, so Y cancels).
	-- The seal guard below re-verifies with THIS weaker predicate, not the
	-- doorway-bounded one: a legitimately-crossed player roams the next
	-- room, far outside the doorway span, but must still be past the plane.
	local function isPastGatePlane(hrpPosition: Vector3): boolean
		return (hrpPosition - gate.Position):Dot(forward) >= GATE_CROSS_BUFFER_STUDS
	end

	local function isThroughDoorway(hrpPosition: Vector3): boolean
		local offset = hrpPosition - gate.Position
		local depth = offset:Dot(forward)
		if depth < GATE_CROSS_BUFFER_STUDS then
			return false
		end
		-- Horizontal distance from the doorway's center line.
		local lateral = (offset - forward * depth) * Vector3.new(1, 0, 1)
		return lateral.Magnitude <= doorwayHalfSpan
	end

	while self._activeDungeon == dungeon and gate.Parent do
		local eligible = 0
		local allCrossed = true

		for _, player in Players:GetPlayers() do
			local ok, character, hrp = isGateEligible(player)
			if not ok then
				continue
			end

			eligible += 1

			if crossed[player.UserId] then
				if character.Parent ~= workspace.Players then
					character.Parent = workspace.Players
				end
				continue
			end

			if isThroughDoorway(hrp.Position) then
				crossed[player.UserId] = true
				character.Parent = workspace.Players

				if not waveStarted then
					waveStarted = true
					self:_onGateFirstCrossing(nextRoomId)
				end

				-- One-way, LOCALLY: only this player's client drops the
				-- gate and turns collision on. Everyone still behind keeps
				-- an open gate on their screen.
				self.Client.OnGateCrossed:Fire(player, gate, gate.CFrame, GATE_CLOSE_TWEEN_SECONDS)
			else
				allCrossed = false
				if desyncedFolder and character.Parent ~= desyncedFolder then
					character.Parent = desyncedFolder
				end
			end
		end

		if eligible > 0 and allCrossed then
			-- Seal guard: never make the closed state authoritative while an
			-- alive player is still on the ROOM side of the plane. Belt-and-
			-- suspenders for crossed marks gone stale — e.g. a crossed player
			-- who died and respawned behind the gate before this poll caught
			-- the wipe, or any future regression in the crossing test. A
			-- caught player is unmarked and their local gate re-opened (their
			-- client slammed it when the stale mark fired OnGateCrossed);
			-- worst case is a spurious local slam+reopen, never a lockout.
			local verified = true
			for _, player in Players:GetPlayers() do
				local ok, _, hrp = isGateEligible(player)
				if ok and crossed[player.UserId] and hrp and not isPastGatePlane(hrp.Position) then
					crossed[player.UserId] = nil
					verified = false
					self.Client.OnGateOpened:Fire(
						player,
						gate,
						gate.Size.Y + GATE_RISE_EXTRA_STUDS,
						GATE_OPEN_TWEEN_SECONDS
					)
				end
			end
			if verified then
				break
			end
		end

		task.wait(GATE_CROSS_POLL_SECONDS)
	end

	-- 5) FINALIZE: everyone's through — make the closed state authoritative
	-- (matches each crosser's local gate) and stop tracking.
	if self._activeDungeon == dungeon and gate.Parent then
		gate.CanCollide = true
		gate:SetAttribute("GateState", "sealed")
	end
end

-- The EVENT room's exit-door hold. Mirrors the gate cycle's shape (solid
-- gate + ActionHighlight countdown billboard) but with different rules:
--   * EVENT_GATE_WAIT_SECONDS on the clock, not the relic gate's 30.
--   * Ends EARLY once every alive player has interacted with the event
--     (EventService's per-room registry: finishing the Sword or Shrine
--     conversation, or telling the Merchant "I'm ready to continue").
--   * The event never "clears" (nothing spawns in it), so this is the
--     ONLY thing standing between the party and the Miniboss/Boss the
--     sequence always places next. When the hold ends we run the same
--     approach flow the old Combat→Miniboss path ran: notification +
--     EncounterService:StartEncounter at this gate. The gate itself
--     stays solid — the encounter owns it from here, exactly as before.
-- EVENT HOLD SUSPENSION (CoffinEventService). While a room's exit hold is
-- suspended its countdown neither ticks down nor early-opens, and the
-- gate billboard shows `text` instead of the countdown. ReleaseEventHold
-- ends the hold at once: the door opens after the usual beat (or the
-- encounter approach begins). Keyed by room id; both are cleared when
-- the room's hold starts.
-- `text` may be a STRING or a FUNCTION returning one, re-read every poll
-- (the Coffin's line carries its live seconds).
function DungeonService:SuspendEventHold(roomId: number, text: (string | () -> string)?)
	self._suspendedEventHolds[roomId] = text or "Challenge in progress..."
end

function DungeonService:ReleaseEventHold(roomId: number)
	print(("[DungeonService] Event hold RELEASED for room %s"):format(tostring(roomId)))
	self._suspendedEventHolds[roomId] = nil
	self._releasedEventHolds[roomId] = true
end

function DungeonService:_startEventGateHold(eventRoom)
	local gate = eventRoom.model and eventRoom.model:FindFirstChild(EXIT_GATE_NAME)
	if not gate or not gate:IsA("BasePart") then
		warn(("[DungeonService] Event room '%s' has no ExitGate — hold skipped"):format(tostring(eventRoom.model)))
		return
	end

	local dungeon = self._activeDungeon
	local nextRoom = dungeon and dungeon.rooms[eventRoom.id + 1]

	-- Fresh hold, fresh suspension state (room ids repeat across floors).
	self._suspendedEventHolds[eventRoom.id] = nil
	self._releasedEventHolds[eventRoom.id] = nil

	-- EventService owns the interacted-registry. Resolved here (not at
	-- module scope) to keep the service graph acyclic.
	local eventService = Knit.GetService("EventService")

	-- Event —> COMBAT: the exit must be a REAL combat gate — crossing
	-- watch, per-player one-way close, first-crossing wave spawn — so
	-- delegate to the full gate cycle, swapping only the countdown rules
	-- (60s, early-open once every alive player has interacted). This is
	-- what makes a shop BETWEEN two combat rooms flow like any other
	-- room transition.
	if nextRoom and nextRoom.roomType == RoomTypes.Combat then
		self:_startGateCycle(eventRoom, eventRoom.id + 1, {
			seconds = EVENT_GATE_WAIT_SECONDS,
			openDelaySeconds = EVENT_GATE_OPEN_DELAY_SECONDS,
			isSuspended = function(): any
				return self._suspendedEventHolds[eventRoom.id]
			end,
			isReleased = function(): boolean
				return self._releasedEventHolds[eventRoom.id] == true
			end,
			isDone = function(player: Player): boolean
				local interacted = eventService and eventService:GetEventInteractions(eventRoom.id)
				return interacted ~= nil and interacted[player.UserId] == true
			end,
		})
		return
	end

	-- Highlight + countdown billboard, same assets as the gate cycle.
	local vfxFolder = ReplicatedStorage.GameAssets:FindFirstChild("VFX")
	local template = vfxFolder and vfxFolder:FindFirstChild(ACTION_HIGHLIGHT_NAME)
	-- Darkened gate highlight while the door waits for players (back in the
	-- 2026-09 pass; it had been cut as "read as a glitch"). Prefer one
	-- authored on the gate, else clone the template's; tweenGateVisuals
	-- fades it in to GATE_HIGHLIGHT_*_TRANSPARENCY and out before destroy.
	local highlight = gate:FindFirstChildOfClass("Highlight")
	if not highlight and template then
		local highlightTemplate = template:FindFirstChildOfClass("Highlight")
		highlight = highlightTemplate and highlightTemplate:Clone()
		if highlight then
			highlight.Adornee = gate
			highlight.Parent = gate
		end
	end
	if highlight then
		-- Occluded: walls in front of the door hide it, so the darkening
		-- reads as the door itself rather than an X-ray through the room.
		highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	end
	local billboard = gate:FindFirstChildOfClass("BillboardGui")
	if not billboard and template then
		local billboardTemplate = template:FindFirstChildOfClass("BillboardGui")
		billboard = billboardTemplate and billboardTemplate:Clone()
		if billboard then
			billboard.Parent = gate
		end
	end
	local actionText = billboard and billboard:FindFirstChild("Frame") and billboard.Frame:FindFirstChild("ActionText")
	if actionText then
		actionText.Text = GATE_BILLBOARD_ACTION_TEXT:format(EVENT_GATE_WAIT_SECONDS)
	end
	tweenGateVisuals(highlight, billboard, true)

	local deadline = os.clock() + EVENT_GATE_WAIT_SECONDS
	while os.clock() < deadline do
		if self._activeDungeon ~= dungeon or not gate.Parent then
			return
		end
		-- Suspended / released: same rules as the gate cycle above.
		local suspendedText = resolveSuspendedText(self._suspendedEventHolds[eventRoom.id])
		if suspendedText then
			deadline = os.clock() + GATE_COUNTDOWN_POLL_SECONDS * 4
			if actionText then
				actionText.Text = suspendedText
			end
			task.wait(GATE_COUNTDOWN_POLL_SECONDS)
			continue
		end
		if self._releasedEventHolds[eventRoom.id] == true then
			print("[DungeonService] Event hold: released, ending hold on " .. gate:GetFullName())
			break
		end

		if actionText then
			actionText.Text = GATE_BILLBOARD_ACTION_TEXT:format(math.ceil(deadline - os.clock()))
		end

		local interacted = eventService and eventService:GetEventInteractions(eventRoom.id) or nil
		if interacted then
			local eligible = 0
			local allDone = true
			for _, player in Players:GetPlayers() do
				if isGateEligible(player) then
					eligible += 1
					if not interacted[player.UserId] then
						allDone = false
					end
				end
			end
			if eligible > 0 and allDone then
				break
			end
		end

		task.wait(GATE_COUNTDOWN_POLL_SECONDS)
	end

	if self._activeDungeon ~= dungeon or not gate.Parent then
		return
	end

	tweenGateVisuals(highlight, billboard, false)
	task.delay(GATE_VISUALS_FADE_SECONDS, function()
		if highlight then
			highlight:Destroy()
		end
		if billboard then
			billboard:Destroy()
		end
	end)

	-- The hold is over: whatever follows, this room's exit is now earned.
	self.Signals.OnEventHoldEnded:Fire(eventRoom)

	if nextRoom and (nextRoom.roomType == RoomTypes.Miniboss or nextRoom.roomType == RoomTypes.Boss) then
		local isBoss = nextRoom.roomType == RoomTypes.Boss
		local indicatorText = isBoss and "Boss Chamber" or "Miniboss Chamber"
		local indicatorSubtext = isBoss and "Boss Chamber found, get ready!" or "Miniboss Chamber found, get ready!"
		for _, player in pairs(Players:GetPlayers()) do
			UserNotificationService:RequestUserNotification(player, {
				titleText = indicatorText,
				titleTextFont = Enum.Font.SourceSansBold,
				titleTextColor3 = Color3.fromRGB(170, 85, 255),
				titleTextTransparency = 0,

				text = indicatorSubtext,
				textFont = Enum.Font.SourceSansBold,
				textColor3 = Color3.fromRGB(255, 255, 255),
				textTransparency = 0,
			})
		end
		if EncounterService then
			EncounterService:StartEncounter(nextRoom.roomType, nextRoom, gate.CFrame)
		end
	else
		-- Sequence edge (an Event not followed by Miniboss/Boss): just
		-- open. Deliberately NOT the full gate cycle — nothing shoppy
		-- follows an event room today.
		gate.CanCollide = false
		gate:SetAttribute("GateState", "open")
		self.Client.OnGateOpened:FireAll(gate, gate.Size.Y + GATE_RISE_EXTRA_STUDS, GATE_OPEN_TWEEN_SECONDS)
	end
end

function DungeonService:_areSegmentZombiesCleared(segmentId: number): boolean
	local dungeon = self._activeDungeon
	if not dungeon or not ZombieSpawnService then
		return false
	end
	for _, room in dungeon.rooms do
		if room.segmentId == segmentId then
			if not ZombieSpawnService:WasRoomSpawned(room) then
				return false
			end
			-- Queue must be fully SPAWNED OUT, not just "no zombies alive
			-- right now" — killing the first 5 of a 10-zombie queue leaves
			-- an empty room for a beat while the spawner tops back up, and
			-- that beat must not open the gate.
			if not ZombieSpawnService:IsRoomQueueExhausted(room) then
				return false
			end
			if #ZombieSpawnService:GetZombiesInRoom(room) > 0 then
				return false
			end
		end
	end
	return true
end

-- Finds the last chunk of the given segment.
function DungeonService:_getSegmentLastChunk(segmentId: number)
	local dungeon = self._activeDungeon
	if not dungeon then
		return nil
	end
	for _, room in dungeon.rooms do
		if room.segmentId == segmentId and room.isLastChunk then
			return room
		end
	end
	return nil
end

-- `countdownOverride` (optional) is passed straight through to the gate
-- cycle — see _startGateCycle. EncounterService uses it after a
-- miniboss: its reward CHESTS have already gated the call on every
-- player opening theirs, so the classic relic-shopping hold (which
-- only ends early on a vending-machine relic pickup that no longer
-- happens) would otherwise sit the full GATE_WAIT_SECONDS.
function DungeonService:OpenSegmentGate(segmentId: number, skipDungeonDoneEffect: boolean?, countdownOverride: any?)
	if self._openedSegments[segmentId] then
		return
	end

	local lastChunk = self:_getSegmentLastChunk(segmentId)

	if not lastChunk then
		return
	end

	self._openedSegments[segmentId] = true

	-- Post-Boss path: dungeon complete, gate opens visually.
	if lastChunk.roomType == RoomTypes.Boss then
		if not skipDungeonDoneEffect then
			task.delay(0.5, function()
				self:_emitDungeonDoneEffect(lastChunk.model)
			end)
		end

		-- The Boss room's ExitGate is deliberately LEFT ALONE (solid, black):
		-- the run continues through the ExitPortal / vote, never through it.

		task.delay(0.5, function()
			if UserNotificationService then
				local isFinal = self:IsFinalDungeon()
				for _, player in pairs(Players:GetPlayers()) do
					UserNotificationService:RequestUserNotification(player, {
						titleText = "Boss Defeated",
						titleTextFont = Enum.Font.SourceSansBold,
						titleTextColor3 = Color3.fromRGB(85, 255, 127),
						titleTextTransparency = 0,

						text = if isFinal then "The run is complete." else "Collect your rewards...",
						textFont = Enum.Font.SourceSansBold,
						textColor3 = Color3.fromRGB(255, 255, 255),
						textTransparency = 0,
					})
				end
			end
		end)

		-- The run continues from EncounterService.OnEncounterOutroFinished
		-- (rewards dropped) -> _onBossRewardsDropped -> portal + vote. The old
		-- fixed 5-minute TeleportAllToLobby is gone.
		self.Signals.OnDungeonCompleted:Fire(self._activeDungeon)

		return
	end

	local dungeon = self._activeDungeon
	local nextRoom = dungeon and dungeon.rooms[lastChunk.id + 1]

	task.delay(0.5, function()
		for _, player in pairs(Players:GetPlayers()) do
			UserNotificationService:RequestUserNotification(player, {
				titleText = "Chamber Cleared",
				titleTextFont = Enum.Font.SourceSansBold,
				titleTextColor3 = Color3.fromRGB(85, 255, 127),
				titleTextTransparency = 0,

				text = "Enemies defeated, choose a relic!",
				textFont = Enum.Font.SourceSansBold,
				textColor3 = Color3.fromRGB(255, 255, 255),
				textTransparency = 0,
			})
		end
	end)

	if nextRoom and (nextRoom.roomType == RoomTypes.Miniboss or nextRoom.roomType == RoomTypes.Boss) then
		local isBoss = nextRoom.roomType == RoomTypes.Boss
		local indicatorText = isBoss and "Boss Chamber" or "Miniboss Chamber"
		local indicatorSubtext = isBoss and "Boss Chamber found, get ready!" or "Miniboss Chamber found, get ready!"

		task.delay(0.75, function()
			for _, player in pairs(Players:GetPlayers()) do
				UserNotificationService:RequestUserNotification(player, {
					titleText = indicatorText,
					titleTextFont = Enum.Font.SourceSansBold,
					titleTextColor3 = Color3.fromRGB(170, 85, 255),
					titleTextTransparency = 0,

					text = indicatorSubtext,
					textFont = Enum.Font.SourceSansBold,
					textColor3 = Color3.fromRGB(255, 255, 255),
					textTransparency = 0,
				})
			end
		end)

		local gate = lastChunk.model:FindFirstChild(EXIT_GATE_NAME)
		local gateCFrame = (gate and gate:IsA("BasePart") and gate.CFrame) or lastChunk.model:GetPivot()
		if EncounterService then
			EncounterService:StartEncounter(nextRoom.roomType, nextRoom, gateCFrame)
		end
		self.Signals.OnSegmentCleared:Fire(self._activeDungeon, lastChunk)
		return
	end

	if not skipDungeonDoneEffect then
		task.delay(0.5, function()
			print("SEGMENT_IUD: " .. segmentId)
			self:_emitDungeonDoneEffect(lastChunk.model)
		end)
	end

	if nextRoom and (nextRoom.roomType == RoomTypes.Combat or nextRoom.roomType == RoomTypes.Event) then
		-- Combat→Combat and Combat→Event both run the Dungeon Gate cycle
		-- (players still need their relic-shopping countdown before an
		-- event room — the door must NOT just swing open).
		-- Combat→Combat: the Dungeon Gate cycle (countdown while players
		-- shop, then a per-player one-way opening). Spawned so the cycle's
		-- countdown/crossing loops don't delay OnSegmentCleared — the
		-- vending machines drop off that signal.
		task.spawn(function()
			self:_startGateCycle(lastChunk, lastChunk.id + 1, countdownOverride)
		end)
	else
		-- No mainline Combat room next (end of plan edge) — fall back to
		-- the plain touch-trigger open.
		self:_setupGateTrigger(lastChunk.model, lastChunk.id + 1, false)
	end
	self.Signals.OnSegmentCleared:Fire(self._activeDungeon, lastChunk)
end

-- The APPROACH gate (the cleared room's ExitGate in front of a miniboss /
-- boss arena) never opens: the encounter intro teleports the party past it
-- and it stays solid. Stamp it "passed" so gate dressing that keys off
-- GateState (the ExitGateParticlePart rig) can fade out -- OpenSegmentGate
-- never gives it the "open" stamp. Called on OnEncounterIntroStarted, while
-- the party is still standing on the pad in front of it.
function DungeonService:_markApproachGatePassed(arenaRoom)
	local dungeon = self._activeDungeon
	if not dungeon or not arenaRoom or not arenaRoom.id then
		return
	end
	local previous = dungeon.rooms[arenaRoom.id - 1]
	local gate = previous and previous.model and previous.model:FindFirstChild(EXIT_GATE_NAME)
	if gate and gate:IsA("BasePart") and gate:GetAttribute("GateState") == nil then
		gate:SetAttribute("GateState", "passed")
	end
end

function DungeonService:_teleportPlayerToStart(dungeon, player): CFrame?
	local marker = self:_findAnchor(dungeon.startModel, START_SPAWN_NAME, true)
	local spawnCFrame
	if marker then
		spawnCFrame = self:_anchorCFrame(marker) :: CFrame
	else
		-- Loud, not silent: "landed somewhere near the start" looked like a
		-- random teleport failure from the outside.
		warn(
			("[DungeonService] %s has no %q marker -- landing at its pivot + %s instead"):format(
				dungeon.startModel.Name,
				START_SPAWN_NAME,
				tostring(START_SPAWN_FALLBACK_OFFSET)
			)
		)
		spawnCFrame = dungeon.startModel:GetPivot() * CFrame.new(START_SPAWN_FALLBACK_OFFSET)
	end

	local targetCFrame = spawnCFrame * CFrame.Angles(0, math.rad(180), 0)

	-- Fan the party out sideways (in the start CFrame's own right axis) so
	-- nobody lands inside anyone else: slot i of n sits at
	-- (i - (n+1)/2) x LANDING_SPREAD_STUDS.
	local players = Players:GetPlayers()
	local slot = table.find(players, player) or 1
	local lateral = (slot - (#players + 1) / 2) * LANDING_SPREAD_STUDS
	targetCFrame = targetCFrame * CFrame.new(lateral, 0, 0)

	local character = player.Character
	if not character then
		return
	end

	-- Set the HumanoidRootPart CFrame DIRECTLY rather than character:PivotTo.
	-- PivotTo moves the model so its *pivot* lands on the target, and when the
	-- character has no PrimaryPart the pivot is the bounding-box CENTER. During
	-- the landing the animation lifts the visible body +25 studs, which shifts
	-- that bounding box way up — so PivotTo(ground) would drop the HRP ~12 studs
	-- BELOW the floor (the fall-through). The HRP's own CFrame is unaffected by
	-- the animation, so setting it directly lands the root exactly on the ground
	-- and the rig's Motor6Ds keep the body at its animated +25 offset.
	-- Reparent FIRST so the CFrame write is the last thing to touch the root.
	character.Parent = workspace.Players

	local hrp = character:FindFirstChild("HumanoidRootPart")
	if hrp then
		hrp.AssemblyLinearVelocity = Vector3.zero
		hrp.CFrame = targetCFrame
	else
		character:PivotTo(targetCFrame)
	end
	return targetCFrame
end

-- Re-asserts the landing spot for `seconds` after the teleport (the pose
-- hold + the fall). The teleport is a server CFrame write on a root the
-- CLIENT owns; a client-side root write in the same window (a dash, a dodge,
-- mobile aim -- all gated client-side now, this is the safety net) would
-- otherwise win. Horizontal only: the humanoid settles vertically onto the
-- floor by itself and must not be fought.
function DungeonService:_holdLandingPosition(
	character: Model,
	hrp: BasePart,
	targetCFrame: CFrame,
	dungeon,
	seconds: number
)
	task.spawn(function()
		local deadline = os.clock() + seconds
		while os.clock() < deadline do
			RunService.Heartbeat:Wait()
			if not character.Parent or not hrp.Parent or self._activeDungeon ~= dungeon then
				return
			end
			local offset = hrp.Position - targetCFrame.Position
			if Vector3.new(offset.X, 0, offset.Z).Magnitude > LANDING_HOLD_TOLERANCE_STUDS then
				hrp.AssemblyLinearVelocity = Vector3.zero
				hrp.CFrame = targetCFrame
			end
		end
	end)
end

--[ Join landing ]--

function DungeonService:_runPlayerLanding(player: Player)
	local dungeon = self._activeDungeon
	if not dungeon then
		return
	end
	-- Keyed by dungeon, not a bare flag: a ready cue arriving between
	-- _activeDungeon being set and OnDungeonGenerated firing used to land
	-- the player TWICE (the generated handler cleared the flag and re-ran
	-- this for every ready player) -- two tracks, two teleports, and an
	-- early OnLandingEnd that unlocked controls mid-fall.
	if self._landed[player] == dungeon then
		return
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not character or not humanoid or not hrp then
		return
	end
	-- Run loop: players who extracted through a portal are gone; players who
	-- are DEAD at the transition stay dead (they spectate the next dungeon
	-- until a revive) -- neither lands.
	if self:IsPlayerExited(player) then
		return
	end
	if humanoid.Health <= 0 or character:GetAttribute(Attributes.Death) == true then
		return
	end

	self._landed[player] = dungeon

	-- Mark the character as mid-fall for EVERY client (see
	-- Attributes.Landing). Set before the pose so nothing has a window to
	-- draw this character's billboards / particles at the staging area,
	-- and cleared on the landing beat below.
	character:SetAttribute(Attributes.Landing, true)

	local animator = humanoid:FindFirstChildOfClass("Animator")
	local animationsFolder = ReplicatedStorage.GameAssets:FindFirstChild("Animations")
	local landAnimation = animationsFolder and animationsFolder:FindFirstChild("LandingAnimation")
	local landAnimationTrack = animator and landAnimation and animator:LoadAnimation(landAnimation)

	-- Top priority so the landing pose fully OVERRIDES whatever else is on
	-- the Animator (default fall/idle, the weapon idle the owner's client
	-- already started) instead of stopping it. This used to blanket-Stop
	-- every playing track first -- a server-authoritative stop that killed
	-- the client-played WEAPON IDLE on every screen, including the owner's,
	-- with nothing left to restart it once the landing ended (players stood
	-- in the default pose until they re-equipped). Priority override gives
	-- the same clean +25 pose (a higher-priority track at weight 1 hides the
	-- lower ones completely) and the idle simply resumes underneath when
	-- the landing finishes. Same approach LifeService uses for the death pose.
	if landAnimationTrack then
		landAnimationTrack.Priority = Enum.AnimationPriority.Action4

		-- PRIME. A server-side Play is what makes each client fetch the
		-- animation ASSET; until it arrives a client renders the default
		-- pose. A zero-length play-then-stop here, before the start delay,
		-- hands every client the whole delay to download it, so the real
		-- freeze below lands on an asset that is already resident.
		landAnimationTrack:Play(0, 1, 1)
		landAnimationTrack:Stop(0)
	end

	task.spawn(function()
		-- Brief hold so armor / weapons / appearance finish welding before we
		-- pose the character (otherwise they pop in mid-landing).
		-- Transition landings skip the join-time welding delay (screen is black
		-- and gear is already welded); a short beat is enough for the pose.
		local isTransitionLanding = self:GetRunDungeonIndex() > 1
		task.wait(if isTransitionLanding then RUN_TRANSITION_PRE_TELEPORT_SECONDS else LANDING_START_DELAY)
		if not character.Parent or not hrp.Parent then
			self._landed[player] = nil -- character gone; let a new one land
			return
		end

		-- Pose the character into the animation's first frame (+25 studs up) WHILE
		-- STILL AT STAGING — off-map, so no other player sees it, and the joiner's
		-- own view is behind the loading screen. Frozen (speed 0), no fade-in, so
		-- there's no default→+25 transition to snap through.
		if landAnimationTrack then
			landAnimationTrack:Play(0, 1, 0)
		end

		-- Let that frozen pose apply + replicate to EVERY client before we move
		-- into view, so nobody ever sees the default pose at the dungeon start.
		task.wait(LANDING_POSE_SETTLE)
		if not character.Parent or not hrp.Parent then
			self._landed[player] = nil
			return
		end

		-- Teleport in. The character arrives already in the +25 pose (no snap).
		-- _teleportPlayerToStart sets the HRP CFrame directly (NOT PivotTo, which
		-- would mis-place the root while the +25 animation is playing), and the
		-- HRP is anchored, so it lands exactly on the ground and can't fall.
		local targetCFrame = self:_teleportPlayerToStart(dungeon, player)
		self:_releaseTransitionFreeze(player)
		if targetCFrame then
			local holdSeconds = LANDING_POSE_HOLD_SECONDS + LANDING_DURATION
			if isTransitionLanding then
				holdSeconds += RUN_TRANSITION_REVEAL_HOLD_SECONDS
			end
			self:_holdLandingPosition(character, hrp, targetCFrame, dungeon, holdSeconds)
		end

		-- HOLD the frozen first frame in place. The screen is still dark, so
		-- this is invisible to the player — it exists purely so the pose
		-- has replicated and rendered on every client before anyone can see
		-- it. Only then does the reveal come, and the drop with it.
		task.wait(LANDING_POSE_HOLD_SECONDS)
		if not character.Parent or not hrp.Parent or self._activeDungeon ~= dungeon then
			if character.Parent then
				character:SetAttribute(Attributes.Landing, nil)
			end
			if not character.Parent or not hrp.Parent then
				self._landed[player] = nil
			end
			return
		end

		-- Transition: sit on the new start room, still black, for a beat so
		-- the teleport has replicated everywhere BEFORE the reveal.
		if isTransitionLanding then
			task.wait(RUN_TRANSITION_REVEAL_HOLD_SECONDS)
			if not character.Parent or self._activeDungeon ~= dungeon then
				-- Floor swapped out from under the landing: un-mark, or this
				-- character stays invisible-attachment forever.
				if character.Parent then
					character:SetAttribute(Attributes.Landing, nil)
				end
				return
			end
		end

		-- Reveal: fade the joiner's loading screen (or the transition black)
		-- + lock controls. Carries the landing CFrame: the client OWNS its
		-- root, so its own snap to it is the authoritative one.
		self.Client.OnLandingStart:Fire(player, targetCFrame)

		-- Drop: resume the animation from the frozen +25 pose down to the ground.
		if landAnimationTrack then
			landAnimationTrack:AdjustSpeed(LANDING_DROP_SPEED)
		end

		-- Impact beat — broadcast so any client can play the landing VFX at the
		-- landing player's position. _onLandingImpact is a server-side seam.
		task.delay(LANDING_IMPACT_DELAY, function()
			if not character.Parent then
				return
			end
			self:_onLandingImpact(player)
			self.Client.OnLandingImpact:FireAll(player)
		end)

		-- End — unanchor + restore controls, then drop the relic machine.
		task.delay(LANDING_DURATION, function()
			-- Touched down: attachments may draw again (the clients fade
			-- them in off this edge).
			if character.Parent then
				character:SetAttribute(Attributes.Landing, nil)
			end
			self.Client.OnLandingEnd:Fire(player)
			-- Server-side twin of OnLandingEnd, for services that need the
			-- player's settled position rather than a client cue.
			self.Signals.OnPlayerLanded:Fire(player)

			-- The free "starter" vending machine drops ONLY on the run's FIRST
			-- dungeon (Hades-style: one free pick when the run begins). Landing
			-- in dungeon 2 / 3 after a boss gets no machine -- the boss's own
			-- rewards were the payoff.
			if isTransitionLanding then
				return
			end
			task.delay(2.5, function()
				if RelicMachineService then
					-- STARTER machine: forces one ungated relic from each of
					-- the run's two elements (see RelicMachine).
					RelicMachineService:DropMachineOnPlayer(player, false, true)
				end
			end)
		end)
	end)
end

function DungeonService:_onLandingImpact(player: Player)
	local root = player.Character.HumanoidRootPart

	local dodgeVFX = ReplicatedStorage.GameAssets.VFX.Dodge.Dodge:Clone()
	dodgeVFX:PivotTo(CFrame.new(root.Position) - Vector3.new(0, 3, 0))
	dodgeVFX.Parent = workspace.IgnoreInstances.MagicSpells

	for _, particle in dodgeVFX.Part.Attachment:GetChildren() do
		if particle:IsA("ParticleEmitter") then
			particle:Emit(20)
		end
	end

	dodgeVFX.Part.Landing:Play()

	Debris:AddItem(dodgeVFX, 5)
end

-- Marks a player ready (their client finished preloading) and lands them if a
-- dungeon already exists. If not (they joined during the auto-gen window) they
-- stay queued and OnDungeonGenerated lands every ready player.
function DungeonService:_markReadyAndMaybeLand(player: Player)
	self._readyForLanding[player] = true
	if self._activeDungeon then
		self:_runPlayerLanding(player)
	end
end

--[ Next-gate marker ]--

function DungeonService:_getNextGate(): BasePart?
	local dungeon = self._activeDungeon
	if not dungeon then
		return nil
	end

	-- All players share the cursor mechanically. Read from any one player;
	-- defaults to 0 (Start) if no players are tracked yet.
	local players = Players:GetPlayers()
	local cursor = 0
	if players[1] then
		cursor = self._playerRoomCursor[players[1]] or 0
	end

	if cursor == 0 then
		local startModel = dungeon.startModel
		if startModel then
			local gate = startModel:FindFirstChild(EXIT_GATE_NAME)
			if gate and gate:IsA("BasePart") then
				return gate
			end
		end
		return nil
	end

	local room = dungeon.rooms[cursor]
	if not room or not room.model then
		return nil
	end
	local gate = room.model:FindFirstChild(EXIT_GATE_NAME)
	if gate and gate:IsA("BasePart") then
		return gate
	end
	return nil
end

-- Lazily creates the next-gate marker model (an invisible Part with an
-- "Indicator" Attachment) under workspace.IgnoreInstances.MapMarkers so the
-- LocationMarkerSystem picks it up.
function DungeonService:_ensureNextGateMarker(): Model
	if self._nextGateMarker and self._nextGateMarker.Parent then
		return self._nextGateMarker
	end

	local mapMarkers = workspace.IgnoreInstances:FindFirstChild("MapMarkers")
	assert(mapMarkers, "[DungeonService] workspace.IgnoreInstances.MapMarkers is missing")

	local model = Instance.new("Model")
	model.Name = NEXT_GATE_MARKER_NAME

	local primary = Instance.new("Part")
	primary.Name = "Marker"
	primary.Size = Vector3.new(1, 1, 1)
	primary.Transparency = 1
	primary.Anchored = true
	primary.CanCollide = false
	primary.CanQuery = false
	primary.CanTouch = false
	primary.Parent = model
	model.PrimaryPart = primary

	local attachment = Instance.new("Attachment")
	attachment.Name = "Indicator"
	attachment:SetAttribute("Image", NEXT_GATE_MARKER_IMAGE)
	attachment:SetAttribute("Color", NEXT_GATE_MARKER_COLOR)
	attachment:SetAttribute("Enabled", true)
	attachment:SetAttribute("IndicatorSize", NEXT_GATE_MARKER_SIZE)
	attachment.Parent = primary

	model.Parent = mapMarkers
	self._nextGateMarker = model
	return model
end

-- Snaps the marker to the next gate, or destroys it if there is no next gate.
-- Safe to call from anywhere — idempotent and self-creating.
function DungeonService:_updateNextGateMarker()
	local gate = self:_getNextGate()
	if not gate then
		self:_destroyNextGateMarker()
		return
	end

	local marker = self:_ensureNextGateMarker()

	marker.PrimaryPart.Position = (gate.Position + gate.CFrame.LookVector) + Vector3.new(0, -2, 0)
end

function DungeonService:_destroyNextGateMarker()
	if self._nextGateMarker then
		self._nextGateMarker:Destroy()
		self._nextGateMarker = nil
	end
end

function DungeonService:_emitDungeonDoneEffect(roomModel: Model?, colorOverride: Color3?)
	if not roomModel then
		return
	end
	local exitGate = roomModel:FindFirstChild(EXIT_GATE_NAME)
	if not exitGate then
		return
	end

	local dungeonDone = exitGate:FindFirstChild("DungeonDone")

	if dungeonDone then
		if colorOverride then
			local sequence = ColorSequence.new(colorOverride)
			for _, particle in dungeonDone:GetChildren() do
				if particle:IsA("ParticleEmitter") then
					particle.Color = sequence
				end
			end
		end
		task.spawn(function()
			for _ = 1, 3, 1 do
				for _, particle in dungeonDone:GetChildren() do
					if particle:IsA("ParticleEmitter") then
						particle:Emit(DUNGEON_DONE_EMIT_STRENGTH)
					end
				end
				task.wait(0.1)
			end
		end)
	else
		warn(
			("[DungeonService] %s has no ExitGate.DungeonDone child — segment-clear particle skipped."):format(
				roomModel.Name
			)
		)
	end

	local unlock = exitGate:FindFirstChild("Unlock")
	if unlock and unlock:IsA("Sound") then
		unlock:Play()
	end
end

--[ Public Functions ]--

function DungeonService:GenerateDungeon(dungeonId: string, difficulty: string, seed: number?, originCFrame: CFrame?)
	seed = seed or (os.time() + math.random(1, 1_000_000))
	originCFrame = originCFrame or CFrame.new(0, 0, 0)

	local dungeonConfig = DungeonData[dungeonId]
	assert(dungeonConfig, "[DungeonService] Unknown dungeon: " .. tostring(dungeonId))

	self._generatingDungeonId = dungeonId
	-- The zombie pool is per dungeon (its GameAssets.Zombies folder).
	if ZombieSpawnService then
		ZombieSpawnService:BuildZombiePlanForDungeon(dungeonId)
	end

	-- First floor of the run: the guaranteed shop may only land AFTER the
	-- Miniboss — players start coin-less, so an early shop sells to nobody.
	-- Later floors (and no-run Studio generates read index 1 too, matching
	-- the real game-start experience) roll it anywhere.
	local plan = Planner.plan(dungeonId, difficulty, seed, self:GetRunDungeonIndex() <= 1)
	local rng = Random.new(seed)
	local runtimeFolder = self:_ensureRuntimeFolder()

	-- Place start room
	local prefabRoot = self:_getPrefabRoot()
	assert(prefabRoot, "[DungeonService] Missing ServerStorage.GameAssets." .. PREFAB_FOLDER_NAME)
	local startPrefab = prefabRoot:FindFirstChild(dungeonConfig.startPrefabName)
	assert(startPrefab, "[DungeonService] Missing start prefab: " .. dungeonConfig.startPrefabName)

	local startModel = startPrefab:Clone()
	startModel:PivotTo(originCFrame)
	startModel.Name = "Start"
	startModel.Parent = runtimeFolder

	for _, wall in startModel:GetChildren() do
		if wall:IsA("BasePart") and wall.Name == "Wall" then
			wall.Parent = WALLS_PARENT_FOLDER
		end
	end

	local roomsList = {}
	local roomsById = {}
	local startExitAnchor = self:_findAnchor(startModel, EXIT_ANCHOR_NAME)
	assert(startExitAnchor, "[DungeonService] Start prefab missing BasePart/Attachment named " .. EXIT_ANCHOR_NAME)

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
		local prevExitAnchor
		if slotIdx == 1 then
			prevExitAnchor = startExitAnchor
		else
			prevExitAnchor = self:_findAnchor(slots[slotIdx - 1].model :: Model, EXIT_ANCHOR_NAME, true)
		end
		if not prevExitAnchor then
			warn(
				("[DungeonService] Slot %d (%s) cannot place: previous room has no ExitAnchor"):format(
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
			local prefab
			if forcedPrefabName then
				local forced = self:_findPrefabByName(node.prefabPool, forcedPrefabName)
				if forced and not slot.tried[forced] then
					prefab = forced
				elseif not forced then
					warn(
						(
							"[DungeonService] Forced prefab '%s' not found in pool '%s' "
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
				or self:_pickPrefab(node.prefabPool, rng)
			slot.model = self:_snapPrefab(fp, ENTRY_ANCHOR_NAME, exitAnchorCFrame, runtimeFolder)
			slot.prefabName = fp.Name
			slot.floors = self:_getRoomFloors(slot.model :: Model)
			for _, f in slot.floors do
				table.insert(placedFloors, f)
			end
			warn(
				("[DungeonService] Max backtracks (%d) hit at slot %d (%s); force-placed."):format(
					MAX_BACKTRACKS,
					slotIdx,
					node.roomType
				)
			)
			slotIdx += 1
		elseif slotIdx == 1 then
			warn(
				("[DungeonService] Cannot place first room (%s) — no Combat/Shrine variant fits start room's exit"):format(
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

			if slot.branchModel:FindFirstChild(ENTRY_ANCHOR_NAME) then
				slot.branchModel:FindFirstChild(ENTRY_ANCHOR_NAME):Destroy()
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

		if slot.model:FindFirstChild(ENTRY_ANCHOR_NAME) then
			slot.model:FindFirstChild(ENTRY_ANCHOR_NAME):Destroy()
		end

		if slot.model:FindFirstChild(EXIT_ANCHOR_NAME) then
			slot.model:FindFirstChild(EXIT_ANCHOR_NAME):Destroy()
		end

		if slot.model:FindFirstChild(BRANCH_ANCHOR_NAME) then
			slot.model:FindFirstChild(BRANCH_ANCHOR_NAME):Destroy()
		end

		-- Inner chunks' ExitGates serve as touch-triggers: when a player touches
		-- one, the gate is destroyed, zombies spawn in the next chunk, and every
		-- player's cursor advances. Last-chunk ExitGates are left alone for the
		-- external encounter system to lock/unlock manually.
		if not room.isLastChunk then
			self:_setupGateTrigger(room.model, room.id + 1)
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

	if startModel:FindFirstChild(EXIT_ANCHOR_NAME) then
		startModel:FindFirstChild(EXIT_ANCHOR_NAME):Destroy()
	end

	-- Start room's ExitGate is also a touch trigger: walking out of Start
	-- spawns the first room's zombies and advances every player to room 1.
	self:_setupGateTrigger(startModel, 1)

	print(
		("[DungeonService] Generated %s/%s with %d rooms (seed %d, %d backtracks, %d forced)"):format(
			dungeonId,
			difficulty,
			#roomsList,
			seed,
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
	-- therefore the same zombie queue. A 3-chunk segment is three fights of
	-- equal size, not a ramp within itself. ZombieSpawnService's queue
	-- formula scales off this, so deeper SEGMENTS field bigger queues.
	--
	-- Relies on a segment's chunks being contiguous in roomsList, which the
	-- Planner guarantees (it emits chunkCount rooms per sequence entry before
	-- moving on). Non-Combat rooms between chunks are skipped without
	-- disturbing the run, since lastSegmentId only updates inside the branch.
	local combatSegmentOrdinal = 0
	local lastCombatSegmentId = nil
	for _, room in roomsList do
		if room.roomType == RoomTypes.Combat then
			if room.segmentId ~= lastCombatSegmentId then
				combatSegmentOrdinal += 1
				lastCombatSegmentId = room.segmentId
			end
			room.combatSegmentIndex = combatSegmentOrdinal
		end
	end

	local dungeon = {
		id = dungeonId,
		difficulty = difficulty,
		seed = seed,
		plan = plan,
		startModel = startModel,
		rooms = roomsList,
		roomsById = roomsById,
	}
	-- Boss rooms: sink the authored ExitPortal out of sight until the boss
	-- falls (see _prepareExitPortal / _raiseExitPortal).
	for _, room in roomsList do
		if room.roomType == RoomTypes.Boss then
			self:_prepareExitPortal(room)
		end
	end

	self._activeDungeon = dungeon

	self:ResetPlayerCursors()
	table.clear(self._openedSegments)

	-- Tear down any active encounter / lobby (e.g. dungeon was regenerated
	-- mid-countdown) so the pad and HUD don't outlive the old run.
	if EncounterService then
		EncounterService:CleanupAll()
	end

	-- Stale marker from the previous run, if any, then place a fresh one on
	-- the first gate (Start room's ExitGate).
	self:_destroyNextGateMarker()
	self:_updateNextGateMarker()

	-- Wait (BOUNDED) for characterless players. Unbounded, a mid-run
	-- regeneration would block forever on someone stuck respawning.
	for _, player in pairs(Players:GetPlayers()) do
		if not player.Character then
			local waited = 0
			while not player.Character and player.Parent and waited < GENERATE_CHARACTER_WAIT_SECONDS do
				waited += task.wait(0.1)
			end
		end
	end

	self._generatingDungeonId = nil
	self.Signals.OnDungeonGenerated:Fire(dungeon)

	return dungeon
end

--[ Run loop ]--

function DungeonService:GetRun()
	return self._run
end

function DungeonService:GetRunDungeonIndex(): number
	return self._run and self._run.index or 1
end

function DungeonService:IsFinalDungeon(): boolean
	local run = self._run
	return run ~= nil and run.index >= #run.sequence
end

function DungeonService:IsPlayerExited(player: Player): boolean
	local run = self._run
	return run ~= nil and run.exited[player] == true
end

-- Starts a fresh RUN at DungeonSequence[1] with `difficulty` for every
-- dungeon in it. The de-facto game start; called by the auto-generate below.
function DungeonService:StartRun(difficulty: string, originCFrame: CFrame?)
	local sequence = table.clone(DungeonSequence)
	assert(#sequence > 0, "[DungeonService] DungeonSequence is empty")
	self._run = {
		sequence = sequence,
		index = 1,
		difficulty = difficulty,
		exited = {},
		originCFrame = originCFrame,
	}
	self.Signals.OnRunStarted:Fire(self._run)
	return self:GenerateDungeon(sequence[1], difficulty, nil, originCFrame)
end

-- Destroys everything the current dungeon put in the world so the next one
-- can generate into a clean map. Order matters: encounters / lobbies first
-- (their pads + HUD), zombies + queues (room-id-keyed state MUST go before
-- new rooms take those ids), machines, markers, then the room models --
-- Walls live in a shared, cached folder, so its CHILDREN are cleared and
-- the folder itself kept.
function DungeonService:_teardownDungeon()
	local dungeon = self._activeDungeon
	self._activeDungeon = nil -- staleness token for every in-flight thread

	self:_destroyExitPortal()
	self:_destroyNextGateMarker()
	if EncounterService then
		EncounterService:CleanupAll()
	end
	if ZombieSpawnService then
		ZombieSpawnService:ResetForNewDungeon()
	end

	local map = workspace.IgnoreInstances:FindFirstChild("Map")
	local machines = map and map:FindFirstChild("RelicMachines")
	if machines then
		for _, machine in machines:GetChildren() do
			machine:Destroy()
		end
	end
	local markers = workspace.IgnoreInstances:FindFirstChild("MapMarkers")
	if markers then
		for _, marker in markers:GetChildren() do
			marker:Destroy()
		end
	end

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

	table.clear(self._openedSegments)
	table.clear(self._landed)
	table.clear(self._playerRoomCursor)

	return dungeon
end

-- Vote passed (or nobody left to vote against it): fade everyone to black,
-- swap the map, land everyone alive in the next dungeon. Idempotent while a
-- transition is already running.
function DungeonService:AdvanceRun()
	local run = self._run
	if not run or self._transitioning then
		return
	end
	if run.index >= #run.sequence then
		return -- final dungeon: nothing to advance to
	end
	self._transitioning = true

	local fromDungeon = self._activeDungeon
	local nextId = run.sequence[run.index + 1]
	self.Signals.OnRunAdvancing:Fire(fromDungeon, nextId)

	task.spawn(function()
		self.Client.OnRunTransition:FireAll({ phase = "in", duration = RUN_TRANSITION_FADE_SECONDS })
		task.wait(RUN_TRANSITION_FADE_SECONDS + RUN_TRANSITION_BLACK_HOLD_SECONDS)

		-- The floor is about to vanish under everyone: freeze alive players in
		-- place (released when their landing teleports them onto the new start).
		table.clear(self._transitionFrozen)
		for _, player in Players:GetPlayers() do
			local character = player.Character
			local hrp = character and character:FindFirstChild("HumanoidRootPart")
			if hrp and not hrp.Anchored then
				hrp.Anchored = true
				self._transitionFrozen[player] = true
			end
		end

		self:_teardownDungeon()
		run.index += 1

		local ok, err = pcall(function()
			self:GenerateDungeon(nextId, run.difficulty, nil, run.originCFrame)
		end)
		if not ok then
			warn("[DungeonService] Next-dungeon generation failed: " .. tostring(err))
		end
		-- Alive players: the landing sequence (OnDungeonGenerated ->
		-- _runPlayerLanding -> OnLandingStart) fades their screen back in.
		-- Players who WON'T land (dead -> keep spectating; extracted) get an
		-- explicit release, or they'd sit on black forever.
		for _, player in Players:GetPlayers() do
			local character = player.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			local dead = not humanoid
				or humanoid.Health <= 0
				or (character and character:GetAttribute(Attributes.Death) == true)
			if dead or self:IsPlayerExited(player) then
				self:_releaseTransitionFreeze(player)
				self.Client.OnRunTransition:Fire(player, { phase = "out", duration = RUN_TRANSITION_FADE_SECONDS })
			end
		end
		self._transitioning = false
	end)
end

function DungeonService:_releaseTransitionFreeze(player: Player)
	if not self._transitionFrozen[player] then
		return
	end
	self._transitionFrozen[player] = nil
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if hrp then
		hrp.Anchored = false
	end
end

--[ Exit portal ]--

-- At generation: find the Boss prefab's authored (underground) ExitPortal,
-- anchor it, and record its resting pivot + Y extent so the raise can rise
-- it by exactly its own height. Missing model = warn once; the room simply
-- has no portal (the vote still runs, players can still descend).
function DungeonService:_prepareExitPortal(room)
	local portal = room.model and room.model:FindFirstChild(EXIT_PORTAL_MODEL_NAME)
	if not portal or not portal:IsA("Model") then
		warn(
			("[DungeonService] Boss room %s has no '%s' model -- no exit portal"):format(
				tostring(room.model and room.model.Name),
				EXIT_PORTAL_MODEL_NAME
			)
		)
		return
	end
	local authored = portal:GetPivot()
	local riseHeight = portal:GetExtentsSize().Y
	-- Everything about the portal must be static for the sink / rise to
	-- hold (an unanchored part would just fall away from the pivot).
	for _, part in portal:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = true
		end
	end
	-- The authored pose lives ON THE MODEL (attribute), so the raise can
	-- re-find both model and target from the room instance alone -- no
	-- dependence on which room TABLE reaches it later.
	portal:SetAttribute("ExitPortalRestCFrame", authored)
	portal:SetAttribute("ExitPortalRiseHeight", riseHeight)
	-- The prompt is the ONLY way to use the portal; it stays off while the
	-- portal is buried and is enabled once the rise finishes.
	local prompt = portal:FindFirstChildWhichIsA("ProximityPrompt", true)
	if prompt then
		prompt.Enabled = false
	else
		warn(
			("[DungeonService] Boss room %s: ExitPortal has no ProximityPrompt -- it will be unusable"):format(
				tostring(room.model.Name)
			)
		)
	end
	room.exitPortal = portal
end

function DungeonService:_destroyExitPortal()
	-- The portal belongs to its Boss room model and dies with the room on
	-- teardown; this only drops the rise-loop token.
	self._exitPortal = nil
end

-- Boss down: raise the room's buried ExitPortal by its own height
-- (MediumLong shake for everyone within EXIT_PORTAL_SHAKE_RADIUS), then
-- enable its ProximityPrompt. Triggering the prompt (a deliberate
-- interaction -- never a touch) fires OnPlayerExtracted (bank escrow in that
-- hook) and sends that player to the lobby place; they drop out of the
-- vote's required count.
function DungeonService:_raiseExitPortal(room)
	-- Re-resolve from the room MODEL: robust to the room table reaching us
	-- through EncounterService being a different reference than the one
	-- _prepareExitPortal annotated.
	local portal: Model? = room and room.model and room.model:FindFirstChild(EXIT_PORTAL_MODEL_NAME)
	if not portal or not portal:IsA("Model") or not portal.Parent then
		warn("[DungeonService] _raiseExitPortal: boss room has no ExitPortal model")
		return
	end
	-- Rise by the model's own Y extent from its authored (underground) rest
	-- pose. Prepared rooms have both stored; anything else measures now.
	local restCFrame: CFrame? = portal:GetAttribute("ExitPortalRestCFrame")
	local riseHeight: number? = portal:GetAttribute("ExitPortalRiseHeight")
	if typeof(restCFrame) ~= "CFrame" then
		restCFrame = portal:GetPivot()
	end
	if typeof(riseHeight) ~= "number" then
		riseHeight = portal:GetExtentsSize().Y
	end
	local targetCFrame = restCFrame + Vector3.new(0, riseHeight, 0)
	self._exitPortal = portal
	-- Every client plays the gate-open sound on the portal locally.
	self.Client.OnExitPortalRising:FireAll(portal)
	-- Server-side twin: MusicService fades in the extraction theme.
	self.Signals.OnExitPortalRising:Fire(portal)

	if CameraShakeService then
		local origin = targetCFrame.Position
		for _, player in Players:GetPlayers() do
			local character = player.Character
			local hrp = character and character:FindFirstChild("HumanoidRootPart")
			if hrp and (hrp.Position - origin).Magnitude <= EXIT_PORTAL_SHAKE_RADIUS then
				CameraShakeService:Shake(player, CameraShakePresets.MediumLong)
			end
		end
	end

	-- Interaction: the portal's ProximityPrompt (authored on the model).
	-- Enabled only once the rise completes.
	local prompt = portal:FindFirstChildWhichIsA("ProximityPrompt", true)
	if prompt then
		prompt.Enabled = false
		prompt.Triggered:Connect(function(player: Player)
			self:_extractPlayer(player)
		end)
	end

	-- Rise: drive the pivot per frame (models can't be tweened directly),
	-- then enable the prompt.
	task.spawn(function()
		local startCFrame = portal:GetPivot()
		local startedAt = os.clock()
		while portal.Parent and self._exitPortal == portal do
			local t = math.clamp((os.clock() - startedAt) / EXIT_PORTAL_RISE_SECONDS, 0, 1)
			-- Sine InOut: eases both out of the ground and into rest -- no
			-- snap at either end.
			local alpha = TweenService:GetValue(t, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
			portal:PivotTo(startCFrame:Lerp(targetCFrame, alpha))
			if t >= 1 then
				break
			end
			task.wait()
		end
		if prompt and prompt.Parent then
			prompt.Enabled = true
		end
	end)
end

function DungeonService:_extractPlayer(player: Player)
	local run = self._run
	if not run or run.exited[player] then
		return
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 or character:GetAttribute(Attributes.Death) == true then
		return
	end
	-- Bank / record hook FIRST, then the teleport (the player is still fully
	-- present with their escrow when listeners run).
	self.Signals.OnPlayerExtracted:Fire(player, self._activeDungeon)

	-- Only a player who is ACTUALLY leaving counts as exited. If the teleport
	-- can't be issued (Studio; a place-teleport failure) they're still here --
	-- leaving them flagged would drop them from the vote AND the next
	-- landing, stranding them on the torn-down map.
	local leaving = LifeService ~= nil and LifeService:TeleportPlayerToLobby(player) == true
	if leaving then
		run.exited[player] = true
	else
		warn(
			("[DungeonService] %s touched the ExitPortal but could not be teleported -- staying in the run"):format(
				player.Name
			)
		)
	end
end

-- Boss rewards have dropped (EncounterService outro done). Final dungeon:
-- fire the hook, spawn nothing. Otherwise: portal + vote pad after a beat.
function DungeonService:_onBossRewardsDropped(room)
	local run = self._run
	local dungeon = self._activeDungeon
	if not run or not dungeon or not room or not room.model then
		return
	end

	if self:IsFinalDungeon() then
		self.Signals.OnFinalDungeonCompleted:Fire(dungeon, run)
		return
	end

	task.delay(EXIT_PORTAL_DELAY, function()
		if self._activeDungeon ~= dungeon then
			return
		end
		self:_raiseExitPortal(room)

		if EncounterService then
			local gate = room.model:FindFirstChild(EXIT_GATE_NAME)
			local gateCFrame = (gate and gate:IsA("BasePart") and gate.CFrame) or room.model:GetPivot()
			EncounterService:StartNextDungeonVote(room, gateCFrame)
		end
	end)
end

function DungeonService:GetActiveDungeon()
	return self._activeDungeon
end

-- Returns the room the player is currently in, or nil if they're at the Start
-- room / not in any dungeon room yet.
function DungeonService:GetPlayerRoom(player: Player)
	local dungeon = self._activeDungeon

	if not dungeon then
		warn("[DungeonService] GetPlayerRoom called but no active dungeon")
		return nil
	end

	local idx = self._playerRoomCursor[player] or 0
	return dungeon.rooms[idx]
end

-- Returns the player's current cursor index (0 = Start, 1..N = room index).
function DungeonService:GetPlayerRoomIndex(player: Player): number
	return self._playerRoomCursor[player] or 0
end

-- Directly sets a player's cursor. Fires OnRoomLeft for the previous room and
-- OnRoomEntered for the new room. Use this for initial placement; prefer
-- AdvancePlayer for normal progression. Index 0 = Start room.
function DungeonService:SetPlayerRoom(player: Player, roomIdx: number)
	local dungeon = self._activeDungeon
	if not dungeon then
		return
	end

	local previousIdx = self._playerRoomCursor[player] or 0
	if previousIdx == roomIdx then
		return
	end

	local previousRoom = dungeon.rooms[previousIdx]
	if previousRoom then
		self.Signals.OnRoomLeft:Fire(player, previousRoom)
	end

	self._playerRoomCursor[player] = roomIdx

	local newRoom = dungeon.rooms[roomIdx]
	if newRoom then
		self.Signals.OnRoomEntered:Fire(player, newRoom)
	end

	-- Slide the next-gate marker forward as players advance.
	self:_updateNextGateMarker()
end

function DungeonService:AdvancePlayer(player: Player)
	local dungeon = self._activeDungeon
	if not dungeon then
		return nil
	end

	local previousIdx = self._playerRoomCursor[player] or 0
	local nextIdx = previousIdx + 1
	if nextIdx > #dungeon.rooms then
		return nil
	end

	-- Remove the gate on the room being left so players can walk through.
	-- Idempotent: subsequent advances by other players just find nothing.
	-- EXCEPT Dungeon Gate cycle gates (GateState attribute): those must
	-- SURVIVE the advance — the whole cycle exists to shut them behind the
	-- party (advance fires on the first crossing, mid-cycle).
	local leavingModel: Instance? = if previousIdx == 0
		then dungeon.startModel
		else dungeon.rooms[previousIdx] and dungeon.rooms[previousIdx].model
	if leavingModel then
		local gate = leavingModel:FindFirstChild(EXIT_GATE_NAME)
		if gate and gate:GetAttribute("GateState") == nil then
			gate:Destroy()
		end
	end

	self:SetPlayerRoom(player, nextIdx)
	return dungeon.rooms[nextIdx]
end

-- Resets all player cursors to 0 (Start). Called automatically by
-- GenerateDungeon; call manually if you regenerate without going through it.
function DungeonService:ResetPlayerCursors()
	for player in self._playerRoomCursor do
		self._playerRoomCursor[player] = 0
	end
end

--[ Initializers ]--

function DungeonService:KnitInit() end

function DungeonService:KnitStart()
	RelicMachineService = Knit.GetService("RelicMachineService")
	RelicService = Knit.GetService("RelicService")
	ZombieSpawnService = Knit.GetService("ZombieSpawnService")
	EncounterService = Knit.GetService("EncounterService")
	UserNotificationService = Knit.GetService("UserNotificationService")
	LifeService = Knit.GetService("LifeService")
	PlayerEventService = Knit.GetService("PlayerEventService")
	CameraShakeService = Knit.GetService("CameraShakeService")

	-- Run loop: the boss's rewards have dropped -> portal + vote (or the
	-- final-dungeon hook).
	EncounterService.OnEncounterOutroFinished:Connect(function(kind: string, room, _mob: Model?)
		if kind == RoomTypes.Boss then
			self:_onBossRewardsDropped(room)
		end
	end)

	-- The party is about to be pulled into the arena: the approach gate
	-- behind them is done (see _markApproachGatePassed).
	EncounterService.OnEncounterIntroStarted:Connect(function(_kind: string, room)
		self:_markApproachGatePassed(room)
	end)

	self.Signals.OnDungeonGenerated:Connect(function()
		self.Client.OnDungeonGenerated:FireAll()

		-- New dungeon → everyone re-lands at the new start. Land every player
		-- whose client already finished preloading; the rest land when their
		-- own OnPlayerAdded (preload-done) fires. _landed is keyed by dungeon,
		-- so a player already landing in THIS dungeon is skipped (no clear).
		for _, player in Players:GetPlayers() do
			if self._readyForLanding[player] then
				self:_runPlayerLanding(player)
			end
		end
	end)

	-- PlayerEventService.OnPlayerAdded fires AFTER this player's client finishes
	-- preloading: PlayerEventController waits on PreloadController.OnPreloadComplete
	-- before calling SetupCharacter, which is what fires this. So it IS the
	-- per-player "ready" cue — no extra delay needed. If the dungeon isn't
	-- generated yet the player is queued and lands on OnDungeonGenerated.
	PlayerEventService.OnPlayerAdded:Connect(function(player)
		self.Client.OnDungeonGenerated:Fire(player)
		self:_markReadyAndMaybeLand(player)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		self._playerRoomCursor[player] = nil
		self._readyForLanding[player] = nil
		self._landed[player] = nil
		if self._run then
			self._run.exited[player] = nil
		end
	end)

	ZombieSpawnService.OnZombieDespawn:Connect(function(zombie: Model)
		local dungeon = self._activeDungeon
		if not dungeon then
			return
		end
		local roomId = zombie:GetAttribute(ROOM_ATTRIBUTE)
		if not roomId then
			return
		end
		local room = dungeon.roomsById[roomId]
		if not room then
			return
		end
		if room.roomType ~= RoomTypes.Combat then
			return
		end
		-- Check every chunk in the segment. The check requires each chunk to
		-- have been spawned in AND fully cleared — otherwise players who run
		-- past zombies into a later chunk and kill there first would trip the
		-- gate-open even though earlier chunks still have living zombies.
		if self:_areSegmentZombiesCleared(room.segmentId) then
			self:OpenSegmentGate(room.segmentId)
		end
	end)

	-- Auto-start the RUN (DungeonSequence[1] first). Fail-soft so a missing
	-- prefab folder doesn't crash boot.
	task.delay(AUTO_GENERATE_DELAY, function()
		local ok, err = pcall(function()
			self:StartRun(AUTO_GENERATE_DIFFICULTY, workspace.IgnoreInstances.DungeonSpawnPoint.CFrame)
		end)
		if not ok then
			warn("[DungeonService] Auto-generation failed: " .. tostring(err))
		end
	end)
end

return DungeonService
