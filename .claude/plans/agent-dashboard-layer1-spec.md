# Agent Dashboard — Layer 1 edit spec (host render-tee)

Branch: `ramon-fork`. Scope: a read-only, additive, version-negotiated host
**render subscription** modeled EXACTLY on the existing raw-tee
(`subscribe_raw` / `raw_output`). A client can `subscribe_render(session_id)`
and receive the session's existing `grid_frame` + `mode_frame` stream (seeded
with a full grid+mode frame on subscribe), WITHOUT attaching, WITHOUT driving
resize, WITHOUT owning the session.

Files touched (this layer ONLY):
- `src/host/protocol.zig`
- `src/host/Server.zig`
- `src/host/test.zig`
- (read-only reference: `src/host/Session.zig` — NO edits; the render-tee reuses
  the existing `on_render`/`renderTick` push path unchanged.)

Build/test: `zig build test -Demit-macos-app=false -Demit-xcframework=false -Dtest-filter=host`

This spec is the authoritative, file-by-file edit list. It supersedes the
high-level plan section in `agent-dashboard-plan.md:49-96`; where this spec and
the plan disagree (the seed mechanism, the read-only invariant, and the
`subscribed_render` lifecycle), THIS spec is correct.

All line numbers below are against the source as read on the date of writing;
they are anchors (function names + nearby lines), not exact targets — verify the
named function before editing.

---

## 0. Resolutions of the prior-review findings (read first)

These three points were internally contradictory in the plan; the spec resolves
them as follows, and every edit below is consistent with these resolutions.

### R-A (BLOCKER → resolved): read-only / no-resize invariant is CLIENT-SIDE only.
There is NO per-conn authorization gate in the host: the `.resize` dispatch arm
(`Server.zig:607-677`) applies any well-formed resize to `e.session` for ANY
handshaked conn; sessions have no single "owner conn" concept. Adding host-side
per-conn resize authorization is OUT of Layer-1 scope (it would touch the
attach/own model, not the additive tee).

Therefore Layer 1 does NOT add a host-side resize-rejection gate, and the
invariant is stated and tested as a **client-side convention**:

> A render subscriber is read-only by construction of the CLIENT (Layer 2's
> mirror backend never sends a `resize`/`attach`/`input` frame). `subscribe_render`
> itself NEVER mutates session grid size, ownership, or the subscriber's resize
> rights. The host does not grant a render subscriber any new ability to mutate
> the session that a bare handshaked conn did not already have.

What Layer 1 actually guarantees (and tests, see §4):
1. Receiving a `subscribe_render` frame changes NO session state except adding
   the conn to `e.render_subscribers` and sending it ONE seed frame pair.
2. A conn that ONLY ever sends `hello` + `subscribe_render` (the mirror's exact
   wire behavior) never causes a resize — there is simply no resize frame on its
   wire, so the session grid is unchanged. The negative test asserts EXACTLY
   this: subscribe, drive output, assert the session grid (cols/rows reported on
   the primary's frames) is unchanged. The test does NOT send a resize from the
   render-sub and assert rejection (that would require a host gate that does not
   exist and is out of scope).

The plan's original "a render-sub that sends a Resize is rejected/ignored
without affecting session size" test (plan line 92) is REPLACED by the
subscribe-then-output negative test in §4.4. This removes the contradiction.

### R-B (BLOCKER → resolved): seed-on-subscribe mechanics.
The real raw-tee seed (`handleSubscribeRaw`, `Server.zig:1074-1094`) does NOT
call any broadcast helper — it writes the replay frame DIRECTLY to the single
subscribing conn via `conn.writeFramed`. The real `pushFullFrames`
(`Server.zig:1500-1573`) iterates `e.subscribers` (the GRID-attach list, line
1555), takes NO conn argument, and sends FOUR frame kinds (mode_frame,
grid_frame, at_prompt, and a pwd_change surface_event). Reusing `pushFullFrames`
verbatim would (a) seed the wrong set (grid attachers, not the new render-sub)
and (b) send at_prompt + pwd_change, which are attach-semantics frames a
read-only mirror should not receive.

Resolution: add a NEW helper `pushFullFramesTo(self, conn, e)` that writes ONLY
`mode_frame` + `grid_frame` to the ONE passed `conn`, sharing a single
`render_mutex` capture. This mirrors the `onRender` fan-out content exactly
(onRender writes only mode+grid, `Server.zig:1263-1264`) and the raw-tee's
single-conn direct-write seed pattern. The render-tee seed is **grid+mode only**
— NOT the 4-frame attach seed. `handleSubscribeRender` calls `pushFullFramesTo`.

(We do NOT refactor the existing `pushFullFrames` to take an optional conn — it
is reused by handleAttach with the full 4-frame seed and the broadcast loop, and
muddying it risks the attach path. A separate, smaller helper is cleaner and
keeps the attach path byte-identical.)

### R-C (MAJOR → resolved): `Conn.subscribed_render` lifecycle is fully enumerated.
The map needs init at ONE site and deinit at TWO sites, exactly where
`subscribed_raw` appears:
- init in `setupConn` (`Server.zig:402`)
- deinit in `reapConn` (`Server.zig:352`)
- deinit in the OOM fallback in `readLoop` (`Server.zig:480`)
All three are listed as concrete edits in §2.

### R-D (MAJOR → resolved): tag placement for wire stability.
`subscribe_render` MUST be appended at the END of the `FrameType` enum, AFTER
`raw_output` (`protocol.zig:168`), so all already-deployed minor-1 peers keep
their wire-tag integers (raw_output stays 30, etc.). Inserting mid-enum would
silently renumber `raw_output` and break the just-shipped raw-tee. See §1.

---

## 1. `src/host/protocol.zig`

### 1.1 Minor version bump (anchor: line 44-49)
Current:
```zig
pub const PROTOCOL_VERSION_MAJOR: u16 = 1;
// Bumped to 1 for the additive subscribe_raw / raw_output frames (H1): ...
pub const PROTOCOL_VERSION_MINOR: u16 = 1;
```
Edit: bump the minor literal `1` → `2` and add an additive comment line above it:
```zig
// Bumped to 2 for the additive subscribe_render frame (Layer 1 / render-tee): a
// peer can negotiate this minor to learn the host can stream a session's
// existing grid_frame/mode_frame render stream to a READ-ONLY subscriber
// (no attach, no resize, no ownership). ADDITIVE only — major unchanged, no
// existing frame encoding or enum order touched; the render stream REUSES the
// existing grid_frame/mode_frame payload tags.
pub const PROTOCOL_VERSION_MINOR: u16 = 2;
```
INVARIANT (additive + minor-negotiated): major stays 1; a peer that never sends
`subscribe_render` is byte-for-byte unaffected (the new minor is purely
informational — nothing in the host gates behavior on the negotiated minor for
this layer; the new frame is the only signal).

### 1.2 New frame tag (anchor: end of `FrameType` enum, line 168 `raw_output,` then `};` at 169)
Append AFTER `raw_output` (the current last variant), at the END of the enum, so
all prior tag integers — including `raw_output` — stay stable on the wire (R-D):
```zig
    // --- Layer 1 (Agent Dashboard): READ-ONLY render subscription ---
    // GUI->host: subscribe to a session's existing render stream (the SAME
    // grid_frame + mode_frame an attached client receives) WITHOUT attaching,
    // resizing, or owning the session. On receipt the host registers the conn
    // as a RENDER subscriber, seeds it with one full grid_frame+mode_frame pair
    // at the session's CURRENT size, then forwards live grid_frame/mode_frame as
    // the session renders. payload = session_id (u64). Appended at the END so all
    // prior tag integers (incl raw_output) stay stable.
    subscribe_render,
```
Do NOT add a new render-payload frame: the stream reuses `grid_frame` /
`mode_frame`, which are already pointer-free and fan-out-safe.

### 1.3 New frame struct (anchor: after `SubscribeRaw` decl, line 1078)
Mirror `SubscribeRaw = SessionIdFrame(.subscribe_raw)` exactly:
```zig
/// GUI->host (Layer 1): subscribe to a session's existing RENDER stream
/// (grid_frame + mode_frame). Bare session id, same shape as
/// Detach/Close/Reset/SubscribeRaw. On receipt the host registers the conn as a
/// RENDER subscriber, seeds it with one full grid_frame+mode_frame at the
/// session's current size (pushFullFramesTo), then forwards live grid_frame/
/// mode_frame. READ-ONLY: it never drives resize, never owns the session.
pub const SubscribeRender = SessionIdFrame(.subscribe_render);
```
INVARIANT (crash-safe untrusted decode): `SessionIdFrame.decode` reads one
`u64` via `readInt`, which returns `error.EndOfStream` on a short payload →
`dispatch` propagates the error → `readLoop` closes the conn cleanly (same as
the existing `SubscribeRaw` robustness, test.zig:1081-1088). No new decode code,
no new failure mode.

---

## 2. `src/host/Server.zig`

### 2.1 `SessionEntry.render_subscribers` field (anchor: after `raw_subscribers`, line 128)
Add, parallel to `raw_subscribers`:
```zig
    /// Layer 1 (Agent Dashboard): connections subscribed to this session's
    /// existing RENDER stream (grid_frame + mode_frame) via subscribe_render.
    /// Parallel to `subscribers`/`raw_subscribers` and guarded by the SAME
    /// `mutex`. A conn can be on any combination of the three lists. onRender
    /// iterates this list (under `mutex`) AFTER the `subscribers` loop to
    /// broadcast the SAME grid/mode frames; teardownEntry clears it alongside the
    /// other two. READ-ONLY: a conn on this list has not attached and never
    /// drives resize.
    render_subscribers: std.ArrayList(*Conn) = .empty,
```

### 2.2 `addRenderSubscriber` / `removeRenderSubscriber` (anchor: after `removeRawSubscriber`, line 190, still inside `SessionEntry`)
Mirror `addRawSubscriber`/`removeRawSubscriber` (lines 172-190) verbatim, swapping
the list name. Idempotent add (dedupe scan); swap-remove on removal; both under
`self.mutex`:
```zig
    /// Layer 1: register `conn` as a RENDER-stream subscriber (idempotent).
    fn addRenderSubscriber(self: *SessionEntry, conn: *Conn) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.render_subscribers.items) |c| if (c == conn) return;
        try self.render_subscribers.append(self.server.alloc, conn);
    }

    /// Layer 1: drop `conn` from the RENDER-stream subscriber list. Mirrors
    /// removeRawSubscriber.
    fn removeRenderSubscriber(self: *SessionEntry, conn: *Conn) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var i: usize = 0;
        while (i < self.render_subscribers.items.len) {
            if (self.render_subscribers.items[i] == conn) {
                _ = self.render_subscribers.swapRemove(i);
            } else i += 1;
        }
    }
```
INVARIANT (threading): list guarded by `e.mutex`, identical lock to the other two
lists; no new lock, no new lock-order edge.

### 2.3 `Conn.subscribed_render` field (anchor: after `subscribed_raw`, line 202)
```zig
    /// Layer 1: session_ids this conn is subscribed to for the RENDER stream (so
    /// disconnect/teardown can unsubscribe). Parallel to `subscribed`/
    /// `subscribed_raw`.
    subscribed_render: std.AutoHashMap(u64, void),
```

### 2.4 `Conn.subscribed_render` LIFECYCLE — the three companion sites (R-C)
These are MANDATORY; omitting any of them is a crash (uninitialized map) or a
leak. Each mirrors the `subscribed_raw` line at the same site.

- **init** in `setupConn` (anchor: `Server.zig:401-403`, the `conn.* = .{ … }`
  initializer). After the `.subscribed_raw = ...,` line add:
  ```zig
          .subscribed_render = std.AutoHashMap(u64, void).init(self.alloc),
  ```
- **deinit** in `reapConn` (anchor: `Server.zig:351-353`). After
  `conn.subscribed_raw.deinit();` add:
  ```zig
      conn.subscribed_render.deinit();
  ```
- **deinit** in the OOM fallback in `readLoop` (anchor: `Server.zig:479-482`).
  After `conn.subscribed_raw.deinit();` add:
  ```zig
          conn.subscribed_render.deinit();
  ```

### 2.5 `subscribeRender` helper (anchor: after `subscribeRaw`, line 1059)
Mirror `subscribeRaw` (lines 1054-1059) — OOM ordering: put into
`conn.subscribed_render` FIRST, then `e.addRenderSubscriber`, so `unsubscribeAll`
(which iterates `conn.subscribed_render`) still cleans up if the second step
fails and no broadcast can hold a pointer the disconnect path won't remove:
```zig
/// Layer 1: register `conn` as a RENDER-stream subscriber of `e`. Same
/// OOM-ordering as `subscribe`/`subscribeRaw` (insert into
/// `conn.subscribed_render` FIRST, then `e.render_subscribers`).
fn subscribeRender(self: *Server, conn: *Conn, e: *SessionEntry) !void {
    try conn.subscribed_render.put(e.session_id, {});
    errdefer _ = conn.subscribed_render.remove(e.session_id);
    try e.addRenderSubscriber(conn);
    _ = self;
}
```

### 2.6 `pushFullFramesTo` helper (anchor: immediately after `pushFullFrames`, line 1573) — R-B
A NEW helper that writes ONLY `mode_frame` + `grid_frame` to ONE passed conn,
sharing a single `render_mutex` capture. It does NOT touch `e.subscribers` and
does NOT send at_prompt/pwd_change (those are attach-semantics, not render-tee):
```zig
/// Layer 1: seed a single freshly-subscribed RENDER conn with one full
/// mode_frame + grid_frame at the session's CURRENT size, so a newly attached
/// preview tile renders immediately without waiting a render tick. Mirrors the
/// raw-tee's direct single-conn seed (handleSubscribeRaw writes the ring replay
/// straight to the one conn) and onRender's mode+grid content (NOT
/// pushFullFrames' 4-frame attach seed — a read-only mirror gets no at_prompt /
/// pwd_change). Captures the snapshot + ModeFrame in ONE render_mutex critical
/// section (finding SI-3) so mode and grid share one point-in-time read. The
/// write happens while registry_mutex is held by the caller
/// (handleSubscribeRender), consistent with handleSubscribeRaw's seed write.
fn pushFullFramesTo(self: *Server, conn: *Conn, e: *SessionEntry) !void {
    _ = self;
    const session = e.session;
    const captured = blk: {
        session.render_mutex.lock();
        defer session.render_mutex.unlock();
        const snap = session.captureSnapshotLocked(session.alloc) catch |err| {
            log.warn("render-tee seed snapshot failed err={}", .{err});
            return;
        };
        break :blk .{
            .snapshot = snap,
            .mode = protocol.ModeFrame.fromTerminal(e.session_id, &session.io.terminal),
        };
    };
    var snapshot = captured.snapshot;
    defer snapshot.deinit(session.alloc);
    const grid: protocol.GridFrame = .{ .session_id = e.session_id, .snapshot = snapshot };
    // Single-conn seed; skip if the conn closed between subscribe and seed.
    if (conn.closed.load(.acquire)) return;
    conn.writeFramed(.mode_frame, captured.mode);
    conn.writeFramed(.grid_frame, grid);
}
```
Notes mirrored from `pushFullFrames`:
- Capture via `captureSnapshotLocked` (line 1519) so any active host search
  highlights are flattened in (no-op when no search) — same as the attach seed.
- Snapshot freed with `snapshot.deinit(session.alloc)` after the writes
  (lines 1546-1547 pattern).
- `closed.load(.acquire)` guard before the write (the broadcast loops do this per
  conn at 1262/1556) — here for the single conn.
INVARIANT (no broadcast-after-free / SR-4 fast-peer contract): the seed write
runs under the caller's `registry_mutex` (handleSubscribeRender), identical to
how handleSubscribeRaw writes the replay under registry_mutex — a concurrent
Close/deinit cannot `fetchRemove`+`teardownEntry` `e` between the get() and the
write.

### 2.7 `handleSubscribeRender` (anchor: after `handleSubscribeRaw`, line 1094)
Mirror `handleSubscribeRaw` (1074-1094): hold `registry_mutex` across the whole
entry dereference (F3 TOCTOU), validate the session exists + is live (else
clean-ignore), register, then seed via `pushFullFramesTo` (the seed write happens
under the held registry_mutex, like the raw replay):
```zig
/// Layer 1: handle a `subscribe_render` frame. Validate the session exists + is
/// live (else clean-ignore, mirroring the unknown-id handling in the other
/// dispatch arms / handleSubscribeRaw), register the conn as a RENDER subscriber,
/// then IMMEDIATELY seed one full mode_frame+grid_frame at the current size so
/// the preview renders without waiting a tick. Live grid_frame/mode_frame follow
/// via onRender. READ-ONLY: no resize, no ownership.
///
/// Lock discipline mirrors handleSubscribeRaw/handleAttach: hold registry_mutex
/// across the whole dereference (F3 TOCTOU) so a concurrent Close/deinit can't
/// free `e` mid-use; the seed write happens under that held lock (SR-4 single/
/// local fast-peer contract).
fn handleSubscribeRender(self: *Server, conn: *Conn, session_id: u64) !void {
    self.registry_mutex.lock();
    defer self.registry_mutex.unlock();
    const e = self.sessions.get(session_id) orelse return; // unknown id: ignore
    if (!sessionLive(e)) return; // torn down: ignore
    try self.subscribeRender(conn, e);
    try self.pushFullFramesTo(conn, e);
}
```

### 2.8 Dispatch arm (anchor: after the `.subscribe_raw` arm, line 743-747)
Add a new arm mirroring `.subscribe_raw`. Because the Zig switch over `FrameType`
is exhaustive, adding the `subscribe_render` enum variant forces a compile error
until this arm exists (a safety net, not a hazard):
```zig
        .subscribe_render => {
            var sub = try protocol.SubscribeRender.decode(alloc, frame.payload);
            defer sub.deinit(alloc);
            try self.handleSubscribeRender(conn, sub.session_id);
        },
```
INVARIANT (handshake gate): the pre-Hello reject at lines 538-542 already covers
`subscribe_render` (it is neither `.hello` nor `.ping`), so an un-handshaked conn
that sends it is closed before reaching this arm — no special-casing needed.

INVARIANT (decode/reject discipline, R from review minor): `subscribe_render` is a
CLIENT→host frame, so it gets this real dispatch arm and is NOT added to the
host→client "ignore if received" set at line 893. `grid_frame`/`mode_frame`
remain in that set (already present) — a render subscriber that erroneously sent
one would be logged + ignored, never acted on.

### 2.9 `onRender` second loop (anchor: line 1259-1265) — R for write-safety detail
The mode/grid locals are built ONCE before the `e.mutex` lock (lines 1251-1257)
and reused for BOTH loops. After the existing `e.subscribers` loop
(1261-1265), add a second loop over `e.render_subscribers` writing the SAME
`mode`+`grid`, with the SAME `closed.load(.acquire)` guard:
```zig
    e.mutex.lock();
    defer e.mutex.unlock();
    for (e.subscribers.items) |conn| {
        if (conn.closed.load(.acquire)) continue;
        conn.writeFramed(.mode_frame, mode);
        conn.writeFramed(.grid_frame, grid);
    }
    // Layer 1: fan the SAME mode+grid frames out to read-only RENDER subscribers.
    // Same e.mutex critical section, same mode/grid locals built once above, same
    // per-conn closed-check (no broadcast-after-free). A conn on BOTH lists would
    // receive the pair twice; in practice the mirror conn is on render_subscribers
    // only (it never attaches), so no duplication occurs.
    for (e.render_subscribers.items) |conn| {
        if (conn.closed.load(.acquire)) continue;
        conn.writeFramed(.mode_frame, mode);
        conn.writeFramed(.grid_frame, grid);
    }
```
INVARIANT (no broadcast-after-free): both loops are inside the one `e.mutex`
critical section; `teardownEntry` clears `render_subscribers` under the same
`e.mutex` (§2.11) before any Conn is freed, so a torn-down entry cannot iterate a
freed conn. The per-conn `closed.load(.acquire)` skips a conn whose readLoop has
set closed but whose reap hasn't run yet — identical to the `subscribers` loop.

### 2.10 Cleanup in `unsubscribeAll` (anchor: line 504-513, after the raw block)
Add a THIRD iteration over `conn.subscribed_render`, under the same
`registry_mutex`-per-iteration discipline as the raw block (so a concurrent
handleClose can't free `e` between get() and deref):
```zig
    // Layer 1: also drop any RENDER subscriptions, under the same registry_mutex
    // discipline. A conn can hold render subscriptions for sessions it never
    // grid-subscribed to, so iterate this set separately.
    var rndit = conn.subscribed_render.keyIterator();
    while (rndit.next()) |sid| {
        self.registry_mutex.lock();
        defer self.registry_mutex.unlock();
        if (self.sessions.get(sid.*)) |e| e.removeRenderSubscriber(conn);
    }
```

### 2.11 Cleanup in the `.detach` arm (anchor: line 749-763)
After the raw-removal lines (757-760), add the render-removal pair (a detach ends
all of the session's streams for that conn):
```zig
                // Layer 1: also drop a RENDER subscription for this session.
                e.removeRenderSubscriber(conn);
                _ = conn.subscribed_render.remove(detach.session_id);
```

### 2.12 Cleanup in `teardownEntry` (anchor: line 1621-1628, the `e.mutex`-guarded block)
Clear `render_subscribers` in the SAME `e.mutex` critical section that already
clears `subscribers` + `raw_subscribers`, BEFORE any Conn is freed, so the
onRender render-loop (§2.9) stops touching them:
```zig
        e.mutex.lock();
        e.subscribers.deinit(self.alloc);
        e.subscribers = .empty;
        e.raw_subscribers.deinit(self.alloc);
        e.raw_subscribers = .empty;
        // Layer 1: drop RENDER subscribers in the SAME critical section so the
        // onRender render-loop stops touching them before any Conn is freed.
        e.render_subscribers.deinit(self.alloc);
        e.render_subscribers = .empty;
        e.mutex.unlock();
```

### 2.13 Session.zig — NO EDITS
The render-tee reuses the existing `on_render`/`renderTick` push path unchanged
(`Session.zig:251-252`, the `on_render` callback fired at the end of
`renderTick`). `onRender` in Server.zig already runs on the owning thread and
already builds mode+grid; §2.9 just adds a second subscriber loop. No new
Session field, no new callback, no push-gate change. (Read-only confirmation: the
push gate that decides WHETHER a tick fires is unchanged, so a render subscriber
does not alter when frames are produced — it only receives the frames the session
was already producing.)

---

## 3. Hard-invariant cross-check (every invariant ↔ the edits that satisfy it)

- **`.exec` byte-for-byte unchanged.** No `.exec` code is touched. `on_render`
  is set only by the host `spawnSession` (Server.zig:1144); `.exec` never reaches
  the host Server. The render-tee adds frames/fields gated entirely on a conn
  sending `subscribe_render`. (§1, §2 — additive only.)
- **Read-only: a render subscriber NEVER drives resize / owns the session.**
  `handleSubscribeRender` (§2.7) only adds to `render_subscribers` + sends a seed;
  it touches no resize/own state. There is no host-side resize gate (out of scope,
  R-A); the guarantee is that `subscribe_render` grants no mutation ability and
  the Layer-2 mirror never sends a resize. Tested by the subscribe-then-output
  negative test (§4.4), which asserts the session grid is unchanged after a
  render-sub subscribes and output flows.
- **Crash-safe untrusted-frame discipline.** `SubscribeRender` decode is
  `SessionIdFrame` → `readInt(u64)` → `error.EndOfStream` on short payload →
  clean conn close (no abort/UAF). The dispatch arm propagates the decode error
  to `readLoop`, which closes the conn; the session survives. (§1.3, §2.8;
  robustness test §4.3.)
- **Additive + minor-negotiated.** Minor 1→2 (§1.1); a peer that never sends
  `subscribe_render` is byte-identical to today (no behavior gates on the minor;
  the frame is the only trigger). The tag is appended at the END (§1.2 / R-D) so
  minor-1 raw-tee peers keep stable tag integers.
- **Threading/locking matches the raw-tee.** `render_subscribers` guarded by
  `e.mutex` (§2.1-2.2); seed write under the caller's `registry_mutex` (§2.6-2.7,
  like the raw replay); onRender's second loop inside the existing `e.mutex`
  section (§2.9); teardown clears the list under `e.mutex` before free (§2.12).
  No new lock, no new lock-order edge, no broadcast-after-free.

---

## 4. `src/host/test.zig` — new tests (`-Dtest-filter=host`)

Reuse the existing harness helpers already used by the raw-tee integration test:
`clientSend`, `pollNext`, `ClientReader`, `connectUnix`, `setRecvTimeout`,
`snapshotContainsMarker`, `FRAME_SCAN_ITERS`, `Server.init/start/deinit`.

### 4.1 Frame round-trip (mirror test.zig:1050-1059, the SubscribeRaw block)
Add a block inside the existing "host protocol frame round-trip" test (or a new
`test "host SubscribeRender frame round-trip (Layer 1)"`):
```zig
{
    const orig: protocol.SubscribeRender = .{ .session_id = 424242 };
    const framed = try protocol.encodeFrame(alloc, .subscribe_render, orig);
    defer alloc.free(framed);
    // ... feed FrameReader, expect tag == .subscribe_render, decode, expect eq.
}
```

### 4.2 Minor-version assertion (cheap guard for R-D / additive)
```zig
test "host protocol minor bumped to 2 for subscribe_render (Layer 1)" {
    try testing.expectEqual(@as(u16, 2), protocol.PROTOCOL_VERSION_MINOR);
    try testing.expectEqual(@as(u16, 1), protocol.PROTOCOL_VERSION_MAJOR);
    // raw_output tag integer must be unchanged (wire stability): subscribe_render
    // appended AFTER it.
    try testing.expect(@intFromEnum(protocol.FrameType.subscribe_render) >
        @intFromEnum(protocol.FrameType.raw_output));
}
```

### 4.3 Decode robustness (mirror test.zig:1081-1088)
```zig
test "host SubscribeRender decode robustness (truncated -> error, no panic) Layer 1" {
    const alloc = testing.allocator;
    var short = [_]u8{0} ** 4; // < u64 session_id
    try testing.expectError(error.EndOfStream, protocol.SubscribeRender.decode(alloc, &short));
}
```

### 4.4 Integration: seed + dual fan-out + read-only negative (model on test.zig:2266-2395)
A single integration test, structured like the raw-tee integration test:
```zig
test "host socket integration: subscribe_render seed + live dual fan-out + read-only (Layer 1)" {
    // 1. init/start a Server on a tmp sock; hello+attach a PRIMARY conn -> get
    //    session_id; record the primary's grid size from the Attached frame
    //    (cols0/rows0) — this is the read-only baseline.
    // 2. Drive a marker through the child (printf), wait for it on a grid_frame
    //    on the PRIMARY (so we know the session is live and rendering).
    // 3. Open a SECOND conn; hello; clientSend .subscribe_render
    //    SubscribeRender{ .session_id = session_id }.
    // 4. SEED ASSERTION: the render-sub receives a mode_frame AND a grid_frame
    //    immediately (the pushFullFramesTo seed), and the seeded grid_frame's
    //    snapshot contains the marker (it was already on screen). Decode the
    //    grid_frame; assert snapshotContainsMarker == true.
    // 5. LIVE DUAL FAN-OUT: drive a NEW marker (printf RENDER_LIVE) on the
    //    PRIMARY; assert it arrives as a grid_frame on BOTH the primary conn and
    //    the render-sub conn (prove onRender's second loop, not just the seed).
    // 6. READ-ONLY NEGATIVE (R-A): the render-sub NEVER sent a resize; assert the
    //    session grid is UNCHANGED — i.e. a grid_frame decoded on the render-sub
    //    reports the same cols/rows as the baseline cols0/rows0 (use the snapshot
    //    dims or a follow-up Attached on a reattach). The render-sub subscribing +
    //    receiving frames did not reflow the session.
    // 7. close the session; brief sleep; let deinit reap.
}
```
Assertions, concretely:
- Seed: find a `.mode_frame` and a `.grid_frame` on the render-sub conn before any
  new output; `snapshotContainsMarker(seeded_grid, "RAW...marker")` (reuse the
  step-2 marker).
- Dual fan-out: a fresh marker appears on a `.grid_frame` for BOTH conns within
  `FRAME_SCAN_ITERS` polls each.
- Read-only: the render-sub's grid_frame snapshot dims equal the baseline dims
  (no reflow). (The render-sub sends ONLY hello + subscribe_render, so there is no
  resize on its wire — this is the §0 R-A assertion in test form.)

### 4.5 Teardown / detach removes the render-sub; no broadcast-after-free
Either a dedicated small test or assertions appended to an existing teardown test
(model on test.zig:2472 "tears down a naturally-exited session cleanly"):
- After `subscribe_render` then `close` the session: the render-sub conn either
  gets a clean child_exited/EOF and the server reaps without UAF (the test
  completes — a UAF would crash under the test allocator / safety build).
- After `detach` from a conn that also subscribed_render: `removeRenderSubscriber`
  + `conn.subscribed_render.remove` run; a subsequent server deinit reaps cleanly.
(The strongest practical guard is that the existing reap/teardown tests run to
completion under the safety allocator with the new list populated — a
broadcast-after-free or leak would fail the test harness.)

---

## 5. What is explicitly NOT in Layer 1
- No host-side per-conn resize/ownership gate (R-A; out of scope).
- No macOS/Swift changes.
- No Layer 2 (mirror surface mode) or Layer 3 (panel) code.
- No `Session.zig` edits.
- No deploy/restart of any live `ghostty-host`. Tests run against the in-process
  test host only (`Server.init`/`start`/`deinit` on a tmp socket).
