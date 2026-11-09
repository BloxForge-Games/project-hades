--!strict
-- Sand Armor, client side (PROTOTYPE, 2026-11-07; Stone Body until
-- 2026-11-08): the caster is cased in sand for `armorSeconds` (a sand
-- highlight with a bright, slowly pulsing outline, a warm glow and
-- trickling sand), then it bursts: a flash, a bright shock ring at the
-- blast's real radius, a sand disc on the floor, flung sand and a dust
-- cloud. The damage reduction, the taunt and the burst's damage are the
-- server's (VFXService/ServerCasts/SandArmor).
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local ArcaneData = require(ReplicatedStorage.Submodules.Core.Shared.Data.ArcaneData)
local ArcaneNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ArcaneNames)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local GameClock = require(ReplicatedStorage.Submodules.Core.Shared.GameClock)

local SPELL = ArcaneNames["Sand Armor"]
-- Sand, light and dark.
local STONE = Color3.fromRGB(226, 196, 140)
local STONE_DARK = Color3.fromRGB(176, 140, 86)
-- The skin's outline and the blast's flash: a warm amber that pops on any floor.
local GLOW = Color3.fromRGB(255, 196, 110)
-- A hit while armored: the sand fill flashes this red and eases back, on
-- the armor's own highlight (the character's damage flash is held off
-- while it is on, 2026-11-08).
local HIT_COLOR = Color3.fromRGB(255, 60, 60)
local HIT_FADE = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local RUBBLE_TEXTURE = "rbxasset://textures/particles/smoke_main.dds"

local function effectsFolder(): Instance
	local ignore = workspace:FindFirstChild("IgnoreInstances")
	return (ignore and ignore:FindFirstChild("ArcaneSpells")) or ignore or workspace
end

local function bare(part: Part)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
end

-- While the armor is on, it is the ONLY highlight on the character
-- (2026-11-08): a character shows one Highlight at a time, so a damage
-- flash, a dodge or another spell's highlight added on top hid the sand.
-- Every other Highlight on (or adorning) the character is switched off
-- and held off -- its owner re-enabling it is undone -- then each one this
-- turned off is put back on at the end, if it still exists. Returns the
-- release function.
-- The armor's own highlight is kept on (a perfect dodge's vanish switches
-- every highlight off). The character's OWN highlight steps off entirely
-- while Attributes.HighlightOverride is set (CharacterHighlightController),
-- so its flashes never re-add it over the armor (2026-11-08).
local function suppressOtherHighlights(character: Model, keep: Highlight): () -> ()
	local suppressed: { [Highlight]: RBXScriptConnection } = {}
	character:SetAttribute(Attributes.HighlightOverride, true)
	local function claim(instance: Instance)
		if not instance:IsA("Highlight") or instance == keep or suppressed[instance] then
			return
		end
		local adornee = instance.Adornee
		local onCharacter = instance:IsDescendantOf(character)
			or (adornee ~= nil and (adornee == character or adornee:IsDescendantOf(character)))
		if not onCharacter or not instance.Enabled then
			return
		end
		instance.Enabled = false
		suppressed[instance] = instance:GetPropertyChangedSignal("Enabled"):Connect(function()
			if instance.Enabled then
				instance.Enabled = false
			end
		end)
	end
	for _, descendant in character:GetDescendants() do
		claim(descendant)
	end
	-- Highlights parented elsewhere that adorn the character (an effects
	-- folder) as well as ones parented under it.
	local connections = {
		keep:GetPropertyChangedSignal("Enabled"):Connect(function()
			if not keep.Enabled and keep.Parent then
				keep.Enabled = true
			end
		end),
		character.DescendantAdded:Connect(claim),
		workspace.DescendantAdded:Connect(function(instance: Instance)
			if instance:IsA("Highlight") then
				-- Adornee is often set right after parenting.
				task.defer(claim, instance)
			end
		end),
	}
	return function()
		character:SetAttribute(Attributes.HighlightOverride, nil)
		for _, connection in connections do
			connection:Disconnect()
		end
		for highlight, connection in suppressed do
			connection:Disconnect()
			if highlight.Parent then
				highlight.Enabled = true
			end
		end
		table.clear(suppressed)
	end
end

local function shatter(at: Vector3, radius: number)
	local folder = effectsFolder()
	local floor = at - Vector3.new(0, 2.6, 0)

	-- The flash: a bright sphere bursting out and fading.
	local flash = Instance.new("Part")
	bare(flash)
	flash.Shape = Enum.PartType.Ball
	flash.Material = Enum.Material.Neon
	flash.Color = GLOW
	flash.Transparency = 0.2
	flash.Size = Vector3.one * 3
	flash.CFrame = CFrame.new(at)
	flash.Parent = folder
	TweenService:Create(
		flash,
		TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.one * radius * 1.4, Transparency = 1 }
	):Play()
	GameClock.Debris(flash, 0.4)

	-- The shock ring, thick and bright, out to the blast's real radius.
	local ring = Instance.new("Part")
	bare(ring)
	ring.Shape = Enum.PartType.Cylinder
	ring.Material = Enum.Material.Neon
	ring.Color = GLOW
	ring.Transparency = 0.1
	ring.Size = Vector3.new(0.4, 2, 2)
	ring.CFrame = CFrame.new(floor) * CFrame.Angles(0, 0, math.rad(90))
	ring.Parent = folder
	TweenService:Create(
		ring,
		TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.new(0.4, radius * 2, radius * 2), Transparency = 1 }
	):Play()
	GameClock.Debris(ring, 0.5)

	-- A sand disc under it, where the armor fell.
	local disc = Instance.new("Part")
	bare(disc)
	disc.Shape = Enum.PartType.Cylinder
	disc.Material = Enum.Material.Sand
	disc.Color = STONE_DARK
	disc.Size = Vector3.new(0.3, radius * 1.6, radius * 1.6)
	disc.CFrame = CFrame.new(floor - Vector3.new(0, 0.05, 0)) * CFrame.Angles(0, 0, math.rad(90))
	disc.Transparency = 0.3
	disc.Parent = folder
	TweenService:Create(disc, TweenInfo.new(0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Transparency = 1 })
		:Play()
	GameClock.Debris(disc, 0.9)

	local holder = Instance.new("Part")
	bare(holder)
	holder.Transparency = 1
	holder.Size = Vector3.one
	holder.CFrame = CFrame.new(at)

	-- The sand: big clumps thrown out to the blast's edge.
	local rubble = Instance.new("ParticleEmitter")
	rubble.Texture = RUBBLE_TEXTURE
	rubble.Color = ColorSequence.new(STONE, STONE_DARK)
	rubble.Size = NumberSequence.new(2.6, 0.6)
	rubble.Lifetime = NumberRange.new(0.5, 0.9)
	rubble.Speed = NumberRange.new(radius * 1.2, radius * 2.4)
	rubble.SpreadAngle = Vector2.new(180, 40)
	rubble.Acceleration = Vector3.new(0, -60, 0)
	rubble.Rate = 0
	rubble.Parent = holder

	-- The dust: a slower cloud hanging after the burst.
	local dust = Instance.new("ParticleEmitter")
	dust.Texture = RUBBLE_TEXTURE
	dust.Color = ColorSequence.new(STONE)
	dust.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 3),
		NumberSequenceKeypoint.new(1, 7),
	})
	dust.Transparency = NumberSequence.new(0.35, 1)
	dust.Lifetime = NumberRange.new(0.9, 1.4)
	dust.Speed = NumberRange.new(radius * 0.4, radius * 0.8)
	dust.SpreadAngle = Vector2.new(180, 15)
	dust.Drag = 3
	dust.Rate = 0
	dust.Parent = holder

	holder.Parent = folder
	rubble:Emit(90)
	dust:Emit(24)
	GameClock.Debris(holder, 2)
end

return function(player: Player, preload: boolean?)
	local character = player.Character
	if preload or not character then
		return
	end
	local data = ArcaneData[SPELL]
	local seconds = data.armorSeconds or 10
	local root = character:FindFirstChild("HumanoidRootPart")
	local sound = ReplicatedStorage.GameAssets.Sounds:FindFirstChild(data.castSound)
	if root and sound and sound:IsA("Sound") then
		local copy = sound:Clone()
		copy.Parent = root
		copy:Play()
		GameClock.Debris(copy, 4)
	end

	-- The skin: sand, a bright amber outline that pulses gently.
	local skin = Instance.new("Highlight")
	skin.Name = "SandArmor"
	skin.FillColor = STONE
	skin.FillTransparency = 1
	skin.OutlineColor = GLOW
	skin.OutlineTransparency = 1
	-- Through walls too (2026-11-08): the armor replaces the character's
	-- own through-wall outline while it is on.
	skin.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	skin.Parent = character
	local releaseHighlights = suppressOtherHighlights(character, skin)
	TweenService:Create(skin, TweenInfo.new(0.2), { FillTransparency = 0.1, OutlineTransparency = 0 }):Play()

	-- Hit feedback: health dropping turns the sand red, then back.
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local hitConnection: RBXScriptConnection? = nil
	if humanoid then
		local lastHealth = humanoid.Health
		local hitTween: Tween? = nil
		hitConnection = humanoid.HealthChanged:Connect(function(health: number)
			local dropped = health < lastHealth
			lastHealth = health
			if not dropped or not skin.Parent then
				return
			end
			if hitTween then
				hitTween:Cancel()
			end
			skin.FillColor = HIT_COLOR
			local fade = TweenService:Create(skin, HIT_FADE, { FillColor = STONE })
			hitTween = fade
			fade:Play()
		end)
	end
	GameClock.Delay(0.2, function()
		if skin.Parent then
			TweenService:Create(
				skin,
				TweenInfo.new(0.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
				{ OutlineTransparency = 0.5 }
			):Play()
		end
	end)

	if root and root:IsA("BasePart") then
		local glow = Instance.new("PointLight")
		glow.Color = GLOW
		glow.Brightness = 1.5
		glow.Range = 10
		glow.Parent = root
		GameClock.Debris(glow, seconds)

		local grit = Instance.new("ParticleEmitter")
		grit.Texture = RUBBLE_TEXTURE
		grit.Color = ColorSequence.new(STONE, STONE_DARK)
		grit.Size = NumberSequence.new(0.9, 0.2)
		grit.Lifetime = NumberRange.new(0.5, 0.9)
		grit.Speed = NumberRange.new(1, 3)
		grit.SpreadAngle = Vector2.new(180, 180)
		grit.Acceleration = Vector3.new(0, -20, 0)
		grit.Rate = 30
		grit.Parent = root
		GameClock.Debris(grit, seconds)
	end

	GameClock.Delay(seconds, function()
		releaseHighlights()
		if hitConnection then
			hitConnection:Disconnect()
		end
		if skin.Parent then
			skin:Destroy()
		end
		local liveRoot = character:FindFirstChild("HumanoidRootPart")
		if liveRoot and liveRoot:IsA("BasePart") then
			-- The ring reaches the hitbox's real radius (Wind Bomb's: hitboxSize.X).
			shatter(liveRoot.Position, data.hitboxSize and data.hitboxSize.X or 12)
		end
	end)
end
