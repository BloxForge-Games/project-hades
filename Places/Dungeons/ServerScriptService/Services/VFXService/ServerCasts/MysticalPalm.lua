--!strict
--[[
	Mystical Palm, server side (2026-11-10; Healing Tree before): Runegrove's
	support Rare.

	The caster channels for `channelSeconds` (rooted for the whole cast
	`duration` by the client, VFXController/MysticalPalm). Every
	`tickSeconds` each player within `healRadius` of the CASTER (the caster
	too) who is alive and not downed heals `healFraction` of their OWN max
	health through PlayerStatsService:ApplyHealing (so healing amps apply
	inside), with a green "+N" for everyone
	(DamageIndicatorService.ShowHealIndicator).

	A share of max health like the Orbs, never scaled by damage dealt or
	Arcane Rank (the GDD's healing rule); the long cooldown is the limit.
	The channel stops at once if the caster dies, is downed or leaves.
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

local SPELL = ArcaneNames["Mystical Palm"]

-- The caster can still channel: in the game, alive and not downed.
local function channeling(caster: Player, character: Model): boolean
	if not caster.Parent or caster.Character ~= character then
		return false
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0 and character:GetAttribute(Attributes.Downed) ~= true
end

-- One tick: heals every eligible player within `radius` of `center`
-- (measured flat, so a jump does not leave the circle).
local function pulse(center: Vector3, radius: number, fraction: number)
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
		local flat = Vector3.new(root.Position.X - center.X, 0, root.Position.Z - center.Z)
		if flat.Magnitude > radius or math.abs(root.Position.Y - center.Y) > 12 then
			continue
		end
		local healed = PlayerStatsService:ApplyHealing(player, humanoid.MaxHealth * fraction)
		if healed >= 1 then
			DamageIndicatorService:ShowHealIndicator(character, math.round(healed))
		end
	end
end

return function(_vfxService: any, caster: Player, _cframe: CFrame)
	local character = caster.Character
	if not character then
		return
	end
	local data = ArcaneData[SPELL]
	local seconds = data.channelSeconds or 5
	local radius = data.healRadius or 14
	local tick = data.tickSeconds or 0.5
	local fraction = data.healFraction or 0.02

	local ticks = math.floor(seconds / tick + 0.5)
	local stopped = false
	for index = 1, ticks do
		GameClock.Delay(tick * index, function()
			if stopped then
				return
			end
			local root = getRoot(character)
			if not root or not channeling(caster, character) then
				stopped = true
				return
			end
			pulse(root.Position, radius, fraction)
		end)
	end
end
