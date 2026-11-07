--!strict
-- Rasenshuriken, client side (PROTOTYPE, 2026-11-07): the throw, then a
-- spinning shuriken of wind that rides the server's marker
-- (VFXService/ServerCasts/Rasenshuriken), opens into a swirling vortex
-- while the marker's Phase is "Vortex", and bursts on "Burst". Every
-- client draws it on the same marker, so all see it where the server is.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local ArcaneData = require(ReplicatedStorage.Submodules.Core.Shared.Data.ArcaneData)
local ArcaneNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ArcaneNames)
local GameClock = require(ReplicatedStorage.Submodules.Core.Shared.GameClock)
local loadOneShotAnimation = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Character.loadOneShotAnimation)

local SPELL = ArcaneNames.Rasenshuriken
local CORE_COLOR = Color3.fromRGB(150, 220, 255)
local BLADE_COLOR = Color3.fromRGB(235, 248, 255)
local WIND_TEXTURE = "rbxasset://textures/particles/smoke_main.dds"
-- How long to wait for the server's marker to stream in.
local MARKER_WAIT = 2
local BLADES = 4
-- Spin (radians/s) while flying and while the vortex holds.
local SPIN_FLYING = 22
local SPIN_VORTEX = 14
-- How fast the visual closes on the marker (per second, exponential).
local FOLLOW_RATE = 22

local function effectsFolder(): Instance
	local ignore = workspace:FindFirstChild("IgnoreInstances")
	return (ignore and ignore:FindFirstChild("ArcaneSpells")) or ignore or workspace
end

local function neon(shape: Enum.PartType, color: Color3, transparency: number, size: Vector3): Part
	local part = Instance.new("Part")
	part.Shape = shape
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = color
	part.Transparency = transparency
	part.Size = size
	return part
end

-- The newest marker of `player`'s, waiting for it to stream in.
local function findMarker(player: Player): BasePart?
	local folder = effectsFolder()
	local deadline = os.clock() + MARKER_WAIT
	while os.clock() < deadline do
		for _, child in folder:GetChildren() do
			if
				child.Name == "Rasenshuriken"
				and child:IsA("BasePart")
				and child:GetAttribute("OwnerId") == player.UserId
				and not child:GetAttribute("ClaimedVisual")
			then
				return child
			end
		end
		task.wait()
	end
	return nil
end

return function(player: Player, preload: boolean?)
	local character = player.Character
	if preload or not character then
		return
	end
	local data = ArcaneData[SPELL]
	local pullRadius = data.pullRadius or 12
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	local asset = ReplicatedStorage.GameAssets.Animations:FindFirstChild(data.castAnimation)
	if animator and asset and asset:IsA("Animation") then
		loadOneShotAnimation(animator, asset):Play(0.05)
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	local sound = ReplicatedStorage.GameAssets.Sounds:FindFirstChild(data.castSound)
	if root and sound and sound:IsA("Sound") then
		local copy = sound:Clone()
		copy.Parent = root
		copy:Play()
		GameClock.Debris(copy, 4)
	end

	task.spawn(function()
		local marker = findMarker(player)
		if not marker then
			return
		end
		-- Locally only: this client's copy has a visual now.
		marker:SetAttribute("ClaimedVisual", true)

		local model = Instance.new("Model")
		model.Name = "RasenshurikenVisual"
		local core = neon(Enum.PartType.Ball, CORE_COLOR, 0.1, Vector3.one * 2.4)
		core.Parent = model
		local blades: { Part } = {}
		for _ = 1, BLADES do
			local blade = neon(Enum.PartType.Block, BLADE_COLOR, 0.25, Vector3.new(4.5, 0.2, 1.1))
			blade.Parent = model
			table.insert(blades, blade)
		end
		local disc = neon(Enum.PartType.Cylinder, CORE_COLOR, 1, Vector3.new(0.3, 3, 3))
		disc.Parent = model
		local wind = Instance.new("ParticleEmitter")
		wind.Texture = WIND_TEXTURE
		wind.Color = ColorSequence.new(BLADE_COLOR)
		wind.Size = NumberSequence.new(1.5, 3)
		wind.Transparency = NumberSequence.new(0.4, 1)
		wind.Lifetime = NumberRange.new(0.2, 0.4)
		wind.Speed = NumberRange.new(2, 5)
		wind.Rate = 60
		wind.Parent = core
		model.Parent = effectsFolder()

		local position = marker.Position
		local angle = 0
		local bladeScale = 1
		local phase = "Flying"
		local connection: RBXScriptConnection? = nil

		local function burst(at: Vector3)
			local blast = neon(Enum.PartType.Ball, BLADE_COLOR, 0.15, Vector3.one * 3)
			blast.CFrame = CFrame.new(at)
			blast.Parent = effectsFolder()
			TweenService:Create(
				blast,
				TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Size = Vector3.one * pullRadius * 2, Transparency = 1 }
			):Play()
			GameClock.Debris(blast, 0.45)
		end

		local function finish()
			if connection then
				connection:Disconnect()
				connection = nil
			end
			burst(position)
			model:Destroy()
		end

		connection = RunService.RenderStepped:Connect(function(dt: number)
			if not marker.Parent then
				finish()
				return
			end
			local nextPhase = marker:GetAttribute("Phase")
			if nextPhase ~= phase then
				phase = if type(nextPhase) == "string" then nextPhase else phase
				if phase == "Vortex" then
					-- Opens out: the blades grow to the pull's reach, a faint
					-- disc marks it, the wind turns inward.
					TweenService:Create(disc, TweenInfo.new(0.25), {
						Size = Vector3.new(0.3, pullRadius * 2, pullRadius * 2),
						Transparency = 0.75,
					}):Play()
					wind.Rate = 160
					wind.Speed = NumberRange.new(-14, -8)
					wind.Size = NumberSequence.new(3, 1)
				elseif phase == "Burst" then
					finish()
					return
				end
			end
			if phase == "Vortex" then
				bladeScale += (pullRadius / 2.5 - bladeScale) * math.min(dt * 8, 1)
			end
			position = position:Lerp(marker.Position, 1 - math.exp(-FOLLOW_RATE * dt))
			angle += dt * (if phase == "Vortex" then SPIN_VORTEX else SPIN_FLYING)
			core.CFrame = CFrame.new(position)
			disc.CFrame = CFrame.new(position - Vector3.new(0, 2.5, 0)) * CFrame.Angles(0, 0, math.rad(90))
			for index, blade in blades do
				local bladeAngle = angle + (index - 1) * (math.pi * 2 / BLADES)
				local length = 4.5 * bladeScale
				blade.Size = Vector3.new(length, 0.2, 1.1 * math.sqrt(bladeScale))
				blade.CFrame = CFrame.new(position) * CFrame.Angles(0, bladeAngle, 0) * CFrame.new(length / 2, 0, 0)
			end
		end)
		-- A safety net if the marker never ends cleanly.
		GameClock.Delay(
			(data.throwDistance or 30) / math.max(data.throwSpeed or 50, 1) + (data.vortexSeconds or 1.5) + 3,
			function()
				if model.Parent then
					finish()
				end
			end
		)
	end)
end
