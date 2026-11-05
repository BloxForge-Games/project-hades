--!strict
--[[
	Module: Controllers/BowStringController.lua
	Description:
	A bow's string, drawn and released with its shots (2026-11-05). Every
	bow in a character carries its string as two halves (Rope1Line,
	Rope2Line), each hung from an invisible anchor at a bow tip (Rope1,
	Rope2) by a Motor6D pivoting at that tip. This turns both halves back
	from their tips (Motor6D.Transform), so the string's middle pulls
	toward the archer:

	  a shot      the string SNAPS forward past rest (WOBBLE_DEGREES) and
	              settles, then draws back to DRAW_DEGREES over the rest of
	              the bow's fire interval (RangedWeaponData itemDelay), ready
	              for the next shot;
	  no shot     held drawn RELAX_AFTER_SECONDS past the interval, it eases
	              back to rest.

	Every client draws every player's bow off ProjectileCastController.Fired
	(the local player's shot at its prediction, others' as the server's copy
	arrives). Which way is "back" is worked out per motor from the bow's
	facing (its Handle's +X is where the arrow flies), so the rig's own axes
	never have to be authored a particular way.

	A Blitz module with no dependencies.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local ProjectileCastController =
	require(ReplicatedStorage.Submodules.Core.Libraries.ProjectileCast.ProjectileCastController)
local RangedWeaponData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RangedWeaponData)
local GameClock = require(ReplicatedStorage.Submodules.Core.Shared.GameClock)

local DRAW_DEGREES = 20
local WOBBLE_DEGREES = 5
local RELEASE_SECONDS = 0.06
local SETTLE_SECONDS = 0.12
-- The draw ends this long before the next shot can fire.
local DRAW_LEAD_SECONDS = 0.05
local RELAX_AFTER_SECONDS = 0.6
local RELAX_SECONDS = 0.25
-- The string anchors' names (each holds one half's Motor6D).
local ANCHOR_NAMES = { Rope1 = true, Rope2 = true }

local BowStringController = {
	Name = "BowStringController",
}

type StringMotor = { motor: Motor6D, sign: number }
type BowState = { motors: { StringMotor }, firedAt: number, interval: number, fromDegrees: number }

local bows: { [Model]: BowState } = {}
local stepConnection: RBXScriptConnection? = nil

local function smooth(alpha: number): number
	local t = math.clamp(alpha, 0, 1)
	return t * t * (3 - 2 * t)
end

-- +1 or -1: the turn about the motor's Z that swings its half's far end
-- toward the archer (against the bow's +X).
local function backSign(motor: Motor6D, forward: Vector3): number
	local part0, part1 = motor.Part0, motor.Part1
	if not part0 or not part1 then
		return 1
	end
	local farEnd = -motor.C1.Position
	local function farEndAt(radians: number): Vector3
		return (part0.CFrame * motor.C0 * CFrame.Angles(0, 0, radians) * motor.C1:Inverse()) * farEnd
	end
	local moved = (farEndAt(math.rad(10)) - farEndAt(0)):Dot(forward)
	return if moved > 0 then -1 else 1
end

local function stringMotorsOf(weapon: Model): { StringMotor }
	local handle = weapon:FindFirstChild("Handle")
	local forward = if handle and handle:IsA("BasePart") then handle.CFrame.RightVector else Vector3.xAxis
	local motors: { StringMotor } = {}
	for _, descendant in weapon:GetDescendants() do
		if descendant:IsA("Motor6D") and descendant.Parent and ANCHOR_NAMES[descendant.Parent.Name] then
			descendant.Transform = CFrame.identity
			table.insert(motors, { motor = descendant, sign = backSign(descendant, forward) })
		end
	end
	return motors
end

-- The string's angle (degrees back from rest) `elapsed` seconds after a
-- shot, and whether the cycle is over.
local function angleAt(state: BowState, elapsed: number): (number, boolean)
	if elapsed < RELEASE_SECONDS then
		return state.fromDegrees + (-WOBBLE_DEGREES - state.fromDegrees) * smooth(elapsed / RELEASE_SECONDS), false
	end
	elapsed -= RELEASE_SECONDS
	if elapsed < SETTLE_SECONDS then
		return -WOBBLE_DEGREES * (1 - smooth(elapsed / SETTLE_SECONDS)), false
	end
	local drawStart = RELEASE_SECONDS + SETTLE_SECONDS
	local drawSeconds = math.max(state.interval - drawStart - DRAW_LEAD_SECONDS, 0.1)
	elapsed -= SETTLE_SECONDS
	if elapsed < drawSeconds then
		return DRAW_DEGREES * smooth(elapsed / drawSeconds), false
	end
	elapsed -= drawSeconds
	if elapsed < RELAX_AFTER_SECONDS then
		return DRAW_DEGREES, false
	end
	elapsed -= RELAX_AFTER_SECONDS
	if elapsed < RELAX_SECONDS then
		return DRAW_DEGREES * (1 - smooth(elapsed / RELAX_SECONDS)), false
	end
	return 0, true
end

local function apply(state: BowState, degrees: number)
	for _, entry in state.motors do
		entry.motor.Transform = CFrame.Angles(0, 0, math.rad(degrees) * entry.sign)
	end
end

local function step()
	local now = GameClock.Now()
	for weapon, state in bows do
		if not weapon.Parent then
			bows[weapon] = nil
			continue
		end
		local degrees, done = angleAt(state, now - state.firedAt)
		apply(state, degrees)
		if done then
			bows[weapon] = nil
		end
	end
	if next(bows) == nil and stepConnection then
		stepConnection:Disconnect()
		stepConnection = nil
	end
end

function BowStringController._onFired(_self: typeof(BowStringController), ownerUserId: number, weaponName: string)
	local data = RangedWeaponData[weaponName]
	if not data or data.weaponType ~= "Bow" then
		return
	end
	local owner = Players:GetPlayerByUserId(ownerUserId)
	local weapon = owner and owner.Character and owner.Character:FindFirstChild(weaponName)
	if not weapon or not weapon:IsA("Model") then
		return
	end
	local state = bows[weapon]
	local now = GameClock.Now()
	if state then
		-- Mid-cycle: release from wherever the string is now.
		state.fromDegrees = (angleAt(state, now - state.firedAt))
	else
		state = { motors = stringMotorsOf(weapon), firedAt = now, interval = 0, fromDegrees = 0 }
		bows[weapon] = state
	end
	state.firedAt = now
	state.interval = tonumber(data.itemDelay) or 0.5
	if #state.motors == 0 then
		bows[weapon] = nil
		return
	end
	if not stepConnection then
		stepConnection = RunService.RenderStepped:Connect(step)
	end
end

function BowStringController.Start(self: typeof(BowStringController))
	ProjectileCastController.Fired:Connect(function(ownerUserId: number, weaponName: string)
		self:_onFired(ownerUserId, weaponName)
	end)
end

return BowStringController
