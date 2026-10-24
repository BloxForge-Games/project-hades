--!strict
--[[
	Module: VFXFadeController.lua
	Description:
	Runs Combat.VFXFade cues. The server parents a VFX rig it owns (an
	aura, the Azure glyph) at its AUTHORED look and asks every client to
	fade it; each client then steps Shared/Functions/VFX/vfxFade on its own
	copy. The per-frame NumberSequence rebuilds a fade needs therefore
	happen on each screen instead of replicating from the server as one
	property write per emitter per frame -- and because the cue is a
	broadcast, every player still sees the same fade at the same moment.

	Per rig the authored transparencies are captured ONCE, on the first cue,
	and reused for every later one: a fade OUT that lands while a fade IN
	is still running (a Stonebound replaced inside its bloom) then still
	fades from the right values instead of capturing a half-faded rig. A
	new cue on a rig cancels the one in flight (vfxFade.run's isCancelled),
	so two loops never fight for the same properties. Records are dropped
	when the rig is destroyed.
]]

--[ Roblox Services ]--

local ReplicatedStorage = game:GetService("ReplicatedStorage")

--[ Imports ]--

local Combat = require(ReplicatedStorage.Submodules.Core.Source.Network.Combat)
local vfxFade = require(ReplicatedStorage.Submodules.Core.Shared.Functions.VFX.vfxFade)

local VFXFadeController = {
	Name = "VFXFadeController",
}

--[ Types ]--

-- One tracked rig: its authored fade targets and a generation counter that
-- every cue bumps, so the fade a cue started stops the moment a newer cue
-- arrives for the same rig.
type FadeRecord = {
	targets: { vfxFade.FadeTarget },
	generation: number,
}

VFXFadeController._records = {} :: { [Instance]: FadeRecord }

--[ Private ]--

function VFXFadeController._recordFor(self: typeof(VFXFadeController), rig: Instance): FadeRecord
	local existing = self._records[rig]
	if existing then
		return existing
	end
	local record: FadeRecord = { targets = vfxFade.capture(rig), generation = 0 }
	self._records[rig] = record
	rig.Destroying:Once(function()
		self._records[rig] = nil
	end)
	return record
end

-- One cue: every rig it names fades together on one loop. Rigs destroyed
-- before the cue arrived are nil in the payload and simply absent here.
function VFXFadeController._runCue(
	self: typeof(VFXFadeController),
	rigs: { Instance? },
	fromAlpha: number,
	toAlpha: number,
	duration: number,
	disableEmitters: boolean?
)
	local targets: { vfxFade.FadeTarget } = {}
	local records: { FadeRecord } = {}
	local generations: { number } = {}
	for _, rig in rigs do
		if not rig or not rig:IsDescendantOf(game) then
			continue
		end
		local record = self:_recordFor(rig)
		record.generation += 1
		table.insert(records, record)
		table.insert(generations, record.generation)
		table.move(record.targets, 1, #record.targets, #targets + 1, targets)
	end
	if #targets == 0 then
		return
	end

	if disableEmitters then
		vfxFade.disableEmitters(targets)
	end

	local function isCancelled(): boolean
		for index, record in records do
			if record.generation ~= generations[index] then
				return true
			end
		end
		return false
	end

	task.spawn(vfxFade.run, targets, fromAlpha, toAlpha, duration, isCancelled)
end

--[ Initializers ]--

function VFXFadeController.Start(self: typeof(VFXFadeController))
	Combat.VFXFade.On(function(payload)
		self:_runCue(payload.Rigs, payload.FromAlpha, payload.ToAlpha, payload.Duration, payload.DisableEmitters)
	end)
end

return VFXFadeController
