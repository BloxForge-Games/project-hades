# Project Hades: Claude Code guide

@AGENTS.md

The shared rules above apply in full. The points below are specific to
Claude Code.

## Asking questions

- Ask pre-task design questions with the AskUserQuestion tool (multiple
  choice), never as a prose list.
- When a request is ambiguous, do everything that does not depend on the
  answer first, then ask.

## Roblox Studio MCP

- Only use the Studio tools when this session is the one assigned to Studio.
- Several Studio windows may be open, and the bridge can land each
  `run_code` call in a different one. Print `game.PlaceId` in every call
  (Lobby `104900904749892`, Dungeons `139780156059811`), write Studio edits as
  idempotent scripts that report "already" or "done now", and stop at once if
  a call reaches an unrelated place.
- Wrap Studio edits in `ChangeHistoryService:SetWaypoint` calls so the user
  can undo them, and tell the user to save the place afterwards.
- `run_code` edits the edit DataModel only. Use `run_script_in_play_mode`
  (45 s or less) for server-side checks during play.
- `require` inside `run_code` caches modules; verify an edited module by
  requiring a clone of it.

## Patching files

- Prefer exact-anchor patch scripts that assert each anchor matches once.
  A failed assert usually means the user edited the file at the same time:
  re-read it rather than retrying.
- Commit messages end with the attribution line the session specifies.
