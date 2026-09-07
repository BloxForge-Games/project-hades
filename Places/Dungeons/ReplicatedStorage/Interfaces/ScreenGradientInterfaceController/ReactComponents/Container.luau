--[[
     Module: Container.lua
     Description:
     Screen gradient overlay. ONE ImageLabel driven by two state sources:

       1. Hold (persistent overlay, OnSetHold / OnClearHold)
       2. Pulse (one-shot flash, OnPulseGradient)

     Priority in the useEffect: hold > pulse > hidden. The ImageLabel's
     ImageColor3 + ImageTransparency are owned ENTIRELY by the tween —
     no ImageColor3 prop is set in the JSX (a prop snap would fight the
     tween and break the red→black crossfade). The tween targets are
     recomputed every time any driver prop changes, so a SetHold mid-
     crossfade smoothly redirects toward the new color.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local React = require(ReplicatedStorage.Submodules.Core.Packages.React)

--[ Tuning ]--

-- Default duration for any state transition. Matches the existing
-- pulse-in / pulse-out timing so the visual language is unchanged for
-- damage / dodge / relic pulses. ClearHold callers can pass a longer
-- value via fadeOutDuration for a slower spectate-end fade.
local DEFAULT_TWEEN_DURATION = 0.35

-- Pulse "visible" alpha. Three layers used to compound to ~0.42; with
-- a single layer here, 0.25 reads as the same hit intensity.
local PULSE_VISIBLE_TRANSPARENCY = 0.25
local HIDDEN_TRANSPARENCY = 1

local function Container(props: any)
	local gradientImageLabelRef = React.useRef(nil)

	React.useEffect(function()
		local current = gradientImageLabelRef.current
		if not current then
			return
		end

		-- Priority: hold beats pulse, both beat hidden. We compute a
		-- single (color, transparency, duration) target and play one
		-- tween — TweenService will start from whatever value the
		-- property currently has, so a mid-tween change naturally
		-- picks up from the in-flight position.
		local targetColor: Color3
		local targetTransparency: number
		local duration: number

		if props.holdActive then
			-- Persistent overlay. Color and transparency travel via
			-- props so red → black or 0.35 → 0.5 swaps animate
			-- smoothly without an intervening fade-to-hidden frame.
			targetColor = props.holdColor or Color3.fromRGB(255, 255, 255)
			targetTransparency = props.holdTransparency or 0.35
			duration = DEFAULT_TWEEN_DURATION
		elseif props.pulseGradient then
			-- One-shot flash. The pulse path still drives the
			-- ImageColor3 — pulseColor changes alongside
			-- pulseGradient when OnPulseGradient fires.
			targetColor = props.pulseColor or Color3.fromRGB(255, 255, 255)
			targetTransparency = PULSE_VISIBLE_TRANSPARENCY
			duration = DEFAULT_TWEEN_DURATION
		else
			-- Hidden. Color doesn't matter visually (transparency=1)
			-- but we keep the prop value so the underlying property
			-- doesn't snap to white on every cycle — the next pulse
			-- color tweens from the previous color, which is cheap
			-- and avoids any color-flash artifact.
			targetColor = props.pulseColor or Color3.fromRGB(255, 255, 255)
			targetTransparency = HIDDEN_TRANSPARENCY
			-- ClearHold can override the fade-out duration for a
			-- slower "spectate ends" tween. Falls back to default
			-- for normal pulse-out and any other hidden transition.
			duration = props.fadeOutDuration or DEFAULT_TWEEN_DURATION
		end

		TweenService:Create(current, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			ImageColor3 = targetColor,
			ImageTransparency = targetTransparency,
		}):Play()
	end, {
		props.holdActive,
		props.holdColor,
		props.holdTransparency,
		props.pulseGradient,
		props.pulseColor,
		props.fadeOutDuration,
	})

	return React.createElement("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Visible = props.Visible,
	}, {
		-- Initial ImageTransparency=1 so the first frame is invisible
		-- before the useEffect's tween runs. Initial ImageColor3 is
		-- white (Roblox default for ImageLabel) — irrelevant visually
		-- because we're transparent on mount.
		GradientImageLabel = React.createElement("ImageLabel", {
			ref = gradientImageLabelRef,

			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(1, 1),
			ImageTransparency = HIDDEN_TRANSPARENCY,
			Image = "rbxassetid://95194409279070",
			BorderSizePixel = 0,
			ZIndex = 1,
			ScaleType = Enum.ScaleType.Stretch,
		}),
	})
end

return Container
