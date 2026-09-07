--[[
     Module: SpectateService.lua
     Description:
     Server-authoritative spectate target tracking. When a player enters
     death state (LifeService.OnPlayerDied), we pick their initial spectate
     target (first alive teammate by UserId) and fire
     IsometricCameraService.OnCameraTargetChanged for that player so the
     existing isometric camera smoothly lerps onto the target's HRP. The
     same signal fires whenever the player cycles via arrow keys, or when
     the currently-spectated player dies and we need to re-target them.

     LifeService consults :GetSpectateTarget during :Revive to know where
     to teleport the reviving player.

     Data shape (replicated):
       SpectateTargets = { [spectatorUserId] = spectatedUserId }
       Only present for players currently in death state. Cleared on
       revive / player leave.
]]

--[ Roblox Services ]--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--[ Exports & Types & Defaults ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)

local LifeService
local IsometricCameraService

local SpectateService = Knit.CreateService({
	Name = "SpectateService",
	Client = {
		-- Map of spectator userId → spectated userId. Replicated to all
		-- clients (spectate UI reads it for the local player; HUD
		-- features for who's watching whom can read it too).
		SpectateTargets = Knit.CreateProperty({}),

		-- Client → server cycle request. Payload: "left" | "right".
		-- Server validates IsDeathState and picks the next eligible
		-- target in sorted order.
		OnCycleRequested = Knit.CreateSignal(),
	},
})

--[ Properties ]--

-- Server-side mirror of the replicated SpectateTargets property.
SpectateService._spectateTargets = {} :: { [number]: number }

--[ Private helpers ]--

-- Eligible spectate candidates for `spectator`. A candidate is any other
-- player who has a Humanoid above 0 HP and is NOT themselves in the
-- death state. Sorted by UserId for deterministic cycling.
function SpectateService:_getCandidates(spectator: Player): { Player }
	local list = {}
	for _, player in Players:GetPlayers() do
		if player == spectator then
			continue
		end
		if LifeService and LifeService:IsDeathState(player) then
			continue
		end
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health > 0 then
			table.insert(list, player)
		end
	end
	table.sort(list, function(a, b)
		return a.UserId < b.UserId
	end)
	return list
end

-- Publishes the current SpectateTargets snapshot to clients.
function SpectateService:_replicateTargets()
	local snapshot = table.clone(self._spectateTargets)
	self.Client.SpectateTargets:Set(snapshot)
end

-- Aims the spectator's camera at the target player's HRP via the existing
-- IsometricCameraService signal. The IsometricCameraController on the
-- client side already does a smooth 2s lerp to the new origin, so we
-- get the "lerp between spectated players" feel for free.
function SpectateService:_routeCameraTo(spectator: Player, target: Player?)
	if not IsometricCameraService then
		return
	end
	if target and target.Character then
		local hrp = target.Character:FindFirstChild("HumanoidRootPart")
		if hrp then
			-- 3rd arg `fireAll = false` → server routes the signal to
			-- this one spectator only.
			IsometricCameraService.OnCameraTargetChanged:Fire(spectator, hrp, false)
			return
		end
	end
	-- No valid target — reset camera to spectator's own HRP. The
	-- IsometricCameraController handles OnCameraTargetReset by pointing
	-- back at LocalPlayer.Character.HumanoidRootPart.
	IsometricCameraService.OnCameraTargetReset:Fire(spectator, false)
end

--[ Public API ]--

-- Returns the Player that `spectator` is currently watching, or nil if
-- they have no target / aren't spectating.
function SpectateService:GetSpectateTarget(spectator: Player): Player?
	local targetId = self._spectateTargets[spectator.UserId]
	if not targetId then
		return nil
	end
	return Players:GetPlayerByUserId(targetId)
end

-- Sets `spectator` to watch `target` (or clears with nil). Updates the
-- replicated property AND routes the camera — but ONLY routes when the
-- target actually changed. The unconditional camera fire we had before
-- caused a visible 2s up-down bob on solo death: PickInitialTarget
-- returns nil (no alive teammates), this method was called with
-- target=nil, _routeCameraTo fired OnCameraTargetReset, and the iso
-- camera ran its 2s InOut lerp from its internal cached position to
-- the HRP — even though the camera was visibly already there, the
-- library's internal interpolation state drifts slightly from the
-- rendered position and the lerp interpolates that delta. Skipping
-- the fire when prev == new (both nil in solo) sidesteps the bob.
function SpectateService:SetSpectateTarget(spectator: Player, target: Player?)
	local previousTargetId = self._spectateTargets[spectator.UserId]
	local newTargetId = target and target.UserId or nil

	if target then
		self._spectateTargets[spectator.UserId] = target.UserId
	else
		self._spectateTargets[spectator.UserId] = nil
	end
	self:_replicateTargets()

	if previousTargetId ~= newTargetId then
		self:_routeCameraTo(spectator, target)
	end
end

-- Picks the first alive teammate for `spectator` (sorted by UserId).
-- Returns nil if everyone else is dead / there are no other players.
function SpectateService:PickInitialTarget(spectator: Player): Player?
	local candidates = self:_getCandidates(spectator)
	return candidates[1]
end

-- Advances `spectator` to the next eligible target. direction = 1 (right)
-- or -1 (left). Wraps around. No-op when the candidate pool is empty.
function SpectateService:CycleTarget(spectator: Player, direction: number)
	local candidates = self:_getCandidates(spectator)
	if #candidates == 0 then
		self:SetSpectateTarget(spectator, nil)
		return
	end

	local currentId = self._spectateTargets[spectator.UserId]
	local currentIndex = nil
	for i, player in candidates do
		if player.UserId == currentId then
			currentIndex = i
			break
		end
	end

	local nextIndex
	if not currentIndex then
		-- Current target is no longer eligible — jump to the first.
		nextIndex = 1
	else
		-- Wrap-around modular cycle: (i - 1 + dir) mod N + 1.
		nextIndex = ((currentIndex - 1 + direction) % #candidates) + 1
	end

	self:SetSpectateTarget(spectator, candidates[nextIndex])
end

function SpectateService.Client:OnDeathStateReplicated(player: Player)
	local initial = self.Server:PickInitialTarget(player)
	self.Server:SetSpectateTarget(player, initial)
end

--[ Lifecycle ]--

function SpectateService:KnitInit()
	LifeService = Knit.GetService("LifeService")
	IsometricCameraService = Knit.GetService("IsometricCameraService")
end

function SpectateService:KnitStart()
	-- On revive: clear their spectate target (they're back to controlling
	-- their own character; IsometricCameraController will already have
	-- the local HRP via OnCameraTargetReset firing during the unanchor).
	LifeService.OnPlayerRevived:Connect(function(player: Player)
		if self._spectateTargets[player.UserId] then
			self:SetSpectateTarget(player, nil)
		end
	end)

	-- When the currently-spectated player dies, every spectator watching
	-- them needs to re-target. We use OnPlayerDied for this (the dying
	-- player just became ineligible), and just brute-force re-pick — the
	-- candidate filter already excludes the dying player.
	LifeService.OnPlayerDied:Connect(function(deadPlayer: Player)
		for spectatorId, targetId in self._spectateTargets do
			if targetId == deadPlayer.UserId then
				local spectator = Players:GetPlayerByUserId(spectatorId)
				if spectator then
					local newTarget = self:PickInitialTarget(spectator)
					self:SetSpectateTarget(spectator, newTarget)
				end
			end
		end
	end)

	-- Client-driven cycle (arrow keys). Validate IsDeathState — only
	-- downed players can spectate.
	self.Client.OnCycleRequested:Connect(function(player: Player, direction: string?)
		if not LifeService:IsDeathState(player) then
			return
		end
		local delta = direction == "right" and 1 or -1
		self:CycleTarget(player, delta)
	end)

	-- Player leave cleanup. Anyone watching this player needs to re-target.
	Players.PlayerRemoving:Connect(function(player: Player)
		for spectatorId, targetId in self._spectateTargets do
			if targetId == player.UserId then
				local spectator = Players:GetPlayerByUserId(spectatorId)
				if spectator then
					local newTarget = self:PickInitialTarget(spectator)
					self:SetSpectateTarget(spectator, newTarget)
				end
			end
		end
		self._spectateTargets[player.UserId] = nil
		self:_replicateTargets()
	end)
end

return SpectateService
