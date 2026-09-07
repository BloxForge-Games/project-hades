--[[
	Module: Client/Controllers/RelicController/Shatter.lua
	Description:
	Ice Breaker (Epic) — the Shatter burst that fires when Chill lands on an
	already-Chilled enemy.

	The VFX is the same shape as Trick Or Trap's pumpkin detonation (an
	explosion part carrying `Explosion` / `Explosion2` sounds and an
	`Attachment` of emitters), so this plays it with the SAME volumes, sound
	offset, emit count and cleanup as the pumpkin branch in
	Client/Controllers/RelicController/ThrownRelic:PlayEffect — keep the two in
	step if that one is ever retuned.

	Server fires RelicService.Client.OnShatterActivated:FireAll, so every
	client renders the burst — including dead players spectating.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

local Shatter = {}
Shatter.__index = Shatter

-- Matches ThrownRelic:PlayEffect's explosion cadence exactly.
local PARTICLE_EMIT = 10
local CLEANUP_SECONDS = 5

function Shatter.new(position: Vector3, scale: number?)
	local self = setmetatable({}, Shatter)
	self.position = position
	-- Azure's Frostburst window scales the burst up (server passes 3).
	self.scale = scale or 1
	return self
end

function Shatter:PlayEffect()
	local template = ReplicatedStorage.GameAssets.VFX:FindFirstChild("Shatter")
	local explosionTemplate = template and template:FindFirstChild("ShatterExplosion")
	if not explosionTemplate then
		warn("[Shatter] Missing GameAssets.VFX.Shatter.ShatterExplosion")
		return
	end

	local explosionVFX = explosionTemplate:Clone()
	-- Azure's enlarged Shatter. The burst is DRAWN by the ParticleEmitters,
	-- and ParticleEmitter.Size is its own NumberSequence in studs — it
	-- ignores the size of the part it rides. Scaling only the part (the old
	-- code) changed nothing visible. So: scale every emitter's Size keypoints
	-- and its Speed range, so the particles are bigger AND travel farther.
	-- Roblox clamps a particle Size keypoint at 10 studs — a large scale
	-- saturates there.
	if self.scale ~= 1 then
		explosionVFX.Size = explosionVFX.Size * self.scale
		for _, descendant in explosionVFX:GetDescendants() do
			if descendant:IsA("ParticleEmitter") then
				local keypoints = {}
				for index, keypoint in descendant.Size.Keypoints do
					keypoints[index] = NumberSequenceKeypoint.new(
						keypoint.Time,
						math.min(keypoint.Value * self.scale, 10),
						math.min(keypoint.Envelope * self.scale, 10)
					)
				end
				descendant.Size = NumberSequence.new(keypoints)
				descendant.Speed = NumberRange.new(descendant.Speed.Min * self.scale, descendant.Speed.Max * self.scale)
			end
		end
	end
	explosionVFX.CFrame = CFrame.new(self.position)
	explosionVFX.Parent = workspace.IgnoreInstances.MagicSpells

	local explosion = explosionVFX:FindFirstChild("Explosion")

	if explosion then
		explosion:Play()
	end

	local attachment = explosionVFX:FindFirstChild("Attachment")
	if attachment then
		for _, particle in attachment:GetChildren() do
			if particle:IsA("ParticleEmitter") then
				particle:Emit(math.round(PARTICLE_EMIT * self.scale))
			end
		end
	end

	Debris:AddItem(explosionVFX, CLEANUP_SECONDS)
end

return Shatter
