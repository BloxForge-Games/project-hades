--[[
	Module: LobbyChatCommandsService.lua
	Description:
	Slash commands for the LOBBY place. Same anatomy as the Dungeons place's
	ChatCommandsService (the registry below is the one home; a new command is
	a new row), kept separate because the two places share no commands: the
	Dungeons set drives run systems that do not exist here.

	Open to EVERY player today (dev / playtest convenience). Restrict in
	`_canRun` if that ever changes.

	    /<command> <arg1> <arg2> ...   -- name + args lowercased; unknown
	                                      commands are ignored silently

	--- /tp (aliases /dungeon, /dungeons) ---

	Reserves ONE private server of the Dungeons place
	(Constants.DUNGEONS_PLACE_ID) and teleports EVERY player in this lobby
	server into it together, so the party lands in the same instance. A
	second /tp while one is in flight is ignored (the first reservation is
	the party's). ReserveServer / TeleportAsync are unavailable in Studio
	and throw for an unpublished place, so both are pcall'd and the failure
	echoed back instead of killing the Chatted connection.
]]

--[ Roblox Services ]--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")

--[ Imports ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local Constants = require(ReplicatedStorage.Submodules.Core.Shared.Data.Constants)

local TextIndicatorService

--[ Constants ]--

local COMMAND_PREFIX = "/"
local FEEDBACK_COLOR = Color3.fromRGB(255, 228, 21)
-- How long a /tp holds the "in flight" latch before another may be issued.
local TELEPORT_RETRY_GRACE_SECONDS = 15

-- True while a party teleport is being reserved / issued.
local teleportInFlight = false

--[ Service ]--

local LobbyChatCommandsService = Knit.CreateService({
	Name = "LobbyChatCommandsService",
	Client = {},
})

--[ Registry ]--

local COMMANDS: { [string]: { usage: string, description: string, handler: (Player, { string }) -> string? } }
COMMANDS = {
	tp = {
		usage = "/tp",
		description = "Teleport EVERYONE here into one reserved Dungeons server.",
		handler = function(player: Player, _args: { string }): string?
			if RunService:IsStudio() then
				return "Studio: teleports are unavailable here (TeleportAsync). Publish and test in a live server."
			end
			if teleportInFlight then
				return "A dungeon teleport is already in progress."
			end
			teleportInFlight = true

			-- One reservation for the whole party.
			local reserveOk, accessCode = pcall(function()
				return TeleportService:ReserveServer(Constants.DUNGEONS_PLACE_ID)
			end)
			if not reserveOk then
				teleportInFlight = false
				warn(("[LobbyChatCommands] /tp ReserveServer failed: %s"):format(tostring(accessCode)))
				return "Reserve failed: " .. tostring(accessCode)
			end

			local options = Instance.new("TeleportOptions")
			options.ReservedServerAccessCode = accessCode
			options:SetTeleportData({ partyLeaderUserId = player.UserId })

			local players = Players:GetPlayers()
			local ok, err = pcall(function()
				TeleportService:TeleportAsync(Constants.DUNGEONS_PLACE_ID, players, options)
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
			return ("Teleporting %d player(s) to a reserved Dungeons server..."):format(#players)
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

-- Single permission seam. Open to everyone today; restrict HERE if that
-- ever changes, so no individual command has to care.
function LobbyChatCommandsService:_canRun(_player: Player, _commandName: string): boolean
	return true
end

-- Echoes command feedback back to the caller: the floating indicator when
-- there is a live character, the server log always.
function LobbyChatCommandsService:_reply(player: Player, message: string)
	print(("[LobbyChatCommands] %s: %s"):format(player.Name, message))

	local character = player.Character
	local part = character and (character:FindFirstChild("Head") or character:FindFirstChild("HumanoidRootPart"))
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

function LobbyChatCommandsService:HandleMessage(player: Player, message: string)
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

function LobbyChatCommandsService:KnitStart()
	TextIndicatorService = Knit.GetService("TextIndicatorService")

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

function LobbyChatCommandsService:KnitInit() end

return LobbyChatCommandsService
