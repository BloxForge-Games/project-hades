local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local packages: Folder = ReplicatedStorage.Submodules.Core.Packages

local Knit = require(packages.Knit)
local Janitor = require(packages:FindFirstChild("Janitor"))
local Signal = require(packages.Signal)
local WorkspaceDependencies = require(ReplicatedStorage.Submodules.Core.Shared.Enums.WorkspaceDependencies)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local MagicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.MagicData)

local player: Player = Players.LocalPlayer
local mouse: Mouse = player:GetMouse()

local INDEX: number = 0.125
-- MINIMUM cast lock (see BeginCastLock). The server builds a spell's
-- hitbox from the caster's CFrame, so the heading has to stay put across
-- that round trip even for a spell whose authored duration is shorter
-- than the trip itself. Long spells simply lock for their duration.
local CAST_LOCK_MIN_SECONDS = 0.25

-- PC: how long the facing keeps TRACKING the cursor after the last
-- click / swing / shot before AutoRotate takes over. This is what stops
-- spam-clicking from shuddering: without it every release handed the
-- body straight back to movement-facing and the next click snapped it
-- to the cursor again. With it, a burst of clicks just keeps extending
-- the window and the body stays smoothly on the cursor throughout.
local PC_CURSOR_LINGER_SECONDS = 0.75

-- Mobile auto-aim (the StartAutoAttack session + TapMagic below).
--
-- Weapon thumbstick model: PRESS starts an auto-attack session — the
-- character snaps to the nearest living zombie within ACQUIRE range and
-- attacks continuously (gun keeps firing, melee keeps swinging) while the
-- finger stays down, tracking the target as it moves. DRAGGING the stick
-- past its threshold kills the session and hands aim to the stick (manual).
-- RELEASE stops the attack. With no zombie in range the session still
-- attacks, unrotated, in the current facing — and picks up a target the
-- moment one enters range.
--
-- Targeting is STICKY: the session keeps its acquired target while it stays
-- alive and within DROP range (wider than ACQUIRE — hysteresis, so a target
-- dancing on the 40-stud line doesn't flicker in and out), and re-acquires
-- nearest only when the target dies / despawns / walks out.
-- TapMagic (both magic sticks) reads ACQUIRE too — one range for all
-- mobile nearest-enemy detection.
local AUTO_AIM_ACQUIRE_RANGE_STUDS = 40
local AUTO_AIM_DROP_RANGE_STUDS = 45

-- AUTO AIM TOGGLE (mobile, topbar "Auto Aim" button, persisted as profile
-- Settings.AutoAim -- default ON). Governs the two places the sticks acquire
-- a target for the player:
--   ON   press-and-hold on the shoot stick snaps to + tracks the nearest
--        enemy; a magic TAP faces the nearest enemy (canAim spells).
--   OFF  press-and-hold just attacks STRAIGHT AHEAD -- no acquisition, no
--        rotation lock, so the humanoid keeps facing wherever the move stick
--        points and that's where the shots go; a magic TAP casts straight
--        ahead. DRAG-aim on any stick is untouched either way (it's a manual
--        aim, not an auto one).
-- The flag flips optimistically on click and is pushed to SettingsService;
-- DataController's snapshot restores it on join.
local DEFAULT_AUTO_AIM = true

-- Facing hold after the WEAPON stick is released (HoldFacing). Without it,
-- release flips Humanoid.AutoRotate back on the same instant, so a player
-- spamming the shoot stick jitters: snap-to-target / rotate-back-toward-
-- movement / snap-to-target… Keeping AutoRotate off for this long after
-- each release means a re-press inside the window finds the character
-- still facing the target — no snap, no jitter. Rolling: every release
-- extends it. TAP / HOLD releases only — a DRAG release skips it, since a
-- manual aim is a deliberate facing choice that should hand rotation back
-- at once (AimThumbstick decides which; it calls HoldFacing). Casts are
-- NOT routed through this — they hold their heading with the cast lock
-- instead (BeginCastLock), a different job.
local WEAPON_RELEASE_FACING_HOLD_SECONDS = 0.1

local IsometricCameraController
local MagicController
local PlayerStateController
local CastModeController

local AimController = Knit.CreateController({
	Name = "AimController",
	_janitor = Janitor.new() :: table,
	_mobileFirstClick = true :: boolean,
	_stepped = false :: boolean,
	_mobileTargetCFrame = nil :: CFrame,
	_moveVectorRotationEnabled = true :: boolean,
	_mobileRotationActivated = false,

	-- Auto-attack session state (weapon thumbstick press-and-hold).
	_autoAttackConnection = nil :: RBXScriptConnection?,
	_autoAttackTargetRoot = nil :: BasePart?,

	-- os.clock() until which _MobileUpdate keeps AutoRotate OFF while no
	-- stick/session is steering (see WEAPON_RELEASE_FACING_HOLD_SECONDS).
	_facingHoldUntil = 0 :: number,
	-- PC: keys of whoever is currently steering the facing at the cursor
	-- (a held weapon button). Non-empty = TRACK the cursor. See
	-- _KeyboardMouseUpdate.
	_aimHolds = {} :: { [string]: true },
	-- PC: os.clock() until which the facing keeps tracking the cursor with
	-- no button held (see PC_CURSOR_LINGER_SECONDS).
	_cursorLingerUntil = 0 :: number,
	-- PC: os.clock() until which a spell CAST owns the facing (see
	-- BeginCastLock). While set the update neither tracks nor hands the
	-- humanoid back AutoRotate — the body stays exactly where the cast
	-- snapped it.
	_castLockUntil = 0 :: number,

	-- Auto Aim toggle (see DEFAULT_AUTO_AIM).
	_autoAimEnabled = DEFAULT_AUTO_AIM :: boolean,
})

AimController.OnWeaponActivate = Signal.new()
AimController.OnMagicActivate = Signal.new()
-- Fires (enabled: boolean) whenever the Auto Aim toggle flips.
AimController.OnAutoAimChanged = Signal.new()

local DataController
local SettingsService

--[ Auto Aim toggle ]--

function AimController:IsAutoAimEnabled(): boolean
	return self._autoAimEnabled
end

function AimController:SetAutoAimEnabled(enabled: boolean)
	if self._autoAimEnabled == enabled then
		return
	end
	self._autoAimEnabled = enabled

	-- Turning OFF mid-session: drop the current lock-on so the running
	-- hold immediately becomes a straight-ahead attack.
	if not enabled and self._autoAttackConnection then
		self._autoAttackTargetRoot = nil
		self._mobileRotationActivated = false
	end

	self.OnAutoAimChanged:Fire(enabled)
	if SettingsService then
		SettingsService:SetAutoAim(enabled):catch(warn)
	end
end

function AimController:ToggleAutoAim()
	self:SetAutoAimEnabled(not self._autoAimEnabled)
end

function AimController:_applyAutoAimProfile(profile: { [string]: any }?)
	local settings = profile and profile.Settings
	local saved = settings and settings.AutoAim
	if typeof(saved) ~= "boolean" or saved == self._autoAimEnabled then
		return
	end
	self._autoAimEnabled = saved
	self.OnAutoAimChanged:Fire(saved)
end

function AimController:GetMobileMoveVectorOffset(): number
	-- local x, _, z = IsometricCameraController:GetDepthValues()

	-- if x > 0 and z > 0 then
	-- 	return 45
	-- elseif x > 0 and z < 0 then
	-- 	return 135
	-- elseif x < 0 and z < 0 then
	-- 	return 225
	-- elseif x < 0 and z > 0 then
	-- 	return 315
	-- end

	local x, _, z = IsometricCameraController:GetDepthValues()

	return (math.deg(math.atan2(x, z)) + 360) % 360
end

-- PC FACING (Ravenswatch model). The character faces where it MOVES —
-- Humanoid.AutoRotate — and turns to the cursor only to attack. ONE state,
-- "tracking", with three ways in:
--   * a weapon button HELD (BeginAimHold / EndAimHold),
--   * a skillshot being AIMED (CastModeController),
--   * a LINGER after any click / swing / shot (RequestCursorFacing), so
--     a burst of attacks never drops out of tracking between them.
-- While tracking the HRP lerps to the cursor every Stepped. Entering
-- tracking from movement-facing SNAPS once so that first attack is
-- aimed; every later click inside the window lerps — no jumps.
-- A dash or a spell owns the CFrame for its window (IsDodging /
-- MagicEnabled / SkillshotDelay): the humanoid must not steer and we
-- must not track — the same rule _MobileUpdate applies.
-- (A per-swing facing FREEZE for melee was tried between this and the
-- old always-face-the-cursor model and removed: alternating track /
-- freeze / track while holding the button read as stutter. Melee and
-- ranged now behave identically here.)
function AimController:_isTrackingCursor(): boolean
	if next(self._aimHolds) ~= nil then
		return true
	end
	if os.clock() < self._cursorLingerUntil then
		return true
	end
	return CastModeController ~= nil and CastModeController:IsAiming() == true
end

function AimController:_KeyboardMouseUpdate()
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not rootPart then
		return
	end

	if
		character:GetAttribute(Attributes.IsDodging) == true
		or character:GetAttribute(Attributes.MagicEnabled) == true
		or os.clock() < self._castLockUntil
	then
		humanoid.AutoRotate = false
		return
	end
	if PlayerStateController:AimActionEnabled() == false then
		return
	end

	if not self:_isTrackingCursor() then
		humanoid.AutoRotate = true
		return
	end

	humanoid.AutoRotate = false
	local mouseLocation: Vector3 = Vector3.new(mouse.Hit.X, rootPart.Position.Y, mouse.Hit.Z)
	if (mouseLocation - rootPart.Position).Magnitude < 0.001 then
		return
	end
	rootPart.CFrame = rootPart.CFrame:Lerp(CFrame.new(rootPart.Position, mouseLocation), INDEX)
end

-- The PC snap: face the cursor NOW, in one frame. Called by the weapon
-- components at the top of their click handlers, ahead of the attack, so
-- the swing / shot is computed from the new facing. No-op on touch —
-- mobile has its own auto-aim snap (_snapFacing).
function AimController:SnapFacingToCursor()
	if UserInputService.TouchEnabled then
		return
	end
	if PlayerStateController:AimActionEnabled() == false then
		return
	end
	self:_snapFacingToCursorNow()
end

-- The snap itself, with no state gate. SnapFacingToCursor wraps it for
-- the weapons; BeginCastLock calls it directly because a cast has
-- ALREADY raised MagicEnabled by the time it asks to face the cursor,
-- and AimActionEnabled reads false under that flag — the gate would
-- refuse the very snap the cast exists to make.
function AimController:_snapFacingToCursorNow()
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not rootPart then
		return
	end
	local flatTarget = Vector3.new(mouse.Hit.X, rootPart.Position.Y, mouse.Hit.Z)
	if (flatTarget - rootPart.Position).Magnitude < 0.001 then
		return
	end
	humanoid.AutoRotate = false
	rootPart.CFrame = CFrame.lookAt(rootPart.Position, flatTarget)
end

-- A spell cast begins — called by MagicController:CastMagic on BOTH
-- platforms, for the spell's whole cast time. It LOCKS the heading: while
-- the lock holds, neither update loop steers the body and AutoRotate stays
-- off, so the CFrame the server reads for the hitbox is the one the player
-- aimed with. When it ends the ordinary rules resume (a held weapon
-- tracks, otherwise AutoRotate comes back).
--
-- This REPLACED the mobile-only SkillshotDelay attribute, which did the
-- same job for a fixed 0.25s on the magic-stick path only. Same guard,
-- one mechanism, driven from the one place that knows the spell.
--
-- The only per-platform part is the OPENING heading:
--   PC     snaps to the cursor now (a cast is an aimed action, and the
--          weapon linger is wiped so it cannot expire mid-cast and hand
--          AutoRotate back while the spell is still going).
--   MOBILE keeps whatever the stick or auto-aim already chose — there is
--          no cursor to face, and TapMagic has aimed it already.
function AimController:BeginCastLock(seconds: number)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		-- Off THIS frame: the loops enforce it for the rest of the lock, but
		-- the cast's own hitbox can be read before either runs again.
		humanoid.AutoRotate = false
	end

	if not UserInputService.TouchEnabled then
		self._cursorLingerUntil = 0
		self:_snapFacingToCursorNow()
	end

	local duration = math.max(seconds or 0, CAST_LOCK_MIN_SECONDS)
	self._castLockUntil = math.max(self._castLockUntil, os.clock() + duration)
end

-- PC: while `key` is held the facing tracks the cursor. Keyed so a held
-- weapon and an aimed skillshot can overlap without one release ending
-- the other's hold. No-op on touch.
function AimController:BeginAimHold(key: string)
	if UserInputService.TouchEnabled then
		return
	end
	self._aimHolds[key] = true
end

function AimController:EndAimHold(key: string)
	self._aimHolds[key] = nil
end

-- Drops EVERY named hold at once. The backstop for the whole mechanism:
-- a hold is only ever opened by a mouse button going down, so a mouse
-- button coming up ends all of them no matter which component opened it
-- or whether that component is still alive to close it.
--
-- This exists because a leaked hold is INVISIBLE and PERMANENT. It
-- outlives the weapon, the character and every respawn (the table lives
-- on the controller), and the only symptom is that the body silently
-- follows the cursor forever. The leak that prompted it: the melee
-- component only released on mouse-up while the weapon was still
-- equipped, so click-and-hold, then open a merchant or talk to an NPC,
-- and the release found an unequipped weapon and did nothing.
function AimController:ReleaseAllAimHolds()
	table.clear(self._aimHolds)
end

-- PC: an attack is happening — called by the weapons on every click,
-- swing and shot. Snaps to the cursor ONLY when this enters tracking
-- from movement-facing (so the first attack of a burst is aimed at
-- once); while already tracking it just extends the linger, and the
-- update's lerp does the turning. No-op on touch.
function AimController:RequestCursorFacing()
	if UserInputService.TouchEnabled then
		return
	end
	if PlayerStateController:AimActionEnabled() == false then
		return
	end
	if not self:_isTrackingCursor() then
		self:SnapFacingToCursor()
	end
	self._cursorLingerUntil = math.max(self._cursorLingerUntil, os.clock() + PC_CURSOR_LINGER_SECONDS)
end

function AimController:_MobileUpdate()
	-- Cast lock (BeginCastLock), the same one the keyboard loop honours:
	-- the heading is pinned for the cast so the server's hitbox matches
	-- what the player aimed. Was the SkillshotDelay attribute.
	if os.clock() < self._castLockUntil then
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.AutoRotate = false
		end
		return
	end

	if PlayerStateController:AimActionEnabled() == false then
		if
			player.Character:GetAttribute(Attributes.IsDodging) == true
			or player.Character:GetAttribute(Attributes.MagicEnabled) == true
		then
			player.Character.Humanoid.AutoRotate = false
		end

		return
	end

	if not self._mobileRotationActivated then
		-- Nothing steering: hand rotation back to the humanoid — unless a
		-- weapon-stick release hold is still running, in which case keep
		-- the current facing (see HoldFacing).
		player.Character.Humanoid.AutoRotate = os.clock() >= self._facingHoldUntil

		return
	end

	if not self._mobileTargetCFrame or not self._mobileRotationActivated then
		return
	end

	local rootPart: BasePart = player.Character:FindFirstChild("HumanoidRootPart")

	local currentAngle = rootPart.CFrame - rootPart.CFrame.Position
	local desiredAngle = self._mobileTargetCFrame - self._mobileTargetCFrame.Position
	local finalCF = CFrame.new(rootPart.CFrame.Position) * currentAngle:Lerp(desiredAngle, INDEX)

	rootPart.CFrame = finalCF
end

function AimController:SetMoveVectorRotationEnabled(enable: boolean)
	self._moveVectorRotationEnabled = enable
end

function AimController:RotatePlayerToMoveVector(activated: boolean, direction: Vector3)
	if UserInputService.TouchEnabled then
		if not self._moveVectorRotationEnabled then
			return
		end

		if PlayerStateController:AimActionEnabled() == false then
			return
		end

		self._mobileRotationActivated = activated

		-- Activating takes rotation NOW. Deactivating hands it back via
		-- _MobileUpdate next Stepped rather than here — that path is what
		-- honours a running facing hold (writing AutoRotate = true here
		-- would flicker it on for a frame and defeat the hold).
		if self._mobileRotationActivated then
			player.Character:WaitForChild("Humanoid").AutoRotate = false
		else
			self._mobileFirstClick = true
		end

		if not direction then
			return
		end

		local rootPart = player.Character.HumanoidRootPart
		local targetDirection = Vector3.new(direction.X, 0, direction.Z).Unit
		local targetPosition = Vector3.new(rootPart.Position.X, rootPart.Position.Y, rootPart.Position.Z)

		self._mobileTargetCFrame = CFrame.new(targetPosition, targetPosition + targetDirection)
			* CFrame.Angles(0, math.rad(self:GetMobileMoveVectorOffset()), 0)

		if self._mobileFirstClick then
			self._mobileFirstClick = false
			player.Character.HumanoidRootPart.CFrame = self._mobileTargetCFrame
		end
	end
end

--[ Mobile auto-aim ]--

-- Root part of the nearest living zombie within `rangeStuds` of the local
-- character, or nil. Pure distance — no line-of-sight filtering, by design:
-- rooms are open arenas and a raycast miss would read as a dead button.
function AimController:_findNearestEnemy(rangeStuds: number): BasePart?
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return nil
	end

	local zombiesFolder = workspace.IgnoreInstances:FindFirstChild("Zombies")
	if not zombiesFolder then
		return nil
	end

	local nearestRoot: BasePart? = nil
	local nearestDistance = rangeStuds

	for _, zombie in zombiesFolder:GetChildren() do
		if not zombie:IsA("Model") then
			continue
		end
		local zombieHumanoid = zombie:FindFirstChildOfClass("Humanoid")
		local zombieRoot = zombie:FindFirstChild("HumanoidRootPart") or zombie.PrimaryPart
		if not zombieHumanoid or zombieHumanoid.Health <= 0 or not zombieRoot then
			continue
		end

		local distance = (zombieRoot.Position - hrp.Position).Magnitude
		if distance <= nearestDistance then
			nearestDistance = distance
			nearestRoot = zombieRoot
		end
	end

	return nearestRoot
end

-- Position variant, kept for callers that only need a point (TapMagic).
function AimController:GetNearestEnemyPosition(rangeStuds: number?): Vector3?
	local root = self:_findNearestEnemy(rangeStuds or AUTO_AIM_ACQUIRE_RANGE_STUDS)
	return root and root.Position
end

-- Instantly faces the character toward `targetPosition` (XZ only — pitch
-- never changes). WORLD-space by definition; deliberately not routed through
-- RotatePlayerToMoveVector, which expects a STICK-space vector and applies
-- the camera-yaw offset — feeding it a world direction would aim wrong by
-- the camera's rotation.
function AimController:_snapFacing(targetPosition: Vector3)
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return
	end
	local flatTarget = Vector3.new(targetPosition.X, hrp.Position.Y, targetPosition.Z)
	if (flatTarget - hrp.Position).Magnitude < 0.001 then
		return
	end
	hrp.CFrame = CFrame.lookAt(hrp.Position, flatTarget)
end

-- Is the session's sticky target still worth keeping? Alive, still in the
-- world, and within DROP range (wider than acquire — hysteresis).
function AimController:_isAutoAttackTargetValid(): boolean
	local targetRoot = self._autoAttackTargetRoot
	if not targetRoot or not targetRoot.Parent then
		return false
	end

	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return false
	end

	local zombieModel = targetRoot:FindFirstAncestorOfClass("Model")
	local zombieHumanoid = zombieModel and zombieModel:FindFirstChildOfClass("Humanoid")
	if not zombieHumanoid or zombieHumanoid.Health <= 0 then
		return false
	end

	return (targetRoot.Position - hrp.Position).Magnitude <= AUTO_AIM_DROP_RANGE_STUDS
end

-- One Heartbeat of the auto-attack session: keep/re-acquire the sticky
-- target, aim the existing _MobileUpdate lerp at it, and keep the attack
-- signal hot. Firing every step mirrors what a stick drag already does
-- (OnWeaponActivate(true) per TouchMoved) — the weapon components own
-- their own fire-rate / swing debounce.
function AimController:_autoAttackStep()
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")

	if not hrp or not humanoid or PlayerStateController:GeneralActionEnabled() == false then
		self:StopAutoAttack()
		return
	end

	-- Auto Aim OFF: never acquire. The session still keeps the attack
	-- signal hot below, but with no target it leaves rotation to the
	-- humanoid, so you fire straight ahead / wherever you're walking.
	if not self._autoAimEnabled then
		self._autoAttackTargetRoot = nil
	elseif not self:_isAutoAttackTargetValid() then
		local newTarget = self:_findNearestEnemy(AUTO_AIM_ACQUIRE_RANGE_STUDS)
		self._autoAttackTargetRoot = newTarget
		if newTarget then
			-- Fresh acquisition: snap so the very next shot is on target;
			-- the per-step lerp below handles tracking from here.
			self:_snapFacing(newTarget.Position)
		end
	end

	local targetRoot = self._autoAttackTargetRoot
	if targetRoot then
		local flatTarget = Vector3.new(targetRoot.Position.X, hrp.Position.Y, targetRoot.Position.Z)
		if (flatTarget - hrp.Position).Magnitude > 0.001 then
			-- Drive the same machinery stick-drags use: _MobileUpdate lerps
			-- the character toward _mobileTargetCFrame every Stepped while
			-- _mobileRotationActivated holds AutoRotate off.
			self._mobileTargetCFrame = CFrame.lookAt(hrp.Position, flatTarget)
			self._mobileRotationActivated = true
			humanoid.AutoRotate = false
		end
	else
		-- No target in range: keep attacking in the current facing and let
		-- the humanoid rotate freely with movement until something wanders
		-- into acquire range.
		self._mobileRotationActivated = false
	end

	self.OnWeaponActivate:Fire(true)
end

-- PRESS on the weapon thumbstick. Idempotent — a second call while a
-- session runs is a no-op. Refuses (and attacks nothing) while general
-- actions are disabled (death, cutscene, stun).
function AimController:StartAutoAttack()
	if self._autoAttackConnection then
		return
	end
	if PlayerStateController:GeneralActionEnabled() == false then
		return
	end

	self._autoAttackConnection = RunService.Heartbeat:Connect(function()
		self:_autoAttackStep()
	end)

	-- First step immediately — acquire + snap + first shot on the press
	-- frame, not a Heartbeat later.
	self:_autoAttackStep()
end

-- True while a mobile press-and-hold auto-attack session is running.
-- Read by PlayerStateController's watchdog so it can tell a live held
-- attack from an Attacking flag whose clear was lost.
function AimController:IsAutoAttacking(): boolean
	return self._autoAttackConnection ~= nil
end

-- RELEASE (or menu-open, disable). Idempotent.
--
-- `keepAttacking` = the DRAG-BREAK case: the stick is taking over aim and
-- will keep the weapon firing itself (OnWeaponActivate(true) every
-- TouchMoved), so the session must end WITHOUT firing OnWeaponActivate(false).
-- Firing false there flapped the weapon off-then-on inside one frame; the
-- gun's loop was still mid fire-rate wait from the press shot, so the
-- re-activation was dropped by its running-loop guard and the gun stalled a
-- full itemDelay before the next TouchMoved restarted it -- "shoot once,
-- then a half-second pause" on every press-and-drag.
function AimController:StopAutoAttack(keepAttacking: boolean?)
	if not self._autoAttackConnection then
		return
	end

	self._autoAttackConnection:Disconnect()
	self._autoAttackConnection = nil
	self._autoAttackTargetRoot = nil
	-- AutoRotate is restored by _MobileUpdate (hold-aware), not here.
	self._mobileRotationActivated = false

	if not keepAttacking then
		self.OnWeaponActivate:Fire(false)
	end
end

-- Weapon-stick RELEASE: keep the current facing for a moment so a re-press
-- doesn't jitter (rationale at WEAPON_RELEASE_FACING_HOLD_SECONDS). Called
-- by AimThumbstick on TouchEnded after a TAP / HOLD release only (not after
-- a drag). Rolling: never shortens a hold already running.
function AimController:HoldFacing(seconds: number?)
	local until_ = os.clock() + (seconds or WEAPON_RELEASE_FACING_HOLD_SECONDS)
	if until_ > self._facingHoldUntil then
		self._facingHoldUntil = until_
	end
end

-- TAP on a magic thumbstick: for a canAim spell (MagicData), face the
-- nearest zombie in range, then cast through the existing
-- OnMagicActivate(slot, false) path — which owns the indicator cleanup, the
-- cast lock, and CastMagic's own mana/cooldown gates. Spells
-- with canAim = false (auras, self-centered bursts) cast with no rotation.
function AimController:TapMagic(equipSlot: number)
	if PlayerStateController:GeneralActionEnabled() == false then
		return
	end

	local castable, vfxName = MagicController:CanCastMagic(equipSlot)
	if not castable or not vfxName then
		return
	end

	-- Auto Aim OFF: a tap casts straight ahead, no snap.
	local magicIndexData = MagicData[vfxName]
	if self._autoAimEnabled and magicIndexData and magicIndexData.canAim then
		local targetPosition = self:GetNearestEnemyPosition(AUTO_AIM_ACQUIRE_RANGE_STUDS)
		if targetPosition then
			self:_snapFacing(targetPosition)
		end
	end

	self.OnMagicActivate:Fire(equipSlot, false)
end

function AimController:SetTargetFilter(instance: Instance)
	mouse.TargetFilter = instance
end

function AimController:StartKeyboardStepped()
	if self._stepped then
		self:AbortStepped()
	end

	self._stepped = self._janitor:Add(RunService.Stepped:Connect(function()
		self:_KeyboardMouseUpdate()
	end))
end

function AimController:StartMobileStepped()
	if self._stepped then
		self:AbortStepped()
	end

	self._stepped = self._janitor:Add(RunService.Stepped:Connect(function()
		self:_MobileUpdate()
	end))
end

function AimController:AbortStepped()
	self._janitor:Cleanup()
	self._stepped = nil
end

function AimController:KnitInit()
	IsometricCameraController = Knit.GetController("IsometricCameraController")
	MagicController = Knit.GetController("MagicController")
	PlayerStateController = Knit.GetController("PlayerStateController")
	CastModeController = Knit.GetController("CastModeController")
end

function AimController:KnitStart()
	-- The authoritative end of every aim hold (see ReleaseAllAimHolds).
	-- Unconditional: no weapon state, no equip check, nothing that can be
	-- false at the moment the button comes up.
	UserInputService.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			self:ReleaseAllAimHolds()
		end
	end)

	self:SetTargetFilter(workspace[WorkspaceDependencies.IgnoreInstances])
	self:SetMoveVectorRotationEnabled(true)

	-- Auto Aim preference: whatever snapshot is already here, then every
	-- push (the join-time snapshot may land after KnitStart).
	DataController = Knit.GetController("DataController")
	SettingsService = Knit.GetService("SettingsService")
	self:_applyAutoAimProfile(DataController:GetProfileData())
	DataController.Signals.OnProfileChanged:Connect(function(profile)
		self:_applyAutoAimProfile(profile)
	end)

	self.OnMagicActivate:Connect(function(equipSlot: number, skillshotEnabled: boolean)
		if PlayerStateController:GeneralActionEnabled() == false then
			return
		end

		MagicController:ToggleMobileIndicator(skillshotEnabled, equipSlot)

		if skillshotEnabled then
			return
		end

		-- The heading lock rides CastMagic now (BeginCastLock), for every
		-- platform and for the spell's real duration. This branch used to
		-- stamp its own 0.25s SkillshotDelay here.
		MagicController:CastMagic(equipSlot)
	end)
end

return AimController
