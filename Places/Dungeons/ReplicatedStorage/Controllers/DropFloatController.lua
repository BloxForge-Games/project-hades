--!strict
--[[
	Module: DropFloatController.lua
	Description:
	ONE Heartbeat for every floating pickup on this client. A landed relic,
	a resting gear drop and a settled coin each used to open their own
	per-instance Heartbeat for a sine bob and a slow spin; a chest spill
	put thirty of them on the frame at once. They register here instead,
	with their own authored numbers, and a single loop poses them all.

	The pose is always written against the REST pose captured at
	registration -- `base * bob * spin` -- never against the current
	pivot. The relic and coin loops used to add sin(t) to wherever the
	model already was, so the offset integrated frame over frame and the
	drop random-walked up and down (and the walk's size depended on the
	frame rate).

	The loop only exists while something is registered: connected on the
	first Register, disconnected when the last entry leaves.

	Registrations can arrive before Blitz has run any lifecycle (a
	component constructs the moment its tagged model streams in), so this
	module needs no Init / Start: the registry and the lazy loop are
	complete at require time.
]]

local RunService = game:GetService("RunService")

--[ Types ]--

export type FloatConfig = {
	-- Rest pose. The bob is measured from here, the spin turns about it.
	base: CFrame,
	-- Studs above / below the rest pose at the peak of the bob.
	bobAmplitude: number,
	-- Seconds for one full bob (up and back).
	bobCycle: number,
	-- Where in the bob cycle this one starts, radians. Random per drop
	-- keeps a spill from bobbing in lockstep.
	phase: number?,
	-- Spin, as an axis in the rest pose's local frame and a rate in
	-- radians per second. Nil = no spin.
	spinAxis: Vector3?,
	spinRate: number?,
}

type FloatEntry = {
	base: CFrame,
	bobAmplitude: number,
	bobAngularSpeed: number,
	phase: number,
	spinAxis: Vector3?,
	spinRate: number,
	startedAt: number,
}

--[ Controller ]--

local DropFloatController = {
	Name = "DropFloatController",

	_entries = {} :: { [Instance]: FloatEntry },
	_count = 0,
	_connection = nil :: RBXScriptConnection?,
}

--[ Private ]--

-- Poses one entry for the current time. A Model is moved by its pivot
-- (every part of a multi-handle relic together); a lone BasePart -- the
-- gear drop's carrier -- by its CFrame.
local function pose(instance: Instance, entry: FloatEntry, now: number)
	local elapsed = now - entry.startedAt
	local bob = entry.bobAmplitude * math.sin(elapsed * entry.bobAngularSpeed + entry.phase)
	local cframe = entry.base * CFrame.new(0, bob, 0)
	if entry.spinAxis then
		cframe = cframe * CFrame.fromAxisAngle(entry.spinAxis, entry.spinRate * elapsed)
	end
	if instance:IsA("Model") then
		instance:PivotTo(cframe)
	elseif instance:IsA("BasePart") then
		instance.CFrame = cframe
	end
end

function DropFloatController._onHeartbeat(self: typeof(DropFloatController))
	local now = os.clock()
	for instance, entry in self._entries do
		-- Gone from the DataModel without an Unregister (destroyed by the
		-- server before the component's janitor ran): drop it here.
		if not instance.Parent then
			self:Unregister(instance)
			continue
		end
		pose(instance, entry, now)
	end
end

--[ Public ]--

-- Starts floating `instance` from `config.base`. Re-registering an
-- instance replaces its entry (and restarts its clock).
function DropFloatController.Register(self: typeof(DropFloatController), instance: Instance, config: FloatConfig)
	if not self._entries[instance] then
		self._count += 1
	end
	self._entries[instance] = {
		base = config.base,
		bobAmplitude = config.bobAmplitude,
		bobAngularSpeed = (2 * math.pi) / config.bobCycle,
		phase = config.phase or 0,
		spinAxis = if config.spinAxis then config.spinAxis.Unit else nil,
		spinRate = config.spinRate or 0,
		startedAt = os.clock(),
	}
	if not self._connection then
		self._connection = RunService.Heartbeat:Connect(function()
			self:_onHeartbeat()
		end)
	end
end

-- Stops floating `instance`; its pose is left wherever the last frame put
-- it (the caller's pickup tween or fade takes over from there). Safe to
-- call for an instance that was never registered.
function DropFloatController.Unregister(self: typeof(DropFloatController), instance: Instance)
	if not self._entries[instance] then
		return
	end
	self._entries[instance] = nil
	self._count -= 1
	if self._count <= 0 then
		self._count = 0
		if self._connection then
			self._connection:Disconnect()
			self._connection = nil
		end
	end
end

function DropFloatController.IsRegistered(self: typeof(DropFloatController), instance: Instance): boolean
	return self._entries[instance] ~= nil
end

return DropFloatController
