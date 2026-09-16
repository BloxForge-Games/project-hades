--[[
     Module: Zombie.lua
     Description: Default zombie mob. Uses MobBase's behavior unchanged.

     Post-refactor: attacks are configured via ZombieData[name].genericAttacks
     and ZombieData[name].uniqueAttacks, NOT via subclass overrides. Most new
     mob types should just add a ZombieData entry — no subclass needed.

     Subclass this (or MobBase directly) only when a mob needs to override
     core lifecycle hooks: FindTarget (custom target selection), OnDeath
     (extra death VFX), or a fully custom AI loop. Per-attack behavior
     belongs in ZombieData.

     Pattern for a subclass with custom lifecycle:

         local MobBase = require(script.Parent.MobBase)
         local Skeleton = setmetatable({}, MobBase)
         Skeleton.__index = Skeleton

         function Skeleton.new(model: Model)
             local self = MobBase.new(model)
             setmetatable(self, Skeleton)
             return self
         end

         function Skeleton:OnDeath()
             -- custom death VFX
             MobBase.OnDeath(self)  -- still run the base pipeline
         end

         return Skeleton
]]

local MobBase = require(script.Parent.MobBase)

local Zombie = setmetatable({}, MobBase)
Zombie.__index = Zombie

function Zombie.new(model: Model)
	local self = MobBase.new(model)
	setmetatable(self, Zombie)
	return self
end

return Zombie
