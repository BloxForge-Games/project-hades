local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Component = require(ReplicatedStorage.Submodules.Core.Packages.Component)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local CommAdder = require(ReplicatedStorage.Submodules.Core.Source.ComponentExtensions.CommAdder)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local SkipRelicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.SkipRelicData)

local RelicService
local TextIndicatorService

Knit.OnStart()
	:andThen(function()
		TextIndicatorService = Knit.GetService("TextIndicatorService")
		RelicService = Knit.GetService("RelicService")
	end)
	:catch(warn)

-- The pickup fade, mirrored by the client's PICKUP_FADE_SECONDS, plus a
-- margin before the instance goes so the tween is never cut short.
local PICKUP_FADE_SECONDS = 0.75
local POST_FADE_DESTROY_DELAY = PICKUP_FADE_SECONDS + 0.25

local Relic = Component.new({
	Tag = TagList.Relic,
	Extensions = { CommAdder },
})

function Relic:Construct()
	self._playerRegistry = {} :: { [Players]: boolean }
	-- Set on the first accepted grab. Owned relics are shielded by the
	-- OwnerId check; a PUBLIC drop has none, so this is what stops two
	-- players who reach it on the same frame both being granted it.
	self._claimed = false
	self._onRelicCollected = self._comm:CreateSignal("OnRelicCollected")
	-- Server -> owner ACCEPT. The client consumes (fades the pull, kills the
	-- prompts, plays the burst) ONLY when this fires, so a refused grab --
	-- relic cap, wrong owner, already claimed -- leaves every relic in the
	-- pull untouched and re-claimable. The client never predicts the outcome.
	self._onRelicCollectAccepted = self._comm:CreateSignal("OnRelicCollectAccepted")
end

function Relic:Start()
	self._onRelicCollected:Connect(function(player: Player)
		if self._playerRegistry[player] or self._claimed then
			return
		end

		-- A PUBLIC drop (a player tossed it from the tray) has no owner;
		-- everything else is claimable by its OwnerId only.
		local isPublic = self.Instance:GetAttribute(Attributes.PublicDrop) == true
		if not isPublic and player.UserId ~= self.Instance:GetAttribute(Attributes.OwnerId) then
			return
		end

		-- The Skip offer is deliberately absent from RelicNames / RelicData,
		-- so it has to clear the validity gate on its own.
		local isSkip = self.Instance.Name == SkipRelicData.Name
		if not isSkip and RelicNames[self.Instance.Name] == nil then
			return
		end

		-- Relic cap: refuse BEFORE consuming anything -- the relic (and, at
		-- a vending machine, the pull's other offers) stays claimable, so a
		-- capped player wastes nothing by bumping into it.
		-- Skipping is ALWAYS allowed: it grants nothing, so the relic cap
		-- cannot be exceeded by it -- and a capped player still needs a way to
		-- clear the pull and open the gate.
		if not isSkip and not RelicService:CanAcceptRelic(player, self.Instance.Name) then
			local character = player.Character
			local indicatorPart = character
				and (character:FindFirstChild("Head") or character:FindFirstChild("HumanoidRootPart"))
			if TextIndicatorService and indicatorPart then
				TextIndicatorService:ShowIndicator(
					player,
					indicatorPart,
					"Reached Maximum Relics! (12)",
					Color3.fromRGB(250, 70, 70),
					true
				)
			end

			-- Refusal sting, paired with the pop above. Cloned onto the HRP
			-- and played server-side, same recipe as GainAura -- a Sound under
			-- a BasePart replicates its playback and is positional for free.
			-- FindFirstChild-guarded so a missing asset warns instead of
			-- erroring the whole pickup handler.
			local rootPart = character and character:FindFirstChild("HumanoidRootPart")
			local errorTemplate = ReplicatedStorage.GameAssets.Sounds:FindFirstChild("Error")
			if rootPart and errorTemplate then
				local errorSound = errorTemplate:Clone()
				errorSound.Parent = rootPart
				errorSound:Play()
				Debris:AddItem(errorSound, 3)
			elseif not errorTemplate then
				warn("[Relic] Missing ReplicatedStorage.GameAssets.Sounds.Error")
			end
			return
		end

		self._playerRegistry[player] = true
		self._claimed = true

		-- Accepted. Fired for the collector's own client-side flourish (the
		-- screen pulse); the relic itself is gone by the next frame.
		self._onRelicCollectAccepted:Fire(player)

		-- Feedback rides the CHARACTER, not the relic. The relic is
		-- destroyed immediately below, and a sound or indicator parented to
		-- it would be cut off with it.
		local character = player.Character
		local rootPart = character and character:FindFirstChild("HumanoidRootPart")
		local indicatorPart = character
			and (character:FindFirstChild("Head") or character:FindFirstChild("HumanoidRootPart"))
		if rootPart then
			local pickupSound = ReplicatedStorage.GameAssets.Sounds.RelicPickup:Clone()
			pickupSound.Parent = rootPart
			pickupSound:Play()
			Debris:AddItem(pickupSound, 3)
		end
		if indicatorPart then
			TextIndicatorService:ShowIndicator(
				player,
				indicatorPart,
				if isSkip then SkipRelicData.PickupText else "Picked up " .. self.Instance.Name .. "!",
				Color3.fromRGB(255, 255, 255)
			)
		end

		-- Grant BEFORE the destroy: the branch below reads the relic's name
		-- off the Instance.
		if isSkip then
			-- Grants nothing. Only the "you have chosen" broadcast fires, so
			-- the gate cycle (and anything else keyed off a relic choice)
			-- proceeds exactly as if a relic had been taken.
			RelicService:MarkRelicChoiceMade(player)
		else
			RelicService:AddRelicsRegistry(player, self.Instance.Name, 1)
			-- Carry the floor label's owner forward. Picking a relic up off
			-- the ground inherits whoever ORIGINALLY dropped it, so dropping
			-- it again keeps their name on it. Anything without an origin (a
			-- machine offer, an event reward) passes nil, which clears the
			-- note so this player counts as the original if they drop it.
			RelicService:SetRelicOrigin(
				player,
				self.Instance.Name,
				self.Instance:GetAttribute(Attributes.DroppedById),
				self.Instance:GetAttribute(Attributes.DroppedByName)
			)
		end

		-- Marked collected FIRST, which is what every client watches: the
		-- prompt and the floating label go instantly on every screen, and
		-- the model fades out together. Only the destroy waits.
		--
		-- The old two-second delay existed so the COLLECTOR's fade had
		-- something to animate, and told nobody else — so every other
		-- player kept staring at a claimed relic, prompt and all, and could
		-- still walk up and trigger it.
		local function collect(relic: Instance)
			relic:SetAttribute(Attributes.Collected, true)
			task.delay(POST_FADE_DESTROY_DELAY, function()
				if relic.Parent then
					relic:Destroy()
				end
			end)
		end

		if isPublic then
			-- Only ITSELF goes: a public drop is part of no fan, so a
			-- vending-machine pull the claimant still has open stays open.
			collect(self.Instance)
		else
			for _, relic in pairs(workspace:QueryDescendants(".Relic")) do
				if relic:GetAttribute("OwnerId") == player.UserId then
					collect(relic)
				end
			end
		end
	end)
end

return Relic
