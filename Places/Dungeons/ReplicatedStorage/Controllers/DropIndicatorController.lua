--!strict
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

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

-- THE PITCH LADDER (2026-11-19). Each currency pickup that follows the
-- last within LADDER_RESET_SECONDS plays one step higher up a major scale
-- (semitones above the sound's own pitch), holding at the top: a stream of
-- coins is a rising run of ticks, and it starts over once the stream stops.
-- Orbs keep their one flat cue.
local LADDER_SEMITONES = { 0, 2, 4, 5, 7, 9, 11, 12 }
local LADDER_RESET_SECONDS = 1
local LADDER_TYPES: { [string]: boolean } = {
	[DropTypes.Coins] = true,
	[DropTypes.Gems] = true,
	[DropTypes.ArcaneCrystals] = true,
}
-- Slack on a cloned sound's cleanup, and its lifetime while the asset has
-- not loaded yet (TimeLength reads 0 until it has).
local SOUND_CLEANUP_MARGIN = 0.5
local SOUND_UNKNOWN_LENGTH = 3

local DropIndicatorController = {
	Name = "DropIndicatorController",

	_ladderStep = 0,
	_ladderAt = -math.huge,
}

-- The pickup sound, one step up the ladder. A CLONE each time: the shared
-- GameAssets sound cannot overlap itself, so a stream of coins used to cut
-- its own ticks short.
function DropIndicatorController._playLadder(self: typeof(DropIndicatorController), template: Sound)
	local now = os.clock()
	if now - self._ladderAt > LADDER_RESET_SECONDS then
		self._ladderStep = 0
	end
	self._ladderAt = now
	self._ladderStep = math.min(self._ladderStep + 1, #LADDER_SEMITONES)

	local sound = template:Clone()
	sound.PlaybackSpeed = template.PlaybackSpeed * 2 ^ (LADDER_SEMITONES[self._ladderStep] / 12)
	sound.Parent = SoundService
	sound:Play()
	local length = if sound.TimeLength > 0 then sound.TimeLength else SOUND_UNKNOWN_LENGTH
	Debris:AddItem(sound, length + SOUND_CLEANUP_MARGIN)
end

DropIndicatorController.OnDropIndicatorRequested = Signal.new()

function DropIndicatorController.Start(self: typeof(DropIndicatorController))
	self.OnDropIndicatorRequested:Connect(function(_: Model, dropType: string, _: number)
		if LADDER_TYPES[dropType] then
			self:_playLadder(DropData[dropType].sound)
		else
			DropData[dropType].sound:Play()
		end

		-- The cue can arrive after the character is gone (a coin still in
		-- flight when the player died): the sound plays, the burst does not.
		local character = Players.LocalPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not root then
			return
		end
		local attachment = root:FindFirstChild("DropParticlesAttachment")
		if not attachment then
			attachment = ReplicatedStorage.GameAssets.Particles.DropParticlesAttachment.DropParticlesAttachment:Clone()
			attachment.Parent = root
		end
		attachment.Particles.Color = ColorSequence.new(DropData[dropType].color)
		attachment.Particles:Emit(10)

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
		-- dropIndicator.Parent = workspace.IgnoreInstances.ArcaneSpells

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
