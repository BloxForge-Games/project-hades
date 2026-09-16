--!strict
--[[
	Module: Services/MeleeWeaponService.lua
	Description:
	The melee hit signal: the MeleeWeapon component fires OnHitRequested
	for every part its swing detects, and DamageService turns those into
	damage.

	A Blitz module with no dependencies.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.Submodules.Core.Shared.Types.Signal)

local MeleeWeaponService = {
	Name = "MeleeWeaponService",

	-- (player, characterModel, damage): consumed by DamageService.
	OnHitRequested = Signal.new() :: Signal.Signal<Player, Model, number>,
}

return MeleeWeaponService
