--[[
     Author(s): 
     Module: PlayerStateController.lua
     Description:
]]

--[ Roblox Services ]--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

--[ Exports & Types & Defaults ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local ValueNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ValueNames)
local HumanoidProperties = require(ReplicatedStorage.Submodules.Core.Shared.Data.HumanoidProperties)
local MagicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.MagicData)
local getEffectiveBaseWalkSpeed =
	require(ReplicatedStorage.Submodules.Core.Shared.Functions.Movement.getEffectiveBaseWalkSpeed)
local getEffectiveJetpackWalkSpeed =
	require(ReplicatedStorage.Submodules.Core.Shared.Functions.Movement.getEffectiveJetpackWalkSpeed)

local BuildController
local CinematicInterfaceController
local AimController
local CastModeController
local MagicController
local DialogueBillboardInterface
local DialogueBillboardService

local PlayerStateController = Knit.CreateController({
	Name = "PlayerStateController",
	Client = {},
})

--[ Imports ]--

--[ Constants ]--

-- STUCK-STATE WATCHDOG
--
-- Every action / movement lock in this game is a "set now, restore a
-- moment later" pair owned by some other system: dodge sets IsDodging and
-- clears it at dodge end, a cast sets MagicEnabled and clears it after the
-- spell duration, a swing drops WalkSpeed and restores it when the swing
-- animation finishes, the server flips MeleeWeaponEnabled off during a
-- swing and back on after the hitbox delay, and so on. Any of those
-- restores can be LOST — a frame spike, a lag hitch, or (mobile) the app
-- being backgrounded mid-action so the touch-release / delayed thread
-- never lands the way the owner expected. The symptom is always the same:
-- the player is alive but trapped — can't attack, can't cast, can't turn,
-- or can only crawl — until respawn.
--
-- The watchdog polls once a second and, for each CHECK below, tracks how
-- long its "trapped" condition has been CONTINUOUSLY true. Past the
-- check's threshold it runs the restore.
--
-- POLLING CANNOT SEE A FLICKER, which is a trap for any state that
-- toggles faster than the poll. A held attack drops MeleeWeaponEnabled
-- for each swing's hitbox delay (0.2-0.65s) and restores it between, so
-- consecutive polls can each land inside a DIFFERENT false window and
-- read as one unbroken stretch — the watchdog then "restored" a gate
-- that was never stuck and cut the swing. A check whose condition can
-- flicker therefore supplies `trappedSince` (below): a timestamp kept by
-- an attribute-change WATCHER, so a single genuine restore resets it and
-- only a truly continuous stretch can age past the threshold. Thresholds sit comfortably above
-- the longest legitimate window for that state (3s for sub-second
-- actions; spell duration + margin for casts; long for cutscenes), so the
-- watchdog can never race a real action in flight — it only fires when
-- the restore is provably lost. Because it keys off the trapped
-- CONDITION rather than a specific owner's bookkeeping, it also catches
-- restores skipped by design (e.g. the weapon components skip their
-- WalkSpeed restore when a gate is closed at swing end).
--
-- Not watched: RagdollTrigger (server-owned, long knockdowns are legit)
-- and Death (LifeController owns the dead state end to end).
--
-- THE WATCHDOG STANDS DOWN WHILE THE PLAYER IS ATTACKING. Its whole
-- purpose is a player who is trapped while doing NOTHING — alive, idle,
-- and unable to act. A player mid-combo is the opposite of that, and
-- every state below is legitimately held or flickering while they
-- weave swings and casts (WalkSpeed at the attack-slow value between a
-- swing and a cast, gates closing and opening, the flags handing off to
-- each other). Polling those mid-weave produced spurious restores that
-- CANCELLED healthy attacks. So: while an attack is actually being
-- executed for the player, and for WATCHDOG_ATTACK_GRACE_SECONDS after
-- the last one, every check's clock is held at zero. A genuinely stuck
-- player stops producing attacks (that is what stuck means), the grace
-- runs out, and the checks resume exactly as before.
--
-- "Attacking" is judged by OUTCOMES, not by the button: a swing the
-- server accepted, a cast that fired, or a weapon loop that is running
-- under live input. Pressing a button that does nothing is NOT
-- attacking — if it were, a stuck melee gate would suppress its own
-- rescue for as long as the player mashed it.
local WATCHDOG_CHECK_INTERVAL_SECONDS = 1
local WATCHDOG_STUCK_SECONDS = 2
local WATCHDOG_CUTSCENE_STUCK_SECONDS = 30 -- boss/miniboss cutscenes run long
-- How long after the last executed attack the watchdog stays stood down.
-- Covers the gap inside a weave (swing -> cast -> swing) with room to
-- spare; a player who has stopped attacking clears it in one breath.
local WATCHDOG_ATTACK_GRACE_SECONDS = 2

-- MagicEnabled legitimately stays true for the spell's full duration
-- (MagicController clears it after `duration`), so its threshold is the
-- LONGEST authored duration plus margin, read from MagicData rather than
-- guessed here — a new long spell can't silently start getting cut off.
local WATCHDOG_MAGIC_MARGIN_SECONDS = 2
local function longestSpellDuration(): number
	local longest = 0
	for _, magicIndex in MagicData do
		if typeof(magicIndex) == "table" and typeof(magicIndex.duration) == "number" then
			longest = math.max(longest, magicIndex.duration)
		end
	end
	return longest
end

--[ Properties ]--

-- os.clock() when MeleeWeaponEnabled last went false with no `true`
-- since; nil whenever the gate is open. Maintained by
-- _watchMeleeGate off the attribute's own change signal, because the
-- once-a-second poll cannot tell a swing loop's flicker from a stuck
-- gate (see the watchdog header).
PlayerStateController._meleeGateFalseSince = nil :: number?
-- os.clock() of the last attack the game EXECUTED for this player (a
-- server-accepted swing, a cast that fired). The watchdog stands down
-- for WATCHDOG_ATTACK_GRACE_SECONDS past it. See the watchdog header.
PlayerStateController._lastAttackActivity = 0 :: number

--[ Private Functions ]--

--[ Public Functions ]--

function PlayerStateController:AimActionEnabled(): boolean
	local player = Players.LocalPlayer

	if
		not player.Character
		or player.Character and player.Character:GetAttribute(Attributes.IsDodging) == true
		or player.Character and player.Character:FindFirstChild(ValueNames.RagdollTrigger) and player.Character:FindFirstChild(
			ValueNames.RagdollTrigger
		).Value == true
		or player.Character and player.Character:GetAttribute(Attributes.MagicEnabled) == true
		or Players.LocalPlayer.Character:GetAttribute(Attributes.CutscenePlaying) == true
		or Players.LocalPlayer.Character:GetAttribute(Attributes.Death) == true
		or Players.LocalPlayer.Character:GetAttribute(Attributes.TalkingToNPC) == true
	then
		return false
	end

	return true
end

function PlayerStateController:GeneralActionEnabled(): boolean
	if
		Players.LocalPlayer.Character:GetAttribute(Attributes.MagicEnabled) == true
		or Players.LocalPlayer.Character:GetAttribute(Attributes.IsDodging) == true
		or Players.LocalPlayer.Character:GetAttribute(Attributes.CutscenePlaying) == true
		or Players.LocalPlayer.Character:GetAttribute(Attributes.Death) == true
		-- Mid-NPC-conversation: no attacking, no spells, no dodge -- and the
		-- aim gate above blocks cursor rotation. Walking away still works and
		-- closes the dialogue, which clears the attribute.
		or Players.LocalPlayer.Character:GetAttribute(Attributes.TalkingToNPC) == true
		or BuildController:GetBuildMode() == true
		or Players.LocalPlayer.Character
			and Players.LocalPlayer.Character:FindFirstChild(ValueNames.RagdollTrigger)
			and Players.LocalPlayer.Character:FindFirstChild(ValueNames.RagdollTrigger).Value == true
	then
		return false
	end

	return true
end

function PlayerStateController:ToolBarActionEnabled(): boolean
	if
		Players.LocalPlayer.Character:GetAttribute(Attributes.MagicEnabled) == true
		or Players.LocalPlayer.Character:GetAttribute(Attributes.Death) == true
	then
		return false
	end

	return true
end

--[ Initializers ]--

-- Restores the local character's WalkSpeed to its relic-composed baseline
-- (jetpack-aware). The weapon components' own restores are GATED on
-- GeneralActionEnabled, so an attack whose active window overlaps a
-- cutscene starting (killing blow on a boss → outro) writes the slow
-- attack speed and then SKIPS the restore — leaving the player crawling
-- until their next completed attack. This is the unconditional back-stop.
function PlayerStateController:RestoreWalkSpeed()
	local character = Players.LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not character or not humanoid then
		return
	end
	if character:GetAttribute(Attributes.Death) == true then
		return -- LifeController owns the dead state's movement
	end
	local ragdollTrigger = character:FindFirstChild(ValueNames.RagdollTrigger)
	if ragdollTrigger and ragdollTrigger.Value == true then
		return -- knocked down: physics owns the body until unragdoll
	end

	if character:GetAttribute(Attributes.OnJetpack) == true then
		humanoid.WalkSpeed = getEffectiveJetpackWalkSpeed()
	else
		humanoid.WalkSpeed = getEffectiveBaseWalkSpeed(HumanoidProperties.WalkSpeed)
	end
end

-- Baseline WalkSpeed the character should hold in a NEUTRAL state (same
-- resolution RestoreWalkSpeed writes; jetpack-aware, relic-composed).
local function expectedBaseWalkSpeed(character: Model): number
	if character:GetAttribute(Attributes.OnJetpack) == true then
		return getEffectiveJetpackWalkSpeed()
	end
	return getEffectiveBaseWalkSpeed(HumanoidProperties.WalkSpeed)
end

-- True while some system LEGITIMATELY owns the character's movement or
-- actions right now — every state in which a sub-baseline WalkSpeed is
-- expected. The WalkSpeed check only counts time spent slow OUTSIDE these.
local function movementLegitimatelyLocked(character: Model): boolean
	if
		character:GetAttribute(Attributes.IsDodging) == true
		or character:GetAttribute(Attributes.MagicEnabled) == true
		or character:GetAttribute(Attributes.CutscenePlaying) == true
		or character:GetAttribute(Attributes.Death) == true
		-- A running weapon attack loop (held mouse / held mobile shoot
		-- stick) legitimately holds WalkSpeed at the attack-slow value for
		-- as long as the player keeps attacking. Without this, holding fire
		-- past WATCHDOG_STUCK_SECONDS read as "stuck slow" and the restore
		-- released the held inputs — cancelling a perfectly healthy attack.
		or character:GetAttribute(Attributes.Attacking) == true
	then
		return true
	end
	local ragdollTrigger = character:FindFirstChild(ValueNames.RagdollTrigger)
	return ragdollTrigger ~= nil and ragdollTrigger.Value == true
end

-- Drops every HELD input the combat systems are tracking: the mobile
-- auto-attack session, the weapon "button held" flag both weapon
-- components loop on, and an open Normal Cast aim. Used when the app loses
-- focus (a backgrounded app never delivers the release that would have
-- ended these) and as the tail of a WalkSpeed restore, so a runaway attack
-- loop can't re-slow the character the moment it's been restored.
function PlayerStateController:_releaseHeldInputs()
	if AimController then
		AimController:StopAutoAttack()
		AimController.OnWeaponActivate:Fire(false)
	end
	if CastModeController then
		CastModeController:CancelAim()
	end
end

-- An attack was just EXECUTED for the player. Called off outcomes only
-- (see the watchdog header): the melee gate closing, a cast firing.
function PlayerStateController:_noteAttackActivity()
	self._lastAttackActivity = os.clock()
end

-- True while the watchdog should stand down. Three ways in:
--   * an executed attack inside the grace window (melee swing, cast);
--   * a weapon loop running under LIVE input — the Attacking flag with
--     the mouse button held or an auto-attack session open, which is
--     the ranged weapon's only footprint (it has no per-shot event) and
--     is the same definition of a legitimate hold the "Attacking set
--     with no held attack input" check already uses. The flag ALONE is
--     never enough: a stuck-true Attacking must not suppress its own
--     rescue.
function PlayerStateController:_isAttacking(character: Model): boolean
	if os.clock() - self._lastAttackActivity < WATCHDOG_ATTACK_GRACE_SECONDS then
		return true
	end
	if character:GetAttribute(Attributes.Attacking) == true then
		if AimController and AimController:IsAutoAttacking() then
			return true
		end
		if UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then
			return true
		end
	end
	return false
end

-- Tracks MeleeWeaponEnabled's transitions on the local character so the
-- watchdog can ask how long it has been CONTINUOUSLY closed. Re-bound per
-- character (a fresh body starts with the gate open, and the old
-- character's connection dies with it).
function PlayerStateController:_watchMeleeGate()
	local localPlayer = Players.LocalPlayer

	local function bind(character: Model)
		self._meleeGateFalseSince = nil
		local function refresh()
			if character:GetAttribute(Attributes.MeleeWeaponEnabled) == false then
				-- Only the FIRST close of a stretch starts the clock; a
				-- re-close after a real open starts a new one.
				if self._meleeGateFalseSince == nil then
					self._meleeGateFalseSince = os.clock()
					-- The server closes this gate only for a swing it ACCEPTED:
					-- the strongest possible "the player is attacking" signal.
					self:_noteAttackActivity()
				end
			else
				self._meleeGateFalseSince = nil
			end
		end
		character:GetAttributeChangedSignal(Attributes.MeleeWeaponEnabled):Connect(refresh)
		refresh()
	end

	if localPlayer.Character then
		bind(localPlayer.Character)
	end
	localPlayer.CharacterAdded:Connect(bind)
end

-- The watchdog's checks. Each: a `stuck` predicate evaluated every poll
-- and a `restore` run once the predicate has held for `threshold`
-- seconds without a break. Order is irrelevant — checks are independent.
-- A check may also supply `trappedSince(character) -> number?`: an EXACT
-- timestamp of when its condition became true, which replaces the poll's
-- own first-seen bookkeeping. Required for anything that can flicker
-- between polls (see the watchdog header).
function PlayerStateController:_buildWatchdogChecks()
	local magicThreshold = math.max(WATCHDOG_STUCK_SECONDS, longestSpellDuration() + WATCHDOG_MAGIC_MARGIN_SECONDS)

	local function attributeStuckTrue(attribute: string, threshold: number)
		return {
			name = "attribute '" .. attribute .. "' stuck true",
			threshold = threshold,
			stuck = function(character: Model)
				return character:GetAttribute(attribute) == true
			end,
			restore = function(character: Model)
				character:SetAttribute(attribute, false)
			end,
		}
	end

	return {
		-- Client-owned gate attributes whose delayed clear was lost.
		attributeStuckTrue(Attributes.IsDodging, WATCHDOG_STUCK_SECONDS), -- dodges end in < 1s
		attributeStuckTrue(Attributes.MagicEnabled, magicThreshold), -- cleared after spell duration
		attributeStuckTrue(Attributes.CutscenePlaying, WATCHDOG_CUTSCENE_STUCK_SECONDS),

		-- Server-owned swing gate: the server flips MeleeWeaponEnabled off
		-- at swing start and back on after the hitbox delay (< 1s). If that
		-- second write is ever lost, the client's swing loop refuses every
		-- swing forever ("I can move but can't attack"). Clearing LOCALLY
		-- is enough — the client only ever reads its own copy, and the
		-- server's next swing re-stamps it either way.
		--
		-- EVENT-TRACKED, not sampled: this is the flickering state the
		-- watchdog header warns about. Holding attack closes and reopens the
		-- gate every swing, and the polled version fired mid-combo on
		-- players who were never stuck at all. _watchMeleeGate owns the
		-- timestamp, so any real reopen resets it.
		{
			name = "MeleeWeaponEnabled stuck false (server swing gate)",
			threshold = WATCHDOG_STUCK_SECONDS,
			stuck = function(_character: Model)
				return self._meleeGateFalseSince ~= nil
			end,
			trappedSince = function(_character: Model): number?
				return self._meleeGateFalseSince
			end,
			restore = function(character: Model)
				character:SetAttribute(Attributes.MeleeWeaponEnabled, true)
				self._meleeGateFalseSince = nil
			end,
		},

		-- Attacking flag up with NO live attack input behind it. Attacking
		-- is a legitimate movement lock for as long as the player holds
		-- fire (see movementLegitimatelyLocked) — so this check must NOT
		-- key off duration alone, or a long hold would trip it. It only
		-- counts as trapped when the flag is up but nothing could still be
		-- driving the loop: no auto-attack session and no held mouse
		-- button. Then it's a lost clear (weapon loop died without its
		-- cleanup — e.g. component torn down mid-loop) and the flag would
		-- otherwise mask a genuine stuck-slow WalkSpeed forever.
		{
			name = "Attacking set with no held attack input",
			threshold = WATCHDOG_STUCK_SECONDS,
			stuck = function(character: Model)
				if character:GetAttribute(Attributes.Attacking) ~= true then
					return false
				end
				if AimController and AimController:IsAutoAttacking() then
					return false
				end
				if UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then
					return false
				end
				return true
			end,
			restore = function(character: Model)
				character:SetAttribute(Attributes.Attacking, false)
				self:_releaseHeldInputs()
			end,
		},

		-- WalkSpeed below baseline while NOTHING legitimately owns movement.
		-- The weapon components' own restores are conditional (skipped when
		-- a gate is closed at swing end) and a backgrounded app can leave a
		-- swing/shot loop running with the button "held" -- both strand
		-- WalkSpeed at the attack-slow value ("I can only crawl"). Restore
		-- to baseline AND release held inputs, or a runaway loop just
		-- re-slows it on its next iteration.
		{
			name = "WalkSpeed below baseline with no movement lock",
			threshold = WATCHDOG_STUCK_SECONDS,
			stuck = function(character: Model, humanoid: Humanoid)
				if movementLegitimatelyLocked(character) then
					return false
				end
				return humanoid.WalkSpeed < expectedBaseWalkSpeed(character) - 0.01
			end,
			restore = function()
				self:_releaseHeldInputs()
				self:RestoreWalkSpeed()
			end,
		},

		-- TalkingToNPC is server-stamped from the client's own SetTalking
		-- fires; if the close-time `false` is ever lost the player can walk
		-- but never attack again. Trapped = flag on with NO dialogue open
		-- locally. Clear locally (what our gates read) and re-send the
		-- release so the server agrees.
		{
			name = "TalkingToNPC set with no dialogue open",
			threshold = WATCHDOG_STUCK_SECONDS,
			stuck = function(character: Model)
				if character:GetAttribute(Attributes.TalkingToNPC) ~= true then
					return false
				end
				return not (DialogueBillboardInterface and DialogueBillboardInterface:IsInDialogue())
			end,
			restore = function(character: Model)
				character:SetAttribute(Attributes.TalkingToNPC, nil)
				if DialogueBillboardService then
					DialogueBillboardService.SetTalking:Fire(false)
				end
			end,
		},
	}
end

function PlayerStateController:_startWatchdog()
	local checks = self:_buildWatchdogChecks()

	task.spawn(function()
		-- Per-check timestamp of when its trapped condition was FIRST seen
		-- in the current continuous stretch; nil = not currently trapped.
		-- Reset wholesale on death / respawn so a new character starts
		-- clean.
		local stuckSince: { [any]: number } = {}
		local trackedCharacter: Model? = nil

		while true do
			task.wait(WATCHDOG_CHECK_INTERVAL_SECONDS)

			local character = Players.LocalPlayer.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if not character or not humanoid or character:GetAttribute(Attributes.Death) == true then
				stuckSince = {}
				trackedCharacter = character
				continue
			end

			if character ~= trackedCharacter then
				stuckSince = {}
				trackedCharacter = character
			end

			-- STAND DOWN while attacking (see the header). Every check's clock
			-- resets, not just pauses: a stretch that began mid-combo was
			-- never a stuck state, and must not be carried into the idle
			-- window as if it were.
			if self:_isAttacking(character) then
				stuckSince = {}
				continue
			end

			for _, check in checks do
				local ok, isStuck = pcall(check.stuck, character, humanoid)
				if not ok or not isStuck then
					stuckSince[check] = nil
					continue
				end

				-- A check that keeps its own EXACT timestamp (trappedSince)
				-- overrides the poll's first-seen guess: for a state that can
				-- flicker, two polls inside two different windows must not
				-- read as one continuous stretch.
				if check.trappedSince then
					local exactOk, since = pcall(check.trappedSince, character, humanoid)
					stuckSince[check] = if exactOk and typeof(since) == "number" then since else nil
					if stuckSince[check] == nil then
						continue
					end
				end

				if stuckSince[check] == nil then
					stuckSince[check] = os.clock()
				elseif os.clock() - stuckSince[check] > check.threshold then
					warn(
						"[PlayerStateController] Watchdog: "
							.. check.name
							.. " for over "
							.. check.threshold
							.. "s -- restoring (lost restore: frame spike, lag, or app backgrounded)"
					)
					local restored, err = pcall(check.restore, character, humanoid)
					if not restored then
						warn("[PlayerStateController] Watchdog restore failed: " .. tostring(err))
					end
					stuckSince[check] = nil
				end
			end
		end
	end)
end

function PlayerStateController:KnitStart()
	BuildController = Knit.GetController("BuildController")
	CinematicInterfaceController = Knit.GetController("CinematicInterfaceController")
	AimController = Knit.GetController("AimController")
	CastModeController = Knit.GetController("CastModeController")
	MagicController = Knit.GetController("MagicController")
	DialogueBillboardInterface = Knit.GetController("DialogueBillboardInterface")
	DialogueBillboardService = Knit.GetService("DialogueBillboardService")

	-- App focus: a backgrounded app (mobile app switch, alt-tab) never
	-- delivers the touch-release / mouse-up that ends a held attack or an
	-- open aim, so the loops keep running blind and the character comes
	-- back mid-swing with WalkSpeed pinned low. Release everything held on
	-- BOTH edges -- on the way out so nothing runs while we're gone, and on
	-- the way back in case the platform only fires one of the two.
	UserInputService.WindowFocusReleased:Connect(function()
		self:_releaseHeldInputs()
	end)
	UserInputService.WindowFocused:Connect(function()
		self:_releaseHeldInputs()
	end)

	-- Walkspeed back-stop on every cutscene end (boss/miniboss outros,
	-- phase changes, landing). Deferred a beat because OnCinematicEnd and
	-- the CutscenePlaying attribute clear are fired by the same owner in
	-- no guaranteed order — the delay lets the whole release settle before
	-- the write, and a double-write of the same value is harmless anyway.
	--
	-- NOT while something legitimately owns movement. A spell's cast
	-- cutscene beat ends here too, and this wrote baseline over the cast's
	-- own root and over a woven swing's slow -- the "my walkspeed reset
	-- mid-cast" pop. Those owners restore on their own timers; a lost
	-- restore is the watchdog's job, not this back-stop's.
	CinematicInterfaceController.Signals.OnCinematicEnd:Connect(function()
		task.delay(0.1, function()
			local character = Players.LocalPlayer.Character
			if character and movementLegitimatelyLocked(character) then
				return
			end
			self:RestoreWalkSpeed()
		end)
	end)

	-- A cast that FIRED is an executed attack (magic weaved between swings
	-- is the exact case that tripped the WalkSpeed check).
	if MagicController then
		MagicController.Signals.OnMagicCasted:Connect(function()
			self:_noteAttackActivity()
		end)
	end

	-- Before the watchdog: its melee check reads the timestamp this keeps.
	self:_watchMeleeGate()
	self:_startWatchdog()
end

return PlayerStateController
