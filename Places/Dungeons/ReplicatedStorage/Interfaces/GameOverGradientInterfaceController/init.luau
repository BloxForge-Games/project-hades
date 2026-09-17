--!strict
--[[
     Module: GameOverGradientInterfaceController.lua
     Description:
     Game Over screen. Visually identical to DeathGradientInterfaceController
     but with different text content + different lifecycle:

       Death screen:
         * Per-player trigger (OnPlayerDied for THIS userId)
         * Holds for DeathCinematicData.VfxDuration (7s)
         * Auto-clears so the dying player enters spectate
         * Randomized death reason from a corpus

       Game Over screen (this controller):
         * Goes up when the LOCAL player is DOWNED (LifeController fires
           the pulse a beat after the impact), and stays up on a wipe
         * The bar is the REVIVE DECISION WINDOW: LifeController pushes
           the window (server end time) through SetReviveWindow and the
           Container counts down to THAT time, so a late or laggy client
           sees the true remainder. With no window (the wipe screen for
           a player who was already fully dead) it falls back to the
           GameOverDuration countdown.
         * A REVIVE button beside the bar while the window is open; it
           prompts the paid dev product (PlayerNetwork.PromptRevivePurchase)
         * Never self-clears: LifeController clears it under the black
           fade before spectate, on a revive, or the place unloads
         * Fixed subtitle

     Signal API mirrors DeathGradient for consistency. Same pulse +
     hold-latch + token-guard machinery plus the revive window.

     For visual testing, fire from the command bar:
       require(game.ReplicatedStorage.Interfaces.GameOverGradientInterfaceController)
              .Signals.OnPulseGradient:Fire(Color3.fromRGB(255, 0, 0), true)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

--[ Imports ]--

local React = require(ReplicatedStorage.Submodules.Core.Packages.React)
local ReactRoblox = require(ReplicatedStorage.Submodules.Core.Packages["React-Roblox"])
local Signal = require(ReplicatedStorage.Submodules.Core.Packages.Signal)
local DeathCinematicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.DeathCinematicData)

local Container = require(script.ReactComponents.Container)

local INTERFACE_ID = "GameOverGradientInterfaceController"

-- The local player's open revive window, in workspace:GetServerTimeNow()
-- seconds: when it closes and when it opened (the bar's full width).
export type ReviveWindow = { endsAt: number, startedAt: number }

--[ App Component ]--

local GameOverGradientInterfaceController = {
	Name = "GameOverGradientInterfaceController",
}

-- Re-entry latch + token, mirroring the death controller. _gameOverPulse
-- blocks new fires during an active hold; _pulseToken invalidates any
-- stale reset callback whose pulse has since been superseded.
GameOverGradientInterfaceController._gameOverPulse = false
GameOverGradientInterfaceController._pulseToken = nil :: {}?
GameOverGradientInterfaceController.Signals = {
	-- Same signature as DeathGradient.OnPulseGradient: (color3, gameOver?).
	-- gameOver=true takes the long-hold branch (GameOverDuration). Without
	-- it, a 0.25s flash plays — useful for non-gameover red flashes if
	-- they ever stack on this controller. In practice LifeService always
	-- fires with the flag set.
	OnPulseGradient = Signal.new(), -- (color3, gameOver?: boolean)

	-- Tears the Game Over overlay down early. The gameOver=true branch of
	-- OnPulseGradient deliberately schedules NO auto-reset -- it assumes the
	-- run ends in a TeleportAsync that unloads the place. Multiplayer revive
	-- breaks that assumption: the player is alive again in the same place, so
	-- something has to clear it. Without this the overlay is stuck on screen
	-- AND the pulse latch stays set, which also blocks the next death's
	-- pulse-in (and therefore its progress-bar reset).
	OnClearGradient = Signal.new(), -- ()

	-- The local player's revive window, or nil once it is over (fully
	-- dead, revived, or never down). Fired by LifeController from the
	-- replicated DeathState; drives the bar's countdown and the REVIVE
	-- button's visibility.
	SetReviveWindow = Signal.new(), -- (window: ReviveWindow?)
}

function GameOverGradientInterfaceController._render(self: typeof(GameOverGradientInterfaceController))
	return function()
		local pulseGradient, setPulseGradient = React.useState(false)
		local imageColor3, setImageColor3 = React.useState(Color3.fromRGB(255, 255, 255))
		local reviveWindow, setReviveWindow = React.useState(nil :: ReviveWindow?)

		React.useEffect(function()
			local onStartConn

			onStartConn = self.Signals.OnPulseGradient:Connect(function(color3: Color3, gameOver: boolean?)
				if self._gameOverPulse then
					return
				end

				local isGameOverPulse = gameOver == true
				self._gameOverPulse = isGameOverPulse

				local token = {}
				self._pulseToken = token

				setPulseGradient(true)
				setImageColor3(color3)

				if isGameOverPulse then
					return
				end

				task.delay(if isGameOverPulse then DeathCinematicData.GameOverDuration else 0.25, function()
					if self._pulseToken ~= token then
						return
					end
					self._pulseToken = nil
					self._gameOverPulse = false
					setPulseGradient(false)
				end)
			end)

			local onClearConn = self.Signals.OnClearGradient:Connect(function()
				-- Invalidate any in-flight auto-reset so a late timer can't fire
				-- against a screen we've already torn down.
				self._pulseToken = nil
				self._gameOverPulse = false
				setPulseGradient(false)
			end)

			local onWindowConn = self.Signals.SetReviveWindow:Connect(function(window: ReviveWindow?)
				setReviveWindow(window)
			end)

			return function()
				onStartConn:Disconnect()
				onClearConn:Disconnect()
				onWindowConn:Disconnect()
			end
		end, {})

		return React.createElement("ScreenGui", {
			ResetOnSpawn = false,
			IgnoreGuiInset = true,
			Name = INTERFACE_ID,
			ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
			ClipToDeviceSafeArea = false,
			-- DisplayOrder one notch above DeathGradient so if the
			-- death screen is mid-fade-out on Game Over arrival, this
			-- overlay sits on top. DeathGradient uses 99999.
			DisplayOrder = 100000,
		}, {
			Container = React.createElement(Container, {
				Visible = true,
				ImageColor3 = imageColor3,

				pulseGradient = pulseGradient,
				reviveWindow = reviveWindow,
			}),
		})
	end
end

--[ Lifecycle ]--

function GameOverGradientInterfaceController.Init(self: typeof(GameOverGradientInterfaceController))
	local root = ReactRoblox.createRoot(Instance.new("Folder"))
	root:render(ReactRoblox.createPortal(React.createElement(self:_render()), Players.LocalPlayer.PlayerGui))
end

return GameOverGradientInterfaceController
