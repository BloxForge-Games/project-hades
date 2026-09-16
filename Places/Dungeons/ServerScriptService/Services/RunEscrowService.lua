--!strict
--[[
	Module: Server/Services/RunEscrowService.lua
	Description:
	The death economy's run-scoped ESCROW (hardcore redesign, spec:
	Docs/DeathEconomySpec.md). Gear drops and coins earned during a run
	are held here — NOT written to the profile — until a bank event:

	  * BANK (all escrow → profile): walking out through the exit portal,
	    via :ClaimRewards. Killing the boss does NOT bank — see below.
	  * DISCARD (escrow lost): entering the death state (out of lives),
	    or leaving the server mid-run. Knowledge is the only thing the
	    Spire can't take back.

	Beating the boss is not the same as getting out. The escrow stays
	full and visible in the Spire's Bounty panel after the boss dies, and
	is still losable, until the player physically walks through the exit
	portal — that walk is the claim. Nothing is hooked to
	OnDungeonCompleted; the portal calls :ClaimRewards(player) itself.

	Design rules (locked):
	  * MAX_RUN_ITEMS cap per player per run. A pickup past the cap is
	    REJECTED (drop stays on the ground until its normal expiry) —
	    no discard UI, the first N you grab are your N.
	  * Run gear is NOT equippable — trophies you're carrying out, not
	    upgrades. You fight with what you brought in.
	  * Run coins are pure cargo (nothing spends them mid-run).

	Replication: EscrowData is per-player (SetFor) —
	  { items = { { gearType, armorSlot?, item = <inventory entry> } },
	    coins = number }
	RunInventoryInterfaceController renders straight from it.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local DataService = require(ServerScriptService.Submodules.Core.Source.Services.DataService)
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

-- DungeonService requires this module at load, so this side reaches it
-- lazily: required on first use, once both modules exist.
local dungeonServiceLazy: any = nil
local function getDungeonService(): any
	if dungeonServiceLazy == nil then
		dungeonServiceLazy = (require :: any)(ServerScriptService.Services.DungeonService)
	end
	return dungeonServiceLazy
end

local RunEscrowService = {
	Name = "RunEscrowService",
	Dependencies = { DataService, CurrencyService, LifeService, TextIndicatorService, GearDropService } :: { any },
}

-- Per-player escrow snapshot (SetFor; was a replicated property), see
-- the module header.
RunEscrowService._escrowProperty = RemoteProperty.Server({
	changed = PlayerNetwork.EscrowDataChanged,
	get = PlayerNetwork.GetEscrowData,
}, { items = {}, coins = 0 })

--[ Constants ]--

-- Matches MAX_RUN_SLOTS in RunInventoryInterfaceController's Container
-- (15 slots = 5 wide × 3 tall), so the grid IS the cap and a full grid
-- of tiles reads as "no more room".
local MAX_RUN_ITEMS = 15

--[ Properties ]--

-- One carried drop; `item` is the fully-built inventory entry.
type EscrowItem = { gearType: string, armorSlot: string?, item: { [string]: any } }

RunEscrowService._escrow = {} :: {
	[number]: {
		items: { EscrowItem },
		coins: number,
	},
}

--[ Private helpers ]--

-- Read CLIENT-side by Pot O' Gold Sword's runtimeDescriptionCallback (see
-- _replicate). Keep in step with RelicData's RUN_COINS_ATTRIBUTE.
local RUN_COINS_ATTRIBUTE = "RunCoins"

function RunEscrowService._getOrCreate(self: typeof(RunEscrowService), player: Player)
	local entry = self._escrow[player.UserId]
	if not entry then
		entry = { items = {}, coins = 0 }
		self._escrow[player.UserId] = entry
	end
	return entry
end

function RunEscrowService._replicate(self: typeof(RunEscrowService), player: Player)
	local entry = self:_getOrCreate(player)
	self._escrowProperty:SetFor(player, {
		items = entry.items,
		coins = entry.coins,
	})

	-- Same coin count, mirrored onto an ATTRIBUTE. The Comm property above is
	-- what the run UI reads; this exists because relic
	-- runtimeDescriptionCallbacks run on the CLIENT, where no server service
	-- is reachable, and attributes replicate on their own — the same reason
	-- PlayerStatsService stamps BonusHealthPercent. Pot O' Gold Sword reads it
	-- to show its live damage bonus. Every coin change already funnels through
	-- _replicate, so the number can't go stale.
	player:SetAttribute(RUN_COINS_ATTRIBUTE, entry.coins)
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

-- Credits run coins (post-multiplier value from DropService's credit
-- path). Cargo only — nothing spends these mid-run.
function RunEscrowService.AddCoins(self: typeof(RunEscrowService), player: Player, amount: number)
	local entry = self:_getOrCreate(player)
	entry.coins += amount
	self:_replicate(player)
end

-- Dragon Lantern's drawback: strips `fraction` of the player's UNBANKED
-- run coins (rounded down). Banked profile coins are never touched --
-- the tax rides the same risk model as the rest of the escrow.
function RunEscrowService.TaxCoins(self: typeof(RunEscrowService), player: Player, fraction: number)
	local entry = self._escrow[player.UserId]
	if not entry or entry.coins <= 0 then
		return
	end
	local loss = math.floor(entry.coins * fraction)
	if loss <= 0 then
		return
	end
	entry.coins -= loss
	self:_replicate(player)
end

function RunEscrowService.GetItemCount(self: typeof(RunEscrowService), player: Player): number
	return #self:_getOrCreate(player).items
end

-- Debits run coins if the balance covers it; false (and no change)
-- otherwise. The Merchant's buy path is the only spender today — run
-- coins were cargo-only before Event rooms existed.
function RunEscrowService.SpendCoins(self: typeof(RunEscrowService), player: Player, amount: number): boolean
	local entry = self:_getOrCreate(player)
	if amount <= 0 or entry.coins < amount then
		return false
	end
	entry.coins -= amount
	self:_replicate(player)
	return true
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
	if not entry or (#entry.items == 0 and entry.coins == 0) then
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
			CurrencyTypes.Coins,
			CurrencyService:GetCurrencyValue(player, CurrencyTypes.Coins) + entry.coins
		)
	end

	print(("[RunEscrowService] Banked %d items + %d coins for %s"):format(#entry.items, entry.coins, player.Name))

	self._escrow[player.UserId] = { items = {}, coins = 0 }
	self:_replicate(player)
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
-- Refuses for a player in the death state: their escrow was already
-- discarded on death, and a corpse shouldn't be able to claim.
--
-- Until the portal exists, drive it from the command bar:
--   require(game.ServerScriptService.Services.RunEscrowService):ClaimRewards(game.Players.SomeUser)
function RunEscrowService.ClaimRewards(self: typeof(RunEscrowService), player: Player): boolean
	if LifeService and LifeService:IsDeathState(player) then
		return false
	end

	local entry = self._escrow[player.UserId]
	if not entry or (#entry.items == 0 and entry.coins == 0) then
		return false
	end

	self:BankAll(player)
	return true
end

-- Discards the whole escrow — a party WIPE, or disconnect mid-run. The
-- Spire keeps what you carried. A single death does NOT land here (see
-- Start): a revive would otherwise bring the player back with
-- nothing to show for the run so far.
function RunEscrowService.Discard(self: typeof(RunEscrowService), player: Player, reason: string?)
	local entry = self._escrow[player.UserId]
	if not entry or (#entry.items == 0 and entry.coins == 0) then
		return
	end

	print(
		("[RunEscrowService] Discarded %d items + %d coins for %s (%s)"):format(
			#entry.items,
			entry.coins,
			player.Name,
			reason or "unspecified"
		)
	)

	self._escrow[player.UserId] = { items = {}, coins = 0 }
	self:_replicate(player)
end

-- Player-initiated DROP from the run inventory: the item leaves the
-- escrow and lands on the floor around them as a PUBLIC gear drop that
-- anyone can pick up, the dropper included. Nothing is paid and nothing
-- is destroyed -- the item keeps its uuid, quality and enchantment
-- across the round trip (GearDropService holds the entry until pickup).
--
-- The escrow write happens FIRST so a duplicate request cannot drop the
-- same item twice, and is undone if the drop fails to spawn.
-- PlayerNetwork.DropRunItem handler (was a client-callable method).
function RunEscrowService._onDropItem(_self: typeof(RunEscrowService), player: Player, uuid: string): boolean
	if typeof(uuid) ~= "string" or uuid == "" then
		return false
	end

	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp or not GearDropService then
		return false
	end

	local entry = RunEscrowService:_getOrCreate(player)
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

	local dropped = table.remove(entry.items, index) :: EscrowItem
	RunEscrowService:_replicate(player)

	if not GearDropService:DropExistingGear(player, hrp.Position, dropped) then
		-- Nothing spawned (missing prefab): give it back rather than
		-- deleting the player's item.
		table.insert(entry.items, index, dropped)
		RunEscrowService:_replicate(player)
		return false
	end
	return true
end

--[ Lifecycle ]--

function RunEscrowService.Start(self: typeof(RunEscrowService))
	PlayerNetwork.DropRunItem.On(function(player: Player, uuid: string): boolean
		return self:_onDropItem(player, uuid)
	end)

	-- DISCARD only on a WIPE: every player down, the run over, the lobby
	-- teleport following. A single death KEEPS the escrow — a teammate
	-- can still revive the player, and losing the run's coins and
	-- Runbound loot on the way down made that revive worth nothing. The
	-- wipe fires on the LAST death only, so every player's escrow goes
	-- here, not just the one who died last. (Death Defiance charges absorb
	-- earlier hits without firing this at all.)
	LifeService.OnPlayerDied:Connect(function(_player: Player, isWipe: boolean?)
		if not isWipe then
			return
		end
		for _, player in Players:GetPlayers() do
			self:Discard(player, "wipe")
		end
	end)

	-- NOT hooked to OnDungeonCompleted. Boss defeat used to bank here
	-- immediately, which emptied the escrow the instant the boss died and
	-- blanked the Spire's Bounty panel mid-victory. Claiming happens when the
	-- player actually walks out through the ExitPortal (DungeonService fires
	-- OnPlayerExtracted BEFORE issuing the lobby teleport, so the escrow is
	-- still fully present here) -- the run's winnings stay on screen, and
	-- stay at risk, until then.
	getDungeonService().Signals.OnPlayerExtracted:Connect(function(player: Player)
		self:ClaimRewards(player)
	end)

	-- Disconnect mid-run = loss (the escrow was never in the profile, so
	-- dropping the in-memory entry IS the discard).
	Players.PlayerRemoving:Connect(function(player: Player)
		self._escrow[player.UserId] = nil
	end)
end

return RunEscrowService
