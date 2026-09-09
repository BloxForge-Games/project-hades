--[[
	Module: CharacterHighlightController.lua
	Description:
	Single client-side Highlight renderer for the local player AND
	every zombie in workspace.IgnoreInstances.Zombies. Per zombie there
	is exactly ONE Highlight Instance — the server-replicated
	"MobHighlight" created by MobBase. This controller mutates its
	visual properties via a per-frame priority resolver so multiple
	effects (damage flash, occlusion outline, attack windup) share the
	same slot instead of stacking new Highlights.

	Why a single highlight: Roblox enforces a HARD 255 active-Highlight
	cap. The previous design created one Highlight per effect per zombie
	(AttackHighlightIndicator + DamageIndicatorHighlight +
	CharacterHighlight ≈ 3 per mob). With 50 zombies + waves of dying
	bodies you cleared the cap and new Highlight Instances silently
	failed to render — that was the root cause of the "wizard's cast
	highlight sometimes doesn't appear" bug.

	==========================================================
	Priority resolver (highest → lowest)
	==========================================================

	  1. DAMAGE FLASH  — red, ~0.25s decay. Fires on damage events;
	                     overrides everything because combat feedback
	                     is the most readable signal.
	  2. OUTLINE       — white, partly transparent, AlwaysOnTop. Active
	                     whenever the zombie's head is occluded by
	                     terrain so you can read threats through walls.
	  3. ATTACK WINDUP — white, transparent, AlwaysOnTop. Server-driven
	                     via the MobHighlightAttackActive attribute on
	                     the model. Client tweens local intensity over
	                     WINDUP_FADE_DURATION for fade-in / fade-out.
	  4. NONE          — FillTransparency / OutlineTransparency = 1.

	The local player highlight is separate — kept on the player's own
	model — and resolves FIVE layers through the same single Instance,
	highest first: DEATH flash (red, LifeController), DAMAGE flash (red),
	DODGE flash (white, perfect dodge), INVULNERABLE (white fill, on while
	Attributes.Invulnerable is true -- jetpack, life loss, cutscene magic
	-- ramped over INVULN_FADE_DURATION) and the occlusion outline. Every
	one of those used to be its OWN Highlight parented to the character,
	and Roblox renders one per adornee -- the most recently added -- so a
	dodge hid the outline for a second, and the death flash (never
	destroyed) hid it for the rest of the life. OTHER players' invulnerability is drawn
	by this client too, as one small Highlight per character keyed on the
	same attribute (they carry no other client highlight, so no slot
	fight). The server parents no Highlight for it at all.
	It used to be occlusion-only, with the flash coming from a SECOND
	Highlight that HumanoidStateController parented to the character.
	Roblox renders one Highlight per adornee — the most recently added —
	so from the first hit onward that (Occluded, fully faded, still
	Enabled) flash instance owned the slot and the white through-wall
	outline never rendered again. One Instance, one resolver, no slot
	fight.

	==========================================================
	Public API
	==========================================================

	  CharacterHighlightController:RequestDamageFlash(model)
	    Flips the damage-flash state for `model` so the per-frame
	    resolver renders red for DAMAGE_FLASH_DURATION. Safe to call
	    on any model; no-ops if not in the zombie registry.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local packages: Folder = ReplicatedStorage.Submodules.Core.Packages

local Knit = require(packages.Knit)
local Janitor = require(packages.Janitor)

local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)

local camera: Camera = workspace.CurrentCamera

local MOB_HIGHLIGHT_NAME = "MobHighlight"
local MOB_ATTACK_ATTRIBUTE = "MobHighlightAttackActive"
local PLAYER_HIGHLIGHT_NAME = "CharacterHighlight"

-- Per-frame loop cadence. 0.025s ≈ 40Hz — matches the legacy tick
-- this controller used. Trade-off: lower = smoother windup tweens,
-- higher = cheaper raycast budget. 40Hz is the sweet spot for
-- 30-50 live zombies.
local TICK_INTERVAL = 0.025

-- Damage flash: 0.25s fade from peak transparency 0.4 → 1, red.
local DAMAGE_FLASH_DURATION = 0.25
local DAMAGE_PEAK_TRANSPARENCY = 0.4
local DAMAGE_COLOR = Color3.fromRGB(255, 0, 0)

-- Perfect-dodge flash: white, snaps to peak over DODGE_ATTACK then fades
-- out over DODGE_DECAY (the old onDodgeIndicator's 0.1 / 1 tweens).
local DODGE_PEAK_TRANSPARENCY = 0.25
local DODGE_ATTACK_DURATION = 0.1
local DODGE_DECAY_DURATION = 1
local DODGE_COLOR = Color3.fromRGB(255, 255, 255)

-- Death flash: red, from fully opaque, fading over DEATH_DECAY (the old
-- onDeathIndicator's values).
local DEATH_PEAK_TRANSPARENCY = 0
local DEATH_DECAY_DURATION = 0.5
local DEATH_COLOR = Color3.fromRGB(237, 56, 56)

-- Names the legacy per-effect highlights used. Nothing creates them any
-- more; one left on a live character from an older client build would
-- take the slot, so they are purged when the local highlight is built.
local LEGACY_LOCAL_HIGHLIGHT_NAMES = {
	"LocalCharacterDamageIndicator",
	"DodgeIndicator",
	"OnDeathHighlight",
	"OnDamageHighlight",
	"InvulnerableHighlight",
}

-- Invulnerable: white fill while Attributes.Invulnerable is true, ramped
-- in / out so it never pops. The fill is the old server highlight's.
local INVULN_FILL_TRANSPARENCY = 0.35
local INVULN_COLOR = Color3.fromRGB(255, 255, 255)
local INVULN_FADE_DURATION = 0.25
-- The per-character highlight this client creates on OTHER players.
local OTHER_INVULN_HIGHLIGHT_NAME = "InvulnerableHighlight"

-- Occlusion outline: stays at this transparency whenever the head is
-- behind terrain. White, occlusion-only DepthMode (AlwaysOnTop so it
-- bleeds through walls — that's the whole point).
local OUTLINE_TRANSPARENCY = 0.65
local OUTLINE_COLOR = Color3.fromRGB(255, 255, 255)

-- Attack windup: client-side intensity tween 0 → 1 driven by the
-- server attribute. At intensity 1 the FillTransparency lands at
-- ATTACK_WINDUP_PEAK_TRANSPARENCY (most opaque white). At 0 it's
-- fully transparent. WINDUP_FADE_DURATION matches the old server
-- TweenInfo so the visual is unchanged.
local ATTACK_WINDUP_PEAK_TRANSPARENCY = 0.35
local WINDUP_FADE_DURATION = 0.35
local WINDUP_COLOR = Color3.fromRGB(255, 255, 255)

-- How long to wait for the server-replicated MobHighlight to arrive
-- on a freshly-spawned zombie. Generous because spawn replication can
-- be slow under load. If it never arrives we just skip the zombie.
local MOB_HIGHLIGHT_WAIT_TIMEOUT = 5

local PlayerEventController

local CharacterHighlightController = Knit.CreateController({
	Name = "CharacterHighlightController",
	Client = {},
})

--------------------------------------------------
-- INTERNAL
--------------------------------------------------

-- Used only for the LOCAL player highlight. Zombies don't get a
-- client-created Highlight — they use the server-replicated MobHighlight.
function CharacterHighlightController:_CreatePlayerHighlightInstance(model: Model)
	for _, name in LEGACY_LOCAL_HIGHLIGHT_NAMES do
		local legacy = model:FindFirstChild(name)
		if legacy then
			legacy:Destroy()
		end
	end
	-- A previous build of OUR highlight on the same character (a second
	-- OnCharacterLoaded for one character) would be a second Highlight too.
	local previous = model:FindFirstChild(PLAYER_HIGHLIGHT_NAME)
	if previous then
		previous:Destroy()
	end

	local highlight = Instance.new("Highlight")
	highlight.Name = PLAYER_HIGHLIGHT_NAME
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.FillColor = Color3.fromRGB(255, 255, 255)
	highlight.FillTransparency = 1
	highlight.OutlineColor = Color3.fromRGB(255, 255, 255)
	highlight.OutlineTransparency = 1
	highlight.Parent = model

	return highlight
end

-- Register a zombie. Finds the server-replicated MobHighlight (waits
-- up to MOB_HIGHLIGHT_WAIT_TIMEOUT seconds), then seeds per-zombie
-- state for the priority resolver. NO new Highlight Instance is
-- created here — that's the whole point.
function CharacterHighlightController:_RegisterZombie(zombie: Model)
	if not zombie:FindFirstChild("Head") then
		return
	end
	if self._zombieRegistry[zombie] then
		return
	end

	-- Wait in a separate task so a slow-replicating MobHighlight
	-- doesn't block ChildAdded for the next zombie.
	task.spawn(function()
		local highlight = zombie:WaitForChild(MOB_HIGHLIGHT_NAME, MOB_HIGHLIGHT_WAIT_TIMEOUT)
		if not highlight or not zombie.Parent then
			-- Either the server never created one (shouldn't happen
			-- given MobBase always does) or the zombie was removed
			-- before it arrived. Either way: bail silently.
			return
		end
		if self._zombieRegistry[zombie] then
			return -- raced with another _RegisterZombie call
		end

		self._zombieRegistry[zombie] = {
			head = zombie:FindFirstChild("Head"),
			highlight = highlight,

			-- Damage flash state: nil if not flashing, else tick()
			-- timestamp at which the flash expires.
			damageFlashEndAt = nil :: number?,

			-- Attack windup local-tween state. The server toggles a
			-- model attribute and the client smoothly tweens intensity
			-- toward the target so the visual fades in/out instead
			-- of snapping.
			windupIntensity = 0,
		}

		-- AncestryChanged fires on ANY parent change. We want to drop
		-- the registry entry the moment the zombie leaves the live-
		-- zombies folder (e.g. moved to DeadZombies on death, or
		-- destroyed outright). Without this we'd keep poking dead
		-- zombies in the per-frame loop forever — which was the
		-- original CharacterHighlight leak path.
		zombie.AncestryChanged:Connect(function(_, parent)
			if parent ~= workspace.IgnoreInstances.Zombies then
				self._zombieRegistry[zombie] = nil
			end
		end)
	end)
end

-- Public: request a damage flash for `model`. Called by
-- DamageIndicatorController when the local player damages a zombie, and
-- HumanoidStateController when the LOCAL PLAYER takes damage. No-ops for
-- any other model (those go through the legacy onDamageIndicator path).
function CharacterHighlightController:RequestDamageFlash(model: Model)
	if model == Players.LocalPlayer.Character then
		self._playerDamageFlashEndAt = os.clock() + DAMAGE_FLASH_DURATION
		ReplicatedStorage.GameAssets.Sounds.HitIndicator:Play()
		return
	end
	local data = self._zombieRegistry[model]
	if not data then
		return
	end
	data.damageFlashEndAt = os.clock() + DAMAGE_FLASH_DURATION
	-- One sound per hit, mirroring the old onDamageIndicator behavior.
	ReplicatedStorage.GameAssets.Sounds.HitIndicator:Play()
end

-- Perfect dodge: the white snap-and-fade, as a layer. Local player only.
function CharacterHighlightController:RequestDodgeFlash(model: Model)
	if model ~= Players.LocalPlayer.Character then
		return
	end
	self._playerDodgeStartAt = os.clock()
end

-- Death: the red flash, as a layer. Local player only.
function CharacterHighlightController:RequestDeathFlash(model: Model)
	if model ~= Players.LocalPlayer.Character then
		return
	end
	self._playerDeathStartAt = os.clock()
end

-- Per-frame resolver for the LOCAL player's single highlight. Same shape
-- as the zombie resolver, highest layer wins: death, damage, dodge,
-- invulnerable, then the through-wall outline, then nothing.
function CharacterHighlightController:_resolvePlayerHighlight(character: Model, deltaTime: number)
	local highlight = self._playerHighlight
	if not highlight or not highlight.Parent then
		return
	end

	-- Ramp the invulnerable intensity toward the attribute (1 / 0). NOT
	-- while a magic cutscene is playing (Susanoo, Domain Expansion): the
	-- cast's own presentation is the feedback there, and the bars-and-
	-- vignette frame should not carry a white glow. The glow comes up as
	-- the cutscene ends and covers the grace tail of the window.
	local invulnTarget = if character:GetAttribute(Attributes.Invulnerable) == true
			and character:GetAttribute(Attributes.MagicCutscenePlaying) ~= true
		then 1
		else 0
	local step = deltaTime / INVULN_FADE_DURATION
	local diff = invulnTarget - (self._playerInvulnIntensity or 0)
	if math.abs(diff) <= step then
		self._playerInvulnIntensity = invulnTarget
	else
		self._playerInvulnIntensity = (self._playerInvulnIntensity or 0) + (if diff > 0 then step else -step)
	end

	local now = os.clock()

	-- Priority 0: death (red, opaque -> clear over DEATH_DECAY_DURATION).
	if self._playerDeathStartAt then
		local elapsed = now - self._playerDeathStartAt
		if elapsed < DEATH_DECAY_DURATION then
			local progress = elapsed / DEATH_DECAY_DURATION
			highlight.FillColor = DEATH_COLOR
			highlight.FillTransparency = DEATH_PEAK_TRANSPARENCY + (1 - DEATH_PEAK_TRANSPARENCY) * progress
			highlight.OutlineTransparency = 1
			highlight.DepthMode = Enum.HighlightDepthMode.Occluded
			return
		end
		self._playerDeathStartAt = nil
	end

	if self._playerDamageFlashEndAt and now < self._playerDamageFlashEndAt then
		local remaining = self._playerDamageFlashEndAt - now
		local progress = 1 - (remaining / DAMAGE_FLASH_DURATION)
		highlight.FillColor = DAMAGE_COLOR
		highlight.FillTransparency = DAMAGE_PEAK_TRANSPARENCY + (1 - DAMAGE_PEAK_TRANSPARENCY) * progress
		highlight.OutlineTransparency = 1
		highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		return
	end
	self._playerDamageFlashEndAt = nil

	local head = character:FindFirstChild("Head")
	local occluded = head ~= nil and self:_IsOccluded(head.Position)

	-- Priority 1.5: perfect dodge (white: 1 -> peak over the attack, then
	-- peak -> 1 over the decay).
	if self._playerDodgeStartAt then
		local elapsed = now - self._playerDodgeStartAt
		local total = DODGE_ATTACK_DURATION + DODGE_DECAY_DURATION
		if elapsed < total then
			local transparency
			if elapsed < DODGE_ATTACK_DURATION then
				transparency = 1 - (1 - DODGE_PEAK_TRANSPARENCY) * (elapsed / DODGE_ATTACK_DURATION)
			else
				local progress = (elapsed - DODGE_ATTACK_DURATION) / DODGE_DECAY_DURATION
				transparency = DODGE_PEAK_TRANSPARENCY + (1 - DODGE_PEAK_TRANSPARENCY) * progress
			end
			highlight.FillColor = DODGE_COLOR
			highlight.FillTransparency = transparency
			highlight.OutlineTransparency = 1
			highlight.DepthMode = if occluded
				then Enum.HighlightDepthMode.AlwaysOnTop
				else Enum.HighlightDepthMode.Occluded
			return
		end
		self._playerDodgeStartAt = nil
	end

	-- Priority 2: invulnerable. Keeps the through-wall depth mode while
	-- occluded so the fill still reads behind cover.
	local intensity = self._playerInvulnIntensity or 0
	if intensity > 0 then
		highlight.FillColor = INVULN_COLOR
		highlight.FillTransparency = 1 - intensity * (1 - INVULN_FILL_TRANSPARENCY)
		highlight.OutlineTransparency = 1
		highlight.DepthMode = if occluded then Enum.HighlightDepthMode.AlwaysOnTop else Enum.HighlightDepthMode.Occluded
		return
	end

	if occluded then
		highlight.FillColor = OUTLINE_COLOR
		highlight.FillTransparency = OUTLINE_TRANSPARENCY
		highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	else
		highlight.FillColor = OUTLINE_COLOR
		highlight.FillTransparency = 1
		highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	end
end

-- OTHER players: one small Highlight per character, created while their
-- Attributes.Invulnerable is true and faded out + destroyed when it drops.
-- Their characters carry no other client highlight, so this cannot take
-- a slot from anything.
function CharacterHighlightController:_bindOtherCharacter(character: Model)
	local function refresh()
		local wants = character:GetAttribute(Attributes.Invulnerable) == true
		local existing = character:FindFirstChild(OTHER_INVULN_HIGHLIGHT_NAME)
		if wants and not existing then
			local highlight = Instance.new("Highlight")
			highlight.Name = OTHER_INVULN_HIGHLIGHT_NAME
			highlight.FillColor = INVULN_COLOR
			highlight.FillTransparency = 1
			highlight.OutlineTransparency = 1
			highlight.DepthMode = Enum.HighlightDepthMode.Occluded
			highlight.Parent = character
			TweenService:Create(
				highlight,
				TweenInfo.new(INVULN_FADE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ FillTransparency = INVULN_FILL_TRANSPARENCY }
			):Play()
		elseif not wants and existing then
			local fade = TweenService:Create(
				existing,
				TweenInfo.new(INVULN_FADE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ FillTransparency = 1 }
			)
			fade.Completed:Once(function()
				-- Re-checked: the attribute may have come back mid-fade.
				if existing.Parent and character:GetAttribute(Attributes.Invulnerable) ~= true then
					existing:Destroy()
				end
			end)
			fade:Play()
		end
	end
	character:GetAttributeChangedSignal(Attributes.Invulnerable):Connect(refresh)
	refresh()
end

function CharacterHighlightController:_watchOtherPlayers()
	local function bind(player: Player)
		if player == Players.LocalPlayer then
			return
		end
		if player.Character then
			self:_bindOtherCharacter(player.Character)
		end
		player.CharacterAdded:Connect(function(character: Model)
			self:_bindOtherCharacter(character)
		end)
	end
	for _, player in Players:GetPlayers() do
		bind(player)
	end
	Players.PlayerAdded:Connect(bind)
end

function CharacterHighlightController:_IsOccluded(point: Vector3)
	local hit = camera:GetPartsObscuringTarget({ point }, self._ignoreList)
	return hit and #hit > 0
end

-- Per-frame priority resolver for a single zombie. Picks the highest
-- priority active layer and writes its color/transparency to the
-- single MobHighlight Instance. Lower-priority layers are NOT
-- additive — only the winner is rendered.
function CharacterHighlightController:_resolveZombieHighlight(zombie: Model, data, deltaTime: number)
	local highlight = data.highlight
	if not highlight or not highlight.Parent then
		-- Server already destroyed the Highlight (mob death janitor
		-- cleanup). Nothing to do; AncestryChanged will scrub the
		-- registry entry shortly.
		return
	end
	local head = data.head
	if not head or not head.Parent then
		return
	end

	-- Tween the local windup intensity toward the server-driven
	-- target (1 when attribute is true, 0 when false). Linear ramp
	-- over WINDUP_FADE_DURATION matches the previous TweenInfo curve
	-- closely enough that the visual is indistinguishable.
	local targetIntensity = if zombie:GetAttribute(MOB_ATTACK_ATTRIBUTE) then 1 else 0
	local step = deltaTime / WINDUP_FADE_DURATION
	local diff = targetIntensity - data.windupIntensity
	if math.abs(diff) <= step then
		data.windupIntensity = targetIntensity
	else
		data.windupIntensity += if diff > 0 then step else -step
	end

	local now = os.clock()

	-- Priority 1: damage flash (red, fading 0.4 → 1 over 0.25s).
	if data.damageFlashEndAt and now < data.damageFlashEndAt then
		local remaining = data.damageFlashEndAt - now
		local progress = 1 - (remaining / DAMAGE_FLASH_DURATION) -- 0 at start, 1 at end
		local transparency = DAMAGE_PEAK_TRANSPARENCY + (1 - DAMAGE_PEAK_TRANSPARENCY) * progress
		highlight.FillColor = DAMAGE_COLOR
		highlight.FillTransparency = transparency
		highlight.OutlineTransparency = 1
		highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		return
	end
	-- Clear stale damageFlashEndAt so subsequent frames don't pay the
	-- comparison cost forever.
	if data.damageFlashEndAt and now >= data.damageFlashEndAt then
		data.damageFlashEndAt = nil
	end

	-- Priority 2: occlusion outline (white, 0.65, AlwaysOnTop).
	local occluded = self:_IsOccluded(head.Position)
	if occluded then
		highlight.FillColor = OUTLINE_COLOR
		highlight.FillTransparency = OUTLINE_TRANSPARENCY
		highlight.OutlineTransparency = 1
		highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		return
	end

	-- Priority 3: attack windup (white, intensity-driven).
	if data.windupIntensity > 0 then
		-- intensity 1 → FillTransparency = ATTACK_WINDUP_PEAK_TRANSPARENCY
		-- intensity 0 → FillTransparency = 1
		highlight.FillColor = WINDUP_COLOR
		highlight.FillTransparency = 1 - data.windupIntensity * (1 - ATTACK_WINDUP_PEAK_TRANSPARENCY)
		highlight.OutlineTransparency = 1
		highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		return
	end

	-- Default: fully invisible. Important to write this every frame
	-- (rather than only on transition) because the priority above can
	-- have left non-default values; without explicit reset they'd
	-- linger when no layer is active.
	highlight.FillTransparency = 1
	highlight.OutlineTransparency = 1
end

function CharacterHighlightController:_InitHighlightThread()
	self._janitor:Cleanup()

	local player = Players.LocalPlayer
	local character = player.Character

	-- RE-ENTRANT. OnCharacterLoaded can fire more than once for one
	-- character (the initial load and CharacterAdded both fire it); the
	-- generation lets the previous loop notice it has been superseded and
	-- stop, instead of two loops driving two highlights on one model.
	self._threadGeneration = (self._threadGeneration or 0) + 1
	local generation = self._threadGeneration

	self._playerHighlight = self:_CreatePlayerHighlightInstance(character)
	self._playerDamageFlashEndAt = nil
	self._playerDodgeStartAt = nil
	self._playerDeathStartAt = nil
	self._playerInvulnIntensity = 0

	local lastTick = os.clock()
	while task.wait(TICK_INTERVAL) do
		if self._threadGeneration ~= generation then
			return
		end
		local now = os.clock()
		local deltaTime = now - lastTick
		lastTick = now

		self:_resolvePlayerHighlight(character, deltaTime)

		-- Resolve priority for every registered zombie. AncestryChanged
		-- has already scrubbed entries for dead/destroyed zombies, so
		-- this iteration is over live mobs only.
		for zombie, data in pairs(self._zombieRegistry) do
			self:_resolveZombieHighlight(zombie, data, deltaTime)
		end
	end
end

function CharacterHighlightController:KnitInit()
	self._janitor = Janitor.new()
	self._zombieRegistry = {}

	self._ignoreList = {
		Players.LocalPlayer.Character,
		workspace.IgnoreInstances.Terrain,
		workspace.IgnoreInstances.Boundaries,
		workspace.Terrain,
		workspace.CurrentCamera,
		workspace.IgnoreInstances.MapMarkers,
		workspace.IgnoreInstances.MagicSpells,
		workspace.PlayerBaseplates,
		workspace.IgnoreInstances.Drops,
		workspace.IgnoreInstances.Zombies,
		workspace.IgnoreInstances.DeadZombies,
	}
end

function CharacterHighlightController:KnitStart()
	PlayerEventController = Knit.GetController("PlayerEventController")

	PlayerEventController.OnCharacterLoaded:Connect(function()
		self:_InitHighlightThread()
	end)

	self:_watchOtherPlayers()

	for _, zombie in ipairs(workspace.IgnoreInstances.Zombies:GetChildren()) do
		self:_RegisterZombie(zombie)
	end

	workspace.IgnoreInstances.Zombies.ChildAdded:Connect(function(zombie)
		self:_RegisterZombie(zombie)
	end)
end

return CharacterHighlightController
