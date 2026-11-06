--!strict
--[[
	Module: LobbyMusicController.lua
	Description:
	The town theme (2026-11-06): SoundService.MainTheme, a looped Sound
	placed in the Lobby place file (not in git).

	  START   silent through the loading screen; as it fades out
	          (LobbyLandingController.OnRevealed) the theme starts at 0 and
	          fades slowly up to MAX_VOLUME.
	  COVERED whenever something covers the screen -- a window, an NPC
	          conversation, a chest reveal: anything that hides the HUD
	          (InterfaceManagerController's HUD scope) -- it fades down to
	          LOW_VOLUME, and back up to MAX_VOLUME once the screen is clear.

	The landing cutscene hides the HUD too, but it is not "covered": the
	HUD's first reopening after the reveal marks the landing over, and
	only from then does a hidden HUD lower the music.

	The theme is in the Settings window's Music group
	(ClientSettingsController.AssignMusic), so the Music slider scales
	both volumes (2026-11-06).

	Client-only.
]]

--[ Roblox Services ]--

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

--[ Imports ]--

local ClientSettingsController = require(ReplicatedStorage.Submodules.Core.Source.Controllers.ClientSettingsController)
local InterfaceManagerController =
	require(ReplicatedStorage.Submodules.Core.Source.Controllers.InterfaceManagerController)
local InterfaceScopes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.InterfaceScopes)
local LobbyLandingController = require(script.Parent.LobbyLandingController)

--[ Constants ]--

local THEME_NAME = "MainTheme"
-- How long to wait for the Sound to replicate before giving up (seconds).
local THEME_WAIT_SECONDS = 15

local MAX_VOLUME = 0.2
local LOW_VOLUME = 0.1

-- Fades (seconds): the first fade in after loading, the dip when the
-- screen is covered, and the rise when it clears.
local START_FADE_SECONDS = 6
local DOWN_FADE_SECONDS = 1.25
local UP_FADE_SECONDS = 1.25

--[ Controller ]--

local LobbyMusicController = {
	Name = "LobbyMusicController",
	Dependencies = { InterfaceManagerController, LobbyLandingController } :: { any },
}

LobbyMusicController._sound = nil :: Sound?
LobbyMusicController._tween = nil :: Tween?
-- The volume the current fade is heading to.
LobbyMusicController._goal = nil :: number?
-- True once the theme has started (the loading screen went away).
LobbyMusicController._started = false
-- True once the landing cutscene is over (the HUD's first reopening).
LobbyMusicController._landed = false

--[ Private ]--

-- The volume the theme should sit at right now.
function LobbyMusicController._targetVolume(self: typeof(LobbyMusicController)): number
	if self._landed and not InterfaceManagerController:IsScopeOpen(InterfaceScopes.HUD) then
		return LOW_VOLUME
	end
	return MAX_VOLUME
end

function LobbyMusicController._fadeTo(self: typeof(LobbyMusicController), volume: number, seconds: number)
	local sound = self._sound
	if not sound then
		return
	end
	-- Already heading there (the slow start fade, when the landing ends
	-- mid-way): let it run rather than restart it faster.
	if self._goal == volume then
		return
	end
	self._goal = volume
	if self._tween then
		self._tween:Cancel()
	end
	local tween = TweenService:Create(
		sound,
		TweenInfo.new(seconds, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
		{ Volume = volume }
	)
	self._tween = tween
	tween:Play()
end

-- The loading screen is going: start the theme from silence.
function LobbyMusicController._begin(self: typeof(LobbyMusicController))
	if self._started then
		return
	end
	self._started = true
	task.spawn(function()
		local sound = SoundService:WaitForChild(THEME_NAME, THEME_WAIT_SECONDS)
		if not sound or not sound:IsA("Sound") then
			warn("[LobbyMusicController] SoundService." .. THEME_NAME .. " missing -- no town theme")
			return
		end
		sound.Looped = true
		sound.Volume = 0
		ClientSettingsController:AssignMusic(sound)
		if not sound.IsPlaying then
			sound:Play()
		end
		self._sound = sound
		self:_fadeTo(self:_targetVolume(), START_FADE_SECONDS)
	end)
end

--[ Lifecycle ]--

function LobbyMusicController.Start(self: typeof(LobbyMusicController))
	InterfaceManagerController.Signals.OnScopeVisibilityChanged:Connect(function(scope: string, isOpen: boolean)
		if scope ~= InterfaceScopes.HUD or not self._started then
			return
		end
		if isOpen then
			self._landed = true
		end
		if not self._landed then
			return
		end
		self:_fadeTo(self:_targetVolume(), if isOpen then UP_FADE_SECONDS else DOWN_FADE_SECONDS)
	end)

	if LobbyLandingController:IsRevealed() then
		self:_begin()
	else
		LobbyLandingController.OnRevealed:Connect(function()
			self:_begin()
		end)
	end
end

return LobbyMusicController
