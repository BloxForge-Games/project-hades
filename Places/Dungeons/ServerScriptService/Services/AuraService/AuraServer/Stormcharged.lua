-- Stormcharged (Storm/Lightning): +15% Critical Hit Chance and +15%
-- Critical Damage while up (AuraData owns both; DamageService reads
-- them in GetCritParameters). Standard rig — the authored asset is the
-- whole GameAssets.Auras.Stormcharged model (the old Overcharged
-- shape), which GenericAura clones wholesale. Expiry ALSO ramps the
-- rig's transparency out (transparencyFade), so the lightning thins
-- away instead of popping off.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AuraNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.AuraNames)
local GenericAura = require(script.Parent.GenericAura)

return GenericAura(AuraNames.Stormcharged, { transparencyFade = true })
