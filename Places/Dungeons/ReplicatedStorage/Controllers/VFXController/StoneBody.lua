--!strict
-- Stone Body, client side (PROTOTYPE, 2026-11-07): the caster greys into
-- stone for `stoneSeconds` (a stone-coloured highlight and falling grit),
-- then shatters in a burst of rubble. The damage reduction, the taunt and
-- the shatter's damage are the server's (VFXService/ServerCasts/StoneBody).
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local ArcaneData = require(ReplicatedStorage.Submodules.Core.Shared.Data.ArcaneData)
local ArcaneNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ArcaneNames)
local GameClock = require(ReplicatedStorage.Submodules.Core.Shared.GameClock)

local SPELL = ArcaneNames["Stone Body"]
local STONE = Color3.fromRGB(128, 118, 104)
local RUBBLE_TEXTURE = "rbxasset://textures/particles/smoke_main.dds"

local function effectsFolder(): Instance
	local ignore = workspace:FindFirstChild("IgnoreInstances")
	return (ignore and ignore:FindFirstChild("ArcaneSpells")) or ignore or workspace
end

local function shatter(at: Vector3, radius: number)
	local ring = Instance.new("Part")
	ring.Shape = Enum.PartType.Cylinder
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.Material = Enum.Material.Slate
	ring.Color = STONE
	ring.Size = Vector3.new(0.6, 2, 2)
	ring.CFrame = CFrame.new(at - Vector3.new(0, 2.6, 0)) * CFrame.Angles(0, 0, math.rad(90))
	ring.Parent = effectsFolder()
	TweenService:Create(
		ring,
		TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.new(0.6, radius * 2, radius * 2), Transparency = 1 }
	):Play()
	GameClock.Debris(ring, 0.45)

	local holder = Instance.new("Part")
	holder.Anchored = true
	holder.CanCollide = false
	holder.CanQuery = false
	holder.CanTouch = false
	holder.Transparency = 1
	holder.Size = Vector3.one
	holder.CFrame = CFrame.new(at)
	local rubble = Instance.new("ParticleEmitter")
	rubble.Texture = RUBBLE_TEXTURE
	rubble.Color = ColorSequence.new(STONE)
	rubble.Size = NumberSequence.new(1.6, 0.4)
	rubble.Lifetime = NumberRange.new(0.4, 0.8)
	rubble.Speed = NumberRange.new(radius, radius * 2)
	rubble.SpreadAngle = Vector2.new(180, 40)
	rubble.Acceleration = Vector3.new(0, -60, 0)
	rubble.Rate = 0
	rubble.Parent = holder
	holder.Parent = effectsFolder()
	rubble:Emit(45)
	GameClock.Debris(holder, 1.5)
end

return function(player: Player, preload: boolean?)
	local character = player.Character
	if preload or not character then
		return
	end
	local data = ArcaneData[SPELL]
	local seconds = data.stoneSeconds or 4
	local root = character:FindFirstChild("HumanoidRootPart")
	local sound = ReplicatedStorage.GameAssets.Sounds:FindFirstChild(data.castSound)
	if root and sound and sound:IsA("Sound") then
		local copy = sound:Clone()
		copy.Parent = root
		copy:Play()
		GameClock.Debris(copy, 4)
	end

	local skin = Instance.new("Highlight")
	skin.Name = "StoneBody"
	skin.FillColor = STONE
	skin.FillTransparency = 1
	skin.OutlineColor = Color3.fromRGB(60, 54, 46)
	skin.OutlineTransparency = 1
	skin.DepthMode = Enum.HighlightDepthMode.Occluded
	skin.Parent = character
	TweenService:Create(skin, TweenInfo.new(0.2), { FillTransparency = 0.25, OutlineTransparency = 0.2 }):Play()

	if root and root:IsA("BasePart") then
		local grit = Instance.new("ParticleEmitter")
		grit.Texture = RUBBLE_TEXTURE
		grit.Color = ColorSequence.new(STONE)
		grit.Size = NumberSequence.new(0.5, 0.1)
		grit.Lifetime = NumberRange.new(0.5, 0.9)
		grit.Speed = NumberRange.new(1, 3)
		grit.Acceleration = Vector3.new(0, -20, 0)
		grit.Rate = 18
		grit.Parent = root
		GameClock.Debris(grit, seconds)
	end

	GameClock.Delay(seconds, function()
		if skin.Parent then
			skin:Destroy()
		end
		local liveRoot = character:FindFirstChild("HumanoidRootPart")
		if liveRoot and liveRoot:IsA("BasePart") then
			shatter(liveRoot.Position, (data.hitboxSize and data.hitboxSize.X or 20) / 2)
		end
	end)
end
