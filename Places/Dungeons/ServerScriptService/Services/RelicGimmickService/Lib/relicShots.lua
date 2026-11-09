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

	FOLLOW (2026-11-05, the Ice Arrow off a bow): a shot fired with
	`follow` from a weapon with ballisticAim flies the weapon's OWN path
	instead -- the shot's exact direction, the weapon's velocity and drop,
	no lift -- FOLLOW_DELAY_SECONDS after it, so it trails the arrow on
	the same arc. Every client draws it with the weapon's drop too
	(RelicShotVFXController, from the caster's drawn weapon).

	RE-AIM (2026-11-08): a DELAYED shot (the Ice Arrow's and the
	Paintball's 0.5 s beat) no longer flies the aim and muzzle of the
	moment it was set off -- by then the mob had moved and so had the
	shooter, and it missed. The mob that shot was aimed at is picked then
	(the nearest within AIM_CONE_DEGREES of the aim, in range), and at
	launch the shot leaves from the shooter's CURRENT muzzle toward that
	mob's CURRENT position, lifted for the drop. With no mob picked (or it
	died) it flies the shooter's current facing.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ProjectileCastService = require(ReplicatedStorage.Submodules.Core.Libraries.ProjectileCast.ProjectileCastService)
local WeaponData = require(ReplicatedStorage.Submodules.Core.Shared.Data.WeaponData)
local RelicTriggerData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicTriggerData)
local GameClock = require(ReplicatedStorage.Submodules.Core.Shared.GameClock)
local getRoot = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Character.getRoot)
local helpers = require(script.Parent.gimmickHelpers)

-- A gun with no maxRange flies this far (the bullet library's default).
local DEFAULT_RANGE = 75
-- The sweep's sphere: a touch fatter than a bullet, so the visual's
-- size and what it hits agree.
local SHOT_RADIUS = 0.75
-- The ids wrap well inside the payload's f32.
local MAX_ID = 1000000
-- A following shot leaves this long after the weapon's own (0.1 -> 0.15,
-- 2026-11-05: room for the shooter's second draw, the double shot).
local FOLLOW_DELAY_SECONDS = 0.15
-- A delayed shot's target: the nearest living mob within this angle of the
-- aim (RE-AIM above).
local AIM_CONE_DEGREES = 25

local relicShots = {}

local function flat(vector: Vector3): Vector3
	return Vector3.new(vector.X, 0, vector.Z)
end

-- The living mob `direction` from `origin` points at: the nearest within
-- AIM_CONE_DEGREES and `range`, or nil.
local function aimTarget(origin: Vector3, direction: Vector3, range: number): BasePart?
	local ignore = workspace:FindFirstChild("IgnoreInstances")
	local folder = ignore and ignore:FindFirstChild("Mobs")
	local aim = flat(direction)
	if not folder or aim.Magnitude < 0.05 then
		return nil
	end
	aim = aim.Unit
	local minDot = math.cos(math.rad(AIM_CONE_DEGREES))
	local best: BasePart? = nil
	local bestDistance = range
	for _, model in folder:GetChildren() do
		if not model:IsA("Model") then
			continue
		end
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		local root = model:FindFirstChild("HumanoidRootPart")
		if not humanoid or humanoid.Health <= 0 or not root or not root:IsA("BasePart") then
			continue
		end
		local to = flat(root.Position - origin)
		local distance = to.Magnitude
		if distance > 0.05 and distance < bestDistance and aim:Dot(to.Unit) >= minDot then
			best, bestDistance = root, distance
		end
	end
	return best
end

local function targetAlive(root: BasePart): boolean
	local model = root.Parent
	local humanoid = model and model:FindFirstChildOfClass("Humanoid")
	return root.Parent ~= nil and humanoid ~= nil and humanoid.Health > 0
end

local nextId = 0

function relicShots.fire(
	player: Player,
	kind: string,
	origin: Vector3,
	direction: Vector3,
	weaponName: string,
	speed: number,
	onHit: (position: Vector3, target: Model?) -> (),
	follow: boolean?,
	delayOverride: number?
)
	nextId = nextId % MAX_ID + 1
	local id = nextId
	local weapon = WeaponData[weaponName]
	local range = ((weapon and weapon.maxRange) or DEFAULT_RANGE) + ((weapon and weapon.rangeSlack) or 0)
	local velocity: Vector3
	local gravity: number
	local delaySeconds = 0
	local followed = follow == true and weapon ~= nil and weapon.ballisticAim == true
	if followed then
		-- The weapon's own flight, a beat behind it.
		speed = tonumber(weapon.velocity) or speed
		velocity = direction.Unit * speed
		gravity = tonumber(weapon.drop) or RelicTriggerData.Shot.Gravity
		delaySeconds = FOLLOW_DELAY_SECONDS
	else
		-- The aim lifted LiftDegrees toward straight up (a level aim leaves
		-- at exactly that angle).
		local lift = math.tan(math.rad(RelicTriggerData.Shot.LiftDegrees))
		velocity = (direction.Unit + Vector3.new(0, lift, 0)).Unit * speed
		gravity = RelicTriggerData.Shot.Gravity
	end
	-- A relic's own beat after the weapon's shot, from any weapon
	-- (2026-11-08: the Paintball's, timed to its draw animation).
	if delayOverride then
		delaySeconds = delayOverride
	end
	local maxSeconds = range / speed + 0.5
	-- RE-AIM (above): a delayed shot remembers its target and the shooter's
	-- spot now, and aims again when it leaves.
	local aimedAt = if delaySeconds > 0 then aimTarget(origin, direction, range) else nil
	local character = player.Character
	local rootAtFire = character and getRoot(character)
	local firedFrom = if rootAtFire then rootAtFire.Position else nil
	local function launch()
		if not player.Parent then
			return
		end
		local launchOrigin = origin
		local launchVelocity = velocity
		if delaySeconds > 0 then
			local liveCharacter = player.Character
			local liveRoot = liveCharacter and getRoot(liveCharacter)
			if liveRoot and firedFrom then
				-- The muzzle moved with the shooter.
				launchOrigin = origin + (liveRoot.Position - firedFrom)
			end
			local aimAt: Vector3? = nil
			if aimedAt and targetAlive(aimedAt) then
				-- Lifted by the drop over the flight, so it lands on the mob.
				local flightSeconds = (aimedAt.Position - launchOrigin).Magnitude / speed
				aimAt = aimedAt.Position + Vector3.new(0, 0.5 * gravity * flightSeconds * flightSeconds, 0)
			elseif liveRoot then
				aimAt = launchOrigin + liveRoot.CFrame.LookVector * range
			end
			if aimAt and (aimAt - launchOrigin).Magnitude > 0.05 then
				launchVelocity = (aimAt - launchOrigin).Unit * speed
			end
		end
		helpers.fx(kind, launchOrigin, launchOrigin + launchVelocity, id, maxSeconds, player)
		ProjectileCastService:LaunchRelicShot(
			player,
			launchOrigin,
			launchVelocity,
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
	if delaySeconds > 0 then
		GameClock.Delay(delaySeconds, launch)
	else
		launch()
	end
end

return relicShots
