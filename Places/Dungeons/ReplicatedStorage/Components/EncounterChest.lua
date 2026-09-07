--[[
	Module: Client/Components/EncounterChest.lua
	Description:
	The Miniboss / Boss reward chest's DROP presentation — a deliberate fork
	of Client/Components/RelicMachine.lua's fall half, per design: the chest
	should feel exactly like a vending machine landing, with the machine
	swapped for a chest. Same raycast-settled fall, same squash (0.75 →
	elastic 1), same LandParticle smoke + Landing thud (the server grafts
	those exact instances from the machine template onto the chest), same
	nearby camera shake, same owner-only prompt enable after the settle.

	WHAT IS DIFFERENT FROM THE MACHINE FORK, AND WHY:
	  * The billboard and glow rig are AUTHORED INTO THE PREFABS (same
	    VendingMachineName / NameText / VendingMachineText rig the machines
	    use), so they are found by name and class here rather than by the
	    machine's hardcoded paths — the two chests' rigs differ.
	  * Squash multiplies the model's AUTHORED scale (GetScale) instead of
	    tweening to absolute 0.75/1: the chest prefabs are scaled in Studio
	    (MinibossChest ships at 1.35), and the machine's absolute values
	    would stomp that.
	  * The fall tween moves EVERY BasePart by one shared delta rather than
	    naming parts — the machine has exactly two known parts, the chests
	    are arbitrary meshes.

	OPENING: the server (EncounterChestService) owns Triggered and the loot,
	but the lid swing is played HERE, locally, when the server flips the
	Opened attribute — the first pass stepped the lid on the server and it
	replicated at network rate, which read as lag. The opened chest stays
	in the world (no fade, no despawn — per design).
]]

--[ Roblox Services ]--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

--[ Imports ]--

local Component = require(ReplicatedStorage.Submodules.Core.Packages.Component)
local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local CameraShakePresets = require(ReplicatedStorage.Submodules.Core.Shared.Enums.CameraShakePresets)
local chestLidSwing = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.chestLidSwing)
local lootSound = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.lootSound)

local CameraShakeController

Knit.OnStart()
	:andThen(function()
		CameraShakeController = Knit.GetController("CameraShakeController")
	end)
	:catch(warn)

--[ Constants ]--

-- All timings and magnitudes mirror Client/Components/RelicMachine.lua so
-- the two drops are indistinguishable beat-for-beat.
local FALL_TWEEN_SECONDS = 1
local SQUASH_SCALE = 0.75
local SQUASH_DELAY = 0.5
local SQUASH_SETTLE_SECONDS = 2
local LAND_FX_DELAY = 0.35
local PROMPT_ENABLE_DELAY = 0.5
local LAND_PARTICLE_COUNT = 10
local LANDING_SHAKE_RANGE_STUDS = 25
local NON_OWNER_TRANSPARENCY = 0.65
-- The NAMEPLATE fades harder than the model does. The machine uses 0.65
-- for both, but a chest sits on the floor where several nameplates
-- stack up in one view — someone else's has to sit further back than
-- the machine's does to stop it competing with your own.
local NON_OWNER_TEXT_TRANSPARENCY = 0.85
-- Tiny lift to stop the chest's bottom face z-fighting the floor. The
-- machine's whole extra stud of hover is deliberately NOT ported — it
-- is why the first pass floated.
-- How long the single motion driver runs: fall + squash delay + elastic
-- settle, plus slack, then it snaps the exact rest pose and disconnects.
local DRIVER_LIFETIME_SECONDS = FALL_TWEEN_SECONDS + SQUASH_DELAY + SQUASH_SETTLE_SECONDS + 0.25
-- Studs above the rest pose the LOCAL fall starts from (the machine's
-- drop height). The server never moves the chest — it replicates only
-- the final rest pose, and this component plays the whole descent
-- locally, landing exactly on that replicated truth.
local DROP_HEIGHT_STUDS = 25
-- Opening presentation, played LOCALLY when the server flips the
-- Opened attribute — a server-stepped lid replicated at network rate
-- and read as lag. The swing itself is shared with the Treasure room
-- chest (Shared/Functions/VFX/chestLidSwing).
local OPENED_ATTRIBUTE = "Opened"
-- Spent dressing: the billboard goes red-(Inactive), every emitter
-- stops dead, and the glow FADES rather than cutting (per design).
local LIGHT_FADE_SECONDS = 1
local INACTIVE_COLOR = Color3.fromRGB(255, 85, 85)
local CHEST_NAME_ATTRIBUTE = "ChestName"
local BILLBOARD_NAME = "VendingMachineName"
local STATUS_LABEL_NAME = "VendingMachineText"
-- How long to wait on a billboard part that has not replicated yet.
-- Generous: missing the flip leaves a spent chest reading "(Active)".
local BILLBOARD_WAIT_SECONDS = 10
-- Same idea for the grafted prompt Attachment (see Construct).
local PROMPT_WAIT_SECONDS = 10

--[ Component ]--

local EncounterChest = Component.new({
	Tag = TagList.EncounterChest,
})

function EncounterChest:Construct()
	-- The prompt is the machine template's own Attachment.ProximityPrompt,
	-- grafted on by the server — so it carries the Style attribute the
	-- custom prompt renderer keys off, exactly like a vending machine's.
	-- WAITED for, not indexed: the tag can replicate (and construct us)
	-- a frame before the grafted Attachment does, which threw here
	-- intermittently. A chest whose prompt never arrives still opens
	-- (the two prompt writes below are nil-safe); it just warns.
	local primary = self.Instance.PrimaryPart or self.Instance:WaitForChild("Treasure", PROMPT_WAIT_SECONDS)
	local attachment = primary and primary:WaitForChild("Attachment", PROMPT_WAIT_SECONDS)
	self._proximityPrompt = attachment and attachment:WaitForChild("ProximityPrompt", PROMPT_WAIT_SECONDS)
	if not self._proximityPrompt then
		warn(
			("[EncounterChest] %s: no Attachment.ProximityPrompt replicated within %ds"):format(
				self.Instance:GetFullName(),
				PROMPT_WAIT_SECONDS
			)
		)
	end
	self._ownerId = self.Instance:GetAttribute(Attributes.OwnerId)
	self._baseScale = self.Instance:GetScale()
	self._numberValue = Instance.new("NumberValue")
	self._numberValue.Value = 1
	self._numberValue.Name = "ChestScale"
	self._numberValue.Parent = self.Instance
end

-- The lid swing, at full local framerate.
function EncounterChest:_playOpen()
	if self._openPlayed then
		return
	end
	self._openPlayed = true
	-- The chest persists after opening — kill the prompt locally too, so
	-- it can never come back (the delayed owner enable also checks the
	-- flag above).
	if self._proximityPrompt then
		self._proximityPrompt.Enabled = false
	end
	lootSound:PlayChestOpen(self.Instance.PrimaryPart)

	-- Billboard: green (Active) to red (Inactive), the machine's own
	-- spent language.
	self:_setBillboardSpent()

	-- Emitters stop immediately; the glow fades out over a beat. Found by
	-- CLASS rather than by path so both prefabs' glow rigs are covered
	-- whatever they are named.
	for _, descendant in self.Instance:GetDescendants() do
		if descendant:IsA("Light") then
			TweenService:Create(descendant, TweenInfo.new(LIGHT_FADE_SECONDS), { Brightness = 0 }):Play()
		elseif
			descendant:IsA("ParticleEmitter")
			or descendant:IsA("Beam")
			or descendant:IsA("Trail")
			or descendant:IsA("Sparkles")
			or descendant:IsA("Fire")
			or descendant:IsA("Smoke")
		then
			descendant.Enabled = false
		end
	end

	-- Faded to nothing: switch the lights off so they stop costing a
	-- light slot on the render budget.
	task.delay(LIGHT_FADE_SECONDS, function()
		if not self.Instance.Parent then
			return
		end
		for _, descendant in self.Instance:GetDescendants() do
			if descendant:IsA("Light") then
				descendant.Enabled = false
			end
		end
	end)

	if self._driver then
		-- The driver PivotTo-s the whole model (lid included) every frame
		-- and would stomp the swing, so retire it and settle the scale —
		-- the prompt only enables 1.5s in, so any residual elastic wobble
		-- being cut short here is imperceptible.
		self._driver:Disconnect()
		self._driver = nil
		self.Instance:ScaleTo(self._baseScale)
	end

	-- The chest is placed facing the player (no 180-degree model flip),
	-- so the default hinge edge is the one away from them.
	if not chestLidSwing:Play(self.Instance) then
		warn(
			("[EncounterChest] '%s' has no part ending in 'Lid' — opening without a lid swing"):format(
				self.Instance:GetFullName()
			)
		)
	end

	-- The opened chest deliberately stays in the world — no fade (per
	-- design).
end

-- The non-owner treatment for ONE instance.
--
-- Split out per-instance because a model replicates PROGRESSIVELY: a
-- UIStroke (or its TextLabel, or the whole BillboardGui) can arrive
-- after Start has already swept GetDescendants, and anything that
-- misses the sweep keeps its AUTHORED value forever. For the stroke
-- that authored value is opaque dark navy, so the miss does not read
-- as "not faded" — it reads as text that is DARKER than the owner's,
-- which is the intermittent bug this replaced.
function EncounterChest:_muteForNonOwner(instance: Instance)
	if instance:IsA("BasePart") then
		instance.LocalTransparencyModifier = NON_OWNER_TRANSPARENCY
		instance.CanCollide = false
	elseif
		instance:IsA("ParticleEmitter")
		or instance:IsA("Beam")
		or instance:IsA("Trail")
		or instance:IsA("Sparkles")
		or instance:IsA("Fire")
		or instance:IsA("Smoke")
		or instance:IsA("Light")
	then
		-- Enabled only gates CONTINUOUS emission — the landing burst
		-- still :Emit()s, so the drop keeps its impact.
		instance.Enabled = false
	elseif instance:IsA("TextLabel") then
		instance.TextTransparency = NON_OWNER_TEXT_TRANSPARENCY
	elseif instance:IsA("UIStroke") then
		instance.Transparency = NON_OWNER_TEXT_TRANSPARENCY
	elseif instance:IsA("BillboardGui") then
		-- Someone else's nameplate should not punch through the world.
		instance.AlwaysOnTop = false
	end
end

-- Flips the billboard to a red "(Inactive)". WAITS for the label rather
-- than snapshotting it: a chest opened the instant it replicates would
-- otherwise keep reading "(Active)" for the rest of the run.
function EncounterChest:_setBillboardSpent()
	task.spawn(function()
		local primary = self.Instance.PrimaryPart
		local billboard = primary and primary:WaitForChild(BILLBOARD_NAME, BILLBOARD_WAIT_SECONDS)
		local frame = billboard and billboard:WaitForChild("Frame", BILLBOARD_WAIT_SECONDS)
		local statusLabel = frame and frame:WaitForChild(STATUS_LABEL_NAME, BILLBOARD_WAIT_SECONDS)
		if not statusLabel or not statusLabel:IsA("TextLabel") or not self.Instance.Parent then
			return
		end

		-- The name comes off the attribute the server stamped, so the two
		-- sides cannot drift.
		local displayName = self.Instance:GetAttribute(CHEST_NAME_ATTRIBUTE)
		statusLabel.Text = tostring(displayName or "Chest") .. " (Inactive)"
		statusLabel.TextColor3 = INACTIVE_COLOR
	end)
end

function EncounterChest:Start()
	local isOwner = Players.LocalPlayer.UserId == self._ownerId

	-- Someone else's chest: semi-hidden and untouchable, the machine's
	-- treatment for non-owners. Everything here is applied per instance
	-- and re-applied to whatever replicates LATER — see the note on
	-- _muteForNonOwner.
	if not isOwner then
		for _, descendant in self.Instance:GetDescendants() do
			self:_muteForNonOwner(descendant)
		end
		self._nonOwnerWatch = self.Instance.DescendantAdded:Connect(function(descendant: Instance)
			self:_muteForNonOwner(descendant)
		end)
	end

	-- The replicated pose IS the rest pose — the server places the chest
	-- seated and never animates. Everything below is a purely local
	-- visual that starts DROP_HEIGHT_STUDS up and lands back on exactly
	-- this pose, so replication has nothing to disagree with (the lid
	-- seam came from server fall CFrames racing client ones per part).
	local restPivot = self.Instance:GetPivot()
	local restY = restPivot.Position.Y
	local bboxCFrame, bboxSize = self.Instance:GetBoundingBox()
	local bottomOffset = restY - (bboxCFrame.Position.Y - bboxSize.Y / 2)
	local restRotation = restPivot.Rotation

	-- ONE motion driver, fixed order every frame: scale, then seat the
	-- pivot. The first pass ran part-Position tweens and ScaleTo
	-- concurrently, and ScaleTo re-lays-out every part around the pivot
	-- on each change — two systems stomping the same parts, which is why
	-- the 1.35-scaled MinibossChest jittered while the 1.0 BossChest
	-- mostly got away with it.
	local fallAlpha = Instance.new("NumberValue")
	fallAlpha.Value = 0
	fallAlpha.Parent = self.Instance
	TweenService:Create(
		fallAlpha,
		TweenInfo.new(FALL_TWEEN_SECONDS, Enum.EasingStyle.Cubic, Enum.EasingDirection.InOut),
		{ Value = 1 }
	):Play()

	-- Opened (any client, replicated attribute): play the open locally.
	self.Instance:GetAttributeChangedSignal(OPENED_ATTRIBUTE):Connect(function()
		if self.Instance:GetAttribute(OPENED_ATTRIBUTE) == true then
			self:_playOpen()
		end
	end)
	if self.Instance:GetAttribute(OPENED_ATTRIBUTE) == true then
		self:_playOpen()
		return
	end

	local startTime = tick()
	local driver
	driver = RunService.Heartbeat:Connect(function()
		if not self.Instance.Parent or not self.Instance.PrimaryPart then
			driver:Disconnect()
			self._driver = nil
			return
		end
		local squash = self._numberValue.Value
		self.Instance:ScaleTo(self._baseScale * squash)
		-- Bottom-anchored squash about the REST pose: the model's lowest
		-- point stays put while the body compresses and stretches above it.
		local seatedY = restY + bottomOffset * (squash - 1)
		local y = seatedY + DROP_HEIGHT_STUDS * (1 - fallAlpha.Value)
		self.Instance:PivotTo(CFrame.new(restPivot.Position.X, y, restPivot.Position.Z) * restRotation)

		if tick() - startTime >= DRIVER_LIFETIME_SECONDS then
			-- Snap the exact replicated rest pose and stop — from here the
			-- local view and the server's truth are identical.
			self.Instance:ScaleTo(self._baseScale)
			self.Instance:PivotTo(restPivot)
			fallAlpha:Destroy()
			driver:Disconnect()
			self._driver = nil
		end
	end)
	self._driver = driver

	self._numberValue.Value = SQUASH_SCALE

	task.delay(SQUASH_DELAY, function()
		if not self.Instance.Parent then
			return
		end
		TweenService:Create(
			self._numberValue,
			TweenInfo.new(SQUASH_SETTLE_SECONDS, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out),
			{ Value = 1 }
		):Play()

		task.delay(LAND_FX_DELAY, function()
			if not self.Instance.Parent or not self.Instance.PrimaryPart then
				return
			end
			local landParticle = self.Instance.PrimaryPart:FindFirstChild("LandParticle")
			if landParticle and landParticle:IsA("ParticleEmitter") then
				landParticle:Emit(LAND_PARTICLE_COUNT)
			end
			local landing = self.Instance.PrimaryPart:FindFirstChild("Landing")
			if landing and landing:IsA("Sound") then
				landing:Play()
			end

			local character = Players.LocalPlayer.Character
			local hrp = character and character:FindFirstChild("HumanoidRootPart")
			if
				CameraShakeController
				and hrp
				and (hrp.Position - self.Instance.PrimaryPart.Position).Magnitude <= LANDING_SHAKE_RANGE_STUDS
			then
				CameraShakeController:Shake(CameraShakePresets.Small)
			end
		end)

		task.delay(PROMPT_ENABLE_DELAY, function()
			if isOwner and self.Instance.Parent and not self._openPlayed then
				if self._proximityPrompt then
					self._proximityPrompt.Enabled = true
				end
			end
		end)
	end)
end

function EncounterChest:Stop()
	if self._nonOwnerWatch then
		self._nonOwnerWatch:Disconnect()
		self._nonOwnerWatch = nil
	end
end

return EncounterChest
