--[[
	Module: Server/Services/ExitGateWindService.lua
	Description:
	The wind curling through a doorway that still has DARKNESS behind it.

	Every chunk boundary in this dungeon is one ExitGate part: the
	uncrossable gate you open by clearing the chunk, and the breakable
	DungeonBarricade both sit at the SAME doorway (_placeGateBarricade
	offsets the barricade off its gate), so one wind per gate marks both
	kinds of spot. GameAssets.VFX.ExitGateWind is cloned onto the gate's
	CFrame exactly as authored — tune the look in Studio, not here.

	WHEN IT BLOWS. A wind is lit when both of these are true:
	  * its OWN chunk is revealed  — you are standing somewhere you can
	    actually see it from, rather than it glowing away in a chunk you
	    have never visited
	  * the chunk BEYOND it is NOT revealed — there is still fog through
	    that doorway
	Entering ("unlocking") a room is what lights its exit; CLEARING the
	room is completion and is not a condition here any more (2026-09 —
	the gate's chained rig, DungeonGateController, follows the same rule
	and fades when the door opens).

	So it reads as "the room through here is still dark", and switches
	itself off the moment you walk through and light that room up. The
	result cascades: clearing chunk N kills N's wind and lights N+1's.

	Driven off the FogOfWarService's own `FogRevealed` room attribute
	rather than off OnRoomEntered directly. Both services listen to that
	same signal, so reading the attribute change instead sidesteps the
	question of which of them runs first.

	Party-wide and server-side, deliberately: fog reveal is party-wide
	(one player entering lights the chunk for everybody), and a per-player
	wind would disagree with the lighting everyone else can see.
]]

--[ Roblox Services ]--

local ReplicatedStorage = game:GetService("ReplicatedStorage")

--[ Imports ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)

local DungeonService

--[ Constants ]--

local VFX_FOLDER_NAME = "VFX"
local WIND_MODEL_NAME = "ExitGateWind"
local EXIT_GATE_NAME = "ExitGate"

-- Set by FogOfWarService on a chunk's model when it lights up.
local ROOM_REVEALED_ATTRIBUTE = "FogRevealed"

--[ Service ]--

local ExitGateWindService = Knit.CreateService({
	Name = "ExitGateWindService",
	Client = {},
})

--[ State ]--

-- One entry per placed wind:
--   model        the clone
--   room         the chunk the gate belongs to, or nil for the START
--                area's gate — the start sits outside dungeon.rooms
--                (players spawn there at cursor 0) and is never
--                fogged, so it counts as permanently lit
--   destination  the chunk through that gate, or nil on the dungeon's
--                last gate (nothing beyond it is ever revealed, so its
--                wind simply never switches off)
ExitGateWindService._winds = {}

--[ Private ]--

-- The authored prefab, or nil (warned once per placement pass).
local function windTemplate(): Model?
	local assets = ReplicatedStorage:FindFirstChild("GameAssets")
	local vfx = assets and assets:FindFirstChild(VFX_FOLDER_NAME)
	local template = vfx and vfx:FindFirstChild(WIND_MODEL_NAME)
	return if template and template:IsA("Model") then template else nil
end

-- Flips just the emitters. The anchor parts stay put either way — they
-- are invisible rigging, and destroying them would cost us the ability
-- to turn the wind back on.
local function setWindActive(model: Model, active: boolean)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("Beam") or descendant:IsA("ParticleEmitter") then
			descendant.Enabled = active
		end
	end
end

-- Whether a chunk has been lit by the fog service.
local function isRevealed(room): boolean
	return room ~= nil and room.model ~= nil and room.model:GetAttribute(ROOM_REVEALED_ATTRIBUTE) == true
end

-- Re-evaluates every wind against the current fog state. Cheap enough to
-- run wholesale on each reveal (a dungeon holds a handful of chunks), and
-- being idempotent means a double-fire costs nothing.
function ExitGateWindService:_refresh()
	for _, entry in self._winds do
		if entry.model.Parent then
			-- No destination (the dungeon's final gate) means nothing
			-- beyond it will ever be revealed, so the wind stays lit.
			local beyondIsDark = entry.destination == nil or not isRevealed(entry.destination)
			local hostIsLit = entry.room == nil or isRevealed(entry.room)
			setWindActive(entry.model, hostIsLit and beyondIsDark)
		end
	end
end

-- Tears down the previous floor's winds.
function ExitGateWindService:_clear()
	for _, entry in self._winds do
		entry.model:Destroy()
	end
	table.clear(self._winds)
end

-- Clones one wind onto every chunk's ExitGate. No doorway is skipped —
-- including the Boss room's, whose gate is solid and never leads
-- anywhere, so its wind simply stays lit for the rest of the run.
-- Clones one wind onto `model`'s ExitGate, if it has one. `room` is the
-- chunk that gate belongs to (nil for the start area) and `destination`
-- is the chunk it opens into (nil when nothing lies beyond).
function ExitGateWindService:_placeWind(template: Model, model: Instance?, room, destination)
	local gate = model and model:FindFirstChild(EXIT_GATE_NAME)
	if not gate or not gate:IsA("BasePart") then
		return
	end

	local wind = template:Clone()

	-- Inert scenery: it sits IN a doorway players walk through, so it
	-- must never collide with or block a raycast against them.
	for _, part in wind:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = true
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
		end
	end

	wind:PivotTo(gate.CFrame + Vector3.new(0, -5.75, 0))
	wind.Parent = workspace.IgnoreInstances.MagicSpells

	table.insert(self._winds, { model = wind, room = room, destination = destination })
end

function ExitGateWindService:_placeWinds(dungeon)
	self:_clear()

	if not dungeon or not dungeon.rooms then
		return
	end

	local template = windTemplate()
	if not template then
		warn(("[ExitGateWindService] Missing GameAssets.%s.%s"):format(VFX_FOLDER_NAME, WIND_MODEL_NAME))
		return
	end

	-- The START area's gate. It lives outside dungeon.rooms (players
	-- spawn there at cursor 0), so the loop below would miss the very
	-- first doorway of the run — the one most likely to be looked at.
	self:_placeWind(template, dungeon.startModel, nil, dungeon.rooms[1])

	for _, room in dungeon.rooms do
		-- Keyed by ID, the codebase's own "next room" idiom (rooms is
		-- indexed by id, not by iteration order).
		self:_placeWind(template, room.model, room, dungeon.rooms[room.id + 1])

		-- Fog flips this attribute when the chunk lights up. Watching it
		-- (rather than OnRoomEntered) keeps us out of the ordering race
		-- between this service and FogOfWarService. Connected for EVERY
		-- chunk, gate or not: a chunk lighting up changes the wind on the
		-- doorway BEHIND it, which is a different room's model.
		if room.model then
			room.model:GetAttributeChangedSignal(ROOM_REVEALED_ATTRIBUTE):Connect(function()
				self:_refresh()
			end)
		end
	end

	self:_refresh()
end

--[ Lifecycle ]--

function ExitGateWindService:KnitInit() end

function ExitGateWindService:KnitStart()
	DungeonService = Knit.GetService("DungeonService")

	DungeonService.Signals.OnDungeonGenerated:Connect(function(dungeon)
		self:_placeWinds(dungeon)
	end)

	-- The branch (Treasure) room lights up with its host and has no gate
	-- of its own, but entering one still changes what is revealed — and a
	-- refresh is idempotent, so it costs nothing to be sure.
	DungeonService.Signals.OnRoomEntered:Connect(function(_player, _room)
		self:_refresh()
	end)
end

return ExitGateWindService
