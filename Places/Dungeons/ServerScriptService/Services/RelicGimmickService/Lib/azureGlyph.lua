--!strict
--[[
	Module: RelicGimmickService/Lib/azureGlyph
	Description:
	The Ice Glyph (GameAssets.VFX.StaffofAzureIceGlyph, the asset keeps
	its old name): a rig welded to its owner's back. Korblox Mage Staff's
	since 2026-10-30, worn while Frostburst is up; Frost.onTick keeps it in
	step (added when missing, faded out and removed when it should go).
	Each client blooms it in and out through Combat.VFXFade.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local CombatNetwork = require(ServerScriptService.Submodules.Core.Source.Network.Combat)

local GLYPH_ASSET_NAME = "StaffofAzureIceGlyph"
local GLYPH_CLONE_NAME = "AzureIceGlyph"
local GLYPH_FADE_IN_SECONDS = 0.4
local GLYPH_FADE_OUT_SECONDS = 1

local azureGlyph = {}

function azureGlyph.find(character: Model): Model?
	local glyph = character:FindFirstChild(GLYPH_CLONE_NAME)
	return if glyph and glyph:IsA("Model") then glyph else nil
end

-- Builds, welds and blooms the glyph onto `character`. Nil when the asset
-- is missing.
function azureGlyph.spawn(character: Model, hrp: BasePart): Model?
	local vfxFolder = ReplicatedStorage.GameAssets:FindFirstChild("VFX")
	local template = vfxFolder and vfxFolder:FindFirstChild(GLYPH_ASSET_NAME)
	if not template or not template:IsA("Model") or not template.PrimaryPart then
		warn("[azureGlyph] Missing GameAssets.VFX." .. GLYPH_ASSET_NAME .. " (Model with a PrimaryPart)")
		return nil
	end

	local glyph = template:Clone()
	glyph.Name = GLYPH_CLONE_NAME

	-- Snap the PrimaryPart onto the HRP (the asset is authored around its
	-- own pivot), weld the secondaries to it and it to the HRP.
	-- Physics-neutral: massless, no collision.
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

	-- The fade cue goes out in the same frame as the parenting, so no
	-- client renders it at full opacity first.
	glyph.Parent = character
	CombatNetwork.VFXFade.FireAll({
		Rigs = { glyph },
		FromAlpha = 0,
		ToAlpha = 1,
		Duration = GLYPH_FADE_IN_SECONDS,
	})
	return glyph
end

-- Fades `glyph` out on every client and destroys it once that has played.
function azureGlyph.dismiss(glyph: Model)
	glyph.Name = GLYPH_CLONE_NAME .. "Fading"
	for _, descendant in glyph:GetDescendants() do
		if descendant:IsA("ParticleEmitter") then
			descendant.Enabled = false
		end
	end
	CombatNetwork.VFXFade.FireAll({
		Rigs = { glyph },
		FromAlpha = 1,
		ToAlpha = 0,
		Duration = GLYPH_FADE_OUT_SECONDS,
	})
	task.delay(GLYPH_FADE_OUT_SECONDS, function()
		glyph:Destroy()
	end)
end

return azureGlyph
