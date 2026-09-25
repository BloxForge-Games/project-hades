--!strict
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

--[ Imports ]--

local Component = require(ReplicatedStorage.Submodules.Core.Packages.Component)
local waitForPrimaryPart = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Drop.waitForPrimaryPart)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local JanitorAdder = require(ReplicatedStorage.Submodules.Core.Source.ComponentExtensions.JanitorAdder)
local DropFloatController = require(ReplicatedStorage.Controllers.DropFloatController)
local GearDropsRenderController = require(ReplicatedStorage.Controllers.GearDropsRenderController)
local DungeonNetwork = require(ReplicatedStorage.Submodules.Core.Source.Network.Dungeon)
local WeaponData = require(ReplicatedStorage.Submodules.Core.Shared.Data.WeaponData)
local ArmorPieceData = require(ReplicatedStorage.Submodules.Core.Shared.Data.ArmorPieceData)
local GearTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.GearTypes)
local RarityColors = require(ReplicatedStorage.Submodules.Core.Shared.Data.RarityColors)
local getGearIdleScale = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Gear.getGearIdleScale)
local lootSound = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.lootSound)
local emitVFXPart = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.emitVFXPart)
local fadeSubtree = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.fadeSubtree)
local getRoot = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Character.getRoot)
local arcPath = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Drop.arcPath)
local privateDropVisibility = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Drop.privateDropVisibility)
local dressRelicDisplay = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Relic.dressRelicDisplay)
local buildPromptCard = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Relic.buildPromptCard)

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
-- The card's Style attribute: the gear card, not the relic size classes
-- buildPromptCard would pick from the description's length.
local PROMPT_STYLE_ATTRIBUTE = "GearDrop"

-- Drops always spawn at level 1 today. Pulled from the GearLevel attribute
-- on the carrier (controller sets it) so when variable-level drops land
-- later (e.g., harder dungeons rolling higher-level gear), only the
-- controller / service change is needed — the component reads whatever's
-- on the attribute.
local DEFAULT_GEAR_LEVEL = 1

-- Fade-out duration on expire.
local FADE_DURATION = 0.5
local FADE_OUT_INFO = TweenInfo.new(FADE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- How long Construct waits for a streamed-in descendant before giving up.
local STREAM_WAIT_SECONDS = 10

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

-- The pickup bursts, the SAME pair a relic plays (Client/Components/
-- Relic), both tinted to the gear's rarity and both attribute-driven
-- prefabs under GameAssets.VFX (emitVFXPart): CollectRelicVFX at the
-- drop, CollectRelicVFXCharacter on the collector. Played by every
-- client off the replicated CollectedById the server stamps before the
-- Expired fade (see _fadeOutAndDestroy); a timeout fade has no
-- collector and bursts nothing.
local COLLECT_VFX_NAME = "CollectRelicVFX"
local COLLECT_CHARACTER_VFX_NAME = "CollectRelicVFXCharacter"
local COLLECT_VFX_LIFETIME_SCALE = 1.5
local COLLECT_CHARACTER_VFX_LIFETIME_SCALE = 2

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
-- Attributes.CollectedById: who took it (server), read by the fade.
local ATTR_COLLECTED_BY_ID = "CollectedById"
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
-- Stamped by the server on every item but the first of a death spill: no
-- throw pop for this one, the burst already sounded once.
local ATTR_SILENT_POP = "SilentPop"
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
	Extensions = { JanitorAdder } :: { any },
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
	prompt.KeyboardKeyCode = PROMPT_KEY
	prompt.RequiresLineOfSight = false
	prompt.MaxActivationDistance = PROMPT_MAX_DISTANCE
	prompt.Enabled = false -- enabled after the bezier lands
	-- The shared card. Name format: "Lvl. 1 AK-47", level pulled from the
	-- carrier attribute so a future variable-level drop system (harder
	-- dungeons → higher-level gear) won't require a component-side change
	-- — only the controller / service that writes the attribute.
	buildPromptCard(prompt, {
		name = "Lvl. " .. tostring(level) .. " " .. gearName,
		description = description,
		rarity = rarity,
		style = PROMPT_STYLE_ATTRIBUTE,
		userText = ownerUserText(self.Instance),
	})
	-- The gear card's own extras.
	prompt:SetAttribute("RarityColor", RarityColors:Get(rarity))
	prompt:SetAttribute("GearName", gearName)
	prompt.Parent = self._carrier
	return prompt
end

function GearDrop:_playBezierFlight()
	-- Thrown: the pop, on the carrier so it rides the arc. Replaced the
	-- chest-only coin blip that used to play here — gear now sounds the
	-- same whichever way it arrived, and a chest item made two noises at
	-- once with both. Coins keep their own blip (Drop component).
	-- A death spill pops once: every item after its first is stamped silent.
	if self.Instance:GetAttribute(ATTR_SILENT_POP) ~= true then
		lootSound:PlayPop(self._carrier)
	end

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
	self._dropParticles.Enabled = false
	self:_emitLandingBurst()
	lootSound:PlayLanding()
end

-- The burst as the drop hits the floor, tinted by the rarity prefab it
-- came from. The pickup bursts are separate (see _fadeOutAndDestroy).
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

-- Someone else's drop. The server already spawned it invisible
-- (privateDropVisibility.hide) and only the owner reveals it, so this
-- client never sees a frame of it. This local pass is the fallback for a
-- spawn path that forgot, and it also catches what the CLIENT built
-- (the billboard from _buildBillboard) -- everything that would render:
--
--   * BasePart.Transparency       → 1 (mesh parts invisible)
--   * Decal / Texture.Transparency → 1 (surface decoration invisible)
--   * ParticleEmitter.Enabled     → false (no rarity glow / drop stream)
--   * BillboardGui.Enabled        → false (no "Lvl. N Name" label)
--
-- Local-only writes — the server's replicated state is unchanged. The
-- GearDropsRenderController also skips non-owned drops in its hover-dim
-- loop so a passing owner-drop hover doesn't tween these parts back
-- toward visible.
function GearDrop:_hideForNonOwner()
	fadeSubtree(self.Instance, {
		targetTransparency = 1,
		includeDecals = true,
		disable = { "ParticleEmitter", "BillboardGui" },
	})
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
	local gearName = self.Instance:GetAttribute(ATTR_NAME) or "Gear"
	local level = self.Instance:GetAttribute(ATTR_LEVEL) or DEFAULT_GEAR_LEVEL
	local rarity = self.Instance:GetAttribute(ATTR_RARITY) or ""
	-- The relic's dressing on the gear prefab: no glow (the rarity aura
	-- is the gear's light).
	dressRelicDisplay(self._carrier, {
		prefab = BILLBOARD_NAME,
		name = "Lvl. " .. tostring(level) .. " " .. tostring(gearName),
		rarity = rarity,
		rarityColor = RarityColors:Get(rarity),
		droppedByName = self.Instance:GetAttribute(ATTR_DROPPED_BY),
	})
end

function GearDrop:_randomSpinRate(): number
	local magnitude = math.random() * (SPIN_RAD_PER_SEC_MAX - SPIN_RAD_PER_SEC_MIN) + SPIN_RAD_PER_SEC_MIN
	if math.random() < 0.5 then
		return -magnitude
	end
	return magnitude
end

-- The resting float: one shared Heartbeat (DropFloatController) poses the
-- carrier from its resting position -- the bob and the Y spin, at this
-- drop's own rates -- and the janitor takes it out on pickup / expire.
function GearDrop:_startRestingLoop()
	DropFloatController:Register(self._carrier, {
		base = CFrame.new(self._restingPosition),
		bobAmplitude = self._bobAmplitude,
		bobCycle = self._bobCycleDuration,
		spinAxis = Vector3.yAxis,
		spinRate = self._spinRateY,
	})
	self._janitor:Add(function()
		DropFloatController:Unregister(self._carrier)
	end, true)
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

-- Fade everything out then destroy. Called when the server signals expire
-- -- a pickup (CollectedById stamped: the bursts play) or a timeout.
function GearDrop:_fadeOutAndDestroy()
	self._janitor:Cleanup()

	if not self._carrier or not self._carrier.Parent then
		return
	end

	-- THE PICKUP BURSTS, on every screen (see COLLECT_VFX_NAME): at the
	-- drop, and on the collector's body, in the gear's rarity colour.
	local collectorId = self.Instance:GetAttribute(ATTR_COLLECTED_BY_ID)
	local collector = if typeof(collectorId) == "number" then Players:GetPlayerByUserId(collectorId) else nil
	if collector then
		local burstColor = RarityColors:Get(self.Instance:GetAttribute(ATTR_RARITY))
		emitVFXPart(COLLECT_VFX_NAME, self._carrier.CFrame, nil, {
			Color = burstColor,
			LifetimeScale = COLLECT_VFX_LIFETIME_SCALE,
		})
		local root = getRoot.fromPlayer(collector)
		if root then
			emitVFXPart(COLLECT_CHARACTER_VFX_NAME, root.CFrame, nil, {
				Color = burstColor,
				LifetimeScale = COLLECT_CHARACTER_VFX_LIFETIME_SCALE,
			})
		end
	end

	-- Disable the prompt so the player can't grab a half-faded drop.
	if self._prompt then
		self._prompt.Enabled = false
	end

	-- Every fadeable thing on the carrier + gear: BaseParts and Decals /
	-- Textures tween to 1, skipping the invisible carrier itself. The
	-- label, the prompt and the emitters go OFF at once rather than faded
	-- with the model: a label and a pickup prompt over a claimed drop read
	-- as still-takeable for as long as they stay legible, which is exactly
	-- what the old fade-the-text-too version left on everyone else's
	-- screen (an emitter's live particles die on their own Lifetime).
	fadeSubtree(self.Instance, {
		targetTransparency = 1,
		tweenInfo = FADE_OUT_INFO,
		includeDecals = true,
		skip = function(descendant)
			return descendant == self._carrier
		end,
		disable = { "BillboardGui", "ProximityPrompt", "ParticleEmitter" },
	})

	task.delay(FADE_DURATION + 0.1, function()
		if self.Instance and self.Instance.Parent then
			self.Instance:Destroy()
		end
	end)
end

--[ Component lifecycle ]--

function GearDrop:Construct()
	self._gone = false
	-- The parts can stream in after the tagged Model does; wait for them.
	self._carrier = waitForPrimaryPart(self.Instance)
	if not self._carrier then
		-- Taken / expired while still streaming in: nothing to build, and
		-- Start checks _gone. Anything else is a real failure.
		if self.Instance.Parent == nil then
			self._gone = true
			return
		end
		error("[GearDrop] PrimaryPart never replicated for " .. self.Instance:GetFullName())
	end
	-- Start (and what runs after it) reads these directly. The server
	-- spawns the model atomic, so they normally arrive with it; the waits
	-- cover an asset that is not, and turn a random "not a valid member"
	-- crash into a clear timeout. Nil only when the model left the
	-- DataModel mid-wait (taken / expired while streaming in): Construct
	-- then bails and Start checks _gone.
	local function need(parent: Instance?, name: string): Instance?
		if parent == nil or self._gone then
			return nil
		end
		local child = parent:WaitForChild(name, STREAM_WAIT_SECONDS)
		if child == nil and self.Instance.Parent == nil then
			self._gone = true
			return nil
		end
		assert(child, ("[GearDrop] %s never replicated under %s"):format(name, parent:GetFullName()))
		return child
	end
	self._dropParticles = need(need(self._carrier, "DropAttachment"), "DropParticles")
	if self._gone then
		return
	end

	self._uuid = self.Instance:GetAttribute(ATTR_UUID)
	assert(self._uuid, "[GearDrop] Component requires GearUuid attribute on the carrier")

	-- Owner gate. The drop is replicated to all clients (Relic-style),
	-- but only the rolling player gets the prompt UI + bezier flight +
	-- pickup hook. Other clients still see the model + bob/spin + fade.
	-- A PUBLIC drop belongs to nobody, so everyone passes this gate and
	-- gets the prompt.
	self._isOwner = self.Instance:GetAttribute(ATTR_PUBLIC_DROP) == true
		or self.Instance:GetAttribute(ATTR_OWNER_ID) == Players.LocalPlayer.UserId

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
	if self._gone then
		return
	end
	self._dropParticles.Color = ColorSequence.new(RarityColors:Get(self.Instance:GetAttribute(ATTR_RARITY)))

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
			DungeonNetwork.GearDropCollected.Fire(self.Instance)

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

	-- Ours: the server spawned it invisible (privateDropVisibility.hide);
	-- put the authored look back before the flight, so the expire fade
	-- later tweens from the real values. Already claimed (Expired is set
	-- on pickup) means it stays hidden: there is nothing left to show.
	-- A no-op on a public drop, which was never hidden.
	if self.Instance:GetAttribute(ATTR_EXPIRED) ~= true then
		privateDropVisibility.reveal(self.Instance)
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
