--[[
     Author(s): 
     Module: VFXService.lua
     Description:
]]

--[ Roblox Services ]--

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

--[ Exports & Types & Defaults ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local MagicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.MagicData)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local CameraShakePresets = require(ReplicatedStorage.Submodules.Core.Shared.Enums.CameraShakePresets)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local Breakable = require(script.Parent.Parent.Components.Breakable)
local Signal = require(ReplicatedStorage.Submodules.Core.Packages.Signal)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)

-- Cast-site relic knobs. MUST mirror MagicController's client chain.
-- Forbidden Box (Cursed): mana costs from Magic are DOUBLED.
local FORBIDDEN_BOX_MANA_MULTIPLIER = 2
-- Cast-cutscene i-frame length when a MagicData `cutscene` entry sets no
-- duration. MUST match CutsceneController's DEFAULT_MAGIC_CUTSCENE_SECONDS.
local DEFAULT_MAGIC_CUTSCENE_SECONDS = 2
-- Icy Arctic Fowl: x0.75 mana while Frostburst is up (its +30% damage
-- half rides the AuraDamage module; the callback owns that value).
local ICY_ARCTIC_FOWL_MANA_MULTIPLIER = 0.75
-- Mystical Staff of Cyan: every equipped cast drops a Magic Sigil at the
-- caster's feet. The registry below is consumed by DamageService's
-- MysticalSigil module via :IsInSigilZone. Radius is the BUFF zone --
-- the visual ring is smaller; forgiving on purpose.
local MYSTICAL_SIGIL_DURATION = 5
local MYSTICAL_SIGIL_RADIUS = 13
-- Visual fade tail: emitters/beams switch off at the 5s buff end, the
-- model is destroyed this many seconds later so in-flight particles
-- finish their lifetime instead of vanishing mid-air.
local MYSTICAL_SIGIL_FADE_SECONDS = 1
local AuraNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.AuraNames)
local onHitboxDamage = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Hitbox.onHitboxDamage)
local MagicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.MagicNames)
local toggleWeaponSheath = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Weapon.toggleWeaponSheath)

local IgnoreListService
local PlayerEventService
local CameraShakeService
local MagicService
local MagicLoadoutService
local RelicService
local ShieldService
local InvulnerabilityService

local BUILDING_FLOOR_STRING = "Floor"
local BUILDING_IMPULSE_SCALAR = 0.1
local BROKEN_BUILDING_MIN_LIFETIME = 2
local BROKEN_BUILDING_MAX_LIFETIME = 4
local BUILDING_KNOCKBACK_STRENGTH = 250
local AURA_DELAY = 1
-- Grace between an aura being CAST and its first swing. The aura's rig
-- (Susanoo's armour) streams in and plays its own activation beat, and an
-- attack that lands before it is on screen reads as damage from nowhere.
-- Only the FIRST swing waits: attackInterval owns the cadence after it.
-- It matters because holding attack THROUGH the cast is a supported (and
-- good) way to open with an aura — the swing fires the instant the
-- attribute flips, which is exactly when the rig is least ready.
local AURA_ACTIVATION_DELAY = 0.2

local vfxServer = script.VFXServer

local VFXService = Knit.CreateService({
	Name = "VFXService",
	Client = {
		OnVFXReplicated = Knit.CreateSignal(),
		OnBuildingBroken = Knit.CreateSignal(),
	},
})

--[ Imports ]--

--[ Constants ]--

--[ Properties ]--

VFXService._playerDetectedPartsRegistry = {}
VFXService._vfxReplicationQueue = {}
VFXService._vfxAuraRegistry = {}
VFXService._vfxAttackRegistry = {}

-- Live Magic Sigil zones -- { position: Vector3, expiresAt: number }.
-- Every cast APPENDS (sigils stack on the floor; the BUFF doesn't --
-- IsInSigilZone is boolean). Expired entries are pruned lazily on
-- every read/write.
VFXService._activeSigils = {}
VFXService._vfxRegistry = {}
VFXService._persistentHitboxes = {}
VFXService._weaponOverlapParams = OverlapParams.new()

VFXService.OnBuildingBroken = Signal.new()

--[ Private Functions ]--

local function shouldResetHitRegistry(vfxName: string): boolean
	return vfxName == MagicNames["Pumpkin Explosion"]
		or vfxName == MagicNames["Big Pumpkin Explosion"]
		-- Was missing: without the reset a zombie grazed by one Fuse Bomb was
		-- immune to every later one for the session.
		or vfxName == MagicNames["Fuse Bomb Explosion"]
		or vfxName == MagicNames["Fireworks Explosion"]
		or vfxName == MagicNames["Ghost Dragon"]
		or vfxName == MagicNames["Susanoo Armor"]
		or vfxName == MagicNames["Domain Expansion"]
end

function VFXService:_checkVFXOwned(player: Player, vfxName: string): boolean
	local loadout = MagicLoadoutService:GetMagicLoadout(player)

	if not loadout then
		print("[VFXService] No magic loadout found for player:", player.Name)
		return false
	end

	local vfxOwned = false

	for _, magicData in loadout do
		if magicData and magicData.name == vfxName then
			vfxOwned = true
			break
		end
	end

	if not vfxOwned then
		print("[VFXService] Player does not own the magic for this VFX:", player.Name, vfxName)
		return false
	end

	return true
end

function VFXService:_toggleWeaponTransparency(player: Player, transparency: number)
	local equippedWeapon = player.Character:GetAttribute(Attributes.EquippedWeapon)
	local toggle = transparency == 0
	local weaponModel = nil

	for _, weapon in pairs(player.Character:GetChildren()) do
		-- Weapons are plain Models now (converted from Accessory). Match by
		-- the Weapon tag + name; skip the Sheathed back-copy so we only
		-- toggle the in-hand weapon.
		if weapon:IsA("Model") and weapon:HasTag("Weapon") and weapon.Name == equippedWeapon then
			if weapon:HasTag("Sheathed") then
				continue
			end

			weaponModel = weapon
			break
		end
	end

	if weaponModel then
		toggleWeaponSheath(weaponModel, player.Character, toggle)
	end
end

--[ Public Functions ]--

function VFXService:AuraAttack(player: Player)
	if not self._vfxAuraRegistry[player] then
		return warn("[VFXService] No active aura VFX found for player:", player.Name)
	end

	-- Still arriving (AURA_ACTIVATION_DELAY). Checked before the cadence
	-- gate and WITHOUT stamping lastAttacked, so the wait costs the player
	-- nothing: the first swing lands the moment the grace is up.
	local readyAt = self._vfxAuraRegistry[player].readyAt
	if readyAt and tick() < readyAt then
		return
	end

	if tick() - self._vfxAuraRegistry[player].lastAttacked < self._vfxAuraRegistry[player].attackInterval then
		return
	end

	self._vfxAuraRegistry[player].lastAttacked = tick()

	self._vfxAuraRegistry[player].attack()
end

function VFXService:RegisterHitbox(
	activePlayer: Player,
	cframe: CFrame,
	radius: number,
	overlapParams: OverlapParams,
	targetTag: string,
	hitCallback: (Model) -> (),
	vfxName: string,
	canBreakBuildings: boolean
)
	local userId = activePlayer.UserId

	if not self._playerDetectedPartsRegistry[userId] then
		self._playerDetectedPartsRegistry[userId] = {}
	end

	if not self._playerDetectedPartsRegistry[userId][vfxName] then
		self._playerDetectedPartsRegistry[userId][vfxName] = {}
	end

	local detectedRegistry = self._playerDetectedPartsRegistry[userId][vfxName]
	local character = activePlayer.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")

	local partsTable = nil
	local hitParts = workspace:GetPartBoundsInRadius(cframe.Position, radius, overlapParams)

	for i = 1, #hitParts do
		local part = hitParts[i]
		local model = part:FindFirstAncestorWhichIsA("Model")

		if not model then
			continue
		end

		if model:HasTag(targetTag) then
			local humanoid = model:FindFirstChild("Humanoid")

			if not humanoid then
				continue
			end

			if detectedRegistry[model] then
				continue
			end

			detectedRegistry[model] = true
			hitCallback(model)
		elseif canBreakBuildings and model:HasTag(TagList.Breakable) then
			-- Magic spells that opt in via MagicData.canBreakBuildings can
			-- instantly destroy Breakables (gates, barricades, props). Passive
			-- relic procs like Ghost Dragon and Fireworks set this to false
			-- so they don't shred the player's own barricades while ticking.
			-- Dedupe so a multi-part breakable only fires once per AOE.
			if detectedRegistry[model] then
				continue
			end
			detectedRegistry[model] = true

			local breakable = Breakable:FromInstance(model)

			if breakable then
				-- (isMagic, isMelee, origin, player) -- see MeleeWeapon for the
				-- same slot fix.
				breakable:Hit(true, false, cframe.Position, activePlayer)
			end
		elseif canBreakBuildings and model:HasTag(TagList.Destructable) and part.Name ~= BUILDING_FLOOR_STRING then
			if not rootPart then
				continue
			end

			self.OnBuildingBroken:Fire(part)

			local hue, saturation = part.Color:ToHSV()
			part.Color = Color3.fromHSV(hue, saturation, 0.35)

			part.Parent = workspace.IgnoreInstances.MagicSpells
			part.Anchored = false

			local pathfindingModifier = Instance.new("PathfindingModifier")
			pathfindingModifier.PassThrough = true
			pathfindingModifier.Parent = part

			local direction = CFrame.new(cframe.Position, rootPart.Position).LookVector + (cframe.UpVector * 2)
			local mass = part.AssemblyMass

			part:ApplyImpulse((-direction * mass) * (BUILDING_KNOCKBACK_STRENGTH * BUILDING_IMPULSE_SCALAR))

			part:ApplyAngularImpulse(
				Vector3.new(math.random(-90, 90), math.random(-90, 90), math.random(-90, 90)) * mass
			)

			task.delay(math.random(BROKEN_BUILDING_MIN_LIFETIME, BROKEN_BUILDING_MAX_LIFETIME), function()
				if not part.Parent then
					return
				end

				for _, child in part:GetChildren() do
					if child:IsA("ParticleEmitter") then
						child.Enabled = false
					elseif child:IsA("Texture") then
						TweenService:Create(child, TweenInfo.new(1), { Transparency = 1 }):Play()
					end
				end

				TweenService:Create(part, TweenInfo.new(1), { Transparency = 1 }):Play()
				Debris:AddItem(part, 1)
			end)

			partsTable = partsTable or {}
			partsTable[#partsTable + 1] = part
		end
	end

	if partsTable then
		self.Client.OnBuildingBroken:FireAll(partsTable)
	end
end

function VFXService:CreateHitbox(
	vfxName: string,
	activePlayer: Player,
	cframe: CFrame,
	targetTag: string,
	overlapParamsRef,
	callback: (Model) -> (),
	radius: number,
	skipCameraShake: boolean?
)
	local magicIndexData = MagicData[vfxName] or {}
	local character = activePlayer.Character

	if not character then
		warn("[VFXService] Character not found for player " .. activePlayer.Name)
		return
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		warn("[VFXService] HumanoidRootPart not found for player " .. activePlayer.Name)
		return
	end

	-- skipCameraShake: high-frequency callers (the sweep loop calls this
	-- per STEP) fire their own single cast shake instead — per-step
	-- re-triggers kept resetting the shake envelope and suppressed it.
	if magicIndexData.cameraShake and not skipCameraShake then
		-- Magic spell explosions read as Medium — punchier than the Small
		-- default other radius emitters fall back to.
		CameraShakeService.OnGetBoundsInShakeRadius:Fire(character, cframe, radius, CameraShakePresets.Medium)
	end

	local canBreakBuildings = magicIndexData.canBreakBuildings or false

	if shouldResetHitRegistry(vfxName) then
		if not self._playerDetectedPartsRegistry[activePlayer.UserId] then
			self._playerDetectedPartsRegistry[activePlayer.UserId] = {}
		end

		self._playerDetectedPartsRegistry[activePlayer.UserId][vfxName] = {}
	end

	local overlapParams = self._weaponOverlapParams
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = overlapParamsRef

	self:RegisterHitbox(activePlayer, cframe, radius, overlapParams, targetTag, callback, vfxName, canBreakBuildings)
end

function VFXService.Client:StartAuraAttack(player)
	-- The loop below ENDS on its own when Susanoo drops, leaving a dead
	-- thread in the registry. Only a LIVE thread means "already attacking";
	-- a dead one is swept so the next start (a fresh cast under a held
	-- button) is not refused.
	local existing = self.Server._vfxAttackRegistry[player]
	if existing then
		if coroutine.status(existing) ~= "dead" then
			return
		end
		self.Server._vfxAttackRegistry[player] = nil
	end

	self.Server._vfxAttackRegistry[player] = task.spawn(function()
		while player.Parent and player.Character and player.Character:GetAttribute(Attributes.SusanooEnabled) do
			self.Server:AuraAttack(player)
			task.wait(AURA_DELAY)
		end
	end)
end

function VFXService.Client:StopAuraAttack(player)
	if self.Server._vfxAttackRegistry[player] then
		task.cancel(self.Server._vfxAttackRegistry[player])
		self.Server._vfxAttackRegistry[player] = nil
	end
end

-- Mystical Staff of Cyan -- sigil placement. Ground point = a downward
-- ray against the MAP geometry only (Include filter, same convention as
-- EncounterService's chest floor snap), so mobs, spell debris, and the
-- caster can't become the "floor". No hit (mid-jump over the void) =
-- no sigil, cast otherwise unaffected.
function VFXService:_spawnMagicSigil(player: Player)
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return
	end

	local ignoreInstances = workspace:FindFirstChild("IgnoreInstances")
	local map = ignoreInstances and ignoreInstances:FindFirstChild("Map")
	if not map then
		return
	end

	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Include
	raycastParams.FilterDescendantsInstances = { map }

	local result = workspace:Raycast(hrp.Position, Vector3.new(0, -50, 0), raycastParams)
	if not result then
		return
	end

	local template = ReplicatedStorage.GameAssets.VFX:FindFirstChild("MagicSigil")
	local model = template and template:FindFirstChild("Model")
	if not model then
		warn("[VFXService] MagicSigil model missing from GameAssets.VFX.MagicSigil")
		return
	end

	local sigil = model:Clone()
	for _, part in sigil:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = true
			part.CanCollide = false
			part.CanQuery = false
		end
	end
	sigil:PivotTo(CFrame.new(result.Position + Vector3.new(0, 1.75, 0)))
	sigil.Parent = workspace.IgnoreInstances.MagicSpells

	-- Smooth lifecycle. Burst 1 particle from every emitter AFTER
	-- parenting (:Emit on an unparented emitter silently discards -- the
	-- parent-then-Emit rule) so the ring reads the instant it lands
	-- instead of waiting on emitter Rate. At the 3s buff end, DISABLE
	-- emitters and beams rather than destroying -- live particles fade
	-- out naturally and the ring doesn't hard-pop -- then the model dies
	-- 1s later once they've cleared.
	for _, descendant in sigil:GetDescendants() do
		if descendant:IsA("ParticleEmitter") then
			descendant:Emit(1)
		end
	end
	task.delay(MYSTICAL_SIGIL_DURATION, function()
		if not sigil.Parent then
			return
		end
		for _, descendant in sigil:GetDescendants() do
			if descendant:IsA("ParticleEmitter") or descendant:IsA("Beam") then
				descendant.Enabled = false
			end
		end
	end)
	Debris:AddItem(sigil, MYSTICAL_SIGIL_DURATION + MYSTICAL_SIGIL_FADE_SECONDS)

	self:_pruneExpiredSigils()
	table.insert(self._activeSigils, {
		position = result.Position,
		expiresAt = tick() + MYSTICAL_SIGIL_DURATION,
	})
end

function VFXService:_pruneExpiredSigils()
	local now = tick()
	for i = #self._activeSigils, 1, -1 do
		if now >= self._activeSigils[i].expiresAt then
			table.remove(self._activeSigils, i)
		end
	end
end

-- True when `position` is inside ANY live sigil circle. XZ distance
-- only -- height is ignored so a jumping attacker doesn't drop the
-- buff. One true is all MysticalSigil.lua needs; overlaps don't stack.
function VFXService:IsInSigilZone(position: Vector3): boolean
	self:_pruneExpiredSigils()
	for _, sigil in self._activeSigils do
		local dx = position.X - sigil.position.X
		local dz = position.Z - sigil.position.Z
		if (dx * dx + dz * dz) <= (MYSTICAL_SIGIL_RADIUS * MYSTICAL_SIGIL_RADIUS) then
			return true
		end
	end
	return false
end

function VFXService.Client:OnVFXRequested(player: Player, vfxName: string, cframe: CFrame)
	if not self.Server:_checkVFXOwned(player, vfxName) then
		return warn("[VFXService] Player attempted to cast unowned magic:", player)
	end

	-- Mana cost multipliers. MUST mirror the client's
	-- MagicController:GetEffectiveManaCost -- that helper drives both the
	-- cast precheck and the toolbar grey-out, and a drift here means the
	-- UI lies about affordability:
	--   * Forbidden Box (Cursed): x2 -- "Mana costs from Magic are doubled".
	--   * Icy Arctic Fowl: x0.65 while Frostburst is up.
	local manaCostMultiplier = 1
	if RelicService:GetSpecificRelicRegistry(player, RelicNames["Forbidden Box"]) > 0 then
		manaCostMultiplier = manaCostMultiplier * FORBIDDEN_BOX_MANA_MULTIPLIER
	end
	do
		local casterCharacter = player.Character
		local casterHrp = casterCharacter and casterCharacter:FindFirstChild("HumanoidRootPart")
		if
			casterHrp
			and casterHrp:FindFirstChild(AuraNames.Frostburst)
			and RelicService:GetSpecificRelicRegistry(player, RelicNames["Icy Arctic Fowl"]) > 0
		then
			manaCostMultiplier = manaCostMultiplier * ICY_ARCTIC_FOWL_MANA_MULTIPLIER
		end
	end

	-- Robloxian Battle Shield: every equipped-spell cast grants its owner a
	-- shield (ShieldService owns the fraction/duration).
	ShieldService:TryRobloxionShield(player)
	ShieldService:TrySpartanStonebound(player)

	local effectiveManaCost = MagicData[vfxName].manaCost * manaCostMultiplier

	if MagicService:GetPlayerMagicData(player).mana - effectiveManaCost < 0 then
		warn("[VFXService] Player attempted to cast magic without enough mana:", player)
		return
	end

	if MagicService:GetPlayerMagicLastUsed(player, vfxName) == nil then
		MagicService:SetPlayerMagicLastUsed(player, vfxName, 0)
	end

	if
		tick() - MagicService:GetPlayerMagicLastUsed(player, vfxName)
		< MagicService:GetPlayerMagicCooldown(player, vfxName)
	then
		warn("[VFXService] Player attempted to cast magic before cooldown was up:", player)

		return
	end

	-- Cooldown reduction: the Mana runes' CDR, stamped as the replicated
	-- CooldownReductionPercent attribute by PlayerStatsService (Abyss
	-- doubling included). MUST mirror the client chain in MagicController.
	local cooldownMultiplier = 1 - (player:GetAttribute("CooldownReductionPercent") or 0)

	local newCooldown = MagicData[vfxName].cooldown * cooldownMultiplier

	if MagicData[vfxName].isAura then
		newCooldown = math.clamp(newCooldown, MagicData[vfxName].lifetime, MagicData[vfxName].cooldown)
	else
		newCooldown = math.clamp(newCooldown, MagicData[vfxName].duration, MagicData[vfxName].cooldown)
	end

	MagicService:SetPlayerMagicData(
		player,
		MagicService:GetPlayerMagicData(player).mana - effectiveManaCost,
		MagicService:GetPlayerMagicData(player).maxMana
	)
	MagicService:SetPlayerMagicLastUsed(player, vfxName, tick())
	MagicService:SetPlayerMagicCooldown(player, vfxName, newCooldown)

	-- Mystical Staff of Cyan: the cast is COMMITTED (mana paid, cooldown
	-- stamped), so drop a sigil at the caster's feet. Equipped casts
	-- only -- relic magic never reaches this remote, same rule as the
	-- aura procs above. Placed here, not in the proc block, so a cast
	-- rejected for mana/cooldown can't paint the floor.
	if RelicService:GetSpecificRelicRegistry(player, RelicNames["Mystical Staff of Cyan"]) > 0 then
		self.Server:_spawnMagicSigil(player)
	end

	if self.Server._vfxReplicationQueue[player.UserId] == nil then
		self.Server._vfxReplicationQueue[player.UserId] = {}
	end

	self.Server._vfxReplicationQueue[player.UserId][vfxName] = true

	local duration = MagicData[vfxName] and MagicData[vfxName].duration or 1

	player.Character:SetAttribute(Attributes.MagicEnabled, true)

	-- CAST CUTSCENE i-frames. A spell with `cutscene` in MagicData holds
	-- the caster in a cinematic beat on their client (bars, no control);
	-- taking hits through it would be unfair and unseen. Server-owned,
	-- because the client's CutscenePlaying attribute never replicates.
	-- No highlight: the spell's own presentation is the feedback. The
	-- duration mirrors the client's beat (CutsceneController's default
	-- when the entry sets none).
	local cutscene = MagicData[vfxName].cutscene
	if cutscene and cutscene.enabled == true and InvulnerabilityService then
		InvulnerabilityService:ApplyTo(player.Character, cutscene.duration or DEFAULT_MAGIC_CUTSCENE_SECONDS, false)
	end

	self.Server:_toggleWeaponTransparency(player, 1)

	local magicIndexData = MagicData[vfxName]
	local activePlayer = player

	if magicIndexData.superArmorDuration and magicIndexData.superArmorDuration > 0 then
		activePlayer.Character:SetAttribute(Attributes.SuperArmor, true)

		task.delay(magicIndexData.superArmorDuration, function()
			if activePlayer.Character then
				activePlayer.Character:SetAttribute(Attributes.SuperArmor, false)
			end
		end)
	end

	task.delay(duration, function()
		if activePlayer.Character then
			self.Server:_toggleWeaponTransparency(activePlayer, 0)

			activePlayer.Character:SetAttribute(Attributes.MagicEnabled, false)
		end
	end)

	local modifiedVfxName = vfxName:gsub(" ", "")

	if vfxName == MagicNames["Domain Expansion"] then
		player.Character:SetAttribute(Attributes.DomainExpansionActive, true)
	end

	if vfxServer:FindFirstChild(modifiedVfxName) then
		local vfxAttack = self.Server._vfxRegistry[modifiedVfxName](activePlayer)

		self.Server._vfxAuraRegistry[activePlayer] = {
			name = vfxName,
			attack = vfxAttack,
			lastAttacked = 0,
			attackInterval = MagicData[vfxName].attackInterval,
			-- The rig gets AURA_ACTIVATION_DELAY to arrive before it can swing.
			readyAt = tick() + AURA_ACTIVATION_DELAY,
		}
	end

	if (cframe.Position - activePlayer.Character.HumanoidRootPart.Position).Magnitude > 10 then
		warn("[VFXService] Player attempted to cast magic too far from their character:", player)
		cframe = activePlayer.Character.HumanoidRootPart.CFrame
	end

	self.OnVFXReplicated:FireAll(activePlayer, vfxName, cframe)
end

function VFXService.Client:OnVFXHitboxRequested(player: Player, activePlayer: Player, vfxName: string, cframe: CFrame)
	if
		not self.Server:_checkVFXOwned(activePlayer, vfxName)
		or self.Server._vfxReplicationQueue[activePlayer.UserId] == nil
		or self.Server._vfxReplicationQueue[activePlayer.UserId][vfxName] == nil
		or self.Server._vfxReplicationQueue[activePlayer.UserId][vfxName] == false
	then
		return
	end

	-- TODO: Reimplement, exploiters can send same player objects
	-- Ensure that only the active player can trigger hitbox effects for their VFX
	if player ~= activePlayer then
		return
	end

	local magicIndexData = MagicData[vfxName] or {}

	self.Server._playerDetectedPartsRegistry[activePlayer.UserId][vfxName] = {}

	if magicIndexData.hitboxCount and magicIndexData.hitboxCount > 1 then
		if self.Server._playerDetectedPartsRegistry[activePlayer.UserId][vfxName].hitboxCount == nil then
			self.Server._playerDetectedPartsRegistry[activePlayer.UserId][vfxName].hitboxCount = 0
		end

		self.Server._playerDetectedPartsRegistry[activePlayer.UserId][vfxName].hitboxCount += 1
	end

	self.Server:CreateHitbox(
		vfxName,
		activePlayer,
		cframe,
		if activePlayer == nil then TagList.Player else TagList.Zombie,
		IgnoreListService:GetWeaponIgnoreList(),
		function(model: Model)
			onHitboxDamage(model, cframe, activePlayer, magicIndexData, true, false)
		end,
		magicIndexData.hitboxSize.X
	)

	if magicIndexData.hitboxCount and magicIndexData.hitboxCount > 1 then
		if
			self.Server._playerDetectedPartsRegistry[activePlayer.UserId][vfxName].hitboxCount
			== magicIndexData.hitboxCount
		then
			self.Server._vfxReplicationQueue[player.UserId][vfxName] = false
		end
	else
		self.Server._vfxReplicationQueue[player.UserId][vfxName] = false
	end
end

function VFXService.Client:OnVFXSweepHitboxRequested(
	player: Player,
	activePlayer: Player,
	vfxName: string,
	cframe: CFrame
)
	if
		not self.Server:_checkVFXOwned(activePlayer, vfxName)
		or self.Server._vfxReplicationQueue[activePlayer.UserId] == nil
		or self.Server._vfxReplicationQueue[activePlayer.UserId][vfxName] ~= true
	then
		return
	end

	if player ~= activePlayer then
		return
	end

	local magicIndexData = MagicData[vfxName] or {}

	local overlapIgnoreList = IgnoreListService:GetWeaponIgnoreList()

	local direction = cframe.LookVector

	-- reset registry for this cast
	if not self.Server._playerDetectedPartsRegistry[activePlayer.UserId] then
		self.Server._playerDetectedPartsRegistry[activePlayer.UserId] = {}
	end

	self.Server._playerDetectedPartsRegistry[activePlayer.UserId][vfxName] = {}

	local stepDistance = magicIndexData.stepDistance
	local travelDistance = magicIndexData.travelDistance

	-- ONE cast shake up front (players around the launch point feel it the
	-- moment the beam fires). The per-step CreateHitbox calls below skip
	-- theirs: ~100 steps × 0.01s re-triggered the shake every frame, which
	-- kept resetting its fade-in envelope so nothing was visible until the
	-- sweep ENDED — the "delayed shake" bug. Enemies damaged along the
	-- path still fire their own shake from onHitboxDamage.
	local character = activePlayer.Character
	if magicIndexData.cameraShake and character then
		CameraShakeService.OnGetBoundsInShakeRadius:Fire(
			character,
			cframe,
			magicIndexData.hitboxSize.X,
			CameraShakePresets.Medium
		)
	end

	for distance = 0, travelDistance, stepDistance do
		task.wait(0.01)

		local stepCFrame = cframe + (direction * distance)

		self.Server:CreateHitbox(
			vfxName,
			activePlayer,
			stepCFrame,
			TagList.Zombie,
			overlapIgnoreList,
			function(model: Model)
				onHitboxDamage(model, stepCFrame, activePlayer, magicIndexData, true, false)
			end,
			magicIndexData.hitboxSize.X,
			true
		)
	end

	self.Server._vfxReplicationQueue[player.UserId][vfxName] = false
end

function VFXService.Client:OnVFXPersistentHitboxRequested(
	player: Player,
	activePlayer: Player,
	vfxName: string,
	cframe: CFrame
)
	if
		not self.Server:_checkVFXOwned(activePlayer, vfxName)
		or self.Server._vfxReplicationQueue[activePlayer.UserId] == nil
		or self.Server._vfxReplicationQueue[activePlayer.UserId][vfxName] ~= true
	then
		return
	end

	if player ~= activePlayer then
		return
	end

	local magicIndexData = MagicData[vfxName] or {}

	-- reset registry for this cast
	if not self.Server._playerDetectedPartsRegistry[activePlayer.UserId] then
		self.Server._playerDetectedPartsRegistry[activePlayer.UserId] = {}
	end

	self.Server._playerDetectedPartsRegistry[activePlayer.UserId][vfxName] = {}

	local hitboxDuration = magicIndexData.hitboxDuration
	local elapsed = 0

	task.spawn(function()
		while elapsed < hitboxDuration do
			self.Server:CreateHitbox(
				vfxName,
				activePlayer,
				cframe,
				TagList.Zombie,
				IgnoreListService:GetWeaponIgnoreList(),
				function(model: Model)
					onHitboxDamage(model, cframe, activePlayer, magicIndexData, true, false)
				end,
				magicIndexData.hitboxSize.X
			)

			task.wait(magicIndexData.hitboxIncrement)

			elapsed += magicIndexData.hitboxIncrement
		end

		if vfxName == MagicNames["Domain Expansion"] then
			player.Character:SetAttribute(Attributes.DomainExpansionActive, false)
		end

		self.Server._vfxReplicationQueue[player.UserId][vfxName] = false
	end)
end

--[ Initializers ]--

function VFXService:KnitStart()
	IgnoreListService = Knit.GetService("IgnoreListService")
	PlayerEventService = Knit.GetService("PlayerEventService")
	CameraShakeService = Knit.GetService("CameraShakeService")
	MagicService = Knit.GetService("MagicService")
	MagicLoadoutService = Knit.GetService("MagicLoadoutService")
	RelicService = Knit.GetService("RelicService")
	ShieldService = Knit.GetService("ShieldService")
	InvulnerabilityService = Knit.GetService("InvulnerabilityService")

	for _, vfxModule in pairs(vfxServer:GetChildren()) do
		if vfxModule:IsA("ModuleScript") then
			local vfxName = vfxModule.Name:gsub(" ", "")
			self._vfxRegistry[vfxName] = require(vfxModule)
		end
	end

	PlayerEventService.OnPlayerAdded:Connect(function(player: Player)
		self._playerDetectedPartsRegistry[player.UserId] = {}
	end)

	PlayerEventService.OnPlayerRemoved:Connect(function(player: Player)
		self._playerDetectedPartsRegistry[player.UserId] = nil

		if self._vfxReplicationQueue[player.UserId] then
			self._vfxReplicationQueue[player.UserId] = nil
		end

		if self._vfxAuraRegistry[player] then
			self._vfxAuraRegistry[player] = nil
		end

		if self._vfxAttackRegistry[player] then
			task.cancel(self._vfxAttackRegistry[player])
			self._vfxAttackRegistry[player] = nil
		end
	end)

	self._weaponOverlapParams.FilterType = Enum.RaycastFilterType.Exclude
	self._weaponOverlapParams.FilterDescendantsInstances = IgnoreListService:GetWeaponIgnoreList()
end

function VFXService:KnitInit() end

return VFXService
