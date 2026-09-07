--[[
	Module: AuraServer/GenericAura.lua
	Description:
	Builder for the "standard-rig" auras — Enflamed, Frostburst,
	Stormcharged. Each is one call: `return GenericAura(AuraNames.X)`.

	Rig recipe (covers both authored shapes):
	  * If GameAssets.Auras.<name> has a "Main" child, ONE clone of it goes
	    under the HRP (the Frenzy-era attachment shape).
	  * Otherwise the whole folder/model is cloned under the HRP (the
	    Overcharged-era shape — Stormcharged is authored this way).
	The clone is RENAMED to the aura name: an HRP child with that Name IS
	the marker every consumer gates on.

	Lifecycle: deadline lives on the marker as "AuraExpiresAt" (poll, don't
	delay, so SetAura's extend works mid-flight); on expiry the marker is
	renamed "<name>Fading" BEFORE the 1s fade so a re-grant can't find a
	dying marker, emitters are disabled so in-flight particles finish, and
	Debris collects it.
]]

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local vfxFade = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.vfxFade)

local TextIndicatorService

Knit.OnStart():andThen(function()
	TextIndicatorService = Knit.GetService("TextIndicatorService")
end)

local EXPIRY_ATTRIBUTE = "AuraExpiresAt"
local FALLBACK_DURATION = 5
-- MINIMUM fade grace. The real grace is the longest authored particle
-- Lifetime in the rig when that is longer — destroying at a flat 1s cut
-- long-lived particles mid-flight, which read as the aura popping off.
local FADE_SECONDS = 1

-- Blocks until the marker's stamped deadline actually passes, re-reading
-- it each pass so a mid-window extension holds.
local function awaitExpiry(marker: Instance)
	while marker.Parent do
		local remaining = (marker:GetAttribute(EXPIRY_ATTRIBUTE) or 0) - os.clock()
		if remaining <= 0 then
			return
		end
		task.wait(remaining)
	end
end

-- `options.transparencyFade`: on expiry, ALSO ramp the whole rig's
-- transparency to invisible over the grace (vfxFade) instead of only
-- letting disabled emitters run dry. Emitter Transparency applies to
-- particles ALREADY ALIVE, which is exactly right on the way OUT — the
-- lingering particles thin away instead of holding full opacity until
-- they expire. Opt-in per aura.
return function(auraName: string, options: { transparencyFade: boolean? }?)
	return function(player: Player, character: Model, duration: number?)
		local hrp = character and character:FindFirstChild("HumanoidRootPart")
		if not hrp or hrp:FindFirstChild(auraName) ~= nil then
			return
		end

		local auraTemplate = ReplicatedStorage.GameAssets.Auras:FindFirstChild(auraName)
		if not auraTemplate then
			warn("[GenericAura] Missing GameAssets.Auras." .. auraName)
			return
		end

		local source = auraTemplate:FindFirstChild("Main") or auraTemplate

		-- Parent FIRST, burst SECOND — :Emit on an emitter that isn't in
		-- the workspace yet silently discards the particles.
		--
		-- Two authored shapes:
		--   * `source` is an Attachment / BasePart / Model (Enflamed's
		--     "Main", the old Overcharged model): clone it wholesale — the
		--     emitters inside keep rendering because their container does.
		--   * `source` is a FOLDER holding bare ParticleEmitters
		--     (Frostburst): a Folder under the HRP renders NOTHING — an
		--     emitter only draws under a BasePart or Attachment — so build
		--     an Attachment marker and clone the emitters INTO it instead.
		local marker: Instance
		if source:IsA("Attachment") or source:IsA("BasePart") or source:IsA("Model") then
			marker = source:Clone()
		else
			marker = Instance.new("Attachment")
			for _, descendant in source:GetDescendants() do
				if descendant:IsA("ParticleEmitter") then
					local emitter = descendant:Clone()
					emitter.Enabled = true
					emitter.Parent = marker
				end
			end
		end
		marker.Name = auraName
		marker.Parent = hrp

		for _, descendant in marker:GetDescendants() do
			if descendant:IsA("ParticleEmitter") then
				descendant:Emit(5)
			end
		end

		task.delay(math.random(1, 15) / 100, function()
			if TextIndicatorService and character:FindFirstChild("Head") then
				TextIndicatorService:ShowIndicator(
					player,
					character.Head,
					auraName .. "!",
					Color3.fromRGB(255, 255, 255)
				)
			end
		end)

		marker:SetAttribute(EXPIRY_ATTRIBUTE, os.clock() + (duration or FALLBACK_DURATION))

		task.spawn(function()
			awaitExpiry(marker)
			if not marker.Parent then
				return
			end

			-- Rename BEFORE the fade grace — see module header.
			marker.Name = auraName .. "Fading"
			local grace = FADE_SECONDS
			for _, descendant in marker:GetDescendants() do
				if descendant:IsA("ParticleEmitter") then
					descendant.Enabled = false
					grace = math.max(grace, descendant.Lifetime.Max)
				end
			end

			if options and options.transparencyFade then
				-- Capture at expiry (the rig is at authored opacity) and
				-- breathe the whole thing out across the grace. vfxFade.run
				-- yields, so the Debris timer below still owns destruction.
				local fadeTargets = vfxFade.capture(marker)
				task.spawn(vfxFade.run, fadeTargets, 1, 0, grace)
			end

			Debris:AddItem(marker, grace)
		end)
	end
end
