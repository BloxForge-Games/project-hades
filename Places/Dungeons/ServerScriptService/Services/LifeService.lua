--!strict
--[[
     Module: LifeService.lua
     Description:
     Server-authoritative lives + death lifecycle (HARDCORE: death is
     permanent for the run — the paid revive flow was removed; dead
     players spectate until the run ends). Replaces Roblox's
     built-in Humanoid death entirely: DamageService clamps lethal damage to
     leave HP at 1 instead of 0, then calls LifeService:LoseLife. We never
     let Humanoid.Health reach 0, so Humanoid.Died never fires and the
     thousand systems that assume the character is alive don't break.
]]

--[ Roblox Services ]--

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeleportService = game:GetService("TeleportService")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

--[ Exports & Types & Defaults ]--

local PlayerEventService = require(ServerScriptService.Submodules.Core.Source.Services.PlayerEventService)
local TextIndicatorService = require(ServerScriptService.Submodules.Core.Source.Services.TextIndicatorService)
local InvulnerabilityService = require(ServerScriptService.Services.InvulnerabilityService)
local UserNotificationService = require(ServerScriptService.Submodules.Core.Source.Services.UserNotificationService)
local RagdollService = require(ServerScriptService.Services.RagdollService)
local PlayerNetwork = require(ServerScriptService.Submodules.Core.Source.Network.Player)
local RemoteProperty = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Network.RemoteProperty)
local Signal = require(ReplicatedStorage.Submodules.Core.Packages.Signal)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local DungeonData = require(ReplicatedStorage.Submodules.Core.Shared.Data.DungeonData)
local Constants = require(ReplicatedStorage.Submodules.Core.Shared.Data.Constants)

-- DungeonService requires this module at load, so this side reaches it
-- lazily: required on first use, once both modules exist.
local dungeonServiceLazy: any = nil
local function getDungeonService(): any
	if dungeonServiceLazy == nil then
		dungeonServiceLazy = (require :: any)(ServerScriptService.Services.DungeonService)
	end
	return dungeonServiceLazy
end

local LifeService = {
	Name = "LifeService",
	Dependencies = {
		PlayerEventService,
		TextIndicatorService,
		InvulnerabilityService,
		UserNotificationService,
		RagdollService,
	} :: { any },
}

-- Per-player lives snapshot, replicated to ALL clients (was a replicated
-- property): { [userId] = { current: number, max: number } }
LifeService._livesProperty = RemoteProperty.Server({
	changed = PlayerNetwork.LivesDataChanged,
	get = PlayerNetwork.GetLivesData,
}, {})

-- Per-player death snapshot, replicated to ALL clients (was a replicated
-- property): { [userId] = { diedAtServerTime, deathPosition, player } }
LifeService._deathStateProperty = RemoteProperty.Server({
	changed = PlayerNetwork.DeathStateChanged,
	get = PlayerNetwork.GetDeathState,
}, {})

-- Whole party down. Server-side only: no client ever read the old
-- GameOverState property, the GameOver broadcast is what they act on.
LifeService._isGameOver = false

--[ Constants ]--

local POST_LIFE_LOSS_INVULN_SECONDS = 3
local DEFAULT_LIVES = 1
local DEATH_ANIMATION_ID = "rbxassetid://73249560309673"
local DEATH_ANIMATION_KEYFRAME_MARKER = "PauseKeyframe"
local ALL_DEAD_TELEPORT_DELAY = 6

-- Paid revive (restored after the pure-hardcore pass). The dev product is
-- prompted server-side only, and ProcessReceipt is the sole caller of
-- :Revive -- there is no free path back from the death state.
local REVIVE_CUTSCENE_DURATION = 4
local FADE_DURATION = 0.4
local REVIVE_PRODUCT_ID = 3598188186

--[ Properties ]--

LifeService._lives = {} :: { [number]: { current: number, max: number } }
LifeService._deathState = {} :: {
	[number]: {
		diedAtClock: number,
		diedAtServerTime: number,
		deathPosition: Vector3,
	},
}
LifeService._deathAnimationTracks = {} :: { [number]: AnimationTrack }
LifeService._lobbyTeleportToken = nil :: any

LifeService.OnLifeLost = Signal.new() -- (player)
LifeService.OnPlayerDied = Signal.new() -- (player)
LifeService.OnPlayerRevived = Signal.new() -- (player)

--[ Private helpers ]--

-- Publishes the current LivesData snapshot to clients.
function LifeService._replicateLives(self: typeof(LifeService))
	local snapshot = {}
	for userId, entry in self._lives do
		snapshot[userId] = { current = entry.current, max = entry.max }
	end
	self._livesProperty:Set(snapshot)
end

function LifeService._replicateDeathState(self: typeof(LifeService))
	local snapshot = {}
	for userId, entry in self._deathState do
		snapshot[userId] = {
			diedAtServerTime = entry.diedAtServerTime,
			deathPosition = entry.deathPosition,
			player = Players:GetPlayerByUserId(userId),
		}
	end
	self._deathStateProperty:Set(snapshot)
end

function LifeService._playDeathAnimation(self: typeof(LifeService), player: Player)
	local userId = player.UserId

	self:_stopDeathAnimation(userId)

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		return
	end

	local animation = Instance.new("Animation")
	animation.AnimationId = DEATH_ANIMATION_ID

	local track = animator:LoadAnimation(animation)
	track.Priority = Enum.AnimationPriority.Action4
	track.Looped = false

	track:GetMarkerReachedSignal(DEATH_ANIMATION_KEYFRAME_MARKER):Connect(function()
		if track.IsPlaying then
			track:AdjustSpeed(0)

			task.delay(8, function()
				self:_stopDeathAnimation(userId)
			end)
		end
	end)

	track:Play()
	track:AdjustSpeed(0.35)
	self._deathAnimationTracks[userId] = track
end

-- Stops the death animation for `userId` if one is active. Idempotent.
function LifeService._stopDeathAnimation(self: typeof(LifeService), userId: number)
	local track = self._deathAnimationTracks[userId]
	if not track then
		return
	end
	track:Stop(0)
	track:Destroy()
	self._deathAnimationTracks[userId] = nil
end

-- True iff every player currently in the server is in death state. Returns
-- false on an empty server so a teleport never fires when nobody's even here
-- (defensive — the scheduling path can only run from inside LoseLife so the
-- caller is always in the player list anyway).
function LifeService._areAllPlayersDead(self: typeof(LifeService)): boolean
	local players = Players:GetPlayers()
	if #players == 0 then
		return false
	end
	for _, player in players do
		if not self._deathState[player.UserId] then
			return false
		end
	end
	return true
end

-- Fires OnTeleportToLobby (clients dismiss spectate / fade / cinematic UI),
-- waits a short grace period, then TeleportAsyncs every player to the lobby
-- place. pcall'd because TeleportService throws if the place isn't published
-- or the studio session isn't set up for cross-place teleport — we want a
-- warn, not a crashed service.
--
-- Public so other services (DungeonService on Boss defeat, etc.) can drive
-- the lobby teleport without duplicating the OnTeleportToLobby fire +
-- TeleportAsync + pcall scaffolding. The party-wipe path that originally
-- owned this method now goes through the public name too.
function LifeService.TeleportAllToLobby(_self: typeof(LifeService))
	local players = Players:GetPlayers()

	if #players == 0 then
		return
	end

	PlayerNetwork.TeleportToLobby.FireAll()

	-- Re-fetch in case anyone left during the grace window. TeleportAsync
	-- on an empty list throws.
	players = Players:GetPlayers()
	if #players == 0 then
		return
	end

	local ok, err = pcall(function()
		TeleportService:TeleportAsync(Constants.LOBBY_PLACE_ID, players)
	end)
	if not ok then
		warn(("[LifeService] Lobby teleport failed: %s"):format(tostring(err)))
	end
end

-- ONE player to the lobby place -- the run-loop ExitPortal (extraction).
-- The rest of the server keeps running. Fires the same client
-- OnTeleportToLobby cue for that player.
-- Returns true if the teleport was ISSUED (Studio can't teleport at all, so
-- callers must be able to tell and not strand the player).
function LifeService.TeleportPlayerToLobby(_self: typeof(LifeService), player: Player): boolean
	if not player or not player.Parent then
		return false
	end
	if RunService:IsStudio() then
		warn(
			("[LifeService] Studio: lobby teleport for %s skipped (TeleportAsync is unavailable in Studio)"):format(
				player.Name
			)
		)
		return false
	end
	PlayerNetwork.TeleportToLobby.Fire(player)
	local ok, err = pcall(function()
		TeleportService:TeleportAsync(Constants.LOBBY_PLACE_ID, { player })
	end)
	if not ok then
		warn(("[LifeService] Lobby teleport failed for %s: %s"):format(player.Name, tostring(err)))
		return false
	end
	return true
end

-- Schedules the all-dead lobby teleport. Token-stamped so:
--   1. A re-schedule (another LoseLife while one is pending) supersedes the
--      old token, leaving the prior callback to abort harmlessly
--   2. The "are still all dead?" re-check at fire time handles the rare race
--      where a player joins mid-window (joiners aren't in death state, so
--      _areAllPlayersDead returns false → teleport aborts)
function LifeService._scheduleLobbyTeleport(self: typeof(LifeService))
	local token = {}
	self._lobbyTeleportToken = token

	task.delay(ALL_DEAD_TELEPORT_DELAY, function()
		if self._lobbyTeleportToken ~= token then
			return -- cancelled by revive or superseded by re-schedule
		end
		if not self:_areAllPlayersDead() then
			return -- party-wipe condition no longer holds (rare: late joiner)
		end
		self._lobbyTeleportToken = nil
		-- DEBUG (2026-09): the party-wipe lobby teleport is disabled so a
		-- wiped party stays in the dungeon for inspection. Restore the
		-- call below to re-enable it.
		warn("[LifeService] Party wiped -- lobby teleport disabled for debugging (see _scheduleLobbyTeleport)")
		-- self:TeleportAllToLobby()
	end)
end

--[ Public API ]--

-- Seeds (or resets) a player's lives to `max`. Called by DungeonService on
-- dungeon generation, and by OnPlayerAdded for late-joiners. Idempotent.
function LifeService.InitializePlayer(self: typeof(LifeService), player: Player, max: number)
	local userId = player.UserId
	self._lives[userId] = { current = max, max = max }
	self:_replicateLives()
end

-- Returns (current, max). Both zero if the player isn't registered yet.
function LifeService.GetLives(self: typeof(LifeService), player: Player): (number, number)
	local entry = self._lives[player.UserId]
	if not entry then
		return 0, 0
	end
	return entry.current, entry.max
end

-- True when the player is in the death state (downed, awaiting revive).
function LifeService.IsDeathState(self: typeof(LifeService), player: Player): boolean
	return self._deathState[player.UserId] ~= nil
end

-- Where the player's HumanoidRootPart was when they entered the death
-- state, for callers that need the corpse's spot after the character is
-- gone (RunEscrowService spills run gear there). nil when not in the
-- death state, or when no root part could be read at the time of death.
function LifeService.GetDeathPosition(self: typeof(LifeService), player: Player): Vector3?
	local state = self._deathState[player.UserId]
	if not state or state.deathPosition == Vector3.zero then
		return nil
	end
	return state.deathPosition
end

-- Alias for IsDeathState — no longer distinguishes "in window" vs "fully
-- dead" since there's no timed window anymore. Kept for any external
-- code that still calls IsFullyDead.
function LifeService.IsFullyDead(self: typeof(LifeService), player: Player): boolean
	return self:IsDeathState(player)
end

-- Called by DamageService when damage would have killed the player.
-- Decrements lives and either restores HP in place (lives left) or
-- transitions to the death state (no lives left).
function LifeService.LoseLife(self: typeof(LifeService), player: Player)
	local userId = player.UserId
	local entry = self._lives[userId]
	if not entry then
		warn(("[LifeService] LoseLife called for unregistered player %s"):format(player.Name))
		return
	end

	-- Already dead — don't double-decrement on lingering hits while ragdolled.
	if self._deathState[userId] then
		return
	end

	entry.current = math.max(entry.current - 1, 0)
	self:_replicateLives()

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")

	if entry.current > 0 then
		local head = character and character:FindFirstChild("Head") :: BasePart?
		if TextIndicatorService and head then
			if entry.current == 1 then
				TextIndicatorService:ShowIndicator(player, head, "Last Life!", Color3.fromRGB(255, 74, 74))
			else
				TextIndicatorService:ShowIndicator(player, head, "Death Defied!", Color3.fromRGB(85, 255, 127))
			end
		end

		-- Still has lives — full HP restore + brief i-frames.
		if humanoid then
			humanoid.Health = humanoid.MaxHealth
		end

		-- ApplyTo itself no-ops on a nil character; the guard only narrows the type.
		if character then
			-- "Combat": earned in play, so the white highlight shows.
			InvulnerabilityService:ApplyTo(character, POST_LIFE_LOSS_INVULN_SECONDS, "Combat")
		end

		self.OnLifeLost:Fire(player)
		PlayerNetwork.LifeLost.FireAll(userId)
		print(("[LifeService] %s lost a life. Remaining: %d/%d"):format(player.Name, entry.current, entry.max))
		return
	end

	-- Out of lives. Enter death state. Ragdoll + Attributes.Death=true
	-- happen immediately; the client orchestrates the visual fade-into-
	-- spectate sequence based on OnPlayerDied + the DeathState property.
	if character then
		character:SetAttribute(Attributes.Death, true)
	end

	local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local deathPosition = (hrp and hrp.Position) or Vector3.zero

	local deathClock = os.clock()
	self._deathState[userId] = {
		diedAtClock = deathClock,
		diedAtServerTime = workspace:GetServerTimeNow(),
		deathPosition = deathPosition,
	}

	self:_replicateDeathState()

	local isWipe = self:_areAllPlayersDead()

	if isWipe then
		self._isGameOver = true
	end

	-- isWipe rides the server signal too: RunEscrowService keeps a dead
	-- player's run loot for a possible revive and discards it only when
	-- the whole party is down.
	self.OnPlayerDied:Fire(player, isWipe)
	PlayerNetwork.PlayerDied.FireAll({ UserId = userId, IsWipe = isWipe })

	if isWipe then
		PlayerNetwork.GameOver.FireAll()
	end

	if TextIndicatorService and character then
		local currentState = self._deathState[userId]
		if not currentState or currentState.diedAtClock ~= deathClock then
			return
		end

		RagdollService:Unragdoll(character)

		-- if RagdollService and character and character.Parent then
		-- 	RagdollService:Ragdoll(character)
		-- end

		for _, playerIndex in pairs(Players:GetPlayers()) do
			if player == playerIndex then
				continue
			end

			UserNotificationService:RequestUserNotification(playerIndex, {
				titleText = "Eternal Damnation",
				titleTextFont = Enum.Font.SourceSansBold,
				titleTextColor3 = Color3.fromRGB(252, 83, 83),
				titleTextTransparency = 0,

				text = player.Name .. " was claimed by the Spire.",
				textFont = Enum.Font.SourceSansBold,
				textColor3 = Color3.fromRGB(255, 255, 255),
				textTransparency = 0,
			})
		end

		self:_playDeathAnimation(player)

		local head = character:FindFirstChild("Head") :: BasePart?
		if head then
			TextIndicatorService:ShowIndicator(player, head, "Eternally Damned!", Color3.fromRGB(247, 67, 67))
		end
	end

	if isWipe then
		print(
			("[LifeService] Party wipe detected — lobby teleport scheduled in %.2fs"):format(ALL_DEAD_TELEPORT_DELAY)
		)
		self:_scheduleLobbyTeleport()
	end

	print(("[LifeService] %s fully died — spectate engaged"):format(player.Name))
end

-- Increments lives, capped at max. Use for relic/event grants.
function LifeService.AddLife(self: typeof(LifeService), player: Player)
	local entry = self._lives[player.UserId]
	if not entry then
		return
	end
	entry.current = math.min(entry.current + 1, entry.max)
	self:_replicateLives()
end

-- Paid revive, restored. Full sequence: fade to black, un-ragdoll,
-- teleport to the spectated party's current room, restore health, fade
-- back, invuln window, clear death state, lives back to 1. ONLY
-- ProcessReceipt calls this.
--
-- Escrow note: RunEscrowService discarded this player's run items and
-- coins the moment they entered the death state. Revive does NOT restore
-- them -- you buy your way back to your feet, not your loot back.
function LifeService.Revive(self: typeof(LifeService), player: Player)
	local userId = player.UserId
	if not self._deathState[userId] then
		return
	end
	print(("[LifeService] %s revive sequence starting"):format(player.Name))

	-- Cancel a pending all-dead lobby teleport and clear Game Over if the
	-- wipe screen already went up -- a revive un-wipes the party.
	self._lobbyTeleportToken = nil

	self._isGameOver = false

	PlayerNetwork.RevivalFade.Fire(player, { Phase = "in", Duration = FADE_DURATION })

	for _, playerIndex in pairs(Players:GetPlayers()) do
		UserNotificationService:RequestUserNotification(playerIndex, {
			titleText = "Player Revive",
			titleTextFont = Enum.Font.SourceSansBold,
			titleTextColor3 = Color3.fromRGB(85, 255, 127),
			titleTextTransparency = 0,

			text = player.Name .. " has been revived!",
			textFont = Enum.Font.SourceSansBold,
			textColor3 = Color3.fromRGB(255, 255, 255),
			textTransparency = 0,
		})
	end

	task.wait(FADE_DURATION)

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")

	self:_stopDeathAnimation(userId)

	if RagdollService and character then
		RagdollService:Unragdoll(character)
	end

	if character and getDungeonService() then
		local room = getDungeonService():GetPlayerRoom(player)
		if room and room.model and room.model.PrimaryPart then
			character:PivotTo(CFrame.new(room.model.PrimaryPart.Position + Vector3.new(0, 5, 0)))
		end
	end

	if humanoid then
		humanoid.Health = humanoid.MaxHealth
	end

	PlayerNetwork.RevivalFade.Fire(player, { Phase = "out", Duration = FADE_DURATION })

	self.OnPlayerRevived:Fire(player)
	PlayerNetwork.PlayerRevived.FireAll(userId)

	if character then
		-- Two windows, not one: the revive cinematic is a Cutscene (no
		-- highlight; the fade and the stand-up are the feedback) and the
		-- grace after it is Combat (highlight on, like a life loss). The
		-- service keeps the UNION open, so the cutscene window closing never
		-- cuts the grace short, and the reason flips to Combat the moment
		-- only the grace remains.
		InvulnerabilityService:ApplyTo(character, REVIVE_CUTSCENE_DURATION, "Cutscene")
		InvulnerabilityService:ApplyTo(character, REVIVE_CUTSCENE_DURATION + POST_LIFE_LOSS_INVULN_SECONDS, "Combat")
	end

	task.wait(REVIVE_CUTSCENE_DURATION)

	if character then
		character:SetAttribute(Attributes.Death, false)
	end

	local entry = self._lives[userId]
	if entry then
		-- Stand up at lives = 1. Next death = same flow.
		entry.current = 1
		self:_replicateLives()
	end

	self._deathState[userId] = nil
	self:_replicateDeathState()

	print(("[LifeService] %s revived. Lives reset to 1."):format(player.Name))
end

--[ Lifecycle ]--

function LifeService.Start(self: typeof(LifeService))
	PlayerNetwork.PromptRevivePurchase.On(function(player: Player)
		self:_onPromptRevivePurchase(player)
	end)

	if getDungeonService() and getDungeonService().Signals and getDungeonService().Signals.OnDungeonGenerated then
		getDungeonService().Signals.OnDungeonGenerated:Connect(function(dungeon)
			-- Lives are PER RUN: seeded when the run's FIRST dungeon generates and
			-- carried across dungeons 2 / 3 -- a later dungeon must not refill them.
			if getDungeonService().GetRunDungeonIndex and getDungeonService():GetRunDungeonIndex() > 1 then
				return
			end
			local dungeonConfig = DungeonData[dungeon.id]
			local difficultyConfig = dungeonConfig and dungeonConfig.difficulties[dungeon.difficulty]
			local maxLives = (difficultyConfig and difficultyConfig.freeRevives) or DEFAULT_LIVES

			for _, player in Players:GetPlayers() do
				self:InitializePlayer(player, maxLives)
			end
		end)
	end

	PlayerEventService.OnPlayerAdded:Connect(function(player: Player)
		local maxLives = DEFAULT_LIVES
		if getDungeonService() then
			local active = getDungeonService():GetActiveDungeon()
			if active then
				local dungeonConfig = DungeonData[active.id]
				local difficultyConfig = dungeonConfig and dungeonConfig.difficulties[active.difficulty]
				if difficultyConfig and difficultyConfig.freeRevives then
					maxLives = difficultyConfig.freeRevives
				end
			end
		end
		self:InitializePlayer(player, maxLives)
	end)

	PlayerEventService.OnPlayerRemoved:Connect(function(player: Player)
		local userId = player.UserId
		self._lives[userId] = nil
		self._deathState[userId] = nil
		self:_replicateLives()
		self:_replicateDeathState()
		self:_stopDeathAnimation(userId)
	end)

	MarketplaceService.ProcessReceipt = function(receiptInfo)
		if receiptInfo.ProductId ~= REVIVE_PRODUCT_ID then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
		if not player then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		-- Grant WITHOUT reviving if they somehow stood up already -- eating
		-- the robux on a no-op is worse than the refund dance, and Roblox
		-- retries NotProcessedYet receipts forever.
		if not self:IsDeathState(player) then
			warn(("[LifeService] Revive receipt for %s but they're not in death state"):format(player.Name))
			return Enum.ProductPurchaseDecision.PurchaseGranted
		end

		self:Revive(player)
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
end

--[ Client-callable API ]--

-- Client requests the revive purchase prompt. Server-initiated so the dev
-- product flow can't be spoofed; validates the player is actually downed
-- before prompting.
function LifeService._onPromptRevivePurchase(self: typeof(LifeService), player: Player)
	if not self:IsDeathState(player) then
		warn(("[LifeService] %s tried to prompt revive but isn't downed"):format(player.Name))
		return
	end
	MarketplaceService:PromptProductPurchase(player, REVIVE_PRODUCT_ID)
end

return LifeService
