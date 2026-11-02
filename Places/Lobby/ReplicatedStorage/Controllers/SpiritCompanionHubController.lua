--!strict
--[[
	Module: SpiritCompanionHubController.lua
	Description:
	The Spirit Companion talks in the hub (2026-11-02): the Lobby half of
	the Dungeons' SpiritCompanionBarkController, on the same bubble and the
	same silence rules, with the hub's pools (Shared/Data
	/SpiritCompanionLines):

	  hubWelcome      once per visit, from WELCOME_DELAY_SECONDS after the
	                  first spawn, retried until she can speak (her model
	                  and the landing can still be on their way) or
	                  WELCOME_GIVE_UP_SECONDS pass
	  hubIdle         every IdleMin-IdleMax seconds
	  nearBlacksmith / nearScavenger / nearBandit / nearWizard
	                  the player comes within APPROACH_STUDS of that NPC
	                  (the nearest one, matched by name keyword like
	                  LobbyNPCService), once per approach, only
	                  APPROACH_CHANCE of the time, at most every
	                  APPROACH_COOLDOWN_SECONDS per NPC and
	                  APPROACH_GLOBAL_COOLDOWN_SECONDS across them all (so
	                  walking down the row gets one line, not four)

	Rules: never the same line twice in a row from one pool; at least
	MinGapSeconds between any two lines; nothing while dead, in a cutscene
	or talking to an NPC. Client-only, the local player's companion only.
]]

--[ Roblox Services ]--

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--[ Imports ]--

local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local SpiritCompanionLines = require(ReplicatedStorage.Submodules.Core.Shared.Data.SpiritCompanionLines)
local ChatBubbleController = require(ReplicatedStorage.Submodules.Core.Source.Controllers.ChatBubbleController)

--[ Controller ]--

local SpiritCompanionHubController = {
	Name = "SpiritCompanionHubController",
	Dependencies = { ChatBubbleController } :: { any },
}

--[ Constants ]--

local WELCOME_DELAY_SECONDS = 6
local WELCOME_GIVE_UP_SECONDS = 30
local POLL_SECONDS = 0.5
-- Studs from an NPC that count as walking up to it, and the further
-- distance the player must leave to before it can fire again.
local APPROACH_STUDS = 12
local LEAVE_STUDS = 18
-- 2026-11-02: per NPC 90 s and every approach before, which talked on
-- every walk past the row.
local APPROACH_COOLDOWN_SECONDS = 600
local APPROACH_GLOBAL_COOLDOWN_SECONDS = 180
local APPROACH_CHANCE = 0.5
-- Lower-cased keyword in the NPC's name -> its pool. First match wins.
local POOL_BY_KEYWORD: { { keyword: string, pool: string } } = {
	{ keyword = "yulgar", pool = "nearBlacksmith" },
	{ keyword = "blacksmith", pool = "nearBlacksmith" },
	{ keyword = "twig", pool = "nearScavenger" },
	{ keyword = "valencia", pool = "nearBandit" },
	{ keyword = "warlic", pool = "nearWizard" },
}
-- The bubble, as the dungeon draws it (SpiritCompanionBarkController).
local SPEAKER_NAME = "Navi"
local SPEAKER_TITLE = "Spirit Companion"
local BUBBLE_STYLE = { studsAbove = 1.2, textSize = 13, nameSize = 11, maxWidth = 200 }
local BUBBLE_KEY = "SpiritCompanionBark"

--[ State ]--

local lastLineAt = -math.huge
local nextIdleAt = 0
local lastIndexByPool: { [string]: number } = {}
-- The NPC the player is standing at (nil once they walk off), and when
-- each NPC last drew a line.
local currentNpc: Model? = nil
local lastApproachAt: { [Model]: number } = {}
local lastAnyApproachAt = -math.huge
-- True until the welcome has had its turn: nothing else speaks first
-- (the spawn stands near an NPC).
local welcomePending = true

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

local function mayTalk(): boolean
	local character = Players.LocalPlayer.Character
	if not character then
		return false
	end
	return character:GetAttribute(Attributes.Death) ~= true
		and character:GetAttribute(Attributes.CutscenePlaying) ~= true
		and character:GetAttribute(Attributes.TalkingToNPC) ~= true
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

-- One line from `pool`, if she may talk and the gap has passed.
local function say(pool: string): boolean
	if not mayTalk() then
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

local function poolForNpc(npc: Model): string?
	local lowered = string.lower(npc.Name)
	for _, entry in POOL_BY_KEYWORD do
		if string.find(lowered, entry.keyword, 1, true) then
			return entry.pool
		end
	end
	return nil
end

-- The nearest talk-to NPC within `radius` of `position`, with its pool.
local function nearestNpc(position: Vector3, radius: number): (Model?, string?)
	local ignore = workspace:FindFirstChild("IgnoreInstances")
	local folder = ignore and ignore:FindFirstChild("NPCs")
	if not folder then
		return nil, nil
	end
	local best: Model?, bestPool: string?, bestDistance = nil, nil, radius
	for _, npc in folder:GetChildren() do
		if npc:IsA("Model") then
			local pool = poolForNpc(npc)
			local distance = (npc:GetPivot().Position - position).Magnitude
			if pool and distance <= bestDistance then
				best, bestPool, bestDistance = npc, pool, distance
			end
		end
	end
	return best, bestPool
end

-- Walking up to an NPC: one line on arrival, then nothing until the
-- player walks off (LEAVE_STUDS) and the NPC's cooldown has passed.
local function checkApproach()
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end
	if currentNpc then
		if (currentNpc:GetPivot().Position - root.Position).Magnitude > LEAVE_STUDS or not currentNpc.Parent then
			currentNpc = nil
		end
		return
	end
	local npc, pool = nearestNpc(root.Position, APPROACH_STUDS)
	if not npc or not pool then
		return
	end
	local now = os.clock()
	if
		now - (lastApproachAt[npc] or -math.huge) < APPROACH_COOLDOWN_SECONDS
		or now - lastAnyApproachAt < APPROACH_GLOBAL_COOLDOWN_SECONDS
		or math.random() >= APPROACH_CHANCE
	then
		-- Said recently, or she lets this one pass: the visit stays quiet.
		currentNpc = npc
		return
	end
	-- Blocked (the gap, a conversation): left unmarked, so it tries again
	-- next poll while the player is still here.
	if say(pool) then
		currentNpc = npc
		lastApproachAt[npc] = now
		lastAnyApproachAt = now
	end
end

--[ Lifecycle ]--

function SpiritCompanionHubController.Start(_self: typeof(SpiritCompanionHubController))
	local player = Players.LocalPlayer
	scheduleIdle()

	-- The welcome, once per visit (a rig swap re-adds the character).
	task.spawn(function()
		if not player.Character then
			player.CharacterAdded:Wait()
		end
		task.wait(WELCOME_DELAY_SECONDS)
		local giveUpAt = os.clock() + WELCOME_GIVE_UP_SECONDS
		while not say("hubWelcome") and os.clock() < giveUpAt do
			task.wait(POLL_SECONDS)
		end
		welcomePending = false
	end)

	task.spawn(function()
		while true do
			task.wait(POLL_SECONDS)
			if welcomePending then
				continue
			end
			checkApproach()
			if os.clock() >= nextIdleAt then
				if not say("hubIdle") then
					-- Blocked (gap, conversation, no companion): try again soon.
					nextIdleAt = os.clock() + 3
				end
			end
		end
	end)
end

return SpiritCompanionHubController
