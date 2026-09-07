local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local packages: Folder = ReplicatedStorage.Submodules.Core.Packages

local Knit = require(packages.Knit)
local Janitor = require(packages.Janitor)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)

local camera: Camera = workspace.CurrentCamera

local PlayerEventController

local WallsTransparencyController = Knit.CreateController({
	Name = "WallsTransparencyController",
	Client = {},
})

local FADE_TIME = 0.25
local FADED_PART_TRANSPARENCY = 0.75
local FADED_TEXTURE_TRANSPARENCY = 0.95

local toggled = true

-- Capture-once. Records the part's true transparency the first time we ever
-- touch it, before any tween starts. Never overwritten by mid-tween reads.
function WallsTransparencyController:_rememberOriginal(part: BasePart)
	if self._originalPartTransparencies[part] == nil then
		self._originalPartTransparencies[part] = part.Transparency
	end
end

function WallsTransparencyController:_rememberOriginalTexture(obj: Texture | Decal)
	if self._originalTextureTransparencies[obj] == nil then
		self._originalTextureTransparencies[obj] = obj.Transparency
	end
end

function WallsTransparencyController:_fadeOut(part: BasePart)
	if self._activeFades[part] then
		return
	end

	self:_rememberOriginal(part)

	local fade = {
		partTween = nil :: Tween?,
		textureTweens = {} :: { [Instance]: Tween },
		textures = {} :: { Texture | Decal }, -- list (preserves which descendants we touched)
	}

	local partTween = TweenService:Create(part, TweenInfo.new(FADE_TIME), {
		Transparency = FADED_PART_TRANSPARENCY,
	})
	fade.partTween = partTween
	partTween:Play()

	for _, descendant in part:GetDescendants() do
		if descendant:IsA("Texture") or descendant:IsA("Decal") then
			self:_rememberOriginalTexture(descendant)

			local tween = TweenService:Create(descendant, TweenInfo.new(FADE_TIME), {
				Transparency = FADED_TEXTURE_TRANSPARENCY,
			})
			fade.textureTweens[descendant] = tween
			table.insert(fade.textures, descendant)
			tween:Play()
		end
	end

	self._activeFades[part] = fade
end

function WallsTransparencyController:_fadeIn(part: BasePart)
	local fade = self._activeFades[part]
	if not fade then
		return
	end

	-- Cancel any in-flight fade-out tweens so they don't fight the fade-in.
	if fade.partTween then
		fade.partTween:Cancel()
	end
	for _, tween in fade.textureTweens do
		tween:Cancel()
	end

	local originalPart = self._originalPartTransparencies[part]
	if originalPart ~= nil then
		TweenService:Create(part, TweenInfo.new(FADE_TIME), {
			Transparency = originalPart,
		}):Play()
	end

	for _, descendant in fade.textures do
		if descendant.Parent then
			local original = self._originalTextureTransparencies[descendant]
			if original ~= nil then
				TweenService:Create(descendant, TweenInfo.new(FADE_TIME), {
					Transparency = original,
				}):Play()
			end
		end
	end

	self._activeFades[part] = nil
end

-- Drops a part we are holding WITHOUT restoring it. Used when a part
-- becomes OcclusionFadeIgnore mid-hold: something else (a gate tween)
-- now owns its Transparency, so both our fade tweens and our captured
-- "original" are wrong — the capture-once value may have been read
-- mid-tween, and _fadeIn would restore the part to that garbage. Forget
-- it all; the next time we touch the part, after its tween has settled,
-- we capture its true value fresh.
function WallsTransparencyController:_release(part: BasePart)
	local fade = self._activeFades[part]
	if not fade then
		return
	end

	if fade.partTween then
		fade.partTween:Cancel()
	end
	for _, tween in fade.textureTweens do
		tween:Cancel()
	end

	self._activeFades[part] = nil
	self._originalPartTransparencies[part] = nil
	for _, descendant in fade.textures do
		self._originalTextureTransparencies[descendant] = nil
	end
end

function WallsTransparencyController:_InitOcclusionThread()
	self._janitor:Cleanup()

	local ignoreList = {
		workspace.IgnoreInstances.Terrain,
		workspace.IgnoreInstances.Boundaries,
		workspace.Terrain,
		workspace.CurrentCamera,
		workspace.IgnoreInstances.MapMarkers,
		workspace.IgnoreInstances.MagicSpells,
		workspace.PlayerBaseplates,
		workspace.IgnoreInstances.Drops,
		workspace.IgnoreInstances.Zombies,
		workspace.IgnoreInstances.DeadZombies,
		--workspace.IgnoreInstances.Map,
	}

	self._janitor:Add(RunService.Heartbeat:Connect(function()
		if not toggled then
			for part in self._activeFades do
				self:_fadeIn(part)
			end
			return
		end

		local character = Players.LocalPlayer.Character
		local head = character and character:FindFirstChild("Head")
		if not head then
			return
		end

		local ignore = table.clone(ignoreList)
		table.insert(ignore, character)
		-- OTHER PLAYERS are never faded. This system exists for walls; when a
		-- player steps between the camera and you, your own highlight already
		-- keeps you readable. Fading THEM was also actively harmful: the
		-- "original" transparency is captured the FIRST time a part is ever
		-- touched, and player parts change transparency underneath us (helmets
		-- hiding hair, sheathed weapons, hidden accessory handles) -- so a later
		-- brief occlusion "restored" a now-hidden part to its stale visible
		-- value. Ignore every character up front (cheap) AND filter any that
		-- slip through (a character mid-spawn / a hit on a nested part).
		for _, otherPlayer in Players:GetPlayers() do
			if otherPlayer ~= Players.LocalPlayer and otherPlayer.Character then
				table.insert(ignore, otherPlayer.Character)
			end
		end

		local occludedParts = camera:GetPartsObscuringTarget({ head.Position }, ignore)

		local currentFrameParts = {}
		for _, part in ipairs(occludedParts) do
			if part:IsA("BasePart") then
				local model = part:FindFirstAncestorOfClass("Model")
				if model and Players:GetPlayerFromCharacter(model) then
					continue
				end
				-- A part whose Transparency someone else is driving right now
				-- (a dungeon gate tweening up or down) is not ours to fade.
				if part:GetAttribute(Attributes.OcclusionFadeIgnore) then
					continue
				end
				currentFrameParts[part] = true
			end
		end

		for part in currentFrameParts do
			self:_fadeOut(part)
		end

		for part in self._activeFades do
			if part:GetAttribute(Attributes.OcclusionFadeIgnore) then
				-- Became someone else's mid-hold: let go, do NOT "restore".
				self:_release(part)
			elseif not currentFrameParts[part] then
				self:_fadeIn(part)
			end
		end
	end))
end

function WallsTransparencyController:_StopOcclusionThread()
	self._janitor:Cleanup()

	for part in self._activeFades do
		self:_fadeIn(part)
	end
end

function WallsTransparencyController:Toggle(toggle: boolean)
	toggled = toggle
end

function WallsTransparencyController:KnitInit()
	self._janitor = Janitor.new()
	self._activeFades = {} -- BasePart -> { partTween, textureTweens, textures }
	self._originalPartTransparencies = {} -- BasePart -> number (captured once)
	self._originalTextureTransparencies = {} -- Texture|Decal -> number (captured once)
end

function WallsTransparencyController:KnitStart()
	PlayerEventController = Knit.GetController("PlayerEventController")

	PlayerEventController.OnCharacterLoaded:Connect(function()
		self:_InitOcclusionThread()
	end)
end

return WallsTransparencyController
