--!strict
--[[
	Module: RelicGimmickService/Lib/relicTriggers
	Description:
	Which every-Nth relics are READY per player: their next melee swing or
	gun shot sets them off (2026-11-04, Shared/Data/RelicTriggerData). Each
	tree module reports its own relics after every count (set); this is the
	ONE writer of the character's Attributes.RelicTriggersReady, which every
	client draws the RelicTrigger glow from (RelicTriggerController).

	clearLane drops a lane's relics at once (the weapon was put away);
	clear drops everything (the player left or respawned).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local RelicTriggerData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicTriggerData)

local relicTriggers = {}

local ready: { [Player]: { [string]: boolean } } = {}

local function publish(player: Player)
	local character = player.Character
	if not character then
		return
	end
	local names = {}
	local set = ready[player]
	if set then
		for relicName in set do
			table.insert(names, relicName)
		end
	end
	table.sort(names)
	local value = if #names > 0 then table.concat(names, ",") else nil
	if character:GetAttribute(Attributes.RelicTriggersReady) ~= value then
		character:SetAttribute(Attributes.RelicTriggersReady, value)
	end
end

-- `relicName`'s next swing / shot triggers (`isReady`), or not.
function relicTriggers.set(player: Player, relicName: string, isReady: boolean)
	local set = ready[player]
	if isReady then
		if not set then
			set = {}
			ready[player] = set
		end
		if set[relicName] then
			return
		end
		set[relicName] = true
	else
		if not set or not set[relicName] then
			return
		end
		set[relicName] = nil
	end
	publish(player)
end

-- Every relic of `lane` no longer ready.
function relicTriggers.clearLane(player: Player, lane: RelicTriggerData.Lane)
	local set = ready[player]
	if not set then
		return
	end
	local changed = false
	for relicName in set do
		if RelicTriggerData.Lanes[relicName] == lane then
			set[relicName] = nil
			changed = true
		end
	end
	if changed then
		publish(player)
	end
end

function relicTriggers.clear(player: Player)
	ready[player] = nil
	publish(player)
end

return relicTriggers
