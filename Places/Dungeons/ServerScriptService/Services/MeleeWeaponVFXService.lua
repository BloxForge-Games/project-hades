--!strict
--[[
     Author(s): 
     Module: MeleeWeaponVFXService.lua
     Description:
]]

--[ Roblox Services ]--

local ServerScriptService = game:GetService("ServerScriptService")

--[ Exports & Types & Defaults ]--

local Combat = require(ServerScriptService.Submodules.Core.Source.Network.Combat)

local MeleeWeaponVFXService = {
	Name = "MeleeWeaponVFXService",
}

--[ Imports ]--

--[ Constants ]--

--[ Properties ]--

--[ Private Functions ]--

--[ Public Functions ]--

--[ Initializers ]--

function MeleeWeaponVFXService.Start(_self: typeof(MeleeWeaponVFXService))
	-- Relay a swing to every OTHER client. The character is the sender's
	-- own, taken from the server -- never from the packet.
	Combat.MeleeSwing.On(function(player: Player, payload)
		local character = player.Character
		if not character then
			return
		end
		Combat.MeleeSwingReplicated.FireExcept(player, {
			Character = character,
			Iteration = payload.Iteration,
			WeaponType = payload.WeaponType,
		})
	end)
end

return MeleeWeaponVFXService
