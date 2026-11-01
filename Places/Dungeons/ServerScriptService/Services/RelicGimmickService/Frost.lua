--!strict
--[[
	Module: RelicGimmickService/Frost
	Description:
	Frost's gimmick epics (Magic / Chill). Their hits are ARCANE damage, so
	every Arcane relic amplifies them and they can crit. The wyrm's orbs
	always Chill; Blizzard's shards only roll the arcane status chances.

	  Ice Dragon Slayer   FROST WYRM: a frost wyrm hovers above your shoulder
	                      for as long as you hold the relic; every
	                      `breathInterval` it fires a frost orb that HOMES
	                      on the nearest enemy in range at `orbSpeed` and
	                      bursts on it (`orbRadius`), or where it last was
	                      if it dies first (2026-10-30: it flew at a fixed
	                      point, so it landed late, behind a moving mob).
	  Icy Arctic Fowl     BLIZZARD: every second while Frostburst, `volley`
	                      fast ice shards hop from you onto enemies in range
	                      (all of them fly; several can strike one enemy),
	                      each bursting (`burstRadius`).
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
	  Crossbow            `everyHits`-th ranged hit fires an arrow at that
	                      target for `arrowDamage` of what the hit dealt, as
	                      RANGED WEAPON damage, and Chills it outright.

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
local azureGlyph = require(script.Parent.Lib.azureGlyph)

local WYRM = RelicNames["Ice Dragon Slayer"]
local FOWL = RelicNames["Icy Arctic Fowl"]
local CROSSBOW = RelicNames["Frozen Blue Ice Crossbow"]
local STAFF = RelicNames["Korblox Mage Staff"]
local AZURE = RelicNames["Staff of Azure Ever Ice"]

-- Frost Wyrm: where its orbs start in its caster's frame (about where
-- the client's wyrm floats) and its reach.
local WYRM_OFFSET = CFrame.new(-3.5, 6, 3)
local WYRM_RANGE = 25
-- Its homing orb bursts once it is this close to the target's root, and
-- gives up (bursting where it is) after ORB_MAX_SECONDS.
local ORB_CONTACT_STUDS = 2.5
local ORB_MAX_SECONDS = 1.5

-- The wyrm is permanent while held: the client keeps it this long past
-- each once-a-second re-send.
local WYRM_KEEPALIVE_SECONDS = 2

-- Blizzard: shard reach, flight (fast and low -- a quick bezier hop, not
-- a lob) and the beat between the three shards of one volley.
local SHARD_RANGE = 20
local SHARD_FLIGHT_SECONDS = 0.22
local SHARD_STAGGER_SECONDS = 0.08

-- Frost Zone: how often it looks for enemies inside.
local FIELD_SCAN_SECONDS = 0.25

-- Ice Arrow: a quick dart from the owner to the target, and the small
-- frost pop where it lands (the IceShard look).
local ARROW_FLIGHT_SECONDS = 0.18
local ARROW_BURST_RADIUS = 3

local Frost = {}

-- Icy Arctic Fowl: the next volley's time per player (every
-- data.intervalSeconds; 2026-10-31, every second while Frostburst before).
local fowlNextVolley: { [Player]: number } = {}

type Wyrm = { expiresAt: number, nextBreath: number }
local wyrms: { [Player]: Wyrm } = {}
-- Frozen Blue Ice Crossbow: ranged hits since the last arrow, and true
-- while an arrow of the owner's is landing (its own hit is a ranged hit).
local crossbowHits: { [Player]: number } = {}
local arrowLanding: { [Player]: boolean } = {}
-- Mage Staff: [player][spell] = a field is still owed by that cast.
local pendingFields: { [Player]: { [string]: boolean } } = {}
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
	chilledMultiplier: number?
)
	helpers.hitBreakables(player, position, radius)
	local statusService = if chilledMultiplier then helpers.statusService() else nil
	forEachEnemyInRadius(position, radius, function(model: Model, humanoid: Humanoid)
		local amount = damage
		if statusService and chilledMultiplier and statusService:IsStatusActive(model, StatusConditions.Chill) then
			amount = damage * chilledMultiplier
		end
		frostHit(player, model, humanoid, amount, chills)
	end)
end

-- After `seconds`, a frost burst of `radius` at `position`.
local function burstAfter(
	player: Player,
	seconds: number,
	position: Vector3,
	radius: number,
	damage: number,
	chills: boolean,
	chilledMultiplier: number?
)
	task.delay(seconds, function()
		if player.Parent then
			burstAt(player, position, radius, damage, chills, chilledMultiplier)
		end
	end)
end

--[ Frost Wyrm ]--

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

	-- Fly at the target's CURRENT root every frame; its last position once
	-- it is dead or gone.
	task.spawn(function()
		local position = from
		local aim = targetRoot.Position
		local launched = os.clock()
		while player.Parent do
			local deltaTime = RunService.Heartbeat:Wait()
			local humanoid = nearestModel and nearestModel:FindFirstChildOfClass("Humanoid")
			if targetRoot.Parent and humanoid and humanoid.Health > 0 then
				aim = targetRoot.Position
			end
			local gap = aim - position
			local step = speed * deltaTime
			if gap.Magnitude <= step + ORB_CONTACT_STUDS then
				burstAt(player, aim, radius, damage, true)
				return
			end
			position += gap.Unit * step
			if os.clock() - launched >= ORB_MAX_SECONDS then
				burstAt(player, position, radius, damage, true)
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
		local endsAt = os.clock() + seconds
		-- First tick as the zone lands, so a 5 s zone deals 5 ticks (it
		-- dealt 4 when the first waited a second; audit 2026-10-30).
		local nextDamageAt = os.clock()
		while os.clock() < endsAt and player.Parent do
			local now = os.clock()
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
			task.wait(FIELD_SCAN_SECONDS)
		end
	end)
end

--[ Blizzard ]--

-- Three fast shards a second at enemies in range, like Seraphine's
-- passive: every shard flies whether there are three targets or one (they
-- can all land on the same enemy), each bursting where it lands.
local function launchVolley(player: Player, root: BasePart)
	local candidates: { BasePart } = {}
	forEachEnemyInRadius(root.Position, SHARD_RANGE, function(model: Model)
		local targetRoot = getRoot(model)
		if targetRoot then
			table.insert(candidates, targetRoot)
		end
	end)
	if #candidates == 0 then
		return
	end
	local radius = helpers.data(FOWL, "burstRadius", 6)
	local damage = helpers.levelDamage(player, helpers.data(FOWL, "damagePerLevel", 5))
	task.spawn(function()
		for shard = 1, helpers.data(FOWL, "volley", 3) do
			if shard > 1 then
				task.wait(SHARD_STAGGER_SECONDS)
			end
			local liveRoot = getRoot.fromPlayer(player)
			local target = candidates[math.random(#candidates)]
			if not liveRoot or not target.Parent then
				continue
			end
			local from = liveRoot.Position + Vector3.new(0, 2, 0)
			helpers.fx("IceShard", from, target.Position, radius, SHARD_FLIGHT_SECONDS)
			burstAfter(
				player,
				SHARD_FLIGHT_SECONDS,
				target.Position,
				radius,
				damage,
				false,
				helpers.data(FOWL, "chilledMultiplier", 2)
			)
		end
	end)
end

--[ Ice Arrow ]--

-- The Nth ranged hit's arrow at `model`: arrowDamage of what that hit
-- dealt, on the gun-shot lane (not arcane, not melee, not relic-sourced:
-- it crits and picks up the weapon relics like the shot it rode in on),
-- then a Chill outright. The arrow's landing is itself a ranged hit, so
-- `arrowLanding` keeps it out of this counter and arrows never chain.
local function fireIceArrow(player: Player, model: Model, dealt: number)
	local root = getRoot.fromPlayer(player)
	local targetRoot = getRoot(model)
	if not root or not targetRoot then
		return
	end
	local from = root.Position + Vector3.new(0, 2, 0)
	helpers.fx("IceShard", from, targetRoot.Position, ARROW_BURST_RADIUS, ARROW_FLIGHT_SECONDS)
	local damage = dealt * helpers.data(CROSSBOW, "arrowDamage", 0.75)
	task.delay(ARROW_FLIGHT_SECONDS, function()
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		if not player.Parent or not model.Parent or not humanoid or humanoid.Health <= 0 then
			return
		end
		arrowLanding[player] = true
		local ok, err: any = pcall(helpers.takeDamage :: any, player, humanoid, damage, false, false, false)
		arrowLanding[player] = nil
		if not ok then
			error(err, 0)
		end
		helpers.statusService():ApplyStatus(player, model, StatusConditions.Chill, true)
	end)
end

--[ Handlers ]--

-- Every gun shot that lands (DamageService): the crossbow's count.
function Frost.onRangedHit(player: Player, model: Model, dealt: number, _wasCrit: boolean)
	if arrowLanding[player] then
		return
	end
	if not helpers.owns(player, CROSSBOW) then
		crossbowHits[player] = nil
		return
	end
	local count = (crossbowHits[player] or 0) + 1
	if count >= helpers.data(CROSSBOW, "everyHits", 3) then
		count = 0
		if dealt > 0 then
			fireIceArrow(player, model, dealt)
		end
	end
	crossbowHits[player] = count
end

function Frost.onSpellCast(player: Player, vfxName: string)
	if helpers.owns(player, AZURE) then
		local pending = pendingFields[player] or {}
		pendingFields[player] = pending
		pending[vfxName] = true
	end
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

-- Every frame: the wyrms' orbs and lifetimes.
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
-- with Frostburst (worn while it is up), the wyrm, then Blizzard.
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
			wyrm = { expiresAt = 0, nextBreath = os.clock() + 0.5 }
			wyrms[player] = wyrm
		end
		wyrm.expiresAt = os.clock() + WYRM_KEEPALIVE_SECONDS
		helpers.fx("WyrmSummon", glyphRoot.Position, nil, nil, WYRM_KEEPALIVE_SECONDS, player)
	end

	if not helpers.owns(player, FOWL) then
		fowlNextVolley[player] = nil
		return
	end
	local root = getRoot.fromPlayer(player)
	local now = os.clock()
	if root and now >= (fowlNextVolley[player] or 0) then
		fowlNextVolley[player] = now + helpers.data(FOWL, "intervalSeconds", 3)
		launchVolley(player, root)
	end
end

function Frost.onPlayerRemoved(player: Player)
	fowlNextVolley[player] = nil
	wyrms[player] = nil
	pendingFields[player] = nil
	crossbowHits[player] = nil
	arrowLanding[player] = nil
end

return Frost
