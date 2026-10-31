--!strict
--[[
	Module: Server/Services/RunEscrowService.lua
	Description:
	The death economy's run-scoped ESCROW (hardcore redesign, spec:
	Docs/DeathEconomySpec.md). Gear drops and coins earned during a run
	are held here — NOT written to the profile — until a bank event:

	  * BANK (all escrow → profile): walking out through the exit portal,
	    via :ClaimRewards. Killing the boss does NOT bank — see below.
	  * HALF (2026-10-30): a FULL death, a wipe or a leave in a run not yet
	    cleared banks HALF the Coins and Forge Ore (OUT_OF_RUN_KEEP) and
	    loses the rest; the gear spills as below.
	  * SPILL (gear leaves the escrow, hits the floor): every FULL death,
	    wipe or not. A DOWNED player (revive window open) keeps everything:
	    the spill waits for LifeService.OnPlayerFullyDied, so a revive
	    bought in the window brings them back with the run intact. Once
	    fully dead, every run item drops from the corpse as a public gear
	    drop that a teammate, or the player after a late revive, can pick
	    up. Coins stay. (Solo, a full death is always a wipe; the loot
	    still spills.)
	  * LEAVE (disconnect mid-run): the gear SPILLS from where the player
	    stood, exactly as a full death spills it, so the party can carry
	    it on; the Coins and Ore are banked on the way out.
	  * DISCARD (escrow lost): what is left after a spill -- the run gear
	    nobody picked up, and the Gems. The COINS AND FORGE ORE ARE NEVER
	    LOST (design call, 2026-10-21): a wipe or a leave banks them into
	    the profile first (BankCurrencies); only the run-bound gear and the
	    Gems die with the run.

	Beating the boss is not the same as getting out. The escrow stays
	full and visible in the Spire's Bounty panel after the boss dies, and
	is still losable, until the player physically walks through the exit
	portal — that walk is the claim. Nothing is hooked to
	OnDungeonCompleted; the claim rides LifeService's
	OnPlayerLeavingToLobby, fired once the lobby teleport has gone out.

	THREE currencies ride the escrow (design call, 2026-10):
	  * GEMS -- the run currency. Mobs drop them, the Merchant and the
	    Relic Slot stand spend them, and they are DISCARDED at the bank:
	    spend or lose. Replicated as `gems` and mirrored onto the
	    RunGems attribute (Pot O' Gold Sword reads it client-side).
	  * COINS -- permanent Gold, from the chests only. Banked into the
	    profile's Gold on the walk out, and on a wipe or a leave too.
	  * FORGE ORE -- the Blacksmith's material, the miniboss / boss chests
	    only, banked exactly like the Coins.
	Every write goes through _commit, which republishes the mirrors, so
	the table, the EscrowData property and the attribute never disagree.

	Design rules (locked):
	  * MAX_RUN_ITEMS cap per player per run. A pickup past the cap is
	    REJECTED (drop stays on the ground until its normal expiry) —
	    no discard UI, the first N you grab are your N.
	  * Run gear is NOT equippable — trophies you're carrying out, not
	    upgrades. You fight with what you brought in.
	  * Coins and Ore are pure cargo (nothing spends them mid-run); Gems
	    are the only thing a run can spend.

	Replication: EscrowData is per-player (SetFor) —
	  { items = { { gearType, armorSlot?, item = <inventory entry> } },
	    gems = number, coins = number, forgeOre = number }
	RunInventoryInterfaceController renders straight from it.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local DataService = require(ServerScriptService.Submodules.Core.Source.Services.DataService)
local PlayerEventService = require(ServerScriptService.Submodules.Core.Source.Services.PlayerEventService)
local InventoryCapData = require(ReplicatedStorage.Submodules.Core.Shared.Data.InventoryCapData)
local countOwnedGear = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Inventory.countOwnedGear)
local CurrencyService =
	require(ServerScriptService.Submodules.Core.Source.Services.DataService.SubServices.CurrencyService)
local LifeService = require(ServerScriptService.Services.LifeService)
local TextIndicatorService = require(ServerScriptService.Submodules.Core.Source.Services.TextIndicatorService)
local GearDropService = require(ServerScriptService.Services.GearDropService)
local PlayerNetwork = require(ServerScriptService.Submodules.Core.Source.Network.Player)
local RemoteProperty = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Network.RemoteProperty)
local InventoryType = require(ReplicatedStorage.Submodules.Core.Shared.Enums.InventoryType)
local GearTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.GearTypes)
local CurrencyTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.CurrencyTypes)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local Blitz = require(ReplicatedStorage.Submodules.Core.Shared.Blitz)
local Log = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Log)

local RunEscrowService = {
	Name = "RunEscrowService",
	Dependencies = { DataService, CurrencyService, LifeService, TextIndicatorService, GearDropService } :: { any },
}

-- Per-player escrow snapshot (SetFor; was a replicated property), see
-- the module header.
RunEscrowService._escrowProperty = RemoteProperty.Server({
	changed = PlayerNetwork.EscrowDataChanged,
	get = PlayerNetwork.GetEscrowData,
}, { items = {}, gems = 0, coins = 0, forgeOre = 0 })

--[ Constants ]--

-- Matches MAX_RUN_SLOTS in RunInventoryInterfaceController's Container
-- (15 slots = 5 wide × 3 tall), so the grid IS the cap and a full grid
-- of tiles reads as "no more room".
local MAX_RUN_ITEMS = 15

-- Death spill ring: items land between MIN and MAX studs from the corpse,
-- each inside its own wedge of the circle; JITTER is how much of the wedge
-- an item may wander from the wedge's centre (0 = perfectly even, 1 = may
-- touch its neighbours' wedges).
local DEATH_SPILL_MIN_RADIUS = 3
local DEATH_SPILL_MAX_RADIUS = 5
local DEATH_SPILL_ANGLE_JITTER = 0.6

--[ Properties ]--

-- One carried drop; `item` is the fully-built inventory entry.
type EscrowItem = { gearType: string, armorSlot: string?, item: { [string]: any } }

RunEscrowService._escrow = {} :: {
	[number]: {
		items: { EscrowItem },
		gems: number,
		coins: number,
		forgeOre: number,
	},
}

--[ Private helpers ]--

-- Read CLIENT-side by Pot O' Gold Sword's runtimeDescriptionCallback (see
-- _replicate). Keep in step with RelicData.
local RUN_GEMS_ATTRIBUTE = "RunGems"

-- Whether the run's final boss is down (DungeonService Run.cleared): the
-- escrow is then safe -- a death banks it rather than losing it.
-- DungeonService is a consumer of this module, so it is reached at call time.
-- The share of the Coins and Forge Ore a player keeps when they are out
-- of a run they did not clear: fully dead, wiped, or gone (design call,
-- 2026-10-30). Their run gear spills either way.
local OUT_OF_RUN_KEEP = 0.5

local function runIsCleared(): boolean
	local dungeonService = Blitz.OptionalService("DungeonService")
	return dungeonService ~= nil and dungeonService:IsRunCleared() == true
end

function RunEscrowService._getOrCreate(self: typeof(RunEscrowService), player: Player)
	local entry = self._escrow[player.UserId]
	if not entry then
		entry = { items = {}, gems = 0, coins = 0, forgeOre = 0 }
		self._escrow[player.UserId] = entry
	end
	return entry
end

function RunEscrowService._replicate(self: typeof(RunEscrowService), player: Player)
	local entry = self:_getOrCreate(player)
	self._escrowProperty:SetFor(player, {
		items = entry.items,
		gems = entry.gems or 0,
		coins = entry.coins,
		forgeOre = entry.forgeOre,
	})

	-- Same coin count, mirrored onto an ATTRIBUTE. The Comm property above is
	-- what the run UI reads; this exists because relic
	-- runtimeDescriptionCallbacks run on the CLIENT, where no server service
	-- is reachable, and attributes replicate on their own — the same reason
	-- PlayerStatsService stamps BonusHealthPercent. Pot O' Gold Sword reads it
	-- to show its live damage bonus. Every coin change already funnels through
	-- _replicate, so the number can't go stale.
	player:SetAttribute(RUN_GEMS_ATTRIBUTE, entry.gems or 0)
end

-- The ONLY writers of a player's currency counts. Credit, tax, spend,
-- bank and discard all land here: the escrow table is written, then both
-- mirrors are republished from it (_replicate), so the table, the
-- EscrowData property and the RunGems attribute can never disagree.
function RunEscrowService._commitGems(self: typeof(RunEscrowService), player: Player, value: number)
	local entry = self:_getOrCreate(player)
	entry.gems = math.max(0, math.floor(value))
	self:_replicate(player)
end

function RunEscrowService._commitCoins(self: typeof(RunEscrowService), player: Player, value: number)
	local entry = self:_getOrCreate(player)
	entry.coins = value
	self:_replicate(player)
end

-- Empties the whole escrow (a bank or a discard). A NEW entry replaces
-- the old one, so a spill loop mid-flight (DropAllOnDeath) sees the
-- identity change and stops; the coin wipe then republishes through
-- _commitCoins like any other coin change.
function RunEscrowService._clearEscrow(self: typeof(RunEscrowService), player: Player)
	self._escrow[player.UserId] = { items = {}, gems = 0, coins = 0, forgeOre = 0 }
	self:_commitCoins(player, 0)
end

--[ Public API ]--

-- Adds a rolled gear entry to the player's run escrow. Returns false
-- (pickup must be rejected, drop stays on the ground) when the item cap
-- is hit. `escrowItem` = { gearType, armorSlot?, item } where `item` is
-- the fully-built inventory entry (GearDrop:_buildInventoryEntry shape)
-- — banking inserts it into the profile verbatim, so the stats the
-- player saw during the run are exactly what they keep.
function RunEscrowService.AddItem(
	self: typeof(RunEscrowService),
	player: Player,
	escrowItem: { [string]: any }
): boolean
	local entry = self:_getOrCreate(player)

	-- The BAG cap (InventoryCapData): what is owned plus what this run is
	-- already carrying, so banking the escrow can never overfill the bag.
	local owned = countOwnedGear(DataService and DataService:GetProfileData(player))
	if owned + #entry.items >= InventoryCapData.BASE_SLOTS then
		local character = player.Character
		if TextIndicatorService and character then
			TextIndicatorService:ShowIndicator(
				player,
				((character:FindFirstChild("Head") :: BasePart?) or character.PrimaryPart) :: BasePart,
				"Bag full!",
				Color3.fromRGB(255, 90, 90),
				true
			)
		end
		return false
	end

	if #entry.items >= MAX_RUN_ITEMS then
		local character = player.Character
		if TextIndicatorService and character then
			TextIndicatorService:ShowIndicator(
				player,
				((character:FindFirstChild("Head") :: BasePart?) or character.PrimaryPart) :: BasePart,
				"Run inventory full!",
				Color3.fromRGB(255, 90, 90),
				true
			)
		end
		return false
	end

	table.insert(entry.items, escrowItem)
	self:_replicate(player)
	-- Ticked only on an ACCEPTED pickup, so an item refused by the cap
	-- above never reads as a gain. Monotonic: banking the escrow or
	-- dropping an item leaves it alone, because it answers "something was
	-- just picked up", not "how much is being carried".
	player:SetAttribute(Attributes.GearGained, ((player:GetAttribute(Attributes.GearGained) or 0) :: number) + 1)
	return true
end

-- Credits Gems (post-multiplier value from DropService's credit path).
function RunEscrowService.AddGems(self: typeof(RunEscrowService), player: Player, amount: number)
	self:_commitGems(player, (self:_getOrCreate(player).gems or 0) + amount)
end

function RunEscrowService.GetGems(self: typeof(RunEscrowService), player: Player): number
	return self:_getOrCreate(player).gems or 0
end

-- Debits Gems if the balance covers it; false (and no change) otherwise.
-- The Merchant and the Relic Slot stand are the spenders.
function RunEscrowService.SpendGems(self: typeof(RunEscrowService), player: Player, amount: number): boolean
	local entry = self:_getOrCreate(player)
	if amount <= 0 or (entry.gems or 0) < amount then
		return false
	end
	self:_commitGems(player, entry.gems - amount)
	return true
end

-- Dragon Lantern's drawback: strips `fraction` of the player's Gems AND
-- carried Coins (each rounded down). Ore and gear are never touched.
function RunEscrowService.TaxCurrencies(self: typeof(RunEscrowService), player: Player, fraction: number)
	local entry = self._escrow[player.UserId]
	if not entry then
		return
	end
	local gemsLoss = math.floor((entry.gems or 0) * fraction)
	if gemsLoss > 0 then
		self:_commitGems(player, entry.gems - gemsLoss)
	end
	local coinsLoss = math.floor((entry.coins or 0) * fraction)
	if coinsLoss > 0 then
		self:_commitCoins(player, entry.coins - coinsLoss)
	end
end

-- Credits Coins (a reward chest's payout, post dungeon scale). Cargo
-- only -- nothing spends these mid-run; they bank into Gold on the walk
-- out.
function RunEscrowService.AddCoins(self: typeof(RunEscrowService), player: Player, amount: number)
	self:_commitCoins(player, self:_getOrCreate(player).coins + amount)
end

-- Forge Ore rides the escrow under the same rules as coins: banked to
-- the profile on clear, gone on death. No tax, no multipliers.
function RunEscrowService.AddForgeOre(self: typeof(RunEscrowService), player: Player, amount: number)
	local entry = self:_getOrCreate(player)
	entry.forgeOre = (entry.forgeOre or 0) + math.max(0, math.floor(amount))
	self:_replicate(player)
end

function RunEscrowService.GetForgeOre(self: typeof(RunEscrowService), player: Player): number
	local entry = self._escrow[player.UserId]
	return if entry then (entry.forgeOre or 0) else 0
end

function RunEscrowService.GetCoins(self: typeof(RunEscrowService), player: Player): number
	return self:_getOrCreate(player).coins
end

-- Banks the whole escrow into the profile: items routed exactly like the
-- old pickup-time grant (Weapon → Inventory.Weapon flat array, Armor →
-- Inventory.Gear[<slot>] sub-array), coins through CurrencyService. One
-- SetProfileValue write at the end so OnPlayerDataUpdated listeners
-- (loadout refresh, hotbar UI) see the whole bank as a single update.
function RunEscrowService.BankAll(self: typeof(RunEscrowService), player: Player)
	local entry = self._escrow[player.UserId]
	if not entry or (#entry.items == 0 and entry.coins == 0 and (entry.forgeOre or 0) == 0) then
		-- Gems alone are nothing to bank: they die with the run.
		self:_clearEscrow(player)
		return
	end

	local profile = DataService and DataService:GetProfileData(player)
	if not profile or not profile.Inventory then
		warn(("[RunEscrowService] Bank failed — no inventory profile for %s"):format(player.Name))
		return
	end

	for _, escrowItem in entry.items do
		if escrowItem.gearType == GearTypes.Weapon then
			if not profile.Inventory[InventoryType.Weapon] then
				profile.Inventory[InventoryType.Weapon] = {}
			end
			table.insert(profile.Inventory[InventoryType.Weapon], escrowItem.item)
		elseif escrowItem.gearType == GearTypes.Armor and escrowItem.armorSlot then
			if not profile.Inventory[InventoryType.Gear] then
				profile.Inventory[InventoryType.Gear] = {}
			end
			if not profile.Inventory[InventoryType.Gear][escrowItem.armorSlot] then
				profile.Inventory[InventoryType.Gear][escrowItem.armorSlot] = {}
			end
			table.insert(profile.Inventory[InventoryType.Gear][escrowItem.armorSlot], escrowItem.item)
		else
			warn(
				("[RunEscrowService] Skipping malformed escrow item for %s (gearType=%s)"):format(
					player.Name,
					tostring(escrowItem.gearType)
				)
			)
		end
	end

	DataService:SetProfileValue(player, "Inventory", profile.Inventory)

	if entry.coins > 0 then
		CurrencyService:SetCurrencyValue(
			player,
			CurrencyTypes.Gold,
			CurrencyService:GetCurrencyValue(player, CurrencyTypes.Gold) + entry.coins
		)
	end

	if (entry.forgeOre or 0) > 0 then
		CurrencyService:SetCurrencyValue(
			player,
			CurrencyTypes.ForgeOre,
			CurrencyService:GetCurrencyValue(player, CurrencyTypes.ForgeOre) + entry.forgeOre
		)
	end
	Log.debug(
		("[RunEscrowService] Banked %d items + %d coins + %d forge ore for %s (%d gems discarded)"):format(
			#entry.items,
			entry.coins,
			entry.forgeOre or 0,
			player.Name,
			entry.gems or 0
		)
	)

	self:_clearEscrow(player)
end

-- Banks the Coins and Forge Ore alone (the profile's Gold and Ore) and
-- zeroes them in the escrow, leaving the run gear and the Gems where they
-- are. `keepFraction` (default all) is the share that reaches the
-- profile; the rest is lost. A full death, a wipe and a leave keep
-- OUT_OF_RUN_KEEP (design call, 2026-10-30; they kept it all before).
function RunEscrowService.BankCurrencies(self: typeof(RunEscrowService), player: Player, keepFraction: number?)
	local entry = self._escrow[player.UserId]
	if not entry or (entry.coins == 0 and (entry.forgeOre or 0) == 0) then
		return
	end
	if not (DataService and DataService:GetProfileData(player)) then
		warn(("[RunEscrowService] Currency bank failed — no profile for %s"):format(player.Name))
		return
	end
	local keep = math.clamp(keepFraction or 1, 0, 1)
	local coins = math.floor(entry.coins * keep)
	local ore = math.floor((entry.forgeOre or 0) * keep)
	if coins > 0 then
		CurrencyService:SetCurrencyValue(
			player,
			CurrencyTypes.Gold,
			CurrencyService:GetCurrencyValue(player, CurrencyTypes.Gold) + coins
		)
	end
	if ore > 0 then
		CurrencyService:SetCurrencyValue(
			player,
			CurrencyTypes.ForgeOre,
			CurrencyService:GetCurrencyValue(player, CurrencyTypes.ForgeOre) + ore
		)
	end
	entry.forgeOre = 0
	self:_commitCoins(player, 0)
	Log.debug(
		("[RunEscrowService] Banked %d coins + %d forge ore for %s (currencies only)"):format(coins, ore, player.Name)
	)
end

-- THE claim entry point — call this when a player walks through the exit
-- portal. Banks their escrow into the profile and empties it.
--
-- The portal owns the TIMING; this method owns the transaction. It does not
-- verify the boss is dead or that a portal exists, because the portal only
-- spawns post-clear and re-deriving that here would just be a second source
-- of truth to keep in sync.
--
-- Returns true only if something was actually banked, so the caller can gate
-- a reward flourish on it instead of playing one over an empty claim.
-- Refuses for a player in the death state (downed or fully dead): a body
-- on the floor shouldn't be able to claim.
--
-- Until the portal exists, drive it from the command bar:
--   require(game.ServerScriptService.Services.RunEscrowService):ClaimRewards(game.Players.SomeUser)
function RunEscrowService.ClaimRewards(self: typeof(RunEscrowService), player: Player): boolean
	-- A dead player cannot claim -- unless the run is already won (final
	-- boss down): then the lobby teleport after the death banks it.
	if LifeService and LifeService:IsDeathState(player) and not runIsCleared() then
		return false
	end

	local entry = self._escrow[player.UserId]
	if not entry or (#entry.items == 0 and entry.coins == 0 and (entry.forgeOre or 0) == 0) then
		-- Nothing to bank; Gems (if any) die with the run.
		self:_clearEscrow(player)
		return false
	end

	self:BankAll(player)
	return true
end

-- Discards the escrow — a party WIPE, or disconnect mid-run. The Coins
-- and Forge Ore are BANKED first (BankCurrencies, design call
-- 2026-10-21); the Spire keeps the run gear and the Gems. A single death
-- does NOT land here (see Start): a revive would otherwise bring the
-- player back with nothing to show for the run so far.
function RunEscrowService.Discard(self: typeof(RunEscrowService), player: Player, reason: string?)
	local entry = self._escrow[player.UserId]
	if
		not entry or (#entry.items == 0 and entry.coins == 0 and (entry.forgeOre or 0) == 0 and (entry.gems or 0) == 0)
	then
		return
	end

	self:BankCurrencies(player, if runIsCleared() then 1 else OUT_OF_RUN_KEEP)

	Log.debug(
		("[RunEscrowService] Discarded %d items + %d coins + %d gems for %s (%s)"):format(
			#entry.items,
			entry.coins,
			entry.gems or 0,
			player.Name,
			reason or "unspecified"
		)
	)

	self:_clearEscrow(player)
end

-- Takes the escrow item at `index` out of the player's run inventory and
-- lands it on the floor around `origin` as a PUBLIC gear drop that anyone
-- can pick up, the dropper included. Nothing is paid and nothing is
-- destroyed -- the item keeps its uuid, quality and enchantment across
-- the round trip (GearDropService holds the entry until pickup).
--
-- The escrow write happens FIRST so a duplicate request cannot drop the
-- same item twice, and is undone if the drop fails to spawn. Shared by
-- the player-initiated drop and the on-death drop so both put exactly the
-- same thing on the floor and update the run inventory UI the same way.
function RunEscrowService._dropItemAt(
	self: typeof(RunEscrowService),
	player: Player,
	index: number,
	origin: Vector3,
	landing: Vector3?,
	silentPop: boolean?
): boolean
	if not GearDropService then
		return false
	end

	local entry = self:_getOrCreate(player)
	local dropped = table.remove(entry.items, index) :: EscrowItem?
	if not dropped then
		return false
	end
	self:_replicate(player)

	if not GearDropService:DropExistingGear(player, origin, dropped, landing, silentPop) then
		-- Nothing spawned (missing prefab): give it back rather than
		-- deleting the player's item.
		table.insert(entry.items, math.min(index, #entry.items + 1), dropped)
		self:_replicate(player)
		return false
	end
	return true
end

-- Player-initiated DROP from the run inventory, by uuid.
-- PlayerNetwork.DropRunItem handler (was a client-callable method).
function RunEscrowService._onDropItem(self: typeof(RunEscrowService), player: Player, uuid: string): boolean
	if typeof(uuid) ~= "string" or uuid == "" then
		return false
	end

	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return false
	end

	local entry = self:_getOrCreate(player)
	local index = nil
	for position, escrowItem in entry.items do
		if type(escrowItem.item) == "table" and escrowItem.item.uuid == uuid then
			index = position
			break
		end
	end
	if not index then
		return false
	end

	return self:_dropItemAt(player, index, hrp.Position)
end

-- DEATH drop: every run-bound item leaves the escrow and spills out of
-- the corpse in ONE burst -- every item on the same frame, each landing in
-- its own wedge of the ring around the body (below), as PUBLIC drops that
-- a teammate, or the player after a revive, can walk over and take. One
-- pop for the whole burst: the first item sounds, the rest are stamped
-- silent (a dozen pops on one frame was a single loud crack).
--
-- Origin is the corpse's HumanoidRootPart; if the character is already
-- gone, LifeService's recorded death position stands in. No position at
-- all = nothing drops (the items stay in the escrow for a revive) and a
-- warn says so. Coins are untouched: they are cargo, not gear.
--
-- Drops through _dropItemAt so a wipe or a disconnect mid-spill (which
-- empty / remove the escrow) ends the loop on its own -- the loop reads
-- the live escrow each step instead of a snapshot.
function RunEscrowService.DropAllOnDeath(self: typeof(RunEscrowService), player: Player)
	local entry = self._escrow[player.UserId]
	if not entry or #entry.items == 0 then
		return
	end
	local origin = self:_spillOrigin(player)
	if not origin then
		warn(
			("[RunEscrowService] %s died with %d run items but has no character or death position — nothing dropped"):format(
				player.Name,
				#entry.items
			)
		)
		return
	end
	self:_spillAll(player, origin, "died")
end

-- LEAVE spill: a player who disconnects mid-run leaves their run gear on
-- the floor where they stood, the same public ring the death spill lays
-- out, so a teammate can carry it on. Runs inside PlayerRemoving, where
-- the Player is still parented and (normally) still has a character; a
-- downed leaver spills from the body. The coins go with the escrow.
function RunEscrowService.DropAllOnLeave(self: typeof(RunEscrowService), player: Player)
	local entry = self._escrow[player.UserId]
	if not entry or #entry.items == 0 then
		return
	end
	local origin = self:_spillOrigin(player)
	if not origin then
		warn(
			("[RunEscrowService] %s left with %d run items but has no character or death position — nothing dropped"):format(
				player.Name,
				#entry.items
			)
		)
		return
	end
	self:_spillAll(player, origin, "left")
end

-- Where a spill starts: the character's root, else the recorded death
-- position (the corpse of a fully dead player whose character is gone).
function RunEscrowService._spillOrigin(_self: typeof(RunEscrowService), player: Player): Vector3?
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if hrp then
		return hrp.Position
	end
	return LifeService:GetDeathPosition(player)
end

-- The spill itself, shared by the death and the leave paths: every item
-- in ONE burst from `dropOrigin`, ring layout, one pop.
function RunEscrowService._spillAll(self: typeof(RunEscrowService), player: Player, dropOrigin: Vector3, reason: string)
	local entry = self._escrow[player.UserId]
	if not entry or #entry.items == 0 then
		return
	end

	-- Ring layout: the circle around the corpse is cut into one wedge per
	-- item, each item lands inside its own wedge at a random angle within
	-- it and a random radius, so the spill reads as an even ring that is
	-- still never the same twice (and never a clump, which pure random
	-- scatter gives about a third of the time).
	local total = #entry.items
	local wedge = (2 * math.pi) / total
	local ringStart = math.random() * 2 * math.pi
	local slot = 0

	local droppedCount = 0
	while self._escrow[player.UserId] == entry and #entry.items > 0 and player.Parent ~= nil do
		local angle = ringStart + slot * wedge + (math.random() - 0.5) * wedge * DEATH_SPILL_ANGLE_JITTER
		local radius = DEATH_SPILL_MIN_RADIUS + math.random() * (DEATH_SPILL_MAX_RADIUS - DEATH_SPILL_MIN_RADIUS)
		local landing = dropOrigin + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
		slot += 1
		if self:_dropItemAt(player, 1, dropOrigin, landing, droppedCount > 0) then
			droppedCount += 1
		else
			-- Could not spawn this one (it went back into the escrow).
			-- Leave it and everything behind it rather than spinning on it.
			break
		end
	end

	Log.debug(
		("[RunEscrowService] %s %s — dropped %d run items from the body"):format(player.Name, reason, droppedCount)
	)
end

--[ Lifecycle ]--

function RunEscrowService.Start(self: typeof(RunEscrowService))
	PlayerNetwork.DropRunItem.On(function(player: Player, uuid: string): boolean
		return self:_onDropItem(player, uuid)
	end)

	-- Every FULL death SPILLS the run gear out of the corpse as public
	-- drops (DropAllOnDeath): a teammate can carry it on, and the player
	-- can pick it back up after a revive. The coins stay in the escrow.
	-- Deliberately NOT OnPlayerDied (= downed): while the revive window is
	-- open the body lies there with its gear, and a revive bought in time
	-- stands the player up with all of it. The body never moves between
	-- the two phases, so the spill origin is unchanged.
	--
	-- A WIPE (every player fully dead, the run over, the lobby teleport
	-- following) spills too -- solo, every full death is a wipe, and the
	-- loot falling out of the corpse is part of dying -- and THEN discards
	-- every player's escrow (the coins, and anything a spill left behind).
	-- The discard waits for the spill so it cannot empty the escrow first.
	-- (Death Defiance charges absorb earlier hits without firing this.)
	LifeService.OnPlayerFullyDied:Connect(function(player: Player, isWipe: boolean?)
		-- Spawned off the signal: the spill waits between items, and
		-- LifeService's death flow must not stall behind it.
		task.spawn(function()
			-- A CLEARED run (final boss down, design call 2026-10: no
			-- extraction) is already won: nothing spills, nothing is
			-- discarded -- the lobby teleport that follows banks it.
			if runIsCleared() then
				return
			end
			self:DropAllOnDeath(player)
			-- Out of the run: half the Gold and Ore now, the rest lost
			-- (design call, 2026-10-30). A revive in the downed window never
			-- gets here, so it keeps everything.
			self:BankCurrencies(player, OUT_OF_RUN_KEEP)
			if isWipe then
				for _, otherPlayer in Players:GetPlayers() do
					self:Discard(otherPlayer, "wipe")
				end
			end
		end)
	end)

	-- A wipe completed by a LEAVER (the last player not fully dead
	-- disconnected) has no full death to hang the discard on, so it lands
	-- here. The death-triggered wipe (lastPlayer set) is already handled
	-- above, after its spill; discarding again here would race that spill.
	LifeService.OnPartyWiped:Connect(function(lastPlayer: Player?)
		if lastPlayer or runIsCleared() then
			return
		end
		for _, otherPlayer in Players:GetPlayers() do
			self:Discard(otherPlayer, "wipe")
		end
	end)

	-- NOT hooked to OnDungeonCompleted. Boss defeat used to bank here
	-- immediately, which emptied the escrow the instant the boss died and
	-- blanked the Spire's Bounty panel mid-victory. Claiming happens when the
	-- player actually walks out through the ExitPortal -- the run's winnings
	-- stay on screen, and stay at risk, until then.
	--
	-- And NOT hooked to DungeonService.OnPlayerExtracted either: that fires
	-- when the portal prompt is triggered, BEFORE the lobby teleport is
	-- attempted, and a teleport that never goes out (Studio; a TeleportAsync
	-- failure) left the player standing in the run with an emptied escrow.
	-- LifeService fires OnPlayerLeavingToLobby only once TeleportAsync has
	-- been issued, so the bank is the walk-out itself. The player is still
	-- on this server at that point (the teleport is asynchronous), with
	-- their profile loaded, so the bank lands before PlayerRemoving.
	LifeService.Signals.OnPlayerLeavingToLobby:Connect(function(player: Player)
		self:ClaimRewards(player)
	end)

	-- Disconnect mid-run: the gear spills where the player stood (a
	-- teammate can carry it on), the Coins and Ore are banked, THEN the
	-- entry is dropped. On PlayerEventService.OnPlayerLeaving, the edge
	-- that runs BEFORE the profile release and the currency registry
	-- teardown (both on OnPlayerRemoved): on raw PlayerRemoving this
	-- raced them, and a leaver carrying Coins or Ore lost them (QA
	-- 2026-10-21, P0 #1). The spill runs first, on the same frame, so
	-- the entry is still there for it.
	PlayerEventService.OnPlayerLeaving:Connect(function(player: Player)
		-- A cleared run is won: a leaver keeps it all (and spills nothing).
		if runIsCleared() then
			self:BankCurrencies(player)
			self._escrow[player.UserId] = nil
			return
		end
		self:DropAllOnLeave(player)
		self:BankCurrencies(player, OUT_OF_RUN_KEEP)
		self._escrow[player.UserId] = nil
	end)
end

return RunEscrowService
