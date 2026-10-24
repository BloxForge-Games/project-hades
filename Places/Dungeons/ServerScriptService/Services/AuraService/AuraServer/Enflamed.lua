-- Enflamed (Blaze): more Weapon Damage while up (AuraData owns the
-- magnitude -- 0.30 after the 2026-10 shift; DamageService reads the marker). Standard rig — see
-- GenericAura for the recipe and lifecycle.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AuraNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.AuraNames)
local GenericAura = require(script.Parent.GenericAura)

return GenericAura(AuraNames.Enflamed)
