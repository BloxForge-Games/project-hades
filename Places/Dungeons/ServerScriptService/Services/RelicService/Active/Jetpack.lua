local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local HumanoidProperties = require(ReplicatedStorage.Submodules.Core.Shared.Data.HumanoidProperties)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)

local RelicService
local WeldConstraintService
local TextIndicatorService
local InvulnerabilityService

Knit.OnStart():andThen(function()
	RelicService = Knit.GetService("RelicService")
	WeldConstraintService = Knit.GetService("WeldConstraintService")
	TextIndicatorService = Knit.GetService("TextIndicatorService")
	InvulnerabilityService = Knit.GetService("InvulnerabilityService")
end)

local Jetpack = {}
Jetpack.__index = Jetpack

function Jetpack.new(player: Player)
	local self = setmetatable({}, Jetpack)
	self._player = player

	return self
end

function Jetpack:Invoke()
	local character = self._player.Character

	if not character or character:FindFirstChild(RelicNames["Experimental Jetpack"]) then
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")

	if not humanoid or humanoid.Health <= 0 then
		return
	end

	local relicCount = RelicService:GetSpecificRelicRegistry(self._player, RelicNames["Experimental Jetpack"])

	if relicCount == 0 then
		return
	end

	character:SetAttribute(Attributes.JetpackOnCooldown, true)

	if character:FindFirstChild("DodgeIndicator") then
		character:FindFirstChild("DodgeIndicator"):Destroy()
	end

	-- Invulnerability + highlight lifecycle is owned by InvulnerabilityService
	-- (moved out of here in Chunk C so LifeService's death-state i-frames
	-- can reuse the same pattern). Duration matches the jetpack flight
	-- length so the i-frames lift exactly when the jetpack does.
	InvulnerabilityService:ApplyTo(
		character,
		RelicService:GetRelicEffect(self._player, RelicNames["Experimental Jetpack"])
	)

	local jetpackClone = ReplicatedStorage.GameAssets.Relics.Actives[RelicNames["Experimental Jetpack"]]:Clone()

	jetpackClone.Handle.ThrusterAttachment1.Fire.Enabled = true
	jetpackClone.Handle.ThrusterAttachment1.Smoke.Enabled = true
	jetpackClone.Handle.ThrusterAttachment2.Fire.Enabled = true
	jetpackClone.Handle.ThrusterAttachment2.Smoke.Enabled = true

	jetpackClone.Handle.InitialThrust.TimePosition = 0.05
	jetpackClone.Handle.InitialThrust:Play()
	jetpackClone.Handle.Thrusting:Play()

	TweenService:Create(jetpackClone.Handle.Thrusting, TweenInfo.new(0.5), { Volume = 0.1 }):Play()

	jetpackClone.Handle.Transparency = 1
	jetpackClone.Parent = character

	task.delay(0.1, function()
		for _, p in pairs(jetpackClone.Handle.ActiveAttachment:GetChildren()) do
			if p:IsA("ParticleEmitter") then
				p.Enabled = false
				p:Emit(10)
			end
		end
	end)

	TweenService:Create(jetpackClone.Handle, TweenInfo.new(1), { Transparency = 0 }):Play()

	WeldConstraintService:CreateWeldConstraint(jetpackClone.Handle, character.Torso)

	-- Effective base comes from RelicService's server-side helper
	-- (baseline + Speed Coil/Astral Cloak callbacks + the WalkSpeedBonus
	-- stat attribute — Gravity Coil, Speedy Shoes, Jetpack's own +3 passive,
	-- Slateskin's gated −3 — × Adrenaline's 1.25 if active), then the
	-- jetpack multiplier scales it. Worked example, no other relics:
	--   (18 + 3 passive) × 1.5 = 31.5
	humanoid.WalkSpeed = RelicService:GetEffectiveBaseWalkSpeed(self._player)
		* HumanoidProperties.JetpackWalkSpeedMultiplier

	character:SetAttribute(Attributes.OnJetpack, true)

	TextIndicatorService:ShowIndicator(self._player, character.Head, "Experimental Jetpack!")

	task.delay(RelicService:GetRelicEffect(self._player, RelicNames["Experimental Jetpack"]), function()
		character:SetAttribute(Attributes.JetpackOnCooldown, false)

		-- Restore to effective base (NOT raw WalkSpeed) — base-walkspeed
		-- relic bonuses stay on after the jetpack ends. Drops the ×1.5
		-- multiplier but keeps the relic bonuses (and Adrenaline's
		-- ×1.25 if that buff is still running). Re-read at end-time
		-- (not captured from the start branch) so a movement-speed
		-- relic picked up MID-flight is reflected on landing.
		humanoid.WalkSpeed = RelicService:GetEffectiveBaseWalkSpeed(self._player)

		character:SetAttribute(Attributes.OnJetpack, false)
		-- Note: Attributes.Invulnerable + highlight are now cleared
		-- automatically by InvulnerabilityService's expiry timer (matched
		-- duration above) — don't double-clear here.

		TweenService:Create(jetpackClone.Handle.Thrusting, TweenInfo.new(0.5), { Volume = 0 }):Play()

		jetpackClone.Handle.ThrusterAttachment1.Fire.Enabled = false
		jetpackClone.Handle.ThrusterAttachment2.Fire.Enabled = false

		TweenService:Create(jetpackClone.Handle, TweenInfo.new(1), { Transparency = 1 }):Play()

		Debris:AddItem(jetpackClone, 2)
	end)
end

return Jetpack
