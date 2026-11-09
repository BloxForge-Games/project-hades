--!strict
-- Shadow Clone Barrage, server side (PROTOTYPE, 2026-11-07): the clones
-- live in ShadowCloneService, which owns their walking, swings, hits taken
-- and the mobs' aggro on them. They appear the moment the cast commits,
-- with the hand seal (2026-11-08: tried after the seal, read as laggy).
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Blitz = require(ReplicatedStorage.Submodules.Core.Shared.Blitz)

-- `cframe` is the caster's own cast position (VFXService keeps it near
-- the server's copy): the clones form up there, not where the server's
-- trailing copy of a moving caster stands (2026-11-08).
return function(_vfxService: any, player: Player, cframe: CFrame)
	local clones = Blitz.OptionalService("ShadowCloneService")
	if clones then
		clones:Summon(player, cframe)
	end
end
