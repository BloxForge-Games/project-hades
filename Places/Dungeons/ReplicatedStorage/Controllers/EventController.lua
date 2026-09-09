--[[
	Module: EventController.lua
	Description:
	Client-side brain for Event-room interactions. The dialogue itself is
	the ordinary NPC pipeline (DialogueBillboardInterface runs the graph);
	this controller supplies what the graphs cannot do alone:

	  * The SwordStone / CursedShrine CUTSCENE: controls off, cinematic
	    bars + HUD hide (CinematicInterfaceController signals — the same
	    rails EncounterIntroController rides). The character just ROTATES
	    to face the event — the dialogue session's own face-watcher does
	    that every frame; there is deliberately no walk-to. All torn down
	    when the dialogue closes BY ANY PATH (leave, give up, death,
	    completion) via the billboard's CloseDialogue signal.
	  * Server round-trips for outcomes (EventService), with the results
	    parked on controller fields the graph nodes' Conditions read —
	    the billboard engine branches by skipping condition-failed nodes,
	    so "fail/dead/success" are three consecutive gated nodes.
	  * LOCAL success VFX: the sword's particles stop and its lights fade
	    for THIS client only — events are per-player, and the sword must
	    stay lit for a teammate who hasn't pulled it yet.

	Graphs reach the model they were triggered on through the billboard's
	GetActiveDialogueModel(), so the registry modules stay plain data plus
	thin calls into here.
]]

--[ Roblox Services ]--

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

--[ Imports ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local applyOwnerLabel = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Drop.applyOwnerLabel)
local Signal = require(ReplicatedStorage.Submodules.Core.Packages.Signal)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local getRelicModelTemplate = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Relic.getRelicModelTemplate)
local getRelicDescription = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Relic.getRelicDescription)
local RelicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicData)
local RarityColors = require(ReplicatedStorage.Submodules.Core.Shared.Data.RarityColors)
local GreaterShrineData = require(ReplicatedStorage.Submodules.Core.Shared.Data.GreaterShrineData)
local ItemRarity = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ItemRarity)
local ScreenSizes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ScreenSizes)
local UserNotificationSystem = require(ReplicatedStorage.Submodules.Core.Libraries.UserNotificationSystem).Controller

local EventService
local CoffinEventService
local RelicRenderController
local ScreenSizeController
local ScreenGradientInterfaceController
local EncounterIntroController
local DialogueBillboardInterface
local CinematicInterfaceController
local CutsceneController

--[ Constants ]--

local LIGHT_FADE_SECONDS = 1
local LIGHT_FADE_INFO = TweenInfo.new(LIGHT_FADE_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

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
-- Same glow the vending drops get (Client/Components/Relic.lua).
local GLOW_NAME = "RarityGlow"
local GLOW_BRIGHTNESS = 0.25
local GLOW_RANGE = 8
-- Buy flourish: the fade-and-shrink after a purchase.
local BUY_FADE_SECONDS = 0.4
-- Stall-display particle tints — the RelicParticleAttachment set ONLY
-- (nameplate text and the RarityGlow PointLight keep the standard
-- palettes). Rarities not listed fall back to RarityColors:Get.
-- The merchant's price, on the stall nameplate's owner line. Gold, the
-- same colour the price already uses on the relic card's description.
local STALL_PRICE_COLOR = Color3.fromRGB(255, 170, 0)
local STALL_PRICE_FORMAT = "(%d Coins)"

local STALL_PARTICLE_COLORS = {
	[ItemRarity.Rare] = Color3.fromRGB(55, 98, 255),
	[ItemRarity.Epic] = Color3.fromRGB(81, 0, 255),
}

--[ Controller ]--

local EventController = Knit.CreateController({
	Name = "EventController",

	Signals = {
		-- Fired when a merchant dialogue asks for sell mode. The relic
		-- UI wiring (Phase C) consumes this: force-open + light the Sell
		-- button until the UI closes.
		OnSellModeRequested = Signal.new(),
		-- The Forge's twin: force-open the tray with the REFORGE button
		-- lit instead. Only one of the two modes is ever live at a time
		-- (the events cannot overlap — each locks the player in its own
		-- cutscene).
		OnReforgeModeRequested = Signal.new(),
	},

	-- Read by dialogue-graph Conditions. "fail" | "success" | "dead" |
	-- "done" | "invalid" | nil (no pull yet this conversation).
	LastSwordResult = nil :: string?,
	-- true once this conversation accepted the shrine's bargain — gates
	-- the leave-path twin of the "Bargain is struck" node.
	ShrineAccepted = false,
	-- "drink" | "attune" | nil — the fountain choice latched THIS
	-- conversation. Gates the outcome twins in the graph; the server call
	-- fires AT THE CHOICE (one of the few events that pays out
	-- mid-dialogue). nil = left / no choice.
	FountainChoice = nil :: string?,
	-- true when the server says this player already spent the active
	-- fountain — fetched by the graph's opening node so the conversation
	-- routes to the "waters lie still" line instead of the choice.
	FountainSpent = false,
	-- "Spirit" | "Power" | "Fortune" | nil -- the Greater Blessing latched
	-- THIS conversation; the server call fires at the choice, like the
	-- fountain. GreaterShrineSpent mirrors FountainSpent.
	GreaterShrineChoice = nil :: string?,
	-- The blessing ids the server rolled for this player at the active
	-- statue. The graph authors a row per blessing and asks
	-- IsBlessingOffered which of them may show.
	GreaterShrineOffer = {} :: { string },
	GreaterShrineSpent = false,
	-- true once this conversation took the Merchant's sell branch — keeps
	-- the ready node from playing as the sell node's walk-forward.
	MerchantSellChosen = false,
	-- Relics sold during the CURRENT merchant conversation — the
	-- post-sale nodes branch on it (sold vs browsed-and-left).
	SoldRelicsThisSession = 0,
	-- true from "sell relics" chosen until the tray closes — the
	-- dialogue is parked on its "..." node for exactly this window.
	_sellFlowActive = false,
	-- FORGE. ForgeReforgeChosen gates the leave-line the same way
	-- MerchantSellChosen gates the merchant's ready-line; ReforgeDone
	-- splits the two outcome twins (swapped vs stepped back).
	ForgeReforgeChosen = false,
	ReforgeDone = false,
	_reforgeFlowActive = false,
	-- COFFIN (CoffinEvent graph). CoffinStatus / CoffinDeclined are fetched
	-- by the opening node ("idle" | "running" | "won" | "failed" |
	-- "expired"); CoffinConfirmVisited flags the confirm node so the accept
	-- twin can tell a jump from a walk-forward; CoffinAccepted gates the
	-- decline twin off the accept path. All reset on close except
	-- CoffinDeclined, which the close handler reads to consume the prompt.
	CoffinStatus = "idle",
	CoffinDeclined = false,
	CoffinConfirmVisited = false,
	CoffinAccepted = false,
	-- [merchant model] = true once this player took "I want to leave" —
	-- the option hides on later visits. Weak keys: the models die with
	-- the floor.
	_merchantReadyModels = setmetatable({}, { __mode = "k" }),

	_cutsceneActive = false,
	_playerControls = nil,

	-- [prompt] = { pedestal, merchant, index, clone } — this client's
	-- live pedestals. Everything about them is LOCAL: what shows, the
	-- price on the tag, and whether the stand is already empty.
	_pedestalsByPrompt = {},
	-- [roomId] = slots from GetMerchantStalls (relic, price, sold, cframe).
	_stalls = {},
	-- ["roomId:index"] = the rendered clone on that stand.
	_stallClones = {},
	-- clones being animated: [model] = { base = CFrame, phase = number }
	_floatingClones = {},
	-- [roomModel] = connection — pending fog-reveal listeners for shop
	-- rooms whose stock unlocked before the room itself was revealed.
	_revealWatchers = {},
})

--[ Private ]--

function EventController:_getHumanoid(): Humanoid?
	local character = Players.LocalPlayer.Character
	return character and character:FindFirstChildOfClass("Humanoid")
end

-- Same lazy PlayerModule resolution as EncounterIntroController.
function EventController:_getControls()
	if self._playerControls then
		return self._playerControls
	end
	local playerScripts = Players.LocalPlayer:FindFirstChild("PlayerScripts")
	local moduleScript = playerScripts and playerScripts:FindFirstChild("PlayerModule")
	if not moduleScript then
		return nil
	end
	local ok, playerModule = pcall(require, moduleScript)
	if not ok then
		return nil
	end
	self._playerControls = playerModule:GetControls()
	return self._playerControls
end

--[ Public — cutscene ]--

-- The event graphs whose beat MOVES the player's health or mana. Only
-- these keep the vitals billboards up, and then only the viewer's own
-- (see Attributes.EventVitals). Keyed by DialogueGraph attribute value.
local VITALS_EVENT_GRAPHS = {
	SwordStone = true,
	CursedShrine = true,
	HealingFountain = true,
}

-- The Sword / Shrine opening beat, called from each graph's first
-- PreAction. Controls off + bars up — nothing else: facing the event
-- is free (the dialogue session's face-watcher lerps the character
-- toward the model every frame), and there is deliberately no walk-to
-- — the player bargains from wherever they stood.
function EventController:BeginEventCutscene()
	if self._cutsceneActive then
		return
	end
	self._cutsceneActive = true

	local character = Players.LocalPlayer.Character
	local humanoid = self:_getHumanoid()

	local controls = self:_getControls()
	if controls then
		controls:Disable()
	end
	if humanoid then
		humanoid:Move(Vector3.zero, false)
	end
	if character then
		character:SetAttribute(Attributes.CutscenePlaying, true)
		-- Marks this as an EVENT cutscene, not an encounter one.
		character:SetAttribute(Attributes.EventCutscene, true)
		-- ...and, for the three beats that MOVE health / mana, keeps THIS
		-- player's vitals billboards up through it. Resolved from the model
		-- being talked to: this runs from node 1's PreAction, so the session
		-- is already open (the same window MarkMerchantReady relies on).
		local model = DialogueBillboardInterface and DialogueBillboardInterface:GetActiveDialogueModel()
		local graph = model and model:GetAttribute("DialogueGraph")
		if graph and VITALS_EVENT_GRAPHS[graph] then
			character:SetAttribute(Attributes.EventVitals, true)
		end
	end
	if CutsceneController then
		CutsceneController:CancelActiveAbility(true)
	end
	if CinematicInterfaceController then
		CinematicInterfaceController.Signals.OnCinematicStart:Fire()
	end
end

-- Safe from any state; runs on EVERY dialogue close while a cutscene is
-- active, so leave / give up / death / success all tear down the same way.
function EventController:EndEventCutscene()
	if not self._cutsceneActive then
		return
	end
	self._cutsceneActive = false

	-- HANDOFF, not release: when an encounter cutscene owns the stage
	-- (its teleport is exactly what closes an open event dialogue),
	-- re-enabling controls and clearing CutscenePlaying here would let
	-- the player roam the boss intro and drop its cinematic bars. The
	-- encounter's own unlock restores everything when it ends.
	if EncounterIntroController and EncounterIntroController:IsStageLocked() then
		-- The encounter owns the stage now, so this is no longer an EVENT
		-- cutscene — drop the marker (CutscenePlaying stays up, and the
		-- boss intro's own rules hide the bars again).
		local handoffCharacter = Players.LocalPlayer.Character
		if handoffCharacter then
			handoffCharacter:SetAttribute(Attributes.EventCutscene, nil)
			handoffCharacter:SetAttribute(Attributes.EventVitals, nil)
		end
		return
	end

	local controls = self:_getControls()
	if controls then
		controls:Enable()
	end
	local character = Players.LocalPlayer.Character
	if character then
		character:SetAttribute(Attributes.CutscenePlaying, false)
		character:SetAttribute(Attributes.EventCutscene, nil)
		character:SetAttribute(Attributes.EventVitals, nil)
	end
	if CinematicInterfaceController then
		CinematicInterfaceController.Signals.OnCinematicEnd:Fire()
	end
end

--[ Public — graph hooks ]--

-- One server pull attempt. Yields; the graph's "You grip the hilt..."
-- node calls this from its PreAction, and the three nodes after it read
-- LastSwordResult from their Conditions.
function EventController:DoSwordPull()
	local model = DialogueBillboardInterface and DialogueBillboardInterface:GetActiveDialogueModel()
	if not model then
		self.LastSwordResult = "invalid"
		return
	end
	local ok, result = pcall(function()
		return EventService:AttemptSwordPull(model):expect()
	end)
	self.LastSwordResult = if ok then result else "invalid"
end

-- LOCAL success dressing: every ParticleEmitter under the sword stops
-- emitting, every Light fades out over a second then disables. Local
-- because the event is per-player — a teammate who hasn't pulled yet
-- still sees the sword shining.
function EventController:PlaySwordSuccessVFX()
	local model = DialogueBillboardInterface and DialogueBillboardInterface:GetActiveDialogueModel()
	if not model then
		return
	end
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("ParticleEmitter") then
			descendant.Enabled = false
		elseif descendant:IsA("Light") then
			local tween = TweenService:Create(descendant, LIGHT_FADE_INFO, { Brightness = 0 })
			tween.Completed:Once(function()
				descendant.Enabled = false
			end)
			tween:Play()
		end
	end
end

-- The Shrine's accept path. Latches the flag (hides the leave twin)
-- and YIELDS through the server bargain RIGHT HERE — the health cost
-- lands mid-dialogue, under the billboard. The cursed-relic fan is
-- still deferred: the server queues it, and the close-path
-- MarkEventInteracted releases it once the bars are down.
function EventController:AcceptShrineCurse()
	self.ShrineAccepted = true
	local model = DialogueBillboardInterface and DialogueBillboardInterface:GetActiveDialogueModel()
	if not model then
		return
	end
	pcall(function()
		EventService:AcceptCurse(model):expect()
	end)
end

-- Healing Fountain, opening node. Starts the standard event cutscene,
-- resets this conversation's choice, and YIELDS on the server's spent
-- check (the sword's pull sets the precedent for a yielding PreAction) so
-- the graph's redirect Conditions can route around a spent fountain.
function EventController:BeginFountainDialogue()
	self:BeginEventCutscene()
	self.FountainChoice = nil

	local model = DialogueBillboardInterface and DialogueBillboardInterface:GetActiveDialogueModel()
	if not model then
		self.FountainSpent = true
		return
	end
	local ok, spent = pcall(function()
		return EventService:IsFountainSpent(model):expect()
	end)
	self.FountainSpent = if ok then spent == true else true
end

-- The two choices latch the flag AND yield through the server right
-- here — the fountain is one of the few events whose payoff lands
-- DURING the dialogue: the outcome line narrates a heal / attunement
-- that has already happened.
function EventController:ChooseFountainDrink()
	self.FountainChoice = "drink"
	local model = DialogueBillboardInterface and DialogueBillboardInterface:GetActiveDialogueModel()
	if not model then
		return
	end
	pcall(function()
		EventService:DrinkFromFountain(model):expect()
	end)
end

function EventController:ChooseFountainAttune()
	self.FountainChoice = "attune"
	local model = DialogueBillboardInterface and DialogueBillboardInterface:GetActiveDialogueModel()
	if not model then
		return
	end
	pcall(function()
		EventService:AttuneToFountain(model):expect()
	end)
end

-- Greater Shrine, opening node: same shape as the fountain's. The bars
-- stay DOWN for this one (it is not in VITALS_EVENT_GRAPHS): the shrine
-- heals through the orbs it drops, not directly.
function EventController:BeginGreaterShrineDialogue()
	self:BeginEventCutscene()
	self.GreaterShrineChoice = nil

	local model = DialogueBillboardInterface and DialogueBillboardInterface:GetActiveDialogueModel()
	if not model then
		self.GreaterShrineSpent = true
		return
	end
	local ok, spent = pcall(function()
		return EventService:IsGreaterShrineSpent(model):expect()
	end)
	self.GreaterShrineSpent = if ok then spent == true else true

	local gotOffer, offer = pcall(function()
		return EventService:GetGreaterShrineOffer(model):expect()
	end)
	self.GreaterShrineOffer = if gotOffer and type(offer) == "table" then offer else {}

	-- Nothing left to offer (every blessing taken this run) reads as
	-- spent: the same line covers both, and without this the choice node
	-- would play with no rows under it.
	if #self.GreaterShrineOffer == 0 then
		self.GreaterShrineSpent = true
	end
end

-- Row gate for the dialogue: every blessing has a row, only the ones
-- in this player's rolled offer pass.
function EventController:IsBlessingOffered(blessingId: string): boolean
	for _, id in self.GreaterShrineOffer do
		if id == blessingId then
			return true
		end
	end
	return false
end

-- One of the blessings: latch, and yield through the server --
-- the stat lands NOW, mid-dialogue, and the screen pulses in the
-- blessing's colour. The Healing Orbs and the statue's dimming both
-- wait for the close path.
function EventController:ChooseGreaterBlessing(blessing: string)
	self.GreaterShrineChoice = blessing
	local model = DialogueBillboardInterface and DialogueBillboardInterface:GetActiveDialogueModel()
	if not model then
		return
	end
	local ok, result = pcall(function()
		return EventService:ChooseGreaterBlessing(model, blessing):expect()
	end)

	-- The pulse is the blessing's own, from the config. An entry with no
	-- pulseColor (Spirit) fires nothing: raising Max Health carries
	-- current health up with it and HumanoidStateController's health
	-- watcher already pulses green, so a second pulse would stutter.
	local config = GreaterShrineData.ByID[blessing]
	local pulse = config and config.pulseColor
	if ok and result == "ok" and pulse and ScreenGradientInterfaceController then
		ScreenGradientInterfaceController.Signals.OnPulseGradient:Fire(pulse)
	end
end

-- The used look, LOCAL to this client (the spend is per player, so a
-- teammate who has not chosen still sees it lit). Same dressing as the
-- sword's success: every emitter and beam UNDER THE STATUE stops (live
-- particles die out on their own), every light fades to nothing over
-- LIGHT_FADE_SECONDS and then disables. Nothing outside the model is
-- touched -- the room's own torches and lights are not the shrine's.
function EventController:_dimGreaterShrine(model: Instance)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("ParticleEmitter") or descendant:IsA("Beam") then
			descendant.Enabled = false
		elseif descendant:IsA("Light") then
			local tween = TweenService:Create(descendant, LIGHT_FADE_INFO, { Brightness = 0 })
			tween.Completed:Once(function()
				descendant.Enabled = false
			end)
			tween:Play()
		end
	end
end

-- Merchant's "sell" option: force-open the relic tray in sell mode and
-- park the dialogue on its "..." node until the tray closes.
function EventController:RequestSellMode()
	self.SoldRelicsThisSession = 0
	self._sellFlowActive = true
	self.Signals.OnSellModeRequested:Fire()
end

-- Does the local player carry ANY relic? The Forge's "Reforge" option
-- is greyed on false — visible, so the player can see what the anvil
-- is for, but unselectable because there is nothing to feed it.
function EventController:HasAnyRelics(): boolean
	local relicController = Knit.GetController("RelicController")
	local owned = relicController and relicController:GetRelicsFromUserId(Players.LocalPlayer.UserId)
	if not owned then
		return false
	end
	for _, count in owned do
		if typeof(count) == "number" and count > 0 then
			return true
		end
	end
	return false
end

-- The Forge's "Reforge" option: force the tray open with the Reforge
-- button lit and park the dialogue on its "..." node. Unlike the
-- merchant's sell session, closing the tray does NOT advance — the
-- blacksmith waits for a relic, and the player's own click on the box
-- is the only other way forward (node 2's PostAction).
function EventController:RequestReforgeMode()
	self.ForgeReforgeChosen = true
	self.ReforgeDone = false
	self._reforgeFlowActive = true
	self.Signals.OnReforgeModeRequested:Fire()
end

-- The tray's Reforge button lands here. On success the relic is already
-- gone server-side and the replacement is QUEUED (it pops from the
-- blacksmith when the conversation closes), so this closes the tray and
-- drives the dialogue forward itself — the flow flag is cleared FIRST so
-- the advance's PostAction cannot double-close.
function EventController:ReforgeRelicViaForge(relicName: string): boolean
	local model = DialogueBillboardInterface and DialogueBillboardInterface:GetActiveDialogueModel()
	if not model then
		return false
	end
	local ok, result = pcall(function()
		return EventService:ReforgeRelic(model, relicName):expect()
	end)
	if not ok or (result ~= "reforged" and result ~= "none") then
		return false
	end

	-- "none" still consumed the relic (nothing usable left at that
	-- rarity); the graph's success line covers both — the difference is
	-- only whether anything pops out at the end.
	self.ReforgeDone = true
	self._reforgeFlowActive = false

	local relicInterface = Knit.GetController("RelicInterfaceController")
	if relicInterface then
		relicInterface.Signals.SetVisible:Fire(false)
	end
	if DialogueBillboardInterface then
		-- external: the "..." node refuses the player's own click.
		DialogueBillboardInterface:OnAdvanceRequested(true)
	end
	return true
end

-- The tray closed during a FORGE session. Mirrors OnSellUIClosed: the
-- blacksmith was parked on "...", so closing the window is the player
-- saying "not this time" and moves the conversation to its backed-out
-- line. No-ops after a successful reforge, which already advanced.
function EventController:OnReforgeUIClosed()
	if not self._reforgeFlowActive then
		return
	end
	self._reforgeFlowActive = false
	if DialogueBillboardInterface then
		DialogueBillboardInterface:OnAdvanceRequested(true)
	end
end

-- The "..." node's PostAction: the player advanced BY HAND without
-- feeding the anvil. Clear the flow first, then close the tray — the
-- graph's cancel twin plays off ReforgeDone still being false.
function EventController:EndReforgeFlowFromDialogue()
	if not self._reforgeFlowActive then
		return
	end
	self._reforgeFlowActive = false
	local relicInterface = Knit.GetController("RelicInterfaceController")
	if relicInterface then
		relicInterface.Signals.SetVisible:Fire(false)
	end
end

-- The tray's sell button lands here (via RelicInterfaceController's
-- props) so sales are COUNTED for the merchant's parting line.
function EventController:SellRelicViaMerchant(relicName: string): number
	local ok, price = pcall(function()
		return EventService:SellRelic(relicName):expect()
	end)
	if not ok or type(price) ~= "number" then
		return 0
	end
	if price > 0 then
		self.SoldRelicsThisSession += 1
	end
	return price
end

-- The tray closed (toggle, scope, or the dialogue's own early-advance
-- force-close). If the merchant is waiting on "...", advance him — the
-- engine then resolves the sold / browsed-and-left node off the count.
function EventController:OnSellUIClosed()
	if not self._sellFlowActive then
		return
	end
	self._sellFlowActive = false
	if DialogueBillboardInterface then
		-- external: the "..." node refuses the player's own click.
		DialogueBillboardInterface:OnAdvanceRequested(true)
	end
end

-- The "..." node's PostAction: the player advanced the dialogue BY HAND
-- while the tray was still open. Clear the flow FIRST (so the tray's
-- close notification cannot double-advance), then close the tray.
function EventController:EndSellFlowFromDialogue()
	if not self._sellFlowActive then
		return
	end
	self._sellFlowActive = false
	local relicInterface = Knit.GetController("RelicInterfaceController")
	if relicInterface then
		relicInterface.Signals.SetVisible:Fire(false)
	end
end

-- Merchant's "I'm ready to continue": counts this player toward the
-- event door's early-open. Called from the graph's PostAction, which
-- runs BEFORE the close — the active model is still resolvable.
function EventController:MarkMerchantReady()
	local model = DialogueBillboardInterface and DialogueBillboardInterface:GetActiveDialogueModel()
	if model then
		self._merchantReadyModels[model] = true
		task.spawn(function()
			pcall(function()
				EventService:MarkEventInteracted(model):expect()
			end)
		end)
	end
end

-- Read by the merchant graph: hides "I want to leave" once this player
-- has taken it at the merchant being talked to.
function EventController:HasMarkedMerchantReady(): boolean
	local model = DialogueBillboardInterface and DialogueBillboardInterface:GetActiveDialogueModel()
	return model ~= nil and self._merchantReadyModels[model] == true
end

--[ Coffin ]--

-- Opening node: cutscene up, then fetch where the offer stands for THIS
-- player so the graph routes (idle offer / running / over / declined).
function EventController:BeginCoffinDialogue()
	self:BeginEventCutscene()
	self.CoffinStatus = "idle"
	self.CoffinDeclined = false
	self.CoffinConfirmVisited = false
	self.CoffinAccepted = false
	local model = DialogueBillboardInterface and DialogueBillboardInterface:GetActiveDialogueModel()
	if not model or not CoffinEventService then
		self.CoffinStatus = "expired"
		return
	end
	local ok, state = pcall(function()
		return CoffinEventService:GetState(model):expect()
	end)
	if ok and type(state) == "table" then
		self.CoffinStatus = state.status or "expired"
		self.CoffinDeclined = state.declined == true
	else
		self.CoffinStatus = "expired"
	end
end

-- Confirm node's PostAction (either option).
function EventController:MarkCoffinConfirmVisited()
	self.CoffinConfirmVisited = true
end

-- Accept twin's PreAction: yields on the server, which starts the
-- challenge for the room. A refusal (someone was first) is fine — the
-- server's cancel closes this conversation either way.
function EventController:AcceptCoffin()
	self.CoffinAccepted = true
	local model = DialogueBillboardInterface and DialogueBillboardInterface:GetActiveDialogueModel()
	if not model or not CoffinEventService then
		return
	end
	pcall(function()
		CoffinEventService:Accept(model):expect()
	end)
end

-- Decline node's PostAction. Runs BEFORE the close, so the model is
-- still resolvable; the close handler consumes the prompt off the flag.
function EventController:DeclineCoffin()
	self.CoffinDeclined = true
	local model = DialogueBillboardInterface and DialogueBillboardInterface:GetActiveDialogueModel()
	if not model or not CoffinEventService then
		return
	end
	task.spawn(function()
		pcall(function()
			CoffinEventService:Decline(model):expect()
		end)
	end)
end

-- The masked-button toast, through the same pipeline server-sent
-- notifications ride.
function EventController:ShowBlockedActionNotification()
	UserNotificationSystem:ShowNotification({
		titleText = "Unavailable",
		titleTextFont = Enum.Font.SourceSansBold,
		titleTextColor3 = Color3.fromRGB(255, 92, 92),
		titleTextTransparency = 0,

		text = "You cannot perform this action right now",
		textFont = Enum.Font.SourceSansBold,
		textColor3 = Color3.fromRGB(255, 255, 255),
		textTransparency = 0,
	})
end

--[ Private — merchant pedestals ]--

-- One tagged pedestal comes online: resolve its shop, fetch THIS
-- player's stock (once per merchant — the server caches the roll), and
-- dress the stand: floating relic clone + priced prompt. Yields.
-- Fetch + render every SERVABLE merchant stall (rooms whose preceding
-- fight has started — the server withholds locked rooms). Called on
-- the dungeon-generated signal, on every stock-unlock signal, and once
-- at start; never on streaming.
function EventController:RefreshMerchantStalls()
	local ok, stalls = pcall(function()
		return EventService:GetMerchantStalls():expect()
	end)
	if not ok or type(stalls) ~= "table" then
		warn("[EventController] GetMerchantStalls failed: " .. tostring(stalls))
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

	local rendered = 0
	for _, stall in stalls do
		self._stalls[stall.roomId] = stall.slots

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
	end
	print(("[EventController] Rendered %d merchant stall relic(s)"):format(rendered))
end

-- One-shot listener: when a fogged shop room is revealed, re-fetch and
-- render its stands. Keyed per model so repeated refreshes while the
-- room is still dark do not stack listeners.
function EventController:_watchRoomReveal(roomModel: Model)
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
function EventController:_renderStallSlot(roomId: number, index: number, slot: any): boolean
	local rarity = RelicData[slot.relicName] and RelicData[slot.relicName].rarity
	local template = rarity and getRelicModelTemplate(slot.relicName, rarity)
	if not template then
		warn(
			("[EventController] No model template for stall relic '%s' (%s)"):format(
				tostring(slot.relicName),
				tostring(rarity)
			)
		)
		return false
	end
	local clone = template:Clone()
	for _, part in clone:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = true
			part.CanCollide = false
		end
	end
	if clone.PrimaryPart then
		clone.PrimaryPart.Transparency = 1
	end
	clone:PivotTo(slot.cframe)
	clone:ScaleTo(PEDESTAL_BASE_SCALE)

	-- VENDING-DROP PARITY: the same nameplate, rarity glow, and dim
	-- membership a machine drop gets. The tag + OwnerId attribute are
	-- what let RelicRenderController's shared dim treat these clones as
	-- family; nothing server-side ever sees them.
	local rarityColor = RarityColors:Get(rarity)
	if clone.PrimaryPart then
		local nameplate = ReplicatedStorage.GameAssets.BillboardGuis.RelicName:Clone()
		nameplate.Adornee = clone.PrimaryPart
		nameplate.Frame.NameText.Text = slot.relicName
		nameplate.Frame.RarityText.Text = rarity
		nameplate.Frame.RarityText.TextColor3 = rarityColor
		-- Same prefab as a dropped relic's nameplate, but a stall relic has
		-- no owner — so the line carries the PRICE in gold instead. Passing
		-- an override also keeps the prefab's authored placeholder from
		-- showing, which is what the nil did before.
		applyOwnerLabel(nameplate.Frame, nil, {
			text = STALL_PRICE_FORMAT:format(slot.price or 0),
			color = STALL_PRICE_COLOR,
		})
		if ScreenSizeController and ScreenSizeController:GetScreenSizeData().name == ScreenSizes.Mobile then
			nameplate.Frame.NameText.TextSize = 12
			nameplate.Frame.RarityText.TextSize = 10
		end
		nameplate.Parent = clone.PrimaryPart

		local glow = Instance.new("PointLight")
		glow.Name = GLOW_NAME
		glow.Color = RarityColors:GetGlow(rarity)
		glow.Brightness = GLOW_BRIGHTNESS
		glow.Range = GLOW_RANGE
		glow.Shadows = true
		glow.Parent = clone.PrimaryPart

		-- The authored sparkle set (RelicParticleAttachment: Layer /
		-- Spark / Shine) rides the template's PrimaryPart; real drops tint
		-- it per rarity (DropService) and move it onto the Handle (Relic
		-- component). Mirror both — the shared dim pass reads it off the
		-- Handle, and the untinted set doesn't match the drop look.
		local particleAttachment = clone.PrimaryPart:FindFirstChild("RelicParticleAttachment")
		if particleAttachment then
			local particleColor = STALL_PARTICLE_COLORS[rarity] or rarityColor
			for _, particle in particleAttachment:GetChildren() do
				if particle:IsA("ParticleEmitter") then
					particle.Color = ColorSequence.new(particleColor)
				end
			end
			local handle = clone:FindFirstChild("Handle")
			if handle then
				particleAttachment.Parent = handle
			end
		end
	end
	clone:AddTag("ShopRelicDisplay")
	clone:SetAttribute("OwnerId", Players.LocalPlayer.UserId)

	local ignoreFolder = workspace:FindFirstChild("IgnoreInstances")
	local spellsFolder = ignoreFolder and ignoreFolder:FindFirstChild("MagicSpells")
	clone.Parent = spellsFolder or workspace
	self._floatingClones[clone] = {
		base = slot.cframe,
		phase = math.random() * math.pi * 2,
		scale = PEDESTAL_BASE_SCALE,
		targetScale = PEDESTAL_BASE_SCALE,
	}
	self._stallClones[roomId .. ":" .. index] = clone
	return true
end

-- A tagged pedestal streamed in: wire its PROMPT only (the display never
-- waited for it). Stall data is a generation product, so the wait below
-- is a join-order formality, bounded by the room's lifetime.
function EventController:_wirePedestal(pedestal: Instance)
	local interactables = pedestal.Parent
	local room = interactables and interactables.Parent
	local roomId = room and room:GetAttribute("RoomId")
	local index = tonumber(string.match(pedestal.Name, "%d+$"))
	if not roomId or not index then
		warn(
			("[EventController] Pedestal '%s': missing RoomId attribute or trailing number"):format(
				pedestal:GetFullName()
			)
		)
		return
	end

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
		return -- pedestal or room despawned before its prompt replicated
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

	while not self._stalls[roomId] and room.Parent do
		task.wait(0.25)
	end
	local slots = self._stalls[roomId]
	local slot = slots and slots[index]
	if not slot or slot.sold then
		prompt.Enabled = false
		return
	end

	-- The SAME prompt contract the vending-machine relic drops use
	-- (Client/Components/Relic.lua), so the place's custom prompt card
	-- renders name + full description here too:
	--   ActionText = relic name, ObjectText = rich description,
	--   Rarity/Style attributes size and tint the card.
	-- The price rides the card's UserText slot (gold), the same line that
	-- carries the owner's name on a dropped relic. All local writes: every
	-- player sees their own stock and price.
	local description = getRelicDescription(Players.LocalPlayer, slot.relicName) or "No description available."

	prompt.ActionText = slot.relicName
	prompt.ObjectText = description
	prompt.Style = Enum.ProximityPromptStyle.Custom
	prompt.UIOffset = Vector2.new(0, 60)

	local promptStyle = "RelicSmall"
	local descriptionLength = string.len(string.gsub(description, "<[^>]+>", ""))
	if descriptionLength > 34 and descriptionLength <= 62 then
		promptStyle = "RelicMedium"
	elseif descriptionLength > 62 then
		promptStyle = "RelicLarge"
	end
	local rarity = RelicData[slot.relicName] and RelicData[slot.relicName].rarity
	prompt:SetAttribute("Rarity", rarity)
	prompt:SetAttribute("Style", promptStyle)
	prompt:SetAttribute("UserText", STALL_PRICE_FORMAT:format(slot.price))
	prompt:SetAttribute("UserTextColor", STALL_PRICE_COLOR)
	self._pedestalsByPrompt[prompt] = {
		pedestal = pedestal,
		roomId = roomId,
		index = index,
	}
	prompt.Enabled = true
end

-- Pulls the shared hover highlight off a doomed clone. Destroying the
-- clone with the highlight still inside LOCKS the highlight's Parent
-- ("The Parent property of PedestalRelicHighlight is locked"), which
-- would break every later pedestal hover for the whole session.
function EventController:_rescuePedestalHighlight(clone: Model)
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
function EventController:_playBuyFlourish(clone: Model)
	self._floatingClones[clone] = nil

	local relicName = clone.Name
	local rarity = RelicData[relicName] and RelicData[relicName].rarity
	if ScreenGradientInterfaceController and rarity then
		ScreenGradientInterfaceController.Signals.OnPulseGradient:Fire(RarityColors:Get(rarity))
	end

	-- Vending-pickup parity: the RelicPickup chime and the rarity-tinted
	-- Collected burst. Real drops carry the attachment already (DropService
	-- adds + tints it); stall clones are raw templates, so it's cloned and
	-- tinted here with the same palette (RarityColors:Get).
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
		local collectedTemplate = ReplicatedStorage.GameAssets.Particles:FindFirstChild("Collected")
		if collectedTemplate and rarity then
			local collected = collectedTemplate:Clone()
			for _, emitter in collected:GetChildren() do
				if emitter:IsA("ParticleEmitter") then
					emitter.Color = ColorSequence.new(RarityColors:Get(rarity))
				end
			end
			-- Parent FIRST, burst SECOND — :Emit on an unparented emitter
			-- is silently discarded.
			collected.Parent = handle
			for _, emitter in collected:GetChildren() do
				if emitter:IsA("ParticleEmitter") then
					emitter:Emit(1)
				end
			end
		end
	end

	local nameplate = clone.PrimaryPart and clone.PrimaryPart:FindFirstChild("RelicName")
	if nameplate then
		nameplate:Destroy()
	end
	local glow = clone.PrimaryPart and clone.PrimaryPart:FindFirstChild(GLOW_NAME)
	if glow then
		TweenService:Create(glow, TweenInfo.new(BUY_FADE_SECONDS), { Brightness = 0 }):Play()
	end
	for _, part in clone:GetDescendants() do
		if part:IsA("BasePart") and part.Transparency < 1 then
			TweenService:Create(part, TweenInfo.new(BUY_FADE_SECONDS), { Transparency = 1 }):Play()
		elseif part:IsA("ParticleEmitter") then
			part.Enabled = false
		end
	end
	-- +1s past the fade so the pickup chime and Collected burst finish
	-- before the (already invisible) clone is collected.
	task.delay(BUY_FADE_SECONDS + 1, function()
		clone:Destroy()
	end)
end

-- A pedestal prompt fired for the local player: try the buy. "bought"
-- clears the stand locally; "poor" already showed the server's "Not
-- enough coins" indicator; anything else quietly re-arms.
function EventController:_onPedestalPrompt(prompt: ProximityPrompt)
	local record = self._pedestalsByPrompt[prompt]
	if not record then
		return
	end
	local ok, result = pcall(function()
		return EventService:BuyMerchantRelic(record.roomId, record.index):expect()
	end)
	if ok and (result == "bought" or result == "sold") then
		prompt.Enabled = false
		self._pedestalsByPrompt[prompt] = nil
		local key = record.roomId .. ":" .. record.index
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

--[ Lifecycle ]--

function EventController:KnitInit() end

function EventController:KnitStart()
	EventService = Knit.GetService("EventService")
	CoffinEventService = Knit.GetService("CoffinEventService")
	RelicRenderController = Knit.GetController("RelicRenderController")
	ScreenSizeController = Knit.GetController("ScreenSizeController")
	ScreenGradientInterfaceController = Knit.GetController("ScreenGradientInterfaceController")
	EncounterIntroController = Knit.GetController("EncounterIntroController")
	DialogueBillboardInterface = Knit.GetController("DialogueBillboardInterface")
	CinematicInterfaceController = Knit.GetController("CinematicInterfaceController")
	CutsceneController = Knit.GetController("CutsceneController")

	-- The server closes every coffin conversation when one player accepts
	-- (or the offer expires). Only OUR open one with THAT coffin.
	CoffinEventService.OnDialogueCancelled:Connect(function(coffin: Model)
		if DialogueBillboardInterface and DialogueBillboardInterface:GetActiveDialogueModel() == coffin then
			DialogueBillboardInterface:ForceClose()
		end
	end)

	-- Per-conversation state resets and cutscene teardown ride the ONE
	-- close path every exit funnels through.
	DialogueBillboardInterface.Signals.CloseDialogue:Connect(function(model: Model?)
		-- Shrine cost and fountain gifts already landed mid-dialogue (the
		-- graphs' PreActions yield through the server). Only the shrine's
		-- cursed-relic FAN is still deferred — the server queued it, and
		-- MarkEventInteracted below releases it. The fountain flags are
		-- captured before the reset — the door section reads them.
		local fountainChoice = self.FountainChoice
		local fountainSpent = self.FountainSpent
		local greaterShrineChoice = self.GreaterShrineChoice
		local greaterShrineSpent = self.GreaterShrineSpent
		local coffinDeclined = self.CoffinDeclined
		local coffinStatus = self.CoffinStatus
		self.LastSwordResult = nil
		self.ShrineAccepted = false
		self.FountainChoice = nil
		self.FountainSpent = false
		self.GreaterShrineChoice = nil
		self.GreaterShrineSpent = false
		self.GreaterShrineOffer = {}
		self.MerchantSellChosen = false
		self.SoldRelicsThisSession = 0
		self.ForgeReforgeChosen = false
		self.ReforgeDone = false
		self.CoffinStatus = "idle"
		self.CoffinDeclined = false
		self.CoffinConfirmVisited = false
		self.CoffinAccepted = false
		-- Walk-away mid-sale: the conversation died while the tray was
		-- open. Close the tray too, or sell mode outlives its merchant.
		-- Walk-away mid-reforge: same rule as the sale below — the tray
		-- must not outlive the conversation that opened it.
		if self._reforgeFlowActive then
			self._reforgeFlowActive = false
			local relicInterface = Knit.GetController("RelicInterfaceController")
			if relicInterface then
				relicInterface.Signals.SetVisible:Fire(false)
			end
		end
		if self._sellFlowActive then
			self._sellFlowActive = false
			local relicInterface = Knit.GetController("RelicInterfaceController")
			if relicInterface then
				relicInterface.Signals.SetVisible:Fire(false)
			end
		end
		self:EndEventCutscene()

		-- COFFIN: a decline, or a conversation held while the offer was
		-- already running / over, consumes the prompt for THIS client. "Not
		-- yet" leaves it live — the player can come back and accept. (The
		-- server also kills the prompt for everyone once the offer is gone.)
		if model and model:GetAttribute("DialogueGraph") == "CoffinEvent" then
			if coffinDeclined or coffinStatus ~= "idle" then
				for _, descendant in model:GetDescendants() do
					if descendant:IsA("ProximityPrompt") then
						descendant:SetAttribute("EventConsumed", true)
						descendant.Enabled = false
					end
				end
			end
		end

		-- A FINISHED Sword/Shrine conversation counts as interacting with
		-- the event (any exit: leave, give up, accept, success, death).
		-- The Merchant deliberately does NOT count here — only his
		-- "I'm ready to continue" option marks readiness.
		local graph = model and model:GetAttribute("DialogueGraph")

		-- The Greater Shrine sits in the Start chunk, which has no event
		-- door, so it never marks a room interacted. Once a blessing was
		-- taken (or the statue was already spent) this client's prompt goes
		-- dark and the statue dims -- HERE, when the conversation has fully
		-- ended, not at the choice, so the statue stays lit through its own
		-- farewell. A walk-away can come back and choose later.
		--
		-- A choice THIS conversation also drops this player's Healing Orbs
		-- now, with the conversation over. Server-gated, once.
		if graph == "GreaterShrine" and model and (greaterShrineChoice ~= nil or greaterShrineSpent) then
			for _, descendant in model:GetDescendants() do
				if descendant:IsA("ProximityPrompt") then
					descendant:SetAttribute("EventConsumed", true)
					descendant.Enabled = false
				end
			end
			self:_dimGreaterShrine(model)
			if greaterShrineChoice ~= nil then
				task.spawn(function()
					pcall(function()
						EventService:DropGreaterShrineOrbs(model):expect()
					end)
				end)
			end
		end
		-- The Forge marks on EITHER path: reforging finishes it, and
		-- "Leave" is an explicit refusal that opens the door too.
		if graph == "SwordStone" or graph == "CursedShrine" or graph == "HealingFountain" or graph == "Forge" then
			task.spawn(function()
				pcall(function()
					EventService:MarkEventInteracted(model):expect()
				end)
			end)

			-- ONE full interaction per player: a finished Sword / Shrine
			-- conversation consumes the event on THIS client. Local writes
			-- — teammates who have not had their turn still see a live
			-- prompt. The attribute (not just Enabled) is what keeps the
			-- billboard's delayed local re-arm from resurrecting it.
			--
			-- The Fountain differs on ONE point: "Leave" preserves the
			-- choice, so its prompt only goes dark once a choice was
			-- actually made (or the fountain was already spent — a revisit
			-- that played the "waters lie still" line darkens it too). A
			-- walk-away can come back and drink later.
			local consume = graph ~= "HealingFountain" or fountainChoice ~= nil or fountainSpent
			if model and consume then
				-- EVERY prompt under the model, not just the first found:
				-- a model authored with more than one ProximityPrompt would
				-- otherwise keep a live prompt and resurrect the event.
				for _, descendant in model:GetDescendants() do
					if descendant:IsA("ProximityPrompt") then
						descendant:SetAttribute("EventConsumed", true)
						descendant.Enabled = false
					end
				end
			end
		end
	end)

	-- Death while locked (a pull or bargain that killed): the death flow
	-- owns the screen from here, but the controls lock and bars must not
	-- survive into the respawn.
	local function watchCharacter(character: Model)
		local humanoid = character:WaitForChild("Humanoid", 5)
		if humanoid then
			humanoid.Died:Connect(function()
				self:EndEventCutscene()
			end)
		end
	end
	if Players.LocalPlayer.Character then
		task.spawn(watchCharacter, Players.LocalPlayer.Character)
	end
	Players.LocalPlayer.CharacterAdded:Connect(watchCharacter)

	-- Merchant stalls render per ROOM as each unlocks: the server rolls
	-- stock only once the fight before the shop begins (keeps the
	-- unowned filter honest). The generation replay and the immediate
	-- call cover rejoin / late start — both serve whatever is already
	-- unlocked.
	local DungeonService = Knit.GetService("DungeonService")
	DungeonService.OnDungeonGenerated:Connect(function()
		task.spawn(function()
			self:RefreshMerchantStalls()
		end)
	end)
	task.spawn(function()
		self:RefreshMerchantStalls()
	end)

	-- Per-player unlock: YOU just entered a shop, its shelves are now
	-- rollable server-side for you — fetch and render them.
	EventService.OnMerchantStockUnlocked:Connect(function(_roomId: number)
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
	-- Streamed-out pedestals only drop their PROMPT record; the display
	-- clone is generation-scoped and dies in RefreshMerchantStalls when
	-- the floor actually regenerates.
	CollectionService:GetInstanceRemovedSignal(TagList.MerchantPedestal):Connect(function(pedestal)
		for prompt, record in self._pedestalsByPrompt do
			if record.pedestal == pedestal then
				self._pedestalsByPrompt[prompt] = nil
			end
		end
	end)

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
		local clone = self._stallClones[record.roomId .. ":" .. record.index]
		local state = clone and self._floatingClones[clone]
		if not state then
			return
		end
		state.targetScale = PEDESTAL_HOVER_SCALE
		-- The prompt card replaces the nameplate while hovered (drop rule).
		local nameplate = clone.PrimaryPart and clone.PrimaryPart:FindFirstChild("RelicName")
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
		local clone = self._stallClones[record.roomId .. ":" .. record.index]
		local state = clone and self._floatingClones[clone]
		if state then
			state.targetScale = PEDESTAL_BASE_SCALE
		end
		local nameplate = clone and clone.PrimaryPart and clone.PrimaryPart:FindFirstChild("RelicName")
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
	RunService.Heartbeat:Connect(function(deltaTime: number)
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

return EventController
