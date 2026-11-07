--!strict
--[[
	ShadowCloneController (PROTOTYPE, 2026-11-07): draws Shadow Clone
	Barrage's clones on this client.

	The server moves each clone as an invisible proxy under
	workspace.IgnoreInstances.ShadowClones (ShadowCloneService). Here every
	proxy gets a local VISUAL: a copy of its caster's character holding the
	caster's own drawn melee weapon (skin, and enchantment: the copy keeps
	its `Enchantment` attribute and the "Weapon" tag, so
	WeaponEnchantFXController dresses it), or a plain Steel Sword when the
	proxy says OwnerWeapon = false. The visual eases after the proxy every
	frame, so a clone glides however the proxy's updates arrive.

	It moves and swings exactly like a player: the weapon's idle / run /
	three swing animations at the weapon's speeds, the slash VFX
	(MeleeWeaponVFXData, the same call the player's swing makes), the slash
	sound and the lunge's dust puff (meleeSwingFeel). Proxy attributes drive
	it: Moving, SwingIteration + SwingSerial, HitSerial (a white flash).
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local MeleeWeaponData = require(ReplicatedStorage.Submodules.Core.Shared.Data.MeleeWeaponData)
local MeleeWeaponVFXData = require(ReplicatedStorage.Submodules.Core.Shared.Data.MeleeWeaponVFXData)
local WeaponNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.WeaponNames)
local GameClock = require(ReplicatedStorage.Submodules.Core.Shared.GameClock)
local playOneShot = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Audio.playOneShot)
local meleeSwingFeel = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Weapon.meleeSwingFeel)
local resolveAnimation = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Weapon.resolveAnimation)

local FOLDER_NAME = "ShadowClones"
local FALLBACK_WEAPON = WeaponNames["Steel Sword"]
-- How fast the visual closes on the proxy (per second, exponential).
local FOLLOW_RATE = 18
-- A proxy this far from its visual is snapped to, not eased toward.
local SNAP_STUDS = 25
local SMOKE_TEXTURE = "rbxasset://textures/particles/smoke_main.dds"
local FADE_IN = 0.25

type Visual = {
	proxy: Model,
	proxyRoot: BasePart,
	model: Model,
	root: BasePart,
	weapon: { [string]: any },
	weaponModel: Model?,
	idle: AnimationTrack?,
	run: AnimationTrack?,
	swings: { AnimationTrack? },
	current: AnimationTrack?,
	connections: { RBXScriptConnection },
}

local ShadowCloneController = {
	Name = "ShadowCloneController",
	_visuals = {} :: { [Model]: Visual },
	_render = nil :: RBXScriptConnection?,
}

--[ Helpers ]--

local function effectsFolder(): Instance
	local ignore = workspace:FindFirstChild("IgnoreInstances")
	return (ignore and ignore:FindFirstChild("ArcaneSpells")) or ignore or workspace
end

local function smokePuff(position: Vector3)
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Size = Vector3.one
	part.CFrame = CFrame.new(position)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = SMOKE_TEXTURE
	emitter.Color = ColorSequence.new(Color3.fromRGB(240, 240, 240))
	emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 2), NumberSequenceKeypoint.new(1, 5) })
	emitter.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.15), NumberSequenceKeypoint.new(1, 1) })
	emitter.Lifetime = NumberRange.new(0.4, 0.7)
	emitter.Speed = NumberRange.new(4, 9)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Rate = 0
	emitter.Parent = part
	part.Parent = effectsFolder()
	emitter:Emit(24)
	GameClock.Debris(part, 1.5)
end

local function stripTags(root: Instance)
	local everything = root:GetDescendants()
	table.insert(everything, root)
	for _, item in everything do
		for _, tag in CollectionService:GetTags(item) do
			CollectionService:RemoveTag(item, tag)
		end
	end
end

-- Destroys every joint or constraint under `root` that reaches outside it.
local function cutOutsideJoints(root: Instance)
	for _, item in root:GetDescendants() do
		local outside = false
		if item:IsA("JointInstance") or item:IsA("WeldConstraint") then
			local part0, part1 = (item :: any).Part0, (item :: any).Part1
			outside = (part0 and not part0:IsDescendantOf(root)) or (part1 and not part1:IsDescendantOf(root))
		elseif item:IsA("Constraint") then
			local a0, a1 = (item :: any).Attachment0, (item :: any).Attachment1
			outside = (a0 and not a0:IsDescendantOf(root)) or (a1 and not a1:IsDescendantOf(root))
		end
		if outside then
			item:Destroy()
		end
	end
end

local function copyOf(instance: Instance): Instance?
	local wasArchivable = instance.Archivable
	instance.Archivable = true
	local ok, result = pcall(function()
		return instance:Clone()
	end)
	instance.Archivable = wasArchivable
	return if ok then result else nil
end

-- A puppet copy of `character`: no scripts, tags, attributes, nameplate,
-- sounds, weapons or outside joints; parts never collide or get hit; the
-- root anchored (the controller places it) and the Humanoid not simulated.
local function puppetOf(character: Model): Model?
	local result = copyOf(character)
	if not result or not result:IsA("Model") then
		return nil
	end
	local puppet = result
	puppet.Name = "ShadowCloneVisual"
	for _, child in puppet:GetChildren() do
		if child:HasTag("Weapon") or child:HasTag("Sheathed") or string.sub(child.Name, -8) == "Sheathed" then
			child:Destroy()
		end
	end
	cutOutsideJoints(puppet)
	stripTags(puppet)
	local everything = puppet:GetDescendants()
	table.insert(everything, puppet)
	for _, item in everything do
		if item.Parent == nil and item ~= puppet then
			continue
		end
		for name in item:GetAttributes() do
			if string.sub(name, 1, 3) ~= "RBX" then
				item:SetAttribute(name, nil)
			end
		end
		if
			item:IsA("LuaSourceContainer")
			or item:IsA("BillboardGui")
			or item:IsA("ForceField")
			or item:IsA("Sound")
			or item:IsA("ProximityPrompt")
			or item:IsA("Highlight")
		then
			item:Destroy()
		elseif item:IsA("BasePart") then
			item.Anchored = false
			item.CanCollide = false
			item.CanQuery = false
			item.CanTouch = false
			item.Massless = true
		end
	end
	local humanoid = puppet:FindFirstChildOfClass("Humanoid")
	local root = puppet:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root or not root:IsA("BasePart") then
		puppet:Destroy()
		return nil
	end
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	humanoid.BreakJointsOnDeath = false
	humanoid.EvaluateStateMachine = false
	root.Anchored = true
	puppet.PrimaryPart = root
	return puppet
end

-- Welds a weapon piece's Handle to `target` through its grip attachment.
local function weldPiece(piece: Model, attachmentName: string, target: Instance?)
	local handle = piece:FindFirstChild("Handle")
	if not handle or not handle:IsA("BasePart") or not target or not target:IsA("BasePart") then
		return
	end
	local attach = handle:FindFirstChild(attachmentName)
	local weld = Instance.new("Weld")
	weld.Name = "HandleWeld"
	weld.Part0 = target
	weld.Part1 = handle
	weld.C0 = CFrame.new()
	weld.C1 = if attach and attach:IsA("Attachment") then attach.CFrame else CFrame.new()
	weld.Parent = handle
end

-- Shows every part of a weapon copy (a drawn copy may be hidden while its
-- owner holds the bow), as the loadout's own "visible" does.
local function showWeapon(weapon: Model)
	for _, item in weapon:GetDescendants() do
		if item:IsA("BasePart") then
			item.Anchored = false
			item.CanCollide = false
			item.CanQuery = false
			item.CanTouch = false
			item.Massless = true
			if item.Name ~= "Handle" and not item:HasTag("AlwaysHidden") then
				item.Transparency = 0
			end
		elseif item:IsA("ParticleEmitter") and not item:HasTag("AlwaysOff") then
			item.Enabled = true
		end
	end
end

-- The weapon for the visual: the caster's own drawn melee copy (skin and
-- enchantment come with it), else a plain asset copy.
local function weaponFor(proxy: Model, owner: Model?, puppet: Model): Model?
	local weaponName = proxy:GetAttribute("WeaponName")
	local source: Instance? = nil
	if proxy:GetAttribute("OwnerWeapon") == true and owner then
		for _, child in owner:GetChildren() do
			if child:IsA("Model") and child:HasTag("Weapon") and child:HasTag("Primary") then
				source = child
				break
			end
		end
	end
	local fromOwner = source ~= nil
	if not source then
		-- The caster's drawn copy is not here (streamed out): the plain asset.
		local name = if proxy:GetAttribute("OwnerWeapon") == true and type(weaponName) == "string"
			then weaponName
			else FALLBACK_WEAPON
		source = ReplicatedStorage.GameAssets.Weapons:FindFirstChild(name)
	end
	local copy = source and copyOf(source)
	if not copy or not copy:IsA("Model") then
		return nil
	end
	local weapon = copy
	cutOutsideJoints(weapon)
	-- The enchantment's emitters are re-made by WeaponEnchantFXController.
	for _, item in weapon:GetDescendants() do
		if item:HasTag("EnchantmentFX") then
			item:Destroy()
		end
	end
	stripTags(weapon)
	showWeapon(weapon)
	weapon.Name = "CloneWeapon"
	weapon.Parent = puppet

	-- A dual-wield asset straight from GameAssets holds Right + Left; the
	-- owner's drawn copy has Left nested under the main piece.
	local right = weapon:FindFirstChild("Right")
	local left = weapon:FindFirstChild("Left")
	if right and right:IsA("Model") and left and left:IsA("Model") then
		weldPiece(right, "RightGripAttachment", puppet:FindFirstChild("RightHandle"))
		weldPiece(left, "LeftGripAttachment", puppet:FindFirstChild("LeftHandle"))
	else
		weldPiece(weapon, "RightGripAttachment", puppet:FindFirstChild("RightHandle"))
		for _, child in weapon:GetChildren() do
			if child:IsA("Model") and child:FindFirstChild("Handle") then
				weldPiece(child, "LeftGripAttachment", puppet:FindFirstChild("LeftHandle"))
			end
		end
	end
	if fromOwner and weapon:GetAttribute("Enchantment") ~= nil then
		weapon:AddTag("Weapon")
	end
	return weapon
end

--[ Visuals ]--

function ShadowCloneController._playSwing(_self: typeof(ShadowCloneController), visual: Visual)
	local iteration = visual.proxy:GetAttribute("SwingIteration")
	if type(iteration) ~= "number" then
		return
	end
	local weapon = visual.weapon
	local track = visual.swings[iteration]
	if visual.current and visual.current ~= track then
		visual.current:Stop(0.25 * GameClock.Scale())
	end
	if track then
		track:Play(0.25 * GameClock.Scale())
		GameClock.SetAnimationSpeed(track, (weapon.animationSpeeds and weapon.animationSpeeds[iteration]) or 1)
		visual.current = track
	end

	local model = visual.model
	-- The lunge's dust, where the player's swing kicks it.
	GameClock.Delay(((weapon.dashDelay and weapon.dashDelay[iteration]) or 0.25) / 2, function()
		if model.Parent then
			meleeSwingFeel.dustPuff(model)
		end
	end)
	-- The slash VFX, the player's own.
	local playSlash = MeleeWeaponVFXData[iteration]
	if playSlash then
		GameClock.Delay((weapon.vfxDelays and weapon.vfxDelays[iteration]) or 0.25, function()
			if model.Parent then
				playSlash(model, false, nil, weapon.weaponType)
			end
		end)
	end
	-- The slash sound.
	local weaponModel = visual.weaponModel
	local handle = weaponModel and weaponModel:FindFirstChild("Handle")
	local slash = handle and handle:FindFirstChild("Slash")
	if slash and slash:IsA("Sound") then
		if weapon.weaponType == "Greatsword" then
			GameClock.Delay(((weapon.vfxDelays and weapon.vfxDelays[iteration]) or 0.5) - 0.05, function()
				playOneShot.Play(slash)
			end)
		else
			playOneShot.Play(slash)
		end
	end
end

function ShadowCloneController._setMoving(_self: typeof(ShadowCloneController), visual: Visual)
	local moving = visual.proxy:GetAttribute("Moving") == true
	if moving then
		if visual.idle then
			visual.idle:Stop(0.15)
		end
		if visual.run and not visual.run.IsPlaying then
			visual.run:Play(0.15)
			GameClock.SetAnimationSpeed(visual.run, visual.weapon.runAnimationSpeed or 1)
		end
	else
		if visual.run then
			visual.run:Stop(0.15)
		end
		if visual.idle and not visual.idle.IsPlaying then
			visual.idle:Play(0.15)
		end
	end
end

function ShadowCloneController._flash(_self: typeof(ShadowCloneController), visual: Visual)
	local flash = Instance.new("Highlight")
	flash.FillColor = Color3.new(1, 1, 1)
	flash.FillTransparency = 0.3
	flash.OutlineTransparency = 1
	flash.DepthMode = Enum.HighlightDepthMode.Occluded
	flash.Parent = visual.model
	GameClock.Debris(flash, 0.12)
end

function ShadowCloneController._add(self: typeof(ShadowCloneController), proxy: Instance)
	if not proxy:IsA("Model") or self._visuals[proxy] then
		return
	end
	local proxyRoot = proxy:WaitForChild("HumanoidRootPart", 5)
	if not proxyRoot or not proxyRoot:IsA("BasePart") or not proxy.Parent then
		return
	end
	local ownerId = proxy:GetAttribute("OwnerId")
	local owner = if type(ownerId) == "number" then Players:GetPlayerByUserId(ownerId) else nil
	local ownerCharacter = owner and owner.Character
	if not ownerCharacter then
		return
	end
	local puppet = puppetOf(ownerCharacter)
	if not puppet then
		return
	end
	local weaponName = proxy:GetAttribute("WeaponName")
	local weapon = (type(weaponName) == "string" and MeleeWeaponData[weaponName]) or MeleeWeaponData[FALLBACK_WEAPON]
	local weaponModel = weaponFor(proxy, ownerCharacter, puppet)

	local root = puppet.PrimaryPart :: BasePart
	root.CFrame = proxyRoot.CFrame
	-- Fade in from clear.
	local parts: { BasePart } = {}
	local authored: { [BasePart]: number } = {}
	for _, item in puppet:GetDescendants() do
		if item:IsA("BasePart") and item.Transparency < 1 and item.Name ~= "Handle" then
			table.insert(parts, item)
			authored[item] = item.Transparency
			item.Transparency = 1
		end
	end
	puppet.Parent = effectsFolder()
	smokePuff(root.Position)

	local humanoid = puppet:FindFirstChildOfClass("Humanoid") :: Humanoid
	local foundAnimator = humanoid:FindFirstChildOfClass("Animator")
	local animator: Animator = if foundAnimator then foundAnimator else Instance.new("Animator")
	animator.Parent = humanoid
	local function load(field: any, looped: boolean): AnimationTrack?
		local animation = resolveAnimation(field)
		if not animation then
			return nil
		end
		local track = animator:LoadAnimation(animation)
		track.Looped = looped
		return track
	end

	local visual: Visual = {
		proxy = proxy,
		proxyRoot = proxyRoot,
		model = puppet,
		root = root,
		weapon = weapon,
		weaponModel = weaponModel,
		idle = load(weapon.idleAnimation, true),
		run = load(weapon.runAnimation, true),
		swings = {
			load(weapon.swingAnimation1, false),
			load(weapon.swingAnimation2, false),
			load(weapon.swingAnimation3, false),
		},
		current = nil,
		connections = {},
	}
	self._visuals[proxy] = visual
	self:_setMoving(visual)

	local started = os.clock()
	local fade: RBXScriptConnection? = nil
	fade = RunService.RenderStepped:Connect(function()
		local alpha = math.clamp((os.clock() - started) / FADE_IN, 0, 1)
		for _, part in parts do
			if part.Parent then
				part.Transparency = 1 - (1 - authored[part]) * alpha
			end
		end
		if alpha >= 1 and fade then
			fade:Disconnect()
		end
	end)
	table.insert(visual.connections, fade :: RBXScriptConnection)

	table.insert(
		visual.connections,
		proxy:GetAttributeChangedSignal("SwingSerial"):Connect(function()
			self:_playSwing(visual)
		end)
	)
	table.insert(
		visual.connections,
		proxy:GetAttributeChangedSignal("Moving"):Connect(function()
			self:_setMoving(visual)
		end)
	)
	table.insert(
		visual.connections,
		proxy:GetAttributeChangedSignal("HitSerial"):Connect(function()
			self:_flash(visual)
		end)
	)
	table.insert(
		visual.connections,
		proxy.AncestryChanged:Connect(function()
			if not proxy:IsDescendantOf(workspace) then
				self:_remove(proxy)
			end
		end)
	)
	self:_ensureRendering()
end

function ShadowCloneController._remove(self: typeof(ShadowCloneController), proxy: Model)
	local visual = self._visuals[proxy]
	if not visual then
		return
	end
	self._visuals[proxy] = nil
	for _, connection in visual.connections do
		connection:Disconnect()
	end
	if visual.model.Parent then
		smokePuff(visual.root.Position)
		visual.model:Destroy()
	end
end

function ShadowCloneController._ensureRendering(self: typeof(ShadowCloneController))
	if self._render then
		return
	end
	self._render = RunService.RenderStepped:Connect(function(dt: number)
		local blend = 1 - math.exp(-FOLLOW_RATE * dt)
		local any = false
		for _, visual in self._visuals do
			any = true
			local goal = visual.proxyRoot.CFrame
			local current = visual.root.CFrame
			if (goal.Position - current.Position).Magnitude > SNAP_STUDS then
				visual.root.CFrame = goal
			else
				visual.root.CFrame = current:Lerp(goal, blend)
			end
		end
		if not any and self._render then
			self._render:Disconnect()
			self._render = nil
		end
	end)
end

function ShadowCloneController.Start(self: typeof(ShadowCloneController))
	task.spawn(function()
		local ignore = workspace:WaitForChild("IgnoreInstances")
		local folder = ignore:WaitForChild(FOLDER_NAME)
		for _, proxy in folder:GetChildren() do
			task.spawn(self._add, self, proxy)
		end
		folder.ChildAdded:Connect(function(proxy: Instance)
			self:_add(proxy)
		end)
	end)
end

return ShadowCloneController
