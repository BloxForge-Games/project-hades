-- Stormcharged (Storm/Lightning): more Critical Hit Chance and Critical
-- Damage while up (AuraData owns both -- +30 points / +0.50 after 2026-10; DamageService reads
-- them in GetCritParameters). Standard rig — the authored asset is the
-- whole GameAssets.Auras.Stormcharged model (the old Overcharged
-- shape), which GenericAura clones wholesale. Expiry ALSO ramps the
-- rig's transparency out (transparencyFade), so the lightning thins
-- away instead of popping off.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AuraNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.AuraNames)
local GenericAura = require(script.Parent.GenericAura)

return GenericAura(AuraNames.Stormcharged, { transparencyFade = true })
