--!strict
--[[
     Module: LifeController.lua
     Description:
     Client-side glue for LifeService. Subscribes to the server's death
     lifecycle broadcasts and re-emits them through local Signal objects
     so client systems (VFX, audio, screen flashes, etc.) can hook in
     without needing to know about the network layer.

     Death is two server-authoritative phases (see LifeService):
       DOWNED (PlayerDied)        the body stays where it fell, fully
                                  visible. The local player gets the
                                  impact, the Game Over screen with the
                                  revive window's bar and REVIVE button,
                                  the red hold and the half fade. Nothing
                                  else moves: no body fade, no gravestone,
                                  no spectate.
       DEAD (PlayerFullyDied)     the window closed. Every client fades
                                  the body; the local player fades to
                                  black, the screen clears under it and
                                  spectate begins. A wipe (IsWipe) leaves
                                  the screen up for GameOver instead.
     A revive (PlayerRevived) tears the local overlays down in either
     phase and restores a faded body.

     Identification: server fires with `userId`. Listeners that only care
     about the local player should compare userId == Players.LocalPlayer.UserId
     themselves; LifeController forwards the raw value rather than
     pre-splitting, so it stays useful for spectator UI that needs to
     react to other players' deaths too.
]]
local Lighting = game:GetService("Lighting")

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Blitz = require(ReplicatedStorage.Submodules.Core.Shared.Blitz)
local CharacterHighlightController = require(ReplicatedStorage.Controllers.CharacterHighlightController)
local ScreenFadeInterfaceController =
	require(ReplicatedStorage.Submodules.Core.Source.Interfaces.ScreenFadeInterfaceController)
local CinematicInterfaceController =
	require(ReplicatedStorage.Submodules.Core.Source.Interfaces.CinematicInterfaceController)
local ScreenGradientInterfaceController = require(ReplicatedStorage.Interfaces.ScreenGradientInterfaceController)
local GameOverGradientInterfaceController = require(ReplicatedStorage.Interfaces.GameOverGradientInterfaceController)
local CameraShakeController = require(ReplicatedStorage.Controllers.CameraShakeController)
local CutsceneController = require(ReplicatedStorage.Controllers.CutsceneController)
local InterfaceManagerController =
	require(ReplicatedStorage.Submodules.Core.Source.Controllers.InterfaceManagerController)
local LivesInterfaceController = require(ReplicatedStorage.Interfaces.LivesInterfaceController)
local PlayerNetwork = require(ReplicatedStorage.Submodules.Core.Source.Network.Player)
local RemoteProperty = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Network.RemoteProperty)
local CameraShakePresets = require(ReplicatedStorage.Submodules.Core.Shared.Enums.CameraShakePresets)
local Signal = require(ReplicatedStorage.Submodules.Core.Packages.Signal)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local ColorCorrectionDefaults = require(ReplicatedStorage.Submodules.Core.Shared.Data.ColorCorrectionDefaults)
local HumanoidProperties = require(ReplicatedStorage.Submodules.Core.Shared.Data.HumanoidProperties)
local getEffectiveBaseWalkSpeed =
	require(ReplicatedStorage.Submodules.Core.Shared.Functions.Movement.getEffectiveBaseWalkSpeed)
local getEffectiveJetpackWalkSpeed =
	require(ReplicatedStorage.Submodules.Core.Shared.Functions.Movement.getEffectiveJetpackWalkSpeed)
local DeathCinematicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.DeathCinematicData)
-- The death flash is a LAYER of the local character's single Highlight
-- (CharacterHighlightController), not its own instance: the old
-- onDeathIndicator highlight was never destroyed, so from the first down
-- on it owned the character's one rendering slot and the through-wall
-- outline never drew again for that life.
local InterfaceScopes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.InterfaceScopes)

-- Hide source held on the HUD scope for the death → revive window. Named so
-- it composes: a revive releasing it won't bring the HUD back if a cutscene
-- or a manual CloseInterface is still holding the same scope.
local HUD_DEATH_SOURCE = "Death"

-- HUD interface controllers we drive via their SetVisible signals during
-- the death + revive lifecycle. We never reach into PlayerGui to flip
-- ScreenGui.Enabled on these directly — each interface owns its own
-- visibility state and exposes a Signal as the public toggle.
local MobileActionButtonInterface: any = nil

local LifeController = {
	Name = "LifeController",
	Dependencies = {
		CharacterHighlightController,
		ScreenFadeInterfaceController,
		CinematicInterfaceController,
		ScreenGradientInterfaceController,
		GameOverGradientInterfaceController,
		CameraShakeController,
		CutsceneController,
		InterfaceManagerController,
		LivesInterfaceController,
	} :: { any },
}

-- Replicated lives snapshot, { [userId] = { current, max } } (was
-- LifeService.LivesData). Owned here so every consumer shares one
-- subscription; LivesInterfaceController observes it.
LifeController.LivesData = RemoteProperty.Client({
	changed = PlayerNetwork.LivesDataChanged,
	get = PlayerNetwork.GetLivesData,
})

-- Replicated death snapshot, keyed by userId (was LifeService.DeathState).
-- TombstoneController observes it too.
LifeController.DeathState = RemoteProperty.Client({
	changed = PlayerNetwork.DeathStateChanged,
	get = PlayerNetwork.GetDeathState,
})

-- Death cinematic timings — sourced from Shared/Data/DeathCinematicData so
-- LifeController, GameOverGradientInterfaceController, and its Container all
-- stay in lockstep. To re-tune the cinematic, edit DeathCinematicData; the
-- locals below propagate the change automatically. The revive window
-- itself (GameOverDuration) is never read here: the server stamps its end
-- time on the death state and the screen counts down to that.
-- AUTHORED colour grade — the values the place's ColorCorrection is
-- built with, pinned in Shared/Data/ColorCorrectionDefaults (the one
-- source every grade-bending effect restores to). The death cinematic
-- desaturates and blurs the screen and the impact slams the tint; the
-- revive puts ALL of it back to these, so a respawn always lands on the
-- authored look. (Reading Lighting at load was tried first: it silently
-- captured whatever an earlier effect had left there.)
local AUTHORED_SATURATION = ColorCorrectionDefaults.Saturation

-- DEATH IMPACT FRAME: the hit that killed you, on screen. TintColor /
-- Brightness / Contrast SNAP to a red slam on the death tick and decay
-- back to the authored values. Saturation is deliberately NOT touched
-- — the death cinematic and the Game Over path own it (they tween it
-- to -0.5 and restore it), and two systems on one property would
-- fight. The Game Over title then waits DEATH_IMPACT_TO_GAME_OVER so
-- the impact lands FIRST and the screen follows it.
local AUTHORED_TINT = ColorCorrectionDefaults.TintColor
local AUTHORED_BRIGHTNESS = ColorCorrectionDefaults.Brightness
local AUTHORED_CONTRAST = ColorCorrectionDefaults.Contrast
-- WHY IT DIDN'T LAND BEFORE: a single-frame snap that started decaying
-- on the very next frame. Intensity alone could not fix that — the eye
-- needs the peak HELD for several frames to register it as a hit. So:
--   1. SLAM  — snap to the peak and HOLD it (a true freeze-frame),
--   2. DECAY — an exponential drain, so the red hangs then drops,
--   3. ECHO  — a second, smaller slam a beat later (a heartbeat),
--      which bridges the gap until the Game Over title lands,
-- with a Large camera shake under the first slam. Every one is a knob.
local DEATH_IMPACT_TINT = Color3.fromRGB(255, 25, 25)
local DEATH_IMPACT_BRIGHTNESS = 0.5
local DEATH_IMPACT_CONTRAST = 0.75
local DEATH_IMPACT_HOLD_SECONDS = 0.18
local DEATH_IMPACT_DECAY_SECONDS = 0.65
local DEATH_IMPACT_ECHO_DELAY_SECONDS = 0.55
local DEATH_IMPACT_ECHO_SCALE = 0.45
-- Shared with LifeService through DeathCinematicData: the server opens the
-- revive window this far (plus the screen's startup pause) after the
-- downing, so the bar flies in full.
local DEATH_IMPACT_TO_GAME_OVER_SECONDS = DeathCinematicData.GameOverImpactDelay

local AUTHORED_BLUR_SIZE = Lighting.Blur.Size

local DEATH_FADE_DURATION = DeathCinematicData.FadeDuration
local DEATH_BLACK_HOLD_DURATION = DeathCinematicData.BlackHoldDuration

-- Body fade. Starts the moment a player is FULLY dead (the server's
-- window expired), not on a local timer: while downed the body is meant
-- to be seen lying there, revive button and all. The server keeps the
-- death pose frozen until after this tween, so the humanoid never
-- visibly stands back up under a still-visible body.
local CHARACTER_FADE_DURATION = DEATH_BLACK_HOLD_DURATION

--[ Red flash overlay tuning ]--

-- A single quick red pulse fired the instant the local player dies. Punches
-- in fast (PUNCH duration), then fades out over FADE duration. Visceral hit
-- moment before the slower death cinematic plays. Self-contained ScreenGui
-- so we don't need a persistent interface controller for it.

--[ Module-scope helpers (no per-event closure allocation) ]--

local function captureAndTweenCharacterToInvisible(character: Model): { { part: any, transparency: number } }
	local cache = table.create(1000)
	-- Honor CHARACTER_FADE_DURATION (was previously hardcoded 0.5 here,
	-- which silently disagreed with the named constant). With the new
	-- ~1.5s start offset + this duration the body fade visibly happens
	-- *during* the early red flash instead of as a late blip.
	local tweenInfo = TweenInfo.new(CHARACTER_FADE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

	for _, descendant in character:GetDescendants() do
		if descendant:IsA("BasePart") or descendant:IsA("Decal") or descendant:IsA("Texture") then
			if descendant.Transparency == 1 then
				continue
			end

			table.insert(cache, { part = descendant, transparency = descendant.Transparency })
			TweenService:Create(descendant, tweenInfo, { Transparency = 1 }):Play()
		end
	end

	return cache
end

-- Tweens each cached part back to its captured Transparency. Skips parts
-- that have since been destroyed (character respawn, leaver, etc.).
local function tweenRestoreCharacterTransparency(cache: { { part: any, transparency: number } }?)
	if not cache then
		return
	end
	local tweenInfo = TweenInfo.new(CHARACTER_FADE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	for _, entry in cache do
		if entry.part and entry.part.Parent then
			TweenService:Create(entry.part, tweenInfo, { Transparency = entry.transparency }):Play()
		end
	end
end

-- Walks every descendant of `root` and either caches+writes Transparency=1
-- (for BasePart / Decal / Texture) or caches+disables (for BillboardGui /
-- ParticleEmitter). Push into the three caller-provided tables so the
-- restore-on-revive loop can put everything back.
--
-- Consolidated into one helper so the dungeon-rooms / zombies / players /
-- relics paths all use the same type-handling logic. Saves duplicating
-- the IsA chain four times and makes adding a new source one line.
--
-- Skips nil / unparented roots defensively (relic models can vanish
-- between getting tagged and us iterating).
local function _fadeRootAndCache(
	root: Instance?,
	cachedTransparency: { { part: any, transparency: number } },
	screenGuis: { { part: any, enabled: boolean } },
	particles: { { part: any, enabled: boolean } }
)
	if not root or not root.Parent then
		return
	end

	for _, part in root:GetDescendants() do
		-- Texture is a Decal subclass, so the Decal branch covers both. Two
		-- identical branches on purpose: the old solver cannot write a
		-- property through a union of Instance classes.
		-- selene: allow(if_same_then_else)
		if part:IsA("BasePart") then
			table.insert(cachedTransparency, { part = part :: Instance, transparency = part.Transparency })
			part.Transparency = 1
		elseif part:IsA("Decal") then
			table.insert(cachedTransparency, { part = part :: Instance, transparency = part.Transparency })
			part.Transparency = 1
		elseif part:IsA("BillboardGui") then
			table.insert(screenGuis, { part = part, enabled = part.Enabled })
			part.Enabled = false
		elseif part:IsA("ParticleEmitter") then
			table.insert(particles, { part = part, enabled = part.Enabled })
			part.Enabled = false
		end
	end
end

--[ Local-only signals for downstream VFX / UI hooks ]--

-- Each fires with userId (number). Subscribers filter for local vs. remote
-- as needed.
LifeController.OnLifeLost = Signal.new()
LifeController.OnPlayerDied = Signal.new() -- downed: the revive window opened
LifeController.OnPlayerFullyDied = Signal.new() -- the window closed, gone for good
LifeController.OnPlayerRevived = Signal.new()

-- Local-only signal indicating whether the LOCAL player is in the
-- "actively spectating" visual state. Distinct from server-side
-- DeathState — DeathState flips true the instant the player dies, but
-- the spectate UI shouldn't appear until AFTER the death-fade completes.
-- This signal gates the UI: flips true at the end of the death-fade
-- sequence (when the screen is fading back from black), flips false at
-- the start of the revive-fade (when the screen is fading to black to
-- cover the teleport). Subscribed by SpectateInterfaceController +
-- SpectateController.
LifeController.OnSpectateStateChanged = Signal.new() -- (isSpectating: boolean)

--[ Properties ]--

-- Cached PlayerModule:GetControls() handle. Same lazy-load pattern as
-- EncounterIntroController so we don't take a require dependency on
-- PlayerScripts at controller boot.
LifeController._playerControls = nil :: any

-- True while we currently hold the controls lock. Tracked so we don't
-- redundantly Disable/Enable across rapid DeathState toggles, and so we
-- never Enable controls we didn't take in the first place (which would
-- step on EncounterIntroController's lock during an encounter cinematic).
LifeController._controlsLocked = false

-- Current "actively spectating" state for the LOCAL player. Read via
-- :IsLocalSpectating() (used by UIs to seed their React state on mount,
-- since they might mount after the signal has already fired).
LifeController._isLocalSpectating = false
LifeController._isLocalDead = false

-- Per-userId cache for the body-fade. Holds the pre-fade transparency of
-- every BasePart/Decal/Texture on the dead character so we can
-- tween-restore them on revive (player might be wearing semi-transparent
-- gear; we don't want to wipe that to 0). Written on PlayerFullyDied,
-- consumed on PlayerRevived.
LifeController._characterFadeCaches = {} :: { [number]: { { part: any, transparency: number } } }
LifeController._isGameOver = false -- true after the all-dead trigger, until teleport or reload
-- True while the LOCAL player's downed screen (Game Over overlay + red
-- hold) is painted: from the downed tick until it clears for spectate or
-- a revive tears it down. GameOver reads it so a wipe never replays the
-- impact or restacks the overlay on a screen that is already showing it.
LifeController._localScreenUp = false
-- The revive window last pushed to the Game Over screen (its server end
-- time), so DeathState updates for OTHER players do not re-push it.
LifeController._pushedReviveWindowEndsAt = nil :: number?
-- Bumped per death impact; a scheduled hold-release or echo from an
-- earlier death checks it before touching Lighting.
LifeController._deathImpactToken = 0

--[ Private helpers ]--

-- Convenience: prefix a log message with "[local]" or the player's name.
local function nameFor(userId: number): string
	local player = Players:GetPlayerByUserId(userId)
	if not player then
		return ("(unknown userId=%d)"):format(userId)
	end
	if player == Players.LocalPlayer then
		return ("%s [local]"):format(player.Name)
	end
	return player.Name
end

--[ Private helpers: controls lock ]--

-- Lazy-loads PlayerModule:GetControls(). Returns nil if PlayerScripts
-- hasn't streamed in yet (caller no-ops). Matches EncounterIntroController's
-- pattern exactly so the two locks are interchangeable.
-- The red impact frame. Snaps IN on one frame — a hit does not ease in
-- — then eases OUT over the decay. Local-only: Lighting is per client.
function LifeController._playDeathImpact(self: typeof(LifeController))
	self._deathImpactToken += 1
	local token = self._deathImpactToken
	local colorCorrection = Lighting.ColorCorrection

	-- Snap to `scale` of the way from the authored look to the peak.
	local function slam(scale: number)
		colorCorrection.TintColor = AUTHORED_TINT:Lerp(DEATH_IMPACT_TINT, scale)
		colorCorrection.Brightness = AUTHORED_BRIGHTNESS + (DEATH_IMPACT_BRIGHTNESS - AUTHORED_BRIGHTNESS) * scale
		colorCorrection.Contrast = AUTHORED_CONTRAST + (DEATH_IMPACT_CONTRAST - AUTHORED_CONTRAST) * scale
	end

	-- Exponential-out: hangs at the top, then drains.
	local function decay()
		TweenService:Create(
			colorCorrection,
			TweenInfo.new(DEATH_IMPACT_DECAY_SECONDS, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out),
			{ TintColor = AUTHORED_TINT, Brightness = AUTHORED_BRIGHTNESS, Contrast = AUTHORED_CONTRAST }
		):Play()
	end

	-- 1. SLAM, with the shake under it, and HOLD the peak.
	if CameraShakeController then
		CameraShakeController:Shake(CameraShakePresets.Death)
	end

	slam(1)
	task.delay(DEATH_IMPACT_HOLD_SECONDS, function()
		if self._deathImpactToken ~= token then
			return
		end
		decay() -- 2. DECAY
	end)

	-- 3. ECHO: the heartbeat. Half the hold, then the same drain.
	task.delay(DEATH_IMPACT_ECHO_DELAY_SECONDS, function()
		if self._deathImpactToken ~= token then
			return
		end
		slam(DEATH_IMPACT_ECHO_SCALE)
		task.delay(DEATH_IMPACT_HOLD_SECONDS * 0.5, function()
			if self._deathImpactToken ~= token then
				return
			end
			decay()
		end)
	end)
end

function LifeController._getPlayerControls(self: typeof(LifeController))
	if self._playerControls then
		return self._playerControls
	end
	local playerScripts = Players.LocalPlayer:FindFirstChild("PlayerScripts")
	if not playerScripts then
		return nil
	end
	local playerModuleScript = playerScripts:FindFirstChild("PlayerModule")
	if not playerModuleScript then
		return nil
	end
	local ok, playerModule = pcall(require, playerModuleScript)
	if not ok or not playerModule then
		return nil
	end
	self._playerControls = playerModule:GetControls()
	return self._playerControls
end

-- Revokes movement input via PlayerModule:GetControls():Disable(). Other
-- ability gates (dodge, magic, weapon fire) are handled by
-- PlayerStateController checking Attributes.Death — both are set by the
-- server-replicated attribute, so this controller doesn't need to touch them.
-- Idempotent.
function LifeController._lockControls(self: typeof(LifeController))
	if self._controlsLocked then
		warn("[LifeController] Controls already locked; skipping redundant lock")
		return
	end
	local controls = self:_getPlayerControls()

	if not controls then
		warn("[LifeController] Couldn't get PlayerModule controls; can't lock movement input")
		return
	end

	controls:Disable()
	self._controlsLocked = true

	-- Zero out any residual move vector the ControlScript captured before
	-- we disabled it — without this the character keeps drifting in the
	-- last-pressed direction during the ragdoll.
	local character = Players.LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")

	if humanoid then
		print("[LifeController] Locking controls: setting WalkSpeed=0 to stop residual movement")
		humanoid.WalkSpeed = 0
	end
end

-- Reverses _lockControls. Only Enables if we previously Disabled — won't
-- step on a lock held by another controller (e.g. EncounterIntroController
-- during an encounter cinematic that happens to overlap a revive).
function LifeController._unlockControls(self: typeof(LifeController))
	if not self._controlsLocked then
		return
	end
	local controls = self:_getPlayerControls()
	if not controls then
		self._controlsLocked = false
		return
	end
	controls:Enable()
	self._controlsLocked = false

	-- Restore WalkSpeed. Matches the convention used throughout the
	-- weapon / VFX code: jetpack speed if on jetpack, default otherwise.
	-- (Jetpack is almost certainly off after revive, but the check is
	-- cheap insurance.)
	local character = Players.LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		if character:GetAttribute(Attributes.OnJetpack) == true then
			humanoid.WalkSpeed = getEffectiveJetpackWalkSpeed()
		else
			humanoid.WalkSpeed = getEffectiveBaseWalkSpeed(HumanoidProperties.WalkSpeed)
		end
	end
end

-- Updates the local spectating state + fires OnSpectateStateChanged.
-- No-op when value matches current (debounces duplicate sets).
function LifeController._setSpectatingState(self: typeof(LifeController), value: boolean)
	if self._isLocalSpectating == value then
		return
	end
	self._isLocalSpectating = value
	self.OnSpectateStateChanged:Fire(value)

	-- Globally disable proximity prompts for this client while
	-- spectating. ProximityPromptService.Enabled is a client-local
	-- property — flipping it here doesn't affect other players or the
	-- server, just gates every prompt's input handling for the dead
	-- viewer. Without this, a spectator could still hold the prompt
	-- key on a relic / gear drop / vending machine they're orbiting
	-- and trigger pickup logic for a character that no longer exists.
	-- Cheaper than gating each of the three per-prompt Triggered
	-- handlers (GearDrop, RelicMachine, Relic) individually and
	-- covers any future prompts automatically.
	self:_refreshPromptGate()
end

-- Proximity prompts are gated for this client while it is DEAD or
-- SPECTATING. ProximityPromptService.Enabled is client-local: flipping it
-- affects no other player and not the server, it just stops every prompt
-- from taking input for a character that no longer acts. Dead comes first:
-- the corpse lies there for a moment before spectate begins, and the run
-- gear spilling out of it must not be collectable by the body it fell from.
-- The server refuses a dead player's pickup too; this is the UX half.
function LifeController._refreshPromptGate(self: typeof(LifeController))
	ProximityPromptService.Enabled = not self._isLocalDead and not self._isLocalSpectating
end

-- Synchronous getter — used by UIs that mount AFTER the signal has
-- already fired and need to seed their initial state.
function LifeController.IsLocalSpectating(self: typeof(LifeController)): boolean
	return self._isLocalSpectating
end

-- Fans `visible` out to every HUD interface that should hide during the
-- death + revive window via their public SetVisible signals. Each interface
-- owns its own visibility state and decides how to render it — we just say
-- "go hidden" / "come back". Add a new HUD-while-dead interface here AND
-- give that interface its own SetVisible signal; no PlayerGui scanning.
--
-- Each ref is nil-guarded because Start wires them in order; if the
-- controller resolution ever races (or a controller is missing from the
-- build), we want a warn-less no-op rather than a hard crash.
function LifeController._setHudVisible(_self: typeof(LifeController), visible: boolean)
	-- PlayerVitals and ToolBar are registered in InterfaceManagerController's
	-- HUD scope, so death goes through it as a named hide source rather than
	-- firing their SetVisible signals directly. That keeps the manager the
	-- single writer for those two: a revive can't un-hide them while a
	-- cutscene or a manual CloseInterface is still holding the scope down.
	--
	-- The interfaces BELOW aren't registered (yet), so they keep their direct
	-- signal path. Move one up here when you scope it.
	if InterfaceManagerController then
		if visible then
			InterfaceManagerController:Show(InterfaceScopes.HUD, HUD_DEATH_SOURCE)
		else
			InterfaceManagerController:Hide(InterfaceScopes.HUD, HUD_DEATH_SOURCE)
		end
	end

	if LivesInterfaceController then
		LivesInterfaceController.Signals.SetVisible:Fire(visible)
	end
	-- Mobile bundle (custom mobile buttons + Roblox-instanced TouchGui
	-- with the thumbstick / jump button). MobileActionButtonInterface
	-- gates its own mount on platform detection — firing this on desktop
	-- is harmless because _Reconcile sees _mobileEnabled=false and bails
	-- before touching anything.
	if MobileActionButtonInterface then
		MobileActionButtonInterface.Signals.SetVisible:Fire(visible)
	end
end

--[ Lifecycle ]--

function LifeController.Start(self: typeof(LifeController))
	MobileActionButtonInterface = Blitz.OptionalController("MobileActionButtonInterface")

	PlayerNetwork.LifeLost.On(function(userId: number)
		print(("[LifeController] %s lost a life"):format(nameFor(userId)))
		self.OnLifeLost:Fire(userId)
	end)

	-- DOWNED. The body stays where it fell, fully visible: no body fade, no
	-- gravestone, no spectate yet. For the local player the Game Over
	-- screen goes up with the revive window's bar and REVIVE button; the
	-- fully dead beat (PlayerFullyDied) or a revive (PlayerRevived) ends it.
	PlayerNetwork.PlayerDied.On(function(userId: number)
		print(("[LifeController] %s is downed"):format(nameFor(userId)))
		self.OnPlayerDied:Fire(userId)

		CutsceneController:CancelActiveAbility(false)

		if userId ~= Players.LocalPlayer.UserId then
			return
		end

		self._localScreenUp = true

		CharacterHighlightController:RequestDeathFlash(Players.LocalPlayer.Character)

		-- The Game Over screen is the ONLY death screen — it paints on every
		-- death regardless of party size or how many players are still
		-- alive. While downed it carries the revive window (bar counting
		-- down to the server's end time, REVIVE button); on a wipe it stays
		-- up as the wipe screen. DeathGradientInterfaceController ("You
		-- Died") is intentionally never fired now; the controller itself is
		-- left registered so restoring it is a one-line change.
		--
		-- death=true → the pulse handler takes the long-hold branch
		-- (multi-second timeout vs 0.25s for normal pulses) so the title
		-- + subtitle fly-in has time to play through the startup pause
		-- and stagger inside the Container's useEffect. Without the flag,
		-- the auto-reset would flip pulseGradient false at 0.25s — BEFORE
		-- the fly-in even starts — and the text would never get a
		-- follow-up pulse-out edge to fade itself out on.
		-- The impact frame first; the Game Over title follows it after a
		-- beat, so the death reads as a HIT before it reads as a screen.
		self:_playDeathImpact()
		task.delay(DEATH_IMPACT_TO_GAME_OVER_SECONDS, function()
			if not self._localScreenUp then
				return -- revived inside the beat; nothing to paint
			end
			GameOverGradientInterfaceController.Signals.OnPulseGradient:Fire(Color3.fromRGB(255, 0, 0), true)
		end)

		-- Downed-phase overlay. Red persistent gradient at 0.35 transparency
		-- held for the whole window; the fully-dead beat crossfades it to
		-- black under the fade so the spectate reveal shows a black overlay.
		-- Fires here on the downed tick so the red is visible from frame 1.
		ScreenGradientInterfaceController.Signals.OnSetHold:Fire(Color3.fromRGB(255, 0, 0), 0.35)

		TweenService:Create(
			Lighting.ColorCorrection,
			TweenInfo.new(1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Saturation = -0.5 }
		):Play()

		TweenService:Create(
			Lighting.Blur,
			TweenInfo.new(DEATH_FADE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Size = 7.5 }
		):Play()

		-- Half fade: the world dims behind the screen but the body, the
		-- fight and the button all stay readable for the whole window.
		ScreenFadeInterfaceController.Signals.FadeIn:Fire(DEATH_FADE_DURATION, 0.5)
	end)

	-- FULLY DEAD: the window closed with no revive. Every client fades the
	-- body now (the server releases the frozen pose only after this tween).
	-- The local player fades to black, clears the screen under it and
	-- enters spectate -- unless this death completed a WIPE, in which case
	-- the screen stays up and the GameOver handler owns it from here.
	PlayerNetwork.PlayerFullyDied.On(function(payload: { UserId: number, IsWipe: boolean })
		local userId, isWipe = payload.UserId, payload.IsWipe
		print(("[LifeController] %s fully died (wipe=%s)"):format(nameFor(userId), tostring(isWipe == true)))
		self.OnPlayerFullyDied:Fire(userId)

		local diedPlayer = Players:GetPlayerByUserId(userId)
		local character = diedPlayer and diedPlayer.Character
		if character and not self._characterFadeCaches[userId] then
			self._characterFadeCaches[userId] = captureAndTweenCharacterToInvisible(character)
		end

		if userId ~= Players.LocalPlayer.UserId then
			return
		end

		-- Wipe-completing death: no black fade, no spectate. The downed
		-- screen (title up, bar at zero, button gone with the phase) IS the
		-- wipe screen; GameOver arrives right behind this and only flags.
		if isWipe == true then
			return
		end

		task.spawn(function()
			ScreenFadeInterfaceController.Signals.FadeIn:Fire(DEATH_FADE_DURATION, 0)

			task.wait(DEATH_FADE_DURATION)

			ScreenGradientInterfaceController.Signals.OnSetHold:Fire(Color3.fromRGB(0, 0, 0), 0.35)

			if self._isGameOver then
				return
			end

			-- The screen is fully black here, so this is the one moment the
			-- Game Over overlay (title, subtitle, bar) can go without being
			-- seen. Its gameOver pulse never self-clears (it assumes a
			-- teleport), so without this the spectating player sat under
			-- "Eternal Damnation" the whole time -- and the pulse latch
			-- stayed set, which also swallowed the real wipe screen later.
			if GameOverGradientInterfaceController then
				GameOverGradientInterfaceController.Signals.OnClearGradient:Fire()
			end
			self._localScreenUp = false

			PlayerNetwork.SpectateRequested.Fire()

			self:_setSpectatingState(true)

			task.wait(DEATH_BLACK_HOLD_DURATION)

			ScreenFadeInterfaceController.Signals.FadeOut:Fire(DEATH_FADE_DURATION)
		end)
	end)

	-- Revive VFX hook. The fade + teleport itself is server-orchestrated
	-- via PlayerNetwork.RevivalFade — we just print the animation hook here
	-- so any client VFX code has a single subscribe point.
	PlayerNetwork.PlayerRevived.On(function(userId: number)
		print(("[LifeController] %s revived"):format(nameFor(userId)))
		self.OnPlayerRevived:Fire(userId)

		-- Only a FULLY dead body was faded; a downed one stands up as it is.
		local cache = self._characterFadeCaches[userId]

		if cache then
			tweenRestoreCharacterTransparency(cache)
			self._characterFadeCaches[userId] = nil
		end

		if userId == Players.LocalPlayer.UserId then
			self._localScreenUp = false

			-- Retire any impact beat still pending (a slam or decay landing
			-- AFTER this restore would leave the grade off), then put the
			-- WHOLE grade back to the authored values in one tween.
			self._deathImpactToken += 1
			TweenService
				:Create(Lighting.ColorCorrection, TweenInfo.new(1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
					Saturation = AUTHORED_SATURATION,
					TintColor = AUTHORED_TINT,
					Brightness = AUTHORED_BRIGHTNESS,
					Contrast = AUTHORED_CONTRAST,
				})
				:Play()

			-- Tear down EVERY death overlay. Guarded individually: an unresolved
			-- controller used to throw here and abort the rest of the teardown,
			-- leaving the player alive under a stuck screen.
			if ScreenGradientInterfaceController then
				ScreenGradientInterfaceController.Signals.OnClearHold:Fire(1)
			end

			-- Game Over never self-clears (its pulse assumes a teleport), so a
			-- revive has to clear it explicitly or it stays up forever.
			if GameOverGradientInterfaceController then
				GameOverGradientInterfaceController.Signals.OnClearGradient:Fire()
			end

			TweenService:Create(
				Lighting.Blur,
				TweenInfo.new(1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Size = AUTHORED_BLUR_SIZE }
			):Play()

			if ScreenFadeInterfaceController then
				ScreenFadeInterfaceController.Signals.FadeOut:Fire(DEATH_FADE_DURATION)
			end

			-- VFX hook (replace with real revive VFX/animation later).
			print("[LifeController] Revive Animation")
		end
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		self._characterFadeCaches[player.UserId] = nil
	end)

	PlayerNetwork.RevivalFade.On(function(payload: { Phase: string, Duration: number })
		if not ScreenFadeInterfaceController then
			return
		end
		local duration = payload.Duration
		if payload.Phase == "in" then
			self:_setSpectatingState(false)
			ScreenFadeInterfaceController.Signals.FadeIn:Fire(duration)
		elseif payload.Phase == "out" then
			ScreenFadeInterfaceController.Signals.FadeOut:Fire(duration)

			task.delay(duration, function()
				if CinematicInterfaceController then
					CinematicInterfaceController.Signals.OnCinematicStart:Fire()
				end
			end)
		end
	end)

	PlayerNetwork.TeleportToLobby.On(function()
		-- self:_setSpectatingState(false)
		-- self:_setHudVisible(false)

		-- if CinematicInterfaceController then
		-- 	CinematicInterfaceController.Signals.OnCinematicEnd:Fire()
		-- end
	end)

	PlayerNetwork.GameOver.On(function()
		print("[LifeController] Game Over — wipe broadcast received")

		self._isGameOver = true

		-- The player whose window just closed is still looking at the
		-- downed screen: title up, bar at zero, button gone with their
		-- "downed" phase. The wipe adds nothing for them -- no second
		-- impact, no restacked overlay. (Solo play always lands here.)
		if self._localScreenUp then
			return
		end

		-- Otherwise the local player was already fully dead and spectating
		-- with a cleared screen: paint the wipe screen for them, without
		-- the impact (they had theirs when they fell). Read before the
		-- spectate reset below clears the evidence.
		local justDied = not self:IsLocalSpectating()

		self:_setSpectatingState(false)

		if justDied then
			self:_playDeathImpact()
		end

		TweenService:Create(
			Lighting.ColorCorrection,
			TweenInfo.new(1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Saturation = -0.5 }
		):Play()

		TweenService:Create(
			Lighting.Blur,
			TweenInfo.new(DEATH_FADE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Size = 5 }
		):Play()

		ScreenFadeInterfaceController.Signals.FadeIn:Fire(DEATH_FADE_DURATION, 0.5)

		if ScreenGradientInterfaceController then
			ScreenGradientInterfaceController.Signals.OnSetHold:Fire(Color3.fromRGB(255, 0, 0), 0.35)
		end

		if GameOverGradientInterfaceController then
			-- Delayed for EVERYONE, not just whoever took the hit, so the
			-- title lands at the same moment on every screen.
			task.delay(DEATH_IMPACT_TO_GAME_OVER_SECONDS, function()
				GameOverGradientInterfaceController.Signals.OnPulseGradient:Fire(Color3.fromRGB(255, 0, 0), true)
			end)
		end
	end)

	-- Snapshot shape per entry (LifeService._replicateDeathState):
	--   { phase = "downed" | "dead", diedAtServerTime, windowEndsAtServerTime,
	--     fullyDiedAtServerTime?, deathPosition, player }
	self.DeathState:Observe(function(deathState: { [any]: any }?)
		local localId = Players.LocalPlayer.UserId
		local localEntry = deathState and (deathState[localId] or deathState[tostring(localId)])
		self._isLocalDead = localEntry ~= nil
		self:_refreshPromptGate()

		-- The revive window, to the Game Over screen: its bar counts down
		-- to the SERVER end time (right remainder on a laggy or late
		-- client) and its REVIVE button shows only while the phase is
		-- "downed". nil once fully dead, revived, or never down. Pushed on
		-- change only: this observer also runs for other players' deaths.
		local windowEndsAt: number? = nil
		if localEntry and localEntry.phase == "downed" then
			windowEndsAt = localEntry.windowEndsAtServerTime
		end
		if windowEndsAt ~= self._pushedReviveWindowEndsAt then
			self._pushedReviveWindowEndsAt = windowEndsAt
			if GameOverGradientInterfaceController then
				local window = if windowEndsAt
					then {
						endsAt = windowEndsAt,
						startedAt = localEntry.windowStartsAtServerTime or localEntry.diedAtServerTime,
					}
					else nil
				GameOverGradientInterfaceController.Signals.SetReviveWindow:Fire(window)
			end
		end

		if localEntry then
			self:_lockControls()
			self:_setHudVisible(false)
		else
			self:_unlockControls()
			self:_setHudVisible(true)
			if CinematicInterfaceController then
				CinematicInterfaceController.Signals.OnCinematicEnd:Fire()
			end
		end
	end)
end

return LifeController
