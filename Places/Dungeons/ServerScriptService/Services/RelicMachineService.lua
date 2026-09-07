--[[
     Author(s): 
     Module: RelicMachineService.lua
     Description:
]]

--[ Roblox Services ]--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

--[ Exports & Types & Defaults ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local RoomTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RoomTypes)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local findFloorBelow = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Dungeon.findFloorBelow)
local DungeonService

local RelicMachineService = Knit.CreateService({
	Name = "RelicMachineService",
	Client = {},
})

--[ Imports ]--

--[ Constants ]--

-- Studs in front of the player the machine lands, along their own facing.
-- Close: the machine faces THEM (see DropModelOnPlayer), so a player who
-- does not move has it squarely in front of them.
local FORWARD_OFFSET = 4
-- Extra clearance kept between the machine's footprint and the floor edge,
-- so a clamped machine never overhangs the lip of the slab.
local FLOOR_EDGE_MARGIN = 1.5
local LANDING_STEPS = 4 -- closer points to try when the forward point is not over floor
local DROP_HEIGHT = 25 -- studs above the landing position where the fall starts
local FALL_DURATION = 0.45 -- seconds for the fall animation
local RAYCAST_HEIGHT = 50 -- how far up from the player we start the ground raycast
local RAYCAST_DEPTH = 200 -- max studs to search downward for ground

--[ Properties ]--

--[ Private Functions ]--

-- Raycasts straight down to find the floor of the dungeon chunk in front of
-- the player. Only the active dungeon's rooms are queried, so we ignore the
-- mob crowd, decoration parts, and other accidental hits.
-- FLOOR-only ground find (findFloorBelow): a wall / gate / prop top under
-- the point returns nil, never a Y -- so the machine can never settle up on
-- a wall where nobody can reach it.
function RelicMachineService:_findGroundY(originXZ: Vector3): number?
	local hit = findFloorBelow(originXZ.X, originXZ.Z, originXZ.Y + RAYCAST_HEIGHT, RAYCAST_DEPTH)
	return hit and hit.Y or nil
end

-- Clamps `position` inside `floorPart`'s XZ footprint, inset by the machine's
-- own half-width plus FLOOR_EDGE_MARGIN. Works in the part's LOCAL space, so
-- a rotated or non-axis-aligned slab clamps correctly instead of against a
-- world-axis box. A slab too small to fit the machine collapses to its
-- centre rather than producing an inverted range.
local function clampToFloorBounds(floorPart: BasePart, position: Vector3, footprintRadius: number): Vector3
	local localPoint = floorPart.CFrame:PointToObjectSpace(position)
	local halfX = math.max((floorPart.Size.X / 2) - footprintRadius, 0)
	local halfZ = math.max((floorPart.Size.Z / 2) - footprintRadius, 0)
	return floorPart.CFrame:PointToWorldSpace(
		Vector3.new(math.clamp(localPoint.X, -halfX, halfX), localPoint.Y, math.clamp(localPoint.Z, -halfZ, halfZ))
	)
end

-- Landing spot for a machine dropped on `hrp`, guaranteed IN BOUNDS:
--   1. Find the Floor slab the player is actually standing on. That slab
--      defines "this chunk's floor" -- the player is on it by definition, so
--      it can never be a neighbouring room or the void.
--   2. Aim FORWARD_OFFSET studs ahead of them, then CLAMP that point inside
--      the slab (inset by the machine's footprint). Previously the forward
--      point was only walked backwards until *some* floor was under it,
--      which could still land on a different chunk's slab, or -- past a
--      room edge -- on nothing at all.
--   3. Re-verify the clamped point (a slab with a hole in it, or a prop
--      sitting on top, would still fail the Floor test) and fall back to the
--      player's own feet, which are on floor by definition.
-- Returns (position, groundY, floorPart).
function RelicMachineService:_pickMachineLanding(hrp: BasePart, footprintRadius: number): (Vector3, number, BasePart?)
	local feetY = hrp.Position.Y - (hrp.Size.Y / 2) - 2
	local _, standingFloor =
		findFloorBelow(hrp.Position.X, hrp.Position.Z, hrp.Position.Y + RAYCAST_HEIGHT, RAYCAST_DEPTH)

	if not standingFloor then
		-- Not over a Floor at all (mid-jump over a gap, off-grid spawn).
		-- Fall back to the old step-back walk rather than dropping nothing.
		local look = hrp.CFrame.LookVector
		local step = FORWARD_OFFSET / LANDING_STEPS
		for i = LANDING_STEPS, 0, -1 do
			local candidate = hrp.Position + look * (step * i)
			local groundY = self:_findGroundY(candidate)
			if groundY then
				return candidate, groundY, nil
			end
		end
		return hrp.Position, feetY, nil
	end

	local desired = hrp.Position + (hrp.CFrame.LookVector * FORWARD_OFFSET)
	local clamped = clampToFloorBounds(standingFloor, desired, footprintRadius + FLOOR_EDGE_MARGIN)

	local groundY = self:_findGroundY(clamped)
	if groundY then
		return clamped, groundY, standingFloor
	end

	-- Clamped point is over a hole / prop. The player's own position is on
	-- this slab, so use that.
	local ownGroundY = self:_findGroundY(hrp.Position)
	return hrp.Position, ownGroundY or feetY, standingFloor
end

-- Drives the model from `startCFrame` to `endCFrame` via PivotTo so anchored
-- multi-part assemblies move as one. Stops if the model is gone.
function RelicMachineService:_animateFall(model: Model, startCFrame: CFrame, endCFrame: CFrame, duration: number)
	local startTime = tick()
	local connection
	connection = RunService.Heartbeat:Connect(function()
		if not model.Parent then
			connection:Disconnect()
			return
		end

		local elapsed = tick() - startTime
		local alpha = math.min(elapsed / duration, 1)
		local easedAlpha = TweenService:GetValue(alpha, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

		model:PivotTo(startCFrame:Lerp(endCFrame, easedAlpha))

		if alpha >= 1 then
			connection:Disconnect()
		end
	end)
end

--[ Public Functions ]--

-- `isStarter` marks the RUN'S FIRST machine for this player. The machine
-- component reads it to force one ungated relic from each of the run's
-- two elements, so neither element starts dead. DungeonService passes it
-- on the first dungeon's landing; every other drop leaves it false.
function RelicMachineService:DropMachineOnPlayer(player: Player, isRuneMachine: boolean?, isStarter: boolean?)
	-- Skip dead / spectating players. The two callers in KnitStart iterate
	-- Players:GetPlayers() raw, so a teammate who died last room would
	-- otherwise get a vending machine dropped onto their ragdoll's HRP
	-- (or the previous-life HRP that's still parented). QA saw both
	-- visual glitches and a wasted spawn against a player who couldn't
	-- interact anyway.
	local character = player.Character
	if not character or character:GetAttribute(Attributes.Death) == true then
		return
	end

	-- Rune machines get their own authored model; everything downstream
	-- (fall animation, prompt, machine component) is shape-identical, so
	-- ONLY the template differs. Falls back to Default if the Rune model
	-- hasn't been published to this place yet.
	local machinesFolder = ReplicatedStorage.GameAssets.VendingMachines
	local template = if isRuneMachine then machinesFolder:FindFirstChild("Rune") else nil
	if isRuneMachine and not template then
		warn("[RelicMachineService] Missing GameAssets.VendingMachines.Rune -- using Default")
	end
	local vendingMachine = (template or machinesFolder.Default):Clone()

	vendingMachine:SetAttribute("OwnerId", player.UserId)
	-- The machine component reads this to decide WHAT it dispenses.
	vendingMachine:SetAttribute("MachineType", if isRuneMachine then "Rune" else "Relic")
	vendingMachine:SetAttribute("IsStarterMachine", isStarter == true)

	if not self:DropModelOnPlayer(player, vendingMachine, workspace.IgnoreInstances.Map.RelicMachines) then
		vendingMachine:Destroy()
	end
end

-- Drops ANY model out of the sky onto the floor just in front of `player`,
-- facing them, and runs the fall.
-- Extracted from DropMachineOnPlayer so the encounter chests
-- (EncounterChestService) land with the identical feel rather than a
-- second copy of the placement maths — the floor clamp alone is ~60 lines
-- of edge cases (rotated slabs, ledges, neighbouring chunks).
--
-- Set every attribute the model's component needs BEFORE calling: this
-- parents it, and a component mounts the moment it does.
--
-- `onLanded` fires once the fall completes, for whatever impact flourish
-- the model wants. Returns false (having touched nothing) when the drop
-- cannot be placed, so the caller owns cleanup of its own clone.
function RelicMachineService:DropModelOnPlayer(
	player: Player,
	model: Model,
	parent: Instance,
	onLanded: (() -> ())?
): boolean
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not hrp or not model.PrimaryPart then
		return false
	end

	-- Landing position: forward of the player but CLAMPED inside the floor
	-- slab they're standing on, so the model can never settle out of
	-- bounds, on a neighbouring chunk, or half-off a ledge.
	local extents = model:GetExtentsSize()
	local footprintRadius = math.max(extents.X, extents.Z) / 2
	local frontXZ, groundY = self:_pickMachineLanding(hrp, footprintRadius)

	local landingPosition = Vector3.new(frontXZ.X, groundY + (extents.Y / 2), frontXZ.Z)

	-- Rotation: face the PLAYER, flattened to the landing height so the
	-- model can never pitch. It used to turn toward the chunk's centre so
	-- the relic fan popped inward, away from the walls; the drops' own wall
	-- ricochet (resolveArcLanding) covers that now, so a machine landing in
	-- front of a standing player squarely faces them instead.
	--
	-- The trailing 180 degrees is the models' shared convention: the
	-- prefab's visual front is its +Z, so a raw lookAt would present its
	-- back. Landing exactly ON the player (a zero-length look makes lookAt
	-- undefined) faces the way they are looking from, mirrored.
	local flatTarget = Vector3.new(hrp.Position.X, landingPosition.Y, hrp.Position.Z)
	if (flatTarget - landingPosition).Magnitude < 0.01 then
		local look = hrp.CFrame.LookVector
		flatTarget = landingPosition - Vector3.new(look.X, 0, look.Z)
	end
	local landingCFrame = CFrame.lookAt(landingPosition, flatTarget) * CFrame.Angles(0, math.rad(180), 0)

	local startCFrame = landingCFrame + Vector3.new(0, DROP_HEIGHT, 0)

	model:PivotTo(startCFrame)
	model.Parent = parent

	self:_animateFall(model, startCFrame, landingCFrame, FALL_DURATION)
	if onLanded then
		task.delay(FALL_DURATION, function()
			if model.Parent then
				onLanded()
			end
		end)
	end
	return true
end

--[ Initializers ]--

function RelicMachineService:KnitStart()
	Players.PlayerRemoving:Connect(function(_player: Player) end)

	-- Drop a vending machine on every player when a Combat segment is cleared.
	-- Miniboss/other segment types are ignored — opt them in here if desired.
	DungeonService.Signals.OnSegmentCleared:Connect(function(_dungeon, lastChunk)
		if lastChunk.roomType ~= RoomTypes.Combat then
			return
		end

		-- EVERY cleared Combat segment drops a RELIC machine. The previous
		-- odd/even alternation with rune machines is gone: rune machines no
		-- longer spawn from room clears at all, so relic pickups are the
		-- single reward cadence and the element-affinity snowball gets a
		-- chance to compound every room instead of every other one.
		--
		-- DropMachineOnPlayer still takes isRuneMachine, and the /drop rune
		-- chat command still uses it -- this only stops the automatic drops.
		for _, player in Players:GetPlayers() do
			task.wait(0.25)
			RelicMachineService:DropMachineOnPlayer(player)
		end
	end)
end

function RelicMachineService:KnitInit()
	DungeonService = Knit.GetService("DungeonService")
end

return RelicMachineService
