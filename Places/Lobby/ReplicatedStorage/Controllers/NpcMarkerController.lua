--!strict
--[[
	Module: NpcMarkerController.lua
	Description:
	Location markers on the hub's NPCs (2026-11-07): an icon over each NPC
	under workspace.IgnoreInstances.NPCs, and an arrow at the screen's edge
	pointing to it while it is off screen -- the dungeon's marker system
	(Libraries/LocationMarkerSystem), started here for the hub.

	A marker floats 2 studs above its NPC's head and hides while it has
	nothing to tell you: when you are close enough for the NPC's highlight
	(LobbyNpcLifeController: your Head within HIGHLIGHT_STUDS of its
	HumanoidRootPart, the same rule), and while you are talking to it. It
	comes back as you walk away.

	Client-only: each marker is a local, invisible anchored part with an
	"Indicator" Attachment under IgnoreInstances.MapMarkers, which the
	library picks up; nothing replicates.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local LocationMarkerSystem = require(ReplicatedStorage.Submodules.Core.Libraries.LocationMarkerSystem)
local DialogueBillboardInterface =
	require(ReplicatedStorage.Submodules.Core.Source.Interfaces.DialogueBillboardInterface)
local LobbyNpcLifeController = require(script.Parent.LobbyNpcLifeController)

local NPC_FOLDER_NAME = "NPCs"
local MARKER_FOLDER_NAME = "MapMarkers"
-- The icon (the dungeons' objective marker), in the hub's NPC gold.
local MARKER_IMAGE = "rbxassetid://8239524757"
local MARKER_COLOR = Color3.fromRGB(255, 170, 0)
local MARKER_SIZE = 0.04
-- Studs between the top of the NPC's head and the marker.
local HEAD_PADDING = 2
-- How often the NPC list is checked for change (NPCs present at join).
local REFRESH_SECONDS = 2

type Marker = {
	npc: Model,
	part: BasePart,
	indicator: Attachment,
}

local NpcMarkerController = {
	Name = "NpcMarkerController",
	Dependencies = { DialogueBillboardInterface, LobbyNpcLifeController } :: { any },

	_markers = {} :: { [Model]: Marker },
}

local function npcFolder(): Instance?
	local ignore = workspace:FindFirstChild("IgnoreInstances")
	return ignore and ignore:FindFirstChild(NPC_FOLDER_NAME)
end

-- Where the marker sits: HEAD_PADDING above the top of the NPC's head
-- (2026-11-07), or above its pivot without a Head.
local function anchorPosition(npc: Model): Vector3
	local head = npc:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		return head.Position + Vector3.new(0, head.Size.Y / 2 + HEAD_PADDING, 0)
	end
	return npc:GetPivot().Position + Vector3.new(0, 3 + HEAD_PADDING, 0)
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

-- Shows or hides each marker: hidden while its NPC is highlighted (your
-- Head within HIGHLIGHT_STUDS of its HumanoidRootPart, the highlight's own
-- rule) or while talking to it. Also keeps each one on its NPC.
function NpcMarkerController._update(self: typeof(NpcMarkerController))
	local character = Players.LocalPlayer.Character
	local head = character and character:FindFirstChild("Head")
	local at = if head and head:IsA("BasePart") then head.Position else nil
	local talkingTo = if DialogueBillboardInterface:IsInDialogue()
		then DialogueBillboardInterface:GetActiveDialogueModel()
		else nil

	for npc, marker in self._markers do
		local position = anchorPosition(npc)
		marker.part.CFrame = CFrame.new(position)
		local near = at ~= nil and (at - position).Magnitude <= LobbyNpcLifeController.HIGHLIGHT_STUDS
		local show = not near and talkingTo ~= npc
		local fade = if show then 0 else 1
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
