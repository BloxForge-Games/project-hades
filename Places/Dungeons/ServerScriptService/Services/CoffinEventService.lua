--[[
	Module: Server/Services/CoffinEventService.lua
	Description:
	The Laughing Coffin (prefab CoffinEvent): a timed WAVE CHALLENGE offered
	through a dialogue. EventService wires the prefab and validates the
	model like any event; this service owns everything after the offer.

	--- FLOW ---
	  * The room enters DARK: at generation every torch (anything under the
	    room's Torches folder, plus any emitter beside a Light) is forced
	    invisible / off and the fog cache is rewritten to match, so the fog
	    reveal restores DARK. Only the chunk PrimaryPart's PointLight is
	    lit. The ordinary event exit hold starts on the first body through
	    the door.
	  * Any player may ACCEPT. The first acceptance starts the challenge
	    for the whole room: every other open coffin conversation is closed
	    (OnDialogueCancelled), the coffin's prompt goes dead, the torches
	    IGNITE, the exit hold is SUSPENDED, the encounter lobby countdown
	    (EncounterService.EncounterLobbyData — the same widget the
	    miniboss / boss approach uses) starts, and the queue pours in.
	  * DECLINE is per player: it marks that player interacted (the hold's
	    early-open counts it), announces "<Name> wishes to continue.", and
	    the client consumes the prompt for them. Everyone declining, or the
	    hold running out, opens the door with no challenge — the torches
	    never light.
	  * WIN = the queue is dry and the last one is dead before the deadline:
	    a beat later an Event Chest falls per living player (coins from
	    DungeonData.coffinEvent, gear off perEnemyType[Event]); the door
	    shows a REWARD_HOLD_SECONDS countdown and opens when every chest is
	    opened or that clock runs out, whichever is first.
	  * FAIL = the deadline passes: the survivors despawn, no chest, the
	    hold releases so the door opens.
	  * EXPIRED = the hold ended with nobody accepting: the prompt goes dead
	    and any open coffin conversation is closed.

	--- QUEUE ---
	One wave = one zombie per SpawnPoint attachment in the room; the wave
	count rolls in DungeonData.coffinEvent.waves. Poured in continuously
	under the combat concurrency rule (CONCURRENT_* below) by
	ZombieSpawnService:StartChallengeQueue, from the dungeon's own pool.
]]

--[ Roblox Services ]--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

--[ Imports ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local EnemyTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.EnemyTypes)
local DungeonData = require(ReplicatedStorage.Submodules.Core.Shared.Data.DungeonData)

local DungeonService
local EventService
local EncounterService
local MusicService
local ZombieSpawnService
local EncounterChestService
local UserNotificationService

--[ Constants ]--

-- Fallbacks when a difficulty has no coffinEvent block.
local DEFAULT_CHALLENGE_SECONDS = 60
local DEFAULT_WAVES = { 5, 6 }
-- The combat concurrency rule (mirrors ZombieSpawnService's defaults).
local CONCURRENT_BASE = 4
local CONCURRENT_PER_PLAYER = 2
local CONCURRENT_MAX = 12
-- How far from the coffin a client request is honoured (EventService's
-- own leash; the dialogue keeps players closer than this anyway).
local INTERACT_RANGE = 30
local POLL_SECONDS = 0.25
-- Torch ignition on accept. A light may carry this attribute to set its
-- own lit brightness; otherwise the default. Emitters simply enable.
local IGNITE_BRIGHTNESS_ATTRIBUTE = "IgniteBrightness"
local DEFAULT_IGNITE_BRIGHTNESS = 1
local IGNITE_SECONDS = 1.5
-- The room's torch folder; every part under it is hidden until accept.
local TORCHES_FOLDER_NAME = "Torches"
-- A torch part's authored transparency, cached at darkening so ignition
-- restores it exactly.
local IGNITE_TRANSPARENCY_ATTRIBUTE = "IgniteTransparency"
-- FogOfWarService's cached-authored-value attributes. Rewritten by
-- _darkenRoom so the fog REVEAL restores dark rather than lit.
local FOG_VALUE_ATTRIBUTE = "FogValue"
local FOG_ENABLED_ATTRIBUTE = "FogEnabled"
-- How long the countdown widget keeps showing the result before it clears.
local RESULT_HUD_LINGER_SECONDS = 2.5
-- The lobby widget's title while the challenge runs.
local LOBBY_LABEL = "Coffin's Challenge"
-- The gate billboard while the challenge runs / rewards are out.
local HOLD_TEXT_RUNNING = "The Coffin's challenge... (%d)"
local HOLD_TEXT_REWARDS = "Collect your rewards... (%d)"
-- After a win: a beat before the chests fall, and how long the door
-- waits for them to be opened before it opens anyway.
local CHEST_DROP_DELAY_SECONDS = 1
local REWARD_HOLD_SECONDS = 60
-- The prompt attribute the client's billboard honours as "never re-arm".
local PROMPT_CONSUMED_ATTRIBUTE = "EventConsumed"
local CHEST_MOB_NAME = "Laughing Coffin"
-- The coffin itself fades out for the fight and back in when it ends.
-- Originals are cached on each instance so the restore is exact.
local COFFIN_FADE_SECONDS = 1.5
local ATTR_ORIGINAL_TRANSPARENCY = "CoffinOriginalTransparency"
local ATTR_ORIGINAL_CAN_COLLIDE = "CoffinOriginalCanCollide"
local ATTR_ORIGINAL_ENABLED = "CoffinOriginalEnabled"

local STATUS = {
	Idle = "idle",
	Running = "running",
	Won = "won",
	Failed = "failed",
	Expired = "expired",
}

local NOTIFY_TITLE_COLOR = Color3.fromRGB(201, 134, 255)
local NOTIFY_WIN_COLOR = Color3.fromRGB(85, 255, 127)
local NOTIFY_FAIL_COLOR = Color3.fromRGB(255, 92, 92)

--[ Service ]--

local CoffinEventService = Knit.CreateService({
	Name = "CoffinEventService",
	Client = {
		-- (coffin: Model) — every client closes an open conversation with
		-- this coffin (someone accepted, or the offer expired).
		OnDialogueCancelled = Knit.CreateSignal(),
	},
})

-- [coffinModel] = state; [roomId] = the same state. One challenge per
-- room per floor.
--   state = { room, coffin, gate, status, declined = { [userId] = true },
--             startedAt, deadline, generation }
CoffinEventService._byCoffin = {}
CoffinEventService._byRoomId = {}

--[ Private ]--

-- The active difficulty's coffinEvent block, or the defaults.
local function activeTuning(): { [string]: any }
	local active = DungeonService and DungeonService:GetActiveDungeon()
	local dungeonConfig = active and DungeonData[active.id]
	local difficultyConfig = dungeonConfig and dungeonConfig.difficulties[active.difficulty]
	return (difficultyConfig and difficultyConfig.coffinEvent) or {}
end

local function coffinPrompt(coffin: Model): ProximityPrompt?
	return coffin:FindFirstChildWhichIsA("ProximityPrompt", true)
end

local function notifyAll(title: string, text: string, titleColor: Color3)
	if not UserNotificationService then
		return
	end
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

function CoffinEventService:_validate(player: Player, coffin: any)
	if typeof(coffin) ~= "Instance" then
		return nil
	end
	local state = self._byCoffin[coffin]
	if not state then
		return nil
	end
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	local anchor = coffin.PrimaryPart or coffin:FindFirstChildWhichIsA("BasePart", true)
	if not hrp or not anchor then
		return nil
	end
	if (hrp.Position - anchor.Position).Magnitude > INTERACT_RANGE then
		return nil
	end
	return state
end

-- Kills the coffin as an interactable for EVERYONE: prompt off on the
-- server, consumed-attribute so no client's re-arm brings it back, and
-- every open conversation with it closed.
function CoffinEventService:_retireCoffin(state)
	local prompt = coffinPrompt(state.coffin)
	if prompt then
		prompt:SetAttribute(PROMPT_CONSUMED_ATTRIBUTE, true)
		prompt.Enabled = false
	end
	self.Client.OnDialogueCancelled:FireAll(state.coffin)
end

-- An emitter that belongs to a TORCH: it sits beside a Light, or anywhere
-- under a folder named Torches. Spawn-point particles (emitted per spawn
-- by ZombieSpawnService) and the gate's DungeonDone burst (emitted on a
-- win) are neither, and must not be switched on here.
local function isTorchEffect(instance: Instance): boolean
	local parent = instance.Parent
	if parent and parent:FindFirstChildWhichIsA("Light") then
		return true
	end
	return instance:FindFirstAncestor(TORCHES_FOLDER_NAME) ~= nil
end

-- A torch's own geometry: any part under the Torches folder.
local function isTorchPart(instance: Instance): boolean
	return instance:IsA("BasePart") and instance:FindFirstAncestor(TORCHES_FOLDER_NAME) ~= nil
end

-- The AUTHORED value of a property the fog may already have hidden: the
-- fog's cache when it has run, else the live value.
local function authoredNumber(instance: Instance, property: string): number
	local cached = instance:GetAttribute(FOG_VALUE_ATTRIBUTE)
	if type(cached) == "number" then
		return cached
	end
	return (instance :: any)[property]
end

-- Forces the room's torches DARK at generation, whatever the prefab was
-- authored with: torch parts invisible, torch lights at 0, torch
-- emitters off — with each authored value cached for ignition, and the
-- fog's own cache overwritten so its reveal tween lands on dark too.
-- Order-independent with FogOfWarService's hide: whichever runs first,
-- the authored value survives (fog cache or live) and the room reveals
-- dark. The chunk PrimaryPart's own glow is left alone.
function CoffinEventService:_darkenRoom(room)
	local model = room.model
	if not model then
		return
	end
	local primary = model.PrimaryPart
	for _, descendant in model:GetDescendants() do
		if primary and descendant:IsDescendantOf(primary) then
			continue
		end
		if descendant:IsA("Light") then
			if descendant:GetAttribute(IGNITE_BRIGHTNESS_ATTRIBUTE) == nil then
				descendant:SetAttribute(IGNITE_BRIGHTNESS_ATTRIBUTE, authoredNumber(descendant, "Brightness"))
			end
			descendant.Brightness = 0
			if descendant:GetAttribute(FOG_VALUE_ATTRIBUTE) ~= nil then
				descendant:SetAttribute(FOG_VALUE_ATTRIBUTE, 0)
			end
		elseif isTorchPart(descendant) then
			if descendant:GetAttribute(IGNITE_TRANSPARENCY_ATTRIBUTE) == nil then
				descendant:SetAttribute(IGNITE_TRANSPARENCY_ATTRIBUTE, authoredNumber(descendant, "Transparency"))
			end
			descendant.Transparency = 1
			if descendant:GetAttribute(FOG_VALUE_ATTRIBUTE) ~= nil then
				descendant:SetAttribute(FOG_VALUE_ATTRIBUTE, 1)
			end
		elseif
			(
				descendant:IsA("ParticleEmitter")
				or descendant:IsA("Fire")
				or descendant:IsA("Smoke")
				or descendant:IsA("Sparkles")
			) and isTorchEffect(descendant)
		then
			descendant.Enabled = false
			if descendant:GetAttribute(FOG_ENABLED_ATTRIBUTE) ~= nil then
				descendant:SetAttribute(FOG_ENABLED_ATTRIBUTE, false)
			end
		end
	end
end

-- The fight is over: the coffin can be spoken to again (it has a last
-- word for the party). The consumed mark is cleared so every client's
-- billboard re-arm honours it; a player who already declined has their
-- own local consume, which the server's re-enable overrides.
function CoffinEventService:_reviveCoffinPrompt(state)
	local prompt = coffinPrompt(state.coffin)
	if prompt then
		prompt:SetAttribute(PROMPT_CONSUMED_ATTRIBUTE, nil)
		prompt.Enabled = true
	end
end

-- The torches come up. Every Light in the room except those under the
-- chunk's PrimaryPart (the coffin's own glow, lit all along) tweens to
-- its cached brightness, torch parts fade back in, and only TORCH
-- emitters switch on (see isTorchEffect).
function CoffinEventService:_igniteRoom(room)
	local model = room.model
	if not model then
		return
	end
	local primary = model.PrimaryPart
	for _, descendant in model:GetDescendants() do
		if primary and descendant:IsDescendantOf(primary) then
			continue
		end
		if descendant:IsA("Light") then
			local target = descendant:GetAttribute(IGNITE_BRIGHTNESS_ATTRIBUTE)
			if type(target) ~= "number" then
				target = DEFAULT_IGNITE_BRIGHTNESS
			end
			descendant.Enabled = true
			TweenService:Create(
				descendant,
				TweenInfo.new(IGNITE_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Brightness = target }
			):Play()
		elseif isTorchPart(descendant) then
			local target = descendant:GetAttribute(IGNITE_TRANSPARENCY_ATTRIBUTE)
			if type(target) ~= "number" then
				target = 0
			end
			TweenService:Create(
				descendant,
				TweenInfo.new(IGNITE_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Transparency = target }
			):Play()
		elseif
			(
				descendant:IsA("ParticleEmitter")
				or descendant:IsA("Fire")
				or descendant:IsA("Smoke")
				or descendant:IsA("Sparkles")
			) and isTorchEffect(descendant)
		then
			descendant.Enabled = true
		end
	end
end

-- Hides (hidden = true) or restores the coffin: every part and decal
-- tweens to invisible, collision goes off so it is not an unseen wall in
-- the arena, and its emitters stop; restoring reads the cached originals
-- back. The coffin's glow (a light under the chunk's PrimaryPart) is not
-- part of the model and stays lit throughout.
-- `restoreEffects` (restore only): false keeps the coffin's emitters OFF
-- after it reappears — the coffin that has been laid to rest.
function CoffinEventService:_setCoffinHidden(state, hidden: boolean, restoreEffects: boolean?)
	local coffin = state.coffin
	if not coffin or not coffin.Parent then
		return
	end
	local tweenInfo = TweenInfo.new(COFFIN_FADE_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	for _, descendant in coffin:GetDescendants() do
		if descendant:IsA("BasePart") or descendant:IsA("Decal") or descendant:IsA("Texture") then
			if hidden then
				if descendant:GetAttribute(ATTR_ORIGINAL_TRANSPARENCY) == nil then
					descendant:SetAttribute(ATTR_ORIGINAL_TRANSPARENCY, descendant.Transparency)
				end
				if descendant:IsA("BasePart") then
					if descendant:GetAttribute(ATTR_ORIGINAL_CAN_COLLIDE) == nil then
						descendant:SetAttribute(ATTR_ORIGINAL_CAN_COLLIDE, descendant.CanCollide)
					end
					descendant.CanCollide = false
				end
				TweenService:Create(descendant, tweenInfo, { Transparency = 1 }):Play()
			else
				local original = descendant:GetAttribute(ATTR_ORIGINAL_TRANSPARENCY)
				if original ~= nil then
					TweenService:Create(descendant, tweenInfo, { Transparency = original }):Play()
				end
				if descendant:IsA("BasePart") then
					local canCollide = descendant:GetAttribute(ATTR_ORIGINAL_CAN_COLLIDE)
					if canCollide ~= nil then
						descendant.CanCollide = canCollide
					end
				end
			end
		elseif descendant:IsA("ParticleEmitter") or descendant:IsA("Beam") or descendant:IsA("Fire") then
			if hidden then
				if descendant:GetAttribute(ATTR_ORIGINAL_ENABLED) == nil then
					descendant:SetAttribute(ATTR_ORIGINAL_ENABLED, descendant.Enabled)
				end
				descendant.Enabled = false
			elseif restoreEffects ~= false then
				local enabled = descendant:GetAttribute(ATTR_ORIGINAL_ENABLED)
				if enabled ~= nil then
					descendant.Enabled = enabled
				end
			end
		end
	end
end

-- Seconds left on the challenge clock (0 once over).
local function secondsLeft(state): number
	return math.max(0, math.ceil((state.deadline or 0) - os.clock()))
end

-- Publishes the countdown through EncounterService's lobby property, so
-- the miniboss / boss approach widget counts this down too. Refuses to
-- clobber a live encounter lobby (cannot happen inside an event room;
-- guarded anyway). `readyLabel` replaces the widget's pad count with
-- the kill tally.
function CoffinEventService:_publishLobby(state, remaining: number?)
	if not EncounterService or EncounterService._activeLobby ~= nil then
		return
	end
	if remaining == nil then
		EncounterService.Client.EncounterLobbyData:Set(nil)
		return
	end
	local total = state.total or 0
	local queued = ZombieSpawnService:GetRoomQueueRemaining(state.room)
	local alive = #ZombieSpawnService:GetZombiesInRoom(state.room)
	local slain = math.max(0, total - queued - alive)
	local anchor = state.coffin.PrimaryPart
	EncounterService.Client.EncounterLobbyData:Set({
		kind = "Coffin",
		label = LOBBY_LABEL,
		remainingSeconds = remaining,
		totalSeconds = state.duration or DEFAULT_CHALLENGE_SECONDS,
		playersOnPad = slain,
		totalPlayers = total,
		readyLabel = ("(%d / %d Slain)"):format(slain, total),
		accelerated = false,
		padPosition = if anchor then anchor.Position else Vector3.zero,
	})
end

function CoffinEventService:_startChallenge(state, player: Player)
	local tuning = activeTuning()
	local seconds = tuning.challengeSeconds or DEFAULT_CHALLENGE_SECONDS
	local waveRange = tuning.waves or DEFAULT_WAVES
	local waves = math.random(waveRange[1], waveRange[2] or waveRange[1])

	local playerCount = math.max(#Players:GetPlayers(), 1)
	local concurrentCap = math.min(CONCURRENT_BASE + playerCount * CONCURRENT_PER_PLAYER, CONCURRENT_MAX)

	local total = ZombieSpawnService:StartChallengeQueue(state.room, waves, concurrentCap)
	if not total or total <= 0 then
		warn("[CoffinEventService] Challenge could not start (no spawn points) — treating as won")
		state.status = STATUS.Running
		state.startedAt = workspace:GetServerTimeNow()
		state.duration = seconds
		self:_finish(state, true)
		return
	end

	state.status = STATUS.Running
	state.startedAt = workspace:GetServerTimeNow()
	state.duration = seconds
	state.deadline = os.clock() + seconds
	state.total = total
	state.generation += 1
	local generation = state.generation

	self:_retireCoffin(state)
	self:_setCoffinHidden(state, true)
	DungeonService:SuspendEventHold(state.room.id, function()
		return HOLD_TEXT_RUNNING:format(secondsLeft(state))
	end)
	self:_igniteRoom(state.room)
	-- The fight plays to the dungeon theme, not the event track.
	if MusicService then
		MusicService:SetEventRoomChallenge(state.room.id, true)
	end
	self:_publishLobby(state, seconds)
	notifyAll("The Laughing Coffin", ("%s started the Event!"):format(player.Name, seconds), NOTIFY_TITLE_COLOR)
	print(
		("[CoffinEventService] Challenge started by %s: %d zombies, cap %d, %ds"):format(
			player.Name,
			total,
			concurrentCap,
			seconds
		)
	)

	-- The referee: win the moment the queue is dry and the room is empty,
	-- fail the moment the clock runs out.
	task.spawn(function()
		while state.status == STATUS.Running and state.generation == generation do
			if not state.room.model or not state.room.model.Parent then
				return
			end
			if os.clock() >= state.deadline then
				self:_finish(state, false)
				return
			end
			if
				ZombieSpawnService:IsRoomQueueExhausted(state.room)
				and #ZombieSpawnService:GetZombiesInRoom(state.room) == 0
			then
				self:_finish(state, true)
				return
			end
			self:_publishLobby(state, state.deadline - os.clock())
			task.wait(POLL_SECONDS)
		end
	end)
end

function CoffinEventService:_finish(state, won: boolean)
	if state.status ~= STATUS.Running then
		return
	end
	state.status = if won then STATUS.Won else STATUS.Failed
	-- The coffin returns either way; its particles only if it was NOT laid
	-- to rest (a win puts the coffin to sleep). It can be spoken to again:
	-- the graph has a last word for a win, a fail, and an expiry.
	self:_setCoffinHidden(state, false, not won)
	self:_reviveCoffinPrompt(state)
	-- Back to the event track.
	if MusicService then
		MusicService:SetEventRoomChallenge(state.room.id, false)
	end
	-- Final frame of the countdown (frozen), then it clears.
	self:_publishLobby(state, if won then state.deadline - os.clock() else 0)
	local generation = state.generation
	task.delay(RESULT_HUD_LINGER_SECONDS, function()
		if state.generation == generation and self._byRoomId[state.room.id] == state then
			self:_publishLobby(state, nil)
		end
	end)

	if won then
		notifyAll("Event Successful", "Victory. Your reward awaits.", NOTIFY_WIN_COLOR)

		-- The door: a visible reward clock. Opens when every chest is opened
		-- (the batch callback) or when the clock runs out, whichever first.
		state.rewardDeadline = os.clock() + REWARD_HOLD_SECONDS
		DungeonService:SuspendEventHold(state.room.id, function()
			return HOLD_TEXT_REWARDS:format(math.max(0, math.ceil(state.rewardDeadline - os.clock())))
		end)
		local released = false
		local function release()
			if released then
				return
			end
			released = true
			print("[CoffinEventService] Rewards collected / reward clock done: releasing the exit")
			DungeonService:ReleaseEventHold(state.room.id)
		end
		task.delay(REWARD_HOLD_SECONDS, release)
		-- The room's own clear celebration, same as a combat segment.
		DungeonService:_emitDungeonDoneEffect(state.room.model)
		-- A beat, then the chests fall.
		task.delay(CHEST_DROP_DELAY_SECONDS, function()
			print("[CoffinEventService] Dropping Event Chests")
			if not self:DropRewardChests(release) then
				release()
			end
		end)
	else
		notifyAll("Event Failed", "Defeat. The reward is lost.", NOTIFY_FAIL_COLOR)
		ZombieSpawnService:DespawnZombiesInRoom(state.room)
		DungeonService:ReleaseEventHold(state.room.id)
	end
end

-- The hold ended with no acceptance: the offer is gone.
function CoffinEventService:_expire(state)
	if state.status ~= STATUS.Idle then
		return
	end
	state.status = STATUS.Expired
	self:_retireCoffin(state)
end

--[ Public ]--

-- Drops the Event Chest batch (one per living player) with the active
-- difficulty's coffin coin row. Shared by the win path and the /drop
-- eventchest debug command. Returns false when the chest service is
-- unavailable, so the caller can open the door itself.
function CoffinEventService:DropRewardChests(onAllOpened: (() -> ())?): boolean
	if not EncounterChestService then
		return false
	end
	EncounterChestService:DropChestsForEncounter(EnemyTypes.Event, CHEST_MOB_NAME, onAllOpened, activeTuning().coins)
	return true
end

-- Called by EventService as it wires the floor's CoffinEvent room.
function CoffinEventService:RegisterRoom(room, coffin: Model)
	local state = {
		room = room,
		coffin = coffin,
		status = STATUS.Idle,
		declined = {},
		generation = 0,
	}
	self._byCoffin[coffin] = state
	self._byRoomId[room.id] = state

	self:_darkenRoom(room)

	-- The exit opening is the surest "the hold is over" edge (every
	-- timed door stamps it); OnEventHoldEnded covers the approach branch
	-- whose door never opens.
	local gate = room.model and room.model:FindFirstChild("ExitGate")
	if gate then
		gate:GetAttributeChangedSignal("GateState"):Connect(function()
			if gate:GetAttribute("GateState") == "open" then
				self:_expire(state)
			end
		end)
	end
end

-- The floor is being torn down. Every live run ENDS here.
--
-- Clearing the two lookups was not enough. The referee is a spawned
-- loop closed over its own `state`, so dropping the table it was
-- indexed under left it spinning on a state that still read Running —
-- and on the next floor the old room's queue reads exhausted and its
-- zombie list empty, which is exactly the WIN condition. A floor-one
-- coffin event would announce "Event Successful" minutes into floor
-- two and hang a reward clock on a room that no longer exists.
--
-- Bumping the generation drops the referee out of its loop and no-ops
-- its pending publishes; moving the status off Running makes _finish
-- refuse outright. Either alone would do, and both is cheap.
function CoffinEventService:ResetForFloor()
	for _, state in self._byRoomId do
		state.generation += 1
		if state.status == STATUS.Running then
			state.status = STATUS.Expired
		end
	end
	table.clear(self._byCoffin)
	table.clear(self._byRoomId)
end

--[ Client ]--

-- The graph's opening node reads this to route the conversation.
function CoffinEventService.Client:GetState(player: Player, coffin: Instance)
	local state = CoffinEventService:_validate(player, coffin)
	if not state then
		return { status = STATUS.Expired, declined = false }
	end
	return { status = state.status, declined = state.declined[player.UserId] == true }
end

-- true when THIS call started the challenge. false when it was already
-- running / over (someone beat them to it — their dialogue is being
-- cancelled by OnDialogueCancelled either way).
function CoffinEventService.Client:Accept(player: Player, coffin: Instance): boolean
	local state = CoffinEventService:_validate(player, coffin)
	if not state or state.status ~= STATUS.Idle then
		return false
	end
	CoffinEventService:_startChallenge(state, player)
	return true
end

-- Per player. Counts toward the hold's early-open and tells the party.
function CoffinEventService.Client:Decline(player: Player, coffin: Instance)
	local state = CoffinEventService:_validate(player, coffin)
	if not state or state.declined[player.UserId] then
		return
	end
	state.declined[player.UserId] = true
	if EventService then
		EventService:MarkInteracted(player, state.room.id)
		EventService:NotifyWishesToContinue(player)
	end
end

--[ Lifecycle ]--

function CoffinEventService:KnitInit()
	DungeonService = Knit.GetService("DungeonService")
	EventService = Knit.GetService("EventService")
	EncounterService = Knit.GetService("EncounterService")
	MusicService = Knit.GetService("MusicService")
	ZombieSpawnService = Knit.GetService("ZombieSpawnService")
	EncounterChestService = Knit.GetService("EncounterChestService")
	UserNotificationService = Knit.GetService("UserNotificationService")
end

function CoffinEventService:KnitStart()
	DungeonService.Signals.OnEventHoldEnded:Connect(function(eventRoom)
		local state = eventRoom and self._byRoomId[eventRoom.id]
		if state then
			self:_expire(state)
		end
	end)
end

return CoffinEventService
