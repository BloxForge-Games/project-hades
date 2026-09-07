local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Jail = {}
Jail.__index = Jail

function Jail.new(targetCharacter: Model)
	local self = setmetatable({}, Jail)
	self.targetCharacter = targetCharacter

	return self
end

-- function Jail:PlayEffect()
-- 	local jail = ReplicatedStorage.GameAssets.VFX.Jail.Model:Clone()
-- 	jail:ScaleTo(self.targetCharacter:GetScale())
-- 	jail:PivotTo(
-- 		CFrame.new(
-- 			self.targetCharacter.HumanoidRootPart.Position
-- 				+ Vector3.new(0, self.targetCharacter.HumanoidRootPart.Size.Y + 8, 0)
-- 		) * CFrame.Angles(0, math.rad(math.random(-45, 45)), 0)
-- 	)
-- 	jail.PrimaryPart.Transparency = 1
-- 	jail.Parent = workspace.IgnoreInstances.MagicSpells

-- 	TweenService:Create(jail.PrimaryPart, TweenInfo.new(2, Enum.EasingStyle.Cubic), {
-- 		Transparency = 0,
-- 	}):Play()

-- 	local hrp = self.targetCharacter.HumanoidRootPart
-- 	local pos = hrp.Position

-- 	local look = hrp.CFrame.LookVector
-- 	local flatLook = Vector3.new(look.X, 0, look.Z).Unit

-- 	local yOnlyCFrame = CFrame.lookAt(pos, pos + flatLook)

-- 	local posTween = TweenService:Create(jail.PrimaryPart, TweenInfo.new(1, Enum.EasingStyle.Cubic), {
-- 		CFrame = yOnlyCFrame,
-- 	})

-- 	posTween:Play()

-- 	task.delay(0.5, function()
-- 		for _, p in jail.PrimaryPart.ActiveAttachment:GetChildren() do
-- 			if p:IsA("ParticleEmitter") then
-- 				p.Enabled = false
-- 				p:Emit(15)
-- 			end
-- 		end
-- 	end)

-- 	task.delay(2, function()
-- 		TweenService:Create(jail.PrimaryPart, TweenInfo.new(0.5, Enum.EasingStyle.Cubic), {
-- 			Transparency = 1,
-- 		}):Play()

-- 		Debris:AddItem(jail, 2)
-- 	end)
-- end

local function EaseOutCubic(t: number): number
	return 1 - math.pow(1 - t, 3)
end

function Jail:PlayEffect()
	local jail = ReplicatedStorage.GameAssets.VFX.Jail.Model:Clone()
	jail:ScaleTo(self.targetCharacter:GetScale())
	jail:PivotTo(CFrame.new(self.targetCharacter.HumanoidRootPart.Position))
	jail.PrimaryPart.Transparency = 1
	jail.Parent = workspace.IgnoreInstances.MagicSpells

	TweenService:Create(jail.PrimaryPart, TweenInfo.new(2, Enum.EasingStyle.Cubic), {
		Transparency = 0,
	}):Play()

	local startTime = workspace:GetServerTimeNow()
	local duration = 1.25

	task.delay(0.75, function()
		for _, p in jail.PrimaryPart.ActiveAttachment:GetChildren() do
			if p:IsA("ParticleEmitter") then
				p.Enabled = false
				p:Emit(15)
			end
		end
	end)

	local baseOffsetYaw = math.rad(math.random(-45, 45)) -- initial random offset
	local swivelYaw = baseOffsetYaw

	local swivelSpeed = math.rad(math.random(120, 220)) -- degrees/sec -> radians/sec

	local connection
	connection = RunService.RenderStepped:Connect(function(dt: number)
		if not self.targetCharacter or not self.targetCharacter:FindFirstChild("HumanoidRootPart") then
			connection:Disconnect()
			return
		end

		local hrp = self.targetCharacter.HumanoidRootPart
		local now = workspace:GetServerTimeNow()

		local rawAlpha = math.clamp((now - startTime) / duration, 0, 1)
		local eased = EaseOutCubic(rawAlpha)

		local currentPos = hrp.Position

		local startHeight = hrp.Size.Y + 8
		local dropHeight = startHeight * (1 - eased)
		local finalPos = currentPos + Vector3.new(0, dropHeight, 0)

		local spinScale = 1 - eased
		swivelYaw += swivelSpeed * dt * spinScale

		local _, y, _ = hrp.CFrame:ToOrientation()
		local rotation = CFrame.Angles(0, y + swivelYaw, 0)

		jail:PivotTo(CFrame.new(finalPos) * rotation)

		if rawAlpha >= 1 then
			connection:Disconnect()

			task.delay(1, function()
				TweenService:Create(jail.PrimaryPart, TweenInfo.new(0.5, Enum.EasingStyle.Cubic), {
					Transparency = 1,
				}):Play()

				Debris:AddItem(jail, 2)
			end)
		end
	end)
end

return Jail
