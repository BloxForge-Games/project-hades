local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local MagicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.MagicNames)
local MagicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.MagicData)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local getPlayerLevel = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Player.getPlayerLevel)

local DamageService
local StatusConditionService
local RelicService

Knit.OnStart():andThen(function()
	DamageService = Knit.GetService("DamageService")
	RelicService = Knit.GetService("RelicService")
	StatusConditionService = Knit.GetService("StatusConditionService")
end)

local HITBOX_SIZE_MULTIPLIER = 1.25

local GhostDragon = {}
GhostDragon.__index = GhostDragon

function GhostDragon.new(
	player: Player,
	ghostDragonCount: number,
	relicService: any,
	vfxService: any,
	ignoreListService: any
)
	local self = setmetatable({}, GhostDragon)

	self._player = player
	self._ghostDragonCount = ghostDragonCount
	self._relicService = relicService
	self._vfxService = vfxService
	self._ignoreListService = ignoreListService

	return self
end

-- Ghost Dragon: every second, deal (8 x PlayerLevel x (1 + bonus MaxHP %))
-- Magic Damage to nearby enemies. RAW damage -- it scales on level and the
-- owner's relic-sourced bonus Maximum Health percentage and NOTHING else.
--
-- The raw-damage flag (5th arg) is what enforces that: it takes
-- TakeDamage's bypass branch, so no amplifier in the chain applies, there
-- is no crit roll and no +-10% variance, and the number the mob takes is
-- exactly 20% of MaxHealth. The final arg opts back INTO the normal hit
-- VFX -- the raw path suppresses them by default for multi-tick DoTs,
-- but this fires once per second and should read like any other hit.
--
-- Statuses still apply -- the applier hub is called separately below, so
-- it is unaffected by the damage bypass.
function GhostDragon:InvokeGhostDragon()
	local character = self._player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	-- Skip the tick while the player is dead/spectating. LifeService keeps
	-- humanoid.Health clamped at 1 during death (so Humanoid.Died never
	-- fires across the project), which means the existing "is the player
	-- alive" check above passes even when the character is ragdolled. The
	-- Death attribute is the authoritative signal — gate on it so the
	-- relic stops dealing damage from the corpse.
	if character:GetAttribute(Attributes.Death) == true then
		return
	end

	-- Rate comes from the relic callback (GHOST_DRAGON_DAMAGE_PER_LEVEL in
	-- RelicData). The bonus-max-health amp came off in the 2026-08 pass:
	-- the card is a flat level scale now, matching every other per-level
	-- relic. Rounded because the raw-damage path applies this verbatim.
	local ratePerLevel = RelicService:GetRelicEffect(self._player, RelicNames["Ghost Dragon"]) or 10
	local baseDamage = math.round(ratePerLevel * getPlayerLevel(self._player))

	self._vfxService:CreateHitbox(
		MagicNames["Ghost Dragon"],
		self._player,
		character.HumanoidRootPart.CFrame,
		TagList.Zombie,
		self._ignoreListService:GetWeaponIgnoreList(),
		function(model: Model)
			local mobHumanoid = model:FindFirstChild("Humanoid")
			if not mobHumanoid or mobHumanoid.Health <= 0 then
				return
			end

			-- UNTYPED relic lane: amplified by unqualified Damage bonuses
			-- (was the raw path with a magic flag — neither was right).
			DamageService:TakeDamage(self._player, mobHumanoid, baseDamage, false, false, false, true, true)

			-- Ghost Dragon damage IS relic magic damage, so each aura tick
			-- rolls the magic-hit applier hub per mob (the status Epics'
			-- "+10% on all damage" rows and the magic-side Rares). Status
			-- DoT ticks never route through the hubs — only real damage
			-- events like this one.
			StatusConditionService:ApplyMagicOnHitStatuses(self._player, model)
		end,
		MagicData[MagicNames["Ghost Dragon"]].hitboxSize.X * HITBOX_SIZE_MULTIPLIER
	)
end

return GhostDragon
