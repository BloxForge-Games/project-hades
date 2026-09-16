--[[
	Module: Server/Services/RelicService/RelicAudit.lua
	Description:
	DEV TOOL. Re-checks the relic dataset for the drift that creeps in when a
	description is edited but its wiring isn't (or vice versa). Not required
	by any runtime path -- nothing requires this module in production.

	Run it from the Studio command bar:

	    require(game.ServerScriptService.Submodules.Core.Server.Services
	        .RelicService.RelicAudit).RunAll()

	Prints one line per problem, grouped by severity, and a PASS/FAIL summary.

	--- WHAT IT CHECKS (element-tree era) ---

	  1. Enum <-> data      every RelicNames entry has a RelicData entry and
	                        vice versa.
	  2. Required fields    name / rarity / tree / combo / archetype /
	                        description / color / callback all present, and
	                        `name` matches its key.
	  3. Vocabulary         tree is an ElementTrees value, combo a RelicCombo
	                        value, every `grants` entry a RelicTags value.
	                        A C / C2 relic must belong to a tree with a
	                        status+aura pair (never Neutral).
	  4. Pool shape         each element tree carries 5 Rare / 4 Epic /
	                        1 Legendary; Neutral carries the rest.
	  5. Runtime text       runtimeDescriptionCallback runs, returns a
	                        string, and leaves no unsubstituted %-holes.
	  6. Markup             description font tags are balanced.
	  7. Status coverage    every StatusConditions value has a
	                        StatusConditionData entry with the fields its
	                        DoT loop needs; redirect statuses carry their
	                        display names.
	  8. Runes              every RuneNames value has a RuneData entry with
	                        all three rarity tiers.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RelicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicData)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local RelicTags = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicTags)
local RelicCombo = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicCombo)
local ElementTrees = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ElementTrees)
local ElementTreeData = require(ReplicatedStorage.Submodules.Core.Shared.Data.ElementTreeData)
local ItemRarity = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ItemRarity)
local StatusConditions = require(ReplicatedStorage.Submodules.Core.Shared.Enums.StatusConditions)
local StatusConditionData = require(ReplicatedStorage.Submodules.Core.Shared.Data.StatusConditionData)
local RuneNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RuneNames)
local RuneData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RuneData)

local RelicAudit = {}

local REQUIRED_FIELDS = { "name", "rarity", "tree", "combo", "archetype", "description", "color", "callback" }

-- Expected per-tree rarity spread (the sheet's 5/4/1).
local TREE_EXPECTED = {
	[ItemRarity.Rare] = 5,
	[ItemRarity.Epic] = 4,
	[ItemRarity.Legendary] = 1,
}

local function valueSet(enum): { [string]: boolean }
	local set = {}
	for _, value in enum do
		set[value] = true
	end
	return set
end

function RelicAudit.Run(): (number, number)
	local problems, warnings = {}, {}
	local function problem(subject: string, message: string)
		table.insert(problems, ("  [FAIL] %-32s %s"):format(subject, message))
	end
	local function warn_(subject: string, message: string)
		table.insert(warnings, ("  [WARN] %-32s %s"):format(subject, message))
	end

	local tags = valueSet(RelicTags)
	local rarities = valueSet(ItemRarity)
	local trees = valueSet(ElementTrees)
	local combos = valueSet(RelicCombo)

	-- 1) enum <-> data
	for key, value in RelicNames do
		if RelicData[value] == nil then
			problem(tostring(key), "in RelicNames but has NO RelicData entry (can never be owned)")
		end
	end
	local nameSet = {}
	for _, value in RelicNames do
		nameSet[value] = true
	end
	for relicName in RelicData do
		if not nameSet[relicName] then
			problem(tostring(relicName), "in RelicData but NOT in RelicNames")
		end
	end

	-- Per-tree / per-rarity tallies for the pool-shape check.
	local treeCounts: { [string]: { [string]: number } } = {}

	for relicName, data in RelicData do
		-- 2) required fields
		for _, field in REQUIRED_FIELDS do
			if data[field] == nil then
				problem(relicName, ("missing required field `%s`"):format(field))
			end
		end
		if data.name ~= nil and data.name ~= relicName then
			problem(relicName, ("`name` is %q but the key is %q"):format(tostring(data.name), relicName))
		end
		if data.rarity ~= nil and not rarities[data.rarity] then
			problem(relicName, ("unknown rarity %q"):format(tostring(data.rarity)))
		end

		-- 3) vocabulary
		if data.tree ~= nil and not trees[data.tree] then
			problem(relicName, ("unknown tree %q"):format(tostring(data.tree)))
		end
		if data.combo ~= nil and not combos[data.combo] then
			problem(relicName, ("unknown combo tier %q"):format(tostring(data.combo)))
		end
		if data.combo ~= nil and data.combo ~= RelicCombo.NC then
			local treeData = data.tree and ElementTreeData[data.tree]
			if not treeData or not treeData.statusTag or not treeData.auraTag then
				problem(
					relicName,
					("combo %q needs a tree with a status/aura pair (tree is %q)"):format(
						tostring(data.combo),
						tostring(data.tree)
					)
				)
			end
		end
		if type(data.grants) == "table" then
			for _, tag in data.grants do
				if not tags[tag] then
					problem(relicName, ("`grants` contains unknown tag %q"):format(tostring(tag)))
				end
			end
		end

		if data.tree ~= nil and data.rarity ~= nil then
			local byRarity = treeCounts[data.tree]
			if not byRarity then
				byRarity = {}
				treeCounts[data.tree] = byRarity
			end
			byRarity[data.rarity] = (byRarity[data.rarity] or 0) + 1
		end

		-- 5) runtime description
		if data.runtimeDescriptionCallback ~= nil then
			if type(data.runtimeDescriptionCallback) ~= "function" then
				problem(relicName, "runtimeDescriptionCallback is not a function")
			else
				local ok, result = pcall(data.runtimeDescriptionCallback, nil)
				if not ok then
					warn_(
						relicName,
						("runtimeDescriptionCallback errored on a nil player: %s"):format(tostring(result))
					)
				elseif type(result) ~= "string" then
					problem(relicName, "runtimeDescriptionCallback did not return a string")
				elseif string.find(result, "%%[diouxXeEfgGqcs]") then
					problem(relicName, "runtime description still contains an UNSUBSTITUTED %-placeholder")
				end
			end
		end

		-- 6) markup balance
		if type(data.description) == "string" then
			local opens = select(2, string.gsub(data.description, "<font", ""))
			local closes = select(2, string.gsub(data.description, "</font>", ""))
			if opens ~= closes then
				problem(relicName, ("unbalanced font tags (%d open, %d close)"):format(opens, closes))
			end
		end
	end

	-- 4) pool shape
	for tree in ElementTreeData do
		if tree ~= ElementTrees.Neutral then
			local byRarity = treeCounts[tree] or {}
			for rarity, expected in TREE_EXPECTED do
				local got = byRarity[rarity] or 0
				if got ~= expected then
					warn_(tree, ("tree carries %d %s relics (sheet says %d)"):format(got, rarity, expected))
				end
			end
		end
	end

	-- 7) status coverage
	for _, status in StatusConditions do
		if status ~= StatusConditions.None and StatusConditionData[status] == nil then
			problem(tostring(status), "StatusConditions value has NO StatusConditionData entry")
		end
	end
	for status, config in StatusConditionData do
		if config.auraName == nil then
			problem(tostring(status), "status config missing `auraName`")
		end
		if config.duration == nil then
			problem(tostring(status), "status config missing `duration`")
		end
		if config.dotPercentOfMaxHealth ~= nil and config.tickInterval == nil then
			problem(tostring(status), "DoT status missing `tickInterval`")
		end
		if config.dotPercentOfMaxHealth ~= nil and config.dotTickCapPerLevel == nil then
			warn_(tostring(status), "DoT status has no `dotTickCapPerLevel` -- ticks are uncapped")
		end
		if config.stackLimit ~= nil and config.stackLimit < 1 then
			problem(tostring(status), "`stackLimit` below 1")
		end
	end

	-- 8) runes
	for _, runeName in RuneNames do
		local rune = RuneData[runeName]
		if not rune then
			problem(runeName, "RuneNames value has NO RuneData entry")
		else
			for _, rarity in { ItemRarity.Rare, ItemRarity.Epic, ItemRarity.Legendary } do
				if rune.effects[rarity] == nil then
					problem(runeName, ("rune missing its %s tier"):format(rarity))
				end
			end
		end
	end

	-- 9) grants <-> description agreement, and 10) conditional gating.
	--
	-- Both parse the CARD TEXT, because descriptions are the source of
	-- truth. Born from the 2026-08 audit that found 16 grants wrong by
	-- hand: relics whose text produced a mechanic without advertising it
	-- (takedown aura granters, self-enabling appliers) and relics
	-- advertising mechanics their rework had removed (the old aura-gated
	-- chance boosters) — the latter falsely unlocked gated relics the
	-- player could not use: dead offers.
	--
	-- Surface words per tag: the card says "Barrier" for Shield, "Blight"
	-- for Blighted, and conjugates statuses ("Burning", "Chilled").
	local TAG_WORDS: { [string]: { string } } = {
		[RelicTags.Burn] = { "Burn", "Burning", "Burns" },
		[RelicTags.Chill] = { "Chill", "Chilled", "Chilling", "Chills" },
		[RelicTags.Shock] = { "Shock", "Shocked", "Shocks" },
		[RelicTags.Poison] = { "Poison", "Poisoned", "Poisons" },
		[RelicTags.Shield] = { "Barrier", "Barriers", "Barriered", "Shield" },
		[RelicTags.Enflamed] = { "Enflamed" },
		[RelicTags.Frostburst] = { "Frostburst" },
		[RelicTags.Blighted] = { "Blighted", "Blight" },
		[RelicTags.Stormcharged] = { "Stormcharged" },
		[RelicTags.Stonebound] = { "Stonebound" },
	}
	-- A producer verb this close BEFORE the tag word means the card says
	-- the relic can CREATE the mechanic ("chance to apply Burn", "grant
	-- you Stonebound", "gain a +10% Barrier", "get Stonebound").
	local PRODUCER_VERBS = { "apply", "applies", "applying", "grant", "grants", "granting", "gain", "gains", "get" }
	local PRODUCER_WINDOW = 40

	local function stripMarkup(text: string): string
		return (text:gsub("<[^>]->", ""))
	end

	-- Does `sentence` (lowercased) say this tag gets PRODUCED?
	local function sentenceProduces(sentence: string, words: { string }): boolean
		for _, word in words do
			local lowered = word:lower()
			local from = 1
			while true do
				local wordStart = sentence:find("%f[%a]" .. lowered .. "%f[%A]", from)
				if not wordStart then
					break
				end

				-- Preposition guard: "to/against/on <word> enemies" is a
				-- TARGET-STATE adjective ("against Shocked enemies"), never
				-- production — even with a verb nearby ("GAIN +10% Crit
				-- Chance against Shocked enemies").
				local prefix = sentence:sub(math.max(1, wordStart - 10), wordStart - 1)
				local isTargetState = prefix:find("to %s*$") ~= nil
					or prefix:find("against %s*$") ~= nil
					or prefix:find("on %s*$") ~= nil

				if not isTargetState then
					-- "<word> chance" — "+10% Shock Chance" self-applier.
					if sentence:find("^%s*chance", wordStart + #lowered) then
						return true
					end
					-- Gerund-verb usage: "<word>ing enemies" acts ON enemies
					-- ("dealing damage and Burning enemies") = production.
					-- ("Chilling an already Chilled enemy" stays out — the
					-- object there is "an", not "enemies".)
					if lowered:sub(-3) == "ing" and sentence:find("^%s+enemies", wordStart + #lowered) then
						return true
					end
					for _, verb in PRODUCER_VERBS do
						local verbStart =
							sentence:find("%f[%a]" .. verb .. "%f[%A]", math.max(1, wordStart - PRODUCER_WINDOW))
						if verbStart and verbStart < wordStart and wordStart - verbStart <= PRODUCER_WINDOW then
							return true
						end
					end
				end
				from = wordStart + 1
			end
		end
		return false
	end

	for relicName, data in RelicData do
		local description = typeof(data.description) == "string" and stripMarkup(data.description) or ""
		local lowered = description:lower()

		local grantsSet: { [string]: boolean } = {}
		for _, tag in (data.grants or {}) :: { string } do
			grantsSet[tag] = true
		end
		local requiredSet: { [string]: boolean } = {}
		for _, tag in (data.requiredTags or {}) :: { string } do
			requiredSet[tag] = true
		end
		local treeData = data.tree and ElementTreeData[data.tree]
		local pairSet: { [string]: boolean } = {}
		if treeData then
			if treeData.statusTag then
				pairSet[treeData.statusTag] = true
			end
			if treeData.auraTag then
				pairSet[treeData.auraTag] = true
			end
		end

		for tag, words in TAG_WORDS do
			-- Which sentences produce this tag, per the card?
			local textProduces = false
			for sentence in lowered:gmatch("[^%.]+") do
				if sentenceProduces(sentence, words) then
					textProduces = true
					break
				end
			end

			-- 9a) The card says it produces the mechanic -> grants must say
			-- so too, or gated relics never unlock off this pickup.
			if textProduces and not grantsSet[tag] then
				problem(tostring(relicName), ("card produces %s but `grants` does not list it"):format(tag))
			end
			-- 9b) grants claims a mechanic the card never says it produces
			-- -> either the tag is stale (falsely unlocks gated relics: dead
			-- offers) or the card is missing a clause. A human call, so WARN.
			if grantsSet[tag] and not textProduces then
				warn_(tostring(relicName), ("`grants` lists %s but the card never says it produces it"):format(tag))
			end

			-- 10) Conditional dependency ("While X", "to/against X enemies",
			-- "your X") must be SATISFIABLE at offer time: self-produced
			-- (grants), explicitly gated (requiredTags), or covered by a C2
			-- tree-pair gate. "increased to ..." clauses are opportunistic
			-- bonuses on an unconditional base and exempt. A bare C does NOT
			-- satisfy a specific-half dependency — C passes on EITHER half,
			-- which is exactly how a dead relic gets offered.
			for _, word in words do
				local w = word:lower()
				for _, pattern in
					{
						"while [%a%s]-%f[%a]" .. w .. "%f[%A]",
						"to " .. w .. " enemies",
						"against " .. w .. " enemies",
						"on " .. w .. " enemies",
						"your " .. w .. "%f[%A]",
					}
				do
					local at = lowered:find(pattern)
					if at then
						local prefix = lowered:sub(math.max(1, at - 30), at)
						local exempt = prefix:find("increased") ~= nil
						local satisfied = grantsSet[tag]
							or requiredSet[tag]
							or (
								data.requiredTags == nil
								and data.requiredRelics == nil
								and data.combo == RelicCombo.C2
								and pairSet[tag]
							)
						if not exempt and not satisfied then
							problem(
								tostring(relicName),
								("card depends on %s (%s) with no gate: not in `grants`/`requiredTags`, no covering C2 pair — offerable while unusable"):format(
									tag,
									word
								)
							)
						end
						break
					end
				end
			end
		end
	end

	print("========== RELIC AUDIT ==========")
	local relicCount = 0
	for _ in RelicData do
		relicCount += 1
	end
	print(("relics: %d"):format(relicCount))

	if #problems > 0 then
		print(("\nPROBLEMS (%d)"):format(#problems))
		for _, line in problems do
			print(line)
		end
	end
	if #warnings > 0 then
		print(("\nWARNINGS (%d)"):format(#warnings))
		for _, line in warnings do
			print(line)
		end
	end
	if #problems == 0 and #warnings == 0 then
		print("\nPASS -- no problems found.")
	else
		print(("\n%d problem(s), %d warning(s)."):format(#problems, #warnings))
	end
	print("=================================")

	return #problems, #warnings
end

RelicAudit.RunAll = RelicAudit.Run

return RelicAudit
