--!strict
--[[
	Module: Services/WheelOfFortuneService.lua
	Description:
	The Wheel of Fortune (prefab WheelOfFortune, 2026-11-13): a wheel on a
	stand under the room's Interactables ("Wheel", its face part
	"WheelFace"). Every player gets ONE free spin; one spin turns at a
	time (a player who asks while it turns is told to wait).

	A spin is rolled HERE (WheelOfFortuneData.Roll), then published on the
	wheel model as attributes every client animates from
	(Components/WheelOfFortune): SpinId (bumped per spin), SpinSlice,
	SpinRotation (the landing rotation, degrees), SpinStartedAt (server
	time) and SpinnerName. The outcome lands once the spin has turned
	(SpinSeconds), so the result never shows before the wheel stops.

	Outcomes (WheelOfFortuneData.Slices): Gold / Crystals burst
	as the spinner's own pickups, Heal heals, Relic and JACKPOT deal a card
	hand (RelicOfferService), and the three bad slices bite: -25% HP takes
	that share of current health (never lethal), Ambush springs a
	corrupted pack around the wheel while the door is held shut, and Lose
	Relic takes one random non-Cursed relic the spinner holds.

	THE CLOWN (2026-11-13): Giggles, the NPC inside the Wheel model,
	is how a player spins: his dialogue (WheelClown) asks the server
	(DungeonNetwork.SpinWheel) and walking away counts toward the door. A
	spin counts the spinner toward the door's early open
	(EventService:MarkInteracted) once its outcome has landed.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local DungeonService = require(ServerScriptService.Services.DungeonService)
local EventService = require(ServerScriptService.Services.EventService)
local MobSpawnService = require(ServerScriptService.Services.MobSpawnService)
local DropService = require(ServerScriptService.Services.DropService)
local LifeService = require(ServerScriptService.Services.LifeService)
local RelicService = require(ServerScriptService.Services.RelicService)
local RelicOfferService = require(ServerScriptService.Services.RelicOfferService)
local PlayerStatsService = require(ServerScriptService.Submodules.Core.Source.Services.PlayerStatsService)
local TextIndicatorService = require(ServerScriptService.Submodules.Core.Source.Services.TextIndicatorService)
local DungeonNetwork = require(ServerScriptService.Submodules.Core.Source.Network.Dungeon)
local UserNotificationService = require(ServerScriptService.Submodules.Core.Source.Services.UserNotificationService)
local NotificationColors = require(ReplicatedStorage.Submodules.Core.Shared.Data.NotificationColors)
local DifficultyData = require(ReplicatedStorage.Submodules.Core.Shared.Data.DifficultyData)
local WheelOfFortuneData = require(ReplicatedStorage.Submodules.Core.Shared.Data.WheelOfFortuneData)
local DropTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.DropTypes)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local Log = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Log)

local WHEEL_NAME = "Wheel"
-- DEBUG (testing only, ship with nil): every spin lands on this slice id
-- ("Ambush", "Relic", ...) so an outcome can be tested on demand.
local DEBUG_FORCE_SLICE: string? = nil
-- The clown in the wheel model: talking to him is the spin.
local CLOWN_GRAPH = "WheelClown"
local CLOWN_NAME = "Giggles the Clown"
local INTERACT_RANGE = 30
local OFFER_SOURCE = "Wheel"
local RELIC_HAND_SIZE = 3
local COIN_PICKUPS = 5
local CRYSTAL_PICKUPS = 3
local HOLD_TEXT_AMBUSH = "Survive the Ambush!"
-- A pause after the wheel stops before the outcome lands, so the result
-- reads after the slice under the pointer, not on top of it.
local LAND_BEAT_SECONDS = 0.5
local WAIT_COLOR = Color3.fromRGB(255, 255, 255)

type Room = DungeonService.Room
type WheelState = {
	room: Room,
	wheel: Model,
	spun: { [number]: boolean },
	spinning: boolean,
	spinId: number,
	generation: number,
	ambush: boolean,
}

local WheelOfFortuneService = {
	Name = "WheelOfFortuneService",
	Dependencies = {
		DungeonService,
		EventService,
		MobSpawnService,
		DropService,
		LifeService,
		RelicService,
		RelicOfferService,
		PlayerStatsService,
		TextIndicatorService,
		UserNotificationService,
	} :: { any },

	_byRoomId = {} :: { [number]: WheelState },
	-- [clown model] = his wheel's state.
	_byClown = {} :: { [Instance]: WheelState },
}

local function notifyAll(title: string, text: string, titleColor: Color3)
	UserNotificationService:RequestAllNotification({
		titleText = title,
		titleTextFont = Enum.Font.SourceSansBold,
		titleTextColor3 = titleColor,
		titleTextTransparency = 0,

		text = text,
		textFont = Enum.Font.SourceSansBold,
		textColor3 = Color3.fromRGB(255, 255, 255),
		textTransparency = 0,
	})
end

local function indicate(player: Player, text: string, color: Color3)
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		TextIndicatorService:ShowIndicator(player, root, text, color, true)
	end
end

-- Splits `total` into at most `pickups` whole pickups owned by `player`.
local function burst(origin: BasePart, dropType: string, total: number, pickups: number, player: Player)
	if total <= 0 then
		return
	end
	local count = math.min(pickups, total)
	local each = total // count
	local extra = total - each * count
	if extra > 0 then
		DropService.OnDropRequested:Fire(origin, dropType, extra, extra, each + 1, each + 1, false, player.UserId, true)
	end
	DropService.OnDropRequested:Fire(
		origin,
		dropType,
		count - extra,
		count - extra,
		each,
		each,
		false,
		player.UserId,
		true
	)
end

local function livingCount(): number
	local count = 0
	for _, player in Players:GetPlayers() do
		if not LifeService:IsDeathState(player) then
			count += 1
		end
	end
	return count
end

-- Up to RELIC_HAND_SIZE distinct relics the player can take, rolled the
-- vending machines' way; `weights` narrows the rarities.
local function rollHand(player: Player, weights: { [string]: number }?): { string }
	local pool = RelicService:GetPlayerAvailableRelics(player)
	local hand = {}
	for _ = 1, RELIC_HAND_SIZE do
		local relicName = RelicService:RollRandomRelicFromPool(pool, weights, nil, player)
		if not relicName then
			break
		end
		table.insert(hand, relicName)
		local at = table.find(pool, relicName)
		if at then
			table.remove(pool, at)
		end
	end
	return hand
end

local function wheelPart(wheel: Model): BasePart?
	local face = wheel:FindFirstChild("WheelFace")
	if face and face:IsA("BasePart") then
		return face
	end
	return wheel.PrimaryPart or wheel:FindFirstChildWhichIsA("BasePart", true)
end

function WheelOfFortuneService._ambush(_self: typeof(WheelOfFortuneService), state: WheelState)
	local origin = wheelPart(state.wheel)
	if not origin then
		return
	end
	local room = state.room
	local count = math.min(
		WheelOfFortuneData.AmbushBaseMobs + WheelOfFortuneData.AmbushMobsPerPlayer * livingCount(),
		WheelOfFortuneData.AmbushMaxMobs
	)
	-- On the floor in front of the wheel, not inside the stand.
	local position = origin.Position + origin.CFrame.LookVector * 8
	local spawned = MobSpawnService:SpawnMobsAt(room, position, count, true)
	if #spawned == 0 then
		return
	end
	state.ambush = true
	DungeonService:SuspendEventHold(room.id, HOLD_TEXT_AMBUSH)
	local generation = state.generation
	local connection: RBXScriptConnection? = nil
	connection = MobSpawnService.OnMobDespawn:Connect(function()
		if state.generation ~= generation then
			if connection then
				connection:Disconnect()
			end
			return
		end
		if #MobSpawnService:GetMobsInRoom(room) == 0 then
			if connection then
				connection:Disconnect()
			end
			state.ambush = false
			DungeonService:ReleaseEventHold(room.id)
			notifyAll("Ambush Survived", "The wheel goes quiet.", NotificationColors.Success)
		end
	end) :: any
	Log.debug(("[WheelOfFortuneService] Ambush: %d corrupted mobs"):format(#spawned))
end

-- Pays slice `index` to `player`.
function WheelOfFortuneService._apply(
	self: typeof(WheelOfFortuneService),
	state: WheelState,
	player: Player,
	index: number
)
	local slice = WheelOfFortuneData.Slices[index]
	local origin = wheelPart(state.wheel)
	local tier = DungeonService:GetDifficultyScale()
	local id = slice.id
	if id == "Gold" or id == "Jackpot" then
		local coins = math.max(math.round(DifficultyData.RunCoins(tier) * (slice.share or 0)), 1)
		if origin then
			burst(origin, DropTypes.Coins, coins, COIN_PICKUPS, player)
		end
	end
	-- The JACKPOT is pure currency (2026-11-13): its share of the run's
	-- coins (above) AND of the run's crystals.
	if id == "Crystals" or id == "Jackpot" then
		local crystals = math.max(math.round((tier.chestCrystals or 0) * (slice.share or 0)), 1)
		if origin then
			burst(origin, DropTypes.ArcaneCrystals, crystals, CRYSTAL_PICKUPS, player)
		end
	elseif id == "Heal" then
		local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			PlayerStatsService:ApplyHealing(player, humanoid.MaxHealth * (slice.share or 0))
		end
	elseif id == "Relic" then
		local hand = rollHand(player, nil)
		if #hand > 0 then
			RelicOfferService:Offer(player, hand, OFFER_SOURCE)
		end
	elseif id == "Bleed" then
		local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health > 1 then
			-- Raw and never lethal, like the events' other health costs.
			humanoid.Health = math.max(1, humanoid.Health - humanoid.Health * (slice.share or 0))
		end
	elseif id == "Ambush" then
		self:_ambush(state)
	end

	-- No text indicator for the result: the clown calls it (2026-11-13).
	notifyAll(
		"Wheel of Fortune",
		("%s spun %s!"):format(player.Name, slice.label),
		if slice.bad then NotificationColors.Error else NotificationColors.Success
	)
end

function WheelOfFortuneService._onSpin(self: typeof(WheelOfFortuneService), state: WheelState, player: Player): string
	if LifeService:IsDeathState(player) then
		return "invalid"
	end
	if state.spun[player.UserId] then
		return "spun"
	end
	if state.spinning then
		indicate(player, "Wait for the wheel...", WAIT_COLOR)
		return "busy"
	end
	state.spun[player.UserId] = true
	-- Read by his dialogue (WheelClown): a second talk goes straight to
	-- "one spin each".
	state.wheel:SetAttribute("Spun_" .. player.UserId, true)
	state.spinning = true
	state.spinId += 1

	local index = (DEBUG_FORCE_SLICE and WheelOfFortuneData.IndexOf(DEBUG_FORCE_SLICE)) or WheelOfFortuneData.Roll()
	local step = 360 / #WheelOfFortuneData.Slices
	local landing =
		WheelOfFortuneData.LandingRotation(index, WheelOfFortuneData.SpinTurns, (math.random() - 0.5) * step)
	local wheel = state.wheel
	wheel:SetAttribute("SpinSlice", index)
	wheel:SetAttribute("SpinRotation", landing)
	wheel:SetAttribute("SpinStartedAt", workspace:GetServerTimeNow())
	wheel:SetAttribute("SpinnerName", player.Name)
	-- Last: clients key their animation off this edge.
	wheel:SetAttribute("SpinId", state.spinId)

	local generation = state.generation
	task.delay(WheelOfFortuneData.SpinSeconds + LAND_BEAT_SECONDS, function()
		if state.generation ~= generation then
			return
		end
		state.spinning = false
		if player.Parent then
			self:_apply(state, player, index)
			-- Counted toward the door's early open only once the outcome
			-- has landed: an Ambush has held the door by then, so the room
			-- cannot open under a fight that is about to start.
			EventService:MarkInteracted(player, state.room.id)
		end
	end)
	return "ok"
end

-- The clown's "Spin the wheel!" (DungeonNetwork.SpinWheel): the player
-- must be at his room's clown.
function WheelOfFortuneService._onSpinRequest(
	self: typeof(WheelOfFortuneService),
	player: Player,
	clown: Instance?
): string
	if typeof(clown) ~= "Instance" then
		return "invalid"
	end
	local state = self._byClown[clown]
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if not state or not clown:IsA("Model") or not root or not root:IsA("BasePart") then
		return "invalid"
	end
	if (root.Position - clown:GetPivot().Position).Magnitude > INTERACT_RANGE then
		return "invalid"
	end
	return self:_onSpin(state, player)
end

-- Called by EventService as it wires the floor's WheelOfFortune room.
function WheelOfFortuneService.RegisterRoom(self: typeof(WheelOfFortuneService), room: Room)
	local interactables = room.model and room.model:FindFirstChild("Interactables")
	local wheel = interactables and interactables:FindFirstChild(WHEEL_NAME)
	if not wheel or not wheel:IsA("Model") then
		warn("[WheelOfFortuneService] WheelOfFortune room has no Interactables.Wheel model")
		return
	end
	local state: WheelState = {
		room = room,
		wheel = wheel,
		spun = {},
		spinning = false,
		spinId = 0,
		generation = 0,
		ambush = false,
	}
	-- The wheel faces each viewer's own camera (Components/WheelOfFortune).
	CollectionService:AddTag(wheel, TagList.WheelOfFortune)
	-- Giggles: his dialogue spins (WheelClown), and his room's door counts
	-- him like any event model.
	-- He stands INSIDE the wheel model, beside its face, so a viewer's
	-- camera-facing turn carries him along (Components/WheelOfFortune).
	local clown = wheel:FindFirstChild(CLOWN_NAME)
	if clown then
		clown:SetAttribute("DialogueGraph", CLOWN_GRAPH)
		CollectionService:AddTag(clown, TagList.NPC)
		EventService:RegisterEventModel(clown, "WheelOfFortune", room)
		self._byClown[clown] = state
	else
		warn("[WheelOfFortuneService] Wheel has no " .. CLOWN_NAME .. " — nobody can spin")
	end
	self._byRoomId[room.id] = state
end

function WheelOfFortuneService.ResetForFloor(self: typeof(WheelOfFortuneService))
	for _, state in self._byRoomId do
		state.generation += 1
	end
	table.clear(self._byRoomId)
	table.clear(self._byClown)
end

function WheelOfFortuneService.Start(self: typeof(WheelOfFortuneService))
	DungeonNetwork.SpinWheel.On(function(player: Player, clown: Instance?)
		return self:_onSpinRequest(player, clown)
	end)
	DungeonService.Signals.OnFloorTeardown:Connect(function()
		self:ResetForFloor()
	end)
end

return WheelOfFortuneService
