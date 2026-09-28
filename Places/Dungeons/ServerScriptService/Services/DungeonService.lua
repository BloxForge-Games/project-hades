--!strict
--[[
     Author(s):
     Module: DungeonService.lua
     Description: The dungeon's OWNER and facade. Holds the run + floor data
                  (the Dungeon / Run tables, the player room cursors, the
                  next-gate marker), the Signals every other system listens
                  to, and a forwarding function for every public call
                  consumers make -- so nothing outside this cluster needs to
                  know about the split below.

                  The behaviour lives in four sub-services, each of which
                  requires THIS module (never the other way round):
                    * DungeonGenerator  pure placement: prefab pools, weighted
                                        event picking, geometry / backtracking,
                                        chunk building relocation.
                    * GateService       the Dungeon Gate cycle + the Event room
                                        exit hold; the single owner of gate
                                        state.
                    * LandingService    the join / transition landing cinematic.
                    * RunFlowService    the run loop: StartRun / AdvanceRun,
                                        floor teardown + generation, the exit
                                        portal + extraction, the final-dungeon
                                        hook.
                  Consumers reach this module through Blitz.OptionalService
                  ("DungeonService") at call time or through its Signals; the
                  forwarders below resolve their sub-service the same way, so
                  the service graph stays acyclic.

                  OnRoomEntered is exposed for external systems to consume;
                  SetPlayerRoom fires it when a player's cursor moves.

     Prefab contract -- see DungeonGenerator.
]]

--[ Roblox Services ]--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--[ Exports & Types & Defaults ]--

local Blitz = require(ReplicatedStorage.Submodules.Core.Shared.Blitz)
local Signal = require(ReplicatedStorage.Submodules.Core.Packages.Signal)
local Planner = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Dungeon.Planner)
local Difficulty = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Difficulty)
local DifficultyData = require(ReplicatedStorage.Submodules.Core.Shared.Data.DifficultyData)

-- A placed room (see _makeRoom). Everything stamped on it later --
-- branch, combatSegmentIndex, exitPortal, buildings -- is optional here.
export type Room = {
	id: number,
	roomType: string,
	segmentId: number,
	chunkIndex: number,
	chunkCount: number,
	isFirstChunk: boolean,
	isLastChunk: boolean,
	model: Model,
	branch: Room?,
	combatSegmentIndex: number?,
	exitPortal: Model?,
	buildings: { Model }?,
}

export type Dungeon = {
	id: string,
	difficulty: string,
	seed: number,
	plan: Planner.RoomPlan,
	startModel: Model,
	rooms: { Room },
	roomsById: { [number]: Room },
}

-- The RUN (see StartRun / AdvanceRun).
export type Run = {
	sequence: { string },
	index: number,
	difficulty: string,
	-- Ascension level (1..MaxAscension) when difficulty is Ascension, else 0.
	ascension: number,
	exited: { [Player]: true },
	originCFrame: CFrame?,
}

local DungeonService = {
	Name = "DungeonService",
}

--[ Constants ]--

local EXIT_GATE_NAME = "ExitGate"

local NEXT_GATE_MARKER_NAME = "NextGateMarker"
local NEXT_GATE_MARKER_IMAGE = "rbxassetid://8239524757" -- urgent / objective icon
local NEXT_GATE_MARKER_COLOR = Color3.fromRGB(255, 170, 0)
local NEXT_GATE_MARKER_SIZE = 0.05

local DUNGEON_DONE_EMIT_STRENGTH = 500

--[ Properties ]--

DungeonService.Signals = {
	OnDungeonGenerated = Signal.new(), -- (dungeon)
	OnDungeonCompleted = Signal.new(), -- (dungeon) — fired when the Boss segment is opened
	OnSegmentCleared = Signal.new(), -- (dungeon, lastChunk) — fired when a non-Boss segment is opened
	OnCombatWaveStarted = Signal.new(), -- (room) — fired when a combat room's zombies spawn via the previous-room gate trigger
	-- (i.e., the player walked into combat and zombies began spawning).
	-- MusicService listens to this to swing the mainTheme volume back
	-- up after the downtime fade from OnSegmentCleared.
	OnRoomEntered = Signal.new(), -- (player, room)

	-- RUN LOOP hooks.
	OnRunStarted = Signal.new(), -- (run) — first dungeon of a run is about to generate
	OnRunAdvancing = Signal.new(), -- (fromDungeon, toDungeonId) — vote passed, transition begins
	OnPlayerExtracted = Signal.new(), -- (player, dungeon) — walked into the ExitPortal (the escrow banks off LifeService.OnPlayerLeavingToLobby)
	OnFinalDungeonCompleted = Signal.new(), -- (dungeon, run) — last dungeon's boss down; nothing else spawns
	OnExitPortalRising = Signal.new(), -- (portal) — extraction portal surfacing (MusicService cues off this)
	-- FLOOR LIFECYCLE. Teardown fires at the START of the floor swap, before any
	-- room model is destroyed, so every per-floor system resets while the world
	-- is still intact; Ready fires once the new floor is fully generated AND
	-- wired (right after OnDungeonGenerated, which stays for its listeners).
	OnFloorTeardown = Signal.new(), -- (dungeon)
	OnFloorReady = Signal.new(), -- (dungeon)
	OnEventHoldEnded = Signal.new(), -- (eventRoom) — an Event room's exit hold ran out: its gate opens, or the
	-- encounter approach beyond it begins. Event rooms never go through OpenSegmentGate, so this is the
	-- only "this room's exit is earned" edge they emit (ExitGateWindService lights the gate off it).
}

DungeonService._activeDungeon = nil :: Dungeon?
-- The RUN: which DungeonSequence entry we're on, the difficulty shared by
-- every dungeon in it, and who has already extracted through a portal (out
-- of the vote's required count, never re-landed).
DungeonService._run = nil :: Run?
DungeonService._playerRoomCursor = {} :: { [Player]: number }
DungeonService._nextGateMarker = nil :: Model?

--[ Private Functions ]--

-- A sub-service, by name, at CALL time (Blitz.OptionalService). They all
-- mount in this place; a nil here is a boot problem worth a loud error.
local function subService(name: string): any
	local service = Blitz.OptionalService(name)
	assert(service, ("[DungeonService] %s is not mounted"):format(name))
	return service
end

--[ Next-gate marker ]--

function DungeonService._getNextGate(self: typeof(DungeonService)): BasePart?
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
function DungeonService._ensureNextGateMarker(self: typeof(DungeonService)): Model
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
-- Safe to call from anywhere — idempotent and self-creating. Public: the
-- encounter flow hides it for a lobby / intro and re-places it afterwards.
function DungeonService.UpdateNextGateMarker(self: typeof(DungeonService))
	local gate = self:_getNextGate()
	if not gate then
		self:DestroyNextGateMarker()
		return
	end

	local marker = self:_ensureNextGateMarker()

	local primary = marker.PrimaryPart
	if primary then
		primary.Position = (gate.Position + gate.CFrame.LookVector) + Vector3.new(0, -2, 0)
	end
end

-- Removes the next-gate marker (a lobby or an arena intro has its own).
function DungeonService.DestroyNextGateMarker(self: typeof(DungeonService))
	if self._nextGateMarker then
		self._nextGateMarker:Destroy()
		self._nextGateMarker = nil
	end
end

-- The segment-clear celebration on a room's ExitGate: its DungeonDone
-- particles (three bursts, optionally tinted `colorOverride`) and its Unlock
-- sound. Public: the encounter lobby fires it on the approach gate in
-- encounter purple, the Coffin event on its own room after a win.
function DungeonService.EmitDungeonDoneEffect(_self: typeof(DungeonService), roomModel: Model?, colorOverride: Color3?)
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

-- Floor / run STATE. RunFlowService is the only writer: SetActiveDungeon at
-- the end of a generation (and nil at the start of a teardown, as the
-- staleness token every in-flight thread compares against), SetRun at
-- StartRun. Everything else reads.
function DungeonService.SetActiveDungeon(self: typeof(DungeonService), dungeon: Dungeon?)
	self._activeDungeon = dungeon
end

function DungeonService.SetRun(self: typeof(DungeonService), run: Run?)
	self._run = run
end

function DungeonService.GetRun(self: typeof(DungeonService)): Run?
	return self._run
end

-- The tier the run plays (DifficultyData.Resolve, Ascension growth
-- applied): enemy health and damage, EXP, boss phases. Normal outside a run.
function DungeonService.GetDifficultyScale(self: typeof(DungeonService)): DifficultyData.TierConfig
	local run = self._run
	if not run then
		return DifficultyData.Resolve(Difficulty.Normal)
	end
	return DifficultyData.Resolve(run.difficulty, run.ascension)
end

function DungeonService.GetRunDungeonIndex(self: typeof(DungeonService)): number
	return self._run and self._run.index or 1
end

function DungeonService.IsFinalDungeon(self: typeof(DungeonService)): boolean
	local run = self._run
	return run ~= nil and run.index >= #run.sequence
end

function DungeonService.IsPlayerExited(self: typeof(DungeonService), player: Player): boolean
	local run = self._run
	return run ~= nil and run.exited[player] == true
end

function DungeonService.GetActiveDungeon(self: typeof(DungeonService)): Dungeon?
	return self._activeDungeon
end

-- Returns the room the player is currently in, or nil if they're at the Start
-- room / not in any dungeon room yet.
function DungeonService.GetPlayerRoom(self: typeof(DungeonService), player: Player): Room?
	local dungeon = self._activeDungeon

	if not dungeon then
		warn("[DungeonService] GetPlayerRoom called but no active dungeon")
		return nil
	end

	local idx = self._playerRoomCursor[player] or 0
	return dungeon.rooms[idx]
end

-- Directly sets a player's cursor. Fires OnRoomEntered for the new room.
-- Use this for initial placement; prefer
-- AdvancePlayer for normal progression. Index 0 = Start room.
function DungeonService.SetPlayerRoom(self: typeof(DungeonService), player: Player, roomIdx: number)
	local dungeon = self._activeDungeon
	if not dungeon then
		return
	end

	local previousIdx = self._playerRoomCursor[player] or 0
	if previousIdx == roomIdx then
		return
	end

	self._playerRoomCursor[player] = roomIdx

	local newRoom = dungeon.rooms[roomIdx]
	if newRoom then
		self.Signals.OnRoomEntered:Fire(player, newRoom)
	end

	-- Slide the next-gate marker forward as players advance.
	self:UpdateNextGateMarker()
end

function DungeonService.AdvancePlayer(self: typeof(DungeonService), player: Player): Room?
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
		-- GateService owns gate state; read it through its getter.
		local GateService = Blitz.OptionalService("GateService")
		if gate and GateService and GateService:GetGateState(gate) == nil then
			gate:Destroy()
		end
	end

	self:SetPlayerRoom(player, nextIdx)
	return dungeon.rooms[nextIdx]
end

-- Resets all player cursors to 0 (Start). Called automatically by
-- GenerateDungeon; call manually if you regenerate without going through it.
function DungeonService.ResetPlayerCursors(self: typeof(DungeonService))
	for player in self._playerRoomCursor do
		self._playerRoomCursor[player] = 0
	end
end

--[ Forwarders ]--

-- Every public entry point that used to live here still answers to the same
-- name; the work happens in the sub-service, resolved at call time.

function DungeonService.GenerateDungeon(
	_self: typeof(DungeonService),
	dungeonId: string,
	difficulty: string,
	seed: number?,
	originCFrame: CFrame?
): Dungeon
	return subService("RunFlowService"):GenerateDungeon(dungeonId, difficulty, seed, originCFrame)
end

function DungeonService.StartRun(_self: typeof(DungeonService), difficulty: string, originCFrame: CFrame?): Dungeon
	return subService("RunFlowService"):StartRun(difficulty, originCFrame)
end

function DungeonService.AdvanceRun(_self: typeof(DungeonService))
	subService("RunFlowService"):AdvanceRun()
end

function DungeonService.OpenSegmentGate(
	_self: typeof(DungeonService),
	segmentId: number,
	skipDungeonDoneEffect: boolean?,
	countdownOverride: any?
)
	subService("GateService"):OpenSegmentGate(segmentId, skipDungeonDoneEffect, countdownOverride)
end

function DungeonService.SuspendEventHold(_self: typeof(DungeonService), roomId: number, text: (string | () -> string)?)
	subService("GateService"):SuspendEventHold(roomId, text)
end

function DungeonService.ReleaseEventHold(_self: typeof(DungeonService), roomId: number)
	subService("GateService"):ReleaseEventHold(roomId)
end

--[ Initializers ]--

function DungeonService.Start(self: typeof(DungeonService))
	Players.PlayerRemoving:Connect(function(player: Player)
		self._playerRoomCursor[player] = nil
		if self._run then
			self._run.exited[player] = nil
		end
	end)
end

return DungeonService
