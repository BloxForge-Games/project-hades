--!strict
--[[
	Module: RelicGimmickService/Blaze
	Description:
	Blaze's gimmick epics (Weapon / Burn):

	  Dragon's Flame Sword  FLAME WAVE: every Nth melee swing (N by weapon
	                        type: Daggers 4, Sword 3, Greatsword 2, so the
	                        faster weapons wait longer) launches a
	                        crescent of fire along the swing's facing. It
	                        deals a share of the swing's damage as MELEE
	                        weapon damage (crits, weapon relics, on-hit
	                        statuses), more to Burning enemies.
	  Berserker's Claymore  INFERNO CLEAVE: a melee hit erupts in fire
	                        around its target, splashing a share of the hit
	                        to the enemies around it as melee weapon damage,
	                        doubled on Burning ones. Once per swing (the
	                        first mob it damages).
	  Phoenix               PHOENIX DASH: a dodge leaves a fire trail along
	                        its path; every second it Burns and damages the
	                        enemies on it (a per-level relic burst).

	  Flame Ronin Katana    DETONATE: a Critical Hit on an enemy you have
	                        Black-Flamed sets the burn off at once.
	  Red Laser Scythe      SWING SPEED (2026-10-30): while Enflamed, the
	                        character's MeleeSwingSpeed attribute (both
	                        MeleeWeapon halves pace swings by it).

	The numbers are each relic's RelicData `data`. Trick Or Trap lives where
	it always did (MobDeath). Every visual is a helpers.fx packet the
	clients draw; only the hits run here.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local AuraNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.AuraNames)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local StatusConditions = require(ReplicatedStorage.Submodules.Core.Shared.Enums.StatusConditions)
local getRoot = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Character.getRoot)
local forEachEnemyInRadius = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Combat.forEachEnemyInRadius)
local helpers = require(script.Parent.Lib.gimmickHelpers)

local FLAME_SWORD = RelicNames["Dragon's Flame Sword"]
local CLAYMORE = RelicNames["Berserker's Claymore"]
local PHOENIX = RelicNames.Phoenix
local RONIN = RelicNames["Flame Ronin Katana"]
local RED_LASER = RelicNames["Red Laser Scythe"]

-- Flame Wave: its travel and its hit width.
local WAVE_SPEED = 55
local WAVE_RANGE = 28
local WAVE_RADIUS = 4.5
-- The wave rides a little below the swinger's root, near the floor.
local WAVE_DROP = 1.5

-- Inferno Cleave's once-per-swing latch.
local CLEAVE_LATCH_SECONDS = 0.15

-- Phoenix Dash: the trail catches mobs within this many studs of the
-- dodge line.
local TRAIL_WIDTH = 3.5

-- Red Laser Scythe's swing speed is re-stamped this often, so Enflamed
-- coming and going shows up within a beat.
local SWING_SPEED_POLL_SECONDS = 0.2

local Blaze = {}

local swingCounts: { [Player]: number } = {}
local lastCleave: { [Player]: number } = {}
local nextSwingSpeedPoll = 0

--[ Flame Wave ]--

local function launchFlameWave(player: Player, origin: Vector3, look: Vector3, swingDamage: number)
	local damage = swingDamage * helpers.data(FLAME_SWORD, "waveDamage", 0.75)
	local start = origin - Vector3.new(0, WAVE_DROP, 0)

	helpers.fx("FlameWave", start, start + look * WAVE_RANGE, nil, WAVE_RANGE / WAVE_SPEED)

	local hit: { [Model]: boolean } = {}
	local hitBreakables: { [Instance]: boolean } = {}
	helpers.sweep(start, look, WAVE_SPEED, WAVE_RANGE, function(position: Vector3)
		helpers.hitBreakables(player, position, WAVE_RADIUS, hitBreakables)
		forEachEnemyInRadius(position, WAVE_RADIUS, function(model: Model, humanoid: Humanoid)
			if hit[model] then
				return
			end
			hit[model] = true
			-- The wave Burns outright (2026-10-31; it paid +50% vs Burning
			-- before) and still rolls the weapon appliers like any hit.
			local statusService = helpers.statusService()
			helpers.takeDamage(player, humanoid, damage, false, false, true)
			statusService:ApplyStatus(player, model, StatusConditions.Burn)
			statusService:ApplyWeaponOnHitStatuses(player, nil, model, false)
		end)
	end)
end

function Blaze.onMeleeSwing(
	player: Player,
	origin: Vector3,
	look: Vector3,
	swingDamage: number,
	_connected: boolean,
	weaponType: string?
)
	if not helpers.owns(player, FLAME_SWORD) then
		return
	end
	local count = (swingCounts[player] or 0) + 1
	if count >= helpers.swingsFor(FLAME_SWORD, weaponType) then
		count = 0
		launchFlameWave(player, origin, look, swingDamage)
	end
	swingCounts[player] = count
end

--[ Inferno Cleave ]--

-- One cleave around `model` for a melee hit that dealt `damage`: every
-- OTHER enemy within splashRadius takes splashFraction of it as melee
-- weapon damage, burningMultiplier times when that enemy is Burning. No
-- status of its own (2026-10-31). Latched per swing so a cleave through
-- three mobs splashes once.
local function cleave(player: Player, model: Model, damage: number)
	if not helpers.owns(player, CLAYMORE) then
		return
	end
	local now = os.clock()
	if lastCleave[player] and now - lastCleave[player] < CLEAVE_LATCH_SECONDS then
		return
	end
	lastCleave[player] = now

	local targetRoot = getRoot(model)
	if not targetRoot then
		return
	end
	local radius = helpers.data(CLAYMORE, "splashRadius", 7)
	local splash = damage * helpers.data(CLAYMORE, "splashFraction", 0.35)
	local burningMultiplier = helpers.data(CLAYMORE, "burningMultiplier", 2)
	helpers.fx("FireBurst", targetRoot.Position, nil, radius)
	helpers.hitBreakables(player, targetRoot.Position, radius)

	local statusService = helpers.statusService()
	forEachEnemyInRadius(targetRoot.Position, radius, function(other: Model, humanoid: Humanoid)
		if other == model then
			return
		end
		local amount = if statusService:IsBurning(other) then splash * burningMultiplier else splash
		helpers.takeDamage(player, humanoid, amount, false, false, true)
	end)
end

function Blaze.onMeleeHit(player: Player, model: Model, damage: number)
	cleave(player, model, damage)
end

--[ Flame Ronin Katana: Detonate ]--

-- A Critical Hit on an enemy the owner has Black-Flamed detonates it: the
-- burn's remaining damage at once (StatusConditionService).
function Blaze.onCrit(player: Player, model: Model, _isMelee: boolean)
	if helpers.owns(player, RONIN) then
		helpers.statusService():DetonateBlackFlame(player, model)
	end
end

--[ Phoenix Dash ]--

function Blaze.onDodge(player: Player, from: Vector3, to: Vector3)
	if not helpers.owns(player, PHOENIX) then
		return
	end
	local seconds = helpers.data(PHOENIX, "trailSeconds", 3)
	local damage = helpers.levelDamage(player, helpers.data(PHOENIX, "damagePerLevel", 10))

	local flat = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
	local length = flat.Magnitude
	helpers.fx("PhoenixTrail", from, to, nil, seconds)

	-- A tick right away, then once a second until the trail is out.
	local mid = from:Lerp(to, 0.5)
	local reach = length / 2 + TRAIL_WIDTH
	local function burnTick()
		-- Breakables along the trail: a few points down its line.
		local seen: { [Instance]: boolean } = {}
		for step = 0, 4 do
			helpers.hitBreakables(player, from:Lerp(to, step / 4), TRAIL_WIDTH, seen)
		end
		local statusService = helpers.statusService()
		forEachEnemyInRadius(mid, reach, function(model: Model, humanoid: Humanoid)
			local root = getRoot(model)
			if not root or helpers.flatDistanceToSegment(root.Position, from, to) > TRAIL_WIDTH then
				return
			end
			-- Untyped relic lane, like every relic burst.
			helpers.takeDamage(player, humanoid, damage, false, false, nil, true)
			statusService:ApplyStatus(player, model, StatusConditions.Burn)
		end)
	end
	task.spawn(function()
		for _ = 1, math.max(1, math.floor(seconds)) do
			burnTick()
			task.wait(1)
		end
	end)
end

-- Red Laser Scythe (2026-10-30): the character's MeleeSwingSpeed is its
-- data.enflamedSwingSpeed while Enflamed, and unset otherwise. The one
-- writer of Attributes.MeleeSwingSpeed; both MeleeWeapon halves read it.
function Blaze.onHeartbeat(now: number)
	if now < nextSwingSpeedPoll then
		return
	end
	nextSwingSpeedPoll = now + SWING_SPEED_POLL_SECONDS
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = getRoot(character)
		if not character or not root then
			continue
		end
		local speed: number? = nil
		if root:FindFirstChild(AuraNames.Enflamed) and helpers.owns(player, RED_LASER) then
			speed = helpers.data(RED_LASER, "enflamedSwingSpeed", 1.25)
		end
		if character:GetAttribute(Attributes.MeleeSwingSpeed) ~= speed then
			character:SetAttribute(Attributes.MeleeSwingSpeed, speed)
		end
	end
end

function Blaze.onPlayerRemoved(player: Player)
	swingCounts[player] = nil
	lastCleave[player] = nil
end

return Blaze
