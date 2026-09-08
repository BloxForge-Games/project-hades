--[[
     Author(s): 
     Module: RelicRenderController.lua
     Description:
]]

--[ Roblox Services ]--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ProximityPromptService = game:GetService("ProximityPromptService")
local CollectionService = game:GetService("CollectionService")

--[ Exports & Types & Defaults ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local RelicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicData)
local getRelicModelTemplate = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Relic.getRelicModelTemplate)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)

local RelicService
local InCombatController

-- Cross-controller reference. Resolved in KnitStart. Used to mirror the
-- relic hover state into the gear-drop system: hovering a relic dims
-- every gear drop the local player owns, hovering a gear drop dims
-- every relic. Net effect: only ONE pickup-class thing is ever
-- highlighted at a time.
local GearDropsRenderController

local RelicRenderController = Knit.CreateController({
	Name = "RelicRenderController",
	Client = {},
})

--[ Imports ]--

--[ Constants ]--

local VISIBILITY_RELIC_TRANSPARENCY = 0.85
local TWEEN_DURATION = 0.5
-- Hover dim of every OTHER owned ground relic: model parts, and the
-- billboard text separately (text reads through a lighter dim than mesh).
local TOGGLE_TRANSPARENCY = 0.7
local TOGGLE_TEXT_TRANSPARENCY = 0.8
local VENDING_MACHINE_TRANSPARENCY = 0.75

-- Particle brightness targets used by the dim/restore loop on ground
-- relics. Promoted from inline magic numbers so the unified hover
-- entry point (`_applyGroundRelicsDim`) can swap between them.
local PARTICLE_DIMMED_BRIGHTNESS = 0.15
local PARTICLE_RESTORED_BRIGHTNESS_LAYER = 4
local PARTICLE_RESTORED_BRIGHTNESS_SPARK = 4
local PARTICLE_RESTORED_BRIGHTNESS_SHINE = 1

--[ Properties ]--

RelicRenderController._orbitClock = 0
RelicRenderController._radiusSpiralState = {}
RelicRenderController._localSpinState = {}
RelicRenderController._combatOverride = false
-- True from the run-transition / landing start until the landing cutscene
-- releases: EVERY orbiting relic on this screen (all players') is fully
-- hidden -- models AND particles -- the same way a dead viewer's are.
RelicRenderController._landingHidden = false
-- True while the VIEWER's own character has CutscenePlaying (every cutscene
-- sets it: landing, encounter intro / outro, boss phase). Same full-hide as
-- the landing flag; the two are OR'd.
RelicRenderController._cutsceneHidden = false
RelicRenderController._promptOverride = false
RelicRenderController._defaultVisible = true
RelicRenderController._relicHighlight = Instance.new("Highlight")
RelicRenderController._clientRenderedRelics = {}
RelicRenderController._relics = {}
RelicRenderController._machines = {}

--[ Private Functions ]--

function RelicRenderController:_renderRelics(dt: number)
	self._orbitClock += dt * 0.35

	local visible = self:ComputeVisibility()

	for userId, entry in pairs(self._clientRenderedRelics) do
		local player = Players:GetPlayerByUserId(userId)
		if not player then
			continue
		end

		local character = player.Character
		if not character then
			continue
		end

		local hrp = character:FindFirstChild("HumanoidRootPart")
		if not hrp then
			continue
		end

		local hideAll = self._landingHidden
			or self._cutsceneHidden
			or Players.LocalPlayer.Character:GetAttribute(Attributes.Death) == true
		if entry.visible ~= visible or entry.hiddenAll ~= hideAll or hideAll then
			entry.visible = visible
			entry.hiddenAll = hideAll
			self:ApplyVisibility(entry, visible, hideAll)
		end

		local center = hrp.Position
		local total = entry.count
		local i = 0

		for _, data in pairs(entry.parts) do
			local model = data.part
			i += 1

			if not self._radiusSpiralState[model] then
				self._radiusSpiralState[model] = { currentRadius = 0, targetRadius = 6.5 }
			end

			local s = self._radiusSpiralState[model]
			s.currentRadius = s.currentRadius + (s.targetRadius - s.currentRadius) * (dt * 2)
			local radius = s.currentRadius

			local angle = self._orbitClock + (2 * math.pi) * (i / total)

			local x = math.cos(angle) * radius
			local z = math.sin(angle) * radius

			if not s.bobAmplitude then
				s.bobAmplitude = 0
				s.bobFrequency = 0
				s.bobPhase = 0
			end

			local bob = math.sin(self._orbitClock * s.bobFrequency + s.bobPhase) * s.bobAmplitude
			local worldPos = center + Vector3.new(x, bob, z)

			if not self._localSpinState[model] then
				self._localSpinState[model] = {
					spin = Vector3.new(0.5, 0.5, 0.5),
					rotation = CFrame.identity,
				}
			end

			local spin = self._localSpinState[model]
			spin.rotation = spin.rotation * CFrame.Angles(spin.spin.X * dt, spin.spin.Y * dt, spin.spin.Z * dt)

			local targetCFrame = CFrame.new(worldPos) * spin.rotation
			model:PivotTo(model:GetPivot():Lerp(targetCFrame, 0.15))
		end
	end
end

--[ Public Functions ]--

function RelicRenderController:ApplyVisibility(entry: { parts: { part: Model } }, visible: boolean, isDead: boolean)
	for _, data in pairs(entry.parts) do
		local model = data.part

		local transparency = visible and 0 or VISIBILITY_RELIC_TRANSPARENCY
		local targetTransparency = isDead and 1 or transparency

		-- Tween every BasePart's transparency EXCEPT PrimaryPart. The
		-- iterate-all path was added to cover multi-handle relics
		-- (Handle + Handle2), but it pulled PrimaryPart visible too
		-- when targetTransparency was 0 (visible state) — that part
		-- is an animation anchor + BillboardGui adornee and must stay
		-- at Transparency=1 forever.
		for _, descendant in model:GetDescendants() do
			if descendant:IsA("BasePart") and descendant ~= model.PrimaryPart then
				TweenService:Create(
					descendant,
					TweenInfo.new(TWEEN_DURATION, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out),
					{ Transparency = targetTransparency }
				):Play()
			end
		end

		-- Particles ramp with the model instead of snapping: brightness is
		-- tweened over the same window, so a relic returning after the landing
		-- hide glows back up as it fades in.
		if model.PrimaryPart then
			local attachment = model.PrimaryPart:FindFirstChild("RelicParticleAttachment")
			if attachment then
				local brightnessInfo = TweenInfo.new(TWEEN_DURATION, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out)
				local targets = {
					Layer = isDead and 0 or (visible and 4 or 0.05),
					Spark = isDead and 0 or (visible and 4 or 0.05),
					Shine = isDead and 0 or (visible and 1 or 0.05),
				}
				for emitterName, brightness in targets do
					local emitter = attachment:FindFirstChild(emitterName)
					if emitter and emitter:IsA("ParticleEmitter") then
						TweenService:Create(emitter, brightnessInfo, { Brightness = brightness }):Play()
					end
				end
			end
		end
	end
end

function RelicRenderController:ComputeVisibility()
	if self._combatOverride then
		return false
	end

	if self._promptOverride then
		return false
	end

	return self._defaultVisible
end

-- Landing hide (LandingController): true hides every relic model + particle
-- on this client for the fall; false tweens them all back in.
function RelicRenderController:SetLandingHidden(hidden: boolean)
	self._landingHidden = hidden
end

function RelicRenderController:SetCombatState(inCombat: boolean)
	self._combatOverride = inCombat
end

function RelicRenderController:SetPromptState(active: boolean)
	self._promptOverride = active
end

-- Dims (or restores) the ground-relic UI for every Relic-tagged model
-- the local player owns. Used by both the inline PromptShown/Hidden
-- handlers and the external SetExternalHover entry point — same body,
-- different `skipModel` and `dim` inputs.
--
-- `skipModel` skips the hovered relic during a dim — its RelicName is
-- handled separately by the inline code (BillboardGui.Enabled = false).
-- Pass nil to apply the dim/restore to ALL owned ground relics.
-- Dims (or restores) every vending machine the local player owns — the
-- hover treatment's third leg alongside ground-relic dim and gear dim.
-- Extracted from the inline PromptShown/PromptHidden blocks so external
-- hover sources (merchant pedestals) reuse it instead of copying it.
--
-- The Miniboss / Boss reward chest ships the SAME billboard rig
-- (VendingMachineName / NameText / VendingMachineText, see
-- Components/EncounterChest), so its text dims here too. Only the text:
-- the chest meshes stay put (an opened chest is scenery, not a pickup).
function RelicRenderController:_setOwnedMachinesDimmed(dim: boolean)
	local modelTransparency = dim and 0.5 or 0
	local textTransparency = dim and VENDING_MACHINE_TRANSPARENCY or 0
	local tweenInfo = TweenInfo.new(TWEEN_DURATION, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out)

	for _, machine in pairs(workspace:QueryDescendants(".RelicMachine")) do
		if machine:GetAttribute("OwnerId") ~= Players.LocalPlayer.UserId then
			continue
		end

		TweenService:Create(machine.Model, tweenInfo, { Transparency = modelTransparency }):Play()
		self:_tweenMachineBillboardText(machine, tweenInfo, textTransparency)
	end

	for _, chest in pairs(workspace:QueryDescendants(".EncounterChest")) do
		if chest:GetAttribute("OwnerId") ~= Players.LocalPlayer.UserId then
			continue
		end
		self:_tweenMachineBillboardText(chest, tweenInfo, textTransparency)
	end
end

-- The NameText / VendingMachineText pair (and their strokes) of a
-- machine-style billboard under `model.PrimaryPart`. Guarded: the chest's
-- billboard replicates progressively and can be missing for a frame.
function RelicRenderController:_tweenMachineBillboardText(model: Model, tweenInfo: TweenInfo, transparency: number)
	local primary = model.PrimaryPart
	local billboard = primary and primary:FindFirstChild("VendingMachineName")
	local nameFrame = billboard and billboard:FindFirstChild("Frame")
	if not nameFrame then
		return
	end
	for _, labelName in { "NameText", "VendingMachineText" } do
		local label = nameFrame:FindFirstChild(labelName)
		if not (label and label:IsA("TextLabel")) then
			continue
		end
		TweenService:Create(label, tweenInfo, { TextTransparency = transparency }):Play()
		local stroke = label:FindFirstChild("UIStroke")
		if stroke then
			TweenService:Create(stroke, tweenInfo, { Transparency = transparency }):Play()
		end
	end
end

-- The whole hover AMBIENCE — orbit semi-hide (prompt state), owned
-- machine dim, owned ground relic dim, gear-drop dim — for hover sources
-- OUTSIDE this controller's own Relic/Rune prompt handlers. The merchant
-- pedestals use this: their clones are not tagged Relic (that would
-- mount the pickup component), so the inline handlers never see them.
-- The hovered thing's own highlight/scale stays the CALLER's job.
function RelicRenderController:SetExternalRelicHover(active: boolean, skipModel: Model?)
	self:SetPromptState(active)
	self:_setOwnedMachinesDimmed(active)
	self:_applyGroundRelicsDim(skipModel, active)
	if GearDropsRenderController then
		GearDropsRenderController:SetExternalHover(active)
	end
end

function RelicRenderController:_applyGroundRelicsDim(skipModel: Model?, dim: boolean)
	local targetTransparency = dim and TOGGLE_TRANSPARENCY or 0
	local textTransparency = dim and TOGGLE_TEXT_TRANSPARENCY or 0
	local layerBrightness = dim and PARTICLE_DIMMED_BRIGHTNESS or PARTICLE_RESTORED_BRIGHTNESS_LAYER
	local sparkBrightness = dim and PARTICLE_DIMMED_BRIGHTNESS or PARTICLE_RESTORED_BRIGHTNESS_SPARK
	local shineBrightness = dim and PARTICLE_DIMMED_BRIGHTNESS or PARTICLE_RESTORED_BRIGHTNESS_SHINE
	local alwaysOnTop = not dim

	local tweenInfo = TweenInfo.new(TWEEN_DURATION, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out)

	local groundDrops = workspace:QueryDescendants(".Relic")
	for _, rune in pairs(workspace:QueryDescendants(".Rune")) do
		table.insert(groundDrops, rune)
	end
	-- Merchant stall displays (EventController's client-local clones).
	-- They carry the same RelicName billboard + OwnerId attribute as
	-- real drops, so the dim body below treats them identically.
	for _, stall in pairs(workspace:QueryDescendants(".ShopRelicDisplay")) do
		table.insert(groundDrops, stall)
	end
	for _, relic in pairs(groundDrops) do
		if relic == skipModel then
			continue
		end
		-- Already claimed: its own pickup fade owns its Transparency now.
		-- Without this the restore leg fought that fade and won — disabling
		-- the prompt on pickup fires PromptHidden, whose restore tweened
		-- every owned relic back to fully opaque, so a collected relic just
		-- sat there looking untouched until the server destroyed it.
		if relic:GetAttribute(Attributes.Collected) == true then
			continue
		end
		-- The owner filter only exists so this client never un-hides loot
		-- it cannot see. A PUBLIC drop (one a player dropped: no OwnerId,
		-- PublicDrop + DroppedByName instead) is visible to everyone, so
		-- it dims on everyone's client -- same rule GearDropsRenderController
		-- uses. Without it a dropped relic never dimmed on any hover.
		if
			relic:GetAttribute(Attributes.PublicDrop) ~= true
			and relic:GetAttribute("OwnerId") ~= Players.LocalPlayer.UserId
		then
			continue
		end
		if not (relic.PrimaryPart and relic.PrimaryPart:FindFirstChild("RelicName")) then
			continue
		end

		relic.PrimaryPart.RelicName.AlwaysOnTop = alwaysOnTop
		TweenService
			:Create(relic.PrimaryPart.RelicName.Frame.NameText, tweenInfo, { TextTransparency = textTransparency })
			:Play()
		TweenService
			:Create(relic.PrimaryPart.RelicName.Frame.NameText.UIStroke, tweenInfo, { Transparency = textTransparency })
			:Play()
		TweenService
			:Create(relic.PrimaryPart.RelicName.Frame.RarityText, tweenInfo, { TextTransparency = textTransparency })
			:Play()
		TweenService
			:Create(
				relic.PrimaryPart.RelicName.Frame.RarityText.UIStroke,
				tweenInfo,
				{ Transparency = textTransparency }
			)
			:Play()
		-- The owner / price line (Shared/Functions/Drop/applyOwnerLabel)
		-- dims with the rest of the card.
		local userText = relic.PrimaryPart.RelicName.Frame:FindFirstChild("UserText")
		if userText then
			TweenService:Create(userText, tweenInfo, { TextTransparency = textTransparency }):Play()
			local userStroke = userText:FindFirstChild("UIStroke")
			if userStroke then
				TweenService:Create(userStroke, tweenInfo, { Transparency = textTransparency }):Play()
			end
		end
		-- Tween every BasePart EXCEPT PrimaryPart. PrimaryPart is an
		-- anchor / BillboardGui adornee — must stay invisible
		-- regardless of hover/dim state.
		--
		-- RUNES ONLY: a rune model carries extra geometry (a union) nested
		-- UNDER its Handle. Dimming both to the same value puts two coplanar
		-- semi-transparent surfaces on top of each other, and Roblox's
		-- transparency sorting flickers between them. So while DIMMED the
		-- nested parts go fully invisible and only the Handle carries the
		-- dim; on restore everything returns to 0 together.
		local isRune = CollectionService:HasTag(relic, TagList.Rune)
		local handle = relic:FindFirstChild("Handle")
		for _, descendant in relic:GetDescendants() do
			if descendant:IsA("BasePart") and descendant ~= relic.PrimaryPart then
				local nestedUnderHandle = isRune
					and handle
					and descendant ~= handle
					and descendant:IsDescendantOf(handle)
				local partTransparency = if nestedUnderHandle and dim then 1 else targetTransparency
				TweenService:Create(descendant, tweenInfo, { Transparency = partTransparency }):Play()
			end
		end

		-- Guarded lookup: active-form relics (Fireworks / Volleyball)
		-- destroy their attachment, and a display model missing the
		-- authored set should skip the sparkle dim, not error.
		local relicHandle = relic:FindFirstChild("Handle")
		local particleAttachment = relicHandle and relicHandle:FindFirstChild("RelicParticleAttachment")
		if particleAttachment then
			particleAttachment.Layer.Brightness = layerBrightness
			particleAttachment.Spark.Brightness = sparkBrightness
			particleAttachment.Shine.Brightness = shineBrightness
		end
	end
end

-- Called by GearDropsRenderController when a gear drop's prompt is
-- shown / hidden so the relic side participates in the unified hover
-- state. When `active` is true: hide orbiting relics (SetPromptState)
-- AND dim every ground relic the local player owns (no model to skip
-- — no relic is the "hovered" one in this path). When false: restore
-- both.
--
-- Symmetric counterpart: RelicRenderController calls
-- `GearDropsRenderController:SetExternalHover(...)` from its own
-- PromptShown / PromptHidden handlers below.
function RelicRenderController:SetExternalHover(active: boolean)
	self:SetPromptState(active)
	self:_applyGroundRelicsDim(nil :: any, active)
	-- Machines too, so a gear hover reads exactly like a relic hover from
	-- the player's side: everything else in the room steps back.
	self:_setOwnedMachinesDimmed(active)
end

--[ Initializers ]--

-- Mirror the local character's CutscenePlaying into _cutsceneHidden, on
-- every character (re-bound per respawn).
function RelicRenderController:_watchViewerCutscene()
	local function bind(character: Model)
		local function refresh()
			self._cutsceneHidden = character:GetAttribute(Attributes.CutscenePlaying) == true
		end
		character:GetAttributeChangedSignal(Attributes.CutscenePlaying):Connect(refresh)
		refresh()
	end
	if Players.LocalPlayer.Character then
		bind(Players.LocalPlayer.Character)
	end
	Players.LocalPlayer.CharacterAdded:Connect(bind)
end

function RelicRenderController:KnitStart()
	self:_watchViewerCutscene()
	RelicService = Knit.GetService("RelicService")
	InCombatController = Knit.GetController("InCombatController")
	-- Cross-controller resolve for the unified hover state. Knit guarantees
	-- all controllers are constructed before KnitStart runs, so this is
	-- always non-nil here. Used in PromptShown / PromptHidden below.
	GearDropsRenderController = Knit.GetController("GearDropsRenderController")

	self._relicHighlight.Name = "RelicHighlight"
	self._relicHighlight.FillColor = Color3.fromRGB(255, 255, 255)
	self._relicHighlight.OutlineColor = Color3.fromRGB(255, 255, 255)
	self._relicHighlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	self._relicHighlight.FillTransparency = 1
	self._relicHighlight.Parent = nil

	for _, relic in ipairs(CollectionService:GetTagged("Relic")) do
		self._relics[relic] = true
	end

	for _, machine in ipairs(CollectionService:GetTagged("RelicMachine")) do
		self._machines[machine] = true
	end

	CollectionService:GetInstanceAddedSignal("Relic"):Connect(function(obj)
		self._relics[obj] = true
	end)

	CollectionService:GetInstanceRemovedSignal("Relic"):Connect(function(obj)
		self._relics[obj] = nil
	end)

	CollectionService:GetInstanceAddedSignal("RelicMachine"):Connect(function(obj)
		self._machines[obj] = true
	end)

	CollectionService:GetInstanceRemovedSignal("RelicMachine"):Connect(function(obj)
		self._machines[obj] = nil
	end)

	RunService.RenderStepped:Connect(function(...)
		self:_renderRelics(...)
	end)

	RelicService.OnReplicateRelics:Connect(
		function(_: number, relicRegistry: { [RelicNames.RelicNames]: number }, _: { RelicNames.RelicNames })
			self._relicRegistry = relicRegistry

			-- Remove players that no longer exist in registry
			for userId, entry in pairs(self._clientRenderedRelics) do
				if not relicRegistry[userId] then
					print("Cleaning up relics for player", userId)

					for _relicName, data in pairs(entry.parts) do
						self._radiusSpiralState[data.part] = nil
						self._localSpinState[data.part] = nil
						data.part:Destroy()
					end

					self._clientRenderedRelics[userId] = nil
				end
			end

			for userId, relics in pairs(relicRegistry) do
				self._clientRenderedRelics[userId] = self._clientRenderedRelics[userId]
					or {
						parts = {},
						count = 0,
						visible = self:ComputeVisibility(),
					}

				local entry = self._clientRenderedRelics[userId]

				-- Remove relics that no longer exist
				for relicName, data in pairs(entry.parts) do
					if not relics[relicName] then
						data.part:Destroy()
						self._radiusSpiralState[data.part] = nil
						self._localSpinState[data.part] = nil
						entry.parts[relicName] = nil
						entry.count -= 1
					end
				end

				-- Add new relics
				for relicName, count in pairs(relics) do
					if entry.parts[relicName] then
						entry.parts[relicName].count = count
						continue
					end

					local rarity = RelicData[relicName] and RelicData[relicName].rarity
					if not rarity then
						warn("Relic data not found for", relicName)
						continue
					end

					local template = getRelicModelTemplate(relicName, rarity)
					if not template then
						warn("Relic template not found for", relicName)
						continue
					end

					local model = template:Clone()
					model.PrimaryPart.Anchored = true
					-- Enforce PrimaryPart invisibility — anchor / adornee
					-- part, must never render. Templates SHOULD author
					-- it at Transparency=1, but a missed authoring
					-- shows up as an orange box around the orbiting
					-- relic. Mirrors the same enforcement in
					-- Client/Components/Relic.lua :Start.
					model.PrimaryPart.Transparency = 1
					model:AddTag("FloatingRelic")

					entry.parts[relicName] = {
						part = model,
						count = count,
					}

					entry.count += 1

					local player = Players:GetPlayerByUserId(userId)

					if player and player.Character then
						local hrp = player.Character:FindFirstChild("HumanoidRootPart")
						if hrp then
							model:PivotTo(CFrame.new(hrp.Position + Vector3.new(0, -10, 0)))
							model.Parent = workspace.IgnoreInstances.MagicSpells
						end
					end
				end
			end
		end
	)

	InCombatController.Signals.InCombatStatusChanged:Connect(function(inCombat: boolean)
		self:SetCombatState(inCombat)
	end)

	local relicHighlight = Instance.new("Highlight")
	relicHighlight.Name = "RelicHighlight"
	relicHighlight.FillColor = Color3.fromRGB(255, 255, 255)
	relicHighlight.OutlineColor = Color3.fromRGB(255, 255, 255)
	relicHighlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	relicHighlight.Parent = nil

	ProximityPromptService.PromptShown:Connect(function(prompt: ProximityPrompt)
		local model = prompt:FindFirstAncestorOfClass("Model")

		-- Runes share the whole relic hover treatment (billboard hidden,
		-- highlight, scale-up) -- they are relics as far as presentation goes.
		if model and (model:HasTag("Relic") or model:HasTag("Rune")) then
			self:SetPromptState(true)

			relicHighlight.Adornee = model.Handle
			relicHighlight.Parent = model.Handle

			if model and model.PrimaryPart and model.PrimaryPart:FindFirstChild("RelicName") then
				model.PrimaryPart.RelicName.Enabled = false

				TweenService:Create(
					model.RelicScale,
					TweenInfo.new(0.5, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out),
					{ Value = 2 }
				):Play()
			end

			TweenService:Create(
				relicHighlight,
				TweenInfo.new(0.5, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out),
				{ FillTransparency = 0.75 }
			):Play()

			self:_setOwnedMachinesDimmed(true)

			-- Dim every OTHER owned ground relic. Skips `model` (the
			-- hovered one) — its RelicName was already Enabled=false
			-- via the inline block above.
			self:_applyGroundRelicsDim(model, true)

			-- Cross-system: notify the gear-drop side so all owned
			-- gear drops dim in lockstep. Unified hover state means
			-- only ONE pickup-class thing is highlighted at a time.
			if GearDropsRenderController then
				GearDropsRenderController:SetExternalHover(true)
			end
		end
	end)

	ProximityPromptService.PromptHidden:Connect(function(prompt: ProximityPrompt)
		local model = prompt:FindFirstAncestorOfClass("Model")

		if model and (model:HasTag("Relic") or model:HasTag("Rune")) then
			self:SetPromptState(false)

			relicHighlight.Adornee = nil
			relicHighlight.Parent = nil

			-- A CLAIMED relic keeps its label off and its scale where it is:
			-- the pickup disables the prompt, which lands us here, and putting
			-- the label back would float a name over a relic that is fading
			-- out from under it.
			local collected = model:GetAttribute(Attributes.Collected) == true
			if not collected and model.PrimaryPart and model.PrimaryPart:FindFirstChild("RelicName") then
				model.PrimaryPart.RelicName.Enabled = true

				TweenService:Create(
					model.RelicScale,
					TweenInfo.new(0.5, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out),
					{ Value = 1.5 }
				):Play()
			end

			relicHighlight.FillTransparency = 1

			self:_setOwnedMachinesDimmed(false)

			-- Restore every owned ground relic. No skip — original
			-- restore behavior walked the full set (the now-unhovered
			-- model is restored alongside everything else; its
			-- RelicName.Enabled = true is set inline above).
			self:_applyGroundRelicsDim(nil :: any, false)

			-- Cross-system: restore the gear-drop side.
			if GearDropsRenderController then
				GearDropsRenderController:SetExternalHover(false)
			end
		end
	end)
end

function RelicRenderController:KnitInit() end

return RelicRenderController
