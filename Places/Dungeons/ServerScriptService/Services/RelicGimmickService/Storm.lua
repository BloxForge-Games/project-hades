--!strict
--[[
	Module: RelicGimmickService/Storm
	Description:
	Storm's gimmick relics (Shock). Their bolts roll a crit of their own
	(gimmickHelpers.rollCrit) and land on the untyped relic lane, so
	crit-chance gear makes them crit while their crits never re-trigger
	the crit gimmicks.

	  Lightning Bolt Sword   CHAIN LIGHTNING (2026-10-31; the Thunder Blade
	                         and its Stormcharged gate left with the auras):
	                         any weapon or spell hit has `chainChance`
	                         (`arcaneChainChance` on Arcane) to arc
	                         lightning from its target through `jumps` more
	                         enemies within `jumpRange`, each bolt dealing
	                         damage and Shocking. One roll per
	                         CHAIN_FANOUT_SECONDS, so an AoE rolls once.
	  Sparkle Time           LIGHTNING DASH: a dodge damages and Shocks every
	  Hoverboard             enemy along its line. (Its length, invisibility
	                         and sound live in DodgeController / DodgeService /
	                         LightningDashController.)

	The clients draw the bolts (helpers.fx).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local StatusConditions = require(ReplicatedStorage.Submodules.Core.Shared.Enums.StatusConditions)
local getRoot = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Character.getRoot)
local forEachEnemyInRadius = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Combat.forEachEnemyInRadius)
local helpers = require(script.Parent.Lib.gimmickHelpers)

local BOLT_SWORD = RelicNames["Lightning Bolt Sword"]
local HOVERBOARD = RelicNames["Sparkle Time Hoverboard"]

-- Chain Lightning: the beat between jumps (so the chain reads as
-- travelling, enemy to enemy). Its reach is data.jumpRange.
local CHAIN_JUMP_SECONDS = 0.07
local CHAIN_FANOUT_SECONDS = 0.1
-- Lightning Dash: how close to the dash line an enemy must be.
local DASH_WIDTH = 3.5

local Storm = {}

local lastChainRoll: { [Player]: number } = {}

-- One Storm bolt on one enemy: its own crit roll, damage, and a Shock.
local function boltHit(player: Player, model: Model, humanoid: Humanoid, baseDamage: number)
	local multiplier = helpers.rollCrit(player, model)
	helpers.takeDamage(player, humanoid, baseDamage * multiplier, false, false, nil, true)
	helpers.statusService():ApplyStatus(player, model, StatusConditions.Shock)
end

--[ Chain Lightning ]--

local function chainLightning(player: Player, origin: Model)
	local originRoot = getRoot(origin)
	if not originRoot then
		return
	end
	local damage = helpers.levelDamage(player, helpers.data(BOLT_SWORD, "damagePerLevel", 15))
	local hit: { [Model]: boolean } = { [origin] = true }
	local from = originRoot.Position
	for jump = 1, helpers.data(BOLT_SWORD, "jumps", 3) do
		if jump > 1 then
			task.wait(CHAIN_JUMP_SECONDS)
		end
		local nextModel: Model? = nil
		local nextHumanoid: Humanoid? = nil
		local nearest = math.huge
		forEachEnemyInRadius(from, helpers.data(BOLT_SWORD, "jumpRange", 18), function(model: Model, humanoid: Humanoid)
			if hit[model] then
				return
			end
			local root = getRoot(model)
			local distance = if root then (root.Position - from).Magnitude else math.huge
			if distance < nearest then
				nearest, nextModel, nextHumanoid = distance, model, humanoid
			end
		end)
		local nextRoot = nextModel and getRoot(nextModel)
		if not nextModel or not nextHumanoid or not nextRoot then
			return
		end
		hit[nextModel] = true
		helpers.fx("Bolt", from, nextRoot.Position)
		boltHit(player, nextModel, nextHumanoid, damage)
		from = nextRoot.Position
	end
end

-- A weapon or spell hit by `player` landed on `model` (DamageService).
function Storm.onAttackHit(player: Player, model: Model, isMagic: boolean)
	if not helpers.owns(player, BOLT_SWORD) then
		return
	end
	local now = os.clock()
	if lastChainRoll[player] and now - lastChainRoll[player] < CHAIN_FANOUT_SECONDS then
		return
	end
	lastChainRoll[player] = now
	local chance = if isMagic
		then helpers.data(BOLT_SWORD, "arcaneChainChance", 0.3)
		else helpers.data(BOLT_SWORD, "chainChance", 0.1)
	if math.random() < chance then
		-- Spawned: the jumps wait between them, and the damage path must
		-- not yield.
		task.spawn(chainLightning, player, model)
	end
end

--[ Lightning Dash ]--

function Storm.onDodge(player: Player, from: Vector3, to: Vector3)
	if not helpers.owns(player, HOVERBOARD) then
		return
	end
	local mid = from:Lerp(to, 0.5)
	local seen: { [Instance]: boolean } = {}
	for step = 0, 4 do
		helpers.hitBreakables(player, from:Lerp(to, step / 4), DASH_WIDTH, seen)
	end
	local damage = helpers.levelDamage(player, helpers.data(HOVERBOARD, "damagePerLevel", 15))
	forEachEnemyInRadius(mid, (to - from).Magnitude / 2 + DASH_WIDTH, function(model: Model, humanoid: Humanoid)
		local root = getRoot(model)
		if root and helpers.flatDistanceToSegment(root.Position, from, to) <= DASH_WIDTH then
			boltHit(player, model, humanoid, damage)
		end
	end)
end

function Storm.onPlayerRemoved(player: Player)
	lastChainRoll[player] = nil
end

return Storm
