--!strict
--[[
	Module: CardScene.lua
	Description:
	The world behind a hand of stage cards (CardStage): a depth of field
	focused on the card plane (the cards sharp, the dungeon soft) and the
	stage's dim plane behind the cards. Shared by the relic offer
	(Container) and the Memory Shrine's board (MemoryBoard), so the two
	never fight over the effects: there is ONE scene state per client.

	`token` is the owner of the current transition: an out overtaken by a
	new in (a hand dealt while the last one is closing) finds its token
	stale and leaves the effects alone, so nothing double-applies and
	nothing restores early. The dim plane keeps its own generation the
	same way (CardStage.setDim).

	Also the card sounds both hands play (the slide as a card starts
	moving, the flip as its face turns up).
]]

local Debris = game:GetService("Debris")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local CardStage = require(script.Parent.CardStage)

--[ Tuning ]--

local SCENE_DOF_NAME = "RelicOfferDepthOfField"
local SCENE_DOF_IN_FOCUS_RADIUS = 6
local SCENE_DOF_FAR_INTENSITY = 0.75
local SCENE_TWEEN = TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)

local CardScene = {}

-- 2026-11-06: the slide as a card starts moving, the flip the moment its
-- face turns up.
CardScene.CARD_SLIDE_SOUND_ID = "rbxassetid://9113578399"
CardScene.CARD_SLIDE_VOLUME = 1
CardScene.CARD_FLIP_SOUND_ID = "rbxassetid://3456145589"
CardScene.CARD_FLIP_VOLUME = 1.1

--[ Sounds ]--

-- A one-shot sound by asset id (nothing when `soundId` is nil).
function CardScene.playSoundId(soundId: string?, volume: number)
	if not soundId then
		return
	end
	local sound = Instance.new("Sound")
	sound.SoundId = soundId
	sound.Volume = volume
	sound.Parent = SoundService
	sound:Play()
	Debris:AddItem(sound, 3)
end

-- A one-shot of a GameAssets.Sounds template, at `volumeScale` of its
-- own volume.
function CardScene.playUiSound(soundName: string, volumeScale: number?)
	local sounds = ReplicatedStorage:FindFirstChild("GameAssets")
	sounds = sounds and sounds:FindFirstChild("Sounds")
	local template = sounds and sounds:FindFirstChild(soundName)
	if not template or not template:IsA("Sound") then
		return
	end
	local sound = template:Clone()
	sound.Volume *= volumeScale or 1
	sound.Parent = SoundService
	sound:Play()
	Debris:AddItem(sound, 5)
end

--[ Scene ]--

local scene = {
	token = 0,
	active = false,
	dof = nil :: DepthOfFieldEffect?,
}

local function sceneDof(): DepthOfFieldEffect
	local existing = scene.dof
	if existing and existing.Parent == Lighting then
		return existing
	end
	local found = Lighting:FindFirstChild(SCENE_DOF_NAME)
	local dof: DepthOfFieldEffect
	if found and found:IsA("DepthOfFieldEffect") then
		dof = found
	else
		dof = Instance.new("DepthOfFieldEffect")
		dof.Name = SCENE_DOF_NAME
		dof.NearIntensity = 0
		dof.FarIntensity = 0
		dof.Parent = Lighting
	end
	dof.FocusDistance = CardStage.STAGE_DISTANCE
	dof.InFocusRadius = SCENE_DOF_IN_FOCUS_RADIUS
	scene.dof = dof
	return dof
end

-- The world recedes: the blur and the dim ease in.
function CardScene.sceneIn()
	scene.token += 1
	scene.active = true
	local dof = sceneDof()
	dof.Enabled = true
	TweenService:Create(dof, SCENE_TWEEN, { FarIntensity = SCENE_DOF_FAR_INTENSITY }):Play()
	CardStage.setDim(true, SCENE_TWEEN)
end

-- The world comes back. `immediate` (unmount) restores on the spot
-- instead of easing out.
function CardScene.sceneOut(immediate: boolean?)
	if not scene.active then
		return
	end
	scene.token += 1
	local token = scene.token
	local dof = scene.dof

	local function restore()
		if scene.token ~= token then
			return
		end
		scene.active = false
		if dof then
			dof.FarIntensity = 0
			dof.Enabled = false
		end
	end

	if immediate then
		CardStage.destroyDim()
		restore()
		return
	end
	CardStage.setDim(false, SCENE_TWEEN)
	if dof then
		local out = TweenService:Create(dof, SCENE_TWEEN, { FarIntensity = 0 })
		out.Completed:Once(restore)
		out:Play()
	else
		restore()
	end
end

return CardScene
