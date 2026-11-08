--!strict
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

                  Put up only once the player has LANDED (2026-11-07:
                  LandingService.OnPlayerLanded), never on spawn: a
                  character spawns at the off-map staging point first, and a
                  marker there pointed every teammate off screen at it.
]]

--[ Roblox Services ]--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Blitz = require(ReplicatedStorage.Submodules.Core.Shared.Blitz)

--[ Exports & Types & Defaults ]--

local PlayerIndicatorService = {
	Name = "PlayerIndicatorService",
}

--[ Imports ]--

--[ Constants ]--

local INDICATOR_NAME = "Indicator"
local INDICATOR_COLOR = Color3.fromRGB(30, 30, 30)
local INDICATOR_SIZE = 0.07
local THUMBNAIL_TYPE = Enum.ThumbnailType.HeadShot
local THUMBNAIL_SIZE = Enum.ThumbnailSize.Size420x420

--[ Properties ]--

--[ Private Functions ]--

function PlayerIndicatorService._getAvatarImage(_self: typeof(PlayerIndicatorService), userId: number): string
	local ok, content = pcall(function()
		return Players:GetUserThumbnailAsync(userId, THUMBNAIL_TYPE, THUMBNAIL_SIZE)
	end)
	if not ok then
		return ""
	end
	return content
end

function PlayerIndicatorService._attachIndicator(self: typeof(PlayerIndicatorService), player: Player, character: Model)
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

-- The landed player's character gets its marker (re-authored each landing).
function PlayerIndicatorService._onLanded(self: typeof(PlayerIndicatorService), player: Player)
	local character = player.Character
	if not character or not character:FindFirstChild("HumanoidRootPart") then
		return
	end
	self:_attachIndicator(player, character)
end

--[ Public Functions ]--

--[ Initializers ]--

function PlayerIndicatorService.Start(self: typeof(PlayerIndicatorService))
	local landing = Blitz.OptionalService("LandingService")
	if landing then
		landing.OnPlayerLanded:Connect(function(player: Player)
			self:_onLanded(player)
		end)
	end
end

return PlayerIndicatorService
