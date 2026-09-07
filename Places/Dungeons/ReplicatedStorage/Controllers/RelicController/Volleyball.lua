local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local getRelicModelTemplate = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Relic.getRelicModelTemplate)

local Volleyball = {}
Volleyball.__index = Volleyball

function Volleyball.new(
	character: Model,
	targetCharacter: Model,
	duration: number,
	startTime: number,
	quadraticBezierController: any
)
	local self = setmetatable({}, Volleyball)
	self._character = character
	self._targetCharacter = targetCharacter
	self._quadraticBezierController = quadraticBezierController
	self._duration = duration
	self._startTime = startTime

	return self
end

function Volleyball:PlayEffect()
	local volleyball = getRelicModelTemplate(RelicNames.Volleyball):Clone()
	local character = self._character
	local targetCharacter = self._targetCharacter

	local originPosition = character.HumanoidRootPart.Position
	local targetPosition = targetCharacter.HumanoidRootPart.Position
	local intermediatePosition = (originPosition + targetPosition) / 2 + Vector3.new(0, 10, 0)

	volleyball:PivotTo(character.HumanoidRootPart.CFrame)

	volleyball.PrimaryPart.RelicParticleAttachment:Destroy()

	for _, p in volleyball.PrimaryPart.ActiveAttachment:GetChildren() do
		if p:IsA("ParticleEmitter") then
			p.Enabled = false
			p:Emit(5)
		end
	end

	volleyball.Parent = workspace.IgnoreInstances.MagicSpells

	local connection

	connection = RunService.RenderStepped:Connect(function()
		local now = workspace:GetServerTimeNow()
		local alpha = math.clamp((now - self._startTime) / self._duration, 0, 1)

		local pos = self._quadraticBezierController:GenerateBezierCurve(
			alpha,
			originPosition,
			intermediatePosition,
			targetCharacter.HumanoidRootPart.Position
		)

		volleyball:PivotTo(CFrame.new(pos))

		if alpha >= 1 then
			connection:Disconnect()

			local volleyballSound = ReplicatedStorage.GameAssets.Sounds.Volleyball:Clone()
			volleyballSound.Parent = volleyball.PrimaryPart
			volleyballSound.TimePosition = 0.2
			volleyballSound:Play()

			for _, p in volleyball.PrimaryPart.ActiveAttachment:GetChildren() do
				if p:IsA("ParticleEmitter") then
					p:Emit(5)
				end
			end

			TweenService:Create(volleyball.Handle, TweenInfo.new(0.25, Enum.EasingStyle.Cubic), { Transparency = 1 })
				:Play()

			Debris:AddItem(volleyball, 1)
		end
	end)
end

return Volleyball
