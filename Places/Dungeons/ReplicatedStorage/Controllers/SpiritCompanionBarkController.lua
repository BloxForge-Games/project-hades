--!strict
--[[
	Module: SpiritCompanionBarkController.lua
	Description:
	The Spirit Companion talks (2026-11-02). A chat-style bubble over the
	LOCAL player's companion, for the local player only: every 30-60 s out
	of combat she picks an idle line, and the dungeon's beats pull a line
	from their own pool (Shared/Data/SpiritCompanionLines):

	  roomCleared     the player's vending machine lands (the last mob fell)
	  lowHealth       health dips under LOW_HEALTH_FRACTION, once per dip
	  downed / revived
	                  the character's Downed attribute flips
	  relicPicked / bagFull
	                  the Player's RelicsGained count rises; full when the
	                  owned count reaches the open slots
	  minibossEnter / bossEnter
	                  EncounterIntroEnd, with the kind from EncounterDataChanged
	  encounterBeaten EncounterOutroEnd

	Rules: never the same line twice in a row from one pool; at least
	MinGapSeconds between any two lines; a beat line resets the idle
	timer; nothing while the player is dead, in a cutscene or talking to
	an NPC; idle lines also wait for the InCombat attribute to clear
	(InCombatController). Client-only: nothing replicates, and four
	companions in a party never talk over each other.
]]

--[ Roblox Services ]--

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

--[ Imports ]--

local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local SpiritCompanionLines = require(ReplicatedStorage.Submodules.Core.Shared.Data.SpiritCompanionLines)
local ChatBubbleController = require(ReplicatedStorage.Submodules.Core.Source.Controllers.ChatBubbleController)
local DungeonNetwork = require(ReplicatedStorage.Submodules.Core.Source.Network.Dungeon)

--[ Controller ]--

local SpiritCompanionBarkController = {
	Name = "SpiritCompanionBarkController",
	Dependencies = { ChatBubbleController } :: { any },
}

--[ Constants ]--

local LOW_HEALTH_FRACTION = 0.3
-- Above this the low-health line may fire again on the next dip.
local LOW_HEALTH_RESET_FRACTION = 0.5
-- The machine lands and the room-clear slow motion releases before she
-- speaks; the relic bubble waits for the pickup burst.
local ROOM_CLEARED_DELAY_SECONDS = 1.6
local RELIC_LINE_DELAY_SECONDS = 0.8
local ENCOUNTER_ENTER_DELAY_SECONDS = 0.6
local ENCOUNTER_BEATEN_DELAY_SECONDS = 1.0
local IDLE_POLL_SECONDS = 1
-- Her name on the bubble, the title after it in italic brackets.
local SPEAKER_NAME = "Navi"
local SPEAKER_TITLE = "Spirit Companion"
-- A smaller card, close over her: she is a small floating thing, and the
-- player-head offset left the bubble hanging far above her.
local BUBBLE_STYLE = { studsAbove = 1.2, textSize = 13, nameSize = 11, maxWidth = 200 }
local BUBBLE_KEY = "SpiritCompanionBark"

--[ State ]--

local lastLineAt = -math.huge
local nextIdleAt = 0
local lastIndexByPool: { [string]: number } = {}
local lowHealthSaid = false
local lastRelicsGained: number? = nil
local encounterKind: string? = nil

--[ Private ]--

local function localCompanion(): Model?
	local userId = Players.LocalPlayer.UserId
	for _, instance in CollectionService:GetTagged(TagList.SpiritCompanion) do
		if instance:IsA("Model") and instance:GetAttribute(Attributes.OwnerId) == userId and instance.PrimaryPart then
			return instance
		end
	end
	return nil
end

-- Dead, in a cutscene or mid-conversation: she keeps quiet.
local function mayTalk(): boolean
	local character = Players.LocalPlayer.Character
	if not character then
		return false
	end
	if character:GetAttribute(Attributes.Death) == true then
		return false
	end
	if character:GetAttribute(Attributes.CutscenePlaying) == true then
		return false
	end
	if character:GetAttribute(Attributes.TalkingToNPC) == true then
		return false
	end
	return true
end

local function inCombat(): boolean
	local character = Players.LocalPlayer.Character
	return character ~= nil and character:GetAttribute(Attributes.InCombat) == true
end

local function pick(pool: string): string?
	local lines = SpiritCompanionLines.Pools[pool]
	if not lines or #lines == 0 then
		return nil
	end
	local index = math.random(#lines)
	if #lines > 1 and index == lastIndexByPool[pool] then
		index = index % #lines + 1
	end
	lastIndexByPool[pool] = index
	return lines[index]
end

-- How long `line` stays up: by its length without markup, between the
-- data's min and max (SpiritCompanionLines).
local function secondsFor(line: string): number
	local length = #(line:gsub("<[^>]->", ""))
	local lines = SpiritCompanionLines
	local alpha = math.clamp((length - lines.ShortChars) / (lines.LongChars - lines.ShortChars), 0, 1)
	return lines.MinBubbleSeconds + (lines.MaxBubbleSeconds - lines.MinBubbleSeconds) * alpha
end

local function scheduleIdle()
	nextIdleAt = os.clock()
		+ SpiritCompanionLines.IdleMinSeconds
		+ math.random() * (SpiritCompanionLines.IdleMaxSeconds - SpiritCompanionLines.IdleMinSeconds)
end

-- One line from `pool`, if she may talk and the gap has passed. A beat
-- line (`force`) ignores the combat check but never the gap or the
-- silence rules. Returns whether anything was said.
local function say(pool: string, force: boolean?): boolean
	if not mayTalk() then
		return false
	end
	if not force and inCombat() then
		return false
	end
	local now = os.clock()
	if now - lastLineAt < SpiritCompanionLines.MinGapSeconds then
		return false
	end
	local companion = localCompanion()
	local anchor = companion and companion.PrimaryPart
	if not anchor then
		return false
	end
	local line = pick(pool)
	if not line then
		return false
	end
	lastLineAt = now
	scheduleIdle()
	ChatBubbleController:ShowAt(
		BUBBLE_KEY,
		anchor,
		SPEAKER_NAME,
		line,
		true,
		secondsFor(line),
		SPEAKER_TITLE,
		BUBBLE_STYLE
	)
	return true
end

local function sayLater(pool: string, seconds: number)
	task.delay(seconds, function()
		say(pool, true)
	end)
end

local function watchCharacter(character: Model)
	local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
	if not humanoid then
		return
	end
	lowHealthSaid = false
	humanoid.HealthChanged:Connect(function(health: number)
		local fraction = if humanoid.MaxHealth > 0 then health / humanoid.MaxHealth else 1
		if fraction > LOW_HEALTH_RESET_FRACTION then
			lowHealthSaid = false
		elseif fraction > 0 and fraction < LOW_HEALTH_FRACTION and not lowHealthSaid then
			lowHealthSaid = true
			say("lowHealth", true)
		end
	end)
	character:GetAttributeChangedSignal(Attributes.Downed):Connect(function()
		if character:GetAttribute(Attributes.Downed) == true then
			-- Down is not dead: she still gets a word in.
			local companion = localCompanion()
			local anchor = companion and companion.PrimaryPart
			local line = anchor and pick("downed")
			if anchor and line then
				lastLineAt = os.clock()
				ChatBubbleController:ShowAt(
					BUBBLE_KEY,
					anchor,
					SPEAKER_NAME,
					line,
					true,
					secondsFor(line),
					SPEAKER_TITLE,
					BUBBLE_STYLE
				)
			end
		elseif character:GetAttribute(Attributes.Death) ~= true then
			sayLater("revived", 0.5)
		end
	end)
end

local function watchMachines()
	local map = workspace:FindFirstChild("IgnoreInstances") and workspace.IgnoreInstances:FindFirstChild("Map")
	local machines = map and map:FindFirstChild("RelicMachines")
	if not machines then
		return
	end
	machines.ChildAdded:Connect(function(child: Instance)
		if child:GetAttribute(Attributes.OwnerId) == Players.LocalPlayer.UserId then
			sayLater("roomCleared", ROOM_CLEARED_DELAY_SECONDS)
		end
	end)
end

--[ Lifecycle ]--

function SpiritCompanionBarkController.Start(_self: typeof(SpiritCompanionBarkController))
	local player = Players.LocalPlayer
	scheduleIdle()

	if player.Character then
		watchCharacter(player.Character)
	end
	player.CharacterAdded:Connect(watchCharacter)
	watchMachines()

	-- Relics: the gained count rises on every pickup; full when the owned
	-- count has reached the open slots.
	lastRelicsGained = tonumber(player:GetAttribute(Attributes.RelicsGained))
	player:GetAttributeChangedSignal(Attributes.RelicsGained):Connect(function()
		local gained = tonumber(player:GetAttribute(Attributes.RelicsGained)) or 0
		if lastRelicsGained ~= nil and gained > lastRelicsGained then
			local owned = tonumber(player:GetAttribute(Attributes.OwnedRelicCount)) or 0
			local slots = tonumber(player:GetAttribute(Attributes.RelicSlots))
			sayLater(if slots and owned >= slots then "bagFull" else "relicPicked", RELIC_LINE_DELAY_SECONDS)
		end
		lastRelicsGained = gained
	end)

	-- Encounters: the HUD payload names the kind; the intro's end is the
	-- fight starting, the outro's end is it won.
	DungeonNetwork.EncounterDataChanged.On(function(payload)
		if payload and payload.kind then
			encounterKind = payload.kind
		end
	end)
	DungeonNetwork.EncounterIntroEnd.On(function()
		sayLater(if encounterKind == "Boss" then "bossEnter" else "minibossEnter", ENCOUNTER_ENTER_DELAY_SECONDS)
	end)
	DungeonNetwork.EncounterOutroEnd.On(function()
		sayLater("encounterBeaten", ENCOUNTER_BEATEN_DELAY_SECONDS)
	end)

	-- Idle chatter, out of combat.
	task.spawn(function()
		while true do
			task.wait(IDLE_POLL_SECONDS)
			if os.clock() >= nextIdleAt then
				if not say("idle") then
					-- Blocked (combat, cutscene, no companion): try again soon.
					nextIdleAt = os.clock() + IDLE_POLL_SECONDS * 3
				end
			end
		end
	end)

	-- Keep the loop honest if a frame hitch stalls task.wait.
	RunService.Heartbeat:Connect(function() end)
end

return SpiritCompanionBarkController
