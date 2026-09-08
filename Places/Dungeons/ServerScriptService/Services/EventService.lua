--[[
	Module: EventService.lua
	Description:
	Server authority for Event-room outcomes: the Sword in the Stone's
	pull rolls, the Cursed Shrine's bargain, and the Merchant's buy / sell
	economy. Dialogue itself runs entirely on the client (the same
	DialogueRegistry graphs NPCs use); the graphs call back into here for
	anything that costs health, moves coins, or grants relics — never
	trust the client with an outcome, only with a request.

	--- WIRING ---
	Rooms arrive from DungeonService.Signals.OnDungeonGenerated. Every
	Event room is recognised by its PREFAB NAME (SwordStone, MerchantShop,
	CursedShrine — the clone keeps it), and its interactables are wired
	here at runtime: NPC tag + DialogueGraph attribute, plus a server-side
	registry entry so a client can never hand us a model we didn't bless.

	--- PER-PLAYER, EVERYTHING ---
	Success state, merchant stock, and drops are all keyed per player.
	One player pulling the sword changes nothing for anyone else; drops
	spawn owner-locked (OwnerId), and the Relic component's claim-one rule
	(collect one -> all your offers despawn) applies unchanged.

	--- HEALTH COSTS ---
	Costs are RAW: no damage variance, no armor, no Slateskin, no Barrier
	absorption — a bargain's price cannot be mitigated away, or Earth
	builds would tank the Shrine for free. They CAN kill, through the same
	lethal clamp DamageService uses (health never hits 0 server-side;
	LifeService:LoseLife owns what death means).
]]

--[ Roblox Services ]--

local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--[ Imports ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local RelicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicData)
local RoomTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RoomTypes)
local ItemRarity = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ItemRarity)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local DropTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.DropTypes)
local GreaterShrineData = require(ReplicatedStorage.Submodules.Core.Shared.Data.GreaterShrineData)
local RelicRollConfig = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicRollConfig)
local rollItemRarity = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Rarity.rollItemRarity)

local DungeonService
local RelicService
local DropService
local LifeService
local PlayerStatsService
local UserNotificationService
local CoffinEventService
local TextIndicatorService
local RunEscrowService

--[ Constants ]--

-- Sword in the Stone.
local SWORD_PULL_SUCCESS_CHANCE = 0.15
local SWORD_PULL_HEALTH_FRACTION = 0.10

-- Cursed Shrine.
local SHRINE_HEALTH_FRACTION = 0.50
local SHRINE_CURSE_COUNT = 3

-- Greater Shrine. The PrayingStatue in every Start chunk after the first
-- floor: pick ONE Greater Blessing per player, free, granted on the spot
-- and lasting the rest of the run. Spirit joins the fountain's Max-HP
-- pool; Power and Fortune have their own run-scoped pools in
-- PlayerStatsService. All three stack across floors.
--
-- Healing Orbs land when the CONVERSATION ENDS (the close path calls
-- DropGreaterShrineOrbs), not at the choice: ORB_TOTAL split by party
-- size, free-for-all, so the team total is always ORB_TOTAL
-- (12 x 5% = 60% of healing however it divides). floor(), min 1, so a
-- big party never rounds to nothing.

-- Healing Fountain. The benign event: both options are FREE, pick ONE per
-- player per fountain (Leave preserves the choice for a return visit).
-- Drink routes through PlayerStatsService:ApplyHealing, so Holiday Ham's
-- +50% healing applies — deliberate ("healing from any source"), unlike
-- event COSTS which are raw. Attune joins the same additive Max-HP pool
-- as HP relics/runes (RecomputeHealth), so it replicates into
-- BonusHealthPercent, every HP scaler sees it, and it stacks with a
-- fountain found in a later dungeon. Server-lifetime = run-lifetime, so
-- the bonus naturally lasts the whole run.
local FOUNTAIN_HEAL_FRACTION = 0.50
local FOUNTAIN_ATTUNE_HP_FRACTION = 0.15

-- Forge. How many offers the anvil fans out for one sacrificed relic.
-- Three, not one: a single random swap was a lateral trade with no
-- upside — the average outcome was a wash and every bit of the variance
-- was downside, because the relic being fed in was one the player chose.
-- A fan of three makes it a CHOICE, and claim-one keeps the price honest.
local FORGE_OFFER_COUNT = 3

-- Merchant.
local MERCHANT_STOCK_SIZE = 5
-- Sell values are FLAT per rarity; buy prices roll uniformly in-range,
-- once per pedestal per player, so two players see different tags.
local SELL_PRICES = {
	[ItemRarity.Rare] = 200,
	[ItemRarity.Epic] = 400,
	[ItemRarity.Legendary] = 800,
	[ItemRarity.Cursed] = 800,
}
local BUY_PRICE_RANGES = {
	[ItemRarity.Rare] = { 300, 400 },
	[ItemRarity.Epic] = { 600, 800 },
	[ItemRarity.Legendary] = { 1200, 1600 },
}

-- How far from the event model a client request is still honoured. Loose
-- on purpose — the dialogue leash already keeps players close; this only
-- has to stop cross-map exploitation.
local INTERACT_RANGE = 30

-- Drop fan for the sword / shrine payouts, in the model's local space:
-- left flank, center, right flank.
local DROP_OFFSETS = {
	Vector3.new(-5, 0, 6),
	Vector3.new(0, 0, 8),
	Vector3.new(5, 0, 6),
}
-- Which DROP_OFFSETS slots a fan of N drops uses, so ANY count stays
-- centered on the model: one relic lands dead-center (the sword's single
-- Legendary used to take slot 1 and pop out on the LEFT), two flank, three
-- fill the whole fan. Counts past 3 wrap through the full fan like before.
local DROP_SLOT_ORDER: { [number]: { number } } = {
	[1] = { 2 },
	[2] = { 1, 3 },
	[3] = { 1, 2, 3 },
}
-- Fan targets are snapped to the floor with a downward ray (see
-- _spawnRelicFan): cast from this far above each offset point, this
-- far down. Generous on both ends — the sword's PrimaryPart rides
-- high on its stone.
local DROP_GROUND_RAY_UP = 8
local DROP_GROUND_RAY_DOWN = 100
-- Beat between drops on a STAGGERED fan (the Shrine and the Forge). The
-- Sword pays out a single relic, so it has nothing to stagger.
local DROP_STAGGER_SECONDS = 0.25

-- The vending machine's dispense sting. It is authored as a child of the
-- machine's PrimaryPart (Server/Components/RelicMachine plays it once per
-- relic it spits out), so an event fan — which has no machine — borrows
-- it from the template. Everything ELSE about the two presentations is
-- already identical: both go through DropService.OnRelicDropRequested,
-- so the bezier arc, the DropAttachment trail and the landing burst all
-- come from the same client Relic component. This sound was the only
-- piece that lived on the machine itself.
local DROP_POP_SOUND_PATH = { "VendingMachines", "Default" }
local DROP_POP_SOUND_NAME = "Pop"

local NOT_ENOUGH_COINS_COLOR = Color3.fromRGB(255, 92, 92)
local SOLD_COLOR = Color3.fromRGB(85, 255, 127)

--[ Service ]--

local EventService = Knit.CreateService({
	Name = "EventService",
	Client = {
		-- Fired (with the roomId) when a merchant room's stock unlocks
		-- — the room before the shop has STARTED. Clients re-fetch
		-- stalls on it.
		OnMerchantStockUnlocked = Knit.CreateSignal(),
	},

	-- [model] = { kind = "SwordStone" | "CursedShrine" | "MerchantShop", room = room }
	-- Only models wired at generation are honoured by any client call.
	_eventModels = {},

	-- [userId] = { [model] = true } — per-player completion latches.
	_swordDone = {},
	_shrineDone = {},
	_fountainDone = {},
	-- [userId][statueModel] = true once that player took a blessing.
	_greaterShrineDone = {},
	-- [userId][blessingId] = true once taken. RUN-scoped: deliberately
	-- NOT cleared with the per-floor state below, because exclusion is
	-- what stops a run seeing the same blessing twice.
	_greaterShrineTaken = {},
	-- [userId][statueModel] = { blessingId, ... } rolled once and kept,
	-- so walking away and returning cannot re-roll for a better offer.
	_greaterShrineOffers = {},
	-- [userId][statueModel] = true while this player's Healing Orbs are
	-- owed, until the close path drops them (DropGreaterShrineOrbs).
	-- Separate from _greaterShrineDone so the orbs land exactly once.
	_greaterShrinePending = {},
	_forgeDone = {},

	-- [userId] = { model = Model, relics = { string } } — a WON sword
	-- pull, or an accepted shrine bargain, whose relic fan is DEFERRED
	-- until the conversation ends; the close-path MarkEventInteracted
	-- releases it. Costs always land immediately — only the REWARD
	-- waits for the bars to come down.
	_pendingRelicFans = {},

	-- [userId] = { [roomId] = { { relicName, price, sold } } }
	_merchantStock = {},

	-- [roomId] = { merchant = Model?, room = room, slotCFrames = { [index] = CFrame } }
	-- Captured AT GENERATION, server-side — the server sees the whole
	-- floor, so pedestal positions never depend on what has streamed to
	-- any client. GetMerchantStalls serves these with the stock so a
	-- client can render every stand the moment generation lands.
	_merchantRooms = {},

	-- [roomId] = true once the room BEFORE the shop has STARTED (its
	-- combat wave spawned, or its encounter began). Stock is neither
	-- ROLLED nor SERVED before this — rolling late keeps the unowned
	-- filter honest: everything claimed on the approach is registered
	-- before the shelves exist.
	-- [userId] = { [roomId] = true }: which shops each player has walked
	-- into (and so may see / buy from). Per player — see _unlockMerchantRoom.
	_merchantUnlocked = {},

	-- [roomId] = { [userId] = true } — who has interacted with each
	-- Event room. Drives the event exit door's early-open (DungeonService
	-- polls it during the hold). "Interacted" per event: SwordStone /
	-- CursedShrine = finished a conversation; MerchantShop = chose
	-- "I'm ready to continue".
	_interactions = {},
})

--[ Private ]--

-- The vending machine's Pop, cloned onto `part` and played once. Server-
-- side clone so it is spatial and replicates on its own, exactly as the
-- machine's own does.
local function playDropPop(part: BasePart?)
	if not part then
		return
	end
	local node: Instance? = ReplicatedStorage.GameAssets
	for _, childName in DROP_POP_SOUND_PATH do
		node = node and node:FindFirstChild(childName)
	end
	local machinePrimary = node and node:IsA("Model") and node.PrimaryPart
	local template = machinePrimary and machinePrimary:FindFirstChild(DROP_POP_SOUND_NAME)
	if not template or not template:IsA("Sound") then
		warn("[EventService] Missing the vending machine's " .. DROP_POP_SOUND_NAME .. " sound")
		return
	end
	local clone = template:Clone()
	clone.Parent = part
	clone:Play()
	Debris:AddItem(clone, 3)
end

-- One-shot UI-feedback sound at a character's HRP (server-side clone
-- — spatial, replicates on its own). GameAssets.Sounds.<soundName>.
local function playFeedbackSound(hrp: BasePart?, soundName: string)
	if not hrp then
		return
	end
	local sounds = ReplicatedStorage.GameAssets:FindFirstChild("Sounds")
	local template = sounds and sounds:FindFirstChild(soundName)
	if not template then
		warn("[EventService] Missing GameAssets.Sounds." .. soundName)
		return
	end
	local clone = template:Clone()
	clone.Parent = hrp
	clone:Play()
	Debris:AddItem(clone, 3)
end

-- Raw, unmitigable health cost with DamageService's lethal clamp: health
-- never reaches 0 directly — LifeService:LoseLife decides whether the
-- player has a life to burn or enters the death state. Returns "dead"
-- when the cost was lethal, "ok" otherwise.
function EventService:_applyHealthCost(player: Player, fraction: number): string
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return "dead"
	end

	local cost = math.round(humanoid.MaxHealth * fraction)
	if humanoid.Health - cost < 1 then
		humanoid.Health = 1
		if LifeService then
			LifeService:LoseLife(player)
		end
		return "dead"
	end

	humanoid.Health -= cost
	return "ok"
end

-- Validates one client request against the wiring registry: the model
-- must be one we blessed, of the expected kind, and the player must be
-- physically near it.
function EventService:_validate(player: Player, model: Instance?, kind: string): boolean
	if typeof(model) ~= "Instance" then
		return false
	end
	local entry = self._eventModels[model]
	if not entry or entry.kind ~= kind then
		return false
	end

	local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	local anchor = model:IsA("Model") and model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
	if not hrp or not anchor then
		return false
	end
	return (hrp.Position - anchor.Position).Magnitude <= INTERACT_RANGE
end

-- Uniformly random unowned relic names of `rarity` (no weights).
-- `ignoreGates` skips the C/C2 usability filter — the Cursed Shrine
-- deals whatever fate it likes (all Cursed are NC today, so this is
-- future-proofing more than behavior); the Sword's payout stays
-- usable-only.
function EventService:_rollUsableRelics(
	player: Player,
	rarity: string,
	count: number,
	ignoreGates: boolean?
): { string }
	local granted = if ignoreGates then nil else RelicService:GetGrantedMechanics(player)
	local candidates = {}
	for relicName, data in RelicData do
		if
			data.rarity == rarity
			and RelicService:GetSpecificRelicRegistry(player, relicName) == 0
			and (ignoreGates or RelicService:IsRelicRollEligible(relicName, granted :: any, player))
		then
			table.insert(candidates, relicName)
		end
	end
	for index = #candidates, 2, -1 do
		local swap = math.random(1, index)
		candidates[index], candidates[swap] = candidates[swap], candidates[index]
	end
	local picked = {}
	for index = 1, math.min(count, #candidates) do
		picked[index] = candidates[index]
	end
	return picked
end

-- Spawns `relicNames` as owner-locked physical drops fanned in front of
-- `sourceModel`. Claim-one comes free: collecting any of a player's
-- offers despawns the rest (Relic component rule).
-- `inFront` mirrors the fan onto the model's LOOKVECTOR side. DROP_OFFSETS
-- are authored on +Z, and Roblox faces —Z, so the default fan lands
-- BEHIND the source — which is invisible on the Sword and the Shrine
-- (static props whose facing is arbitrary) but wrong on the Forge, whose
-- Mechaforger is a character the player is standing in front of.
-- `staggerSeconds` pops the fan one relic at a time, RIGHT TO LEFT,
-- instead of all at once — a three-relic payout reads as the source
-- dealing them out rather than one pile appearing. Nil / 0 keeps the
-- simultaneous fan.
function EventService:_spawnRelicFan(
	player: Player,
	sourceModel: Model,
	relicNames: { string },
	inFront: boolean?,
	staggerSeconds: number?
)
	local primary = sourceModel.PrimaryPart or sourceModel:FindFirstChildWhichIsA("BasePart", true)
	if not primary or not DropService then
		return
	end
	local origin = primary.Position

	-- TargetPosition is a FLOOR-LEVEL contract (the vending machine
	-- drops at its base; the client bob adds the hover). The offsets
	-- above are relative to the interactable's PrimaryPart, which sits
	-- well OFF the floor — the sword atop its stone, the shrine on its
	-- mound — so each target is rayed down to the actual ground.
	-- Characters and the drop/spell folders are excluded so a player
	-- standing in the fan doesn't catch a relic on their head.
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	local excluded: { Instance } = { sourceModel }
	local ignoreFolder = workspace:FindFirstChild("IgnoreInstances")
	if ignoreFolder then
		table.insert(excluded, ignoreFolder)
	end
	for _, other in game:GetService("Players"):GetPlayers() do
		if other.Character then
			table.insert(excluded, other.Character)
		end
	end
	rayParams.FilterDescendantsInstances = excluded

	-- Resolve every landing spot BEFORE anything is fired. A staggered fan
	-- yields between drops, and resolving inside that loop would let the
	-- world move (a gate opening, a player walking through) between one
	-- relic's ray and the next — the fan's shape has to be decided in a
	-- single frame even when it is dealt out over several.
	local slotOrder = DROP_SLOT_ORDER[#relicNames]
	local drops = {}
	for index, relicName in relicNames do
		local slot = if slotOrder then slotOrder[index] else ((index - 1) % #DROP_OFFSETS) + 1
		local offset = DROP_OFFSETS[slot]
		if inFront then
			offset = Vector3.new(offset.X, offset.Y, -offset.Z)
		end
		local target = (primary.CFrame * CFrame.new(offset)).Position
		local hit = workspace:Raycast(
			target + Vector3.new(0, DROP_GROUND_RAY_UP, 0),
			Vector3.new(0, -DROP_GROUND_RAY_DOWN, 0),
			rayParams
		)
		if hit then
			target = hit.Position
		end
		table.insert(drops, { relicName = relicName, target = target, slot = slot })
	end

	local function fire(drop)
		-- One Pop PER RELIC, matching the machine's cadence: it plays the
		-- same sting once for every relic it dispenses, so a staggered fan
		-- of three pops three times rather than once.
		playDropPop(primary)
		DropService.OnRelicDropRequested:Fire(
			player,
			RelicData[drop.relicName].rarity,
			drop.relicName,
			origin,
			drop.target
		)
	end

	if not staggerSeconds or staggerSeconds <= 0 then
		for _, drop in drops do
			fire(drop)
		end
		return
	end

	-- RIGHT TO LEFT. DROP_OFFSETS run left (slot 1) → centre (2) →
	-- right (3), so descending slot order deals from the right of the fan
	-- inward. Spawned so the caller (a dialogue-close handler) is not held
	-- for the length of the deal.
	table.sort(drops, function(a, b)
		return a.slot > b.slot
	end)
	task.spawn(function()
		for index, drop in drops do
			if index > 1 then
				task.wait(staggerSeconds)
			end
			fire(drop)
		end
	end)
end

-- Runtime wiring for one generated dungeon: every Event room's
-- interactable gets its NPC tag + DialogueGraph, and lands in the
-- validation registry. Prefab NAME is the event identity.
function EventService:_wireDungeon(dungeon)
	local wired = 0
	for _, room in dungeon.roomsById do
		if room.roomType ~= RoomTypes.Event or not room.model then
			continue
		end

		-- Placed rooms are RENAMED (Room_<id>_Event), so the prefab
		-- identity rides the PrefabName attribute DungeonService stamps at
		-- placement. The raw name is only a fallback for hand-placed rooms.
		local eventKind = room.model:GetAttribute("PrefabName") or room.model.Name
		local interactablesFolder = room.model:FindFirstChild("Interactables")

		if eventKind == "SwordStone" then
			local sword = interactablesFolder and interactablesFolder:FindFirstChildWhichIsA("Model")
			if sword then
				sword:SetAttribute("DialogueGraph", "SwordStone")
				CollectionService:AddTag(sword, TagList.NPC)
				self._eventModels[sword] = { kind = "SwordStone", room = room }
				wired += 1
			else
				warn("[EventService] SwordStone room has no Interactables model — event not wired")
			end
		elseif eventKind == "CursedShrine" then
			local shrine = interactablesFolder and interactablesFolder:FindFirstChildWhichIsA("Model")
			if shrine then
				shrine:SetAttribute("DialogueGraph", "CursedShrine")
				CollectionService:AddTag(shrine, TagList.NPC)
				self._eventModels[shrine] = { kind = "CursedShrine", room = room }
				wired += 1
			else
				warn("[EventService] CursedShrine room has no Interactables model — event not wired")
			end
		elseif eventKind == "HealingFountain" then
			-- Accepts the singular folder name too — the fountain prefab
			-- was authored with "Interactable" before the convention
			-- settled on "Interactables".
			local folder = interactablesFolder or room.model:FindFirstChild("Interactable")
			local fountain = folder and folder:FindFirstChildWhichIsA("Model")
			if fountain then
				fountain:SetAttribute("DialogueGraph", "HealingFountain")
				CollectionService:AddTag(fountain, TagList.NPC)
				self._eventModels[fountain] = { kind = "HealingFountain", room = room }
				wired += 1
			else
				warn("[EventService] HealingFountain room has no Interactables model — event not wired")
			end
		elseif eventKind == "CoffinEvent" then
			-- The Laughing Coffin: a prop under Interactables, like the
			-- shrine. CoffinEventService runs the challenge itself; this only
			-- makes the coffin a dialogue target and a validated event model.
			local coffin = interactablesFolder and interactablesFolder:FindFirstChildWhichIsA("Model")
			if coffin then
				coffin:SetAttribute("DialogueGraph", "CoffinEvent")
				CollectionService:AddTag(coffin, TagList.NPC)
				self._eventModels[coffin] = { kind = "CoffinEvent", room = room }
				if CoffinEventService then
					CoffinEventService:RegisterRoom(room, coffin)
				end
				wired += 1
			else
				warn("[EventService] CoffinEvent room has no Interactables model — coffin not wired")
			end
		elseif eventKind == "Forge" then
			-- The Mechaforger lives under NPCs (merchant-shaped prefab), not
			-- Interactables — it is a character, not a prop.
			local npcFolder = room.model:FindFirstChild("NPCs")
			local forge = npcFolder and npcFolder:FindFirstChildWhichIsA("Model")
			if forge then
				forge:SetAttribute("DialogueGraph", "Forge")
				CollectionService:AddTag(forge, TagList.NPC)
				self._eventModels[forge] = { kind = "Forge", room = room }
				wired += 1
			else
				warn("[EventService] Forge room has no NPCs model — blacksmith not wired")
			end
		elseif eventKind == "MerchantShop" then
			local npcFolder = room.model:FindFirstChild("NPCs")
			local merchant = npcFolder and npcFolder:FindFirstChildWhichIsA("Model")
			if merchant then
				merchant:SetAttribute("DialogueGraph", "SpiresMerchant")
				CollectionService:AddTag(merchant, TagList.NPC)
				self._eventModels[merchant] = { kind = "MerchantShop", room = room }
				wired += 1
			else
				warn("[EventService] MerchantShop room has no NPCs model — merchant not wired")
			end
			-- Stalls are a GENERATION product: capture each pedestal's world
			-- CFrame (attachment if authored, else above the part) HERE, on
			-- the server, where streaming can't hide anything. The tag still
			-- goes on for the client's PROMPT wiring; the display no longer
			-- waits on it. Stock itself stays lazy per player (cached roll).
			local slotCFrames = {}
			if interactablesFolder then
				for _, pedestal in interactablesFolder:GetChildren() do
					local slotIndex = tonumber(string.match(pedestal.Name, "%d+$"))
					if slotIndex and (pedestal:IsA("Model") or pedestal:IsA("BasePart")) then
						CollectionService:AddTag(pedestal, TagList.MerchantPedestal)
						local attachment = pedestal:FindFirstChildWhichIsA("Attachment", true)
						if attachment then
							slotCFrames[slotIndex] = attachment.WorldCFrame
						elseif pedestal:IsA("BasePart") then
							slotCFrames[slotIndex] = pedestal.CFrame * CFrame.new(0, 3, 0)
						else
							slotCFrames[slotIndex] = pedestal:GetPivot() * CFrame.new(0, 3, 0)
						end
					end
				end
			end
			self._merchantRooms[room.id] = {
				merchant = merchant,
				room = room,
				slotCFrames = slotCFrames,
			}
		end
	end
	-- Loud on purpose: if this reads 0 on a floor that placed Event
	-- rooms, the wiring is what broke — check the prefab structure
	-- (Interactables / NPCs folders) against the warns above.
	-- The Greater Shrine lives in the START chunk, not an Event room, so
	-- the loop above never sees it. Wired by PRESENCE: a Start chunk that
	-- holds a PrayingStatue gets the event; the first floor's simply does
	-- not have one. No room entry -- the Start area has no event door to
	-- open, and nothing that reads _eventModels iterates it.
	local startModel = dungeon.startModel
	local startInteractables = startModel and startModel:FindFirstChild("Interactables")
	local statue = startInteractables and startInteractables:FindFirstChild("Blessing Shrine")
	if statue and statue:IsA("Model") then
		-- The dialogue billboard adorns the PrimaryPart; without one the
		-- client falls back to an arbitrary part and warns. Say so here
		-- too, on the server, where a prefab problem is easier to spot.
		if not statue.PrimaryPart then
			warn("[EventService] PrayingStatue has no PrimaryPart; set one so the dialogue box sits on the statue")
		end
		statue:SetAttribute("DialogueGraph", "GreaterShrine")
		CollectionService:AddTag(statue, TagList.NPC)
		self._eventModels[statue] = { kind = "GreaterShrine", room = nil }
		wired += 1
	end

	print(("[EventService] Wired %d event interactable(s) this floor"):format(wired))
end

-- DungeonService polls this during the event exit-door hold.
function EventService:GetEventInteractions(roomId: number): { [number]: boolean }
	return self._interactions[roomId] or {}
end

-- Server-side mark (CoffinEventService's decline): the same registry the
-- client method writes, without the proximity check — the caller has
-- already validated the request against its own model.
function EventService:MarkInteracted(player: Player, roomId: number)
	self._interactions[roomId] = self._interactions[roomId] or {}
	self._interactions[roomId][player.UserId] = true
end

-- "<Name> wishes to continue." to the whole party — the Merchant's leave
-- option and the Coffin's decline both announce it, so nobody waits on
-- a teammate who has already voted with their feet.
function EventService:NotifyWishesToContinue(player: Player)
	if not UserNotificationService then
		return
	end
	UserNotificationService:RequestAllNotification({
		titleText = "Skip Event Requested",
		titleTextFont = Enum.Font.SourceSansBold,
		titleTextColor3 = Color3.fromRGB(174, 95, 252),
		titleTextTransparency = 0,

		text = ("%s voted to skip."):format(player.Name),
		textFont = Enum.Font.SourceSansBold,
		textColor3 = Color3.fromRGB(255, 255, 255),
		textTransparency = 0,
	})
end

--[ Client API ]--

-- The client reports "this player is done with this event" — a
-- finished Sword/Shrine conversation, or the Merchant's ready option.
-- Registry + proximity validated; the worst a spoof achieves is
-- removing the SPOOFER's own contribution to the party's wait.
function EventService.Client:MarkEventInteracted(player: Player, model: Instance)
	if typeof(model) ~= "Instance" then
		return
	end
	local entry = EventService._eventModels[model]
	if not entry or not EventService:_validate(player, model, entry.kind) then
		return
	end
	local roomId = entry.room.id
	EventService._interactions[roomId] = EventService._interactions[roomId] or {}
	EventService._interactions[roomId][player.UserId] = true

	-- The Merchant's "I want to leave" is an explicit vote — tell the party.
	if entry.kind == "MerchantShop" then
		EventService:NotifyWishesToContinue(player)
	end

	-- A WON sword pull or an accepted shrine bargain queued its relic
	-- fan for this moment — the conversation is over, pop the rewards.
	local pending = EventService._pendingRelicFans[player.UserId]
	if pending and pending.model == model then
		EventService._pendingRelicFans[player.UserId] = nil
		EventService:_spawnRelicFan(player, pending.model, pending.relics, pending.inFront, pending.stagger)
	end
end

-- One pull attempt. Pays the health cost FIRST (it can kill — the stone
-- takes its price either way), then rolls. Returns:
--   "success" — relic fan QUEUED (pops when the conversation ends),
--               event done for this player
--   "fail"    — cost paid, sword didn't budge
--   "dead"    — the cost was lethal
--   "done"    — this player already pulled it out
--   "invalid" — bad model / too far / unknown
function EventService.Client:AttemptSwordPull(player: Player, swordModel: Instance): string
	if not EventService:_validate(player, swordModel, "SwordStone") then
		return "invalid"
	end

	local done = EventService._swordDone[player.UserId]
	if done and done[swordModel] then
		return "done"
	end

	if EventService:_applyHealthCost(player, SWORD_PULL_HEALTH_FRACTION) == "dead" then
		return "dead"
	end

	if math.random() > SWORD_PULL_SUCCESS_CHANCE then
		return "fail"
	end

	EventService._swordDone[player.UserId] = EventService._swordDone[player.UserId] or {}
	EventService._swordDone[player.UserId][swordModel] = true

	-- ONE random usable Legendary — the card's promise ("The blade rewards
	-- you with a Legendary Relic"). Replaced the old one-of-each-rarity
	-- fan; still usability-gated, so a C2 tree Legendary only appears for
	-- a player who can actually use it (the Neutral Legendaries are always
	-- eligible while unowned).
	local rewards = EventService:_rollUsableRelics(player, ItemRarity.Legendary, 1)
	-- Deferred to dialogue close — MarkEventInteracted releases it. The
	-- roll and the health cost stay HERE because the dialogue branches
	-- on this function's return value mid-conversation.
	EventService._pendingRelicFans[player.UserId] = { model = swordModel :: Model, relics = rewards }
	return "success"
end

-- The Shrine's bargain. The cost is NEVER lethal — 50% of MaxHealth,
-- floored at 1 HP, no life lost — then SHRINE_CURSE_COUNT distinct
-- unowned Cursed relics fan out, claim-one. Called mid-dialogue from
-- the "Bargain is struck" node: the COST lands under the billboard;
-- the FAN is queued and released by MarkEventInteracted at close.
-- Returns "struck" | "done" | "invalid".
function EventService.Client:AcceptCurse(player: Player, shrineModel: Instance): string
	if not EventService:_validate(player, shrineModel, "CursedShrine") then
		return "invalid"
	end

	local done = EventService._shrineDone[player.UserId]
	if done and done[shrineModel] then
		return "done"
	end
	EventService._shrineDone[player.UserId] = EventService._shrineDone[player.UserId] or {}
	EventService._shrineDone[player.UserId][shrineModel] = true

	-- Non-lethal by contract ("only deal 50% hp"): raw like every event
	-- cost, but clamped to leave 1 HP and never routed through
	-- LifeService. _applyHealthCost stays the Sword's lethal variant.
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health > 0 then
		local cost = math.round(humanoid.MaxHealth * SHRINE_HEALTH_FRACTION)
		humanoid.Health = math.max(humanoid.Health - cost, 1)
	end

	-- Completely random among unowned Cursed relics — no usability gate,
	-- matching the merchant's anything-goes rule.
	local curses = EventService:_rollUsableRelics(player, ItemRarity.Cursed, SHRINE_CURSE_COUNT, true)
	-- DEFERRED: the cost just landed; the fan pops at conversation end.
	EventService._pendingRelicFans[player.UserId] =
		{ model = shrineModel :: Model, relics = curses, stagger = DROP_STAGGER_SECONDS }

	return "struck"
end

-- Whether this player has already taken the fountain's gift. The graph's
-- first node fetches it (yielding PreAction, same beat the sword's pull
-- lands on) so the conversation can route to the "waters lie still" line
-- instead of re-offering a spent choice.
function EventService.Client:IsFountainSpent(player: Player, fountainModel: Instance): boolean
	if typeof(fountainModel) ~= "Instance" then
		return true
	end
	local entry = EventService._eventModels[fountainModel]
	if not entry or entry.kind ~= "HealingFountain" then
		return true
	end
	local done = EventService._fountainDone[player.UserId]
	return done ~= nil and done[fountainModel] == true
end

-- Drink: restore FOUNTAIN_HEAL_FRACTION of Maximum Health through the
-- central heal path (Holiday Ham applies). Spends the fountain for this
-- player. Returns "ok" | "done" | "invalid".
function EventService.Client:DrinkFromFountain(player: Player, fountainModel: Instance): string
	if not EventService:_validate(player, fountainModel, "HealingFountain") then
		return "invalid"
	end

	local done = EventService._fountainDone[player.UserId]
	if done and done[fountainModel] then
		return "done"
	end
	EventService._fountainDone[player.UserId] = EventService._fountainDone[player.UserId] or {}
	EventService._fountainDone[player.UserId][fountainModel] = true

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health > 0 then
		PlayerStatsService:ApplyHealing(player, humanoid.MaxHealth * FOUNTAIN_HEAL_FRACTION)
	end
	return "ok"
end

-- Attune: FOUNTAIN_ATTUNE_HP_FRACTION more Maximum Health for the rest of
-- the run, joining the relic/rune additive pool (PlayerStatsService).
-- RecomputeHealth's carry-up grants the new headroom as flesh too. Spends
-- the fountain for this player. Returns "ok" | "done" | "invalid".
function EventService.Client:AttuneToFountain(player: Player, fountainModel: Instance): string
	if not EventService:_validate(player, fountainModel, "HealingFountain") then
		return "invalid"
	end

	local done = EventService._fountainDone[player.UserId]
	if done and done[fountainModel] then
		return "done"
	end
	EventService._fountainDone[player.UserId] = EventService._fountainDone[player.UserId] or {}
	EventService._fountainDone[player.UserId][fountainModel] = true

	PlayerStatsService:AddFountainHealthPercent(player, FOUNTAIN_ATTUNE_HP_FRACTION)
	return "ok"
end

-- Whether this player already took a Greater Blessing from this statue.
-- Fetched by the graph's opening node (yielding PreAction) so the
-- conversation can route to the spent line instead of re-offering.
function EventService.Client:IsGreaterShrineSpent(player: Player, statueModel: Instance): boolean
	if typeof(statueModel) ~= "Instance" then
		return true
	end
	local entry = EventService._eventModels[statueModel]
	if not entry or entry.kind ~= "GreaterShrine" then
		return true
	end
	local done = EventService._greaterShrineDone[player.UserId]
	return done ~= nil and done[statueModel] == true
end

-- The blessings this player can still be offered: the pool minus what
-- they have already taken this RUN.
local function availableBlessings(taken: { [string]: boolean }?): { any }
	local available = {}
	for _, blessing in GreaterShrineData.Blessings do
		if not (taken and taken[blessing.id]) then
			table.insert(available, blessing)
		end
	end
	return available
end

-- This player's offer at this statue: OfferCount blessings drawn from
-- what is left. Rolled ONCE and remembered -- a player who walks out
-- and comes back gets the same three, so the shrine cannot be
-- re-rolled by leaving. Returns ids in pool order (the dialogue's rows
-- are authored in that order too, so the menu reads consistently).
function EventService.Client:GetGreaterShrineOffer(player: Player, statueModel: Instance): { string }
	if typeof(statueModel) ~= "Instance" then
		return {}
	end
	local entry = EventService._eventModels[statueModel]
	if not entry or entry.kind ~= "GreaterShrine" then
		return {}
	end

	local offers = EventService._greaterShrineOffers[player.UserId]
	if offers and offers[statueModel] then
		return offers[statueModel]
	end

	local available = availableBlessings(EventService._greaterShrineTaken[player.UserId])
	-- Fisher-Yates over indices, then take the first OfferCount and put
	-- them back into pool order.
	local picked = {}
	for index = #available, 2, -1 do
		local j = math.random(1, index)
		available[index], available[j] = available[j], available[index]
	end
	for index = 1, math.min(GreaterShrineData.OfferCount, #available) do
		picked[available[index].id] = true
	end

	local offer = {}
	for _, blessing in GreaterShrineData.Blessings do
		if picked[blessing.id] then
			table.insert(offer, blessing.id)
		end
	end

	EventService._greaterShrineOffers[player.UserId] = EventService._greaterShrineOffers[player.UserId] or {}
	EventService._greaterShrineOffers[player.UserId][statueModel] = offer
	return offer
end

-- Take a blessing: spends the statue for this player, grants the stat
-- immediately, and marks their Healing Orbs owed (the close path drops
-- them once the bars are down). Returns "ok" | "done" | "invalid".
function EventService.Client:ChooseGreaterBlessing(player: Player, statueModel: Instance, blessing: string): string
	if not EventService:_validate(player, statueModel, "GreaterShrine") then
		return "invalid"
	end
	local config = GreaterShrineData.ByID[blessing]
	if not config then
		return "invalid"
	end

	-- Must be one of the three THIS player was offered here. The client
	-- picks a row, but the row it picked is not evidence -- without this
	-- any blessing could be claimed at any statue.
	local offers = EventService._greaterShrineOffers[player.UserId]
	local offer = offers and offers[statueModel]
	local offered = false
	for _, id in offer or {} do
		if id == blessing then
			offered = true
			break
		end
	end
	if not offered then
		return "invalid"
	end

	-- Already taken this run: the pool should have excluded it, so this
	-- only fires on a stale offer or a forged call.
	local taken = EventService._greaterShrineTaken[player.UserId]
	if taken and taken[blessing] then
		return "done"
	end

	local done = EventService._greaterShrineDone[player.UserId]
	if done and done[statueModel] then
		return "done"
	end
	EventService._greaterShrineDone[player.UserId] = EventService._greaterShrineDone[player.UserId] or {}
	EventService._greaterShrineDone[player.UserId][statueModel] = true
	EventService._greaterShrinePending[player.UserId] = EventService._greaterShrinePending[player.UserId] or {}
	EventService._greaterShrinePending[player.UserId][statueModel] = true

	EventService._greaterShrineTaken[player.UserId] = EventService._greaterShrineTaken[player.UserId] or {}
	EventService._greaterShrineTaken[player.UserId][blessing] = true

	PlayerStatsService:AddGreaterShrineEffect(player, config.effect, config.amount)

	-- Tell the player what they took. `response` is the dialogue row's
	-- HyperText ("Spirit <color=...>(+%d%% Max HP)</color>"); the
	-- notification is plain text, so the tags are stripped.
	if UserNotificationService then
		local line = (config.response or blessing):format(math.round(config.amount * 100))
		line = line:gsub("<color=[^>]*>", ""):gsub("</color>", "")
		UserNotificationService:RequestUserNotification(player, {
			titleText = "Greater Blessing",
			titleTextFont = Enum.Font.SourceSansBold,
			titleTextColor3 = Color3.fromRGB(174, 95, 252),
			titleTextTransparency = 0,

			text = line,
			textFont = Enum.Font.SourceSansBold,
			textColor3 = Color3.fromRGB(255, 255, 255),
			textTransparency = 0,
		})
	end
	return "ok"
end

-- This player's share of the Healing Orbs, dropped by the close path
-- once the conversation has fully ended. Free-for-all (no owner), at
-- the statue's base, through the ordinary Health drop -- 5% each via
-- DropService. Once: the pending entry is consumed.
-- Returns "ok" | "none" | "invalid".
function EventService.Client:DropGreaterShrineOrbs(player: Player, statueModel: Instance): string
	if typeof(statueModel) ~= "Instance" then
		return "invalid"
	end
	local entry = EventService._eventModels[statueModel]
	if not entry or entry.kind ~= "GreaterShrine" then
		return "invalid"
	end
	local pending = EventService._greaterShrinePending[player.UserId]
	if not pending or not pending[statueModel] then
		return "none"
	end
	pending[statueModel] = nil

	local anchor = if statueModel:IsA("Model")
		then (statueModel.PrimaryPart or statueModel:FindFirstChildWhichIsA("BasePart", true))
		else nil
	if not anchor or not DropService then
		return "invalid"
	end

	local partySize = math.max(1, #Players:GetPlayers())
	local orbs = math.max(1, math.floor(GreaterShrineData.OrbTotal / partySize))
	-- (basePart, dropType, minCount, maxCount, minValue, maxValue,
	-- isBoss, ownerId) -- no owner: anyone may collect. The same count of
	-- EACH kind, so OrbTotal describes one type, not the sum.
	DropService.OnDropRequested:Fire(anchor, DropTypes.Health, orbs, orbs, 1, 1, false)
	DropService.OnDropRequested:Fire(anchor, DropTypes.Mana, orbs, orbs, 1, 1, false)
	return "ok"
end

-- THE FORGE. Sacrifice one owned relic and the anvil fans out
-- FORGE_OFFER_COUNT distinct relics of the SAME RARITY, claim-one (the
-- Relic component's rule — taking any one despawns the rest).
--
-- Every offer rolls through the ordinary vending pipeline
-- (RollRandomRelicFromPool with the rarity forced), so each inherits
-- every rule an offer already obeys: combo gates are respected (the
-- Forge can never hand back something unusable), ELEMENT AFFINITY
-- applies, and deeper C / C2 relics weigh more. The fan therefore leans
-- toward the trees the player is actually building rather than the whole
-- pool — which, with three of them to choose between, is what turns
-- the anvil from a slot machine into a decision.
--
-- ORDER MATTERS: the old relic is removed BEFORE the roll, so a relic
-- whose `grants` were the player's only source of a status stops
-- unlocking that tree's gated relics for this roll — you cannot forge
-- away your Burn enabler and be handed a Burn-gated payoff. The
-- sacrificed relic is then excluded explicitly, since being unowned
-- would otherwise make it a legal result (reforging into itself).
--
-- One reforge per player per Forge, and the REWARD is deferred: the
-- fan pops from the blacksmith when the conversation ends, the same
-- beat the Sword's payout lands on (_pendingRelicFans).
-- Returns "reforged" | "none" | "done" | "invalid".
function EventService.Client:ReforgeRelic(player: Player, forgeModel: Instance, relicName: string): string
	if not EventService:_validate(player, forgeModel, "Forge") then
		return "invalid"
	end
	if typeof(relicName) ~= "string" or not RelicData[relicName] then
		return "invalid"
	end
	if RelicService:GetSpecificRelicRegistry(player, relicName) <= 0 then
		return "invalid"
	end

	local done = EventService._forgeDone[player.UserId]
	if done and done[forgeModel] then
		return "done"
	end

	local rarity = RelicData[relicName].rarity

	-- Sacrifice first (see the ordering note above), with the same
	-- everyone-visible shockwave a Destroy or a sale plays.
	RelicService:RemoveRelicsRegistry(player, relicName, 1)
	RelicService:PlayRelicRemovedFX(player)

	local candidates = {}
	for candidateName, data in RelicData do
		if
			data.rarity == rarity
			and candidateName ~= relicName
			and RelicService:GetSpecificRelicRegistry(player, candidateName) == 0
		then
			table.insert(candidates, candidateName)
		end
	end

	-- Weights forced to the ONE rarity: RollRandomRelicFromPool's
	-- explicit-weights path skips its own rarity roll but keeps the
	-- eligibility filter and the combo / affinity weighting.
	--
	-- Rolled one at a time, dropping each winner from the pool, so the fan
	-- is DISTINCT relics and every draw re-weights against what is left. A
	-- thin bucket simply yields fewer than FORGE_OFFER_COUNT rather than
	-- failing — one offer is still a reforge.
	local offers = {}
	for _ = 1, FORGE_OFFER_COUNT do
		local rolled = RelicService:RollRandomRelicFromPool(candidates, { [rarity] = 1 }, nil, player)
		if not rolled then
			break
		end
		table.insert(offers, rolled)
		local index = table.find(candidates, rolled)
		if index then
			table.remove(candidates, index)
		end
	end

	if #offers == 0 then
		-- Nothing usable left at that rarity. The relic is still spent —
		-- the graph's own line covers it, and latching keeps the player
		-- from grinding the anvil for a bucket that cannot fill.
		EventService._forgeDone[player.UserId] = EventService._forgeDone[player.UserId] or {}
		EventService._forgeDone[player.UserId][forgeModel] = true
		return "none"
	end

	EventService._forgeDone[player.UserId] = EventService._forgeDone[player.UserId] or {}
	EventService._forgeDone[player.UserId][forgeModel] = true

	-- DEFERRED: pops from the blacksmith once the dialogue closes.
	-- inFront: the blacksmith faces the player, so its reward has to land
	-- on the anvil side rather than in the wall behind it.
	EventService._pendingRelicFans[player.UserId] =
		{ model = forgeModel :: Model, relics = offers, inFront = true, stagger = DROP_STAGGER_SECONDS }
	return "reforged"
end

-- This player's stock for one merchant ROOM: { { relicName, price, sold } }.
-- Rolled once on first request and cached. The first request only
-- happens after the room UNLOCKS for THIS player (they entered it), so the
-- unowned filter sees FINAL ownership — every pick from the fight
-- before the shop has already landed by then.
-- Keyed by roomId, not the merchant Instance:
-- rooms are the stable identity; models come and go with streaming.
function EventService:_stockForRoom(player: Player, roomId: number): { any }
	local byPlayer = self._merchantStock[player.UserId]
	if not byPlayer then
		byPlayer = {}
		self._merchantStock[player.UserId] = byPlayer
	end
	if byPlayer[roomId] then
		return byPlayer[roomId]
	end

	-- Distinct and unowned, NO combo gating: the merchant sells C and C2
	-- relics the player cannot use YET (design call — a shop can sell
	-- you ambition; vending machines are where usability is enforced).
	-- Bucketed by rarity with each bucket shuffled, so a slot "rolls a
	-- rarity, then takes the next unowned relic of it".
	local byRarity: { [string]: { string } } = {}
	for relicName, data in RelicData do
		if BUY_PRICE_RANGES[data.rarity] and RelicService:GetSpecificRelicRegistry(player, relicName) == 0 then
			local bucket = byRarity[data.rarity]
			if not bucket then
				bucket = {}
				byRarity[data.rarity] = bucket
			end
			table.insert(bucket, relicName)
		end
	end
	for _, bucket in byRarity do
		for index = #bucket, 2, -1 do
			local swap = math.random(1, index)
			bucket[index], bucket[swap] = bucket[swap], bucket[index]
		end
	end

	local stock = {}
	local function stockOne(rarity: string): boolean
		local bucket = byRarity[rarity]
		local relicName = bucket and table.remove(bucket)
		if not relicName then
			return false
		end
		local range = BUY_PRICE_RANGES[rarity]
		table.insert(stock, {
			relicName = relicName,
			price = math.random(range[1], range[2]),
			sold = false,
		})
		return true
	end

	-- Slot 1: ONE Legendary, guaranteed while any unowned one exists.
	stockOne(ItemRarity.Legendary)

	-- The rest roll their rarity off the run-stage table the vending
	-- machines use (RelicRollConfig.RarityWeights — Legendary is 1-3%
	-- per slot), so a SECOND Legendary is rare and a third rarer still.
	-- Only rarities with stock left are weighed: an exhausted bucket hands
	-- its slots to the others instead of leaving a hole.
	local stageWeights = RelicRollConfig.RarityWeights[RelicService:GetRunStage()]
		or RelicRollConfig.RarityWeights.Early
	while #stock < MERCHANT_STOCK_SIZE do
		local available = {}
		local anyLeft = false
		for rarity, weight in stageWeights do
			if byRarity[rarity] and #byRarity[rarity] > 0 then
				available[rarity] = weight
				anyLeft = true
			end
		end
		if not anyLeft or not stockOne(rollItemRarity(available, ItemRarity.Rare)) then
			break
		end
	end

	-- Shuffled so the guaranteed Legendary is not always the first card.
	for index = #stock, 2, -1 do
		local swap = math.random(1, index)
		stock[index], stock[swap] = stock[swap], stock[index]
	end
	byPlayer[roomId] = stock
	return stock
end

-- A room STARTED (combat wave spawned / encounter intro began): every
-- merchant room in the NEXT segment unlocks — its stock becomes
-- rollable + servable, and clients are told to fetch.
-- Unlocks a shop the moment a player first ENTERS it. That is the latest
-- possible point, and the only one that closes the duplicate window:
-- the shelves roll lazily on the client's first request, which comes
-- the instant the unlock fires. Unlocking when the fight BEFORE the
-- shop started (the old rule) rolled the shelves before anyone had
-- picked from that fight's vending machine, so the relic you then
-- chose could already be on sale. Unlocking on the segment CLEAR would
-- not fix it either — the machines drop on that very signal and the
-- pick happens during the gate wait after it. Entry is past the gate,
-- which only opens once every alive player has picked (or the wait
-- expires), so ownership is final by the time the roll happens.
--
-- PER PLAYER, not per room. A room-wide unlock rolled a teammate's
-- shelves the moment the FIRST player walked in — while that teammate
-- could still be at the vending machine, so their own pick could land
-- after their roll and show up for sale. Each player unlocks a shop by
-- entering it THEMSELVES, and only their client is told.
function EventService:_isMerchantUnlockedFor(player: Player, roomId: number): boolean
	local byPlayer = self._merchantUnlocked[player.UserId]
	return byPlayer ~= nil and byPlayer[roomId] == true
end

function EventService:_unlockMerchantRoom(player: Player, room)
	if not player or not room or room.id == nil then
		return
	end
	if not self._merchantRooms[room.id] or self:_isMerchantUnlockedFor(player, room.id) then
		return
	end
	local byPlayer = self._merchantUnlocked[player.UserId]
	if not byPlayer then
		byPlayer = {}
		self._merchantUnlocked[player.UserId] = byPlayer
	end
	byPlayer[room.id] = true
	self.Client.OnMerchantStockUnlocked:Fire(player, room.id)
end

-- Everything a client needs to dress every SERVABLE merchant room, in
-- one call: per-room slots with relic, price, sold flag and the WORLD
-- CFrame captured at generation. No range gate and no streaming
-- dependence — but rooms THIS player has not entered yet are withheld
-- entirely; OnMerchantStockUnlocked tells their client when to come back.
function EventService.Client:GetMerchantStalls(player: Player): { any }
	local stalls = {}
	for roomId, entry in EventService._merchantRooms do
		if not EventService:_isMerchantUnlockedFor(player, roomId) then
			continue
		end
		local stock = EventService:_stockForRoom(player, roomId)
		local slots = {}
		for index, slot in stock do
			slots[index] = {
				relicName = slot.relicName,
				price = slot.price,
				sold = slot.sold,
				cframe = entry.slotCFrames[index],
			}
		end
		-- roomModel rides along so the client can gate rendering on the
		-- room's FogRevealed attribute — floating relics inside an
		-- unrevealed shop would announce the shop through its doorway.
		table.insert(stalls, { roomId = roomId, slots = slots, roomModel = entry.room.model })
	end
	return stalls
end

-- Buys stock slot `index` of merchant room `roomId`. Grants the relic
-- DIRECTLY (no physical drop) and empties the pedestal for this player
-- only. Returns "bought" | "poor" | "sold" | "invalid".
function EventService.Client:BuyMerchantRelic(player: Player, roomId: number, index: number): string
	if typeof(roomId) ~= "number" or typeof(index) ~= "number" then
		return "invalid"
	end
	local entry = EventService._merchantRooms[roomId]
	if not entry or not EventService:_isMerchantUnlockedFor(player, roomId) then
		return "invalid"
	end
	-- Range-gated against the PEDESTAL being bought from — stalls serve
	-- floor-wide at generation, so the buy is where physical presence
	-- gets enforced.
	local slotCFrame = entry.slotCFrames[index]
	local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if not slotCFrame or not hrp or (hrp.Position - slotCFrame.Position).Magnitude > INTERACT_RANGE then
		return "invalid"
	end
	local slot = EventService:_stockForRoom(player, roomId)[index]
	if not slot then
		return "invalid"
	end
	if slot.sold then
		return "sold"
	end
	if RelicService:GetSpecificRelicRegistry(player, slot.relicName) > 0 then
		-- Acquired elsewhere AFTER the shelves rolled (the shop room's
		-- own window — e.g. a vending pull moments earlier). The stand
		-- empties unpaid, WITH feedback instead of a silent vanish.
		slot.sold = true
		if TextIndicatorService and hrp then
			TextIndicatorService:ShowIndicator(player, hrp, "Already owned", NOT_ENOUGH_COINS_COLOR, true)
		end
		return "sold"
	end

	if not RunEscrowService:SpendCoins(player, slot.price) then
		-- Server-side feedback so the "Not enough coins" pop can't be
		-- suppressed or spoofed client-side.
		if TextIndicatorService and hrp then
			TextIndicatorService:ShowIndicator(player, hrp, "Not enough coins", NOT_ENOUGH_COINS_COLOR, true)
		end
		playFeedbackSound(hrp, "Error")
		return "poor"
	end

	slot.sold = true
	RelicService:AddRelicsRegistry(player, slot.relicName, 1)
	-- Same voice as the vending pickup's "Picked up X!" — white, over
	-- the buyer's head, server-issued.
	if TextIndicatorService then
		TextIndicatorService:ShowIndicator(
			player,
			hrp,
			("You bought %s!"):format(slot.relicName),
			Color3.fromRGB(255, 255, 255),
			true
		)
	end
	return "bought"
end

-- Sells one owned relic at the flat rarity price. The relic and its
-- effects leave immediately (RemoveRelicsRegistry replicates; stats
-- recompute off the registry). Returns the coins paid, or 0.
function EventService.Client:SellRelic(player: Player, relicName: string): number
	if typeof(relicName) ~= "string" or not RelicData[relicName] then
		return 0
	end
	if RelicService:GetSpecificRelicRegistry(player, relicName) <= 0 then
		return 0
	end

	local price = SELL_PRICES[RelicData[relicName].rarity]
	if not price then
		return 0
	end

	RelicService:RemoveRelicsRegistry(player, relicName, 1)
	RunEscrowService:AddCoins(player, price)

	-- Full sale presentation: green receipt over the head, the Buy
	-- chime, and the everyone-visible removed-relic shockwave.
	local sellerHrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if TextIndicatorService and sellerHrp then
		TextIndicatorService:ShowIndicator(player, sellerHrp, ("You sold %s!"):format(relicName), SOLD_COLOR, true)
	end
	playFeedbackSound(sellerHrp, "Buy")
	RelicService:PlayRelicRemovedFX(player)
	return price
end

--[ Lifecycle ]--

function EventService:KnitInit()
	DungeonService = Knit.GetService("DungeonService")
	RelicService = Knit.GetService("RelicService")
	DropService = Knit.GetService("DropService")
	LifeService = Knit.GetService("LifeService")
	TextIndicatorService = Knit.GetService("TextIndicatorService")
	RunEscrowService = Knit.GetService("RunEscrowService")
	PlayerStatsService = Knit.GetService("PlayerStatsService")
	UserNotificationService = Knit.GetService("UserNotificationService")
	CoffinEventService = Knit.GetService("CoffinEventService")
end

function EventService:KnitStart()
	DungeonService.Signals.OnDungeonGenerated:Connect(function(dungeon)
		-- Fresh floor: everything here is per-floor state — old room
		-- models are destroyed with the floor, so wholesale reset both
		-- drops the dead Instance keys and re-arms the per-player
		-- latches for the new floor's events.
		self._eventModels = {}
		self._swordDone = {}
		self._pendingRelicFans = {}
		self._shrineDone = {}
		self._fountainDone = {}
		self._greaterShrineDone = {}
		self._greaterShrinePending = {}
		-- Offers are keyed on statue models, which die with the floor.
		-- _greaterShrineTaken is NOT reset here: exclusion is run-scoped.
		self._greaterShrineOffers = {}
		self._forgeDone = {}
		self._merchantStock = {}
		self._merchantRooms = {}
		self._merchantUnlocked = {}
		self._interactions = {}
		-- The coffin's per-floor state goes with ours, BEFORE the wiring
		-- below registers the new floor's coffin with it.
		if CoffinEventService then
			CoffinEventService:ResetForFloor()
		end
		self:_wireDungeon(dungeon)

		-- (A first-room shop used to be pre-unlocked here because it had
		-- no fight to unlock it. Entry-time unlock covers it: walking out
		-- of the Start area into it fires OnRoomEntered like any room.)
	end)

	-- Merchant stock unlocks when a player first ENTERS the shop — see
	-- _unlockMerchantRoom for why nothing earlier is safe. Per player:
	-- each party member unlocks it by walking in themselves.
	DungeonService.Signals.OnRoomEntered:Connect(function(player: Player, room)
		self:_unlockMerchantRoom(player, room)
	end)

	game:GetService("Players").PlayerRemoving:Connect(function(player)
		self._swordDone[player.UserId] = nil
		self._pendingRelicFans[player.UserId] = nil
		self._shrineDone[player.UserId] = nil
		self._forgeDone[player.UserId] = nil
		self._fountainDone[player.UserId] = nil
		self._greaterShrineDone[player.UserId] = nil
		self._greaterShrinePending[player.UserId] = nil
		self._greaterShrineTaken[player.UserId] = nil
		self._greaterShrineOffers[player.UserId] = nil
		self._merchantStock[player.UserId] = nil
		self._merchantUnlocked[player.UserId] = nil
	end)
end

return EventService
