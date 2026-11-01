--!strict
--[[
	Module: Server/Services/RunEscrowService.lua
	Description:
	The run-scoped ESCROW for the three run currencies. Since 2026-10-31
	GEAR IS NOT ESCROWED: a gear drop banks into the profile the moment it
	is picked up (AddItem), win or lose, so a run can never take a weapon
	back (GDD.md, "A normal run"). What rides the escrow:

	  * GEMS -- the run currency. Mobs drop them, the Merchant and the
	    Relic Slot stand spend them, and they are DISCARDED when the run
	    ends: spend or lose. Replicated as `gems` and mirrored onto the
	    RunGems attribute (Pot O' Gold Sword reads it client-side).
	  * COINS -- permanent Gold, from the chests, the pots and gear sales.
	    Banked into the profile's Gold at the end of the run.
	  * ARCANE CRYSTALS -- the spell currency, from the chests and the
	    veins, banked exactly like the Coins.

	How a run ends decides the share (design call, 2026-10-30):
	  * CLEAR (the exit portal, :ClaimRewards; or a leave / death after the
	    final boss is down): ALL the Coins and Crystals bank.
	  * FULL DEATH, WIPE or LEAVE before the clear: ALL of it banks too
	    (OUT_OF_RUN_KEEP = 1 since 2026-10-31; half from 2026-10-30 until
	    then). Nothing a player picks up is ever lost; the run ending early
	    only costs the chests not yet opened. The bank still waits for
	    LifeService.OnPlayerFullyDied for a DOWNED player, so a revive
	    keeps the run intact.
	  * Gems die with the run on every path (and no longer drop: Gems have
	    no sink since the Merchant left, DropService GEMS_ENABLED).

	Beating the boss is not the same as getting out. The escrow stays on
	screen after the boss dies, until the player walks through the exit
	portal; nothing is hooked to OnDungeonCompleted. The claim rides
	LifeService's OnPlayerLeavingToLobby, fired once the lobby teleport
	has gone out.

	Every write goes through _commit, which republishes the mirrors, so
	the table, the EscrowData property and the attribute never disagree.

	Replication: EscrowData is per-player (SetFor) --
	  { gems = number, coins = number, arcaneCrystals = number }
	ToolBarInterface's currency readouts render straight from it.

	The bag cap still applies at pickup (InventoryCapData): a drop that
	would overfill the bag is refused and stays on the floor.
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
	Dependencies = { DataService, CurrencyService, LifeService, TextIndicatorService } :: { any },
}

-- Per-player escrow snapshot (SetFor; was a replicated property), see
-- the module header.
RunEscrowService._escrowProperty = RemoteProperty.Server({
	changed = PlayerNetwork.EscrowDataChanged,
	get = PlayerNetwork.GetEscrowData,
}, { gems = 0, coins = 0, arcaneCrystals = 0 })

--[ Constants ]--

--[ Properties ]--

RunEscrowService._escrow = {} :: {
	[number]: {
		gems: number,
		coins: number,
		arcaneCrystals: number,
	},
}

--[ Private helpers ]--

-- Read CLIENT-side by Pot O' Gold Sword's runtimeDescriptionCallback (see
-- _replicate). Keep in step with RelicData.
local RUN_GEMS_ATTRIBUTE = "RunGems"

-- Whether the run's final boss is down (DungeonService Run.cleared): the
-- escrow is then safe -- a death banks it rather than losing it.
-- DungeonService is a consumer of this module, so it is reached at call time.
-- The share of the Coins and Arcane Crystals a player keeps when they are out
-- of a run they did not clear: fully dead, wiped, or gone. ALL of it since
-- 2026-10-31 (design call: dying costs the rest of the run, never what
-- was picked up); half from 2026-10-30 until then. Kept as a knob.
local OUT_OF_RUN_KEEP = 1

local function runIsCleared(): boolean
	local dungeonService = Blitz.OptionalService("DungeonService")
	return dungeonService ~= nil and dungeonService:IsRunCleared() == true
end

function RunEscrowService._getOrCreate(self: typeof(RunEscrowService), player: Player)
	local entry = self._escrow[player.UserId]
	if not entry then
		entry = { gems = 0, coins = 0, arcaneCrystals = 0 }
		self._escrow[player.UserId] = entry
	end
	return entry
end

function RunEscrowService._replicate(self: typeof(RunEscrowService), player: Player)
	local entry = self:_getOrCreate(player)
	self._escrowProperty:SetFor(player, {
		gems = entry.gems or 0,
		coins = entry.coins,
		arcaneCrystals = entry.arcaneCrystals,
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
-- the old one; the coin wipe then republishes through _commitCoins like
-- any other coin change.
function RunEscrowService._clearEscrow(self: typeof(RunEscrowService), player: Player)
	self._escrow[player.UserId] = { gems = 0, coins = 0, arcaneCrystals = 0 }
	self:_commitCoins(player, 0)
end

--[ Public API ]--

-- Banks a picked-up gear entry straight into the profile (2026-10-31;
-- it sat in the escrow until the walk-out before). Returns false, and the
-- drop stays on the floor, when the bag is full (InventoryCapData).
-- `escrowItem` = { gearType, armorSlot?, item } where `item` is the
-- fully-built inventory entry (GearDrop:_buildInventoryEntry shape) --
-- it goes into the profile verbatim, so the stats the player saw on the
-- floor are exactly what they keep. One SetProfileValue write, so the
-- loadout refresh, the bag and Power all see it as a single update.
function RunEscrowService.AddItem(
	self: typeof(RunEscrowService),
	player: Player,
	escrowItem: { [string]: any }
): boolean
	local profile = DataService and DataService:GetProfileData(player)
	if not profile or not profile.Inventory then
		warn(("[RunEscrowService] Pickup refused -- no inventory profile for %s"):format(player.Name))
		return false
	end

	if countOwnedGear(profile) >= InventoryCapData.BASE_SLOTS then
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
			("[RunEscrowService] Refusing malformed pickup for %s (gearType=%s)"):format(
				player.Name,
				tostring(escrowItem.gearType)
			)
		)
		return false
	end
	DataService:SetProfileValue(player, "Inventory", profile.Inventory)

	-- Ticked only on an ACCEPTED pickup, so an item refused by the cap
	-- above never reads as a gain. Monotonic: it answers "something was
	-- just picked up" (SpiritCompanion), not "how much is carried".
	player:SetAttribute(Attributes.GearGained, ((player:GetAttribute(Attributes.GearGained) or 0) :: number) + 1)
	self:_replicate(player)
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
-- carried Coins (each rounded down). Crystals and gear are never touched.
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

-- Arcane Crystals rides the escrow under the same rules as coins: banked to
-- the profile on clear, gone on death. No tax, no multipliers.
function RunEscrowService.AddArcaneCrystals(self: typeof(RunEscrowService), player: Player, amount: number)
	local entry = self:_getOrCreate(player)
	entry.arcaneCrystals = (entry.arcaneCrystals or 0) + math.max(0, math.floor(amount))
	self:_replicate(player)
end

function RunEscrowService.GetArcaneCrystals(self: typeof(RunEscrowService), player: Player): number
	local entry = self._escrow[player.UserId]
	return if entry then (entry.arcaneCrystals or 0) else 0
end

function RunEscrowService.GetCoins(self: typeof(RunEscrowService), player: Player): number
	return self:_getOrCreate(player).coins
end

-- Banks the whole escrow at a CLEAR: all the Coins and Crystals into the
-- profile (gear already banked at pickup), the Gems discarded.
function RunEscrowService.BankAll(self: typeof(RunEscrowService), player: Player)
	local entry = self._escrow[player.UserId]
	if not entry or (entry.coins == 0 and (entry.arcaneCrystals or 0) == 0) then
		-- Gems alone are nothing to bank: they die with the run.
		self:_clearEscrow(player)
		return
	end
	self:BankCurrencies(player, 1)
	Log.debug(("[RunEscrowService] Banked the run for %s (%d gems discarded)"):format(player.Name, entry.gems or 0))
	self:_clearEscrow(player)
end

-- Banks the Coins and Arcane Crystals (the profile's Gold and Crystals) and
-- zeroes them in the escrow, leaving the Gems where they are.
-- `keepFraction` (default all) is the share that reaches the
-- profile; the rest is lost. A full death, a wipe and a leave keep
-- OUT_OF_RUN_KEEP (design call, 2026-10-30; they kept it all before).
function RunEscrowService.BankCurrencies(self: typeof(RunEscrowService), player: Player, keepFraction: number?)
	local entry = self._escrow[player.UserId]
	if not entry or (entry.coins == 0 and (entry.arcaneCrystals or 0) == 0) then
		return
	end
	if not (DataService and DataService:GetProfileData(player)) then
		warn(("[RunEscrowService] Currency bank failed — no profile for %s"):format(player.Name))
		return
	end
	local keep = math.clamp(keepFraction or 1, 0, 1)
	local coins = math.floor(entry.coins * keep)
	local crystals = math.floor((entry.arcaneCrystals or 0) * keep)
	if coins > 0 then
		CurrencyService:SetCurrencyValue(
			player,
			CurrencyTypes.Gold,
			CurrencyService:GetCurrencyValue(player, CurrencyTypes.Gold) + coins
		)
	end
	if crystals > 0 then
		CurrencyService:SetCurrencyValue(
			player,
			CurrencyTypes.ArcaneCrystals,
			CurrencyService:GetCurrencyValue(player, CurrencyTypes.ArcaneCrystals) + crystals
		)
	end
	entry.arcaneCrystals = 0
	self:_commitCoins(player, 0)
	Log.debug(
		("[RunEscrowService] Banked %d coins + %d arcane crystals for %s (currencies only)"):format(
			coins,
			crystals,
			player.Name
		)
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
	if not entry or (entry.coins == 0 and (entry.arcaneCrystals or 0) == 0) then
		-- Nothing to bank; Gems (if any) die with the run.
		self:_clearEscrow(player)
		return false
	end

	self:BankAll(player)
	return true
end

-- Ends the escrow -- a party WIPE, or disconnect mid-run. The Coins and
-- Arcane Crystals are BANKED first (BankCurrencies: all of them after a
-- clear, OUT_OF_RUN_KEEP before one); the Gems die. A single death does
-- NOT land here (see Start): a revive would otherwise bring the player
-- back with nothing to show for the run so far.
function RunEscrowService.Discard(self: typeof(RunEscrowService), player: Player, reason: string?)
	local entry = self._escrow[player.UserId]
	if not entry or (entry.coins == 0 and (entry.arcaneCrystals or 0) == 0 and (entry.gems or 0) == 0) then
		return
	end

	self:BankCurrencies(player, if runIsCleared() then 1 else OUT_OF_RUN_KEEP)

	Log.debug(
		("[RunEscrowService] Discarded %d gems for %s (%s)"):format(
			entry.gems or 0,
			player.Name,
			reason or "unspecified"
		)
	)

	self:_clearEscrow(player)
end

--[ Lifecycle ]--

function RunEscrowService.Start(self: typeof(RunEscrowService))
	-- Every FULL death banks half the run's Coins and Crystals and loses
	-- the rest (OUT_OF_RUN_KEEP); the gear was banked at pickup, so a
	-- death costs currency only (design call, 2026-10-31). Deliberately
	-- NOT OnPlayerDied (= downed): while the revive window is open a
	-- revive bought in time keeps everything.
	--
	-- A WIPE (every player fully dead, the run over, the lobby teleport
	-- following) THEN discards every player's escrow. (Death Defiance
	-- charges absorb earlier hits without firing this.)
	LifeService.OnPlayerFullyDied:Connect(function(player: Player, isWipe: boolean?)
		task.spawn(function()
			-- A CLEARED run (final boss down, design call 2026-10: no
			-- extraction) is already won: nothing is lost -- the lobby
			-- teleport that follows banks it.
			if runIsCleared() then
				return
			end
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
	-- above.
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

	-- Disconnect mid-run: the Coins and Crystals are banked (half before a
	-- clear, all after), THEN the entry is dropped. On
	-- PlayerEventService.OnPlayerLeaving, the edge that runs BEFORE the
	-- profile release and the currency registry teardown (both on
	-- OnPlayerRemoved): on raw PlayerRemoving this raced them, and a
	-- leaver carrying Coins or Crystals lost them (QA 2026-10-21, P0 #1).
	PlayerEventService.OnPlayerLeaving:Connect(function(player: Player)
		self:BankCurrencies(player, if runIsCleared() then 1 else OUT_OF_RUN_KEEP)
		self._escrow[player.UserId] = nil
	end)
end

return RunEscrowService
