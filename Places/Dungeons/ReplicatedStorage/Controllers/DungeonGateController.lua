--[[
	Module: DungeonGateController.lua
	Description:
	Client half of the Dungeon Gate cycle (server: DungeonService
	_startGateCycle). The gate part itself never moves on the SERVER — the
	server owns collision + timing and cues this controller to animate
	everything locally, which is what makes the door one-way PER PLAYER:

	  OnGateOpened  → (broadcast) the gate tweens up out of the doorway on
	                  every client. The server already set CanCollide false,
	                  so it's passable the moment the cue arrives.
	  OnGateCrossed → (this client only) fired when the LOCAL player walks
	                  past the gate. The gate tweens back down into the
	                  doorway and CanCollide flips on LOCALLY. Character
	                  physics is client-owned, so local collision is what
	                  actually blocks backtracking — while every player
	                  still behind the gate keeps THEIR raised, open copy
	                  and can walk through.

	The server passes the authored doorway CFrame with OnGateCrossed (its
	copy never moved), so the drop lands exactly where the gate started
	even though this client's copy is currently raised. Once every player
	has crossed, the server sets CanCollide true authoritatively — that
	replicated value matches what crossers already set locally.
]]

--[ Roblox Services ]--

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

--[ Imports ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local CameraShakePresets = require(ReplicatedStorage.Submodules.Core.Shared.Enums.CameraShakePresets)

local DungeonService
local CameraShakeController

--[ Controller ]--

local DungeonGateController = Knit.CreateController({
	Name = "DungeonGateController",
})

--[ Private ]--

-- How long the crossed-gate slam tween runs. The invisible doorway
-- collider below outlives it slightly so there's never a gap between
-- "collider gone" and "real gate resting in the doorway".
local SLAM_TWEEN_SECONDS = 1

-- Gate open / slam shakes are proximity-gated: only rattle the camera if
-- the LOCAL player is within this many studs of the doorway — a gate
-- moving across the room shouldn't shake you.
local GATE_SHAKE_RANGE_STUDS = 75
local GATE_OPEN_SOUND_ID = "rbxassetid://107033324149762"
-- The boss-room ExitPortal surfacing is only heard this close to it.
local EXIT_PORTAL_SOUND_RADIUS = 80
local GATE_CLOSE_SOUND_ID = "rbxassetid://85204139841993"

-- While a gate is tweening up or down it must not be faded by the walls
-- occlusion system (WallsTransparencyController). That system captures
-- a part's "original" transparency the FIRST time it touches it and
-- restores to that later — a capture taken mid-tween is garbage — and
-- its own fade tween fights (and cancels) the gate tween's Transparency.
-- So the gate is flagged for exactly the tween's lifetime, in both
-- directions; the occlusion system skips flagged parts and releases any
-- it already holds. Tracking resumes the moment the flag clears.
--
-- COUNTED, not boolean: a rise overridden by a slam fires the rise's
-- Completed (state Cancelled) while the slam is still running, and a
-- plain boolean would clear the flag out from under it.
local occlusionIgnoreCounts: { [BasePart]: number } = {}

local function beginOcclusionIgnore(gate: BasePart)
	occlusionIgnoreCounts[gate] = (occlusionIgnoreCounts[gate] or 0) + 1
	gate:SetAttribute(Attributes.OcclusionFadeIgnore, true)
end

local function endOcclusionIgnore(gate: BasePart)
	local count = math.max((occlusionIgnoreCounts[gate] or 1) - 1, 0)
	occlusionIgnoreCounts[gate] = if count > 0 then count else nil
	if count == 0 and gate.Parent then
		gate:SetAttribute(Attributes.OcclusionFadeIgnore, nil)
	end
end

-- One-shot positional sound on the gate part. Local like every other gate
-- effect (each player's gate opens/closes on their own screen); destroys
-- itself when done, with a Debris fallback for assets that never fire
-- Ended.
local function playGateSound(gate: BasePart, soundId: string)
	local sound = Instance.new("Sound")
	sound.SoundId = soundId
	sound.Volume = if soundId == GATE_OPEN_SOUND_ID then 0.35 else 2
	sound.Parent = gate
	sound:Play()
	sound.Ended:Once(function()
		sound:Destroy()
	end)
	Debris:AddItem(sound, 10)
end

-- Small local shake when a gate event happens within range of the local
-- player. Client-side like every other gate visual — each player's gate
-- opens and slams on their own screen.
local function shakeIfNear(position: Vector3)
	local character = Players.LocalPlayer.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if CameraShakeController and hrp and (hrp.Position - position).Magnitude <= GATE_SHAKE_RANGE_STUDS then
		CameraShakeController:Shake(CameraShakePresets.Medium)
	end
end

-- The visual slam takes a second — long enough for a fast dodge back
-- through the doorway before the descending gate physically blocks it. So
-- the moment the cross cue arrives, an INVISIBLE collider snaps into the
-- authored doorway CFrame instantly (local, like everything else here) and
-- the visible gate plays its slam on top of it. Self-cleans just after the
-- tween lands — by then the real gate holds the doorway with CanCollide on.
--
-- Blocking the DODGE is what dictates the two odd-looking settings below.
-- A dodge dash is a Heartbeat CFrame lerp (DodgeController.Dash), so it
-- ignores CanCollide entirely — the only thing that stops it is its own
-- forward raycast, an INCLUDE filter over specific folders. Therefore the
-- collider must (a) live in one of those folders (DungeonRooms — where the
-- room + resting gate already live) and (b) keep CanQuery = true so the
-- ray can actually hit it. Walking is blocked by plain physics either way.
local function spawnDoorwayCollider(gate: BasePart, originalCFrame: CFrame)
	local collider = Instance.new("Part")
	collider.Name = "DungeonGateCollider"
	collider.Size = gate.Size
	collider.CFrame = originalCFrame
	collider.Anchored = true
	collider.Transparency = 1
	collider.CanCollide = true
	collider.CanQuery = true -- dodge wall-check raycasts skip CanQuery=false parts
	collider.CanTouch = false
	collider.Parent = workspace.IgnoreInstances.Map.DungeonRooms
	Debris:AddItem(collider, SLAM_TWEEN_SECONDS + 0.2)
end

-- Dust burst at the foot of the door as it slams shut — same asset +
-- recipe as DodgeController's dodge-end landing puff (GameAssets.VFX.Dodge).
-- Local like the slam itself: only the player whose door just shut sees it.
local function playSlamVFX(gate: BasePart, originalCFrame: CFrame)
	local dodgeVFX = ReplicatedStorage.GameAssets.VFX.DungeonDoor.Door:Clone()
	dodgeVFX:PivotTo(CFrame.new(originalCFrame.Position - Vector3.new(0, (gate.Size.Y / 2), 0)))
	dodgeVFX.Parent = workspace.IgnoreInstances.MagicSpells

	for _, particle in dodgeVFX.Part.Attachment:GetChildren() do
		if particle:IsA("ParticleEmitter") then
			particle:Emit(25)
		end
	end

	dodgeVFX.Part.Landing:Play()

	-- The slam impact — shake lands together with the dust + sound.
	shakeIfNear(originalCFrame.Position)

	Debris:AddItem(dodgeVFX, 5)
end

--[ Lifecycle ]--

function DungeonGateController:KnitStart()
	DungeonService = Knit.GetService("DungeonService")
	CameraShakeController = Knit.GetController("CameraShakeController")

	-- Boss-room ExitPortal surfacing: same open sound as a gate, played on
	-- the portal (its PrimaryPart / first BasePart) so it's positional.
	DungeonService.OnExitPortalRising:Connect(function(portal: Model)
		if not portal or not portal.Parent then
			return
		end
		local anchor = portal.PrimaryPart or portal:FindFirstChildWhichIsA("BasePart", true)
		if not anchor then
			return
		end
		local character = Players.LocalPlayer.Character
		local hrp = character and character:FindFirstChild("HumanoidRootPart")
		if not hrp or (hrp.Position - anchor.Position).Magnitude > EXIT_PORTAL_SOUND_RADIUS then
			return
		end
		playGateSound(anchor, GATE_OPEN_SOUND_ID)
	end)

	DungeonService.OnGateOpened:Connect(function(gate: BasePart, riseStuds: number)
		if not gate or not gate.Parent then
			return
		end

		-- Clear LOCAL collision explicitly. Normally redundant (the server
		-- already set CanCollide false before this cue), but this cue is
		-- also re-fired to a single player by the server's seal guard when
		-- their crossed-mark went stale — and that client pinned CanCollide
		-- true locally in OnGateCrossed, which server replication won't
		-- override. Without this line a guard-reopened gate rises visually
		-- but stays solid for that player.
		gate.CanCollide = false

		playGateSound(gate, GATE_OPEN_SOUND_ID)
		shakeIfNear(gate.Position)

		local riseTween = TweenService:Create(
			gate,
			TweenInfo.new(SLAM_TWEEN_SECONDS, Enum.EasingStyle.Cubic, Enum.EasingDirection.InOut),
			{
				CFrame = gate.CFrame + Vector3.new(0, riseStuds, 0),
				Transparency = 1,
			}
		)
		beginOcclusionIgnore(gate)
		riseTween.Completed:Once(function()
			endOcclusionIgnore(gate)
		end)
		riseTween:Play()

		if gate:FindFirstChild("gaming") then
			TweenService:Create(
				gate.gaming,
				TweenInfo.new(SLAM_TWEEN_SECONDS, Enum.EasingStyle.Cubic, Enum.EasingDirection.InOut),
				{
					Transparency = 1,
				}
			):Play()
		end
	end)

	DungeonService.OnGateCrossed:Connect(function(gate: BasePart, originalCFrame: CFrame)
		if not gate or not gate.Parent then
			return
		end

		gate.CanCollide = true

		spawnDoorwayCollider(gate, originalCFrame)

		local slamTween = TweenService:Create(
			gate,
			TweenInfo.new(SLAM_TWEEN_SECONDS, Enum.EasingStyle.Cubic, Enum.EasingDirection.InOut),
			{
				CFrame = originalCFrame,
				Transparency = 0,
			}
		)

		if gate:FindFirstChild("gaming") then
			TweenService:Create(
				gate.gaming,
				TweenInfo.new(SLAM_TWEEN_SECONDS, Enum.EasingStyle.Cubic, Enum.EasingDirection.InOut),
				{
					Transparency = 0,
				}
			):Play()
		end

		beginOcclusionIgnore(gate)
		slamTween.Completed:Once(function()
			endOcclusionIgnore(gate)
		end)
		slamTween:Play()

		task.delay(0.5, function()
			playGateSound(gate, GATE_CLOSE_SOUND_ID)
		end)

		task.delay(0.75, function()
			playSlamVFX(gate, originalCFrame)
		end)
	end)
end

function DungeonGateController:KnitInit() end

return DungeonGateController
