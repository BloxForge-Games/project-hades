--[[
    Author(s):
    Module: RelicService.lua
    Description:
]]

--[ Roblox Services ]--

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--[ Exports & Types & Defaults ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local RelicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicData)
local RelicRollConfig = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicRollConfig)
local RelicCapData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicCapData)
local Signal = require(ReplicatedStorage.Submodules.Core.Packages.Signal)
local RelicStackData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicStackData)
local ItemRarity = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ItemRarity)
local LootPlan = require(ReplicatedStorage.Submodules.Core.Libraries.LootPlan)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local ElementTreeData = require(ReplicatedStorage.Submodules.Core.Shared.Data.ElementTreeData)
local ElementTrees = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ElementTrees)
local RelicCombo = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicCombo)
local RoomTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RoomTypes)
local HumanoidProperties = require(ReplicatedStorage.Submodules.Core.Shared.Data.HumanoidProperties)
local findFloorBelow = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Dungeon.findFloorBelow)

-- Incremental Relics
local Fireworks = require(script.Incremental.Fireworks)
local GhostDragon = require(script.Incremental.GhostDragon)
local SuperStompBoots = require(script.Incremental.SuperStompBoots)

local DropService
local PlayerEventService
local IgnoreListService
local VFXService
local EncounterService

local RelicService = Knit.CreateService({
	Name = "RelicService",
	Client = {

		OnReplicateRelics = Knit.CreateSignal(),
		OnVolleyballEffectActivated = Knit.CreateSignal(),
		OnPumpkinEffectActivated = Knit.CreateSignal(),
		OnJailEffectActivated = Knit.CreateSignal(),
		OnFireworksEffectActivated = Knit.CreateSignal(),
		-- Super Stomp Boots: fired AFTER damage application from
		-- SuperStompBoots:InvokeStomp. Payload: (caster, landingPosition,
		-- radius, baseDamage). Designer wires VFX in RelicController's
		-- subscriber.
		OnSuperStompBoots = Knit.CreateSignal(),
		-- Ice Breaker's Shatter burst. Payload: (position). Fired from
		-- StatusConditionService when Chill lands on a Chilled target.
		OnShatterActivated = Knit.CreateSignal(),
		-- Throwing Bolts' Lightning Strike. Payload: (groundPosition).
		-- Fired from DamageService on a crit into a Shocked enemy.
		OnLightningStrikeActivated = Knit.CreateSignal(),
	},

	_relicLimitRegistry = {},
	_relicRegistry = {},
	-- [userId][relicName] = { id, name } — who ORIGINALLY put this relic
	-- on the floor, carried forward through every hand-off so the owner
	-- tag never becomes "whoever dropped it last".
	--
	-- Tracked per PLAYER rather than per item because a relic has no
	-- instance identity: the registry is a name and a count, so there is
	-- nothing to hang the origin on the way gear hangs it on its entry.
	-- Recorded when a public relic is picked up (Server/Components/Relic)
	-- and read back when that player drops it again.
	_relicOrigins = {},
	_incrementalCount = 0,
	_incrementalRegistry = {},
	_activeRegistry = {},
	_relicsList = {},
})

--[ Imports ]--

--[ Constants ]--

-- Default weighted rarity for relic rolls. Aligned with GDD §10.7 ability
-- chest rates. Callers (shrines, boss rewards, etc.) can pass their own
-- weights table to RollRandomRelic for custom distributions:
--   GDD Greater Shrine: { Rare=65, Epic=30, Legendary=5 }

-- Hard ceiling on DISTINCT relics a player can own in a run. SHARED with
-- the client (Shared/Data/RelicCapData) so the pickup component can refuse
-- WITHOUT consuming the relic, and the relic interface can size itself.
local MAX_OWNED_RELICS = RelicCapData.MaxOwnedRelics

-- PURE RANDOM SELECTION -- rarity is rolled from the run-stage table in
-- Shared/Data/RelicRollConfig, then the relic is picked uniformly from that
-- rarity. No build weighting of any kind.

-- Build rarity buckets from RelicData once at module load. Each bucket holds
-- the list of relic names available at that rarity, so RollRandomRelic can
-- do an O(1) random pick after the weighted rarity roll.
local relicsByRarity: { [string]: { string } } = {}
for relicName, data in RelicData do
	local rarity = data.rarity
	if not relicsByRarity[rarity] then
		relicsByRarity[rarity] = {}
	end
	table.insert(relicsByRarity[rarity], relicName)
end

--[ Properties ]--

RelicService.Signals = {
	OnRelicsUpdated = Signal.new(),
}

--[ Private Functions ]--

-- Destroys the player's Ghost Dragon visual if it exists. The part lives at
-- workspace.IgnoreInstances.MagicSpells.GhostDragon_<userId> (parented there
-- — instead of under the character — so Model:PivotTo on the character can't
-- mangle its rotation during encounter teleports). Because it's outside the
-- character tree, it does NOT get destroyed on character respawn the way a
-- character-parented part would; we have to clean it up explicitly on
-- CharacterRemoving (the next relic tick will recreate it bound to the
-- fresh HRP) and on PlayerRemoving.
function RelicService:_cleanupGhostDragon(userId: number)
	local ignoreInstances = workspace:FindFirstChild("IgnoreInstances")
	local magicSpells = ignoreInstances and ignoreInstances:FindFirstChild("MagicSpells")
	if not magicSpells then
		return
	end
	local part = magicSpells:FindFirstChild("GhostDragon_" .. userId)
	if part then
		part:Destroy()
	end
end

function RelicService:_fireworks(userId: number)
	local player = Players:GetPlayerByUserId(userId)
	-- Periodic relics (Fireworks, Ghost Dragon) never fire into a cutscene.
	if EncounterService and EncounterService.IsCutsceneActive and EncounterService:IsCutsceneActive() then
		return
	end

	local fireworkCount = self:GetSpecificRelicRegistry(player, RelicNames["Summer Fireworks"])
	local ghostDragonCount = self:GetSpecificRelicRegistry(player, RelicNames["Ghost Dragon"])

	if
		fireworkCount ~= 0 and (self._incrementalRegistry[userId] % RelicData["Summer Fireworks"].data.interval == 0)
	then
		Fireworks.new(
			player,
			self:GetRelicEffect(player, RelicNames["Summer Fireworks"]),
			self,
			VFXService,
			IgnoreListService
		)
			:InvokeFireworks()
	end

	if
		ghostDragonCount ~= 0
		and self._incrementalRegistry[userId] % RelicData["Ghost Dragon"].data.minInterval == 0
	then
		GhostDragon.new(
			player,
			self:GetSpecificRelicRegistry(player, RelicNames["Ghost Dragon"]),
			self,
			VFXService,
			IgnoreListService
		)
			:InvokeGhostDragon()
	end
end

function RelicService:_incrementalRelicEffects()
	for userId, _ in self._relicRegistry do
		self._incrementalRegistry[userId] += 1

		self:_fireworks(userId)

		if self._incrementalRegistry[userId] >= 100 then
			self._incrementalRegistry[userId] = 0
		end
	end
end

--[ Public Functions ]--

function RelicService:GetRelicLimitRegistry(relicName: string)
	return self._relicLimitRegistry[relicName]
end

function RelicService:SetRelicLimitRegistry(relicName: string, limit: number)
	self._relicLimitRegistry[relicName] = limit
end

function RelicService:GetRelicActiveModule(player: Player, moduleName: string)
	if self._activeRegistry[moduleName] == nil then
		return
	end

	self._activeRegistry[moduleName].new(player):Invoke()
end

-- Single fan-out for "player perfect-dodged something". Used to be
-- inlined at every perfect-dodge call site (melee mob swing dodge,
-- projectile dodge) which made it hard to add new relic effects that
-- needed the same trigger. Now each perfect-dodge site calls this
-- one method and any new relic just adds another branch here.
--
-- Currently triggers:
--   * Experimental Jetpack — 2s invulnerable jetpack
--
-- Jetpack is gated internally via its own active-module ownership
-- check, so calling this on every perfect dodge is always safe.
--
-- Attack Doge USED to flag DamageService for a forced crit on the
-- next non-magic hit, and later became a target-HP damage module.
-- Both designs were scrapped — it is now a crit-chance relic whose
-- Adrenaline proc rides DamageService:_postDamage's `wasCrit`, so it
-- needs no perfect-dodge hook either way.
function RelicService:OnPlayerPerfectDodged(player: Player)
	-- Jetpack proc — existing behavior, kept identical. GetRelicActiveModule
	-- internally checks ownership before invoking.
	self:GetRelicActiveModule(player, "Jetpack")

	-- The element rework removed the other perfect-dodge relics (Speedy
	-- Shoes' Adrenaline died with that aura; Robloxian Battle Shield now
	-- procs on MAGIC USE via VFXService -> ShieldService).
end

-- Server-side effective BASE walkspeed — the authoritative mirror of
-- the client helper Shared/Functions/Movement/getEffectiveBaseWalkSpeed
-- (keep the two in sync):
--   baseline + flat base-walkspeed relic callbacks (Speed Coil) + the
--   WalkSpeedBonus stat attribute (PlayerStatsService —
--   Astral Cloak's +5),
--   then × Slateskin Potion's 0.50 while owned,
--   then × Slateskin's 0.5 / Stormcharged's 1.10 while up.
-- Jetpack flight multiplies its own ×1.5 on top at its call sites.
local BASE_WALKSPEED_RELICS = {
	RelicNames["Speed Coil"],
}
-- Slateskin Potion HALVES the effective base (its callback owns the 0.50).
-- Keep in sync with the client mirror, getEffectiveBaseWalkSpeed.

function RelicService:GetEffectiveBaseWalkSpeed(player: Player): number
	local total = HumanoidProperties.WalkSpeed
	for _, relicName in BASE_WALKSPEED_RELICS do
		if self:GetSpecificRelicRegistry(player, relicName) > 0 then
			total += self:GetRelicEffect(player, relicName) or 0
		end
	end
	total += player:GetAttribute("WalkSpeedBonus") or 0

	-- Slateskin's halving, applied to the summed base so it scales the flat
	-- bonuses above rather than being outrun by them.
	if self:GetSpecificRelicRegistry(player, RelicNames["Slateskin Potion"]) > 0 then
		total *= self:GetRelicEffect(player, RelicNames["Slateskin Potion"]) or 1
	end

	return total
end

function RelicService:GetRelicsRegistry(player: Player)
	return table.clone(self._relicRegistry[player.UserId] or {})
end

function RelicService:GetSpecificRelicRegistry(player: Player, relic: RelicNames.RelicNames)
	return self._relicRegistry[player.UserId] and self._relicRegistry[player.UserId][relic] or 0
end

-- Grants a relic to the player. Per the single-stack design rule,
-- this is a HARD NO-OP if the player already owns the relic at the
-- per-rarity cap (which is 1 for every rarity — see RelicStackData).
--
-- The earlier implementation relied on math.clamp to enforce the cap,
-- which kept the count correct but ran the relic's active callback on
-- EVERY pickup attempt regardless. That meant a second Cheeseburger
-- pickup re-applied the +20% MaxHealth bonus, and any future active
-- relic would silently double-dip its side effect on duplicate pickup.
-- The early return below makes the cap enforce side effects too, not
-- just the registry number.
--
-- We also skip firing OnReplicateRelics / OnRelicsUpdated when nothing
-- changed. Listeners (DodgeService for Gravity Coil, UI controllers
-- for the relic tray, …) subscribe to those signals; a no-op pickup
-- shouldn't wake them up.
function RelicService:AddRelicsRegistry(player: Player, relic: string, count: number): boolean
	local registry = self._relicRegistry[player.UserId]

	if not registry then
		self._relicRegistry[player.UserId] = {}
		registry = self._relicRegistry[player.UserId]
	end

	-- Single-stack guard. Return BEFORE adding to the visible relics
	-- list / firing replication so a redundant pickup is silent.
	local cap = RelicStackData[RelicData[relic].rarity] or 1
	local currentCount = registry[relic] or 0
	if currentCount >= cap then
		return false
	end

	-- Relic cap backstop. Pickup paths (Relic component) check
	-- CanAcceptRelic FIRST and show the indicator without consuming
	-- anything; this guard only catches grant paths that skipped it.
	if not self:CanAcceptRelic(player, relic) then
		return false
	end

	if table.find(self._relicsList[player.UserId], relic) == nil then
		table.insert(self._relicsList[player.UserId], relic)
	end

	registry[relic] = math.clamp(currentCount + count, 0, cap)

	if RelicData[relic].active then
		RelicData[relic].callback(player, registry[relic])
	end

	self.Client.OnReplicateRelics:FireAll(player.UserId, self._relicRegistry, self._relicsList)

	RelicService.Signals.OnRelicsUpdated:Fire(player, relic, registry[relic], self._relicsList)
	self:_publishOwnedRelicCount(player)
	-- Ticks on EVERY successful pickup, including one that only deepens a
	-- stack. OwnedRelicCount cannot serve this: it is the number of
	-- DISTINCT relics held (it also gates the relic cap), so a stacking
	-- pickup leaves it unchanged and a listener watching it for "I gained
	-- something" silently misses those.
	player:SetAttribute(Attributes.RelicsGained, (player:GetAttribute(Attributes.RelicsGained) or 0) + 1)
	return true
end

-- The "a relic just left this player" flourish, visible to EVERYONE:
-- the RemoveRelicShockwave VFX part cloned to the character's HRP and
-- burst once (server-side clone — it replicates on its own). Called
-- by the tray's Destroy and the Merchant's sell (EventService).
-- Same one-shot recipe as AuraService's aura shockwaves.
function RelicService:PlayRelicRemovedFX(player: Player)
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return
	end
	local vfxFolder = ReplicatedStorage.GameAssets:FindFirstChild("VFX")
	local template = vfxFolder and vfxFolder:FindFirstChild("RemoveRelicShockwave")
	if not template then
		warn("[RelicService] Missing GameAssets.VFX.RemoveRelicShockwave")
		return
	end
	-- Cloned as a WHOLE PART and left where it spawned — a ground
	-- shockwave, not a rider. Parenting the template's attachment into
	-- the HRP instead was tried and reverted (same call as the aura
	-- shockwaves): riding the character made the burst read wrong, since
	-- an attachment inherits the HRP's orientation and drags the ground
	-- plane around with the player.
	local shockwave = template:Clone()
	if shockwave:IsA("BasePart") then
		shockwave.Anchored = true
		shockwave.CanCollide = false
		shockwave.CanQuery = false
	end
	shockwave:PivotTo(hrp.CFrame)
	shockwave.Parent = workspace.IgnoreInstances.MagicSpells
	-- Parent FIRST, burst SECOND — :Emit on an unparented emitter is
	-- silently discarded.
	for _, descendant in shockwave:GetDescendants() do
		if descendant:IsA("ParticleEmitter") then
			descendant:Emit(2)
		end
	end
	Debris:AddItem(shockwave, 3)
end

-- Tray DROP: the ring around the player the relic lands in (a random
-- bearing at a random distance between the two), and where the toss
-- starts (chest height, so the arc reads as thrown, not spawned).
-- Scattered rather than always straight ahead: dropping several relics
-- in a row used to pile them on one spot, and the top one hid the rest.
local DROP_RELIC_MIN_RADIUS_STUDS = 4
local DROP_RELIC_MAX_RADIUS_STUDS = 8
local DROP_RELIC_ORIGIN_UP_STUDS = 2
-- Floor find under the player for the landing height (relic drops sit a
-- fixed offset above TargetPosition, client-side). Fallback when no
-- Floor is under them: an R15 root sits about this far above the ground.
local DROP_RELIC_FLOOR_CAST_UP = 5
local DROP_RELIC_FLOOR_CAST_DEPTH = 50
local DROP_RELIC_ROOT_ABOVE_FLOOR = 3

-- Remembers who ORIGINALLY dropped a relic this player has just picked
-- up off the floor, so dropping it again re-stamps THEIR name rather
-- than this player's. Called by the Relic component on an accepted
-- pickup; a nil origin (a machine offer, an event reward, mob loot)
-- clears any stale note, making the next drop the item's first.
function RelicService:SetRelicOrigin(player: Player, relicName: string, originId: number?, originName: string?)
	local origins = self._relicOrigins[player.UserId]
	if not origins then
		origins = {}
		self._relicOrigins[player.UserId] = origins
	end
	if type(originId) == "number" and type(originName) == "string" then
		origins[relicName] = { id = originId, name = originName }
	else
		origins[relicName] = nil
	end
end

-- Player-initiated DROP from the relic tray: the relic leaves the
-- registry and lands on the floor ahead of the player as a PUBLIC drop
-- (DropService, Attributes.PublicDrop) that anyone can pick back up, the
-- dropper included. Nothing is paid (that is the Merchant's SELL in
-- EventService) and nothing is lost. Cursed relics are refused: their
-- drawback is the price of their payoff, and dropping one would make
-- the trade-off free. Validated server-side; the tray button is only a
-- request, and it greys Cursed out on its own. Replaced DestroyRelic.
function RelicService.Client:DropRelic(player: Player, relicName: string): boolean
	if typeof(relicName) ~= "string" or not RelicData[relicName] then
		return false
	end
	if RelicData[relicName].rarity == ItemRarity.Cursed then
		return false
	end
	if RelicService:GetSpecificRelicRegistry(player, relicName) <= 0 then
		return false
	end
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not hrp or not DropService then
		return false
	end

	RelicService:RemoveRelicsRegistry(player, relicName, 1)
	RelicService:PlayRelicRemovedFX(player)

	-- Tossed to a random spot in the ring around the player, at floor
	-- height. A wall in the way is DropService's problem: the arc
	-- ricochets back into the room.
	local rootPosition = hrp.Position
	local floorY = rootPosition.Y - DROP_RELIC_ROOT_ABOVE_FLOOR
	local floor = findFloorBelow(
		rootPosition.X,
		rootPosition.Z,
		rootPosition.Y + DROP_RELIC_FLOOR_CAST_UP,
		DROP_RELIC_FLOOR_CAST_DEPTH
	)
	if floor then
		floorY = floor.Y
	end
	local origin = rootPosition + Vector3.new(0, DROP_RELIC_ORIGIN_UP_STUDS, 0)
	local bearing = math.random() * math.pi * 2
	local radius = DROP_RELIC_MIN_RADIUS_STUDS
		+ math.random() * (DROP_RELIC_MAX_RADIUS_STUDS - DROP_RELIC_MIN_RADIUS_STUDS)
	local target =
		Vector3.new(rootPosition.X + math.cos(bearing) * radius, floorY, rootPosition.Z + math.sin(bearing) * radius)
	-- The ORIGINAL owner if this relic came off the floor, otherwise this
	-- player is the original. Cleared afterwards: the relic is no longer
	-- theirs, and whoever picks it up records the origin for themselves.
	local origins = RelicService._relicOrigins[player.UserId]
	local recorded = origins and origins[relicName]
	if origins then
		origins[relicName] = nil
	end

	DropService.OnRelicDropRequested:Fire(player, RelicData[relicName].rarity, relicName, origin, target, {
		public = true,
		originalOwnerId = (recorded and recorded.id) or player.UserId,
		originalOwnerName = (recorded and recorded.name) or player.Name,
	})
	return true
end

function RelicService:RemoveRelicsRegistry(player: Player, relic: string, count: number)
	local registry = self._relicRegistry[player.UserId]

	if not registry then
		self._relicRegistry[player.UserId] = {}
		registry = self._relicRegistry[player.UserId]
	end

	registry[relic] = math.clamp((registry[relic] or 0) - count, 0, RelicStackData[RelicData[relic].rarity])

	if registry[relic] == 0 then
		registry[relic] = nil

		local index = table.find(self._relicsList[player.UserId], relic)

		if index then
			table.remove(self._relicsList[player.UserId], index)
		end
	end

	self.Client.OnReplicateRelics:FireAll(player.UserId, self._relicRegistry, self._relicsList)

	RelicService.Signals.OnRelicsUpdated:Fire(player, relic, registry[relic], self._relicsList)
	self:_publishOwnedRelicCount(player)
end

function RelicService:GetRelicEffect(player: Player, relicName: RelicNames.RelicNames): any?
	if
		self._relicRegistry[player.UserId]
		and self._relicRegistry[player.UserId][relicName]
		and self._relicRegistry[player.UserId][relicName] > 0
	then
		return RelicData[relicName].callback(player, self._relicRegistry[player.UserId][relicName])
	end

	return false
end

function RelicService:GetPlayerAvailableRelics(player: Player): { RelicNames.RelicNames }
	local unstacked = {}

	for relicName, relicInfo in RelicData do
		local maxStack = RelicStackData[relicInfo.rarity]
		if (self._relicRegistry[player.UserId] and self._relicRegistry[player.UserId][relicName] or 0) < maxStack then
			table.insert(unstacked, relicName)
		end
	end

	return unstacked
end

-- Same weighted-rarity roll as RollRandomRelic, but restricted to a
-- caller-supplied pool of relic names (e.g. "the relics this player hasn't
-- fully stacked yet"). Buckets the pool by rarity using RelicData, builds a
-- LootPlan from only the rarities that have at least one entry in the pool,
-- rolls a rarity, then picks a uniformly-random relic from that bucket.
-- Returns (relicName, rarity), or (nil, nil) if the pool is empty.
--
-- This is what RelicMachine (vending machines) uses so per-player exclusions
-- (fully-stacked relics) still respect the global rarity weights instead of
-- flat-rolling and accidentally biasing toward whichever rarity happens to
-- have the most available relics in the pool.
-- "This player has made their relic choice" -- fired by the SKIP offer,
-- which grants nothing but must still satisfy everything keyed off a choice
-- (chiefly DungeonService's gate cycle, which ends its countdown early once
-- every alive player has chosen).
--
-- Reuses OnRelicsUpdated deliberately: that signal already IS the
-- "this player's relics changed / they interacted with a machine" broadcast,
-- and all three listeners (DungeonService, DodgeService, PlayerStatsService)
-- read only the `player` argument. The trailing nils are therefore safe, and
-- the recomputes they trigger are idempotent.
function RelicService:MarkRelicChoiceMade(player: Player)
	RelicService.Signals.OnRelicsUpdated:Fire(player, nil, nil, self._relicsList)
end

-- Number of DISTINCT relics the player owns (the MAX_OWNED_RELICS pool).
-- Publishes the owned-relic count onto the PLAYER, where anything
-- cosmetic can watch it without a remote. The attribute has existed in
-- the enum since before anything wrote it; the Spirit Companion's
-- celebrate reaction is the first reader, and it needs a replicated
-- signal that a relic was gained which every client can see for every
-- player, not just their own.
--
-- On the PLAYER rather than the character so it survives a respawn.
function RelicService:_publishOwnedRelicCount(player: Player)
	player:SetAttribute(Attributes.OwnedRelicCount, self:GetOwnedRelicCount(player))
end

function RelicService:GetOwnedRelicCount(player: Player): number
	return #(self._relicsList[player.UserId] or {})
end

-- True once the player holds the maximum number of DISTINCT relics. The
-- vending machine reads this to decide whether to dispense the Skip offer:
-- a capped player cannot claim anything, so the Skip is their only way to
-- clear the pull and open the gate.
function RelicService:IsAtRelicCap(player: Player): boolean
	return self:GetOwnedRelicCount(player) >= MAX_OWNED_RELICS
end

-- False when granting `relic` would exceed the relic cap: the player is at
-- MAX_OWNED_RELICS and doesn't already own this one (owned relics re-trigger
-- the per-relic stack guard instead). Pickup paths check this BEFORE
-- consuming anything so a refused grab wastes nothing.
function RelicService:CanAcceptRelic(player: Player, relic: string): boolean
	local registry = self._relicRegistry[player.UserId]
	if registry and (registry[relic] or 0) > 0 then
		return true
	end
	return self:GetOwnedRelicCount(player) < MAX_OWNED_RELICS
end

-- Mechanics the player can currently PRODUCE: the union of every owned
-- relic's `grants`. This is what relic prerequisites are checked against --
-- never `tags`, since a relic can SCALE off Burn while applying none of it
-- (Dragon's Breath Potion).
--
-- Conditional granters (Flaming Mace applies Burn only while Frenzied) count
-- unconditionally, and under STRICT gating that is correct: Flaming Mace is
-- itself gated behind Frenzy, so owning it already implies owning a Frenzy
-- source. The dependency resolves itself.
function RelicService:GetGrantedMechanics(player: Player): { [string]: boolean }
	local granted = {}
	local registry = self._relicRegistry[player.UserId]
	if not registry then
		return granted
	end

	for relicName, count in registry do
		if typeof(count) ~= "number" or count <= 0 then
			continue
		end
		local data = RelicData[relicName]
		if data and data.grants then
			for _, mechanic in data.grants do
				granted[mechanic] = true
			end
		end
	end
	return granted
end

--[ Element affinity ]--

-- How many relics of `tree` the player already owns. Drives the affinity
-- weight below; Neutral is never counted because it is exempt.
function RelicService:GetOwnedTreeCount(player: Player, tree: string): number
	local registry = self._relicRegistry[player.UserId]
	if not registry or not tree or tree == ElementTrees.Neutral then
		return 0
	end
	local count = 0
	for relicName, owned in registry do
		if typeof(owned) == "number" and owned > 0 then
			local data = RelicData[relicName]
			if data and data.tree == tree then
				count += 1
			end
		end
	end
	return count
end

-- How many ELEMENTAL relics the player owns, across every tree. Both
-- dampeners key off this rather than off distinct-tree count: a
-- distinct-tree gate never fires for a mono-element build, and that is
-- precisely the build the drift hurts most.
function RelicService:GetOwnedElementalCount(player: Player): number
	local registry = self._relicRegistry[player.UserId]
	if not registry then
		return 0
	end
	local count = 0
	for relicName, owned in registry do
		if typeof(owned) == "number" and owned > 0 then
			local data = RelicData[relicName]
			if data and data.tree and data.tree ~= ElementTrees.Neutral then
				count += 1
			end
		end
	end
	return count
end

-- The roll-weight multiplier for one relic's tree, from how much of that
-- tree the player has already committed to.
--
-- NOTHING IS EVER LOCKED OUT: every tree can always appear. A run narrows
-- because the trees you are actually building get heavier, not because the
-- others are removed -- so a fifth-element relic stays possible to the end,
-- just increasingly rare. Neutral is exempt and always returns 1.
function RelicService:GetElementAffinityWeight(relicName: string, player: Player?): number
	local data = RelicData[relicName]
	local tree = data and data.tree
	if not player or not tree then
		return 1
	end

	local elemental = self:GetOwnedElementalCount(player)

	-- NEUTRAL. Shrinks as the player commits, on its own curve. It has no
	-- tree to be committed TO, so it reads the elemental total instead.
	if tree == ElementTrees.Neutral then
		local neutralCurve = RelicRollConfig.NeutralAffinityWeights
		if not neutralCurve or #neutralCurve == 0 then
			return 1
		end
		return neutralCurve[math.clamp(elemental + 1, 1, #neutralCurve)]
	end

	local curve = RelicRollConfig.ElementAffinityWeights
	if not curve or #curve == 0 then
		return 1
	end
	-- index 1 == owning none of that tree; anything past the curve's end
	-- holds at its last value.
	local count = self:GetOwnedTreeCount(player, tree)
	local weight = curve[math.clamp(count + 1, 1, #curve)]

	-- A tree the player has NO foothold in, once committed. This is the
	-- only subtractive term in the whole roll — everything else only ever
	-- adds tickets, which is why affinity alone could never narrow a run.
	if count == 0 and elemental >= (RelicRollConfig.UnexploredDampenerGate or math.huge) then
		weight *= RelicRollConfig.UnexploredDampener or 1
	end
	return weight
end

-- The roll-weight multiplier for a KEYSTONE relic — the card its tree is
-- built around (RelicData's `keystone`). Worth more only once the player
-- has a foothold in that tree, so a first-ever Frost offer is not steered
-- toward Ice Breaker; from the moment they own one Frost relic, the tree's
-- centrepiece is what it tries to complete them with. 1 for everything
-- else, so the multiply is a no-op on the rest of the pool.
function RelicService:GetKeystoneWeight(relicName: string, player: Player?): number
	local data = RelicData[relicName]
	if not player or not data or not data.keystone then
		return 1
	end
	local tree = data.tree
	if not tree or tree == ElementTrees.Neutral then
		return 1
	end
	local gate = RelicRollConfig.KeystoneFootholdGate or 1
	if self:GetOwnedTreeCount(player, tree) < gate then
		return 1
	end
	return RelicRollConfig.KeystoneWeight or 1
end

-- The UNOWNED, ungated (NC) relics of one tree. The starter machine uses
-- this to guarantee a foothold in each of the run's two elements.
function RelicService:GetUnownedNCRelicsForTree(player: Player, tree: string): { string }
	local registry = self._relicRegistry[player.UserId] or {}
	local found = {}
	for relicName, data in RelicData do
		if data.tree == tree and (data.combo == nil or data.combo == RelicCombo.NC) then
			if (registry[relicName] or 0) == 0 then
				table.insert(found, relicName)
			end
		end
	end
	return found
end

-- May this relic be OFFERED to this player? Combo gating (the sheet's
-- NC / C / C2 column, RelicData's `combo` field):
--   NC  always offerable.
--   C   the player can produce the relic's tree STATUS or AURA.
--   C2  the player can produce BOTH.
-- A relic carrying `requiredTags` / `requiredRelics` REPLACES the
-- tree-pair check with those explicit prerequisites: every listed tag
-- must be producible and every listed relic OWNED (Staff of Azure Ever
-- Ice: Frostburst + Ice Breaker — the relic it upgrades, not just the
-- tree's status). `ownerPlayer` is only needed for the ownership half.
-- "Can produce" = GetGrantedMechanics (union of owned `grants`), checked
-- against the tree's pair in ElementTreeData. Neutral relics carry no
-- pair and are always offerable. An offer should never be something you
-- cannot use.
function RelicService:IsRelicRollEligible(
	relicName: string,
	granted: { [string]: boolean },
	ownerPlayer: Player?
): boolean
	local data = RelicData[relicName]
	if not data then
		return false
	end

	-- Explicit prerequisites replace the tree-pair check entirely.
	if data.requiredTags or data.requiredRelics then
		for _, tag in (data.requiredTags or {}) :: { string } do
			if granted[tag] ~= true then
				return false
			end
		end
		for _, requiredName in (data.requiredRelics or {}) :: { string } do
			if not ownerPlayer or (self:GetSpecificRelicRegistry(ownerPlayer, requiredName) or 0) <= 0 then
				return false
			end
		end
		return true
	end

	if data.combo == nil or data.combo == RelicCombo.NC then
		return true
	end

	local treeData = data.tree and ElementTreeData[data.tree]
	local statusTag = treeData and treeData.statusTag
	local auraTag = treeData and treeData.auraTag
	if not statusTag or not auraTag then
		return true -- no pair to gate on (Neutral) -- never lock a relic out
	end

	local hasStatus = granted[statusTag] == true
	local hasAura = granted[auraTag] == true
	if data.combo == RelicCombo.C then
		return hasStatus or hasAura
	end
	return hasStatus and hasAura -- C2
end

-- Run stage, used ONLY for the rarity table (Early / Mid / Late odds), read
-- from the existing run progression: DungeonService's 1-based dungeon index
-- over Shared/Data/DungeonSequence. No run in progress (lobby, Studio solo)
-- falls back to Early.
function RelicService:GetRunStage(): string
	local ok, index = pcall(function()
		return Knit.GetService("DungeonService"):GetRunDungeonIndex()
	end)
	if not ok or type(index) ~= "number" or index <= 1 then
		return "Early"
	elseif index == 2 then
		return "Mid"
	end
	return "Late"
end

-- Rarity for one offer. Rolled INDEPENDENTLY of relic selection and of how
-- many relics each rarity holds (41 Epics vs 40 Rares must not skew the
-- odds), from the run-stage table in RelicRollConfig. Rarities with no
-- candidate are simply absent from the plan, which IS the graceful fallback.
-- Cursed never appears -- it has no entry in any stage table.
function RelicService:RollRelicRarity(poolByRarity: { [string]: { string } }, stage: string, luck: number?): string?
	local weights = RelicRollConfig.RarityWeights[stage] or RelicRollConfig.RarityWeights.Early
	local plan = LootPlan.new("single")
	local any = false
	for rarity, weight in weights do
		if weight > 0 and poolByRarity[rarity] and #poolByRarity[rarity] > 0 then
			plan:AddLoot(rarity, weight)
			any = true
		end
	end
	if not any then
		return nil
	end
	return plan:GetRandomLoot(luck or 1)
end

-- Rolls ONE relic for an offer slot. TWO steps, and nothing else:
--   1. Drop candidates the player cannot USE (rollPrerequisites unmet).
--   2. Roll a RARITY from the run-stage table (rarity pacing is the only
--      weighting in the system).
--   3. Pick UNIFORMLY at random from that rarity's bucket.
--
-- Past that eligibility filter there is NO build weighting -- no synergy or
-- wildcard slots, no tag multipliers. Every USABLE relic is equally likely
-- within its rarity; playtesting found weighted offers felt steered.
-- `ownerPlayer` is whose ownership the eligibility check reads; nil skips
-- the filter entirely.
--
--   `availableRelics`  caller's candidate list (already ownership- and
--                      duplicate-filtered -- RelicMachine owns those rules).
--   `weights`          legacy per-rarity override; nil uses the run-stage
--                      table (the normal path). Pinata passes one.
--   `luck`             LootPlan luck passthrough.
--
-- Returns (relicName, rarity), or (nil, nil) when the pool is empty.
function RelicService:RollRandomRelicFromPool(
	availableRelics: { string },
	weights: { [string]: number }?,
	luck: number?,
	ownerPlayer: Player?
): (string?, string?)
	if not availableRelics or #availableRelics == 0 then
		return nil, nil
	end

	local granted = if ownerPlayer then self:GetGrantedMechanics(ownerPlayer) else nil

	-- Bucket the USABLE pool by rarity. Filtering BEFORE the rarity roll
	-- matters: a rarity whose every candidate is gated must not stay in the
	-- plan, or the roll could land on a bucket with nothing pickable in it.
	local poolByRarity: { [string]: { string } } = {}
	for _, relicName in availableRelics do
		local data = RelicData[relicName]
		local comboOk = not granted or self:IsRelicRollEligible(relicName, granted, ownerPlayer)
		if data and comboOk then
			poolByRarity[data.rarity] = poolByRarity[data.rarity] or {}
			table.insert(poolByRarity[data.rarity], relicName)
		end
	end

	local rolledRarity
	if weights then
		-- Legacy explicit-weights path (Pinata's premium filter).
		local plan = LootPlan.new("single")
		local any = false
		for rarity, weight in weights do
			if weight > 0 and poolByRarity[rarity] and #poolByRarity[rarity] > 0 then
				plan:AddLoot(rarity, weight)
				any = true
			end
		end
		rolledRarity = if any then plan:GetRandomLoot(luck or 1) else nil
	else
		rolledRarity = self:RollRelicRarity(poolByRarity, self:GetRunStage(), luck)
	end
	if not rolledRarity then
		return nil, nil
	end

	local bucket = poolByRarity[rolledRarity]
	if not bucket or #bucket == 0 then
		return nil, nil
	end

	-- Weighted pick INSIDE the bucket, from TWO independent multipliers:
	--
	--   ComboWeights     how deep the relic sits in its tree. Everything
	--                    here already passed the combo filter, so a C / C2
	--                    tag means the player unlocked it.
	--   element affinity how committed the player already is to that tree.
	--                    This is what narrows a run: no tree is ever
	--                    removed, the ones you are building just get more
	--                    tickets. Neutral always weighs 1.
	--   keystone         a tree's CENTREPIECE, once the player has any
	--                    foothold in it (Ice Breaker for Frost). 1 for
	--                    everything else.
	local function weightOf(relicName: string): number
		local combo = RelicData[relicName] and RelicData[relicName].combo
		local comboWeight = RelicRollConfig.ComboWeights[combo] or 1
		return comboWeight
			* self:GetElementAffinityWeight(relicName, ownerPlayer)
			* self:GetKeystoneWeight(relicName, ownerPlayer)
	end

	local totalWeight = 0
	for _, relicName in bucket do
		totalWeight += weightOf(relicName)
	end
	if totalWeight <= 0 then
		return bucket[math.random(1, #bucket)], rolledRarity
	end

	local roll = math.random() * totalWeight
	for _, relicName in bucket do
		roll -= weightOf(relicName)
		if roll <= 0 then
			return relicName, rolledRarity
		end
	end
	-- Float drift only; the loop above all but always returns.
	return bucket[#bucket], rolledRarity
end

--[ Initializers ]--

-- Holiday Ham: "increase your character size by +20%". Model:ScaleTo sets
-- an ABSOLUTE scale factor relative to the model's authored size, so this
-- is idempotent -- calling it twice does not compound to 1.44 -- and it
-- scales everything parented under the character with it (accessories,
-- welded weapons, the hitbox).
--
-- Re-applied on respawn because a fresh character always starts at 1.
local HOLIDAY_HAM_CHARACTER_SCALE = 1.20

-- Applies (or clears) the Ham size. Runs on pickup AND respawn, and
-- deliberately handles the NOT-owned case too: without the reset branch a
-- player who somehow loses the relic would keep the scale for the rest of
-- the run, since nothing else ever writes it back.
function RelicService:_applyHolidayHamScale(player: Player)
	local character = player.Character
	if not character or not character.PrimaryPart then
		return
	end

	local owned = self:GetSpecificRelicRegistry(player, RelicNames["Holiday Ham"]) > 0
	local targetScale = if owned then HOLIDAY_HAM_CHARACTER_SCALE else 1
	if character:GetScale() == targetScale then
		return -- already there; skip the rescale and its joint churn
	end
	character:ScaleTo(targetScale)
end

-- Sword of the Epicredness: a permanent crimson aura while owned --
-- GameAssets.Auras.Crimson's emitters cloned into every body part
-- (Frenzy-style), re-applied on respawn. Server-side clones, so every
-- client sees it. Idempotent via the marker name.
local CRIMSON_CLONE_NAME = "CrimsonRelicAura"
local CRIMSON_BODY_PARTS = { "HumanoidRootPart", "Head", "Left Arm", "Right Arm", "Left Leg", "Right Leg" }

function RelicService:_applyCrimsonAura(player: Player)
	if self:GetSpecificRelicRegistry(player, RelicNames["Sword of the Epicredness"]) <= 0 then
		return
	end
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not hrp or hrp:FindFirstChild(CRIMSON_CLONE_NAME) then
		return
	end
	local auraTemplate = ReplicatedStorage.GameAssets.Auras:FindFirstChild("Crimson")
	if not auraTemplate then
		warn("[RelicService] Missing ReplicatedStorage.GameAssets.Auras.Crimson")
		return
	end
	for _, partName in CRIMSON_BODY_PARTS do
		local bodyPart = character:FindFirstChild(partName)
		if not bodyPart then
			continue
		end
		for _, particle in auraTemplate:GetDescendants() do
			if particle:IsA("ParticleEmitter") then
				local clone = particle:Clone()
				clone.Name = CRIMSON_CLONE_NAME
				clone.Enabled = true
				clone.Parent = bodyPart
			end
		end
	end
end

function RelicService:KnitStart()
	DropService = Knit.GetService("DropService")
	EncounterService = Knit.GetService("EncounterService")
	PlayerEventService = Knit.GetService("PlayerEventService")
	VFXService = Knit.GetService("VFXService")
	IgnoreListService = Knit.GetService("IgnoreListService")

	-- Super Stomp Boots — constructed per dodge-land event for owners.
	-- Mirrors the Fireworks pattern (`SuperStompBoots.new(...):InvokeStomp()`)
	-- rather than the old singleton .Start() style; one short-lived
	-- instance per stomp, garbage-collected after :InvokeStomp returns.
	-- Ownership gate lives here so the class itself stays focused on
	-- "do the AOE", not "decide whether to fire".
	local DodgeService = Knit.GetService("DodgeService")
	local DamageIndicatorService = Knit.GetService("DamageIndicatorService")

	DodgeService.Signals.OnDodgeLanded:Connect(function(player: Player, landingPosition: Vector3)
		-- Callback now returns the per-level base damage (25), not a
		-- MaxHP fraction. SuperStompBoots multiplies by the player's
		-- profile.Level and routes through TakeDamage.
		local damagePerLevel = self:GetRelicEffect(player, RelicNames["Super Stomp Boots"])

		if not damagePerLevel then
			return
		end

		SuperStompBoots.new(player, damagePerLevel, landingPosition, self, IgnoreListService, DamageIndicatorService)
			:InvokeStomp()
	end)

	-- Apple Pie (Rare): clearing ANY dungeon room restores 8% Maximum
	-- Health to relic owners. THREE signals cover every room type:
	--   * OnSegmentCleared — Combat segment clears AND miniboss defeats
	--     (the miniboss room is its own segment and fires this on death).
	--   * OnDungeonCompleted — the Boss defeat (that path returns before
	--     OnSegmentCleared fires, so it needs its own hook).
	--   * OnRoomEntered — EVENT rooms. Nothing spawns in one, so an
	--     event room never "clears"; walking in IS the clear (design
	--     call). Per-player by nature: the signal fans out one call per
	--     player as the party's cursors advance, and it fires once per
	--     room, so there is no double-heal to guard against.
	local APPLE_PIE_HEAL_FRACTION = 0.08
	local DungeonService = Knit.GetService("DungeonService")

	local function healApplePieOwner(player: Player)
		if self:GetSpecificRelicRegistry(player, RelicNames["Apple Pie"]) <= 0 then
			return
		end
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health > 0 then
			-- Through ApplyHealing so Holiday Ham's +50% applies, same as
			-- every other mid-run restore.
			Knit.GetService("PlayerStatsService"):ApplyHealing(player, humanoid.MaxHealth * APPLE_PIE_HEAL_FRACTION)
		end
	end

	local function healApplePieOwners()
		for _, player in Players:GetPlayers() do
			healApplePieOwner(player)
		end
	end

	DungeonService.Signals.OnSegmentCleared:Connect(function(_dungeon, _lastChunk)
		healApplePieOwners()
	end)

	DungeonService.Signals.OnDungeonCompleted:Connect(function(_dungeon)
		healApplePieOwners()
	end)

	DungeonService.Signals.OnRoomEntered:Connect(function(player: Player, room)
		if room and room.roomType == RoomTypes.Event then
			healApplePieOwner(player)
		end
	end)

	for _, module in script.Active:GetChildren() do
		if module:IsA("ModuleScript") then
			self._activeRegistry[module.Name] = require(module)
		end
	end

	task.spawn(function()
		while task.wait(1) do
			self:_incrementalRelicEffects()
		end
	end)

	-- ELEMENT LOCK. Assigned per RUN, for everyone present when it starts.
	-- DungeonService fires OnRunStarted just before the first dungeon
	-- generates, which is early enough that the starter machine (dropped on
	-- the landing that follows) already sees the assignment.
	-- Crimson aura + Holiday Ham size re-application: on pickup and on
	-- every respawn. Both are character-level relic effects that a fresh
	-- character does not inherit.
	self.Signals.OnRelicsUpdated:Connect(function(player: Player)
		self:_applyCrimsonAura(player)
		self:_applyHolidayHamScale(player)
	end)
	PlayerEventService.OnCharacterAdded:Connect(function(player: Player)
		self:_applyCrimsonAura(player)
		self:_applyHolidayHamScale(player)
	end)

	PlayerEventService.OnPlayerAdded:Connect(function(player: Player)
		self._relicRegistry[player.UserId] = {}
		self._incrementalRegistry[player.UserId] = 0
		self._relicsList[player.UserId] = {}

		self.Client.OnReplicateRelics:FireAll(player.UserId, self._relicRegistry, self._relicsList)

		player.Character:SetAttribute(Attributes.OnJetpack, false)

		-- Ghost Dragon visual lives outside the character tree (see
		-- _cleanupGhostDragon comment), so the engine doesn't auto-destroy
		-- it on respawn. Tear it down on CharacterRemoving — the next
		-- relic tick rebuilds it against the freshly-spawned HRP, which
		-- otherwise wouldn't have the GhostDragonTargetAttachment the
		-- AlignPosition needs. The connection is owned by the Player
		-- instance, so it auto-disconnects when they leave; no manual
		-- tracking needed.
		player.CharacterRemoving:Connect(function()
			self:_cleanupGhostDragon(player.UserId)
		end)

		task.delay(3, function()
			-- EARTH RELICS
			-- self:AddRelicsRegistry(player, RelicNames["Robloxian Battle Shield"], 1)
			-- self:AddRelicsRegistry(player, RelicNames["Riot Shield"], 1)
			-- self:AddRelicsRegistry(player, RelicNames["Bundle of TNT"], 1)
			-- self:AddRelicsRegistry(player, RelicNames["Earth Summoning Horn"], 1)
			-- self:AddRelicsRegistry(player, RelicNames["Golden Steampunk Gloves"], 1)
			-- self:AddRelicsRegistry(player, RelicNames["Spartan Sword and Shield"], 1)
			-- self:AddRelicsRegistry(player, RelicNames["Golem's Hammer"], 1)
			-- self:AddRelicsRegistry(player, RelicNames["Space Sandwich"], 1)
			-- self:AddRelicsRegistry(player, RelicNames["Leland the Lolturtle"], 1)
			-- self:AddRelicsRegistry(player, RelicNames["Earth Protection Orb"], 1)

			-- BLAZE RELICS
			-- self:AddRelicsRegistry(player, RelicNames["Faux Firebrand"], 1)
			-- self:AddRelicsRegistry(player, RelicNames["Fire Breathing Dragon Friend"], 1)
			-- self:AddRelicsRegistry(player, RelicNames["Ye Olde Fire Breath Potion"], 1)
			-- self:AddRelicsRegistry(player, RelicNames["Flaming Bo Staff"], 1)
			-- self:AddRelicsRegistry(player, RelicNames["Flaming Mace"], 1)
			-- self:AddRelicsRegistry(player, RelicNames.Phoenix, 1)
			-- self:AddRelicsRegistry(player, RelicNames["Trick Or Trap"], 1)
			-- self:AddRelicsRegistry(player, RelicNames["Dragon's Flame Sword"], 1)
			-- self:AddRelicsRegistry(player, RelicNames["Berserker's Claymore"], 1)
			-- self:AddRelicsRegistry(player, RelicNames["Flame Ronin Katana"], 1)

			-- FROST RELICS
			-- self:AddRelicsRegistry(player, RelicNames["Korblox Spell Book"], 1)
			-- self:AddRelicsRegistry(player, RelicNames["Ice Cream"], 1)
			-- self:AddRelicsRegistry(player, RelicNames["Frozen Flail"], 1)
			-- self:AddRelicsRegistry(player, RelicNames["Frozen Blue Ice Crossbow"], 1)
			-- self:AddRelicsRegistry(player, RelicNames["Blizzard Wand"], 1)
			-- self:AddRelicsRegistry(player, RelicNames["Icy Arctic Fowl"], 1)
			-- self:AddRelicsRegistry(player, RelicNames["Ice Breaker"], 1)
			-- self:AddRelicsRegistry(player, RelicNames["Ice Dragon Slayer"], 1)
			-- self:AddRelicsRegistry(player, RelicNames["Korblox Mage Staff"], 1)
			-- self:AddRelicsRegistry(player, RelicNames["Staff of Azure Ever Ice"], 1)

			-- VENOM RELICS
			-- self:AddRelicsRegistry(player, RelicNames["Korblox Evil Eye"], 1)
			-- self:AddRelicsRegistry(player, RelicNames["Zombie Axe"], 1)
			-- self:AddRelicsRegistry(player, RelicNames["Zombie Bomb"], 1)
			-- self:AddRelicsRegistry(player, RelicNames["Poison Picnic"], 1)
			-- self:AddRelicsRegistry(player, RelicNames["Poisonous Butterfly"], 1)
			-- self:AddRelicsRegistry(player, RelicNames["Overseer's Short Sword"], 1)
			-- self:AddRelicsRegistry(player, RelicNames["Overseer's Battleaxe"], 1)
			-- self:AddRelicsRegistry(player, RelicNames["Skeletal Scythe"], 1)
			-- self:AddRelicsRegistry(player, RelicNames["Foul Poison Fowl"], 1)
			-- self:AddRelicsRegistry(player, RelicNames["Mechatronic Spider"], 1)

			-- -- STORM RELICS
			-- self:AddRelicsRegistry(player, RelicNames["Lightning Orb"], 1)
			-- self:AddRelicsRegistry(player, RelicNames["Static Shock Sheep"], 1)
			-- self:AddRelicsRegistry(player, RelicNames["Ninja Whip"], 1)
			-- self:AddRelicsRegistry(player, RelicNames["Throwing Bolts"], 1)
			-- self:AddRelicsRegistry(player, RelicNames["Lightning Wand"], 1)
			-- self:AddRelicsRegistry(player, RelicNames.Katana, 1)
			-- self:AddRelicsRegistry(player, RelicNames["Deluxe Coil Gun"], 1)
			-- self:AddRelicsRegistry(player, RelicNames["Sparkle Time Hoverboard"], 1)
			-- self:AddRelicsRegistry(player, RelicNames["Lightning Bolt Sword"], 1)
			-- self:AddRelicsRegistry(player, RelicNames["Lightning Horn of the Heavens"], 1)
		end)
	end)

	PlayerEventService.OnPlayerRemoved:Connect(function(player: Player)
		self._relicRegistry[player.UserId] = nil
		self._incrementalRegistry[player.UserId] = nil
		self._relicsList[player.UserId] = nil

		self.Client.OnReplicateRelics:FireAll(player.UserId, self._relicRegistry, self._relicsList)

		-- Final cleanup of the workspace-parented Ghost Dragon visual —
		-- CharacterRemoving handles respawns; this catches the disconnect.
		self:_cleanupGhostDragon(player.UserId)
	end)
end

function RelicService:KnitInit() end

return RelicService
