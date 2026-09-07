--[[
	Module: Client/Controllers/RelicController/ThrownRelic.lua
	Description:
	The shared client visual for a relic that is LOBBED from a corpse onto the
	ground and detonates: Trick Or Trap's Explosive Pumpkins and Fuse
	Bomb's bombs both run through here.

	Flow (identical for every user -- the only difference is which model is
	thrown):
	  1. Clone the relic's own display model, fade it in at the corpse.
	  2. Arc it along a quadratic bezier to the ground target, spinning on a
	     random per-throw rate, timed off the SERVER's start stamp so every
	     client sees the same flight.
	  3. On landing: kill the trail particles, then after a short beat play
	     the shared ExplosionFX (sound + burst) and fade the model out.

	Damage is NOT this module's job -- MobBase already fires the real hitbox
	server-side on the same clock. This is purely presentation, so a missing
	asset degrades to "no visual" instead of breaking the kill.

	The model is resolved from RelicData's rarity (GameAssets.Relics.<rarity>
	.<relicName>), the same convention the relic drop path uses.
]]

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local getRelicModelTemplate = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Relic.getRelicModelTemplate)

--[ Constants ]--

local DEFAULT_SCALE = 1.35
local FADE_SECONDS = 0.25
local ARC_APEX_STUDS = 10 -- height the bezier's control point sits above the midpoint
local LAND_TO_BLAST_SECONDS = 0.25
local CLEANUP_SECONDS = 5
local EXPLOSION_VOLUME = 0.05

local ThrownRelic = {}
ThrownRelic.__index = ThrownRelic

-- Resolves a relic's display model (tree-aware folder layout). Returns nil
-- (with a warn) rather than erroring, so a missing asset can't break a
-- takedown.
local function resolveModel(relicName: string): Model?
	local template = getRelicModelTemplate(relicName)
	if not template then
		warn("[ThrownRelic] Missing relic model for " .. tostring(relicName))
	end
	return template
end

function ThrownRelic.new(
	relicName: string,
	position: Vector3,
	targetPosition: Vector3,
	startTime: number,
	duration: number,
	quadraticBezierController: any,
	scale: number?
)
	local self = setmetatable({}, ThrownRelic)
	self.relicName = relicName
	self.position = position
	self.targetPosition = targetPosition
	self.startTime = startTime
	self.duration = duration
	self.quadraticBezierController = quadraticBezierController
	self.scale = scale or DEFAULT_SCALE
	return self
end

function ThrownRelic:PlayEffect()
	local template = resolveModel(self.relicName)
	if not template then
		return
	end

	local model = template:Clone()

	-- The idle "pick me up" sparkle belongs to the ground pickup, not to a
	-- thrown projectile. Guarded: not every relic model carries one.
	local primary = model.PrimaryPart
	local idleParticles = primary and primary:FindFirstChild("RelicParticleAttachment")
	if idleParticles then
		idleParticles:Destroy()
	end

	model:PivotTo(CFrame.new(self.position))
	model:ScaleTo(self.scale)

	local handle = model:FindFirstChild("Handle") or primary
	if handle then
		handle.Transparency = 1
		TweenService:Create(handle, TweenInfo.new(FADE_SECONDS, Enum.EasingStyle.Cubic), { Transparency = 0 }):Play()
	end
	model.Parent = workspace.IgnoreInstances.MagicSpells

	local originPosition = self.position
	local targetPosition = self.targetPosition
	local intermediatePosition = (originPosition + targetPosition) / 2 + Vector3.new(0, ARC_APEX_STUDS, 0)

	local rotationAngle = 0
	local randomRotate = math.random(-360, 360)

	local connection
	connection = RunService.RenderStepped:Connect(function(deltaTime: number)
		-- Alpha comes off the SERVER clock, so every client's arc lands at
		-- the same moment the server's hitbox fires.
		local now = workspace:GetServerTimeNow()
		local alpha = math.clamp((now - self.startTime) / self.duration, 0, 1)

		rotationAngle += deltaTime * math.rad(randomRotate) / self.duration

		local pos = self.quadraticBezierController:GenerateBezierCurve(
			alpha,
			originPosition,
			intermediatePosition,
			targetPosition
		)
		model:PivotTo(CFrame.new(pos) * CFrame.Angles(0, rotationAngle, 0))

		if alpha < 1 then
			return
		end
		connection:Disconnect()

		local activeAttachment = primary and primary:FindFirstChild("ActiveAttachment")
		if activeAttachment then
			for _, particle in activeAttachment:GetChildren() do
				if particle:IsA("ParticleEmitter") then
					particle.Enabled = false
					particle:Emit(5)
				end
			end
		end

		task.delay(LAND_TO_BLAST_SECONDS, function()
			local vfxFolder = ReplicatedStorage.GameAssets:FindFirstChild("VFX")
			local blastTemplate = vfxFolder
				and vfxFolder:FindFirstChild("Fire Blast")
				and vfxFolder["Fire Blast"]:FindFirstChild("ExplosionFX")

			if blastTemplate then
				local explosionVFX = blastTemplate:Clone()
				explosionVFX.CFrame = CFrame.new(targetPosition)
				explosionVFX.Parent = workspace.IgnoreInstances.MagicSpells

				explosionVFX.Explosion.Volume = EXPLOSION_VOLUME
				explosionVFX.Explosion2.Volume = EXPLOSION_VOLUME
				explosionVFX.Explosion:Play()
				explosionVFX.Explosion2.TimePosition = 0.25
				explosionVFX.Explosion2:Play()

				for _, descendant in explosionVFX.Attachment:GetChildren() do
					if descendant:IsA("ParticleEmitter") then
						descendant:Emit(10)
					end
				end
				Debris:AddItem(explosionVFX, CLEANUP_SECONDS)
			end

			if handle then
				TweenService:Create(handle, TweenInfo.new(FADE_SECONDS, Enum.EasingStyle.Cubic), { Transparency = 1 })
					:Play()
			end
			Debris:AddItem(model, CLEANUP_SECONDS)
		end)
	end)
end

return ThrownRelic
