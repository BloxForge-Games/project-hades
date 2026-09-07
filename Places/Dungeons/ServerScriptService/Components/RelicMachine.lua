--[[
     Author(s): ryanisawesome25
     Module: RelicMachine.luau
     Description:
]]

--[ Exports & Types & Defaults ]--

--[ Roblox Services ]--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--[ Imports ]--

local Component = require(ReplicatedStorage.Submodules.Core.Packages.Component)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local ItemRarity = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ItemRarity)
local RelicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicData)
local RelicCombo = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicCombo)
local SkipRelicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.SkipRelicData)
local RuneNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RuneNames)
local RelicRollConfig = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicRollConfig)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local ElementTrees = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ElementTrees)
local CommAdder = require(ReplicatedStorage.Submodules.Core.Source.ComponentExtensions.CommAdder)

local DropService
local RelicService

Knit.OnStart()
	:andThen(function()
		DropService = Knit.GetService("DropService")
		RelicService = Knit.GetService("RelicService")
	end)
	:catch(warn)

--[ Component Root ]--

local RelicMachine = Component.new({
	Tag = "RelicMachine",
	Extensions = { CommAdder },
})

--[ Constants ]--

--[ Properties ]--

--[ Private Functions ]--

-- Picks the next relic for this machine via RelicService:RollRandomRelicFromPool,
-- which buckets the per-player available pool by rarity and rolls using the
-- RUN-STAGE rarity table in Shared/Data/RelicRollConfig.
--
-- The previous implementation flat-rolled math.random(1, #self._relics) which
-- ignored rarity entirely — if the pool happened to have more Epics than
-- Rares (often true once the player has stacked their cheapest Rares), Epics
-- came up far more often than the GDD weights would suggest.
--
-- Two-pass exclusion of owned relics:
--   (1) The local `_relics` pool was seeded from
--       RelicService:GetPlayerAvailableRelics at machine spawn — it already
--       excluded relics the player owned AT THAT MOMENT.
--   (2) Re-query the player's CURRENT registry on every pick and skip
--       names they've acquired since the machine spawned. Without (2),
--       two vending machines that spawn back-to-back (RelicMachineService
--       spawns 10 at dungeon start, plus one per cleared Combat segment)
--       can both offer the same relic, the player picks it up from
--       machine A, then sees machine B offer it again as a phantom
--       duplicate — the AddRelicsRegistry hard-no-ops on the second
--       pickup so they get nothing for it. The re-query closes that
--       window: machine B's pick reads the live registry and skips
--       anything the player already owns.
--
-- After picking, the chosen name is removed from the local pool so the same
-- machine can't roll duplicates across its three offers either.
-- Relic fan geometry: slots spread symmetrically around the machine's
-- centre line, with the true middle slot (odd counts only) stepping
-- forward -- the authored left / middle-forward / right silhouette.
local FAN_SPACING_STUDS = 5.5
local FAN_BASE_Z = 6
local FAN_FORWARD_Z = 7

-- The Skip offer is NOT part of the fan: it drops alone, centred and
-- further out, so it reads as "decline" rather than another relic.
local SKIP_OFFER_Z_OFFSET = 14

-- Starter machine only: how many of its offers are FORCED to be an ungated
-- relic from a random element tree. Anything past this rolls normally, so
-- the leftover slots can still come up elemental by luck.
--
-- 0 = the run's first machine rolls exactly like any other machine
-- (2026-08-31 design call: completely random, no guaranteed elemental).
-- The forcing machinery stays dormant so this is retunable in one number.
local STARTER_GUARANTEED_ELEMENTS = 0

-- Slot roles for one pull, shuffled in place. See the call site for the
-- per-machine rules.
-- Picks ONE offer. Selection is PURE RANDOM inside a rolled rarity -- the
-- only filtering left is `premiumOnly` (Pinata's Epic+ restriction) plus the
-- ownership / already-offered exclusions applied above.
-- STARTER SLOT: an unowned, ungated relic of `tree`, or nil when the tree
-- has none left. Bypasses the rarity roll entirely -- the point is a
-- guaranteed elemental foothold for the run's opening pull, and every
-- tree's NC pair is Rare anyway, so there is no rarity to preserve.
function RelicMachine:_getStarterRelicData(tree: string)
	local owner = Players:GetPlayerByUserId(self._ownerId)
	if not owner or not tree then
		return nil
	end

	local candidates = {}
	for _, relicName in RelicService:GetUnownedNCRelicsForTree(owner, tree) do
		-- Respect this machine's own no-duplicates pool.
		if table.find(self._relics, relicName) then
			table.insert(candidates, relicName)
		end
	end
	if #candidates == 0 then
		return nil
	end

	local picked = candidates[math.random(1, #candidates)]
	local index = table.find(self._relics, picked)
	if index then
		table.remove(self._relics, index)
	end
	return RelicData[picked]
end

function RelicMachine:_getRandomRelicData(premiumOnly: boolean?)
	if #self._relics == 0 then
		return nil
	end

	-- Pinata: restrict the pool to the premium tiers. Cursed counts --
	-- per design, "Epic or higher" includes the trade-off tier.
	local PREMIUM_RARITIES = {
		[ItemRarity.Epic] = true,
		[ItemRarity.Legendary] = true,
		[ItemRarity.Cursed] = true,
	}

	-- Re-query owned relics LIVE (not the snapshot from machine spawn).
	-- Build a fresh candidate list filtered against the player's current
	-- registry. We don't mutate self._relics here — the original list is
	-- still useful as the seed; we just refine it per-pick.
	local owner = Players:GetPlayerByUserId(self._ownerId)
	local ownedRegistry = owner and RelicService:GetRelicsRegistry(owner) or {}
	local candidates = {}
	for _, relicName in self._relics do
		local rarityOk = not premiumOnly or PREMIUM_RARITIES[RelicData[relicName].rarity] == true
		-- Starter machine: NC only, HARD. The run's opening pull may
		-- never show a C / C2 relic, regardless of what eligibility
		-- math would otherwise allow.
		local comboOk = not self._isStarterMachine or RelicData[relicName].combo == RelicCombo.NC
		if rarityOk and comboOk and (ownedRegistry[relicName] or 0) == 0 then
			table.insert(candidates, relicName)
		end
	end

	if #candidates == 0 then
		return nil
	end

	-- The owner is always passed: every role needs the build state (Synergy
	-- to lean toward it, Wildcard to lean away, and ALL roles to resolve duo
	-- prerequisites). The ROLE is what decides how that state is used.
	local relicName = RelicService:RollRandomRelicFromPool(candidates, nil, nil, owner)
	if not relicName then
		return nil
	end

	local index = table.find(self._relics, relicName)
	if index then
		table.remove(self._relics, index)
	end

	return RelicData[relicName]
end

--[ Public Functions ]--

--[ Initializers ]--

-- Rune machines: pick `count` DISTINCT rune types, each with a rarity
-- rolled from the run-stage weights (same table the relic roll uses,
-- Cursed excluded -- runes have no Cursed tier).
local function rollRuneOffers(count: number): { { name: string, rarity: string } }
	local names = {}
	for _, runeName in RuneNames do
		table.insert(names, runeName)
	end
	-- Fisher-Yates, then take the first `count`.
	for i = #names, 2, -1 do
		local j = math.random(1, i)
		names[i], names[j] = names[j], names[i]
	end

	local stage = RelicService:GetRunStage()
	local weights = RelicRollConfig.RarityWeights[stage] or RelicRollConfig.RarityWeights.Early
	local offers = {}
	for i = 1, math.min(count, #names) do
		local total = 0
		for _, weight in weights do
			total += weight
		end
		local roll = math.random() * total
		local rolled = ItemRarity.Rare
		for rarity, weight in weights do
			roll -= weight
			if roll <= 0 then
				rolled = rarity
				break
			end
		end
		table.insert(offers, { name = names[i], rarity = rolled })
	end
	return offers
end

function RelicMachine:Construct()
	-- A tagged machine whose PrimaryPart link is broken (part deleted /
	-- renamed / model rebuilt in Studio) would stack-trace on the next
	-- line and never name itself. Bail loudly with the culprit instead;
	-- Start() checks the same field and skips the dead machine.
	local primary = self.Instance.PrimaryPart
	local attachment = primary and primary:FindFirstChild("Attachment")
	if not attachment then
		warn(
			("[RelicMachine] '%s' has no PrimaryPart.Attachment — machine not wired (unset PrimaryPart on the model?)"):format(
				self.Instance:GetFullName()
			)
		)
		return
	end
	self._proximityPrompt = attachment:WaitForChild("ProximityPrompt")
	self._ownerId = self.Instance:GetAttribute(Attributes.OwnerId)
	self._onPromptTriggered = self._comm:CreateSignal("OnPromptTriggered")
	self._relics = {}
	self._canClick = true
end

function RelicMachine:Start()
	if not self._proximityPrompt then
		return -- Construct bailed on a broken model; its warn names it
	end
	self._relics = {}

	self.Instance.PrimaryPart.VendingMachineName.Frame.NameText.Text = Players:GetPlayerByUserId(self._ownerId).Name
		.. "'s"
	self._isRuneMachine = self.Instance:GetAttribute("MachineType") == "Rune"
	-- Run's-first-machine marker. Only meaningful while
	-- STARTER_GUARANTEED_ELEMENTS > 0; at 0 (today) the starter rolls
	-- exactly like any other machine.
	self._isStarterMachine = self.Instance:GetAttribute("IsStarterMachine") == true
	-- The prompt bubble's title is the AUTHORED ObjectText, and the Rune
	-- model was duplicated from Default -- stamp it here so the label
	-- always matches the machine kind, whatever the asset says.
	self._proximityPrompt.ObjectText = if self._isRuneMachine then "Rune Machine" else "Vending Machine"
	self.Instance.PrimaryPart.VendingMachineName.Frame.VendingMachineText.Text = if self._isRuneMachine
		then "Rune Machine (Active)"
		else "Vending Machine (Active)"
	self.Instance.PrimaryPart.VendingMachineName.Frame.VendingMachineText.TextColor3 = Color3.fromRGB(85, 255, 127)

	self.Instance.PrimaryPart.Idle:Play()

	self._relics = RelicService:GetPlayerAvailableRelics(Players:GetPlayerByUserId(self._ownerId))

	self._onPromptTriggered:Connect(function(player: Player, cframe: CFrame)
		if self._ownerId == player.UserId and self._canClick then
			self._proximityPrompt.Enabled = false
			self._canClick = false

			self.Instance.PrimaryPart.InteractParticle:Emit(10)

			self.Instance.PrimaryPart.InteractSound:Play()
			self.Instance.PrimaryPart.InteractSound.TimePosition = 0.65
			self.Instance.PrimaryPart.InteractSound2:Play()
			self.Instance.PrimaryPart.InteractSound2.TimePosition = 0.65

			--Destroy particles
			self.Instance.PrimaryPart.Idle:Stop()
			self.Instance.PrimaryPart.Attachment1.ParticleEmitter.Enabled = false
			self.Instance.PrimaryPart.Attachment.PointLight.Enabled = false
			self.Instance.PrimaryPart.Attachment.Shine.Enabled = false
			self.Instance.PrimaryPart.Layer.Enabled = false
			self.Instance.PrimaryPart.Spark.Enabled = false
			self.Instance.PrimaryPart.VendingMachineName.Frame.VendingMachineText.Text = if self._isRuneMachine
				then "Rune Machine (Empty)"
				else "Vending Machine (Empty)"
			self.Instance.PrimaryPart.VendingMachineName.Frame.VendingMachineText.TextColor3 =
				Color3.fromRGB(255, 85, 85)

			-- Pinata (Cursed): the owner gets TWO choices instead of three,
			-- but the pool is filtered to Epic-or-higher (Epic / Legendary /
			-- Cursed -- the premium tiers) inside _getRandomRelicData. Purely
			-- per-owner: machines belong to one player, so nobody else's
			-- choices are affected.
			-- RUNE machine: three distinct rune types, rarity rolled per offer.
			-- Pinata's 2-choice drawback is relic-machine-only; runes have no
			-- cap and no Skip offer.
			if self._isRuneMachine then
				local runeOffers = rollRuneOffers(3)
				local runeCenter = (#runeOffers + 1) / 2
				local machineHalfHeight = self.Instance.PrimaryPart.Size.Y / 2
				local runeOrigin = cframe.Position + Vector3.new(0, machineHalfHeight, 0)
				for i, offer in runeOffers do
					local xOffset = (i - runeCenter) * FAN_SPACING_STUDS
					local zOffset = if math.abs(i - runeCenter) < 0.01 then FAN_FORWARD_Z else FAN_BASE_Z
					local position = cframe * CFrame.new(xOffset, -machineHalfHeight, zOffset)
					DropService.OnRuneDropRequested:Fire(
						player,
						offer.rarity,
						offer.name,
						runeOrigin,
						position.Position
					)
					self.Instance.PrimaryPart.Pop:Play()
					task.wait(0.25)
				end
				return
			end

			local ownsPinata = RelicService:GetSpecificRelicRegistry(player, RelicNames.Pinata) > 0
			local offerCount = if ownsPinata then 2 else 3

			-- First machine of the run for this owner: every offer must be a
			-- different primary archetype. Rarity weights are untouched -- only
			-- the archetype spread is guaranteed.

			-- CONTROLLED RANDOMNESS -- the pull's roles, at SHUFFLED positions
			-- so nobody learns "the left one is the build pick":
			--   3 offers: Synergy + Neutral + Wildcard.
			--   2 offers (Pinata): Synergy + Wildcard -- the premium filter
			--     already narrows the pool, so the Neutral slot is the one to
			--     drop.
			--   First machine: all Neutral. Nothing is owned yet, so Synergy
			--     and Wildcard would both be no-ops; its archetype allowlist +
			--     diversity rules do the shaping instead.
			local centerIndex = (offerCount + 1) / 2
			local halfHeight = self.Instance.PrimaryPart.Size.Y / 2
			local origin = cframe.Position + Vector3.new(0, halfHeight, 0)

			-- STARTER MACHINE: STARTER_GUARANTEED_ELEMENTS slots (currently
			-- ZERO — the opening pull is completely random) are forced to an
			-- ungated relic from a random element tree; the rest roll
			-- normally and can come up elemental or Neutral on luck alone.
			--
			-- The guaranteed tree is picked fresh HERE, not locked for the run.
			-- Nothing is ever removed from the pool -- the four trees this
			-- machine skips can still appear at any later machine. What narrows a
			-- run is element affinity (RelicService:GetElementAffinityWeight):
			-- whichever of these the player takes gets heavier from then on.
			--
			-- Which SLOT carries the guarantee is shuffled in with the frees,
			-- so the pull cannot be read by position.
			--
			-- A nil pick (that tree's ungated relics are somehow all owned) falls
			-- through to a normal roll rather than leaving a slot empty.
			local starterTrees = nil
			if self._isStarterMachine and STARTER_GUARANTEED_ELEMENTS > 0 then
				local trees = {}
				for _, tree in ElementTrees do
					if tree ~= ElementTrees.Neutral then
						table.insert(trees, tree)
					end
				end
				-- Fisher-Yates, then take the first STARTER_GUARANTEED_ELEMENTS.
				for index = #trees, 2, -1 do
					local swap = math.random(1, index)
					trees[index], trees[swap] = trees[swap], trees[index]
				end
				-- One entry per SLOT: the guaranteed trees first, then nils for
				-- the free slots, shuffled so the free slot is not always last.
				starterTrees = table.create(offerCount)
				for slot = 1, offerCount do
					starterTrees[slot] = if slot <= STARTER_GUARANTEED_ELEMENTS then trees[slot] else nil
				end
				for index = offerCount, 2, -1 do
					local swap = math.random(1, index)
					starterTrees[index], starterTrees[swap] = starterTrees[swap], starterTrees[index]
				end
			end

			for i = 1, offerCount do
				local relicData
				local tree = starterTrees and starterTrees[i]
				if tree then
					relicData = self:_getStarterRelicData(tree)
				end
				relicData = relicData or self:_getRandomRelicData(ownsPinata)

				-- Only a TRUE middle slot steps forward, so the 3-offer pull keeps
				-- its left / middle-forward / right shape and Pinata's pair sits
				-- level.
				local xOffset = (i - centerIndex) * FAN_SPACING_STUDS
				local zOffset = if math.abs(i - centerIndex) < 0.01 then FAN_FORWARD_Z else FAN_BASE_Z
				local position = cframe * CFrame.new(xOffset, -halfHeight, zOffset)

				if relicData then
					DropService.OnRelicDropRequested:Fire(
						player,
						relicData.rarity,
						relicData.name,
						origin,
						position.Position
					)
				end

				self.Instance.PrimaryPart.Pop:Play()

				task.wait(0.25)
			end

			-- Skip offer -- dispensed LAST and ALONE, centred in front of the
			-- machine rather than inside the fan. Only when the owner is at the
			-- relic cap: below it they can always claim something, so a decline
			-- option would be noise; at the cap every relic on offer is
			-- unclaimable and this is their only way to clear the pull and open
			-- the gate. `Folder` rides in the rarity slot so the drop path's
			-- GameAssets.Relics[rarity][name] lookup resolves it unchanged.
			if RelicService:IsAtRelicCap(player) then
				local skipPosition = cframe * CFrame.new(0, -halfHeight, SKIP_OFFER_Z_OFFSET)
				DropService.OnRelicDropRequested:Fire(
					player,
					SkipRelicData.Folder,
					SkipRelicData.Name,
					origin,
					skipPosition.Position
				)
				self.Instance.PrimaryPart.Pop:Play()
			end
		end
	end)
end

function RelicMachine:Stop() end

return RelicMachine
