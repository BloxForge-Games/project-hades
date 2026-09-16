--!strict
--[[
	Module: Server/Services/PlayerVitalsBillboardService.lua
	Description:
	Attaches the side-mounted vitals billboards -- HealthBillboardGui and
	ManaBillboardGui -- to every player character on spawn. The GUIs live
	under the HumanoidRootPart, so they REPLICATE to every client for free;
	this service does nothing else. All motion (bar tweens on health / mana
	change, hide during the viewer's cutscene, hide on death) is done
	per-viewer on the client by PlayerVitalsBillboardController: each client
	tweens its own copies, so the bars are smooth everywhere and each viewer
	can hide them during THEIR cutscene (CutscenePlaying is a client-set
	attribute the server never sees).

	Templates: ReplicatedStorage.GameAssets.BillboardGuis.<name>
	  HealthBillboardGui / ManaBillboardGui
	    Frame                 -- background track
	    HealthBar / ManaBar   -- fill; the client scales its Y from the bottom
	Mana values themselves reach other clients as the Mana / MaxMana
	character attributes MagicService stamps (see Attributes.Mana).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local PlayerEventService = require(ServerScriptService.Submodules.Core.Source.Services.PlayerEventService)

local BILLBOARD_TEMPLATE_NAMES = { "HealthBillboardGui", "ManaBillboardGui" }

local PlayerVitalsBillboardService = {
	Name = "PlayerVitalsBillboardService",
	Dependencies = { PlayerEventService } :: { any },
}

function PlayerVitalsBillboardService._attach(_self: typeof(PlayerVitalsBillboardService), character: Model)
	local hrp = character:WaitForChild("HumanoidRootPart", 10)
	if not hrp then
		return
	end

	local folder = ReplicatedStorage.GameAssets:FindFirstChild("BillboardGuis")
	for _, templateName in BILLBOARD_TEMPLATE_NAMES do
		if hrp:FindFirstChild(templateName) then
			continue -- already attached (respawn re-fire / template baked into the rig)
		end
		local template = folder and folder:FindFirstChild(templateName)
		if not template then
			warn("[PlayerVitalsBillboardService] Missing GameAssets.BillboardGuis." .. templateName)
			continue
		end
		local billboard = template:Clone()
		billboard.Name = templateName
		billboard.Adornee = hrp
		billboard.Parent = hrp
	end
end

function PlayerVitalsBillboardService.Start(self: typeof(PlayerVitalsBillboardService))
	PlayerEventService.OnCharacterAdded:Connect(function(_player: Player, character: Model)
		task.spawn(function()
			self:_attach(character)
		end)
	end)
end

return PlayerVitalsBillboardService
