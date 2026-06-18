# Agent Dashboard — a live wall of every CLI agent

Fork-only feature of **"Ghostty (ramon)"** (bundle id `com.mitchellh.ghostty-ramon`).
A floating, foreground-locked **NSPanel** that shows a live, natively-rendered
mini-preview of **every terminal split running a CLI agent** (Claude Code / Codex /
…) across **all tabs and all windows** — built for a wide monitor where you want a
glanceable status wall of your agents off to one side.

Each tile shows the agent's last rows in full ANSI color, highlights the ones that
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
- **`toggle_agent_dashboard`** — a payload-less keybind action (fork-only). Bind it to
  whatever you like; `ctrl+a>d` is the tmux-flavored default. It's also in the command
  palette as **"Toggle Agent Dashboard"**.

> Both keys and the action are fork-only. Keep them in `~/.config/ghostty-ramon/config`
> — an official Ghostty sharing `~/.config/ghostty/config` would error on them.

---

## Using it

- **The panel** floats above terminal windows, stays visible when another app is
  frontmost, and joins all Spaces. Drag it by its background; resize it; its frame and
  open/closed state are remembered across launches (per fork identity's UserDefaults).
  The default first-run frame is the right ~40% × full height of your widest screen.
- **Tiles** are 4:3 cards: a header (`agent badge · title · bell dot · Hide ✕`), the
  live preview, and a footer (`cwd · "needs input"` pill when ringing). They sort
  **bell-first**, then most-recently-seen-as-an-agent, then a stable tie-break.
- **Click a tile** to jump to that real split — it raises the window, selects the tab,
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

- **Config:** `src/config/Config.zig` (`agent-dashboard`, `agent-dashboard-commands`,
  both reusing `RepeatableString`); the action in `src/input/Binding.zig`,
  `src/apprt/action.zig`, `src/input/command.zig`.
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
  (`agentDashboard`, `agentDashboardCommands`, `resolveAgentDashboardCommands`);
  `macos/Ghostty.xcodeproj/project.pbxproj` (iOS-target exclusion of the macOS-only
  files).
- **Tests:** `src/config/Config.zig` (`agent-dashboard config`),
  `src/input/Binding.zig` (`Binding toggle_agent_dashboard`), `src/host/test.zig`
  (minor-4 / `ForegroundPid` round-trip), `src/termio/Client.zig` (`foreground_pid`
  decode), plus the Swift detector/model/sort tests in
  `macos/Tests/AgentDashboard/AgentDashboardTests.swift`.
