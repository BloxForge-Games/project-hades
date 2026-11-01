--!strict
--[[
	Module: Server/Services/ShieldService.lua
	Description:
	The Shield system (the user-facing name since the 2026-11-01 Earth
	rework; "Barrier" between the element rework and that). A player's pool
	is a list of independent BUCKETS; each bucket remembers its APPLIER
	(players can shield other players) and an optional TAG.

	The tag is how a relic keys off ITS shields ending without this module
	knowing the relic: GrantShield(..., tag) stamps the bucket, and when an
	applier's LAST bucket with that tag on a holder ends -- absorbed dry by
	damage OR expired, both count -- OnTaggedShieldEnded fires (holder,
	applier, tag). Bundle of TNT (RelicGimmickService/Earth) grants
	tagged shields on Orb pickups and explodes on that signal.

	Non-Earth hook living here:
	  * Korblox Ice Claws (duo): when a holder who owns it loses their last
	    Shield, it shatters for Arcane Damage and Chills (_shatterIceShell).

	Every other relic that used to live here (Golden Steampunk Gloves, Space
	Sandwich, Cheezburger, Robloxian Battle Shield, Spartan Sword and
	Shield, Earth Summoning Horn's share, Golem's Hammer's hit-shield and
	tremor loop, the old "your Shields explode" TNT) is retired with the
	2026-11-01 Earth rework. Their entry points stay as no-ops (see
	"Retired entry points") until their callers are removed.

	Cap: the SUM of live buckets never exceeds 100% of the holder's
	MaxHealth. Absorption drains soonest-expiring buckets first, after all
	damage mitigation (getDamageService() calls AbsorbShieldDamage last).

	The "ShieldValue" attribute on the character carries the visible total
	(client UI + shieldGate consumers read it).
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local TextIndicatorService = require(ServerScriptService.Submodules.Core.Source.Services.TextIndicatorService)
local RelicService = require(ServerScriptService.Services.RelicService)
local Breakable = require(ServerScriptService.Components.Breakable)
local RelicNetwork = require(ServerScriptService.Submodules.Core.Source.Network.Relic)
local AuraNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.AuraNames)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local RelicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicData)
local getRelicLevel = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Player.getRelicLevel)
local getRoot = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Character.getRoot)
local forEachEnemyInRadius = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Combat.forEachEnemyInRadius)
local StatusConditions = require(ReplicatedStorage.Submodules.Core.Shared.Enums.StatusConditions)
local Signal = require(ReplicatedStorage.Submodules.Core.Shared.Types.Signal)
local Blitz = require(ReplicatedStorage.Submodules.Core.Shared.Blitz)

-- DamageService requires this module at load, so this side reaches it
-- lazily: required on first use, once both modules exist.
local damageServiceLazy: any = nil
local function getDamageService(): any
	if damageServiceLazy == nil then
		damageServiceLazy = (require :: any)(ServerScriptService.Services.DamageService)
	end
	return damageServiceLazy
end

local ShieldService = {
	Name = "ShieldService",
	Dependencies = { TextIndicatorService, RelicService } :: { any },
}

--[ Signals ]--

-- (holder, applier, tag): applier's last `tag` bucket on holder ended,
-- expired or absorbed dry. Fired only for TAGGED grants.
ShieldService.OnTaggedShieldEnded = Signal.new() :: Signal.Signal<Player, Player, string>

--[ Constants ]--

-- Bucket-expiry poll cadence. Poll-don't-delay: buckets are pruned by
-- the watcher loop rather than per-bucket task.delays, so an absorb that
-- empties a bucket early never races a stale timer.
local EXPIRY_POLL_SECONDS = 0.1

local SHIELD_ATTRIBUTE = "ShieldValue"
-- Ceiling on the SUM of live buckets, as a fraction of the HOLDER's
-- MaxHealth. Raised to 100% with the element rework.
local SHIELD_CAP_FRACTION = 1.00

--[ Properties ]--

type ShieldBucket = { value: number, expiresAt: number, ownerId: number, tag: string? }
type ShieldState = {
	character: Model,
	userId: number,
	buckets: { ShieldBucket },
	emitters: { ParticleEmitter },
	attachments: { Instance },
	running: boolean,
}

-- [userId] = { character, userId, buckets, emitters, attachments, running }
-- buckets: { { value, expiresAt, ownerId, tag? }, ... }
ShieldService._pools = {} :: { [number]: ShieldState }

-- Korblox Ice Claws per-player last-proc clock.
ShieldService._iceShellLastAt = {} :: { [number]: number }

--[ Private ]--

-- Pool state keyed by userId but VALIDATED against character identity:
-- a respawn replaces the character instance, so stale buckets from the
-- previous life are dropped on first touch instead of leaking onto the
-- new character.
function ShieldService._getState(self: typeof(ShieldService), player: Player): ShieldState?
	local character = player.Character
	if not character then
		return nil
	end
	local state = self._pools[player.UserId]
	if not state or state.character ~= character then
		local fresh: ShieldState = {
			character = character,
			userId = player.UserId,
			buckets = {},
			emitters = {},
			attachments = {},
			running = false,
		}
		self._pools[player.UserId] = fresh
		state = fresh
	end
	return state
end

local function totalOf(state: ShieldState): number
	local total = 0
	for _, bucket in state.buckets do
		total += bucket.value
	end
	return total
end

-- The key an applier's tagged buckets share.
local function tagKey(ownerId: number, tag: string): string
	return tostring(ownerId) .. "|" .. tag
end

-- The set of (applier, tag) pairs with at least one live bucket in this
-- pool: diffed across every removal to find whose tagged shields ended.
local function taggedSetOf(state: ShieldState): { [string]: { ownerId: number, tag: string } }
	local tagged = {}
	for _, bucket in state.buckets do
		if bucket.tag then
			tagged[tagKey(bucket.ownerId, bucket.tag)] = { ownerId = bucket.ownerId, tag = bucket.tag }
		end
	end
	return tagged
end

-- Drops buckets whose clock has run out. Returns true if anything was
-- removed, so callers know to re-stamp.
local function pruneExpired(state: ShieldState): boolean
	local now = os.clock()
	local removed = false
	for index = #state.buckets, 1, -1 do
		if state.buckets[index].expiresAt <= now then
			table.remove(state.buckets, index)
			removed = true
		end
	end
	return removed
end

function ShieldService._stamp(_self: typeof(ShieldService), state: ShieldState)
	if state.character.Parent then
		local total = totalOf(state)
		state.character:SetAttribute(SHIELD_ATTRIBUTE, if total > 0 then math.round(total) else nil)
	end
end

-- Bursts every tracked emitter so a grant reads INSTANTLY -- the authored
-- Rate is slow (ambient shimmer).
function ShieldService._burstEmitters(_self: typeof(ShieldService), state: ShieldState)
	for _, emitter in state.emitters do
		if emitter.Parent then
			emitter:Emit(1)
		end
	end
end

function ShieldService._spawnVisuals(self: typeof(ShieldService), state: ShieldState, _player: Player)
	local hrp = getRoot(state.character)
	if not hrp then
		return
	end

	-- Asset contract: GameAssets.Auras.Shielded.Main is an ATTACHMENT
	-- holding the ParticleEmitter(s).
	local aurasFolder = ReplicatedStorage.GameAssets:FindFirstChild("Auras")
	local template = aurasFolder and aurasFolder:FindFirstChild(AuraNames.Shielded)
	local mainTemplate = template and template:FindFirstChild("Main")
	if not mainTemplate then
		warn("[ShieldService] Missing ReplicatedStorage.GameAssets.Auras." .. AuraNames.Shielded .. ".Main")
	else
		local mainAttachment = mainTemplate:Clone()
		mainAttachment.Name = AuraNames.Shielded
		mainAttachment.Parent = hrp
		-- The ATTACHMENT is tracked for destruction; the EMITTERS inside it
		-- are tracked separately for disable/burst (Attachment has no
		-- .Enabled).
		table.insert(state.attachments, mainAttachment)
		for _, descendant in mainAttachment:GetDescendants() do
			if descendant:IsA("ParticleEmitter") then
				descendant.Enabled = true
				table.insert(state.emitters, descendant)
			end
		end
		self:_burstEmitters(state)
	end
end

-- Fires OnTaggedShieldEnded for every (applier, tag) that was in `before`
-- but has no bucket left now.
function ShieldService._fireEndedTags(
	self: typeof(ShieldService),
	state: ShieldState,
	before: { [string]: { ownerId: number, tag: string } }
)
	local after = taggedSetOf(state)
	local holder = Players:GetPlayerFromCharacter(state.character)
	for key, entry in before do
		if after[key] then
			continue
		end
		local applier = Players:GetPlayerByUserId(entry.ownerId)
		if holder and applier then
			self.OnTaggedShieldEnded:Fire(holder, applier, entry.tag)
		end
	end
end

-- Korblox Ice Claws (duo, 2026-10-30): the holder's Shields are gone, so
-- their ice shell shatters: per-level Arcane Damage and a Chill to every
-- enemy in data.radius, at most once per data.cooldownSeconds.
function ShieldService._shatterIceShell(self: typeof(ShieldService), state: ShieldState)
	local player = Players:GetPlayerFromCharacter(state.character)
	local hrp = getRoot(state.character)
	if not player or not hrp or not RelicService then
		return
	end
	if (RelicService:GetSpecificRelicRegistry(player, RelicNames["Korblox Ice Claws"]) or 0) <= 0 then
		return
	end
	local entry = RelicData[RelicNames["Korblox Ice Claws"]]
	local data = (entry and entry.data) or {}
	local now = os.clock()
	if now - (self._iceShellLastAt[player.UserId] or -math.huge) < (data.cooldownSeconds or 3) then
		return
	end
	self._iceShellLastAt[player.UserId] = now
	local damage =
		math.round((RelicService:GetRelicEffect(player, RelicNames["Korblox Ice Claws"]) or 0) * getRelicLevel(player))
	local radius = data.radius or 12
	local position = hrp.Position
	RelicNetwork.GimmickEffect.FireAll({
		Kind = "IceShellShatter",
		Caster = player,
		From = position,
		To = position,
		Radius = radius,
		Duration = 0,
		StartTime = workspace:GetServerTimeNow(),
	})
	Breakable.HitInRadius(position, radius, player)
	local damageService = getDamageService()
	local statusService = Blitz.OptionalService("StatusConditionService")
	forEachEnemyInRadius(position, radius, function(model: Model, targetHumanoid: Humanoid)
		if damage > 0 and damageService then
			damageService:WithRelicKnockback(function()
				damageService:TakeDamage(player, targetHumanoid, damage, true, false, false)
			end)
		end
		if statusService then
			statusService:ApplyStatus(player, model, StatusConditions.Chill)
		end
	end)
end

function ShieldService._teardown(self: typeof(ShieldService), state: ShieldState)
	table.clear(state.buckets)
	self:_stamp(state)
	-- Both end paths (absorbed dry, watcher exit) land here, sometimes
	-- twice in a row; the shatter's cooldown keeps it to one.
	if state.character.Parent then
		task.spawn(function()
			self:_shatterIceShell(state)
		end)
	end

	-- Disable emitters first so in-flight particles fade naturally, then
	-- destroy their host attachments after the fade window.
	for _, emitter in state.emitters do
		if emitter.Parent then
			emitter.Enabled = false
		end
	end
	local attachments = state.attachments
	state.attachments = {}
	table.clear(state.emitters)

	task.delay(1, function()
		for _, attachment in attachments do
			attachment:Destroy()
		end
	end)
end

-- One watcher per shielded player. Prunes expired buckets on a poll and
-- exits when the last bucket dies -- absorbed dry or expired -- or the
-- character goes away. Tagged buckets that lapse mid-window report from
-- here.
function ShieldService._ensureWatcher(self: typeof(ShieldService), state: ShieldState)
	if state.running then
		return
	end
	state.running = true
	task.spawn(function()
		while state.character.Parent and #state.buckets > 0 do
			task.wait(EXPIRY_POLL_SECONDS)
			local before = taggedSetOf(state)
			if pruneExpired(state) then
				self:_stamp(state)
				self:_fireEndedTags(state, before)
			end
		end
		state.running = false
		self:_teardown(state)
	end)
end

--[ Public API ]--

-- Grants a NEW shield bucket on `targetPlayer`, applied by
-- `applierPlayer`, worth `fraction` of the APPLIER's MaxHealth, lasting
-- `duration` seconds. Self-grants pass the same player twice. `tag`
-- (optional) marks the bucket for OnTaggedShieldEnded. Returns the
-- granted value (0 when nothing landed).
function ShieldService.GrantShield(
	self: typeof(ShieldService),
	applierPlayer: Player,
	targetPlayer: Player,
	fraction: number,
	duration: number,
	tag: string?
): number
	local state = self:_getState(targetPlayer)
	if not state then
		return 0
	end
	local humanoid = state.character:FindFirstChildOfClass("Humanoid")
	local applierHumanoid = applierPlayer.Character and applierPlayer.Character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 or not applierHumanoid then
		return 0
	end

	pruneExpired(state)

	-- Trim to the cap's remaining headroom (fraction of the HOLDER's max).
	local headroom = (humanoid.MaxHealth * SHIELD_CAP_FRACTION) - totalOf(state)
	if headroom <= 0 then
		return 0
	end
	local value = math.min(applierHumanoid.MaxHealth * fraction, headroom)

	local wasEmpty = #state.buckets == 0

	table.insert(state.buckets, {
		value = value,
		expiresAt = os.clock() + duration,
		ownerId = applierPlayer.UserId,
		tag = tag,
	})
	self:_stamp(state)

	if wasEmpty then
		local gainAuraSound = ReplicatedStorage.GameAssets.Sounds.GainAura:Clone()
		gainAuraSound.Parent = getRoot(state.character)
		gainAuraSound:Play()

		Debris:AddItem(gainAuraSound, 2)

		self:_spawnVisuals(state, targetPlayer)
	else
		self:_burstEmitters(state)
	end

	-- Pop on EVERY grant -- fresh or stacked.
	if TextIndicatorService then
		local head = (state.character:FindFirstChild("Head") or getRoot(state.character)) :: BasePart?
		if head then
			TextIndicatorService:ShowIndicator(
				targetPlayer,
				head,
				-- The enum stays "Shielded" because marker names and the aura
				-- ASSET folder are keyed on it.
				"Shield!",
				Color3.fromRGB(220, 220, 220)
			)
		end
	end
	self:_ensureWatcher(state)

	return value
end

-- Spends buckets against `damage`, returning what they couldn't absorb.
-- Called by DamageService:PlayerTakeDamage after every damage reduction
-- and before Humanoid application. Buckets drain soonest-expiring first;
-- tagged buckets absorbed dry report from here.
function ShieldService.AbsorbShieldDamage(self: typeof(ShieldService), player: Player, damage: number): number
	local state = self._pools[player.UserId]
	if not state or state.character ~= player.Character then
		return damage
	end

	local before = taggedSetOf(state)

	pruneExpired(state)
	if #state.buckets == 0 then
		self:_fireEndedTags(state, before)
		return damage
	end

	table.sort(state.buckets, function(a, b)
		return a.expiresAt < b.expiresAt
	end)

	local remaining = damage
	for index = 1, #state.buckets do
		local bucket = state.buckets[index]
		local absorbed = math.min(bucket.value, remaining)
		bucket.value -= absorbed
		remaining -= absorbed
		if remaining <= 0 then
			break
		end
	end

	for index = #state.buckets, 1, -1 do
		if state.buckets[index].value <= 0 then
			table.remove(state.buckets, index)
		end
	end

	self:_stamp(state)
	self:_fireEndedTags(state, before)

	if #state.buckets == 0 then
		self:_teardown(state)
	end

	return remaining
end

function ShieldService.GetShieldValue(self: typeof(ShieldService), player: Player): number
	local state = self._pools[player.UserId]
	if not state or state.character ~= player.Character then
		return 0
	end
	pruneExpired(state)
	return totalOf(state)
end

--[ Retired entry points ]--

-- The relics behind these left with the 2026-11-01 Earth rework (their
-- RelicData rows are `retired`). DamageService, VFXService and
-- MeleeWeapon still call in; each is a no-op so nothing dead runs, and
-- the method can go the day its caller does.
function ShieldService.TrySpaceSandwichBarrier(_self: typeof(ShieldService), _player: Player) end
function ShieldService.TryPebblePouchBarrier(_self: typeof(ShieldService), _player: Player) end
function ShieldService.TryGoldenGlovesBarrier(_self: typeof(ShieldService), _player: Player) end
function ShieldService.TryRobloxionShield(_self: typeof(ShieldService), _player: Player) end
function ShieldService.TryGolemBarrier(_self: typeof(ShieldService), _player: Player) end

--[ Lifecycle ]--

function ShieldService.Start(self: typeof(ShieldService))
	Players.PlayerRemoving:Connect(function(player: Player)
		self._pools[player.UserId] = nil
		self._iceShellLastAt[player.UserId] = nil
	end)
end

return ShieldService
