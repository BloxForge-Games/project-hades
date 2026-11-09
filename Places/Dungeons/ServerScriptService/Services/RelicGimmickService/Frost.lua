--!strict
--[[
	Module: RelicGimmickService/Frost
	Description:
	Frost's gimmick epics (Magic / Chill). Their hits are ARCANE damage, so
	every Arcane relic amplifies them, they can crit, and each one calls
	Icy Arctic Fowl's shard. The wyrm's orbs always Chill.

	  Ice Dragon Slayer   FROST WYRM: a frost wyrm hovers above your shoulder
	                      for as long as you hold the relic. Every
	                      `breathInterval` it fires a frost orb that HOMES on
	                      the nearest enemy in range (2026-11-05: its blast on
	                      each Spell left). It bursts (`orbRadius`), Chills,
	                      and deals `chilledMultiplier` x to an enemy already
	                      Chilled.
	  Icy Arctic Fowl     BLIZZARD (2026-11-05; a Spell's hits only before):
	                      every ARCANE hit of yours -- a spell, the wyrm, a
	                      Frost Zone, an Ice Arrow, a Paintball -- sends a
	                      homing ice shard at the enemy it hit, bursting
	                      (`burstRadius`); a Chilled enemy takes
	                      `chilledMultiplier` x. The shards deal REGULAR
	                      (relic-lane) damage, so they never call more.
	  Frozen Blue Ice     ICE ARROW: every `everyHits`-th ranged shot fires
	  Crossbow            one after the shot (relicShots follow); it deals
	                      Arcane Damage (2026-11-05) and Chills.
	  Staff of Azure      FROST ZONE (2026-10-30; the Mage Staff's field
	  Ever Ice            until then): a Spell's first hit leaves a zone of
	                      ice there for `zoneSeconds`; zones from earlier
	                      casts stay. Each Chills an enemy inside at most
	                      once every `chillEvery` seconds and deals its
	                      per-level Arcane damage every second. (Its +35%
	                      Chill slow is a StatusConditionData row.)
	  Korblox Mage Staff  ICE GLYPH (2026-10-30): worn while Frostburst
	                      (Lib/azureGlyph). Its +30% Arcane Damage and +35%
	                      Chill chance on Spells while Frostburst live in
	                      DamageService/AuraDamage and StatusConditionService.
	  Frozen Blue Ice     ICE ARROW (2026-11-01, the tree's enabler): every
	  Crossbow            `everyHits`-th gun SHOT (2026-11-04; landed hits
	                      before) fires an arrow WITH the shot, straight
	                      along its aim (Lib/relicShots, no homing): the
	                      first mob it flies into takes per-level relic
	                      damage and a Chill; a wall stops it for nothing.
	                      An arrow that damages a mob also restores
	                      `manaFraction` of max Mana, once (2026-11-05).

	The clients draw everything (helpers.fx); the server only aims, waits
	out each flight and lands the hits where the packet said they land.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local AuraNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.AuraNames)
local StatusConditions = require(ReplicatedStorage.Submodules.Core.Shared.Enums.StatusConditions)
local getRoot = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Character.getRoot)
local forEachEnemyInRadius = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Combat.forEachEnemyInRadius)
local snapToGround = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Combat.snapToGround)
local helpers = require(script.Parent.Lib.gimmickHelpers)
local relicTriggers = require(script.Parent.Lib.relicTriggers)
local relicShots = require(script.Parent.Lib.relicShots)
local azureGlyph = require(script.Parent.Lib.azureGlyph)
local GameClock = require(ReplicatedStorage.Submodules.Core.Shared.GameClock)

local WYRM = RelicNames["Ice Dragon Slayer"]
local FOWL = RelicNames["Icy Arctic Fowl"]
local CROSSBOW = RelicNames["Frozen Blue Ice Crossbow"]
-- The Ice Arrow's beat, the Magenta Paintball's (2026-11-08): the arrow
-- leaves ICE_ARROW_DELAY after the shot that sets it off, and the shooter's
-- draw starts ICE_ARROW_DRAW_AT after that shot, so its release meets it.
local ICE_ARROW_DELAY = 0.5
local ICE_ARROW_DRAW_AT = 0.1
local STAFF = RelicNames["Korblox Mage Staff"]
local AZURE = RelicNames["Staff of Azure Ever Ice"]

-- Frost Wyrm: where its orbs start in its caster's frame (about where
-- the client's wyrm floats) and its reach.
local WYRM_OFFSET = CFrame.new(-3.5, 6, 3)
local WYRM_RANGE = 25
-- The periodic orb bursts once it is this close to its target's root, and
-- gives up (bursting where it is) after ORB_MAX_SECONDS.
local ORB_CONTACT_STUDS = 2.5
local ORB_MAX_SECONDS = 1.5

-- The wyrm is permanent while held: the client keeps it this long past
-- each once-a-second re-send.
local WYRM_KEEPALIVE_SECONDS = 2

-- Blizzard: the shards' homing flight is the Fowl's data (shardSpeed ...).
-- Where a cast's shards appear, in turn, in the caster's frame: right,
-- left, above the head.
local SHARD_SPAWN_OFFSETS = {
	Vector3.new(2.5, 1.5, 0),
	Vector3.new(-2.5, 1.5, 0),
	Vector3.new(0, 4, 0),
}

-- Frost Zone: how often it looks for enemies inside.
local FIELD_SCAN_SECONDS = 0.25

-- Ice Arrow (2026-11-04): its studs a game second.
local ARROW_SPEED = 90

local Frost = {}

type Wyrm = { expiresAt: number, nextBreath: number }
local wyrms: { [Player]: Wyrm } = {}
-- Frozen Blue Ice Crossbow: gun shots since the last arrow.
local crossbowHits: { [Player]: number } = {}
-- Mage Staff: [player][spell] = a field is still owed by that cast.
local pendingFields: { [Player]: { [string]: boolean } } = {}
-- Icy Arctic Fowl: how many shards each player has sent (picks the next
-- spawn offset).
local fowlShardsSent: { [Player]: number } = {}
-- One arcane hit from a Frost gimmick: damage, a guaranteed Chill when
-- `chills`, and the arcane on-hit appliers (not a cast, so the spell-only
-- rows stay out).
local function frostHit(player: Player, model: Model, humanoid: Humanoid, damage: number, chills: boolean)
	helpers.takeDamage(player, humanoid, damage, true, false, false)
	local statusService = helpers.statusService()
	if chills then
		statusService:ApplyStatus(player, model, StatusConditions.Chill)
	end
	statusService:ApplyArcaneOnHitStatuses(player, model, false)
end

-- A frost burst of `radius` at `position`, now.
-- `chilledMultiplier` (Icy Arctic Fowl, 2026-10-31): an enemy already
-- Chilled takes the burst that many times over.
local function burstAt(
	player: Player,
	position: Vector3,
	radius: number,
	damage: number,
	chills: boolean,
	chilledMultiplier: number?,
	regular: boolean?
)
	helpers.hitBreakables(player, position, radius)
	local statusService = if chilledMultiplier then helpers.statusService() else nil
	forEachEnemyInRadius(position, radius, function(model: Model, humanoid: Humanoid)
		local amount = damage
		if statusService and chilledMultiplier and statusService:IsStatusActive(model, StatusConditions.Chill) then
			amount = damage * chilledMultiplier
		end
		if regular then
			-- Regular (relic-lane) damage, not Arcane: an Icy Arctic Fowl shard,
			-- so it never calls another shard (2026-11-05).
			helpers.takeDamage(player, humanoid, amount, false, false, false, true)
		else
			frostHit(player, model, humanoid, amount, chills)
		end
	end)
end

--[ Frost Wyrm ]--

-- The periodic orb: homes on the nearest enemy in WYRM_RANGE and bursts on
-- it, or where it last was if it dies first.
local function fireOrb(player: Player, root: BasePart)
	local from = (root.CFrame * WYRM_OFFSET).Position
	local nearest: BasePart? = nil
	local nearestModel: Model? = nil
	local nearestDistance = math.huge
	forEachEnemyInRadius(root.Position, WYRM_RANGE, function(model: Model)
		local targetRoot = getRoot(model)
		local distance = if targetRoot then (targetRoot.Position - root.Position).Magnitude else math.huge
		if targetRoot and distance < nearestDistance then
			nearest, nearestModel, nearestDistance = targetRoot, model, distance
		end
	end)
	if not nearest then
		return
	end
	local targetRoot: BasePart = nearest
	local speed = helpers.data(WYRM, "orbSpeed", 55)
	local radius = helpers.data(WYRM, "orbRadius", 5)
	local damage = helpers.levelDamage(player, helpers.data(WYRM, "damagePerLevel", 15))
	local chilledMultiplier = helpers.data(WYRM, "chilledMultiplier", 1.5)
	-- Duration is only the client's estimate; both sides home the same way.
	helpers.fx(
		"FrostOrb",
		from,
		targetRoot.Position,
		radius,
		(targetRoot.Position - from).Magnitude / speed,
		player,
		nearestModel
	)
	task.spawn(function()
		local position = from
		local aim = targetRoot.Position
		local launched = GameClock.Now()
		while player.Parent do
			local deltaTime = GameClock.Dt(RunService.Heartbeat:Wait())
			local humanoid = nearestModel and nearestModel:FindFirstChildOfClass("Humanoid")
			if targetRoot.Parent and humanoid and humanoid.Health > 0 then
				aim = targetRoot.Position
			end
			local gap = aim - position
			local step = speed * deltaTime
			if gap.Magnitude <= step + ORB_CONTACT_STUDS then
				burstAt(player, aim, radius, damage, true, chilledMultiplier)
				return
			end
			position += gap.Unit * step
			if GameClock.Now() - launched >= ORB_MAX_SECONDS then
				burstAt(player, position, radius, damage, true, chilledMultiplier)
				return
			end
		end
	end)
end

--[ Frost Field ]--

local function spawnField(player: Player, position: Vector3)
	local ground = snapToGround(position, { mapOnly = true }) or position
	local radius = helpers.data(AZURE, "zoneRadius", 8)
	local seconds = helpers.data(AZURE, "zoneSeconds", 5)
	local chillEvery = helpers.data(AZURE, "chillEvery", 2)
	local damage = helpers.levelDamage(player, helpers.data(AZURE, "damagePerLevel", 15))
	helpers.fx("FrostField", ground, nil, radius, seconds)

	local lastChill: { [Model]: number } = {}
	task.spawn(function()
		local endsAt = GameClock.Now() + seconds
		-- First tick as the zone lands, so a 5 s zone deals 5 ticks (it
		-- dealt 4 when the first waited a second; audit 2026-10-30).
		local nextDamageAt = GameClock.Now()
		while GameClock.Now() < endsAt and player.Parent do
			local now = GameClock.Now()
			local statusService = helpers.statusService()
			local damageTick = now >= nextDamageAt
			if damageTick then
				nextDamageAt += 1
				helpers.hitBreakables(player, ground, radius)
			end
			forEachEnemyInRadius(ground, radius, function(model: Model, humanoid: Humanoid)
				if damageTick and damage > 0 then
					helpers.takeDamage(player, humanoid, damage, true, false, false)
				end
				if lastChill[model] and now - lastChill[model] < chillEvery then
					return
				end
				lastChill[model] = now
				statusService:ApplyStatus(player, model, StatusConditions.Chill)
			end)
			GameClock.Wait(FIELD_SCAN_SECONDS)
		end
	end)
end

--[ Blizzard ]--

-- One shard's homing flight (the Fowl's data; the clients fly the same
-- curve): it leaves rising and turning toward `target`, eases its
-- velocity toward it every frame, and bursts on contact, or where it is
-- once its time is up.
local function flyShard(player: Player, from: Vector3, target: BasePart, radius: number, damage: number)
	local speed = helpers.data(FOWL, "shardSpeed", 48)
	local turnRate = helpers.data(FOWL, "shardTurnRate", 7)
	local contact = helpers.data(FOWL, "shardContact", 2.5)
	local maxSeconds = helpers.data(FOWL, "shardMaxSeconds", 2.5)
	local chilledMultiplier = helpers.data(FOWL, "chilledMultiplier", 2)
	local aim = target.Position
	local flat = Vector3.new(aim.X - from.X, 0, aim.Z - from.Z)
	local velocity = Vector3.new(0, helpers.data(FOWL, "shardLaunchUp", 9), 0)
		+ (if flat.Magnitude > 0.05 then flat.Unit * speed * 0.5 else Vector3.zero)
	task.spawn(function()
		-- It hangs where it appeared while it fades in.
		GameClock.Wait(helpers.data(FOWL, "shardFadeIn", 0.15))
		local position = from
		local flown = 0
		while player.Parent do
			local deltaTime = GameClock.Dt(RunService.Heartbeat:Wait())
			flown += deltaTime
			local model = target.Parent
			local humanoid = model and model:FindFirstChildOfClass("Humanoid")
			if model and humanoid and humanoid.Health > 0 then
				aim = target.Position
			end
			local gap = aim - position
			if gap.Magnitude <= contact or flown >= maxSeconds then
				burstAt(player, position, radius, damage, false, chilledMultiplier, true)
				return
			end
			velocity = velocity:Lerp(gap.Unit * speed, 1 - math.exp(-turnRate * deltaTime))
			position += velocity * deltaTime
		end
	end)
end

--[ Ice Arrow ]--

-- An Ice Arrow that damaged a mob restores manaFraction of max Mana.
local function restoreCrossbowMana(player: Player)
	local arcaneService = helpers.service("ArcaneService")
	local data = arcaneService:GetPlayerArcaneData(player)
	if not data or not data.maxMana or data.mana >= data.maxMana then
		return
	end
	local fraction = helpers.data(CROSSBOW, "manaFraction", 0.05)
	arcaneService:SetPlayerArcaneData(player, math.min(data.mana + data.maxMana * fraction, data.maxMana), data.maxMana)
end

-- The arrow landed on `target` (nil: a wall, or the end of its range):
-- damagePerLevel x the Power factor on the relic lane (2026-11-02; a share
-- of the hit on the gun lane before), then a Chill outright.
local function iceArrowHit(player: Player, target: Model?)
	local humanoid = target and target:FindFirstChildOfClass("Humanoid")
	if not target or not humanoid or humanoid.Health <= 0 then
		return
	end
	local damage = helpers.levelDamage(player, helpers.data(CROSSBOW, "damagePerLevel", 10))
	-- Arcane Damage (2026-11-05; the relic lane before): Frostburst and
	-- Forbidden Box raise it, and it calls Icy Arctic Fowl's shard.
	helpers.takeDamage(player, humanoid, damage, true, false, false)
	helpers.statusService():ApplyStatus(player, target, StatusConditions.Chill, true)
	-- One arrow, one target: the Mana is paid once.
	if damage > 0 then
		restoreCrossbowMana(player)
	end
end

--[ Handlers ]--

-- Every gun shot, the moment it is fired: the crossbow's count. The Nth
-- fires the arrow with it.
function Frost.onRangedFire(player: Player, origin: Vector3, direction: Vector3, weaponName: string)
	if not helpers.owns(player, CROSSBOW) then
		crossbowHits[player] = nil
		relicTriggers.set(player, CROSSBOW, false)
		return
	end
	local needed = helpers.data(CROSSBOW, "everyHits", 4)
	local count = (crossbowHits[player] or 0) + 1
	if count >= needed then
		count = 0
		-- The shooter's draw now (their client waits Duration from the
		-- server's StartTime); the arrow ICE_ARROW_DELAY later, on the
		-- bow's own arc off a bow (relicShots follow).
		helpers.fx("IceArrowDraw", origin, origin, 0, ICE_ARROW_DRAW_AT, player)
		relicShots.fire(player, "IceArrowShot", origin, direction, weaponName, ARROW_SPEED, function(_, target)
			iceArrowHit(player, target)
		end, true, ICE_ARROW_DELAY)
	end
	crossbowHits[player] = count
	relicTriggers.set(player, CROSSBOW, count == needed - 1)
end

-- The gun was put away: the crossbow's count starts over.
function Frost.onWeaponStowed(player: Player, lane: string)
	if lane == "Ranged" then
		crossbowHits[player] = nil
	end
end

function Frost.onSpellCast(player: Player, vfxName: string, _castCFrame: CFrame?)
	if helpers.owns(player, AZURE) then
		local pending = pendingFields[player] or {}
		pendingFields[player] = pending
		pending[vfxName] = true
	end
	-- (Ice Dragon Slayer's blast with each Spell left 2026-11-05: it blasts
	-- every 1.5s only. Icy Arctic Fowl answers every Arcane hit now,
	-- onAttackHit.)
end

-- Icy Arctic Fowl (2026-11-05; a Spell's hits only before): every ARCANE
-- hit sends a homing shard at the enemy it hit -- a spell, the Frost Dragon,
-- the Frost Zone, an Ice Arrow, a Paintball. The shards deal regular damage,
-- so they never call more shards.
function Frost.onAttackHit(player: Player, model: Model, isMagic: boolean)
	if not isMagic or not helpers.owns(player, FOWL) then
		return
	end
	local targetRoot = getRoot(model)
	local liveRoot = getRoot.fromPlayer(player)
	if not targetRoot or not liveRoot then
		return
	end
	local sent = (fowlShardsSent[player] or 0) + 1
	fowlShardsSent[player] = sent
	local radius = helpers.data(FOWL, "burstRadius", 6)
	local damage = helpers.levelDamage(player, helpers.data(FOWL, "damagePerLevel", 5))
	local offset = SHARD_SPAWN_OFFSETS[(sent - 1) % #SHARD_SPAWN_OFFSETS + 1]
	local from = (liveRoot.CFrame * CFrame.new(offset)).Position
	helpers.fx("IceShard", from, targetRoot.Position, radius, nil, player, model)
	flyShard(player, from, targetRoot, radius, damage)
end

function Frost.onSpellHit(player: Player, vfxName: string, model: Model)
	local pending = pendingFields[player]
	if not pending or not pending[vfxName] then
		return
	end
	pending[vfxName] = nil
	local root = getRoot(model)
	if root then
		spawnField(player, root.Position)
	end
end

-- Every frame: the wyrms' periodic orbs and lifetimes.
function Frost.onHeartbeat(now: number)
	for player, wyrm in wyrms do
		local root = getRoot.fromPlayer(player)
		if now >= wyrm.expiresAt or not root then
			wyrms[player] = nil
		elseif now >= wyrm.nextBreath then
			wyrm.nextBreath = now + helpers.data(WYRM, "breathInterval", 1.5)
			fireOrb(player, root)
		end
	end
end

-- Once a second per player: Korblox Mage Staff's Ice Glyph kept in step
-- with Frostburst (worn while it is up), then the wyrm.
function Frost.onTick(player: Player)
	local character = player.Character
	local glyphRoot = getRoot.fromPlayer(player)
	if character and glyphRoot then
		local glyph = azureGlyph.find(character)
		local owns = helpers.owns(player, STAFF) and glyphRoot:FindFirstChild(AuraNames.Frostburst) ~= nil
		if owns and not glyph then
			azureGlyph.spawn(character, glyphRoot)
		elseif glyph and not owns then
			azureGlyph.dismiss(glyph)
		end
	end

	-- Ice Dragon Slayer: the wyrm is up for as long as the relic is held.
	if glyphRoot and helpers.owns(player, WYRM) then
		local wyrm = wyrms[player]
		if not wyrm then
			wyrm = { expiresAt = 0, nextBreath = GameClock.Now() + 0.5 }
			wyrms[player] = wyrm
		end
		wyrm.expiresAt = GameClock.Now() + WYRM_KEEPALIVE_SECONDS
		helpers.fx("WyrmSummon", glyphRoot.Position, nil, nil, WYRM_KEEPALIVE_SECONDS, player)
	end
end

function Frost.onPlayerRemoved(player: Player)
	wyrms[player] = nil
	fowlShardsSent[player] = nil
	pendingFields[player] = nil
	crossbowHits[player] = nil
end

return Frost
