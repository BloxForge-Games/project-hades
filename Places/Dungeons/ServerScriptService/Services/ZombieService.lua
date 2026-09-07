--[[
	Module: ZombieService.lua
	Description:
	Server-side mob attack execution + client replication. Called by
	MobBase's attack pipeline (once per swing); owns:

	  * Hitbox Model cloning + placement (from GameAssets.Hitboxes by
	    name, CFramed via the per-attack `hitboxCFrame(zombie)` function)
	  * Overlap-based hit detection during `hitFrameDuration`
	  * Per-attack damage + ragdoll application
	  * Lunge tween replication (per-attack `lungeDistance` opt-in)
	  * Visual flash replication for clients

	The hitbox lifecycle is factored into ONE primitive — SpawnHitbox(mob,
	config) — which BOTH the declarative generic-melee adapter
	(ExecuteMobAttack) and imperative uniqueAttacks `run` callbacks call. So a
	bespoke boss move reuses the same telegraph + damage + interrupt handling
	as a basic zombie swing instead of hand-rolling its own overlap loop.

	==========================================================
	Per-attack config shape (passed in from MobBase)
	==========================================================

	The `attack` table corresponds to one entry from
	ZombieData[name].genericAttacks. Fields used here:
	  animation        : Animation (loaded + played by MobBase, not used here)
	  hitboxName       : string — looks up GameAssets.Hitboxes.<name>
	  attackRange      : number (MobBase-side; not used here)
	  damage           : number
	  canRagdoll       : boolean
	  lungeDistance    : number — 0 means no lunge tween fires
	  windUpDuration   : number (MobBase-side; not used here)
	  hitFrameDuration : number — overlap-check window
	  recoveryDuration : number (MobBase-side; not used here)
	  hitboxCFrame     : function(zombieModel) -> CFrame
	  onTelegraph      : function(zombieModel, cframe)? — optional; fired at
	                     windup start for signature VFX / camera shake

	==========================================================
	Client replication signals
	==========================================================

	  OnReplicateZombieAttack(model, startCFrame, goalCFrame, timestamp)
	    Fires only if attack.lungeDistance > 0. Client tweens the mob's
	    HRP from startCFrame → goalCFrame for the cosmetic "step into
	    swing" effect.

	  OnReplicateMobAttack(model, hitboxName, hitboxCFrame, windUpDuration, hitFrameDuration)
	    Fires at WIND-UP START (immediately, before any damage). Payload
	    tells the client which Hitbox Model to clone (from
	    ReplicatedStorage.GameAssets.Hitboxes), where to place it (world
	    CFrame, computed server-side), and the windup + hit-frame
	    durations so the client visual can ramp up over windup and fade
	    over hit-frame — peaking at the moment of impact. Multi-part
	    Hitbox Models flash each Part in parallel.
]]

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)

local ZombieService = Knit.CreateService({
	Name = "ZombieService",

	Client = {
		OnReplicateZombieAttack = Knit.CreateSignal(),
		OnReplicateMobAttack = Knit.CreateSignal(),

		-- Ranged-projectile cast replication. Fires at WIND-UP END
		-- (immediately before the projectile becomes visible). Each
		-- client animates the projectile locally; the TARGETED player's
		-- client reports the impact CFrame back via
		-- OnMobProjectileHitRequested (below).
		--
		-- Payload:
		--   mobModel        : Model
		--   projectileName  : string         — looks up GameAssets.VFX.<name>
		--   originCFrame    : CFrame         — muzzle position
		--   targetPosition  : Vector3        — fire-and-forget aim point
		--   castUuid        : string         — registry key for impact callback
		--   attackConfig    : table          — { speed, lifetime, hitRadius }
		OnReplicateMobRangedAttack = Knit.CreateSignal(),

		-- (castUuid: string) — broadcast when a cast resolves, so every
		-- client despawns its own copy of that projectile. Only the targeted
		-- player's client can detect the impact, so this is the only way the
		-- other clients learn the fireball is spent.
		OnMobProjectileDespawn = Knit.CreateSignal(),
	},
})

local HttpService = game:GetService("HttpService")

local TextIndicatorService
local DamageService
local RelicService

-- Folder under workspace.IgnoreInstances where transient hitbox Models
-- live during their hit-frame window. Picked to match other transient
-- VFX placement (existing MagicSpells folder).
local HITBOX_PARENT = workspace.IgnoreInstances.MagicSpells

-- Pending ranged-cast registry. Server records each fired cast here;
-- the client-side handler (targeted player's client) calls back via
-- OnMobProjectileHitRequested with the impact CFrame, which the server
-- then validates against this registry before applying damage.
--
-- Shape:
--   [castUuid: string] = {
--       mob            : Model,
--       target         : Player,    -- only this player can report impact
--       damage         : number,
--       canRagdoll     : boolean,
--       hitRadius      : number,
--       expireToken    : {},        -- table identity for stale-fire guard
--   }
--
-- Entries auto-expire via task.delay(projectileLifetime + grace) so
-- dropped/spoofed impact reports don't accumulate.
local PROJECTILE_REGISTRY_EXPIRE_GRACE = 0.5

-- Overlap params reused across calls. Excludes IgnoreInstances entirely
-- so the hit check only sees player characters + dungeon geometry (the
-- player's own Character is technically a descendant of workspace,
-- which is what we want).
local overlapParams = OverlapParams.new()
overlapParams.FilterType = Enum.RaycastFilterType.Exclude
overlapParams.FilterDescendantsInstances = { workspace.IgnoreInstances }

--[ Private helpers ]--

--[ Pending ranged-cast registry ]--

-- See PROJECTILE_REGISTRY_EXPIRE_GRACE comment above for shape.
ZombieService._pendingRangedCasts = {}

--[ Hitbox helpers ]--

-- Looks up the Hitbox Model template by name. Warns + returns nil if
-- missing — the user is responsible for authoring these under
-- ReplicatedStorage.GameAssets.Hitboxes.<name>. Each template must be
-- a Model with PrimaryPart set.
function ZombieService:_resolveHitboxTemplate(hitboxName: string): Model?
	local hitboxesFolder = ReplicatedStorage.GameAssets:FindFirstChild("Hitboxes")
	if not hitboxesFolder then
		warn("[ZombieService] Missing ReplicatedStorage.GameAssets.Hitboxes folder")
		return nil
	end
	local template = hitboxesFolder:FindFirstChild(hitboxName)
	if not template or not template:IsA("Model") then
		warn(("[ZombieService] Hitbox template '%s' not found or not a Model"):format(hitboxName))
		return nil
	end
	return template
end

-- Runs overlap-check hit detection over the hitbox Model's parts for
-- the attack's hitFrameDuration. Each BasePart in the hitbox Model
-- contributes its own overlap zone (multi-zone attacks: cones, AoE
-- rings, fans, etc. — anything the designer authored as separate
-- Parts).
--
-- One damage application per (player, attack) — players who walk
-- through multiple zones within one swing aren't multi-hit.
function ZombieService:_runHitDetection(zombieModel: Model, attack, hitboxModel: Model)
	local hitRegistry: { [Player]: boolean } = {}
	local startTime = os.clock()
	-- Cache the zombie's humanoid so the per-tick alive-check below
	-- doesn't pay a FindFirstChildOfClass lookup every Heartbeat.
	local zombieHumanoid = zombieModel:FindFirstChildOfClass("Humanoid")
	local hitParts = {}
	for _, descendant in hitboxModel:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(hitParts, descendant)
		end
	end

	while os.clock() - startTime < attack.hitFrameDuration do
		if not zombieModel.Parent then
			return
		end
		if not hitboxModel.Parent then
			return
		end
		-- Bail if the zombie died mid-hitframe. Without this the loop
		-- keeps applying damage for the full hitFrameDuration even
		-- after a kill — MobBase's _relocateToDeadFolder reparents to
		-- DeadZombies but doesn't destroy the model, so the
		-- zombieModel.Parent check above still passes.
		if zombieHumanoid and zombieHumanoid.Health <= 0 then
			return
		end
		-- Jail interrupt: Portable Justice fired mid-hitframe. The
		-- mob's swing animation continues to play out (cheaper than
		-- yanking it mid-frame, and gives the player visual feedback
		-- that the jail landed RIGHT AS the mob was about to connect)
		-- but no further damage applies. Without this gate, a melee
		-- mob jailed during its hitFrameDuration still landed the hit
		-- because the loop only checked death + hitbox existence.
		if zombieModel:GetAttribute(Attributes.Jailed) == true then
			return
		end
		-- Interrupt: a phase change / death cancelled this attack mid-hitframe
		-- (MobBase:_interruptAttack stamps the flag). Stop applying damage.
		if zombieModel:GetAttribute("AttackInterrupted") == true then
			return
		end

		for _, hitboxPart in hitParts do
			local touched = workspace:GetPartBoundsInBox(hitboxPart.CFrame, hitboxPart.Size, overlapParams)
			for _, part in touched do
				local model = part:FindFirstAncestorWhichIsA("Model")
				if not model then
					continue
				end
				local humanoid = model:FindFirstChild("Humanoid")
				if not humanoid or humanoid.Health <= 0 then
					continue
				end
				local player = Players:GetPlayerFromCharacter(model)
				if not player or hitRegistry[player] then
					continue
				end
				hitRegistry[player] = true

				-- Dodge intercept: the player perfectly dodged this swing.
				-- Same UX as the prior implementation — small invisible part
				-- at the hit point to anchor the indicator.
				if model:GetAttribute(Attributes.IsDodging) then
					local perfectDodgedPart = Instance.new("Part")
					perfectDodgedPart.Size = Vector3.new(1, 1, 1)
					perfectDodgedPart.Transparency = 1
					perfectDodgedPart.CFrame = part.CFrame
					perfectDodgedPart.Anchored = true
					perfectDodgedPart.CanCollide = false
					perfectDodgedPart.Parent = workspace.IgnoreInstances.MagicSpells
					Debris:AddItem(perfectDodgedPart, 2)

					-- All perfect-dodge-triggered relics fan out from here.
					-- Single fan-out means future perfect-dodge relics plug in
					-- without editing this attack-loop branch — they just add
					-- a branch inside RelicService:OnPlayerPerfectDodged.
					-- Today: Experimental Jetpack only.
					RelicService:OnPlayerPerfectDodged(player)
					TextIndicatorService:ShowIndicator(player, perfectDodgedPart, "Perfect Dodge!")
				else
					DamageService:PlayerTakeDamage(player, zombieModel, attack.damage, attack.canRagdoll)
				end
			end
		end

		RunService.Heartbeat:Wait()
	end
end

-- Computes the lunge goal CFrame for an attack with lungeDistance > 0.
-- Raycasts forward — if a wall is in the way, the goal is clipped to
-- just before the wall so the mob doesn't tween THROUGH geometry.
function ZombieService:_computeLungeGoalCFrame(zombieModel: Model, lungeDistance: number): CFrame
	local root = zombieModel.HumanoidRootPart
	local goalCFrame = root.CFrame + root.CFrame.LookVector * lungeDistance

	local rayOrigin = root.Position - Vector3.new(0, root.Size.Y, 0)
	local rayDirection = root.CFrame.LookVector * lungeDistance

	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Include
	raycastParams.FilterDescendantsInstances = {
		workspace.IgnoreInstances.Map,
		workspace.IgnoreInstances.Boundaries,
	}

	local raycastResult = workspace:Raycast(rayOrigin, rayDirection, raycastParams)
	if raycastResult then
		goalCFrame = CFrame.new(raycastResult.Position + Vector3.new(0, root.Size.Y, 0))
	end

	return goalCFrame
end

--[ Public API ]--

-- Shared mob-melee hitbox primitive. The ONE code path that turns an authored
-- GameAssets.Hitboxes.<name> Model into a telegraphed, damaging, self-cleaning
-- hitbox. BOTH the declarative generic-melee adapter (ExecuteMobAttack, below)
-- and imperative uniqueAttacks `run` callbacks call this — so a bespoke boss
-- move reuses the same telegraph + damage + interrupt/dodge handling as a basic
-- zombie swing instead of hand-rolling its own overlap loop.
--
-- Owns the full hit-frame timeline (blocks for windUpDuration + hitFrameDuration):
--   1. Telegraph: client visual flash + optional onTelegraph hook (windup start).
--   2. Block windUpDuration (telegraph showing, no damage).
--   3. Interrupt gate (death / phase change stamped "AttackInterrupted").
--   4. Lunge (opt-in via lungeDistance) — synced to hit-frame start.
--   5. Clone the server-side hitbox Model + hit detection for hitFrameDuration.
--   6. Destroy the hitbox.
--
-- config fields:
--   hitboxName       : string                — GameAssets.Hitboxes.<name> (visual + damage volume)
--   cframe           : CFrame | (mob) -> CFrame  — world placement, resolved ONCE so the client
--                                                  visual + server hitbox land identically
--   damage           : number
--   canRagdoll       : boolean?
--   windUpDuration   : number?               — default 0 (no telegraph delay)
--   hitFrameDuration : number?               — default 0 (no damage window)
--   lungeDistance    : number?               — default 0 (no lunge)
--   onTelegraph      : (mob, cframe) -> ()?   — optional; fired server-side at windup start for
--                                               signature VFX / camera shake (owns its replication)
function ZombieService:SpawnHitbox(zombieModel: Model, config)
	if not zombieModel or not zombieModel.Parent then
		return
	end
	if not zombieModel:FindFirstChild("HumanoidRootPart") then
		return
	end

	-- Resolve placement ONCE (function or literal CFrame). Reused for the client
	-- visual AND the server hitbox so the two render at exactly the same place.
	local cframe = config.cframe
	if type(cframe) == "function" then
		cframe = cframe(zombieModel)
	end
	if typeof(cframe) ~= "CFrame" then
		warn("[ZombieService] SpawnHitbox: config.cframe missing or not a CFrame")
		return
	end

	local windUpDuration = config.windUpDuration or 0
	local hitFrameDuration = config.hitFrameDuration or 0

	-- ============================================================
	-- Phase 1: telegraph (visual flash + optional VFX hook) at windup start
	-- ============================================================
	-- Client uses windUpDuration to ramp the hitbox UP (transparent → opaque)
	-- during windup so the player sees the danger zone intensifying, then fades
	-- it DOWN over hitFrameDuration so the visual peaks at impact and clears as
	-- the damage window closes. Firing at windup START (not hit-frame start) is
	-- what gives the player time to react.
	self.Client.OnReplicateMobAttack:FireAll(zombieModel, config.hitboxName, cframe, windUpDuration, hitFrameDuration)
	if config.onTelegraph then
		-- Spawned so a yielding / erroring hook can't stall or break the
		-- hit-frame timeline. The hook owns its own client replication.
		task.spawn(config.onTelegraph, zombieModel, cframe)
	end

	-- ============================================================
	-- Phase 2: windup wait (no damage yet)
	-- ============================================================
	if windUpDuration > 0 then
		task.wait(windUpDuration)
	end
	if not zombieModel.Parent then
		return
	end

	-- Interrupt gate: a boss phase change OR the mob's death (both call
	-- MobBase:_interruptAttack, which stamps "AttackInterrupted") cancels the
	-- attack HERE — before the lunge + hitbox fire. That stops the mob lunging
	-- (moving) or spawning a damage hitbox into a cutscene. The visual telegraph
	-- already fired at windup-start; it self-fades client-side.
	if zombieModel:GetAttribute("AttackInterrupted") == true then
		return
	end

	-- ============================================================
	-- Phase 3: lunge (opt-in) — fires at hit-frame start
	-- ============================================================
	if config.lungeDistance and config.lungeDistance > 0 then
		local root = zombieModel.HumanoidRootPart
		local goalCFrame = self:_computeLungeGoalCFrame(zombieModel, config.lungeDistance)
		self.Client.OnReplicateZombieAttack:FireAll(zombieModel, root.CFrame, goalCFrame, workspace:GetServerTimeNow())

		-- Server-side: tween the mob to the goal mid-hitframe. Without this the
		-- server-authoritative position lags and the next AI tick's distance
		-- check sees stale data.
		task.delay(hitFrameDuration * 0.5, function()
			if zombieModel.Parent and not zombieModel:GetAttribute("AttackInterrupted") then
				zombieModel:PivotTo(goalCFrame)
			end
		end)
	end

	-- ============================================================
	-- Phase 4: clone server-side hitbox + run hit detection
	-- ============================================================
	local hitboxTemplate = config.hitboxName and self:_resolveHitboxTemplate(config.hitboxName)
	if not hitboxTemplate then
		return -- no / invalid hitboxName → telegraph-only (already fired)
	end

	local hitboxModel = hitboxTemplate:Clone()
	hitboxModel:PivotTo(cframe)
	hitboxModel.Parent = HITBOX_PARENT

	-- _runHitDetection only reads hitFrameDuration / damage / canRagdoll.
	self:_runHitDetection(zombieModel, {
		hitFrameDuration = hitFrameDuration,
		damage = config.damage,
		canRagdoll = config.canRagdoll,
	}, hitboxModel)

	if hitboxModel.Parent then
		hitboxModel:Destroy()
	end
end

-- Called by MobBase at WIND-UP START for kind="melee" generic attacks. Thin
-- adapter mapping one ZombieData genericAttacks entry onto SpawnHitbox (the
-- shared primitive that owns the visual + damage timeline). Blocks for
-- (windUpDuration + hitFrameDuration); MobBase owns recoveryDuration after.
function ZombieService:ExecuteMobAttack(zombieModel: Model, attack)
	self:SpawnHitbox(zombieModel, {
		hitboxName = attack.hitboxName,
		cframe = attack.hitboxCFrame,
		damage = attack.damage,
		canRagdoll = attack.canRagdoll,
		windUpDuration = attack.windUpDuration,
		hitFrameDuration = attack.hitFrameDuration,
		lungeDistance = attack.lungeDistance,
		onTelegraph = attack.onTelegraph,
	})
end

--[ Ranged attack pipeline ]--

-- Called by MobBase at WIND-UP END for kind="ranged" attacks. Owns:
--   1. Generates a castUuid + registers the pending cast (target,
--      damage, canRagdoll, hitRadius) so the impact callback below
--      can validate against the registry.
--   2. Fires OnReplicateMobRangedAttack to all clients with the
--      projectile name, origin CFrame, target position (fire-and-
--      forget aim), and projectile physics config (speed, lifetime,
--      hitRadius).
--   3. Schedules a task.delay(projectileLifetime + grace) safety to
--      clean up the registry entry if no impact callback ever fires.
--
-- Returns the castUuid (mostly for testing / diagnostics).
function ZombieService:FireMobRangedAttack(zombieModel: Model, target: Player, attack): string?
	if not zombieModel.Parent or not target or not target.Parent then
		return nil
	end
	local targetCharacter = target.Character
	local targetHRP = targetCharacter and targetCharacter:FindFirstChild("HumanoidRootPart")
	if not targetHRP then
		return nil
	end

	local castUuid = HttpService:GenerateGUID(false)
	local expireToken = {}

	self._pendingRangedCasts[castUuid] = {
		mob = zombieModel,
		target = target,
		damage = attack.damage,
		canRagdoll = attack.canRagdoll,
		hitRadius = attack.hitRadius or 4,
		explosionRadius = attack.explosionRadius or 10,
		expireToken = expireToken,
	}

	-- Stale-cast cleanup: if the impact callback never arrives (player
	-- left, projectile despawned via lifetime, packet lost), clear the
	-- registry entry so the table doesn't accumulate.
	local lifetime = attack.projectileLifetime or 2
	task.delay(lifetime + PROJECTILE_REGISTRY_EXPIRE_GRACE, function()
		local entry = self._pendingRangedCasts[castUuid]
		if entry and entry.expireToken == expireToken then
			self._pendingRangedCasts[castUuid] = nil
		end
	end)

	-- Resolve muzzle origin (mob-relative CFrame from per-attack function).
	local originCFrame = attack.muzzleOffset and attack.muzzleOffset(zombieModel) or zombieModel.HumanoidRootPart.CFrame

	-- Aim point: straight ahead along the MOB's facing at cast time —
	-- NOT the target's position. The mob rotated to face the target
	-- before its windup (MobBase:_runRangedSwing), so the projectile
	-- flies where the mob is pointing; moving out of its facing line
	-- during the windup is the dodge counterplay. Flattened to the
	-- muzzle's height so shots fly level.
	local facing = zombieModel.HumanoidRootPart.CFrame.LookVector
	local flatFacing = Vector3.new(facing.X, 0, facing.Z)
	flatFacing = if flatFacing.Magnitude > 0.001 then flatFacing.Unit else Vector3.zAxis
	local travelDistance = (attack.projectileSpeed or 40) * lifetime
	local targetPosition = originCFrame.Position + flatFacing * travelDistance

	self.Client.OnReplicateMobRangedAttack:FireAll(
		zombieModel,
		attack.projectileName,
		originCFrame,
		targetPosition,
		castUuid,
		{
			speed = attack.projectileSpeed,
			lifetime = lifetime,
			hitRadius = attack.hitRadius or 4,
			explosionRadius = attack.explosionRadius or 10,
		}
	)

	return castUuid
end

-- Client → server impact report. Mirrors VFXService:OnVFXHitboxRequested
-- in shape: the client that detected the impact tells the server WHERE
-- the projectile landed, and the server runs the physics query +
-- applies damage. Server-authoritative for damage, smooth for visuals.
--
-- Validation:
--   1. castUuid must be in _pendingRangedCasts (anti-replay).
--   2. player must match the registered target (anti-spoof — only the
--      targeted player can report their own hit).
--   3. mob must still exist (defensive — registered cast outlived its mob).
--
-- After damage applies, the registry entry is cleared so a second
-- callback for the same uuid is a no-op.
-- Client → server perfect-dodge notification. Fired by the projectile
-- client module when the local player is in their dodge i-frames at the
-- moment the projectile would have overlapped them. Unlike
-- OnMobProjectileHitRequested below, this does NOT clear the registry
-- entry — the client lets the projectile keep flying through the
-- dodged player, so a subsequent real impact on the same cast (player
-- re-enters the path after i-frames end, or a different overlap point)
-- still triggers damage.
--
-- Side effects fired here mirror the melee perfect-dodge path
-- (ZombieService._runHitDetection lines ~213-215):
--   * Experimental Jetpack relic procs via RelicService.
--   * Server-side TextIndicator broadcast (so other players see the
--     "Perfect Dodge!" floater, not just the local client).
--
-- Anti-spoof: same as OnMobProjectileHitRequested — cast must exist,
-- caller must be the registered target, AND the character must
-- actually have the IsDodging attribute server-side. The IsDodging
-- check closes the obvious exploit of spamming this signal to proc
-- Jetpack without a dodge.
function ZombieService.Client:OnMobProjectilePerfectDodgedRequested(player: Player, castUuid: string)
	local registry = self.Server._pendingRangedCasts
	local entry = registry[castUuid]
	if not entry then
		return -- expired or never existed
	end
	if player ~= entry.target then
		return
	end

	local character = player.Character
	if not character then
		return
	end
	if character:GetAttribute(Attributes.IsDodging) ~= true then
		-- Client claimed a dodge but server doesn't see one. Drop the
		-- signal — Jetpack:Invoke would also no-op via its own guards,
		-- but we don't want to pay the cost of a relic-registry lookup
		-- on a spammed packet.
		return
	end

	-- Same fan-out as the melee dodge branch — see RelicService:OnPlayerPerfectDodged.
	RelicService:OnPlayerPerfectDodged(player)
	TextIndicatorService:ShowIndicator(player, character.Head, "Perfect Dodge!")
	-- Intentionally do NOT clear registry[castUuid] — the projectile
	-- keeps flying client-side; the registry needs to stay alive so
	-- a real impact later in the projectile's flight can apply damage.
	-- Natural cleanup happens via the lifetime task.delay in
	-- FireMobRangedAttack.
end

function ZombieService.Client:OnMobProjectileHitRequested(player: Player, castUuid: string, hitCFrame: CFrame)
	local registry = self.Server._pendingRangedCasts
	local entry = registry[castUuid]
	if not entry then
		return -- expired or never existed
	end

	-- Anti-spoof: only the registered target can report this cast's hit.
	if player ~= entry.target then
		return
	end

	-- Defensive: mob may have been killed/despawned before the impact
	-- callback arrived. Damage application would still work via
	-- DamageService but it's cleaner to skip rather than show a dead
	-- zombie as the damage source.
	if not entry.mob or not entry.mob.Parent then
		registry[castUuid] = nil
		return
	end

	-- Single-shot overlap check at the reported impact position. We
	-- TRUST the client's reported CFrame here (same trust model as
	-- VFXService:OnVFXHitboxRequested — clients can technically
	-- manipulate the hit position, but with damage capped at the
	-- attack's `damage` field there's no exploit value beyond "make
	-- the projectile hit at a slightly different angle").
	local localOverlapParams = OverlapParams.new()
	localOverlapParams.FilterType = Enum.RaycastFilterType.Exclude
	localOverlapParams.FilterDescendantsInstances = { workspace.IgnoreInstances }

	if entry.explosionRadius and entry.explosionRadius > 0 then
		local parts = workspace:GetPartBoundsInRadius(hitCFrame.Position, entry.explosionRadius, localOverlapParams)
		for _, part in parts do
			local character = part:FindFirstAncestorWhichIsA("Model")
			if not character then
				continue
			end
			local humanoid = character:FindFirstChild("Humanoid")
			if not humanoid or humanoid.Health <= 0 then
				continue
			end
			local hitPlayer = Players:GetPlayerFromCharacter(character)
			if hitPlayer ~= entry.target then
				-- Only damage the registered target. Splash to other
				-- players would require a different attack design.
				continue
			end
			-- Dodge intercept matches the melee path's UX. Triggering
			-- the Experimental Jetpack relic here mirrors the melee
			-- path's `GetRelicActiveModule(..., "Jetpack")` call —
			-- without it the relic only procs on dodged melee swings
			-- and silently no-ops on dodged ranged casts, which QA
			-- caught: "Perfect Dodging the Wizard Fireball does not
			-- trigger Experimental Jetpack."
			if character:GetAttribute(Attributes.IsDodging) then
				RelicService:GetRelicActiveModule(hitPlayer, "Jetpack")
				TextIndicatorService:ShowIndicator(hitPlayer, character.Head, "Perfect Dodge!")
			else
				DamageService:PlayerTakeDamage(hitPlayer, entry.mob, entry.damage, entry.canRagdoll)
			end
			break -- only the registered target gets hit, no need to keep scanning
		end
	else
		local character = player.Character

		if character:GetAttribute(Attributes.IsDodging) then
			RelicService:GetRelicActiveModule(player, "Jetpack")
			TextIndicatorService:ShowIndicator(player, character.Head, "Perfect Dodge!")
		else
			DamageService:PlayerTakeDamage(player, entry.mob, entry.damage, entry.canRagdoll)
		end
	end

	-- Tell EVERY client this cast is over so their local copy despawns.
	--
	-- Each client simulates the projectile independently off the original
	-- FireAll — but only the targeted player's client can detect the hit
	-- (the others' loops treat every non-local character as passable, by
	-- design, so a teammate's body doesn't block a shot). Without this
	-- broadcast, the target saw the fireball vanish on impact while everyone
	-- else watched it sail straight through them and keep going until its
	-- 60s lifetime or a wall.
	--
	-- Fired AFTER damage resolution so the despawn can't race the hit.
	--
	-- `self.Server.Client`, NOT `self.Client`: this is a Client-table method,
	-- so `self` IS the Client table and has no `.Client` field. Server-side
	-- methods elsewhere in this file (FireMobRangedAttack et al.) can write
	-- `self.Client.X` because there `self` is the service — same expression,
	-- different meaning depending on which table the method hangs off. Note
	-- the `self.Server._pendingRangedCasts` read at the top of this very
	-- function for the matching idiom.
	self.Server.Client.OnMobProjectileDespawn:FireAll(castUuid)

	-- One impact per cast — clear the registry.
	registry[castUuid] = nil
end

--[ Lifecycle ]--

function ZombieService:KnitStart()
	RelicService = Knit.GetService("RelicService")
	TextIndicatorService = Knit.GetService("TextIndicatorService")
	DamageService = Knit.GetService("DamageService")
end

return ZombieService
