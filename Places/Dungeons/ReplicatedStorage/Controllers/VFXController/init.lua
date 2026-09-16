--!strict
--[[
     Author(s): 
     Module: VFXController.lua
     Description:
]]

--[ Roblox Services ]--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

--[ Exports & Types & Defaults ]--

local Magic = require(ReplicatedStorage.Submodules.Core.Source.Network.Magic)
-- local VFXData = require(ReplicatedStorage.Submodules.Core.Shared.Data.VFXData)
local Attributes = require(ReplicatedStorage.Submodules.Core.Shared.Enums.Attributes)

-- Sub-registry: per-projectile modules for MOB ranged attacks. Keyed
-- by projectileName (matches ZombieData[name].genericAttacks[i].projectileName).
-- Required as a child folder so adding a new ranged-mob projectile is
-- just dropping a ModuleScript in MobProjectiles/ — no edits here.
local MobProjectiles = require(script:WaitForChild("MobProjectiles"))

-- AimController requires this module at load, so this side reaches it
-- lazily: required on first use, once both modules exist.
local aimControllerLazy: any = nil
local function getAimController(): any
	if aimControllerLazy == nil then
		aimControllerLazy = (require :: any)(ReplicatedStorage.Controllers.AimController)
	end
	return aimControllerLazy
end

local VFXController = {
	Name = "VFXController",
}

--[ Imports ]--

--[ Constants ]--

--[ Properties ]--

VFXController._vfxRegistry = {} :: { [string]: any }
-- True while the attack button is held. The aura attack must start on
-- EITHER edge: button pressed while Susanoo is up (the press handlers),
-- or Susanoo coming up while the button is already held (the attribute
-- watch in Start). Without the second, casting Susanoo mid-fire
-- never started the attack until the button was released and pressed
-- again.
VFXController._auraHeld = false

--[ Private Functions ]--

function VFXController._startAuraAttack(self: typeof(VFXController))
	self._auraHeld = true
	local char = Players.LocalPlayer.Character

	if char and char:GetAttribute(Attributes.SusanooEnabled) then
		Magic.AuraAttackStart.Fire()
	end
end

function VFXController._stopAuraAttack(self: typeof(VFXController))
	self._auraHeld = false
	Magic.AuraAttackStop.Fire()
end

-- The other edge: Susanoo comes up while the button is already held.
-- Per character, so a respawn rebinds cleanly.
function VFXController._watchAuraRisingEdge(self: typeof(VFXController))
	local player = Players.LocalPlayer
	local function bind(character: Model)
		character:GetAttributeChangedSignal(Attributes.SusanooEnabled):Connect(function()
			if self._auraHeld and character:GetAttribute(Attributes.SusanooEnabled) == true then
				Magic.AuraAttackStart.Fire()
			end
		end)
	end
	player.CharacterAdded:Connect(bind)
	if player.Character then
		bind(player.Character)
	end
end

--[ Public Functions ]--

function VFXController.GetRegistry(self: typeof(VFXController)): { [string]: { [any]: any } }
	return self._vfxRegistry
end

-- Runs one effect module for `player`. The single entry point for both
-- paths: the caster's own immediate run (PlayVFX) and everyone else's
-- replicated one (OnVFXReplicated).
function VFXController._runVFXModule(self: typeof(VFXController), player: Player, vfxName: string, cframe: CFrame)
	local moduleName = vfxName:gsub(" ", "")
	local vfxFunction = self._vfxRegistry[moduleName]
	if not vfxFunction then
		warn("[VFXController] No VFX found for name:", moduleName)
		return
	end
	vfxFunction(player, false, cframe)
end

-- The caster runs their OWN copy of the effect NOW, and skips the copy the
-- server broadcasts back (see the OnVFXReplicated handler). Before this the
-- caster waited a full client -> server -> client round trip to see their
-- own cast animation, cast sound, particles and cutscene -- 0.1-0.2s of
-- nothing after the button.
--
-- Safe because the caster's client was already the only one doing the
-- authoritative work: every module gates its hitbox requests on
-- `player == Players.LocalPlayer`, so running it here does exactly what it
-- did before, just earlier. Mana, cooldown and ownership are still checked
-- on the server; MagicController mirrors those checks before it gets here,
-- so a rejected cast (a desync) is the only way to see an effect that did
-- not land.
function VFXController.PlayVFX(self: typeof(VFXController), vfxName: string)
	local cframe = Players.LocalPlayer.Character.HumanoidRootPart.CFrame
	task.spawn(function()
		self:_runVFXModule(Players.LocalPlayer, vfxName, cframe)
	end)
	Magic.CastRequested.Fire({ MagicName = vfxName, CFrame = cframe })
end

-- Mob ranged-attack projectile dispatch. Called by ZombieController
-- when ZombieService.OnReplicateMobRangedAttack fires. Delegates to
-- the per-projectile module under MobProjectiles/ keyed by name.
function VFXController.RunMobProjectile(
	_self: typeof(VFXController),
	projectileName: string,
	zombieModel: Model,
	originCFrame: CFrame,
	targetPosition: Vector3,
	castUuid: string,
	attackConfig: { speed: number, lifetime: number, hitRadius: number }
)
	MobProjectiles.Run(projectileName, zombieModel, originCFrame, targetPosition, castUuid, attackConfig)
end

--[ Initializers ]--

function VFXController.Start(self: typeof(VFXController))
	self:_watchAuraRisingEdge()

	-- Controller signal connections (Potential memory leaks)
	getAimController().OnWeaponActivate:Connect(function(activated: boolean)
		if activated then
			self:_startAuraAttack()
		else
			self:_stopAuraAttack()
		end
	end)

	-- The broadcast reaches everyone, the caster included -- other listeners
	-- (the cast dialogue strip) need the caster's own cast too -- but the
	-- caster's effect module already ran locally in PlayVFX, so THIS client
	-- skips its own cast here rather than playing it twice.
	Magic.CastReplicated.On(function(payload)
		local player = payload.Caster
		if not player then
			return
		end
		local vfxName = payload.MagicName
		local cframe = payload.CFrame
		if player == Players.LocalPlayer then
			return
		end
		self:_runVFXModule(player, vfxName, cframe)
	end)

	UserInputService.InputBegan:Connect(function(input, gameProcessedEvent)
		if gameProcessedEvent then
			return
		end

		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			self:_startAuraAttack()
		end
	end)

	UserInputService.InputEnded:Connect(function(input, gameProcessedEvent)
		if gameProcessedEvent then
			return
		end

		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			self:_stopAuraAttack()
		end
	end)
end

function VFXController.Init(self: typeof(VFXController))
	for _, vfxModule in script:GetChildren() do
		-- Skip the MobProjectiles sub-folder — it's its own dispatch
		-- (required at the top of this file) and isn't a per-player-
		-- magic spell module. Folders containing init.lua surface as
		-- ModuleScripts in Roblox, so without this filter MobProjectiles
		-- would accidentally get registered as a magic spell named
		-- "MobProjectiles".
		if vfxModule:IsA("ModuleScript") and vfxModule.Name ~= "MobProjectiles" then
			local vfxName = vfxModule.Name

			self._vfxRegistry[vfxName] = (require :: any)(vfxModule)
		end
	end
end

return VFXController
