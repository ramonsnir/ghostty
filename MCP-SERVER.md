# MCP server — let an agent watch & drive Ghostty

Fork-only feature of **"Ghostty (ramon)"** (bundle id `com.mitchellh.ghostty-ramon`).
A single GUI-embedded **MCP server** *inside the running app* exposes the live terminal
to an orchestrating agent (Claude Code / Codex). The agent can: **reorganize** splits &
tabs, **open tabs / run commands**, **read** a surface's screen, **send input** (notably
approving CLI-agent prompts), and **watch** sessions for bell / process-exit / prompt
events and respond.

It speaks MCP two ways: an **in-GUI HTTP JSON-RPC** endpoint (`POST /mcp`) and a tiny
**stdio shim** (`ghostty-mcp`) that pipes stdin/stdout to it so `claude mcp add` works.

**OFF by default.** One app, one rebuild/relaunch — no second process. **Zero host
changes** (it builds on the libghostty C API + macOS layout handlers), so enabling it
needs only a GUI relaunch, never a `ghostty-host` restart.

---

## Quick start — the config

Put this in `~/.config/ghostty-ramon/config` (fork-only file; the official Ghostty never
sees it, so it won't error on the unknown keys). **Relaunch** the app afterward — config is
read at launch.

```ini
# MCP server (fork-only). Empty/unset listen => disabled.
mcp-listen = 127.0.0.1:8765                 # BIND address — localhost recommended
mcp-token  = <48-hex secret>                # `openssl rand -hex 24`
```

- **`mcp-listen`** — `addr:port` to bind. **Localhost (`127.0.0.1`)** is recommended: the
  agent (a local Claude Code / Codex, via the stdio shim) runs on this same Mac. It's a
  *bind address*, not an allowlist. Empty/unset ⇒ the server is disabled.
  - **Per-identity port offset (automatic).** All three fork identities share
    `~/.config/ghostty-ramon/config`, so they read the *same* `mcp-listen` port and would
    otherwise fight over it side-by-side. The server shifts the port by a per-bundle-id
    offset so they coexist: **Release** (`…ghostty-ramon`) keeps the configured port,
    **ReleaseLocal** (`.local`) uses **+1**, **Debug** (`.debug`) uses **+2**. So
    `mcp-listen = 127.0.0.1:8765` ⇒ Release `8765`, ReleaseLocal `8766`, Debug `8767`. The
    stdio shim's default URL targets `8765` (Release); point it at a dev build with
    `GHOSTTY_MCP_URL=http://127.0.0.1:8766/mcp` (or `:8767`). No config needed — it's in
    `MCPServer.init` (`portOffset`/`applyPortOffset`, overflow-safe, unit-tested).
- **`mcp-token`** — **always set it.** Unlike the web monitor (which may run open on a
  tailnet), the MCP token is a **shell-execution credential** — the tools can spawn tabs
  and run arbitrary commands. It's enforced on every `/mcp` request (`X-Ghostty-Token`
  header, constant-time compare). Empty ⇒ the server runs OPEN and logs a warning; only do
  that on a bind you fully trust. Rotate (+ relaunch) if it leaks.

> **Why localhost, not the tailnet?** The web monitor is a human-in-the-loop phone tool
> and can run open behind a Tailscale ACL. The MCP server executes shell commands on an
> agent's behalf, so it stays local + token-gated. If you genuinely need it off-box, bind
> the Tailscale IP **with** a token — never open.

---

## Connecting an agent

A Claude Code session opened anywhere in this repo gets the `ghostty` MCP server
**automatically** — the committed **`.mcp.json`** at the repo root registers it (Claude
Code prompts once to approve a project-scoped server, then remembers). No per-machine
`claude mcp add`, no secret in the registration. Two things make that work:

1. **The shim is on `PATH`** as `ghostty-mcp` (installed to `~/.local/bin/ghostty-mcp` —
   see *New-machine setup* below). `.mcp.json` invokes the bare name, not a clone-specific
   path.
2. **The token needs no env var.** When `GHOSTTY_MCP_TOKEN` is unset the shim reads the
   `mcp-token` line straight from `~/.config/ghostty-ramon/local` (the fork's canonical
   secret store), so the committed `.mcp.json` carries no secret yet still authenticates.

After a fresh clone + setup, just **restart Claude Code** in the repo and the tools load.

```jsonc
// .mcp.json (committed at the repo root) — no secret, no absolute path
{ "mcpServers": { "ghostty": { "command": "ghostty-mcp", "args": [], "env": {} } } }
```

**Manual / one-off registration** (e.g. outside the repo, or to target a dev build):

```sh
claude mcp add ghostty -- ghostty-mcp
```

- `GHOSTTY_MCP_URL` overrides the endpoint (default `http://127.0.0.1:8765/mcp`). Point it
  at a dev identity with `GHOSTTY_MCP_URL=http://127.0.0.1:8766/mcp` (ReleaseLocal) or
  `:8767` (Debug).
- `GHOSTTY_MCP_TOKEN` overrides the token (sent as `X-Ghostty-Token`); if unset it falls
  back to `mcp-token` in `~/.config/ghostty-ramon/local`.

A remote MCP client can also hit `POST /mcp` directly with the `X-Ghostty-Token` header,
no shim.

### New-machine setup (install the shim once)

The shim is a tiny standalone SPM package. Build a release binary and drop it on `PATH`
(alongside `ghostty-host`):

```sh
cd macos/mcp-shim && swift build -c release
cp .build/release/ghostty-mcp ~/.local/bin/ghostty-mcp     # ~/.local/bin must be on PATH
```

That + an `mcp-token` in `~/.config/ghostty-ramon/local` is all the per-machine state the
committed `.mcp.json` needs. (The shim changes rarely — rebuild only if `main.swift` does.)

---

## The tools (12)

Every tool addresses a surface by its **stable UUID** from `list_surfaces` (window/tab are
positional encounter-order indices, **not** durable — only `id` is).

**Discover / read**
- **`list_surfaces`** — all live panes: `id`, title, pwd, window/tab/split position, focus,
  bell, exited, `atPrompt` (coarse, see caveat), and three optional fields (omitted when
  unknown): `processName` / `command` (the foreground process + full command line, e.g.
  `claude` / `claude --resume`) and `idleSeconds` (seconds since the screen last changed).
  See Known limits for `processName`/`command`'s host-restart requirement and the
  `idleSeconds` TUI nuance.
- **`read_surface {id}`** — text of the **visible screen** (viewport). *Scrollback/history
  is not exposed* — see Known limits. To see output that scrolled off, `scroll` it into
  view, then read again.
- **`get_layout`** — the window → tab → split-tree of every window.

**Respond** (real key events, not paste)
- **`send_text {id, text, submit?}`** — types text; `submit:true` appends a real Return.
- **`send_key {id, key}`** — one named key: `enter`, `escape`, `tab`, `backspace`, arrows,
  `y`, `n`, `space`, `ctrl-c`, `ctrl-u`. Approve a CLI prompt with `send_key y` + `send_key
  enter`, interrupt with `ctrl-c`.
- **`scroll {id, dy}`** — signed wheel ticks (positive = back/up), clamped ±30.

**Watch**
- **`wait_for_event {filter?, timeoutMs?}`** — blocks until a `bell`, `exited`, or `prompt`
  event fires (or timeout, clamped 1000–120000 ms). Returns the event or `{event:null}`.
  Prefer `bell`/`exited` (precise); `prompt` is the coarse heuristic.
- **`watch_for_pattern {id, regex, timeoutMs?}`** — polls a surface's viewport text for a
  regex. The fallback for TUI agents that don't emit shell-prompt events.

**Control / layout**
- **`focus_surface {id}`** — raise window, select tab, focus the pane (un-zooms if needed).
- **`new_tab {id?, cwd?, command?}`** — open a tab; optional `cwd` (absolute, no `~`),
  optional first-input `command` (runs in the live shell, doesn't replace it), optional
  source `id` to inherit context.
- **`close_surface {id}`** — request close (honors close-confirmation).
- **`perform_action {id, action}`** — run any keybind-action grammar string against the
  surface: `new_split:right`, `flip_split:horizontal`, `toggle_split_direction:vertical`,
  `swap_split:next`, `move_split_to_new_tab`, `merge_tabs:next_horizontal`, `mark_split`,
  `pull_marked_split:right`, `resize_split:down,2`, `goto_last_surface`, … Relative verbs
  act relative to the given surface (v1 focuses it first).

**The intended loop:** `wait_for_event` (or `watch_for_pattern`) → `read_surface` to see
what's being asked → `send_key`/`send_text` to respond → repeat; plus `perform_action` /
`new_tab` / `focus_surface` to arrange the workspace.

---

## Security model (read once)

- **No TLS** — keep the bind local (or tailnet-only). The token is the credential.
- **The token gates every `/mcp` request** (`X-Ghostty-Token`, constant-time compare). It
  is a **shell-execution credential** — treat it like an SSH key.
- **Second route — `POST /agent-state`.** The same listener also serves a token-gated
  `POST /agent-state`, the ingest endpoint for the Claude Code per-tile-state hooks (see
  AGENT-DASHBOARD.md → "Per-tile agent state (Claude Code hooks)"). It rides the **exact
  same** Host-header guard, token gate (same `X-Ghostty-Token`, constant-time compare), and
  backoff as `/mcp`, so anyone holding the MCP token — or any caller, when the server runs
  open — can also POST agent-state events. It does NOT spawn shells; it only updates a
  dashboard tile's displayed state. Still, it is a real second authenticated surface on the
  same token, so treat the token accordingly.
- **Defense in depth** (copied from the web monitor, independent of the token): a
  Host-header allowlist (DNS-rebinding guard), a per-peer failed-token backoff (when a
  token is set), and per-connection bounds (idle watchdog + absolute deadline +
  connection cap). The long-poll `wait_for_event`/`watch_for_pattern` connections are
  exempt from the idle watchdog but bounded by the clamped `timeoutMs`.

---

## Architecture (how it reuses, but doesn't extend, the web monitor)

The MCP server is a **standalone GUI module** (`macos/Sources/Features/MCP/`). It *copies*
the web monitor's proven scaffolding — the serial-queue + main-thread-hop threading model,
the `keySpecs` native-keycode input mapping, the `decideRoute`/`RequestParser` shape, the
token/Host-header/backoff defenses — but builds directly on Ghostty's existing
abstractions and **does not depend on the web monitor** (per the scope rule in CLAUDE.md).

- **Read / respond** go through the **libghostty C API** on the GUI surface:
  `ghostty_surface_read_text` (viewport), `ghostty_surface_key` (real key events, native
  macOS keycodes), `ghostty_surface_text`, `ghostty_surface_mouse_scroll`. No host client.
- **Watch** is a small Swift **event bus** fed by existing GUI surface state: the
  `ghosttyBellDidRing` notification (bell), `process_exited` (exit), and a `needsConfirmQuit`
  transition (the coarse `prompt`). `wait_for_event` parks the HTTP connection and resolves
  it single-shot off the serial queue.
- **Layout** calls the existing `TerminalController` / `SplitTree` handlers.
- **Transport:** an in-GUI `NWListener` on a dedicated serial queue answers JSON-RPC 2.0
  (`initialize`, `tools/list`, `tools/call`); the **`ghostty-mcp` stdio shim** is a dumb
  stdin↔HTTP pipe so stdio-only clients work.

Because all of this is GUI-side, **the host (`ghostty-host`) has zero MCP awareness** — the
only Zig change is two additive, default-null config keys it ignores.

---

## Known limits

- **`read_surface` is viewport-only.** Under the fork's `pty-host` backend the GUI holds
  only a viewport-sized mirror (real scrollback lives on the host), so there is no honest
  full-history read — only the current screen. Use `scroll` + re-read to reach scrolled-off
  output. (A true host-backed scrollback read would need a new host frame — out of scope.)
- **`prompt` / `atPrompt` is a coarse heuristic, not OSC 133.** It's derived from Ghostty's
  close-confirmation state and is gated by `confirm-close-surface`: with the default
  (`true`) it roughly means "a child is idle at a prompt"; with `false` the `prompt` event
  **never** fires and `atPrompt` is always true; with `always` it's inverted. For
  "is the agent waiting on me?", **`watch_for_pattern` on the prompt text is more reliable**
  than the `prompt` event today.
- **`processName` / `command` are HOST-GATED and need a host restart.** Under `pty-host`
  the GUI mirror cannot read the foreground process locally (the PTY lives in the host), so
  the host resolves the name + command line and pushes them in an additive `process_info`
  frame (protocol minor 3). A GUI upgrade alone is not enough — the host advertises its minor
  at connect time, so until `ghostty-host` is restarted to a minor-3 build the fields stay
  **absent** (omitted). Nothing breaks in the meantime (old host never sends the frame; old
  GUI never receives an unknown tag).
- **`idleSeconds` is a coarse activity heuristic.** It's seconds since the surface's screen
  last changed (the arrival of a render frame): ~0 while a TUI repaints/works, growing while
  it waits for input. A TUI that repaints on a timer (a clock, a spinner) never goes idle, so
  treat it as a hint. GUI-only (ships at the next GUI relaunch, no host restart needed); null
  on backends without a host frame stream.
- **Relative layout verbs focus the target first** (v1). Anchor-parameterizing the
  `SplitTree` transforms so they don't disturb focus is a follow-up.
- **No live config reload** — changing `mcp-listen` / `mcp-token` needs a GUI relaunch.

---

## Status

Implemented via a gated design→impl→verify→critic workflow. Covered by a Swift unit suite
(`GhosttyTests/MCPServerTests`) + a Zig config-parse test; the macOS app builds clean and a
**live Debug end-to-end run passed** (handshake, `tools/list`, 401-without-token,
list/read, type+submit+read-back, split via `perform_action`, cwd-aware `new_tab` with an
initial command, `send_key`, and `wait_for_event` parking/timeout). Merged on `ramon-fork`
(not pushed).

## Where the code lives

| Piece | File |
|---|---|
| Server (NWListener, routing, JSON-RPC) | `macos/Sources/Features/MCP/MCPServer.swift` |
| JSON-RPC envelopes / tool result shapes | `macos/Sources/Features/MCP/MCPRPC.swift` |
| Tool registry + schemas + dispatch | `macos/Sources/Features/MCP/MCPTools.swift` |
| Input injection (`keySpecs`, key/text/scroll) | `macos/Sources/Features/MCP/MCPInput.swift` |
| Surface enumeration + layout + un-zoom | `macos/Sources/Features/MCP/MCPLayout.swift` |
| Watch event bus (`wait_for_event`/pattern) | `macos/Sources/Features/MCP/MCPEventBus.swift` |
| stdio↔HTTP shim (separate SPM package) | `macos/mcp-shim/Sources/ghostty-mcp/main.swift` |
| Auto-registration (project-scoped) | `.mcp.json` (repo root) |
| Unit tests | `macos/Tests/MCP/MCPServerTests.swift` |
| Config keys (`[:0]`-terminated, C-gettable) | `src/config/Config.zig` (`mcp-listen` / `mcp-token`) |
| macOS config getters | `macos/Sources/Ghostty/Ghostty.Config.swift` (`mcpListen` / `mcpToken`) |
| Start on launch | `macos/Sources/App/macOS/AppDelegate.swift` |
| Full architecture / wiring notes | **`CLAUDE.md`** ("MCP server" entry) |
