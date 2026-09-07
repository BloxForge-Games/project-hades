--[[
	Module: Server/Services/DamageService/Jail.lua
	Description:
	Portable Justice on-hit module. Fired by DamageService:TakeDamage
	for every weapon hit (skipped on magic hits). Rolls per-mob jail
	chance and, on success, locks the mob's Jailed attribute on for
	JAIL_DURATION. MobBase's _resyncWalkSpeed listener freezes
	movement; the attack-pipeline gates added in MobBase / ZombieService
	stop any in-flight attack from connecting while Jailed.

	Chance:
	  Normal / Elite : NORMAL_JAIL_CHANCE_PCT (15%)
	  Miniboss/Boss  : IMMUNE — cannot be Jailed at all, per the relic
	                   text ("Jail Non-boss enemies"). The old reduced
	                   5% boss rate is gone; encounter pacing is now
	                   protected outright rather than by a lower roll.

	Gates (in order — first failure short-circuits):
	  * isMagic            — Portable Justice is weapon-only.
	  * relic not owned    — relic presence flag from RelicService.
	  * already Jailed     — no re-stacking the timer.
	  * SuperArmor true    — windup / unique attacks claim SuperArmor,
	                         which also blocks Jail (consistent with
	                         the rest of the CC stack).
	  * Ragdolled          — already locked out via knockback.
	  * Health <= 0        — dead.
	  * CCDebounce true    — 5s post-jail cooldown so the same mob
	                         can't be re-jailed back-to-back.

	JAILED_DEBOUNCE is the post-release cooldown. JAIL_DURATION is
	the lockout itself. Both authored as constants here so a tuning
	pass lands in one place.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local EnemyTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.EnemyTypes)
local ValueNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ValueNames)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)

local RelicService

Knit.OnStart():andThen(function()
	RelicService = Knit.GetService("RelicService")
end)

local JAIL_DURATION = 3
local JAILED_DEBOUNCE = 5

-- Jail chance (percent) for a NON-BOSS enemy. Tune here.
local NORMAL_JAIL_CHANCE_PCT = 15

-- True when the mob is a Miniboss or Boss, which can never be Jailed.
-- Reads the EnemyType attribute MobBase stamps at spawn (Normal / Elite /
-- Miniboss / Boss). A missing/unknown attribute reads as NON-boss, so a
-- misconfigured ZombieData entry surfaces as "weird mob got jailed"
-- rather than "relic silently does nothing".
local function isEncounterEnemy(mobModel: Model): boolean
	local enemyType = mobModel:GetAttribute(Attributes.EnemyType)
	return enemyType == EnemyTypes.Miniboss or enemyType == EnemyTypes.Boss
end

return function(player: Player, humanoid: Humanoid, isMagic: boolean)
	if isMagic then
		return
	end

	-- Relic ownership check. Reads the registry rather than the callback,
	-- which returns a bare 1 (the relic's old +25% Weapon Damage half left
	-- with its rework -- Jail is now its whole effect). The per-type chance
	-- math lives here, not in the callback, because it needs the per-mob
	-- EnemyType attribute.
	if RelicService:GetSpecificRelicRegistry(player, RelicNames["Portable Justice"]) <= 0 then
		return
	end

	local mobModel = humanoid.Parent
	if not mobModel then
		return
	end

	if
		mobModel:GetAttribute(Attributes.Jailed) == true
		or mobModel:GetAttribute(Attributes.SuperArmor) == true
		or mobModel:GetAttribute(Attributes.CCDebounce) == true
		or humanoid.Health <= 0
	then
		return
	end

	local ragdollTrigger = mobModel:FindFirstChild(ValueNames.RagdollTrigger)
	if ragdollTrigger and ragdollTrigger.Value == true then
		return
	end

	-- Minibosses and Bosses are Jail-IMMUNE per the relic text.
	if isEncounterEnemy(mobModel) then
		return
	end

	if math.random(1, 100) > NORMAL_JAIL_CHANCE_PCT then
		return
	end

	-- Proc'd. Lock Jailed on for JAIL_DURATION, then release and
	-- start the CCDebounce cooldown before the same mob can be jailed
	-- again. MobBase listens on Jailed's AttributeChangedSignal and
	-- zeroes WalkSpeed; the attack-pipeline gates (MobBase:_runAttack,
	-- ZombieService._runHitDetection, MobBase:_runRangedSwing) read
	-- the attribute mid-attack to cancel any in-flight swing.
	mobModel:SetAttribute(Attributes.Jailed, true)
	mobModel:SetAttribute(Attributes.CCDebounce, true)

	RelicService.Client.OnJailEffectActivated:FireAll(mobModel)

	task.delay(JAIL_DURATION, function()
		if mobModel.Parent then
			mobModel:SetAttribute(Attributes.Jailed, false)
		end

		task.delay(JAILED_DEBOUNCE, function()
			if mobModel.Parent then
				mobModel:SetAttribute(Attributes.CCDebounce, false)
			end
		end)
	end)
end
