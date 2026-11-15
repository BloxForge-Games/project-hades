--!strict
--[[
	Module: Components/MimicVaultChest.lua
	Description:
	A Mimic Vault chest on this client (2026-11-13). The server
	(MimicVaultService) owns the prompt and the outcome; this only plays
	the open: the encounter chests' own lid swing (chestLidSwing, at the
	viewer's framerate) when the chest's Opened attribute flips. The mimic
	never flips Opened -- it shakes and vanishes on the server.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Component = require(ReplicatedStorage.Submodules.Core.Packages.Component)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local chestLidSwing = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.chestLidSwing)

local OPENED_ATTRIBUTE = "Opened"

local MimicVaultChest = Component.new({
	Tag = TagList.MimicVaultChest,
})

function MimicVaultChest:_playOpen()
	if self._openPlayed then
		return
	end
	self._openPlayed = true
	chestLidSwing:Play(self.Instance)
end

function MimicVaultChest:Start()
	self._connection = self.Instance:GetAttributeChangedSignal(OPENED_ATTRIBUTE):Connect(function()
		if self.Instance:GetAttribute(OPENED_ATTRIBUTE) == true then
			self:_playOpen()
		end
	end)
	if self.Instance:GetAttribute(OPENED_ATTRIBUTE) == true then
		self:_playOpen()
	end
end

function MimicVaultChest:Stop()
	if self._connection then
		self._connection:Disconnect()
		self._connection = nil
	end
end

return MimicVaultChest
