local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local Signal = require(ReplicatedStorage.Submodules.Core.Packages.Signal)

local DamageIndicatorService = Knit.CreateService({
	Name = "DamageIndicatorService",
	Client = {
		DamageIndicatorRequested = Knit.CreateSignal(),
		DamageVFXRequested = Knit.CreateSignal(),
		StatusVFXRequested = Knit.CreateSignal(),
	},
})

DamageIndicatorService.DamageIndicatorRequested = Signal.new()

function DamageIndicatorService:ShowIndicator(...)
	self.DamageIndicatorRequested:Fire(...)
	self.Client.DamageIndicatorRequested:Fire(...)
	self.Client.DamageVFXRequested:FireAll(...)
end

-- ShowIndicator MINUS the hit-particle burst: floating damage number and
-- highlight flash only.
--
-- For damage that isn't an impact. A status DoT tick is damage the player
-- should SEE (the number is how you read that Burn is working) but it isn't
-- a weapon connecting, so it shouldn't replay the sword-hit sparks. Burn and
-- Poison tick once a second for five seconds, so routing them through
-- ShowIndicator fired six hit bursts per application — the landing hit plus
-- one per tick — which read as the status VFX stuttering.
function DamageIndicatorService:ShowIndicatorNoHitVFX(...)
	self.DamageIndicatorRequested:Fire(...)
	self.Client.DamageIndicatorRequested:Fire(...)
end

function DamageIndicatorService:ShowStatusVFX(model: Model, color3: Color3, vfxName: string?)
	self.Client.StatusVFXRequested:FireAll(model, color3, vfxName)
end

function DamageIndicatorService:KnitStart() end

return DamageIndicatorService
