--!strict
--[[
	Module: Controllers/RelicTriggerController.lua
	Description:
	The RelicTrigger glow (2026-11-04, Shared/Data/RelicTriggerData): on
	every player's weapon in hand, ONE RelicTrigger while any every-Nth
	relic's NEXT swing or shot sets it off. Its stars take the ready
	relics' element colours: with several ready (one colour per element),
	the stars CYCLE through them, CYCLE_SECONDS each. The server says which relics are ready (the character's
	Attributes.RelicTriggersReady); this draws them on the weapon named by
	the character's EquippedWeapon, for the relics of that weapon's lane
	only. Putting the weapon away (EquippedWeapon changes) hides the glow
	at once; the count is kept, so drawing that weapon again brings the
	glow straight back (2026-11-04).

	WHERE ON THE WEAPON. Every Attachment named "RelicTriggerAttachment" in
	the weapon model, when it has any; else a gun's muzzle (MuzzleAttachment,
	else OriginAttachment); else, for melee, one glow per Handle (both
	daggers of a pair) at BLADE_FRACTION of the way from the grip to the
	blade's tip, or per weapon (an axe's head) in BLADE_FRACTION_BY_WEAPON
	(2026-11-04; at the Handle's centre, near the hilt, before).

	THE SOUND (2026-11-04). SOUND_ID plays on the weapon whenever the glow
	appears: a relic becomes ready, or the weapon is drawn again with one
	ready. A relic joining a glow already showing plays it again; a redraw
	of the same relics (the weapon model re-made) does not. While the glow
	shows, LOOP_SOUND_ID (a wind) loops on the glow itself as a proximity
	sound, and stops with it: the charge used, the weapon put away.

	The asset is place-side: ReplicatedStorage.GameAssets.VFX.RelicTrigger,
	a Model whose Part carries the emitters; every emitter named "Star" is
	recoloured, the rest (the grey wind) keep their colour.

	A Blitz module with no dependencies.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local RelicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicData)
local RelicTriggerData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicTriggerData)
local getWeaponCategory = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Inventory.getWeaponCategory)
local GameClock = require(ReplicatedStorage.Submodules.Core.Shared.GameClock)

local TEMPLATE_NAME = "RelicTrigger"
local SOUND_ID = "rbxassetid://93989620006639"
local SOUND_VOLUME = 0.5
-- The wind looped on the glow (one per weapon, on the first glow), heard
-- within LOOP_MAX_DISTANCE studs, at full volume inside LOOP_MIN_DISTANCE.
local LOOP_SOUND_ID = "rbxassetid://128646536104501"
local LOOP_VOLUME = 0.4
local LOOP_MIN_DISTANCE = 6
local LOOP_MAX_DISTANCE = 100
local STAR_EMITTER_NAME = "Star"
local ANCHOR_ATTACHMENT_NAME = "RelicTriggerAttachment"
-- Several ready elements: seconds to blend from one colour into the next
-- (0.6 since 2026-11-04; a hard switch every 0.25 s before).
local CYCLE_SECONDS = 0.6
-- A gun's barrel tip first, then where its bullets leave.
local MUZZLE_ATTACHMENT_NAMES = { "MuzzleAttachment", "OriginAttachment" }

local RelicTriggerController = {
	Name = "RelicTriggerController",
}

-- The glow parts drawn on each character right now.
local drawn: { [Model]: { BasePart } } = {}
-- The ready relics each character's glow showed at the last refresh.
local shown: { [Model]: { [string]: boolean } } = {}

local function template(): BasePart?
	local gameAssets = ReplicatedStorage:FindFirstChild("GameAssets")
	local vfx = gameAssets and gameAssets:FindFirstChild("VFX")
	local model = vfx and vfx:FindFirstChild(TEMPLATE_NAME)
	if not model then
		return nil
	end
	if model:IsA("BasePart") then
		return model
	end
	local part = if model:IsA("Model") then model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart") else nil
	return part
end

local function effectParent(): Instance
	local ignore = workspace:FindFirstChild("IgnoreInstances")
	return (ignore and ignore:FindFirstChild("ArcaneSpells")) or ignore or workspace
end

type Anchor = { part: BasePart, offset: CFrame }

-- Where along a melee blade the glow sits: 0 at the grip, 1 at the far
-- tip of the visible model. Mid-blade by default (the guard sits near the
-- grip, so 0.55 lands on the middle of the blade itself); per weapon by
-- name where the business end is elsewhere (an axe's head).
local BLADE_FRACTION = 0.55
local BLADE_FRACTION_BY_WEAPON: { [string]: number } = {
	["Stormforge Breaker"] = 0.85,
}

-- The grip point on a melee Handle, in the Handle's space: its
-- Right/LeftGripAttachment, else the joint holding it to the hand.
local function gripPointOf(handle: BasePart): Vector3?
	for _, child in handle:GetChildren() do
		if child:IsA("Attachment") and string.find(child.Name, "GripAttachment$") then
			return child.Position
		end
	end
	for _, child in handle:GetChildren() do
		if
			child:IsA("JointInstance")
			and child.Part1 == handle
			and child.Part0
			and not child.Part0:IsDescendantOf(handle.Parent :: Instance)
		then
			return child.C1.Position
		end
	end
	return nil
end

-- The spot along one melee Handle's blade, in the Handle's space. The
-- blade runs along the Handle's longest axis, toward whichever side the
-- VISIBLE model reaches farther past the grip (the invisible Handle box
-- can sit centred on the grip, as on the daggers, so its own shape does
-- not say which way the blade points); its tip is that farthest reach.
local function bladePointOf(handle: BasePart, model: Instance, fraction: number): CFrame
	local grip = gripPointOf(handle)
	local size = handle.Size
	local axis = if size.X >= size.Y and size.X >= size.Z
		then Vector3.xAxis
		elseif size.Y >= size.Z then Vector3.yAxis
		else Vector3.zAxis
	if grip == nil then
		return CFrame.identity
	end
	local start = grip:Dot(axis)
	-- How far the visible parts reach past the grip along +axis and -axis.
	local plus, minus = 0, 0
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") and descendant ~= handle and descendant.Transparency < 1 then
			local local_ = handle.CFrame:ToObjectSpace(descendant.CFrame)
			local direction = local_:VectorToObjectSpace(axis)
			local half = descendant.Size / 2
			local extent = math.abs(direction.X) * half.X
				+ math.abs(direction.Y) * half.Y
				+ math.abs(direction.Z) * half.Z
			local centre = local_.Position:Dot(axis) - start
			plus = math.max(plus, centre + extent)
			minus = math.max(minus, extent - centre)
		end
	end
	if plus == 0 and minus == 0 then
		-- Nothing visible: the Handle box's far end from the grip.
		local halfLength = size:Dot(Vector3.new(math.abs(axis.X), math.abs(axis.Y), math.abs(axis.Z))) / 2
		plus, minus = halfLength - start, halfLength + start
	end
	local reach = if plus >= minus then plus else -minus
	-- On the Handle's centre line, `fraction` of the way from grip to tip.
	return CFrame.new(axis * (start + reach * fraction))
end

-- The spots on `weapon` the glow sits at (see the header): one per blade,
-- so both daggers of a pair glow.
local function anchorsOf(weapon: Model, isGun: boolean): { Anchor }
	local anchors: { Anchor } = {}
	for _, descendant in weapon:GetDescendants() do
		if descendant.Name == ANCHOR_ATTACHMENT_NAME and descendant:IsA("Attachment") then
			local parent = descendant.Parent
			if parent and parent:IsA("BasePart") then
				table.insert(anchors, { part = parent, offset = descendant.CFrame })
			end
		end
	end
	if #anchors > 0 then
		return anchors
	end
	if isGun then
		for _, name in MUZZLE_ATTACHMENT_NAMES do
			local muzzle = weapon:FindFirstChild(name, true)
			if muzzle and muzzle:IsA("Attachment") and muzzle.Parent and muzzle.Parent:IsA("BasePart") then
				return { { part = muzzle.Parent, offset = muzzle.CFrame } }
			end
		end
	else
		local fraction = BLADE_FRACTION_BY_WEAPON[weapon.Name] or BLADE_FRACTION
		for _, descendant in weapon:GetDescendants() do
			if descendant.Name == "Handle" and descendant:IsA("BasePart") then
				table.insert(anchors, {
					part = descendant,
					offset = bladePointOf(descendant, descendant.Parent :: Instance, fraction),
				})
			end
		end
		if #anchors > 0 then
			return anchors
		end
	end
	local fallback = weapon:FindFirstChild("Handle")
		or weapon.PrimaryPart
		or weapon:FindFirstChildWhichIsA("BasePart", true)
	if fallback and fallback:IsA("BasePart") then
		table.insert(anchors, { part = fallback, offset = CFrame.identity })
	end
	return anchors
end

local function clearGlow(character: Model)
	local parts = drawn[character]
	if parts then
		for _, part in parts do
			part:Destroy()
		end
	end
	drawn[character] = nil
end

-- The ready relics of the drawn weapon's lane, sorted.
local function readyRelicsFor(character: Model, category: string?): { string }
	local list = {}
	local value = character:GetAttribute(Attributes.RelicTriggersReady)
	if type(value) ~= "string" or category == nil then
		return list
	end
	for relicName in string.gmatch(value, "[^,]+") do
		local lane = RelicTriggerData.Lanes[relicName]
		if lane and RelicTriggerData.Categories[lane] == category then
			table.insert(list, relicName)
		end
	end
	table.sort(list)
	return list
end

-- One glow whose stars cycle through `colors` (see the header).
local function makeGlow(source: BasePart, colors: { Color3 }): BasePart
	local part = source:Clone()
	part.Anchored = false
	part.Massless = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	local stars: { ParticleEmitter } = {}
	for _, descendant in part:GetDescendants() do
		if descendant:IsA("ParticleEmitter") and descendant.Name == STAR_EMITTER_NAME then
			table.insert(stars, descendant)
		elseif descendant:IsA("BaseScript") then
			descendant:Destroy()
		end
	end
	local tint = ColorSequence.new(colors[1])
	for _, star in stars do
		star.Color = tint
	end
	-- Several elements: the stars BLEND from one colour into the next every
	-- frame (CYCLE_SECONDS per colour, eased in and out), looping while the
	-- glow lives. The first frame waits for the glow to be parented.
	if #colors > 1 then
		task.spawn(function()
			local startedAt = GameClock.Now()
			RunService.Heartbeat:Wait()
			while part.Parent do
				local position = (GameClock.Now() - startedAt) / CYCLE_SECONDS
				local index = math.floor(position) % #colors + 1
				local alpha = position - math.floor(position)
				local eased = alpha * alpha * (3 - 2 * alpha)
				local blended = ColorSequence.new(colors[index]:Lerp(colors[index % #colors + 1], eased))
				for _, star in stars do
					star.Color = blended
				end
				RunService.Heartbeat:Wait()
			end
		end)
	end
	return part
end

-- The trigger sound on `part`, gone when it ends.
local function playSound(part: BasePart)
	local sound = Instance.new("Sound")
	sound.SoundId = SOUND_ID
	sound.Volume = SOUND_VOLUME
	sound.Parent = part
	sound.Ended:Once(function()
		sound:Destroy()
	end)
	sound:Play()
	GameClock.Debris(sound, 10)
end

function RelicTriggerController._refresh(self: typeof(RelicTriggerController), character: Model)
	local relics, anchor = self:_draw(character)
	local previous = shown[character] or {}
	local now: { [string]: boolean } = {}
	local appeared = false
	for _, relicName in relics do
		now[relicName] = true
		if not previous[relicName] then
			appeared = true
		end
	end
	shown[character] = now
	if appeared and anchor then
		playSound(anchor)
	end
end

-- Draws the glow; returns the relics it shows and the part it sits on
-- (none when nothing is drawn).
function RelicTriggerController._draw(_self: typeof(RelicTriggerController), character: Model): ({ string }, BasePart?)
	clearGlow(character)
	if not character.Parent then
		return {}, nil
	end
	local weaponName = character:GetAttribute(Attributes.EquippedWeapon)
	if type(weaponName) ~= "string" then
		return {}, nil
	end
	local weapon = character:FindFirstChild(weaponName)
	if not weapon or not weapon:IsA("Model") then
		return {}, nil
	end
	local category = getWeaponCategory(weaponName)
	local relics = readyRelicsFor(character, category)
	if #relics == 0 then
		return {}, nil
	end
	local source = template()
	if not source then
		warn("[RelicTriggerController] Missing GameAssets.VFX." .. TEMPLATE_NAME)
		return {}, nil
	end
	local anchors = anchorsOf(weapon, category == RelicTriggerData.Categories.Ranged)
	if #anchors == 0 then
		return {}, nil
	end

	-- One colour per ready ELEMENT (two Blaze relics are one red).
	local colors: { Color3 } = {}
	local seen: { [string]: boolean } = {}
	for _, relicName in relics do
		local row = RelicData[relicName]
		local tree = (row and row.tree) or "Neutral"
		if not seen[tree] then
			seen[tree] = true
			table.insert(colors, RelicTriggerData.Colors[tree] or RelicTriggerData.Colors.Neutral)
		end
	end
	local glows: { BasePart } = {}
	for _, anchor in anchors do
		local glow = makeGlow(source, colors)
		glow.CFrame = anchor.part.CFrame * anchor.offset
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = glow
		weld.Part1 = anchor.part
		weld.Parent = glow
		glow.Parent = effectParent()
		table.insert(glows, glow)
	end
	drawn[character] = glows

	-- The wind loop, on the glow: destroyed with it when the glow clears.
	local loop = Instance.new("Sound")
	loop.Name = "RelicTriggerLoop"
	loop.SoundId = LOOP_SOUND_ID
	loop.Volume = LOOP_VOLUME
	loop.Looped = true
	loop.RollOffMode = Enum.RollOffMode.InverseTapered
	loop.RollOffMinDistance = LOOP_MIN_DISTANCE
	loop.RollOffMaxDistance = LOOP_MAX_DISTANCE
	loop.Parent = glows[1]
	loop:Play()
	return relics, anchors[1].part
end

function RelicTriggerController._watch(self: typeof(RelicTriggerController), character: Model)
	local function refresh()
		self:_refresh(character)
	end
	character:GetAttributeChangedSignal(Attributes.RelicTriggersReady):Connect(refresh)
	character:GetAttributeChangedSignal(Attributes.EquippedWeapon):Connect(refresh)
	-- The in-hand weapon model is re-made on a loadout change, and can
	-- stream in after the attribute names it.
	character.ChildAdded:Connect(function(child: Instance)
		if child.Name == character:GetAttribute(Attributes.EquippedWeapon) then
			refresh()
		end
	end)
	character.AncestryChanged:Connect(function()
		if not character.Parent then
			clearGlow(character)
			shown[character] = nil
		end
	end)
	refresh()
end

function RelicTriggerController.Start(self: typeof(RelicTriggerController))
	local function watchPlayer(player: Player)
		player.CharacterAdded:Connect(function(character: Model)
			self:_watch(character)
		end)
		if player.Character then
			self:_watch(player.Character)
		end
	end
	Players.PlayerAdded:Connect(watchPlayer)
	for _, player in Players:GetPlayers() do
		watchPlayer(player)
	end
end

return RelicTriggerController
