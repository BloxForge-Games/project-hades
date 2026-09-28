--!strict
--[[
     Author(s):
     Module: RunFlowService.lua
     Description: The RUN LOOP. StartRun begins a run at sequence[1] (a
                  normal run is ONE dungeon: the one this place hosts, at
                  the difficulty the party arrived with); AdvanceRun (the vote passed) fades every screen to black,
                  freezes the party, tears the floor down and generates the
                  next one; GenerateDungeon is the generate-and-wire step
                  both share (DungeonGenerator places, this module flips the
                  active dungeon, prepares the exit portal and fires the
                  lifecycle signals). Also the extraction: the Boss room's
                  ExitPortal rising after the rewards, and the walk into it.
]]

--[ Roblox Services ]--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ServerScriptService = game:GetService("ServerScriptService")

--[ Exports & Types & Defaults ]--

local DungeonService = require(ServerScriptService.Services.DungeonService)
local DungeonGenerator = require(ServerScriptService.Services.DungeonGenerator)
local GateService = require(ServerScriptService.Services.GateService)
local ZombieSpawnService = require(ServerScriptService.Services.ZombieSpawnService)
local EncounterService = require(ServerScriptService.Services.EncounterService)
local CameraShakeService = require(ServerScriptService.Services.CameraShakeService)
local DungeonNetwork = require(ServerScriptService.Submodules.Core.Source.Network.Dungeon)
local Blitz = require(ReplicatedStorage.Submodules.Core.Shared.Blitz)
local DifficultyData = require(ReplicatedStorage.Submodules.Core.Shared.Data.DifficultyData)
local Difficulty = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Difficulty)
local getPlaceDungeonId = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Dungeon.getPlaceDungeonId)
local Log = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Log)
local CameraShakePresets = require(ReplicatedStorage.Submodules.Core.Shared.Enums.CameraShakePresets)
local RoomTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RoomTypes)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)

type Room = DungeonService.Room
type Dungeon = DungeonService.Dungeon
type Run = DungeonService.Run

-- EncounterService's signals carry ITS structural mirror of a room (it
-- reaches this module lazily); the object is one of ours.
type EncounterRoom = { id: number, model: Model, roomType: string, segmentId: number }

local RunFlowService = {
	Name = "RunFlowService",
	Dependencies = {
		DungeonService,
		DungeonGenerator,
		GateService,
		ZombieSpawnService,
		EncounterService,
		CameraShakeService,
	} :: { any },
}

--[ Constants ]--

local EXIT_GATE_NAME = "ExitGate"

local AUTO_GENERATE_DELAY = 5

-- The run's difficulty when nothing asks otherwise (Studio, a direct join
-- without teleport data). A request is still clamped to the leader's unlocks.
local DEFAULT_DIFFICULTY = Difficulty.Normal
-- How long the run waits for the leader's profile before starting without
-- the unlock check.
local LEADER_PROFILE_WAIT_SECONDS = 15
-- Studio only: workspace attributes that pick the difficulty (and skip the
-- unlock clamp, since Studio profiles are fresh).
local DEBUG_DIFFICULTY_ATTRIBUTE = "DebugDifficulty"
local DEBUG_ASCENSION_ATTRIBUTE = "DebugAscension"

-- RUN LOOP (see StartRun / AdvanceRun). After a boss: outro + rewards
-- (EncounterService) -> EXIT_PORTAL_DELAY -> the ExitPortal rises out of the
-- floor (Medium shake) and, only mid-chain (a run of several dungeons, the
-- future Keystone Trial), the "next dungeon" vote pad appears (EncounterService lobby, kind NextDungeon:
-- 30s auto / 3s when everyone remaining is on it). Vote expiry ->
-- AdvanceRun: fade every screen to black, tear the whole map down,
-- generate the next DungeonSequence entry, land everyone (same landing as
-- a fresh join). Walking into the portal fires OnPlayerExtracted and sends
-- THAT player to the lobby place (the escrow banks off LifeService's
-- OnPlayerLeavingToLobby once the teleport is issued); they leave the
-- vote's required count. Last dungeon (every normal run): OnFinalDungeonCompleted
-- fires (progress records off it) and the portal rises with no vote pad.
local EXIT_PORTAL_DELAY = 3
-- The ExitPortal is a Model AUTHORED INSIDE each Boss prefab, sitting
-- UNDERGROUND at its resting pose. After the boss it rises straight up by
-- its own Y extent (so its base ends level with where its top was) with a
-- MediumLong shake for everyone within EXIT_PORTAL_SHAKE_RADIUS studs.
local EXIT_PORTAL_MODEL_NAME = "ExitPortal"
local EXIT_PORTAL_RISE_SECONDS = 2
local EXIT_PORTAL_SHAKE_RADIUS = 80

local RUN_TRANSITION_FADE_SECONDS = 0.6
local RUN_TRANSITION_BLACK_HOLD_SECONDS = 1.4 -- fully black before teardown starts

local GENERATE_CHARACTER_WAIT_SECONDS = 5 -- bounded wait for characterless players

--[ Properties ]--

RunFlowService._exitPortal = nil :: Model?
RunFlowService._transitioning = false
-- Players frozen (HRP anchored) for the map swap; released at their teleport.
RunFlowService._transitionFrozen = {} :: { [Player]: true }

--[ Public Functions ]--

-- Generates one floor and wires it into the run: the zombie plan, the
-- placement (DungeonGenerator), the Boss room's exit portal, the active-
-- dungeon flip, cursor / gate / encounter resets, the first next-gate marker,
-- a bounded wait for characterless players, then OnDungeonGenerated and
-- OnFloorReady. Yields.
function RunFlowService.GenerateDungeon(
	self: typeof(RunFlowService),
	dungeonId: string,
	difficulty: string,
	seed: number?,
	originCFrame: CFrame?
): Dungeon
	-- The zombie pool is per dungeon (its GameAssets.Zombies folder).
	if ZombieSpawnService then
		ZombieSpawnService:BuildZombiePlanForDungeon(dungeonId)
	end

	-- First floor of the run: the guaranteed shop may only land AFTER the
	-- Miniboss — players start coin-less, so an early shop sells to nobody.
	-- Later floors (and no-run Studio generates read index 1 too, matching
	-- the real game-start experience) roll it anywhere.
	local dungeon = DungeonGenerator:Generate({
		dungeonId = dungeonId,
		difficulty = difficulty,
		seed = seed,
		originCFrame = originCFrame,
		forceShopAfterMiniboss = DungeonService:GetRunDungeonIndex() <= 1,
	})
	-- Boss rooms: sink the authored ExitPortal out of sight until the boss
	-- falls (see _prepareExitPortal / _raiseExitPortal).
	for _, room in dungeon.rooms do
		if room.roomType == RoomTypes.Boss then
			self:_prepareExitPortal(room)
		end
	end

	DungeonService:SetActiveDungeon(dungeon)

	DungeonService:ResetPlayerCursors()
	GateService:ResetForFloor()

	-- Tear down any active encounter / lobby (e.g. dungeon was regenerated
	-- mid-countdown) so the pad and HUD don't outlive the old run.
	if EncounterService then
		EncounterService:CleanupAll()
	end

	-- Stale marker from the previous run, if any, then place a fresh one on
	-- the first gate (Start room's ExitGate).
	DungeonService:DestroyNextGateMarker()
	DungeonService:UpdateNextGateMarker()

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

	DungeonService.Signals.OnDungeonGenerated:Fire(dungeon)
	DungeonService.Signals.OnFloorReady:Fire(dungeon)

	return dungeon
end

-- Starts a fresh RUN over `sequence` (dungeon ids, in order) at
-- `difficulty` / `ascension` for every dungeon in it. A normal run is one
-- dungeon; a longer sequence is the Keystone Trial's chain. Called by the
-- auto-start below.
function RunFlowService.StartRun(
	self: typeof(RunFlowService),
	sequence: { string },
	difficulty: string,
	ascension: number,
	originCFrame: CFrame?
): Dungeon
	assert(#sequence > 0, "[RunFlowService] StartRun needs at least one dungeon")
	local run: Run = {
		sequence = table.clone(sequence),
		index = 1,
		difficulty = difficulty,
		ascension = if difficulty == Difficulty.Ascension then ascension else 0,
		exited = {},
		originCFrame = originCFrame,
	}
	DungeonService:SetRun(run)
	DungeonService.Signals.OnRunStarted:Fire(run)
	return self:GenerateDungeon(sequence[1], difficulty, nil, originCFrame)
end

-- Destroys everything the current dungeon put in the world so the next one
-- can generate into a clean map. Order matters: encounters / lobbies first
-- (their pads + HUD), zombies + queues (room-id-keyed state MUST go before
-- new rooms take those ids), machines, markers, then the room models --
-- Walls live in a shared, cached folder, so its CHILDREN are cleared and
-- the folder itself kept.
function RunFlowService._teardownDungeon(self: typeof(RunFlowService)): Dungeon?
	local dungeon = DungeonService:GetActiveDungeon()
	-- The lifecycle edge FIRST, while the world is still intact: every
	-- per-floor system (encounters, chests, the Coffin, fog) resets off it.
	if dungeon then
		DungeonService.Signals.OnFloorTeardown:Fire(dungeon)
	end
	DungeonService:SetActiveDungeon(nil) -- staleness token for every in-flight thread

	self:_destroyExitPortal()
	DungeonService:DestroyNextGateMarker()
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

	-- The room models, the walls and the relocated chunk buildings.
	DungeonGenerator:DestroyFloor()

	GateService:ResetForFloor()
	DungeonService:ResetPlayerCursors()

	return dungeon
end

-- Vote passed (or nobody left to vote against it): fade everyone to black,
-- swap the map, land everyone alive in the next dungeon. Idempotent while a
-- transition is already running.
function RunFlowService.AdvanceRun(self: typeof(RunFlowService))
	local run = DungeonService:GetRun()
	if not run or self._transitioning then
		return
	end
	if run.index >= #run.sequence then
		return -- final dungeon: nothing to advance to
	end
	self._transitioning = true

	local fromDungeon = DungeonService:GetActiveDungeon()
	local nextId = run.sequence[run.index + 1]
	DungeonService.Signals.OnRunAdvancing:Fire(fromDungeon, nextId)

	task.spawn(function()
		DungeonNetwork.RunTransition.FireAll({ Phase = "in", Duration = RUN_TRANSITION_FADE_SECONDS })
		task.wait(RUN_TRANSITION_FADE_SECONDS + RUN_TRANSITION_BLACK_HOLD_SECONDS)

		-- The floor is about to vanish under everyone: freeze alive players in
		-- place (released when their landing teleports them onto the new start).
		table.clear(self._transitionFrozen)
		for _, player in Players:GetPlayers() do
			local character = player.Character
			local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
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
			warn("[RunFlowService] Next-dungeon generation failed: " .. tostring(err))
			-- The old floor is gone and no new one is coming: without this
			-- every alive player would sit HRP-anchored behind a black screen
			-- with no landing to release them. Let everyone go and lift the
			-- fade, whatever their state.
			for _, player in Players:GetPlayers() do
				self:ReleaseTransitionFreeze(player)
				DungeonNetwork.RunTransition.Fire(player, { Phase = "out", Duration = RUN_TRANSITION_FADE_SECONDS })
			end
			self._transitioning = false
			return
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
			if dead or DungeonService:IsPlayerExited(player) then
				self:ReleaseTransitionFreeze(player)
				DungeonNetwork.RunTransition.Fire(player, { Phase = "out", Duration = RUN_TRANSITION_FADE_SECONDS })
			end
		end
		self._transitioning = false
	end)
end

-- Un-anchors a player frozen for the map swap (see AdvanceRun). Public: the
-- landing releases each player as it teleports them onto the new start.
function RunFlowService.ReleaseTransitionFreeze(self: typeof(RunFlowService), player: Player)
	if not self._transitionFrozen[player] then
		return
	end
	self._transitionFrozen[player] = nil
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if hrp then
		hrp.Anchored = false
	end
end

--[ Exit portal ]--

-- At generation: find the Boss prefab's authored (underground) ExitPortal,
-- anchor it, and record its resting pivot + Y extent so the raise can rise
-- it by exactly its own height. Missing model = warn once; the room simply
-- has no portal (the vote still runs, players can still descend).
function RunFlowService._prepareExitPortal(_self: typeof(RunFlowService), room: Room)
	local portal = room.model and room.model:FindFirstChild(EXIT_PORTAL_MODEL_NAME)
	if not portal or not portal:IsA("Model") then
		warn(
			("[RunFlowService] Boss room %s has no '%s' model -- no exit portal"):format(
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
			("[RunFlowService] Boss room %s: ExitPortal has no ProximityPrompt -- it will be unusable"):format(
				tostring(room.model.Name)
			)
		)
	end
	room.exitPortal = portal
end

function RunFlowService._destroyExitPortal(self: typeof(RunFlowService))
	-- The portal belongs to its Boss room model and dies with the room on
	-- teardown; this only drops the rise-loop token.
	self._exitPortal = nil
end

-- Boss down: raise the room's buried ExitPortal by its own height
-- (MediumLong shake for everyone within EXIT_PORTAL_SHAKE_RADIUS), then
-- enable its ProximityPrompt. Triggering the prompt (a deliberate
-- interaction -- never a touch) fires OnPlayerExtracted and sends that player
-- to the lobby place (the escrow banks off OnPlayerLeavingToLobby once the
-- teleport is issued); they drop out of the
-- vote's required count.
function RunFlowService._raiseExitPortal(self: typeof(RunFlowService), room: Room)
	-- Re-resolve from the room MODEL: robust to the room table reaching us
	-- through EncounterService being a different reference than the one
	-- _prepareExitPortal annotated.
	local portal = room.model:FindFirstChild(EXIT_PORTAL_MODEL_NAME)
	if not portal or not portal:IsA("Model") or not portal.Parent then
		warn("[RunFlowService] _raiseExitPortal: boss room has no ExitPortal model")
		return
	end
	-- Rise by the model's own Y extent from its authored (underground) rest
	-- pose. Prepared rooms have both stored; anything else measures now.
	local restAttribute = portal:GetAttribute("ExitPortalRestCFrame")
	local riseAttribute = portal:GetAttribute("ExitPortalRiseHeight")
	local restCFrame: CFrame = if typeof(restAttribute) == "CFrame" then restAttribute else portal:GetPivot()
	local riseHeight: number = if typeof(riseAttribute) == "number" then riseAttribute else portal:GetExtentsSize().Y
	local targetCFrame = restCFrame + Vector3.new(0, riseHeight, 0)
	self._exitPortal = portal
	-- Every client plays the gate-open sound on the portal locally.
	DungeonNetwork.ExitPortalRising.FireAll(portal)
	-- Server-side twin: MusicService fades in the extraction theme.
	DungeonService.Signals.OnExitPortalRising:Fire(portal)

	if CameraShakeService then
		local origin = targetCFrame.Position
		for _, player in Players:GetPlayers() do
			local character = player.Character
			local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
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

function RunFlowService._extractPlayer(_self: typeof(RunFlowService), player: Player)
	local run = DungeonService:GetRun()
	if not run or run.exited[player] then
		return
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not character or not humanoid or humanoid.Health <= 0 or character:GetAttribute(Attributes.Death) == true then
		return
	end
	-- Bank / record hook FIRST, then the teleport (the player is still fully
	-- present with their escrow when listeners run).
	DungeonService.Signals.OnPlayerExtracted:Fire(player, DungeonService:GetActiveDungeon())

	-- Only a player who is ACTUALLY leaving counts as exited. If the teleport
	-- can't be issued (Studio; a place-teleport failure) they're still here --
	-- leaving them flagged would drop them from the vote AND the next
	-- landing, stranding them on the torn-down map.
	-- LifeService is a consumer of DungeonService: resolved at call time.
	local LifeService = Blitz.OptionalService("LifeService")
	local leaving = LifeService ~= nil and LifeService:TeleportPlayerToLobby(player) == true
	if leaving then
		run.exited[player] = true
	else
		warn(
			("[RunFlowService] %s touched the ExitPortal but could not be teleported -- staying in the run"):format(
				player.Name
			)
		)
	end
end

-- Boss rewards have dropped (EncounterService outro done). Final dungeon:
-- fire the hook, spawn nothing. Otherwise: portal + vote pad after a beat.
function RunFlowService._onBossRewardsDropped(self: typeof(RunFlowService), room: Room?)
	local run = DungeonService:GetRun()
	local dungeon = DungeonService:GetActiveDungeon()
	if not run or not dungeon or not room or not room.model then
		return
	end

	local isFinal = DungeonService:IsFinalDungeon()
	if isFinal then
		DungeonService.Signals.OnFinalDungeonCompleted:Fire(dungeon, run)
	end

	task.delay(EXIT_PORTAL_DELAY, function()
		if DungeonService:GetActiveDungeon() ~= dungeon then
			return
		end
		self:_raiseExitPortal(room)

		-- The vote to move on only exists mid-chain.
		if not isFinal and EncounterService then
			local gate = room.model:FindFirstChild(EXIT_GATE_NAME)
			local gateCFrame = (gate and gate:IsA("BasePart") and gate.CFrame) or room.model:GetPivot()
			EncounterService:StartNextDungeonVote(room, gateCFrame)
		end
	end)
end

--[ Run request ]--

-- What the arriving party asked for: the hub queue's teleport data
-- ({ Difficulty, Ascension, partyLeaderUserId }), read off the FIRST player
-- to arrive (yields until someone does). Returns the request and the
-- leader whose unlocks bound it (the first arrival when the leader is not
-- here yet or none was named).
function RunFlowService._readRunRequest(_self: typeof(RunFlowService)): (string, number, Player)
	local first = Players:GetPlayers()[1] or Players.PlayerAdded:Wait()
	local difficulty = DEFAULT_DIFFICULTY
	local ascension = 1
	local leader = first
	local joinData = first:GetJoinData()
	local data = if type(joinData) == "table" then joinData.TeleportData else nil
	if type(data) == "table" then
		if DifficultyData.IsValid(data.Difficulty) then
			difficulty = data.Difficulty
		end
		if type(data.Ascension) == "number" then
			ascension = data.Ascension
		end
		if type(data.partyLeaderUserId) == "number" then
			leader = Players:GetPlayerByUserId(data.partyLeaderUserId) or leader
		end
	end
	return difficulty, ascension, leader
end

-- The difficulty this run plays: the request, clamped DOWN to the highest
-- rank the leader has unlocked in this dungeon (DungeonProgressService).
-- Studio uses the DebugDifficulty / DebugAscension workspace attributes,
-- or the default, and skips the clamp.
function RunFlowService._resolveRunDifficulty(self: typeof(RunFlowService), dungeonId: string): (string, number)
	local requested, ascension, leader = self:_readRunRequest()

	if RunService:IsStudio() then
		local debugDifficulty = workspace:GetAttribute(DEBUG_DIFFICULTY_ATTRIBUTE)
		if DifficultyData.IsValid(debugDifficulty) then
			requested = debugDifficulty
			ascension = tonumber(workspace:GetAttribute(DEBUG_ASCENSION_ATTRIBUTE)) or 1
		end
		return requested, ascension
	end

	local rank = DifficultyData.Rank(requested, ascension) or 1
	-- A consumer of this service's facade: resolved at call time.
	local progressService = Blitz.OptionalService("DungeonProgressService")
	local unlocked = progressService
		and progressService:GetHighestUnlockedRank(leader, dungeonId, LEADER_PROFILE_WAIT_SECONDS)
	if unlocked == nil then
		warn(
			("[RunFlowService] Could not read %s's unlocks in time -- starting %s unchecked"):format(
				leader.Name,
				requested
			)
		)
	elseif rank > unlocked then
		Log.debug(
			("[RunFlowService] Requested rank %d clamped to %s's unlocked %d"):format(rank, leader.Name, unlocked)
		)
		rank = unlocked
	end
	return DifficultyData.FromRank(rank)
end

--[ Initializers ]--

function RunFlowService.Start(self: typeof(RunFlowService))
	-- Run loop: the boss's rewards have dropped -> portal + vote (or the
	-- final-dungeon hook).
	EncounterService.OnEncounterOutroFinished:Connect(function(kind: string, room: EncounterRoom?, _mob: Model?)
		if kind == RoomTypes.Boss then
			self:_onBossRewardsDropped(room :: Room?)
		end
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		self._transitionFrozen[player] = nil
	end)

	-- Auto-start the RUN: the dungeon this place hosts, at the difficulty
	-- the party arrived with (which waits for the first arrival). Fail-soft
	-- so a missing prefab folder doesn't crash boot.
	task.delay(AUTO_GENERATE_DELAY, function()
		local ok, err = pcall(function()
			local dungeonId = getPlaceDungeonId()
			local difficulty, ascension = self:_resolveRunDifficulty(dungeonId)
			Log.debug(("[RunFlowService] Starting %s on %s (ascension %d)"):format(dungeonId, difficulty, ascension))
			self:StartRun({ dungeonId }, difficulty, ascension, workspace.IgnoreInstances.DungeonSpawnPoint.CFrame)
		end)
		if not ok then
			warn("[RunFlowService] Auto-generation failed: " .. tostring(err))
		end
	end)
end

return RunFlowService
