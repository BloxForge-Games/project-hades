--!strict
--[[
	RunSummaryService (2026-11-08): the end-of-run summary each player sees
	in the dungeon before the hub teleport. Result (CLEARED / DEFEATED),
	run stats, rewards earned, the build they ran and their next goals.

	  * CLEAR: RunFlowService's exit gate asks Open(player, true, onClose)
	    instead of teleporting. The run loot is banked FIRST (RunEscrowService
	    :ClaimRewards), so the rewards shown are exactly what landed, Store
	    boosts and the friend bonus included; Continue (or AUTO_CONTINUE_SECONDS)
	    runs onClose, the teleport.
	  * WIPE: LifeService.OnPartyWiped (the escrow is banked there) opens a
	    DEFEATED summary for everyone once the game-over beat has played
	    (WIPE_SUMMARY_DELAY); Continue teleports that player, and LifeService's
	    own wipe teleport takes anyone who never pressed it.

	Rewards are deltas against a snapshot taken when the player's profile
	loads in this server (Gold, Crystals, Level / EXP), so every grant path
	is counted without each one reporting here. Kills come from
	RoundStatisticsService, corrupted kills from its OnCorruptedKill, gear
	from RunEscrowService:AddItem (NoteGear).
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Blitz = require(ReplicatedStorage.Submodules.Core.Shared.Blitz)
local GameClock = require(ReplicatedStorage.Submodules.Core.Shared.GameClock)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local CurrencyTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.CurrencyTypes)
local DungeonData = require(ReplicatedStorage.Submodules.Core.Shared.Data.DungeonData)
local DifficultyData = require(ReplicatedStorage.Submodules.Core.Shared.Data.DifficultyData)
local QuestData = require(ReplicatedStorage.Submodules.Core.Shared.Data.QuestData)
local GearChestData = require(ReplicatedStorage.Submodules.Core.Shared.Data.GearChestData)
local dungeonProgress = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Dungeon.dungeonProgress)
local arcaneIndex = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Arcane.arcaneIndex)
local relicUnlocks = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Relic.relicUnlocks)
local DataService = require(ServerScriptService.Submodules.Core.Source.Services.DataService)
local ExperienceService =
	require(ServerScriptService.Submodules.Core.Source.Services.DataService.SubServices.ExperienceService)
local DungeonNetwork = require(ServerScriptService.Submodules.Core.Source.Network.Dungeon)

-- A summary nobody closes sends the player on after this long.
local AUTO_CONTINUE_SECONDS = 30
-- After a wipe: the game-over beat plays first (LifeController's red hold
-- and pulse), then the summary rises over it.
local WIPE_SUMMARY_DELAY = 3.5
-- At most this many gear rows in the summary (the rest counted).
local MAX_GEAR_ROWS = 6

type Snapshot = {
	gold: number,
	crystals: number,
	level: number,
	currentExp: number,
	-- Quest progress and dungeon progress as the run began, for what the
	-- run moved / unlocked.
	dailyProgress: { [string]: number },
	weeklyProgress: { [string]: number },
	dungeonProgress: { [string]: any },
}

type Record = {
	snapshot: Snapshot?,
	corruptedKills: number,
	gear: { { name: string, rarity: string } },
	gearCount: number,
	-- The summary is up; nil = never opened.
	open: boolean?,
	-- Closed (Continue / timeout); a later exit-gate press goes straight on.
	closed: boolean?,
	onClose: (() -> ())?,
}

local RunSummaryService = {
	Name = "RunSummaryService",
	_records = {} :: { [Player]: Record },
	_runStartedAt = nil :: number?,
}

function RunSummaryService._record(self: typeof(RunSummaryService), player: Player): Record
	local record = self._records[player]
	if not record then
		record = { corruptedKills = 0, gear = {}, gearCount = 0 }
		self._records[player] = record
	end
	return record
end

local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return if value == nil then {} else value
	end
	local copy = {}
	for key, item in value do
		copy[key] = if type(item) == "table" then deepCopy(item) else item
	end
	return copy
end

function RunSummaryService._snapshot(self: typeof(RunSummaryService), player: Player)
	local profile = DataService:GetProfileData(player)
	if not profile then
		return
	end
	local quests = if type(profile.Quests) == "table" then profile.Quests else {}
	local function progressOf(kind: any): { [string]: number }
		return if type(kind) == "table" and type(kind.Progress) == "table" then table.clone(kind.Progress) else {}
	end
	self:_record(player).snapshot = {
		gold = profile[CurrencyTypes.Gold] or 0,
		crystals = profile[CurrencyTypes.ArcaneCrystals] or 0,
		level = ExperienceService:GetLevel(player),
		currentExp = ExperienceService:GetCurrentExp(player),
		dailyProgress = progressOf(quests.Daily),
		weeklyProgress = progressOf(quests.Weekly),
		dungeonProgress = deepCopy(profile.DungeonProgress),
	}
end

-- A gear piece the player picked up (RunEscrowService:AddItem).
function RunSummaryService.NoteGear(self: typeof(RunSummaryService), player: Player, item: { [string]: any }?)
	local record = self:_record(player)
	record.gearCount += 1
	if item and type(item.name) == "string" and #record.gear < MAX_GEAR_ROWS then
		table.insert(record.gear, {
			name = item.name,
			rarity = if type(item.rarity) == "string" then item.rarity else "Common",
		})
	end
end

-- EXP gained since the snapshot, across any level-ups.
local function expGained(snapshot: Snapshot, level: number, currentExp: number): number
	if level == snapshot.level then
		return math.max(currentExp - snapshot.currentExp, 0)
	end
	local total = ExperienceService:_totalExpForLevel(snapshot.level) - snapshot.currentExp
	for between = snapshot.level + 1, level - 1 do
		total += ExperienceService:_totalExpForLevel(between)
	end
	return math.max(total + currentExp, 0)
end

-- What the run moved forward (2026-11-08): the quests it progressed, and
-- anything it unlocked (a level, a difficulty, a dungeon, a stronger gear
-- chest), compared against the snapshot.
function RunSummaryService._progress(
	_self: typeof(RunSummaryService),
	player: Player,
	profile: { [string]: any },
	snapshot: Snapshot?,
	dungeonId: string?
): ({ { [string]: any } }, { string })
	local quests: { { [string]: any } } = {}
	local unlocks: { string } = {}
	if not snapshot then
		return quests, unlocks
	end

	-- Quests: every active daily / weekly whose count went up this run.
	local questState = if type(profile.Quests) == "table" then profile.Quests else {}
	local function scan(kind: any, active: { QuestData.Quest }, before: { [string]: number }, tag: string)
		if type(kind) ~= "table" or type(kind.Progress) ~= "table" then
			return
		end
		for _, quest in active do
			local now = tonumber(kind.Progress[quest.id]) or 0
			local was = tonumber(before[quest.id]) or 0
			if now > was then
				local done = now >= quest.target
				table.insert(quests, {
					title = quest.title,
					detail = if done
						then tag .. "  •  Complete! Claim it in the hub"
						else string.format("%s  •  %d / %d", tag, now, quest.target),
					progress = math.clamp(now / math.max(quest.target, 1), 0, 1),
					done = done,
				})
			end
		end
	end
	local daily = questState.Daily
	if type(daily) == "table" and type(daily.Period) == "number" then
		scan(daily, QuestData.ActiveDaily(daily.Period), snapshot.dailyProgress, "Daily")
	end
	local weekly = questState.Weekly
	if type(weekly) == "table" and type(weekly.Period) == "number" then
		scan(weekly, QuestData.ActiveWeekly(weekly.Period), snapshot.weeklyProgress, "Weekly")
	end
	-- Completed first.
	table.sort(quests, function(a, b)
		if a.done ~= b.done then
			return a.done
		end
		return a.progress > b.progress
	end)

	-- Unlocks. (No "Reached Level N" line, 2026-11-08: the EXP bar on the
	-- HUD already says it; only what a level or clear OPENS is listed.)
	local level = ExperienceService:GetLevel(player)
	local before = { DungeonProgress = snapshot.dungeonProgress, Level = snapshot.level }
	if dungeonId then
		local row = DungeonData[dungeonId]
		local name = if row and row.displayName then row.displayName else dungeonId
		-- Difficulties: the queue's rule (the next rank after your clears,
		-- under your Level's gate).
		local function playable(level_: number, progress: any): number
			local unlocked = dungeonProgress.getHighestUnlockedRank(progress, dungeonId)
			return math.min(unlocked, DifficultyData.HighestRankForPlayerLevel(level_))
		end
		local was = playable(snapshot.level, snapshot.dungeonProgress)
		local now = playable(level, profile.DungeonProgress)
		for rank = was + 1, now do
			table.insert(unlocks, string.format("%s unlocked in %s", DifficultyData.FromRank(rank), name))
		end
		-- The gear chest (Valencia's) rolls at your best clear there.
		local tierWas = GearChestData.TierFor(before, dungeonId)
		local tierNow = GearChestData.TierFor(profile, dungeonId)
		if tierNow ~= tierWas then
			table.insert(unlocks, string.format("Stronger %s Gear Chest (%s)", name, tierNow))
		end
		if GearChestData.LegendaryOpen(profile, dungeonId) and not GearChestData.LegendaryOpen(before, dungeonId) then
			table.insert(unlocks, string.format("Legendary gear in the %s Gear Chest", name))
		end
	end
	-- Dungeons opened by the new level.
	for id, row in DungeonData do
		if type(row) == "table" and type(row.unlockLevel) == "number" and row.unlockLevel > snapshot.level then
			if row.unlockLevel <= level and id ~= dungeonId then
				table.insert(unlocks, string.format("%s unlocked", row.displayName or tostring(id)))
			end
		end
	end
	-- Relics the new levels unlocked (RelicUnlockData.ByLevel, 2026-11-08).
	for _, relicName in relicUnlocks.unlockedBetween(snapshot.level, level) do
		table.insert(unlocks, string.format("New relic: %s", relicName))
	end
	return quests, unlocks
end

-- One player's summary, as the client draws it.
function RunSummaryService._build(self: typeof(RunSummaryService), player: Player, cleared: boolean)
	local record = self:_record(player)
	local profile = DataService:GetProfileData(player) or {}
	local snapshot = record.snapshot

	local dungeonService = Blitz.OptionalService("DungeonService")
	local dungeon = dungeonService and dungeonService:GetActiveDungeon()
	local run = dungeonService and dungeonService:GetRun()
	local dungeonRow = dungeon and DungeonData[dungeon.id]
	local stats = Blitz.OptionalService("RoundStatisticsService")

	local gold, crystals, exp = 0, 0, 0
	if snapshot then
		gold = math.max((profile[CurrencyTypes.Gold] or 0) - snapshot.gold, 0)
		crystals = math.max((profile[CurrencyTypes.ArcaneCrystals] or 0) - snapshot.crystals, 0)
		exp = expGained(snapshot, ExperienceService:GetLevel(player), ExperienceService:GetCurrentExp(player))
	end

	-- The build: the relics held and the equipped spells.
	local relics = {}
	local relicService = Blitz.OptionalService("RelicService")
	if relicService then
		for name, count in relicService:GetRelicsRegistry(player) do
			if type(count) == "number" and count > 0 then
				table.insert(relics, name)
			end
		end
		table.sort(relics)
	end
	local spells = {}
	for _, entry in arcaneIndex.getOwnedArray(profile) do
		if type(entry) == "table" and type(entry.equipSlot) == "number" and entry.equipSlot > 0 then
			table.insert(spells, entry.name)
		end
	end

	local friendBonus = player:GetAttribute(Attributes.FriendBonus)
	local damageService = Blitz.OptionalService("DamageService")
	local dealt, taken = 0, 0
	if damageService then
		dealt, taken = damageService:GetRunDamage(player)
	end
	local quests, unlocks = self:_progress(player, profile, snapshot, if dungeon then dungeon.id else nil)

	-- The party (2026-11-08): everyone in this server (one run's party),
	-- kills and damage dealt side by side; the client marks the MVP.
	local party = {}
	for _, member in Players:GetPlayers() do
		local memberDealt = if damageService then (damageService:GetRunDamage(member)) else 0
		table.insert(party, {
			userId = member.UserId,
			name = member.DisplayName,
			kills = if stats then stats:GetTotalKillsAndAssists(member) else 0,
			damageDealt = math.floor(memberDealt),
		})
	end
	return {
		cleared = cleared,
		dungeon = if dungeonRow and dungeonRow.displayName then dungeonRow.displayName else "Dungeon",
		difficulty = if run and type(run.difficulty) == "string" then run.difficulty else "",
		seconds = if self._runStartedAt then math.max(math.floor(GameClock.Now() - self._runStartedAt), 0) else 0,
		kills = if stats then stats:GetTotalKillsAndAssists(player) else 0,
		damageDealt = math.floor(dealt),
		damageTaken = math.floor(taken),
		corruptedKills = record.corruptedKills,
		relicCount = #relics,
		gearCount = record.gearCount,
		gold = gold,
		crystals = crystals,
		exp = exp,
		friendBonus = if type(friendBonus) == "number" then friendBonus else 0,
		gear = record.gear,
		relics = relics,
		spells = spells,
		quests = quests,
		unlocks = unlocks,
		party = party,
		me = player.UserId,
		autoContinue = AUTO_CONTINUE_SECONDS,
	}
end

-- Shows `player` their summary. `onClose` runs once, on Continue or the
-- timeout. A clear banks the run loot first, so the rewards are final.
function RunSummaryService.Open(self: typeof(RunSummaryService), player: Player, cleared: boolean, onClose: (() -> ())?)
	local record = self:_record(player)
	if record.open then
		return
	end
	record.open = true
	record.onClose = onClose
	if cleared then
		local escrow = Blitz.OptionalService("RunEscrowService")
		if escrow then
			escrow:ClaimRewards(player)
		end
	end
	local ok, json = pcall(HttpService.JSONEncode, HttpService, self:_build(player, cleared))
	if not ok then
		warn("[RunSummaryService] Could not encode the summary: " .. tostring(json))
		self:_close(player)
		return
	end
	DungeonNetwork.RunSummaryShow.Fire(player, json)
	task.delay(AUTO_CONTINUE_SECONDS + 1, function()
		if self._records[player] == record and record.open then
			self:_close(player)
		end
	end)
end

-- A preview of `player`'s summary (the /summary dev command): no banking,
-- no teleport, and it leaves the real one free to open later.
-- `partySize` (2-4) pads the party strip with mock teammates (your own
-- avatar, random kills / damage) so a solo tester sees the co-op layout.
function RunSummaryService.Preview(
	self: typeof(RunSummaryService),
	player: Player,
	cleared: boolean,
	partySize: number?
)
	local summary = self:_build(player, cleared)
	local wanted = math.clamp(math.floor(partySize or 1), 1, 4)
	local mockNames = { "Teammate", "Partner", "Ally" }
	while #summary.party < wanted do
		local index = #summary.party
		table.insert(summary.party, {
			userId = player.UserId,
			name = mockNames[index] or ("Player " .. (index + 1)),
			kills = math.random(5, 60),
			damageDealt = math.random(500, 20000),
		})
	end
	-- Nothing is banked in a preview: add the loot still in the escrow, so
	-- it reads as the real one would (before the Store / friend bonus).
	local escrow = Blitz.OptionalService("RunEscrowService")
	if escrow then
		summary.gold += escrow:GetCoins(player) or 0
		summary.crystals += escrow:GetArcaneCrystals(player) or 0
	end
	local ok, json = pcall(HttpService.JSONEncode, HttpService, summary)
	if ok then
		DungeonNetwork.RunSummaryShow.Fire(player, json)
	end
end

-- The summary was closed (or never shown): a later exit-gate press goes on.
function RunSummaryService.HasClosed(self: typeof(RunSummaryService), player: Player): boolean
	local record = self._records[player]
	return record ~= nil and record.closed == true
end

function RunSummaryService.IsOpen(self: typeof(RunSummaryService), player: Player): boolean
	local record = self._records[player]
	return record ~= nil and record.open == true
end

function RunSummaryService._close(self: typeof(RunSummaryService), player: Player)
	local record = self._records[player]
	if not record or not record.open then
		return
	end
	record.open = false
	record.closed = true
	local onClose = record.onClose
	record.onClose = nil
	if onClose then
		task.spawn(onClose)
	end
end

function RunSummaryService.Start(self: typeof(RunSummaryService))
	DataService.Signals.OnPlayerDataLoaded:Connect(function(player: Player)
		self:_snapshot(player)
	end)
	for _, player in Players:GetPlayers() do
		if DataService:GetProfileData(player) then
			self:_snapshot(player)
		end
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		self._records[player] = nil
	end)

	-- The run clock: the first floor ready.
	local dungeonService = Blitz.OptionalService("DungeonService")
	if dungeonService and dungeonService.Signals and dungeonService.Signals.OnFloorReady then
		dungeonService.Signals.OnFloorReady:Connect(function()
			if self._runStartedAt == nil then
				self._runStartedAt = GameClock.Now()
			end
		end)
	end

	local stats = Blitz.OptionalService("RoundStatisticsService")
	if stats and stats.Signals and stats.Signals.OnCorruptedKill then
		stats.Signals.OnCorruptedKill:Connect(function(player: Player)
			local record = self:_record(player)
			record.corruptedKills += 1
		end)
	end

	DungeonNetwork.RunSummaryContinue.On(function(player: Player)
		self:_close(player)
	end)

	-- A wipe: everyone's DEFEATED summary once the game-over beat has played.
	-- Continue teleports that player; LifeService's wipe teleport takes the
	-- rest when it fires.
	local lifeService = Blitz.OptionalService("LifeService")
	if lifeService and lifeService.OnPartyWiped then
		lifeService.OnPartyWiped:Connect(function()
			task.delay(WIPE_SUMMARY_DELAY, function()
				for _, player in Players:GetPlayers() do
					self:Open(player, false, function()
						local life = Blitz.OptionalService("LifeService")
						if life and player.Parent == Players then
							life:TeleportPlayerToLobby(player)
						end
					end)
				end
			end)
		end)
	end
end

return RunSummaryService
