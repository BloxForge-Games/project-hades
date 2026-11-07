--!strict
--[[
	Stone Body, server side (PROTOTYPE, 2026-11-07).

	For `stoneSeconds` the caster takes `damageReduction` less damage
	(DamageService:AddTimedReduction) and every mob within `tauntRadius`
	chases them (TauntService). When it ends the stone SHATTERS: every mob
	within half the hitbox takes the spell's `damage` through the spell-hit
	path (x Arcane Rank, crits and Arcane bonuses), the same however much
	the caster took.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ArcaneData = require(ReplicatedStorage.Submodules.Core.Shared.Data.ArcaneData)
local ArcaneNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ArcaneNames)
local Blitz = require(ReplicatedStorage.Submodules.Core.Shared.Blitz)
local GameClock = require(ReplicatedStorage.Submodules.Core.Shared.GameClock)
local getRoot = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Character.getRoot)

local SPELL = ArcaneNames["Stone Body"]

return function(vfxService: any, player: Player, _cframe: CFrame)
	local data = ArcaneData[SPELL]
	local seconds = data.stoneSeconds or 4
	local damageService = Blitz.OptionalService("DamageService")
	if not damageService then
		return
	end
	damageService:AddTimedReduction(player, SPELL, data.damageReduction or 0.4, seconds)
	local taunts = Blitz.OptionalService("TauntService")
	if taunts then
		taunts:Taunt(player, data.tauntRadius or 20, seconds)
	end

	GameClock.Delay(seconds, function()
		local character = player.Character
		local root = character and getRoot(character)
		local ignore = workspace:FindFirstChild("IgnoreInstances")
		local folder = ignore and ignore:FindFirstChild("Mobs")
		if not root or not folder then
			return
		end
		local radius = (data.hitboxSize and data.hitboxSize.X or 20) / 2
		local center = root.Position
		for _, model in folder:GetChildren() do
			if not model:IsA("Model") then
				continue
			end
			local humanoid = model:FindFirstChildOfClass("Humanoid")
			local mobRoot = model:FindFirstChild("HumanoidRootPart")
			if not humanoid or humanoid.Health <= 0 or not mobRoot or not mobRoot:IsA("BasePart") then
				continue
			end
			local flatGap = Vector3.new(mobRoot.Position.X - center.X, 0, mobRoot.Position.Z - center.Z).Magnitude
			if flatGap - mobRoot.Size.X / 2 <= radius then
				vfxService:_spellHit(model, CFrame.new(center), player, SPELL, data)
			end
		end
	end)
end
