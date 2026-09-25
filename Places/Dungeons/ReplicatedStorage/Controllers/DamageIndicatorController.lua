--!strict
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local InputPlatformController = require(ReplicatedStorage.Submodules.Core.Source.Controllers.InputPlatformController)
local CharacterHighlightController = require(ReplicatedStorage.Controllers.CharacterHighlightController)
-- Blink client module for the Combat domain (bfg-core/Network/Combat.blink):
-- the typed replacement for DamageIndicatorService's old remote signals.
local Combat = require(ReplicatedStorage.Submodules.Core.Source.Network.Combat)
local Signal = require(ReplicatedStorage.Submodules.Core.Packages.Signal)
local onDamageIndicator = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Highlight.onDamageIndicator)
local HighlightIndicators = require(ReplicatedStorage.Submodules.Core.Shared.Enums.HighlightIndicators)
local DamageIndicatorColors = require(ReplicatedStorage.Submodules.Core.Shared.Enums.DamageIndicatorColors)
local isMagicCutscenePlaying =
	require(ReplicatedStorage.Submodules.Core.Shared.Functions.Cutscene.isMagicCutscenePlaying)
local playHitBurst = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.playHitBurst)
local getRoot = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Character.getRoot)

local DEFAULT_TWEEN_INFO_PROPS = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut, 0, false, 0)
local FONT_SCALED = 1.25
-- The number's face. One Font, built once: it used to be a Font.new per
-- damage number, which under a spray of hits was an allocation per hit.
local DAMAGE_FONT =
	Font.new("rbxasset://fonts/families/Montserrat.json", Enum.FontWeight.SemiBold, Enum.FontStyle.Normal)

-- Motion ARC: two chained tweens on the BillboardGui's offset. RISE eases
-- OUT (fast launch, slowing into the apex), then FALL eases IN (slow tip-
-- over, accelerating down like gravity) to a point slightly BELOW where the
-- number spawned, so the drop is unmistakable. The fade runs over the FALL
-- only — fully opaque on the way up, fading on the way down. Offsets are in
-- ExtentsOffset units (multiples of the adornee part's half-size), same
-- units the old straight-up drift used.
--   ARC_PEAK_*     height band of the apex
--   ARC_END_*      where it settles (negative = below the spawn point)
--   ARC_LATERAL_*  camera-relative sideways drift over the whole flight
--                  (random magnitude AND sign) via ExtentsOffset.X, so
--                  rapid hits fan out instead of stacking in one column
-- Every one of these is rolled PER NUMBER so no two hits trace the same
-- path or land in the same spot: apex height, how far it drifts sideways
-- (and which way), and how far below the spawn point it settles.
local ARC_PEAK_MIN, ARC_PEAK_MAX = 30, 42
local ARC_END_MIN, ARC_END_MAX = -10, -2
local ARC_LATERAL_MIN, ARC_LATERAL_MAX = 4, 14
local ARC_RISE_TWEEN_INFO = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local ARC_FALL_TWEEN_INFO = TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local FADE_TWEEN_INFO = TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.In) -- = the fall
-- Teardown once the fall (and its fade) has landed, with a small margin.
local INDICATOR_LIFETIME = ARC_RISE_TWEEN_INFO.Time + ARC_FALL_TWEEN_INFO.Time + 0.15

-- Critical hits: gold number, and a larger indicator frame than a normal
-- hit. The TextLabel is forced TextScaled at spawn (see the handler), so
-- the frame size IS the text size — FONT_SCALED (the shared scale divisor)
-- is left alone; only the crit frame's base dimensions grow.
local CRITICAL_COLOR3 = Color3.fromRGB(255, 96, 10)
local CRITICAL_SIZE_DESKTOP = UDim2.fromOffset(100 / FONT_SCALED, 52 / FONT_SCALED)
local CRITICAL_SIZE_MOBILE = UDim2.fromOffset(70 / FONT_SCALED, 34 / FONT_SCALED)

-- Status DoT ticks draw at this fraction of a normal hit's frame (0.5 =
-- half size). Ticks never crit, so this only ever scales the non-crit size.
local STATUS_SIZE_SCALE = 0.85

-- Crit JITTER: while the number is on its way up, the label rattles in every
-- direction — a few px of position offset and a few degrees of rotation,
-- re-rolled every frame — with an envelope that decays to zero over
-- CRIT_JITTER_DURATION, so it lands calm at the apex and falls clean. Done
-- on the LABEL (Position / Rotation), not the billboard offset, so it never
-- fights the arc tweens driving ExtentsOffset.
local CRIT_JITTER_DURATION = 0.5
local CRIT_JITTER_PX = 5
local CRIT_JITTER_DEGREES = 10

-- One crit number mid-rattle: its label and when the rattle began.
type CritJitter = { label: TextLabel, startedAt: number }

-- Impact size-pulse for WEAPON / MAGIC hit numbers (status DoT ticks skip
-- it — they're a steady readout, not an impact). Two beats: overshoot, then
-- settle — "big, then small" — while the existing upward drift + fade run
-- on top unchanged.
--
-- HOW it pulses matters, given how the asset is built (Indicator is a
-- BillboardGui with ClipsDescendants ON, holding a TextLabel):
--   * The TextLabel is forced TextScaled = true at spawn. The asset authors
--     it OFF, and with it off no Size tween — label OR billboard — moves
--     the glyphs at all (only the box changes; the font size is fixed), so
--     the pulse was invisible. TextScaled makes "box size = text size",
--     which is also what the crit sizing has always assumed.
--   * The BillboardGui's Size is NEVER tweened. A BillboardGui has no
--     AnchorPoint — it grows from its top-left corner off the adornee, so
--     tweening it big-then-small made the whole number visibly rise and
--     drop (the "it's tweening the text down" bug). It's set to the final
--     size ONCE, up front, and stays put.
--   * Only the TextLabel pulses, as a SCALE fraction of that fixed frame,
--     center-anchored so it grows in place. Overshoot is > 1 (bigger than
--     the frame) — legal because TextScaled fits the glyphs to the label,
--     and the label's own bounds may spill past the clip edge briefly.
--     PULSE_OVERSHOOT_PX is the intent (~+px on the final size), converted
--     to a per-axis scale so it reads the same pop on every platform size.
local PULSE_OVERSHOOT_PX = 7.5
local PULSE_IN_TWEEN_INFO = TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PULSE_SETTLE_TWEEN_INFO = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
-- Fallback highlight name (used only when the damaged model isn't in
-- the zombie registry — non-zombie targets that somehow trigger
-- DamageVFXRequested). Zombies go through the unified MobHighlight
-- via CharacterHighlightController:RequestDamageFlash and never hit
-- this branch.
local HIGHLIGHT_NAME = HighlightIndicators.DamageIndicator

-- Status procs use their own authored asset, NOT the shared HitFX the
-- regular hit burst clones — they sit side by side under the same folder.
local STATUS_VFX_NAME = "StatusFX"

-- One emitter inside the shared HitFX draws a blade arc, so it plays on
-- MELEE hits only — a bullet or a spell landing shouldn't stamp a sword
-- cut on the target. Every other emitter in that asset is
-- weapon-agnostic and still fires on all damage.
--
-- Matched by NAME rather than by pulling the child out explicitly, so
-- the asset can be re-laid-out in Studio without this going stale.

-- Burst size. This stays in code because ParticleEmitter has no authored
-- burst-count property; :Emit needs to be told a number. Everything ELSE
-- about how StatusFX looks — Size, Lifetime, ZOffset, Rate, Speed — is
-- authored on the asset and deliberately left alone here, so it can be
-- tuned in Studio where it's visible.
local STATUS_VFX_EMIT_COUNT = 5

-- Grace period added after the longest-lived particle should have died,
-- before Debris destroys the clone. Destroying the instance kills anything
-- still in flight, so this is DERIVED from the authored Lifetime rather
-- than a fixed guess that a long authored fade would outlive.
local STATUS_VFX_CLEANUP_MARGIN = 0.5

local DamageIndicatorController = {
	Name = "DamageIndicatorController",
	Dependencies = { InputPlatformController, CharacterHighlightController } :: { any },

	-- Every crit number still rattling, driven by ONE Heartbeat that exists
	-- only while this list does (see _addCritJitter). It used to be a
	-- Heartbeat connection per crit.
	_critJitters = {} :: { CritJitter },
	_critJitterConnection = nil :: RBXScriptConnection?,
}

DamageIndicatorController.OnIndicatorRequested = Signal.new()

-- One frame of the crit rattle for every live crit number: a fresh random
-- offset and tilt scaled by an envelope that decays to zero over
-- CRIT_JITTER_DURATION, so each lands calm at its apex and falls clean.
-- Finished (or torn down early) numbers are reset and dropped; the
-- connection goes with the last one.
function DamageIndicatorController._stepCritJitters(self: typeof(DamageIndicatorController))
	local now = os.clock()
	local jitters = self._critJitters
	for index = #jitters, 1, -1 do
		local jitter = jitters[index]
		local label = jitter.label
		local envelope = 1 - math.clamp((now - jitter.startedAt) / CRIT_JITTER_DURATION, 0, 1)
		if envelope <= 0 or not label.Parent then
			if label.Parent then
				label.Rotation = 0
				label.Position = UDim2.fromScale(0.5, 0.5)
			end
			table.remove(jitters, index)
			continue
		end
		label.Rotation = (math.random() * 2 - 1) * CRIT_JITTER_DEGREES * envelope
		label.Position = UDim2.new(
			0.5,
			(math.random() * 2 - 1) * CRIT_JITTER_PX * envelope,
			0.5,
			(math.random() * 2 - 1) * CRIT_JITTER_PX * envelope
		)
	end
	if #jitters == 0 and self._critJitterConnection then
		self._critJitterConnection:Disconnect()
		self._critJitterConnection = nil
	end
end

-- Starts the rattle on a crit number's label, connecting the shared
-- Heartbeat if this is the first live one.
function DamageIndicatorController._addCritJitter(self: typeof(DamageIndicatorController), label: TextLabel)
	table.insert(self._critJitters, { label = label, startedAt = os.clock() })
	if not self._critJitterConnection then
		self._critJitterConnection = RunService.Heartbeat:Connect(function()
			self:_stepCritJitters()
		end)
	end
end

function DamageIndicatorController.Start(self: typeof(DamageIndicatorController))
	Combat.DamageVFX.On(function(payload)
		-- The mob can be gone before this arrives (died / streamed out).
		local character = payload.Character
		if not character then
			return
		end
		local color3 = payload.Color
		local sparks = payload.Sparks
		-- Zombies AND the local character resolve through the single-
		-- highlight controller; only untracked models (breakables, NPCs)
		-- take the standalone flash.
		if
			CharacterHighlightController
			and (CharacterHighlightController._zombieRegistry[character] or character == Players.LocalPlayer.Character)
		then
			CharacterHighlightController:RequestDamageFlash(character)
		else
			onDamageIndicator(character, HIGHLIGHT_NAME)
		end

		-- The flash above is for every hit; the sparks below are not. A
		-- gun shot sends `sparks = false` (its BulletImpact is the impact),
		-- and nil -- every other caller -- keeps them.
		if sparks == false then
			return
		end

		-- No root (mid-despawn) means nowhere to burst.
		local root = getRoot(character)
		if not root then
			return
		end
		-- The shared hit burst, rolled a random angle per hit so a combo
		-- never reads as one frame repeated. Resisted hits tint the impact
		-- sparks to match the grey number -- keyed off the shared enum, not
		-- a colour literal, so a retune of the resist colour can't silently
		-- desync this.
		playHitBurst(root.CFrame, {
			roll = true,
			color = if color3 == DamageIndicatorColors.Resisted then color3 :: Color3 else nil,
		})
	end)

	-- Status proc burst. Clones the dedicated StatusFX asset (NOT the HitFX
	-- the hit burst above uses) and tints every emitter to the status's
	-- StatusConditionData colour. Fires IN ADDITION to that hit burst rather
	-- than replacing it -- see DamageIndicatorService:ShowStatusVFX for why
	-- it can't replace it.
	--
	-- Tints every ParticleEmitter descendant rather than naming children
	-- explicitly, so StatusFX can hold any emitter layout and an emitter
	-- added later still gets tinted instead of firing an untinted puff.
	Combat.StatusVFX.On(function(payload)
		local character = payload.Character
		local color3 = payload.Color
		local vfxName = payload.VFXName
		-- A proc can land on the same frame the mob dies, by which point
		-- the model may already be gone on this client.
		local hrp = if character and character.Parent then getRoot(character) else nil
		if not hrp then
			return
		end

		-- FindFirstChild rather than a direct index: a missing asset should
		-- drop the flash and warn once per proc, not error out of the
		-- handler.
		-- A status may bring its own authored asset (Black Burn) instead of
		-- the shared StatusFX. Same folder, same burst — different emitters.
		local assetName = vfxName or STATUS_VFX_NAME
		local template = ReplicatedStorage.GameAssets.VFX.SwordSlash:FindFirstChild(assetName)
		if not template then
			warn("[DamageIndicatorController] Missing GameAssets.VFX.SwordSlash." .. assetName)
			return
		end

		local statusVFX = template:Clone()
		statusVFX.Parent = hrp

		-- Colour is the ONE property overridden on the SHARED asset, because
		-- it's per-status data from StatusConditionData and can't be baked
		-- into a single asset. A status with its own asset is skipped: its
		-- colour is already authored, and tinting would flatten it.
		-- Size / Lifetime / ZOffset render exactly as authored either way.
		local tint = if vfxName then nil else ColorSequence.new(color3)
		local longestLifetime = 0
		for _, particle in pairs(statusVFX:GetDescendants()) do
			if particle:IsA("ParticleEmitter") then
				if tint then
					particle.Color = tint
				end
				longestLifetime = math.max(longestLifetime, particle.Lifetime.Max)
				particle:Emit(STATUS_VFX_EMIT_COUNT)
			end
		end

		Debris:AddItem(statusVFX, longestLifetime + STATUS_VFX_CLEANUP_MARGIN)
	end)

	-- `resistKind` ("Projectile" | "Magic" | nil) picks the resist sound.
	-- Sent explicitly by DamageService rather than inferred from the number's
	-- colour: both resist kinds now render the SAME grey, so colour can no
	-- longer distinguish them (this used to match two different golds).
	Combat.DamageIndicator.On(function(payload)
		local character = payload.Character
		if not character then
			return
		end
		local value = payload.Value
		local critical = payload.Critical
		local color3 = payload.Color
		local isMelee = payload.IsMelee
		local resistKind = payload.ResistKind
		local isStatus = payload.IsStatus
		-- Magic cutscene: DROPPED, not deferred (see
		-- TextIndicatorController for why nothing is deferred).
		if isMagicCutscenePlaying() then
			return
		end

		-- Where the number spawns: the Head, or the root of a target that
		-- has none (a breakable, a headless rig). Neither means nothing to
		-- anchor to, so no number -- and no sound for one.
		local anchor = character:FindFirstChild("Head") or character.PrimaryPart or getRoot(character)
		if not (anchor and anchor:IsA("BasePart")) then
			return
		end

		self.OnIndicatorRequested:Fire()

		local damageIndicator = game.ReplicatedStorage.GameAssets.Particles.DamageIndicator:Clone()
		local indicator = damageIndicator.Indicator
		local textLabel = damageIndicator.Indicator.TextLabel
		textLabel.FontFace = DAMAGE_FONT
		local indicatorSize

		if resistKind == "Projectile" then
			ReplicatedStorage.GameAssets.Sounds.Bulletproof:Play()
		elseif resistKind == "Magic" then
			ReplicatedStorage.GameAssets.Sounds.MagicResist:Play()
		else
			if not isMelee then
				ReplicatedStorage.GameAssets.Sounds.BulletHit:Play()
			end
		end

		-- Indicator Billboard GUI prop changes
		indicator.ExtentsOffsetWorldSpace = Vector3.new(0, 0, 0)
		-- TextLabel prop changes. TextScaled is forced ON here: the asset
		-- authors it off, and with it off the font size is fixed, so no
		-- Size tween can make the number pulse (or make crits any bigger).
		-- ON = the label's box IS the text size, which every size below
		-- (crit frame, pulse overshoot) relies on.
		textLabel.TextScaled = true
		textLabel.TextTransparency = 0
		textLabel.UIStroke.Transparency = 0.65
		textLabel.UIStroke.Color = Color3.fromRGB(0, 0, 0)

		-- Critical: bigger frame (TextScaled = bigger text) and the crit
		-- gold. Gold wins over the damage-type colour (magic purple /
		-- resist grey) — "this was a crit" is the louder signal to read
		-- at a glance; the type is still carried by the hit VFX tint.
		if critical then
			indicatorSize = if not InputPlatformController:IsMobilePlatform()
				then CRITICAL_SIZE_DESKTOP
				else CRITICAL_SIZE_MOBILE
			textLabel.TextColor3 = CRITICAL_COLOR3
			textLabel.Text = value .. "!"

			ReplicatedStorage.GameAssets.Sounds.CriticalHit:Play()
		else
			indicatorSize = if not InputPlatformController:IsMobilePlatform()
				then UDim2.fromOffset(75 / FONT_SCALED, 40 / FONT_SCALED)
				else UDim2.fromOffset(60 / FONT_SCALED, 25 / FONT_SCALED)
			textLabel.TextColor3 = color3 or Color3.fromRGB(255, 255, 255)
			textLabel.Text = value

			-- Status DoT ticks read as a secondary, "it's working" readout —
			-- half the size of a real hit so a Burn stack never competes
			-- with the number that landed it. TextScaled fits the glyphs to
			-- the frame, so halving the frame halves the text.
			if isStatus then
				indicatorSize = UDim2.fromOffset(
					indicatorSize.X.Offset * STATUS_SIZE_SCALE,
					indicatorSize.Y.Offset * STATUS_SIZE_SCALE
				)
			end
		end

		-- Part prop changes
		damageIndicator.Position = anchor.Position

		-- The BillboardGui frame is FIXED at the final size, immediately —
		-- never tweened (see the pulse constants for why). The label is
		-- center-anchored inside it so any size change grows in place.
		indicator.Size = indicatorSize
		textLabel.AnchorPoint = Vector2.new(0.5, 0.5)
		textLabel.Position = UDim2.fromScale(0.5, 0.5)

		damageIndicator.Parent = workspace.IgnoreInstances.MagicSpells

		-- Size-in on the LABEL only, as a scale of the fixed frame.
		-- Weapon / magic hits get the impact PULSE (overshoot past full
		-- size, then settle to full); status ticks keep the plain grow-in
		-- from small to full.
		local fullSize = UDim2.fromScale(1, 1)
		if isStatus then
			textLabel.Size = UDim2.fromScale(0, 0)
			TweenService:Create(textLabel, DEFAULT_TWEEN_INFO_PROPS, { Size = fullSize }):Play()
		else
			-- +PULSE_OVERSHOOT_PX on each axis, expressed as a scale of the
			-- frame so it's the same relative pop on desktop and mobile.
			local overshootSize = UDim2.fromScale(
				(indicatorSize.X.Offset + PULSE_OVERSHOOT_PX) / indicatorSize.X.Offset,
				(indicatorSize.Y.Offset + PULSE_OVERSHOOT_PX) / indicatorSize.Y.Offset
			)

			textLabel.Size = UDim2.fromScale(0, 0)
			local pulseIn = TweenService:Create(textLabel, PULSE_IN_TWEEN_INFO, { Size = overshootSize })

			-- Settle back to full size once the overshoot lands.
			pulseIn.Completed:Once(function()
				TweenService:Create(textLabel, PULSE_SETTLE_TWEEN_INFO, { Size = fullSize }):Play()
			end)

			pulseIn:Play()
		end

		-- ARC: rise (ease-out) to a random apex, then fall (ease-in) to just
		-- below the spawn point. Vertical travel is world-space; the
		-- sideways drift is CAMERA-space (ExtentsOffset.X) so it always
		-- reads as left/right on screen from any angle. Fade is chained to
		-- the fall so the number is solid on the way up and dissolves on
		-- the way down.
		local peak = math.random(ARC_PEAK_MIN, ARC_PEAK_MAX)
		local landing = math.random(ARC_END_MIN, ARC_END_MAX)
		local lateral = math.random(ARC_LATERAL_MIN, ARC_LATERAL_MAX) * (if math.random() < 0.5 then -1 else 1)
		indicator.ExtentsOffset = Vector3.zero

		-- Crit rattle on the way up (see CRIT_JITTER_*), on the shared
		-- Heartbeat.
		if critical then
			self:_addCritJitter(textLabel)
		end

		TweenService:Create(indicator, ARC_RISE_TWEEN_INFO, {
			ExtentsOffset = Vector3.new(lateral * 0.5, 0, 0),
		}):Play()
		local rise = TweenService:Create(indicator, ARC_RISE_TWEEN_INFO, {
			ExtentsOffsetWorldSpace = Vector3.new(0, peak, 0),
		})
		rise.Completed:Once(function()
			if not damageIndicator.Parent then
				return
			end
			TweenService:Create(indicator, ARC_FALL_TWEEN_INFO, {
				ExtentsOffsetWorldSpace = Vector3.new(0, landing, 0),
			}):Play()
			TweenService:Create(indicator, ARC_FALL_TWEEN_INFO, {
				ExtentsOffset = Vector3.new(lateral, 0, 0),
			}):Play()
			TweenService:Create(textLabel, FADE_TWEEN_INFO, { TextTransparency = 1 }):Play()
			TweenService:Create(textLabel.UIStroke, FADE_TWEEN_INFO, { Transparency = 1 }):Play()
		end)
		rise:Play()

		Debris:AddItem(damageIndicator, INDICATOR_LIFETIME)
	end)
end

return DamageIndicatorController
