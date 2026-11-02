--!strict
--[[
	Module: ChatCommandsService.lua
	Description:
	The ONE home for slash commands. Every command lives in the COMMANDS
	registry below -- adding one is a new row, never a new listener and never
	a new `if` in some other service.

	Only members of the game's group at Constants.COMMAND_MIN_GROUP_RANK
	(250) or above may run them, in Studio too (2026-10-27) -- except
	PUBLIC_COMMANDS (/wipedata, 2026-10-28), which anyone may run. The one
	gate is `_canRun` below.

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

	--- /level <level> ---

	Sets YOUR level (ExperienceService:SetLevel), with 0 EXP into it.

	--- /difficulty <easy|normal|hard|nightmare> ---

	Switches the RUN's difficulty in place (DungeonService run + the active
	floor's descriptor), re-stamps the relic level cap, rescales every
	living mob to the new tier's health (EnemyScalingService) and, in
	Studio, writes the DebugDifficulty workspace attribute so a restart
	keeps it. Mob damage, EXP, gear level range and rarity, chest payouts
	and the next floor's generation all read the live tier. The CURRENT
	floor's layout (its miniboss, floor count) is already built and stays.
	No argument reports the current tier.

	--- /bonusstat <StatKey percent | roll | clear> ---
	--- /enchant <name | roll | clear> ---

	Test edits to YOUR primary weapon's gear lines and enchantment (the
	Lobby has the same two). Each saves the inventory and then recomputes
	what reads it (PlayerStatsService) and re-instances the held weapon
	(WeaponLoadoutService), the Blacksmith's commit sequence, so the aura
	and the numbers change at once.

	--- /wipedata ---

	Resets the CALLER's own profile to the DataTemplate defaults
	(DataService:WipeProfileData) and then kicks them after a short delay,
	so every service rebuilds from the fresh profile on rejoin instead of
	needing its own wipe path. Only ever touches the player who typed it.
]]

--[ Roblox Services ]--

local GroupService = game:GetService("GroupService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

--[ Imports ]--

local RelicMachineService = require(ServerScriptService.Services.RelicMachineService)
local EncounterChestService = require(ServerScriptService.Services.EncounterChestService)
local TextIndicatorService = require(ServerScriptService.Submodules.Core.Source.Services.TextIndicatorService)
local LifeService = require(ServerScriptService.Services.LifeService)
local RunEscrowService = require(ServerScriptService.Services.RunEscrowService)
local DataService = require(ServerScriptService.Submodules.Core.Source.Services.DataService)
local CurrencyService =
	require(ServerScriptService.Submodules.Core.Source.Services.DataService.SubServices.CurrencyService)
local ExperienceService =
	require(ServerScriptService.Submodules.Core.Source.Services.DataService.SubServices.ExperienceService)
local CurrencyTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.CurrencyTypes)
local InventoryType = require(ReplicatedStorage.Submodules.Core.Shared.Enums.InventoryType)
local CoffinEventService = require(ServerScriptService.Services.CoffinEventService)
local EnemyTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.EnemyTypes)
local Constants = require(ReplicatedStorage.Submodules.Core.Shared.Data.Constants)
local RoomTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RoomTypes)
local RelicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicData)
local Blitz = require(ReplicatedStorage.Submodules.Core.Shared.Blitz)
local Difficulty = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Difficulty)
local DifficultyData = require(ReplicatedStorage.Submodules.Core.Shared.Data.DifficultyData)
local BonusStatData = require(ReplicatedStorage.Submodules.Core.Shared.Data.BonusStatData)
local rollBonusStats = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Inventory.rollBonusStats)
local EnchantmentData = require(ReplicatedStorage.Submodules.Core.Shared.Data.EnchantmentData)
local EnchantmentNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.EnchantmentNames)
local rollWeaponEnchantment =
	require(ReplicatedStorage.Submodules.Core.Shared.Functions.Inventory.rollWeaponEnchantment)
local PlayerStatsService = require(ServerScriptService.Submodules.Core.Source.Services.PlayerStatsService)
local WeaponLoadoutService = require(ServerScriptService.Submodules.Core.Source.Services.WeaponLoadoutService)

-- RunFlowService's Studio-only difficulty pick; /difficulty writes it so a
-- Studio restart replays the chosen tier.
local DEBUG_DIFFICULTY_ATTRIBUTE = "DebugDifficulty"

-- A Difficulty value from its name, case-insensitive.
local function matchDifficulty(arg: string?): string?
	if not arg then
		return nil
	end
	for _, difficulty: string in Difficulty :: { [string]: string } do
		if string.lower(difficulty) == string.lower(arg) then
			return difficulty
		end
	end
	return nil
end

local function difficultyNames(): string
	local names = {}
	for _, difficulty in DifficultyData.Order do
		table.insert(names, string.lower(difficulty))
	end
	return table.concat(names, "|")
end

-- RelicService requires half the place at load; reached on first use.
local function getRelicService(): any
	return (require :: any)(ServerScriptService.Services.RelicService)
end

-- A relic name squashed for matching typed input: lower case, letters and
-- digits only ("Dragon's Flame Sword" -> "dragonsflamesword").
local function relicKey(name: string): string
	return (string.gsub(string.lower(name), "[^%w]", ""))
end

-- The relic `query` names: an exact squashed match, else the ONE relic
-- whose squashed name starts with or contains it. Returns the name, or nil
-- and the candidates when it is ambiguous / unknown.
local function findRelic(query: string): (string?, { string })
	local wanted = relicKey(query)
	local starts, contains = {}, {}
	for name in RelicData do
		local key = relicKey(name)
		if key == wanted then
			return name, {}
		elseif string.sub(key, 1, #wanted) == wanted then
			table.insert(starts, name)
		elseif string.find(key, wanted, 1, true) then
			table.insert(contains, name)
		end
	end
	local pool = if #starts > 0 then starts else contains
	if #pool == 1 then
		return pool[1], {}
	end
	table.sort(pool)
	return nil, pool
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

local function enchantmentNames(): string
	local names = {}
	for _, row in EnchantmentData do
		table.insert(names, row.displayName)
	end
	table.sort(names)
	return table.concat(names, ", ")
end

-- [player] = their group rank, looked up ONCE per session (GetRankInGroup
-- is a web call). Weak keys: a leaver takes their entry with it.
local groupRankCache: { [Player]: number } = setmetatable({}, { __mode = "k" }) :: any

--[ Constants ]--

local COMMAND_PREFIX = "/"
-- /level: the highest level it sets.
local MAX_SET_LEVEL = 200
-- /give gold: one command can hand out at most this much.
local MAX_GIVE_GOLD = 1_000_000

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

local ChatCommandsService = {
	Name = "ChatCommandsService",
	Dependencies = {
		RelicMachineService,
		EncounterChestService,
		TextIndicatorService,
		LifeService,
		DataService,
		ExperienceService,
		CoffinEventService,
		PlayerStatsService,
		WeaponLoadoutService,
	} :: { any },
}

--[ Drop targets ]--

-- Each entry performs ONE wave of its thing across every player. Repetition,
-- staggering and clamping are the /drop handler's job, not the target's.
type DropTarget = {
	aliases: { string },
	label: string,
	drop: () -> (),
	name: string?,
}

local DROP_TARGETS: { [string]: DropTarget } = {
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
	-- feeds the coin row (MobData); Dungeon1's pair is used as the
	-- debug stand-in since there is no corpse to read — gear still
	-- rolls off the ACTIVE dungeon's own dungeonDrops table either way.
	MinibossChest = {
		aliases = { "minibosschest", "minichest", "mchest" },
		label = "miniboss chest",
		drop = function()
			if EncounterChestService then
				EncounterChestService:DropChestsForEncounter(EnemyTypes.Miniboss, "Runic Executioner")
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
				EncounterChestService:DropChestsForEncounter(EnemyTypes.Boss, "Nine Tailed Beast")
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

type Command = {
	usage: string,
	description: string,
	handler: (player: Player, args: { string }) -> string?,
}

local COMMANDS: { [string]: Command }
COMMANDS = {
	fight = {
		usage = "/fight [miniboss|boss]",
		description = "Teleports everyone into this floor's miniboss (default) or boss fight and starts it.",
		handler = function(_player: Player, args: { string }): string?
			local which = args[1] or "miniboss"
			local kind = if which == "boss"
				then RoomTypes.Boss
				elseif which == "miniboss" or which == "mini" then RoomTypes.Miniboss
				else nil
			if not kind then
				return ("Usage: %s"):format(COMMANDS.fight.usage)
			end
			-- Required at call time: EncounterService sits deep in the
			-- dungeon cluster, and this debug path is its only use here.
			local EncounterService = require(ServerScriptService.Services.EncounterService) :: any
			return EncounterService:DebugStartEncounter(kind)
		end,
	},
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

	give = {
		usage = "/give <gems|gold|ore> <amount>",
		description = "gems: the run currency (escrow). gold / ore: straight into YOUR profile, for the Blacksmith.",
		handler = function(player: Player, args: { string }): string?
			local what = args[1] and string.lower(args[1])
			local amount = math.floor(tonumber(args[2]) or 0)
			if amount <= 0 then
				return ("Usage: %s -- amount must be a positive number"):format(COMMANDS.give.usage)
			end
			amount = math.min(amount, MAX_GIVE_GOLD)
			if what == "gems" then
				if not RunEscrowService then
					return "RunEscrowService is unavailable."
				end
				-- The run currency: what the shop and the Relic Slot stand
				-- spend; gone when the run ends.
				RunEscrowService:AddGems(player, amount)
				return ("Gave you %d Gems (now %d)."):format(amount, RunEscrowService:GetGems(player))
			elseif what == "gold" or what == "crystals" or what == "ore" then
				-- PROFILE currencies: Gold (the Blacksmith's) and Arcane
				-- Crystals (the Arcane Trainer's; "ore" is the old name).
				if not CurrencyService then
					return "CurrencyService is unavailable."
				end
				local currency = if what == "gold" then CurrencyTypes.Gold else CurrencyTypes.ArcaneCrystals
				CurrencyService:SetCurrencyValue(
					player,
					currency,
					CurrencyService:GetCurrencyValue(player, currency) + amount
				)
				return ("Gave you %d %s (profile now %d)."):format(
					amount,
					currency,
					CurrencyService:GetCurrencyValue(player, currency)
				)
			end
			return ("Usage: %s"):format(COMMANDS.give.usage)
		end,
	},

	relic = {
		usage = "/relic <name> | /relic clear",
		description = "Grants yourself a relic by (partial) name, opening a slot if you are full; 'clear' removes all of yours.",
		handler = function(player: Player, args: { string }): string?
			local relicService = getRelicService()
			local query = table.concat(args, " ")
			if query == "" then
				return ("Usage: %s"):format(COMMANDS.relic.usage)
			end
			if query == "clear" then
				local removed = 0
				for name, count in relicService:GetRelicsRegistry(player) do
					if count > 0 then
						relicService:RemoveRelicsRegistry(player, name, count)
						removed += 1
					end
				end
				return ("Removed %d relic(s)."):format(removed)
			end
			local name, candidates = findRelic(query)
			if not name then
				if #candidates == 0 then
					return ("No relic matches '%s'."):format(query)
				end
				return ("'%s' matches %d relics: %s"):format(
					query,
					#candidates,
					table.concat(candidates, ", ", 1, math.min(#candidates, 6))
				)
			end
			if relicService:IsAtRelicCap(player) then
				relicService:SetRelicSlots(player, relicService:GetRelicSlots(player) + 1)
			end
			if relicService:AddRelicsRegistry(player, name, 1) then
				return ("Granted %s."):format(name)
			end
			return ("Could not grant %s (already owned, or no slot left)."):format(name)
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

	difficulty = {
		usage = "/difficulty [easy|normal|hard|nightmare]",
		description = "Switches the run's difficulty in place (mobs rescale; the current floor's layout stays).",
		handler = function(_player: Player, args: { string }): string?
			local dungeonService = Blitz.OptionalService("DungeonService")
			if not dungeonService then
				return "DungeonService is unavailable."
			end
			local run = dungeonService:GetRun()
			if not run then
				return "No run is active."
			end
			if not args[1] then
				return ("Difficulty is %s."):format(run.difficulty)
			end
			local wanted = matchDifficulty(args[1])
			if not wanted then
				return ("Usage: /difficulty <%s>"):format(difficultyNames())
			end
			if wanted == run.difficulty then
				return ("Difficulty is already %s."):format(wanted)
			end

			local previous = run.difficulty
			run.difficulty = wanted
			local active = dungeonService:GetActiveDungeon()
			if active then
				active.difficulty = wanted
			end
			-- SetRun re-stamps the relic level cap off the new tier.
			dungeonService:SetRun(run)
			if RunService:IsStudio() then
				workspace:SetAttribute(DEBUG_DIFFICULTY_ATTRIBUTE, wanted)
			end
			local scaling = Blitz.OptionalService("EnemyScalingService")
			if scaling then
				scaling:RescaleAll()
			end
			local tier = DifficultyData.Resolve(wanted)
			return ("Difficulty %s -> %s (enemy health x%.2f, grunts x%.2f more, damage x%.2f, gear L%d-%d). Living mobs rescaled; the floor's layout stays."):format(
				previous,
				wanted,
				tier.enemyHealth,
				tier.gruntHealth,
				tier.enemyDamage,
				tier.levelRange.min,
				tier.levelRange.max
			)
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

	-- The Lobby's /bonusstat, here too (2026-11-01) so a line can be tried
	-- against live mobs. Lines are the rolled map { [statKey] = fraction }
	-- (rollBonusStats); the key is matched ignoring case against
	-- BonusStatData's rows since the parser lowercases tokens.
	bonusstat = {
		usage = "/bonusstat <StatKey percent | roll | clear>",
		description = "Studio-only: sets a real gear line on YOUR primary weapon (e.g. /bonusstat CritChance 8), rerolls its lines for its rarity (roll), or clears them. Keys: the BonusStatData rows.",
		handler = function(player: Player, args: { string }): string?
			local target, inventory, reason = findPrimaryWeapon(player)
			if not target or not inventory then
				return reason
			end
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
				if string.lower(row.key) == first then
					key = row.key
				end
			end
			if not key then
				return "Unknown line. Keys: " .. table.concat(BonusStatData.Pool, ", ")
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

-- Commands ANYONE may run, rank or not (2026-10-28): /wipedata only ever
-- resets the caller's own profile.
local PUBLIC_COMMANDS: { [string]: boolean } = {
	wipedata = true,
}

--[ Private ]--

-- Single permission seam, so no individual command has to care: anyone
-- for PUBLIC_COMMANDS, else members
-- of the game's group at
-- Constants.COMMAND_MIN_GROUP_RANK or above. The rank is fetched once per
-- player and cached (GroupService:GetGroupsAsync is a web call); a failed lookup (no group id yet, web error) reads
-- as rank 0, so commands fail CLOSED.
function ChatCommandsService._canRun(_self: typeof(ChatCommandsService), player: Player, commandName: string): boolean
	if PUBLIC_COMMANDS[commandName] then
		return true
	end
	local rank = groupRankCache[player]
	if rank == nil then
		local ok, groups = pcall(function()
			return GroupService:GetGroupsAsync(player.UserId)
		end)
		rank = 0
		if ok and typeof(groups) == "table" then
			for _, group in groups :: { any } do
				if group.Id == Constants.GROUP_ID then
					rank = tonumber(group.Rank) or 0
					break
				end
			end
		end
		groupRankCache[player] = rank
	end
	return rank >= Constants.COMMAND_MIN_GROUP_RANK
end

-- Public form of the command gate: may `player` run debug commands (the
-- group rank). RunFlowService asks it before honouring a /tp
-- teleport's Unclamped flag, which arrives in client-settable TeleportData.
function ChatCommandsService.IsAuthorized(self: typeof(ChatCommandsService), player: Player): boolean
	return self:_canRun(player, "")
end

-- Echoes command feedback back to the caller. Uses the same floating
-- indicator the rest of the game uses, so it needs a live character; the
-- server log always gets it regardless.
function ChatCommandsService._reply(_self: typeof(ChatCommandsService), player: Player, message: string)
	print(("[ChatCommands] %s: %s"):format(player.Name, message))

	local character = player.Character
	local part = character
		and (character:FindFirstChild("Head") or character:FindFirstChild("HumanoidRootPart")) :: BasePart?
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

function ChatCommandsService.HandleMessage(self: typeof(ChatCommandsService), player: Player, message: string)
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

function ChatCommandsService.Start(self: typeof(ChatCommandsService))
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

return ChatCommandsService
