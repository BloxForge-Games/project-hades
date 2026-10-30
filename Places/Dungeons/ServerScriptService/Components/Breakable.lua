--!strict
--[[
     Author(s):
     Module: Breakable.lua
     Description: Component for any in-world model that can be destroyed by
                  the player. Tagged "Breakable" via CollectionService.

                  Hit accounting:
                    - Melee hit = 1 count, bullet = 0.5, breaks at the
                      model's BreakHits attribute (default 3)
                    - Arcane spell hit = instant break, unless the model
                      sets ArcaneHits (the loot veins / pots), which is
                      what one spell hit counts as instead

                  Breakable.Signals.Hit / .Broken fire on the server for
                  every landed hit and on the break, so a spawner can pay
                  out (BreakableLootService).

                  Break effect mirrors VFXService's Destructable path:
                  darken color, reparent + unanchor for physics, outward
                  impulse + spin, fade transparency, debris destroy.

                  Weapons / spells look this up via:
                      local breakable = Breakable:FromInstance(model)
                      if breakable then breakable:Hit(isMagic, origin) end
]]

--[ Roblox Services ]--

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local ServerScriptService = game:GetService("ServerScriptService")

--[ Exports & Types & Defaults ]--

local Component = require(ReplicatedStorage.Submodules.Core.Packages.Component)
local Janitor = require(ReplicatedStorage.Submodules.Core.Packages.Janitor)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local CollisionGroups = require(ReplicatedStorage.Submodules.Core.Shared.Enums.CollisionGroups)
local Combat = require(ServerScriptService.Submodules.Core.Source.Network.Combat)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local Signal = require(ReplicatedStorage.Submodules.Core.Packages.Signal)

--[ Constants ]--

local MAX_WEAPON_HITS = 3
local KNOCKBACK_STRENGTH = 25
local IMPULSE_SCALAR = 0.25
local UPWARD_KICK = 5 -- Y component baked into every part's outward direction
local ANGULAR_IMPULSE_RANGE = 90 -- degrees per axis for the spin
local DARKEN_VALUE = 0.35

local DEBRIS_MIN_LIFETIME = 2
-- A loot breakable (BreakStyle set) stays this long after its break, inert,
-- while every client plays its shatter / sink on it.
local STYLED_BREAK_LIFETIME = 2
local DEBRIS_MAX_LIFETIME = 4
local FADE_TIME = 1

local Breakable = Component.new({
	Tag = TagList.Breakable,
})

-- (model, hitCount, breakHits, player?) after every landed hit that did not
-- break it, and (model, player?) on the break.
Breakable.Signals = {
	Hit = Signal.new(),
	Broken = Signal.new(),
}

--[ Relic hits ]--

-- RELIC damage on breakables (2026-10-29): every live Breakable within
-- `radius` of `position` (measured to the edge of its box) takes one hit,
-- as a weapon hit would. Relic AoEs find their mobs through
-- forEachEnemyInRadius, which only ever sees the Mobs folder; their sites
-- call this beside it. `seen` (optional) dedupes across one sweep's steps:
-- a breakable it already holds is skipped, and a hit one is added.
function Breakable.HitInRadius(position: Vector3, radius: number, player: Player?, seen: { [Instance]: boolean }?)
	for _, instance in CollectionService:GetTagged(TagList.Breakable) do
		if not instance:IsDescendantOf(workspace) or (seen and seen[instance]) then
			continue
		end
		local center: Vector3, reach: number
		if instance:IsA("Model") then
			local boxCFrame, boxSize = instance:GetBoundingBox()
			center, reach = boxCFrame.Position, math.max(boxSize.X, boxSize.Z) / 2
		elseif instance:IsA("BasePart") then
			center, reach = instance.Position, math.max(instance.Size.X, instance.Size.Z) / 2
		else
			continue
		end
		if (center - position).Magnitude > radius + reach then
			continue
		end
		local breakable = Breakable:FromInstance(instance)
		if breakable then
			if seen then
				seen[instance] = true
			end
			breakable:Hit(false, true, position, player, nil)
		end
	end
end

--[ Private Functions ]--

function Breakable:_applyBreakImpulse(part: BasePart)
	local hue, saturation = part.Color:ToHSV()
	part.Color = Color3.fromHSV(hue, saturation, DARKEN_VALUE)

	part.CollisionGroup = CollisionGroups.BrokenBuilding
	part.Anchored = false

	-- Pathfinding modifier so mobs walk through the debris without re-routing.
	local pf = Instance.new("PathfindingModifier")
	pf.PassThrough = true
	pf.Parent = part

	-- Per-part random horizontal direction with a fixed upward kick. Decoupled
	-- from the hit origin so the explosion strength is constant regardless of
	-- how close the attacker was or whether they used melee, ranged, or arcane.
	local angle = math.random() * math.pi * 2
	local direction = Vector3.new(math.cos(angle), UPWARD_KICK, math.sin(angle))
	local mass = part.AssemblyMass

	part:ApplyImpulse(direction * mass * KNOCKBACK_STRENGTH * IMPULSE_SCALAR)
	part:ApplyAngularImpulse(
		Vector3.new(
			math.random(-ANGULAR_IMPULSE_RANGE, ANGULAR_IMPULSE_RANGE),
			math.random(-ANGULAR_IMPULSE_RANGE, ANGULAR_IMPULSE_RANGE),
			math.random(-ANGULAR_IMPULSE_RANGE, ANGULAR_IMPULSE_RANGE)
		) * mass
	)

	if self.Instance.PrimaryPart:FindFirstChild("BreakSound") then
		self.Instance.PrimaryPart.BreakSound:Play()
	end

	task.delay(math.random(DEBRIS_MIN_LIFETIME, DEBRIS_MAX_LIFETIME), function()
		if not part.Parent then
			return
		end
		for _, child in part:GetChildren() do
			if child:IsA("ParticleEmitter") then
				child.Enabled = false
			elseif child:IsA("Texture") or child:IsA("Decal") then
				TweenService:Create(child, TweenInfo.new(FADE_TIME), { Transparency = 1 }):Play()
			end
		end
		TweenService:Create(part, TweenInfo.new(FADE_TIME), { Transparency = 1 }):Play()
		Debris:AddItem(part, FADE_TIME + 0.5)
	end)
end

function Breakable:_break(_origin: Vector3?, player: Player?)
	if self._broken then
		return
	end
	self._broken = true
	Breakable.Signals.Broken:Fire(self.Instance, player)

	-- Loot breakables (pots, veins) do not fall apart: the breaking hit's
	-- BreakableDamaged has already told every client to play the model's
	-- BreakStyle on it, so the server just makes it inert and lets it go.
	if self.Instance:GetAttribute(Attributes.BreakStyle) ~= nil then
		for _, part in self.Instance:GetDescendants() do
			if part:IsA("BasePart") then
				part.CanCollide = false
				part.CanQuery = false
			end
		end
		Debris:AddItem(self.Instance, STYLED_BREAK_LIFETIME)
		self._janitor:Cleanup()
		return
	end

	-- Snapshot parts before reparenting them (which would mutate the iteration).
	local pieces = {}

	for _, part in self.Instance:GetChildren() do
		if part:IsA("BasePart") then
			table.insert(pieces, part)
		end
	end

	for _, weld in self.Instance.PrimaryPart:GetChildren() do
		if weld:IsA("Weld") then
			weld:Destroy()
		end
	end

	self.Instance.Parent = workspace.IgnoreInstances.ArcaneSpells

	for _, part in pieces do
		self:_applyBreakImpulse(part)
	end

	-- Detach the empty model shell after the longest debris lifetime.
	Debris:AddItem(self.Instance, DEBRIS_MAX_LIFETIME + FADE_TIME + 1)

	self._janitor:Cleanup()
end

--[ Public Functions ]--

-- Register a hit on this breakable. Arcane hits break instantly; weapon hits
-- accumulate up to MAX_WEAPON_HITS. `origin` is the world position of the
-- attacker / spell (used to compute outward impulse direction).
-- `hitPosition` is where the weapon actually met the model, for the
-- client's impact sparks; nil falls back to the model's pivot there.
function Breakable:Hit(isMagic: boolean, isMelee: boolean, origin: Vector3, player: Player?, hitPosition: Vector3?)
	if self._broken then
		return
	end

	local arcaneHits = self.Instance:GetAttribute(Attributes.ArcaneHits)
	if isMagic and type(arcaneHits) ~= "number" then
		self:_break(origin, player)
		return
	end

	if self.Instance.PrimaryPart:FindFirstChild("HitSound") then
		self.Instance.PrimaryPart.HitSound:Play()
	end

	-- A bullet is half a hit -- a crystal takes twice its melee hits in
	-- shots -- except on a pot ("Shatter"), which one bullet breaks.
	local isPot = self.Instance:GetAttribute(Attributes.BreakStyle) == "Shatter"
	self._hitCount += if isMagic then arcaneHits :: number elseif isMelee or isPot then 1 else 0.5
	local breakHits = self.Instance:GetAttribute(Attributes.BreakHits)
	local maxHits = if type(breakHits) == "number" then breakHits else MAX_WEAPON_HITS

	-- `isMelee` rides along so the client can pick its impact feedback: a
	-- bullet already draws its own BulletImpact where it landed. Arcane
	-- only reaches here on a model with ArcaneHits (the loot breakables);
	-- everywhere else it broke the model above. Fired on the BREAKING hit
	-- too, which is what plays a loot breakable's shatter / sink.
	Combat.BreakableDamaged.FireAll({
		Breakable = self.Instance,
		HitCount = self._hitCount,
		IsMelee = isMelee,
		HitPosition = hitPosition,
	})

	if self._hitCount >= maxHits then
		self:_break(origin, player)
	else
		Breakable.Signals.Hit:Fire(self.Instance, self._hitCount, maxHits, player)
	end
end

--[ Initializers ]--

function Breakable:Construct()
	self._janitor = Janitor.new()
	self._hitCount = 0
	self._broken = false
end

function Breakable:Start()
	self.Instance:SetAttribute(Attributes.CachedCFrame, self.Instance:GetPivot())
end

function Breakable:Stop()
	self._janitor:Cleanup()
end

return Breakable
