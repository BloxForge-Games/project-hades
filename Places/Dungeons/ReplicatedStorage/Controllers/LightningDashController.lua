--!strict
--[[
	Module: LightningDashController
	Description:
	Sparkle Time Hoverboard's LIGHTNING DASH, as every client sees it. While
	a character carries the LightningDash attribute (DodgeService sets it
	for the dash's i-frames), its body is hidden on this client and an
	electric current is drawn along the path it travels: short jagged
	neon segments from where it was last frame to where it is now, each
	flashing out, with a light riding the head of the current and an
	electric crackle at the start.

	Purely visual and local; the dash itself (speed, i-frames, Shock) is
	the server's and DodgeController's.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local GameClock = require(ReplicatedStorage.Submodules.Core.Shared.GameClock)

-- The dash's current, whoever dashes (never the relic Shock colours).
local CURRENT_COLOR = Color3.fromRGB(140, 210, 255)
local vfxBudget = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.vfxBudget)

local SEGMENT_FADE_SECONDS = 0.3
local SEGMENT_THICKNESS = 0.3
local JITTER = 1.1
-- Each stretch of path is drawn as this many jagged pieces (one on a
-- phone or low quality); a stretch is drawn once the root has moved
-- SEGMENT_STUDS (2026-11-05; every frame before, two parts a frame).
local PIECES_PER_FRAME = 2
local SEGMENT_STUDS = 1.5
local DASH_SOUND_ID = "rbxassetid://109264260607772"
local DASH_SOUND_VOLUME = 1.5

local LightningDashController = {
	Name = "LightningDashController",
}

type Dash = { connection: RBXScriptConnection, light: PointLight, restore: { [Instance]: number } }
local active: { [Model]: Dash } = {}

local function effectsFolder(): Instance
	return workspace.IgnoreInstances:FindFirstChild("ArcaneSpells") or workspace.IgnoreInstances
end

local function drawPiece(a: Vector3, b: Vector3, color: Color3)
	local length = (b - a).Magnitude
	if length < 0.05 then
		return
	end
	local piece = Instance.new("Part")
	piece.Name = "LightningDashCurrent"
	piece.Anchored = true
	piece.CanCollide = false
	piece.CanQuery = false
	piece.CanTouch = false
	piece.CastShadow = false
	piece.Material = Enum.Material.Neon
	piece.Color = color
	piece.Size = Vector3.new(SEGMENT_THICKNESS, SEGMENT_THICKNESS, length)
	piece.CFrame = CFrame.lookAt(a:Lerp(b, 0.5), b)
	piece.Parent = effectsFolder()
	GameClock.Tween(piece, TweenInfo.new(SEGMENT_FADE_SECONDS), {
		Transparency = 1,
		Size = Vector3.new(0.05, 0.05, length),
	}):Play()
	GameClock.Debris(piece, SEGMENT_FADE_SECONDS + 0.05)
end

local function drawCurrent(from: Vector3, to: Vector3, color: Color3)
	local previous = from
	local pieces = vfxBudget.count(PIECES_PER_FRAME, 1)
	for index = 1, pieces do
		local point = from:Lerp(to, index / pieces)
		if index < pieces then
			point += Vector3.new(
				(math.random() * 2 - 1) * JITTER,
				(math.random() * 2 - 1) * JITTER,
				(math.random() * 2 - 1) * JITTER
			)
		end
		drawPiece(previous, point, color)
		previous = point
	end
end

local function hide(character: Model): { [Instance]: number }
	local restore: { [Instance]: number } = {}
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("BasePart") then
			restore[descendant] = descendant.LocalTransparencyModifier
			descendant.LocalTransparencyModifier = 1
		elseif descendant:IsA("Decal") then
			restore[descendant] = descendant.Transparency
			descendant.Transparency = 1
		end
	end
	return restore
end

local function stop(character: Model)
	local dash = active[character]
	if not dash then
		return
	end
	active[character] = nil
	dash.connection:Disconnect()
	dash.light:Destroy()
	for instance, value in dash.restore do
		if instance.Parent then
			if instance:IsA("BasePart") then
				instance.LocalTransparencyModifier = value
			elseif instance:IsA("Decal") then
				instance.Transparency = value
			end
		end
	end
end

local function start(character: Model)
	stop(character)
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return
	end
	local sound = Instance.new("Sound")
	sound.SoundId = DASH_SOUND_ID
	sound.Volume = DASH_SOUND_VOLUME
	sound.Parent = root
	sound:Play()
	GameClock.Debris(sound, 5)

	-- Always the pale blue (2026-11-05: back from the Shock purple /
	-- Coil Shocked yellow it took for a day).
	local color = CURRENT_COLOR
	local light = Instance.new("PointLight")
	light.Color = color
	light.Brightness = 3
	light.Range = 12
	light.Parent = root
	local last = root.Position
	local connection = RunService.RenderStepped:Connect(function()
		local now = root.Position
		if (now - last).Magnitude >= SEGMENT_STUDS then
			drawCurrent(last, now, color)
			last = now
		end
	end)
	active[character] = { connection = connection, light = light, restore = hide(character) }
end

local function watch(character: Model)
	character:GetAttributeChangedSignal(Attributes.LightningDash):Connect(function()
		if character:GetAttribute(Attributes.LightningDash) == true then
			start(character)
		else
			stop(character)
		end
	end)
	character.AncestryChanged:Connect(function(_, parent)
		if not parent then
			stop(character)
		end
	end)
end

local function watchPlayer(player: Player)
	if player.Character then
		watch(player.Character)
	end
	player.CharacterAdded:Connect(watch)
end

function LightningDashController.Start(_self: typeof(LightningDashController))
	for _, player in Players:GetPlayers() do
		watchPlayer(player)
	end
	Players.PlayerAdded:Connect(watchPlayer)
end

return LightningDashController
