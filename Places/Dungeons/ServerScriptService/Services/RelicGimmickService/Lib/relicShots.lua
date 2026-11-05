--!strict
--[[
	Module: RelicGimmickService/Lib/relicShots
	Description:
	The ranged relics' own projectile (2026-11-04): fired WITH the gun shot
	that sets the relic off, from the same muzzle and along the same aim,
	on an ARC (no homing): RelicTriggerData.Shot lifts it a few degrees
	over the bullet's straight line and drops it faster. It is swept by the
	bullet library itself (ProjectileCastService:LaunchRelicShot: the same
	ignore list and collision as a bullet, but no bullet damage), and the
	relic's `onHit(position, target)` runs where it lands: on the mob it
	flew into, or on the wall / at the end of the gun's range (target nil).
	Wherever it lands it also hits the breakables there
	(helpers.POINT_BREAK_RADIUS), so a relic shot breaks a prop it flies
	into.

	Every client draws it (RelicShotVFXController) from two gimmick
	effects that share an id, carried in the payload's Radius:
	  <kind>          the launch: From = the muzzle, To - From = its
	                  launch velocity (studs / s), Duration = the longest
	                  it can fly. Every client flies the same arc
	                  (RelicTriggerData.Shot.Gravity).
	  RelicShotEnd    where it landed (From), so the client stops it there.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ProjectileCastService = require(ReplicatedStorage.Submodules.Core.Libraries.ProjectileCast.ProjectileCastService)
local WeaponData = require(ReplicatedStorage.Submodules.Core.Shared.Data.WeaponData)
local RelicTriggerData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicTriggerData)
local helpers = require(script.Parent.gimmickHelpers)

-- A gun with no maxRange flies this far (the bullet library's default).
local DEFAULT_RANGE = 75
-- The sweep's sphere: a touch fatter than a bullet, so the visual's
-- size and what it hits agree.
local SHOT_RADIUS = 0.75
-- The ids wrap well inside the payload's f32.
local MAX_ID = 1000000

local relicShots = {}

local nextId = 0

function relicShots.fire(
	player: Player,
	kind: string,
	origin: Vector3,
	direction: Vector3,
	weaponName: string,
	speed: number,
	onHit: (position: Vector3, target: Model?) -> ()
)
	nextId = nextId % MAX_ID + 1
	local id = nextId
	local weapon = WeaponData[weaponName]
	local range = (weapon and weapon.maxRange) or DEFAULT_RANGE
	-- The aim lifted LiftDegrees toward straight up (a level aim leaves at
	-- exactly that angle).
	local lift = math.tan(math.rad(RelicTriggerData.Shot.LiftDegrees))
	local velocity = (direction.Unit + Vector3.new(0, lift, 0)).Unit * speed
	local gravity = RelicTriggerData.Shot.Gravity
	local maxSeconds = range / speed + 0.5
	helpers.fx(kind, origin, origin + velocity, id, maxSeconds, player)
	ProjectileCastService:LaunchRelicShot(
		player,
		origin,
		velocity,
		gravity,
		range,
		SHOT_RADIUS,
		function(position: Vector3, target: Model?)
			helpers.fx("RelicShotEnd", position, position, id, 0, player)
			if player.Parent then
				helpers.hitBreakables(player, position, helpers.POINT_BREAK_RADIUS)
				onHit(position, target)
			end
		end
	)
end

return relicShots
