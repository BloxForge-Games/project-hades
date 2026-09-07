--[[
	Module: Server/Services/ShieldService.lua
	Description:
	The Barrier system (user-facing name for shields since the element
	rework). A player's pool is a list of independent BUCKETS; each bucket
	remembers its APPLIER — players can shield OTHER players now (Earth
	Summoning Horn), and two Earth relics key off exactly who applied what:

	  * Bundle of TNT: when the LAST bucket applier X owns on a holder
	    ends — absorbed dry by damage OR expired, both count — it explodes
	    to enemies near the holder for
	        (X's Level x 20) + 35% of X's BONUS Maximum Health
	    Both terms read X, not the holder: the blast belongs to whoever
	    applied the shield. Two TNT owners shielding one target chain two
	    independent explosions.
	  * Earth Summoning Horn: Barriers X applies to THEMSELVES are shared
	    (75% of the value) with allies within its radius.

	Other Earth hooks living here:
	  * Earth Protection Orb: +50% on Barrier VALUE while its owner is
	    Stonebound, both for Barriers they gain and Barriers they give.
	  * Golden Steampunk Gloves: +5% Barrier for 5s on a MELEE hit, rate
	    limited by BARRIER_PROC_COOLDOWN (MeleeWeapon calls
	    TryGoldenGlovesBarrier). This replaced Space Sandwich's
	    damage-taken proc in the 2026-08 pass.
	  * Spartan Sword and Shield: grants Stonebound on a magic cast
	    (VFXService calls TrySpartanStonebound).
	  * Golem's Hammer: while holding a Barrier, the Empower rig sits on
	    the HRP and a Tremor pulses every second for (Level x the relic
	    callback, 50) damage in a radius. (Its Stonebound clause was dropped in the 2026-09
	    un-gating pass.)

	Cap: the SUM of live buckets never exceeds 100% of the holder's
	MaxHealth. Absorption drains soonest-expiring buckets first, after all
	damage mitigation (DamageService calls AbsorbShieldDamage last).

	The "ShieldValue" attribute on the character carries the visible total
	(client UI + shieldGate consumers read it).
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local AuraNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.AuraNames)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local RelicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicData)
local getPlayerLevel = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Player.getPlayerLevel)

local TextIndicatorService
local RelicService
local DamageService

local ShieldService = Knit.CreateService({
	Name = "ShieldService",
	Client = {},
})

--[ Constants ]--

-- Bucket-expiry poll cadence. Poll-don't-delay: buckets are pruned by
-- the watcher loop rather than per-bucket task.delays, so an absorb that
-- empties a bucket early never races a stale timer.
local EXPIRY_POLL_SECONDS = 0.1

local SHIELD_ATTRIBUTE = "ShieldValue"
-- Ceiling on the SUM of live buckets, as a fraction of the HOLDER's
-- MaxHealth. Raised to 100% with the element rework.
local SHIELD_CAP_FRACTION = 1.00

-- Earth Summoning Horn: allies within this radius receive this
-- fraction of shields the owner applies to themselves.
local SUMMONING_HORN_RADIUS = 15

-- Space Sandwich: internal cooldown between procs, so a mob swarm can't
-- keep the shield permanently topped.
-- GLOBAL Barrier cooldown, per applier+target pair. Every proc-driven
-- Barrier source respects it, so a new one cannot be added without a
-- rate limit by accident — Golden Steampunk Gloves rolls on every melee
-- hit, which without this would keep a Barrier permanently up and make
-- its +35% damage unconditional.
--
-- Deliberately NOT applied to the TNT detonation path or to any grant
-- that is already once-per-cast (Robloxian fires on a cast the player
-- paid mana for, and rate-limiting that would feel like a dropped input).
local BARRIER_PROC_COOLDOWN = 3
-- Fallback only: RelicData's `barrierSeconds` is the authored value and
-- is what actually applies. Kept equal so a missing data table cannot
-- silently shorten the Barrier.
local GOLDEN_GLOVES_DURATION = 5

-- Robloxian Battle Shield: duration of the on-cast shield (the fraction
-- lives in its relic callback).
local ROBLOXION_SHIELD_DURATION = 5

-- Bundle of TNT explosion. The blast is FUSED rather than instant: the
-- shield ending and the explosion reading as one event made it impossible
-- to tell which one killed you, and a beat of delay is what sells it as a
-- bundle of dynamite going off.
local TNT_EXPLOSION_RADIUS = 10
local TNT_FUSE_SECONDS = 0

-- Golem's Hammer tremor loop. The rig is dropped BELOW the character so it
-- reads as ground shaking under them rather than a ring at the waist.
--
-- Only the ground MESH blooms in. The particle bursts emit at full authored
-- opacity, because ParticleEmitter.Transparency applies to particles that
-- are already ALIVE — ramping it in spends the whole lifetime of a
-- short-lived spark while it's still invisible, so the burst reads as
-- half-missing. Everything fades OUT together; that end was the genuinely
-- abrupt one, and at a 1s pulse interval two tremors overlap, so a hard cut
-- there reads as a strobe.
local TREMOR_INTERVAL = 1
local TREMOR_RADIUS = 10
local TREMOR_Y_OFFSET = 1.5
local TREMOR_EMIT_COUNT = 5
local TREMOR_FADE_OUT_SECONDS = 0.9
-- Total on-screen life; the hold is whatever the two fades don't spend.

--[ Properties ]--

-- [userId] = { character, userId, buckets, emitters, attachments,
--              running, golemRunning }
-- buckets: { { value, expiresAt, ownerId }, ... }
ShieldService._pools = {}

-- Space Sandwich per-player last-proc clock.
ShieldService._barrierProcLastAt = {}

--[ Private ]--

-- Pool state keyed by userId but VALIDATED against character identity:
-- a respawn replaces the character instance, so stale buckets from the
-- previous life are dropped on first touch instead of leaking onto the
-- new character.
function ShieldService:_getState(player: Player)
	local character = player.Character
	if not character then
		return nil
	end
	local state = self._pools[player.UserId]
	if not state or state.character ~= character then
		state = {
			character = character,
			userId = player.UserId,
			buckets = {},
			emitters = {},
			attachments = {},
			running = false,
			golemRunning = false,
		}
		self._pools[player.UserId] = state
	end
	return state
end

local function totalOf(state): number
	local total = 0
	for _, bucket in state.buckets do
		total += bucket.value
	end
	return total
end

-- The set of appliers with at least one live bucket in this pool —
-- Bundle of TNT diffs it across every removal to find whose shields ended.
local function ownerSetOf(state): { [number]: boolean }
	local owners = {}
	for _, bucket in state.buckets do
		owners[bucket.ownerId] = true
	end
	return owners
end

-- Drops buckets whose clock has run out. Returns true if anything was
-- removed, so callers know to re-stamp.
local function pruneExpired(state): boolean
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

function ShieldService:_stamp(state)
	if state.character.Parent then
		local total = totalOf(state)
		state.character:SetAttribute(SHIELD_ATTRIBUTE, if total > 0 then math.round(total) else nil)
	end
end

-- Bursts every tracked emitter so a grant reads INSTANTLY — the authored
-- Rate is slow (ambient shimmer).
function ShieldService:_burstEmitters(state)
	for _, emitter in state.emitters do
		if emitter.Parent then
			emitter:Emit(1)
		end
	end
end

function ShieldService:_spawnVisuals(state, _player: Player)
	local hrp = state.character:FindFirstChild("HumanoidRootPart")
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

-- Bundle of TNT: applier X's last bucket on this holder just ended.
-- Explodes AT THE HOLDER for (X's Level x 20) + 35% of X's BONUS max health.
function ShieldService:_detonateTnt(ownerId: number, holderCharacter: Model)
	local owner = Players:GetPlayerByUserId(ownerId)
	if not owner or not RelicService then
		return
	end
	if (RelicService:GetSpecificRelicRegistry(owner, RelicNames["Bundle of TNT"]) or 0) <= 0 then
		return
	end

	local hrp = holderCharacter and holderCharacter:FindFirstChild("HumanoidRootPart")
	local ownerHumanoid = owner.Character and owner.Character:FindFirstChildOfClass("Humanoid")
	if not hrp or not ownerHumanoid then
		return
	end

	-- Blast math, read off the OWNER (the applier), never the holder. The
	-- callback IS the per-level damage, so this number has one home in
	-- RelicData and cannot drift from the card.
	local damagePerLevel = RelicService:GetRelicEffect(owner, RelicNames["Bundle of TNT"]) or 0
	local blastDamage = math.round(getPlayerLevel(owner) * damagePerLevel)
	if blastDamage <= 0 then
		return
	end

	-- Fuse. Position is captured NOW so the blast lands where the shield
	-- ended even if the holder walks off, and so the VFX and the damage
	-- sweep share one point.
	local blastPosition = hrp.Position
	task.delay(TNT_FUSE_SECONDS, function()
		-- Explosion VFX: GameAssets.VFX.BundleOfTNT.Explosion — burst every
		-- emitter and play every sound authored on it.
		local vfxFolder = ReplicatedStorage.GameAssets:FindFirstChild("VFX")
		local tntFolder = vfxFolder and vfxFolder:FindFirstChild("BundleOfTNT")
		local explosionTemplate = tntFolder and tntFolder:FindFirstChild("Explosion")
		if explosionTemplate then
			local explosion = explosionTemplate:Clone()
			-- ANCHOR FIRST. The Sound is a 3D positional sound parented to the
			-- rig's BasePart, so an unanchored part drops it away from the
			-- listener under gravity and the roll-off silences it within a
			-- fraction of a second -- while the burst still looks correct,
			-- because :Emit particles are world-space and stay where they spawned.
			-- Same normalisation every other rig in this file does.
			for _, part in explosion:GetDescendants() do
				if part:IsA("BasePart") then
					part.Anchored = true
					part.CanCollide = false
					part.CanQuery = false
				end
			end
			explosion:PivotTo(CFrame.new(blastPosition))
			explosion.Parent = workspace.IgnoreInstances.MagicSpells
			for _, descendant in explosion:GetDescendants() do
				if descendant:IsA("ParticleEmitter") then
					descendant:Emit(10)
				elseif descendant:IsA("Sound") then
					descendant:Play()
				end
			end
			Debris:AddItem(explosion, 5)
		else
			warn("[ShieldService] Missing GameAssets.VFX.BundleOfTNT.Explosion")
		end

		if DamageService then
			local overlapParams = OverlapParams.new()
			overlapParams.FilterType = Enum.RaycastFilterType.Include
			overlapParams.FilterDescendantsInstances = { workspace.IgnoreInstances.Zombies }
			local struck = {}
			for _, part in workspace:GetPartBoundsInRadius(blastPosition, TNT_EXPLOSION_RADIUS, overlapParams) do
				local model = part:FindFirstAncestorWhichIsA("Model")
				if not model or struck[model] then
					continue
				end
				local targetHumanoid = model:FindFirstChildOfClass("Humanoid")
				if not targetHumanoid or targetHumanoid.Health <= 0 then
					continue
				end
				struck[model] = true
				-- Relic-sourced flat damage (never rolls appliers as a weapon
				-- swing would).
				DamageService:TakeDamage(owner, targetHumanoid, blastDamage, false, false, nil, true)
			end
		end
	end)
end

-- Fires the TNT check for every applier who was in `before` but has no
-- bucket left now.
function ShieldService:_detonateEndedOwners(state, before: { [number]: boolean })
	local after = ownerSetOf(state)
	for ownerId in before do
		if not after[ownerId] then
			task.spawn(function()
				self:_detonateTnt(ownerId, state.character)
			end)
		end
	end
end

function ShieldService:_teardown(state)
	table.clear(state.buckets)
	self:_stamp(state)

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
-- exits when the last bucket dies — absorbed dry or expired — or the
-- character goes away. TNT owners whose buckets lapse mid-window detonate
-- from here.
function ShieldService:_ensureWatcher(state)
	if state.running then
		return
	end
	state.running = true
	task.spawn(function()
		while state.character.Parent and #state.buckets > 0 do
			task.wait(EXPIRY_POLL_SECONDS)
			local before = ownerSetOf(state)
			if pruneExpired(state) then
				self:_stamp(state)
				self:_detonateEndedOwners(state, before)
			end
		end
		state.running = false
		self:_teardown(state)
	end)
end

-- Golem's Hammer: while the holder is Shielded, keep the Empower rig on
-- their HRP and pulse a Tremor every second — (Level x callback) damage to
-- everything in the radius.
function ShieldService:_ensureGolemLoop(state, player: Player)
	if state.golemRunning then
		return
	end
	if not RelicService or (RelicService:GetSpecificRelicRegistry(player, RelicNames["Golem's Hammer"]) or 0) <= 0 then
		return
	end
	state.golemRunning = true

	task.spawn(function()
		local empowerClone: Instance? = nil

		local function clearEmpower()
			if empowerClone then
				for _, descendant in empowerClone:GetDescendants() do
					if descendant:IsA("ParticleEmitter") then
						descendant.Enabled = false
					end
				end
				Debris:AddItem(empowerClone, 1)
				empowerClone = nil
			end
		end

		while state.character.Parent and #state.buckets > 0 do
			local hrp = state.character:FindFirstChild("HumanoidRootPart")
			local humanoid = state.character:FindFirstChildOfClass("Humanoid")
			local owned = (RelicService:GetSpecificRelicRegistry(player, RelicNames["Golem's Hammer"]) or 0) > 0

			if hrp and humanoid and humanoid.Health > 0 and owned then
				-- Empower rig up (GameAssets.Auras.Empower under the HRP).
				if not empowerClone or not empowerClone.Parent then
					local aurasFolder = ReplicatedStorage.GameAssets:FindFirstChild("Auras")
					local template = aurasFolder and aurasFolder:FindFirstChild(AuraNames.Empower)
					if template then
						empowerClone = template:Clone()
						empowerClone.Name = AuraNames.Empower
						empowerClone.Parent = hrp
					end
				end

				-- Tremor pulse: VFX + AoE damage. The callback IS the per-level
				-- per-second damage, so the pulse always pays out and the number
				-- lives only in RelicData.
				local damagePerLevel = RelicService:GetRelicEffect(player, RelicNames["Golem's Hammer"]) or 0
				local tremorDamage = math.round(getPlayerLevel(player) * damagePerLevel)

				local vfxFolder = ReplicatedStorage.GameAssets:FindFirstChild("VFX")
				local tremorFolder = vfxFolder and vfxFolder:FindFirstChild("Tremor")
				local tremorTemplate = tremorFolder and tremorFolder:FindFirstChild("Tremor")
				if tremorTemplate then
					local tremor = tremorTemplate:Clone()
					for _, part in tremor:GetDescendants() do
						if part:IsA("BasePart") then
							part.Anchored = true
							part.CanCollide = false
							part.CanQuery = false
						end
					end
					tremor:PivotTo(CFrame.new(hrp.Position - Vector3.new(0, TREMOR_Y_OFFSET, 0)))

					tremor.Parent = workspace.IgnoreInstances.MagicSpells

					for _, descendant in tremor.EarthTremor.Explode:GetDescendants() do
						if descendant:IsA("ParticleEmitter") then
							descendant:Emit(TREMOR_EMIT_COUNT)
						end
					end

					for _, descendant in tremor.EarthTremor.Main:GetDescendants() do
						if descendant:IsA("ParticleEmitter") then
							descendant:Emit(0.25)
						end
					end

					-- EVERY authored Sound on the rig, not a named subset: the
					-- asset carries more than one (Explosion1 + Stomp) and they
					-- sit on EarthTremor itself, outside the Explode attachment
					-- the emitters are scoped to. Same recipe as the Bundle of
					-- TNT blast, so adding a sound in Studio needs no code change.
					for _, descendant in tremor:GetDescendants() do
						if descendant:IsA("Sound") then
							descendant:Play()
						end
					end

					task.spawn(function()
						task.wait(0.5)

						for _, descendant in tremor:GetDescendants() do
							if descendant:IsA("ParticleEmitter") then
								descendant.Enabled = false
							end
						end

						task.wait(TREMOR_FADE_OUT_SECONDS)

						tremor:Destroy()
					end)
				end

				if tremorDamage > 0 and DamageService then
					local overlapParams = OverlapParams.new()
					overlapParams.FilterType = Enum.RaycastFilterType.Include
					overlapParams.FilterDescendantsInstances = { workspace.IgnoreInstances.Zombies }
					local struck = {}
					for _, part in workspace:GetPartBoundsInRadius(hrp.Position, TREMOR_RADIUS, overlapParams) do
						local model = part:FindFirstAncestorWhichIsA("Model")
						if not model or struck[model] then
							continue
						end
						local targetHumanoid = model:FindFirstChildOfClass("Humanoid")
						if not targetHumanoid or targetHumanoid.Health <= 0 then
							continue
						end
						struck[model] = true
						DamageService:TakeDamage(player, targetHumanoid, tremorDamage, false, false, nil, true)
					end
				end
			else
				clearEmpower()
			end

			task.wait(TREMOR_INTERVAL)
		end

		clearEmpower()
		state.golemRunning = false
	end)
end

--[ Public API ]--

-- Grants a NEW shield bucket on `targetPlayer`, applied by
-- `applierPlayer`, worth `fraction` of the APPLIER's MaxHealth, lasting
-- `duration` seconds. Self-grants pass the same player twice. Returns the
-- granted value (0 when nothing landed) so sharers (Earth Summoning Horn)
-- know what to mirror.
function ShieldService:GrantShield(
	applierPlayer: Player,
	targetPlayer: Player,
	fraction: number,
	duration: number
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

	-- Earth Protection Orb: +50% on the VALUE while its owner is
	-- Stonebound — covering Barriers they GIVE (owner is the applier) and
	-- Barriers they GAIN (owner is the target). A self-grant qualifies once.
	local valueMultiplier = 1
	if RelicService then
		local function orbBoost(player: Player): boolean
			if (RelicService:GetSpecificRelicRegistry(player, RelicNames["Earth Protection Orb"]) or 0) <= 0 then
				return false
			end
			local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
			return hrp ~= nil and hrp:FindFirstChild(AuraNames.Stonebound) ~= nil
		end
		if orbBoost(applierPlayer) or (targetPlayer ~= applierPlayer and orbBoost(targetPlayer)) then
			valueMultiplier = RelicService:GetRelicEffect(applierPlayer, RelicNames["Earth Protection Orb"])
				or RelicService:GetRelicEffect(targetPlayer, RelicNames["Earth Protection Orb"])
				-- Unreachable: orbBoost already proved one of the two owns it,
				-- so one of the reads above returns a number. Matches the card
				-- anyway so a future refactor cannot resurrect a stale 1.25.
				or 1.50
		end
	end

	-- Trim to the cap's remaining headroom (fraction of the HOLDER's max).
	local headroom = (humanoid.MaxHealth * SHIELD_CAP_FRACTION) - totalOf(state)
	if headroom <= 0 then
		return 0
	end
	local value = math.min(applierHumanoid.MaxHealth * fraction * valueMultiplier, headroom)

	local wasEmpty = #state.buckets == 0

	table.insert(state.buckets, {
		value = value,
		expiresAt = os.clock() + duration,
		ownerId = applierPlayer.UserId,
	})
	self:_stamp(state)

	if wasEmpty then
		local gainAuraSound = ReplicatedStorage.GameAssets.Sounds.GainAura:Clone()
		gainAuraSound.Parent = state.character:FindFirstChild("HumanoidRootPart")
		gainAuraSound:Play()

		Debris:AddItem(gainAuraSound, 2)

		self:_spawnVisuals(state, targetPlayer)
	else
		self:_burstEmitters(state)
	end

	-- Pop on EVERY grant — fresh or stacked.
	if TextIndicatorService then
		local head = state.character:FindFirstChild("Head") or state.character:FindFirstChild("HumanoidRootPart")
		if head then
			TextIndicatorService:ShowIndicator(
				targetPlayer,
				head,
				-- "Barrier" is the USER-FACING name; the enum stays "Shielded"
				-- because marker names and the aura ASSET folder are keyed on it.
				"Barrier!",
				Color3.fromRGB(220, 220, 220)
			)
		end
	end
	self:_ensureWatcher(state)

	-- Earth Summoning Horn: SELF-applied Barriers mirror 75% of the value
	-- to allies in radius. Gated to self-applies so the mirror can never
	-- recurse (mirrored grants are applier ~= target).
	--
	-- Allies no longer need to be Stonebound: the card says "Allies also
	-- receive", full stop, and the relic is NC now — requiring an aura the
	-- player may not be able to produce would make it dead on pickup.
	if
		applierPlayer == targetPlayer
		and RelicService
		and (RelicService:GetSpecificRelicRegistry(applierPlayer, RelicNames["Earth Summoning Horn"]) or 0) > 0
	then
		local shareFraction = RelicService:GetRelicEffect(applierPlayer, RelicNames["Earth Summoning Horn"]) or 0
		local hrp = state.character:FindFirstChild("HumanoidRootPart")
		if shareFraction > 0 and hrp then
			for _, ally in Players:GetPlayers() do
				if ally ~= applierPlayer then
					local allyCharacter = ally.Character
					local allyHrp = allyCharacter and allyCharacter:FindFirstChild("HumanoidRootPart")
					if allyHrp and (allyHrp.Position - hrp.Position).Magnitude <= SUMMONING_HORN_RADIUS then
						self:GrantShield(applierPlayer, ally, fraction * shareFraction, duration)
					end
				end
			end
		end
	end

	-- Golem's Hammer wants a loop whenever its owner is shielded.
	self:_ensureGolemLoop(state, targetPlayer)

	return value
end

-- Space Sandwich: called by DamageService when its owner takes damage.
-- Internal cooldown so a swarm can't keep the shield permanently topped.
-- Golden Steampunk Gloves: a MELEE hit rolls for a Barrier on its owner.
-- This slot used to be Space Sandwich's damage-taken proc; the 2026-08
-- pass turned Space Sandwich into a takedown aura relic and moved Earth's
-- proc-driven Barrier here, onto the offensive side of the tree.
--
-- Chance, size and duration all come from RelicData so the card stays the
-- one source of truth.
function ShieldService:TryGoldenGlovesBarrier(player: Player)
	if not RelicService then
		return
	end
	if (RelicService:GetSpecificRelicRegistry(player, RelicNames["Golden Steampunk Gloves"]) or 0) <= 0 then
		return
	end

	local entry = RelicData[RelicNames["Golden Steampunk Gloves"]]
	local data = entry and entry.data
	if not data then
		return
	end
	if math.random() > (data.barrierChance or 0) then
		return
	end

	local now = os.clock()
	if now - (self._barrierProcLastAt[player.UserId] or -math.huge) < BARRIER_PROC_COOLDOWN then
		return
	end
	self._barrierProcLastAt[player.UserId] = now

	local fraction = data.barrierPercent or 0
	if fraction > 0 then
		self:GrantShield(player, player, fraction, data.barrierSeconds or GOLDEN_GLOVES_DURATION)
	end
end

-- Robloxian Battle Shield: called by VFXService on every successful magic
-- cast by its owner.
function ShieldService:TryRobloxionShield(player: Player)
	if not RelicService then
		return
	end
	if (RelicService:GetSpecificRelicRegistry(player, RelicNames["Robloxian Battle Shield"]) or 0) <= 0 then
		return
	end
	local fraction = RelicService:GetRelicEffect(player, RelicNames["Robloxian Battle Shield"]) or 0
	if fraction > 0 then
		self:GrantShield(player, player, fraction, ROBLOXION_SHIELD_DURATION)
	end
end

-- Spartan Sword and Shield: the same magic cast also grants Stonebound.
-- Its OTHER half (the +25% damage rider on everyone Stonebound touches)
-- lives in AuraService's payload, not here.
--
-- No cooldown: this is gated by the mana the cast already cost, and
-- SetAura extends rather than stacks.
function ShieldService:TrySpartanStonebound(player: Player)
	if not RelicService or not player.Character then
		return
	end
	if (RelicService:GetSpecificRelicRegistry(player, RelicNames["Spartan Sword and Shield"]) or 0) <= 0 then
		return
	end
	local AuraService = Knit.GetService("AuraService")
	if AuraService then
		AuraService:SetAura(player, AuraNames.Stonebound, player.Character)
	end
end

-- Spends buckets against `damage`, returning what they couldn't absorb.
-- Called by DamageService:PlayerTakeDamage after every damage reduction
-- and before Humanoid application. Buckets drain soonest-expiring first;
-- a TNT applier whose buckets are absorbed dry detonates from here.
function ShieldService:AbsorbShieldDamage(player: Player, damage: number): number
	local state = self._pools[player.UserId]
	if not state or state.character ~= player.Character then
		return damage
	end

	local before = ownerSetOf(state)

	pruneExpired(state)
	if #state.buckets == 0 then
		self:_detonateEndedOwners(state, before)
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
	self:_detonateEndedOwners(state, before)

	if #state.buckets == 0 then
		self:_teardown(state)
	end

	return remaining
end

function ShieldService:GetShieldValue(player: Player): number
	local state = self._pools[player.UserId]
	if not state or state.character ~= player.Character then
		return 0
	end
	pruneExpired(state)
	return totalOf(state)
end

--[ Lifecycle ]--

function ShieldService:KnitStart()
	TextIndicatorService = Knit.GetService("TextIndicatorService")
	RelicService = Knit.GetService("RelicService")
	DamageService = Knit.GetService("DamageService")

	Players.PlayerRemoving:Connect(function(player: Player)
		self._pools[player.UserId] = nil
		self._barrierProcLastAt[player.UserId] = nil
	end)
end

return ShieldService
