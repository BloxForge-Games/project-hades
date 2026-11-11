--!strict
--[[
	Eight Inner Gates, server side (2026-11-08): Runegrove's melee Epic.

	One press (2026-11-09; a lunge into a 6-punch flurry and a finisher
	before). The caster is rooted (their client's walk speed claim) and
	invulnerable (InvulnerabilityService "Combat" window, the white
	highlight) for the whole cast (`duration`). After `chargeSeconds` the
	caster's client dashes them `dashStuds` forward (VFXController/
	EightInnerGates). Once the dash has landed and replicated, the first
	kick hits every mob along the path the root actually travelled
	(`pathWidth` wide, reaching `kickReach` past the end) for `damage`
	through VFXService's spell-hit path (Rank, crits, Arcane, relic procs)
	with a small push (`firstKickKnockbackStuds`), and breaks the breakables
	along the path as spell hits (canBreakBuildings; Breakable.HitInRadius).
	`secondKickDelay` later the second kick hits every mob within
	`secondKickRadius` of the landing and `kickReach` ahead of it for
	`damage` again, launched away from the dash's start with the camera
	shake (2026-11-09: a double kick).

	ON CAST the gate opens: the character's Attributes.InnerGatesOpen is
	set for `gateSeconds` (this module is its one writer;
	RelicGimmickService/Blaze folds gateSwingSpeed into MeleeSwingSpeed and
	getEffectiveBaseWalkSpeed adds gateMoveSpeed), and the Enflamed aura is
	granted for the same `gateSeconds` (AuraService:SetAura: its rig, a
	smooth fade out). A recast while open restarts both.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local ArcaneData = require(ReplicatedStorage.Submodules.Core.Shared.Data.ArcaneData)
local ArcaneNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ArcaneNames)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local AuraNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.AuraNames)
local Blitz = require(ReplicatedStorage.Submodules.Core.Shared.Blitz)
local GameClock = require(ReplicatedStorage.Submodules.Core.Shared.GameClock)
local getRoot = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Character.getRoot)

local SPELL = ArcaneNames["Eight Inner Gates"]
-- When the kick resolves after the dash ends (lets the dash replicate).
local AFTER_DASH = 0.1

-- [character] = the latest cast's token, so an older cast's timer never
-- closes a newer gate.
local gateTokens: { [Model]: number } = setmetatable({}, { __mode = "k" }) :: any

-- Every living mob within `halfWidth` (flat) of the segment `from`-`to`.
local function mobsAlongPath(from: Vector3, to: Vector3, halfWidth: number): { Model }
	local found: { Model } = {}
	local ignore = workspace:FindFirstChild("IgnoreInstances")
	local folder = ignore and ignore:FindFirstChild("Mobs")
	if not folder then
		return found
	end
	local a = Vector3.new(from.X, 0, from.Z)
	local segment = Vector3.new(to.X, 0, to.Z) - a
	local lengthSq = segment:Dot(segment)
	for _, model in folder:GetChildren() do
		if not model:IsA("Model") then
			continue
		end
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		local mobRoot = model:FindFirstChild("HumanoidRootPart")
		if not humanoid or humanoid.Health <= 0 or not mobRoot or not mobRoot:IsA("BasePart") then
			continue
		end
		local p = Vector3.new(mobRoot.Position.X, 0, mobRoot.Position.Z)
		local t = if lengthSq > 1e-6 then math.clamp((p - a):Dot(segment) / lengthSq, 0, 1) else 0
		local gap = (p - (a + segment * t)).Magnitude - mobRoot.Size.X / 2
		if gap <= halfWidth then
			table.insert(found, model)
		end
	end
	return found
end

local function openGate(character: Model, seconds: number)
	local token = (gateTokens[character] or 0) + 1
	gateTokens[character] = token
	character:SetAttribute(Attributes.InnerGatesOpen, true)
	GameClock.Delay(seconds, function()
		if gateTokens[character] == token and character.Parent then
			character:SetAttribute(Attributes.InnerGatesOpen, nil)
		end
	end)
end

return function(vfxService: any, player: Player, _cframe: CFrame)
	local data = ArcaneData[SPELL]
	local character = player.Character
	if not character then
		return
	end
	local invulnerability = Blitz.OptionalService("InvulnerabilityService")
	if invulnerability then
		invulnerability:ApplyTo(character, data.duration or 1.8, "Combat")
	end
	local gateSeconds = data.gateSeconds or 10
	openGate(character, gateSeconds)
	local auraService = Blitz.OptionalService("AuraService")
	if auraService then
		auraService:SetAura(player, AuraNames.Enflamed, character, gateSeconds)
	end

	local chargeSeconds = data.chargeSeconds or 1
	local halfWidth = (data.pathWidth or 10) / 2
	local kickReach = data.kickReach or 5
	-- Where the dash starts: the root when the charge ends.
	local startPosition: Vector3? = nil
	GameClock.Delay(chargeSeconds, function()
		local root = getRoot(character)
		startPosition = root and root.Position
	end)

	GameClock.Delay(chargeSeconds + (data.dashSeconds or 0.25) + AFTER_DASH, function()
		if player.Character ~= character then
			return
		end
		local root = getRoot(character)
		if not root then
			return
		end
		local look = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
		look = if look.Magnitude > 1e-3 then look.Unit else Vector3.zAxis
		local from = startPosition or root.Position
		local to = root.Position + look * kickReach
		-- Pushed away from the dash's start (along and out of the path).
		local at = CFrame.new(from)
		local firstKick = table.clone(data)
		firstKick.knockbackStuds = data.firstKickKnockbackStuds or 1
		firstKick.knockbackSlideSpeed = nil
		firstKick.cameraShake = false
		for _, model in mobsAlongPath(from, to, halfWidth) do
			vfxService:_spellHit(model, at, player, SPELL, firstKick)
		end

		-- The second kick: around and ahead of the landing, the launch.
		GameClock.Delay(data.secondKickDelay or 0.25, function()
			if player.Character ~= character then
				return
			end
			local liveRoot = getRoot(character)
			if not liveRoot then
				return
			end
			local landing = liveRoot.Position
			for _, model in mobsAlongPath(landing, landing + look * kickReach, data.secondKickRadius or 9) do
				vfxService:_spellHit(model, at, player, SPELL, data)
			end
		end)
		if data.canBreakBuildings then
			-- Circles strung along the path.
			local Breakable = (require :: any)(ServerScriptService.Components.Breakable)
			local seen: { [Instance]: boolean } = {}
			local span = (to - from) * Vector3.new(1, 0, 1)
			local steps = math.max(1, math.ceil(span.Magnitude / halfWidth))
			for step = 0, steps do
				Breakable.HitInRadius(from + span * (step / steps), halfWidth, player, seen, true)
			end
		end
	end)
end
