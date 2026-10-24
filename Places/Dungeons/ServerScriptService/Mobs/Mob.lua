--[[
     Module: Mob.lua
     Description: Default mob mob. Uses MobBase's behavior unchanged.

     Post-refactor: attacks are configured via MobData[name].genericAttacks
     and MobData[name].uniqueAttacks, NOT via subclass overrides. Most new
     mob types should just add a MobData entry — no subclass needed.

     Subclass this (or MobBase directly) only when a mob needs to override
     core lifecycle hooks: FindTarget (custom target selection), OnDeath
     (extra death VFX), or a fully custom AI loop. Per-attack behavior
     belongs in MobData.

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

local Mob = setmetatable({}, MobBase)
Mob.__index = Mob

function Mob.new(model: Model)
	local self = MobBase.new(model)
	setmetatable(self, Mob)
	return self
end

return Mob
