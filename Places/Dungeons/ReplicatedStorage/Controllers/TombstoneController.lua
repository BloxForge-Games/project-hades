--!strict
--[[
     Module: TombstoneController.lua
     Description:
     Client-side death-marker renderer. Observes LifeController.DeathState
     (entries carry phase, deathPosition, diedAtServerTime and, once the
     revive window has closed, fullyDiedAtServerTime) and spawns / tweens
     / destroys a tombstone instance locally per FULLY dead player. A
     DOWNED player (phase "downed", revive window open) gets no marker:
     the body is lying right there and may yet stand back up. Server
     doesn't track the marker at all — it just publishes the death
     metadata.

     Why client-side instead of server-instanced:
       - Tombstones are pure visual; no gameplay system reads or interacts
         with the instance on the server.
       - Each client runs the rise tween at their own frame rate (60-120Hz)
         instead of inheriting Roblox's ~20Hz CFrame replication interp.
       - No server-side bookkeeping (registry table, cleanup on revive /
         player leave, race-checks across task.delays) — the DeathState
         observer is the single source of truth.

     Timing:
       - SPAWN_DELAY_AFTER_FULL_DEATH (= the body fade + a small buffer)
         gates when the tombstone appears after the window closes.
         Computed against the entry's fullyDiedAtServerTime so all clients
         agree on the spawn moment regardless of when they observed the
         change.
       - Late joiners get the snapshot via Observe's initial fire. If the
         full death is older than SPAWN_DELAY_AFTER_FULL_DEATH at the time
         of join, we spawn immediately (no wait).

     Cleanup:
       - DeathState entry vanishes (revive / player leave) → destroy
         the local instance + cancel any pending spawn task.
       - A "downed" entry never schedules anything, so the phase flipping
         to "dead" on a later observation is what schedules the spawn.
]]

--[ Roblox Services ]--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

--[ Exports & Types & Defaults ]--

local LifeController = require(ReplicatedStorage.Controllers.LifeController)

local TombstoneController = {
	Name = "TombstoneController",
	Dependencies = { LifeController } :: { any },
}

--[ Tuning ]--

-- Name of the prefab Model (or Part) under ReplicatedStorage.GameAssets
-- that gets cloned per dead player. If absent, the placeholder Part below
-- is used. Swap to the real asset name when authored.
local TOMBSTONE_PREFAB_NAME = "Default"

-- Placeholder visuals — used only when the prefab above isn't present.
-- Delete once the real asset lands.
local TOMBSTONE_FALLBACK_SIZE = Vector3.new(2, 4, 1)
local TOMBSTONE_FALLBACK_COLOR = Color3.fromRGB(80, 80, 80)
local TOMBSTONE_FALLBACK_MATERIAL = Enum.Material.Slate

-- Rise animation: tombstone spawns this many studs below its final ground
-- position and tweens upward over RISE_DURATION seconds. Mirrors the
-- RelicMachine vending drop pattern (raycast down to find ground, then
-- animate from offset to settled).
local TOMBSTONE_RISE_DURATION = 1
local TOMBSTONE_RISE_OFFSET = 5

-- Delay from the moment of FULL death (the revive window closing) to the
-- start of the rise tween. Sized so the marker only appears AFTER the
-- body has faded out (LifeController's CHARACTER_FADE_DURATION, 1s) —
-- for the dead player the rise plays under their fade-to-black; for
-- other players it reads as "the body fades, then the marker rises."
-- Slight desync is fine — other players have no fade to align with.
local SPAWN_DELAY_AFTER_FULL_DEATH = 2

-- Where to parent the tombstone in the world tree. Falls back to
-- workspace if IgnoreInstances.MagicSpells isn't present yet.
local function getTombstoneContainer(): Instance
	local ignore = workspace:FindFirstChild("IgnoreInstances")
	local magicSpells = ignore and ignore:FindFirstChild("MagicSpells")
	return magicSpells or workspace
end

-- Raycast filter for the ground-finding raycast. Excludes the dying
-- player's character so the tombstone sits on the actual floor instead
-- of on top of the ragdoll.
local function getGroundRaycastParams(excludeCharacter: Model?): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	if excludeCharacter then
		params.FilterDescendantsInstances = { excludeCharacter }
	end
	return params
end

--[ State ]--

-- Per-userId local tombstone instance. Cleared when the player's
-- DeathState entry vanishes (revive / player leave) or when a fresh
-- death replaces an older one.
TombstoneController._tombstones = {} :: { [number]: Instance }

-- Per-userId pending spawn token. When we schedule a delayed spawn we
-- stamp a unique token; the delay callback compares it against the
-- current token before spawning. Any subsequent DeathState change for
-- that userId stamps a new token, invalidating any in-flight delays.
-- Cheaper than tracking task handles (which task.cancel doesn't support
-- ergonomically when the closure has already captured upvalues).
TombstoneController._pendingTokens = {} :: { [number]: any }

--[ Helpers ]--

-- Either clones ReplicatedStorage.GameAssets[TOMBSTONE_PREFAB_NAME] or
-- builds a placeholder Part. Returns (instance, animTarget). animTarget
-- is the BasePart whose CFrame we tween — for a Part it's the part
-- itself, for a Model it's the PrimaryPart (rest of the model must be
-- welded to it). Models without a PrimaryPart return animTarget=nil and
-- the caller skips the tween.
local function buildTombstoneInstance(displayName: string): (Instance, BasePart?)
	local gameAssets = ReplicatedStorage:FindFirstChild("GameAssets")
	local prefab = gameAssets and gameAssets.Tombstones:FindFirstChild(TOMBSTONE_PREFAB_NAME)

	if prefab then
		local clone = prefab:Clone()
		clone.Tombstone.NameTag.PlayerName.Text = displayName

		return clone, clone.PrimaryPart
	end

	local part = Instance.new("Part")
	part.Size = TOMBSTONE_FALLBACK_SIZE
	part.Color = TOMBSTONE_FALLBACK_COLOR
	part.Material = TOMBSTONE_FALLBACK_MATERIAL
	part.Anchored = true
	part.CanCollide = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth

	return part, part
end

-- Destroys the local tombstone for userId if one exists, clears the
-- pending-spawn token so any in-flight task.delay aborts. Idempotent.
function TombstoneController._destroyTombstone(self: typeof(TombstoneController), userId: number)
	-- Invalidate any pending spawn for this userId.
	self._pendingTokens[userId] = nil

	local instance = self._tombstones[userId]
	if not instance then
		return
	end
	instance:Destroy()
	self._tombstones[userId] = nil
end

-- Builds + positions + tweens the tombstone in place. Called either
-- immediately (late joiner past the spawn delay) or from the delayed
-- spawn closure. No-op if a tombstone for this userId already exists
-- (defensive against double-spawn races).
function TombstoneController._spawnTombstone(
	self: typeof(TombstoneController),
	userId: number,
	player: Player,
	recordedDeathPosition: Vector3?
)
	if self._tombstones[userId] then
		return
	end

	-- The body never moves between downed and dead, so its root part and
	-- the server's recorded position agree; the record covers a character
	-- that has already been removed.
	local character = player and player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local deathPosition = ((rootPart and rootPart.Position) or recordedDeathPosition) :: Vector3

	-- Raycast down to find the ground, excluding the dying player's
	-- character so we don't hit the ragdoll body.
	local rayParams = getGroundRaycastParams(character)
	local hit = workspace:Raycast(deathPosition, Vector3.new(0, -50, 0), rayParams)
	local groundY = hit and hit.Position.Y or (deathPosition.Y - 3)

	-- Name tag (DisplayName, fall back to Name). For destroyed/missing
	-- players we still render the marker but skip the label.
	local displayName = player.DisplayName ~= "" and player.DisplayName or player.Name

	local tombstone, animTarget = buildTombstoneInstance(displayName)
	tombstone.Name = "Tombstone_" .. userId

	local size = (animTarget and animTarget.Size) or TOMBSTONE_FALLBACK_SIZE
	local finalY = groundY + size.Y / 2
	local startY = finalY - TOMBSTONE_RISE_OFFSET

	local finalCFrame = CFrame.new(deathPosition.X, finalY - 1.5, deathPosition.Z)
	local startCFrame = CFrame.new(deathPosition.X, startY, deathPosition.Z)

	-- Seat at start before parenting so the rise isn't visible as a
	-- snap-then-tween.
	if tombstone:IsA("BasePart") then
		tombstone.CFrame = startCFrame
	else
		(tombstone :: PVInstance):PivotTo(startCFrame)
	end

	tombstone.Parent = getTombstoneContainer()
	self._tombstones[userId] = tombstone

	-- Rise tween. Skipped for Models without a PrimaryPart (no anchor
	-- to drive); they just snap to final position.
	if animTarget then
		TweenService:Create(
			animTarget,
			TweenInfo.new(TOMBSTONE_RISE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ CFrame = finalCFrame }
		):Play()
	elseif tombstone:IsA("Model") then
		tombstone:PivotTo(finalCFrame)
	end
end

-- Decides whether to spawn now or schedule a delayed spawn for a
-- newly-observed DeathState entry. Token-stamps so subsequent changes
-- for the same userId cancel an in-flight delay. A DOWNED entry is left
-- alone (no token either), so the observation that flips it to "dead"
-- is the one that schedules.
function TombstoneController._scheduleSpawn(
	self: typeof(TombstoneController),
	userId: number,
	entry: {
		phase: string,
		diedAtServerTime: number,
		fullyDiedAtServerTime: number?,
		deathPosition: Vector3,
		player: Player,
	}
)
	if entry.phase ~= "dead" then
		return
	end
	local fullyDiedAt = entry.fullyDiedAtServerTime
	if not entry.deathPosition or not fullyDiedAt then
		return
	end

	-- New token for this scheduling pass. The delay callback checks it
	-- before spawning; any subsequent observation (including revive /
	-- die-again) replaces the token and the old delay no-ops.
	local token = {}
	self._pendingTokens[userId] = token

	local spawnAt = fullyDiedAt + SPAWN_DELAY_AFTER_FULL_DEATH
	local waitFor = spawnAt - workspace:GetServerTimeNow()

	if waitFor <= 0 then
		-- Late joiner: the death is already older than the spawn delay.
		-- Spawn immediately, skip the visual delay (we missed the
		-- "moment of silence" beat anyway).
		self._pendingTokens[userId] = nil
		self:_spawnTombstone(userId, entry.player, entry.deathPosition)
		return
	end

	task.delay(waitFor, function()
		if self._pendingTokens[userId] ~= token then
			-- Superseded by a newer observation (player revived, died
			-- again, left — anything that swapped the token).
			return
		end
		self._pendingTokens[userId] = nil
		self:_spawnTombstone(userId, entry.player, entry.deathPosition)
	end)
end

--[ Lifecycle ]--

function TombstoneController.Start(self: typeof(TombstoneController))
	-- Single source of truth: observe DeathState changes and reconcile
	-- the local tombstone set against it on every update.
	--
	-- For each userId currently rendered locally:
	--   - if the server entry vanished → destroy
	-- For each userId in the server state without a local instance:
	--   - schedule a spawn once its phase is "dead" (delayed for fresh
	--     deaths, immediate for late-join); "downed" entries are skipped
	--     and picked up by the observation that flips them
	LifeController.DeathState:Observe(function(deathState: { [any]: any }?)
		local serverEntries: { [any]: any } = deathState or {}

		-- 1. Reap stale local tombstones.
		for userId, _ in self._tombstones do
			-- DeathState keys may have replicated as string or number;
			-- check both shapes.
			local serverEntry = serverEntries[userId] or serverEntries[tostring(userId)]
			if not serverEntry then
				self:_destroyTombstone(userId)
			end
		end

		-- 2. Spawn / reschedule for entries that appear or change.
		for rawKey, entry in serverEntries do
			local userId = tonumber(rawKey) or rawKey
			if typeof(userId) ~= "number" then
				continue
			end
			if self._tombstones[userId] then
				-- Already rendered. Could compare diedAtServerTime here
				-- to detect "die → revive → die" within the spawn-delay
				-- window, but that path is vanishingly rare given the
				-- revive cutscene takes ~3+ seconds itself. Skipping
				-- for simplicity — worst case the marker stays at the
				-- old spot for one cycle.
				continue
			end
			-- Only schedule if there's no pending spawn already
			-- (e.g. we observed the same entry twice in rapid succession).
			if self._pendingTokens[userId] then
				continue
			end
			self:_scheduleSpawn(userId, entry)
		end
	end)

	-- Defensive cleanup on player leave: the server's PlayerRemoved
	-- handler already clears DeathState for the leaver (which the
	-- observer above reacts to), but if for any reason that
	-- replication is delayed we'll still destroy local instances when
	-- the player itself goes away.
	Players.PlayerRemoving:Connect(function(player: Player)
		self:_destroyTombstone(player.UserId)
	end)
end

return TombstoneController
