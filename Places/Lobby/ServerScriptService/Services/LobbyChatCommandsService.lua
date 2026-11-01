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
	gate the Dungeons place's commands use -- in Studio too (2026-10-27) --
	except PUBLIC_COMMANDS (/wipedata, 2026-10-28), which anyone may run.
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

	--- /gear [weapon|armor] [rarity] ---

	Puts ONE random piece of gear in YOUR bag (2026-11-01), built the way a
	dungeon drop is (GearDrop._buildInventoryEntry): a weapon always
	carries an enchantment (rollWeaponEnchantment.pick) and every piece
	rolls its gear lines for its rarity (rollBonusStats); the level is
	yours, so it equips. Defaults: a weapon, at a rarity drawn from
	Uncommon to Legendary so the lines always roll (ask for "common" to
	get none). A weapon whose data pins a rarity keeps it. A fresh uuid
	is not in profile.Seen, so the piece wears the bag's NEW tag.

	--- /bonusstat <StatKey percent | roll | clear> ---
	--- /enchant <name | roll | clear> ---

	Test edits to YOUR primary weapon's gear lines and enchantment (the
	Dungeons place has the same two). Each saves the inventory and then
	recomputes what reads it (PlayerStatsService) and re-instances the
	held weapon (WeaponLoadoutService), the Blacksmith's commit sequence,
	so the aura and the numbers change at once.

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

local HttpService = game:GetService("HttpService")
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
local dungeonProgress = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Dungeon.dungeonProgress)
local Difficulty = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Difficulty)
local InventoryType = require(ReplicatedStorage.Submodules.Core.Shared.Enums.InventoryType)
local BonusStatData = require(ReplicatedStorage.Submodules.Core.Shared.Data.BonusStatData)
local rollBonusStats = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Inventory.rollBonusStats)
local rollWeaponEnchantment =
	require(ReplicatedStorage.Submodules.Core.Shared.Functions.Inventory.rollWeaponEnchantment)
local ArmorPieceData = require(ReplicatedStorage.Submodules.Core.Shared.Data.ArmorPieceData)
local MeleeWeaponData = require(ReplicatedStorage.Submodules.Core.Shared.Data.MeleeWeaponData)
local RangedWeaponData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RangedWeaponData)
local EnchantmentNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.EnchantmentNames)
local ItemRarity = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ItemRarity)

-- /gear: the rarities it draws from when none is named (Common rolls no
-- gear lines, so it only comes when asked), and the scalar range a drop
-- rolls (GearDrop's SCALAR_MULTIPLIER_MIN / MAX).
local GEAR_RARITIES: { string } = {
	ItemRarity.Uncommon,
	ItemRarity.Rare,
	ItemRarity.Epic,
	ItemRarity.Legendary,
}
local GEAR_SCALAR_MIN = 0.5
local GEAR_SCALAR_MAX = 1

-- A rarity named by its start ("/gear epic", "/gear leg"), among the
-- five that gear rolls.
local function matchRarity(arg: string?): string?
	if not arg or arg == "" then
		return nil
	end
	for _, rarity in { ItemRarity.Common, ItemRarity.Uncommon, ItemRarity.Rare, ItemRarity.Epic, ItemRarity.Legendary } do
		if string.lower(rarity):sub(1, #arg) == arg then
			return rarity
		end
	end
	return nil
end

local EnchantmentData = require(ReplicatedStorage.Submodules.Core.Shared.Data.EnchantmentData)
local PlayerStatsService = require(ServerScriptService.Submodules.Core.Source.Services.PlayerStatsService)
local WeaponLoadoutService = require(ServerScriptService.Submodules.Core.Source.Services.WeaponLoadoutService)

-- The caller's PRIMARY weapon (equipSlot 1, else their first) and the
-- Inventory table it sits in, for /enchant and /bonusstat; nil and the
-- reply to give when there is none.
local function findPrimaryWeapon(player: Player): ({ [string]: any }?, { [string]: any }?, string?)
	local profile = DataService:GetProfileData(player)
	if next(profile) == nil then
		return nil, nil, "Your profile isn't loaded yet -- try again in a moment."
	end
	local inventory = profile.Inventory
	local weapons = if type(inventory) == "table" then inventory[InventoryType.Weapon] else nil
	if type(weapons) ~= "table" then
		return nil, nil, "You have no weapons."
	end
	local target = nil
	for _, item in weapons do
		if type(item) == "table" and item.equipSlot == 1 then
			target = item
		end
	end
	target = target or weapons[1]
	if type(target) ~= "table" then
		return nil, nil, "You have no weapons."
	end
	return target, inventory, nil
end

-- Saves an edited weapon and brings the live state in line with it, the
-- way BlacksmithService._commit does after an Imbue: the enchantment and
-- gear-line sums, the stat attributes, then the held model (its
-- Enchantment attribute is what the aura particles follow).
local function commitWeaponEdit(player: Player, inventory: { [string]: any })
	DataService:SetProfileValue(player, "Inventory", inventory)
	PlayerStatsService:RecomputeGearStats(player)
	PlayerStatsService:RecomputeStatAttributes(player)
	WeaponLoadoutService:SetWeaponLoadout(player)
end

-- An enchantment's stored key from its key or its shown name, ignoring
-- case ("frostbite" -> Frostburst, "corrosion" -> Blight).
local function matchEnchantment(arg: string): string?
	local lowered = string.lower(arg)
	for key, row in EnchantmentData do
		if string.lower(key) == lowered or string.lower(row.displayName) == lowered then
			return key
		end
	end
	return nil
end

-- The names of the weapons the data authors (both catalogues) and of the
-- armor pieces, sorted so a draw is reproducible to read.
local function catalogueNames(...: { [string]: any }): { string }
	local names = {}
	for _, catalogue in { ... } do
		for name in catalogue do
			table.insert(names, name)
		end
	end
	table.sort(names)
	return names
end

local function enchantmentNames(): string
	local names = {}
	for _, row in EnchantmentData do
		table.insert(names, row.displayName)
	end
	table.sort(names)
	return table.concat(names, ", ")
end

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
	Dependencies = {
		TextIndicatorService,
		DataService,
		CurrencyService,
		ExperienceService,
		PlayerStatsService,
		WeaponLoadoutService,
	} :: { any },
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
	mastery = {
		usage = "/mastery <dungeon> <xp>",
		description = "Adds Dungeon Mastery XP to YOUR dungeon (e.g. /mastery runegrove 5000); 0 resets it.",
		handler = function(player: Player, args: { string }): string?
			local dungeonId: string? = nil
			for _, id in DungeonIds :: { [string]: string } do
				if string.lower(id) == (args[1] or "") then
					dungeonId = id
				end
			end
			local xp = tonumber(args[2])
			if not dungeonId or not xp then
				return "Usage: /mastery <dungeon> <xp>"
			end
			local profile = DataService:GetProfileData(player)
			if next(profile) == nil then
				return "Your profile isn't loaded yet -- try again in a moment."
			end
			local progress = profile.DungeonProgress
			if type(progress) ~= "table" then
				progress = {}
			end
			if xp <= 0 then
				progress[dungeonId] = nil
				DataService:SetProfileValue(player, "DungeonProgress", progress)
				return ("%s Mastery reset."):format(dungeonId)
			end
			local before, after = dungeonProgress.addMasteryXp(progress, dungeonId, xp)
			DataService:SetProfileValue(player, "DungeonProgress", progress)
			return ("%s: +%d Mastery XP (level %d -> %d)."):format(dungeonId, xp, before, after)
		end,
	},
	gear = {
		usage = "/gear [weapon|armor] [rarity]",
		description = "Puts one random piece of gear in YOUR bag, built like a dungeon drop: a weapon always enchanted, gear lines rolled for its rarity (Uncommon to Legendary unless named), at your level.",
		handler = function(player: Player, args: { string }): string?
			local profile = DataService:GetProfileData(player)
			if next(profile) == nil then
				return "Your profile isn't loaded yet -- try again in a moment."
			end
			local inventory = profile.Inventory
			if type(inventory) ~= "table" then
				return "Your profile has no inventory."
			end

			-- Any order: each word is a kind or a rarity.
			local wantArmor = false
			local askedRarity: string? = nil
			for _, arg in args do
				if arg == "armor" or arg == "armour" then
					wantArmor = true
				elseif arg == "weapon" then
					wantArmor = false
				elseif matchRarity(arg) then
					askedRarity = matchRarity(arg)
				else
					return ("Unknown kind or rarity %q. Usage: /gear [weapon|armor] [rarity]"):format(arg)
				end
			end

			local names = if wantArmor
				then catalogueNames(ArmorPieceData)
				else catalogueNames(MeleeWeaponData, RangedWeaponData)
			if #names == 0 then
				return "No gear is authored."
			end
			local name = names[math.random(1, #names)]
			local data = if wantArmor then ArmorPieceData[name] else (MeleeWeaponData[name] or RangedWeaponData[name])

			-- A pinned rarity (a Legendary unique) wins; else the asked one;
			-- else a draw that always carries gear lines.
			local rarity = if type(data) == "table" and type(data.rarity) == "string"
				then data.rarity
				else askedRarity or GEAR_RARITIES[math.random(1, #GEAR_RARITIES)]
			local gearType = if wantArmor then "Armor" else "Weapon"
			local item: { [string]: any } = {
				uuid = HttpService:GenerateGUID(false),
				name = name,
				enchantment = if wantArmor then EnchantmentNames.None else rollWeaponEnchantment.pick(nil),
				rarity = rarity,
				level = math.max(ExperienceService:GetLevel(player), 1),
				upgrades = 0,
				scalarMultiplier = math.round(
					(GEAR_SCALAR_MIN + math.random() * (GEAR_SCALAR_MAX - GEAR_SCALAR_MIN)) * 100
				) / 100,
				bonusStats = rollBonusStats(gearType, rarity),
				shiny = false,
			}

			if wantArmor then
				local slot = if type(data) == "table" then data.slot else nil
				if type(slot) ~= "string" then
					return ("%s has no armor slot authored."):format(name)
				end
				item.equipped = false
				inventory[InventoryType.Gear] = if type(inventory[InventoryType.Gear]) == "table"
					then inventory[InventoryType.Gear]
					else {}
				local pieces = inventory[InventoryType.Gear][slot]
				if type(pieces) ~= "table" then
					pieces = {}
					inventory[InventoryType.Gear][slot] = pieces
				end
				table.insert(pieces, item)
			else
				item.equipSlot = 0
				local weapons = inventory[InventoryType.Weapon]
				if type(weapons) ~= "table" then
					weapons = {}
					inventory[InventoryType.Weapon] = weapons
				end
				table.insert(weapons, item)
			end
			DataService:SetProfileValue(player, "Inventory", inventory)

			local lines = {}
			for _, line in BonusStatData.Describe(item.bonusStats) do
				table.insert(lines, line.text)
			end
			return ("Gave %s %s%s (Lv %d): %s."):format(
				rarity,
				name,
				if item.enchantment ~= EnchantmentNames.None then " [" .. tostring(item.enchantment) .. "]" else "",
				item.level,
				if #lines > 0 then table.concat(lines, ", ") else "no gear lines"
			)
		end,
	},
	bonusstat = {
		usage = "/bonusstat <StatKey percent | roll | clear>",
		description = "Studio-only: sets a real gear line on YOUR primary weapon (e.g. /bonusstat CritChance 8), rerolls its lines for its rarity (roll), or clears them. Keys: the BonusStatData rows.",
		handler = function(player: Player, args: { string }): string?
			local target, inventory, reason = findPrimaryWeapon(player)
			if not target or not inventory then
				return reason
			end
			-- Lines are the rolled map { [statKey] = fraction } (2026-10-31,
			-- rollBonusStats); the key is matched ignoring case against
			-- BonusStatData's rows since the parser lowercases tokens.
			local first = string.lower(args[1] or "")
			if first == "" then
				return "Usage: /bonusstat <StatKey percent | roll | clear>"
			end
			if first == "clear" then
				target.bonusStats = {}
				commitWeaponEdit(player, inventory)
				return ("%s: gear lines cleared."):format(tostring(target.name))
			end
			if first == "roll" then
				target.bonusStats = rollBonusStats("Weapon", target.rarity)
				commitWeaponEdit(player, inventory)
				local texts = {}
				for _, line in BonusStatData.Describe(target.bonusStats) do
					table.insert(texts, line.text)
				end
				return ("%s: rolled %s."):format(
					tostring(target.name),
					if #texts > 0 then table.concat(texts, ", ") else "no lines"
				)
			end
			local key = nil
			for _, row in BonusStatData.Order do
				if string.lower(row.key) == first and row.slot == "Weapon" then
					key = row.key
				end
			end
			if not key then
				local keys = {}
				for _, k in BonusStatData.BySlot.Weapon do
					table.insert(keys, k)
				end
				return "Unknown weapon line. Keys: " .. table.concat(keys, ", ")
			end
			local percent = tonumber(args[2])
			if not percent then
				return ("Usage: /bonusstat %s <percent>"):format(key)
			end
			local stats = if type(target.bonusStats) == "table" then target.bonusStats else {}
			stats[key] = math.round(percent) / 100
			target.bonusStats = stats
			commitWeaponEdit(player, inventory)
			return ("%s: %s."):format(tostring(target.name), BonusStatData.Format(key, stats[key]))
		end,
	},
	enchant = {
		usage = "/enchant <name | roll | clear>",
		description = "Puts an enchantment on YOUR primary weapon by name (Enflamed, Frostbite, Stormcharged, Corrosion, Stonebound), rolls one from the drop pool (roll), or removes it (clear).",
		handler = function(player: Player, args: { string }): string?
			local target, inventory, reason = findPrimaryWeapon(player)
			if not target or not inventory then
				return reason
			end
			local first = args[1] or ""
			if first == "" then
				return "Usage: /enchant <name | roll | clear>"
			end
			local enchantment: string
			if first == "clear" then
				enchantment = EnchantmentNames.None
			elseif first == "roll" then
				enchantment = rollWeaponEnchantment.pick(nil)
			else
				local matched = matchEnchantment(first)
				if not matched then
					return "Unknown enchantment. Names: " .. enchantmentNames()
				end
				enchantment = matched
			end
			-- The same field the drop roll and the Blacksmith's Imbue write;
			-- the commit re-instances the held weapon so its aura follows.
			target.enchantment = enchantment
			commitWeaponEdit(player, inventory)
			if enchantment == EnchantmentNames.None then
				return ("%s: enchantment cleared."):format(tostring(target.name))
			end
			return ("%s: now %s."):format(tostring(target.name), EnchantmentData[enchantment].displayName)
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

-- Commands ANYONE may run, rank or not (2026-10-28): /wipedata only ever
-- resets the caller's own profile.
local PUBLIC_COMMANDS: { [string]: boolean } = {
	wipedata = true,
}

--[ Private ]--

-- Single permission seam: every command but PUBLIC_COMMANDS needs the game's group at
-- Constants.COMMAND_MIN_GROUP_RANK or above (the Dungeons place's gate),
-- in Studio too. The rank is read the way the Dungeons place reads it
-- (GroupService:GetGroupsAsync, a web call): pcall'd, and a failure
-- refuses (never grants).
function LobbyChatCommandsService._canRun(
	_self: typeof(LobbyChatCommandsService),
	player: Player,
	commandName: string
): boolean
	if PUBLIC_COMMANDS[commandName] then
		return true
	end
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
