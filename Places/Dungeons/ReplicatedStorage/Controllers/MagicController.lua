--[[
     Author(s): 
     Module: MagicController.lua
     Description:
]]

--[ Roblox Services ]--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--[ Exports & Types & Defaults ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local MagicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.MagicData)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local Signal = require(ReplicatedStorage.Submodules.Core.Packages.Signal)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local AuraNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.AuraNames)

local RelicController
local PlayerStateController
local PlayerEventController

local MagicController = Knit.CreateController({
	Name = "MagicController",
	Client = {},

	_magicData = {},
	_magicCooldownRegistry = {},
	_magicDebounce = false,
	_studMarkers = {},
	Signals = {
		OnMagicCasted = Signal.new(),
		OnMagicComplete = Signal.new(),
		OnMagic3CooldownUpdated = Signal.new(),
		OnMagic4CooldownUpdated = Signal.new(),
		OnNoManaRequested = Signal.new(),
		-- Fired when a relic pickup changes effective mana COSTS (not mana
		-- itself) -- Forbidden Box / Bloxiade. Slot UIs re-evaluate
		-- affordability on this, covering the full-mana case where no
		-- OnManaChanged would ever fire.
		OnManaCostsChanged = Signal.new(),
		OnManaChanged = Signal.new(),
	},
})

--[ Imports ]--

local MagicService
local MagicLoadoutController
local VFXController
local WeldConstraintController
local AimController

--[ Constants ]--

--[ Properties ]--

--[ Private Functions ]--

--[ Public Functions ]--

-- ONE source of truth for what a spell actually costs THIS player right
-- now -- the cast precheck and every slot UI (toolbar on desktop AND
-- mobile) read this, so the grey-out can never disagree with the cast
-- gate. MUST mirror VFXService:OnVFXRequested's server-side multiplier
-- chain, or the local precheck drifts from what the server charges:
--   * Forbidden Box (Cursed): x2 -- "Mana costs from Magic are doubled".
--   * Icy Arctic Fowl: x0.75 while Frostburst is up. Conditional on a
--     live aura, so the toolbar grey-out can lag a beat when it
--     starts/ends; the CAST gate reads this helper live, so casting is
--     always correct.
function MagicController:GetEffectiveManaCost(vfxName: string): number
	local magicIndexData = MagicData[vfxName]
	if not magicIndexData then
		return 0
	end

	local manaCostMultiplier = 1
	local ownedRelics = RelicController:GetRelicsFromUserId(Players.LocalPlayer.UserId)
	if ownedRelics and (ownedRelics[RelicNames["Forbidden Box"]] or 0) > 0 then
		manaCostMultiplier = manaCostMultiplier * 2
	end
	if ownedRelics and (ownedRelics[RelicNames["Icy Arctic Fowl"]] or 0) > 0 then
		local character = Players.LocalPlayer.Character
		local hrp = character and character:FindFirstChild("HumanoidRootPart")
		if hrp and hrp:FindFirstChild(AuraNames.Frostburst) then
			manaCostMultiplier = manaCostMultiplier * 0.75
		end
	end

	return magicIndexData.manaCost * manaCostMultiplier
end

-- LIVE slot gates for UI (mobile magic sticks, toolbar). Both read current
-- state on every call -- current mana vs the relic-adjusted effective cost,
-- and the cooldown registry -- so a button that greys out can un-grey the
-- moment regen / a relic pickup / a cooldown end makes the slot usable
-- again. Slots with no spell equipped read as unaffordable / not on
-- cooldown. UI should re-read these on OnManaChanged, OnManaCostsChanged
-- and the slot's OnMagic<N>CooldownUpdated.
function MagicController:CanAffordSlot(equipSlot: number): boolean
	local loadout = MagicLoadoutController:GetMagicLoadoutRegistry()[tostring(equipSlot)]
	if not loadout or not MagicData[loadout.name] then
		return false
	end
	local mana = self._magicData and self._magicData.mana or 0
	return mana - self:GetEffectiveManaCost(loadout.name) >= 0
end

function MagicController:IsSlotOnCooldown(equipSlot: number): boolean
	local loadout = MagicLoadoutController:GetMagicLoadoutRegistry()[tostring(equipSlot)]
	if not loadout then
		return false
	end
	local entry = self._magicCooldownRegistry[loadout.name]
	if not entry then
		return false
	end
	return tick() - entry.lastUsed < entry.cooldown
end

-- Every gate a cast must pass, WITH the player-facing feedback a failed
-- attempt gives (no-mana signal, cooldown warn). Returns (true, vfxName,
-- character, effectiveManaCost) when the spell in `equipSlot` can fire
-- right now, else false. Shared by :CastMagic and by CastModeController's
-- Normal Cast, which refuses to even open aim mode for a spell that would
-- be rejected -- so the two paths can never disagree on what's castable.
function MagicController:CanCastMagic(equipSlot: number): (boolean, string?, Model?, number?)
	if PlayerStateController:GeneralActionEnabled() == false then
		return false
	end

	local character = Players.LocalPlayer.Character

	if not MagicLoadoutController:GetMagicLoadoutRegistry()[tostring(equipSlot)] then
		warn("[MagicController] No magic found in loadout for equip slot: " .. tostring(equipSlot))
		return false
	end

	local vfxName = MagicLoadoutController:GetMagicLoadoutRegistry()[tostring(equipSlot)].name

	if not character or not character.PrimaryPart or self._magicDebounce or MagicData[vfxName] == nil then
		return false
	end

	local effectiveManaCost = self:GetEffectiveManaCost(vfxName)

	if self._magicData.mana - effectiveManaCost < 0 then
		self.Signals.OnNoManaRequested:Fire(equipSlot)
		return false
	end

	if self._magicCooldownRegistry[vfxName] == nil then
		self._magicCooldownRegistry[vfxName] = {
			cooldown = 0,
			lastUsed = 0,
		}
	end

	if tick() - self._magicCooldownRegistry[vfxName].lastUsed < self._magicCooldownRegistry[vfxName].cooldown then
		warn("[MagicController] Magic is still on cooldown for equip slot: " .. tostring(equipSlot))
		return false
	end

	return true, vfxName, character, effectiveManaCost
end

function MagicController:CastMagic(equipSlot: number)
	local castable, vfxName, character, effectiveManaCost = self:CanCastMagic(equipSlot)
	if not castable or not vfxName or not character or not effectiveManaCost then
		return
	end

	-- Mana-rune Cooldown Reduction via the replicated attribute
	-- (PlayerStatsService stamps it, Abyss-doubled), mirroring the server
	-- chain in VFXService.Client:OnVFXRequested -- drift here means the
	-- toolbar countdown disagrees with what the server enforces.
	local cooldownMultiplier = 1 - (Players.LocalPlayer:GetAttribute("CooldownReductionPercent") or 0)

	local newCooldown = MagicData[vfxName].cooldown * cooldownMultiplier

	if MagicData[vfxName].isAura then
		newCooldown = math.clamp(newCooldown, MagicData[vfxName].lifetime, MagicData[vfxName].cooldown)
	else
		newCooldown = math.clamp(newCooldown, MagicData[vfxName].duration, MagicData[vfxName].cooldown)
	end

	self._magicData.mana = self._magicData.mana - effectiveManaCost

	self.Signals.OnManaChanged:Fire(self._magicData)

	self.Signals["OnMagic" .. equipSlot .. "CooldownUpdated"]:Fire(true, self._magicData.mana, effectiveManaCost)

	task.delay(newCooldown, function()
		self.Signals["OnMagic" .. equipSlot .. "CooldownUpdated"]:Fire(false, self._magicData.mana, effectiveManaCost)
	end)

	-- Set magic enabled on client due to server desync from network
	character:SetAttribute(Attributes.MagicEnabled, true)

	self._magicDebounce = true

	self._magicCooldownRegistry[vfxName] = {
		cooldown = newCooldown,
		lastUsed = tick(),
	}

	self.Signals.OnMagicCasted:Fire(vfxName, equipSlot, newCooldown)

	-- LOCK the heading for the cast, both platforms (AimController decides
	-- what that means per platform: PC snaps to the cursor first, mobile
	-- keeps the stick's own aim). This is the ONE cast-desync guard now —
	-- it replaced both the inline CFrame write that raced the humanoid's
	-- steering here, and the mobile-only SkillshotDelay attribute.
	if AimController then
		AimController:BeginCastLock(MagicData[vfxName].duration)
	end

	-- Runs the caster's OWN effect module immediately (cast animation, cast
	-- sound, particles, cutscene) and sends the cast to the server for
	-- validation + everyone else. See VFXController:PlayVFX.
	VFXController:PlayVFX(vfxName)

	task.delay(MagicData[vfxName].duration, function()
		self._magicDebounce = false

		-- Symmetric clear for the optimistic `MagicEnabled = true` write
		-- at line ~123 above. Previously the client relied on the
		-- server's VFXService to mirror MagicEnabled=false back via
		-- attribute replication when the cast completed, but the server
		-- only fires that write when the cast is ACCEPTED — any
		-- server-side rejection (mana check, cooldown desync, ownership
		-- check) leaves the client's optimistic true write stuck on the
		-- character forever, gating PlayerStateController:GeneralActionEnabled()
		-- to false → no magic, no weapons, no dodge until respawn.
		--
		-- Clearing here on the client unconditionally after `duration`
		-- closes the race: even a rejected-server cast self-recovers
		-- after the duration elapses on the client.
		if character and character.Parent then
			character:SetAttribute(Attributes.MagicEnabled, false)
		end

		self.Signals.OnMagicComplete:Fire(vfxName)
	end)
end

function MagicController:ToggleMobileIndicator(toggle: boolean, equipSlot: number)
	local loadoutIndex = MagicLoadoutController:GetMagicLoadoutRegistry()[tostring(equipSlot)]
	local magicIndex = MagicData[loadoutIndex.name]

	if magicIndex.uniqueMobileIndicator == true then
		for _, surfacegui in self._studMarkers[magicIndex.name]:GetDescendants() do
			if surfacegui:IsA("SurfaceGui") then
				surfacegui.Enabled = toggle
			end
		end

		return
	end

	if magicIndex.isAOE then
		self._studMarkers[magicIndex.range].AOEMarkerPart.Size =
			Vector3.new(magicIndex.hitboxSize.X * 2, 0, magicIndex.hitboxSize.Z * 2)
		self._studMarkers[magicIndex.range].AOEMarkerPart.SurfaceGui.Enabled = toggle
		return
	end

	self._arrowBeamPart.ArrowBeam.Width0 = magicIndex.indicatorWidth
	self._arrowBeamPart.ArrowBeam.Width1 = magicIndex.indicatorWidth
	self._arrowBeamPart.EndAttachment.CFrame = CFrame.new(0, 0, magicIndex.indicatorLength)
	self._arrowBeamPart.ArrowBeam.Enabled = toggle
end

function MagicController:GetMagicData(): table
	return self._magicData
end

--[ Initializers ]--

function MagicController:KnitStart()
	MagicService = Knit.GetService("MagicService")

	MagicLoadoutController = Knit.GetController("MagicLoadoutController")
	VFXController = Knit.GetController("VFXController")
	PlayerEventController = Knit.GetController("PlayerEventController")
	WeldConstraintController = Knit.GetController("WeldConstraintController")
	MagicLoadoutController = Knit.GetController("MagicLoadoutController")
	PlayerStateController = Knit.GetController("PlayerStateController")
	RelicController = Knit.GetController("RelicController")
	AimController = Knit.GetController("AimController")

	self._mouse = Players.LocalPlayer:GetMouse()

	-- Relic pickups can change effective COSTS with mana untouched
	-- (Forbidden Box at full mana). Re-announce so slot UIs re-evaluate.
	RelicController.Signals.OnRelicsUpdated:Connect(function()
		self.Signals.OnManaCostsChanged:Fire()
	end)

	MagicService.MagicData:Observe(function(magicData: table)
		self._magicData = magicData

		self.Signals.OnManaChanged:Fire(self._magicData)
	end)

	PlayerEventController.OnCharacterLoaded:Connect(function(character)
		-- Defensive reset: clear any stuck MagicEnabled flag from a
		-- pre-respawn cast that never got its server-side mirror clear.
		-- Belt-and-suspenders with the duration-end clear in :CastMagic
		-- — even if a future code path bypasses that, respawn brings
		-- the gate back to a known-good state.
		character:SetAttribute(Attributes.MagicEnabled, false)

		self._arrowBeamPart = ReplicatedStorage.GameAssets.MobileHitMarkers.ArrowBeamPart:Clone()
		self._arrowBeamPart.CFrame = character.HumanoidRootPart.CFrame * CFrame.Angles(0, math.rad(180), 0)
		self._arrowBeamPart.ArrowBeam.Enabled = false
		self._arrowBeamPart.Parent = workspace.IgnoreInstances.MagicSpells

		WeldConstraintController:CreateWeldConstraint(self._arrowBeamPart, character.HumanoidRootPart)

		for _, aoeMarker in pairs(ReplicatedStorage.GameAssets.MobileHitMarkers.AOEMarkers:GetChildren()) do
			self._studMarkers[aoeMarker.Name] = aoeMarker:Clone()
			self._studMarkers[aoeMarker.Name]:PivotTo(
				character.HumanoidRootPart.CFrame * CFrame.Angles(0, math.rad(270), 0)
			)
			self._studMarkers[aoeMarker.Name].Parent = workspace.IgnoreInstances.MagicSpells

			WeldConstraintController:CreateWeldConstraint(
				self._studMarkers[aoeMarker.Name].PrimaryPart,
				character.HumanoidRootPart
			)
		end
	end)
end

function MagicController:KnitInit() end

return MagicController
