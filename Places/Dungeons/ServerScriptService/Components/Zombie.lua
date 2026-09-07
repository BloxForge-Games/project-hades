--[[
     Author(s):
     Module: Zombie.lua (Component)
     Description: Thin Component that wakes up any model tagged TagList.Zombie.
                  All behavior lives in Server/Mobs/<Name>.lua classes — this
                  file only routes models to the right class based on their
                  Name and forwards lifecycle calls.

                  To add a new mob type:
                    1. Write Server/Mobs/<NewType>.lua (extend MobBase)
                    2. Register it in MOB_CLASSES below
                    3. Spawn models with model.Name == "<NewType>" and tag them
                       with TagList.Zombie
]]

--[ Roblox Services ]--

local ReplicatedStorage = game:GetService("ReplicatedStorage")

--[ Exports & Types & Defaults ]--

local Component = require(ReplicatedStorage.Submodules.Core.Packages.Component)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local ZombieNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ZombieNames)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)

local Zombie = require(script.Parent.Parent.Mobs.Zombie)
local Miniboss = require(script.Parent.Parent.Mobs.Miniboss)
local Boss = require(script.Parent.Parent.Mobs.Boss)

-- Registry: maps model.Name -> Mob class. Add new mob classes here.
-- Models whose Name isn't in this table fall back to the default Zombie class.
--
-- NOTE: miniboss / boss dispatch does NOT key off Name — the same model can
-- serve both roles across difficulties (see DungeonData). It keys off the
-- IsBoss / IsMiniboss attribute the spawn stamps (ZombieSpawnService), which
-- is set BEFORE parenting so it's present here in Construct.
local MOB_CLASSES: { [string]: any } = {
	[ZombieNames.Walker] = Zombie,
	[ZombieNames.Robombie] = Zombie,
	[ZombieNames.PotHead] = Zombie,
	[ZombieNames["The Undead Brute"]] = Zombie,
}

local DEFAULT_MOB_CLASS = Zombie

local ZombieComponent = Component.new({
	Tag = TagList.Zombie,
})

function ZombieComponent:Construct()
	local model = self.Instance
	local Class
	if model:GetAttribute(Attributes.IsBoss) then
		Class = Boss
	elseif model:GetAttribute(Attributes.IsMiniBoss) then
		Class = Miniboss
	else
		Class = MOB_CLASSES[model.Name] or DEFAULT_MOB_CLASS
	end
	self._mob = Class.new(model)
end

function ZombieComponent:Start()
	self._mob:Start()
end

function ZombieComponent:Stop()
	if self._mob then
		self._mob:Stop()
	end
end

return ZombieComponent
