local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Component = require(ReplicatedStorage.Submodules.Core.Packages.Component)
local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local CommAdder = require(ReplicatedStorage.Submodules.Core.Source.ComponentExtensions.CommAdder)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local DropData = require(ReplicatedStorage.Submodules.Core.Shared.Data.DropData)
local DropTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.DropTypes)

local DESTROY_DELAY = 25
local MANA_DESTROY_DELAY = 10

local DropService

Knit.OnStart()
	:andThen(function()
		DropService = Knit.GetService("DropService")
	end)
	:catch(warn)

local Drop = Component.new({
	Tag = TagList.Drop,
	Extensions = { CommAdder },
})

function Drop:Construct()
	self._playerRegistry = {} :: { [Players]: boolean }
	self._onCoinCollected = self._comm:CreateSignal("OnCoinCollected")
	self._dropValue = self.Instance:GetAttribute(Attributes.DropValue)
	self._dropType = self.Instance:GetAttribute(Attributes.DropType)
	self._imageId = self.Instance:GetAttribute(Attributes.ImageId)
end

function Drop:Start()
	self.Instance.PrimaryPart.BillboardGui.Image.Image = self._imageId
	self.Instance.PrimaryPart.BillboardGui.Image.ImageColor3 = DropData[self._dropType].color
	self.Instance.PrimaryPart.BillboardGui.Size = DropData[self._dropType].size

	for _, descendant in self.Instance:GetDescendants() do
		if not descendant:IsA("ParticleEmitter") then
			continue
		end

		descendant.Color = ColorSequence.new(DropData[self._dropType].color)
	end

	-- Update drop image if updated
	self.Instance.AttributeChanged:Connect(function(attributeName: string)
		if not attributeName == Attributes.ImageId then
			return
		end

		self.Instance.PrimaryPart.BillboardGui.Image.Image = self._imageId
	end)

	-- Removes the coin within 15 seconds
	task.delay(
		if self._dropType == DropTypes.Coins
			then DESTROY_DELAY
			elseif self._dropType == DropTypes.Mana then MANA_DESTROY_DELAY
			else DESTROY_DELAY,
		function()
			local coinImageTransparencyTween = TweenService:Create(
				self.Instance.PrimaryPart.BillboardGui.Image,
				TweenInfo.new(1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ ImageTransparency = 1 }
			)

			for _, descendant in self.Instance.PrimaryPart:GetDescendants() do
				if descendant:IsA("ParticleEmitter") then
					descendant.Enabled = false
				end
			end

			coinImageTransparencyTween:Play()

			coinImageTransparencyTween.Completed:Connect(function()
				self.Instance:Destroy()
			end)
		end
	)

	self._onCoinCollected:Connect(function(player: Player)
		-- PRIVATE drop (chest loot): only its owner banks it. The client
		-- already hides it from everyone else, but the credit is real
		-- currency — it gets checked HERE, where it cannot be faked.
		local ownerId = self.Instance:GetAttribute(Attributes.OwnerId)
		if ownerId and player.UserId ~= ownerId then
			return
		end

		if self._playerRegistry[player] then
			return
		end

		self._playerRegistry[player] = true

		DropService.OnDropCollected:Fire(player, self._dropType, self._dropValue)
	end)
end

return Drop
