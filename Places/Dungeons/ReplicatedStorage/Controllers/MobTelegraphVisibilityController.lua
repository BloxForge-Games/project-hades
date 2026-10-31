--!strict
--[[
	Module: MobTelegraphVisibilityController.lua
	Description:
	The "Mob Hitboxes" toggle behind the top bar icon of the same name
	(2026-10-30). Off hides the danger-zone flashes of MELEE mob attacks
	(slashes, cleaves, stomps); the RANGED ones (a support mob's heal
	square, the Runic Executioner's Water Dragon and Water Shark Barrage)
	always show, because they land away from the mob and there is nothing
	else to read them by. Which is which rides on each telegraph packet
	(`Ranged`, MobService.SpawnHitbox, from MobData `rangedTelegraph`).

	Purely visual: the hits land exactly the same. MobController asks
	IsMeleeHidden() before it draws a flash.

	SESSION ONLY, like Show Drops: a fresh join shows every hitbox again.
]]

--[ Roblox Services ]--

local ReplicatedStorage = game:GetService("ReplicatedStorage")

--[ Imports ]--

local Signal = require(ReplicatedStorage.Submodules.Core.Packages.Signal)
local SignalTypes = require(ReplicatedStorage.Submodules.Core.Shared.Types.Signal)

--[ Controller ]--

local MobTelegraphVisibilityController = {
	Name = "MobTelegraphVisibilityController",
}

--[ Properties ]--

MobTelegraphVisibilityController._meleeHidden = false
MobTelegraphVisibilityController.OnChanged = Signal.new() :: SignalTypes.Signal<boolean>

--[ Public ]--

-- True while melee mob telegraphs are hidden.
function MobTelegraphVisibilityController.IsMeleeHidden(self: typeof(MobTelegraphVisibilityController)): boolean
	return self._meleeHidden
end

function MobTelegraphVisibilityController.Toggle(self: typeof(MobTelegraphVisibilityController))
	self._meleeHidden = not self._meleeHidden
	self.OnChanged:Fire(self._meleeHidden)
end

return MobTelegraphVisibilityController
