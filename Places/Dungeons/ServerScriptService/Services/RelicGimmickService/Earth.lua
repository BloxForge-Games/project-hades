--!strict
--[[
	Module: RelicGimmickService/Earth
	Description:
	Earth's gimmicks after the 2026-11-01 rework (Orbs and Fracture). Every
	hit here is a relic burst on the untyped lane; every number is the
	relic's RelicData `data`:

	  Golden Steampunk Gloves  every swingsDaggers / swingsSword /
	                        swingsGreatsword melee SWING (4 / 3 / 2) sends a
	                        shockwave out of the enemy the swing struck
	                        (or just ahead when it struck nothing):
	                        Power-scaled damage in `radius` and Fracture on
	                        everything in it.
	  Earth Protection Orb  THE ORB BANK: a Health or Mana Orb collected
	                        while that bar is at storeThreshold (95%) of
	                        its max is stored (up to maxOrbs; DropService
	                        asks OrbBankIntercept before restoring). Every
	                        spendInterval the bank spends one orb if a bar
	                        is below the threshold, Health first, at the
	                        orb's normal value. The stored orbs ride the
	                        character's EarthOrbBank attribute (one letter
	                        per orb, H / M) for EarthOrbBankController.
	  Bundle of TNT         an Orb pickup grants a shieldPercent Shield for
	                        shieldSeconds, tagged; when the owner's last
	                        tagged Shield ends (expired or broken,
	                        ShieldService.OnTaggedShieldEnded) it explodes
	                        for damagePerLevel x level in `radius`,
	                        Fracturing everything hit, once per
	                        cooldownSeconds.
	  Earth Summoning Horn  every Orb pickup pulses a shockwave of
	                        damagePerLevel x level in `radius` (one per
	                        cooldownSeconds) and gives every OTHER player
	                        inside it the same restore the owner got.
	  Golem's Hammer        Orbs restore orbMultiplier (DropService). While
	                        in combat (a living mob within `radius`, or
	                        damage dealt or taken within COMBAT_LINGER) the
	                        ground quakes every quakeEverySeconds for
	                        damagePerLevel x level in `radius`, x
	                        fracturedMultiplier on enemies already
	                        Fractured, then Fractures everything hit.

	The visuals are helpers.fx packets (RelicGimmickFXController draws
	Boulder, Shockwave and Quake) and the TNT blast's own broadcast
	(RelicNetwork.TntExplosionEffect, drawn by RelicController).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local StatusConditions = require(ReplicatedStorage.Submodules.Core.Shared.Enums.StatusConditions)
local DropTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.DropTypes)
local getRoot = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Character.getRoot)
local forEachEnemyInRadius = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Combat.forEachEnemyInRadius)
local combatProximity = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Combat.combatProximity)
local RelicNetwork = require(ServerScriptService.Submodules.Core.Source.Network.Relic)
local helpers = require(script.Parent.Lib.gimmickHelpers)

local GLOVES = RelicNames["Golden Steampunk Gloves"]
local ORB_BANK = RelicNames["Earth Protection Orb"]
local TNT = RelicNames["Bundle of TNT"]
local HORN = RelicNames["Earth Summoning Horn"]
local GOLEM = RelicNames["Golem's Hammer"]

-- The character attribute carrying the bank: one letter per stored orb
-- (ORB_LETTERS), nil when empty. EarthOrbBankController reads it.
local ORB_BANK_ATTRIBUTE = "EarthOrbBank"
local ORB_LETTERS: { [string]: string } = {
	[DropTypes.Health] = "H",
	[DropTypes.Mana] = "M",
}

-- Bundle of TNT's Shields carry this tag, so only THEY detonate when they
-- end (ShieldService.OnTaggedShieldEnded).
local TNT_SHIELD_TAG = "BundleOfTnt"

-- How long the Horn's shockwave ring takes to reach its radius.
local SHOCKWAVE_SECONDS = 0.45

-- Golem's Hammer: damage dealt or taken keeps the owner "in combat" this
-- long after the last hit, on top of the living-mob proximity check.
local COMBAT_LINGER_SECONDS = 4

local Earth = {}

--[ State ]--

type Bank = { orbs: { string }, lastSpend: number }
local banks: { [Player]: Bank } = {}

local lastTntBlast: { [Player]: number } = {}
local lastShockwave: { [Player]: number } = {}

type GolemState = {
	lastQuake: number,
	lastCombat: number,
	-- The character whose Humanoid.HealthChanged is being watched for
	-- damage taken, and that connection.
	character: Model?,
	healthConnection: RBXScriptConnection?,
}
local golems: { [Player]: GolemState } = {}

local function dropService(): any
	return helpers.service("DropService")
end

local function shieldService(): any
	return helpers.service("ShieldService")
end

-- The relic-burst hit every Earth blast lands: damage (when any), then
-- Fracture.
local function fractureHit(player: Player, model: Model, humanoid: Humanoid, damage: number)
	if damage > 0 then
		helpers.takeDamage(player, humanoid, damage, false, false, nil, true)
	end
	helpers.statusService():ApplyStatus(player, model, StatusConditions.Fractured)
end

local function isFractured(model: Model): boolean
	return helpers.statusService():IsStatusActive(model, StatusConditions.Fractured) == true
end

--[ Golden Steampunk Gloves ]--

local glovesSwings: { [Player]: number } = {}
-- The last enemy this swing struck (onMeleeHit runs per mob before the
-- swing hook): where the Nth swing's shockwave bursts. Cleared per swing.
local glovesLastTarget: { [Player]: Model } = {}

-- The shockwave out of `center`: every enemy in `radius` takes the
-- Power-scaled damage and is Fractured. Drawn with the Horn's ring kind,
-- in a short pulse.
local function glovesShockwave(player: Player, center: Vector3)
	local radius = helpers.data(GLOVES, "radius", 8)
	helpers.fx("Shockwave", center - Vector3.new(0, 2.5, 0), nil, radius, 0.4, player)
	helpers.hitBreakables(player, center, radius)
	local damage = helpers.levelDamage(player, helpers.data(GLOVES, "damagePerLevel", 20))
	forEachEnemyInRadius(center, radius, function(other: Model, humanoid: Humanoid)
		fractureHit(player, other, humanoid, damage)
	end)
end

-- Counts one melee SWING (2026-11-01; hits per mob before); the Nth (by
-- weapon weight: swingsDaggers / swingsSword / swingsGreatsword) bursts
-- the shockwave at the enemy the swing struck, or just ahead of the
-- player when it struck nothing, and starts the count over.
local function countGlovesSwing(player: Player, origin: Vector3, look: Vector3, weaponType: string?)
	local target = glovesLastTarget[player]
	glovesLastTarget[player] = nil
	if not helpers.owns(player, GLOVES) then
		glovesSwings[player] = nil
		return
	end
	local count = (glovesSwings[player] or 0) + 1
	if count >= helpers.swingsFor(GLOVES, weaponType) then
		count = 0
		local targetRoot = if target and target.Parent then getRoot(target) else nil
		local center = if targetRoot then targetRoot.Position else origin + look * 3
		glovesShockwave(player, center)
	end
	glovesSwings[player] = count
end

--[ Earth Protection Orb ]--

local function stampBank(player: Player, bank: Bank?)
	local character = player.Character
	if not character then
		return
	end
	local letters = ""
	if bank then
		for _, dropType in bank.orbs do
			letters ..= ORB_LETTERS[dropType] or "H"
		end
	end
	character:SetAttribute(ORB_BANK_ATTRIBUTE, if letters ~= "" then letters else nil)
end

local function clearBank(player: Player)
	if banks[player] then
		banks[player] = nil
		stampBank(player, nil)
	end
end

-- The fraction of its max a bar is at: Health from the Humanoid, Mana
-- from ArcaneService's data. Nil when the bar cannot be read.
local function barFraction(player: Player, dropType: string): number?
	if dropType == DropTypes.Health then
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not humanoid or humanoid.MaxHealth <= 0 then
			return nil
		end
		return humanoid.Health / humanoid.MaxHealth
	elseif dropType == DropTypes.Mana then
		local arcaneService = helpers.service("ArcaneService")
		local arcaneData = arcaneService:GetPlayerArcaneData(player)
		if not arcaneData or (arcaneData.maxMana or 0) <= 0 then
			return nil
		end
		return arcaneData.mana / arcaneData.maxMana
	end
	return nil
end

-- DropService asks this before restoring a Health or Mana Orb. True
-- means the orb went into the bank and restores nothing now.
local function interceptOrb(player: Player, dropType: string): boolean
	if not ORB_LETTERS[dropType] or not helpers.owns(player, ORB_BANK) then
		return false
	end
	-- Stored only when the bar is at or above storeThreshold (95% since
	-- 2026-11-01: an orb heals 5%, so a bar it could not fill counts as
	-- full; 90% before, which banked orbs the player still needed). A
	-- sliver under still counts so float rounding never blocks it.
	local fraction = barFraction(player, dropType)
	if fraction == nil or fraction < helpers.data(ORB_BANK, "storeThreshold", 0.95) - 0.001 then
		return false
	end
	local bank = banks[player]
	if not bank then
		bank = { orbs = {}, lastSpend = 0 }
		banks[player] = bank
	end
	if #bank.orbs >= helpers.data(ORB_BANK, "maxOrbs", 5) then
		return false
	end
	table.insert(bank.orbs, dropType)
	stampBank(player, bank)
	return true
end

-- One bank's spend step: the oldest stored orb OF THE KIND a bar needs
-- becomes that bar's restore, Health first (2026-11-01: the oldest orb of
-- any kind used to go, so a Mana orb healed). A low bar with no orb of
-- its kind stored waits; the other bar is checked next.
local function spendFromBank(player: Player, bank: Bank, now: number)
	if #bank.orbs == 0 or now - bank.lastSpend < helpers.data(ORB_BANK, "spendInterval", 1) then
		return
	end
	local threshold = helpers.data(ORB_BANK, "spendThreshold", 0.9)
	for _, dropType in { DropTypes.Health, DropTypes.Mana } do
		local fraction = barFraction(player, dropType)
		if fraction == nil or fraction >= threshold then
			continue
		end
		local index = table.find(bank.orbs, dropType)
		if not index then
			continue
		end
		bank.lastSpend = now
		table.remove(bank.orbs, index)
		stampBank(player, bank)
		local drops = dropService()
		drops:RestoreOrb(player, dropType, drops:OrbRestoreMultiplier(player))
		return
	end
end

--[ Bundle of TNT ]--

-- Applier `owner`'s last TNT Shield on `holder` just ended: the blast at
-- the holder, once per cooldownSeconds per owner.
local function detonateTnt(owner: Player, holder: Player)
	if not owner.Parent or not helpers.owns(owner, TNT) then
		return
	end
	local root = getRoot.fromPlayer(holder)
	if not root then
		return
	end
	local now = os.clock()
	if now - (lastTntBlast[owner] or -math.huge) < helpers.data(TNT, "cooldownSeconds", 3) then
		return
	end
	lastTntBlast[owner] = now

	local position = root.Position
	local radius = helpers.data(TNT, "radius", 10)
	local damage = helpers.levelDamage(owner, helpers.data(TNT, "damagePerLevel", 30))
	-- Every client plays GameAssets.VFX.BundleOfTNT.Explosion there
	-- (RelicController's handler).
	RelicNetwork.TntExplosionEffect.FireAll(position)
	helpers.hitBreakables(owner, position, radius)
	forEachEnemyInRadius(position, radius, function(model: Model, humanoid: Humanoid)
		fractureHit(owner, model, humanoid, damage)
	end)
end

--[ Earth Summoning Horn ]--

-- An Orb `player` just collected: the shockwave (rate limited) and the
-- share to every other player inside the radius (every time).
local function hornPulse(player: Player, dropType: string)
	local root = getRoot.fromPlayer(player)
	if not root then
		return
	end
	local radius = helpers.data(HORN, "radius", 15)
	local drops = dropService()
	local multiplier = drops:OrbRestoreMultiplier(player)
	for _, other in Players:GetPlayers() do
		if other ~= player then
			local otherRoot = getRoot.fromPlayer(other)
			if otherRoot and (otherRoot.Position - root.Position).Magnitude <= radius then
				drops:RestoreOrb(other, dropType, multiplier)
			end
		end
	end

	local now = os.clock()
	if now - (lastShockwave[player] or -math.huge) < helpers.data(HORN, "cooldownSeconds", 0.5) then
		return
	end
	lastShockwave[player] = now
	local damage = helpers.levelDamage(player, helpers.data(HORN, "damagePerLevel", 20))
	helpers.fx("Shockwave", root.Position, nil, radius, SHOCKWAVE_SECONDS, player)
	helpers.hitBreakables(player, root.Position, radius)
	forEachEnemyInRadius(root.Position, radius, function(_model: Model, humanoid: Humanoid)
		if damage > 0 then
			helpers.takeDamage(player, humanoid, damage, false, false, nil, true)
		end
	end)
end

-- Every Health or Mana Orb a player collects (DropService.OnDropCollected;
-- a banked orb counts too, the pickup happened).
local function onOrbCollected(player: Player, dropType: string, _value: number)
	if not ORB_LETTERS[dropType] then
		return
	end
	if helpers.owns(player, TNT) then
		shieldService():GrantShield(
			player,
			player,
			helpers.data(TNT, "shieldPercent", 0.1),
			helpers.data(TNT, "shieldSeconds", 5),
			TNT_SHIELD_TAG
		)
	end
	if helpers.owns(player, HORN) then
		hornPulse(player, dropType)
	end
end

--[ Golem's Hammer ]--

local function dropGolem(player: Player)
	local state = golems[player]
	if not state then
		return
	end
	if state.healthConnection then
		state.healthConnection:Disconnect()
	end
	golems[player] = nil
end

local function markCombat(player: Player)
	local state = golems[player]
	if state then
		state.lastCombat = os.clock()
	end
end

-- Keeps the owner's state on their CURRENT character: the Humanoid's
-- HealthChanged marks damage taken as combat.
local function ensureGolem(player: Player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not character or not humanoid then
		return
	end
	local state = golems[player]
	if not state then
		state = { lastQuake = 0, lastCombat = -math.huge, character = nil, healthConnection = nil }
		golems[player] = state
	end
	if state.character == character then
		return
	end
	if state.healthConnection then
		state.healthConnection:Disconnect()
	end
	state.character = character
	local lastHealth = humanoid.Health
	state.healthConnection = humanoid.HealthChanged:Connect(function(health: number)
		if health < lastHealth then
			markCombat(player)
		end
		lastHealth = health
	end)
end

local function inCombat(state: GolemState, root: BasePart, now: number): boolean
	if now - state.lastCombat < COMBAT_LINGER_SECONDS then
		return true
	end
	return combatProximity.isNearLivingMob(root.Position, helpers.data(GOLEM, "radius", 12))
end

local function quake(player: Player, root: BasePart)
	local radius = helpers.data(GOLEM, "radius", 12)
	local damage = helpers.levelDamage(player, helpers.data(GOLEM, "damagePerLevel", 20))
	local fracturedMultiplier = helpers.data(GOLEM, "fracturedMultiplier", 2)
	helpers.fx("Quake", root.Position, nil, radius, nil, player)
	helpers.hitBreakables(player, root.Position, radius)
	forEachEnemyInRadius(root.Position, radius, function(model: Model, humanoid: Humanoid)
		local dealt = if isFractured(model) then math.round(damage * fracturedMultiplier) else damage
		fractureHit(player, model, humanoid, dealt)
	end)
end

--[ Handlers ]--

function Earth.onMeleeSwing(
	player: Player,
	origin: Vector3,
	look: Vector3,
	_swingDamage: number,
	_connected: boolean,
	weaponType: string?
)
	countGlovesSwing(player, origin, look, weaponType)
end

function Earth.onMeleeHit(player: Player, model: Model, _damage: number)
	if helpers.owns(player, GLOVES) then
		glovesLastTarget[player] = model
	end
end

-- Every weapon or spell hit: damage dealt keeps a Golem owner in combat.
function Earth.onAttackHit(player: Player, _model: Model, _isMagic: boolean)
	markCombat(player)
end

function Earth.onHeartbeat(now: number)
	for player, bank in banks do
		spendFromBank(player, bank, now)
	end
	for player, state in golems do
		local root = getRoot.fromPlayer(player)
		local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		if not root or not humanoid or humanoid.Health <= 0 then
			continue
		end
		if now - state.lastQuake >= helpers.data(GOLEM, "quakeEverySeconds", 3) and inCombat(state, root, now) then
			state.lastQuake = now
			quake(player, root)
		end
	end
end

-- Once a second: the relics' state follows ownership (a dropped relic
-- empties the bank and stops the quakes), and the Golem watcher follows
-- the character.
function Earth.onTick(player: Player)
	if not helpers.owns(player, ORB_BANK) then
		clearBank(player)
	else
		-- A new character has no attribute yet: restamp so the ring comes
		-- back after a respawn and nothing stored is lost unspent.
		local bank = banks[player]
		local character = player.Character
		if bank and #bank.orbs > 0 and character and character:GetAttribute(ORB_BANK_ATTRIBUTE) == nil then
			stampBank(player, bank)
		end
	end
	if helpers.owns(player, GOLEM) then
		ensureGolem(player)
	else
		dropGolem(player)
	end
end

function Earth.onPlayerRemoved(player: Player)
	glovesSwings[player] = nil
	glovesLastTarget[player] = nil
	banks[player] = nil
	lastTntBlast[player] = nil
	lastShockwave[player] = nil
	dropGolem(player)
end

--[ Wiring ]--

-- Required by RelicGimmickService.Start, once every service has run Init,
-- so the Dungeons services it hooks exist.
do
	local drops = dropService()
	drops.OrbBankIntercept = interceptOrb
	drops.OnDropCollected:Connect(onOrbCollected)
	shieldService().OnTaggedShieldEnded:Connect(function(holder: Player, applier: Player, tag: string)
		if tag == TNT_SHIELD_TAG then
			detonateTnt(applier, holder)
		end
	end)
end

return Earth
