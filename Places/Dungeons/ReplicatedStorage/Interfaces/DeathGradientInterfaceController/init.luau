--[[
     Module: DeathGradientInterfaceController.lua
     Description:
     Death-specific gradient overlay. Duplicate of ScreenGradientInterfaceController
     wired identically (OnPulseGradient signal, _deathPulse + _pulseToken guards,
     5s death-pulse / 0.25s regular-pulse timing) but driven by its OWN signal
     instance and rendering its own Container with 3 stacked GradientImageLabels.

     Why a parallel controller instead of reusing ScreenGradientInterfaceController:
     the screen gradient handles every non-death pulse (damage flash, dodge,
     relic pickup) and shares a single _deathPulse guard with them. Driving
     the death overlay through that same pipeline meant a non-death pulse
     fired the tick before death could leave a stale reset callback queued
     that would clobber the death pulse mid-animation. Even with the token
     guard added there, isolating the death visual into its own controller
     (own signal, own token, own React tree) means damage/dodge/relic
     pulses can't interfere with it at all — the only thing that fires
     this controller's signal is LifeController on death.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

--[ Imports ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local React = require(ReplicatedStorage.Submodules.Core.Packages.React)
local ReactRoblox = require(ReplicatedStorage.Submodules.Core.Packages["React-Roblox"])
local Signal = require(ReplicatedStorage.Submodules.Core.Packages.Signal)
local DeathCinematicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.DeathCinematicData)

local Container = require(script.ReactComponents.Container)

local INTERFACE_ID = "DeathGradientInterfaceController"

--[ App Component ]--

local DeathGradientInterfaceController = Knit.CreateController({
	Name = "DeathGradientInterfaceController",
})

-- Mirrors ScreenGradientInterfaceController's death-pulse latch + token. The
-- latch (`_deathPulse`) blocks new fires while a death pulse is already
-- showing; the token (`_pulseToken`) invalidates any stale task.delay reset
-- callback whose pulse has since been superseded.
DeathGradientInterfaceController._deathPulse = false
DeathGradientInterfaceController._pulseToken = nil
DeathGradientInterfaceController.Signals = {
	OnPulseGradient = Signal.new(),
}

function DeathGradientInterfaceController:_render()
	return function()
		local pulseGradient, setPulseGradient = React.useState(false)
		local imageColor3, setImageColor3 = React.useState(Color3.fromRGB(255, 255, 255))

		React.useEffect(function()
			local onStartConn

			onStartConn = self.Signals.OnPulseGradient:Connect(function(color3: Color3, death: boolean?)
				-- Re-entry guard. Death pulse already showing → don't let
				-- a follow-up pulse restart its timer or overwrite color.
				if self._deathPulse then
					return
				end

				local isDeathPulse = death == true
				self._deathPulse = isDeathPulse

				-- Token-stamp this pulse. Any pending reset from a prior
				-- pulse will no-op when it sees its token has moved on.
				local token = {}
				self._pulseToken = token

				setPulseGradient(true)
				setImageColor3(color3)

				-- Death-pulse hold duration sourced from DeathCinematicData so
				-- LifeController's task.spawn timeline (FadeIn at VfxDuration)
				-- and the Container's countdown bar (which empties at this
				-- same beat) all auto-resync on a config change.
				task.delay(if isDeathPulse then DeathCinematicData.VfxDuration else 0.25, function()
					if self._pulseToken ~= token then
						return
					end
					self._pulseToken = nil
					self._deathPulse = false
					setPulseGradient(false)
				end)
			end)

			return function()
				onStartConn:Disconnect()
			end
		end, {})

		return React.createElement("ScreenGui", {
			ResetOnSpawn = false,
			IgnoreGuiInset = true,
			Name = INTERFACE_ID,
			ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
			ClipToDeviceSafeArea = false,
			DisplayOrder = 99999,
		}, {
			Container = React.createElement(Container, {
				Visible = true,
				ImageColor3 = imageColor3,

				pulseGradient = pulseGradient,
			}),
		})
	end
end

--[ Lifecycle ]--

function DeathGradientInterfaceController:KnitInit()
	local root = ReactRoblox.createRoot(Instance.new("Folder"))
	root:render(ReactRoblox.createPortal(React.createElement(self:_render()), Players.LocalPlayer.PlayerGui))
end

return DeathGradientInterfaceController
