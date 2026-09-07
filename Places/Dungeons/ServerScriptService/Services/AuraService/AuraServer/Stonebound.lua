--[[
	Module: AuraServer/Stonebound.lua
	Description:
	Stonebound (Earth): +10% Damage and +10% Damage Reduction for its
	holder, enlargeable by the OWNER's relics (payload arrives computed
	from AuraService). ONE instance per target across owners — the
	replace-if-stronger decision already happened in SetAura before this
	module runs.

	CUSTOM rig, per the authored asset (GameAssets.Auras.Stonebound):
	  * "Main" (Attachment)       -> cloned under the Torso.
	  * "EachBodyPart" (particle) -> cloned into every BasePart EXCEPT the
	    HumanoidRootPart and the CharacterHitbox.
	  * "Model"                   -> cloned, its PrimaryPart welded to the
	    HRP, centred on it and rotated 90 on Z (the spinning-ring rig; its
	    own constraints drive the motion).

	FADING: the rig FADES onto the character on grant and fades away on
	expiry rather than popping. The asset mixes ParticleEmitters, Trails,
	Beams (all NumberSequence transparency — not tweenable) and BaseParts
	(float transparency), so the fade captures every element's AUTHORED
	transparency at clone time and lerps the whole set between invisible
	and authored by rebuilding the sequences per step. Replacement by a
	stronger Stonebound gets a fast fade instead of an instant pop.

	The MARKER is a bare Attachment named "Stonebound" on the HRP carrying
	the deadline AND the payload attributes (StoneboundDamageBonus /
	StoneboundDamageReduction / StoneboundOwnerId) — replicated, so the
	damage pipeline and any client UI read them straight off the marker.
]]

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local AuraNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.AuraNames)

local TextIndicatorService

Knit.OnStart():andThen(function()
	TextIndicatorService = Knit.GetService("TextIndicatorService")
end)

local EXPIRY_ATTRIBUTE = "AuraExpiresAt"
local STONEBOUND_DAMAGE_ATTRIBUTE = "StoneboundDamageBonus"
local STONEBOUND_REDUCTION_ATTRIBUTE = "StoneboundDamageReduction"
local STONEBOUND_OWNER_ATTRIBUTE = "StoneboundOwnerId"
local FALLBACK_DURATION = 5

-- Fade timings: the grant blooms in quickly (it should read as a proc, not
-- a slow reveal); expiry breathes out over a full second; a replacement's
-- old rig gets a fast fade so the stronger rig visibly takes over.
local FADE_IN_SECONDS = 0.4
local FADE_OUT_SECONDS = 1
local REPLACEMENT_FADE_SECONDS = 0.25

local FX_NAME = "StoneboundFX"
local MODEL_NAME = "StoneboundModel"

-- Polls in SHORT steps rather than one long wait: a stronger application
-- replaces this aura by destroying its marker outright, and the rig sweep
-- below must notice that within a beat — a full-duration task.wait would
-- leave two rigs overlapping until the original deadline.
local REPLACEMENT_POLL_SECONDS = 0.25

local function awaitExpiry(marker: Instance)
	while marker.Parent do
		local remaining = (marker:GetAttribute(EXPIRY_ATTRIBUTE) or 0) - os.clock()
		if remaining <= 0 then
			return
		end
		task.wait(math.min(remaining, REPLACEMENT_POLL_SECONDS))
	end
end

--[ Fade machinery ]--

-- One captured element: the instance plus its AUTHORED transparency, so
-- alpha 1 always lands exactly on what was built in Studio.
--   ParticleEmitter / Trail / Beam -> NumberSequence
--   BasePart                       -> number
type FadeTarget = { instance: Instance, sequence: NumberSequence?, number: number? }

local function collectFadeTargets(root: Instance, targets: { FadeTarget })
	local function capture(instance: Instance)
		if instance:IsA("ParticleEmitter") or instance:IsA("Trail") or instance:IsA("Beam") then
			table.insert(targets, { instance = instance, sequence = instance.Transparency })
		elseif instance:IsA("BasePart") then
			table.insert(targets, { instance = instance, number = instance.Transparency })
		end
	end
	capture(root)
	for _, descendant in root:GetDescendants() do
		capture(descendant)
	end
end

-- alpha 0 = fully invisible, alpha 1 = exactly as authored. Sequences are
-- rebuilt per step (NumberSequence isn't tweenable); every keypoint is
-- dragged toward transparency 1, which preserves a multi-stop gradient's
-- SHAPE instead of flattening it.
local function applyFadeAlpha(targets: { FadeTarget }, alpha: number)
	for _, target in targets do
		local instance = target.instance
		if not instance.Parent then
			continue
		end
		if target.sequence then
			local keypoints = {}
			for index, keypoint in target.sequence.Keypoints do
				keypoints[index] = NumberSequenceKeypoint.new(
					keypoint.Time,
					1 - (1 - keypoint.Value) * alpha,
					keypoint.Envelope * alpha
				)
			end
			(instance :: ParticleEmitter).Transparency = NumberSequence.new(keypoints)
		elseif target.number ~= nil then
			(instance :: BasePart).Transparency = 1 - (1 - target.number) * alpha
		end
	end
end

-- Steps the whole set from `fromAlpha` to `toAlpha` over `duration`.
-- Frame-stepped on the server heartbeat — the rig is a handful of
-- elements, so the per-step sequence rebuilds are cheap.
local function fade(targets: { FadeTarget }, fromAlpha: number, toAlpha: number, duration: number)
	applyFadeAlpha(targets, fromAlpha)
	local elapsed = 0
	while elapsed < duration do
		elapsed += task.wait()
		local progress = math.clamp(elapsed / duration, 0, 1)
		applyFadeAlpha(targets, fromAlpha + (toAlpha - fromAlpha) * progress)
	end
	applyFadeAlpha(targets, toAlpha)
end

type Payload = { ownerId: number, damageBonus: number, damageReduction: number }

return function(player: Player, character: Model, duration: number?, payload: Payload)
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not hrp or hrp:FindFirstChild(AuraNames.Stonebound) ~= nil then
		return
	end

	local auraTemplate = ReplicatedStorage.GameAssets.Auras:FindFirstChild(AuraNames.Stonebound)
	if not auraTemplate then
		warn("[Stonebound] Missing GameAssets.Auras.Stonebound")
		return
	end

	local cleanupInstances: { Instance } = {}
	local fadeTargets: { FadeTarget } = {}

	-- Main attachment -> Torso (UpperTorso on R15).
	local torso = character:FindFirstChild("Torso") or character:FindFirstChild("UpperTorso")
	local mainTemplate = auraTemplate:FindFirstChild("Main")
	if mainTemplate and torso and torso:IsA("BasePart") then
		local mainClone = mainTemplate:Clone()
		mainClone.Name = FX_NAME
		collectFadeTargets(mainClone, fadeTargets)
		mainClone.Parent = torso
		table.insert(cleanupInstances, mainClone)
	elseif not mainTemplate then
		warn("[Stonebound] Missing GameAssets.Auras.Stonebound.Main")
	end

	-- EachBodyPart particle -> every BasePart except the HRP and the
	-- CharacterHitbox (an invisible collision part — particles hanging off
	-- it float detached from the visible body).
	local bodyTemplate = auraTemplate:FindFirstChild("EachBodyPart")
	if bodyTemplate then
		for _, part in character:GetChildren() do
			if part:IsA("BasePart") and part ~= hrp and part.Name ~= "CharacterHitbox" then
				local clone = bodyTemplate:Clone()
				clone.Name = FX_NAME
				if clone:IsA("ParticleEmitter") then
					clone.Enabled = true
				end
				collectFadeTargets(clone, fadeTargets)
				clone.Parent = part
				table.insert(cleanupInstances, clone)
			end
		end
	else
		warn("[Stonebound] Missing GameAssets.Auras.Stonebound.EachBodyPart")
	end

	-- The spinning-ring model, welded to the HRP and centred on it. Parts
	-- must not collide or the ring would shove the character around.
	local modelTemplate = auraTemplate:FindFirstChild("Model")
	if modelTemplate and modelTemplate:IsA("Model") and modelTemplate.PrimaryPart then
		local modelClone = modelTemplate:Clone()
		modelClone.Name = MODEL_NAME
		for _, part in modelClone:GetDescendants() do
			if part:IsA("BasePart") then
				part.CanCollide = false
				part.CanQuery = false
				part.CanTouch = false
				part.Massless = true
			end
		end
		-- Centred on the HRP, rotated 90 degrees on Z so the ring rig sits in
		-- its intended orientation (the asset is authored lying flat).
		modelClone:PivotTo(hrp.CFrame * CFrame.Angles(0, 0, math.rad(90)))

		local weld = Instance.new("WeldConstraint")
		weld.Part0 = modelClone.PrimaryPart
		weld.Part1 = hrp
		weld.Parent = modelClone.PrimaryPart

		collectFadeTargets(modelClone, fadeTargets)
		modelClone.Parent = character
		table.insert(cleanupInstances, modelClone)
	elseif modelTemplate then
		warn("[Stonebound] GameAssets.Auras.Stonebound.Model needs a PrimaryPart to weld")
	end

	-- Everything spawns INVISIBLE (alpha 0 applied before this frame
	-- renders) and blooms in — the fade, not a pop.
	applyFadeAlpha(fadeTargets, 0)
	task.spawn(fade, fadeTargets, 0, 1, FADE_IN_SECONDS)

	-- Fresh-grant pop, same beat as every other aura (small random delay so
	-- simultaneous procs stagger instead of stacking on one pixel).
	task.delay(math.random(1, 15) / 100, function()
		if TextIndicatorService and character:FindFirstChild("Head") then
			TextIndicatorService:ShowIndicator(
				player,
				character.Head,
				AuraNames.Stonebound .. "!",
				Color3.fromRGB(255, 255, 255)
			)
		end
	end)

	-- The marker: deadline + payload, all replicated attributes.
	local marker = Instance.new("Attachment")
	marker.Name = AuraNames.Stonebound
	marker:SetAttribute(EXPIRY_ATTRIBUTE, os.clock() + (duration or FALLBACK_DURATION))
	marker:SetAttribute(STONEBOUND_DAMAGE_ATTRIBUTE, payload.damageBonus)
	marker:SetAttribute(STONEBOUND_REDUCTION_ATTRIBUTE, payload.damageReduction)
	marker:SetAttribute(STONEBOUND_OWNER_ATTRIBUTE, payload.ownerId)
	marker.Parent = hrp

	task.spawn(function()
		awaitExpiry(marker)

		local function destroyRig()
			for _, instance in cleanupInstances do
				instance:Destroy()
			end
		end

		if not marker.Parent then
			-- Replaced by a stronger application (SetAura destroys the
			-- marker outright) or the character died. Fast fade rather than
			-- an instant pop — the replacement's own bloom-in overlaps it,
			-- reading as one rig handing over to the next.
			fade(fadeTargets, 1, 0, REPLACEMENT_FADE_SECONDS)
			destroyRig()
			return
		end

		-- Rename BEFORE the fade grace so a re-grant takes the fresh path.
		marker.Name = AuraNames.Stonebound .. "Fading"
		Debris:AddItem(marker, FADE_OUT_SECONDS)

		-- Stop NEW particles immediately, then breathe the whole rig out —
		-- trails, beams and parts fade in lockstep while in-flight
		-- particles thin away with the falling emitter transparency.
		for _, target in fadeTargets do
			if target.instance:IsA("ParticleEmitter") and target.instance.Parent then
				target.instance.Enabled = false
			end
		end
		fade(fadeTargets, 1, 0, FADE_OUT_SECONDS)
		destroyRig()
	end)
end
