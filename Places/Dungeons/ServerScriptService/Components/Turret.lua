-- SERVER Turret.luau
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Component = require(ReplicatedStorage.Submodules.Core.Packages.Component)
local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local WeaponData = require(ReplicatedStorage.Submodules.Core.Shared.Data.WeaponData)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local CommAdder = require(ReplicatedStorage.Submodules.Core.Source.ComponentExtensions.CommAdder)

local ProjectileWeaponService

Knit.OnStart():andThen(function()
	ProjectileWeaponService = Knit.GetService("ProjectileWeaponService")
end)

local Turret = Component.new({
	Tag = "Turret",
	Extensions = { CommAdder },
})

local DEFAULT_RANGE = 30
local DEFAULT_FIRE_RATE = 1
local DEFAULT_WEAPON_NAME = "Turret"
local TARGET_REFRESH_RATE = 0.1

function Turret:Construct()
	self._running = false
	self._target = nil
	self._range = self.Instance:GetAttribute("Range") or DEFAULT_RANGE
	self._fireRate = self.Instance:GetAttribute("FireRate") or DEFAULT_FIRE_RATE
	self._weaponName = self.Instance:GetAttribute("WeaponName") or DEFAULT_WEAPON_NAME
	self._player = Players:GetPlayerByUserId(self.Instance:GetAttribute(Attributes.OwnerId) or -1)
	self._lastShotTime = 0

	self._onTurretCFrameChanged = self._comm:CreateSignal("OnTurretCFrameChanged")

	self._targetTrack = {
		model = nil,
		lastPosition = nil,
		velocity = Vector3.zero,
		lastSampleTime = 0,
	}
end

function Turret:_UpdateTargetTrack(target: Model)
	local hrp = target and target:FindFirstChild("HumanoidRootPart")
	if not hrp then
		self._targetTrack.model = nil
		self._targetTrack.lastPosition = nil
		self._targetTrack.velocity = Vector3.zero
		self._targetTrack.lastSampleTime = 0
		return
	end

	local now = os.clock()
	local position = hrp.Position

	if self._targetTrack.model ~= target then
		self._targetTrack.model = target
		self._targetTrack.lastPosition = position
		self._targetTrack.velocity = hrp.AssemblyLinearVelocity
		self._targetTrack.lastSampleTime = now
		return
	end

	local lastPosition = self._targetTrack.lastPosition
	local lastSampleTime = self._targetTrack.lastSampleTime
	local dt = now - lastSampleTime

	if lastPosition and dt > 0 then
		local sampledVelocity = (position - lastPosition) / dt
		self._targetTrack.velocity = self._targetTrack.velocity:Lerp(sampledVelocity, 0.35)
	end

	self._targetTrack.lastPosition = position
	self._targetTrack.lastSampleTime = now
end

function Turret:_GetVelocityOffset(target: Model): Vector3
	local hrp = target:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return Vector3.zero
	end

	local weaponData = WeaponData[self._weaponName]
	local muzzleCFrame = self:_GetMuzzleCFrame()
	local projectileVelocity = weaponData and weaponData.velocity or 250

	local distance = (hrp.Position - muzzleCFrame.Position).Magnitude
	local travelTime = distance / math.max(projectileVelocity, 1)

	local velocity = self._targetTrack.velocity
	local maxLeadSpeed = 35
	if velocity.Magnitude > maxLeadSpeed then
		velocity = velocity.Unit * maxLeadSpeed
	end

	return velocity * travelTime
end

function Turret:_GetMuzzleCFrame(): CFrame
	local attachment = self.Instance.Model.Barrel1:FindFirstChild("StartAttachment", true)
	if attachment and attachment:IsA("Attachment") then
		return attachment.WorldCFrame
	end

	local primaryPart = self.Instance.PrimaryPart
	return primaryPart and primaryPart.CFrame or CFrame.identity
end

function Turret:_IsValidTarget(model: Model?): boolean
	if not model or not model.Parent then
		return false
	end

	if not CollectionService:HasTag(model, TagList.Zombie) and not CollectionService:HasTag(model, "Zombie") then
		return false
	end

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local hrp = model:FindFirstChild("HumanoidRootPart")

	if not humanoid or humanoid.Health <= 0 or not hrp then
		return false
	end

	local primaryPart = self.Instance.PrimaryPart

	if not primaryPart then
		return false
	end

	return (hrp.Position - primaryPart.Position).Magnitude <= self._range
end

function Turret:_GetNearestZombie(): Model?
	local primaryPart = self.Instance.PrimaryPart
	if not primaryPart then
		return nil
	end

	local closestTarget = nil
	local closestDistance = self._range

	for _, zombie in workspace.IgnoreInstances.Zombies:GetChildren() do
		if zombie:IsA("Model") then
			local humanoid = zombie:FindFirstChildOfClass("Humanoid")
			local hrp = zombie:FindFirstChild("HumanoidRootPart")

			if humanoid and humanoid.Health > 0 and hrp then
				local distance = (hrp.Position - primaryPart.Position).Magnitude
				if distance < closestDistance then
					closestDistance = distance
					closestTarget = zombie
				end
			end
		end
	end

	return closestTarget
end

function Turret:_GetPredictedTargetPosition(target: Model): Vector3
	local hrp = target:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return self.Instance.PrimaryPart.Position + self.Instance.PrimaryPart.CFrame.LookVector * 50
	end

	-- _UpdateTargetTrack is NOT called here anymore — caller is responsible
	-- to avoid double-updating per loop iteration
	local velocityOffset = self:_GetVelocityOffset(target)
	return hrp.Position + velocityOffset
end

function Turret:_AimAt(position: Vector3)
	local primaryPart = self.Instance.PrimaryPart
	if not primaryPart then
		return
	end

	local direction = position - primaryPart.Position
	local flatDirection = Vector3.new(direction.X, 0, direction.Z)

	if flatDirection.Magnitude < 0.001 then
		return
	end

	flatDirection = flatDirection.Unit
	local yaw = math.atan2(-flatDirection.Z, flatDirection.X)
	local targetCFrame = CFrame.new(primaryPart.Position) * CFrame.Angles(0, yaw + math.rad(-90), 0)

	self._onTurretCFrameChanged:FireAll(self.Instance, targetCFrame)
	self.Instance:PivotTo(targetCFrame)
end

function Turret:_CanFire(): boolean
	return os.clock() - self._lastShotTime >= self._fireRate
end

function Turret:_FireAt(target: Model)
	if not ProjectileWeaponService then
		return
	end

	local weaponData = WeaponData[self._weaponName]
	if not weaponData then
		warn("[Turret] Missing WeaponData for:", self._weaponName)
		return
	end

	-- Update lastShotTime FIRST so _CanFire never spins
	-- even if something below fails or returns early
	self._lastShotTime = os.clock()

	-- Re-validate at fire time — zombie may have died since loop check
	if not self:_IsValidTarget(target) then
		return
	end

	local startCFrame = self:_GetMuzzleCFrame()
	local endPosition = self:_GetPredictedTargetPosition(target)
	endPosition = Vector3.new(endPosition.X, startCFrame.Position.Y, endPosition.Z)

	ProjectileWeaponService:FireTurretProjectile(self._player, self.Instance, self._weaponName, {
		StartCFrame = startCFrame,
		EndCFrame = endPosition,
	})
end

function Turret:Start()
	if self._running then
		return
	end

	self._running = true

	task.wait(1)

	task.spawn(function()
		while self._running and self.Instance and self.Instance.Parent and task.wait(TARGET_REFRESH_RATE) do
			local primaryPart = self.Instance.PrimaryPart

			if not primaryPart then
				continue
			end

			self._target = self:_GetNearestZombie()

			if not self:_IsValidTarget(self._target) then
				continue
			end

			-- Single update per iteration, used by both _AimAt and _FireAt
			self:_UpdateTargetTrack(self._target)

			local hrp = self._target:FindFirstChild("HumanoidRootPart")
			local humanoid = self._target:FindFirstChildOfClass("Humanoid")

			-- Extra liveness check after track update
			if not humanoid or humanoid.Health <= 0 or not hrp then
				self._target = nil
				continue
			end

			local predictedPosition = self:_GetPredictedTargetPosition(self._target)

			if (hrp.Position - primaryPart.Position).Magnitude > 3 then
				self:_AimAt(predictedPosition)
			end

			if self:_CanFire() then
				self:_FireAt(self._target)
			end
		end
	end)
end

function Turret:Stop()
	self._running = false
	self._target = nil
end

return Turret
