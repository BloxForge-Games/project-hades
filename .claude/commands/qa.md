---
description: Play the game 5+ times through the Studio MCP bridge and report bugs and performance issues (no fixes, no edit-DM changes)
---

# /qa — scripted playtest sweep

Run the Dungeons place five times through the Roblox Studio MCP bridge, driving a full gameplay loop server-side each time, and hand back a ranked list of bugs and performance issues. **Report only — fix nothing, and never modify the edit DataModel** (no Scripts, attributes or instances through `run_code`; play-session state is fine, it is discarded on stop).

## 0. Preconditions (check, don't assume)

1. `mcp__Roblox_Studio__get_studio_mode` must answer. A timeout means the MCP plugin toggle inside Studio is OFF — ask the user to toggle it and stop; do not keep retrying.
2. Confirm the open place is `[project-hades] Dungeons` and that Rojo is synced: with `run_code` (edit DM, read-only) print `game.PlaceId, game.Name` and check a recently changed file's `.Source` contains a known recent string.
3. Note the rules of the bridge: `run_code` runs in the EDIT DM only. Playtests are `run_script_in_play_mode` (`mode: start_play`, `timeout: 55`), which runs the script on the play SERVER DM and auto-stops when it returns — keep every script **≤45 s**. After a run finishes, the next call often returns `{logs:[]}` in <1 s: call `get_studio_mode` (or `start_stop_play stop`) and re-send. The plugin's print concat throws on booleans — always `tostring`. Only server output comes back; client errors are invisible, say so in the report.

## 1. The five runs

Each script: `require` the loaded Blitz services straight from `ServerScriptService.Services.*` (returns the live module tables), wait for `DungeonService:GetActiveDungeon()` and `LandingService._landed[player]`, then drive the loop. Collect every `warn`/error line verbatim. Useful handles:

- Wave the real way: `GateService:_onGateFirstCrossing(roomId)` then `hrp.CFrame = dungeon.rooms[roomId].model:GetPivot() + Vector3.new(0, 4, 0)`.
- Kill through the real path: `DamageService:TakeDamage(player, humanoid, 400, false, false, true)`.
- Mobs alive: count `Humanoid`s with `Health > 0` under `workspace.IgnoreInstances.Mobs`; corpses in `.DeadMobs`; loot in `.Drops`; chests in `.Chests`.
- Perf: a `RunService.Heartbeat` connection recording `dt > 0.08` with a timestamp, plus `Stats.HeartbeatTimeMs`, `Stats.PhysicsStepTimeMs`, `Stats.InstanceCount`, `Stats.MovingPrimitivesCount`, `Stats:GetTotalMemoryUsageMb()`. Remember Play Solo shares one process: a gap can be client work; say "server frame gap" not "server stall" unless bisected.

| Run | What it covers | Assert |
|---|---|---|
| 1 Boot | join → preload done (`PlayerEventService.OnPlayerAdded`) → `OnFloorReady` → landed; mark timestamps; wrap `DungeonGenerator.Generate` to time it | preload < 10 s, Generate < 500 ms on 0 backtracks, landing teleports to the start, no warnings beyond the known ones |
| 2 First room | spawn room 1, kill all, watch drops / DeadMobs cleanup / `RelicOfferService:HasOpenOffer` | queue exhausts, corpses clear within ~10 s, no stray offer |
| 3 Segment | rooms 1 → 2, `OnSegmentCleared`, `GateService:IsSegmentOpened(1)`, chest count, EXP delta via `DataService:GetProfileData(player)` (`CurrentExp`) | segment opens ≤ 3 s after the last kill (solo), chest spawns, EXP rises, room 3 not pre-spawned |
| 4 Systems | `RelicOfferService:Offer(player, {3 names}, "qa")` and wait for the 30 s auto-pick; `AuraService:SetAura` Stormcharged → `DamageService:GetCritParameters` (+30 chance, same mult); Stonebound → `GetStoneboundPayload` = (0, 0.30); `LifeService:LoseLife` twice → downed | offer resolves at 30 s with a relic in `RelicService:GetRelicsRegistry`; aura numbers match AuraData; lives 2→1→downed |
| 5 Stress | `MobSpawnService:SpawnMobsInRoom` for ~10 combat rooms, sample perf every 2 s for 14 s, mass-kill, sample 12 s more | avg frame ≤ 17 ms with 50+ mobs, max gap during mass death and cleanup, instance count returns to baseline |

Add a 6th run if any assertion fails and you need a second sample before calling it a bug.

## 2. Report format

Lead with a one-line verdict, then:

1. **Bugs / defects** — a table: `#`, severity (High / Medium / Low / Info), finding, evidence (run number, the exact log line or number). Anything in the place file (bad asset ids, missing markers, junk instances) is still a finding — say it is place-side.
2. **Performance** — frame gaps with timestamps and what was happening, generation time and backtracks, memory delta, cleanup hitches.
3. **Verified working** — what passed, with the numbers, so the user knows what was covered.
4. **Not covered** — bosses, events, multi-floor, client-side UI/VFX; ask for the client console if needed.

Do not propose fixes in the report; the user triages first. Save nothing to the place.
