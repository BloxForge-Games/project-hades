--!strict
-- Forbidden Box (Cursed): +75% MORE DAMAGE -- weapon AND magic, per its
-- element-rework text ("deal +75% more Damage", unqualified). The doubled
-- mana cost half lives in VFXService + MagicController's mirrored cost
-- chains. Returns bonus damage for the orchestrator's additive sum.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local RelicService = require(ServerScriptService.Services.RelicService)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)

return function(player: Player, damage: number, _isMagic: boolean)
	local effect = RelicService:GetRelicEffect(player, RelicNames["Forbidden Box"]) or 1
	if effect == 1 then
		return 0
	end

	return math.round(damage * effect) - damage
end
