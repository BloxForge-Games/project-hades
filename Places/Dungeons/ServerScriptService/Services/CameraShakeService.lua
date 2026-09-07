--[[
	Module: CameraShakeService.lua
	Description:
	Server relay for the custom camera shake system. The actual shake math
	lives client-side in CameraShakeController; presets (Small / Medium /
	Large) are tuned in Shared/Data/CameraShakeData.lua.

	Server emitters have two entry points:

	  :Shake(player, preset)          -- direct: shake ONE player's camera
	  OnShakeRequested:Fire(player, preset)
	                                  -- signal form of the same (loose
	                                     coupling for services that don't
	                                     want a hard reference)
	  OnGetBoundsInShakeRadius:Fire(sourceModel, cframe, range)
	                                  -- AoE impact: every player whose
	                                     character is inside range ×
	                                     DETECTION_RANGE_SCALAR gets the
	                                     same Small shake. Binary on
	                                     purpose — in range or not, no
	                                     distance falloff — so any given
	                                     impact always feels identical.
	                                     Fired by onHitboxDamage (magic AoE)
	                                     and VFXService.
]]

--[ Roblox Services ]--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--[ Imports ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local Signal = require(ReplicatedStorage.Submodules.Core.Packages.Signal)
local CameraShakePresets = require(ReplicatedStorage.Submodules.Core.Shared.Enums.CameraShakePresets)

--[ Constants ]--

-- The shake radius extends beyond the damage hitbox — you FEEL a nearby
-- impact you didn't take.
local DETECTION_RANGE_SCALAR = 2.5

--[ Service ]--

local CameraShakeService = Knit.CreateService({
	Name = "CameraShakeService",
	Client = {
		OnShakeRequested = Knit.CreateSignal(), -- (preset: string)
	},
})

CameraShakeService.OnGetBoundsInShakeRadius = Signal.new() -- (sourceModel, cframe, range)
CameraShakeService.OnShakeRequested = Signal.new() -- (player, preset)

--[ Public API ]--

function CameraShakeService:Shake(player: Player, preset: string)
	self.Client.OnShakeRequested:Fire(player, preset)
end

--[ Lifecycle ]--

function CameraShakeService:KnitStart()
	local overlapParams = OverlapParams.new()
	overlapParams.FilterDescendantsInstances =
		{ workspace.IgnoreInstances, workspace.Terrain, workspace.PlayerBaseplates, workspace.CurrentCamera }
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude

	self.OnGetBoundsInShakeRadius:Connect(function(_sourceModel: Model, cframe: CFrame, range: number, preset: string?)
		-- Emitters may pass their own preset (magic explosions send
		-- Medium); anything that doesn't falls back to Small.
		local resolvedPreset = preset or CameraShakePresets.Small

		-- Dedup per player — a character overlaps the query with many
		-- parts, but each player gets exactly one shake per impact.
		local shaken: { [Player]: true } = {}
		for _, part in workspace:GetPartBoundsInRadius(cframe.Position, range * DETECTION_RANGE_SCALAR, overlapParams) do
			local model = part:FindFirstAncestorWhichIsA("Model")
			local player = model and Players:GetPlayerFromCharacter(model)
			if player and not shaken[player] then
				shaken[player] = true
				self:Shake(player, resolvedPreset)
			end
		end
	end)

	self.OnShakeRequested:Connect(function(player: Player, preset: string)
		self:Shake(player, preset)
	end)
end

function CameraShakeService:KnitInit() end

return CameraShakeService
