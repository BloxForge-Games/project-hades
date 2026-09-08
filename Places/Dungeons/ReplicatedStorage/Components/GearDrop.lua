--[[
     Module: GearDrop.lua (Client-side component)
     Description:
     Per-drop client-side counterpart to Server/Components/GearDrop.lua.
     Both attach to the same TagList.GearDrop model that GearDropService
     spawns server-side under workspace.IgnoreInstances.GearDrops.

 
]]

--[ Roblox Services ]--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

--[ Imports ]--

local Component = require(ReplicatedStorage.Submodules.Core.Packages.Component)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local JanitorAdder = require(ReplicatedStorage.Submodules.Core.Source.ComponentExtensions.JanitorAdder)
local CommAdder = require(ReplicatedStorage.Submodules.Core.Source.ComponentExtensions.CommAdder)
local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local WeaponData = require(ReplicatedStorage.Submodules.Core.Shared.Data.WeaponData)
local ArmorPieceData = require(ReplicatedStorage.Submodules.Core.Shared.Data.ArmorPieceData)
local GearTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.GearTypes)
local RarityColors = require(ReplicatedStorage.Submodules.Core.Shared.Data.RarityColors)
local getGearIdleScale = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Gear.getGearIdleScale)
local lootSound = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.lootSound)
local arcPath = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Drop.arcPath)
local applyOwnerLabel = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Drop.applyOwnerLabel)
local ScreenSizes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ScreenSizes)

local ScreenSizeController
local GearDropsRenderController

Knit.OnStart()
	:andThen(function()
		ScreenSizeController = Knit.GetController("ScreenSizeController")
		GearDropsRenderController = Knit.GetController("GearDropsRenderController")
	end)
	:catch(warn)
--[ Constants ]--

-- Bezier curve tuning. Same shape as Drop.lua — apex above origin, land
-- offset on the ground. The X/Z scatter range lets multiple simultaneous
-- drops separate visually instead of stacking.
local BEZIER_STEP = 0.02 -- progress increment per frame (50 frames total = ~0.85s arc)
local BEZIER_APEX_Y_MIN = 8
local BEZIER_APEX_Y_MAX = 16

-- Bob + spin tuning for the resting state.
local BOB_AMPLITUDE_MIN = 0.15
local BOB_AMPLITUDE_MAX = 0.35
local BOB_CYCLE_DURATION_MIN = 2.0
local BOB_CYCLE_DURATION_MAX = 3.5

-- Y-axis spin rate, randomized per drop within this range so different
-- drops rotate at slightly different paces (no two side-by-side drops
-- spin in perfect lockstep). Sign is randomized too — half the drops
-- spin clockwise, half counter-clockwise — for a touch of variety.
local SPIN_RAD_PER_SEC_MIN = math.rad(10)
local SPIN_RAD_PER_SEC_MAX = math.rad(25)

-- ProximityPrompt tuning.
local PROMPT_MAX_DISTANCE = 5
local PROMPT_KEY = Enum.KeyCode.F
local PROMPT_STYLE_ATTRIBUTE = "GearDrop"

-- Drops always spawn at level 1 today. Pulled from the GearLevel attribute
-- on the carrier (controller sets it) so when variable-level drops land
-- later (e.g., harder dungeons rolling higher-level gear), only the
-- controller / service change is needed — the component reads whatever's
-- on the attribute.
local DEFAULT_GEAR_LEVEL = 1

-- Fade-out duration on expire.
local FADE_DURATION = 0.5

-- Idle scale resolver now lives in
-- Shared/Functions/Gear/getGearIdleScale. The component still applies
-- the initial ScaleTo on Construct so armor drops don't pop in at 1×
-- and shrink to their idle scale on the first frame, but the value +
-- branching logic is shared with GearDropService (server-side spawn
-- scale) and GearDropsRenderController (hover-restore target).
-- Required at the top with the other imports.

-- Name of the NumberValue parented to the carrier that drives the
-- scale. GearDropsRenderController tweens .Value on hover; this
-- component listens to .Changed and calls Model:ScaleTo. Shared name
-- so both sides agree on the handle.
local SCALE_VALUE_NAME = "GearScale"

-- Name of the burst attachment GearDropService parents to the carrier
-- server-side (one-shot pickup VFX). On prompt Triggered the owner's
-- client component walks this attachment's ParticleEmitter children
-- and calls :Emit() so the player gets immediate "you grabbed it"
-- feedback before the server even responds. COLLECTED_EMIT_COUNT is
-- how many particles each emitter inside the attachment spawns —
-- user-spec is :Emit(1), one particle per emitter (the attachment
-- ships with multiple emitter children, so the visible burst is still
-- a multi-particle flash).
local COLLECTED_ATTACHMENT_NAME = "Collected"
local COLLECTED_EMIT_COUNT = 1

-- LANDING burst, the relic drop's beat (Client/Components/Relic emits
-- its RelicParticles the frame the bezier finishes). The rarity
-- attachment GearDropService clones on is named for its prefab —
-- UncommonRelicParticles / RareRelicParticles / EpicRelicParticles /
-- LegendaryRelicParticles — so the suffix identifies it without the
-- client needing the rarity-to-prefab mapping.
-- The relic's landing burst, shared so a gear drop hits the floor with
-- exactly the same puff a relic does. Rarity is already carried by the
-- ambient aura and the flight trail, so this one is NOT tinted — same
-- as the relic, which leaves it alone too.
local LANDING_PARTICLE_NAME = "RelicParticles"
local LANDING_EMIT_COUNT = 15

-- Attribute names — must match what GearDropService writes when
-- spawning the model server-side. ATTR_OWNER_ID gates the prompt
-- (only the owning player gets the pickup UI); ATTR_ORIGIN_POSITION
-- is the mob's death position, used by the owner's bezier as the
-- flight starting point (carrier is spawned at the LANDING position
-- by the server, so the bezier flies origin → landing visually).
local ATTR_UUID = "GearUuid"
local ATTR_NAME = "GearName"
local ATTR_TYPE = "GearType"
local ATTR_RARITY = "GearRarity"
local ATTR_DESCRIPTION = "GearDescription"
local ATTR_LEVEL = "GearLevel"
local ATTR_EXPIRED = "Expired"
local ATTR_OWNER_ID = "OwnerId"
local ATTR_ORIGIN_POSITION = "OriginPosition"
-- Attributes.BouncePosition: the landing ricocheted off a wall (server).
local ATTR_BOUNCE_POSITION = "BouncePosition"
-- Attributes.PublicDrop: a player dropped this from their run inventory,
-- so every client treats itself as the owner (prompt, flight, pickup).
local ATTR_PUBLIC_DROP = "PublicDrop"
-- Attributes.DroppedByName: who dropped it, for the billboard's owner
-- line. Absent on mob loot and chest loot, which nobody dropped.
local ATTR_DROPPED_BY = "DroppedByName"
-- CLIENT-LOCAL: this player triggered the prompt and is waiting on the
-- server. Read by GearDropsRenderController to keep the floating label
-- down for the whole round trip, so a successful pickup never flashes it
-- back up between the prompt closing and the drop starting to fade.
local ATTR_PICKUP_PENDING = "PickupPending"

-- Floating label prefab under GameAssets.BillboardGuis. The gear
-- counterpart of the relic's RelicName: same Frame shape (NameText,
-- RarityText, UserText), so the shared owner-label helper and the
-- render controller's billboard dim both work on it unchanged.
local BILLBOARD_NAME = "GearName"
-- Mobile text sizes, matching Client/Components/Relic.lua.
local MOBILE_NAME_TEXT_SIZE = 12
local MOBILE_RARITY_TEXT_SIZE = 10

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

local GearDrop = Component.new({
	Tag = TagList.GearDrop,
	Extensions = { JanitorAdder, CommAdder },
})

--[ Private helpers ]--

-- (Landing position is picked server-side now — see
-- GearDropService:_pickLandingPosition. The carrier is spawned by the
-- server already AT the landing position, so the component just reads
-- carrier.Position in Construct to get the resting target. Origin
-- comes from the ATTR_ORIGIN_POSITION attribute the server set, which
-- the owner's bezier uses as the flight starting point.)

-- Pulls the gear's description from the appropriate data table. The
-- controller stashed the description on an attribute, but we ALSO fall
-- back to the catalogue lookup in case the attribute is missing (the
-- catalogue is the canonical source).
function GearDrop:_resolveDescription(): string
	local fromAttr = self.Instance:GetAttribute(ATTR_DESCRIPTION)
	if typeof(fromAttr) == "string" and fromAttr ~= "" then
		return fromAttr
	end
	local gearName = self.Instance:GetAttribute(ATTR_NAME)
	local gearType = self.Instance:GetAttribute(ATTR_TYPE)
	local data = nil
	if gearType == GearTypes.Weapon then
		data = WeaponData[gearName]
	elseif gearType == GearTypes.Armor then
		data = ArmorPieceData[gearName]
	end
	return (data and data.description) or ""
end

-- Builds + mounts the custom ProximityPrompt on the carrier. Returns the
-- prompt so caller can hook Triggered. The prompt is configured BEFORE
-- the bezier animation starts but disabled until landing — we don't want
-- the player to be able to grab a drop mid-flight.
function GearDrop:_buildPrompt(): ProximityPrompt
	local gearName = self.Instance:GetAttribute(ATTR_NAME) or "Gear"
	local rarity = self.Instance:GetAttribute(ATTR_RARITY) or ""
	local level = self.Instance:GetAttribute(ATTR_LEVEL) or DEFAULT_GEAR_LEVEL
	local description = self:_resolveDescription()

	local prompt = Instance.new("ProximityPrompt")
	-- Format: "Lvl. 1 AK-47". Level pulled from the carrier attribute so a
	-- future variable-level drop system (harder dungeons → higher-level
	-- gear) won't require a component-side change — only the controller /
	-- service that writes the attribute.
	prompt.ActionText = "Lvl. " .. tostring(level) .. " " .. gearName
	prompt.ObjectText = description -- per user spec: ObjectText = gear description
	prompt.KeyboardKeyCode = PROMPT_KEY
	prompt.RequiresLineOfSight = false
	prompt.MaxActivationDistance = PROMPT_MAX_DISTANCE
	prompt.Style = Enum.ProximityPromptStyle.Custom
	prompt.Enabled = false -- enabled after the bezier lands
	prompt:SetAttribute("Style", PROMPT_STYLE_ATTRIBUTE)
	prompt.UIOffset = Vector2.new(0, 15)

	prompt:SetAttribute("Rarity", rarity)
	prompt:SetAttribute("RarityColor", RarityColors:Get(rarity))
	prompt:SetAttribute("GearName", gearName)
	prompt:SetAttribute("UserText", ownerUserText(self.Instance))
	prompt.Parent = self._carrier
	return prompt
end

function GearDrop:_playBezierFlight()
	-- Thrown: the pop, on the carrier so it rides the arc. Replaced the
	-- chest-only coin blip that used to play here — gear now sounds the
	-- same whichever way it arrived, and a chest item made two noises at
	-- once with both. Coins keep their own blip (Drop component).
	lootSound:PlayPop(self._carrier)

	local origin = self._originPosition
	local landing = self._restingPosition
	local apex = origin + Vector3.new(0, math.random(BEZIER_APEX_Y_MIN, BEZIER_APEX_Y_MAX), 0)
	-- One or two bezier legs (see Relic): a BouncePosition makes the
	-- wall ricochet visible.
	local arc, durationScale = arcPath(origin, apex, landing, self.Instance:GetAttribute(ATTR_BOUNCE_POSITION))

	-- A finer step for a ricochet (durationScale) so the longer two-leg
	-- path takes proportionally more frames and flies at the same pace.
	for t = 0, 1, BEZIER_STEP / durationScale do
		RunService.RenderStepped:Wait()
		if not self._carrier or not self._carrier.Parent then
			return -- destroyed mid-flight (e.g., player picked something else, or expired)
		end
		self._carrier.CFrame = CFrame.new(arc(t))
	end

	-- Landed: the trail stops and the rarity burst fires, matching the
	-- relic drop's landing beat.
	self.Instance.PrimaryPart.DropAttachment.DropParticles.Enabled = false
	self:_emitLandingBurst()
	lootSound:PlayLanding()
end

-- The burst as the drop hits the floor, tinted by the rarity prefab it
-- came from. Separate from _emitPickupBurst: that one is the Collected
-- attachment, fired when the player takes the item.
function GearDrop:_emitLandingBurst()
	if not self._landingParticles then
		return
	end
	-- The RELIC's burst, same emitter and same count. This used to re-fire
	-- the drop's own rarity AURA emitters instead, which is why gear hit
	-- the floor with a different puff from a relic — the aura is the
	-- ambient glow, not a landing effect.
	self._landingParticles:Emit(LANDING_EMIT_COUNT)
end

function GearDrop:_emitPickupBurst()
	if not self._carrier then
		return
	end
	local collected = self._carrier:FindFirstChild(COLLECTED_ATTACHMENT_NAME)
	if not collected then
		return
	end
	for _, child in collected:GetChildren() do
		if child:IsA("ParticleEmitter") then
			child:Emit(COLLECTED_EMIT_COUNT)
		end
	end
end

-- Hides every visible element on the drop so non-owner clients see
-- nothing where someone else's loot lives. The model still exists
-- (it's server-spawned + replicated), but everything that would
-- render is muted client-side:
--
--   * BasePart.Transparency       → 1 (mesh parts invisible)
--   * Decal / Texture.Transparency → 1 (surface decoration invisible)
--   * ParticleEmitter.Enabled     → false (no rarity glow / drop stream)
--   * BillboardGui.Enabled        → false (no "Lvl. N Name" label)
--
-- The carrier is already Transparency = 1 from the server-side build,
-- but the loop hits it anyway harmlessly.
--
-- Local-only writes — the server's replicated state is unchanged, so
-- the owner's client still sees their drop with full visuals. The
-- GearDropsRenderController also skips non-owned drops in its
-- hover-dim loop so a passing owner-drop hover doesn't accidentally
-- tween these parts back toward visible.
function GearDrop:_hideForNonOwner()
	for _, descendant in self.Instance:GetDescendants() do
		if descendant:IsA("BasePart") or descendant:IsA("Decal") or descendant:IsA("Texture") then
			descendant.Transparency = 1
		elseif descendant:IsA("ParticleEmitter") or descendant:IsA("BillboardGui") then
			descendant.Enabled = false
		end
	end
end

-- Returns a random radians-per-second spin rate in the [MIN, MAX] range
-- with a 50/50 random sign. Called once in Construct to seed the
-- per-drop Y-axis rotation rate.
-- Clones the GearName billboard onto the carrier and fills it in:
-- "Lvl. 6 Adventurers Tunic", the rarity in its own colour, and the
-- owner line for gear a player dropped. Built on the CLIENT, like the
-- relic's, so mobile text sizing is per viewer and the non-owner hide
-- (which disables every BillboardGui in the model) catches it for free.
function GearDrop:_buildBillboard()
	if not self._carrier then
		return
	end
	local assets = ReplicatedStorage:FindFirstChild("GameAssets")
	local billboards = assets and assets:FindFirstChild("BillboardGuis")
	local template = billboards and billboards:FindFirstChild(BILLBOARD_NAME)
	if not template then
		warn("[GearDrop] Missing GameAssets.BillboardGuis." .. BILLBOARD_NAME)
		return
	end

	local gearName = self.Instance:GetAttribute(ATTR_NAME) or "Gear"
	local level = self.Instance:GetAttribute(ATTR_LEVEL) or DEFAULT_GEAR_LEVEL
	local rarity = self.Instance:GetAttribute(ATTR_RARITY) or ""

	local billboard = template:Clone()
	billboard.Adornee = self._carrier
	billboard.Frame.NameText.Text = "Lvl. " .. tostring(level) .. " " .. tostring(gearName)
	billboard.Frame.RarityText.Text = rarity
	billboard.Frame.RarityText.TextColor3 = RarityColors:Get(rarity)
	applyOwnerLabel(billboard.Frame, self.Instance:GetAttribute(ATTR_DROPPED_BY))

	if ScreenSizeController and ScreenSizeController:GetScreenSizeData().name == ScreenSizes.Mobile then
		billboard.Frame.NameText.TextSize = MOBILE_NAME_TEXT_SIZE
		billboard.Frame.RarityText.TextSize = MOBILE_RARITY_TEXT_SIZE
	end

	billboard.Parent = self._carrier
end

function GearDrop:_randomSpinRate(): number
	local magnitude = math.random() * (SPIN_RAD_PER_SEC_MAX - SPIN_RAD_PER_SEC_MIN) + SPIN_RAD_PER_SEC_MIN
	if math.random() < 0.5 then
		return -magnitude
	end
	return magnitude
end

function GearDrop:_startRestingLoop()
	local startTime = tick()
	self._janitor:Add(RunService.Heartbeat:Connect(function(_dt: number)
		if not self._carrier or not self._carrier.Parent then
			return
		end

		local elapsed = tick() - startTime
		local bobOffset = self._bobAmplitude * math.sin((elapsed * 2 * math.pi) / self._bobCycleDuration)
		local spinAngle = elapsed * self._spinRateY

		self._carrier.CFrame = CFrame.new(self._restingPosition + Vector3.new(0, bobOffset, 0))
			* CFrame.Angles(0, spinAngle, 0)
	end))
end

function GearDrop:_setupScale()
	local idleScale = getGearIdleScale(self.Instance:GetAttribute(ATTR_NAME), self.Instance:GetAttribute(ATTR_TYPE))

	-- Initial scale apply before the NumberValue / Changed listener is
	-- in play; reflecting it into the NumberValue's initial value below
	-- keeps the two in sync from frame 1.
	self.Instance:ScaleTo(idleScale)

	-- NumberValue lives on the carrier (not on self.Instance) so the
	-- fade-out's descendant walk on self.Instance doesn't accidentally
	-- iterate over it.
	self._scaleValue = Instance.new("NumberValue")
	self._scaleValue.Name = SCALE_VALUE_NAME
	self._scaleValue.Value = idleScale
	self._scaleValue.Parent = self._carrier

	self._janitor:Add(self._scaleValue.Changed:Connect(function(value: number)
		if self.Instance and self.Instance.Parent then
			self.Instance:ScaleTo(value)
		end
	end))
end

-- Fade everything out then destroy. Called when the server signals expire.
function GearDrop:_fadeOutAndDestroy()
	self._janitor:Cleanup()

	if not self._carrier or not self._carrier.Parent then
		return
	end

	-- Disable the prompt so the player can't grab a half-faded drop.
	if self._prompt then
		self._prompt.Enabled = false
	end

	-- Collect every fadeable thing on the carrier + gear: BaseParts get
	-- Transparency tweened to 1, Decals/Textures same, ParticleEmitters
	-- get Enabled=false (their existing particles fade naturally based
	-- on their own Lifetime). Skip the invisible carrier itself.
	local tweenInfo = TweenInfo.new(FADE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

	for _, descendant in self.Instance:GetDescendants() do
		if
			(descendant:IsA("BasePart") and descendant ~= self._carrier)
			or descendant:IsA("Decal")
			or descendant:IsA("Texture")
		then
			TweenService:Create(descendant, tweenInfo, { Transparency = 1 }):Play()
		elseif
			descendant:IsA("BillboardGui")
			or descendant:IsA("ProximityPrompt")
			or descendant:IsA("ParticleEmitter")
		then
			-- OFF at once rather than faded with the model. A label and a
			-- pickup prompt over a claimed drop read as still-takeable for as
			-- long as they stay legible, which is exactly what the old
			-- fade-the-text-too version left on everyone else's screen.
			descendant.Enabled = false
		end
	end

	task.delay(FADE_DURATION + 0.1, function()
		if self.Instance and self.Instance.Parent then
			self.Instance:Destroy()
		end
	end)
end

--[ Component lifecycle ]--

function GearDrop:Construct()
	self._carrier = self.Instance.PrimaryPart
	assert(self._carrier, "[GearDrop] Component requires PrimaryPart on the carrier model")

	self._uuid = self.Instance:GetAttribute(ATTR_UUID)
	assert(self._uuid, "[GearDrop] Component requires GearUuid attribute on the carrier")

	-- Owner gate. The drop is replicated to all clients (Relic-style),
	-- but only the rolling player gets the prompt UI + bezier flight +
	-- pickup hook. Other clients still see the model + bob/spin + fade.
	-- A PUBLIC drop belongs to nobody, so everyone passes this gate and
	-- gets the prompt.
	self._isOwner = self.Instance:GetAttribute(ATTR_PUBLIC_DROP) == true
		or self.Instance:GetAttribute(ATTR_OWNER_ID) == Players.LocalPlayer.UserId

	-- Comm signal mirror of Server/Components/GearDrop.lua. Server side
	-- did `_comm:CreateSignal("OnGearCollected")`; we grab the same
	-- handle and Fire on prompt Triggered. Server validates and grants.
	self._onGearCollected = self._comm:GetSignal("OnGearCollected")

	-- Landing burst, cloned per drop (a shared emitter cannot overlap
	-- itself when a chest spills several items). Parented to the carrier
	-- so it rides the arc and sits where the gear lands.
	local landingTemplate = ReplicatedStorage.GameAssets.Particles:FindFirstChild(LANDING_PARTICLE_NAME)
	if landingTemplate then
		self._landingParticles = landingTemplate:Clone()
		self._landingParticles.Parent = self._carrier
	else
		warn(("[GearDrop] GameAssets.Particles.%s is missing"):format(LANDING_PARTICLE_NAME))
	end

	self._restingPosition = self._carrier.Position
	local originAttr = self.Instance:GetAttribute(ATTR_ORIGIN_POSITION)
	if typeof(originAttr) == "Vector3" then
		self._originPosition = originAttr
	else
		-- Defensive fallback — if the server didn't stamp the origin
		-- (shouldn't happen but covers race conditions on first replicate),
		-- skip the bezier by starting at the landing.
		self._originPosition = self._restingPosition
	end

	self._bobAmplitude = math.random() * (BOB_AMPLITUDE_MAX - BOB_AMPLITUDE_MIN) + BOB_AMPLITUDE_MIN
	self._bobCycleDuration = math.random() * (BOB_CYCLE_DURATION_MAX - BOB_CYCLE_DURATION_MIN) + BOB_CYCLE_DURATION_MIN

	-- Y-axis spin rate, randomized once per drop. _randomSpinRate
	-- handles the magnitude pick + sign flip.
	self._spinRateY = self:_randomSpinRate()

	-- Built BEFORE the owner branch: _hideForNonOwner disables every
	-- BillboardGui in the model, so the label has to exist by then.
	self:_buildBillboard()

	if self._isOwner then
		self._prompt = self:_buildPrompt()
	else
		self:_hideForNonOwner()
	end
end

function GearDrop:Start()
	self.Instance.PrimaryPart.DropAttachment.DropParticles.Color =
		ColorSequence.new(RarityColors:Get(self.Instance:GetAttribute(ATTR_RARITY)))

	self._janitor:Add(self.Instance:GetAttributeChangedSignal(ATTR_EXPIRED):Connect(function()
		if self.Instance:GetAttribute(ATTR_EXPIRED) == true then
			self:_fadeOutAndDestroy()
		end
	end))

	-- Prompt is only built in :Construct() when this client is the
	-- drop's owner (line ~401, gated by `self._isOwner`). Non-owners
	-- still :Start() to wire up the rarity color + expiration fade
	-- below, but `_prompt` is nil for them — guarding the connection
	-- avoids the "attempt to index nil with 'Triggered'" stack we saw
	-- in QA when a spectator/non-owner client received a gear drop.
	if self._prompt then
		self._janitor:Add(self._prompt.Triggered:Connect(function()
			self._prompt.Enabled = false
			-- Claimed BEFORE the prompt's own PromptHidden lands, so the
			-- label stays down for the whole round trip. Released below if
			-- the pickup is refused; on success the drop fades and dies
			-- with the flag still set.
			self.Instance:SetAttribute(ATTR_PICKUP_PENDING, true)
			if GearDropsRenderController then
				GearDropsRenderController:RefreshBillboardVisibility(self.Instance)
			end
			self:_emitPickupBurst()
			self._onGearCollected:Fire()

			ReplicatedStorage.GameAssets.Sounds.GearCollected:Play()

			-- Still here a second later means the server REFUSED the pickup
			-- (run inventory full): the prompt comes back so the player can
			-- retry, and the label is released. Refresh rather than a plain
			-- enable — if the player is still standing in range the prompt
			-- is up again, and the label must stay down for that instead.
			task.delay(1, function()
				if self._prompt and self.Instance and self.Instance.Parent then
					self._prompt.Enabled = true
					self.Instance:SetAttribute(ATTR_PICKUP_PENDING, false)
					if GearDropsRenderController then
						GearDropsRenderController:RefreshBillboardVisibility(self.Instance)
					end
				end
			end)
		end))
	end

	if not self._isOwner then
		return
	end

	-- Owner-only: scale infrastructure + bezier + resting loop.
	self:_setupScale()

	task.spawn(function()
		self:_playBezierFlight()
		if not self._carrier or not self._carrier.Parent then
			return -- destroyed mid-flight
		end
		if self._prompt then
			self._prompt.Enabled = true
		end
		self:_startRestingLoop()
	end)
end

return GearDrop
