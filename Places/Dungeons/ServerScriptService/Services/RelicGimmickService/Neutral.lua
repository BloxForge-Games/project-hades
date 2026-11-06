--!strict
--[[
	Module: RelicGimmickService/Neutral
	Description:
	Neutral's gimmick relics that ride the combat hooks:
	  Midnight Sword  MANA ON HIT: a melee swing that connects, or a gun
	                  shot that lands, restores manaFraction of the owner's
	                  max Mana. Per hit EVENT, never per enemy: a cleave
	                  through five mobs is one restore, five bullets are
	                  five. (Korblox Mage Staff's free cast lives in
	                  VFXService's cast path, not here.)
	  Volleyball      SPIKE (2026-11-04 here; DamageService/Volleyball
	                  before): every `spikeEvery`-th gun SHOT fires a
	                  Volleyball WITH it, straight along its aim
	                  (Lib/relicShots, no homing); the first mob it flies
	                  into takes shotShare of the gun's damage on the
	                  universal relic lane (variance, Shock, Blight, Abyss;
	                  no weapon lines, no crit). A wall stops it for nothing.
	The numbers are the relic's RelicData `data`.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local WeaponData = require(ReplicatedStorage.Submodules.Core.Shared.Data.WeaponData)
local computeWeaponDamage = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Inventory.computeWeaponDamage)
local ArcaneService = require(ServerScriptService.Services.ArcaneService)
local helpers = require(script.Parent.Lib.gimmickHelpers)
local relicTriggers = require(script.Parent.Lib.relicTriggers)
local relicShots = require(script.Parent.Lib.relicShots)

local MIDNIGHT = RelicNames["Midnight Sword"]
local VOLLEYBALL = RelicNames["Volleyball"]

-- The ball's studs a game second.
local VOLLEYBALL_SPEED = 70

local Neutral = {}

local volleyballShots: { [Player]: number } = {}

local function restoreMana(player: Player)
	if not helpers.owns(player, MIDNIGHT) then
		return
	end
	local data = ArcaneService:GetPlayerArcaneData(player)
	if not data or not data.maxMana or data.mana >= data.maxMana then
		return
	end
	local fraction = helpers.data(MIDNIGHT, "manaFraction", 0.03)
	ArcaneService:SetPlayerArcaneData(player, math.min(data.mana + data.maxMana * fraction, data.maxMana), data.maxMana)
end

-- Once per swing, only when it connected with something.
function Neutral.onMeleeSwing(
	player: Player,
	_origin: Vector3,
	_look: Vector3,
	_swingDamage: number,
	connected: boolean,
	_weaponType: string?
)
	if connected then
		restoreMana(player)
	end
end

-- Once per gun shot that lands.
function Neutral.onRangedHit(player: Player, _model: Model, _dealt: number, _wasCrit: boolean)
	restoreMana(player)
end

-- The gun's damage, as its own model stamps it (computeWeaponDamage), or
-- its flat base when the model is gone (swapped mid-flight).
local function gunDamage(player: Player, weaponName: string): number
	local character = player.Character
	local weaponModel = character and character:FindFirstChild(weaponName)
	local weapon = WeaponData[weaponName]
	return (weaponModel and computeWeaponDamage(weaponModel)) or (weapon and weapon.damage) or 0
end

-- The ball landed on `target` (nil: a wall, or the end of its range).
local function volleyballHit(player: Player, target: Model?, weaponName: string)
	local humanoid = target and target:FindFirstChildOfClass("Humanoid")
	if not target or not humanoid or humanoid.Health <= 0 or target:GetAttribute(Attributes.Invulnerable) == true then
		return
	end
	local spikeDamage =
		math.max(math.round(gunDamage(player, weaponName) * helpers.data(VOLLEYBALL, "shotShare", 1)), 1)
	-- The universal relic lane (isRelicSourced): TakeDamage owns the
	-- indicator, the execute check and every universal multiplier.
	helpers.damageService():TakeDamage(player, humanoid, spikeDamage, false, false, false, true)
end

-- Every gun shot, the moment it is fired: the Volleyball's count. The
-- Nth fires the ball with it.
function Neutral.onRangedFire(player: Player, origin: Vector3, direction: Vector3, weaponName: string)
	if not helpers.owns(player, VOLLEYBALL) then
		volleyballShots[player] = nil
		relicTriggers.set(player, VOLLEYBALL, false)
		return
	end
	local needed = helpers.data(VOLLEYBALL, "spikeEvery", 3)
	local count = (volleyballShots[player] or 0) + 1
	if count >= needed then
		count = 0
		relicShots.fire(player, "VolleyballShot", origin, direction, weaponName, VOLLEYBALL_SPEED, function(_, target)
			volleyballHit(player, target, weaponName)
		end)
	end
	volleyballShots[player] = count
	relicTriggers.set(player, VOLLEYBALL, count == needed - 1)
end

-- The gun was put away: the Volleyball's count starts over.
function Neutral.onWeaponStowed(player: Player, lane: string)
	if lane == "Ranged" then
		volleyballShots[player] = nil
	end
end

function Neutral.onPlayerRemoved(player: Player)
	volleyballShots[player] = nil
end

return Neutral
