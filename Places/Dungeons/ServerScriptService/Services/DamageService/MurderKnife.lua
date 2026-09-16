--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local RelicService = require(ServerScriptService.Services.RelicService)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)

local MURDER_KNIFE_STUD_RADIUS = 12.5

return function(player: Player, humanoid: Humanoid, damage: number, _isMagic: boolean)
	-- No damage-type gate — the nearby bonus applies to weapon AND
	-- magic; only the distance (and the backstab angle) gate the proc.
	local murderKnifeEffect = RelicService:GetRelicEffect(player, RelicNames["Murder Knife"]) or 1

	if murderKnifeEffect == 1 then
		return 0
	end

	local humanoidRootPart = (humanoid.Parent :: Instance):FindFirstChild("HumanoidRootPart") :: BasePart?
	local playerRootPart = (player.Character :: Model):FindFirstChild("HumanoidRootPart") :: BasePart?

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
