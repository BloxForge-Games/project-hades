local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local MagicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.MagicNames)
local MagicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.MagicData)

local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)

local DamageService
Knit.OnStart():andThen(function()
	DamageService = Knit.GetService("DamageService")
end)

local Fireworks = {}
Fireworks.__index = Fireworks

function Fireworks.new(
	player: Player,
	fireworksCount: number,
	relicService: any,
	vfxService: any,
	ignoreListService: any
)
	local self = setmetatable({}, Fireworks)

	self._player = player
	self._fireworksCount = fireworksCount
	self._relicService = relicService
	self._vfxService = vfxService
	self._ignoreListService = ignoreListService
	self._enemyList = {}
	self._uniqueTargets = {}

	return self
end

function Fireworks:InvokeFireworks()
	task.spawn(function()
		local hrp = self._player.Character:FindFirstChild("HumanoidRootPart")

		if not hrp then
			return
		end

		self._enemyList = {}
		self._uniqueTargets = {}

		for _, enemy in ipairs(workspace.IgnoreInstances.Zombies:GetChildren()) do
			if enemy:IsA("Model") then
				local enemyHRP = enemy:FindFirstChild("HumanoidRootPart")
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
			self._relicService.Client.OnFireworksEffectActivated:FireAll(
				self._player,
				targetEnemy,
				workspace:GetServerTimeNow(),
				1
			)

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
						if not humanoid or not DamageService then
							return
						end
						local config = MagicData[MagicNames["Fireworks Explosion"]]
						local damageRoll = if config.runtimeDamageCallback
							then config.runtimeDamageCallback(self._player)
							else config.damage
						DamageService:TakeDamage(
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
