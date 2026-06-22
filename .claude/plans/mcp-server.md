# Ghostty (fork) MCP server — implementation plan

Status: design locked, ready for implementation.
Branch/worktree: `mcp-server` at `/Users/ramon/git/ghostty-mcp-server`.

## Goal

A fork-only **MCP server** that lets an orchestrating agent (Claude Code / Codex)
both **control** the macOS Ghostty fork (reorganize splits/tabs, open tabs, run
commands) and **watch + respond to** live terminal sessions (bell, process exit,
shell-prompt transitions; read screen text; type input / approve CLI-agent
prompts).

## Non-goals / scope guardrails

- **Do NOT touch the web monitor.** Phone workflows only. We may *copy* its proven
  scaffolding (serial-queue + main-hop threading, `decideRoute`/`RequestParser`
  shape, token / Host-header / backoff security, the `keySpecs` native-keycode
  table) into the new MCP module, but we do not import from or extend it.
- **No host / emulation changes.** No edits to `src/host/*` or `src/termio/Client.zig`.
  The host already pushes `surface_event` (bell), `at_prompt`, and `child_exited`
  up to the GUI, and key encoding already happens GUI-side. The MCP server consumes
  existing GUI state + the libghostty C API. The ONLY Zig change allowed is two
  additive config keys in `src/config/Config.zig` (mirroring the web-monitor keys).
- Fork-only. Default off. An official Ghostty sharing `~/.config/ghostty/config`
  must never trip — keys live in `~/.config/ghostty-ramon/config`.

## Architecture

GUI-resident standalone module (`macos/Sources/Features/MCP/`), built on:

| Capability | Existing abstraction (reused, not rebuilt) |
|---|---|
| Read screen / scrollback | `ghostty_surface_read_text(surface, range, &out)` |
| Respond — text | `ghostty_surface_text` |
| Respond — keys (enter/esc/ctrl-c/tab/arrows/y/n) | `ghostty_surface_key` (mode-correct via GUI encoder) + copied `keySpecs` keycode table |
| Respond — scroll | `ghostty_surface_mouse_scroll` |
| Watch — bell | `ghosttyBellDidRing` notification |
| Watch — process exited | `ghostty_surface_process_exited` |
| Watch — command running vs at-prompt | `ghostty_surface_needs_confirm_quit` (coarse) + optional Swift `atPrompt` property fed from the already-arriving `at_prompt` frame (GUI-only add) |
| Layout / reorg | `BaseTerminalController` handlers + `SplitTree` pure transforms |
| Surface enumeration / uuid→view | `TerminalController.all` + `SurfaceView.uuid` |

**No second host-protocol client.** The host stays frozen.

## Transport — in-GUI HTTP + stdio shim (decided)

- **In-GUI HTTP MCP** (the real server): its own `NWListener` on a dedicated serial
  queue, JSON-RPC 2.0 over `POST /mcp`, plain-`application/json` response mode
  (no SSE needed — see watch below). Gated by `mcp-token` (`X-Ghostty-Token`
  header) and the copied Host-header / backoff defenses. Bind localhost-only by
  default.
- **stdio shim** (`ghostty-mcp`): a standalone Swift SPM executable in
  `macos/mcp-shim/` (NOT wired into `Ghostty.xcodeproj`, built with `swift build`).
  It is a dumb pipe: reads MCP JSON-RPC from stdin, POSTs each message to the
  in-GUI server, writes responses to stdout. Finds the server via `mcp-listen`
  (env override `GHOSTTY_MCP_URL`) and attaches the token (env `GHOSTTY_MCP_TOKEN`).
  Lets `claude mcp add ghostty -- ghostty-mcp` work. All logic stays server-side;
  the shim rarely changes.

## Config keys (fork-only, additive, default null/off)

In `src/config/Config.zig`, mirroring `web-monitor-listen`/`web-monitor-token`
(both `?[:0]const u8` so `ghostty_config_get` can return a C string):

- `mcp-listen` — `addr:port`; empty/null ⇒ disabled. Purely a BIND address.
- `mcp-token` — optional; if set, fully enforced (constant-time compare; header
  for `/mcp`). If empty ⇒ OPEN (logs a warning), access control is localhost/
  tailnet only. **This credential can spawn tabs and run shell commands — treat as
  a shell-execution credential; bind localhost or tailnet only.**

Swift getters in `macos/Sources/Ghostty/Ghostty.Config.swift`: `mcpListen`, `mcpToken`.

Plus a Zig parse/roundtrip test for the two keys (mirror the web-monitor-token test).

## Tool surface (MCP `tools/list` + `tools/call`)

All surface-addressing is by **stable surface UUID** (string). Discovery returns it.

### Read
- `list_surfaces` → `[{ id, title, pwd, window, tab, splitPath, focused, bell, exited, atPrompt }]`
- `read_surface` → `{ id, mode: "viewport"|"scrollback" }` ⇒ `{ text, cols, rows }`
- `get_layout` → the window→tab→split tree(s): `{ windows: [{ id, tabs: [{ id, tree }]}] }`

### Respond
- `send_text` → `{ id, text, submit?: bool }` (submit appends Return)
- `send_key` → `{ id, key }` where key ∈ enter|escape|tab|backspace|up|down|left|right|y|n|ctrl-c|ctrl-u
- `scroll` → `{ id, dy }` (signed wheel ticks)

### Watch
- `wait_for_event` → `{ filter?: { ids?: [string], types?: ["bell"|"exited"|"prompt"] }, timeoutMs?: number }`
  ⇒ blocks until a matching event or timeout, returns `{ event: { id, type, ts } | null }`.
  Implemented as a long-held `tools/call` (the HTTP connection stays open, exempt
  from the idle watchdog); a one-shot waiter is registered with the event bus and
  fulfilled off the serial queue — **never block the serial queue.**
- `watch_for_pattern` → `{ id, regex, timeoutMs?: number }` ⇒ polls `read_surface`
  text for the regex; for TUI agents that don't emit OSC 133. Honestly heuristic.

### Layout / control
- `focus_surface` → `{ id }`
- `new_tab` → `{ cwd?: string, command?: string }` (reuses `new_tab:<dir>` /
  `new_tab_command` semantics)
- `close_surface` → `{ id }`
- `perform_action` → `{ id, action }` where `action` is the existing keybind-action
  grammar string: `flip_split:…`, `toggle_split_direction:…`, `swap_split:…`,
  `move_split_to_new_tab`, `merge_tabs:…`, `mark_split`, `clear_split_mark`,
  `pull_marked_split:…`, `resize_split:…`, `goto_last_surface`.

## Watch mechanism / event bus

`MCPEventBus` (main-actor-ish, but published to the serial queue safely):
- Subscribes to `ghosttyBellDidRing` (bell), observes `process_exited` transitions,
  and `atPrompt` transitions.
- Keeps a small ring of recent `{ id, type, ts }` events so a `wait_for_event` that
  registers slightly late still catches a just-fired event (short coalescing window).
- `wait_for_event` registers a one-shot waiter (id/type filter + deadline). Fulfilled
  by the next matching event or a timer; resolves the held HTTP response. The serial
  queue is never blocked — the connection is parked and the response is written when
  the waiter fires.

## Addressing & layout invocation

- uuid→`SurfaceView` resolution happens on **main**, returning only value types
  across the main hop (never a `ghostty_surface_t`/`SurfaceView` across the hop) —
  same discipline the web monitor uses.
- Relative layout verbs (`swap_split:next`, `pull_marked_split`, `merge_tabs`) are
  focus-relative. **Phase 1: focus-then-act** (focus the uuid, run the existing
  handler). **Phase 2 (follow-up): anchor-parameterize** the `SplitTree` transforms
  (already mostly pure) so the action takes an explicit anchor and doesn't disturb
  user focus. Ship focus-then-act first.

## Threading (correctness-critical, copied discipline)

- Listener + all connections on a dedicated background **serial** queue (never
  `DispatchQueue.main`), making `DispatchQueue.main.sync` hops deadlock-safe.
- Every handler touching AppKit / `TerminalController.all` / `SurfaceView` /
  `ghostty_surface_*` hops to main and returns only value types.
- `wait_for_event` connections are long-lived and EXEMPT from the idle watchdog
  (like the web monitor's `/stream`). All other connections keep the idle + absolute
  deadlines + connection cap.
- Routing decision is a **pure** function `decideRoute(...) -> RouteDecision` (no
  AppKit/socket/mutation), unit-tested alongside `keySpecs`, `parseListen`,
  `RequestParser`, JSON-RPC framing, `surfacesJSON`, and the tool-dispatch mapping.

## Security (independent of token)

- `hostHeaderAllowed` DNS-rebinding guard (copied).
- Per-peer failed-token backoff (only when a token is set; copied).
- Per-connection idle + absolute deadlines + connection cap (copied), with
  `wait_for_event` exempt from idle only.
- All untrusted text rendered/returned as data (no shell interpolation; commands run
  via the explicit `new_tab`/`new_tab_command` path only).

## File-by-file wiring

Core (Zig):
- `src/config/Config.zig` — `mcp-listen` + `mcp-token` fields + docs + parse test.

macOS (Swift), new module `macos/Sources/Features/MCP/`:
- `MCPServer.swift` — `NWListener`, serial queue, `RequestParser`, `decideRoute`,
  JSON-RPC 2.0 (`initialize`, `tools/list`, `tools/call`), token/Host/backoff,
  start/stop.
- `MCPTools.swift` — tool registry + JSON schemas + dispatch (pure mapping where
  possible; main-hop for effects).
- `MCPInput.swift` — copied `keySpecs(forKey:)`/`keySpecs(forText:)` + key/text/scroll
  injection via the C API.
- `MCPLayout.swift` — `list_surfaces`/`get_layout`/`focus_surface`/`new_tab`/
  `close_surface`/`perform_action` against `TerminalController`/`SplitTree`.
- `MCPEventBus.swift` — bell/exited/prompt bus + `wait_for_event` waiters.
- `macos/Sources/Ghostty/Ghostty.Config.swift` — `mcpListen`/`mcpToken` getters.
- `macos/Sources/App/macOS/AppDelegate.swift` — start/stop (mirror web monitor).
- `macos/Ghostty.xcodeproj/project.pbxproj` — iOS exclusion for the new macOS-only
  MCP files (copy the web-monitor exclusion pattern; rely on the synchronized Sources
  group for inclusion).

Shim (separate SPM, NOT in the xcodeproj):
- `macos/mcp-shim/Package.swift` + `macos/mcp-shim/Sources/ghostty-mcp/main.swift` —
  stdio↔HTTP pipe.

Optional GUI-only add for richer watch:
- A Swift `atPrompt` property on the surface fed from the already-arriving `at_prompt`
  frame (no host change). If non-trivial, defer to `needs_confirm_quit` as the coarse
  proxy and note it.

Tests:
- `macos/Tests/MCP/MCPServerTests.swift` (filesystem-synchronized `GhosttyTests`
  group): `decideRoute`, `keySpecs`, `parseListen`, `RequestParser`, JSON-RPC framing,
  `tools/list` schema shape, tool-dispatch mapping, `surfacesJSON`, Host-header guard,
  backoff.
- Zig: config parse/roundtrip test for `mcp-listen`/`mcp-token`.

## Test / verify plan

- Zig: `zig build test -Demit-macos-app=false -Demit-xcframework=false -Dtest-filter=mcp`
  (and the existing config filter) — runs the config key test.
- Rebuild lib: `zig build -Demit-macos-app=false -Doptimize=ReleaseFast`.
- Swift: `macos/build.nu --action test` (or `xcodebuild … -only-testing:GhosttyTests/MCPServerTests test`).
- Build app: `macos/build.nu --configuration ReleaseLocal --action build`.
- Shim: `cd macos/mcp-shim && swift build`.
- Manual smoke: set `mcp-listen = 127.0.0.1:8765` + a token in
  `~/.config/ghostty-ramon/config`; `curl` `tools/list`; `claude mcp add ghostty -- ghostty-mcp`.

NOTE: full Swift app/test builds are minutes-long and are run by the human / main
loop AFTER the workflow — workflow agents must NOT run multi-minute builds inside a
turn (watchdog). They author + statically verify; the Zig config test is the only
cheap build they may attempt.

## Phasing

1. Server + `list_surfaces`/`read_surface`/`send_text`/`send_key`/`scroll` over the C API.
2. `wait_for_event` event bus.
3. `get_layout` + `perform_action` (focus-then-act).
4. Anchor-parameterize relative verbs; `watch_for_pattern`.

Workflow gate structure: **design → impl+tests → verify → critic**, each phase with a
reviewer pair-mate blocking on an A+ / ≥98 gate.
