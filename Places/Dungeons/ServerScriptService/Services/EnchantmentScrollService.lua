--!strict
--[[
	Module: Server/Services/EnchantmentScrollService.lua
	Description:
	ENCHANTMENT SCROLLS in the dungeon (2026-11-14): the roll, the drop in
	the world and the grant. Gear no longer drops enchanted; an enchantment
	arrives as a scroll (Shared/Data/EnchantmentScrollData owns the roll,
	the names, the colours and the chances). Applying a scroll to gear is
	not built yet (the enchanter NPC); this pass only drops, picks up and
	stores them.

	  RollChestScroll(player, origin, enemyType)
	      One chest's roll for one player, at the chest tier's chance
	      (EnchantmentScrollData.ChanceByEnemyType). Called by
	      EncounterChestService (Boss / Miniboss / Coffin chests, one chest
	      per player) and Components/Chest (the treasure chest, once per
	      living player, never from a mimic).
	  DropScroll(player, origin, enchantment?, tier?)
	      Spawns the drop for `player`; a nil enchantment or tier is
	      rolled. Also the `/scroll` test command's entry point.
	  Grant(player, enchantment, tier)
	      +1 in the profile's `EnchantmentScrolls` map. No toast
	      (2026-11-14): the bag's Scrolls tab shows what is owned.
	      Called by Components/EnchantmentScrollDrop on pickup.

	THE DROP is a plain NEON BLOCK in the scroll's colour with a billboard
	of its name, built here in code (no asset). It behaves like a gear
	drop: owned by one player (Attributes.OwnerId), spawned invisible and
	revealed only on its owner's client (privateDropVisibility), Atomic so
	the client component gets the part with the model, thrown from the
	chest to a floor spot (with the wall ricochet), picked up on a prompt
	and never timed out. It lives in workspace.IgnoreInstances
	.EnchantmentScrollDrops and is cleared on the floor teardown
	(DungeonService.Signals.OnFloorTeardown, reached through
	Blitz.OptionalService).

	GRANTED AT PICKUP, like gear (RunEscrowService.AddItem banks gear the
	moment it is picked up): a scroll taken is kept, win or lose. Scrolls
	are not gear, so the bag cap does not apply.
]]

--[ Roblox Services ]--

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

--[ Imports ]--

local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local Blitz = require(ReplicatedStorage.Submodules.Core.Shared.Blitz)
local DataService = require(ServerScriptService.Submodules.Core.Source.Services.DataService)
local EnchantmentScrollData = require(ReplicatedStorage.Submodules.Core.Shared.Data.EnchantmentScrollData)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local enchantmentTier = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Inventory.enchantmentTier)
local findFloorBelow = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Dungeon.findFloorBelow)
local privateDropVisibility = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Drop.privateDropVisibility)
local resolveArcLanding = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Drop.resolveArcLanding)

--[ Constants ]--

local DROP_FOLDER_NAME = "EnchantmentScrollDrops"

-- DEBUG, STUDIO ONLY (2026-11-14): in Studio every chest that can pay a
-- scroll pays one, so the drop, pickup and bag list are easy to test. A
-- live server always rolls the real chance (EnchantmentScrollData). Set
-- to nil to roll the real chance in Studio too.
local STUDIO_DEBUG_CHANCE: number? = 1

-- The block.
local BLOCK_SIZE = Vector3.new(1.5, 1.5, 1.5)
local BLOCK_NAME = "Block"

-- The label over it.
local BILLBOARD_NAME = "ScrollName"
local BILLBOARD_SIZE = UDim2.fromScale(8, 1)
local BILLBOARD_OFFSET = Vector3.new(0, 2, 0)
local BILLBOARD_MAX_DISTANCE = 60

-- The landing spot: a scatter around the origin, over floor, the same
-- shape as a gear drop's (GearDropService).
local LANDING_XZ_SCATTER = 5
local LANDING_ATTEMPTS = 6
local LANDING_Y_ABOVE_GROUND = 2
local LANDING_RAYCAST_UP = 10
local LANDING_RAYCAST_DEPTH = 100

-- Read by both EnchantmentScrollDrop components.
local ATTR_ENCHANTMENT = "ScrollEnchantment"
local ATTR_TIER = "ScrollTier"
local ATTR_ORIGIN_POSITION = "OriginPosition"

--[ Service ]--

local EnchantmentScrollService = {
	Name = "EnchantmentScrollService",
	Dependencies = { DataService } :: { any },
}

--[ Private ]--

function EnchantmentScrollService._ensureDropFolder(_self: typeof(EnchantmentScrollService)): Instance
	local parent: Instance = workspace:FindFirstChild("IgnoreInstances") or workspace
	local folder = parent:FindFirstChild(DROP_FOLDER_NAME)
	if not folder then
		local created = Instance.new("Folder")
		created.Name = DROP_FOLDER_NAME
		created.Parent = parent
		folder = created
	end
	return folder :: Instance
end

-- A floor spot scattered around `origin`; straight under it when no
-- scatter finds floor; the origin's own height as the last resort.
function EnchantmentScrollService._pickLandingPosition(
	_self: typeof(EnchantmentScrollService),
	origin: Vector3
): Vector3
	local fromY = origin.Y + LANDING_RAYCAST_UP
	for _ = 1, LANDING_ATTEMPTS do
		local x = origin.X + math.random(-LANDING_XZ_SCATTER, LANDING_XZ_SCATTER)
		local z = origin.Z + math.random(-LANDING_XZ_SCATTER, LANDING_XZ_SCATTER)
		local floor = findFloorBelow(x, z, fromY, LANDING_RAYCAST_DEPTH)
		if floor then
			return Vector3.new(x, floor.Y + LANDING_Y_ABOVE_GROUND, z)
		end
	end
	local underOrigin = findFloorBelow(origin.X, origin.Z, fromY, LANDING_RAYCAST_DEPTH)
	if underOrigin then
		return Vector3.new(origin.X, underOrigin.Y + LANDING_Y_ABOVE_GROUND, origin.Z)
	end
	return Vector3.new(origin.X, origin.Y + LANDING_Y_ABOVE_GROUND, origin.Z)
end

-- The neon block and its name label, as one Model at `landing`.
function EnchantmentScrollService._buildDropModel(
	_self: typeof(EnchantmentScrollService),
	enchantment: string,
	tier: number,
	landing: Vector3
): Model
	local color = EnchantmentScrollData.Color(enchantment)

	local block = Instance.new("Part")
	block.Name = BLOCK_NAME
	block.Shape = Enum.PartType.Block
	block.Size = BLOCK_SIZE
	block.Material = Enum.Material.Neon
	block.Color = color
	block.Anchored = true
	block.CanCollide = false
	block.CanQuery = false
	block.CanTouch = false
	block.CastShadow = false
	block.CFrame = CFrame.new(landing)

	local billboard = Instance.new("BillboardGui")
	billboard.Name = BILLBOARD_NAME
	billboard.Size = BILLBOARD_SIZE
	billboard.StudsOffsetWorldSpace = BILLBOARD_OFFSET
	billboard.MaxDistance = BILLBOARD_MAX_DISTANCE
	billboard.AlwaysOnTop = true
	billboard.ResetOnSpawn = false
	billboard.Adornee = block

	local label = Instance.new("TextLabel")
	label.Name = "NameText"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBold
	label.Text = EnchantmentScrollData.DisplayName(enchantment, tier)
	label.TextColor3 = color
	label.TextScaled = true
	label.TextStrokeColor3 = Color3.fromRGB(25, 25, 25)
	label.TextStrokeTransparency = 0
	label.Parent = billboard
	billboard.Parent = block

	local model = Instance.new("Model")
	model.Name = "EnchantmentScrollDrop"
	block.Parent = model
	model.PrimaryPart = block
	return model
end

--[ Public ]--

-- Spawns one scroll drop for `player`, thrown from `origin`. A nil
-- enchantment or tier is rolled (EnchantmentScrollData.Roll for both, the
-- tier odds alone for a named enchantment). Returns the model, or nil
-- for an enchantment no scroll carries.
function EnchantmentScrollService.DropScroll(
	self: typeof(EnchantmentScrollService),
	player: Player,
	origin: Vector3,
	enchantment: string?,
	tier: number?
): Model?
	local rolledEnchantment, rolledTier = EnchantmentScrollData.Roll()
	local scrollEnchantment = enchantment or rolledEnchantment
	local scrollTier = if enchantment
		then (if tier then enchantmentTier.Clamp(tier) else enchantmentTier.Roll())
		else enchantmentTier.Clamp(tier or rolledTier)
	if not EnchantmentScrollData.IsScrollEnchantment(scrollEnchantment) then
		warn(("[EnchantmentScrollService] '%s' is not a scroll enchantment"):format(tostring(scrollEnchantment)))
		return nil
	end

	-- The wall ricochet every arc shares: a scatter that crossed a wall
	-- reflects back into the room.
	local landing, bounce =
		resolveArcLanding(origin, self:_pickLandingPosition(origin), { floorOffset = LANDING_Y_ABOVE_GROUND })

	local model = self:_buildDropModel(scrollEnchantment, scrollTier, landing)
	model:SetAttribute(ATTR_ENCHANTMENT, scrollEnchantment)
	model:SetAttribute(ATTR_TIER, scrollTier)
	model:SetAttribute(Attributes.OwnerId, player.UserId)
	model:SetAttribute(ATTR_ORIGIN_POSITION, origin)
	if bounce then
		model:SetAttribute(Attributes.BouncePosition, bounce)
	end
	-- Owner-locked: spawned invisible, and only the owner's client
	-- component reveals it. Nobody else ever sees it.
	privateDropVisibility.hide(model)

	-- Tagged and stamped Atomic BEFORE parenting: the client component
	-- reads the block and its billboard the moment the model streams in.
	CollectionService:AddTag(model, TagList.EnchantmentScrollDrop)
	model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
	model.Parent = self:_ensureDropFolder()
	return model
end

-- One chest's roll for one player: a scroll at the chest tier's chance
-- (EnchantmentScrollData.ChanceByEnemyType; no row, no scroll).
function EnchantmentScrollService.RollChestScroll(
	self: typeof(EnchantmentScrollService),
	player: Player,
	origin: Vector3,
	enemyType: string?
): Model?
	local chance = EnchantmentScrollData.Chance(enemyType)
	if chance > 0 and STUDIO_DEBUG_CHANCE and RunService:IsStudio() then
		chance = STUDIO_DEBUG_CHANCE
	end
	if chance <= 0 or math.random() >= chance then
		return nil
	end
	return self:DropScroll(player, origin)
end

-- Adds one scroll to the player's profile. Returns false
-- (nothing written) when the profile is not loaded or the scroll is not
-- a real one.
function EnchantmentScrollService.Grant(
	_self: typeof(EnchantmentScrollService),
	player: Player,
	enchantment: string,
	tier: number
): boolean
	if not EnchantmentScrollData.IsScrollEnchantment(enchantment) then
		return false
	end
	-- An empty table until the profile has loaded.
	local profile = DataService:GetProfileData(player)
	if next(profile) == nil then
		warn(("[EnchantmentScrollService] Pickup refused -- no profile for %s"):format(player.Name))
		return false
	end

	local scrolls = profile[EnchantmentScrollData.ProfileKey]
	if typeof(scrolls) ~= "table" then
		scrolls = {}
	end
	local key = EnchantmentScrollData.Key(enchantment, tier)
	scrolls[key] = math.max(0, math.floor(tonumber(scrolls[key]) or 0)) + 1
	DataService:SetProfileValue(player, EnchantmentScrollData.ProfileKey, scrolls)
	return true
end

-- Destroys every scroll still on the floor.
function EnchantmentScrollService.ClearDrops(_self: typeof(EnchantmentScrollService))
	for _, drop in CollectionService:GetTagged(TagList.EnchantmentScrollDrop) do
		drop:Destroy()
	end
end

--[ Lifecycle ]--

function EnchantmentScrollService.Start(self: typeof(EnchantmentScrollService))
	-- The floor's scrolls go with the floor. DungeonService is never
	-- required from a consumer (Docs/Architecture.md).
	local dungeonService = Blitz.OptionalService("DungeonService")
	if dungeonService then
		dungeonService.Signals.OnFloorTeardown:Connect(function()
			self:ClearDrops()
		end)
	end
end

return EnchantmentScrollService
