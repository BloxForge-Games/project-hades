--!strict
--[[
	Module: MobDeath.lua
	Description: The kill side of a mob's death, shared by both mob
	runtimes so a takedown pays out the same however the mob was driven:
	  * MobBase (Humanoid rigs: minibosses, bosses, and any MobData entry
	    without `useMobSim`)
	  * MobSimService (client-simulated mobs)

	Owns, in OnDeath order:
	  * GrantKill            party EXP for a player kill
	  * RunKillerRewards     lobbed bombs (Trick Or Trap, Fuse Bomb), the
	                         Zombie Bomb cloud, per-assister stats / takedown
	                         auras / Midnight Sword mana / orb rolls, then the
	                         corpse drops (gear + gems), deferred to the
	                         reward chest for encounter mobs
	  * TrackAssists         the assist registry those rewards read

	The body side (ragdoll, impulse, sound, despawn) stays with each
	runtime: MobBase does it with server physics, the sim on every client.
]]

--[ Roblox Services ]--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

--[ Imports ]--

local DropService = require(ServerScriptService.Services.DropService)
local RelicService = require(ServerScriptService.Services.RelicService)
local RoundStatisticsService = require(ServerScriptService.Services.RoundStatisticsService)
local AuraService = require(ServerScriptService.Services.AuraService)
local VFXService = require(ServerScriptService.Services.VFXService)
local IgnoreListService = require(ServerScriptService.Submodules.Core.Source.Services.IgnoreListService)
local GearDropService = require(ServerScriptService.Services.GearDropService)
local DamageService = require(ServerScriptService.Services.DamageService)
local StatusConditionService = require(ServerScriptService.Services.StatusConditionService)
local EncounterService = require(ServerScriptService.Services.EncounterService)
local ExpRewardService = require(ServerScriptService.Services.ExpRewardService)
local DungeonService = require(ServerScriptService.Services.DungeonService)
local ArcaneService = require(ServerScriptService.Services.ArcaneService)
local RelicNetwork = require(ServerScriptService.Submodules.Core.Source.Network.Relic)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local DropTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.DropTypes)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local EnemyType = require(ReplicatedStorage.Submodules.Core.Shared.Enums.EnemyTypes)
local AuraNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.AuraNames)
local ArcaneNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ArcaneNames)
local StatusConditions = require(ReplicatedStorage.Submodules.Core.Shared.Enums.StatusConditions)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local RoomTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RoomTypes)
local ArcaneData = require(ReplicatedStorage.Submodules.Core.Shared.Data.ArcaneData)
local getPlayerLevel = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Player.getPlayerLevel)
local onHitboxDamage = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Hitbox.onHitboxDamage)
local forEachEnemyInRadius = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Combat.forEachEnemyInRadius)
local snapToGround = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Combat.snapToGround)

--[ Types ]--

-- MobData `gems`: DropRate = pickup count range, Gems = value-per-pickup
-- range, dropChance (0..1, default 1) that the kill drops at all.
export type GemsRow = {
	minDropRate: number,
	maxDropRate: number,
	minGems: number,
	maxGems: number,
	dropChance: number?,
}

-- Everything the kill side reads off a dying mob.
export type Context = {
	model: Model,
	-- Drop origin and bomb launch point. On a sim mob this is the proxy's
	-- root, which sits exactly where every client draws the body.
	rootPart: BasePart,
	enemyType: string,
	gems: GemsRow?,
	-- [player name] = os.clock() of their last damaging hit (TrackAssists).
	assists: { [string]: number },
	-- Spawned in a miniboss / boss ROLE (IsMiniboss / IsBoss), which pays
	-- through the reward chest instead of the corpse.
	isEncounter: boolean,
}

--[ Constants ]--

-- Takedown -> aura grants. Chance comes from each relic's callback, so
-- RelicData stays the one source and the cards cannot drift from this.
local TAKEDOWN_AURA_RELICS = {
	{ relicName = RelicNames["Flaming Mace"], aura = AuraNames.Enflamed },
	{ relicName = RelicNames["Ice Cream"], aura = AuraNames.Frostburst },
	{ relicName = RelicNames["Poison Picnic"], aura = AuraNames.Blighted },
	{ relicName = RelicNames["Ninja Whip"], aura = AuraNames.Stormcharged },
	{ relicName = RelicNames["Space Sandwich"], aura = AuraNames.Stonebound },
}

-- Midnight Sword: fraction of Maximum Mana restored per takedown (its old
-- Overcharged-at-full-mana half died with that aura).
local MIDNIGHT_SWORD_MANA_FRACTION = 0.05
-- Assist credit EXPIRES: a player counts as an assister on this mob only
-- while their last damaging hit was within this many seconds (every hit
-- refreshes the window). Applies to the WHOLE assist registry -- relic
-- takedown procs, orb rolls, kill statistics, gear drops.
local ASSIST_WINDOW_SECONDS = 5

-- Lobbed bombs (Trick Or Trap's pumpkins, the Fuse Bomb): the client's
-- arc flies for BOMB_FLIGHT_SECONDS; the server hitbox fires the margin
-- after that, so the blast never lands before the bomb visibly does.
local BOMB_FLIGHT_SECONDS = 0.75
local BOMB_DETONATION_MARGIN_SECONDS = 0.25
-- Each bomb lands within this many studs (per axis) of the corpse's
-- ground point.
local BOMB_SCATTER_STUDS = 5
-- Lift above the ground point so the bomb (and its hitbox) rests ON the
-- floor rather than half inside it.
local BOMB_REST_HEIGHT_STUDS = 3.25 / 2
-- CONCURRENT bomb cap, PER RELIC and SERVER-WIDE (the counter lives in
-- RelicService's limit registry, keyed by relic name and shared by every
-- player). Trick Or Trap and Fuse Bomb each get their own 15, so at most
-- 30 bombs are ever in flight at once — a frame-rate guard, not a
-- balance one. A slot is held only from the lob to the detonation
-- (BOMB_FLIGHT_SECONDS + BOMB_DETONATION_MARGIN_SECONDS), so the cap bites
-- only on a genuine pile-up.
local BOMB_LIMIT_PER_RELIC = 15

-- One lobbed-bomb relic. `lobBombs` runs the recipe both share (ground
-- the corpse, roll the count, claim a cap slot per bomb, broadcast the
-- arc, detonate a hitbox after the fuse); these fields are everything the
-- two relics differ in.
type BombSpec = {
	relicName: string,
	arcaneName: string,
	-- How many bombs this takedown lobs. A closure rather than a maximum so
	-- the Fuse Bomb's fixed 1 never touches the RNG, exactly as before.
	rollBombCount: () -> number,
	-- The blast's damage lane, per struck mob.
	onHit: (killer: Player, model: Model, targetCFrame: CFrame) -> (),
}

-- Trick Or Trap: 1-3 pumpkins. ANY takedown drops them. The
-- Burning-target requirement came off in the 2026-08 pass when the relic
-- became NC: gating an opener behind a Burn the player might have no way
-- to apply made it dead on pickup. The pumpkins apply Burn themselves
-- now, so this is what STARTS the Blaze chain rather than paying it off.
local TRICK_OR_TRAP_BOMBS: BombSpec = {
	relicName = RelicNames["Trick Or Trap"],
	arcaneName = ArcaneNames["Pumpkin Explosion"],
	rollBombCount = function()
		return math.random(1, 3)
	end,
	onHit = function(killer, model, targetCFrame)
		-- isRelicSourced = true rides the UNTYPED lane now: unqualified
		-- Damage bonuses scale the blast, typed relics/crits never apply.
		-- Still rolls the WEAPON applier hub via onHitboxDamage
		-- (isMagic = false).
		onHitboxDamage(model, targetCFrame, killer, ArcaneData[ArcaneNames["Pumpkin Explosion"]], false, true)

		-- "...and burning them": the blast applies Burn outright rather
		-- than rolling for it, which is what lets Trick Or Trap open the
		-- Blaze tree on its own.
		-- The cast: StatusConditionService's own helper signatures disagree
		-- on Player vs Player?, which fails its self type on any method
		-- call from a strict file.
		if StatusConditionService then
			(StatusConditionService :: any):ApplyStatus(killer, model, StatusConditions.Burn)
		end
	end,
}

-- Fuse Bomb (Neutral Rare): the pumpkin recipe — same fuse, same cap
-- machinery (its OWN BOMB_LIMIT_PER_RELIC counter, not one shared with the
-- pumpkins), same hitbox — but ONE bomb per takedown (no 1-3 roll), the
-- Fuse Bomb model (relicName rides the client payload), and the blast is
-- PLAIN damage: neither weapon nor arcane — the raw path, no amplifiers /
-- crit / appliers (Summer Fireworks' recipe). No Burn either.
local FUSE_BOMBS: BombSpec = {
	relicName = RelicNames["Fuse Bomb"],
	arcaneName = ArcaneNames["Fuse Bomb Explosion"],
	rollBombCount = function()
		return 1
	end,
	onHit = function(killer, model, _targetCFrame)
		-- UNTYPED relic lane (isRelicSourced): unqualified Damage bonuses
		-- scale the blast; Weapon/Arcane-typed relics and crits never apply.
		local targetHumanoid = model:FindFirstChildOfClass("Humanoid")
		if not targetHumanoid or not DamageService then
			return
		end
		local config = ArcaneData[ArcaneNames["Fuse Bomb Explosion"]]
		local damageRoll = if config.runtimeDamageCallback then config.runtimeDamageCallback(killer) else config.damage
		DamageService:TakeDamage(killer, targetHumanoid, damageRoll, false, false, false, true, true)
	end,
}

-- Zombie Bomb (Venom Legendary): a takedown on a POISONED mob leaves a
-- Poison Cloud at the corpse (the Blighted clause was dropped in the
-- 2026-09 un-gating pass) -- (callback x level) damage per tick for the
-- duration, and each tick has
-- CLOUD_STATUS_CHANCE to Poison everything inside (the sheet's "+30%
-- Status Chance"). LIMIT bounds live clouds PER PLAYER, same shape as
-- the pumpkin cap.
local MOB_BOMB_CLOUD_DURATION = 5
local MOB_BOMB_CLOUD_TICK_SECONDS = 1
local MOB_BOMB_CLOUD_RADIUS = 7
local MOB_BOMB_CLOUD_LIMIT = 3
local MOB_BOMB_CLOUD_FADE_SECONDS = 1.5

--[ Module ]--

local MobDeath = {}

--[ Assist registry ]--

-- ASSIST CREDIT, refreshed on EVERY damage instance.
--
-- This used to hang off GetAttributeChangedSignal(SlainBy) alone, which
-- is a trap: DamageService writes SlainBy on every hit, but the signal
-- only fires when the value CHANGES. A solo player therefore stamped a
-- timestamp on their FIRST hit and never again, so credit expired
-- ASSIST_WINDOW_SECONDS later -- mid-fight. Every miniboss and boss
-- outlives that window, which silently killed their gear drops, their
-- kill/assist stats, and every takedown proc that gates on
-- assistedRecently.
--
-- HealthChanged fires per damage instance regardless of who dealt it,
-- so pairing it with the attribute read keeps the window live for as
-- long as a player is actually fighting. Returns the connections; the
-- caller owns them.
function MobDeath.TrackAssists(model: Model, humanoid: Humanoid, assists: { [string]: number }): { RBXScriptConnection }
	local function creditCurrentAttacker()
		local slainBy = model:GetAttribute(Attributes.SlainBy)
		if type(slainBy) == "string" and slainBy ~= "" then
			assists[slainBy] = os.clock()
		end
	end

	local lastCreditedHealth = humanoid.Health
	return {
		model:GetAttributeChangedSignal(Attributes.SlainBy):Connect(creditCurrentAttacker),
		humanoid.HealthChanged:Connect(function(newHealth: number)
			-- Damage only; a heal must not extend an attacker's credit.
			if newHealth < lastCreditedHealth then
				creditCurrentAttacker()
			end
			lastCreditedHealth = newHealth
		end),
	}
end

-- True while `name` still holds live assist credit (last hit within
-- ASSIST_WINDOW_SECONDS).
function MobDeath.AssistedRecently(assists: { [string]: number }, name: string): boolean
	local lastHitAt = assists[name]
	return lastHitAt ~= nil and (os.clock() - lastHitAt) <= ASSIST_WINDOW_SECONDS
end

--[ Kill credit ]--

-- The player whose hit killed this mob (the SlainBy stamp), while they
-- are still here with a character. nil for a non-player death (a room
-- despawn, a trap with no owner) or a killer who left.
function MobDeath.ResolveKiller(model: Model): Player?
	local slainBy = model:GetAttribute(Attributes.SlainBy)
	if type(slainBy) ~= "string" or slainBy == "" then
		return nil
	end
	local killer = Players:FindFirstChild(slainBy)
	if killer and killer:IsA("Player") and killer.Character then
		return killer
	end
	return nil
end

-- A player's kill pays EXP to the whole living party (ExpRewardService),
-- whether or not the killer is still here.
function MobDeath.GrantKill(context: Context)
	local slainBy = context.model:GetAttribute(Attributes.SlainBy)
	if type(slainBy) == "string" and slainBy ~= "" then
		ExpRewardService:GrantKill(context.enemyType)
	end
end

--[ Lobbed bombs ]--

-- The lobbed-bomb recipe both bomb relics share (TRICK_OR_TRAP_BOMBS,
-- FUSE_BOMBS). Every bomb claims a slot against its relic's global cap
-- (BOMB_LIMIT_PER_RELIC) before spawning, and simply does not spawn when
-- the cap is full. The claim is read-then-write with no yield between, so
-- the bombs of one takedown cannot over-claim each other.
local function lobBombs(context: Context, killer: Player, spec: BombSpec)
	local owned = RelicService:GetSpecificRelicRegistry(killer, spec.relicName)
	if not owned or owned <= 0 then
		return
	end

	local origin = context.rootPart.Position
	local groundPosition = snapToGround(origin) or origin
	local cachedCFrame = CFrame.new(groundPosition) + Vector3.new(0, BOMB_REST_HEIGHT_STUDS, 0)
	local arcaneName = spec.arcaneName

	for _ = 1, spec.rollBombCount() do
		task.spawn(function()
			local currentLimit = RelicService:GetRelicLimitRegistry(spec.relicName) or 0
			if currentLimit >= BOMB_LIMIT_PER_RELIC then
				return
			end

			RelicService:SetRelicLimitRegistry(spec.relicName, currentLimit + 1)
			local targetCFrame = cachedCFrame
				+ Vector3.new(
					math.random(-BOMB_SCATTER_STUDS, BOMB_SCATTER_STUDS),
					0,
					math.random(-BOMB_SCATTER_STUDS, BOMB_SCATTER_STUDS)
				)

			RelicNetwork.ThrownRelicLaunched.FireAll({
				Position = origin,
				TargetPosition = targetCFrame.Position,
				StartTime = workspace:GetServerTimeNow(),
				Duration = BOMB_FLIGHT_SECONDS,
				ArcaneName = arcaneName,
				RelicName = spec.relicName,
			})

			task.delay(BOMB_FLIGHT_SECONDS + BOMB_DETONATION_MARGIN_SECONDS, function()
				-- Slot released FIRST, before the blast: this bomb is detonating,
				-- so its slot is spent either way, and a hitbox that ERRORS must
				-- never strand it — the counter is server-wide and nothing ever
				-- resets it, so a leaked slot would starve the relic for the life
				-- of the server.
				RelicService:SetRelicLimitRegistry(
					spec.relicName,
					(RelicService:GetRelicLimitRegistry(spec.relicName) or 0) - 1
				)
				VFXService:CreateHitbox(
					arcaneName,
					killer,
					targetCFrame,
					TagList.Zombie,
					IgnoreListService:GetWeaponIgnoreList(),
					function(model: Model)
						spec.onHit(killer, model, targetCFrame)
					end,
					ArcaneData[arcaneName].hitboxSize.X
				)
			end)
		end)
	end
end

--[ Zombie Bomb cloud ]--

local function runZombieBombCloud(context: Context, killer: Player)
	local damagePerLevel = RelicService:GetRelicEffect(killer, RelicNames["Zombie Bomb"])
	if not damagePerLevel or RelicService:GetSpecificRelicRegistry(killer, RelicNames["Zombie Bomb"]) <= 0 then
		return
	end
	-- Gate: the mob died POISONED (family read -- Noxious Venom counts;
	-- any player's stacks, read before the stack watchers release).
	if not (StatusConditionService and StatusConditionService:IsPoisoned(context.model)) then
		return
	end

	local limitKey = RelicNames["Zombie Bomb"] .. "_" .. killer.UserId
	local liveClouds = RelicService:GetRelicLimitRegistry(limitKey) or 0
	if liveClouds >= MOB_BOMB_CLOUD_LIMIT then
		return
	end
	RelicService:SetRelicLimitRegistry(limitKey, liveClouds + 1)

	local cloudTemplate = ReplicatedStorage.GameAssets.VFX:FindFirstChild("PoisonCloud")
	local cloudPosition = context.rootPart.Position
	local cloud
	if cloudTemplate then
		cloud = cloudTemplate:Clone()
		cloud:PivotTo(CFrame.new(cloudPosition))
		for _, part in cloud:GetDescendants() do
			if part:IsA("BasePart") then
				part.Anchored = true
				part.CanCollide = false
				part.CanQuery = false
				part.CanTouch = false
			end
		end
		cloud.Parent = workspace.IgnoreInstances.ArcaneSpells
	else
		warn("[MobDeath] Missing ReplicatedStorage.GameAssets.VFX.PoisonCloud")
	end

	local tickDamage = math.round(damagePerLevel * getPlayerLevel(killer))
	task.spawn(function()
		local elapsed = 0
		while elapsed < MOB_BOMB_CLOUD_DURATION do
			task.wait(MOB_BOMB_CLOUD_TICK_SECONDS)
			elapsed += MOB_BOMB_CLOUD_TICK_SECONDS

			forEachEnemyInRadius(cloudPosition, MOB_BOMB_CLOUD_RADIUS, function(model, targetHumanoid)
				-- Relic damage, NEUTRAL type (isMagic = false): no arcane
				-- amplifiers, no arcane resist, white number — the same bucket
				-- as TNT / tremor / Ghost Dragon. Full amp chain + crit roll
				-- (isRelicSourced = true).
				if DamageService and tickDamage > 0 then
					DamageService:TakeDamage(killer, targetHumanoid, tickDamage, false, false, nil, true)
				end
				-- "...and applies Poison": every tick, no roll. The card dropped
				-- its Status Chance clause in the 2026-08 pass, so the cloud is
				-- now a guaranteed Poison field rather than a chance to seed one.
				if StatusConditionService then
					-- Cast: see TRICK_OR_TRAP_BOMBS.
					(StatusConditionService :: any):ApplyStatus(killer, model, StatusConditions.Poison, false)
				end
			end)
		end

		RelicService:SetRelicLimitRegistry(limitKey, (RelicService:GetRelicLimitRegistry(limitKey) or 1) - 1)

		if cloud then
			for _, emitter in cloud:GetDescendants() do
				if emitter:IsA("ParticleEmitter") then
					emitter.Enabled = false
				end
			end
			task.delay(MOB_BOMB_CLOUD_FADE_SECONDS, function()
				cloud:Destroy()
			end)
		end
	end)
end

--[ Assist payouts ]--

local function handleAssists(context: Context)
	for name, _ in context.assists do
		if not MobDeath.AssistedRecently(context.assists, name) then
			continue
		end
		local player = Players:FindFirstChild(name)
		if not player or not player:IsA("Player") then
			continue
		end

		RoundStatisticsService.Signals.OnKillOrAssist:Fire(player, 1)

		local enemyType = context.model:GetAttribute(Attributes.EnemyType)

		if enemyType == EnemyType.Elite then
			RoundStatisticsService.Signals.OnEliteChanged:Fire(player, 1)
		elseif enemyType == EnemyType.Miniboss then
			RoundStatisticsService.Signals.OnMinibossChanged:Fire(player, 3)
		elseif enemyType == EnemyType.Boss then
			-- The count is REQUIRED (the handler adds it). Omitting it here
			-- threw on every boss kill, so the boss tally never moved.
			-- Continues the elite 1 / miniboss 3 weighting.
			RoundStatisticsService.Signals.OnBossChanged:Fire(player, 5)
		end

		-- Takedown procs roll per killer/assister — anyone in this mob's
		-- assist registry whose credit is still live (the 5s window),
		-- INCLUDING the player who landed the killing blow.

		-- Takedown aura grants — one relic per element tree, all rolling off
		-- the same kill. These are each tree's THIRD ungated opener, added in
		-- the 2026-08 pass so a run does not always begin with the same two
		-- status/aura enablers.
		--
		-- Rolled per killer/assister like everything else here, and routed
		-- through SetAura so the Sword of Eternal Abyss lockout, the duration
		-- bonuses and the extend-only rule all apply for free.
		if AuraService and player.Character then
			for _, row in TAKEDOWN_AURA_RELICS do
				if RelicService:GetSpecificRelicRegistry(player, row.relicName) > 0 then
					local chance = RelicService:GetRelicEffect(player, row.relicName) or 0
					if chance > 0 and math.random() <= chance then
						AuraService:SetAura(player, row.aura, player.Character)
					end
				end
			end
		end

		-- Midnight Sword: takedowns restore 5% of Maximum Mana.
		if RelicService:GetSpecificRelicRegistry(player, RelicNames["Midnight Sword"]) > 0 then
			local arcaneData = ArcaneService:GetPlayerArcaneData(player)
			if arcaneData and arcaneData.maxMana and arcaneData.mana < arcaneData.maxMana then
				local refunded =
					math.min(arcaneData.mana + arcaneData.maxMana * MIDNIGHT_SWORD_MANA_FRACTION, arcaneData.maxMana)
				ArcaneService:SetPlayerArcaneData(player, refunded, arcaneData.maxMana)
			end
		end

		-- Mana orb roll per killer/assister. Gear Recycler: +10pp drop
		-- chance (its orb-restore half lives in DropService).
		local manaDropChance = 5

		if RelicService:GetSpecificRelicRegistry(player, RelicNames["Gear Recycler"]) > 0 then
			manaDropChance += 10
		end

		if math.random() * 100 <= manaDropChance then
			DropService.OnDropRequested:Fire(context.rootPart, DropTypes.Mana, 1, 1, 1, 1, false)
		end

		-- Health orb roll per killer/assister. (Regeneration Coil's old
		-- +2.5pp here left when it became an any-source healing amp.)
		local healthDropChance = 5

		if math.random() * 100 <= healthDropChance then
			DropService.OnDropRequested:Fire(context.rootPart, DropTypes.Health, 1, 1, 1, 1, false)
		end
	end
end

--[ Corpse drops ]--

-- Personal-loot gear roll for every player in the assist registry.
local function dropGear(context: Context)
	if not GearDropService then
		return
	end
	for name, _ in context.assists do
		local player = Players:FindFirstChild(name)
		if player and player:IsA("Player") and MobDeath.AssistedRecently(context.assists, name) then
			GearDropService:DropGear(player, context.rootPart.Position, context.enemyType)
		end
	end
end

-- GEMS, the run currency, off every grunt's corpse (MobData `gems`:
-- DropRate = pickup count, Gems = value per pickup). Shared pickups --
-- every player banks the full value once. Pot Of Gold / Dragon Lantern /
-- Fortune multiply collector-side at credit time (DropService).
--
-- EXCEPT in a Miniboss / Boss room: those pay Coins and Forge Ore through
-- their reward chest (EncounterChestService), not corpse Gems -- the
-- Miniboss's own `gems` row is its chest's Gem PURSE, paid there, so it
-- must never scatter here as well. The gate is the ROOM, not the mob, so
-- the adds a miniboss wave spawns are covered too -- every mob carries
-- the RoomId its spawner stamped (MobSpawnService).
local function dropGems(context: Context)
	local gems = context.gems
	if not gems then
		return
	end
	local roomId = context.model:GetAttribute("RoomId")
	local dungeon = DungeonService and DungeonService:GetActiveDungeon()
	local room = if dungeon and type(roomId) == "number" then dungeon.roomsById[roomId] else nil
	if room and (room.roomType == RoomTypes.Miniboss or room.roomType == RoomTypes.Boss) then
		return
	end
	-- The row's `dropChance` (default 1): the kill drops at all, or not.
	local dropChance = gems.dropChance
	if type(dropChance) == "number" and math.random() >= dropChance then
		return
	end

	DropService.OnDropRequested:Fire(
		context.rootPart,
		DropTypes.Gems,
		gems.minDropRate,
		gems.maxDropRate,
		gems.minGems,
		gems.maxGems,
		false
	)
end

--[ Public ]--

-- Everything a player's takedown pays, in the order MobBase always ran it:
-- the two bomb relics, the Zombie Bomb cloud, per-assister payouts
-- (immediate, regardless of mob tier), then the corpse drops.
--
-- Encounter-tier mobs (miniboss / boss ROLE) drop NOTHING at the corpse:
-- their gear and coins are the reward CHEST's contents
-- (EncounterChestService, off the outro beat), so dropping them here as
-- well would pay the player twice. Without EncounterService (defensive)
-- they drop like a regular mob. EncounterService.OnEncounterOutroFinished
-- is the seam where corpse-side encounter rewards would go if any are
-- ever added back.
function MobDeath.RunKillerRewards(context: Context, killer: Player)
	lobBombs(context, killer, TRICK_OR_TRAP_BOMBS)
	lobBombs(context, killer, FUSE_BOMBS)
	runZombieBombCloud(context, killer)
	handleAssists(context)

	if context.isEncounter and EncounterService then
		return
	end
	dropGear(context)
	dropGems(context)
end

return MobDeath
