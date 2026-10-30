--!strict
--[[
	Module: RelicGimmickService/Frost
	Description:
	Frost's gimmick epics (Magic / Chill). Their hits are ARCANE damage, so
	every Arcane relic amplifies them and they can crit. The wyrm's orbs
	always Chill; Blizzard's shards only roll the arcane status chances.

	  Ice Dragon Slayer   FROST WYRM: casting a Spell summons a frost wyrm
	                      above your shoulder for `seconds`; every
	                      `breathInterval` it fires a slow frost orb at the
	                      nearest enemy in range, which bursts where it
	                      lands (`orbRadius`). Recasting refreshes it.
	  Icy Arctic Fowl     BLIZZARD: every second while Frostburst, a volley
	                      of `volley` ice shards arcs from you onto as many
	                      different nearby enemies, each bursting
	                      (`burstRadius`).
	  Staff of Azure      ICE GLYPH: worn at all times while held (Lib/
	  Ever Ice            azureGlyph). Its doubled Chill chance, longer
	                      Frostburst and Arcane bonus live in
	                      StatusConditionService / AuraService / MoreDamage.
	  Korblox Mage Staff  FROST FIELD: a Spell's first hit leaves a field of
	                      ice there for `fieldSeconds`; fields from earlier
	                      casts stay. Each Chills an enemy inside at most
	                      once every `chillEvery` seconds, so Ice Breaker
	                      Shatters from it are paced, not constant. (Its
	                      stronger Chill slow is a StatusConditionData row.)

	The clients draw everything (helpers.fx); the server only aims, waits
	out each flight and lands the hits where the packet said they land.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

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
local STAFF = RelicNames["Korblox Mage Staff"]
local AZURE = RelicNames["Staff of Azure Ever Ice"]

-- Frost Wyrm: where it hovers in its caster's frame (the client's cube
-- sits here too), its reach and how fast its orb flies.
local WYRM_OFFSET = CFrame.new(-3.5, 7, 2)
local WYRM_RANGE = 25
local ORB_SPEED = 30

-- Blizzard: shard reach and flight.
local SHARD_RANGE = 20
local SHARD_FLIGHT_SECONDS = 0.45

-- Frost Field: how often it looks for enemies inside.
local FIELD_SCAN_SECONDS = 0.25

local Frost = {}

type Wyrm = { expiresAt: number, nextBreath: number }
local wyrms: { [Player]: Wyrm } = {}
-- Mage Staff: [player][spell] = a field is still owed by that cast.
local pendingFields: { [Player]: { [string]: boolean } } = {}

-- One arcane hit from a Frost gimmick: damage, a guaranteed Chill when
-- `chills`, and the arcane on-hit appliers (not a cast, so the spell-only
-- rows stay out).
local function frostHit(player: Player, model: Model, humanoid: Humanoid, damage: number, chills: boolean)
	helpers.damageService():TakeDamage(player, humanoid, damage, true, false, false)
	local statusService = helpers.statusService()
	if chills then
		statusService:ApplyStatus(player, model, StatusConditions.Chill)
	end
	statusService:ApplyArcaneOnHitStatuses(player, model, false)
end

-- After `seconds`, a frost burst of `radius` at `position`.
local function burstAfter(
	player: Player,
	seconds: number,
	position: Vector3,
	radius: number,
	damage: number,
	chills: boolean
)
	task.delay(seconds, function()
		if not player.Parent then
			return
		end
		helpers.hitBreakables(player, position, radius)
		forEachEnemyInRadius(position, radius, function(model: Model, humanoid: Humanoid)
			frostHit(player, model, humanoid, damage, chills)
		end)
	end)
end

--[ Frost Wyrm ]--

local function fireOrb(player: Player, root: BasePart)
	local from = (root.CFrame * WYRM_OFFSET).Position
	local nearest: BasePart? = nil
	local nearestDistance = math.huge
	forEachEnemyInRadius(root.Position, WYRM_RANGE, function(model: Model)
		local targetRoot = getRoot(model)
		local distance = if targetRoot then (targetRoot.Position - root.Position).Magnitude else math.huge
		if targetRoot and distance < nearestDistance then
			nearest, nearestDistance = targetRoot, distance
		end
	end)
	if not nearest then
		return
	end
	local to = nearest.Position
	local flight = (to - from).Magnitude / ORB_SPEED
	local radius = helpers.data(WYRM, "orbRadius", 5)
	helpers.fx("FrostOrb", from, to, radius, flight, player)
	burstAfter(player, flight, to, radius, helpers.levelDamage(player, helpers.data(WYRM, "damagePerLevel", 15)), true)
end

--[ Frost Field ]--

local function spawnField(player: Player, position: Vector3)
	local ground = snapToGround(position, { mapOnly = true }) or position
	local radius = helpers.data(STAFF, "fieldRadius", 8)
	local seconds = helpers.data(STAFF, "fieldSeconds", 8)
	local chillEvery = helpers.data(STAFF, "chillEvery", 2)
	helpers.fx("FrostField", ground, nil, radius, seconds)

	local lastChill: { [Model]: number } = {}
	task.spawn(function()
		local endsAt = os.clock() + seconds
		while os.clock() < endsAt and player.Parent do
			local now = os.clock()
			local statusService = helpers.statusService()
			forEachEnemyInRadius(ground, radius, function(model: Model)
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

local function launchVolley(player: Player, root: BasePart)
	local candidates: { BasePart } = {}
	forEachEnemyInRadius(root.Position, SHARD_RANGE, function(model: Model)
		local targetRoot = getRoot(model)
		if targetRoot then
			table.insert(candidates, targetRoot)
		end
	end)
	local from = root.Position + Vector3.new(0, 3, 0)
	local radius = helpers.data(FOWL, "burstRadius", 6)
	local damage = helpers.levelDamage(player, helpers.data(FOWL, "damagePerLevel", 15))
	for _ = 1, math.min(helpers.data(FOWL, "volley", 3), #candidates) do
		local target = table.remove(candidates, math.random(#candidates)) :: BasePart
		helpers.fx("IceShard", from, target.Position, radius, SHARD_FLIGHT_SECONDS)
		burstAfter(player, SHARD_FLIGHT_SECONDS, target.Position, radius, damage, false)
	end
end

--[ Handlers ]--

function Frost.onSpellCast(player: Player, vfxName: string)
	if helpers.owns(player, STAFF) then
		local pending = pendingFields[player] or {}
		pendingFields[player] = pending
		pending[vfxName] = true
	end

	if not helpers.owns(player, WYRM) then
		return
	end
	local root = getRoot.fromPlayer(player)
	if not root then
		return
	end
	local seconds = helpers.data(WYRM, "seconds", 6)
	local wyrm = wyrms[player]
	if not wyrm then
		wyrm = { expiresAt = 0, nextBreath = os.clock() + 0.5 }
		wyrms[player] = wyrm
	end
	wyrm.expiresAt = os.clock() + seconds
	helpers.fx("WyrmSummon", root.Position, nil, nil, seconds, player)
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

-- Once a second per player: Staff of Azure Ever Ice's Ice Glyph kept in
-- step with ownership (it is up at all times while held), then Blizzard.
function Frost.onTick(player: Player)
	local character = player.Character
	local glyphRoot = getRoot.fromPlayer(player)
	if character and glyphRoot then
		local glyph = azureGlyph.find(character)
		local owns = helpers.owns(player, AZURE)
		if owns and not glyph then
			azureGlyph.spawn(character, glyphRoot)
		elseif glyph and not owns then
			azureGlyph.dismiss(glyph)
		end
	end

	if not helpers.owns(player, FOWL) then
		return
	end
	local root = getRoot.fromPlayer(player)
	if root and root:FindFirstChild(AuraNames.Frostburst) then
		launchVolley(player, root)
	end
end

function Frost.onPlayerRemoved(player: Player)
	wyrms[player] = nil
	pendingFields[player] = nil
end

return Frost
