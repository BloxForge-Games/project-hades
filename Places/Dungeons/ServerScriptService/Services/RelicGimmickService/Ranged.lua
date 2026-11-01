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
	  Witches Brew            (Venom) every `everyShots` shot lobs a poison
	                          bubble at the target: per-level damage in
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

local CHARGE = RelicNames["Rubber Chicken Launcher"]
local MORTAR = RelicNames["Witches Brew"]

-- How long the bubble flies.
local BUBBLE_FLIGHT_SECONDS = 0.5
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
	task.delay(fuse, function()
		mine[model] = nil
		if not player.Parent then
			return
		end
		local liveRoot = getRoot(model)
		if liveRoot then
			lastPosition = liveRoot.Position
		end
		helpers.fx("ShockBurst", lastPosition, nil, radius)
		splash(player, lastPosition, radius, math.round(dealt * share), StatusConditions.Shock)
	end)
end

--[ Witches Brew ]--

local function lobBubble(player: Player, target: Vector3)
	local root = getRoot.fromPlayer(player)
	if not root then
		return
	end
	local radius = helpers.data(MORTAR, "radius", 7)
	local ground = snapToGround(target, { mapOnly = true }) or target
	helpers.fx("ToxicBubble", root.Position + Vector3.new(0, 2, 0), ground, radius, BUBBLE_FLIGHT_SECONDS)
	task.delay(BUBBLE_FLIGHT_SECONDS, function()
		if not player.Parent then
			return
		end
		splash(
			player,
			ground,
			radius,
			helpers.levelDamage(player, helpers.data(MORTAR, "damagePerLevel", 15)),
			StatusConditions.Poison
		)
		local seconds = helpers.data(MORTAR, "puddleSeconds", 3)
		helpers.fx("ToxicPuddle", ground, nil, radius, seconds)
		local endsAt = os.clock() + seconds
		while os.clock() < endsAt and player.Parent do
			task.wait(PUDDLE_SCAN_SECONDS)
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
	if helpers.owns(player, MORTAR) and countShot(mortarShots, player, helpers.data(MORTAR, "everyShots", 6)) then
		lobBubble(player, root.Position)
	end
end

function Ranged.onPlayerRemoved(player: Player)
	mortarShots[player] = nil
	charges[player] = nil
end

return Ranged
