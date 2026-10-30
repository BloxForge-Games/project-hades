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
	  OnMeleeSwing(player, origin, look, swingDamage, connected, weaponType)
	      MeleeWeapon, once per swing after its hitbox resolves.
	  OnMeleeHit(player, model, damage)
	      MeleeWeapon, once per mob a swing damages.
	  OnSpellCast(player, vfxName)
	      VFXService, once a cast is paid for.
	  OnSpellHit(player, vfxName, model)
	      VFXService, for every mob a real spell hits.
	  OnStatusTick(player, model, status)
	      StatusConditionService, every DoT tick a player's status lands.
	  OnCrit(player, model, isMelee)
	      DamageService, every weapon or spell Critical Hit.
	  OnAttackHit(player, model)
	      DamageService, every weapon or spell hit (no relic bursts, no
	      DoT ticks).
	  dodges
	      DodgeService.OnDodgeStarted / OnDodgeLanded, subscribed here; a
	      tree module gets (player, from, to) once the dodge lands.
	  clocks
	      onHeartbeat(now) every frame, onTick(player) once a second for
	      every player -- for the summons and the auras that fire on a
	      rhythm.

	Each tree module is a table of optional handlers with the same names
	(onMeleeSwing, onMeleeHit, onSpellCast, onSpellHit, onDodge,
	onHeartbeat, onTick, onPlayerRemoved), so a new tree is a new child
	module and nothing else.

	Damage typing is the trees' own (see each module): Blaze's waves and
	cleaves are MELEE weapon damage, so they pick up every weapon relic and
	can crit; its fire trail is a relic burst on the untyped lane.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local DodgeService = require(ServerScriptService.Submodules.Core.Source.Services.DodgeService)
local PlayerEventService = require(ServerScriptService.Submodules.Core.Source.Services.PlayerEventService)

type TreeModule = {
	onMeleeSwing: ((
		player: Player,
		origin: Vector3,
		look: Vector3,
		swingDamage: number,
		connected: boolean,
		weaponType: string?
	) -> ())?,
	onMeleeHit: ((player: Player, model: Model, damage: number) -> ())?,
	onDodge: ((player: Player, from: Vector3, to: Vector3) -> ())?,
	onSpellCast: ((player: Player, vfxName: string) -> ())?,
	onSpellHit: ((player: Player, vfxName: string, model: Model) -> ())?,
	onStatusTick: ((player: Player, model: Model, status: string) -> ())?,
	onCrit: ((player: Player, model: Model, isMelee: boolean) -> ())?,
	onAttackHit: ((player: Player, model: Model) -> ())?,
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
	weaponType: string?
)
	for _, tree in self._trees do
		if tree.onMeleeSwing then
			tree.onMeleeSwing(player, origin, look, swingDamage, connected, weaponType)
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

function RelicGimmickService.OnSpellCast(self: typeof(RelicGimmickService), player: Player, vfxName: string)
	for _, tree in self._trees do
		if tree.onSpellCast then
			tree.onSpellCast(player, vfxName)
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

function RelicGimmickService.OnCrit(self: typeof(RelicGimmickService), player: Player, model: Model, isMelee: boolean?)
	for _, tree in self._trees do
		if tree.onCrit then
			tree.onCrit(player, model, isMelee == true)
		end
	end
end

function RelicGimmickService.OnAttackHit(self: typeof(RelicGimmickService), player: Player, model: Model)
	for _, tree in self._trees do
		if tree.onAttackHit then
			tree.onAttackHit(player, model)
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
		local now = os.clock()
		for _, tree in self._trees do
			if tree.onHeartbeat then
				tree.onHeartbeat(now)
			end
		end
	end)
	task.spawn(function()
		while true do
			task.wait(1)
			for _, player in Players:GetPlayers() do
				for _, tree in self._trees do
					if tree.onTick then
						tree.onTick(player)
					end
				end
			end
		end
	end)

	PlayerEventService.OnPlayerRemoved:Connect(function(player: Player)
		self._dodgeFrom[player] = nil
		for _, tree in self._trees do
			if tree.onPlayerRemoved then
				tree.onPlayerRemoved(player)
			end
		end
	end)
end

return RelicGimmickService
