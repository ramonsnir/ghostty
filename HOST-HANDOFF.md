# Host handoff: upgrading `ghostty-host` without dropping sessions

Fork-only. Lets a running `ghostty-host` hand its live terminal sessions to a
successor process built from the current bundle, then exit — so moving the host
to a new binary (or off a *deleted* exec path) stops being a destructive event.
Read **`PTYHOST.md`** first for the underlying `.client` emulation-on-host model;
this doc is the handoff layer on top of it.

## Why

`ghostty-host` is a long-lived launchd `KeepAlive` LaunchAgent holding every
surface's pty + terminal state in RAM. Two problems it fixes:

1. **The destructive restart.** The only way to move the host to a new binary was
   `bootout`+`bootstrap`, which kills every session. So a protocol change was
   inherently session-losing, and the setup code bent over backwards to avoid it.

2. **The EPERM/TCC time-bomb.** Because we avoided restarts, a host could keep
   running long after the bundle it was `exec`'d from was gone (Sparkle staging
   cleanup, or emptying the Trash after an update). When the exec path stops
   resolving, `proc_pidpath_audittoken()` returns `ENOENT`, tccd cannot build an
   attribution chain, and **every TCC-gated file access from every shell under
   that host fails closed with `EPERM`** — silent, undiagnosable, invisible to
   `launchctl print` (observed running 20 days from a deleted staging dir).

The fix keeps the sessions alive across a re-exec to the canonical bundle path.

## Architecture: supervisor + worker

```
launchd KeepAlive job ─▶ ghostty-host --supervise   (session-less; owns the socket path)
                          │  binds the AF_UNIX listener ONCE (forever)
                          │  holds a dup of every pty master (MasterRegistry)
                          │  fork/execs + crash-restarts the worker
                          │  brokers worker→worker handoff (health-ack gate)
                          ▼
                        ghostty-host --handoff-worker   (serves GUI sessions)
                          │  accepts GUI conns on the inherited listen fd
                          │  owns terminal.Terminal + IO threads per session
                          ▼
                        GUI (.client) ── redials the same socket path on drop
```

Both are the **same `ghostty-host` binary** in different argv modes (`src/host/Supervisor.zig`
`parseMode`): `--supervise`, `--handoff-worker`, the legacy `--listen=` standalone
(byte-for-byte unchanged), and the Phase-1 stdout-diff.

### Why a supervisor (the forcing constraint)

"The incumbent must survive a failed successor" requires two processes alive
concurrently during a handoff. pty masters die with the process holding them, so
the successor must hold dup'd masters *before* the incumbent exits. But launchd
won't run two instances of one job or adopt a live pid — so the successor cannot
be launchd-spawned during handoff. A supervisor-spawned worker is an ordinary
child (not gated by the job's LWCR — this dissolves the exit-78 cdhash crash-loop
trap for *worker* updates), and the supervisor provides the crash-restart
supervision launchd would otherwise give. No lighter launchd-native option
(socket activation, `KeepAlive` dicts, `kickstart`) satisfies both hard
requirements.

## The handoff sequence

Two internal channels: **supervisor↔worker** over an inherited `socketpair`
(control frames + `SCM_RIGHTS` fd passing, `src/host/handoff_protocol.zig`);
**worker↔GUI** over the existing AF_UNIX listener (`src/host/protocol.zig`,
unchanged so the GUI protocol stays byte-stable).

1. **On session spawn** the worker sends `register_master{session_id, pid}` + a
   **dup** of the master UP to the supervisor (`Server.notifySessionSpawned` →
   `announceSpawnedMaster`, gated on `control_fd != null && SessionEntry.announce_master`
   — an *adopted* session does not re-announce). The supervisor holds the dup.
2. **`freeze_all`** (S→v1): for each session the worker detaches its IO (joins the
   thread), serializes the `Terminal` under `render_mutex` (`session_transfer`),
   sends `session_state{id, blob_len}`+blob UP, and RETAINS `{own master fd, pid,
   blob}` in its `frozen` map for a possible unfreeze. Then `freeze_done{count}`.
3. **`adopt`** (S→v2): `{id, blob_len, aux2=pid}` + the supervisor's held
   master-dup + blob → v2 deserializes, `Session.adopt(master, pid, terminal)`,
   registers it under the ORIGINAL id, starts it, `adopt_ack{ok}`; then
   `ready{count}`.
4. **Health-ack gate + successor-liveness check** (`Supervisor.brokerHandoff`):
   SUCCESS iff every session `adopt_ack{ok=1}` AND a `ready` reached the freeze count
   AND the successor process is still alive → `shutdown` v1 (it exits, v2 is the live
   worker). ANY nack / timeout / missing master / dead successor → **abort**:
   `unfreeze` v1 (it re-adopts its frozen sessions + resumes) and the caller kills
   v2. Every abort path routes through `abortUnfreeze`, which tells v1 to resume
   *before* returning the error — so there is **never a window where neither
   serves**.
   - **The successor-liveness check** (`successorAlive`, issue #6): a cheap
     non-blocking `MSG_PEEK` recv on v2's CONTROL channel before commit. For a session-carrying
     handoff the ack-gate already proved v2's control loop is alive; but a
     **zero-session** handoff sends no adopts and `ready_reached` starts true, so the
     gate never touches v2 — a v2 that died at startup (e.g. a failed `exec`) would
     otherwise be committed while v1 is shut down. When v2's process dies the kernel
     closes its control-socket end, so a `recv(MSG_PEEK|MSG_DONTWAIT)` on the
     supervisor's peer returns EOF (0 bytes) → veto → abort; a live v2 → `EAGAIN` (or
     a peeked, non-consumed pending frame) → commit. `MSG_PEEK` (not a bare `poll`)
     is used so a live v2 that RACED a frame onto the channel during the handoff window
     (e.g. a `register_master` from a GUI client that spawned on v2) is not mistaken
     for EOF. This is **zombie-proof** (fd closure is independent of reaping — unlike
     `kill(pid,0)`, which reports an un-reaped zombie as alive on XNU) and
     **attributable to v2** (its own channel, not the shared listener). The pure
     broker unit tests keep the mock v2 channel open, so the SUCCESS path holds.
     Residual (benign, unfixed): if v2's `execve` is still in flight at check time
     (worker_end not yet closed) and then fails, a zero-session handoff commits into a
     brief no-server window — but with no sessions to lose and the supervisor's
     crash-restart bringing a fresh worker right back, this self-heals; the freeze
     round-trip with v1 also gives v2 ample startup slack first.
   - **Why NOT a connect "service probe"** (the issue's originally-proposed point 3,
     deliberately dropped): a probe that `connect`s to the listen socket before commit
     **cannot** detect this bug — the `SS_DRAINING` poison happens at v1's `deinit`,
     triggered by the `shutdown` sent *after* the probe, so at probe time the listener
     is always healthy. It also cannot **attribute** an accept to v2 (v1 still shares
     the listener), and an unaccepted conn just queues in the backlog and reads
     healthy. It added ~500ms/handoff blocking the reader thread for no real
     detection. The poison is fixed at the source instead (see the listener-fd
     ownership contract below); the regression test guards it deterministically.

### The single-active-reader invariant

The masters in v1, the supervisor, and v2 all share one open-file-description
(dup / `SCM_RIGHTS`), so one kernel read pointer. Exactly one reader is active at
a time. The serialized `Terminal` reflects precisely the bytes v1 consumed; bytes
the child wrote but v1 hadn't read stay in the kernel buffer and are consumed by
v2 after rehydrate — no loss, no double-read. GUI keystrokes during the gap are
held by the `.client` `.reconnecting` hold-gate.

## The fd / child ownership contract (the subtle part)

Ownership of a session's **pty master fd** and its **child** transfers exactly
once; the rules (all `// FORK(host-handoff):`-marked in `src/termio/Exec.zig` +
`src/host/Server.zig`):

- **`Exec.adopt` is set as the LAST statement of session construction** (reaching
  into the moved `self.io.backend.exec` after `Termio.init`), so it is non-null
  **iff construction fully succeeded**. On any construction failure it stays null
  and the caller (`handleAdopt`) closes the master exactly once — no double-close.
- **Detach-for-handoff** (`Session.detachForHandoff` → `Exec.threadExit` detach
  branch): stop the read thread + child watcher, do NOT close the master or SIGHUP
  the child (nulls `self.adopt` so later `deinit` won't either) — the successor
  continues them.
- **Adopted normal close** (`Exec.threadExit` adopt branch): SIGHUP + reap the
  child, close the master exactly once, null `self.adopt`.
- **Adopt-init FAILURE** (`Exec.threadEnter` errdefer): close ONLY the successor's
  master copy — NEVER SIGHUP the child (it is still the predecessor's, which will
  `unfreeze`). This is the incumbent-survival guarantee at the fd level.
- **Never-started adopted session destroyed** (`Exec.deinit`, the OOM /
  thread-spawn-failure path): `self.adopt` still set → close master + SIGHUP/reap.
- **Frozen state** (`Server.frozen`): on `shutdown` close the retained masters +
  free blobs, do NOT SIGHUP (successor owns the children); on `unfreeze` re-adopt
  each `Session.adopt(own master, pid, terminal)`.

Verified by the in-process integration tests (`src/host/test.zig`): a real shell
survives detach→adopt (screen + scrollback preserved, same pid, second command
executes); the child survives an aborted handoff and is recovered by `unfreeze`;
an adopt failure never kills the predecessor's child; a never-started adopted
session's destroy releases the master + reaps the child; net open-fd count never
grows.

## The listener fd ownership contract (issue #6 — the shared-socket poison)

The **GUI listen socket** is a second shared fd with its own ownership rules,
separate from the per-session pty masters. The supervisor binds it ONCE
(`Server.bindListenSocket`) and every worker inherits the SAME socket object
(fork + `dup2` → fd 3, and across a handoff the successor inherits it too). So all
of {supervisor, v1, v2} hold references to one kernel socket object.

**The bug it fixes:** `Server.deinit` used to `posix.close(self.listen_fd)` to
unblock its accept thread (which was parked in a blocking `accept()`). On XNU,
closing an fd *while a thread of that process is blocked in `accept()` on it* sets
`SS_DRAINING` on the **socket object** — which is shared — so **every subsequent
`accept()` in ANY holder returns `ECONNABORTED`, forever**. During a handoff v1's
`shutdown` → `deinit` therefore poisoned the listener v2 had just inherited: v2
acked healthy, v1 exited, and v2 owned a listener it could never accept on → the
GUI hung at launch after **every** app update (the exec-path staleness trigger
fires a handoff on every update). See the issue for the XNU `SS_DRAINING` /
`bsd/kern/uipc_syscalls.c` detail and a minimal 2-child OS repro.

The rules now (all `// FORK(host-handoff):`-marked in `src/host/Server.zig`):

- **`owns_listen_fd`** — a field DISTINCT from `owns_path`. True only for a Server
  that solely owns the socket it may close (the standalone `init` host, or a test's
  private throwaway listener); **false for a supervisor-managed worker**
  (`initFromListenFd`), whose listener is shared. `deinit` closes `listen_fd` ONLY
  when `owns_listen_fd` — a worker never closes the shared listener (the OS reaps
  its copy on process exit, at which point no thread is blocked in accept anyway).
- **Wakeable accept loop** — the accept thread now blocks in `poll([listen_fd,
  accept_wake[0]])`, never in `accept()`. `deinit` unblocks it by writing one byte
  to the `accept_wake` self-pipe (mirrors `Supervisor.reader_wake`), then joins —
  **without touching the socket**. So even for an owned listener, nothing is ever
  blocked in `accept()` at close time.
- **Non-blocking listener + blocking accepted conns** — `start()` sets `O_NONBLOCK`
  on `listen_fd` so `accept()` never blocks after a `poll` wake (needed because
  during a handoff BOTH workers poll the shared listener and the loser of an accept
  race must get `WouldBlock` and re-poll, not block → else it would be stuck in
  `accept()` at *its* teardown, the same poison). **Gotcha:** on macOS/BSD `accept()`
  INHERITS the listener's `O_NONBLOCK` onto the accepted socket, which would make
  `Conn.readLoop`'s blocking `read` drop the conn before Hello — so each accepted fd
  is explicitly set back to blocking (`setBlocking`).
- **CLOEXEC hygiene** — both `accept_wake` ends (and, secondary finding, both
  `Supervisor.reader_wake` ends) are `FD_CLOEXEC`, so no supervisor/worker
  bookkeeping fd leaks into a shell child across `fork`+`execve`. The worker ALSO
  re-sets `FD_CLOEXEC` on its inherited **listener** (`start`) and **control** fd
  (`startControlLoop`) — both arrive with CLOEXEC *cleared* (to survive the worker's
  own `execve`), and `Command` only wires stdin/out/err + relies on CLOEXEC for the
  rest, so without this every shell would inherit them. A shell holding the control
  fd would keep the supervisor↔worker channel open after the worker died, defeating
  the supervisor's EOF crash detection (and the successor-liveness check above).

Verified by `src/host/test.zig` "host handoff: v1 teardown does not poison the
shared listener; v2 still accepts": two Servers share a `dup`'d listener, a client
is served pre-swap, v1 is `deinit`'d (the swap), and a NEW client is then accepted
by v2 — which FAILS pre-fix (poisoned socket) and passes post-fix. Also confirmed
end-to-end with the issue's shell repro: pre-fix post-handoff connect → `EOF` +
`accept failed err=error.ConnectionAborted`; post-fix → connection held +
`handoff committed … now serving`.

## GUI reconnection

A local `.client` `.attach` surface opts into a **bounded** redial
(`Config.handoff_redial`, set in `src/Surface.zig`; distinct from the remote
`reconnect`): it arms the existing redial machine but gives up after
`RECONNECT_HANDOFF_MAX_ATTEMPTS` (~1s/2s/4s) rather than the remote's forever
cadence (which would storm a genuinely-dead local host). `session_ended`-on-miss
stays gated on `reconnect` ALONE, so a genuine miss falls through to the Phase-1
spawn-fresh. On a successful handoff the successor re-registers each session under
its original id, so the redial `reattachId` HITS and the reconnect is silent.

## Triggers

Two things ASK for a handoff. Both are funneled onto the `--supervise`
**reader/broker thread** (the sole owner of the active control channel) and both
spawn v2 from the **canonical worker path re-resolved AT TRIGGER TIME** (`--worker=`
if configured, else the supervisor's own `selfExePath`), then run the same
`brokerHandoff` inline via `triggerSelfHandoff` (a self-handoff with no external
caller waiting — distinct from the blocking public `handoff()` an external
MCP/test caller uses). Because the reader thread runs one thing at a time, the
broker is **never re-entered**; a handoff already in flight coalesces new triggers.

- **SIGHUP** — "a new version is available." ForkSetup (below) `kill(supervisor,
  SIGHUP)`s after installing a new build. The handler is **async-signal-safe**: it
  ONLY sets an atomic flag (`g_sighup_pending`) and writes one byte to the existing
  `reader_wake` self-pipe (errno saved/restored) — no alloc, no logging, no handoff
  work in signal context. The reader wakes, `swap`s the flag to false (so many
  piled-up signals collapse to one follow-up), and brokers the handoff.
- **Exec-path staleness self-check** — the EPERM trigger. Folded into the reader's
  `poll` timeout (`STALENESS_CHECK_INTERVAL_MS`, no busy loop): every interval the
  supervisor asks macOS `libproc` `proc_pidpath` for the WORKER pid's current exec
  path and applies the pure `workerPathStale` decision — stale on `null`/`ENOENT`
  (the exec file was unlinked — exactly the EPERM condition) OR a mismatch with the
  canonical path (bundle moved/replaced) — and on stale hands off to a fresh worker
  from the canonical path, so the live worker again executes a path that resolves.
  It also `proc_pidpath`s the supervisor's OWN pid and just **warns** if that is
  gone (a stable supervisor install is a deploy concern — it does NOT self-exec).

## ForkSetup + deploy

- **Plist ProgramArguments → the supervisor**: `ghostty-host --supervise
  --listen=<socket>`; `KeepAlive` now supervises the *supervisor*. The supervisor
  should live at a **stable path** (outside the churning bundle) so its own exec
  path never goes stale.
- **Two-identity reload split** (`macos/.../ForkSetup/ForkSetup.swift`): a
  **worker**-identity change (common) becomes a non-destructive `.handoffWorker`
  plan that SIGHUPs the running supervisor — no bootout, sessions survive, no LWCR
  reload. A **supervisor**-identity change (rare) keeps the destructive
  `bootout`+`bootstrap`. The two identities are **carved IN SWIFT** from the same
  packed `ghostty_host_reload_identity()` (pure `decodeReloadIdentities`) — **no new
  C export, no lib rebuild for the split**. FIRST-CUT MAPPING: **supervisor =
  protocol MAJOR** (rare bumps → destructive reload); **worker = protocol MINOR +
  `host_reload_epoch`** (common bumps → SIGHUP handoff). Recorded in two UserDefaults
  keys (`kInstalledHost{Supervisor,Worker}Identity`, replacing the single
  `kInstalledHostReloadIdentity`). The `.handoffWorker` EXECUTOR resolves the
  supervisor pid from `launchctl print <label>` (the same job label + `pid = N` probe
  used elsewhere) and `kill(pid, SIGHUP)`s it; a missing pid / failed kill is left
  UNrecorded so the next launch retries (never a bootout).
- **The plain-host → supervisor first update is a ONE-TIME `.reload`; subsequent worker
  updates are `.handoffWorker`.** An upgrading colleague reaches the
  no-recorded-supervisor-identity branch (the old build wrote only the single-key
  identity, so both new keys are absent), which **disambiguates on the EXISTING plist's
  ProgramArguments** via the pure `plistRunsSupervisor` (`--supervise` present?), read
  from the SAME single plist parse as the ownership marker (`readPlist`):
  - existing plist ALREADY runs `--supervise` → a genuine supervisor whose identity
    record was merely lost → **non-destructive** `.adoptRunning` (running) / `.revive`
    (down), recording both identities without a bootout.
  - existing plist is a PLAIN `--listen` host (the real pre-supervisor→supervisor
    UPGRADE) → the **ONE-TIME switchover** `.reload` when running (bootout the plain
    host, bootstrap the supervisor — the single unavoidable session-losing deploy), or
    `.revive` when down (nothing to lose). After this, worker upgrades are
    non-destructive `.handoffWorker`s.
  - **Why this matters (the bug it fixes):** adopting a plain host as if it were a
    supervisor would leave a plain host running under a supervisor plist (EPERM risk
    from the moved bundle) with no supervisor actually up, and a later `.handoffWorker`
    would SIGHUP that plain host — whose DEFAULT SIGHUP action is TERMINATION — killing
    every session. The `--supervise`-args check ensures a SIGHUP only ever targets a
    genuine supervisor.

## Redeploy classification

**Host change** (`src/host`, `src/termio` core → compiled into `ghostty-host`):
the switchover is the destructive deploy, run deliberately from a non-ramon
terminal. The GUI-side (`Client.zig` `handoff_redial`, `Surface.zig`) is a
lib/xcframework rebuild + GUI relaunch; ForkSetup is Swift/GUI.

## Where the code lives

- `src/host/fdpass.zig` — Darwin `SCM_RIGHTS`: header + 0..N fds over `SOCK_STREAM`
  (`sendMsg`/`recvMsg`; fixed-header framing so a `recvMsg` never over-reads a
  trailing blob). macOS-only.
- `src/host/handoff_protocol.zig` — the supervisor↔worker frame codec (fixed
  32-byte header + tags; `Frame`, `sendFrame`/`recvFrame`, `writeBlob`/`readBlob`).
- `src/host/session_transfer.zig` + `// FORK(host-handoff):` methods in
  `src/terminal/{Terminal,Screen,PageList,page,ScreenSet,Tabstops}.zig`,
  `kitty/graphics_*.zig`, `apc/glyph/Glossary.zig` — full-fidelity `Terminal`
  serialize/deserialize behind a MAGIC + layout fingerprint (same-build contract).
- `src/termio/Exec.zig` / `Termio.zig` / `src/host/Session.zig` — pty adopt/detach
  + the rehydrated-terminal injection.
- `src/host/Server.zig` — `initFromListenFd`/`bindListenSocket`/`owns_path`; the
  worker control handlers (`handleFreezeAll`/`handleAdopt`/`handleShutdown`/
  `handleUnfreeze`, `notifySessionSpawned`, the `frozen` map, `startControlLoop`);
  **issue #6** — `owns_listen_fd` + the wakeable `acceptLoop` (`accept_wake`
  self-pipe, non-blocking listener via `setNonblock`, `setBlocking` on accepted fds,
  `setCloexec` on the listener + control fd) so a worker `deinit` never poisons the
  shared listener and shells never inherit the listener/control fds.
- `src/host/Supervisor.zig` — the `--supervise` process: `parseMode`, `spawnWorker`
  + `childExecWorker` (fork/exec fd-inheritance: F_DUPFD→dup2 fd 3=listener/4=control,
  clear CLOEXEC), `MasterRegistry`/`readerLoop`, `handleWorkerCrash`, `handoff` +
  the unit-tested `brokerHandoff` (+ its **issue #6** `successorAlive` pre-commit
  control-channel EOF liveness check), the `reader_wake` CLOEXEC fix + the rate-limited
  stale-supervisor warning (`warned_own_path_stale`), and the **triggers**: `sighupHandler` /
  `installSighupHandler` + the `g_sighup_*` globals, the `libproc.proc_pidpath`
  binding with `workerExecPath` + the pure `workerPathStale`,
  `checkWorkerStalenessAndMaybeHandoff` (folded into `readerLoop`'s poll), and
  `triggerSelfHandoff` / `finishHandoff` (the reader-inline broker commit/abort
  shared with `serviceHandoffRequest`).
- `src/main_host.zig` — the argv dispatch.
- `src/termio/Client.zig` + `src/Surface.zig` — `handoff_redial`.

## Tested vs live-smoke-only

- **Unit/integration (all green):** the serializer round-trip; fdpass +
  handoff_protocol codecs; the in-process detach→adopt→shell-survives sequence
  (success / abort→unfreeze / never-started-destroy / adopt-failure-doesn't-kill);
  the broker health-ack gate driven with mock workers over socketpairs; the pure
  `workerPathStale` decision (resolves-equal / ENOENT-null / differs) + the
  `proc_pidpath` resolver against this test process's own exec path; arg parsing;
  **issue #6** — the shared-listener poison regression (two Servers share a `dup`'d
  listener; a client is served, v1 is torn down, a NEW client is still accepted by
  v2) + the `owns_listen_fd`-keeps-the-listener-open assertion.
- **Live-smoke only (P4):** the real fork/exec of a worker that inherits the fd-3
  listener + fd-4 control across `execve`; crash-restart; SIGHUP + the timer-driven
  handoff firing; the full 2-process handoff end to end.

## Known follow-ups

- **Provisional successor child ownership** (rare): an OOM/thread-spawn failure in
  `registerAdoptedSession` *after* a successful `Session.adopt` makes `Exec.deinit`
  SIGHUP the child, which during a handoff is still the predecessor's — a rare
  incumbent-survival dent. Fix: model the successor's child as provisional until
  the supervisor commits the handoff (close-only on any pre-commit teardown).
- **Crash-recovery re-adopt**: on a worker crash the supervisor currently respawns
  an empty worker (sessions lost, same as today's host crash). Because it holds the
  masters, it could instead re-adopt them into the fresh worker with blank
  terminals (shells survive, redraw).
