--[[
     Author(s): ryanisawesome25
     Module: Trap.luau
     Description: Spike trap that damages ANY humanoid entity (zombies and
                  players, including the player who built it) walking over
                  it. Uses ZonePlus for zone detection. Plays a spike
                  extension animation on trigger, then enters a cooldown.

                  Ownership: traps may carry an OwnerId attribute (set by
                  BuildService for player-built traps) OR have no owner at
                  all (set by the chunk system for dungeon-room traps —
                  these are pre-tagged 'Trap' inside Combat chunks and
                  auto-instantiate when the chunk parents into workspace).
                  Owner is used only for kill attribution against zombies;
                  it does NOT exempt the owner from self-damage. Traps are
                  now pure hazards, not friendly builds.
]]

--[ Exports & Types & Defaults ]--

--[ Roblox Services ]--

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--[ Imports ]--

local Component = require(ReplicatedStorage.Submodules.Core.Packages.Component)
local Janitor = require(ReplicatedStorage.Submodules.Core.Packages.Janitor)
local Zone = require(ReplicatedStorage.Submodules.Core.Packages.ZonePlus)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local CommAdder = require(ReplicatedStorage.Submodules.Core.Source.ComponentExtensions.CommAdder)
local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)

local DamageIndicatorService
local DamageService

Knit.OnStart():andThen(function()
	DamageService = Knit.GetService("DamageService")
	DamageIndicatorService = Knit.GetService("DamageIndicatorService")
end)

--[ Component Root ]--

local Trap = Component.new({
	Tag = "Trap",

	Extensions = { CommAdder },
})

--[ Constants ]--

local TRAP_COOLDOWN = 5
local DETECTION_HEIGHT = 10
local TRAP_DELAY = 0.1
-- Every trap hit costs 20% of the VICTIM's own maximum health, so five
-- steps kill anything that can step on one — a player, a zombie, or a
-- boss with fifty times their health. A flat number could not do that:
-- it was either irrelevant to a boss or lethal to a player.
--
-- Deliberately NOT scaled by anything. Both call sites below take the
-- unmitigated path, because a trap that five steps kill for one build
-- and ten for another is no longer a rule the player can learn.
local TRAP_MAX_HEALTH_FRACTION = 0.20

--[ Private Functions ]--

--[ Public Functions ]--

-- Triggered when ANY tracked entity (zombie or player character)
-- enters the trap zone. Iterates everything currently inside and
-- damages each humanoid once, then enters the cooldown — so a row
-- of mobs walking onto the same trap during a single tick all take
-- the hit on this proc.
function Trap:_onEntityEntered()
	if self._onCooldown then
		return
	end
	-- A COMPLETED room's traps are scenery: no spikes, no damage, on the
	-- way back through a cleared chamber or while looting an arena.
	if self.Instance:GetAttribute(Attributes.TrapDisabled) == true then
		return
	end

	self._onCooldown = true

	task.delay(TRAP_DELAY, function()
		self._spikeSound:Play()

		local entitiesInZone = 0

		for _, model in self._zone:getItems() do
			if not model or not model.Parent then
				continue
			end
			local humanoid = model:FindFirstChildOfClass("Humanoid")

			if not humanoid or humanoid.Health <= 0 then
				continue
			end

			entitiesInZone += 1

			-- Per victim, not per trap: the fraction is of THIS humanoid's
			-- maximum health.
			local damage = humanoid.MaxHealth * TRAP_MAX_HEALTH_FRACTION

			local victimPlayer = Players:GetPlayerFromCharacter(model)

			if victimPlayer then
				-- `~= true`, NOT `== false`: the attribute is only ever written by
				-- DodgeService (true at dodge start, false at dodge end), so a
				-- fresh character carries nil until its first dodge — and
				-- `nil == false` is false, which made traps silently skip a
				-- player for their whole first life. Missing must mean "not
				-- dodging", the way ZombieService already reads it.
				if model:GetAttribute(Attributes.IsDodging) ~= true then
					-- `true`: fixed damage, so no relic or set bonus can turn
					-- five steps into ten.
					DamageService:PlayerTakeDamage(victimPlayer, self.Instance, damage, false, true)
					DamageIndicatorService:ShowIndicator(victimPlayer, humanoid.Parent, math.round(damage), false)
				end
			else
				if self._player then
					DamageService:TakeDamage(self._player, humanoid, damage, false, true, false, false, true)
				else
					-- CONTINUE, not return: an invulnerable mob standing on the
					-- trap used to abort the whole proc, sparing everything
					-- else in the zone along with it.
					if humanoid.Parent:GetAttribute(Attributes.Invulnerable) == true then
						continue
					end
					humanoid:TakeDamage(damage)

					for _, player in Players:GetPlayers() do
						-- if humanoid.Health <= 0 then
						-- 	TextIndicatorService:ShowIndicator(
						-- 		player,
						-- 		humanoid.Parent.HumanoidRootPart,
						-- 		"Trap Killed!",
						-- 		Color3.fromRGB(247, 67, 67),
						-- 		true
						-- 	)
						-- end

						DamageIndicatorService:ShowIndicator(player, humanoid.Parent, math.round(damage), false)
					end
				end
			end
		end

		if entitiesInZone == 0 then
			self._onCooldown = false
			return
		end

		self._onSpikesTriggered:FireAll(self.Instance)

		task.delay(TRAP_COOLDOWN, function()
			self._onCooldown = false

			if #self._zone:getItems() > 0 then
				self:_onEntityEntered()
			end
		end)
	end)
end

--[ Initializers ]--

function Trap:Construct()
	self._janitor = Janitor.new()
	self._onCooldown = false
	self._player = Players:GetPlayerByUserId(self.Instance:GetAttribute(Attributes.OwnerId) or -1)

	self._onSpikesTriggered = self._comm:CreateSignal("OnSpikesTriggered")
end

function Trap:Start()
	-- Trigger region resolution.
	--   * If the trap model has a child BasePart named "BoundingBox",
	--     use its CFrame + Size as the zone. Dungeon-chunk traps ship
	--     with a precisely-sized BoundingBox part for exactly this
	--     purpose — Model:GetBoundingBox() would otherwise return the
	--     union of every descendant (Base plate, CollisionBox, the
	--     inner spike Model, etc.) which can be much wider/taller
	--     than the intended trigger volume.
	--   * Player-built traps don't ship with a BoundingBox child, so
	--     fall back to Model:GetBoundingBox() — preserves the legacy
	--     behavior for BuildService-spawned traps with no regression.
	local boundCFrame: CFrame, boundSize: Vector3
	local boundingBoxPart = self.Instance:FindFirstChild("BoundingBox")
	if boundingBoxPart and boundingBoxPart:IsA("BasePart") then
		boundCFrame = boundingBoxPart.CFrame
		boundSize = boundingBoxPart.Size
	else
		boundCFrame, boundSize = self.Instance:GetBoundingBox()
	end

	self._spikeSound = ReplicatedStorage.GameAssets.Sounds.SpikeTrap:Clone()
	self._spikeSound.Parent = self.Instance.PrimaryPart

	self._zone = Zone.fromRegion(
		boundCFrame * CFrame.new(0, DETECTION_HEIGHT / 2, 0),
		boundSize + Vector3.new(0, DETECTION_HEIGHT, 0)
	)

	-- ── Zombie tracking (existing) ─────────────────────────────
	for _, zombie in ipairs(CollectionService:GetTagged(TagList.Zombie)) do
		self._zone:trackItem(zombie)
	end

	self._janitor:Add(CollectionService:GetInstanceAddedSignal(TagList.Zombie):Connect(function(zombie)
		self._zone:trackItem(zombie)
	end))

	self._janitor:Add(CollectionService:GetInstanceRemovedSignal(TagList.Zombie):Connect(function(zombie)
		self._zone:untrackItem(zombie)
	end))

	-- ── Player character tracking (new) ────────────────────────
	-- Players don't have a CollectionService tag, so we follow
	-- CharacterAdded/Removing per-player. A small helper makes the
	-- per-player wiring legible — keeps the Add/Removed connections
	-- + initial-character handling in one place.
	local function bindPlayer(player: Player)
		if player.Character then
			self._zone:trackItem(player.Character)
		end
		self._janitor:Add(player.CharacterAdded:Connect(function(character)
			self._zone:trackItem(character)
		end))
		self._janitor:Add(player.CharacterRemoving:Connect(function(character)
			self._zone:untrackItem(character)
		end))
	end

	for _, player in Players:GetPlayers() do
		bindPlayer(player)
	end

	self._janitor:Add(Players.PlayerAdded:Connect(bindPlayer))

	-- ── Trigger ────────────────────────────────────────────────
	self._zone.itemEntered:Connect(function()
		self:_onEntityEntered()
	end)

	self._janitor:Add(function()
		self._zone:destroy()
	end)
end

function Trap:Stop()
	self._janitor:Cleanup()
end

return Trap
