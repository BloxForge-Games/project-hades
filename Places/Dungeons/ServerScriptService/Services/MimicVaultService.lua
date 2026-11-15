--!strict
--[[
	Module: Services/MimicVaultService.lua
	Description:
	The Mimic Vault (prefab MimicVault, 2026-11-13): three chests under the
	room's Interactables (Chest1..Chest3, the Event Chest model), shared by
	the party. Any player may open any chest, in any order. Two hold loot;
	ONE, rolled when the room is wired, is a MIMIC -- so opening the next
	chest is always the gamble.

	  * LOOT CHEST: its lid swings open (client, Components/MimicVaultChest
	    off the Opened attribute) and every living player gets their own
	    burst of Coins and Arcane Crystals (owner-locked pickups):
	    LOOT_COIN_SHARE of the tier's run coins and LOOT_CRYSTAL_SHARE of
	    its chest crystals each.
	  * THE MIMIC (a PUNISHMENT, it pays nothing): the chest shakes and
	    bursts, and a corrupted pack of the dungeon's own mobs pours out
	    (MIMIC_BASE_MOBS + MIMIC_MOBS_PER_PLAYER each). The exit door is
	    held shut until the pack is dead, then the room's hold resumes.

	THE SEAL: the vault SEALS (every unopened chest goes dead) the moment
	any player steps past its ExitGate (_watchExit), or enters a later
	room. Nobody can wake a mimic behind a
	party that has already moved on, and a mimic fight holds the door, so
	nobody can leave mid-fight either. Opening a chest counts the opener
	toward the door's early open (EventService:MarkInteracted), so a solo
	player can open the door with one chest and still gamble on the rest
	before walking through.

	The prompts are the vending machine's own (grafted, so the custom
	prompt renderer draws them); the server owns Triggered, so nothing here
	needs a remote. EventService registers the room as it wires the floor;
	OnFloorTeardown drops every state.

	GREYBOX: the mimic has no model of its own yet -- the pack bursting
	out of the chest is the stand-in.
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
local UserNotificationService = require(ServerScriptService.Submodules.Core.Source.Services.UserNotificationService)
local NotificationColors = require(ReplicatedStorage.Submodules.Core.Shared.Data.NotificationColors)
local DifficultyData = require(ReplicatedStorage.Submodules.Core.Shared.Data.DifficultyData)
local DropTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.DropTypes)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local Log = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Log)

-- The chests under Interactables, by name.
local CHEST_NAMES = { "Chest1", "Chest2", "Chest3" }
local PROMPT_ACTION = "Open"
local PROMPT_OBJECT = "Mysterious Chest"
-- The prompt is the vending machine's (its Style attribute is what the
-- custom prompt renderer keys off), grafted like the encounter chests'.
local MACHINE_TEMPLATE_PATH = { "VendingMachines", "Default" }
-- The client swings the lid off this (Components/MimicVaultChest).
local OPENED_ATTRIBUTE = "Opened"
-- A loot chest's take, per living player: shares of the tier's run coins
-- (DifficultyData.RunCoins) and of its chest crystals.
local LOOT_COIN_SHARE = 0.05
local LOOT_CRYSTAL_SHARE = 0.05
local LOOT_COIN_PICKUPS = 4
local LOOT_CRYSTAL_PICKUPS = 2
-- The mimic: a shake, then the burst.
local SHAKE_SECONDS = 0.9
local SHAKE_DEGREES = 8
local MIMIC_BASE_MOBS = 4
local MIMIC_MOBS_PER_PLAYER = 1
local MIMIC_MAX_MOBS = 10
local HOLD_TEXT_FIGHT = "Defeat the Mimic!"
-- The seal's exit check (_watchExit): how far past the ExitGate counts as
-- out, and how often it looks.
local EXIT_GATE_NAME = "ExitGate"
local EXIT_SEAL_STUDS = 3
local EXIT_POLL_SECONDS = 0.5

type Room = DungeonService.Room
type VaultState = {
	room: Room,
	mimicIndex: number,
	opened: { [number]: boolean },
	prompts: { [number]: ProximityPrompt },
	sealed: boolean,
	status: string, -- "idle" | "fight" | "done"
	generation: number,
}

local MimicVaultService = {
	Name = "MimicVaultService",
	Dependencies = {
		DungeonService,
		EventService,
		MobSpawnService,
		DropService,
		LifeService,
		UserNotificationService,
	} :: { any },

	-- [roomId] = the vault's state for this floor.
	_byRoomId = {} :: { [number]: VaultState },
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

local function chestPart(chest: Model): BasePart?
	return chest.PrimaryPart or chest:FindFirstChildWhichIsA("BasePart", true)
end

-- The vending machine template's prompt, or nil.
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

-- Grafts the machine's prompt into an Attachment on `part`.
local function graftPrompt(part: BasePart): ProximityPrompt
	local attachment: Instance? = part:FindFirstChild("Attachment")
	if not attachment then
		local made = Instance.new("Attachment")
		made.Parent = part
		attachment = made
	end
	local template = machinePrompt()
	local prompt = if template then template:Clone() else Instance.new("ProximityPrompt")
	if not template then
		warn("[MimicVaultService] No vending machine prompt to graft — using a default prompt")
	end
	prompt.ActionText = PROMPT_ACTION
	prompt.ObjectText = PROMPT_OBJECT
	prompt.RequiresLineOfSight = false
	prompt.Enabled = true
	prompt.Parent = attachment
	return prompt
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

local function livingPlayers(): { Player }
	local living = {}
	for _, player in Players:GetPlayers() do
		if not LifeService:IsDeathState(player) then
			table.insert(living, player)
		end
	end
	return living
end

-- The chest vanishes (the mimic is out).
local function hideChest(chest: Model)
	for _, part in chest:GetDescendants() do
		if part:IsA("BasePart") then
			part.Transparency = 1
			part.CanCollide = false
		elseif part:IsA("Decal") or part:IsA("Texture") then
			(part :: any).Transparency = 1
		end
	end
end

function MimicVaultService._payLoot(_self: typeof(MimicVaultService), chest: Model)
	chest:SetAttribute(OPENED_ATTRIBUTE, true)
	local origin = chestPart(chest)
	if not origin then
		return
	end
	local tier = DungeonService:GetDifficultyScale()
	local coins = math.max(math.round(DifficultyData.RunCoins(tier) * LOOT_COIN_SHARE), 1)
	local crystals = math.max(math.round((tier.chestCrystals or 0) * LOOT_CRYSTAL_SHARE), 1)
	for _, player in livingPlayers() do
		burst(origin, DropTypes.Coins, coins, LOOT_COIN_PICKUPS, player)
		burst(origin, DropTypes.ArcaneCrystals, crystals, LOOT_CRYSTAL_PICKUPS, player)
	end
end

function MimicVaultService._startMimic(self: typeof(MimicVaultService), state: VaultState, chest: Model, opener: Player)
	state.status = "fight"
	local generation = state.generation
	local room = state.room
	DungeonService:SuspendEventHold(room.id, HOLD_TEXT_FIGHT)
	notifyAll("It's a Mimic!", ("%s woke something hungry..."):format(opener.Name), NotificationColors.Error)

	-- The shake: a few quick twists about its own pivot.
	local pivot = chest:GetPivot()
	local shakes = 6
	for index = 1, shakes do
		local sign = if index % 2 == 0 then 1 else -1
		chest:PivotTo(pivot * CFrame.Angles(0, 0, math.rad(SHAKE_DEGREES * sign)))
		task.wait(SHAKE_SECONDS / shakes)
	end
	chest:PivotTo(pivot)
	if state.generation ~= generation or not room.model or not room.model.Parent then
		return
	end

	local origin = chestPart(chest)
	local position = if origin then origin.Position else pivot.Position
	local explosion = Instance.new("Explosion")
	explosion.BlastPressure = 0
	explosion.BlastRadius = 0
	explosion.DestroyJointRadiusPercent = 0
	explosion.Position = position
	explosion.Parent = workspace
	hideChest(chest)

	local count = math.min(MIMIC_BASE_MOBS + MIMIC_MOBS_PER_PLAYER * #livingPlayers(), MIMIC_MAX_MOBS)
	local spawned = MobSpawnService:SpawnMobsAt(room, position, count, true)
	Log.debug(("[MimicVaultService] Mimic burst: %d corrupted mobs"):format(#spawned))
	if #spawned == 0 then
		self:_endFight(state)
		return
	end

	local connection: RBXScriptConnection? = nil
	connection = MobSpawnService.OnMobDespawn:Connect(function()
		if state.generation ~= generation or state.status ~= "fight" then
			if connection then
				connection:Disconnect()
			end
			return
		end
		if #MobSpawnService:GetMobsInRoom(room) == 0 then
			if connection then
				connection:Disconnect()
			end
			self:_endFight(state)
		end
	end) :: any
end

-- The pack is dead. The mimic is a punishment: nothing drops, the door's
-- hold simply resumes.
function MimicVaultService._endFight(_self: typeof(MimicVaultService), state: VaultState)
	if state.status ~= "fight" then
		return
	end
	state.status = "done"
	notifyAll("Mimic Slain", "The vault falls silent.", NotificationColors.Success)
	DungeonService:ReleaseEventHold(state.room.id)
end

-- Seals the vault: every unopened chest goes dead.
function MimicVaultService._seal(_self: typeof(MimicVaultService), state: VaultState)
	if state.sealed then
		return
	end
	state.sealed = true
	for index, prompt in state.prompts do
		if not state.opened[index] then
			prompt.Enabled = false
		end
	end
end

function MimicVaultService._onOpen(self: typeof(MimicVaultService), state: VaultState, index: number, player: Player)
	if state.sealed or state.opened[index] or LifeService:IsDeathState(player) then
		return
	end
	local interactables = state.room.model and state.room.model:FindFirstChild("Interactables")
	local chest = interactables and interactables:FindFirstChild(CHEST_NAMES[index])
	if not chest or not chest:IsA("Model") then
		return
	end
	state.opened[index] = true
	local prompt = state.prompts[index]
	if prompt then
		prompt.Enabled = false
	end
	EventService:MarkInteracted(player, state.room.id)

	if index == state.mimicIndex then
		task.spawn(function()
			self:_startMimic(state, chest, player)
		end)
	else
		self:_payLoot(chest)
	end
end

-- Called by EventService as it wires the floor's MimicVault room.
function MimicVaultService.RegisterRoom(self: typeof(MimicVaultService), room: Room)
	local interactables = room.model and room.model:FindFirstChild("Interactables")
	if not interactables then
		warn("[MimicVaultService] MimicVault room has no Interactables folder")
		return
	end
	local state: VaultState = {
		room = room,
		mimicIndex = math.random(1, #CHEST_NAMES),
		opened = {},
		prompts = {},
		sealed = false,
		status = "idle",
		generation = 0,
	}
	for index, name in CHEST_NAMES do
		local chest = interactables:FindFirstChild(name)
		local part = if chest and chest:IsA("Model") then chestPart(chest) else nil
		if not chest or not part then
			warn("[MimicVaultService] MimicVault is missing " .. name)
			continue
		end
		CollectionService:AddTag(chest, TagList.MimicVaultChest)
		local prompt = graftPrompt(part)
		state.prompts[index] = prompt
		prompt.Triggered:Connect(function(player: Player)
			self:_onOpen(state, index, player)
		end)
	end
	self._byRoomId[room.id] = state
	self:_watchExit(state)
end

-- THE SEAL, by position: a player past the room's ExitGate (on the far
-- side of it from the room's centre) has left the vault. Polled, because
-- the next room's entry signal only fires when the next room is a combat
-- room (an Event -> Event door just opens).
function MimicVaultService._watchExit(self: typeof(MimicVaultService), state: VaultState)
	local model = state.room.model
	local gate = model and model:FindFirstChild(EXIT_GATE_NAME)
	if not gate or not gate:IsA("BasePart") then
		return
	end
	local centre = model:GetPivot().Position
	local outward = Vector3.new(gate.Position.X - centre.X, 0, gate.Position.Z - centre.Z)
	if outward.Magnitude < 1e-3 then
		return
	end
	outward = outward.Unit
	local generation = state.generation
	task.spawn(function()
		while not state.sealed and state.generation == generation and model.Parent do
			for _, player in Players:GetPlayers() do
				local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
				if root and root:IsA("BasePart") then
					local past = (root.Position - gate.Position):Dot(outward)
					if past > EXIT_SEAL_STUDS then
						self:_seal(state)
						break
					end
				end
			end
			task.wait(EXIT_POLL_SECONDS)
		end
	end)
end

function MimicVaultService.ResetForFloor(self: typeof(MimicVaultService))
	for _, state in self._byRoomId do
		state.generation += 1
	end
	table.clear(self._byRoomId)
end

function MimicVaultService.Start(self: typeof(MimicVaultService))
	DungeonService.Signals.OnFloorTeardown:Connect(function()
		self:ResetForFloor()
	end)
	-- THE SEAL: anyone entering a room past a vault seals it.
	DungeonService.Signals.OnRoomEntered:Connect(function(_player: Player, room)
		if not room or typeof(room.id) ~= "number" then
			return
		end
		for vaultId, state in self._byRoomId do
			if room.id > vaultId then
				self:_seal(state)
			end
		end
	end)
end

return MimicVaultService
