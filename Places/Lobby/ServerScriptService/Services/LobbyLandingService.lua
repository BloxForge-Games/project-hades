--[[
	Module: LobbyLandingService.lua
	Description:
	Server half of the Lobby join "landing": the same sequence as
	DungeonService:_runPlayerLanding, with the dungeon start marker swapped
	for workspace.IgnoreInstances.LobbySpawnPoint and none of the run
	bookkeeping (no dungeon gate, no exited/dead checks, no starter machine).

	  1. PlayerEventService.OnPlayerAdded (this player's client finished
	     preloading and called SetupCharacter) -> land them.
	  2. Prime the LandingAnimation so every client fetches the asset during
	     the start delay.
	  3. Freeze the character in the animation's first frame (+25 studs)
	     while still at the staging spawn, let it replicate, then set the
	     HRP CFrame onto LobbySpawnPoint (party fanned out sideways).
	  4. OnLandingStart (to the player): their LobbyLandingController drops the
	     loading screen and locks controls. The track resumes and the body
	     falls to the ground.
	  5. OnLandingImpact (broadcast): dust + landing sound at the player.
	  6. OnLandingEnd (to the player): controls restored.

	Constants are DungeonService's join-landing values; keep them in sync.
]]

--[ Roblox Services ]--

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

--[ Imports ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)

local PlayerEventService

--[ Constants ]--

-- Where players land: a Part under workspace.IgnoreInstances. Its CFrame is
-- used as-is (position + facing), so point its LookVector the way players
-- should face when they touch down.
local IGNORE_INSTANCES_NAME = "IgnoreInstances"
local SPAWN_POINT_NAME = "LobbySpawnPoint"

-- Same values as DungeonService's join landing.
local LANDING_START_DELAY = 1 -- armor / weapons finish welding before the pose
local LANDING_POSE_SETTLE = 0.2 -- frozen pose replicates before the teleport
local LANDING_POSE_HOLD_SECONDS = 0.5 -- pose is rendered everywhere before the reveal
local LANDING_DROP_SPEED = 0.75
local LANDING_IMPACT_DELAY = 1.6
local LANDING_DURATION = 1.7
local LANDING_SPREAD_STUDS = 5
local LANDING_HOLD_TOLERANCE_STUDS = 2 -- see _holdLandingPosition

--[ Service ]--

local LobbyLandingService = Knit.CreateService({
	Name = "LobbyLandingService",
	Client = {
		OnLandingStart = Knit.CreateSignal(), -- (to one player) drop loading screen + lock controls
		OnLandingImpact = Knit.CreateSignal(), -- (broadcast, player) landing VFX hook
		OnLandingEnd = Knit.CreateSignal(), -- (to one player) restore controls
	},
})

LobbyLandingService._landed = {} -- [Player]: true -- landed once this join

--[ Private Functions ]--

function LobbyLandingService:_getSpawnPoint(): BasePart?
	local ignoreInstances = workspace:FindFirstChild(IGNORE_INSTANCES_NAME)
	local spawnPoint = ignoreInstances and ignoreInstances:FindFirstChild(SPAWN_POINT_NAME)
	if not spawnPoint or not spawnPoint:IsA("BasePart") then
		warn(
			("[LobbyLandingService] workspace.%s.%s missing -- players stay at their spawn"):format(
				IGNORE_INSTANCES_NAME,
				SPAWN_POINT_NAME
			)
		)
		return nil
	end
	return spawnPoint
end

-- Mirrors DungeonService:_teleportPlayerToStart minus the marker lookup.
function LobbyLandingService:_teleportPlayerToSpawnPoint(player: Player): CFrame?
	local spawnPoint = self:_getSpawnPoint()
	if not spawnPoint then
		return
	end

	local targetCFrame = spawnPoint.CFrame

	-- Fan the party out sideways (in the spawn CFrame's own right axis) so
	-- nobody lands inside anyone else: slot i of n sits at
	-- (i - (n+1)/2) x LANDING_SPREAD_STUDS.
	local players = Players:GetPlayers()
	local slot = table.find(players, player) or 1
	local lateral = (slot - (#players + 1) / 2) * LANDING_SPREAD_STUDS
	targetCFrame = targetCFrame * CFrame.new(lateral, 0, 0)

	local character = player.Character
	if not character then
		return
	end

	-- Set the HumanoidRootPart CFrame DIRECTLY rather than character:PivotTo:
	-- the landing animation lifts the visible body +25 studs, which shifts the
	-- model's bounding-box pivot up, so PivotTo(ground) would sink the root
	-- below the floor. The HRP's own CFrame is unaffected by the animation.
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if hrp then
		hrp.AssemblyLinearVelocity = Vector3.zero
		hrp.CFrame = targetCFrame
	else
		character:PivotTo(targetCFrame)
	end
	return targetCFrame
end

-- Re-asserts the landing spot for `seconds` after the teleport (the pose
-- hold + the fall). The teleport is a server CFrame write on a root the
-- CLIENT owns; a client-side root write in the same window (a dash, a dodge,
-- mobile aim -- all gated client-side now, this is the safety net) would
-- otherwise win. Horizontal only: the humanoid settles vertically onto the
-- floor by itself and must not be fought.
function LobbyLandingService:_holdLandingPosition(
	character: Model,
	hrp: BasePart,
	targetCFrame: CFrame,
	seconds: number
)
	task.spawn(function()
		local deadline = os.clock() + seconds
		while os.clock() < deadline do
			RunService.Heartbeat:Wait()
			if not character.Parent or not hrp.Parent then
				return
			end
			local offset = hrp.Position - targetCFrame.Position
			if Vector3.new(offset.X, 0, offset.Z).Magnitude > LANDING_HOLD_TOLERANCE_STUDS then
				hrp.AssemblyLinearVelocity = Vector3.zero
				hrp.CFrame = targetCFrame
			end
		end
	end)
end

-- Same dust + sound as DungeonService:_onLandingImpact. The Dungeons place
-- parents the clone under IgnoreInstances.MagicSpells; the Lobby may not
-- have that folder, so fall back to IgnoreInstances, then workspace.
function LobbyLandingService:_onLandingImpact(player: Player)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end

	local vfxFolder = ReplicatedStorage.GameAssets:FindFirstChild("VFX")
	local dodgeFolder = vfxFolder and vfxFolder:FindFirstChild("Dodge")
	local template = dodgeFolder and dodgeFolder:FindFirstChild("Dodge")
	if not template then
		return
	end

	local ignoreInstances = workspace:FindFirstChild(IGNORE_INSTANCES_NAME)
	local parent = (ignoreInstances and ignoreInstances:FindFirstChild("MagicSpells")) or ignoreInstances or workspace

	local dodgeVFX = template:Clone()
	dodgeVFX:PivotTo(CFrame.new(root.Position) - Vector3.new(0, 3, 0))
	dodgeVFX.Parent = parent

	local attachment = dodgeVFX:FindFirstChild("Part") and dodgeVFX.Part:FindFirstChild("Attachment")
	if attachment then
		for _, particle in attachment:GetChildren() do
			if particle:IsA("ParticleEmitter") then
				particle:Emit(20)
			end
		end
	end

	local landingSound = dodgeVFX:FindFirstChild("Part") and dodgeVFX.Part:FindFirstChild("Landing")
	if landingSound then
		landingSound:Play()
	end

	Debris:AddItem(dodgeVFX, 5)
end

-- DungeonService:_runPlayerLanding, minus the run bookkeeping.
function LobbyLandingService:_runPlayerLanding(player: Player)
	if self._landed[player] then
		return
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not character or not humanoid or not hrp then
		return
	end
	if humanoid.Health <= 0 or character:GetAttribute(Attributes.Death) == true then
		return
	end

	self._landed[player] = true

	-- Mark the character as mid-fall for every client (Attributes.Landing);
	-- cleared on the landing beat below.
	character:SetAttribute(Attributes.Landing, true)

	local animator = humanoid:FindFirstChildOfClass("Animator")
	local animationsFolder = ReplicatedStorage.GameAssets:FindFirstChild("Animations")
	local landAnimation = animationsFolder and animationsFolder:FindFirstChild("LandingAnimation")
	local landAnimationTrack = animator and landAnimation and animator:LoadAnimation(landAnimation)

	-- Top priority so the pose overrides whatever else is on the Animator
	-- (default idle, the owner's weapon idle) instead of stopping it; the
	-- idle resumes underneath when the landing finishes.
	if landAnimationTrack then
		landAnimationTrack.Priority = Enum.AnimationPriority.Action4

		-- PRIME: a server-side Play makes each client fetch the animation
		-- asset. Zero-length play-then-stop hands them the whole start delay
		-- to download it, so the real freeze below lands on a resident asset.
		landAnimationTrack:Play(0, 1, 1)
		landAnimationTrack:Stop(0)
	end

	task.spawn(function()
		-- Brief hold so armor / weapons / appearance finish welding before we
		-- pose the character (otherwise they pop in mid-landing).
		task.wait(LANDING_START_DELAY)
		if not character.Parent or not hrp.Parent then
			return
		end

		-- Pose into the animation's first frame (+25 studs) while STILL at the
		-- staging spawn -- off-map, and the joiner's own view is behind the
		-- loading screen. Frozen (speed 0), no fade-in.
		if landAnimationTrack then
			landAnimationTrack:Play(0, 1, 0)
		end

		-- Let the frozen pose apply + replicate before we move into view.
		task.wait(LANDING_POSE_SETTLE)
		if not character.Parent or not hrp.Parent then
			return
		end

		-- Teleport in. The character arrives already in the +25 pose.
		local targetCFrame = self:_teleportPlayerToSpawnPoint(player)
		if targetCFrame then
			self:_holdLandingPosition(character, hrp, targetCFrame, LANDING_POSE_HOLD_SECONDS + LANDING_DURATION)
		end

		-- Hold the frozen frame in place, still behind the loading screen, so
		-- the pose has rendered on every client before anyone sees it.
		task.wait(LANDING_POSE_HOLD_SECONDS)
		if not character.Parent or not hrp.Parent then
			if character.Parent then
				character:SetAttribute(Attributes.Landing, nil)
			end
			return
		end

		-- Reveal: drop the joiner's loading screen + lock controls.
		self.Client.OnLandingStart:Fire(player, targetCFrame)

		-- Drop: resume the animation from the frozen pose down to the ground.
		if landAnimationTrack then
			landAnimationTrack:AdjustSpeed(LANDING_DROP_SPEED)
		end

		-- Impact beat -- broadcast so any client can play VFX at the landing
		-- player's position.
		task.delay(LANDING_IMPACT_DELAY, function()
			if not character.Parent then
				return
			end
			self:_onLandingImpact(player)
			self.Client.OnLandingImpact:FireAll(player)
		end)

		-- End -- restore controls.
		task.delay(LANDING_DURATION, function()
			if character.Parent then
				character:SetAttribute(Attributes.Landing, nil)
			end
			self.Client.OnLandingEnd:Fire(player)
		end)
	end)
end

--[ Lifecycle ]--

function LobbyLandingService:KnitInit()
	PlayerEventService = Knit.GetService("PlayerEventService")
end

function LobbyLandingService:KnitStart()
	-- PlayerEventService.OnPlayerAdded fires AFTER this player's client
	-- finishes preloading (PlayerEventController waits on OnPreloadComplete
	-- before calling SetupCharacter) -- the same per-player "ready" cue
	-- DungeonService lands on.
	PlayerEventService.OnPlayerAdded:Connect(function(player: Player)
		self:_runPlayerLanding(player)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		self._landed[player] = nil
	end)
end

return LobbyLandingService
