local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MagicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.MagicNames)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local MagicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.MagicData)
local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local onHitboxDamage = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Hitbox.onHitboxDamage)

local VFXService
local IgnoreListService

Knit.OnStart():andThen(function()
	VFXService = Knit.GetService("VFXService")
	IgnoreListService = Knit.GetService("IgnoreListService")
end)

return function(player: Player)
	local character = player.Character or player.CharacterAdded:Wait()
	local hrp = character:WaitForChild("HumanoidRootPart")

	-- Clone the rig
	local susanooRig = ReplicatedStorage.GameAssets.VFX[MagicNames["Susanoo Armor"]].Armor:Clone()

	-- Ensure PrimaryPart is set correctly in Studio
	local primary = susanooRig.PrimaryPart
	if not primary then
		warn("Susanoo rig has no PrimaryPart!")
		return
	end

	-- Place it roughly where it should start
	primary.CFrame = hrp.CFrame + Vector3.new(0, -15, 0)

	-- Create attachment on the character (this is our target)
	local targetAttachment = Instance.new("Attachment")
	targetAttachment.Name = "SusanooFollowAttachment"
	targetAttachment.Position = Vector3.new(0, -15, 0)
	targetAttachment.Parent = hrp

	-- Create attachment on the rig
	local rigAttachment = Instance.new("Attachment")
	rigAttachment.Name = "SusanooRootAttachment"
	rigAttachment.Parent = primary

	-- AlignPosition (smooth follow)
	local alignPosition = Instance.new("AlignPosition")
	alignPosition.Attachment0 = rigAttachment
	alignPosition.Attachment1 = targetAttachment
	alignPosition.MaxForce = 100_000
	alignPosition.MaxVelocity = 75
	alignPosition.Responsiveness = 30
	alignPosition.Parent = primary

	-- AlignOrientation (match player rotation)
	local alignOrientation = Instance.new("AlignOrientation")
	alignOrientation.Attachment0 = rigAttachment
	alignOrientation.Attachment1 = targetAttachment
	alignOrientation.MaxTorque = 100_000
	alignOrientation.MaxAngularVelocity = math.rad(360)
	alignOrientation.Responsiveness = 30
	alignOrientation.Parent = primary

	-- Parent to a clean folder
	susanooRig.Parent = workspace.IgnoreInstances.MagicSpells

	-- Important: assign physics ownership on the SERVER
	susanooRig.PrimaryPart:SetNetworkOwner(player)

	-- Load & play animation
	local animator = susanooRig:WaitForChild("AnimationController"):WaitForChild("Animator")

	task.delay(MagicData[MagicNames["Susanoo Armor"]].duration, function()
		susanooRig.SusanooPart.SurfaceGui.Enabled = false
	end)

	task.delay(0.5, function()
		targetAttachment.Position = Vector3.new(0, 5, 0)

		task.delay(0.05, function()
			local castVFX = ReplicatedStorage.GameAssets.VFX[MagicNames["Susanoo Armor"]].CastPart:Clone()
			castVFX.CFrame = hrp.CFrame
			castVFX.Parent = workspace.IgnoreInstances.MagicSpells

			for _, particle in pairs(castVFX:GetDescendants()) do
				if particle:IsA("ParticleEmitter") then
					particle:Emit(5)
				end
			end

			Debris:AddItem(castVFX, 3)
		end)

		susanooRig.PrimaryPart.SusanooActivate:Play()
	end)

	local idleTrack =
		animator:LoadAnimation(ReplicatedStorage.GameAssets.Animations:FindFirstChild("SusanooIdleAnimation"))
	idleTrack:Play(0.25)

	local attackAnimation =
		animator:LoadAnimation(ReplicatedStorage.GameAssets.Animations:FindFirstChild("SusanooAttackAnimation"))

	attackAnimation:Play()
	attackAnimation:Stop()

	character:SetAttribute(Attributes.SusanooEnabled, true)

	local animationConnection

	animationConnection = attackAnimation:GetMarkerReachedSignal("SusanooAttack"):Connect(function()
		if not character:GetAttribute(Attributes.SusanooEnabled) then
			return
		end

		local attackVFXPart = ReplicatedStorage.GameAssets.VFX[MagicNames["Susanoo Armor"]].AttackPart:Clone()
		local range = MagicData[MagicNames["Susanoo Armor"]].range
		local hitboxCFrame = CFrame.new(
			susanooRig.PrimaryPart.CFrame.Position
				+ character.HumanoidRootPart.CFrame.LookVector * range
				+ Vector3.new(0, -7.5, 0)
		) * CFrame.Angles(0, character.HumanoidRootPart.CFrame:ToEulerAnglesYXZ(), 0)

		attackVFXPart.CFrame = hitboxCFrame
		attackVFXPart.Parent = workspace.IgnoreInstances.MagicSpells

		for _, particle in pairs(attackVFXPart:GetDescendants()) do
			if particle:IsA("ParticleEmitter") then
				particle:Emit(10)
			end
		end

		susanooRig.PrimaryPart.SusanooAttack:Play()
		susanooRig.PrimaryPart.GroundSmash:Play()

		Debris:AddItem(attackVFXPart, 3)

		VFXService:CreateHitbox(
			MagicNames["Susanoo Armor"],
			player,
			hitboxCFrame,
			TagList.Zombie,
			IgnoreListService:GetWeaponIgnoreList(),
			function(model: Model)
				onHitboxDamage(model, hitboxCFrame, player, MagicData[MagicNames["Susanoo Armor"]], true, false)
			end,
			MagicData[MagicNames["Susanoo Armor"]].hitboxSize.X
		)
	end)

	task.delay(MagicData[MagicNames["Susanoo Armor"]].lifetime, function()
		animationConnection:Disconnect()
		attackAnimation:Stop(0.25)

		character:SetAttribute(Attributes.SusanooEnabled, false)

		susanooRig.PrimaryPart.SusanooActivate:Play()

		VFXService.Client:StopAuraAttack(player)

		local castVFX = ReplicatedStorage.GameAssets.VFX[MagicNames["Susanoo Armor"]].CastPart:Clone()
		castVFX.CFrame = hrp.CFrame
		castVFX.Parent = workspace.IgnoreInstances.MagicSpells

		for _, particle in pairs(castVFX:GetDescendants()) do
			if particle:IsA("ParticleEmitter") then
				particle:Emit(5)
			end
		end

		Debris:AddItem(castVFX, 3)

		targetAttachment.Position = Vector3.new(0, -15, 0)

		task.delay(1, function()
			susanooRig:Destroy()
		end)
	end)

	return function()
		if not character:GetAttribute(Attributes.SusanooEnabled) then
			return
		end

		attackAnimation:Play()
	end
end
