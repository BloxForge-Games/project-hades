--!strict
--[[
	Module: Controllers/CutsceneController/DomainBanner.lua
	Description:
	Domain Expansion's TITLE BANNER (2026-11-10), on the caster's screen
	only, from the cast:

	  * a soft slanted white flash wipes across;
	  * a slanted band OPENS like a slit from its centre line (the white
	    edges riding the opening). Through it (a ViewportFrame with a
	    WorldModel, so the animation plays) a copy of the caster does the
	    domain's hand sign in front of the shrine, lit red, in a tight head
	    and hands shot, while the banner's camera pushes in from the hands
	    to the face;
	  * "DOMAIN" slams in on the top edge and "EXPANSION" on the bottom
	    edge, then they fade;
	  * the band CLOSES back into its centre line the same way.

	The band IS the ViewportFrame, rotated to TILT and resized as it opens
	and closes (2026-11-10: a CanvasGroup around it never clipped it -- a
	ViewportFrame draws outside its CanvasGroup). So the picture keeps its
	scale while the band crops it, the viewport camera's field of view is
	narrowed with the band's height (a slit, not a squash). The edges and
	words sit beside it. Every piece is placed in pixels each frame from
	one `open` value.

	BEHIND the copy is a picture, not the shrine model (2026-11-10: the
	model was too big to frame): BACKDROP_IMAGE on an ImageLabel the same
	band shape, under the viewport (whose own background is clear). Its
	Crop scaling keeps the picture's scale while the band opens, like the
	viewport's narrowing field of view.

	The copy carries no weapons (the in-hand and the sheathed models are
	removed), only the character and its armour. Only its root is
	anchored, so the animation moves its limbs. The banner camera follows
	the copy's HEAD each frame (the cast animation crouches it).

	The words ride the band's edges as it opens: "DOMAIN" just inside the
	top edge, "EXPANSION" just inside the bottom one; black, white
	outline.

	  local cancel = DomainBanner.play(character, startedAt)  -- a cleanup

	`startedAt`: seconds since the cast, so the copy's animation starts
	where the real one is.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local GameClock = require(ReplicatedStorage.Submodules.Core.Shared.GameClock)
local ArcaneNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ArcaneNames)
local ArcaneLoadoutController = require(ReplicatedStorage.Submodules.Core.Source.Controllers.ArcaneLoadoutController)
local DungeonNetwork = require(ReplicatedStorage.Submodules.Core.Source.Network.Dungeon)

-- The band's tilt (degrees), full height (share of the screen), width
-- (share of the screen; it overhangs both sides) and centre.
local TILT = -8
-- 0.374 since 2026-11-10 (0.34, 10% less).
local BAND_HEIGHT = 0.374
local BAND_WIDTH = 1.5
local BAND_CENTER_Y = 0.42
-- The edge lines: white outside, a thin black line just inside the band
-- (2026-11-10: a 4 px white line alone before).
local EDGE_THICKNESS = 7
local INNER_EDGE_THICKNESS = 3
-- Timeline, seconds from play() -- JJS-style (2026-11-10; slow eased
-- opens and closes before): a white BURST from the caster, the band SNAPS
-- open (a slight overshoot) as it fades, holds while the shot inside keeps
-- moving, the words fade, then the band COLLAPSES fast.
local BURST_SECONDS = 0.3
-- A soft full-screen white flash only (2026-11-10: a stronger one and a
-- white ring bursting from the caster before; too much).
local BURST_TRANSPARENCY = 0.6
-- The open and close are the earlier ones (2026-11-10: a 0.16 s snap and a
-- 0.2 s collapse tried and reverted): a Back ease open that settles at
-- full height by CLOSE_AT, then an ease-in close over CLOSE_SECONDS.
local OPEN_AT = 0
local CLOSE_AT = 1.4
local CLOSE_SECONDS = 0.55
-- The band, its edges and its picture fade out over this last share of the
-- close.
local CLOSE_FADE_SHARE = 0.5
-- The words: in with the open, held until the close, fading as they ride
-- its edges back in.
local TEXT_IN_AT = 0.05
local TEXT_IN_SECONDS = 0.2
local TEXT_OUT_AT = CLOSE_AT
local TEXT_OUT_SECONDS = CLOSE_SECONDS
-- They start side by side on the centre line and SPLIT to their edges and
-- places along the band over SPLIT_SECONDS (a Back ease).
local SPLIT_SECONDS = 0.35
local DOMAIN_START_ALONG = -0.07
local EXPANSION_START_ALONG = 0.07
-- The vignette over the backdrop picture: its edges this dark (0 = black).
local VIGNETTE_EDGE_TRANSPARENCY = 0.15
local VIGNETTE_SIDE_REACH = 0.3
local VIGNETTE_TOP_REACH = 0.45
-- The banner camera, aimed below the copy's head: it starts on the HANDS
-- (AIM_START_BELOW_HEAD) and tilts up to the face (AIM_BELOW_HEAD) while
-- pushing in, over the band's whole life -- the motion inside the hold.
-- (2026-11-10: aimed at fixed heights 3.6 -> 2.9 then 8 -> 6.5 studs off;
-- the crouching cast left the copy low and small.)
local CAMERA_FIELD_OF_VIEW = 32
-- BAND_MASK (2026-11-10, tested in Studio): a rotated ViewportFrame
-- renders to its upright bounding box, so resizing it with the band (and
-- narrowing the field of view to match) magnified the picture as the band
-- thinned -- the zoom as it closed -- and a CanvasGroup never clips a
-- ViewportFrame. So the viewport (and the backdrop) stay upright, at one
-- fixed size MASK_WIDTH of the screen wide, and a hard-edged UIGradient
-- cuts the slanted band out of them each frame. The copy stands upright
-- in the tilted band.
local MASK_WIDTH = 1.15
-- The push-in and tilt finish this early, front-loaded (Quad out), so the
-- shot is STILL well before the close (2026-11-10: easing on right up to
-- CLOSE_AT, its last creep read as a zoom as the band closed; measured in
-- Studio, the close itself holds the size exactly).
local PUSH_SECONDS = 0.9
-- The camera sits this far ABOVE its aim point and looks down onto it: a
-- level, front-on shot of the face (2026-11-10: level with the aim point,
-- below the face, it looked up at the copy).
local CAMERA_RISE = 0.7
-- 2026-11-10: 0.3 / 1.0 (0.5 / 1.5: started too low, ended short of the
-- face).
local AIM_BELOW_HEAD = 0.3
local AIM_START_BELOW_HEAD = 1.0
local CAMERA_FROM_DISTANCE = 6.5
local CAMERA_TO_DISTANCE = 5
-- The cast animation and how fast the real cast plays it
-- (VFXController/DomainExpansion), so the copy strikes the same pose.
local ANIMATION_NAME = "DomainExpansionAnimation"
local ANIMATION_SPEED = 0.35
-- The copy plays it at the real cast's speed, matching the character in
-- the world (2026-11-10: 0.2 then 0.27 for a while), and HOLDS its last
-- frame (HOLD_BEFORE_END from the end) instead of snapping back to rest.
local BANNER_ANIMATION_SPEED = ANIMATION_SPEED
local HOLD_BEFORE_END = 0.05
-- The picture behind the copy.
local BACKDROP_IMAGE = "rbxassetid://9528470282"
-- The copy's light, as set up in Studio (2026-11-10): grey ambient, a
-- red key light from above and behind.
local VIEWPORT_AMBIENT = Color3.fromRGB(125, 125, 125)
local VIEWPORT_LIGHT = Color3.fromRGB(235, 14, 18)
local VIEWPORT_LIGHT_DIRECTION = Vector3.new(-0.5, -2, 1)
local VIEWPORT_BACKGROUND = Color3.fromRGB(55, 0, 10)
-- The game's UI font (Montserrat, its heading weight).
local TEXT_FONT =
	Font.new("rbxasset://fonts/families/Montserrat.json", Enum.FontWeight.ExtraBold, Enum.FontStyle.Normal)
local TEXT_COLOR = Color3.new(0, 0, 0)
local TEXT_OUTLINE = Color3.new(1, 1, 1)
-- How far each word's centre sits OUTSIDE its edge, as a share of its own
-- height: DOMAIN rides on top of the top edge, EXPANSION under the bottom
-- one, each cutting into its edge (2026-11-10: just inside them before).
local WORD_OUTSET = 0.28
local WORD_STROKE = 3
-- Where each word sits along the band, as a share of the screen width
-- from its centre (negative = left).
local DOMAIN_ALONG = -0.24
local EXPANSION_ALONG = 0.24

local DomainBanner = {}

-- THE SNAPSHOT (2026-11-10): a clean copy of the local character taken
-- once, at rest, as it LANDS with Domain Expansion equipped (and again on
-- a later landing), kept in MEMORY only (no parent). (2026-11-10: parked
-- in workspace at y -5000 at first -- below the fall-destroy height, a
-- live-Humanoid copy there broke the player's spawn.)
-- Every banner clones THIS, never the live character, so whatever the
-- player is doing when they cast (moving, rolling, swinging, aiming) never
-- reaches the copy. The live character is the fallback until one exists.
-- How long after the landing the snapshot is taken (the landing pose has
-- settled, controls still locked).
local SNAPSHOT_AFTER_LANDING = 1
local snapshot: Model? = nil

-- The weapon models a character wears (WeaponLoadoutService): the in-hand
-- ones are tagged by their slot, the back copies "Sheathed".
local WEAPON_TAGS = { "Primary", "Secondary", "Sheathed" }

local function stripWeapons(copy: Instance)
	for _, child in copy:GetChildren() do
		if child:IsA("Model") or child:IsA("Tool") then
			for _, tag in WEAPON_TAGS do
				if child:HasTag(tag) then
					child:Destroy()
					break
				end
			end
		end
	end
end

-- The R6 rig's STANDARD joints (C0, C1), at scale 1. A copy made while
-- the character moves, rolls, swings or aims kept whatever those joints
-- held then -- TiltController's lean on the root and hips, anything else
-- that bends them -- and the copy stood skewed in the banner (2026-11-10).
-- Every one of the six is set back to these (positions scaled to the
-- rig), and its Transform cleared, so the copy always starts from the
-- same rest pose into the cast animation.
local R6_JOINTS: { [string]: { CFrame } } = {
	RootJoint = {
		CFrame.new(0, 0, 0, -1, 0, 0, 0, 0, 1, 0, 1, 0),
		CFrame.new(0, 0, 0, -1, 0, 0, 0, 0, 1, 0, 1, 0),
	},
	Neck = {
		CFrame.new(0, 1, 0, -1, 0, 0, 0, 0, 1, 0, 1, 0),
		CFrame.new(0, -0.5, 0, -1, 0, 0, 0, 0, 1, 0, 1, 0),
	},
	["Right Shoulder"] = {
		CFrame.new(1, 0.5, 0, 0, 0, 1, 0, 1, 0, -1, 0, 0),
		CFrame.new(-0.5, 0.5, 0, 0, 0, 1, 0, 1, 0, -1, 0, 0),
	},
	["Left Shoulder"] = {
		CFrame.new(-1, 0.5, 0, 0, 0, -1, 0, 1, 0, 1, 0, 0),
		CFrame.new(0.5, 0.5, 0, 0, 0, -1, 0, 1, 0, 1, 0, 0),
	},
	["Right Hip"] = {
		CFrame.new(1, -1, 0, 0, 0, 1, 0, 1, 0, -1, 0, 0),
		CFrame.new(0.5, 1, 0, 0, 0, 1, 0, 1, 0, -1, 0, 0),
	},
	["Left Hip"] = {
		CFrame.new(-1, -1, 0, 0, 0, -1, 0, 1, 0, 1, 0, 0),
		CFrame.new(-0.5, 1, 0, 0, 0, -1, 0, 1, 0, 1, 0, 0),
	},
}

local function scaled(cframe: CFrame, scale: number): CFrame
	return cframe.Rotation + cframe.Position * scale
end

local function untilt(copy: Model)
	local scale = copy:GetScale()
	for _, joint in copy:GetDescendants() do
		local standard = if joint:IsA("Motor6D") then R6_JOINTS[joint.Name] else nil
		if standard and joint:IsA("Motor6D") then
			joint.C0 = scaled(standard[1], scale)
			joint.C1 = scaled(standard[2], scale)
			joint.Transform = CFrame.identity
		end
	end
end

-- Puts a character copy's ROOT at `at` and rebuilds every limb and
-- accessory from it through its joints (Part1 = Part0 * C0 * C1^-1), the
-- whole copy anchored meanwhile (2026-11-10). The character has no
-- PrimaryPart, so PivotTo placed its BOUNDING-BOX centre -- which the
-- hitbox part, the pose and the landing animation's +25 stud lift all
-- move -- and the copy came out shifted, or (snapshotted mid-landing)
-- floating out of the shot. Now the pose at copy time never matters.
local function placeAtRoot(copy: Model, at: CFrame)
	local root = copy:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		copy:PivotTo(at)
		return
	end
	copy.PrimaryPart = root
	root.CFrame = at
	local placed: { [BasePart]: boolean } = { [root] = true }
	local joints: { JointInstance } = {}
	for _, joint in copy:GetDescendants() do
		if joint:IsA("JointInstance") and joint.Part0 and joint.Part1 then
			table.insert(joints, joint)
		end
	end
	-- Outward from the root until nothing more can be placed.
	local progressed = true
	while progressed do
		progressed = false
		for _, joint in joints do
			local part0, part1 = joint.Part0 :: BasePart, joint.Part1 :: BasePart
			if placed[part0] and not placed[part1] then
				part1.CFrame = part0.CFrame * joint.C0 * joint.C1:Inverse()
				placed[part1] = true
				progressed = true
			elseif placed[part1] and not placed[part0] then
				part0.CFrame = part1.CFrame * joint.C1 * joint.C0:Inverse()
				placed[part0] = true
				progressed = true
			end
		end
	end
end

-- A copy of `instance` with nothing that runs, sounds or shows over 3D.
-- `anchorAll`: every part anchored (a prop); else only the root (an
-- animated character, whose limbs the animation moves).
local function inertCopy(instance: Instance, anchorAll: boolean): Instance?
	local wasArchivable = instance.Archivable
	instance.Archivable = true
	local copy = instance:Clone()
	instance.Archivable = wasArchivable
	if not copy then
		return nil
	end
	for _, child in copy:GetDescendants() do
		if
			child:IsA("BaseScript")
			or child:IsA("Sound")
			or child:IsA("Highlight")
			or child:IsA("BillboardGui")
			or child:IsA("ForceField")
		then
			child:Destroy()
		elseif child:IsA("BasePart") then
			child.Anchored = anchorAll or child.Name == "HumanoidRootPart"
		end
	end
	return copy
end

local function tween(instance: Instance, seconds: number, goals: { [string]: any }, style: Enum.EasingStyle?)
	TweenService
		:Create(instance, TweenInfo.new(seconds, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out), goals)
		:Play()
end

-- A word: its label inside a CanvasGroup, faded as ONE image through the
-- group (2026-11-10: fading the text and its outline separately showed the
-- outline through the half-faded fill, a muddy, uneven fade). The label is
-- inset by the outline so the group never clips it.
-- The label's own fill and outline fade TOO (fadeWord): a CanvasGroup
-- falls back to drawing its children plainly where the device cannot
-- render it (or its texture budget is spent), and GroupTransparency then
-- does nothing (2026-11-10: the words stopped fading).
type Word = { group: CanvasGroup, label: TextLabel, stroke: UIStroke }

local function fadeWord(entry: Word, hidden: number)
	entry.group.GroupTransparency = hidden
	entry.label.TextTransparency = hidden
	entry.stroke.Transparency = hidden
end

local function word(parent: Instance, text: string): Word
	local group = Instance.new("CanvasGroup")
	group.Name = text
	group.AnchorPoint = Vector2.new(0.5, 0.5)
	group.BackgroundTransparency = 1
	group.GroupTransparency = 1
	group.Rotation = TILT
	group.ZIndex = 5
	local label = Instance.new("TextLabel")
	label.Text = text
	label.FontFace = TEXT_FONT
	label.TextColor3 = TEXT_COLOR
	label.TextScaled = true
	label.BackgroundTransparency = 1
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.5)
	label.Size = UDim2.new(1, -WORD_STROKE * 4, 1, -WORD_STROKE * 4)
	label.Parent = group
	local stroke = Instance.new("UIStroke")
	stroke.Color = TEXT_OUTLINE
	stroke.Thickness = WORD_STROKE
	stroke.Parent = label
	group.Parent = parent
	return { group = group, label = label, stroke = stroke }
end

-- How open the band is (0..1) `t` seconds in: a long soft ease in and out
-- of the slit.
-- Opens with a Back ease (just past full, settling by CLOSE_AT), then
-- closes over CLOSE_SECONDS with an ease-in (slow at the top).
-- How faded out the band is (0..1) `t` seconds in: over the last
-- CLOSE_FADE_SHARE of the close, eased.
local function closeFade(t: number): number
	local fadeStart = CLOSE_AT + CLOSE_SECONDS * (1 - CLOSE_FADE_SHARE)
	local alpha = math.clamp((t - fadeStart) / (CLOSE_SECONDS * CLOSE_FADE_SHARE), 0, 1)
	return TweenService:GetValue(alpha, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
end

local function openness(t: number): number
	if t < CLOSE_AT then
		return TweenService:GetValue(t / CLOSE_AT, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	elseif t < CLOSE_AT + CLOSE_SECONDS then
		return 1 - TweenService:GetValue((t - CLOSE_AT) / CLOSE_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	end
	return 0
end

-- How visible the words are `t` seconds in (0..1): a quick fade in, then
-- a long soft fade out that finishes before the band closes.
local function wordVisibility(t: number): number
	if t < TEXT_IN_AT then
		return 0
	elseif t < TEXT_IN_AT + TEXT_IN_SECONDS then
		return TweenService:GetValue(
			(t - TEXT_IN_AT) / TEXT_IN_SECONDS,
			Enum.EasingStyle.Quad,
			Enum.EasingDirection.Out
		)
	elseif t < TEXT_OUT_AT then
		return 1
	elseif t < TEXT_OUT_AT + TEXT_OUT_SECONDS then
		return 1
			- TweenService:GetValue(
				(t - TEXT_OUT_AT) / TEXT_OUT_SECONDS,
				Enum.EasingStyle.Sine,
				Enum.EasingDirection.InOut
			)
	end
	return 0
end

-- Plays the banner on the local player's screen; returns a cleanup that
-- removes it at once (the cutscene was cut short).
function DomainBanner.play(character: Model, startedAt: number): () -> ()
	local playerGui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return function() end
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "DomainBanner"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 40

	-- The BURST: a soft white wash over the screen, fading as the band
	-- opens.
	local flash = Instance.new("Frame")
	flash.Name = "Flash"
	flash.Size = UDim2.fromScale(1, 1)
	flash.BorderSizePixel = 0
	flash.BackgroundColor3 = Color3.new(1, 1, 1)
	flash.BackgroundTransparency = BURST_TRANSPARENCY
	flash.ZIndex = 10
	flash.Parent = gui
	tween(flash, BURST_SECONDS, { BackgroundTransparency = 1 })

	-- The band: the backdrop picture, the viewport over it, then its edges
	-- and words.
	local backdrop = Instance.new("ImageLabel")
	backdrop.Name = "Backdrop"
	backdrop.AnchorPoint = Vector2.new(0.5, 0.5)
	backdrop.BorderSizePixel = 0
	backdrop.BackgroundColor3 = VIEWPORT_BACKGROUND
	backdrop.Image = BACKDROP_IMAGE
	backdrop.ScaleType = Enum.ScaleType.Crop
	backdrop.ZIndex = 1
	backdrop.Parent = gui

	local viewport = Instance.new("ViewportFrame")
	viewport.Name = "Band"
	viewport.AnchorPoint = Vector2.new(0.5, 0.5)
	viewport.BorderSizePixel = 0
	viewport.BackgroundTransparency = 1
	viewport.Ambient = VIEWPORT_AMBIENT
	viewport.LightColor = VIEWPORT_LIGHT
	viewport.LightDirection = VIEWPORT_LIGHT_DIRECTION
	viewport.ZIndex = 2
	viewport.Parent = gui
	-- The band's shape: a hard-edged mask on each (see BAND_MASK).
	local masks: { UIGradient } = {}
	for _, masked in { viewport :: GuiObject, backdrop } do
		local mask = Instance.new("UIGradient")
		mask.Rotation = 90 + TILT
		mask.Parent = masked
		table.insert(masks, mask)
	end
	local world = Instance.new("WorldModel")
	world.Parent = viewport

	local edges: { Frame } = {}
	local innerEdges: { Frame } = {}
	for _ = 1, 2 do
		for _, inner in { false, true } do
			local edge = Instance.new("Frame")
			edge.Name = if inner then "InnerEdge" else "Edge"
			edge.AnchorPoint = Vector2.new(0.5, 0.5)
			edge.Rotation = TILT
			edge.BorderSizePixel = 0
			edge.BackgroundColor3 = if inner then Color3.new(0, 0, 0) else Color3.new(1, 1, 1)
			edge.ZIndex = 3
			edge.Parent = gui
			table.insert(if inner then innerEdges else edges, edge)
		end
	end
	local domain = word(gui, "DOMAIN")
	local expansion = word(gui, "EXPANSION")

	-- The vignette over the backdrop (under the viewport): black fading in
	-- from the band's sides and from its top and bottom.
	local vignettes: { Frame } = {}
	for _, gradientRotation in { 0, 90 } do
		local shade = Instance.new("Frame")
		shade.Name = "Vignette"
		shade.AnchorPoint = Vector2.new(0.5, 0.5)
		shade.Rotation = TILT
		shade.BorderSizePixel = 0
		shade.BackgroundColor3 = Color3.new(0, 0, 0)
		shade.ZIndex = 1
		local reach = if gradientRotation == 0 then VIGNETTE_SIDE_REACH else VIGNETTE_TOP_REACH
		local gradient = Instance.new("UIGradient")
		gradient.Rotation = gradientRotation
		gradient.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, VIGNETTE_EDGE_TRANSPARENCY),
			NumberSequenceKeypoint.new(reach, 1),
			NumberSequenceKeypoint.new(1 - reach, 1),
			NumberSequenceKeypoint.new(1, VIGNETTE_EDGE_TRANSPARENCY),
		})
		gradient.Parent = shade
		shade.Parent = gui
		table.insert(vignettes, shade)
	end

	-- The copy, facing the banner camera, mid-cast.
	local standAt = CFrame.lookAt(Vector3.new(0, 3, 0), Vector3.new(0, 3, -10))
	local source: Model = snapshot or character
	-- Every part anchored while it is placed (reseat), then all but the
	-- root freed for the animation.
	local copy = inertCopy(source, true)
	if copy and source == snapshot then
		for _, part in copy:GetDescendants() do
			if part:IsA("BasePart") then
				part.LocalTransparencyModifier = 0
			end
		end
	end
	local head: BasePart? = nil
	local castTrack: AnimationTrack? = nil
	if copy and copy:IsA("Model") then
		stripWeapons(copy)
		untilt(copy)
		local headPart = copy:FindFirstChild("Head")
		head = if headPart and headPart:IsA("BasePart") then headPart else nil
		local humanoid = copy:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		end
		placeAtRoot(copy, standAt)
		for _, part in copy:GetDescendants() do
			if part:IsA("BasePart") then
				part.Anchored = part.Name == "HumanoidRootPart"
			end
		end
		copy.Parent = world
		local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
		if humanoid and not animator then
			local made = Instance.new("Animator")
			made.Parent = humanoid
			animator = made
		end
		local asset = ReplicatedStorage.GameAssets.Animations:FindFirstChild(ANIMATION_NAME)
		if animator and asset and asset:IsA("Animation") then
			local track = animator:LoadAnimation(asset)
			track.Looped = false
			track:Play(0)
			track:AdjustSpeed(BANNER_ANIMATION_SPEED)
			track.TimePosition = startedAt * ANIMATION_SPEED
			castTrack = track
		end
	end

	-- The banner camera: in front of the copy, pushing in and up.
	local camera = Instance.new("Camera")
	camera.FieldOfView = CAMERA_FIELD_OF_VIEW
	camera.Parent = viewport
	viewport.CurrentCamera = camera

	gui.Parent = playerGui

	-- Everything placed from the screen size and how open the band is.
	local angle = math.rad(TILT)
	local along = Vector2.new(math.cos(angle), math.sin(angle))
	local across = Vector2.new(-math.sin(angle), math.cos(angle))
	local started = GameClock.Now()
	local total = CLOSE_AT + CLOSE_SECONDS
	local function place()
		local t = GameClock.Now() - started
		-- Freeze on the last frame rather than finish (which drops the pose).
		local track = castTrack
		if track and track.IsPlaying and track.Speed > 0 and track.Length > 0 then
			if track.TimePosition >= track.Length - HOLD_BEFORE_END then
				track.TimePosition = track.Length - HOLD_BEFORE_END
				track:AdjustSpeed(0)
			end
		end
		local screen = gui.AbsoluteSize
		local center = Vector2.new(screen.X * 0.5, screen.Y * BAND_CENTER_Y)
		local width = screen.X * BAND_WIDTH
		local fullHeight = screen.Y * BAND_HEIGHT
		local height = fullHeight * openness(t)
		-- The viewport and the backdrop stand UPRIGHT at one fixed size and the
		-- camera at one fixed field of view, so the picture never rescales;
		-- the slanted band is cut out of them by the masks (BAND_MASK).
		local tilt = math.rad(math.abs(TILT))
		local maskWidth = screen.X * MASK_WIDTH
		local maskHeight = fullHeight / math.cos(tilt) + maskWidth * math.tan(tilt) + 8
		viewport.Position = UDim2.fromOffset(center.X, center.Y)
		viewport.Size = UDim2.fromOffset(maskWidth, maskHeight)
		backdrop.Position = viewport.Position
		backdrop.Size = viewport.Size
		local fullTangent = math.tan(math.rad(CAMERA_FIELD_OF_VIEW) / 2)
		camera.FieldOfView = math.deg(2 * math.atan(fullTangent * maskHeight / fullHeight))
		local showing = height >= 1
		viewport.Visible = showing
		backdrop.Visible = showing
		if showing then
			-- The mask's 0..1 runs across the box along its (perpendicular to
			-- the band) axis; opaque for the band's height about the middle.
			local axis = math.rad(90 + TILT)
			local extent = maskWidth * math.abs(math.cos(axis)) + maskHeight * math.abs(math.sin(axis))
			local half = math.clamp(height / 2 / extent, 0.0015, 0.497)
			local low, high = 0.5 - half, 0.5 + half
			local sequence = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1),
				NumberSequenceKeypoint.new(low - 0.001, 1),
				NumberSequenceKeypoint.new(low, 0),
				NumberSequenceKeypoint.new(high, 0),
				NumberSequenceKeypoint.new(high + 0.001, 1),
				NumberSequenceKeypoint.new(1, 1),
			})
			for _, mask in masks do
				mask.Transparency = sequence
			end
		end
		for _, shade in vignettes do
			shade.Position = UDim2.fromOffset(center.X, center.Y)
			shade.Size = UDim2.fromOffset(width, math.max(height, 1))
			shade.Visible = showing
		end
		-- The last stretch of the close FADES everything out as it shuts
		-- (2026-11-10: it snapped shut at full speed and full strength).
		local fade = closeFade(t)
		viewport.ImageTransparency = fade
		backdrop.ImageTransparency = fade
		backdrop.BackgroundTransparency = fade
		for _, shade in vignettes do
			shade.BackgroundTransparency = fade
		end
		local hidden = 1 - wordVisibility(t)
		fadeWord(domain, hidden)
		fadeWord(expansion, hidden)
		for index, edge in edges do
			local side = if index == 1 then -1 else 1
			local at = center + across * side * (height / 2 + EDGE_THICKNESS / 2)
			edge.Position = UDim2.fromOffset(at.X, at.Y)
			edge.Size = UDim2.fromOffset(width, EDGE_THICKNESS)
			edge.BackgroundTransparency = if height < 1 then 1 else fade
			-- The black line just inside, never wider than half the band.
			local inner = innerEdges[index]
			local innerThickness = math.min(INNER_EDGE_THICKNESS, height / 2)
			local innerAt = center + across * side * (height / 2 - innerThickness / 2)
			inner.Position = UDim2.fromOffset(innerAt.X, innerAt.Y)
			inner.Size = UDim2.fromOffset(width, math.max(innerThickness, 0))
			inner.BackgroundTransparency = if height < 1 then 1 else fade
		end
		-- The words ride the edges as they open: just inside each.
		local wordHeight = fullHeight * 0.32
		local wordSize = UDim2.fromOffset(screen.X * 0.2, wordHeight)
		local edgeOffset = height / 2 + EDGE_THICKNESS / 2 + wordHeight * WORD_OUTSET
		-- Side by side on the centre line, then split apart along the band.
		local split = TweenService:GetValue(
			math.clamp((t - OPEN_AT) / SPLIT_SECONDS, 0, 1),
			Enum.EasingStyle.Back,
			Enum.EasingDirection.Out
		)
		local domainAlong = DOMAIN_START_ALONG + (DOMAIN_ALONG - DOMAIN_START_ALONG) * split
		local expansionAlong = EXPANSION_START_ALONG + (EXPANSION_ALONG - EXPANSION_START_ALONG) * split
		local domainAt = center + along * screen.X * domainAlong - across * edgeOffset
		local expansionAt = center + along * screen.X * expansionAlong + across * edgeOffset
		domain.group.Position = UDim2.fromOffset(domainAt.X, domainAt.Y)
		domain.group.Size = wordSize
		expansion.group.Position = UDim2.fromOffset(expansionAt.X, expansionAt.Y)
		expansion.group.Size = wordSize
		-- The tilt (and push-in), over the OPEN only: it settles as the close
		-- starts, so the close never reads as a zoom (2026-11-10: it ran on
		-- through the close).
		local push =
			TweenService:GetValue(math.clamp(t / PUSH_SECONDS, 0, 1), Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		local distance = CAMERA_FROM_DISTANCE + (CAMERA_TO_DISTANCE - CAMERA_FROM_DISTANCE) * push
		-- Centred on the copy's own axis (where it stands); only the HEIGHT
		-- follows its head (2026-11-10: following the head sideways too,
		-- a weapon or bow pose left the shot off-centre).
		local headY = if head and head.Parent then head.Position.Y else standAt.Position.Y + 1.5
		local below = AIM_START_BELOW_HEAD + (AIM_BELOW_HEAD - AIM_START_BELOW_HEAD) * push
		local aim = Vector3.new(standAt.Position.X, headY - below, standAt.Position.Z)
		camera.CFrame = CFrame.lookAt(aim + standAt.LookVector * distance + Vector3.new(0, CAMERA_RISE, 0), aim)
	end
	place()
	local connection = RunService.RenderStepped:Connect(place)

	local function cleanup()
		connection:Disconnect()
		gui:Destroy()
	end
	GameClock.Delay(total + 0.05, cleanup)
	return cleanup
end

-- Domain Expansion is in one of the local player's arcane slots.
local function domainEquipped(): boolean
	local registry = ArcaneLoadoutController:GetArcaneLoadoutRegistry() :: any
	for _, entry in registry do
		if type(entry) == "table" and entry.name == ArcaneNames["Domain Expansion"] then
			return true
		end
	end
	return false
end

-- Takes the snapshot of the local character now (replacing any older one),
-- if Domain Expansion is equipped and the character is alive.
function DomainBanner.TakeSnapshot()
	local character = Players.LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not character or not humanoid or humanoid.Health <= 0 or not domainEquipped() then
		return
	end
	local copy = inertCopy(character, true)
	if not copy or not copy:IsA("Model") then
		return
	end
	stripWeapons(copy)
	untilt(copy)
	-- No tags (a tagged character would pick up the components the real
	-- one runs).
	for _, item in { copy :: Instance, unpack(copy:GetDescendants()) } do
		for _, tag in item:GetTags() do
			item:RemoveTag(tag)
		end
		if item:IsA("BasePart") then
			item.CanCollide = false
			item.CanQuery = false
			item.CanTouch = false
			item.LocalTransparencyModifier = 1
		elseif item:IsA("Humanoid") then
			item.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		end
	end
	if snapshot then
		snapshot:Destroy()
	end
	copy.Name = "Snapshot"
	snapshot = copy
end

-- Snapshots on every landing (and when Domain Expansion is equipped later
-- while standing in the run), SNAPSHOT_AFTER_LANDING after it.
DungeonNetwork.LandingStart.On(function()
	GameClock.Delay(SNAPSHOT_AFTER_LANDING, DomainBanner.TakeSnapshot)
end)
ArcaneLoadoutController.Signals.OnArcaneLoadoutUpdated:Connect(function()
	if not snapshot and domainEquipped() then
		DomainBanner.TakeSnapshot()
	end
end)

return DomainBanner
