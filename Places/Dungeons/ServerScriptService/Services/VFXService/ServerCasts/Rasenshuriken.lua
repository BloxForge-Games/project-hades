--!strict
--[[
	Rasenshuriken, server side (PROTOTYPE, 2026-11-07).

	THROW: a marker part flies down the caster's facing at `throwSpeed`
	and detonates on the first mob it reaches (within `contactRadius`), a
	wall, or at `throwDistance`.
	VORTEX: for `vortexSeconds` it holds there; every `tickSeconds` each mob
	within `pullRadius` takes `tickDamage` and is DRAWN toward the centre
	(MobSimService:Carry at `pullSpeed`, so it slides in smoothly). A mob
	the vortex catches is HELD until the vortex ends (MobSimService:Hold):
	no chasing, no attacking, no turning between pulls or once it reaches
	the centre, so it never fights the pull (2026-11-07).
	BURST: it ends in a blast for `damage` on everything within
	`pullRadius`, which throws them back out `burstKnockback` studs. The
	burst also breaks what is in `pullRadius` (pots, veins, props;
	VFXService's shared hitbox, 2026-11-08: it never touched them).

	Every hit is the spell-hit path (Arcane Rank, crits, Arcane bonuses).
	Minibosses and bosses take the damage but are never drawn in.

	The marker (workspace.IgnoreInstances.ArcaneSpells, "Rasenshuriken")
	is what every client draws on (VFXController Rasenshuriken): OwnerId
	says whose, Phase is "Flying", "Vortex" or "Burst".
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local ArcaneData = require(ReplicatedStorage.Submodules.Core.Shared.Data.ArcaneData)
local ArcaneNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ArcaneNames)
local Blitz = require(ReplicatedStorage.Submodules.Core.Shared.Blitz)
local GameClock = require(ReplicatedStorage.Submodules.Core.Shared.GameClock)
local isEncounterEnemy = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Mob.isEncounterEnemy)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local IgnoreListService = require(ServerScriptService.Submodules.Core.Source.Services.IgnoreListService)

local SPELL = ArcaneNames.Rasenshuriken
local STEP_SECONDS = 0.03
-- Mobs closer to the centre than this are left where they are.
local PULL_HOLD_STUDS = 2
-- How long the marker lingers after the burst, for the clients' blast.
local BURST_LINGER = 0.4
-- A caught mob stays held this long past the burst, so it lands its
-- knockback before it acts again.
local HOLD_PAST_BURST = 0.2

type Mob = { model: Model, humanoid: Humanoid, root: BasePart }

local function livingMobs(): { Mob }
	local result = {}
	local ignore = workspace:FindFirstChild("IgnoreInstances")
	local folder = ignore and ignore:FindFirstChild("Mobs")
	if not folder then
		return result
	end
	for _, model in folder:GetChildren() do
		if not model:IsA("Model") then
			continue
		end
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		local root = model:FindFirstChild("HumanoidRootPart")
		if humanoid and humanoid.Health > 0 and root and root:IsA("BasePart") then
			table.insert(result, { model = model, humanoid = humanoid, root = root })
		end
	end
	return result
end

local function flat(vector: Vector3): Vector3
	return Vector3.new(vector.X, 0, vector.Z)
end

local function wallParams(): RaycastParams
	local params = RaycastParams.new()
	local ignore = workspace:FindFirstChild("IgnoreInstances")
	local map = ignore and ignore:FindFirstChild("Map")
	local rooms = map and map:FindFirstChild("DungeonRooms")
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = if rooms then { rooms } else {}
	return params
end

return function(vfxService: any, player: Player, cframe: CFrame)
	local data = ArcaneData[SPELL]
	local look = flat(cframe.LookVector)
	look = if look.Magnitude > 0.01 then look.Unit else Vector3.zAxis
	local start = cframe.Position + look * 2
	local throwSpeed = math.max(data.throwSpeed or 50, 1)
	local throwDistance = data.throwDistance or 30
	local contactRadius = data.contactRadius or 3
	local pullRadius = data.pullRadius or 12
	local pullSpeed = data.pullSpeed or 14
	local tickSeconds = data.tickSeconds or 0.25
	local vortexSeconds = data.vortexSeconds or 1.5

	local folderParent = workspace:FindFirstChild("IgnoreInstances")
	local folder = folderParent and folderParent:FindFirstChild("ArcaneSpells") or folderParent or workspace
	local marker = Instance.new("Part")
	marker.Name = "Rasenshuriken"
	marker.Size = Vector3.one
	marker.Transparency = 1
	marker.Anchored = true
	marker.CanCollide = false
	marker.CanQuery = false
	marker.CanTouch = false
	marker.CFrame = CFrame.lookAt(start, start + look)
	marker:SetAttribute("OwnerId", player.UserId)
	marker:SetAttribute("Phase", "Flying")
	marker.Parent = folder

	-- The tick and the burst share the spell's card, each with its own
	-- damage and push.
	local tickCard = table.clone(data)
	tickCard.damage = data.tickDamage or 20
	tickCard.knockbackStuds = 0
	local burstCard = table.clone(data)
	burstCard.knockbackStuds = data.burstKnockback or 8

	task.spawn(function()
		-- THROW
		local params = wallParams()
		local travelled = 0
		local position = start
		local last = GameClock.Now()
		while travelled < throwDistance and player.Parent and marker.Parent do
			GameClock.Wait(STEP_SECONDS)
			local now = GameClock.Now()
			local step = math.min(throwSpeed * (now - last), throwDistance - travelled)
			last = now
			local wall = workspace:Raycast(position, look * step, params)
			if wall then
				position = wall.Position - look * 1
				break
			end
			position += look * step
			travelled += step
			marker.CFrame = CFrame.lookAt(position, position + look)
			local touched = false
			for _, mob in livingMobs() do
				local gap = flat(mob.root.Position - position).Magnitude - mob.root.Size.X / 2
				if gap <= contactRadius then
					touched = true
					break
				end
			end
			if touched then
				break
			end
		end
		if not marker.Parent then
			return
		end

		-- VORTEX
		marker.CFrame = CFrame.lookAt(position, position + look)
		marker:SetAttribute("Phase", "Vortex")
		local mobSim = Blitz.OptionalService("MobSimService")
		local center = position
		local ticks = math.max(math.floor(vortexSeconds / tickSeconds + 0.5), 1)
		local vortexEnds = GameClock.Now() + ticks * tickSeconds
		local held: { [Model]: boolean } = {}
		for _ = 1, ticks do
			if not player.Parent or not marker.Parent then
				break
			end
			for _, mob in livingMobs() do
				local toCenter = flat(center - mob.root.Position)
				local gap = toCenter.Magnitude - mob.root.Size.X / 2
				if gap > pullRadius then
					continue
				end
				vfxService:_spellHit(mob.model, CFrame.new(center), player, SPELL, tickCard)
				local pullable = mobSim ~= nil and mob.humanoid.Health > 0 and not isEncounterEnemy(mob.model)
				-- Caught: held for the rest of the vortex (to just past the
				-- burst, which throws it out).
				-- A mob mid-attack is not held (magic never cancels an
				-- attack); the next tick catches it once it has finished.
				if
					mobSim
					and pullable
					and not held[mob.model]
					and mobSim:Hold(mob.model, math.max(vortexEnds - GameClock.Now(), 0) + HOLD_PAST_BURST)
				then
					held[mob.model] = true
				end
				if mobSim and pullable and toCenter.Magnitude > PULL_HOLD_STUDS then
					-- Slightly longer than a tick, so each leg runs into the next.
					local pull = math.min(toCenter.Magnitude - PULL_HOLD_STUDS, pullSpeed * tickSeconds * 1.15)
					mobSim:Carry(mob.model, toCenter.Unit, pull, pullSpeed)
				end
			end
			GameClock.Wait(tickSeconds)
		end
		if not marker.Parent then
			return
		end

		-- BURST
		marker:SetAttribute("Phase", "Burst")
		for _, mob in livingMobs() do
			local gap = flat(mob.root.Position - center).Magnitude - mob.root.Size.X / 2
			if gap <= pullRadius then
				vfxService:_spellHit(mob.model, CFrame.new(center), player, SPELL, burstCard)
			end
		end
		-- The breakables: VFXService's shared hitbox owns them (loot
		-- breakables, and props / gates through canBreakBuildings). The mobs
		-- were just hit above, so its mob callback does nothing. A fresh
		-- registry per burst, or a pot from the last cast is skipped.
		local registry = vfxService._playerDetectedPartsRegistry[player.UserId]
		if registry then
			registry[SPELL] = nil
		end
		vfxService:CreateHitbox(
			SPELL,
			player,
			CFrame.new(center),
			TagList.Zombie,
			IgnoreListService:GetWeaponIgnoreList(),
			function(_model: Model) end,
			pullRadius,
			true
		)
		GameClock.Debris(marker, BURST_LINGER)
	end)
end
