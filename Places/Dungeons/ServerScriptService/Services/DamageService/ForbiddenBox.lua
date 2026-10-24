--!strict
-- Forbidden Box (Cursed): +75% MORE DAMAGE -- weapon AND arcane, per its
-- element-rework text ("deal +75% more Damage", unqualified). The doubled
-- mana cost half lives in VFXService + ArcaneController's mirrored cost
-- chains. Returns bonus damage for the orchestrator's additive sum.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DamageService = require(script.Parent)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)

type RelicSnapshot = DamageService.RelicSnapshot

return function(_player: Player, snapshot: RelicSnapshot, damage: number, _isMagic: boolean)
	local effect = DamageService.RelicEffect(snapshot, RelicNames["Forbidden Box"]) or 1
	if effect == 1 then
		return 0
	end

	return math.round(damage * effect) - damage
end
