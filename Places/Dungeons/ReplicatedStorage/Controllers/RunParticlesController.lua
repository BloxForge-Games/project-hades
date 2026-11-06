--!strict
--[[
	Module: Controllers/RunParticlesController.lua
	Description:
	The sprint smoke under the local character (2026-11-05 rewrite). The
	SINGLE writer of RunParticlesToggle: every CHECK_SECONDS it decides
	whether the smoke should be on -- standing on the ground (not seated)
	and either RUNNING (moving at the full walk speed; a swing or a shot
	slows the walk, and that is not running) or mid-dodge (a dodge moves the
	body by CFrame, so the humanoid reads still) -- and sends only a CHANGE.
	Each new character asks the server for its smoke part
	(RunParticlesCreate) and starts from off.

	It used to toggle on speed thresholds and state changes while the dodge
	toggled it too, so the smoke went missing: a character that loaded after
	the one creation request had no part, a dodge's "off" stuck while still
	running, and a jump's "off" never came back on landing.

	A Blitz module depending on PlayerEventController.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local PlayerNetwork = require(ReplicatedStorage.Submodules.Core.Source.Network.Player)
local Janitor = require(ReplicatedStorage.Submodules.Core.Packages.Janitor)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local PlayerEventController = require(ReplicatedStorage.Submodules.Core.Source.Controllers.PlayerEventController)
local HumanoidProperties = require(ReplicatedStorage.Submodules.Core.Shared.Data.HumanoidProperties)
local GameClock = require(ReplicatedStorage.Submodules.Core.Shared.GameClock)

-- How often the smoke's state is re-decided.
local CHECK_SECONDS = 0.1
-- MoveDirection above this counts as moving.
local MOVE_THRESHOLD = 0.1
-- Running is walking at (about) the full walk speed: an attack's slow, a
-- bow's or a sword's walkSpeed, sits well under this.
local RUN_SPEED = HumanoidProperties.WalkSpeed - 1

local RunParticlesController = {
	Name = "RunParticlesController",
	Dependencies = { PlayerEventController } :: { any },

	particlesEnabled = false :: boolean,
	_janitor = Janitor.new() :: any,
}

local function shouldSmoke(character: Model, humanoid: Humanoid): boolean
	if humanoid.Health <= 0 or humanoid.Sit then
		return false
	end
	if humanoid.FloorMaterial == Enum.Material.Air then
		return false
	end
	if character:GetAttribute(Attributes.IsDodging) == true then
		return true
	end
	-- The walk speed the game meant: slow motion scales the real one and
	-- publishes the unscaled value (TimeScaleController).
	local walkSpeed = humanoid.WalkSpeed
	local unscaled = character:GetAttribute("WalkSpeedUnscaled")
	if GameClock.Scale() < 1 and type(unscaled) == "number" then
		walkSpeed = unscaled
	end
	return humanoid.MoveDirection.Magnitude > MOVE_THRESHOLD and walkSpeed >= RUN_SPEED
end

function RunParticlesController._set(self: typeof(RunParticlesController), enabled: boolean)
	if self.particlesEnabled == enabled then
		return
	end
	self.particlesEnabled = enabled
	PlayerNetwork.RunParticlesToggle.Fire(enabled)
end

function RunParticlesController.Start(self: typeof(RunParticlesController))
	PlayerEventController.OnCharacterLoaded:Connect(function(character: Model)
		self._janitor:Cleanup()
		-- A fresh character has no smoke part yet, and the server's emitter
		-- starts off: ask for the part and start from off.
		self.particlesEnabled = false
		PlayerNetwork.RunParticlesCreate.Fire()

		local humanoid = character:WaitForChild("Humanoid") :: Humanoid
		local sinceCheck = 0
		self._janitor:Add(RunService.Heartbeat:Connect(function(dt: number)
			sinceCheck += dt
			if sinceCheck < CHECK_SECONDS then
				return
			end
			sinceCheck = 0
			self:_set(shouldSmoke(character, humanoid))
		end))
	end)
end

return RunParticlesController
