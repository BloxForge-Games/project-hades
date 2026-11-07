--!strict
--[[
	Module: TradeService.lua (Lobby)
	Description:
	Player-to-player trades within this hub server (2026-11-02; rules in
	Shared/Data/TradeData). THE SERVER OWNS EVERY TRADE: clients only ask,
	and nothing a client sends is trusted past "which uuid / how much".

	  REQUEST   RequestTrade -> the target gets TradeRequested (a toast) and
	            REQUEST_SECONDS to answer; RespondTrade opens the trade for
	            both. Both must be MIN_LEVEL+ and in no trade.
	  OFFER     SetOffer replaces the sender's whole offer. Every uuid must
	            be theirs, unequipped, unfavourited and not a spell; the
	            Gold and Crystals must be in their wallet -- and are
	            always 0 while TradeData.CURRENCY_TRADABLE is false
	            (items only, 2026-11-06).
	            ANY offer change bumps the version and clears both players'
	            Ready and Confirm.
	  READY     SetReady names the version it means; a stale one is ignored.
	            Both Ready starts CONFIRM_DELAY (ConfirmAt).
	  CONFIRM   ConfirmTrade (same version, past ConfirmAt). Both confirmed
	            -> _commit.
	  COMMIT    one synchronous server step, no yields: re-reads BOTH live
	            profiles, re-validates every uuid, wallet and the receivers'
	            bag space, and only then moves the items and currency and
	            writes the trade to both profiles' TradeLog (one id). Any
	            failure cancels the whole trade and moves nothing, so a piece
	            can never be in two bags or none.
	  LOCK      LOCK_ATTRIBUTE is true on both players while the trade is
	            open (this service is its only writer); the bag services and
	            the queue refuse while it is set.
	  CLOSE     cancelled by either player, a player leaving, IDLE_SECONDS
	            untouched, or a failed commit. TradeClosed tells both.
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local TradeNetwork = require(ServerScriptService.Submodules.Core.Source.Network.Trade)
local DataService = require(ServerScriptService.Submodules.Core.Source.Services.DataService)
local SettingsService =
	require(ServerScriptService.Submodules.Core.Source.Services.DataService.SubServices.SettingsService)
local CurrencyService =
	require(ServerScriptService.Submodules.Core.Source.Services.DataService.SubServices.CurrencyService)
local UserNotificationService = require(ServerScriptService.Submodules.Core.Source.Services.UserNotificationService)

local ArmorPieceData = require(ReplicatedStorage.Submodules.Core.Shared.Data.ArmorPieceData)
local InventoryCapData = require(ReplicatedStorage.Submodules.Core.Shared.Data.InventoryCapData)
local NotificationColors = require(ReplicatedStorage.Submodules.Core.Shared.Data.NotificationColors)
local TradeData = require(ReplicatedStorage.Submodules.Core.Shared.Data.TradeData)
local CurrencyTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.CurrencyTypes)
local InventoryType = require(ReplicatedStorage.Submodules.Core.Shared.Enums.InventoryType)

type Offer = { items: { string }, gold: number, crystals: number }
type Session = {
	id: string,
	players: { Player },
	offers: { [Player]: Offer },
	ready: { [Player]: boolean },
	confirmed: { [Player]: boolean },
	version: number,
	confirmAt: number,
	touched: number,
	closed: boolean,
}
type Found = { item: { [string]: any }, list: { any }, index: number }

local TradeService = {
	Name = "TradeService",
	Dependencies = { DataService, CurrencyService, UserNotificationService, SettingsService } :: { any },
}

TradeService._sessions = {} :: { [Player]: Session }
-- target -> requester UserId -> expiry (server time)
TradeService._requests = {} :: { [Player]: { [number]: number } }
TradeService._lastRequest = {} :: { [Player]: number }

--[ Helpers ]--

local function now(): number
	return workspace:GetServerTimeNow()
end

local function notify(player: Player, title: string, text: string, color: Color3?)
	UserNotificationService:RequestUserNotification(player, {
		titleText = title,
		titleTextColor3 = color or NotificationColors.Error,
		text = text,
	})
end

local function profileOf(player: Player): { [string]: any }?
	local profile = DataService:GetProfileData(player)
	if next(profile) == nil then
		return nil
	end
	return profile
end

local function levelOf(player: Player): number
	local profile = profileOf(player)
	return if profile then tonumber(profile.Level) or 1 else 0
end

-- The piece `uuid` in `inventory`: the item, the list it sits in and where.
local function findItem(inventory: { [string]: any }, uuid: string): Found?
	local weapons = inventory[InventoryType.Weapon]
	if type(weapons) == "table" then
		for index, item in weapons do
			if type(item) == "table" and item.uuid == uuid then
				return { item = item, list = weapons, index = index }
			end
		end
	end
	local gear = inventory[InventoryType.Gear]
	if type(gear) == "table" then
		for _, pieces in gear do
			if type(pieces) == "table" then
				for index, item in pieces do
					if type(item) == "table" and item.uuid == uuid then
						return { item = item, list = pieces, index = index }
					end
				end
			end
		end
	end
	return nil
end

local function isEquipped(item: { [string]: any }): boolean
	if item.equipSlot ~= nil then
		return (tonumber(item.equipSlot) or 0) > 0
	end
	return item.equipped == true
end

-- Weapons and armour in the bag (the cap counts both).
local function countGear(inventory: { [string]: any }): number
	local count = 0
	local weapons = inventory[InventoryType.Weapon]
	if type(weapons) == "table" then
		count += #weapons
	end
	local gear = inventory[InventoryType.Gear]
	if type(gear) == "table" then
		for _, pieces in gear do
			if type(pieces) == "table" then
				count += #pieces
			end
		end
	end
	return count
end

-- Into `inventory` the way a pickup banks: weapons in their list, armour
-- under its slot.
local function bank(inventory: { [string]: any }, entry: { [string]: any })
	local armor = ArmorPieceData[entry.name]
	if armor and type(armor.slot) == "string" then
		local gear = inventory[InventoryType.Gear]
		if type(gear) ~= "table" then
			gear = {}
			inventory[InventoryType.Gear] = gear
		end
		local pieces = gear[armor.slot]
		if type(pieces) ~= "table" then
			pieces = {}
			gear[armor.slot] = pieces
		end
		table.insert(pieces, entry)
	else
		local weapons = inventory[InventoryType.Weapon]
		if type(weapons) ~= "table" then
			weapons = {}
			inventory[InventoryType.Weapon] = weapons
		end
		table.insert(weapons, entry)
	end
end

-- An offer's piece as the other side reads it.
local function itemView(item: { [string]: any }): any
	local bonus = {}
	if type(item.bonusStats) == "table" then
		for key, value in item.bonusStats do
			if type(key) == "string" and type(value) == "number" then
				table.insert(bonus, { Key = key, Value = value })
			end
		end
	end
	return {
		Uuid = tostring(item.uuid),
		Name = tostring(item.name),
		Rarity = tostring(item.rarity or ""),
		Level = math.clamp(math.floor(tonumber(item.level) or 1), 0, 65535),
		Upgrades = math.clamp(math.floor(tonumber(item.upgrades) or 0), 0, 255),
		Quality = tonumber(item.scalarMultiplier) or 1,
		Enchantment = if type(item.enchantment) == "string" then item.enchantment else "",
		Bonus = bonus,
	}
end

-- Whether `offer` is good against `player`'s live profile: every uuid
-- theirs, tradeable and listed once; the wallet covers the Gold and
-- Crystals. Returns a reason when it is not.
local function checkOffer(player: Player, offer: Offer): (boolean, string?)
	local profile = profileOf(player)
	if not profile or type(profile.Inventory) ~= "table" then
		return false, "Your profile isn't loaded yet."
	end
	if #offer.items > TradeData.MAX_ITEMS then
		return false, ("At most %d items a side."):format(TradeData.MAX_ITEMS)
	end
	local seen: { [string]: boolean } = {}
	for _, uuid in offer.items do
		if seen[uuid] then
			return false, "That item is already on your offer."
		end
		seen[uuid] = true
		local found = findItem(profile.Inventory, uuid)
		if not found then
			return false, "That item is no longer in your bag."
		end
		if isEquipped(found.item) then
			return false, "Unequip it before trading it."
		end
		if found.item.favourite == true then
			return false, "Unfavourite it before trading it."
		end
	end
	local gold = CurrencyService:GetCurrencyValue(player, CurrencyTypes.Gold)
	if offer.gold > gold then
		return false, "Not enough Gold."
	end
	if offer.crystals > CurrencyService:GetCurrencyValue(player, CurrencyTypes.ArcaneCrystals) then
		return false, "Not enough Arcane Crystals."
	end
	return true, nil
end

--[ Session ]--

function TradeService._partnerOf(_self: typeof(TradeService), session: Session, player: Player): Player
	return if session.players[1] == player then session.players[2] else session.players[1]
end

function TradeService._offerView(_self: typeof(TradeService), session: Session, player: Player): any
	local offer = session.offers[player]
	local profile = profileOf(player)
	local items = {}
	if profile and type(profile.Inventory) == "table" then
		for _, uuid in offer.items do
			local found = findItem(profile.Inventory, uuid)
			if found then
				table.insert(items, itemView(found.item))
			end
		end
	end
	return {
		Items = items,
		Gold = offer.gold,
		Crystals = offer.crystals,
		Ready = session.ready[player] == true,
		Confirmed = session.confirmed[player] == true,
	}
end

function TradeService._send(self: typeof(TradeService), session: Session)
	for _, player in session.players do
		if player.Parent then
			local partner = self:_partnerOf(session, player)
			TradeNetwork.TradeUpdated.Fire(player, {
				PartnerUserId = partner.UserId,
				Version = session.version,
				Mine = self:_offerView(session, player),
				Theirs = self:_offerView(session, partner),
				ConfirmAt = session.confirmAt,
			})
		end
	end
end

function TradeService._close(self: typeof(TradeService), session: Session, completed: boolean, message: string)
	if session.closed then
		return
	end
	session.closed = true
	for _, player in session.players do
		if self._sessions[player] == session then
			self._sessions[player] = nil
		end
		player:SetAttribute(TradeData.LOCK_ATTRIBUTE, nil)
		if player.Parent then
			TradeNetwork.TradeClosed.Fire(player, { Completed = completed, Message = message })
		end
	end
end

-- Any change to an offer: a new version, both Ready and Confirm cleared.
function TradeService._changed(self: typeof(TradeService), session: Session)
	session.version += 1
	session.ready = {}
	session.confirmed = {}
	session.confirmAt = 0
	session.touched = now()
	self:_send(session)
end

function TradeService._open(self: typeof(TradeService), a: Player, b: Player)
	local session: Session = {
		id = HttpService:GenerateGUID(false),
		players = { a, b },
		offers = {
			[a] = { items = {}, gold = 0, crystals = 0 },
			[b] = { items = {}, gold = 0, crystals = 0 },
		},
		ready = {},
		confirmed = {},
		version = 1,
		confirmAt = 0,
		touched = now(),
		closed = false,
	}
	for _, player in session.players do
		self._sessions[player] = session
		player:SetAttribute(TradeData.LOCK_ATTRIBUTE, true)
		-- Pending requests to or from either player lapse.
		self._requests[player] = nil
	end
	self:_send(session)
end

-- The swap: one synchronous step over both LIVE profiles. Everything is
-- re-checked first; on any failure nothing moves and the trade closes.
function TradeService._commit(self: typeof(TradeService), session: Session)
	local a, b = session.players[1], session.players[2]
	if not a.Parent or not b.Parent then
		self:_close(session, false, "A player left. Nothing was traded.")
		return
	end
	for _, player in session.players do
		local ok, reason = checkOffer(player, session.offers[player])
		if not ok then
			self:_close(session, false, ("Trade cancelled: %s"):format(reason or "an offer changed."))
			return
		end
	end
	local profileA, profileB = profileOf(a), profileOf(b)
	if not profileA or not profileB then
		self:_close(session, false, "A profile was not loaded. Nothing was traded.")
		return
	end
	local invA, invB = profileA.Inventory, profileB.Inventory
	local offerA, offerB = session.offers[a], session.offers[b]
	-- Bag space after the swap.
	local afterA = countGear(invA) - #offerA.items + #offerB.items
	local afterB = countGear(invB) - #offerB.items + #offerA.items
	if afterA > InventoryCapData.BASE_SLOTS or afterB > InventoryCapData.BASE_SLOTS then
		self:_close(session, false, "Trade cancelled: a bag would be over full.")
		return
	end

	-- Take every piece out of its owner's bag (resolved fresh, by uuid).
	local function take(inventory: { [string]: any }, uuids: { string }): { { [string]: any } }
		local taken = {}
		for _, uuid in uuids do
			local found = findItem(inventory, uuid) :: Found
			table.remove(found.list, found.index)
			local entry = found.item
			entry.favourite = nil
			if entry.equipSlot ~= nil then
				entry.equipSlot = 0
			else
				entry.equipped = false
			end
			table.insert(taken, entry)
		end
		return taken
	end
	local fromA = take(invA, offerA.items)
	local fromB = take(invB, offerB.items)
	for _, entry in fromA do
		bank(invB, entry)
	end
	for _, entry in fromB do
		bank(invA, entry)
	end

	-- Currency: each pays what they sent and gets what the other sent less
	-- the trade fee (TradeData.Received), so currency drains as it moves.
	local goldA = CurrencyService:GetCurrencyValue(a, CurrencyTypes.Gold)
	local goldB = CurrencyService:GetCurrencyValue(b, CurrencyTypes.Gold)
	local crystalsA = CurrencyService:GetCurrencyValue(a, CurrencyTypes.ArcaneCrystals)
	local crystalsB = CurrencyService:GetCurrencyValue(b, CurrencyTypes.ArcaneCrystals)
	CurrencyService:SetCurrencyValue(
		a,
		CurrencyTypes.Gold,
		goldA - offerA.gold + TradeData.Received(offerB.gold),
		{ transaction = "Trade", sku = "PlayerTrade" }
	)
	CurrencyService:SetCurrencyValue(
		b,
		CurrencyTypes.Gold,
		goldB - offerB.gold + TradeData.Received(offerA.gold),
		{ transaction = "Trade", sku = "PlayerTrade" }
	)
	CurrencyService:SetCurrencyValue(
		a,
		CurrencyTypes.ArcaneCrystals,
		crystalsA - offerA.crystals + TradeData.Received(offerB.crystals),
		{ transaction = "Trade", sku = "PlayerTrade" }
	)
	CurrencyService:SetCurrencyValue(
		b,
		CurrencyTypes.ArcaneCrystals,
		crystalsB - offerB.crystals + TradeData.Received(offerA.crystals),
		{ transaction = "Trade", sku = "PlayerTrade" }
	)

	-- Both profiles log the same trade id.
	local at = os.time()
	local function log(profile: { [string]: any }, partner: Player, gave: Offer, got: Offer)
		local entries = if type(profile.TradeLog) == "table" then profile.TradeLog else {}
		table.insert(entries, 1, {
			Id = session.id,
			PartnerUserId = partner.UserId,
			At = at,
			Gave = { Items = table.clone(gave.items), Gold = gave.gold, Crystals = gave.crystals },
			Got = { Items = table.clone(got.items), Gold = got.gold, Crystals = got.crystals },
		})
		while #entries > TradeData.LOG_LENGTH do
			table.remove(entries)
		end
		return entries
	end
	DataService:SetProfileValue(a, "Inventory", invA)
	DataService:SetProfileValue(b, "Inventory", invB)
	DataService:SetProfileValue(a, "TradeLog", log(profileA, b, offerA, offerB))
	DataService:SetProfileValue(b, "TradeLog", log(profileB, a, offerB, offerA))
	self:_close(session, true, "Trade complete!")
end

--[ Handlers ]--

function TradeService._onRequest(self: typeof(TradeService), player: Player, targetUserId: number)
	local last = self._lastRequest[player]
	if last and now() - last < TradeData.REQUEST_COOLDOWN then
		return
	end
	self._lastRequest[player] = now()
	local target = Players:GetPlayerByUserId(targetUserId)
	if not target or target == player then
		return
	end
	if self._sessions[player] then
		notify(player, "Can't Trade", "You are already in a trade.")
		return
	end
	if levelOf(player) < TradeData.MIN_LEVEL then
		notify(player, "Can't Trade", ("Trading opens at Level %d."):format(TradeData.MIN_LEVEL))
		return
	end
	if levelOf(target) < TradeData.MIN_LEVEL then
		notify(player, "Can't Trade", ("%s is under Level %d."):format(target.DisplayName, TradeData.MIN_LEVEL))
		return
	end
	if self._sessions[target] then
		notify(player, "Can't Trade", ("%s is already trading."):format(target.DisplayName))
		return
	end
	-- The target turned trade requests off (Trading window toggle).
	if not SettingsService:AcceptsRequests(target, "TradeRequests") then
		notify(player, "Can't Trade", ("%s isn't taking trade requests."):format(target.DisplayName))
		return
	end
	local list = self._requests[target] or {}
	self._requests[target] = list
	local expiresAt = now() + TradeData.REQUEST_SECONDS
	list[player.UserId] = expiresAt
	TradeNetwork.TradeRequested.Fire(target, { FromUserId = player.UserId, ExpiresAt = expiresAt })
	notify(player, "Trade Request Sent", ("Waiting for %s..."):format(target.DisplayName), NotificationColors.System)
end

function TradeService._onRespond(self: typeof(TradeService), player: Player, fromUserId: number, accept: boolean)
	local list = self._requests[player]
	local expiresAt = list and list[fromUserId]
	if not list or not expiresAt then
		return
	end
	list[fromUserId] = nil
	local from = Players:GetPlayerByUserId(fromUserId)
	if not from then
		notify(player, "Can't Trade", "They left the server.")
		return
	end
	if not accept then
		notify(from, "Trade Declined", ("%s declined your trade."):format(player.DisplayName))
		TradeNetwork.RequestAnswered.Fire(from, player.UserId)
		return
	end
	if now() > expiresAt then
		notify(player, "Can't Trade", "That request ran out.")
		return
	end
	if self._sessions[player] or self._sessions[from] then
		notify(player, "Can't Trade", "One of you is already trading.")
		return
	end
	if levelOf(player) < TradeData.MIN_LEVEL or levelOf(from) < TradeData.MIN_LEVEL then
		notify(player, "Can't Trade", ("Trading opens at Level %d."):format(TradeData.MIN_LEVEL))
		return
	end
	self:_open(from, player)
end

function TradeService._onSetOffer(self: typeof(TradeService), player: Player, update: any)
	local session = self._sessions[player]
	if not session or session.closed then
		return
	end
	local items: { string } = {}
	for _, uuid in update.Items do
		table.insert(items, uuid)
	end
	local offer: Offer = {
		items = items,
		-- Items only unless currency trading is on: what a client sends
		-- for these is ignored.
		gold = if TradeData.CURRENCY_TRADABLE then math.max(math.floor(update.Gold), 0) else 0,
		crystals = if TradeData.CURRENCY_TRADABLE then math.max(math.floor(update.Crystals), 0) else 0,
	}
	local ok, reason = checkOffer(player, offer)
	if not ok then
		notify(player, "Can't Offer That", reason or "That offer isn't valid.")
		-- The client's offer snaps back to the one the server holds.
		self:_send(session)
		return
	end
	session.offers[player] = offer
	self:_changed(session)
end

function TradeService._onSetReady(self: typeof(TradeService), player: Player, update: any)
	local session = self._sessions[player]
	if not session or session.closed or update.Version ~= session.version then
		return
	end
	session.ready[player] = update.Ready == true
	session.confirmed = {}
	local partner = self:_partnerOf(session, player)
	session.confirmAt = if session.ready[player] and session.ready[partner] then now() + TradeData.CONFIRM_DELAY else 0
	session.touched = now()
	self:_send(session)
end

function TradeService._onConfirm(self: typeof(TradeService), player: Player, version: number)
	local session = self._sessions[player]
	if not session or session.closed or version ~= session.version then
		return
	end
	local partner = self:_partnerOf(session, player)
	if not (session.ready[player] and session.ready[partner]) or session.confirmAt <= 0 then
		return
	end
	if now() < session.confirmAt - 0.1 then
		return
	end
	session.confirmed[player] = true
	session.touched = now()
	if session.confirmed[partner] then
		self:_commit(session)
	else
		self:_send(session)
	end
end

function TradeService._onCancel(self: typeof(TradeService), player: Player)
	local session = self._sessions[player]
	if session then
		local partner = self:_partnerOf(session, player)
		self:_close(session, false, ("%s cancelled the trade."):format(player.DisplayName))
		if partner.Parent then
			notify(partner, "Trade Cancelled", ("%s cancelled the trade."):format(player.DisplayName))
		end
	end
end

function TradeService._onPlayerRemoving(self: typeof(TradeService), player: Player)
	local session = self._sessions[player]
	if session then
		self:_close(session, false, ("%s left. Nothing was traded."):format(player.DisplayName))
	end
	self._requests[player] = nil
	self._lastRequest[player] = nil
	for _, list in self._requests do
		list[player.UserId] = nil
	end
end

--[ Lifecycle ]--

function TradeService.Start(self: typeof(TradeService))
	TradeNetwork.RequestTrade.On(function(player: Player, targetUserId: number)
		self:_onRequest(player, targetUserId)
	end)
	TradeNetwork.RespondTrade.On(function(player: Player, response)
		self:_onRespond(player, response.FromUserId, response.Accept)
	end)
	TradeNetwork.SetOffer.On(function(player: Player, update)
		self:_onSetOffer(player, update)
	end)
	TradeNetwork.SetReady.On(function(player: Player, update)
		self:_onSetReady(player, update)
	end)
	TradeNetwork.ConfirmTrade.On(function(player: Player, version: number)
		self:_onConfirm(player, version)
	end)
	TradeNetwork.CancelTrade.On(function(player: Player)
		self:_onCancel(player)
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		self:_onPlayerRemoving(player)
	end)

	-- Idle trades close; lapsed requests drop.
	task.spawn(function()
		while true do
			task.wait(10)
			local t = now()
			local seen: { [Session]: boolean } = {}
			for _, session in self._sessions do
				if not seen[session] then
					seen[session] = true
					if t - session.touched > TradeData.IDLE_SECONDS then
						self:_close(session, false, "The trade timed out.")
					end
				end
			end
			for _, list in self._requests do
				for userId, expiresAt in list do
					if t > expiresAt then
						list[userId] = nil
					end
				end
			end
		end
	end)
end

return TradeService
