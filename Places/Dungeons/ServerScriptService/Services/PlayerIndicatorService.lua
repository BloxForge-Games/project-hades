--[[
     Author(s):
     Module: PlayerIndicatorService.lua
     Description: Attaches an "Indicator" Attachment to every player's
                  HumanoidRootPart on spawn. Carries the player's avatar
                  headshot as the Image attribute so the client-side
                  LocationMarkerSystem can render off-screen teammate
                  arrows for co-op orientation.

                  All visual logic lives in the LocationMarkerSystem
                  library; this service only authors the attachment + its
                  attributes.
]]

--[ Roblox Services ]--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--[ Exports & Types & Defaults ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)

local PlayerIndicatorService = Knit.CreateService({
	Name = "PlayerIndicatorService",
	Client = {},
})

--[ Imports ]--

--[ Constants ]--

local INDICATOR_NAME = "Indicator"
local INDICATOR_COLOR = Color3.fromRGB(30, 30, 30)
local INDICATOR_SIZE = 0.07
local THUMBNAIL_TYPE = Enum.ThumbnailType.HeadShot
local THUMBNAIL_SIZE = Enum.ThumbnailSize.Size420x420

--[ Properties ]--

--[ Private Functions ]--

function PlayerIndicatorService:_getAvatarImage(userId: number): string
	local ok, content = pcall(function()
		return Players:GetUserThumbnailAsync(userId, THUMBNAIL_TYPE, THUMBNAIL_SIZE)
	end)
	if not ok then
		return ""
	end
	return content
end

function PlayerIndicatorService:_attachIndicator(player: Player, character: Model)
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return
	end

	-- Re-author from scratch on each spawn so stale attributes don't linger.
	local existing = hrp:FindFirstChild(INDICATOR_NAME)
	if existing then
		existing:Destroy()
	end

	local attachment = Instance.new("Attachment")
	attachment.Name = INDICATOR_NAME
	attachment:SetAttribute("Image", self:_getAvatarImage(player.UserId))
	attachment:SetAttribute("Color", INDICATOR_COLOR)
	attachment:SetAttribute("Enabled", true)
	attachment:SetAttribute("IndicatorSize", INDICATOR_SIZE)
	attachment:SetAttribute("UserID", player.UserId)
	attachment.Parent = hrp
end

function PlayerIndicatorService:_bindPlayer(player: Player)
	local function onCharacter(character: Model)
		-- HRP may not be parented yet on first frame; wait briefly.
		local hrp = character:FindFirstChild("HumanoidRootPart")
		if not hrp then
			hrp = character:WaitForChild("HumanoidRootPart", 5)
		end
		if hrp then
			self:_attachIndicator(player, character)
		end
	end

	player.CharacterAdded:Connect(onCharacter)
	if player.Character then
		onCharacter(player.Character)
	end
end

--[ Public Functions ]--

--[ Initializers ]--

function PlayerIndicatorService:KnitInit() end

function PlayerIndicatorService:KnitStart()
	Players.PlayerAdded:Connect(function(player: Player)
		self:_bindPlayer(player)
	end)
	for _, player in Players:GetPlayers() do
		self:_bindPlayer(player)
	end
end

return PlayerIndicatorService
