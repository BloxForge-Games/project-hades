--[[
	Module: ZombieController.lua
	Description:
	Client-side visual response to server-driven mob attacks. Two
	signals it reacts to:

	  OnReplicateMobAttack(zombieModel, hitboxName, hitboxCFrame, windUpDuration, hitFrameDuration)
	    Server fires at WIND-UP START (not hit-frame start) so the
	    player sees the danger zone telegraph in time to react. Client:
	      1. Clones the same Hitbox Model the server used (from
	         GameAssets.Hitboxes.<hitboxName>), positions via the
	         server-computed world hitboxCFrame.
	      2. Phase 1 (windup): Tween Transparency 1 → 0 over windUpDuration.
	         Color stays at the template (red). Visual: red ramps in.
	      3. Snap (instant, at hit-frame start): Set Color = white directly.
	         This is the "flash" — a hard color snap at the moment damage
	         starts applying server-side.
	      4. Phase 2 (hit-frame): Tween Transparency 0 → 1 over hitFrameDuration.
	         Color stays white from the snap. Visual: white fades to invisible.
	    Net visual sequence: red ramp-in → white flash → fade out.

	  OnReplicateZombieAttack(zombieModel, startCFrame, goalCFrame, _ts)
	    Server fires only when the attack has lungeDistance > 0. Client
	    tweens the mob's HRP to the goal CFrame for the cosmetic
	    "step into swing" effect. Tween duration is a fixed client-side
	    constant — the lunge is purely visual, server-side position is
	    set authoritatively via PivotTo.

	==========================================================
	Memory note (kept from prior refactor)
	==========================================================
	Hitbox flash helpers are module-scope and take a `state` table by
	reference instead of capturing closures per-event. Death-mid-flash
	cleanup uses a single `aborted` flag the flash coroutine checks at
	every yield point.
]]

--[ Roblox Services ]--

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

--[ Imports ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)

local ZombieService
local VFXController

local ZombieController = Knit.CreateController({
	Name = "ZombieController",
	Client = {},
})

--[ Constants ]--

-- Death-mid-flash cleanup: how long the fade-to-invisible takes when
-- the zombie dies during its swing. Slightly longer than the normal
-- flash fade so the player can register the cancellation.
local HITBOX_DEATH_FADE_DURATION = 0.5

-- Lunge tween duration. Cosmetic only — server already PivotTo'd the
-- mob mid-hitframe; this just smooths the visual jump.
local LUNGE_TWEEN_DURATION = 0.4

-- Hitbox flash visual color
local FLASH_WHITE = Color3.new(1, 1, 1)

-- Max Y jitter applied to each cloned hitbox to prevent z-fighting when
-- multiple mobs swing simultaneously (15+ zombies on the same floor
-- produce overlapping hitboxes at the same Y → flicker as the depth
-- test ties). 0.05 studs is well below visible threshold but breaks
-- the tie so each clone wins/loses depth consistently per-frame.
local HITBOX_Y_JITTER_MAX = 0.05

-- Folder under workspace.IgnoreInstances where the client-side visual
-- hitbox clones live. Same folder the prior implementation used so
-- LifeController's clearZombieHitboxes sweep still picks them up.
local HITBOX_PARENT = workspace.IgnoreInstances.MagicSpells

--[ Local-player death gate ]--

-- Suppression window for mob-attack VISUALS, deliberately narrow: true
-- only for the first few seconds after the local player dies — the
-- death cinematic — not for the whole death state.
--
-- The previous version checked the Death attribute alone — written as a
-- race guard for the ~3s death animation back when death was a short
-- revive window. Under hardcore, Death stays true for the REST OF THE
-- RUN, so that gate silently became "spectators never see mob
-- telegraphs, projectiles, or lunges again". Replicated visuals must
-- reach spectators — they're watching living teammates fight.
--
-- Time-based rather than attribute-based because the death flow never
-- stamps CutscenePlaying (only scripted cutscenes / boss intros / the
-- landing do) — there is no attribute that marks exactly this window.
-- localDeathStartedAt is stamped by the Death listener in KnitStart.
local DEATH_CINEMATIC_SUPPRESS_SECONDS = 4
local localDeathStartedAt = 0

local function isLocalDeathCinematicPlaying(): boolean
	local character = Players.LocalPlayer.Character
	if character == nil or character:GetAttribute(Attributes.Death) ~= true then
		return false
	end
	return (os.clock() - localDeathStartedAt) < DEATH_CINEMATIC_SUPPRESS_SECONDS
end

--[ Hitbox flash helpers (module-scope to avoid per-event allocations) ]--

-- Set of in-flight hitbox-flash states, so a boss phase change / outro
-- cutscene can abort every active telegraph at once (abortAllHitboxFlashes).
-- States add themselves on spawn and remove on fade/completion.
local activeFlashes: { [any]: boolean } = {}

-- Cancels the in-flight flash and fades every part on the hitbox to
-- transparency 1. Idempotent. Called either from the death listener
-- (zombie killed mid-attack) or from the initial check below if the
-- zombie was already dead when the attack event arrived.
local function fadeOutHitbox(state)
	if state.aborted then
		return
	end
	state.aborted = true
	activeFlashes[state] = nil

	if state.diedConn then
		state.diedConn:Disconnect()
		state.diedConn = nil
	end

	if not state.model.Parent then
		return
	end

	local fadeInfo = TweenInfo.new(HITBOX_DEATH_FADE_DURATION, Enum.EasingStyle.Cubic)
	for _, part in state.parts do
		TweenService:Create(part, fadeInfo, { Transparency = 1 }):Play()
		local selectionBox = part:FindFirstChildOfClass("SelectionBox")
		if selectionBox then
			TweenService:Create(selectionBox, fadeInfo, { Transparency = 1, SurfaceTransparency = 1 }):Play()
		end
	end

	Debris:AddItem(state.model, HITBOX_DEATH_FADE_DURATION + 0.1)
end

-- Drives the telegraph → fade chain. Two phases:
--   Phase 1 (windup): Transparency 1 → 0 over windUpDuration.
--                     Visual builds in intensity as the swing winds up.
--   Phase 2 (hit-frame): Transparency 0 → 1 over hitFrameDuration.
--                        Visual peaks at the windup→hit-frame transition
--                        (which is exactly when damage starts applying
--                        server-side) and fades as the damage window closes.
--
-- Multi-part Hitbox Models flash all parts in parallel by creating one
-- tween per part. They all share the same tween duration so they
-- complete simultaneously (no need to track individual Completed signals).
--
-- state.aborted is checked at every yield point so a mid-flash death
-- cleanly hands off to fadeOutHitbox.
local function runHitboxFlash(state, windUpDuration: number, hitFrameDuration: number)
	if state.aborted or not state.model.Parent then
		return
	end

	-- Phase 1: ramp UP (windup telegraph).
	-- Start hitbox parts at fully transparent (template Models are
	-- authored opaque, so override here on spawn).
	for _, part in state.parts do
		part.Transparency = 1
	end

	local rampInfo = TweenInfo.new(windUpDuration, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out)

	for _, part in state.parts do
		TweenService:Create(part, rampInfo, { Transparency = 0.75 }):Play()

		local selectionBox = part:FindFirstChildOfClass("SelectionBox")

		if selectionBox then
			TweenService:Create(selectionBox, rampInfo, { Transparency = 0 }):Play()
		end
	end

	task.wait(windUpDuration)

	-- Hit-frame snap. Both the underlying hitbox Part AND its
	-- SelectionBox swap to white over hitFrameDuration so the flash
	-- reads consistently from either rendering layer. The original
	-- code only tweened `part.Color`, but the SelectionBox sits over
	-- the part with its own opaque red SurfaceColor3 — that red fill
	-- masked the part's color change and the flash never appeared.
	-- Tweening `Color3` (outline) and `SurfaceColor3` (fill) on the
	-- SelectionBox itself fixes that. Also: the SelectionBox tween
	-- previously reused `rampInfo` (windup duration) instead of a
	-- hit-frame-scoped TweenInfo, so its timing didn't match the
	-- part's hit-frame tween — corrected here.
	local flashInfo = TweenInfo.new(hitFrameDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

	for _, part in state.parts do
		TweenService:Create(part, flashInfo, { Color = FLASH_WHITE }):Play()

		task.delay(hitFrameDuration / 2, function()
			TweenService:Create(part, flashInfo, { Transparency = 0 }):Play()
		end)

		local selectionBox = part:FindFirstChildOfClass("SelectionBox")

		if selectionBox then
			TweenService:Create(selectionBox, flashInfo, {
				Color3 = FLASH_WHITE,
				SurfaceColor3 = FLASH_WHITE,
			}):Play()
		end
	end

	if state.aborted or not state.model.Parent then
		return
	end

	task.wait(hitFrameDuration)

	if state.aborted or not state.model.Parent then
		return
	end

	-- Phase 2: fade DOWN (hit-frame).
	local fadeInfo = TweenInfo.new(hitFrameDuration, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out)

	for _, part in state.parts do
		TweenService:Create(part, fadeInfo, { Transparency = 1 }):Play()

		local selectionBox = part:FindFirstChildOfClass("SelectionBox")

		if selectionBox then
			TweenService:Create(selectionBox, fadeInfo, { Transparency = 1, SurfaceTransparency = 1 }):Play()
		end
	end

	if state.aborted then
		return
	end

	-- Normal completion: drop the death listener + Debris-clean.
	if state.diedConn then
		state.diedConn:Disconnect()
		state.diedConn = nil
	end
	activeFlashes[state] = nil

	Debris:AddItem(state.model, 1)
end

-- Fades out every in-flight hitbox telegraph immediately. Called when a boss
-- phase change / outro cutscene starts so no danger-zone flash lingers on the
-- frozen mob during the cinematic (the server already cancelled the
-- corresponding damage hitbox + lunge — see ZombieService AttackInterrupted).
local function abortAllHitboxFlashes()
	local snapshot = {}
	for state in activeFlashes do
		table.insert(snapshot, state)
	end
	for _, state in snapshot do
		fadeOutHitbox(state)
	end
end

-- Per-event entry point. Clones the Hitbox Model the server names,
-- places it at the world CFrame the server computed, runs the
-- telegraph→fade chain over (windUpDuration + hitFrameDuration).
-- Aborts cleanly if the local player dies during the flash window.
local function spawnHitboxFlash(
	zombieModel: Model,
	hitboxName: string,
	hitboxCFrame: CFrame,
	windUpDuration: number,
	hitFrameDuration: number
)
	-- Race gate #1: server fired this RIGHT as the local player died.
	-- Suppressed only while the death CINEMATIC owns the screen —
	-- spectators (death state, cinematic over) see every telegraph.
	if isLocalDeathCinematicPlaying() then
		return
	end

	local hitboxesFolder = ReplicatedStorage.GameAssets:FindFirstChild("Hitboxes")
	if not hitboxesFolder then
		warn("[ZombieController] Missing ReplicatedStorage.GameAssets.Hitboxes folder")
		return
	end
	local template = hitboxesFolder:FindFirstChild(hitboxName)
	if not template or not template:IsA("Model") then
		warn(("[ZombieController] Hitbox template '%s' missing or not a Model"):format(hitboxName))
		return
	end

	local clonedHitbox = template:Clone()
	-- Y jitter: per-clone random nudge to break depth ties when
	-- multiple mobs swing on the same floor. Sub-visible offset
	-- (0-0.05 studs), but enough to give each clone a distinct
	-- Y so the depth test resolves consistently per-frame instead
	-- of flickering. See HITBOX_Y_JITTER_MAX comment for why.
	clonedHitbox:PivotTo(hitboxCFrame + Vector3.new(0, math.random() * HITBOX_Y_JITTER_MAX, 0))
	clonedHitbox.Parent = HITBOX_PARENT

	-- Collect every BasePart upfront so the flash + death-fade loops
	-- don't re-walk descendants per tween.
	local parts: { BasePart } = {}
	for _, descendant in clonedHitbox:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end

	local state = {
		model = clonedHitbox,
		parts = parts,
		aborted = false,
		diedConn = nil,
	}
	activeFlashes[state] = true

	-- Hook the zombie's death so a kill mid-flash fades the visual.
	local humanoid = zombieModel:FindFirstChildOfClass("Humanoid")
	if humanoid then
		if humanoid.Health <= 0 then
			-- Already dead when the attack event arrived — skip the
			-- flash, jump straight to the fade-out.
			fadeOutHitbox(state)
			return
		end
		-- HealthChanged instead of Died:Once. Died has subtle timing
		-- quirks (doesn't fire reliably if the Humanoid is reparented
		-- or destroyed on the same frame Health hits 0 — MobBase's
		-- _relocateToDeadFolder reparents to DeadZombies in the same
		-- death tick, which can race the Died event). HealthChanged
		-- fires on every health write, so we just check `<= 0` inside
		-- and abort the flash. Connection (not :Once) so we keep the
		-- listener alive — fadeOutHitbox sets aborted=true which
		-- prevents double-fade if HealthChanged fires twice.
		state.diedConn = humanoid.HealthChanged:Connect(function(newHealth: number)
			if newHealth <= 0 then
				fadeOutHitbox(state)
			end
		end)
	end

	-- Race gate #2: player died DURING the flash. The runHitboxFlash
	-- coroutine checks state.aborted at every yield, so we don't need
	-- a pre-flash death recheck — the inline check inside the flash
	-- function handles it.
	task.spawn(function()
		runHitboxFlash(state, windUpDuration, hitFrameDuration)
	end)
end

--[ Initializers ]--

function ZombieController:KnitStart()
	-- Stamps the death-cinematic suppression window (see
	-- isLocalDeathCinematicPlaying above). Re-wired per character so a
	-- respawn's fresh instance gets its own listener.
	local function watchDeathAttribute(character: Model)
		if character:GetAttribute(Attributes.Death) == true then
			localDeathStartedAt = os.clock()
		end
		character:GetAttributeChangedSignal(Attributes.Death):Connect(function()
			if character:GetAttribute(Attributes.Death) == true then
				localDeathStartedAt = os.clock()
			end
		end)
	end

	if Players.LocalPlayer.Character then
		watchDeathAttribute(Players.LocalPlayer.Character)
	end
	Players.LocalPlayer.CharacterAdded:Connect(watchDeathAttribute)

	ZombieService = Knit.GetService("ZombieService")
	VFXController = Knit.GetController("VFXController")

	ZombieService.OnReplicateMobAttack:Connect(spawnHitboxFlash)

	-- Abort any lingering hitbox telegraphs when a boss phase change / outro
	-- cutscene begins — the frozen (or dead) mob shouldn't show a danger zone
	-- mid-scene. The server already cancelled the matching damage hitbox +
	-- lunge (ZombieService AttackInterrupted); this clears the client visual.
	local EncounterService = Knit.GetService("EncounterService")
	EncounterService.EncounterPhaseStart:Connect(abortAllHitboxFlashes)
	EncounterService.EncounterOutroStart:Connect(abortAllHitboxFlashes)

	-- Lunge tween: cosmetic only. Fires only for attacks with
	-- lungeDistance > 0. Server already PivotTo'd authoritatively;
	-- this just smooths the visual jump on the client.
	ZombieService.OnReplicateZombieAttack:Connect(
		function(zombieModel: Model, _startCFrame: CFrame, goalCFrame: CFrame, _timeStamp: number)
			if isLocalDeathCinematicPlaying() then
				return
			end

			local root = zombieModel:FindFirstChild("HumanoidRootPart")
			if not root then
				warn("[ZombieController] Replicated zombie model is missing HumanoidRootPart.")
				return
			end

			TweenService
				:Create(root, TweenInfo.new(LUNGE_TWEEN_DURATION, Enum.EasingStyle.Cubic), { CFrame = goalCFrame })
				:Play()
		end
	)

	-- Ranged projectile cast. Delegates to VFXController's
	-- MobProjectiles dispatcher — each projectile type has its own
	-- per-projectile module (WizardFireball.lua etc.) that owns the
	-- full client-side trajectory + impact callback. ZombieController
	-- stays a thin plumbing layer; the actual VFX logic lives co-
	-- located with the player magic spell modules under VFXController/.
	ZombieService.OnReplicateMobRangedAttack:Connect(
		function(
			zombieModel: Model,
			projectileName: string,
			originCFrame: CFrame,
			targetPosition: Vector3,
			castUuid: string,
			attackConfig: { speed: number, lifetime: number, hitRadius: number }
		)
			if isLocalDeathCinematicPlaying() then
				return
			end
			VFXController:RunMobProjectile(
				projectileName,
				zombieModel,
				originCFrame,
				targetPosition,
				castUuid,
				attackConfig
			)
		end
	)
end

function ZombieController:KnitInit() end

return ZombieController
