--!strict
--[[
	Module: Controllers/RelicUnlockController.lua
	Description:
	Announces what the LOCAL player just earned (2026-11-06), read by
	diffing the profile snapshots (DataController), so no remote of its own:
	  * a relic unlocked (profile.RelicUnlocks gains a name): a gold banner
	    at the top of the screen, the relic's icon, "Relic Unlocked" and its
	    name in its rarity's colour, with the Legendary reveal sound. Several
	    at once queue, one after another.
	  * a monster met for the first time (profile.Codex.Monsters gains a
	    name): a small "New Monster" toast.
	The first snapshot is the baseline: nothing already earned is shown.
]]

--[ Roblox Services ]--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

--[ Imports ]--

local DataController = require(ReplicatedStorage.Submodules.Core.Source.Controllers.DataController)
local NotificationColors = require(ReplicatedStorage.Submodules.Core.Shared.Data.NotificationColors)
local RarityColors = require(ReplicatedStorage.Submodules.Core.Shared.Data.RarityColors)
local RelicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicData)
local UserNotificationSystem = require(ReplicatedStorage.Submodules.Core.Libraries.UserNotificationSystem).Controller

--[ Constants ]--

local GOLD = Color3.fromRGB(255, 170, 0)
local PLATE_COLOR = Color3.fromRGB(20, 31, 40)
local UNLOCK_SOUND_ID = "rbxassetid://134101870095704"
local UNLOCK_SOUND_VOLUME = 0.8
local BANNER_HOLD_SECONDS = 3.2
local BANNER_GAP_SECONDS = 0.35
local IN_TWEEN = TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local OUT_TWEEN = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
-- Where the banner rests and where it slides in from (scale of the screen).
local SHOWN_Y = 0.12
local HIDDEN_Y = -0.15

--[ Module ]--

local RelicUnlockController = {
	Name = "RelicUnlockController",
	Dependencies = { DataController } :: { any },
	_knownRelics = nil :: { [string]: boolean }?,
	_knownMonsters = nil :: { [string]: boolean }?,
	_queue = {} :: { string },
	_showing = false,
	_gui = nil :: ScreenGui?,
}

--[ Private ]--

local function namesIn(value: any): { [string]: boolean }
	local out = {}
	if type(value) == "table" then
		for name in value do
			if type(name) == "string" then
				out[name] = true
			end
		end
	end
	return out
end

local function rarityColor(relicName: string): Color3
	local data = RelicData[relicName]
	local color = data and (RarityColors :: any)[data.rarity]
	return if typeof(color) == "Color3" then color else GOLD
end

function RelicUnlockController._ensureGui(self: typeof(RelicUnlockController)): ScreenGui
	local gui = self._gui
	if gui and gui.Parent then
		return gui
	end
	local screen = Instance.new("ScreenGui")
	screen.Name = "RelicUnlockBanner"
	screen.DisplayOrder = 120
	screen.IgnoreGuiInset = true
	screen.ResetOnSpawn = false
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screen.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	self._gui = screen
	return screen
end

-- One banner, start to finish (yields).
function RelicUnlockController._playBanner(self: typeof(RelicUnlockController), relicName: string)
	local screen = self:_ensureGui()
	local data = RelicData[relicName]

	local plate = Instance.new("Frame")
	plate.Name = "Banner"
	plate.AnchorPoint = Vector2.new(0.5, 0.5)
	plate.BackgroundColor3 = PLATE_COLOR
	plate.Position = UDim2.fromScale(0.5, HIDDEN_Y)
	plate.Size = UDim2.fromScale(0.3, 0.1)
	plate.ZIndex = 1
	local aspect = Instance.new("UIAspectRatioConstraint")
	aspect.AspectRatio = 4.4
	aspect.Parent = plate
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.18, 0)
	corner.Parent = plate
	local stroke = Instance.new("UIStroke")
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Color = GOLD
	stroke.Thickness = 2.5
	stroke.Parent = plate

	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.AnchorPoint = Vector2.new(0, 0.5)
	icon.BackgroundTransparency = 1
	icon.Image = if data and type(data.icon) == "string" then data.icon else ""
	icon.Position = UDim2.fromScale(0.04, 0.5)
	icon.ScaleType = Enum.ScaleType.Fit
	icon.Size = UDim2.fromScale(0.2, 0.84)
	icon.ZIndex = 2
	icon.Parent = plate

	local function label(name: string, text: string, color: Color3, y: number, height: number, weight: Enum.FontWeight)
		local textLabel = Instance.new("TextLabel")
		textLabel.Name = name
		textLabel.BackgroundTransparency = 1
		textLabel.FontFace = Font.new("rbxasset://fonts/families/Montserrat.json", weight)
		textLabel.Position = UDim2.fromScale(0.27, y)
		textLabel.Size = UDim2.fromScale(0.69, height)
		textLabel.Text = text
		textLabel.TextColor3 = color
		textLabel.TextScaled = true
		textLabel.TextXAlignment = Enum.TextXAlignment.Left
		textLabel.ZIndex = 2
		local outline = Instance.new("UIStroke")
		outline.Color = Color3.fromRGB(25, 25, 25)
		outline.Thickness = 1.2
		outline.Parent = textLabel
		textLabel.Parent = plate
	end
	label("Title", "RELIC UNLOCKED", GOLD, 0.16, 0.3, Enum.FontWeight.Heavy)
	label("RelicName", relicName, rarityColor(relicName), 0.5, 0.34, Enum.FontWeight.Bold)

	plate.Parent = screen

	local sound = Instance.new("Sound")
	sound.SoundId = UNLOCK_SOUND_ID
	sound.Volume = UNLOCK_SOUND_VOLUME
	sound.Parent = SoundService
	sound:Play()
	task.delay(4, function()
		sound:Destroy()
	end)

	TweenService:Create(plate, IN_TWEEN, { Position = UDim2.fromScale(0.5, SHOWN_Y) }):Play()
	task.wait(IN_TWEEN.Time + BANNER_HOLD_SECONDS)
	local out = TweenService:Create(plate, OUT_TWEEN, { Position = UDim2.fromScale(0.5, HIDDEN_Y) })
	out:Play()
	out.Completed:Wait()
	plate:Destroy()
end

function RelicUnlockController._drain(self: typeof(RelicUnlockController))
	if self._showing then
		return
	end
	self._showing = true
	task.spawn(function()
		while #self._queue > 0 do
			local relicName = table.remove(self._queue, 1) :: string
			self:_playBanner(relicName)
			task.wait(BANNER_GAP_SECONDS)
		end
		self._showing = false
	end)
end

function RelicUnlockController._onProfile(self: typeof(RelicUnlockController), profile: any)
	if type(profile) ~= "table" or next(profile) == nil then
		return
	end
	local relics = namesIn(profile.RelicUnlocks)
	local monsters = namesIn(if type(profile.Codex) == "table" then profile.Codex.Monsters else nil)
	local knownRelics, knownMonsters = self._knownRelics, self._knownMonsters
	self._knownRelics, self._knownMonsters = relics, monsters
	if not knownRelics or not knownMonsters then
		return
	end

	-- Fewer names than before is a reset (/unlockrelics reset): nothing new.
	for relicName in relics do
		if not knownRelics[relicName] then
			table.insert(self._queue, relicName)
		end
	end
	self:_drain()

	for mobName in monsters do
		if not knownMonsters[mobName] then
			UserNotificationSystem:ShowNotification({
				titleText = "New Monster",
				titleTextFont = Enum.Font.SourceSansBold :: any,
				titleTextColor3 = NotificationColors.Reward,
				titleTextTransparency = 0,
				text = mobName .. " added to your Codex.",
				textFont = Enum.Font.SourceSansBold :: any,
				textColor3 = Color3.fromRGB(255, 255, 255),
				textTransparency = 0,
			})
		end
	end
end

--[ Lifecycle ]--

function RelicUnlockController.Start(self: typeof(RelicUnlockController))
	DataController.Signals.OnProfileChanged:Connect(function(profile)
		self:_onProfile(profile)
	end)
	self:_onProfile(DataController:GetProfileData())
end

return RelicUnlockController
