--!strict
-- Eight Inner Gates, client side (2026-11-08): the gates flare on the
-- press and keep charging around the rooted caster (a red-green column,
-- rising sparks, a shrinking floor ring) for `chargeSeconds`, then the
-- caster's own client dashes `dashStuds` forward in a flying kick: a
-- burning crescent swept up at the launch, a fire trail along the path
-- and a fiery shockwave where it lands, then `secondKickDelay` later a
-- second crescent and a bigger shockwave (2026-11-09; a lunge into a
-- punch flurry before). Rooted through the charge; from the dash to the
-- end of the cast the caster walks at `kickWalkSpeed`. There is no kick animation yet, the fist one plays. The open
-- gate's look is the Enflamed aura the server grants for `gateSeconds`
-- (AuraService). The hit, the invulnerability and the gate's speed are
-- the server's (VFXService/ServerCasts/EightInnerGates); the caster's
-- client roots itself for `duration` and re-applies its walk speed when
-- the gate opens and closes.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local ArcaneData = require(ReplicatedStorage.Submodules.Core.Shared.Data.ArcaneData)
local ArcaneNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ArcaneNames)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local GameClock = require(ReplicatedStorage.Submodules.Core.Shared.GameClock)
local DodgeController = require(ReplicatedStorage.Submodules.Core.Source.Controllers.DodgeController)
local claimWalkSpeed = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Movement.claimWalkSpeed)
local restoreWalkSpeed = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Movement.restoreWalkSpeed)
local loadOneShotAnimation = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Character.loadOneShotAnimation)

local SPELL = ArcaneNames["Eight Inner Gates"]
local GATE_RED = Color3.fromRGB(255, 70, 50)
local GATE_GREEN = Color3.fromRGB(90, 255, 160)
local FIRE = Color3.fromRGB(255, 150, 60)
local SPARK_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"

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

-- The charge: a red-green column around the caster that brightens, sparks
-- rising off it, and a floor ring closing in, all over `seconds`.
local function charge(root: BasePart, seconds: number)
	local folder = effectsFolder()
	local column = Instance.new("Part")
	bare(column)
	column.Shape = Enum.PartType.Cylinder
	column.Material = Enum.Material.Neon
	column.Color = GATE_GREEN
	column.Transparency = 0.9
	column.Size = Vector3.new(7, 6, 6)
	column.CFrame = CFrame.new(root.Position) * CFrame.Angles(0, 0, math.rad(90))
	column.Parent = folder
	TweenService:Create(
		column,
		TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ Size = Vector3.new(9, 3.5, 3.5), Transparency = 0.45, Color = GATE_RED }
	):Play()
	GameClock.Debris(column, seconds + 0.05)

	local ring = Instance.new("Part")
	bare(ring)
	ring.Shape = Enum.PartType.Cylinder
	ring.Material = Enum.Material.Neon
	ring.Color = GATE_RED
	ring.Transparency = 0.4
	ring.Size = Vector3.new(0.2, 16, 16)
	ring.CFrame = CFrame.new(root.Position - Vector3.new(0, 2.8, 0)) * CFrame.Angles(0, 0, math.rad(90))
	ring.Parent = folder
	TweenService:Create(
		ring,
		TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ Size = Vector3.new(0.2, 3, 3), Transparency = 0, Color = FIRE }
	):Play()
	GameClock.Debris(ring, seconds + 0.05)

	local sparks = Instance.new("ParticleEmitter")
	sparks.Texture = SPARK_TEXTURE
	sparks.Color = ColorSequence.new(GATE_GREEN, GATE_RED)
	sparks.LightEmission = 1
	sparks.Size = NumberSequence.new(0.5, 0)
	sparks.Lifetime = NumberRange.new(0.4, 0.7)
	sparks.Speed = NumberRange.new(6, 12)
	sparks.SpreadAngle = Vector2.new(25, 25)
	sparks.EmissionDirection = Enum.NormalId.Top
	sparks.Rate = 60
	sparks.Parent = root
	GameClock.Delay(seconds, function()
		sparks.Enabled = false
	end)
	GameClock.Debris(sparks, seconds + 1)
end

-- The kick: a burning crescent swept up from the floor to overhead in
-- front of the caster, leaving a fire trail.
local function kickArc(root: BasePart)
	local folder = effectsFolder()
	local look = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
	look = if look.Magnitude > 1e-3 then look.Unit else Vector3.zAxis
	-- Pivot at the hip; the foot swings on a 4-stud arm in the caster's
	-- vertical plane, from low-behind-front to high.
	local pivot = CFrame.lookAt(root.Position, root.Position + look)
	local foot = Instance.new("Part")
	bare(foot)
	foot.Shape = Enum.PartType.Ball
	foot.Material = Enum.Material.Neon
	foot.Color = FIRE
	foot.Size = Vector3.one * 1.8
	local a0 = Instance.new("Attachment")
	a0.Position = Vector3.new(0, 0, 0.9)
	a0.Parent = foot
	local a1 = Instance.new("Attachment")
	a1.Position = Vector3.new(0, 0, -0.9)
	a1.Parent = foot
	local trail = Instance.new("Trail")
	trail.Attachment0 = a0
	trail.Attachment1 = a1
	trail.Color = ColorSequence.new(FIRE, GATE_RED)
	trail.LightEmission = 1
	trail.Transparency = NumberSequence.new(0, 1)
	trail.WidthScale = NumberSequence.new(1, 0.2)
	trail.Lifetime = 0.25
	trail.Parent = foot
	local function at(angle: number): CFrame
		-- angle 0 = straight down, 180 = straight up, swinging forward.
		return pivot * CFrame.Angles(math.rad(angle), 0, 0) * CFrame.new(0, -4, 0)
	end
	foot.CFrame = at(-20)
	foot.Parent = folder
	local swing = Instance.new("NumberValue")
	swing.Value = -20
	swing.Changed:Connect(function(value: number)
		foot.CFrame = at(value)
	end)
	TweenService:Create(swing, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Value = 160 })
		:Play()
	TweenService:Create(foot, TweenInfo.new(0.3, Enum.EasingStyle.Linear), { Transparency = 1 }):Play()
	GameClock.Debris(foot, 0.5)
	GameClock.Debris(swing, 0.5)
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
	local chargeSeconds = data.chargeSeconds or 1
	local dashSeconds = data.dashSeconds or 0.25
	local isCaster = player == Players.LocalPlayer

	playSound(data.castSound, root)
	flare(root)
	charge(root, chargeSeconds)

	-- Rooted through the charge, then the cast walk speed until the end.
	local claim = claimWalkSpeed(character, 0)
	local kickClaim: number? = nil
	GameClock.Delay(chargeSeconds, function()
		kickClaim = claimWalkSpeed(character, data.kickWalkSpeed or 2)
		restoreWalkSpeed(character, nil, claim)
	end)

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	local asset = ReplicatedStorage.GameAssets.Animations:FindFirstChild(data.castAnimation)
	local track = if animator and asset and asset:IsA("Animation") then loadOneShotAnimation(animator, asset) else nil

	GameClock.Delay(chargeSeconds, function()
		local liveRoot = character:FindFirstChild("HumanoidRootPart")
		if not liveRoot or not liveRoot:IsA("BasePart") then
			return
		end
		if isCaster then
			DodgeController:SetDodgeCFrame(data.dashStuds or 18, dashSeconds, true)
		end
		if track then
			track:Play(0.05)
		end
		kickArc(liveRoot)
		-- A fire trail behind the flying kick.
		local a0 = Instance.new("Attachment")
		a0.Position = Vector3.new(0, 1.5, 0)
		a0.Parent = liveRoot
		local a1 = Instance.new("Attachment")
		a1.Position = Vector3.new(0, -2, 0)
		a1.Parent = liveRoot
		local trail = Instance.new("Trail")
		trail.Attachment0 = a0
		trail.Attachment1 = a1
		trail.Color = ColorSequence.new(FIRE, GATE_RED)
		trail.LightEmission = 1
		trail.Transparency = NumberSequence.new(0.1, 1)
		trail.Lifetime = 0.3
		trail.Parent = liveRoot
		GameClock.Delay(dashSeconds, function()
			trail.Enabled = false
			if liveRoot.Parent then
				finisherBlast(liveRoot, 8)
			end
		end)
		-- The second kick.
		GameClock.Delay(dashSeconds + 0.1 + (data.secondKickDelay or 0.25), function()
			if not liveRoot.Parent then
				return
			end
			if track then
				track:Play(0.05)
			end
			kickArc(liveRoot)
			finisherBlast(liveRoot, (data.secondKickRadius or 9) * 1.6)
		end)
		GameClock.Debris(trail, dashSeconds + 0.4)
		GameClock.Debris(a0, dashSeconds + 0.4)
		GameClock.Debris(a1, dashSeconds + 0.4)
	end)

	GameClock.Delay(data.duration or 1.8, function()
		restoreWalkSpeed(character, nil, claim)
		if kickClaim then
			restoreWalkSpeed(character, nil, kickClaim)
		end
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
		GameClock.Delay((data.duration or 1.8) + (data.gateSeconds or 10) + 2, function()
			if connection and connection.Connected then
				connection:Disconnect()
			end
		end)
	end
end
