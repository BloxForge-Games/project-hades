--!strict
--[[
	Module: DropPickupSweepController.lua
	Description:
	ONE pickup sweep for every coin and orb on the floor. Each Drop
	component used to run a workspace:GetPartBoundsInRadius plus a relic
	registry lookup on EVERY Heartbeat for its whole lifetime, against an
	OverlapParams that had baked in whichever character existed when the
	drop was built (a respawn left it testing a dead body). A landed drop
	registers here instead; a single loop at PICKUP_SWEEP_HZ resolves the
	local character ONCE per tick, reads the Pot Of Gold count ONCE per
	tick, and tests every drop by plain distance from the root.

	The sweep only runs while something is registered: a thread starts on
	the first Register and exits once the registry empties.

	Registrations can arrive before Blitz has run any lifecycle (a
	component constructs the moment its tagged model streams in), so this
	module needs no Init / Start: the registry and the lazy loop are
	complete at require time.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RelicController = require(ReplicatedStorage.Controllers.RelicController)
local DropTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.DropTypes)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)

--[ Constants ]--

-- Sweep cadence. A drop is at most one tick late to notice the player
-- stepped into its radius, which at 10 Hz is under the coin's own
-- PICKUP_DELAY.
local PICKUP_SWEEP_HZ = 10
local PICKUP_SWEEP_INTERVAL = 1 / PICKUP_SWEEP_HZ

-- Pot Of Gold: these drop types are collected from ANY distance for owners
-- -- the proximity gate is skipped and the drop's own fly-to-player tween
-- runs from wherever it sits. Gear drops are deliberately absent: they
-- are a deliberate choice the player should walk to.
local COMPASS_DROP_TYPES = {
	[DropTypes.Coins] = true,
	[DropTypes.Health] = true,
	[DropTypes.Mana] = true,
	[DropTypes.SuperMana] = true,
}

--[ Types ]--

export type SweepConfig = {
	-- The part whose position is tested against the root.
	part: BasePart,
	-- Studs from the root within which the drop is collected.
	radius: number,
	-- Attributes.DropType, for the Pot Of Gold rule.
	dropType: string?,
	-- Runs ONCE, on the tick the drop is collected, with the root that
	-- collected it (the drop tweens toward it). The entry is removed
	-- before this runs.
	onPickup: (root: BasePart) -> (),
}

--[ Controller ]--

local DropPickupSweepController = {
	Name = "DropPickupSweepController",

	_drops = {} :: { [Instance]: SweepConfig },
	_count = 0,
	_thread = nil :: thread?,
}

--[ Private ]--

-- True when Pot Of Gold pulls compass-type drops in from any distance.
-- Reads the replicated relic registry, so it costs no round trip; a
-- registry not yet replicated simply falls back to the normal radius.
local function ownsPotOfGold(): boolean
	local owned = RelicController:GetRelicsFromUserId(Players.LocalPlayer.UserId)
	return owned ~= nil and (owned[RelicNames["Pot Of Gold"]] or 0) > 0
end

function DropPickupSweepController._sweep(self: typeof(DropPickupSweepController))
	-- Resolved per tick, never cached: this is what makes a respawned
	-- character collect, where the old per-drop filter kept the body it
	-- was built with.
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not (root and root:IsA("BasePart")) then
		return
	end
	local rootPosition = root.Position
	local potOfGold = ownsPotOfGold()

	-- Collected entries are gathered first and run after the walk, so a
	-- pickup callback that tears its component down never mutates the
	-- registry under the iteration.
	local collected: { SweepConfig } = {}
	for instance, config in self._drops do
		if not config.part.Parent then
			self:Unregister(instance)
			continue
		end
		local inRange = potOfGold and config.dropType ~= nil and COMPASS_DROP_TYPES[config.dropType] == true
		if not inRange then
			inRange = (config.part.Position - rootPosition).Magnitude <= config.radius
		end
		if inRange then
			table.insert(collected, config)
			self:Unregister(instance)
		end
	end

	for _, config in collected do
		config.onPickup(root)
	end
end

function DropPickupSweepController._ensureLoop(self: typeof(DropPickupSweepController))
	if self._thread then
		return
	end
	self._thread = task.spawn(function()
		while self._count > 0 do
			task.wait(PICKUP_SWEEP_INTERVAL)
			self:_sweep()
		end
		self._thread = nil
	end)
end

--[ Public ]--

-- Puts a landed drop into the sweep. Registering an instance already in
-- the sweep replaces its config.
function DropPickupSweepController.Register(
	self: typeof(DropPickupSweepController),
	instance: Instance,
	config: SweepConfig
)
	if not self._drops[instance] then
		self._count += 1
	end
	self._drops[instance] = config
	self:_ensureLoop()
end

-- Takes a drop out of the sweep (picked up, expired, destroyed). Safe to
-- call for an instance that was never registered.
function DropPickupSweepController.Unregister(self: typeof(DropPickupSweepController), instance: Instance)
	if not self._drops[instance] then
		return
	end
	self._drops[instance] = nil
	self._count = math.max(self._count - 1, 0)
end

return DropPickupSweepController
