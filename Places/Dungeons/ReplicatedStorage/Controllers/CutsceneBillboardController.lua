--[[
	Module: CutsceneBillboardController.lua
	Description:
	Empties the world of FLOATING UI for the length of a magic cutscene
	(Susanoo, Domain Expansion, any magic with a MagicData.cutscene index).
	A cinematic framed on your character reads as a cinematic right up until
	a relic label, a mob health bar and three damage numbers drift across it.

	WHAT GOES: every BillboardGui on this client -- relic and rune labels,
	gear drop labels, chest and vending-machine nameplates, mob health bars,
	player health and mana bars, dialogue billboards, prompts' own cards.
	A BLANKET SWEEP rather than per-owner opt-in, so a billboard nobody
	remembered (or one added next month) is covered by construction.

	Indicators are NOT swept: damage numbers and text indicators are
	suppressed at their source instead (DamageIndicatorController /
	TextIndicatorController both check isMagicCutscenePlaying), because a
	number that spawned hidden and reappeared at the end would pop into
	view halfway through an arc it had already flown.

	LOCAL ONLY: the caster is the only one watching a cutscene, so the
	caster is the only one who loses their world UI. Everyone else is still
	fighting and still needs to read the room.

	RESTORE IS EXACT: only billboards this controller actually turned off
	come back on. A billboard already hidden for its own reasons (a
	non-owner's loot, a spent chest, the hide-drops toggle) is left alone,
	and one that is destroyed mid-cutscene simply never returns.

	SCREEN UI IS UNTOUCHED. Only the BillboardGui class is swept -- the
	cinematic bars, the vignette and the cast dialogue strip are ScreenGuis
	and are the cutscene's own presentation.
]]

--[ Roblox Services ]--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--[ Imports ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)

--[ Controller ]--

local CutsceneBillboardController = Knit.CreateController({
	Name = "CutsceneBillboardController",

	-- The billboards THIS controller switched off, and must switch back on.
	-- STRONG keys, deliberately. An Instance's Lua object only stays alive
	-- while a strong Lua reference exists -- the DataModel holding the
	-- Instance does not count -- so a weak-keyed table silently loses
	-- every server-replicated billboard no client script references (mob
	-- health bars) within seconds, and those never came back after a
	-- cutscene. Cleared on stop, so nothing is retained past the window.
	_hidden = {},
	_active = false,
	-- Catches billboards that arrive mid-cutscene (a relic dropping, a mob
	-- spawning); nil while no cutscene is running.
	_arrivalConnection = nil,
})

--[ Private ]--

-- The roots a world billboard can live under. PlayerGui is included
-- because a BillboardGui parented there still renders in the world
-- through its Adornee -- and ScreenGuis there are untouched, since the
-- sweep only ever looks at the BillboardGui class.
function CutsceneBillboardController:_roots(): { Instance }
	local roots = { workspace }
	local playerGui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if playerGui then
		table.insert(roots, playerGui)
	end
	return roots
end

function CutsceneBillboardController:_hide(instance: Instance)
	if not instance:IsA("BillboardGui") or not (instance :: BillboardGui).Enabled then
		return
	end
	(instance :: BillboardGui).Enabled = false
	self._hidden[instance] = true
end

function CutsceneBillboardController:_start()
	if self._active then
		return
	end
	self._active = true

	for _, root in self:_roots() do
		for _, descendant in root:GetDescendants() do
			self:_hide(descendant)
		end
	end

	-- One connection on Workspace covers PlayerGui arrivals too rarely to
	-- matter on its own, so both roots get watched.
	local connections = {}
	for _, root in self:_roots() do
		table.insert(
			connections,
			root.DescendantAdded:Connect(function(descendant: Instance)
				if self._active then
					self:_hide(descendant)
				end
			end)
		)
	end
	self._arrivalConnection = connections
end

function CutsceneBillboardController:_stop()
	if not self._active then
		return
	end
	self._active = false

	for _, connection in self._arrivalConnection or {} do
		connection:Disconnect()
	end
	self._arrivalConnection = nil

	for instance in self._hidden do
		-- Destroyed mid-cutscene, or re-parented out: nothing to restore.
		if instance.Parent then
			(instance :: BillboardGui).Enabled = true
		end
	end
	table.clear(self._hidden)
end

--[ Lifecycle ]--

function CutsceneBillboardController:KnitInit() end

function CutsceneBillboardController:KnitStart()
	local localPlayer = Players.LocalPlayer

	local function bind(character: Model)
		local function refresh()
			if character:GetAttribute(Attributes.MagicCutscenePlaying) == true then
				self:_start()
			else
				self:_stop()
			end
		end
		character:GetAttributeChangedSignal(Attributes.MagicCutscenePlaying):Connect(refresh)
		refresh()
	end

	if localPlayer.Character then
		bind(localPlayer.Character)
	end
	-- A respawn mid-cutscene (death during a cast) leaves the flag behind on
	-- the old character: restore now, then follow the new one.
	localPlayer.CharacterAdded:Connect(function(character: Model)
		self:_stop()
		bind(character)
	end)
end

return CutsceneBillboardController
