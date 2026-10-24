# Project Hades: September 2026 audit and refactor

A map of what changed in the four-phase audit pass, written for whoever (human or Claude) opens this repo next. `bfg-core/Docs/Architecture.md` is the reference for how the code is *meant* to fit together; this file is the changelog that explains *why the tree looks like it does now* and what to be careful about. Everything below is staged in both repos at the time of writing; the user commits.

## Layout reminders

- Live checkout is `Github/project-hades`. `bfg-core/` is a git submodule and has its own index; stage in both.
- Two places: `Places/Dungeons` and `Places/Lobby`. Shared code lives in `bfg-core/Source/{Shared,Client,Server}` and mounts as `ReplicatedStorage.Submodules.Core.*` / `ServerScriptService.Submodules.Core.*`.
- Gates after every change: `stylua`, `selene Places`, `(cd bfg-core && selene Source && stylua --check Source)`, the `typecheck: all` task from `.vscode/tasks.json` (regenerates both sourcemaps), `python tools/verify_places.py`.
- Blink (`bfg-core/Network/*.blink`) is regenerated with `cd bfg-core/Network && blink <Domain> -y -q`, then stylua twice on the generated `Source/*/Network` folders. Never hand-edit generated files.
- `TileSweep` is source-checked-in under `bfg-core/Libraries/TileSweep/` (the old `.rbxm` broke Rojo 7.5.1 and is gone).

## Phase 1: live-server bugs

| Fix | Where |
|---|---|
| No more forced MerchantShop as room 1 | `Planner.lua` `DEBUG_FIRST_ROOM_EVENT = nil` |
| Party wipe teleports to the lobby again | `LifeService._scheduleLobbyTeleport` |
| Chat commands gated: Studio, or group rank >= 250 | `ChatCommandsService._canRun`; `Constants.GROUP_ID = 33936009`, `COMMAND_MIN_GROUP_RANK` |
| Relic selling validated (unlocked merchant, in range); Cursed relics refused | `EventService._onSellRelic`, `_isAtUnlockedMerchant` |
| Profile: no dump on join; pushes coalesced per frame; load pcall'd; clean leave no longer kicks | `DataService/init.lua` |
| Join order: profile loads on the raw join, `OnPlayerAdded` fires once when profile AND SetupCharacter are in, then `OnPlayerDataLoaded` | `PlayerEventService` (`OnPlayerJoined`, `NotifyProfileLoaded`), `DataService` |
| Profile schema versioning | `DataTemplate.Version`, `DataService/Migrations.lua` (`CurrentVersion`, `Steps`, `Apply`) |
| Store key in one place | `Constants.PROFILE_STORE_KEY` (still the test key) |
| Debug tooling not mounted | `DebugTools` mapping removed from both `*.project.json` |

## Phase 2: performance

Server:
- `ZombieSpawnService` miniboss wave loop polls once a second, warns once per cap episode, counts the room's own zombies.
- `StatusConditionService` runs ONE 10 Hz sweep over `_active` records instead of two threads per status instance.
- `ZombieService` hit frames query every 2nd frame and stop once every hittable player is registered.
- `MobBase` AI: per-mob start stagger, one LOS ray per tick, pathfinding only when the target moved > 4 studs or the mob is stuck.
- `DamageService`: `SlainBy` written only on change; per-player relic snapshot (`RelicService:GetRelicSnapshot`, invalidated on registry change) replaces 80-100 lookups per hit; target statuses resolved once per hit and passed down.
- `VFXService`: sweep capped at 25 queries, persistent hitbox exits when the caster is gone, detection registries weak-keyed, OverlapParams per call.
- `IgnoreListService`: mob `RaycastHitbox` parts sit in the `MobRaycastHitbox` collision group; weapon queries use `WeaponQuery`. The replicated ignore list no longer churns per mob.
- `RelicService` 1 Hz incremental tick skips when nobody owns Fireworks / Ghost Dragon.
- Generation yields every 8 placements (`DungeonGenerator`); stale-floor tables cleared on teardown.

Moved to the client, replicated to everyone via broadcasts:
- Mob spawn/despawn fades: `Combat.MobFade` event, `ZombieController` is the single fade owner, timings in `Shared/Data/MobFadeData.lua`.
- Mob health bar animates client-side from replicated health (`ZombieController`).
- Aura fades: `Combat.VFXFade` event + `VFXFadeController`; `vfxFade.lua` runs client-side.
- Relic replication is a typed per-player delta (`RelicsReplicated { UserId, Registry, List, Removed? }`) plus `RelicsSnapshot` on join; both client caches key by numeric UserId.
- Unreliable events: `DamageVFX, StatusVFX, MeleeSwingReplicated, MeleeSwingHit, MobAttack, MobLunge, CameraShake`. Damage numbers stay reliable.

Client:
- `DropPickupSweepController`: one 10 Hz sweep for coin/orb pickup (no per-drop Heartbeat).
- `DropFloatController`: one Heartbeat for every resting relic, gear and coin bob/spin.
- `OcclusionController`: one occlusion pass at 30 Hz feeding `WallsTransparencyController`, `BuildingTransparencyController` and `CharacterHighlightController`. Local character behind cover: wall fades AND outline+fill; mobs: outline+fill.
- `RelicRenderController` visibility loop no longer re-tweens every frame while hidden.
- Hover dim: one descendant walk per drop, 0.1 s debounce, one shared palette `Shared/Data/PickupHoverStyle.lua`.
- `DamageIndicatorController`: one font constant, one shared crit-jitter loop.

## Phase 3: dead code and logging

Deleted: `VFXData.lua`, RaycastHitbox/WindShake libraries, PlayFabSDK, ServerPackages mapping + wally server dep, `BaseStats` enum, `MeleeWeaponService`, `DeathGradientInterfaceController`, the whole rune system (RuneService, RuneData, RuneNames, `Functions/Rune`, the two Blink events, the stat hooks in PlayerStatsService/DamageService, the tag), the vaulted Spray Paint relic, `viewportScaleIndex` on every relic row, unread `knockback`/`canRagdoll` magic fields, dead enum entries, dead signals (`OnRoomLeft`, `OnPlayerLanded`, `OnRoomCleared`) and dead functions across MobBase, DamageService, ZombieSpawn, FogOfWar, EncounterChest, RunEscrow, DungeonService, CutsceneController, the relic renderer.

Kept on purpose: `EasyVisuals.rbxm` (used by inventory frames), `UnequipItem`, the dev seed kit in `DataTemplate` (commented as such), the three Roact interfaces, `OnRunStarted` / `OnRunAdvancing` / `OnFinalDungeonCompleted` / `OnPlayerExtracted` (dungeon flow is WIP; the last currently has no listener).

Logging: `bfg-core/Source/Shared/Functions/Log.luau`. `Log.debug` / `Log.warn` print only in Studio. Development chatter and expected-state warnings go through it; genuine failures (missing asset, failed teleport, profile load) keep plain `warn`.

Also: `isEncounterEnemy` shared helper (`Shared/Functions/Mob/`), DamageService asserts its on-hit module set at boot, the screen-pulse token guard is real, `Constants` derives place ids from `PlaceIdData`.

## Phase 4: architecture

`DungeonService` (was 3,258 lines) is now a 462-line facade: Dungeon/Run data, the Signals table, forwarders for every old public name. Behaviour moved verbatim into:

| Service | Owns |
|---|---|
| `DungeonGenerator` | placement, backtracking, prefab pools, `_relocateChunkBuildings`, `Generate(descriptor)`, `DestroyFloor()` |
| `GateService` | gate cycle + event hold as ONE `_runGateHold(gate, dungeon, rules)`; single owner of `GateState` (`_setGateState`), `_openedSegments`, hold tables |
| `LandingService` | join/landing cinematic, `LANDING_*` constants, lands on `OnFloorReady` |
| `RunFlowService` | `StartRun`, `AdvanceRun` (releases freezes + fades out on generation failure), teardown, exit portal, `_extractPlayer` |

Floor lifecycle signals on `DungeonService.Signals`, in order: `OnRunStarted` -> `OnFloorTeardown` (before rooms are destroyed) -> `OnDungeonGenerated` -> `OnFloorReady` -> `OnRoomEntered` / `OnSegmentCleared` ... -> `OnExitPortalRising` -> `OnPlayerExtracted` -> `OnRunAdvancing` -> `OnFloorTeardown` ... Per-floor resets hang off `OnFloorTeardown`; landing and fog off `OnFloorReady`.

Service-graph rules (enforced now, keep them):
- No consumer `require`s `DungeonService`. Use `Blitz.OptionalService("DungeonService")` at call time or its signals. `Boss.lua` and `ExitGateWindService` require it directly for exported types only; that is fine because the facade requires nothing back.
- No private reach-ins between services. Promoted: `DungeonService:UpdateNextGateMarker/DestroyNextGateMarker/EmitDungeonDoneEffect`, `EncounterService:IsLobbyActive/PublishLobbyData`, `RelicMachineService:PickMachineLanding`, `FogOfWarService:IsRevealed/HideRoom`, `InvulnerabilityService:OpenWindow/CloseWindow`.
- One owner per value, mirrors derived in the setter: gate state (GateService), room reveal `FogRevealed` (FogOfWarService `_setRevealed`), run coins (RunEscrowService `_commitCoins` -> RemoteProperty + `RunCoins` attribute), lives/death state (LifeService `_setLives`/`_setDeathState` -> `_publish*`), invulnerability (InvulnerabilityService windows, reasons Jetpack > Cutscene > Combat; EncounterService opens Cutscene windows), relic slots (RelicService).
- Extraction order: `ExtractionSweep` cue -> sweep hold -> `TeleportAsync` -> `LifeService.Signals.OnPlayerLeavingToLobby` -> RunEscrow banks -> `run.exited`. In Studio nothing teleports, so nothing banks.
- `Revive` has a per-player re-entrancy latch.

Shared functions added (`bfg-core/Source/Shared/Functions/`):

| Module | Replaces |
|---|---|
| `Combat/forEachEnemyInRadius` | 4 copies of the radius-damage loop (VFXService.RegisterHitbox stays hand-rolled: tag-gated, registry-deduped) |
| `Combat/snapToGround` | 4 ground raycasts (emitVFXPart keeps its own) |
| `Character/getRoot` | ~20 `FindFirstChild("HumanoidRootPart")` + cast sites |
| `Mob/isEncounterEnemy` | EnemyType Miniboss/Boss checks (MobBase keeps IsBoss/IsMiniBoss reads: spawn ROLE, not tier) |
| `VFX/fadeSubtree` | 8 fade/dim walks |
| `VFX/playHitBurst` | 2 SwordSlash hit bursts |
| `VFX/emitVFXPart` | attribute-driven prefab bursts (`EmitCount/EmitDelay/EmitDuration`, `TimeScale_End/_Duration`; options `Scale, EmitScale, DefaultEmitCount, Color, LifetimeScale, Ground*`) |
| `Relic/dressRelicDisplay`, `Relic/buildPromptCard` | nameplate/glow/particle dressing and the prompt-card contract in Relic, GearDrop, merchant stalls |
| `Log` | Studio-only print/warn |

MobBase: `_lobBombs(killer, spec)` replaces the pumpkin and fuse-bomb twins; the class is properly typed (`type Fields`, `export type MobBase`), no `any`.

Client: `EventController` (846 lines) keeps dialogue-graph state and every `controller()` entry point; `MerchantStallRenderController` (new) owns the stall renderer, hover, buy flourish and float loop.

Blitz: header now states the real guarantee. `AwaitStart` / `OnStart` resume when every `Start` has been DISPATCHED (run to its first yield), not finished. Publish state in `Init` or before the first yield in `Start`.

## Other things done in the same window

- Relic slots: 10 open by default, 15 max, five shop rungs (250 Common, 500 Uncommon, 750 Rare, 1000 Epic, 1250 Legendary) in `RelicSlotShopData`; the merchant refuses buys at the relic cap.
- Loading screen = tile sweep: `ScreenSweepController` snaps tiles on at boot, loading text + bar draw over them, landing controllers fade the bar then Cascade off. Extraction covers with Swirl. Presets and timings in `ScreenSweepData`.
- Pickup bursts: `CollectRelicVFX` at the relic, `CollectRelicVFXCharacter` on the collector, rarity-tinted, played by every client off `CollectedById`. Gear uses the same pair. The old Collected attachments are gone from relics and gear.
- Sword slash flicker: `warmSwordSlashTextures` keeps the nine flipbook textures GPU-resident (tiny black clones in front of the camera) during swings and casts.

## Gotchas for the next session

- `core.autocrlf=true`: `git add` prints "LF will be replaced by CRLF" for every LF file it touches. It is noise, not a change. Verify with `git diff --cached --numstat`.
- Never run `stylua --line-endings Windows`; it emits `\r\r\n`.
- `luau-lsp analyze` on a single file must run from the repo root with the sourcemap, or requires resolve wrongly. A new module shows as "Unknown require" until the sourcemap is regenerated.
- Multiple agents editing concurrently must not regenerate `sourcemap.json`; build a scratch sourcemap instead.
- Blitz sub-tiers are hand-listed in the bootstrappers (`DataService.SubServices`, `RelicController.SubControllers`); a new sub-tier folder is not auto-loaded.
- The Studio MCP bridge times out; the user boots and tests in Studio.
- `wally.lock` still lists the removed server dependency until wally runs.
- `PlayerEventService` still writes the spawn-time `Invulnerable = false` default directly; every other writer goes through `InvulnerabilityService`.

## Not done (deliberately)

- Keystone Trial / hub data schema (`HubData`, per-dungeon difficulties, `DungeonSequence` descriptors): declined for this pass. With one reserved server per run, run state already persists across chained dungeons; the trial is a data + flow change on top of `RunFlowService`.
- CI stays on selene + stylua only.
- `DamageService` DoT ticks still play the mob's damaged animation (the client-side health bar move could not distinguish them without a DamageService hook).
