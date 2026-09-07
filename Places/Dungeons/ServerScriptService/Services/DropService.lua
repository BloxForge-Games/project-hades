local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local Signal = require(ReplicatedStorage.Submodules.Core.Packages.Signal)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local DropTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.DropTypes)
local DropData = require(ReplicatedStorage.Submodules.Core.Shared.Data.DropData)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local RelicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicData)

local InventoryType = require(ReplicatedStorage.Submodules.Core.Shared.Enums.InventoryType)
local EnchantmentNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.EnchantmentNames)
local EnchantmentData = require(ReplicatedStorage.Submodules.Core.Shared.Data.EnchantmentData)
local ItemRarity = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ItemRarity)
local RarityColors = require(ReplicatedStorage.Submodules.Core.Shared.Data.RarityColors)
local RuneRarityColors = require(ReplicatedStorage.Submodules.Core.Shared.Data.RuneRarityColors)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local resolveArcLanding = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Drop.resolveArcLanding)

-- Coin landing scatter (studs, each axis) around the dead mob. Picked
-- HERE rather than per client — it used to be, so every player watched
-- the same coin settle somewhere different — and run through the wall
-- ricochet like every other arc.
local COIN_SCATTER_STUDS = 8
local COIN_SCATTER_BOSS_STUDS = 20

local IS_BOSS_COIN_DROP_DELAY = 0.05

-- Relics granting a flat COIN bonus. Their callbacks return the bonus
-- FRACTION and are summed additively at the credit site, so two +% relics
-- add rather than compound. Dragon Lantern is deliberately NOT here: its
-- callback returns a full multiplier and it keeps multiplying on top.
local COIN_BONUS_RELICS = {
	RelicNames["Pot Of Gold"],
}

local MagicService
local PlayerStatsService
local RunEscrowService
local RelicService
local ArmorSetBonusService
local DataService

-- Looter enchantment: ×1.10 coin credit when the COLLECTOR has a
-- Looter-enchanted weapon EQUIPPED (either slot). Reads the persisted
-- profile so it can't drift from the inventory UI's source of truth.
local function getLooterCoinMultiplier(player: Player): number
	local looterConfig = EnchantmentData[EnchantmentNames.Looter]
	if not looterConfig or not looterConfig.coinMultiplier or not DataService then
		return 1
	end
	local profile = DataService:GetProfileData(player)
	local weapons = profile and profile.Inventory and profile.Inventory[InventoryType.Weapon]
	if not weapons then
		return 1
	end
	for _, entry in weapons do
		if entry.equipSlot and entry.equipSlot > 0 and entry.enchantment == EnchantmentNames.Looter then
			return looterConfig.coinMultiplier
		end
	end
	return 1
end

-- Orb pickup flourish: the GameAssets.Auras.Orb emitters cloned onto the
-- collector's HumanoidRootPart and burst once, tinted to the orb's kind.
-- ONE authored asset serving both orbs — it is built uncoloured and tinted
-- here, the same way StatusFX is tinted per status, so a retune in Studio
-- lands on health and mana together.
--
local ORB_PICKUP_VFX_NAME = "Orb"
local ORB_PICKUP_EMIT_COUNT = 5
-- Grace period past the longest authored Lifetime before the clone is
-- collected. DERIVED rather than a fixed guess: destroying an emitter kills
-- anything still in flight, and the HRP outlives the burst, so a short fixed
-- delay would clip a long authored fade.
local ORB_PICKUP_CLEANUP_MARGIN = 0.5
local ORB_PICKUP_COLORS: { [string]: Color3 } = {
	[DropTypes.Health] = Color3.fromRGB(85, 255, 127),
	[DropTypes.Mana] = Color3.fromRGB(85, 255, 255),
}

local function playOrbPickupVFX(player: Player, dropType: string)
	local tintColor = ORB_PICKUP_COLORS[dropType]
	if not tintColor then
		return
	end

	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return
	end

	local aurasFolder = ReplicatedStorage.GameAssets:FindFirstChild("Auras")
	local template = aurasFolder and aurasFolder:FindFirstChild(ORB_PICKUP_VFX_NAME)
	if not template then
		warn("[DropService] Missing ReplicatedStorage.GameAssets.Auras." .. ORB_PICKUP_VFX_NAME)
		return
	end

	-- Emitters must sit under a BasePart to render, so they clone straight
	-- onto the HRP rather than keeping the folder's structure — same recipe
	-- as StatusConditionService's aura rigs.
	local tint = ColorSequence.new(tintColor)
	for _, particle in template:GetDescendants() do
		if particle:IsA("ParticleEmitter") then
			local clone = particle:Clone()
			clone.Name = "OrbPickupVFX"
			clone.Color = tint
			-- Enabled false, then Emit: a ONE-SHOT burst. Left enabled it
			-- would also stream at its authored Rate until Debris collects
			-- it, because the HRP it hangs off is not going anywhere.
			clone.Enabled = false
			clone.Parent = hrp
			-- Parent FIRST, burst SECOND -- :Emit on an unparented emitter is
			-- silently discarded.
			clone:Emit(ORB_PICKUP_EMIT_COUNT)
			Debris:AddItem(clone, clone.Lifetime.Max + ORB_PICKUP_CLEANUP_MARGIN)
		end
	end
end

local DropService = Knit.CreateService({
	Name = "DropService",
})

-- `isBoss` is the SCATTER RADIUS (Client/Components/Drop reads it as
-- IsBoss and throws the drop ±20 studs instead of ±8), not a tier flag.
--
-- `ownerId` makes the drop PRIVATE to one player: only they can see it
-- and only they can bank it. Omit it (as the mob death drops do) and the
-- drop stays SHARED — every player collects the full value once, which
-- is the game's normal party-loot behaviour.
DropService.OnDropRequested = Signal.new() :: (
	basePart: BasePart,
	dropType: DropTypes.DropTypes,
	minDropRate: number,
	maxDropRate: number,
	minValue: number,
	maxValue: number,
	isBoss: boolean,
	ownerId: number?,
	fromChest: boolean?
) -> ()
DropService.OnRelicDropRequested = Signal.new()
DropService.OnRuneDropRequested = Signal.new()
DropService.OnDropCollected = Signal.new() :: (player: Player, dropType: DropTypes.DropTypes, value: number) -> ()
DropService.OnCoinCollected = Signal.new() :: (playerName: string, coinsValue: number) -> ()
DropService.OnManaCollected = Signal.new() :: (playerName: string, manaValue: number) -> ()
DropService.OnChestCoinsRequested = Signal.new()

function DropService:KnitStart()
	MagicService = Knit.GetService("MagicService")
	RunEscrowService = Knit.GetService("RunEscrowService")
	RelicService = Knit.GetService("RelicService")
	ArmorSetBonusService = Knit.GetService("ArmorSetBonusService")
	DataService = Knit.GetService("DataService")
	PlayerStatsService = Knit.GetService("PlayerStatsService")

	self.OnRelicDropRequested:Connect(function(
		player: Player,
		itemRarity: ItemRarity.ItemRarity,
		relicName: RelicNames.RelicNames,
		originalPosition: Vector3,
		targetPosition: Vector3,
		-- public: anyone's to take, no fan (the tray's Drop button).
		-- originalOwner*: whose name the floor label shows — the FIRST
		-- player to drop this relic, not whoever is dropping it now.
		options: {
			public: boolean?,
			originalOwnerId: number?,
			originalOwnerName: string?,
		}?
	)
		local character = player.Character

		if not character or not character.PrimaryPart then
			return
		end

		-- Element-rework folder layout: Relics/<Tree>/<Rarity>/<Name>.
		-- The Skip offer (and anything without a RelicData entry) still
		-- resolves the OLD way -- its `Folder` rides in the rarity slot
		-- (Relics.Skip["Skip Relic"]).
		local relicsFolder = game.ReplicatedStorage.GameAssets.Relics
		local data = RelicData[relicName]
		local template
		if data and data.tree then
			local treeFolder = relicsFolder:FindFirstChild(data.tree)
			local rarityFolder = treeFolder and treeFolder:FindFirstChild(itemRarity)
			template = rarityFolder and rarityFolder:FindFirstChild(relicName)
		end
		if not template then
			local rarityFolder = relicsFolder:FindFirstChild(itemRarity)
			template = rarityFolder and rarityFolder:FindFirstChild(relicName)
		end
		if not template then
			warn("[DropService] Missing relic model: " .. tostring(relicName) .. " (" .. tostring(itemRarity) .. ")")
			return
		end
		local drop = template:Clone()
		drop:ScaleTo(1.5)

		local collectedAttachment = ReplicatedStorage.GameAssets.Particles.Collected:Clone()
		collectedAttachment.Parent = drop.Handle

		-- Tint the collected-burst particles per rarity. RarityColors:Get
		-- returns the Default color for unmapped rarities (Common /
		-- Uncommon / Unique / Mythic / Shiny), which is fine here —
		-- relic drops only roll Rare+ in practice, but if that changes
		-- the particles still render a sensible color instead of nil.
		local rarityColor = RarityColors:Get(itemRarity)
		for _, descendant in collectedAttachment:GetChildren() do
			descendant.Color = ColorSequence.new(rarityColor)
		end

		local dropAttachment = ReplicatedStorage.GameAssets.Particles.DropAttachment:Clone()
		dropAttachment.Parent = drop.Handle
		-- A target past a dungeon wall (a fan slot into a corner, a relic
		-- tossed at a wall) ricochets back into the room; the client flies
		-- the two-segment arc through BouncePosition.
		local landing, bounce = resolveArcLanding(originalPosition, targetPosition)
		drop:SetAttribute("TargetPosition", landing)
		if bounce then
			drop:SetAttribute(Attributes.BouncePosition, bounce)
		end
		if options and options.public then
			-- No OwnerId at all: the owner lock and the fan-wide claim
			-- (client + server Relic components) both key off it. The
			-- ORIGINAL owner's name rides along instead, purely for the
			-- billboard's UserText — it grants nothing. RelicService supplies
			-- it and carries it across hand-offs, so a relic passed down a
			-- chain of players still reads its first owner. Falls back to the
			-- dropper for any caller that does not say.
			drop:SetAttribute(Attributes.PublicDrop, true)
			drop:SetAttribute(Attributes.DroppedByName, (options and options.originalOwnerName) or player.Name)
			drop:SetAttribute(Attributes.DroppedById, (options and options.originalOwnerId) or player.UserId)
		else
			drop:SetAttribute("OwnerId", player.UserId)
		end
		drop:AddTag(TagList.Relic)
		-- PivotTo, not PrimaryPart.CFrame, so MULTI-handle relics
		-- (e.g. Super Stomp Boots Full with Handle + Handle2) move
		-- as one unit. Setting PrimaryPart.CFrame only moves that
		-- one part — secondary handles stayed at their template
		-- world position, so only one boot appeared at the drop
		-- site and the other one was stranded at 0,0,0.
		drop:PivotTo(CFrame.new(originalPosition))
		drop.Parent = workspace.IgnoreInstances.Drops
	end)

	-- Physical rune drops (rune machines). Mirrors the relic path but
	-- simpler: the model comes from GameAssets.Runes[<name>], the particles
	-- under its RelicParticleAttachment (Layer / Shine / Spark) are tinted
	-- to the rolled rarity's colour, and the drop is placed directly at its
	-- fan position (no client arc -- runes have no client component).
	-- Physical rune drops (rune machines) -- the EXACT relic recipe: the
	-- model spawns at the machine's mouth, the CLIENT Rune component
	-- animates the bezier arc to TargetPosition, and the Collected /
	-- DropAttachment particles ride the Handle just like a relic's.
	self.OnRuneDropRequested:Connect(
		function(
			player: Player,
			itemRarity: string,
			runeName: string,
			originalPosition: Vector3,
			targetPosition: Vector3
		)
			local runesFolder = ReplicatedStorage.GameAssets:FindFirstChild("Runes")
			local template = runesFolder and runesFolder:FindFirstChild(runeName)
			if not template then
				warn("[DropService] Missing rune model: GameAssets.Runes." .. tostring(runeName))
				return
			end

			local drop = template:Clone()
			drop:ScaleTo(1.5)

			-- Runes use their OWN particle palette (RuneRarityColors), not the
			-- game-wide RarityColors the relic path above uses.
			local rarityColor = RuneRarityColors:Get(itemRarity)

			-- Pickup-burst + drop-trail attachments, tinted per rarity --
			-- same clones the relic path parents onto the Handle.
			local collectedAttachment = ReplicatedStorage.GameAssets.Particles.Collected:Clone()
			collectedAttachment.Parent = drop.Handle
			for _, descendant in collectedAttachment:GetChildren() do
				descendant.Color = ColorSequence.new(rarityColor)
			end

			local dropAttachment = ReplicatedStorage.GameAssets.Particles.DropAttachment:Clone()
			dropAttachment.Parent = drop.Handle

			-- Rarity tint on the authored RelicParticleAttachment set.
			for _, descendant in drop:GetDescendants() do
				if descendant.Name == "RelicParticleAttachment" then
					for _, particle in descendant:GetChildren() do
						if particle:IsA("ParticleEmitter") then
							particle.Color = ColorSequence.new(rarityColor)
						end
					end
				end
			end

			-- Same wall ricochet as the relic path.
			local landing, bounce = resolveArcLanding(originalPosition, targetPosition)
			drop:SetAttribute("TargetPosition", landing)
			if bounce then
				drop:SetAttribute(Attributes.BouncePosition, bounce)
			end
			drop:SetAttribute("OwnerId", player.UserId)
			drop:SetAttribute("RuneRarity", itemRarity)
			drop:AddTag(TagList.Rune)
			-- Spawn at the machine's mouth; the client's bezier carries it to
			-- the fan position (PivotTo so multi-part models move as one).
			drop:PivotTo(CFrame.new(originalPosition))
			drop.Parent = workspace.IgnoreInstances.Drops
		end
	)

	self.OnDropRequested:Connect(
		function(
			basePart: BasePart,
			dropType: DropTypes.DropTypes,
			minDropRate: number,
			maxDropRate: number,
			minValue: number,
			maxValue: number,
			isBoss: boolean,
			ownerId: number?,
			fromChest: boolean?
		)
			for _ = 1, math.random(minDropRate, maxDropRate) do
				task.wait(IS_BOSS_COIN_DROP_DELAY)

				local drop = game.ReplicatedStorage.GameAssets.Drops.Default:Clone()
				drop:SetAttribute(Attributes.IsBoss, isBoss or false)
				if ownerId then
					-- Private drop: the client hides it from everyone else and
					-- the server refuses their collect (Server/Components/Drop).
					drop:SetAttribute(Attributes.OwnerId, ownerId)
				end
				if fromChest then
					-- Chest loot pops out with a blip per coin; mob death loot
					-- stays silent (it would be constant).
					drop:SetAttribute("ChestDrop", true)
				end
				drop:SetAttribute(Attributes.DropValue, math.random(minValue or 1, maxValue or 1))
				drop:SetAttribute(Attributes.DropType, dropType)
				drop:SetAttribute(Attributes.ImageId, DropData[dropType].image)

				-- Landing picked here (see COIN_SCATTER_STUDS); the client keeps
				-- its own Y offset on top, as before.
				local scatter = if isBoss then COIN_SCATTER_BOSS_STUDS else COIN_SCATTER_STUDS
				local target = basePart.Position
					+ Vector3.new(math.random(-scatter, scatter), 0, math.random(-scatter, scatter))
				local landing, bounce = resolveArcLanding(basePart.Position, target)
				drop:SetAttribute("TargetPosition", landing)
				if bounce then
					drop:SetAttribute(Attributes.BouncePosition, bounce)
				end
				drop.PrimaryPart.Position = basePart.Position
				drop.Parent = workspace.IgnoreInstances.Drops
			end
		end
	)

	self.OnDropCollected:Connect(function(player: Player, dropType: DropTypes.DropTypes, value: number)
		if dropType == DropTypes.Coins then
			-- Collector-side coin multipliers, all at credit time so the
			-- bonus belongs to whoever picks the coin up and lands on the
			-- full instance value:
			--   * Explorer set bonus (all 3 Adventurers pieces): ×1.10
			--     (getter returns 1 when not fully equipped).
			--   * Looter (equipped enchanted weapon): ×1.10.
			--   * Pot Of Gold: ×1.35 ("Gain +35% Coins gain" — personal;
			--     (its drop-chance half left with the rework).
			-- All compose multiplicatively.
			-- Read from the callback rather than a hardcoded 1.50 so the number
			-- lives in exactly one place (RelicData). Callback returns the BONUS
			-- fraction (0.50), so the multiplier is 1 + it.
			-- Relic coin bonuses (Pot Of Gold +25%) sum ADDITIVELY into ONE
			-- multiplier. Each magnitude comes from its own callback (the BONUS
			-- fraction), so the numbers live only in RelicData.
			local relicCoinBonus = 0
			for _, relicName in COIN_BONUS_RELICS do
				if RelicService:GetSpecificRelicRegistry(player, relicName) > 0 then
					relicCoinBonus += RelicService:GetRelicEffect(player, relicName) or 0
				end
			end
			local relicCoinMultiplier = 1 + relicCoinBonus
			-- Dragon Lantern (Cursed): "+200% more Coins from all sources" -- same
			-- credit-time site as Pot Of Gold, so the run-coin readout, the 10%
			-- damage tax and the eventual bank all see the multiplied number.
			-- (It used to multiply at bank time in CurrencyService, which tripled
			-- coins earned BEFORE the relic and taxed the un-tripled value.)
			-- Callback returns the full multiplier (3).
			local dragonLanternMultiplier = 1
			if RelicService:GetSpecificRelicRegistry(player, RelicNames["Dragon Lantern"]) > 0 then
				dragonLanternMultiplier = RelicService:GetRelicEffect(player, RelicNames["Dragon Lantern"]) or 1
			end
			value = math.round(
				value
					* ArmorSetBonusService:GetCoinMultiplier(player)
					* getLooterCoinMultiplier(player)
					* relicCoinMultiplier
					* dragonLanternMultiplier
					-- Greater Shrine "Fortune": coin DROPS only, run-scoped.
					* (1 + PlayerStatsService:GetGreaterShrineEffect(player, "Coin"))
			)

			-- Death economy: run coins go to the ESCROW, not the profile —
			-- banked on dungeon clear, lost on death/disconnect
			-- (RunEscrowService). Multipliers apply here at collect time so
			-- the escrowed number is already final.
			RunEscrowService:AddCoins(player, value)
			-- Fires the coin collected signal for any client-side effects (like text indicators)
			self.OnCoinCollected:Fire(player.Name, value)
			--DataService:SetNumericalProfileData(player, ProfileTemplateIndex.Coins, value)
			-- self.OnCoinCollected:Fire(player, value)
		elseif dropType == DropTypes.Mana then
			playOrbPickupVFX(player, dropType)

			-- Mana orbs restore 10% of the player's max mana.
			-- Gear Recycler: "Mana Orbs grant +50% more mana" — its callback
			-- returns the multiplier (1.5), applied to the base fraction so it
			-- scales with the player's max mana.
			local BASE_MANA_FRACTION = 0.1
			local manaMultiplier = RelicService:GetRelicEffect(player, RelicNames["Gear Recycler"]) or 1

			local currentMana = MagicService:GetPlayerMagicData(player).mana
			local maxMana = MagicService:GetPlayerMagicData(player).maxMana
			local manaRestored = currentMana + (maxMana * BASE_MANA_FRACTION * manaMultiplier)

			MagicService:SetPlayerMagicData(player, math.clamp(manaRestored, 0, maxMana), maxMana)
		elseif dropType == DropTypes.Health then
			-- Ahead of the humanoid guard below: you picked the orb up, so the
			-- flourish plays even in the edge case where the heal cannot.
			playOrbPickupVFX(player, dropType)

			-- Teddy Trap (Cursed): HEALTH ORBS no longer heal its owner — the
			-- orb is consumed (VFX played) and restores nothing. This is the
			-- relic's whole heal block; every other heal source works normally.
			if RelicService:GetSpecificRelicRegistry(player, RelicNames["Teddy Trap"]) > 0 then
				return
			end

			-- Health orbs restore 5% of the player's max health. Healing
			-- amps (Holiday Ham, Regeneration Coil) apply inside
			-- ApplyHealing — any-source, summed additively.
			local BASE_HEALTH_FRACTION = 0.05

			local humanoid = player.Character and player.Character:FindFirstChild("Humanoid")

			if not humanoid then
				return
			end

			PlayerStatsService:ApplyHealing(player, humanoid.MaxHealth * BASE_HEALTH_FRACTION)
		elseif dropType == DropTypes.ChestCoins then
			self.OnChestCoinsRequested:Fire(player, value)
		elseif dropType == DropTypes.Relics then
			-- Relic drops are handled in the RelicService, so we just fire a signal here for any client-side effects
			self.OnDropCollected:Fire(player, dropType, value)
		end
	end)
end

return DropService
