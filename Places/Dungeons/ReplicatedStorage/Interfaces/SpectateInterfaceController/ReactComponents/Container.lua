--[[
     Module: Container.lua
     Description:
     Spectate HUD. Two Observe subscriptions:
       1. LifeService.DeathState — am I dead? Drives visibility.
       2. SpectateService.SpectateTargets — who am I watching? Drives the
          "Now Viewing: X" label.

     Layout:
       - Top-center: "Now Viewing: <PlayerName>" with "< />" arrow hints
         flanking the name (matches the arrow-key cycle controls).

     Bottom-center: REVIVE button (paid, restored). Calls
     LifeService:PromptRevivePurchase; the server's ProcessReceipt →
     :Revive flow fades, teleports to the party, and clears DeathState
     (which hides this whole UI). Run escrow stays lost — revive buys
     your feet back, not your loot.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local React = require(ReplicatedStorage.Submodules.Core.Packages.React)

-- Fade duration for the spectate UI entrance / exit. Matches the death-fade
-- timing in LifeController (0.4s feels parallel to the screen-fade window
-- without being slower than it). Used on isSpectating true → false → true
-- transitions; the tween is token-guarded against rapid toggles.
local SPECTATE_FADE_DURATION = 0.4
local SPECTATE_FADE_TWEEN_INFO = TweenInfo.new(SPECTATE_FADE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

--[ Tuning ]--

local FONT = Font.new("rbxasset://fonts/families/Montserrat.json", Enum.FontWeight.Bold)

-- "Now Viewing" header positioning.

--[ Component ]--

local function Container(props: any)
	local LifeService = props.LifeService
	local LifeController = props.LifeController
	local SpectateService = props.SpectateService

	-- Visibility: am I in the "actively spectating" visual state? Gated
	-- on LifeController.OnSpectateStateChanged (NOT DeathState) — that
	-- signal flips true only AFTER the death cinematic + fade complete,
	-- so the UI doesn't pop in immediately when the player dies.
	-- Seeded from :IsLocalSpectating() in case we mount post-flip.
	local isSpectating, setIsSpectating = React.useState(LifeController:IsLocalSpectating())

	-- Spectated player's userId. nil if no target (everyone alive or
	-- everyone else dead — UI then shows "(no one)").
	local spectatedUserId, setSpectatedUserId = React.useState(nil)

	-- Observe the local spectating state. Flips true after death-fade
	-- completes; flips false at start of revive-fade.
	React.useEffect(function()
		local conn = LifeController.OnSpectateStateChanged:Connect(function(value: boolean)
			setIsSpectating(value)
		end)
		return function()
			if conn then
				conn:Disconnect()
			end
		end
	end, {})

	-- Observe SpectateTargets — name to display.
	React.useEffect(function()
		local observer = SpectateService.SpectateTargets:Observe(function(data: { [any]: any }?)
			local localId = Players.LocalPlayer.UserId
			local targetId = data and (data[localId] or data[tostring(localId)])
			setSpectatedUserId(targetId)
		end)
		return function()
			if observer then
				observer:Disconnect()
			end
		end
	end, {})

	-- CanvasGroup ref + token guarding the fade tween. A CanvasGroup lets
	-- us tween every descendant's effective opacity with a single
	-- GroupTransparency property — much simpler than reffing each label
	-- and button individually. Token guards rapid isSpectating toggles
	-- (e.g. revive-during-fade) so the previous fade's Completed handler
	-- can't flip Visible=false on a UI that's already fading back in.
	local containerRef = React.useRef(nil)
	local fadeTokenRef = React.useRef(nil)

	-- Driven by the fade-tween's Completed callback so input clicks are
	-- blocked on the fully-faded UI. Mounts invisible (no fade-in pop on
	-- first render), flips true on the spectate-state edge, stays true
	-- during the fade-out, flips false only when the out-tween completes.
	local visible, setVisible = React.useState(false)

	React.useEffect(function()
		local current = containerRef.current
		if not current then
			return
		end

		-- Fresh token. Any prior in-flight fade's Completed handler will
		-- see the token has moved and bail.
		local token = {}
		fadeTokenRef.current = token

		if isSpectating then
			-- Fade in. Set Visible immediately so the tween-in is actually
			-- visible — otherwise we'd render the tween against a hidden
			-- ScreenGui and reveal at the end with a snap-pop.
			setVisible(true)
			TweenService:Create(current, SPECTATE_FADE_TWEEN_INFO, {
				GroupTransparency = 0,
			}):Play()
		else
			-- Fade out, THEN hide. The Completed → setVisible(false) flow
			-- keeps the React tree mounted across the fade so the
			-- transparency interpolation actually plays; without this, a
			-- React-side conditional render would unmount mid-fade.
			local tween = TweenService:Create(current, SPECTATE_FADE_TWEEN_INFO, {
				GroupTransparency = 1,
			})
			tween.Completed:Connect(function()
				if fadeTokenRef.current ~= token then
					return -- a new fade started; let it own the Visible flip
				end
				setVisible(false)
			end)
			tween:Play()
		end
	end, { isSpectating })

	-- Resolve player name. Use "N/A" if nobody to spectate (everyone
	-- else dead too). Number-or-string defensive lookup.
	local spectatedName = "N/A"
	if spectatedUserId then
		local player = Players:GetPlayerByUserId(tonumber(spectatedUserId) or 0)
		if player then
			spectatedName = player.DisplayName ~= "" and player.DisplayName or player.Name
		end
	end

	return React.createElement("CanvasGroup", {
		ref = containerRef,

		AnchorPoint = Vector2.new(0, 0),
		Position = UDim2.fromScale(0, 0),
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,

		-- Start fully transparent. The useEffect's fade-in tween paints
		-- toward GroupTransparency=0 on the first isSpectating=true edge.
		GroupTransparency = 1,

		-- Visible drives input-blocking. While the UI is fully faded out
		-- AND not transitioning, descendants don't accept clicks. The
		-- fade-out → setVisible(false) flow runs only after the tween
		-- completes, so input stays active through the fade.
		Visible = visible,
	}, {

		Header = React.createElement("Frame", {
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.fromScale(0.5, 0.861),
			Size = UDim2.fromScale(0.25, 0.09),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
		}, {
			ShadowGradientImageLabel = React.createElement("ImageLabel", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.6),
				Size = UDim2.fromScale(1.255, 1.837),
				BackgroundTransparency = 1,
				Image = "rbxassetid://90190541001824",
				ScaleType = Enum.ScaleType.Stretch,
				ImageTransparency = 0.65,
				ZIndex = -1,
			}, {
				UICorner = React.createElement("UICorner", {
					CornerRadius = UDim.new(0.35, 0),
				}),
			}),

			NowSpectatingLabel = React.createElement("TextLabel", {
				AnchorPoint = Vector2.new(0.5, 0),
				Position = UDim2.fromScale(0.5, 0.126),
				Size = UDim2.fromScale(0.9, 0.324),
				BackgroundTransparency = 1,
				Text = "Now Spectating:",
				TextColor3 = Color3.fromRGB(175, 175, 175),
				TextScaled = true,
				FontFace = FONT,
			}, {
				UIStroke = React.createElement("UIStroke", {
					Color = Color3.fromRGB(0, 0, 0),
					Thickness = 0.05,
					Transparency = 0.5,
					StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize,
				}),
			}),

			-- Player name + arrow hints. Horizontal UIListLayout so the
			-- arrows flank the name dynamically.
			NameRow = React.createElement("Frame", {
				AnchorPoint = Vector2.new(0.5, 1),
				Position = UDim2.fromScale(0.5, 0.92),
				Size = UDim2.fromScale(0.92, 0.5),
				BackgroundTransparency = 1,
			}, {
				UIListLayout = React.createElement("UIListLayout", {
					FillDirection = Enum.FillDirection.Horizontal,
					HorizontalAlignment = Enum.HorizontalAlignment.Center,
					VerticalAlignment = Enum.VerticalAlignment.Center,
					Padding = UDim.new(-0.05, 0),
					SortOrder = Enum.SortOrder.LayoutOrder,
				}),

				LeftArrowFrameContainer = React.createElement("Frame", {
					LayoutOrder = 1,
					Size = UDim2.fromScale(0.2, 1),
					BackgroundTransparency = 1,
				}, {
					LeftArrowButton = React.createElement("ImageButton", {
						Size = UDim2.fromScale(1, 1),
						BackgroundTransparency = 1,
						ScaleType = Enum.ScaleType.Fit,
						Image = "rbxassetid://12198207955",
						[React.Event.Activated] = function()
							-- Server-side SpectateService:CycleTarget consumes
							-- the "left"|"right" payload, validates the player
							-- is still in death state, and routes the camera
							-- via IsometricCameraService. The SpectateTargets
							-- Observe above picks up the new userId and the
							-- name label updates on its own.
							SpectateService.OnCycleRequested:Fire("left")
						end,
					}),
				}),

				NameFrameContainer = React.createElement("Frame", {
					LayoutOrder = 2,
					Size = UDim2.fromScale(0.75, 1),
					BackgroundTransparency = 1,
				}, {
					NameTextLabel = React.createElement("TextLabel", {
						AnchorPoint = Vector2.new(0.5, 0.5),
						Position = UDim2.fromScale(0.5, 0.5),
						Size = UDim2.fromScale(1, 0.75),
						BackgroundTransparency = 1,
						Text = spectatedName,
						TextColor3 = Color3.fromRGB(255, 255, 255),
						TextScaled = true,
						FontFace = Font.new("rbxasset://fonts/families/Montserrat.json", Enum.FontWeight.Bold),
						TextXAlignment = Enum.TextXAlignment.Center,
						TextYAlignment = Enum.TextYAlignment.Center,
					}, {
						UIStroke = React.createElement("UIStroke", {
							Color = Color3.fromRGB(0, 0, 0),
							Thickness = 0.05,
							Transparency = 0.5,
							StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize,
						}),
					}),
				}),

				RightArrowFrameContainer = React.createElement("Frame", {
					LayoutOrder = 3,
					Size = UDim2.fromScale(0.2, 1),
					BackgroundTransparency = 1,
				}, {
					RightArrowButton = React.createElement("ImageButton", {
						Size = UDim2.fromScale(1, 1),
						BackgroundTransparency = 1,
						Rotation = 180,
						Image = "rbxassetid://12198207955",
						ScaleType = Enum.ScaleType.Fit,
						[React.Event.Activated] = function()
							SpectateService.OnCycleRequested:Fire("right")
						end,
					}),
				}),
			}),
		}),

		--[ REVIVE button (paid, restored) ]--
		-- Taps LifeService:PromptRevivePurchase, a server-validated Knit
		-- method that prompts the dev product. On purchase, the server's
		-- ProcessReceipt -> :Revive flow fades, teleports, and clears the
		-- death state -- which hides this whole UI mid-fade.
		ReviveButton = React.createElement("TextButton", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.825),
			Size = UDim2.fromScale(0.105, 0.047),
			BackgroundColor3 = Color3.fromRGB(85, 255, 127),
			Text = "REVIVE",
			TextColor3 = Color3.fromRGB(255, 255, 255),
			TextScaled = true,
			FontFace = FONT,
			BorderSizePixel = 0,
			AutoButtonColor = true,
			[React.Event.Activated] = function()
				LifeService:PromptRevivePurchase()
			end,
		}, {
			UICorner = React.createElement("UICorner", { CornerRadius = UDim.new(0.2, 0) }),
			UIStroke = React.createElement("UIStroke", {
				Color = Color3.fromRGB(31, 94, 46),
				Thickness = 0.06,
				ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
				StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize,
			}),
			BorderStroke = React.createElement("UIStroke", {
				Color = Color3.fromRGB(31, 94, 46),
				Thickness = 0.075,
				ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
				StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize,
			}),
			UIPadding = React.createElement("UIPadding", {
				PaddingLeft = UDim.new(0, 0),
				PaddingRight = UDim.new(0, 0),
				PaddingTop = UDim.new(0.15, 0),
				PaddingBottom = UDim.new(0.15, 0),
			}),
		}),
	})
end

return Container
