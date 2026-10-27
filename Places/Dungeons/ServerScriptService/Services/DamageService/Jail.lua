--!strict
--[[
	Module: Server/Services/DamageService/Jail.lua
	Description:
	Portable Justice on-hit module. Fired by DamageService:_postDamage
	after EVERY damage instance -- weapon, arcane, relic bursts and DoT
	ticks ("All damage", 2026-10-25). Rolls per-mob jail
	chance and, on success, locks the mob's Jailed attribute on for
	JAIL_DURATION. MobBase's _resyncWalkSpeed listener freezes
	movement; the attack-pipeline gates added in MobBase / MobService
	stop any in-flight attack from connecting while Jailed.

	Chance:
	  Normal / Elite : the relic's data.jailChance (20%)
	  Miniboss/Boss  : IMMUNE — cannot be Jailed at all, per the relic
	                   text ("Jail Non-boss enemies"). The old reduced
	                   5% boss rate is gone; encounter pacing is now
	                   protected outright rather than by a lower roll.

	Gates (in order — first failure short-circuits):
	  * relic not owned    — relic presence flag from RelicService.
	  * already Jailed     — no re-stacking the timer.
	  * SuperArmor true    — windup / unique attacks claim SuperArmor,
	                         which also blocks Jail (consistent with
	                         the rest of the CC stack).
	  * Ragdolled          — already locked out via knockback.
	  * Health <= 0        — dead.
	  * CCDebounce true    — the per-enemy cooldown, counted from the
	                         moment it is Jailed, so the same mob can't
	                         be re-jailed back-to-back.

	The chance, the lockout and the cooldown are the relic's `data`
	(RelicData owns the card's numbers).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local RelicService = require(ServerScriptService.Services.RelicService)
local RelicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicData)
local RelicNetwork = require(ServerScriptService.Submodules.Core.Source.Network.Relic)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local isEncounterEnemy = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Mob.isEncounterEnemy)
local ValueNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ValueNames)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)

-- One of Portable Justice's `data` numbers, or the fallback.
local function justiceData(field: string, fallback: number): number
	local row = RelicData[RelicNames["Portable Justice"]]
	local value = row and row.data and row.data[field]
	return if type(value) == "number" then value else fallback
end

return function(player: Player, humanoid: Humanoid)
	-- Relic ownership check. Reads the count rather than the callback,
	-- which returns a bare 1 (the relic's old +25% Weapon Damage half left
	-- with its rework -- Jail is now its whole effect).
	if (RelicService:GetSpecificRelicRegistry(player, RelicNames["Portable Justice"]) or 0) <= 0 then
		return
	end

	local mobModel = humanoid.Parent :: Model?
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

	local ragdollTrigger = mobModel:FindFirstChild(ValueNames.RagdollTrigger) :: BoolValue?
	if ragdollTrigger and ragdollTrigger.Value == true then
		return
	end

	-- Minibosses and Bosses are Jail-IMMUNE per the relic text (shared
	-- Functions/Mob/isEncounterEnemy: the EnemyType attribute MobBase stamps).
	if isEncounterEnemy(mobModel) then
		return
	end

	if math.random() > justiceData("jailChance", 0.20) then
		return
	end
	local jailSeconds = justiceData("jailSeconds", 3)
	-- The card's cooldown counts from the Jail itself; the lockout is part
	-- of it, so the debounce left after release is the remainder.
	local debounceSeconds = math.max(justiceData("cooldownSeconds", 5) - jailSeconds, 0)

	-- Proc'd. Lock Jailed on for jailSeconds, then release and
	-- start the CCDebounce cooldown before the same mob can be jailed
	-- again. MobBase listens on Jailed's AttributeChangedSignal and
	-- zeroes WalkSpeed; the attack-pipeline gates (MobBase:_runAttack,
	-- MobService._runHitDetection, MobBase:_runRangedSwing) read
	-- the attribute mid-attack to cancel any in-flight swing.
	mobModel:SetAttribute(Attributes.Jailed, true)
	mobModel:SetAttribute(Attributes.CCDebounce, true)

	RelicNetwork.JailEffect.FireAll(mobModel)

	task.delay(jailSeconds, function()
		if mobModel.Parent then
			mobModel:SetAttribute(Attributes.Jailed, false)
		end

		task.delay(debounceSeconds, function()
			if mobModel.Parent then
				mobModel:SetAttribute(Attributes.CCDebounce, false)
			end
		end)
	end)
end
