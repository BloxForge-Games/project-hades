--[[
	Module: Client/Components/Rune.lua
	Description:
	The client half of a rune drop — a deliberate mirror of
	Client/Components/Relic (bezier pop-out arc, bob + spin float, RelicName
	billboard, custom-styled ProximityPrompt, request-only pickup). Runes
	ARE relics as far as presentation goes; what differs:

	  * The billboard reads the rune's name bare (no "Rune" suffix -- the
	    names ARE the items) and the prompt description is the
	    ROLLED TIER's flat stat (getRuneDescription — an Epic Damage rune
	    says "+5%", never the whole ladder).
	  * There is no Skip offer and no cap refusal — the server always
	    accepts a valid owner pickup, but the client stays request-only
	    anyway so the contract matches Relic exactly.
	  * Accept sweeps every ".Rune"-tagged offer of the owner (pick 1 of 3).

	Kept in step with Client/Components/Relic on purpose — if the relic
	pickup feel is ever retuned (arc timing, fade, prompt styling), mirror
	it here.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Component = require(ReplicatedStorage.Submodules.Core.Packages.Component)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local CommAdder = require(ReplicatedStorage.Submodules.Core.Source.ComponentExtensions.CommAdder)
local JanitorAdder = require(ReplicatedStorage.Submodules.Core.Source.ComponentExtensions.JanitorAdder)
local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local RuneData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RuneData)
local RarityColors = require(ReplicatedStorage.Submodules.Core.Shared.Data.RarityColors)
local RuneRarityColors = require(ReplicatedStorage.Submodules.Core.Shared.Data.RuneRarityColors)
local ScreenSizes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ScreenSizes)
local getRuneDescription = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Rune.getRuneDescription)
local applyOwnerLabel = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Drop.applyOwnerLabel)
local arcPath = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Drop.arcPath)

local Y_POS_OFFSET = 3
local ROTATION_SPEED = 20
local ScreenGradientInterfaceController
local ScreenSizeController

Knit.OnStart()
	:andThen(function()
		ScreenGradientInterfaceController = Knit.GetController("ScreenGradientInterfaceController")
		ScreenSizeController = Knit.GetController("ScreenSizeController")
	end)
	:catch(warn)

local Rune = Component.new({
	Tag = TagList.Rune,
	Extensions = { CommAdder, JanitorAdder },
})

function Rune:_HeartbeatUpdate(deltaTime: number)
	-- Bob + rotation folded into ONE PivotTo, same as Relic — moves the
	-- whole model (Handle + PrimaryPart) together.
	local bobY = self._amplitude * math.sin((tick() * 2) * (math.pi / self._durationPerCycle))
	local rotation = math.rad(ROTATION_SPEED * deltaTime)
	self.Instance:PivotTo(
		self.Instance:GetPivot() * CFrame.new(0, bobY, 0) * CFrame.Angles(rotation, rotation * 1.5, rotation / 2)
	)
end

function Rune:Construct()
	self._amplitude = Random.new():NextNumber(0.01, 0.015)
	self._durationPerCycle = Random.new():NextNumber(2, 3.5)
	self._primaryPart = self.Instance.Handle
	self._onRuneCollected = self._comm:GetSignal("OnRuneCollected")
	self._onRuneCollectAccepted = self._comm:GetSignal("OnRuneCollectAccepted")
	self._canPickup = false
	self._consumed = false
	self._originPosition = self.Instance:GetPivot().Position
	self._intermediatePosition = self._originPosition + Vector3.new(0, math.random(7, 10), 0)
	self._endPosition = self.Instance:GetAttribute("TargetPosition") + Vector3.new(0, Y_POS_OFFSET, 0)
	-- One or two bezier legs (see Relic): a BouncePosition makes the
	-- wall ricochet visible.
	self._arc, self._arcDurationScale = arcPath(
		self._originPosition,
		self._intermediatePosition,
		self._endPosition,
		self.Instance:GetAttribute(Attributes.BouncePosition)
	)
	self._connection = nil
	-- The hover scale-up tween (RelicRenderController's PromptShown) drives
	-- this value on relics AND runes -- same name, same 1.5 base.
	self._numberValue = Instance.new("NumberValue")
	self._numberValue.Value = 1.5
	self._numberValue.Name = "RelicScale"
	self._numberValue.Parent = self.Instance
	self._relicParticles = ReplicatedStorage.GameAssets.Particles.RelicParticles:Clone()
	self._relicParticles.Parent = self.Instance.Handle
	self._collectedAttachment = self.Instance.Handle:FindFirstChild("Collected")
end

function Rune:Start()
	-- PrimaryPart is a control/anchor part + billboard adornee — never
	-- meant to render.
	if self.Instance.PrimaryPart then
		self.Instance.PrimaryPart.Transparency = 1
	end

	local rarity = self.Instance:GetAttribute("RuneRarity")

	if Players.LocalPlayer.UserId ~= self.Instance:GetAttribute(Attributes.OwnerId) then
		-- Not ours: fade every visible part and mute the rarity particles,
		-- same treatment the Relic component gives other owners' offers.
		for _, descendant in self.Instance:GetDescendants() do
			if descendant:IsA("BasePart") and descendant ~= self.Instance.PrimaryPart then
				TweenService:Create(
					descendant,
					TweenInfo.new(0, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out),
					{ Transparency = 1 }
				):Play()
			end
		end

		local particleAttachment = self.Instance.PrimaryPart
			and self.Instance.PrimaryPart:FindFirstChild("RelicParticleAttachment")
		if particleAttachment then
			for _, particle in particleAttachment:GetChildren() do
				if particle.Name == "Shine" then
					particle.Enabled = false
					continue
				end
				if particle:IsA("ParticleEmitter") then
					particle.Transparency = NumberSequence.new({
						NumberSequenceKeypoint.new(0, 1),
						NumberSequenceKeypoint.new(1, 1),
					})
				end
			end
		end
		return
	end

	-- Fade-in: every BasePart except the anchor.
	for _, descendant in self.Instance:GetDescendants() do
		if descendant:IsA("BasePart") and descendant ~= self.Instance.PrimaryPart then
			TweenService:Create(
				descendant,
				TweenInfo.new(1, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out),
				{ Transparency = 0 }
			):Play()
		end
	end

	self.startTime = workspace:GetServerTimeNow()
	-- Stretched for a ricochet (arcPath's durationScale) so the longer
	-- two-leg path flies at the same pace as a plain arc.
	self.duration = 1 * (self._arcDurationScale or 1)

	self._numberValue.Changed:Connect(function(value)
		self.Instance:ScaleTo(value)
	end)

	local runeName = self.Instance.Name
	-- What the PLAYER sees. The instance keeps the enum/asset name
	-- (Cheeseburger et al.) for registry and model lookups; RuneData's
	-- `name` is the display identity ("Health Rune").
	local displayName = (RuneData[runeName] and RuneData[runeName].name) or runeName
	-- Rarity TEXT keeps the game-wide palette (so a rune's "Epic" reads the
	-- same as a relic's); PARTICLES use the rune-specific one.
	local rarityColor = RarityColors:Get(rarity)
	local particleColor = RuneRarityColors:Get(rarity)

	local runeBillboardGui = ReplicatedStorage.GameAssets.BillboardGuis.RelicName:Clone()
	runeBillboardGui.Adornee = self.Instance.PrimaryPart
	runeBillboardGui.Frame.NameText.Text = displayName
	runeBillboardGui.Frame.RarityText.Text = rarity
	runeBillboardGui.Frame.RarityText.TextColor3 = rarityColor

	-- Shares the RelicName prefab, whose UserText carries authored
	-- placeholder text. A rune is never a player drop, so nil hides it.
	applyOwnerLabel(runeBillboardGui.Frame, nil)

	runeBillboardGui.Parent = self.Instance.PrimaryPart

	local dropAttachment = self._primaryPart:FindFirstChild("DropAttachment")
	if dropAttachment and dropAttachment:FindFirstChild("DropParticles") then
		dropAttachment.DropParticles.Color = ColorSequence.new(particleColor)
	end

	if ScreenSizeController:GetScreenSizeData().name == ScreenSizes.Mobile then
		runeBillboardGui.Frame.NameText.TextSize = 12
		runeBillboardGui.Frame.RarityText.TextSize = 10
	end

	self._connection = RunService.RenderStepped:Connect(function(_: number)
		local now = workspace:GetServerTimeNow()
		local alpha = math.clamp((now - self.startTime) / self.duration, 0, 1)

		local pos = self._arc(alpha)

		self.Instance:PivotTo(CFrame.new(pos))

		if alpha >= 1 then
			self._connection:Disconnect()

			if dropAttachment and dropAttachment:FindFirstChild("DropParticles") then
				dropAttachment.DropParticles.Enabled = false
			end

			self._relicParticles:Emit(15)

			self._janitor:Add(RunService.Heartbeat:Connect(function(deltaTime: number)
				self:_HeartbeatUpdate(deltaTime)
			end))

			-- The ROLLED TIER's stat is the whole description — the tier
			-- ladder never shows, matching how relic numbers read.
			local runeDescription = getRuneDescription(runeName, rarity) or "No description available."

			local proximityPrompt = Instance.new("ProximityPrompt")
			proximityPrompt.ActionText = displayName
			proximityPrompt.ObjectText = runeDescription
			proximityPrompt.KeyboardKeyCode = Enum.KeyCode.F
			proximityPrompt.RequiresLineOfSight = false
			proximityPrompt.MaxActivationDistance = 6
			proximityPrompt.Style = Enum.ProximityPromptStyle.Custom
			proximityPrompt.UIOffset = Vector2.new(0, 60)
			proximityPrompt.Enabled = false

			local promptStyle = "RelicSmall"
			local descriptionLength = string.len(string.gsub(runeDescription, "<[^>]+>", ""))

			if descriptionLength > 34 and descriptionLength <= 62 then
				promptStyle = "RelicMedium"
			elseif descriptionLength > 62 then
				promptStyle = "RelicLarge"
			end

			proximityPrompt:SetAttribute("Rarity", rarity)
			proximityPrompt:SetAttribute("Style", promptStyle)

			proximityPrompt.Parent = self.Instance.Handle

			task.delay(0.25, function()
				proximityPrompt.Enabled = true
			end)

			-- REQUEST ONLY — the server owns the decision; nothing is
			-- consumed here.
			proximityPrompt.Triggered:Connect(function(player: Player)
				if player.UserId ~= self.Instance:GetAttribute(Attributes.OwnerId) then
					return
				end
				self._onRuneCollected:Fire(self.Instance.Name)
			end)

			-- ACCEPTED by the server: play the pickup across the whole pull.
			self._janitor:Add(self._onRuneCollectAccepted:Connect(function()
				if self._consumed then
					return
				end
				self._consumed = true

				proximityPrompt.Enabled = false

				local taggedRunes = workspace:QueryDescendants("." .. TagList.Rune)

				for _, rune in pairs(taggedRunes) do
					if rune:GetAttribute("OwnerId") ~= Players.LocalPlayer.UserId then
						continue
					end

					ScreenGradientInterfaceController.Signals.OnPulseGradient:Fire(rarityColor)

					local prompt = rune:FindFirstChild("Handle") and rune.Handle:FindFirstChild("ProximityPrompt")
					if prompt then
						prompt.Enabled = false
					end

					local runeNameGui = rune.PrimaryPart and rune.PrimaryPart:FindFirstChild("RelicName")
					if runeNameGui then
						runeNameGui:Destroy()
					end

					local particleAttachment = rune:FindFirstChild("Handle")
						and rune.Handle:FindFirstChild("RelicParticleAttachment")
					if particleAttachment then
						for _, descendant in particleAttachment:GetDescendants() do
							if descendant:IsA("ParticleEmitter") then
								descendant.Enabled = false
							end
						end
					end

					if rune.Name == self.Instance.Name and rune:FindFirstChild("Handle") then
						local collected = rune.Handle:FindFirstChild("Collected")
						if collected then
							for _, v in collected:GetChildren() do
								v:Emit(1)
							end
						end
					end

					-- Pickup fade — every BasePart except the anchor.
					for _, descendant in rune:GetDescendants() do
						if descendant:IsA("BasePart") and descendant ~= rune.PrimaryPart then
							TweenService:Create(descendant, TweenInfo.new(0.75), { Transparency = 1 }):Play()
						end
					end
				end
			end))
		end
	end)

	-- The rarity particles ride the Handle once the arc lands, same as
	-- relics (authored under PrimaryPart so the machine can tint them).
	local particleAttachment = self.Instance.PrimaryPart
		and self.Instance.PrimaryPart:FindFirstChild("RelicParticleAttachment")
	if particleAttachment then
		particleAttachment.Parent = self._primaryPart
	end
end

return Rune
