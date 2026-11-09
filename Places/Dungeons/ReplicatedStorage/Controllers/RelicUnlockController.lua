--!strict
--[[
	Module: Controllers/RelicUnlockController.lua
	Description:
	Announces the LOCAL player's first discoveries (2026-11-06), read by
	diffing the profile snapshots (DataController), so no remote of its own:
	  * a relic picked up for the first time ever (profile.RelicProgress.Found
	    gains a name): "New Relic Discovered!";
	  * a monster met for the first time (profile.Codex.Monsters gains a
	    name): "New Monster Discovered!";
	  * a level reached that unlocks a relic (profile.Level rises past a
	    RelicUnlockData.ByLevel slot, 2026-11-08): "New Relic Unlocked!".
	    Earlier relics this was the only unlock path, so it announces again.
	The name stands out in colour: a relic in its rarity's (RarityColors), a
	monster in gold (MONSTER_NAME_COLOR).
	The first snapshot is the baseline: nothing already known is announced.
	RelicUnlockService pushes the first two at once when they happen;
	ExperienceService writes Level on a level up.
]]

--[ Roblox Services ]--

local ReplicatedStorage = game:GetService("ReplicatedStorage")

--[ Imports ]--

local DataController = require(ReplicatedStorage.Submodules.Core.Source.Controllers.DataController)
local NotificationColors = require(ReplicatedStorage.Submodules.Core.Shared.Data.NotificationColors)
local RarityColors = require(ReplicatedStorage.Submodules.Core.Shared.Data.RarityColors)
local RelicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicData)
local relicUnlocks = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Relic.relicUnlocks)
local UserNotificationSystem = require(ReplicatedStorage.Submodules.Core.Libraries.UserNotificationSystem).Controller

--[ Constants ]--

-- A monster's name in the toast (the relic palette's gold).
local MONSTER_NAME_COLOR = Color3.fromRGB(255, 170, 0)

--[ Module ]--

local RelicUnlockController = {
	Name = "RelicUnlockController",
	Dependencies = { DataController } :: { any },
	_knownRelics = nil :: { [string]: boolean }?,
	_knownMonsters = nil :: { [string]: boolean }?,
	_knownLevel = nil :: number?,
}

--[ Private ]--

local function namesIn(value: any): { [string]: boolean }
	local out = {}
	if type(value) == "table" then
		for name in value do
			if type(name) == "string" then
				out[name] = true
			end
		end
	end
	return out
end

-- `name` wrapped in a RichText colour, its markup characters escaped.
local function colored(name: string, color: Color3): string
	local safe = name:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
	return string.format(
		'<font color="rgb(%d,%d,%d)">%s</font>',
		math.round(color.R * 255),
		math.round(color.G * 255),
		math.round(color.B * 255),
		safe
	)
end

local function relicColor(relicName: string): Color3
	local data = RelicData[relicName]
	local color = data and (RarityColors :: any)[data.rarity]
	return if typeof(color) == "Color3" then color else MONSTER_NAME_COLOR
end

local function announce(title: string, text: string)
	UserNotificationSystem:ShowNotification({
		titleText = title,
		titleTextFont = Enum.Font.SourceSansBold :: any,
		titleTextColor3 = NotificationColors.Reward,
		titleTextTransparency = 0,
		text = text,
		textFont = Enum.Font.SourceSansBold :: any,
		textColor3 = Color3.fromRGB(255, 255, 255),
		textTransparency = 0,
		richText = true,
	})
end

function RelicUnlockController._onProfile(self: typeof(RelicUnlockController), profile: any)
	if type(profile) ~= "table" or next(profile) == nil then
		return
	end
	local progress = profile.RelicProgress
	local relics = namesIn(if type(progress) == "table" then progress.Found else nil)
	local monsters = namesIn(if type(profile.Codex) == "table" then profile.Codex.Monsters else nil)
	local level = tonumber(profile.Level) or 1
	local knownRelics, knownMonsters, knownLevel = self._knownRelics, self._knownMonsters, self._knownLevel
	self._knownRelics, self._knownMonsters, self._knownLevel = relics, monsters, level
	if not knownRelics or not knownMonsters or not knownLevel then
		return
	end
	for _, relicName in relicUnlocks.unlockedBetween(knownLevel, level) do
		announce(
			"New Relic Unlocked!",
			"Reaching level "
				.. tostring(relicUnlocks.unlockLevel(relicName) or level)
				.. " unlocked the Relic: "
				.. colored(relicName, relicColor(relicName))
				.. ". It can now appear in your runs!"
		)
	end
	for relicName in relics do
		if not knownRelics[relicName] then
			announce(
				"New Relic Discovered!",
				"You have discovered the Relic: "
					.. colored(relicName, relicColor(relicName))
					.. ", for the first time!"
			)
		end
	end
	for mobName in monsters do
		if not knownMonsters[mobName] then
			announce(
				"New Monster Discovered!",
				"You have discovered the Monster: " .. colored(mobName, MONSTER_NAME_COLOR) .. ", for the first time!"
			)
		end
	end
end

--[ Lifecycle ]--

function RelicUnlockController.Start(self: typeof(RelicUnlockController))
	DataController.Signals.OnProfileChanged:Connect(function(profile)
		self:_onProfile(profile)
	end)
	self:_onProfile(DataController:GetProfileData())
end

return RelicUnlockController
