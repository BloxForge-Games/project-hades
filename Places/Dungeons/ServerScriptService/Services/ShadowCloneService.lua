--!strict
--[[
	ShadowCloneService (PROTOTYPE, 2026-11-07): Shadow Clone Barrage's
	clones, server side.

	The server owns a clone as an invisible anchored PROXY (a one-part model
	under workspace.IgnoreInstances.ShadowClones) that it moves itself every
	frame: no physics, no Humanoid, so a clone never jumps, never lags behind
	a physics owner and never pushes anything. Every client draws the clone
	(ShadowCloneController): a copy of its caster holding the caster's own
	melee weapon, easing after the proxy and swinging with the player's own
	animations, slash VFX, lunge and dust.

	  * SLOTS: each clone owns one of three spots behind its caster
	    (SLOT_OFFSETS). It appears there, and runs back to it whenever it has
	    nothing to fight.
	  * FIGHTING: each clone takes the nearest living mob near its caster
	    that the fewest other clones are on, so they spread over the pack
	    and only share a mob when mobs run short. It walks to its spot by
	    that mob (its own arc position when shared), sidestepping walls, and
	    swings the weapon's three-hit combo at the weapon's own timing: the
	    lunge (meleeSwingFeel) at half the dash delay, the hit at
	    hitboxDelay.
	  * SPACING: clones ease apart whenever two get within CLONE_SPACING,
	    and out of their caster, so they never stand inside each other.
	  * SPEED: the caster's own cruising speed (RelicService), matched to
	    the caster's real speed while following.
	  * DAMAGE: ArcaneData `damage` per swing x the caster's Arcane Rank, to
	    every mob in front within the weapon's range. Crits and Arcane
	    bonuses apply; relic procs do not (DamageService.WithoutProcs) and
	    nothing is pushed (WithArcaneKnockback 0).
	  * LIFE: `lifetime` seconds, or `cloneHits` mob hits (MobService counts
	    them through HitClone: melee, projectiles and area attacks alike).
	  * AGGRO: mobs ask PickTarget. A mob goes for its nearest clone unless a
	    player is more than `aggroMargin` studs closer. Minibosses and
	    bosses too (2026-11-07).

	Proxy attributes the clients read: OwnerId, WeaponName, OwnerWeapon
	(true: copy the caster's drawn melee weapon, with its skin and
	enchantment; false: a plain Steel Sword), Moving, SwingIteration +
	SwingSerial (a swing started), HitSerial (a hit taken).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local DataService = require(ServerScriptService.Submodules.Core.Source.Services.DataService)
local ArcaneData = require(ReplicatedStorage.Submodules.Core.Shared.Data.ArcaneData)
local MeleeWeaponData = require(ReplicatedStorage.Submodules.Core.Shared.Data.MeleeWeaponData)
local ArcaneNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ArcaneNames)
local WeaponNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.WeaponNames)
local Blitz = require(ReplicatedStorage.Submodules.Core.Shared.Blitz)
local GameClock = require(ReplicatedStorage.Submodules.Core.Shared.GameClock)
local arcaneIndex = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Arcane.arcaneIndex)
local getRoot = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Character.getRoot)
local meleeSwingFeel = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Weapon.meleeSwingFeel)

local SPELL = ArcaneNames["Shadow Clone Barrage"]
local FALLBACK_WEAPON = WeaponNames["Steel Sword"]
local FOLDER_NAME = "ShadowClones"
-- The spots behind the caster, in the caster's frame (+Z is behind): the
-- first three for one cast, rows behind them for stacked casts.
-- The clones come out one at a time, this far apart (s), and each lives
-- `lifetime` from its OWN arrival, so they leave one at a time at the
-- same spacing (2026-11-09).
local SPAWN_INTERVAL = 0.35

local SLOT_OFFSETS = {
	Vector3.new(-4, 0, 3.5),
	Vector3.new(0, 0, 5.5),
	Vector3.new(4, 0, 3.5),
	Vector3.new(-7, 0, 6),
	Vector3.new(7, 0, 6),
	Vector3.new(-3, 0, 8.5),
	Vector3.new(3, 0, 8.5),
	Vector3.new(-6, 0, 10),
	Vector3.new(6, 0, 10),
}
-- Korblox Mage Staff (2026-11-07): its free casts make a recast possible
-- while clones still stand, so with it a recast ADDS clones instead of
-- replacing them, up to this many at once (the oldest make way past it).
local STACKING_RELIC = "Korblox Mage Staff"
local MAX_STACKED_CLONES = 9
-- Studs from its slot a clone settles at (it stops walking). 0.6 -> 1.5
-- (2026-11-08): a nudge of a stud no longer sends it walking back.
local SLOT_SETTLE = 1.5
-- How far (studs) from its caster a clone will go for a mob.
local SEEK_RANGE = 40
-- Share of the weapon's range a clone closes to before it swings.
local REACH_SHARE = 0.75
-- A swing hits mobs within this angle of the clone's facing (cosine).
local SWING_CONE_DOT = 0.2
-- The clone's body radius for the wall probe, and its turn rate (per s).
local BODY_RADIUS = 1.5
local TURN_RATE = 14
-- Headings tried, in degrees off straight: straight first, then the
-- sidesteps when the way is blocked.
local HEADINGS = { 0, 40, -40, 80, -80 }
-- How far below the walk height the floor probe reaches (a step down).
local FLOOR_PROBE = 8
-- Clones never stand inside each other or their caster: closer than these
-- (studs) and they ease apart, at up to SEPARATION_SPEED studs/s.
local CLONE_SPACING = 3.5
local CASTER_SPACING = 3
local SEPARATION_SPEED = 14
-- Clones sharing one target take spots around it, these many degrees
-- apart, facing it from the caster's side.
local SHARED_SPREAD = 70
-- A clone counts as moving for this long after its last step (s), so its
-- run does not flicker on and off between frames.
local MOVING_GRACE = 0.15
-- Left this far behind (studs), a following clone runs faster to catch up.
local CATCH_UP_STUDS = 20
local CATCH_UP_SPEED = 1.5
-- The FORMATION (2026-11-08): the slots hang off an anchor, not the
-- caster's live position and facing, so running in circles on the spot or
-- turning in place leaves the clones standing. The anchor holds until the
-- caster is FOLLOW_DEADZONE studs from it, then tracks them until they
-- settle: less than SETTLE_DRIFT studs of real progress in SETTLE_WINDOW s.
local FOLLOW_DEADZONE = 8
-- After a hit, a clone shrugs off further hits for this long (2026-11-08):
-- one ATTACK costs one hit, even a multi-strike one (the PotHead's double
-- slash, the Cleave's three) or overlapping strips (the Barrage's fan),
-- which each counted before and killed a 3-hit clone in two attacks.
local HIT_GRACE = 0.6
local SETTLE_WINDOW = 0.5
local SETTLE_DRIFT = 3

type Mob = { model: Model, humanoid: Humanoid, root: BasePart }

-- One caster's formation anchor (FOLLOW_DEADZONE above).
type Formation = {
	anchor: CFrame,
	following: boolean,
	mark: Vector3,
	markAt: number,
}

export type Clone = {
	model: Model,
	root: BasePart,
	owner: Player,
	slot: number,
	hitsLeft: number,
	lastHitAt: number,
	endsAt: number,
	alive: boolean,
	position: Vector3,
	look: Vector3,
	standHeight: number,
	weapon: { [string]: any },
	damage: number,
	target: Mob?,
	combo: number,
	busyUntil: number,
	lungeFrom: number,
	lungeUntil: number,
	moving: boolean,
	movedAt: number,
	swings: number,
}

local ShadowCloneService = {
	Name = "ShadowCloneService",
	_clones = {} :: { Clone },
	_byModel = {} :: { [Model]: Clone },
	_step = nil :: RBXScriptConnection?,
	_folder = nil :: Folder?,
	-- Per caster: where their clones' slots hang from.
	_formations = {} :: { [Player]: Formation },
	-- Per caster: bumped per Summon, so a recast (or leaving) cancels the
	-- previous cast's clones still waiting to come out.
	_summonSerials = {} :: { [Player]: number },
}

--[ Helpers ]--

local function flat(vector: Vector3): Vector3
	return Vector3.new(vector.X, 0, vector.Z)
end

-- `root`'s position, turned only about Y (its yaw).
local function yawFrame(root: BasePart): CFrame
	local at = root.Position
	local look = flat(root.CFrame.LookVector)
	if look.Magnitude < 0.01 then
		return CFrame.new(at)
	end
	return CFrame.lookAt(at, at + look.Unit)
end

local function livingMobs(): { Mob }
	local result = {}
	local ignore = workspace:FindFirstChild("IgnoreInstances")
	local folder = ignore and ignore:FindFirstChild("Mobs")
	if not folder then
		return result
	end
	for _, model in folder:GetChildren() do
		if not model:IsA("Model") then
			continue
		end
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		local root = model:FindFirstChild("HumanoidRootPart")
		if humanoid and humanoid.Health > 0 and root and root:IsA("BasePart") then
			table.insert(result, { model = model, humanoid = humanoid, root = root })
		end
	end
	return result
end

local function isAlive(mob: Mob?): boolean
	return mob ~= nil and mob.model.Parent ~= nil and mob.humanoid.Health > 0
end

-- The level geometry clones walk on and bump into: the dungeon rooms.
local worldParams = RaycastParams.new()
local function refreshWorldParams()
	local ignore = workspace:FindFirstChild("IgnoreInstances")
	local map = ignore and ignore:FindFirstChild("Map")
	local rooms = map and map:FindFirstChild("DungeonRooms")
	if rooms then
		worldParams.FilterType = Enum.RaycastFilterType.Include
		worldParams.FilterDescendantsInstances = { rooms }
	else
		worldParams.FilterType = Enum.RaycastFilterType.Exclude
		local exclude: { Instance } = {}
		if ignore then
			table.insert(exclude, ignore)
		end
		for _, player in Players:GetPlayers() do
			if player.Character then
				table.insert(exclude, player.Character)
			end
		end
		worldParams.FilterDescendantsInstances = exclude
	end
end

local function floorBelow(position: Vector3, standHeight: number): number?
	local hit =
		workspace:Raycast(position + Vector3.new(0, 2, 0), Vector3.new(0, -(standHeight + FLOOR_PROBE), 0), worldParams)
	return hit and hit.Position.Y
end

-- The caster's melee weapon (Primary slot) and whether the clients copy
-- the caster's own (skin, enchantment); else a plain Steel Sword.
local function meleeWeaponOf(player: Player): (string, boolean)
	local loadoutService = Blitz.OptionalService("WeaponLoadoutService")
	local loadout = loadoutService and loadoutService:GetWeaponLoadout(player)
	local primary = loadout and loadout[1]
	local name = primary and primary.name
	if type(name) == "string" and MeleeWeaponData[name] then
		return name, true
	end
	return FALLBACK_WEAPON, false
end

--[ Public ]--

-- Summons the caster's clones (the spell's ServerCast module calls this).
-- `origin`: where the caster really stood as they cast -- the CFrame their
-- client sent with the cast, which VFXService has already held to within
-- 10 studs of the server's copy (2026-11-08). The server's copy of a
-- moving character trails it (a dodge, a sprint), and clones formed on
-- that copy sometimes appeared well behind the caster. Nil: the server's.
function ShadowCloneService.Summon(self: typeof(ShadowCloneService), player: Player, origin: CFrame?)
	local data = ArcaneData[SPELL]
	local character = player.Character
	local casterRoot = character and getRoot(character)
	if not character or not casterRoot then
		return
	end
	local castFrame = origin or casterRoot.CFrame
	local castLook = flat(castFrame.LookVector)
	castLook = if castLook.Magnitude > 0.01 then castLook.Unit else Vector3.zAxis
	-- Level, at the caster's position, facing their way.
	castFrame = CFrame.lookAt(castFrame.Position, castFrame.Position + castLook)
	refreshWorldParams()
	local weaponName, ownerWeapon = meleeWeaponOf(player)
	local weapon = MeleeWeaponData[weaponName] or MeleeWeaponData[FALLBACK_WEAPON]
	local rank = arcaneIndex.getRankDamageMultiplier(DataService:GetProfileData(player), SPELL)
	local casterFloor = floorBelow(castFrame.Position, 3)
	local standHeight = if casterFloor then math.clamp(castFrame.Position.Y - casterFloor, 1, 6) else 3

	-- The new clones form up on the caster where they stand.
	self._formations[player] = {
		anchor = castFrame,
		following = false,
		mark = castFrame.Position,
		markAt = GameClock.Now(),
	}

	-- A recast replaces the caster's clones still standing -- or, with the
	-- Korblox Mage Staff, stacks on them (oldest dismissed past the cap).
	local count = math.min(data.cloneCount or 3, #SLOT_OFFSETS)
	local relicService = Blitz.OptionalService("RelicService")
	local stacks = relicService ~= nil and relicService:GetSpecificRelicRegistry(player, STACKING_RELIC) > 0
	local mine: { Clone } = {}
	for _, old in self._clones do
		if old.owner == player and old.alive then
			table.insert(mine, old)
		end
	end
	local keep = if stacks then math.max(0, math.min(MAX_STACKED_CLONES, #SLOT_OFFSETS) - count) else 0
	table.sort(mine, function(a, b)
		return a.endsAt < b.endsAt
	end)
	while #mine > keep do
		self:_dismiss(table.remove(mine, 1) :: Clone)
	end
	local taken: { [number]: boolean } = {}
	for _, old in mine do
		taken[old.slot] = true
	end
	local slots: { number } = {}
	for slot = 1, #SLOT_OFFSETS do
		if #slots >= count then
			break
		end
		if not taken[slot] then
			table.insert(slots, slot)
		end
	end

	local serial = (self._summonSerials[player] or 0) + 1
	self._summonSerials[player] = serial

	local function spawnClone(slot: number, isFirst: boolean)
		-- A later clone forms on the caster where they stand NOW (level),
		-- so one arriving after a step is not left behind.
		local frame = castFrame
		local look = castLook
		if not isFirst then
			local liveRoot = player.Character and getRoot(player.Character)
			if liveRoot then
				local liveLook = flat(liveRoot.CFrame.LookVector)
				look = if liveLook.Magnitude > 0.01 then liveLook.Unit else castLook
				frame = CFrame.lookAt(liveRoot.Position, liveRoot.Position + look)
			end
		end
		local spot = (frame * CFrame.new(SLOT_OFFSETS[slot])).Position
		local floor = floorBelow(spot, standHeight)
		local position = Vector3.new(spot.X, if floor then floor + standHeight else frame.Position.Y, spot.Z)

		local model = Instance.new("Model")
		model.Name = "ShadowClone"
		local root = Instance.new("Part")
		root.Name = "HumanoidRootPart"
		root.Size = Vector3.new(2, 2, 1)
		root.Transparency = 1
		root.Anchored = true
		root.CanCollide = false
		root.CanQuery = false
		root.CanTouch = false
		root.CFrame = CFrame.lookAt(position, position + look)
		root.Parent = model
		model.PrimaryPart = root
		model:SetAttribute("OwnerId", player.UserId)
		model:SetAttribute("WeaponName", weaponName)
		model:SetAttribute("OwnerWeapon", ownerWeapon)
		model:SetAttribute("Slot", slot)
		model:SetAttribute("Moving", false)
		model:SetAttribute("SwingSerial", 0)
		model:SetAttribute("HitSerial", 0)
		-- A client reads the root the moment the model streams in.
		model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
		model.Parent = self:_cloneFolder()

		local clone: Clone = {
			model = model,
			root = root,
			owner = player,
			slot = slot,
			hitsLeft = data.cloneHits or 3,
			lastHitAt = -math.huge,
			endsAt = GameClock.Now() + (data.lifetime or 8),
			alive = true,
			position = position,
			look = look,
			standHeight = standHeight,
			weapon = weapon,
			damage = (data.damage or 6) * rank,
			target = nil,
			combo = 0,
			busyUntil = 0,
			lungeFrom = 0,
			lungeUntil = 0,
			moving = false,
			movedAt = 0,
			swings = 0,
		}
		table.insert(self._clones, clone)
		self._byModel[model] = clone
		self:_ensureStepping()
	end

	for index, slot in slots do
		if index == 1 then
			spawnClone(slot, true)
		else
			GameClock.Delay((index - 1) * SPAWN_INTERVAL, function()
				if
					self._summonSerials[player] ~= serial
					or not player.Parent
					or not (player.Character and getRoot(player.Character))
				then
					return
				end
				spawnClone(slot, false)
			end)
		end
	end
end

-- The live clones (do not mutate).
function ShadowCloneService.GetClones(self: typeof(ShadowCloneService)): { Clone }
	return self._clones
end

function ShadowCloneService.IsClone(self: typeof(ShadowCloneService), model: Instance?): boolean
	return model ~= nil and model:IsA("Model") and self._byModel[model] ~= nil
end

-- The player whose clone `model` is, or nil.
function ShadowCloneService.OwnerOf(self: typeof(ShadowCloneService), model: Instance?): Player?
	local clone = if model and model:IsA("Model") then self._byModel[model] else nil
	return clone and clone.owner
end

-- The clone a mob at `from` should chase instead of its nearest player
-- (`nearestPlayerDistance` away): the nearest clone within `range`, unless
-- that player is more than aggroMargin studs closer. nil = keep the player.
function ShadowCloneService.PickTarget(
	self: typeof(ShadowCloneService),
	from: Vector3,
	range: number,
	nearestPlayerDistance: number
): (Model?, BasePart?)
	if #self._clones == 0 then
		return nil, nil
	end
	local margin = ArcaneData[SPELL].aggroMargin or 5
	local best: Clone? = nil
	local bestDistance = range
	for _, clone in self._clones do
		if not clone.alive then
			continue
		end
		local distance = (clone.position - from).Magnitude
		if distance < bestDistance then
			best, bestDistance = clone, distance
		end
	end
	if best and bestDistance <= nearestPlayerDistance + margin then
		return best.model, best.root
	end
	return nil, nil
end

-- One mob attack landed on `model` (a clone): one of its hits gone.
function ShadowCloneService.HitClone(self: typeof(ShadowCloneService), model: Model)
	local clone = self._byModel[model]
	if not clone or not clone.alive then
		return
	end
	local now = GameClock.Now()
	if now - clone.lastHitAt < HIT_GRACE then
		return
	end
	clone.lastHitAt = now
	clone.hitsLeft -= 1
	if clone.hitsLeft <= 0 then
		self:_dismiss(clone)
		return
	end
	model:SetAttribute("HitSerial", ((model:GetAttribute("HitSerial") :: number?) or 0) + 1)
end

--[ Private ]--

function ShadowCloneService._cloneFolder(self: typeof(ShadowCloneService)): Folder
	local folder = self._folder
	if folder and folder.Parent then
		return folder
	end
	local ignore = workspace:FindFirstChild("IgnoreInstances") or workspace
	local existing = ignore:FindFirstChild(FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		self._folder = existing
		return existing
	end
	local created = Instance.new("Folder")
	created.Name = FOLDER_NAME
	created.Parent = ignore
	self._folder = created
	return created
end

function ShadowCloneService._dismiss(self: typeof(ShadowCloneService), clone: Clone)
	if not clone.alive then
		return
	end
	clone.alive = false
	self._byModel[clone.model] = nil
	local index = table.find(self._clones, clone)
	if index then
		table.remove(self._clones, index)
	end
	if clone.model.Parent then
		clone.model:Destroy()
	end
end

function ShadowCloneService._ensureStepping(self: typeof(ShadowCloneService))
	if self._step then
		return
	end
	self._step = RunService.Heartbeat:Connect(function(dt: number)
		self:_stepAll(dt)
	end)
end

-- Moves the clone up to `distance` studs along `direction` (flat, unit),
-- sidestepping a wall, holding to the floor. Returns whether it moved.
function ShadowCloneService._walk(
	_self: typeof(ShadowCloneService),
	clone: Clone,
	direction: Vector3,
	distance: number
): boolean
	if distance <= 0 then
		return false
	end
	local origin = clone.position
	for _, degrees in HEADINGS do
		local heading = if degrees == 0
			then direction
			else CFrame.fromAxisAngle(Vector3.yAxis, math.rad(degrees)):VectorToWorldSpace(direction)
		local wall = workspace:Raycast(origin, heading * (distance + BODY_RADIUS), worldParams)
		if wall then
			continue
		end
		local nextSpot = origin + heading * distance
		local floor = floorBelow(nextSpot, clone.standHeight)
		if not floor then
			continue
		end
		clone.position = Vector3.new(nextSpot.X, floor + clone.standHeight, nextSpot.Z)
		return true
	end
	return false
end

function ShadowCloneService._turnToward(_self: typeof(ShadowCloneService), clone: Clone, want: Vector3, dt: number)
	local wantFlat = flat(want)
	if wantFlat.Magnitude < 0.01 then
		return
	end
	local blend = 1 - math.exp(-TURN_RATE * dt)
	local look = clone.look:Lerp(wantFlat.Unit, blend)
	clone.look = if look.Magnitude > 0.01 then look.Unit else wantFlat.Unit
end

-- Damage to every mob in front of the clone within the weapon's range.
function ShadowCloneService._swingHit(_self: typeof(ShadowCloneService), clone: Clone)
	local damageService = Blitz.OptionalService("DamageService")
	if not damageService or not clone.alive then
		return
	end
	local reach = clone.weapon.range or 9
	for _, mob in livingMobs() do
		local offset = flat(mob.root.Position - clone.position)
		if offset.Magnitude - mob.root.Size.X / 2 > reach then
			continue
		end
		if offset.Magnitude > 0.5 and clone.look:Dot(offset.Unit) < SWING_CONE_DOT then
			continue
		end
		local humanoid = mob.humanoid
		damageService:WithArcaneKnockback(0, function()
			damageService:WithoutProcs(function()
				damageService:TakeDamage(clone.owner, humanoid, clone.damage, true)
			end)
		end)
	end
end

function ShadowCloneService._startSwing(self: typeof(ShadowCloneService), clone: Clone, now: number)
	local weapon = clone.weapon
	clone.combo = clone.combo % 3 + 1
	local combo = clone.combo
	local hitAt = (weapon.hitboxDelay and weapon.hitboxDelay[combo]) or 0.2
	local nextAt = (weapon.animationDelay and weapon.animationDelay[combo]) or 0.5
	local lungeAt = ((weapon.dashDelay and weapon.dashDelay[combo]) or 0.25) / 2
	clone.busyUntil = now + nextAt
	clone.lungeFrom = now + lungeAt
	clone.lungeUntil = clone.lungeFrom + meleeSwingFeel.LUNGE_SECONDS
	clone.swings += 1
	clone.model:SetAttribute("SwingIteration", combo)
	clone.model:SetAttribute("SwingSerial", clone.swings)
	GameClock.Delay(hitAt, function()
		self:_swingHit(clone)
	end)
end

-- The caster's own cruising speed (relic and stat bonuses included), so a
-- clone always keeps pace with the player it copies.
local function walkSpeedFor(owner: Player): number
	local relicService = Blitz.OptionalService("RelicService")
	local speed = relicService and relicService:GetEffectiveBaseWalkSpeed(owner)
	if type(speed) == "number" and speed > 0 then
		return speed
	end
	return ArcaneData[SPELL].cloneWalkSpeed or 16
end

-- The mob for `clone`: the nearest living mob near the caster that the
-- fewest OTHER clones are already on, so clones spread over the pack and
-- only pile onto one mob when there are fewer mobs than clones.
function ShadowCloneService._pickTarget(self: typeof(ShadowCloneService), clone: Clone, ownerAt: Vector3): Mob?
	local best: Mob? = nil
	local bestClaims, bestDistance = math.huge, math.huge
	for _, mob in livingMobs() do
		if (mob.root.Position - ownerAt).Magnitude > SEEK_RANGE then
			continue
		end
		local claims = 0
		for _, other in self._clones do
			if other ~= clone and other.alive and other.target and other.target.model == mob.model then
				claims += 1
			end
		end
		local distance = (mob.root.Position - clone.position).Magnitude
		if claims < bestClaims or (claims == bestClaims and distance < bestDistance) then
			best, bestClaims, bestDistance = mob, claims, distance
		end
	end
	-- Keep the current target unless a less crowded one is free, so two
	-- clones never trade mobs back and forth.
	local current = clone.target
	if current and isAlive(current) and (current.root.Position - ownerAt).Magnitude <= SEEK_RANGE then
		local currentClaims = 0
		for _, other in self._clones do
			if other ~= clone and other.alive and other.target and other.target.model == current.model then
				currentClaims += 1
			end
		end
		if currentClaims <= bestClaims then
			return current
		end
	end
	return best
end

-- Where `clone` stands to fight its target. Alone on it: the near side,
-- along its approach. Sharing it: its own spot on an arc around the
-- target, facing it from the caster's side, SHARED_SPREAD degrees from the
-- next clone's, so two clones on one mob never stand in the same place.
function ShadowCloneService._engageSpot(
	self: typeof(ShadowCloneService),
	clone: Clone,
	target: Mob,
	ownerAt: Vector3
): Vector3
	local center = target.root.Position
	local standOff = target.root.Size.X / 2 + (clone.weapon.range or 9) * REACH_SHARE * 0.8
	local sharing: { Clone } = {}
	for _, other in self._clones do
		if other.alive and other.target and other.target.model == target.model then
			table.insert(sharing, other)
		end
	end
	local base: Vector3
	local angle = 0
	if #sharing <= 1 then
		base = flat(clone.position - center)
	else
		base = flat(ownerAt - center)
		table.sort(sharing, function(a: Clone, b: Clone): boolean
			if a.owner ~= b.owner then
				return a.owner.UserId < b.owner.UserId
			end
			return a.slot < b.slot
		end)
		local index = table.find(sharing, clone) or 1
		-- Centred on the caster's side: -1, 0, +1 steps for three clones.
		angle = (index - (#sharing + 1) / 2) * SHARED_SPREAD
	end
	if base.Magnitude < 0.05 then
		base = flat(clone.position - center)
		if base.Magnitude < 0.05 then
			base = Vector3.xAxis
		end
	end
	local direction = CFrame.fromAxisAngle(Vector3.yAxis, math.rad(angle)):VectorToWorldSpace(base.Unit)
	return center + direction * standOff
end

-- Eases `clone` out of any other clone and out of its caster.
-- `fromOwner`: also keep CASTER_SPACING from the caster. Off while the
-- formation holds (2026-11-08): the caster walking over a resting clone
-- shoved it off its slot, it walked back facing them, and was shoved
-- again, over and over.
function ShadowCloneService._separate(
	self: typeof(ShadowCloneService),
	clone: Clone,
	ownerAt: Vector3,
	dt: number,
	fromOwner: boolean
)
	local push = Vector3.zero
	for _, other in self._clones do
		if other == clone or not other.alive then
			continue
		end
		local away = flat(clone.position - other.position)
		local distance = away.Magnitude
		if distance < CLONE_SPACING then
			-- Exactly on top of each other: split by slot.
			local direction = if distance > 0.05
				then away.Unit
				else CFrame.fromAxisAngle(Vector3.yAxis, clone.slot * 2.1):VectorToWorldSpace(Vector3.xAxis)
			push += direction * (CLONE_SPACING - distance)
		end
	end
	local awayFromOwner = flat(clone.position - ownerAt)
	if fromOwner and awayFromOwner.Magnitude < CASTER_SPACING and awayFromOwner.Magnitude > 0.05 then
		push += awayFromOwner.Unit * (CASTER_SPACING - awayFromOwner.Magnitude)
	end
	if push.Magnitude > 0.01 then
		self:_walk(clone, push.Unit, math.min(push.Magnitude, SEPARATION_SPEED * dt))
	end
end

-- The frame `owner`'s clones take their slots from this step: held still
-- until the caster leaves FOLLOW_DEADZONE, then on the caster until they
-- settle (FOLLOW_DEADZONE above).
function ShadowCloneService._formationFrame(
	self: typeof(ShadowCloneService),
	owner: Player,
	ownerRoot: BasePart,
	now: number
): CFrame
	local at = ownerRoot.Position
	local formation = self._formations[owner]
	if not formation then
		formation = { anchor = yawFrame(ownerRoot), following = false, mark = at, markAt = now }
		self._formations[owner] = formation
	end
	if not formation.following and flat(at - formation.anchor.Position).Magnitude > FOLLOW_DEADZONE then
		formation.following = true
		formation.mark = at
		formation.markAt = now
	end
	if formation.following then
		formation.anchor = yawFrame(ownerRoot)
		if now - formation.markAt >= SETTLE_WINDOW then
			if flat(at - formation.mark).Magnitude < SETTLE_DRIFT then
				formation.following = false
			end
			formation.mark = at
			formation.markAt = now
		end
	end
	return formation.anchor
end

function ShadowCloneService._stepClone(self: typeof(ShadowCloneService), clone: Clone, now: number, dt: number)
	local owner = clone.owner
	local ownerRoot = owner.Character and getRoot(owner.Character)
	if not ownerRoot then
		self:_dismiss(clone)
		return
	end
	local ownerAt = ownerRoot.Position
	local walkSpeed = walkSpeedFor(owner)
	local stepped = false
	-- Resting in a held formation: the caster may walk right over it.
	local resting = false

	if now < clone.busyUntil then
		-- Mid-swing: face the target, and the lunge carries it forward.
		local target = clone.target
		if target and isAlive(target) then
			self:_turnToward(clone, target.root.Position - clone.position, dt)
		end
		if now >= clone.lungeFrom and now < clone.lungeUntil then
			local speed = meleeSwingFeel.LUNGE_STUDS / meleeSwingFeel.LUNGE_SECONDS
			-- Never lunge through the target: stop at half the reach.
			local stopAt = (clone.weapon.range or 9) * REACH_SHARE * 0.5
			local gap = if target and isAlive(target)
				then flat(target.root.Position - clone.position).Magnitude - target.root.Size.X / 2
				else math.huge
			if gap > stopAt then
				self:_walk(clone, clone.look, math.min(speed * dt, gap - stopAt))
			end
		end
	else
		-- Re-pick every step while not swinging: a clone moves off a mob
		-- another clone is on as soon as a free one is near.
		clone.target = self:_pickTarget(clone, ownerAt)
		local target = clone.target
		if target then
			local spot = self:_engageSpot(clone, target, ownerAt)
			local toSpot = flat(spot - clone.position)
			local toTarget = flat(target.root.Position - clone.position)
			local gap = toTarget.Magnitude - target.root.Size.X / 2
			local reach = (clone.weapon.range or 9) * REACH_SHARE
			if toSpot.Magnitude > 1 and (gap > reach or toSpot.Magnitude > 2.5) then
				stepped = self:_walk(clone, toSpot.Unit, math.min(walkSpeed * dt, toSpot.Magnitude))
				self:_turnToward(clone, if gap > reach then toSpot else toTarget, dt)
			else
				self:_turnToward(clone, toTarget, dt)
				-- At its spot and turned in: swing.
				if toTarget.Magnitude < 0.05 or clone.look:Dot(toTarget.Unit) > 0.7 then
					self:_startSwing(clone, now)
				end
			end
		else
			clone.combo = 0
			-- Nothing to fight: run to the slot behind the caster's
			-- formation anchor (held still while they mill about).
			local formation = self:_formationFrame(owner, ownerRoot, now)
			local held = self._formations[owner]
			resting = held ~= nil and not held.following
			local slotSpot = (formation * CFrame.new(SLOT_OFFSETS[clone.slot])).Position
			local offset = flat(slotSpot - clone.position)
			if offset.Magnitude > SLOT_SETTLE then
				-- Keep pace with the caster, however fast they are going.
				local ownerSpeed = flat(ownerRoot.AssemblyLinearVelocity).Magnitude
				local speed = math.max(walkSpeed, ownerSpeed)
				if offset.Magnitude > CATCH_UP_STUDS then
					speed *= CATCH_UP_SPEED
				end
				stepped = self:_walk(clone, offset.Unit, math.min(speed * dt, offset.Magnitude))
				self:_turnToward(clone, offset, dt)
				-- Stranded behind a wall it cannot get round: rejoin the slot.
				if not stepped and offset.Magnitude > 30 then
					local floor = floorBelow(slotSpot, clone.standHeight)
					if floor then
						clone.position = Vector3.new(slotSpot.X, floor + clone.standHeight, slotSpot.Z)
					end
				end
			else
				self:_turnToward(clone, formation.LookVector, dt)
			end
		end
	end

	self:_separate(clone, ownerAt, dt, not resting)

	if stepped then
		clone.movedAt = now
	end
	local moving = now - clone.movedAt < MOVING_GRACE
	if moving ~= clone.moving then
		clone.moving = moving
		clone.model:SetAttribute("Moving", moving)
	end
	clone.root.CFrame = CFrame.lookAt(clone.position, clone.position + clone.look)
end

function ShadowCloneService._stepAll(self: typeof(ShadowCloneService), dt: number)
	local now = GameClock.Now()
	for index = #self._clones, 1, -1 do
		local clone = self._clones[index]
		if not clone then
			continue
		end
		if not clone.alive or now >= clone.endsAt or not clone.owner.Parent or not clone.model.Parent then
			self:_dismiss(clone)
			continue
		end
		self:_stepClone(clone, now, dt)
	end
	-- A caster with no clones left keeps no formation.
	for owner in self._formations do
		local any = false
		for _, clone in self._clones do
			if clone.owner == owner then
				any = true
				break
			end
		end
		if not any then
			self._formations[owner] = nil
		end
	end
	if #self._clones == 0 and self._step then
		self._step:Disconnect()
		self._step = nil
	end
end

function ShadowCloneService.Start(self: typeof(ShadowCloneService))
	-- Made up front, so clients can wait on it.
	self:_cloneFolder()
	Players.PlayerRemoving:Connect(function(player: Player)
		self._summonSerials[player] = nil
		for index = #self._clones, 1, -1 do
			local clone = self._clones[index]
			if clone and clone.owner == player then
				self:_dismiss(clone)
			end
		end
	end)
end

return ShadowCloneService
