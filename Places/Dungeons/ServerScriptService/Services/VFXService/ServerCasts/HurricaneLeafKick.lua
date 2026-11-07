--!strict
--[[
	Hurricane Leaf Kick, server side (PROTOTYPE, 2026-11-07).

	`hitDelay` seconds after the cast (when the kick lands), every mob
	within half the hitbox of the caster takes `damage` (VFXService's
	spell-hit path: Rank scaling, crits, Arcane, relic procs) and is
	STUNNED for `stunSeconds` (MobSimService:Stun): an attack it is winding
	up is cancelled before it lands, and it neither moves nor attacks until
	the stun ends. Minibosses and bosses take the damage but are never
	stunned.

	The caster's client dashes them forward first (VFXController
	HurricaneLeafKick); `hitDelay` is set past the dash so the server reads
	where it ended. The stun shows as floating "Stunned!" text (the shared
	TextIndicator) for every player. The knock-up hop needs the client mob
	renderer (MobController) to play it.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ArcaneData = require(ReplicatedStorage.Submodules.Core.Shared.Data.ArcaneData)
local ArcaneNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ArcaneNames)
local Blitz = require(ReplicatedStorage.Submodules.Core.Shared.Blitz)
local GameClock = require(ReplicatedStorage.Submodules.Core.Shared.GameClock)
local getRoot = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Character.getRoot)
local isEncounterEnemy = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Mob.isEncounterEnemy)

local SPELL = ArcaneNames["Hurricane Leaf Kick"]
local STUN_TEXT = "Stunned!"
local STUN_COLOR = Color3.fromRGB(255, 214, 74)

-- The shared floating text over the struck mob, for every player.
local function showStun(model: Model, root: BasePart)
	local textIndicator = Blitz.OptionalService("TextIndicatorService")
	if not textIndicator then
		return
	end
	local head = model:FindFirstChild("Head")
	local anchor = if head and head:IsA("BasePart") then head else root
	for _, viewer in Players:GetPlayers() do
		textIndicator:ShowIndicator(viewer, anchor, STUN_TEXT, STUN_COLOR, true)
	end
end

return function(vfxService: any, player: Player, _cframe: CFrame)
	local data = ArcaneData[SPELL]
	GameClock.Delay(data.hitDelay or 0.25, function()
		local character = player.Character
		local root = character and getRoot(character)
		if not root then
			return
		end
		local center = root.Position
		local radius = (data.hitboxSize and data.hitboxSize.X or 24) / 2
		local stunSeconds = data.stunSeconds or 1
		local mobSim = Blitz.OptionalService("MobSimService")

		local ignore = workspace:FindFirstChild("IgnoreInstances")
		local folder = ignore and ignore:FindFirstChild("Mobs")
		if not folder then
			return
		end
		for _, model in folder:GetChildren() do
			if not model:IsA("Model") then
				continue
			end
			local humanoid = model:FindFirstChildOfClass("Humanoid")
			local mobRoot = model:FindFirstChild("HumanoidRootPart")
			if not humanoid or humanoid.Health <= 0 or not mobRoot or not mobRoot:IsA("BasePart") then
				continue
			end
			local flat = (mobRoot.Position - center) * Vector3.new(1, 0, 1)
			if flat.Magnitude - mobRoot.Size.X / 2 > radius then
				continue
			end
			vfxService:_spellHit(model, CFrame.new(center), player, SPELL, data)
			if humanoid.Health > 0 and not isEncounterEnemy(model) and mobSim and mobSim:Stun(model, stunSeconds) then
				showStun(model, mobRoot)
			end
		end
	end)
end
