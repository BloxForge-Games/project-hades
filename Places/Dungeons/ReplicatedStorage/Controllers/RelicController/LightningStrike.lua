--[[
	Module: Client/Controllers/RelicController/LightningStrike.lua
	Description:
	Throwing Bolts (Epic) — the Lightning Strike that lands when a Critical
	Hit connects with a Shocked enemy.

	The VFX is a duplicate of the "Lighting Shatter" magic spell's model
	(GroundImpact / Impact / Lightning / Starter, same child names), scaled
	down and recoloured purple, so this plays it with the SAME emit cadence,
	sounds and cleanup as Client/Controllers/VFXController/LightingShatter —
	keep the two in step if that spell's timing is ever retuned.

	One deliberate difference: no radialGroundFracture call. The spell
	cracks the floor beneath it; the relic's strike is much smaller and the
	debris read as noise at this scale.

	Server fires RelicService.Client.OnLightningStrikeActivated:FireAll, so
	every client renders the strike — including dead players spectating.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

local LightningStrike = {}
LightningStrike.__index = LightningStrike

-- Matches LightingShatter's cadence exactly.
local STARTER_EMIT = 15
local BODY_EMIT = 15
local IMPACT_EMIT = 10
local BODY_EMIT_DELAY = 0.1
local CLEANUP_SECONDS = 5

function LightningStrike.new(position: Vector3)
	local self = setmetatable({}, LightningStrike)
	self.position = position
	return self
end

function LightningStrike:PlayEffect()
	local template = ReplicatedStorage.GameAssets.VFX:FindFirstChild("LightingStrike")
	if not template then
		warn("[LightningStrike] Missing GameAssets.VFX.LightingStrike")
		return
	end

	local strike = template:Clone()
	-- Scale is baked into the asset (0.451) — don't ScaleTo here, or tuning
	-- the model in Studio stops taking effect.
	strike:PivotTo(CFrame.new(self.position))
	strike.Parent = workspace.IgnoreInstances.MagicSpells

	-- Starter first, then everything else a beat later — the two-stage burst
	-- is what makes the bolt read as descending rather than popping at once.
	for _, particle in strike.Starter:GetDescendants() do
		if particle:IsA("ParticleEmitter") then
			particle:Emit(STARTER_EMIT)
		end
	end

	task.delay(BODY_EMIT_DELAY, function()
		if not strike.Parent then
			return
		end
		for _, particle in strike:GetDescendants() do
			if particle:IsA("ParticleEmitter") and particle.Parent.Name ~= "StarterAttachment" then
				particle:Emit(if particle.Parent.Name ~= "ImpactAttachment" then BODY_EMIT else IMPACT_EMIT)
			end
		end
	end)

	local groundImpact = strike:FindFirstChild("GroundImpact")
	if groundImpact then
		local explosion = groundImpact:FindFirstChild("ElectricExplosion")
		local explosion2 = groundImpact:FindFirstChild("ElectricExplosion2")
		if explosion then
			explosion:Play()
		end
		if explosion2 then
			explosion2:Play()
		end
	end

	Debris:AddItem(strike, CLEANUP_SECONDS)
end

return LightningStrike
