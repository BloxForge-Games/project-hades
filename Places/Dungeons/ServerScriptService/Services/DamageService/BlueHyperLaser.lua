-- Hyperlaser Gun (Rare): deal more damage the MORE health you have --
-- scaling linearly from +0% at empty to +20% at full HP, per the card.
-- Mirror-axis of Red Hyperlaser Gun, which peaks when nearly dead off
-- the SAME +20% ceiling. The curve lives in the RelicData callback;
-- this module just converts the multiplier into the orchestrator's
-- flat-bonus shape.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)

local RelicService

Knit.OnStart():andThen(function()
	RelicService = Knit.GetService("RelicService")
end)

return function(player: Player, damage: number, _isMagic: boolean)
	-- No damage-type gate — the bonus applies to weapon AND magic. The
	-- magnitude scales linearly with the caster's CURRENT HP (up to +20%
	-- at full); the curve lives in the RelicData callback, read fresh on
	-- every hit.
	local blueLaserEffect = RelicService:GetRelicEffect(player, RelicNames["Hyperlaser Gun"]) or 1

	if blueLaserEffect == 1 then
		return 0
	end

	return math.round(damage * blueLaserEffect) - damage
end
