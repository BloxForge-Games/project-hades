--[[
	Module: GearDropService.lua
	Description:
	Server-authoritative gear drop spawner.

]]

--[ Roblox Services ]--

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

--[ Imports ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local DungeonData = require(ReplicatedStorage.Submodules.Core.Shared.Data.DungeonData)
local findFloorBelow = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Dungeon.findFloorBelow)
local resolveArcLanding = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Drop.resolveArcLanding)
local WeaponData = require(ReplicatedStorage.Submodules.Core.Shared.Data.WeaponData)
local ArmorPieceData = require(ReplicatedStorage.Submodules.Core.Shared.Data.ArmorPieceData)
local getGearIdleScale = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Gear.getGearIdleScale)
local GearTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.GearTypes)
local ItemRarity = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ItemRarity)
local RarityColors = require(ReplicatedStorage.Submodules.Core.Shared.Data.RarityColors)
local rollItemRarity = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Rarity.rollItemRarity)

local DungeonService

--[ Constants ]--

-- Carrier part dimensions. Invisible, non-collidable; only acts as the
-- weld anchor + ProximityPrompt host + comm Instance host.
local CARRIER_SIZE = Vector3.new(0.2, 0.2, 0.2)

-- Folder under workspace.IgnoreInstances where drops live. Kept under
-- IgnoreInstances so camera / pathfinding / etc. skip them.
local DROP_FOLDER_NAME = "GearDrops"

-- ±studs of randomization for the landing spot (offset from origin).
-- Multiple simultaneous drops separate visually instead of stacking.
-- Server picks the landing offset so all clients see the drop end up
-- in the same place (the client-side bezier just animates the route).
local LANDING_XZ_SCATTER = 5
local LANDING_ATTEMPTS = 6 -- scatter re-rolls before falling back to straight below the origin

-- Final hover height of the drop above the actual dungeon floor.
-- Constant regardless of mob size — the previous version added a
-- fixed Y offset to the mob's HRP, which floated drops way up for
-- tall mobs (minibosses, bosses sit higher off the ground than
-- normal zombies). _pickLandingPosition raycasts down to the dungeon
-- floor and stacks LANDING_Y_ABOVE_GROUND on top of the floor hit Y.
local LANDING_Y_ABOVE_GROUND = 2

-- Raycast tuning for the floor-finder under the picked landing XZ.
-- Start a few studs above the origin so a death position sitting in
-- the floor's bounding box still registers a hit; cast deep enough
-- that drops near elevated arenas / platforms can still find ground.
-- Gap between successive items out of a CHEST, so a three-item payout
-- arcs out one at a time instead of in a single frame. Mirrors the coin
-- payout's own stagger (DropService's IS_BOSS_COIN_DROP_DELAY). Corpse
-- loot is unstaggered — a mob death is one beat, not a payout.
local CHEST_DROP_STAGGER_SECONDS = 0.1
local LANDING_RAYCAST_UP = 10
local LANDING_RAYCAST_DEPTH = 100

-- Fallback level used when no active dungeon is in play (ad-hoc test
-- calls, or a malformed difficulty config missing `levelRange`). When
-- a real dungeon is active, the level is rolled from
-- DungeonData[id].difficulties[diff].levelRange = { min, max } —
-- see _rollGearLevel below.
local DEFAULT_GEAR_LEVEL = 1

-- (Pinata's gear-drop constants lived here; the relic was reworked into
-- a Cursed vending-machine relic — see RelicMachine — and its gear hooks
-- were removed.)

-- Idle-scale ladder now lives in Shared/Functions/Gear/getGearIdleScale.
-- This file was previously authoring its own copy (with armor = 0.75),
-- the client component had its own (armor = 1.0), and the render
-- controller had a third (armor = 1) — all duplicating the same
-- branching logic. The server's 0.75 was getting silently overwritten
-- by the client's 1.0 on every drop. Single shared resolver removes
-- the bug class.

-- Attribute names. Both the server and client component read these,
-- so they're shared via this single source of truth.
local ATTR_UUID = "GearUuid"
local ATTR_NAME = "GearName"
local ATTR_TYPE = "GearType"
local ATTR_RARITY = "GearRarity"
local ATTR_DESCRIPTION = "GearDescription"
local ATTR_LEVEL = "GearLevel"
local ATTR_OWNER_ID = "OwnerId"
local ATTR_ORIGIN_POSITION = "OriginPosition"
-- Attributes.BouncePosition: set when the landing ricocheted off a wall.
local ATTR_BOUNCE_POSITION = "BouncePosition"
-- Attributes.PublicDrop: a player dropped this from their run inventory,
-- so ANYONE may pick it up (the OwnerId lock is skipped on both sides).
local ATTR_PUBLIC_DROP = "PublicDrop"
-- Attributes.DroppedByName / DroppedById: the item's ORIGINAL owner, for
-- the floor label. Name to read, id to compare.
local ATTR_DROPPED_BY = "DroppedByName"
local ATTR_DROPPED_BY_ID = "DroppedById"
-- Armor-only: which slot ("Helmet" / "Chestplate" / "Greaves") the
-- piece goes into on pickup. The server-side GearDrop component
-- reads this to write the inventory entry into the right sub-array
-- of profile.Inventory.Gear[slot] without needing ArmorPieceData
-- itself. Nil for weapons (they don't have a slot concept).
local ATTR_SLOT = "GearSlot"

-- Rarity → particle prefab name under ReplicatedStorage.GameAssets.Particles.
-- These attachments were originally authored for relics; gear reuses
-- them as the rarity VFX (consistent visual language across pickups).
local RARITY_TO_PARTICLE: { [string]: string } = {
	[ItemRarity.Common] = "UncommonRelicParticles",
	[ItemRarity.Uncommon] = "UncommonRelicParticles",
	[ItemRarity.Rare] = "RareRelicParticles",
	[ItemRarity.Epic] = "EpicRelicParticles",
	[ItemRarity.Legendary] = "LegendaryRelicParticles",
	[ItemRarity.Mythic] = "LegendaryRelicParticles",
	[ItemRarity.Shiny] = "LegendaryRelicParticles",
}

-- Pickup-burst attachment names — match prefabs in
-- ReplicatedStorage.GameAssets.Particles. Cloned onto the carrier here;
-- the client component :Emit()s the Collected emitters on Triggered.
local COLLECTED_ATTACHMENT_NAME = "Collected"
local DROP_ATTACHMENT_NAME = "DropAttachment"

-- Marks gear that fell out of a Miniboss / Boss chest rather than off a
-- corpse. Read by Client/Components/GearDrop for the pop-out blip.
local ATTR_FROM_CHEST = "ChestDrop"

-- Billboard prefab name under GameAssets.BillboardGuis. Reused from
-- the relic system since the same name + rarity layout fits gear too.

--[ Service ]--

local GearDropService = Knit.CreateService({
	Name = "GearDropService",
	Client = {},
})

--[ Private helpers ]--

-- Lazily ensures the GearDrops folder exists under
-- workspace.IgnoreInstances. Falls back to workspace if IgnoreInstances
-- isn't present (e.g., booting on a partial map).
function GearDropService:_ensureDropFolder(): Folder
	local ignore = workspace:FindFirstChild("IgnoreInstances")
	if not ignore then
		ignore = workspace
	end
	local folder = ignore:FindFirstChild(DROP_FOLDER_NAME)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = DROP_FOLDER_NAME
		folder.Parent = ignore
	end
	return folder
end

-- Returns the active dungeon's full `dungeonDrops` config (with .pool
-- and .perEnemyType sub-tables), or nil if no dungeon is active OR the
-- difficulty doesn't have one defined.
function GearDropService:_getActiveDropConfig()
	if not DungeonService then
		return nil
	end
	local active = DungeonService:GetActiveDungeon()
	if not active then
		return nil
	end
	local dungeonConfig = DungeonData[active.id]
	local difficultyConfig = dungeonConfig and dungeonConfig.difficulties[active.difficulty]
	return difficultyConfig and difficultyConfig.dungeonDrops or nil
end

-- Returns the active difficulty's rarity-weight table, or nil if no
-- dungeon is active OR the difficulty config doesn't define one.
-- Shape: { [ItemRarity.Common] = N, [ItemRarity.Uncommon] = N, ... }
-- See DungeonData[id].difficulties[diff].rarityWeights for authoring.
function GearDropService:_getActiveRarityWeights()
	if not DungeonService then
		return nil
	end
	local active = DungeonService:GetActiveDungeon()
	if not active then
		return nil
	end
	local dungeonConfig = DungeonData[active.id]
	local difficultyConfig = dungeonConfig and dungeonConfig.difficulties[active.difficulty]
	return difficultyConfig and difficultyConfig.rarityWeights or nil
end

-- Returns the active difficulty's gear-drop level range, or nil if no
-- dungeon is active OR the difficulty config doesn't define one.
-- Shape: `{ min = N, max = N }` (named keys, matches DungeonData
-- authoring convention).
function GearDropService:_getActiveLevelRange()
	if not DungeonService then
		return nil
	end
	local active = DungeonService:GetActiveDungeon()
	if not active then
		return nil
	end
	local dungeonConfig = DungeonData[active.id]
	local difficultyConfig = dungeonConfig and dungeonConfig.difficulties[active.difficulty]
	return difficultyConfig and difficultyConfig.levelRange or nil
end

-- Rolls a level for a single drop using the active difficulty's
-- levelRange. Falls back to DEFAULT_GEAR_LEVEL if no range is
-- available (ad-hoc test calls, malformed config). The level stamped
-- on ATTR_LEVEL drives both the displayed prompt text ("Lvl. N Name")
-- and the persisted inventory entry's `level` field on pickup.
function GearDropService:_rollGearLevel(): number
	local range = self:_getActiveLevelRange()
	if not range or not range.min or not range.max then
		return DEFAULT_GEAR_LEVEL
	end
	return math.random(range.min, range.max)
end

-- Default config for ad-hoc test calls or chest-style drops that aren't
-- tied to a specific mob (enemyType == nil). One guaranteed drop.
local DEFAULT_DROP_CONFIG = {
	dropChance = 1.0,
	dropCount = { 1, 1 },
}

-- Returns the perEnemyType entry for the given enemyType, or the
-- default if missing. perEnemyType from DungeonData wins when present.
function GearDropService:_resolveEnemyDropConfig(dropConfig, enemyType: string?)
	if enemyType and dropConfig and dropConfig.perEnemyType then
		local cfg = dropConfig.perEnemyType[enemyType]
		if cfg then
			return cfg
		end
		warn(
			("[GearDropService] enemyType '%s' has no perEnemyType entry in the active pool — falling back to default"):format(
				tostring(enemyType)
			)
		)
	end
	return DEFAULT_DROP_CONFIG
end

-- Weighted random pick from a pool. Returns the picked entry, or nil
-- for an empty / zero-weight pool. Sum-normalized on every call (cheap;
-- pools are < 10 entries).
function GearDropService:_rollFromPool(pool): { name: string, type: string, weight: number }?
	if not pool or #pool == 0 then
		return nil
	end
	local totalWeight = 0
	for _, entry in pool do
		totalWeight += entry.weight or 0
	end
	if totalWeight <= 0 then
		return nil
	end
	local roll = math.random() * totalWeight
	local accumulator = 0
	for _, entry in pool do
		accumulator += entry.weight or 0
		if roll <= accumulator then
			return entry
		end
	end
	return pool[#pool]
end

-- Looks up the data table entry for a given gear name + type. Returns
-- the entry table (with .rarity / .description / .setName / .slot for
-- armor) or nil if missing.
--
-- Armor pieces (post-refactor): each piece is named per-slot
-- ("Enforcer Helmet" / "Enforcer Chestplate" / "Enforcer Greaves")
-- and the corresponding ArmorPieceData entry holds setName + slot
-- needed to resolve the asset folder later.
function GearDropService:_getGearData(gearName: string, gearType: string)
	if gearType == GearTypes.Weapon then
		return WeaponData[gearName]
	elseif gearType == GearTypes.Armor then
		return ArmorPieceData[gearName]
	end
	return nil
end

-- Idle scale resolution now lives in
-- Shared/Functions/Gear/getGearIdleScale. The previous server-side
-- copy duplicated the same logic in the client component + render
-- controller — three places to keep in sync, predictably drifted apart.

-- Picks a randomized landing position offset from origin. Multiple
-- drops spawned at the same origin spread out via this scatter. The
-- server picks once so all clients see the drop land in the same spot.
--
-- Y is computed via a downward raycast against the DungeonRooms folder
-- (same pattern EncounterService._findLobbyPadFloorY uses) so the drop
-- ends up exactly LANDING_Y_ABOVE_GROUND above the actual floor. This
-- replaces the old "origin.Y + fixed offset" approach, which floated
-- drops way up for tall mobs (the mob's HRP sits ~3 studs above ground
-- for a normal zombie but much higher for minibosses / bosses).
--
-- If the raycast misses (room geometry edge case, drop happened outside
-- of a tagged room, IgnoreInstances.Map.DungeonRooms not present yet)
-- we fall back to (origin.Y + LANDING_Y_ABOVE_GROUND) — better than
-- nothing, and the warn surfaces the misconfiguration during dev.
-- Landing point for a drop from `origin`: a random scatter around it that
-- is over FLOOR (findFloorBelow -- a wall / gate top is rejected, never
-- landed on). Re-rolls the scatter up to LANDING_ATTEMPTS times, then tries
-- straight under the origin (the mob was standing on floor), then falls
-- back to the origin height so the drop still spawns somewhere.
function GearDropService:_pickLandingPosition(origin: Vector3): Vector3
	local fromY = origin.Y + LANDING_RAYCAST_UP
	for _ = 1, LANDING_ATTEMPTS do
		local landingX = origin.X + math.random(-LANDING_XZ_SCATTER, LANDING_XZ_SCATTER)
		local landingZ = origin.Z + math.random(-LANDING_XZ_SCATTER, LANDING_XZ_SCATTER)
		local floor = findFloorBelow(landingX, landingZ, fromY, LANDING_RAYCAST_DEPTH)
		if floor then
			return Vector3.new(landingX, floor.Y + LANDING_Y_ABOVE_GROUND, landingZ)
		end
	end

	local underOrigin = findFloorBelow(origin.X, origin.Z, fromY, LANDING_RAYCAST_DEPTH)
	if underOrigin then
		return Vector3.new(origin.X, underOrigin.Y + LANDING_Y_ABOVE_GROUND, origin.Z)
	end

	-- Fallback: no floor found anywhere near. Use the origin height + the
	-- same above-ground offset so the drop at least appears somewhere
	-- reasonable instead of failing to spawn.
	return Vector3.new(origin.X, origin.Y + LANDING_Y_ABOVE_GROUND, origin.Z)
end

-- Resolves the asset folder for a given gear type. Weapons live under
-- GameAssets.Weapons (Accessories); armor under GameAssets.Armor (Models).
function GearDropService:_resolveAssetFolder(gearType: string): Folder?
	local assets = ReplicatedStorage:FindFirstChild("GameAssets")
	if not assets then
		return nil
	end
	if gearType == GearTypes.Weapon then
		return assets:FindFirstChild("Weapons")
	elseif gearType == GearTypes.Armor then
		return assets:FindFirstChild("Armor")
	end
	return nil
end

-- Normalizes a cloned gear prefab into a visual Model ready to weld
-- onto the carrier.
--
--   * Accessory (Weapon) prefabs:
--       Two relevant children — a Model containing the mesh parts and
--       a Handle BasePart with grip attachments. We reparent the Handle
--       INTO the Model, set it as PrimaryPart (so PivotTo uses the
--       grip-anchored point — sensible orientation for asymmetric
--       weapons), hide it (transparency 1 + CanCollide off — it's a
--       pure pivot/anchor, not a visual), and destroy the Accessory
--       shell.
--
--   * Model (Armor) prefabs:
--       Return as-is.
--
--   * Anything else: warn + destroy + nil.
function GearDropService:_normalizeGearVisual(gearInstance: Instance): Model?
	if gearInstance:IsA("Model") then
		-- Weapons are Models now (converted from Accessory). A weapon Model
		-- holds an inner visible "Model" child (the meshes) + a "Handle"
		-- grip part + an "AttachmentPart". For a DROP we want just the
		-- visible meshes with the Handle as a hidden PrimaryPart — same
		-- normalization the old Accessory branch did, just sourced from a
		-- Model. Detected structurally by the presence of BOTH a "Model"
		-- and "Handle" child (an already-normalized armor wrapper has
		-- neither and falls through to the return-as-is below).
		local visualModel = gearInstance:FindFirstChild("Model")
		local handle = gearInstance:FindFirstChild("Handle")
		if visualModel and visualModel:IsA("Model") and handle and handle:IsA("BasePart") then
			visualModel.Parent = nil
			handle.Parent = visualModel
			visualModel.PrimaryPart = handle
			handle.Transparency = 1
			handle.CanCollide = false
			handle.CanQuery = false
			handle.CanTouch = false
			gearInstance:Destroy()
			return visualModel
		end

		-- Already-normalized Model (e.g. armor wrapper, or a weapon authored
		-- without the inner-Model split) — use as-is.
		return gearInstance
	end

	if gearInstance:IsA("Folder") then
		-- Armor piece slot folder (Helmet / Chestplate / Greaves).
		-- Each child Model is one limb of the piece (Head / Torso /
		-- Left Arm / Right Arm / Left Leg / Right Leg). The asset
		-- authors these at their character-relative offsets so the
		-- relative positions between limbs already form a coherent
		-- "armor piece floating in air" when we PivotTo a carrier.
		--
		-- We wrap them in a single Model so the rest of the drop
		-- pipeline (_pivotGearToCarrier, _weldGearToCarrier,
		-- ScaleTo, GetBoundingBox) operates on one Model handle
		-- without branching everywhere. The first limb's PrimaryPart
		-- becomes the wrapper's PrimaryPart — arbitrary but stable
		-- (PivotTo uses it as the origin; relative offsets between
		-- limbs are preserved).
		local wrapper = Instance.new("Model")
		wrapper.Name = gearInstance.Name

		local pickedPrimary: BasePart? = nil
		for _, child in gearInstance:GetChildren() do
			if child:IsA("Model") then
				child.Parent = wrapper
				if not pickedPrimary and child.PrimaryPart then
					pickedPrimary = child.PrimaryPart
				end
			end
		end

		if not pickedPrimary then
			warn(
				("[GearDropService] Armor piece folder '%s' has no child Model with a PrimaryPart"):format(
					gearInstance.Name
				)
			)
			wrapper:Destroy()
			gearInstance:Destroy()
			return nil
		end

		wrapper.PrimaryPart = pickedPrimary
		gearInstance:Destroy()
		return wrapper
	end

	warn(("[GearDropService] Unsupported prefab class '%s'"):format(gearInstance.ClassName))
	gearInstance:Destroy()
	return nil
end

-- Builds the invisible carrier Part. The gear is welded to this; the
-- client component CFrames this part directly to drive bezier + bob.
-- Anchored=true so physics doesn't run; the component drives CFrame.
function GearDropService:_buildCarrierPart(landingPosition: Vector3): BasePart
	local carrier = Instance.new("Part")
	carrier.Name = "Carrier"
	carrier.Size = CARRIER_SIZE
	carrier.Transparency = 1
	carrier.CanCollide = false
	carrier.CanQuery = false
	carrier.CanTouch = false
	carrier.Anchored = true
	carrier.CFrame = CFrame.new(landingPosition)
	carrier.Massless = true
	return carrier
end

-- Positions the gear Model at the carrier's CFrame before welding so
-- the relative offset is "carrier at gear-root." After welding, this
-- offset is locked in — moving carrier moves the whole gear rigidly.
function GearDropService:_pivotGearToCarrier(visualModel: Model, carrier: BasePart)
	if visualModel.PrimaryPart then
		visualModel:PivotTo(carrier.CFrame)
		return
	end
	-- Fallback for Models without PrimaryPart (common — artists often
	-- forget to set it). Translate every BasePart by (carrier-CFrame -
	-- first-part-CFrame), equivalent to "what PivotTo would do."
	local firstPart: BasePart? = nil
	for _, descendant in visualModel:GetDescendants() do
		if descendant:IsA("BasePart") then
			firstPart = descendant
			break
		end
	end
	if not firstPart then
		return
	end
	local translation = carrier.CFrame * firstPart.CFrame:Inverse()
	for _, descendant in visualModel:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.CFrame = translation * descendant.CFrame
		end
	end
end

-- Pivots the visual so its BOUNDING-BOX CENTER lands at the carrier's
-- CFrame, regardless of where the model's pivot (PrimaryPart) actually
-- sits. Used by armor pieces where the wrapper's PrimaryPart is
-- "whichever limb's PrimaryPart we encountered first while iterating
-- the slot folder" — a stable but arbitrary choice that lands on a
-- corner limb (Left Arm for Chestplate, Left Leg for Greaves), which
-- would otherwise dangle the visual off one side of the floating
-- carrier + ProximityPrompt.
--
-- Why bounding-box centering instead of a per-slot "anchor limb"
-- convention (e.g. Chestplate→Torso, Greaves→???):
--   * Greaves has no natural center limb — Left Leg and Right Leg sit
--     symmetric around the player's hips, and no child Model lives at
--     the midpoint. Any "designated center" rule needs a per-slot
--     special-case for it.
--   * Future slots (Cape, Gauntlets, Boots) inherit the same problem
--     and the rule grows another entry.
--   * Geometric center is universally correct without naming conventions.
--
-- Math:
--   pivotToCenter = pivot:Inverse() * boxCFrame
--     -- expresses the bounding-box center in the pivot's LOCAL frame.
--   After PivotTo(T):
--     pivot ends up at T
--     box center ends up at T * pivotToCenter
--   We want T * pivotToCenter = carrier.CFrame, so:
--     T = carrier.CFrame * pivotToCenter:Inverse()
function GearDropService:_pivotGearCenteredOnCarrier(visualModel: Model, carrier: BasePart)
	if not visualModel.PrimaryPart then
		-- No PrimaryPart → no defined pivot to offset from. Fall
		-- through to the existing PrimaryPart-less translation path
		-- which already centers on the assembly's first part.
		self:_pivotGearToCarrier(visualModel, carrier)
		return
	end
	local boxCFrame = visualModel:GetBoundingBox()
	local pivotToCenter = visualModel:GetPivot():Inverse() * boxCFrame
	visualModel:PivotTo(carrier.CFrame * pivotToCenter:Inverse())
end

-- WeldConstraint every BasePart in the visual model to the carrier.
-- Sets Anchored=false on each (welds can't hold anchored parts in a
-- moving assembly). The carrier itself stays anchored — the component
-- drives its CFrame directly.
function GearDropService:_weldGearToCarrier(gearInstance: Instance, carrier: BasePart)
	for _, descendant in gearInstance:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = false
			descendant.CanCollide = false
			descendant.Massless = true

			local weld = Instance.new("WeldConstraint")
			weld.Part0 = carrier
			weld.Part1 = descendant
			weld.Parent = carrier
		end
	end
end

-- Lifts the model so the BOTTOM of its bounding box sits at
-- `desiredBottomY`. Mirrors the lobby-pad snap pattern in
-- EncounterService._createLobbyPad. Without this, the carrier sits at
-- floorY + LANDING_Y_ABOVE_GROUND but the model's mesh parts span
-- whatever the prefab geometry dictates — for tall armor (humanoid-
-- bust scale even after the 0.75 client-side idle scale) the feet
-- end up well below the floor.
--
-- Operates on the already-welded assembly so the carrier and the
-- visual parts move together. PivotTo on the Model translates the
-- PrimaryPart (carrier) and welds drag the rest.
--
-- Caveat: bounding box is measured at server-side scale = 1. The
-- client component applies the per-gear-type idle scale (0.75 for
-- armor, 1.35 for ranged weapons, 1.0 for melee) AFTER replication,
-- so the final visual bottom drifts slightly from `desiredBottomY` in
-- proportion to (1 - idleScale). Net result: armor sits a touch
-- higher than LANDING_Y_ABOVE_GROUND after it's scaled to 0.75,
-- never clips into the floor.
function GearDropService:_snapModelBottomToHeight(model: Model, desiredBottomY: number)
	local bbCFrame, bbSize = model:GetBoundingBox()
	local currentBottomY = bbCFrame.Position.Y - (bbSize.Y / 2)
	local liftY = desiredBottomY - currentBottomY
	if liftY ~= 0 then
		model:PivotTo(model:GetPivot() + Vector3.new(0, liftY, 0))
	end
end

-- Clones the rarity-matched particle attachment from GameAssets.Particles
-- and parents it to the carrier. Warns + no-ops on missing folder /
-- prefab / mapping — the drop still works, just without VFX.
function GearDropService:_attachRarityParticles(carrier: BasePart, rarity: string)
	local particleName = RARITY_TO_PARTICLE[rarity]
	if not particleName then
		warn(("[GearDropService] No particle mapping for rarity '%s'"):format(tostring(rarity)))
		return
	end
	local assets = ReplicatedStorage:FindFirstChild("GameAssets")
	local particlesFolder = assets and assets:FindFirstChild("Particles")
	if not particlesFolder then
		return
	end
	local prefab = particlesFolder:FindFirstChild(particleName)
	if not prefab then
		return
	end

	for _, child in prefab:GetChildren() do
		if child:IsA("ParticleEmitter") then
			child.Color = ColorSequence.new(RarityColors:Get(rarity))
		end
	end

	prefab:Clone().Parent = carrier
end

-- Clones the Collected + DropAttachment prefabs to the carrier. Mirrors
-- the DropService pattern (relic drops also receive these two).
-- Collected = one-shot burst, recolored per rarity, :Emit()ed by the
-- client component on Triggered. DropAttachment = ambient stream while
-- the drop sits on the floor; not recolored.
function GearDropService:_attachPickupBurstAttachments(carrier: BasePart, rarity: string)
	local assets = ReplicatedStorage:FindFirstChild("GameAssets")
	local particlesFolder = assets and assets:FindFirstChild("Particles")
	if not particlesFolder then
		return
	end

	local rarityColor = RarityColors:Get(rarity)

	local collectedTemplate = particlesFolder:FindFirstChild(COLLECTED_ATTACHMENT_NAME)

	if collectedTemplate then
		local collected = collectedTemplate:Clone()
		for _, child in collected:GetChildren() do
			if child:IsA("ParticleEmitter") then
				child.Color = ColorSequence.new(rarityColor)
			end
		end
		collected.Parent = carrier
	end

	local dropAttachmentTemplate = particlesFolder:FindFirstChild(DROP_ATTACHMENT_NAME)

	if dropAttachmentTemplate then
		local dropClone = dropAttachmentTemplate:Clone()

		dropClone.Parent = carrier
	end
end

-- Clones the shared RelicName BillboardGui prefab and populates it with
-- the drop's name + rarity. NameText format matches the client
-- ProximityPrompt's ActionText ("Lvl. N Name"). The client component
-- adjusts text sizes for mobile in its Construct.
function GearDropService:_attachBillboardGui(_carrier: BasePart, _gearName: string, _level: number, _rarity: string)
	-- local assets = ReplicatedStorage:FindFirstChild("GameAssets")
	-- local billboardsFolder = assets and assets:FindFirstChild("BillboardGuis")
	-- local template = billboardsFolder and billboardsFolder:FindFirstChild(BILLBOARD_NAME)
	-- if not template then
	-- 	return
	-- end

	-- local billboard = template:Clone()
	-- billboard.Adornee = carrier
	-- billboard.Frame.NameText.Text = "Lvl. " .. tostring(level) .. " " .. tostring(gearName)
	-- billboard.Frame.RarityText.Text = rarity
	-- billboard.Frame.RarityText.TextColor3 = RarityColors:Get(rarity)
	-- billboard.AlwaysOnTop = true
	-- billboard.Parent = carrier
end

-- Builds the full GearDrop model server-side. Single point of asset
-- assembly (visual + particles + billboard + attributes + tag). The
-- returned model is parented under workspace.IgnoreInstances.GearDrops
-- and tagged, which auto-attaches the server + client GearDrop
-- components.
function GearDropService:_buildDropModel(
	uuid: string,
	gearName: string,
	gearType: string,
	rarity: string,
	description: string,
	originPosition: Vector3,
	landingPosition: Vector3,
	ownerId: number,
	level: number,
	fromChest: boolean?
): Model?
	local assetFolder = self:_resolveAssetFolder(gearType)
	if not assetFolder then
		warn(("[GearDropService] No asset folder for gearType '%s'"):format(tostring(gearType)))
		return nil
	end

	-- Asset lookup branches on gear type.
	--   Weapons: `GameAssets.Weapons[<gearName>]` (Accessory prefab).
	--   Armor:   `GameAssets.Armor[<setName>][<slot>]` (Folder of limb
	--            Models). The piece name is per-slot ("Enforcer Helmet"),
	--            but the asset is organized by set then slot — so we
	--            look up ArmorPieceData[<gearName>] to bridge.
	local prefab: Instance?
	local armorSlot: string? = nil

	if gearType == GearTypes.Armor then
		local pieceData = ArmorPieceData[gearName]
		if not pieceData then
			warn(("[GearDropService] No ArmorPieceData entry for '%s'"):format(tostring(gearName)))
			return nil
		end
		armorSlot = pieceData.slot
		local setFolder = assetFolder:FindFirstChild(pieceData.setName)
		if not setFolder then
			warn(
				("[GearDropService] No armor set folder '%s' under GameAssets.Armor"):format(
					tostring(pieceData.setName)
				)
			)
			return nil
		end
		prefab = setFolder:FindFirstChild(pieceData.slot)
		if not prefab then
			warn(
				("[GearDropService] Set '%s' missing slot folder '%s'"):format(
					tostring(pieceData.setName),
					tostring(pieceData.slot)
				)
			)
			return nil
		end
	else
		prefab = assetFolder:FindFirstChild(gearName)
		if not prefab then
			warn(("[GearDropService] No prefab '%s' in asset folder"):format(tostring(gearName)))
			return nil
		end
	end

	local clonedPrefab = prefab:Clone()
	local visualModel = self:_normalizeGearVisual(clonedPrefab)
	if not visualModel then
		return nil
	end

	local carrier = self:_buildCarrierPart(landingPosition)

	local model = Instance.new("Model")
	model.Name = "GearDrop_" .. uuid:sub(1, 8)

	carrier.Parent = model
	model.PrimaryPart = carrier

	visualModel.Parent = model
	-- Pivot policy by gear type:
	--   * Weapons: PrimaryPart-anchored pivot. The Accessory's Handle
	--     (now the visualModel's PrimaryPart) sits at the grip — a
	--     natural spin/bob anchor, and the visual reads centered for
	--     most weapons because the grip is roughly mid-length.
	--   * Armor:   Bounding-box centered pivot. The wrapper's
	--     PrimaryPart is an arbitrary corner limb's PrimaryPart;
	--     anchoring there dangles the assembly off one side of the
	--     carrier + ProximityPrompt. Centering puts the visible armor
	--     mass on the prompt.
	if gearType == GearTypes.Armor then
		self:_pivotGearCenteredOnCarrier(visualModel, carrier)
	else
		self:_pivotGearToCarrier(visualModel, carrier)
	end
	self:_weldGearToCarrier(visualModel, carrier)

	-- Apply the per-gear-type idle scale BEFORE attaching particles +
	-- billboard. Model:ScaleTo rescales ParticleEmitter.Size (and other
	-- size-like properties) of children that exist at the time it's
	-- called — so attaching emitters AFTER this means they keep their
	-- authored Size at any idle scale (armor at 0.75 no longer has 75%-
	-- sized rarity particles).
	--
	-- Snap-to-height runs against the POST-scale bounding box so the
	-- lift reflects the actual visual extent the player will see, not
	-- the natural-1× extent.
	--
	-- The client component still calls ScaleTo(idleScale) on Construct;
	-- that's a no-op when the server already set the same value, but
	-- it serves as a safety net if a future change drops the server-
	-- side scaling. The client's hover-scale tween still rescales the
	-- particles temporarily (since they're inside the model hierarchy),
	-- but the idle state — which is what players see 95% of the time —
	-- now displays particles at their authored size.
	local idleScale = getGearIdleScale(gearName, gearType)
	model:ScaleTo(idleScale)

	-- Now that the visual is welded AND scaled, measure the bounding
	-- box and lift so the BOTTOM sits at landingPosition.Y (= floorY +
	-- LANDING_Y_ABOVE_GROUND). Without this, large items like armor
	-- would have their feet clip through the floor — the carrier-at-
	-- landing position only positions the pivot, not the mesh extents.
	self:_snapModelBottomToHeight(model, landingPosition.Y)

	self:_attachRarityParticles(carrier, rarity)
	self:_attachPickupBurstAttachments(carrier, rarity)
	self:_attachBillboardGui(carrier, gearName, level, rarity)

	-- Metadata. OwnerId gates pickup; OriginPosition lets the client
	-- bezier the visual from the mob's death position rather than the
	-- spawn-at-landing position. GearLevel drives prompt text + the
	-- inventory entry's `level` field on pickup.
	model:SetAttribute(ATTR_UUID, uuid)
	model:SetAttribute(ATTR_NAME, gearName)
	model:SetAttribute(ATTR_TYPE, gearType)
	model:SetAttribute(ATTR_RARITY, rarity)
	model:SetAttribute(ATTR_DESCRIPTION, description)
	model:SetAttribute(ATTR_LEVEL, level)
	model:SetAttribute(ATTR_OWNER_ID, ownerId)
	model:SetAttribute(ATTR_ORIGIN_POSITION, originPosition)
	if fromChest then
		-- Out of an encounter chest: the client blips it on pop-out, the
		-- same way that chest's coins do.
		model:SetAttribute(ATTR_FROM_CHEST, true)
	end
	-- Armor pickups need to know which sub-array of Inventory.Gear to
	-- push into. Stamp the slot here (nil for weapons; the pickup
	-- component branches on gear type before reading this).
	if armorSlot then
		model:SetAttribute(ATTR_SLOT, armorSlot)
	end

	-- Tag LAST so both server + client component Construct against a
	-- fully-built model (PrimaryPart set, gear welded, attributes
	-- populated).
	CollectionService:AddTag(model, TagList.GearDrop)
	model.Parent = self:_ensureDropFolder()

	return model
end

function GearDropService:_fireSingleDrop(
	player: Player,
	originPosition: Vector3,
	entry: { name: string, type: string, weight: number },
	fromChest: boolean?
): string?
	local gearData = self:_getGearData(entry.name, entry.type)

	-- Rarity resolution policy (refactor: drops now roll rarity at drop
	-- time):
	--   1. If the data file pins a `rarity` field on the entry, use it
	--      verbatim. Legendaries (Susanoo Armor, Domain Expansion,
	--      Ghost Dragon, etc.) declare `rarity = ItemRarity.Legendary`
	--      so they ALWAYS land at Legendary regardless of where they
	--      dropped. Designer-only escape hatch — also useful for
	--      story-locked unique items later.
	--   2. Otherwise roll a rarity via the active dungeon difficulty's
	--      `rarityWeights` table (DungeonData.<id>.difficulties.<diff>.
	--      rarityWeights). Same item dropped on Easy lands Common-heavy;
	--      dropped on Nightmare lands Epic-heavy.
	--   3. If no dungeon is active (ad-hoc test calls, lobby drops),
	--      rollItemRarity's nil-table branch returns ItemRarity.Common
	--      as the safe default. The drop still works, just at base tier.
	--
	-- (Pinata's gear floor used to apply here; the relic is now a Cursed
	-- vending-machine relic and gear drops roll the authored weights only.)
	--
	--   Applies to both Weapon and Armor drops (the only two GearTypes
	--   that flow through this service). Magic spells drop via a
	--   different path and are unaffected — matches the spec.
	local rarity
	if gearData and gearData.rarity then
		rarity = gearData.rarity
	else
		local weights = self:_getActiveRarityWeights()
		rarity = rollItemRarity(weights, ItemRarity.Common)
	end
	local description = (gearData and gearData.description) or ""
	local uuid = HttpService:GenerateGUID(false)

	local landingPosition = self:_pickLandingPosition(originPosition)
	-- Wall ricochet, shared with every other arc: a scatter that crossed
	-- a dungeon wall reflects back into the room. floorOffset re-derives
	-- the height over whatever floor the reflected point is on.
	local bouncePosition
	landingPosition, bouncePosition =
		resolveArcLanding(originPosition, landingPosition, { floorOffset = LANDING_Y_ABOVE_GROUND })
	-- Per-drop level roll using the active dungeon's levelRange. Each
	-- drop gets its own roll — a Boss with dropCount = {2, 3} can land
	-- gear at three different levels in one kill.
	local level = self:_rollGearLevel()

	local model = self:_buildDropModel(
		uuid,
		entry.name,
		entry.type,
		rarity,
		description,
		originPosition,
		landingPosition,
		player.UserId,
		level,
		fromChest
	)
	if not model then
		return nil
	end
	if bouncePosition then
		model:SetAttribute(ATTR_BOUNCE_POSITION, bouncePosition)
	end
	return uuid
end

--[ Public API ]--

function GearDropService:DropGear(
	player: Player,
	originPosition: Vector3,
	enemyType: string?,
	fromChest: boolean?
): { string }
	if not player or not player.Parent then
		return {}
	end

	local dropConfig = self:_getActiveDropConfig()
	if not dropConfig then
		-- Studio-only warn — production mobs that die outside a dungeon
		-- (lobby, non-dungeon places, etc.) shouldn't pollute QA bug
		-- report logs. In Studio it surfaces misconfigured pools that
		-- the dev would want to catch.
		if RunService:IsStudio() then
			warn(("[GearDropService] DropGear: no active dungeon pool (player=%s)"):format(player.Name))
		end
		return {}
	end

	local pool = dropConfig.pool
	if not pool or #pool == 0 then
		warn("[GearDropService] DropGear: pool is empty")
		return {}
	end

	local enemyConfig = self:_resolveEnemyDropConfig(dropConfig, enemyType)
	-- Pinata: "+10% Dungeon Drop chance" — ×1.10 on the configured gear
	-- drop chance for owners (its rarity half is the escalating floor
	-- below).
	local dropChance = enemyConfig.dropChance
	if math.random() > dropChance then
		return {}
	end

	local countMin = enemyConfig.dropCount[1]
	local countMax = enemyConfig.dropCount[2]
	local dropCount = math.random(countMin, countMax)

	-- GUARANTEED COUNT. A rolled entry can fail to BUILD — its prefab or
	-- armor-set folder missing under GameAssets (_buildDropModel /
	-- _normalizeGearVisual warn which). That used to silently cost the
	-- player the drop: a miniboss chest could pay 0 of its 2. Now a failed
	-- slot re-rolls from the pool MINUS the entry that failed, bounded by
	-- the pool size, so an asset problem is a warn to go fix rather than
	-- lost loot. The count is dropCount exactly unless every candidate in
	-- the pool is broken, which gets its own warn below.
	local uuids: { string } = {}
	for slot = 1, dropCount do
		if fromChest then
			-- Yielding is safe here: the only chest caller is
			-- EncounterChestService:_openChest, which runs inside a
			-- ProximityPrompt.Triggered handler and so has its own coroutine.
			-- The coin payout that follows it is delayed by the same total,
			-- which reads as gear first, then coins.
			task.wait(CHEST_DROP_STAGGER_SECONDS)
		end
		local candidates = table.clone(pool)
		local uuid: string? = nil
		for _ = 1, #pool do
			local entry = self:_rollFromPool(candidates)
			if not entry then
				break
			end
			uuid = self:_fireSingleDrop(player, originPosition, entry, fromChest)
			if uuid then
				break
			end
			local failedIndex = table.find(candidates, entry)
			if failedIndex then
				table.remove(candidates, failedIndex)
			end
		end
		if uuid then
			table.insert(uuids, uuid)
		else
			warn(
				("[GearDropService] DropGear: slot %d of %d could not be filled — every pool entry failed to build (see the warns above)"):format(
					slot,
					dropCount
				)
			)
		end
	end
	return uuids
end

-- Gear a PLAYER dropped, keyed by its uuid: the exact escrow entry that
-- left their run inventory. A normal pickup BUILDS an entry, rolling a
-- fresh quality and enchantment (GearDrop:_buildInventoryEntry) — fine
-- for loot appearing for the first time, wrong for an item that already
-- exists, which would silently re-roll its stats every time it changed
-- hands. Whoever picks one of these up gets the item as it was.
GearDropService._preservedEntries = {} :: { [string]: { [string]: any } }

-- The entry a player dropped under this uuid, if any. Does NOT consume
-- it: the pickup can still be refused by the run item cap, and the drop
-- has to stay on the floor intact when it is.
function GearDropService:GetPreservedEntry(uuid: string): { [string]: any }?
	return self._preservedEntries[uuid]
end

-- Called once a preserved entry has actually been granted.
function GearDropService:ReleasePreservedEntry(uuid: string)
	self._preservedEntries[uuid] = nil
end

-- Drops an item the player ALREADY OWNS onto the floor around them, as a
-- PUBLIC drop anyone can take (including them). Nothing is rolled: the
-- name, rarity, level and uuid all come from the escrow entry, and the
-- entry itself is held until pickup so quality and enchantment survive
-- the round trip.
--
-- Landing goes through the same scatter and wall ricochet as loot, so a
-- drop made with your back to a wall arcs off it and lands in the room
-- instead of inside the geometry.
--
-- Returns false having spawned nothing when the model cannot be built,
-- so the caller can put the item back in the escrow.
function GearDropService:DropExistingGear(
	player: Player,
	originPosition: Vector3,
	escrowItem: { [string]: any }
): boolean
	local item = escrowItem and escrowItem.item
	local gearType = escrowItem and escrowItem.gearType
	if type(item) ~= "table" or type(gearType) ~= "string" then
		warn("[GearDropService] DropExistingGear: malformed escrow entry")
		return false
	end

	local uuid = item.uuid
	if type(uuid) ~= "string" or uuid == "" then
		uuid = HttpService:GenerateGUID(false)
	end

	local gearData = self:_getGearData(item.name, gearType)
	local description = (gearData and gearData.description) or ""

	local landingPosition = self:_pickLandingPosition(originPosition)
	local bouncePosition
	landingPosition, bouncePosition =
		resolveArcLanding(originPosition, landingPosition, { floorOffset = LANDING_Y_ABOVE_GROUND })

	local model = self:_buildDropModel(
		uuid,
		item.name,
		gearType,
		item.rarity or ItemRarity.Common,
		description,
		originPosition,
		landingPosition,
		player.UserId,
		item.level or 1,
		false
	)
	if not model then
		return false
	end
	if bouncePosition then
		model:SetAttribute(ATTR_BOUNCE_POSITION, bouncePosition)
	end
	-- OwnerId stays stamped (the drop still knows who threw it) but
	-- PublicDrop is what both components actually read, and it opens the
	-- pickup to everyone.
	model:SetAttribute(ATTR_PUBLIC_DROP, true)

	-- ORIGINAL owner, not the last one to let go of it. The first player
	-- to drop this item stamps their name onto the ITEM, and every drop
	-- after that reads it back — so a piece passed from Player1 to
	-- Player2 to Player3 still reads (Player1) on the floor.
	--
	-- It lives on the inventory entry rather than the drop model because
	-- the model is destroyed the moment someone takes it. The entry is
	-- what actually round-trips: it is held in _preservedEntries while the
	-- item is on the floor and restored verbatim on pickup, so the fields
	-- written below come back with it next time.
	local originId = item.originalOwnerId
	local originName = item.originalOwnerName
	if type(originId) ~= "number" or type(originName) ~= "string" then
		originId = player.UserId
		originName = player.Name
	end
	model:SetAttribute(ATTR_DROPPED_BY, originName)
	model:SetAttribute(ATTR_DROPPED_BY_ID, originId)

	local preservedItem = table.clone(item)
	preservedItem.originalOwnerId = originId
	preservedItem.originalOwnerName = originName
	self._preservedEntries[uuid] = {
		gearType = gearType,
		armorSlot = escrowItem.armorSlot,
		item = preservedItem,
	}
	return true
end

--[ Lifecycle ]--

function GearDropService:KnitInit()
	DungeonService = Knit.GetService("DungeonService")
	-- RelicService is read inside the rarity roll for Pinata's
	-- "Rare-or-higher floor on weapon / armor drops" effect.
end

return GearDropService
