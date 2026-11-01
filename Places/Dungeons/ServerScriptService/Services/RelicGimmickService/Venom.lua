--!strict
--[[
	Module: RelicGimmickService/Venom
	Description:
	Venom's gimmick relic that needs a world effect:
	  Zombie Bomb       TOXIC SPIT (2026-10-31; it rode the owner's Poison
	                    ticks before): any weapon or spell hit has
	                    `spitChance` to lob a toxic bubble from the hit enemy
	                    at another one nearby, damaging and Poisoning every
	                    enemy where it lands. One roll per
	                    SPIT_FANOUT_SECONDS, so an AoE rolls once.
	                    (Foul Poison Fowl's takedown cloud is in MobDeath.)

	The bubble is drawn by the clients (helpers.fx); the server waits out
	its flight and Poisons where it lands.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local StatusConditions = require(ReplicatedStorage.Submodules.Core.Shared.Enums.StatusConditions)
local getRoot = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Character.getRoot)
local forEachEnemyInRadius = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Combat.forEachEnemyInRadius)
local helpers = require(script.Parent.Lib.gimmickHelpers)

local ZOMBIE_BOMB = RelicNames["Zombie Bomb"]

-- Toxic Spit's reach and flight.
local SPIT_RANGE = 15
local SPIT_FLIGHT_SECONDS = 0.5
-- The goop splashes every enemy within this far of the landing.
local SPIT_SPLASH_RADIUS = 6
-- One roll per hit burst (an AoE's many hits land within this window).
local SPIT_FANOUT_SECONDS = 0.1

local Venom = {}

local lastSpitRoll: { [Player]: number } = {}

local function lobBubble(player: Player, fromModel: Model)
	local fromRoot = getRoot(fromModel)
	if not fromRoot then
		return
	end
	local candidates: { Model } = {}
	forEachEnemyInRadius(fromRoot.Position, SPIT_RANGE, function(model: Model)
		if model ~= fromModel then
			table.insert(candidates, model)
		end
	end)
	-- Alone: the goop lands back on the hit enemy itself.
	local target = if #candidates > 0 then candidates[math.random(#candidates)] else fromModel
	local targetRoot = getRoot(target)
	if not targetRoot then
		return
	end
	local from = fromRoot.Position + Vector3.new(0, 2, 0)
	local to = targetRoot.Position
	helpers.fx("ToxicBubble", from, to, SPIT_SPLASH_RADIUS, SPIT_FLIGHT_SECONDS)
	task.delay(SPIT_FLIGHT_SECONDS, function()
		if not player.Parent then
			return
		end
		helpers.hitBreakables(player, to, SPIT_SPLASH_RADIUS)
		local damage = helpers.levelDamage(player, helpers.data(ZOMBIE_BOMB, "damagePerLevel", 12))
		forEachEnemyInRadius(to, SPIT_SPLASH_RADIUS, function(model: Model, humanoid: Humanoid)
			-- Untyped relic lane, like every relic burst.
			helpers.takeDamage(player, humanoid, damage, false, false, nil, true)
			helpers.statusService():ApplyStatus(player, model, StatusConditions.Poison)
		end)
	end)
end

-- A weapon or spell hit by `player` landed on `model` (DamageService):
-- Toxic Spit's roll.
function Venom.onAttackHit(player: Player, model: Model, _isMagic: boolean)
	if not helpers.owns(player, ZOMBIE_BOMB) then
		return
	end
	local now = os.clock()
	if lastSpitRoll[player] and now - lastSpitRoll[player] < SPIT_FANOUT_SECONDS then
		return
	end
	lastSpitRoll[player] = now
	if math.random() < helpers.data(ZOMBIE_BOMB, "spitChance", 0.2) then
		lobBubble(player, model)
	end
end

function Venom.onPlayerRemoved(player: Player)
	lastSpitRoll[player] = nil
end

return Venom
