--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local ArcaneNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ArcaneNames)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local ArcaneData = require(ReplicatedStorage.Submodules.Core.Shared.Data.ArcaneData)
local VFXService = require(ServerScriptService.Services.VFXService)
local IgnoreListService = require(ServerScriptService.Submodules.Core.Source.Services.IgnoreListService)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local emitVFXPart = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.emitVFXPart)
local getRoot = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Character.getRoot)
local GameClock = require(ReplicatedStorage.Submodules.Core.Shared.GameClock)

-- The rig comes into being at the rise (2026-11-09; it was built at the
-- cast and parked 15 studs under the floor until then): `appearSeconds`
-- after the cast, it spawns under the caster and rises at once.
-- SusanooEnabled (its swings, the client's held-button start,
-- DamageService's reduction) flips on with it.
local RISE_AFTER_SPAWN = 0.05

return function(player: Player)
	local character = player.Character or player.CharacterAdded:Wait()
	local hrp = character:WaitForChild("HumanoidRootPart") :: BasePart
	local data = ArcaneData[ArcaneNames["Susanoo Armor"]]
	local appearSeconds = data.appearSeconds or 0.5

	-- Filled in by spawnRig; nil until the rise (and if the cast ended first).
	local susanooRig: Model? = nil
	local targetAttachment: Attachment? = nil
	local attackAnimation: AnimationTrack? = nil
	local animationConnection: RBXScriptConnection? = nil
	local ended = false

	local function spawnRig()
		if ended or player.Character ~= character or not hrp.Parent then
			return
		end
		-- Clone the rig
		local rig = ReplicatedStorage.GameAssets.VFX[ArcaneNames["Susanoo Armor"]].Armor:Clone()
		susanooRig = rig

		-- Ensure PrimaryPart is set correctly in Studio
		local primary = rig.PrimaryPart
		if not primary then
			warn("Susanoo rig has no PrimaryPart!")
			return
		end

		-- Place it roughly where it should start
		primary.CFrame = hrp.CFrame + Vector3.new(0, -15, 0)

		-- Create attachment on the character (this is our target)
		local target = Instance.new("Attachment")
		target.Name = "SusanooFollowAttachment"
		target.Position = Vector3.new(0, -15, 0)
		target.Parent = hrp
		targetAttachment = target

		-- Create attachment on the rig
		local rigAttachment = Instance.new("Attachment")
		rigAttachment.Name = "SusanooRootAttachment"
		rigAttachment.Parent = primary

		-- AlignPosition (smooth follow)
		local alignPosition = Instance.new("AlignPosition")
		alignPosition.Attachment0 = rigAttachment
		alignPosition.Attachment1 = target
		alignPosition.MaxForce = 100_000
		alignPosition.MaxVelocity = 75
		alignPosition.Responsiveness = 30
		alignPosition.Parent = primary

		-- AlignOrientation (match player rotation)
		local alignOrientation = Instance.new("AlignOrientation")
		alignOrientation.Attachment0 = rigAttachment
		alignOrientation.Attachment1 = target
		alignOrientation.MaxTorque = 100_000
		alignOrientation.MaxAngularVelocity = math.rad(360)
		alignOrientation.Responsiveness = 30
		alignOrientation.Parent = primary

		-- Its caster's: their cutscene keeps it on screen whatever its
		-- distance (CutsceneIsolationController; 2026-11-10: it arrives 15
		-- studs under them, past the near-the-caster check, and stayed hidden).
		rig:SetAttribute(Attributes.OwnerId, player.UserId)
		-- Parent to a clean folder
		rig.Parent = workspace.IgnoreInstances.ArcaneSpells

		-- Important: assign physics ownership on the SERVER
		primary:SetNetworkOwner(player)

		-- Load & play animation
		local animator = rig:WaitForChild("AnimationController"):WaitForChild("Animator")

		GameClock.Delay(data.duration, function()
			local gui = rig:FindFirstChild("SusanooPart")
			gui = gui and gui:FindFirstChild("SurfaceGui")
			if gui and gui:IsA("SurfaceGui") then
				gui.Enabled = false
			end
		end)

		-- The rise, a frame after the spawn so the rig starts under the floor.
		GameClock.Delay(RISE_AFTER_SPAWN, function()
			if ended then
				return
			end
			target.Position = Vector3.new(0, 5, 0)

			GameClock.Delay(0.05, function()
				local castVFX = ReplicatedStorage.GameAssets.VFX[ArcaneNames["Susanoo Armor"]].CastPart:Clone()
				castVFX.CFrame = hrp.CFrame
				castVFX:SetAttribute(Attributes.OwnerId, player.UserId)
				castVFX.Parent = workspace.IgnoreInstances.ArcaneSpells

				for _, particle in pairs(castVFX:GetDescendants()) do
					if particle:IsA("ParticleEmitter") then
						particle:Emit(5)
					end
				end

				GameClock.Debris(castVFX, 3)
			end)

			primary.SusanooActivate:Play()
		end)

		local idleTrack =
			animator:LoadAnimation(ReplicatedStorage.GameAssets.Animations:FindFirstChild("SusanooIdleAnimation"))
		idleTrack:Play(0.25)

		local attack =
			animator:LoadAnimation(ReplicatedStorage.GameAssets.Animations:FindFirstChild("SusanooAttackAnimation"))
		attackAnimation = attack

		attack:Play()
		attack:Stop()

		character:SetAttribute(Attributes.SusanooEnabled, true)

		animationConnection = attack:GetMarkerReachedSignal("SusanooAttack"):Connect(function()
			if not character:GetAttribute(Attributes.SusanooEnabled) then
				return
			end

			local root = getRoot(character)
			if not root then
				return
			end

			local attackVFXPart = ReplicatedStorage.GameAssets.VFX[ArcaneNames["Susanoo Armor"]].AttackPart:Clone()
			local range = ArcaneData[ArcaneNames["Susanoo Armor"]].range
			local hitboxCFrame = CFrame.new(
				primary.CFrame.Position + root.CFrame.LookVector * range + Vector3.new(0, -7.5, 0)
			) * CFrame.Angles(0, root.CFrame:ToEulerAnglesYXZ(), 0)

			attackVFXPart.CFrame = hitboxCFrame
			attackVFXPart:SetAttribute(Attributes.OwnerId, player.UserId)
			attackVFXPart.Parent = workspace.IgnoreInstances.ArcaneSpells

			for _, particle in pairs(attackVFXPart:GetDescendants()) do
				if particle:IsA("ParticleEmitter") then
					particle:Emit(10)
				end
			end

			primary.SusanooAttack:Play()
			primary.GroundSmash:Play()

			GameClock.Debris(attackVFXPart, 3)

			-- The combat pack's dust where the smash lands. Server-side like the
			-- AttackPart burst above; the helper needs only ReplicatedStorage and
			-- workspace, so it runs here exactly as it does on a client.
			emitVFXPart("GroundDust", hitboxCFrame, nil, { GroundSnapDistance = 10 })

			VFXService:CreateHitbox(
				ArcaneNames["Susanoo Armor"],
				player,
				hitboxCFrame,
				TagList.Zombie,
				IgnoreListService:GetWeaponIgnoreList(),
				function(model: Model)
					-- Through VFXService's spell-hit path so Korblox Mage Staff's
					-- refund sees the swing like any other cast hit.
					VFXService:_spellHit(
						model,
						hitboxCFrame,
						player,
						ArcaneNames["Susanoo Armor"],
						ArcaneData[ArcaneNames["Susanoo Armor"]]
					)
				end,
				ArcaneData[ArcaneNames["Susanoo Armor"]].hitboxSize.X
			)
		end)
	end

	GameClock.Delay(appearSeconds, spawnRig)

	GameClock.Delay(data.lifetime, function()
		ended = true
		if animationConnection then
			animationConnection:Disconnect()
		end
		if attackAnimation then
			attackAnimation:Stop(0.25)
		end

		character:SetAttribute(Attributes.SusanooEnabled, false)

		VFXService:_onAuraAttackStop(player)

		local rig = susanooRig
		local target = targetAttachment
		if not rig then
			-- The cast ended before the rise: nothing was built.
			return
		end
		if rig.PrimaryPart then
			(rig.PrimaryPart :: any).SusanooActivate:Play()
		end

		local castVFX = ReplicatedStorage.GameAssets.VFX[ArcaneNames["Susanoo Armor"]].CastPart:Clone()
		castVFX.CFrame = hrp.CFrame
		castVFX:SetAttribute(Attributes.OwnerId, player.UserId)
		castVFX.Parent = workspace.IgnoreInstances.ArcaneSpells

		for _, particle in pairs(castVFX:GetDescendants()) do
			if particle:IsA("ParticleEmitter") then
				particle:Emit(5)
			end
		end

		GameClock.Debris(castVFX, 3)

		if target then
			target.Position = Vector3.new(0, -15, 0)
		end

		GameClock.Delay(1, function()
			rig:Destroy()
			-- The follow target lives on the CHARACTER, not the rig: every
			-- cast left one more Attachment on the root part.
			if target then
				target:Destroy()
			end
		end)
	end)

	return function()
		if not character:GetAttribute(Attributes.SusanooEnabled) or not attackAnimation then
			return
		end

		attackAnimation:Play()
	end
end
