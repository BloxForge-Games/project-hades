--!strict
--[[
	Module: Controllers/ProjectileWeaponController.lua
	Description:
	Client face of the ProjectileCast library: boots it and routes the
	CastSingle signal into it. AmmoUpdated is the library's ammo feed for
	WeaponLoadoutController.

	A Blitz module with no dependencies.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.Submodules.Core.Shared.Types.Signal)
local ProjectileCastController =
	require(ReplicatedStorage.Submodules.Core.Libraries.ProjectileCast.ProjectileCastController)

local ProjectileWeaponController = {
	Name = "ProjectileWeaponController",

	CastSingle = Signal.new() :: Signal.Signal<...any>,
	-- (weaponTag, currentAmmo, maxAmmo)
	AmmoUpdated = Signal.new() :: Signal.Signal<string, number, number>,

	WrapperEnabled = true :: boolean,
}

function ProjectileWeaponController.SetWrapperEnabled(self: typeof(ProjectileWeaponController), enable: boolean)
	self.WrapperEnabled = enable
end

function ProjectileWeaponController.GetWrapperEnabled(self: typeof(ProjectileWeaponController)): boolean
	return self.WrapperEnabled
end

function ProjectileWeaponController.FireProjectile(_self: typeof(ProjectileWeaponController), ...: any)
	ProjectileCastController:Cast(...)
end

function ProjectileWeaponController.Start(self: typeof(ProjectileWeaponController))
	ProjectileCastController:Init()

	self.CastSingle:Connect(function(...)
		if not self.WrapperEnabled then
			return
		end

		ProjectileCastController:Cast(...)
	end)
end

return ProjectileWeaponController
