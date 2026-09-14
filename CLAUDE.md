# Ghostty — ramon fork

Personal macOS fork of Ghostty that adds split/tab-reorganization commands and
runs side-by-side with an official Ghostty. Single working branch: **`ramon-fork`**.
Upstream conventions still apply (`AGENTS.md`, `macos/AGENTS.md`); this file only
covers what's specific to the fork.

> **PTY-host (emulation-on-host) work** is now **merged into `ramon-fork`** (it
> formerly lived on a `ptyhost/phase-2b` branch, since merged and deleted — the
> code came in via `3eb0ba26a Merge branch 'ptyhost/phase-2b' into ramon-fork`).
> If you are resuming or touching that work (the `.client` termio backend,
> `ghostty-host`, reattach-across-restart), read the top-level **`PTYHOST.md`**
> first — it has the architecture decisions, invariants/gotchas, and open items.
> (`.claude/` is gitignored / local-only; feature docs live at the repo root.)

## How this file is organized

This `CLAUDE.md` is the always-in-context **index**: the BLOCKING rules, the safety
rules, a one-entry-per-feature **Feature map**, the fork-only config-key index, and the
redeploy reference. **Full behavior, gotchas, wiring, and tests for each feature live in
its dedicated doc at the repo root — follow the pointer before touching the feature.**
The docs:

| Doc | Covers |
|---|---|
| `FORK-ACTIONS.md` | fork keybind actions + command-palette entries |
| `BELL-ATTENTION.md` | bell/attention two-tier model, focused variant, diagnostics, persistence, split/zoom visibility |
| `WEB-MONITOR.md` | phone/laptop HTTP monitor (xterm.js color stream, input, scroll, maximize, push) |
| `MCP-SERVER.md` | MCP server + shim, agent-control + knowledge tools |
| `AGENT-DASHBOARD.md` | live agent-preview sidebar panel |
| `AGENT-MANAGER.md` | Haiku status summarizer sidecar, warm-base, usage tracking, rate-limit watchdog, orphan guard |
| `AGENT-QUEUE.md` | queue supervisor user guide: grid/packing, adopt, schedules, health/backlog, multi-host |
| `AGENT-QUEUE-INTERNALS.md` / `-UI.md` / `-OPS.md` | Agent Queue impl notes — part 1 engine/dispatch/config/adopt/params; part 2 layout/dashboard/live-controls; part 3 throttling/run-identity/restart/multi-host |
| `HERO-AGENTS.md` | hero agents (attention-as-scarce-resource, two-pool model) |
| `CLOUD-HOSTS-DESIGN.md` / `CLOUD-HOSTS-IMPL-PLAN.md` | remote `ghostty-host` over SSH: design + build plan + Phase-4/6 + hardening |
| `CLOUD-QUEUE-BALANCING.md` | per-queue multi-host load balancing |
| `PTYHOST.md` | pty-host architecture, session lifecycle, write-pool fix, launchd LaunchAgent deploy |
| `HOST-HANDOFF.md` | session-preserving `ghostty-host` upgrades: supervisor+worker, the handoff sequence, fd/child ownership contract, triggers (SIGHUP + exec-path self-check), the switchover deploy |
| `SUSPEND-RESUME-DESIGN.md` | PROPOSED — suspend idle Claude agent splits (kill child to reclaim RAM, keep frozen placeholder, Resume via `claude-pool --resume <id>`); Claude-first, Codex postponed |
| `FORK-FIXES.md` | standalone robustness / upstream-bug fixes (`CachedValue` crash) |
| `FORK-DISTRIBUTION.md` | fork identity (bundle id / icon / update feed), colleague DMG release, `ForkSetup` first-launch (supervisor LaunchAgent + two-identity host reload) |
| `FORK-DEV.md` | the macOS build / test / install iteration lifecycle |
| `SHARING.md` / `ONBOARDING.md` | user-facing colleague guide + onboarding cheat sheet |
| `DESKTOP-MONITOR-DESIGN.md` | SUPERSEDED — historical |

## 📝 Documentation discipline (BLOCKING)

**Every code change MUST update the relevant Markdown docs in the same change — this is
not optional.** When you touch a feature, update its feature doc at the repo root (e.g.
`AGENT-QUEUE.md`, `AGENT-DASHBOARD.md`, `AGENT-MANAGER.md`, `BELL-ATTENTION.md`,
`WEB-MONITOR.md`, `MCP-SERVER.md`, `PTYHOST.md`, `FORK-ACTIONS.md`, `FORK-DISTRIBUTION.md`,
`FORK-DEV.md`, `FORK-FIXES.md`) AND the matching one-entry summary in this `CLAUDE.md`'s
**Feature map** (config keys, redeploy note, doc pointer) — plus the **Fork-only config
keys** index below if you added/removed a key — so the docs never drift from the code. A
new config key / keybind action / template knob / MCP tool / protocol field is incomplete
until it is documented (user-facing behavior in the feature doc, the load-bearing facts +
file wiring in that doc's "Implementation notes" section, and the summary here). Treat a
docs update as part of the definition of done for the work — land it in the same commit,
not "later." **Keep the summary here to a few lines; the depth belongs in the feature doc.**

## 🔒 No real-world names or concrete personal examples (BLOCKING)

**Never put real company, customer, client, employer, person, or private-project
names — or any concrete identifier tied to a real-world entity — into tracked
content.** This covers code, comments, docs, tests, fixtures, sample data,
illustrative examples, the tracked `example/` configs, and commit messages, and it
applies to placeholder/sample values exactly as much as to functional code. Always
use neutral, obviously-fake placeholders instead (`Acme`, `Example`, `foo`/`bar`,
`project-a` / `~/git/your-project`, `user@example.com`, an `EX-`-style key prefix).
When a real value genuinely must exist for the fork to run on a given machine, keep
it ONLY in untracked / machine-local files (e.g. `~/.config/ghostty-ramon/local` or
the live `~/.config/...` configs), never in anything that gets committed. If you
notice an existing real-world name slip through, treat removing it as in-scope.

## 🛑 Worktree discipline (BLOCKING)

> 🛑 **STOP — READ THIS BEFORE YOUR FIRST `Edit`/`Write`.** Claude keeps
> violating this rule: it reads the task, jumps straight to editing files on
> the main tree's `ramon-fork` checkout, and only *then* commits there. **That
> is wrong every single time, even for a "one-line" / "trivial" change, even
> when you're "already on `ramon-fork`", even when the user says "just commit
> it".** Being on `ramon-fork` is NOT permission to edit it — it is the exact
> state the worktree rule exists to protect. The very fact that you're tempted
> to skip the worktree "because it's small" is the violation. The installed
> Release fork builds from this checkout and hosts the live Claude Code
> session; a dirty/half-edited `ramon-fork` here can break the next rebuild
> under you. So: **before editing ANY tracked file, your FIRST action is to
> create a worktree** (command below) and `cd` into it. If you've already made
> edits on the main tree before realizing this, stop, `git stash`, move to a
> worktree, and `git stash pop` there. When the work is done, merge the branch
> back into `ramon-fork` as described in the paragraph below. No exceptions,
> no "this once."

**Always work on a git worktree, never directly on the main tree's `ramon-fork`
checkout.** Create a worktree for each task **inside `.claude/worktrees/`**
(`git worktree add .claude/worktrees/<task> -b <branch> ramon-fork`) — **NOT in
the repo's parent dir (`../ghostty-<task>`), which clutters `~/git/`**. The
`.claude/worktrees/` dir is gitignored, so the nested checkout (and its build
artifacts) never show up in the main tree's `git status`. Do all editing/testing
there, keep the main tree's `ramon-fork` checkout clean, and remove the worktree
when done (`git worktree remove .claude/worktrees/<task>`). **Release builds must ALWAYS come from `ramon-fork`
on the main tree** — never build a Release (the installed `/Applications/Ghostty
(ramon).app`) from a worktree branch. So when the work is done: **merge the
worktree branch into `ramon-fork`, switch the main tree to `ramon-fork`, and
rebuild there.** (The reason the worktree exists is precisely so the installed
Release that hosts this session keeps building from a stable `ramon-fork`.)

The full build / test / install steps (toolchain, `zig build`, `build.nu`, the deploy
block, the sidecar-rebuild + stale-xcframework traps) are in **`FORK-DEV.md`**.

## Redeploy reference (which change needs which restart)

Every Feature-map entry names one of these. **Getting this wrong ships a stale artifact
that "builds fine" — the class of bug that costs a debug session.** Detail: `FORK-DEV.md`.

- **GUI-only** (Swift-only): rebuild + install the app; user relaunches. No host restart,
  no session loss. Safe to deploy while the session is live (see `FORK-DEV.md` step 6).
- **Zig + lib**: any `src/` change the GUI links (new C export / config key / apprt action)
  → rebuild the lib **with the xcframework** (`zig build -Demit-macos-app=false
  -Doptimize=ReleaseFast`; never `-Demit-xcframework=false`) + `rm -rf macos/build/ReleaseLocal`
  + app build. Still no host restart if the change isn't compiled into `ghostty-host`.
- **Host** (`src/host/`, `src/termio/`, core that links into `ghostty-host`): deploy the new
  `ghostty-host` **and reload the LaunchAgent via bootout+bootstrap — never `kill`** (LWCR
  crash-loop). **This ends every live RAM-only session — schedule it deliberately.** See
  `PTYHOST.md`.
- **Sidecar** (`macos/agent-manager/`): rebuild `dist` (`npm run build`) — `build.nu` now
  re-bundles it, but a stale bundled `dist` deploys silently. GUI relaunch; no host restart.

## Feature map

One entry per fork feature: what it is, config keys (+ default / on-off), the redeploy it
needs, and its doc. **Read the doc before touching the feature** — the docs hold the
load-bearing gotchas, chokepoints ("omission silently drops the command"), wiring, and tests.

### Keybind actions & command palette → `FORK-ACTIONS.md`
Fork-only actions on the focused surface (all in the command palette unless noted):
`flip_split`, `toggle_split_direction`, `move_split_to_new_tab`, `merge_tabs`,
`new_tab[:dir]`, `new_tab_command`, `mark_split` / `clear_split_mark` /
`pull_marked_split`, `swap_split`, `compact_splits`, `goto_last_surface`, `report_bug`,
`toggle_project_selector` (needs the `project-directory` key), `suspend_split` (suspend an idle Claude
split to reclaim RAM — see `SUSPEND-RESUME-DESIGN.md`). Plus always-on tweaks to
upstream `goto_split` (directional wrap-around cycling) and `equalize_splits` (visual-grid
equalization), and the `repeatable:` flag prefix (tmux `bind -r`). `compact_splits`
reorganizes the tab into the densest `ceil(sqrt(N))`-column grid (reuses the Agent-Queue
compact-grid transform); no default keybind — bind it in `~/.config/ghostty-ramon/config`. GUI/Zig+lib depending on
the action. **Authoring trap:** trigger keys are case-insensitive and the `repeatable:` flag
is NOT part of trigger identity, so two bindings at one prefix silently clobber (last wins,
no error) — write `shift+` explicitly for any shifted symbol (`!`,`%`,`?`,…) and give
clashing actions different keys. Keep fork keybinds in `~/.config/ghostty-ramon/config`.

### Bell / attention → `BELL-ATTENTION.md`
Two-tier, fail-open "bell vs needs-you". Fork-only, OFF by default. Keys: `bell-features-focused`,
`attention-features`, `agent-manager-bell-filter`, `bell-diagnostics` (and it EXPANDS the shared
upstream `bell-features` vocabulary). `BellFeatures` = a Zig packed struct ⇄ Swift OptionSet by
FIXED bit position (pinned by a bit-ABI test); parse is ADDITIVE over defaults (dial down with
`no-*`). Load-bearing: promotion is FAIL-OPEN + event-driven; a truly focused surface is NEVER
promoted; a bell dismissal aborts/suppresses an in-flight classify via a generation guard. Also
covers: focused-variant bell, JSONL diagnostics, persistence across GUI restart
(`invalidateBellRestorableState()` on every mutation, or AppKit re-saves the stale blob), and
bell visibility across splits/zoom. GUI relaunch + rebuilt sidecar `dist`; no host change.

### Web monitor → `WEB-MONITOR.md`
GUI-embedded HTTP server; from a phone/laptop over Tailscale lists surfaces, renders one in color
via xterm.js off a per-session host byte stream, sends input, scrolls, maximizes a split, opens a
new tab (＋ New tab in the list → `POST /api/new-tab`, auto-jumps into it), and does bell→Web-Push.
Fork-only, OFF by default. Keys: `web-monitor-listen` (bind loopback `127.0.0.1:18787`, front with
`tailscale serve` for HTTPS), `web-monitor-token` 🔒. ONE responsive capability-adaptive page for
phone + desktop. Traps: input is REAL key events with NATIVE macOS virtual keycodes (the
`GHOSTTY_KEY_*` enum is wrong); scroll uses FRAME MODE (host authoritative render via
`ghostty_surface_read_ansi`) + a first-scroll cursor seed — never re-emulate scroll-region in
xterm.js (garble). **The live view streams over SSE (`/stream-sse`: base64 `data:` frames, grid
size as the first in-band `event: size`, token via `?token=`), NOT `fetch()`+getReader — iOS
WebKit BUFFERS a fetch body stream so the preview goes stale (the raw `/stream` is kept but
unused).** Mobile input: the Send field has autocorrect/spellcheck ON (autocapitalize off; token
box strict-off); buttons `preventDefault` pointerdown so the iOS keyboard-dismiss doesn't eat the
first tap. The raw-tee is a HOST change; the SSE/scroll/hide/maximize/page work is GUI-only.

### MCP server + knowledge tools → `MCP-SERVER.md`
GUI-embedded MCP server (HTTP JSON-RPC + stdio shim `ghostty-mcp`) giving an orchestrating agent
**27** registered tools to control the fork and watch/respond to sessions, plus 4 read-only config/
feature DISCOVERY tools (`get_effective_config`, `docs_for_feature`, `describe_config_key`,
`list_config_keys`) and `get_haiku_usage`. Fork-only, OFF by default. Keys: `mcp-listen`,
`mcp-token` 🔒 (a SHELL-EXECUTION credential — bind localhost, always set it). **When adding/
removing a tool, update the `toolsListHasAllTools` count assertion in `MCPServerTests.swift`.**
Mostly Swift over existing libghostty; `list_config_keys`/`describe_config_key` add read-only Zig C
exports (Zig+lib). Enabling/changing is a GUI relaunch, never a host restart.

### Agent Dashboard → `AGENT-DASHBOARD.md`
Sidebar `NSPanel` with a live natively-rendered preview of every split running a CLI agent; click
to jump, Hide, spotlight, dismiss bell system-wide, adopt into a queue. Fork-only, macOS, OFF by
default. Keys: `agent-dashboard`, `agent-dashboard-commands`, `agent-dashboard-pin`,
`agent-dashboard-spotlight-seconds`; actions `toggle_agent_dashboard`, `hide_dashboard_split`,
`spotlight_dashboard_split`, `focus_agent_dashboard`. Live previews need `pty-host`. **Two
presentations:** the floating panel OR a **docked native leftmost TAB** in the focused terminal
window (same SwiftUI, not a TUI — for a small laptop screen wanting the terminal full-screen).
`toggle_agent_dashboard` now **CYCLES** panel → tab → off, remembered across launches (persisted
`agentDashboardPresentation` in UserDefaults; **no config key**); **`focus_agent_dashboard`** jumps
to the dashboard (select the docked tab / bring the panel forward) — the "tab 0" left of cmd-1..9
(suggested `ctrl+a>backquote`). Tab mode adds `AgentDashboardTabWindow.swift` + the
`NonTerminalTabWindow` marker and teaches `TerminalController.relabelTabs` / numeric `onGotoTab` to
skip the non-terminal tab (cmd-1/`goto_tab:1` = first TERMINAL); ctrl-tab from the tab is handled in
`AppDelegate.localEventKeyDown`. **Mostly GUI-only Swift; `focus_agent_dashboard` is the one Zig+lib
piece** (new apprt action + C export → rebuild the xcframework). Traps: agent detection is HOST-GATED
on the minor-4 `foreground_pid` frame; per-tile state comes from Claude Code hooks POSTing to MCP
`/agent-state`; hook-only evidence is a LEASE that expires so a plain shell that once ran `claude`
stops being a tile. Mostly GUI; the mirror-grid C export is Zig+lib but NOT compiled into the host.

### Agent Manager → `AGENT-MANAGER.md`
Haiku status summarizer (warm TS Agent SDK sidecar) that annotates each dashboard tile with a live
one-line status; also the rate-limit attention watchdog. Read-only. Fork-only, macOS, OFF by
default. Keys: `agent-manager`, `agent-manager-node-path`, `agent-manager-usage-tracking` (default
ON), `agent-manager-warm-base` (default OFF), `agent-manager-alert-watchdog` (default ON). Billing
rides Claude Code's own auth (no API key). Traps: detection keys off `agentKind` (fg process is
`bash` under the pool wrapper); the sidecar self-disables unless enabled + MCP configured + `node`
on PATH; cost is controlled by throttle + warm-base fork-per-call. Includes the **sidecar orphan
guard** (`GHOSTTY_PARENT_PID` watchdog) and `get_haiku_usage`. GUI relaunch + rebuilt sidecar `dist`.

### Agent Queue → `AGENT-QUEUE.md` (user guide) + `AGENT-QUEUE-INTERNALS.md` / `-UI.md` / `-OPS.md` (impl notes)
Turns the dashboard into an active supervisor: from a JSON template it opens a tab of splits,
launches one CLI agent per work item, caps concurrency, tracks to completion, force-closes done+idle
splits (unless kept), and re-polls. Fork-only, macOS, OFF by default. Keys: `agent-queue`,
`agent-queue-templates-dir` (RepeatableString search list), `agent-queue-max-total` (0 = unlimited),
`agent-queue-hero-max`; action `start_agent_queue`. Hard deps: pty-host + Claude agent-state hooks.
Includes **adopt a free split**, **hero agents** (→ `HERO-AGENTS.md`), **schedules** (recurring
scan agents), the compact-grid retiling, and **per-queue multi-host** (→ `CLOUD-QUEUE-BALANCING.md`).
⚠️ Recurring chokepoint: a new queue command/annotation field must be whitelisted in
`coerceQueueCommands` (`mcp.ts`) and emitted on `list_surfaces` rows (`MCPLayout.surfacesJSONData`)
or it is SILENTLY DROPPED. GUI relaunch + rebuilt sidecar `dist`; usually no host/Zig change.

### PTY-host + session lifecycle → `PTYHOST.md`
The `.client` emulation-on-host backend: sessions survive a GUI quit/relaunch (RAM-only; a HOST
restart loses them). Config `pty-host` (local socket). Covers: the `SegmentedPool` write-pool
grow-corruption input-freeze fix (a core change → host restart), unconditional window-state
restoration (`window-save-state` is ignored, pinned `"always"`), deliberate-close-destroys-session,
the launchd LaunchAgent deploy (bootout+bootstrap, never `kill`), and the cloud-hosts redial subsystem.
Also the **host-handoff** path (behind `// FORK(host-handoff):`, additive + gated — `.exec` is
byte-for-byte unchanged when unused): (1) `src/host/session_transfer.zig` — a same-build,
full-fidelity marshal of a live `terminal.Terminal` (all scrollback, cursor, selection, modes,
charsets, kitty graphics, glyph glossary) behind a MAGIC + layout-fingerprint guard; (2) the
**pty-master DETACH + ADOPT** mechanism (`Exec.zig`/`Termio.zig`/`Session.zig`): a predecessor
`Session.detachForHandoff` gives up the pty master fd WITHOUT killing the child or closing the
master (extract first via `masterFdForHandoff`/`childPidForHandoff`), and `Session.adopt` builds a
fully-running successor Session around that master fd + child pid + rehydrated Terminal (via
`Exec.adopt` + `termio.Options.adopt_terminal`), continuing the SAME shell. Adopted-close SIGHUPs +
reaps the child and closes the master exactly once (no double-close/leak) — via `Exec.threadExit` for
a started session, or `Exec.deinit` for one destroyed WITHOUT ever starting (owner-thread-spawn
failed); `Session.adopt` sets `Exec.adopt` only on full construction success, so a mid-build failure
leaves the caller owning the fd (no double-close). An adopt-INIT FAILURE (task #7) closes ONLY the
successor's master copy, NEVER SIGHUPs the (predecessor's) child. The
accessors also surface an adopted session's own fd/pid, so a successor can hand off AGAIN (chained
swaps). (2b) **Worker-side supervisor↔worker CONTROL handling** (`Server.zig`, macOS-only, gated on
`Server.control_fd`): `register_master`/`unregister_master` announce; `freeze_all` serializes + hands
every session up + retains a `frozen` map; `adopt` takes a handed-off session over (registered under
its original id); `shutdown` drops the frozen state; `unfreeze` re-adopts it (incumbent survives a
failed successor) — over `handoff_protocol.zig` + `fdpass.zig` (`SCM_RIGHTS`). The worker now
AUTO-announces every fresh session's master from `sessionOwnerThread` (`announceSpawnedMaster`,
idempotent via `announced_masters`; adopted sessions skip it via `SessionEntry.announce_master`). (2c)
**The SUPERVISOR process** (`Supervisor.zig`, macOS-only): the SAME `ghostty-host` binary in a new argv
mode — `main_host.zig` dispatches `--supervise` / `--handoff-worker` / `--listen=` / stdout-diff via the
pure `Supervisor.parseMode`. It binds the listen socket forever, `spawnWorker`s a worker by fork/exec
with the listener at fd 3 + a control socketpair at fd 4 (dup2 + CLOEXEC-clear inheritance), holds every
pty master (`MasterRegistry` via a `readerLoop`), crash-restarts a dead worker (first cut: loses its
sessions), and BROKERS a handoff (`brokerHandoff`, the unit-tested core): `freeze_all` v1 → `adopt`→v2 →
a HEALTH-ACK GATE + a pre-commit successor-liveness check (all acked + `ready` AND v2's control channel
still open, via a `recv(MSG_PEEK)` EOF check → `shutdown` v1; any nack/timeout/dead-successor → `unfreeze` v1 + kill
v2, never a no-server window). The listener is a SHARED socket object across {supervisor,v1,v2}; **issue
#6** — a worker `deinit` must NEVER close it (`owns_listen_fd=false`) and the accept loop is wakeable
(`poll`+`accept_wake` self-pipe, non-blocking listener, `setBlocking` accepted fds) so v1's teardown can't
XNU-`SS_DRAINING`-poison the successor's accepts (the actual fix). CLOEXEC hygiene: `accept_wake` +
`reader_wake` + the worker's inherited listener/control fds are all `FD_CLOEXEC` so shells never inherit
them (a leaked control fd would defeat crash detection). The issue's proposed connect "service probe" was
dropped as unsound — it runs BEFORE the poison (v1's post-`shutdown` `deinit`) and can't attribute an
accept to v2 (→ `HOST-HANDOFF.md`).
Two TRIGGERS now fire a handoff (`triggerSelfHandoff`, reader-thread-inline,
canonical path re-resolved at trigger time, coalesced): a **SIGHUP** (async-signal-safe handler → atomic
flag + `reader_wake` self-pipe; the "new build installed" nudge ForkSetup sends) and a periodic
**exec-path staleness self-check** folded into the reader `poll` (macOS `libproc` `proc_pidpath` + the
pure `workerPathStale`: stale on `ENOENT`/unlinked-exec — the EPERM condition — or a canonical-path
mismatch → hand off to a fresh worker; the supervisor's own stale path only WARNs, no self-exec).
In-process tests in `src/host/test.zig`: the worker-side detach+adopt + freeze→adopt / unfreeze / task-#7
SEQUENCE tests (mock supervisor vs real `Server` workers) PLUS the `brokerHandoff` SUCCESS/ABORT tests
(two mock workers + a fake registry over `socketpair`s) + a `parseMode` arg-parse test + the trigger tests
(pure `workerPathStale` + `proc_pidpath` self-resolve). SIGHUP delivery + timer-driven firing + a real
supervisor process on launchd restart are live-smoke only; a host restart still loses sessions today.
Host change. (2d) **ForkSetup wiring** (Swift/GUI-only → `FORK-DISTRIBUTION.md` + `HOST-HANDOFF.md`):
the colleague host LaunchAgent plist now runs the SUPERVISOR (`ghostty-host --supervise --listen=…`), and
the reload gate is SPLIT into a **supervisor** vs **worker** identity (carved in Swift from the existing
`ghostty_host_reload_identity()`, NO new C export) so a common WORKER change is a non-destructive
`.handoffWorker` (SIGHUP the running supervisor → session-preserving handoff, no bootout) and only a rare
SUPERVISOR change keeps the destructive `.reload`; first-cut mapping supervisor=protocol MAJOR,
worker=MINOR+`host_reload_epoch`. Plus (3) **P2 GUI local handoff-redial**
(`Client.Config.handoff_redial`, GUI-only, no host change): a LOCAL `.attach` surface reuses the
cloud-hosts redial machine — armed via the derived `Config.wantsRedial()` (`reconnect or
handoff_redial`) — to reconnect across the ~1-3s handoff socket gap, but with a FINITE cap
(`shouldKeepRedialing`, `RECONNECT_HANDOFF_MAX_ATTEMPTS=3`) so a genuinely-dead local host is NOT
stormed; `session_ended`-on-miss stays gated on `reconnect` ALONE (local falls through to
adopt-fresh-id, no dead-pane overlay). `handoff_redial=true, reconnect=false` for a local attach;
remote stays `reconnect=true`; mirrors get neither; both-false is the byte-for-byte single-shot path.
Set in `src/Surface.zig` (inverse of the `reconnect` gate, no C ABI). Pure-helper + arming tests in
`src/termio/client_difftest.zig`.

### Cloud-hosted terminals → `CLOUD-HOSTS-DESIGN.md` / `CLOUD-HOSTS-IMPL-PLAN.md`
Some splits/tabs run their shell on a remote `ghostty-host` over an SSH unix-socket forward, mixed
with local splits; reattach by stable `(host, session_id)`. Fork-only, OFF by default. Keys:
`pty-remote-host` (RS registry), `pty-remote-host-command` (RS transport override 🔒-ish),
`pty-remote-project-directory` (RS), `pty-remote-ssh-options`, `pty-remote-connect-timeout` (u32),
`pty-remote-capability-token` (RS 🔒), `pty-remote-mcp-allowed-host` (RS); actions
`new_split_on_host` / `new_tab_on_host`. Phases 1–6 + hardening (tunnel liveness watch, orphan-forward
reap, `adopt_split`, cross-host tile) are in the design doc; multi-host queue balancing is in
`CLOUD-QUEUE-BALANCING.md`. GUI relaunch + a lib/xcframework rebuild (new config keys / C exports);
the Linux `/proc` arm is the only host change, and only on the box.

### Standalone fixes → `FORK-FIXES.md`
Self-contained robustness / upstream-bug fixes not tied to one feature — currently the `CachedValue`
thread-safety SIGABRT fix (GUI-only). The PTY-host write-pool fix lives in `PTYHOST.md`.

## Fork-only config keys

All fork-only — keep them in `~/.config/ghostty-ramon/config` (an official Ghostty shares
`~/.config/ghostty/config` and errors on unknown keys). 🔒 = a secret/credential → put it (and any
per-machine value) in the untracked `~/.config/ghostty-ramon/local`, pulled in via
`config-file = ?~/.config/ghostty-ramon/local`. RS = `RepeatableString` (repeat the key for more
entries). Loading mechanism + how the tracked `example/` copies mirror the live configs:
`FORK-DISTRIBUTION.md`.

- **Splits / projects:** `project-directory` (RS)
- **Bell / attention:** `bell-features-focused`, `attention-features`, `agent-manager-bell-filter`, `bell-diagnostics`
- **Web monitor:** `web-monitor-listen`, `web-monitor-token` 🔒
- **MCP server:** `mcp-listen`, `mcp-token` 🔒
- **Agent dashboard:** `agent-dashboard`, `agent-dashboard-commands`, `agent-dashboard-pin`, `agent-dashboard-spotlight-seconds`
- **Agent manager:** `agent-manager`, `agent-manager-node-path`, `agent-manager-usage-tracking`, `agent-manager-warm-base`, `agent-manager-alert-watchdog`
- **Agent queue:** `agent-queue`, `agent-queue-templates-dir` (RS), `agent-queue-max-total`, `agent-queue-hero-max`
- **Cloud hosts:** `pty-remote-host` (RS), `pty-remote-host-command` (RS 🔒-ish target), `pty-remote-project-directory` (RS), `pty-remote-ssh-options`, `pty-remote-connect-timeout` (u32), `pty-remote-capability-token` (RS 🔒), `pty-remote-mcp-allowed-host` (RS)
- **PTY-host infra:** `pty-host` (local socket path)

## ⚠️ Safety
**Two remotes — push ONLY to `fork`, NEVER to `origin`.**
- `origin` = *upstream* `ghostty-org/ghostty` (the official repo). **Never push here.**
  A push to `origin` would shove personal work at the official project.
- `fork` = personal backup `git@github.com:ramonsnir/ghostty.git`. Back it up with a
  **bare `git push fork`** (no refspec). The `fork` remote has a pinned push refspec
  (`remote.fork.push = refs/heads/ramon-fork:refs/heads/main`), so `git push fork`
  **always** pushes local `ramon-fork` → `fork/main`, **regardless of which branch is
  currently checked out** — you can run it from any local feature branch and it still
  backs up `ramon-fork`, never the feature branch.
  - **Do NOT add an explicit refspec** like `git push fork HEAD:main` — an explicit
    refspec overrides the pinned one and, from a feature branch, would overwrite
    `fork/main` with the wrong branch. Always use the bare `git push fork`.

So pushing to `fork` is now allowed and is the backup path; just confirm the
remote is `fork` before pushing, and **never** `git push origin`. Any local-only
feature branches (the old `ptyhost/*` ones are gone, merged into `ramon-fork`) have
no remote set — leave them local-only unless explicitly asked to back them up to
`fork`, and remember a bare `git push fork` backs up `ramon-fork`, not them.

NEVER run `osascript -e 'quit app "Ghostty"'` — the fork and the official build are
both *named* "Ghostty", so it's ambiguous and can quit the user's real, working
Ghostty.

**Avoid casually quitting the installed Release fork (`com.mitchellh.ghostty-ramon`)
— it normally hosts the shell Claude Code is running in. But be accurate about
why: under pty-host a GUI quit is a DETACH, not a kill. The shell + `claude`
survive on `ghostty-host` and REATTACH on relaunch (the installed build forces
`NSQuitAlwaysKeepsWindows` on, so reattach is reliable), so a DELIBERATE
quit+relaunch to pick up a new build is non-destructive and THIS session
continues across it — it does NOT "terminate the session mid-task." The real
caution is that reattach is reliable-not-GUARANTEED: a rare connect-race /
App-Nap edge case can leave the session alive-but-orphaned (the `claude` process
is fine on the host, but its GUI view is lost until re-found). So don't quit it
without a reason, and prefer letting the user drive the relaunch — but a planned
relaunch (e.g. to activate a deployed GUI change) is expected and safe.** The
three identities exist specifically so iteration doesn't touch the host:

| Identity | Bundle id | Path | Safe to quit/launch? |
|---|---|---|---|
| Release (installed) | `com.mitchellh.ghostty-ramon` | `/Applications/Ghostty (ramon).app` | Quit = DETACH (survives + reattaches on relaunch); don't quit casually, but a planned relaunch is fine |
| ReleaseLocal | `com.mitchellh.ghostty-ramon.local` | `macos/build/ReleaseLocal/Ghostty.app` | Yes |
| Debug | `com.mitchellh.ghostty-ramon.debug` | `macos/build/Debug/Ghostty.app` | Yes |

To restart the dev fork, target precisely:
`osascript -e 'tell application id "com.mitchellh.ghostty-ramon.local" to quit'`
(or `.debug`), or kill the PID whose path is under `macos/build/`. For the
installed Release, the install block in `FORK-DEV.md` (step 6 of the iteration
lifecycle) is safe to run while the host is live (ditto/plist/codesign don't disturb the
running binary) and **may be run WITHOUT confirmation** when the deploy is
GUI-only from a `ramon-fork` build (see `FORK-DEV.md` for the exact two conditions; a
host change or a branch build still needs to be raised with the user first).
Either way, let the user quit + relaunch the installed Release themselves to
pick up the new binary.
