--!strict
--[[
	Module: Controllers/MemoryShrineController.lua
	Description:
	The Memory Shrine's board on this client (2026-11-13; server:
	MemoryShrineService). The altar's "Begin the trial." option
	(EventController:StartMemoryShrine) calls Open(altar): this asks the
	server for the player's board (MemoryShrineStart) and, when it is
	"ok", mounts the board (MemoryBoard, drawn with the relic offer's 3D
	cards) until it closes. Flips go to the server (MemoryShrineFlip) by
	board SLOT; the server judges and pays.

	One board at a time. Nothing is mounted between boards: the React
	root, its ScreenGui and the cards' parts exist only while one is open.

	THE LOCKOUT: once a board ends (or the server
	answers "done"), this client switches the altar's ProximityPrompts off
	(the dialogue opens client-side from them) and keeps them off: a
	prompt re-enabled by anything, or a prompt added later under the
	altar, is switched off again, until the altar is destroyed. The server
	refuses a finished board on its own; this is what stops the dialogue
	opening for a second visit.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage.Submodules.Core.Packages.React)
local ReactRoblox = require(ReplicatedStorage.Submodules.Core.Packages["React-Roblox"])
local DungeonNetwork = require(ReplicatedStorage.Submodules.Core.Source.Network.Dungeon)
local InterfaceManagerController =
	require(ReplicatedStorage.Submodules.Core.Source.Controllers.InterfaceManagerController)

local MemoryBoard = require(ReplicatedStorage.Interfaces.RelicOfferInterfaceController.ReactComponents.MemoryBoard)

local INTERFACE_ID = "MemoryShrineInterface"
-- The relic offer's layer: above the dialogue billboard (20), below the
-- cinematic bars (999) and the screen fades (9999).
local DISPLAY_ORDER = 50

local MemoryShrineController = {
	Name = "MemoryShrineController",
	Dependencies = { InterfaceManagerController } :: { any },

	-- The open board's React root, or nil.
	_root = nil :: any,
	-- True from Open until the board has closed (a second Open while the
	-- server is answering is ignored).
	_busy = false,
	-- [altar] = the lockout's connections (see the header).
	_locked = {} :: { [Instance]: { RBXScriptConnection } },
}

-- The altar can no longer be talked to on this client (see the header).
function MemoryShrineController.LockAltar(self: typeof(MemoryShrineController), altar: Instance)
	if self._locked[altar] then
		return
	end
	local connections: { RBXScriptConnection } = {}
	self._locked[altar] = connections
	local function hold(prompt: ProximityPrompt)
		prompt.Enabled = false
		table.insert(
			connections,
			prompt:GetPropertyChangedSignal("Enabled"):Connect(function()
				if prompt.Enabled then
					prompt.Enabled = false
				end
			end)
		)
	end
	for _, descendant in altar:GetDescendants() do
		if descendant:IsA("ProximityPrompt") then
			hold(descendant)
		end
	end
	table.insert(
		connections,
		altar.DescendantAdded:Connect(function(descendant: Instance)
			if descendant:IsA("ProximityPrompt") then
				hold(descendant)
			end
		end)
	)
	table.insert(
		connections,
		altar.Destroying:Connect(function()
			for _, connection in connections do
				connection:Disconnect()
			end
			self._locked[altar] = nil
		end)
	)
end

function MemoryShrineController.IsAltarLocked(self: typeof(MemoryShrineController), altar: Instance): boolean
	return self._locked[altar] ~= nil
end

function MemoryShrineController.IsOpen(self: typeof(MemoryShrineController)): boolean
	return self._busy
end

function MemoryShrineController._close(self: typeof(MemoryShrineController))
	local root = self._root
	self._root = nil
	if root then
		root:unmount()
	end
	self._busy = false
end

-- Opens (or re-opens) this player's board at `altar`. Does nothing when
-- the server has no board to play ("done", "invalid").
function MemoryShrineController.Open(self: typeof(MemoryShrineController), altar: Instance)
	if self._busy or self._locked[altar] then
		return
	end
	self._busy = true
	task.spawn(function()
		local ok, board = pcall(DungeonNetwork.MemoryShrineStart.Invoke, altar)
		if ok and board and board.Status == "done" then
			self:LockAltar(altar)
		end
		if not ok or not board or board.Status ~= "ok" or #board.Cards == 0 then
			self._busy = false
			return
		end
		local root = ReactRoblox.createRoot(Instance.new("Folder"))
		self._root = root
		root:render(ReactRoblox.createPortal(
			React.createElement("ScreenGui", {
				Name = INTERFACE_ID,
				ResetOnSpawn = false,
				IgnoreGuiInset = true,
				ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
				DisplayOrder = DISPLAY_ORDER,
			}, {
				Board = React.createElement(MemoryBoard, {
					board = board,
					onFlip = function(slot: number)
						return DungeonNetwork.MemoryShrineFlip.Invoke({ Shrine = altar, Index = slot })
					end,
					onClosed = function()
						if self._root == root then
							self:_close()
						end
					end,
					onEnded = function()
						self:LockAltar(altar)
					end,
				}),
			}),
			Players.LocalPlayer:WaitForChild("PlayerGui")
		))
	end)
end

function MemoryShrineController.Init(_self: typeof(MemoryShrineController)) end

function MemoryShrineController.Start(self: typeof(MemoryShrineController))
	-- A death or a respawn mid-board closes it on the spot.
	Players.LocalPlayer.CharacterRemoving:Connect(function()
		if self._root then
			self:_close()
		end
	end)
end

return MemoryShrineController
