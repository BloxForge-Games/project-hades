--!strict
-- Shadow Clone Barrage, server side (PROTOTYPE, 2026-11-07): the clones
-- live in ShadowCloneService, which owns their walking, swings, hits taken
-- and the mobs' aggro on them.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Blitz = require(ReplicatedStorage.Submodules.Core.Shared.Blitz)

return function(_vfxService: any, player: Player, _cframe: CFrame)
	local clones = Blitz.OptionalService("ShadowCloneService")
	if clones then
		clones:Summon(player)
	end
end
