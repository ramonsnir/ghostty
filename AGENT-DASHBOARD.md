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
a split-zoom) on click. A per-tile **Hide (eye-slash)** declutters idle sessions; a hidden
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
agent-dashboard-spotlight-seconds = 10         # how long spotlight_dashboard_split holds a tile on top

# Keybind to toggle the panel (also in the command palette: "Toggle Agent Dashboard").
keybind = ctrl+a>d=toggle_agent_dashboard

# Keybind to HIDE the focused split from the dashboard (also in the command
# palette: "Hide Split from Agent Dashboard"). Hide-only — reveal from the
# dashboard's Show button.
keybind = ctrl+a>shift+d=hide_dashboard_split

# Keybind to SPOTLIGHT the focused split at the top of the dashboard for a
# few seconds — the fast way to find "the agent I'm looking at" (also in the
# command palette: "Spotlight Split at Top of Agent Dashboard"). Written `shift+p` because
# `ctrl+a>p` is previous-tab, and shift-keys must spell `shift+` (see CLAUDE.md).
keybind = ctrl+a>shift+p=spotlight_dashboard_split
keybind = ctrl+a>ctrl+shift+p=spotlight_dashboard_split   # more-human alias
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
  activates Ghostty. Read once at launch — relaunch to change. **(NOTE: this pins the
  whole PANEL vs. other windows — a different "pin" from `agent-dashboard-spotlight-seconds`
  / `spotlight_dashboard_split`, which raises ONE tile to the top of the list.)**
- **`agent-dashboard-spotlight-seconds`** — how long (in seconds) the
  `spotlight_dashboard_split` action keeps a split "spotlighted" at the very top of the
  dashboard. Default `10`. `0` means keep it pinned until another split is spotlighted (no
  timeout). Read live from config each time the action fires (no relaunch needed to
  re-read a changed value).
- **`toggle_agent_dashboard`** — a payload-less keybind action (fork-only). Bind it to
  whatever you like; `ctrl+a>d` is the tmux-flavored default. It's also in the command
  palette as **"Toggle Agent Dashboard"**.
- **`hide_dashboard_split`** — a payload-less, **surface-scoped** keybind action
  (fork-only). It **hides the FOCUSED split** from the dashboard — the keyboard equivalent
  of a tile's eye-slash **Hide** button, so you can declutter the dashboard from inside the
  agent's own split without reaching for the panel. **Hide-only / idempotent**: pressing it
  on an already-hidden split keeps it hidden (it does not toggle back), so it never
  re-reveals a split you've hidden — reveal from the dashboard's **Show** button. A hidden
  agent still **auto-unhides the instant it rings / needs input**, exactly as when hidden
  from its tile. Works even if the panel has never been shown this session (the hide is
  recorded + persisted); it does NOT open the panel. Also in the command palette as
  **"Hide Split from Agent Dashboard"**.
- **`spotlight_dashboard_split`** — a payload-less, **surface-scoped** keybind action
  (fork-only). It **spotlights the FOCUSED split** at the very TOP of the dashboard: it
  **unhides** the split (if hidden) and floats its tile above every other tile — including
  queue sections and attention/waiting tiles ("top is top") — for
  `agent-dashboard-spotlight-seconds` seconds, or until you spotlight another split with the same
  action. It's the fast way to answer "which tile is the agent I'm looking at?" **Unlike
  Hide, it OPENS the panel** if it's closed (the point is to *see* the agent). The spotlighted
  tile also gets a distinct up-arrow badge + a strong accent border. **It TOGGLES**: pressing it
  again on the same (already-spotlighted) split dismisses the spotlight immediately, so you don't
  have to wait out the timer (a toggle-off does NOT open/alter the panel). You can also **click
  the up-arrow badge** on the tile to dismiss it. Also in the command palette as **"Spotlight
  Split at Top of Agent Dashboard"**.

> All these keys and actions are fork-only. Keep them in `~/.config/ghostty-ramon/config`
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
  dot · Hide (eye-slash)`), the live preview (showing the agent's **latest rows** — bottom-anchored,
  the top is clipped), and a footer (`cwd · "needs input"` pill when ringing). They sort
  **bell-first**, then most-recently-seen-as-an-agent, then a stable tie-break.
- **Click a row** to jump to that real split — it raises the window, selects the tab,
  **un-zooms** if the split is hidden under a zoom, and gives the standard locate-pane
  highlight flash. The tiles are **read-only**: no inline reply / key forwarding (jump
  to the split to type).
- **Hide (eye-slash)** (hover a tile) hides an idle agent; the hide set persists across launches.
  A **"N hidden"** chip at the bottom opens a popover listing hidden agents
  (`badge · title · Show`) with a **Show all**. A hidden agent that **rings the bell**
  is revealed automatically — an agent asking for input never stays hidden.
- **Hide from the keyboard** — the **`hide_dashboard_split`** action (command palette:
  "Hide Split from Agent Dashboard") hides the **currently focused** split without touching
  the panel, so you can declutter the dashboard from inside the agent you're working in.
  Hide-only (pressing it on an already-hidden split keeps it hidden — reveal from the
  panel's Show button). Same persisted hide set + same auto-unhide-on-bell as the eye-slash
  button.
- **Dismiss a bell from its tile.** When a tile is ringing it shows an amber **🔔
  (`bell.badge.fill`)** glyph in its header — now a **click target**. Clicking it
  acknowledges the bell **and** the promoted "needs you" attention **system-wide**
  without focusing the split: the amber frame, the 🔔 title prefix, the dock badge,
  this tile's mark, and the "needs you" pill all drop everywhere they appear. This is
  the desk-side equivalent of the web monitor's phone clear (same
  `SurfaceView.resetBell` + `resetAttention`), and it only clears GUI state — the raw
  bell can ring again and the Agent Manager re-arms on its next clean classify, so a
  still-live condition re-fires later.
- **Find the split you're looking at.** The tile for the split you're **currently focused
  on** in the terminal gets a **light "you're here" treatment** — a thin accent border and
  a small accent dot in its header — as long as it isn't hidden. It's cosmetic only (it
  never reorders anything), and it updates as you move focus between panes/windows. When a
  glance isn't enough (a big wall of agents), the **`spotlight_dashboard_split`** action (command
  palette: "Spotlight Split at Top of Agent Dashboard") **spotlights the focused split at the very
  top**: it unhides it and floats its tile above everything — queue sections and
  ringing/waiting tiles included ("top is top") — for `agent-dashboard-spotlight-seconds`
  seconds (default 10; `0` = until you spotlight another split). The spotlighted tile shows an up-arrow
  badge + a strong accent border. **Unlike Hide, this opens the panel** if it's closed.
  Spotlighting a second split moves the spotlight to it. Pressing the action **again on the
  same split** dismisses the spotlight early (it toggles), and you can also **click the tile's
  up-arrow badge** to dismiss it — no need to wait out the timer.
- **Adopt… (queue tiles excluded)** — on a tile for a CLI-agent split that is **not** already
  owned by a queue, an **Adopt…** button (disabled, with a tooltip, when no queue is running)
  pulls that human-created split into a running Agent Queue: it opens a sheet that infers the
  work-item key (best-effort Haiku), previews the matching issue title from the queue's backlog
  graph as you type, and on confirm moves the split into the queue's grid tab and tracks it like
  a dispatched item. Full behavior + the latch/keep/claim mechanics live in **AGENT-QUEUE.md
  (→ Adopting a free split)**.
- **Promote to Hero / Demote (queue tiles only)** — a **hero** is a load-bearing queue item that
  competes for *your attention* rather than a machine slot: it lives in its **own dedicated tab**
  (never packed into the grid), is **never auto-closed**, and is counted against a separate
  fleet-wide cap (`agent-queue-hero-max`) instead of the queue's concurrency. On a **queue-owned
  agent tile** the header controls gain a purple **star** button: on a regular tile it reads
  **"Promote to Hero"** and, on click, **ejects the split into its own new tab** and flips it to a
  hero; on a tile that already IS a hero it reads **"Demote"** (a `star.slash`) and flips it back to
  a regular tracked item (the split **stays in its own tab** — demote does not re-pack it into the
  grid). A hero tile carries a **persistent purple `star.fill` glyph** in its header (shown without
  hovering, distinct from the keep 📌 pin and the amber bell) and a **purple tile border** — a
  standing "this is load-bearing" marker that reads apart from the amber bell frame and the accent
  focus/spotlight border. Promotion **never blocks**: it may push you *over* the hero cap; the only
  consequence is that no *new* heroes dispatch until live heroes drain back under. Full accounting
  + the two entry paths + the wire contract live in **AGENT-QUEUE.md (→ Hero agents)** and
  **HERO-AGENTS.md**.

  A hero also gets an **across-tabs tab marker**: a tinted **star** glyph in the tab's accessory
  slot (the slot the reset-zoom button uses — free because a single-terminal hero tab can never be
  zoomed), visible even on non-focused tabs, so you can spot the hero's tab at a glance across a
  window full of tabs.
- **Hero-waiting in the backlog DAG.** In a queue's backlog dependency canvas, a hero item that is
  **stuck on a hero slot** (the fleet-wide `agent-queue-hero-max` is full, including
  `agent-queue-hero-max = 0` which disables hero dispatch) is drawn with a **distinct purple star
  icon** (`star.circle.fill`) and a **purple card border** instead of the routine orange clock, and
  its **hover tooltip lists every gate blocking it** ("Hero slots full", and any additional cap like
  the queue lifetime `maxItems` or concurrency). This is the whole point of the distinct icon: when a
  hero is stuck on a *hero* slot, nobody wastes time bumping `maxItems`. A regular waiting item that
  carries block reasons gets the same tooltip on its clock icon. (Dependency-blocked items are not
  listed — the graph edges already show that.) See **AGENT-QUEUE.md (→ Hero agents / backlog)** for
  the block-reason wire contract.

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
  reports a new state. You can leave a waiting tile up on purpose; **Hide (eye-slash)** is the
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
  top, does NOT auto-unhide, and fires NO Web Push.
  The shell count is read from the live viewport (no hook tells us about background
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

**2. Install the hooks — the easy way (recommended).** Open the **Command Palette**
(cmd+shift+p) and run **"Install Claude Agent Hooks"** (or, if the Agent Queue/Manager
is enabled, just accept the one-time prompt that offers it on launch). This copies the
hook script to `~/.config/ghostty-ramon/claude-hooks/ghostty-agent-state.sh` and merges
the six hook events into `~/.claude/settings.json` for you — safely: it backs up your
existing settings first, merges idempotently (re-running is a no-op), preserves every
hook you already have, and refuses to touch a malformed settings file. After it runs,
**restart your Claude Code sessions** to pick up the hooks.

It maps each Claude Code event to the script with the state as an argument:

| Claude Code event | state passed |
|---|---|
| `UserPromptSubmit` | `working` |
| `PreToolUse` | `working` |
| `SessionStart` | `working` |
| `Notification` | `waiting` |
| `Stop` | `idle` |
| `SessionEnd` | `idle` |

**Manual fallback (if you'd rather wire it by hand).** Copy the script into the fork
config dir, then merge the `hooks` block from `settings-hooks.json` into your
`~/.claude/settings.json`. The source files ship in two places:

- **DMG / colleague install:** bundled at `…/Ghostty (ramon).app/Contents/Resources/claude-hooks/`.
- **Repo clone (developers):** at `example/claude-hooks/` in the checkout.

```sh
# Pick the SRC dir for your install (bundled vs. repo clone):
SRC="/Applications/Ghostty (ramon).app/Contents/Resources/claude-hooks"   # DMG
# SRC="example/claude-hooks"                                              # repo clone

mkdir -p ~/.config/ghostty-ramon/claude-hooks
cp "$SRC/ghostty-agent-state.sh" ~/.config/ghostty-ramon/claude-hooks/
chmod +x ~/.config/ghostty-ramon/claude-hooks/ghostty-agent-state.sh
# then merge $SRC/settings-hooks.json into ~/.claude/settings.json (same six events above)
```

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
  reusing `RepeatableString`, `agent-dashboard-pin` bool, and `agent-dashboard-spotlight-seconds`
  `u32`); the `toggle_agent_dashboard` action in `src/input/Binding.zig`, `src/apprt/action.zig`,
  `src/input/command.zig`.
- **`spotlight_dashboard_split` action (spotlight the focused split at the top; focus highlight):**
  core — `src/input/Binding.zig` (action + surface scope + `Binding spotlight_dashboard_split` test),
  `src/apprt/action.zig` (union + `Key`, appended LAST after `hide_dashboard_split` — union
  order MUST match the `Key` enum), `include/ghostty.h`
  (`GHOSTTY_ACTION_SPOTLIGHT_DASHBOARD_SPLIT`), `src/Surface.zig` (dispatch),
  `src/input/command.zig` ("Spotlight Split at Top of Agent Dashboard" palette entry). macOS —
  `Ghostty.App.swift` `spotlightDashboardSplit` (resolves the focused `SurfaceView`, posts
  `ghosttySpotlightDashboardSplit` with it as `object`) + `recordFocusedSurface` posts
  `ghosttyFocusedSurfaceDidChange`, `GhosttyPackage.swift` (the two `Notification.Name`s),
  `AppDelegate.swift` (`ghosttySpotlightDashboardSplit` observer → lazily creates the controller,
  then `agentDashboard.spotlight(surfaceID:)`), `AgentDashboardController.swift`
  (`spotlight(surfaceID:)` → opens the panel + model `spotlight(_:duration:)`; `subscribeFocus` →
  `model.setFocusedSurface`), `Ghostty.Config.swift` (`agentDashboardSpotlightSeconds`).
  The model (`spotlightedSurfaceID`/`focusedSurfaceID`/`spotlight`/`spotlightedEntry`, spotlight-first `sorted`,
  section-lift), the view (`tile(for:)` + the dedicated top row), and the tile
  (`isFocused`/`isSpotlighted` border + header glyphs) are in the same three
  `AgentDashboard/*.swift` files. Tests: `Binding spotlight_dashboard_split` (Zig) +
  the spotlight/focus cases in `macos/Tests/AgentDashboard/AgentDashboardTests.swift`.
- **Hero splits (Hero Agents; NO keybind action — promote/demote are dashboard buttons):** the
  tile hero visual + Promote/Demote buttons in `AgentPreviewTile.swift`
  (`isHero`/`heroPurple`/`onPromoteToHero`/`onDemoteFromHero`) + `AgentDashboardView.swift`, the
  `promoteToHero`/`demoteFromHero` model methods + the `hero` userInfo in `postNeedsAttention` +
  the `HookSnapshotEntry.queueHero`→`list_surfaces` emit in `AgentDashboardController.swift`, the
  backlog hero-waiting icon/tooltip in `QueueBacklogCanvas.swift` (`QueueBacklogReasons`), and the
  across-tabs tab marker in `TerminalWindow.swift` (`surfaceIsHero` + `HeroAccessoryView`) +
  `TerminalController.swift` (`heroSurfaceIDs`/`syncSurfaceIsHero`). The `queueHero` annotation +
  `SurfaceRow.hero` emit live in `MCP/MCPAnnotation.swift` + `MCP/MCPLayout.swift`; the sidecar
  engine + wire contract are in **HERO-AGENTS.md** / **AGENT-QUEUE.md**. Full mechanism in
  Implementation notes → "Hero splits". Tests: the hero cases in
  `macos/Tests/AgentDashboard/AgentDashboardTests.swift` + `macos/Tests/MCP/MCPAnnotationTests.swift`.
- **`hide_dashboard_split` action (hide focused split from the keyboard; hide-only):** core —
  `src/input/Binding.zig` (action + surface scope + `Binding hide_dashboard_split` test),
  `src/apprt/action.zig` (union + `Key`, in the slot after `goto_last_surface` — the union
  field order MUST match the `Key` enum order), `include/ghostty.h`
  (`GHOSTTY_ACTION_HIDE_DASHBOARD_SPLIT`), `src/Surface.zig` (dispatch),
  `src/input/command.zig` ("Hide Split from Agent Dashboard" palette entry). macOS —
  `Ghostty.App.swift` `hideDashboardSplit` (resolves the focused `SurfaceView` from the
  target, posts `ghosttyHideDashboardSplit` with it as `object`),
  `GhosttyPackage.swift` (the `Notification.Name`), `AppDelegate.swift`
  (`ghosttyHideDashboardSplit` observer → lazily creates the controller, then
  `agentDashboard.hide(surfaceID:)`), `AgentDashboardController.swift`
  (`hide(surfaceID:)` → model `hide(_:)`, the same idempotent hide the eye-slash button
  uses). Tests: `Binding hide_dashboard_split` (Zig) + `hideIsIdempotentAndPersists` in
  `macos/Tests/AgentDashboard/AgentDashboardTests.swift`.
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
- **Tests:** `src/config/Config.zig` (`agent-dashboard config` — now also asserts
  `agent-dashboard-spotlight-seconds`),
  `src/input/Binding.zig` (`Binding toggle_agent_dashboard`, `Binding hide_dashboard_split`,
  `Binding spotlight_dashboard_split`),
  `src/host/test.zig`
  (minor-4 / `ForegroundPid` round-trip), `src/termio/Client.zig` (`foreground_pid`
  decode), plus the Swift detector/model/sort tests + the `AgentDashboardPanelTests`
  pin/window-level tests in
  `macos/Tests/AgentDashboard/AgentDashboardTests.swift` and the hook/agent-state
  pure-helper tests in `macos/Tests/MCP/MCPAgentStateTests.swift`.

---

## Implementation notes (for agents touching the code)

These are the load-bearing internals for an agent working on the Agent Dashboard
code — the dev nuance behind the user-facing behavior above. (The high-level
config/usage and the code map are above; this section is the deep mechanism + the
gotchas, not a recap.)

### Action + config keys, and the pin window-level/activation semantics

- **Action + config (fork-only, default off):** the payload-less keybind action
  `toggle_agent_dashboard` (also a command-palette entry "Toggle Agent Dashboard");
  `agent-dashboard` (master enable) + `agent-dashboard-commands` (exe names that count
  as an agent; comma-split OR repeated, default `claude,codex`; both reuse
  `RepeatableString`) + **`agent-dashboard-pin`** (bool, default false → floating window
  level + activating window when true; wired `Config.zig` → `Ghostty.Config.agentDashboardPin`
  → `AgentDashboardPanel(pinned:)`, which sets `level = pinned ? .floating : .normal` AND
  drops `.nonactivatingPanel` from the style mask when pinned). Keep all in
  `~/.config/ghostty-ramon/config`. Read at launch (relaunch to change).
- **`hide_dashboard_split` (hide the focused split from the keyboard; HIDE-ONLY).** A second
  payload-less keybind action, but **surface-scoped** (NOT app-scoped like
  `toggle_agent_dashboard`) — it acts on the focused split, so it follows the
  `mark_split`/`pull_marked_split` target-resolution pattern, NOT the app-global notify
  pattern. Flow: `Surface.zig` → apprt `.hide_dashboard_split` → `Ghostty.App.hideDashboardSplit`
  resolves the `SurfaceView` from the `GHOSTTY_TARGET_SURFACE` (no-op + `false` on an APP
  target) and posts `.ghosttyHideDashboardSplit` with **the SurfaceView as `object`** (like
  `pullMarkedSplit`); `AppDelegate.ghosttyHideDashboardSplit` reads `surfaceView.id` and calls
  `agentDashboard.hide(surfaceID:)`, which delegates to the model's idempotent `hide(_:)`
  (a no-op when already hidden — the SAME method the eye-slash button calls). It is
  deliberately **hide-only, not a toggle**: clicking/pressing on an already-hidden split keeps
  it hidden rather than re-revealing it (reveal is the explicit `show(_:)` path behind the
  panel's Show button). The model's hide set is keyed by the **surface UUID** (`view.id`, the
  same id the eye-slash button and `entry.id` use), so the keybind and the tile button share
  one persisted set. **The AppDelegate handler lazily creates the controller** (mirrors
  `ghosttyToggleAgentDashboard`) so the hide is recorded + persisted even if the panel has
  never been shown this session — but it does NOT call `show()`, so the panel stays closed.
  **`Key` enum ordering gotcha:** the apprt `Action`
  union field order MUST match the `Action.Key` enum order (a Zig comptime check), and the
  `Key` enum order MUST match `ghostty.h` (`checkGhosttyHEnum`); this action is appended at
  the END of both (after `goto_last_surface`) — don't interleave it.
- **Window-level / activation rationale.** The panel is **normal-level by default**
  (other windows can cover it) with a visible title ("Agent Dashboard") + standard-window
  AX subrole; the fork-only **`agent-dashboard-pin`** key flips it to a **floating window
  level** (native always-on-top). The pin is in-process precisely because an external
  window manager keyed on bundle id (Rectangle Pro's "pin one app to a side") CANNOT
  distinguish the panel from the terminals — they share one bundle id — so its pin manages
  the terminals too; pinning here sidesteps that. The AX subrole stays `.standardWindow`
  even when pinned (a floating subrole is filtered out by most window managers; only the
  window *level* changes). **Pinning ALSO drops `.nonactivatingPanel`** from the style
  mask: the default overlay never activates Ghostty so it never becomes the app's focused
  window, and Rectangle/Rectangle Pro keyboard shortcuts act on "the frontmost app's
  focused window" — so a non-activating pinned panel is UNMOVABLE by Rectangle (Rectangle
  itself manages any window with level < 21, so the floating level 3 is fine; the blocker
  was the non-activating panel never being the focused window). As an activating window it
  can become key/focused on click, so Rectangle can move/snap it while the floating level
  keeps it on top; it STILL never becomes `main` (`canBecomeMain = false` unchanged), so
  "new window inherits from main" is unaffected. Trade-off: clicking a pinned dashboard
  activates Ghostty (fine — clicking a tile jumps into a terminal anyway).
- **⌘V/⌘C/⌘X/⌘A work in the panel's modal text fields (always on).** Clicking into a
  `TextField` in a dashboard SwiftUI modal (e.g. the **Adopt** sheet's issue-key field)
  and pressing **⌘V pasted nothing**. Root cause is NOT activation (the pinned panel is
  an *activating* window) and NOT the menu (the Edit ▸ Paste/Copy/Cut/Select-All items
  are correctly wired to the first-responder `paste:`/`copy:`/`cut:`/`selectAll:`
  selectors in `MainMenu.xib`). It is `AppDelegate.localEventKeyDown` — the app-level
  local keyDown monitor that lets Ghostty keybinds work with no terminal window open.
  When the pinned panel is key there is **no main window** (the panel is
  `canBecomeMain = false`), so that monitor's `guard NSApp.mainWindow == nil` does NOT
  early-return; it then sees ⌘V matches Ghostty's `paste_from_clipboard` binding, calls
  `ghostty_app_key` (pastes into a *terminal* surface), and returns nil — **consuming ⌘V
  before the sheet's field editor ever sees it**. Local monitors run before menu
  key-equivalent processing, so the Edit menu never got a turn. Fix: `localEventKeyDown`
  calls `agentDashboardOwnsKeyWindow()` (walks the key window's `sheetParent`/`parent`
  up to `agentDashboard.window`, since a `.sheet` is a separate attached `NSWindow`) and,
  when true, calls `routeDashboardEditingKey(event)` — which sends the editing selector
  (`cut:`/`copy:`/`paste:`/`selectAll:`) **directly to the key window's first responder**
  (`NSApp.sendAction(sel, to: firstResponder, from: nil)`), NOT via the Edit menu.
  **Important:** just returning the event to defer to the menu's `paste:` only produced a
  BEEP — a SwiftUI-hosted field's menu key-equivalent path doesn't reach the field editor
  — so we route to the responder directly. For paste there's a fallback: if the responder
  doesn't take `paste:`, insert the clipboard string via `NSTextView.insertText` /
  `perform(insertText:)` (typing works, so the input path does). Handled ⇒ consume; else
  fall through. Scoped strictly to the dashboard panel + its sheet, so a ⌘V in a real
  terminal is untouched. (Earlier attempts that FAILED: a panel `performKeyEquivalent`
  override — never ran, the sheet is a separate window; a competing controller-side local
  monitor — the AppDelegate monitor consumes ⌘V first; and a plain `return event` to defer
  to the menu — beeped.) Wiring: `AppDelegate.swift` (`agentDashboardOwnsKeyWindow` +
  `routeDashboardEditingKey` + the `localEventKeyDown` guard).

### Focus highlight + spotlight (find "the agent I'm looking at")

- **Focus highlight (VIEW-only, no config, always on).** The tile for the app-wide
  focused surface gets a light accent border + a small header dot. The single source of
  truth is `Ghostty.App.recordFocusedSurface` (the settled-focus chokepoint that already
  drives `goto_last_surface`); it posts `.ghosttyFocusedSurfaceDidChange` with the surface
  as `object`. The controller's `subscribeFocus` sink calls `model.setFocusedSurface(id)`,
  which stores `focusedSurfaceID` (`@Published`) and does **NOT** rebuild/re-sort — focus
  is not a sort key, so the `@Published` change alone re-renders the tiles, which read
  `entry.id == model.focusedSurfaceID` (passed as the tile's `isFocused`). Because
  `recordFocusedSurface`'s only caller already filters out dashboard **mirror** surfaces
  (see `setNeedsFocusHistoryUpdate`), the highlight never chases a mirror. When focus
  lands on a non-agent split (or none), no tile matches ⇒ no highlight. When the app is
  inactive the focus path doesn't fire, so the highlight sticks on the last-focused tile
  (acceptable).
- **Spotlight (`spotlight_dashboard_split` → `model.spotlight(_:duration:)`).** Surface-scoped
  like `hide_dashboard_split`: `Surface.zig` → apprt `.spotlight_dashboard_split` →
  `Ghostty.App.spotlightDashboardSplit` (no-op + `false` on an APP target) posts
  `.ghosttySpotlightDashboardSplit` with the `SurfaceView`; `AppDelegate` lazily creates the
  controller and calls `spotlight(surfaceID:)`, which reads the PRE-toggle
  `model.spotlightedSurfaceID != id` into `willSpotlight`, **opens the panel first ONLY when
  turning on** (`if willSpotlight, !isShown { show() }`, so the surface is already in `live` when
  it re-sorts — a toggle-off leaves the panel alone), then `model.toggleSpotlight(id, duration:
  agentDashboardSpotlightSeconds)`. **`toggleSpotlight`**: if `id` is already spotlighted →
  `clearSpotlight()` (dismiss early — the same keybind toggles it off without waiting out the
  timer); else `spotlight(id, duration:)`. `spotlight` unhides `id` (shared hide set), sets
  `spotlightedSurfaceID`, bumps a monotonic `spotlightGeneration`, rebuilds (re-sorts), and — when
  `duration > 0` — arms a one-shot `DispatchQueue.main.asyncAfter` that clears the spotlight only
  if `spotlightGeneration` and `spotlightedSurfaceID` still match (so a later spotlight, which bumps
  the generation, silently supersedes the earlier timer). `duration <= 0` ⇒ no timer (spotlight
  until replaced). **`clearSpotlight()`** (also wired to a **click on the tile's up-arrow badge**,
  via the tile's `onDismissSpotlight` → `model.clearSpotlight()`) nils `spotlightedSurfaceID`, bumps
  `spotlightGeneration` (invalidating any pending timer), and rebuilds.
- **"Top is top" (absolute-first sort + section lift).** Two pieces make the spotlighted tile
  sit above **everything**, including the per-queue origin sections: (1) the pure
  `sorted(…, spotlightedID:)` compares `id == spotlightedID` FIRST — above attention, manual order,
  idle/recency — so the spotlighted entry is `entries.first`; (2) since the dashboard renders
  **origin sections** (a queue's tiles live under its header), the model exposes
  `spotlightedEntry` (the spotlighted tile lifted OUT) and the `sections` computed prop EXCLUDES it,
  and the view renders `spotlightedEntry` as a dedicated row at the very top of the `List`
  (above the banner + every `Section`, `moveDisabled`). Rendering it in exactly one place
  (top row **or** its section, never both) is why `sections` filters it. The spotlighted row
  ignores the origin filter too (it's lifted from the unfiltered `entries`), so a spotlight
  always shows even if its origin is filtered out. `spotlightedEntry` is nil if the pinned
  surface isn't a live agent tile (closed / not detected) ⇒ no ghost row.
- **Scroll the new top row into view.** Inserting a row at the top of a `List` does NOT move
  its scroll offset, so a spotlight while scrolled down would land ABOVE the viewport ("appears
  at the top, but out of view — I have to scroll up to see it"). The `List` is wrapped in a
  `ScrollViewReader`; the spotlighted top row carries `.id(spotlighted.id)`, and an
  `onChange(of: model.spotlightedSurfaceID)` does `proxy.scrollTo(newID, anchor: .top)` (deferred
  one runloop via `DispatchQueue.main.async` so the row is laid out first, wrapped in a short
  `withAnimation`). Only a non-nil new id scrolls; expiry (→ nil) doesn't. The top row's id is
  unique because `sections` excludes it, so `scrollTo` never targets a section copy.
- **Two "pin" config keys, deliberately kept apart.** `agent-dashboard-pin` (bool) floats
  the whole PANEL vs. other windows; `agent-dashboard-spotlight-seconds` (u32) is the
  duration `spotlight_dashboard_split` holds ONE tile at the top of the list. Different scope,
  documented as such in both `Config.zig` docs and above.
- **Wiring:** core — `Config.zig` (`agent-dashboard-spotlight-seconds`), `Binding.zig` +
  `apprt/action.zig` + `ghostty.h` + `Surface.zig` + `command.zig` (`spotlight_dashboard_split`);
  macOS — `Ghostty.App.swift` (`spotlightDashboardSplit` + the focus-change post in
  `recordFocusedSurface`), `GhosttyPackage.swift` (`ghosttySpotlightDashboardSplit` +
  `ghosttyFocusedSurfaceDidChange`), `AppDelegate.swift` (observer),
  `Ghostty.Config.swift` (`agentDashboardSpotlightSeconds`),
  `AgentDashboardController.swift` (model `focusedSurfaceID`/`spotlightedSurfaceID`/`spotlightGeneration`
  + `setFocusedSurface`/`spotlight`/`toggleSpotlight`/`clearSpotlight`/`spotlightedEntry`,
  spotlight-first `sorted`, `sections` lift, controller `spotlight(surfaceID:)` [toggle + open-on-on-only]
  + `subscribeFocus`), `AgentPreviewTile.swift` (`isFocused`/`isSpotlighted` border + header glyphs +
  the up-arrow dismiss button `onDismissSpotlight`), `AgentDashboardView.swift` (`tile(for:)` builder
  + the spotlighted top row + `onDismissSpotlight: { model.clearSpotlight() }`). Tests: `Binding
  spotlight_dashboard_split` + `agent-dashboard config` (Zig); the `AgentDashboardSortTests` cases
  (`spotlightSortsAbsoluteFirst`, `spotlightOutranksManualOrder`, `noSpotlightIDLeavesAttentionFirst`)
  + the `AgentDashboardModelTests` cases (`spotlightUnhidesFloatsAndLiftsOutOfSections`,
  `spotlightSupersedesPrevious`, `spotlightedEntryNilWhenSurfaceNotAnAgent`, `setFocusedSurfaceIsViewOnly`,
  `clearSpotlightRemovesIt`, `toggleSpotlightOffOnSameID`) in
  `macos/Tests/AgentDashboard/AgentDashboardTests.swift`. **GUI-only** (the `spotlight_dashboard_split`
  action is a new apprt enum ⇒ a lib/xcframework rebuild, but the host never sees it — no host
  restart / no session loss); GUI relaunch to pick it up.
- **Bell dismiss from the tile (`onDismissBell` → `model.dismissBell(_:)`).** The header's
  amber 🔔 (`bell.badge.fill`) is now a borderless `Button` (was a static `Image`) whose
  action is the tile input `onDismissBell`, wired in `AgentDashboardView.tile(for:)` to
  `model.dismissBell(entry.id)`. `dismissBell` resolves the entry's WEAK `realView`
  (`entries.first { $0.id == id }?.realView`) and calls `SurfaceView.resetBell()` +
  `resetAttention()` on it — the **exact same acknowledge the web monitor's phone
  clear-bell / clear-attention routes do** (`WebMonitorServer` `.clearBell`/`.clearAttention`).
  Because every bell/attention visual (amber frame, 🔔 title prefix, dock badge, this tile's
  mark, the "needs you"/"needs input" pill) derives from the surface's single
  `bell`/`attentionNeeded` `@Published` flags, clearing them drops the signal **system-wide**;
  the dashboard mark clears because the controller observes `\.bell`/`\.attentionNeeded`
  (`surfaceValuesPublisher`) into its `bells`/`attention` dicts that feed `entry.bell`/`.attention`.
  It clears **GUI state only** — the raw bell can ring again and the sidecar re-arms on its next
  clean classify (a still-live condition re-promotes). No-op on an unresolved / nil-`realView`
  tile (its bell wouldn't be showing anyway). The button lives among the other borderless header
  controls (up-arrow / keep-pin / hide), so its own hit-testing intercepts the click ahead of the
  row-level `onTapGesture { jump() }` — clicking 🔔 dismisses without also jumping. Wiring:
  `AgentDashboardController.swift` (`dismissBell(_:)`), `AgentPreviewTile.swift` (`onDismissBell`
  input + the 🔔 `Button`), `AgentDashboardView.swift` (`onDismissBell: { model.dismissBell(entry.id) }`).
  Test: `AgentDashboardModelTests.dismissBellNoOpWhenSurfaceUnresolved` (the nil-`realView` guard;
  the positive path drives a real SurfaceView, exercised via the already-tested
  `resetBell`/`resetAttention`). GUI-only, no Zig/host change — live-deployable.

### Hero splits — tile visual, promote/demote, tab marker, backlog icon (ramon fork / Hero Agents)

The dashboard is where a **hero** (a load-bearing queue item — its own dedicated tab, never
auto-closed, counted against the fleet-wide `agent-queue-hero-max` instead of concurrency) is
surfaced and controlled. The engine + wire contract live in **HERO-AGENTS.md** and
**AGENT-QUEUE.md**; this section is the dashboard-side mechanism only.

- **Hero-ness rides the `queueHero` annotation.** The supervisor stamps `queueHero` (Bool) onto a
  hero surface via `set_surface_annotation` each sweep; the tile reads it as
  `isHero = entry.annotation?.queueHero ?? false`. It is the single source of truth for every hero
  visual below, so the sidecar remains authoritative — the GUI only ever *optimistically* flips it
  and lets the next restamp reconcile.
- **Tile visual (`AgentPreviewTile.swift`).** A hero tile shows a **persistent purple `star.fill`**
  glyph in its header (only on a queue-owned tile — `isQueueOwned && isHero`), shown without
  hovering so a load-bearing hero is obvious. Distinct from the keep 📌 pin (a hero is
  keep-by-default, but keep is a separate control) and the amber bell. The tile also takes a
  **purple border** (`heroPurple = Color.purple`), slotted in `frameColor`/`frameWidth` **below**
  the loud bell (amber, width 3) and the spotlight/focus accent (accent, width 3/2) but **above**
  plain hover — so a ringing/spotlighted hero still shows its louder state, and an idle hero reads
  apart from everything at width 2.
- **Promote / Demote buttons (queue-owned agent tiles only, `isQueueOwned && entry.agent != nil`).**
  A borderless header button: on a non-hero it's a purple `star` labeled **"Promote to Hero"**; on a
  hero it's a secondary `star.slash` labeled **"Demote"**. The action inputs are `onPromoteToHero` /
  `onDemoteFromHero`, wired in `AgentDashboardView.tile(for:)` to
  `model.promoteToHero(id:run:key:)` / `demoteFromHero(id:run:key:)` (run/key read off the tile's
  `annotation.queueName`/`queueKey`). Like the other borderless header controls (🔔 / up-arrow /
  keep-pin / hide), its own hit-testing intercepts the click ahead of the row-level
  `onTapGesture { jump() }`.
- **`model.promoteToHero` (the dedicated-tab eject).** Guards out the `(other)` catch-all / a blank
  run, then **ejects the split into its own new tab GUI-side IMMEDIATELY** —
  `MCPLayout.performAction(uuid:action:"move_split_to_new_tab")`, the SAME machinery the keybind
  uses — so the hero visibly pops out of the grid without waiting for a round-trip (a no-op on an
  already-solitary tab, so a later sidecar re-eject is harmless). It then **optimistically merges**
  `AgentAnnotation(queueHero: true)` onto the stored annotation (so the star + border + tab marker
  flip instantly), rebuilds entries, and posts a `promote` `QueueCommand` (`run`, optional `key`,
  `surfaceUUID`) onto the shared `.ghosttyQueueCommand` FIFO. The sidecar is authoritative: it sets
  the run-level `hero` bit for the two-pool accounting, re-ejects (the no-op), and re-stamps the
  annotation.
- **`model.demoteFromHero` (no re-pack).** Same guard + optimistic
  `AgentAnnotation(queueHero: false)` merge + rebuild, then posts a `demote` `QueueCommand`. There is
  **no move** — demotion does NOT re-pack the split back into a grid (a HERO-AGENTS.md non-goal); the
  split stays in its own tab like any kept split. The sidecar clears the run-level `hero` bit so the
  item re-enters the regular pool for future accounting.
- **Across-tabs tab marker (`TerminalWindow.swift` + `TerminalController.swift`).** A per-tab
  `surfaceIsHero: Bool` on `TerminalWindow` (parallel to `surfaceIsZoomed`) drives a **titlebar
  accessory** (`heroAccessory` → `HeroAccessoryView`, parallel to the reset-zoom accessory) plus an
  in-tab-accessory `heroTabButton` — a tinted **`star.fill`** glyph (systemYellow / yellow, so it
  reads apart from the purple *tile* border and the amber bell title-prefix). Because the accessory's
  visibility is a per-tab bool, the marker shows across **all** tabs, even non-focused ones — that is
  the across-tabs marker. A hero tab is single-terminal and can never be zoomed, so the hero accessory
  and the reset-zoom accessory are mutually exclusive and never collide (they share the accessory
  slot). `TerminalController` keeps a `heroSurfaceIDs` set fed by the async
  `.ghosttyAgentAnnotationDidChange` notification (the annotation is PARTIAL — a `queueHero == nil`
  means "unchanged", so it only acts on an explicit true/false, mirroring `AgentAnnotation.merging`)
  and re-derives `window.surfaceIsHero` from that set ∩ the tab's current surface tree in
  `syncSurfaceIsHero()` — called both on the annotation change and on every surface-tree change (so a
  hero that moved to another tab stops marking the old one), exactly how `surfaceIsZoomed` is
  re-derived from `to.zoomed`.
- **Backlog hero-waiting icon + tooltip (`QueueBacklogCanvas.swift`).** A waiting `NodeCard` gets a
  DISTINCT icon when it's a hero blocked on a hero slot: `blockReasonsByKey` reads the per-item
  `blockReasons` off `model.queueStatuses[run].next[]` (the sidecar carries them), and the pure,
  unit-tested `QueueBacklogReasons` maps the raw `BlockReason` tokens to presentation.
  `isHeroWaiting(_:) = reasons.contains("heroSlots")` → a purple **`star.circle.fill`** (not the
  orange `clock`) + a purple card border + the `heroWaitingHelp` tooltip; a regular waiting item with
  block reasons keeps the clock but gains the `waitingHelp` tooltip. `tooltipLines(_:)` emits ORDERED
  human-readable lines regardless of the sidecar's array order (hero slots → `maxItems` → queue
  concurrency → global concurrency), passing an **unknown future token through verbatim** rather than
  dropping it. Matching by the raw wire string (no parallel Swift enum) keeps the block-reason
  contract single-sourced with the TS `BlockReason` union.
- **Notification routing (`postNeedsAttention`, `WebMonitorPush.swift`).** When a hero surface enters
  `.waiting`, `postNeedsAttention` reads the stored `queueHero` off the annotation and adds
  `AgentStateUserInfoKey.hero` to the `.ghosttyAgentNeedsAttention` userInfo, so the `WebPushManager`
  observer routes to `onHero` (the loud attention tier + a distinct push glyph) instead of
  `onAttention`. Reuses the existing bell/attention + push plumbing — no new delivery mechanism (see
  WEB-MONITOR.md for the push glyph).
- **Wiring:** `AgentPreviewTile.swift` (`isHero`/`heroPurple`, the header `star.fill` glyph, the
  Promote/Demote button + `onPromoteToHero`/`onDemoteFromHero` inputs, the `frameColor`/`frameWidth`
  hero slot), `AgentDashboardView.swift` (`onPromoteToHero`/`onDemoteFromHero` wiring in `tile(for:)`),
  `AgentDashboardController.swift` (`AgentDashboardModel.promoteToHero`/`demoteFromHero`,
  `HookSnapshotEntry.queueHero` → the `list_surfaces` `SurfaceRow.hero` emit, the `hero` userInfo in
  `postNeedsAttention`), `QueueBacklogCanvas.swift` (`blockReasonsByKey` + `NodeCard.blockReasons` +
  `QueueBacklogReasons`), `TerminalWindow.swift` (`surfaceIsHero` + `heroAccessory`/`heroTabButton` +
  `HeroAccessoryView` + `ViewModel.isSurfaceHero`), `TerminalController.swift` (`heroSurfaceIDs` +
  `syncSurfaceIsHero` + `onAgentAnnotationDidChange`). The `queueHero` annotation arg parse + the
  `AgentAnnotation.queueHero` field / `merging` are in `MCPAnnotation.swift`; the `SurfaceRow.hero`
  emit is in `MCPLayout.swift` (both the reconcile-visibility chokepoint — see AGENT-QUEUE.md).
  **GUI-only, no Zig/host change** — live-deployable (GUI relaunch + rebuilt sidecar `dist`). Tests:
  `AgentDashboardTests.swift` (hero promote/demote + `QueueBacklogReasons` icon/tooltip cases) +
  `MCPAnnotationTests.swift` (`queueHero` parse + `merging`).

### Live previews need pty-host (the mirror SurfaceView)

- **Live previews need `pty-host`.** Each tile mounts a read-only **mirror**
  `SurfaceView` (`mirror = true` + the host session id) and lets the existing
  `SurfaceWrapper` render it natively (full color, viewport-only — right for a
  thumbnail), scaled aspect-fit-by-width + bottom-anchored so the latest rows show.
  Without pty-host there's no session to mirror ⇒ metadata-only tiles under a banner.

- **⚠️ `AgentMirrorPreview.geometry` cell-size inputs come from the HOST surface, not
  the mirror (flicker fix).** The scale is the UNIFORM `referenceColumns` (125) scheme —
  a pane wider than 125 cols fills the width (overflow → horizontal scroll), a narrower
  one renders proportionally (`cols/125` of the width) at the same cell size as every
  other tile. **`cellW`/`cellH` MUST be read from the *real* (host) surface**
  (`realSurface.surfaceSize`), the mirror's own `surfaceSize` only as a fallback — the
  SAME source as `cols`/`rows`. The mirror's frame is computed FROM the cell size, and the
  mirror's own `cell_width_px` **jitters ±1px** (e.g. 17↔16) as that frame re-rounds its
  framebuffer onto a sub-pixel boundary, so reading the *mirror's* cell size closed a
  feedback loop that oscillated the scale every frame: a ~160 Hz "the preview keeps
  switching font size" flicker, **display-dependent** (it surfaced after moving the window
  between displays of different scale). The host surface has a fixed real frame, so its
  cell size is stable and breaks the loop. (Shipped bug: `cellW`/`cellH` were once
  mirror-first while `cols`/`rows` were host-first; all four are now host-first. NOTE: a
  fit-to-width rewrite was tried and reverted — the uniform `referenceColumns` scale is
  the intended behavior; the host-sourced cell size is the only change.)

  **The host geometry is also REMEMBERED across frames (`hostGeomBox` + the pure
  `mergeHostGeom`).** When this agent's split is hidden under a **sibling's zoom**, its
  real `SurfaceView` leaves the SwiftUI hierarchy (`TerminalSplitTreeView` renders only
  the zoomed subtree) and `realSurface.surfaceSize` goes **nil** — but the host session's
  grid did NOT change (zoom is GUI-only). Without memory the geometry would read
  `cols=0`/`cellW=0` and fall into the degenerate width-fit branch → that ONE tile renders
  HUGE and flickers (the live symptom). So the tile caches the last VALID host grid
  (`cols/rows/cellW/cellH`) and keeps using it whenever the live read is absent; the cache
  refreshes the instant the split is shown again (`mergeHostGeom` rejects a zero/partial
  read, accepts a real resize).

  **Edge: the dashboard OPENED while a split is already zoom-hidden** — the cache was
  never populated (the real split was never laid out, so `realSurface.surfaceSize` was
  never non-nil). The tile then pulls the grid from the mirror's OWN `.client` stream via
  `resolveGrid` → `ghostty_surface_mirror_grid_size` (NEW C API): the `.client` mirror
  receives the host's real `cols`/`rows` in every `grid_frame` (stored in
  `Client.render_state`), even though the real split isn't on screen. So the fallback chain
  is **cache/host → mirror client-stream grid → mirror frame size**. **Cell SIZE in that
  same host-never-seen case can only come from the mirror's own `cell_width_px`, which
  JITTERS (e.g. 15↔17) via the very frame-feedback the host-sourcing fixed — so it is
  LATCHED: `resolveGrid` records the FIRST non-zero fallback cell size (`hostGeomBox.
  fallbackCellW`/`fallbackCellH`, via the pure `latchedCell`) and holds it, freezing the
  scale (font cell size is constant for a thumbnail's life; a real change re-mounts the tile
  or arrives via the host when the split is shown).** Without the latch, cols/rows were
  stable but `cellW` oscillated → the tile still flickered (the live repro: 1577 geom
  re-renders in 8s → 0 after the latch). The C call is
  GATED on `cols == 0`, so it only runs in this rare case (and reads under the render mutex,
  so it can't tear against the read thread). NEW C API: `ghostty_surface_mirror_grid_size`
  → `ghostty_surface_mirror_grid_s {columns, rows, valid}` (`src/apprt/embedded.zig` +
  `include/ghostty.h`), backed by `Surface.mirrorSourceGrid` → `Client.mirrorSourceGrid`
  (returns the named `Client.MirrorGrid`, null for non-mirror / pre-first-frame). **This is
  a lib/xcframework rebuild (new C export) — GUI-only; the host never instantiates a
  `.client` mirror, so `ghostty-host` is NOT rebuilt/reloaded (no session loss).** Tests:
  `AgentMirrorGeometryTests` (`mergeHostGeomRemembersThroughZoomHidden`, `latchedCellHoldsFirstNonZero`,
  `uniformScaleAcrossSplitsOfDifferentWidths`,
  `framesFullHostGridAndPinsBottom`/`fallsBackToContainerWhenGridUnknown`/
  `zeroBackingDoesNotDivideByZero`).

### Live previews auto-reconnect (never give up while the split is alive)

- **The problem this fixes.** Each preview is a read-only `.client` **mirror** to
  `ghostty-host` with a **single-shot** connection and **NO retry** in the Zig client
  (`src/termio/Client.zig` `connectAndAttach`): on ANY socket blip — EOF, a read error, a
  decode error, or a host-pushed `child_exited` — the read thread calls `markMirrorEnded()`
  and **exits** (`Client.zig` `ReadThread.threadMainPosix`). The tile keyed the mirror
  SurfaceView on `.id(sessionID)`, so a mirror that died on a **still-alive** session was
  **never rebuilt** — the preview froze on its last frame (or, if it died before the first
  frame, an empty default surface) until a **full GUI restart**. Over a long session the
  transient blips accumulate and previews die one-by-one — the "restart to recover them"
  symptom. **Nothing wrong with the real terminal** (a separate attach connection), which is
  the key tell: only the mirror's socket dropped.

- **The fix (GUI-only, self-healing).** `AgentMirrorPreview` polls
  `surfaceView.processExited` in its existing identity-tied `.task` loop — true for a mirror
  the moment `markMirrorEnded` synthesizes a `child_exited` (`Surface.childExited` sets
  `child_exited` for a mirror and RETURNS without closing; `ghostty_surface_process_exited`
  reads exactly that bit, so **no new C accessor was needed**). On that edge it calls
  `onEnded`; the tile (`AgentPreviewTile`) then **recreates the mirror SurfaceView** — the
  tile id became `"\(sessionID)-\(mirrorGeneration)"` and `handleMirrorEnded` bumps
  `mirrorGeneration` after a backoff, tearing down the dead `.client` connection and mounting
  a fresh one.

- **Backoff — quick burst, then a steady minute, NEVER give up.** `mirrorReconnectDelay(attempt:)`
  is a quick exponential burst **1, 2, 4, 8, 16, 30s** for the first `quickReconnectAttempts` (6),
  then a **steady `steadyReconnectDelay` (60s) cadence FOREVER** (pure/static, unit-tested). It no
  longer STOPS after a cap — the old `maxMirrorReconnects`/`mirrorFailed` give-up flag (which
  required a manual Refresh to recover) is GONE, so a preview self-heals on its own without a
  click, even for a socket that drops repeatedly for minutes. A fresh connection that stays up for
  `mirrorStableSeconds` (15) fires `onStable`, resetting the attempt count so a LATER transient
  drop starts a fresh quick burst. The small top-trailing button (`mirrorRefreshButton`) is now a
  **"reconnect now"** convenience, not a rescue: it appears only while a reconnect is pending in
  the slow phase (`showReconnectNow` = `mirrorReconnectPending && attempts >= quickReconnectAttempts`,
  i.e. waits ≥30s) to let you skip the wait; a click (`retryMirror`) restarts the quick burst
  immediately. A monotonic `mirrorReconnectToken` invalidates a scheduled timer when the user
  forces a retry (or the mirror goes stable) so a stale timer can't double-bump the generation.
  **Reconnect is gated on the REAL split still being alive** (`entry.realView?.processExited ==
  false`): if the real process ALSO exited the session is genuinely gone (the detector drops the
  tile shortly), so we do nothing and let it vanish — no churn on a dead endpoint, and this gate is
  what BOUNDS the otherwise-infinite retry.

- **Scope.** PURE SWIFT in `AgentPreviewTile.swift` — no Zig, no C, no host change; deployable
  live (GUI relaunch, no session loss). Wiring: `AgentPreviewTile.swift`
  (`mirrorGeneration`/`mirrorAttempts`/`mirrorReconnectPending`/`mirrorReconnectToken` state,
  `mirrorReconnectDelay`/`handleMirrorEnded`/`handleMirrorStable`/`retryMirror`/`showReconnectNow`,
  `mirrorRefreshButton`, the `"\(sessionID)-\(mirrorGeneration)"` id, and `AgentMirrorPreview`'s
  `onEnded`/`onStable` closures + the `.task` `processExited` poll). Tests: `AgentMirrorReconnectTests`
  (`backoffQuickBurstThenSteadyMinute`, `backoffSettlesAtSteadyIntervalForever`,
  `backoffNeverNegativeOrZero`). NOTE the host's 978
  `libxev … invalid state in submission queue` bursts are a SEPARATE per-session-loop issue
  (see PTYHOST.md) — they'd freeze the REAL terminal too, so they are not the preview-death
  cause; this reconnect self-heals every transient drop regardless of source.

### Smart bottom-anchor — skip empty rows AND the info-less footer

- **Smart bottom-anchor (fork-only, always on, no config, PURE-SWIFT / ZERO Zig).** A
  bottom-anchored thumbnail of a partially-filled screen (a fresh agent chat, a TUI not
  yet at the bottom) wastes the preview on empty trailing rows; worse, an idle Claude
  Code/Codex agent ALWAYS pins its input box + mode/status lines at the bottom, so the
  meaningful content is pushed off-view. So the preview shifts the bottom-anchored mirror
  DOWN by the number of trailing rows to drop — blanks PLUS a detected footer — so the
  LAST row of CONTENT lands at the bottom (the dropped rows fall below the clip). It does
  NOT collapse interior repeated/blank lines (the native Metal mirror renders the host
  grid as-is — no seam to inject a "… N more …" marker; that would need a separate
  self-rendered text preview that loses color/TUI fidelity — deliberately not done).

- **Row source is the existing `cachedVisibleContents`, NOT a new core getter.** Under
  pty-host the GUI mirror's `dumpText` is row-accurate (exactly one text line per grid
  row, no soft-wrap, blank rows preserved, every row newline-terminated), so
  `realSurface.cachedVisibleContents.get()` split on `\n` (drop one trailing "") IS the
  viewport grid. Keeping this pure-Swift (no Zig core getter) keeps it GUI-only + tunable
  with no host-linking change. `read_text`'s general path is NOT usable for a row count
  (it uses `unwrap=true` + trims trailing blanks) — but the **mirror** path (the only one
  the dashboard hits) does neither, which is what makes this work.

- **Footer detection is CONSERVATIVE — never hides content** (the load-bearing design
  constraint, found by reading real screens). `AgentMirrorPreview.chromeTrailingSkip(rows:)`
  (pure, tested) peels trailing chrome and stops at the first row with REAL content, so
  nothing meaningful is hidden. It peels, from the bottom: (1) up to `maxStatusLines` (3)
  status/help lines — plain text with NO box-drawing (e.g. `⏵⏵ auto mode on…`, `↑↓ select
  · x stop workflow…`); the no-box-drawing test is what distinguishes an outside-the-box
  status line from a filled box-interior row (which carries `│`); then (2) it REQUIRES a
  horizontal-rule row (`─`×≥12 — a box's bottom border; ASCII `-` does NOT count, so
  markdown rules are safe) or it bails to blanks-only; then (3) it peels the box's
  structural rows upward — borders (incl. a border carrying embedded status text, e.g. the
  claude-pool line), empty interior cells (`│   │`), the empty `❯` prompt, and blank gap —
  stopping at the first real-content row. This handles BOTH the input box AND content
  boxes: the `/workflows` viewer's filled phase rows are real content (kept), while its
  empty interior tail + bottom border + help line are dropped; a permission prompt keeps
  its question/options and only loses the bottom border.

- **GOTCHA — the NO-BREAK SPACE U+00A0.** Claude Code pads the prompt line with a
  **NO-BREAK SPACE U+00A0**, not a normal space — `❯\u{00A0}…` — and the rule rows are
  real U+2500. So `isEmptyInteriorRow`/`isBlankRow` MUST test the **Unicode whitespace
  property** (covers U+00A0), NOT just U+0020/U+0009 — a codepoint-only check reads the
  NBSP as content, the interior never looks empty, and `chromeTrailingSkip` returns 0 for
  every footer.

- **Footer shapes + whole-gap absorption.** The per-tile refresh runs off a `.task` poll
  tied to view identity (not a `Timer.publish`, which restarts on every re-render).
  Handles both Claude Code footer shapes (full-width `───`/`❯`/`───` rules and rounded
  `╭─╮`/`│ │`/`╰─╯` boxes). When a footer IS found it also drops the ENTIRE blank gap
  above it (not just one separator) — a near-empty session has content at the TOP, a big
  blank gap, then the footer pinned at the bottom, so absorbing the whole gap lands the
  last real content row at the bottom instead of a blank row mid-gap.

- **The offset + the poll.** The offset is a pure, tested
  `AgentMirrorPreview.bottomAnchorOffset(skipRows:…)` (clamped to `rows-1` so an all-blank
  screen keeps one row visible), refreshed by `refreshSkipRows()` on a light ~0.8s
  per-tile `.task` poll (live frames render off the Metal path, not via `@Published`, so a
  poll — not an observer — drives it). Limitation: a placeholder prompt (`❯ Try "…"`)
  reads as non-empty interior → the box is shown (conservative); most active agents show a
  bare `❯`. **GUI-only, no Zig/host change, GUI relaunch to pick up.**
  - Wiring: `AgentDashboard/AgentPreviewTile.swift` (`chromeTrailingSkip` +
    `isRuleRow`/`isEmptyInteriorRow`/`isBlankRow` + `bottomAnchorOffset` + `refreshSkipRows`
    + `.offset` + timer).
  - Tests: `macos/Tests/AgentDashboard/AgentDashboardTests.swift` (`ChromeTrailingSkipTests`
    — grounded in real captured footers — + `BottomAnchorOffsetTests`).

### Detection is HOST-GATED on a new protocol frame

- **Detection is HOST-GATED on a NEW protocol frame.** Under `.client` the GUI mirror
  can't read the foreground process, so the host pushes the raw foreground pid via an
  additive `foreground_pid` frame (**protocol minor bumped 3→4**); the GUI walks that
  pid's process subtree locally with libproc and path-component-matches the configured
  commands. **Detection silently finds nothing until `ghostty-host` is on a minor-4
  build** — a GUI upgrade alone is not enough (and a stale xcframework can leave the app
  on minor 3). Gotchas: `proc_listchildpids` is unreliable on macOS — use
  `proc_listpids`+`proc_pidinfo` parent links; a versioned exe basename isn't the command
  name, hence path-component match.

### Threading / cost, and core wiring

- **Threading / cost:** the detector is a ~2s off-main `.utility` poll (pure
  `matchAgent`/`resolve` behind an injectable `ProcEnumerator`); paused while the panel is
  hidden/occluded, and mirror renderers pause via `ghostty_surface_set_occlusion` — a
  hidden panel costs ~nothing. The model is `@MainActor`; the detector hops to main only
  to snapshot value types `(uuid, foregroundPID)` and to publish results. Hide set
  persists in the per-bundle-id UserDefaults; a ringing agent is never left hidden.
  GUI-only changes relaunch the GUI; the `foreground_pid` frame is a HOST change (host
  rebuild + LaunchAgent reload — see `CLAUDE.md`).
- Wiring: core — `src/config/Config.zig` (`agent-dashboard`/`-commands`),
  `src/input/{Binding,command}.zig` + `src/apprt/action.zig` (action), the minor-4 frame
  in `src/host/{protocol,Server,Session}.zig` + `src/termio/Client.zig` +
  `ghostty_surface_foreground_pid` (`include/ghostty.h`, `src/apprt/embedded.zig`,
  `src/Surface.zig`); macOS — `macos/Sources/Features/AgentDashboard/*` (Controller +
  Model + Panel + View + PreviewTile + Detector), `AppDelegate.swift`,
  `Ghostty.Config.swift`, `Ghostty.Surface.swift` (`foregroundPID`), `project.pbxproj`
  (iOS exclusion).
- Tests: `macos/Tests/AgentDashboard/AgentDashboardTests.swift`; Zig
  `agent-dashboard config` + `Binding toggle_agent_dashboard` + the minor-4/`ForegroundPid`
  round-trip in `src/host/test.zig` + the `foreground_pid` Client decode.

### Per-tile agent state via Claude Code hooks

- **Per-tile agent state via Claude Code hooks (fork-only, GUI + hooks ONLY, ZERO
  Zig/host change).** Each tile can show an authoritative `working`/`waiting`/`idle` chip
  (+ `lastTool`/`lastPrompt`) driven by Claude Code's lifecycle hooks, NOT a heuristic. A
  tiny shell hook (`example/claude-hooks/ghostty-agent-state.sh`, wired by
  `example/claude-hooks/settings-hooks.json` into `~/.claude/settings.json`) fires on
  `UserPromptSubmit`/`PreToolUse`/`SessionStart` (→ `working`), `Notification` (→
  `waiting`), `Stop`/`SessionEnd` (→ `idle`) and **POSTs `{tty,state,prompt?,tool?,message?}`
  to the EXISTING in-GUI MCP server** at `POST /agent-state` (`X-Ghostty-Token`,
  `127.0.0.1:8765`; `GHOSTTY_MCP_PORT` overrides for the 8766/8767 dev offsets). The hook
  is fire-and-forget (backgrounded `curl --max-time 2`, never blocks/fails the agent),
  debounces only the chatty `PreToolUse`/`working` with a ~1s per-tty stamp file, and
  reads the token from `$GHOSTTY_MCP_TOKEN` or `~/.config/ghostty-ramon/local`.

- **tty correlation is the load-bearing trick (the ppid walk):** the hook reports the
  surface's controlling tty — but Claude Code spawns hooks (like Bash tool calls)
  **DETACHED from the controlling terminal**, so the hook's OWN tty is `??`/none. The
  script therefore **walks up its ppid chain** (`ps -o tty= -p <pid>`, then `ps -o ppid=`)
  and takes the nearest ancestor with a real tty — the `claude` process itself runs on the
  surface's tty (e.g. `ttys030`). (Reading the hook's OWN tty does NOT work — it's
  `??`/none because the hook is spawned detached; the ppid walk is required.)

- **The MCP `/agent-state` handler (tty → surface UUID).** The MCP handler
  (`MCPServer.handleAgentState`) resolves it to a surface UUID by reading each surface's
  **host-pushed minor-4 `foregroundPID`** (the SAME pid the dashboard detector already
  consumes — no new frame) and mapping that pid → controlling tty via libproc
  `proc_pidinfo(PROC_PIDTBSDINFO).pbi_e_tdev` → `devname()`, normalizing both sides
  (`/dev/ttysNNN`/`ttysNNN`/`sNNN` → `ttysNNN`). A no-match returns 200 (the hook is
  fire-and-forget; a momentary miss isn't an error). The handler posts
  `.ghosttyAgentStateDidChange`.

- **Model application (`applyAgentState`).** `AgentDashboardModel.applyAgentState` is
  **hook-authoritative + alongside** (any surface that ever POSTed joins `hookBacked` and
  thereafter MUTES the `idleSeconds` heuristic), app-side **coalesces** an unchanged state
  (the second `PreToolUse` debounce), auto-unhides + sorts-first on `.waiting` (mirrors the
  bell auto-unhide), and on the working/idle→`.waiting` EDGE posts
  `.ghosttyAgentNeedsAttention`, which `WebPushManager` observes to fire a Web Push (an
  `⏳ ` push, reusing the bell fan-out via the shared `enqueuePush`; the per-surface ~3s
  debounce is keyed per-kind so a bell never swallows the waiting push). **No TTL** — the
  ~2s detector poll removes dead agents; a missed `Stop` is an accepted cosmetic
  stale-`working`.

- **Persistence via AgentStateStore (keyed by session id, not surface UUID).** Persisted
  across GUI restart (hooks only POST on transitions, so a relaunched GUI would otherwise
  show blank chips until the agent next acts): the model write-throughs each state to an
  `AgentStateStore` (UserDefaults) keyed by the **stable host session id** — NOT the
  surface UUID, which is freshly minted each launch — and `rebuild(live:)` rehydrates it
  onto the new UUID by session id (silent restore — no push / no waiting-edge re-fire; the
  next live hook takes over). Records age-prune (14d / 256-cap, timestamp touched for live
  sessions). Caveat: a HOST restart resets the session-id counter, so a stale record could
  briefly hydrate a reused id with wrong state until the next hook self-corrects (host
  restarts are rare + lose all sessions anyway). `prune` / `AgentStateStore` /
  `UserDefaultsAgentStateStore` are unit-tested. Claude-Code-only (Codex tiles stay
  preview-only).

- **Shared symbols + wiring.** Pinned shared symbols (`AgentState`/`AgentStatePayload`/the
  two `Notification.Name`s/`AgentStateUserInfoKey`) live in
  `macos/Sources/Features/AgentDashboard/AgentStateBridge.swift`.
  - Wiring: hooks — `example/claude-hooks/*`; MCP —
    `macos/Sources/Features/MCP/MCPAgentState.swift` (pure parser + tty normalize/match +
    the injectable `TTYResolver` proc seam) + `MCPServer.swift` (`/agent-state` route +
    `handleAgentState`); dashboard — `AgentStateBridge.swift` +
    `AgentDashboardController.swift` (model state + observer + `postNeedsAttention` +
    drop-stale) + `AgentPreviewTile.swift` (state chip + waiting border/pill + tool/prompt);
    push — `macos/Sources/Features/WebMonitor/WebMonitorPush.swift` (attention observer →
    `onAttention`/`enqueuePush`); `project.pbxproj` (iOS exclusion of the 2 new source files).
  - Tests: `macos/Tests/MCP/MCPAgentStateTests.swift` (parse / normalizeTTY / ttyMatches /
    resolveSurface w/ injected resolver / decideRoute `/agent-state`) + the `applyAgentState`
    model tests in `macos/Tests/AgentDashboard/AgentDashboardTests.swift`.
  - **GUI relaunch only** to pick it up (no host restart); the user copies the hook to
    `~/.config/ghostty-ramon/claude-hooks/` + merges the settings block (see the user-facing
    setup section above).
