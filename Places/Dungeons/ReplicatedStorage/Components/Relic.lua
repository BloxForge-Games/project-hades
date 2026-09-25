--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Component = require(ReplicatedStorage.Submodules.Core.Packages.Component)
local DropFloatController = require(ReplicatedStorage.Controllers.DropFloatController)
local waitForPrimaryPart = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Drop.waitForPrimaryPart)
local TagList = require(ReplicatedStorage.Submodules.Core.Shared.Enums.TagList)
local JanitorAdder = require(ReplicatedStorage.Submodules.Core.Source.ComponentExtensions.JanitorAdder)
local ScreenGradientInterfaceController = require(ReplicatedStorage.Interfaces.ScreenGradientInterfaceController)
local RelicNetwork = require(ReplicatedStorage.Submodules.Core.Source.Network.Relic)
local InstanceRouter = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Network.InstanceRouter)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)
local RelicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.RelicData)
local SkipRelicData = require(ReplicatedStorage.Submodules.Core.Shared.Data.SkipRelicData)
local RarityColors = require(ReplicatedStorage.Submodules.Core.Shared.Data.RarityColors)
local getRelicDescription = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Relic.getRelicDescription)
local dressRelicDisplay = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Relic.dressRelicDisplay)
local buildPromptCard = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Relic.buildPromptCard)
local lootSound = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.lootSound)
local emitVFXPart = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.emitVFXPart)
local fadeSubtree = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.fadeSubtree)
local getRoot = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Character.getRoot)
local arcPath = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Drop.arcPath)
local privateDropVisibility = require(ReplicatedStorage.Submodules.Core.Shared.Functions.Drop.privateDropVisibility)

local localPlayer = Players.LocalPlayer

local Y_POS_OFFSET = 3
-- The pickup bursts, both tinted to the relic's rarity and both parts
-- whose attachment emitters carry their own EmitCount / EmitDelay /
-- EmitDuration (emitVFXPart reads them):
--   * CollectRelicVFX           at the RELIC, where it was taken;
--   * CollectRelicVFXCharacter  on the COLLECTOR's character.
-- Played by every client off the replicated CollectedById (see
-- _playCollectedFade) -- not off the collector-only accept signal, which
-- is why nobody else used to see them.
local COLLECT_RELIC_VFX_NAME = "CollectRelicVFX"
local COLLECT_RELIC_CHARACTER_VFX_NAME = "CollectRelicVFXCharacter"
-- The prefabs' authored particle lifetimes read as a snap; every emitter
-- lingers this much longer (emitVFXPart's LifetimeScale), the body burst
-- more than the relic one.
local COLLECT_RELIC_VFX_LIFETIME_SCALE = 1.5
local COLLECT_RELIC_CHARACTER_VFX_LIFETIME_SCALE = 2
-- The landed float (DropFloatController): a slow tumble about this axis
-- (in the relic's own frame) at ROTATION_SPEED degrees per second along
-- it, and a gentle bob about the landing pose. The bob used to be a
-- PER-FRAME increment of 0.01-0.015 added to wherever the relic already
-- was, which integrated to roughly a third of a stud at 60 fps (and less
-- at lower frame rates); these are the studs the fixed bob actually
-- travels, sized to read the same.
local ROTATION_SPEED = 20
local ROTATION_AXIS = Vector3.new(1, 1.5, 0.5)
local BOB_AMPLITUDE_MIN = 0.15
local BOB_AMPLITUDE_MAX = 0.35
local BOB_CYCLE_MIN = 2
local BOB_CYCLE_MAX = 3.5
-- How long Construct waits for a streamed-in descendant before giving up.
local STREAM_WAIT_SECONDS = 10

-- Mirrors the server's PICKUP_FADE_SECONDS, which times the destroy.
local PICKUP_FADE_SECONDS = 0.75
-- The fade-in on spawn, and the (zero-length) hide of someone else's
-- owner-locked relic.
local FADE_IN_INFO = TweenInfo.new(1, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out)
local HIDE_INFO = TweenInfo.new(0, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out)

-- The prompt card's UserText line: "(name)" of the player who DROPPED this
-- item from their tray (DroppedByName, stamped by DropService /
-- GearDropService on a public drop; a name, so it survives them leaving).
-- Empty -- the card hides the line -- for anything else: a vending
-- machine's relic is not yours until you take it, so no name on it.
local function ownerUserText(instance: Instance): string
	if instance:GetAttribute("PublicDrop") ~= true then
		return ""
	end
	local name = instance:GetAttribute("DroppedByName")
	return if typeof(name) == "string" and name ~= "" then ("(%s)"):format(name) else ""
end

local acceptedRouter = InstanceRouter.Client(RelicNetwork.RelicCollectAccepted)

local Relic = Component.new({
	Tag = TagList.Relic,
	Extensions = { JanitorAdder } :: { any },
})

function Relic:Construct()
	self._gone = false
	self._amplitude = Random.new():NextNumber(BOB_AMPLITUDE_MIN, BOB_AMPLITUDE_MAX)
	self._durationPerCycle = Random.new():NextNumber(BOB_CYCLE_MIN, BOB_CYCLE_MAX)
	-- The parts can stream in after the tagged Model does; wait for them.
	-- PrimaryPart is the invisible anchor (billboard adornee, particle
	-- rig); the Handle is the visible mesh Start flies and fades.
	local anchor = waitForPrimaryPart(self.Instance)
	if not anchor then
		-- Taken / expired while still streaming in: nothing to build, and
		-- Start checks _gone. Anything else is a real failure.
		if self.Instance.Parent == nil then
			self._gone = true
			return
		end
		error("[Relic] PrimaryPart never replicated for " .. self.Instance:GetFullName())
	end
	-- Start (and what runs after it) reads these directly. The server
	-- spawns the model atomic, so they normally arrive with it; the waits
	-- cover an asset that is not, and turn a random "not a valid member"
	-- crash into a clear timeout. Nil only when the model left the
	-- DataModel mid-wait (taken / expired while streaming in): Construct
	-- then bails and Start checks _gone.
	local function need(parent: Instance?, name: string): Instance?
		if parent == nil or self._gone then
			return nil
		end
		local child = parent:WaitForChild(name, STREAM_WAIT_SECONDS)
		if child == nil and self.Instance.Parent == nil then
			self._gone = true
			return nil
		end
		assert(child, ("[Relic] %s never replicated under %s"):format(name, parent:GetFullName()))
		return child
	end
	local handle = need(self.Instance, "Handle")
	self._relicParticleAttachment = need(anchor, "RelicParticleAttachment")
	self._dropParticles = need(need(handle, "DropAttachment"), "DropParticles")
	if self._gone then
		return
	end
	self._primaryPart = handle
	self._consumed = false
	self._isBoss = self.Instance:GetAttribute(Attributes.IsBoss)
	self._originPosition = self.Instance:GetPivot().Position
	self._intermediatePosition = self._originPosition + Vector3.new(0, math.random(7, 10), 0)
	self._endPosition = self.Instance:GetAttribute("TargetPosition") + Vector3.new(0, Y_POS_OFFSET, 0)
	-- One or two bezier legs: a BouncePosition (the server's wall hit, see
	-- resolveArcLanding) splits the flight there and the second leg carries
	-- on to TargetPosition, so the ricochet is visible.
	self._arc, self._arcDurationScale = arcPath(
		self._originPosition,
		self._intermediatePosition,
		self._endPosition,
		self.Instance:GetAttribute(Attributes.BouncePosition)
	)
	self._numberValue = Instance.new("NumberValue")
	self._numberValue.Value = 1.5
	self._numberValue.Name = "RelicScale"
	self._numberValue.Parent = self.Instance
	self._connection = nil
	self._relicParticles = ReplicatedStorage.GameAssets.Particles.RelicParticles:Clone()
	self._relicParticles.Parent = handle
end

-- The pickup, as EVERY client sees it. The prompt and the floating label
-- go at once — a label over a claimed relic reads as still-takeable for
-- as long as it is legible — while the model itself fades out, so the
-- relic leaves rather than blinking out of existence.
--
-- Driven by the replicated Collected attribute, so it runs on every
-- screen. It used to hang off the collector-only accept signal, which is
-- why everyone else watched a claimed relic sit there until the server
-- destroyed it. Guarded: a re-fire cannot replay it.
function Relic:_playCollectedFade()
	if self._consumed then
		return
	end
	self._consumed = true

	-- AT ONCE: everything that reads as "you can still take this", plus
	-- the effects that do not ride Transparency and would otherwise
	-- outlive the mesh (a Light leaves a lit patch of floor under an
	-- invisible relic; emitters keep spitting particles from nothing).
	-- Disabling a SHOWN prompt fires PromptHidden, which is what takes the
	-- description card and RelicRenderController's hover down; a relic not
	-- yet landed has no prompt here, and its landing checks _consumed so it
	-- never grows one.
	--
	-- Over PICKUP_FADE_SECONDS: the visible geometry, 0 -> 1. The HANDLE
	-- is the relic's visible mesh (Construct aliases it as _primaryPart,
	-- confusingly) and PrimaryPart is a separate invisible anchor that
	-- only hosts the billboard. So every BasePart fades (MeshPart and
	-- UnionOperation are BaseParts too) — the Handle, the parts nested
	-- under it, and the extra handles a multi-part relic carries, all
	-- together.
	--
	-- The anchor is skipped ONLY when it is genuinely a separate part. If
	-- a relic's PrimaryPart IS its Handle, skipping it would leave the
	-- whole relic sitting there at full opacity — which is exactly what
	-- the blanket skip did.
	local anchor = self.Instance.PrimaryPart
	if anchor == self.Instance:FindFirstChild("Handle") then
		anchor = nil
	end
	fadeSubtree(self.Instance, {
		targetTransparency = 1,
		tweenInfo = TweenInfo.new(PICKUP_FADE_SECONDS),
		skip = function(descendant)
			return descendant == anchor
		end,
		disable = { "ProximityPrompt", "BillboardGui", "ParticleEmitter", "Trail", "Light" },
	})

	-- THE PICKUP BURSTS, on every screen, only for the relic actually
	-- taken: the rest of a claim-one pull is Collected but carries no
	-- collector. CollectRelicVFX bursts at the relic and
	-- CollectRelicVFXCharacter on the collector's body, both in the
	-- relic's colour. Relic colour is read here rather than from Start's
	-- locals because this runs on clients that never own the relic.
	local collectorId = self.Instance:GetAttribute(Attributes.CollectedById)
	local collector = if typeof(collectorId) == "number" then Players:GetPlayerByUserId(collectorId) else nil
	if not collector then
		return
	end
	local relicData = RelicData[self.Instance.Name]
	local burstColor = if self.Instance.Name == SkipRelicData.Name
		then SkipRelicData.Color
		elseif relicData then RarityColors:Get(relicData.rarity)
		else nil
	-- Own clone at the relic, not a child of it: the relic fades and
	-- leaves while the burst is still playing.
	emitVFXPart(COLLECT_RELIC_VFX_NAME, self._primaryPart.CFrame, nil, {
		Color = burstColor,
		LifetimeScale = COLLECT_RELIC_VFX_LIFETIME_SCALE,
	})
	local root = getRoot.fromPlayer(collector)
	if root then
		emitVFXPart(COLLECT_RELIC_CHARACTER_VFX_NAME, root.CFrame, nil, {
			Color = burstColor,
			LifetimeScale = COLLECT_RELIC_CHARACTER_VFX_LIFETIME_SCALE,
		})
	end
end

function Relic:Start()
	if self._gone then
		return
	end
	-- A PUBLIC drop (tray Drop button) is everyone's: no fade, no owner
	-- lock, and claiming it consumes only itself. Anything else is
	-- owner-locked: the server spawned it invisible (privateDropVisibility
	-- .hide) and only the owner's client reveals it.
	local isPublic = self.Instance:GetAttribute(Attributes.PublicDrop) == true
	local isOwner = isPublic or Players.LocalPlayer.UserId == self.Instance:GetAttribute(Attributes.OwnerId)
	if isOwner then
		-- Authored look back FIRST, so the anchor enforcement and the
		-- fade-in below start from the real values. Skips itself on a
		-- relic already Collected (claimed while it was streaming in).
		privateDropVisibility.reveal(self.Instance)
	end
	-- PrimaryPart is a control / anchor part for animations + the
	-- BillboardGui adornee — never meant to render. Enforce
	-- Transparency=1 here so a missed template authoring doesn't
	-- bleed an orange box through every relic. Belt + suspenders for
	-- the iterate-and-skip pattern used by the tween loops below.
	if self.Instance.PrimaryPart then
		self.Instance.PrimaryPart.Transparency = 1
	end

	-- The server marks a relic Collected the instant someone takes it.
	-- Connected before the owner gate below so it covers every client,
	-- and re-checked immediately in case the attribute arrived with the
	-- instance (a relic claimed while it was still streaming in).
	self._janitor:Add(self.Instance:GetAttributeChangedSignal(Attributes.Collected):Connect(function()
		if self.Instance:GetAttribute(Attributes.Collected) == true then
			self:_playCollectedFade()
		end
	end))
	if self.Instance:GetAttribute(Attributes.Collected) == true then
		self:_playCollectedFade()
		return
	end

	-- Someone else's owner-locked relic (claimed as a fan by its owner).
	-- Already invisible from the server; the local hide below is only the
	-- fallback for a spawn path that forgot to pre-hide.
	if not isOwner then
		-- Every BasePart in the model EXCEPT PrimaryPart. Without the
		-- skip, the prior multi-handle fix made PrimaryPart visible as an
		-- orange box (it tweened to Transparency=1 here but other code
		-- paths re-tweened it visible — and tweening it 1→1 also briefly
		-- overwrites the enforced 1 above).
		fadeSubtree(self.Instance, {
			targetTransparency = 1,
			tweenInfo = HIDE_INFO,
			skip = function(descendant)
				return descendant == self.Instance.PrimaryPart
			end,
		})

		for _, particle in self._relicParticleAttachment:GetChildren() do
			if particle.Name == "Shine" then
				particle.Enabled = false
				continue
			end

			particle.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1),
				NumberSequenceKeypoint.new(1, 1),
			})
		end
		return
	end

	-- Fade-in: every BasePart EXCEPT PrimaryPart, which stays at
	-- Transparency=1 (anchor part, see enforcement at top of :Start).
	-- Multi-handle relics get all their VISIBLE handles tweened in
	-- together — PrimaryPart was the orange-cube culprit before this
	-- skip was added.
	fadeSubtree(self.Instance, {
		targetTransparency = 0,
		tweenInfo = FADE_IN_INFO,
		skip = function(descendant)
			return descendant == self.Instance.PrimaryPart
		end,
	})

	self.startTime = workspace:GetServerTimeNow()
	-- Stretched for a ricochet (arcPath's durationScale) so the longer
	-- two-leg path flies at the same pace as a plain arc.
	self.duration = 1 * (self._arcDurationScale or 1)

	self._numberValue.Changed:Connect(function(value)
		self.Instance:ScaleTo(value)
	end)

	-- The Skip offer has no RelicData entry, so its rarity text / colour come
	-- from SkipRelicData instead (a nil rarity would error on assignment).
	local isSkip = self.Instance.Name == SkipRelicData.Name
	local rarity = if isSkip
		then SkipRelicData.DisplayRarity
		else RelicData[self.Instance.Name] and RelicData[self.Instance.Name].rarity

	local rarityColor = if isSkip then SkipRelicData.Color else RarityColors:Get(rarity)

	self._dropParticles.Color = ColorSequence.new(rarityColor)

	-- The nameplate and the GROUND-relic glow (shared dressing). The
	-- owner line is "(PlayerName)" ONLY on a relic a player dropped from
	-- their tray: a vending-machine offer, an event reward or a Skip
	-- carries no DroppedByName and the label hides. The light sits on the
	-- primary Handle, tinted via the glow-specific palette (the Skip offer
	-- keeps its own colour) -- and it lives HERE rather than on the model
	-- template on purpose: this component only runs on relics tagged
	-- TagList.Relic, while the copies orbiting a player are clones tagged
	-- "FloatingRelic" that never mount it. A light in the template would
	-- light up every orbiting relic too.
	dressRelicDisplay(self.Instance.PrimaryPart, {
		name = self.Instance.Name,
		rarity = rarity,
		rarityColor = rarityColor,
		droppedByName = self.Instance:GetAttribute(Attributes.DroppedByName),
		glowColor = if isSkip then rarityColor else RarityColors:GetGlow(rarity),
		glowParent = self._primaryPart,
	})

	-- Thrown: the pop, on the Handle so it rides the arc. Every relic
	-- source reaches this same flight, so a machine, a mob, a chest, an
	-- event and a player's own tray drop all sound alike.
	lootSound:PlayPop(self.Instance:FindFirstChild("Handle"))

	-- In the janitor: a relic claimed mid-flight (the Collected fade runs
	-- and the server destroys it) used to leave this per-frame connection
	-- behind, since only the landing below ever disconnected it.
	self._connection = self._janitor:Add(RunService.RenderStepped:Connect(function(_: number)
		local now = workspace:GetServerTimeNow()
		local alpha = math.clamp((now - self.startTime) / self.duration, 0, 1)

		local pos = self._arc(alpha)

		-- PivotTo on the whole model — was two separate
		-- `PrimaryPart.CFrame` / `Handle.CFrame` writes, which left
		-- secondary handles (Handle2, etc.) stranded at template
		-- positions during the popup arc. With PivotTo the entire
		-- multi-part model rides the bezier together.
		self.Instance:PivotTo(CFrame.new(pos))

		if alpha >= 1 then
			self._connection:Disconnect()

			-- Claimed while still in the air: the pull's offers drop 0.25 s
			-- apart and fly for ~1 s, so a quick pick of the first one to
			-- land marks the rest Collected before they touch down. The
			-- Collected fade has already run on this model, and the code
			-- below would build it a fresh, ENABLED prompt over that fade --
			-- which is exactly how a claimed offer kept showing its card and
			-- hover until the server destroyed it. Nothing to land.
			if self._consumed then
				self._dropParticles.Enabled = false
				return
			end

			self._dropParticles.Enabled = false

			self._relicParticles:Emit(15)
			lootSound:PlayLanding()

			-- The float: one shared Heartbeat (DropFloatController) poses
			-- the whole model -- every handle of a multi-handle relic
			-- together -- from the landing pose. Out with the janitor on
			-- pickup / destroy.
			DropFloatController:Register(self.Instance, {
				base = self.Instance:GetPivot(),
				bobAmplitude = self._amplitude,
				bobCycle = self._durationPerCycle,
				phase = math.random() * 2 * math.pi,
				spinAxis = ROTATION_AXIS,
				spinRate = math.rad(ROTATION_SPEED) * ROTATION_AXIS.Magnitude,
			})
			self._janitor:Add(function()
				DropFloatController:Unregister(self.Instance)
			end, true)

			local relicName = self.Instance.Name

			local relicDescription = if isSkip
				then SkipRelicData.Description
				else getRelicDescription(localPlayer, relicName) or "No description available."
			local proximityPrompt = Instance.new("ProximityPrompt")
			proximityPrompt.KeyboardKeyCode = Enum.KeyCode.F
			proximityPrompt.RequiresLineOfSight = false
			proximityPrompt.MaxActivationDistance = 6
			proximityPrompt.Enabled = false
			-- The shared card: name + rich description, sized by the
			-- description's length and tinted by the rarity.
			buildPromptCard(proximityPrompt, {
				name = relicName,
				description = relicDescription,
				rarity = rarity,
				userText = ownerUserText(self.Instance),
			})

			proximityPrompt.Parent = self.Instance.Handle

			-- Re-checked at fire time: a claim that lands inside this grace
			-- window must not switch the prompt back on behind the fade.
			task.delay(0.25, function()
				if not self._consumed then
					proximityPrompt.Enabled = true
				end
			end)

			-- REQUEST ONLY. The server owns the relic-cap decision, so nothing
			-- is consumed here -- no prompt disable, no fade, no particle
			-- stop. A refused grab therefore leaves the relic (and the rest
			-- of the pull) fully visible and re-triggerable; the server shows
			-- the "Reached maximum relic cap!" pop.
			proximityPrompt.Triggered:Connect(function(player: Player)
				if not isPublic and player.UserId ~= self.Instance:GetAttribute(Attributes.OwnerId) then
					return
				end
				RelicNetwork.RelicCollectRequested.Fire(self.Instance)
			end)

			-- ACCEPTED by the server, and only ever for the COLLECTOR: their
			-- own screen pulse. The disappearance and both pickup bursts
			-- ride the Collected / CollectedById attributes instead
			-- (_playCollectedFade), so every player sees them.
			self._janitor:Add(acceptedRouter:Bind(self.Instance, function()
				ScreenGradientInterfaceController.Signals.OnPulseGradient:Fire(rarityColor)
			end))
		end
	end))

	self._relicParticleAttachment.Parent = self._primaryPart
end

return Relic
