--!strict
--[[
	Module: Controllers/CutsceneController/ImpactFrame.lua
	Description:
	An anime IMPACT FRAME on this screen (2026-11-13): the Susanoo
	Sharingan's burst and the Domain Expansion Eyes' open. CASTER ONLY --
	the cutscenes call it on the caster's own client.

	TWO quick flashes, inverted black and white:
	  1. the world blows out to white (a ColorCorrectionEffect: no colour,
	     hard contrast, pushed bright) and every character near the camera
	     is a solid BLACK silhouette (Highlight, fill only);
	  2. a beat later the inverse: the world crushed dark, the silhouettes
	     WHITE.
	Then everything is removed and the shot carries on. A sharp camera
	shake (CameraShakePresets.ImpactFrame) and an impact sound land on the
	first flash.

	  ImpactFrame.play()
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CameraShakeController = require(ReplicatedStorage.Controllers.CameraShakeController)
local CameraShakePresets = require(ReplicatedStorage.Submodules.Core.Shared.Enums.CameraShakePresets)

-- Each flash's length and the gap between them.
local FLASH_SECONDS = 0.06
local GAP_SECONDS = 0.04
-- The two grades (ColorCorrectionEffect): white-out, then crushed dark.
local WHITE_GRADE = { Saturation = -1, Contrast = 3, Brightness = 0.55 }
local DARK_GRADE = { Saturation = -1, Contrast = 3, Brightness = -0.6 }
-- Characters (any model with a Humanoid) within this many studs of the
-- camera become silhouettes; at most MAX_SILHOUETTES (Highlights are
-- limited), nearest first.
local SILHOUETTE_RANGE = 90
local MAX_SILHOUETTES = 24
-- The hit: a short bass impact on the first flash.
local SOUND_ID = "rbxassetid://9125402735"
local SOUND_VOLUME = 1.2

local ImpactFrame = {}

-- The models to silhouette: every Humanoid's model near the camera.
local function silhouetteModels(): { Model }
	local camera = workspace.CurrentCamera
	local origin = if camera then camera.CFrame.Position else Vector3.zero
	local found: { { model: Model, distance: number } } = {}
	local seen: { [Model]: boolean } = {}
	local function consider(model: Model)
		if seen[model] then
			return
		end
		seen[model] = true
		local distance = (model:GetPivot().Position - origin).Magnitude
		if distance <= SILHOUETTE_RANGE then
			table.insert(found, { model = model, distance = distance })
		end
	end
	for _, player in Players:GetPlayers() do
		if player.Character then
			consider(player.Character)
		end
	end
	local mobs = workspace:FindFirstChild("IgnoreInstances")
	mobs = mobs and mobs:FindFirstChild("Mobs")
	if mobs then
		for _, mob in mobs:GetChildren() do
			if mob:IsA("Model") then
				consider(mob)
			end
		end
	end
	table.sort(found, function(a, b)
		return a.distance < b.distance
	end)
	local models = {}
	for index = 1, math.min(#found, MAX_SILHOUETTES) do
		table.insert(models, found[index].model)
	end
	return models
end

local function setGrade(grade: ColorCorrectionEffect, values: { [string]: number })
	grade.Saturation = values.Saturation
	grade.Contrast = values.Contrast
	grade.Brightness = values.Brightness
end

local function setFill(highlights: { Highlight }, color: Color3)
	for _, highlight in highlights do
		highlight.FillColor = color
	end
end

function ImpactFrame.play()
	local grade = Instance.new("ColorCorrectionEffect")
	grade.Name = "ImpactFrame"
	setGrade(grade, WHITE_GRADE)
	grade.Parent = Lighting

	local highlights: { Highlight } = {}
	for _, model in silhouetteModels() do
		local highlight = Instance.new("Highlight")
		highlight.Name = "ImpactFrameSilhouette"
		highlight.FillTransparency = 0
		highlight.OutlineTransparency = 1
		highlight.DepthMode = Enum.HighlightDepthMode.Occluded
		highlight.Adornee = model
		highlight.Parent = model
		table.insert(highlights, highlight)
	end
	setFill(highlights, Color3.new(0, 0, 0))

	CameraShakeController:Shake(CameraShakePresets.ImpactFrame)
	local sound = Instance.new("Sound")
	sound.Name = "ImpactFrameSound"
	sound.SoundId = SOUND_ID
	sound.Volume = SOUND_VOLUME
	sound.Parent = workspace.CurrentCamera
	sound:Play()
	sound.Ended:Once(function()
		sound:Destroy()
	end)

	-- Real time on purpose: a frame is a frame, whatever the cutscene's
	-- own slow-down is doing.
	task.delay(FLASH_SECONDS, function()
		grade.Enabled = false
		for _, highlight in highlights do
			highlight.Enabled = false
		end
		task.delay(GAP_SECONDS, function()
			setGrade(grade, DARK_GRADE)
			grade.Enabled = true
			setFill(highlights, Color3.new(1, 1, 1))
			for _, highlight in highlights do
				highlight.Enabled = true
			end
			task.delay(FLASH_SECONDS, function()
				grade:Destroy()
				for _, highlight in highlights do
					highlight:Destroy()
				end
			end)
		end)
	end)
end

return ImpactFrame
