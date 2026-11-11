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
	  Zombie Bomb       ROT EYE (2026-11-10; Toxic Spit's goop bubble
	                    before): every Poison or Death Venom the owner
	                    applies opens an eye over that enemy (unless it has
	                    one, or closed one within `reopenCooldown`, or the
	                    owner has `maxEyes` up). It fires a laser every
	                    `laserInterval` for `eyeSeconds` at the nearest
	                    OTHER enemy (the one it is on when alone), damaging
	                    and Poisoning it, so the Poison spreads and the next
	                    eye opens there. RelicData's row has the numbers.
	                    (Foul Poison Fowl's takedown cloud is in MobDeath.)

	The eye and its lasers are drawn by the clients (helpers.fx RotEye /
	RotLaser); the server owns the timing, the targets and the hits.
	PROTOTYPE visuals until the artist's eye asset is in.
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

-- Rot Eye: how far above the enemy's top the eye floats (the client
-- draws it there too, RelicGimmickFXController ROT_EYE_HEIGHT).
local ROT_EYE_HEIGHT = 2.5
-- Evil Eye: how long a primed shot waits for its hit.
local PRIME_SECONDS = 1.5

local Venom = {}

-- Rot Eye: the owner's open eyes; [player][model] = when that enemy may
-- open another.
type Eye = { host: Model, closesAt: number, nextShotAt: number }
local eyesOf: { [Player]: { Eye } } = {}
local reopenAt: { [Player]: { [Model]: number } } = {}
-- Evil Eye: gun shots since the last primed one, and when the primed
-- shot lapses.
local eyeShots: { [Player]: number } = {}
local eyePrimedUntil: { [Player]: number } = {}
-- True when the shot onRangedFire just counted is the Eye's poison shot
-- (2026-11-05): ShotTint reads it right after, for the shot's colour.
local eyeShotIsPoison: { [Player]: boolean } = {}

local function isAlive(model: Model): boolean
	if not model.Parent then
		return false
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

-- Where the eye floats: above the enemy's top.
local function eyePosition(model: Model): Vector3?
	local root = getRoot(model)
	if not root then
		return nil
	end
	local box, size = model:GetBoundingBox()
	return Vector3.new(root.Position.X, box.Position.Y + size.Y / 2 + ROT_EYE_HEIGHT, root.Position.Z)
end

local function hasEyeOn(player: Player, model: Model): boolean
	local eyes: { Eye } = eyesOf[player] or {}
	for _, eye in eyes do
		if eye.host == model then
			return true
		end
	end
	return false
end

local function openEye(player: Player, host: Model): boolean
	local eyes = eyesOf[player] or {}
	eyesOf[player] = eyes
	if #eyes >= helpers.data(ZOMBIE_BOMB, "maxEyes", 3) then
		return false
	end
	local position = eyePosition(host)
	if not position then
		return false
	end
	local now = GameClock.Now()
	local windup = helpers.data(ZOMBIE_BOMB, "eyeWindup", 0.4)
	local life = helpers.data(ZOMBIE_BOMB, "eyeSeconds", 3)
	table.insert(eyes, { host = host, closesAt = now + windup + life, nextShotAt = now + windup })
	helpers.fx("RotEye", position, position, 0, windup + life, player, host)
	return true
end

-- One laser from `host`'s eye: the nearest other living enemy in range,
-- else the host itself.
local function fireLaser(player: Player, host: Model)
	local from = eyePosition(host)
	if not from then
		return
	end
	local target: Model? = nil
	local best = math.huge
	forEachEnemyInRadius(from, helpers.data(ZOMBIE_BOMB, "laserRange", 15), function(model: Model)
		if model == host then
			return
		end
		local root = getRoot(model)
		local distance = if root then (root.Position - from).Magnitude else math.huge
		if distance < best then
			best = distance
			target = model
		end
	end)
	local chosen: Model = target or host
	local targetRoot = getRoot(chosen)
	local humanoid = chosen:FindFirstChildOfClass("Humanoid")
	if not targetRoot or not humanoid or humanoid.Health <= 0 then
		return
	end
	helpers.fx("RotLaser", from, targetRoot.Position, 0, 0, player, chosen)
	helpers.hitBreakables(player, targetRoot.Position, helpers.POINT_BREAK_RADIUS)
	local damage = helpers.levelDamage(player, helpers.data(ZOMBIE_BOMB, "damagePerLevel", 20))
	-- Untyped relic lane, like every relic burst.
	helpers.takeDamage(player, humanoid, damage, false, false, nil, true)
	helpers.statusService():ApplyStatus(player, chosen, StatusConditions.Poison)
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

-- A status the owner applied (StatusConditionService): their Poison or
-- Death Venom opens an eye over that enemy.
function Venom.onStatusApplied(player: Player, model: Model, status: string)
	if status ~= StatusConditions.Poison and status ~= StatusConditions.NoxiousVenom then
		return
	end
	if not helpers.owns(player, ZOMBIE_BOMB) or hasEyeOn(player, model) or not isAlive(model) then
		return
	end
	local waits = reopenAt[player]
	if waits and waits[model] and GameClock.Now() < waits[model] then
		return
	end
	openEye(player, model)
end

-- Every frame: each open eye fires on its rhythm, and closes when its
-- time is up or its enemy dies.
function Venom.onHeartbeat(now: number)
	for player, eyes in eyesOf do
		local owns = player.Parent ~= nil and helpers.owns(player, ZOMBIE_BOMB)
		for index = #eyes, 1, -1 do
			local eye = eyes[index]
			local alive = isAlive(eye.host)
			if owns and alive then
				while eye.nextShotAt <= now and eye.nextShotAt < eye.closesAt do
					eye.nextShotAt += helpers.data(ZOMBIE_BOMB, "laserInterval", 1)
					fireLaser(player, eye.host)
				end
			end
			if not owns or not alive or now >= eye.closesAt then
				table.remove(eyes, index)
				if alive then
					local waits = reopenAt[player] or {}
					reopenAt[player] = waits
					waits[eye.host] = now + helpers.data(ZOMBIE_BOMB, "reopenCooldown", 5)
				end
			end
		end
		if #eyes == 0 then
			eyesOf[player] = nil
		end
	end
end

local function forgetGone(byModel: { [Model]: any }?)
	if byModel then
		for model in byModel do
			if not model.Parent then
				byModel[model] = nil
			end
		end
	end
end

-- Once a second: forget the waits of enemies that are gone.
function Venom.onTick(player: Player)
	forgetGone(reopenAt[player])
end

function Venom.onPlayerRemoved(player: Player)
	eyesOf[player] = nil
	reopenAt[player] = nil
	eyeShots[player] = nil
	eyePrimedUntil[player] = nil
	eyeShotIsPoison[player] = nil
end

return Venom
