--!strict
-- Shadow Clone Barrage, client side (PROTOTYPE, 2026-11-07): the cast
-- sound only. No cast animation and no slow (2026-11-07): the caster
-- keeps moving. The clones are ShadowCloneService's proxies, drawn by
-- ShadowCloneController.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameClock = require(ReplicatedStorage.Submodules.Core.Shared.GameClock)

return function(player: Player, preload: boolean?)
	local character = player.Character
	if preload or not character then
		return
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	local sound = ReplicatedStorage.GameAssets.Sounds:FindFirstChild("Magic Spell Cast")
	if root and sound and sound:IsA("Sound") then
		local copy = sound:Clone()
		copy.Parent = root
		copy:Play()
		GameClock.Debris(copy, 4)
	end
end
