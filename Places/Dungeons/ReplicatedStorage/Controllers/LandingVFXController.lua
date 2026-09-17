--!strict
--[[
	Module: Controllers/LandingVFXController.lua
	Description:
	Plays the landing-impact effect and the landing sound for EVERY
	player's dungeon-entry landing on this client, from the server's
	DungeonNetwork.LandingImpact broadcast.
	DungeonService fires that on the impact beat with the landing player
	attached, to everyone; LandingController deliberately leaves it
	unconsumed as the VFX hook, and this is the consumer.

	The effect sits on the FLOOR under the character's root, upright: a
	short ray down from the root (a landed R6 root is ~3 studs up), and
	root-minus-3 when nothing is under it. The server teleported and
	anchored the character for the drop and held the pose until it had
	replicated, so on every client the root is on the landing spot by the
	time the beat arrives -- no position needs to travel with the event.

	A Blitz module with no dependencies.
]]

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DungeonNetwork = require(ReplicatedStorage.Submodules.Core.Source.Network.Dungeon)
local emitVFXPart = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.emitVFXPart)

-- The combat pack's landing burst, dropped into GameAssets.VFX in Studio.
local LAND_VFX_NAME = "LandVFX"
-- Studs to look for the floor under the root, and how far below the root
-- the effect goes when nothing is there.
local LANDING_FLOOR_RAY_STUDS = 6
local LANDING_FLOOR_FALLBACK_DROP = 3
-- GameAssets.Sounds template for the impact. Played from the landed
-- character's root, not the template: a 3D source there gives the
-- lander a full-volume thud and a teammate a positional one, whereas
-- playing the template in ReplicatedStorage would be 2D and the same
-- volume for everyone on the server.
local LAND_SOUND_NAME = "LandSound"
-- Seconds the clone is kept: past the longest plausible sound length.
local LAND_SOUND_LIFETIME = 5

-- A missing template warns once, like the VFX helper does.
local warnedMissingSound = false
local function playLandSound(root: BasePart)
	local sounds = ReplicatedStorage:FindFirstChild("GameAssets")
	sounds = sounds and sounds:FindFirstChild("Sounds")
	local template = sounds and sounds:FindFirstChild(LAND_SOUND_NAME)
	if not template or not template:IsA("Sound") then
		if not warnedMissingSound then
			warnedMissingSound = true
			warn(("[LandingVFXController] GameAssets.Sounds.%s is missing; no landing sound"):format(LAND_SOUND_NAME))
		end
		return
	end
	local sound = template:Clone()
	sound.Parent = root
	sound:Play()
	Debris:AddItem(sound, LAND_SOUND_LIFETIME)
end

local LandingVFXController = {
	Name = "LandingVFXController",
}

function LandingVFXController.Start(_self: typeof(LandingVFXController))
	DungeonNetwork.LandingImpact.On(function(player: Player?)
		local character = player and player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not root or not root:IsA("BasePart") then
			return
		end
		emitVFXPart(LAND_VFX_NAME, root.CFrame, nil, {
			GroundSnapDistance = LANDING_FLOOR_RAY_STUDS,
			GroundFallbackDrop = LANDING_FLOOR_FALLBACK_DROP,
		})
		playLandSound(root)
	end)
end

return LandingVFXController
