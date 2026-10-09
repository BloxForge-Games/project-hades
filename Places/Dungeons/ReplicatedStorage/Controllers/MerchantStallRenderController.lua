--!strict
--[[
	Module: MerchantStallRenderController.lua
	Description:
	The merchant stands, as THIS client sees them. Split out of
	EventController, which keeps the dialogue side (the cutscene lock, the
	graph hooks, the sell / reforge round-trips, the ready mark).

	  * The DISPLAY: for every servable shop room (GetMerchantStalls -- the
	    server withholds rooms whose preceding fight has not started) a
	    floating relic clone per stocked stand, dressed like a vending
	    drop (nameplate with the price on the owner line, rarity glow,
	    tinted sparkles), plus the Relic Slot stand's rung on sale, kept as
	    a greyed ghost once every rung is bought. Client-local clones under
	    IgnoreInstances, never seen by the server's fog pass, so a fogged
	    room's stands wait for its reveal.
	  * The BUY PROMPTS: the tagged pedestals' authored prompts, wired with
	    the relic-drop card contract and this player's price. A buy is a
	    server round-trip; "bought" plays the vending pickup's send-off on
	    the clone, and the Relic Slot stand re-arms with the next rung.
	  * HOVER: the same treatment ground relics get (white highlight, a
	    scale-up, the nameplate swapped for the card) plus the shared
	    ambience dim through RelicRenderController:SetExternalRelicHover.
	  * The FLOAT: one Heartbeat spinning and bobbing every clone.

	Everything here is LOCAL -- what shows, the price on the tag, whether a
	stand is already empty: every player sees their own stock.
]]

--[ Roblox Services ]--

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

--[ Imports ]--

local RelicRenderController =
	require(ReplicatedStorage.Controllers.RelicController.SubControllers.RelicRenderController)
-- Read by dressRelicDisplay for the mobile nameplate sizes: listed so it
-- is up before the first stand is dressed.
local ScreenSizeController = require(ReplicatedStorage.Submodules.Core.Source.Controllers.ScreenSizeController)
local ScreenGradientInterfaceController = require(ReplicatedStorage.Interfaces.ScreenGradientInterfaceController)
local DungeonNetwork = require(ReplicatedStorage.Submodules.Core.Source.Network.Dungeon)
local emitVFXPart = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.emitVFXPart)
local fadeSubtree = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.fadeSubtree)
local getRoot = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Character.getRoot)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local getRelicModelTemplate = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Relic.getRelicModelTemplate)
local getRelicDescription = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Relic.getRelicDescription)
local dressRelicDisplay = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Relic.dressRelicDisplay)
local buildPromptCard = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Relic.buildPromptCard)
local RelicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicData)
local RarityColors = require(ReplicatedStorage.Submodules.Core.Shared.Data.RarityColors)
local SkipRelicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.SkipRelicData)
local RelicSlotShopData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicSlotShopData)
local ItemRarity = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ItemRarity)
local Log = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Log)

--[ Constants ]--

-- Pedestal display: slow spin + gentle bob, the same read as the drop
-- relics' float without touching their component.
local PEDESTAL_SPIN_SPEED = 0.8 -- radians/second
local PEDESTAL_BOB_HEIGHT = 0.35
local PEDESTAL_BOB_SPEED = 1.2
-- Vending-drop parity: drops spawn at 1.5x and hover to 2x, so the
-- stalls do exactly the same. The lerp rate shapes both directions.
local PEDESTAL_BASE_SCALE = 1.5
local PEDESTAL_HOVER_SCALE = 2
local PEDESTAL_SCALE_LERP_PER_SECOND = 8
-- Buy flourish: the fade-and-shrink after a purchase.
local BUY_FADE_SECONDS = 0.4
-- The pickup bursts, shared with a vending collect (Client/Components/
-- Relic), attribute-driven and tinted to the rarity: CollectRelicVFX at
-- the stall's relic, CollectRelicVFXCharacter on the buyer.
local COLLECT_RELIC_VFX_NAME = "CollectRelicVFX"
local COLLECT_RELIC_CHARACTER_VFX_NAME = "CollectRelicVFXCharacter"
-- Same lingering as the vending collect (Client/Components/Relic).
local COLLECT_RELIC_VFX_LIFETIME_SCALE = 1.5
local COLLECT_RELIC_CHARACTER_VFX_LIFETIME_SCALE = 2
-- The merchant's price, on the stall nameplate's owner line. Gold, the
-- same colour the price already uses on the relic card's description.
local STALL_PRICE_COLOR = Color3.fromRGB(255, 170, 0)
local STALL_PRICE_FORMAT = "(%d Gold)"

-- Stall-display particle tints — the RelicParticleAttachment set ONLY
-- (nameplate text and the RarityGlow PointLight keep the standard
-- palettes). Rarities not listed fall back to RarityColors:Get.
local STALL_PARTICLE_COLORS = {
	[ItemRarity.Rare] = Color3.fromRGB(55, 98, 255),
	[ItemRarity.Epic] = Color3.fromRGB(81, 0, 255),
}

-- The Relic Slot stand (RelicSlotShopData) once every rung is bought:
-- the display stays as a near-black silhouette (every part this colour,
-- its mesh texture stripped so the colour is all that draws) with a
-- "Sold Out" line, no glow, no sparkles, and no prompt.
local SOLD_OUT_PART_COLOR = Color3.fromRGB(50, 50, 50)
local SOLD_OUT_PART_TRANSPARENCY = 0.3
-- After a slot buy the stand re-arms with the next rung: this long after
-- the flourish starts (its fade is BUY_FADE_SECONDS) the fresh display
-- fades back in and the prompt re-enables.
local SLOT_UPGRADE_RESPAWN_SECONDS = 1

--[ Types ]--

-- One wired stall prompt: which pedestal it sits on and which stall slot
-- it sells. `kind` "relic" is a numbered stock stand (index = its slot);
-- "slot" is the room's Relic Slot stand (index unused, 0).
type PedestalRecord = { pedestal: Instance, roomId: number, index: number, kind: string }
-- Everything a stand's display clone gets besides its model: the
-- RelicName nameplate (name / rarity line / price line), the RarityGlow
-- light and the tinted sparkle set. No glowColor / particleColor means
-- no light and no sparkles (a sold-out stand).
type StallDressing = {
	name: string,
	rarity: string,
	rarityColor: Color3,
	priceText: string,
	priceColor: Color3,
	glowColor: Color3?,
	particleColor: Color3?,
}
-- A display clone mid-float: its rest pose plus the hover scale lerp.
type FloatState = { base: CFrame, phase: number, scale: number, targetScale: number }

-- The _stallClones key of a record's display clone.
local function stallKey(record: PedestalRecord): string
	if record.kind == "slot" then
		return record.roomId .. ":slot"
	end
	return record.roomId .. ":" .. record.index
end

--[ Controller ]--

local MerchantStallRenderController = {
	Name = "MerchantStallRenderController",
	Dependencies = { RelicRenderController, ScreenSizeController, ScreenGradientInterfaceController } :: { any },

	-- [prompt] = { pedestal, merchant, index, clone } — this client's
	-- live pedestals. Everything about them is LOCAL: what shows, the
	-- price on the tag, and whether the stand is already empty.
	_pedestalsByPrompt = {} :: { [ProximityPrompt]: PedestalRecord },
	-- [roomId] = slots from GetMerchantStalls (relic, price, sold, cframe).
	_stalls = {} :: { [number]: { DungeonNetwork.MerchantSlot } },
	-- [roomId] = the Relic Slot stand from GetMerchantStalls (rung, price,
	-- soldOut, cframe); rooms without the stand have no entry.
	_slotUpgrades = {} :: { [number]: DungeonNetwork.MerchantSlotUpgrade },
	-- ["roomId:index"] = the rendered clone on that stand.
	_stallClones = {} :: { [string]: Model },
	-- clones being animated: [model] = { base = CFrame, phase = number }
	_floatingClones = {} :: { [Model]: FloatState },
	-- [roomModel] = connection — pending fog-reveal listeners for shop
	-- rooms whose stock unlocked before the room itself was revealed.
	_revealWatchers = {} :: { [Model]: RBXScriptConnection },
	-- The shared hover highlight, created in Start (see _rescuePedestalHighlight).
	_pedestalHighlight = nil :: Highlight?,
}

--[ Public ]--

-- Fetch + render every SERVABLE merchant stall (rooms whose preceding
-- fight has started — the server withholds locked rooms). Called on
-- the dungeon-generated signal, on every stock-unlock signal, and once
-- at start; never on streaming.
function MerchantStallRenderController.RefreshMerchantStalls(self: typeof(MerchantStallRenderController))
	local ok, stalls = pcall(function()
		return DungeonNetwork.GetMerchantStalls.Invoke()
	end)
	if not ok or type(stalls) ~= "table" then
		warn("[MerchantStallRenderController] GetMerchantStalls failed: " .. tostring(stalls))
		return
	end

	-- Regen-safe: the previous floor's clones die before the new render.
	for key, clone in self._stallClones do
		self._floatingClones[clone] = nil
		self:_rescuePedestalHighlight(clone)
		clone:Destroy()
		self._stallClones[key] = nil
	end
	table.clear(self._stalls)
	table.clear(self._slotUpgrades)
	-- Reveal watchers for rooms the previous floor destroyed: the connection
	-- died with the model, the Model key did not.
	for roomModel, connection in self._revealWatchers do
		if not roomModel.Parent then
			connection:Disconnect()
			self._revealWatchers[roomModel] = nil
		end
	end

	local rendered = 0
	for _, stall in stalls do
		self._stalls[stall.roomId] = stall.slots
		if stall.slotUpgrade then
			self._slotUpgrades[stall.roomId] = stall.slotUpgrade
		end

		-- FOG OF WAR: the stands are client-local clones parented to
		-- IgnoreInstances, NOT to the room model, so the server's fog pass
		-- never touches them. Stock unlocks a whole room early (when the
		-- fight before the shop starts), which would leave five lit relics
		-- floating in an unrevealed room — the loudest possible tell.
		-- Render them only once the room itself is revealed; the listener
		-- re-runs this whole refresh the moment it flips.
		local roomModel = stall.roomModel
		if roomModel and roomModel:GetAttribute("FogRevealed") == false then
			self:_watchRoomReveal(roomModel)
			continue
		end

		for index, slot in stall.slots do
			if not slot.sold and slot.cframe then
				if self:_renderStallSlot(stall.roomId, index, slot) then
					rendered += 1
				end
			end
		end
		-- The Relic Slot stand renders sold out too (greyed), unlike a
		-- bought-out relic stand.
		if stall.slotUpgrade and stall.slotUpgrade.cframe then
			if self:_renderSlotUpgrade(stall.roomId, stall.slotUpgrade) then
				rendered += 1
			end
		end
	end
	Log.debug(("[MerchantStallRenderController] Rendered %d merchant stall relic(s)"):format(rendered))
end

--[ Private ]--

-- One-shot listener: when a fogged shop room is revealed, re-fetch and
-- render its stands. Keyed per model so repeated refreshes while the
-- room is still dark do not stack listeners.
function MerchantStallRenderController._watchRoomReveal(self: typeof(MerchantStallRenderController), roomModel: Model)
	if self._revealWatchers[roomModel] then
		return
	end
	local connection
	connection = roomModel:GetAttributeChangedSignal("FogRevealed"):Connect(function()
		if roomModel:GetAttribute("FogRevealed") ~= true then
			return
		end
		connection:Disconnect()
		self._revealWatchers[roomModel] = nil
		task.spawn(function()
			self:RefreshMerchantStalls()
		end)
	end)
	self._revealWatchers[roomModel] = connection
end

-- One floating display clone at the stand's generation-captured CFrame.
function MerchantStallRenderController._renderStallSlot(
	self: typeof(MerchantStallRenderController),
	roomId: number,
	index: number,
	slot: any
): boolean
	local rarity = RelicData[slot.relicName] and RelicData[slot.relicName].rarity
	local template = rarity and getRelicModelTemplate(slot.relicName, rarity)
	if not template then
		warn(
			("[MerchantStallRenderController] No model template for stall relic '%s' (%s)"):format(
				tostring(slot.relicName),
				tostring(rarity)
			)
		)
		return false
	end
	local clone = template:Clone()
	-- VENDING-DROP PARITY: the same nameplate, rarity glow, and dim
	-- membership a machine drop gets. Same prefab as a dropped relic's
	-- nameplate, but a stall relic has no owner -- so the line carries
	-- the PRICE in gold instead.
	local rarityColor = RarityColors:Get(rarity)
	self:_dressStallClone(clone, slot.cframe, {
		name = slot.relicName,
		rarity = rarity,
		rarityColor = rarityColor,
		priceText = STALL_PRICE_FORMAT:format(slot.price or 0),
		priceColor = STALL_PRICE_COLOR,
		glowColor = RarityColors:GetGlow(rarity),
		particleColor = STALL_PARTICLE_COLORS[rarity] or rarityColor,
	})
	self:_placeStallClone(clone, roomId .. ":" .. index, slot.cframe)
	return true
end

-- Anchors, poses and dresses one display clone (see StallDressing). The
-- ShopRelicDisplay tag + OwnerId attribute (_placeStallClone) are what
-- let RelicRenderController's shared dim treat these clones as family;
-- nothing server-side ever sees them.
function MerchantStallRenderController._dressStallClone(
	_self: typeof(MerchantStallRenderController),
	clone: Model,
	cframe: CFrame,
	dressing: StallDressing
)
	for _, part in clone:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = true
			part.CanCollide = false
		end
	end
	local primary = clone.PrimaryPart
	if primary then
		primary.Transparency = 1
	end
	clone:PivotTo(cframe)
	clone:ScaleTo(PEDESTAL_BASE_SCALE)
	if not primary then
		return
	end

	-- The shared drop dressing: nameplate (the price on the owner line,
	-- since a stall relic has no owner), RarityGlow, and the authored
	-- sparkle set tinted and moved onto the Handle where the shared dim
	-- pass reads it. No glow / particle colour (a sold-out stand) means
	-- no light -- and no sparkles at all, so the set goes.
	dressRelicDisplay(primary, {
		name = dressing.name,
		rarity = dressing.rarity,
		rarityColor = dressing.rarityColor,
		ownerOverride = { text = dressing.priceText, color = dressing.priceColor },
		glowColor = dressing.glowColor,
		particleColor = dressing.particleColor,
	})
	if not dressing.particleColor then
		local particleAttachment = primary:FindFirstChild("RelicParticleAttachment")
		if particleAttachment then
			particleAttachment:Destroy()
		end
	end
end

-- Puts a dressed clone on its stand: the dim-family tag, the ignore
-- folder, the float loop, and the key it is found under.
function MerchantStallRenderController._placeStallClone(
	self: typeof(MerchantStallRenderController),
	clone: Model,
	key: string,
	cframe: CFrame
)
	clone:AddTag("ShopRelicDisplay")
	clone:SetAttribute("OwnerId", Players.LocalPlayer.UserId)

	local ignoreFolder = workspace:FindFirstChild("IgnoreInstances")
	local spellsFolder = ignoreFolder and ignoreFolder:FindFirstChild("ArcaneSpells")
	clone.Parent = spellsFolder or workspace
	self._floatingClones[clone] = {
		base = cframe,
		phase = math.random() * math.pi * 2,
		scale = PEDESTAL_BASE_SCALE,
		targetScale = PEDESTAL_BASE_SCALE,
	}
	self._stallClones[key] = clone
end

-- The Relic Slot stand's display: the Skip offer's model dressed for the
-- rung on sale -- its rarity on the nameplate line, glow and sparkles,
-- the rung's price on the price line. Sold out (every rung bought) keeps
-- the model as a greyed ghost: "Sold Out" on the rarity line, "(???)"
-- for a price, no glow, no sparkles.
function MerchantStallRenderController._renderSlotUpgrade(
	self: typeof(MerchantStallRenderController),
	roomId: number,
	upgrade: DungeonNetwork.MerchantSlotUpgrade
): boolean
	local cframe = upgrade.cframe
	local template = getRelicModelTemplate(SkipRelicData.Name, SkipRelicData.Folder)
	if not cframe or not template or not template:IsA("Model") then
		warn(
			("[MerchantStallRenderController] No model for the Relic Slot stand (GameAssets.Relics.%s.%s)"):format(
				SkipRelicData.Folder,
				SkipRelicData.Name
			)
		)
		return false
	end
	local tiers = RelicSlotShopData.Tiers
	local rung = tiers[upgrade.tier] or tiers[#tiers]

	local clone = template:Clone()
	clone.Name = RelicSlotShopData.Name
	if upgrade.soldOut then
		self:_dressStallClone(clone, cframe, {
			name = RelicSlotShopData.Name,
			rarity = RelicSlotShopData.SoldOutText,
			rarityColor = SkipRelicData.Color,
			priceText = RelicSlotShopData.SoldOutPriceText,
			priceColor = SkipRelicData.Color,
		})
		for _, descendant in clone:GetDescendants() do
			if descendant:IsA("BasePart") and descendant.Transparency < 1 then
				descendant.Color = SOLD_OUT_PART_COLOR
				descendant.Material = Enum.Material.Plastic
				descendant.Transparency = math.max(descendant.Transparency, SOLD_OUT_PART_TRANSPARENCY)
				if descendant:IsA("MeshPart") then
					-- Settable on a clone at runtime on current clients; a
					-- refusal just leaves the texture, so guarded.
					pcall(function()
						(descendant :: any).TextureID = ""
					end)
				end
			elseif descendant:IsA("SpecialMesh") then
				descendant.TextureId = ""
				descendant.VertexColor = Vector3.new(1, 1, 1)
			elseif descendant:IsA("Decal") or descendant:IsA("Texture") then
				(descendant :: any).Transparency = 1
			end
		end
	else
		local rarityColor = RarityColors:Get(rung.rarity)
		self:_dressStallClone(clone, cframe, {
			name = RelicSlotShopData.Name,
			rarity = rung.rarity,
			rarityColor = rarityColor,
			priceText = STALL_PRICE_FORMAT:format(upgrade.price),
			priceColor = STALL_PRICE_COLOR,
			glowColor = RarityColors:GetGlow(rung.rarity),
			particleColor = STALL_PARTICLE_COLORS[rung.rarity] or rarityColor,
		})
	end
	self:_placeStallClone(clone, roomId .. ":slot", cframe)
	return true
end

-- A freshly rendered stand fading IN (the Relic Slot stand re-arming
-- after a buy): every visible part and the glow start from nothing and
-- tween to what the render gave them, over the buy fade's length.
function MerchantStallRenderController._fadeInClone(_self: typeof(MerchantStallRenderController), clone: Model)
	local restore = fadeSubtree(clone, { targetTransparency = 1, skipHidden = true, lights = true })
	restore(TweenInfo.new(BUY_FADE_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out))
end

-- A tagged pedestal streamed in: wire its PROMPT only (the display never
-- waited for it). Stall data is a generation product, so the wait below
-- is a join-order formality, bounded by the room's lifetime.
function MerchantStallRenderController._wirePedestal(self: typeof(MerchantStallRenderController), pedestal: Instance)
	local interactables = pedestal.Parent
	local room = interactables and interactables.Parent
	local roomId = (room and room:GetAttribute("RoomId")) :: number?
	local index = tonumber(string.match(pedestal.Name, "%d+$"))
	if not room or not roomId or not index then
		warn(
			("[MerchantStallRenderController] Pedestal '%s': missing RoomId attribute or trailing number"):format(
				pedestal:GetFullName()
			)
		)
		return
	end

	local prompt = self:_awaitStandPrompt(pedestal, room)
	if not prompt then
		return
	end

	while not self._stalls[roomId] and room.Parent do
		task.wait(0.25)
	end
	local slots = self._stalls[roomId]
	local slot = slots and slots[index]
	if not slot or slot.sold then
		prompt.Enabled = false
		return
	end

	-- The SAME prompt card the vending-machine relic drops use
	-- (Client/Components/Relic.lua), so the place's custom prompt renders
	-- name + full description here too. The price rides the card's
	-- UserText slot (gold), the same line that carries the owner's name
	-- on a dropped relic. All local writes: every player sees their own
	-- stock and price.
	local description = getRelicDescription(Players.LocalPlayer, slot.relicName) or "No description available."
	buildPromptCard(prompt, {
		name = slot.relicName,
		description = description,
		rarity = RelicData[slot.relicName] and RelicData[slot.relicName].rarity,
		userText = STALL_PRICE_FORMAT:format(slot.price),
		userTextColor = STALL_PRICE_COLOR,
	})
	self._pedestalsByPrompt[prompt] = {
		pedestal = pedestal,
		roomId = roomId,
		index = index,
		kind = "relic",
	}
	prompt.Enabled = true
end

-- A stand's authored prompt, once it has streamed in and the room is
-- revealed; nil if the stand or room despawned first. Disables the
-- prompt on the way (the caller re-enables once its texts are in).
function MerchantStallRenderController._awaitStandPrompt(
	_self: typeof(MerchantStallRenderController),
	pedestal: Instance,
	room: Instance
): ProximityPrompt?
	-- Streaming replicates the pedestal PART before its descendants, so
	-- the authored prompt (under the Attachment) can land a beat after
	-- the tag fires. Poll on the same room-lifetime bound the stall-data
	-- wait below uses instead of one-shot-and-give-up.
	local prompt = pedestal:FindFirstChildWhichIsA("ProximityPrompt", true)
	while not prompt and pedestal.Parent and room.Parent do
		task.wait(0.25)
		prompt = pedestal:FindFirstChildWhichIsA("ProximityPrompt", true)
	end
	if not prompt then
		return nil -- pedestal or room despawned before its prompt replicated
	end
	-- Keep the authored placeholder ("Relic Name") hidden until the real
	-- texts are in; re-enabled at the end of the wire.
	prompt.Enabled = false

	-- FOG OF WAR: a shop's stands are wired the moment their pedestals
	-- stream in, which can be well before anyone has entered the room.
	-- Enabling the prompt then would float a buy card inside an
	-- unrevealed room — wait for the server's reveal first.
	while room:GetAttribute("FogRevealed") == false and pedestal.Parent and room.Parent do
		task.wait(0.25)
	end

	return prompt
end

-- The tagged Relic Slot pedestal streamed in: wire its prompt to the
-- room's slot-upgrade state (fetched with the stalls). Same waits and
-- fog rule as _wirePedestal; the display itself never waits on this.
function MerchantStallRenderController._wireSlotPedestal(
	self: typeof(MerchantStallRenderController),
	pedestal: Instance
)
	local interactables = pedestal.Parent
	local room = interactables and interactables.Parent
	local roomId = (room and room:GetAttribute("RoomId")) :: number?
	if not room or not roomId then
		warn(
			("[MerchantStallRenderController] Relic Slot pedestal '%s': missing RoomId attribute"):format(
				pedestal:GetFullName()
			)
		)
		return
	end
	local prompt = self:_awaitStandPrompt(pedestal, room)
	if not prompt then
		return
	end
	while not self._slotUpgrades[roomId] and room.Parent do
		task.wait(0.25)
	end
	self:_armSlotPrompt(prompt, pedestal, roomId)
end

-- Writes the Relic Slot stand's prompt card for the rung on sale and
-- records it for the buy; leaves it disabled when the stand is sold out
-- (or has no state). Re-run after every buy for the next rung.
function MerchantStallRenderController._armSlotPrompt(
	self: typeof(MerchantStallRenderController),
	prompt: ProximityPrompt,
	pedestal: Instance,
	roomId: number
)
	local upgrade = self._slotUpgrades[roomId]
	if not upgrade or upgrade.soldOut or not prompt.Parent or not pedestal.Parent then
		prompt.Enabled = false
		return
	end
	local tiers = RelicSlotShopData.Tiers
	local rung = tiers[upgrade.tier] or tiers[#tiers]

	-- The relic-drop prompt card (see _wirePedestal): name + rich
	-- description, tinted by the rung's rarity, the price on the UserText
	-- line.
	buildPromptCard(prompt, {
		name = RelicSlotShopData.Name,
		description = RelicSlotShopData.Description,
		rarity = rung.rarity,
		userText = STALL_PRICE_FORMAT:format(upgrade.price),
		userTextColor = STALL_PRICE_COLOR,
	})
	self._pedestalsByPrompt[prompt] = {
		pedestal = pedestal,
		roomId = roomId,
		index = 0,
		kind = "slot",
	}
	prompt.Enabled = true
end

-- Pulls the shared hover highlight off a doomed clone. Destroying the
-- clone with the highlight still inside LOCKS the highlight's Parent
-- ("The Parent property of PedestalRelicHighlight is locked"), which
-- would break every later pedestal hover for the whole session.
function MerchantStallRenderController._rescuePedestalHighlight(
	self: typeof(MerchantStallRenderController),
	clone: Model
)
	local highlight = self._pedestalHighlight
	if highlight and highlight.Parent == clone then
		highlight.FillTransparency = 1
		highlight.Adornee = nil
		highlight.Parent = nil
	end
end

-- The vending pickup's send-off, minus the claim-one teardown: rarity
-- gradient pulse, then the display fades and shrinks out. The clone
-- leaves the float loop first so the fade owns its pose.
-- `rarityOverride` is for a clone whose name is not a RelicData entry
-- (the Relic Slot stand): the rung's rarity tints the pulse and burst.
function MerchantStallRenderController._playBuyFlourish(
	self: typeof(MerchantStallRenderController),
	clone: Model,
	rarityOverride: string?
)
	self._floatingClones[clone] = nil

	local relicName = clone.Name
	local rarity = rarityOverride or (RelicData[relicName] and RelicData[relicName].rarity)
	if ScreenGradientInterfaceController and rarity then
		ScreenGradientInterfaceController.Signals.OnPulseGradient:Fire(RarityColors:Get(rarity))
	end

	-- Vending-pickup parity: the RelicPickup chime, CollectRelicVFX at
	-- the relic, and CollectRelicVFXCharacter on the buyer, both tinted
	-- to the rarity.
	local handle = clone:FindFirstChild("Handle") or clone.PrimaryPart
	if handle then
		-- Two-layer sting: the vending RelicPickup chime plus the shop's
		-- own Buy cha-ching, together.
		for _, soundName in { "RelicPickup", "Buy" } do
			local sound = ReplicatedStorage.GameAssets.Sounds:FindFirstChild(soundName)
			if sound then
				local soundClone = sound:Clone()
				soundClone.Parent = handle
				soundClone:Play()
			end
		end
		local burstColor = if rarity then RarityColors:Get(rarity) else nil
		if handle:IsA("BasePart") then
			emitVFXPart(COLLECT_RELIC_VFX_NAME, handle.CFrame, nil, {
				Color = burstColor,
				LifetimeScale = COLLECT_RELIC_VFX_LIFETIME_SCALE,
			})
		end
		local root = getRoot.fromPlayer(Players.LocalPlayer)
		if root then
			emitVFXPart(COLLECT_RELIC_CHARACTER_VFX_NAME, root.CFrame, nil, {
				Color = burstColor,
				LifetimeScale = COLLECT_RELIC_CHARACTER_VFX_LIFETIME_SCALE,
			})
		end
	end

	local nameplate = clone.PrimaryPart and clone.PrimaryPart:FindFirstChild("RelicName")
	if nameplate then
		nameplate:Destroy()
	end
	-- Every visible part and the glow fade out together; the sparkles
	-- stop at once and their live particles die on their own.
	fadeSubtree(clone, {
		targetTransparency = 1,
		tweenInfo = TweenInfo.new(BUY_FADE_SECONDS),
		skipHidden = true,
		lights = true,
		disable = { "ParticleEmitter" },
	})
	-- +1s past the fade so the pickup chime and Collected burst finish
	-- before the (already invisible) clone is collected.
	task.delay(BUY_FADE_SECONDS + 1, function()
		clone:Destroy()
	end)
end

-- A pedestal prompt fired for the local player: try the buy. "bought"
-- clears the stand locally; "poor" already showed the server's "Not
-- enough coins" indicator; anything else quietly re-arms.
function MerchantStallRenderController._onPedestalPrompt(
	self: typeof(MerchantStallRenderController),
	prompt: ProximityPrompt
)
	local record = self._pedestalsByPrompt[prompt]
	if not record then
		return
	end
	if record.kind == "slot" then
		self:_onSlotPedestalPrompt(prompt, record)
		return
	end
	local ok, result = pcall(function()
		return DungeonNetwork.BuyMerchantRelic.Invoke({ RoomId = record.roomId, Index = record.index })
	end)
	if ok and (result == "bought" or result == "sold") then
		prompt.Enabled = false
		self._pedestalsByPrompt[prompt] = nil
		local key = stallKey(record)
		local clone = self._stallClones[key]
		self._stallClones[key] = nil
		-- Mirror the server's sold latch locally: if this pedestal
		-- streams out and back in, _wirePedestal reads slot.sold and
		-- keeps the prompt dead instead of rewiring a ghost.
		local slots = self._stalls[record.roomId]
		local slot = slots and slots[record.index]
		if slot then
			slot.sold = true
		end
		-- The record above is already gone, so the PromptHidden handler
		-- early-returns and ITS cleanup never runs — un-hover explicitly:
		-- rescue the shared highlight off the doomed clone and lift the
		-- shared ambience dim.
		if clone then
			self:_rescuePedestalHighlight(clone)
		end
		if RelicRenderController then
			RelicRenderController:SetExternalRelicHover(false)
		end
		if clone and result == "bought" then
			self:_playBuyFlourish(clone)
		elseif clone then
			self._floatingClones[clone] = nil
			clone:Destroy()
		end
	end
end

-- The Relic Slot stand's prompt fired: try the buy. "bought" plays the
-- buy flourish on the display, then the stand RE-ARMS with the next rung
-- (fades back in, prompt re-enabled) -- or, after the last rung, as the
-- greyed sold-out ghost with no prompt. The local state advances the
-- same way the server's does (RelicSlotShopData.Tiers), so no refetch;
-- a later refresh (server truth) simply overrides it.
function MerchantStallRenderController._onSlotPedestalPrompt(
	self: typeof(MerchantStallRenderController),
	prompt: ProximityPrompt,
	record: PedestalRecord
)
	local ok, result = pcall(function()
		return DungeonNetwork.BuyRelicSlot.Invoke(record.roomId)
	end)
	if not ok or (result ~= "bought" and result ~= "sold") then
		return
	end
	prompt.Enabled = false
	self._pedestalsByPrompt[prompt] = nil
	local key = stallKey(record)
	local clone = self._stallClones[key]
	self._stallClones[key] = nil

	local upgrade = self._slotUpgrades[record.roomId]
	local tiers = RelicSlotShopData.Tiers
	local boughtRung = upgrade and tiers[upgrade.tier]
	if upgrade then
		local nextRung = if result == "bought" then tiers[upgrade.tier + 1] else nil
		if nextRung then
			upgrade.tier += 1
			upgrade.price = nextRung.price
		else
			upgrade.soldOut = true
		end
	end

	-- Un-hover explicitly (the record is gone, so PromptHidden's cleanup
	-- never runs): rescue the shared highlight, lift the ambience dim.
	if clone then
		self:_rescuePedestalHighlight(clone)
	end
	if RelicRenderController then
		RelicRenderController:SetExternalRelicHover(false)
	end
	if clone and result == "bought" then
		self:_playBuyFlourish(clone, boughtRung and boughtRung.rarity)
	elseif clone then
		self._floatingClones[clone] = nil
		clone:Destroy()
	end

	-- Re-arm once the flourish has cleared. The display is rendered only
	-- if nothing else (a refresh in the meantime) already put one there;
	-- the prompt is always re-armed off the current state.
	task.delay(SLOT_UPGRADE_RESPAWN_SECONDS, function()
		local current = self._slotUpgrades[record.roomId]
		if not current or not current.cframe then
			return
		end
		if not self._stallClones[key] and self:_renderSlotUpgrade(record.roomId, current) then
			local fresh = self._stallClones[key]
			if fresh then
				self:_fadeInClone(fresh)
			end
		end
		self:_armSlotPrompt(prompt, record.pedestal, record.roomId)
	end)
end

--[ Lifecycle ]--

function MerchantStallRenderController.Start(self: typeof(MerchantStallRenderController))
	-- Merchant stalls render per ROOM as each unlocks: the server rolls
	-- stock only once the fight before the shop begins (keeps the
	-- unowned filter honest). The generation replay and the immediate
	-- call cover rejoin / late start — both serve whatever is already
	-- unlocked.
	DungeonNetwork.DungeonGenerated.On(function()
		task.spawn(function()
			self:RefreshMerchantStalls()
		end)
	end)
	task.spawn(function()
		self:RefreshMerchantStalls()
	end)

	-- Per-player unlock: YOU just entered a shop, its shelves are now
	-- rollable server-side for you — fetch and render them.
	DungeonNetwork.MerchantStockUnlocked.On(function(_roomId: number)
		task.spawn(function()
			self:RefreshMerchantStalls()
		end)
	end)

	-- Merchant pedestals: discovery by tag (the server stamps them at
	-- generation) wires the BUY PROMPTS only.
	local function onPedestal(pedestal: Instance)
		task.spawn(function()
			self:_wirePedestal(pedestal)
		end)
	end
	CollectionService:GetInstanceAddedSignal(TagList.MerchantPedestal):Connect(onPedestal)
	for _, pedestal in CollectionService:GetTagged(TagList.MerchantPedestal) do
		onPedestal(pedestal)
	end
	-- The Relic Slot stand: same discovery, its own wire.
	local function onSlotPedestal(pedestal: Instance)
		task.spawn(function()
			self:_wireSlotPedestal(pedestal)
		end)
	end
	CollectionService:GetInstanceAddedSignal(TagList.MerchantSlotPedestal):Connect(onSlotPedestal)
	for _, pedestal in CollectionService:GetTagged(TagList.MerchantSlotPedestal) do
		onSlotPedestal(pedestal)
	end
	-- Streamed-out pedestals only drop their PROMPT record; the display
	-- clone is generation-scoped and dies in RefreshMerchantStalls when
	-- the floor actually regenerates.
	local function onPedestalRemoved(pedestal: Instance)
		for prompt, record in self._pedestalsByPrompt do
			if record.pedestal == pedestal then
				self._pedestalsByPrompt[prompt] = nil
			end
		end
	end
	CollectionService:GetInstanceRemovedSignal(TagList.MerchantPedestal):Connect(onPedestalRemoved)
	CollectionService:GetInstanceRemovedSignal(TagList.MerchantSlotPedestal):Connect(onPedestalRemoved)

	ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt, player: Player)
		if player ~= Players.LocalPlayer then
			return
		end
		task.spawn(function()
			self:_onPedestalPrompt(prompt)
		end)
	end)

	-- HOVER: the same treatment ground relics get — white highlight and
	-- a scale-up on the hovered display, plus the shared ambience (orbit
	-- semi-hide, owned machine / ground-relic / gear-drop dim) through
	-- RelicRenderController's external entry point. The clones cannot
	-- carry the Relic tag (that would mount the pickup component), which
	-- is why the inline handlers never see them.
	local pedestalHighlight = Instance.new("Highlight")
	pedestalHighlight.Name = "PedestalRelicHighlight"
	pedestalHighlight.FillColor = Color3.fromRGB(255, 255, 255)
	pedestalHighlight.OutlineColor = Color3.fromRGB(255, 255, 255)
	pedestalHighlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	pedestalHighlight.FillTransparency = 1
	-- Field copy: the buy path and the stall wipe are METHODS (outside
	-- this closure) and must rescue the highlight off clones they
	-- destroy — see _rescuePedestalHighlight.
	self._pedestalHighlight = pedestalHighlight

	ProximityPromptService.PromptShown:Connect(function(prompt: ProximityPrompt)
		local record = self._pedestalsByPrompt[prompt]
		if not record then
			return
		end
		local clone = self._stallClones[stallKey(record)]
		local state = clone and self._floatingClones[clone]
		if not state then
			return
		end
		state.targetScale = PEDESTAL_HOVER_SCALE
		-- The prompt card replaces the nameplate while hovered (drop rule).
		local nameplate = clone.PrimaryPart and clone.PrimaryPart:FindFirstChild("RelicName") :: BillboardGui?
		if nameplate then
			nameplate.Enabled = false
		end
		pedestalHighlight.FillTransparency = 1
		pedestalHighlight.Adornee = clone
		pedestalHighlight.Parent = clone
		TweenService:Create(
			pedestalHighlight,
			TweenInfo.new(0.5, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out),
			{ FillTransparency = 0.75 }
		):Play()
		if RelicRenderController then
			RelicRenderController:SetExternalRelicHover(true, clone)
		end
	end)

	ProximityPromptService.PromptHidden:Connect(function(prompt: ProximityPrompt)
		local record = self._pedestalsByPrompt[prompt]
		if not record then
			return
		end
		local clone = self._stallClones[stallKey(record)]
		local state = clone and self._floatingClones[clone]
		if state then
			state.targetScale = PEDESTAL_BASE_SCALE
		end
		local nameplate = clone and clone.PrimaryPart and clone.PrimaryPart:FindFirstChild("RelicName") :: BillboardGui?
		if nameplate then
			nameplate.Enabled = true
		end
		pedestalHighlight.FillTransparency = 1
		pedestalHighlight.Adornee = nil
		pedestalHighlight.Parent = nil
		if RelicRenderController then
			RelicRenderController:SetExternalRelicHover(false)
		end
	end)

	-- The float: one Heartbeat for every pedestal clone this client has.
	-- Most of a run no stand is dressed, so the body is skipped outright
	-- while the table is empty: one `next` per frame.
	RunService.Heartbeat:Connect(function(deltaTime: number)
		if next(self._floatingClones) == nil then
			return
		end
		local now = os.clock()
		for clone, state in self._floatingClones do
			if not clone.Parent then
				self._floatingClones[clone] = nil
				continue
			end
			local bob = math.sin(now * PEDESTAL_BOB_SPEED + state.phase) * PEDESTAL_BOB_HEIGHT
			clone:PivotTo(state.base * CFrame.new(0, bob, 0) * CFrame.Angles(0, now * PEDESTAL_SPIN_SPEED, 0))
			-- Hover scale: framerate-independent lerp toward the target;
			-- ScaleTo is absolute, so applying every frame cannot compound.
			if math.abs(state.targetScale - state.scale) > 0.003 then
				local alpha = math.min(deltaTime * PEDESTAL_SCALE_LERP_PER_SECOND, 1)
				state.scale += (state.targetScale - state.scale) * alpha
				clone:ScaleTo(state.scale)
			end
		end
	end)
end

return MerchantStallRenderController
