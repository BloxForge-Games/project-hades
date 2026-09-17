--!strict
--[[
     Module: LifeService.lua
     Description:
     Server-authoritative lives + death lifecycle. Replaces Roblox's
     built-in Humanoid death entirely: DamageService clamps lethal damage to
     leave HP at 1 instead of 0, then calls LifeService:LoseLife. We never
     let Humanoid.Health reach 0, so Humanoid.Died never fires and the
     thousand systems that assume the character is alive don't break.

     Death is TWO phases, both server-authoritative and both replicated
     through the DeathState snapshot:

       DOWNED  Out of lives. Death attribute on, controls locked, the death
               animation plays and freezes on its last frame, the body
               stays where it fell. The revive DECISION WINDOW
               (DeathCinematicData.GameOverDuration) is open: the client's
               "Eternal Damnation" screen counts down to
               `windowEndsAtServerTime` and offers the paid revive. The run
               gear does NOT spill and nothing is discarded -- a revive
               here stands the player up in place with everything intact.

       DEAD    The window closed with no revive. `fullyDiedAtServerTime`
               is stamped, OnPlayerFullyDied / PlayerFullyDied fire, and
               ONLY NOW the gear spills (RunEscrowService), the body and
               screen fade, the gravestone rises and spectate begins. A
               party WIPE is every connected player in this phase.

     The paid revive (dev product) works in both phases: prompted only
     while downed, but a receipt that lands after the window closed still
     revives (they paid). `/revive` (ChatCommandsService) is a debug tool
     that calls :Revive any time.
]]

--[ Roblox Services ]--

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeleportService = game:GetService("TeleportService")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

--[ Exports & Types & Defaults ]--

local PlayerEventService = require(ServerScriptService.Submodules.Core.Source.Services.PlayerEventService)
local TextIndicatorService = require(ServerScriptService.Submodules.Core.Source.Services.TextIndicatorService)
local InvulnerabilityService = require(ServerScriptService.Services.InvulnerabilityService)
local UserNotificationService = require(ServerScriptService.Submodules.Core.Source.Services.UserNotificationService)
local RagdollService = require(ServerScriptService.Services.RagdollService)
local PlayerNetwork = require(ServerScriptService.Submodules.Core.Source.Network.Player)
local RemoteProperty = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Network.RemoteProperty)
local Signal = require(ReplicatedStorage.Submodules.Core.Packages.Signal)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local DungeonData = require(ReplicatedStorage.Submodules.Core.Shared.Data.DungeonData)
local Constants = require(ReplicatedStorage.Submodules.Core.Shared.Data.Constants)
local DeathCinematicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.DeathCinematicData)

-- DungeonService requires this module at load, so this side reaches it
-- lazily: required on first use, once both modules exist.
local dungeonServiceLazy: any = nil
local function getDungeonService(): any
	if dungeonServiceLazy == nil then
		dungeonServiceLazy = (require :: any)(ServerScriptService.Services.DungeonService)
	end
	return dungeonServiceLazy
end

export type DeathPhase = "downed" | "dead"

-- One player's death, server side. The replicated snapshot carries every
-- field but diedAtClock (see _replicateDeathState for the wire shape).
export type DeathEntry = {
	phase: DeathPhase,
	diedAtClock: number,
	diedAtServerTime: number,
	-- When the revive window opens and closes (workspace:GetServerTimeNow()
	-- base). Fixed at the moment of downing; the client bar flies in full
	-- at the opening and counts down to the close.
	windowStartsAtServerTime: number,
	windowEndsAtServerTime: number,
	-- Stamped on the downed -> dead transition; nil while downed.
	fullyDiedAtServerTime: number?,
	deathPosition: Vector3,
}

local LifeService = {
	Name = "LifeService",
	Dependencies = {
		PlayerEventService,
		TextIndicatorService,
		InvulnerabilityService,
		UserNotificationService,
		RagdollService,
	} :: { any },
}

-- Per-player lives snapshot, replicated to ALL clients (was a replicated
-- property): { [userId] = { current: number, max: number } }
LifeService._livesProperty = RemoteProperty.Server({
	changed = PlayerNetwork.LivesDataChanged,
	get = PlayerNetwork.GetLivesData,
}, {})

-- Per-player death snapshot, replicated to ALL clients:
--   { [userId] = { phase, diedAtServerTime, windowEndsAtServerTime,
--                  fullyDiedAtServerTime?, deathPosition, player } }
LifeService._deathStateProperty = RemoteProperty.Server({
	changed = PlayerNetwork.DeathStateChanged,
	get = PlayerNetwork.GetDeathState,
}, {})

-- Whole party down. Server-side only: no client ever read the old
-- GameOverState property, the GameOver broadcast is what they act on.
LifeService._isGameOver = false

--[ Constants ]--

local POST_LIFE_LOSS_INVULN_SECONDS = 3
local DEFAULT_LIVES = 1
local DEATH_ANIMATION_ID = "rbxassetid://73249560309673"
local DEATH_ANIMATION_SPEED = 0.35
-- How close to the track's end (seconds of track time) the hold engages.
-- At 0.35x speed one Heartbeat advances the track ~6ms, so this is ~8
-- frames of margin: comfortably before Roblox stops a non-looped track
-- at its end, and visually still the final pose.
local DEATH_ANIMATION_HOLD_EPSILON = 0.05
-- The client fades the body over CHARACTER_FADE_DURATION (1s) once fully
-- dead. The held track is released only after that fade, so the humanoid
-- never visibly pops back to standing under a still-visible body.
local DEATH_ANIMATION_RELEASE_DELAY = 2
local ALL_DEAD_TELEPORT_DELAY = 6

-- The revive decision window. One source of truth with the client bar
-- (GameOverGradientInterfaceController), which nonetheless counts down to
-- the replicated `windowEndsAtServerTime` rather than this constant.
local DEATH_WINDOW_SECONDS = DeathCinematicData.GameOverDuration
-- The window OPENS when the client's bar flies in, not at the downing:
-- the client spends the impact beat and the startup pause first, and a
-- window measured from the downing had the bar appear already a third
-- drained. Same constants the client paces itself on.
local DEATH_WINDOW_LEAD_SECONDS = DeathCinematicData.GameOverImpactDelay + DeathCinematicData.GameOverStartupDelay

-- Paid revive. The dev product is prompted server-side only (and only
-- while downed); ProcessReceipt is the sole production caller of :Revive.
local REVIVE_CUTSCENE_DURATION = 4
local FADE_DURATION = 0.4
local REVIVE_PRODUCT_ID = 3598188186

--[ Properties ]--

LifeService._lives = {} :: { [number]: { current: number, max: number } }
LifeService._deathState = {} :: { [number]: DeathEntry }
LifeService._deathAnimationTracks = {} :: { [number]: AnimationTrack }
-- The Heartbeat poll that freezes each death track on its last frame.
LifeService._deathAnimationHolds = {} :: { [number]: RBXScriptConnection }
-- Token per open revive window; the expiry callback aborts if a revive
-- (or a leave) replaced or cleared it.
LifeService._deathWindowTokens = {} :: { [number]: any }
LifeService._lobbyTeleportToken = nil :: any

LifeService.OnLifeLost = Signal.new() -- (player)
-- DOWNED: the player is out of lives and the revive window just opened.
-- Listeners that treat the player as gone for good belong on
-- OnPlayerFullyDied instead.
LifeService.OnPlayerDied = Signal.new() -- (player)
-- The window closed with no revive. isWipe: this was the last connected
-- player still not fully dead, so the run is over (GameOver follows).
LifeService.OnPlayerFullyDied = Signal.new() -- (player, isWipe: boolean)
-- Every connected player is fully dead. Fires AFTER OnPlayerFullyDied on
-- a death-triggered wipe (lastPlayer = who closed it) and on its own,
-- lastPlayer = nil, when the wipe was completed by a player LEAVING.
LifeService.OnPartyWiped = Signal.new() -- (lastPlayer: Player?)
LifeService.OnPlayerRevived = Signal.new() -- (player)

--[ Private helpers ]--

-- Publishes the current LivesData snapshot to clients.
function LifeService._replicateLives(self: typeof(LifeService))
	local snapshot = {}
	for userId, entry in self._lives do
		snapshot[userId] = { current = entry.current, max = entry.max }
	end
	self._livesProperty:Set(snapshot)
end

-- The wire shape every client reader (LifeController, TombstoneController,
-- the Game Over screen) sees. diedAtClock stays server-side: it is an
-- os.clock() race token, meaningless on another machine.
function LifeService._replicateDeathState(self: typeof(LifeService))
	local snapshot = {}
	for userId, entry in self._deathState do
		snapshot[userId] = {
			phase = entry.phase,
			diedAtServerTime = entry.diedAtServerTime,
			windowStartsAtServerTime = entry.windowStartsAtServerTime,
			windowEndsAtServerTime = entry.windowEndsAtServerTime,
			fullyDiedAtServerTime = entry.fullyDiedAtServerTime,
			deathPosition = entry.deathPosition,
			player = Players:GetPlayerByUserId(userId),
		}
	end
	self._deathStateProperty:Set(snapshot)
end

-- Plays the death animation and FREEZES IT ON ITS FINAL FRAME. A
-- non-looped track stops itself at its end and the humanoid snaps back to
-- its idle pose, so the track is polled each Heartbeat and its speed set
-- to 0 just before the end is reached. The hold lasts until
-- _stopDeathAnimation: a revive while downed, the post-fade release after
-- full death, or the player leaving. The track is never stopped while the
-- body is still on show.
function LifeService._playDeathAnimation(self: typeof(LifeService), player: Player)
	local userId = player.UserId

	self:_stopDeathAnimation(userId)

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		return
	end

	local animation = Instance.new("Animation")
	animation.AnimationId = DEATH_ANIMATION_ID

	local track = animator:LoadAnimation(animation)
	track.Priority = Enum.AnimationPriority.Action4
	track.Looped = false

	track:Play()
	track:AdjustSpeed(DEATH_ANIMATION_SPEED)
	self._deathAnimationTracks[userId] = track

	-- Length reads 0 until the asset has loaded; the poll simply waits
	-- for a real value. If the track somehow stops before the hold
	-- engages (asset failed to load), the poll ends with it.
	self._deathAnimationHolds[userId] = RunService.Heartbeat:Connect(function()
		if self._deathAnimationTracks[userId] ~= track then
			self:_releaseDeathAnimationHold(userId)
			return
		end
		if not track.IsPlaying then
			self:_releaseDeathAnimationHold(userId)
			return
		end
		local length = track.Length
		if length <= 0 then
			return
		end
		if track.TimePosition >= length - DEATH_ANIMATION_HOLD_EPSILON then
			track:AdjustSpeed(0)
			self:_releaseDeathAnimationHold(userId)
		end
	end)
end

-- Disconnects the last-frame poll only; the track keeps whatever speed it
-- has (0 once the hold engaged).
function LifeService._releaseDeathAnimationHold(self: typeof(LifeService), userId: number)
	local hold = self._deathAnimationHolds[userId]
	if hold then
		hold:Disconnect()
		self._deathAnimationHolds[userId] = nil
	end
end

-- Stops the death animation for `userId` if one is active. Idempotent.
function LifeService._stopDeathAnimation(self: typeof(LifeService), userId: number)
	self:_releaseDeathAnimationHold(userId)
	local track = self._deathAnimationTracks[userId]
	if not track then
		return
	end
	track:Stop(0)
	track:Destroy()
	self._deathAnimationTracks[userId] = nil
end

-- True iff every connected player is FULLY dead (phase "dead"). A downed
-- player still counts as in the fight: their window may end in a revive.
-- `excluding` leaves one player out -- the one mid PlayerRemoving, who is
-- still in Players:GetPlayers() while the handlers run. Returns false on
-- an empty server so a teleport never fires when nobody's even here.
function LifeService._areAllPlayersDead(self: typeof(LifeService), excluding: Player?): boolean
	local counted = 0
	for _, player in Players:GetPlayers() do
		if player == excluding then
			continue
		end
		counted += 1
		local entry = self._deathState[player.UserId]
		if not entry or entry.phase ~= "dead" then
			return false
		end
	end
	return counted > 0
end

-- Fires OnTeleportToLobby (clients dismiss spectate / fade / cinematic UI),
-- waits a short grace period, then TeleportAsyncs every player to the lobby
-- place. pcall'd because TeleportService throws if the place isn't published
-- or the studio session isn't set up for cross-place teleport — we want a
-- warn, not a crashed service.
--
-- Public so other services (DungeonService on Boss defeat, etc.) can drive
-- the lobby teleport without duplicating the OnTeleportToLobby fire +
-- TeleportAsync + pcall scaffolding. The party-wipe path that originally
-- owned this method now goes through the public name too.
function LifeService.TeleportAllToLobby(_self: typeof(LifeService))
	local players = Players:GetPlayers()

	if #players == 0 then
		return
	end

	PlayerNetwork.TeleportToLobby.FireAll()

	-- Re-fetch in case anyone left during the grace window. TeleportAsync
	-- on an empty list throws.
	players = Players:GetPlayers()
	if #players == 0 then
		return
	end

	local ok, err = pcall(function()
		TeleportService:TeleportAsync(Constants.LOBBY_PLACE_ID, players)
	end)
	if not ok then
		warn(("[LifeService] Lobby teleport failed: %s"):format(tostring(err)))
	end
end

-- ONE player to the lobby place -- the run-loop ExitPortal (extraction).
-- The rest of the server keeps running. Fires the same client
-- OnTeleportToLobby cue for that player.
-- Returns true if the teleport was ISSUED (Studio can't teleport at all, so
-- callers must be able to tell and not strand the player).
function LifeService.TeleportPlayerToLobby(_self: typeof(LifeService), player: Player): boolean
	if not player or not player.Parent then
		return false
	end
	if RunService:IsStudio() then
		warn(
			("[LifeService] Studio: lobby teleport for %s skipped (TeleportAsync is unavailable in Studio)"):format(
				player.Name
			)
		)
		return false
	end
	PlayerNetwork.TeleportToLobby.Fire(player)
	local ok, err = pcall(function()
		TeleportService:TeleportAsync(Constants.LOBBY_PLACE_ID, { player })
	end)
	if not ok then
		warn(("[LifeService] Lobby teleport failed for %s: %s"):format(player.Name, tostring(err)))
		return false
	end
	return true
end

-- Schedules the all-dead lobby teleport. Token-stamped so:
--   1. A re-schedule (another wipe evaluation while one is pending)
--      supersedes the old token, leaving the prior callback to abort
--      harmlessly
--   2. The "are still all dead?" re-check at fire time handles the rare race
--      where a player joins mid-window (joiners aren't in death state, so
--      _areAllPlayersDead returns false → teleport aborts)
function LifeService._scheduleLobbyTeleport(self: typeof(LifeService))
	local token = {}
	self._lobbyTeleportToken = token

	task.delay(ALL_DEAD_TELEPORT_DELAY, function()
		if self._lobbyTeleportToken ~= token then
			return -- cancelled by revive or superseded by re-schedule
		end
		if not self:_areAllPlayersDead() then
			return -- party-wipe condition no longer holds (rare: late joiner)
		end
		self._lobbyTeleportToken = nil
		-- DEBUG (2026-09): the party-wipe lobby teleport is disabled so a
		-- wiped party stays in the dungeon for inspection. Restore the
		-- call below to re-enable it.
		warn("[LifeService] Party wiped -- lobby teleport disabled for debugging (see _scheduleLobbyTeleport)")
		-- self:TeleportAllToLobby()
	end)
end

-- The run is over: every connected player is fully dead. `lastPlayer` is
-- the one whose window just closed, or nil when a leaver completed the
-- wipe. Broadcasts GameOver, fires OnPartyWiped and schedules the
-- teleport. Re-entrant only after a revive cleared _isGameOver.
function LifeService._onPartyWiped(self: typeof(LifeService), lastPlayer: Player?)
	self._isGameOver = true
	PlayerNetwork.GameOver.FireAll()
	self.OnPartyWiped:Fire(lastPlayer)
	print(
		("[LifeService] Party wipe (%s) — lobby teleport scheduled in %.2fs"):format(
			if lastPlayer then lastPlayer.Name .. " was the last" else "last player left",
			ALL_DEAD_TELEPORT_DELAY
		)
	)
	self:_scheduleLobbyTeleport()
end

-- DOWNED -> DEAD. The window expired (or was never going to be answered:
-- see the leave path) with no revive. Stamps the phase, tells everyone,
-- and evaluates the wipe. Everything that treats the player as gone for
-- good hangs off the signals fired here.
function LifeService._finalizeDeath(self: typeof(LifeService), player: Player)
	local userId = player.UserId
	local entry = self._deathState[userId]
	if not entry or entry.phase ~= "downed" then
		return
	end

	self._deathWindowTokens[userId] = nil
	entry.phase = "dead"
	entry.fullyDiedAtServerTime = workspace:GetServerTimeNow()
	self:_replicateDeathState()

	-- The client fades the body now; the frozen pose is released only once
	-- that fade has hidden it. Stamped against the entry so a revive-then-
	-- die-again inside the delay cannot stop the NEW death's track.
	task.delay(DEATH_ANIMATION_RELEASE_DELAY, function()
		if self._deathState[userId] == entry then
			self:_stopDeathAnimation(userId)
		end
	end)

	local isWipe = self:_areAllPlayersDead()
	if isWipe then
		self._isGameOver = true
	end

	-- isWipe rides the server signal: RunEscrowService spills the run gear
	-- on every full death and discards every escrow on a wipe, in that
	-- order.
	self.OnPlayerFullyDied:Fire(player, isWipe)
	PlayerNetwork.PlayerFullyDied.FireAll({ UserId = userId, IsWipe = isWipe })

	print(("[LifeService] %s fully died — spectate engaged"):format(player.Name))

	if isWipe then
		self:_onPartyWiped(player)
	end
end

--[ Public API ]--

-- Seeds (or resets) a player's lives to `max`. Called by DungeonService on
-- dungeon generation, and by OnPlayerAdded for late-joiners. Idempotent.
function LifeService.InitializePlayer(self: typeof(LifeService), player: Player, max: number)
	local userId = player.UserId
	self._lives[userId] = { current = max, max = max }
	self:_replicateLives()
end

-- Returns (current, max). Both zero if the player isn't registered yet.
function LifeService.GetLives(self: typeof(LifeService), player: Player): (number, number)
	local entry = self._lives[player.UserId]
	if not entry then
		return 0, 0
	end
	return entry.current, entry.max
end

-- True in EITHER death phase (downed or fully dead): the player cannot act.
function LifeService.IsDeathState(self: typeof(LifeService), player: Player): boolean
	return self._deathState[player.UserId] ~= nil
end

-- True only while the revive window is open.
function LifeService.IsDowned(self: typeof(LifeService), player: Player): boolean
	local entry = self._deathState[player.UserId]
	return entry ~= nil and entry.phase == "downed"
end

-- True only once the window closed with no revive (phase "dead").
function LifeService.IsFullyDead(self: typeof(LifeService), player: Player): boolean
	local entry = self._deathState[player.UserId]
	return entry ~= nil and entry.phase == "dead"
end

-- Connected players who are still IN the run: alive or downed. A downed
-- player may yet buy a revive, so they count; a fully dead one does not.
-- `excluding` leaves out a player mid PlayerRemoving (still listed by
-- Players:GetPlayers() while its handlers run). EnemyScalingService's
-- multiplier is built on this.
function LifeService.GetActivePlayerCount(self: typeof(LifeService), excluding: Player?): number
	local count = 0
	for _, player in Players:GetPlayers() do
		if player == excluding then
			continue
		end
		if self:IsFullyDead(player) then
			continue
		end
		count += 1
	end
	return count
end

-- Where the player's HumanoidRootPart was when they went down, for
-- callers that need the corpse's spot after the character is gone
-- (RunEscrowService spills run gear there). The body never moves between
-- downed and dead, so the one position serves both phases. nil when not
-- in the death state, or when no root part could be read at the time.
function LifeService.GetDeathPosition(self: typeof(LifeService), player: Player): Vector3?
	local state = self._deathState[player.UserId]
	if not state or state.deathPosition == Vector3.zero then
		return nil
	end
	return state.deathPosition
end

-- Called by DamageService when damage would have killed the player.
-- Decrements lives and either restores HP in place (lives left) or
-- DOWNS the player (no lives left): the revive window opens here, and
-- _finalizeDeath closes it.
function LifeService.LoseLife(self: typeof(LifeService), player: Player)
	local userId = player.UserId
	local entry = self._lives[userId]
	if not entry then
		warn(("[LifeService] LoseLife called for unregistered player %s"):format(player.Name))
		return
	end

	-- Already down — don't double-decrement on lingering hits.
	if self._deathState[userId] then
		return
	end

	entry.current = math.max(entry.current - 1, 0)
	self:_replicateLives()

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")

	if entry.current > 0 then
		local head = character and character:FindFirstChild("Head") :: BasePart?
		if TextIndicatorService and head then
			if entry.current == 1 then
				TextIndicatorService:ShowIndicator(player, head, "Last Life!", Color3.fromRGB(255, 74, 74))
			else
				TextIndicatorService:ShowIndicator(player, head, "Death Defied!", Color3.fromRGB(85, 255, 127))
			end
		end

		-- Still has lives — full HP restore + brief i-frames.
		if humanoid then
			humanoid.Health = humanoid.MaxHealth
		end

		-- ApplyTo itself no-ops on a nil character; the guard only narrows the type.
		if character then
			-- "Combat": earned in play, so the white highlight shows.
			InvulnerabilityService:ApplyTo(character, POST_LIFE_LOSS_INVULN_SECONDS, "Combat")
		end

		self.OnLifeLost:Fire(player)
		PlayerNetwork.LifeLost.FireAll(userId)
		print(("[LifeService] %s lost a life. Remaining: %d/%d"):format(player.Name, entry.current, entry.max))
		return
	end

	-- Out of lives: DOWNED. Attributes.Death=true and the frozen death pose
	-- happen now; the body stays where it fell, fully visible, and nothing
	-- is spilled or discarded until the window closes without a revive.
	if character then
		character:SetAttribute(Attributes.Death, true)
	end

	local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local deathPosition = (hrp and hrp.Position) or Vector3.zero

	local deathClock = os.clock()
	local now = workspace:GetServerTimeNow()
	local deathEntry: DeathEntry = {
		phase = "downed",
		diedAtClock = deathClock,
		diedAtServerTime = now,
		windowStartsAtServerTime = now + DEATH_WINDOW_LEAD_SECONDS,
		windowEndsAtServerTime = now + DEATH_WINDOW_LEAD_SECONDS + DEATH_WINDOW_SECONDS,
		fullyDiedAtServerTime = nil,
		deathPosition = deathPosition,
	}
	self._deathState[userId] = deathEntry

	self:_replicateDeathState()

	self.OnPlayerDied:Fire(player)
	PlayerNetwork.PlayerDied.FireAll(userId)

	if character then
		RagdollService:Unragdoll(character)

		-- The party learns of the fall at once: the teammate is on the
		-- floor either way, and a revive gets its own notification.
		for _, playerIndex in pairs(Players:GetPlayers()) do
			if player == playerIndex then
				continue
			end

			UserNotificationService:RequestUserNotification(playerIndex, {
				titleText = "Eternal Damnation",
				titleTextFont = Enum.Font.SourceSansBold,
				titleTextColor3 = Color3.fromRGB(252, 83, 83),
				titleTextTransparency = 0,

				text = player.Name .. " was claimed by the Spire.",
				textFont = Enum.Font.SourceSansBold,
				textColor3 = Color3.fromRGB(255, 255, 255),
				textTransparency = 0,
			})
		end

		self:_playDeathAnimation(player)

		local head = character:FindFirstChild("Head") :: BasePart?
		if TextIndicatorService and head then
			TextIndicatorService:ShowIndicator(player, head, "Eternally Damned!", Color3.fromRGB(247, 67, 67))
		end
	end

	-- The window. Its token is cleared by a revive (Revive) or a leave
	-- (OnPlayerRemoved), and the entry identity is re-checked so a
	-- revive-then-down-again inside one window cannot close the new one.
	local windowToken = {}
	self._deathWindowTokens[userId] = windowToken
	-- Lead + window: the timer must land on the same beat the replicated
	-- windowEndsAtServerTime names, or the server closes the window while
	-- the client's bar still shows time left.
	task.delay(DEATH_WINDOW_LEAD_SECONDS + DEATH_WINDOW_SECONDS, function()
		if self._deathWindowTokens[userId] ~= windowToken then
			return
		end
		if self._deathState[userId] ~= deathEntry then
			return
		end
		self:_finalizeDeath(player)
	end)

	print(("[LifeService] %s is downed — %.0fs to revive"):format(player.Name, DEATH_WINDOW_SECONDS))
end

-- Increments lives, capped at max. Use for relic/event grants.
function LifeService.AddLife(self: typeof(LifeService), player: Player)
	local entry = self._lives[player.UserId]
	if not entry then
		return
	end
	entry.current = math.min(entry.current + 1, entry.max)
	self:_replicateLives()
end

-- Revive, in EITHER phase. Sequence: fade to black, release the death
-- pose, un-ragdoll, (fully dead only) teleport to the spectated party's
-- current room, restore health, fade back, invuln windows, clear death
-- state, lives back to 1. A DOWNED player stands up IN PLACE: the body is
-- right there and nothing spilled, so there is nothing to teleport to or
-- recover. ProcessReceipt and the /revive debug command call this.
--
-- Escrow note: a fully dead player's run gear already spilled out of the
-- corpse (RunEscrowService). Revive does NOT restore it -- you buy your
-- way back to your feet, then walk over and pick it up.
function LifeService.Revive(self: typeof(LifeService), player: Player)
	local userId = player.UserId
	local entry = self._deathState[userId]
	if not entry then
		return
	end
	local wasDowned = entry.phase == "downed"
	print(("[LifeService] %s revive sequence starting (%s)"):format(player.Name, entry.phase))

	-- Close the revive window (no expiry may land mid-sequence), cancel a
	-- pending all-dead lobby teleport and clear Game Over if the wipe
	-- screen already went up -- a revive un-wipes the party.
	self._deathWindowTokens[userId] = nil
	self._lobbyTeleportToken = nil

	self._isGameOver = false

	PlayerNetwork.RevivalFade.Fire(player, { Phase = "in", Duration = FADE_DURATION })

	for _, playerIndex in pairs(Players:GetPlayers()) do
		UserNotificationService:RequestUserNotification(playerIndex, {
			titleText = "Player Revive",
			titleTextFont = Enum.Font.SourceSansBold,
			titleTextColor3 = Color3.fromRGB(85, 255, 127),
			titleTextTransparency = 0,

			text = player.Name .. " has been revived!",
			textFont = Enum.Font.SourceSansBold,
			textColor3 = Color3.fromRGB(255, 255, 255),
			textTransparency = 0,
		})
	end

	task.wait(FADE_DURATION)

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")

	self:_stopDeathAnimation(userId)

	if RagdollService and character then
		RagdollService:Unragdoll(character)
	end

	-- Fully dead: the party has moved on and the body is invisible, so
	-- rejoin them. Downed: the fight is right here; stand up where you fell.
	if not wasDowned and character and getDungeonService() then
		local room = getDungeonService():GetPlayerRoom(player)
		if room and room.model and room.model.PrimaryPart then
			character:PivotTo(CFrame.new(room.model.PrimaryPart.Position + Vector3.new(0, 5, 0)))
		end
	end

	if humanoid then
		humanoid.Health = humanoid.MaxHealth
	end

	PlayerNetwork.RevivalFade.Fire(player, { Phase = "out", Duration = FADE_DURATION })

	self.OnPlayerRevived:Fire(player)
	PlayerNetwork.PlayerRevived.FireAll(userId)

	if character then
		-- Two windows, not one: the revive cinematic is a Cutscene (no
		-- highlight; the fade and the stand-up are the feedback) and the
		-- grace after it is Combat (highlight on, like a life loss). The
		-- service keeps the UNION open, so the cutscene window closing never
		-- cuts the grace short, and the reason flips to Combat the moment
		-- only the grace remains.
		InvulnerabilityService:ApplyTo(character, REVIVE_CUTSCENE_DURATION, "Cutscene")
		InvulnerabilityService:ApplyTo(character, REVIVE_CUTSCENE_DURATION + POST_LIFE_LOSS_INVULN_SECONDS, "Combat")
	end

	task.wait(REVIVE_CUTSCENE_DURATION)

	if character then
		character:SetAttribute(Attributes.Death, false)
	end

	local lives = self._lives[userId]
	if lives then
		-- Stand up at lives = 1. Next death = same flow.
		lives.current = 1
		self:_replicateLives()
	end

	-- Only clear the entry this revive started on: a leave during the
	-- cutscene already removed it, and must not have a stale write undone.
	if self._deathState[userId] == entry then
		self._deathState[userId] = nil
		self:_replicateDeathState()
	end

	print(("[LifeService] %s revived. Lives reset to 1."):format(player.Name))
end

--[ Lifecycle ]--

function LifeService.Start(self: typeof(LifeService))
	PlayerNetwork.PromptRevivePurchase.On(function(player: Player)
		self:_onPromptRevivePurchase(player)
	end)

	if getDungeonService() and getDungeonService().Signals and getDungeonService().Signals.OnDungeonGenerated then
		getDungeonService().Signals.OnDungeonGenerated:Connect(function(dungeon)
			-- Lives are PER RUN: seeded when the run's FIRST dungeon generates and
			-- carried across dungeons 2 / 3 -- a later dungeon must not refill them.
			if getDungeonService().GetRunDungeonIndex and getDungeonService():GetRunDungeonIndex() > 1 then
				return
			end
			local dungeonConfig = DungeonData[dungeon.id]
			local difficultyConfig = dungeonConfig and dungeonConfig.difficulties[dungeon.difficulty]
			local maxLives = (difficultyConfig and difficultyConfig.freeRevives) or DEFAULT_LIVES

			for _, player in Players:GetPlayers() do
				self:InitializePlayer(player, maxLives)
			end
		end)
	end

	PlayerEventService.OnPlayerAdded:Connect(function(player: Player)
		local maxLives = DEFAULT_LIVES
		if getDungeonService() then
			local active = getDungeonService():GetActiveDungeon()
			if active then
				local dungeonConfig = DungeonData[active.id]
				local difficultyConfig = dungeonConfig and dungeonConfig.difficulties[active.difficulty]
				if difficultyConfig and difficultyConfig.freeRevives then
					maxLives = difficultyConfig.freeRevives
				end
			end
		end
		self:InitializePlayer(player, maxLives)
	end)

	PlayerEventService.OnPlayerRemoved:Connect(function(player: Player)
		local userId = player.UserId
		self._lives[userId] = nil
		self._deathState[userId] = nil
		self._deathWindowTokens[userId] = nil
		self:_replicateLives()
		self:_replicateDeathState()
		self:_stopDeathAnimation(userId)

		-- The leaver may have been the last player not fully dead (alive,
		-- or downed with a window that will now never close): if everyone
		-- still here is fully dead, the run is over. The leaver is still
		-- in Players:GetPlayers() at this point, hence the exclusion.
		if not self._isGameOver and self:_areAllPlayersDead(player) then
			self:_onPartyWiped(nil)
		end
	end)

	MarketplaceService.ProcessReceipt = function(receiptInfo)
		if receiptInfo.ProductId ~= REVIVE_PRODUCT_ID then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
		if not player then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		-- Grant WITHOUT reviving if they somehow stood up already -- eating
		-- the robux on a no-op is worse than the refund dance, and Roblox
		-- retries NotProcessedYet receipts forever. Either death phase
		-- revives: only the PROMPT is gated on the window, a receipt that
		-- lands after it closed was still paid for.
		if not self:IsDeathState(player) then
			warn(("[LifeService] Revive receipt for %s but they're not in death state"):format(player.Name))
			return Enum.ProductPurchaseDecision.PurchaseGranted
		end

		self:Revive(player)
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
end

--[ Client-callable API ]--

-- Client requests the revive purchase prompt. Server-initiated so the dev
-- product flow can't be spoofed; validates the window is actually open
-- before prompting -- once fully dead there is no button and no prompt.
function LifeService._onPromptRevivePurchase(self: typeof(LifeService), player: Player)
	if not self:IsDowned(player) then
		warn(("[LifeService] %s tried to prompt revive but isn't downed"):format(player.Name))
		return
	end
	MarketplaceService:PromptProductPurchase(player, REVIVE_PRODUCT_ID)
end

return LifeService
