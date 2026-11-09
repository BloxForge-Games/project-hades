--!strict
--[[
	Module: Controllers/RelicShotVFXController.lua
	Description:
	The ranged relics' own shots (2026-11-04; the server half is
	RelicGimmickService/Lib/relicShots). Each is fired WITH the gun shot
	that set its relic off, from the same muzzle and aim, on the same ARC
	the server flies (From, launch velocity To - From, and
	RelicTriggerData.Shot.Gravity) -- no homing -- until the server says
	where it landed:

	  PaintballShot   Magenta Paintball Gun: the Ice Arrow's pieces in pink
	                  (2026-11-05).
	  IceArrowShot    Frozen Blue Ice Crossbow: the Ice Arrow prefab
	                  (GameAssets.VFX.IceArrow: Release at the muzzle, the
	                  Arrow in flight, Impact where it lands).
	  VolleyballShot  Volleyball: the relic's own ball model, with the
	                  GameAssets.VFX.Volleyball Release at the muzzle and
	                  Impact where it lands.
	  BrewShot        Witches Brew: a green potion (the burst and puddle
	                  where it lands are the server's own effects).
	  RelicShotEnd    where a shot landed: it stops there and plays its end.

	A launch and its end share an id (the payload's Radius) per caster. A
	shot whose end never arrives stops after its Duration.

	FACING. The Ice Arrow and Volleyball prefabs look down their part's -Z,
	like a bullet
	(CFrame.new(from, to)), so CFrame.lookAt along the flight needs no
	correction.

	Game time throughout, so slow motion slows it. A Blitz module with no
	dependencies.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local GameClock = require(ReplicatedStorage.Submodules.Core.Shared.GameClock)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local emitVFXPart = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.emitVFXPart)
local getRelicModelTemplate = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Relic.getRelicModelTemplate)
local RelicTriggerData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicTriggerData)
local WeaponData = require(ReplicatedStorage.Submodules.Core.Shared.Data.WeaponData)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local Blitz = require(ReplicatedStorage.Submodules.Core.Shared.Blitz)
local relicProcColors = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.relicProcColors)
local resolveAnimation = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Weapon.resolveAnimation)

local ICE_ARROW_FOLDER = "IceArrow"
local ICE_RELEASE_VFX = ICE_ARROW_FOLDER .. "/Release"
local ICE_IMPACT_VFX = ICE_ARROW_FOLDER .. "/Impact"
local VOLLEYBALL_RELEASE_VFX = "Volleyball/Release"
local VOLLEYBALL_IMPACT_VFX = "Volleyball/Impact"
-- Magenta Paintball Gun's colour: the Ice Arrow's pieces, painted.
local PAINTBALL_COLOR = Color3.fromRGB(255, 60, 200)
local POTION_SIZE = 1.1
local BALL_FADE_SECONDS = 0.25
-- How long a landed shot stays for its trails and loose particles.
local CLEANUP_SECONDS = 1
-- The shooter's second draw for a relic shot that leaves after the
-- weapon's own (the double shot, 2026-11-05): which of the weapon's attack
-- animations, how fast, and its blend in.
local DOUBLE_SHOT_ANIMATION_INDEX = 1
local DOUBLE_SHOT_SPEED = 1.4
local DOUBLE_SHOT_FADE_SECONDS = 0.08

-- One loaded track per animation, per Animator.
local doubleShotTracks: { [Animator]: { [string]: AnimationTrack } } = setmetatable({}, { __mode = "k" }) :: any

-- The LOCAL player's double shot: one of their held ranged weapon's attack
-- animations (shootAnimations, or its single shootAnimation) played again
-- as the relic shot leaves. Played on the owner's client, it replicates to
-- everyone like any character animation.
local function playDoubleShot()
	local character = Players.LocalPlayer.Character
	local weaponName = character and character:GetAttribute(Attributes.EquippedWeapon)
	local data: any = if type(weaponName) == "string" then WeaponData[weaponName] else nil
	if not data then
		return
	end
	local list = data.shootAnimations
	local nameOrId = if type(list) == "table" and #list > 0
		then list[math.min(DOUBLE_SHOT_ANIMATION_INDEX, #list)]
		else data.shootAnimation
	local animation = resolveAnimation(nameOrId)
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	if not animation or not animator then
		return
	end
	local tracks: { [string]: AnimationTrack } = doubleShotTracks[animator] or {}
	doubleShotTracks[animator] = tracks
	local track: AnimationTrack = tracks[animation.AnimationId] or animator:LoadAnimation(animation)
	if not tracks[animation.AnimationId] then
		track.Priority = Enum.AnimationPriority.Action2
		tracks[animation.AnimationId] = track
	end
	track:Play(DOUBLE_SHOT_FADE_SECONDS)
	GameClock.SetAnimationSpeed(track, DOUBLE_SHOT_SPEED)
end

type Payload = {
	Kind: string,
	Caster: Player?,
	From: Vector3,
	To: Vector3,
	Radius: number,
	Duration: number,
	StartTime: number,
}

type Shot = {
	kind: string,
	visual: Instance,
	-- Moves the visual to a CFrame.
	place: (cframe: CFrame) -> (),
	origin: Vector3,
	velocity: Vector3,
	gravity: Vector3,
	-- The flight's flat heading, for the end check.
	heading: Vector3,
	direction: Vector3,
	startedAt: number,
	maxSeconds: number,
	landedAt: Vector3?,
	done: boolean,
}

local RelicShotVFXController = {
	Name = "RelicShotVFXController",
}

local shots: { [string]: Shot } = {}

local function keyOf(caster: Player?, id: number): string
	return (if caster then tostring(caster.UserId) else "?") .. ":" .. tostring(math.round(id))
end

local function effectParent(): Instance
	local ignore = workspace:FindFirstChild("IgnoreInstances")
	return (ignore and ignore:FindFirstChild("ArcaneSpells")) or ignore or workspace
end

local function quiet(part: BasePart)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
end

-- The Ice Arrow's in-flight part, ready to fly.
local function makeArrow(): BasePart?
	local gameAssets = ReplicatedStorage:FindFirstChild("GameAssets")
	local vfx = gameAssets and gameAssets:FindFirstChild("VFX")
	local folder = vfx and vfx:FindFirstChild(ICE_ARROW_FOLDER)
	local template = folder and folder:FindFirstChild("Arrow")
	if not (template and template:IsA("BasePart")) then
		warn("[RelicShotVFXController] Missing GameAssets.VFX.IceArrow.Arrow")
		return nil
	end
	local arrow = template:Clone()
	quiet(arrow)
	for _, descendant in arrow:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			descendant.Massless = true
		end
	end
	return arrow
end

-- The Volleyball relic's model, its pickup sparkle removed.
local function makeBall(): Model?
	local template = getRelicModelTemplate(RelicNames.Volleyball)
	if not (template and template:IsA("Model")) then
		warn("[RelicShotVFXController] No model for Volleyball under GameAssets.Relics")
		return nil
	end
	local ball = template:Clone()
	local primary = ball.PrimaryPart
	local sparkle = primary and primary:FindFirstChild("RelicParticleAttachment")
	if sparkle then
		sparkle:Destroy()
	end
	for _, descendant in ball:GetDescendants() do
		if descendant:IsA("BasePart") then
			quiet(descendant)
		end
	end
	return ball
end

-- Poison's green, or Death Venom's purple for its caster (relicProcColors).
local function makePotion(caster: Player?): BasePart
	local relicController = Blitz.OptionalController("RelicController")
	local relics = caster and relicController and relicController:GetRelicsFromUserId(caster.UserId)
	local potion = Instance.new("Part")
	potion.Name = "BrewShot"
	potion.Shape = Enum.PartType.Ball
	potion.Size = Vector3.one * POTION_SIZE
	potion.Color = relicProcColors.poison(relics)
	potion.Material = Enum.Material.Neon
	potion.Transparency = 0.25
	potion.CastShadow = false
	quiet(potion)
	return potion
end

local function ballEmitters(ball: Model): { ParticleEmitter }
	local list = {}
	local primary = ball.PrimaryPart
	local active = primary and primary:FindFirstChild("ActiveAttachment")
	if active then
		for _, child in active:GetChildren() do
			if child:IsA("ParticleEmitter") then
				table.insert(list, child)
			end
		end
	end
	return list
end

-- The shot's end where it landed (or ran out), then its cleanup.
local function finish(shot: Shot, position: Vector3)
	shot.done = true
	local visual = shot.visual
	local facing = CFrame.lookAt(position, position + shot.direction)
	shot.place(facing)
	if (shot.kind == "IceArrowShot" or shot.kind == "PaintballShot") and visual:IsA("BasePart") then
		emitVFXPart(
			ICE_IMPACT_VFX,
			facing,
			nil,
			if shot.kind == "PaintballShot" then { Color = PAINTBALL_COLOR } else nil
		)
		for _, descendant in visual:GetDescendants() do
			if descendant:IsA("ParticleEmitter") then
				descendant.Enabled = false
				if descendant.LockedToPart then
					descendant:Clear()
				end
			elseif descendant:IsA("Trail") then
				descendant.Enabled = false
			end
		end
	elseif shot.kind == "VolleyballShot" and visual:IsA("Model") then
		emitVFXPart(VOLLEYBALL_IMPACT_VFX, facing)
		for _, emitter in ballEmitters(visual) do
			emitter:Emit(5)
		end
		local sounds = ReplicatedStorage:FindFirstChild("GameAssets")
		local sound = sounds and sounds:FindFirstChild("Sounds") and sounds.Sounds:FindFirstChild("Volleyball")
		if sound and sound:IsA("Sound") and visual.PrimaryPart then
			local clone = sound:Clone()
			clone.Parent = visual.PrimaryPart
			clone.TimePosition = 0.2
			clone:Play()
		end
		for _, descendant in visual:GetDescendants() do
			if descendant:IsA("BasePart") then
				GameClock.Tween(descendant, TweenInfo.new(BALL_FADE_SECONDS, Enum.EasingStyle.Cubic), {
					Transparency = 1,
				}):Play()
			end
		end
	elseif visual:IsA("BasePart") then
		visual.Transparency = 1
	end
	GameClock.Debris(visual, CLEANUP_SECONDS)
end

-- Where an arc is `t` seconds in, and which way it is heading.
local function arcAt(origin: Vector3, velocity: Vector3, gravity: Vector3, t: number): (Vector3, Vector3)
	return origin + velocity * t + gravity * (0.5 * t * t), velocity + gravity * t
end

-- The gravity a shot flies under: an Ice Arrow from a caster holding a
-- ballisticAim weapon follows that weapon's arc (its drop; relicShots
-- follow, 2026-11-05); everything else the relic shots' own.
local function gravityFor(payload: Payload): number
	if (payload.Kind == "IceArrowShot" or payload.Kind == "PaintballShot") and payload.Caster then
		local character = payload.Caster.Character
		local weaponName = character and character:GetAttribute(Attributes.EquippedWeapon)
		local weapon = if type(weaponName) == "string" then WeaponData[weaponName] else nil
		if weapon and weapon.ballisticAim == true and tonumber(weapon.drop) then
			return tonumber(weapon.drop) :: number
		end
	end
	return RelicTriggerData.Shot.Gravity
end

local function flat(vector: Vector3): Vector3
	return Vector3.new(vector.X, 0, vector.Z)
end

-- The Paintball's second draw (Neutral's PaintballDraw): the shooter's own
-- client plays it `delay` seconds after the shot that set it off, so its
-- release meets the Paintball leaving (2026-11-08).
function RelicShotVFXController.DoubleShot(_self: typeof(RelicShotVFXController), caster: Player?, delay: number)
	if caster ~= Players.LocalPlayer then
		return
	end
	if delay > 0 then
		GameClock.Delay(delay, playDoubleShot)
	else
		playDoubleShot()
	end
end

function RelicShotVFXController.Launch(_self: typeof(RelicShotVFXController), payload: Payload)
	local velocity = payload.To - payload.From
	if velocity.Magnitude < 1e-3 or payload.Duration <= 0 then
		return
	end
	local direction = velocity
	local origin = payload.From
	local facing = CFrame.lookAt(origin, origin + direction)

	local visual: Instance? = nil
	local place: ((CFrame) -> ())? = nil
	if payload.Kind == "IceArrowShot" or payload.Kind == "PaintballShot" then
		local painted = payload.Kind == "PaintballShot"
		-- (The Paintball's draw plays ahead of it: DoubleShot, 2026-11-08.)
		local arrow = makeArrow()
		if arrow then
			emitVFXPart(ICE_RELEASE_VFX, facing, nil, if painted then { Color = PAINTBALL_COLOR } else nil)
			if painted then
				local paint = ColorSequence.new(PAINTBALL_COLOR)
				for _, descendant in arrow:GetDescendants() do
					if descendant:IsA("ParticleEmitter") or descendant:IsA("Trail") or descendant:IsA("Beam") then
						(descendant :: any).Color = paint
					elseif descendant:IsA("BasePart") then
						descendant.Color = PAINTBALL_COLOR
					end
				end
			end
			arrow.CFrame = facing
			arrow.Parent = effectParent()
			for _, descendant in arrow:GetDescendants() do
				if descendant:IsA("ParticleEmitter") then
					local count = descendant:GetAttribute("EmitCount")
					if typeof(count) == "number" and count > 0 then
						descendant:Emit(count)
					end
				elseif descendant:IsA("Trail") then
					descendant.Enabled = true
				end
			end
			visual = arrow
			place = function(cframe: CFrame)
				arrow.CFrame = cframe
			end
		end
	elseif payload.Kind == "VolleyballShot" then
		local ball = makeBall()
		if ball then
			emitVFXPart(VOLLEYBALL_RELEASE_VFX, facing)
			ball:PivotTo(facing)
			ball.Parent = effectParent()
			for _, emitter in ballEmitters(ball) do
				emitter.Enabled = false
				emitter:Emit(5)
			end
			visual = ball
			place = function(cframe: CFrame)
				ball:PivotTo(cframe)
			end
		end
	elseif payload.Kind == "BrewShot" then
		local potion = makePotion(payload.Caster)
		potion.CFrame = facing
		potion.Parent = effectParent()
		visual = potion
		place = function(cframe: CFrame)
			potion.CFrame = cframe
		end
	end
	if not visual or not place then
		return
	end

	local shot: Shot = {
		kind = payload.Kind,
		visual = visual,
		place = place,
		origin = origin,
		velocity = velocity,
		gravity = Vector3.new(0, -gravityFor(payload), 0),
		heading = if flat(velocity).Magnitude > 1e-3 then flat(velocity).Unit else Vector3.zero,
		direction = velocity.Unit,
		startedAt = GameClock.Now(),
		maxSeconds = payload.Duration,
		landedAt = nil,
		done = false,
	}
	local key = keyOf(payload.Caster, payload.Radius)
	shots[key] = shot

	task.spawn(function()
		while not shot.done and visual.Parent do
			RunService.RenderStepped:Wait()
			local elapsed = math.min(GameClock.Now() - shot.startedAt, shot.maxSeconds)
			local position, heading = arcAt(shot.origin, shot.velocity, shot.gravity, elapsed)
			if heading.Magnitude > 1e-3 then
				shot.direction = heading.Unit
			end
			local landedAt = shot.landedAt
			if landedAt then
				-- Stop once it has come as far (along the ground) as the spot
				-- the server says it hit; a shot fired straight up or down
				-- stops on the next frame.
				local reached = (position - shot.origin):Dot(shot.heading)
				local target = (landedAt - shot.origin):Dot(shot.heading)
				if shot.heading == Vector3.zero or reached >= target then
					finish(shot, landedAt)
					break
				end
			end
			shot.place(CFrame.lookAt(position, position + shot.direction))
			if elapsed >= shot.maxSeconds then
				finish(shot, position)
				break
			end
		end
		if shots[key] == shot then
			shots[key] = nil
		end
	end)
end

-- Where a shot landed: it flies on to that spot and stops there.
function RelicShotVFXController.Land(_self: typeof(RelicShotVFXController), payload: Payload)
	local shot = shots[keyOf(payload.Caster, payload.Radius)]
	if shot and not shot.done then
		shot.landedAt = payload.From
	end
end

return RelicShotVFXController
