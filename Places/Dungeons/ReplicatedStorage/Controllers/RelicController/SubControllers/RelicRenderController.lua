--!strict
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

local InCombatController = require(ReplicatedStorage.Controllers.InCombatController)
local RelicNetwork = require(ReplicatedStorage.Submodules.Core.Source.Network.Relic)
local RelicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicData)
local getRelicModelTemplate = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Relic.getRelicModelTemplate)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local PickupHoverStyle = require(ReplicatedStorage.Submodules.Core.Shared.Data.PickupHoverStyle)
local fadeSubtree = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.fadeSubtree)
local getRoot = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Character.getRoot)

-- GearDropsRenderController requires this module at load, so this side reaches it
-- lazily: required on first use, once both modules exist.
local gearDropsRenderControllerLazy: any = nil
local function getGearDropsRenderController(): any
	if gearDropsRenderControllerLazy == nil then
		gearDropsRenderControllerLazy = (require :: any)(ReplicatedStorage.Controllers.GearDropsRenderController)
	end
	return gearDropsRenderControllerLazy
end

-- Cross-controller reference. Resolved in Start. Used to mirror the
-- relic hover state into the gear-drop system: hovering a relic dims
-- every gear drop the local player owns, hovering a gear drop dims
-- every relic. Net effect: only ONE pickup-class thing is ever
-- highlighted at a time.

local RelicRenderController = {
	Name = "RelicRenderController",
	Dependencies = { InCombatController } :: { any },
}

--[ Imports ]--

--[ Constants ]--

local VISIBILITY_RELIC_TRANSPARENCY = 0.85
local TWEEN_DURATION = 0.5
-- The hover dim of every OTHER owned pickup on the floor -- ground relic
-- meshes, billboard text, sparkle brightness, vending machines -- reads
-- PickupHoverStyle, the one palette GearDropsRenderController dims from
-- too. Enter / exit is committed HOVER_DEBOUNCE_SECONDS after the last
-- change (see _scheduleAmbienceCommit).
local HOVER_DEBOUNCE_SECONDS = PickupHoverStyle.HoverDebounceSeconds
-- The per-relic applied-dim record is keyed by models that die with the
-- floor: weak keys.
local WEAK_KEYS = { __mode = "k" }

--[ Types ]--

-- Per-model orbit state: the radius eases out from the spawn point, and
-- the bob terms (all 0 today) add a vertical wobble on top.
type SpiralState = {
	currentRadius: number,
	targetRadius: number,
	bobAmplitude: number,
	bobFrequency: number,
	bobPhase: number,
}

type SpinState = {
	spin: Vector3,
	rotation: CFrame,
}

type RenderedRelicPart = {
	part: Model,
	count: number,
}

-- One orbiting set per player: relic name -> model, plus the running
-- total that spaces the orbit and the last-applied visibility flags.
type RenderedRelicEntry = {
	parts: { [string]: RenderedRelicPart },
	count: number,
	visible: boolean,
	hiddenAll: boolean?,
}

--[ Properties ]--

RelicRenderController._orbitClock = 0
RelicRenderController._radiusSpiralState = {} :: { [Model]: SpiralState }
RelicRenderController._localSpinState = {} :: { [Model]: SpinState }
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
-- The hover AMBIENCE (orbit semi-hide, owned machine dim, owned ground
-- relic dim, gear-drop dim) is DERIVED from two inputs -- this side's own
-- hovered relic / rune / stall display, and the gear side's hover
-- (SetExternalHover) -- OR'd into one wanted state, committed
-- HOVER_DEBOUNCE_SECONDS after the last change and applied only where the
-- floor differs from it. Walking across a loot pile used to restore and
-- re-dim every relic on every footfall.
RelicRenderController._ownHoverActive = false
RelicRenderController._ownHoverModel = nil :: Model?
RelicRenderController._externalHoverActive = false
RelicRenderController._ambienceCommitPending = false
-- What the last commit applied: the machine dim, and per ground relic.
RelicRenderController._machinesDimmed = false
RelicRenderController._groundDimApplied = setmetatable({}, WEAK_KEYS) :: any
RelicRenderController._clientRenderedRelics = {} :: { [number]: RenderedRelicEntry }
-- Every player's { [relicName] = count } as the server last told us,
-- keyed by NUMERIC UserId -- the same key RelicController uses, so the
-- two caches can never disagree on a player. Seeded by RelicsSnapshot,
-- kept current by RelicsReplicated deltas.
RelicRenderController._relicRegistry = {} :: { [number]: { [string]: number } }

--[ Private Functions ]--

-- Brings ONE player's orbiting models in line with `relics` ({ [relicName]
-- = count }, or nil when the player is gone): models for relics they no
-- longer hold are destroyed, new ones are cloned in, counts are refreshed.
-- Called per delta and per snapshot entry.
function RelicRenderController._syncPlayerRelics(
	self: typeof(RelicRenderController),
	userId: number,
	relics: { [string]: number }?
)
	if not relics then
		local gone = self._clientRenderedRelics[userId]
		if not gone then
			return
		end
		for _relicName, data in pairs(gone.parts) do
			self._radiusSpiralState[data.part] = nil
			self._localSpinState[data.part] = nil
			data.part:Destroy()
		end
		self._clientRenderedRelics[userId] = nil
		return
	end

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

		local model = template:Clone() :: Model
		local primaryPart = model.PrimaryPart :: BasePart
		primaryPart.Anchored = true
		-- Enforce PrimaryPart invisibility — anchor / adornee part, must
		-- never render. Templates SHOULD author it at Transparency=1, but a
		-- missed authoring shows up as an orange box around the orbiting
		-- relic. Mirrors the same enforcement in Client/Components/Relic.lua
		-- :Start.
		primaryPart.Transparency = 1
		model:AddTag("FloatingRelic")

		entry.parts[relicName] = {
			part = model,
			count = count,
		}

		entry.count += 1

		local hrp = getRoot.fromPlayer(Players:GetPlayerByUserId(userId))
		if hrp then
			model:PivotTo(CFrame.new(hrp.Position + Vector3.new(0, -10, 0)))
			model.Parent = workspace.IgnoreInstances.MagicSpells
		end
	end
end

function RelicRenderController._renderRelics(self: typeof(RelicRenderController), dt: number)
	self._orbitClock += dt * 0.35

	local visible = self:ComputeVisibility()
	-- The full hide (landing, cutscene, the viewer dead) is the same for
	-- every player's set, so it is read once per frame. The viewer has no
	-- character between death and respawn.
	local viewerCharacter = Players.LocalPlayer.Character
	local hideAll = self._landingHidden
		or self._cutsceneHidden
		or (viewerCharacter ~= nil and viewerCharacter:GetAttribute(Attributes.Death) == true)

	for userId, entry in pairs(self._clientRenderedRelics) do
		local player = Players:GetPlayerByUserId(userId)
		if not player then
			continue
		end

		local character = player.Character
		if not character then
			continue
		end

		local hrp = getRoot(character)
		if not hrp then
			continue
		end

		-- Applied ON CHANGE only. This used to also re-run every frame
		-- while any hide was active, which walked every model's
		-- descendants and started a tween per part toward the value it
		-- already held, for as long as a cutscene lasted. A relic that
		-- joins the set mid-hide is caught below, on its first frame.
		if entry.visible ~= visible or entry.hiddenAll ~= hideAll then
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
				self._radiusSpiralState[model] = {
					currentRadius = 0,
					targetRadius = 6.5,
					bobAmplitude = 0,
					bobFrequency = 0,
					bobPhase = 0,
				}
				-- First frame for this model: a fresh clone arrives at its
				-- authored, fully visible look, so a set that is currently
				-- semi-hidden or hidden takes it to that state now.
				if not visible or hideAll then
					self:_applyModelVisibility(model, visible, hideAll)
				end
			end

			local s = self._radiusSpiralState[model]
			s.currentRadius = s.currentRadius + (s.targetRadius - s.currentRadius) * (dt * 2)
			local radius = s.currentRadius

			local angle = self._orbitClock + (2 * math.pi) * (i / total)

			local x = math.cos(angle) * radius
			local z = math.sin(angle) * radius

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

function RelicRenderController.ApplyVisibility(
	self: typeof(RelicRenderController),
	entry: RenderedRelicEntry,
	visible: boolean,
	isDead: boolean
)
	for _, data in pairs(entry.parts) do
		self:_applyModelVisibility(data.part, visible, isDead)
	end
end

-- One orbiting model's visibility: visible, semi-hidden (combat / a prompt
-- up) or fully hidden (landing, cutscene, the viewer dead).
function RelicRenderController._applyModelVisibility(
	_self: typeof(RelicRenderController),
	model: Model,
	visible: boolean,
	isDead: boolean
)
	local transparency = visible and 0 or VISIBILITY_RELIC_TRANSPARENCY
	local targetTransparency = isDead and 1 or transparency

	-- Tween every BasePart's transparency EXCEPT PrimaryPart. The
	-- iterate-all path was added to cover multi-handle relics
	-- (Handle + Handle2), but it pulled PrimaryPart visible too
	-- when targetTransparency was 0 (visible state) — that part
	-- is an animation anchor + BillboardGui adornee and must stay
	-- at Transparency=1 forever.
	fadeSubtree(model, {
		targetTransparency = targetTransparency,
		tweenInfo = TweenInfo.new(TWEEN_DURATION, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out),
		skip = function(descendant)
			return descendant == model.PrimaryPart
		end,
	})

	-- Particles ramp with the model instead of snapping: brightness is
	-- tweened over the same window, so a relic returning after the landing
	-- hide glows back up as it fades in.
	if model.PrimaryPart then
		local attachment = model.PrimaryPart:FindFirstChild("RelicParticleAttachment")
		if attachment then
			local brightnessInfo = TweenInfo.new(TWEEN_DURATION, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out)
			local targets: { [string]: number } = {
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

function RelicRenderController.ComputeVisibility(self: typeof(RelicRenderController))
	if self._combatOverride then
		return false
	end

	if self._promptOverride then
		return false
	end

	return true
end

-- Landing hide (LandingController): true hides every relic model + particle
-- on this client for the fall; false tweens them all back in.
function RelicRenderController.SetLandingHidden(self: typeof(RelicRenderController), hidden: boolean)
	self._landingHidden = hidden
end

function RelicRenderController.SetCombatState(self: typeof(RelicRenderController), inCombat: boolean)
	self._combatOverride = inCombat
end

function RelicRenderController.SetPromptState(self: typeof(RelicRenderController), active: boolean)
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
function RelicRenderController._setOwnedMachinesDimmed(self: typeof(RelicRenderController), dim: boolean)
	-- Already there: nothing to sweep.
	if self._machinesDimmed == dim then
		return
	end
	self._machinesDimmed = dim

	local modelTransparency = dim and PickupHoverStyle.MachineModelTransparency or 0
	local textTransparency = dim and PickupHoverStyle.MachineTextTransparency or 0
	local tweenInfo = PickupHoverStyle.TweenInfo

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
function RelicRenderController._tweenMachineBillboardText(
	_self: typeof(RelicRenderController),
	model: Model,
	tweenInfo: TweenInfo,
	transparency: number
)
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
function RelicRenderController.SetExternalRelicHover(
	self: typeof(RelicRenderController),
	active: boolean,
	skipModel: Model?
)
	self:_setOwnHover(active, skipModel)
end

-- This side's own hover input: a relic / rune prompt, or a stall display
-- through SetExternalRelicHover. Schedules the ambience commit and tells
-- the gear side at once (it debounces its own commit); that call never
-- comes back, so there is no loop.
function RelicRenderController._setOwnHover(self: typeof(RelicRenderController), active: boolean, model: Model?)
	self._ownHoverActive = active
	self._ownHoverModel = if active then model else nil
	self:_scheduleAmbienceCommit()
	if getGearDropsRenderController() then
		getGearDropsRenderController():SetExternalHover(active)
	end
end

-- Schedules a commit HOVER_DEBOUNCE_SECONDS out. Every input change in
-- that window folds into the one commit, which then applies only the
-- difference between what is on the floor and what is wanted.
function RelicRenderController._scheduleAmbienceCommit(self: typeof(RelicRenderController))
	if self._ambienceCommitPending then
		return
	end
	self._ambienceCommitPending = true
	task.delay(HOVER_DEBOUNCE_SECONDS, function()
		self._ambienceCommitPending = false
		self:_commitAmbience()
	end)
end

-- The ambience as it should be RIGHT NOW: the orbit semi-hide, the owned
-- machine dim and the owned ground-relic dim, each applied only where it
-- differs from what the last commit left.
function RelicRenderController._commitAmbience(self: typeof(RelicRenderController))
	local active = self._ownHoverActive or self._externalHoverActive
	local skipModel = if self._ownHoverActive then self._ownHoverModel else nil
	self:SetPromptState(active)
	self:_setOwnedMachinesDimmed(active)
	self:_applyGroundRelicsDim(skipModel, active)
end

-- The dim (or restore) of ONE ground relic: the shared fade walk
-- (fadeSubtree), riding its one pass for the billboard flag and the
-- sparkle set too, where the labels, the meshes and the sparkles used
-- to be three separate lookups / walks.
--   * Every BasePart EXCEPT PrimaryPart, which is an anchor / BillboardGui
--     adornee and must stay invisible regardless of hover / dim state.
--   * The billboard's labels and strokes (name, rarity, the owner / price
--     line from applyOwnerLabel alike) take the TEXT value, and the
--     billboard drops behind geometry while dimmed. The prompt is a
--     custom style (no UI in the model), so every label here is card text.
--   * The sparkle set (Layer / Spark / Shine) is written directly. Active-
--     form relics (Fireworks / Volleyball) destroy their attachment, and a
--     display model may lack the authored set: then there is simply
--     nothing to dim.
function RelicRenderController._applyRelicDim(_self: typeof(RelicRenderController), relic: Model, dim: boolean)
	local primaryPart = relic.PrimaryPart
	fadeSubtree(relic, {
		targetTransparency = if dim then PickupHoverStyle.ModelTransparency else 0,
		textTransparency = if dim then PickupHoverStyle.TextTransparency else 0,
		tweenInfo = PickupHoverStyle.TweenInfo,
		includeGuis = true,
		skip = function(descendant)
			return descendant == primaryPart
		end,
		visit = function(descendant)
			if descendant:IsA("BillboardGui") then
				descendant.AlwaysOnTop = not dim
			elseif descendant:IsA("ParticleEmitter") then
				local restored = PickupHoverStyle.ParticleRestoredBrightness[descendant.Name]
				if restored then
					descendant.Brightness = if dim then PickupHoverStyle.ParticleDimmedBrightness else restored
				end
			end
		end,
	})
end

-- Every owned ground relic, rune and stall display: dimmed while `dim`
-- and not the hovered `skipModel`, restored otherwise -- touching only
-- the ones whose recorded state differs.
function RelicRenderController._applyGroundRelicsDim(
	self: typeof(RelicRenderController),
	skipModel: Model?,
	dim: boolean
)
	-- Ground relics, runes, and the merchant stall displays
	-- (MerchantStallRenderController's client-local clones, which carry the same
	-- RelicName billboard + OwnerId attribute as real drops, so the dim
	-- treats them identically). Tagged lookups rather than a workspace
	-- walk; a tagged template outside workspace is not on the floor.
	local groundDrops: { Instance } = {}
	for _, tag in { "Relic", "ShopRelicDisplay" } do
		for _, tagged in CollectionService:GetTagged(tag) do
			if tagged:IsA("Model") and tagged:IsDescendantOf(workspace) then
				table.insert(groundDrops, tagged)
			end
		end
	end
	for _, relic in groundDrops do
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
		local primaryPart = (relic :: Model).PrimaryPart
		if not (primaryPart and primaryPart:FindFirstChild("RelicName")) then
			continue
		end

		local wanted = dim and relic ~= skipModel
		local applied = self._groundDimApplied[relic] == true
		if wanted == applied then
			continue
		end
		self:_applyRelicDim(relic :: Model, wanted)
		self._groundDimApplied[relic] = if wanted then true else nil
	end
end

-- Called by GearDropsRenderController when a gear drop is hovered /
-- released so the relic side participates in the unified hover state:
-- orbiting relics semi-hide, and every owned ground relic and machine
-- dims (no model to skip — no relic is the "hovered" one in this path).
-- The caller has already debounced; this records the input and schedules
-- the commit, and never calls back.
--
-- Symmetric counterpart: RelicRenderController calls
-- `GearDropsRenderController:SetExternalHover(...)` from _setOwnHover.
function RelicRenderController.SetExternalHover(self: typeof(RelicRenderController), active: boolean)
	self._externalHoverActive = active
	self:_scheduleAmbienceCommit()
end

--[ Initializers ]--

-- Mirror the local character's CutscenePlaying into _cutsceneHidden, on
-- every character (re-bound per respawn).
function RelicRenderController._watchViewerCutscene(self: typeof(RelicRenderController))
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

function RelicRenderController.Start(self: typeof(RelicRenderController))
	self:_watchViewerCutscene()

	RunService.RenderStepped:Connect(function(...)
		self:_renderRelics(...)
	end)

	-- The whole table, once, on join: players missing from it lose their
	-- orbit, everyone in it is reconciled.
	RelicNetwork.RelicsSnapshot.On(function(snapshot)
		local registry: { [number]: { [string]: number } } = {}
		for userId, entry in snapshot do
			registry[userId] = entry.Registry
		end
		self._relicRegistry = registry

		for userId in pairs(self._clientRenderedRelics) do
			if not registry[userId] then
				self:_syncPlayerRelics(userId, nil)
			end
		end
		for userId, relics in registry do
			self:_syncPlayerRelics(userId, relics)
		end
	end)

	-- One player's relics changed (or they left: Removed).
	RelicNetwork.RelicsReplicated.On(function(payload)
		if payload.Removed then
			self._relicRegistry[payload.UserId] = nil
			self:_syncPlayerRelics(payload.UserId, nil)
			return
		end
		self._relicRegistry[payload.UserId] = payload.Registry
		self:_syncPlayerRelics(payload.UserId, payload.Registry)
	end)

	InCombatController.Signals.InCombatStatusChanged:Connect(function(inCombat: boolean)
		self:SetCombatState(inCombat)
	end)

	local relicHighlight = Instance.new("Highlight")
	relicHighlight.Name = "RelicHighlight"
	relicHighlight.FillColor = Color3.fromRGB(255, 255, 255)
	relicHighlight.OutlineColor = Color3.fromRGB(255, 255, 255)
	relicHighlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	relicHighlight.Parent = nil

	-- The relic (or rune) whose prompt is up right now, and the watchers
	-- that end the hover if the relic goes away by any route other than
	-- the prompt service's own PromptHidden. Disabling a shown prompt does
	-- fire PromptHidden, but a model destroyed or untagged under a live
	-- hover does not -- and a Collected relic must lose its hover THIS
	-- frame on every screen, not whenever the prompt service gets round to
	-- it. Whichever path fires first wins; the rest are no-ops.
	local hoveredModel: Model? = nil
	local hoverWatchers: { RBXScriptConnection } = {}

	local function endHover(model: Model)
		if hoveredModel ~= model then
			return
		end
		hoveredModel = nil
		for _, connection in hoverWatchers do
			connection:Disconnect()
		end
		table.clear(hoverWatchers)

		relicHighlight.Adornee = nil
		relicHighlight.Parent = nil

		-- A CLAIMED relic keeps its label off and its scale where it is:
		-- the pickup disables the prompt, which lands us here, and putting
		-- the label back would float a name over a relic that is fading
		-- out from under it.
		local collected = model:GetAttribute(Attributes.Collected) == true
		local primaryPart = model.PrimaryPart
		local relicName = if primaryPart then primaryPart:FindFirstChild("RelicName") :: BillboardGui? else nil
		if not collected and relicName then
			relicName.Enabled = true

			local relicScale = model:FindFirstChild("RelicScale") :: NumberValue?
			if relicScale then
				TweenService:Create(
					relicScale,
					TweenInfo.new(0.5, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out),
					{ Value = 1.5 }
				):Play()
			end
		end

		relicHighlight.FillTransparency = 1

		-- The ambience -- orbit semi-hide, owned machines, owned ground
		-- relics, the gear-drop side -- comes back through the debounced
		-- commit (the now-unhovered model's RelicName.Enabled = true is set
		-- inline above).
		self:_setOwnHover(false, nil)
	end

	ProximityPromptService.PromptShown:Connect(function(prompt: ProximityPrompt)
		local model = prompt:FindFirstAncestorOfClass("Model")

		-- Runes share the whole relic hover treatment (billboard hidden,
		-- highlight, scale-up) -- they are relics as far as presentation goes.
		if model and model:HasTag("Relic") then
			-- Already claimed: nothing here is takeable, so no hover. A
			-- disabled prompt cannot be shown, but the attribute can land in
			-- the same step as the prompt service's decision.
			if model:GetAttribute(Attributes.Collected) == true then
				return
			end

			-- One hover at a time. The prompt service normally hides the old
			-- prompt before showing the next, but a missed PromptHidden must
			-- not leave the previous relic's ambience stuck on.
			if hoveredModel and hoveredModel ~= model then
				endHover(hoveredModel)
			end
			hoveredModel = model

			-- The explicit "relic gone" routes: claimed (Collected replicates
			-- to every client the instant someone takes it, and the pull's
			-- other offers are marked with it), destroyed, or untagged.
			table.insert(
				hoverWatchers,
				model:GetAttributeChangedSignal(Attributes.Collected):Connect(function()
					if model:GetAttribute(Attributes.Collected) == true then
						endHover(model)
					end
				end)
			)
			table.insert(
				hoverWatchers,
				model.Destroying:Connect(function()
					endHover(model)
				end)
			)

			local handle = assert(model:FindFirstChild("Handle"), "Relic model has no Handle")
			relicHighlight.Adornee = handle
			relicHighlight.Parent = handle

			local primaryPart = model.PrimaryPart
			local relicName = if primaryPart then primaryPart:FindFirstChild("RelicName") :: BillboardGui? else nil
			if relicName then
				relicName.Enabled = false

				TweenService:Create(
					model:FindFirstChild("RelicScale") :: NumberValue,
					TweenInfo.new(0.5, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out),
					{ Value = 2 }
				):Play()
			end

			TweenService:Create(
				relicHighlight,
				TweenInfo.new(0.5, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out),
				{ FillTransparency = 0.75 }
			):Play()

			-- Everything else steps back through the debounced commit:
			-- orbiting relics semi-hide, owned machines dim, every OTHER
			-- owned ground relic dims (`model`, the hovered one, is skipped
			-- -- its RelicName was already Enabled=false above), and the
			-- gear-drop side dims in lockstep. Unified hover state means
			-- only ONE pickup-class thing is highlighted at a time.
			self:_setOwnHover(true, model)
		end
	end)

	ProximityPromptService.PromptHidden:Connect(function(prompt: ProximityPrompt)
		local model = prompt:FindFirstAncestorOfClass("Model")

		if model and model:HasTag("Relic") then
			endHover(model)
		end
	end)

	-- Untagged under a live hover (the component's teardown, or a relic
	-- re-purposed by its own logic): same exit as a destroy.
	for _, tag in { "Relic" } do
		CollectionService:GetInstanceRemovedSignal(tag):Connect(function(obj)
			if obj:IsA("Model") then
				endHover(obj)
			end
		end)
	end
end

return RelicRenderController
