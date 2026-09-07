-- A controller that provides a series of Raycast helper functions

local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)

-- Below this planar speed a target counts as stationary and gets no lead —
-- Humanoid velocity jitters slightly even when standing still.
local MIN_LEAD_SPEED = 1
local MAX_RAYCAST_DISTANCE = 500
local RAY_SPREAD_ANGLE = 5
local RAY_INCREMENT_ANGLE = 5
local MAX_RAY_COUNT = 10
local VISUALIZE_RAYCAST = false

local camera = workspace.CurrentCamera

local ProximityRayController = Knit.CreateController({
	Name = "ProximityRayController",
	_camera = workspace.CurrentCamera :: Camera,
	_raycastResult = nil,
})

function ProximityRayController:GetRayResult(ignoreList: table, filterType: string, x: number, y: number): RaycastResult
	local mouseCastParams = RaycastParams.new()
	mouseCastParams.FilterDescendantsInstances = ignoreList
	mouseCastParams.FilterType = Enum.RaycastFilterType[filterType]

	local unitRay = camera:ViewportPointToRay(x, y)

	return workspace:Raycast(unitRay.Origin, unitRay.Direction * MAX_RAYCAST_DISTANCE, mouseCastParams)
end

-- Lead offset for a moving target: how far AHEAD of the mob to aim so the
-- bullet and the mob arrive at the same place.
--
-- Correct lead is `velocity × timeToTarget`, and timeToTarget is
-- `distance ÷ projectileSpeed`. Both terms matter, which is what the old
-- implementation got wrong: it applied `velocity / 4` — a fixed quarter
-- second of lead — and ONLY past 25 studs. So it led by a constant amount
-- regardless of how far the target was or how fast the gun shot, and led by
-- nothing at all inside 25 studs before snapping to that constant.
--
-- The failure that surfaces first is a mob running perpendicular at range:
-- real flight time there is well over 0.25s, so the aim point lands behind
-- it and the shot misses entirely. This affects mouse aim and mobile
-- auto-aim identically — both targeting paths call through here.
--
-- Y velocity is dropped deliberately. Mobs are ground units; folding in a
-- jump or a knockback's vertical component would lift the aim point off
-- their body and produce misses over flat ground.
function ProximityRayController:GetVelocityOffset(raycastResult: RaycastResult, projectileSpeed: number?): Vector3
	local raycastModel: Model? = raycastResult.Instance:FindFirstAncestorWhichIsA("Model")
		or raycastResult.Instance.Parent:FindFirstAncestorWhichIsA("Model")

	local targetRoot = raycastModel and raycastModel:FindFirstChild("HumanoidRootPart")
	local character = Players.LocalPlayer.Character
	local originRoot = character and character:FindFirstChild("HumanoidRootPart")

	-- No speed means the caller couldn't resolve weapon data. Aiming dead-on
	-- is a far better failure than leading by a garbage amount.
	if not targetRoot or not originRoot or not projectileSpeed or projectileSpeed <= 0 then
		return Vector3.zero
	end

	local velocity = targetRoot.AssemblyLinearVelocity
	local flatVelocity = Vector3.new(velocity.X, 0, velocity.Z)

	-- Near-stationary mobs get no lead. Humanoid velocity jitters slightly
	-- even when standing, and leading off that noise walks the aim point
	-- around a target that isn't going anywhere.
	if flatVelocity.Magnitude < MIN_LEAD_SPEED then
		return Vector3.zero
	end

	local distance = (originRoot.Position - targetRoot.Position).Magnitude

	return flatVelocity * (distance / projectileSpeed)
end

function ProximityRayController:_ComputeRaycastAngles(
	params: RaycastParams,
	angle1: number,
	angle2: number,
	tag: string
)
	if self._raycastResult then
		return
	end

	local rayCFrame = Players.LocalPlayer.Character.HumanoidRootPart.CFrame
	local rayDirection = rayCFrame * CFrame.Angles(math.rad(angle1), math.rad(angle2), 0)

	local raycastResult = workspace:Raycast(rayCFrame.Position, rayDirection.LookVector * MAX_RAYCAST_DISTANCE, params)

	if not raycastResult then
		return
	end

	local raycastModel: Model? = raycastResult.Instance:FindFirstAncestorWhichIsA("Model")
		or raycastResult.Instance.Parent:FindFirstAncestorWhichIsA("Model")

	if tag and not CollectionService:HasTag(raycastModel, tag) then
		return
	end

	local distance = (Players.LocalPlayer.Character.HumanoidRootPart.Position - raycastResult.Position).Magnitude

	if VISUALIZE_RAYCAST then
		local part = Instance.new("Part")
		part.Parent = workspace.CurrentCamera
		part.CFrame = CFrame.lookAt(Players.LocalPlayer.Character.HumanoidRootPart.Position, raycastResult.Position)
			* CFrame.new(0, 0, -distance / 2)
		part.Size = Vector3.new(0.1, 0.1, distance)
		part.Anchored = true
		part.CanCollide = false
		part.BrickColor = BrickColor.new("Really red")

		Debris:AddItem(part, 3)
	end

	self._raycastResult = raycastResult
end

function ProximityRayController:CastProximityRays(raycastParams: RaycastParams, tag: string?)
	local castCount = 25

	self._raycastResult = nil

	for _ = 1, MAX_RAY_COUNT, 1 do
		self:_ComputeRaycastAngles(raycastParams, castCount, 0, tag)
		self:_ComputeRaycastAngles(raycastParams, castCount, RAY_SPREAD_ANGLE, tag)
		self:_ComputeRaycastAngles(raycastParams, castCount, -RAY_SPREAD_ANGLE, tag)

		castCount -= RAY_INCREMENT_ANGLE

		if self._raycastResult then
			break
		end
	end

	return self._raycastResult
end

return ProximityRayController
