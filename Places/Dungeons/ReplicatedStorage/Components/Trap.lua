--!strict
--[[
     Author(s): ryanisawesome25
     Module: Trap.luau
     Description:
]]

--[ Exports & Types & Defaults ]--

--[ Roblox Services ]--

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

--[ Imports ]--

local Component = require(ReplicatedStorage.Submodules.Core.Packages.Component)
local waitForPrimaryPart = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Drop.waitForPrimaryPart)
local DungeonNetwork = require(ReplicatedStorage.Submodules.Core.Source.Network.Dungeon)
local InstanceRouter = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Network.InstanceRouter)

--[ Component Root ]--

local spikesRouter = InstanceRouter.Client(DungeonNetwork.TrapSpikesTriggered)

local Trap = Component.new({
	Tag = "Trap",
})

--[ Constants ]--

--[ Properties ]--

--[ Private Functions ]--

--[ Public Functions ]--

--[ Initializers ]--

function Trap:Construct()
	-- The parts can stream in after the tagged Model does; wait for them
	-- so the spike cache below is complete.
	waitForPrimaryPart(self.Instance)

	-- Cache spike parts and their original CFrames
	self._spikeOriginalCFrames = {}

	for _, part in pairs(self.Instance:GetDescendants()) do
		if part:IsA("BasePart") and part.Name == "Spike" then
			self._spikeOriginalCFrames[part] = part.CFrame
		end
	end
end

function Trap:Start()
	self._unbindSpikes = spikesRouter:Bind(self.Instance, function(trapInstance: Model)
		if trapInstance ~= self.Instance then
			warn("Spike trigger received for different trap instance:", trapInstance.Name)
			return
		end

		-- Play spike animation
		for spikePart, originalCFrame in pairs(self._spikeOriginalCFrames) do
			local extendedCFrame = originalCFrame * CFrame.new(0, 1.25, 0)

			spikePart.Transparency = 0

			local extendTween = TweenService:Create(
				spikePart,
				TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
				{ CFrame = extendedCFrame }
			)

			extendTween:Play()

			extendTween.Completed:Connect(function()
				task.delay(0.5, function()
					local retractTween = TweenService:Create(
						spikePart,
						TweenInfo.new(0.25, Enum.EasingStyle.Cubic, Enum.EasingDirection.In),
						{ CFrame = originalCFrame * CFrame.new(0, -1.25, 0) }
					)

					retractTween:Play()

					task.delay(3, function()
						local innerRetractTween = TweenService:Create(
							spikePart,
							TweenInfo.new(0.5, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out),
							{ CFrame = originalCFrame }
						)

						innerRetractTween:Play()
					end)
				end)
			end)
		end
	end)
end

function Trap:Stop()
	if self._unbindSpikes then
		self._unbindSpikes()
		self._unbindSpikes = nil
	end
end

return Trap
