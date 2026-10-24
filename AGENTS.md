# Project Hades: agent guide

Instructions for any coding agent (Codex, Claude Code, OpenCode, ...) working
in this repository. Claude Code also reads `CLAUDE.md`, which imports this
file. Keep this file the single source of truth for shared rules.

## The repository

Project Hades is a Roblox action roguelite (Luau), synced into Studio with
Rojo. There are two places and one shared core:

| Path | What it is |
|---|---|
| `Places/Dungeons/` | The dungeon run place (combat, relics, events, bosses). |
| `Places/Lobby/` | The hub place (NPCs, shop, forge, queue). |
| `bfg-core/` | **Git submodule** (`BloxForge-Games/bfg-core`, live branch `main`). Shared services, controllers, interfaces, data and libraries used by both places. |
| `bfg-debug/` | Git submodule with debug tools. |
| `dungeons.project.json`, `lobby.project.json` | Rojo projects, one per place. |
| `tools/verify_places.py` | Static boot check for both places. |

Read these before design or architecture work:

- `GDD.md`: the condensed game design. It is the design target, not a
  description of the code.
- `REFACTOR-2026-09.md` and `bfg-core/Docs/Architecture.md`: the module map,
  boot order, service rules and networking conventions. Read them before
  touching dungeon flow, gates, landing, extraction, the join pipeline, or
  adding a service dependency.

## Setting up a fresh worktree

A new worktree does not inherit the submodules, packages or generated files.
Run these once from the worktree root:

```bash
git submodule update --init --recursive
git -C bfg-core switch -c <your-branch-name>
rokit install --no-trust-check
(cd bfg-core && wally install)
rojo sourcemap dungeons.project.json --include-non-scripts -o sourcemap.json
rojo sourcemap lobby.project.json --include-non-scripts -o sourcemap.lobby.json
```

- **bfg-core starts on a detached HEAD.** Create a branch in it (second
  command) before editing, or your commits strand and cannot be pushed.
- **Type definitions are gitignored.** Download them once per worktree,
  pinned to the luau-lsp version in `rokit.toml`:

  ```bash
  mkdir -p tools/luau && curl -sSfL -o tools/luau/globalTypes.d.luau https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/1.69.0/scripts/globalTypes.d.luau
  ```

- **`rokit install --no-trust-check`** skips a prompt about `lune`, a
  tool pinned outside this repo that normal work never uses.
- **`wally install` rewrites `bfg-core/wally.lock`** until the lock is
  fixed on bfg-core's main. Undo it with `git -C bfg-core checkout
  wally.lock`; never commit it with a feature.
- **Packages are untracked.** Without `wally install` every package require
  shows as "Unknown require".

## Architecture rules

- **Blitz is the loader** (`bfg-core/Source/Shared/Blitz.luau`). A module is a
  table with `Name`, optional `Dependencies`, a non-yielding `Init` and a
  `Start`. Modules require each other directly.
- **Cross-place or optional lookups** go through
  `Blitz.OptionalService("Name")` (server) or
  `Blitz.OptionalController("Name")` (client), resolved at call time and
  nil-guarded. Never require a Dungeons-only module from bfg-core.
- **Never require DungeonService from a consumer.** It requires its
  consumers. Use `Blitz.OptionalService("DungeonService")` and its signals
  (`OnFloorTeardown`, `OnFloorReady`).
- **One owner per value.** Attributes such as `GateState`, `FogRevealed` and
  `Invulnerable` have a single writer; do not write them from elsewhere.
- **Networking is Blink.** Definitions live in `bfg-core/Network/*.blink`.
  After editing one, regenerate from `bfg-core/Network` with
  `blink <File> -y` (for example `blink Player -y`). Never hand-edit the
  generated `Source/*/Network/` files.
- **Tables over remotes:** a numeric-keyed table with a hole (`{ [2] = x }`)
  does not survive a remote as an array. Send every slot (use `false` for
  empty) or use string keys.
- **Streaming:** a server spawner of a model that a client component reads
  sets `ModelStreamingMode = Atomic` before parenting. Client components wait
  for the primary part and `WaitForChild` every child they read.
- **Profile schema changes** need a migration step in
  `bfg-core/Source/Server/Services/DataService/Migrations.lua` and a bump of
  `CurrentVersion`. New profiles come from `DataTemplate.lua`.
- **Relic text is the source of truth.** Descriptions in `RelicData.lua` own
  the numbers; code is synced to them, never the reverse. Scaling relics show
  the real number through `runtimeDescriptionCallback`.

## Code style

- Public methods PascalCase, private methods `_camelCase`, local functions
  camelCase. React components are PascalCase locals.
- `--!strict` on new modules.
- **No backtick string interpolation** in project code; use `string.format`
  or concatenation.
- Studio-only chatter goes through `Shared/Functions/Log`, not `print`. Do
  not leave debug prints behind.
- React-lua UI: siblings at equal ZIndex draw in an undefined order, so give
  plates and content explicit ZIndex values. A CanvasGroup clips its own
  UIStroke (use a sibling border frame). `UIShadow` is a real instance.
- Dialogue text is HyperText markup (`<color=r,g,b>`, `<wait=.3>`), not
  RichText. Coloured words use the relic palette: gold `255,170,0`, blue
  `108,196,255`.

## Required checks before every commit

Run all of these on the files you changed. All must pass.

```bash
stylua --syntax Luau --check <files>
selene <files>
python tools/verify_places.py
```

Type check, once per place, with the ignore list passed as flags (luau-lsp
cannot read `.vscode/settings.json`):

```bash
luau-lsp analyze \
  --ignore='**/_Index/**' --ignore='**/Packages/**' --ignore='**/ServerPackages/**' \
  --ignore='**/Libraries/AfterImage/**' --ignore='**/Libraries/HyperText/**' \
  --ignore='**/Libraries/LocationMarkerSystem/**' --ignore='**/Libraries/LootPlan/**' \
  --ignore='**/Libraries/ProfileService/**' --ignore='**/Libraries/RaycastHitbox/**' \
  --ignore='**/Libraries/ViewportModel/**' --ignore='**/Libraries/WindShake/**' \
  --ignore='**/Libraries/Shime.luau' \
  --ignore='**/Source/Client/Network/**' --ignore='**/Source/Shared/Network/**' \
  --ignore='**/Source/Server/Network/**' \
  --sourcemap=sourcemap.json --definitions=tools/luau/globalTypes.d.luau <files>
```

Repeat with `--sourcemap=sourcemap.lobby.json` for anything in bfg-core,
since it loads in both places.

**Line endings.** Some working copies are CRLF. `stylua --check` reports a
whole-file diff on a CRLF file. Check an LF copy instead
(`tr -d '\r' < file > /tmp/x.lua && stylua --syntax Luau --check /tmp/x.lua`).
Never use `stylua --line-endings Windows`; it corrupts comment lines. Keep
each file's existing line endings when you write it.

## Committing

1. **Commit inside `bfg-core` first**, then push its branch.
2. **Then commit in the parent repo**, including the bumped `bfg-core`
   submodule pointer.

The parent must never point at a bfg-core commit that only exists in your
worktree. Never commit someone else's uncommitted edits: stage only the files
or hunks you changed.

## Working in parallel with other agents

Several agents may work on this repo at once, one worktree each.

- **Stay in your lane.** Touch only the files your task needs.
- **Shared hotspots cause conflicts.** Coordinate before editing these:
  `bfg-core/Source/Shared/Enums/Attributes.lua`, `bfg-core/Network/*.blink`,
  `DataTemplate.lua`, and above all `Migrations.lua` (two agents adding the
  same version number will collide).
- **Rojo:** only one worktree syncs into a given Studio window. If you run
  `rojo serve`, use a port no other worktree uses (`--port 34873`, ...).
- **Studio:** only the agent assigned to Studio may change place files.
  Place-file changes (assets, custom prompts, `StarterPlayerScripts`) are not
  in git; the user must save the place in Studio to keep them.

## Things that live only in Studio

These are in the place files, not the repo: `GameAssets` (models, sounds,
images), the custom proximity prompt renderer under
`StarterPlayer.StarterPlayerScripts.CustomProximityPrompts`, and NPC models.
Renaming an asset that code looks up by name (for example weapons under
`GameAssets.Weapons`) must be done in both places.
