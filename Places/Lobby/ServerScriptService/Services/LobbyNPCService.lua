--!strict
--[[
	Module: LobbyNPCService.lua
	Description:
	Wires the hub's talk-to NPCs (2026-10-23). The models live under
	workspace.IgnoreInstances.NPCs, authored in Studio by name; this
	service gives each one its dialogue graph, the NPC tag (which the core
	NPC component and the billboard dialogue key off) and a ProximityPrompt
	under its PrimaryPart if the rig ships none.

	  a name containing "artix"                    -> LobbyGearMerchant (Artix's shop)
	  a name containing "twig" or "merchant"       -> LobbyMerchant   (the Shop)
	  a name containing "cysero" or "blacksmith"   -> LobbyBlacksmith (the Forge)
	  a name containing "warlic" or "arcane"       -> LobbyArcaneTrainer (the chests)
	Matched by keyword, case-insensitive, so "Twig the Moglin", "Twig the
	Merchant" or "The Merchant" all land on the same graph (an exact-name
	table missed a rename and dropped Twig onto the default graph).

	A model whose name is not in the table is left alone with a warn, so a
	misnamed rig is visible in the log rather than silently mute.
]]

--[ Roblox Services ]--

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--[ Imports ]--

local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)

--[ Constants ]--

local IGNORE_INSTANCES_NAME = "IgnoreInstances"
local NPC_FOLDER_NAME = "NPCs"
local DIALOGUE_GRAPH_ATTRIBUTE = "DialogueGraph"

-- Lower-cased keyword in the model name -> DialogueRegistry module name.
-- First match in order wins.
local GRAPH_BY_KEYWORD: { { keyword: string, graph: string } } = {
	{ keyword = "artix", graph = "LobbyGearMerchant" },
	{ keyword = "twig", graph = "LobbyMerchant" },
	{ keyword = "cysero", graph = "LobbyBlacksmith" },
	{ keyword = "warlic", graph = "LobbyArcaneTrainer" },
	{ keyword = "merchant", graph = "LobbyMerchant" },
	{ keyword = "blacksmith", graph = "LobbyBlacksmith" },
	{ keyword = "arcane", graph = "LobbyArcaneTrainer" },
}

local function graphForName(name: string): string?
	local lowered = string.lower(name)
	for _, entry in GRAPH_BY_KEYWORD do
		if string.find(lowered, entry.keyword, 1, true) then
			return entry.graph
		end
	end
	return nil
end

-- The prompt, when the rig ships none. Roblox's default style: the custom
-- prompt UI the Dungeons chests use lives in that place file, not here.
-- Flip to Custom (with Style = "DefaultCustom") once the Lobby ships it.
local PROMPT_ACTION_TEXT = "Talk"
local PROMPT_MAX_DISTANCE = 8

--[ Service ]--

local LobbyNPCService = {
	Name = "LobbyNPCService",
	Dependencies = {} :: { any },
}

--[ Private ]--

local function ensurePrompt(model: Model): ProximityPrompt?
	local existing = model:FindFirstChildWhichIsA("ProximityPrompt", true)
	if existing then
		return existing
	end
	local primary = model.PrimaryPart or (model:FindFirstChild("HumanoidRootPart") :: BasePart?)
	if not primary then
		warn(("[LobbyNPCService] '%s' has no PrimaryPart or HumanoidRootPart -- no prompt made"):format(model.Name))
		return nil
	end
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = PROMPT_ACTION_TEXT
	prompt.ObjectText = model.Name
	prompt.KeyboardKeyCode = Enum.KeyCode.F
	prompt.Exclusivity = Enum.ProximityPromptExclusivity.OnePerButton
	prompt.HoldDuration = 0
	prompt.Style = Enum.ProximityPromptStyle.Default
	prompt.RequiresLineOfSight = false
	prompt.MaxActivationDistance = PROMPT_MAX_DISTANCE
	prompt.Parent = primary
	return prompt
end

function LobbyNPCService._wire(_self: typeof(LobbyNPCService), model: Instance)
	if not model:IsA("Model") then
		return
	end
	local graphName = graphForName(model.Name)
	if not graphName then
		warn(
			("[LobbyNPCService] No dialogue graph for NPC '%s' -- add a keyword to GRAPH_BY_KEYWORD"):format(model.Name)
		)
		return
	end
	-- A rig without a PrimaryPart adorns the billboard to an arbitrary part;
	-- the HumanoidRootPart is the one it should have.
	if not model.PrimaryPart then
		local root = model:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			model.PrimaryPart = root
		end
	end
	model:SetAttribute(DIALOGUE_GRAPH_ATTRIBUTE, graphName)
	ensurePrompt(model)
	-- The tag last: the NPC component reads the prompt on Construct.
	CollectionService:AddTag(model, TagList.NPC)
end

--[ Lifecycle ]--

function LobbyNPCService.Start(self: typeof(LobbyNPCService))
	local ignoreInstances = workspace:FindFirstChild(IGNORE_INSTANCES_NAME)
	local folder = ignoreInstances and ignoreInstances:FindFirstChild(NPC_FOLDER_NAME)
	if not folder then
		warn(
			("[LobbyNPCService] workspace.%s.%s missing -- no hub NPCs wired"):format(
				IGNORE_INSTANCES_NAME,
				NPC_FOLDER_NAME
			)
		)
		return
	end
	for _, model in folder:GetChildren() do
		self:_wire(model)
	end
	folder.ChildAdded:Connect(function(model)
		self:_wire(model)
	end)
end

return LobbyNPCService
