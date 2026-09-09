local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")

local ColorCorrectionDefaults = require(ReplicatedStorage.Submodules.Core.Shared.Data.ColorCorrectionDefaults)

-- AUTHORED ColorCorrection tint, from ColorCorrectionDefaults (the one
-- source every grade-bending effect restores to). This effect tints the
-- screen and then puts it back; restoring to a literal would stomp the
-- place's own grade the moment it is authored as anything else.
local AUTHORED_TINT_COLOR = ColorCorrectionDefaults.TintColor

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)

local MagicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.MagicNames)
local MagicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.MagicData)
local restoreWalkSpeed = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Movement.restoreWalkSpeed)

local CutsceneController

Knit.OnStart():andThen(function()
	CutsceneController = Knit.GetController("CutsceneController")
end)

return function(player: Player, preload: boolean?)
	local character = player.Character

	character.Humanoid.WalkSpeed = 0

	local susanooAnimation = character:WaitForChild("Humanoid"):FindFirstChildOfClass("Animator"):LoadAnimation(
		ReplicatedStorage.GameAssets.Animations:FindFirstChild("SusanooArmorAnimation")
	)

	-- The cast line ("I'll show you my true power.") is MagicData.dialogue,
	-- played by PlayerDialogueInterface off the cast replication.

	susanooAnimation:Play()
	susanooAnimation:AdjustSpeed(0.3)

	if player == Players.LocalPlayer and not preload then
		task.defer(function()
			-- The "Susanoo" camera path (Cutscenes/Susanoo: two waypoints
			-- pivoted to the caster, GameAssets.CutsceneWaypoints
			-- .SusanooWaypoints). PlayCutscene brings the bars, the lock,
			-- the camera bob and the wall hide with it.
			CutsceneController:PlayCutscene("Susanoo")
		end)

		ReplicatedStorage.GameAssets.Sounds.SusanooCast:Play()

		TweenService:Create(
			Lighting.ColorCorrection,
			TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ TintColor = Color3.fromRGB(217, 156, 255) }
		):Play()

		task.delay(MagicData[MagicNames["Susanoo Armor"]].lifetime + 0.1, function()
			TweenService:Create(
				Lighting.ColorCorrection,
				TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ TintColor = AUTHORED_TINT_COLOR }
			):Play()
		end)
	end

	task.delay(MagicData[MagicNames["Susanoo Armor"]].duration, function()
		-- Only if this cast still OWNS the slow: weaving a swing (or
		-- another spell) in takes the slow over, and that owner restores
		-- it on its own timer. See Shared/Functions/Movement/
		-- restoreWalkSpeed.
		--
		-- The claim is 0 because that is what this cast WROTE (above), not
		-- the 2 its sibling spells use. Claiming 2 here could never match
		-- the humanoid's 0, so the restore would silently never fire and
		-- the player would stay rooted. Domain Expansion, the other spell
		-- that roots fully, claims 0 for the same reason.
		restoreWalkSpeed(character, 0)
	end)
end
