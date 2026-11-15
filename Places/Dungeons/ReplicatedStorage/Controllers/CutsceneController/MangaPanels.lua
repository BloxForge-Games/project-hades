--!strict
--[[
	Module: Controllers/CutsceneController/MangaPanels.lua
	Description:
	The ultimates' MANGA PANELS (2026-11-12; Domain Expansion first, as
	DomainPanels, then Susanoo): hand-inked speech bubbles beside the
	caster carrying the cast's lines, for every OTHER player who sees the
	cast (the VFX scripts run on every client; the caster has their own
	cutscene instead). They replace the on-screen subtitle strip for
	arcanes with a cutscene (PlayerDialogueInterface skips those).

	  * one bubble per line, PANELS[arcaneName], timed by ArcaneData
	    dialogue[n].at (the cutscene's clock), alternating sides;
	  * each FADES IN while it eases up into place, and its text WRITES
	    ITSELF in: every letter fades in over REVEAL_SOFTNESS letters'
	    time, so a soft edge sweeps along the line (2026-11-12: letters
	    snapping on one at a time read as choppy); then it drifts up
	    slowly while it is held;
	  * all of a cast's bubbles fade out smoothly together, still rising,
	    PANEL_HOLD seconds after its last line;
	  * the caster's nameplate is hidden from the first bubble until the
	    last one has faded (NameplateController.SetHiddenFor).

	A BillboardGui on the caster's root part, facing each viewer's camera
	(StudsOffset is camera-space, so left and right are as they see it).
	Each bubble is tilted a few degrees and they sit unevenly, so they
	read as drawn by hand. The art is a wobbly inked box whose tail points
	down at the caster: from the box's bottom-right on a left bubble, and
	mirrored on a right one (decals, group 33936009). The fades drive the
	image and text transparency directly (no CanvasGroup: one falls back to
	plain drawing on some devices, where its GroupTransparency does
	nothing; DomainBanner).

	  MangaPanels.play(character, arcaneName)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextService = game:GetService("TextService")

local ArcaneData = require(ReplicatedStorage.Submodules.Core.Shared.Data.ArcaneData)
local ArcaneNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ArcaneNames)
local GameClock = require(ReplicatedStorage.Submodules.Core.Shared.GameClock)
local NameplateController = require(ReplicatedStorage.Submodules.Core.Source.Controllers.NameplateController)

-- The bubble art, WIDE (1160 x 762; 2026-11-12, a tall 508 x 900 one
-- before, too narrow for a word like EXPANSION): the tail at the
-- bottom-right (decal 102226541695796) and its mirror, the tail at the
-- bottom-left (decal 123541391359260). Its box is the top 82%.
local BUBBLE_TAIL_RIGHT = "rbxassetid://70872244841801"
local BUBBLE_TAIL_LEFT = "rbxassetid://112812435678361"
local BUBBLE_ASPECT = 1160 / 762
-- The text box inside the bubble's box (above the tail), as shares of
-- the image.
local TEXT_WIDTH = 0.82
local TEXT_HEIGHT = 0.6
local BOX_CENTER_X = 0.5
local BOX_CENTER_Y = 0.41
-- The game's own font (the dialogue's and the title banner's).
local PANEL_FONT =
	Font.new("rbxasset://fonts/families/Montserrat.json", Enum.FontWeight.ExtraBold, Enum.FontStyle.Normal)
-- perSize measures the text at this size; Roblox caps TextSize at 100.
local MEASURE_SIZE = 50
local MAX_TEXT_SIZE = 100
-- Every bubble is laid out at this many pixels tall (its width follows
-- the art) and scaled to its on-screen size by a UIScale each frame.
local REFERENCE_HEIGHT = 200
-- The text's line spacing (lines a little tighter than the font's own).
local LINE_HEIGHT = 0.9

-- A bubble's height in studs unless its spec says otherwise (its width
-- follows the art), and the most distance it draws from.
local DEFAULT_HEIGHT_STUDS = 2.6
local WORLD_MAX_DISTANCE = 200

-- All of a cast's bubbles leave this long after its last line.
local PANEL_HOLD = 2.5

local FADE_IN_SECONDS = 0.6
local FADE_OUT_SECONDS = 0.7
-- The text's reveal: it starts this far into the fade in, at
-- REVEAL_LETTERS_PER_SECOND (game time), each letter fading in over
-- REVEAL_SOFTNESS letters' worth of that.
local REVEAL_START = 0.15
local REVEAL_LETTERS_PER_SECOND = 32
local REVEAL_SOFTNESS = 4
-- How far a bubble rises, as shares of its height: into place as it
-- fades in, slowly while it is held, and as it fades out.
local IN_RISE = 0.2
local HOLD_RISE = 0.12
local OUT_RISE = 0.18

type PanelSpec = {
	-- Which ArcaneData dialogue line times it (its `at`).
	line: number,
	-- Broken into its lines by hand: the label never wraps, so a word is
	-- never split across lines (2026-11-12: TextScaled wrapping broke
	-- "EXPANSION" and "HMPH" mid-word); it scales down to fit instead.
	text: string,
	-- The bubble's centre, in studs beside the root (camera-space).
	worldOffset: Vector3,
	-- Whether it sits on the caster's left (its tail on the right,
	-- towards them).
	left: boolean,
	tilt: number,
	textTilt: number,
	-- Optional: its height in studs.
	height: number?,
}

-- Uneven on purpose: different heights, tilts and text tilts.
local PANELS: { [string]: { PanelSpec } } = {
	[ArcaneNames["Domain Expansion"]] = {
		{
			line = 1,
			text = "DOMAIN\nEXPANSION...",
			worldOffset = Vector3.new(-3.1, 2.6, 0),
			left = true,
			tilt = -5,
			textTilt = -3,
		},
		{
			line = 2,
			text = "...MALEVOLENT\nSHRINE!",
			worldOffset = Vector3.new(3.2, 2.2, 0),
			left = false,
			tilt = 4,
			textTilt = -2,
		},
	},
	[ArcaneNames["Susanoo Armor"]] = {
		{
			line = 1,
			text = "HMPH...",
			worldOffset = Vector3.new(-2.6, 2.4, 0),
			left = true,
			tilt = -4,
			textTilt = -3,
			-- Smaller since its text matches the long line's (2026-11-12; 1.9).
			height = 1.6,
		},
		{
			line = 2,
			text = "JUST GIVE UP,\nAND LET ME\nCUT YOU DOWN\nALREADY!",
			worldOffset = Vector3.new(3.7, 2.7, 0),
			left = false,
			tilt = 3,
			textTilt = -2,
			height = 3.3,
		},
	},
}

type Panel = {
	image: ImageLabel,
	label: TextLabel,
	-- Moves the bubble `rise` heights above its spot over `seconds`.
	moveTo: (rise: number, seconds: number, style: Enum.EasingStyle, direction: Enum.EasingDirection) -> (),
	destroy: (after: number) -> (),
}

local MangaPanels = {}

-- Numbers each cast's nameplate hide (NameplateController sources).
local nextCastId = 0

local function lineAt(arcaneName: string, index: number): number?
	local data = ArcaneData[arcaneName]
	local lines = data and data.dialogue
	local line = type(lines) == "table" and lines[index]
	return if type(line) == "table" and type(line.at) == "number" then line.at else nil
end

-- Pixels per TextSize step of `text` (unwrapped) across and down, measured
-- once per text (YIELDS the first time; text grows linearly with its size,
-- so one measurement at MEASURE_SIZE gives it).
local measured: { [string]: Vector2 } = {}
local function perSize(text: string): Vector2?
	local cached = measured[text]
	if cached then
		return cached
	end
	local params = Instance.new("GetTextBoundsParams")
	params.Text = text
	params.Font = PANEL_FONT
	params.Size = MEASURE_SIZE
	params.Width = math.huge
	local ok, bounds = pcall(function()
		return TextService:GetTextBoundsAsync(params)
	end)
	if not ok then
		return nil
	end
	local size = bounds :: Vector2
	-- LineHeight packs the lines a little tighter than measured.
	local result = Vector2.new(size.X / MEASURE_SIZE, size.Y * LINE_HEIGHT / MEASURE_SIZE)
	if result.X <= 0 or result.Y <= 0 then
		return nil
	end
	measured[text] = result
	return result
end

-- The text height in STUDS at which `spec`'s every line fits its box.
local function fitStuds(spec: PanelSpec): number?
	local ratio = perSize(spec.text)
	if not ratio then
		return nil
	end
	local boxX = REFERENCE_HEIGHT * BUBBLE_ASPECT * TEXT_WIDTH
	local boxY = REFERENCE_HEIGHT * TEXT_HEIGHT
	local referencePixels = math.min(boxX / ratio.X, boxY / ratio.Y)
	return referencePixels * (spec.height or DEFAULT_HEIGHT_STUDS) / REFERENCE_HEIGHT
end

-- The tilted bubble: its art and its text, both fully transparent. The
-- text is `textSize` at the reference layout.
local function buildFace(parent: GuiObject, spec: PanelSpec, textSize: number): (ImageLabel, TextLabel)
	local image = Instance.new("ImageLabel")
	image.Name = "Art"
	image.Size = UDim2.fromScale(1, 1)
	image.BackgroundTransparency = 1
	image.Image = if spec.left then BUBBLE_TAIL_RIGHT else BUBBLE_TAIL_LEFT
	image.ImageTransparency = 1
	image.ScaleType = Enum.ScaleType.Stretch
	image.Rotation = spec.tilt
	image.ZIndex = 1
	image.Parent = parent

	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(if spec.left then BOX_CENTER_X else 1 - BOX_CENTER_X, BOX_CENTER_Y)
	label.Size = UDim2.fromScale(TEXT_WIDTH, TEXT_HEIGHT)
	label.BackgroundTransparency = 1
	label.FontFace = PANEL_FONT
	label.Text = ""
	label.TextColor3 = Color3.new(0, 0, 0)
	-- Every letter starts hidden through its own rich-text transparency
	-- (reveal), so the layout is the full line's from the start.
	label.RichText = true
	label.TextTransparency = 0
	-- Never wraps (a word is never split), so it is sized by hand: Roblox's
	-- TextScaled is switched off by TextWrapped = false (2026-11-12: the
	-- text stayed one size as the bubble grew and shrank with the zoom).
	label.TextScaled = false
	label.TextWrapped = false
	label.LineHeight = LINE_HEIGHT
	label.TextSize = math.clamp(textSize, 1, MAX_TEXT_SIZE)
	-- On top of the art's tilt, which it inherits.
	label.Rotation = spec.textTilt
	label.ZIndex = 2
	label.Parent = image
	return image, label
end

local nextBubbleId = 0

local function buildWorld(root: BasePart, spec: PanelSpec, textStuds: number): Panel
	local height = spec.height or DEFAULT_HEIGHT_STUDS
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "MangaPanel"
	billboard.Adornee = root
	billboard.Size = UDim2.fromScale(height * BUBBLE_ASPECT, height)
	-- The tilt pokes the corners out a little.
	billboard.ClipsDescendants = false
	billboard.StudsOffset = spec.worldOffset - Vector3.new(0, IN_RISE * height, 0)
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	billboard.MaxDistance = WORLD_MAX_DISTANCE
	billboard.ResetOnSpawn = false

	-- The bubble at its reference layout, scaled every frame to the size
	-- the billboard will draw at THIS frame: worked out from the camera
	-- right after it moves (2026-11-12: reading the billboard's
	-- AbsoluteSize trailed a frame behind a zoom, and the bubble wobbled).
	local holder = Instance.new("Frame")
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.fromScale(0.5, 0.5)
	holder.Size = UDim2.fromOffset(REFERENCE_HEIGHT * BUBBLE_ASPECT, REFERENCE_HEIGHT)
	holder.BackgroundTransparency = 1
	holder.Parent = billboard
	local scale = Instance.new("UIScale")
	scale.Scale = 0
	scale.Parent = holder
	local image, label = buildFace(holder, spec, textStuds * REFERENCE_HEIGHT / height)
	billboard.Parent = root

	nextBubbleId += 1
	local bindName = "MangaPanel_" .. tostring(nextBubbleId)
	RunService:BindToRenderStep(bindName, Enum.RenderPriority.Camera.Value + 1, function()
		if not billboard.Parent then
			RunService:UnbindFromRenderStep(bindName)
			return
		end
		local camera = workspace.CurrentCamera
		if not camera then
			return
		end
		local cameraCFrame = camera.CFrame
		local center = root.Position + cameraCFrame:VectorToWorldSpace(billboard.StudsOffset)
		local depth = (center - cameraCFrame.Position):Dot(cameraCFrame.LookVector)
		if depth <= 0.05 then
			return
		end
		local pixelsPerStud = camera.ViewportSize.Y / (2 * depth * math.tan(math.rad(camera.FieldOfView) / 2))
		scale.Scale = height * pixelsPerStud / REFERENCE_HEIGHT
	end)

	return {
		image = image,
		label = label,
		moveTo = function(rise, seconds, style, direction)
			GameClock.Tween(billboard, TweenInfo.new(seconds, style, direction), {
				StudsOffset = spec.worldOffset + Vector3.new(0, rise * height, 0),
			}):Play()
		end,
		destroy = function(after)
			GameClock.Debris(billboard, after)
		end,
	}
end

local function escape(text: string): string
	return (text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

-- The line with every letter at its transparency for `shown` letters
-- revealed (fractional: the letters just past it are part-way in).
local function revealText(letters: { string }, shown: number): string
	local parts = table.create(#letters)
	for index, letter in letters do
		local alpha = math.clamp((shown - (index - 1)) / REVEAL_SOFTNESS, 0, 1)
		if letter == "\n" or alpha >= 1 then
			parts[index] = escape(letter)
		else
			parts[index] = string.format('<font transparency="%.2f">%s</font>', 1 - alpha, escape(letter))
		end
	end
	return table.concat(parts)
end

-- Writes `text` into `label`, a soft edge sweeping along it.
local function reveal(label: TextLabel, text: string)
	local letters: { string } = {}
	for _, code in utf8.codes(text) do
		table.insert(letters, utf8.char(code))
	end
	local finish = #letters + REVEAL_SOFTNESS
	local shown = 0
	label.Text = revealText(letters, 0)
	local connection: RBXScriptConnection
	connection = RunService.RenderStepped:Connect(function(deltaTime: number)
		if not label.Parent then
			connection:Disconnect()
			return
		end
		shown = math.min(finish, shown + GameClock.Dt(deltaTime) * REVEAL_LETTERS_PER_SECOND)
		if shown >= finish then
			label.Text = escape(text)
			connection:Disconnect()
			return
		end
		label.Text = revealText(letters, shown)
	end)
end

-- Shows one bubble `at` seconds from now, held until `outAt`, its text
-- `textStuds` tall.
local function schedule(character: Model, spec: PanelSpec, at: number, outAt: number, textStuds: number)
	GameClock.Delay(at, function()
		if not character.Parent then
			return
		end
		local root = character:FindFirstChild("HumanoidRootPart")
		if not root or not root:IsA("BasePart") then
			return
		end
		local panel = buildWorld(root, spec, textStuds)
		local holdSeconds = math.max(FADE_IN_SECONDS, outAt - at)

		-- Fade in, rising into place.
		GameClock.Tween(
			panel.image,
			TweenInfo.new(FADE_IN_SECONDS, Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
			{ ImageTransparency = 0 }
		):Play()
		panel.moveTo(0, FADE_IN_SECONDS, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
		GameClock.Delay(REVEAL_START, reveal, panel.label, spec.text)
		-- Then a slow drift up while it is held.
		GameClock.Delay(FADE_IN_SECONDS, function()
			panel.moveTo(HOLD_RISE, holdSeconds - FADE_IN_SECONDS, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
		end)

		-- A smooth fade out, still rising.
		GameClock.Delay(holdSeconds, function()
			local fadeOut = TweenInfo.new(FADE_OUT_SECONDS, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
			GameClock.Tween(panel.image, fadeOut, { ImageTransparency = 1 }):Play()
			GameClock.Tween(panel.label, fadeOut, { TextTransparency = 1 }):Play()
			panel.moveTo(HOLD_RISE + OUT_RISE, FADE_OUT_SECONDS, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
			panel.destroy(FADE_OUT_SECONDS + 0.1)
		end)
	end)
end

-- Schedules `arcaneName`'s bubbles from the cast, for everyone but the
-- caster. A line with no ArcaneData timing is skipped.
function MangaPanels.play(character: Model, arcaneName: string)
	if character == Players.LocalPlayer.Character then
		return
	end
	local specs = PANELS[arcaneName]
	if not specs then
		return
	end
	local timed: { { spec: PanelSpec, at: number } } = {}
	local firstAt = math.huge
	local lastAt = 0
	for _, spec in specs do
		local at = lineAt(arcaneName, spec.line)
		if at then
			table.insert(timed, { spec = spec, at = at })
			firstAt = math.min(firstAt, at)
			lastAt = math.max(lastAt, at)
		end
	end
	if #timed == 0 then
		return
	end
	local outAt = lastAt + PANEL_HOLD
	-- ONE text size for all of a cast's bubbles: the largest at which every
	-- bubble's lines fit (2026-11-12: each fitted its own, and "HMPH..." came
	-- out bigger than the line after it). Measuring yields, so the delays
	-- count from the cast.
	local startedAt = GameClock.Now()
	task.spawn(function()
		local textStuds = math.huge
		for _, entry in timed do
			local studs = fitStuds(entry.spec)
			if studs then
				textStuds = math.min(textStuds, studs)
			end
		end
		if textStuds == math.huge then
			return
		end
		local elapsed = GameClock.Now() - startedAt
		for _, entry in timed do
			schedule(character, entry.spec, math.max(0, entry.at - elapsed), outAt - elapsed, textStuds)
		end
	end)

	-- The caster's nameplate is hidden while their bubbles are up: it drew
	-- across them (2026-11-12). One source per cast, so two casts overlap
	-- cleanly.
	local player = Players:GetPlayerFromCharacter(character)
	if player then
		nextCastId += 1
		local source = "MangaPanels_" .. tostring(nextCastId)
		GameClock.Delay(firstAt, function()
			NameplateController:SetHiddenFor(player, source, true)
		end)
		GameClock.Delay(outAt + FADE_OUT_SECONDS, function()
			NameplateController:SetHiddenFor(player, source, false)
		end)
	end
end

return MangaPanels
