--!strict
--[[
	Module: EncounterChestService.lua
	Description:
	The Miniboss / Boss reward chest. Replaces the vending machine that used
	to fall after an encounter: one chest per player, dropped out of the sky
	onto the floor in front of them, facing the middle of their chunk.

	WHY A CHEST AND NOT A MACHINE:
	the machine's job was a relic pull. Encounter kills no longer award
	relics (design call) — they award the GEAR and COINS the mob itself used
	to scatter around its corpse mid-cinematic. A chest is the honest shape
	for that: one reward object, opened when the player is ready, instead of
	loot raining onto a body during an outro nobody is looking away from.

	WHERE THE LOOT COMES FROM — both are existing systems, unchanged:
	  * GEAR  GearDropService:DropGear, which reads the active dungeon's
	          DungeonData.dungeonDrops (its `pool` plus the `perEnemyType`
	          row for Miniboss / Boss). Rolled PER PLAYER, exactly as the
	          corpse drop did.
	  * COINS + FORGE ORE  the tier's chestCoins / chestOre totals
	          (DifficultyData, per EnemyType), split into the encounter
	          mob's MobData `chestPickups` counts. These are the run's ONLY
	          source of permanent currency (design call, 2026-10); grunts
	          drop Gems, the run currency, and the Event Chest pays Gems.
	  * GEMS  an encounter mob with a MobData `gems` row pays that purse
	          from its chest too, on top of the Coins + Ore (the Miniboss:
	          ~50 a floor before the tier's GemScale; the Boss has no row).

	PER PLAYER, OWNER-LOCKED: a chest carries its owner's UserId and only
	that player can open it, so nobody can take a teammate's reward. This
	matches how every other reward in the game already behaves (owner-locked
	relic drops, per-player event outcomes).
]]

--[ Roblox Services ]--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local ServerScriptService = game:GetService("ServerScriptService")

--[ Imports ]--

local DungeonService = require(ServerScriptService.Services.DungeonService)
local DropService = require(ServerScriptService.Services.DropService)
local GearDropService = require(ServerScriptService.Services.GearDropService)
local RelicMachineService = require(ServerScriptService.Services.RelicMachineService)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local DropTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.DropTypes)
local EnemyTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.EnemyTypes)
local DifficultyData = require(ReplicatedStorage.Submodules.Core.Shared.Data.DifficultyData)
local MobData = require(ReplicatedStorage.Submodules.Core.Shared.Data.MobData)

--[ Constants ]--

-- GameAssets.Chest.<name>, one per encounter tier.
local CHEST_MODELS = {
	[EnemyTypes.Miniboss] = "MinibossChest",
	[EnemyTypes.Boss] = "BossChest",
	-- The CoffinEvent's reward (CoffinEventService).
	[EnemyTypes.Event] = "EventChest",
}

-- The player-facing name, on both the prompt and the billboard. Stamped
-- onto the chest as an attribute so the client can rebuild the label
-- when it flips to (Inactive) without a second copy of this table.
local CHEST_DISPLAY_NAMES = {
	[EnemyTypes.Miniboss] = "Miniboss Chest",
	[EnemyTypes.Boss] = "Boss Chest",
	[EnemyTypes.Event] = "Event Chest",
}
local CHEST_NAME_ATTRIBUTE = "ChestName"

-- The authored billboard, same names and same two labels the vending
-- machines use (the prefabs were built from the machine's rig).
local BILLBOARD_NAME = "VendingMachineName"
local OWNER_LABEL_NAME = "NameText"
local STATUS_LABEL_NAME = "VendingMachineText"
local ACTIVE_COLOR = Color3.fromRGB(85, 255, 127)

-- Presentation lives CLIENT-SIDE in Components/EncounterChest.lua — a
-- fork of the vending machine's own component, so the fall, squash,
-- smoke, thud and shake are beat-identical to a machine drop. This
-- service grafts the machine template's FX instances onto each chest so
-- that component has the exact same assets to play with:
--   Attachment.ProximityPrompt  (carries the Style attribute the custom
--                                prompt renderer requires)
--   LandParticle                (the landing smoke)
--   Landing                     (the landing thud)
local MACHINE_TEMPLATE_PATH = { "VendingMachines", "Default" }
local MACHINE_FX_NAMES = { "LandParticle", "Landing" }

-- Authored INTO the chest prefabs (Treasure.Idle): the hum a live chest
-- gives off. Played server-side like the vending machine's own Idle so
-- its playing state replicates, and positional because it sits in the
-- PrimaryPart — teammates hear it too, falling off with distance.
local IDLE_SOUND_NAME = "Idle"

-- Opening presentation (the lid swing) is CLIENT-side in
-- Components/EncounterChest — the server-stepped CFrameValue it used to
-- be arrived at replication rate and read as lag, the same lesson the
-- fall taught. The server only flips OPENED_ATTRIBUTE and pays out; the
-- opened chest deliberately STAYS in the world (per design — no fade,
-- no despawn).
local OPENED_ATTRIBUTE = "Opened"

local OWNER_ATTRIBUTE = "OwnerId"

-- One BATCH is the set of chests dropped for a single encounter — one
-- per living player. The exit gate now waits on the whole batch, so a
-- chest nobody ever opens would softlock the run: the batch therefore
-- resolves itself after this long no matter what. It also resolves a
-- chest early when its owner leaves or the chest is destroyed, so the
-- timeout is a backstop rather than the normal path.
local BATCH_TIMEOUT_SECONDS = 90

-- One chest batch (see BATCH_TIMEOUT_SECONDS). `gems` is an optional
-- MobData `gems`-shaped row the Event Chest pays (the run currency);
-- encounter chests pay the tier's Coins + Ore (DifficultyData) plus the
-- encounter mob's own `gems` row when it has one (the Miniboss purse).
type ChestBatch = {
	pending: number,
	done: boolean,
	onAllOpened: (() -> ())?,
	gems: { [string]: number }?,
	-- [userId] = true for every player who got a chest / who opened it.
	owners: { [number]: boolean },
	opened: { [number]: boolean },
}

--[ Service ]--

local EncounterChestService = {
	Name = "EncounterChestService",
	Dependencies = { DungeonService, DropService, GearDropService, RelicMachineService } :: { any },
	_batchByChest = {} :: { [Model]: ChestBatch },
	_activeBatch = nil :: ChestBatch?,
}

--[ Private ]--

-- Fires a batch's completion callback exactly once.
local function completeBatch(batch: ChestBatch)
	if batch.done then
		return
	end
	batch.done = true
	if batch.onAllOpened then
		-- Spawned: a listener that errors must not take out the caller
		-- (which may be the prompt handler mid-payout).
		task.spawn(batch.onAllOpened)
	end
end

-- The chest's own coin scatter, read off the DEAD MOB's MobData row so a
-- tier's boss pays what its row says. Same four fields the corpse drop used.
-- The vending machine template's PrimaryPart, source of the grafted FX.
local function machineTemplatePrimary(): BasePart?
	local node: Instance? = ReplicatedStorage.GameAssets
	for _, childName in MACHINE_TEMPLATE_PATH do
		node = node and node:FindFirstChild(childName)
	end
	return if node and node:IsA("Model") then node.PrimaryPart else nil
end

-- Grafts the machine's landing FX + prompt onto a chest's PrimaryPart.
-- The prompt comes over inside the machine's own Attachment (stripped of
-- the machine's glow/shine), so its Style attribute and offsets are
-- byte-identical to a real machine's — which is what makes the custom
-- prompt UI render it.
local function graftMachineFX(chestPrimary: BasePart): ProximityPrompt?
	local source = machineTemplatePrimary()
	if not source then
		warn("[EncounterChestService] Missing GameAssets.VendingMachines.Default " .. "— no FX to graft")
		return nil
	end

	for _, fxName in MACHINE_FX_NAMES do
		if not chestPrimary:FindFirstChild(fxName) then
			local fx = source:FindFirstChild(fxName)
			if fx then
				fx:Clone().Parent = chestPrimary
			end
		end
	end

	local sourceAttachment = source:FindFirstChild("Attachment")
	local existingAttachment = chestPrimary:FindFirstChild("Attachment")
	local attachment: Instance
	if existingAttachment then
		attachment = existingAttachment
	else
		if not sourceAttachment then
			return nil
		end
		attachment = sourceAttachment:Clone()
		-- The machine's glow rig rides its Attachment; the chest brings
		-- its own glow, so take only the prompt.
		for _, child in attachment:GetChildren() do
			if not child:IsA("ProximityPrompt") then
				child:Destroy()
			end
		end
		attachment.Parent = chestPrimary
	end

	-- The prefabs author their own Attachment (glow rig + billboard
	-- anchor) but no prompt — graft the machine's own prompt into it
	-- rather than building one, because the custom prompt renderer keys
	-- off the Style attribute the template carries.
	local prompt = attachment:FindFirstChildWhichIsA("ProximityPrompt")
	if not prompt and sourceAttachment then
		local sourcePrompt = sourceAttachment:FindFirstChildWhichIsA("ProximityPrompt")
		if sourcePrompt then
			local clonedPrompt = sourcePrompt:Clone()
			clonedPrompt.Parent = attachment
			prompt = clonedPrompt
		end
	end
	return prompt
end

-- Stamps the owner and the green "(Active)" status onto the chest's
-- billboard — the same two labels, and the same green, the vending
-- machines use. The client flips it to a red "(Inactive)" on open.
local function applyBillboard(chest: Model, player: Player, displayName: string)
	local primary = chest.PrimaryPart
	local billboard = primary and primary:FindFirstChild(BILLBOARD_NAME)
	local frame = billboard and billboard:FindFirstChild("Frame")
	if not frame then
		warn(
			("[EncounterChestService] '%s' has no PrimaryPart.%s.Frame "):format(chest.Name, BILLBOARD_NAME)
				.. "-- chest drops without an owner billboard"
		)
		return
	end

	local ownerLabel = frame:FindFirstChild(OWNER_LABEL_NAME)
	if ownerLabel and ownerLabel:IsA("TextLabel") then
		ownerLabel.Text = player.Name .. "'s"
	end

	local statusLabel = frame:FindFirstChild(STATUS_LABEL_NAME)
	if statusLabel and statusLabel:IsA("TextLabel") then
		statusLabel.Text = displayName .. " (Active)"
		statusLabel.TextColor3 = ACTIVE_COLOR
	end
end

-- Places one chest STATICALLY at its final rest pose: the machine's own
-- landing pick (forward of the player, clamped to their floor slab,
-- facing the chunk middle), but seated by the model's BOUNDING-BOX
-- BOTTOM rather than extents/2 around the pivot — the chests' pivot is
-- not their centre, which is what floated the first pass.
--
-- DELIBERATELY NO SERVER ANIMATION. The fall is a client-side visual
-- (Components/EncounterChest). When the server animated too, both
-- authorities wrote part CFrames and whichever replicated update landed
-- last PER PART won — the lid took one authority's final pose, the body
-- the other's, and the chest arrived with a visible seam. A static
-- server pose gives replication exactly one truth to converge on.
local function placeChestAtRest(player: Player, chest: Model): boolean
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp or not chest.PrimaryPart then
		return false
	end

	local extents = chest:GetExtentsSize()
	local footprintRadius = math.max(extents.X, extents.Z) / 2
	local frontXZ, groundY, _floorPart = RelicMachineService:PickMachineLanding(hrp, footprintRadius)

	-- Seat the BOTTOM on the ground: pivot height above the model's
	-- lowest point, preserved.
	local pivot = chest:GetPivot()
	local bboxCFrame, bboxSize = chest:GetBoundingBox()
	local bottomOffset = pivot.Position.Y - (bboxCFrame.Position.Y - bboxSize.Y / 2)
	local landingPosition = Vector3.new(frontXZ.X, groundY + bottomOffset + 0.05, frontXZ.Z)

	-- Face the PLAYER, flattened. This deliberately breaks from the
	-- machine's convention of facing the chunk middle (per design): the
	-- chest is yours and lands in front of you, so it looks at you. No
	-- 180-degree model-front flip either — the chests are authored
	-- front-forward. If the player is somehow standing exactly on the
	-- landing spot, keep the gate-facing pose rather than a zero look.
	local flatTarget = Vector3.new(hrp.Position.X, landingPosition.Y, hrp.Position.Z)
	if (flatTarget - landingPosition).Magnitude < 0.01 then
		flatTarget = landingPosition + Vector3.new(hrp.CFrame.LookVector.X, 0, hrp.CFrame.LookVector.Z)
	end
	chest:PivotTo(CFrame.lookAt(landingPosition, flatTarget))
	-- Atomic: the client component needs the grafted prompt, billboard and
	-- landing FX the moment the tagged Model streams in (see DropService).
	chest.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
	chest.Parent = workspace.IgnoreInstances.Map.RelicMachines
	return true
end

-- How many pickups a chest splits its payout into (MobData `chestPickups`
-- on the encounter mob), { min, max } per currency. A sane default for a
-- chest with no row behind it.
local DEFAULT_PICKUPS = { coins = { 5, 7 }, ore = { 3, 4 } }
local function pickupCountsFor(mobName: string?): { coins: { number }, ore: { number } }
	local data = mobName and MobData[mobName]
	return (data and data.chestPickups) or DEFAULT_PICKUPS
end

-- Fires a MobData `gems`-shaped row (pickup count range x value range)
-- from `origin`, private to `player`, chest-style (a blip per pickup).
local function dropGems(origin: BasePart, gems: { [string]: number }, player: Player)
	if not DropService then
		return
	end
	DropService.OnDropRequested:Fire(
		origin,
		DropTypes.Gems,
		gems.minDropRate,
		gems.maxDropRate,
		gems.minGems,
		gems.maxGems,
		false,
		player.UserId,
		true
	)
end

-- Fires `total` of `dropType` as `count` pickups from `origin`, private to
-- `player`, chest-style (a blip per pickup). Rounds the per-pickup value
-- up so the chest never pays less than its row.
local function dropSplit(origin: BasePart, dropType: string, total: number, countRange: { number }, player: Player)
	if not DropService or total <= 0 then
		return
	end
	local count = math.random(countRange[1], countRange[2])
	local value = math.max(1, math.ceil(total / count))
	DropService.OnDropRequested:Fire(origin, dropType, count, count, value, value, false, player.UserId, true)
end

-- Resolves ONE chest against its batch: opened, destroyed, or its owner
-- left the game. When the last one resolves, the batch completes — which
-- is what opens the encounter's exit gate.
function EncounterChestService._resolveChest(self: typeof(EncounterChestService), chest: Model)
	local batch = self._batchByChest[chest]
	if not batch then
		return
	end
	self._batchByChest[chest] = nil

	batch.pending -= 1
	if batch.pending <= 0 then
		completeBatch(batch)
	end
end

-- Pays out ONE chest to its owner, then retires it.
function EncounterChestService._openChest(self: typeof(EncounterChestService), chest: Model, player: Player)
	-- One payout only — the chest persists after opening, so the attribute
	-- doubles as the "already opened" latch (and guards a double Trigger
	-- racing the Enabled flip below).
	if chest:GetAttribute(OPENED_ATTRIBUTE) then
		return
	end

	local prompt = chest:FindFirstChildWhichIsA("ProximityPrompt", true)
	if prompt then
		prompt.Enabled = false
	end

	-- Every client's component plays the lid swing off this edge.
	chest:SetAttribute(OPENED_ATTRIBUTE, true)

	-- Spent: the idle hum stops with the open.
	local idle = chest.PrimaryPart and chest.PrimaryPart:FindFirstChild(IDLE_SOUND_NAME)
	if idle and idle:IsA("Sound") then
		idle:Stop()
	end

	-- Read BEFORE resolving: resolving drops the chest from the batch map,
	-- and the batch may carry a Gems row of its own (the Event Chest).
	local batch = self._batchByChest[chest]
	if batch and batch.opened then
		batch.opened[player.UserId] = true
	end

	-- The encounter's gate countdown ends early once every player has
	-- opened theirs (EncounterService reads HasPlayerOpenedChest).
	self:_resolveChest(chest)

	local origin = chest.PrimaryPart
	if not origin then
		return
	end

	local enemyType = chest:GetAttribute(Attributes.EnemyType) :: string?
	local mobName = chest:GetAttribute("MobName") :: string?

	-- GEAR: the dungeon's own dungeonDrops table, rolled for this player
	-- against the encounter tier's perEnemyType row.
	if GearDropService and enemyType then
		-- `true`: chest gear pops out with the same blip its coins use.
		GearDropService:DropGear(player, origin.Position, enemyType, true)
	end

	-- CURRENCY (design call, 2026-10). An ENCOUNTER chest pays its share
	-- of the tier's permanent take -- Coins and Forge Ore, run totals from
	-- DifficultyData `chestCoins` / `chestOre` split by floor and by
	-- miniboss / boss (ChestPayout), then into MobData `chestPickups`
	-- pickups -- plus the encounter mob's own Gem purse when its MobData
	-- row has `gems` (the Miniboss, ~50 a floor; DropService applies the
	-- tier's GemScale at collect time). The EVENT chest
	-- (Laughing Coffin) pays Gems from the batch's own row instead.
	-- Everything is PRIVATE to the chest's owner: chests are per player,
	-- so shared pickups meant everybody banked everybody else's chest.
	-- DropService applies the dungeon's rewardScale to the Coins and Ore
	-- at collect time.
	if enemyType == EnemyTypes.Event then
		local gems = batch and batch.gems
		if gems then
			dropGems(origin, gems, player)
		end
	elseif enemyType then
		-- The tier's run total, split across floors (back-loaded) and
		-- between the floor's miniboss and boss (DifficultyData.ChestPayout).
		local tier = DungeonService:GetDifficultyScale()
		local floor = DungeonService:GetFloor()
		local pickups = pickupCountsFor(mobName)
		local coins = DifficultyData.ChestPayout(tier, floor, enemyType, "chestCoins")
		if coins then
			dropSplit(origin, DropTypes.Coins, coins, pickups.coins, player)
		end
		local ore = DifficultyData.ChestPayout(tier, floor, enemyType, "chestOre")
		if ore then
			dropSplit(origin, DropTypes.ForgeOre, ore, pickups.ore, player)
		end
		local mobData = mobName and MobData[mobName]
		local purse = mobData and mobData.gems
		if purse then
			dropGems(origin, purse, player)
		end
	end

	-- The opened chest stays in the world as scenery, collidable — the
	-- room cleanup that clears the machines clears it too.
end

--[ Public ]--

-- Drops one chest per living player for a finished encounter. `mob` is the
-- corpse: its NAME is the MobData key the coin scatter reads, so the
-- chest pays what that specific mob's row says.
-- `mob` may also be a plain MobData KEY (a string) — the /drop debug
-- command has no corpse to hand over, only a name for the coin row.
-- `coinsOverride` (optional): a coin row shaped like a MobData mob's
-- ({ minDropRate, maxDropRate, minCoins, maxCoins }) that every chest in
-- this batch pays instead of `mob`'s row — the Event Chest, which has no
-- mob behind it.
function EncounterChestService.DropChestsForEncounter(
	self: typeof(EncounterChestService),
	enemyType: string,
	mob: (Model | string)?,
	onAllOpened: (() -> ())?,
	gemsOverride: { [string]: number }?
)
	-- The batch exists BEFORE the first bail-out: every early return has
	-- to complete it, or a missing prefab would leave the gate shut and
	-- the run unfinishable.
	local batch: ChestBatch = {
		pending = 0,
		done = false,
		onAllOpened = onAllOpened,
		gems = gemsOverride,
		-- [userId] = true for every player who got a chest / who opened it.
		-- The encounter gate's countdown reads these (HasPlayerOpenedChest).
		owners = {},
		opened = {},
	}
	self._activeBatch = batch

	local modelName = CHEST_MODELS[enemyType]
	if not modelName then
		warn("[EncounterChestService] No chest model for enemy type " .. tostring(enemyType))
		completeBatch(batch)
		return
	end

	local chestFolder = ReplicatedStorage.GameAssets:FindFirstChild("Chest")
	local template = chestFolder and chestFolder:FindFirstChild(modelName)
	if not template then
		warn("[EncounterChestService] Missing GameAssets.Chest." .. modelName)
		completeBatch(batch)
		return
	end

	-- Backstop against a chest that is never opened (an AFK player).
	task.delay(BATCH_TIMEOUT_SECONDS, function()
		completeBatch(batch)
	end)

	local mobName = if typeof(mob) == "string" then mob else mob and mob.Name

	for _, player in Players:GetPlayers() do
		-- Dead / spectating players get nothing: the chest would land on a
		-- ragdoll they cannot walk back to. Same guard the machine used.
		local character = player.Character
		if not character or character:GetAttribute(Attributes.Death) == true then
			continue
		end

		local chest = template:Clone()
		-- NEVER a Treasure-room chest. A prefab tagged `Chest` in Studio mounts
		-- Server/Components/Chest on the clone: a SECOND prompt at the model
		-- root that flips `Opened` itself and pays treasure-room coins —
		-- bypassing _openChest, so the batch never resolves and the door it
		-- guards never opens. Strip the tag before the clone ever parents.
		CollectionService:RemoveTag(chest, TagList.Chest)

		-- SELF-HEAL a missing PrimaryPart: both chest prefabs shipped from
		-- Studio without one set, and the drop path needs it (extents,
		-- pivot, the prompt's parent). Adopt the largest BasePart — for a
		-- chest that is the body mesh — instead of silently dropping
		-- nothing, which is exactly what happened on the first playtest.
		if not chest.PrimaryPart then
			local largest, largestVolume = nil, 0
			for _, part in chest:GetDescendants() do
				if part:IsA("BasePart") then
					local size = part.Size
					local volume = size.X * size.Y * size.Z
					if volume > largestVolume then
						largest, largestVolume = part, volume
					end
				end
			end
			chest.PrimaryPart = largest
			warn(
				(
					"[EncounterChestService] GameAssets.Chest.%s has no PrimaryPart "
					.. "— adopted '%s'. Set it on the prefab for a stable pivot."
				):format(modelName, tostring(largest and largest.Name))
			)
		end

		local displayName = CHEST_DISPLAY_NAMES[enemyType] or "Chest"
		chest:SetAttribute(OWNER_ATTRIBUTE, player.UserId)
		chest:SetAttribute(Attributes.EnemyType, enemyType)
		chest:SetAttribute(CHEST_NAME_ATTRIBUTE, displayName)
		if mobName then
			chest:SetAttribute("MobName", mobName)
		end

		-- The client component tweens every part's Position — physics must
		-- never fight it.
		for _, part in chest:GetDescendants() do
			if part:IsA("BasePart") then
				part.Anchored = true
			end
		end

		-- The machine template's OWN prompt (with the Style attribute the
		-- custom renderer needs), landing smoke and thud, grafted on. The
		-- client EncounterChest component — a fork of the machine's —
		-- plays them, so the drop is beat-identical to a machine's.
		local prompt = graftMachineFX(chest.PrimaryPart)
		if not prompt then
			warn("[EncounterChestService] No prompt could be grafted onto " .. modelName)
			chest:Destroy()
			continue
		end

		-- Counted only once it is certain to exist; the placement check
		-- below un-counts it again if the chest never lands.
		batch.pending += 1
		batch.owners[player.UserId] = true
		self._batchByChest[chest] = batch
		-- Room cleanup (or any other despawn) must not strand the batch.
		chest.Destroying:Connect(function()
			self:_resolveChest(chest)
		end)
		prompt.ActionText = "Open"
		prompt.ObjectText = displayName
		prompt.HoldDuration = 0
		applyBillboard(chest, player, displayName)
		-- Disabled until landed; the OWNER's client enables it after the
		-- settle, exactly on the machine's timing.
		prompt.Enabled = false

		chest:AddTag(TagList.EncounterChest)

		local opened = false
		prompt.Triggered:Connect(function(triggeringPlayer: Player)
			-- Owner-locked: a teammate's chest is not yours to open.
			if opened or triggeringPlayer ~= player then
				return
			end
			opened = true
			self:_openChest(chest, player)
		end)

		local placed = placeChestAtRest(player, chest)
		if not placed then
			warn(
				("[EncounterChestService] Could not place %s for %s (no HRP or no PrimaryPart)"):format(
					modelName,
					player.Name
				)
			)
			chest:Destroy()
		else
			-- Live: the idle hum runs until the chest is opened. Looping is
			-- the asset's own setting — a one-shot Idle plays once.
			local idle = chest.PrimaryPart and chest.PrimaryPart:FindFirstChild(IDLE_SOUND_NAME)
			if idle and idle:IsA("Sound") then
				idle:Play()
			end
		end

		task.wait(0.25)
	end

	-- Nobody alive to drop for (or every placement failed): the gate must
	-- still open.
	if batch.pending <= 0 then
		completeBatch(batch)
	end
end

-- True when `player` has opened their chest from the CURRENT batch, or
-- never had one in it (dead at the drop, joined later): nothing to wait
-- for. True with no batch at all, for the same reason.
function EncounterChestService.HasPlayerOpenedChest(self: typeof(EncounterChestService), player: Player): boolean
	local batch = self._activeBatch
	if not batch or batch.done then
		return true
	end
	if not batch.owners[player.UserId] then
		return true
	end
	return batch.opened[player.UserId] == true
end

-- The floor is being replaced. Batches are per encounter and their chests
-- die with the floor's rooms, but the two lookups only ever emptied at
-- boot: the previous floor's batch stayed the ACTIVE one, so
-- HasPlayerOpenedChest on the new floor answered from
-- stale state until its first encounter, and a still-pending batch's
-- BATCH_TIMEOUT could fire its callback into a floor that no longer
-- existed. Every live batch is retired (done, so neither the timeout
-- nor a chest's teardown-destroy can complete it) and both lookups are
-- cleared. Mirrors CoffinEventService.ResetForFloor.
function EncounterChestService.ResetForFloor(self: typeof(EncounterChestService))
	for _, batch in self._batchByChest do
		batch.done = true
	end
	if self._activeBatch then
		self._activeBatch.done = true
	end
	table.clear(self._batchByChest)
	self._activeBatch = nil
end

--[ Lifecycle ]--

function EncounterChestService.Init(self: typeof(EncounterChestService))
	self._batchByChest = {}
	self._activeBatch = nil
end

function EncounterChestService.Start(self: typeof(EncounterChestService))
	-- A player who leaves can never open theirs — release it so the rest
	-- of the party is not held at the gate waiting on a ghost.
	Players.PlayerRemoving:Connect(function(player: Player)
		for chest in self._batchByChest do
			if chest:GetAttribute(OWNER_ATTRIBUTE) == player.UserId then
				self:_resolveChest(chest)
			end
		end
	end)

	-- Floor reset (see ResetForFloor). OnFloorTeardown fires at the START
	-- of the teardown, before it destroys the old chests, so their batch is
	-- already retired when those Destroying signals fire.
	DungeonService.Signals.OnFloorTeardown:Connect(function()
		self:ResetForFloor()
	end)
end

return EncounterChestService
