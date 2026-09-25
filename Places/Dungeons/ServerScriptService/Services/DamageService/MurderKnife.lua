--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DamageService = require(script.Parent)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local getRoot = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Character.getRoot)

type RelicSnapshot = DamageService.RelicSnapshot

local MURDER_KNIFE_STUD_RADIUS = 12.5

return function(player: Player, snapshot: RelicSnapshot, humanoid: Humanoid, damage: number, _isMagic: boolean)
	-- No damage-type gate — the nearby bonus applies to weapon AND
	-- magic; only the distance (and the backstab angle) gate the proc.
	local murderKnifeEffect = DamageService.RelicEffect(snapshot, RelicNames["Murder Knife"]) or 1

	if murderKnifeEffect == 1 then
		return 0
	end

	local humanoidRootPart = getRoot(humanoid.Parent)
	local playerRootPart = getRoot.fromPlayer(player)

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
