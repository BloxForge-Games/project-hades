--[[
     Author(s):
     Module: Breakable.lua
     Description: Component for any in-world model that can be destroyed by
                  the player. Tagged "Breakable" via CollectionService.

                  Hit accounting:
                    - Weapon hit (melee or projectile) = 1 count, breaks at 5
                    - Magic spell hit = instant break

                  Break effect mirrors VFXService's Destructable path:
                  darken color, reparent + unanchor for physics, outward
                  impulse + spin, fade transparency, debris destroy.

                  Weapons / spells look this up via:
                      local breakable = Breakable:FromInstance(model)
                      if breakable then breakable:Hit(isMagic, origin) end
]]

--[ Roblox Services ]--

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

--[ Exports & Types & Defaults ]--

local Component = require(ReplicatedStorage.Submodules.Core.Packages.Component)
local Janitor = require(ReplicatedStorage.Submodules.Core.Packages.Janitor)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local CollisionGroups = require(ReplicatedStorage.Submodules.Core.Shared.Enums.CollisionGroups)
local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)

local BreakableService

--[ Constants ]--

local MAX_WEAPON_HITS = 3
local KNOCKBACK_STRENGTH = 25
local IMPULSE_SCALAR = 0.25
local UPWARD_KICK = 5 -- Y component baked into every part's outward direction
local ANGULAR_IMPULSE_RANGE = 90 -- degrees per axis for the spin
local DARKEN_VALUE = 0.35

local DEBRIS_MIN_LIFETIME = 2
local DEBRIS_MAX_LIFETIME = 4
local FADE_TIME = 1

Knit.OnStart()
	:andThen(function()
		BreakableService = Knit.GetService("BreakableService")
	end)
	:catch(warn)

local Breakable = Component.new({
	Tag = TagList.Breakable,
})

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
	-- how close the attacker was or whether they used melee, ranged, or magic.
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

function Breakable:_break(_origin: Vector3?, _player: Player?)
	if self._broken then
		return
	end
	self._broken = true

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

	self.Instance.Parent = workspace.IgnoreInstances.MagicSpells

	for _, part in pieces do
		self:_applyBreakImpulse(part)
	end

	-- Detach the empty model shell after the longest debris lifetime.
	Debris:AddItem(self.Instance, DEBRIS_MAX_LIFETIME + FADE_TIME + 1)

	self._janitor:Cleanup()
end

--[ Public Functions ]--

-- Register a hit on this breakable. Magic hits break instantly; weapon hits
-- accumulate up to MAX_WEAPON_HITS. `origin` is the world position of the
-- attacker / spell (used to compute outward impulse direction).
-- `hitPosition` is where the weapon actually met the model, for the
-- client's impact sparks; nil falls back to the model's pivot there.
function Breakable:Hit(isMagic: boolean, isMelee: boolean, origin: Vector3, player: Player?, hitPosition: Vector3?)
	if self._broken then
		return
	end

	if isMagic then
		self:_break(origin)
		return
	end

	if self.Instance.PrimaryPart:FindFirstChild("HitSound") then
		self.Instance.PrimaryPart.HitSound:Play()
	end

	self._hitCount += if isMelee then 1 else 0.5

	-- `isMelee` rides along so the client can pick its impact feedback: a
	-- bullet already draws its own BulletImpact where it landed. Magic
	-- never reaches here -- it broke the model above.
	BreakableService.Client.OnBreakableDamaged:FireAll(self.Instance, self._hitCount, isMelee, hitPosition)

	if self._hitCount >= MAX_WEAPON_HITS then
		self:_break(origin, player)
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
