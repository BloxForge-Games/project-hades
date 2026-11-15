--!strict
--[[
	Module: Controllers/CutsceneController/CasterSubtitles.lua
	Description:
	The ultimates' lines as MINIMAL SUBTITLES on the CASTER's screen only
	(2026-11-12): white text with a soft dark outline, bottom centre, no
	name and no backdrop, film-subtitle style. Everyone else reads the
	lines in the manga panels beside the caster (MangaPanels), and the
	named subtitle strip (PlayerDialogueInterface) skips arcanes with a
	cutscene.

	Timed by ArcaneData dialogue beats ({ text, at, duration }) on the game
	clock, as the panels are. ONE LINE AT A TIME: each fades in while it
	rises into place, holds, then fades out while it rises on. A new line
	waits for the one before to finish fading out, so two never overlap.
	The LAST line holds until the toolbar comes back at the cutscene's end
	(ToolBarInterface SetVisible true) and fades out with it (2026-11-12);
	that also cuts any line still showing or due. Without that signal, the
	last line leaves LAST_LINE_MAX_SECONDS after it appears.

	It sits just ABOVE the bottom cutscene bar (CinematicInterfaceController's
	BottomBarFrame), measured every frame so it follows the bar as it
	slides; FALLBACK_Y without a bar. Drawn over the bars (DISPLAY_ORDER).

	  CasterSubtitles.play(arcaneName)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local ToolBarInterface = require(ReplicatedStorage.Submodules.Core.Source.Interfaces.ToolBarInterface)
local ArcaneData = require(ReplicatedStorage.Submodules.Core.Shared.Data.ArcaneData)
local GameClock = require(ReplicatedStorage.Submodules.Core.Shared.GameClock)

local FONT = Font.new("rbxasset://fonts/families/Montserrat.json", Enum.FontWeight.SemiBold, Enum.FontStyle.Normal)
local TEXT_COLOR = Color3.fromRGB(240, 240, 240)
local STROKE_TRANSPARENCY = 0.55
-- Over the cutscene bars, which draw at 999 (CinematicInterfaceController;
-- 2026-11-12: at 21 the line sat hidden under the bottom bar).
local DISPLAY_ORDER = 1000
-- The line's box: its height a share of the screen, the text capped at
-- MAX_TEXT_SIZE pixels. Its bottom sits BAR_GAP (a share of the screen
-- height) above the bar's top edge (2026-11-12: inside the bar read as
-- too low); FALLBACK_Y (its centre) when there is no bar on the screen.
-- The bar's ScreenGui measures from its own origin, which is copied.
local CINEMATIC_GUI_NAME = "CinematicInterfaceController"
local BOTTOM_BAR_NAME = "BottomBarFrame"
local BAR_GAP = 0.025
local FALLBACK_Y = 0.85
local LINE_HEIGHT = 0.03
local LINE_WIDTH = 0.8
local MAX_TEXT_SIZE = 19
-- A beat that names no duration holds this long.
local DEFAULT_SECONDS = 2
local FADE_IN_SECONDS = 0.35
local FADE_OUT_SECONDS = 0.35
-- How far a line rises as it fades in, and again as it fades out, in
-- line heights.
local RISE = 0.6
-- The most the last line holds when the toolbar never comes back.
local LAST_LINE_MAX_SECONDS = 10

local CasterSubtitles = {}

local gui: ScreenGui? = nil
local area: Frame? = nil
local current: TextLabel? = nil
local follow: RBXScriptConnection? = nil
-- Bumped by every play() and by the toolbar's return: a line due from an
-- older run is dropped.
local runToken = 0
local toolbarConnection: { Disconnect: (any) -> () }? = nil

-- The bottom cutscene bar, if the cinematic interface is on this screen.
local function bottomBar(playerGui: PlayerGui): (ScreenGui?, GuiObject?)
	local cinematic = playerGui:FindFirstChild(CINEMATIC_GUI_NAME)
	if not cinematic or not cinematic:IsA("ScreenGui") then
		return nil, nil
	end
	local bar = cinematic:FindFirstChild(BOTTOM_BAR_NAME, true)
	return cinematic, if bar and bar:IsA("GuiObject") then bar else nil
end

-- Puts the line area just above the bar (or at FALLBACK_Y).
local function place(playerGui: PlayerGui, screenGui: ScreenGui, lineArea: Frame)
	local cinematic, bar = bottomBar(playerGui)
	if cinematic then
		screenGui.IgnoreGuiInset = cinematic.IgnoreGuiInset
	end
	local height = screenGui.AbsoluteSize.Y
	local y = height * FALLBACK_Y
	if bar then
		local barTop = bar.AbsolutePosition.Y - screenGui.AbsolutePosition.Y
		local above = barTop - height * BAR_GAP - lineArea.AbsoluteSize.Y / 2
		y = math.min(y, above)
	end
	lineArea.Position = UDim2.new(0.5, 0, 0, y)
end

local function screen(): Frame?
	if gui and gui.Parent and area then
		return area
	end
	local playerGui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return nil
	end
	local made = Instance.new("ScreenGui")
	made.Name = "CasterSubtitles"
	made.IgnoreGuiInset = true
	made.ResetOnSpawn = false
	made.DisplayOrder = DISPLAY_ORDER

	local lineArea = Instance.new("Frame")
	lineArea.Name = "LineArea"
	lineArea.AnchorPoint = Vector2.new(0.5, 0.5)
	lineArea.Size = UDim2.fromScale(LINE_WIDTH, LINE_HEIGHT)
	lineArea.BackgroundTransparency = 1
	lineArea.Parent = made
	made.Parent = playerGui
	place(playerGui, made, lineArea)

	if follow then
		follow:Disconnect()
	end
	follow = RunService.RenderStepped:Connect(function()
		if not made.Parent then
			if follow then
				follow:Disconnect()
				follow = nil
			end
			return
		end
		-- Only while a line is up.
		if #lineArea:GetChildren() > 0 then
			place(playerGui, made, lineArea)
		end
	end)

	gui = made
	area = lineArea
	return lineArea
end

-- The line's spot, `rise` line heights above its resting place.
local function at(rise: number): UDim2
	return UDim2.fromScale(0.5, 0.5 - rise)
end

-- Fades `label` out while it rises on, then removes it.
local function fadeOut(label: TextLabel)
	local info = TweenInfo.new(FADE_OUT_SECONDS, Enum.EasingStyle.Sine, Enum.EasingDirection.In)
	GameClock.Tween(label, info, {
		TextTransparency = 1,
		TextStrokeTransparency = 1,
		Position = at(RISE),
	}):Play()
	GameClock.Debris(label, FADE_OUT_SECONDS + 0.05)
end

local function reveal(text: string, seconds: number)
	local parent = screen()
	if not parent then
		return
	end

	local label = Instance.new("TextLabel")
	label.Name = "Line"
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = at(-RISE)
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.FontFace = FONT
	label.Text = text
	label.TextColor3 = TEXT_COLOR
	label.TextStrokeColor3 = Color3.new(0, 0, 0)
	label.TextScaled = true
	label.TextWrapped = true
	label.TextTransparency = 1
	label.TextStrokeTransparency = 1
	local constraint = Instance.new("UITextSizeConstraint")
	constraint.MaxTextSize = MAX_TEXT_SIZE
	constraint.Parent = label
	label.Parent = parent
	current = label

	GameClock.Tween(label, TweenInfo.new(FADE_IN_SECONDS, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), {
		TextTransparency = 0,
		TextStrokeTransparency = STROKE_TRANSPARENCY,
		Position = at(0),
	}):Play()
	GameClock.Delay(math.max(seconds, FADE_IN_SECONDS), function()
		if label.Parent and current == label then
			current = nil
			fadeOut(label)
		end
	end)
end

-- Shows a line, once the one before (if any) has faded out.
local function show(token: number, text: string, seconds: number)
	if token ~= runToken then
		return
	end
	local previous = current
	if previous and previous.Parent then
		current = nil
		fadeOut(previous)
		GameClock.Delay(FADE_OUT_SECONDS, function()
			if token == runToken then
				reveal(text, math.max(0, seconds - FADE_OUT_SECONDS))
			end
		end)
	else
		reveal(text, seconds)
	end
end

-- The toolbar coming back (the cutscene's end): the line showing fades
-- out with it, and any line still due is dropped.
local function onToolbarShown()
	runToken += 1
	local line = current
	if line and line.Parent then
		current = nil
		fadeOut(line)
	end
	if toolbarConnection then
		toolbarConnection:Disconnect()
		toolbarConnection = nil
	end
end

-- Plays `arcaneName`'s dialogue beats as subtitles on this screen, from now.
function CasterSubtitles.play(arcaneName: string)
	local data = ArcaneData[arcaneName]
	local beats = data and data.dialogue
	if type(beats) ~= "table" then
		return
	end
	runToken += 1
	local token = runToken
	if not toolbarConnection then
		toolbarConnection = ToolBarInterface.Signals.SetVisible:Connect(function(visible: boolean)
			if visible then
				onToolbarShown()
			end
		end)
	end
	local count = #beats
	for index, beat in beats do
		if type(beat) == "table" and type(beat.text) == "string" then
			local seconds = if index == count then LAST_LINE_MAX_SECONDS else tonumber(beat.duration) or DEFAULT_SECONDS
			GameClock.Delay(tonumber(beat.at) or 0, show, token, beat.text, seconds)
		end
	end
end

return CasterSubtitles
