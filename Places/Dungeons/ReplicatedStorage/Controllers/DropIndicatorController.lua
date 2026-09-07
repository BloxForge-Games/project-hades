local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local Signal = require(ReplicatedStorage.Submodules.Core.Packages.Signal)
local DropData = require(ReplicatedStorage.Submodules.Core.Shared.Data.DropData)
local DropTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.DropTypes)

-- local INDICATOR_LIFETIME = 5
-- local TRANSPARENCY_TWEEN_INFO_PROPS = TweenInfo.new(3, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut, 0, false, 0)
-- local DEFAULT_TWEEN_INFO_PROPS = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut, 0, false, 0)
-- local MOVEMENT_TWEEN_INFO_PROPS = TweenInfo.new(0.75, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut, 0, false, 0)
-- local RANDOM_OFFSET_THRESHOLD = 125
-- local RANDOM_ROTATION_THRESHOLD = 25
-- local SHOW_DELAY = 0.5
-- local INDICATOR_ENABLED = true

local DropIndicatorController = Knit.CreateController({
	Name = "DropIndicatorController",
})

DropIndicatorController.OnDropIndicatorRequested = Signal.new()

function DropIndicatorController:KnitStart()
	self.OnDropIndicatorRequested:Connect(function(_: Model, dropType: string, _: number)
		DropData[dropType].sound:Play()

		if not Players.LocalPlayer.Character.HumanoidRootPart:FindFirstChild("DropParticlesAttachment") then
			ReplicatedStorage.GameAssets.Particles.DropParticlesAttachment.DropParticlesAttachment:Clone().Parent =
				Players.LocalPlayer.Character.HumanoidRootPart
		end

		Players.LocalPlayer.Character.HumanoidRootPart:FindFirstChild("DropParticlesAttachment").Particles.Color =
			ColorSequence.new(DropData[dropType].color)
		Players.LocalPlayer.Character.HumanoidRootPart:FindFirstChild("DropParticlesAttachment").Particles:Emit(10)

		if dropType == DropTypes.Mana then
			return
		end

		if dropType ~= DropTypes.Coins then
			return
		end

		-- local dropIndicator = game.ReplicatedStorage.GameAssets.Particles.DropIndicator:Clone()
		-- -- Removed visibility, since feel like it collides with the damage numbers on screen, too many numbers!
		-- dropIndicator.Indicator.Enabled = INDICATOR_ENABLED

		-- local indicator = dropIndicator.Indicator
		-- local textLabel = dropIndicator.Indicator.TextLabel

		-- -- Indicator Billboard GUI prop changes
		-- indicator.ExtentsOffsetWorldSpace = Vector3.new(0, 0, 0)
		-- -- TextLabel prop changes
		-- textLabel.Text = value .. "     "
		-- textLabel.TextTransparency = 0
		-- textLabel.UIStroke.Transparency = 0.25
		-- textLabel.UIStroke.Color = Color3.fromRGB(0, 0, 0)
		-- textLabel.TextColor3 = DropData[dropType].color
		-- textLabel.Image.Image = DropData[dropType].image

		-- -- Part prop changes
		-- dropIndicator.Position = character.HumanoidRootPart.Position
		-- dropIndicator.Parent = workspace.IgnoreInstances.MagicSpells

		-- TweenService:Create(indicator, DEFAULT_TWEEN_INFO_PROPS, {
		-- 	Size = UDim2.fromScale(5, 1.25),
		-- }):Play()

		-- TweenService:Create(indicator, MOVEMENT_TWEEN_INFO_PROPS, {
		-- 	ExtentsOffsetWorldSpace = Vector3.new(
		-- 		math.random(0, RANDOM_OFFSET_THRESHOLD),
		-- 		math.random(RANDOM_OFFSET_THRESHOLD / 2, RANDOM_OFFSET_THRESHOLD),
		-- 		math.random(0, RANDOM_OFFSET_THRESHOLD)
		-- 	),
		-- }):Play()

		-- TweenService:Create(
		-- 	indicator.TextLabel,
		-- 	MOVEMENT_TWEEN_INFO_PROPS,
		-- 	{ Rotation = math.random(-RANDOM_ROTATION_THRESHOLD, RANDOM_ROTATION_THRESHOLD) }
		-- ):Play()

		-- task.wait(SHOW_DELAY)

		-- TweenService:Create(indicator.TextLabel, TRANSPARENCY_TWEEN_INFO_PROPS, { TextTransparency = 1 }):Play()
		-- TweenService:Create(indicator.TextLabel.UIStroke, TRANSPARENCY_TWEEN_INFO_PROPS, { Transparency = 1 }):Play()
		-- TweenService:Create(indicator.TextLabel.Image, TRANSPARENCY_TWEEN_INFO_PROPS, { ImageTransparency = 1 }):Play()

		-- Debris:AddItem(indicator.Parent, INDICATOR_LIFETIME)
	end)
end

return DropIndicatorController
