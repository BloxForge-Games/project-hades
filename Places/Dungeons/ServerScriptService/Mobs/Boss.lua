--[[
	Module: Boss.lua
	Description: Boss mob — a Miniboss (aggressive cadence + no-ragdoll death)
	that ALSO does HP-threshold phase changes. Phases are the only thing this
	class adds on top of Miniboss.

	--- PHASE MODEL ---

	A boss can have up to 2 phase changes, fired at HP thresholds (66% then
	33% by default). How many are ACTIVE this run is resolved per-boss:
	  * data.phaseCount = <number>      → that many, regardless of difficulty
	    (unique fixed-phase bosses).
	  * data.phaseCount = "difficulty"  → look up DIFFICULTY_PHASE_COUNT
	    (or omit phaseCount entirely; this is the default).
	A boss with no `phases` table (or 0 active) just behaves as a Miniboss.

	Each phase entry lives in ZombieData[name].phases[i]:
	    {
	        healthThreshold = 0.66,   -- optional; defaults to PHASE_THRESHOLDS[i]
	        cutsceneDuration = 3,     -- optional; EncounterService default if nil
	        onPhaseStart = function(mob: Model) ... end,  -- VFX / anim / HP
	        genericAttacks = { <ZombieData generic attack>, ... },  -- added to pool
	        uniqueAttacks  = { { attackRange, run }, ... },         -- added to pool
	    }

	On a threshold crossing the boss: cancels any in-flight cast
	(_interruptAttack), hands the cutscene staging to
	EncounterService:PlayPhaseCutscene (freeze everything, instakill adds, lock
	+ invuln players, boss invulnerable), and at the cutscene beat injects the
	phase's new attacks into the live pool (_addAttacks) + runs onPhaseStart.
	One phase runs at a time.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Submodules.Core.Packages.Knit)
local Miniboss = require(script.Parent.Miniboss)

local Boss = setmetatable({}, Miniboss)
Boss.__index = Boss

local EncounterService
local DungeonService

-- HP fractions at which phase changes fire, in order. A boss with N active
-- phases uses the first N (phase 1 at 66%, phase 2 at 33%). A phase entry can
-- override its own cutoff via healthThreshold.
local PHASE_THRESHOLDS = { 0.66, 0.33 }

-- Difficulty → number of phase changes, used when a boss defers to difficulty
-- (the default). Easy = none, Normal = 1, Hard / Nightmare = 2. Tune here. If
-- per-dungeon control is ever needed this can move into
-- DungeonData.difficulties[diff].phaseChanges and be read off the dungeon.
local DIFFICULTY_PHASE_COUNT: { [string]: number } = {
	Easy = 0,
	Normal = 1,
	Hard = 2,
	Nightmare = 2,
}

-- Resolves how many of the boss's declared phases are active this run.
local function resolvePhaseCount(data, difficulty: string?): number
	local phases = data.phases or {}
	local declared = data.phaseCount
	if type(declared) == "number" then
		return math.clamp(declared, 0, #phases)
	end
	-- "difficulty" or unset → difficulty map; unknown difficulty → 0.
	local count = (difficulty and DIFFICULTY_PHASE_COUNT[difficulty]) or 0
	return math.min(count, #phases)
end

function Boss.new(model: Model)
	local self = Miniboss.new(model)
	setmetatable(self, Boss)

	EncounterService = EncounterService or Knit.GetService("EncounterService")
	DungeonService = DungeonService or Knit.GetService("DungeonService")

	-- Resolve which phases are active for this run (boss config + difficulty).
	local dungeon = DungeonService and DungeonService:GetActiveDungeon()
	local difficulty = dungeon and dungeon.difficulty
	local count = resolvePhaseCount(self._data, difficulty)

	self._activePhases = {}
	for i = 1, count do
		local config = self._data.phases[i]
		table.insert(self._activePhases, {
			threshold = config.healthThreshold or PHASE_THRESHOLDS[i] or 0,
			config = config,
			triggered = false,
		})
	end

	-- Set by _runPhase so Miniboss:_afterAttack doesn't re-chase mid-cutscene.
	self._phasing = false

	return self
end

function Boss:Start()
	Miniboss.Start(self) -- inherits MobBase.Start

	if #self._activePhases == 0 then
		return -- no phases this run → pure Miniboss behavior
	end

	-- Watch own HP for threshold crossings. Janitor-managed → cleaned on death.
	self._janitor:Add(self._humanoid.HealthChanged:Connect(function()
		self:_checkPhases()
	end))

	-- Catch a threshold already crossed before the watch connected (the watch
	-- only fires on CHANGE; HealthChanged wouldn't fire for an already-low boss).
	self:_checkPhases()
end

-- Fires the lowest-index un-triggered phase whose HP threshold we've dropped
-- to. One phase at a time (guarded by _phasing). A hit that crosses BOTH
-- thresholds triggers phase 1 now; phase 2 is re-checked when phase 1 ends.
function Boss:_checkPhases()
	if self._phasing or self._humanoid.Health <= 0 then
		return
	end
	local maxHealth = self._humanoid.MaxHealth
	if maxHealth <= 0 then
		return
	end
	local ratio = self._humanoid.Health / maxHealth
	for _, phase in ipairs(self._activePhases) do
		if not phase.triggered and ratio <= phase.threshold then
			phase.triggered = true
			self._phasing = true
			task.spawn(function()
				self:_runPhase(phase)
			end)
			return
		end
	end
end

-- Runs one phase change. Cancels the boss's current cast, hands cutscene
-- staging to EncounterService (freeze, instakill adds, lock + invuln), and
-- injects the phase's new attacks + VFX/anim/HP at the cutscene beat. Then
-- un-freezes, resumes Chase, and re-checks for a second already-crossed
-- threshold.
function Boss:_runPhase(phase)
	self:_interruptAttack()

	local config = phase.config
	local function applyPhaseContent()
		self:_addAttacks(config.genericAttacks, config.uniqueAttacks)
		if config.onPhaseStart then
			config.onPhaseStart(self._model)
		end
	end

	if EncounterService then
		EncounterService:PlayPhaseCutscene(self._model, {
			duration = config.cutsceneDuration, -- nil → EncounterService default
			onCutsceneBeat = applyPhaseContent,
		})
	else
		-- Defensive: no EncounterService (e.g. isolated test) — still apply
		-- the mechanical change without the cinematic.
		applyPhaseContent()
	end

	self._phasing = false
	if self._humanoid.Health > 0 then
		self:_enterChase()
	end
	-- Catch a second threshold that was already crossed before this phase ran.
	self:_checkPhases()
end

return Boss
