local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)

local QuadraticBezierController = Knit.CreateController({
	Name = "QuadraticBezierController",
})

local Y_AXIS_DECREASE: number = 200
local BEZIER_PART_LIFETIME = 30

function QuadraticBezierController:GenerateBezierCurve(t, p0, p1, p2): Vector3
	return (1 - t) ^ 2 * p0 + 2 * (1 - t) * t * p1 + t ^ 2 * p2
end

-- For debugging purposes
function QuadraticBezierController:GenerateBezierParts(targetRadius: Part, origin: Part): (Part?, Part?)
	local part0: Part = targetRadius:FindFirstChild("Part0")
	local part1: Part = targetRadius:FindFirstChild("Part1")

	if not part0 or not part1 then
		return
	end

	local aX: number = part0.CFrame.X
	local bX: number = part1.CFrame.X
	local aZ: number = part0.CFrame.Z
	local bZ: number = part1.CFrame.Z

	if not aX or not bX or not aZ or not bZ then
		return
	end

	local randomXPosition: number? = math.random(math.min(aX, bX), math.max(aX, bX))
	local randomZPosition: number? = math.random(math.min(aZ, bZ), math.max(aZ, bZ))

	local endPoint: Part = Instance.new("Part")
	endPoint.CFrame = CFrame.new(randomXPosition, targetRadius.Position.Y, randomZPosition)
	endPoint.Anchored = true
	endPoint.Parent = workspace:FindFirstChild("Snowballs")

	local intermediatePoint: Part = Instance.new("Part")
	intermediatePoint.Position = (origin.Position + endPoint.Position) / 2
	intermediatePoint.CFrame = intermediatePoint.CFrame + Vector3.new(0, origin.Position.Y - Y_AXIS_DECREASE, 0)
	intermediatePoint.Anchored = true
	intermediatePoint.Parent = workspace:FindFirstChild("Snowballs")

	local rootPart: Part = origin.Parent:FindFirstChild("RootPart")

	endPoint.CFrame = CFrame.lookAt(
		endPoint.Position,
		Vector3.new(intermediatePoint.Position.X, targetRadius.Position.Y, intermediatePoint.Position.Z)
	)
	rootPart.CFrame = CFrame.lookAt(
		rootPart.Position,
		Vector3.new(intermediatePoint.Position.X, rootPart.Position.Y, intermediatePoint.Position.Z)
	)

	Debris:AddItem(intermediatePoint, BEZIER_PART_LIFETIME)
	Debris:AddItem(endPoint, BEZIER_PART_LIFETIME)

	return intermediatePoint, endPoint
end

return QuadraticBezierController
