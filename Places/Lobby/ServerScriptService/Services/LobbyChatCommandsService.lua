--!strict
--[[
	Module: LobbyChatCommandsService.lua
	Description:
	Slash commands for the LOBBY place. Same anatomy as the Dungeons place's
	ChatCommandsService (the registry below is the one home; a new command is
	a new row), kept separate because the two places share no commands: the
	Dungeons set drives run systems that do not exist here.

	EVERY command needs a member of the game's group at
	Constants.COMMAND_MIN_GROUP_RANK (250) or above (2026-10-24), the same
	gate the Dungeons place's commands use -- in Studio too (2026-10-27).
	`_canRun` is the one permission seam.

	    /<command> <arg1> <arg2> ...   -- name + args lowercased; unknown
	                                      commands are ignored silently

	--- /wipedata ---

	Resets YOUR profile to the template (DataService:WipeProfileData) and
	kicks you a beat later so every service that cached state off the load
	rebuilds from the fresh profile on rejoin. Same command as the Dungeons
	place's; the Lobby is where a fresh start is usually wanted.

	--- /level <level> ---

	Sets YOUR level (ExperienceService:SetLevel), with 0 EXP into it.

	--- /gold [amount] ---

	Adds Gold to YOUR profile through CurrencyService (the same write the
	shop and the chests use, so the UI updates at once). Default 1000;
	a negative amount takes Gold away, never below 0.

	--- /tp [dungeon] [difficulty] ---

	A TEST stand-in for the hub's queue. Reserves ONE private server of the
	named dungeon's place (DungeonData placeId) and teleports EVERY player in
	this lobby server into it together, carrying the same teleport data the
	queue will send: { partyLeaderUserId, Difficulty }. The
	dungeon server clamps that difficulty to the leader's unlocks.
	Defaults: Runegrove, Normal. The dungeon matches an id or the start of a
	display name ("/tp ember hard"). A second /tp while one is in flight is
	ignored (the first reservation is the party's). ReserveServer / TeleportAsync are unavailable in Studio
	and throw for an unpublished place, so both are pcall'd and the failure
	echoed back instead of killing the Chatted connection.
]]

--[ Roblox Services ]--

local Players = game:GetService("Players")
local GroupService = game:GetService("GroupService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")
local ServerScriptService = game:GetService("ServerScriptService")

--[ Imports ]--

local TextIndicatorService = require(ServerScriptService.Submodules.Core.Source.Services.TextIndicatorService)
local DataService = require(ServerScriptService.Submodules.Core.Source.Services.DataService)
local CurrencyService =
	require(ServerScriptService.Submodules.Core.Source.Services.DataService.SubServices.CurrencyService)
local ExperienceService =
	require(ServerScriptService.Submodules.Core.Source.Services.DataService.SubServices.ExperienceService)
local CurrencyTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.CurrencyTypes)
local DungeonData = require(ReplicatedStorage.Submodules.Core.Shared.Data.DungeonData)
local DungeonIds = require(ReplicatedStorage.Submodules.Core.Shared.Enums.DungeonIds)
local Difficulty = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Difficulty)
local InventoryType = require(ReplicatedStorage.Submodules.Core.Shared.Enums.InventoryType)

-- The spells the profile now has equipped, for the /wipedata reply. It
-- reads the WIPED profile, so it shows what this server's template holds:
-- an unexpected spell here means this server runs an older build.
local function describeEquippedArcane(player: Player): string
	local inventory = DataService:GetProfileData(player).Inventory
	local arcane = if type(inventory) == "table" then inventory[InventoryType.Arcane] else nil
	local equipped = {}
	if type(arcane) == "table" then
		for _, entry in arcane do
			if type(entry) == "table" and type(entry.equipSlot) == "number" and entry.equipSlot >= 3 then
				table.insert(equipped, ("%d: %s"):format(entry.equipSlot, tostring(entry.name)))
			end
		end
	end
	table.sort(equipped)
	return if #equipped > 0 then table.concat(equipped, ", ") else "none"
end

local Constants = require(ReplicatedStorage.Submodules.Core.Shared.Data.Constants)

--[ Constants ]--

local COMMAND_PREFIX = "/"
local FEEDBACK_COLOR = Color3.fromRGB(255, 228, 21)
-- How long a /tp holds the "in flight" latch before another may be issued.
local TELEPORT_RETRY_GRACE_SECONDS = 15
-- /wipedata: the reply gets this long on screen before the kick.
local WIPE_KICK_DELAY_SECONDS = 2
local WIPE_KICK_MESSAGE = "Your data has been wiped. Rejoin to start fresh."
-- /gold with no amount.
local DEFAULT_GOLD_AMOUNT = 1000
-- /level: the highest level it sets.
local MAX_SET_LEVEL = 200

-- /tp defaults when no argument names them.
local DEFAULT_TP_DUNGEON = DungeonIds.Runegrove
local DEFAULT_TP_DIFFICULTY = Difficulty.Normal

-- A dungeon id from an id or the start of a display name, case-insensitive.
local function matchDungeon(arg: string?): string?
	if not arg or arg == "" then
		return DEFAULT_TP_DUNGEON
	end
	local lowered = string.lower(arg)
	for id, config in DungeonData do
		if string.lower(id) == lowered or string.sub(string.lower(config.displayName), 1, #lowered) == lowered then
			return id
		end
	end
	return nil
end

-- A Difficulty value from its name, case-insensitive.
local function matchDifficulty(arg: string?): string?
	if not arg or arg == "" then
		return DEFAULT_TP_DIFFICULTY
	end
	for _, difficulty: string in Difficulty :: { [string]: string } do
		if string.lower(difficulty) == string.lower(arg) then
			return difficulty
		end
	end
	return nil
end

-- True while a party teleport is being reserved / issued.
local teleportInFlight = false

--[ Service ]--

local LobbyChatCommandsService = {
	Name = "LobbyChatCommandsService",
	Dependencies = { TextIndicatorService, DataService, CurrencyService, ExperienceService } :: { any },
}

--[ Registry ]--

local COMMANDS: { [string]: { usage: string, description: string, handler: (Player, { string }) -> string? } }
COMMANDS = {
	tp = {
		usage = "/tp [dungeon] [difficulty]",
		description = "Teleport EVERYONE here into one reserved server of a dungeon at EXACTLY that difficulty (no unlock / level clamp; test stand-in for the queue).",
		handler = function(player: Player, args: { string }): string?
			-- Any order: each word is a dungeon or a difficulty (`/tp hard`,
			-- `/tp runegrove hard`). Missing ones take the defaults.
			local dungeonId: string? = nil
			local difficulty: string? = nil
			for _, arg in args do
				local asDifficulty = matchDifficulty(arg)
				local asDungeon = if asDifficulty then nil else matchDungeon(arg)
				if asDifficulty then
					difficulty = asDifficulty
				elseif asDungeon then
					dungeonId = asDungeon
				else
					return ("Unknown dungeon or difficulty %q."):format(arg)
				end
			end
			dungeonId = dungeonId or matchDungeon(nil)
			difficulty = difficulty or matchDifficulty(nil)
			if not dungeonId or not difficulty then
				return "Usage: /tp [dungeon] [difficulty]"
			end
			local placeId = DungeonData[dungeonId].placeId

			if RunService:IsStudio() then
				return "Studio: teleports are unavailable here (TeleportAsync). Publish and test in a live server."
			end
			if teleportInFlight then
				return "A dungeon teleport is already in progress."
			end
			teleportInFlight = true

			-- One reservation for the whole party.
			local reserveOk, accessCode = pcall(function()
				return TeleportService:ReserveServer(placeId)
			end)
			if not reserveOk then
				teleportInFlight = false
				warn(("[LobbyChatCommands] /tp ReserveServer failed: %s"):format(tostring(accessCode)))
				return "Reserve failed: " .. tostring(accessCode)
			end

			local options = Instance.new("TeleportOptions")
			options.ReservedServerAccessCode = accessCode
			options:SetTeleportData({
				partyLeaderUserId = player.UserId,
				Difficulty = difficulty,
				-- Play exactly what was asked: the dungeon skips the unlock and
				-- player-level clamps, but only for a leader its own command
				-- check also allows (RunFlowService._resolveRunDifficulty).
				Unclamped = true,
			})

			local players = Players:GetPlayers()
			local ok, err = pcall(function()
				TeleportService:TeleportAsync(placeId, players, options)
			end)
			if not ok then
				teleportInFlight = false
				warn(("[LobbyChatCommands] /tp teleport failed: %s"):format(tostring(err)))
				return "Teleport failed: " .. tostring(err)
			end

			-- Released after a grace so a failed arrival (players bounced
			-- back) can retry; on success this server is empty anyway.
			task.delay(TELEPORT_RETRY_GRACE_SECONDS, function()
				teleportInFlight = false
			end)
			return ("Teleporting %d player(s) to %s (%s)..."):format(
				#players,
				DungeonData[dungeonId].displayName,
				difficulty
			)
		end,
	},
	gold = {
		usage = "/gold [amount]",
		description = "Adds Gold to YOUR profile (default 1000; negative takes it away).",
		handler = function(player: Player, args: { string }): string?
			local amount = if args[1] then tonumber(args[1]) else DEFAULT_GOLD_AMOUNT
			if not amount then
				return "Usage: /gold [amount]"
			end
			amount = math.floor(amount)
			if not DataService:GetProfileData(player) then
				return "Your profile isn't loaded yet -- try again in a moment."
			end
			local total = math.max(CurrencyService:GetCurrencyValue(player, CurrencyTypes.Gold) + amount, 0)
			CurrencyService:SetCurrencyValue(player, CurrencyTypes.Gold, total)
			return ("%+d Gold (now %d)."):format(amount, total)
		end,
	},
	level = {
		usage = "/level <level>",
		description = "Sets YOUR level (1 to 200), with 0 EXP into it.",
		handler = function(player: Player, args: { string }): string?
			local wanted = tonumber(args[1])
			if not wanted then
				return "Usage: /level <level>"
			end
			local level = ExperienceService:SetLevel(player, math.clamp(math.floor(wanted), 1, MAX_SET_LEVEL))
			if not level then
				return "Your profile isn't loaded yet -- try again in a moment."
			end
			return ("Level set to %d."):format(level)
		end,
	},
	wipedata = {
		usage = "/wipedata",
		description = "Wipes YOUR player data back to defaults and kicks you so it reloads.",
		handler = function(player: Player, _args: { string }): string?
			if not DataService then
				return "DataService is unavailable."
			end
			if not DataService:WipeProfileData(player) then
				return "Your profile isn't loaded yet -- try again in a moment."
			end

			-- Delayed so the reply below is visible; the kick's PlayerRemoved
			-- releases the profile and saves the wiped state.
			task.delay(WIPE_KICK_DELAY_SECONDS, function()
				if player:IsDescendantOf(Players) then
					player:Kick(WIPE_KICK_MESSAGE)
				end
			end)

			local equipped = describeEquippedArcane(player)
			return ("Data wiped (arcane %s). Kicking you so it reloads..."):format(equipped)
		end,
	},
	help = {
		usage = "/help",
		description = "List every command.",
		handler = function(_player: Player, _args: { string }): string?
			local lines = {}
			for _, command in COMMANDS do
				table.insert(lines, ("%s -- %s"):format(command.usage, command.description))
			end
			table.sort(lines)
			return table.concat(lines, "\n")
		end,
	},
}
-- Aliases: same handler, different spelling.
COMMANDS.dungeon = COMMANDS.tp
COMMANDS.dungeons = COMMANDS.tp

--[ Private ]--

-- Single permission seam: every command needs the game's group at
-- Constants.COMMAND_MIN_GROUP_RANK or above (the Dungeons place's gate),
-- in Studio too. The rank is read the way the Dungeons place reads it
-- (GroupService:GetGroupsAsync, a web call): pcall'd, and a failure
-- refuses (never grants).
function LobbyChatCommandsService._canRun(
	_self: typeof(LobbyChatCommandsService),
	player: Player,
	_commandName: string
): boolean
	local ok, groups = pcall(function()
		return GroupService:GetGroupsAsync(player.UserId)
	end)
	if not ok or typeof(groups) ~= "table" then
		warn(("[LobbyChatCommands] GetGroupsAsync failed for %s: %s"):format(player.Name, tostring(groups)))
		return false
	end
	for _, group in groups :: { any } do
		if group.Id == Constants.GROUP_ID then
			return (tonumber(group.Rank) or 0) >= Constants.COMMAND_MIN_GROUP_RANK
		end
	end
	return false
end

-- Echoes command feedback back to the caller: the floating indicator when
-- there is a live character, the server log always.
function LobbyChatCommandsService._reply(_self: typeof(LobbyChatCommandsService), player: Player, message: string)
	print(("[LobbyChatCommands] %s: %s"):format(player.Name, message))

	local character = player.Character
	local part = character
		and (character:FindFirstChild("Head") or character:FindFirstChild("HumanoidRootPart")) :: BasePart?
	if TextIndicatorService and part then
		TextIndicatorService:ShowIndicator(player, part, message, FEEDBACK_COLOR, true)
	end
end

-- Splits a raw chat message into (commandName, args). Nil when the message
-- isn't a command at all, so ordinary chat falls straight through.
local function parse(message: string): (string?, { string })
	if string.sub(message, 1, #COMMAND_PREFIX) ~= COMMAND_PREFIX then
		return nil, {}
	end

	local tokens = {}
	for token in string.gmatch(string.sub(message, #COMMAND_PREFIX + 1), "%S+") do
		table.insert(tokens, string.lower(token))
	end

	local commandName = table.remove(tokens, 1)
	return commandName, tokens
end

function LobbyChatCommandsService.HandleMessage(self: typeof(LobbyChatCommandsService), player: Player, message: string)
	local commandName, args = parse(message)
	if not commandName then
		return
	end

	local command = COMMANDS[commandName]
	if not command then
		return -- unknown command: stay silent, it may just be normal chat
	end

	if not self:_canRun(player, commandName) then
		self:_reply(player, ("You can't use %s."):format(COMMAND_PREFIX .. commandName))
		return
	end

	-- pcall'd: a broken command must never kill the Chatted connection for
	-- the rest of the session.
	local ok, result = pcall(command.handler, player, args)
	if not ok then
		warn(("[LobbyChatCommandsService] /%s errored: %s"):format(commandName, tostring(result)))
		self:_reply(player, ("%s failed."):format(COMMAND_PREFIX .. commandName))
		return
	end

	if type(result) == "string" and result ~= "" then
		self:_reply(player, result)
	end
end

--[ Lifecycle ]--

function LobbyChatCommandsService.Start(self: typeof(LobbyChatCommandsService))
	local function bind(player: Player)
		player.Chatted:Connect(function(message: string)
			self:HandleMessage(player, message)
		end)
	end

	Players.PlayerAdded:Connect(bind)
	for _, player in Players:GetPlayers() do
		bind(player)
	end
end

return LobbyChatCommandsService
