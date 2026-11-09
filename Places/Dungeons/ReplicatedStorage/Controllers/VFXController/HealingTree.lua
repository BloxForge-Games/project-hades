--!strict
-- Healing Tree, client side (2026-11-08): a glowing magic tree grows out of
-- the floor `treeOffset` studs ahead of the cast (the same spot the server
-- heals around, VFXService/ServerCasts/HealingTree), with a green ring at
-- the real heal radius, drifting leaves, rising sparks and a soft light.
-- It stands `treeSeconds`, then shrinks back into the ground. Built from
-- plain parts: stock art until a real model ships.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local ArcaneData = require(ReplicatedStorage.Submodules.Core.Shared.Data.ArcaneData)
local ArcaneNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ArcaneNames)
local GameClock = require(ReplicatedStorage.Submodules.Core.Shared.GameClock)

local SPELL = ArcaneNames["Healing Tree"]
local BARK = Color3.fromRGB(120, 86, 60)
local BARK_GLOW = Color3.fromRGB(150, 255, 170)
local LEAF = Color3.fromRGB(110, 255, 150)
local LEAF_DEEP = Color3.fromRGB(40, 200, 110)
local SPARK_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"
local LEAF_TEXTURE = "rbxasset://textures/particles/smoke_main.dds"
local FLOOR_SEARCH = 12
local GROW = TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local SHRINK = TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local function effectsFolder(): Instance
	local ignore = workspace:FindFirstChild("IgnoreInstances")
	return (ignore and ignore:FindFirstChild("ArcaneSpells")) or ignore or workspace
end

-- The same base as the server's: ahead of `cframe`, dropped to the floor.
local function treeBase(cframe: CFrame, offset: number): Vector3
	local look = Vector3.new(cframe.LookVector.X, 0, cframe.LookVector.Z)
	look = if look.Magnitude > 1e-3 then look.Unit else Vector3.zAxis
	local point = cframe.Position + look * offset
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ignore: { Instance } = {}
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(ignore, player.Character)
		end
	end
	local ignoreFolder = workspace:FindFirstChild("IgnoreInstances")
	if ignoreFolder then
		table.insert(ignore, ignoreFolder)
	end
	params.FilterDescendantsInstances = ignore
	local hit = workspace:Raycast(point + Vector3.new(0, 2, 0), Vector3.new(0, -FLOOR_SEARCH, 0), params)
	return if hit then hit.Position else point - Vector3.new(0, 3, 0)
end

local function part(name: string, shape: Enum.PartType, material: Enum.Material, color: Color3): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Shape = shape
	p.Material = material
	p.Color = color
	return p
end

-- Grows `p` from a sliver to `size` at `cframe` (the base stays put for
-- the trunk because its CFrame is tweened with the size).
local function grow(p: Part, fromCFrame: CFrame, toCFrame: CFrame, size: Vector3, delay: number)
	p.Size = Vector3.new(0.05, 0.05, 0.05)
	p.CFrame = fromCFrame
	GameClock.Delay(delay, function()
		if p.Parent then
			TweenService:Create(p, GROW, { Size = size, CFrame = toCFrame }):Play()
		end
	end)
end

return function(player: Player, preload: boolean?, cframe: CFrame?)
	if preload then
		return
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local castCFrame = cframe or (root and root:IsA("BasePart") and root.CFrame) or nil
	if not castCFrame then
		return
	end
	local data = ArcaneData[SPELL]
	local seconds = data.treeSeconds or 5
	local radius = data.treeRadius or 14
	local base = treeBase(castCFrame, data.treeOffset or 5)

	local model = Instance.new("Model")
	model.Name = "HealingTree"
	local spin = CFrame.Angles(0, math.random() * math.pi * 2, 0)
	local origin = CFrame.new(base) * spin
	local parts: { Part } = {}
	local function add(p: Part): Part
		p.Parent = model
		table.insert(parts, p)
		return p
	end

	-- The trunk: grows up out of the floor.
	local trunkHeight = 9
	local trunk = add(part("Trunk", Enum.PartType.Cylinder, Enum.Material.Wood, BARK))
	local upright = CFrame.Angles(0, 0, math.rad(90))
	grow(
		trunk,
		origin * upright,
		origin * CFrame.new(0, trunkHeight / 2, 0) * upright,
		Vector3.new(trunkHeight, 1.6, 1.6),
		0
	)
	-- Glowing veins up the bark.
	local vein = add(part("Vein", Enum.PartType.Cylinder, Enum.Material.Neon, BARK_GLOW))
	vein.Transparency = 0.4
	grow(
		vein,
		origin * upright,
		origin * CFrame.new(0, trunkHeight / 2, 0) * upright,
		Vector3.new(trunkHeight * 0.95, 1.75, 0.5),
		0
	)

	-- Three branches leaning out of the top of the trunk.
	for index = 1, 3 do
		local yaw = CFrame.Angles(0, math.rad(index * 120), 0)
		local branch = add(part("Branch", Enum.PartType.Cylinder, Enum.Material.Wood, BARK))
		local at = origin * CFrame.new(0, trunkHeight * 0.75, 0) * yaw * CFrame.Angles(0, 0, math.rad(50))
		grow(branch, at, at * CFrame.new(1.6, 0, 0), Vector3.new(3.6, 0.8, 0.8), 0.15)
	end

	-- The canopy: soft glowing spheres, inner bright and outer clouds.
	local canopyCenter = origin * CFrame.new(0, trunkHeight + 1.5, 0)
	local core = add(part("CanopyCore", Enum.PartType.Ball, Enum.Material.Neon, LEAF))
	core.Transparency = 0.25
	grow(core, canopyCenter, canopyCenter, Vector3.one * 6, 0.25)
	local cloudOffsets = {
		Vector3.new(3, -0.5, 0),
		Vector3.new(-1.5, -0.5, 2.6),
		Vector3.new(-1.5, -0.5, -2.6),
		Vector3.new(0, 2.2, 0),
	}
	for _, offset in cloudOffsets do
		local cloud = add(part("Canopy", Enum.PartType.Ball, Enum.Material.Neon, LEAF_DEEP))
		cloud.Transparency = 0.45
		local at = canopyCenter * CFrame.new(offset)
		grow(cloud, canopyCenter, at, Vector3.one * 5, 0.3)
	end

	-- The heal circle on the floor, at the real radius.
	local flat = CFrame.new(base + Vector3.new(0, 0.08, 0)) * CFrame.Angles(0, 0, math.rad(90))
	local ring = add(part("Ring", Enum.PartType.Cylinder, Enum.Material.Neon, LEAF))
	ring.Transparency = 0.35
	grow(ring, flat, flat, Vector3.new(0.12, radius * 2, radius * 2), 0)
	local disc = add(part("Floor", Enum.PartType.Cylinder, Enum.Material.Neon, LEAF_DEEP))
	disc.Transparency = 0.9
	grow(
		disc,
		flat * CFrame.new(-0.03, 0, 0),
		flat * CFrame.new(-0.03, 0, 0),
		Vector3.new(0.08, radius * 2 - 0.4, radius * 2 - 0.4),
		0
	)

	-- Leaves drifting down out of the canopy.
	local leaves = Instance.new("ParticleEmitter")
	leaves.Texture = LEAF_TEXTURE
	leaves.Color = ColorSequence.new(LEAF, LEAF_DEEP)
	leaves.LightEmission = 0.6
	leaves.Size = NumberSequence.new(0.6, 0.2)
	leaves.Transparency = NumberSequence.new(0.2, 1)
	leaves.Lifetime = NumberRange.new(1.5, 2.5)
	leaves.Speed = NumberRange.new(1, 3)
	leaves.SpreadAngle = Vector2.new(180, 180)
	leaves.Acceleration = Vector3.new(0, -3, 0)
	leaves.RotSpeed = NumberRange.new(-90, 90)
	leaves.Rate = 14
	leaves.Parent = core

	-- Sparks rising across the heal circle.
	local sparks = Instance.new("ParticleEmitter")
	sparks.Texture = SPARK_TEXTURE
	sparks.Color = ColorSequence.new(LEAF, BARK_GLOW)
	sparks.LightEmission = 1
	sparks.Size = NumberSequence.new(0.45, 0)
	sparks.Transparency = NumberSequence.new(0.1, 1)
	sparks.Lifetime = NumberRange.new(0.9, 1.5)
	sparks.Speed = NumberRange.new(3, 6)
	sparks.EmissionDirection = Enum.NormalId.Right
	sparks.SpreadAngle = Vector2.new(5, 5)
	sparks.Shape = Enum.ParticleEmitterShape.Disc
	sparks.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	sparks.Rate = 35
	sparks.Parent = disc

	local light = Instance.new("PointLight")
	light.Color = LEAF
	light.Brightness = 1.6
	light.Range = radius + 4
	light.Parent = core

	-- The canopy breathes while the tree stands.
	GameClock.Delay(0.8, function()
		if core.Parent then
			TweenService:Create(
				core,
				TweenInfo.new(0.9, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
				{ Transparency = 0.5 }
			):Play()
		end
	end)

	model.Parent = effectsFolder()

	local sound = ReplicatedStorage.GameAssets.Sounds:FindFirstChild(data.castSound)
	if sound and sound:IsA("Sound") and root then
		local copy = sound:Clone()
		copy.Parent = root
		copy:Play()
		GameClock.Debris(copy, 4)
	end

	-- The end: everything shrinks back into the floor and fades.
	GameClock.Delay(seconds, function()
		leaves.Enabled = false
		sparks.Enabled = false
		light.Enabled = false
		for _, p in parts do
			if p.Parent then
				TweenService:Create(p, SHRINK, { Size = p.Size * 0.05, Transparency = 1 }):Play()
			end
		end
		GameClock.Debris(model, 1.5)
	end)
end
