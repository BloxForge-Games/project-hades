--!strict
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
	(float transparency), which is exactly what Shared/Functions/VFX/
	vfxFade handles -- and it runs on every CLIENT: the server parents the
	rig as authored and fires ONE Combat.VFXFade cue naming every piece
	(VFXFadeController). Stepping the fade here used to replicate a
	rebuilt NumberSequence per emitter per frame to every player.
	Replacement by a stronger Stonebound gets a fast fade instead of an
	instant pop.

	The MARKER is a bare Attachment named "Stonebound" on the HRP carrying
	the deadline AND the payload attributes (StoneboundDamageBonus /
	StoneboundDamageReduction / StoneboundOwnerId) — replicated, so the
	damage pipeline and any client UI read them straight off the marker.
]]

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local TextIndicatorService = require(ServerScriptService.Submodules.Core.Source.Services.TextIndicatorService)
local CombatNetwork = require(ServerScriptService.Submodules.Core.Source.Network.Combat)
local AuraNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.AuraNames)
local getRoot = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Character.getRoot)

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
		local remaining = ((marker:GetAttribute(EXPIRY_ATTRIBUTE) :: number?) or 0) - os.clock()
		if remaining <= 0 then
			return
		end
		task.wait(math.min(remaining, REPLACEMENT_POLL_SECONDS))
	end
end

--[ Fade cue ]--

-- Asks every client to fade the rig's pieces together (VFXFadeController
-- runs vfxFade on them). alpha 0 = invisible, 1 = as authored. Fired
-- AFTER the pieces are parented, so they exist on every client when the
-- cue lands; a piece destroyed in between arrives nil and is skipped.
local function cueFade(rigs: { Instance }, fromAlpha: number, toAlpha: number, duration: number)
	CombatNetwork.VFXFade.FireAll({
		Rigs = rigs,
		FromAlpha = fromAlpha,
		ToAlpha = toAlpha,
		Duration = duration,
	})
end

type Payload = { ownerId: number, damageBonus: number, damageReduction: number }

return function(player: Player, character: Model, duration: number?, payload: Payload)
	local hrp = getRoot(character)
	if not hrp or hrp:FindFirstChild(AuraNames.Stonebound) ~= nil then
		return
	end

	local auraTemplate = ReplicatedStorage.GameAssets.Auras:FindFirstChild(AuraNames.Stonebound)
	if not auraTemplate then
		warn("[Stonebound] Missing GameAssets.Auras.Stonebound")
		return
	end

	-- Every piece of the rig: what expiry destroys, and what the fade cue
	-- names.
	local cleanupInstances: { Instance } = {}

	-- Main attachment -> Torso (UpperTorso on R15).
	local torso = character:FindFirstChild("Torso") or character:FindFirstChild("UpperTorso")
	local mainTemplate = auraTemplate:FindFirstChild("Main")
	if mainTemplate and torso and torso:IsA("BasePart") then
		local mainClone = mainTemplate:Clone()
		mainClone.Name = FX_NAME
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

		modelClone.Parent = character
		table.insert(cleanupInstances, modelClone)
	elseif modelTemplate then
		warn("[Stonebound] GameAssets.Auras.Stonebound.Model needs a PrimaryPart to weld")
	end

	-- Everything blooms in on every client — the fade, not a pop. The cue
	-- goes out in the same frame as the parenting above, so each client
	-- snaps the pieces to alpha 0 before it renders them.
	cueFade(cleanupInstances, 0, 1, FADE_IN_SECONDS)

	-- Fresh-grant pop, same beat as every other aura (small random delay so
	-- simultaneous procs stagger instead of stacking on one pixel).
	task.delay(math.random(1, 15) / 100, function()
		local head = character:FindFirstChild("Head") :: BasePart?
		if TextIndicatorService and head then
			TextIndicatorService:ShowIndicator(player, head, AuraNames.Stonebound .. "!", Color3.fromRGB(255, 255, 255))
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
			cueFade(cleanupInstances, 1, 0, REPLACEMENT_FADE_SECONDS)
			task.wait(REPLACEMENT_FADE_SECONDS)
			destroyRig()
			return
		end

		-- Rename BEFORE the fade grace so a re-grant takes the fresh path.
		marker.Name = AuraNames.Stonebound .. "Fading"
		Debris:AddItem(marker, FADE_OUT_SECONDS)

		-- Stop NEW particles immediately (one replicated bool each), then
		-- breathe the whole rig out on every client — trails, beams and
		-- parts fade in lockstep while in-flight particles thin away with
		-- the falling emitter transparency.
		for _, instance in cleanupInstances do
			if instance:IsA("ParticleEmitter") and instance.Parent then
				instance.Enabled = false
			end
			for _, descendant in instance:GetDescendants() do
				if descendant:IsA("ParticleEmitter") then
					descendant.Enabled = false
				end
			end
		end
		cueFade(cleanupInstances, 1, 0, FADE_OUT_SECONDS)
		task.wait(FADE_OUT_SECONDS)
		destroyRig()
	end)
end
