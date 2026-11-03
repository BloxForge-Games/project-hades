--!strict
--[[
	Module: LobbyNpcBarkController.lua
	Description:
	The hub's NPCs speak now and then (2026-11-03), in the Spirit
	Companion's bubble (ChatBubbleController.ShowAt), their name and their
	job in grey brackets ("Yulgar  (Blacksmith)"). The lines are
	Shared/Data/HubNpcLines. Sparing on purpose, so the town never feels
	chatty:

	  GREET  the player comes within GREET_STUDS of an NPC: it greets them,
	         once per approach, GREET_CHANCE of the time, at most every
	         GREET_COOLDOWN_SECONDS per NPC.
	  IDLE   every IDLE_MIN-IDLE_MAX seconds one NPC within IDLE_STUDS of
	         the player says something to no one in particular.
	  GAP    no NPC speaks within MIN_GAP_SECONDS of another's line.

	Silent while the player is dead, in a cutscene or talking to an NPC,
	and the moment a conversation opens every bark still showing is
	cleared, so the conversation's own box is never covered.
	Never the same line twice in a row from one pool. Client-only.
]]

--[ Roblox Services ]--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

--[ Imports ]--

local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local HubNpcLines = require(ReplicatedStorage.Submodules.Core.Shared.Data.HubNpcLines)
local ChatBubbleController = require(ReplicatedStorage.Submodules.Core.Source.Controllers.ChatBubbleController)

--[ Module ]--

local LobbyNpcBarkController = {
	Name = "LobbyNpcBarkController",
	Dependencies = { ChatBubbleController } :: { any },
}

--[ Constants ]--

local IGNORE_INSTANCES_NAME = "IgnoreInstances"
local NPC_FOLDER_NAME = "NPCs"

local GREET_STUDS = 20
-- The player must step this far away before the NPC can greet again.
local GREET_RESET_STUDS = 21
local GREET_CHANCE = 0.6
local GREET_COOLDOWN_SECONDS = 25
local IDLE_STUDS = 45
local IDLE_MIN_SECONDS = 15
local IDLE_MAX_SECONDS = 25
local MIN_GAP_SECONDS = 10
-- How often the approach check runs.
local CHECK_SECONDS = 0.5

local BUBBLE_STYLE = { studsAbove = 1.2, textSize = 13, nameSize = 11, maxWidth = 200 }
-- The Spirit Companion's bubble (SpiritCompanionHubController): she always
-- wins -- while it shows, no NPC speaks and any bark is cleared, since two
-- on-top billboards have no draw order between them.
local COMPANION_BUBBLE_KEY = "SpiritCompanionBark"

--[ State ]--

type Speaker = {
	model: Model,
	voice: HubNpcLines.NpcVoice,
	near: boolean,
	lastGreetAt: number,
}

local speakers: { Speaker } = {}
local lastLineAt = -math.huge
local nextIdleAt = 0
local lastIndex: { [string]: number } = {}

--[ Private ]--

local function voiceFor(model: Model): HubNpcLines.NpcVoice?
	local lowered = string.lower(model.Name)
	for _, voice in HubNpcLines.Voices do
		if string.find(lowered, voice.keyword, 1, true) then
			return voice
		end
	end
	return nil
end

local function scheduleIdle()
	nextIdleAt = os.clock() + IDLE_MIN_SECONDS + math.random() * (IDLE_MAX_SECONDS - IDLE_MIN_SECONDS)
end

local function canSpeak(): boolean
	local character = Players.LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return character ~= nil
		and humanoid ~= nil
		and humanoid.Health > 0
		and character:GetAttribute(Attributes.CutscenePlaying) ~= true
		and character:GetAttribute(Attributes.TalkingToNPC) ~= true
		and os.clock() - lastLineAt >= MIN_GAP_SECONDS
		and not ChatBubbleController:IsShowing(COMPANION_BUBBLE_KEY)
end

local function pick(key: string, lines: { string }): string?
	if #lines == 0 then
		return nil
	end
	local index = math.random(#lines)
	if #lines > 1 and index == lastIndex[key] then
		index = index % #lines + 1
	end
	lastIndex[key] = index
	return lines[index]
end

local function secondsFor(line: string): number
	local length = #(line:gsub("<[^>]->", ""))
	local lines = HubNpcLines
	local alpha = math.clamp((length - lines.ShortChars) / (lines.LongChars - lines.ShortChars), 0, 1)
	return lines.MinBubbleSeconds + (lines.MaxBubbleSeconds - lines.MinBubbleSeconds) * alpha
end

local function say(speaker: Speaker, pool: "greet" | "idle"): boolean
	local head = speaker.model:FindFirstChild("Head")
	if not head or not head:IsA("BasePart") then
		return false
	end
	local line = pick(speaker.voice.keyword .. pool, speaker.voice[pool])
	if not line then
		return false
	end
	lastLineAt = os.clock()
	ChatBubbleController:ShowAt(
		"HubNpc" .. speaker.voice.keyword,
		head,
		speaker.voice.name,
		line,
		true,
		secondsFor(line),
		speaker.voice.title,
		BUBBLE_STYLE
	)
	return true
end

local function distanceTo(speaker: Speaker, position: Vector3): number
	local head = speaker.model:FindFirstChild("Head")
	if not head or not head:IsA("BasePart") then
		return math.huge
	end
	return (head.Position - position).Magnitude
end

local function check()
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return
	end
	local position = root.Position
	local now = os.clock()
	-- Greetings: the approach edge only, so standing beside an NPC never
	-- repeats one.
	for _, speaker in speakers do
		local distance = distanceTo(speaker, position)
		if not speaker.near and distance <= GREET_STUDS then
			speaker.near = true
			if
				now - speaker.lastGreetAt >= GREET_COOLDOWN_SECONDS
				and math.random() < GREET_CHANCE
				and canSpeak()
				and say(speaker, "greet")
			then
				speaker.lastGreetAt = now
			end
		elseif speaker.near and distance > GREET_RESET_STUDS then
			speaker.near = false
		end
	end
	-- Idle: one NPC in earshot, now and then.
	if now >= nextIdleAt then
		scheduleIdle()
		if canSpeak() then
			local inRange = {}
			for _, speaker in speakers do
				if distanceTo(speaker, position) <= IDLE_STUDS then
					table.insert(inRange, speaker)
				end
			end
			if #inRange > 0 then
				say(inRange[math.random(#inRange)], "idle")
			end
		end
	end
end

-- Clears every NPC bark still on screen (a conversation just opened).
local function hideAll()
	for _, voice in HubNpcLines.Voices do
		ChatBubbleController:Hide("HubNpc" .. voice.keyword)
	end
end

local function watchConversation(character: Model)
	character:GetAttributeChangedSignal(Attributes.TalkingToNPC):Connect(function()
		if character:GetAttribute(Attributes.TalkingToNPC) == true then
			hideAll()
		end
	end)
end

local function track(model: Model)
	local voice = voiceFor(model)
	if not voice then
		return
	end
	for _, speaker in speakers do
		if speaker.model == model then
			return
		end
	end
	table.insert(speakers, { model = model, voice = voice, near = false, lastGreetAt = -math.huge })
end

--[ Lifecycle ]--

function LobbyNpcBarkController.Start(_self: typeof(LobbyNpcBarkController))
	scheduleIdle()
	local player = Players.LocalPlayer
	if player.Character then
		watchConversation(player.Character)
	end
	player.CharacterAdded:Connect(watchConversation)
	task.spawn(function()
		local ignore = workspace:WaitForChild(IGNORE_INSTANCES_NAME, 10)
		local folder = ignore and ignore:WaitForChild(NPC_FOLDER_NAME, 10)
		if not folder then
			return
		end
		folder.ChildAdded:Connect(function(child: Instance)
			if child:IsA("Model") then
				track(child)
			end
		end)
		folder.ChildRemoved:Connect(function(child: Instance)
			for index, speaker in speakers do
				if speaker.model == child then
					table.remove(speakers, index)
					break
				end
			end
		end)
		for _, child in folder:GetChildren() do
			if child:IsA("Model") then
				track(child)
			end
		end
	end)
	local elapsed = 0
	local companionWasShowing = false
	RunService.Heartbeat:Connect(function(dt: number)
		-- The companion starts a line: clear the NPCs' at once.
		local companionShowing = ChatBubbleController:IsShowing(COMPANION_BUBBLE_KEY)
		if companionShowing and not companionWasShowing then
			hideAll()
		end
		companionWasShowing = companionShowing
		elapsed += dt
		if elapsed >= CHECK_SECONDS then
			elapsed = 0
			check()
		end
	end)
end

return LobbyNpcBarkController
