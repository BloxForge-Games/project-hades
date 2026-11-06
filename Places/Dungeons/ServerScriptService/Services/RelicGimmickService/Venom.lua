--!strict
--[[
	Module: RelicGimmickService/Venom
	Description:
	Venom's gimmick relics:
	  Korblox Evil Eye  THE 3rd SHOT (2026-11-05; every 2nd Spell cheaper
	                    and Poisoning before): every `everyShots`-th gun
	                    shot is primed (its RelicTrigger glows the shot
	                    before); the next shot hit deals `bonusDamage` of
	                    the hit again on top, on the relic lane, and
	                    Poisons. The prime lapses after PRIME_SECONDS (a
	                    miss).
	  Zombie Bomb       TOXIC SPIT (2026-11-01; `spitChance` per attack hit
	                    from 2026-10-31 until then): every Poison or Death
	                    Venom TICK the owner deals has `tickSpitChance` to
	                    lob a toxic bubble from the ticking enemy at another
	                    one nearby, damaging and Poisoning every enemy where
	                    it lands. One roll per enemy per tick, and a spit at
	                    most every `spitCooldown`.
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
local relicTriggers = require(script.Parent.Lib.relicTriggers)
local GameClock = require(ReplicatedStorage.Submodules.Core.Shared.GameClock)

local ZOMBIE_BOMB = RelicNames["Zombie Bomb"]
local EVIL_EYE = RelicNames["Korblox Evil Eye"]

-- Toxic Spit's reach and flight.
local SPIT_RANGE = 15
local SPIT_FLIGHT_SECONDS = 0.5
-- The goop splashes every enemy within this far of the landing.
local SPIT_SPLASH_RADIUS = 6
-- One roll per enemy per tick: the same enemy's stacks ticking within
-- this window (one status sweep) count as one tick.
local SPIT_TICK_WINDOW_SECONDS = 0.1
-- Evil Eye: how long a primed shot waits for its hit.
local PRIME_SECONDS = 1.5

local Venom = {}

-- Toxic Spit: when the owner last spat, and [player][model] = when that
-- enemy's tick last rolled.
local lastSpitAt: { [Player]: number } = {}
local lastTickRoll: { [Player]: { [Model]: number } } = {}
-- Evil Eye: gun shots since the last primed one, and when the primed
-- shot lapses.
local eyeShots: { [Player]: number } = {}
local eyePrimedUntil: { [Player]: number } = {}
-- True when the shot onRangedFire just counted is the Eye's poison shot
-- (2026-11-05): ShotTint reads it right after, for the shot's colour.
local eyeShotIsPoison: { [Player]: boolean } = {}

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
	helpers.fx("ToxicBubble", from, to, SPIT_SPLASH_RADIUS, SPIT_FLIGHT_SECONDS, player)
	GameClock.Delay(SPIT_FLIGHT_SECONDS, function()
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

--[ Handlers ]--

-- Every gun shot, the moment it is fired: Evil Eye's count. The Nth is
-- primed.
function Venom.onRangedFire(player: Player, _origin: Vector3, _direction: Vector3, _weaponName: string)
	eyeShotIsPoison[player] = nil
	if not helpers.owns(player, EVIL_EYE) then
		eyeShots[player] = nil
		relicTriggers.set(player, EVIL_EYE, false)
		return
	end
	local needed = helpers.data(EVIL_EYE, "everyShots", 3)
	local count = (eyeShots[player] or 0) + 1
	if count >= needed then
		count = 0
		eyePrimedUntil[player] = GameClock.Now() + PRIME_SECONDS
		eyeShotIsPoison[player] = true
	end
	eyeShots[player] = count
	relicTriggers.set(player, EVIL_EYE, count == needed - 1)
end

-- The colour of the shot onRangedFire just counted: "Poison" for the Eye's
-- (ProjectileCastService sends it with the shot, so every client paints
-- exactly that arrow green), nil otherwise.
function Venom.shotTint(player: Player): string?
	return if eyeShotIsPoison[player] then "Poison" else nil
end

-- A gun shot landed: a primed one deals its bonus and Poisons.
function Venom.onRangedHit(player: Player, model: Model, dealt: number, _wasCrit: boolean)
	local primedUntil = eyePrimedUntil[player]
	if not primedUntil then
		return
	end
	eyePrimedUntil[player] = nil
	if GameClock.Now() > primedUntil or not helpers.owns(player, EVIL_EYE) then
		return
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end
	local bonus = dealt * helpers.data(EVIL_EYE, "bonusDamage", 0.5)
	if bonus > 0 then
		helpers.takeDamage(player, humanoid, bonus, false, false, nil, true)
	end
	helpers.statusService():ApplyStatus(player, model, StatusConditions.Poison, false)
end

-- The gun was put away (a respawn): the count starts over.
function Venom.onWeaponStowed(player: Player, lane: string)
	if lane == "Ranged" then
		eyeShots[player] = nil
		eyePrimedUntil[player] = nil
		eyeShotIsPoison[player] = nil
	end
end

-- A DoT tick the owner dealt (StatusConditionService): Toxic Spit rolls
-- on Poison and Death Venom ticks, once per enemy per tick, and spits at
-- most once per spitCooldown.
function Venom.onStatusTick(player: Player, model: Model, status: string)
	if status ~= StatusConditions.Poison and status ~= StatusConditions.NoxiousVenom then
		return
	end
	if not helpers.owns(player, ZOMBIE_BOMB) then
		return
	end
	local now = GameClock.Now()
	local rolls = lastTickRoll[player] or {}
	lastTickRoll[player] = rolls
	local lastRoll = rolls[model]
	if lastRoll and now - lastRoll < SPIT_TICK_WINDOW_SECONDS then
		return
	end
	rolls[model] = now
	if now - (lastSpitAt[player] or 0) < helpers.data(ZOMBIE_BOMB, "spitCooldown", 0.5) then
		return
	end
	if math.random() < helpers.data(ZOMBIE_BOMB, "tickSpitChance", 0.1) then
		lastSpitAt[player] = now
		lobBubble(player, model)
	end
end

-- Once a second: forget the tick rolls of enemies that are gone.
function Venom.onTick(player: Player)
	local rolls = lastTickRoll[player]
	if not rolls then
		return
	end
	for model in rolls do
		if not model.Parent then
			rolls[model] = nil
		end
	end
end

function Venom.onPlayerRemoved(player: Player)
	lastSpitAt[player] = nil
	lastTickRoll[player] = nil
	eyeShots[player] = nil
	eyePrimedUntil[player] = nil
	eyeShotIsPoison[player] = nil
end

return Venom
