--!strict
-- Mystical Staff of Cyan (Legendary): two arcane-damage halves per the
-- relic description:
--   * OWNER passive: +40% Magic Damage on every arcane hit.
--   * Sigil zone: +25% Magic Damage while standing in ANY live Arcane
--     Sigil circle -- ownership-blind ("anyone standing in the circle"),
--     so unlike the passive there is NO registry gate on it.
--
-- Both magnitudes are hardcoded here rather than callback reads: the
-- zone half can't read a callback (a non-owner standing in someone
-- else's sigil has none of their own), and the passive is kept beside
-- it so the pair can't drift apart. Keep in step with the RelicData
-- description. Sigils are dropped by VFXService on every equipped cast
-- by an owner; overlapping sigils do NOT stack -- IsInSigilZone answers
-- a boolean, so standing in three circles is the same +25% as one. An
-- owner standing in their own sigil gets both halves (+90% total,
-- additive in the orchestrator's amplifier sum).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local VFXService = require(ServerScriptService.Services.VFXService)
local DamageService = require(script.Parent)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local getRoot = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Character.getRoot)

type RelicSnapshot = DamageService.RelicSnapshot

local OWNER_MAGIC_BONUS = 0.40
local SIGIL_MAGIC_BONUS = 0.25

return function(player: Player, snapshot: RelicSnapshot, damage: number, isMagic: boolean)
	if not isMagic then
		return 0
	end

	local bonus = 0

	if DamageService.RelicCount(snapshot, RelicNames["Mystical Staff of Cyan"]) > 0 then
		bonus += damage * OWNER_MAGIC_BONUS
	end

	local hrp = getRoot.fromPlayer(player)
	if hrp and VFXService and VFXService:IsInSigilZone(hrp.Position) then
		bonus += damage * SIGIL_MAGIC_BONUS
	end

	return math.round(bonus)
end
