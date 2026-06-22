# Agent Dashboard — Layer 2 FIX-PASS spec (resolve Critic items; score was 86)

Branch: `ramon-fork`. Layer 1 committed (`6497b5451`). Layer 2 PRODUCTION code is
ALREADY in the working tree (UNCOMMITTED) and was reviewed correct/safe/faithful.
This pass fixes the FOUR remaining Critic items. **UNLIKE a normal layer, the
IMPLEMENT phase OWNS BOTH production AND test changes** (these fixes are largely
test work). The VerifyDeterminism phase then PROVES the two flaky wedge tests are
now deterministic.

Specs: `.claude/plans/agent-dashboard-layer2-spec.md` (Layer-2),
`.claude/plans/agent-dashboard-plan.md` (overall).

Build/test (each ONE streaming command, timeout up to 600000ms):
```
zig build -Demit-macos-app=false -Demit-xcframework=false
zig build test -Demit-macos-app=false -Demit-xcframework=false -Dtest-filter=host
zig build test -Demit-macos-app=false -Demit-xcframework=false -Dtest-filter=client
```
Do NOT touch macOS/Swift (Layer 3; C header edits are fine but none are needed here).
Do NOT build/run the macOS app. Do NOT deploy/restart any live `ghostty-host`.

**TEST-DISCOVERY RULE (verified against `build.zig:42-46,352`):** `-Dtest-filter`
matches test **NAMES** (substring), NOT file paths. The host suite's tests are
named `"host …"`; the client suite's tests are named `"client …"`. **Every new
test MUST carry the right substring in its NAME or it silently never runs under the
listed commands.** (Critic MINOR 1 — addressed explicitly per fix.)

All line numbers are anchors verified against the WORKING TREE as read on the spec
date (the uncommitted Layer-2 code already shifted some Layer-2-spec anchors); find
the named function before editing.

---

## HARD INVARIANTS (unchanged from Layer 2 — cross-referenced per fix)

- **I1** `.exec` byte-for-byte unchanged.
- **I2** non-mirror `.client` ATTACH path unchanged (a real attach client's
  `.child_exited` still closes via the existing Surface flow; buffered-exit replay
  on reattach unchanged).
- **I3** a mirror NEVER emits a session-mutating frame.
- **I4** additive C-ABI (no C-header change is required by this pass).
- **I5** crash-safety: checked decode, bounded lengths, no broadcast-after-free,
  no new lock-order inversion.
- **I6** bounded-drop PRODUCTION semantics stay correct: CAP ring, drop-oldest,
  drain off `e.mutex`, shutdown-before-join teardown.
- **I7** primary GUI `subscribers` + raw-tee (`raw_subscribers`) semantics
  unchanged.

---

## FIX 1 [BLOCKER] — DETERMINISTIC bounded-drop wedge tests (drain-pause seam)

### 1.0 The defect
Two host tests assert overflow happened (`dropped>0`, `ring==CAP`) after a fixed
`std.Thread.sleep`, relying on REAL socket backpressure with test-shrunk 2048-byte
`SO_SNDBUF`/`SO_RCVBUF` that Darwin clamps to a kernel floor. Under CPU load the
per-conn drain thread (`renderDrainLoop`, `Server.zig:500`) keeps up, the ring
never exceeds CAP, `dropped` stays 0, and the test SIGABRTs (~40% under load,
passes on idle):

- **A-test-5** — `"host Layer2: bounded-drop genuinely fires …"`, assert block
  `test.zig:4155-4169` (the `expect(dropped > 0)` at `4165`).
- **A-test-6** — `"host Layer2: GENUINELY wedged drain thread (full socket
  buffers) does not hang teardown (BLOCKER fix)"`, sanity block
  `test.zig:4267-4272` (`expectEqual(CAP, …)` at `4269`, `expect(dropped > 0)` at
  `4268`).

The PRODUCTION invariant `ring_len <= CAP` is correct and always holds: the drop
happens SYNCHRONOUSLY in `renderOutPush` under the leaf mutex
(`Server.zig:356-376` — the `while (… >= RenderOut.CAP) orderedRemove(0)` loop),
INDEPENDENT of the drain thread. The flakiness is ONLY the *test*'s reliance on the
drain thread falling behind to MANUFACTURE the overflow. The sibling A-test-7
already uses `<= CAP` (`test.zig:4414`); A-test-6's `expectEqual(CAP, …)` at `4269`
is the strict one.

### 1.1 PRODUCTION seam — a TEST-ONLY drain-pause gate (ZERO production change when unpaused)

Add to the `RenderOut` struct (`Server.zig:473-490`, after `dropped: u64 = 0;`):
```zig
    /// TEST-ONLY drain gate. When true, renderDrainLoop parks instead of
    /// popping/writing, so a test can DETERMINISTICALLY overflow the ring
    /// (push CAP+N frames with no consumer) without depending on real socket
    /// backpressure / sleeps. Defaults false in production: when false the drain
    /// loop's predicate is byte-for-byte the original, so there is ZERO production
    /// behavior change. Settable ONLY from tests (Conn.setDrainPausedForTest).
    /// Atomic so the test thread may flip it while the drain thread reads it.
    drain_paused: std.atomic.Value(bool) = .init(false),
```

In `renderDrainLoop` (`Server.zig:500-535`), gate the pop. The ONLY change is the
`cond.wait` predicate plus an early `continue` when paused — everything else
(drop-on-closed, FIFO pop, blocking `writeAll` off all locks, `stop`+empty→return)
is unchanged. Replace the inner critical section:
```zig
        {
            conn.render_out.mutex.lock();
            defer conn.render_out.mutex.unlock();
            // TEST-ONLY pause gate: when paused, do NOT pop/write; park on cond
            // until unpaused, stopped, or a fresh signal. stop ALWAYS wins (so
            // teardown can join even while paused — preserves the BLOCKER-fix
            // discipline). In production drain_paused is always false, so this
            // reduces to the original `bufs.len == 0 and !stop` wait.
            while ((conn.render_out.bufs.items.len == 0 or conn.render_out.drain_paused.load(.acquire))
                and !conn.render_out.stop)
            {
                conn.render_out.cond.wait(&conn.render_out.mutex);
            }
            if (!conn.render_out.stop and conn.render_out.drain_paused.load(.acquire)) {
                // Woken but still paused (a push signaled while paused): re-park.
                continue;
            }
            if (conn.render_out.bufs.items.len > 0) {
                buf = conn.render_out.bufs.orderedRemove(0);
            } else {
                return; // stop && empty -> done.
            }
        }
```
> **`stop`-wins discipline (preserves I6 + the BLOCKER fix).** `renderOutTeardown`
> sets `stop=true`+signals BEFORE `shutdown(.send)`+join (`Server.zig:403-435`).
> Because `stop` short-circuits the wait (`and !stop`) AND the `continue` re-park
> is gated on `!stop`, a PAUSED drain thread STILL wakes at teardown and proceeds
> to drain-remaining/return — so the pause seam can NEVER wedge teardown. (When
> `stop` is set with the ring non-empty, the loop falls through, pops one buffer,
> writes it — to a still-open peer — and re-loops until empty, identical to the
> existing flush-then-exit semantics. This is correct because A-test-6 (1.3) shuts
> the peer first, so `writeAll` returns promptly via `closed`/EPIPE.)

Add the TEST-ONLY setter as a method on `Conn` (near the other
`renderOut*ForTest` helpers, `Server.zig:437-457`):
```zig
    /// TEST-ONLY: pause/resume this conn's render drain thread. Paused, the drain
    /// thread parks WITHOUT consuming the ring, so a test can deterministically
    /// fill it past CAP (forcing drop-oldest in renderOutPush) and assert
    /// renderOutLenForTest()==CAP / renderOutDroppedForTest()>0 with NO dependence
    /// on socket backpressure. Resuming signals the cond so the drain resumes and
    /// the ring drains to the (now-readable) peer. Production never calls this.
    pub fn setDrainPausedForTest(self: *Conn, paused: bool) void {
        self.render_out.mutex.lock();
        defer self.render_out.mutex.unlock();
        self.render_out.drain_paused.store(paused, .release);
        self.render_out.cond.signal();
    }
```
> `drain_paused` is a STRICT LEAF (only flipped under `render_out.mutex` for the
> signal + read via the atomic load in the loop) — no new lock edge (I5).
> Production default `false` ⇒ the loop predicate is the original ⇒ ZERO production
> change (I6).

### 1.2 Rewrite A-test-5 — deterministic, timing-INDEPENDENT
Replace the whole body of `"host Layer2: bounded-drop genuinely fires …"` (the test
around `test.zig:4155-4173` + its setup above). The new test does NOT shrink socket
buffers, does NOT drive 40 ticks, and has NO `std.Thread.sleep` for the overflow
assertion. Shape:

1. `Server.init` + `start()` (NO `test_tiny_sockbuf`). PRIMARY: hello → attach →
   capture `session_id` (reuse the existing hello/attach/`FRAME_SCAN_ITERS` scan at
   `test.zig:4215-4232`). `defer server.deinit()`.
2. Connect a render-sub conn `rndc`: hello → `subscribe_render{session_id}`. Do NOT
   shrink its RCVBUF; the pause seam — not backpressure — manufactures the overflow.
   `defer posix.close(rndc)`.
3. **Bounded-iteration poll** (NOT a sleep) for the render-sub to register and its
   drain thread to spawn: loop ≤ `FRAME_SCAN_ITERS`, each iteration drive one tiny
   `input` line on the primary + drain a couple primary frames (keeps the session
   ticking so `onRender`→`renderOutEnsure` runs), checking
   `server.firstRenderSubscriberForTest(session_id) != null`; break when present.
   `const sub = server.firstRenderSubscriberForTest(session_id).?;`
4. `sub.setDrainPausedForTest(true);` — PAUSE the drain. From here the ring can only
   grow.
5. Drive ≥ `CAP+2` mode/grid frames onto the now-undrained ring: loop `CAP*2 + 4`
   (~12) iterations, each sending a distinct `input` printf line on the primary and
   draining a couple of the PRIMARY's own frames (so the session render thread keeps
   ticking and `onRender` keeps calling `renderOutPush`, where the drop happens
   synchronously). Use a SHORT bounded inner poll, not a fixed sleep; the OUTCOME is
   independent of its duration because the gate guarantees no draining.
6. **Deterministic asserts (NO sleep before them):**
   - `try testing.expectEqual(Server.Conn.RENDER_OUT_CAP_FOR_TEST, sub.renderOutLenForTest());`
     — with the drain paused the ring is pinned EXACTLY at CAP (drop-oldest in
     `renderOutPush` caps it; nothing consumes it). `== CAP` is the stronger
     deterministic claim and the point of the seam. (`<= CAP` also holds if a
     reviewer prefers the looser form.)
   - `try testing.expect(sub.renderOutDroppedForTest() > 0);` — we pushed > CAP, so
     drop-oldest MUST have fired. Deterministic (independent of the drain thread).
7. `sub.setDrainPausedForTest(false);` — RESUME.
8. **Recovery assert (BOUNDED-iteration poll, NOT a sleep — Critic MINOR for
   step 8).** Default to the **fd-read** path with a bounded `FRAME_SCAN_ITERS`
   poll: now READ `rndc` (it was never drained), drive ONE more distinct marker on
   the primary, and scan ≤ `FRAME_SCAN_ITERS` reads of `rndc` for a `grid_frame`
   whose snapshot contains the latest marker (`snapshotContainsMarker`,
   `test.zig:2063`). Assert it is found. The poll is bounded-iteration (each
   `pollNext` has a small per-call timeout), so the OUTCOME is timing-INDEPENDENT
   (it finds the marker within the bound or fails — no flaky pass on a fixed
   wall-clock). Acceptable fallback if fd-read proves awkward: assert
   `renderOutLenForTest()` shrinks below CAP within the SAME bounded poll after
   resume. Prefer fd-read (proves end-to-end delivery recovered).
9. `clientSend(.close)` and return (`defer server.deinit()` joins everything via the
   BLOCKER-fix teardown).

Rename to keep the substring `host` + reflect determinism, e.g.
`"host Layer2: bounded-drop is DETERMINISTIC under a paused drain (ring==CAP, dropped>0, recovers on resume)"`.

### 1.3 Rewrite A-test-6 — deterministic teardown-doesn't-hang under a PAUSED drain
A-test-6 proves the BLOCKER fix: teardown must not hang when the drain thread is
parked. Replace the REAL-backpressure wedge (tiny buffers + screen-filling output +
250ms sleep) with the deterministic pause seam, but KEEP the exact teardown
discipline it proves (explicit `deinit` while the wedged peer's READ side is open;
close the peer only AFTER deinit returns). Shape:

1. `Server.init` (NO `test_tiny_sockbuf` needed). **No `defer server.deinit()`**
   (deinit is called explicitly at the end — preserve the comment block at
   `test.zig:4194-4201`, lightly updated: the parked-drain state now comes from the
   pause seam, and the unblock at teardown comes from `stop` winning over
   `drain_paused` in the loop predicate, NOT from a kernel write-unblock).
2. `server.start()`. PRIMARY: hello → attach → `session_id`.
3. Render-sub `rndc` (a MANUAL fd; closed AFTER deinit, NOT via `defer`): hello →
   `subscribe_render`. NO RCVBUF shrink.
4. Bounded-iteration poll for `const sub = firstRenderSubscriberForTest(session_id).?`
   (as in 1.2 step 3).
5. `sub.setDrainPausedForTest(true);` — PARK the drain thread DETERMINISTICALLY.
6. Drive `CAP*2 + 4` distinct `input` lines on the primary (draining a couple
   primary frames each iter), so the ring is pinned at CAP with `dropped>0` — the
   "wedged" state, caused by the gate, not backpressure.
7. **Deterministic sanity (NO sleep):**
   - `try testing.expect(sub.renderOutDroppedForTest() > 0);`
   - `try testing.expectEqual(Server.Conn.RENDER_OUT_CAP_FOR_TEST, sub.renderOutLenForTest());`
     — `== CAP` is DETERMINISTIC because the drain is paused (this is the strict
     assert the Critic flagged at `4269`; under the gate it is provable so it does
     NOT need relaxing. `<= CAP` matches the A-test-7 sibling at `4414` and is also
     acceptable.)
8. **Teardown (UNCHANGED discipline):** `posix.shutdown(rndc, .send)` (peer
   half-closes WRITE → server readLoop sees EOF → enqueues the conn for reaping →
   `reapConn` → `renderOutTeardown`). Then `server.deinit();`. With the pause seam,
   `renderOutTeardown` sets `stop=true`+signals; the loop predicate (1.1) makes
   `stop` WIN over `drain_paused`, so the parked thread wakes, drains the remaining
   buffers to the now-shut peer (`writeAll` returns promptly via `closed`/EPIPE) and
   returns; `t.join()` completes; deinit returns promptly. **No
   `setDrainPausedForTest(false)` before teardown** (the `stop`-wins predicate is
   the proof — and is exactly the production teardown path). VerifyDeterminism
   mutation check: dropping the `and !stop` term from the predicate makes this test
   HANG (the parked thread never wakes at teardown) — the SAME class of fault as the
   original shutdown-before-join removal.
9. `posix.close(rndc);` AFTER deinit returns.

Rename to keep `host`, e.g.
`"host Layer2: teardown does not hang with a PAUSED (deterministically parked) drain thread (BLOCKER fix)"`.

> **A-test-7 LEFT AS-IS** (`test.zig:4319-4421`): the head-of-line-block proof,
> already `<= CAP` (`4414`) + per-marker `expect(found)`. Its `dropped > 0` at
> `4413` still relies on real backpressure, but a spurious `dropped==0` there only
> WEAKENS (cannot falsely fail) the head-of-line claim, whose real asserts are the
> primary-marker checks. Optionally the implementer MAY add the pause seam there for
> symmetry, but it is NOT required by this pass (the two FLAGGED flaky tests are 5
> and 6). If touched, keep the primary-marker asserts intact.

Invariants: I6 (gate is test-only; production drop semantics unchanged), I5 (leaf
atomic, no new lock edge), I1/I2/I3/I7 (host-test-only).

---

## FIX 2 [M1] — remove the dead session-ended overlay write + correct the comment

### 2.0 The defect
`Surface.childExited`'s `isMirror()` branch (`Surface.zig:1478-1487`) writes
`"[mirror] session ended."` into `self.renderer_state.terminal` (carriageReturn /
linefeed / printString / `cursor_visible=false`). But a `.client` mirror's renderer
draws from `state.mirror` (= `&Client.render_state`), NEVER the local
`renderer_state.terminal`: `renderer/generic.zig:1229` is
`if (state.mirror) |mirror| copyFrom(mirror) else update(state.terminal)`, and
`renderer_state.mirror` is non-null for EVERY `.client` surface. So the overlay text
is NEVER drawn — DEAD code + a MISLEADING comment.

### 2.1 The fix
In `Surface.zig` `childExited` (`1478-1487`), replace the dead-write `isMirror()`
branch with a no-write early return that states the truth:
```zig
    // Layer 2 (Agent Dashboard): a render MIRROR owns no pty and must NEVER close
    // anything real on a session-gone signal. `markMirrorEnded` (and the host's M2
    // child_exited forward) synthesizes a child_exited purely to DRIVE this handler;
    // the normal flow would fall through to `self.close()` (and, on the
    // runtime<=abnormal-threshold branch, an abnormal-exit GUI/terminal message),
    // tearing down a valid preview tile on any genuine session-gone — including a
    // routine ghostty-host restart. For a mirror we return WITHOUT closing and
    // WITHOUT performAction(.show_child_exited) (a synthetic exit is not a real
    // process exit).
    //
    // We do NOT write any "session ended" text into renderer_state.terminal: a
    // .client mirror's renderer draws from `state.mirror` (= &Client.render_state),
    // NEVER the local terminal (renderer/generic.zig: `if (state.mirror) |m|
    // copyFrom(m) else update(state.terminal)`, and renderer_state.mirror is
    // non-null for every .client surface), so such a write would never be drawn.
    // The OPERATIVE behavior is: the FROZEN last frame persists (the renderer keeps
    // drawing the last grid_frame) + the synthetic child_exited signal with NO
    // self.close(). Layer 3 dims/overlays the terminated tile.
    if (self.mirrorChildExitShouldDim()) {
        return;
    }
```
> The guard now calls the pure predicate `mirrorChildExitShouldDim()` added in
> FIX 4a (== `isMirror()`); this makes the guard key unit-testable. Removes the
> `renderer_state.mutex.lock()`/`unlock()` + the four terminal mutations.
> `self.child_exited = true;` at the TOP of `childExited` (`Surface.zig:1463`) STAYS
> (read by the surface's own close/exit bookkeeping; harmless on a mirror). The
> early `return` is BEFORE the abnormal-exit branch and `self.close()`, so the
> architectural signal (synthetic child_exited, NO close) is intact.

Invariants: I1 (`.exec` → `isMirror` false, branch never taken), I2 (non-mirror
`.client` attach → false → unchanged close flow), I3 (no frame emitted), I5 (only a
dead write removed).

---

## FIX 3 [M2] — child-exit-while-host-alive: broadcast child_exited to render_subscribers (ADDITIVE, non-blocking)

### 3.0 The defect
`onChildExited` (`Server.zig:1758-1779`) broadcasts `.child_exited` ONLY to
`e.subscribers` (the blocking-write GUI list, `1775-1778`), NOT
`e.render_subscribers`. So when the real agent process exits but the host stays
alive (the COMMON Agent-Dashboard case), a mirror gets NO frame: its socket stays
open (no EOF), so `markMirrorEnded` (EOF/read-error/fatal-decode only, per the
Layer-2 silence-is-not-death design) never fires, and the tile shows a stale frozen
frame forever, never declaring "ended".

### 3.1 Host fix — also broadcast child_exited to render_subscribers via the NON-BLOCKING path
In `onChildExited` (`Server.zig:1767-1778`), inside the EXISTING `e.mutex` critical
section, AFTER the primary `subscribers` loop, ADD a second loop over
`e.render_subscribers` delivering via the **non-blocking render path**
(`renderOutEnsure` + `renderOutPush`), NOT a blocking `writeFramed` under `e.mutex`.
Reuses the EXISTING `.child_exited` frame (`ce`) — NO new frame, fully additive —
and stays consistent with the bounded-drop design so a slow mirror can't stall
`onChildExited`:
```zig
    e.buffered_child_exited = ce;
    for (e.subscribers.items) |conn| {
        if (conn.closed.load(.acquire)) continue;
        conn.writeFramed(.child_exited, ce);
    }
    // Layer 2 FIX (M2): the child exited while the HOST stays alive (the common
    // Agent-Dashboard case — host outlives one agent). A render MIRROR's socket
    // does NOT see EOF here (the conn stays open), so its client-side
    // markMirrorEnded (EOF/read-error only) never fires and the tile would freeze
    // forever. Deliver the SAME child_exited frame to render subscribers too —
    // ADDITIVE (reuses the existing frame; no protocol change) — but via the
    // NON-BLOCKING render path (renderOutEnsure + renderOutPush enqueues onto the
    // per-conn bounded ring drained off e.mutex), NEVER a blocking writeFramed
    // under e.mutex, so a wedged mirror can't stall onChildExited (consistent with
    // the onRender bounded-drop design). The frame is absolute (a terminal signal);
    // the ring's drop-oldest is safe (child_exited is the last meaningful frame).
    for (e.render_subscribers.items) |conn| {
        if (conn.closed.load(.acquire)) continue;
        conn.renderOutEnsure();
        conn.renderOutPush(.child_exited, ce);
    }
```
> **Crash-safety / lock-order (I5):** identical discipline to `onRender`'s render
> loop (`Server.zig:1748-1753`) — under `e.mutex`, `closed`-checked, `renderOutPush`
> takes only the leaf `render_out.mutex` (no new lock edge; no broadcast-after-free
> because `teardownEntry` clears `render_subscribers` under `e.mutex` before any
> conn free, `Server.zig:2170-2173`). `renderOutPush(tag, frame: anytype)`
> `encodeFrame`s into OWNED bytes (`Server.zig:356-376`), so `.child_exited`+`ce`
> (a `protocol.ChildExited`) encodes fine, no aliasing of `ce`.
>
> **Buffered-exit replay unchanged (I2):** `e.buffered_child_exited = ce` and
> `deliverBufferedExit` (`Server.zig:2112-2128`, blocking write to `subscribers` on
> reattach) are UNTOUCHED — a real ATTACH client still gets the buffered exit on
> reattach exactly as before. The session stays alive host-side regardless.

### 3.2 Protocol minor doc — NO bump required
The `.child_exited` frame already exists and is already in the host→client
decode-accept set (`Server.zig:1304`; the client decodes it at `Client.zig:1162`).
Sending it to a render subscriber is a NEW DESTINATION for an EXISTING frame —
additive, no wire-format change, no minor bump (I4). OPTIONAL: a one-line comment in
`src/host/protocol.zig` near the `child_exited` tag ("also delivered to
render_subscribers (Layer 2 M2) via the bounded render path"). No code/minor change.

### 3.3 Client fix — a MIRROR receiving child_exited calls markMirrorEnded (NOT the attach close path)
In `Client.zig` `handleFrame`'s `.child_exited` arm (`1162-1181`), branch on role.
The attach arm (`self.child_exited = …` + mailbox push) stays for `.attach` (I2).
For a mirror, signal render-quiescent instead of the close path. **DEADLOCK HAZARD
(verified):** `handleFrame` holds `renderMutex()` for the whole switch
(`Client.zig:1029-1031`); the existing `markMirrorEnded` (`Client.zig:987-1004`)
RE-LOCKS `renderMutex()` — calling it here self-deadlocks. Resolve by SPLITTING
`markMirrorEnded` into a caller-holds-the-lock core + a self-locking wrapper.

**Edit A — split `markMirrorEnded` (`Client.zig:987-1004`):**
```zig
/// CALLER MUST HOLD renderMutex(). Fire-once core: marks the mirror ended, sets the
/// local child_exited parity field, pushes the synthetic child_exited surface
/// message + wakes the renderer. Returns true if it fired (false if already ended).
/// Lets handleFrame's .child_exited arm (which ALREADY holds renderMutex) signal
/// session-gone WITHOUT re-locking (which would self-deadlock).
fn markMirrorEndedLocked(self: *Client) bool {
    if (self.mirror_ended) return false; // fire-once
    self.mirror_ended = true;
    self.child_exited = .{ .exit_code = 0, .runtime_ms = 0 };
    if (self.surface_mailbox) |mb| _ = mb.push(.{
        .child_exited = .{ .exit_code = 0, .runtime_ms = 0 },
    }, .{ .forever = {} });
    if (self.renderer_wakeup) |*w| w.notify() catch {};
    return true;
}

/// Self-locking wrapper: declare the mirror session gone. Called from the read
/// thread (EOF / read-error / fatal-decode) where renderMutex is NOT held. Takes
/// the guard, then delegates. Idempotent (fire-once).
pub fn markMirrorEnded(self: *Client) void {
    const m = self.renderMutex();
    m.lock();
    defer m.unlock();
    _ = self.markMirrorEndedLocked();
}
```
> The mailbox `push` + `renderer_wakeup.notify()` now run UNDER `renderMutex` in
> BOTH paths. SAFE: the existing real `.child_exited`/`.grid_frame` arms already
> push the mailbox + notify under the same held `renderMutex`
> (`Client.zig:1045,1175-1180`) — established discipline; the mailbox queue + wakeup
> eventfd are their own synchronization, not ordered under `renderMutex`. (The prior
> `markMirrorEnded` pushed OUTSIDE the lock; moving it inside matches handleFrame's
> arms and removes a TOCTOU on `mirror_ended` between unlock and push. B-test-3/4
> still pass: they call `markMirrorEnded` (the wrapper) directly / via EOF, and the
> observable contract — one message, fire-once, `mirror_ended`+`child_exited` set —
> is unchanged.)

**Edit B — the `.child_exited` arm role branch (`Client.zig:1162-1181`):**
Move the field write INTO the role branches (Critic MINOR 2: the top-of-arm write
would, on a REPEAT child_exited to a mirror, leave `self.child_exited` holding the
REAL exit code while `markMirrorEndedLocked` returns false and never re-signals).
Replace the arm body:
```zig
        .child_exited => {
            const ce = try protocol.ChildExited.decode(alloc, payload);
            if (self.config.role == .mirror) {
                // Layer 2 FIX (M2): the host forwarded a child_exited to this render
                // subscriber because the real agent exited while the host stays
                // alive. A mirror owns NO pty and must NOT take the attach close
                // path. markMirrorEndedLocked (we ALREADY hold renderMutex here)
                // sets the quiescent terminated state + signals the surface;
                // Surface.childExited's mirror guard renders it WITHOUT self.close().
                // Fire-once: a repeat child_exited is a no-op (the field is set
                // inside the locked core only on first fire, so a repeat never
                // overwrites it with a stale-but-unmirrored value).
                _ = self.markMirrorEndedLocked();
            } else {
                // .attach (existing behavior, byte-for-byte): record + deliver to
                // the surface so Surface.childExited runs the normal close/show-
                // exited flow (what .exec does from its IO thread). Without this a
                // real .client tab HANGS on `exit`.
                self.child_exited = .{
                    .exit_code = ce.exit_code,
                    .runtime_ms = ce.runtime_ms,
                };
                if (self.surface_mailbox) |mb| _ = mb.push(.{
                    .child_exited = .{
                        .exit_code = ce.exit_code,
                        .runtime_ms = ce.runtime_ms,
                    },
                }, .{ .forever = {} });
            }
        },
```
> MOOTS Critic MINOR 2 (no top-of-arm field write; the attach write is in `else`,
> the mirror write is inside `markMirrorEndedLocked` on first fire only). `ce` is
> decoded for the attach branch and harmlessly unused by the mirror branch — the
> synthetic {0,0} is intentional (parity with the EOF path); a future Layer wanting
> the real code can read `ce` here.

Invariants: I2 (the `else` arm is the EXISTING attach field write + mailbox push,
byte-for-byte), I3 (mirror emits no frame), I1 (`.exec` never builds a Client), I5
(the split REMOVES the re-lock deadlock; no new lock edge).

---

## FIX 4 — the MISSING guard tests (session-gone guard + the M2 render-sub path)

### 4.0 What must be proven
- **(4a)** `Surface.childExited`'s mirror guard (`Surface.zig:1478…`) RETURNS
  WITHOUT `self.close()`. A regression dropping the guard would make every mirror
  self-CLOSE on a routine ghostty-host restart (EOF) instead of dimming.
- **(4b)** [FIX 3] a render subscriber RECEIVES `.child_exited` when the child exits
  while the host stays alive; and a mirror Client receiving `.child_exited` fires
  `markMirrorEnded` (not the attach close path).

### 4a — Surface session-gone guard test (CLIENT suite, so it actually runs)

**TEST-DISCOVERY (Critic MINOR 1):** name it with the substring `client` so it runs
under `-Dtest-filter=client`. **Placement: `src/termio/client_difftest.zig`** (a
sibling of `Client.zig`, matched by the `client` filter). Do NOT place it in
`Surface.zig` with a non-matching name.

`Surface.childExited` is FILE-PRIVATE and a real `*Surface` is heavy to construct in
a unit test, so test the DECISION as a pure predicate (the Critic-blessed
pure-function extraction):

1. Add a pure predicate next to `isMirror` (`Surface.zig:1174`):
   ```zig
   /// Layer 2: the decision childExited makes on its FIRST branch — whether this
   /// surface is a read-only mirror (dims, never closes) vs a real attach/exec
   /// surface (runs the normal close/show-exited flow). Extracted as a pure
   /// predicate so the guard key is unit-testable without a live Surface (the real
   /// childExited is file-private and needs a full surface). childExited calls
   /// `if (self.mirrorChildExitShouldDim()) return;` instead of inlining isMirror().
   pub fn mirrorChildExitShouldDim(self: *Surface) bool {
       return self.isMirror();
   }
   ```
   `childExited`'s guard (FIX 2) calls it:
   `if (self.mirrorChildExitShouldDim()) { return; }`.

2. The test in `client_difftest.zig`, named e.g.
   `"client mirror Surface.childExited dims (never closes); attach uses the close flow (Layer 2 FIX)"`:
   - The Surface predicate is `isMirror()` == `config.role == .mirror`. Build a
     `role = .mirror` Client (`Client.init(alloc, .{ .role = .mirror,
     .session_id = 0x… })`) and a `role = .attach` Client (default) and assert the
     guard KEY:
     - mirror: `try testing.expect(client_mirror.config.role == .mirror);` (⇒ the
       Surface predicate returns true ⇒ `childExited` returns WITHOUT `self.close()`),
     - attach: `try testing.expect(client_attach.config.role == .attach);` (⇒
       predicate false ⇒ the close/show-exited flow runs).
   - Document in the test why this is the strongest buildable guard: the end-to-end
     "no self.close()" is ALSO proven structurally (FIX 2's early `return` precedes
     `self.close()`) + by the existing B-test-4 (mirror EOF fires `markMirrorEnded`,
     the surface gets the synthetic child_exited). The regression caught: deleting
     `if (self.mirrorChildExitShouldDim()) return;` makes the consumer fall through
     to `self.close()` — the predicate-contract test pins the branch key.
   > If a `*Surface` can be cheaply faked in-suite, the implementer MAY instead
   > assert `Surface.isMirror()` / `mirrorChildExitShouldDim()` directly on a
   > fake-backed Surface — preferred if buildable; otherwise the role-keyed
   > predicate above is the buildable equivalent.

### 4b — render-sub receives child_exited (HOST suite) + mirror Client handles it (CLIENT suite)

**(i) HOST integration test (name contains `host`):**
`"host Layer2 M2: child exits while host alive -> render subscriber receives child_exited"`.
Reuse the A-test helpers (`clientSend`, `pollNext`, `ClientReader`, `FRAME_SCAN_ITERS`):
1. `Server.init` + `start()`; `defer server.deinit()`.
2. PRIMARY: hello → attach. Trigger a quick child exit: after `attached`, send an
   `input` frame `"exit\n"` to the session (simplest + does not depend on the
   `Attach.initial_input` field name; if `initial_input` IS available on
   `protocol.Attach`, `Attach{ .session_id = null, .initial_input = "exit\n" }` is
   also fine). Capture `session_id`.
3. RENDER-SUB `rndc`: hello → `subscribe_render{session_id}`; drain its seed frames
   with a bounded poll. `defer posix.close(rndc)`.
4. **Assert (BOUNDED-iteration poll, NOT a sleep):** scan ≤ `FRAME_SCAN_ITERS` reads
   of `rndc` for a `.child_exited` frame; decode it; assert its `session_id`
   matches. `try testing.expect(found_child_exited);`. The render-sub conn stays
   OPEN (no EOF) — the whole point: WITHOUT FIX 3 the render-sub would get nothing.
5. The session may auto-tear after the child exits; the test asserts only that the
   render-sub OBSERVED `child_exited` first. `server.deinit()` cleans up.
> Folds in a crash-safety check by construction: the render-sub never drives a
> mutating frame; the host delivers `child_exited` via the bounded ring (no blocking
> write under `e.mutex`).

**(ii) CLIENT unit test (name contains `client`) — extend the B-test-3/4 region:**
`"client mirror handleFrame .child_exited fires markMirrorEnded, not the attach close path (Layer 2 FIX M2)"`.
Mirror B-test-3 (`client_difftest.zig:2568`) + the `.child_exited` decode test
(`1314`):
1. Build a `role = .mirror` Client wired to a capturing `surface_mailbox`
   (`captureMailbox` / the inline capture, `client_difftest.zig:1353,2641-2655`).
2. `try testing.expect(!client.mirror_ended);`
3. Encode `protocol.ChildExited{ .session_id = …, .exit_code = 137, .runtime_ms = 9 }`
   and feed it: `try client.handleFrame(alloc, .child_exited, p);` — exercises the
   REAL renderMutex-held path → `markMirrorEndedLocked` (proves NO self-deadlock).
4. Assert: `client.mirror_ended == true`; EXACTLY ONE `child_exited` surface message
   in the queue (`drainOne` / `queue.pop`), tag `.child_exited`;
   `client.child_exited != null` with `exit_code == 0` and `runtime_ms == 0` (the
   SYNTHETIC terminated state — NOT {137,9} from the frame — proving the mirror used
   the terminated path, not the attach record). A SECOND
   `handleFrame(.child_exited)` is a no-op (fire-once): no second mailbox message,
   `mirror_ended` still true.
5. CONTRAST: a `role = .attach` Client fed the same frame sets
   `client.child_exited.?.exit_code == 137` and pushes a child_exited message
   (already proven by `"client handleFrame .child_exited records exit_code +
   runtime_ms"`, `1314`). Add only: assert the attach Client did NOT set
   `mirror_ended` — pins the role split with minimal duplication.

Invariants for FIX 4: I1 (`.exec` not exercised; predicate false for exec), I2 (the
attach contrast proves the close-flow key is intact), I3/I5/I6/I7 (tests only).

---

## VerifyDeterminism phase (proves FIX 1)

After IMPLEMENT (production + tests):
```
zig build -Demit-macos-app=false -Demit-xcframework=false
zig build test -Demit-macos-app=false -Demit-xcframework=false -Dtest-filter=host
zig build test -Demit-macos-app=false -Demit-xcframework=false -Dtest-filter=client
```
Then prove timing-INDEPENDENCE: run the host suite REPEATEDLY UNDER CPU LOAD (e.g.
`for i in $(seq 1 20)` of the host test command, optionally with a background
`yes > /dev/null &` load generator) and confirm ALL runs pass with NO SIGABRT — the
original A-test-5/6 SIGABRTed ~40% under load. Record the run count + load in
`determinismEvidence`. Structural proofs backing the empirical loop: (a) `== CAP` is
deterministic under the pause gate (no consumer), (b) the `and !stop` predicate term
is required or A-test-6 hangs at teardown (the mutation check).

---

## File-touch summary (this pass)
- `src/host/Server.zig` — FIX 1 (`RenderOut.drain_paused` atomic +
  `Conn.setDrainPausedForTest` + `renderDrainLoop` predicate); FIX 3
  (`onChildExited` render_subscribers loop via `renderOutEnsure`/`renderOutPush`).
- `src/host/test.zig` — FIX 1 (rewrite A-test-5 + A-test-6 deterministically);
  FIX 4b(i) (new host M2 integration test).
- `src/termio/Client.zig` — FIX 3 (split `markMirrorEnded` → `markMirrorEndedLocked`
  + wrapper; `.child_exited` arm role branch).
- `src/termio/client_difftest.zig` — FIX 4a (mirror-dim-vs-attach-close predicate
  test); FIX 4b(ii) (mirror `handleFrame .child_exited` → `markMirrorEnded` test).
- `src/Surface.zig` — FIX 2 (remove dead overlay write + correct comment); FIX 4a
  (add `mirrorChildExitShouldDim` pure predicate + call it from `childExited`'s
  guard).
- `src/host/protocol.zig` — OPTIONAL one-line doc note near `child_exited` (no
  code/minor change). NO C-header change required this pass (I4).

No macOS/Swift edits. No build/run of the macOS app. No live-host deploy.

---

## POST-CRITIC RESOLUTION (this fix pass — resolves the remaining MAJOR + minors)

The first iteration's Critic found the headline four fixes correct/safe but flagged
ONE MAJOR + several minors. Resolved here:

- **[MAJOR — FIX 4a tautology] RESOLVED.** The 4a guard test previously asserted only
  `client.config.role == .mirror/.attach` and NEVER invoked the predicate it was
  extracted to pin, so a regression in `Surface.isMirror()`'s backend-union switch
  (`.client => |*c| c.config.role == .mirror`, `.exec => false`) was uncaught. NOW the
  test builds a `*Surface` whose ONLY initialized field is `io.backend` (the predicate
  dereferences nothing else), moves the just-built Client into the union, and INVOKES
  `surface.isMirror()` / `surface.mirrorChildExitShouldDim()` directly — for both the
  `.client{mirror}` (true) and `.client{attach}` (false) arms. A NEW sibling test pins
  the third switch arm: a Surface with `io.backend = .{ .exec = undefined }` asserts
  both predicates return false WITHOUT touching the (undefined) Exec payload (the
  `.exec => false` arm is a constant). The backend-union switch is now fully exercised.
  (`src/termio/client_difftest.zig`, two `client …` tests.)

- **[MINOR] Stale `markMirrorEndedLocked` doc.** The old `markMirrorEnded` docblock
  (asserting "Called ONLY from the read thread on a GENUINE socket signal—EOF" and
  "`pub` so the difftest harness can unit-test") was left stacked atop the locked-core
  docblock, contradicting the locked core's real caller context. Trimmed: the locked
  core now documents only its caller-holds-lock contract; the full mirror-role
  session-gone semantics moved to the `markMirrorEnded` wrapper docblock, which also now
  notes the M2 path calls the locked core directly from handleFrame. (`Client.zig`.)

- **[MINOR] Mirror poll-error asymmetry.** `threadMainPosix`'s `posix.poll()` error path
  returned WITHOUT `markMirrorEnded()` for the mirror role, asymmetric with the
  EOF/read-error/fatal-decode paths (a mirror whose poll errored would freeze on its
  last frame). Now gated `if (is_mirror) client.markMirrorEnded();` like the siblings.
  (`Client.zig`.)

- **[MINOR] CAP-headroom dependency undocumented.** `onChildExited`'s render-sub loop
  relies on child_exited surviving the CAP=4 drop-oldest ring. Added an explicit
  CAP-HEADROOM note: render-stop fires same-tick so no later grid frames push after the
  exit; the single post-exit tick pushes ≤3 frames ≤ CAP; documented the future-change
  invariant (keep per-tick render pushes ≤ CAP-1 so a trailing grid_frame can never
  evict child_exited). (`Server.zig`.)

- **[MINOR] M2 host test lacked a session-survival assert.** Added
  `try testing.expect(server.firstRenderSubscriberForTest(session_id) != null);` after
  the child_exited receive — proving the SessionEntry was NOT torn down by the child
  exit (the whole point distinguishing it from the EOF path). (Removed a flawed
  "conn still open" probe: `pollNext` returns `null` on BOTH timeout and EOF, so it
  cannot distinguish them; the survival assert is the sound evidence.) (`test.zig`.)

- **[MINOR] Dead re-park branch in renderDrainLoop.** Annotated as PROVABLY DEAD in
  production (drain_paused always false there) and reachable only in the test-paused
  case — correct, harmless, `!stop`-gated so teardown is never wedged. (`Server.zig`.)

- **[MINOR — out of scope, documented] `terminal/search/Thread.zig` flake.** The host
  test BINARY pulls in an unrelated pre-existing test (`terminal.search.Thread.test_0`,
  an unnamed `test {` with a 100ms `timedWait`) that intermittently SIGABRTs under heavy
  CPU load (~15% of runs at 6-8x load here). It is NOT a Layer-2 test, is untouched by
  this diff, and every such failing run still reports `N/N selected tests passed` with
  the sole signal-6 being `terminal.search.Thread.test_0`. Left as-is per scope; future
  maintainers should not mistake it for a Layer-2 regression. The Layer-2 wedge/M2 tests
  had ZERO assertion failures across 12 loaded runs.

### Determinism evidence (FIX 1)
Lib builds clean. Host suite: 3x idle PASS + clean idle PASS; client suite: 2x PASS.
Under 6x `yes` CPU load, 12 runs of `-Dtest-filter="host Layer2"`: 0/12 Layer-2
regressions (10 exit 0; the 2 non-zero exits were both the unrelated
`terminal.search.Thread.test_0` flake, all with the Layer-2 tests passing). The
original A-test-5/6 SIGABRTed ~40% under load on their OWN assertions; that is gone —
the drain-pause gate makes the overflow (`ring==CAP`, `dropped>0`) deterministic and
timing-independent.

### SECOND-CRITIC RESOLUTION — client-side determinism BLOCKER (B-test-4)

The headline four fixes were confirmed correct/safe, but a SECOND critic round found
ONE remaining BLOCKER (plus the same item restated as a MAJOR): the client test
`"client mirror read loop fires markMirrorEnded on a GENUINE socket EOF (Layer 2)"`
(B-test-4, `client_difftest.zig:2624`, assert at `:2684 expect(client.mirror_ended)`)
was NON-DETERMINISTIC under CPU load (~2/10 fail at 6x), the SAME flaky-test class
FIX 1 set out to kill, on the client side.

**Root cause (TEST ordering, not a product bug):** `ReadThread.threadMainPosix`
(`Client.zig:1771-1789`) checks the QUIT pipe BEFORE re-reading the socket
(`if (pollfds[1].revents & POLL.IN != 0) return;`, `Client.zig:1782`). The test
closed the peer fd then IMMEDIATELY called `client.threadExit` (writes the quit byte)
with no happens-before for the EOF observation. Under load a single poll wake could
see BOTH the socket EOF (POLLHUP/POLLIN) AND the quit byte ready; the quit branch
won, the loop returned WITHOUT re-reading the n==0 EOF that calls `markMirrorEnded`,
so `mirror_ended` stayed false. Production is unaffected (the surface is torn down on
either path); this was purely test determinism.

**FIX (test-only, `client_difftest.zig:2667-2682`):** after closing the peer fd and
BEFORE calling `threadExit`, BOUNDED-POLL on `client.mirror_ended` becoming true
(≤1000 × 1ms; converges in a few ms since the closed peer is always readable=EOF), so
the EOF observation happens-before the quit byte. The poll is bounded-iteration, so
the outcome is timing-INDEPENDENT (it converges within budget on any load, or fails
deterministically — never a flaky pass racing `threadExit`). The subsequent
`threadExit` join remains the definitive happens-before that publishes `mirror_ended`
+ the mailbox message. NO production change; the comment block was rewritten to state
the real ordering guarantee (the prior comment falsely claimed the EOF arm runs
"before any quit byte is even processed", which the code did NOT guarantee).

**Determinism evidence (this round):** lib build clean. Host suite 5/5 (4 idle + 1
under 6x `yes` load), exit 0. Client suite 5/5 under 6x load + 10/10 under 8x `yes`
load (B-test-4 was ~2/10 before the fix) — zero failures.

### Safety-lens re-verification (independent critic re-run)
Lib build clean (`zig build -Demit-macos-app=false -Demit-xcframework=false`). Host
suite exit 0; client suite exit 0 (idle). Under 6x `yes` CPU load: 27 grouped
`-Dtest-filter="host Layer2"` runs + 22 isolated runs of each rewritten wedge test —
ZERO failures attributable to a Layer-2 test (the wedge tests reported pass in every
run, e.g. `68/69 passed`/`69/69 passed`). Every non-zero exit was the pre-existing,
untouched, out-of-scope `terminal.search.Thread.test_0` (`std.Thread.Futex` timedWait
`reached unreachable` panic) — never a Layer-2 assertion. BLOCKER confirmed fixed.
Concurrency invariants spot-checked against the diff: (I5) `onChildExited`'s new
render-sub loop runs under `e.mutex`, `closed`-checked, taking only the leaf
`render_out.mutex` (same edge as `onRender` — no new lock-order cycle, no
broadcast-after-free since `teardownEntry` clears `render_subscribers` under `e.mutex`);
the drain-pause seam is a strict leaf atomic flipped only under `render_out.mutex`, and
the `and !stop` predicate term makes `stop` win over `drain_paused` so teardown can
never wedge (A-test-6's mutation check); `markMirrorEnded` correctly split into a
caller-holds-lock core (called from `handleFrame` which holds `renderMutex` across the
switch) + a self-locking wrapper (read-thread EOF path) — no self-deadlock; the mirror
`.child_exited` arm calls the locked core and never the attach close path (verified by
the client tests + the role-keyed Surface-predicate tests).
