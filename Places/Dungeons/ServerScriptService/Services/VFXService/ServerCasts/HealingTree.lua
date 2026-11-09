--!strict
--[[
	Healing Tree, server side (2026-11-08): Runegrove's support Rare.

	The cast plants a tree `treeOffset` studs ahead of the cast CFrame, on
	the floor under that spot (the client's VFXController/HealingTree
	places its tree the same way from the same CFrame). For `treeSeconds`,
	every `tickSeconds` each player within `treeRadius` of it (the caster
	too) who is alive and not downed heals `healFraction` of their OWN max
	health through PlayerStatsService:ApplyHealing (so healing amps apply
	inside), with a green "+N" for everyone
	(DamageIndicatorService.ShowHealIndicator).

	A share of max health like the Orbs, never scaled by damage dealt or
	Arcane Rank (the GDD's healing rule); the long cooldown is the limit.
	The tree stands its full time even if the caster dies.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local ArcaneData = require(ReplicatedStorage.Submodules.Core.Shared.Data.ArcaneData)
local ArcaneNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ArcaneNames)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local GameClock = require(ReplicatedStorage.Submodules.Core.Shared.GameClock)
local getRoot = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Character.getRoot)
local PlayerStatsService = require(ServerScriptService.Submodules.Core.Source.Services.PlayerStatsService)
local DamageIndicatorService = require(ServerScriptService.Submodules.Core.Source.Services.DamageIndicatorService)

local SPELL = ArcaneNames["Healing Tree"]
-- How far below the cast point the floor is looked for.
local FLOOR_SEARCH = 12

-- The tree's base: `offset` studs ahead of `cframe` (flat), dropped to the
-- floor; the flat point itself when there is no floor under it.
local function treeBase(cframe: CFrame, offset: number): Vector3
	local look = Vector3.new(cframe.LookVector.X, 0, cframe.LookVector.Z)
	look = if look.Magnitude > 1e-3 then look.Unit else Vector3.zAxis
	local point = cframe.Position + look * offset
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ignore: { Instance } = {}
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(ignore, player.Character)
		end
	end
	local ignoreFolder = workspace:FindFirstChild("IgnoreInstances")
	if ignoreFolder then
		table.insert(ignore, ignoreFolder)
	end
	params.FilterDescendantsInstances = ignore
	local hit = workspace:Raycast(point + Vector3.new(0, 2, 0), Vector3.new(0, -FLOOR_SEARCH, 0), params)
	return if hit then hit.Position else point - Vector3.new(0, 3, 0)
end

-- One tick: heals every eligible player within `radius` of `base`
-- (measured flat, so a jump does not leave the circle).
local function pulse(base: Vector3, radius: number, fraction: number)
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and getRoot(character)
		if not character or not humanoid or not root then
			continue
		end
		if humanoid.Health <= 0 or humanoid.Health >= humanoid.MaxHealth then
			continue
		end
		if character:GetAttribute(Attributes.Downed) == true then
			continue
		end
		local flat = Vector3.new(root.Position.X - base.X, 0, root.Position.Z - base.Z)
		if flat.Magnitude > radius or math.abs(root.Position.Y - base.Y) > 12 then
			continue
		end
		local healed = PlayerStatsService:ApplyHealing(player, humanoid.MaxHealth * fraction)
		if healed >= 1 then
			DamageIndicatorService:ShowHealIndicator(character, math.round(healed))
		end
	end
end

return function(_vfxService: any, _player: Player, cframe: CFrame)
	local data = ArcaneData[SPELL]
	local seconds = data.treeSeconds or 5
	local radius = data.treeRadius or 14
	local tick = data.tickSeconds or 0.5
	local fraction = data.healFraction or 0.02
	local base = treeBase(cframe, data.treeOffset or 5)

	local ticks = math.floor(seconds / tick + 0.5)
	for index = 1, ticks do
		GameClock.Delay(tick * index, function()
			pulse(base, radius, fraction)
		end)
	end
end
