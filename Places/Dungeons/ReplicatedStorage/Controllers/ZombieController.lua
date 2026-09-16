--!strict
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

	It also owns the MAGIC-CUTSCENE DIM (SetCutsceneDim): for the length
	of a magic cutscene every mob under workspace.IgnoreInstances.Zombies
	-- regular, miniboss, boss, and any that spawn meanwhile -- is held
	semi-transparent on this client only, and put back exactly where it
	was when the cutscene ends. CutsceneController.PlayMagicCutscene is
	the caller. See the "Cutscene dim" section for the rules.

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

local VFXController = require(ReplicatedStorage.Controllers.VFXController)
local DungeonNetwork = require(ReplicatedStorage.Submodules.Core.Source.Network.Dungeon)
local Combat = require(ReplicatedStorage.Submodules.Core.Source.Network.Combat)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)

local ZombieController = {
	Name = "ZombieController",
	Dependencies = { VFXController } :: { any },
}

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

--[ Cutscene dim ]--

-- Transparency every mob body part is held at while a magic cutscene runs
-- (SetCutsceneDim). The dim only ever makes a part MORE transparent: one
-- already at or past this value -- the invisible HumanoidRootPart, the
-- hitbox parts, a corpse mid-fade -- is left exactly where it is.
local CUTSCENE_DIM_TRANSPARENCY = 0.75

-- Everything under a mob model that carries a Transparency the dim
-- touches: BaseParts and Decals (Texture inherits Decal, so the face and
-- any skin textures ride along with the part they sit on).
type Fadeable = BasePart | Decal

local function isFadeable(instance: Instance): boolean
	return instance:IsA("BasePart") or instance:IsA("Decal")
end

-- Reads go through the union fine; a WRITE needs the concrete class, so
-- every Transparency write the dim makes goes through here.
local function setTransparency(fadeable: Fadeable, value: number)
	if fadeable:IsA("BasePart") then
		fadeable.Transparency = value
	else
		(fadeable :: Decal).Transparency = value
	end
end

-- How many SetCutsceneDim(true) calls are outstanding. Overlapping
-- cutscenes dim once (0 -> 1) and restore once (1 -> 0).
ZombieController._cutsceneDimDepth = 0

-- What each tracked part looked like before the dim -- the value it goes
-- back to. STRONG keys, deliberately: a server-replicated mob part that
-- no client script references is only kept alive in Lua by a strong
-- reference, so a weak-keyed table would silently drop entries (and
-- their restore) mid-cutscene. Cleared on restore, so nothing is
-- retained past the window.
ZombieController._cutsceneDimOriginals = {} :: { [Fadeable]: number }

-- One Transparency-changed connection per tracked part, plus the
-- DescendantAdded watch on the mob folder that catches parts arriving
-- mid-cutscene (a mob spawning, a late-replicating accessory).
ZombieController._cutsceneDimConnections = {} :: { RBXScriptConnection }
ZombieController._cutsceneDimArrival = nil :: RBXScriptConnection?

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
-- localDeathStartedAt is stamped by the Death listener in Start.
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
type FlashState = {
	model: Model,
	parts: { BasePart },
	aborted: boolean,
	diedConn: RBXScriptConnection?,
}

local activeFlashes: { [any]: boolean } = {}

-- Cancels the in-flight flash and fades every part on the hitbox to
-- transparency 1. Idempotent. Called either from the death listener
-- (zombie killed mid-attack) or from the initial check below if the
-- zombie was already dead when the attack event arrived.
local function fadeOutHitbox(state: FlashState)
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
local function runHitboxFlash(state: FlashState, windUpDuration: number, hitFrameDuration: number)
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

	local state: FlashState = {
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

--[ Cutscene dim ]--

-- Takes one part under the dim: remembers what it looks like, dims it,
-- and follows every later write to it for as long as the dim lasts.
--
-- A write this client did not make is the new truth. The server's spawn
-- fade-in (1 -> 0 over 0.75s, MobBase._fadeInOnSpawn) and death fade-out
-- (-> 1, MobBase / Miniboss) both replicate per tween step and land on top
-- of the local value; each such step replaces the remembered original and
-- is dimmed again if it dropped below the dim. That is what keeps a mob
-- that spawns mid-cutscene dim as it fades in (and restores it to the
-- opaque value the fade ended on, not the transparent one it started at),
-- and what lets a corpse fade out through the cutscene without snapping
-- back to solid when it ends. Our own write is recognised by its value
-- and ignored, so the re-dim inside the handler cannot loop.
function ZombieController._trackCutsceneDim(self: typeof(ZombieController), instance: Instance)
	if not isFadeable(instance) then
		return
	end
	local fadeable = instance :: Fadeable
	if self._cutsceneDimOriginals[fadeable] ~= nil then
		return
	end
	self._cutsceneDimOriginals[fadeable] = fadeable.Transparency

	table.insert(
		self._cutsceneDimConnections,
		fadeable:GetPropertyChangedSignal("Transparency"):Connect(function()
			local current = fadeable.Transparency
			if current == CUTSCENE_DIM_TRANSPARENCY then
				return
			end
			self._cutsceneDimOriginals[fadeable] = current
			if current < CUTSCENE_DIM_TRANSPARENCY then
				setTransparency(fadeable, CUTSCENE_DIM_TRANSPARENCY)
			end
		end)
	)

	if fadeable.Transparency < CUTSCENE_DIM_TRANSPARENCY then
		setTransparency(fadeable, CUTSCENE_DIM_TRANSPARENCY)
	end
end

-- Dims every part of every live mob now, then every part that arrives
-- under the mob folder for as long as the dim lasts. The folder, not the
-- Zombie tag, because it is exactly the set of LIVE mobs (a corpse leaves
-- it for DeadZombies on death, keeping its tag) and is the same source
-- CharacterHighlightController reads.
function ZombieController._startCutsceneDim(self: typeof(ZombieController))
	local zombiesFolder = workspace.IgnoreInstances.Zombies
	for _, descendant in zombiesFolder:GetDescendants() do
		self:_trackCutsceneDim(descendant)
	end
	self._cutsceneDimArrival = zombiesFolder.DescendantAdded:Connect(function(descendant: Instance)
		self:_trackCutsceneDim(descendant)
	end)
end

-- Drops every watch, then puts back only the parts still showing OUR
-- value. A part someone else has written since -- a corpse that faded
-- out, a part whose replicated value moved past the dim -- already shows
-- the truth and is left alone. A part destroyed or unparented
-- mid-cutscene has nothing to come back to.
function ZombieController._stopCutsceneDim(self: typeof(ZombieController))
	if self._cutsceneDimArrival then
		self._cutsceneDimArrival:Disconnect()
		self._cutsceneDimArrival = nil
	end
	for _, connection in self._cutsceneDimConnections do
		connection:Disconnect()
	end
	table.clear(self._cutsceneDimConnections)

	for fadeable, original in self._cutsceneDimOriginals do
		if fadeable.Parent and fadeable.Transparency == CUTSCENE_DIM_TRANSPARENCY then
			setTransparency(fadeable, original)
		end
	end
	table.clear(self._cutsceneDimOriginals)
end

-- Public: renders every mob semi-transparent for the LOCAL player while a
-- magic cutscene runs (active = true) and restores them when it ends
-- (active = false). Reference-counted, so two overlapping cutscenes dim
-- once and restore once, when the last of them releases; a release with
-- nothing outstanding is a no-op. Local-only -- nothing here replicates,
-- and no other client system tweens mob body parts, so there is no
-- second writer to fight (CharacterHighlightController drives the mob
-- Highlight, never part Transparency).
function ZombieController.SetCutsceneDim(self: typeof(ZombieController), active: boolean)
	if active then
		self._cutsceneDimDepth += 1
		if self._cutsceneDimDepth == 1 then
			self:_startCutsceneDim()
		end
		return
	end

	if self._cutsceneDimDepth == 0 then
		return
	end
	self._cutsceneDimDepth -= 1
	if self._cutsceneDimDepth == 0 then
		self:_stopCutsceneDim()
	end
end

--[ Initializers ]--

function ZombieController.Start(_self: typeof(ZombieController))
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

	Combat.MobAttack.On(function(payload)
		if not payload.Mob then
			return
		end
		spawnHitboxFlash(
			payload.Mob,
			payload.HitboxName,
			payload.CFrame,
			payload.WindUpDuration,
			payload.HitFrameDuration
		)
	end)

	-- Abort any lingering hitbox telegraphs when a boss phase change / outro
	-- cutscene begins — the frozen (or dead) mob shouldn't show a danger zone
	-- mid-scene. The server already cancelled the matching damage hitbox +
	-- lunge (ZombieService AttackInterrupted); this clears the client visual.
	DungeonNetwork.EncounterPhaseStart.On(abortAllHitboxFlashes)
	DungeonNetwork.EncounterOutroStart.On(abortAllHitboxFlashes)

	-- Lunge tween: cosmetic only. Fires only for attacks with
	-- lungeDistance > 0. Server already PivotTo'd authoritatively;
	-- this just smooths the visual jump on the client.
	Combat.MobLunge.On(function(payload)
		local zombieModel = payload.Mob
		local goalCFrame = payload.GoalCFrame
		if not zombieModel then
			return
		end
		if isLocalDeathCinematicPlaying() then
			return
		end

		local root = zombieModel:FindFirstChild("HumanoidRootPart")
		if not root then
			warn("[ZombieController] Replicated zombie model is missing HumanoidRootPart.")
			return
		end

		TweenService:Create(root, TweenInfo.new(LUNGE_TWEEN_DURATION, Enum.EasingStyle.Cubic), { CFrame = goalCFrame })
			:Play()
	end)

	-- Ranged projectile cast. Delegates to VFXController's
	-- MobProjectiles dispatcher — each projectile type has its own
	-- per-projectile module (WizardFireball.lua etc.) that owns the
	-- full client-side trajectory + impact callback. ZombieController
	-- stays a thin plumbing layer; the actual VFX logic lives co-
	-- located with the player magic spell modules under VFXController/.
	Combat.MobRangedAttack.On(function(payload)
		local zombieModel = payload.Mob
		if not zombieModel then
			return
		end
		local projectileName = payload.ProjectileName
		local originCFrame = payload.OriginCFrame
		local targetPosition = payload.TargetPosition
		local castUuid = payload.CastUuid
		local attackConfig = {
			speed = payload.Speed,
			lifetime = payload.Lifetime,
			hitRadius = payload.HitRadius,
			explosionRadius = payload.ExplosionRadius,
		}
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
	end)
end

return ZombieController
