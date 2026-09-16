--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

-- DamageService requires this module at load (directly or through its parent),
-- so this side reaches it lazily: required on first use, once both exist.
local damageServiceLazy: any = nil
local function getDamageService(): any
	if damageServiceLazy == nil then
		damageServiceLazy = (require :: any)(ServerScriptService.Services.DamageService)
	end
	return damageServiceLazy
end
local RelicNetwork = require(ServerScriptService.Submodules.Core.Source.Network.Relic)
local MagicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.MagicNames)
local MagicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.MagicData)

local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)

type EnemyEntry = { model: Model, distance: number }

local Fireworks = {}
Fireworks.__index = Fireworks

export type Fireworks = typeof(setmetatable(
	{} :: {
		_player: Player,
		_fireworksCount: number,
		_relicService: any,
		_vfxService: any,
		_ignoreListService: any,
		_enemyList: { EnemyEntry },
		_uniqueTargets: { Model },
	},
	Fireworks
))

function Fireworks.new(
	player: Player,
	fireworksCount: number,
	relicService: any,
	vfxService: any,
	ignoreListService: any
): Fireworks
	local self = setmetatable({
		_player = player,
		_fireworksCount = fireworksCount,
		_relicService = relicService,
		_vfxService = vfxService,
		_ignoreListService = ignoreListService,
		_enemyList = {} :: { EnemyEntry },
		_uniqueTargets = {} :: { Model },
	}, Fireworks)

	return self
end

function Fireworks.InvokeFireworks(self: Fireworks)
	task.spawn(function()
		local hrp = (self._player.Character :: Model):FindFirstChild("HumanoidRootPart") :: BasePart?

		if not hrp then
			return
		end

		self._enemyList = {}
		self._uniqueTargets = {}

		for _, enemy in ipairs(workspace.IgnoreInstances.Zombies:GetChildren()) do
			if enemy:IsA("Model") then
				local enemyHRP = enemy:FindFirstChild("HumanoidRootPart") :: BasePart?
				local humanoid = enemy:FindFirstChildOfClass("Humanoid")

				if enemyHRP and humanoid and humanoid.Health > 0 then
					local distance = (enemyHRP.Position - hrp.Position).Magnitude

					table.insert(self._enemyList, {
						model = enemy,
						distance = distance,
					})
				end
			end
		end

		table.sort(self._enemyList, function(a, b)
			return a.distance < b.distance
		end)

		local fireworksToFire = self._fireworksCount

		local targetCount = math.min(#self._enemyList, fireworksToFire)

		for i = 1, targetCount do
			table.insert(self._uniqueTargets, self._enemyList[i].model)
		end

		while #self._uniqueTargets < fireworksToFire and #self._uniqueTargets > 0 do
			table.insert(self._uniqueTargets, self._uniqueTargets[1])
		end

		for _, targetEnemy in ipairs(self._uniqueTargets) do
			RelicNetwork.FireworksEffect.FireAll({
				Caster = self._player,
				Target = targetEnemy,
				StartTime = workspace:GetServerTimeNow(),
				Duration = 1,
			})

			task.delay(1, function()
				self._vfxService:CreateHitbox(
					MagicNames["Fireworks Explosion"],
					self._player,
					targetEnemy:GetPivot(),
					TagList.Zombie,
					self._ignoreListService:GetWeaponIgnoreList(),
					function(model: Model)
						-- UNTYPED relic lane (isRelicSourced): scales with
						-- unqualified Damage bonuses; Weapon/Magic-typed
						-- relics and crits never apply. No applier hubs
						-- (those live in onHitboxDamage; this spell's status
						-- is None and cameraShake false, so nothing is lost).
						local humanoid = model:FindFirstChild("Humanoid")
						if not humanoid or not getDamageService() then
							return
						end
						local config = MagicData[MagicNames["Fireworks Explosion"]]
						local damageRoll = if config.runtimeDamageCallback
							then config.runtimeDamageCallback(self._player)
							else config.damage
						getDamageService():TakeDamage(
							self._player,
							humanoid,
							damageRoll,
							false, -- isMagic
							false, -- isStatusConditionDamage: amplified lane
							false, -- isMelee
							true, -- isRelicSourced: the untyped lane
							true -- showHitVFX
						)
					end,
					MagicData[MagicNames["Fireworks Explosion"]].hitboxSize.X
				)
			end)

			task.wait(0.05)
		end
	end)
end

return Fireworks
