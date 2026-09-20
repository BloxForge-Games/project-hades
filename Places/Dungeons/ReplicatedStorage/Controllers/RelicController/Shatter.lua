--[[
	Module: Client/Controllers/RelicController/Shatter.lua
	Description:
	Ice Breaker (Epic) -- the Shatter burst that fires when Chill lands on an
	already-Chilled enemy.

	The prefab is GameAssets.VFX.Shatter.ShatterExplosion: a part carrying
	an `Explosion` sound and an `Attachment` of emitters, each with its own
	EmitCount / EmitDelay / EmitDuration attributes. emitVFXPart reads those
	(an emitter without them gets the helper's default burst), places and
	cleans up the clone; this module only adds the sound and the size.

	Server fires RelicNetwork.ShatterEffect.FireAll, so every
	client renders the burst -- including dead players spectating.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local emitVFXPart = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.emitVFXPart)

local Shatter = {}
Shatter.__index = Shatter

-- Nested under the Shatter folder in GameAssets.VFX (a slash path).
local SHATTER_VFX_PATH = "Shatter/ShatterExplosion"
local SHATTER_SOUND_NAME = "Explosion"

function Shatter.new(position: Vector3, scale: number?)
	local self = setmetatable({}, Shatter)
	self.position = position
	-- Azure's Frostburst window scales the burst up (server passes 3).
	self.scale = scale or 1
	return self
end

function Shatter:PlayEffect()
	-- Azure's enlarged Shatter: Scale grows the part, its attachment
	-- offsets and every emitter's size and speed (the helper caps a
	-- particle size at Roblox's 10-stud limit); EmitScale grows every
	-- authored burst count by the same factor.
	local explosionVFX = emitVFXPart(SHATTER_VFX_PATH, CFrame.new(self.position), nil, {
		Scale = self.scale,
		EmitScale = self.scale,
	})
	if not explosionVFX then
		return
	end

	local explosion = explosionVFX:FindFirstChild(SHATTER_SOUND_NAME)
	if explosion and explosion:IsA("Sound") then
		explosion:Play()
	end
end

return Shatter
