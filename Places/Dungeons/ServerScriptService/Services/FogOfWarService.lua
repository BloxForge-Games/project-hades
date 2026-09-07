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
]]

--[ Roblox Services ]--

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

--[ Imports ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)

local DungeonService

--[ Constants ]--

-- The structural shell, kept visible in an unrevealed chunk. Matched on
-- DIRECT CHILDREN of the room model (the authored prefab layout), so a
-- Wall's own Decals and Textures ride along with it.
--
-- ExitGate is structural on purpose: hidden, a shut gate reads as an open
-- doorway you inexplicably cannot walk through.
local STRUCTURE_NAMES: { [string]: boolean } = {
	Floor = true,
	Wall = true,
	ExitGate = true,
}

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
	Client = {},

	-- [roomId] = true once revealed. Rebuilt per floor; the guard that
	-- makes OnRoomEntered's per-player fan-out reveal exactly once.
	_revealed = {},
})

--[ Private ]--

-- The numeric property this instance fades on, or nil when it is not a
-- numeric-fade class.
local function numericProperty(instance: Instance): string?
	if instance:IsA("BasePart") then
		return "Transparency"
	elseif instance:IsA("Decal") then
		-- Textures are Decals, so this covers both.
		return "Transparency"
	elseif instance:IsA("Light") then
		return "Brightness"
	elseif instance:IsA("Sound") then
		return "Volume"
	end
	return nil
end

-- True for the flip-at-reveal classes. ParticleEmitter / Beam / Trail /
-- Fire / Smoke / Sparkles all inherit nothing useful in common, so the
-- test is explicit.
local function isBooleanHidden(instance: Instance): boolean
	return instance:IsA("ParticleEmitter")
		or instance:IsA("Beam")
		or instance:IsA("Trail")
		or instance:IsA("Fire")
		or instance:IsA("Smoke")
		or instance:IsA("Sparkles")
		or instance:IsA("ProximityPrompt")
		or instance:IsA("Highlight")
		or instance:IsA("LayerCollector") -- BillboardGui / SurfaceGui / ScreenGui
end

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
		-- Transparency hides at 1; Brightness and Volume hide at 0.
		(instance :: any)[property] = if property == "Transparency" then 1 else 0
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

-- Every non-structural descendant of a room model, in one flat list. The
-- skip is by DIRECT CHILD name, so a whole Floor / Wall / ExitGate subtree
-- (its Decals, its Textures) is passed over as a unit.
function FogOfWarService:_collectHideables(roomModel: Model): { Instance }
	local hideables = {}
	for _, child in roomModel:GetChildren() do
		if STRUCTURE_NAMES[child.Name] then
			continue
		end
		table.insert(hideables, child)
		for _, descendant in child:GetDescendants() do
			table.insert(hideables, descendant)
		end
	end
	return hideables
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
