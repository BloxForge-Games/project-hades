--!strict
--[[
	Module: RelicGimmickService/Lib/gimmickHelpers
	Description:
	The small pieces every tree's gimmicks share: who owns what, the
	level-scaled number a card prints, the services the hits go through
	(reached lazily -- several of them require each other at load), and
	the one call that sends an effect to the clients.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local RelicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicData)
local MeleeWeaponTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.MeleeWeaponTypes)
local getRelicLevel = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Player.getRelicLevel)
local RelicNetwork = require(ServerScriptService.Submodules.Core.Source.Network.Relic)

local helpers = {}

local lazy: { [string]: any } = {}
local function service(name: string): any
	local found = lazy[name]
	if found == nil then
		found = (require :: any)(ServerScriptService.Services[name])
		lazy[name] = found
	end
	return found
end

-- A Dungeons service by name, required on first use.
helpers.service = service

function helpers.relicService(): any
	return service("RelicService")
end

function helpers.damageService(): any
	return service("DamageService")
end

-- TakeDamage for a gimmick hit, same arguments, with the relic push
-- (DamageService.WithRelicKnockback: 1 stud, not a weapon / spell push).
function helpers.takeDamage(player: Player, humanoid: Humanoid, damage: number, ...: any)
	local damageService = service("DamageService")
	local extra = table.pack(...)
	damageService:WithRelicKnockback(function()
		damageService:TakeDamage(player, humanoid, damage, table.unpack(extra, 1, extra.n))
	end)
end

function helpers.statusService(): any
	return service("StatusConditionService")
end

function helpers.owns(player: Player, relicName: string): boolean
	return (helpers.relicService():GetSpecificRelicRegistry(player, relicName) or 0) > 0
end

-- One of a relic's `data` numbers, or the fallback.
function helpers.data(relicName: string, field: string, fallback: number): number
	local row = RelicData[relicName]
	local value = row and row.data and row.data[field]
	return if type(value) == "number" then value else fallback
end

-- A swing-count relic's swings for this weapon type: its data
-- swingsDaggers / swingsSword / swingsGreatsword (4 / 3 / 2 unless set),
-- so the faster weapons wait more swings for the same payoff.
function helpers.swingsFor(relicName: string, weaponType: string?): number
	if weaponType == MeleeWeaponTypes.Daggers then
		return helpers.data(relicName, "swingsDaggers", 4)
	elseif weaponType == MeleeWeaponTypes.Greatsword then
		return helpers.data(relicName, "swingsGreatsword", 2)
	end
	return helpers.data(relicName, "swingsSword", 3)
end

-- A relic's per-level damage at this player's relic level, rounded the way
-- its card prints it.
function helpers.levelDamage(player: Player, perLevel: number): number
	return math.round(perLevel * getRelicLevel(player))
end

-- A gimmick's own crit roll against `model`, with the player's live crit
-- chance and multiplier: the multiplier on a crit, 1 otherwise, and
-- whether it critted. The hit itself then lands on the untyped relic
-- lane (which never crits again).
function helpers.rollCrit(player: Player, model: Model?, isMagic: boolean?): (number, boolean)
	local chance, multiplier = helpers.damageService():GetCritParameters(player, isMagic, false, model)
	if math.random() * 100 <= chance then
		return multiplier, true
	end
	return 1, false
end

-- Sends one gimmick visual to every client (RelicGimmickFXController
-- draws it; Relic.blink's GimmickEffectPayload lists the kinds). The
-- server never builds effect parts: only the hits and checks run here.
function helpers.fx(
	kind: string,
	from: Vector3,
	to: Vector3?,
	radius: number?,
	duration: number?,
	caster: Player?,
	target: Model?
)
	RelicNetwork.GimmickEffect.FireAll({
		Kind = kind,
		Caster = caster,
		Target = target,
		From = from,
		To = to or from,
		Radius = radius or 0,
		Duration = duration or 0,
		StartTime = workspace:GetServerTimeNow(),
	})
end

-- Relic damage breaks breakables too (2026-10-29): one hit on every
-- Breakable within `radius` of `position` (Components/Breakable.
-- HitInRadius). `seen` dedupes across one sweep's steps.
function helpers.hitBreakables(player: Player, position: Vector3, radius: number, seen: { [Instance]: boolean }?)
	(require :: any)(ServerScriptService.Components.Breakable).HitInRadius(position, radius, player, seen)
end

-- The shortest distance from `point` to the segment a -> b, on the ground
-- plane (height ignored, so a trail catches mobs of any size).
function helpers.flatDistanceToSegment(point: Vector3, a: Vector3, b: Vector3): number
	local p = Vector3.new(point.X, 0, point.Z)
	local start = Vector3.new(a.X, 0, a.Z)
	local finish = Vector3.new(b.X, 0, b.Z)
	local segment = finish - start
	local lengthSq = segment:Dot(segment)
	if lengthSq < 1e-6 then
		return (p - start).Magnitude
	end
	local t = math.clamp((p - start):Dot(segment) / lengthSq, 0, 1)
	return (p - (start + segment * t)).Magnitude
end

-- A projectile on the server: steps `onStep(position, travelled)` along
-- `start` + `look` at `speed` every frame until `range`, with no part --
-- the clients draw it from the matching fx packet.
function helpers.sweep(start: Vector3, look: Vector3, speed: number, range: number, onStep: (position: Vector3) -> ())
	local travelled = 0
	local connection: RBXScriptConnection
	connection = RunService.Heartbeat:Connect(function(dt: number)
		travelled = math.min(travelled + speed * dt, range)
		onStep(start + look * travelled)
		if travelled >= range then
			connection:Disconnect()
		end
	end)
end

return helpers
