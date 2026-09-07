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
local CommAdder = require(ReplicatedStorage.Submodules.Core.Source.ComponentExtensions.CommAdder)

--[ Component Root ]--

local Trap = Component.new({
	Tag = "Trap",

	Extensions = { CommAdder },
})

--[ Constants ]--

--[ Properties ]--

--[ Private Functions ]--

--[ Public Functions ]--

--[ Initializers ]--

function Trap:Construct()
	-- CommAdder leaves _comm nil when the instance was destroyed
	-- mid-wait (DungeonService backtracks destroying already-parented
	-- chunks — see CommAdder's awaitComm comment). Bail cleanly here
	-- instead of throwing on :GetSignal, then Start nil-guards the
	-- same way. The component will Stop shortly when the destroy
	-- replication finishes; no leaks.
	if not self._comm then
		return
	end

	self._onSpikesTriggered = self._comm:GetSignal("OnSpikesTriggered") :: table

	-- Cache spike parts and their original CFrames
	self._spikeOriginalCFrames = {}

	for _, part in pairs(self.Instance:GetDescendants()) do
		if part:IsA("BasePart") and part.Name == "Spike" then
			self._spikeOriginalCFrames[part] = part.CFrame
		end
	end
end

function Trap:Start()
	if not self._onSpikesTriggered then
		return
	end
	self._onSpikesTriggered:Connect(function(trapInstance: Model)
		if trapInstance ~= self.Instance then
			return warn("Spike trigger received for different trap instance:", trapInstance.Name)
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

function Trap:Stop() end

return Trap
