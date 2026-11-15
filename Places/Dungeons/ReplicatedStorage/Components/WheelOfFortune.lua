--!strict
--[[
	Module: Components/WheelOfFortune.lua
	Description:
	The Wheel of Fortune's wheel on this client (2026-11-13). Draws the face
	-- the painted wheel (WheelOfFortuneData.ImageId) and every slice's
	label, on a SurfaceGui on the model's "WheelFace" part -- and plays
	each spin the server publishes (WheelOfFortuneService): on a new SpinId
	it turns from where it rests to SpinRotation over SpinSeconds, measured
	from SpinStartedAt on the server clock, so every screen lands together.
	Every slice boundary that passes the pointer ticks.
	The wheel stays as placed in the prefab, facing straight out into the
	room (2026-11-13: turning it toward each camera tilted it, and pulled
	the clown's rig apart).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Component = require(ReplicatedStorage.Submodules.Core.Packages.Component)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local WheelOfFortuneData = require(ReplicatedStorage.Submodules.Core.Shared.Data.WheelOfFortuneData)
local uiSound = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.uiSound)

local FACE_NAME = "WheelFace"
local PIXELS_PER_STUD = 60
-- Where a slice's label sits, as a share of the wheel's radius.
local LABEL_RADIUS = 0.3
local LABEL_FONT =
	Font.new("rbxasset://fonts/families/Montserrat.json", Enum.FontWeight.ExtraBold, Enum.FontStyle.Normal)

local WheelOfFortune = Component.new({
	Tag = TagList.WheelOfFortune,
})

function WheelOfFortune:_build()
	local face = self.Instance:WaitForChild(FACE_NAME, 10)
	if not face or not face:IsA("BasePart") then
		warn("[WheelOfFortune] " .. self.Instance:GetFullName() .. " has no " .. FACE_NAME)
		return
	end
	local gui = Instance.new("SurfaceGui")
	gui.Name = "WheelGui"
	gui.Face = Enum.NormalId.Front
	gui.LightInfluence = 0.4
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = PIXELS_PER_STUD
	gui.Adornee = face
	gui.Parent = face

	local wheel = Instance.new("ImageLabel")
	wheel.Name = "Wheel"
	wheel.AnchorPoint = Vector2.new(0.5, 0.5)
	wheel.Position = UDim2.fromScale(0.5, 0.5)
	wheel.Size = UDim2.fromScale(1, 1)
	wheel.SizeConstraint = Enum.SizeConstraint.RelativeYY
	wheel.BackgroundTransparency = 1
	wheel.Image = WheelOfFortuneData.ImageId
	wheel.Parent = gui

	local count = #WheelOfFortuneData.Slices
	local step = 360 / count
	for index, slice in WheelOfFortuneData.Slices do
		local angle = (index - 0.5) * step
		local radians = math.rad(angle)
		local label = Instance.new("TextLabel")
		label.Name = slice.id
		label.AnchorPoint = Vector2.new(0.5, 0.5)
		label.Position = UDim2.fromScale(0.5 + LABEL_RADIUS * math.sin(radians), 0.5 - LABEL_RADIUS * math.cos(radians))
		label.Size = UDim2.fromScale(0.3, 0.09)
		-- Along the radius, reading outward on the right half and inward on
		-- the left, so no label is ever upside down.
		label.Rotation = if angle > 180 then angle + 90 else angle - 90
		label.BackgroundTransparency = 1
		label.FontFace = LABEL_FONT
		label.Text = slice.label
		label.TextScaled = true
		label.TextColor3 = Color3.fromRGB(255, 255, 255)
		label.TextStrokeTransparency = 0.2
		label.TextStrokeColor3 = Color3.fromRGB(40, 24, 12)
		label.Parent = wheel
	end
	self._wheel = wheel
	self._step = step
	-- Rest where the last spin landed (a late join sees the same wheel).
	local landed = self.Instance:GetAttribute("SpinRotation")
	if typeof(landed) == "number" then
		wheel.Rotation = landed % 360
	end
end

function WheelOfFortune:_spin()
	local wheel = self._wheel
	local target = self.Instance:GetAttribute("SpinRotation")
	local startedAt = self.Instance:GetAttribute("SpinStartedAt")
	if not wheel or typeof(target) ~= "number" or typeof(startedAt) ~= "number" then
		return
	end
	if self._spinConnection then
		self._spinConnection:Disconnect()
	end
	local from = wheel.Rotation % 360
	local seconds = WheelOfFortuneData.SpinSeconds
	local step = self._step
	local lastSlot = math.floor(from / step)
	self._spinConnection = RunService.RenderStepped:Connect(function()
		local alpha = math.clamp((workspace:GetServerTimeNow() - startedAt) / seconds, 0, 1)
		local eased = TweenService:GetValue(alpha, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
		local rotation = from + (target - from) * eased
		wheel.Rotation = rotation
		local slot = math.floor(rotation / step)
		if slot ~= lastSlot then
			lastSlot = slot
			uiSound:PlayHover()
		end
		if alpha >= 1 then
			wheel.Rotation = target % 360
			if self._spinConnection then
				self._spinConnection:Disconnect()
				self._spinConnection = nil
			end
		end
	end)
end

function WheelOfFortune:Start()
	task.spawn(function()
		self:_build()
	end)
	self._idConnection = self.Instance:GetAttributeChangedSignal("SpinId"):Connect(function()
		self:_spin()
	end)
end

function WheelOfFortune:Stop()
	if self._idConnection then
		self._idConnection:Disconnect()
		self._idConnection = nil
	end
	if self._spinConnection then
		self._spinConnection:Disconnect()
		self._spinConnection = nil
	end
end

return WheelOfFortune
