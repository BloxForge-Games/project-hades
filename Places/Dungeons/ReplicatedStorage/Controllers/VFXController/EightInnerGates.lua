--!strict
-- Eight Inner Gates, client side (2026-11-08): the gates flare (a red-green
-- burst and steam at the caster), the caster lunges toward their aim (their
-- own client only), burning fists stream out in
-- the cone for the flurry, and the finisher throws a fiery shockwave
-- forward. The open gate's look is the Enflamed aura the server grants
-- for `gateSeconds` (AuraService). The hits, the damage reduction and the gate's speed are
-- the server's (VFXService/ServerCasts/EightInnerGates); the caster's
-- client re-applies its walk speed when the gate opens and closes.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local DodgeController = require(ReplicatedStorage.Submodules.Core.Source.Controllers.DodgeController)
local ArcaneData = require(ReplicatedStorage.Submodules.Core.Shared.Data.ArcaneData)
local ArcaneNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ArcaneNames)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local GameClock = require(ReplicatedStorage.Submodules.Core.Shared.GameClock)
local claimWalkSpeed = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Movement.claimWalkSpeed)
local restoreWalkSpeed = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Movement.restoreWalkSpeed)
local loadOneShotAnimation = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Character.loadOneShotAnimation)

local SPELL = ArcaneNames["Eight Inner Gates"]
local GATE_RED = Color3.fromRGB(255, 70, 50)
local GATE_GREEN = Color3.fromRGB(90, 255, 160)
local FIRE = Color3.fromRGB(255, 150, 60)
local SPARK_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"
local AFTER_DASH = 0.1
-- Fists per punch, fanned across the cone.
local FISTS_PER_PUNCH = 3

local function effectsFolder(): Instance
	local ignore = workspace:FindFirstChild("IgnoreInstances")
	return (ignore and ignore:FindFirstChild("ArcaneSpells")) or ignore or workspace
end

local function bare(p: Part)
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
end

local function playSound(name: string, parent: Instance)
	local sound = ReplicatedStorage.GameAssets.Sounds:FindFirstChild(name)
	if sound and sound:IsA("Sound") then
		local copy = sound:Clone()
		copy.Parent = parent
		copy:Play()
		GameClock.Debris(copy, 4)
	end
end

-- The gates flare: a red-green ball bursting out of the caster and a ring
-- racing across the floor.
local function flare(root: BasePart)
	local folder = effectsFolder()
	local ball = Instance.new("Part")
	bare(ball)
	ball.Shape = Enum.PartType.Ball
	ball.Material = Enum.Material.Neon
	ball.Color = GATE_RED
	ball.Transparency = 0.2
	ball.Size = Vector3.one * 3
	ball.CFrame = root.CFrame
	ball.Parent = folder
	TweenService:Create(
		ball,
		TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.one * 12, Transparency = 1, Color = GATE_GREEN }
	):Play()
	GameClock.Debris(ball, 0.35)

	local ring = Instance.new("Part")
	bare(ring)
	ring.Shape = Enum.PartType.Cylinder
	ring.Material = Enum.Material.Neon
	ring.Color = GATE_GREEN
	ring.Transparency = 0.2
	ring.Size = Vector3.new(0.3, 2, 2)
	ring.CFrame = CFrame.new(root.Position - Vector3.new(0, 2.8, 0)) * CFrame.Angles(0, 0, math.rad(90))
	ring.Parent = folder
	TweenService:Create(
		ring,
		TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.new(0.3, 18, 18), Transparency = 1 }
	):Play()
	GameClock.Debris(ring, 0.4)
end

-- One punch: burning fists shooting out across the cone ahead of `root`.
local function fists(root: BasePart, length: number, angle: number)
	local folder = effectsFolder()
	local origin = root.Position + Vector3.new(0, 0.6, 0)
	local look = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
	look = if look.Magnitude > 1e-3 then look.Unit else Vector3.zAxis
	for _ = 1, FISTS_PER_PUNCH do
		local yaw = math.rad((math.random() - 0.5) * angle)
		local direction = (CFrame.Angles(0, yaw, 0) * look)
		local height = (math.random() - 0.5) * 2
		local fist = Instance.new("Part")
		bare(fist)
		fist.Shape = Enum.PartType.Ball
		fist.Material = Enum.Material.Neon
		fist.Color = FIRE
		fist.Transparency = 0.1
		fist.Size = Vector3.new(1.6, 1.6, 1.6)
		local from = origin + direction * 1.5 + Vector3.new(0, height, 0)
		fist.CFrame = CFrame.lookAt(from, from + direction)
		fist.Parent = folder

		local trail = Instance.new("Trail")
		local a0 = Instance.new("Attachment")
		a0.Position = Vector3.new(0, 0.6, 0)
		a0.Parent = fist
		local a1 = Instance.new("Attachment")
		a1.Position = Vector3.new(0, -0.6, 0)
		a1.Parent = fist
		trail.Attachment0 = a0
		trail.Attachment1 = a1
		trail.Color = ColorSequence.new(FIRE, GATE_RED)
		trail.LightEmission = 1
		trail.Transparency = NumberSequence.new(0.1, 1)
		trail.Lifetime = 0.15
		trail.FaceCamera = true
		trail.Parent = fist

		local travel = length * (0.7 + math.random() * 0.3)
		TweenService:Create(
			fist,
			TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ CFrame = fist.CFrame + direction * travel, Transparency = 1, Size = Vector3.new(2.4, 2.4, 2.4) }
		):Play()
		GameClock.Debris(fist, 0.35)
	end
end

-- The finisher: a fiery wedge of shock thrown forward and a flash.
local function finisherBlast(root: BasePart, length: number)
	local folder = effectsFolder()
	local look = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
	look = if look.Magnitude > 1e-3 then look.Unit else Vector3.zAxis
	local floor = root.Position - Vector3.new(0, 2.8, 0)

	local wave = Instance.new("Part")
	bare(wave)
	wave.Shape = Enum.PartType.Cylinder
	wave.Material = Enum.Material.Neon
	wave.Color = FIRE
	wave.Transparency = 0.15
	wave.Size = Vector3.new(0.4, 3, 3)
	wave.CFrame = CFrame.new(floor + look * 2) * CFrame.Angles(0, 0, math.rad(90))
	wave.Parent = folder
	TweenService:Create(wave, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.4, length * 1.4, length * 1.4),
		CFrame = CFrame.new(floor + look * length * 0.5) * CFrame.Angles(0, 0, math.rad(90)),
		Transparency = 1,
	}):Play()
	GameClock.Debris(wave, 0.35)

	local holder = Instance.new("Part")
	bare(holder)
	holder.Transparency = 1
	holder.Size = Vector3.one
	holder.CFrame = CFrame.lookAt(root.Position, root.Position + look)
	local burst = Instance.new("ParticleEmitter")
	burst.Texture = SPARK_TEXTURE
	burst.Color = ColorSequence.new(FIRE, GATE_RED)
	burst.LightEmission = 1
	burst.Size = NumberSequence.new(1.2, 0)
	burst.Lifetime = NumberRange.new(0.3, 0.6)
	burst.Speed = NumberRange.new(length * 2, length * 3.5)
	burst.SpreadAngle = Vector2.new(35, 15)
	burst.EmissionDirection = Enum.NormalId.Front
	burst.Rate = 0
	burst.Parent = holder
	holder.Parent = folder
	burst:Emit(60)
	GameClock.Debris(holder, 1)
end

return function(player: Player, preload: boolean?)
	local character = player.Character
	if preload or not character then
		return
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return
	end
	local data = ArcaneData[SPELL]
	local length = data.coneLength or 14
	local angle = data.coneAngle or 80
	local hits = data.flurryHits or 6
	local flurrySeconds = data.flurrySeconds or 0.6
	local flareSeconds = data.flareSeconds or 0.75
	local dashSeconds = data.dashSeconds or 0.2
	local start = flareSeconds + dashSeconds + AFTER_DASH
	local isCaster = player == Players.LocalPlayer

	playSound(data.castSound, root)
	flare(root)

	local claim = claimWalkSpeed(character, 0)
	-- The charge ends with the gates bursting open again as the caster
	-- launches (the 0.75 s charge would otherwise go quiet after the first).
	GameClock.Delay(flareSeconds, function()
		local liveRoot = character:FindFirstChild("HumanoidRootPart")
		if liveRoot and liveRoot:IsA("BasePart") then
			flare(liveRoot)
		end
		if isCaster then
			DodgeController:SetDodgeCFrame(data.dashStuds or 10, dashSeconds, true)
		end
	end)

	-- The punch animation, replayed through the flurry.
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	local asset = ReplicatedStorage.GameAssets.Animations:FindFirstChild(data.castAnimation)
	local track = if animator and asset and asset:IsA("Animation") then loadOneShotAnimation(animator, asset) else nil

	local spacing = flurrySeconds / hits
	for index = 0, hits - 1 do
		GameClock.Delay(start + index * spacing, function()
			local liveRoot = character:FindFirstChild("HumanoidRootPart")
			if not liveRoot or not liveRoot:IsA("BasePart") then
				return
			end
			if track and index % 2 == 0 then
				track:Play(0.05)
			end
			fists(liveRoot, length, angle)
		end)
	end

	GameClock.Delay(start + flurrySeconds, function()
		local liveRoot = character:FindFirstChild("HumanoidRootPart")
		if liveRoot and liveRoot:IsA("BasePart") then
			if track then
				track:Play(0.05)
			end
			finisherBlast(liveRoot, length)
		end
	end)

	GameClock.Delay(data.duration or 1.8, function()
		restoreWalkSpeed(character, nil, claim)
	end)

	-- The caster's walk speed picks up the gate when it opens and drops it
	-- when it closes (the server owns the attribute).
	if isCaster then
		local connection: RBXScriptConnection? = nil
		connection = character:GetAttributeChangedSignal(Attributes.InnerGatesOpen):Connect(function()
			restoreWalkSpeed(character)
			if character:GetAttribute(Attributes.InnerGatesOpen) ~= true and connection then
				connection:Disconnect()
			end
		end)
		-- Never outlives the gate (a cast that never opened one).
		GameClock.Delay(start + flurrySeconds + (data.gateSeconds or 8) + 2, function()
			if connection and connection.Connected then
				connection:Disconnect()
			end
		end)
	end
end
