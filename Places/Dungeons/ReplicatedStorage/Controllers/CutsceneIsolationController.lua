--!strict
--[[
	Module: Controllers/CutsceneIsolationController.lua
	Description:
	Leaves only the local player on screen (2026-11-09, for Susanoo's
	cutscene: ArcaneData cutscene.isolate). While active, on THIS client
	only:
	  * every mob (IgnoreInstances.Mobs), corpse (IgnoreInstances.DeadMobs)
	    and other player's character is hidden;
	  * mob attack telegraphs (MobController's hitbox flashes, tagged with
	    Attributes.MobTelegraph) are hidden;
	  * every Highlight in the world is switched off (2026-11-10);
	  * every sound in the world is muted (2026-11-09: most are positional
	    and loud with the camera this close), but the cutscene's own
	    (Attributes.CutsceneAudio) and music;
	  * another player's server-made spell effects (arriving among the
	    spell effects away from the caster) are hidden;
	  * anything of those that arrives meanwhile is hidden on arrival.
	Other players' client-drawn effects (their casts, swings, shots, and
	mob projectiles) are skipped at the source while the local player is
	mid-arcane-cutscene (isArcaneCutscenePlaying: VFXController,
	MeleeWeaponVFXController, ProjectileCastController).
	Parts and decals take LocalTransparencyModifier = 1, selection boxes
	go invisible, particle emitters, beams, trails, highlights and
	billboards are switched off. Anything switched back on meanwhile (the
	server showing a hit mob's health bar) is hidden again. Each one goes
	back to its latest real value when the window ends.

	Purely visual: hits, hitboxes and mobs keep running on the server.
	Reference-counted, so overlapping cutscenes isolate once and restore
	once. CutsceneController.PlayArcaneCutscene is the caller.
]]

--[ Roblox Services ]--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--[ Imports ]--

local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)

--[ Constants ]--

-- An effect arriving among the spell effects farther than this from the
-- caster is someone else's and is hidden; nearer, it is the caster's own.
local OWN_EFFECT_RADIUS = 20
-- ClientSettingsController's music group: music keeps playing.
local MUSIC_GROUP_NAME = "SettingsMusic"

--[ Module ]--

local CutsceneIsolationController = {
	Name = "CutsceneIsolationController",
}

-- Outstanding SetActive(true) calls.
CutsceneIsolationController._depth = 0
-- [instance] = what to put back (the value of hidingFor's property). Strong keys: a replicated
-- part nothing else references must not drop its restore.
CutsceneIsolationController._originals = {} :: { [Instance]: number | boolean }
CutsceneIsolationController._connections = {} :: { RBXScriptConnection }

--[ Private ]--

-- What hides an instance: the property and its hidden value, or nil.
local function hidingFor(instance: Instance): (string?, any)
	if instance:IsA("BasePart") or instance:IsA("Decal") then
		return "LocalTransparencyModifier", 1
	elseif instance:IsA("Sound") then
		-- The world's sounds are mostly positional, and loud with the
		-- camera this close (2026-11-09).
		return "Volume", 0
	elseif instance:IsA("SelectionBox") then
		-- Draws whatever its part's transparency (telegraph outlines).
		return "Visible", false
	elseif
		instance:IsA("ParticleEmitter")
		or instance:IsA("Beam")
		or instance:IsA("Trail")
		or instance:IsA("Highlight")
		or instance:IsA("BillboardGui")
		or instance:IsA("SurfaceGui")
	then
		return "Enabled", false
	end
	return nil, nil
end

local function hideOne(self: typeof(CutsceneIsolationController), instance: Instance)
	if self._originals[instance] ~= nil then
		return
	end
	local property, hidden = hidingFor(instance)
	if not property then
		return
	end
	local item = instance :: any
	self._originals[instance] = item[property]
	item[property] = hidden
	-- Something switching it back on mid-window (the server showing a hit
	-- mob's health bar) is re-hidden, and its new value is what returns.
	table.insert(
		self._connections,
		instance:GetPropertyChangedSignal(property):Connect(function()
			if item[property] ~= hidden then
				self._originals[instance] = item[property]
				item[property] = hidden
			end
		end)
	)
end

local function hideTree(self: typeof(CutsceneIsolationController), root: Instance)
	hideOne(self, root)
	for _, descendant in root:GetDescendants() do
		hideOne(self, descendant)
	end
	table.insert(
		self._connections,
		root.DescendantAdded:Connect(function(descendant: Instance)
			hideOne(self, descendant)
		end)
	)
end

-- Every child of `folder`, now and arriving (a mob spawning, a corpse).
local function hideFolder(self: typeof(CutsceneIsolationController), folder: Instance?)
	if not folder then
		return
	end
	for _, child in folder:GetChildren() do
		hideTree(self, child)
	end
	table.insert(
		self._connections,
		folder.ChildAdded:Connect(function(child: Instance)
			hideTree(self, child)
		end)
	)
end

local function hideCharacter(self: typeof(CutsceneIsolationController), player: Player)
	if player == Players.LocalPlayer then
		return
	end
	if player.Character then
		hideTree(self, player.Character)
	end
	table.insert(
		self._connections,
		player.CharacterAdded:Connect(function(character: Model)
			hideTree(self, character)
		end)
	)
end

function CutsceneIsolationController._start(self: typeof(CutsceneIsolationController))
	local ignore = workspace:FindFirstChild("IgnoreInstances")
	hideFolder(self, ignore and ignore:FindFirstChild("Mobs"))
	hideFolder(self, ignore and ignore:FindFirstChild("DeadMobs"))

	for _, player in Players:GetPlayers() do
		hideCharacter(self, player)
	end
	table.insert(
		self._connections,
		Players.PlayerAdded:Connect(function(player: Player)
			hideCharacter(self, player)
		end)
	)

	-- Every sound in the world, now and arriving, but the cutscene's own
	-- (Attributes.CutsceneAudio) and music.
	local function considerSound(instance: Instance)
		if
			instance:IsA("Sound")
			and instance:GetAttribute(Attributes.CutsceneAudio) ~= true
			and not (instance.SoundGroup and instance.SoundGroup.Name == MUSIC_GROUP_NAME)
		then
			hideOne(self, instance)
		end
	end
	-- Every Highlight in the world too (2026-11-10): a Highlight draws
	-- over particles, which write no depth, so a drop's or a relic's
	-- outline showed through the Sharingan held in front of the camera.
	local function considerWorld(instance: Instance)
		if instance:IsA("Highlight") then
			hideOne(self, instance)
		else
			considerSound(instance)
		end
	end
	for _, descendant in workspace:GetDescendants() do
		considerWorld(descendant)
	end
	table.insert(self._connections, workspace.DescendantAdded:Connect(considerWorld))

	-- Mob telegraphs live among the spell effects (ArcaneSpells), next to
	-- the caster's own: the tagged ones go. So does any effect arriving
	-- AWAY from the caster (another player's server-made spell parts,
	-- 2026-11-09); the caster's own (Susanoo's rig, its bursts) spawn on
	-- them and stay. Anything stamped Attributes.OwnerId with the local
	-- player's UserId stays wherever it arrives (2026-11-10: Susanoo's rig
	-- arrives 15 studs under its caster to rise and read as too far, so it
	-- stayed hidden all cutscene).
	local spells = ignore and ignore:FindFirstChild("ArcaneSpells")
	if spells then
		local function consider(child: Instance)
			if child:GetAttribute(Attributes.MobTelegraph) == true then
				hideTree(self, child)
				return
			end
			if child:GetAttribute(Attributes.OwnerId) == Players.LocalPlayer.UserId then
				return
			end
			local root = Players.LocalPlayer.Character
				and Players.LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
			local at: Vector3? = nil
			if child:IsA("BasePart") then
				at = child.Position
			elseif child:IsA("Model") then
				at = child:GetPivot().Position
			end
			if root and root:IsA("BasePart") and at and (at - root.Position).Magnitude > OWN_EFFECT_RADIUS then
				hideTree(self, child)
			end
		end
		for _, child in spells:GetChildren() do
			consider(child)
		end
		table.insert(
			self._connections,
			spells.ChildAdded:Connect(function(child: Instance)
				-- The tag is set before the clone is parented.
				consider(child)
			end)
		)
	end
end

function CutsceneIsolationController._stop(self: typeof(CutsceneIsolationController))
	for _, connection in self._connections do
		connection:Disconnect()
	end
	table.clear(self._connections)
	for instance, original in self._originals do
		local property = hidingFor(instance)
		if property and instance.Parent then
			(instance :: any)[property] = original
		end
	end
	table.clear(self._originals)
end

--[ Public ]--

-- Starts (true) or ends (false) one isolation window.
function CutsceneIsolationController.SetActive(self: typeof(CutsceneIsolationController), active: boolean)
	if active then
		self._depth += 1
		if self._depth == 1 then
			self:_start()
		end
		return
	end
	if self._depth == 0 then
		return
	end
	self._depth -= 1
	if self._depth == 0 then
		self:_stop()
	end
end

return CutsceneIsolationController
