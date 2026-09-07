--[[
     Module: LifeController.lua
     Description:
     Client-side glue for LifeService. Subscribes to the three server
     visual-callback signals and re-emits them through local Signal objects
     so client systems (VFX, audio, screen flashes, etc.) can hook in
     without needing to know about Knit / RemoteSignals.

     For now (Chunk A) the local handlers only print — Chunks C/D wire
     real visuals + spectate behavior. The signal surface is forwards-
     compatible: future VFX listeners just `LifeController.OnLifeLost:Connect(...)`.

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

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
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
local onDeathIndicator = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Highlight.onDeathIndicator)
local InterfaceScopes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.InterfaceScopes)

-- Hide source held on the HUD scope for the death → revive window. Named so
-- it composes: a revive releasing it won't bring the HUD back if a cutscene
-- or a manual CloseInterface is still holding the same scope.
local HUD_DEATH_SOURCE = "Death"

local ScreenGradientInterfaceController
local GameOverGradientInterfaceController
local CameraShakeController
local LifeService
local ScreenFadeInterfaceController
local CinematicInterfaceController
local CutsceneController
local SpectateService

-- HUD interface controllers we drive via their SetVisible signals during
-- the death + revive lifecycle. We never reach into PlayerGui to flip
-- ScreenGui.Enabled on these directly — each interface owns its own
-- visibility state and exposes a Signal as the public toggle.
local InterfaceManagerController
local LivesInterfaceController
local MobileActionButtonInterface

local LifeController = Knit.CreateController({
	Name = "LifeController",
})

-- Death cinematic timings — sourced from Shared/Data/DeathCinematicData so
-- LifeController, GameOverGradientInterfaceController, and its Container all
-- stay in lockstep. To re-tune the cinematic, edit DeathCinematicData; the
-- locals below propagate the change automatically. CHARACTER_FADE_START_OFFSET
-- stays local because it's tuned against this controller's own task.delay
-- timeline and isn't referenced by the other systems.
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
local DEATH_IMPACT_TO_GAME_OVER_SECONDS = 3

local AUTHORED_BLUR_SIZE = Lighting.Blur.Size

local DEATH_VFX_DURATION = DeathCinematicData.VfxDuration
local DEATH_FADE_DURATION = DeathCinematicData.FadeDuration
local DEATH_BLACK_HOLD_DURATION = DeathCinematicData.BlackHoldDuration

-- Body fade timing. Body is fully invisible by
-- CHARACTER_FADE_START_OFFSET + CHARACTER_FADE_DURATION (default ≈ 2.5s
-- after death). Originally 6.5s offset + 0.5s tween, which left the
-- ragdoll visible for the entire screen-fade-to-black window (~7s).
-- QA reported "you can see the player get up briefly during the Death
-- animation" — that was the death animation track ending while the
-- humanoid was still live underneath the cinematic, with no fade yet
-- to hide it. Fading earlier (1.5s after death) puts the body out of
-- frame well before any default Humanoid state can take over visually.
local CHARACTER_FADE_START_OFFSET = 5
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
		if part:IsA("BasePart") or part:IsA("Decal") or part:IsA("Texture") then
			table.insert(cachedTransparency, { part = part, transparency = part.Transparency })
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
LifeController.OnPlayerDied = Signal.new()
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
LifeController._playerControls = nil

-- True while we currently hold the controls lock. Tracked so we don't
-- redundantly Disable/Enable across rapid DeathState toggles, and so we
-- never Enable controls we didn't take in the first place (which would
-- step on EncounterIntroController's lock during an encounter cinematic).
LifeController._controlsLocked = false

-- Current "actively spectating" state for the LOCAL player. Read via
-- :IsLocalSpectating() (used by UIs to seed their React state on mount,
-- since they might mount after the signal has already fired).
LifeController._isLocalSpectating = false

-- Per-userId cache + race token for the body-fade. The cache holds the
-- pre-fade transparency of every BasePart/Decal/Texture on the dying
-- character so we can tween-restore them on revive (player might be
-- wearing semi-transparent gear; we don't want to wipe that to 0).
-- The token guards against die → revive → die races scheduled within the
-- CHARACTER_FADE_START_OFFSET window: each death stamps a fresh token,
-- the delay callback aborts if it doesn't match anymore.
LifeController._characterFadeCaches = {} :: { [number]: { { part: any, transparency: number } } }
LifeController._pendingFadeTokens = {} :: { [number]: any }
LifeController._isGameOver = false -- true after the all-dead trigger, until teleport or reload
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
function LifeController:_playDeathImpact()
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

function LifeController:_getPlayerControls()
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
function LifeController:_lockControls()
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
function LifeController:_unlockControls()
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
function LifeController:_setSpectatingState(value: boolean)
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
	ProximityPromptService.Enabled = not value
end

-- Synchronous getter — used by UIs that mount AFTER the signal has
-- already fired and need to seed their initial state.
function LifeController:IsLocalSpectating(): boolean
	return self._isLocalSpectating
end

-- Fans `visible` out to every HUD interface that should hide during the
-- death + revive window via their public SetVisible signals. Each interface
-- owns its own visibility state and decides how to render it — we just say
-- "go hidden" / "come back". Add a new HUD-while-dead interface here AND
-- give that interface its own SetVisible signal; no PlayerGui scanning.
--
-- Each ref is nil-guarded because KnitStart wires them in order; if the
-- controller resolution ever races (or a controller is missing from the
-- build), we want a warn-less no-op rather than a hard crash.
function LifeController:_setHudVisible(visible: boolean)
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

function LifeController:KnitInit()
	LifeService = Knit.GetService("LifeService")
end

function LifeController:KnitStart()
	ScreenFadeInterfaceController = Knit.GetController("ScreenFadeInterfaceController")
	CinematicInterfaceController = Knit.GetController("CinematicInterfaceController")
	ScreenGradientInterfaceController = Knit.GetController("ScreenGradientInterfaceController")
	GameOverGradientInterfaceController = Knit.GetController("GameOverGradientInterfaceController")
	CameraShakeController = Knit.GetController("CameraShakeController")
	CutsceneController = Knit.GetController("CutsceneController")
	SpectateService = Knit.GetService("SpectateService")

	InterfaceManagerController = Knit.GetController("InterfaceManagerController")
	LivesInterfaceController = Knit.GetController("LivesInterfaceController")
	MobileActionButtonInterface = Knit.GetController("MobileActionButtonInterface")

	LifeService.OnLifeLost:Connect(function(userId: number)
		print(("[LifeController] %s lost a life"):format(nameFor(userId)))
		self.OnLifeLost:Fire(userId)
	end)

	LifeService.OnPlayerDied:Connect(function(userId: number, isWipe: boolean?)
		print(("[LifeController] %s died (wipe=%s)"):format(nameFor(userId), tostring(isWipe == true)))
		self.OnPlayerDied:Fire(userId)

		CutsceneController:CancelActiveAbility(false)

		local fadeToken = {}
		self._pendingFadeTokens[userId] = fadeToken

		task.delay(CHARACTER_FADE_START_OFFSET, function()
			if self._pendingFadeTokens[userId] ~= fadeToken then
				return -- superseded (revived or died again)
			end
			local diedPlayer = Players:GetPlayerByUserId(userId)
			local character = diedPlayer and diedPlayer.Character
			if not character then
				return
			end
			self._characterFadeCaches[userId] = captureAndTweenCharacterToInvisible(character)
		end)

		if userId ~= Players.LocalPlayer.UserId then
			return
		end

		-- Wipe-completing death — this player's death was the all-dead
		-- trigger. SKIP the standard death cinematic (red flash, fade-in,
		-- spectate setup) entirely; the OnGameOver handler below will
		-- paint the Game Over screen instead. User stories 2 and 3:
		--   * Story 2 (solo): die → no other players → wipe → straight
		--     to Game Over.
		--   * Story 3 (last alive): die while teammates are spectating →
		--     wipe → Game Over plays for everyone.
		-- Without this early return, the death cinematic would run for
		-- ~7s under the Game Over overlay, finishing right around when
		-- the teleport fires — wastes the moment.
		if isWipe == true then
			return
		end

		onDeathIndicator(Players.LocalPlayer.Character)

		-- HARDCORE: the Game Over screen is the ONLY death screen — it
		-- paints on every death regardless of party size or how many
		-- players are still alive. This is the individual-death path
		-- (teammates still fighting); the wipe path early-returns above
		-- and gets the same screen from the OnGameOver handler instead.
		-- DeathGradientInterfaceController ("You Died") is intentionally
		-- never fired now; the controller itself is left registered so
		-- restoring it is a one-line change.
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
			GameOverGradientInterfaceController.Signals.OnPulseGradient:Fire(Color3.fromRGB(255, 0, 0), true)
		end)

		-- Death-VFX-phase overlay. Red persistent gradient at 0.35
		-- transparency held until the FadeIn-to-full-black completes — at
		-- which point we crossfade it to black (see inside the task.spawn
		-- below) so the spectate reveal shows a black overlay. Fires here
		-- on the local death tick so the red is visible from frame 1 of
		-- the cinematic, alongside the DeathGradient pulse above.
		ScreenGradientInterfaceController.Signals.OnSetHold:Fire(Color3.fromRGB(255, 0, 0), 0.35)

		-- clearZombieHitboxes()

		if CutsceneController then
			CutsceneController:CancelActiveAbility(false)
		end

		task.spawn(function()
			print("[LifeController] Death Animation")

			-- 	local cachedTransparency = table.create(4096)
			-- 	local screenGuis = table.create(512)
			-- 	local particles = table.create(512)

			-- 	fadeRootAndCache(workspace.IgnoreInstances.Map.DungeonRooms, cachedTransparency, screenGuis, particles)

			-- 	for _, zombie in workspace.IgnoreInstances.Zombies:GetChildren() do
			-- 		if zombie:IsA("Model") then
			-- 			fadeRootAndCache(zombie, cachedTransparency, screenGuis, particles)
			-- 		end
			-- 	end

			-- 	local playersContainer = workspace:FindFirstChild("Players")
			-- 	local localCharacter = Players.LocalPlayer.Character

			-- 	if playersContainer then
			-- 		for _, character in playersContainer:GetChildren() do
			-- 			if character:IsA("Model") and character ~= localCharacter then
			-- 				fadeRootAndCache(character, cachedTransparency, screenGuis, particles)
			-- 			end
			-- 		end
			-- 	end

			-- 	local dropsContainer = workspace.IgnoreInstances:FindFirstChild("Drops")

			-- 	if dropsContainer then
			-- 		fadeRootAndCache(dropsContainer, cachedTransparency, screenGuis, particles)
			-- 	end

			-- 	workspace.IgnoreInstances.DeadZombies:ClearAllChildren()

			-- 	local suppressionConnections = {}

			-- 	local function watchBillboard(billboard: BillboardGui)
			-- 		local conn = billboard:GetPropertyChangedSignal("Enabled"):Connect(function()
			-- 			if billboard.Enabled then
			-- 				billboard.Enabled = false
			-- 			end
			-- 		end)
			-- 		table.insert(suppressionConnections, conn)
			-- 	end

			-- 	local function watchZombie(zombie: Instance)
			-- 		if not zombie:IsA("Model") then
			-- 			return
			-- 		end
			-- 		for _, descendant in zombie:GetDescendants() do
			-- 			if descendant:IsA("BillboardGui") then
			-- 				watchBillboard(descendant)
			-- 			end
			-- 		end
			-- 		local descConn = zombie.DescendantAdded:Connect(function(descendant)
			-- 			if descendant:IsA("BillboardGui") then
			-- 				-- Cache so restore re-enables to its actual state.
			-- 				table.insert(screenGuis, { part = descendant, enabled = descendant.Enabled })
			-- 				descendant.Enabled = false
			-- 				watchBillboard(descendant)
			-- 			end
			-- 		end)
			-- 		table.insert(suppressionConnections, descConn)
			-- 	end

			-- 	for _, zombie in workspace.IgnoreInstances.Zombies:GetChildren() do
			-- 		watchZombie(zombie)
			-- 	end
			-- 	local zombieAddedConn = workspace.IgnoreInstances.Zombies.ChildAdded:Connect(function(zombie)
			-- 		if zombie:IsA("Model") then
			-- 			fadeRootAndCache(zombie, cachedTransparency, screenGuis, particles)
			-- 			watchZombie(zombie)
			-- 		end
			-- 	end)

			-- 	table.insert(suppressionConnections, zombieAddedConn)

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

			ScreenFadeInterfaceController.Signals.FadeIn:Fire(DEATH_FADE_DURATION, 0.5)

			task.wait(DEATH_VFX_DURATION)

			ScreenFadeInterfaceController.Signals.FadeIn:Fire(DEATH_FADE_DURATION, 0)

			-- 	if not ScreenFadeInterfaceController then
			-- 		return
			-- 	end

			task.wait(DEATH_FADE_DURATION)

			ScreenGradientInterfaceController.Signals.OnSetHold:Fire(Color3.fromRGB(0, 0, 0), 0.35)

			-- 	for _, conn in suppressionConnections do
			-- 		conn:Disconnect()
			-- 	end
			-- 	table.clear(suppressionConnections)

			-- 	for _, entry in cachedTransparency do
			-- 		entry.part.Transparency = entry.transparency
			-- 	end

			-- 	for _, entry in screenGuis do
			-- 		entry.part.Enabled = entry.enabled
			-- 	end

			-- 	for _, entry in particles do
			-- 		entry.part.Enabled = entry.enabled
			-- 	end

			if self._isGameOver then
				return
			end

			SpectateService:OnDeathStateReplicated()

			self:_setSpectatingState(true)

			task.wait(DEATH_BLACK_HOLD_DURATION)

			ScreenFadeInterfaceController.Signals.FadeOut:Fire(DEATH_FADE_DURATION)
		end)
	end)

	-- Revive VFX hook. The fade + teleport itself is server-orchestrated
	-- via LifeService.RevivalFade — we just print the animation hook here
	-- so any client VFX code has a single subscribe point.
	LifeService.OnPlayerRevived:Connect(function(userId: number)
		print(("[LifeController] %s revived"):format(nameFor(userId)))
		self.OnPlayerRevived:Fire(userId)

		self._pendingFadeTokens[userId] = nil
		local cache = self._characterFadeCaches[userId]

		if cache then
			tweenRestoreCharacterTransparency(cache)
			self._characterFadeCaches[userId] = nil
		end

		if userId == Players.LocalPlayer.UserId then
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
		local userId = player.UserId
		self._pendingFadeTokens[userId] = nil
		self._characterFadeCaches[userId] = nil
	end)

	LifeService.RevivalFade:Connect(function(payload: { phase: string, duration: number }?)
		if not payload or not ScreenFadeInterfaceController then
			return
		end
		local duration = payload.duration or DEATH_FADE_DURATION
		if payload.phase == "in" then
			self:_setSpectatingState(false)
			ScreenFadeInterfaceController.Signals.FadeIn:Fire(duration)
		elseif payload.phase == "out" then
			ScreenFadeInterfaceController.Signals.FadeOut:Fire(duration)

			task.delay(duration, function()
				if CinematicInterfaceController then
					CinematicInterfaceController.Signals.OnCinematicStart:Fire()
				end
			end)
		end
	end)

	LifeService.OnTeleportToLobby:Connect(function()
		-- self:_setSpectatingState(false)
		-- self:_setHudVisible(false)

		-- if CinematicInterfaceController then
		-- 	CinematicInterfaceController.Signals.OnCinematicEnd:Fire()
		-- end
	end)

	LifeService.OnGameOver:Connect(function()
		print("[LifeController] Game Over — wipe broadcast received")

		self._isGameOver = true

		-- Only the player whose death CAUSED the wipe takes the hit;
		-- teammates already spectating had theirs when they fell. Read
		-- before the spectate reset below clears the evidence. (Solo play
		-- is always a wipe, so this is the path that usually runs.)
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

	LifeService.DeathState:Observe(function(deathState: { [any]: any }?)
		local localId = Players.LocalPlayer.UserId
		local localEntry = deathState and (deathState[localId] or deathState[tostring(localId)])
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
