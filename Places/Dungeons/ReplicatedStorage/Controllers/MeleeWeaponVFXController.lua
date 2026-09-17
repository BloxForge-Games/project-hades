--!strict
--[[
	Module: Controllers/MeleeWeaponVFXController.lua
	Description:
	Plays other players' melee swing effects from the server's
	Combat.MeleeSwingReplicated broadcast; the local player's own swing
	runs directly from the MeleeWeapon component. Also plays the slash
	marks for every swing the server says LANDED (Combat.MeleeSwingHit,
	swinger included -- the swing itself cannot know it hit).

	A Blitz module with no dependencies.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Combat = require(ReplicatedStorage.Submodules.Core.Source.Network.Combat)
local MeleeWeaponVFXData = require(ReplicatedStorage.Submodules.Core.Shared.Data.MeleeWeaponVFXData)
local playSlashMarks = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.playSlashMarks)

local MeleeWeaponVFXController = {
	Name = "MeleeWeaponVFXController",
}

function MeleeWeaponVFXController.Start(_self: typeof(MeleeWeaponVFXController))
	Combat.MeleeSwingReplicated.On(function(payload)
		local character = payload.Character
		if not character then
			return
		end
		local play = MeleeWeaponVFXData[payload.Iteration]
		if play then
			play(character, false, nil, payload.WeaponType)
		end
	end)

	Combat.MeleeSwingHit.On(function(payload)
		local character = payload.Character
		if character then
			playSlashMarks(character, payload.WeaponType)
		end
	end)
end

return MeleeWeaponVFXController
