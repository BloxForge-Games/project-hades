-- Enflamed (Blaze): +30% Weapon Damage while up (AuraData owns the
-- magnitude; DamageService reads the marker). Standard rig — see
-- GenericAura for the recipe and lifecycle.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AuraNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.AuraNames)
local GenericAura = require(script.Parent.GenericAura)

return GenericAura(AuraNames.Enflamed)
