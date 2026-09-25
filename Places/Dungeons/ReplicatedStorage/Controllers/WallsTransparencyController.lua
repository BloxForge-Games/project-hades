--!strict
--[[
	Module: WallsTransparencyController.lua
	Description:
	Fades whatever sits between the camera and the LOCAL player's head so
	a wall never hides you: the part goes to FADED_PART_TRANSPARENCY (its
	textures and decals to FADED_TEXTURE_TRANSPARENCY) while it occludes,
	and comes back to the transparency it had the first time it was ever
	touched. Map buildings and pillars are BuildingTransparencyController's
	(it fades a whole model as one unit); this handles everything else.

	The occlusion answer comes from OcclusionController's single per-tick
	pass -- this used to be its own Heartbeat query that rebuilt an ignore
	list every frame -- so this controller only owns the fades: it reads
	the parts covering the head on each pass, filters out what it must
	never touch, and fades / restores the difference.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local OcclusionController = require(ReplicatedStorage.Controllers.OcclusionController)

-- Parts of a Building-tagged model (pillars, the static map buildings)
-- belong to BuildingTransparencyController, which fades the WHOLE model
-- to one value and caches the authored look itself. Two owners on one
-- part is how a pillar came apart: this system faded the single block on
-- its ray, then "restored" it to the value it had captured -- opaque --
-- while the pillar system still held every other block at its faded
-- value, so lone blocks popped solid as you moved.
local function isBuildingPart(part: BasePart): boolean
	local ancestor = part.Parent
	while ancestor and ancestor ~= workspace do
		if ancestor:IsA("Model") and ancestor:HasTag(TagList.Building) then
			return true
		end
		ancestor = ancestor.Parent
	end
	return false
end

-- OTHER PLAYERS are never faded. This system exists for walls; when a
-- player steps between the camera and you, your own highlight already
-- keeps you readable. Fading THEM was also actively harmful: the
-- "original" transparency is captured the FIRST time a part is ever
-- touched, and player parts change transparency underneath us (helmets
-- hiding hair, sheathed weapons, hidden accessory handles) -- so a later
-- brief occlusion "restored" a now-hidden part to its stale visible
-- value. The shared pass keeps them as occluders on purpose (that is what
-- lights your highlight behind a teammate), so they are filtered out of
-- the hits here: any part with a player's character among its ancestors.
local function isPlayerPart(part: BasePart): boolean
	local model = part:FindFirstAncestorOfClass("Model")
	while model do
		if Players:GetPlayerFromCharacter(model) then
			return true
		end
		model = model:FindFirstAncestorOfClass("Model")
	end
	return false
end

type Fade = {
	partTween: Tween?,
	textureTweens: { [Instance]: Tween },
	textures: { Texture | Decal },
}

local WallsTransparencyController = {
	Name = "WallsTransparencyController",
	Dependencies = { OcclusionController } :: { any },

	_activeFades = {} :: { [BasePart]: Fade },
	_originalPartTransparencies = {} :: { [BasePart]: number },
	_originalTextureTransparencies = {} :: { [Texture | Decal]: number },
	-- Spell VFX props (the Domain Expansion shrine, IgnoreInstances.Map
	-- .MagicSpells). They animate their OWN transparency, and this
	-- system's capture-once "original" would fight that; per design the
	-- character highlight is enough to keep you readable when you walk
	-- under one -- which is also why they stay OUT of the shared ignore
	-- list (the highlight must still see them) and are skipped here.
	_spellPropsFolder = nil :: Instance?,
}

local FADE_TIME = 0.25
-- The capture-once maps are keyed by wall parts and never released on the
-- restore path (by design), so a floor's destroyed walls must fall out on
-- their own: weak keys.
local WEAK_KEYS = { __mode = "k" }
local FADED_PART_TRANSPARENCY = 0.75
local FADED_TEXTURE_TRANSPARENCY = 0.95

local toggled = true

-- The parts this pass wants faded. One table, cleared per pass, so a tick
-- allocates nothing of its own.
local currentPassParts: { [BasePart]: true } = {}

-- Capture-once. Records the part's true transparency the first time we ever
-- touch it, before any tween starts. Never overwritten by mid-tween reads.
function WallsTransparencyController._rememberOriginal(self: typeof(WallsTransparencyController), part: BasePart)
	if self._originalPartTransparencies[part] == nil then
		self._originalPartTransparencies[part] = part.Transparency
	end
end

function WallsTransparencyController._rememberOriginalTexture(
	self: typeof(WallsTransparencyController),
	obj: Texture | Decal
)
	if self._originalTextureTransparencies[obj] == nil then
		self._originalTextureTransparencies[obj] = obj.Transparency
	end
end

function WallsTransparencyController._fadeOut(self: typeof(WallsTransparencyController), part: BasePart)
	if self._activeFades[part] then
		return
	end

	self:_rememberOriginal(part)

	local fade = {
		partTween = nil :: Tween?,
		textureTweens = {} :: { [Instance]: Tween },
		textures = {} :: { Texture | Decal }, -- list (preserves which descendants we touched)
	}

	local partTween = TweenService:Create(part, TweenInfo.new(FADE_TIME), {
		Transparency = FADED_PART_TRANSPARENCY,
	})
	fade.partTween = partTween
	partTween:Play()

	for _, descendant in part:GetDescendants() do
		if descendant:IsA("Texture") or descendant:IsA("Decal") then
			self:_rememberOriginalTexture(descendant)

			local tween = TweenService:Create(descendant, TweenInfo.new(FADE_TIME), {
				Transparency = FADED_TEXTURE_TRANSPARENCY,
			})
			fade.textureTweens[descendant] = tween
			table.insert(fade.textures, descendant)
			tween:Play()
		end
	end

	self._activeFades[part] = fade
end

function WallsTransparencyController._fadeIn(self: typeof(WallsTransparencyController), part: BasePart)
	local fade = self._activeFades[part]
	if not fade then
		return
	end

	-- Cancel any in-flight fade-out tweens so they don't fight the fade-in.
	if fade.partTween then
		fade.partTween:Cancel()
	end
	for _, tween in fade.textureTweens do
		tween:Cancel()
	end

	local originalPart = self._originalPartTransparencies[part]
	if originalPart ~= nil then
		TweenService:Create(part, TweenInfo.new(FADE_TIME), {
			Transparency = originalPart,
		}):Play()
	end

	for _, descendant in fade.textures do
		if descendant.Parent then
			local original = self._originalTextureTransparencies[descendant]
			if original ~= nil then
				TweenService:Create(descendant, TweenInfo.new(FADE_TIME), {
					Transparency = original,
				}):Play()
			end
		end
	end

	self._activeFades[part] = nil
end

-- Drops a part we are holding WITHOUT restoring it. Used when a part
-- becomes OcclusionFadeIgnore mid-hold: something else (a gate tween)
-- now owns its Transparency, so both our fade tweens and our captured
-- "original" are wrong — the capture-once value may have been read
-- mid-tween, and _fadeIn would restore the part to that garbage. Forget
-- it all; the next time we touch the part, after its tween has settled,
-- we capture its true value fresh.
function WallsTransparencyController._release(self: typeof(WallsTransparencyController), part: BasePart)
	local fade = self._activeFades[part]
	if not fade then
		return
	end

	if fade.partTween then
		fade.partTween:Cancel()
	end
	for _, tween in fade.textureTweens do
		tween:Cancel()
	end

	self._activeFades[part] = nil
	self._originalPartTransparencies[part] = nil
	for _, descendant in fade.textures do
		self._originalTextureTransparencies[descendant] = nil
	end
end

function WallsTransparencyController._isSpellProp(self: typeof(WallsTransparencyController), part: BasePart): boolean
	local folder = self._spellPropsFolder
	return folder ~= nil and part:IsDescendantOf(folder)
end

-- One occlusion pass: fade what covers the head this tick, restore what
-- stopped covering it. The PLAYER only. Walls covering a mob stay solid
-- (per design): the through-wall highlight is the cue for a hidden mob,
-- and fading every wall a mob stood behind opened up too much of the room.
function WallsTransparencyController._onOcclusionPass(self: typeof(WallsTransparencyController))
	if not toggled then
		for part in self._activeFades do
			self:_fadeIn(part)
		end
		return
	end

	table.clear(currentPassParts)
	for _, part in OcclusionController:GetPlayerHeadOccluders() do
		if isPlayerPart(part) or isBuildingPart(part) or self:_isSpellProp(part) then
			continue
		end
		-- A part whose Transparency someone else is driving right now
		-- (a dungeon gate tweening up or down) is not ours to fade.
		if part:GetAttribute(Attributes.OcclusionFadeIgnore) then
			continue
		end
		currentPassParts[part] = true
	end

	for part in currentPassParts do
		self:_fadeOut(part)
	end

	for part in self._activeFades do
		if part:GetAttribute(Attributes.OcclusionFadeIgnore) then
			-- Became someone else's mid-hold: let go, do NOT "restore".
			self:_release(part)
		elseif not currentPassParts[part] then
			self:_fadeIn(part)
		end
	end
end

function WallsTransparencyController.Toggle(_self: typeof(WallsTransparencyController), toggle: boolean)
	toggled = toggle
end

function WallsTransparencyController.Init(self: typeof(WallsTransparencyController))
	self._activeFades = {} -- BasePart -> { partTween, textureTweens, textures }
	self._originalPartTransparencies = setmetatable({}, WEAK_KEYS) :: any -- BasePart -> number (captured once)
	self._originalTextureTransparencies = setmetatable({}, WEAK_KEYS) :: any -- Texture|Decal -> number (captured once)
end

function WallsTransparencyController.Start(self: typeof(WallsTransparencyController))
	local ignoreFolder = workspace:FindFirstChild("IgnoreInstances")
	local map = ignoreFolder and ignoreFolder:FindFirstChild("Map")
	self._spellPropsFolder = map and map:FindFirstChild("MagicSpells")

	-- The fades ride the shared pass, whichever character is alive: the
	-- pass resolves the character itself, so nothing here re-binds on
	-- respawn.
	OcclusionController.OnPass:Connect(function()
		self:_onOcclusionPass()
	end)
end

return WallsTransparencyController
