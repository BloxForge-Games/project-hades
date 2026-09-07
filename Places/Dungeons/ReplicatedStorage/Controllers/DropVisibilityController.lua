--[[
	Module: DropVisibilityController.lua
	Description:
	The "Hide Player Drops" toggle behind the top bar icon of the same name.
	Hides the relics and gear OTHER players have dropped on the floor, so a
	co-op run's shared loot pile stops competing with your own.

	Scope is deliberately narrow: only PUBLIC drops (Attributes.PublicDrop —
	an item a player dropped from their relic tray or run inventory) whose
	dropper is not you. Everything else is already private. A relic you do
	not own fades out on your client, gear you do not own is hidden by the
	GearDrop component, and mob loot, chest loot and vending-machine offers
	all belong to exactly one player already. Your OWN dropped items stay
	visible, because you may well want them back.

	Hidden means fully inert: the model, its particles, its glow, its
	floating label and its pickup prompt all go. A prompt hovering over
	nothing would be worse than the clutter this removes.

	SESSION ONLY. Unlike Quick Cast and Auto Aim this is not written to the
	profile — it is a moment-to-moment declutter switch, and a fresh join
	starts showing drops again.

	The restore is EXACT, not a blanket re-enable. Hiding records which
	emitters, lights, billboards and prompts were actually on at the time
	and turns only those back on. A blanket pass would light up things that
	were off for their own reasons — a landed drop's spent flight trail, a
	billboard suppressed because its prompt is showing, the Shine emitter a
	non-owner never had.

	Parts are hidden with LocalTransparencyModifier rather than Transparency
	so this never fights the render controllers, which tween Transparency
	for their hover dim.
]]

--[ Roblox Services ]--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

--[ Imports ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local Signal = require(ReplicatedStorage.Submodules.Core.Packages.Signal)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)

--[ Constants ]--

-- The drop tags this setting governs. Runes are absent on purpose: they
-- are owner-locked and cannot be dropped by a player, so none of them is
-- ever another player's drop.
local GOVERNED_TAGS = { TagList.Relic, TagList.GearDrop }

--[ Controller ]--

local DropVisibilityController = Knit.CreateController({
	Name = "DropVisibilityController",
})

--[ Properties ]--

DropVisibilityController._hidden = false
DropVisibilityController.OnChanged = Signal.new() :: (hidden: boolean) -> ()

-- [model] = what this controller switched OFF when it hid that model, so
-- the restore can put back exactly that and nothing else.
DropVisibilityController._suppressed = {} :: { [Instance]: { Instance } }

--[ Private ]--

-- Is this model a drop the setting is allowed to hide? Public, and not
-- the local player's own.
function DropVisibilityController:_isOtherPlayersDrop(model: Instance): boolean
	if model:GetAttribute(Attributes.PublicDrop) ~= true then
		return false
	end
	return model:GetAttribute(Attributes.DroppedById) ~= Players.LocalPlayer.UserId
end

-- Hides `model` and remembers what it switched off.
function DropVisibilityController:_hide(model: Instance)
	if self._suppressed[model] then
		return -- already hidden
	end

	local switchedOff: { Instance } = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.LocalTransparencyModifier = 1
		elseif
			descendant:IsA("ParticleEmitter")
			or descendant:IsA("Trail")
			or descendant:IsA("Light")
			or descendant:IsA("BillboardGui")
			or descendant:IsA("ProximityPrompt")
		then
			-- Only what is ON right now is recorded, so the restore cannot
			-- switch on something that was off for its own reasons.
			if descendant.Enabled then
				descendant.Enabled = false
				table.insert(switchedOff, descendant)
			end
		end
	end
	self._suppressed[model] = switchedOff
end

-- Puts `model` back exactly as it was found.
function DropVisibilityController:_show(model: Instance)
	local switchedOff = self._suppressed[model]
	if not switchedOff then
		return -- was never hidden by us
	end
	self._suppressed[model] = nil

	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.LocalTransparencyModifier = 0
		end
	end
	for _, instance in switchedOff do
		if instance.Parent then
			instance.Enabled = true
		end
	end
end

-- Brings one drop in line with the current setting.
function DropVisibilityController:Apply(model: Instance)
	if self._hidden and self:_isOtherPlayersDrop(model) then
		self:_hide(model)
	else
		self:_show(model)
	end
end

function DropVisibilityController:_applyAll()
	for _, tag in GOVERNED_TAGS do
		for _, model in CollectionService:GetTagged(tag) do
			self:Apply(model)
		end
	end
end

--[ Public ]--

function DropVisibilityController:IsHidden(): boolean
	return self._hidden
end

function DropVisibilityController:SetHidden(hidden: boolean)
	if self._hidden == hidden then
		return
	end
	self._hidden = hidden
	self:_applyAll()
	self.OnChanged:Fire(hidden)
end

function DropVisibilityController:Toggle()
	self:SetHidden(not self._hidden)
end

--[ Lifecycle ]--

function DropVisibilityController:KnitStart()
	for _, tag in GOVERNED_TAGS do
		-- Deferred one frame: the tag lands before the components have built
		-- the drop's billboard and prompt, and hiding has to see them to
		-- switch them off.
		CollectionService:GetInstanceAddedSignal(tag):Connect(function(model: Instance)
			task.defer(function()
				if model.Parent then
					self:Apply(model)
				end
			end)
		end)
		CollectionService:GetInstanceRemovedSignal(tag):Connect(function(model: Instance)
			self._suppressed[model] = nil
		end)
	end
	self:_applyAll()
end

function DropVisibilityController:KnitInit() end

return DropVisibilityController
