--!strict
--[[
	Module: DamageIndicatorService.lua
	Description:
	Pushes damage feedback to clients: the floating number for the player
	who dealt the hit, the hit flash + sparks for everyone, and status proc
	bursts. Owns no state; every method is fire-and-forget.

	FIRST SERVICE ON BLINK (phase 3 proof). Its three remotes are the
	Combat domain's events (bfg-core/Network/Combat.blink); the old remote signals
	they replace were untyped varargs. Callers keep the same positional
	signatures, and the DamageIndicatorController reads the typed payloads.

	Still resolved by name through the Blitz shim for the callers
	that have not migrated (DamageService, Trap, StatusConditionService).
]]

--[ Roblox Services ]--

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

--[ Imports ]--

local Signal = require(ReplicatedStorage.Submodules.Core.Packages.Signal)
local Combat = require(ServerScriptService.Submodules.Core.Source.Network.Combat)

--[ Types ]--

export type ResistKind = "Projectile" | "Magic"

--[ Module ]--

local DamageIndicatorService = {
	Name = "DamageIndicatorService",

	-- Server-side mirror of every indicator shown, for server listeners.
	-- (Player, Model, number, boolean, Color3?, boolean?, ResistKind?,
	-- boolean?, boolean?) -- the same positional shape ShowIndicator takes.
	DamageIndicatorRequested = Signal.new(),
}

--[ Public API ]--

-- Floating number for `player`, hit flash for everyone, sparks unless
-- `sparks == false`.
function DamageIndicatorService.ShowIndicator(
	self: typeof(DamageIndicatorService),
	player: Player,
	character: Model,
	value: number,
	critical: boolean,
	color: Color3?,
	isMelee: boolean?,
	resistKind: ResistKind?,
	isStatus: boolean?,
	sparks: boolean?
)
	self.DamageIndicatorRequested:Fire(player, character, value, critical, color, isMelee, resistKind, isStatus, sparks)
	Combat.DamageIndicator.Fire(player, {
		Character = character,
		Value = value,
		Critical = critical,
		Color = color,
		IsMelee = isMelee,
		ResistKind = resistKind,
		IsStatus = isStatus,
	})
	Combat.DamageVFX.FireAll({
		Character = character,
		Color = color,
		Sparks = sparks,
	})
end

-- ShowIndicator MINUS the hit-particle burst: floating number and flash
-- only. For damage that isn't an impact: a status DoT tick is damage the
-- player should SEE, but it isn't a weapon connecting, so it must not
-- replay the sword-hit sparks (Burn ticked six bursts per application).
function DamageIndicatorService.ShowIndicatorNoHitVFX(
	self: typeof(DamageIndicatorService),
	player: Player,
	character: Model,
	value: number,
	critical: boolean,
	color: Color3?,
	isMelee: boolean?,
	resistKind: ResistKind?,
	isStatus: boolean?
)
	self.DamageIndicatorRequested:Fire(player, character, value, critical, color, isMelee, resistKind, isStatus)
	Combat.DamageIndicator.Fire(player, {
		Character = character,
		Value = value,
		Critical = critical,
		Color = color,
		IsMelee = isMelee,
		ResistKind = resistKind,
		IsStatus = isStatus,
	})
end

-- Status proc burst on `model` for everyone. `vfxName` selects an authored
-- asset over the shared, tinted StatusFX.
function DamageIndicatorService.ShowStatusVFX(
	_self: typeof(DamageIndicatorService),
	model: Model,
	color: Color3,
	vfxName: string?
)
	Combat.StatusVFX.FireAll({
		Character = model,
		Color = color,
		VFXName = vfxName,
	})
end

return DamageIndicatorService
