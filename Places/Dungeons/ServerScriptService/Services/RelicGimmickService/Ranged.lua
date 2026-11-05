--!strict
--[[
	Module: RelicGimmickService/Ranged
	Description:
	The ranged relics' gimmicks (2026-10-30), one per element; each is
	driven by onRangedHit (every gun shot that lands) and counts its own
	shots per player:

	  (War Rocks moved to RelicGimmickService/Earth on 2026-11-01: a
	  chance per Weapon hit, melee or ranged, that Fractures.)
	  Rubber Chicken Launcher  (Storm) a ranged Critical Hit sticks a charge
	                          on the enemy; after `fuseSeconds` it detonates
	                          for the callback's share of that hit in
	                          `radius`, Shocking everything there.
	  Witches Brew            (Venom) every `everyShots` gun SHOT (2026-11-04;
	                          landed hits before) throws a potion WITH the
	                          shot, straight along its aim (Lib/relicShots,
	                          no homing); it bursts where it lands (a mob,
	                          a wall, or the end of the gun's range):
	                          per-level damage in
	                          `radius`, Poison, and a puddle that Poisons
	                          whatever stands in it for `puddleSeconds`.

	Every hit here is a relic burst (the untyped lane: no crits, no weapon
	relics). The Hyperlaser guns (Blaze's red, Frost's blue) have no
	gimmick: they are a status row and DamageService/RangedRelics.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local StatusConditions = require(ReplicatedStorage.Submodules.Core.Shared.Enums.StatusConditions)
local getRoot = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Character.getRoot)
local forEachEnemyInRadius = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Combat.forEachEnemyInRadius)
local snapToGround = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Combat.snapToGround)
local helpers = require(script.Parent.Lib.gimmickHelpers)
local relicTriggers = require(script.Parent.Lib.relicTriggers)
local relicShots = require(script.Parent.Lib.relicShots)
local GameClock = require(ReplicatedStorage.Submodules.Core.Shared.GameClock)

local CHARGE = RelicNames["Rubber Chicken Launcher"]
local MORTAR = RelicNames["Witches Brew"]

-- How long the bubble flies.
-- The potion's studs a game second (2026-11-04).
local POTION_SPEED = 60
-- How often a puddle looks for enemies standing in it.
local PUDDLE_SCAN_SECONDS = 0.5

local Ranged = {}

local mortarShots: { [Player]: number } = {}
-- [player][model] = a charge is already ticking there (one at a time).
local charges: { [Player]: { [Model]: boolean } } = {}

-- Counts a shot for one of the every-Nth relics; true on the Nth.
local function countShot(counts: { [Player]: number }, player: Player, every: number): boolean
	local count = (counts[player] or 0) + 1
	if count >= every then
		counts[player] = 0
		return true
	end
	counts[player] = count
	return false
end

-- A relic-burst splash at `position`: damage, and `status` when given.
local function splash(player: Player, position: Vector3, radius: number, damage: number, status: string?)
	helpers.hitBreakables(player, position, radius)
	local statusService = helpers.statusService()
	forEachEnemyInRadius(position, radius, function(model: Model, humanoid: Humanoid)
		if damage > 0 then
			helpers.takeDamage(player, humanoid, damage, false, false, nil, true)
		end
		if status then
			statusService:ApplyStatus(player, model, status)
		end
	end)
end

--[ Rubber Chicken Launcher ]--

local function stickCharge(player: Player, model: Model, dealt: number)
	local mine = charges[player] or {}
	charges[player] = mine
	if mine[model] then
		return
	end
	local root = getRoot(model)
	if not root then
		return
	end
	mine[model] = true
	local fuse = helpers.data(CHARGE, "fuseSeconds", 1.5)
	local radius = helpers.data(CHARGE, "radius", 8)
	local share = helpers.relicService():GetRelicEffect(player, CHARGE) or 1
	helpers.fx("StaticCharge", root.Position, root.Position, radius, fuse, player, model)
	local lastPosition = root.Position
	GameClock.Delay(fuse, function()
		mine[model] = nil
		if not player.Parent then
			return
		end
		local liveRoot = getRoot(model)
		if liveRoot then
			lastPosition = liveRoot.Position
		end
		helpers.fx("ShockBurst", lastPosition, nil, radius, nil, player)
		splash(player, lastPosition, radius, math.round(dealt * share), StatusConditions.Shock)
	end)
end

--[ Witches Brew ]--

-- The potion burst at `position`: damage and Poison in `radius`, then a
-- puddle that Poisons whatever stands in it for `puddleSeconds`.
local function burstPotion(player: Player, position: Vector3)
	local radius = helpers.data(MORTAR, "radius", 7)
	local ground = snapToGround(position, { mapOnly = true }) or position
	helpers.fx("ToxicBurst", position, nil, radius, nil, player)
	splash(
		player,
		ground,
		radius,
		helpers.levelDamage(player, helpers.data(MORTAR, "damagePerLevel", 15)),
		StatusConditions.Poison
	)
	local seconds = helpers.data(MORTAR, "puddleSeconds", 3)
	helpers.fx("ToxicPuddle", ground, nil, radius, seconds, player)
	task.spawn(function()
		local endsAt = GameClock.Now() + seconds
		while GameClock.Now() < endsAt and player.Parent do
			GameClock.Wait(PUDDLE_SCAN_SECONDS)
			splash(player, ground, radius, 0, StatusConditions.Poison)
		end
	end)
end

--[ Handlers ]--

function Ranged.onRangedHit(player: Player, model: Model, dealt: number, wasCrit: boolean)
	local root = getRoot(model)
	if not root then
		return
	end
	if wasCrit and dealt > 0 and helpers.owns(player, CHARGE) then
		stickCharge(player, model, dealt)
	end
end

-- Every gun shot, the moment it is fired: the Brew's count. The Nth
-- throws the potion with it.
function Ranged.onRangedFire(player: Player, origin: Vector3, direction: Vector3, weaponName: string)
	if not helpers.owns(player, MORTAR) then
		mortarShots[player] = nil
		relicTriggers.set(player, MORTAR, false)
		return
	end
	local needed = helpers.data(MORTAR, "everyShots", 5)
	if countShot(mortarShots, player, needed) then
		relicShots.fire(player, "BrewShot", origin, direction, weaponName, POTION_SPEED, function(position)
			burstPotion(player, position)
		end)
	end
	relicTriggers.set(player, MORTAR, (mortarShots[player] or 0) == needed - 1)
end

-- The gun was put away: the Brew's count starts over.
function Ranged.onWeaponStowed(player: Player, lane: string)
	if lane == "Ranged" then
		mortarShots[player] = nil
	end
end

function Ranged.onPlayerRemoved(player: Player)
	mortarShots[player] = nil
	charges[player] = nil
end

return Ranged
