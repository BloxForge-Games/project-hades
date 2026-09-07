local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local Signal = require(ReplicatedStorage.Submodules.Core.Packages.Signal)
local ProjectileCastController =
	require(ReplicatedStorage.Submodules.Core.Libraries.ProjectileCast.ProjectileCastController)

local ProjectileWeaponController = Knit.CreateController({
	Name = "ProjectileWeaponController",
})

ProjectileWeaponController.CastSingle = Signal.new()
ProjectileWeaponController.AmmoUpdated = Signal.new()

ProjectileWeaponController.WrapperEnabled = true

function ProjectileWeaponController:SetWrapperEnabled(enable: boolean)
	self.WrapperEnabled = enable
end

function ProjectileWeaponController:GetWrapperEnabled(): boolean
	return self.WrapperEnabled
end

function ProjectileWeaponController:FireProjectile(...)
	ProjectileCastController:Cast(...)
end

-- ProjectileWeapon library client wrapper

function ProjectileWeaponController:KnitInit() end

function ProjectileWeaponController:KnitStart()
	ProjectileCastController:Init()

	self.CastSingle:Connect(function(...): boolean
		if not self.WrapperEnabled then
			return
		end

		ProjectileCastController:Cast(...)
	end)
end

return ProjectileWeaponController
