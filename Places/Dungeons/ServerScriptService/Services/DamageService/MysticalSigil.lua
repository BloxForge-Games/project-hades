-- Mystical Staff of Cyan (Legendary): two magic-damage halves per the
-- relic description:
--   * OWNER passive: +40% Magic Damage on every magic hit.
--   * Sigil zone: +25% Magic Damage while standing in ANY live Magic
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

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)

local RelicService
local VFXService

local OWNER_MAGIC_BONUS = 0.40
local SIGIL_MAGIC_BONUS = 0.25

Knit.OnStart():andThen(function()
	RelicService = Knit.GetService("RelicService")
	VFXService = Knit.GetService("VFXService")
end)

return function(player: Player, damage: number, isMagic: boolean)
	if not isMagic then
		return 0
	end

	local bonus = 0

	if RelicService and RelicService:GetSpecificRelicRegistry(player, RelicNames["Mystical Staff of Cyan"]) > 0 then
		bonus += damage * OWNER_MAGIC_BONUS
	end

	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if hrp and VFXService and VFXService:IsInSigilZone(hrp.Position) then
		bonus += damage * SIGIL_MAGIC_BONUS
	end

	return math.round(bonus)
end
