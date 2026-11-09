--!strict
--[[
	TauntService (2026-11-07, Sand Armor): which player a taunted mob must
	chase. Taunt marks every living mob within a radius of the player for
	a time; the mob brains (MobSimService._findTarget, MobBase.FindTarget)
	ask GetTaunter before anything else, so a taunt outranks the nearest
	player and Shadow Clones alike. A taunt lapses early when its player
	dies or leaves.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local GameClock = require(ReplicatedStorage.Submodules.Core.Shared.GameClock)
local getRoot = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Character.getRoot)

type Taunt = { player: Player, untilAt: number }

local TauntService = {
	Name = "TauntService",
	-- Weak-keyed: a dead mob's model is not pinned by its taunt.
	_taunts = (setmetatable({}, { __mode = "k" }) :: any) :: { [Model]: Taunt },
}

-- Taunts every living mob within `radius` studs of `player` for `seconds`.
-- Returns how many mobs it took.
function TauntService.Taunt(self: typeof(TauntService), player: Player, radius: number, seconds: number): number
	local root = player.Character and getRoot(player.Character)
	local ignore = workspace:FindFirstChild("IgnoreInstances")
	local folder = ignore and ignore:FindFirstChild("Mobs")
	if not root or not folder then
		return 0
	end
	local untilAt = GameClock.Now() + seconds
	local count = 0
	for _, model in folder:GetChildren() do
		if not model:IsA("Model") then
			continue
		end
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		local mobRoot = model:FindFirstChild("HumanoidRootPart")
		if not humanoid or humanoid.Health <= 0 or not mobRoot or not mobRoot:IsA("BasePart") then
			continue
		end
		if (mobRoot.Position - root.Position).Magnitude <= radius then
			self._taunts[model] = { player = player, untilAt = untilAt }
			count += 1
		end
	end
	return count
end

-- The character (and root) `model` must chase, or nil when it is not
-- taunted, the taunt is over, or its player is down.
function TauntService.GetTaunter(self: typeof(TauntService), model: Model): (Model?, BasePart?)
	local taunt = self._taunts[model]
	if not taunt then
		return nil, nil
	end
	if GameClock.Now() >= taunt.untilAt or not taunt.player.Parent then
		self._taunts[model] = nil
		return nil, nil
	end
	local character = taunt.player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and getRoot(character)
	if
		not character
		or not humanoid
		or humanoid.Health <= 0
		or not root
		or character:GetAttribute(Attributes.Death) == true
	then
		self._taunts[model] = nil
		return nil, nil
	end
	return character, root
end

function TauntService.Start(self: typeof(TauntService))
	Players.PlayerRemoving:Connect(function(player: Player)
		for model, taunt in self._taunts do
			if taunt.player == player then
				self._taunts[model] = nil
			end
		end
	end)
end

return TauntService
