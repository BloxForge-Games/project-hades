local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local getRelicModelTemplate = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Relic.getRelicModelTemplate)

local Fireworks = {}
Fireworks.__index = Fireworks

function Fireworks.new(
	character: Model,
	targetCharacter: Model,
	duration: number,
	startTime: number,
	quadraticBezierController: any
)
	local self = setmetatable({}, Fireworks)
	self._character = character
	self._targetCharacter = targetCharacter
	self._quadraticBezierController = quadraticBezierController
	self._duration = duration
	self._startTime = startTime

	return self
end

function Fireworks:PlayEffect()
	local fireworks = getRelicModelTemplate(RelicNames["Summer Fireworks"]):Clone()
	local character = self._character
	local targetCharacter = self._targetCharacter

	local originPosition = character.HumanoidRootPart.Position
	local targetPosition = targetCharacter.HumanoidRootPart.Position
	local intermediatePosition = (originPosition + targetPosition) / 2 + Vector3.new(0, 20, 0)

	local fireworksCast = ReplicatedStorage.GameAssets.Sounds.FireworksCast:Clone()
	fireworksCast.Parent = fireworks.PrimaryPart
	fireworksCast:Play()

	fireworks.PrimaryPart.Trail2.Enabled = true

	fireworks:PivotTo(character.HumanoidRootPart.CFrame)

	fireworks.PrimaryPart.RelicParticleAttachment:Destroy()

	fireworks.Parent = workspace.IgnoreInstances.MagicSpells

	local connection

	local lastPos = originPosition

	connection = RunService.RenderStepped:Connect(function()
		local now = workspace:GetServerTimeNow()
		local alpha = math.clamp((now - self._startTime) / self._duration, 0, 1)

		local pos = self._quadraticBezierController:GenerateBezierCurve(
			alpha,
			originPosition,
			intermediatePosition,
			targetCharacter.HumanoidRootPart.Position
		)

		-- Calculate trajectory direction
		local direction = (pos - lastPos)

		if direction.Magnitude > 0.001 then
			direction = direction.Unit
		else
			direction = Vector3.new(0, 0, -1) -- fallback
		end

		-- Make projectile face its movement direction
		local lookCFrame = CFrame.lookAt(pos, pos + direction) * CFrame.Angles(0, 0, math.rad(180))

		fireworks:PivotTo(lookCFrame)

		lastPos = pos

		if alpha >= 1 then
			connection:Disconnect()

			fireworks.PrimaryPart.Trail2.Enabled = false

			local explosionVFX = ReplicatedStorage.GameAssets.VFX["Fireworks Explosion"].Explosion:Clone()
			explosionVFX:PivotTo(CFrame.new(targetCharacter.HumanoidRootPart.Position))
			explosionVFX.Parent = workspace.IgnoreInstances.MagicSpells

			explosionVFX.Explosion:Play()

			for _, p in explosionVFX:GetDescendants() do
				if p:IsA("ParticleEmitter") then
					p:Emit(20)
				end
			end

			Debris:AddItem(explosionVFX, 2)

			TweenService:Create(fireworks.Handle, TweenInfo.new(0.25, Enum.EasingStyle.Cubic), { Transparency = 1 })
				:Play()

			Debris:AddItem(fireworks, 1)
		end
	end)
end

return Fireworks
