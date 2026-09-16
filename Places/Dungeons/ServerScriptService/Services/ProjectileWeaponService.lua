--!strict
--[[
	Module: Services/ProjectileWeaponService.lua
	Description:
	Server face of the ProjectileCast library: boots it and sets the target
	tags. The gun components talk to the library through here rather than
	requiring it.

	A Blitz module with no dependencies.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ProjectileCastService = require(ReplicatedStorage.Submodules.Core.Libraries.ProjectileCast.ProjectileCastService)
local TargetSettings = require(ReplicatedStorage.Submodules.Core.Libraries.ProjectileCast.TargetSettings)

local ProjectileWeaponService = {
	Name = "ProjectileWeaponService",

	WrapperEnabled = true :: boolean,
}

function ProjectileWeaponService.SetWrapperEnabled(self: typeof(ProjectileWeaponService), enable: boolean)
	self.WrapperEnabled = enable
end

function ProjectileWeaponService.GetWrapperEnabled(self: typeof(ProjectileWeaponService)): boolean
	return self.WrapperEnabled
end

-- The ProjectileWeapon component's ammo paths land here; the library
-- tracks ammo on the client, so the server side is a no-op today.
function ProjectileWeaponService.InitPlayerAmmoCountIndex(
	_self: typeof(ProjectileWeaponService),
	_player: Player,
	_weaponName: string
)
end

function ProjectileWeaponService.ReloadPlayerAmmo(
	_self: typeof(ProjectileWeaponService),
	_player: Player,
	_itemName: string
)
end

function ProjectileWeaponService.Start(_self: typeof(ProjectileWeaponService))
	ProjectileCastService:Init()

	TargetSettings.SetTaggedTargets({ "Zombie" })
end

return ProjectileWeaponService
