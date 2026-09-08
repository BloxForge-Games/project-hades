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
local RelicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicData)
local SkipRelicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.SkipRelicData)
local RarityColors = require(ReplicatedStorage.Submodules.Core.Shared.Data.RarityColors)
local ScreenSizes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ScreenSizes)
local getRelicDescription = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Relic.getRelicDescription)
local lootSound = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.lootSound)
local applyOwnerLabel = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Drop.applyOwnerLabel)
local arcPath = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Drop.arcPath)

local localPlayer = Players.LocalPlayer

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

-- GROUND-relic glow. Lives here rather than on the model template on
-- purpose: this component only runs on relics tagged TagList.Relic — the
-- ones a vending machine drops — while the copies orbiting a player are
-- clones tagged "FloatingRelic" that never mount this component. Putting
-- the light in the template would light up every orbiting relic too.
local GLOW_BRIGHTNESS = 0.25
local GLOW_RANGE = 8
local GLOW_NAME = "RarityGlow"
-- Mirrors the server's PICKUP_FADE_SECONDS, which times the destroy.
local PICKUP_FADE_SECONDS = 0.75

-- The prompt card's UserText line: "(name)" of the player who DROPPED this
-- item from their tray (DroppedByName, stamped by DropService /
-- GearDropService on a public drop; a name, so it survives them leaving).
-- Empty -- the card hides the line -- for anything else: a vending
-- machine's relic is not yours until you take it, so no name on it.
local function ownerUserText(instance: Instance): string
	if instance:GetAttribute("PublicDrop") ~= true then
		return ""
	end
	local name = instance:GetAttribute("DroppedByName")
	return if typeof(name) == "string" and name ~= "" then ("(%s)"):format(name) else ""
end

local Relic = Component.new({
	Tag = TagList.Relic,
	Extensions = { CommAdder, JanitorAdder },
})

function Relic:_HeartbeatUpdate(deltaTime: number)
	-- Bob + rotation folded into ONE PivotTo so multi-handle relics
	-- (Handle + Handle2 + …) move and rotate together. The previous
	-- impl bobbed via PivotTo (OK — moves all parts) but rotated via
	-- `Handle.CFrame *= angles` (BAD — only rotates Handle). Result on
	-- a multi-handle relic: Handle spun in place while Handle2 sat
	-- still, visibly detaching the two pieces every frame.
	--
	-- Composing in pivot-space: translation around the model's pivot
	-- followed by rotation around the same pivot. Order matters —
	-- `CFrame.new(bob) * CFrame.Angles(...)` translates first then
	-- rotates, which keeps the rotation centered on the bobbed pivot.
	local bobY = self._amplitude * math.sin((tick() * 2) * (math.pi / self._durationPerCycle))
	local rotation = math.rad(ROTATION_SPEED * deltaTime)
	self.Instance:PivotTo(
		self.Instance:GetPivot() * CFrame.new(0, bobY, 0) * CFrame.Angles(rotation, rotation * 1.5, rotation / 2)
	)
end

function Relic:Construct()
	self._amplitude = Random.new():NextNumber(0.01, 0.015)
	self._durationPerCycle = Random.new():NextNumber(2, 3.5)
	self._primaryPart = self.Instance.Handle
	self._onRelicCollected = self._comm:GetSignal("OnRelicCollected")
	self._onRelicCollectAccepted = self._comm:GetSignal("OnRelicCollectAccepted")
	self._overlapParams = OverlapParams.new()
	-- Set overlap params
	self._overlapParams.FilterDescendantsInstances = {
		Players.LocalPlayer.Character,
	}
	self._overlapParams.FilterType = Enum.RaycastFilterType.Include
	self._canPickup = false
	self._consumed = false
	self._isBoss = self.Instance:GetAttribute(Attributes.IsBoss)
	self._originPosition = self.Instance:GetPivot().Position
	self._intermediatePosition = self._originPosition + Vector3.new(0, math.random(7, 10), 0)
	self._endPosition = self.Instance:GetAttribute("TargetPosition") + Vector3.new(0, Y_POS_OFFSET, 0)
	-- One or two bezier legs: a BouncePosition (the server's wall hit, see
	-- resolveArcLanding) splits the flight there and the second leg carries
	-- on to TargetPosition, so the ricochet is visible.
	self._arc, self._arcDurationScale = arcPath(
		self._originPosition,
		self._intermediatePosition,
		self._endPosition,
		self.Instance:GetAttribute(Attributes.BouncePosition)
	)
	self._numberValue = Instance.new("NumberValue")
	self._numberValue.Value = 1.5
	self._numberValue.Name = "RelicScale"
	self._numberValue.Parent = self.Instance
	self._connection = nil
	self._relicParticles = ReplicatedStorage.GameAssets.Particles.RelicParticles:Clone()
	self._relicParticles.Parent = self.Instance.Handle
	self._collectedAttachment = self.Instance.Handle.Collected
end

-- The pickup, as EVERY client sees it. The prompt and the floating label
-- go at once — a label over a claimed relic reads as still-takeable for
-- as long as it is legible — while the model itself fades out, so the
-- relic leaves rather than blinking out of existence.
--
-- Driven by the replicated Collected attribute, so it runs on every
-- screen. It used to hang off the collector-only accept signal, which is
-- why everyone else watched a claimed relic sit there until the server
-- destroyed it. Guarded: a re-fire cannot replay it.
function Relic:_playCollectedFade()
	if self._consumed then
		return
	end
	self._consumed = true

	-- PASS 1, instant: everything that reads as "you can still take this",
	-- plus the effects that do not ride Transparency and would otherwise
	-- outlive the mesh (a Light leaves a lit patch of floor under an
	-- invisible relic; emitters keep spitting particles from nothing).
	for _, descendant in self.Instance:GetDescendants() do
		if
			descendant:IsA("ProximityPrompt")
			or descendant:IsA("BillboardGui")
			or descendant:IsA("ParticleEmitter")
			or descendant:IsA("Trail")
			or descendant:IsA("Light")
		then
			descendant.Enabled = false
		end
	end

	-- PASS 2, over PICKUP_FADE_SECONDS: the visible geometry, 0 -> 1. The
	-- HANDLE is the relic's visible mesh (Construct aliases it as
	-- _primaryPart, confusingly) and PrimaryPart is a separate invisible
	-- anchor that only hosts the billboard. So every BasePart fades
	-- (MeshPart and UnionOperation are BaseParts too) — the Handle, the
	-- parts nested under it, and the extra handles a multi-part relic
	-- carries, all together.
	--
	-- The anchor is skipped ONLY when it is genuinely a separate part. If
	-- a relic's PrimaryPart IS its Handle, skipping it would leave the
	-- whole relic sitting there at full opacity — which is exactly what
	-- the blanket skip did.
	local anchor = self.Instance.PrimaryPart
	if anchor == self.Instance:FindFirstChild("Handle") then
		anchor = nil
	end

	local tweenInfo = TweenInfo.new(PICKUP_FADE_SECONDS)
	for _, descendant in self.Instance:GetDescendants() do
		if descendant:IsA("BasePart") and descendant ~= anchor then
			TweenService:Create(descendant, tweenInfo, { Transparency = 1 }):Play()
		end
	end
end

function Relic:Start()
	-- PrimaryPart is a control / anchor part for animations + the
	-- BillboardGui adornee — never meant to render. Enforce
	-- Transparency=1 here so a missed template authoring doesn't
	-- bleed an orange box through every relic. Belt + suspenders for
	-- the iterate-and-skip pattern used by the tween loops below.
	if self.Instance.PrimaryPart then
		self.Instance.PrimaryPart.Transparency = 1
	end

	-- The server marks a relic Collected the instant someone takes it.
	-- Connected before the owner gate below so it covers every client,
	-- and re-checked immediately in case the attribute arrived with the
	-- instance (a relic claimed while it was still streaming in).
	self._janitor:Add(self.Instance:GetAttributeChangedSignal(Attributes.Collected):Connect(function()
		if self.Instance:GetAttribute(Attributes.Collected) == true then
			self:_playCollectedFade()
		end
	end))
	if self.Instance:GetAttribute(Attributes.Collected) == true then
		self:_playCollectedFade()
		return
	end

	-- A PUBLIC drop (tray Drop button) is everyone's: no fade, no owner
	-- lock, and claiming it consumes only itself. Anything else fades for
	-- everyone but its OwnerId and is claimed as a fan.
	local isPublic = self.Instance:GetAttribute(Attributes.PublicDrop) == true
	if not isPublic and Players.LocalPlayer.UserId ~= self.Instance:GetAttribute(Attributes.OwnerId) then
		warn("Local player is not the owner of this relic. Cannot enable pickup.")

		-- Fade EVERY BasePart in the model EXCEPT PrimaryPart. Without
		-- the skip, the prior multi-handle fix made PrimaryPart visible
		-- as an orange box (it tweened to Transparency=1 here but other
		-- code paths re-tweened it visible — and tweening it 1→1 also
		-- briefly overwrites the enforced 1 above).
		for _, descendant in self.Instance:GetDescendants() do
			if descendant:IsA("BasePart") and descendant ~= self.Instance.PrimaryPart then
				TweenService:Create(
					descendant,
					TweenInfo.new(0, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out),
					{ Transparency = 1 }
				):Play()
			end
		end

		for _, particle in self.Instance.PrimaryPart.RelicParticleAttachment:GetChildren() do
			if particle.Name == "Shine" then
				particle.Enabled = false
				continue
			end

			particle.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1),
				NumberSequenceKeypoint.new(1, 1),
			})
		end
		return
	end

	-- Fade-in: every BasePart EXCEPT PrimaryPart, which stays at
	-- Transparency=1 (anchor part, see enforcement at top of :Start).
	-- Multi-handle relics get all their VISIBLE handles tweened in
	-- together — PrimaryPart was the orange-cube culprit before this
	-- skip was added.
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

	-- The Skip offer has no RelicData entry, so its rarity text / colour come
	-- from SkipRelicData instead (a nil rarity would error on assignment).
	local isSkip = self.Instance.Name == SkipRelicData.Name
	local rarity = if isSkip
		then SkipRelicData.DisplayRarity
		else RelicData[self.Instance.Name] and RelicData[self.Instance.Name].rarity

	local relicBillboardGui = ReplicatedStorage.GameAssets.BillboardGuis.RelicName:Clone()
	relicBillboardGui.Adornee = self.Instance.PrimaryPart
	relicBillboardGui.Frame.NameText.Text = self.Instance.Name
	relicBillboardGui.Frame.RarityText.Text = rarity

	-- Owner line: "(PlayerName)" under the rarity, and ONLY on a relic a
	-- player dropped from their tray. A vending-machine offer, an event
	-- reward or a Skip carries no DroppedByName, and the shared helper
	-- hides the label for them (the prefab authors placeholder text).
	applyOwnerLabel(relicBillboardGui.Frame, self.Instance:GetAttribute(Attributes.DroppedByName))

	local rarityColor = if isSkip then SkipRelicData.Color else RarityColors:Get(rarity)

	relicBillboardGui.Frame.RarityText.TextColor3 = rarityColor

	self._primaryPart.DropAttachment.DropParticles.Color = ColorSequence.new(rarityColor)

	-- One light on the primary Handle, tinted via the glow-specific
	-- palette (RarityColors:GetGlow — purer hues than the text tint; the
	-- Skip offer keeps its own colour). ONE, not one per handle: a
	-- multi-handle relic would otherwise stack brightness and read far
	-- hotter than a single-handle one.
	local glow = Instance.new("PointLight")
	glow.Name = GLOW_NAME
	glow.Color = if isSkip then rarityColor else RarityColors:GetGlow(rarity)
	glow.Brightness = GLOW_BRIGHTNESS
	glow.Range = GLOW_RANGE
	glow.Shadows = true
	glow.Parent = self._primaryPart

	relicBillboardGui.Parent = self.Instance.PrimaryPart

	if ScreenSizeController:GetScreenSizeData().name == ScreenSizes.Mobile then
		relicBillboardGui.Frame.NameText.TextSize = 12
		relicBillboardGui.Frame.RarityText.TextSize = 10
	end

	-- Thrown: the pop, on the Handle so it rides the arc. Every relic
	-- source reaches this same flight, so a machine, a mob, a chest, an
	-- event and a player's own tray drop all sound alike.
	lootSound:PlayPop(self.Instance:FindFirstChild("Handle"))

	self._connection = RunService.RenderStepped:Connect(function(_: number)
		local now = workspace:GetServerTimeNow()
		local alpha = math.clamp((now - self.startTime) / self.duration, 0, 1)

		local pos = self._arc(alpha)

		-- PivotTo on the whole model — was two separate
		-- `PrimaryPart.CFrame` / `Handle.CFrame` writes, which left
		-- secondary handles (Handle2, etc.) stranded at template
		-- positions during the popup arc. With PivotTo the entire
		-- multi-part model rides the bezier together.
		self.Instance:PivotTo(CFrame.new(pos))

		if alpha >= 1 then
			self._connection:Disconnect()

			self._primaryPart.DropAttachment.DropParticles.Enabled = false

			self._relicParticles:Emit(15)
			lootSound:PlayLanding()

			self._janitor:Add(RunService.Heartbeat:Connect(function(deltaTime: number)
				self:_HeartbeatUpdate(deltaTime)
			end))

			local relicName = self.Instance.Name

			local relicDescription = if isSkip
				then SkipRelicData.Description
				else getRelicDescription(localPlayer, relicName) or "No description available."
			local proximityPrompt = Instance.new("ProximityPrompt")
			proximityPrompt.ActionText = relicName
			proximityPrompt.ObjectText = relicDescription
			proximityPrompt.KeyboardKeyCode = Enum.KeyCode.F
			proximityPrompt.RequiresLineOfSight = false
			proximityPrompt.MaxActivationDistance = 6
			proximityPrompt.Style = Enum.ProximityPromptStyle.Custom
			proximityPrompt.UIOffset = Vector2.new(0, 60)
			proximityPrompt.Enabled = false

			local promptStyle = "RelicSmall"
			local descriptionLength = string.len(string.gsub(relicDescription, "<[^>]+>", ""))

			if descriptionLength > 34 and descriptionLength <= 62 then
				promptStyle = "RelicMedium"
			elseif descriptionLength > 62 then
				promptStyle = "RelicLarge"
			end

			proximityPrompt:SetAttribute("Rarity", rarity)
			proximityPrompt:SetAttribute("Style", promptStyle)
			proximityPrompt:SetAttribute("UserText", ownerUserText(self.Instance))

			proximityPrompt.Parent = self.Instance.Handle

			task.delay(0.25, function()
				proximityPrompt.Enabled = true
			end)

			-- REQUEST ONLY. The server owns the relic-cap decision, so nothing
			-- is consumed here -- no prompt disable, no fade, no particle
			-- stop. A refused grab therefore leaves the relic (and the rest
			-- of the pull) fully visible and re-triggerable; the server shows
			-- the "Reached maximum relic cap!" pop.
			proximityPrompt.Triggered:Connect(function(player: Player)
				if not isPublic and player.UserId ~= self.Instance:GetAttribute(Attributes.OwnerId) then
					return
				end
				self._onRelicCollected:Fire(self.Instance.Name)
			end)

			-- ACCEPTED by the server, and only ever for the COLLECTOR: their
			-- own flourish. The disappearance itself — prompt, label, fade —
			-- rides the Collected attribute instead, so every player sees it.
			self._janitor:Add(self._onRelicCollectAccepted:Connect(function()
				ScreenGradientInterfaceController.Signals.OnPulseGradient:Fire(rarityColor)

				local collectedBurst = self.Instance.Handle:FindFirstChild("Collected")
				if collectedBurst then
					for _, emitter in collectedBurst:GetChildren() do
						if emitter:IsA("ParticleEmitter") then
							emitter:Emit(1)
						end
					end
				end
			end))
		end
	end)

	self.Instance.PrimaryPart.RelicParticleAttachment.Parent = self._primaryPart
end

return Relic
