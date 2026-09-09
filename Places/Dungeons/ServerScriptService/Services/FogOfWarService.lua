--[[
	Module: FogOfWarService.lua
	Description:
	FOG OF WAR for dungeon chunks. Without it a player can stand at a gate
	and read the next room's identity through the doorway → a shrine, a
	merchant, a boss arena — which drains every event's reveal and lets a
	party pre-plan around a room they have not earned yet.

	THE RULE:
	  * A chunk keeps its STRUCTURAL SHELL visible from the moment it is
	    placed (see STRUCTURE_NAMES): Floor, Wall, and its ExitGate. The
	    room reads as a room — you can see there is space ahead, and the
	    gate still reads as a closed door rather than an invisible wall.
	  * EVERYTHING else in the chunk is hidden at generation: props,
	    torches, traps, spawn markers, NPCs, interactables, their lights,
	    particles, prompts, sounds and GUIs.
	  * The FIRST player to enter the chunk reveals it for EVERYONE, with
	    a tween back to the authored look.

	PARTY-WIDE, SERVER-DRIVEN: reveal is one shared state, not a per-player
	view — DungeonService advances every cursor on the first crossing, so
	OnRoomEntered is exactly "the party is in this chunk now". The server
	writes the properties and Roblox replicates the tweens, which also
	means a late joiner sees the correct state with no catch-up logic.

	HOW ORIGINALS SURVIVE:
	Each hidden instance carries its authored value in an attribute
	(FOG_NUMBER_ATTRIBUTE / FOG_BOOLEAN_ATTRIBUTE) before the live property
	is overwritten. Reveal reads the attribute back, so nothing has to be
	held in a server-side table that a re-parent or a stream could
	invalidate, and the values are inspectable in Studio while debugging.

	TWO KINDS OF HIDING:
	  * NUMERIC (tweenable, fades in): BasePart.Transparency,
	    Decal/Texture.Transparency, Light.Brightness, Sound.Volume.
	  * BOOLEAN (instant, flips at reveal): ParticleEmitter / Beam / Trail /
	    Fire / Smoke / Sparkles / ProximityPrompt / Highlight / *Gui
	    `.Enabled`. Their visuals are sequence-driven and cannot be tweened
	    through a single number, and a prompt or a highlight has no
	    meaningful half-on state anyway.

	COLLISION IS UNTOUCHED: a hidden prop still blocks. Players cannot
	reach an unrevealed chunk (the gate is shut), and keeping collision
	means the reveal never drops someone through geometry they were
	standing on.

	LEAVING A ROOM BEHIND (LOCAL): the reveal is permanent on the server,
	but once a player is through a gate that sealed behind them (or the
	encounter intro pulled them into an arena) the rooms behind go dark
	again on THEIR client only -- LeaveRoomsBehind sends the trail to
	FogOfWarController, which applies the same hideable rules locally.
	The rules themselves live in Shared/Functions/Dungeon/fogHideables so
	the two sides cannot drift.
]]

--[ Roblox Services ]--

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

--[ Imports ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local fogHideables = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Dungeon.fogHideables)

local DungeonService

--[ Constants ]--

-- Reveal fade. Long enough to read as a room lighting up, short enough
-- that it is over before a player has walked two steps in.
local REVEAL_SECONDS = 1
local REVEAL_TWEEN_INFO = TweenInfo.new(REVEAL_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- Authored-value caches, stamped before the live property is overwritten.
local FOG_NUMBER_ATTRIBUTE = "FogValue"
local FOG_BOOLEAN_ATTRIBUTE = "FogEnabled"

-- Stamped on the ROOM MODEL. Clients read it to know whether a chunk's
-- contents are live yet — EventController's pedestal wiring waits on it
-- so a merchant prompt cannot light up inside an unrevealed shop.
local ROOM_REVEALED_ATTRIBUTE = "FogRevealed"

--[ Service ]--

local FogOfWarService = Knit.CreateService({
	Name = "FogOfWarService",
	Client = {
		-- (to one player, or broadcast) { rooms: {Model}, buildings: {Model},
		-- delaySeconds: number, afterGateClose: boolean } -- see
		-- LeaveRoomsBehind.
		OnRoomsLeftBehind = Knit.CreateSignal(),
	},

	-- [roomId] = true once revealed. Rebuilt per floor; the guard that
	-- makes OnRoomEntered's per-player fan-out reveal exactly once.
	_revealed = {},
})

--[ Private ]--

-- The classification (what fades on which property, what flips) is the
-- shared fogHideables module -- the client re-fog uses the same one.
local numericProperty = fogHideables.numericProperty
local isBooleanHidden = fogHideables.isBooleanHidden

-- Hides ONE instance, caching its authored value first. Idempotent: an
-- instance that already carries a cache attribute is left alone, so a
-- second pass (a re-parent, a re-run) cannot cache the hidden value as
-- if it were the original.
local function hideInstance(instance: Instance)
	local property = numericProperty(instance)
	if property then
		if instance:GetAttribute(FOG_NUMBER_ATTRIBUTE) == nil then
			instance:SetAttribute(FOG_NUMBER_ATTRIBUTE, (instance :: any)[property])
		end
		(instance :: any)[property] = fogHideables.hiddenValue(property)
		return
	end

	if isBooleanHidden(instance) then
		if instance:GetAttribute(FOG_BOOLEAN_ATTRIBUTE) == nil then
			instance:SetAttribute(FOG_BOOLEAN_ATTRIBUTE, (instance :: any).Enabled)
		end
		(instance :: any).Enabled = false
	end
end

-- Restores ONE instance from its cache attribute. Numeric properties
-- TWEEN back; booleans flip immediately so prompts and particles are live
-- for the whole fade rather than popping in at the end.
local function revealInstance(instance: Instance)
	local cachedNumber = instance:GetAttribute(FOG_NUMBER_ATTRIBUTE)
	if cachedNumber ~= nil then
		local property = numericProperty(instance)
		if property then
			TweenService:Create(instance, REVEAL_TWEEN_INFO, { [property] = cachedNumber }):Play()
		end
		instance:SetAttribute(FOG_NUMBER_ATTRIBUTE, nil)
		return
	end

	local cachedBoolean = instance:GetAttribute(FOG_BOOLEAN_ATTRIBUTE)
	if cachedBoolean ~= nil then
		(instance :: any).Enabled = cachedBoolean
		instance:SetAttribute(FOG_BOOLEAN_ATTRIBUTE, nil)
	end
end

-- Every non-structural descendant of a room model, in one flat list
-- (fogHideables owns the structural-shell rule).
function FogOfWarService:_collectHideables(roomModel: Model): { Instance }
	return fogHideables.collectRoomHideables(roomModel)
end

-- Hides one chunk (and its Treasure branch, which hangs off the same
-- room and is revealed with it).
function FogOfWarService:_hideRoom(room)
	if not room or not room.model then
		return
	end
	room.model:SetAttribute(ROOM_REVEALED_ATTRIBUTE, false)
	for _, instance in self:_collectHideables(room.model) do
		hideInstance(instance)
	end
	-- Chunk buildings were moved OUT of the model into Map.Buildings by
	-- DungeonService (room.buildings); they are still this room's.
	for _, building in room.buildings or {} do
		if building.Parent then
			hideInstance(building)
			for _, descendant in building:GetDescendants() do
				hideInstance(descendant)
			end
		end
	end
	if room.branch then
		self:_hideRoom(room.branch)
	end
end

--[ Public ]--

-- Reveals one chunk for EVERYONE, once. Safe to call repeatedly — the
-- `_revealed` latch and the cache-attribute checks both no-op on a second
-- pass.
function FogOfWarService:RevealRoom(room)
	if not room or not room.model or self._revealed[room.id] then
		return
	end
	self._revealed[room.id] = true

	-- GetDescendants covers direct children too; anything without a
	-- cache attribute (the structural shell) is a no-op.
	for _, instance in room.model:GetDescendants() do
		revealInstance(instance)
	end
	for _, building in room.buildings or {} do
		if building.Parent then
			revealInstance(building)
			for _, descendant in building:GetDescendants() do
				revealInstance(descendant)
			end
		end
	end
	room.model:SetAttribute(ROOM_REVEALED_ATTRIBUTE, true)

	if room.branch then
		-- The Treasure branch opens off this chunk with no gate of its
		-- own, so it lights up with its host.
		local branch = room.branch
		if branch.model then
			for _, instance in branch.model:GetDescendants() do
				revealInstance(instance)
			end
			branch.model:SetAttribute(ROOM_REVEALED_ATTRIBUTE, true)
		end
	end
end

-- Whether a chunk's contents are live yet. Server-side readers (the
-- client reads the room model's attribute instead).
function FogOfWarService:IsRoomRevealed(roomId: number): boolean
	return self._revealed[roomId] == true
end

-- Tells `target` (one player, or everyone when nil) that `rooms` are
-- behind them for good: their client re-fogs each room's model, its
-- Treasure branch and its relocated buildings, LOCALLY, `delaySeconds`
-- later (+ the client's own gate-slam tween when `afterGateClose`). The
-- client is idempotent per model, so sending the whole trail on every
-- crossing is fine and self-healing.
function FogOfWarService:LeaveRoomsBehind(
	target: Player?,
	rooms: { any },
	delaySeconds: number,
	afterGateClose: boolean
)
	local roomModels = {}
	local buildings = {}
	for _, room in rooms do
		if room.model and room.model.Parent then
			table.insert(roomModels, room.model)
		end
		if room.branch and room.branch.model and room.branch.model.Parent then
			table.insert(roomModels, room.branch.model)
		end
		for _, building in room.buildings or {} do
			if building.Parent then
				table.insert(buildings, building)
			end
		end
	end
	if #roomModels == 0 and #buildings == 0 then
		return
	end

	local payload = {
		rooms = roomModels,
		buildings = buildings,
		delaySeconds = delaySeconds,
		afterGateClose = afterGateClose,
	}
	if target then
		self.Client.OnRoomsLeftBehind:Fire(target, payload)
	else
		self.Client.OnRoomsLeftBehind:FireAll(payload)
	end
end

--[ Lifecycle ]--

function FogOfWarService:KnitInit() end

function FogOfWarService:KnitStart()
	DungeonService = Knit.GetService("DungeonService")

	-- Hide the whole floor the moment it exists. The Start room is not in
	-- `rooms` (it is the dungeon's startModel), so the room players
	-- actually stand in is never fogged.
	DungeonService.Signals.OnDungeonGenerated:Connect(function(dungeon)
		table.clear(self._revealed)
		for _, room in dungeon.rooms do
			self:_hideRoom(room)
		end
	end)

	-- First crossing advances EVERY player's cursor, so this fires once
	-- per player for the same chunk — `_revealed` collapses that to one
	-- reveal. Encounter starts route through SetPlayerRoom too, so a
	-- Miniboss / Boss arena lights up as its intro begins.
	DungeonService.Signals.OnRoomEntered:Connect(function(_player: Player, room)
		self:RevealRoom(room)
	end)
end

return FogOfWarService
