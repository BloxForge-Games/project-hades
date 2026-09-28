--!strict
--[[
     Author(s):
     Module: LandingService.lua
     Description: The dungeon-entry landing cinematic: a joining player (or
                  the whole party at a floor transition) is posed into the
                  landing animation's first frame off-map, teleported onto the
                  Start room already posed, held there until every client has
                  the pose, then revealed and dropped. Fires the
                  LandingStart / LandingImpact / LandingEnd cues the clients
                  play off, and drops the run's starter relic machine.
                  LobbyLandingService mirrors this for the lobby.
]]

--[ Roblox Services ]--

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

--[ Exports & Types & Defaults ]--

local DungeonService = require(ServerScriptService.Services.DungeonService)
local DungeonGenerator = require(ServerScriptService.Services.DungeonGenerator)
local RunFlowService = require(ServerScriptService.Services.RunFlowService)
local PlayerEventService = require(ServerScriptService.Submodules.Core.Source.Services.PlayerEventService)
local DungeonNetwork = require(ServerScriptService.Submodules.Core.Source.Network.Dungeon)
local Blitz = require(ReplicatedStorage.Submodules.Core.Shared.Blitz)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local ScreenSweepData = require(ReplicatedStorage.Submodules.Core.Shared.Data.ScreenSweepData)

type Dungeon = DungeonService.Dungeon

local LandingService = {
	Name = "LandingService",
	Dependencies = { DungeonService, DungeonGenerator, RunFlowService, PlayerEventService } :: { any },
}

--[ Constants ]--

local START_SPAWN_NAME = "StartCFrame"
local START_SPAWN_FALLBACK_OFFSET = Vector3.new(0, 5, 0)

-- Join landing timeline. The character spawns at the off-map staging spawn, is
-- posed into the animation's first (+25-stud) frame WHILE STILL THERE (hidden),
-- then teleported in already-posed so there's no default→+25 "snap", and dropped
-- via the animation. START_DELAY holds briefly so armor/weapons finish welding
-- before posing; POSE_SETTLE lets the frozen pose replicate to every client
-- before the teleport; DROP_SPEED is the playback speed of the drop; IMPACT /
-- DURATION are measured from the drop start (impact VFX, then unanchor + relic).
-- 1s (was 2): the loader is already down for the assets and the character's
-- gear welds well inside a second; the join felt slow behind the loader.
local LANDING_START_DELAY = 0
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
-- Per-player random delay before the reveal + drop, so a party that spawned
-- in together does not all hit the ground on the same frame: the slots
-- already spread them in SPACE (LANDING_SPREAD_STUDS), this spreads them in
-- TIME. Everything after the reveal (impact, end) is relative to it, so the
-- whole landing shifts as one.
local LANDING_STAGGER_MIN_SECONDS = 0.1
local LANDING_STAGGER_MAX_SECONDS = 0.5
local LANDING_DURATION = 1.7
-- Join landing: the drop waits until the screen is fully revealed (the
-- loader fade, then the cascade, both started by the landing cue) and a
-- further beat, so the player SEES themselves fall rather than landing
-- under the tiles.
local LANDING_DROP_AFTER_REVEAL_SECONDS = 0.35
local JOIN_DROP_DELAY_SECONDS = ScreenSweepData.JoinRevealSeconds + LANDING_DROP_AFTER_REVEAL_SECONDS

-- Landing spread: players fan out sideways from the start CFrame so a
-- party doesn't land in one overlapping pile.
local LANDING_SPREAD_STUDS = 5
-- Horizontal drift from the landing spot past which the server snaps the
-- root back during the fall (see _holdLandingPosition).
local LANDING_HOLD_TOLERANCE_STUDS = 2

-- Transition landings (dungeon 2+): screen stays black through generation
-- and the teleport, then holds this long ON the new start room before the
-- reveal + drop -- so nobody ever sees the swap or a not-yet-replicated
-- teleport. The 2s join-time welding delay is skipped (gear is welded).
local RUN_TRANSITION_PRE_TELEPORT_SECONDS = 0.5
local RUN_TRANSITION_REVEAL_HOLD_SECONDS = 1

--[ Properties ]--

LandingService._readyForLanding = {} :: { [Player]: true } -- client preload finished (per join)
LandingService._landed = {} :: { [Player]: Dungeon } -- the dungeon the player already landed in

--[ Private Functions ]--

function LandingService._teleportPlayerToStart(_self: typeof(LandingService), dungeon: Dungeon, player: Player): CFrame?
	local marker = DungeonGenerator:FindAnchor(dungeon.startModel, START_SPAWN_NAME, true)
	local spawnCFrame: CFrame
	if marker then
		spawnCFrame = DungeonGenerator:AnchorCFrame(marker) :: CFrame
	else
		-- Loud, not silent: "landed somewhere near the start" looked like a
		-- random teleport failure from the outside.
		warn(
			("[LandingService] %s has no %q marker -- landing at its pivot + %s instead"):format(
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

	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
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
function LandingService._holdLandingPosition(
	_self: typeof(LandingService),
	character: Model,
	hrp: BasePart,
	targetCFrame: CFrame,
	dungeon: Dungeon,
	seconds: number
)
	task.spawn(function()
		local deadline = os.clock() + seconds
		while os.clock() < deadline do
			RunService.Heartbeat:Wait()
			if not character.Parent or not hrp.Parent or DungeonService:GetActiveDungeon() ~= dungeon then
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

function LandingService._runPlayerLanding(self: typeof(LandingService), player: Player)
	local dungeon = DungeonService:GetActiveDungeon()
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
	local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not character or not humanoid or not hrp then
		return
	end
	-- Run loop: players who extracted through a portal are gone; players who
	-- are DEAD at the transition stay dead (they spectate the next dungeon
	-- until a revive) -- neither lands.
	if DungeonService:IsPlayerExited(player) then
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
		local isTransitionLanding = DungeonService:GetRunDungeonIndex() > 1
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
		RunFlowService:ReleaseTransitionFreeze(player)
		if targetCFrame then
			local holdSeconds = LANDING_POSE_HOLD_SECONDS + LANDING_DURATION
			if isTransitionLanding then
				holdSeconds += RUN_TRANSITION_REVEAL_HOLD_SECONDS
			else
				holdSeconds += JOIN_DROP_DELAY_SECONDS
			end
			self:_holdLandingPosition(character, hrp, targetCFrame, dungeon, holdSeconds)
		end

		-- HOLD the frozen first frame in place. The screen is still dark, so
		-- this is invisible to the player — it exists purely so the pose
		-- has replicated and rendered on every client before anyone can see
		-- it. Only then does the reveal come, and the drop with it.
		task.wait(LANDING_POSE_HOLD_SECONDS)
		if not character.Parent or not hrp.Parent or DungeonService:GetActiveDungeon() ~= dungeon then
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
			if not character.Parent or DungeonService:GetActiveDungeon() ~= dungeon then
				-- Floor swapped out from under the landing: un-mark, or this
				-- character stays invisible-attachment forever.
				if character.Parent then
					character:SetAttribute(Attributes.Landing, nil)
				end
				return
			end
		end

		-- Stagger (see LANDING_STAGGER_*). Re-checked after the wait like the
		-- holds above: the character or the floor can go away in it.
		task.wait(
			LANDING_STAGGER_MIN_SECONDS + math.random() * (LANDING_STAGGER_MAX_SECONDS - LANDING_STAGGER_MIN_SECONDS)
		)
		if not character.Parent or not hrp.Parent or DungeonService:GetActiveDungeon() ~= dungeon then
			if character.Parent then
				character:SetAttribute(Attributes.Landing, nil)
			end
			if not character.Parent or not hrp.Parent then
				self._landed[player] = nil
			end
			return
		end

		-- Reveal: fade the joiner's loading screen (or the transition black)
		-- + lock controls. Carries the landing CFrame: the client OWNS its
		-- root, so its own snap to it is the authoritative one.
		DungeonNetwork.LandingStart.Fire(player, targetCFrame)

		-- Join only: hold the frozen pose until the screen has revealed.
		-- A run transition fades back in over the drop instead.
		if not isTransitionLanding then
			task.wait(JOIN_DROP_DELAY_SECONDS)
			if not character.Parent or not hrp.Parent or DungeonService:GetActiveDungeon() ~= dungeon then
				if character.Parent then
					character:SetAttribute(Attributes.Landing, nil)
				end
				if not character.Parent or not hrp.Parent then
					self._landed[player] = nil
				end
				return
			end
		end

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
			DungeonNetwork.LandingImpact.FireAll(player)
		end)

		-- End — unanchor + restore controls, then drop the relic machine.
		task.delay(LANDING_DURATION, function()
			-- Touched down: attachments may draw again (the clients fade
			-- them in off this edge).
			if character.Parent then
				character:SetAttribute(Attributes.Landing, nil)
			end
			DungeonNetwork.LandingEnd.Fire(player)

			-- The free "starter" vending machine drops ONLY on the run's FIRST
			-- dungeon (Hades-style: one free pick when the run begins). Landing
			-- in dungeon 2 / 3 after a boss gets no machine -- the boss's own
			-- rewards were the payoff.
			if isTransitionLanding then
				return
			end
			task.delay(2.5, function()
				-- A consumer of DungeonService: resolved at call time, never required.
				local RelicMachineService = Blitz.OptionalService("RelicMachineService")
				if RelicMachineService then
					-- STARTER machine: forces one ungated relic from each of
					-- the run's two elements (see RelicMachine).
					RelicMachineService:DropMachineOnPlayer(player, true)
				end
			end)
		end)
	end)
end

function LandingService._onLandingImpact(_self: typeof(LandingService), player: Player)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end

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
-- stay queued and OnFloorReady lands every ready player.
function LandingService._markReadyAndMaybeLand(self: typeof(LandingService), player: Player)
	self._readyForLanding[player] = true
	if DungeonService:GetActiveDungeon() then
		self:_runPlayerLanding(player)
	end
end

--[ Initializers ]--

function LandingService.Start(self: typeof(LandingService))
	DungeonService.Signals.OnFloorReady:Connect(function()
		DungeonNetwork.DungeonGenerated.FireAll()

		-- New dungeon → everyone re-lands at the new start. Land every player
		-- whose client already finished preloading; the rest land when their
		-- own OnPlayerAdded (preload-done) fires. _landed is keyed by dungeon,
		-- so a player already landing in THIS dungeon is skipped (it is cleared
		-- on OnFloorTeardown, below).
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
	-- generated yet the player is queued and lands on OnFloorReady.
	PlayerEventService.OnPlayerAdded:Connect(function(player)
		DungeonNetwork.DungeonGenerated.Fire(player)
		self:_markReadyAndMaybeLand(player)
	end)

	-- The floor is going: nobody has landed in the next one yet.
	DungeonService.Signals.OnFloorTeardown:Connect(function()
		table.clear(self._landed)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		self._readyForLanding[player] = nil
		self._landed[player] = nil
	end)
end

return LandingService
