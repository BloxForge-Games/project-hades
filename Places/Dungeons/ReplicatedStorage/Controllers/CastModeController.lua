--[[
	Module: Client/Controllers/CastModeController.lua
	Description:
	Owns the QUICK CAST / NORMAL CAST toggle for magic on keyboard + mouse
	(League-style), and the topbar button that flips it.

	  Quick Cast  (default)  Press the spell key -> fires instantly toward
	                         the cursor. This is the behavior the game
	                         always had; nothing about it changed.
	  Normal Cast            Press the spell key -> the spell's indicator
	                         comes up and STAYS up; the character keeps
	                         turning to follow the mouse (AimController's
	                         usual cursor-follow, so the player angles the
	                         spell by moving the mouse). Releasing the key
	                         does NOTHING -- the aim is armed until the
	                         player commits. LEFT-CLICK the world to fire.
	                         RIGHT-CLICK or ESCAPE cancels with nothing
	                         spent. Pressing the SAME spell key again, or
	                         ANY OTHER spell key / toolbar slot, also
	                         cancels (it does not switch -- press the new
	                         spell again to aim it). Clicking a magic slot
	                         on the toolbar arms it the same way; the next
	                         left-click on the WORLD fires it (a click on UI
	                         is gameProcessed and ignored).

	Blocked spells never enter aim mode: the press runs the exact same
	gates a Quick Cast would (MagicController:CanCastMagic -- mana,
	cooldown, action state) and gives the same feedback up front, so the
	player never aims something that then refuses to fire.

	Mobile: the toggle is HIDDEN and irrelevant -- touch always taps a
	toolbar slot to cast (the existing behavior; the hold-thumbstick flow
	is a separate task). Every entry point here therefore short-circuits
	to a plain cast on mobile.

	Persistence: profile Settings.QuickCast via SettingsService; read back
	from DataController's snapshot. The local flag flips optimistically on
	click so the button and input feel instant.

	The topbar button lives in TopBarInterface (all topbar chrome in one
	place); it calls ToggleQuickCast() and mirrors IsQuickCast() /
	Signals.OnCastModeChanged for its label. This controller owns only the
	STATE and the input behaviour.
]]

--[ Roblox Services ]--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

--[ Imports ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local Signal = require(ReplicatedStorage.Submodules.Core.Packages.Signal)

local MagicController
local PlayerStateController
local InputPlatformController
local DataController
local SettingsService

--[ Constants ]--

-- Default when the profile has no saved preference yet.
local DEFAULT_QUICK_CAST = true

--[ Controller ]--

local CastModeController = Knit.CreateController({
	Name = "CastModeController",
})

CastModeController.Signals = {
	-- Fires (quickCast: boolean) whenever the mode flips.
	OnCastModeChanged = Signal.new(),
}

CastModeController._quickCast = DEFAULT_QUICK_CAST
-- Slot currently being aimed in Normal Cast, or nil.
CastModeController._aimingSlot = nil :: number?
CastModeController._aimWatch = nil :: RBXScriptConnection?

--[ Public: mode ]--

function CastModeController:IsQuickCast(): boolean
	return self._quickCast
end

-- True while a Normal Cast aim is open (indicator up, waiting on release
-- / click). Weapons read this so the firing left-click doesn't ALSO swing.
function CastModeController:IsAiming(): boolean
	return self._aimingSlot ~= nil
end

function CastModeController:SetQuickCast(enabled: boolean)
	if self._quickCast == enabled then
		return
	end
	self._quickCast = enabled

	-- Switching TO Quick Cast mid-aim: the held key would now be a
	-- one-shot, so drop the open aim rather than fire it on release.
	if enabled then
		self:CancelAim()
	end

	self.Signals.OnCastModeChanged:Fire(enabled)

	if SettingsService then
		SettingsService:SetQuickCast(enabled):catch(warn)
	end
end

function CastModeController:ToggleQuickCast()
	self:SetQuickCast(not self._quickCast)
end

--[ Private ]--

-- Normal Cast input only exists on keyboard + mouse.
function CastModeController:_normalCastActive(): boolean
	return not self._quickCast and not InputPlatformController:IsMobilePlatform()
end

-- Indicator show/hide, isolated so a marker/asset mismatch for one spell
-- can never strand aim mode (it warns and the aim proceeds without it).
function CastModeController:_setIndicator(slot: number, visible: boolean)
	local ok, err = pcall(function()
		MagicController:ToggleMobileIndicator(visible, slot)
	end)
	if not ok then
		warn("[CastModeController] indicator toggle failed for slot " .. tostring(slot) .. ": " .. tostring(err))
	end
end

--[ Public: Normal Cast aim ]--

-- Arms `slot` if the spell can fire right now: indicator up immediately and
-- held until a left-click fires it or something cancels it. Any spell input
-- while an aim is already open -- the SAME slot again or a DIFFERENT one --
-- is a cancel, never a switch: the player re-presses the spell they want.
function CastModeController:BeginAim(slot: number)
	if self._aimingSlot ~= nil then
		self:CancelAim()
		return
	end

	-- Same gates + same feedback as a Quick Cast attempt.
	if not MagicController:CanCastMagic(slot) then
		return
	end

	self._aimingSlot = slot
	self:_setIndicator(slot, true)

	self._aimWatch = RunService.Heartbeat:Connect(function()
		-- Anything that would block the cast mid-aim (dodge, death,
		-- dialogue, respawn) drops the aim rather than leaving a stale
		-- indicator.
		local character = Players.LocalPlayer.Character
		if not character or not character.Parent or PlayerStateController:GeneralActionEnabled() == false then
			self:CancelAim()
		end
	end)
end

function CastModeController:_closeAim()
	local slot = self._aimingSlot
	if slot == nil then
		return nil
	end
	self._aimingSlot = nil
	if self._aimWatch then
		self._aimWatch:Disconnect()
		self._aimWatch = nil
	end
	self:_setIndicator(slot, false)
	return slot
end

function CastModeController:CancelAim()
	self:_closeAim()
end

-- Fires the aimed spell. CastMagic re-runs the gates itself, so a spell
-- that became uncastable during the aim is still refused there.
function CastModeController:FireAim()
	local slot = self:_closeAim()
	if slot ~= nil then
		MagicController:CastMagic(slot)
	end
end

--[ Public: input entry points ]--

-- Spell key pressed / released (from UserInputController's 3 / 4 binds).
function CastModeController:OnSpellKey(slot: number, inputState: Enum.UserInputState)
	if not self:_normalCastActive() then
		if inputState == Enum.UserInputState.Begin then
			MagicController:CastMagic(slot)
		end
		return
	end

	-- Press arms (or cancels an open aim -- see BeginAim). RELEASE is
	-- deliberately ignored: the aim stays armed until a left-click fires it
	-- or a right-click / Escape / another spell input cancels it.
	if inputState == Enum.UserInputState.Begin then
		self:BeginAim(slot)
	end
end

-- Toolbar slot clicked. Normal Cast: arms the spell (the click that got us
-- here was on UI, so it can't double as the firing click) -- or cancels an
-- open aim, same as a spell key. The next left-click on the world fires.
-- Otherwise: plain cast, as always.
function CastModeController:OnToolbarSlotClicked(slot: number)
	if self:_normalCastActive() then
		self:BeginAim(slot)
	else
		MagicController:CastMagic(slot)
	end
end

--[ Lifecycle ]--

function CastModeController:_applyProfile(profile: { [string]: any }?)
	local settings = profile and profile.Settings
	local saved = settings and settings.QuickCast
	if typeof(saved) ~= "boolean" then
		return
	end
	if saved ~= self._quickCast then
		self._quickCast = saved
		self.Signals.OnCastModeChanged:Fire(saved)
	end
end

function CastModeController:KnitStart()
	MagicController = Knit.GetController("MagicController")
	PlayerStateController = Knit.GetController("PlayerStateController")
	InputPlatformController = Knit.GetController("InputPlatformController")
	DataController = Knit.GetController("DataController")
	SettingsService = Knit.GetService("SettingsService")

	-- Saved preference: whatever snapshot is already here, then every push
	-- (the join-time snapshot may land after KnitStart).
	self:_applyProfile(DataController:GetProfileData())
	DataController.Signals.OnProfileChanged:Connect(function(profile)
		self:_applyProfile(profile)
	end)

	-- Mobile drops any open aim (the topbar button itself is owned and
	-- platform-gated by TopBarInterface).
	InputPlatformController.OnInputPlatformChanged:Connect(function()
		if InputPlatformController:IsMobilePlatform() then
			self:CancelAim()
		end
	end)

	-- Fire / cancel inputs while aiming. Only WORLD clicks count
	-- (gameProcessedEvent = a click on UI, e.g. the toolbar).
	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessedEvent: boolean)
		if self._aimingSlot == nil or gameProcessedEvent then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			self:FireAim()
		elseif input.UserInputType == Enum.UserInputType.MouseButton2 or input.KeyCode == Enum.KeyCode.Escape then
			self:CancelAim()
		end
	end)
end

function CastModeController:KnitInit() end

return CastModeController
