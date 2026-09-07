--[[
	Module: Client/Controllers/PlayerVitalsBillboardController.lua
	Description:
	Drives every player's side-mounted vitals billboards on THIS client --
	HealthBillboardGui and ManaBillboardGui. The GUIs themselves are attached
	(and replicated) by PlayerVitalsBillboardService; this controller owns what
	they show:

	  * BARS  each fill's height tracks its fraction, tweened, so it slides
	          down on loss and back up on gain. Anchored to the BOTTOM so it
	          drains downward.
	            HealthBar : Humanoid.Health, plus a grey ShieldBar segment
	                        stacked on top for the ShieldValue attribute
	                        (LoL rescale, same as the HUD bar)
	            ManaBar   : Mana / MaxMana character attributes (stamped by
	                        MagicService -- other clients can't read the
	                        owner's per-player mana property, so the
	                        attributes are how it gets here)
	  * HIDE  every billboard on a character is disabled while
	            - the VIEWER's own character is in a cutscene (CutscenePlaying,
	              a client-set attribute -- so this is per-viewer by nature:
	              during your boss intro no bars are drawn on your screen), or
	            - that character is dead (health <= 0 / Death attribute).
	          ONE exception, and it is narrow: an event cutscene that MOVES
	          health or mana (Attributes.EventVitals -- Fountain / Cursed
	          Shrine / Sword in the Stone) keeps the bars up, because watching
	          the number move is the beat. Even then only the VIEWER'S OWN are
	          drawn: a teammate's bars over a frozen body are noise while you
	          bargain. Every other event (Merchant, Forge, Coffin) hides them
	          like an encounter intro.

	Runs for every player, the local one included, on both join paths (players
	already here at start, and everyone who joins after), and re-binds on every
	respawn. All connections per character are janitored on character removal.
]]

--[ Roblox Services ]--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

--[ Imports ]--

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)

--[ Constants ]--

local HEALTH_BILLBOARD_NAME = "HealthBillboardGui"
local HEALTH_BAR_NAMES = { "HealthBar" }
local MANA_BILLBOARD_NAME = "ManaBillboardGui"
-- The mana template was authored with its fill still named "HealthBar"
-- (duplicated from the health one); accept either so a rename is optional.
local MANA_BAR_NAMES = { "ManaBar", "HealthBar" }

-- Fill geometry, as SCALE of the billboard (the fill is a SIBLING of the
-- Frame track, not a child, so it's laid out against the billboard). The
-- fill is CLAMPED to the track's rect at resolve time: at most FILL_MAX_X
-- wide / FILL_MAX_Y tall, but never wider or taller than the Frame, centred
-- on it, bottom edge on the Frame's bottom edge. Height = maxHeight x
-- fraction, anchored at that bottom edge, so it drains DOWN and refills UP
-- inside the track and can't poke out of it whatever these are set to.
local FILL_MAX_X = 0.7
local FILL_MAX_Y = 0.95
local FILL_ZINDEX = 2 -- above the track (ZIndex 1)
local TRACK_FRAME_NAME = "Frame"

-- A max-stat change (relic / armor) is written by the server as TWO steps a
-- moment apart (MaxHealth then Health; Mana then MaxMana), and the game
-- heals by the gain -- so the FRACTION ends where it started, but reading
-- each step alone shows a fake dip-and-refill and fades the bar in. Refreshes
-- are therefore coalesced to the next frame and only count as a change if
-- the displayed fraction actually moved.
local FRACTION_EPSILON = 0.0005

local BAR_TWEEN_INFO = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- SHIELD segment on the health billboard: a second fill (ShieldBar, cloned
-- from HealthBar at resolve time and tinted the HUD's shield grey) stacked
-- directly on top of the health fill. Same LoL-style rescale the HUD bar
-- uses: denominator = max(MaxHealth, Health + Shield), so a full-HP shield
-- visibly compresses the red instead of drawing nothing, and health +
-- shield together can never exceed the track. Shield reads the ShieldValue
-- character attribute ShieldService stamps (nil = none).
local SHIELD_ATTRIBUTE = "ShieldValue"
local SHIELD_BAR_NAME = "ShieldBar"
local SHIELD_COLOR = Color3.fromRGB(214, 214, 219)

-- AUTO-HIDE: a bar is only shown while its value is changing or not full.
-- Any change fades it in (and holds it); once the value is FULL it lingers
-- FULL_LINGER_SECONDS, then fades out. Spawns hidden if already full. Done
-- by tweening the transparency of every visual under the billboard (a
-- BillboardGui has no transparency of its own) toward each element's
-- AUTHORED value on show and 1 on hide -- so strokes / tints fade as
-- designed. Independent of the cutscene / death Enabled toggle above.
local FULL_LINGER_SECONDS = 3
local FADE_IN_INFO = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local FADE_OUT_INFO = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
-- Fractions within this of 1 count as full (guards float regen drift).
local FULL_EPSILON = 0.001
-- How long to wait for the server's replicated billboards to arrive after the
-- character does; past this a missing billboard is simply skipped.
local BILLBOARD_WAIT_SECONDS = 10

--[ Controller ]--

local PlayerVitalsBillboardController = Knit.CreateController({
	Name = "PlayerVitalsBillboardController",
})

-- [character]: { character, humanoid, connections = { RBXScriptConnection },
--               bars = { { billboard, bar, fraction: () -> number, tween,
--                         fadeTargets, fadeTweens, shown, hideToken,
--                         fillWidth, fillMaxHeight, lastFraction,
--                         refreshScheduled } } }
PlayerVitalsBillboardController._tracked = {}
PlayerVitalsBillboardController._viewerInCutscene = false
-- True during a health/mana event cutscene: every character EXCEPT the
-- viewer's own is hidden (see the header).
PlayerVitalsBillboardController._viewerOwnBarsOnly = false

--[ Private ]--

local function safeFraction(value: number?, max: number?): number
	if typeof(value) ~= "number" or typeof(max) ~= "number" or max <= 0 then
		return 0
	end
	return math.clamp(value / max, 0, 1)
end

-- Enabled = alive AND not landing AND not viewer-cutscene AND (mine, or we
-- are not inside the own-bars-only window), applied to every bar.
function PlayerVitalsBillboardController:_refreshVisibility(entry)
	local character = entry.character
	local alive = entry.humanoid.Health > 0 and character:GetAttribute(Attributes.Death) ~= true
	-- The SUBJECT's own dungeon-entry fall hides its bars for everyone,
	-- which the viewer-cutscene test above cannot do: a teammate dropping
	-- in is not YOUR cutscene, so their bars used to draw over a body that
	-- had not finished loading. This controller owns the two vitals
	-- billboards outright (CharacterRevealController skips them by name),
	-- so the fade below is the single reveal for them.
	local landing = character:GetAttribute(Attributes.Landing) == true
	local visible = alive
		and not landing
		and not self._viewerInCutscene
		and (entry.isLocal or not self._viewerOwnBarsOnly)
	local wasVisible = entry.visible
	if wasVisible == visible then
		return
	end
	entry.visible = visible
	local token = {}
	entry.visibilityToken = token
	for _, barEntry in entry.bars do
		if visible then
			-- Coming BACK (cutscene / landing released): re-enable, and any bar
			-- that should be showing (not full) fades in from nothing. Bars
			-- that are auto-hidden (full) stay hidden -- nothing to fade.
			barEntry.billboard.Enabled = true
			if barEntry.shown then
				self:_fadeBarVisuals(barEntry, false, true)
				self:_fadeBarVisuals(barEntry, true)
			end
		elseif wasVisible == nil then
			-- First evaluation while hidden (e.g. spawned mid-cutscene): just off.
			barEntry.billboard.Enabled = false
		else
			-- Going away (cutscene started / died): fade the visuals out, THEN
			-- disable once the fade lands (unless visibility flipped back).
			self:_fadeBarVisuals(barEntry, false)
			task.delay(FADE_OUT_INFO.Time, function()
				if entry.visibilityToken == token and not entry.visible then
					barEntry.billboard.Enabled = false
				end
			end)
		end
	end
end

-- Every fadeable visual under a billboard with its authored transparency,
-- so show restores the design and hide goes to 1. Captured once at resolve.
local function collectFadeTargets(billboard: BillboardGui): { { instance: Instance, property: string, base: number } }
	local targets = {}
	for _, descendant in billboard:GetDescendants() do
		if descendant:IsA("GuiObject") then
			table.insert(targets, {
				instance = descendant,
				property = "BackgroundTransparency",
				base = descendant.BackgroundTransparency,
			})
			if descendant:IsA("ImageLabel") or descendant:IsA("ImageButton") then
				table.insert(targets, {
					instance = descendant,
					property = "ImageTransparency",
					base = descendant.ImageTransparency,
				})
			elseif descendant:IsA("TextLabel") or descendant:IsA("TextButton") then
				table.insert(targets, {
					instance = descendant,
					property = "TextTransparency",
					base = descendant.TextTransparency,
				})
			end
		elseif descendant:IsA("UIStroke") then
			table.insert(targets, { instance = descendant, property = "Transparency", base = descendant.Transparency })
		end
	end
	return targets
end

-- Fade a bar's visuals in (to authored) or out (to 1). Cancels any fade in
-- flight so rapid show/hide never fights itself.
-- Tweens (or snaps) a bar's visuals toward shown / hidden WITHOUT touching
-- its auto-hide `shown` state -- used both by the auto-hide and by the
-- cutscene fade, which must not disturb the auto-hide bookkeeping.
function PlayerVitalsBillboardController:_fadeBarVisuals(barEntry, shown: boolean, instant: boolean?)
	for _, fadeTween in barEntry.fadeTweens do
		fadeTween:Cancel()
	end
	table.clear(barEntry.fadeTweens)

	local info = if shown then FADE_IN_INFO else FADE_OUT_INFO
	for _, target in barEntry.fadeTargets do
		local goal = if shown then target.base else 1
		if instant then
			(target.instance :: any)[target.property] = goal
		else
			local fadeTween = TweenService:Create(target.instance, info, { [target.property] = goal })
			table.insert(barEntry.fadeTweens, fadeTween)
			fadeTween:Play()
		end
	end
end

function PlayerVitalsBillboardController:_setBarShown(barEntry, shown: boolean, instant: boolean?)
	barEntry.shown = shown
	self:_fadeBarVisuals(barEntry, shown, instant)
end

-- Value changed (or first read): show the bar; if it's full, arm the
-- linger-then-hide, otherwise cancel any pending hide.
function PlayerVitalsBillboardController:_onBarValueChanged(barEntry, instant: boolean?)
	local isFull = barEntry.fraction() >= 1 - FULL_EPSILON
		and (barEntry.shieldFraction == nil or barEntry.shieldFraction() <= FULL_EPSILON)

	-- Any pending hide is stale the moment the value moves.
	barEntry.hideToken = nil

	if instant then
		-- First read: full = start hidden, not full = start shown. No fade.
		self:_setBarShown(barEntry, not isFull, true)
	elseif not barEntry.shown then
		self:_setBarShown(barEntry, true)
	end

	if isFull then
		local token = {}
		barEntry.hideToken = token
		task.delay(FULL_LINGER_SECONDS, function()
			if barEntry.hideToken == token and barEntry.shown then
				barEntry.hideToken = nil
				self:_setBarShown(barEntry, false)
			end
		end)
	end
end

function PlayerVitalsBillboardController:_refreshBar(barEntry, instant: boolean?)
	local fraction = barEntry.fraction()
	-- Shield segment (health bar only): fraction of the SAME denominator, so
	-- it stacks on the fill without either overflowing the track.
	local shieldFraction = if barEntry.shieldFraction then barEntry.shieldFraction() else 0

	-- No visible change (e.g. max + current rose together): keep the bar
	-- exactly as it is -- no tween, no fade-in, no linger reset.
	if
		not instant
		and barEntry.lastFraction ~= nil
		and math.abs(fraction - barEntry.lastFraction) < FRACTION_EPSILON
		and math.abs(shieldFraction - (barEntry.lastShieldFraction or 0)) < FRACTION_EPSILON
	then
		return
	end
	barEntry.lastFraction = fraction
	barEntry.lastShieldFraction = shieldFraction

	local bar: GuiObject = barEntry.bar
	local target = UDim2.fromScale(barEntry.fillWidth, barEntry.fillMaxHeight * fraction)

	if barEntry.tween then
		barEntry.tween:Cancel()
		barEntry.tween = nil
	end
	if barEntry.shieldTween then
		barEntry.shieldTween:Cancel()
		barEntry.shieldTween = nil
	end

	-- Shield sits directly above the health fill: its bottom edge is the
	-- fill's top edge (bottom - health height), height = its own fraction.
	local shieldBar: GuiObject? = barEntry.shieldBar
	local shieldTarget = if shieldBar
		then {
			Size = UDim2.fromScale(barEntry.fillWidth, barEntry.fillMaxHeight * shieldFraction),
			Position = UDim2.fromScale(barEntry.fillCenterX, barEntry.fillBottomY - barEntry.fillMaxHeight * fraction),
		}
		else nil

	if instant then
		bar.Size = target
		if shieldBar and shieldTarget then
			shieldBar.Size = shieldTarget.Size
			shieldBar.Position = shieldTarget.Position
		end
	else
		local tween = TweenService:Create(bar, BAR_TWEEN_INFO, { Size = target })
		barEntry.tween = tween
		tween:Play()
		if shieldBar and shieldTarget then
			local shieldTween = TweenService:Create(shieldBar, BAR_TWEEN_INFO, shieldTarget)
			barEntry.shieldTween = shieldTween
			shieldTween:Play()
		end
	end

	self:_onBarValueChanged(barEntry, instant)
end

-- Coalesces every signal that fires in one frame (Max + current written
-- back-to-back) into ONE refresh next Heartbeat, so the bar evaluates the
-- settled state rather than each half-written step.
function PlayerVitalsBillboardController:_scheduleRefresh(barEntry)
	if barEntry.refreshScheduled then
		return
	end
	barEntry.refreshScheduled = true
	task.defer(function()
		barEntry.refreshScheduled = false
		if barEntry.bar.Parent then
			self:_refreshBar(barEntry)
		end
	end)
end

-- Resolves one billboard + its fill under the HRP (or nil if it never
-- arrives). The fill is the first child matching any of `barNames`; the
-- billboard's descendants replicate together, so once the billboard is here
-- the fill is too (no per-name wait -- a wrong name must not stall 10s).
-- Anchors the fill's bottom edge so a shrinking height reads as DOWN.
local function resolveBar(hrp: BasePart, billboardName: string, barNames: { string }): (BillboardGui?, GuiObject?, any)
	local billboard = hrp:WaitForChild(billboardName, BILLBOARD_WAIT_SECONDS)
	if not billboard then
		return nil, nil
	end
	local bar: GuiObject? = nil
	for _, name in barNames do
		local candidate = billboard:FindFirstChild(name)
		if candidate and candidate:IsA("GuiObject") then
			bar = candidate
			break
		end
	end
	if not bar then
		warn(
			("[PlayerVitalsBillboardController] %s has no fill named %s"):format(
				billboardName,
				table.concat(barNames, " / ")
			)
		)
		return nil, nil
	end
	-- Track rect (scale space) from the authored Frame; falls back to a
	-- centred full-billboard rect if there's no Frame.
	local trackLeft, trackTop, trackWidth, trackHeight = 0, 0, 1, 1
	local track = billboard:FindFirstChild(TRACK_FRAME_NAME)
	if track and track:IsA("GuiObject") then
		trackWidth = track.Size.X.Scale
		trackHeight = track.Size.Y.Scale
		trackLeft = track.Position.X.Scale - trackWidth * track.AnchorPoint.X
		trackTop = track.Position.Y.Scale - trackHeight * track.AnchorPoint.Y
	end
	local geometry = {
		fillWidth = math.min(FILL_MAX_X, trackWidth),
		fillMaxHeight = math.min(FILL_MAX_Y, trackHeight),
		centerX = trackLeft + trackWidth / 2,
		bottomY = trackTop + trackHeight,
	}

	-- Lay the fill out INSIDE the track: bottom-anchored on its bottom edge,
	-- centred, never larger than it.
	bar.AnchorPoint = Vector2.new(0.5, 1)
	bar.Position = UDim2.fromScale(geometry.centerX, geometry.bottomY)
	bar.Size = UDim2.fromScale(geometry.fillWidth, geometry.fillMaxHeight)
	bar.ZIndex = FILL_ZINDEX
	return billboard, bar, geometry
end

function PlayerVitalsBillboardController:_untrack(character: Model)
	local entry = self._tracked[character]
	if not entry then
		return
	end
	self._tracked[character] = nil
	for _, connection in entry.connections do
		connection:Disconnect()
	end
	for _, barEntry in entry.bars do
		if barEntry.tween then
			barEntry.tween:Cancel()
		end
		if barEntry.shieldTween then
			barEntry.shieldTween:Cancel()
		end
		for _, fadeTween in barEntry.fadeTweens do
			fadeTween:Cancel()
		end
		barEntry.hideToken = nil
	end
end

function PlayerVitalsBillboardController:_track(character: Model)
	self:_untrack(character)

	local humanoid = character:WaitForChild("Humanoid", BILLBOARD_WAIT_SECONDS)
	local hrp = character:WaitForChild("HumanoidRootPart", BILLBOARD_WAIT_SECONDS)
	if not humanoid or not hrp or not character.Parent then
		return
	end

	local healthBillboard, healthBar, healthGeometry = resolveBar(hrp, HEALTH_BILLBOARD_NAME, HEALTH_BAR_NAMES)
	local manaBillboard, manaBar, manaGeometry = resolveBar(hrp, MANA_BILLBOARD_NAME, MANA_BAR_NAMES)
	if not character.Parent or self._tracked[character] then
		return -- character left mid-wait, or a second _track raced this one
	end

	local entry = {
		character = character,
		humanoid = humanoid,
		-- Whose bars these are: the own-bars-only window draws only the
		-- viewer's (see _refreshVisibility).
		isLocal = Players:GetPlayerFromCharacter(character) == Players.LocalPlayer,
		connections = {},
		bars = {},
	}

	local healthEntry, manaEntry
	if healthBillboard and healthBar then
		-- ShieldBar: create from the HealthBar (same authored look), tinted
		-- grey, drawn above it. Created BEFORE fade targets are collected so
		-- it fades with the rest of the billboard.
		local shieldBar = healthBillboard:FindFirstChild(SHIELD_BAR_NAME) :: GuiObject?
		if not shieldBar then
			shieldBar = healthBar:Clone()
			shieldBar.Name = SHIELD_BAR_NAME
			shieldBar.BackgroundColor3 = SHIELD_COLOR
			shieldBar.ZIndex = healthBar.ZIndex + 1
			shieldBar.Size = UDim2.fromScale(healthGeometry.fillWidth, 0)
			shieldBar.Parent = healthBillboard
		end

		-- LoL rescale: one denominator for both fractions.
		local function healthDenominator(): number
			local shield = character:GetAttribute(SHIELD_ATTRIBUTE)
			shield = if typeof(shield) == "number" then shield else 0
			return math.max(humanoid.MaxHealth, humanoid.Health + shield)
		end

		healthEntry = {
			billboard = healthBillboard,
			bar = healthBar,
			shieldBar = shieldBar,
			fraction = function()
				return safeFraction(humanoid.Health, healthDenominator())
			end,
			shieldFraction = function()
				local shield = character:GetAttribute(SHIELD_ATTRIBUTE)
				return safeFraction(if typeof(shield) == "number" then shield else 0, healthDenominator())
			end,
			tween = nil,
			shieldTween = nil,
			fadeTargets = collectFadeTargets(healthBillboard),
			fadeTweens = {},
			shown = true,
			hideToken = nil,
			fillWidth = healthGeometry.fillWidth,
			fillMaxHeight = healthGeometry.fillMaxHeight,
			fillCenterX = healthGeometry.centerX,
			fillBottomY = healthGeometry.bottomY,
			lastFraction = nil,
			lastShieldFraction = nil,
			refreshScheduled = false,
		}
		table.insert(entry.bars, healthEntry)
	end
	if manaBillboard and manaBar then
		manaEntry = {
			billboard = manaBillboard,
			bar = manaBar,
			fraction = function()
				return safeFraction(character:GetAttribute(Attributes.Mana), character:GetAttribute(Attributes.MaxMana))
			end,
			tween = nil,
			fadeTargets = collectFadeTargets(manaBillboard),
			fadeTweens = {},
			shown = true,
			hideToken = nil,
			fillWidth = manaGeometry.fillWidth,
			fillMaxHeight = manaGeometry.fillMaxHeight,
			lastFraction = nil,
			refreshScheduled = false,
		}
		table.insert(entry.bars, manaEntry)
	end
	if #entry.bars == 0 then
		return
	end
	self._tracked[character] = entry

	-- Health: bar + visibility (death).
	table.insert(
		entry.connections,
		humanoid.HealthChanged:Connect(function()
			if healthEntry then
				self:_scheduleRefresh(healthEntry)
			end
			self:_refreshVisibility(entry)
		end)
	)
	table.insert(
		entry.connections,
		character:GetAttributeChangedSignal(Attributes.Landing):Connect(function()
			self:_refreshVisibility(entry)
		end)
	)
	table.insert(
		entry.connections,
		humanoid:GetPropertyChangedSignal("MaxHealth"):Connect(function()
			if healthEntry then
				self:_scheduleRefresh(healthEntry)
			end
		end)
	)
	-- Shield pool changes (gain, absorb, expiry) redraw the segment.
	table.insert(
		entry.connections,
		character:GetAttributeChangedSignal(SHIELD_ATTRIBUTE):Connect(function()
			if healthEntry then
				self:_scheduleRefresh(healthEntry)
			end
		end)
	)

	-- Mana: both attributes drive the same bar.
	if manaEntry then
		for _, attribute in { Attributes.Mana, Attributes.MaxMana } do
			table.insert(
				entry.connections,
				character:GetAttributeChangedSignal(attribute):Connect(function()
					self:_scheduleRefresh(manaEntry)
				end)
			)
		end
	end

	table.insert(
		entry.connections,
		character:GetAttributeChangedSignal(Attributes.Death):Connect(function()
			self:_refreshVisibility(entry)
		end)
	)
	table.insert(
		entry.connections,
		character.AncestryChanged:Connect(function(_, parent)
			if not parent then
				self:_untrack(character)
			end
		end)
	)

	for _, barEntry in entry.bars do
		self:_refreshBar(barEntry, true)
	end
	self:_refreshVisibility(entry)
end

function PlayerVitalsBillboardController:_watchPlayer(player: Player)
	if player.Character then
		task.spawn(function()
			self:_track(player.Character)
		end)
	end
	player.CharacterAdded:Connect(function(character)
		task.spawn(function()
			self:_track(character)
		end)
	end)
	player.CharacterRemoving:Connect(function(character)
		self:_untrack(character)
	end)
end

-- The viewer's cutscene state lives on THEIR character's CutscenePlaying
-- attribute (client-set). Re-bound on every local respawn.
function PlayerVitalsBillboardController:_watchViewerCutscene()
	local localPlayer = Players.LocalPlayer

	local function bind(character: Model)
		local function refresh()
			-- Only an event that MOVES health or mana (EventVitals: Fountain /
			-- Shrine / Sword) keeps bars up, and then only the viewer's own.
			-- Every other cutscene, event or encounter, hides all of them.
			local inCutscene = character:GetAttribute(Attributes.CutscenePlaying) == true
			local vitalsEvent = character:GetAttribute(Attributes.EventVitals) == true
			self._viewerInCutscene = inCutscene and not vitalsEvent
			self._viewerOwnBarsOnly = inCutscene and vitalsEvent
			for _, entry in self._tracked do
				self:_refreshVisibility(entry)
			end
		end
		character:GetAttributeChangedSignal(Attributes.CutscenePlaying):Connect(refresh)
		character:GetAttributeChangedSignal(Attributes.EventVitals):Connect(refresh)
		refresh()
	end

	if localPlayer.Character then
		bind(localPlayer.Character)
	end
	localPlayer.CharacterAdded:Connect(bind)
end

--[ Lifecycle ]--

function PlayerVitalsBillboardController:KnitStart()
	self:_watchViewerCutscene()

	for _, player in Players:GetPlayers() do
		self:_watchPlayer(player)
	end
	Players.PlayerAdded:Connect(function(player)
		self:_watchPlayer(player)
	end)
end

function PlayerVitalsBillboardController:KnitInit() end

return PlayerVitalsBillboardController
