--!strict
--[[
	Module: RelicGimmickService/Storm
	Description:
	Storm's gimmick epics (Crit / Shock). Their bolts roll a crit of their
	own (gimmickHelpers.rollCrit) and land on the untyped relic lane, so
	crit-chance relics make them crit while their crits never re-trigger
	the crit gimmicks.

	  Katana                 CHAIN LIGHTNING: any weapon or spell hit has
	                         `chainChance` (`arcaneChainChance` on Arcane)
	                         to arc lightning from its target through
	                         `jumps` more enemies within `jumpRange` (damage
	                         only, no Shock). One roll per
	                         CHAIN_FANOUT_SECONDS, so an AoE rolls once.
	  Lightning Bolt Sword   THUNDER BLADE: while Stormcharged, every 4 / 3 /
	                         2 melee swings (Daggers / Sword / Greatsword)
	                         throw a lightning slash along the swing; it
	                         pierces every enemy in its path, Shocking each.
	  Sparkle Time           LIGHTNING DASH: a dodge damages and Shocks every
	  Hoverboard             enemy along its line. (Its invisibility and sound live in
	                         DodgeService / DodgeController /
	                         LightningDashController.)

	The clients draw the bolts and the blade (helpers.fx).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local AuraNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.AuraNames)
local StatusConditions = require(ReplicatedStorage.Submodules.Core.Shared.Enums.StatusConditions)
local getRoot = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Character.getRoot)
local forEachEnemyInRadius = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Combat.forEachEnemyInRadius)
local helpers = require(script.Parent.Lib.gimmickHelpers)

local KATANA = RelicNames.Katana
local BOLT_SWORD = RelicNames["Lightning Bolt Sword"]
local HOVERBOARD = RelicNames["Sparkle Time Hoverboard"]

-- Chain Lightning: the beat between jumps (so the chain reads as
-- travelling, enemy to enemy). Its reach is data.jumpRange.
local CHAIN_JUMP_SECONDS = 0.07
local CHAIN_FANOUT_SECONDS = 0.1

-- Thunder Blade: its travel and hit width.
local BLADE_SPEED = 60
local BLADE_RANGE = 26
local BLADE_RADIUS = 4
local BLADE_DROP = 1

-- Lightning Dash: how close to the dash line an enemy must be.
local DASH_WIDTH = 3.5

local Storm = {}

local bladeSwings: { [Player]: number } = {}
local lastChainRoll: { [Player]: number } = {}

-- One Storm bolt on one enemy: its own crit roll, damage, and a Shock
-- unless `noShock` (Chain Lightning).
local function boltHit(player: Player, model: Model, humanoid: Humanoid, baseDamage: number, noShock: boolean?)
	local multiplier = helpers.rollCrit(player, model)
	helpers.takeDamage(player, humanoid, baseDamage * multiplier, false, false, nil, true)
	if not noShock then
		helpers.statusService():ApplyStatus(player, model, StatusConditions.Shock)
	end
end

local function isStormcharged(player: Player): boolean
	local root = getRoot.fromPlayer(player)
	return root ~= nil and root:FindFirstChild(AuraNames.Stormcharged) ~= nil
end

--[ Chain Lightning ]--

local function chainLightning(player: Player, origin: Model)
	local originRoot = getRoot(origin)
	if not originRoot then
		return
	end
	local damage = helpers.levelDamage(player, helpers.data(KATANA, "damagePerLevel", 9))
	local hit: { [Model]: boolean } = { [origin] = true }
	local from = originRoot.Position
	for jump = 1, helpers.data(KATANA, "jumps", 3) do
		if jump > 1 then
			task.wait(CHAIN_JUMP_SECONDS)
		end
		local nextModel: Model? = nil
		local nextHumanoid: Humanoid? = nil
		local nearest = math.huge
		forEachEnemyInRadius(from, helpers.data(KATANA, "jumpRange", 18), function(model: Model, humanoid: Humanoid)
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
		boltHit(player, nextModel, nextHumanoid, damage, true)
		from = nextRoot.Position
	end
end

--[ Thunder Blade ]--

local function throwBlade(player: Player, origin: Vector3, swingLook: Vector3)
	local look = swingLook * Vector3.new(1, 0, 1)
	if look.Magnitude < 0.1 then
		return
	end
	look = look.Unit
	local start = origin - Vector3.new(0, BLADE_DROP, 0)
	helpers.fx("ThunderBlade", start, start + look * BLADE_RANGE, nil, BLADE_RANGE / BLADE_SPEED)
	local damage = helpers.levelDamage(player, helpers.data(BOLT_SWORD, "damagePerLevel", 20))
	local hit: { [Model]: boolean } = {}
	local hitBreakables: { [Instance]: boolean } = {}
	helpers.sweep(start, look, BLADE_SPEED, BLADE_RANGE, function(position: Vector3)
		helpers.hitBreakables(player, position, BLADE_RADIUS, hitBreakables)
		forEachEnemyInRadius(position, BLADE_RADIUS, function(model: Model, humanoid: Humanoid)
			if hit[model] then
				return
			end
			hit[model] = true
			boltHit(player, model, humanoid, damage)
		end)
	end)
end

-- Every melee swing (MeleeWeapon): Thunder Blade's count.
function Storm.onMeleeSwing(
	player: Player,
	origin: Vector3,
	look: Vector3,
	_swingDamage: number,
	_connected: boolean,
	weaponType: string?
)
	if not helpers.owns(player, BOLT_SWORD) or not isStormcharged(player) then
		return
	end
	local count = (bladeSwings[player] or 0) + 1
	if count >= helpers.swingsFor(BOLT_SWORD, weaponType) then
		count = 0
		throwBlade(player, origin, look)
	end
	bladeSwings[player] = count
end

-- A weapon or spell hit by `player` landed on `model` (DamageService).
function Storm.onAttackHit(player: Player, model: Model, isMagic: boolean)
	if not helpers.owns(player, KATANA) then
		return
	end
	local now = os.clock()
	if lastChainRoll[player] and now - lastChainRoll[player] < CHAIN_FANOUT_SECONDS then
		return
	end
	lastChainRoll[player] = now
	local chance = if isMagic
		then helpers.data(KATANA, "arcaneChainChance", 0.3)
		else helpers.data(KATANA, "chainChance", 0.1)
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
	bladeSwings[player] = nil
	lastChainRoll[player] = nil
end

return Storm
