--!strict
-- Chidori, client side (PROTOTYPE, 2026-11-07), built like Wind Bomb: the
-- caster's client lunges `dashStuds` at `dashDelay`, then at `hitDelay`
-- asks the server for the hitbox `range` ahead of where the lunge ended
-- (Arcane.HitboxRequested; VFXService validates it and deals the hit), so
-- the hit lands where the caster sees it. Crackling lightning on the hand
-- and a blue burst where it strikes.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local DodgeController = require(ReplicatedStorage.Submodules.Core.Source.Controllers.DodgeController)
local Arcane = require(ReplicatedStorage.Submodules.Core.Source.Network.Arcane)
local ArcaneData = require(ReplicatedStorage.Submodules.Core.Shared.Data.ArcaneData)
local ArcaneNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ArcaneNames)
local GameClock = require(ReplicatedStorage.Submodules.Core.Shared.GameClock)
local loadOneShotAnimation = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Character.loadOneShotAnimation)

local SPELL = ArcaneNames.Chidori
local SPARK_BLUE = Color3.fromRGB(140, 200, 255)
local SPARK_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"

local function effectsFolder(): Instance
	local ignore = workspace:FindFirstChild("IgnoreInstances")
	return (ignore and ignore:FindFirstChild("ArcaneSpells")) or ignore or workspace
end

local function burst(at: Vector3)
	local ball = Instance.new("Part")
	ball.Shape = Enum.PartType.Ball
	ball.Anchored = true
	ball.CanCollide = false
	ball.CanQuery = false
	ball.CanTouch = false
	ball.Material = Enum.Material.Neon
	ball.Color = SPARK_BLUE
	ball.Transparency = 0.1
	ball.Size = Vector3.one
	ball.CFrame = CFrame.new(at)
	ball.Parent = effectsFolder()
	TweenService:Create(
		ball,
		TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.one * 7, Transparency = 1 }
	):Play()
	GameClock.Debris(ball, 0.35)
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
	local sound = ReplicatedStorage.GameAssets.Sounds:FindFirstChild(data.castSound)
	if root and sound and sound:IsA("Sound") then
		local copy = sound:Clone()
		copy.Parent = root
		copy:Play()
		GameClock.Debris(copy, 4)
	end

	-- Lightning crackling in the hand for the whole lunge.
	local hand = character:FindFirstChild("Right Arm") or character:FindFirstChild("RightHand")
	if hand and hand:IsA("BasePart") then
		local sparks = Instance.new("ParticleEmitter")
		sparks.Texture = SPARK_TEXTURE
		sparks.Color = ColorSequence.new(SPARK_BLUE)
		sparks.LightEmission = 1
		sparks.Size = NumberSequence.new(0.8, 0)
		sparks.Lifetime = NumberRange.new(0.1, 0.25)
		sparks.Speed = NumberRange.new(6, 14)
		sparks.SpreadAngle = Vector2.new(180, 180)
		sparks.Rate = 220
		sparks.Parent = hand
		GameClock.Delay(data.hitDelay or 0.35, function()
			sparks.Enabled = false
		end)
		GameClock.Debris(sparks, 1)
	end

	if player == Players.LocalPlayer then
		GameClock.Delay(data.dashDelay or 0.1, function()
			DodgeController:SetDodgeCFrame(data.dashStuds or 18.75, data.dashSeconds or 0.35, true)
		end)
	end
	GameClock.Delay(data.hitDelay or 0.5, function()
		local liveRoot = character:FindFirstChild("HumanoidRootPart")
		if not liveRoot or not liveRoot:IsA("BasePart") then
			return
		end
		local hitboxCFrame = liveRoot.CFrame + liveRoot.CFrame.LookVector * (data.range or 5)
		if player == Players.LocalPlayer then
			Arcane.HitboxRequested.Fire({ ArcaneName = SPELL, CFrame = hitboxCFrame })
		end
		burst(hitboxCFrame.Position)
	end)
end
