--!strict
--[[
	Eight Inner Gates, server side (2026-11-08): Runegrove's melee Epic.

	One press. The whole cast (`duration`) takes `flurryDamageReduction`
	less damage (DamageService:AddTimedReduction). After the gate flare and
	the lunge (the caster's client dashes, VFXController/EightInnerGates),
	`flurryHits` punches land over `flurrySeconds`: each hits every mob in a
	cone `coneLength` long and `coneAngle` wide ahead of the caster's
	CURRENT root for `damage` through VFXService's spell-hit path (Rank,
	crits, Arcane, relic procs; no knockback). Then the finisher hits the
	same cone for `finisherDamage` with the spell's knockback and camera
	shake. Every punch and the finisher also break the breakables in the
	cone's reach as spell hits (canBreakBuildings; Breakable.HitInRadius,
	each one once per cast; 2026-11-08).

	ON CAST (2026-11-08; after the finisher before) the gate opens: the
	character's Attributes.InnerGatesOpen is set for `gateSeconds` (this
	module is its one writer; RelicGimmickService/Blaze folds gateSwingSpeed
	into MeleeSwingSpeed and getEffectiveBaseWalkSpeed adds gateMoveSpeed),
	and the Enflamed aura is granted for the same `gateSeconds`
	(AuraService:SetAura: its rig, +30% Weapon Damage, a smooth fade out).
	A recast while open restarts both.
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
-- Mobs this close count as in the cone whatever the angle (point blank).
local POINT_BLANK = 4
-- When the first punch lands after the lunge ends (lets the dash replicate).
local AFTER_DASH = 0.1

-- [character] = the latest cast's token, so an older cast's timer never
-- closes a newer gate.
local gateTokens: { [Model]: number } = setmetatable({}, { __mode = "k" }) :: any

-- Every living mob in the cone ahead of `root` right now.
local function mobsInCone(root: BasePart, length: number, angle: number): { Model }
	local found: { Model } = {}
	local ignore = workspace:FindFirstChild("IgnoreInstances")
	local folder = ignore and ignore:FindFirstChild("Mobs")
	if not folder then
		return found
	end
	local look = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
	look = if look.Magnitude > 1e-3 then look.Unit else Vector3.zAxis
	local halfAngle = math.rad(angle / 2)
	for _, model in folder:GetChildren() do
		if not model:IsA("Model") then
			continue
		end
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		local mobRoot = model:FindFirstChild("HumanoidRootPart")
		if not humanoid or humanoid.Health <= 0 or not mobRoot or not mobRoot:IsA("BasePart") then
			continue
		end
		local flat = (mobRoot.Position - root.Position) * Vector3.new(1, 0, 1)
		local reach = flat.Magnitude - mobRoot.Size.X / 2
		if reach > length then
			continue
		end
		if flat.Magnitude > POINT_BLANK then
			local cos = flat.Unit:Dot(look)
			if math.acos(math.clamp(cos, -1, 1)) > halfAngle then
				continue
			end
		end
		table.insert(found, model)
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
	local damageService = Blitz.OptionalService("DamageService")
	if damageService then
		damageService:AddTimedReduction(player, SPELL, data.flurryDamageReduction or 0.5, data.duration or 1.8)
	end
	local gateSeconds = data.gateSeconds or 8
	openGate(character, gateSeconds)
	local auraService = Blitz.OptionalService("AuraService")
	if auraService then
		auraService:SetAura(player, AuraNames.Enflamed, character, gateSeconds)
	end

	local length = data.coneLength or 14
	local angle = data.coneAngle or 80
	local hits = data.flurryHits or 6
	local flurrySeconds = data.flurrySeconds or 0.6
	local start = (data.flareSeconds or 0.75) + (data.dashSeconds or 0.2) + AFTER_DASH
	local spacing = flurrySeconds / hits

	-- The flurry's own hit row: a small push (`punchKnockbackStuds`; a nil
	-- push fell back to every spell's 3 studs, 18 over the flurry, until
	-- 2026-11-08) and no per-punch shake.
	local punch = table.clone(data)
	punch.knockbackStuds = data.punchKnockbackStuds or 0.5
	punch.knockbackSlideSpeed = nil
	punch.cameraShake = false
	-- The finisher: its own damage, with the spell's knockback and shake.
	local finisher = table.clone(data)
	finisher.damage = data.finisherDamage or 120
	-- Breakables already broken by this cast.
	local brokenThisCast: { [Instance]: boolean } = {}

	local function strike(row: { [any]: any })
		if player.Character ~= character then
			return
		end
		local root = getRoot(character)
		if not root then
			return
		end
		local at = CFrame.new(root.Position)
		for _, model in mobsInCone(root, length, angle) do
			vfxService:_spellHit(model, at, player, SPELL, row)
		end
		if data.canBreakBuildings then
			-- A circle over the cone's reach, ahead of the caster.
			local look = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
			look = if look.Magnitude > 1e-3 then look.Unit else Vector3.zAxis
			local Breakable = (require :: any)(ServerScriptService.Components.Breakable)
			Breakable.HitInRadius(root.Position + look * (length / 2), length / 2, player, brokenThisCast, true)
		end
	end

	for index = 0, hits - 1 do
		GameClock.Delay(start + index * spacing, function()
			strike(punch)
		end)
	end
	GameClock.Delay(start + flurrySeconds, function()
		strike(finisher)
	end)
end
