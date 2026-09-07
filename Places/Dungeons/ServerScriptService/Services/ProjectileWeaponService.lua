local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local ProjectileCastService = require(ReplicatedStorage.Submodules.Core.Libraries.ProjectileCast.ProjectileCastService)
local TargetSettings = require(ReplicatedStorage.Submodules.Core.Libraries.ProjectileCast.TargetSettings)
local WeaponData = require(ReplicatedStorage.Submodules.Core.Shared.Data.WeaponData)

local ProjectileWeaponService = Knit.CreateService({
	Name = "ProjectileWeaponService",
	Client = {
		OnWeaponIntefaceUpdate = Knit.CreateSignal(),
	},
})

ProjectileWeaponService.WrapperEnabled = true

function ProjectileWeaponService:SetWrapperEnabled(enable: boolean)
	self.WrapperEnabled = enable
end

function ProjectileWeaponService:GetWrapperEnabled(): boolean
	return self.WrapperEnabled
end

-- This Service is a mainly a Wrapper for ProjectileCastService's methods
-- since ProjectileCastService is a library and not part of the Service/Controller Knit network infrastructure

function ProjectileWeaponService:ToggleWeaponAttribute()
	--ProjectileCastService:ToggleWeaponAttribute(...)
end

function ProjectileWeaponService:IncrementAmmoByPercentage()
	--ProjectileCastService:IncrementAmmoByPercentage(...)
end

function ProjectileWeaponService:ReloadPlayerAmmo()
	--ProjectileCastService:ReloadPlayerAmmo(...)
end

function ProjectileWeaponService:ReloadPlayerCartridge()
	--ProjectileCastService:ReloadPlayerCartridge(...)
end

function ProjectileWeaponService:InitPlayerAmmoCountIndex()
	--ProjectileCastService:InitPlayerAmmoCountIndex(...)
end

function ProjectileWeaponService:GetPlayerAmmoCountData()
	--return ProjectileCastService:GetPlayerAmmoCountData(...)
end

function ProjectileWeaponService:FireTurretProjectile(
	player: Player,
	turretModel: Model,
	itemName: string,
	projectileTable: table
)
	if not turretModel or not turretModel.PrimaryPart then
		warn("[ProjectileWeaponService] - Invalid turret model for firing projectile.")
		return
	end

	local weaponData = WeaponData[itemName]
	if not weaponData then
		warn("[ProjectileWeaponService] - Turret weapon missing WeaponData for:", itemName)
		return
	end

	local origin = projectileTable.StartCFrame.Position
	local direction = (projectileTable.EndCFrame - origin).Unit

	ProjectileCastService:SpawnTurretProjectile(player, turretModel, itemName, origin, direction)
end

function ProjectileWeaponService:KnitInit() end

function ProjectileWeaponService:KnitStart()
	ProjectileCastService:Init()

	TargetSettings.setTaggedTargets({ "Zombie" })
end

return ProjectileWeaponService
