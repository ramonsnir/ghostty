# PTY-host (emulation-on-host) — current state

A long-lived **`ghostty-host`** process owns the PTY, the child shell, and the
terminal **emulation**. The macOS GUI runs as a thin **`.client`** that renders a
host-fed, viewport-only *mirror* of the screen over an `AF_UNIX` socket. The point
of the split: **a terminal session (live shell + its children + screen state)
survives a GUI binary swap or restart** — quit the GUI, rebuild/reinstall, relaunch,
and each tab reattaches to its still-running host session.

Status: **merged into `ramon-fork`** (the former `ptyhost/phase-2b` branch and
its isolated worktree are gone — merged and deleted). For the rationale behind
any line, `git log` / `git show` / `git blame` the `.client`-backend files
(`src/host/`, `src/termio/Client.zig`, `src/termio/Termio.zig`).

This doc is the **current-state** description (what works, what doesn't, how it's
built, what the goal status is). Forward backlog + decisions live in the
**local-only** (untracked) `.claude/docs/ptyhost-remediation.md`.

---

## Goal status: does a session survive a GUI restart?

**Yes — substantially met, and close to a daily driver.** On GUI quit + relaunch,
each tab reattaches by a host-assigned `session_id` (persisted via macOS restorable
state) and recovers the **live** host session: the same shell process and its
children, cwd, terminal modes, scroll region, alt-screen, and scrollback. Reattach
is responsive and shows scrollback. Verified live and by host integration tests.

### "Well" — what is preserved vs. lost on reattach

| Preserved | Lost / not restored |
|---|---|
| Live shell process + children (same PIDs) | Selection (transient host gesture state) |
| cwd, modes, scroll region, charset, alt-screen | — |
| Scrollback (host-owned; reaches GUI on attach + via host-round-trip scroll) | — |
| Title, colors, cursor + cursor style, viewport | — |
| Window/tab/split layout (macOS restorable state) | — |

### "Always" — failure modes and the honest caveats

- **Host crash/kill, or machine reboot → ALL sessions lost.** The host holds every
  session in memory with no persistence; it is the **single point of failure**. This
  is the inherent trade the design makes — it survives *GUI* restarts, not *host*
  restarts. There is no launchd supervision and **no SIGTERM/graceful shutdown**
  (killing the host kills every shell). Host crash-hardening is therefore the
  highest-stakes property; see Durability below (it is in good shape).
- **Unknown `session_id` on reattach → fresh spawn (now logged; no false match).**
  If the persisted id no longer maps to a live host session, the GUI spawns a new
  blank shell (`Server.zig` handleAttach "degrade to spawn-fresh"). Session ids are
  **random 64-bit** (not a counter that resets to 1 each host launch), so a stale id
  from a dead host instance never false-matches a fresh one — an unknown id always
  degrades cleanly instead of binding a tab to the wrong/younger session. The Client
  detects the miss (it asked for one id and got a different one back) and **logs it**
  ("prior session closed or host restarted"); a user-visible indication (vs. a log)
  is the remaining polish. The orphaned host session, if any, keeps running with no
  GUI attached.
- **Restorable-state versioning is tolerant (NOT a cliff).** `TerminalRestorableState`
  is `version = 8` but **`minimumVersion = 5`** (`TerminalRestorable.swift`; only the
  protocol *default* is `minimumVersion { version }`, and the concrete type overrides
  it). The decoder accepts v5–8, and the Codable layer is additive-tolerant — newer
  fields are optionals / `decodeIfPresent` (e.g. `sessionID` at
  `SurfaceView_AppKit.swift`), so an older blob simply leaves them `nil` (those
  surfaces spawn fresh; everything else restores). So older schemas load fine across
  the additive changes made so far. The real sensitivity is only if a future change
  **raises `minimumVersion`** or makes a **non-additive** change (renamed/retyped/
  required field) — keep changes additive+optional and `minimumVersion` low. (This is
  the macOS state-restoration schema version — unrelated to the host *protocol*
  version negotiated in `Hello`.)
- **Reattach is gated by macOS state restoration — the fork forces it on
  UNCONDITIONALLY (fork-only, issue #5; supersedes the earlier pty-host-gated
  behavior).** The reattach id lives in the macOS window-state archive
  (`sessionID`, above), so a GUI quit/relaunch only recovers live sessions if
  macOS actually *writes and restores* that archive. Whether it does on a clean
  quit is governed by `NSQuitAlwaysKeepsWindows`, which historically the fork
  derived from `window-save-state` (`always → true`, `never → false`, `default →`
  defer to the macOS **"Close windows when quitting an application"** system
  preference — which is *checked-by-default* in modern macOS = don't restore). So
  under `window-save-state = default` (the fork's own default) the whole "sessions
  survive a GUI quit/relaunch" promise **silently** hinged on an invisible system
  checkbox. The fork now removes the dependency entirely: **restoration is
  unconditional.** `Ghostty.Config.windowSaveState` is pinned to `"always"` (the
  config value is no longer consulted — the `window-save-state` key stays defined
  in `src/config/Config.zig` only so the shared/upstream config still parses it),
  `AppDelegate.quitAlwaysKeepsWindows()` is a constant `true` (always sets
  `NSQuitAlwaysKeepsWindows = true`), and the `willEncodeRestorableState` /
  `didDecodeRestorableState` / `TerminalRestorable.restoreWindow` guards that once
  skipped on `"never"` are removed (always encode / always decode). An explicit
  `window-save-state = never` **NO LONGER opts out** (accepted trade-off — no
  config escape hatch), and this applies to every identity/build, not just
  pty-host. Wiring: `macos/Sources/Ghostty/Ghostty.Config.swift` (getter →
  `"always"`), `macos/Sources/App/macOS/AppDelegate.swift` (`quitAlwaysKeepsWindows`
  collapsed to `true` + `ghosttyConfigDidChange` + `willEncode`/`didDecode`),
  `macos/Sources/Features/Terminal/TerminalRestorable.swift` (skip-branch removed),
  `macos/Sources/Features/ForkSetup/ForkSetup.swift` (seed comment); test
  `macos/Tests/App/AppDelegateTests.swift`.
- **Connect failure (host down / bad socket) → visible error, never a silent local
  fallback.** The IO thread paints an error into the surface
  (`src/termio/Thread.zig`); it never quietly forks a local shell, so a degraded
  host is never mistaken for a working session.
- Handled cleanly: degenerate/transient reattach resize frames (dropped),
  child-already-exited (tab closes correctly), detach/reattach/close races
  (serialized on `registry_mutex`), multiple windows/tabs (per-tab id).

---

## Session lifecycle: detach-on-quit vs. close-on-deliberate-close (fork-only)

The default teardown for EVERY `.client` surface is **detach**: a bare socket drop
(the GUI quitting, crashing, being SIGKILLed, or a macOS window-state restore
transient) reaches the host as an EOF, which **parks** the RAM-only session for
reattach (`Server.readLoop` `n==0` → `unsubscribeAll`, child survives). That is
exactly right for a quit/relaunch — it is what makes reattach work — but it means a
**deliberately closed** split/tab/window would otherwise leave its shell running
forever with no GUI ever coming back for it (a host-side leak; `Server.zig` documents
the gap).

Fix (fork-only, GUI-lib-side; the host already implements the `Close` frame +
`handleClose` — **no host rebuild/restart, live sessions survive the deploy**): a
DELIBERATE close now sends `protocol.Close`, which fetch-removes + tears down the host
session. "Deliberate" = close split (`ctrl+a>x` / `close_surface`), close tab (tab X /
`close_tab` / close-others), close window (red button / `close_window`),
and the confirm-free fast path (Agent-Queue auto-close / AppleScript / App-Intent /
dead-process close). A quit / crash / restore transient is NOT deliberate and still
detaches.

- **Mechanism (core, `src/termio/Client.zig`).** A per-`Client` atomic
  `close_session` (store-release on the apprt thread, load-acquire on the io thread).
  `threadExit` — after the read thread is joined, before `posix.close(fd)` — sends a
  **synchronous** framed Close (`sendCloseSync`) iff FOUR gates all hold:
  (i) `role == .attach` (a `.mirror` dashboard preview NEVER closes),
  (ii) `close_session` set (the deliberate mark),
  (iii) `!app_quitting` (the process-global quit gate; see below),
  (iv) `session_id != 0` (actually attached). The async xev write path is dead at
  teardown (the loop has stopped), so the send is a blocking `posix.write`;
  `sendCloseSync` sets `SO_NOSIGPIPE` (a peer-closed socket returns EPIPE, never a
  process SIGPIPE) + `SO_SNDTIMEO` (250ms — a wedged host can't hang teardown) and
  clears `O_NONBLOCK`. It is best-effort: every failure is logged + swallowed; the
  host's idle reaper is the backstop. `handleClose` is idempotent (an unknown /
  already-removed id is a no-op), so a Close racing the child's own exit is safe.

- **The last-window-close → DETACH guarantee is a MARK-TIME prediction, not the
  send-time belt.** A last-window explicit close that TRIGGERS app termination must
  detach (keep sessions for reattach), not destroy. The load-bearing signal is
  `TerminalController.windowCloseTriggersAppTermination()` (pure core
  `windowCloseWouldTerminate(shouldQuitAfterLastWindowClosed:remainingTerminalWindowCount:)`
  = quit-after-last-window AND no other terminal window remains): when true, A3 marks
  NOTHING. This is stateless and independent of teardown-vs-`willTerminate` ordering.
  The process-global `app_quitting` gate (set by `ghostty_app_set_quitting(true)` at
  `applicationWillTerminate`) is a defense-in-depth BELT for any future termination path
  that might route through a mark site; cmd+Q itself never marks (its teardown path
  doesn't route through `closeSurface`/`close*Immediately`).

- **Mark plumbing (macOS Swift).** The mark is centralized in
  `BaseTerminalController.replaceSurfaceTree(closingViews:)` — threaded from
  `removeSurfaceNode(deliberateClose:)` and FORWARDED to `super` by the
  `TerminalController.replaceSurfaceTree` override — so a split `close → undo → redo`
  re-marks (the undo closure clears via `keepSession`; the nested redo re-invokes
  `replaceSurfaceTree` with the same `closingViews`). **Root** split closes are
  intercepted by `closeSurface` and routed to `closeTab`/`closeWindow`, so the override's
  **empty-tree branch is reached ONLY by MOVES** — it closes the emptied tab via
  `closeTabImmediately(markLeaves: TerminalController.moveEmptiedSourceMarksLeaves)` (a
  NAMED, tested `false` constant — the sole protection for the reparented live view,
  which the `viewHeldByAnotherController` backstop cannot yet catch), never marking it.
  A tab close (`closeTabImmediately(markLeaves:)`, A2) and a window close
  (`closeWindowImmediately(markLeaves:)`, A3) fan the mark out to EVERY leaf of every
  controller in the tab group — **including zoom-hidden splits** (`root.leaves()`) —
  before each tree is emptied; their redo re-marks by re-invoking `close*Immediately()`,
  and the `with: undoState` restore init clears the mark on the restored leaves.
  `closeWindowImmediately`'s mark decision runs through the pure
  `TerminalController.shouldMarkLeavesOnClose(isMoveEmptiedSource:triggersAppTermination:)`
  (marks iff NOT a move AND NOT app-terminating). **All marking funnels through ONE
  place:** `BaseTerminalController.applyCloseMark(_ phase:_:)` runs the pure, generic,
  per-phase decision `closeMarkOperations(_:closingViews:heldElsewhere:)` — `.set`/`.redo`
  mark every non-held leaf, `.undo` clears EVERY closing leaf unconditionally (the
  data-loss-safe direction), a move (`nil`) is a no-op — through the single overridable
  `setCloseSessionHook` seam (default = the real `ghostty_surface_set_close_session` /
  `_keep_session` C exports). A recorder + `MockView` test drives `.set → .undo → .redo`
  through `closeMarkOperations` to observe the mark → clear → re-mark ordering with no
  live controller/surface.

- **EXCLUDED — moves + mirrors never mark.** Every reorganization that reparents a LIVE
  `SurfaceView` (`move_split_to_new_tab`, `pull_marked_split`, `merge_tabs`, `swap_split`,
  queue pack/adopt/promote/demote, cross-window drop, `retileCompactGrid`) calls
  `removeSurfaceNode` with `deliberateClose: false` (→ `closingViews == nil`) AND, if it
  empties a source, hits the override's `markLeaves: false` branch. A defense-in-depth
  `viewHeldByAnotherController` backstop additionally skips any leaf already held by
  another live controller. `.mirror` clients are triple-gated (setter early-return,
  `threadExit` role gate, host render-only refusal).

- **Undo safety.** The undo state retains the live `SurfaceView`s until undo expiry, so
  a wrongly-marked Close is delayed by the undo timeout and preempted by process death on
  a real quit; a `close → undo` clears the mark before it could fire.

- **Two accepted caveats (both err toward SAFE detach, never toward killing a live
  session).** (1) `windowCloseTriggersAppTermination` counts only *terminal* windows as
  "remaining", not a Settings/About auxiliary; with such an auxiliary open at a
  last-terminal-close it OVER-predicts termination and DETACHES a session that could have
  been destroyed (a harmless session-park leak that clears on the next reattach / host
  restart). (2) The **Quick Terminal**'s single ROOT surface is never destroyed by a
  deliberate close: `QuickTerminalController.closeSurface` overrides the root path — a live
  root animates out (no teardown) and a process-exited root empties the tree DIRECTLY
  (never through `removeSurfaceNode(deliberateClose:)`, so no leaf is marked). Only a
  NON-root Quick-Terminal split routes to `super` and destroys that split's session, which
  is the intended deliberate-close behavior.

- Wiring: core `src/termio/Client.zig` (`close_session` + `app_quitting`/`setQuitting` +
  `requestCloseSession`/`keepSession` + `threadExit` gate + `sendCloseSync`),
  `src/Surface.zig` (forwarders), `src/apprt/embedded.zig` + `include/ghostty.h`
  (`ghostty_surface_set_close_session` / `_keep_session` / `ghostty_app_set_quitting`).
  macOS `Ghostty.Surface.swift` (`markCloseSession`/`keepCloseSession`),
  `AppDelegate.swift` (`shouldQuitAfterLastWindowClosed` + the
  `applicationWillTerminate` quit gate), `BaseTerminalController.swift`
  (`setCloseSessionHook` seam + `viewHeldByAnotherController` + `leavesToMarkForClose` +
  `closingLeaves` (the primary deliberate-vs-move mapping) + `CloseMarkPhase` +
  `closeMarkOperations` (the pure per-phase mark/clear decision) + `applyCloseMark`
  (the ONE funnel) + `markLeavesForClose` +
  `removeSurfaceNode(deliberateClose:)` + `replaceSurfaceTree(closingViews:)`),
  `TerminalController.swift`
  (`replaceSurfaceTree` override + `moveEmptiedSourceMarksLeaves` (named empty-branch
  constant) + `shouldMarkLeavesOnClose` (window-close mark predicate) +
  `closeTabImmediately(markLeaves:)` +
  `closeWindowImmediately(markLeaves:)` + `closeAllWindowsImmediately` — forces
  `markLeaves: false` across the batch when the close-all quits the app, so every window
  DETACHES uniformly at mark time — + `windowCloseTriggersAppTermination` /
  `windowCloseWouldTerminate` + the `with: undoState` mark clear). Tests: Zig
  `src/termio/client_difftest.zig` (deliberate-close sends Close; mirror/unattached/
  quitting/unmarked send none; peer-close swallow), `src/host/test.zig` (Close
  idempotency), Swift `macos/Tests/Terminal/CloseSessionLifecycleTests.swift`
  (`leavesToMarkForClose` + `closingLeaves` move-exclusion; `closeMarkOperations`
  recorder-seam mark → clear → re-mark ordering + move-never-marks + held-elsewhere
  filter; `moveEmptiedSourceMarksLeaves` == false; `shouldMarkLeavesOnClose` matrix;
  `windowCloseWouldTerminate` matrix; zoom-hidden leaf enumeration).

---

## Current functional state (`.client`)

Everything below is verified against the code at HEAD. Roots for non-working items:
**R1** = GUI reads the unfed local terminal; **R2** = host mode-mirror not consumed;
**R3** = no scrollback/history on the wire (mirror is viewport-only).

### Works

- **Input:** typing; all TUI input modes (DECCKM cursor keys, keypad, Kitty keyboard
  flags, alt-esc, backarrow, modify_other_keys, KAM); bracketed paste; mouse
  click/release/motion/drag reporting (SGR/X10/1002/1003) + button-scroll +
  alternate-scroll. (Host ships a `ModeFrame`; the `.client` terminal applies it.)
- **Rendering:** cells, colors (incl. 256-palette / reverse-video), cursor +
  visibility/blink/style; cell fidelity is proven equal to in-process `.exec`
  (differential tests).
- **Selection + copy:** drag-select, double-click word, triple-click line,
  select-all; ⌘C / copy-on-select. Host-authoritative (host runs `select*` /
  `selectionString` on the real screen). **Select-all copies the full buffer
  including scrollback** (no R3 needed — the host has it).
- **Scroll** (host round-trip), **⌘K clear screen/scrollback**, **terminal reset**
  (force-pushes the post-reset frame so stuck modes recover).
- **confirm-close-surface=true** warns only when a command is actually running
  (host-authoritative `at_prompt` bit). (`=always`, the user's config, confirms
  unconditionally by design.)
- **SurfaceEvents:** title, bell, clipboard read/write (OSC52), pwd, dynamic colors
  (OSC 4/10/11), desktop notifications, progress, mouse-shape, password-input,
  command-tracking.
- **Links:** OSC8 (host-computed) and regex-link *detection*. **Search**
  (host-computed highlights + nav + counts). **Resize** (authoritative wire grid;
  degenerate frames dropped). **child-exit → tab close.**
- **cwd-inherit on new tab:** wired (host `finalize()`s its config so the login
  shell + OSC7 resolve; pwd synced into the local terminal). Believed working; a
  definitive end-to-end GUI re-smoke is the one loose end here.

### Broken / missing — but low-to-near-zero impact for this usage

(Interactive shells + TUIs + CLI agents. No CJK/IME, VoiceOver, or right-click copy.)

| Item | Root | Impact |
|---|---|---|
| Alt-screen wheel→arrow translation (less/man/vim without mouse mode) | R2 | low-moderate (the one felt gap; apps with `mouse=a` work) |
| Cursor-click-to-move at the prompt | R1 | low-moderate (keyboard nav unaffected) |
| Selection autoscroll past the viewport edge | R1/R3 | low (select-all covers whole-buffer copy) |
| Cross-scrollback selection *highlight* (the off-screen visual) | R3 | low (copy across scrollback works) |
| regex-link / copy_url *text extraction*; `search_selection` seed | R1 | low |
| `write_screen` history dump; `read_text`/accessibility over history | R3 | near-zero (no VoiceOver) |
| IME preedit anchor; Quick Look / Look Up word | R1 | near-zero (no IME) |
| Live OS color-scheme DSR (mode 2031); right-click→Copy | R1/R2 | near-zero / de-prioritized |

**Scrollback paging is local-less by design:** the mirror is viewport-only, so scroll
is a host round-trip (no smooth local paging). History-spanning features (the R3
rows above) would need a new history-transport frame — see *Phase C: decided against*
in the remediation doc.

---

## Durability & safety posture

- **`.exec` is byte-for-byte unchanged** (the hard invariant). Every `.client`
  behavior is gated on mirror-presence / the backend union; the differential test
  corpus asserts the mirror equals the in-process `.exec` RenderState cell-for-cell.
- **Host crash-hardening (the highest-stakes property): good.** The two known crash
  vectors are fixed and regression-tested — the `PageList.resizeCols` unsigned
  underflow (saturating subtraction; this was the *all-sessions-down* reattach-flood
  crash) and an `@enumFromInt` UB on an untrusted highlight tag on the render hot
  path (validated at the wire boundary + at the render site). The **entire untrusted
  GUI→host frame surface degrades a malformed frame to a clean connection close, not
  a process abort**: every enum decode goes through checked `intToEnum`, frame length
  is bounded, the dispatch loop catches and logs, and selection coords drop
  out-of-viewport rather than index out of bounds. No other reachable host
  crash/UAF turned up in dispatch/selection/resize/decode.
- **Residual durability risk:** the host runs the full upstream terminal emulator on
  real PTY output and has **no panic isolation** — a latent panic anywhere in
  upstream emulation reachable by adversarial child output would abort the whole
  process (all sessions). None found; the surface is the whole emulator, not just IPC.
- **Data integrity:** the render-tick push gate is complete (rows-changed OR
  force-push for search/selection/viewport/**mode** OR cursor-changed), so no
  render-affecting host state change is silently dropped. Selection text is extracted
  in the same locked critical section as the snapshot, so highlight and copy text
  share one point-in-time read (no torn/stale copy).
- **Write-request pool grow corruption — the permanent per-session input freeze (FIXED).**
  This was THE cause of the recurring "one tab's input wedges forever; session stays alive;
  survives a GUI restart; only a host restart clears it" symptom, and of the
  `libxev_kqueue: invalid state in submission queue state=.active` bursts. **Root cause:**
  `SegmentedPool` (`src/datastruct/segmented_pool.zig`), which vends the stable-pointer
  `xev.WriteRequest`/`[64]u8` slots for the PTY write path (`Exec.zig` `write_req_pool` /
  `write_buf_pool`; also `Client.zig`), was a RING (`get()` = `@mod(i, len)`) whose `grow()`
  reset the ring cursor `i` against a **doubled modulus** while writes were still outstanding.
  Once more than `prealloc`(=32) writes were outstanding at one moment — a >2 KB paste chunked
  into 64-byte writes, an output/DA/DSR burst, or a reattach flood — the grow desynced the
  cursor from the outstanding window, so a later `get()` handed back a slot whose
  `xev.Completion` was **still armed in kqueue**. Reusing that live completion double-added it
  to `loop.submissions` (→ the `.active` log) AND, more often, clobbered the WriteQueue's
  intrusive `next` pointer (`stream.zig`, `req.* = .{}`), **severing the write daisy-chain so
  every subsequent keystroke to that session was dropped forever**. Only ~9% of hits landed on
  the active head (the logged error); ~91% hit a queued slot and wedged **silently**, so the
  logged bursts under-counted the real frequency ~10×. State is per-session, host-side,
  RAM-only → a GUI reattach (same `session_id`, fresh sockets) rejoined the same corrupted
  session; only a host restart re-inited the pool. **Fix:** `SegmentedPool` now tracks slot
  liveness EXPLICITLY with a free-list (a parallel index ring `idx` + `head`/`available`): a
  slot is vended only from the genuinely-free region and `grow()` renormalizes to `head=0`
  with the fresh slots as the free region, so a live slot can NEVER be re-vended regardless of
  grow timing. Public API (`get`/`getGrow`/argument-less FIFO `put`/`deinit`, default `.{}`)
  is byte-compatible, so both callers are unchanged and the GUI `.client` write pool is fixed
  by the same change. `get`/`put` stay O(1) + allocation-free; only `getGrow`/`grow` allocate.
  Proven by a 220k-iteration fuzz test (shadow model asserting no live aliasing + count
  invariant + no live-slot clobber) and a deterministic 8-op grow-while-outstanding repro,
  both of which FAIL on the old ring and PASS on the fix. **This is a core `src/` change that
  links into `ghostty-host`, so it only takes effect after a host redeploy + LaunchAgent
  bootout+bootstrap (ends live RAM-only sessions) AND a GUI lib/xcframework rebuild.** Wiring:
  `src/datastruct/segmented_pool.zig` (free-list rewrite + the two tests). Callers unchanged:
  `src/termio/Exec.zig`, `src/termio/Client.zig`.
- **Known scalability caveat (not a correctness bug):** attach/close do blocking
  socket writes under `registry_mutex`, so they serialize behind one slow GUI peer —
  acceptable for a single local GUI.
- **Spurious-`child_exited` diagnostic (fork-only, always on, host-only).** When the
  host emits a `child_exited` (driven by the `xev.Process` exit watcher → `processExit`
  → `processExitCommon`), `Server.onChildExited` first checks whether the watched child
  pid is *actually* gone via `kill(pid, 0)`: ESRCH (`error.ProcessNotFound`) ⇒ genuine
  exit (logged `info` "child_exited verified gone"); still alive ⇒ logged **`warn`
  "SPURIOUS child_exited: pid=… STILL ALIVE at emit"**. This is the proof probe for the
  reported symptom *"the GUI shows Process-exited but the session is still live in the
  host"* — if it ever fires `warn`, the `xev.Process` completion fired erroneously
  (suspected libxev completion corruption; historically correlated with the
  `libxev_kqueue: invalid state in submission queue` bursts — but note those bursts are now
  ROOT-CAUSED and FIXED via the SegmentedPool write-pool grow bug above, so post-fix a
  `warn` here would point at a DIFFERENT completion-corruption source, not the write pool).
  Reads STORED backend state only
  (`Session.childPidForDiag` → `Exec.childPidForDiag`, the `.exec` fork/exec leader pid);
  no syscalls beyond the `kill(pid,0)` probe, no mutation — **`.exec` runtime is
  byte-for-byte unchanged** (the GUI never reaches `onChildExited`; it's host-only).
  CAVEAT: a tiny pid-reuse window between the IO-thread exit notification and this
  owner-thread callback could read a reused pid as "alive" — rare for the exact pid
  within one ~100 ms tick. Wiring: `src/termio/Exec.zig` (`childPidForDiag`),
  `src/host/Session.zig` (`childPidForDiag` forwarder), `src/host/Server.zig`
  (`onChildExited` probe). NOTE: this is a temporary diagnostic — remove it once the
  spurious-exit cause is found (or kept as a cheap permanent guardrail).

---

## Architecture & invariants

### Two backends (`src/termio/backend.zig`)

- **`.exec`** (default) — the in-process `Terminal`; upstream behavior, unchanged.
- **`.client`** (`src/termio/Client.zig`) — proxies to the host over `AF_UNIX`.

Selected by the fork-only config key **`pty-host = <socket path>`** (consumed in
`src/Surface.zig` before either backend is constructed): non-null ⇒ `.client`. No
silent `.exec` fallback (see Goal status).

### The mirror (the central decision)

Under `.client` the renderer's source of truth is a host-supplied
**`terminal.RenderState` mirror, viewport-only by construction** — not a raw
`Terminal`. The wire payload is a **pointer-free `Snapshot`** (`src/host/RenderState.zig`),
serialized over framed `AF_UNIX` and rehydrated client-side into a `RenderState` the
renderer consumes unchanged. There is **no local scrollback buffer** on the client.

A `PageList.Pin` is a host pointer and **cannot cross the wire** (the mirror sets a
poisoned sentinel), so pin-dereferencing GUI paths are gated off and the **host
computes the result**: search highlights ride `row.highlights` on the frame; OSC8
links come via a `Hover`→`LinkFrame` round-trip; regex links work GUI-side because
they read cell *text*, not pins.

### One mutex for the mirror

The renderer reads the mirror under `renderer_state.mutex`; the `Client` read thread
writes it under the **same** mutex (passed via `Client.Config.render_mutex`). The
mutex/mirror pointers must reference the `Client` at its **final address** (after
`Termio.init` moves the backend union) — the wiring reaches into
`self.io.backend.client` *after* the move for exactly this reason.

### The render-tick push gate (the rule to remember)

`src/host/Session.zig` `renderTick` runs on a ~10 Hz poll timer as well as on real
output, and every captured `Snapshot` is `.full`, so the push is gated:

```
if (changed > 0 or force_push or cursor_changed) { push GridFrame + ModeFrame }
```

**Any new render-affecting host state must be added to this gate or it never reaches
the GUI.** This is the single most common bug class here — it caused the cursor,
search-clear, scroll-after-reattach, and mode-only-flip gaps. The current force-push
terms cover search, selection, viewport (scroll/jump), and mode changes; cursor moves
have their own `cursorEql` term. A freshly (re)attached GUI bypasses the gate via
`Server.pushFullFrames`.

**There is a SECOND, easy-to-miss gate in front of this one — the idle-CPU
`must_capture` capture gate.** To avoid the grid-sized Snapshot projection on idle
ticks, `renderTick` only PROJECTS a Snapshot when
`cells_dirty || force_push || cursor_state_changed || first-frame`; if it skips the
projection, the push gate above is never even reached. `cursor_state_changed` comes
from a cheap O(1) `cursorGateLocked()` / `CursorGate` read. **Every `cursorEql` field
that can change without dirtying a cell, without a scroll, and without a mode flip MUST
be in `CursorGate`, or the move is silently dropped until the next cell change.** This
bit us as **issue #2**: `CursorGate` originally omitted cursor **position** (x/y), so a
cursor-only move (arrow key, `setCursorPos`, advancing over pre-existing spaces — any
move the child app makes that the host cursor already reflects) left
`must_capture == false` — no Snapshot, so `cursor_changed` never fired and the GUI
cursor froze "until a non-space char is keyed" (a non-space dirties a cell ⇒ capture ⇒
the deferred move ships). NOTE: this is the *display* of an already-landed host cursor
move — distinct from the still-open R1 "Cursor-click-to-move at the prompt" row in the
Broken/missing table above (that is the GUI *translating* a mouse click into shell
cursor-movement keystrokes off the unfed local terminal; not fixed here). Fix: x/y are
now in `CursorGate` (read from
`t.screens.active.cursor.x/y`, the exact source the Snapshot's `cursor_x/y` derive
from). `cursor_cell`/`cursor_viewport` stay covered (cell-rewrite-under-steady-cursor ⇒
`cells_dirty`; scroll ⇒ `viewport_dirty`; a move ⇒ x/y). This was a HOST-ONLY
regression: a laptop whose deployed `ghostty-host` predated the idle-CPU optimization
was unaffected, while one with the newer host showed it (the GUI is identical; only the
host gates pushes). The snapshot-level `cursorEql` test always passed — the gap was that
nothing drove a cursor-only move through the real `renderTick`/`must_capture` path
(now covered by a regression test in `src/host/test.zig`).

### Resize, reattach, protocol

- **Resize** drives off the **authoritative wire `{cols, rows}`** the GUI rendered
  at (reconstructed by `Resize.toSize`), never re-derived from raw pixel
  `screen_w/h`. Degenerate frames (resolved grid below the 10×4 min-window floor) are
  **dropped** in `Server.dispatch` — a transient reattach frame must never reflow the
  real terminal.
- **Reattach** is keyed on `session_id` (random non-zero u64 per session; 0 =
  unattached — see `allocSessionId`). Forward via `ghostty_surface_config_s.session_id`;
  reverse via `ghostty_surface_session_id()`;
  persisted Swift-side as `sessionID` in `TerminalRestorable` (v8).
- **Protocol** (`src/host/protocol.zig`): length-prefixed binary frames; a `Hello`
  handshake is required before any stateful frame. **Frozen-ABI discipline:** keep
  the host tiny and stable and prefer additive, version-negotiated changes — a host
  rebuild kills every live shell it owns.
- **SurfaceEvent channel** (one `surface_event` frame) forwards the
  `apprt.surface.Message` set; the `Client` re-injects each so the GUI handles them
  as under `.exec`. Carve-outs: `child_exited` has its own dedicated frame (do not
  double-forward); `clipboard_read`/`report_title` responses ride the Input channel.

---

## Where the code lives

**Host** (`src/host/`): `main.zig` (`--listen=<path>`), `Server.zig` (listener +
session registry + subscriber routing + dispatch), `Session.zig` (one session:
Termio/Exec/Terminal + `renderTick` push gate + selection/clear/reset/at-prompt
handlers), `RenderState.zig` (`Snapshot` serialize/deserialize/rehydrate, `cursorEql`),
`protocol.zig` (frames, `Hello`, `Resize.toSize`), `difftest.zig` + `test.zig`.

**Client** (`src/termio/`): `Client.zig` (the `.client` backend), `backend.zig`
(the union), `Termio.zig`/`Thread.zig` (message routing), `message.zig`,
`client_difftest.zig`.

**Core wiring:** `src/Surface.zig` (backend selection on `pty-host`; mirror/mutex
wiring after the move; selection/scroll/clear/reset routing; `session_id` getter;
`needsConfirmQuit`), `src/renderer/generic.zig` (reads the mirror; pin paths gated;
highlight-tag validated), `src/config/Config.zig` (`pty-host` key).

**C-ABI / apprt:** `include/ghostty.h` (`session_id` field + getter),
`src/apprt/embedded.zig`. **macOS:** `SurfaceView.swift` / `SurfaceView_AppKit.swift`
(`sessionID` Codable), `TerminalRestorable.swift` (v8).

---

## Build, run, test, smoke

> Build/run **only** in `/Users/ramon/git/ghostty-phase2b`. Never touch
> `/Users/ramon/git/ghostty`. Never quit/launch the **installed Release** fork
> (`com.mitchellh.ghostty-ramon`) — it hosts the working session. Use the
> **ReleaseLocal** identity ("Ghostty (ramon-local)", `…ghostty-ramon.local`) for dev.

**Tests (fast, no app):**
```sh
zig build test -Demit-macos-app=false -Demit-xcframework=false -Dtest-filter=<host|client|Screen|Terminal>
```

**Build lib + host:**
```sh
zig build -Demit-macos-app=false -Doptimize=ReleaseFast   # -> zig-out/bin/ghostty-host
```

**Build the macOS app (ReleaseLocal):**
```sh
rm -rf macos/build/ReleaseLocal                 # REQUIRED — see the stale-binary trap below
macos/build.nu --configuration ReleaseLocal --action build
```

**⚠️ Stale-binary trap (cost a long debug session).** `build.nu` compiles into
DerivedData, then xcodebuild codesigns the output bundle. If that bundle carries
xattr/"resource fork detritus" (left by a prior manual `ditto`/`xattr`/`codesign`),
the codesign **fails** (`** BUILD FAILED **`, exit 65) and the freshly-linked binary
is **never copied over** — so the app you launch is **silently stale** (old behavior,
even though `zig build` succeeded). **Always `rm -rf macos/build/ReleaseLocal` first**
so build.nu produces a clean bundle and exits 0. To verify freshness: check the binary
mtime, and launch the binary **directly** (not via `open`) with `GHOSTTY_LOG=stderr`
redirected to a file — core libghostty `log.*` is invisible unless `GHOSTTY_LOG` is
set (it gates both the os_log path under subsystem=<bundle id> and the stderr path).

**Smoke (the headline feature — re-verify when resuming):**
1. Start the host: `./zig-out/bin/ghostty-host --listen=/tmp/ghostty-host.sock`
   (a fresh dev host; not the one hosting this session).
2. `pty-host = /tmp/ghostty-host.sock` in a config the dev app loads
   (`~/.config/ghostty-ramon/config` or a `--config-file`).
3. Launch ReleaseLocal; open a tab; start an observable long-lived process
   (`sleep 9999 & echo MARKER-$$`, or `vim`/`top`).
4. Quit **only** ReleaseLocal (`tell application id "com.mitchellh.ghostty-ramon.local"
   to quit`); leave the host running. Relaunch.
5. **Pass:** the tab reattaches to the still-running session (same marker PID, screen
   intact, scrollback present). **Fail:** a fresh shell, or a visible connect error.

### Dev notes (process)

- Workflow review/plan agents must be pinned `model: 'opus'` — the `Explore` agentType
  silently downgrades the model. Background multi-phase workflows kept dying on the
  180 s no-output watchdog during heavy Opus reads; main-loop build/test + a single
  foreground Opus review agent has been more reliable.
- The original implementation plan (`.claude/plans/ptyhost-implementation-plan.md`,
  the `§` cross-refs in old commit messages) is **not in this worktree**; this doc and
  the source comments are authoritative.
