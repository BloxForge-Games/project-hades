--!strict
--[[
	Module: NpcMarkerController.lua
	Description:
	Location markers on the hub's NPCs (2026-11-07): an icon over each NPC
	under workspace.IgnoreInstances.NPCs, and an arrow at the screen's edge
	pointing to it while it is off screen -- the dungeon's marker system
	(Libraries/LocationMarkerSystem), started here for the hub.

	A marker sits on its NPC's HumanoidRootPart and only shows while the
	NPC is OFF SCREEN (2026-11-07): it fades out as the NPC comes into view
	and back in as it leaves, so it is purely a pointer to NPCs you cannot
	see.

	Client-only: each marker is a local, invisible anchored part with an
	"Indicator" Attachment under IgnoreInstances.MapMarkers, which the
	library picks up; nothing replicates.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local LocationMarkerSystem = require(ReplicatedStorage.Submodules.Core.Libraries.LocationMarkerSystem)

local NPC_FOLDER_NAME = "NPCs"
local MARKER_FOLDER_NAME = "MapMarkers"
-- The icon (the dungeons' objective marker), in the hub's NPC gold.
local MARKER_IMAGE = "rbxassetid://8239524757"
local MARKER_COLOR = Color3.fromRGB(255, 170, 0)
local MARKER_SIZE = 0.04
-- On screen means inside the view by this many pixels (so a marker at
-- the very edge does not flicker).
local SCREEN_INSET = 8
-- How often the NPC list is checked for change (NPCs present at join).
local REFRESH_SECONDS = 2

type Marker = {
	npc: Model,
	part: BasePart,
	indicator: Attachment,
}

local NpcMarkerController = {
	Name = "NpcMarkerController",

	_markers = {} :: { [Model]: Marker },
}

local function npcFolder(): Instance?
	local ignore = workspace:FindFirstChild("IgnoreInstances")
	return ignore and ignore:FindFirstChild(NPC_FOLDER_NAME)
end

-- Where the marker sits: the NPC's HumanoidRootPart (its pivot without one).
local function anchorPosition(npc: Model): Vector3
	local root = npc:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root.Position else npc:GetPivot().Position
end

-- Whether `position` is on screen (in front of the camera, inside the
-- view by SCREEN_INSET).
local function onScreen(position: Vector3): boolean
	local camera = workspace.CurrentCamera
	if not camera then
		return false
	end
	local point, inFront = camera:WorldToViewportPoint(position)
	local size = camera.ViewportSize
	return inFront
		and point.X >= SCREEN_INSET
		and point.Y >= SCREEN_INSET
		and point.X <= size.X - SCREEN_INSET
		and point.Y <= size.Y - SCREEN_INSET
end

function NpcMarkerController._add(self: typeof(NpcMarkerController), npc: Model)
	local ignore = workspace:FindFirstChild("IgnoreInstances")
	local folder = ignore and ignore:FindFirstChild(MARKER_FOLDER_NAME)
	if not folder then
		return
	end

	local model = Instance.new("Model")
	model.Name = "NpcMarker_" .. npc.Name
	local part = Instance.new("Part")
	part.Name = "Marker"
	part.Size = Vector3.one
	part.Transparency = 1
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.CFrame = CFrame.new(anchorPosition(npc))
	part.Parent = model
	model.PrimaryPart = part

	local indicator = Instance.new("Attachment")
	indicator.Name = "Indicator"
	indicator:SetAttribute("Image", MARKER_IMAGE)
	indicator:SetAttribute("Color", MARKER_COLOR)
	indicator:SetAttribute("IndicatorSize", MARKER_SIZE)
	indicator:SetAttribute("Enabled", true)
	-- Shown and hidden by fading (Fade 0 / 1), not by Enabled, so it eases
	-- out and keeps tracking its NPC while it does.
	indicator:SetAttribute("Fade", 0)
	indicator.Parent = part

	model.Parent = folder
	self._markers[npc] = { npc = npc, part = part, indicator = indicator }
end

-- Adds markers for new NPCs, drops those whose NPC is gone.
function NpcMarkerController._refresh(self: typeof(NpcMarkerController))
	local folder = npcFolder()
	if folder then
		for _, npc in folder:GetChildren() do
			if npc:IsA("Model") and not self._markers[npc] then
				self:_add(npc)
			end
		end
	end
	for npc, marker in self._markers do
		if not npc.Parent then
			local model = marker.part.Parent
			if model then
				model:Destroy()
			end
			self._markers[npc] = nil
		end
	end
end

-- Shows each marker only while its NPC is off screen, and keeps it on
-- its NPC.
function NpcMarkerController._update(self: typeof(NpcMarkerController))
	for npc, marker in self._markers do
		local position = anchorPosition(npc)
		marker.part.CFrame = CFrame.new(position)
		local fade = if onScreen(position) then 1 else 0
		if marker.indicator:GetAttribute("Fade") ~= fade then
			marker.indicator:SetAttribute("Fade", fade)
		end
	end
end

function NpcMarkerController.Start(self: typeof(NpcMarkerController))
	LocationMarkerSystem:Init()
	task.spawn(function()
		while true do
			self:_refresh()
			task.wait(REFRESH_SECONDS)
		end
	end)
	RunService.Heartbeat:Connect(function()
		self:_update()
	end)
end

return NpcMarkerController
