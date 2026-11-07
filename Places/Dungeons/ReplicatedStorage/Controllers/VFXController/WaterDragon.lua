--!strict
-- Water Dragon, client side (PROTOTYPE, 2026-11-07): the cast, and a
-- serpent of water (a glowing head and a trailing body of spheres, spray
-- streaming off it) that rushes down the caster's facing for
-- `travelDistance` at `dragonSpeed`, the same run the server's hits follow
-- (VFXService/ServerCasts/WaterDragon).
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local ArcaneData = require(ReplicatedStorage.Submodules.Core.Shared.Data.ArcaneData)
local ArcaneNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ArcaneNames)
local GameClock = require(ReplicatedStorage.Submodules.Core.Shared.GameClock)
local loadOneShotAnimation = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Character.loadOneShotAnimation)

local SPELL = ArcaneNames["Water Dragon"]
local WATER = Color3.fromRGB(70, 160, 255)
local FOAM = Color3.fromRGB(210, 240, 255)
local SPRAY_TEXTURE = "rbxasset://textures/particles/smoke_main.dds"
-- Body spheres trailing the head, and the gap between them (studs).
local BODY_SEGMENTS = 7
local SEGMENT_GAP = 2.2
-- How high above the caster's root the dragon flies, and how it weaves.
local FLY_HEIGHT = 0.5
local WEAVE_STUDS = 1.2
local WEAVE_RATE = 9

local function effectsFolder(): Instance
	local ignore = workspace:FindFirstChild("IgnoreInstances")
	return (ignore and ignore:FindFirstChild("ArcaneSpells")) or ignore or workspace
end

local function sphere(size: number, color: Color3, transparency: number): Part
	local part = Instance.new("Part")
	part.Shape = Enum.PartType.Ball
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Material = Enum.Material.Neon
	part.Color = color
	part.Transparency = transparency
	part.Size = Vector3.one * size
	return part
end

return function(player: Player, preload: boolean?, cframe: CFrame?)
	local character = player.Character
	if preload or not character then
		return
	end
	local data = ArcaneData[SPELL]
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	local asset = ReplicatedStorage.GameAssets.Animations:FindFirstChild(data.castAnimation)
	if animator and asset and asset:IsA("Animation") then
		loadOneShotAnimation(animator, asset):Play(0.05)
	end
	local sound = ReplicatedStorage.GameAssets.Sounds:FindFirstChild(data.castSound)
	if sound and sound:IsA("Sound") then
		local copy = sound:Clone()
		copy.Parent = root
		copy:Play()
		GameClock.Debris(copy, 4)
	end

	local start = cframe or root.CFrame
	local origin = start.Position + Vector3.new(0, FLY_HEIGHT, 0)
	local look = Vector3.new(start.LookVector.X, 0, start.LookVector.Z)
	look = if look.Magnitude > 0.01 then look.Unit else Vector3.zAxis
	local side = look:Cross(Vector3.yAxis)
	local total = data.travelDistance or 40
	local speed = math.max(data.dragonSpeed or 60, 1)

	local folder = Instance.new("Folder")
	folder.Name = "WaterDragon"
	local head = sphere(4.5, WATER, 0.05)
	head.Parent = folder
	local spray = Instance.new("ParticleEmitter")
	spray.Texture = SPRAY_TEXTURE
	spray.Color = ColorSequence.new(FOAM)
	spray.Size = NumberSequence.new(2.5, 5)
	spray.Transparency = NumberSequence.new(0.3, 1)
	spray.Lifetime = NumberRange.new(0.3, 0.6)
	spray.Speed = NumberRange.new(4, 8)
	spray.SpreadAngle = Vector2.new(60, 60)
	spray.Rate = 90
	spray.Parent = head
	local body: { Part } = {}
	for index = 1, BODY_SEGMENTS do
		local part = sphere(4 - index * 0.35, WATER, 0.15 + index * 0.08)
		part.Parent = folder
		body[index] = part
	end
	folder.Parent = effectsFolder()

	-- A point on the dragon's path `distance` studs in, weaving side to side.
	local function pathPoint(distance: number): Vector3
		local clamped = math.clamp(distance, 0, total)
		return origin + look * clamped + side * math.sin(clamped / total * WEAVE_RATE) * WEAVE_STUDS
	end

	local started = os.clock()
	local connection: RBXScriptConnection? = nil
	connection = RunService.RenderStepped:Connect(function()
		local travelled = (os.clock() - started) * speed
		local headAt = pathPoint(travelled)
		head.CFrame = CFrame.lookAt(headAt, headAt + look)
		for index, part in body do
			part.CFrame = CFrame.new(pathPoint(travelled - index * SEGMENT_GAP))
		end
		-- Done once the tail has caught up with the end of the lane.
		if travelled - BODY_SEGMENTS * SEGMENT_GAP >= total then
			if connection then
				connection:Disconnect()
			end
			spray.Enabled = false
			for _, part in body do
				part.Transparency = 1
			end
			head.Transparency = 1
			GameClock.Debris(folder, 0.7)
		end
	end)
	-- A safety net if the loop is cut short.
	GameClock.Debris(folder, total / speed + 3)
end
