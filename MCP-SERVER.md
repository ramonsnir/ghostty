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

> **On a fork INSTALL (the DMG build), this is auto-configured for you.** On first launch
> the app provisions the untracked `~/.config/ghostty-ramon/local` with
> `mcp-listen = 127.0.0.1:8765` + a freshly-generated random `mcp-token` (64 hex chars from
> the system CSPRNG), so the MCP server — and everything built on it (the `ghostty-mcp`
> shim, the Claude agent-state hooks, the dashboard chips, the agent queue/manager) — works
> out of the box with no hand-written token. It never rotates or clobbers a token you
> already set there; to rotate, edit the `mcp-token` line in `local`. The keys below are
> for a from-scratch / repo-clone setup, or to override the auto-provisioned values.

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

## The tools

The server registers **26** tools total: the 12 agent-control tools documented here,
`set_attention` (the Bell Attention promotion tool — see BELL-ATTENTION.md), `get_haiku_usage`
(Agent Manager budget query — see AGENT-MANAGER.md), the queue-supervisor internals (driven by
the Agent Queue sidecar, not meant for hand use — see AGENT-QUEUE.md), and the 4 read-only
**knowledge** tools at the end of this section.

Most tools address a surface by its **stable UUID** from `list_surfaces` (window/tab are
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
- **`get_haiku_usage {hours?}`** — Agent Manager Haiku token/cost usage over the last
  `hours` (default 3), broken down **by feature** (`summarizer` vs `bell-classify`) and **by
  account**, plus a grand total. Read-only; survives GUI restarts (the sidecar logs each
  call to disk). See [AGENT-MANAGER.md](AGENT-MANAGER.md) → *Haiku usage / budget tracking*.

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

**Knowledge / discovery** (read-only; answer "what can I configure / is feature X on?")
- **`get_effective_config {changedOnly?, keys?}`** — the fork's effective configuration:
  the current value of a curated key set (every fork-only key + high-signal upstream keys)
  and whether each equals its built-in default. `changedOnly` (default `true`) returns ONLY
  keys the user actually set; `keys:[…]` restricts to specific keys. Secrets (`mcp-token`,
  `web-monitor-token`) are **redacted** to `<set>`/`` — never echoed. Returns
  `{config:[{key,value,isDefault}]}`.
- **`docs_for_feature {feature?}`** — explain a fork feature: its summary, the config keys
  that control it, the steps to enable it, whether it is currently **enabled**, and any
  **unmet requirements** (computed LIVE from the config with the real precondition predicates
  — e.g. the Agent Manager needs its flag on AND `mcp-listen`+`mcp-token` set AND node
  resolvable). `feature` is one of `agent-dashboard | agent-manager | agent-queue |
  web-monitor | mcp | project-selector | splits | all` (default `all`). Returns
  `{features:[{name,summary,configKeys,enableSteps,requires,enabled,docPath}]}`.
- **`describe_config_key {key}`** — one key's full documentation (the same text
  `ghostty +explain-config` prints), whether it's a **fork-only** key, and — when the app
  config is loaded — its current value. Returns `{key,doc,forkOnly,known,currentValue?}`;
  `known:false` for an unrecognized key.
- **`list_config_keys {filter?, forkOnly?}`** — every config key with a one-line summary
  and fork-only flag. `filter` is a case-insensitive substring on the key name; `forkOnly:
  true` returns only the fork's keys. Returns `{keys:[{key,forkOnly,summary}]}`.

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

---

## Implementation notes (for agents touching the code)

The load-bearing dev-internals for an agent working on this code.

### Built on existing abstractions; zero host changes

Read/respond go through the libghostty C API on the GUI surface
(`ghostty_surface_read_text` viewport, `ghostty_surface_key` real key events,
`ghostty_surface_text`, `ghostty_surface_mouse_scroll`); watch is a Swift event bus over
existing GUI state (`ghosttyBellDidRing`, `process_exited`, a `needsConfirmQuit`
transition); layout calls the existing `TerminalController`/`SplitTree` handlers. The host
(`ghostty-host`) has **no MCP awareness** — the only Zig change is two additive,
default-null config keys it ignores. So enabling/changing MCP needs a **GUI relaunch only,
never a host restart**.

### Copies the web monitor, never depends on it

Standalone module that **COPIES the web monitor, never depends on it** (per the
web-monitor scope rule in CLAUDE.md): the serial-queue + main-hop threading model, the
`keySpecs` NATIVE-keycode input mapping (Return=36, Esc=53, …; the `GHOSTTY_KEY_*` enum
value silently no-ops — see the web-monitor `fix7` notes), the `decideRoute`/`RequestParser`
shape, and the token/Host-header/backoff defenses are all re-homed in
`macos/Sources/Features/MCP/`, not imported from `WebMonitor`.

### Config + per-identity port offset

**Config (fork-only, default null/off):** `mcp-listen` (`addr:port`, empty = disabled;
purely a BIND address) + `mcp-token`. **Unlike `web-monitor-token`, the MCP token should
ALWAYS be set** — it is a SHELL-EXECUTION credential (the tools spawn tabs + run commands),
so the recommended bind is **localhost** (`127.0.0.1:8765`) with a token, NOT an open
tailnet bind. Empty token ⇒ runs OPEN + logs a warning. Keep both in
`~/.config/ghostty-ramon/config`.

**Per-identity port offset (automatic, code not config):** the three fork identities share
one config file (hence one `mcp-listen` port) and would fight over it side-by-side, so
`MCPServer.init` shifts the port by a per-bundle-id offset — Release `+0` (keeps the
configured port), ReleaseLocal `+1`, Debug `+2` (so `:8765` ⇒ 8765 / 8766 / 8767). Pure
overflow-safe helpers `portOffset(forBundleID:)` / `applyPortOffset(_:offset:)` in
`MCPServer.swift`, unit-tested (`MCPServerTests`). The stdio shim defaults to Release
(`8765`); use `GHOSTTY_MCP_URL` to hit a dev build.

### Transport

In-GUI HTTP JSON-RPC 2.0 on its own `NWListener` (`POST /mcp`: `initialize` / `tools/list`
/ `tools/call`) + a standalone stdio shim (`macos/mcp-shim`, `ghostty-mcp`, a dumb
stdin↔HTTP pipe, NOT in `Ghostty.xcodeproj`, built with `swift build`) so
`claude mcp add ghostty -- ghostty-mcp` works. The shim's default URL is
`http://127.0.0.1:8765/mcp`; `GHOSTTY_MCP_URL`/`GHOSTTY_MCP_TOKEN` override.

### Durable registration (the "works on a new laptop" story)

A committed **`.mcp.json`** at the repo root registers the server project-scoped as
`ghostty -- ghostty-mcp` (bare PATH name, **no secret, no clone-specific path**), so any
Claude Code session opened in the repo auto-gets all the tools after a one-time approval +
restart. Two pieces make a secret-less, path-less registration work: (1) the shim is
installed on PATH at **`~/.local/bin/ghostty-mcp`** (release build, alongside
`ghostty-host`; new-machine: `cd macos/mcp-shim && swift build -c release && cp
.build/release/ghostty-mcp ~/.local/bin/`); (2) the shim **falls back to reading
`mcp-token` from `~/.config/ghostty-ramon/local`** when `GHOSTTY_MCP_TOKEN` is unset
(`tokenFromLocalConfig()` in `main.swift` — same canonical secret store the agent-state
hook reads), so the committed JSON needs no token. Dev identities still reachable via
`GHOSTTY_MCP_URL=…:8766/:8767`. Wiring: `.mcp.json` (repo root),
`macos/mcp-shim/Sources/ghostty-mcp/main.swift` (`tokenFromLocalConfig`); see "Connecting
an agent" above.

### The registered tools (26)

The 12 agent-control tools: `list_surfaces`, `read_surface`, `get_layout`, `send_text`,
`send_key`, `scroll`, `wait_for_event`, `watch_for_pattern`, `focus_surface`, `new_tab`,
`close_surface`, `perform_action` (the keybind-action grammar string). All address a surface
by **stable UUID**; `wait_for_event`/`watch_for_pattern` are long-poll (idle-watchdog-exempt,
bounded by a clamped `timeoutMs` 1000–120000). Plus **`set_attention`** (promote a bell to
the sticky attention state — the Bell Attention v2 loud tier; see BELL-ATTENTION.md),
**`get_haiku_usage`** (Agent Manager Haiku budget query — a pure file read, no surface/GUI hop;
see AGENT-MANAGER.md), the Agent Queue supervisor internals (`spawn_split_command`,
`force_close_surface`, `signal_attention`, `take_queue_commands`, `report_queue_status`,
`report_queue_graph`, `move_surface_into_tab`, `set_surface_annotation` — see AGENT-QUEUE.md)
and the 4 knowledge tools below. So the inventory is **12 agent-control + `set_attention` +
`get_haiku_usage` + 8 queue/supervisor + 4 knowledge = 26**, and
`MCPServerTests.toolsListHasAllTools` asserts the total is **26** — keep it in sync when a tool
is added or removed.

`list_surfaces` rows carry `id, title, pwd, window/tab/split position, focused, bell,
exited, atPrompt` plus three OPTIONAL (omitted-when-unknown) fields: `processName` /
`command` (foreground process + full cmdline) and `idleSeconds` (seconds since the screen
last changed).

### Host-gated `processName` / `command` / `idleSeconds`

**`processName`/`command` are HOST-GATED**: under `.client` the GUI mirror can't read the
foreground process (the PTY is in the host), so the host resolves them (libproc/sysctl in
`src/os/proc_info.zig`) and PUSHES an additive `process_info` frame (protocol minor 3,
gated on the conn's negotiated minor in `Server.zig`) — they stay absent until the **host
is restarted** to a minor-3 build, even after a GUI upgrade.

**`idleSeconds` is GUI-only** (stamped in `Client.zig` on each applied `grid_frame`; ships
at the next GUI relaunch, no host restart) and is a coarse heuristic (a TUI that repaints
on a timer never idles; null on backends without a host frame stream).

### Two deliberate v1 limits (documented honestly, don't "fix" by guessing)

(a) **`read_surface` is VIEWPORT-ONLY** — under `pty-host` the GUI mirror is viewport-sized
(real scrollback is on the host), so there is no honest scrollback read; the `mode` param
was REMOVED rather than lie. Reach scrolled-off output via `scroll` + re-read.

(b) **`prompt`/`atPrompt` rides the coarse `needsConfirmQuit` bit, NOT OSC 133** — gated by
`confirm-close-surface` (`false` ⇒ never fires; `always` ⇒ inverted); prefer
`watch_for_pattern` for "agent waiting on me". A real OSC-133 bit needs host plumbing (out
of scope).

Relative layout verbs focus the target first (anchor-parameterizing `SplitTree` is a
follow-up).

### Knowledge tools (read-only config/feature discovery)

The 4 knowledge tools are pure, read-only, and never touch a surface. They exist so an agent
can answer "what can I configure?" / "is feature X on, and how do I enable it?" without the
human scrolling the command palette.

- `get_effective_config` / `docs_for_feature` read the **live** `Ghostty.Config` (main-isolated)
  on a `DispatchQueue.main.sync` hop and return ONLY value types across it (the WebMonitor/MCP
  threading rule). `isDefault` is computed against a fresh `Ghostty.Config.defaultConfig()` (a
  finalized initial-defaults config). `docs_for_feature`'s `enabled`/`requires` come from the
  pure `MCPKnowledge.status(_:pre:)`, whose predicates MIRROR the real runtime gates (e.g.
  `AgentManagerController.sidecarShouldStart`: feature flag on AND `mcp-listen`+`mcp-token` set
  AND node resolvable). Secrets are redacted (`MCPKnowledge.redact`) on every path.
- `describe_config_key` / `list_config_keys` are backed by a NEW read-only **Zig C API** that
  needs no `*Config` (reads the generated `help_strings` + the `Key` enum, so it works headless):
  `ghostty_config_describe_key(name,len)` → `ghostty_config_key_doc_s`,
  `ghostty_config_key_count()`, `ghostty_config_key_at(idx)` → `ghostty_config_key_info_s`.
  Returned `const char*`s are STATIC (do not free). **Fork-only-key detection is the doc's
  leading `(ramon fork` prefix** (matches both `(ramon fork)` and the scoped
  `(ramon fork / Agent Manager)` / `(ramon fork / Bell Attention)` forms), so any new
  fork key is auto-classified.

Wiring: `src/config/CApi.zig` (the 3 exports + `keyDoc`), `include/ghostty.h`
(`ghostty_config_key_doc_s`/`_info_s` + prototypes), `macos/Sources/Features/MCP/MCPKnowledge.swift`
(NEW), `MCPTools.swift` (4 schemas + dispatch), `Ghostty.Config.swift`
(`describeKey`/`allConfigKeys`/`defaultConfig`/`firstLine`). Tests: the knowledge cases in
`MCPServerTests.swift` (tool count now 25) + the `ghostty_config_describe_key`/`_key_count`/
`_key_at` Zig tests in `src/config/CApi.zig`.

### Wiring

`src/config/Config.zig` (`mcp-listen`/`mcp-token` + parse test);
`macos/Sources/Features/MCP/{MCPServer,MCPRPC,MCPTools,MCPInput,MCPLayout,MCPEventBus}.swift`;
`Ghostty.Config.swift` (`mcpListen`/`mcpToken`); `AppDelegate.swift` (start on launch);
`project.pbxproj` (iOS exclusion); `macos/mcp-shim/*`.

The `processName`/`command`/`idleSeconds` feature adds:
- **HOST** — `src/os/proc_info.zig` (pid→name+cmdline resolver, pure `parseProcArgs2`), the
  `process_info` frame + `Conn.negotiated_minor` gate
  (`src/host/{protocol,Server,Session}.zig`, minor bumped to 3).
- **CORE/lib** — `src/termio/Client.zig` (cache + `last_activity_ms` stamp on `grid_frame`
  only + accessors), `src/Surface.zig`
  (`foregroundProcessName`/`foregroundCommand`/`idleMillis` getters; `.exec` resolves
  locally via `proc_info`), `src/apprt/embedded.zig` + `include/ghostty.h`
  (`ghostty_surface_process_name`/`_command`/`_idle_ms` exports).
- **macOS** — `Surface View/SurfaceView_AppKit.swift` (the three computed vars),
  `MCPLayout.swift` (`SurfaceRow` fields + JSON), `MCPTools.swift` (schema doc).

### Tests

`macos/Tests/MCP/MCPServerTests.swift` + the `mcp` Zig config test
(`zig build test -Dtest-filter=mcp`); the `process_info` frame round-trip/bounds + minor-3
tests in `src/host/test.zig` and the `proc_info parseProcArgs2` tests in
`src/os/proc_info.zig` (`zig build test -Dtest-filter=host` / `-Dtest-filter=proc_info`),
plus the `process_info`/`idleMillis` Client tests in `src/termio/Client.zig`.
