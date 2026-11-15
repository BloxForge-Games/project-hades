--!strict
--[[
	Module: EnchantmentScrollDrop.lua (Server-side component)
	Description:
	The pickup of an enchantment scroll on the floor (2026-11-14): the
	server half of the TagList.EnchantmentScrollDrop model that
	EnchantmentScrollService spawns. It mirrors Server/Components/GearDrop:

	  * The owner's client component fires DungeonNetwork.GearDropCollected
	    with this instance when the prompt is triggered. The scroll shares
	    the gear drop's event: InstanceRouter routes one event per
	    INSTANCE, so each class only ever hears its own models and no new
	    Blink event is needed.
	  * This component checks the player is alive, in reach and the owner
	    (Attributes.OwnerId), then EnchantmentScrollService:Grant adds the
	    scroll to the profile at once (gear banks at pickup too).
	  * On a grant it stamps CollectedById and Expired, which every client
	    watches, and destroys the model once the client fade has played.

	No expire timer: like gear, a scroll waits until it is taken or the
	floor is torn down (EnchantmentScrollService:ClearDrops).
]]

--[ Roblox Services ]--

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

--[ Imports ]--

local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local Component = require(ReplicatedStorage.Submodules.Core.Packages.Component)
local DungeonNetwork = require(ServerScriptService.Submodules.Core.Source.Network.Dungeon)
local EnchantmentScrollService = require(ServerScriptService.Services.EnchantmentScrollService)
local GameClock = require(ReplicatedStorage.Submodules.Core.Shared.GameClock)
local InstanceRouter = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Network.InstanceRouter)
local LifeService = require(ServerScriptService.Services.LifeService)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local withinPickupReach = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Drop.withinPickupReach)

--[ Constants ]--

-- Must match EnchantmentScrollService and the client component.
local ATTR_ENCHANTMENT = "ScrollEnchantment"
local ATTR_TIER = "ScrollTier"
local ATTR_EXPIRED = "Expired"

-- The client's prompt reaches 5 studs; this is that with margin for the
-- trigger's latency (the gear drop's reach).
local PICKUP_REACH = 20
-- The client fade (0.5 s) plus a margin.
local POST_FADE_DESTROY_DELAY = 0.65

-- The gear drop's router: one per event, shared by both classes.
local collectedRouter = InstanceRouter.Server(DungeonNetwork.GearDropCollected)

--[ Component ]--

local EnchantmentScrollDrop = Component.new({
	Tag = TagList.EnchantmentScrollDrop,
})

function EnchantmentScrollDrop:Construct()
	-- Set on the grant, so a second trigger cannot pay twice.
	self._collected = false
end

function EnchantmentScrollDrop:Start()
	collectedRouter:Bind(self.Instance, function(player: Player)
		-- A dead player collects nothing.
		if LifeService:IsDeathState(player) then
			return
		end
		if not withinPickupReach(player, self.Instance, PICKUP_REACH) then
			return
		end
		if self._collected then
			return
		end
		-- The client only builds the prompt for the owner; a spoofed fire
		-- from anyone else stops here.
		if player.UserId ~= self.Instance:GetAttribute(Attributes.OwnerId) then
			return
		end

		local enchantment = self.Instance:GetAttribute(ATTR_ENCHANTMENT)
		local tier = self.Instance:GetAttribute(ATTR_TIER)
		if typeof(enchantment) ~= "string" or typeof(tier) ~= "number" then
			warn("[EnchantmentScrollDrop] Pickup rejected -- missing scroll attributes")
			return
		end

		-- Latched BEFORE the grant so two triggers in one frame pay once;
		-- released if the grant is refused (the scroll stays to retry).
		self._collected = true
		if not EnchantmentScrollService:Grant(player, enchantment, tier) then
			self._collected = false
			return
		end

		-- Every client kills the prompt and label and fades the block off
		-- Expired; the instance follows once that fade has played.
		local instance = self.Instance
		instance:SetAttribute(Attributes.CollectedById, player.UserId)
		instance:SetAttribute(ATTR_EXPIRED, true)
		GameClock.Delay(POST_FADE_DESTROY_DELAY, function()
			if instance.Parent then
				instance:Destroy()
			end
		end)
	end)
end

return EnchantmentScrollDrop
