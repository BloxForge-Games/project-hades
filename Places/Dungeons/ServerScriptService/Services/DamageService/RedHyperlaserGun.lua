-- Red Hyperlaser Gun (Rare): deal more damage the LESS health you have
-- -- scaling linearly from +0% at full HP to +35% when nearly dead, per
-- the card. HIGHER ceiling than Hyperlaser Gun's +25% (the risk axis
-- pays more), opposite axis: max benefit means standing at death's door. The curve lives in the RelicData
-- callback; this module converts the multiplier into the
-- orchestrator's flat-bonus shape.
--
-- Returns BONUS damage (not total), so the orchestrator's `totalDamage
-- += this(...)` sum picks it up identically to Linked Sword + friends.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)

local RelicService

Knit.OnStart():andThen(function()
	RelicService = Knit.GetService("RelicService")
end)

return function(player: Player, damage: number, _isMagic: boolean)
	-- No damage-type gate — the bonus applies to weapon AND magic; the
	-- linear low-HP curve lives in the RelicData callback, read fresh on
	-- every hit.
	local effect = RelicService:GetRelicEffect(player, RelicNames["Red Hyperlaser Gun"]) or 1
	if effect == 1 then
		return 0
	end

	return math.round(damage * effect) - damage
end
