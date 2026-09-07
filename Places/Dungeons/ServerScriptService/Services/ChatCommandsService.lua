--[[
	Module: ChatCommandsService.lua
	Description:
	The ONE home for slash commands. Every command lives in the COMMANDS
	registry below -- adding one is a new row, never a new listener and never
	a new `if` in some other service.

	Currently open to EVERY player (this is a dev/playtest convenience). If
	that ever needs restricting, gate it in one place: `_canRun` below.

	--- ANATOMY ---

	A chat message is parsed as:
	    /<command> <arg1> <arg2> ...
	The command name and its arguments are lowercased; unknown commands are
	ignored silently so ordinary chat containing a slash never spams anyone.

	COMMANDS[name] = {
	    usage       -- shown by /help
	    description
	    handler(player, args) -> string?   -- returned string is echoed back
	                                          to the caller as feedback
	}

	--- /drop ---

	`/drop <thing> [count]` runs a DROP_TARGETS entry `count` times across
	EVERY player in the server. `count` defaults to 1 and is clamped to
	MAX_DROP_COUNT so a typo ("/drop vendingmachine 9999") can't wedge the
	server.

	Adding a future drop target is one row in DROP_TARGETS -- give it any
	number of aliases and a `drop()` that performs a SINGLE wave. The command
	handles repetition, staggering, clamping, aliasing and feedback for you.

	--- /wipedata ---

	Resets the CALLER's own profile to the DataTemplate defaults
	(DataService:WipeProfileData) and then kicks them after a short delay,
	so every service rebuilds from the fresh profile on rejoin instead of
	needing its own wipe path. Only ever touches the player who typed it.
]]

--[ Roblox Services ]--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--[ Imports ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local EnemyTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.EnemyTypes)

local RelicMachineService
local EncounterChestService
local TextIndicatorService
local LifeService
local DataService
local CoffinEventService

--[ Constants ]--

local COMMAND_PREFIX = "/"

-- Upper bound on any /drop repetition. Purely a footgun guard: the command
-- is open to everyone, and spawning hundreds of models in one frame would
-- stall the server for the whole party.
local MAX_DROP_COUNT = 25

-- Pause between individual drops so a multi-drop wave spreads over a few
-- frames instead of spiking in one. Matches the cadence RelicMachineService
-- already uses when it drops a machine per player on segment clear.
local DROP_STAGGER_SECONDS = 0.25

local FEEDBACK_COLOR = Color3.fromRGB(120, 200, 255)

-- /wipedata: the wipe lands immediately; the kick waits this long so the
-- feedback indicator is readable before the player is dropped. Leaving
-- releases the profile, which is what persists the wiped data.
local WIPE_KICK_DELAY_SECONDS = 2
local WIPE_KICK_MESSAGE = "Your data has been wiped. Rejoin to start fresh."

--[ Service ]--

local ChatCommandsService = Knit.CreateService({
	Name = "ChatCommandsService",
	Client = {},
})

--[ Drop targets ]--

-- Each entry performs ONE wave of its thing across every player. Repetition,
-- staggering and clamping are the /drop handler's job, not the target's.
local DROP_TARGETS = {
	VendingMachine = {
		aliases = { "vendingmachine", "vending", "machine", "relicmachine" },
		label = "vending machine",
		drop = function()
			for _, target in Players:GetPlayers() do
				if RelicMachineService then
					RelicMachineService:DropMachineOnPlayer(target)
				end
				task.wait(DROP_STAGGER_SECONDS)
			end
		end,
	},
	-- Encounter reward chests, minus the encounter. The mob-name string
	-- feeds the coin row (ZombieData); Dungeon1's pair is used as the
	-- debug stand-in since there is no corpse to read — gear still
	-- rolls off the ACTIVE dungeon's own dungeonDrops table either way.
	MinibossChest = {
		aliases = { "minibosschest", "minichest", "mchest" },
		label = "miniboss chest",
		drop = function()
			if EncounterChestService then
				EncounterChestService:DropChestsForEncounter(EnemyTypes.Miniboss, "The Undead Brute")
			end
		end,
	},
	-- The Coffin's reward chest, minus the challenge. Coins come from the
	-- active difficulty's coffinEvent row (none outside a dungeon).
	EventChest = {
		aliases = { "eventchest", "echest", "coffinchest" },
		label = "event chest",
		drop = function()
			if CoffinEventService then
				CoffinEventService:DropRewardChests()
			end
		end,
	},
	BossChest = {
		aliases = { "bosschest", "bchest" },
		label = "boss chest",
		drop = function()
			if EncounterChestService then
				EncounterChestService:DropChestsForEncounter(EnemyTypes.Boss, "The Undead King")
			end
		end,
	},
	-- Same drop path as the vending machine; the `true` is the
	-- isRuneMachine flag (the machine component reads the MachineType
	-- attribute it stamps and dispenses runes instead of relics).
	RuneMachine = {
		aliases = { "runemachine", "rune", "runes" },
		label = "rune machine",
		drop = function()
			for _, target in Players:GetPlayers() do
				if RelicMachineService then
					RelicMachineService:DropMachineOnPlayer(target, true)
				end
				task.wait(DROP_STAGGER_SECONDS)
			end
		end,
	},
}

-- alias -> target, built once at load so lookup is O(1) and aliases can't
-- silently collide (a duplicate is a hard error at startup, not a mystery
-- later).
local dropAliases: { [string]: any } = {}
for name, target in DROP_TARGETS do
	for _, alias in target.aliases do
		assert(dropAliases[alias] == nil, ("[ChatCommandsService] duplicate drop alias '%s'"):format(alias))
		dropAliases[alias] = target
	end
	target.name = name
end

local function dropTargetNames(): string
	local names = {}
	for _, target in DROP_TARGETS do
		table.insert(names, target.aliases[1])
	end
	table.sort(names)
	return table.concat(names, ", ")
end

--[ Commands ]--

local COMMANDS
COMMANDS = {
	drop = {
		usage = "/drop <thing> [count]",
		description = "Drops <thing> on every player, [count] times (default 1).",
		handler = function(_player: Player, args: { string }): string?
			local targetName = args[1]
			if not targetName then
				return ("Usage: %s -- available: %s"):format(COMMANDS.drop.usage, dropTargetNames())
			end

			local target = dropAliases[targetName]
			if not target then
				return ("Unknown drop '%s' -- available: %s"):format(targetName, dropTargetNames())
			end

			-- Absent / unparseable count means one wave. math.floor keeps
			-- "/drop machine 2.7" sane rather than erroring.
			local count = math.clamp(math.floor(tonumber(args[2]) or 1), 1, MAX_DROP_COUNT)

			-- Spawned: the waves yield (DROP_STAGGER_SECONDS per player), and
			-- a chat handler must never block the chat pipeline.
			task.spawn(function()
				for _ = 1, count do
					target.drop()
				end
			end)

			return ("Dropping %d %s%s on all players."):format(count, target.label, if count == 1 then "" else "s")
		end,
	},

	revive = {
		usage = "/revive",
		description = "Revives every player currently in the death state.",
		handler = function(_player: Player, _args: { string }): string?
			if not LifeService then
				return "LifeService is unavailable."
			end

			-- Collected up front purely so the feedback line can say something
			-- truthful. LifeService:Revive already no-ops on anyone who is not
			-- in the death state, so filtering is not what keeps this safe.
			local down = {}
			for _, player in Players:GetPlayers() do
				if LifeService:IsDeathState(player) then
					table.insert(down, player)
				end
			end

			if #down == 0 then
				return "Nobody is down."
			end

			-- One thread EACH, not one thread for the loop: Revive yields for
			-- the whole fade -> teleport -> cutscene sequence, so a shared
			-- thread would make the last player wait out everyone else's
			-- cutscene before their own started. Spawning also keeps the chat
			-- pipeline unblocked, same as /drop.
			--
			-- Reviving the LAST downed player is what un-wipes the party:
			-- Revive clears the pending lobby teleport and the Game Over
			-- screen, so this works on a full party wipe, not just a partial.
			for _, player in down do
				task.spawn(function()
					LifeService:Revive(player)
				end)
			end

			return ("Reviving %d player%s."):format(#down, if #down == 1 then "" else "s")
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

			return "Data wiped. Kicking you so it reloads..."
		end,
	},

	help = {
		usage = "/help",
		description = "Lists every command.",
		handler = function(): string?
			local lines = {}
			for _name, command in COMMANDS do
				table.insert(lines, ("%s -- %s"):format(command.usage, command.description))
			end
			table.sort(lines)
			return table.concat(lines, "\n")
		end,
	},
}

--[ Private ]--

-- Single permission seam. Open to everyone today; restrict HERE if that
-- ever changes, so no individual command has to care.
function ChatCommandsService:_canRun(_player: Player, _commandName: string): boolean
	return true
end

-- Echoes command feedback back to the caller. Uses the same floating
-- indicator the rest of the game uses, so it needs a live character; the
-- server log always gets it regardless.
function ChatCommandsService:_reply(player: Player, message: string)
	print(("[ChatCommands] %s: %s"):format(player.Name, message))

	local character = player.Character
	local part = character and (character:FindFirstChild("Head") or character:FindFirstChild("HumanoidRootPart"))
	if TextIndicatorService and part then
		TextIndicatorService:ShowIndicator(player, part, message, FEEDBACK_COLOR, true)
	end
end

-- Splits a raw chat message into (commandName, args). Returns nil when the
-- message isn't a command at all, so ordinary chat falls straight through.
local function parse(message: string): (string?, { string })
	if string.sub(message, 1, #COMMAND_PREFIX) ~= COMMAND_PREFIX then
		return nil, {}
	end

	local tokens = {}
	-- %S+ rather than a plain split so runs of spaces collapse instead of
	-- producing empty arguments.
	for token in string.gmatch(string.sub(message, #COMMAND_PREFIX + 1), "%S+") do
		table.insert(tokens, string.lower(token))
	end

	local commandName = table.remove(tokens, 1)
	return commandName, tokens
end

function ChatCommandsService:HandleMessage(player: Player, message: string)
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
		warn(("[ChatCommandsService] /%s errored: %s"):format(commandName, tostring(result)))
		self:_reply(player, ("%s failed."):format(COMMAND_PREFIX .. commandName))
		return
	end

	if type(result) == "string" and result ~= "" then
		self:_reply(player, result)
	end
end

--[ Lifecycle ]--

function ChatCommandsService:KnitStart()
	RelicMachineService = Knit.GetService("RelicMachineService")
	EncounterChestService = Knit.GetService("EncounterChestService")
	TextIndicatorService = Knit.GetService("TextIndicatorService")
	LifeService = Knit.GetService("LifeService")
	DataService = Knit.GetService("DataService")
	CoffinEventService = Knit.GetService("CoffinEventService")

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

function ChatCommandsService:KnitInit() end

return ChatCommandsService
