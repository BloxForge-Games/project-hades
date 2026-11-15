--!strict
--[[
	Module: EnchantmentScrollDrop.lua (Client-side component)
	Description:
	The client half of an enchantment scroll on the floor (2026-11-14):
	the TagList.EnchantmentScrollDrop model EnchantmentScrollService
	spawns, a neon block in the scroll's colour with a name billboard.
	The server half is Server/Components/EnchantmentScrollDrop.

	A scroll is PRIVATE, like chest gear: the server spawns it invisible
	and only its owner's client (Attributes.OwnerId) does anything here.
	The owner reveals it (privateDropVisibility), flies it from the chest
	to its landing spot on the arc every drop shares, then floats it (the
	bob and the spin, DropFloatController) and enables the pickup prompt.
	The prompt fires DungeonNetwork.GearDropCollected with this instance
	(the gear drop's event, routed per instance on the server). When the
	server stamps Expired the block fades out and the server destroys it.

	Everyone else never reveals it and never builds a prompt.
]]

--[ Roblox Services ]--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

--[ Imports ]--

local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local Component = require(ReplicatedStorage.Submodules.Core.Packages.Component)
local DropFloatController = require(ReplicatedStorage.Controllers.DropFloatController)
local DungeonNetwork = require(ReplicatedStorage.Submodules.Core.Source.Network.Dungeon)
local EnchantmentScrollData = require(ReplicatedStorage.Submodules.Core.Shared.Data.EnchantmentScrollData)
local GameClock = require(ReplicatedStorage.Submodules.Core.Shared.GameClock)
local JanitorAdder = require(ReplicatedStorage.Submodules.Core.Source.ComponentExtensions.JanitorAdder)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local arcPath = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Drop.arcPath)
local lootSound = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.lootSound)
local privateDropVisibility = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Drop.privateDropVisibility)
local waitForPrimaryPart = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Drop.waitForPrimaryPart)

--[ Constants ]--

-- Must match EnchantmentScrollService.
local ATTR_ENCHANTMENT = "ScrollEnchantment"
local ATTR_TIER = "ScrollTier"
local ATTR_ORIGIN_POSITION = "OriginPosition"
local ATTR_EXPIRED = "Expired"
local BILLBOARD_NAME = "ScrollName"

-- How long Construct waits for a streamed-in child.
local STREAM_WAIT_SECONDS = 10

-- The flight, the gear drop's: progress per frame and the apex's height.
local BEZIER_STEP = 0.02
local BEZIER_APEX_Y_MIN = 8
local BEZIER_APEX_Y_MAX = 16

-- The resting float.
local BOB_AMPLITUDE = 0.25
local BOB_CYCLE_SECONDS = 2.5
local SPIN_RAD_PER_SEC = math.rad(40)

-- The prompt: the chest's plain custom card (Style "DefaultCustom").
local PROMPT_MAX_DISTANCE = 5
local PROMPT_KEY = Enum.KeyCode.F
local PROMPT_STYLE = "DefaultCustom"
-- Still here this long after a trigger means the server refused: the
-- prompt comes back.
local PICKUP_RETRY_SECONDS = 1

local FADE_INFO = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

--[ Component ]--

local EnchantmentScrollDrop = Component.new({
	Tag = TagList.EnchantmentScrollDrop,
	Extensions = { JanitorAdder } :: { any },
})

--[ Private ]--

function EnchantmentScrollDrop:_buildPrompt(): ProximityPrompt
	local enchantment = self.Instance:GetAttribute(ATTR_ENCHANTMENT)
	local tier = self.Instance:GetAttribute(ATTR_TIER)

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Pick Up"
	prompt.ObjectText = if typeof(enchantment) == "string"
		then EnchantmentScrollData.DisplayName(enchantment, if typeof(tier) == "number" then tier else nil)
		else "Enchantment Scroll"
	prompt.KeyboardKeyCode = PROMPT_KEY
	prompt.HoldDuration = 0
	prompt.RequiresLineOfSight = false
	prompt.MaxActivationDistance = PROMPT_MAX_DISTANCE
	prompt.Style = Enum.ProximityPromptStyle.Custom
	prompt:SetAttribute("Style", PROMPT_STYLE)
	-- Enabled once the block has landed.
	prompt.Enabled = false
	prompt.Parent = self._block
	return prompt
end

-- Origin to landing on the shared arc (with the wall ricochet). Returns
-- false when the block went away mid-flight.
function EnchantmentScrollDrop:_playFlight(): boolean
	lootSound:PlayPop(self._block)

	local origin = self._originPosition
	local landing = self._restingPosition
	local apex = origin + Vector3.new(0, math.random(BEZIER_APEX_Y_MIN, BEZIER_APEX_Y_MAX), 0)
	local arc, durationScale = arcPath(origin, apex, landing, self.Instance:GetAttribute(Attributes.BouncePosition))

	for t = 0, 1, BEZIER_STEP / durationScale do
		RunService.RenderStepped:Wait()
		if not self._block.Parent or self._fading then
			return false
		end
		self._block.CFrame = CFrame.new(arc(t))
	end
	self._block.CFrame = CFrame.new(landing)
	lootSound:PlayLanding()
	return true
end

-- The pickup (or a teardown): prompt and label off at once, the block
-- fades. The server destroys the instance.
function EnchantmentScrollDrop:_fadeOut()
	if self._fading then
		return
	end
	self._fading = true
	self._janitor:Cleanup()
	if self._prompt then
		self._prompt.Enabled = false
	end
	if self._billboard then
		self._billboard.Enabled = false
	end
	if self._block.Parent then
		TweenService:Create(self._block, FADE_INFO, { Transparency = 1 }):Play()
	end
end

--[ Lifecycle ]--

function EnchantmentScrollDrop:Construct()
	self._fading = false
	self._isOwner = self.Instance:GetAttribute(Attributes.OwnerId) == Players.LocalPlayer.UserId
	if not self._isOwner then
		-- Someone else's: the server spawned it invisible and it stays so.
		return
	end

	-- The server spawns the model Atomic, so these normally arrive with
	-- it; the waits cover a model taken while it was still streaming in.
	self._block = waitForPrimaryPart(self.Instance, STREAM_WAIT_SECONDS)
	if not self._block then
		self._isOwner = false
		return
	end
	local billboard = self._block:WaitForChild(BILLBOARD_NAME, STREAM_WAIT_SECONDS)
	self._billboard = if billboard and billboard:IsA("BillboardGui") then billboard else nil

	self._restingPosition = self._block.Position
	local origin = self.Instance:GetAttribute(ATTR_ORIGIN_POSITION)
	self._originPosition = if typeof(origin) == "Vector3" then origin else self._restingPosition

	self._prompt = self:_buildPrompt()
end

function EnchantmentScrollDrop:Start()
	if not self._isOwner then
		return
	end

	self._janitor:Add(self.Instance:GetAttributeChangedSignal(ATTR_EXPIRED):Connect(function()
		if self.Instance:GetAttribute(ATTR_EXPIRED) == true then
			self:_fadeOut()
		end
	end))
	-- Already claimed while it streamed in: it stays hidden.
	if self.Instance:GetAttribute(ATTR_EXPIRED) == true then
		return
	end

	privateDropVisibility.reveal(self.Instance)

	-- The label steps aside while the prompt card is up.
	self._janitor:Add(self._prompt.PromptShown:Connect(function()
		if self._billboard then
			self._billboard.Enabled = false
		end
	end))
	self._janitor:Add(self._prompt.PromptHidden:Connect(function()
		if self._billboard and not self._fading then
			self._billboard.Enabled = true
		end
	end))

	self._janitor:Add(self._prompt.Triggered:Connect(function()
		self._prompt.Enabled = false
		DungeonNetwork.GearDropCollected.Fire(self.Instance)
		ReplicatedStorage.GameAssets.Sounds.GearCollected:Play()

		-- Still here and not fading a moment later: the server refused
		-- (out of reach, no profile yet). The prompt comes back.
		GameClock.Delay(PICKUP_RETRY_SECONDS, function()
			if self.Instance.Parent and not self._fading then
				self._prompt.Enabled = true
			end
		end)
	end))

	task.spawn(function()
		if not self:_playFlight() then
			return
		end
		self._prompt.Enabled = true
		DropFloatController:Register(self._block, {
			base = CFrame.new(self._restingPosition),
			bobAmplitude = BOB_AMPLITUDE,
			bobCycle = BOB_CYCLE_SECONDS,
			spinAxis = Vector3.yAxis,
			spinRate = SPIN_RAD_PER_SEC,
		})
		self._janitor:Add(function()
			DropFloatController:Unregister(self._block)
		end, true)
	end)
end

return EnchantmentScrollDrop
