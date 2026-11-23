--!strict
--[[
	Module: Server/Services/EventGuideService.lua
	Description:
	Where an Event room wants each player to go (2026-11-19). Play-testers
	walked into event rooms and did not know what to do, so the room now
	leads them: the guide path (the hub's golden wisps, GuideBeamController)
	runs from the player to the EVENT (the shrine, the NPC, the clown), and
	once that player is done with it, or the room's door has opened, to the
	EXIT GATE. The Spirit Companion explains the event on the way in and
	points at the door on the way out (SpiritCompanionBarkController).

	Published per player; this service is the single writer of both:
	  EventGuideTarget   an ObjectValue under the Player: the instance the
	                     guide path points at, nil for none
	                     (EventGuideController reads it).
	  EventRoomState     a Player attribute (Attributes.EventRoomState):
	                     "" outside an Event room, "<Kind>" inside one
	                     ("Forge", "WheelOfFortune", ...), "<Kind>|done"
	                     once the player is pointed at the door.

	"Done" for a player is EventService's own registry (OnInteracted: a
	finished conversation, a declined offer, the party's wheel spin). The
	door opening (its GateState going "open") or the room's hold ending
	(OnEventHoldEnded, the Miniboss / Boss approach) points everyone in the
	room at the door, done or not: that is the time-out.

	THE NUDGE, everywhere outside an Event room (2026-11-19). The path
	waits: it only appears for a player who has left the next thing
	untouched for NUDGE_SECONDS, and the clock restarts whenever that next
	thing changes. In order:
	  THE VENDING MACHINE  After a Combat room is cleared (and in the start
	          room), the player's own relic machine, until they open it.
	          (No path shows within 7 studs of any target: that is
	          GuideBeamController's own rule.)
	  THE EXIT GATE        NUDGE_SECONDS after they opened the machine (and
	          never while its cards are still on screen), that room's exit
	          gate, the door the next-gate marker sits on.
	  A DOORWAY INSIDE A COMBAT ROOM  once that chunk's mobs are all dead
	          (the marker alone did not get play-testers to walk on to the
	          second half). Never while mobs live: the path would pull the
	          player into the next wave.
	  ANY OPEN GATE        for a player with no machine (they were down at
	          the clear), and after a Miniboss.
	"Opened" is the machine's own Pulled attribute, so a relic from
	anywhere else (a chest, a chat command) does not count.
	EventRoomState stays "" for all of these.
]]

--[ Roblox Services ]--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

--[ Imports ]--

local DungeonService = require(ServerScriptService.Services.DungeonService)
local EventService = require(ServerScriptService.Services.EventService)
local LandingService = require(ServerScriptService.Services.LandingService)
local MobSpawnService = require(ServerScriptService.Services.MobSpawnService)
local RelicOfferService = require(ServerScriptService.Services.RelicOfferService)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local RoomTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RoomTypes)

--[ Constants ]--

local TARGET_VALUE_NAME = "EventGuideTarget"
local EXIT_GATE_NAME = "ExitGate"
local GATE_STATE_OPEN = "open"
local GATE_STATE_SEALED = "sealed"
local DONE_SUFFIX = "|done"
-- The nudge: seconds a player may leave their next step untouched before
-- the path points at it, and how often that is checked.
local NUDGE_SECONDS = 10
local IDLE_POLL_SECONDS = 1
-- The relic vending machines (RelicMachineService / Components.RelicMachine).
local MACHINE_FOLDER_NAME = "RelicMachines"
local MACHINE_TYPE_ATTRIBUTE = "MachineType"
local RELIC_MACHINE_TYPE = "Relic"
local MACHINE_PULLED_ATTRIBUTE = "Pulled"

--[ Types ]--

type Room = DungeonService.Room

--[ Service ]--

local EventGuideService = {
	Name = "EventGuideService",
	Dependencies = { DungeonService, EventService, RelicOfferService, LandingService, MobSpawnService } :: { any },

	-- [roomId] = true once the room's door has opened or its hold ended.
	_roomOpen = {} :: { [number]: boolean },
	-- [roomId] = the watch on that room's ExitGate state.
	_gateWatches = {} :: { [number]: RBXScriptConnection },

	-- The last chunk of the Combat room cleared most recently (its exit
	-- gate is the way on), nil before the first clear of a floor.
	_clearedChunk = nil :: Room?,
	-- [userId] = the relic machine dropped for that player most recently.
	_machines = {} :: { [number]: Model },
	-- [player] = the room the /event test command built and dropped them
	-- in (SetDebugRoom). It is not on the floor's path, so the player's
	-- room cursor never names it; cleared when they next enter a room.
	_debugRooms = {} :: { [Player]: Room },

	-- The idle nudge. [player] = true once their drop into this floor has
	-- finished; the way on they currently have and when they got it; and
	-- what the path points at once that has stood NUDGE_SECONDS.
	_landed = {} :: { [Player]: boolean },
	_idle = {} :: { [Player]: { gate: Instance, since: number } },
	_idleGate = {} :: { [Player]: Instance },
}

--[ Private ]--

local function targetValue(player: Player): ObjectValue
	local existing = player:FindFirstChild(TARGET_VALUE_NAME)
	if existing and existing:IsA("ObjectValue") then
		return existing
	end
	local value = Instance.new("ObjectValue")
	value.Name = TARGET_VALUE_NAME
	value.Parent = player
	return value
end

local function exitGate(room: Room): Instance?
	local gate = room.model and room.model:FindFirstChild(EXIT_GATE_NAME)
	return if gate and gate:IsA("BasePart") then gate else nil
end

local function publish(player: Player, target: Instance?, state: string)
	local value = targetValue(player)
	if value.Value ~= target then
		value.Value = target
	end
	if player:GetAttribute(Attributes.EventRoomState) ~= state then
		player:SetAttribute(Attributes.EventRoomState, state)
	end
end

-- Points `player` at what their room wants: nothing outside an Event room,
-- the event until they are done with it, then the exit gate.
function EventGuideService._playerRoom(self: typeof(EventGuideService), player: Player): Room?
	local debugRoom = self._debugRooms[player]
	if debugRoom and debugRoom.model and debugRoom.model.Parent then
		return debugRoom
	end
	return if DungeonService:GetActiveDungeon() then DungeonService:GetPlayerRoom(player) else nil
end

function EventGuideService._refresh(self: typeof(EventGuideService), player: Player)
	if not player.Parent then
		return
	end
	local room = self:_playerRoom(player)
	if not room or room.roomType ~= RoomTypes.Event then
		publish(player, self._idleGate[player], "")
		return
	end
	local model, kind = EventService:GetEventModel(room.id)
	local eventKind = kind or "Event"
	local done = self._roomOpen[room.id] == true
		or EventService:GetEventInteractions(room.id)[player.UserId] == true
		or model == nil
	if done then
		publish(player, exitGate(room), eventKind .. DONE_SUFFIX)
	else
		publish(player, model, eventKind)
	end
end

-- The vending machine dropped for `player` most recently, while it still
-- stands and belongs to the room they are in: the start room, or the Combat
-- room cleared last.
function EventGuideService._machine(self: typeof(EventGuideService), player: Player, room: Room?): Model?
	local machine = self._machines[player.UserId]
	if not machine or not machine.Parent then
		return nil
	end
	local cleared = self._clearedChunk
	local here = room == nil or (cleared ~= nil and room.segmentId == cleared.segmentId)
	return if here then machine else nil
end

-- What `player` should be doing next, nil while there is nothing (still
-- dropping in, mobs alive, a shut gate) or inside an Event room, which
-- leads the player itself.
function EventGuideService._nextStep(self: typeof(EventGuideService), player: Player): Instance?
	local dungeon = DungeonService:GetActiveDungeon()
	if not dungeon or not self._landed[player] or DungeonService:IsRunCleared() then
		return nil
	end
	local room = self:_playerRoom(player)
	if room and room.roomType == RoomTypes.Event then
		return nil
	end

	-- The door out of where they stand: the start room's, the cleared
	-- room's last chunk's, or this chunk's.
	local cleared = self._clearedChunk
	local gate: Instance?
	if not room then
		local startGate = dungeon.startModel:FindFirstChild(EXIT_GATE_NAME)
		gate = if startGate and startGate:IsA("BasePart") then startGate else nil
	elseif cleared and room.segmentId == cleared.segmentId then
		gate = exitGate(cleared)
	else
		gate = exitGate(room)
	end
	local state = if gate then gate:GetAttribute(Attributes.GateState) else nil

	-- Their machine first; the door once they have opened it.
	local machine = self:_machine(player, room)
	if machine then
		if machine:GetAttribute(MACHINE_PULLED_ATTRIBUTE) ~= true then
			return machine
		end
		return if state ~= GATE_STATE_SEALED then gate else nil
	end

	if not gate or not room then
		return if state ~= GATE_STATE_SEALED then gate else nil
	end
	if state == GATE_STATE_OPEN then
		return gate
	end
	-- A doorway inside a Combat room (the next chunk is the same room):
	-- free once everything this chunk will ever spawn is dead.
	local nextRoom = dungeon.rooms[room.id + 1]
	local inner = room.roomType == RoomTypes.Combat
		and state == nil
		and nextRoom ~= nil
		and nextRoom.segmentId == room.segmentId
	if
		inner
		and MobSpawnService:WasRoomSpawned(room)
		and MobSpawnService:IsRoomQueueExhausted(room)
		and #MobSpawnService:GetMobsInRoom(room) == 0
	then
		return gate
	end
	return nil
end

-- True while a due nudge should stay hidden: the relic cards are on screen.
function EventGuideService._nudgeHidden(_self: typeof(EventGuideService), player: Player): boolean
	return RelicOfferService:HasOpenOffer(player)
end

-- One pass of the nudge over every player.
function EventGuideService._tickIdle(self: typeof(EventGuideService))
	local now = os.clock()
	for _, player in Players:GetPlayers() do
		local target = self:_nextStep(player)
		local idle: { gate: Instance, since: number }? = self._idle[player]
		if not target then
			idle = nil
		elseif not idle or idle.gate ~= target then
			idle = { gate = target, since = now }
		end
		self._idle[player] = idle :: any
		local shown = if idle and now - idle.since >= NUDGE_SECONDS then idle.gate else nil
		if shown and self:_nudgeHidden(player) then
			shown = nil
		end
		if self._idleGate[player] ~= shown then
			self._idleGate[player] = shown :: any
			self:_refresh(player)
		end
	end
end

function EventGuideService._refreshRoom(self: typeof(EventGuideService), roomId: number)
	for _, player in Players:GetPlayers() do
		local room = self:_playerRoom(player)
		if room and room.id == roomId then
			self:_refresh(player)
		end
	end
end

function EventGuideService._markRoomOpen(self: typeof(EventGuideService), roomId: number)
	if self._roomOpen[roomId] then
		return
	end
	self._roomOpen[roomId] = true
	self:_refreshRoom(roomId)
end

-- Watches an Event room's exit gate for the moment it opens.
function EventGuideService._watchGate(self: typeof(EventGuideService), room: Room)
	if self._gateWatches[room.id] then
		return
	end
	local gate = exitGate(room)
	if not gate then
		return
	end
	local function check()
		if gate:GetAttribute(Attributes.GateState) == GATE_STATE_OPEN then
			self:_markRoomOpen(room.id)
		end
	end
	self._gateWatches[room.id] = gate:GetAttributeChangedSignal(Attributes.GateState):Connect(check)
	check()
end

-- The /event test command (ChatCommandsService): `player` now stands in
-- `room`, an event room built off the floor's path, so guide them through
-- it as if they had walked in.
function EventGuideService.SetDebugRoom(self: typeof(EventGuideService), player: Player, room: Room)
	self._debugRooms[player] = room
	self._roomOpen[room.id] = nil
	local watch = self._gateWatches[room.id]
	if watch then
		watch:Disconnect()
		self._gateWatches[room.id] = nil
	end
	self:_watchGate(room)
	self:_refresh(player)
end

function EventGuideService._resetFloor(self: typeof(EventGuideService))
	for _, connection in self._gateWatches do
		connection:Disconnect()
	end
	table.clear(self._gateWatches)
	table.clear(self._roomOpen)
	table.clear(self._machines)
	table.clear(self._debugRooms)
	table.clear(self._landed)
	table.clear(self._idle)
	table.clear(self._idleGate)
	self._clearedChunk = nil
	for _, player in Players:GetPlayers() do
		publish(player, nil, "")
	end
end

--[ Lifecycle ]--

function EventGuideService.Start(self: typeof(EventGuideService))
	for _, player in Players:GetPlayers() do
		targetValue(player)
	end
	Players.PlayerAdded:Connect(function(player: Player)
		targetValue(player)
	end)

	DungeonService.Signals.OnRoomEntered:Connect(function(player: Player, room: Room)
		self._debugRooms[player] = nil
		if room.roomType == RoomTypes.Event then
			self:_watchGate(room)
		end
		self:_refresh(player)
	end)
	DungeonService.Signals.OnEventHoldEnded:Connect(function(room: Room)
		self:_markRoomOpen(room.id)
	end)
	DungeonService.Signals.OnFloorTeardown:Connect(function()
		self:_resetFloor()
	end)
	EventService.OnInteracted:Connect(function(player: Player, _roomId: number)
		self:_refresh(player)
	end)

	-- Combat rooms: the clear, then each player's machine (dropped a beat
	-- after the signal, so the old ones are forgotten first).
	DungeonService.Signals.OnSegmentCleared:Connect(function(_dungeon: any, lastChunk: Room)
		if lastChunk.roomType ~= RoomTypes.Combat then
			return
		end
		self._clearedChunk = lastChunk
		table.clear(self._machines)
	end)
	task.spawn(function()
		local ignore = workspace:WaitForChild("IgnoreInstances")
		local machines = ignore:WaitForChild("Map"):WaitForChild(MACHINE_FOLDER_NAME)
		machines.ChildAdded:Connect(function(child: Instance)
			local ownerId = child:GetAttribute(Attributes.OwnerId)
			if
				child:IsA("Model")
				and typeof(ownerId) == "number"
				and child:GetAttribute(MACHINE_TYPE_ATTRIBUTE) == RELIC_MACHINE_TYPE
			then
				self._machines[ownerId] = child
			end
		end)
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		self._debugRooms[player] = nil
		self._machines[player.UserId] = nil
		self._landed[player] = nil
		self._idle[player] = nil
		self._idleGate[player] = nil
	end)

	-- The idle nudge.
	LandingService.OnPlayerLanded:Connect(function(player: Player)
		self._landed[player] = true
	end)
	task.spawn(function()
		while true do
			task.wait(IDLE_POLL_SECONDS)
			self:_tickIdle()
		end
	end)
end

return EventGuideService
