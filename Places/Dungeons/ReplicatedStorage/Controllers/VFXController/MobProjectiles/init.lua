--[[
	Module: VFXController/MobProjectiles/init.lua
	Description:
	Auto-registry dispatcher for client-side mob ranged-attack visuals.
	Mirrors the per-spell module pattern under VFXController/ (FireBlast,
	HollowPurple, etc.) — each child ModuleScript here is a per-projectile
	visual module keyed by projectileName.

	Module contract:
	  function(zombieModel: Model, originCFrame: CFrame,
	           targetPosition: Vector3, castUuid: string, attackConfig: table)
	    The module owns the FULL client-side projectile lifecycle:
	      * Clones GameAssets.VFX.<projectileName>.Projectile
	      * Positions at originCFrame
	      * Animates trajectory toward targetPosition (fire-and-forget;
	        local target movement after cast time is the player's
	        dodge counterplay)
	      * Overlap-checks against the local player + walls each tick
	      * On impact (LOCAL player only): calls
	        ZombieService:OnMobProjectileHitRequested(castUuid, hit.CFrame)
	      * Spawns GameAssets.VFX.<projectileName>.ExplosionFX at impact,
	        destroys the projectile.

	attackConfig shape (passed through from ZombieService):
	  { speed: number, lifetime: number, hitRadius: number }

	Adding a new ranged-mob projectile = new ModuleScript in this folder
	with a matching name + a new GameAssets.VFX.<name> Folder/Model.
	No dispatcher edits needed — child modules are auto-required at
	KnitInit time.
]]

local MobProjectiles = {}

-- registry[projectileName] = function(zombieModel, originCFrame, targetPosition, castUuid, attackConfig)
local registry: { [string]: any } = {}

-- Auto-register every child ModuleScript by its Name. Called once
-- on require — matches the VFXController.KnitInit pattern.
for _, moduleScript in script:GetChildren() do
	if moduleScript:IsA("ModuleScript") then
		registry[moduleScript.Name] = require(moduleScript)
	end
end

-- Dispatch entry. Looks up the registered module by projectileName
-- and forwards the payload. Warns + no-ops if the name isn't
-- registered (e.g., ZombieData references a projectile whose module
-- hasn't been authored yet).
function MobProjectiles.Run(
	projectileName: string,
	zombieModel: Model,
	originCFrame: CFrame,
	targetPosition: Vector3,
	castUuid: string,
	attackConfig: { speed: number, lifetime: number, hitRadius: number }
)
	local module = registry[projectileName]
	if not module then
		warn(("[MobProjectiles] No module for projectile '%s'"):format(tostring(projectileName)))
		return
	end
	module(zombieModel, originCFrame, targetPosition, castUuid, attackConfig)
end

return MobProjectiles
