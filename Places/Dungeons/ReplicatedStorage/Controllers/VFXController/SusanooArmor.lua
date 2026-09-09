local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)

-- The screen tint is CLAIMED through MagicAmbienceController, not written
-- to Lighting here: one global property cannot be owned by two casts, and
-- writing it directly meant a Susanoo landing inside a Domain Expansion
-- repainted the screen and then handed it back to the AUTHORED grade
-- rather than to the domain that still owned it. First claim holds.
local SUSANOO_TINT_COLOR = Color3.fromRGB(217, 156, 255)

local MagicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.MagicNames)
local MagicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.MagicData)
local restoreWalkSpeed = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Movement.restoreWalkSpeed)

local CutsceneController
local MagicAmbienceController

Knit.OnStart():andThen(function()
	CutsceneController = Knit.GetController("CutsceneController")
	MagicAmbienceController = Knit.GetController("MagicAmbienceController")
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

	if not preload then
		ReplicatedStorage.GameAssets.Sounds.SusanooVoiceline:Play()
	end

	if player == Players.LocalPlayer and not preload then
		task.defer(function()
			-- MagicData.cutscene names the "Susanoo" camera path (two
			-- waypoints pivoted to the caster, GameAssets.CutsceneWaypoints
			-- .SusanooWaypoints). Going through the data index rather than
			-- PlayCutscene directly keeps the camera move and the server's
			-- invulnerability window reading the same numbers.
			CutsceneController:PlayMagicCutscene(MagicNames["Susanoo Armor"])
		end)

		-- The viewer's OWN Susanoo, so no proximity: it is on their body.
		local ambienceId = ("Susanoo_%d_%s"):format(player.UserId, tostring(os.clock()))
		if MagicAmbienceController then
			MagicAmbienceController:Claim(ambienceId, { tint = SUSANOO_TINT_COLOR })
		end

		task.delay(MagicData[MagicNames["Susanoo Armor"]].lifetime + 0.1, function()
			if MagicAmbienceController then
				MagicAmbienceController:Release(ambienceId)
			end
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
