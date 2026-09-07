--[[
	Module: AuraServer/Frostburst.lua
	Description:
	Frostburst (Frost): +30% Magic Damage while up (AuraData owns the
	magnitude; the AuraDamage module reads the marker).

	CUSTOM rig, per the design call: every ParticleEmitter authored under
	GameAssets.Auras.Frostburst is cloned into EVERY BasePart of the
	character EXCEPT the HumanoidRootPart and the CharacterHitbox (the
	invisible collision part — particles hanging off it float detached
	from the visible body). Same body-coverage recipe as Blighted.

	This is also why Frostburst can't ride GenericAura: its asset is bare
	emitters in a Folder, and a Folder parented to the HRP renders nothing
	(ParticleEmitters only draw under a BasePart or Attachment).

	The MARKER is a bare Attachment named "Frostburst" on the HRP — the
	visuals live on body parts, but every consumer gates on the HRP child
	name, so the marker must sit there regardless.
]]

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local AuraNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.AuraNames)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local vfxFade = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.vfxFade)

local TextIndicatorService
local RelicService

Knit.OnStart():andThen(function()
	TextIndicatorService = Knit.GetService("TextIndicatorService")
	RelicService = Knit.GetService("RelicService")
end)

local EXPIRY_ATTRIBUTE = "AuraExpiresAt"
local FALLBACK_DURATION = 5
-- MINIMUM fade grace; stretched to the longest authored particle Lifetime
-- at expiry so nothing gets destroyed mid-flight.
local FADE_SECONDS = 1

-- Staff of Azure Ever Ice's HIDDEN effect: while its owner is Frostburst,
-- a glyph rig (GameAssets.VFX.StaffofAzureIceGlyph) rides their back,
-- welded to the HRP. Undocumented in the relic card by design.
local GLYPH_ASSET_NAME = "StaffofAzureIceGlyph"
local GLYPH_CLONE_NAME = "AzureIceGlyph"
local GLYPH_FADE_IN_SECONDS = 0.4
local GLYPH_FADE_OUT_SECONDS = 1

-- Name stamped on every visual clone so expiry can sweep them without
-- tracking tables that could leak across respawns.
local FX_NAME = "FrostburstFX"

-- Builds, welds and blooms the glyph onto the character. Returns the rig
-- and its fade targets, or nil when the asset is missing.
local function spawnGlyph(character: Model, hrp: BasePart): (Model?, { vfxFade.FadeTarget }?)
	local vfxFolder = ReplicatedStorage.GameAssets:FindFirstChild("VFX")
	local template = vfxFolder and vfxFolder:FindFirstChild(GLYPH_ASSET_NAME)
	if not template or not template:IsA("Model") or not template.PrimaryPart then
		warn("[Frostburst] Missing GameAssets.VFX." .. GLYPH_ASSET_NAME .. " (Model with a PrimaryPart)")
		return nil, nil
	end

	local glyph = template:Clone()
	glyph.Name = GLYPH_CLONE_NAME

	-- Snap the PrimaryPart onto the HRP (the asset is authored around its
	-- own pivot), then weld EVERY part: the secondaries to the PrimaryPart
	-- so the rig stays rigid, the PrimaryPart to the HRP so the whole thing
	-- follows the character. Physics-neutral — massless, no collision.
	glyph:PivotTo(hrp.CFrame)
	for _, part in glyph:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = false
			part.Massless = true
			part.CanCollide = false
			part.CanQuery = false
			if part ~= glyph.PrimaryPart then
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = glyph.PrimaryPart
				weld.Part1 = part
				weld.Parent = part
			end
		end
	end
	local rootWeld = Instance.new("WeldConstraint")
	rootWeld.Part0 = hrp
	rootWeld.Part1 = glyph.PrimaryPart
	rootWeld.Parent = glyph.PrimaryPart

	-- Invisible BEFORE parenting, then bloom in — particles, beams and
	-- lights all ride the same alpha (vfxFade).
	local fadeTargets = vfxFade.capture(glyph)
	vfxFade.apply(fadeTargets, 0)
	glyph.Parent = character
	task.spawn(vfxFade.run, fadeTargets, 0, 1, GLYPH_FADE_IN_SECONDS)

	return glyph, fadeTargets
end

local function awaitExpiry(marker: Instance)
	while marker.Parent do
		local remaining = (marker:GetAttribute(EXPIRY_ATTRIBUTE) or 0) - os.clock()
		if remaining <= 0 then
			return
		end
		task.wait(remaining)
	end
end

return function(player: Player, character: Model, duration: number?)
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not hrp or hrp:FindFirstChild(AuraNames.Frostburst) ~= nil then
		return
	end

	local auraTemplate = ReplicatedStorage.GameAssets.Auras:FindFirstChild(AuraNames.Frostburst)
	if not auraTemplate then
		warn("[Frostburst] Missing GameAssets.Auras.Frostburst")
		return
	end

	-- Every authored emitter, whatever the folder structure holds.
	local emitterTemplates: { ParticleEmitter } = {}
	if auraTemplate:IsA("ParticleEmitter") then
		table.insert(emitterTemplates, auraTemplate)
	end
	for _, descendant in auraTemplate:GetDescendants() do
		if descendant:IsA("ParticleEmitter") then
			table.insert(emitterTemplates, descendant)
		end
	end
	if #emitterTemplates == 0 then
		warn("[Frostburst] GameAssets.Auras.Frostburst holds no ParticleEmitters")
		return
	end

	-- Body coverage: every BasePart except the HRP and the CharacterHitbox.
	local clones: { ParticleEmitter } = {}
	for _, part in character:GetChildren() do
		if part:IsA("BasePart") and part ~= hrp and part.Name ~= "CharacterHitbox" then
			for _, template in emitterTemplates do
				local clone = template:Clone()
				clone.Name = FX_NAME
				clone.Enabled = true
				clone.Parent = part
				table.insert(clones, clone)
				clone:Emit(2)
			end
		end
	end

	task.delay(math.random(1, 15) / 100, function()
		if TextIndicatorService and character:FindFirstChild("Head") then
			TextIndicatorService:ShowIndicator(
				player,
				character.Head,
				AuraNames.Frostburst .. "!",
				Color3.fromRGB(255, 255, 255)
			)
		end
	end)

	-- The marker: a bare Attachment on the HRP carrying the deadline.
	local marker = Instance.new("Attachment")
	marker.Name = AuraNames.Frostburst
	marker.Parent = hrp
	marker:SetAttribute(EXPIRY_ATTRIBUTE, os.clock() + (duration or FALLBACK_DURATION))

	-- Azure glyph: only for Staff of Azure Ever Ice owners. Checked at
	-- GRANT — a mid-aura relic change neither adds nor removes it.
	local glyph: Model? = nil
	local glyphFadeTargets: { vfxFade.FadeTarget }? = nil
	if
		RelicService
		and (RelicService:GetSpecificRelicRegistry(player, RelicNames["Staff of Azure Ever Ice"]) or 0) > 0
	then
		glyph, glyphFadeTargets = spawnGlyph(character, hrp)
	end

	task.spawn(function()
		awaitExpiry(marker)
		if not marker.Parent then
			-- Character died/despawned mid-window: the clones died with the
			-- body parts, nothing to sweep.
			return
		end

		-- Rename BEFORE the fade grace so a re-grant takes the fresh path.
		marker.Name = AuraNames.Frostburst .. "Fading"
		local grace = FADE_SECONDS
		for _, clone in clones do
			if clone.Parent then
				clone.Enabled = false
				grace = math.max(grace, clone.Lifetime.Max)
			end
		end

		-- The glyph expires WITH the aura: emitters off, then the whole rig
		-- (beams and lights included) breathes out on one alpha.
		if glyph and glyph.Parent and glyphFadeTargets then
			local dyingGlyph, dyingTargets = glyph, glyphFadeTargets
			task.spawn(function()
				vfxFade.disableEmitters(dyingTargets)
				vfxFade.run(dyingTargets, 1, 0, GLYPH_FADE_OUT_SECONDS)
				dyingGlyph:Destroy()
			end)
		end

		task.delay(grace, function()
			for _, clone in clones do
				clone:Destroy()
			end
		end)
		Debris:AddItem(marker, grace)
	end)
end
