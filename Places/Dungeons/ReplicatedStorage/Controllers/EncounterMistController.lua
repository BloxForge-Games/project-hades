--!strict
--[[
	Module: Controllers/EncounterMistController.lua
	Description:
	The mist over every miniboss / boss fight (2026-11-06).

	  * ON at the intro's fade to black (EncounterIntroFade "in", once the
	    screen is fully black): the Atmosphere switches to MIST_LOOK in one
	    go, unseen, the camera's zoom->haze range to MIST_DENSITY_RANGE
	    (IsometricCameraController.SetAtmosphereDensityRange: the camera
	    eases Density with zoom every frame, so zooming still thickens and
	    thins the mist), and every visible Highlight outline to
	    OUTLINE_TRANSPARENCY.
	  * OFF when the boss dies (the outro, EncounterDataChanged nil, or its
	    0 HP flush): all of it tweens back to the room's own over FADE_OUT.
	    (Roblox steps a tweened Atmosphere colour; accepted, 2026-11-06.)

	An outline another system changes mid-fight (a dodge flash, a death
	fade) is left to it; one shown during the fight (a new mob, a re-shown
	outline) joins on the next sweep. Each goes back to its own value.
]]

--[ Roblox Services ]--

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

--[ Imports ]--

local DungeonNetwork = require(ReplicatedStorage.Submodules.Core.Source.Network.Dungeon)
local IsometricCameraController =
	require(ReplicatedStorage.Submodules.Core.Source.Controllers.IsometricCameraController)

--[ Constants ]--

type Look = { Color: Color3, Decay: Color3, Glare: number, Offset: number }
type DensityRange = { zoomedOut: number, zoomedIn: number, paused: number }

-- The mist's Atmosphere (authored in Studio, 2026-11-06). Haze is left as
-- the room has it; Density is the camera's (MIST_DENSITY_RANGE).
local MIST_LOOK: Look = {
	Color = Color3.fromRGB(69, 102, 102),
	Decay = Color3.fromRGB(74, 74, 74),
	Glare = 0.79,
	-- 0.207 -> 1 (2026-11-08).
	Offset = 1,
}
-- The authored 0.664 fully zoomed out, thickening by the default range's
-- 0.1 zoomed in, and 0.1 more in a cutscene close-up.
local MIST_DENSITY_RANGE: DensityRange = { zoomedOut = 0.664, zoomedIn = 0.764, paused = 0.864 }

-- Back to the room's own look once the boss is beaten.
local FADE_OUT = TweenInfo.new(2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)

-- Highlight outlines sink to this transparency in the mist.
local OUTLINE_TRANSPARENCY = 0.5
-- How often the mist looks for outlines shown since it came in.
local OUTLINE_SWEEP_SECONDS = 0.5
-- An outline whose value is not the one this last wrote has another owner.
local OUTLINE_EPSILON = 0.001

--[ Module ]--

local EncounterMistController = {
	Name = "EncounterMistController",
	Dependencies = { IsometricCameraController } :: { any },
	-- The mist is in (false as soon as its fade out starts).
	_on = false,
	-- 1 in the mist, eased to 0 on the way out: the density range and the
	-- outlines read it. Made in Start.
	_blend = nil :: NumberValue?,
	_tweens = {} :: { Tween },
	-- The room's own look, read as the mist comes in.
	_clearLook = nil :: Look?,
	-- The outlines being faded: their own transparency and the value this
	-- last wrote (weak: a destroyed Highlight just drops out).
	_outlines = (setmetatable({}, { __mode = "k" }) :: any) :: { [Highlight]: { original: number, written: number } },
	_sweepRunning = false,
	-- The latest intro fade (an older one's delayed switch is dropped).
	_fadeToken = 0,
}

--[ Private ]--

local function atmosphere(): Atmosphere?
	return Lighting:FindFirstChildOfClass("Atmosphere")
end

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

function EncounterMistController._blendValue(self: typeof(EncounterMistController)): number
	local blend = self._blend
	return if blend then blend.Value else 0
end

-- Takes on every visible outline in the world not already faded.
function EncounterMistController._collectOutlines(self: typeof(EncounterMistController))
	for _, descendant in workspace:GetDescendants() do
		if descendant:IsA("Highlight") and self._outlines[descendant] == nil then
			local original = descendant.OutlineTransparency
			if original < OUTLINE_TRANSPARENCY then
				self._outlines[descendant] = { original = original, written = original }
			end
		end
	end
end

-- The density range and the outlines at the blend.
function EncounterMistController._applyBlend(self: typeof(EncounterMistController))
	local t = self:_blendValue()
	for highlight, entry in self._outlines do
		if math.abs(highlight.OutlineTransparency - entry.written) > OUTLINE_EPSILON then
			self._outlines[highlight] = nil
			continue
		end
		highlight.OutlineTransparency = lerp(entry.original, OUTLINE_TRANSPARENCY, t)
		entry.written = highlight.OutlineTransparency
	end
	if t <= 0 then
		IsometricCameraController:SetAtmosphereDensityRange(nil)
		return
	end
	local default = IsometricCameraController:GetDefaultAtmosphereDensityRange()
	IsometricCameraController:SetAtmosphereDensityRange({
		zoomedOut = lerp(default.zoomedOut, MIST_DENSITY_RANGE.zoomedOut, t),
		zoomedIn = lerp(default.zoomedIn, MIST_DENSITY_RANGE.zoomedIn, t),
		paused = lerp(default.paused, MIST_DENSITY_RANGE.paused, t),
	})
end

-- While the mist is in, outlines shown since join it.
function EncounterMistController._startOutlineSweep(self: typeof(EncounterMistController))
	if self._sweepRunning then
		return
	end
	self._sweepRunning = true
	task.spawn(function()
		while self._on do
			self:_collectOutlines()
			self:_applyBlend()
			task.wait(OUTLINE_SWEEP_SECONDS)
		end
		self._sweepRunning = false
	end)
end

function EncounterMistController._cancelTweens(self: typeof(EncounterMistController))
	for _, tween in self._tweens do
		tween:Cancel()
	end
	table.clear(self._tweens)
end

-- The mist in, all at once (the screen is black).
function EncounterMistController._mistOn(self: typeof(EncounterMistController))
	if self._on then
		return
	end
	self._on = true
	self:_cancelTweens()
	local current = atmosphere()
	if current then
		if self._clearLook == nil then
			self._clearLook = {
				Color = current.Color,
				Decay = current.Decay,
				Glare = current.Glare,
				Offset = current.Offset,
			}
		end
		current.Color = MIST_LOOK.Color
		current.Decay = MIST_LOOK.Decay
		current.Glare = MIST_LOOK.Glare
		current.Offset = MIST_LOOK.Offset
	end
	self:_collectOutlines()
	local blend = self._blend
	if blend then
		blend.Value = 1
	end
	self:_applyBlend()
	self:_startOutlineSweep()
end

-- The mist out, tweened back to the room's own over FADE_OUT.
function EncounterMistController._mistOff(self: typeof(EncounterMistController))
	if not self._on then
		return
	end
	self._on = false
	self:_cancelTweens()
	local current = atmosphere()
	local clear = self._clearLook
	if current and clear then
		local tween = TweenService:Create(current, FADE_OUT, clear :: any)
		table.insert(self._tweens, tween)
		tween:Play()
	end
	local blend = self._blend
	if blend then
		local tween = TweenService:Create(blend, FADE_OUT, { Value = 0 })
		table.insert(self._tweens, tween)
		tween.Completed:Connect(function(state)
			if state == Enum.PlaybackState.Completed then
				self._clearLook = nil
				-- Back at their own values (the last step wrote them).
				table.clear(self._outlines)
			end
		end)
		tween:Play()
	end
end

--[ Public ]--

-- The mist is in (a miniboss / boss fight; false once its fade out starts).
function EncounterMistController.IsOn(self: typeof(EncounterMistController)): boolean
	return self._on
end

--[ Lifecycle ]--

function EncounterMistController.Start(self: typeof(EncounterMistController))
	local blend = Instance.new("NumberValue")
	blend.Name = "EncounterMistBlend"
	self._blend = blend
	blend.Changed:Connect(function()
		self:_applyBlend()
	end)

	-- The transition into the boss room: once the screen is black, the
	-- mist is in.
	DungeonNetwork.EncounterIntroFade.On(function(payload)
		if not payload or payload.Phase ~= "in" then
			return
		end
		self._fadeToken += 1
		local token = self._fadeToken
		task.delay(tonumber(payload.Duration) or 0, function()
			if token == self._fadeToken then
				self:_mistOn()
			end
		end)
	end)
	-- The boss is beaten: the outro, or the fight's data cleared (nil, or
	-- the health stream's 0 HP flush that lands just after it).
	DungeonNetwork.EncounterOutroStart.On(function()
		self:_mistOff()
	end)
	DungeonNetwork.EncounterDataChanged.On(function(payload)
		if payload == nil or (tonumber(payload.currentHP) or 1) <= 0 then
			self:_mistOff()
		end
	end)
	-- Joined (or reloaded) mid-fight: the encounter already up.
	task.spawn(function()
		local ok, payload = pcall(DungeonNetwork.GetEncounterData.Invoke)
		if ok and payload ~= nil and (tonumber(payload.currentHP) or 1) > 0 then
			self:_mistOn()
		end
	end)
end

return EncounterMistController
