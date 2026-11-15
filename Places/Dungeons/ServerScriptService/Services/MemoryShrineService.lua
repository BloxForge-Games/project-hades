--!strict
--[[
	Module: Services/MemoryShrineService.lua
	Description:
	The Memory Shrine (prefab MemoryShrine, 2026-11-13; Slay the Spire's
	Match and Keep): an altar under the room's Interactables ("Altar").
	Talking to it (dialogue MemoryShrine) offers the trial or a skip; the
	trial opens the player's OWN board (MemoryShrineController), once.

	A board is 5 pairs, 10 cards in rows of 5: RELIC_PAIRS relics the
	player could take (rolled the vending machines' way), one Coins pair,
	and NEGATIVE_PAIRS bad pairs drawn from NEGATIVE_KINDS (lose Max HP,
	lose Max Mana, lose a random relic, a forced Cursed relic). The client
	shows every face, turns them down, then plays the SHUFFLE the server
	rolled (Order) slowly enough to follow, and the player flips two at a
	time. ONE CHANCE (2026-11-14): a MATCH keeps the pair's effect at once
	(good or bad) and the board carries on; the first MISS ends it. The
	board also ends when every pair is found; the player then counts toward
	the room door's early open. (The wire field MissesLeft is 1 while the
	board is live, 0 once it has ended.)

	THE SERVER JUDGES: it holds each board in its FINAL (shuffled) order,
	remembers the player's first pick and decides match / miss. The
	client is sent the reveal order and the shuffle (it must animate
	both); it only ever asks to flip a slot.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local DungeonService = require(ServerScriptService.Services.DungeonService)
local EventService = require(ServerScriptService.Services.EventService)
local DropService = require(ServerScriptService.Services.DropService)
local LifeService = require(ServerScriptService.Services.LifeService)
local RelicService = require(ServerScriptService.Services.RelicService)
local TextIndicatorService = require(ServerScriptService.Submodules.Core.Source.Services.TextIndicatorService)
local PlayerStatsService = require(ServerScriptService.Submodules.Core.Source.Services.PlayerStatsService)
local DungeonNetwork = require(ServerScriptService.Submodules.Core.Source.Network.Dungeon)
local DifficultyData = require(ReplicatedStorage.Submodules.Core.Shared.Data.DifficultyData)
local RelicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicData)
local DropTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.DropTypes)
local ItemRarity = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ItemRarity)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)

local ALTAR_NAME = "Altar"
local PROMPT_ACTION = "Interact"
local PROMPT_OBJECT = "Mysterious Altar"
local MACHINE_TEMPLATE_PATH = { "VendingMachines", "Default" }
local RELIC_PAIRS = 2
local NEGATIVE_PAIRS = 2
-- A max-stat card's cost, a share of the stat for the run
-- (PlayerStatsService PayMaxStat).
local LOSE_MAX_SHARE = 0.10
local COIN_SHARE = 0.08
local COIN_PICKUPS = 5
local INTERACT_RANGE = 30
local KIND_RELIC = "Relic"
local KIND_COINS = "Coins"
local KIND_CURSED = "Cursed"
local KIND_LOSE_MAX_HP = "LoseMaxHP"
local KIND_LOSE_MAX_MANA = "LoseMaxMana"
local KIND_LOSE_RELIC = "LoseRelic"
local NEGATIVE_KINDS = { KIND_LOSE_MAX_HP, KIND_LOSE_MAX_MANA, KIND_LOSE_RELIC, KIND_CURSED }
local BAD_COLOR = Color3.fromRGB(255, 92, 92)
local DIALOGUE_GRAPH = "MemoryShrine"
local GOOD_COLOR = Color3.fromRGB(85, 255, 127)
local CURSED_COLOR = Color3.fromRGB(201, 134, 255)

type Card = { kind: string, relic: string? }
type Board = {
	cards: { Card },
	matched: { [number]: boolean },
	first: number?,
	finished: boolean,
	-- The reveal order (as first shown) and the shuffle into the final
	-- order: cards[slot] = reveal[order[slot]].
	reveal: { Card },
	order: { number },
	shown: boolean,
}
type ShrineState = {
	room: DungeonService.Room,
	altar: Model,
	boards: { [number]: Board },
}

local MemoryShrineService = {
	Name = "MemoryShrineService",
	Dependencies = {
		DungeonService,
		EventService,
		DropService,
		LifeService,
		RelicService,
		TextIndicatorService,
		PlayerStatsService,
	} :: { any },

	-- [altar model] = the shrine's state for this floor.
	_byAltar = {} :: { [Instance]: ShrineState },
}

local function machinePrompt(): ProximityPrompt?
	local node: Instance? = ReplicatedStorage:FindFirstChild("GameAssets")
	for _, childName in MACHINE_TEMPLATE_PATH do
		node = node and node:FindFirstChild(childName)
	end
	local primary = if node and node:IsA("Model") then node.PrimaryPart else nil
	local attachment = primary and primary:FindFirstChild("Attachment")
	local prompt = attachment and attachment:FindFirstChildWhichIsA("ProximityPrompt")
	return if prompt then prompt else nil
end

local function graftPrompt(part: BasePart): ProximityPrompt
	local attachment: Instance? = part:FindFirstChild("Attachment")
	if not attachment then
		local made = Instance.new("Attachment")
		made.Parent = part
		attachment = made
	end
	local template = machinePrompt()
	local prompt = if template then template:Clone() else Instance.new("ProximityPrompt")
	prompt.ActionText = PROMPT_ACTION
	prompt.ObjectText = PROMPT_OBJECT
	prompt.RequiresLineOfSight = false
	prompt.Enabled = true
	prompt.Parent = attachment
	return prompt
end

local function altarPart(altar: Model): BasePart?
	return altar.PrimaryPart or altar:FindFirstChildWhichIsA("BasePart", true)
end

local function indicate(player: Player, text: string, color: Color3)
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		TextIndicatorService:ShowIndicator(player, root, text, color, true)
	end
end

local function shuffle(list: { any })
	for index = #list, 2, -1 do
		local swap = math.random(1, index)
		list[index], list[swap] = list[swap], list[index]
	end
end

-- Up to `count` distinct relics `player` could take, rolled the vending
-- machines' way.
local function rollRelics(player: Player, count: number): { string }
	local pool = RelicService:GetPlayerAvailableRelics(player)
	local picked = {}
	for _ = 1, count do
		local relicName = RelicService:RollRandomRelicFromPool(pool, nil, nil, player)
		if not relicName then
			break
		end
		table.insert(picked, relicName)
		local at = table.find(pool, relicName)
		if at then
			table.remove(pool, at)
		end
	end
	return picked
end

-- A random live Cursed relic `player` neither holds nor has locked.
local function rollCursed(player: Player): string?
	local candidates = {}
	for relicName, data in RelicData do
		if
			data.rarity == ItemRarity.Cursed
			and not data.retired
			and RelicService:GetSpecificRelicRegistry(player, relicName) == 0
			and RelicService:IsRelicUnlocked(player, relicName)
		then
			table.insert(candidates, relicName)
		end
	end
	return if #candidates > 0 then candidates[math.random(1, #candidates)] else nil
end

function MemoryShrineService._newBoard(_self: typeof(MemoryShrineService), player: Player): Board
	local reveal: { Card } = {}
	local function pair(card: Card)
		table.insert(reveal, card)
		table.insert(reveal, { kind = card.kind, relic = card.relic })
	end
	for _, relicName in rollRelics(player, RELIC_PAIRS) do
		pair({ kind = KIND_RELIC, relic = relicName })
	end
	pair({ kind = KIND_COINS })
	-- NEGATIVE_PAIRS distinct bad kinds (a Cursed pair only when there is a
	-- Cursed relic to force).
	local kinds = table.clone(NEGATIVE_KINDS)
	shuffle(kinds)
	local placed = 0
	for _, kind in kinds do
		if placed >= NEGATIVE_PAIRS then
			break
		end
		if kind == KIND_CURSED then
			local cursed = rollCursed(player)
			if cursed then
				pair({ kind = KIND_CURSED, relic = cursed })
				placed += 1
			end
		else
			pair({ kind = kind })
			placed += 1
		end
	end
	-- Pairs sit side by side in the reveal (the faces read as a set); the
	-- shuffle is what scatters them.
	local order = {}
	for index in reveal do
		order[index] = index
	end
	shuffle(order)
	local cards = {}
	for slot, index in order do
		cards[slot] = reveal[index]
	end
	return {
		cards = cards,
		matched = {},
		first = nil,
		finished = false,
		reveal = reveal,
		order = order,
		shown = false,
	}
end

function MemoryShrineService._state(self: typeof(MemoryShrineService), player: Player, altar: Instance?): ShrineState?
	if typeof(altar) ~= "Instance" then
		return nil
	end
	local state = self._byAltar[altar]
	if not state then
		return nil
	end
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	local part = altarPart(state.altar)
	if not root or not root:IsA("BasePart") or not part then
		return nil
	end
	if (root.Position - part.Position).Magnitude > INTERACT_RANGE then
		return nil
	end
	return state
end

-- The prize of a found pair.
function MemoryShrineService._pay(_self: typeof(MemoryShrineService), state: ShrineState, player: Player, card: Card)
	if card.kind == KIND_COINS then
		local part = altarPart(state.altar)
		local coins = math.max(math.round(DifficultyData.RunCoins(DungeonService:GetDifficultyScale()) * COIN_SHARE), 1)
		if part then
			local count = math.min(COIN_PICKUPS, coins)
			local each = coins // count
			local extra = coins - each * count
			if extra > 0 then
				DropService.OnDropRequested:Fire(
					part,
					DropTypes.Coins,
					extra,
					extra,
					each + 1,
					each + 1,
					false,
					player.UserId,
					true
				)
			end
			DropService.OnDropRequested:Fire(
				part,
				DropTypes.Coins,
				count - extra,
				count - extra,
				each,
				each,
				false,
				player.UserId,
				true
			)
		end
		indicate(player, "Gold!", GOOD_COLOR)
	elseif card.kind == KIND_LOSE_MAX_HP or card.kind == KIND_LOSE_MAX_MANA then
		local stat = if card.kind == KIND_LOSE_MAX_HP then "Health" else "Mana"
		PlayerStatsService:PayMaxStat(player, stat, LOSE_MAX_SHARE)
		indicate(
			player,
			("-%d%% Max %s"):format(math.round(LOSE_MAX_SHARE * 100), if stat == "Health" then "HP" else "Mana"),
			BAD_COLOR
		)
	elseif card.kind == KIND_LOSE_RELIC then
		local held = {}
		for relicName, count in RelicService:GetRelicsRegistry(player) do
			local data = RelicData[relicName]
			if count > 0 and data and data.rarity ~= ItemRarity.Cursed then
				table.insert(held, relicName)
			end
		end
		if #held > 0 then
			local lost = held[math.random(1, #held)]
			RelicService:RemoveRelicsRegistry(player, lost, 1)
			RelicService:PlayRelicRemovedFX(player)
			indicate(player, ("Lost %s!"):format(lost), BAD_COLOR)
		end
	elseif card.relic then
		if RelicService:AddRelicsRegistry(player, card.relic, 1) then
			local color = if card.kind == KIND_CURSED then CURSED_COLOR else GOOD_COLOR
			indicate(player, ("Gained %s!"):format(card.relic), color)
		end
	end
end

function MemoryShrineService._finish(
	_self: typeof(MemoryShrineService),
	state: ShrineState,
	player: Player,
	board: Board
)
	if board.finished then
		return
	end
	board.finished = true
	board.first = nil
	EventService:MarkInteracted(player, state.room.id)
end

local function cardRow(card: Card, matched: boolean): any
	return { Kind = card.kind, Relic = card.relic, Matched = matched }
end

function MemoryShrineService._onStart(self: typeof(MemoryShrineService), player: Player, altar: Instance?): any
	local state = self:_state(player, altar)
	if not state or LifeService:IsDeathState(player) then
		return { Status = "invalid", Cards = {}, Order = {}, Fresh = false, MissesLeft = 0 }
	end
	local existing = state.boards[player.UserId]
	if existing and existing.finished then
		return { Status = "done", Cards = {}, Order = {}, Fresh = false, MissesLeft = 0 }
	end
	local board: Board = existing or self:_newBoard(player)
	state.boards[player.UserId] = board
	board.first = nil
	local cards, order = {}, {}
	if not board.shown then
		-- First showing: the reveal order and the shuffle into the board.
		board.shown = true
		for index, card in board.reveal do
			cards[index] = cardRow(card, false)
		end
		order = table.clone(board.order)
		return { Status = "ok", Cards = cards, Order = order, Fresh = true, MissesLeft = 1 }
	end
	-- A re-opened board: already in its final order, nothing to shuffle.
	for slot, card in board.cards do
		cards[slot] = cardRow(card, board.matched[slot] == true)
		order[slot] = slot
	end
	return { Status = "ok", Cards = cards, Order = order, Fresh = false, MissesLeft = 1 }
end

function MemoryShrineService._onFlip(self: typeof(MemoryShrineService), player: Player, request: any): any
	local function reply(result: string, board: Board?): any
		return {
			Result = result,
			MissesLeft = if board and not board.finished then 1 else 0,
			Finished = if board then board.finished else true,
		}
	end
	if typeof(request) ~= "table" then
		return reply("invalid", nil)
	end
	local state = self:_state(player, request.Shrine)
	local board = state and state.boards[player.UserId]
	if not state or not board or board.finished then
		return reply("invalid", board)
	end
	local index = request.Index
	if typeof(index) ~= "number" or not board.cards[index] or board.matched[index] or board.first == index then
		return reply("invalid", board)
	end
	if not board.first then
		board.first = index
		return reply("first", board)
	end

	local first = board.first :: number
	board.first = nil
	local a, b = board.cards[first], board.cards[index]
	local result
	if a.kind == b.kind and a.relic == b.relic then
		board.matched[first] = true
		board.matched[index] = true
		self:_pay(state, player, a)
		result = "match"
	else
		result = "miss"
	end

	local remaining = 0
	for cardIndex in board.cards do
		if not board.matched[cardIndex] then
			remaining += 1
		end
	end
	if remaining == 0 or result == "miss" then
		self:_finish(state, player, board)
	end
	return reply(result, board)
end

-- Called by EventService as it wires the floor's MemoryShrine room.
function MemoryShrineService.RegisterRoom(self: typeof(MemoryShrineService), room: DungeonService.Room)
	local interactables = room.model and room.model:FindFirstChild("Interactables")
	local altar = interactables and interactables:FindFirstChild(ALTAR_NAME)
	if not altar or not altar:IsA("Model") then
		warn("[MemoryShrineService] MemoryShrine room has no Interactables.Altar model")
		return
	end
	local part = altarPart(altar)
	if not part then
		warn("[MemoryShrineService] Altar has no parts")
		return
	end
	-- Talking to the altar offers the trial or a skip (dialogue
	-- MemoryShrine); its "Skip" counts toward the door like any event's.
	altar:SetAttribute("DialogueGraph", DIALOGUE_GRAPH)
	-- The NPC component labels the prompt with the model's name.
	altar.Name = PROMPT_OBJECT
	CollectionService:AddTag(altar, TagList.NPC)
	CollectionService:AddTag(altar, TagList.MemoryShrine)
	EventService:RegisterEventModel(altar, "MemoryShrine", room)
	graftPrompt(part)
	self._byAltar[altar] = { room = room, altar = altar, boards = {} }
end

function MemoryShrineService.Start(self: typeof(MemoryShrineService))
	DungeonNetwork.MemoryShrineStart.On(function(player: Player, altar: Instance?)
		return self:_onStart(player, altar)
	end)
	DungeonNetwork.MemoryShrineFlip.On(function(player: Player, request)
		return self:_onFlip(player, request)
	end)
	DungeonService.Signals.OnFloorTeardown:Connect(function()
		table.clear(self._byAltar)
	end)
end

return MemoryShrineService
