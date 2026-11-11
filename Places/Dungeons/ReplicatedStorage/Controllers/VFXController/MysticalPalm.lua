--!strict
-- Mystical Palm, client side (2026-11-10; Healing Tree before): the caster
-- channels healing chakra for `channelSeconds`, rooted. PLACEHOLDER
-- visuals until the real ones ship: both hands glow green (a neon ball, a
-- light and wisps on each), and a green ring on the floor at the real heal
-- radius follows the caster and pulses on every heal tick
-- (VFXService/ServerCasts/MysticalPalm heals on the same rhythm). The cast
-- animation plays once and holds its last pose through the channel.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local ArcaneData = require(ReplicatedStorage.Submodules.Core.Shared.Data.ArcaneData)
local ArcaneNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ArcaneNames)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local GameClock = require(ReplicatedStorage.Submodules.Core.Shared.GameClock)
local loadOneShotAnimation = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Character.loadOneShotAnimation)
local claimWalkSpeed = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Movement.claimWalkSpeed)
local restoreWalkSpeed = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Movement.restoreWalkSpeed)

local SPELL = ArcaneNames["Mystical Palm"]
local CHAKRA = Color3.fromRGB(110, 255, 150)
local CHAKRA_DEEP = Color3.fromRGB(40, 200, 110)
local SPARK_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"
local WISP_TEXTURE = "rbxasset://textures/particles/smoke_main.dds"
local HAND_SIZE = 0.9
local RING_TRANSPARENCY = 0.4
local RING_PULSE_TRANSPARENCY = 0.05
local RING_PULSE_SECONDS = 0.3
local FLOOR_DROP = 2.9
local FADE = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
-- The cast animation freezes this close to its end, holding the pose.
local HOLD_BEFORE_END = 0.05

local function effectsFolder(): Instance
	local ignore = workspace:FindFirstChild("IgnoreInstances")
	return (ignore and ignore:FindFirstChild("ArcaneSpells")) or ignore or workspace
end

local function part(name: string, shape: Enum.PartType, color: Color3, transparency: number): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Shape = shape
	p.Material = Enum.Material.Neon
	p.Color = color
	p.Transparency = transparency
	return p
end

-- A hand: R15's RightHand / LeftHand, R6's Right Arm / Left Arm.
local function handOf(character: Model, side: string): BasePart?
	local hand = character:FindFirstChild(side .. "Hand") or character:FindFirstChild(side .. " Arm")
	return if hand and hand:IsA("BasePart") then hand else nil
end

-- The cast animation, frozen near its end until `release` is called.
local function holdCastPose(character: Model, animationName: string?): () -> ()
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	local asset = animationName and ReplicatedStorage.GameAssets.Animations:FindFirstChild(animationName)
	if not animator or not asset or not asset:IsA("Animation") then
		return function() end
	end
	local track = loadOneShotAnimation(animator, asset)
	track:Play(0.1)
	local released = false
	task.spawn(function()
		local waited = 0
		while track.Length <= 0 and waited < 1 do
			waited += GameClock.Wait(0.05)
		end
		GameClock.Wait(math.max(track.Length - HOLD_BEFORE_END, 0))
		if not released and track.IsPlaying then
			track:AdjustSpeed(0)
		end
	end)
	return function()
		released = true
		if track.IsPlaying then
			track:Stop(0.25)
		end
	end
end

return function(player: Player, preload: boolean?, _cframe: CFrame?)
	if preload then
		return
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not character or not root or not root:IsA("BasePart") then
		return
	end
	local data = ArcaneData[SPELL]
	local seconds = data.channelSeconds or 5
	local radius = data.healRadius or 14
	local tick = data.tickSeconds or 0.5

	-- Rooted through the whole cast (only the caster's own client moves
	-- its body). Claimed at 0, so only this cast's restore lifts it.
	local walkSpeedClaim: number? = nil
	if player == Players.LocalPlayer then
		walkSpeedClaim = claimWalkSpeed(character, 0)
	end
	local releasePose = holdCastPose(character, data.castAnimation)

	local sound = ReplicatedStorage.GameAssets.Sounds:FindFirstChild(data.castSound)
	if sound and sound:IsA("Sound") then
		local copy = sound:Clone()
		copy.Parent = root
		copy:Play()
		GameClock.Debris(copy, 4)
	end

	local folder = Instance.new("Folder")
	folder.Name = "MysticalPalm"
	local parts: { Part } = {}

	-- The hands: a glowing ball on each, with a light and rising wisps.
	local hands: { { glow: Part, hand: BasePart } } = {}
	for _, side in { "Right", "Left" } do
		local hand = handOf(character, side)
		if not hand then
			continue
		end
		local glow = part("Chakra" .. side, Enum.PartType.Ball, CHAKRA, 1)
		glow.Size = Vector3.one * HAND_SIZE
		glow.CFrame = hand.CFrame
		glow.Parent = folder
		table.insert(parts, glow)
		local light = Instance.new("PointLight")
		light.Color = CHAKRA
		light.Brightness = 2
		light.Range = 8
		light.Parent = glow
		local wisps = Instance.new("ParticleEmitter")
		wisps.Texture = WISP_TEXTURE
		wisps.Color = ColorSequence.new(CHAKRA, CHAKRA_DEEP)
		wisps.LightEmission = 1
		wisps.Size = NumberSequence.new(0.6, 0)
		wisps.Transparency = NumberSequence.new(0.3, 1)
		wisps.Lifetime = NumberRange.new(0.4, 0.8)
		wisps.Speed = NumberRange.new(1, 2)
		wisps.SpreadAngle = Vector2.new(40, 40)
		wisps.Acceleration = Vector3.new(0, 3, 0)
		wisps.Rate = 25
		wisps.Parent = glow
		TweenService:Create(glow, FADE, { Transparency = 0.15 }):Play()
		table.insert(hands, { glow = glow, hand = hand })
	end

	-- The heal circle on the floor, at the real radius, under the caster.
	local function floorFrame(): CFrame
		return CFrame.new(root.Position - Vector3.new(0, FLOOR_DROP, 0)) * CFrame.Angles(0, 0, math.rad(90))
	end
	local ring = part("Ring", Enum.PartType.Cylinder, CHAKRA, 1)
	ring.Size = Vector3.new(0.12, radius * 2, radius * 2)
	ring.CFrame = floorFrame()
	ring.Parent = folder
	table.insert(parts, ring)
	local disc = part("Floor", Enum.PartType.Cylinder, CHAKRA_DEEP, 1)
	disc.Size = Vector3.new(0.08, radius * 2 - 0.4, radius * 2 - 0.4)
	disc.CFrame = floorFrame() * CFrame.new(-0.03, 0, 0)
	disc.Parent = folder
	table.insert(parts, disc)
	TweenService:Create(ring, FADE, { Transparency = RING_TRANSPARENCY }):Play()
	TweenService:Create(disc, FADE, { Transparency = 0.88 }):Play()

	-- Sparks rising across the circle.
	local sparks = Instance.new("ParticleEmitter")
	sparks.Texture = SPARK_TEXTURE
	sparks.Color = ColorSequence.new(CHAKRA)
	sparks.LightEmission = 1
	sparks.Size = NumberSequence.new(0.4, 0)
	sparks.Transparency = NumberSequence.new(0.1, 1)
	sparks.Lifetime = NumberRange.new(0.8, 1.3)
	sparks.Speed = NumberRange.new(3, 5)
	sparks.EmissionDirection = Enum.NormalId.Right
	sparks.SpreadAngle = Vector2.new(5, 5)
	sparks.Shape = Enum.ParticleEmitterShape.Disc
	sparks.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	sparks.Rate = 30
	sparks.Parent = disc

	folder.Parent = effectsFolder()

	-- Follow the caster (the hands and the circle) every frame.
	local follow = RunService.RenderStepped:Connect(function()
		if not root.Parent then
			return
		end
		for _, entry in hands do
			if entry.hand.Parent then
				entry.glow.CFrame = entry.hand.CFrame * CFrame.new(0, -entry.hand.Size.Y / 2, 0)
			end
		end
		ring.CFrame = floorFrame()
		disc.CFrame = floorFrame() * CFrame.new(-0.03, 0, 0)
	end)

	-- The ring brightens on every heal tick.
	local ticks = math.floor(seconds / tick + 0.5)
	for index = 1, ticks do
		GameClock.Delay(tick * index, function()
			if not ring.Parent then
				return
			end
			ring.Transparency = RING_PULSE_TRANSPARENCY
			TweenService:Create(ring, TweenInfo.new(RING_PULSE_SECONDS), { Transparency = RING_TRANSPARENCY }):Play()
		end)
	end

	-- The end: the channel's time is up, or the caster died / was downed.
	local ended = false
	local function finish()
		if ended then
			return
		end
		ended = true
		follow:Disconnect()
		sparks.Enabled = false
		for _, p in parts do
			for _, child in p:GetChildren() do
				if child:IsA("ParticleEmitter") or child:IsA("PointLight") then
					(child :: any).Enabled = false
				end
			end
			TweenService:Create(p, FADE, { Transparency = 1 }):Play()
		end
		GameClock.Debris(folder, 1.5)
		releasePose()
		if walkSpeedClaim then
			restoreWalkSpeed(character, 0, walkSpeedClaim)
		end
	end
	GameClock.Delay(math.max(seconds, data.duration or 0), finish)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.Died:Once(finish)
	end
	character:GetAttributeChangedSignal(Attributes.Downed):Once(function()
		if character:GetAttribute(Attributes.Downed) == true then
			finish()
		end
	end)
end
