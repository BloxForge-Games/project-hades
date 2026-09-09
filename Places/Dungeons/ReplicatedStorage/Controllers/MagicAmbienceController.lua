--[[
	Module: MagicAmbienceController.lua
	Description:
	The single owner of the three SCREEN-WIDE effects big magic wants, none
	of which can exist twice at once:

	  * the colour grade (Lighting.ColorCorrection.TintColor -- one global
	    property),
	  * the music takeover (Sukuna's theme replacing the dungeon theme),
	  * the ambient camera shake.

	WHY THIS EXISTS: each effect used to be written straight from the VFX
	script that wanted it, so two casts fought over one property. Two Domain
	Expansions and the FIRST to end restored the tint, stopped the music and
	let the shake die while the second was still running; a Susanoo cast
	during a domain repainted the screen purple and handed it back to the
	authored grade rather than to the domain. Everything here is CLAIMED
	instead of written: N claims produce ONE effect, and it lifts when the
	LAST claim is released.

	TWO KINDS OF CLAIM:
	  * `Claim(id, config)` / `Release(id)` -- unconditional, for effects
	    with no position (Susanoo's tint: it is on your own character).
	  * `ClaimAtPosition(id, config, getPosition, radius)` -- PROXIMITY.
	    The claim only counts while the local character is within `radius`
	    of the position, re-checked POLL_SECONDS apart, so walking out of a
	    domain lifts its effects and walking into another picks them up
	    with no seam. Used by Domain Expansion.

	FIRST CLAIM HOLDS (per design): a second claim never repaints a tint the
	first one owns, and never restarts music that is already playing. The
	effect belongs to whoever grabbed it until they let go, at which point
	the next claim in line takes over.
]]

--[ Roblox Services ]--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")

--[ Imports ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local ColorCorrectionDefaults = require(ReplicatedStorage.Submodules.Core.Shared.Data.ColorCorrectionDefaults)

local CameraShakeController
local MusicController

--[ Constants ]--

-- Proximity re-check cadence. Four times a second: walking in or out
-- feels immediate once the effects' own fades sit on top, and the check
-- is a handful of distance comparisons.
local POLL_SECONDS = 0.25

-- Release fade, shared by the tint and the music so they lift together.
local RELEASE_FADE_SECONDS = 1
local TINT_TWEEN_INFO = TweenInfo.new(RELEASE_FADE_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- The grade to come home to. Never a literal: see ColorCorrectionDefaults.
local AUTHORED_TINT_COLOR = ColorCorrectionDefaults.TintColor

--[ Controller ]--

local MagicAmbienceController = Knit.CreateController({
	Name = "MagicAmbienceController",

	-- [id] = { config, getPosition?, radius?, inRange } for every live
	-- claim, in `_order` so "first claim" is well defined.
	_claims = {},
	_order = {},
	-- The claim id currently DRIVING each channel, or nil when idle.
	_tintOwner = nil,
	_musicOwner = nil,
	_shakeOwner = nil,
})

--[ Private ]--

-- Claims that currently count: unconditional ones always, proximity ones
-- only while the viewer is inside their radius. In claim order.
function MagicAmbienceController:_activeClaims(): { string }
	local active = {}
	for _, id in self._order do
		local claim = self._claims[id]
		if claim and (claim.getPosition == nil or claim.inRange) then
			table.insert(active, id)
		end
	end
	return active
end

-- The first active claim asking for `channel`, or nil.
function MagicAmbienceController:_ownerFor(channel: string): string?
	for _, id in self:_activeClaims() do
		if self._claims[id].config[channel] ~= nil then
			return id
		end
	end
	return nil
end

function MagicAmbienceController:_applyTint(ownerId: string?)
	if ownerId == self._tintOwner then
		return
	end
	self._tintOwner = ownerId
	local target = if ownerId then self._claims[ownerId].config.tint else AUTHORED_TINT_COLOR
	TweenService:Create(Lighting.ColorCorrection, TINT_TWEEN_INFO, { TintColor = target }):Play()
end

function MagicAmbienceController:_applyMusic(ownerId: string?)
	if ownerId == self._musicOwner then
		return
	end

	-- Stop the outgoing takeover before starting any incoming one, so two
	-- overlapping domains hand the theme over rather than layering it.
	if self._musicOwner then
		local previous = self._claims[self._musicOwner]
		local sound = previous and previous.musicSound
		if sound then
			local fade = TweenService:Create(sound, TweenInfo.new(RELEASE_FADE_SECONDS), { Volume = 0 })
			fade.Completed:Once(function()
				sound:Destroy()
			end)
			fade:Play()
			previous.musicSound = nil
		end
	end

	self._musicOwner = ownerId

	if not ownerId then
		-- The dungeon's own theme comes back up.
		if MusicController then
			MusicController:SetTakeoverMuted(false, RELEASE_FADE_SECONDS)
		end
		return
	end

	local claim = self._claims[ownerId]
	local config = claim.config.music
	local template = ReplicatedStorage.GameAssets.Sounds:FindFirstChild(config.soundName)
	if not template then
		warn("[MagicAmbienceController] No sound named " .. tostring(config.soundName))
		return
	end

	-- The dungeon theme goes SILENT under it rather than playing through
	-- underneath: a takeover is meant to be the only thing you hear.
	if MusicController then
		MusicController:SetTakeoverMuted(true, RELEASE_FADE_SECONDS)
	end

	-- A CLONE per takeover: the shared template was played and stopped by
	-- every cast at once, which is how one domain ending silenced another.
	local sound = template:Clone()
	sound.Name = config.soundName .. "_Takeover"
	sound.Volume = 0
	sound.Looped = true
	sound.Parent = workspace.IgnoreInstances.MagicSpells
	sound:Play()
	if config.startTime then
		sound.TimePosition = config.startTime
	end
	TweenService:Create(sound, TweenInfo.new(RELEASE_FADE_SECONDS), { Volume = config.volume or 0.1 }):Play()
	claim.musicSound = sound
end

-- The shake channel is a CameraShakePresets name. The preset system has
-- no stop call, so a held claim re-arms it every poll (see _refresh);
-- re-arming the same preset EXTENDS it rather than restarting, keeping
-- the oscillation and the fade envelope continuous, and it decays over
-- the preset's own fade-out once nobody re-arms it.
function MagicAmbienceController:_applyShake(ownerId: string?)
	if ownerId == self._shakeOwner then
		return
	end
	self._shakeOwner = ownerId
	if not ownerId or not CameraShakeController then
		return
	end
	CameraShakeController:Shake(self._claims[ownerId].config.shake)
end

-- Recomputes every channel from the current claims. Cheap and total:
-- called on claim, on release, and on every poll.
function MagicAmbienceController:_refresh()
	self:_applyTint(self:_ownerFor("tint"))
	self:_applyMusic(self:_ownerFor("music"))

	local shakeOwner = self:_ownerFor("shake")
	self:_applyShake(shakeOwner)
	-- Re-arm while the claim holds: the preset's duration is deliberately
	-- shorter than a domain, so it bleeds off on its own the moment nobody
	-- holds it.
	if shakeOwner and CameraShakeController then
		CameraShakeController:Shake(self._claims[shakeOwner].config.shake)
	end
end

function MagicAmbienceController:_viewerPosition(): Vector3?
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return root and (root :: BasePart).Position or nil
end

--[ Public ]--

-- Claims one or more channels under `id`. `config` may carry:
--   tint  = Color3
--   music = { soundName = string, volume = number?, startTime = number? }
--   shake = a CameraShakePresets name, held while the claim holds
-- Re-claiming a live id replaces its config.
function MagicAmbienceController:Claim(id: string, config: { [string]: any })
	if not self._claims[id] then
		table.insert(self._order, id)
	end
	self._claims[id] = { config = config, inRange = true }
	self:_refresh()
end

-- A claim that only counts while the viewer is within `radius` studs of
-- `getPosition()`. `getPosition` returning nil (the shrine was destroyed)
-- reads as out of range.
function MagicAmbienceController:ClaimAtPosition(
	id: string,
	config: { [string]: any },
	getPosition: () -> Vector3?,
	radius: number
)
	if not self._claims[id] then
		table.insert(self._order, id)
	end
	self._claims[id] = { config = config, getPosition = getPosition, radius = radius, inRange = false }
	self:_poll()
end

function MagicAmbienceController:Release(id: string)
	local claim = self._claims[id]
	if not claim then
		return
	end

	-- ORDER MATTERS. The music teardown reads the playing sound off the
	-- claim, so the channel is handed over BEFORE the claim is forgotten.
	-- Clearing the table first left _applyMusic looking up a claim that no
	-- longer existed, finding no sound, and leaving the takeover playing
	-- with nobody left who could stop it -- the theme that kept going after
	-- a domain you had just walked back into ended.
	if self._musicOwner == id then
		self:_applyMusic(nil)
	end
	-- A claim that never became the owner can still hold a sound (it was
	-- started, then out-ranked or walked out of before this release).
	if claim.musicSound then
		claim.musicSound:Destroy()
		claim.musicSound = nil
	end

	self._claims[id] = nil
	local index = table.find(self._order, id)
	if index then
		table.remove(self._order, index)
	end
	self:_refresh()
end

--[ Lifecycle ]--

function MagicAmbienceController:_poll()
	local viewer = self:_viewerPosition()
	local changed = false
	for _, id in self._order do
		local claim = self._claims[id]
		if claim and claim.getPosition then
			local position = claim.getPosition()
			local inRange = viewer ~= nil and position ~= nil and (viewer - position).Magnitude <= claim.radius
			if inRange ~= claim.inRange then
				claim.inRange = inRange
				changed = true
			end
		end
	end
	-- A held shake claim needs a refresh every poll even when nothing
	-- changed: the shake is re-armed rather than stopped, so it decays the
	-- moment nobody re-arms it.
	if changed or self._shakeOwner then
		self:_refresh()
	end
end

function MagicAmbienceController:KnitInit() end

function MagicAmbienceController:KnitStart()
	CameraShakeController = Knit.GetController("CameraShakeController")
	MusicController = Knit.GetController("MusicController")

	local accumulated = 0
	RunService.Heartbeat:Connect(function(deltaTime: number)
		accumulated += deltaTime
		if accumulated < POLL_SECONDS then
			return
		end
		accumulated = 0
		if next(self._claims) ~= nil then
			self:_poll()
		end
	end)
end

return MagicAmbienceController
