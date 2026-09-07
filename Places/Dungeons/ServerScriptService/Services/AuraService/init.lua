--[[
	Module: AuraService.lua
	Description:
	Grants and tracks the five element auras (Enflamed / Frostburst /
	Blighted / Stormcharged / Stonebound) plus the Shielded marker
	ShieldService owns. Durations and buff magnitudes live in
	Shared/Data/AuraData — this service owns granting, extension, and the
	marker contract.

	MARKER CONTRACT (load-bearing): an HRP child whose Name == the aura
	name IS the aura. Every consumer gates on FindFirstChild(auraName);
	the marker carries the "AuraExpiresAt" deadline attribute, and aura
	modules rename it ("<Aura>Fading") before their fade-out so a re-grant
	during the grace second takes the fresh-grant path.

	STONEBOUND SPREADS FROM EVERY SOURCE. Any self-grant of it carries to
	allies within STONEBOUND_SPREAD_RADIUS and plays the shockwave once on
	the source (_spreadStonebound, fired from SetAura's fresh-grant path).
	Riot Shield, Space Sandwich and Spartan Sword and Shield all get this
	for free, and so does anything added later — it is a property of the
	aura, not of one relic.

	STONEBOUND is the special one: ONE instance per target across ALL
	owners. Its payload (+damage / +damage reduction) is computed from the
	OWNER's relics (Leland the Lolturtle, Spartan Sword and Shield) and
	stamped on the marker as attributes; a NEW application replaces the
	live one only when its payload is STRONGER (sum of both fractions).
	Same-owner re-grants extend like any aura.
]]

--[ Roblox Services ]--

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--[ Exports & Types & Defaults ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local AuraNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.AuraNames)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local AuraData = require(ReplicatedStorage.Submodules.Core.Shared.Data.AuraData)
local RelicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicData)
local Enflamed = require(script.AuraServer.Enflamed)
local Frostburst = require(script.AuraServer.Frostburst)
local Stormcharged = require(script.AuraServer.Stormcharged)
local Blighted = require(script.AuraServer.Blighted)
local Stonebound = require(script.AuraServer.Stonebound)

local RelicService

local AuraService = Knit.CreateService({
	Name = "AuraService",
	Client = {},
})

--[ Constants ]--

-- Attribute stamped on the HRP aura marker holding its os.clock() deadline.
-- The aura modules poll it instead of a fixed task.delay, which is what lets
-- a re-grant push the expiry out mid-flight.
local EXPIRY_ATTRIBUTE = "AuraExpiresAt"

-- Stonebound payload attributes, stamped on ITS marker (replicated — the
-- damage pipeline and client UI read them).
local STONEBOUND_DAMAGE_ATTRIBUTE = "StoneboundDamageBonus"
local STONEBOUND_REDUCTION_ATTRIBUTE = "StoneboundDamageReduction"
local STONEBOUND_OWNER_ATTRIBUTE = "StoneboundOwnerId"

-- Aura-duration extensions, summed ADDITIVELY (both owned = +75%, never
-- 1.25 x 1.5), read from the RECEIVER ("your auras"). Flaming Orb of
-- Divine Pain pays for its +50% with +25% damage taken while an aura is up
-- (DamageService:PlayerTakeDamage).
local AURA_DURATION_BONUSES = {
	{ relicName = RelicNames["Flaming Orb of Divine Pain"], bonus = 0.5 },
	{ relicName = RelicNames["Spray Paint"], bonus = 0.25 },
}

-- How far Stonebound carries to allies. Every source spreads — Riot
-- Shield, Space Sandwich, Spartan Sword and Shield, and anything added
-- later — but ONLY from the player who earned it; recipients never pass
-- it on. This is a property of the aura, not of one relic. It reaches
-- the swinger and every ally in radius. The chance lives in the relic
-- callback; the radius and the flourish's shape live here.
local STONEBOUND_SPREAD_RADIUS = 14

-- EVERY aura pops its element's shockwave on a fresh grant (the
-- Stonebound proc flourish, generalized). Template part per aura under
-- GameAssets.VFX; auras with no entry (Shielded, Empower) just skip.
local AURA_SHOCKWAVE_TEMPLATES = {
	[AuraNames.Enflamed] = "EnflamedShockwave",
	[AuraNames.Frostburst] = "FrostburstShockwave",
	-- Asset name drops the aura's -ed.
	[AuraNames.Blighted] = "BlightShockwave",
	[AuraNames.Stormcharged] = "StormchargedShockwave",
	[AuraNames.Stonebound] = "StoneboundShockwave",
}
local AURA_SHOCKWAVE_EMIT_COUNT = 2
local AURA_SHOCKWAVE_LIFETIME = 3

--[ Private Functions ]--

-- The element shockwave for a freshly granted aura: the matching VFX
-- part cloned to the middle of the receiver's torso and burst once.
-- One-shot: it STAYS WHERE IT SPAWNED — a ground shockwave, not a
-- rider. Parenting the template's attachment into the HRP instead was
-- tried and reverted: riding the character made the burst read wrong
-- (it inherits the HRP's orientation and drags the ground plane with
-- the player). Debris collects it after the authored particles die out.
--
-- Fires on FRESH grants only (SetAura's extend branch returns first),
-- and spread-received Stonebound stays silent — that flourish belongs
-- to the source. Auras without a template entry simply skip.
local function playAuraShockwave(character: Model, auraName: string)
	local templateName = AURA_SHOCKWAVE_TEMPLATES[auraName]
	if not templateName then
		return
	end
	local torso = character:FindFirstChild("HumanoidRootPart")

	if not torso then
		return
	end

	local vfxFolder = ReplicatedStorage.GameAssets:FindFirstChild("VFX")
	local template = vfxFolder and vfxFolder:FindFirstChild(templateName)
	if not template then
		warn("[AuraService] Missing GameAssets.VFX." .. templateName)
		return
	end

	local shockwave = template:Clone()
	if shockwave:IsA("BasePart") then
		shockwave.Anchored = true
		shockwave.CanCollide = false
		shockwave.CanQuery = false
	end

	shockwave:PivotTo(torso.CFrame)
	shockwave.Parent = workspace.IgnoreInstances.MagicSpells

	-- Parent FIRST, burst SECOND -- :Emit on an unparented emitter is
	-- silently discarded.
	for _, descendant in shockwave:GetDescendants() do
		if descendant:IsA("ParticleEmitter") then
			descendant:Emit(AURA_SHOCKWAVE_EMIT_COUNT)
		end
	end

	Debris:AddItem(shockwave, AURA_SHOCKWAVE_LIFETIME)
end

-- The OWNER-relic riders on a Stonebound payload. Base magnitudes are
-- AuraData's; Leland and Spartan enlarge what this owner's Stonebound
-- gives its users.
function AuraService:_computeStoneboundPayload(ownerPlayer: Player): (number, number)
	local config = AuraData[AuraNames.Stonebound]
	local damageBonus = config.damagePercent
	local damageReduction = config.damageReduction

	if RelicService then
		if (RelicService:GetSpecificRelicRegistry(ownerPlayer, RelicNames["Spartan Sword and Shield"]) or 0) > 0 then
			damageBonus += RelicService:GetRelicEffect(ownerPlayer, RelicNames["Spartan Sword and Shield"]) or 0
		end
		-- Leland rides BOTH halves now. The callback carries the Damage
		-- Reduction; the damage half is in RelicData `data`, because a
		-- callback returns one number.
		if (RelicService:GetSpecificRelicRegistry(ownerPlayer, RelicNames["Leland the Lolturtle"]) or 0) > 0 then
			damageReduction += RelicService:GetRelicEffect(ownerPlayer, RelicNames["Leland the Lolturtle"]) or 0
			local lelandData = RelicData[RelicNames["Leland the Lolturtle"]]
			damageBonus += (lelandData and lelandData.data and lelandData.data.damageBonus) or 0
		end
	end

	return damageBonus, damageReduction
end

--[ Public Functions ]--

-- The live Stonebound payload on a character, for the damage pipeline:
-- (damageBonus, damageReduction), both 0 when the aura isn't up.
function AuraService:GetStoneboundPayload(character: Model?): (number, number)
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	local marker = hrp and hrp:FindFirstChild(AuraNames.Stonebound)
	if not marker then
		return 0, 0
	end
	return marker:GetAttribute(STONEBOUND_DAMAGE_ATTRIBUTE) or 0,
		marker:GetAttribute(STONEBOUND_REDUCTION_ATTRIBUTE) or 0
end

-- Riot Shield (Earth Rare): a MELEE hit that LANDS has the relic's chance
-- to grant its owner Stonebound.
--
-- The SPREAD is not this relic's job any more. Every Stonebound grant
-- carries to nearby allies now (see _spreadStonebound), so this rolls and
-- grants, and the aura handles the rest.
--
-- ONE caller: MeleeWeapon, once per SWING, owning a per-swing latch — so
-- a cleave through three mobs is ONE roll. It briefly also fired on ranged
-- hits; the card is "Melee Weapon Damage" again, and a shot has no swing
-- to latch onto anyway (a shotgun would have rolled per pellet).
function AuraService:TryRiotShieldStonebound(player: Player)
	if not RelicService then
		return
	end
	if (RelicService:GetSpecificRelicRegistry(player, RelicNames["Riot Shield"]) or 0) <= 0 then
		return
	end

	local chance = RelicService:GetRelicEffect(player, RelicNames["Riot Shield"]) or 0
	if chance <= 0 or math.random() > chance then
		return
	end

	local character = player.Character
	if not character then
		return
	end
	self:SetAura(player, AuraNames.Stonebound, character)
end

-- Pushes a fresh Stonebound out to every ally within
-- STONEBOUND_SPREAD_RADIUS, and plays the shockwave once on the source.
--
-- Called from SetAura on any SELF-grant of Stonebound, so it covers every
-- source the tree has (melee hit, takedown, magic cast) and any future one
-- for free.
--
-- `ownerPlayer` rides along on each grant for two reasons: recipients get
-- a payload shaped by the SOURCE's Leland / Spartan riders rather than
-- their own, AND it is what marks the grant as a spread so the recipient
-- does not pass it on again.
function AuraService:_spreadStonebound(ownerPlayer: Player, ownerCharacter: Model)
	local hrp = ownerCharacter and ownerCharacter:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return
	end

	-- No shockwave here: SetAura's fresh-grant hook already played it on
	-- the source, and recipients are deliberately silent.
	for _, other in Players:GetPlayers() do
		if other ~= ownerPlayer then
			local otherCharacter = other.Character
			local otherHrp = otherCharacter and otherCharacter:FindFirstChild("HumanoidRootPart")
			if otherHrp and (otherHrp.Position - hrp.Position).Magnitude <= STONEBOUND_SPREAD_RADIUS then
				self:SetAura(other, AuraNames.Stonebound, otherCharacter, nil, ownerPlayer)
			end
		end
	end
end

-- Grants `auraName` to `character` for `duration` seconds (defaults from
-- AuraData). `player` is the RECEIVER — their Spray Paint extends it,
-- their Sword of Eternal Abyss blocks it. `ownerPlayer` matters only for
-- Stonebound, whose payload follows the GRANTER's relics; nil = self.
--
-- EXTEND-ONLY on re-grant: the deadline moves out only when the new one is
-- LATER, and visuals never respawn (no strobe).
function AuraService:SetAura(
	player: Player,
	auraName: string,
	character: Model,
	duration: number?,
	ownerPlayer: Player?
)
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return
	end

	-- Sword of Eternal Abyss (Cursed): its owner gains NO auras, full stop.
	-- Gated at the entry point so every aura source is covered.
	if RelicService and RelicService:GetSpecificRelicRegistry(player, RelicNames["Sword of Eternal Abyss"]) > 0 then
		return
	end

	local config = AuraData[auraName]
	local resolvedDuration = duration or (config and config.duration)

	-- Duration extensions, applied at the GRANT so the extend-only re-grant
	-- math below just works. Summed first, then applied once.
	if resolvedDuration and RelicService then
		local bonus = 0
		for _, row in AURA_DURATION_BONUSES do
			if (RelicService:GetSpecificRelicRegistry(player, row.relicName) or 0) > 0 then
				bonus += row.bonus
			end
		end
		if bonus > 0 then
			resolvedDuration *= 1 + bonus
		end
	end

	local marker = hrp:FindFirstChild(auraName)

	-- Stonebound's one-per-target rule: a second owner's application
	-- REPLACES the live one only when its payload is stronger; weaker or
	-- equal from a different owner is a no-op. Same-owner falls through to
	-- the ordinary extend below.
	if auraName == AuraNames.Stonebound and marker then
		local owner = ownerPlayer or player
		local currentOwnerId = marker:GetAttribute(STONEBOUND_OWNER_ATTRIBUTE)
		if currentOwnerId ~= owner.UserId then
			local newDamage, newReduction = self:_computeStoneboundPayload(owner)
			local currentStrength = (marker:GetAttribute(STONEBOUND_DAMAGE_ATTRIBUTE) or 0)
				+ (marker:GetAttribute(STONEBOUND_REDUCTION_ATTRIBUTE) or 0)
			if newDamage + newReduction > currentStrength then
				-- Stronger: tear the old one down NOW (no fade grace — the
				-- replacement's rig takes over) and fall through to a fresh
				-- grant.
				marker:Destroy()
				marker = nil
			else
				return
			end
		end
	end

	-- Already active → extend the deadline in place and stop.
	--
	-- SILENT by design: the text pop belongs to a BRAND-NEW application
	-- only. A refresh changes nothing the player can see (the visuals
	-- deliberately don't respawn), and high-frequency procs — a 25%
	-- per-crit Stormcharge, a Riot Shield party grant — would machine-gun
	-- identical text over the head every few hits. Each aura module fires
	-- the pop itself on the fresh-grant path.
	if marker and resolvedDuration then
		local newExpiry = os.clock() + resolvedDuration
		if newExpiry > (marker:GetAttribute(EXPIRY_ATTRIBUTE) or 0) then
			marker:SetAttribute(EXPIRY_ATTRIBUTE, newExpiry)
		end
		return
	end

	local gainAuraSound = ReplicatedStorage.GameAssets.Sounds.GainAura:Clone()
	gainAuraSound.Parent = hrp
	gainAuraSound:Play()

	Debris:AddItem(gainAuraSound, 2)

	-- The element shockwave, for EVERY aura — fresh grants only (the
	-- extend branch returned above; no strobe on refresh). The owner
	-- check keeps spread-received Stonebound silent, same as always.
	if ownerPlayer == nil or ownerPlayer == player then
		playAuraShockwave(character, auraName)
	end

	if auraName == AuraNames.Enflamed then
		Enflamed(player, character, resolvedDuration)
	elseif auraName == AuraNames.Frostburst then
		Frostburst(player, character, resolvedDuration)
	elseif auraName == AuraNames.Stormcharged then
		Stormcharged(player, character, resolvedDuration)
	elseif auraName == AuraNames.Blighted then
		Blighted(player, character, resolvedDuration)
	elseif auraName == AuraNames.Stonebound then
		local owner = ownerPlayer or player
		local damageBonus, damageReduction = self:_computeStoneboundPayload(owner)
		Stonebound(player, character, resolvedDuration, {
			ownerId = owner.UserId,
			damageBonus = damageBonus,
			damageReduction = damageReduction,
		})

		-- ONLY THE OWNER SPREADS. A player who RECEIVES Stonebound never
		-- passes it on — otherwise one proc would bounce around the party
		-- forever, and standing near a teammate would be a permanent aura.
		--
		-- The test is stateless on purpose: every spread grant carries the
		-- SOURCE as `ownerPlayer`, and _spreadStonebound skips the source
		-- itself, so `ownerPlayer ~= player` is exactly "this is a spread
		-- arriving". No reentrancy flag — a shared boolean would have to
		-- survive the grant below yielding, and would wrongly suppress a
		-- second player's proc if it ever did.
		--
		-- On the FRESH-grant path deliberately. The extend-only branch
		-- returns earlier, so a player sitting inside a teammate's
		-- Stonebound does not re-fire a shockwave on every refresh.
		if ownerPlayer == nil or ownerPlayer == player then
			self:_spreadStonebound(player, character)
		end
	end
end

--[ Initializers ]--

function AuraService:KnitStart()
	RelicService = Knit.GetService("RelicService")
end

function AuraService:KnitInit() end

return AuraService
