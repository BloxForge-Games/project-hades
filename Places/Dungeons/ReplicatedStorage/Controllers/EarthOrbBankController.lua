--!strict
--[[
	Module: EarthOrbBankController
	Description:
	Draws Earth Protection Orb's bank: the orbs a player has stored orbit
	their character. The server (RelicGimmickService/Earth) writes the
	character's EarthOrbBank attribute, one letter per stored orb (H for a
	Health Orb, M for a Mana Orb, nil when empty).

	Every orb in the ring is the DROP'S OWN MODEL (GameAssets.Drops.Default
	styled like DropService styles it), so a banked orb is the orb you saw
	on the floor, now in a slot above you:
	  * The collecting client (Components/Drop) asks WillBank first; on a
	    yes it hands the drop over through Adopt instead of playing the
	    pickup. Adopt clones the drop where it floats and flies the clone
	    into the ring; when the server's attribute grows a beat later the
	    clone becomes that slot. If the server did not bank after all
	    (threshold race) the clone fades out.
	  * Everyone else only sees the attribute grow: a fresh orb fades into
	    the slot.
	  * A spent orb (the attribute shrinks; the bank spends FIFO) sinks
	    into the character and fades.
	Nothing is simulated here beyond the ring's pose on one RenderStepped.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local DropData = require(ReplicatedStorage.Submodules.Core.Shared.Data.DropData)
local DropTypes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.DropTypes)
local RelicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicData)
local RelicNames = require(ReplicatedStorage.Submodules.Core.Shared.Enums.RelicNames)
local getRoot = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Character.getRoot)
local RelicController = require(ReplicatedStorage.Controllers.RelicController)

--[ Constants ]--

-- Written by RelicGimmickService/Earth (ORB_BANK_ATTRIBUTE there).
local ORB_BANK_ATTRIBUTE = "EarthOrbBank"
local ORB_BANK = RelicNames["Earth Protection Orb"]
local LETTER_BY_TYPE: { [string]: string } = {
	[DropTypes.Health] = "H",
	[DropTypes.Mana] = "M",
}
local TYPE_BY_LETTER: { [string]: string } = {
	H = DropTypes.Health,
	M = DropTypes.Mana,
}
-- The arc trail the drop streams while it flies off a corpse; a ring orb
-- never flies that arc, so it stays off (Components/Drop turns it off on
-- landing too). The pickup burst's emitters live under this container
-- and only ever Emit on a collect; a ring orb never runs them.
local ARC_TRAIL_EMITTER_NAME = "DropParticles"
local COLLECT_BURST_NAME = "Collected"
-- The ring the orbs ride: its radius, height above the root, turn time and
-- bob (2026-11-01: slower, higher and wider than the first cut).
local ORBIT_RADIUS = 3.8
local ORBIT_LIFT = 3.1
local ORBIT_SECONDS_PER_TURN = 9
local BOB_HEIGHT = 0.3
local BOB_SECONDS = 2.4
-- Every orb EASES toward its slot each frame instead of sitting on it
-- (the relic renderer's feel): the ring lags a running or rolling
-- character, a new orb drifts in from where it was collected, and the
-- others slide over to make room. The time constant below is the lag
-- (about 0.15 of the gap per frame at 60 fps, like the relics).
local FOLLOW_RATE = 9
-- A fresh orb's fade-in, a spent orb's sink, and how long an adopted drop
-- waits for the server's word.
local FADE_SECONDS = 0.4
local SPEND_SECONDS = 0.35
local ADOPT_GRACE_SECONDS = 1.0

--[ Types ]--

type Orb = {
	model: Model,
	primary: BasePart,
	-- Where it is now; eased toward its slot every frame.
	position: Vector3,
}

type Pending = {
	orb: Orb,
	letter: string,
	at: number,
}

type Entry = {
	character: Model,
	orbs: { Orb },
	-- The letters the ring was last built from, to tell WHICH slot a spend
	-- removed (the bank spends by kind, not always the oldest).
	letters: string,
	pending: Pending?,
	connection: RBXScriptConnection,
}

--[ Module ]--

local EarthOrbBankController = {
	Name = "EarthOrbBankController",
}

local entries: { [Model]: Entry } = {}

--[ Helpers ]--

local function effectsFolder(): Instance
	local ignore = workspace:FindFirstChild("IgnoreInstances")
	return (ignore and ignore:FindFirstChild("ArcaneSpells")) or ignore or workspace
end

local function dropTemplate(): Model?
	local assets = ReplicatedStorage:FindFirstChild("GameAssets")
	local drops = assets and assets:FindFirstChild("Drops")
	local template = drops and drops:FindFirstChild("Default")
	return if template and template:IsA("Model") then template else nil
end

-- Styles a Default drop clone the way the server's Drop component does.
local function styleAsOrb(model: Model, dropType: string)
	local row = DropData[dropType]
	local primary = model.PrimaryPart
	local billboard = primary and primary:FindFirstChild("BillboardGui")
	local image = billboard and billboard:FindFirstChild("Image")
	if billboard and billboard:IsA("BillboardGui") then
		billboard.Enabled = true
		billboard.Size = row.size
	end
	if image and image:IsA("ImageLabel") then
		image.Image = row.image
		image.ImageColor3 = row.color
	end
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("ParticleEmitter") then
			descendant.Color = ColorSequence.new(row.color)
			-- Everything else keeps its authored state: the idle shine runs,
			-- the arc trail and the pickup burst never do.
			if descendant.Name == ARC_TRAIL_EMITTER_NAME or descendant:FindFirstAncestor(COLLECT_BURST_NAME) then
				descendant.Enabled = false
			end
		elseif descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
		end
	end
end

local function orbImage(orb: Orb): ImageLabel?
	local billboard = orb.primary:FindFirstChild("BillboardGui")
	local image = billboard and billboard:FindFirstChild("Image")
	return if image and image:IsA("ImageLabel") then image else nil
end

local function setEmitters(orb: Orb, enabled: boolean)
	for _, descendant in orb.model:GetDescendants() do
		if
			descendant:IsA("ParticleEmitter")
			and descendant.Name ~= ARC_TRAIL_EMITTER_NAME
			and not descendant:FindFirstAncestor(COLLECT_BURST_NAME)
		then
			descendant.Enabled = enabled
		end
	end
end

-- A clean ring orb from the drop template, at `position`, faded in.
local function makeOrb(dropType: string, position: Vector3): Orb?
	local template = dropTemplate()
	if not template then
		return nil
	end
	local model = template:Clone()
	for _, tag in model:GetTags() do
		model:RemoveTag(tag)
	end
	model.Name = "EarthBankOrb"
	styleAsOrb(model, dropType)
	local primary = model.PrimaryPart
	if not primary then
		model:Destroy()
		return nil
	end
	model:PivotTo(CFrame.new(position))
	local orb: Orb = { model = model, primary = primary, position = position }
	local image = orbImage(orb)
	if image then
		image.ImageTransparency = 1
		TweenService:Create(image, TweenInfo.new(FADE_SECONDS), { ImageTransparency = 0 }):Play()
	end
	model.Parent = effectsFolder()
	return orb
end

-- The orb sinks into the character and fades (a spend), or just fades.
local function retireOrb(orb: Orb, sinkTo: Vector3?)
	setEmitters(orb, false)
	local image = orbImage(orb)
	if image then
		TweenService:Create(image, TweenInfo.new(SPEND_SECONDS), { ImageTransparency = 1 }):Play()
	end
	if sinkTo then
		local sink = TweenInfo.new(SPEND_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		TweenService:Create(orb.primary, sink, { CFrame = CFrame.new(sinkTo) }):Play()
	end
	task.delay(SPEND_SECONDS + 0.05, function()
		orb.model:Destroy()
	end)
end

local function slotPosition(root: BasePart, index: number, count: number, now: number): Vector3
	local baseAngle = (now / ORBIT_SECONDS_PER_TURN) * math.pi * 2
	local bob = math.sin((now / BOB_SECONDS) * math.pi * 2) * BOB_HEIGHT
	local angle = baseAngle + (index - 1) * (math.pi * 2 / math.max(count, 1))
	local offset = Vector3.new(math.cos(angle), 0, math.sin(angle)) * ORBIT_RADIUS
	return root.Position + offset + Vector3.new(0, ORBIT_LIFT + bob, 0)
end

-- Matches the entry's orbs to the attribute: a longer string adds a slot
-- at the end (the adopted drop if one is waiting with the same letter, a
-- fresh orb fading in otherwise), a shorter string spends the OLDEST, and
-- a recoloured slot is rebuilt.
local function syncEntry(entry: Entry)
	local value = entry.character:GetAttribute(ORB_BANK_ATTRIBUTE)
	local letters = if type(value) == "string" then value else ""
	local wanted = #letters
	local root = getRoot(entry.character)
	local sinkTo = root and (root.Position + Vector3.new(0, 1, 0)) or nil
	-- A spend removes one letter somewhere in the string: retire the slot
	-- at the first position that no longer matches (the last when the
	-- prefix still matches), so the orb that sinks is the one that was
	-- spent and the rest slide over.
	local previous = entry.letters
	while #entry.orbs > wanted do
		local removeAt = #entry.orbs
		for index = 1, #previous do
			if string.sub(previous, index, index) ~= string.sub(letters, index, index) then
				removeAt = math.min(index, #entry.orbs)
				break
			end
		end
		retireOrb(table.remove(entry.orbs, removeAt) :: Orb, sinkTo)
		previous = string.sub(previous, 1, removeAt - 1) .. string.sub(previous, removeAt + 1)
	end
	entry.letters = letters
	for index = 1, wanted do
		local letter = string.sub(letters, index, index)
		local dropType = TYPE_BY_LETTER[letter] or DropTypes.Health
		local orb: Orb? = entry.orbs[index]
		if orb and orb.model:GetAttribute("BankLetter") ~= letter then
			retireOrb(orb, nil)
			orb = nil
		end
		if not orb then
			local pending = entry.pending
			if pending and pending.letter == letter and pending.orb.model.Parent then
				entry.pending = nil
				orb = pending.orb
			else
				local at = if root then slotPosition(root, index, wanted, os.clock()) else Vector3.zero
				orb = makeOrb(dropType, at)
			end
			if orb then
				orb.model:SetAttribute("BankLetter", letter)
				entry.orbs[index] = orb
			end
		end
	end
end

local function dropEntry(character: Model)
	local entry = entries[character]
	if not entry then
		return
	end
	entries[character] = nil
	entry.connection:Disconnect()
	for _, orb in entry.orbs do
		retireOrb(orb, nil)
	end
	if entry.pending then
		retireOrb(entry.pending.orb, nil)
	end
end

local function ensureEntry(character: Model): Entry
	local existing = entries[character]
	if existing then
		return existing
	end
	local entry: Entry = {
		character = character,
		orbs = {},
		letters = "",
		pending = nil,
		connection = character:GetAttributeChangedSignal(ORB_BANK_ATTRIBUTE):Connect(function()
			local live = entries[character]
			if live then
				syncEntry(live)
			end
		end),
	}
	entries[character] = entry
	syncEntry(entry)
	return entry
end

local function watchPlayer(player: Player)
	if player.Character then
		ensureEntry(player.Character)
	end
	player.CharacterAdded:Connect(function(character: Model)
		ensureEntry(character)
	end)
	player.CharacterRemoving:Connect(dropEntry)
end

-- The fraction of its max the local player's bar is at, as the server
-- would read it (Health off the Humanoid, Mana off the character's
-- attributes). Nil when it cannot be read.
local function localBarFraction(dropType: string): number?
	local character = Players.LocalPlayer.Character
	if not character then
		return nil
	end
	if dropType == DropTypes.Health then
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if not humanoid or humanoid.MaxHealth <= 0 then
			return nil
		end
		return humanoid.Health / humanoid.MaxHealth
	end
	local mana = character:GetAttribute("Mana")
	local maxMana = character:GetAttribute("MaxMana")
	if type(mana) ~= "number" or type(maxMana) ~= "number" or maxMana <= 0 then
		return nil
	end
	return mana / maxMana
end

--[ Public ]--

-- The collecting client's prediction of RelicGimmickService/Earth's
-- interceptOrb: owns the relic, the matching bar is FULL and the bank has
-- room. A wrong guess only costs a visual (see Adopt).
function EarthOrbBankController.WillBank(_self: typeof(EarthOrbBankController), dropType: string): boolean
	if not LETTER_BY_TYPE[dropType] then
		return false
	end
	local registry = RelicController:GetRelicsFromUserId(Players.LocalPlayer.UserId)
	if not registry or (registry[ORB_BANK] or 0) <= 0 then
		return false
	end
	local data = (RelicData[ORB_BANK] and RelicData[ORB_BANK].data) or {}
	local fraction = localBarFraction(dropType)
	if fraction == nil or fraction < (data.storeThreshold or 0.95) - 0.001 then
		return false
	end
	local character = Players.LocalPlayer.Character
	local value = character and character:GetAttribute(ORB_BANK_ATTRIBUTE)
	local held = if type(value) == "string" then #value else 0
	return held < (data.maxOrbs or 5)
end

-- The local drop `dropModel` is being banked: clone it where it floats,
-- hide the original (the server destroys it on collect) and fly the clone
-- into the ring. The clone becomes the new slot when the attribute grows
-- (syncEntry); if that never comes it fades out after ADOPT_GRACE_SECONDS.
function EarthOrbBankController.Adopt(_self: typeof(EarthOrbBankController), dropModel: Model, dropType: string)
	local character = Players.LocalPlayer.Character
	local primary = dropModel.PrimaryPart
	if not character or not primary then
		return
	end
	local letter = LETTER_BY_TYPE[dropType]
	if not letter then
		return
	end
	local clone = dropModel:Clone()
	for _, tag in clone:GetTags() do
		clone:RemoveTag(tag)
	end
	clone.Name = "EarthBankOrb"
	styleAsOrb(clone, dropType)
	local clonePrimary = clone.PrimaryPart
	if not clonePrimary then
		clone:Destroy()
		return
	end
	-- The original goes quiet at once; the server's destroy follows.
	for _, descendant in dropModel:GetDescendants() do
		if descendant:IsA("ParticleEmitter") then
			descendant.Enabled = false
		elseif descendant:IsA("BillboardGui") then
			(descendant :: BillboardGui).Enabled = false
		end
	end
	clone.Parent = effectsFolder()
	local orb: Orb = { model = clone, primary = clonePrimary, position = primary.Position }
	local entry = ensureEntry(character)
	if entry.pending then
		retireOrb(entry.pending.orb, nil)
	end
	entry.pending = { orb = orb, letter = letter, at = os.clock() }
	task.delay(ADOPT_GRACE_SECONDS, function()
		local live = entries[character]
		if live and live.pending and live.pending.orb == orb then
			live.pending = nil
			retireOrb(orb, nil)
		end
	end)
end

--[ Lifecycle ]--

local function easeToward(orb: Orb, target: Vector3, dt: number)
	local alpha = 1 - math.exp(-dt * FOLLOW_RATE)
	orb.position = orb.position:Lerp(target, alpha)
	orb.primary.CFrame = CFrame.new(orb.position)
end

local function step(dt: number)
	local now = os.clock()
	for character, entry in entries do
		local root = getRoot(character)
		if not root or not character.Parent then
			dropEntry(character)
			continue
		end
		local count = #entry.orbs
		for index, orb in entry.orbs do
			easeToward(orb, slotPosition(root, index, count, now), dt)
		end
		-- An adopted drop still waiting for the server drifts toward the
		-- slot it will take (the one past the last).
		local pending = entry.pending
		if pending and pending.orb.model.Parent then
			easeToward(pending.orb, slotPosition(root, count + 1, count + 1, now), dt)
		end
	end
end

function EarthOrbBankController.Start(_self: typeof(EarthOrbBankController))
	for _, player in Players:GetPlayers() do
		watchPlayer(player)
	end
	Players.PlayerAdded:Connect(watchPlayer)
	RunService.RenderStepped:Connect(step)
end

return EarthOrbBankController
