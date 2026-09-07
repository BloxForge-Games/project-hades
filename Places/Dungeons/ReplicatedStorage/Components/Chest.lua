--[[
	Module: Client/Components/Chest.lua
	Description:
	The Treasure room chest's OPEN presentation — the lid swing, played
	locally when the server flips the `Opened` attribute.

	This is the presentation half of Server/Components/Chest.lua, which
	owns the prompt, the one-open latch and the loot. It exists for the
	same reason Client/Components/EncounterChest does: a lid stepped on the
	server replicates at network rate and reads as lag, so the swing has to
	run at the viewer's framerate. The hinge itself is shared between both
	chests (Shared/Functions/VFX/chestLidSwing).

	Unlike the encounter chests, this chest is SHARED party loot — there is
	no owner, so every player sees the same open with no per-viewer dimming.
]]

--[ Roblox Services ]--

local ReplicatedStorage = game:GetService("ReplicatedStorage")

--[ Imports ]--

local Component = require(ReplicatedStorage.Submodules.Core.Packages.Component)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local chestLidSwing = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.chestLidSwing)
local lootSound = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.lootSound)

--[ Constants ]--

local OPENED_ATTRIBUTE = "Opened"

--[ Component ]--

local Chest = Component.new({
	Tag = TagList.Chest,
})

function Chest:Construct()
	self._openPlayed = false
end

-- Guarded so a re-fired attribute (or a client that mounts the component
-- on an already-open chest) cannot restart the swing mid-flight.
function Chest:_playOpen()
	if self._openPlayed then
		return
	end
	self._openPlayed = true
	lootSound:PlayChestOpen(self.Instance.PrimaryPart)

	if not chestLidSwing:Play(self.Instance) then
		warn(
			("[Chest] '%s' has no part ending in 'Lid' — opening without a lid swing"):format(
				self.Instance:GetFullName()
			)
		)
	end
end

function Chest:Start()
	-- Already open when this client mounted it (a late joiner, or a chest
	-- that streamed in after somebody looted it): show the end state.
	if self.Instance:GetAttribute(OPENED_ATTRIBUTE) == true then
		self:_playOpen()
		return
	end

	self._openedWatch = self.Instance:GetAttributeChangedSignal(OPENED_ATTRIBUTE):Connect(function()
		if self.Instance:GetAttribute(OPENED_ATTRIBUTE) == true then
			self:_playOpen()
		end
	end)
end

function Chest:Stop()
	if self._openedWatch then
		self._openedWatch:Disconnect()
		self._openedWatch = nil
	end
end

return Chest
