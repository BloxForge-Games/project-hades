--[[
	Module: FogOfWarController.lua
	Description:
	LOCAL re-fog of dungeon chunks the player has left for good. The server
	fog (FogOfWarService) reveals a chunk for everyone on first entry and
	never hides it again; this controller darkens it again on THIS client
	only, once the player is through and the way back is shut:

	  * Gate crossing  -- the exit gate sealed behind them (the server's
	                      per-player OnGateCrossed). Fog lands one beat
	                      after the local slam tween ends.
	  * Arena intro    -- the encounter intro pulled the party into the
	                      Miniboss / Boss arena. Fog lands one beat after
	                      the fade-to-black has them inside.

	WHAT GOES: exactly the set the server fog hid at generation, from the
	shared rules in Shared/Functions/Dungeon/fogHideables -- props, torches,
	traps, lights, particles, prompts, sounds, GUIs, and the chunk's
	relocated pillars. Floor, walls and the sealed gate stay, so the room
	behind still reads as a room. Loot and machines left behind live
	outside the chunk model and are untouched (per design).

	HOW: numeric properties tween to their hidden value over FADE_SECONDS
	(the reveal in reverse); booleans flip off at the start of the fade.
	Nothing is cached -- a re-fogged chunk never comes back (the way back
	is sealed), and the floor's models are destroyed on the next
	generation, which is the only reset. `_fogged` is weak-keyed for the
	same reason.

	Every fogged room / building model is stamped Attributes.LocalFogged
	(client-only attribute) so BuildingTransparencyController leaves its
	pillars alone instead of "restoring" them to the fog value.
]]

--[ Roblox Services ]--

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

--[ Imports ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local fogHideables = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Dungeon.fogHideables)

local FogOfWarService
local DungeonGateController

--[ Constants ]--

-- The fade-out. Mirrors FogOfWarService's REVEAL_SECONDS in reverse.
local FADE_SECONDS = 1
local FADE_TWEEN_INFO = TweenInfo.new(FADE_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- Server-side fog caches (FogOfWarService). An instance still carrying
-- one is hidden by the server already; touching it here would fight the
-- reveal that is about to tween it.
local SERVER_FOG_NUMBER_ATTRIBUTE = "FogValue"
local SERVER_FOG_BOOLEAN_ATTRIBUTE = "FogEnabled"

--[ Controller ]--

local FogOfWarController = Knit.CreateController({
	Name = "FogOfWarController",
	-- [Model] = true for every room / building model already re-fogged.
	-- Weak keys: destroyed floors drop out on their own.
	_fogged = setmetatable({}, { __mode = "k" }),
})

--[ Private ]--

-- Hides ONE instance locally: numeric properties tween to their hidden
-- value, booleans flip off now.
local function hideLocally(instance: Instance)
	if
		instance:GetAttribute(SERVER_FOG_NUMBER_ATTRIBUTE) ~= nil
		or instance:GetAttribute(SERVER_FOG_BOOLEAN_ATTRIBUTE) ~= nil
	then
		return
	end

	local property = fogHideables.numericProperty(instance)
	if property then
		TweenService:Create(instance, FADE_TWEEN_INFO, { [property] = fogHideables.hiddenValue(property) }):Play()
		return
	end

	if fogHideables.isBooleanHidden(instance) then
		(instance :: any).Enabled = false
	end
end

function FogOfWarController:_fogModel(model: Instance, hideables: { Instance })
	if self._fogged[model] or not model.Parent then
		return
	end
	self._fogged[model] = true
	model:SetAttribute(Attributes.LocalFogged, true)
	for _, instance in hideables do
		hideLocally(instance)
	end
end

-- The payload of one OnRoomsLeftBehind: every room model and relocated
-- building the server says is behind this player now. Idempotent per
-- model, so the server can resend the whole trail on every crossing.
function FogOfWarController:_onRoomsLeftBehind(payload)
	local rooms = payload and payload.rooms or {}
	local buildings = payload and payload.buildings or {}

	local delay = payload and payload.delaySeconds or 0
	if payload and payload.afterGateClose then
		-- The slam is this client's own tween; the beat starts when it lands.
		delay += DungeonGateController:GetGateSlamSeconds()
	end

	task.delay(delay, function()
		for _, roomModel in rooms do
			if roomModel:IsA("Model") and roomModel.Parent then
				self:_fogModel(roomModel, fogHideables.collectRoomHideables(roomModel))
			end
		end
		for _, building in buildings do
			if building.Parent then
				self:_fogModel(building, fogHideables.collectBuildingHideables(building))
			end
		end
	end)
end

--[ Lifecycle ]--

function FogOfWarController:KnitInit() end

function FogOfWarController:KnitStart()
	FogOfWarService = Knit.GetService("FogOfWarService")
	DungeonGateController = Knit.GetController("DungeonGateController")

	FogOfWarService.OnRoomsLeftBehind:Connect(function(payload)
		self:_onRoomsLeftBehind(payload)
	end)
end

return FogOfWarController
