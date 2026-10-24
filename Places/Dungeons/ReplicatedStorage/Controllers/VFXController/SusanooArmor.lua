--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CutsceneController = require(ReplicatedStorage.Controllers.CutsceneController)
local ArcaneAmbienceController = require(ReplicatedStorage.Controllers.ArcaneAmbienceController)

-- The screen tint is CLAIMED through ArcaneAmbienceController, not written
-- to Lighting here: one global property cannot be owned by two casts, and
-- writing it directly meant a Susanoo landing inside a Domain Expansion
-- repainted the screen and then handed it back to the AUTHORED grade
-- rather than to the domain that still owned it. First claim holds.
local SUSANOO_TINT_COLOR = Color3.fromRGB(217, 156, 255)

local ArcaneNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ArcaneNames)
local ArcaneData = require(ReplicatedStorage.Submodules.Core.Shared.Data.ArcaneData)
local restoreWalkSpeed = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Movement.restoreWalkSpeed)
local claimWalkSpeed = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Movement.claimWalkSpeed)
local emitVFXPart = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.emitVFXPart)

-- The spawn burst: GameAssets.VFX["Susanoo Armor"].SpawnPart, whose
-- attachment emitters carry their own EmitCount / EmitDelay /
-- EmitDuration (emitVFXPart reads them). Played on every client ON THE
-- SAME FRAME the server's CastPart lands: the server clones that part
-- into IgnoreInstances.ArcaneSpells at the caster's root once the rig
-- has risen (VFXServer/SusanooArmor), and it reaches each client a
-- replication hop later, so a fixed delay here always drifted from it.
-- This watches the folder for a CastPart arriving within
-- SPAWN_VFX_MATCH_STUDS of the caster and bursts a stud under it. If
-- none shows inside SPAWN_VFX_FALLBACK_SECONDS (the cast was refused,
-- or the part streamed elsewhere), the burst plays at the root anyway.
-- SPAWN only: the window closes long before the despawn CastPart.
local SPAWN_VFX_PATH = "Susanoo Armor/SpawnPart"
local SPAWN_VFX_OFFSET = CFrame.new(0, -1, 0)
local SPAWN_VFX_CAST_PART_NAME = "CastPart"
local SPAWN_VFX_MATCH_STUDS = 10
local SPAWN_VFX_FALLBACK_SECONDS = 2

return function(player: Player, preload: boolean?)
	local character = player.Character :: Model

	-- Claimed, so only THIS cast's restore below can undo it (see claimWalkSpeed).
	local walkSpeedClaim = claimWalkSpeed(character, 0)

	local susanooAnimation = (character:WaitForChild("Humanoid"):FindFirstChildOfClass("Animator") :: Animator):LoadAnimation(
		ReplicatedStorage.GameAssets.Animations:FindFirstChild("SusanooArmorAnimation")
	)

	-- The cast line ("I'll show you my true power.") is ArcaneData.dialogue,
	-- played by PlayerDialogueInterface off the cast replication.

	susanooAnimation:Play()
	susanooAnimation:AdjustSpeed(0.3)

	if not preload then
		ReplicatedStorage.GameAssets.Sounds.SusanooVoiceline:Play()

		-- Spawn burst, on the CastPart's own frame (see SPAWN_VFX_PATH).
		local ignoreInstances = workspace:FindFirstChild("IgnoreInstances")
		local spellsFolder = ignoreInstances and ignoreInstances:FindFirstChild("ArcaneSpells")
		local burstPlayed = false
		local castPartWatch: RBXScriptConnection? = nil
		local function playSpawnBurst(at: CFrame)
			if burstPlayed then
				return
			end
			burstPlayed = true
			if castPartWatch then
				castPartWatch:Disconnect()
			end
			emitVFXPart(SPAWN_VFX_PATH, at * SPAWN_VFX_OFFSET)
		end
		if spellsFolder then
			castPartWatch = spellsFolder.ChildAdded:Connect(function(child: Instance)
				if child.Name ~= SPAWN_VFX_CAST_PART_NAME or not child:IsA("BasePart") then
					return
				end
				local root = character:FindFirstChild("HumanoidRootPart")
				if
					root
					and root:IsA("BasePart")
					and (child.Position - root.Position).Magnitude <= SPAWN_VFX_MATCH_STUDS
				then
					playSpawnBurst(child.CFrame)
				end
			end)
		end
		task.delay(SPAWN_VFX_FALLBACK_SECONDS, function()
			if burstPlayed then
				return
			end
			local root = character:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") and character.Parent then
				playSpawnBurst(root.CFrame)
			elseif castPartWatch then
				castPartWatch:Disconnect()
			end
		end)
	end

	if player == Players.LocalPlayer and not preload then
		task.defer(function()
			-- ArcaneData.cutscene names the "Susanoo" camera path (two
			-- waypoints pivoted to the caster, GameAssets.CutsceneWaypoints
			-- .SusanooWaypoints). Going through the data index rather than
			-- PlayCutscene directly keeps the camera move and the server's
			-- invulnerability window reading the same numbers.
			CutsceneController:PlayArcaneCutscene(ArcaneNames["Susanoo Armor"])
		end)

		-- The viewer's OWN Susanoo, so no proximity: it is on their body.
		local ambienceId = ("Susanoo_%d_%s"):format(player.UserId, tostring(os.clock()))
		if ArcaneAmbienceController then
			ArcaneAmbienceController:Claim(ambienceId, { tint = SUSANOO_TINT_COLOR })
		end

		task.delay(ArcaneData[ArcaneNames["Susanoo Armor"]].lifetime + 0.1, function()
			if ArcaneAmbienceController then
				ArcaneAmbienceController:Release(ambienceId)
			end
		end)
	end

	task.delay(ArcaneData[ArcaneNames["Susanoo Armor"]].duration, function()
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
		restoreWalkSpeed(character, 0, walkSpeedClaim)
	end)
end
