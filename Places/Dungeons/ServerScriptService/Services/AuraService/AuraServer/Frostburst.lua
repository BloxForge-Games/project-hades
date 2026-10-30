--!strict
--[[
	Module: AuraServer/Frostburst.lua
	Description:
	Frostburst (Frost): more Magic Damage while up (AuraData owns the
	magnitude -- 0.30 after the 2026-10 shift; the AuraDamage module reads the marker).

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

	(Staff of Azure Ever Ice's Ice Glyph rode this aura until 2026-10-29;
	it is worn at all times now, RelicGimmickService/Lib/azureGlyph.)
]]

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local TextIndicatorService = require(ServerScriptService.Submodules.Core.Source.Services.TextIndicatorService)
local AuraNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.AuraNames)
local getRoot = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Character.getRoot)

local EXPIRY_ATTRIBUTE = "AuraExpiresAt"
local FALLBACK_DURATION = 5
-- MINIMUM fade grace; stretched to the longest authored particle Lifetime
-- at expiry so nothing gets destroyed mid-flight.
local FADE_SECONDS = 1

-- Name stamped on every visual clone so expiry can sweep them without
-- tracking tables that could leak across respawns.
local FX_NAME = "FrostburstFX"

local function awaitExpiry(marker: Instance)
	while marker.Parent do
		local remaining = ((marker:GetAttribute(EXPIRY_ATTRIBUTE) :: number?) or 0) - os.clock()
		if remaining <= 0 then
			return
		end
		task.wait(remaining)
	end
end

return function(player: Player, character: Model, duration: number?)
	local hrp = getRoot(character)
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
		local head = character:FindFirstChild("Head") :: BasePart?
		if TextIndicatorService and head then
			TextIndicatorService:ShowIndicator(player, head, AuraNames.Frostburst .. "!", Color3.fromRGB(255, 255, 255))
		end
	end)

	-- The marker: a bare Attachment on the HRP carrying the deadline.
	local marker = Instance.new("Attachment")
	marker.Name = AuraNames.Frostburst
	marker.Parent = hrp
	marker:SetAttribute(EXPIRY_ATTRIBUTE, os.clock() + (duration or FALLBACK_DURATION))

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

		task.delay(grace, function()
			for _, clone in clones do
				clone:Destroy()
			end
		end)
		Debris:AddItem(marker, grace)
	end)
end
