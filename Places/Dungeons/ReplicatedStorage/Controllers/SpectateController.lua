--[[
     Module: SpectateController.lua
     Description:
     Client-side spectate input handler. Listens for Left/Right arrow
     keys (and gamepad equivalents) while the local player is in
     LifeService.DeathState, and fires SpectateService.OnCycleRequested
     to the server. Server picks the next eligible target, updates the
     SpectateTargets property, AND fires IsometricCameraService.OnCameraTargetChanged
     for this player — so the camera lerp comes for free from the
     existing isometric camera plumbing. We don't drive the camera here.

     Gated on DeathState so the arrow keys retain their normal meaning
     (movement / camera rotation depending on bindings) outside of
     spectate mode.
]]

--[ Roblox Services ]--

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

--[ Exports & Types & Defaults ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)

local LifeController
local SpectateService

local SpectateController = Knit.CreateController({
	Name = "SpectateController",
})

--[ Properties ]--

-- Mirror of LifeController.OnSpectateStateChanged. True while the local
-- player is in the active spectate visual state (post-death-fade). We
-- gate input on this rather than DeathState so arrow keys don't try to
-- cycle during the death cinematic (between the death and the moment
-- the spectate UI actually shows).
SpectateController._isLocalSpectating = false

--[ Private helpers ]--

-- Returns true if the input key should trigger a left/right cycle, and
-- which direction. Arrow keys for keyboard; D-pad for gamepad (left-stick
-- left/right is too easy to bump during normal camera use).
local function resolveCycleDirection(input: InputObject): string?
	if input.UserInputType == Enum.UserInputType.Keyboard then
		if input.KeyCode == Enum.KeyCode.Left then
			return "left"
		elseif input.KeyCode == Enum.KeyCode.Right then
			return "right"
		end
	elseif input.UserInputType == Enum.UserInputType.Gamepad1 then
		if input.KeyCode == Enum.KeyCode.DPadLeft then
			return "left"
		elseif input.KeyCode == Enum.KeyCode.DPadRight then
			return "right"
		end
	end
	return nil
end

--[ Lifecycle ]--

function SpectateController:KnitInit()
	SpectateService = Knit.GetService("SpectateService")
end

function SpectateController:KnitStart()
	LifeController = Knit.GetController("LifeController")

	-- Seed initial value in case the spectate state already flipped on
	-- before this controller mounted (defensive — controllers normally
	-- all init before any player can die).
	self._isLocalSpectating = LifeController:IsLocalSpectating()

	-- Track local spectating state via LifeController's signal. This is
	-- the post-fade state, NOT DeathState — arrow keys shouldn't cycle
	-- during the death cinematic, only once the spectate UI is visible.
	LifeController.OnSpectateStateChanged:Connect(function(isSpectating: boolean)
		self._isLocalSpectating = isSpectating
	end)

	-- Cycle input. Roblox passes `processed = true` if another input
	-- handler already consumed the event (chat, UI button, etc.) — we
	-- honor that so spectate doesn't fight with text input or button
	-- presses.
	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed or not self._isLocalSpectating then
			return
		end
		local direction = resolveCycleDirection(input)
		if not direction then
			return
		end
		SpectateService.OnCycleRequested:Fire(direction)
	end)
end

return SpectateController
