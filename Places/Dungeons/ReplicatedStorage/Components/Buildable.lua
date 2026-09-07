--[[
     Author(s): ryanisawesome25
     Module: Buildable.luau
     Description:
]]

--[ Exports & Types & Defaults ]--

--[ Roblox Services ]--

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

--[ Imports ]--

local Component = require(ReplicatedStorage.Submodules.Core.Packages.Component)
local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local onDamageIndicator = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Highlight.onDamageIndicator)

local BuildService

Knit.OnStart():andThen(function()
	BuildService = Knit.GetService("BuildService")
end)

--[ Component Root ]--

local Buildable = Component.new({
	Tag = "Buildable",
})

--[ Constants ]--

local ATTACK_HIGHLIGHT_NAME = "BuildDamageIndicator"

--[ Properties ]--

--[ Private Functions ]--

--[ Public Functions ]--

--[ Initializers ]--

function Buildable:Construct() end

function Buildable:Start()
	BuildService.OnBuildDamaged:Connect(function(buildTemplate: Model)
		if
			buildTemplate:FindFirstChild(ATTACK_HIGHLIGHT_NAME)
			and buildTemplate:FindFirstChild(ATTACK_HIGHLIGHT_NAME).FillTransparency ~= 1
		then
			return
		end

		if buildTemplate:FindFirstChild(ATTACK_HIGHLIGHT_NAME) then
			buildTemplate:FindFirstChild(ATTACK_HIGHLIGHT_NAME):Destroy()
		end

		-- Tween the PrimaryPart's angles to indicate damage
		local primaryPart = buildTemplate.PrimaryPart

		if primaryPart then
			local originalCFrame = buildTemplate:GetAttribute(Attributes.CachedCFrame)
			-- Randomize angles between -10 and 10 degrees for each axis
			local angleOffsetX = math.rad(math.random(-10, 10))
			local angleOffsetY = math.rad(math.random(-10, 10))
			local angleOffsetZ = math.rad(math.random(-10, 10))
			local tweenInfo = TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
			local goal = {}
			goal.CFrame = originalCFrame * CFrame.Angles(angleOffsetX, angleOffsetY, angleOffsetZ)

			local tween = TweenService:Create(primaryPart, tweenInfo, goal)
			tween:Play()
			tween.Completed:Connect(function()
				-- Return to original angles
				local returnTween = TweenService:Create(primaryPart, TweenInfo.new(0.2), { CFrame = originalCFrame })
				returnTween:Play()
			end)
		end

		onDamageIndicator(buildTemplate, ATTACK_HIGHLIGHT_NAME)
	end)
end

function Buildable:Stop() end

return Buildable
