--[[
	Module: VFXController/MobProjectiles/WizardFireball.lua
	Description:
	Client-side fireball projectile for Wizard mobs. Mirrors the
	FireBlast.lua pattern (task.wait loop + GetPartBoundsInRadius
	overlap check) but inverted: the LOCAL player (when targeted) is
	the one who reports the impact, instead of the casting player.

	Asset contract:
	  ReplicatedStorage.GameAssets.VFX.WizardFireball/
	    .Projectile     → Model with PrimaryPart, the flying body
	    .ExplosionFX    → Model with attachment + ParticleEmitters

	Flow:
	  1. Clone .Projectile, place at originCFrame.
	  2. Compute direction = (targetPosition - originCFrame.Position).Unit
	     (fire-and-forget — target's movement after cast is their dodge).
	  3. Move forward by speed*dt per tick (straight line, no drop).
	  4. GetPartBoundsInRadius at projectile position each tick:
	       - Local player hit OR projectile lifetime expired OR wall hit
	         → impact this frame.
	  5. On impact (LOCAL player only): call
	     ZombieService:OnMobProjectileHitRequested(castUuid, projectile.CFrame)
	  6. Spawn .ExplosionFX at impact, Debris-clean both.

	Why the LOCAL player gates the impact callback: ZombieService's
	registry is keyed by castUuid + targetPlayer. Only the targeted
	player's client should report — every client renders the projectile
	(replicated visual), but only the target triggers damage.
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)

local ZombieService
local TextIndicatorController

-- Tick cadence. Matches FireBlast's 0.015s (~67Hz) — fast enough that
-- a 60 stud/sec projectile only moves ~0.9 studs per tick, way under
-- a typical body part width so overlap checks don't tunnel.
local TICK_INTERVAL = 0.01

-- Distance from the muzzle the projectile must clear before WALL hits
-- (dungeon geometry) start counting. PLAYER hits + dodge detection
-- still fire inside this window — only the "anything in workspace
-- triggers an impact" branch is suppressed.
--
-- Why this exists: the casting wizard has `hipHeight = 0.35`, putting
-- the HRP (and therefore the muzzle, which is `HRP * CFrame.new(0,0,-2)`)
-- at roughly Y = 1.35 above the floor. The hit-detection sphere
-- (radius = attack.hitRadius, typically 2) extends down to Y ≈ -0.65,
-- so the dungeon floor at Y = 0 is INSIDE the overlap on every early
-- tick. Without clearance, a perfect dodge at point-blank range gets
-- past the player-hit branch via the IsDodging `continue`, then trips
-- the floor on the next iteration of the same for-loop and the
-- projectile dies. From farther away the player isn't in the overlap,
-- so the iteration order doesn't matter as much in practice.
--
-- 5 studs gives the projectile time to clear the wizard's body + the
-- floor immediately under them. After that distance the projectile is
-- airborne and wall hits resume normally — so a real wall in the
-- middle of the room still stops the fireball as expected.
local MUZZLE_CLEARANCE_DISTANCE = 5

Knit.OnStart():andThen(function()
	ZombieService = Knit.GetService("ZombieService")
	TextIndicatorController = Knit.GetController("TextIndicatorController")
end)

return function(
	_zombieModel: Model,
	originCFrame: CFrame,
	targetPosition: Vector3,
	castUuid: string,
	attackConfig: { speed: number, lifetime: number, hitRadius: number }
)
	local vfxFolder = ReplicatedStorage.GameAssets.VFX:FindFirstChild("WizardFireball")
	if not vfxFolder then
		warn("[WizardFireball] Missing ReplicatedStorage.GameAssets.VFX.WizardFireball")
		return
	end
	local projectileTemplate = vfxFolder:FindFirstChild("Projectile")
	if not projectileTemplate then
		warn("[WizardFireball] Missing .Projectile child under GameAssets.VFX.WizardFireball")
		return
	end

	-- Clone + place the projectile at the muzzle, facing the target.
	-- Flatten the aim vector to the muzzle's Y plane: the wizard only
	-- rotates horizontally to face the player, and the fireball flies
	-- straight out of their chest in a level line. Without this flatten
	-- the projectile angles downward (or up) toward the player's
	-- HumanoidRootPart, which sits lower than the muzzle and bobs
	-- vertically when the player dodges / rolls / jumps.
	local projectile = projectileTemplate:Clone()
	local flatTarget = Vector3.new(targetPosition.X, originCFrame.Position.Y, targetPosition.Z)
	local direction = (flatTarget - originCFrame.Position)
	if direction.Magnitude < 0.05 then
		-- Target is directly above/below the mob (degenerate after
		-- Y-flatten) — skip rather than divide-by-zero into a
		-- NaN-poisoned CFrame.
		return
	end
	direction = direction.Unit
	projectile:PivotTo(CFrame.lookAt(originCFrame.Position, originCFrame.Position + direction))

	-- Anchor every BasePart so Roblox engine gravity can't pull the
	-- projectile down between our PivotTo calls. The trajectory is
	-- 100% driven by this script's per-tick step — no physics body
	-- forces, no bullet drop.
	for _, descendant in projectile:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
		end
	end

	projectile.Parent = workspace.IgnoreInstances.MagicSpells

	-- Optional muzzle flash at the cast origin. Cheap and adds polish.
	local castFXTemplate = vfxFolder:FindFirstChild("CastFX")
	if castFXTemplate then
		local castFX = castFXTemplate:Clone()
		castFX:PivotTo(originCFrame)
		castFX.Parent = workspace.IgnoreInstances.MagicSpells
		for _, descendant in castFX:GetDescendants() do
			if descendant:IsA("ParticleEmitter") then
				descendant:Emit(25)
			end
		end
		Debris:AddItem(castFX, 1)
	end

	-- Per-tick overlap params. Include-filtered to EXACTLY two roots:
	-- player characters, and the dungeon room geometry. Everything else in
	-- the workspace — props, breakables, gate barricades, coin/gear drops,
	-- relics, other projectiles, mob bodies — is invisible to the overlap
	-- and therefore cannot stop the fireball.
	--
	-- This used to include `workspace.IgnoreInstances.Map`, i.e. the WHOLE
	-- map folder rather than just its walls. Anything non-wall parented
	-- under Map landed in the overlap and fell through to the wall-hit
	-- branch below, which is why fireballs kept dying against "random
	-- items" with nothing visibly in the way.
	-- PLAYER hits only. A sphere is right here: a body is a volume and we
	-- want a near-miss inside hitRadius to count.
	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Include
	overlapParams.FilterDescendantsInstances = { workspace.Players }

	-- WALL hits are a RAYCAST along the segment travelled this tick, not a
	-- sphere. That distinction is the whole fix for "the orb vanishes when I
	-- narrowly avoid it": with a sphere, any dungeon geometry within
	-- hitRadius counted as a wall — including the FLOOR the projectile is
	-- flying level over, a step, or a doorframe beside the player. The
	-- projectile died mid-air with no damage and no visible cause.
	--
	-- A segment cast can only report geometry the projectile actually flew
	-- INTO, so flying over a floor or past a wall is free. It also makes
	-- MUZZLE_CLEARANCE unnecessary for walls — the old floor-under-the-wizard
	-- false positive can't happen through a level cast.
	local dungeonRooms = workspace.IgnoreInstances.Map.DungeonRooms
	local wallParams = RaycastParams.new()
	wallParams.FilterType = Enum.RaycastFilterType.Include
	wallParams.FilterDescendantsInstances = { dungeonRooms }

	local localCharacter = Players.LocalPlayer.Character

	-- Trajectory loop. Fire-and-forget along the initial direction
	-- vector. Per-tick: move forward by speed*tickInterval, apply
	-- gravity if > 0, check overlap.
	local startTime = os.clock()
	local lifetime = attackConfig.lifetime
	local hitRadius = attackConfig.hitRadius
	local speed = attackConfig.speed

	-- Anchor for the muzzle-clearance check (see MUZZLE_CLEARANCE_DISTANCE
	-- comment for rationale). Captured once because the muzzle doesn't
	-- move after spawn — only the projectile does.
	local muzzlePosition = originCFrame.Position

	local hit = false
	local hitCFrame: CFrame? = nil
	local hitLocalPlayer = false

	-- Server-confirmed end-of-cast. Every client simulates this projectile
	-- independently, but ONLY the targeted player's client can see the hit —
	-- everyone else treats non-local characters as passable, so their copy
	-- would otherwise fly straight through the player who got hit and keep
	-- going. This subscription is how the other clients learn to despawn.
	local despawned = false
	local despawnConn = ZombieService.OnMobProjectileDespawn:Connect(function(despawnedUuid: string)
		if despawnedUuid == castUuid then
			despawned = true
		end
	end)

	-- One-shot guard for the perfect-dodge server signal. The overlap
	-- check runs at ~67Hz; without this we'd spam
	-- OnMobProjectilePerfectDodgedRequested every tick the player
	-- stays inside the radius during their i-frame window. Server
	-- handler is idempotent (Jetpack's own cooldown gates the proc)
	-- but no need to fire ~30 redundant packets per dodged cast.
	local perfectDodgeFired = false

	while not hit do
		if despawned then
			-- Another client's impact resolved this cast. Stop flying and
			-- fall through to the shared cleanup below so the trail fades
			-- naturally instead of the model just vanishing.
			break
		end
		if os.clock() - startTime >= lifetime then
			-- Lifetime expired without contact. Despawn cleanly; no
			-- impact callback fires (server's registry expire handles
			-- the orphaned cast).
			break
		end
		if not projectile.Parent then
			-- Something destroyed the projectile externally (cleanup
			-- sweep, etc.). Bail — releasing the despawn subscription,
			-- since this is the one exit that skips the cleanup below.
			despawnConn:Disconnect()
			return
		end

		-- Move forward by speed * tickInterval along the initial
		-- direction. Straight-line, no drop — this is a magic
		-- fireball, not a thrown rock.
		local previousPosition = projectile:GetPivot().Position
		local moveStep = direction * speed * TICK_INTERVAL
		projectile:PivotTo(projectile:GetPivot() + moveStep)

		-- Player overlap at the projectile's new position.
		local projectilePosition = projectile:GetPivot().Position
		local parts = workspace:GetPartBoundsInRadius(projectilePosition, hitRadius, overlapParams)

		-- WALL check: cast across the segment actually travelled this tick,
		-- so geometry is only a hit if the projectile flew INTO it. Walls
		-- are still suppressed inside MUZZLE_CLEARANCE_DISTANCE — the
		-- wizard's low hipHeight can put the segment's first steps clipping
		-- the floor right under it.
		local insideMuzzleClearance = (projectilePosition - muzzlePosition).Magnitude < MUZZLE_CLEARANCE_DISTANCE
		if not insideMuzzleClearance then
			local wallResult = workspace:Raycast(previousPosition, moveStep, wallParams)
			if wallResult then
				hit = true
				hitCFrame = CFrame.new(wallResult.Position)
				break
			end
		end

		for _, part in parts do
			-- Local-player-hit gate. IsDescendantOf walks the FULL
			-- ancestor chain, not just the nearest Model — critical
			-- because the player's equipped weapon and armor pieces
			-- are their own Models parented inside the character.
			-- The previous `FindFirstAncestorWhichIsA("Model") ==
			-- localCharacter` check matched on the NEAREST Model
			-- ancestor, so a part inside the player's AK-47 (or
			-- Chestplate / Helmet / etc.) resolved to the weapon
			-- model — not the character. It then fell through to
			-- the wall-hit branch below and killed the projectile.
			-- That's why the fireball "didn't come out at all"
			-- specifically on the cast-frame perfect dodge: the
			-- player hadn't moved away yet, so their equipped
			-- weapon's parts were inside the spawn-radius overlap
			-- and tripped the false wall hit on iteration 1.
			if part:IsDescendantOf(localCharacter) then
				-- A registered perfect dodge LATCHES for the rest of this
				-- projectile's flight, rather than being re-read from
				-- IsDodging every tick.
				--
				-- The overlap lasts many ticks (1-stud radius, ~0.15 studs of
				-- travel per tick), so a tick-by-tick read races the i-frame
				-- window: dodge on the frame of contact, get told "Perfect
				-- Dodge!", then have the i-frames lapse while still inside the
				-- radius and eat a full hit on the very next tick. From the
				-- player's side that reads as the dodge being ignored and the
				-- orb vanishing anyway.
				--
				-- Latching means one clean rule: if you were dodging the
				-- moment it reached you, it missed you. Walking back into a
				-- still-flying projectile no longer re-arms it against you —
				-- an accepted trade for the race being gone.
				if perfectDodgeFired or localCharacter:GetAttribute(Attributes.IsDodging) then
					-- Tell the server to fire the perfect-dodge side
					-- effects (Experimental Jetpack proc, server-side
					-- TextIndicator broadcast) ONCE per cast. The
					-- server validates castUuid + target + IsDodging
					-- server-side before doing anything — see
					-- ZombieService.Client:OnMobProjectilePerfectDodgedRequested.
					-- Server does NOT clear the cast registry, so the
					-- projectile keeps flying past us and a later overlap
					-- (after our i-frames end) can still apply damage if
					-- we walk back into the path.
					if not perfectDodgeFired then
						perfectDodgeFired = true
						ZombieService:OnMobProjectilePerfectDodgedRequested(castUuid)

						TextIndicatorController:ShowIndicator(
							localCharacter.HumanoidRootPart,
							"Perfect Dodge!",
							Color3.fromRGB(255, 255, 255),
							false
						)
					end
					continue
				end

				hit = true
				hitCFrame = projectile:GetPivot()
				hitLocalPlayer = true

				break
			end

			-- Anything else in this overlap is ANOTHER player's character —
			-- the include list is workspace.Players only, so nothing else
			-- can appear here. Other players are passable: only the
			-- registered target reports damage, and stopping on a teammate
			-- would kill projectiles aimed at someone standing behind them.
			--
			-- Walls are no longer tested in this loop at all; they're the
			-- segment raycast above.
		end

		task.wait(TICK_INTERVAL)
	end

	-- Spawn impact VFX at the final position. Same for hit-player and
	-- hit-wall — the visual is identical (the registry on the server
	-- knows whether to apply damage).
	-- local impactPosition = projectile:GetPivot().Position
	-- local explosionTemplate = vfxFolder:FindFirstChild("ExplosionFX")
	-- if explosionTemplate then
	-- 	local explosion = explosionTemplate:Clone()
	-- 	explosion:PivotTo(CFrame.new(impactPosition))
	-- 	explosion.Parent = workspace.IgnoreInstances.MagicSpells
	-- 	for _, descendant in explosion:GetDescendants() do
	-- 		if descendant:IsA("ParticleEmitter") then
	-- 			descendant:Emit(25)
	-- 		end
	-- 	end
	-- 	Debris:AddItem(explosion, 2)
	-- end

	despawnConn:Disconnect()

	-- Disable the projectile's particle emitters so trailing trails
	-- fade naturally instead of snapping, then debris the model.
	for _, descendant in projectile:GetDescendants() do
		if descendant:IsA("ParticleEmitter") then
			descendant.Enabled = false
		end
	end
	Debris:AddItem(projectile, 1)

	-- Impact callback — ONLY the targeted local player fires this.
	-- Everyone else just sees the projectile fly + impact visual.
	if hitLocalPlayer and hitCFrame and ZombieService then
		ZombieService:OnMobProjectileHitRequested(castUuid, hitCFrame)
	end
end
