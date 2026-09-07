--[[
     Author(s): 
     Module: BuildController.lua
     Description:
]]

--[ Roblox Services ]--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

--[ Exports & Types & Defaults ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local Signal = require(ReplicatedStorage.Submodules.Core.Packages.Signal)
local BuildNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.BuildNames)

local PlacementSystem = require(script.PlacementSystem)

local TOGGLE_DEBOUNCE = 0.25

local BuildService
local ZombieSpawnService

local BuildController = Knit.CreateController({
	Name = "BuildController",

	_placementSystem = nil,
	_buildMode = false,
	_activeBuild = nil,
	_buildRegistry = {},
	_characters = {},
	_zombieRegistry = {},
	_canToggle = true,
	_buildLevelRegistry = {},

	Signals = {
		OnBuildModeToggled = Signal.new(),
		OnBuildLevelChanged = Signal.new(),
	},
})

--[ Imports ]--

--[ Constants ]--

--[ Properties ]--

--[ Private Functions ]--

function BuildController:_ToggleBuildHighlight(toggle: boolean)
	for _, build in pairs(workspace.IgnoreInstances.Map.Buildables:GetChildren()) do
		if build.PrimaryPart and build.PrimaryPart:FindFirstChild("BuildInterface") then
			if toggle then
				build.PrimaryPart.BuildInterface.PlayerName.Visible = true
				build.PrimaryPart.BuildInterface.BuildName.Visible = true

				if build.PrimaryPart.BuildInterface.PlayerName.Text == "(" .. Players.LocalPlayer.Name .. ")" then
					if build.Model:FindFirstChild("PlayerBuildHighlight") then
						continue
					end

					local highlight = Instance.new("Highlight")
					highlight.Name = "PlayerBuildHighlight"
					highlight.FillColor = Color3.fromRGB(255, 255, 255)
					highlight.OutlineColor = Color3.fromRGB(0, 0, 0)
					highlight.FillTransparency = 0.75
					highlight.OutlineTransparency = 0
					highlight.Parent = build.Model

					build.PrimaryPart.BuildInterface.InnerFrame.Visible = true
				end
			else
				build.PrimaryPart.BuildInterface.PlayerName.Visible = false
				build.PrimaryPart.BuildInterface.BuildName.Visible = false

				if build.PrimaryPart.BuildInterface.PlayerName.Text == "(" .. Players.LocalPlayer.Name .. ")" then
					if build.Model:FindFirstChild("PlayerBuildHighlight") then
						build.Model.PlayerBuildHighlight:Destroy()
					end

					local maxHealth = build.PrimaryPart:FindFirstChild("MaxHealth")
					local currentHealth = build.PrimaryPart:FindFirstChild("CurrentHealth")

					if maxHealth and currentHealth then
						if currentHealth.Value == maxHealth.Value then
							build.PrimaryPart.BuildInterface.InnerFrame.Visible = false
						end
					end
				end
			end
		else
			warn(`[BuildController] Build ${build.Name} is missing a BuildInterface - cannot display player name`)
			continue
		end
	end

	for _, build in pairs(workspace.IgnoreInstances.MagicSpells.ClientBuildables:GetChildren()) do
		if build.PrimaryPart and build.PrimaryPart:FindFirstChild("BuildInterface") then
			if toggle then
				if build.PrimaryPart.BuildInterface.PlayerName.Text == "(" .. Players.LocalPlayer.Name .. ")" then
					if build.Model:FindFirstChild("PlayerBuildHighlight") then
						continue
					end

					local highlight = Instance.new("Highlight")
					highlight.Name = "PlayerBuildHighlight"
					highlight.FillColor = Color3.fromRGB(255, 255, 255)
					highlight.OutlineColor = Color3.fromRGB(0, 0, 0)
					highlight.FillTransparency = 0.75
					highlight.OutlineTransparency = 0
					highlight.Parent = build.Model
				end
			else
				if build.PrimaryPart.BuildInterface.PlayerName.Text == "(" .. Players.LocalPlayer.Name .. ")" then
					if build.Model:FindFirstChild("PlayerBuildHighlight") then
						build.Model.PlayerBuildHighlight:Destroy()
					end
				end
			end
		else
			warn(`[BuildController] Build ${build.Name} is missing a BuildInterface - cannot display player name`)
			continue
		end
	end
end

--[ Public Functions ]--

function BuildController:SetActiveBuild(build: BuildNames.BuildNames)
	self._activeBuild = build

	if self._placementSystem then
		self._placementSystem:SetBuild(build)
		self._placementSystem:UpdateBuildLevel(self._buildLevelRegistry)

		print(`[BuildController] Active build set to: ${build}`)
	else
		warn("[BuildController] Cannot set active build - placement system not initialized")
	end
end

function BuildController:GetBuildMode(): boolean
	return self._buildMode
end

function BuildController:GetBuildLevelRegistry(): table
	return table.clone(self._buildLevelRegistry)
end

function BuildController:ToggleBuildMode()
	self._buildMode = not self._buildMode

	self.Signals.OnBuildModeToggled:Fire(self._buildMode)

	if not self._canToggle then
		return
	end

	self._canToggle = false

	if self._buildMode then
		TweenService:Create(
			workspace.IgnoreInstances.Terrain.InBounds.Terrain.GridTexture,
			TweenInfo.new(0.5),
			{ Transparency = 0.75 }
		):Play()

		TweenService:Create(
			workspace.IgnoreInstances.Terrain.InBounds.Terrain.DefaultTexture,
			TweenInfo.new(0.5),
			{ Transparency = 1 }
		):Play()

		self._placementSystem = PlacementSystem.new(workspace.IgnoreInstances.Terrain.InBounds.Terrain)
		self._placementSystem:Init()
		self._placementSystem:UpdateCharacterList(self._characters)
		self._placementSystem:UpdateZombieRegistry(self._zombieRegistry)

		self:_ToggleBuildHighlight(true)

		if self._activeBuild then
			self._placementSystem:SetBuild(self._activeBuild)
			self._placementSystem:UpdateBuildRegistry(self._buildRegistry)
			self._placementSystem:UpdateBuildLevel(self._buildLevelRegistry)
		end
	else
		self:_ToggleBuildHighlight(false)

		TweenService:Create(
			workspace.IgnoreInstances.Terrain.InBounds.Terrain.GridTexture,
			TweenInfo.new(0.5),
			{ Transparency = 1 }
		):Play()

		TweenService:Create(
			workspace.IgnoreInstances.Terrain.InBounds.Terrain.DefaultTexture,
			TweenInfo.new(0.5),
			{ Transparency = 0.75 }
		):Play()

		self._placementSystem:Destroy()
		self._placementSystem = nil
	end

	task.wait(TOGGLE_DEBOUNCE)

	self._canToggle = true
end

--[ Initializers ]--

function BuildController:KnitStart()
	BuildService = Knit.GetService("BuildService")
	ZombieSpawnService = Knit.GetService("ZombieSpawnService")

	self._zombieRegistry = workspace.IgnoreInstances.Zombies:GetChildren()

	ZombieSpawnService.ZombieRegistry:Observe(function(zombieRegistry: table)
		local newRegistry = {}

		for _, zombie in pairs(zombieRegistry) do
			table.insert(newRegistry, zombie.Torso)
		end

		self._zombieRegistry = newRegistry

		if self._placementSystem then
			self._placementSystem:UpdateZombieRegistry(self._zombieRegistry)
		end
	end)

	BuildService.PlayerCharacters:Observe(function(characters: table)
		self._characters = characters

		if self._placementSystem then
			self._placementSystem:UpdateCharacterList(self._characters)
		end
	end)

	BuildService.BuildRegistry:Observe(function(buildRegistry: table)
		self._buildRegistry = buildRegistry

		if self._placementSystem then
			self._placementSystem:UpdateBuildRegistry(buildRegistry)

			self:_ToggleBuildHighlight(true)
		end
	end)

	BuildService.BuildLevelRegistry:Observe(function(buildLevelRegistry: table)
		self._buildLevelRegistry = buildLevelRegistry

		self.Signals.OnBuildLevelChanged:Fire(buildLevelRegistry)

		if self._placementSystem then
			self._placementSystem:UpdateBuildLevel(buildLevelRegistry)
		end
	end)
end

function BuildController:KnitInit() end

return BuildController
