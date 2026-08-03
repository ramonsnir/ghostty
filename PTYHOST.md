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

- **Why NOT at teardown.** The obvious hook — send Close when the surface's IO thread
  tears down (`Client.threadExit`) — DOES NOT work for a `.client` close: a closed
  surface's `SurfaceView` is RETAINED past the undo window (AppKit + the reattach
  machinery hold it), so `threadExit` never runs at the close-commit point (verified
  LIVE — the session stayed alive minutes after close). `threadExit` fires reliably only
  on app QUIT, where we correctly DETACH. So Close is sent over the **LIVE** connection
  at the **undo-commit boundary**, decoupled from teardown.

- **Send path (core).** A payload-less termio message `.close_session`
  (`src/termio/Message.zig`), dispatched by `Thread.zig` to `Termio.closeSession(td)` →
  `Client.closeSession(td)`, which sends a framed `protocol.Close` on the LIVE write
  stream — the same fire-and-forget path as `reset`/`clearScreen` — gated on
  (i) `role == .attach` (a `.mirror` dashboard preview NEVER closes) and
  (ii) `session_id != 0` (actually attached); `.exec` is a no-op (its real subprocess
  dies with its own teardown). `handleClose` is idempotent (unknown / already-removed id
  ⇒ no-op), so a Close racing the child's own exit is safe. `threadExit` is now the plain
  upstream DETACH (socket drop) and NEVER sends Close (locked by a test).
  `Surface.closeSessionNow()` queues the message; the C export
  `ghostty_surface_close_session_now` (→ `Ghostty.Surface.closeSessionNow`) reaches it.

- **Commit timing (macOS Swift).** The GUI does NOT send Close at the close gesture — it
  SCHEDULES it at the undo-commit boundary. `BaseTerminalController.applyCloseMark` keeps
  a per-view `pendingCloseCommits` (`[ObjectIdentifier: DispatchWorkItem]`): `.set`/`.redo`
  (re)schedule a main-queue timer at `closeCommitDelay(undoExpiration)` — the undo window
  plus a 0.5s margin so the commit fires strictly AFTER the undo action expires (⌘Z can no
  longer race it) — whose block calls `view.surfaceModel?.closeSessionNow()`; `.undo`
  CANCELS the pending commit (⌘Z restored a LIVE session, which must stay alive +
  reattachable); a re-mark supersedes a stale pending commit. The work item
  strong-captures the view, so the surface stays alive until the Close is actually sent,
  then releases it. On a real quit the process exits before any pending timer fires ⇒
  those sessions DETACH (no `app_quitting` belt needed — process death is the backstop).

- **The last-window-close → DETACH guarantee is a MARK-TIME prediction.** A last-window
  explicit close that TRIGGERS app termination must detach (keep sessions for reattach),
  not destroy. The load-bearing signal is
  `TerminalController.windowCloseTriggersAppTermination()` (pure core
  `windowCloseWouldTerminate(shouldQuitAfterLastWindowClosed:remainingTerminalWindowCount:)`
  = quit-after-last-window AND no other terminal window remains): when true, A3 schedules
  NOTHING. This is stateless and independent of teardown-vs-`willTerminate` ordering.
  Belt-and-suspenders comes for free from the commit being a deferred timer: even if a
  termination path DID schedule a commit, the process exits before the timer fires, so
  the session detaches. cmd+Q itself never schedules (its teardown path doesn't route
  through `closeSurface`/`close*Immediately`).

- **Schedule plumbing (macOS Swift).** The schedule is centralized in
  `BaseTerminalController.replaceSurfaceTree(closingViews:)` — threaded from
  `removeSurfaceNode(deliberateClose:)` and FORWARDED to `super` by the
  `TerminalController.replaceSurfaceTree` override — so a split `close → undo → redo`
  re-schedules (the undo closure cancels the pending commit; the nested redo re-invokes
  `replaceSurfaceTree` with the same `closingViews`). **Root** split closes are
  intercepted by `closeSurface` and routed to `closeTab`/`closeWindow`, so the override's
  **empty-tree branch is reached ONLY by MOVES** — it closes the emptied tab via
  `closeTabImmediately(markLeaves: TerminalController.moveEmptiedSourceMarksLeaves)` (a
  NAMED, tested `false` constant — the sole protection for the reparented live view,
  which the `viewHeldByAnotherController` backstop cannot yet catch), never scheduling it.
  A tab close (`closeTabImmediately(markLeaves:)`, A2) and a window close
  (`closeWindowImmediately(markLeaves:)`, A3) fan the schedule out to EVERY leaf of every
  controller in the tab group — **including zoom-hidden splits** (`root.leaves()`) —
  before each tree is emptied; their redo re-schedules by re-invoking `close*Immediately()`,
  and the `with: undoState` restore init cancels the pending commit on the restored leaves.
  `closeWindowImmediately`'s decision runs through the pure
  `TerminalController.shouldMarkLeavesOnClose(isMoveEmptiedSource:triggersAppTermination:)`
  (schedules iff NOT a move AND NOT app-terminating). **All of it funnels through ONE
  place:** `BaseTerminalController.applyCloseMark(_ phase:_:)` runs the pure, generic,
  per-phase decision `closeMarkOperations(_:closingViews:heldElsewhere:)` — `.set`/`.redo`
  yield `close=true` for every non-held leaf (schedule a commit), `.undo` yields
  `close=false` for EVERY closing leaf unconditionally (cancel — the data-loss-safe
  direction), a move (`nil`) is a no-op — then schedules/cancels the per-view
  `pendingCloseCommits` timer directly. A recorder + `MockView` test drives
  `.set → .undo → .redo` through `closeMarkOperations` to observe the
  schedule → cancel → re-schedule ordering with no live controller/surface.

- **EXCLUDED — moves + mirrors never commit.** Every reorganization that reparents a LIVE
  `SurfaceView` (`move_split_to_new_tab`, `pull_marked_split`, `merge_tabs`, `swap_split`,
  queue pack/adopt/promote/demote, cross-window drop, `retileCompactGrid`) calls
  `removeSurfaceNode` with `deliberateClose: false` (→ `closingViews == nil`) AND, if it
  empties a source, hits the override's `markLeaves: false` branch. A defense-in-depth
  `viewHeldByAnotherController` backstop additionally skips any leaf already held by
  another live controller. `.mirror` clients are double-gated even if somehow scheduled
  (they are dashboard-preview surfaces, never tab leaves): `Client.closeSession`'s role
  gate + the host's render-only-subscriber refusal.

- **Undo safety.** The undo state retains the live `SurfaceView`s until undo expiry; a
  `close → undo` cancels the pending commit before it fires, and process death on a real
  quit preempts any still-pending commit. The commit's 0.5s margin past `undoExpiration`
  guarantees the timer never fires while ⌘Z is still possible.

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

- Wiring: core `src/termio/Message.zig` (`.close_session` message), `src/termio/Thread.zig`
  (dispatch → `io.closeSession`), `src/termio/Termio.zig` (`closeSession` backend router,
  `.exec` no-op), `src/termio/Client.zig` (`closeSession` live Close send + plain
  detach-only `threadExit`), `src/Surface.zig` (`closeSessionNow` → `queueIo(.close_session)`),
  `src/apprt/embedded.zig` + `include/ghostty.h` (`ghostty_surface_close_session_now`).
  macOS `Ghostty.Surface.swift` (`closeSessionNow`), `AppDelegate.swift`
  (`shouldQuitAfterLastWindowClosed`), `BaseTerminalController.swift`
  (`pendingCloseCommits` + `closeCommitDelay` + `viewHeldByAnotherController` +
  `leavesToMarkForClose` + `closingLeaves` (the primary deliberate-vs-move mapping) +
  `CloseMarkPhase` + `closeMarkOperations` (the pure per-phase decision) + `applyCloseMark`
  (the ONE funnel: schedules/cancels the timers) + `markLeavesForClose` +
  `removeSurfaceNode(deliberateClose:)` + `replaceSurfaceTree(closingViews:)`),
  `TerminalController.swift`
  (`replaceSurfaceTree` override + `moveEmptiedSourceMarksLeaves` (named empty-branch
  constant) + `shouldMarkLeavesOnClose` (window-close schedule predicate) +
  `closeTabImmediately(markLeaves:)` +
  `closeWindowImmediately(markLeaves:)` + `closeAllWindowsImmediately` — forces
  `markLeaves: false` across the batch when the close-all quits the app, so every window
  DETACHES uniformly at schedule time — + `windowCloseTriggersAppTermination` /
  `windowCloseWouldTerminate` + the `with: undoState` commit cancel). Tests: Zig
  `src/termio/client_difftest.zig` (deliberate close sends a LIVE Close; mirror/unattached
  send none; plain teardown never sends Close), `src/host/test.zig` (Close idempotency),
  Swift `macos/Tests/Terminal/CloseSessionLifecycleTests.swift`
  (`leavesToMarkForClose` + `closingLeaves` move-exclusion; `closeMarkOperations`
  recorder schedule → cancel → re-schedule ordering + move-never-commits + held-elsewhere
  filter; `moveEmptiedSourceMarksLeaves` == false; `shouldMarkLeavesOnClose` matrix;
  `windowCloseWouldTerminate` matrix; `closeCommitDelay` boundary; zoom-hidden leaf
  enumeration).

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

**Cloud-hosts (Phase 1) — per-surface socket override + `(host, session_id)` identity.**
The socket is no longer only the GLOBAL `pty-host` scalar: `Surface.init` now resolves it
via `termio.Client.resolveSocketPath(per_surface_sock, config.@"pty-host")`, where
`per_surface_sock` comes from the additive `rt_surface.pty_host_socket` field (carried from
`ghostty_surface_config_s.pty_host_socket` / `apprt.Surface.Options.pty_host_socket`, read
via `@hasField` so apprts without it compile to "global only"). A per-surface override WINS
over the global scalar, so a *cloud* split dials a GUI-resolved SSH-forwarded local socket
while local splits use the global host. A paired additive `host_name` field
(`ghostty_surface_config_s.host_name` → `apprt.Surface.Options.host_name` → `Client.Config.host_name`,
duped/freed like `socket_path`) records the **identity label** of the host this surface runs
on; nil ⇒ the reserved name `local`. Together `(host_name, session_id)` is the reattach/persistence
key across a GUI restart (the session_id is a RANDOM non-zero u64 minted host-side by
`allocSessionId`; `0` = "no session"). `Client.Config.reconnect` (default false) now DRIVES the
Phase-2 redial state machine (see the next subsection); the GUI auto-sets it true ONLY for a
resolved REMOTE `.attach` surface (a per-surface socket override present + role `.attach`), so a
`local`/nil host and all mirrors stay `reconnect=false`. **FORK(host-handoff):** its sibling
`Client.Config.handoff_redial` (default false) is the INVERSE — auto-set true for a resolved LOCAL
`.attach` surface (no per-surface socket override + role `.attach`) — and drives the SAME redial
machine but with a FINITE cap (P2 subsection below); a `.mirror` gets neither, and both-false is the
byte-for-byte single-shot local path.

**Deferred dial for a RESTORED/launched REMOTE surface.** The `.client` connect is single-shot
(no retry — `connectAndAttach`), so a remote surface must NOT eagerly dial: its SSH tunnel may
be down at restore time and would blank the pane. Instead the macOS `SurfaceView` resolves the
host THREE ways (`resolveHost`): nil/`"local"` ⇒ the unchanged eager local dial; a name in the
`pty-remote-host` registry ⇒ leave `self.surface` nil, stash the deferred-dial inputs, subscribe
to the tunnel supervisor's readiness signal (a full Hello→HelloAck handshake via `ghostty_probe_host`),
and run the single `ghostty_surface_new` in `materializeClientSurface` once it handshakes; a name
NOT in the registry ⇒ an error state (never a local-socket fallback or a spawn). The GUI-lib-only
`ghostty_probe_host` (backed by `termio.Client.probeHost`, reusing the real `protocol.zig` codec)
is never compiled into `ghostty-host`. `hostName` is persisted in the surface archive only for a
non-local surface; `ptyHostSocket` is NOT persisted (re-resolved from `hostName` on restore).
Full design + wiring: `CLOUD-HOSTS-DESIGN.md` / `CLOUD-HOSTS-IMPL-PLAN.md` and the CLAUDE.md
cloud-hosts summary bullet.

**Cloud-hosts (Phase 2) — mid-session redial for REMOTE hosts ONLY.** Phase 2 REVERSES the
deliberate single-shot decision **for remote hosts only** — a `local`/nil host stays
**byte-for-byte single-shot** (the KeepAlive LaunchAgent is ≈always up, and a dropped local host
can't restore RAM-only sessions anyway; `reconnect=false` ⇒ none of the machinery below is armed).
A remote forwarded socket, by contrast, vanishes on every sleep / WiFi roam / Tailscale reconnect
while the remote session is perfectly alive, so a remote `.attach` opts into a redial machine:

- **Surface-visible state channel (`termio.Client.State`, five states).** Backed by `enum(c_int)`
  so it maps 1:1 to the C `ghostty_client_state_e` the macOS overlay reads via the lock-free
  `ghostty_surface_client_state` accessor: `ok` (normal / `.exec` / local), `reconnecting` (drop
  in flight — also the "hold outbound frames" gate), `session_ended` (reattach returned a
  DIFFERENT session id ⇒ host restarted, prior session gone), `cannot_handshake` (connected but
  EOF before any `HelloAck` — ambiguous: starting up / down / incompatible), `too_old` (decoded a
  `HelloAck` with a mismatched MAJOR — confident + directional), `unreachable` (the `connectUnix`
  dial failed). Stored in a `std.atomic.Value` (not renderMutex), written by the read thread's
  drop classification + the redial machine, read UNLOCKED by `queueWrite`/`sendFrame` (hold/drop
  on `.reconnecting`) and by the Swift accessor. `setClientState` also wakes the renderer so the
  overlay repaints.
- **The redial runs ENTIRELY on the IO/xev-loop thread.** The write path (write_stream + queue +
  the two `SegmentedPool`s + the socket fd) is IO-thread-owned and read unlocked by `queueWrite`,
  so tearing it down + rebuilding it from the READ thread would be a cross-thread UAF + an illegal
  concurrent xev submission. Instead the read thread (or a failed `writeCallback` — the ONLY
  timely signal a BLACK-HOLED tunnel gives) merely sets the `.reconnecting` hold-gate and
  `notify()`s a thread-safe `xev.Async` (`reconnect_async`), then exits. The async callback runs
  the state machine on the loop thread (serialized with `queueWrite`/`writeCallback`):
  `teardownConnection` (join the old read thread via its quit pipe, close the old fd + pipe with
  `-1` sentinels so `threadExit`/`deinit` never double-close, reset the reader + `ack_seen`) →
  `scheduleReconnect` → `attemptReconnect` (fresh `connectUnix` + pipe, rebuild `write_stream`,
  respawn the read thread, re-`Hello`+`Attach` via `sendFrameRaw` which BYPASSES the
  `.reconnecting` gate). **⚠️ Stale-completion guard in `writeCallback`:** the write pools + queue
  are LEFT INTACT across `teardownConnection` (a pending completion from the pre-drop connection
  must fire to reclaim its slot), so an ERROR completion for the OLD fd can land AFTER a redial has
  already rebuilt a healthy connection — tripping the redial from it would tear that healthy
  session down. So `writeCallback` trips the redial ONLY when the completion's own fd
  (`streamFd(s)`, recovered from the `xev.Stream` the callback receives) equals the live
  `read_thread_fd`; a stale completion (torn-down fd) is ignored, making correctness independent of
  xev's completion-drain ordering rather than resting on the ≥1s backoff usually draining old-fd
  errors first.
- **Reattach, not re-spawn (`reattachId`).** The redial's `Attach` reattaches to the LIVE
  host-assigned id if we have one, else the configured/persisted id, else a FRESH spawn (null) —
  NEVER a blind re-Attach that would spawn+orphan a second session. The host's
  known-vs-returned-id check (the `.attached` arm) flips the state to `session_ended` on a miss
  (and does NOT adopt the fresh id), or `.ok` on a hit. **⚠️ The `session_ended`-on-miss arm is
  GATED on `Config.reconnect` — i.e. a REMOTE `.attach` surface ONLY.** The overlay that makes
  `session_ended` visible is mounted only for a remote surface, so a LOCAL `.client` attach must
  NOT take that path (it would leave a silent, unexplained dead pane with `session_id` pinned to
  the gone id). A local reattach-miss instead keeps Phase-1 semantics: fall through and ADOPT the
  host's fresh id → a usable fresh shell (the local host-restart-across-GUI-restart behavior).
- **The backoff is an `xev.Timer` on the loop — NEVER a bare `sleep` (settled OQ7).** `reconnectDelayMs`
  is a quick exponential burst (1,2,4,8,16,30s) for the first `RECONNECT_QUICK_ATTEMPTS`, then a
  steady 60s cadence FOREVER (never gives up while the surface wants the host), always > 0. A
  clean quit stops the loop, which cancels the timer (the callback sees `error.Canceled`); the
  read thread `poll()`s its quit self-pipe (Darwin has no eventfd). A per-attempt **handshake
  watchdog** (`xev.Timer`, ceiling = `Config.connect_timeout_s`, 0 ⇒ compiled
  `DEFAULT_CONNECT_TIMEOUT_S`=10s) fires if no `HelloAck` arrives after a connect — the only
  detector for a tunnel that connected then went silent WITHOUT a read-side EOF — and re-triggers
  the redial. The per-attempt ceiling is the fork config `pty-remote-connect-timeout`.
- **GUI-only.** `Client.zig`, the surface Options field, the probe, and the state accessor are NOT
  compiled into `ghostty-host` — so this is a lib/xcframework rebuild + GUI relaunch, **no host
  restart / no session loss.** Full wiring + tests: `CLOUD-HOSTS-DESIGN.md` /
  `CLOUD-HOSTS-IMPL-PLAN.md` and the CLAUDE.md cloud-hosts bullet.

**P2: GUI local handoff-redial (`Config.handoff_redial`) — a BOUNDED reuse of the Phase-2 machine
for a same-machine host handoff.** When the local `ghostty-host` hands its live sessions to a
successor process (the marshal + detach/adopt of the "Host handoff" section below, later phases),
the GUI's socket to the OLD host drops for ~1-3s while it reconnects to the successor and reattaches
by `session_id`. Phase 2 armed the redial machine for REMOTE hosts only; P2 lets a LOCAL `.attach`
surface survive that brief gap **without** turning a local pane into a forever-redialing remote one.
All fork additions are marked `// FORK(host-handoff):`.

- **A NEW, DISTINCT flag: `Client.Config.handoff_redial` (default false).** Kept separate from
  `reconnect` so the two never conflate: a remote surface is `reconnect=true, handoff_redial=false`
  (redial forever, `session_ended` + overlay); a LOCAL `.attach` surface is `handoff_redial=true,
  reconnect=false`; a `.mirror` gets NEITHER. `handoff_redial=false && reconnect=false` is
  byte-for-byte today's single-shot local path.
- **One derived arming predicate: `Config.wantsRedial()` = `reconnect or handoff_redial`.** Every
  site that previously ARMED the machine on `reconnect` now arms on `wantsRedial()`: the
  `reconnect_async`/timer creation in `connectAndAttach`, the `onAttachDrop` notify, and the
  `classifyDrop` first arg (so a local handoff drop also goes `.reconnecting` and HOLDS keystrokes
  across the gap via the `queueWrite`/`sendFrame` hold-gate, instead of dropping them). The remaining
  machinery — the IO-thread ownership, the `xev.Timer` backoff, the black-holed-write trip + the
  stale-completion guard in `writeCallback`, the handshake watchdog, `reattachId` — is REUSED
  unchanged.
- **FINITE retry cap (`shouldKeepRedialing`, pure + unit-tested).** The one behavioral divergence
  between the two armed cases. A remote `reconnect` client redials FOREVER (quick burst → steady 60s
  cadence — UNCHANGED). A handoff-redial-ONLY client (`handoff_redial && !reconnect`) redials only a
  bounded burst of `RECONNECT_HANDOFF_MAX_ATTEMPTS = 3` dials (delays 1s,2s,4s ≈ 7s wall — covers a
  1-3s handoff gap) and then STOPS — it must NOT fall into the steady-60s-forever cadence, which
  would storm a genuinely-dead local KeepAlive host. The cap is enforced in `scheduleReconnect`:
  when exhausted it logs "gave up", stops scheduling, and leaves the surface on its FROZEN last frame
  (no overlay locally, and **NEVER** an `.exec` fallback). It deliberately leaves `redial_in_flight`
  set so the `reconnectAsyncCallback` coalesce guard permanently locks out further dials; the
  last-set state is `.@"unreachable"` (≠ `.reconnecting`, so input is not held forever). A successful
  reconnect resets the attempt counter, so each distinct handoff gap gets its own fresh burst.
- **`session_ended`-on-miss stays gated on `Config.reconnect` ALONE** — deliberately NOT
  `wantsRedial()`. On a SUCCESSFUL handoff the successor re-registers each session under its ORIGINAL
  id, so `reattachId` HITS → `.ok` (no miss). A genuinely-unknown id on a local redial (an
  aborted/failed handoff) falls through to the Phase-1 adopt-the-fresh-id behavior — NOT the remote
  dead-pane `session_ended` state, which local has no overlay to render.
- **Where the flag is set: `src/Surface.zig`**, the exact INVERSE of the remote `reconnect` gate and
  derived purely in Zig from the same inputs (`per_surface_sock`, `client_role`) — so it does **NOT**
  cross the C ABI / apprt Options (like `reconnect`, it is computed in the core, not carried on the
  surface). `.reconnect = per_surface_sock != null and client_role == .attach;` /
  `.handoff_redial = per_surface_sock == null and client_role == .attach;` — for an `.attach`
  surface exactly one is true; a `.mirror` gets neither; never both.
- **GUI-only, same as Phase 2** (`Client.zig` + the `Surface.zig` derivation are not compiled into
  `ghostty-host`): lib/xcframework rebuild + GUI relaunch, no host restart. Pure-helper tests
  (`shouldKeepRedialing`, the `classifyDrop` derived arg) + the arming test live in
  `src/termio/client_difftest.zig`.

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

## Host handoff: full-fidelity session serialization (`src/host/session_transfer.zig`)

A **HOST** restart otherwise loses every RAM-only session (see the goal-status
caveats above). The foundation for surviving it is a **same-build**
serialize/deserialize of the live `terminal.Terminal`: the running host marshals
each session's full emulation state to pointer-free bytes; a successor process
built from the **identical** binary rebuilds an *equal* `Terminal`.

- **Same-version contract, not a schema.** Both ends are the same build, so there
  is no cross-version compatibility layer. `session_transfer.serialize` writes a
  `MAGIC` (`"GHOSTHH"`+version) then a **layout fingerprint** — the `@sizeOf` of
  every type whose raw bytes ride the wire (`Terminal`, `Screen`, `PageList`,
  `Page`, `Row`, `Cell`, `Pin`, `Style`, `ModePacked`). `deserialize` asserts both
  and returns `HandoffBadMagic` / `HandoffLayoutMismatch` on drift — refuse rather
  than decode garbage.
- **The approach mirrors `clone()`.** The (de)serialize methods reproduce the
  structural walk of `PageList.clone`/`Screen.clone` (iterate pages in order,
  allocate fresh nodes via `createPageExt`, remap tracked pins by location) but
  redirect source/destination to a byte stream — and, unlike clone, carry the
  **whole** pagelist (all scrollback), the scroll/viewport position, and the full
  cursor (style, active hyperlink), not just clone's read-only subset.
- **A page is a raw memcpy.** A page's interior is entirely offset-based, so each
  page serializes as its struct bytes + its `memory` block; on rebuild the only
  absolute pointer, `memory`, is re-pointed and the offset interior (styles,
  graphemes, hyperlinks, string_alloc) "just works". `verifyIntegrity` is run on
  every rebuilt page. **Pins** (cursor, selection endpoints, viewport, kitty
  placements) are serialized as `(page_index, x, y)` and re-tracked after the
  page list is rebuilt.
- **Coverage.** Every `Terminal` field: both screens (primary + optional
  alternate) + which is active, sizes/px, modes (+saved/default), scrolling
  region, tabstops (prealloc + dynamic bits), charsets, colors/palette, flags,
  `previous_char`, `status_display`, `mouse_shape`, pwd/title, the fork-only
  `glyph_glossary` (decoded glyf outlines), and per-screen: no-scrollback, saved
  cursor, selection, protected mode, kitty keyboard stack, semantic prompt, dirty,
  and kitty `ImageStorage` (images = id→pixels+metadata; placements = pinned or
  virtual). **Deliberately deferred:** kitty `ImageStorage.loading` (a
  partially-transmitted, mid-escape-sequence image) — a rare transient; dropping
  it ignores the next continuation chunk rather than corrupting state.
- **The fork additions are marked** `// FORK(host-handoff):` and are co-located
  with `clone()` in the terminal files (they need private access). A shared helper
  `src/terminal/serial.zig` provides the raw-POD / length-prefixed primitives
  (with a comptime pointer-free guard so a pointer can never be raw-serialized).
  Round-trip tests live in `session_transfer.zig` (reached from `host/main.zig`).
  `session_transfer.zig` is platform-neutral (compiles on the Linux cloud box).

### The pty-master DETACH + ADOPT path (`Exec.zig` / `Termio.zig` / `Session.zig`)

The serializer above rebuilds the *screen*. This path hands off the *live pty +
child*: a predecessor gives up its pty master fd (without killing the child or
closing the master), and a successor builds a Session around that master fd + the
still-running child pid + the rehydrated `Terminal`, continuing the SAME shell.
Everything is **additive and gated** — with neither flag set, the `.exec` runtime
is byte-for-byte unchanged. All fork additions are marked `// FORK(host-handoff):`.

- **Extract (predecessor).** `Session.masterFdForHandoff` / `childPidForHandoff`
  read stored state only and forward through `Termio` → `Exec`. For a FRESH session
  the master comes from `subprocess.pty.master` and the pid from the `fork_exec`
  Command; for an ALREADY-ADOPTED session (`subprocess` is empty) they surface
  `Exec.adopt.{master_fd,child_pid}` instead — so a **successor can itself become a
  predecessor** (a chained worker swap). The caller `dup`s the master (or passes it
  via `fdpass.zig`/SCM_RIGHTS) and serializes the `Terminal` **before** detaching —
  detach neutralizes the subprocess (and nulls `Exec.adopt`), after which the
  accessors return null.
- **DETACH (predecessor).** `Session.detachForHandoff` sets `Exec.detach_requested`
  then `stop()`s. `Exec.threadExit` sees the flag and: nulls `subprocess.pty` +
  `subprocess.process` **and `self.adopt`** (so the later `Exec.deinit`→
  `subprocess.deinit` neither closes the master via `pty.deinit` nor SIGHUPs via
  `subprocess.stop`, and — for an adopted session — the adopt-teardown branch is
  skipped, so a handed-off master is never closed / a handed-off child never
  SIGHUP'd), stops the read thread the normal way, and returns. The master stays
  open (ownership moved to the caller) and the child stays alive. The flag is set
  before `stop()` so the IO thread reads it in `threadExit` after observing the
  stop-notify barrier (same non-atomic cross-thread convention as
  `termios_timer_running`).
- **ADOPT (successor).** `Session.adopt(alloc, opts, master_fd, child_pid,
  terminal)` mirrors `create` (both go through `createInternal`) but: sets
  `Exec.adopt = .{ master_fd, child_pid }`, passes the rehydrated terminal as
  `termio.Options.adopt_terminal`, and skips the `working_directory`/`initial_input`
  spawn-opts (an adopted shell must not be re-fed a command). `Termio.init` uses the
  provided terminal verbatim (taking ownership) and skips the fresh-terminal
  defaults (cursor style / pixel size) that would clobber restored state.
  `Exec.threadEnter` skips `subprocess.start`, sets `pty_fds.read = .write =
  master_fd`, builds the exit watcher via `xev.Process.init(child_pid)` (macOS/Linux
  watch ANY pid), and runs the rest (kill pipe, write stream, termios timer, read
  thread, `process.wait`) unchanged. The read thread immediately drains any bytes
  buffered on the master since the predecessor stopped (shared kernel read pointer
  across dup/SCM_RIGHTS — the single-active-reader invariant). GUI resizes reach the
  shell because `Exec.resize` special-cases an adopted Exec (TIOCSWINSZ directly on
  `master_fd`, since `subprocess.pty` is null).
- **Lifecycle / no leaks.** On a normal `.exec` close the child is SIGHUP'd + reaped
  by `subprocess.stop` and the master closed once by `subprocess.deinit`→`pty.deinit`
  (unchanged). On **detach** neither happens (ownership moved). On an **adopted**
  session's close, `subprocess` was never started (pty==null, process==null), so
  `Exec.threadExit`'s adopt branch does both itself: `Subprocess.killPid` SIGHUPs +
  reaps the child (unless the watcher already saw it exit), then — after the read
  thread has joined — `posix.close(master_fd)` closes it EXACTLY once, and **nulls
  `self.adopt`** so a later `Exec.deinit` does not repeat it. `xev.Stream` never owns
  the fd (its `deinit` is a no-op), so it is never a second closer.
- **Never-started adopted session (`Exec.deinit` release + the ownership contract).**
  A `Session.adopt`-built session OWNS the master fd + child, but an owner thread that
  would run `threadExit` might never spawn (an OOM / thread-spawn failure in
  `Server.registerAdoptedSession`), so `Session.destroy` runs `Exec.deinit` with no
  `threadExit` ever having fired — which would LEAK the master + ORPHAN the child.
  `Exec.deinit` therefore releases the adopt resources itself when `self.adopt` is
  still set (close master + `killPid` SIGHUP/reap). It is **exactly once** by a
  case matrix: (a) normal `.exec` → `adopt==null`, skip; (b) started+closed →
  `threadExit` consumed + nulled it, skip; (c) started+detached → detach nulled it
  (master handed off), skip; (d) never-started → still set → release here. The
  no-double-close hinges on the **ownership contract**: `Session.adopt`
  (`createInternal`) sets `Exec.adopt` only as its LAST, post-`Termio.init` statement
  — so `adopt` is set **iff construction fully succeeded**. On ANY mid-construction
  failure `adopt` stays null, so neither the internal `io_exec.deinit` errdefer nor
  the tail `self.io.deinit()` touches the master, and the CALLER that passed the fd
  (`handleAdopt`/`handleUnfreeze`, which `posix.close(master_fd)` on a `Session.adopt`
  error) closes it exactly once. Regression test: "host handoff: destroy an adopted
  session that was NEVER started…".
- **Adopt-INIT FAILURE (task #7).** `Exec.threadEnter`'s adopt-path errdefer (runs
  only on a mid-init failure of the successor) closes **only** the successor's
  master-fd copy — it must **NEVER** SIGHUP the child. During a handoff the child
  still belongs to the PREDECESSOR (which kept it alive and, on abort, `unfreeze`s —
  re-adopts — its frozen sessions); killing it in the failing successor would
  destroy the incumbent's live session out from under the recovery. (The NORMAL
  adopted-close teardown above still SIGHUPs on a real close — only this mid-init
  failure path is SIGHUP-free.)
- **Tests.** `src/host/test.zig` has two layers of in-process integration tests
  (local `dup` models the fd pass). (1) The PRIMITIVE test "host handoff: detach a
  session and adopt it into another; real shell survives host": Session A spawns a
  real shell, drives a marker, is extracted + detached + destroyed; Session B adopts
  the dup'd master + pid + deserialized Terminal and asserts (a) B's screen incl.
  scrollback equals A's dump, (b) a NEW command typed to B runs (same shell alive),
  (c) on B's close the child is reaped (`kill`→ESRCH) and no fd is leaked. (2) The
  SEQUENCE tests "host handoff sequence: …" drive a MOCK SUPERVISOR (the test thread)
  against real `Server` workers over control `socketpair`s, each worker running its
  real control loop: **success** (v1 freezes, hands up; v2 adopts under the same id;
  same shell survives a second marker; `shutdown` v1; net-zero fds), **unfreeze**
  (v1 freezes; handoff aborts; v1 re-adopts + resumes; child never killed), and
  **task #7** (v2's adopt FAILS on a corrupt blob → v1's child stays alive → v1
  `unfreeze` recovers). Each is deterministic (poll for frozen-drain / session
  reappearance before the fd check) and asserts net-zero open fds vs a warmed
  baseline.
- **Cross-process caveat.** `killPid`'s `waitpid` reap works in-process (the child
  is our child). A real cross-process successor is not the child's parent (the child
  re-parents to init when the predecessor exits), so it can SIGHUP but not reap; the
  supervisor (which the child re-parents to, if it double-forks the workers) owns
  that concern in a real deployment.

### The supervisor↔worker CONTROL path (`src/host/Server.zig`)

The DETACH+ADOPT primitives above are driven, in a real handoff, by a session-less
**supervisor** that brokers the swap between an OLD worker (predecessor) and a NEW
one (successor) over an inherited `socketpair` using the `handoff_protocol.zig`
codec + `fdpass.zig` (`SCM_RIGHTS`). This is the **worker half**, cohesive with the
`Server` (which owns the session registry). Everything is **additive + gated**:
`Server.control_fd == null` (the standalone worker + every existing test) makes the
whole path inert and byte-for-byte unchanged. macOS-only (rides the Darwin cmsg
ABI): every body is inside `if (comptime builtin.os.tag == .macos)` so it is never
analyzed on the Linux host (verified by a Linux cross-compile).

- **Announce.** The session owner thread (`sessionOwnerThread`), once `start()`
  succeeds, calls `announceSpawnedMaster` — it polls briefly for the pty (it opens
  async on the IO thread's `threadEnter`, racing `start()` returning), then
  `Server.notifySessionSpawned` sends `register_master{session_id, aux=child_pid}` +
  a **dup** of the master UP the control fd, so the supervisor holds its own master
  copy (SIGHUP insurance + the source fd for a future `adopt`). Gated on
  `control_fd != null` **AND** `SessionEntry.announce_master` — TRUE for a fresh
  `spawnSession`, FALSE for a `registerAdoptedSession` (adopt/unfreeze): a successor
  must NOT re-announce a session the supervisor already tracks (it would corrupt the
  registry AND interleave a `register_master` into the `adopt_ack`/`ready` stream the
  broker reads). `notifySessionSpawned` is **idempotent** — an `announced_masters`
  set (guarded by `control_write_mutex`, marked only after a successful send) makes a
  redundant announce (e.g. the in-process handoff-sequence tests that ALSO call it) a
  no-op, so a session is registered EXACTLY once. On an explicit close
  `Server.notifySessionClosed` sends `unregister_master` (from `handleClose` —
  deliberately NOT `teardownEntry`, which the freeze path also uses: a freeze hands
  the master off, it does not close it) and drops the dedup mark. All
  worker→supervisor writes serialize on `control_write_mutex`.
- **`freeze_all` (S→predecessor).** For each live session: extract master + pid,
  `detachForHandoff` (joins the IO thread → the Terminal is single-threaded, exactly
  the adopt-test order), `session_transfer.serialize` the Terminal under
  `render_mutex`, send `session_state{id, aux=blob_len}` + the blob UP (NO fd — the
  supervisor already holds a master dup), RETAIN `{own master fd, child pid, blob}`
  in the `frozen` map for a possible `unfreeze`, and DESTROY the now-serialized
  Session (which, post-detach, leaves the master open + the child alive). Then
  `freeze_done{aux=count}`. The retained master fd is the session's OWN master, kept
  open across the detach+destroy.
- **`adopt` (S→successor).** `{session_id, aux=blob_len, aux2=child_pid}` + a master
  fd (SCM_RIGHTS) + the blob → `deserialize`, `Session.adopt(master_fd, child_pid,
  terminal)`, register under the ORIGINAL session_id (`registerAdoptedSession` — the
  adopt analogue of `spawnSession`'s tail, locking `registry_mutex` itself since the
  control loop holds no lock), start its owner thread, `adopt_ack{ok=1}`, then
  `ready{live_count}`. On a deserialize/adopt FAILURE only the master-fd copy is
  closed (the child is the predecessor's — left alone) and `adopt_ack{ok=0}` is sent.
- **`shutdown` (S→predecessor).** The successor is serving: DESTROY the frozen state
  — close each retained master fd, drop each blob — but do NOT SIGHUP the children
  (the successor owns them now). Break the control loop; the process exits.
- **`unfreeze` (S→predecessor).** The handoff ABORTED: for each frozen session
  `deserialize` the kept blob and `Session.adopt(own master fd, child pid, terminal)`,
  re-register + start — resuming service on the SAME live children (the "incumbent
  survives a failed successor" path).
- **Threading.** `startControlLoop` spawns `controlLoop` (recvFrame →
  `handleControlFrame` until `shutdown`/`deinit` clears `control_running`, or the
  socket closes); the handlers are `pub` so the in-process test drives them without
  the loop. `joinControlLoop` (used by WORKER mode) blocks on the control thread
  until it exits on its OWN (a `shutdown` frame or the supervisor dropping the
  channel), nulling `control_thread` so the following `deinit` does not re-join.
  `deinit` stops+joins the control loop FIRST (it can spawn/destroy sessions), then
  drops any still-frozen state (close fds, free blobs) and closes `control_fd`.
  `frozen` is guarded by `registry_mutex`; a test-only `frozenCountForTest` lets a
  test wait for an async `shutdown`/`unfreeze` to drain.

### The SUPERVISOR process (`src/host/Supervisor.zig`) + one-binary-three-modes

The session-less supervisor is the OTHER half — the launchd job that drives the
worker-side control path above. It and the worker are the **same `ghostty-host`
binary** in different argv modes (no second build target); `main_host.zig`'s `main`
parses the mode via the pure `Supervisor.parseMode` (unit-tested) and dispatches:

- `--supervise --listen=<path> [--worker=<path>]` → `runSupervise` → the supervisor.
- `--handoff-worker --listen-fd=<N> --control-fd=<M> [--listen=<path>]` → worker mode:
  `Server.initFromListenFd(path, N, owns_path=false)` + `startControlLoop(M)` +
  `joinControlLoop` (serve until a `shutdown` frame / dropped channel), then exit(0).
- `--listen=<path>` alone → the pre-existing standalone Server (byte-for-byte).
- else → the pre-existing Phase-1 stdout-diff. The two new modes are checked FIRST
  because their argv ALSO carries `--listen=`.

The supervisor is **macOS-only** (rides the Darwin cmsg handoff); off macOS every
body is a comptime-dead `if (comptime builtin.os.tag == .macos)` block / an early
`error.Unsupported`, so the `src/host` tree still compiles on the Linux box.

- **`init`.** `Server.bindListenSocket(path)` (owns the path forever — a worker swap
  never rebinds it), resolve the worker binary (`--worker=` or `std.fs.selfExePath`,
  NUL-terminated for `execveZ`), pre-build the `--listen=<path>` argv entry (so
  `spawnWorker` allocates NOTHING between fork and exec), and `MasterRegistry.init`.
  Sets FD_CLOEXEC on the listener (it reaches a worker via dup2, not raw inherit).
- **`spawnWorker` — fd-inheritance.** `socketpair` → `{super_end, worker_end}` (both
  set FD_CLOEXEC so neither leaks as a stray fd into the exec'd worker); `fork`; in
  the CHILD (`childExecWorker`, async-signal-safe — no alloc/locks) the listener and
  the control socket are placed at **fd 3 / fd 4** via a collision-proof
  `F_DUPFD`→≥10 then `dup2`→3/4 (dup2 CLEARS CLOEXEC on the target, so they survive
  `execve`), then `execveZ(worker, {worker, "--handoff-worker", "--listen-fd=3",
  "--control-fd=4", "--listen=<path>"})`. The PARENT keeps `super_end` (+ its own
  listener) and returns `{pid, super_end}`.
- **Master registry (`MasterRegistry`, `readerLoop`).** A single reader thread is the
  SOLE owner of the live worker's `super_end`: it `poll`s that fd + a self-pipe, and
  on a control frame stores `register_master{id, pid}`+fd / drops `unregister_master`.
  Supervisor-lifetime dups (SIGHUP insurance + the `adopt` source), keyed by
  session_id; a handoff re-points the ACTIVE channel, it does not re-register them.
- **Crash-restart (`handleWorkerCrash`).** If the reader's `recvFrame` errors (channel
  EOF = the live worker died, not a handoff `shutdown` — those are handled inline), it
  closes the held masters + reaps the pid + spawns a fresh EMPTY worker. FIRST CUT: a
  crash loses that worker's sessions (a `TODO(host-handoff)` notes re-adopting the held
  masters into blank terminals as a future soft-reflow).
- **`handoff(new_worker_path)` + the BROKER (`brokerHandoff`).** `handoff` spawns v2,
  then POSTS the broker to the reader thread (via the self-pipe) so the broker runs
  INLINE on the sole `super_end` owner — no second reader competes. `brokerHandoff` is
  the **pure, unit-tested** protocol dance, factored to take `(v1_ctrl, v2_ctrl,
  registry, timeout)` so a test drives it with two `socketpair`s while playing BOTH
  mock workers: (1) `freeze_all`→v1, collect `session_state`+blob until `freeze_done`;
  (2) per frozen session `adopt{id, blob_len, child_pid}` + the held master
  (SCM_RIGHTS — NOT consumed, the supervisor keeps its dup) + blob → v2; (3) the
  **HEALTH-ACK GATE**: collect `adopt_ack`+`ready`; SUCCESS iff EVERY session acked ok
  AND a `ready` reached the freeze count → `shutdown` v1 (it exits; reader commits v2
  as the active channel + reaps v1); ANY nacked adopt / response `poll` timeout → ABORT
  → `unfreeze` v1 (the incumbent re-adopts + resumes) + kill v2, `error.HandoffAborted`.
  There is **never a window where neither worker serves**.
- **Handoff TRIGGERS (`triggerSelfHandoff`).** Two things ask for a handoff, both
  routed onto the reader/broker thread so the broker never re-enters, both spawning
  v2 from the canonical path **re-resolved at trigger time** (`--worker=` if set, else
  the supervisor's own `selfExePath`): (1) **SIGHUP** — the "new build installed"
  nudge (ForkSetup `kill(supervisor, SIGHUP)`); the async-signal-safe handler ONLY
  sets an atomic flag + writes the `reader_wake` self-pipe (errno saved/restored),
  and the reader `swap`s the flag (coalescing piled-up signals) before brokering; (2)
  **exec-path staleness self-check** — folded into the reader's `poll` timeout
  (`STALENESS_CHECK_INTERVAL_MS`, no busy loop): `libproc` `proc_pidpath` on the
  worker pid + the pure `workerPathStale` decision (stale on `ENOENT`/`null` — the
  unlinked-exec EPERM condition — or a mismatch with the canonical path) → hand off
  to a fresh worker from the canonical path. The supervisor also `proc_pidpath`s its
  OWN pid and just WARNS if stale (a stable supervisor install is a deploy concern; it
  does NOT self-exec). Full doc: `HOST-HANDOFF.md`.
- **Tests.** `src/host/test.zig`: `brokerHandoff` SUCCESS (acks all + `ready` →
  `shutdown` v1, no `unfreeze`) and ABORT (a nacked adopt → `unfreeze` v1, no
  `shutdown`), both driving the real `handoff_protocol` wire dance with two mock-worker
  threads + a fake registry; a `parseMode` arg-parse truth table; and the TRIGGER
  tests — the pure `workerPathStale` decision (resolves-equal / `ENOENT`-null /
  differs) + `proc_pidpath` resolving this test process's own exec path. The
  worker-side freeze→adopt / unfreeze / task-#7 SEQUENCE tests (a mock supervisor vs
  real `Server` workers) remain. The SIGHUP delivery + timer-driven firing + a real
  supervisor PROCESS / launchd on restart are validated by smoke later — a host restart
  still loses sessions today.

## Where the code lives

**Host** (`src/host/`): `main.zig` (barrel), `Server.zig` (listener +
session registry + subscriber routing + dispatch + **FORK: worker-side handoff
control** — `control_fd`/`frozen`/`announced_masters`/`notifySessionSpawned`/
`announceSpawnedMaster`/`notifySessionClosed`/`handleControlFrame`/`controlLoop`/
`joinControlLoop`), `Supervisor.zig` (**FORK: the supervisor process** — `parseMode`
argv dispatch, `MasterRegistry`, `spawnWorker` fork/exec fd-inheritance, `readerLoop`
+ crash-restart, `handoff`/`brokerHandoff`, macOS-only bodies), `Session.zig` (one
session: Termio/Exec/Terminal + `renderTick` push gate + selection/clear/reset/
at-prompt handlers), `RenderState.zig` (`Snapshot` serialize/deserialize/rehydrate,
`cursorEql`), `protocol.zig` (frames, `Hello`, `Resize.toSize`), `session_transfer.zig`
(FORK: same-build full-Terminal serialize/deserialize for host handoff),
`handoff_protocol.zig` (FORK: supervisor↔worker control codec, macOS-only) +
`fdpass.zig` (FORK: Darwin `SCM_RIGHTS` fd-passing, macOS-only), `difftest.zig` +
`test.zig`. `src/main_host.zig` is the exe root: `main` dispatches `--supervise` /
`--handoff-worker` / `--listen=` / stdout-diff via `Supervisor.parseMode`.

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

---

## PTY-host runs under a launchd LaunchAgent (deploy + new-machine setup)

The `ghostty-host` process (the fork's emulation-on-host backend — see
top-level `PTYHOST.md`) is **not** launched by the GUI app or a login script. It
runs as a **user LaunchAgent** `com.mitchellh.ghostty-ramon.host`
(`~/Library/LaunchAgents/com.mitchellh.ghostty-ramon.host.plist`, `KeepAlive=true` +
`RunAtLoad=true`). The GUI merely connects to its socket
(`pty-host = ~/.ghostty-ramon-host.sock` in the fork config). One long-lived host
serves every GUI restart; a **host** restart still loses all live sessions
(RAM-only). Locations: binary `~/.local/bin/ghostty-host`, socket
`~/.ghostty-ramon-host.sock`, combined stdout+stderr log
`~/Library/Logs/ghostty-ramon-host.log`.

**Canonical plist — replicate verbatim on every laptop for environment consistency.**
launchd requires ABSOLUTE paths (no `~`/env expansion in `ProgramArguments` or the
socket path), so **replace `/Users/ramon` with that machine's home** (and keep
`pty-host` in the config pointing at the same absolute socket path):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.mitchellh.ghostty-ramon.host</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Users/ramon/.local/bin/ghostty-host</string>
        <string>--listen=/Users/ramon/.ghostty-ramon-host.sock</string>
    </array>
    <!-- ReleaseFast host honors GHOSTTY_RESOURCES_DIR first; point it at the installed
         bundle so the child shell gets TERM=xterm-ghostty + a valid TERMINFO. -->
    <key>EnvironmentVariables</key>
    <dict>
        <key>GHOSTTY_RESOURCES_DIR</key>
        <string>/Applications/Ghostty (ramon).app/Contents/Resources/ghostty</string>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ProcessType</key><string>Interactive</string>
    <key>StandardOutPath</key><string>/Users/ramon/Library/Logs/ghostty-ramon-host.log</string>
    <key>StandardErrorPath</key><string>/Users/ramon/Library/Logs/ghostty-ramon-host.log</string>
</dict>
</plist>
```

**New-machine setup (one-time):** (1) build the host
(`zig build -Demit-macos-app=false -Doptimize=ReleaseFast`) and copy
`zig-out/bin/ghostty-host` → `~/.local/bin/ghostty-host`; (2) write the plist above
(fix the home path) to `~/Library/LaunchAgents/…`; (3)
`launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.mitchellh.ghostty-ramon.host.plist`
(RunAtLoad starts it); (4) ensure `pty-host = <that socket>` is in the fork config.

### ⚠️ After redeploying the host binary, RELOAD the agent — NEVER just `kill` it
launchd pins a code-signing launch requirement (**LWCR**) derived from the host binary's
Designated Requirement. **For Ramon's hand-built dev host this is the cdhash**: the fork
builds `ghostty-host` **ad-hoc / linker-signed** (no cert chain → the DR falls back to a
cdhash requirement), so **every rebuild has a new cdhash** and the old LWCR rejects it.
(The COLLEAGUE bundled host is different — Developer-ID-signed, so its DR/LWCR is pinned
to the identity `identifier + Team ID`, NOT the cdhash; that's exactly why the ForkSetup
reload gate keys off the protocol/epoch reload IDENTITY, not the binary hash — a new
same-identity host loads under the old LWCR fine. This whole section is about the AD-HOC
dev host below.) If you swap `~/.local/bin/ghostty-host` under a
running job and then merely `kill` it, `KeepAlive` respawns the NEW binary under the
OLD pinned requirement → launchd rejects it → it **exits 78 (`EX_CONFIG`) before it
can even write a log line** → hot crash loop (`launchctl print …` shows
`last exit code = 78`, `needs LWCR update`, and `runs` climbing) → nothing binds the
socket → **the GUI shows empty screens**. The binary is fine — it runs perfectly
standalone, even with the exact plist env; only launchd rejects it. (This cost a long
debug session on 2026-06-17; the symptom "I killed the host and a new window didn't
relaunch it / empty screens" is THIS.)

> The COLLEAGUE path (`ForkSetup`, which manages the *bundled* Developer-ID host) does
> NOT face this cdhash trap: that host's LWCR is identity-pinned, so a new same-identity
> build satisfies it. ForkSetup therefore only bootout-reloads when the host RELOAD
> IDENTITY (protocol version + `host_reload_epoch`) changes — NOT on every host recompile
> — and skips the reload on a GUI-only update even if the host's cdhash changed, so live
> sessions survive. (Older builds keyed off a SHA-256 of the host binary and reloaded on
> any recompile; superseded — see the First-launch setup section in
> `FORK-DISTRIBUTION.md`.) Ramon's hand-managed ad-hoc host here is a separate manual deploy —
> ForkSetup leaves it alone via the ownership-marker gate, and it still needs the
> bootout+bootstrap reload above on every rebuild.

**Correct deploy-then-restart of the host** (run from a NON-ramon terminal —
Terminal.app or the official Ghostty — since it ends every session, including this
Claude Code one if it lives under the host):
```sh
# 1) deploy without disturbing the running host: atomic rename keeps the live
#    process's inode (a plain `cp` over it risks ETXTBSY / corrupting it).
cp /path/to/repo/zig-out/bin/ghostty-host ~/.local/bin/ghostty-host.new
chmod +x ~/.local/bin/ghostty-host.new
mv -f ~/.local/bin/ghostty-host.new ~/.local/bin/ghostty-host
# 2) RELOAD (bootout+bootstrap) so launchd re-derives the LWCR from the new binary.
#    Do NOT `kill` — KeepAlive would crash-loop the new binary under the stale LWCR.
launchctl bootout   gui/$(id -u)/com.mitchellh.ghostty-ramon.host
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.mitchellh.ghostty-ramon.host.plist
# 3) verify healthy: pid set, runs=1, "(never exited)", and "server listening" in the log.
launchctl print gui/$(id -u)/com.mitchellh.ghostty-ramon.host | grep -iE 'pid =|last exit|runs ='
```
After the host comes back, **open fresh tabs/windows** — surfaces attached to the
pre-restart sessions are dead (sessions are RAM-only). Note: `pkill`/`pgrep -f
ghostty-host` do NOT match the host's cmdline on macOS; to find the pid use
`ps ax -o pid,command | grep '[g]hostty-host --listen'`. A stale socket file is NOT a
problem — the host unlinks-and-rebinds.

