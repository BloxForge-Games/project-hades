--[[
     Module: GearDropsRenderController.lua
     Description:
     Singleton client-side render coordinator for gear drops. Mirrors
     RelicRenderController's role for relics — handles all the cross-drop
     hover orchestration that doesn't belong in a per-instance component:


]]

--[ Roblox Services ]--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local ProximityPromptService = game:GetService("ProximityPromptService")
local CollectionService = game:GetService("CollectionService")

--[ Imports ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local getGearIdleScale = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Gear.getGearIdleScale)

-- Cross-controller reference, resolved in KnitStart. The mirror of the
-- one RelicRenderController holds on THIS controller: hovering a gear
-- drop dims every relic, rune and vending machine, exactly as hovering a
-- relic dims every gear drop. Only one pickup is ever lit at a time.
local RelicRenderController

--[ Constants ]--

local TWEEN_DURATION = 0.25
local TWEEN_INFO = TweenInfo.new(TWEEN_DURATION, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out)

local DIMMED_TRANSPARENCY = 0.5

-- Idle scale ladder now lives in
-- Shared/Functions/Gear/getGearIdleScale. HOVER_SCALE_MULTIPLIER stays
-- here — it's render-controller specific (only used to compute the
-- bumped scale on PromptShown; idle restore goes back through the
-- shared resolver).
local HOVER_SCALE_MULTIPLIER = 1.25

local PARTICLE_DIMMED_BRIGHTNESS = 0.25
local PARTICLE_RESTORED_BRIGHTNESS_LAYER = 4
local PARTICLE_RESTORED_BRIGHTNESS_SPARK = 4
local PARTICLE_RESTORED_BRIGHTNESS_SHINE = 1

local HIGHLIGHT_FILL_TRANSPARENCY_HOVERED = 0.75
local HIGHLIGHT_FILL_TRANSPARENCY_HIDDEN = 1
local HIGHLIGHT_FILL_COLOR = Color3.fromRGB(255, 255, 255)
local HIGHLIGHT_OUTLINE_COLOR = Color3.fromRGB(255, 255, 255)

-- Names — must match the controller / component conventions.
local SCALE_VALUE_NAME = "GearScale"
local PARTICLE_LAYER_NAME = "Layer"
local PARTICLE_SPARK_NAME = "Spark"
local PARTICLE_SHINE_NAME = "Shine"

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

-- Billboard text transparency while another drop is hovered. Matches
-- RelicRenderController's TOGGLE_TRANSPARENCY so a mixed floor of relics
-- and gear dims to one level.
local BILLBOARD_TEXT_DIMMED_TRANSPARENCY = 0.6

--[ Controller ]--

local GearDropsRenderController = Knit.CreateController({
	Name = "GearDropsRenderController",
	Client = {},
})

--[ Private helpers ]--

-- Finds the visualModel child of a gear-drop outer Model. The outer
-- Model has exactly two children: a BasePart (the carrier) and a
-- Model (the visualModel — what the player actually sees). Returning
-- the visualModel as the highlight adornee scopes the highlight to the
-- visible mesh parts; adorning the outer Model would also touch the
-- invisible carrier geometry, which can produce a small stray outline.
function GearDropsRenderController:_findVisualModel(model: Model): Model?
	for _, child in model:GetChildren() do
		if child:IsA("Model") then
			return child
		end
	end
	return nil
end

-- Walks a drop's descendants once and tweens every fadeable surface
-- towards the given targetTransparency. Centralized so the
-- shown/hidden handlers stay short and the set of fadeable types is
-- defined in exactly one place.
--
-- Skips:
--   * BaseParts already at Transparency 1 (carrier, hidden Handle on
--     weapon drops, artist-authored invisible markers). Tweening those
--     would expose geometry that's meant to stay invisible.
function GearDropsRenderController:_tweenDropTransparency(model: Instance, targetTransparency: number)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			if descendant.Transparency ~= 1 then
				TweenService:Create(descendant, TWEEN_INFO, { Transparency = targetTransparency }):Play()
			end
		elseif descendant:IsA("Decal") or descendant:IsA("Texture") or descendant:IsA("UIStroke") then
			TweenService:Create(descendant, TWEEN_INFO, { Transparency = targetTransparency }):Play()
		elseif descendant:IsA("TextLabel") or descendant:IsA("TextButton") then
			TweenService:Create(descendant, TWEEN_INFO, { TextTransparency = targetTransparency }):Play()
		end
	end
end

-- Modulates named ParticleEmitters' Brightness on a drop. dimmed=true
-- pushes all three to PARTICLE_DIMMED_BRIGHTNESS (0.25); dimmed=false
-- restores authored Layer/Spark/Shine values. Direct property writes
-- (not tweens) match RelicRenderController which also writes the
-- Brightness instantly — feels more responsive than a fade on
-- particle intensity, which the eye reads as "the dimming finished
-- between frames" anyway.
function GearDropsRenderController:_setDropParticleBrightness(model: Instance, dimmed: boolean)
	for _, descendant in model:GetDescendants() do
		if not descendant:IsA("ParticleEmitter") then
			continue
		end
		if descendant.Name == PARTICLE_LAYER_NAME then
			descendant.Brightness = dimmed and PARTICLE_DIMMED_BRIGHTNESS or PARTICLE_RESTORED_BRIGHTNESS_LAYER
		elseif descendant.Name == PARTICLE_SPARK_NAME then
			descendant.Brightness = dimmed and PARTICLE_DIMMED_BRIGHTNESS or PARTICLE_RESTORED_BRIGHTNESS_SPARK
		elseif descendant.Name == PARTICLE_SHINE_NAME then
			descendant.Brightness = dimmed and PARTICLE_DIMMED_BRIGHTNESS or PARTICLE_RESTORED_BRIGHTNESS_SHINE
		end
	end
end

-- Flips BillboardGui.AlwaysOnTop on every billboard inside a drop.
-- Direct write (not tween) — boolean property.
function GearDropsRenderController:_setDropBillboardAlwaysOnTop(model: Instance, alwaysOnTop: boolean)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BillboardGui") then
			descendant.AlwaysOnTop = alwaysOnTop
		end
	end
end

-- Fades the TEXT of every billboard inside a drop (labels and their
-- strokes alike). The relic side dims NameText / RarityText by name;
-- walking every TextLabel instead covers the owner line as well and
-- needs no update when the prefab gains another row.
function GearDropsRenderController:_tweenDropBillboardText(model: Instance, targetTransparency: number)
	for _, descendant in model:GetDescendants() do
		if not descendant:IsA("BillboardGui") then
			continue
		end
		for _, label in descendant:GetDescendants() do
			if label:IsA("TextLabel") then
				TweenService:Create(label, TWEEN_INFO, { TextTransparency = targetTransparency }):Play()
				local stroke = label:FindFirstChildOfClass("UIStroke")
				if stroke then
					TweenService:Create(stroke, TWEEN_INFO, { Transparency = targetTransparency }):Play()
				end
			end
		end
	end
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
function GearDropsRenderController:RefreshBillboardVisibility(model: Instance)
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
function GearDropsRenderController:_setDropBillboardEnabled(model: Instance, enabled: boolean)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BillboardGui") then
			descendant.Enabled = enabled
		end
	end
end

-- Walks every OTHER GearDrop on the client and applies the dim
-- treatment (transparency + particles + AlwaysOnTop). Filters:
--   * Skips the hovered model itself.
--   * Skips drops that are mid-fade (ATTR_EXPIRED == true) — their
--     own _fadeOutAndDestroy is driving transparency to 1; we'd
--     fight that.
--   * Skips drops the local player doesn't own. Non-owned drops are
--     hidden on this client (the client component's _hideForNonOwner
--     sets Transparency=1 + disables particles + disables billboard);
--     tweening their transparency from 1 → 0.5 would partially
--     un-hide other players' loot. Owner-only drops also means only
--     owner-hovers can fire PromptShown anyway, so the dim only ever
--     needs to touch the local player's own siblings.
local localUserId = Players.LocalPlayer.UserId
function GearDropsRenderController:_applyOthersDim(hoveredModel: Model, dim: boolean)
	local targetTransparency = dim and DIMMED_TRANSPARENCY or 0
	local alwaysOnTop = not dim
	for _, otherModel in CollectionService:GetTagged(TagList.GearDrop) do
		if otherModel == hoveredModel then
			continue
		end
		if otherModel:GetAttribute(ATTR_EXPIRED) == true then
			continue
		end
		-- A PUBLIC drop (one a player dropped) is visible to everyone, so
		-- it dims on everyone's client -- the owner filter above only
		-- exists to avoid un-hiding loot this client cannot see.
		if
			otherModel:GetAttribute(ATTR_PUBLIC_DROP) ~= true
			and otherModel:GetAttribute(ATTR_OWNER_ID) ~= localUserId
		then
			continue
		end
		self:_tweenDropTransparency(otherModel, targetTransparency)
		self:_setDropParticleBrightness(otherModel, dim)
		self:_setDropBillboardAlwaysOnTop(otherModel, alwaysOnTop)
		self:_tweenDropBillboardText(otherModel, if dim then BILLBOARD_TEXT_DIMMED_TRANSPARENCY else 0)
	end
end

-- Tweens the hovered drop's GearScale NumberValue. The per-instance
-- GearDrop component listens to that NumberValue's Changed signal and
-- calls Model:ScaleTo, so this single tween drives the whole scale
-- animation. If the NumberValue is missing (race during build), no-op.
function GearDropsRenderController:_tweenHoveredScale(model: Model, targetScale: number)
	local carrier = model.PrimaryPart
	if not carrier then
		return
	end
	local scaleValue = carrier:FindFirstChild(SCALE_VALUE_NAME)
	if scaleValue and scaleValue:IsA("NumberValue") then
		TweenService:Create(scaleValue, TWEEN_INFO, { Value = targetScale }):Play()
	end
end

-- Called by RelicRenderController when a Relic / RelicMachine prompt is
-- shown / hidden so the gear-drop side dims in lockstep with relic
-- hover. When `active` is true: dim every gear drop the local player
-- owns (no model to skip — no gear is the "hovered" one in this path).
-- When false: restore them.
--
-- One-way relationship by design — gear-drop hover is intentionally
-- minimal (highlight + scale only, see PromptShown below) so we don't
-- mirror back into the relic side. Only RELIC hover triggers the
-- cross-system dim; GEAR hover stays self-contained.
function GearDropsRenderController:SetExternalHover(active: boolean)
	-- _applyOthersDim treats `hoveredModel == nil` as "no exclusion" —
	-- the `if otherModel == hoveredModel then continue end` check is
	-- never true when hoveredModel is nil, so every owned drop gets
	-- the dim treatment. Reuses the full dim path (transparency tweens
	-- + particle brightness + AlwaysOnTop flip).
	self:_applyOthersDim(nil :: any, active)
end

-- Returns the GearDrop-tagged ancestor Model of the prompt, or nil if
-- the prompt isn't on a gear drop. Centralizes the filter so the
-- two event handlers stay symmetric.
function GearDropsRenderController:_resolveDropModelFromPrompt(prompt: ProximityPrompt): Model?
	local model = prompt:FindFirstAncestorOfClass("Model")
	if model and CollectionService:HasTag(model, TagList.GearDrop) then
		return model
	end
	return nil
end

--[ Lifecycle ]--

function GearDropsRenderController:KnitStart()
	-- Resolved here rather than at module scope: the two render
	-- controllers reference each other, so a require-time lookup would be
	-- circular.
	RelicRenderController = Knit.GetController("RelicRenderController")

	-- Single shared Highlight. Reparented between hovered drops; sits
	-- detached (Parent = nil) when nothing is hovered.
	self._highlight = Instance.new("Highlight")
	self._highlight.Name = "GearDropHighlight"
	self._highlight.FillColor = HIGHLIGHT_FILL_COLOR
	self._highlight.OutlineColor = HIGHLIGHT_OUTLINE_COLOR
	self._highlight.FillTransparency = HIGHLIGHT_FILL_TRANSPARENCY_HIDDEN
	self._highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	self._highlight.Parent = nil

	-- Gear hover is the FULL treatment now, matching a relic hover: the
	-- hovered drop lights up and everything else steps back — its own
	-- label hidden so it does not fight the prompt, other gear dimmed,
	-- and relics, runes and vending machines dimmed through
	-- RelicRenderController. The relationship is now symmetric: each
	-- side's PromptShown calls the other's SetExternalHover, and neither
	-- of those calls back, so there is no loop.
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
			self._highlight.Adornee = visualModel
			self._highlight.Parent = visualModel
			TweenService:Create(self._highlight, TWEEN_INFO, { FillTransparency = HIGHLIGHT_FILL_TRANSPARENCY_HOVERED })
				:Play()
		end

		-- Scale up the hovered drop.
		local idleScale = getGearIdleScale(model:GetAttribute(ATTR_NAME), model:GetAttribute(ATTR_TYPE))
		local hoverScale = idleScale * HOVER_SCALE_MULTIPLIER
		self:_tweenHoveredScale(model, hoverScale)

		-- The hovered drop's own label goes away while its prompt is up,
		-- the same swap the relic path makes.
		model:SetAttribute(ATTR_PROMPT_SHOWN, true)
		self:RefreshBillboardVisibility(model)

		-- Everything else steps back: other gear here, relics and runes
		-- and vending machines through the relic controller.
		self:_applyOthersDim(model, true)
		if RelicRenderController then
			RelicRenderController:SetExternalHover(true)
		end
	end)

	ProximityPromptService.PromptHidden:Connect(function(prompt: ProximityPrompt)
		local model = self:_resolveDropModelFromPrompt(prompt)
		if not model then
			return
		end

		-- Detach highlight first so a quick hover-on/hover-off cycle
		-- doesn't leave a stale outline mid-tween. Direct write
		-- (no tween) — same as RelicRenderController.
		self._highlight.FillTransparency = HIGHLIGHT_FILL_TRANSPARENCY_HIDDEN
		self._highlight.Adornee = nil
		self._highlight.Parent = nil

		-- Scale back to idle.
		local idleScale = getGearIdleScale(model:GetAttribute(ATTR_NAME), model:GetAttribute(ATTR_TYPE))
		self:_tweenHoveredScale(model, idleScale)

		-- Label back, unless something else still says otherwise — a
		-- pickup in flight, or a drop already fading out.
		model:SetAttribute(ATTR_PROMPT_SHOWN, false)
		self:RefreshBillboardVisibility(model)
		self:_applyOthersDim(model, false)
		if RelicRenderController then
			RelicRenderController:SetExternalHover(false)
		end
	end)
end

function GearDropsRenderController:KnitInit() end

return GearDropsRenderController
