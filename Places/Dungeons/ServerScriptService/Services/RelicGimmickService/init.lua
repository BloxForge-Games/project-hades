--!strict
--[[
	Module: RelicGimmickService
	Description:
	The GIMMICK epics (the 2026-10-29 epic pass): relics whose effect is a
	thing that happens in the world -- a wave, a trail, a summon -- rather
	than a number in the damage sum. This service is the one place their
	triggers arrive; each element tree's gimmicks live in their own child
	module (Blaze, ...), which this hands every trigger to.

	TRIGGERS (who calls in):
	  OnMeleeSwing(player, origin, look, swingDamage, connected, weaponType,
	               startedAt)
	      MeleeWeapon, once per swing after its hitbox resolves; startedAt
	      is when the swing began, before its hitbox wait (2026-11-10).
	  OnMeleeHit(player, model, damage)
	      MeleeWeapon, once per mob a swing damages.
	  OnSpellCast(player, vfxName)
	      VFXService, once a cast is paid for.
	  OnSpellHit(player, vfxName, model)
	      VFXService, for every mob a real spell hits.
	  OnStatusTick(player, model, status)
	      StatusConditionService, every DoT tick a player's status lands.
	  OnStatusApplied(player, model, status)
	      StatusConditionService, every status a player applies, fresh or
	      refresh (2026-11-10; Zombie Bomb's Rot Eye).
	  OnCrit(player, model, isMelee, dealt, isRanged)
	      DamageService, every weapon or spell Critical Hit, with what it
	      dealt.
	  OnRangedHit(player, model, dealt, wasCrit)
	      DamageService, every gun shot that lands (2026-10-30).
	  OnRangedFire(player, origin, direction, weaponName)
	      ProjectileCastService, every gun shot the moment it is fired:
	      the muzzle, the aim and the gun (2026-11-04). The every-Nth
	      ranged relics count SHOTS and fire their own straight shot with
	      it (Lib/relicShots).
	  respawn
	      A fresh character starts every every-Nth count over:
	      onWeaponStowed(player, lane) for both lanes, and its RelicTrigger
	      glow cleared (Lib/relicTriggers). Swapping or sheathing a weapon
	      does NOT reset anything (2026-11-04): the count waits, and the
	      glow only hides while that weapon is put away
	      (RelicTriggerController draws it on the weapon in hand).
	  OnAttackHit(player, model, isMagic)
	      DamageService, every weapon or spell hit (no relic bursts, no
	      DoT ticks).
	  dodges
	      DodgeService.OnDodgeStarted / OnDodgeLanded, subscribed here; a
	      tree module gets (player, from, to) once the dodge lands.
	  OnPerfectDodge(player)
	      RelicService.OnPlayerPerfectDodged, every Perfect Dodge
	      (2026-11-01; the Katana's prime).
	  clocks
	      onHeartbeat(now) every frame, onTick(player) once a second for
	      every player -- for the summons and the auras that fire on a
	      rhythm.

	Each tree module is a table of optional handlers with the same names
	(onMeleeSwing, onMeleeHit, onSpellCast, onSpellHit, onDodge,
	onPerfectDodge, onHeartbeat, onTick, onPlayerRemoved), so a new tree is a new child
	module and nothing else.

	Damage typing is the trees' own (see each module): Blaze's waves and
	cleaves are MELEE weapon damage, so they pick up every weapon relic and
	can crit; its fire trail is a relic burst on the untyped lane.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local DodgeService = require(ServerScriptService.Submodules.Core.Source.Services.DodgeService)
local PlayerEventService = require(ServerScriptService.Submodules.Core.Source.Services.PlayerEventService)
local GameClock = require(ReplicatedStorage.Submodules.Core.Shared.GameClock)
local RelicTriggerData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicTriggerData)
local relicTriggers = require(script.Lib.relicTriggers)

type TreeModule = {
	onMeleeSwing: ((
		player: Player,
		origin: Vector3,
		look: Vector3,
		swingDamage: number,
		connected: boolean,
		weaponType: string?,
		startedAt: number?
	) -> ())?,
	onMeleeHit: ((player: Player, model: Model, damage: number) -> ())?,
	onDodge: ((player: Player, from: Vector3, to: Vector3) -> ())?,
	onPerfectDodge: ((player: Player) -> ())?,
	onSpellCast: ((player: Player, vfxName: string, castCFrame: CFrame?) -> ())?,
	onSpellHit: ((player: Player, vfxName: string, model: Model) -> ())?,
	onStatusTick: ((player: Player, model: Model, status: string) -> ())?,
	onStatusApplied: ((player: Player, model: Model, status: string) -> ())?,
	onCrit: ((player: Player, model: Model, isMelee: boolean, dealt: number, isRanged: boolean) -> ())?,
	onRangedHit: ((player: Player, model: Model, dealt: number, wasCrit: boolean) -> ())?,
	onRangedFire: ((player: Player, origin: Vector3, direction: Vector3, weaponName: string) -> ())?,
	shotTint: ((player: Player) -> string?)?,
	onWeaponStowed: ((player: Player, lane: RelicTriggerData.Lane) -> ())?,
	onAttackHit: ((player: Player, model: Model, isMagic: boolean) -> ())?,
	onHeartbeat: ((now: number) -> ())?,
	onTick: ((player: Player) -> ())?,
	onPlayerRemoved: ((player: Player) -> ())?,
}

local RelicGimmickService = {
	Name = "RelicGimmickService",
	Dependencies = { DodgeService, PlayerEventService } :: { any },

	_trees = {} :: { TreeModule },
	-- Where each player's current dodge began (OnDodgeStarted), for the
	-- dodge gimmicks that run along its path.
	_dodgeFrom = {} :: { [Player]: Vector3 },
}

--[ Triggers ]--

function RelicGimmickService.OnMeleeSwing(
	self: typeof(RelicGimmickService),
	player: Player,
	origin: Vector3,
	look: Vector3,
	swingDamage: number,
	connected: boolean,
	weaponType: string?,
	startedAt: number?
)
	for _, tree in self._trees do
		if tree.onMeleeSwing then
			tree.onMeleeSwing(player, origin, look, swingDamage, connected, weaponType, startedAt)
		end
	end
end

function RelicGimmickService.OnMeleeHit(self: typeof(RelicGimmickService), player: Player, model: Model, damage: number)
	for _, tree in self._trees do
		if tree.onMeleeHit then
			tree.onMeleeHit(player, model, damage)
		end
	end
end

-- `castCFrame`: where and which way the spell was cast (VFXService's
-- cast request), for the relics that fire along it.
function RelicGimmickService.OnSpellCast(
	self: typeof(RelicGimmickService),
	player: Player,
	vfxName: string,
	castCFrame: CFrame?
)
	for _, tree in self._trees do
		if tree.onSpellCast then
			tree.onSpellCast(player, vfxName, castCFrame)
		end
	end
end

function RelicGimmickService.OnSpellHit(
	self: typeof(RelicGimmickService),
	player: Player,
	vfxName: string,
	model: Model
)
	for _, tree in self._trees do
		if tree.onSpellHit then
			tree.onSpellHit(player, vfxName, model)
		end
	end
end

function RelicGimmickService.OnStatusTick(
	self: typeof(RelicGimmickService),
	player: Player,
	model: Model,
	status: string
)
	for _, tree in self._trees do
		if tree.onStatusTick then
			tree.onStatusTick(player, model, status)
		end
	end
end

function RelicGimmickService.OnStatusApplied(
	self: typeof(RelicGimmickService),
	player: Player,
	model: Model,
	status: string
)
	for _, tree in self._trees do
		if tree.onStatusApplied then
			tree.onStatusApplied(player, model, status)
		end
	end
end

function RelicGimmickService.OnCrit(
	self: typeof(RelicGimmickService),
	player: Player,
	model: Model,
	isMelee: boolean?,
	dealt: number?,
	isRanged: boolean?
)
	for _, tree in self._trees do
		if tree.onCrit then
			tree.onCrit(player, model, isMelee == true, dealt or 0, isRanged == true)
		end
	end
end

function RelicGimmickService.OnRangedHit(
	self: typeof(RelicGimmickService),
	player: Player,
	model: Model,
	dealt: number,
	wasCrit: boolean
)
	for _, tree in self._trees do
		if tree.onRangedHit then
			tree.onRangedHit(player, model, dealt, wasCrit)
		end
	end
end

function RelicGimmickService.OnRangedFire(
	self: typeof(RelicGimmickService),
	player: Player,
	origin: Vector3,
	direction: Vector3,
	weaponName: string
)
	for _, tree in self._trees do
		if tree.onRangedFire then
			tree.onRangedFire(player, origin, direction, weaponName)
		end
	end
end

-- The colour (a name, e.g. "Poison") of the shot OnRangedFire just
-- counted, from the first tree that has one; nil for a plain shot.
-- ProjectileCastService sends it with the shot (2026-11-05).
function RelicGimmickService.ShotTint(self: typeof(RelicGimmickService), player: Player): string?
	for _, tree in self._trees do
		if tree.shotTint then
			local tint = tree.shotTint(player)
			if tint then
				return tint
			end
		end
	end
	return nil
end

-- `lane`'s every-Nth counts start over and its glow goes (a respawn).
function RelicGimmickService._stowLane(self: typeof(RelicGimmickService), player: Player, lane: RelicTriggerData.Lane)
	for _, tree in self._trees do
		if tree.onWeaponStowed then
			tree.onWeaponStowed(player, lane)
		end
	end
	relicTriggers.clearLane(player, lane)
end

-- A fresh character starts with every count over.
function RelicGimmickService._watchCharacter(self: typeof(RelicGimmickService), player: Player, _character: Model)
	self:_stowLane(player, "Melee")
	self:_stowLane(player, "Ranged")
	relicTriggers.clear(player)
end

function RelicGimmickService.OnAttackHit(
	self: typeof(RelicGimmickService),
	player: Player,
	model: Model,
	isMagic: boolean?
)
	for _, tree in self._trees do
		if tree.onAttackHit then
			tree.onAttackHit(player, model, isMagic == true)
		end
	end
end

function RelicGimmickService.OnPerfectDodge(self: typeof(RelicGimmickService), player: Player)
	for _, tree in self._trees do
		if tree.onPerfectDodge then
			tree.onPerfectDodge(player)
		end
	end
end

--[ Lifecycle ]--

function RelicGimmickService.Start(self: typeof(RelicGimmickService))
	for _, child in script:GetChildren() do
		if child:IsA("ModuleScript") then
			table.insert(self._trees, (require :: any)(child))
		end
	end

	DodgeService.Signals.OnDodgeStarted:Connect(function(player: Player, from: Vector3)
		self._dodgeFrom[player] = from
	end)
	DodgeService.Signals.OnDodgeLanded:Connect(function(player: Player, landing: Vector3)
		local from = self._dodgeFrom[player]
		self._dodgeFrom[player] = nil
		if not from then
			return
		end
		for _, tree in self._trees do
			if tree.onDodge then
				tree.onDodge(player, from, landing)
			end
		end
	end)

	RunService.Heartbeat:Connect(function()
		local now = GameClock.Now()
		for _, tree in self._trees do
			if tree.onHeartbeat then
				tree.onHeartbeat(now)
			end
		end
	end)
	task.spawn(function()
		while true do
			GameClock.Wait(1)
			for _, player in Players:GetPlayers() do
				for _, tree in self._trees do
					if tree.onTick then
						tree.onTick(player)
					end
				end
			end
		end
	end)

	local function watchPlayer(player: Player)
		player.CharacterAdded:Connect(function(character: Model)
			self:_watchCharacter(player, character)
		end)
		if player.Character then
			self:_watchCharacter(player, player.Character)
		end
	end
	Players.PlayerAdded:Connect(watchPlayer)
	for _, player in Players:GetPlayers() do
		watchPlayer(player)
	end

	PlayerEventService.OnPlayerRemoved:Connect(function(player: Player)
		self._dodgeFrom[player] = nil
		relicTriggers.clear(player)
		for _, tree in self._trees do
			if tree.onPlayerRemoved then
				tree.onPlayerRemoved(player)
			end
		end
	end)
end

return RelicGimmickService
