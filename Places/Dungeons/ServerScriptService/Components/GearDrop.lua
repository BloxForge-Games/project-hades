--[[
	Module: GearDrop.lua (Server-side component)
	Description:
	Owner-validation + inventory-grant + expire-timer counterpart to the
	client-side GearDrop component. Both attach to the same TagList.GearDrop
	tagged Model that GearDropService spawns in workspace.

	Architecture mirrors Server/Components/Relic.lua:
	  * Construct creates a `_comm:CreateSignal("OnGearCollected")` so the
	    client component (on the same Instance) can `_comm:GetSignal(...)`
	    and Fire it on prompt Triggered.
	  * Start hooks the signal — when it fires, this component validates
	    the player matches the model's OwnerId attribute, grants the
	    inventory item, and destroys the model.
	  * Construct also schedules a task.delay for the 120s expire window;
	    if no one picks the drop up by then, it sets the Expired attribute
	    (so the client can fade) and destroys after the fade duration.

	The GearDropService no longer fires Knit Client signals for pickup /
	expire — that responsibility moved here so the server logic lives
	next to the tagged Instance instead of being plumbed via uuids
	through a pair of remotes.
]]

--[ Roblox Services ]--

local ReplicatedStorage = game:GetService("ReplicatedStorage")

--[ Imports ]--

local Component = require(ReplicatedStorage.Submodules.Core.Packages.Component)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local CommAdder = require(ReplicatedStorage.Submodules.Core.Source.ComponentExtensions.CommAdder)
local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local GearTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.GearTypes)
local EnchantmentNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.EnchantmentNames)
local ItemRarity = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ItemRarity)

-- Weapon-drop enchantment roll: ENCHANTMENT_CHANCE of rolling one at all,
-- then a uniform pick from the pool. Looter only — the status
-- enchantments were removed (relics own status application now).
-- Armor never rolls enchantments.
local ENCHANTMENT_CHANCE = 0.25
local ENCHANTMENT_POOL = {
	EnchantmentNames.Looter,
}

local RunEscrowService
local TextIndicatorService
local GearDropService

Knit.OnStart()
	:andThen(function()
		RunEscrowService = Knit.GetService("RunEscrowService")
		TextIndicatorService = Knit.GetService("TextIndicatorService")
		GearDropService = Knit.GetService("GearDropService")
	end)
	:catch(warn)

--[ Constants ]--

-- scalarMultiplier roll range for granted inventory items. Range agreed
-- with the user — DataTemplate's hand-authored entries sit in
-- [0.85, 1.15]; runtime drops roll wider variance per spec.
local SCALAR_MULTIPLIER_MIN = 0.5
local SCALAR_MULTIPLIER_MAX = 1

-- Attribute names — must match what GearDropService writes when spawning
-- the model and what the client component reads for the prompt UI.
local ATTR_NAME = "GearName"
local ATTR_TYPE = "GearType"
local ATTR_LEVEL = "GearLevel"
local ATTR_RARITY = "GearRarity"
local ATTR_OWNER_ID = "OwnerId"
-- Raised on pickup. Every client watches it to kill the prompt + label
-- and fade the model; the destroy follows POST_FADE_DESTROY_DELAY later.
local ATTR_EXPIRED = "Expired"
-- The client fade (FADE_DURATION, 0.5s) plus a margin, so the model is
-- never pulled out from under a tween still running.
local POST_FADE_DESTROY_DELAY = 0.65
-- Attributes.PublicDrop: a player dropped this from their run inventory.
-- Anyone may pick it up, so the OwnerId gate below is skipped.
local ATTR_PUBLIC_DROP = "PublicDrop"
-- UUID stamped by GearDropService at drop time (HttpService:GenerateGUID).
-- We propagate it onto the inventory entry's `uuid` field on pickup so
-- the Inventory UI + InventoryService have a stable handle on the item
-- across sorts, equips, and future reorders. Array-index identification
-- would race with the equipped-first sort the Inventory UI applies.
local ATTR_UUID = "GearUuid"
-- Armor only: which slot ("Helmet" / "Chestplate" / "Greaves") the
-- piece feeds. Stamped by GearDropService when building an armor
-- drop; nil for weapons.
local ATTR_SLOT = "GearSlot"

-- Fallback level for the granted inventory entry if the model is
-- missing its ATTR_LEVEL attribute (defensive — GearDropService should
-- always set it, but a hand-spawned drop in Studio might not).
local DEFAULT_INVENTORY_LEVEL = 1

--[ Component ]--

local GearDrop = Component.new({
	Tag = TagList.GearDrop,
	Extensions = { CommAdder },
})

--[ Private helpers ]--

-- Builds the inventory entry table for a given drop. Shape mirrors
-- DataTemplate's existing entries so the existing loadout / equip code
-- consumes new drops the same as starter items.
--
-- `level` is the gear level — rolled server-side by
-- GearDropService:_rollGearLevel using the active dungeon's
-- difficulty.levelRange, then stamped on ATTR_LEVEL. _grantInventory
-- reads the attribute and passes it here so the inventory entry's
-- persisted level matches what the player saw in the pickup prompt.
--
-- `rarity` is the rolled rarity from GearDropService:_fireSingleDrop —
-- either the data file's static rarity (legendaries) or a roll against
-- the active dungeon's `rarityWeights`. Stored per-instance because
-- every drop is its own inventory entry (two Common AKs and one Epic AK
-- coexist as three separate items). Damage code uses this stored value
-- with RarityMultipliers to scale base damage at use time.
function GearDrop:_buildInventoryEntry(
	gearName: string,
	gearType: string,
	level: number,
	rarity: string,
	uuid: string
): { [string]: any }
	local scalarMultiplier = math.round(
		(SCALAR_MULTIPLIER_MIN + math.random() * (SCALAR_MULTIPLIER_MAX - SCALAR_MULTIPLIER_MIN)) * 100
	) / 100

	if gearType == GearTypes.Weapon then
		local enchantment = EnchantmentNames.None
		if math.random() <= ENCHANTMENT_CHANCE then
			enchantment = ENCHANTMENT_POOL[math.random(1, #ENCHANTMENT_POOL)]
		end
		return {
			uuid = uuid,
			name = gearName,
			enchantment = enchantment,
			rarity = rarity,
			level = level,
			upgrades = 0,
			equipSlot = 0,
			scalarMultiplier = scalarMultiplier,
			-- Placeholder retained per design decision; bonusStats is
			-- shelved but the field stays so a future re-enable
			-- doesn't require a profile migration.
			bonusStats = {},
			shiny = false,
		}
	else
		-- Armor piece shape. Uses `equipped: boolean` (not
		-- `equipSlot: number`) because armor slots are partitioned
		-- across sub-arrays of Inventory.Gear (Helmet / Chestplate /
		-- Greaves) — there's no slot index; the array key IS the slot.
		-- `equipped = false` on pickup so we don't silently displace
		-- whatever piece the player already has equipped; they choose
		-- to equip via the inventory UI.
		return {
			uuid = uuid,
			name = gearName,
			enchantment = EnchantmentNames.None,
			rarity = rarity,
			level = level,
			upgrades = 0,
			equipped = false,
			scalarMultiplier = scalarMultiplier,
			bonusStats = {},
			shiny = false,
		}
	end
end

-- Pushes the rolled item into the player's RUN ESCROW (death economy —
-- see RunEscrowService / Docs/DeathEconomySpec.md). Nothing touches the
-- profile at pickup time: the escrow banks to the profile on dungeon
-- clear, or is discarded on death/disconnect.
--
-- Returns true on success, false when the run item cap rejects the
-- pickup — the caller only destroys the drop model on true, so a
-- rejected pickup leaves the drop on the ground (the player can see
-- what they couldn't carry until it expires normally).
function GearDrop:_grantInventory(
	player: Player,
	gearName: string,
	gearType: string,
	level: number,
	rarity: string,
	armorSlot: string?,
	uuid: string
): boolean
	if gearType ~= GearTypes.Weapon and gearType ~= GearTypes.Armor then
		warn(("[GearDrop] Unknown gearType '%s'; can't grant"):format(tostring(gearType)))
		return false
	end

	-- Armor routes into profile.Inventory.Gear[<slot>] at BANK time, so
	-- the slot has to be present now — reject early rather than escrow
	-- an entry that can't be banked later.
	if gearType == GearTypes.Armor and not armorSlot then
		warn(
			("[GearDrop] Armor pickup '%s' missing slot attribute — can't route to a Gear sub-array"):format(
				tostring(gearName)
			)
		)
		return false
	end

	-- An item a PLAYER dropped already exists, so it is restored rather
	-- than rebuilt: _buildInventoryEntry rolls a fresh quality and
	-- enchantment every call, which would re-roll the item's stats each
	-- time it changed hands. Released only once the escrow accepts it, so
	-- a pickup refused by the run item cap leaves the drop intact.
	local preserved = GearDropService and GearDropService:GetPreservedEntry(uuid)
	if preserved then
		if not RunEscrowService:AddItem(player, preserved) then
			return false
		end
		GearDropService:ReleasePreservedEntry(uuid)
		return true
	end

	local item = self:_buildInventoryEntry(gearName, gearType, level, rarity, uuid)

	return RunEscrowService:AddItem(player, {
		gearType = gearType,
		armorSlot = armorSlot,
		item = item,
	})
end

-- Raises the Expired attribute, which every client watches: each one
-- kills the drop's prompt and label AT ONCE and fades the model out.
-- The instance follows once that fade has had time to play.
--
-- The expire TIMER that used to share this path is gone (drops no longer
-- time out), so a pickup is its only caller now.
function GearDrop:_fadeAndDestroy()
	if not self.Instance or not self.Instance.Parent then
		return
	end
	self.Instance:SetAttribute(ATTR_EXPIRED, true)
	local instance = self.Instance
	task.delay(POST_FADE_DESTROY_DELAY, function()
		if instance and instance.Parent then
			instance:Destroy()
		end
	end)
end

--[ Lifecycle ]--

function GearDrop:Construct()
	-- Create the comm signal. The client component (attached to the same
	-- Instance) reads this via `_comm:GetSignal("OnGearCollected")` and
	-- fires it on prompt Triggered.
	self._onGearCollected = self._comm:CreateSignal("OnGearCollected")

	-- Track whether we've already granted this drop. Prevents a race
	-- where the player rapid-fire-clicks before we destroy the model.
	self._collected = false

	-- NO expire timer. Drops used to fade out after 120 seconds; they now
	-- sit on the floor until someone takes them or the floor is torn down
	-- with the dungeon. A player who drops an item to hand it to a
	-- teammate should not lose it to a clock, and the same courtesy is
	-- extended to mob loot. Only a pickup removes a drop now, through
	-- _fadeAndDestroy.
end

function GearDrop:Start()
	self._onGearCollected:Connect(function(player: Player)
		-- Idempotency — drops the second click on the floor.
		if self._collected then
			return
		end

		-- Owner gate. The client component on this Instance only enables
		-- the prompt for the owner, but a spoofed Fire from any player
		-- could land here, so re-validate server-side. A PUBLIC drop (one a
		-- player dropped from their run inventory) has no owner to check:
		-- anyone may take it, the dropper included.
		local isPublic = self.Instance:GetAttribute(ATTR_PUBLIC_DROP) == true
		local ownerId = self.Instance:GetAttribute(ATTR_OWNER_ID)
		if not isPublic and player.UserId ~= ownerId then
			return
		end

		local gearName = self.Instance:GetAttribute(ATTR_NAME)
		local gearType = self.Instance:GetAttribute(ATTR_TYPE)
		if typeof(gearName) ~= "string" or typeof(gearType) ~= "string" then
			warn("[GearDrop] Pickup rejected — missing GearName/GearType attribute")
			return
		end

		-- Level read off the model so the granted inventory entry's
		-- `level` matches what the player saw in the pickup prompt /
		-- billboard ("Lvl. N Name"). Falls back to
		-- DEFAULT_INVENTORY_LEVEL if the attribute is missing
		-- (defensive — hand-spawned Studio drops, malformed builder).
		local level = self.Instance:GetAttribute(ATTR_LEVEL) or DEFAULT_INVENTORY_LEVEL

		-- Rarity read off the model. GearDropService stamps the rolled
		-- (or legendary-pinned) rarity here. Common fallback covers
		-- legacy / hand-spawned drops that predate the rarity-roll
		-- refactor and don't carry the attribute.
		local rarity = self.Instance:GetAttribute(ATTR_RARITY) or ItemRarity.Common

		-- Armor slot read off the model. Stamped by GearDropService
		-- for armor pieces via ArmorPieceData lookup; nil for weapons
		-- (and they don't need it — _grantInventory's Weapon branch
		-- doesn't reference armorSlot).
		local armorSlot = self.Instance:GetAttribute(ATTR_SLOT)

		-- UUID read off the model. Stamped by GearDropService at drop
		-- time and propagated onto the inventory entry's `uuid` field
		-- via _buildInventoryEntry. Defensive fallback if missing
		-- (legacy / hand-spawned drops) — generate one client-side so
		-- the inventory entry is never UUID-less.
		local uuid = self.Instance:GetAttribute(ATTR_UUID)
		if typeof(uuid) ~= "string" or uuid == "" then
			uuid = game:GetService("HttpService"):GenerateGUID(false)
		end

		if not self:_grantInventory(player, gearName, gearType, level, rarity, armorSlot, uuid) then
			return -- inventory write failed; client visual stays so player can retry
		end

		-- Adorned to the CHARACTER, not the drop: the drop is destroyed on
		-- the next line and would take the indicator with it.
		local character = player.Character
		local indicatorPart = character
			and (character:FindFirstChild("Head") or character:FindFirstChild("HumanoidRootPart"))
		if indicatorPart then
			TextIndicatorService:ShowIndicator(
				player,
				indicatorPart,
				"Picked up " .. gearName .. "!",
				Color3.fromRGB(255, 255, 255),
				true
			)
		end

		-- Fades out on EVERY screen, with the prompt and label killed on the
		-- instant so nobody is left looking at a claimed drop that still
		-- reads as takeable.
		self._collected = true
		self:_fadeAndDestroy()
	end)
end

return GearDrop
