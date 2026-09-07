local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)

local RelicService

Knit.OnStart():andThen(function()
	RelicService = Knit.GetService("RelicService")
end)

local MURDER_KNIFE_STUD_RADIUS = 12.5

return function(player: Player, humanoid: Humanoid, damage: number, _isMagic: boolean)
	-- No damage-type gate — the nearby bonus applies to weapon AND
	-- magic; only the distance (and the backstab angle) gate the proc.
	local murderKnifeEffect = RelicService:GetRelicEffect(player, RelicNames["Murder Knife"]) or 1

	if murderKnifeEffect == 1 then
		return 0
	end

	local humanoidRootPart = humanoid.Parent:FindFirstChild("HumanoidRootPart")
	local playerRootPart = player.Character:FindFirstChild("HumanoidRootPart")

	if not humanoidRootPart or not playerRootPart then
		return 0
	end

	if (humanoidRootPart.Position - playerRootPart.Position).Magnitude >= MURDER_KNIFE_STUD_RADIUS then
		return 0
	end

	-- Its old backstab rider left with the element rework -- the +20%
	-- nearby bonus is the whole relic now.
	return math.round(damage * murderKnifeEffect) - damage
end
