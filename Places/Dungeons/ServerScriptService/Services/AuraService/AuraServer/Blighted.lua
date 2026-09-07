--[[
	Module: AuraServer/Blighted.lua
	Description:
	Blighted (Venom): +15% Status Chance while up (AuraData owns the
	magnitude; StatusConditionService reads the marker).

	CUSTOM rig, per the authored asset (GameAssets.Auras.Blighted holds
	five particles):
	  * Flame1 / Flame2 / Glow  -> cloned into EVERY BasePart of the
	    character EXCEPT the HumanoidRootPart and the CharacterHitbox.
	  * TorsoBlight1 / TorsoBlight2 -> cloned into the Torso only
	    (UpperTorso on R15 rigs).

	The MARKER is a bare Attachment named "Blighted" on the HRP — the
	visuals live on body parts, but every consumer gates on the HRP child
	name, so the marker must sit there regardless. All clones are named
	after the marker's fading name so the cleanup sweep can find them.
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
local FALLBACK_DURATION = 5
local FADE_SECONDS = 1

-- Name stamped on every visual clone so expiry can sweep them without
-- tracking tables that could leak across respawns.
local FX_NAME = "BlightedFX"

local BODY_PARTICLES = { "Flame1", "Flame2", "Glow" }
local TORSO_PARTICLES = { "TorsoBlight1", "TorsoBlight2" }

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
	if not hrp or hrp:FindFirstChild(AuraNames.Blighted) ~= nil then
		return
	end

	local auraTemplate = ReplicatedStorage.GameAssets.Auras:FindFirstChild(AuraNames.Blighted)
	if not auraTemplate then
		warn("[Blighted] Missing GameAssets.Auras.Blighted")
		return
	end

	local clones: { ParticleEmitter } = {}
	local function cloneInto(particleName: string, parent: BasePart)
		local template = auraTemplate:FindFirstChild(particleName)
		if not template then
			warn("[Blighted] Missing GameAssets.Auras.Blighted." .. particleName)
			return
		end
		local clone = template:Clone()
		clone.Name = FX_NAME
		clone.Enabled = true
		clone.Parent = parent
		table.insert(clones, clone)
	end

	-- Body coverage: every BasePart except the HRP (the design call —
	-- "HRP does not count since we are doing Torso") and the
	-- CharacterHitbox, an invisible collision part whose particles would
	-- float detached from the visible body. Same exclusions as Stonebound
	-- and Frostburst.
	for _, part in character:GetChildren() do
		if part:IsA("BasePart") and part ~= hrp and part.Name ~= "CharacterHitbox" then
			for _, particleName in BODY_PARTICLES do
				cloneInto(particleName, part)
			end
		end
	end

	local torso = character:FindFirstChild("Torso") or character:FindFirstChild("UpperTorso")
	if torso and torso:IsA("BasePart") then
		for _, particleName in TORSO_PARTICLES do
			cloneInto(particleName, torso)
		end
	end

	-- Fresh-grant pop, same beat as every other aura (small random delay so
	-- simultaneous procs stagger instead of stacking on one pixel).
	task.delay(math.random(1, 15) / 100, function()
		if TextIndicatorService and character:FindFirstChild("Head") then
			TextIndicatorService:ShowIndicator(
				player,
				character.Head,
				AuraNames.Blighted .. "!",
				Color3.fromRGB(255, 255, 255)
			)
		end
	end)

	-- The marker: a bare Attachment on the HRP carrying the deadline.
	local marker = Instance.new("Attachment")
	marker.Name = AuraNames.Blighted
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
		marker.Name = AuraNames.Blighted .. "Fading"
		for _, clone in clones do
			if clone.Parent then
				clone.Enabled = false
			end
		end

		task.delay(FADE_SECONDS, function()
			for _, clone in clones do
				clone:Destroy()
			end
		end)
		Debris:AddItem(marker, FADE_SECONDS)
	end)
end
