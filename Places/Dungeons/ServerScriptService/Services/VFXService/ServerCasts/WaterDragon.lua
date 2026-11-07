--!strict
--[[
	Water Dragon, server side (PROTOTYPE, 2026-11-07).

	The dragon's head runs `travelDistance` studs down the caster's facing
	at `dragonSpeed`. Each mob within half the hitbox (the lane's width) of
	the lane is hit ONCE as the head reaches it, then CARRIED along with
	the head (MobSimService:Carry, at the dragon's own speed, so it rides
	the dragon smoothly) to where the dragon ends, at most `carryStuds`.
	The pack ends up washed along and bunched at the end of the lane.
	Minibosses and bosses take the hit but are never carried.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ArcaneData = require(ReplicatedStorage.Submodules.Core.Shared.Data.ArcaneData)
local ArcaneNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ArcaneNames)
local Blitz = require(ReplicatedStorage.Submodules.Core.Shared.Blitz)
local GameClock = require(ReplicatedStorage.Submodules.Core.Shared.GameClock)
local isEncounterEnemy = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Mob.isEncounterEnemy)

local SPELL = ArcaneNames["Water Dragon"]
local STEP_SECONDS = 0.03

return function(vfxService: any, player: Player, cframe: CFrame)
	local data = ArcaneData[SPELL]
	local origin = cframe.Position
	local look = Vector3.new(cframe.LookVector.X, 0, cframe.LookVector.Z)
	look = if look.Magnitude > 0.01 then look.Unit else Vector3.zAxis
	local total = data.travelDistance or 40
	local speed = math.max(data.dragonSpeed or 60, 1)
	local halfWidth = (data.hitboxSize and data.hitboxSize.X or 6) / 2
	local carryStuds = data.carryStuds or 16
	local struck: { [Model]: boolean } = {}
	local mobSim = Blitz.OptionalService("MobSimService")

	task.spawn(function()
		local travelled = 0
		local last = GameClock.Now()
		while travelled < total and player.Parent do
			GameClock.Wait(STEP_SECONDS)
			local now = GameClock.Now()
			travelled = math.min(total, travelled + speed * (now - last))
			last = now
			local ignore = workspace:FindFirstChild("IgnoreInstances")
			local folder = ignore and ignore:FindFirstChild("Mobs")
			if not folder then
				return
			end
			for _, model in folder:GetChildren() do
				if not model:IsA("Model") or struck[model] then
					continue
				end
				local humanoid = model:FindFirstChildOfClass("Humanoid")
				local mobRoot = model:FindFirstChild("HumanoidRootPart")
				if not humanoid or humanoid.Health <= 0 or not mobRoot or not mobRoot:IsA("BasePart") then
					continue
				end
				local offset = Vector3.new(mobRoot.Position.X - origin.X, 0, mobRoot.Position.Z - origin.Z)
				local along = offset:Dot(look)
				if along < -1 or along > travelled then
					continue
				end
				if (offset - look * along).Magnitude - mobRoot.Size.X / 2 <= halfWidth then
					struck[model] = true
					vfxService:_spellHit(model, CFrame.new(mobRoot.Position), player, SPELL, data)
					-- Ride the dragon to the end of the lane.
					local carry = math.min(carryStuds, total - along)
					if mobSim and humanoid.Health > 0 and carry > 0.5 and not isEncounterEnemy(model) then
						mobSim:Carry(model, look, carry, speed)
					end
				end
			end
		end
	end)
end
