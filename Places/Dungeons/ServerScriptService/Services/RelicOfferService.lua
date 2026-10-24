--!strict
--[[
	Module: RelicOfferService.lua
	Description:
	The PICK-ONE relic offer: a hand of relics dealt to ONE player as cards
	on their screen (RelicOfferInterfaceController), replacing the physical
	claim-one fan that used to drop in front of the vending machine, the
	Forge and the Cursed Shrine. The server owns everything that matters:

	  * Offer(player, relics, source) rolls nothing itself -- the caller
	    already chose the relics (RelicMachine / EventService) -- it only
	    deals them, stamps the deadline and tells the client.
	  * ONE open offer per player. A second Offer while one is open is
	    QUEUED and dealt the moment the first resolves, so a Forge hand
	    can never overwrite a vending pull mid-choice.
	  * The client answers with RelicOfferChosen (a name, or nil = Skip);
	    every answer is validated here exactly as the old pickup was:
	    the offer must be theirs and open, the relic must be in the hand,
	    a dead player takes nothing, and the relic cap refuses a pick
	    (RelicService.CanAcceptRelic) WITHOUT closing the offer.
	  * OFFER_SECONDS after the deal the server auto-picks a random
	    acceptable relic from the hand -- or Skips when none is (the cap,
	    a dead player) -- so a walked-away offer can never hold the gate.
	  * Taking a relic grants it (RelicService.AddRelicsRegistry) and
	    Skipping fires RelicService.MarkRelicChoiceMade, so everything
	    keyed off "this player chose" (chiefly GateService's early open)
	    proceeds exactly as it did off the floor pickup.

	The floor teardown (DungeonService.Signals.OnFloorTeardown, reached
	through Blitz.OptionalService -- no consumer requires DungeonService)
	voids every open offer: the hand belonged to a floor that no longer
	exists.
]]

--[ Roblox Services ]--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

--[ Imports ]--

local PlayerEventService = require(ServerScriptService.Submodules.Core.Source.Services.PlayerEventService)
local TextIndicatorService = require(ServerScriptService.Submodules.Core.Source.Services.TextIndicatorService)
local RelicService = require(ServerScriptService.Services.RelicService)
local LifeService = require(ServerScriptService.Services.LifeService)
local RelicNetwork = require(ServerScriptService.Submodules.Core.Source.Network.Relic)
local RelicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicData)
local SkipRelicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.SkipRelicData)
local Blitz = require(ReplicatedStorage.Submodules.Core.Shared.Blitz)
local Signal = require(ReplicatedStorage.Submodules.Core.Packages.Signal)
local Log = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Log)

--[ Constants ]--

-- How long a dealt hand stays open before the server picks for the
-- player. Counted from the DEAL, not from when the cards are on screen:
-- hiding the cards does not pause it.
local OFFER_SECONDS = 30

-- The relic-cap refusal, the same red the old floor pickup used.
local RELIC_CAP_COLOR = Color3.fromRGB(250, 70, 70)
local PICKUP_TEXT_COLOR = Color3.fromRGB(255, 255, 255)

--[ Types ]--

type Offer = {
	id: number,
	player: Player,
	relics: { string },
	source: string,
	expiresAt: number,
	canSkip: boolean,
}

--[ Service ]--

local RelicOfferService = {
	Name = "RelicOfferService",
	Dependencies = { PlayerEventService, TextIndicatorService, RelicService, LifeService } :: { any },

	Signals = {
		-- (player, relicName?, source) -- how a hand ended: the name that was
		-- taken, or nil for a Skip.
		OnOfferResolved = Signal.new(),
	},

	-- [userId] = the OPEN offer, or nil.
	_pending = {} :: { [number]: Offer },
	-- [userId] = offers waiting behind the open one, in deal order.
	_queued = {} :: { [number]: { Offer } },
	-- Monotonic; an id is never reused, so a late answer for a resolved
	-- offer can never match a newer one.
	_nextId = 1,
}

--[ Private ]--

-- The relic-cap refusal (indicator + Error sting), the recipe the floor
-- pickup used, so a refused card feels like a refused relic did.
function RelicOfferService._refuseAtCap(_self: typeof(RelicOfferService), player: Player)
	local character = player.Character
	local indicatorPart = character
		and (character:FindFirstChild("Head") or character:FindFirstChild("HumanoidRootPart")) :: BasePart?
	if indicatorPart then
		TextIndicatorService:ShowIndicator(
			player,
			indicatorPart,
			string.format("Reached Maximum Relics! (%d)", RelicService:GetRelicSlots(player)),
			RELIC_CAP_COLOR,
			true
		)
	end
end

function RelicOfferService._showPickupText(_self: typeof(RelicOfferService), player: Player, text: string)
	local character = player.Character
	local indicatorPart = character
		and (character:FindFirstChild("Head") or character:FindFirstChild("HumanoidRootPart")) :: BasePart?
	if indicatorPart then
		TextIndicatorService:ShowIndicator(player, indicatorPart, text, PICKUP_TEXT_COLOR)
	end
end

-- Deals `offer` to its player: it becomes the open one, the deadline
-- starts, the client gets the hand.
function RelicOfferService._deal(self: typeof(RelicOfferService), offer: Offer)
	local player = offer.player
	offer.expiresAt = workspace:GetServerTimeNow() + OFFER_SECONDS
	offer.canSkip = RelicService:IsAtRelicCap(player)
	self._pending[player.UserId] = offer

	RelicNetwork.RelicOffered.Fire(player, {
		OfferId = offer.id,
		Source = offer.source,
		Relics = offer.relics,
		ExpiresAt = offer.expiresAt,
		CanSkip = offer.canSkip,
	})
	Log.debug(
		("[RelicOfferService] dealt offer %d (%s) to %s: %s"):format(
			offer.id,
			offer.source,
			player.Name,
			table.concat(offer.relics, ", ")
		)
	)

	task.delay(OFFER_SECONDS, function()
		-- Still the open offer? Anything else already resolved it.
		if self._pending[player.UserId] ~= offer then
			return
		end
		self:_autoPick(offer)
	end)
end

-- The deadline: a random relic the player can still take, else a Skip.
-- A dead player takes nothing (the old pickup refused them too), so
-- their hand skips.
function RelicOfferService._autoPick(self: typeof(RelicOfferService), offer: Offer)
	local player = offer.player
	local acceptable = {}
	if not LifeService:IsDeathState(player) then
		for _, relicName in offer.relics do
			if RelicService:CanAcceptRelic(player, relicName) then
				table.insert(acceptable, relicName)
			end
		end
	end
	if #acceptable == 0 then
		self:_resolve(offer, nil, "Skipped")
		return
	end
	self:_resolve(offer, acceptable[math.random(1, #acceptable)], "Taken")
end

-- Closes the open offer: grants or skips, tells the player and everyone
-- who watches, then deals the next queued hand if there is one.
function RelicOfferService._resolve(self: typeof(RelicOfferService), offer: Offer, relicName: string?, outcome: string)
	local player = offer.player
	if self._pending[player.UserId] ~= offer then
		return
	end
	self._pending[player.UserId] = nil

	local granted: string? = nil
	if outcome == "Taken" and relicName then
		if RelicService:AddRelicsRegistry(player, relicName, 1) then
			granted = relicName
			-- A machine / event offer has no floor origin: this player
			-- counts as the original if they ever drop it.
			RelicService:SetRelicOrigin(player, relicName, nil, nil)
			self:_showPickupText(player, "Picked up " .. relicName .. "!")
			RelicNetwork.RelicOfferTaken.FireAll({ Player = player, Rarity = RelicData[relicName].rarity })
		else
			-- The grant lost a race (a duplicate landed between the deal
			-- and the pick). Nothing was taken, but the choice was made.
			outcome = "Skipped"
		end
	end
	if outcome == "Skipped" then
		RelicService:MarkRelicChoiceMade(player)
		self:_showPickupText(player, SkipRelicData.PickupText)
	end

	if player.Parent then
		RelicNetwork.RelicOfferResolved.Fire(player, {
			OfferId = offer.id,
			RelicName = granted,
			Outcome = outcome,
		})
	end
	Log.debug(
		("[RelicOfferService] offer %d for %s: %s%s"):format(
			offer.id,
			player.Name,
			outcome,
			if granted then " (" .. granted .. ")" else ""
		)
	)
	self.Signals.OnOfferResolved:Fire(player, granted, offer.source)

	-- The next hand, if one queued up behind this one.
	local queue = self._queued[player.UserId]
	if queue and #queue > 0 and player.Parent then
		local nextOffer = table.remove(queue, 1) :: Offer
		self:_deal(nextOffer)
	end
end

-- RelicNetwork.RelicOfferChosen handler.
function RelicOfferService._onChosen(
	self: typeof(RelicOfferService),
	player: Player,
	payload: { OfferId: number, RelicName: string? }
)
	local offer = self._pending[player.UserId]
	if not offer or typeof(payload) ~= "table" or payload.OfferId ~= offer.id then
		return
	end

	local relicName = payload.RelicName
	if relicName == nil then
		-- Skip is ALWAYS allowed: it grants nothing, so the cap cannot be
		-- exceeded by it -- and a capped player needs a way to clear the
		-- hand and open the gate.
		self:_resolve(offer, nil, "Skipped")
		return
	end

	if typeof(relicName) ~= "string" or not table.find(offer.relics, relicName) or not RelicData[relicName] then
		return
	end

	-- A dead player collects nothing; the hand stays open (their revive
	-- may land before the deadline).
	if LifeService:IsDeathState(player) then
		RelicNetwork.RelicOfferResolved.Fire(player, { OfferId = offer.id, RelicName = nil, Outcome = "Refused" })
		return
	end

	-- Relic cap: refuse WITHOUT closing the hand, so a capped player can
	-- still Skip (or open a slot and come back before the deadline).
	if not RelicService:CanAcceptRelic(player, relicName) then
		self:_refuseAtCap(player)
		RelicNetwork.RelicOfferResolved.Fire(player, { OfferId = offer.id, RelicName = nil, Outcome = "Refused" })
		return
	end

	self:_resolve(offer, relicName, "Taken")
end

-- Voids every open and queued offer: the floor they were dealt on is
-- gone. The clients close their cards; nothing is granted or marked.
function RelicOfferService._cancelAll(self: typeof(RelicOfferService))
	for userId, offer in self._pending do
		self._pending[userId] = nil
		local player = Players:GetPlayerByUserId(userId)
		if player then
			RelicNetwork.RelicOfferResolved.Fire(player, { OfferId = offer.id, RelicName = nil, Outcome = "Cancelled" })
		end
	end
	table.clear(self._queued)
end

--[ Public ]--

-- Deals `relicNames` (already rolled by the caller) to `player`. Returns
-- false when nothing could be dealt (no valid names); the caller decides
-- what an empty hand means. Unknown names are dropped, not dealt.
function RelicOfferService.Offer(
	self: typeof(RelicOfferService),
	player: Player,
	relicNames: { string },
	source: string
): boolean
	local relics = {}
	for _, relicName in relicNames do
		if RelicData[relicName] and not table.find(relics, relicName) then
			table.insert(relics, relicName)
		end
	end
	if #relics == 0 or not player.Parent then
		return false
	end

	local offer: Offer = {
		id = self._nextId,
		player = player,
		relics = relics,
		source = source,
		expiresAt = 0,
		canSkip = false,
	}
	self._nextId += 1

	if self._pending[player.UserId] then
		local queue = self._queued[player.UserId]
		if not queue then
			queue = {}
			self._queued[player.UserId] = queue
		end
		table.insert(queue, offer)
		return true
	end

	self:_deal(offer)
	return true
end

-- True while this player has a hand on screen.
function RelicOfferService.HasOpenOffer(self: typeof(RelicOfferService), player: Player): boolean
	return self._pending[player.UserId] ~= nil
end

--[ Lifecycle ]--

function RelicOfferService.Start(self: typeof(RelicOfferService))
	RelicNetwork.RelicOfferChosen.On(function(player: Player, payload)
		self:_onChosen(player, payload)
	end)

	-- Leaving drops the hand with the player: a deferred auto-pick finds
	-- no pending entry and does nothing.
	PlayerEventService.OnPlayerRemoved:Connect(function(player: Player)
		self._pending[player.UserId] = nil
		self._queued[player.UserId] = nil
	end)

	local dungeonService = Blitz.OptionalService("DungeonService")
	if dungeonService then
		dungeonService.Signals.OnFloorTeardown:Connect(function()
			self:_cancelAll()
		end)
	end
end

return RelicOfferService
