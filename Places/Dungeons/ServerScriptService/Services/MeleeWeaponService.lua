local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local Signal = require(ReplicatedStorage.Submodules.Core.Packages.Signal)
-- local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)

local MeleeWeaponService = Knit.CreateService({
	Name = "MeleeWeaponService",
})

MeleeWeaponService.OnHitRequested = Signal.new()

function MeleeWeaponService:KnitStart()
	-- Being set in DamageService
	-- self.OnHitRequested:Connect(function(player: Player, characterModel: Model, _: number)
	-- 	 characterModel:SetAttribute(Attributes.SlainBy, player.Name)
	-- end)
end

return MeleeWeaponService
