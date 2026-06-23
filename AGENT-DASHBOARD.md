# Agent Dashboard — a live wall of every CLI agent

Fork-only feature of **"Ghostty (ramon)"** (bundle id `com.mitchellh.ghostty-ramon`).
A persistent sidebar **NSPanel** that shows a live, natively-rendered
preview of **every terminal split running a CLI agent** (Claude Code / Codex /
…) across **all tabs and all windows** — built for a wide monitor where you want a
glanceable status wall of your agents off to one side. Agents are stacked as
**full-width rows**, each showing the **latest rows** of that split.

The panel is **not** always-on-top — it sits at normal window level, so other
windows can be raised in front of it. It carries a real, visible **window title
("Agent Dashboard")** and a standard-window accessibility subrole, so an external
window manager (Rectangle Pro etc.) can target it by title.

Each row shows the agent's last rows in full ANSI color, highlights the ones that
**rang the bell** (needs-your-input) with the amber bell border, and **jumps you to
that split** (raising its window, selecting its tab, un-zooming if it's hidden under
a split-zoom) on click. A per-tile **Hide ✕** declutters idle sessions; a hidden
agent **auto-unhides the instant it rings**.

**OFF by default.** macOS-only, GUI-only — one rebuild/relaunch, no second process,
no host restart to toggle. Live previews need the fork's **pty-host** backend (see
below); without it the panel degrades to metadata-only tiles.

---

## Quick start — the config

Put this in `~/.config/ghostty-ramon/config` (fork-only file; the official Ghostty
never sees it, so it won't error on the unknown keys). **Relaunch** the app
afterward — config is read at launch.

```ini
# Agent Dashboard (fork-only). Default off.
agent-dashboard          = true
agent-dashboard-commands = claude,codex        # exe names that count as "an agent"
agent-dashboard-pin      = true                # float the panel above other windows

# Keybind to toggle the panel (also in the command palette: "Toggle Agent Dashboard").
keybind = ctrl+a>d=toggle_agent_dashboard
```

- **`agent-dashboard`** — master enable. `true` ⇒ the panel is created at launch and
  shown per its remembered visibility (shown the very first run). `false` ⇒ dormant
  until the `toggle_agent_dashboard` action lazily creates it.
- **`agent-dashboard-commands`** — the executable names that mark a split as running
  an agent. Comma-separated **or** repeated; defaults to `claude,codex` when unset.
  Matching is by **path component** of the foreground process's executable, so a
  versioned/wrapped install whose basename isn't the command name still matches (e.g.
  Claude's exe `…/share/claude/versions/2.1.181` matches because `claude` is a path
  component). Read once at launch — relaunch to change.
- **`agent-dashboard-pin`** — `true` floats the panel above other windows (native
  always-on-top); `false` (default) keeps it at normal level so other windows can cover
  it. Use this instead of an external window manager's "pin": Rectangle Pro and friends
  match windows by **bundle id**, and the dashboard shares the fork's bundle id with the
  terminal windows, so their pin can't target the dashboard alone — it ends up managing
  the terminals too. Pinning in-process avoids that. When pinned, the panel also becomes
  an **activating window** (it's a non-activating overlay otherwise) so Rectangle's
  move/snap shortcuts can still reposition it — those act on the frontmost app's focused
  window, which a non-activating panel never becomes. So you keep it on top *and* can
  still move it with Rectangle; the only side effect is that clicking the dashboard
  activates Ghostty. Read once at launch — relaunch to change.
- **`toggle_agent_dashboard`** — a payload-less keybind action (fork-only). Bind it to
  whatever you like; `ctrl+a>d` is the tmux-flavored default. It's also in the command
  palette as **"Toggle Agent Dashboard"**.

> Both keys and the action are fork-only. Keep them in `~/.config/ghostty-ramon/config`
> — an official Ghostty sharing `~/.config/ghostty/config` would error on them.

---

## Using it

- **The panel** sits at normal window level (NOT always-on-top, so other windows can
  cover it), stays visible when another app is frontmost, and joins all Spaces. It has a
  visible title bar ("Agent Dashboard") and a standard-window subrole, so a window manager
  (Rectangle Pro) can target it by title. Drag it by its title bar / background; resize it;
  its frame and open/closed state are remembered across launches (per fork identity's
  UserDefaults). The default first-run frame is the right ~40% × full height of your widest
  screen.
- **Rows** are full-width cards stacked vertically: a header (`agent badge · title · bell
  dot · Hide ✕`), the live preview (showing the agent's **latest rows** — bottom-anchored,
  the top is clipped), and a footer (`cwd · "needs input"` pill when ringing). They sort
  **bell-first**, then most-recently-seen-as-an-agent, then a stable tie-break.
- **Click a row** to jump to that real split — it raises the window, selects the tab,
  **un-zooms** if the split is hidden under a zoom, and gives the standard locate-pane
  highlight flash. The tiles are **read-only**: no inline reply / key forwarding (jump
  to the split to type).
- **Hide ✕** (hover a tile) hides an idle agent; the hide set persists across launches.
  A **"N hidden"** chip at the bottom opens a popover listing hidden agents
  (`badge · title · Show`) with a **Show all**. A hidden agent that **rings the bell**
  is revealed automatically — an agent asking for input never stays hidden.

### Degraded states (never a blank panel)

- **No pty-host** → tiles render metadata-only (title/cwd, no live preview) under a
  yellow "Live previews require pty-host" banner.
- **No terminals open** → "No terminals open."
- **Terminals open, no agents detected** → "No CLI agents running. Watching for: … ·
  polling every ~2s."
- **All agents hidden** → a prompt pointing at the "N hidden" chip.

---

## Per-tile agent state (Claude Code hooks — optional)

The dashboard can show **what each Claude Code agent is doing right now** — a small
state chip per tile — when you wire up the included Claude Code **hooks**. This is
**optional and additive**: without it, tiles still show the live preview and the
bell border; with it, every tile gains an authoritative state chip and a waiting
agent floats to the top, auto-unhides, and (if you've armed Web Push) pings your
phone.

### What the per-tile state means

A hook-backed tile shows one of three states next to its badge:

- **working** (neutral/blue) — the agent is actively running: you submitted a prompt,
  it's about to call a tool (`PreToolUse`), or the session just started. When working,
  the tile may also show the **last tool** it ran (e.g. `Bash`) and a truncated copy
  of your **last prompt** as a subtitle.
- **waiting** (amber **"waiting ⚠" chip** + **"needs input" pill**) — the agent is
  **asking you for input or approval** (a Claude Code `Notification`). This is the "an
  agent needs me" signal: the tile shows the waiting chip and pill, **sorts to the top**,
  **auto-unhides** if you'd hidden it, and fires a **Web Push** if you've armed the web
  monitor's Notify toggle. **Unlike a real bell, waiting does NOT clear when you focus
  the split** — it is a *status*, not a transient alert, so it persists until the agent
  reports a new state. You can leave a waiting tile up on purpose; **Hide ✕** is the
  manual dismiss. (Deliberately, the tile's amber **frame + bell icon** are driven by the
  **real terminal bell ONLY** — and clear on focus, like any bell — so the two signals
  stay visually distinct: bell = "something pinged, now cleared by looking"; waiting =
  "still blocked on you".) (Web Push needs the HTTPS / `tailscale serve` setup described
  in WEB-MONITOR.md — a plain-HTTP-over-Tailscale-IP monitor can't push.) The waiting
  push uses its OWN per-surface ~3s debounce, keyed separately from the bell's, so a bell
  on the same surface within ~3s never swallows the `⏳` waiting push. The waiting
  auto-unhide lands once, on entering waiting, so you *can* re-hide a still-waiting tile
  (a bell, which re-rings, cannot).
- **⚙ background** (neutral/blue **"⚙ background" chip** + quiet **"N shell running"**
  pill) — the agent reported `waiting`, BUT Claude Code's footer still shows one or more
  **background shells running** (a `run_in_background` / Ctrl-B command). It is then
  waiting on its OWN work, not on you, so the tile is **DEMOTED**: it does NOT sort to the
  top, does NOT auto-unhide, and fires NO Web Push — and no premature suggested reply is
  shown. The shell count is read from the live viewport (no hook tells us about background
  shells). When the shell finishes it normally wakes the agent (Claude Code injects a
  task-notification → the agent works, then genuinely waits), and that fresh transition
  re-arms the real **waiting** chip + push. So "Set up DMG…" running a ~20-min background
  build no longer reads as "needs you".
- **idle** (dim) — the agent finished its turn (`Stop`) or the session ended
  (`SessionEnd`).

A tile only shows a state chip once that agent has reported at least one hook event;
agents you haven't wired hooks for (or non-Claude agents like Codex) keep the
preview-only behavior. Once a tile is **hook-backed**, the hook state is
authoritative — it overrides any heuristic idle/working guess.

**Statuses survive a GUI restart.** The hooks only POST on *transitions*, so a
relaunched GUI would otherwise show blank chips until each agent next acts. Instead the
last-known state is persisted (keyed by the **host session id**, which is stable across
a GUI relaunch — the surface's identity is not) and restored onto the tile when the GUI
reattaches. The exception is a **host** restart: it ends every session and resets their
ids, so a chip may briefly show a stale state until the next hook event corrects it.

### How it works (one sentence)

Each Claude Code lifecycle event runs a tiny script that POSTs `{tty, state, …}` to
the fork's in-GUI **MCP server**; the MCP server resolves your terminal's **tty** to
the matching dashboard tile (using the same host-pushed foreground pid the dashboard
already tracks) and updates that tile's state. It is **GUI + hooks only** — no host
restart, no extra background process; the POST just rides the MCP server you may
already be running.

### Setup

**1. You need the MCP server running.** The hooks POST to the fork's MCP server on
`127.0.0.1`. Make sure `~/.config/ghostty-ramon/config` (and/or the untracked `local`
file for the token) has:

```ini
mcp-listen = 127.0.0.1:8765
mcp-token  = <your-token>        # recommended; put real secrets in ~/.config/ghostty-ramon/local
```

(See `MCP-SERVER.md` for the MCP server itself. The hook is inert if the server is
down — the POST just fails silently under a 2-second timeout.) The `mcp-token` is a
shell-execution credential and the hook reads it from `~/.config/ghostty-ramon/local`
(or `$GHOSTTY_MCP_TOKEN`), so `chmod 600 ~/.config/ghostty-ramon/local` to keep it
out of other local users' reach.

**2. Install the hook script.** Copy it into the fork config dir and make it
executable:

```sh
mkdir -p ~/.config/ghostty-ramon/claude-hooks
cp example/claude-hooks/ghostty-agent-state.sh ~/.config/ghostty-ramon/claude-hooks/
chmod +x ~/.config/ghostty-ramon/claude-hooks/ghostty-agent-state.sh
```

**3. Wire the hooks into Claude Code.** Merge the `hooks` block from
`example/claude-hooks/settings-hooks.json` into your `~/.claude/settings.json`. It
maps each Claude Code event to the script with the state as an argument:

| Claude Code event | state passed |
|---|---|
| `UserPromptSubmit` | `working` |
| `PreToolUse` | `working` |
| `SessionStart` | `working` |
| `Notification` | `waiting` |
| `Stop` | `idle` |
| `SessionEnd` | `idle` |

That's it — start (or restart) a Claude Code session in a Ghostty tab and its tile
gains a live state chip.

### Token & dev-build notes

- The script reads the MCP token from `$GHOSTTY_MCP_TOKEN` if set, else greps
  `mcp-token` from `~/.config/ghostty-ramon/local` (the per-machine secret file). If
  neither is present it POSTs without a token (fine when the MCP server runs open).
- It hits port **8765** (the Release MCP default). For a dev build (ReleaseLocal/Debug,
  which the MCP per-identity offset shifts to 8766/8767), set `GHOSTTY_MCP_PORT` in the
  hook's environment.
- The `PreToolUse` event is the chatty one (it fires on every tool call), so the
  script debounces it per-terminal with a ~1s stamp file in a private dir (`$TMPDIR`,
  or `~/.cache/ghostty-ramon` if `$TMPDIR` is unset — never world-writable `/tmp`).
  The debounce actually keys on the `working` arg, so it covers all three `working`
  events (`UserPromptSubmit`, `PreToolUse`, `SessionStart`) — the script can't tell
  them apart. In the common turn order this only swallows the redundant `PreToolUse`;
  the rare reverse edge (a `SessionStart` <1s before a prompt) can drop a prompt
  subtitle, which is accepted. The `waiting`/`idle` events (`Notification`/`Stop`/
  `SessionEnd`) are rare/meaningful and never debounced.

### Limitations (honest)

- **Claude Code only.** The hook events are Claude Code's; Codex and other agents
  keep the preview-only tile (still detected, still previewed, just no state chip).
- **No TTL / no liveness ping.** State changes only on a hook event. If a session is
  killed mid-turn without firing `Stop`, the tile can sit on a stale `working` until
  the ~2s detector poll notices the process is gone and removes the tile entirely — a
  cosmetic miss, not a leak.
- **One tab per tty.** Correlation is by controlling tty, which is unique per terminal
  split, so this is exact in practice.

---

## Requirements & limits

- **Live color previews require the fork's `pty-host` backend** (`pty-host = …` in the
  config — see `CLAUDE.md` / `.claude/docs/ptyhost.md`). Each tile mounts a read-only
  **mirror** `SurfaceView` that renders the host's session natively (full color,
  viewport-only — exactly right for a thumbnail). Without pty-host there is no host
  session id to mirror, so the panel falls back to metadata-only tiles.
- **Agent detection needs a recent host.** Under `.client` the GUI mirror can't read
  the foreground process (the PTY lives in the host), so the host pushes the foreground
  pid over an additive `foreground_pid` protocol frame (**protocol minor 4**). The GUI
  then walks that pid's process subtree locally via libproc. A GUI upgrade alone is not
  enough — the **`ghostty-host` must be running a minor-4 build**, or detection silently
  finds nothing. (See the LaunchAgent deploy procedure in `CLAUDE.md`.)
- **Detection is a ~2s off-main poll**, paused while the panel is hidden/occluded so a
  hidden panel costs near-zero. Mirror renderers are likewise paused when the panel is
  hidden (`ghostty_surface_set_occlusion`).

---

## Where it lives (code map)

- **Config:** `src/config/Config.zig` (`agent-dashboard`, `agent-dashboard-commands`
  reusing `RepeatableString`, and `agent-dashboard-pin` bool); the action in
  `src/input/Binding.zig`, `src/apprt/action.zig`, `src/input/command.zig`.
- **Foreground-pid plumbing (the minor-4 frame):** `src/host/protocol.zig`
  (`foreground_pid` FrameType + `ForegroundPid` struct, `PROTOCOL_VERSION_MINOR = 4`),
  `src/host/Session.zig` (resolve-on-change + reattach seed), `src/host/Server.zig`
  (`foregroundPidAllowed` minor gate + push), `src/termio/Client.zig` (decode + cache,
  `getProcessInfo(.foreground_pid)` under `.client`), exported via
  `ghostty_surface_foreground_pid` (`include/ghostty.h`, `src/apprt/embedded.zig`,
  `src/Surface.zig`) → `Ghostty.Surface.swift` `foregroundPID`.
- **macOS UI:** `macos/Sources/Features/AgentDashboard/` —
  `AgentDashboardController.swift` (singleton owned by `AppDelegate`; panel/model/
  detector lifecycle, observers, occlusion, jump-target walk),
  `AgentDashboardModel` (the single source of truth: entries, hide set, bell/agent
  reconciliation, pure sort), `AgentDashboardPanel.swift` (the floating NSPanel),
  `AgentDashboardView.swift` (grid + degraded states + hidden popover),
  `AgentPreviewTile.swift` (tile + `AgentMirrorPreview` mirror-render),
  `AgentDetector.swift` (off-main libproc poller + pure `matchAgent`/`resolve`).
- **Wiring:** `macos/Sources/App/macOS/AppDelegate.swift` (create-on-launch + toggle
  notification + teardown); `macos/Sources/Ghostty/Ghostty.Config.swift`
  (`agentDashboard`, `agentDashboardCommands`, `resolveAgentDashboardCommands`,
  `agentDashboardPin`); the panel level is set in `AgentDashboardPanel(pinned:)`,
  passed `ghostty.config.agentDashboardPin` by the controller;
  `macos/Ghostty.xcodeproj/project.pbxproj` (iOS-target exclusion of the macOS-only
  files).
- **Per-tile agent state (Claude Code hooks):** the hook script + settings snippet in
  `example/claude-hooks/{ghostty-agent-state.sh,settings-hooks.json}`; the shared
  symbols (`AgentState`, `AgentStatePayload`, the two `Notification.Name`s) in
  `macos/Sources/Features/AgentDashboard/AgentStateBridge.swift`; the MCP `/agent-state`
  route + tty→surface resolver in `macos/Sources/Features/MCP/MCPServer.swift` +
  `MCPAgentState.swift`; the model's `agentStates`/`hookBacked`/`applyAgentState` +
  observer + `postNeedsAttention` in `AgentDashboardController.swift`; the state chip in
  `AgentPreviewTile.swift`; and the Web Push on waiting in
  `macos/Sources/Features/WebMonitor/WebMonitorPush.swift` (attention observer →
  `onAttention`/`enqueuePush`). **GUI + hooks only — no Zig/host change** (it reuses the
  existing minor-4 foreground-pid).
- **Tests:** `src/config/Config.zig` (`agent-dashboard config`),
  `src/input/Binding.zig` (`Binding toggle_agent_dashboard`), `src/host/test.zig`
  (minor-4 / `ForegroundPid` round-trip), `src/termio/Client.zig` (`foreground_pid`
  decode), plus the Swift detector/model/sort tests + the `AgentDashboardPanelTests`
  pin/window-level tests in
  `macos/Tests/AgentDashboard/AgentDashboardTests.swift` and the hook/agent-state
  pure-helper tests in `macos/Tests/MCP/MCPAgentStateTests.swift`.
