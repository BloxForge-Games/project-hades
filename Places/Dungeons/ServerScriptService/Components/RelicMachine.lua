--!strict
--[[
     Author(s): ryanisawesome25
     Module: RelicMachine.luau
     Description:
]]

--[ Exports & Types & Defaults ]--

--[ Roblox Services ]--

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

--[ Imports ]--

local Component = require(ReplicatedStorage.Submodules.Core.Packages.Component)
local TextIndicatorService = require(ServerScriptService.Submodules.Core.Source.Services.TextIndicatorService)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local RelicService = require(ServerScriptService.Services.RelicService)
local RelicOfferService = require(ServerScriptService.Services.RelicOfferService)
local DungeonNetwork = require(ServerScriptService.Submodules.Core.Source.Network.Dungeon)
local InstanceRouter = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Network.InstanceRouter)
local ItemRarity = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ItemRarity)
local RelicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicData)
local RelicCombo = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicCombo)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local ElementTrees = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ElementTrees)
local LifeService = require(ServerScriptService.Services.LifeService)

--[ Component Root ]--

local promptRouter = InstanceRouter.Server(DungeonNetwork.RelicMachinePromptTriggered, function(data)
	return data.Machine
end)

local RelicMachine = Component.new({
	Tag = "RelicMachine",
})

--[ Constants ]--

-- RELIC CAP (design call, 2026-10-21): a machine never opens for an
-- owner holding as many relics as they have slots. The pull would only
-- ever end in a Skip, so the prompt refuses instead -- the shop's own
-- red pop over the player and its Error sound -- and the machine stays
-- intact. A capped owner's choice is marked MADE the moment the machine
-- lands (and again on every refused tap), so the segment gate does not
-- hold its full countdown for a pull nobody can take.
local RELIC_CAP_COLOR = Color3.fromRGB(250, 70, 70)
local RELIC_CAP_TEXT = "Reached Maximum Relics! (%d)"
local RELIC_CAP_LABEL = "Vending Machine (Relics Full)"
local ERROR_SOUND_NAME = "Error"
local ERROR_SOUND_LIFETIME = 3

--[ Properties ]--

--[ Private Functions ]--

-- The shop's refusal pop and sound, over the player's root.
local function refuseAtRelicCap(player: Player)
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not (hrp and hrp:IsA("BasePart")) then
		return
	end
	TextIndicatorService:ShowIndicator(
		player,
		hrp,
		RELIC_CAP_TEXT:format(RelicService:GetRelicSlots(player)),
		RELIC_CAP_COLOR,
		true
	)
	local sounds = ReplicatedStorage.GameAssets:FindFirstChild("Sounds")
	local template = sounds and sounds:FindFirstChild(ERROR_SOUND_NAME)
	if template and template:IsA("Sound") then
		local clone = template:Clone()
		clone.Parent = hrp
		clone:Play()
		Debris:AddItem(clone, ERROR_SOUND_LIFETIME)
	end
end

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
--
-- The pull is dealt as CARDS on the owner's screen (RelicOfferService),
-- not dropped on the floor: the machine only rolls the hand and plays its
-- own dispense flourish. The Skip option and the 30 s auto-pick are the
-- offer service's.
local OFFER_SOURCE = "Vending"

-- Starter machine only: how many of its offers are FORCED to be an ungated
-- relic from a random element tree. Anything past this rolls normally, so
-- the leftover slots can still come up elemental by luck.
--
-- 0 (2026-10-30): no guarantee; the first machine rolls like any other
-- (it still offers ungated relics only). It was 1 from 2026-10-29, and 0
-- from the 2026-08-31 call before that.
local STARTER_GUARANTEED_ELEMENTS = 0

-- Slot roles for one pull, shuffled in place. See the call site for the
-- per-machine rules.
-- Picks ONE offer. Selection is PURE RANDOM inside a rolled rarity -- the
-- only filtering left is `premiumOnly` (Pinata's Epic+ restriction) plus the
-- ownership / already-offered exclusions applied above.
-- STARTER SLOT: an unowned, ungated relic of `tree`, or nil when the tree
-- has none left. Bypasses the rarity roll -- the point is a guaranteed
-- elemental foothold for the run's opening pull -- but keeps to the tree's
-- RARE ungated relics while it has any, so the guarantee never hands out
-- an Epic for free (every tree has NC Epics since the 2026-10 pass).
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
	local rares = {}
	for _, relicName in candidates do
		if RelicData[relicName].rarity == ItemRarity.Rare then
			table.insert(rares, relicName)
		end
	end
	if #rares > 0 then
		candidates = rares
	end

	local picked = candidates[math.random(1, #candidates)]
	local index = table.find(self._relics, picked)
	if index then
		table.remove(self._relics, index)
	end
	return RelicData[picked]
end

-- `onlyTree` (2026-11-01) restricts the candidates to one tree; with
-- Neutral it also leaves the Cursed tier out, so the guaranteed Neutral
-- slot of a hand is a plain Neutral card.
function RelicMachine:_getRandomRelicData(premiumOnly: boolean?, onlyTree: string?)
	if #self._relics == 0 then
		return nil
	end

	-- Pinata: restrict the pool to the premium tiers. Cursed counts --
	-- per design, "Epic or higher" includes the trade-off tier.
	local PREMIUM_RARITIES = {
		[ItemRarity.Epic] = true,
		[ItemRarity.Legendary] = true,
		[ItemRarity.Duo] = true,
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
		local treeOk = true
		if onlyTree then
			local data = RelicData[relicName]
			treeOk = (data.tree or ElementTrees.Neutral) == onlyTree
				and not (onlyTree == ElementTrees.Neutral and data.rarity == ItemRarity.Cursed)
		end
		if rarityOk and comboOk and treeOk and (ownedRegistry[relicName] or 0) == 0 then
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
	-- Run's-first-machine marker. Only meaningful while
	-- STARTER_GUARANTEED_ELEMENTS > 0; at 0 (today) the starter rolls
	-- exactly like any other machine.
	self._isStarterMachine = self.Instance:GetAttribute("IsStarterMachine") == true
	-- The prompt bubble's title is the AUTHORED ObjectText; stamped here
	-- so the label never depends on what the asset says.
	self._proximityPrompt.ObjectText = "Vending Machine"
	self.Instance.PrimaryPart.VendingMachineName.Frame.VendingMachineText.Text = "Vending Machine (Active)"
	self.Instance.PrimaryPart.VendingMachineName.Frame.VendingMachineText.TextColor3 = Color3.fromRGB(85, 255, 127)

	self.Instance.PrimaryPart.Idle:Play()

	local owner = Players:GetPlayerByUserId(self._ownerId)
	self._relics = RelicService:GetPlayerAvailableRelics(owner)

	-- A capped owner (see RELIC_CAP_COLOR): the label says so from the
	-- landing, and their choice is already made for the gate.
	if owner and RelicService:IsAtRelicCap(owner) then
		self.Instance.PrimaryPart.VendingMachineName.Frame.VendingMachineText.Text = RELIC_CAP_LABEL
		self.Instance.PrimaryPart.VendingMachineName.Frame.VendingMachineText.TextColor3 = RELIC_CAP_COLOR
		RelicService:MarkRelicChoiceMade(owner)
	end

	promptRouter:Bind(self.Instance, function(player: Player, _payload: { CFrame: CFrame })
		-- A dead player collects nothing: the run gear that spilled out of the
		-- corpse is for the living (or for this player after a revive).
		if LifeService:IsDeathState(player) then
			return
		end
		-- At the relic cap the machine refuses and stays whole (the client
		-- keeps its prompt up for the same reason): red pop, Error sound,
		-- choice marked made so the gate never waits on it.
		if self._ownerId == player.UserId and RelicService:IsAtRelicCap(player) then
			refuseAtRelicCap(player)
			RelicService:MarkRelicChoiceMade(player)
			return
		end
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
			self.Instance.PrimaryPart.VendingMachineName.Frame.VendingMachineText.Text = "Vending Machine (Empty)"
			self.Instance.PrimaryPart.VendingMachineName.Frame.VendingMachineText.TextColor3 =
				Color3.fromRGB(255, 85, 85)

			-- Pinata (Cursed): the owner gets TWO choices instead of three,
			-- but the pool is filtered to Epic-or-higher (Epic / Legendary /
			-- Cursed -- the premium tiers) inside _getRandomRelicData. Purely
			-- per-owner: machines belong to one player, so nobody else's
			-- choices are affected.
			local ownsPinata = RelicService:GetSpecificRelicRegistry(player, RelicNames.Pinata) > 0
			local offerCount = if ownsPinata then 2 else 3

			-- First machine of the run for this owner: every offer must be a
			-- different primary archetype. Rarity weights are untouched -- only
			-- the archetype spread is guaranteed.

			-- Every slot rolls RelicService.RollRandomRelicFromPool: a tree
			-- drawn uniformly, a rarity from RelicRollConfig, a card drawn
			-- uniformly. No slot roles, no affinity, no weighting of any kind
			-- (design call, 2026-10-31).
			-- STARTER MACHINE: STARTER_GUARANTEED_ELEMENTS slots (currently
			-- ZERO) would be forced to an ungated relic from a random element
			-- tree; the rest roll normally.
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

			local offers = {}
			for i = 1, offerCount do
				local relicData
				local tree = starterTrees and starterTrees[i]
				if tree then
					relicData = self:_getStarterRelicData(tree)
				end
				relicData = relicData or self:_getRandomRelicData(ownsPinata)
				if relicData then
					table.insert(offers, relicData.name)
				end
			end

			-- At least one plain Neutral card in every hand (design call,
			-- 2026-11-01): the tree draw stays as it is for the other slots,
			-- and only when no slot rolled Neutral does one random free slot
			-- (never a starter-guaranteed one) swap its card for a Neutral
			-- pick. The displaced card goes back into the machine's pool.
			-- Cursed does not count as the Neutral card.
			local hasNeutral = false
			for _, offerName in offers do
				local offerData = RelicData[offerName]
				if
					offerData
					and (offerData.tree or ElementTrees.Neutral) == ElementTrees.Neutral
					and offerData.rarity ~= ItemRarity.Cursed
				then
					hasNeutral = true
					break
				end
			end
			if not hasNeutral and #offers > 0 then
				local freeSlots = {}
				for slot = 1, #offers do
					if not (starterTrees and starterTrees[slot]) then
						table.insert(freeSlots, slot)
					end
				end
				if #freeSlots > 0 then
					local slot = freeSlots[math.random(1, #freeSlots)]
					local neutralData = self:_getRandomRelicData(ownsPinata, ElementTrees.Neutral)
					if neutralData then
						table.insert(self._relics, offers[slot])
						offers[slot] = neutralData.name
					end
				end
			end

			self.Instance.PrimaryPart.Pop:Play()

			-- The hand goes to the owner's screen. An EMPTY hand (the pool is
			-- exhausted) still counts as the owner's choice, so the gate's
			-- countdown does not wait on a pull that had nothing to give.
			if not RelicOfferService:Offer(player, offers, OFFER_SOURCE) then
				RelicService:MarkRelicChoiceMade(player)
			end
		end
	end)
end

function RelicMachine:Stop() end

return RelicMachine
