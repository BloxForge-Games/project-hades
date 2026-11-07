--!strict
-- Hurricane Leaf Kick, client side (PROTOTYPE, 2026-11-07): a spinning
-- leap forward (`dashStuds` over `dashSeconds`, the caster's own client
-- only), then a green shockwave ring and a burst of leaves where the kick
-- lands. The hit and the stun are the server's
-- (VFXService/ServerCasts/HurricaneLeafKick).
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local DodgeController = require(ReplicatedStorage.Submodules.Core.Source.Controllers.DodgeController)
local ArcaneData = require(ReplicatedStorage.Submodules.Core.Shared.Data.ArcaneData)
local ArcaneNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ArcaneNames)
local GameClock = require(ReplicatedStorage.Submodules.Core.Shared.GameClock)
local claimWalkSpeed = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Movement.claimWalkSpeed)
local restoreWalkSpeed = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Movement.restoreWalkSpeed)
local loadOneShotAnimation = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Character.loadOneShotAnimation)

local SPELL = ArcaneNames["Hurricane Leaf Kick"]
local LEAF_GREEN = Color3.fromRGB(120, 220, 90)
local RING_SECONDS = 0.35
local CAST_WALK_SPEED = 0
local LEAF_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"

local function shockwave(at: Vector3, radius: number)
	local folder = workspace:FindFirstChild("IgnoreInstances") or workspace
	local ring = Instance.new("Part")
	ring.Shape = Enum.PartType.Cylinder
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.Material = Enum.Material.Neon
	ring.Color = LEAF_GREEN
	ring.Transparency = 0.25
	ring.Size = Vector3.new(0.4, 2, 2)
	-- A cylinder's axis is X: lay it flat.
	ring.CFrame = CFrame.new(at) * CFrame.Angles(0, 0, math.rad(90))
	ring.Parent = folder
	TweenService:Create(
		ring,
		TweenInfo.new(RING_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.new(0.4, radius * 2, radius * 2), Transparency = 1 }
	):Play()
	GameClock.Debris(ring, RING_SECONDS + 0.1)

	local holder = Instance.new("Part")
	holder.Anchored = true
	holder.CanCollide = false
	holder.CanQuery = false
	holder.CanTouch = false
	holder.Transparency = 1
	holder.Size = Vector3.one
	holder.CFrame = CFrame.new(at)
	local leaves = Instance.new("ParticleEmitter")
	leaves.Texture = LEAF_TEXTURE
	leaves.Color = ColorSequence.new(LEAF_GREEN)
	leaves.Size = NumberSequence.new(0.6, 0.2)
	leaves.Lifetime = NumberRange.new(0.5, 0.9)
	leaves.Speed = NumberRange.new(radius, radius * 2)
	leaves.SpreadAngle = Vector2.new(180, 25)
	leaves.Rotation = NumberRange.new(0, 360)
	leaves.RotSpeed = NumberRange.new(-360, 360)
	leaves.EmissionDirection = Enum.NormalId.Top
	leaves.Rate = 0
	leaves.Parent = holder
	holder.Parent = folder
	leaves:Emit(40)
	GameClock.Debris(holder, 1.5)
end

return function(player: Player, preload: boolean?)
	local character = player.Character
	if preload or not character then
		return
	end
	local data = ArcaneData[SPELL]
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	local asset = ReplicatedStorage.GameAssets.Animations:FindFirstChild(data.castAnimation)
	if animator and asset and asset:IsA("Animation") then
		loadOneShotAnimation(animator, asset):Play(0.05)
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	local sound = ReplicatedStorage.GameAssets.Sounds:FindFirstChild("DivergentFistCast")
	if root and sound and sound:IsA("Sound") then
		local copy = sound:Clone()
		copy.Parent = root
		copy:Play()
		GameClock.Debris(copy, 4)
	end

	local claim = claimWalkSpeed(character, CAST_WALK_SPEED)
	if player == Players.LocalPlayer then
		DodgeController:SetDodgeCFrame(data.dashStuds or 12, data.dashSeconds or 0.25, true)
	end
	-- The ring lands where the dash ends (the server's hit waits a little
	-- longer, for the dash to replicate).
	GameClock.Delay(data.dashSeconds or 0.25, function()
		local liveRoot = character:FindFirstChild("HumanoidRootPart")
		if liveRoot and liveRoot:IsA("BasePart") then
			local radius = (data.hitboxSize and data.hitboxSize.X or 24) / 2
			shockwave(liveRoot.Position - Vector3.new(0, 2.5, 0), radius)
		end
	end)
	GameClock.Delay(data.duration or 0.6, function()
		restoreWalkSpeed(character, nil, claim)
	end)
end
