--!strict
--[[
     Module: ScreenGradientInterfaceController.lua
     Description:
     UI root / React bridge
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

--[ Imports ]--

local React = require(ReplicatedStorage.Submodules.Core.Packages.React)
local ReactRoblox = require(ReplicatedStorage.Submodules.Core.Packages["React-Roblox"])
local Signal = require(ReplicatedStorage.Submodules.Core.Packages.Signal)

local Container = require(script.ReactComponents.Container)

local INTERFACE_ID = "ScreenGradientInterfaceController"

--[ App Component ]--

local ScreenGradientInterfaceController = {
	Name = "ScreenGradientInterfaceController",
	-- The pulse's shape, for effects that ride along with it (the
	-- perfect-dodge camera flourish in TextIndicatorController): the flash
	-- tweens in over PULSE_TWEEN_SECONDS (the Container's
	-- DEFAULT_TWEEN_DURATION; keep the two equal), holds until
	-- PULSE_HOLD_SECONDS after the fire, then tweens out over the same.
	PULSE_TWEEN_SECONDS = 0.35,
	PULSE_HOLD_SECONDS = 0.45,
}

-- Token guarding the most recently scheduled reset callback. Every fire of
-- OnPulseGradient takes a fresh token; the task.delay reset bails when the
-- token has moved on. Without this a pulse fired 0.1 s after another (a
-- HumanoidStateController HealthChanged flash under a relic pickup, say)
-- is cut short by the EARLIER pulse's timer: the reset lands PULSE_HOLD
-- after the first fire and yanks the second flash off the screen early.
-- Same pattern as GameOverGradientInterfaceController.
ScreenGradientInterfaceController._pulseToken = nil :: {}?
ScreenGradientInterfaceController.Signals = {
	-- One-shot flash: damage red, dodge white, relic rarity, etc. Tweens
	-- in, holds until PULSE_HOLD_SECONDS after the fire, tweens out. A
	-- fire during the hold restarts the clock from the new colour.
	OnPulseGradient = Signal.new(), -- (color3)

	-- Persistent overlay: holds at the given color + transparency until
	-- OnClearHold is fired. Calling OnSetHold while a hold is already
	-- active smoothly tweens to the new (color, transparency) — used by
	-- LifeController to crossfade red (death VFX) → black (spectate)
	-- at the death-cinematic boundary in a single beat.
	OnSetHold = Signal.new(), -- (color3, transparency)

	-- Clears the persistent overlay. Optional fade duration controls
	-- how fast ImageTransparency rises back to 1; defaults to the
	-- standard pulse tween duration if nil.
	OnClearHold = Signal.new(), -- (fadeDuration: number?)
}

function ScreenGradientInterfaceController._render(self: typeof(ScreenGradientInterfaceController))
	return function()
		-- Pulse state: existing one-shot flash (damage / dodge / relic).
		local pulseGradient, setPulseGradient = React.useState(false)
		local pulseColor, setPulseColor = React.useState(Color3.fromRGB(255, 255, 255))

		-- Hold state: persistent overlay until OnClearHold. holdActive is
		-- the on/off; color + transparency travel alongside so a SetHold
		-- → SetHold sequence with a new color smoothly crossfades in the
		-- Container's useEffect (deps watch holdColor + holdTransparency
		-- so React re-runs the tween on every change).
		local holdActive, setHoldActive = React.useState(false)
		local holdColor, setHoldColor = React.useState(Color3.fromRGB(255, 255, 255))
		local holdTransparency, setHoldTransparency = React.useState(0.35)

		-- Optional override for the fade-out duration when OnClearHold
		-- fires. Reset to nil on the next OnSetHold so a future ClearHold
		-- without a duration argument uses the Container's default again.
		local fadeOutDuration, setFadeOutDuration = React.useState(nil :: number?)

		React.useEffect(function()
			local conns = {}

			table.insert(
				conns,
				self.Signals.OnPulseGradient:Connect(function(color3: Color3)
					local token = {}
					self._pulseToken = token

					setPulseGradient(true)
					setPulseColor(color3)

					task.delay(self.PULSE_HOLD_SECONDS, function()
						if self._pulseToken ~= token then
							return -- a later pulse owns the screen now
						end
						self._pulseToken = nil
						setPulseGradient(false)
					end)
				end)
			)

			-- SetHold: start (or update) the persistent overlay. The
			-- Container's useEffect watches holdActive + holdColor +
			-- holdTransparency, so updating any of these (red → black
			-- crossfade) re-runs the tween toward the new target.
			-- Resetting fadeOutDuration here ensures a subsequent
			-- ClearHold() without an arg uses the default, not whatever
			-- the previous ClearHold passed.
			table.insert(
				conns,
				self.Signals.OnSetHold:Connect(function(color3: Color3, transparency: number?)
					setHoldColor(color3)
					setHoldTransparency(transparency or 0.35)
					setHoldActive(true)
					-- Typed nil: the first call pins the setter's state type for
					-- the old solver, which otherwise infers it as plain `nil`.
					setFadeOutDuration(nil :: number?)
				end)
			)

			-- ClearHold: tween out. The optional duration arg is stashed
			-- in React state so the Container's useEffect picks it up
			-- on the same edge as holdActive flipping false.
			table.insert(
				conns,
				self.Signals.OnClearHold:Connect(function(duration: number?)
					if duration ~= nil then
						setFadeOutDuration(duration)
					end
					setHoldActive(false)
				end)
			)

			return function()
				for _, c in conns do
					c:Disconnect()
				end
			end
		end, {})

		return React.createElement("ScreenGui", {
			ResetOnSpawn = false,
			IgnoreGuiInset = true,
			Name = INTERFACE_ID,
			ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
			ClipToDeviceSafeArea = false,
			DisplayOrder = 1000,
		}, {
			Container = React.createElement(Container, {
				Visible = true,

				pulseColor = pulseColor,
				pulseGradient = pulseGradient,

				holdActive = holdActive,
				holdColor = holdColor,
				holdTransparency = holdTransparency,
				fadeOutDuration = fadeOutDuration,
			}),
		})
	end
end

--[ Lifecycle ]--

function ScreenGradientInterfaceController.Init(self: typeof(ScreenGradientInterfaceController))
	local root = ReactRoblox.createRoot(Instance.new("Folder"))
	root:render(ReactRoblox.createPortal(React.createElement(self:_render()), Players.LocalPlayer.PlayerGui))
end

return ScreenGradientInterfaceController
