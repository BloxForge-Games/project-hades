--[[
	Module: AmbientGradientInterfaceController/init.luau
	Description:
	The permanent screen vignette — a black gradient held at a constant
	75% transparency over the whole viewport, for atmosphere only.

	ONE RUNTIME KNOB, and only one: SetStrong(true / false) tweens the
	vignette between its resting transparency and a stronger one, for
	cutscene beats (CutsceneController:PlayMagicCutscene). Otherwise it
	stays as it was: no props, mounted once at KnitInit — which is also
	why the whole interface is a single file.
	ALWAYS VISIBLE, deliberately: it is NOT registered with
	InterfaceManagerController, so it does not hide with the HUD scope
	during cutscenes, the death flow, or spectating. `ResetOnSpawn = false`
	keeps it alive across respawns.

	ON TOP OF EVERYTHING: DisplayOrder 99999 puts it above every other
	ScreenGui, HUD included. That is correct for a vignette — it darkens
	the frame's edges uniformly rather than sitting behind the interface
	and being masked by it. It cannot swallow input: an ImageLabel is not
	interactive, so clicks and taps pass straight through to the UI below.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

--[ Imports ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local React = require(ReplicatedStorage.Submodules.Core.Packages.React)
local ReactRoblox = require(ReplicatedStorage.Submodules.Core.Packages["React-Roblox"])
local Signal = require(ReplicatedStorage.Submodules.Core.Packages.Signal)

local INTERFACE_ID = "AmbientGradientInterfaceController"

--[ Tuning ]--

-- The vignette artwork, shared with ScreenGradientInterfaceController's
-- pulse overlay (same shape, different job).
local GRADIENT_IMAGE = "rbxassetid://95194409279070"
-- Black at 25% opacity. Low enough to read as lens falloff rather than a
-- filter; the single knob to turn if it ever feels heavy.
local GRADIENT_COLOR = Color3.new()
local GRADIENT_TRANSPARENCY = 0.75
-- The STRONG level a cutscene beat pulls the vignette to, and how fast it
-- gets there and back. 0 = the black artwork fully opaque (the frame goes
-- dark around the cast); it eases back to GRADIENT_TRANSPARENCY after.
local STRONG_GRADIENT_TRANSPARENCY = 0
local STRENGTH_TWEEN_SECONDS = 0.35

--[ Controller ]--

local AmbientGradientInterfaceController = Knit.CreateController({
	Name = INTERFACE_ID,
})

-- (strong: boolean) — the render tweens the vignette to the matching
-- transparency. Fired by SetStrong; a signal so the React side owns the
-- instance and the controller never reaches into the tree.
AmbientGradientInterfaceController.Signals = {
	OnSetStrong = Signal.new(),
}

-- Pull the vignette strong (a cutscene beat) or back to resting.
function AmbientGradientInterfaceController:SetStrong(strong: boolean)
	self.Signals.OnSetStrong:Fire(strong == true)
end

function AmbientGradientInterfaceController:_render()
	return function()
		local imageRef = React.useRef(nil)

		React.useEffect(function()
			local conn = self.Signals.OnSetStrong:Connect(function(strong: boolean)
				local image = imageRef.current
				if not image then
					return
				end
				TweenService:Create(
					image,
					TweenInfo.new(STRENGTH_TWEEN_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
					{ ImageTransparency = if strong then STRONG_GRADIENT_TRANSPARENCY else GRADIENT_TRANSPARENCY }
				):Play()
			end)
			return function()
				conn:Disconnect()
			end
		end, {})

		return React.createElement("ScreenGui", {
			-- Name so the ScreenGui is findable in PlayerGui, matching
			-- every other interface here.
			Name = INTERFACE_ID,
			ClipToDeviceSafeArea = false,
			DisplayOrder = 99999,
			ResetOnSpawn = false,
			ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets,
			ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		}, {
			Container = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				BackgroundTransparency = 1,
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromScale(1, 1),
			}, {
				GradientImageLabel1 = React.createElement("ImageLabel", {
					ref = imageRef,
					AnchorPoint = Vector2.new(0.5, 0.5),
					BackgroundTransparency = 1,
					Image = GRADIENT_IMAGE,
					ImageColor3 = GRADIENT_COLOR,
					ImageTransparency = GRADIENT_TRANSPARENCY,
					Position = UDim2.fromScale(0.5, 0.5),
					Size = UDim2.fromScale(1, 1),
				}),
			}),
		})
	end
end

--[ Lifecycle ]--

function AmbientGradientInterfaceController:KnitInit()
	local root = ReactRoblox.createRoot(Instance.new("Folder"))
	root:render(ReactRoblox.createPortal(React.createElement(self:_render()), Players.LocalPlayer.PlayerGui))
end

return AmbientGradientInterfaceController
