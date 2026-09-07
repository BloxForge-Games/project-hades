--[[
     Module: EncounterService.lua
     Description: Owns the full lifecycle of a "boss-tier" encounter — the
                  pre-fight lobby, the cinematic intro (fade / walk / camera),
                  the mob spawn + wave spawner, and the defeat hook. Handles
                  both minibosses (mid-dungeon) and the final boss (end of
                  dungeon) with one parameterized flow.
]]

--[ Roblox Services ]--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

--[ Exports & Types & Defaults ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local EnemyTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.EnemyTypes)
local Signal = require(ReplicatedStorage.Submodules.Core.Packages.Signal)
local DungeonData = require(ReplicatedStorage.Submodules.Core.Shared.Data.DungeonData)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)

-- "NextDungeon" is the run-loop VOTE: same pad / timers / HUD as an
-- encounter lobby, but expiry advances the run instead of starting a fight.
export type EncounterKind = "Miniboss" | "Boss" | "NextDungeon"
local NEXT_DUNGEON_KIND = "NextDungeon"

local DungeonService -- resolved in KnitStart
local ZombieSpawnService
local IsometricCameraService

local EncounterService = Knit.CreateService({
	Name = "EncounterService",
	Client = {
		-- Active encounter HUD data. nil when no encounter is active.
		--   { kind, name, level, currentHP, maxHP }
		EncounterData = Knit.CreateProperty(nil),

		-- Pre-fight lobby state. nil when no lobby is active.
		--   { remainingSeconds, totalSeconds, playersOnPad, totalPlayers,
		--     accelerated, padPosition, kind }
		EncounterLobbyData = Knit.CreateProperty(nil),

		-- Cinematic intro signals (server drives, clients run local fade /
		-- control-lock / walk logic). Same payload shapes as the previous
		-- MinibossIntro* signals on DungeonService.
		EncounterIntroFade = Knit.CreateSignal(), -- ({ phase = "in"|"out", duration })
		EncounterIntroWalk = Knit.CreateSignal(), -- ({ targetPosition })
		EncounterIntroEnd = Knit.CreateSignal(), -- ()

		-- Cinematic OUTRO signals (mob defeated). Unlike the intro there's
		-- NO screen fade — the camera pans live onto the defeated mob, holds
		-- for the dramatic beat, then pans back to the player. Start raises
		-- the cinematic bars + locks controls (reusing the intro's
		-- _lockControls, which also cancels in-flight dashes / ability
		-- cutscenes); End lowers the bars + restores controls. The camera
		-- pan itself rides the same IsometricCameraService.OnCameraTargetChanged
		-- / OnCameraTargetReset path the intro uses.
		EncounterOutroStart = Knit.CreateSignal(), -- ()
		EncounterOutroEnd = Knit.CreateSignal(), -- ()

		-- Boss PHASE-CHANGE cinematic (mid-fight, at HP thresholds). Start
		-- locks controls + raises bars + cancels dashes / ability cutscenes
		-- (reuses the intro's _lockControls via the client handler, same as
		-- the outro); End releases. The server freezes the boss, instakills
		-- the adds, and sets invulnerability around these (see
		-- PlayPhaseCutscene); the camera rides IsometricCameraService just
		-- like the intro/outro.
		EncounterPhaseStart = Knit.CreateSignal(), -- ()
		EncounterPhaseEnd = Knit.CreateSignal(), -- ()
	},
})

--[ Constants ]--

local ROOM_TYPES = {
	Miniboss = "Miniboss",
	Boss = "Boss",
}

-- Teleport offset: how many studs forward of the gate (along LookVector) the
-- party lands at when the cinematic fades to black.
local ENCOUNTER_TELEPORT_FORWARD_OFFSET = 6
local ENCOUNTER_LEVEL_PLACEHOLDER = 1 -- TODO: derive from difficulty / mob data

-- Cinematic intro timings. The server orchestrates the whole sequence; clients
-- run their local fade / walk / control-lock logic in response to the
-- EncounterIntroFade / EncounterIntroWalk / EncounterIntroEnd signals.
local ENCOUNTER_INTRO_FADE_DURATION = 1
local ENCOUNTER_INTRO_WALK_UP_STUDS = 20
-- Party spread on arrival: the same fan the dungeon landing uses
-- (DungeonService's LANDING_SPREAD_STUDS), so a party walks into the
-- arena as a LINE instead of arriving in one overlapping pile and
-- shoving each other apart on the first physics step.
local ENCOUNTER_INTRO_SPREAD_STUDS = 5
local ENCOUNTER_INTRO_POST_TELEPORT_WAIT = 1 -- buffer for HRP replication + constraint catch-up
local ENCOUNTER_INTRO_WALK_UP_DURATION = 1.5
local ENCOUNTER_INTRO_CAMERA_TWEEN_DURATION = 2 -- matches { duration = 2 } in IsometricCameraController
local ENCOUNTER_INTRO_BOSS_HOLD_DURATION = 3 -- seconds the camera holds on the mob

-- Cinematic outro (mob defeated) timings. Same camera-tween duration as the
-- intro so the pan feels consistent. HOLD is the dramatic beat the camera
-- lingers on the corpse — the boss/miniboss death animation plays during this
-- window (wired separately). Tune all three here.
local ENCOUNTER_OUTRO_CAMERA_TWEEN_DURATION = 2 -- pan-to-mob and pan-back; matches IsometricCameraController slack
local ENCOUNTER_OUTRO_HOLD_DURATION = 3 -- seconds the camera holds on the defeated mob

-- Boss phase-change cinematic. CUTSCENE_DURATION is the hold-on-boss beat —
-- the configurable "length of each cutscene" the boss applies its phase change
-- under. A per-phase `cutsceneDuration` in ZombieData overrides it. The camera
-- pan in/out reuses the intro/outro tween duration.
local ENCOUNTER_PHASE_CUTSCENE_DURATION = 3
local ENCOUNTER_PHASE_CAMERA_TWEEN_DURATION = ENCOUNTER_OUTRO_CAMERA_TWEEN_DURATION

-- Pre-fight lobby tuning. Two parallel timers: normal always ticks; fast only
-- ticks while every alive player is on the pad and resets the moment anyone
-- steps off. Lobby expires when the smaller of the two hits 0.
local ENCOUNTER_LOBBY_TIMER_DURATION = 60
local ENCOUNTER_LOBBY_FAST_DURATION = 3
local ENCOUNTER_LOBBY_PAD_DISTANCE = 15 -- studs back from the gate, on the player-approach side
local ENCOUNTER_LOBBY_PAD_RADIUS = 5
local ENCOUNTER_LOBBY_PAD_HEIGHT = 0.4
local ENCOUNTER_LOBBY_PAD_COLOR = Color3.fromRGB(144, 46, 224)
local ENCOUNTER_LOBBY_TICK_INTERVAL = 0.1
local CUTSCENE_CAMERA_DELAY = 0.75

-- Optional Model under ServerStorage.GameAssets with a PrimaryPart. When
-- present, _createLobbyPad clones it instead of building the cylinder fallback.
local ENCOUNTER_LOBBY_PAD_PREFAB_NAME = "MinibossLobbyPad"

-- Lobby-pad marker (placeholder image; replace at the asset layer).
local LOBBY_MARKER_NAME = "EncounterLobbyMarker"
local LOBBY_MARKER_IMAGE = "rbxassetid://8239524757"
local LOBBY_MARKER_COLOR = Color3.fromRGB(255, 170, 0)
local LOBBY_MARKER_SIZE = 0.06
local LOBBY_MARKER_Y_OFFSET = 3

-- Color override for the DungeonDone particles fired on the encounter-approach
-- gate (miniboss / boss). Passed to DungeonService:_emitDungeonDoneEffect so
-- that specific gate's celebration plays in encounter purple instead of the
-- prefab-authored color.
local ENCOUNTER_GATE_PARTICLE_COLOR = Color3.fromRGB(170, 85, 255)

-- Beat between the outro cinematic ending and the reward chests falling.
local CHEST_DROP_DELAY_SECONDS = 1.5
-- Hard ceiling on the encounter gate staying shut. The gate normally
-- opens when the last chest is opened; this only ever fires if that
-- path never runs at all, and must outlast the outro plus the chest
-- service's own batch timeout.
local ENCOUNTER_GATE_FAILSAFE_SECONDS = 150
-- The gate cycle's hold after an encounter, started the moment the reward
-- chests land: the door counts down from WAIT_SECONDS ("Waiting for
-- Players...") and opens EARLY once every living player has opened their
-- chest (isDone reads EncounterChestService), exactly like the relic
-- gate ends early once everyone picked. Unopened chests stay where they
-- are and remain openable. OPEN_DELAY lets the moment land before the
-- door moves. The old shape waited on the whole chest batch and THEN ran
-- a 5s ceiling that broke on its first poll -- the flash of a timer you
-- saw after the last chest.
local ENCOUNTER_GATE_OPEN_DELAY_SECONDS = 1
local ENCOUNTER_GATE_WAIT_SECONDS = 30

--[ Server-side signals (hookable by BossService, etc.) ]--

EncounterService.OnEncounterStarted = Signal.new() -- (kind: EncounterKind, room, mob: Model)
EncounterService.OnEncounterDefeated = Signal.new() -- (kind: EncounterKind, room)

-- Fires AFTER the outro cinematic fully completes (camera returned, controls
-- released). MobBase listens here to drop the HELD miniboss/boss coin + gear
-- rewards, so they land when control returns to the player instead of
-- mid-cinematic. The vending-machine drop is handled alongside this fire (see
-- _dropEncounterRewards).
EncounterService.OnEncounterOutroFinished = Signal.new() -- (kind, room, mob: Model)

-- Music + cutscene-driven systems listen to these to swap themes /
-- volumes on intro start vs. intro end. They fire at the bookends of
-- _startFight's cinematic — IntroStarted at Phase 1 (before the fade-
-- to-black) and IntroEnded at Phase 9 (when controls are released).
-- Separate from OnEncounterStarted (which fires AFTER the mob is
-- spawned in Phase 2 — too late for music to start its intro-volume
-- ramp).
EncounterService.OnEncounterIntroStarted = Signal.new() -- (kind: EncounterKind, room)
EncounterService.OnEncounterIntroEnded = Signal.new() -- (kind: EncounterKind, room)

--[ Properties ]--

-- Active encounter (the fight, not the lobby). Set once the cinematic
-- teleports players in + spawns the mob; cleared on defeat.
-- CUTSCENE WINDOW. Every encounter cinematic (intro, outro, boss phase
-- change) is bracketed by _beginCutscene / _endCutscene. While the depth is
-- > 0: every player character AND the encounter mob carry
-- Attributes.Invulnerable (DamageService refuses damage both ways -- direct
-- hits, status ticks, Ghost Dragon, everything), and RelicService skips its
-- periodic relic ticks (Fireworks / Ghost Dragon) so nothing fires into a
-- cinematic. Depth-counted so overlapping windows can't release early.
-- Bumped by CleanupAll, which the dungeon runs on every regeneration.
-- Anything scheduled against a floor captures this first and compares it
-- on the way back in, so a timer from the last floor cannot act on this
-- one. Room tables, segment ids and models are all reused across floors,
-- which makes a stale callback look perfectly valid without it.
EncounterService._floorGeneration = 0
EncounterService._cutsceneDepth = 0
EncounterService._cutsceneMob = nil :: Model?

EncounterService._activeEncounter = nil :: {
	kind: EncounterKind,
	room: any,
	mob: Model,
	humanoid: Humanoid,
	hpConn: RBXScriptConnection?,
}?

-- Active lobby state. nil when no lobby is running.
EncounterService._activeLobby = nil :: {
	kind: EncounterKind,
	room: any,
	gateCFrame: CFrame,
	padInstance: Instance,
	padReference: BasePart,
	marker: Model?,
	thread: thread?,
	startedAt: number,
	fastStartedAt: number?,
}?

--[ Helpers: mob lookup ]--

-- Pulls the mob asset name for a kind from the active dungeon's config.
-- Returns nil if no dungeon is active or the kind isn't configured.
function EncounterService:_getMobNameForKind(kind: EncounterKind): string?
	local dungeon = DungeonService and DungeonService:GetActiveDungeon()
	if not dungeon then
		return nil
	end
	local config = DungeonData[dungeon.id]
	if not config then
		return nil
	end
	if kind == ROOM_TYPES.Miniboss then
		return config.miniboss
	elseif kind == ROOM_TYPES.Boss then
		return config.boss
	end
	return nil
end

--[ Helpers: lobby pad ]--

-- Looks up the optional lobby-pad prefab under ServerStorage.GameAssets.
function EncounterService:_findLobbyPadPrefab(): Model?
	local gameAssets = ServerStorage:FindFirstChild("GameAssets")
	if not gameAssets then
		return nil
	end
	local prefab = gameAssets:FindFirstChild(ENCOUNTER_LOBBY_PAD_PREFAB_NAME)
	if not prefab or not prefab:IsA("Model") then
		return nil
	end
	if not prefab.PrimaryPart then
		warn(
			("[EncounterService] %s prefab found but has no PrimaryPart; falling back to programmatic pad."):format(
				ENCOUNTER_LOBBY_PAD_PREFAB_NAME
			)
		)
		return nil
	end
	return prefab
end

-- Builds the Battle Ready pad inside the just-cleared room. Returns
-- (padInstance, padReference) — first is destroyable root, second is the
-- BasePart whose Position drives the occupancy check.
-- Raycasts straight down from `xzPosition` to find the dungeon floor's Y.
-- The gate's Y sits mid-wall, so we drop the pad onto the actual ground rather
-- than leaving it floating in air. Returns nil if no DungeonRooms surface is
-- found within RAYCAST_DEPTH studs (caller falls back to the original Y).
function EncounterService:_findLobbyPadFloorY(xzPosition: Vector3): number?
	local dungeonRooms = workspace.IgnoreInstances:FindFirstChild("Map")
	dungeonRooms = dungeonRooms and dungeonRooms:FindFirstChild("DungeonRooms")
	if not dungeonRooms then
		return nil
	end

	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Include
	raycastParams.FilterDescendantsInstances = { dungeonRooms }

	-- Start a few studs above the gate's Y so a gate sitting in the floor's
	-- bounding box doesn't fail to register a hit.
	local origin = xzPosition + Vector3.new(0, 10, 0)
	local result = workspace:Raycast(origin, Vector3.new(0, -100, 0), raycastParams)
	return result and result.Position.Y or nil
end

function EncounterService:_createLobbyPad(gateCFrame: CFrame): (Instance, BasePart)
	-- Gate convention in the project's prefabs: LookVector points *out* of the
	-- arena (toward the player-approach side). The pad goes in the just-cleared
	-- room so players can step on it without crossing the gate — so +LookVector
	-- from the gate is exactly where we want it.
	local rawPosition = gateCFrame.Position + (gateCFrame.LookVector * ENCOUNTER_LOBBY_PAD_DISTANCE)

	-- Snap Y to the actual dungeon floor. The gate's CFrame sits mid-wall, so
	-- without this the pad floats in mid-air. Fall back to the raw gate Y if
	-- the raycast misses (room geometry edge cases).
	local floorY = self:_findLobbyPadFloorY(rawPosition) or rawPosition.Y

	local prefab = self:_findLobbyPadPrefab()
	if prefab then
		local clone = prefab:Clone()

		-- Pivot the clone to a placeholder X/Z first so we can read its world
		-- bounding box at the intended placement, then re-pivot so the
		-- bounding-box BOTTOM sits flush on the floor regardless of how the
		-- prefab's pivot was authored (base, center, etc.).
		clone:PivotTo(CFrame.new(rawPosition.X, floorY, rawPosition.Z))
		local bbCFrame, bbSize = clone:GetBoundingBox()
		local bbBottomY = bbCFrame.Position.Y - (bbSize.Y / 2)
		local liftY = floorY - bbBottomY
		clone:PivotTo(CFrame.new(rawPosition.X, floorY + liftY, rawPosition.Z))

		clone.Parent = workspace.IgnoreInstances.Map.DungeonRooms
		return clone, clone.PrimaryPart :: BasePart
	end

	-- Programmatic fallback: flat neon cylinder. Center sits at floorY plus
	-- half the cylinder's thickness so the cylinder face is flush with the floor.
	local pad = Instance.new("Part")
	pad.Name = "EncounterBattleReadyPad"
	pad.Shape = Enum.PartType.Cylinder
	pad.Size = Vector3.new(ENCOUNTER_LOBBY_PAD_HEIGHT, ENCOUNTER_LOBBY_PAD_RADIUS * 2, ENCOUNTER_LOBBY_PAD_RADIUS * 2)
	pad.CFrame = CFrame.new(rawPosition.X, floorY + (ENCOUNTER_LOBBY_PAD_HEIGHT / 2), rawPosition.Z)
		* CFrame.Angles(0, 0, math.rad(90))
	pad.Material = Enum.Material.Neon
	pad.Color = ENCOUNTER_LOBBY_PAD_COLOR
	pad.Transparency = 0.35
	pad.Anchored = true
	pad.CanCollide = false
	pad.CanQuery = false
	pad.CanTouch = false

	local light = Instance.new("PointLight")
	light.Color = ENCOUNTER_LOBBY_PAD_COLOR
	light.Brightness = 1.5
	light.Range = ENCOUNTER_LOBBY_PAD_RADIUS * 2
	light.Parent = pad

	pad.Parent = workspace.IgnoreInstances.Map.DungeonRooms
	return pad, pad
end

-- Counts alive players whose HRP sits within the pad's horizontal radius.
function EncounterService:_countPlayersOnLobbyPad(padReference: BasePart): (number, number)
	local padPos = padReference.Position
	local onPad = 0
	local totalAlive = 0
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not character or not humanoid or humanoid.Health <= 0 then
			continue
		end
		-- Run loop: a player who walked into the ExitPortal is out of the
		-- count (they're leaving / gone), so the vote can complete without them.
		if DungeonService and DungeonService:IsPlayerExited(player) then
			continue
		end
		totalAlive += 1
		local hrp = character:FindFirstChild("HumanoidRootPart")
		if hrp then
			local delta = hrp.Position - padPos
			local horizontal = Vector3.new(delta.X, 0, delta.Z).Magnitude
			if horizontal <= ENCOUNTER_LOBBY_PAD_RADIUS then
				onPad += 1
			end
		end
	end
	return onPad, totalAlive
end

-- Builds the LocationMarker model above the pad.
function EncounterService:_createLobbyMarker(padReference: BasePart): Model?
	local mapMarkers = workspace.IgnoreInstances:FindFirstChild("MapMarkers")
	if not mapMarkers then
		warn("[EncounterService] workspace.IgnoreInstances.MapMarkers missing — lobby marker skipped.")
		return nil
	end

	local model = Instance.new("Model")
	model.Name = LOBBY_MARKER_NAME

	local primary = Instance.new("Part")
	primary.Name = "Marker"
	primary.Size = Vector3.new(1, 1, 1)
	primary.Position = padReference.Position + Vector3.new(0, LOBBY_MARKER_Y_OFFSET, 0)
	primary.Transparency = 1
	primary.Anchored = true
	primary.CanCollide = false
	primary.CanQuery = false
	primary.CanTouch = false
	primary.Parent = model
	model.PrimaryPart = primary

	local attachment = Instance.new("Attachment")
	attachment.Name = "Indicator"
	attachment:SetAttribute("Image", LOBBY_MARKER_IMAGE)
	attachment:SetAttribute("Color", LOBBY_MARKER_COLOR)
	attachment:SetAttribute("Enabled", true)
	attachment:SetAttribute("IndicatorSize", LOBBY_MARKER_SIZE)
	attachment.Parent = primary

	model.Parent = mapMarkers
	return model
end

--[ Lobby lifecycle ]--

-- Tears down the lobby state. Idempotent.
function EncounterService:_cleanupLobby()
	local lobby = self._activeLobby
	if not lobby then
		return
	end
	if lobby.thread and coroutine.status(lobby.thread) ~= "dead" then
		pcall(task.cancel, lobby.thread)
	end
	if lobby.padInstance and lobby.padInstance.Parent then
		lobby.padInstance:Destroy()
	end
	if lobby.marker and lobby.marker.Parent then
		lobby.marker:Destroy()
	end
	self._activeLobby = nil
	self.Client.EncounterLobbyData:Set(nil)
end

-- Fires when the displayed countdown hits 0. Tears the lobby down, moves
-- every player's cursor onto the encounter room (via SetPlayerRoom so the
-- combat→arena gate stays solid behind them), and hands off to the cinematic.
function EncounterService:_onLobbyExpired()
	local lobby = self._activeLobby
	if not lobby then
		return
	end
	local kind = lobby.kind
	local room = lobby.room
	local gateCFrame = lobby.gateCFrame

	self:_cleanupLobby()

	-- Run-loop vote: no fight -- hand off to DungeonService for the
	-- fade / teardown / next-dungeon generation.
	if kind == NEXT_DUNGEON_KIND then
		if DungeonService then
			DungeonService:AdvanceRun()
		end
		return
	end

	if DungeonService then
		for _, p in Players:GetPlayers() do
			DungeonService:SetPlayerRoom(p, room.id)
		end
	end

	self:_startFight(kind, room, gateCFrame)
end

-- Kicks off the pre-fight lobby for `kind` in `room`. Spawns pad + marker,
-- replicates lobby state, starts the two-parallel-timer ticker.
function EncounterService:_startLobby(kind: EncounterKind, room, gateCFrame: CFrame)
	if not room or not room.model then
		return
	end
	-- Defensive: only one lobby at a time.
	if self._activeLobby then
		return
	end

	local padInstance, padReference = self:_createLobbyPad(gateCFrame)
	local marker = self:_createLobbyMarker(padReference)

	local lobby = {
		kind = kind,
		room = room,
		gateCFrame = gateCFrame,
		padInstance = padInstance,
		padReference = padReference,
		marker = marker,
		thread = nil :: thread?,
		startedAt = workspace:GetServerTimeNow(),
		fastStartedAt = nil :: number?,
	}
	self._activeLobby = lobby

	if DungeonService then
		DungeonService:_destroyNextGateMarker()

		-- Lobby-trigger celebration: play the DungeonDone particles + Unlock
		-- sound on the cleared room's exit gate (the gate the players just
		-- walked up to). Same FX used for normal segment opens, just fired
		-- here at queue-start instead of at gate-open, and tinted encounter
		-- purple to visually mark the approach gate.
		local dungeon = DungeonService:GetActiveDungeon()

		-- (Vote lobbies sit IN the boss room; the boss branch already fired
		-- the dungeon-done effect there, so only encounter lobbies celebrate.)
		local clearedRoom = kind ~= NEXT_DUNGEON_KIND and dungeon and dungeon.rooms[room.id - 1] or nil
		if clearedRoom then
			DungeonService:_emitDungeonDoneEffect(clearedRoom.model, ENCOUNTER_GATE_PARTICLE_COLOR)
		end
	end

	task.delay(0.75, function()
		-- Initial property push so the HUD renders right away.
		local _, initialTotalPlayers = self:_countPlayersOnLobbyPad(padReference)
		self.Client.EncounterLobbyData:Set({
			kind = kind,
			label = self:_lobbyLabel(kind),
			remainingSeconds = ENCOUNTER_LOBBY_TIMER_DURATION,
			totalSeconds = ENCOUNTER_LOBBY_TIMER_DURATION,
			playersOnPad = 0,
			totalPlayers = initialTotalPlayers,
			accelerated = false,
			padPosition = padReference.Position,
		})

		-- Ticker. Two parallel timers — normal always ticks; fast only ticks while
		-- everyone's on the pad and resets the moment anyone steps off. Lobby
		-- expires on min(normal, fast) == 0.
		lobby.thread = task.spawn(function()
			while self._activeLobby == lobby do
				task.wait(ENCOUNTER_LOBBY_TICK_INTERVAL)

				if self._activeLobby ~= lobby then
					return
				end

				local now = workspace:GetServerTimeNow()
				local normalRemaining = math.max(0, ENCOUNTER_LOBBY_TIMER_DURATION - (now - lobby.startedAt))

				local onPad, totalAlive = self:_countPlayersOnLobbyPad(padReference)
				local everyoneOnPad = totalAlive > 0 and onPad >= totalAlive

				local fastRemaining: number? = nil
				if everyoneOnPad then
					if lobby.fastStartedAt == nil then
						lobby.fastStartedAt = now
					end
					fastRemaining = math.max(0, ENCOUNTER_LOBBY_FAST_DURATION - (now - lobby.fastStartedAt))
				else
					lobby.fastStartedAt = nil
				end

				local displayedRemaining: number
				local displayedTotal: number
				local accelerated: boolean
				if fastRemaining ~= nil and fastRemaining < normalRemaining then
					displayedRemaining = fastRemaining
					displayedTotal = ENCOUNTER_LOBBY_FAST_DURATION
					accelerated = true
				else
					displayedRemaining = normalRemaining
					displayedTotal = ENCOUNTER_LOBBY_TIMER_DURATION
					accelerated = false
				end

				self.Client.EncounterLobbyData:Set({
					kind = kind,
					label = self:_lobbyLabel(kind),
					remainingSeconds = displayedRemaining,
					totalSeconds = displayedTotal,
					playersOnPad = onPad,
					totalPlayers = totalAlive,
					accelerated = accelerated,
					padPosition = padReference.Position,
				})

				if displayedRemaining <= 0 then
					self:_onLobbyExpired()
					return
				end
			end
		end)
	end)
end

--[ Cinematic intro + fight ]--

-- Runs the full cinematic (fade → teleport → walk → camera pan → reveal HP →
-- camera back → controls released → waves start), then wires the defeat hook.
-- Identical flow for Miniboss and Boss; only the mob name differs.
function EncounterService:IsCutsceneActive(): boolean
	return self._cutsceneDepth > 0
end

local function setCharactersInvulnerable(invulnerable: boolean)
	for _, player in Players:GetPlayers() do
		local character = player.Character
		if character then
			character:SetAttribute(Attributes.Invulnerable, invulnerable)
		end
	end
end

-- Opens a cutscene window: players (and `mob`, if given) become invulnerable.
function EncounterService:_beginCutscene(mob: Model?)
	self._cutsceneDepth += 1
	setCharactersInvulnerable(true)
	if mob then
		self._cutsceneMob = mob
		mob:SetAttribute(Attributes.Invulnerable, true)
	end
end

-- A mob that spawns INSIDE an already-open window (the intro) joins it.
function EncounterService:_addCutsceneMob(mob: Model?)
	if not mob or self._cutsceneDepth <= 0 then
		return
	end
	self._cutsceneMob = mob
	mob:SetAttribute(Attributes.Invulnerable, true)
end

-- Closes a window; the LAST close releases everyone.
function EncounterService:_endCutscene()
	self._cutsceneDepth = math.max(0, self._cutsceneDepth - 1)
	if self._cutsceneDepth > 0 then
		return
	end
	setCharactersInvulnerable(false)
	local mob = self._cutsceneMob
	self._cutsceneMob = nil
	if mob and mob.Parent then
		mob:SetAttribute(Attributes.Invulnerable, false)
	end
end

function EncounterService:_startFight(kind: EncounterKind, room, gateCFrame: CFrame)
	if not room or not room.model or not ZombieSpawnService then
		return
	end

	local mobName = self:_getMobNameForKind(kind)
	if not mobName then
		warn(("[EncounterService] No mob configured for kind %s in active dungeon"):format(tostring(kind)))
		return
	end

	if DungeonService then
		DungeonService:_destroyNextGateMarker()
	end

	-- Gate convention in the project's prefabs: gateCFrame.LookVector points
	-- *out* of the arena (toward the player-approach side). So -LookVector is
	-- "into the arena" — the direction we teleport + walk during the intro.
	-- (The lobby pad sits on the +LookVector side, in the just-cleared room.)
	local walkDirection = -gateCFrame.LookVector
	-- The CENTRE of the arrival line. Each player's own slot is this
	-- fanned sideways in Phase 2 (ENCOUNTER_INTRO_SPREAD_STUDS).
	local teleportPosition = gateCFrame.Position + (walkDirection * ENCOUNTER_TELEPORT_FORWARD_OFFSET)
	local teleportCFrame = CFrame.new(teleportPosition, teleportPosition + walkDirection)

	task.spawn(function()
		-- Intro window: nothing can hurt anyone until Phase 9 releases it.
		self:_beginCutscene(nil)
		-- Music + cutscene listeners get a heads-up BEFORE the fade-to-
		-- black so they can start the intro-volume theme transition in
		-- parallel with the fade. The fade hides the world swap; the
		-- music intro plays underneath both.
		self.OnEncounterIntroStarted:Fire(kind, room)

		-- Phase 1: fade clients to black.
		self.Client.EncounterIntroFade:FireAll({
			phase = "in",
			duration = ENCOUNTER_INTRO_FADE_DURATION,
		})

		task.wait(ENCOUNTER_INTRO_FADE_DURATION)

		-- Phase 2: while black, teleport players + spawn the mob (idle, no waves yet).
		--
		-- Constraint-driven accessories like Ghost Dragon (AlignPosition under
		-- the character) get their rotation corrupted by a raw PivotTo: the
		-- constraint solver carries residual state across the teleport and
		-- dumps it on the next physics step. Disable every AlignPosition on
		-- each character before the pivot, yield a frame so the engine sees
		-- the new positions cleanly, then re-enable. No anchoring involved.
		local disabledAlignPositions = {}

		-- Who actually ARRIVES. Collected before the fan below so the slots
		-- are centred on the players being teleported: counting a dead
		-- teammate would leave a hole in the line and push everyone else
		-- off-centre.
		--
		-- Skip dead/spectating players. Without this, a teammate who died in
		-- the previous room gets yanked into the miniboss arena along with
		-- their ragdoll, and their spectate camera then teleports them right
		-- back out — looks broken in QA. Attributes.Death is the canonical
		-- "is currently in the death/revive/spectate window" flag set by
		-- LifeService.
		local arriving: { Player } = {}
		for _, player in Players:GetPlayers() do
			local character = player.Character
			if character and character:GetAttribute(Attributes.Death) ~= true then
				table.insert(arriving, player)
			end
		end

		-- [player] = the slot they landed on. Phase 4 walks each of them the
		-- SAME distance forward from their OWN slot, so the party advances as
		-- a line rather than converging on one point.
		local arrivalPositions: { [Player]: Vector3 } = {}

		for slot, player in arriving do
			local character = player.Character
			if not character then
				-- Lost their character between the two passes.
				continue
			end
			for _, descendant in character:GetDescendants() do
				if descendant:IsA("AlignPosition") and descendant.Enabled then
					descendant.Enabled = false
					table.insert(disabledAlignPositions, descendant)
				end
			end

			-- Slot i of n sits at (i - (n+1)/2) x SPREAD in the arrival
			-- CFrame's OWN right axis, so the line is centred on
			-- teleportPosition and square to the walk direction. Identical
			-- shape to the landing fan in DungeonService.
			local lateral = (slot - (#arriving + 1) / 2) * ENCOUNTER_INTRO_SPREAD_STUDS
			local slotCFrame = teleportCFrame * CFrame.new(lateral, 0, 0)
			arrivalPositions[player] = slotCFrame.Position
			character:PivotTo(slotCFrame)
		end

		task.wait(1)

		for _, alignPosition in disabledAlignPositions do
			alignPosition.Enabled = true
		end

		task.wait(1)

		local mob = ZombieSpawnService:SpawnMinibossInRoom(room, mobName, kind == ROOM_TYPES.Boss)
		self:_addCutsceneMob(mob)
		if not mob then
			warn(("[EncounterService] Failed to spawn %s '%s' in room %s"):format(kind, mobName, room.model.Name))

			self.Client.EncounterIntroFade:FireAll({ phase = "out", duration = ENCOUNTER_INTRO_FADE_DURATION })
			self.Client.EncounterIntroEnd:FireAll()
			self:_endCutscene()
			if DungeonService then
				DungeonService:_updateNextGateMarker()
			end
			return
		end

		local humanoid = mob:FindFirstChildOfClass("Humanoid")
		if not humanoid then
			warn(("[EncounterService] %s '%s' has no Humanoid"):format(kind, mobName))

			self.Client.EncounterIntroFade:FireAll({ phase = "out", duration = ENCOUNTER_INTRO_FADE_DURATION })
			self.Client.EncounterIntroEnd:FireAll()
			self:_endCutscene()
			return
		end

		-- Record the active encounter + fire the server-side OnEncounterStarted
		-- signal so external listeners (BossService, etc.) can hook in.
		self._activeEncounter = {
			kind = kind,
			room = room,
			mob = mob,
			humanoid = humanoid,
			hpConn = nil,
		}
		self.OnEncounterStarted:Fire(kind, room, mob)

		-- Phase 3: fade back from black.
		self.Client.EncounterIntroFade:FireAll({
			phase = "out",
			duration = ENCOUNTER_INTRO_FADE_DURATION,
		})
		task.wait(ENCOUNTER_INTRO_FADE_DURATION)

		-- Phase 4: post-teleport buffer + auto walk-up. Target computed on the
		-- server in world space so the client doesn't read a stale HRP.
		task.wait(ENCOUNTER_INTRO_POST_TELEPORT_WAIT)

		-- Straight forward from each player's OWN arrival slot, the same
		-- distance for everyone: the line that walked in stays a line.
		-- Per player rather than FireAll — a target computed from someone
		-- else's slot would drag them sideways, and a player who never
		-- arrived (dead) has no walk to run.
		for player, arrivalPosition in arrivalPositions do
			self.Client.EncounterIntroWalk:Fire(player, {
				targetPosition = arrivalPosition + (walkDirection * ENCOUNTER_INTRO_WALK_UP_STUDS),
			})
		end
		task.wait(ENCOUNTER_INTRO_WALK_UP_DURATION)

		-- Phase 5: pan the camera onto the mob.
		local cameraTarget = mob:WaitForChild("HumanoidRootPart")
		if cameraTarget and IsometricCameraService then
			IsometricCameraService.OnCameraTargetChanged:Fire(nil, cameraTarget, true)
		end
		task.wait(ENCOUNTER_INTRO_CAMERA_TWEEN_DURATION)

		-- HP-change stream. We attach now so any damage between attach and the
		-- end of the cinematic still flows; the property is only Set later
		-- (Phase 8) to delay the HP bar reveal until the camera returns.
		local encounter = self._activeEncounter
		local hpConn
		hpConn = humanoid.HealthChanged:Connect(function(newHealth)
			self.Client.EncounterData:Set({
				kind = kind,
				name = mobName,
				level = ENCOUNTER_LEVEL_PLACEHOLDER,
				currentHP = newHealth,
				maxHP = humanoid.MaxHealth,
			})
		end)
		if encounter then
			encounter.hpConn = hpConn
		end

		humanoid.Died:Once(function()
			if hpConn then
				hpConn:Disconnect()
				hpConn = nil
			end
			self:_onMobDefeated(kind, room)
		end)

		-- Phase 6: hold on the mob for the dramatic beat.
		task.wait(ENCOUNTER_INTRO_BOSS_HOLD_DURATION)

		-- Phase 7: camera back to the local player.
		if IsometricCameraService then
			IsometricCameraService.OnCameraTargetReset:Fire(nil, true)
		end
		task.wait(ENCOUNTER_INTRO_CAMERA_TWEEN_DURATION)

		-- Phase 8: HP bar reveal. We Set the property explicitly (rather than
		-- relying on the HealthChanged hook, which only fires on damage) so the
		-- bar always reveals at the same beat regardless of whether the mob
		-- has been hit during the cinematic.
		self.Client.EncounterData:Set({
			kind = kind,
			name = mobName,
			level = ENCOUNTER_LEVEL_PLACEHOLDER,
			currentHP = humanoid.Health,
			maxHP = humanoid.MaxHealth,
		})

		-- Phase 9: end the cinematic. Controls released, bars lowered, and
		-- the invulnerability window closes -- the fight is live.
		self.Client.EncounterIntroEnd:FireAll()
		self:_endCutscene()

		-- Server-side signal so MusicService can ramp the encounter
		-- theme from INTRO_VOLUME up to FULL the moment controls return.
		self.OnEncounterIntroEnded:Fire(kind, room)

		-- Defensive: skip starting waves if the mob died during the cinematic.
		if humanoid.Health > 0 then
			ZombieSpawnService:StartMinibossWaves(room)
		end
	end)
end

-- Plays the "mob defeated" cinematic: raise bars + lock controls on all
-- clients (no screen fade), pan the camera onto the dead mob, hold for the
-- dramatic beat (the death animation plays here — wired separately), then pan
-- the camera back to each player and release the lock.
--
-- Runs in a task.spawn so the surrounding _onMobDefeated cleanup (waves,
-- despawn, gate open) proceeds in parallel — those happen "off-camera" while
-- the player watches the boss, and are there when the camera returns. `mob` is
-- captured by the caller BEFORE _activeEncounter is cleared; it may already be
-- in the dead-zombie folder but its HumanoidRootPart still exists, which is all
-- the camera needs as an origin part. When the cinematic finishes it releases
-- the held rewards (coins + gear + vending machine) via _dropEncounterRewards.
function EncounterService:_playOutroCinematic(kind: EncounterKind, room, mob: Model?)
	-- Snapshot the last-room check NOW, synchronously at death time, while the
	-- dungeon is still active. The boss (last) room tears the dungeon down on
	-- defeat (lobby teleport), so GetActiveDungeon() may be nil by the time the
	-- cinematic below finishes ~8s later.
	local isLastRoom = self:_isLastRoomInSequence(room)

	task.spawn(function()
		-- Outro window: players are invulnerable until controls return (the
		-- mob is dead; nothing to protect there).
		self:_beginCutscene(nil)
		-- Lock controls + raise cinematic bars + cancel dashes / ability
		-- cutscenes (handled client-side by EncounterIntroController:_lockControls
		-- via the EncounterOutroStart handler).
		self.Client.EncounterOutroStart:FireAll()

		-- Pan the camera onto the defeated mob. Same service path the intro
		-- uses. Skipped gracefully if the HRP is gone (mob fully cleaned up
		-- before this ran) — the bars + lock still play out so the timing
		-- stays consistent for every client.
		local cameraTarget = mob and mob:FindFirstChild("HumanoidRootPart")

		if cameraTarget and IsometricCameraService then
			task.wait(CUTSCENE_CAMERA_DELAY)

			IsometricCameraService.OnCameraTargetChanged:Fire(nil, cameraTarget, true)
		end

		task.wait(ENCOUNTER_OUTRO_CAMERA_TWEEN_DURATION)

		-- Hold on the mob — the death animation beat.
		task.wait(ENCOUNTER_OUTRO_HOLD_DURATION)

		-- Camera back to the local player.
		if IsometricCameraService then
			IsometricCameraService.OnCameraTargetReset:Fire(nil, true)
		end
		task.wait(ENCOUNTER_OUTRO_CAMERA_TWEEN_DURATION)

		-- Release controls + lower the cinematic bars + close the window.
		self.Client.EncounterOutroEnd:FireAll()
		self:_endCutscene()

		-- Outro fully done → release the held rewards (coins + gear via the
		-- mob, vending machine here) so they land as control returns.
		self:_dropEncounterRewards(kind, room, mob, isLastRoom)
	end)
end

-- Opens the encounter room's exit gate. Idempotent (OpenSegmentGate
-- guards on _openedSegments), so every caller here can fire freely.
--
-- skipDungeonDoneEffect=true: _onMobDefeated already emitted the effect
-- directly for instant feedback on the kill. Without this, the post-Boss
-- / normal path re-emits 0.5s later and doubles the celebration.
function EncounterService:_openEncounterGate(room)
	-- THE funnel for every way this gate opens, and the one place the
	-- "is this room still real" question can be asked once.
	--
	-- Two callers schedule work that outlives a floor. The 150s failsafe
	-- is one (generation-guarded at its own call site). The other is the
	-- reward-chest batch: every chest connects Destroying -> _resolveChest
	-- so a despawn cannot strand the batch, which means TEARING DOWN THE
	-- FLOOR resolves every unopened chest at once, completes the batch,
	-- and fires onAllOpened — this — with the previous floor's room.
	--
	-- The damage was not the stale gate but where its segmentId landed:
	-- the new dungeon resolved it to ITS boss segment, whose
	-- _openedSegments guard the regeneration had just cleared. That ran
	-- the whole post-Boss branch on a fresh floor — the clear effect, the
	-- green "Boss Defeated / Collect your rewards..." toast, silence from
	-- MusicService's OnDungeonCompleted handler — and left the floor's real
	-- boss segment marked open before anyone reached it.
	--
	-- Room tables are rebuilt per generation, so identity against the
	-- ACTIVE dungeon is exact: a stale room can never match, and a live
	-- one always does. Cheaper and stricter than comparing ids, which are
	-- reused floor to floor.
	if not DungeonService or not room then
		return
	end
	local dungeon = DungeonService:GetActiveDungeon()
	local roomsById = dungeon and dungeon.roomsById
	if not roomsById or roomsById[room.id] ~= room then
		return
	end

	local chestService = Knit.GetService("EncounterChestService")
	DungeonService:OpenSegmentGate(room.segmentId, true, {
		seconds = ENCOUNTER_GATE_WAIT_SECONDS,
		openDelaySeconds = ENCOUNTER_GATE_OPEN_DELAY_SECONDS,
		-- Early open: every living player has opened their chest.
		isDone = function(player: Player): boolean
			return chestService == nil or chestService:HasPlayerOpenedChest(player)
		end,
	})
end

-- Drops the rewards held back during the outro. Encounter loot now lands
-- in a CHEST per player (EncounterChestService) rather than as a vending
-- machine plus a scatter around the corpse: the gear and coins the mob
-- used to drop are the chest's contents, and encounter kills no longer
-- award a relic at all (design call — that was the machine's job).
--
-- The chest drops on EVERY encounter including the run's last, unlike the
-- machine it replaces: its coins still bank on extraction, so `isLastRoom`
-- no longer gates anything here.
function EncounterService:_dropEncounterRewards(kind: EncounterKind, room, mob: Model?, isLastRoom: boolean)
	-- Still fired: other listeners hang off this beat. MobBase no longer
	-- drops anything for an encounter mob — that loot is the chest's.
	self.OnEncounterOutroFinished:Fire(kind, room, mob)

	task.wait(CHEST_DROP_DELAY_SECONDS)

	local enemyType = if kind == ROOM_TYPES.Boss then EnemyTypes.Boss else EnemyTypes.Miniboss
	local chestService = Knit.GetService("EncounterChestService")
	if chestService then
		-- onAllOpened still funnels into _openEncounterGate (idempotent):
		-- for the Boss it is the "everyone opened" early edge of the timer
		-- below; for a Miniboss the running gate cycle already handles the
		-- early open and this is a no-op.
		chestService:DropChestsForEncounter(enemyType, mob, function()
			self:_openEncounterGate(room)
		end)

		if kind == ROOM_TYPES.Boss then
			-- The boss gate never opens; the run continues through the
			-- portal + vote that OpenSegmentGate's boss path starts. Same
			-- rule as the miniboss door: ENCOUNTER_GATE_WAIT_SECONDS from
			-- the chest drop, or as soon as every chest is opened.
			local generation = self._floorGeneration
			task.delay(ENCOUNTER_GATE_WAIT_SECONDS, function()
				if self._floorGeneration ~= generation then
					return
				end
				self:_openEncounterGate(room)
			end)
		else
			-- Miniboss: the gate cycle starts NOW and counts down on the
			-- door, ending early once every living player opened theirs.
			self:_openEncounterGate(room)
		end
	else
		-- No chests to wait on.
		self:_openEncounterGate(room)
	end
	local _ = isLastRoom -- kept in the signature; no longer gates the reward
end

-- True when `room` is the LAST room of the active dungeon's sequence (the final
-- main-path room — roomsList is built in sequence order, so the last entry is
-- the sequence's final room). Gates the vending-machine drop off the
-- dungeon-ending encounter.
function EncounterService:_isLastRoomInSequence(room): boolean
	local dungeon = DungeonService and DungeonService:GetActiveDungeon()
	if not dungeon or not dungeon.rooms or not room then
		return false
	end
	local lastRoom = dungeon.rooms[#dungeon.rooms]
	return lastRoom ~= nil and lastRoom.id == room.id
end

function EncounterService:_onMobDefeated(kind: EncounterKind, room)
	if not room or not ZombieSpawnService then
		return
	end

	local mob = self._activeEncounter and self._activeEncounter.mob
	-- Kick off the outro cinematic; it releases the held rewards (coins + gear
	-- + vending machine) when it finishes, via _dropEncounterRewards.
	self:_playOutroCinematic(kind, room, mob)

	ZombieSpawnService:StopMinibossWaves(room)
	ZombieSpawnService:DespawnZombiesInRoom(room)

	self.Client.EncounterData:Set(nil)

	if DungeonService then
		DungeonService:_emitDungeonDoneEffect(room.model)
		DungeonService:_updateNextGateMarker()

		-- The gate NO LONGER opens on the kill. It opens once every player
		-- has opened their reward chest (wired in _dropEncounterRewards),
		-- so the party leaves together with their loot in hand.
		--
		-- FAILSAFE: if the outro never reaches the reward drop (an error in
		-- the spawned cinematic would kill that thread silently), the run
		-- would be unfinishable. OpenSegmentGate is idempotent, so this is
		-- free insurance — it no-ops on the normal path.
		--
		-- GENERATION-GUARDED, because 150 seconds outlasts a floor. Beat the
		-- boss and move on, and this used to fire on the NEXT floor with the
		-- old room's segmentId — which the new dungeon happily resolved to
		-- its own boss segment, whose _openedSegments guard had been cleared
		-- by the regeneration. That ran the whole post-Boss branch two
		-- minutes into a fresh floor: the clear effect, the green "Boss
		-- Defeated / Collect your rewards..." notification, and
		-- OnDungeonCompleted, with the floor's real boss segment left marked
		-- open before anyone had reached it.
		local generation = self._floorGeneration
		task.delay(ENCOUNTER_GATE_FAILSAFE_SECONDS, function()
			if self._floorGeneration ~= generation then
				return
			end
			self:_openEncounterGate(room)
		end)
	end

	self._activeEncounter = nil
	self.OnEncounterDefeated:Fire(kind, room)
end

--[ Public ]--

-- Plays a boss PHASE-CHANGE cinematic and BLOCKS until it finishes (the boss's
-- _runPhase awaits this, then un-freezes + resumes Chase). Mirrors the outro's
-- control-lock + camera treatment, plus the "freeze everything" rules:
--   * all players: controls locked + dashes / ability cutscenes cancelled
--     (client, via EncounterPhaseStart → _lockControls), and Invulnerable set
--     so an in-flight boss attack can't land mid-cutscene.
--   * the boss: AI idled (Enabled=false), pinned (WalkSpeed/AutoRotate=0/off),
--     anims stopped, Invulnerable. The boss already cancelled its OWN cast
--     (_interruptAttack) before calling this.
--   * every OTHER live mob in the room: instakilled — a clean slate for the
--     new phase.
-- opts = { duration: number?, onCutsceneBeat: (() -> ())? }. `duration` is the
-- hold-on-boss beat (defaults to ENCOUNTER_PHASE_CUTSCENE_DURATION).
-- `onCutsceneBeat` fires while the camera holds on the boss — that's where the
-- boss injects its new attacks + VFX / anim / HP.
function EncounterService:PlayPhaseCutscene(mob: Model, opts: { duration: number?, onCutsceneBeat: (() -> ())? }?)
	opts = opts or {}
	local duration = opts.duration or ENCOUNTER_PHASE_CUTSCENE_DURATION
	local room = self._activeEncounter and self._activeEncounter.room
	local humanoid = mob:FindFirstChildOfClass("Humanoid")

	-- Lock + raise bars + cancel dashes / ability cutscenes on every client.
	self.Client.EncounterPhaseStart:FireAll()
	self:_beginCutscene(mob)

	-- Players invulnerable for the cutscene (controls are locked anyway; this
	-- also nullifies any boss attack still in flight).
	local frozenCharacters = {}
	for _, player in Players:GetPlayers() do
		local character = player.Character
		if character then
			character:SetAttribute(Attributes.Invulnerable, true)
			table.insert(frozenCharacters, character)
		end
	end

	-- Freeze the boss. Enabled=false idles its AI loop; WalkSpeed/AutoRotate
	-- pin it in place; anims stop; Invulnerable shields it.
	mob:SetAttribute(Attributes.Enabled, false)
	mob:SetAttribute(Attributes.Invulnerable, true)
	if humanoid then
		humanoid.WalkSpeed = 0
		humanoid.AutoRotate = false
		for _, track in humanoid:GetPlayingAnimationTracks() do
			track:Stop()
		end
	end

	-- Clean slate: instakill every OTHER live mob in the room, and freeze the
	-- wave spawner so no new adds appear (or finish appearing) during the
	-- cutscene. Resumed at the end.
	if room and ZombieSpawnService then
		ZombieSpawnService:PauseMinibossWaves(room)
		ZombieSpawnService:DespawnZombiesInRoom(room, mob)
	end

	-- Pan the camera onto the boss.
	local cameraTarget = mob:FindFirstChild("HumanoidRootPart")

	task.wait(CUTSCENE_CAMERA_DELAY)

	if cameraTarget and IsometricCameraService then
		IsometricCameraService.OnCameraTargetChanged:Fire(nil, cameraTarget, true)
	end

	task.wait(ENCOUNTER_PHASE_CAMERA_TWEEN_DURATION)

	-- The beat: apply the phase's mechanical change while the camera holds.
	if opts.onCutsceneBeat then
		local ok, err = pcall(opts.onCutsceneBeat)
		if not ok then
			warn(("[EncounterService] Phase cutscene beat callback errored: %s"):format(tostring(err)))
		end
	end
	task.wait(duration)

	-- Camera back to the local player.
	if IsometricCameraService then
		IsometricCameraService.OnCameraTargetReset:Fire(nil, true)
	end
	task.wait(ENCOUNTER_PHASE_CAMERA_TWEEN_DURATION)

	-- Un-freeze the boss (WalkSpeed is restored by the boss's _enterChase
	-- once this returns).
	mob:SetAttribute(Attributes.Enabled, true)
	mob:SetAttribute(Attributes.Invulnerable, false)
	if humanoid then
		humanoid.AutoRotate = true
	end

	-- Clear player invulnerability + release controls.
	for _, character in frozenCharacters do
		if character.Parent then
			character:SetAttribute(Attributes.Invulnerable, false)
		end
	end
	self:_endCutscene()
	self.Client.EncounterPhaseEnd:FireAll()

	-- Resume the wave spawner for the (harder) new phase.
	if room and ZombieSpawnService then
		ZombieSpawnService:ResumeMinibossWaves(room)
	end
end

-- Entry point from DungeonService:OpenSegmentGate when the cleared segment's
-- next room is RoomTypes.Miniboss or RoomTypes.Boss. Starts the lobby; the
-- lobby's ticker eventually calls _startFight, which wires defeat back to
-- _onMobDefeated.
-- HUD title for a lobby kind ("Miniboss" -> "- Miniboss Room -" is built
-- client-side from `label`).
function EncounterService:_lobbyLabel(kind: string): string
	if kind == NEXT_DUNGEON_KIND then
		return "Next Dungeon"
	end
	return kind .. " Room"
end

-- Run-loop VOTE after a non-final boss: the encounter-lobby pad + timers,
-- placed in front of the boss room's exit gate. Standing on it = voting to
-- descend; expiry (30s, or 3s once everyone remaining is on) ->
-- DungeonService:AdvanceRun. Players who take the ExitPortal are excluded
-- from the required count.
function EncounterService:StartNextDungeonVote(room, gateCFrame: CFrame)
	self:_startLobby(NEXT_DUNGEON_KIND, room, gateCFrame)
end

function EncounterService:StartEncounter(kind: EncounterKind, room, gateCFrame: CFrame)
	if kind ~= ROOM_TYPES.Miniboss and kind ~= ROOM_TYPES.Boss then
		warn(("[EncounterService] Unknown encounter kind: %s"):format(tostring(kind)))
		return
	end
	self:_startLobby(kind, room, gateCFrame)
end

-- Tear down any in-flight lobby + clear the encounter HUD. Called by
-- DungeonService when the dungeon regenerates so a mid-encounter regen
-- doesn't leave a phantom pad / HUD.
function EncounterService:CleanupAll()
	-- Invalidate everything the last floor scheduled (see _floorGeneration).
	self._floorGeneration += 1
	self:_cleanupLobby()
	if self._activeEncounter and self._activeEncounter.hpConn then
		self._activeEncounter.hpConn:Disconnect()
	end
	self._activeEncounter = nil
	self.Client.EncounterData:Set(nil)
end

--[ Initializers ]--

function EncounterService:KnitInit() end

function EncounterService:KnitStart()
	DungeonService = Knit.GetService("DungeonService")
	ZombieSpawnService = Knit.GetService("ZombieSpawnService")
	IsometricCameraService = Knit.GetService("IsometricCameraService")
end

return EncounterService
