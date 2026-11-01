--!strict
--[[
	Module: RelicGimmickService/Earth
	Description:
	Earth's gimmick epic (Tank / Barrier). Its damage rides the untyped
	relic lane like every relic burst.

	  Spartan Sword and    PHALANX (2026-10-30): while Stonebound, `shields`
	  Shield               stone shields orbit you; an enemy one passes
	                       takes per-level damage and gives you a
	                       `barrierPercent` Barrier for `barrierSeconds`.
	                       (Its Stonebound-on-cast stays in ShieldService.)

	The shields' angle is a function of the server clock
	(GetServerTimeNow), so the clients (RelicGimmickFXController) draw it
	exactly where it hits; the server only re-sends that it is still up.
	(Golden Steampunk Gloves' Shockwave Fist lived here until 2026-10-29;
	the relic is a Barriered damage bonus again, DamageService/AuraDamage.)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local getRoot = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Character.getRoot)
local forEachEnemyInRadius = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Combat.forEachEnemyInRadius)
local helpers = require(script.Parent.Lib.gimmickHelpers)

local SPARTAN = RelicNames["Spartan Sword and Shield"]
local GLOVES = RelicNames["Golden Steampunk Gloves"]

local ORBIT_HIT_RADIUS = 2.5
-- The client keeps a shield this long past each re-send (sent once a
-- second while it is up).
local ORBIT_KEEPALIVE_SECONDS = 1.5

local Earth = {}

type Orbit = {
	lastHit: { [Model]: number },
	lastBarrier: number,
	-- Breakables hit since breakReset; cleared every hitCooldown, so the
	-- shield chips a breakable once per pass like a mob.
	breakSeen: { [Instance]: boolean },
	breakReset: number,
}
local orbits: { [Player]: Orbit } = {}

local function shieldService(): any
	return helpers.service("ShieldService")
end

--[ Phalanx ]--

-- `shields` slabs evenly spaced round the orbit, at the server clock's
-- angle (the client draws the same: RelicGimmickFXController).
local function shieldOffsets(): { Vector3 }
	local radius = helpers.data(SPARTAN, "orbitRadius", 9)
	local secondsPerTurn = helpers.data(SPARTAN, "orbitSecondsPerTurn", 2.6)
	local count = helpers.data(SPARTAN, "shields", 2)
	local base = (workspace:GetServerTimeNow() / secondsPerTurn) * math.pi * 2
	local offsets = {}
	for index = 0, count - 1 do
		local angle = base + index * (math.pi * 2 / count)
		table.insert(offsets, Vector3.new(math.cos(angle), 0, math.sin(angle)) * radius)
	end
	return offsets
end

function Earth.onHeartbeat(now: number)
	local offsets = shieldOffsets()
	for player, orbit in orbits do
		local root = getRoot.fromPlayer(player)
		if not root or not helpers.owns(player, SPARTAN) then
			orbits[player] = nil
			continue
		end
		local damage = helpers.levelDamage(player, helpers.data(SPARTAN, "damagePerLevel", 10))
		local hitCooldown = helpers.data(SPARTAN, "hitCooldown", 0.75)
		if now - orbit.breakReset >= hitCooldown then
			orbit.breakReset = now
			table.clear(orbit.breakSeen)
		end
		for _, offset in offsets do
			local position = root.Position + offset
			helpers.hitBreakables(player, position, ORBIT_HIT_RADIUS, orbit.breakSeen)
			forEachEnemyInRadius(position, ORBIT_HIT_RADIUS, function(model: Model, humanoid: Humanoid)
				if orbit.lastHit[model] and now - orbit.lastHit[model] < hitCooldown then
					return
				end
				orbit.lastHit[model] = now
				helpers.takeDamage(player, humanoid, damage, false, false, nil, true)
				if now - orbit.lastBarrier >= helpers.data(SPARTAN, "barrierCooldown", 0.5) then
					orbit.lastBarrier = now
					shieldService():GrantShield(
						player,
						player,
						helpers.data(SPARTAN, "barrierPercent", 0.05),
						helpers.data(SPARTAN, "barrierSeconds", 3)
					)
				end
			end)
		end
	end
end

-- Once a second: Spartan owners get (or keep) their shields (2026-10-31;
-- they orbited only while Stonebound before).
function Earth.onTick(player: Player)
	if not helpers.owns(player, SPARTAN) then
		return
	end
	local root = getRoot.fromPlayer(player)
	if not root then
		return
	end
	if not orbits[player] then
		orbits[player] = { lastHit = {}, lastBarrier = 0, breakSeen = {}, breakReset = 0 }
	end
	helpers.fx("OrbitShield", root.Position, nil, nil, ORBIT_KEEPALIVE_SECONDS, player)
end

-- A weapon hit by `player` (DamageService): Golden Steampunk Gloves'
-- Barrier roll (ShieldService owns the chance, size and cooldown).
function Earth.onAttackHit(player: Player, _model: Model, isMagic: boolean)
	if isMagic or not helpers.owns(player, GLOVES) then
		return
	end
	shieldService():TryGoldenGlovesBarrier(player)
end

function Earth.onPlayerRemoved(player: Player)
	orbits[player] = nil
end

return Earth
