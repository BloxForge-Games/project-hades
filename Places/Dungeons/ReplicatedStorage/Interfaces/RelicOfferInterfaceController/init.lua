--!strict
--[[
	Module: RelicOfferInterfaceController.lua
	Description:
	UI root / React bridge for the relic OFFER: the pick-one hand of cards
	the server deals (RelicOfferService) in place of the old floor fan at
	a vending machine, the Forge or the Cursed Shrine.

	Wire-up only. The Container owns the screen; this module mounts it,
	forwards the three server events into signals the Container observes,
	sends the player's answer back, and plays the everyone-visible burst
	when ANY player takes a relic from a hand (RelicOfferTaken), the same
	CollectRelicVFXCharacter burst the floor pickup used to play.
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--[ Imports ]--

local RelicController = require(ReplicatedStorage.Controllers.RelicController)
local InputPlatformController = require(ReplicatedStorage.Submodules.Core.Source.Controllers.InputPlatformController)
local ScreenSizeController = require(ReplicatedStorage.Submodules.Core.Source.Controllers.ScreenSizeController)
local ScreenSizes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.ScreenSizes)
local RelicInterfaceController = require(ReplicatedStorage.Interfaces.RelicInterfaceController)
local InterfaceManagerController =
	require(ReplicatedStorage.Submodules.Core.Source.Controllers.InterfaceManagerController)
local RelicNetwork = require(ReplicatedStorage.Submodules.Core.Source.Network.Relic)
local React = require(ReplicatedStorage.Submodules.Core.Packages.React)
local ReactRoblox = require(ReplicatedStorage.Submodules.Core.Packages["React-Roblox"])
local Signal = require(ReplicatedStorage.Submodules.Core.Packages.Signal)
local RarityColors = require(ReplicatedStorage.Submodules.Core.Shared.Data.RarityColors)
local emitVFXPart = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.emitVFXPart)
local getRoot = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Character.getRoot)

local Container = require(script.ReactComponents.Container)

local INTERFACE_ID = "RelicOfferInterfaceController"

-- Above the dialogue billboard (20) the hand follows, below the cinematic
-- bars (999) and the screen fades (9999).
local DISPLAY_ORDER = 50

-- The taken burst on the chooser's body: the prefab and lifetime the
-- floor pickup used (Client/Components/Relic).
local TAKEN_VFX_NAME = "CollectRelicVFXCharacter"
local TAKEN_VFX_LIFETIME_SCALE = 2
-- Heard by everyone ELSE at the chooser's body; the chooser's own client
-- plays it flat on the pick (Container).
local TAKEN_SOUND_NAME = "RelicPickup"

--[ Controller ]--

local RelicOfferInterfaceController = {
	Name = "RelicOfferInterfaceController",
	Dependencies = {
		RelicController,
		InputPlatformController,
		InterfaceManagerController,
		ScreenSizeController,
		RelicInterfaceController,
	} :: { any },
}

RelicOfferInterfaceController.Signals = {
	-- (payload: RelicOfferPayload) -- the server dealt a hand.
	OnOffered = Signal.new(),
	-- (payload: RelicOfferResolvedPayload) -- how the hand ended.
	OnResolved = Signal.new(),
}

function RelicOfferInterfaceController._render(self: typeof(RelicOfferInterfaceController))
	return function()
		return React.createElement("ScreenGui", {
			ResetOnSpawn = false,
			Name = INTERFACE_ID,
			ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets,
			ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
			DisplayOrder = DISPLAY_ORDER,
		}, {
			Container = React.createElement(Container, {
				offeredSignal = self.Signals.OnOffered,
				resolvedSignal = self.Signals.OnResolved,
				onChoose = function(offerId: number, relicName: string?)
					RelicNetwork.RelicOfferChosen.Fire({ OfferId = offerId, RelicName = relicName })
				end,
				isMobile = function(): boolean
					return InputPlatformController:IsMobilePlatform()
				end,
				-- Phones only: the Mobile screen bucket (touch, no mouse, a
				-- short viewport). Tablets, PC and console are not phones.
				isPhone = function(): boolean
					return ScreenSizeController:GetScreenSizeData().name == ScreenSizes.Mobile
				end,
				screenSizeChanged = ScreenSizeController.Signals.ScreenSizeChanged,
				-- The relic tray: while it is open, the cards take no hover or
				-- pick (it draws above them; a click meant for the tray must
				-- never choose a relic).
				isRelicTrayOpen = function(): boolean
					return RelicInterfaceController:IsOpen()
				end,
				relicTrayChanged = RelicInterfaceController.Signals.OnVisibilityChanged,
			}),
		})
	end
end

-- The everyone-visible pickup: burst on the body, sound for the others.
function RelicOfferInterfaceController._playTaken(
	_self: typeof(RelicOfferInterfaceController),
	player: Player?,
	rarity: string
)
	local root = getRoot.fromPlayer(player)
	if not root then
		return
	end
	emitVFXPart(TAKEN_VFX_NAME, root.CFrame, nil, {
		Color = RarityColors:Get(rarity),
		LifetimeScale = TAKEN_VFX_LIFETIME_SCALE,
	})
	if player == Players.LocalPlayer then
		return
	end
	local sounds = ReplicatedStorage:FindFirstChild("GameAssets")
	sounds = sounds and sounds:FindFirstChild("Sounds")
	local template = sounds and sounds:FindFirstChild(TAKEN_SOUND_NAME)
	if template and template:IsA("Sound") then
		local sound = template:Clone()
		sound.Parent = root
		sound:Play()
		Debris:AddItem(sound, 5)
	end
end

--[ Lifecycle ]--

function RelicOfferInterfaceController.Init(self: typeof(RelicOfferInterfaceController))
	local root = ReactRoblox.createRoot(Instance.new("Folder"))
	root:render(ReactRoblox.createPortal(React.createElement(self:_render()), Players.LocalPlayer.PlayerGui))
end

function RelicOfferInterfaceController.Start(self: typeof(RelicOfferInterfaceController))
	RelicNetwork.RelicOffered.On(function(payload)
		self.Signals.OnOffered:Fire(payload)
	end)
	RelicNetwork.RelicOfferResolved.On(function(payload)
		self.Signals.OnResolved:Fire(payload)
	end)
	RelicNetwork.RelicOfferTaken.On(function(payload)
		self:_playTaken(payload.Player, payload.Rarity)
	end)
end

return RelicOfferInterfaceController
