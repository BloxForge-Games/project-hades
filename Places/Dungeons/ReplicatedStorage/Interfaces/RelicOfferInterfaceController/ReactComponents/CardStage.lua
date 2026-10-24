--[[
	Module: CardStage.lua
	Description:
	The 3D stage the relic offer's cards stand on. Each OfferCard rents ONE
	thin, invisible Part parented to the camera; its React tree draws onto
	a SurfaceGui on the part's FRONT face and a card-back image onto a
	SurfaceGui on its BACK face. Both guis live in PlayerGui with the part
	as Adornee, so the ImageButton inside still takes hover and clicks.

	The stage poses every live part once per frame (one RenderStep bind,
	opened with the first card and closed with the last) in front of the
	camera, parallel to the screen, so a card always faces the player
	however the isometric camera moves. Everything is sized from the
	camera's FOV and viewport so the card FACE lands on screen exactly where
	the old 2D row put it: the same height fraction, the same centre y, the
	same gap. Resize or FOV change recomputes it.

	The PART is a little wider and taller than the card face (PART_WIDTH /
	PART_HEIGHT, in face widths / heights): transparent margin around the
	face for the embers, the shadow blur and the pick ring, since a
	SurfaceGui clips at its edge.

	THE KEYWORD TOOLTIPS are on the part too: the OfferCard hangs its
	column off the face's right edge in the front gui, so it turns, tilts
	and lifts with the card. The part therefore carries a wide margin on
	the face's RIGHT (TOOLTIP_MARGIN) for the column to land in, since a
	SurfaceGui clips at its edge. AlwaysOnTop guis on overlapping parts
	sort by depth, and only the hovered card is lifted toward the camera
	(the Container drops every other card's hover the moment one is
	hovered), so the open column always draws over its neighbour.

	POSE, per card -- every field tweenable through tweenPose:
	  x       displacement from the slot, in face WIDTHS (right positive)
	  y       displacement from the slot, in face HEIGHTS (down positive,
	          like a UDim2 offset)
	  depth   studs toward the camera (the hover lift, the taken fly-in)
	  yaw     degrees about the face's vertical axis (the deal-in spin, the
	          dismissed flip-back); 180 shows the back
	  pitch   degrees about the face's horizontal axis (top edge toward the
	          camera positive)
	  roll    degrees about the view axis
	Rotations turn the part about the FACE's centre, not the part's, so a
	spinning card turns on its own spine.

	ORIENTATION: a Part's Front face is its -Z, and the camera looks down
	ITS -Z, so a part sharing the camera's orientation would show its back.
	The stage turns every part half a turn about Y (FACE_CAMERA) so at
	yaw 0 the Front face (the card tree) looks AT the camera and the Back
	face (the card back) looks away. A Front-face gui's x runs toward the
	part's -X, so the face, in the gui's left portion, sits on the part's
	+X side, and the part is shifted that way so the face centre -- not
	the part centre -- lands on the slot.

	TILT: while a card is hovered the stage adds a small, smoothed tilt
	toward the cursor on top of the pose (setTilt), so the card leans
	toward the pointer like a tile on a pivot.

	LAYERING: an AlwaysOnTop SurfaceGui draws over the world but UNDER every
	ScreenGui, which is why the Container's old dim backdrop is gone (it
	would have painted over the cards and swallowed their input). The
	hovered card moves toward the camera, so it also sorts in front of its
	neighbours where their parts overlap.

	THE DIM: the backdrop's job is done in the world instead (setDim): one
	black part the stage keeps squarely in front of the camera, DIM_BEHIND
	studs behind the card plane and sized to cover the whole view there
	with margin, tweened between clear and DIM_TRANSPARENCY. The cards
	draw over it (AlwaysOnTop); the world shows through it dimmed. It
	exists only while a hand is up -- created on the first setDim(true),
	destroyed once the fade-out lands -- so an idle client runs nothing.

	The card back is the OfferCard's own (its frame art in its rarity
	tint, CardSurface's `back` prop). A SurfaceGui on the Back face is
	laid out to READ CORRECTLY from behind the part (Roblox mirrors it for
	the viewer), so the back goes in plain, no flip, on the face's
	mirrored rectangle.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage.Submodules.Core.Packages.React)
local ReactRoblox = require(ReplicatedStorage.Submodules.Core.Packages["React-Roblox"])

--[ Tuning ]--

-- The card face: width over height (the old 2D slot's constraint).
local FACE_ASPECT = 0.68

-- The part, in face widths / heights, and where the face sits in it:
-- FACE_MARGIN of margin on the left, top and bottom (the ember field is
-- 1.32 x 1.28, the pick ring grows to 1.18, the shadow blurs past that)
-- and, on the RIGHT, that margin plus TOOLTIP_MARGIN for the keyword
-- column the OfferCard hangs off the face (its TOOLTIP_GAP + TOOLTIP_WIDTH
-- is 0.86 face widths; the rest is slack for the plates' slide).
local FACE_MARGIN = 0.2
local TOOLTIP_MARGIN = 0.9
local PART_WIDTH = 1 + 2 * FACE_MARGIN + TOOLTIP_MARGIN
local PART_HEIGHT = 1 + 2 * FACE_MARGIN
local FACE_LEFT = FACE_MARGIN
local FACE_TOP = FACE_MARGIN
local PART_THICKNESS = 0.05

-- How far in front of the camera the cards rest. Far enough that a card
-- flying toward the camera (TAKEN) has room before the near plane; close
-- enough that nothing in the world sits between (the guis are AlwaysOnTop
-- anyway).
local STAGE_DISTANCE = 8

-- The hover tilt toward the cursor: the most the card leans (degrees) when
-- the cursor is at the face's edge, and how fast it follows (per second).
local TILT_MAX_DEGREES = 7
local TILT_FOLLOW_RATE = 12

-- The RenderStep bind runs AFTER the camera controller has moved the
-- camera for the frame (sizing, tilt, the fallback placement). Anything
-- that writes the camera LATER in the frame -- the screen shake, a
-- cutscene -- is caught by a CFrame-changed hook on the camera that
-- re-places the parts from the final CFrame, so they never lag it.
local RENDER_BIND_NAME = "RelicOfferCardStage"

-- The dim plane: this far behind the card plane, this much larger than
-- the view there (so no edge shows on a wide screen or mid camera move),
-- this dark when on (the old 2D backdrop's value).
local DIM_BEHIND = 2
local DIM_MARGIN = 1.3
local DIM_TRANSPARENCY = 0.7
local DIM_DEFAULT_TWEEN = TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)

-- Half a turn about Y: the part's Front face toward the camera (see the
-- header). Applied AFTER the pose rotation, so yaw / pitch / roll read in
-- camera space.
local FACE_CAMERA = CFrame.Angles(0, math.pi, 0)
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 1

--[ Types ]--

export type Pose = {
	x: number?,
	y: number?,
	depth: number?,
	yaw: number?,
	pitch: number?,
	roll: number?,
}

export type Layout = {
	-- The face height as a fraction of the viewport height.
	cardHeight: number,
	-- The face centre's y as a fraction of the viewport height.
	rowY: number,
	-- Gap between faces as a fraction of the viewport WIDTH (the old
	-- UIListLayout padding).
	gap: number,
}

export type Card = {
	part: Part,
	frontGui: SurfaceGui,
	backGui: SurfaceGui,
	-- The pose's yaw, live (degrees): the deal's reveal watches it.
	yawValue: NumberValue,
	setSlot: (self: Card, index: number, count: number) -> (),
	setPose: (self: Card, pose: Pose) -> (),
	tweenPose: (self: Card, pose: Pose, info: TweenInfo) -> Tween?,
	setTilt: (self: Card, on: boolean) -> (),
	faceCenter: (self: Card) -> Vector2,
	containsPoint: (self: Card, point: Vector2) -> boolean,
	destroy: (self: Card) -> (),
}

--[ State ]--

local localPlayer = Players.LocalPlayer

local layout: Layout = { cardHeight = 0.46, rowY = 0.541, gap = 0.028 }

-- Derived from the camera each frame it changes (viewport, FOV, layout).
local metrics = {
	viewport = Vector2.zero,
	fov = 0,
	halfWidth = 0,
	halfHeight = 0,
	faceWidth = 0,
	faceHeight = 0,
	pixelsPerStud = 1,
	-- The dim plane's size at its distance (placeDim), cached here.
	dimSize = Vector3.zero,
	layout = nil :: Layout?,
}

local cards: { [any]: any } = {}
local renderBound = false

-- The dim plane (setDim), and the generation of its current fade: a
-- fade-out overtaken by a new fade-in finds its generation stale and
-- leaves the part alone.
local dimPart: Part? = nil
local dimGeneration = 0

local lastClock = os.clock()

--[ Metrics ]--

local function refreshMetrics(camera: Camera): boolean
	local viewport = camera.ViewportSize
	local fov = camera.FieldOfView
	if viewport == metrics.viewport and fov == metrics.fov and metrics.layout == layout then
		return false
	end
	if viewport.X <= 0 or viewport.Y <= 0 then
		return false
	end
	metrics.viewport = viewport
	metrics.fov = fov
	metrics.layout = layout
	-- The view's half extents, in studs, on the plane STAGE_DISTANCE out.
	metrics.halfHeight = STAGE_DISTANCE * math.tan(math.rad(fov / 2))
	metrics.halfWidth = metrics.halfHeight * viewport.X / viewport.Y
	metrics.faceHeight = layout.cardHeight * 2 * metrics.halfHeight
	metrics.faceWidth = metrics.faceHeight * FACE_ASPECT
	-- One gui pixel per screen pixel on the resting plane, so TextScaled
	-- caps and the phone's fixed text sizes mean what they did in 2D.
	metrics.pixelsPerStud = viewport.Y / (2 * metrics.halfHeight)
	local dimDistance = STAGE_DISTANCE + DIM_BEHIND
	local dimHalfHeight = dimDistance * math.tan(math.rad(fov / 2))
	local dimHalfWidth = dimHalfHeight * viewport.X / viewport.Y
	metrics.dimSize = Vector3.new(2 * dimHalfWidth * DIM_MARGIN, 2 * dimHalfHeight * DIM_MARGIN, PART_THICKNESS)
	return true
end

local function applyMetrics(card)
	card.part.Size = Vector3.new(PART_WIDTH * metrics.faceWidth, PART_HEIGHT * metrics.faceHeight, PART_THICKNESS)
	card.frontGui.PixelsPerStud = metrics.pixelsPerStud
	card.backGui.PixelsPerStud = metrics.pixelsPerStud
end

-- The slot's face centre, in screen fractions, as the old row laid it out:
-- the faces centred as a group on x = 0.5, `gap` of the width apart.
local function slotCenterFraction(card): Vector2
	local faceWidthFraction = metrics.faceWidth / (2 * metrics.halfWidth)
	local pitch = faceWidthFraction + layout.gap
	local x = 0.5 + (card.index - (card.count + 1) / 2) * pitch
	return Vector2.new(x, layout.rowY)
end

-- The face centre in CAMERA space for the card's current pose, and the
-- rotation (camera space, tilt included) to apply about it. At rest the
-- front normal is the camera's +Z (toward it): yaw +theta leans that
-- normal toward +X (the viewer's right), pitch +phi leans it down.
local function facePlacement(card): (Vector3, CFrame)
	local slot = slotCenterFraction(card)
	local pose = card.pose
	local x = (slot.X - 0.5) * 2 * metrics.halfWidth + pose.x.Value * metrics.faceWidth
	local y = (0.5 - slot.Y) * 2 * metrics.halfHeight - pose.y.Value * metrics.faceHeight
	local z = -(STAGE_DISTANCE - pose.depth.Value)
	local rotation = CFrame.Angles(0, math.rad(pose.yaw.Value + card.tiltYaw), 0)
		* CFrame.Angles(math.rad(pose.pitch.Value + card.tiltPitch), 0, 0)
		* CFrame.Angles(0, 0, math.rad(pose.roll.Value))
	return Vector3.new(x, y, z), rotation
end

-- The face centre's offset from the part's centre, in the part's frame:
-- the gui's left portion is the part's +X side (header).
local function faceOffsetInPart(): Vector3
	local partWidth = PART_WIDTH * metrics.faceWidth
	return Vector3.new(partWidth / 2 - (FACE_LEFT + 0.5) * metrics.faceWidth, 0, 0)
end

-- PLACEMENT: every part's CFrame from a camera CFrame and the current
-- metrics and poses. No sizing, no tilt
-- stepping, no allocations beyond the CFrames themselves: this runs on
-- every camera write in a frame.
local function place(cameraCFrame: CFrame)
	local dim = dimPart
	if dim then
		dim.CFrame = cameraCFrame * CFrame.new(0, 0, -(STAGE_DISTANCE + DIM_BEHIND))
	end
	local partOffset = faceOffsetInPart()
	for _, card in cards do
		local faceCenter, rotation = facePlacement(card)
		-- Pivot at the face centre: the pose rotation, then the half turn
		-- that faces the camera, then the slide that puts the face (not
		-- the part) on the pivot.
		card.part.CFrame = cameraCFrame * CFrame.new(faceCenter) * rotation * FACE_CAMERA * CFrame.new(-partOffset)
	end
end

--[ Per frame ]--

local function stepTilt(card, deltaTime: number)
	local targetYaw, targetPitch = 0, 0
	if card.tilt then
		local center = card:faceCenter()
		local cursor = UserInputService:GetMouseLocation() - GuiService:GetGuiInset()
		local halfW = layout.cardHeight * FACE_ASPECT * metrics.viewport.Y / 2
		local halfH = layout.cardHeight * metrics.viewport.Y / 2
		if halfW > 0 and halfH > 0 then
			local dx = math.clamp((cursor.X - center.X) / halfW, -1, 1)
			local dy = math.clamp((cursor.Y - center.Y) / halfH, -1, 1)
			-- The edge under the cursor leans toward the camera: the normal
			-- turns toward the cursor's side (yaw +theta is toward +X,
			-- pitch +phi is downward; screen y grows downward too).
			targetYaw = dx * TILT_MAX_DEGREES
			targetPitch = dy * TILT_MAX_DEGREES
		end
	end
	local follow = math.min(1, deltaTime * TILT_FOLLOW_RATE)
	card.tiltYaw += (targetYaw - card.tiltYaw) * follow
	card.tiltPitch += (targetPitch - card.tiltPitch) * follow
end

local function step()
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local now = os.clock()
	local deltaTime = now - lastClock
	lastClock = now

	local changed = refreshMetrics(camera)
	if metrics.faceHeight <= 0 then
		return
	end
	local dim = dimPart
	if dim and (changed or dim.Size ~= metrics.dimSize) then
		dim.Size = metrics.dimSize
	end
	for _, card in cards do
		if changed then
			applyMetrics(card)
		end
		if card.part.Parent ~= camera then
			card.part.Parent = camera
		end
		stepTilt(card, deltaTime)
	end
	place(camera.CFrame)
end

-- The camera hook: re-place on every CFrame write so a shake or cutscene
-- that moves the camera after the bind still finds the parts on it, and
-- follow a CurrentCamera swap.
local cameraCFrameConnection: RBXScriptConnection? = nil
local currentCameraConnection: RBXScriptConnection? = nil

local function unhookCameraCFrame()
	if cameraCFrameConnection then
		cameraCFrameConnection:Disconnect()
		cameraCFrameConnection = nil
	end
end

local function hookCameraCFrame()
	unhookCameraCFrame()
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	cameraCFrameConnection = camera:GetPropertyChangedSignal("CFrame"):Connect(function()
		if metrics.faceHeight > 0 then
			place(camera.CFrame)
		end
	end)
end

local function bindRender()
	if renderBound then
		return
	end
	renderBound = true
	lastClock = os.clock()
	RunService:BindToRenderStep(RENDER_BIND_NAME, RENDER_PRIORITY, step)
	hookCameraCFrame()
	currentCameraConnection = workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(hookCameraCFrame)
end

local function unbindRender()
	if not renderBound then
		return
	end
	renderBound = false
	RunService:UnbindFromRenderStep(RENDER_BIND_NAME)
	unhookCameraCFrame()
	if currentCameraConnection then
		currentCameraConnection:Disconnect()
		currentCameraConnection = nil
	end
end

-- The per-frame bind runs while anything is on the stage: a card or the
-- dim plane.
local function unbindRenderIfIdle()
	if next(cards) == nil and dimPart == nil then
		unbindRender()
	end
end

--[ Cards ]--

local function makeSurfaceGui(name: string, face: Enum.NormalId, part: Part): SurfaceGui
	local gui = Instance.new("SurfaceGui")
	gui.Name = name
	gui.Face = face
	gui.AlwaysOnTop = true
	gui.ResetOnSpawn = false
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = metrics.pixelsPerStud
	gui.LightInfluence = 0
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Adornee = part
	gui.Parent = localPlayer:WaitForChild("PlayerGui")
	return gui
end

local CardStage = {}

CardStage.FACE_ASPECT = FACE_ASPECT
CardStage.PART_WIDTH = PART_WIDTH
CardStage.PART_HEIGHT = PART_HEIGHT
CardStage.FACE_LEFT = FACE_LEFT
CardStage.FACE_TOP = FACE_TOP
CardStage.STAGE_DISTANCE = STAGE_DISTANCE

-- The hand's layout (the Container's platform card height, row y, gap).
-- Applies to every live card on the next frame.
function CardStage.setLayout(newLayout: Layout)
	layout = newLayout
end

-- A new part + its two guis. `index` / `count` place it in the hand; the
-- pose starts at rest (on its slot, face up).
function CardStage.create(name: string, index: number, count: number): Card
	local part = Instance.new("Part")
	part.Name = "RelicOfferCard_" .. name
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	-- Out of every raycast (the mouse ray and the occlusion rays start at
	-- the camera, right where this part sits). SurfaceGui input does not
	-- go through spatial queries, so the ImageButton keeps its clicks.
	part.CanQuery = false
	part.CastShadow = false
	part.Transparency = 1
	part.Size = Vector3.new(1, 1, PART_THICKNESS)
	-- Parked far off until the first step places it, so nothing flashes
	-- at the origin.
	part.CFrame = CFrame.new(0, -10000, 0)
	part.Parent = workspace.CurrentCamera

	local frontGui = makeSurfaceGui("RelicOfferCardFront_" .. name, Enum.NormalId.Front, part)
	local backGui = makeSurfaceGui("RelicOfferCardBack_" .. name, Enum.NormalId.Back, part)

	local function value(initial: number): NumberValue
		local v = Instance.new("NumberValue")
		v.Value = initial
		return v
	end

	local yawValue = value(0)
	local card = {
		part = part,
		frontGui = frontGui,
		backGui = backGui,
		yawValue = yawValue,
		index = index,
		count = math.max(count, 1),
		pose = {
			x = value(0),
			y = value(0),
			depth = value(0),
			yaw = yawValue,
			pitch = value(0),
			roll = value(0),
		},
		tilt = false,
		tiltYaw = 0,
		tiltPitch = 0,
		alive = true,
	}

	function card.setSlot(self, newIndex: number, newCount: number)
		self.index = newIndex
		self.count = math.max(newCount, 1)
	end

	function card.setPose(self, pose: Pose)
		for field, target in pose :: { [string]: number } do
			local v = self.pose[field]
			if v then
				v.Value = target
			end
		end
	end

	-- Tweens every field given; returns the first tween made (all share
	-- `info`, so its Completed is the pose's).
	function card.tweenPose(self, pose: Pose, info: TweenInfo): Tween?
		local first: Tween? = nil
		for field, target in pose :: { [string]: number } do
			local v = self.pose[field]
			if v then
				local tween = TweenService:Create(v, info, { Value = target })
				tween:Play()
				first = first or tween
			end
		end
		return first
	end

	function card.setTilt(self, on: boolean)
		self.tilt = on
	end

	-- The face centre on screen (viewport space, inset excluded), tilt
	-- ignored.
	function card.faceCenter(self): Vector2
		local camera = workspace.CurrentCamera
		if not camera or metrics.faceHeight <= 0 then
			return Vector2.zero
		end
		local faceCenter = facePlacement(self)
		local world = camera.CFrame:PointToWorldSpace(faceCenter)
		local projected = camera:WorldToViewportPoint(world)
		return Vector2.new(projected.X, projected.Y)
	end

	-- Whether a screen point (inset-adjusted) lies on the face, as if the
	-- face were flat on the screen at its current depth.
	function card.containsPoint(self, point: Vector2): boolean
		if metrics.faceHeight <= 0 then
			return false
		end
		local center = self:faceCenter()
		local depth = STAGE_DISTANCE - self.pose.depth.Value
		if depth <= 0 then
			return false
		end
		local magnify = STAGE_DISTANCE / depth
		local halfW = layout.cardHeight * FACE_ASPECT * metrics.viewport.Y / 2 * magnify
		local halfH = layout.cardHeight * metrics.viewport.Y / 2 * magnify
		return math.abs(point.X - center.X) <= halfW and math.abs(point.Y - center.Y) <= halfH
	end

	function card.destroy(self)
		if not self.alive then
			return
		end
		self.alive = false
		cards[self] = nil
		for _, v in self.pose do
			v:Destroy()
		end
		self.frontGui:Destroy()
		self.backGui:Destroy()
		self.part:Destroy()
		unbindRenderIfIdle()
	end

	cards[card] = card
	bindRender()
	-- Sized now when the camera is already known, so the first frame's
	-- gui layout is right; the step re-checks every frame anyway.
	local camera = workspace.CurrentCamera
	if camera then
		refreshMetrics(camera)
		if metrics.faceHeight > 0 then
			applyMetrics(card)
		end
	end
	return (card :: any) :: Card
end

--[ Dim ]--

-- The dim plane in or out (see the header). `info` defaults to
-- DIM_DEFAULT_TWEEN. On: the part is made if needed and fades to
-- DIM_TRANSPARENCY. Off: it fades clear and is destroyed when the fade
-- lands, unless a new setDim(true) has overtaken it.
function CardStage.setDim(on: boolean, info: TweenInfo?)
	dimGeneration += 1
	local generation = dimGeneration
	local tweenInfo = info or DIM_DEFAULT_TWEEN

	if on then
		local part = dimPart
		if not part then
			part = Instance.new("Part")
			part.Name = "RelicOfferDim"
			part.Anchored = true
			part.CanCollide = false
			part.CanTouch = false
			part.CanQuery = false
			part.CastShadow = false
			part.Material = Enum.Material.SmoothPlastic
			part.Color = Color3.fromRGB(0, 0, 0)
			part.Transparency = 1
			part.Size = Vector3.new(1, 1, PART_THICKNESS)
			part.CFrame = CFrame.new(0, -10000, 0)
			part.Parent = workspace.CurrentCamera
			dimPart = part
			-- Placed now so the first frame of the fade is already in front
			-- of the camera.
			local camera = workspace.CurrentCamera
			if camera then
				refreshMetrics(camera)
				if metrics.faceHeight > 0 then
					part.Size = metrics.dimSize
					part.CFrame = camera.CFrame * CFrame.new(0, 0, -(STAGE_DISTANCE + DIM_BEHIND))
				end
			end
			bindRender()
		end
		TweenService:Create(part, tweenInfo, { Transparency = DIM_TRANSPARENCY }):Play()
		return
	end

	local part = dimPart
	if not part then
		return
	end
	local fade = TweenService:Create(part, tweenInfo, { Transparency = 1 })
	fade.Completed:Once(function()
		if generation ~= dimGeneration or dimPart ~= part then
			return
		end
		dimPart = nil
		part:Destroy()
		unbindRenderIfIdle()
	end)
	fade:Play()
end

-- The dim plane gone on the spot (unmount).
function CardStage.destroyDim()
	dimGeneration += 1
	local part = dimPart
	if part then
		dimPart = nil
		part:Destroy()
	end
	unbindRenderIfIdle()
end

--[ CardSurface ]--

-- The React side of one card: portals `children` (the OfferCard tree) into
-- the card's FRONT gui and `back` (the card's own back, sized to the
-- face) into its BACK gui. The children are laid out by the OfferCard
-- against the whole gui, which is the whole part; FACE_LEFT / FACE_TOP /
-- PART_WIDTH / PART_HEIGHT say where the face is in it.
--
-- Props:
--   card      the Card from CardStage.create
--   back      the element drawn over the face's rectangle on the back
--   children  the front tree
function CardStage.CardSurface(props: any)
	local card = props.card
	return React.createElement(React.Fragment, nil, {
		Front = ReactRoblox.createPortal(props.children, card.frontGui),
		Back = ReactRoblox.createPortal(
			React.createElement("Frame", {
				-- The FACE's rectangle, mirrored across the part: seen from
				-- behind, the face is on the viewer's RIGHT. Roblox already
				-- lays a Back-face gui out to read correctly from behind,
				-- so the back goes in plain.
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(1 - (FACE_LEFT + 0.5) / PART_WIDTH, 0.5),
				Size = UDim2.fromScale(1 / PART_WIDTH, 1 / PART_HEIGHT),
				BackgroundTransparency = 1,
			}, {
				Back = props.back,
			}),
			card.backGui
		),
	})
end

return CardStage
