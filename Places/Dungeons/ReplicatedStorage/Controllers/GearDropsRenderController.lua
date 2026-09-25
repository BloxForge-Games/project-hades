--!strict
--[[
     Module: GearDropsRenderController.lua
     Description:
     Singleton client-side render coordinator for gear drops. Mirrors
     RelicRenderController's role for relics — handles all the cross-drop
     hover orchestration that doesn't belong in a per-instance component:
     the hovered drop's highlight and scale bump, its label swap for the
     prompt, and the FLOOR DIM (every other owned drop steps back) that
     it shares with the relic side through PickupHoverStyle.

     The floor dim is DERIVED, not toggled. Two inputs -- this side's own
     prompt (active + the hovered drop) and the relic side's hover
     (SetExternalHover) -- are OR'd into one wanted state, committed
     HOVER_DEBOUNCE_SECONDS after the last change, and applied only to the
     drops whose state actually differs. Walking across a loot pile used
     to fire a full restore-then-dim of every drop on every footfall.
]]

--[ Roblox Services ]--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local ProximityPromptService = game:GetService("ProximityPromptService")
local CollectionService = game:GetService("CollectionService")

--[ Imports ]--

local RelicRenderController =
	require(ReplicatedStorage.Controllers.RelicController.SubControllers.RelicRenderController)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local PickupHoverStyle = require(ReplicatedStorage.Submodules.Core.Shared.Data.PickupHoverStyle)
local getGearIdleScale = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Gear.getGearIdleScale)
local fadeSubtree = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.fadeSubtree)

--[ Constants ]--

-- The hovered drop's OWN treatment (highlight fill, scale bump): snappier
-- than the floor dim, whose timing is PickupHoverStyle's.
local TWEEN_DURATION = 0.25
local TWEEN_INFO = TweenInfo.new(TWEEN_DURATION, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out)

-- Idle scale ladder now lives in
-- Shared/Functions/Gear/getGearIdleScale. HOVER_SCALE_MULTIPLIER stays
-- here — it's render-controller specific (only used to compute the
-- bumped scale on PromptShown; idle restore goes back through the
-- shared resolver).
local HOVER_SCALE_MULTIPLIER = 1.25

local HIGHLIGHT_FILL_TRANSPARENCY_HOVERED = 0.75
local HIGHLIGHT_FILL_TRANSPARENCY_HIDDEN = 1
local HIGHLIGHT_FILL_COLOR = Color3.fromRGB(255, 255, 255)
local HIGHLIGHT_OUTLINE_COLOR = Color3.fromRGB(255, 255, 255)

-- The floor dim, shared with the relic side (see PickupHoverStyle).
local HOVER_DEBOUNCE_SECONDS = PickupHoverStyle.HoverDebounceSeconds

-- Names — must match the controller / component conventions.
local SCALE_VALUE_NAME = "GearScale"

-- Attribute names.
local ATTR_TYPE = "GearType"
local ATTR_NAME = "GearName"
local ATTR_EXPIRED = "Expired"
local ATTR_OWNER_ID = "OwnerId"
-- Attributes.PublicDrop: nobody owns it, so every client sees it and it
-- takes the dim treatment on every client rather than only its owner's.
local ATTR_PUBLIC_DROP = "PublicDrop"

-- CLIENT-LOCAL attributes (nothing server-side reads or writes these).
-- Together with Expired they are the whole answer to "should this
-- drop's billboard be showing":
--   PromptShown    the player is close enough that the pickup prompt is
--                  up, and the label would fight it for the same space.
--   PickupPending  this player triggered the prompt and the server has
--                  not answered yet. Set by the GearDrop component.
local ATTR_PROMPT_SHOWN = "PromptShown"
local ATTR_PICKUP_PENDING = "PickupPending"

-- The per-drop applied-dim record is keyed by drop models that die with
-- the floor: weak keys.
local WEAK_KEYS = { __mode = "k" }

--[ Controller ]--

local GearDropsRenderController = {
	Name = "GearDropsRenderController",
	Dependencies = { RelicRenderController } :: { any },

	-- Single shared Highlight, built in Start. Reparented between hovered
	-- drops; sits detached (Parent = nil) when nothing is hovered.
	_highlight = nil :: Highlight?,

	-- The floor dim's two inputs (see the header) and its bookkeeping.
	_ownHoverActive = false,
	_ownHoverModel = nil :: Model?,
	_externalHoverActive = false,
	_dimCommitPending = false,
	-- [drop model] = true while this controller holds it dimmed.
	_dimApplied = setmetatable({}, WEAK_KEYS) :: any,
}

--[ Private helpers ]--

-- Finds the visualModel child of a gear-drop outer Model. The outer
-- Model has exactly two children: a BasePart (the carrier) and a
-- Model (the visualModel — what the player actually sees). Returning
-- the visualModel as the highlight adornee scopes the highlight to the
-- visible mesh parts; adorning the outer Model would also touch the
-- invisible carrier geometry, which can produce a small stray outline.
function GearDropsRenderController._findVisualModel(_self: typeof(GearDropsRenderController), model: Model): Model?
	for _, child in model:GetChildren() do
		if child:IsA("Model") then
			return child
		end
	end
	return nil
end

-- The dim (or restore) of ONE drop: the shared fade walk (fadeSubtree),
-- riding its one pass for the billboard flag and the sparkles too.
--
--   * BaseParts already at Transparency 1 (carrier, hidden Handle on
--     weapon drops, artist-authored invisible markers) are skipped:
--     tweening those would expose geometry that's meant to stay
--     invisible.
--   * Labels and their strokes take the TEXT value, lighter than the
--     mesh, and their billboard drops behind geometry while dimmed. Every
--     TextLabel in a drop is billboard text (the prompt is a custom
--     style, so it puts no UI in the model), which is what lets this skip
--     an ancestor check per descendant.
--   * The rarity sparkle set (Layer / Spark / Shine) is written directly,
--     not tweened, matching the relic side: a fade on particle intensity
--     reads as "the dimming finished between frames" anyway.
function GearDropsRenderController._applyDropDim(
	_self: typeof(GearDropsRenderController),
	model: Instance,
	dim: boolean
)
	fadeSubtree(model, {
		targetTransparency = if dim then PickupHoverStyle.ModelTransparency else 0,
		textTransparency = if dim then PickupHoverStyle.TextTransparency else 0,
		tweenInfo = PickupHoverStyle.TweenInfo,
		skipHidden = true,
		includeDecals = true,
		includeGuis = true,
		visit = function(descendant)
			if descendant:IsA("BillboardGui") then
				descendant.AlwaysOnTop = not dim
			elseif descendant:IsA("ParticleEmitter") then
				local restored = PickupHoverStyle.ParticleRestoredBrightness[descendant.Name]
				if restored then
					descendant.Brightness = if dim then PickupHoverStyle.ParticleDimmedBrightness else restored
				end
			end
		end,
	})
end

-- Recomputes whether a drop's billboard should be showing from the three
-- flags above, and applies it.
--
-- DERIVED rather than toggled, because the toggling version lost a race
-- on every successful pickup. Triggering the prompt disables it, which
-- fires PromptHidden immediately, but the server's Expired flag only
-- arrives a round trip later — so the restore ran first and flashed the
-- label back up for a moment over a drop that was already gone. Asking
-- "what should be true right now" has no ordering to get wrong: whoever
-- changes a flag calls this, and the last word always matches the state.
function GearDropsRenderController.RefreshBillboardVisibility(self: typeof(GearDropsRenderController), model: Instance)
	local hidden = model:GetAttribute(ATTR_PROMPT_SHOWN) == true
		or model:GetAttribute(ATTR_PICKUP_PENDING) == true
		or model:GetAttribute(ATTR_EXPIRED) == true
	self:_setDropBillboardEnabled(model, not hidden)
end

-- Toggles BillboardGui.Enabled on every billboard inside a drop. Used
-- only on the HOVERED drop (suppress the floating label so it doesn't
-- compete with the ProximityPrompt UI). Direct write — instant on/off
-- mirrors `model.PrimaryPart.RelicName.Enabled = false` in the relic
-- path.
function GearDropsRenderController._setDropBillboardEnabled(
	_self: typeof(GearDropsRenderController),
	model: Instance,
	enabled: boolean
)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BillboardGui") then
			descendant.Enabled = enabled
		end
	end
end

-- The floor dim as it should be RIGHT NOW, applied to every drop whose
-- recorded state differs. Filters:
--   * Skips the hovered model itself (it is lit, not dimmed).
--   * Skips drops that are mid-fade (ATTR_EXPIRED == true) — their
--     own _fadeOutAndDestroy is driving transparency to 1; we'd
--     fight that.
--   * Skips drops the local player doesn't own. Non-owned drops are
--     invisible on this client (spawned hidden by the server, see
--     privateDropVisibility, and never revealed here); tweening their
--     transparency from 1 → 0.5 would partially un-hide other players'
--     loot. A PUBLIC drop (one a player dropped) is visible to everyone,
--     so it dims on everyone's client -- the owner filter only exists to
--     avoid un-hiding loot this client cannot see.
local localUserId = Players.LocalPlayer.UserId
function GearDropsRenderController._commitDim(self: typeof(GearDropsRenderController))
	local active = self._ownHoverActive or self._externalHoverActive
	local hoveredModel = if self._ownHoverActive then self._ownHoverModel else nil
	for _, model in CollectionService:GetTagged(TagList.GearDrop) do
		if not model:IsDescendantOf(workspace) then
			continue
		end
		if model:GetAttribute(ATTR_EXPIRED) == true then
			continue
		end
		if model:GetAttribute(ATTR_PUBLIC_DROP) ~= true and model:GetAttribute(ATTR_OWNER_ID) ~= localUserId then
			continue
		end
		local wanted = active and model ~= hoveredModel
		local applied = self._dimApplied[model] == true
		if wanted == applied then
			continue
		end
		self:_applyDropDim(model, wanted)
		self._dimApplied[model] = if wanted then true else nil
	end
end

-- Schedules a commit HOVER_DEBOUNCE_SECONDS out. Every input change in
-- that window folds into the one commit, which then applies only the
-- difference between what is on the floor and what is wanted.
function GearDropsRenderController._scheduleDimCommit(self: typeof(GearDropsRenderController))
	if self._dimCommitPending then
		return
	end
	self._dimCommitPending = true
	task.delay(HOVER_DEBOUNCE_SECONDS, function()
		self._dimCommitPending = false
		self:_commitDim()
	end)
end

-- This side's own prompt: the hovered drop lights up and everything else
-- steps back — other gear here, and relics, runes and vending machines
-- through the relic controller. The relic side is told at once (it
-- debounces its own commit); the cross-call never comes back, so there
-- is no loop.
function GearDropsRenderController._setOwnHover(self: typeof(GearDropsRenderController), active: boolean, model: Model?)
	self._ownHoverActive = active
	self._ownHoverModel = if active then model else nil
	self:_scheduleDimCommit()
	if RelicRenderController then
		RelicRenderController:SetExternalHover(active)
	end
end

-- Tweens the hovered drop's GearScale NumberValue. The per-instance
-- GearDrop component listens to that NumberValue's Changed signal and
-- calls Model:ScaleTo, so this single tween drives the whole scale
-- animation. If the NumberValue is missing (race during build), no-op.
function GearDropsRenderController._tweenHoveredScale(
	_self: typeof(GearDropsRenderController),
	model: Model,
	targetScale: number
)
	local carrier = model.PrimaryPart
	if not carrier then
		return
	end
	local scaleValue = carrier:FindFirstChild(SCALE_VALUE_NAME)
	if scaleValue and scaleValue:IsA("NumberValue") then
		TweenService:Create(scaleValue, TWEEN_INFO, { Value = targetScale }):Play()
	end
end

-- Called by RelicRenderController when a relic, rune, vending machine or
-- stall display is hovered / released so the gear-drop side dims in
-- lockstep. The caller has already debounced; this only records the
-- input and schedules the commit (no drop is the "hovered" one in this
-- path, so every owned drop takes the dim). Never calls back.
function GearDropsRenderController.SetExternalHover(self: typeof(GearDropsRenderController), active: boolean)
	self._externalHoverActive = active
	self:_scheduleDimCommit()
end

-- Returns the GearDrop-tagged ancestor Model of the prompt, or nil if
-- the prompt isn't on a gear drop. Centralizes the filter so the
-- two event handlers stay symmetric.
function GearDropsRenderController._resolveDropModelFromPrompt(
	_self: typeof(GearDropsRenderController),
	prompt: ProximityPrompt
): Model?
	local model = prompt:FindFirstAncestorOfClass("Model")
	if model and CollectionService:HasTag(model, TagList.GearDrop) then
		return model
	end
	return nil
end

--[ Lifecycle ]--

function GearDropsRenderController.Start(self: typeof(GearDropsRenderController))
	local highlight = Instance.new("Highlight")
	highlight.Name = "GearDropHighlight"
	highlight.FillColor = HIGHLIGHT_FILL_COLOR
	highlight.OutlineColor = HIGHLIGHT_OUTLINE_COLOR
	highlight.FillTransparency = HIGHLIGHT_FILL_TRANSPARENCY_HIDDEN
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.Parent = nil
	self._highlight = highlight

	-- Gear hover is the FULL treatment, matching a relic hover: the
	-- hovered drop lights up at once (highlight, scale, its own label
	-- hidden so it does not fight the prompt) and the floor dim follows
	-- through the debounced commit.
	ProximityPromptService.PromptShown:Connect(function(prompt: ProximityPrompt)
		local model = self:_resolveDropModelFromPrompt(prompt)
		if not model then
			return
		end

		-- Highlight the visualModel. Adornee'ing the outer Model also
		-- works but the highlight then touches the invisible carrier
		-- geometry (small stray outline). Scoping to the visualModel
		-- makes the outline trace only the visible mesh.
		local visualModel = self:_findVisualModel(model)
		if visualModel then
			highlight.Adornee = visualModel
			highlight.Parent = visualModel
			TweenService:Create(highlight, TWEEN_INFO, { FillTransparency = HIGHLIGHT_FILL_TRANSPARENCY_HOVERED })
				:Play()
		end

		-- Scale up the hovered drop.
		local idleScale =
			getGearIdleScale(model:GetAttribute(ATTR_NAME) :: string?, model:GetAttribute(ATTR_TYPE) :: string?)
		local hoverScale = idleScale * HOVER_SCALE_MULTIPLIER
		self:_tweenHoveredScale(model, hoverScale)

		-- The hovered drop's own label goes away while its prompt is up,
		-- the same swap the relic path makes.
		model:SetAttribute(ATTR_PROMPT_SHOWN, true)
		self:RefreshBillboardVisibility(model)

		self:_setOwnHover(true, model)
	end)

	ProximityPromptService.PromptHidden:Connect(function(prompt: ProximityPrompt)
		local model = self:_resolveDropModelFromPrompt(prompt)
		if not model then
			return
		end

		-- Detach highlight first so a quick hover-on/hover-off cycle
		-- doesn't leave a stale outline mid-tween. Direct write
		-- (no tween) — same as RelicRenderController.
		highlight.FillTransparency = HIGHLIGHT_FILL_TRANSPARENCY_HIDDEN
		highlight.Adornee = nil
		highlight.Parent = nil

		-- Scale back to idle.
		local idleScale =
			getGearIdleScale(model:GetAttribute(ATTR_NAME) :: string?, model:GetAttribute(ATTR_TYPE) :: string?)
		self:_tweenHoveredScale(model, idleScale)

		-- Label back, unless something else still says otherwise — a
		-- pickup in flight, or a drop already fading out.
		model:SetAttribute(ATTR_PROMPT_SHOWN, false)
		self:RefreshBillboardVisibility(model)

		self:_setOwnHover(false, nil)
	end)
end

return GearDropsRenderController
