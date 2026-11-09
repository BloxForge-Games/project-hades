--!strict
--[[
	Module: TrainingDummyService.lua (Lobby)
	Description:
	The hub's training dummy (2026-11-07; Shared/Data/TrainingDummyData): a
	wooden R6 rig in the Lobby room that players hit to test their damage.
	It never dies and moves nothing; every hit shows the dungeon's own
	floating number (DamageIndicatorService, core) and a readout over its
	head: who hit it last, their last hit, DPS over DPS_WINDOW_SECONDS and
	the total, cleared after RESET_AFTER_SECONDS without a hit.

	HITS. The Lobby has no DamageService, so the core hit paths
	(Server/Components/MeleeWeapon, ProjectileCastService) hand a hit on a
	model carrying TrainingDummyData.ATTRIBUTE to :Hit instead. The dummy is
	tagged Zombie, the weapons' target tag, so swings and arrows find it.

	DAMAGE. :Hit runs the RELIC-FREE part of DamageService:TakeDamage for a
	weapon hit, which is everything a hub player can have:
	  base     computeWeaponDamage (the caller's, the same number a dungeon
	           hit starts from)
	  variance rollDamageVariance (+/-10%)
	  additive + ArmorSetBonusService weapon amp (the Ruinseeker set)
	           + the WeaponDamage enchantment and gear lines
	  crit     BonusStatData.Base chance and multiplier + the CritChance /
	           CritDamage gear lines + the CritChance enchantment; chance
	           past 100 becomes crit damage, as in the dungeon
	Left out because the hub cannot have them: relics, auras
	(Enflamed / Frostburst / Stormcharged windows), Greater Shrines, boss
	damage and the target's statuses. It MIRRORS DamageService rather than
	calling it (that service is Dungeons-only); keep the two in step when
	the weapon formula changes.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local PlayerStatsService = require(ServerScriptService.Submodules.Core.Source.Services.PlayerStatsService)
local ArmorSetBonusService = require(ServerScriptService.Submodules.Core.Source.Services.ArmorSetBonusService)
local DamageIndicatorService = require(ServerScriptService.Submodules.Core.Source.Services.DamageIndicatorService)
local BonusStatData = require(ReplicatedStorage.Submodules.Core.Shared.Data.BonusStatData)
local TrainingDummyData = require(ReplicatedStorage.Submodules.Core.Shared.Data.TrainingDummyData)
local DamageIndicatorColors = require(ReplicatedStorage.Submodules.Core.Shared.Enums.DamageIndicatorColors)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local CollisionGroups = require(ReplicatedStorage.Submodules.Core.Shared.Enums.CollisionGroups)
local CollisionGroupService = require(ServerScriptService.Submodules.Core.Source.Services.CollisionGroupService)
local rollDamageVariance = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Damage.rollDamageVariance)
local GameClock = require(ReplicatedStorage.Submodules.Core.Shared.GameClock)

local DUMMY_NAME = "Training Dummy"
-- White and ExtraBold, title and readout alike (2026-11-07; the title was
-- gold, the font Bold).
local TITLE_COLOR = Color3.fromRGB(255, 255, 255)
-- The readout line a light grey under the white title (2026-11-07).
local TEXT_COLOR = Color3.fromRGB(190, 190, 190)
local FONT = Font.new("rbxasset://fonts/families/Montserrat.json", Enum.FontWeight.ExtraBold, Enum.FontStyle.Normal)
-- The readout: no hitter's name (2026-11-07), dashes when idle.
local READOUT_FORMAT = "Last: %s | DPS: %s | Total: %s"
local IDLE_TEXT = string.format(READOUT_FORMAT, "--", "--", "--")
-- The rig: R6 part sizes and their places relative to the Torso.
-- The Torso's centre above the floor (legs 2 + half the torso 1).
local TORSO_HEIGHT = 3
-- The readout over the head, in studs (width, height).
local READOUT_SIZE = Vector2.new(9, 1.4)
-- The lines' text size limits in pixels (UITextSizeConstraint) and the
-- distance the readout hides past (2026-11-08).
local TITLE_TEXT_LIMITS = NumberRange.new(8, 18)
local READOUT_TEXT_LIMITS = NumberRange.new(8, 14)
-- 150 (2026-11-08; 60 hid dummies still on screen under the high camera).
local READOUT_MAX_DISTANCE = 150
-- The classic Rig Builder dummy grey (Medium stone grey).
local DUMMY_COLOR = Color3.fromRGB(163, 162, 165)

type HitRecord = { at: number, value: number }
-- One dummy's score (2026-11-07: any number of dummies, each its own).
type DummyState = {
	model: Model,
	readout: TextLabel,
	hits: { HitRecord },
	total: number,
	lastHitAt: number,
	lastValue: number,
}

local TrainingDummyService = {
	Name = "TrainingDummyService",
	Dependencies = { PlayerStatsService, ArmorSetBonusService, DamageIndicatorService } :: { any },
}

-- Every dummy in the place, keyed by its model.
TrainingDummyService._dummies = {} :: { [Model]: DummyState }

--[ Damage ]--

-- One weapon hit's number and whether it crit (see DAMAGE above).
function TrainingDummyService.RollHit(
	_self: typeof(TrainingDummyService),
	player: Player,
	baseDamage: number
): (number, boolean)
	local damage = rollDamageVariance(baseDamage)
	-- The WeaponDamage enchantment and gear lines, as one fraction.
	local weaponDamage = PlayerStatsService:GetEnchantmentStat(player, "WeaponDamage")
		+ PlayerStatsService:GetGearStat(player, "WeaponDamage")
	local total = damage + ArmorSetBonusService:GetWeaponDamageAmplifier(player, damage, false) + damage * weaponDamage

	local critChance = BonusStatData.Base.CritChance * 100
		+ PlayerStatsService:GetGearStat(player, "CritChance") * 100
		+ PlayerStatsService:GetEnchantmentStat(player, "CritChance")
	local critMultiplier = BonusStatData.Base.CritDamage + PlayerStatsService:GetGearStat(player, "CritDamage")
	if critChance > 100 then
		critMultiplier += (critChance - 100) / 100
		critChance = 100
	end

	if math.random() * 100 <= critChance then
		return math.round(total * critMultiplier), true
	end
	return math.round(total), false
end

-- Whether `model` is the training dummy.
function TrainingDummyService.IsDummy(_self: typeof(TrainingDummyService), model: Instance?): boolean
	return model ~= nil and model:GetAttribute(TrainingDummyData.ATTRIBUTE) == true
end

-- A weapon hit on the dummy by `player`: rolls the number, shows it and
-- counts it. `isMelee` false is a ranged shot (an arrow: no sparks, its
-- own impact draws, as in the dungeon).
function TrainingDummyService.Hit(
	self: typeof(TrainingDummyService),
	player: Player,
	model: Model,
	baseDamage: number,
	isMelee: boolean
)
	if not self:IsDummy(model) or baseDamage <= 0 then
		return
	end
	local value, critical = self:RollHit(player, baseDamage)
	DamageIndicatorService:ShowIndicator(
		player,
		model,
		value,
		critical,
		DamageIndicatorColors.Weapon,
		isMelee,
		nil,
		nil,
		if isMelee then nil else false
	)
	self:_record(model, value)
end

--[ Readout ]--

local refreshReadout: (state: DummyState) -> ()

local function formatNumber(value: number): string
	local text = tostring(math.floor(value + 0.5))
	local formatted = text:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (formatted:gsub("^,", ""))
end

function TrainingDummyService._record(self: typeof(TrainingDummyService), model: Model, value: number)
	local state = self._dummies[model]
	if not state then
		return
	end
	local now = GameClock.Now()
	if now - state.lastHitAt > TrainingDummyData.RESET_AFTER_SECONDS then
		table.clear(state.hits)
		state.total = 0
	end
	table.insert(state.hits, { at = now, value = value })
	state.total += value
	state.lastHitAt = now
	state.lastValue = value
	refreshReadout(state)
end

-- Damage per second over the last DPS_WINDOW_SECONDS: the window's sum over
-- the time it covers (at least a second, so one hit is not a spike).
local function dps(state: DummyState, now: number): number
	local window = TrainingDummyData.DPS_WINDOW_SECONDS
	local sum, first = 0, now
	for index = #state.hits, 1, -1 do
		local hit = state.hits[index]
		if now - hit.at > window then
			break
		end
		sum += hit.value
		first = hit.at
	end
	return sum / math.max(now - first, 1)
end

function refreshReadout(state: DummyState)
	local readout = state.readout
	local now = GameClock.Now()
	if now - state.lastHitAt > TrainingDummyData.RESET_AFTER_SECONDS then
		readout.Text = IDLE_TEXT
		return
	end
	readout.Text = string.format(
		READOUT_FORMAT,
		formatNumber(state.lastValue),
		formatNumber(dps(state, now)),
		formatNumber(state.total)
	)
end

--[ The rig ]--

-- A line of the readout: `top` and `height` are shares of the billboard,
-- the text scaled to fit (the billboard is sized in studs, so the text
-- keeps its size against the dummy on every screen, 2026-11-07), held
-- between `minSize` and `maxSize` pixels (2026-11-08): up close it stops
-- growing, far off it stays readable.
local function newLabel(
	parent: Instance,
	text: string,
	color: Color3,
	top: number,
	height: number,
	minSize: number,
	maxSize: number
): TextLabel
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.FontFace = FONT
	label.Position = UDim2.fromScale(0, top)
	label.Size = UDim2.fromScale(1, height)
	label.Text = text
	label.TextColor3 = color
	label.TextScaled = true
	label.TextStrokeTransparency = 0.4
	local limits = Instance.new("UITextSizeConstraint")
	limits.MinTextSize = minSize
	limits.MaxTextSize = maxSize
	limits.Parent = label
	label.Parent = parent
	return label
end

-- Where the dummy stands: the TrainingDummySpawn part, else the fallback,
-- dropped onto the floor below.
local function placement(): CFrame
	local spawnPart = workspace:FindFirstChild(TrainingDummyData.SPAWN_PART_NAME, true)
	local position, facing = TrainingDummyData.FALLBACK_POSITION, TrainingDummyData.FALLBACK_FACING
	if spawnPart and spawnPart:IsA("BasePart") then
		position = spawnPart.Position
		facing = spawnPart.CFrame.LookVector
	end
	local floor = workspace:Raycast(position + Vector3.new(0, 10, 0), Vector3.new(0, -60, 0))
	local floorY = if floor then floor.Position.Y else position.Y - TORSO_HEIGHT
	local flat = Vector3.new(facing.X, 0, facing.Z)
	if flat.Magnitude < 0.01 then
		flat = Vector3.new(0, 0, -1)
	end
	local torsoPosition = Vector3.new(position.X, floorY + TORSO_HEIGHT, position.Z)
	return CFrame.lookAt(torsoPosition, torsoPosition + flat.Unit)
end

-- A grey R6 rig, the fallback when the place has no "Training Dummy" model
-- (the Lobby place file carries one, 2026-11-07, so it can be moved in
-- Studio): the default description in the Rig Builder grey, no face, its
-- feet set on the floor at placement().
local function buildFallback(): Model
	local description = Instance.new("HumanoidDescription")
	-- The Rig Builder dummy's grey (a blank description is black).
	for _, property in { "HeadColor", "TorsoColor", "LeftArmColor", "RightArmColor", "LeftLegColor", "RightLegColor" } do
		(description :: any)[property] = DUMMY_COLOR
	end
	local model = Players:CreateHumanoidModelFromDescription(description, Enum.HumanoidRigType.R6)
	model.Name = DUMMY_NAME
	local target = placement()
	model:PivotTo(target)
	-- Stand it on the floor: the rig's pivot is not its torso centre, so
	-- line its lowest point up with where the feet belong.
	local boxCFrame, boxSize = model:GetBoundingBox()
	local bottom = boxCFrame.Position.Y - boxSize.Y / 2
	local feetY = target.Position.Y - TORSO_HEIGHT
	model:PivotTo(model:GetPivot() + Vector3.new(0, feetY - bottom, 0))
	model.Parent = workspace
	return model
end

-- Makes `model` the dummy: still, walk-through, scored, aimable. Whatever
-- the model is (the place's own or the fallback), it is set up the same.
function TrainingDummyService._setUp(self: typeof(TrainingDummyService), model: Model)
	local passThrough = CollisionGroupService:EnsurePassThrough()
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			-- Anchored in place, walk-through (PassThrough: the Humanoid forces
			-- Head / Torso solid otherwise), hits still land (CanQuery on).
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CollisionGroup = passThrough
		elseif
			descendant:IsA("Script")
			or descendant:IsA("LocalScript")
			or (descendant:IsA("Decal") and descendant.Name == "face")
		then
			-- The default Animate / Health scripts (a still dummy needs
			-- neither) and the face (none, 2026-11-07).
			descendant:Destroy()
		end
	end

	-- The cursor's aim-assist box (2026-11-07), as every dungeon mob has:
	-- an invisible RaycastHitbox a little bigger than the rig, so pointing
	-- near the dummy aims at it. Hit by the aim ray (Default queries), kept
	-- out of the weapons' overlap queries by its MobRaycastHitbox group
	-- (IgnoreListService), so it never counts as a hit itself.
	local torso = model:FindFirstChild("Torso") or model.PrimaryPart
	if torso and torso:IsA("BasePart") and not model:FindFirstChild("RaycastHitbox") then
		local hoverBox = Instance.new("Part")
		hoverBox.Name = "RaycastHitbox"
		hoverBox.Anchored = true
		hoverBox.CanCollide = false
		hoverBox.CanTouch = false
		hoverBox.CanQuery = true
		hoverBox.Transparency = 1
		hoverBox.Size = Vector3.new(4.5, 6.5, 3)
		hoverBox.CFrame = torso.CFrame * CFrame.new(0, -0.5, 0)
		hoverBox.CollisionGroup = CollisionGroups.MobRaycastHitbox
		hoverBox.Parent = model
	end

	local existing = model:FindFirstChildOfClass("Humanoid")
	local humanoid: Humanoid = if existing then existing else Instance.new("Humanoid")
	if not existing then
		humanoid.RigType = Enum.HumanoidRigType.R6
		humanoid.Parent = model
	end
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	-- Never takes damage itself (the service only counts), but a target
	-- must have Health above 0 for the hit paths to accept it.
	humanoid.MaxHealth = 1e9
	humanoid.Health = 1e9
	humanoid.BreakJointsOnDeath = false

	-- The readout, over the head.
	local head = model:FindFirstChild("Head")
	local gui = Instance.new("BillboardGui")
	gui.Name = "Readout"
	local adornee: Instance? = if head and head:IsA("BasePart") then head else model.PrimaryPart
	gui.Adornee = adornee :: any
	-- In studs (scale), not pixels: pixel text stays the same size on a
	-- phone while the world shrinks, so it read huge there.
	gui.Size = UDim2.fromScale(READOUT_SIZE.X, READOUT_SIZE.Y)
	gui.StudsOffset = Vector3.new(0, 2.6, 0)
	-- Hidden past this (2026-11-08; was 120), so dummies across the room
	-- don't add text to the screen.
	gui.MaxDistance = READOUT_MAX_DISTANCE
	gui.LightInfluence = 0
	gui.Parent = model
	-- The name, smaller than it was (2026-11-08; 0.52 of the height).
	newLabel(gui, DUMMY_NAME, TITLE_COLOR, 0.16, 0.36, TITLE_TEXT_LIMITS.Min, TITLE_TEXT_LIMITS.Max)
	local readout = newLabel(gui, IDLE_TEXT, TEXT_COLOR, 0.59, 0.32, READOUT_TEXT_LIMITS.Min, READOUT_TEXT_LIMITS.Max)

	model:SetAttribute(TrainingDummyData.ATTRIBUTE, true)
	-- The weapons' target tag: swings and arrows only hit tagged models.
	CollectionService:AddTag(model, TagList.Zombie)
	CollectionService:AddTag(model, TagList.LungeBlocker)
	self._dummies[model] = {
		model = model,
		readout = readout,
		hits = {},
		total = 0,
		lastHitAt = -math.huge,
		lastValue = 0,
	}
	model.Destroying:Connect(function()
		self._dummies[model] = nil
	end)
end

-- Every "Training Dummy" model directly in Workspace becomes a dummy (move
-- and duplicate them in Studio, 2026-11-07); one is built when there are
-- none.
function TrainingDummyService._spawn(self: typeof(TrainingDummyService))
	local found = false
	for _, child in workspace:GetChildren() do
		if child.Name == DUMMY_NAME and child:IsA("Model") then
			found = true
			self:_setUp(child)
		end
	end
	if not found then
		self:_setUp(buildFallback())
	end
end

--[ Lifecycle ]--

function TrainingDummyService.Start(self: typeof(TrainingDummyService))
	-- The fallback build (CreateHumanoidModelFromDescription) yields.
	task.spawn(self._spawn, self)
	-- The readout's DPS falls and resets on its own, so it ticks.
	task.spawn(function()
		while true do
			task.wait(0.5)
			for _, state in self._dummies do
				refreshReadout(state)
			end
		end
	end)
end

return TrainingDummyService
