--!strict
--[[
     Author(s):
     Module: GateService.lua
     Description: The doors between rooms. Owns the Dungeon Gate cycle (a
                  cleared Combat segment's exit: countdown, open, per-player
                  one-way close, seal), the Event room's exit hold, the touch-
                  trigger doorways inside a segment, and the segment-clear
                  detection that starts it all.

                  SINGLE OWNER OF GATE STATE: the GateState attribute every
                  client and service keys off is written by exactly one
                  function here (_setGateState); _openedSegments and the per-
                  hold suspend / release tables are private to this module and
                  read through getters. Nothing else stamps a gate.

                  ONE HOLD DRIVER: the Combat gate's relic-shopping wait and
                  the Event room's interact-or-timeout wait used to be two
                  copies of the same loop. They are one (_runGateHold) with the
                  rules plugged in -- who counts as done, whether the hold is
                  suspended, whether it has been released -- see HoldRules.
]]

--[ Roblox Services ]--

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local ServerScriptService = game:GetService("ServerScriptService")

--[ Exports & Types & Defaults ]--

local DungeonService = require(ServerScriptService.Services.DungeonService)
local ZombieSpawnService = require(ServerScriptService.Services.ZombieSpawnService)
local EncounterService = require(ServerScriptService.Services.EncounterService)
local FogOfWarService = require(ServerScriptService.Services.FogOfWarService)
local UserNotificationService = require(ServerScriptService.Submodules.Core.Source.Services.UserNotificationService)
local DungeonNetwork = require(ServerScriptService.Submodules.Core.Source.Network.Dungeon)
local Blitz = require(ReplicatedStorage.Submodules.Core.Shared.Blitz)
local RoomTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RoomTypes)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local Log = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Log)

type Room = DungeonService.Room
type Dungeon = DungeonService.Dungeon

-- EncounterService's signals carry ITS structural mirror of a room (it
-- reaches this module lazily); the object is one of ours.
type EncounterRoom = { id: number, model: Model, roomType: string, segmentId: number }

-- One exit-door HOLD's rules (see _runGateHold). Both the Combat segment
-- gate (the relic-shopping wait) and the Event room's exit hold are the
-- same driver with different rules plugged in.
export type HoldRules = {
	seconds: number,
	-- "Who counts as done": the countdown ends EARLY once every alive
	-- player satisfies it.
	isDone: (Player) -> boolean,
	-- While it returns text (a string, or a function returning one, re-read
	-- every poll) the countdown freezes and the billboard shows that text.
	isSuspended: (() -> any)?,
	-- true ends the hold at once, whatever the clock says.
	isReleased: (() -> boolean)?,
	-- Early-open pause: a beat between the last player finishing and the
	-- door moving.
	openDelaySeconds: number?,
}

local GateService = {
	Name = "GateService",
	Dependencies = {
		DungeonService,
		ZombieSpawnService,
		EncounterService,
		FogOfWarService,
		UserNotificationService,
	} :: { any },
}

--[ Constants ]--

local EXIT_GATE_NAME = "ExitGate"
-- Components/Trap's tag (not in TagList: the component declares it inline).
local TRAP_TAG = "Trap"
local ROOM_ATTRIBUTE = "RoomId" -- set on each room model so encounter systems can map back to room data

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
-- LOCAL RE-FOG of the rooms left behind (FogOfWarService:LeaveRoomsBehind
-- -> FogOfWarController). The beat after the way back shuts:
--   * gate crossing: this many seconds after the crosser's own gate-slam
--     tween lands (the client adds its slam duration);
--   * arena intro: this many seconds after the intro's fade-to-black has
--     the party inside (fade is 1s, so the rooms go dark at 2s, unseen).
local LEAVE_BEHIND_DELAY_SECONDS = 1
local ARENA_LEAVE_BEHIND_DELAY_SECONDS = 2
local GATE_RISE_EXTRA_STUDS = 2 -- raised height = gate height + this
local GATE_VISUALS_FADE_SECONDS = 0.3 -- highlight + billboard fade in / fade out
local GATE_HIGHLIGHT_FILL_TRANSPARENCY = 0.65
local GATE_HIGHLIGHT_OUTLINE_TRANSPARENCY = 0
local DESYNCED_PLAYERS_FOLDER_NAME = "DesyncedPlayers"

--[ Properties ]--

GateService._openedSegments = {} :: { [number]: true } -- [segmentId]: true
-- EVENT HOLD SUSPENSION (see SuspendEventHold). [roomId]: billboard text
-- while suspended; [roomId]: true once released.
GateService._suspendedEventHolds = {} :: { [number]: any }
GateService._releasedEventHolds = {} :: { [number]: true }

--[ Gate state ]--

-- THE gate-state writer. Every GateState stamp ("open", "sealed", "passed")
-- goes through here, so the attribute the clients (DungeonGateController)
-- and the Coffin event key off is published from exactly one place.
function GateService._setGateState(_self: typeof(GateService), gate: BasePart, state: string?)
	gate:SetAttribute(Attributes.GateState, state)
end

-- The gate's published state: "open" (the cycle raised it), "sealed"
-- (everyone is through, closed for good), "passed" (an approach gate the
-- encounter intro carried the party past), or nil (a bare doorway / a gate
-- the cycle has not reached).
function GateService.GetGateState(_self: typeof(GateService), gate: Instance): string?
	local state = gate:GetAttribute(Attributes.GateState)
	return if type(state) == "string" then state else nil
end

-- True once OpenSegmentGate has run for the segment this floor.
function GateService.IsSegmentOpened(self: typeof(GateService), segmentId: number): boolean
	return self._openedSegments[segmentId] == true
end

-- The floor is going (or a fresh one is about to be wired): every opened
-- segment and every event-hold suspension / release belongs to the old
-- floor. Room ids restart on every floor, so a hold suspended or released
-- on this floor would otherwise read as suspended / released for whichever
-- room takes that id on the next one.
function GateService.ResetForFloor(self: typeof(GateService))
	table.clear(self._openedSegments)
	table.clear(self._suspendedEventHolds)
	table.clear(self._releasedEventHolds)
end

--[ Private Functions ]--

function GateService._placeGateBarricade(_self: typeof(GateService), roomModel: Model, gate: BasePart)
	local breakablesFolder = ReplicatedStorage:FindFirstChild("GameAssets")
		and ReplicatedStorage.GameAssets:FindFirstChild("Breakables")
	local template = breakablesFolder and breakablesFolder:FindFirstChild(BARRICADE_PREFAB_NAME)

	if not template then
		warn("[GateService] Missing ReplicatedStorage.GameAssets.Breakables." .. BARRICADE_PREFAB_NAME)
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

-- Wires a chunk's ExitGate as a touch trigger (the barricade doorways between
-- the chunks of one segment, and the Start room's exit): invisible, optionally
-- barricaded, and on the first touch it spawns the next room's wave (or starts
-- an Event room's hold), destroys itself and advances every cursor. Public for
-- DungeonGenerator, which calls it as it places each room.
function GateService.SetupGateTrigger(
	self: typeof(GateService),
	model: Model,
	nextRoomId: number,
	placeBarricade: boolean?
)
	local gate = model:FindFirstChild(EXIT_GATE_NAME)
	if not gate or not gate:IsA("BasePart") then
		return
	end

	gate.CanCollide = false
	gate.CanQuery = false
	gate.Transparency = 1

	for _, texture in pairs(gate:GetDescendants()) do
		-- Texture inherits from Decal, so the one IsA covers both.
		if texture:IsA("Decal") then
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

		local dungeon = DungeonService:GetActiveDungeon()
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
			DungeonService.Signals.OnCombatWaveStarted:Fire(nextRoom)
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
			DungeonService:AdvancePlayer(p)
		end
	end)
end

-- Alive, in-world players — the set the Dungeon Gate cycle waits on. Dead /
-- spectating (Death attribute) players never hold up the countdown or the
-- all-crossed check.
local function isGateEligible(player: Player): (boolean, Model?, BasePart?)
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
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
function GateService._gatePlayerSide(_self: typeof(GateService), roomModel: Model, gate: BasePart): Vector3
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
function GateService._onGateFirstCrossing(self: typeof(GateService), nextRoomId: number)
	local dungeon = DungeonService:GetActiveDungeon()
	local nextRoom = dungeon and dungeon.rooms[nextRoomId]

	if nextRoom and ZombieSpawnService and nextRoom.roomType == RoomTypes.Combat then
		ZombieSpawnService:SpawnZombiesInRoom(nextRoom)
		DungeonService.Signals.OnCombatWaveStarted:Fire(nextRoom)
	elseif nextRoom and nextRoom.roomType == RoomTypes.Event then
		-- First body through the door starts the event room's own exit
		-- hold (design call: the party's clock starts when someone
		-- actually walks in, not when the previous room was cleared).
		task.spawn(function()
			self:_startEventGateHold(nextRoom)
		end)
	end

	for _, p in Players:GetPlayers() do
		DungeonService:AdvancePlayer(p)
	end
end

-- THE hold driver. Dresses `gate` with the ActionHighlight visuals (a
-- darkened highlight + a "Waiting for Players...(x)" billboard), runs the
-- countdown under `rules`, then fades the visuals out. Returns true when the
-- hold ended (the deadline, everyone done, or released) and the caller may
-- move the door; false when the floor swapped or the gate vanished
-- mid-hold, in which case nothing else should happen.
function GateService._runGateHold(
	_self: typeof(GateService),
	gate: BasePart,
	dungeon: Dungeon?,
	rules: HoldRules
): boolean
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
		warn("[GateService] Missing ReplicatedStorage.GameAssets.VFX." .. ACTION_HIGHLIGHT_NAME)
	end

	local billboardFrame = billboard and billboard:FindFirstChild("Frame")
	local actionText = billboardFrame and billboardFrame:FindFirstChild("ActionText") :: TextLabel?
	if actionText then
		actionText.Text = GATE_BILLBOARD_ACTION_TEXT:format(rules.seconds)
	end

	tweenGateVisuals(highlight, billboard, true)

	local brokeEarly = false
	local deadline = os.clock() + rules.seconds
	while os.clock() < deadline do
		if DungeonService:GetActiveDungeon() ~= dungeon or not gate.Parent then
			return false
		end

		-- SUSPENDED (an event challenge is running): the countdown freezes
		-- and the billboard reads the challenge line. RELEASED: the hold is
		-- over now, whatever the clock says.
		local suspendedText = resolveSuspendedText(rules.isSuspended and rules.isSuspended())
		if suspendedText then
			deadline = os.clock() + GATE_COUNTDOWN_POLL_SECONDS * 4
			if actionText then
				actionText.Text = suspendedText
			end
			task.wait(GATE_COUNTDOWN_POLL_SECONDS)
			continue
		end
		if rules.isReleased and rules.isReleased() then
			Log.debug("[GateService] Gate hold: released, ending hold on " .. gate:GetFullName())
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
				if not rules.isDone(player) then
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
	-- Early-open pause (event holds only): everyone just finished — let
	-- the moment land for openDelaySeconds before the door moves. The
	-- staleness guard below re-checks after the wait.
	if brokeEarly and rules.openDelaySeconds then
		task.wait(rules.openDelaySeconds)
	end

	if DungeonService:GetActiveDungeon() ~= dungeon or not gate.Parent then
		return false
	end

	-- The hold is over. Visuals fade out (the door moves next), then get destroyed.
	tweenGateVisuals(highlight, billboard, false)
	task.delay(GATE_VISUALS_FADE_SECONDS, function()
		if highlight then
			highlight:Destroy()
		end
		if billboard then
			billboard:Destroy()
		end
	end)

	return true
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
function GateService._startGateCycle(
	self: typeof(GateService),
	lastChunk: Room,
	nextRoomId: number,
	countdownOverride: any?
)
	local gate = lastChunk.model:FindFirstChild(EXIT_GATE_NAME)
	if not gate or not gate:IsA("BasePart") then
		return
	end

	local dungeon = DungeonService:GetActiveDungeon()

	-- 1) + 2) Highlight, billboard and countdown: the hold driver. The
	-- classic rules end the hold EARLY once every alive player has collected
	-- a relic from their vending machine (RelicService.Signals.OnRelicsUpdated,
	-- resolved at call time: RelicService is a consumer of DungeonService).
	local chosen: { [number]: true } = {}
	local relicConnection
	if not countdownOverride then
		local RelicService = Blitz.OptionalService("RelicService")
		if RelicService then
			relicConnection = RelicService.Signals.OnRelicsUpdated:Connect(function(player: Player)
				chosen[player.UserId] = true
			end)
		end
	end
	local isPlayerDone = if countdownOverride and countdownOverride.isDone
		then countdownOverride.isDone
		else function(player: Player)
			return chosen[player.UserId] == true
		end

	local held = self:_runGateHold(gate, dungeon, {
		seconds = (countdownOverride and countdownOverride.seconds) or GATE_WAIT_SECONDS,
		isDone = isPlayerDone,
		isSuspended = countdownOverride and countdownOverride.isSuspended,
		isReleased = countdownOverride and countdownOverride.isReleased,
		openDelaySeconds = countdownOverride and countdownOverride.openDelaySeconds,
	})
	if relicConnection then
		relicConnection:Disconnect()
	end
	if not held then
		return
	end

	-- 3) OPEN.
	gate.CanCollide = false
	self:_setGateState(gate, "open")
	DungeonNetwork.GateOpened.FireAll({
		Gate = gate,
		RiseStuds = gate.Size.Y + GATE_RISE_EXTRA_STUDS,
		TweenSeconds = GATE_OPEN_TWEEN_SECONDS,
	})

	local desyncedFolder = workspace:FindFirstChild(DESYNCED_PLAYERS_FOLDER_NAME)
	if not desyncedFolder then
		warn("[GateService] workspace." .. DESYNCED_PLAYERS_FOLDER_NAME .. " missing — mob-desync disabled.")
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

	while DungeonService:GetActiveDungeon() == dungeon and gate.Parent do
		local eligible = 0
		local allCrossed = true

		for _, player in Players:GetPlayers() do
			local ok, character, hrp = isGateEligible(player)
			if not ok or not character or not hrp then
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
				DungeonNetwork.GateCrossed.Fire(player, {
					Gate = gate,
					OriginalCFrame = gate.CFrame,
					TweenSeconds = GATE_CLOSE_TWEEN_SECONDS,
				})
				-- ...and, a beat after the slam, everything behind that gate
				-- goes dark for them (the whole cleared trail, not just this
				-- segment: idempotent on the client).
				if FogOfWarService then
					FogOfWarService:LeaveRoomsBehind(
						player,
						self:_roomsUpTo(lastChunk.id),
						LEAVE_BEHIND_DELAY_SECONDS,
						true
					)
				end
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
					DungeonNetwork.GateOpened.Fire(player, {
						Gate = gate,
						RiseStuds = gate.Size.Y + GATE_RISE_EXTRA_STUDS,
						TweenSeconds = GATE_OPEN_TWEEN_SECONDS,
					})
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
	if DungeonService:GetActiveDungeon() == dungeon and gate.Parent then
		gate.CanCollide = true
		self:_setGateState(gate, "sealed")
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
function GateService.SuspendEventHold(self: typeof(GateService), roomId: number, text: (string | () -> string)?)
	self._suspendedEventHolds[roomId] = text or "Challenge in progress..."
end

function GateService.ReleaseEventHold(self: typeof(GateService), roomId: number)
	Log.debug(("[GateService] Event hold RELEASED for room %s"):format(tostring(roomId)))
	self._suspendedEventHolds[roomId] = nil
	self._releasedEventHolds[roomId] = true
end

function GateService._startEventGateHold(self: typeof(GateService), eventRoom: Room)
	local gate = eventRoom.model and eventRoom.model:FindFirstChild(EXIT_GATE_NAME)
	if not gate or not gate:IsA("BasePart") then
		warn(("[GateService] Event room '%s' has no ExitGate — hold skipped"):format(tostring(eventRoom.model)))
		return
	end

	local dungeon = DungeonService:GetActiveDungeon()
	local nextRoom = dungeon and dungeon.rooms[eventRoom.id + 1]

	-- Fresh hold, fresh suspension state (room ids repeat across floors).
	self._suspendedEventHolds[eventRoom.id] = nil
	self._releasedEventHolds[eventRoom.id] = nil

	-- EventService owns the interacted-registry. Resolved at CALL time
	-- (Blitz.OptionalService) to keep the service graph acyclic.

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
				local EventService = Blitz.OptionalService("EventService")
				local interacted = EventService and EventService:GetEventInteractions(eventRoom.id)
				return interacted ~= nil and interacted[player.UserId] == true
			end,
		})
		return
	end

	-- Highlight + countdown billboard + countdown: the same driver as the
	-- gate cycle, under the event's rules (60s; early once every alive
	-- player has interacted; suspend / release from the Coffin challenge).
	local held = self:_runGateHold(gate, dungeon, {
		seconds = EVENT_GATE_WAIT_SECONDS,
		isSuspended = function(): any
			return self._suspendedEventHolds[eventRoom.id]
		end,
		isReleased = function(): boolean
			return self._releasedEventHolds[eventRoom.id] == true
		end,
		isDone = function(player: Player): boolean
			local EventService = Blitz.OptionalService("EventService")
			local interacted = EventService and EventService:GetEventInteractions(eventRoom.id)
			return interacted ~= nil and interacted[player.UserId] == true
		end,
	})
	if not held then
		return
	end

	-- The hold is over: whatever follows, this room's exit is now earned.
	DungeonService.Signals.OnEventHoldEnded:Fire(eventRoom)

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
			EncounterService:StartEncounter(nextRoom.roomType :: EncounterService.EncounterKind, nextRoom, gate.CFrame)
		end
	else
		-- Sequence edge (an Event not followed by Miniboss/Boss): just
		-- open. Deliberately NOT the full gate cycle — nothing shoppy
		-- follows an event room today.
		gate.CanCollide = false
		self:_setGateState(gate, "open")
		DungeonNetwork.GateOpened.FireAll({
			Gate = gate,
			RiseStuds = gate.Size.Y + GATE_RISE_EXTRA_STUDS,
			TweenSeconds = GATE_OPEN_TWEEN_SECONDS,
		})
	end
end

function GateService._areSegmentZombiesCleared(_self: typeof(GateService), segmentId: number): boolean
	local dungeon = DungeonService:GetActiveDungeon()
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

-- Stamps every Trap model in the room's chunk as disabled: the server Trap
-- component reads the attribute at proc time and stays quiet. Idempotent;
-- called when a segment's gate opens and when an arena's encounter falls.
function GateService._disableRoomTraps(_self: typeof(GateService), room: Room?)
	local model = room and room.model
	if not model then
		return
	end
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("Model") and CollectionService:HasTag(descendant, TRAP_TAG) then
			descendant:SetAttribute(Attributes.TrapDisabled, true)
		end
	end
end

-- Finds the last chunk of the given segment.
function GateService._getSegmentLastChunk(_self: typeof(GateService), segmentId: number): Room?
	local dungeon = DungeonService:GetActiveDungeon()
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
function GateService.OpenSegmentGate(
	self: typeof(GateService),
	segmentId: number,
	skipDungeonDoneEffect: boolean?,
	countdownOverride: any?
)
	if self._openedSegments[segmentId] then
		return
	end

	local dungeon = DungeonService:GetActiveDungeon()
	local lastChunk = self:_getSegmentLastChunk(segmentId)

	if not lastChunk or not dungeon then
		return
	end

	self._openedSegments[segmentId] = true

	-- The segment is done: its traps go inert (Attributes.TrapDisabled).
	-- Every chunk of the segment, not just the last -- a player walking
	-- back through a cleared chamber should not eat spikes.
	for _, room in dungeon.rooms do
		if room.segmentId == segmentId then
			self:_disableRoomTraps(room)
		end
	end

	-- Post-Boss path: dungeon complete, gate opens visually.
	if lastChunk.roomType == RoomTypes.Boss then
		if not skipDungeonDoneEffect then
			task.delay(0.5, function()
				DungeonService:EmitDungeonDoneEffect(lastChunk.model)
			end)
		end

		-- The Boss room's ExitGate is deliberately LEFT ALONE (solid, black):
		-- the run continues through the ExitPortal / vote, never through it.

		task.delay(0.5, function()
			if UserNotificationService then
				local isFinal = DungeonService:IsFinalDungeon()
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
		DungeonService.Signals.OnDungeonCompleted:Fire(DungeonService:GetActiveDungeon())

		return
	end

	local nextRoom = dungeon.rooms[lastChunk.id + 1]

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
			EncounterService:StartEncounter(nextRoom.roomType :: EncounterService.EncounterKind, nextRoom, gateCFrame)
		end
		DungeonService.Signals.OnSegmentCleared:Fire(DungeonService:GetActiveDungeon(), lastChunk)
		return
	end

	if not skipDungeonDoneEffect then
		task.delay(0.5, function()
			Log.debug("[GateService] SegmentId: " .. segmentId)
			DungeonService:EmitDungeonDoneEffect(lastChunk.model)
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
		self:SetupGateTrigger(lastChunk.model, lastChunk.id + 1, false)
	end
	DungeonService.Signals.OnSegmentCleared:Fire(DungeonService:GetActiveDungeon(), lastChunk)
end

-- Every mainline room up to and including `roomId` -- the trail behind a
-- player who just left room `roomId`. For FogOfWarService:LeaveRoomsBehind.
function GateService._roomsUpTo(_self: typeof(GateService), roomId: number): { Room }
	local out: { Room } = {}
	local dungeon = DungeonService:GetActiveDungeon()
	if not dungeon then
		return out
	end
	for _, room in dungeon.rooms do
		if room.id <= roomId then
			table.insert(out, room)
		end
	end
	return out
end

-- The APPROACH gate (the cleared room's ExitGate in front of a miniboss /
-- boss arena) never opens: the encounter intro teleports the party past it
-- and it stays solid. Stamp it "passed" so gate dressing that keys off
-- GateState (the ExitGateParticlePart rig) can fade out -- OpenSegmentGate
-- never gives it the "open" stamp. Called on OnEncounterIntroStarted, while
-- the party is still standing on the pad in front of it.
function GateService._markApproachGatePassed(self: typeof(GateService), arenaRoom: Room?)
	local dungeon = DungeonService:GetActiveDungeon()
	if not dungeon or not arenaRoom or not arenaRoom.id then
		return
	end
	local previous = dungeon.rooms[arenaRoom.id - 1]
	local gate = previous and previous.model and previous.model:FindFirstChild(EXIT_GATE_NAME)
	if gate and gate:IsA("BasePart") and self:GetGateState(gate) == nil then
		self:_setGateState(gate, "passed")
	end
end

--[ Initializers ]--

function GateService.Start(self: typeof(GateService))
	-- The party is about to be pulled into the arena: the approach gate
	-- behind them is done (see _markApproachGatePassed).
	EncounterService.OnEncounterIntroStarted:Connect(function(_kind: string, encounterRoom: EncounterRoom?)
		local room = encounterRoom :: Room?
		self:_markApproachGatePassed(room)
		-- The whole party is pulled into the arena: everything before it
		-- goes dark for everyone, once the fade-to-black has them inside.
		if FogOfWarService and room and room.id then
			FogOfWarService:LeaveRoomsBehind(nil, self:_roomsUpTo(room.id - 1), ARENA_LEAVE_BEHIND_DELAY_SECONDS, false)
		end
	end)

	-- The arena is won: its traps go inert right away, not only when the
	-- gate opens later (the miniboss gate waits on chests / a countdown,
	-- the boss gate never opens), so looting the arena is safe.
	EncounterService.OnEncounterDefeated:Connect(function(_kind: string, room: EncounterRoom?)
		self:_disableRoomTraps(room :: Room?)
	end)

	ZombieSpawnService.OnZombieDespawn:Connect(function(zombie: Model)
		local dungeon = DungeonService:GetActiveDungeon()
		if not dungeon then
			return
		end
		local roomId = zombie:GetAttribute(ROOM_ATTRIBUTE)
		if type(roomId) ~= "number" then
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
end

return GateService
