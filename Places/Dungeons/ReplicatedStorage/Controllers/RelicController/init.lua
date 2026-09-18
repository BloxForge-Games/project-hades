--!strict
--[[
     Module: RelicController.lua
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local QuadraticBezierController = require(ReplicatedStorage.Controllers.QuadraticBezierController)
local RelicNetwork = require(ReplicatedStorage.Submodules.Core.Source.Network.Relic)
local vanishCharacter = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Character.vanishCharacter)
local DodgeConfig = require(ReplicatedStorage.Submodules.Core.Shared.Data.DodgeConfig)
local RelicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicData)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local Signal = require(ReplicatedStorage.Submodules.Core.Packages.Signal)
local SignalTypes = require(ReplicatedStorage.Submodules.Core.Shared.Types.Signal)

-- Relic effects
local Volleyball = require(script.Volleyball)
local ThrownRelic = require(script.ThrownRelic)
local Shatter = require(script.Shatter)
local LightningStrike = require(script.LightningStrike)
local Jail = require(script.Jail)
local Fireworks = require(script.Fireworks)

local RelicController = {
	Name = "RelicController",
	Dependencies = { QuadraticBezierController } :: { any },

	_relicRegistry = {} :: { [string]: any },
	_clientRenderedRelics = {}, -- [userId] = { parts = {}, count = number, visible = bool },
}

RelicController.Signals = {
	OnRelicCollected = Signal.new() :: SignalTypes.Signal<RelicNames.RelicNames>,
	-- (userId: number, registry: { [relicName]: count }?, list: { RelicNames })
	OnRelicsUpdated = Signal.new() :: SignalTypes.Signal<number, any, any>,
}

function RelicController.GetRelicEffect(self: typeof(RelicController), player: Player, relicName: RelicNames.RelicNames)
	if
		self._relicRegistry[tostring(player.UserId)]
		and self._relicRegistry[tostring(player.UserId)][relicName]
		and self._relicRegistry[tostring(player.UserId)][relicName] > 0
	then
		return RelicData[relicName].callback(player, self._relicRegistry[tostring(player.UserId)][relicName])
	end
end

function RelicController.GetRelicsFromUserId(self: typeof(RelicController), userId: number)
	return self._relicRegistry[tostring(userId)] or nil
end

-- See the PerfectDodgeBurst handler in Start.
local PERFECT_DODGE_VFX_NAME = "DodgeVFXPart"
local PERFECT_DODGE_DEFAULT_EMIT = 25
-- The burst's ACTIVE window: how long the prefab streams.
local PERFECT_DODGE_ACTIVE_SECONDS = 0.2
-- How long the dodger's body is gone (vanishCharacter) -- the whole
-- character, armour, weapons and particles included, so the burst reads
-- as the player blinking out of existence and back. A touch longer than
-- the stream so the body returns after the last particles have left.
local PERFECT_DODGE_VANISH_SECONDS = 0.1
-- The burst sits where the body WAS this many seconds ago, not where it
-- is: a roll is a straight line at a known speed (DodgeConfig's dash),
-- so "0.05 s ago" is that many studs back along the roll, and the burst
-- trails the body like an after-image instead of sitting on top of it.
-- 0 puts it on the root.
local PERFECT_DODGE_TRAIL_SECONDS = 0.025
local PERFECT_DODGE_LIFETIME = 3
local warnedMissingDodgeVFX = false

function RelicController._playPerfectDodgeBurst(_self: typeof(RelicController), cframe: CFrame)
	local gameAssets = ReplicatedStorage:FindFirstChild("GameAssets")
	local vfxFolder = gameAssets and gameAssets:FindFirstChild("VFX")
	local template = vfxFolder and vfxFolder:FindFirstChild(PERFECT_DODGE_VFX_NAME)
	if not template or not template:IsA("BasePart") then
		if not warnedMissingDodgeVFX then
			warnedMissingDodgeVFX = true
			warn(
				("[RelicController] GameAssets.VFX.%s is missing; no perfect-dodge burst"):format(
					PERFECT_DODGE_VFX_NAME
				)
			)
		end
		return
	end

	local clone = template:Clone()
	clone.Anchored = true
	clone.CanCollide = false
	clone.CanQuery = false
	clone.CanTouch = false
	clone.CFrame = cframe
	local ignoreInstances = workspace:FindFirstChild("IgnoreInstances")
	clone.Parent = (ignoreInstances and ignoreInstances:FindFirstChild("MagicSpells")) or workspace

	local emitters: { ParticleEmitter } = {}
	for _, descendant in clone:GetDescendants() do
		if descendant:IsA("ParticleEmitter") then
			descendant.Enabled = true
			local count = descendant:GetAttribute("EmitCount")
			descendant:Emit(if typeof(count) == "number" then count else PERFECT_DODGE_DEFAULT_EMIT)
			table.insert(emitters, descendant)
		end
	end

	task.delay(PERFECT_DODGE_ACTIVE_SECONDS, function()
		for _, emitter in emitters do
			if emitter.Parent then
				emitter.Enabled = false
			end
		end
	end)
	Debris:AddItem(clone, PERFECT_DODGE_LIFETIME)
end

function RelicController.Start(self: typeof(RelicController))
	RelicNetwork.RelicsReplicated.On(
		function(payload: { UserId: number, Registry: { [any]: any }, List: { [any]: any } })
			local playerId, relicRegistry, relicsList = payload.UserId, payload.Registry, payload.List
			self._relicRegistry = relicRegistry

			if playerId == Players.LocalPlayer.UserId then
				RelicController.Signals.OnRelicsUpdated:Fire(
					playerId,
					RelicController:GetRelicsFromUserId(playerId),
					relicsList[tostring(playerId)]
				)
			end
		end
	)

	RelicNetwork.FireworksEffect.On(
		function(payload: { Caster: Player?, Target: Model?, StartTime: number, Duration: number })
			local player, targetCharacter, startTime, duration =
				payload.Caster, payload.Target, payload.StartTime, payload.Duration
			if not player or not targetCharacter then
				return
			end
			-- Fireworks indexes the character's HumanoidRootPart when played,
			-- so a caster with no character has always errored; the cast
			-- keeps that behaviour.
			Fireworks.new(player.Character :: Model, targetCharacter, duration, startTime, QuadraticBezierController)
				:PlayEffect()
		end
	)

	RelicNetwork.JailEffect.On(function(targetCharacter: Model?)
		if not targetCharacter then
			return
		end
		Jail.new(targetCharacter):PlayEffect()
	end)

	-- Thrown-relic visuals: a model lobbed from the corpse that arcs to the
	-- ground and detonates (ThrownRelic). Trick Or Trap's pumpkins and
	-- Fuse Bomb's bombs both ride it — the payload's relicName picks the
	-- model (older payloads omit it; default to the pumpkin). The real
	-- damage hitbox is fired server-side on the same clock.
	RelicNetwork.ThrownRelicLaunched.On(function(payload: {
		Position: Vector3,
		TargetPosition: Vector3,
		StartTime: number,
		Duration: number,
		MagicName: string?,
		RelicName: string?,
	})
		local position, targetPosition, startTime, duration, relicName =
			payload.Position, payload.TargetPosition, payload.StartTime, payload.Duration, payload.RelicName
		ThrownRelic.new(
			relicName or RelicNames["Trick Or Trap"],
			position,
			targetPosition,
			startTime,
			duration,
			QuadraticBezierController
		):PlayEffect()
	end)

	-- `scale` is 1 for a normal Shatter. (The 2x Staff of Azure Ever Ice
	-- variant was cut in the 2026-09 pass; the parameter stays so a future
	-- variant needs no signal change.)
	RelicNetwork.ShatterEffect.On(function(payload: { Position: Vector3, Scale: number })
		Shatter.new(payload.Position, payload.Scale):PlayEffect()
	end)

	RelicNetwork.LightningStrikeEffect.On(function(position: Vector3)
		LightningStrike.new(position):PlayEffect()
	end)

	-- Perfect dodge: the burst on the dodger's root, read HERE so it sits
	-- where this client sees the body (the server's copy trails a roll).
	-- Built on every client and emitted on the frame it is placed: a burst
	-- from each emitter at once (EmitCount, default
	-- PERFECT_DODGE_DEFAULT_EMIT) plus the prefab's own stream for
	-- PERFECT_DODGE_ACTIVE_SECONDS, then gone after PERFECT_DODGE_LIFETIME.
	-- For PERFECT_DODGE_VANISH_SECONDS the dodger's whole body vanishes on
	-- this client, so the burst is all that is left of them.
	RelicNetwork.PerfectDodgeBurst.On(function(dodger: Player?)
		local character = dodger and dodger.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if character and root and root:IsA("BasePart") then
			-- The mover faces the root along the roll, so "behind" is
			-- straight back along its look vector at the roll's speed.
			local rollSpeed = DodgeConfig.DashDistance / DodgeConfig.DashDuration
			local trail = root.CFrame.LookVector * (rollSpeed * PERFECT_DODGE_TRAIL_SECONDS)
			self:_playPerfectDodgeBurst(root.CFrame - trail)
			vanishCharacter(character, PERFECT_DODGE_VANISH_SECONDS)
		end
	end)

	RelicNetwork.VolleyballEffect.On(
		function(payload: { Character: Model?, Target: Model?, StartTime: number, Duration: number })
			local character, targetCharacter, startTime, duration =
				payload.Character, payload.Target, payload.StartTime, payload.Duration
			if not character or not targetCharacter then
				return
			end
			Volleyball.new(character, targetCharacter, duration, startTime, QuadraticBezierController):PlayEffect()
		end
	)

	-- Super Stomp Boots VFX hook. Server fires AFTER damage application
	-- in SuperStompBoots:InvokeStomp. Placeholder print until VFX is
	-- authored — replace with the stomp visual when ready. Payload:
	--   caster          : Player who stomped
	--   landingPosition : Vector3 where the dodge ended
	--   radius          : number  (AOE radius, in studs)
	--   baseDamage      : number  (pre-variance, pre-rounding)
	RelicNetwork.SuperStomp.On(
		function(payload: { Caster: Player?, LandingPosition: Vector3, Radius: number, BaseDamage: number })
			local landingPosition = payload.LandingPosition
			local superStompBootsVFX =
				ReplicatedStorage.GameAssets.VFX["Super Stomp Boots"]["Super Stomp Boots"]:Clone()
			superStompBootsVFX:PivotTo(CFrame.new(landingPosition))
			superStompBootsVFX.Parent = workspace.IgnoreInstances.MagicSpells

			for _, particle in superStompBootsVFX.Part.Attachment:GetChildren() do
				if particle:IsA("ParticleEmitter") then
					particle:Emit(25)
				end
			end

			superStompBootsVFX.Part.Stomp:Play()

			Debris:AddItem(superStompBootsVFX, 5)
		end
	)
end

return RelicController
