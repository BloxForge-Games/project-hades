--[[
	Module: Server/Services/RelicService/Incremental/SuperStompBoots.lua
	Description:
	Super Stomp Boots (redesigned) — server-side AOE stomp on dodge
	landing. Mirrors the class shape of Fireworks (.new(...) +
	:InvokeStomp()). RelicService spawns one instance per dodge-land
	event for owners and calls :InvokeStomp().

	Damage math:
	    base = 25 × PlayerLevel             (relic data callback × profile.Level)
	    routed through DamageService:TakeDamage with
	    isMagic=false, isMelee=true so weapon-damage amplifiers
	    compose (Linked Sword, Berserker's Claymore, Red Hyperlaser
	    Gun, Murder Knife, Phoenix Bow, Attack Doge, Teddy Bloxpin's
	    outgoing half) plus the standard crit / variance pipeline.

	Was previously direct `humanoid:TakeDamage(MaxHealth × fraction)`
	which bypassed the whole pipeline.

	VFX hook unchanged: fires `OnSuperStompBoots:FireAll(caster,
	landingPosition, radius, baseDamage)` AFTER damage application.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
-- Shared helper that reads the PlayerLevel attribute (ExperienceService
-- mirrors profile.Level onto it). Replaces the prior inline DataService
-- lookup so the value matches everywhere — including the relic UI's
-- runtimeDescriptionCallback.
local getPlayerLevel = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Player.getPlayerLevel)

local STOMP_RADIUS = 10 -- studs; tune via this constant

local SuperStompBoots = {}
SuperStompBoots.__index = SuperStompBoots

function SuperStompBoots.new(
	player: Player,
	damagePerLevel: number,
	landingPosition: Vector3,
	relicService: any,
	ignoreListService: any,
	damageIndicatorService: any
)
	local self = setmetatable({}, SuperStompBoots)

	self._player = player
	self._damagePerLevel = damagePerLevel
	self._landingPosition = landingPosition
	self._relicService = relicService
	self._ignoreListService = ignoreListService
	self._damageIndicatorService = damageIndicatorService

	return self
end

function SuperStompBoots:InvokeStomp()
	local character = self._player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")

	if not humanoid or humanoid.MaxHealth <= 0 then
		return
	end

	-- Player level → base damage. Reads the PlayerLevel attribute via
	-- the shared helper; falls back to the profile on the server side
	-- if the attribute hasn't been stamped yet (rare init race).
	local DamageService = Knit.GetService("DamageService")
	local StatusConditionService = Knit.GetService("StatusConditionService")
	local level = getPlayerLevel(self._player)
	local baseDamage = self._damagePerLevel * level

	-- Hit every zombie in the stomp radius. Tag-based lookup mirrors
	-- the hitbox pattern VFXService:CreateHitbox uses so behavior is
	-- consistent with magic spells. OverlapParams keeps the cost
	-- bounded to the radius volume.
	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Include
	overlapParams.FilterDescendantsInstances = { workspace.IgnoreInstances.Zombies }

	local hitMobs: { [Model]: boolean } = {}
	for _, part in workspace:GetPartBoundsInRadius(self._landingPosition, STOMP_RADIUS, overlapParams) do
		local model = part:FindFirstAncestorWhichIsA("Model")
		if not model or hitMobs[model] then
			continue
		end
		local mobHumanoid = model:FindFirstChildOfClass("Humanoid")
		if not mobHumanoid or mobHumanoid.Health <= 0 then
			continue
		end
		hitMobs[model] = true

		-- Route through TakeDamage so all the weapon-damage amplifiers
		-- + crit + variance + indicator + on-hit relic procs compose
		-- automatically. Signature: (player, humanoid, damage, isMagic,
		-- isStatusConditionDamage, isMelee). isMelee=true per the
		-- design — the stomp procs Berserker's Claymore's melee bonus
		-- but NOT Volleyball (ranged-only gate).
		-- Trailing `true` = isRelicSourced. The stomp is melee-FLAGGED (so it
		-- procs Berserker's Claymore), but it's a relic proc rather than a
		-- weapon swing, so it deals damage without staggering. Flip that last
		-- argument to false if stomps should knock weak mobs around.
		DamageService:TakeDamage(self._player, mobHumanoid, baseDamage, false, false, true, true)

		-- TakeDamage does NOT roll the status applier tables — the hit
		-- paths own that (melee/projectile → weapon hub, onHitboxDamage
		-- → magic hub). The stomp bypasses those paths, so roll the
		-- weapon hub here per mob (the stomp is weapon-flavored:
		-- isMagic=false, isMelee=true), matching how GhostDragon calls
		-- the magic hub for its aura ticks.
		StatusConditionService:ApplyWeaponOnHitStatuses(self._player, nil, model, false)
	end

	-- Client replication hook for VFX. Fires AFTER damage application
	-- so any visual the designer attaches can read final state.
	-- FireAll (rather than FireFor caster) so other clients see the
	-- stomp on the caster too — consistent with how OnFireworksEffectActivated
	-- and OnVolleyballEffectActivated broadcast.
	self._relicService.Client.OnSuperStompBoots:FireAll(self._player, self._landingPosition, STOMP_RADIUS, baseDamage)
end

return SuperStompBoots
