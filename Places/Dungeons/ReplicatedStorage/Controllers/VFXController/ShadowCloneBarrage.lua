--!strict
-- Shadow Clone Barrage, client side (PROTOTYPE, 2026-11-07): the cast
-- sound, and (2026-11-08) the hand seal with the caster slowed to
-- CAST_WALK_SPEED for the cast (ArcaneData `duration`). The seal is sped
-- up to fit the cast exactly and plays at Action4, so a weapon swing woven
-- into the cast cannot override it; it is preloaded with the spell so the
-- first cast is not missing it. The clones are ShadowCloneService's
-- proxies, drawn by ShadowCloneController.
local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ArcaneData = require(ReplicatedStorage.Submodules.Core.Shared.Data.ArcaneData)
local ArcaneNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ArcaneNames)
local GameClock = require(ReplicatedStorage.Submodules.Core.Shared.GameClock)
local claimWalkSpeed = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Movement.claimWalkSpeed)
local restoreWalkSpeed = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Movement.restoreWalkSpeed)
local loadOneShotAnimation = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Character.loadOneShotAnimation)

local SPELL = ArcaneNames["Shadow Clone Barrage"]
-- The Domain hand seal (0.73 s at speed 1).
local HAND_SEAL_ID = "rbxassetid://121360847047261"
local HAND_SEAL_SECONDS = 0.73
local CAST_WALK_SPEED = 1

local handSeal = Instance.new("Animation")
handSeal.AnimationId = HAND_SEAL_ID

-- Fetched as soon as the client loads this module, so the first cast
-- already has it (a cold LoadAnimation can miss the whole 0.5 s cast).
local function preloadSeal()
	task.spawn(function()
		pcall(ContentProvider.PreloadAsync, ContentProvider, { handSeal })
	end)
end
preloadSeal()

return function(player: Player, preload: boolean?)
	if preload then
		preloadSeal()
		return
	end
	local character = player.Character
	if not character then
		return
	end
	local data = ArcaneData[SPELL]
	local castSeconds = (data and data.duration) or 0.5
	local root = character:FindFirstChild("HumanoidRootPart")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	if animator then
		local track = loadOneShotAnimation(animator, handSeal)
		track.Priority = Enum.AnimationPriority.Action4
		local length = if track.Length > 0 then track.Length else HAND_SEAL_SECONDS
		track:Play(0.05, 1, length / castSeconds)
	end

	-- The caster's own client owns their movement: slow it for the cast.
	if player == Players.LocalPlayer then
		local claim = claimWalkSpeed(character, CAST_WALK_SPEED)
		GameClock.Delay(castSeconds, function()
			restoreWalkSpeed(character, CAST_WALK_SPEED, claim)
		end)
	end

	local sound = ReplicatedStorage.GameAssets.Sounds:FindFirstChild("Magic Spell Cast")
	if root and sound and sound:IsA("Sound") then
		local copy = sound:Clone()
		copy.Parent = root
		copy:Play()
		GameClock.Debris(copy, 4)
	end
end
