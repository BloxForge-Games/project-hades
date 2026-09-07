--[[
     Module: RelicController.lua
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local RelicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicData)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local Signal = require(ReplicatedStorage.Submodules.Core.Packages.Signal)

-- Relic effects
local Volleyball = require(script.Volleyball)
local ThrownRelic = require(script.ThrownRelic)
local Shatter = require(script.Shatter)
local LightningStrike = require(script.LightningStrike)
local Jail = require(script.Jail)
local Fireworks = require(script.Fireworks)

local RelicService
local QuadraticBezierController

local RelicController = Knit.CreateController({
	Name = "RelicController",
	Client = {},

	_relicRegistry = {},
	_clientRenderedRelics = {}, -- [userId] = { parts = {}, count = number, visible = bool }
})

RelicController.Signals = {
	OnRelicCollected = Signal.new() :: (relicName: RelicNames.RelicNames) -> (),
	OnRelicsUpdated = Signal.new() :: () -> (),
}

function RelicController:GetRelicEffect(player: Player, relicName: RelicNames.RelicNames)
	if
		self._relicRegistry[tostring(player.UserId)]
		and self._relicRegistry[tostring(player.UserId)][relicName]
		and self._relicRegistry[tostring(player.UserId)][relicName] > 0
	then
		return RelicData[relicName].callback(player, self._relicRegistry[tostring(player.UserId)][relicName])
	end
end

function RelicController:GetRelicsFromUserId(userId: number)
	return self._relicRegistry[tostring(userId)] or nil
end

function RelicController:KnitStart()
	RelicService = Knit.GetService("RelicService")
	QuadraticBezierController = Knit.GetController("QuadraticBezierController")

	RelicService.OnReplicateRelics:Connect(
		function(
			playerId: number,
			relicRegistry: { [RelicNames.RelicNames]: number },
			relicsList: { RelicNames.RelicNames }
		)
			self._relicRegistry = relicRegistry

			if playerId == Players.LocalPlayer.UserId then
				RelicController.Signals.OnRelicsUpdated:Fire(
					playerId,
					RelicController:GetRelicsFromUserId(playerId),
					relicsList[tostring(playerId)]
				)
			end
		end
	)

	RelicService.OnFireworksEffectActivated:Connect(
		function(player: Player, targetCharacter: Model, startTime: number, duration: number)
			Fireworks.new(player.Character, targetCharacter, duration, startTime, QuadraticBezierController)
				:PlayEffect()
		end
	)

	RelicService.OnJailEffectActivated:Connect(function(targetCharacter: Model)
		Jail.new(targetCharacter):PlayEffect()
	end)

	-- Thrown-relic visuals: a model lobbed from the corpse that arcs to the
	-- ground and detonates (ThrownRelic). Trick Or Trap's pumpkins and
	-- Fuse Bomb's bombs both ride it — the payload's relicName picks the
	-- model (older payloads omit it; default to the pumpkin). The real
	-- damage hitbox is fired server-side on the same clock.
	RelicService.OnPumpkinEffectActivated:Connect(
		function(
			position: Vector3,
			targetPosition: Vector3,
			startTime: number,
			duration: number,
			_magicName: string?,
			relicName: string?
		)
			ThrownRelic.new(
				relicName or RelicNames["Trick Or Trap"],
				position,
				targetPosition,
				startTime,
				duration,
				QuadraticBezierController
			):PlayEffect()
		end
	)

	-- `scale` is 1 for a normal Shatter, 2 while Staff of Azure Ever Ice's
	-- Frostburst window doubles them.
	RelicService.OnShatterActivated:Connect(function(position: Vector3, scale: number?)
		Shatter.new(position, scale):PlayEffect()
	end)

	RelicService.OnLightningStrikeActivated:Connect(function(position: Vector3)
		LightningStrike.new(position):PlayEffect()
	end)

	RelicService.OnVolleyballEffectActivated:Connect(
		function(character: Model, targetCharacter: Model, startTime: number, duration: number)
			Volleyball.new(character, targetCharacter, duration, startTime, QuadraticBezierController):PlayEffect()
		end
	)

	-- Super Stomp Boots VFX hook. Server fires AFTER damage application
	-- in SuperStompBoots:InvokeStomp. Placeholder print until VFX is
	-- authored — replace with the stomp visual when ready. Payload:
	--   caster          : Player who stomped
	--   landingPosition : Vector3 where the dodge ended
	--   radius          : number  (AOE radius, in studs)
	--   baseDamage      : number  (pre-variance, pre-rounding)
	RelicService.OnSuperStompBoots:Connect(function(_caster: Player, landingPosition: Vector3)
		local superStompBootsVFX = ReplicatedStorage.GameAssets.VFX["Super Stomp Boots"]["Super Stomp Boots"]:Clone()
		superStompBootsVFX:PivotTo(CFrame.new(landingPosition))
		superStompBootsVFX.Parent = workspace.IgnoreInstances.MagicSpells

		for _, particle in superStompBootsVFX.Part.Attachment:GetChildren() do
			if particle:IsA("ParticleEmitter") then
				particle:Emit(25)
			end
		end

		superStompBootsVFX.Part.Stomp:Play()

		Debris:AddItem(superStompBootsVFX, 5)
	end)
end

Knit.AddControllers(script.SubControllers)

return RelicController
