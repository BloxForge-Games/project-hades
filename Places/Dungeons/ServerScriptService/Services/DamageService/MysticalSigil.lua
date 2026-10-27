--!strict
-- Mystical Staff of Cyan (Legendary), the Sigil half: +25% Arcane Damage
-- while standing in ANY live Arcane Sigil circle -- ownership-blind
-- ("anyone inside"), so there is NO registry gate, and the value is
-- hardcoded here because a non-owner has no callback to read. It joins
-- the additive pool. Sigils are dropped by VFXService on every equipped
-- cast by an owner; overlapping sigils do NOT stack (IsInSigilZone is a
-- boolean). The owner's own "40% more Arcane Damage" is a true
-- multiplier in MoreDamage.lua (2026-10-27).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local VFXService = require(ServerScriptService.Services.VFXService)
local DamageService = require(script.Parent)
local getRoot = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Character.getRoot)

type RelicSnapshot = DamageService.RelicSnapshot

local SIGIL_MAGIC_BONUS = 0.25

return function(player: Player, _snapshot: RelicSnapshot, damage: number, isMagic: boolean)
	if not isMagic then
		return 0
	end

	local bonus = 0

	local hrp = getRoot.fromPlayer(player)
	if hrp and VFXService and VFXService:IsInSigilZone(hrp.Position) then
		bonus += damage * SIGIL_MAGIC_BONUS
	end

	return math.round(bonus)
end
