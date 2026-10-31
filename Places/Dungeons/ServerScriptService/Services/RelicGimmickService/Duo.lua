--!strict
--[[
	Module: RelicGimmickService/Duo
	Description:
	The DUO relics (2026-10-30): Legendary, offered once the player can
	produce a tag from each of two elements (RelicData requiredTags).

	  HEX Spitter            (Blaze + Storm) while Enflamed AND Stormcharged,
	                         a Critical Hit bursts in a nova: the callback's
	                         share of the hit to every other enemy in
	                         `radius` (a relic burst), Burning and Shocking
	                         all of them.
	  Blizzard Wand          (Frost + Storm) a Spell's first hit calls a
	                         hailstorm there for `seconds`: a shard falls
	                         every `shardEvery` at a random spot inside
	                         `radius`, dealing per-level ARCANE damage in
	                         `shardRadius` (so it can crit and takes the
	                         arcane relics) and Chilling.
	  Korblox Ice Claws      (Frost + Earth) the ice shell is drawn here (a
	                         keepalive while the owner holds a Barrier); its
	                         shatter is ShieldService._shatterIceShell.
	  Fire Breathing Friend  (Venom + Blaze) no gimmick here: Melted is
	                         StatusConditionService's attribute and
	                         DamageService's vulnerability step; the clients
	                         draw the green fire.
	  Medusa Head           (Earth + Venom) no gimmick here: the Petrified
	                         status (StatusConditionService applies it with
	                         the owner's Poison while Stonebound).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local AuraNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.AuraNames)
local StatusConditions = require(ReplicatedStorage.Submodules.Core.Shared.Enums.StatusConditions)
local getRoot = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Character.getRoot)
local forEachEnemyInRadius = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Combat.forEachEnemyInRadius)
local snapToGround = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Combat.snapToGround)
local helpers = require(script.Parent.Lib.gimmickHelpers)

local PLASMA = RelicNames["HEX Spitter"]
local HAIL = RelicNames["Blizzard Wand"]
local SHELL = RelicNames["Korblox Ice Claws"]

-- One nova per player per this window: an AoE crit is many crits.
local PLASMA_LATCH_SECONDS = 0.1
-- A hail shard falls this long before it lands.
local SHARD_FALL_SECONDS = 0.25
local SHARD_FALL_HEIGHT = 18
-- The shell's keepalive: the client keeps it this long past each
-- once-a-second re-send.
local SHELL_KEEPALIVE_SECONDS = 2

local Duo = {}

local lastNova: { [Player]: number } = {}
-- Blizzard Wand: [player][spell] = a storm is still owed by that cast.
local pendingStorms: { [Player]: { [string]: boolean } } = {}

--[ HEX Spitter ]--

function Duo.onCrit(player: Player, model: Model, _isMelee: boolean, dealt: number, _isRanged: boolean)
	if dealt <= 0 or not helpers.owns(player, PLASMA) then
		return
	end
	local casterRoot = getRoot.fromPlayer(player)
	if
		not casterRoot
		or not casterRoot:FindFirstChild(AuraNames.Enflamed)
		or not casterRoot:FindFirstChild(AuraNames.Stormcharged)
	then
		return
	end
	local now = os.clock()
	if now - (lastNova[player] or -math.huge) < PLASMA_LATCH_SECONDS then
		return
	end
	lastNova[player] = now
	local root = getRoot(model)
	if not root then
		return
	end
	local radius = helpers.data(PLASMA, "radius", 8)
	local share = helpers.relicService():GetRelicEffect(player, PLASMA) or 0.6
	local damage = math.round(dealt * share)
	helpers.fx("PlasmaNova", root.Position, nil, radius)
	helpers.hitBreakables(player, root.Position, radius)
	local statusService = helpers.statusService()
	forEachEnemyInRadius(root.Position, radius, function(other: Model, humanoid: Humanoid)
		if other ~= model and damage > 0 then
			helpers.takeDamage(player, humanoid, damage, false, false, nil, true)
		end
		statusService:ApplyStatus(player, other, StatusConditions.Burn)
		statusService:ApplyStatus(player, other, StatusConditions.Shock)
	end)
end

--[ Blizzard Wand ]--

local function callHailstorm(player: Player, position: Vector3)
	local ground = snapToGround(position, { mapOnly = true }) or position
	local seconds = helpers.data(HAIL, "seconds", 4)
	local radius = helpers.data(HAIL, "radius", 10)
	local every = helpers.data(HAIL, "shardEvery", 0.2)
	local shardRadius = helpers.data(HAIL, "shardRadius", 4)
	local damage = helpers.levelDamage(player, helpers.data(HAIL, "damagePerLevel", 8))
	helpers.fx("Hailstorm", ground, nil, radius, seconds)
	task.spawn(function()
		local endsAt = os.clock() + seconds
		while os.clock() < endsAt and player.Parent do
			local angle = math.random() * math.pi * 2
			local distance = math.sqrt(math.random()) * radius
			local spot = ground + Vector3.new(math.cos(angle) * distance, 0, math.sin(angle) * distance)
			helpers.fx("HailShard", spot + Vector3.new(0, SHARD_FALL_HEIGHT, 0), spot, shardRadius, SHARD_FALL_SECONDS)
			task.delay(SHARD_FALL_SECONDS, function()
				if not player.Parent then
					return
				end
				helpers.hitBreakables(player, spot, shardRadius)
				local statusService = helpers.statusService()
				forEachEnemyInRadius(spot, shardRadius, function(model: Model, humanoid: Humanoid)
					helpers.takeDamage(player, humanoid, damage, true, false, false)
					statusService:ApplyStatus(player, model, StatusConditions.Chill)
				end)
			end)
			task.wait(every)
		end
	end)
end

function Duo.onSpellCast(player: Player, vfxName: string)
	if helpers.owns(player, HAIL) then
		local pending = pendingStorms[player] or {}
		pendingStorms[player] = pending
		pending[vfxName] = true
	end
end

function Duo.onSpellHit(player: Player, vfxName: string, model: Model)
	local pending = pendingStorms[player]
	if pending and pending[vfxName] then
		pending[vfxName] = nil
		local root = getRoot(model)
		if root then
			callHailstorm(player, root.Position)
		end
	end
end

--[ Korblox Ice Claws ]--

-- Once a second: the shell is up while its owner holds any Barrier.
function Duo.onTick(player: Player)
	if not helpers.owns(player, SHELL) then
		return
	end
	local character = player.Character
	local root = getRoot(character)
	if character and root and ((character:GetAttribute("ShieldValue") or 0) :: number) > 0 then
		helpers.fx("IceShell", root.Position, nil, nil, SHELL_KEEPALIVE_SECONDS, player)
	end
end

function Duo.onPlayerRemoved(player: Player)
	lastNova[player] = nil
	pendingStorms[player] = nil
end

return Duo
