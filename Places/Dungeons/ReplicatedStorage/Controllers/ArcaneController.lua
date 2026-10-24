--!strict
--[[
     Author(s): 
     Module: ArcaneController.lua
     Description:
]]

--[ Roblox Services ]--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--[ Exports & Types & Defaults ]--

local ArcaneLoadoutController = require(ReplicatedStorage.Submodules.Core.Source.Controllers.ArcaneLoadoutController)
local VFXController = require(ReplicatedStorage.Controllers.VFXController)
local PlayerEventController = require(ReplicatedStorage.Submodules.Core.Source.Controllers.PlayerEventController)
local WeldConstraintController = require(ReplicatedStorage.Submodules.Core.Source.Controllers.WeldConstraintController)
local PlayerStateController = require(ReplicatedStorage.Controllers.PlayerStateController)
local RelicController = require(ReplicatedStorage.Controllers.RelicController)
local PlayerNetwork = require(ReplicatedStorage.Submodules.Core.Source.Network.Player)
local RemoteProperty = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Network.RemoteProperty)
local ArcaneData = require(ReplicatedStorage.Submodules.Core.Shared.Data.ArcaneData)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local Signal = require(ReplicatedStorage.Submodules.Core.Packages.Signal)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local AuraNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.AuraNames)

-- AimController requires this module at load, so this side reaches it
-- lazily: required on first use, once both modules exist.
local aimControllerLazy: any = nil
local function getAimController(): any
	if aimControllerLazy == nil then
		aimControllerLazy = (require :: any)(ReplicatedStorage.Controllers.AimController)
	end
	return aimControllerLazy
end

-- The replicated mana record (PlayerNetwork.ArcaneDataChanged).
type PlayerArcaneData = { mana: number, maxMana: number }

-- The loadout registry is keyed by the slot's STRING (every reader below
-- goes through tostring), while ArcaneLoadout declares number keys; this is
-- the one place that mismatch is bridged.
local function loadoutForSlot(equipSlot: number): { [string]: any }?
	local registry = ArcaneLoadoutController:GetArcaneLoadoutRegistry() :: any
	return registry[tostring(equipSlot)]
end

local ArcaneController = {
	Name = "ArcaneController",
	Dependencies = {
		ArcaneLoadoutController,
		VFXController,
		PlayerEventController,
		WeldConstraintController,
		PlayerStateController,
		RelicController,
	} :: { any },

	-- Empty until the first replicate; typed as the seeded record because
	-- every reader has always assumed it is one.
	_arcaneData = ({} :: any) :: PlayerArcaneData,
	_arcaneCooldownRegistry = {} :: { [string]: { cooldown: number, lastUsed: number } },
	_arcaneDebounce = false,
	-- Bumped per cast. A cast's end-of-duration timer acts only while its
	-- serial is still the latest: Fire Blast's timer used to clear
	-- ArcaneEnabled (and the debounce) 0.65 s in, right after Wind Bomb had
	-- set them for its own second, which unlocked dodging mid-cast.
	_castSerial = 0,
	-- Cloned MobileHitMarkers, keyed by marker name; indexed by child name.
	_studMarkers = {} :: { [string]: any },
	_arrowBeamPart = nil :: any,
	_mouse = nil :: Mouse?,
	Signals = {
		OnArcaneCasted = Signal.new(),
		OnArcaneComplete = Signal.new(),
		OnArcane3CooldownUpdated = Signal.new(),
		OnArcane4CooldownUpdated = Signal.new(),
		OnNoManaRequested = Signal.new(),
		-- Fired when a relic pickup changes effective mana COSTS (not mana
		-- itself) -- Forbidden Box / Bloxiade. Slot UIs re-evaluate
		-- affordability on this, covering the full-mana case where no
		-- OnManaChanged would ever fire.
		OnManaCostsChanged = Signal.new(),
		OnManaChanged = Signal.new(),
	},
}

--[ Imports ]--

--[ Constants ]--

--[ Properties ]--

--[ Private Functions ]--

--[ Public Functions ]--

-- ONE source of truth for what a spell actually costs THIS player right
-- now -- the cast precheck and every slot UI (toolbar on desktop AND
-- mobile) read this, so the grey-out can never disagree with the cast
-- gate. MUST mirror VFXService:OnVFXRequested's server-side multiplier
-- chain, or the local precheck drifts from what the server charges:
--   * Forbidden Box (Cursed): x2 -- "Mana costs from Arcane are doubled".
--   * Icy Arctic Fowl: x0.75 while Frostburst is up. Conditional on a
--     live aura, so the toolbar grey-out can lag a beat when it
--     starts/ends; the CAST gate reads this helper live, so casting is
--     always correct.
function ArcaneController.GetEffectiveManaCost(_self: typeof(ArcaneController), vfxName: string): number
	local arcaneIndexData = ArcaneData[vfxName]
	if not arcaneIndexData then
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

	return arcaneIndexData.manaCost * manaCostMultiplier
end

-- LIVE slot gates for UI (mobile arcane sticks, toolbar). Both read current
-- state on every call -- current mana vs the relic-adjusted effective cost,
-- and the cooldown registry -- so a button that greys out can un-grey the
-- moment regen / a relic pickup / a cooldown end makes the slot usable
-- again. Slots with no spell equipped read as unaffordable / not on
-- cooldown. UI should re-read these on OnManaChanged, OnManaCostsChanged
-- and the slot's OnArcane<N>CooldownUpdated.
function ArcaneController.CanAffordSlot(self: typeof(ArcaneController), equipSlot: number): boolean
	local loadout = loadoutForSlot(equipSlot)
	if not loadout or not ArcaneData[loadout.name] then
		return false
	end
	local mana = self._arcaneData and self._arcaneData.mana or 0
	return mana - self:GetEffectiveManaCost(loadout.name) >= 0
end

function ArcaneController.IsSlotOnCooldown(self: typeof(ArcaneController), equipSlot: number): boolean
	local loadout = loadoutForSlot(equipSlot)
	if not loadout then
		return false
	end
	local entry = self._arcaneCooldownRegistry[loadout.name]
	if not entry then
		return false
	end
	return os.clock() - entry.lastUsed < entry.cooldown
end

-- Every gate a cast must pass, WITH the player-facing feedback a failed
-- attempt gives (the no-mana signal; a cooldown click is silently
-- refused). Returns (true, vfxName,
-- character, effectiveManaCost) when the spell in `equipSlot` can fire
-- right now, else false. Shared by :CastArcane and by CastModeController's
-- Normal Cast, which refuses to even open aim mode for a spell that would
-- be rejected -- so the two paths can never disagree on what's castable.
function ArcaneController.CanCastArcane(
	self: typeof(ArcaneController),
	equipSlot: number
): (boolean, string?, Model?, number?)
	if PlayerStateController:GeneralActionEnabled() == false then
		return false
	end

	local character = Players.LocalPlayer.Character

	local loadout = loadoutForSlot(equipSlot)
	if not loadout then
		warn("[ArcaneController] No arcane found in loadout for equip slot: " .. tostring(equipSlot))
		return false
	end

	local vfxName = loadout.name

	if not character or not character.PrimaryPart or self._arcaneDebounce or ArcaneData[vfxName] == nil then
		return false
	end

	local effectiveManaCost = self:GetEffectiveManaCost(vfxName)

	if self._arcaneData.mana - effectiveManaCost < 0 then
		self.Signals.OnNoManaRequested:Fire(equipSlot)
		return false
	end

	if self._arcaneCooldownRegistry[vfxName] == nil then
		self._arcaneCooldownRegistry[vfxName] = {
			cooldown = 0,
			lastUsed = 0,
		}
	end

	if os.clock() - self._arcaneCooldownRegistry[vfxName].lastUsed < self._arcaneCooldownRegistry[vfxName].cooldown then
		return false
	end

	return true, vfxName, character, effectiveManaCost
end

function ArcaneController.CastArcane(self: typeof(ArcaneController), equipSlot: number)
	local castable, vfxName, character, effectiveManaCost = self:CanCastArcane(equipSlot)
	if not castable or not vfxName or not character or not effectiveManaCost then
		return
	end

	-- Mana-rune Cooldown Reduction via the replicated attribute
	-- (PlayerStatsService stamps it, Abyss-doubled), mirroring the server
	-- chain in VFXService.Client:OnVFXRequested -- drift here means the
	-- toolbar countdown disagrees with what the server enforces.
	local cooldownMultiplier = 1 - (Players.LocalPlayer:GetAttribute("CooldownReductionPercent") or 0)

	local newCooldown = ArcaneData[vfxName].cooldown * cooldownMultiplier

	if ArcaneData[vfxName].isAura then
		newCooldown = math.clamp(newCooldown, ArcaneData[vfxName].lifetime, ArcaneData[vfxName].cooldown)
	else
		newCooldown = math.clamp(newCooldown, ArcaneData[vfxName].duration, ArcaneData[vfxName].cooldown)
	end

	self._arcaneData.mana = self._arcaneData.mana - effectiveManaCost

	self.Signals.OnManaChanged:Fire(self._arcaneData)

	self.Signals["OnArcane" .. equipSlot .. "CooldownUpdated"]:Fire(true, self._arcaneData.mana, effectiveManaCost)

	task.delay(newCooldown, function()
		self.Signals["OnArcane" .. equipSlot .. "CooldownUpdated"]:Fire(false, self._arcaneData.mana, effectiveManaCost)
	end)

	-- Set arcane enabled on client due to server desync from network
	character:SetAttribute(Attributes.ArcaneEnabled, true)

	self._arcaneDebounce = true
	self._castSerial += 1
	local castSerial = self._castSerial

	self._arcaneCooldownRegistry[vfxName] = {
		cooldown = newCooldown,
		lastUsed = os.clock(),
	}

	self.Signals.OnArcaneCasted:Fire(vfxName, equipSlot, newCooldown)

	-- LOCK the heading for the cast, both platforms (AimController decides
	-- what that means per platform: PC snaps to the cursor first, mobile
	-- keeps the stick's own aim). This is the ONE cast-desync guard now —
	-- it replaced both the inline CFrame write that raced the humanoid's
	-- steering here, and the mobile-only SkillshotDelay attribute.
	if getAimController() then
		getAimController():BeginCastLock(ArcaneData[vfxName].duration)
	end

	-- Runs the caster's OWN effect module immediately (cast animation, cast
	-- sound, particles, cutscene) and sends the cast to the server for
	-- validation + everyone else. See VFXController:PlayVFX.
	VFXController:PlayVFX(vfxName)

	task.delay(ArcaneData[vfxName].duration, function()
		-- A later cast owns the flags now; its own timer releases them.
		if self._castSerial ~= castSerial then
			self.Signals.OnArcaneComplete:Fire(vfxName)
			return
		end
		self._arcaneDebounce = false

		-- Symmetric clear for the optimistic `ArcaneEnabled = true` write
		-- at line ~123 above. Previously the client relied on the
		-- server's VFXService to mirror ArcaneEnabled=false back via
		-- attribute replication when the cast completed, but the server
		-- only fires that write when the cast is ACCEPTED — any
		-- server-side rejection (mana check, cooldown desync, ownership
		-- check) leaves the client's optimistic true write stuck on the
		-- character forever, gating PlayerStateController:GeneralActionEnabled()
		-- to false → no arcane, no weapons, no dodge until respawn.
		--
		-- Clearing here on the client unconditionally after `duration`
		-- closes the race: even a rejected-server cast self-recovers
		-- after the duration elapses on the client.
		if character and character.Parent then
			character:SetAttribute(Attributes.ArcaneEnabled, false)
		end

		self.Signals.OnArcaneComplete:Fire(vfxName)
	end)
end

function ArcaneController.ToggleMobileIndicator(self: typeof(ArcaneController), toggle: boolean, equipSlot: number)
	-- Same as before: a slot with nothing equipped throws here.
	local loadoutIndex = loadoutForSlot(equipSlot) :: { [string]: any }
	local arcaneIndex = ArcaneData[loadoutIndex.name]

	if arcaneIndex.uniqueMobileIndicator == true then
		for _, surfacegui in self._studMarkers[arcaneIndex.name]:GetDescendants() do
			if surfacegui:IsA("SurfaceGui") then
				surfacegui.Enabled = toggle
			end
		end

		return
	end

	if arcaneIndex.isAOE then
		self._studMarkers[arcaneIndex.range].AOEMarkerPart.Size =
			Vector3.new(arcaneIndex.hitboxSize.X * 2, 0, arcaneIndex.hitboxSize.Z * 2)
		self._studMarkers[arcaneIndex.range].AOEMarkerPart.SurfaceGui.Enabled = toggle
		return
	end

	self._arrowBeamPart.ArrowBeam.Width0 = arcaneIndex.indicatorWidth
	self._arrowBeamPart.ArrowBeam.Width1 = arcaneIndex.indicatorWidth
	self._arrowBeamPart.EndAttachment.CFrame = CFrame.new(0, 0, arcaneIndex.indicatorLength)
	self._arrowBeamPart.ArrowBeam.Enabled = toggle
end

function ArcaneController.GetArcaneData(self: typeof(ArcaneController)): { [any]: any }
	return self._arcaneData
end

--[ Initializers ]--

function ArcaneController.Start(self: typeof(ArcaneController))
	self._mouse = Players.LocalPlayer:GetMouse()

	-- Relic pickups can change effective COSTS with mana untouched
	-- (Forbidden Box at full mana). Re-announce so slot UIs re-evaluate.
	RelicController.Signals.OnRelicsUpdated:Connect(function()
		self.Signals.OnManaCostsChanged:Fire()
	end)

	RemoteProperty.Client({ changed = PlayerNetwork.ArcaneDataChanged, get = PlayerNetwork.GetArcaneData })
		:Observe(function(arcaneData: PlayerArcaneData?)
			-- The server always seeds the record; nil here was never handled.
			self._arcaneData = arcaneData :: PlayerArcaneData

			self.Signals.OnManaChanged:Fire(self._arcaneData)
		end)

	PlayerEventController.OnCharacterLoaded:Connect(function(character)
		-- Defensive reset: clear any stuck ArcaneEnabled flag from a
		-- pre-respawn cast that never got its server-side mirror clear.
		-- Belt-and-suspenders with the duration-end clear in :CastArcane
		-- — even if a future code path bypasses that, respawn brings
		-- the gate back to a known-good state.
		character:SetAttribute(Attributes.ArcaneEnabled, false)

		-- Direct child index as before: a rig with no root throws here.
		local humanoidRootPart = character:FindFirstChild("HumanoidRootPart") :: BasePart

		-- Respawn: the previous character's markers sit in ArcaneSpells welded
		-- to a dead root. Replace them instead of stacking one set per life.
		if self._arrowBeamPart then
			self._arrowBeamPart:Destroy()
			self._arrowBeamPart = nil
		end
		for name, marker in self._studMarkers do
			marker:Destroy()
			self._studMarkers[name] = nil
		end

		self._arrowBeamPart = ReplicatedStorage.GameAssets.MobileHitMarkers.ArrowBeamPart:Clone()
		self._arrowBeamPart.CFrame = humanoidRootPart.CFrame * CFrame.Angles(0, math.rad(180), 0)
		self._arrowBeamPart.ArrowBeam.Enabled = false
		self._arrowBeamPart.Parent = workspace.IgnoreInstances.ArcaneSpells

		WeldConstraintController:CreateWeldConstraint(self._arrowBeamPart, humanoidRootPart)

		for _, aoeMarker in pairs(ReplicatedStorage.GameAssets.MobileHitMarkers.AOEMarkers:GetChildren()) do
			self._studMarkers[aoeMarker.Name] = aoeMarker:Clone()
			self._studMarkers[aoeMarker.Name]:PivotTo(humanoidRootPart.CFrame * CFrame.Angles(0, math.rad(270), 0))
			self._studMarkers[aoeMarker.Name].Parent = workspace.IgnoreInstances.ArcaneSpells

			WeldConstraintController:CreateWeldConstraint(
				self._studMarkers[aoeMarker.Name].PrimaryPart,
				humanoidRootPart
			)
		end
	end)
end

return ArcaneController
