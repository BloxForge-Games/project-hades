--!strict
--[[
	Module: Server/Components/Rune.lua
	Description:
	A physical rune drop (dispensed by a rune machine) — the server half of
	the same request/accept contract the Relic component uses:

	  * The CLIENT is request-only: its prompt fires OnRuneCollected and
	    consumes nothing until the server answers.
	  * The server validates (owner, known rune, not already claimed) and
	    fires OnRuneCollectAccepted, which is the client's cue to play the
	    pickup across the whole pull.

	Differences from Relic, all by design: runes have NO ownership cap (no
	refusal path) and NO Skip offer — every valid pickup succeeds. Picking
	one still sweeps the owner's other rune offers and marks the machine
	choice made, so the gate cycle proceeds exactly as a relic pick would.

	Attributes on the model (stamped by DropService's rune drop path):
	  OwnerId        -- the player this offer belongs to
	  RuneRarity     -- rolled tier (magnitude + tint + billboard text)
	  TargetPosition -- fan landing spot (the client animates the arc)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Component = require(ReplicatedStorage.Submodules.Core.Packages.Component)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local RuneService = require(ServerScriptService.Services.RuneService)
local RelicService = require(ServerScriptService.Services.RelicService)
local TextIndicatorService = require(ServerScriptService.Submodules.Core.Source.Services.TextIndicatorService)
local RelicNetwork = require(ServerScriptService.Submodules.Core.Source.Network.Relic)
local InstanceRouter = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Network.InstanceRouter)
local RuneData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RuneData)

local collectRouter = InstanceRouter.Server(RelicNetwork.RuneCollectRequested)

local Rune = Component.new({
	Tag = TagList.Rune,
})

function Rune:Construct()
	self._claimed = false
	-- Server -> owner ACCEPT: the client consumes (fades the pull, kills
	-- the prompts, plays the burst) ONLY when this fires — same contract
	-- as the Relic component, even though runes have no refusal path
	-- today, so a future one (events, shops) slots in without a client
	-- change.
	self._collectedSound = ReplicatedStorage.GameAssets.Sounds.RelicPickup:Clone()
	self._collectedSound.Parent = self.Instance:FindFirstChild("Handle") or self.Instance.PrimaryPart
end

function Rune:Start()
	collectRouter:Bind(self.Instance, function(player: Player)
		if self._claimed then
			return
		end
		if player.UserId ~= self.Instance:GetAttribute(Attributes.OwnerId) then
			return
		end
		if RuneData[self.Instance.Name] == nil then
			return
		end
		local rarity = self.Instance:GetAttribute("RuneRarity")
		if rarity == nil or RuneData[self.Instance.Name].effects[rarity] == nil then
			return
		end

		self._claimed = true

		-- Accepted: tell the owner's client to play the pickup BEFORE the
		-- server-side destroy so the fade has its models to animate.
		RelicNetwork.RuneCollectAccepted.Fire(player, self.Instance)

		RuneService:AddRune(player, self.Instance.Name, rarity)

		-- Sweep this player's whole rune pull (the pick-1-of-3 rule), on
		-- the same 2s grace the relic pull uses so the client fade wins.
		for _, rune in workspace:QueryDescendants("." .. TagList.Rune) do
			if rune:GetAttribute(Attributes.OwnerId) == player.UserId then
				task.delay(2, function()
					rune:Destroy()
				end)
			end
		end

		self._collectedSound:Play()

		if self.Instance.PrimaryPart then
			-- Display identity comes from RuneData's `name` ("Health Rune"),
			-- never the instance name -- that's the enum/asset key
			-- (Cheeseburger et al.).
			local runeData = RuneData[self.Instance.Name]
			TextIndicatorService:ShowIndicator(
				player,
				self.Instance.PrimaryPart,
				"Picked up " .. ((runeData and runeData.name) or self.Instance.Name) .. "!",
				Color3.fromRGB(255, 255, 255)
			)
		end

		-- The machine choice is made — the gate cycle proceeds exactly as
		-- if a relic had been taken.
		RelicService:MarkRelicChoiceMade(player)
	end)
end

return Rune
