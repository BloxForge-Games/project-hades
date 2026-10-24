--!strict
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

	The merchant STANDS -- the floating relic displays, their buy prompts
	and the hover / float loops -- are MerchantStallRenderController's.
	This side keeps only the merchant's dialogue: the sell session and
	the ready mark.
]]

--[ Roblox Services ]--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

--[ Imports ]--

local ScreenGradientInterfaceController = require(ReplicatedStorage.Interfaces.ScreenGradientInterfaceController)
local EncounterIntroController = require(ReplicatedStorage.Controllers.EncounterIntroController)
local DialogueBillboardInterface =
	require(ReplicatedStorage.Submodules.Core.Source.Interfaces.DialogueBillboardInterface)
local CinematicInterfaceController =
	require(ReplicatedStorage.Submodules.Core.Source.Interfaces.CinematicInterfaceController)
local CutsceneController = require(ReplicatedStorage.Controllers.CutsceneController)
local relicController = require(ReplicatedStorage.Controllers.RelicController)
local relicInterface = require(ReplicatedStorage.Interfaces.RelicInterfaceController)
local RelicController = require(ReplicatedStorage.Controllers.RelicController)
local RelicInterfaceController = require(ReplicatedStorage.Interfaces.RelicInterfaceController)
local DungeonNetwork = require(ReplicatedStorage.Submodules.Core.Source.Network.Dungeon)
local Signal = require(ReplicatedStorage.Submodules.Core.Packages.Signal)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local GreaterShrineData = require(ReplicatedStorage.Submodules.Core.Shared.Data.GreaterShrineData)
local UserNotificationSystem = require(ReplicatedStorage.Submodules.Core.Libraries.UserNotificationSystem).Controller

--[ Constants ]--

local LIGHT_FADE_SECONDS = 1
local LIGHT_FADE_INFO = TweenInfo.new(LIGHT_FADE_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

--[ Controller ]--

local EventController = {
	Name = "EventController",
	Dependencies = {
		ScreenGradientInterfaceController,
		EncounterIntroController,
		DialogueBillboardInterface,
		CinematicInterfaceController,
		CutsceneController,
		relicController,
		relicInterface,
		RelicController,
		RelicInterfaceController,
	} :: { any },

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
	-- "expired"); CoffinAccepted gates the decline node off the accept
	-- path. All reset on close except CoffinDeclined, which the close
	-- handler reads to consume the prompt.
	CoffinStatus = "idle",
	CoffinDeclined = false,
	CoffinAccepted = false,
	-- [merchant model] = true once this player took "I want to leave" —
	-- the option hides on later visits. Weak keys: the models die with
	-- the floor.
	_merchantReadyModels = setmetatable({}, { __mode = "k" }),

	_cutsceneActive = false,
	_playerControls = nil :: any,
}

--[ Private ]--

function EventController._getHumanoid(_self: typeof(EventController)): Humanoid?
	local character = Players.LocalPlayer.Character
	return character and character:FindFirstChildOfClass("Humanoid")
end

-- Same lazy PlayerModule resolution as EncounterIntroController.
function EventController._getControls(self: typeof(EventController))
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
function EventController.BeginEventCutscene(self: typeof(EventController))
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
function EventController.EndEventCutscene(self: typeof(EventController))
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
function EventController.DoSwordPull(self: typeof(EventController))
	local model = DialogueBillboardInterface and DialogueBillboardInterface:GetActiveDialogueModel()
	if not model then
		self.LastSwordResult = "invalid"
		return
	end
	local ok, result = pcall(function()
		return DungeonNetwork.AttemptSwordPull.Invoke(model)
	end)
	self.LastSwordResult = if ok then result else "invalid"
end

-- LOCAL success dressing: every ParticleEmitter under the sword stops
-- emitting, every Light fades out over a second then disables. Local
-- because the event is per-player — a teammate who hasn't pulled yet
-- still sees the sword shining.
function EventController.PlaySwordSuccessVFX(_self: typeof(EventController))
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
function EventController.AcceptShrineCurse(self: typeof(EventController))
	self.ShrineAccepted = true
	local model = DialogueBillboardInterface and DialogueBillboardInterface:GetActiveDialogueModel()
	if not model then
		return
	end
	pcall(function()
		DungeonNetwork.AcceptCurse.Invoke(model)
	end)
end

-- Healing Fountain, opening node. Starts the standard event cutscene,
-- resets this conversation's choice, and YIELDS on the server's spent
-- check (the sword's pull sets the precedent for a yielding PreAction) so
-- the graph's redirect Conditions can route around a spent fountain.
function EventController.BeginFountainDialogue(self: typeof(EventController))
	self:BeginEventCutscene()
	self.FountainChoice = nil

	local model = DialogueBillboardInterface and DialogueBillboardInterface:GetActiveDialogueModel()
	if not model then
		self.FountainSpent = true
		return
	end
	local ok, spent = pcall(function()
		return DungeonNetwork.IsFountainSpent.Invoke(model)
	end)
	self.FountainSpent = if ok then spent == true else true
end

-- The two choices latch the flag AND yield through the server right
-- here — the fountain is one of the few events whose payoff lands
-- DURING the dialogue: the outcome line narrates a heal / attunement
-- that has already happened.
function EventController.ChooseFountainDrink(self: typeof(EventController))
	self.FountainChoice = "drink"
	local model = DialogueBillboardInterface and DialogueBillboardInterface:GetActiveDialogueModel()
	if not model then
		return
	end
	pcall(function()
		DungeonNetwork.DrinkFromFountain.Invoke(model)
	end)
end

function EventController.ChooseFountainAttune(self: typeof(EventController))
	self.FountainChoice = "attune"
	local model = DialogueBillboardInterface and DialogueBillboardInterface:GetActiveDialogueModel()
	if not model then
		return
	end
	pcall(function()
		DungeonNetwork.AttuneToFountain.Invoke(model)
	end)
end

-- Greater Shrine, opening node: same shape as the fountain's. The bars
-- stay DOWN for this one (it is not in VITALS_EVENT_GRAPHS): the shrine
-- heals through the orbs it drops, not directly.
function EventController.BeginGreaterShrineDialogue(self: typeof(EventController))
	self:BeginEventCutscene()
	self.GreaterShrineChoice = nil

	local model = DialogueBillboardInterface and DialogueBillboardInterface:GetActiveDialogueModel()
	if not model then
		self.GreaterShrineSpent = true
		return
	end
	local ok, spent = pcall(function()
		return DungeonNetwork.IsGreaterShrineSpent.Invoke(model)
	end)
	self.GreaterShrineSpent = if ok then spent == true else true

	local gotOffer, offer = pcall(function()
		return DungeonNetwork.GetGreaterShrineOffer.Invoke(model)
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
function EventController.IsBlessingOffered(self: typeof(EventController), blessingId: string): boolean
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
function EventController.ChooseGreaterBlessing(self: typeof(EventController), blessing: string)
	self.GreaterShrineChoice = blessing
	local model = DialogueBillboardInterface and DialogueBillboardInterface:GetActiveDialogueModel()
	if not model then
		return
	end
	local ok, result = pcall(function()
		return DungeonNetwork.ChooseGreaterBlessing.Invoke({ Statue = model, Blessing = blessing })
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
function EventController._dimGreaterShrine(_self: typeof(EventController), model: Instance)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("ParticleEmitter") or descendant:IsA("Beam") then
			-- Both classes have Enabled; the cast is only because the checker
			-- cannot write a property through a class union.
			(descendant :: any).Enabled = false
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
function EventController.RequestSellMode(self: typeof(EventController))
	self.SoldRelicsThisSession = 0
	self._sellFlowActive = true
	self.Signals.OnSellModeRequested:Fire()
end

-- Does the local player carry ANY relic? The Forge's "Reforge" option
-- is greyed on false — visible, so the player can see what the anvil
-- is for, but unselectable because there is nothing to feed it.
function EventController.HasAnyRelics(_self: typeof(EventController)): boolean
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
function EventController.RequestReforgeMode(self: typeof(EventController))
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
function EventController.ReforgeRelicViaForge(self: typeof(EventController), relicName: string): boolean
	local model = DialogueBillboardInterface and DialogueBillboardInterface:GetActiveDialogueModel()
	if not model then
		return false
	end
	local ok, result = pcall(function()
		return DungeonNetwork.ReforgeRelic.Invoke({ Forge = model, RelicName = relicName })
	end)
	if not ok or (result ~= "reforged" and result ~= "none") then
		return false
	end

	-- "none" still consumed the relic (nothing usable left at that
	-- rarity); the graph's success line covers both — the difference is
	-- only whether anything pops out at the end.
	self.ReforgeDone = true
	self._reforgeFlowActive = false

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
function EventController.OnReforgeUIClosed(self: typeof(EventController))
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
function EventController.EndReforgeFlowFromDialogue(self: typeof(EventController))
	if not self._reforgeFlowActive then
		return
	end
	self._reforgeFlowActive = false
	if relicInterface then
		relicInterface.Signals.SetVisible:Fire(false)
	end
end

-- The tray's sell button lands here (via RelicInterfaceController's
-- props) so sales are COUNTED for the merchant's parting line.
function EventController.SellRelicViaMerchant(self: typeof(EventController), relicName: string): number
	local ok, price = pcall(function()
		return DungeonNetwork.SellRelic.Invoke(relicName)
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
function EventController.OnSellUIClosed(self: typeof(EventController))
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
function EventController.EndSellFlowFromDialogue(self: typeof(EventController))
	if not self._sellFlowActive then
		return
	end
	self._sellFlowActive = false
	if relicInterface then
		relicInterface.Signals.SetVisible:Fire(false)
	end
end

-- Merchant's "I'm ready to continue": counts this player toward the
-- event door's early-open. Called from the graph's PostAction, which
-- runs BEFORE the close — the active model is still resolvable.
function EventController.MarkMerchantReady(self: typeof(EventController))
	local model = DialogueBillboardInterface and DialogueBillboardInterface:GetActiveDialogueModel()
	if model then
		self._merchantReadyModels[model] = true
		task.spawn(function()
			pcall(function()
				DungeonNetwork.MarkEventInteracted.Fire(model)
			end)
		end)
	end
end

-- Read by the merchant graph: hides "I want to leave" once this player
-- has taken it at the merchant being talked to.
function EventController.HasMarkedMerchantReady(self: typeof(EventController)): boolean
	local model = DialogueBillboardInterface and DialogueBillboardInterface:GetActiveDialogueModel()
	return model ~= nil and self._merchantReadyModels[model] == true
end

--[ Coffin ]--

-- Opening node: cutscene up, then fetch where the offer stands for THIS
-- player so the graph routes (idle offer / running / over / declined).
function EventController.BeginCoffinDialogue(self: typeof(EventController))
	self:BeginEventCutscene()
	self.CoffinStatus = "idle"
	self.CoffinDeclined = false
	self.CoffinAccepted = false
	local model = DialogueBillboardInterface and DialogueBillboardInterface:GetActiveDialogueModel()
	if not model then
		self.CoffinStatus = "expired"
		return
	end
	local ok, state = pcall(function()
		return DungeonNetwork.GetCoffinState.Invoke(model)
	end)
	if ok and type(state) == "table" then
		self.CoffinStatus = state.status or "expired"
		self.CoffinDeclined = state.declined == true
	else
		self.CoffinStatus = "expired"
	end
end

-- Confirm node's PostAction (either option).
-- The confirm node's "Open it." option action: asks the server to start
-- the challenge for the room. The model is resolved NOW, while the
-- conversation is still open (the option closes it right after), and
-- the request runs off the click so the close is not held on the round
-- trip. A refusal (someone was first) is fine — the server's cancel
-- reaches every open coffin conversation either way.
function EventController.AcceptCoffin(self: typeof(EventController))
	self.CoffinAccepted = true
	local model = DialogueBillboardInterface and DialogueBillboardInterface:GetActiveDialogueModel()
	if not model then
		return
	end
	task.spawn(function()
		pcall(function()
			DungeonNetwork.AcceptCoffin.Invoke(model)
		end)
	end)
end

-- Decline node's PostAction. Runs BEFORE the close, so the model is
-- still resolvable; the close handler consumes the prompt off the flag.
function EventController.DeclineCoffin(self: typeof(EventController))
	self.CoffinDeclined = true
	local model = DialogueBillboardInterface and DialogueBillboardInterface:GetActiveDialogueModel()
	if not model then
		return
	end
	task.spawn(function()
		pcall(function()
			DungeonNetwork.DeclineCoffin.Fire(model)
		end)
	end)
end

-- The masked-button toast, through the same pipeline server-sent
-- notifications ride.
function EventController.ShowBlockedActionNotification(_self: typeof(EventController))
	UserNotificationSystem:ShowNotification({
		titleText = "Unavailable",
		titleTextFont = Enum.Font.SourceSansBold :: any,
		titleTextColor3 = Color3.fromRGB(255, 92, 92),
		titleTextTransparency = 0,

		text = "You cannot perform this action right now",
		textFont = Enum.Font.SourceSansBold :: any,
		textColor3 = Color3.fromRGB(255, 255, 255),
		textTransparency = 0,
	})
end

--[ Lifecycle ]--

function EventController.Start(self: typeof(EventController))
	-- The server closes every coffin conversation when one player accepts
	-- (or the offer expires). Only OUR open one with THAT coffin.
	DungeonNetwork.CoffinDialogueCancelled.On(function(coffin: Model?)
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
		self.CoffinAccepted = false
		-- Walk-away mid-sale: the conversation died while the tray was
		-- open. Close the tray too, or sell mode outlives its merchant.
		-- Walk-away mid-reforge: same rule as the sale below — the tray
		-- must not outlive the conversation that opened it.
		if self._reforgeFlowActive then
			self._reforgeFlowActive = false
			if relicInterface then
				relicInterface.Signals.SetVisible:Fire(false)
			end
		end
		if self._sellFlowActive then
			self._sellFlowActive = false
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
						DungeonNetwork.DropGreaterShrineOrbs.Invoke(model)
					end)
				end)
			end
		end
		-- The Forge marks on EITHER path: reforging finishes it, and
		-- "Leave" is an explicit refusal that opens the door too.
		if graph == "SwordStone" or graph == "CursedShrine" or graph == "HealingFountain" or graph == "Forge" then
			task.spawn(function()
				pcall(function()
					DungeonNetwork.MarkEventInteracted.Fire(model)
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
		local humanoid = character:WaitForChild("Humanoid", 5) :: Humanoid?
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
end

return EventController
