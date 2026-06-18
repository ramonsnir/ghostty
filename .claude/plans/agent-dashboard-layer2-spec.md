# Agent Dashboard — Layer 2 edit spec (core render-mirror surface mode)

Branch: `ramon-fork`. Layer 1 is **committed** (protocol minor 2,
`FrameType.subscribe_render` at `protocol.zig:183`, `SubscribeRender =
SessionIdFrame(.subscribe_render)` at `protocol.zig:1101`,
`SessionEntry.render_subscribers` at `Server.zig:144`, add/remove at
`Server.zig:208-227`, `subscribeRender`/`handleSubscribeRender` at
`Server.zig:1231`/`1294`, `pushFullFramesTo` at `Server.zig:1826`, the
`onRender` second loop at `Server.zig:1502-1506`, the read-only gate
`Conn.isRenderOnlySubscriber` at `Server.zig:285` consumed by every mutating
dispatch arm). This spec builds on top of it.

Two things to build:

- **(A) Carried prereq (host):** give RENDER subscribers a NON-BLOCKING,
  bounded-buffer-and-DROP delivery path so a wedged render subscriber can no
  longer stall the session render thread / head-of-line-block the primary GUI
  subscribers / delay teardown. grid_frame + mode_frame are ABSOLUTE full-state
  snapshots, so dropping stale frames for a slow sub is safe. Scope STRICTLY to
  `render_subscribers`; do NOT change the primary GUI `subscribers` semantics
  (SR-4) and do NOT touch `raw_subscribers`.
- **(B) The render-mirror surface mode (client + apprt + C header):** a `.client`
  backend MIRROR role that `subscribe_render`s an existing session, consumes its
  grid_frame/mode_frame into the same RenderState mirror, suppresses every
  session-mutating outbound frame, and handles session-gone by rendering a
  quiescent terminated state.

Files touched (this layer ONLY):
- `src/host/Server.zig` (part A)
- `src/termio/Client.zig` (part B: role flag, subscribe-vs-attach, suppression,
  session-gone)
- `src/termio/backend.zig` (no change required — see B0; listed for the reader)
- `src/Surface.zig` (part B: construct mirror role under pty-host, post-move wiring)
- `src/apprt/embedded.zig` (part B: C-ABI field consumption)
- `include/ghostty.h` (part B: appended C-ABI field)
- `src/host/test.zig` (part A tests, `-Dtest-filter=host`)
- `src/termio/client_difftest.zig` and/or a `src/termio/Client.zig` test block
  (part B tests, `-Dtest-filter=client`)

Build/test (each as ONE streaming command, long timeout):
```
zig build -Demit-macos-app=false -Demit-xcframework=false
zig build test -Demit-macos-app=false -Demit-xcframework=false -Dtest-filter=host
zig build test -Demit-macos-app=false -Demit-xcframework=false -Dtest-filter=client
```
Do NOT build/run the macOS app. Do NOT deploy/restart any live `ghostty-host`.

All line numbers are anchors (function names + nearby lines) verified against the
source as read on the spec date — find the named function before editing.

---

## 0-bis. CRITIC FIXES APPLIED (supersedes the §0 / §B3 silence-timeout design)

The post-implementation critic raised three MAJORs (no blockers). All are resolved
in the tree; this section is authoritative where it conflicts with §0/§B3 below.

### FIX 1 (headline) — silence is NOT death: removed the false-terminate of idle-but-alive mirrors.
The original §0/§B3 design declared a session "gone" after 5 s of frame SILENCE
(`MIRROR_LIVENESS_TIMEOUT_MS`). But the host suppresses grid/mode frames on an idle
session (renderTick push-gate `changed>0 || force_push || cursor_changed`) and never
closes the per-render-subscriber socket on session-gone, so a perfectly-alive agent
sitting IDLE at a prompt — the Agent Dashboard's PRIMARY target — emits zero frames
and would be mis-declared terminated within 5 s. That is a wrong result on the
headline live case. **RESOLUTION:** the mirror now declares the session gone ONLY on a
GENUINE socket signal — EOF (`n==0`) or a read error — NEVER on frame silence. The
silence timeout and `markMirrorEnded`-on-timeout are REMOVED. The read loop still
polls with a finite `MIRROR_POLL_TIMEOUT_MS` (1000 ms) only to stay responsive to the
quit pipe; a poll timeout simply re-loops. Consequences: an idle-but-alive agent is
never falsely terminated; on a host-side `Close` of a still-running host (rare for the
live-agent target) the socket stays open and the mirror keeps showing the last frame —
non-destructive (the mirror owns nothing real), re-derived on the model's next
refresh. A host-side liveness/keepalive frame that would also cover the keep-open-Close
case is the Layer-3 followup (additive host protocol change, out of Layer-2 scope).
The `MIRROR_LIVENESS_TIMEOUT_MS` const and the `mirror_last_frame_ms` field are
DELETED. `mirror_ended` and `markMirrorEnded` remain (now fired only by EOF/read-error)
and the B-test-3 fire-once unit test is unchanged.

### FIX 2 — bounded-drop is now PROVEN (was tautological): A-test-5.
The prior A-test-1 did not prove the ring is BOUNDED (raising `CAP` to 100000 left the
suite green; `RenderOut.dropped` was never asserted). Added a TEST HOOK
(`Conn.renderOutDroppedForTest()` / `renderOutLenForTest()` / `RENDER_OUT_CAP_FOR_TEST`
+ `Server.firstRenderSubscriberForTest(session_id)`, all `pub`/TEST-ONLY) and **A-test-5**
("bounded-drop genuinely fires"): it GENUINELY wedges a render-sub (server-side
`test_tiny_sockbuf` shrinks the accepted-conn SO_SNDBUF to 2048 + a tiny client SO_RCVBUF,
peer never read), drives 40 ticks of output, then asserts `dropped > 0` AND
`ring_len <= CAP`. Mutation-verified: setting `CAP = 100000` makes A-test-5 FAIL on
`dropped > 0`. The `dropped` counter is also now logged at teardown (`log.debug`,
no longer dead telemetry).

### FIX 4 (post-critic MAJOR) — `test_tiny_sockbuf` must wedge ONLY the render-sub, not the primary.
The first draft applied the 2048-byte SO_SNDBUF shrink in `setupConn`, i.e. to EVERY
accepted conn INCLUDING the PRIMARY GUI conn. `onRender`'s retained-by-design blocking
write to a primary subscriber (the SR-4 single-fast-local-peer contract, deliberately
left blocking by prereq A) runs WHILE HOLDING `e.mutex`. The wedge tests drive
screen-filling output but drain the primary only opportunistically, so when the test
reader fell behind, the primary's 2KB send buffer filled and `onRender`'s blocking
write to the PRIMARY wedged with `e.mutex` held; the test thread then called
`firstRenderSubscriberForTest` (registry_mutex -> e.mutex) and blocked on `e.mutex`
forever — a genuine, timing-dependent DEADLOCK (observed: 21+ min hang, identical
wedged stack across samples; passed on re-run). The wedge tests could themselves hang
teardown. RESOLUTION: do NOT shrink in `setupConn`. Apply the shrink ONLY once a conn
becomes a RENDER subscriber, in `subscribeRender` (`setSockBufTo(conn.fd, SO_SNDBUF,
2048)` guarded by `test_tiny_sockbuf`). The primary conn keeps its full SOCKET_BUF, so
`onRender`'s blocking write to the primary never backpressures and `e.mutex` is never
held across a wedged primary write — `firstRenderSubscriberForTest` can no longer
deadlock. This matches PRODUCTION (a real primary is a fast local GUI with a large
buffer). Verified: `-Dtest-filter=host` now passes deterministically across repeated
runs with no hang (A-test-5/6/7 all still genuinely wedge the render-sub via the
subscribe-time shrink + tiny client RCVBUF). (`src/host/Server.zig` `setupConn` +
`subscribeRender`.)

### FIX 3 — the BLOCKER fix (shutdown(.send)-before-join) is now PROVEN: A-test-6.
The prior A-test-2/3 never genuinely wedged the drain thread (CAP=4 tiny frames fit a
~1 MiB kernel buffer), so commenting out `renderOutTeardown`'s `posix.shutdown(self.fd,
.send)` left the suite green. Added **A-test-6** ("GENUINELY wedged drain thread does
not hang teardown"): with both socket buffers shrunk to 2048 (measured floor on macOS
AF_UNIX) and SCREEN-FILLING output (large grid_frames), the drain thread is PROVABLY
parked inside the blocking `writeAll` (asserted: ring pinned at `CAP`, `dropped > 0`).
The peer then `shutdown(.send)`s its WRITE side ONLY (server reads EOF → reaps the
conn) while its READ side stays OPEN, and `server.deinit()` is called EXPLICITLY with
the peer still open (NO `defer posix.close(rndc)` — that would unblock the write
independently of the fix; the peer is closed only AFTER deinit returns). The ONLY thing
that can unblock the parked write and let the reaper→deinit complete is
renderOutTeardown's `shutdown(.send)`. Mutation-verified: commenting out the shutdown
makes A-test-6 HANG (deinit's reaper-join never returns). The genuine-unblock fact was
confirmed against the kernel: peer-SHUT_WR and own-SHUT_RD do NOT unblock a blocked
AF_UNIX write; only own-SHUT_WR (= `.send`) returns it with EPIPE.

### Resolved MINORS.
- `RenderOut.dropped` is now logged at teardown (`renderOutTeardown`) and read by the
  test hook — no longer dead telemetry.
- `mirror_ended` field comment corrected: the renderer does NOT read it in Layer 2 (it
  keeps drawing the frozen last frame); the operative signal is the synthetic
  `child_exited` surface message. The flag/lock are forward-compatible for a Layer-3
  terminated overlay.

---

## 0. Resolution of the prior-review findings (read first)

> NOTE: §0's "Resolved MAJOR — session-gone detection" and §B3's silence-timeout
> design are SUPERSEDED by §0-bis FIX 1 above (silence is no longer treated as death;
> the `MIRROR_LIVENESS_TIMEOUT_MS` timeout was removed). The §0 BLOCKER resolution
> (shutdown-before-join) stands and is now test-proven (§0-bis FIX 3).

### Resolved BLOCKER — teardown must shut the fd BEFORE joining the drain thread.
The host sockets are **blocking** `SOCK_STREAM` (`Server.zig:301-314`
"BLOCKING-WRITE CONTRACT"; fd created `SOCK.STREAM` at `Server.zig:353-355`, the
write side never sets non-blocking). The new render-drain thread (A3) does the
blocking `posix.write` (via `conn.writeAll`) OFF the locks — good — but a drain
thread blocked inside `posix.write` to a wedged-but-still-connected peer (a peer
that half-closes only its READ side, or never drains) will NOT observe a stop
flag until the write returns (possibly never). The drain-thread teardown
(`renderOutTeardown`, A7.1) is reached from **two** call sites:

1. `reapConn` (`Server.zig:421`), which already `t.join()`s the conn's read
   thread at `:422` — the SINGLE reaper thread. If `renderOutTeardown`'s
   `t.join()` blocked here, ALL subsequent dead-conn reaping stalls. This is the
   normal mid-session reap path and it does NOT shut the conn fd (only `deinit`
   does, `Server.zig:2002-2005`). EXPOSED.
2. `readLoop`'s OOM inline free (`Server.zig:549-559`), which frees the conn
   inline (it could not enqueue to the reaper).

FIX (mandatory): `renderOutTeardown` MUST `posix.shutdown(self.fd, .send)` (the
write half is sufficient; `.both` is also fine) BEFORE `t.join()`, mirroring what
`deinit` already does at `Server.zig:2004` (`posix.shutdown(conn.fd, .both)`
before waiting). The shutdown interrupts any in-flight blocking write with EPIPE/
ENOTCONN so the drain thread's `writeAll` returns, the drain loop observes
`stop`, and `join()` completes promptly. Both call sites call
`renderOutTeardown`, so both are covered. See A7.

NOTE on lock-order: `reapConn` runs on the reaper thread holding NO `SessionEntry`
mutex and NO `registry_mutex` (it pops from `dead_conns` under `conns_mutex`, then
RELEASES it before `reapConn`, `Server.zig:396-402`). So shutting the fd + joining
the drain thread there introduces no new lock-order edge. `unsubscribeAll` has
ALREADY removed the conn from every `e.render_subscribers` before the conn is
enqueued for reaping (`Server.zig:518-521`), so by the time `reapConn` runs no
`onRender` can enqueue into this conn's RenderOut ring — the drain thread only has
to flush what is already buffered (bounded, ≤ CAP buffers) and then exit.

### Resolved MAJOR — session-gone detection must NOT key on EOF/read-error.
The prior spec asserted the read loop "returns on EOF (n==0)". That is FACTUALLY
WRONG: at `Client.zig:1541` `n == 0` is a `break` out of the INNER read loop, not
a return; control falls through to `posix.poll(&pollfds, -1)` at `Client.zig:1564`
and re-loops. More importantly, on real session-gone the host does NOT close the
mirror's socket per-subscriber: `teardownEntry` (`Server.zig:1908-1924`) only
clears `e.render_subscribers` under `e.mutex`; the conn fd stays open and the
mirror simply STOPS receiving frames. So on session-gone the mirror's read thread
neither hits EOF nor an error — it parks in `poll(-1)` forever. An EOF/read-error
hook therefore NEVER fires in the common path, and the headline "quiescent
terminated" deliverable would not work.

RESOLUTION (chosen mechanism — CLIENT-SIDE liveness timeout, fully in Layer-2
scope; full design in B3):
- The mirror read loop polls with a **finite timeout** instead of `-1`, and tracks
  a `mirror_last_frame_ms` wall-clock stamp updated on every successfully decoded
  frame.
- If no frame arrives within `MIRROR_LIVENESS_TIMEOUT_MS` (recommended **5000 ms**,
  a const in Client.zig), the mirror declares the session gone, sets a
  `mirror_ended` flag under `renderMutex()`, pushes ONE synthetic `child_exited`
  surface message (so `Surface.childExited` runs and the tile shows terminated —
  exactly the same surface path the real `.child_exited` frame uses at
  `Client.zig:1041-1046`), and `return`s the read thread. The flag is idempotent
  (fire-once guard) so a slow-but-alive session that resumes does not double-fire.
- EOF (`n == 0`) and read-errors ALSO route to the same `markMirrorEnded` helper
  in the mirror role (they are genuine session-gone on a mirror — the host process
  died or the conn dropped), so all three paths converge on one signal.
- This is mirror-ROLE-only: the `.attach` role keeps `poll(-1)` and its existing
  EOF/error handling **byte-for-byte unchanged** (the timeout + liveness branch is
  gated on `self.config.role == .mirror`).

Rationale for the heuristic over a host-side frame: a host-side
per-render-subscriber "session_gone" frame would be an additive protocol change on
the host (out of the Layer-2 scope as the task framed it — Layer 1 owns the host
protocol surface and is committed). The client-side timeout needs no protocol
change, degrades gracefully against an old host, and is safe because the mirror
owns nothing real — a false "terminated" only dims a preview tile; the real session
is untouched and a later re-subscribe re-mirrors cleanly. The 5 s window is
comfortably above the host's ~10 Hz renderTick poll, so a BUSY session is never
misdeclared. A genuinely IDLE-but-alive agent (no output ≥ 5 s) MAY be shown
terminated — a documented heuristic (B3.3): a read-only viewport mirror cannot
distinguish idle from dead without a host liveness frame, which is the
Layer-3/followup. The false-positive cost is only a dimmed tile, re-derived on the
model's next refresh.

### Resolved MINOR — line anchors corrected.
- `onRender` is at `Server.zig:1443`; its render-sub loop is `1502-1506`.
- `pushFullFramesTo` is at `Server.zig:1826`; its seed writes are `1857-1858`.
- `subscribeRender` is at `Server.zig:1231`; `handleSubscribeRender` at `1294`.
- `reapConn` at `Server.zig:421` (read-thread join at `422`, fd close `423`);
  deinit shutdown at `2004`; OOM inline free `549-559`; `unsubscribeAll` `564`.
- Client send methods: `focusGained` `685`, `resize` `696`, `queueWrite` `733`,
  `scrollViewport` `757`, `clearScreen` `772`, `reset` `786`, `jumpToPrompt`
  `797`, `selectionDrag` `812`, `selectionClear` `829`, `selectionPoint` `844`,
  `childExitedAbnormally` `857`. Hello send `611`; Attach send `624-628`. The read
  loop is `threadMainPosix` at `Client.zig:1499-1571` (inner read `1529-1562`,
  `n==0` break `1541`, `poll(-1)` `1564`, quit-pipe return `1569`).

### Resolved MINOR — drain-thread spawn under a producer lock.
The seed enqueue (A6 `renderOutEnsure`) is reached from `subscribeRender`
(`Server.zig:1231`), called by `handleSubscribeRender` (`1294`) WHILE
`registry_mutex` is held (`1295`); the live enqueue (A4) runs under `e.mutex`.
Spawning the drain thread under either lock is ACCEPTABLE: `Thread.spawn` is brief
and the new thread takes only its own leaf lock (`RenderOut.mutex`) — no
lock-order edge with `registry_mutex` or `e.mutex`. The spec text says exactly
this ("caller holds registry_mutex or e.mutex; thread-spawn under it is
acceptable — leaf-only new thread"); it does NOT claim the caller holds nothing.

### Resolved MINOR — drops are per-buffer, not per-pair.
`onRender`/seed push `mode` then `grid` as two separate `renderOutPush()` calls
into the CAP-bounded ring. If the ring is full at the pair, the first push drops
the oldest buffer and the second drops the next-oldest, so a mode/grid PAIR
boundary can be split across a drop (momentarily `grid(N-1)` + `mode(N)` +
`grid(N)`). This is HARMLESS because every grid_frame is an ABSOLUTE full snapshot
and the drain delivers buffers in FIFO order, so the consumer converges to the
freshest grid on the next tick. The spec does NOT claim "the unit of delivery is
the pair"; drops are per-buffer and that is safe precisely because grid frames are
absolute.

### Resolved MINOR — labeled-block vs if for subscribe/attach.
B1.3 uses an `if (self.config.role == .mirror) { …subscribe_render… } else
{ …attach… }` form, NOT a labeled-block break.

---

## PART A — bounded-drop render-subscriber delivery (host)

### A0. Design overview
Today `onRender` (`Server.zig:1502-1506`) and the seed `pushFullFramesTo`
(`1857-1858`) write to render subscribers with BLOCKING `posix.write` while
holding `e.mutex` (onRender) / `registry_mutex` (the seed). Replace those direct
writes with an **enqueue into a per-conn bounded RenderOut ring** that a
**dedicated per-conn drain thread** flushes with blocking writes OFF all the
session/registry locks. Enqueue is O(1) under the mutex, drop-oldest on overflow.

Key properties:
- **Leaf lock:** `RenderOut.mutex` is acquired only by (a) the enqueue path while
  holding `e.mutex`/`registry_mutex` and (b) the drain thread holding nothing
  else. It is a strict LEAF (no nested lock acquired while holding it). Lock order
  is `e.mutex` → `RenderOut.mutex` (enqueue), `registry_mutex` → `RenderOut.mutex`
  (seed), and `RenderOut.mutex` alone (drain) — no cycle, no inversion with
  `write_mutex`.
- **Encode decouples from the Snapshot:** the enqueue ENCODES the frame to owned
  bytes (`protocol.encodeFrame`) under the producer call, so the buffered bytes do
  NOT alias the transient `Snapshot`/`ModeFrame` that onRender/seed built (those
  are freed right after, exactly as today). The ring owns `[]u8` buffers.
- **Drop is safe:** grid/mode are absolute snapshots; dropping the oldest buffer
  for a wedged sub loses only a stale frame.
- **Primary GUI `subscribers` and `raw_subscribers` are UNTOUCHED.** Only the
  `render_subscribers` write path changes.

### A1. `RenderOut` struct (new; anchor: just below the `Conn` struct, after `Server.zig:332`)
A bounded outbound ring + drain-thread handle, owned per-`Conn`.
```zig
/// Layer 2 (Agent Dashboard, prereq A): a per-Conn bounded outbound ring for
/// RENDER-subscriber frames (grid_frame/mode_frame), drained by a dedicated
/// thread OFF e.mutex/registry_mutex. grid/mode are ABSOLUTE full-state
/// snapshots, so when the ring is full we DROP the oldest buffer (drop-OLDEST
/// coalescing) rather than block the producer — a wedged remote mirror can no
/// longer stall the session render thread, head-of-line-block the primary GUI
/// `subscribers`, or delay teardownEntry. Scope: render_subscribers ONLY; the
/// GUI `subscribers` (SR-4) and `raw_subscribers` paths are unchanged.
///
/// LOCKING: `mutex` is a strict LEAF. Producers (onRender under e.mutex; the
/// seed under registry_mutex) lock it only to push pre-encoded bytes; the drain
/// thread locks it only to pop. No other lock is taken while holding it, so
/// there is no cycle with e.mutex/registry_mutex/write_mutex.
const RenderOut = struct {
    /// Each entry is an OWNED, already-encoded framed message ([]u8 from
    /// protocol.encodeFrame), so the ring never aliases the transient
    /// Snapshot/ModeFrame the producer built.
    const CAP: usize = 4; // ~2 mode+grid PAIRS; drops are per-buffer (safe: absolute).
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    /// FIFO ring of owned framed buffers; len <= CAP.
    bufs: std.ArrayList([]u8) = .empty,
    /// Set by renderOutTeardown to ask the drain thread to flush-then-exit.
    stop: bool = false,
    /// The drain thread, spawned lazily on the first enqueue (renderOutEnsure).
    thread: ?std.Thread = null,
    /// Guards lazy spawn (flipped under `mutex`).
    started: bool = false,
    /// Count of buffers dropped on overflow (debug/telemetry only).
    dropped: u64 = 0,
};
```
Add a field to `Conn` (anchor: after `write_mutex`, `Server.zig:247`):
```zig
    /// Layer 2 prereq A: bounded outbound ring + drain thread for this conn's
    /// RENDER-subscriber frames. Lazily started on first render enqueue; torn
    /// down (fd .send shut, thread joined, bufs freed) in reapConn / the OOM
    /// inline free. Empty until this conn subscribes_render to something.
    render_out: RenderOut = .{},
```

### A2. `renderOutPush` — enqueue with drop-oldest (method on `Conn`; anchor: near `writeFramed`, `Server.zig:291`)
```zig
/// Layer 2 prereq A: enqueue a render frame for the drain thread. Encodes to
/// owned bytes, pushes onto the bounded ring, and DROPS the oldest buffer on
/// overflow (safe: grid/mode are absolute). Never blocks on the socket. The
/// caller holds e.mutex (onRender) or registry_mutex (seed); this takes only the
/// leaf render_out.mutex. Best-effort: an encode failure logs + drops the frame
/// (the next tick re-sends full state).
fn renderOutPush(self: *Conn, tag: protocol.FrameType, frame: anytype) void {
    if (self.closed.load(.acquire)) return;
    const alloc = self.server.alloc;
    const bytes = protocol.encodeFrame(alloc, tag, frame) catch |err| {
        log.warn("render enqueue encode failed tag={s} err={}", .{ @tagName(tag), err });
        return;
    };
    self.render_out.mutex.lock();
    defer self.render_out.mutex.unlock();
    // Drop-OLDEST until there is room for one more (per-buffer, not per-pair).
    while (self.render_out.bufs.items.len >= RenderOut.CAP) {
        const old = self.render_out.bufs.orderedRemove(0);
        alloc.free(old);
        self.render_out.dropped += 1;
    }
    self.render_out.bufs.append(alloc, bytes) catch {
        alloc.free(bytes); // OOM appending: drop THIS buffer too (best-effort).
        return;
    };
    self.render_out.cond.signal();
}
```
NOTE: `orderedRemove(0)` is O(n) with n ≤ CAP = 4 (trivial); FIFO order preserved.

### A3. `renderDrainLoop` — the drain thread (free fn; anchor: near the other thread fns, after `readLoop`, `Server.zig:562`)
Pops one buffer at a time, releases the ring mutex, then does the BLOCKING write
OFF all session/registry locks.
```zig
/// Layer 2 prereq A: drain thread for a Conn's RENDER outbound ring. Pops one
/// owned framed buffer at a time and writes it with the BLOCKING writeAll OFF
/// e.mutex/registry_mutex, so a wedged remote mirror stalls ONLY this thread,
/// never the session render thread / primary subscribers / teardown. Exits when
/// stop is set and the ring is empty, or when the conn is closed. Touches ONLY
/// this conn (its ring + its fd) — never e/SessionEntry/registry — so it is safe
/// to run after the session is torn down. renderOutTeardown shuts the fd .send
/// half before join so a write blocked on a wedged peer is interrupted.
fn renderDrainLoop(conn: *Conn) void {
    const alloc = conn.server.alloc;
    while (true) {
        var buf: ?[]u8 = null;
        {
            conn.render_out.mutex.lock();
            defer conn.render_out.mutex.unlock();
            while (conn.render_out.bufs.items.len == 0 and !conn.render_out.stop) {
                conn.render_out.cond.wait(&conn.render_out.mutex);
            }
            if (conn.render_out.bufs.items.len > 0) {
                buf = conn.render_out.bufs.orderedRemove(0);
            } else {
                return; // stop && empty -> done.
            }
        }
        if (buf) |b| {
            defer alloc.free(b);
            conn.writeAll(b); // respects conn.closed; sets it on write error.
        }
        // If the conn went closed, free remaining buffers (no point writing) so
        // we exit promptly and leak nothing.
        if (conn.closed.load(.acquire)) {
            conn.render_out.mutex.lock();
            defer conn.render_out.mutex.unlock();
            for (conn.render_out.bufs.items) |b| alloc.free(b);
            conn.render_out.bufs.clearRetainingCapacity();
            if (conn.render_out.stop) return;
            // else loop; it blocks on cond until renderOutTeardown sets stop.
        }
    }
}
```

### A4. `onRender` — replace the render-sub direct writes with enqueue (anchor: `Server.zig:1502-1506`)
Replace the body of the EXISTING render-sub loop. The primary `subscribers` loop
(`1471-1475`) is UNCHANGED.
```zig
    // Layer 2 prereq A: NON-BLOCKING bounded enqueue to RENDER subscribers (was a
    // blocking writeFramed under e.mutex). Drop-oldest on overflow; a per-conn
    // drain thread flushes OFF e.mutex. A wedged remote mirror can no longer
    // stall this session's render thread / the primary GUI subscribers above /
    // teardownEntry. grid/mode are absolute, so per-buffer drops are safe.
    for (e.render_subscribers.items) |conn| {
        if (conn.closed.load(.acquire)) continue;
        conn.renderOutEnsure();              // lazy-spawn the drain thread (idempotent)
        conn.renderOutPush(.mode_frame, mode);
        conn.renderOutPush(.grid_frame, grid);
    }
```
Also EDIT the big LIVENESS/HEAD-OF-LINE WARNING block above the loop
(`Server.zig:1482-1501`): change it to state the HARD FOLLOW-UP it described is now
IMPLEMENTED for render subscribers (bounded drop-on-full + per-conn drain thread),
and that the primary `subscribers` path intentionally retains the SR-4
single-fast-local-peer contract.

### A5. `pushFullFramesTo` seed — enqueue instead of blocking write (anchor: `Server.zig:1857-1858`)
Replace the two seed `conn.writeFramed(...)` writes with the enqueue path so the
seed (under `registry_mutex`) no longer blocks registry-wide work:
```zig
    if (conn.closed.load(.acquire)) return;
    // Layer 2 prereq A: enqueue the seed (was blocking writeFramed under
    // registry_mutex). Same bounded ring + drain thread as the live path, so a
    // wedged mirror cannot stall the registry during subscribe. Lazy-spawn the
    // drain thread here too (under registry_mutex — brief, leaf-only new thread).
    conn.renderOutEnsure();
    conn.renderOutPush(.mode_frame, captured.mode);
    conn.renderOutPush(.grid_frame, grid);
```
Also EDIT `pushFullFramesTo`'s LIVENESS warning (`Server.zig:1846-1856`) to note the
seed now uses the non-blocking ring (the registry-stall window it warned about is
closed).

### A6. `renderOutEnsure` — lazy drain-thread spawn (method on `Conn`; anchor: near renderOutPush, `Server.zig:291`)
```zig
/// Layer 2 prereq A: ensure this conn's render drain thread is running
/// (idempotent). Spawns on first render enqueue. The CALLER holds e.mutex
/// (onRender) or registry_mutex (the seed); the thread-spawn under that lock is
/// acceptable — Thread.spawn is brief and the new thread takes only its own leaf
/// render_out.mutex, introducing no lock-order edge. We take the leaf mutex here
/// to flip `started` so the differing caller locks don't race the guard.
fn renderOutEnsure(self: *Conn) void {
    self.render_out.mutex.lock();
    defer self.render_out.mutex.unlock();
    if (self.render_out.started) return;
    self.render_out.thread = std.Thread.spawn(.{}, renderDrainLoop, .{self}) catch |err| {
        log.warn("render drain thread spawn failed err={}; render frames will drop", .{err});
        return; // leave started=false; renderOutPush still buffers (capped) but
                // nothing drains. Teardown frees bufs regardless -> no leak.
    };
    self.render_out.started = true;
}
```

### A7. Teardown — `renderOutTeardown` + the two call sites (BLOCKER fix)

#### A7.1 `renderOutTeardown` (method on `Conn`; anchor: near reapConn, `Server.zig:421`)
```zig
/// Layer 2 prereq A: stop + join the render drain thread and free the ring.
/// MUST shut the fd's SEND half BEFORE join so a drain thread blocked in a
/// blocking write to a wedged-but-connected peer is interrupted (EPIPE/ENOTCONN)
/// and can observe `stop` — otherwise the reaper would hang (BLOCKER fix,
/// mirroring deinit's posix.shutdown-before-wait at Server.zig:2004). Idempotent
/// and safe when no thread was ever started.
fn renderOutTeardown(self: *Conn) void {
    {
        self.render_out.mutex.lock();
        self.render_out.stop = true;
        self.render_out.cond.signal();
        self.render_out.mutex.unlock();
    }
    // Interrupt any in-flight blocking write to a wedged peer BEFORE join.
    // .send is sufficient (we only block on writes); harmless if already shut.
    if (self.render_out.thread != null) {
        posix.shutdown(self.fd, .send) catch {};
    }
    if (self.render_out.thread) |t| {
        t.join();
        self.render_out.thread = null;
    }
    for (self.render_out.bufs.items) |b| self.server.alloc.free(b);
    self.render_out.bufs.deinit(self.server.alloc);
    self.render_out.bufs = .empty;
}
```
ORDERING / SAFETY:
- `reapConn` joins the read thread and sets `closed` (read thread sets it on
  exit), then `renderOutTeardown` shuts `.send` + joins the drain thread, then
  `reapConn` `posix.close(conn.fd)` once afterward. A `shutdown(.send)` on an fd
  `deinit` already `shutdown(.both)` is harmless (ENOTCONN swallowed).
- `unsubscribeAll` (`Server.zig:518-521`) ran on the read thread BEFORE the conn
  was enqueued for reaping, so the conn is off every `e.render_subscribers` — NO
  producer can enqueue during teardown. The drain thread only flushes ≤ CAP
  buffers, then exits on `stop`.

#### A7.2 Call `renderOutTeardown` from `reapConn` (anchor: `Server.zig:421-429`)
```zig
fn reapConn(self: *Server, conn: *Conn) void {
    if (conn.thread) |t| t.join();
    conn.renderOutTeardown();      // Layer 2 prereq A: stop+join drain (shuts .send first)
    posix.close(conn.fd);
    conn.subscribed.deinit();
    conn.subscribed_raw.deinit();
    conn.subscribed_render.deinit();
    conn.reader.deinit(self.alloc);
    self.alloc.destroy(conn);
}
```

#### A7.3 Call `renderOutTeardown` from the OOM inline free in `readLoop` (anchor: `Server.zig:549-559`)
```zig
    if (oom) {
        // shut-before-close, mirroring reapConn (post-critic fix).
        conn.renderOutTeardown();   // Layer 2 prereq A: stop+join drain (shuts .send first)
        posix.close(conn.fd);
        conn.subscribed.deinit();
        conn.subscribed_raw.deinit();
        conn.subscribed_render.deinit();
        conn.reader.deinit(self.alloc);
        self.alloc.destroy(conn);
        return;
    }
```
NOTE (post-critic MAJOR fix): the original draft closed the fd FIRST and claimed the
close "already interrupted any in-flight blocking write." That is WRONG on POSIX/
Darwin — `close()` does NOT reliably wake another thread blocked in `write()` on the
same fd; the reliable interrupt is `shutdown(.send)`, which is exactly why reapConn
shuts the LIVE fd before joining. With close-first, `renderOutTeardown`'s
`shutdown(.send)` would act on a stale/reused fd (a no-op) and `t.join()` on a parked
drain thread could HANG. So `renderOutTeardown()` (which does shutdown-before-join on
the live fd) MUST run BEFORE `posix.close(conn.fd)`, identical to reapConn. This is
only the OOM-dying-process fallback (a thread leak is already accepted there), but the
ordering still matters for the join to be bounded.

#### A7.4 `deinit` interaction (anchor: `Server.zig:1989-2006`) — NO new edit, verify
`deinit` already `shutdown(conn.fd, .both)` for every live conn (`2002-2005`)
before spinning until `conns` empties; each read thread then exits, unsubscribes,
and self-migrates to `dead_conns`; the reaper drains them and `reapConn` (A7.2)
runs `renderOutTeardown` — whose `shutdown(.send)` is redundant (deinit already
shut `.both`) and harmless, and whose `join` completes because the write was
already interrupted. So `deinit` needs NO change; A7.2 covers the drain-thread
teardown on the shutdown path. The fix makes the NORMAL mid-session reap path
equally safe (the path the review flagged exposed).

### A8. No other host edits
- `subscribeRender`/`handleSubscribeRender`/`addRenderSubscriber`/`teardownEntry`/
  `unsubscribeAll`/`isRenderOnlySubscriber` UNCHANGED (Layer 1). teardownEntry
  still clears `render_subscribers` under `e.mutex` before any conn free; the drain
  thread is conn-local and torn down at reap, so there is no interaction.
- `writeFramed`/`writeAll` UNCHANGED — the drain thread reuses `writeAll` (which
  already locks `write_mutex` and respects `closed`), so render writes stay
  serialized against any other writer on the same conn.
- Primary `subscribers` and `raw_subscribers` paths byte-for-byte unchanged.

---

## PART B — render-mirror surface mode (client + apprt + C header)

### B0. `backend.zig` — NO change required
The mirror role lives entirely inside `termio.Client` (a `Config.role` field +
internal branches). The `Backend` union arms (`backend.zig:28-37`) already
delegate every method to the `.client` Client; the suppression (B2) is implemented
as early-returns INSIDE the Client methods, so the union dispatch is unchanged.
Listed only to record that backend.zig is intentionally untouched. (`.exec` arms
are byte-for-byte unchanged regardless.)

### B1. `src/termio/Client.zig` — mirror role

#### B1.1 Role enum + Config field (anchor: `Config` struct, `Client.zig:262-311`)
```zig
    /// Layer 2 (Agent Dashboard): the backend's ROLE.
    ///   .attach — existing behavior: Hello + Attach (spawn/reattach), owns the
    ///             session's GUI side, drives resize/input/scroll/etc.
    ///   .mirror — READ-ONLY render mirror: Hello + subscribe_render(session_id),
    ///             consumes grid_frame/mode_frame into the SAME RenderState mirror
    ///             the renderer reads, and SUPPRESSES every session-mutating
    ///             outbound frame (resize/input/focus/scroll/clear/reset/jump/
    ///             selection/attach). Owns NO pty; never drives the real session.
    ///             Reachable ONLY under pty-host (a non-zero session_id present).
    pub const Role = enum { attach, mirror };

    /// Layer 2: see Role. Default .attach keeps today's behavior byte-for-byte.
    role: Role = .attach,
```
INVARIANT (mirror reachable only under pty-host): the mirror role is only set by
Surface.zig when `config.@"pty-host"` is non-null AND a non-zero session_id is
present (B4). `connectAndAttach`'s mirror branch (B1.3) guards `session_id != null`
and degrades to a clean no-op (logs; does NOT attach, does NOT subscribe) so it can
never silently spawn a session. `role` is a SCALAR in `Config`, copied by value
through `init` (`Client.zig:358-366`) and the `Termio.init` backend-union MOVE — no
pointer hazard, no new post-move pointer to capture.

#### B1.2 Mirror-state fields (anchor: near `child_exited` / mirror fields, `Client.zig:218`)
```zig
    /// Layer 2 (mirror role): wall-clock ms of the last successfully decoded
    /// frame; the read loop uses it for the liveness timeout. 0 = none yet.
    /// Touched ONLY on the read thread (no lock; the liveness decision is local).
    mirror_last_frame_ms: i64 = 0,
    /// Layer 2 (mirror role): set once when the mirror declares the session gone
    /// (liveness timeout / EOF / read error). Guarded by renderMutex() (the
    /// renderer may read it to draw the terminated state); idempotent fire-once
    /// (markMirrorEnded checks it). Never set under .attach.
    mirror_ended: bool = false,
```

#### B1.3 `connectAndAttach` — subscribe_render vs attach (anchor: Hello+Attach sends, `Client.zig:611-628`)
Keep the Hello send (`611`) for BOTH roles. Replace the single Attach send with a
role branch. CRITICAL structural rule: do NOT early-return — the existing
`_ = self.renderMutex();` (`641`) + read-thread spawn tail (`651-658`) MUST run for
ALL roles (so `threadExit`'s `join` is valid). Gate ONLY the frame send:
```zig
    try sendFrameRaw(client_td, loop, alloc, .hello, protocol.Hello{});

    if (self.config.role == .mirror) {
        // Layer 2: a mirror SUBSCRIBE_RENDERs an existing session instead of
        // attaching. It NEVER sends Attach (which would spawn/reattach + own the
        // session). session_id MUST be present (Surface only builds a mirror with
        // a non-zero id); if absent, log + send nothing (a no-op mirror), never
        // spawn. Seed the session_id atomic so ghostty_surface_session_id() is
        // correct for the mirror (no .attached reply arrives for a render-sub).
        if (self.config.session_id) |sid| {
            try sendFrameRaw(client_td, loop, alloc, .subscribe_render, protocol.SubscribeRender{
                .session_id = sid,
            });
            self.session_id.store(sid, .release); // single-threaded here (read thread not spawned yet)
        } else {
            log.warn("mirror role with no session_id; not subscribing (no-op mirror)", .{});
        }
    } else {
        // .attach (existing behavior, byte-for-byte): spawn/reattach + spawn opts.
        try sendFrameRaw(client_td, loop, alloc, .attach, protocol.Attach{
            .session_id = self.config.session_id,
            .working_directory = self.config.working_directory,
            .initial_input = self.config.initial_input,
        });
    }
```
INVARIANT (mirror outbound frame set = {Hello, subscribe_render} ONLY): in the
mirror path the ONLY `sendFrameRaw` calls are Hello (`611`) and subscribe_render
(or just Hello in the degenerate no-id case). No Attach; B2 suppresses every other
send. Asserted by B-test-2.

#### B1.4 grid_frame/mode_frame consumption — UNCHANGED
`handleFrame`'s `.grid_frame` (`Client.zig:900-912`) and `.mode_frame`
(`914-1002`) arms rehydrate the SAME `self.render_state` mirror and apply modes —
no change. The renderer (`src/renderer/generic.zig`) reads the mirror under
`render_mutex` and is UNCHANGED. A mirror receives EXACTLY the grid_frame/mode_frame
an attached client receives (Layer 1 fans the same frames), so rehydration is
identical — asserted by the difftest (B6.2 B-test-1). For the liveness stamp (B3),
the read loop sets `mirror_last_frame_ms` after a successful `handleFrame`, NOT
inside `handleFrame` (keeps the decode path role-agnostic).
- `.attached` arm (`1004-1026`): a mirror never receives `.attached` (subscribe_render
  seeds grid+mode only). If a buggy host sent one, the existing arm just stores the
  id — harmless. No change.
- `.child_exited` arm (`1028-1047`): a mirror MAY receive a real `.child_exited` if
  the host forwarded one; the existing arm pushes the surface message — desirable
  (shows terminated). No change; the B3 timeout is the PRIMARY session-gone path
  because the render-tee commonly sends no child_exited to a render sub.

### B2. Outbound-frame SUPPRESSION (the read-only mirror never mutates the session)
Add `if (self.config.role == .mirror) return;` as the FIRST statement (before any
`sendFrame` / any local mutation) to EACH session-mutating send method. Each
returns success (benign no-op) so callers treat it as such. This is the CLIENT-side
half of the read-only guarantee; the host's `isRenderOnlySubscriber` (committed
Layer 1) is defense-in-depth.

Methods to gate (anchors):
- `focusGained` (`685`) — a mirror reports no focus.
- `resize` (`696`) — **critical**: a mirror NEVER drives session size. Early-return
  BEFORE the local `self.grid_size`/`self.screen_size` writes (`705-706`) so the
  mirror is fully inert; the host grid (pushed in frames) is authoritative. (Layer 3
  scales the tile from the host grid; it does not resize the mirror.)
- `queueWrite` (`733`) — input suppressed (read-only; inline-reply is a future
  Layer-3 add relaxing ONLY this method, never resize).
- `scrollViewport` (`757`), `clearScreen` (`772`), `reset` (`786`),
  `jumpToPrompt` (`797`), `selectionDrag` (`812`), `selectionClear` (`829`),
  `selectionPoint` (`844`).

DO NOT gate:
- `childExitedAbnormally` (`857`) — sends NO frame; only writes the local
  `self.child_exited` field under the render mutex. Harmless under mirror (and
  effectively never reached: the host owns the child). Leave unchanged.
- `getProcessInfo` (`876`) — already returns null.
- lifecycle/wiring (`deinit`/`threadEnter`/`threadExit`/`initTerminal`/
  `setLocalTerminal`/`renderMutex`) — no outbound session mutation.

Example gate on `resize`:
```zig
pub fn resize(self: *Client, td: *termio.Termio.ThreadData, size: renderer.Size) !void {
    // Layer 2 (mirror role): a READ-ONLY render mirror NEVER drives session size.
    // Suppress the Resize frame entirely (host also gates via
    // isRenderOnlySubscriber — defense in depth). The host grid is authoritative;
    // the mirror renders whatever cols/rows the host pushes.
    if (self.config.role == .mirror) return;
    ... existing body ...
}
```
INVARIANT (additive, .attach unchanged): every gate is `role == .mirror`-only, so
the `.attach` path (and the `.exec` path, which never constructs a Client) is
byte-for-byte unchanged.

### B3. Session-gone handling (client-side liveness, the resolved MAJOR)

#### B3.1 `markMirrorEnded` helper (anchor: near `childExitedAbnormally`, `Client.zig:857`)
```zig
/// Layer 2 (mirror role): declare the mirrored session gone and signal the
/// surface with a quiescent terminated state. Idempotent (fire-once): a second
/// call is a no-op so a recovered-then-stalled session does not double-fire.
/// Called ONLY from the read thread (liveness timeout / EOF / read error in the
/// mirror branch). Does NOT close or mutate anything real — the mirror owns no
/// pty; this only dims the preview. Synthetic exit_code 0 since a mirror cannot
/// know the real exit code in the timeout case. Reuses the EXACT surface path the
/// real .child_exited arm uses (Client.zig:1041-1046).
fn markMirrorEnded(self: *Client) void {
    {
        const m = self.renderMutex();
        m.lock();
        defer m.unlock();
        if (self.mirror_ended) return; // fire-once
        self.mirror_ended = true;
    }
    if (self.surface_mailbox) |mb| _ = mb.push(.{
        .child_exited = .{ .exit_code = 0, .runtime_ms = 0 },
    }, .{ .forever = {} });
    if (self.renderer_wakeup) |*w| w.notify() catch {};
}
```
The mirror's last `render_state` frame stays as-is (frozen) — the renderer keeps
drawing it, which IS the "quiescent" look; Layer 3 overlays a dimmed "session
ended" treatment keyed off the surface's child-exited handling. The client does
NOT clear/blank the mirror (no real state to reset).

#### B3.1-bis (post-critic MAJOR fix) — `Surface.childExited` must NOT self-close a mirror.
`markMirrorEnded` pushes a synthetic `child_exited{exit_code=0, runtime_ms=0}` so
`Surface.childExited` runs. But that handler's DEFAULT path
(`wait-after-command=false`) ends in `self.close()`, and the `runtime_ms <=
abnormal_command_exit_runtime_ms` branch (0 <= 250) would additionally fire the
abnormal-exit GUI/terminal message. So on ANY genuine EOF — including a routine
`ghostty-host` restart (the documented deploy caveat that drops all live sessions)
— every mirror surface would self-CLOSE instead of dimming to a "session ended"
tile, the wrong behavior for a read-only preview. RESOLUTION: add `Surface.isMirror()`
(true iff the `.client` backend is in `.mirror` role) and GUARD `Surface.childExited`
at the top: when `isMirror()`, render a quiescent `"[mirror] session ended."` line
into the LOCAL mirror terminal (the frozen last frame stays beneath it) and RETURN
WITHOUT `self.close()` and WITHOUT `performAction(.show_child_exited)` (a synthetic
exit is not a real process exit). This also moots the related minor where
`childExitedAbnormally` would write into the mirror terminal — a mirror never reaches
that branch now. The mirror owns no pty, so nothing real is touched on either path;
the difference is the SURFACE now persists as a terminated tile rather than being torn
down. (`src/Surface.zig`: `isMirror()` next to `sessionId()`; the guard at the top of
`childExited`.)

#### B3.2 Read-loop liveness — mirror-only timeout (anchor: `threadMainPosix`, `Client.zig:1499-1571`)
Gate ALL new behavior on `client.config.role == .mirror`; the `.attach` path keeps
`poll(-1)` and its EOF/error handling UNCHANGED.

Changes inside `threadMainPosix`:
1. At the top of the mirror branch, record `var mirror_started_ms: i64 =
   std.time.milliTimestamp();` as the baseline for "no frame ever received".
2. After a frame is successfully handled (after `client.handleFrame(...)` succeeds,
   `Client.zig:1553-1560`), for the mirror role set
   `client.mirror_last_frame_ms = std.time.milliTimestamp();`.
3. Replace the `posix.poll(&pollfds, -1)` (`1564`) timeout with a role-dependent
   value: `-1` for `.attach` (unchanged), `MIRROR_POLL_TIMEOUT_MS` (recommended
   **1000 ms**) for `.mirror`.
4. After `poll` returns for the mirror role (timeout or a non-quit wake), compute
   `now - baseline` where `baseline = if (client.mirror_last_frame_ms != 0)
   client.mirror_last_frame_ms else mirror_started_ms`. If the gap ≥
   `MIRROR_LIVENESS_TIMEOUT_MS` (recommended **5000 ms**), call
   `client.markMirrorEnded()` and `return` (end the read thread).
5. EOF (`n == 0`, `1541`) and read errors (`1530-1540`): for the mirror role, call
   `client.markMirrorEnded()` before exiting. Under `.attach`, leave the existing
   `break`/`return` UNCHANGED (EOF on attach is the existing reattach/disconnect
   path, not a child-exit here). For the mirror, conn-drop EOF == genuinely gone.
   SYMMETRY FIX (post-critic): the THREE other fatal read-thread exits also gate
   `if (is_mirror) client.markMirrorEnded();` before their `return` — a
   `reader.push` failure, a `reader.next` decode failure, and a `handleFrame`
   failure (the last two reachable for a LIVE mirror because untrusted host bytes
   can yield `error.InvalidFrame` via the mouse/kitty `intToEnum` guards in
   `handleFrame`). Without this, a corrupt/fatal-decode read-thread exit would
   freeze the mirror tile on its last frame and never deliver the synthetic
   `child_exited`. No deadlock risk: these are NOT under `renderMutex()` and
   `markMirrorEnded` is fire-once.
6. The quit-pipe return (`1569`) is UNCHANGED for both roles (normal surface close;
   it must NOT call markMirrorEnded — that would falsely signal terminated on a
   normal mirror close).

Add near the top of Client.zig:
```zig
/// Layer 2 (mirror role): poll cadence + no-frame liveness window. The mirror
/// declares the session gone after MIRROR_LIVENESS_TIMEOUT_MS without a frame.
/// 5 s is comfortably above the host's ~10 Hz renderTick poll, so a BUSY session
/// is never misdeclared; a long-IDLE-but-alive agent MAY be shown terminated
/// (documented heuristic — a read-only viewport mirror cannot distinguish idle
/// from dead without a host liveness frame, a Layer-3 followup). Mirror-only;
/// .attach uses poll(-1) unchanged.
const MIRROR_POLL_TIMEOUT_MS: i32 = 1000;
const MIRROR_LIVENESS_TIMEOUT_MS: i64 = 5000;
```

#### B3.3 Documented limitation
A genuinely idle-but-alive agent (no output for ≥ 5 s) is shown terminated.
Acceptable for Layer 2 (the dashboard targets active agents) and re-derived on the
model's next refresh / re-mirror. The clean fix (a host-side per-render-subscriber
`session_gone` render frame) is explicitly OUT of Layer-2 scope (an additive
host-protocol change owned by the committed Layer 1) and noted as a
Layer-3/followup. The timeout is chosen because it needs no protocol change and the
false-positive cost is only a dimmed preview tile — nothing real is touched.

### B4. `src/Surface.zig` — construct the mirror role (post-move discipline)

#### B4.1 Read the mirror flag off `rt_surface`; pass `role` (anchor: `.client` branch, `Surface.zig:683-740`)
Inside `if (config.@"pty-host") |sock|`, read a new `mirror` flag off `rt_surface`
defensively (same `@hasField` pattern as `session_id` at `690-693`), and pass
`role`:
```zig
            const req_session_id: u64 = if (@hasField(@TypeOf(rt_surface.*), "session_id"))
                rt_surface.session_id else 0;
            const req_mirror: bool = if (@hasField(@TypeOf(rt_surface.*), "mirror"))
                rt_surface.mirror else false;
            // Layer 2: a mirror is reachable ONLY with a real session to mirror.
            // A mirror flag with session_id 0 has nothing to subscribe to, so
            // degrade to a normal (fresh-spawn) .client surface rather than a dead
            // mirror. (Layer 3 always supplies a non-zero id for a mirror.)
            const role: termio.Client.Role =
                if (req_mirror and req_session_id != 0) .mirror else .attach;
            const io_client = try termio.Client.init(alloc, .{
                .socket_path = sock,
                .render_mutex = mutex,
                .session_id = termio.Client.sessionIdFromConfig(req_session_id),
                .role = role,
                .working_directory = if (config.@"working-directory") |wd| wd.value() else null,
                .initial_input = client_initial_input: { ... unchanged ... },
            });
```
POST-MOVE INVARIANT: `role` is a SCALAR carried inside `Config`, copied by value
through `Client.init` and the `Termio.init` backend-union MOVE. There is NO new
pointer to capture, so the "use the FINAL post-move Client address" invariant is
satisfied trivially — the EXISTING post-move wiring block (`Surface.zig:804-836`,
which reaches `self.io.backend.client` AFTER the move to set
`renderer_state.mirror`, `link_cells`, `setLocalTerminal`, and the cwd seed) is
UNCHANGED and continues to operate on the moved Client. The mirror role needs no
additional post-move reach.

#### B4.2 Mirror cwd seed — leave as-is, harmless
The post-move block seeds `self.io.terminal.setPwd` from `config.@"working-directory"`
(`Surface.zig:835-836`). For a mirror this is typically null (Layer 3 builds a bare
mirror config), so the seed is a no-op; if non-null it only seeds the LOCAL mirror
terminal's pwd (never sent to the host — input/resize suppressed; pwd is not an
outbound frame). No change needed.

#### B4.3 `session_id()` getter — correct for a mirror via B1.3 seed
`Surface.zig:1149-1150` returns the Client's `session_id` atomic. A mirror gets no
`.attached` reply, so without seeding the atomic would read 0. B1.3 seeds it
(`self.session_id.store(sid, .release)`) right after sending subscribe_render
(single-threaded, pre-read-thread), so `ghostty_surface_session_id()` is correct
for a mirror. `.attach` is unaffected (it still gets its id from `.attached`).

### B5. C-ABI — appended `mirror` field (additive, safe default)

#### B5.1 `include/ghostty.h` (anchor: `ghostty_surface_config_s`, `include/ghostty.h:467-487`)
APPEND `bool mirror;` AFTER `context` (current last field):
```c
  uint64_t session_id;
  bool wait_after_command;
  ghostty_surface_context_e context;
  // Layer 2 (Agent Dashboard): when true AND session_id is non-zero AND the
  // `.client` backend is selected (pty-host set), this surface is a READ-ONLY
  // render MIRROR of the existing session_id: it subscribe_renders the session
  // and renders its live grid, and NEVER drives resize/input/etc. Default false
  // = a normal attach/spawn surface (today's behavior). Appended last so the ABI
  // stays additive; old zero-initialized callers get the safe default.
  bool mirror;
} ghostty_surface_config_s;
```

#### B5.2 `embedded.zig` `Surface.Options` (anchor: extern struct, `embedded.zig:432-481`)
APPEND the matching field AFTER `context` (`embedded.zig:480`), same default:
```zig
        /// Context for the new surface
        context: apprt.surface.NewSurfaceContext = .window,

        /// Layer 2 (Agent Dashboard): see ghostty.h. true => this surface is a
        /// READ-ONLY render mirror of `session_id` (requires pty-host + non-zero
        /// session_id). Default false = normal attach/spawn (today's behavior).
        /// Appended last to keep the extern layout additive with the C header.
        mirror: bool = false,
```

#### B5.3 `embedded.zig` `Surface` struct field (anchor: after `session_id`, `embedded.zig:429`)
```zig
    /// Layer 2 (Agent Dashboard): see Options.mirror. Carried from init Options
    /// so the core Surface.init reads it off `rt_surface` when building the
    /// `.client` backend config. Only meaningful with the `.client` backend + a
    /// non-zero session_id.
    mirror: bool = false,
```

#### B5.4 `embedded.zig` `Surface.init` — copy Options → field (anchor: the `self.* = .{ … }`, `embedded.zig:483-499`)
After `.session_id = opts.session_id,` (`498`):
```zig
            .session_id = opts.session_id,
            .mirror = opts.mirror,
```
INVARIANT (additive C-ABI): the new field is appended last in BOTH the C struct
and the extern Zig struct, defaults to false (zero), so an old caller that does not
set it (Swift, pre-Layer-3) gets a non-mirror surface — existing behavior. The
`@hasField` read in Surface.zig (B4.1) means the core compiles even for apprts
(e.g. `none`) whose Surface struct lacks the field.

### B6. Tests

#### B6.1 Part A — host bounded-drop tests (`src/host/test.zig`, `-Dtest-filter=host`)
Reuse the raw-tee/render-tee harness (`Server.init/start/deinit`, `connectUnix`,
`clientSend`, `pollNext`, `ClientReader`, `setRecvTimeout`, `snapshotContainsMarker`,
`FRAME_SCAN_ITERS`).
- **A-test-1 (drop-on-full is safe; no stall — STRENGTHENED with a raw-tee check):**
  attach a PRIMARY conn, subscribe_render a SECOND conn (the wedged/unread render-sub),
  AND subscribe_raw a THIRD conn that IS actively read each iteration. Drive several
  distinct markers on the primary. Assert (a) the PRIMARY keeps receiving fresh
  grid_frames promptly within FRAME_SCAN_ITERS while the render-sub is starved (no
  head-of-line block — the key assertion), (a') the ACTIVELY-READ RAW subscriber also
  observes each marker's raw bytes promptly (the raw-tee is on its own observer path
  and MUST be unaffected by the wedged render-sub — added in this layer), and (b) when
  the render-sub finally reads, it converges to a grid_frame with the LATEST marker
  (drops self-heal because grid_frame is absolute). Test name:
  `host Layer2: slow render-sub does not block the primary OR the raw-tee; drops self-heal`.
- **A-test-2 (wedged render-sub does not hang teardown):** subscribe_render, drive
  output so the drain has work, WEDGE the render-sub peer (stop reading, fill its
  socket buffer), then `Close` the session from the primary. Assert teardown
  completes (a hung reaper would time out the test). Exercises the BLOCKER fix
  (`renderOutTeardown` shuts `.send` before join). Then close the wedged conn and
  assert the server reaps it without UAF.
- **A-test-3 (deinit with a live wedged render-sub):** subscribe_render + wedge,
  then `Server.deinit`; assert clean shutdown (deinit's `shutdown(.both)` + A7.2's
  drain teardown cooperate; no hang, no leak).
- **A-test-4 (drain lifecycle / no leak):** subscribe_render then detach/close
  WITHOUT driving output (drain may or may not have spawned); assert clean reap.
  Then subscribe_render + one frame + close; assert the drain thread spawns, joins,
  and the ring is freed (safety allocator catches a leak).
- **A-test-7 (PRIMARY liveness UNDER a GENUINE wedge — combined; resolves a
  post-impl MAJOR):** the two halves of the no-head-of-line-block contract in ONE
  test. A-test-1 asserts the primary keeps seeing fresh markers but does NOT shrink
  the socket buffers (its render-sub frames are absorbed by the ~1 MiB kernel
  buffer, so it would pass even against the OLD blocking code); A-test-5/6 GENUINELY
  wedge the drain thread but only assert `dropped>0` / `ring<=CAP` / hang-free
  teardown (reading the primary only opportunistically, never asserting it saw the
  LATEST markers). A-test-7 shrinks BOTH socket buffers (`test_tiny_sockbuf` +
  `setTinyRecvBuf`) AND never reads the render-sub (drain thread genuinely PARKS in
  writeAll), THEN for each of 8 markers driven on the primary asserts the PRIMARY
  observes that exact marker promptly, and finally proves the wedge was genuine
  (`dropped>0`, `ring<=CAP`). Against the OLD blocking render write under `e.mutex`
  the parked write would head-of-line-block the session render thread and the
  primary would not see the markers — so this fails-before / passes-after.
- Existing Layer-1 render-tee integration tests MUST still pass (seed + dual
  fan-out now route through the ring): assert the render-sub still receives the
  seeded grid_frame with the marker and a live grid_frame after new output.

#### B6.2 Part B — mirror tests (`-Dtest-filter=client`)
- **B-test-1 (mirror render equality):** in `client_difftest.zig` (or sibling),
  build a Client with `role = .mirror`, feed it the SAME framed grid_frame/mode_frame
  the existing `buildFramed` producer emits, drive `handleFrame`, and assert the
  rehydrated `render_state` mirror is cell-identical to the reference RenderState —
  i.e. the mirror role consumes frames identically to attach (guards that `role`
  did not perturb the decode path).
- **B-test-2 (CRITICAL — mirror outbound frame set):** the headline invariant.
  Drive the connect lifecycle for a `role = .mirror` Client (non-null session_id)
  against a collector that records every framed message the client SENDS (reuse the
  lifecycle harness calling `connectAndAttach` directly with a captured write side,
  or a focused unit test of the send methods with a stub `ThreadData` whose write
  path appends tags to an in-test list). Assert:
  - the outbound set after connect is EXACTLY `{Hello, subscribe_render}` — NO
    `attach` frame is ever sent;
  - each suppressed method (`resize`, `queueWrite`, `focusGained`, `scrollViewport`,
    `clearScreen`, `reset`, `jumpToPrompt`, `selectionDrag`, `selectionClear`,
    `selectionPoint`) produces NO additional outbound frame (count unchanged);
  - for CONTRAST, a `role = .attach` Client sends `{Hello, attach}` and `resize`
    DOES produce a `.resize` frame (proves the gate is role-scoped, not global).
  Minimum bar if the full lifecycle harness is heavy: a unit test asserting each
  suppressed method early-returns without enqueuing, plus that the mirror connect
  path enqueues subscribe_render (not attach) after Hello via the collector.
- **B-test-3 (session-gone signal):** with a mirror Client wired to a capturing
  `surface_mailbox`, call `markMirrorEnded` (the unit-testable core of B3) and
  assert (a) exactly ONE `child_exited` surface message is pushed, (b)
  `mirror_ended == true`, (c) a SECOND `markMirrorEnded` pushes NOTHING (fire-once).
  (The full poll-timeout path is integration-level; the unit test covers the signal
  contract.)
- **B-test-4 (the ACTUAL production session-gone trigger, end-to-end; resolves a
  post-impl MAJOR):** B-test-3 only calls `markMirrorEnded` DIRECTLY and B-test-2
  drives a real mirror read loop but tears down via the QUIT PIPE (not EOF), so the
  `is_mirror`-gated EOF / read-error dispatch in `ReadThread.threadMainPosix` was
  uncovered end-to-end — a regression dropping the `is_mirror` guard on the EOF
  branch, or mis-deriving `is_mirror` from `config.role`, would not be caught.
  B-test-4 builds a `role = .mirror` Client wired to a capturing `surface_mailbox`,
  `connectAndAttach`s it against a `TestListener` that ACCEPTS-AND-HOLDS the peer fd
  (new `startHolding`/`acceptHold` — no drain, no close; the test owns the fd), then
  CLOSES the server peer fd so the client read thread's `read()` returns `n==0`
  (EOF — the genuine session-gone signal a dead host emits). `threadExit` joins the
  read thread (the happens-before that publishes the result); the test asserts
  `mirror_ended == true`, `child_exited != null`, and EXACTLY ONE synthetic
  `child_exited` surface message in the mailbox (the EOF arm fired `markMirrorEnded`
  before returning; the trailing quit-pipe return did NOT re-fire — fire-once held
  across the real path). `TestListener.deinit` does not touch `accepted_fd` in the
  holding mode (the test closes it).

---

## C. Hard-invariant cross-check (each invariant ↔ the edits that satisfy it)

- **`.exec` byte-for-byte unchanged; non-mirror `.client` attach path unchanged.**
  - Part A touches ONLY `render_subscribers` delivery (onRender second loop,
    pushFullFramesTo seed) + new conn-local fields/threads exercised only when a
    conn has subscribed_render; primary `subscribers` (SR-4) and `raw_subscribers`
    untouched (A4, A5, A8). `.exec` never reaches the host Server.
  - Part B's Client changes are ALL gated on `self.config.role == .mirror` (B1.3
    branch, B2 early-returns, B3 read-loop branch). `role` defaults to `.attach`
    (B1.1). `.exec` never constructs a Client. The C-ABI `mirror` defaults false
    (B5). Both unchanged.
- **A mirror NEVER sends a frame that mutates the real session.**
  - B1.3 sends only Hello + subscribe_render in the mirror branch (no Attach).
  - B2 early-returns from every mutating send method under `.mirror`.
  - Asserted by B-test-2 (outbound set == {Hello, subscribe_render}; suppressed
    methods enqueue nothing). Host defense-in-depth: `isRenderOnlySubscriber`
    (committed Layer 1) drops any mutating frame from a render-only conn.
- **Additive C-ABI: appended field, safe default; old callers unaffected.**
  - B5.1/B5.2 APPEND `mirror` (bool) last in both the C struct and the extern Zig
    struct, default false; B5.3/B5.4 carry it; B4.1 reads it via `@hasField`. Old
    zero-initialized callers get a non-mirror surface.
- **pty-host mirror/mutex wiring uses the FINAL post-move Client address.**
  - The role is a SCALAR in `Config`, copied by value through init + the
    backend-union move (B1.1) — NO new pre-move pointer captured. The EXISTING
    post-move wiring (`Surface.zig:804-836`) reaching `self.io.backend.client` is
    unchanged and remains the only reach (B4.1). render_mutex is still threaded via
    `Config.render_mutex` (unchanged), so `renderMutex()` resolves to the
    renderer-state mutex for the mirror exactly as for attach.
- **Crash-safety + additive protocol discipline preserved (host side).**
  - Part A adds NO new frame type and NO protocol change (only HOW render frames
    reach the wire — buffered + drained). subscribe_render decode unchanged (Layer
    1). The drain thread is conn-local (no e/registry deref → no
    broadcast-after-free); RenderOut.mutex is a strict leaf (no lock-order cycle);
    teardown shuts `.send` before join (BLOCKER fix → no reaper hang);
    `unsubscribeAll` still removes the conn from `render_subscribers` before reap
    (no enqueue-after-unsubscribe); bounded CAP + drop-oldest caps memory.

---

## D. Explicitly NOT in Layer 2
- No macOS/Swift source changes (Layer 3) beyond the additive C header.
- No macOS app build/run; no `ghostty-host` deploy/restart. Tests run against the
  in-process test host + the client difftest harness only.
- No host-side `session_gone` render frame (a possible Layer-3/followup; B3.3).
- No inline-reply (a future Layer-3 add relaxing ONLY `queueWrite`, never `resize`).
- No change to the primary GUI `subscribers` (SR-4) or `raw_subscribers` delivery
  semantics.
