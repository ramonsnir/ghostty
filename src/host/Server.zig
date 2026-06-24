//! Phase 2a transport Server: an AF_UNIX SOCK_STREAM listener that accepts GUI
//! connections, owns the session registry (session_id -> Session), and routes
//! the framed protocol (src/host/protocol.zig) between GUI clients and the
//! Phase-1 Session emulation.
//!
//! ## Threading model
//!
//! The Server runs three classes of threads, all plain `std.Thread`s; it does
//! NOT share the Session's xev render loop (keeps the GPU-free invariant and
//! avoids reworking Phase-1's single-thread render-loop/destroy ordering):
//!
//!   - one ACCEPT thread, blocking in `accept()`;
//!   - one READ thread per connection, blocking in `read()` + decoding frames;
//!   - one OWNING thread per Session, which calls `start()` -> `runRenderLoop()`
//!     -> `destroy()` (Phase-1 binds the render loop + destroy to one thread,
//!     so this is exactly that thread). The render-tick push callback fires on
//!     this thread.
//!
//! Connection threads only ENQUEUE mailbox messages onto a Session (Input /
//! Resize / Focus), which is thread-safe via `Termio.queueMessage`. They never
//! touch the render loop. The render-tick push callback serializes a GridFrame
//! (+ ModeFrame) and writes to subscriber fds under `SessionEntry.mutex`.
//!
//! ## Invariants (plan §3.3/§6, unchanged from Phase 1)
//!
//! `renderer_state.inspector` stays null; no apprt.embedded App/Surface/
//! Inspector; backend `.exec`; renderer mailbox drains exactly
//! {.resize,.reset_cursor_blink}; Termio reused verbatim. The Server adds no
//! GPU symbols (pure posix sockets + std).

const Server = @This();

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

const renderer = @import("../renderer.zig");
const CoreSurface = @import("../Surface.zig");

const Session = @import("Session.zig");
const RenderState = @import("RenderState.zig");
const protocol = @import("protocol.zig");
const proc_info = @import("../os/main.zig").proc_info;

const log = std.log.scoped(.host_server);

/// 1 MiB socket buffers so a full grid frame never short-writes (plan §2).
const SOCKET_BUF: c_int = 1 * 1024 * 1024;

alloc: Allocator,

/// The bound, listening AF_UNIX socket.
listen_fd: posix.socket_t,
/// The bound socket path, owned (unlinked on deinit).
path: []const u8,

/// Registry of live sessions, keyed by host-assigned session_id. Ids are RANDOM
/// 64-bit values (see allocSessionId), not a sequential counter — so a session_id
/// the GUI persisted from a PREVIOUS host instance cannot collide with a fresh id
/// after a host restart (which would cause a false reattach: a tab silently binding
/// to a different/younger session, or two tabs sharing one). 0 is the reserved
/// "unattached" sentinel.
sessions: std.AutoHashMap(u64, *SessionEntry),
registry_mutex: std.Thread.Mutex = .{},

/// All open connections + the reaping queue. BOTH lists are guarded by the one
/// `conns_mutex` so a read thread's migration (remove from `conns` + append to
/// `dead_conns`) is atomic w.r.t. the reaper's emptiness check — closing the
/// in-flight window where a conn is on neither list.
conns: std.ArrayList(*Conn) = .empty,
conns_mutex: std.Thread.Mutex = .{},

/// Connections whose read thread has exited (EOF/error) and which are awaiting
/// reaping (thread join + free). A read thread cannot join itself, so it hands
/// its Conn here for the reaper thread to reclaim. Fixes the per-reconnect fd +
/// Conn + thread-handle leak on a long-lived host (findings P4 / F5). Guarded
/// by `conns_mutex` (see above).
dead_conns: std.ArrayList(*Conn) = .empty,
reaper_signal: std.Thread.Semaphore = .{},
reaper_thread: ?std.Thread = null,
/// Cleared by deinit to tell the reaper to drain everything + exit. The reaper
/// is the SINGLE owner of conn joins + frees (normal disconnect AND shutdown),
/// so there is never a conns/dead_conns ownership race with deinit.
reaper_running: std.atomic.Value(bool) = .init(true),

/// Idle-leak fix: a SEPARATE, PERIODIC reaper for dead (child-exited / start-failed),
/// zero-subscriber sessions. The .client GUI never sends an explicit Close, so a parked
/// dead session (its Session never destroyed, its io thread never joined) would leak
/// forever (threads + fds + the 256 KiB raw_ring). Unlike the conn reaper above
/// (signal-driven via `reaper_signal`), session death is never signaled, so this thread
/// wakes on a TIMED wait (~5 s) and scans the registry (`reapSessionsOnce`). The event is
/// ONE-SHOT: set ONLY by deinit to signal shutdown (never reset); a timeout just means
/// "time to scan".
session_reaper_thread: ?std.Thread = null,
session_reaper_event: std.Thread.ResetEvent = .{},
session_reaper_running: std.atomic.Value(bool) = .init(true),

/// Idle-leak fix: monotonic-ms epoch captured at init. `monoNowMs()` measures the
/// reaper's grace window against it. `std.time.milliTimestamp()` is deliberately NOT
/// used (wall-clock can jump under NTP and skew/break the grace window). Set in init().
mono_epoch: std.time.Instant = undefined,

host_pid: i32,
host_start_epoch: i64,

accept_thread: ?std.Thread = null,
running: std.atomic.Value(bool) = .init(true),

/// TEST-ONLY: when set true BEFORE a peer connects, `setupConn` shrinks the
/// accepted conn's socket SEND buffer to a tiny size instead of raising it to
/// SOCKET_BUF. Combined with the test client setting a tiny SO_RCVBUF on its end,
/// this lets a render-drain thread GENUINELY block inside the blocking writeAll
/// after only a few KB (rather than absorbing CAP small frames into a ~1 MiB
/// kernel buffer). That makes the wedge tests actually exercise the BLOCKER fix
/// (renderOutTeardown's shutdown(.send)-before-join interrupting an in-flight
/// blocking write) and the bounded-drop overflow (the ring fills because the drain
/// thread is parked). Never set in production. Read once per accept on the accept
/// thread; writers (tests) set it before connecting, so no lock is needed.
test_tiny_sockbuf: bool = false,

/// A registered session plus its subscriber connections and buffered exit.
///
/// ## Lifecycle / ownership (fixes F1/F3/spawn-fail/owner-fail/notify-race)
///
/// The owning thread is the ONLY thread allowed to call `Session.destroy()`
/// (Phase-1 invariant: render loop + destroy share a thread, asserted in
/// `Session.destroy`). So teardown is split across two parties, coordinated by
/// the flags below (all under `mutex`) plus the `teardown` event:
///
///   - Natural child exit: `runRenderLoop` returns on its own. The owner thread
///     marks `child_dead = true` and then PARKS on `teardown` — it does NOT
///     destroy the Session. The SessionEntry stays valid and registered so a
///     reattach can still recover the viewport + deliver the buffered
///     `ChildExited` (plan §4.8: "a detached session with a live child lives
///     forever"; "child exit while detached buffers + reports on reattach").
///   - `start()` failure: the owner thread destroys the Session immediately
///     (it never entered the render loop, so destroy on this thread is legal),
///     sets `session_alive = false`, and parks on `teardown`. No path may
///     dereference `e.session` once `session_alive == false`.
///   - Explicit `Close` / `Server.deinit`: removes the entry from the registry
///     (under `registry_mutex`, so exactly one caller owns it), then signals
///     teardown: sets `teardown_requested`, posts `teardown`, and notifies
///     `render_stop` (to break a still-running render loop). The owner thread
///     wakes, destroys the Session if still alive, and exits. The closer joins
///     the owner thread and frees the entry — exactly once.
pub const SessionEntry = struct {
    server: *Server,
    session_id: u64,
    session: *Session,
    /// The dedicated owning thread (start -> runRenderLoop -> park -> destroy).
    thread: ?std.Thread = null,
    subscribers: std.ArrayList(*Conn) = .empty,
    /// H1 (Phase 2b): connections subscribed to this session's RAW pty output
    /// (the `subscribe_raw` / `raw_output` channel). Parallel to `subscribers`
    /// and guarded by the same `mutex`. A conn can be on either, both, or
    /// neither list. onRawOutput iterates this list (under `mutex`) to broadcast
    /// `raw_output` frames; teardownEntry clears it alongside `subscribers`.
    raw_subscribers: std.ArrayList(*Conn) = .empty,
    /// Layer 1 (Agent Dashboard): connections subscribed to this session's
    /// existing RENDER stream (grid_frame + mode_frame) via subscribe_render.
    /// Parallel to `subscribers`/`raw_subscribers` and guarded by the SAME
    /// `mutex`. A conn can be on any combination of the three lists. onRender
    /// iterates this list (under `mutex`) AFTER the `subscribers` loop to
    /// broadcast the SAME grid/mode frames; teardownEntry clears it alongside the
    /// other two. READ-ONLY by SUBSCRIPTION SEMANTICS, not host enforcement:
    /// being on this list grants no mutation authority and `subscribe_render`
    /// itself never reflows the session. It does NOT, however, revoke any ability
    /// a bare handshaked conn already has — the host has no per-conn owner model,
    /// so the `.resize`/`.input`/`.close` arms still act on any handshaked conn
    /// keyed by session_id (the pre-existing socket-trusted host model; the
    /// AF_UNIX socket perms + tailnet ACL are the trust boundary). The read-only
    /// guarantee is a CLIENT-SIDE convention (Layer 2's mirror never sends a
    /// resize), asserted in test as "subscribe + drive output does not reflow".
    render_subscribers: std.ArrayList(*Conn) = .empty,
    /// The child's exit, recorded the moment it fires (finding SR3-3). Once
    /// set, the child is permanently dead and this is REPLAYED on every
    /// (re)attach via deliverBufferedExit — it is NOT consumed-once. This
    /// covers both §4.8 cases uniformly: a child that exits while detached, AND
    /// a child that exits while a prior subscriber was attached (that subscriber
    /// gets it live in onChildExited, but a LATER reattach on a fresh conn must
    /// still learn the child is dead — the GUI otherwise cannot tell). The
    /// entry stays registered with a valid (not-destroyed) Session until an
    /// explicit Close, so this can be replayed indefinitely.
    buffered_child_exited: ?protocol.ChildExited = null,
    mutex: std.Thread.Mutex = .{},

    /// Set by the owner thread when the child exited on its own. The Session is
    /// still valid (NOT destroyed) so reattach can recover state.
    child_dead: bool = false,
    /// Idle-leak fix: monotonic-ms grace anchor for the session reaper. Stamped (via
    /// `e.server.monoNowMs()`) when the owner thread first marks the entry dead — both
    /// the child-exit arm and the start-fail arm — and RE-anchored to "now" whenever the
    /// AGGREGATE subscriber count drops to 0 on a child_dead entry (last-detach anchoring:
    /// the grace measures time-since-nobody-watching). null while the session is live.
    /// Written under `mutex`.
    dead_at_ms: ?i64 = null,
    /// Idle-leak fix: set true in the start-FAIL arm of sessionOwnerThread (alongside
    /// session_alive=false). Distinguishes a start-failed parked orphan (REAPABLE) from
    /// an entry that is mid-destroy (session_alive=false is also set there, but AFTER
    /// teardown + only on the already-removed entry). reapEligible uses it as a
    /// first-class branch so the start-fail orphan is reaped, not masked by !session_alive.
    /// Written under `mutex`.
    start_failed: bool = false,
    /// True until the owner thread has called `Session.destroy()`. Once false,
    /// `e.session` is a freed pointer and MUST NOT be dereferenced. Guarded by
    /// `mutex`.
    session_alive: bool = true,
    /// Set by the closer (Close/deinit) to ask the owner thread to tear down.
    teardown_requested: bool = false,
    /// Released by the closer to wake the parked owner thread.
    teardown: std.Thread.ResetEvent = .{},

    fn addSubscriber(self: *SessionEntry, conn: *Conn) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.subscribers.items) |c| if (c == conn) return;
        try self.subscribers.append(self.server.alloc, conn);
    }

    fn removeSubscriber(self: *SessionEntry, conn: *Conn) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var i: usize = 0;
        while (i < self.subscribers.items.len) {
            if (self.subscribers.items[i] == conn) {
                _ = self.subscribers.swapRemove(i);
            } else i += 1;
        }
    }

    /// H1 (Phase 2b): register `conn` as a RAW-output subscriber (idempotent).
    fn addRawSubscriber(self: *SessionEntry, conn: *Conn) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.raw_subscribers.items) |c| if (c == conn) return;
        try self.raw_subscribers.append(self.server.alloc, conn);
    }

    /// H1 (Phase 2b): drop `conn` from the RAW-output subscriber list. Mirrors
    /// removeSubscriber.
    fn removeRawSubscriber(self: *SessionEntry, conn: *Conn) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var i: usize = 0;
        while (i < self.raw_subscribers.items.len) {
            if (self.raw_subscribers.items[i] == conn) {
                _ = self.raw_subscribers.swapRemove(i);
            } else i += 1;
        }
    }

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

};

/// A single GUI connection.
pub const Conn = struct {
    server: *Server,
    fd: posix.socket_t,
    reader: protocol.FrameReader = .{},
    /// session_ids this conn is subscribed to (so disconnect can unsubscribe).
    subscribed: std.AutoHashMap(u64, void),
    /// H1 (Phase 2b): session_ids this conn is subscribed to for RAW output (so
    /// disconnect/teardown can unsubscribe). Parallel to `subscribed`.
    subscribed_raw: std.AutoHashMap(u64, void),
    /// Layer 1: session_ids this conn is subscribed to for the RENDER stream (so
    /// disconnect/teardown can unsubscribe). Parallel to `subscribed`/
    /// `subscribed_raw`.
    subscribed_render: std.AutoHashMap(u64, void),
    /// Serializes writes to this fd across the read thread (Pong/Attached/etc)
    /// and the various render threads (GridFrame/ModeFrame broadcast).
    write_mutex: std.Thread.Mutex = .{},
    /// Layer 2 prereq A: bounded outbound ring + drain thread for this conn's
    /// RENDER-subscriber frames. Lazily started on first render enqueue; torn
    /// down (fd .send shut, thread joined, bufs freed) in reapConn / the OOM
    /// inline free. Empty until this conn subscribes_render to something.
    render_out: RenderOut = .{},
    thread: ?std.Thread = null,
    closed: std.atomic.Value(bool) = .init(false),
    /// True once a compatible-major Hello has been accepted on this conn. Until
    /// then, dispatch rejects every frame other than Hello/Ping and closes the
    /// conn (finding PROTO-1): the major-version gate must run before any
    /// stateful frame, or an incompatible-major GUI that never sends Hello (or
    /// sends Attach first) would be served and then mis-decode GridFrame/
    /// ModeFrame against an incompatible wire schema. Only touched on the read
    /// thread (dispatch), so no lock needed.
    handshaked: bool = false,

    /// The peer's advertised protocol MINOR, captured in the `.hello` arm from
    /// `hello.protocol_version_minor` (0 until then). Gates additive host->GUI
    /// frames whose tag an older GUI's FrameType enum does not contain — notably
    /// `process_info` (minor 3): the host emits it ONLY to conns with
    /// `negotiated_minor >= 3` (see `processInfoAllowed`). This is the WHOLE
    /// forward-compat mechanism, because `FrameReader.next` rejects an unknown
    /// tag as `error.InvalidFrameType` and the GUI Client read loop treats that
    /// as fatal — so an old GUI must NEVER be sent the new tag.
    ///
    /// CROSS-THREAD (unlike `handshaked`, which IS read-thread-only): this field
    /// is WRITTEN on the read/dispatch thread (the `.hello` arm) but READ on the
    /// session-owning/render thread inside the broadcast paths (`onProcessInfo`,
    /// `pushFullFrames`) while iterating `e.subscribers`. It is still a plain u16
    /// with no per-field lock, and that is SAFE because of a happens-before edge,
    /// not single-thread access: a conn is PUBLISHED into `e.subscribers` only by
    /// `handleAttach`, which on a given conn runs strictly AFTER that conn's
    /// `.hello` arm (the `handshaked` gate enforces hello-before-attach on the
    /// same serial per-conn read thread), and the subscriber-list publish + every
    /// broadcast read both occur under `e.mutex`. That mutex provides the
    /// happens-before that makes the value reliably visible on the render thread.
    /// (A SECOND `.hello` on an already-attached conn would rewrite this on the
    /// read thread concurrently with a render-thread read under `e.mutex` —
    /// benign for an aligned u16, but technically a data race; a well-behaved GUI
    /// sends hello exactly once, matching the pre-existing re-settable
    /// `handshaked` pattern.)
    negotiated_minor: u16 = 0,

    /// Layer 1 (read-only gate, LOCK-FREE on the hot path): true when THIS conn
    /// is a RENDER subscriber of `session_id` but has NOT grid-attached to it —
    /// i.e. the exact wire profile of the web-monitor mirror, which only ever
    /// sends `hello` + `subscribe_render` and NEVER attaches. The session-
    /// MUTATING dispatch arms (resize/input/close/focus/scroll/jump/clear/reset/
    /// selection) drop the frame when this returns true, so a compromised or
    /// buggy mirror client (the surface exposed to a remote phone over a tailnet)
    /// can never reflow the real session grid, feed input, or close the session.
    ///
    /// CORRECTNESS / NO-LOCK rationale: this checks the conn-LOCAL maps
    /// `subscribed`/`subscribed_render`, which are mutated ONLY by this conn's
    /// single readLoop thread (subscribe/subscribeRender/detach all run in
    /// dispatch on that thread). The gate also runs in dispatch on that same
    /// thread, so the conn's own membership cannot change mid-dispatch and no
    /// lock is needed. Crucially this does NOT acquire `e.mutex`: the previously
    /// lock-free `.input`/`.resize`/`.focus`/… hot paths stay lock-free, so a
    /// wedged remote render subscriber blocking inside `onRender` (which holds
    /// `e.mutex` while writing to render subscribers) can NOT stall local-GUI
    /// keystroke/resize dispatch. (An earlier version scanned the SessionEntry
    /// subscriber lists under `e.mutex`, which coupled the input path to a slow
    /// remote mirror — removed; see the onRender liveness note.)
    ///
    /// Conservative by design: a conn that has ALSO grid-attached (in
    /// `subscribed`) is a real GUI and keeps full mutation rights — the gate
    /// only fires for the render-ONLY profile, so the attach/own model and the
    /// `.exec` path are byte-for-byte unchanged.
    fn isRenderOnlySubscriber(self: *Conn, session_id: u64) bool {
        if (!self.subscribed_render.contains(session_id)) return false;
        return !self.subscribed.contains(session_id);
    }

    /// Write a full framed message to this conn's fd, looping on short writes.
    fn writeFramed(self: *Conn, tag: protocol.FrameType, frame: anytype) void {
        const alloc = self.server.alloc;
        const bytes = protocol.encodeFrame(alloc, tag, frame) catch |err| {
            log.warn("encode frame failed tag={s} err={}", .{ @tagName(tag), err });
            return;
        };
        defer alloc.free(bytes);
        self.writeAll(bytes);
    }

    /// BLOCKING-WRITE CONTRACT (findings SR-4 / SF2): the fd is a blocking
    /// SOCK_STREAM, so this loop blocks if the peer's send buffer fills (a slow
    /// or stalled GUI). The five delivery paths (onRender / onChildExited /
    /// onSearchEvent / pushFullFrames / deliverBufferedExit) call writeFramed -> writeAll while
    /// holding `SessionEntry.mutex`, so a wedged subscriber head-of-line-blocks
    /// delivery to OTHER subscribers, stalls the session render thread, and
    /// delays teardownEntry (which needs e.mutex to clear subscribers before it
    /// joins the owner). The 1 MiB SO_SNDBUF widens but does not eliminate the
    /// window. Acceptable for Phase 2a (a single fast local GUI). A multi-
    /// subscriber Phase-2b expansion MUST NOT inherit this silently: either set
    /// the fds non-blocking and drop a would-block subscriber, or snapshot the
    /// subscriber Conn list under e.mutex and write OUTSIDE the lock (each Conn
    /// already has its own write_mutex for cross-thread safety).
    fn writeAll(self: *Conn, bytes: []const u8) void {
        if (self.closed.load(.acquire)) return;
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        var off: usize = 0;
        while (off < bytes.len) {
            const n = posix.write(self.fd, bytes[off..]) catch |err| {
                log.debug("write failed err={}", .{err});
                self.closed.store(true, .release);
                return;
            };
            if (n == 0) {
                self.closed.store(true, .release);
                return;
            }
            off += n;
        }
    }

    /// Layer 2 prereq A: enqueue a render frame for the drain thread. Encodes to
    /// owned bytes, pushes onto the bounded ring, and DROPS the oldest buffer on
    /// overflow (safe: grid/mode are absolute). Never blocks on the socket. The
    /// caller holds e.mutex (onRender) or registry_mutex (seed); this takes only
    /// the leaf render_out.mutex. Best-effort: an encode failure logs + drops the
    /// frame (the next tick re-sends full state).
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

    /// Layer 2 prereq A: ensure this conn's render drain thread is running
    /// (idempotent). Spawns on first render enqueue. The CALLER holds e.mutex
    /// (onRender) or registry_mutex (the seed); the thread-spawn under that lock
    /// is acceptable — Thread.spawn is brief and the new thread takes only its own
    /// leaf render_out.mutex, introducing no lock-order edge. We take the leaf
    /// mutex here to flip `started` so the differing caller locks don't race the
    /// guard.
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

    /// Layer 2 prereq A: stop + join the render drain thread and free the ring.
    /// MUST shut the fd's SEND half BEFORE join so a drain thread blocked in a
    /// blocking write to a wedged-but-connected peer is interrupted (EPIPE/
    /// ENOTCONN) and can observe `stop` — otherwise the reaper would hang
    /// (mirroring deinit's posix.shutdown-before-wait). Idempotent and safe when
    /// no thread was ever started.
    fn renderOutTeardown(self: *Conn) void {
        {
            self.render_out.mutex.lock();
            self.render_out.stop = true;
            self.render_out.cond.signal();
            self.render_out.mutex.unlock();
        }
        // Interrupt any in-flight blocking write to a wedged peer BEFORE join.
        // .send is sufficient (we only block on writes); harmless if already shut.
        // Reading `thread` here without the ring mutex is safe ONLY because every
        // producer (renderOutEnsure, the sole writer of `thread`) is quiesced by the
        // time teardown runs: unsubscribeAll has removed this conn from every
        // e.render_subscribers and the read thread is joined, so no onRender/seed can
        // be concurrently in renderOutEnsure. Do not call teardown while producers
        // may still enqueue.
        if (self.render_out.thread != null) {
            posix.shutdown(self.fd, .send) catch {};
        }
        if (self.render_out.thread) |t| {
            t.join();
            self.render_out.thread = null;
        }
        // Diagnostics for a wedged remote mirror: a non-zero drop count means a
        // render subscriber could not keep up and stale grid/mode snapshots were
        // coalesced away (safe — they are absolute full-state). Logged once at
        // teardown so the field is not dead telemetry.
        if (self.render_out.dropped > 0) {
            log.debug("render drain teardown: dropped {d} stale render frame(s) for a slow subscriber", .{self.render_out.dropped});
        }
        for (self.render_out.bufs.items) |b| self.server.alloc.free(b);
        self.render_out.bufs.deinit(self.server.alloc);
        self.render_out.bufs = .empty;
    }

    /// TEST-ONLY mirror of the render-out ring bound, so a test can assert
    /// `renderOutLenForTest() <= RENDER_OUT_CAP_FOR_TEST` without reaching into the
    /// file-private RenderOut struct.
    pub const RENDER_OUT_CAP_FOR_TEST: usize = RenderOut.CAP;

    /// TEST-ONLY: number of render frames dropped on ring overflow for this conn,
    /// read under the leaf mutex. Lets a test assert the bounded-drop path fired
    /// (a regression making the ring unbounded would never drop -> this stays 0).
    pub fn renderOutDroppedForTest(self: *Conn) u64 {
        self.render_out.mutex.lock();
        defer self.render_out.mutex.unlock();
        return self.render_out.dropped;
    }

    /// TEST-ONLY: current depth of the render outbound ring, read under the leaf
    /// mutex. A test can assert this never exceeds RenderOut.CAP (the bound).
    pub fn renderOutLenForTest(self: *Conn) usize {
        self.render_out.mutex.lock();
        defer self.render_out.mutex.unlock();
        return self.render_out.bufs.items.len;
    }

    /// TEST-ONLY: pause/resume this conn's render drain thread. Paused, the drain
    /// thread parks WITHOUT consuming the ring, so a test can deterministically fill
    /// it past CAP (forcing drop-oldest in renderOutPush) and assert
    /// renderOutLenForTest()==CAP / renderOutDroppedForTest()>0 with NO dependence on
    /// socket backpressure. Resuming signals the cond so the drain resumes and the
    /// ring drains to the (now-readable) peer. Production never calls this; with
    /// drain_paused false the drain loop predicate is byte-for-byte the original.
    pub fn setDrainPausedForTest(self: *Conn, paused: bool) void {
        self.render_out.mutex.lock();
        defer self.render_out.mutex.unlock();
        self.render_out.drain_paused.store(paused, .release);
        // Wake the drain thread so it re-evaluates the gate (resume, or re-park).
        self.render_out.cond.signal();
    }
};

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
    /// TEST-ONLY drain gate. When true, renderDrainLoop parks instead of
    /// popping/writing, so a test can DETERMINISTICALLY overflow the ring (push
    /// CAP+N frames with no consumer) without depending on real socket
    /// backpressure / sleeps. Defaults false in production: when false the drain
    /// loop's predicate is byte-for-byte the original, so there is ZERO production
    /// behavior change. Settable ONLY from tests (Conn.setDrainPausedForTest).
    /// Atomic so the test thread may flip it while the drain thread reads it.
    drain_paused: std.atomic.Value(bool) = .init(false),
};

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
            // TEST-ONLY pause gate: when paused, do NOT pop/write; park on cond
            // until unpaused, stopped, or a fresh signal. `stop` ALWAYS wins (so
            // teardown can join even while paused — preserves the BLOCKER-fix
            // discipline: renderOutTeardown sets stop+signals before join). In
            // PRODUCTION drain_paused is always false, so this reduces to the
            // original `bufs.len == 0 and !stop` wait — ZERO production change.
            while ((conn.render_out.bufs.items.len == 0 or conn.render_out.drain_paused.load(.acquire)) and
                !conn.render_out.stop)
            {
                conn.render_out.cond.wait(&conn.render_out.mutex);
            }
            if (!conn.render_out.stop and conn.render_out.drain_paused.load(.acquire)) {
                // Woken but still paused (a push signaled while paused): re-park.
                // PROVABLY DEAD in production: drain_paused is always false there, so
                // exiting the while above with stop==false implies !paused, making this
                // guard false. Reachable ONLY in the test-paused case (a push signals
                // the cond while paused) — correct, harmless re-park. `!stop` keeps the
                // stop-wins discipline so teardown is never wedged.
                continue;
            }
            // On stop (or unpaused with work): flush-then-exit (the original
            // flush-on-stop semantics): pop while non-empty, else return. Teardown
            // frees any remainder regardless, so a paused-at-stop ring leaks nothing.
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
            // else loop back: the next iteration blocks benignly on `cond` until
            // renderOutTeardown sets `stop` and signals. This is NOT a busy-loop —
            // the ring is now empty and no producer can re-enqueue (the conn is
            // off every e.render_subscribers post-unsubscribeAll), so cond.wait
            // parks until teardown wakes it exactly once.
        }
    }
}

/// Build a sockaddr.un from a path, validating length.
fn makeAddr(path: []const u8) !posix.sockaddr.un {
    var addr: posix.sockaddr.un = undefined;
    addr.family = posix.AF.UNIX;
    if (path.len >= addr.path.len) return error.PathTooLong;
    @memcpy(addr.path[0..path.len], path);
    addr.path[path.len] = 0;
    return addr;
}

/// Create + bind + listen the server socket at `path`. Caller owns the
/// returned *Server (call deinit).
pub fn init(alloc: Allocator, path: []const u8) !*Server {
    const self = try alloc.create(Server);
    errdefer alloc.destroy(self);

    const path_dup = try alloc.dupe(u8, path);
    errdefer alloc.free(path_dup);

    const fd = try posix.socket(
        posix.AF.UNIX,
        posix.SOCK.STREAM,
        0,
    );
    errdefer posix.close(fd);

    // Remove any stale path.
    posix.unlink(path) catch {};

    const addr = try makeAddr(path);
    try posix.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));
    try posix.listen(fd, 16);

    self.* = .{
        .alloc = alloc,
        .listen_fd = fd,
        .path = path_dup,
        .sessions = std.AutoHashMap(u64, *SessionEntry).init(alloc),
        .host_pid = std.c.getpid(),
        .host_start_epoch = std.time.timestamp(),
        // Idle-leak fix: monotonic epoch for the reaper grace window (NOT wall-clock).
        .mono_epoch = std.time.Instant.now() catch unreachable,
    };

    return self;
}

/// Spawn the accept + conn-reaper + session-reaper threads. Returns immediately.
pub fn start(self: *Server) !void {
    self.reaper_thread = try std.Thread.spawn(.{}, reaperLoop, .{self});
    // Idle-leak fix: the periodic dead-session reaper.
    self.session_reaper_thread = try std.Thread.spawn(.{}, sessionReaperLoop, .{self});
    self.accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
}

/// TEST-ONLY: return the first render subscriber Conn of `session_id`, or null.
/// The caller can read its render-out drop counter / ring depth to assert the
/// bounded-drop path. Taken under registry_mutex -> e.mutex (canonical order).
pub fn firstRenderSubscriberForTest(self: *Server, session_id: u64) ?*Conn {
    self.registry_mutex.lock();
    defer self.registry_mutex.unlock();
    const e = self.sessions.get(session_id) orelse return null;
    e.mutex.lock();
    defer e.mutex.unlock();
    if (e.render_subscribers.items.len == 0) return null;
    return e.render_subscribers.items[0];
}

/// The first regular (grid) subscriber of `session_id`, or null. Lets a test
/// inspect the negotiated minor captured from that conn's Hello (used to verify
/// the process_info compat gate). Mirrors firstRenderSubscriberForTest.
pub fn firstSubscriberForTest(self: *Server, session_id: u64) ?*Conn {
    self.registry_mutex.lock();
    defer self.registry_mutex.unlock();
    const e = self.sessions.get(session_id) orelse return null;
    e.mutex.lock();
    defer e.mutex.unlock();
    if (e.subscribers.items.len == 0) return null;
    return e.subscribers.items[0];
}

/// Reaps disconnected connections: joins their (already-exited) read thread,
/// closes the fd, frees the Conn. The SOLE owner of conn joins + frees. Woken
/// by `reaper_signal`. Exits only once deinit has cleared `reaper_running` AND
/// both `conns` (all read threads migrated off) and `dead_conns` (all reaped)
/// are empty — so at exit there is provably nothing left to free.
fn reaperLoop(self: *Server) void {
    while (true) {
        self.reaper_signal.wait();
        // Drain everything currently dead.
        while (true) {
            var conn: ?*Conn = null;
            {
                self.conns_mutex.lock();
                defer self.conns_mutex.unlock();
                if (self.dead_conns.items.len > 0) conn = self.dead_conns.pop();
            }
            const c = conn orelse break;
            self.reapConn(c);
        }
        if (!self.reaper_running.load(.acquire)) {
            self.conns_mutex.lock();
            const live = self.conns.items.len;
            const dead = self.dead_conns.items.len;
            self.conns_mutex.unlock();
            // deinit shut every conn fd, so each read thread exits and removes
            // itself from `conns` (self-migrating to `dead_conns`, or — only on
            // OOM — freeing itself inline). Both lists share conns_mutex, so a
            // conn is never in-flight between them when we observe both empty.
            if (live == 0 and dead == 0) return;
        }
    }
}

/// Join a dead conn's read thread, close its fd, and free it. The conn must
/// already be unsubscribed from every session (readLoop does this before
/// enqueueing it) so no render tick can reference it.
fn reapConn(self: *Server, conn: *Conn) void {
    if (conn.thread) |t| t.join();
    conn.renderOutTeardown(); // Layer 2 prereq A: stop+join drain (shuts .send first)
    posix.close(conn.fd);
    conn.subscribed.deinit();
    conn.subscribed_raw.deinit();
    conn.subscribed_render.deinit();
    conn.reader.deinit(self.alloc);
    self.alloc.destroy(conn);
}

/// Idle-leak fix: the grace window a dead (child-exited / start-failed), zero-subscriber
/// session lingers before the reaper reclaims it. 1 hour: generous enough that a restart
/// hiccup or stepping away and back does not lose the dead session's final viewport +
/// exit status (a within-grace reattach still recovers both), yet bounded far below the
/// multi-day thread/fd accumulation this fixes. Last-detach anchored (see the re-anchor
/// in handleDetach/unsubscribeAll), so the window measures time-since-nobody-watching.
const dead_session_grace_ms: i64 = 3_600_000;

/// Idle-leak fix: monotonic milliseconds since `mono_epoch`. NOT wall-clock
/// (std.time.milliTimestamp can jump under NTP and skew the grace window). Lock-free, so
/// it is safe to call inside an `e.mutex` critical section (no new lock/order).
pub fn monoNowMs(self: *Server) i64 {
    const now = std.time.Instant.now() catch unreachable;
    return @intCast(now.since(self.mono_epoch) / std.time.ns_per_ms);
}

/// Idle-leak fix: PURE eligibility predicate for the session reaper (decoupled from
/// thread timing so it is unit-testable as a truth table). An entry is reapable iff it is
/// a parked DEAD orphan — a normally child-dead session (`session_alive && child_dead`,
/// parked at sessionOwnerThread's child-exit park) OR a start-FAILED one
/// (`!session_alive && start_failed`, parked at the start-fail park) — AND has ZERO
/// subscribers (no GUI is viewing its final screen) AND its grace window has elapsed. A
/// genuinely-destroying entry (`!session_alive && !start_failed`) and a LIVE detached
/// child (`!child_dead`) are NEVER eligible.
pub fn reapEligible(
    child_dead: bool,
    session_alive: bool,
    start_failed: bool,
    teardown_requested: bool,
    subscriber_count: usize,
    dead_at_ms: ?i64,
    now_ms: i64,
    grace_ms: i64,
) bool {
    // Defensive/belt-and-suspenders: teardown_requested is set ONLY inside teardownEntry,
    // which runs only AFTER the entry was fetchRemove'd from the registry — so a reaper
    // scan (which iterates the registry) can never observe it true. The genuine
    // anti-double-free is the single-owner fetchRemove gate (a racing Close wins the
    // remove and the reaper then finds nothing).
    if (teardown_requested) return false;
    const reapable_state =
        (session_alive and child_dead) or
        (!session_alive and start_failed);
    if (!reapable_state) return false;
    // A GUI viewing the final screen (any of the three subscriber lists) keeps it.
    if (subscriber_count != 0) return false;
    const dead_at = dead_at_ms orelse return false;
    return (now_ms - dead_at) >= grace_ms;
}

/// Idle-leak fix: the periodic dead-session reaper loop. Wakes on a ~5 s timed wait (or
/// immediately when deinit sets the ONE-SHOT shutdown event) and reaps eligible entries.
/// The event is set ONLY by deinit, so a successful wait => shutdown; a timeout
/// (error.Timeout, swallowed) => time to scan. No `.reset()` is ever called.
fn sessionReaperLoop(self: *Server) void {
    while (true) {
        self.session_reaper_event.timedWait(5 * std.time.ns_per_s) catch {};
        if (!self.session_reaper_running.load(.acquire)) break;
        self.reapSessionsOnce(self.monoNowMs(), dead_session_grace_ms);
    }
}

/// Idle-leak fix: one reaper scan. Collect-then-act (mirrors handleClose's discipline):
/// under registry_mutex, scan the registry and `fetchRemove` every eligible entry into a
/// local list (the subscriber-count read + eligibility decision + removal all happen in
/// the SAME registry_mutex region, so a racing handleAttach — which serializes on
/// registry_mutex — cannot subscribe to an entry being removed). RELEASE registry_mutex,
/// THEN teardownEntry each removed entry (teardownEntry must NEVER be called under
/// registry_mutex — it would risk a lock-order deadlock). The fetchRemove is the
/// single-owner gate: a racing explicit Close / deinit can never also grab the same entry.
/// `now_ms` / `grace_ms` are parameters so a test can drive a scan deterministically with
/// a tiny grace.
pub fn reapSessionsOnce(self: *Server, now_ms: i64, grace_ms: i64) void {
    var to_reap: std.ArrayList(*SessionEntry) = .empty;
    defer to_reap.deinit(self.alloc);
    {
        self.registry_mutex.lock();
        defer self.registry_mutex.unlock();
        var it = self.sessions.iterator();
        while (it.next()) |kv| {
            const e = kv.value_ptr.*;
            const eligible = blk: {
                e.mutex.lock();
                defer e.mutex.unlock();
                const subs = e.subscribers.items.len +
                    e.raw_subscribers.items.len +
                    e.render_subscribers.items.len;
                break :blk reapEligible(
                    e.child_dead,
                    e.session_alive,
                    e.start_failed,
                    e.teardown_requested,
                    subs,
                    e.dead_at_ms,
                    now_ms,
                    grace_ms,
                );
            };
            // OOM building the reap list: skip this entry this scan (it stays registered,
            // retried next scan) — NEVER remove-without-teardown (that would leak it).
            if (eligible) to_reap.append(self.alloc, e) catch continue;
        }
        // Remove the collected entries from the registry NOW (still under registry_mutex)
        // so a racing handleAttach/handleClose sees them gone before we release the lock.
        for (to_reap.items) |e| _ = self.sessions.remove(e.session_id);
    }
    // Tear down OUTSIDE registry_mutex (teardownEntry wakes + joins the owner thread,
    // which runs Session.destroy() on its OWN thread — Phase-1 invariant preserved).
    for (to_reap.items) |e| self.teardownEntry(e);
}

fn acceptLoop(self: *Server) void {
    while (self.running.load(.acquire)) {
        const fd = posix.accept(self.listen_fd, null, null, 0) catch |err| {
            // When deinit closes listen_fd, accept fails; that's the exit path.
            if (!self.running.load(.acquire)) return;
            // A transient accept() error (EINTR/EMFILE/ECONNABORTED) must NOT
            // permanently kill the accept thread on a long-lived host (it would
            // silently deny ALL future GUI connections). Log and keep looping.
            // Finding F6.
            log.warn("accept failed err={}; continuing", .{err});
            continue;
        };
        self.setupConn(fd) catch |err| {
            log.warn("setup conn failed err={}", .{err});
            posix.close(fd);
        };
    }
}

/// Best-effort SO_SNDBUF/RCVBUF raise via the raw syscall. We deliberately do
/// NOT use `posix.setsockopt`: its error set treats EINVAL as `unreachable`,
/// and EINVAL/ENOTSOCK can legitimately occur if the freshly-accepted peer has
/// already closed (a connect-then-instant-close client) — that would panic the
/// host. The buffer size is a hint, so ignore every failure.
fn setSockBuf(fd: posix.socket_t, opt: u32) void {
    setSockBufTo(fd, opt, SOCKET_BUF);
}

/// As setSockBuf but with an explicit size (used by the test-only tiny-buffer
/// path to genuinely wedge a drain thread's blocking write).
fn setSockBufTo(fd: posix.socket_t, opt: u32, size: c_int) void {
    _ = std.posix.system.setsockopt(
        fd,
        posix.SOL.SOCKET,
        opt,
        std.mem.asBytes(&size),
        @sizeOf(c_int),
    );
}

fn setupConn(self: *Server, fd: posix.socket_t) !void {
    // Raise socket buffers (best-effort; never fatal — see setSockBuf).
    //
    // NOTE: `test_tiny_sockbuf` does NOT shrink here. Shrinking at accept time
    // would also shrink the PRIMARY GUI conn's SEND buffer, and onRender's
    // retained-by-design blocking write to a primary subscriber (the SR-4
    // single-fast-local-peer contract, deliberately unchanged by prereq A) runs
    // WHILE HOLDING e.mutex. A test whose primary reader falls behind would then
    // wedge that write with e.mutex held, and a subsequent
    // firstRenderSubscriberForTest (registry_mutex -> e.mutex) would deadlock the
    // test thread — the wedge tests could themselves hang teardown. The shrink is
    // therefore applied ONLY to a conn once it becomes a RENDER subscriber, in
    // subscribeRender (so the primary keeps its full SOCKET_BUF and never
    // backpressures onRender). See subscribeRender.
    setSockBuf(fd, posix.SO.SNDBUF);
    setSockBuf(fd, posix.SO.RCVBUF);

    const conn = try self.alloc.create(Conn);
    errdefer self.alloc.destroy(conn);
    conn.* = .{
        .server = self,
        .fd = fd,
        .subscribed = std.AutoHashMap(u64, void).init(self.alloc),
        .subscribed_raw = std.AutoHashMap(u64, void).init(self.alloc),
        .subscribed_render = std.AutoHashMap(u64, void).init(self.alloc),
    };

    {
        self.conns_mutex.lock();
        defer self.conns_mutex.unlock();
        try self.conns.append(self.alloc, conn);
    }

    conn.thread = try std.Thread.spawn(.{}, readLoop, .{conn});
}

fn readLoop(conn: *Conn) void {
    const self = conn.server;
    var buf: [16 * 1024]u8 = undefined;
    while (self.running.load(.acquire) and !conn.closed.load(.acquire)) {
        const n = posix.read(conn.fd, &buf) catch |err| {
            log.debug("read failed err={}", .{err});
            break;
        };
        if (n == 0) break; // EOF
        conn.reader.push(self.alloc, buf[0..n]) catch |err| {
            log.warn("reader push failed err={}", .{err});
            break;
        };
        while (true) {
            const frame = conn.reader.next(self.alloc) catch |err| {
                log.warn("frame decode failed err={}", .{err});
                conn.closed.store(true, .release);
                break;
            } orelse break;
            self.dispatch(conn, frame) catch |err| {
                log.warn("dispatch failed err={}", .{err});
            };
            // A frame may have closed the conn (e.g. a refused-version Hello).
            // Stop draining the rest of this read batch so a refused client
            // cannot drive any further protocol action (e.g. a piggy-backed
            // Attach spawning a session). Finding P5.
            if (conn.closed.load(.acquire)) break;
        }
    }
    conn.closed.store(true, .release);
    // Unsubscribe this conn from all sessions BEFORE enqueueing it for reaping,
    // so no session render tick can still reference it once the reaper frees it.
    self.unsubscribeAll(conn);

    // Hand ourselves to the reaper: a read thread can't join itself. Atomically
    // move from the live `conns` list to the `dead_conns` queue (both under
    // conns_mutex, so the reaper never sees us on neither list), then wake the
    // reaper. The reaper is the single owner of conn joins + frees on EVERY
    // exit (normal disconnect AND shutdown), so there is no conns/dead_conns
    // ownership race in deinit (findings P4 / F5). On OOM (can't append to
    // dead_conns) we stay on `conns`; the reaper still frees us at shutdown
    // (it loops until conns is empty), so nothing leaks.
    var oom = false;
    {
        self.conns_mutex.lock();
        defer self.conns_mutex.unlock();
        // Remove from `conns` first; then either enqueue for the reaper or, on
        // OOM, free inline (the reaper must never see a conn left on `conns`
        // forever, or its shutdown emptiness check would spin).
        var i: usize = 0;
        while (i < self.conns.items.len) : (i += 1) {
            if (self.conns.items[i] == conn) {
                _ = self.conns.swapRemove(i);
                break;
            }
        }
        self.dead_conns.append(self.alloc, conn) catch {
            oom = true;
        };
    }
    if (oom) {
        // OOM fallback: free our own Conn inline (we are its sole owner now
        // that it's off `conns`). We can't join our own thread handle, so it
        // leaks — acceptable on an OOM-dying process.
        // Layer 2 prereq A: stop+join drain BEFORE closing the fd, mirroring
        // reapConn. renderOutTeardown does posix.shutdown(self.fd, .send) on the
        // LIVE fd, which (unlike close()) reliably interrupts a drain thread
        // parked in a blocking write to a wedged peer — on POSIX/Darwin close()
        // does NOT reliably wake another thread blocked in write() on the same
        // fd, so closing first would leave the shutdown a no-op on a stale fd and
        // the t.join() could hang. Shut-before-close keeps the OOM path's join
        // bounded too. Closing afterward is then a plain release of the fd.
        conn.renderOutTeardown();
        posix.close(conn.fd);
        conn.subscribed.deinit();
        conn.subscribed_raw.deinit();
        conn.subscribed_render.deinit();
        conn.reader.deinit(self.alloc);
        self.alloc.destroy(conn);
        return;
    }
    self.reaper_signal.post();
}

fn unsubscribeAll(self: *Server, conn: *Conn) void {
    var it = conn.subscribed.keyIterator();
    while (it.next()) |sid| {
        // Hold registry_mutex ACROSS the e.removeSubscriber dereference
        // (findings SR-R2-1 / ZM-R2-1), matching the .detach handler. Dropping
        // the lock before the deref would let a concurrent handleClose
        // fetchRemove + teardownEntry(e) (which calls alloc.destroy(e)) free the
        // entry between the get() and the deref — a use-after-free of the
        // SessionEntry and its embedded mutex. removeSubscriber only briefly
        // takes e.mutex with no blocking I/O, so doing it under registry_mutex
        // preserves the canonical registry_mutex -> e.mutex lock order and adds
        // no deadlock risk (teardownEntry never takes registry_mutex).
        self.registry_mutex.lock();
        defer self.registry_mutex.unlock();
        if (self.sessions.get(sid.*)) |e| e.removeSubscriber(conn);
    }
    // H1 (Phase 2b): also drop any RAW-output subscriptions, under the same
    // registry_mutex discipline (so a concurrent handleClose can't free the
    // entry between the get() and the deref). A conn can hold RAW subscriptions
    // for sessions it never grid-subscribed to, so iterate this set separately.
    var rit = conn.subscribed_raw.keyIterator();
    while (rit.next()) |sid| {
        self.registry_mutex.lock();
        defer self.registry_mutex.unlock();
        if (self.sessions.get(sid.*)) |e| e.removeRawSubscriber(conn);
    }
    // Layer 1: also drop any RENDER subscriptions, under the same registry_mutex
    // discipline. A conn can hold render subscriptions for sessions it never
    // grid-subscribed to, so iterate this set separately.
    var rndit = conn.subscribed_render.keyIterator();
    while (rndit.next()) |sid| {
        self.registry_mutex.lock();
        defer self.registry_mutex.unlock();
        if (self.sessions.get(sid.*)) |e| e.removeRenderSubscriber(conn);
    }
    // Idle-leak fix: FOURTH region — last-detach grace re-anchor. Now that this conn is
    // off ALL THREE subscriber lists above, re-anchor any child_dead entry whose AGGREGATE
    // subscriber count just dropped to 0 (the grace measures time-since-nobody-watching).
    // The three removal loops above run in SEPARATE registry_mutex regions, so the aggregate
    // is only 0 after the third — hence this fourth pass. Iterate the UNION of the three
    // subscribed-id sets (a conn may hold a raw/render sub for a session it never
    // grid-subscribed); a duplicate id across sets is harmless (the stamp is idempotent).
    var ait = conn.subscribed.keyIterator();
    while (ait.next()) |sid| self.reanchorIfLastDetach(sid.*);
    var arit = conn.subscribed_raw.keyIterator();
    while (arit.next()) |sid| self.reanchorIfLastDetach(sid.*);
    var arndit = conn.subscribed_render.keyIterator();
    while (arndit.next()) |sid| self.reanchorIfLastDetach(sid.*);
}

/// Idle-leak fix: if `sid` is a child_dead entry whose AGGREGATE subscriber count (all
/// three lists) is now 0, re-anchor its reaper grace window to "now" (last-detach
/// anchoring). NULL-GUARDED: registry_mutex is released between unsubscribeAll's removal
/// regions and this call, so a racing handleClose could have fetchRemove'd + freed the
/// entry in the gap — `get` returns null and we skip it (a missed re-anchor only shifts
/// the window, never a UAF; reapEligible re-reads the aggregate + fetchRemoves atomically
/// at reap time). Idempotent. Takes registry_mutex (canonical order) then e.mutex.
fn reanchorIfLastDetach(self: *Server, sid: u64) void {
    self.registry_mutex.lock();
    defer self.registry_mutex.unlock();
    const e = self.sessions.get(sid) orelse return;
    e.mutex.lock();
    defer e.mutex.unlock();
    if (e.child_dead and
        e.subscribers.items.len == 0 and
        e.raw_subscribers.items.len == 0 and
        e.render_subscribers.items.len == 0)
    {
        e.dead_at_ms = self.monoNowMs();
    }
}

/// Dispatch one decoded GUI->host frame.
///
/// MAILBOX NOTE (finding spsc-multi-producer): Input/Resize/Focus enqueue onto
/// the session's Termio mailbox, and dispatch runs on a per-connection read
/// thread — of which more than one can be subscribed to the same session_id.
/// The mailbox is nominally single-producer (initSPSC), so the host uses it
/// intentionally as MULTI-producer and depends on BlockingQueue.push being
/// mutex-guarded (`src/datastruct/blocking_queue.zig`). If that type ever drops
/// its internal lock for a true lockless SPSC optimization, these enqueues must
/// be funneled through a single per-session serialization point instead.
fn dispatch(self: *Server, conn: *Conn, frame: protocol.Frame) !void {
    const alloc = self.alloc;

    // Handshake gate (finding PROTO-1): the major-version check lives in the
    // .hello case below, but it is only load-bearing if NO stateful frame is
    // processed before a compatible Hello is accepted. So reject (close) any
    // frame other than Hello/Ping until `conn.handshaked` is set. This makes
    // the §6 versioning discipline enforced rather than advisory: an
    // incompatible-major GUI that never sends Hello, or sends Attach first,
    // cannot spawn sessions / queue input / resize / tear down and then
    // mis-decode GridFrame against an incompatible schema. Ping is allowed
    // pre-handshake purely as a liveness probe (it touches no session state).
    if (!conn.handshaked and frame.tag != .hello and frame.tag != .ping) {
        log.warn("frame {s} before Hello handshake; closing conn", .{@tagName(frame.tag)});
        conn.closed.store(true, .release);
        return;
    }

    switch (frame.tag) {
        .hello => {
            var hello = try protocol.Hello.decode(alloc, frame.payload);
            defer hello.deinit(alloc);
            if (hello.protocol_version_major != protocol.PROTOCOL_VERSION_MAJOR) {
                log.warn("incompatible protocol major {d}; closing conn", .{
                    hello.protocol_version_major,
                });
                conn.closed.store(true, .release);
                return;
            }
            conn.handshaked = true;
            // Capture the peer's advertised minor so additive host->GUI frames
            // can be gated on it (e.g. process_info needs >= 3). Major already
            // matched above; the minor is purely a feature-negotiation hint.
            conn.negotiated_minor = hello.protocol_version_minor;
            conn.writeFramed(.hello_ack, protocol.HelloAck{
                .host_pid = self.host_pid,
                .host_start_epoch = self.host_start_epoch,
            });
        },

        .attach => {
            var attach = try protocol.Attach.decode(alloc, frame.payload);
            defer attach.deinit(alloc);
            // SLICE 11: carry the spawn-opts (cwd + initial_input) through to
            // the spawn path. Both are borrowed from the decoded frame (freed by
            // `attach.deinit` above); handleAttach/spawnSession use them
            // synchronously to seed Session.Options before this returns, and
            // Session.create dupes them into the session config's arena — no
            // lifetime extension needed past this call.
            try self.handleAttach(
                conn,
                attach.session_id,
                attach.working_directory,
                attach.initial_input,
            );
        },

        .input => {
            var input = try protocol.Input.decode(alloc, frame.payload);
            defer input.deinit(alloc);
            // Hold registry_mutex across the whole dereference so a concurrent
            // Close/deinit can't fetchRemove + free this entry mid-use (the
            // TOCTOU window, finding F3). Enqueueing into the Termio mailbox is
            // cheap + non-blocking, so this is a brief critical section.
            self.registry_mutex.lock();
            defer self.registry_mutex.unlock();
            if (self.sessions.get(input.session_id)) |e| {
                // Layer 1 read-only gate: a render-ONLY conn (the mirror) must
                // never feed input to the real session.
                if (conn.isRenderOnlySubscriber(input.session_id)) {
                    log.debug("dropping input from render-only conn session={d}", .{input.session_id});
                    return;
                }
                if (sessionLive(e)) {
                    // NOTE (finding SI-1, Phase-2b FOLLOWUP): input.linefeed is
                    // decoded but intentionally NOT applied here. The Termio
                    // write mailbox carries no per-write linefeed bit — the
                    // \r -> \r\n (bracketed-paste/CR) translation is governed
                    // by Termio.flags.linefeed_mode, set via a separate
                    // .linefeed_mode message — so sendInput's .write_small/
                    // .write_alloc path has no slot for it. Phase 2a defaults
                    // linefeed_mode=false and has no GUI producer that sets the
                    // bit; honoring it (emit a .linefeed_mode message when
                    // input.linefeed differs from the session's current mode,
                    // or add a per-write path) is deferred to Phase 2b.
                    e.session.sendInput(input.bytes) catch |err|
                        log.warn("sendInput failed err={}", .{err});
                }
            }
        },

        .resize => {
            var resize = try protocol.Resize.decode(alloc, frame.payload);
            defer resize.deinit(alloc);

            // Slice 12: DROP a degenerate resize. On reattach the GUI can
            // momentarily report a 0 / near-0 grid for a restored tab before
            // layout/font-metrics settle (tab-dependent, restore-timing). The
            // host must NEVER resize the terminal to a degenerate grid: applying
            // one reflows the screen down to ~1 row — DISCARDING scrollback —
            // and, with real history present, underflow-panics
            // PageList.resizeCols (`self.rows - cursor.y - 1`) during the
            // column reflow, aborting the IO thread.
            //
            // We gate on the RESOLVED grid (the (cols,rows) Termio.resize will
            // actually apply via `Resize.toSize().grid()`), not the raw wire
            // {cols, rows}. Gating on the wire value alone only caught a literal
            // {0,0} frame, but `size.grid()`'s `@max(1,…)` floor
            // (src/renderer/size.zig:260-261) maps {0,0} to a 1x1 collapse grid
            // and a wire {1,1} (or any other tiny transient) sails straight
            // through to the same panic. Resolving first closes that gap.
            //
            // The floor is the GUI's OWN minimum terminal size —
            // CoreSurface.min_window_{width,height}_cells (10x4, src/Surface.zig)
            // — which every apprt embedder enforces as the minimum window size.
            // A grid below that floor is, by the app's own definition, not a
            // legitimate terminal; it can only be a transient/garbled reattach
            // frame. Dropping it (vs clamping) is cleanest: the terminal is
            // never touched, so no reflow/discard, and the next well-formed
            // Resize carries the real restored size. Well-formed frames (>= the
            // floor) are unaffected and still apply the authoritative wire grid
            // below, so Slice 9 is not regressed. .exec untouched.
            const resolved = resize.toSize().grid();
            if (resolved.columns < CoreSurface.min_window_width_cells or
                resolved.rows < CoreSurface.min_window_height_cells)
            {
                log.debug(
                    "dropping degenerate resize session={d} wire={d}x{d} resolved={d}x{d} (floor {d}x{d})",
                    .{
                        resize.session_id,
                        resize.cols,
                        resize.rows,
                        resolved.columns,
                        resolved.rows,
                        CoreSurface.min_window_width_cells,
                        CoreSurface.min_window_height_cells,
                    },
                );
                return;
            }

            self.registry_mutex.lock();
            defer self.registry_mutex.unlock();
            if (self.sessions.get(resize.session_id)) |e| {
                // Layer 1 read-only gate (HARD INVARIANT: "a resize frame from
                // such a conn must not change session grid size"): drop a resize
                // from a render-ONLY conn so a compromised/buggy mirror can never
                // reflow (and discard scrollback of) the real session.
                if (conn.isRenderOnlySubscriber(resize.session_id)) {
                    log.debug("dropping resize from render-only conn session={d}", .{resize.session_id});
                    return;
                }
                if (sessionLive(e)) {
                    // Slice 9: reconstruct the size from the AUTHORITATIVE wire
                    // {cols, rows} (via Resize.toSize) rather than the raw
                    // screen_w/h. Termio.resize derives the grid via
                    // size.grid() = (screen - padding) / cell; toSize() sets
                    // screen = cols*cell + padding so that derivation reproduces
                    // the grid the GUI actually rendered at. For a well-formed
                    // frame this equals what the raw screen_w/h would derive
                    // (both come from one client-side renderer.Size); driving
                    // off {cols, rows} makes the host authoritative-grid driven,
                    // so an inconsistent/transient peer frame can't collapse the
                    // terminal to a re-derived (near-1x1) grid that would discard
                    // rows and erase scrollback. See toSize().
                    const size: renderer.Size = resize.toSize();
                    e.session.io.queueMessage(.{ .resize = size }, .unlocked);
                }
            }
        },

        .focus => {
            var focus = try protocol.Focus.decode(alloc, frame.payload);
            defer focus.deinit(alloc);
            self.registry_mutex.lock();
            defer self.registry_mutex.unlock();
            if (self.sessions.get(focus.session_id)) |e| {
                // Layer 1 read-only gate: a render-ONLY conn must not drive focus.
                if (conn.isRenderOnlySubscriber(focus.session_id)) {
                    log.debug("dropping focus from render-only conn session={d}", .{focus.session_id});
                    return;
                }
                if (sessionLive(e)) {
                    e.session.io.queueMessage(.{ .focused = focus.focused }, .unlocked);
                }
            }
        },

        .scroll_viewport => {
            var sv = try protocol.ScrollViewport.decode(alloc, frame.payload);
            defer sv.deinit(alloc);
            // Drop an unknown kind byte from a desynced/buggy peer rather than
            // panic on an invalid union tag.
            if (sv.toTarget()) |target| {
                // Hold registry_mutex across the dereference (finding F3
                // TOCTOU), mirroring the .input/.resize arms. queueMessage is
                // cheap + non-blocking.
                self.registry_mutex.lock();
                defer self.registry_mutex.unlock();
                if (self.sessions.get(sv.session_id)) |e| {
                    // Layer 1 read-only gate: a render-ONLY conn must not repin
                    // the real session's viewport.
                    if (conn.isRenderOnlySubscriber(sv.session_id)) {
                        log.debug("dropping scroll_viewport from render-only conn session={d}", .{sv.session_id});
                        return;
                    }
                    if (sessionLive(e)) e.session.scrollViewport(target);
                }
            } else {
                log.warn("ignoring scroll_viewport with unknown kind={}", .{sv.kind});
            }
        },

        .jump_to_prompt => {
            var jp = try protocol.JumpToPrompt.decode(alloc, frame.payload);
            defer jp.deinit(alloc);
            self.registry_mutex.lock();
            defer self.registry_mutex.unlock();
            if (self.sessions.get(jp.session_id)) |e| {
                // Layer 1 read-only gate: a render-ONLY conn must not repin.
                if (conn.isRenderOnlySubscriber(jp.session_id)) {
                    log.debug("dropping jump_to_prompt from render-only conn session={d}", .{jp.session_id});
                    return;
                }
                if (sessionLive(e)) e.session.jumpToPrompt(@intCast(jp.delta));
            }
        },

        .clear_screen => {
            var cs = try protocol.ClearScreen.decode(alloc, frame.payload);
            defer cs.deinit(alloc);
            // Same registry_mutex discipline as .scroll_viewport / .jump_to_prompt
            // (F3 TOCTOU): clearScreen only enqueues to the session's io thread.
            self.registry_mutex.lock();
            defer self.registry_mutex.unlock();
            if (self.sessions.get(cs.session_id)) |e| {
                // Layer 1 read-only gate: a render-ONLY conn must not clear the
                // real session's screen/scrollback.
                if (conn.isRenderOnlySubscriber(cs.session_id)) {
                    log.debug("dropping clear_screen from render-only conn session={d}", .{cs.session_id});
                    return;
                }
                if (sessionLive(e)) e.session.clearScreen(cs.history);
            }
        },

        .reset => {
            var rst = try protocol.Reset.decode(alloc, frame.payload);
            defer rst.deinit(alloc);
            // Same registry_mutex discipline: reset only enqueues to the io thread.
            self.registry_mutex.lock();
            defer self.registry_mutex.unlock();
            if (self.sessions.get(rst.session_id)) |e| {
                // Layer 1 read-only gate: a render-ONLY conn must not reset the
                // real session's terminal.
                if (conn.isRenderOnlySubscriber(rst.session_id)) {
                    log.debug("dropping reset from render-only conn session={d}", .{rst.session_id});
                    return;
                }
                if (sessionLive(e)) e.session.reset();
            }
        },

        .subscribe_raw => {
            var sub = try protocol.SubscribeRaw.decode(alloc, frame.payload);
            defer sub.deinit(alloc);
            try self.handleSubscribeRaw(conn, sub.session_id);
        },

        .subscribe_render => {
            var sub = try protocol.SubscribeRender.decode(alloc, frame.payload);
            defer sub.deinit(alloc);
            try self.handleSubscribeRender(conn, sub.session_id);
        },

        .detach => {
            var detach = try protocol.Detach.decode(alloc, frame.payload);
            defer detach.deinit(alloc);
            self.registry_mutex.lock();
            defer self.registry_mutex.unlock();
            if (self.sessions.get(detach.session_id)) |e| {
                e.removeSubscriber(conn);
                _ = conn.subscribed.remove(detach.session_id);
                // H1 (Phase 2b): also drop a RAW subscription for this session
                // (a detach ends both the grid and the raw streams for it).
                e.removeRawSubscriber(conn);
                _ = conn.subscribed_raw.remove(detach.session_id);
                // Layer 1: also drop a RENDER subscription for this session.
                e.removeRenderSubscriber(conn);
                _ = conn.subscribed_render.remove(detach.session_id);
                // Child stays alive (Session NOT stopped).
                // Idle-leak fix: last-detach anchoring — this single handler dropped the
                // conn from all three lists in ONE registry_mutex region, so if the
                // AGGREGATE is now 0 on a child_dead entry, re-anchor the grace window.
                // registry_mutex is already held; inline the e.mutex check (calling
                // reanchorIfLastDetach would re-lock registry_mutex — not recursive).
                e.mutex.lock();
                if (e.child_dead and
                    e.subscribers.items.len == 0 and
                    e.raw_subscribers.items.len == 0 and
                    e.render_subscribers.items.len == 0)
                {
                    e.dead_at_ms = self.monoNowMs();
                }
                e.mutex.unlock();
            }
        },

        .close => {
            var close = try protocol.Close.decode(alloc, frame.payload);
            defer close.deinit(alloc);
            try self.handleClose(conn, close.session_id);
        },

        .set_search => {
            var set = try protocol.SetSearch.decode(alloc, frame.payload);
            defer set.deinit(alloc);
            // `opts` is reserved (always 0 this slice); setSearch ignores it.
            // Log if a peer sends a non-zero value so a future/buggy option
            // doesn't pass unnoticed (finding SETSEARCH-OPTS-DROP-3).
            if (set.opts != 0) log.debug(
                "ignoring unsupported search opts={}",
                .{set.opts},
            );
            // Hold registry_mutex across the dereference (finding F3 TOCTOU),
            // mirroring the .input arm. setSearch is brief (lazy thread spawn +
            // a mailbox push); the search WORK runs async on the search thread.
            self.registry_mutex.lock();
            defer self.registry_mutex.unlock();
            if (self.sessions.get(set.session_id)) |e| {
                // Layer 1 read-only gate: a render-ONLY conn must not drive the
                // real session's search state.
                if (conn.isRenderOnlySubscriber(set.session_id)) {
                    log.debug("dropping set_search from render-only conn session={d}", .{set.session_id});
                    return;
                }
                if (sessionLive(e)) {
                    e.session.setSearch(set.query) catch |err|
                        log.warn("setSearch failed err={}", .{err});
                }
            }
        },

        .search_nav => {
            var nav = try protocol.SearchNav.decode(alloc, frame.payload);
            defer nav.deinit(alloc);
            self.registry_mutex.lock();
            defer self.registry_mutex.unlock();
            if (self.sessions.get(nav.session_id)) |e| {
                // Layer 1 read-only gate.
                if (conn.isRenderOnlySubscriber(nav.session_id)) {
                    log.debug("dropping search_nav from render-only conn session={d}", .{nav.session_id});
                    return;
                }
                if (sessionLive(e)) e.session.navSearch(nav.dir);
            }
        },

        .clear_search => {
            var clear = try protocol.ClearSearch.decode(alloc, frame.payload);
            defer clear.deinit(alloc);
            self.registry_mutex.lock();
            defer self.registry_mutex.unlock();
            if (self.sessions.get(clear.session_id)) |e| {
                // Layer 1 read-only gate.
                if (conn.isRenderOnlySubscriber(clear.session_id)) {
                    log.debug("dropping clear_search from render-only conn session={d}", .{clear.session_id});
                    return;
                }
                if (sessionLive(e)) e.session.clearSearch();
            }
        },

        .hover => {
            var hover = try protocol.Hover.decode(alloc, frame.payload);
            defer hover.deinit(alloc);
            try self.handleHover(conn, hover);
        },

        .selection_drag => {
            var drag = try protocol.SelectionDrag.decode(alloc, frame.payload);
            defer drag.deinit(alloc);
            // Hold registry_mutex across the dereference (finding F3 TOCTOU),
            // mirroring the .set_search/.hover arms. selectDrag takes the
            // session's render_mutex internally for the select() + selectionString,
            // a BOUNDED compute (one viewport map + one selection-string extract),
            // and only STAGES the selection_text into the session's pending fields.
            // It does NOT broadcast the selection_text frame here (findings SEL-1 /
            // SEL-LOCK-1): that BLOCKING per-subscriber write would head-of-line-
            // block every other session behind one slow GUI peer while this
            // app-global registry_mutex is held, on a hot path (a frame per mouse-
            // move). The owning thread's renderTick drains + broadcasts it off
            // registry_mutex, alongside the forced GridFrame.
            self.registry_mutex.lock();
            defer self.registry_mutex.unlock();
            if (self.sessions.get(drag.session_id)) |e| {
                // Layer 1 read-only gate.
                if (conn.isRenderOnlySubscriber(drag.session_id)) {
                    log.debug("dropping selection_drag from render-only conn session={d}", .{drag.session_id});
                    return;
                }
                if (sessionLive(e)) {
                    e.session.selectDrag(
                        .{ .x = drag.anchor_x, .y = drag.anchor_y },
                        .{ .x = drag.head_x, .y = drag.head_y },
                        drag.rectangle,
                    ) catch |err|
                        log.warn("selectDrag failed err={}", .{err});
                }
            }
        },

        .selection_clear => {
            var clear = try protocol.SelectionClear.decode(alloc, frame.payload);
            defer clear.deinit(alloc);
            // Same lock discipline as .selection_drag: selectClear only STAGES the
            // cleared selection_text under render_mutex; renderTick broadcasts it
            // off registry_mutex (findings SEL-1 / SEL-LOCK-1).
            self.registry_mutex.lock();
            defer self.registry_mutex.unlock();
            if (self.sessions.get(clear.session_id)) |e| {
                // Layer 1 read-only gate.
                if (conn.isRenderOnlySubscriber(clear.session_id)) {
                    log.debug("dropping selection_clear from render-only conn session={d}", .{clear.session_id});
                    return;
                }
                if (sessionLive(e)) {
                    e.session.selectClear() catch |err|
                        log.warn("selectClear failed err={}", .{err});
                }
            }
        },

        .selection_point => {
            var sp = try protocol.SelectionPoint.decode(alloc, frame.payload);
            defer sp.deinit(alloc);
            // Drop a desynced/garbage mode byte BEFORE locking or touching the
            // session, mirroring ScrollViewport.toTarget's null-on-garbage drop.
            // selectPoint also guards internally (belt-and-suspenders).
            if (sp.toMode() == null) {
                log.debug("dropping selection_point with unknown mode={d}", .{sp.mode});
                return;
            }
            // Same lock discipline as .selection_drag: selectPoint maps a viewport
            // pin + expands the selection (selectWord/selectLine/selectAll) and
            // STAGES the selection_text under render_mutex; renderTick broadcasts
            // it off registry_mutex (findings SEL-1 / SEL-LOCK-1).
            self.registry_mutex.lock();
            defer self.registry_mutex.unlock();
            if (self.sessions.get(sp.session_id)) |e| {
                // Layer 1 read-only gate.
                if (conn.isRenderOnlySubscriber(sp.session_id)) {
                    log.debug("dropping selection_point from render-only conn session={d}", .{sp.session_id});
                    return;
                }
                if (sessionLive(e)) {
                    e.session.selectPoint(sp.x, sp.y, sp.mode) catch |err|
                        log.warn("selectPoint failed err={}", .{err});
                }
            }
        },

        .ping => {
            conn.writeFramed(.pong, protocol.Pong{});
        },

        // Host->GUI frames; not expected from the GUI. Ignore.
        .hello_ack, .attached, .grid_frame, .mode_frame, .child_exited, .pong, .search_total, .search_selected, .link_frame, .surface_event, .selection_text, .at_prompt, .raw_output, .process_info, .foreground_pid => {
            log.debug("ignoring host->gui frame from client: {s}", .{@tagName(frame.tag)});
        },
    }
}

fn lookup(self: *Server, session_id: u64) ?*SessionEntry {
    self.registry_mutex.lock();
    defer self.registry_mutex.unlock();
    return self.sessions.get(session_id);
}

/// True if `e.session` is safe to dereference (the owner thread has not yet
/// destroyed it). Callers MUST already hold `registry_mutex` so the entry
/// itself can't be freed underneath them (finding F3 / owner-fail). The Session
/// stays valid after a natural child exit (`child_dead`), only becoming invalid
/// once teardown destroys it (`session_alive == false`).
fn sessionLive(e: *SessionEntry) bool {
    e.mutex.lock();
    defer e.mutex.unlock();
    return e.session_alive;
}

/// Test-only registry accessor (used by the socket integration test to read
/// the host-boundary canary `unexpected_renderer_count`).
pub fn lookupForTest(self: *Server, session_id: u64) ?*SessionEntry {
    return self.lookup(session_id);
}

/// Test-only: number of live (not-yet-reaped) connections. Used by the
/// reconnect-reaping test to assert disconnected conns drain to baseline.
pub fn connCountForTest(self: *Server) usize {
    self.conns_mutex.lock();
    defer self.conns_mutex.unlock();
    return self.conns.items.len + self.dead_conns.items.len;
}

fn handleAttach(
    self: *Server,
    conn: *Conn,
    session_id: ?u64,
    working_directory: ?[]const u8,
    initial_input: ?[]const u8,
) !void {
    // Reattach to a session whose Session is still valid (alive child OR a
    // child that exited but whose entry has not been Closed — plan §4.8).
    //
    // UAF FIX (findings SR-1 / ZM1): hold registry_mutex across the ENTIRE
    // entry dereference, exactly like the .input/.resize/.focus handlers. The
    // old code fetched the entry via lookup() (which unlocks before returning)
    // and then dereferenced e (sessionLive/subscribe/Attached/pushFullFrames/
    // deliverBufferedExit) with NO lock held — a concurrent handleClose/deinit
    // could fetchRemove + teardownEntry (join owner + free e + free e.session)
    // mid-use, a use-after-free of both the SessionEntry and its *Session.
    // Holding registry_mutex for the whole dereference means a concurrent
    // fetchRemove cannot run until we release, so e cannot be freed underneath
    // us. NOTE: pushFullFrames does blocking socket writes under this lock, so
    // all attaches (and any concurrent Close/deinit) serialize behind one slow
    // GUI — acceptable for Phase 2a (single local GUI); a Phase-2b follow-up is
    // a refcount/pin on SessionEntry so attaches don't serialize on socket I/O.
    // pushFullFrames ALSO does a bounded sysctl(KERN_PROCARGS2)+libproc proc_name
    // resolve for the process_info seed under this lock (only when a subscriber
    // negotiated minor >= 3); far cheaper than the blocking writes and only on
    // attach (rare), but it lengthens this already-serialized critical section —
    // same Phase-2b refcount follow-up applies.
    if (session_id) |sid| reattach: {
        self.registry_mutex.lock();
        defer self.registry_mutex.unlock();
        const e = self.sessions.get(sid) orelse break :reattach;
        if (!sessionLive(e)) break :reattach; // torn down; degrade to spawn.
        try self.subscribe(conn, e);
        // plan §5 step 3: the host replies Attached in BOTH the spawn and the
        // reattach cases, so the GUI can confirm the session_id and learn the
        // current cols/rows (finding P2). Send it before the full frames.
        // Source dims from the LIVE terminal, not opts (findings SR-2 / SF1):
        // opts is the immutable spawn-time geometry and is never updated on a
        // Resize, so reporting opts after a resize+reattach would send stale
        // dims contradicting the immediate GridFrame.
        const dims = liveDims(e.session);
        conn.writeFramed(.attached, protocol.Attached{
            .session_id = e.session_id,
            .cols = dims.cols,
            .rows = dims.rows,
        });
        try self.pushFullFrames(e);
        self.deliverBufferedExit(e);
        return;
    }
    // Unknown / GC'd / torn-down id: degrade to spawn-fresh (plan §5 step 2).
    //
    // Same UAF discipline on the spawn path: spawnSession registers the entry
    // and only THEN can a concurrent Close find it, so we hold registry_mutex
    // across spawn + the dereference. spawnSession() therefore must NOT lock
    // registry_mutex itself (it's already held here).
    self.registry_mutex.lock();
    defer self.registry_mutex.unlock();
    // SLICE 11: a FRESH spawn (or a degrade-to-spawn from an unknown/torn-down
    // id) honors the Attach's spawn-opts (cwd + initial_input); a LIVE reattach
    // above returned before reaching here, so it never applies them (the existing
    // session keeps its own state). `null` => host default ($HOME / no input),
    // today's behavior.
    const e = try self.spawnSession(working_directory, initial_input);
    // spawnSession registered `e` in the registry AND started its owner thread.
    // If any subsequent step fails (subscribe OOM, pushFullFrames), tear down
    // the just-spawned session (finding SR-R2-2): the conn was never subscribed
    // (or subscribe rolled itself back) and the GUI never learned the
    // session_id (Attached is sent only after subscribe succeeds), so nothing
    // would ever teardown this entry — its Session, pty/child, owner thread, and
    // SessionEntry would leak until process exit. Unlike the reattach path, the
    // spawn-fresh entry has no other owner. teardownEntry never takes
    // registry_mutex (it only locks e.mutex and joins the owner thread), so it
    // is safe to call with registry_mutex already held; mirror handleClose's
    // remove-then-teardown.
    errdefer {
        _ = self.sessions.remove(e.session_id);
        self.teardownEntry(e);
    }
    try self.subscribe(conn, e);
    const dims = liveDims(e.session);
    conn.writeFramed(.attached, protocol.Attached{
        .session_id = e.session_id,
        .cols = dims.cols,
        .rows = dims.rows,
    });
    try self.pushFullFrames(e);
    // A child that exited in the window between spawnSession() starting the
    // owner thread and this subscribe() would have buffered its ChildExited
    // (no subscribers yet); deliver it now so the spawn-attach path matches
    // the reattach path's deliver-on-attach guarantee (finding F3 spawn-vs-
    // attach). Not reachable in Phase 2a (default Options spawn a long-lived
    // shell) but keeps the contract symmetric for Phase 2b.
    self.deliverBufferedExit(e);
}

/// Read the LIVE grid dimensions from the session's terminal under
/// render_mutex (findings SR-2 / SF1). The terminal's cols/rows track Resize
/// (via Terminal.resize), unlike the immutable spawn-time `opts`.
const LiveDims = struct { cols: u16, rows: u16 };
fn liveDims(session: *Session) LiveDims {
    session.render_mutex.lock();
    defer session.render_mutex.unlock();
    return .{
        .cols = session.io.terminal.cols,
        .rows = session.io.terminal.rows,
    };
}

/// Register `conn` as a subscriber of `e`. Order matters for OOM safety
/// (finding ZM3): insert into `conn.subscribed` FIRST, then `e.subscribers`.
/// If the subscribed.put fails (OOM) we have not yet added conn to
/// e.subscribers, so no render tick / teardown can hold a pointer to a conn
/// that disconnect's unsubscribeAll won't clean up. (unsubscribeAll iterates
/// conn.subscribed; if a conn were in e.subscribers but missing from
/// conn.subscribed, it would never be removed and would dangle after reaping.)
fn subscribe(self: *Server, conn: *Conn, e: *SessionEntry) !void {
    try conn.subscribed.put(e.session_id, {});
    errdefer _ = conn.subscribed.remove(e.session_id);
    try e.addSubscriber(conn);
    _ = self;
}

/// H1 (Phase 2b): register `conn` as a RAW-output subscriber of `e`. Same
/// OOM-ordering as `subscribe` (insert into `conn.subscribed_raw` FIRST, then
/// `e.raw_subscribers`): if the second put fails, unsubscribeAll (which iterates
/// `conn.subscribed_raw`) still cleans up, and no broadcast holds a pointer to a
/// conn that disconnect won't remove.
fn subscribeRaw(self: *Server, conn: *Conn, e: *SessionEntry) !void {
    try conn.subscribed_raw.put(e.session_id, {});
    errdefer _ = conn.subscribed_raw.remove(e.session_id);
    try e.addRawSubscriber(conn);
    _ = self;
}

/// Layer 1: register `conn` as a RENDER-stream subscriber of `e`. Same
/// OOM-ordering as `subscribe`/`subscribeRaw` (insert into
/// `conn.subscribed_render` FIRST, then `e.render_subscribers`).
fn subscribeRender(self: *Server, conn: *Conn, e: *SessionEntry) !void {
    if (self.test_tiny_sockbuf) {
        // TEST-ONLY: shrink THIS render-sub's SEND buffer so a never-reading peer
        // backpressures the drain thread's blocking writeAll after only a few KB
        // (rather than absorbing CAP small frames into a ~1 MiB kernel buffer),
        // making the wedge/bounded-drop tests actually bite. Applied here (not in
        // setupConn) so ONLY render subscribers shrink — the primary GUI conn
        // keeps its full SOCKET_BUF, so onRender's blocking write to the primary
        // (held under e.mutex, SR-4) never wedges and a test's
        // firstRenderSubscriberForTest can't deadlock on e.mutex. SO_SNDMINBUF on
        // Darwin is small; the kernel clamps to its floor, still tiny vs.
        // SOCKET_BUF.
        setSockBufTo(conn.fd, posix.SO.SNDBUF, 2048);
    }
    try conn.subscribed_render.put(e.session_id, {});
    errdefer _ = conn.subscribed_render.remove(e.session_id);
    try e.addRenderSubscriber(conn);
}

/// H1 (Phase 2b): handle a `subscribe_raw` frame. Validate the session exists +
/// is live (else clean-ignore, mirroring the unknown-id handling in the other
/// dispatch arms), register the conn as a RAW subscriber, then IMMEDIATELY send
/// the recent-output ring-buffer replay as one `raw_output` frame so the peer's
/// xterm.js has scrollback context before the live stream begins. Live
/// `raw_output` frames follow as the session produces output (via onRawOutput).
///
/// Lock discipline mirrors handleAttach: hold registry_mutex across the whole
/// entry dereference (finding F3 TOCTOU) so a concurrent Close/deinit can't free
/// `e` mid-use. The ring snapshot is captured under the session's render_mutex
/// (rawRingSnapshot, a distinct lock) and the replay write happens while
/// registry_mutex is held — consistent with handleAttach's pushFullFrames write
/// under the same lock (the SR-4 single/local fast-peer contract).
fn handleSubscribeRaw(self: *Server, conn: *Conn, session_id: u64) !void {
    self.registry_mutex.lock();
    defer self.registry_mutex.unlock();
    const e = self.sessions.get(session_id) orelse return; // unknown id: ignore
    if (!sessionLive(e)) return; // torn down: ignore

    try self.subscribeRaw(conn, e);

    // Replay the recent raw-output ring so the peer renders scrollback context
    // immediately. An empty ring (a never-written session) sends an empty
    // raw_output, which the peer can treat as "subscribed, nothing buffered yet."
    const replay = e.session.rawRingSnapshot() catch |err| {
        log.warn("raw ring snapshot failed err={}", .{err});
        return;
    };
    defer self.alloc.free(replay);
    conn.writeFramed(.raw_output, protocol.RawOutput{
        .session_id = e.session_id,
        .bytes = replay,
    });
}

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
///
/// SEED-vs-LIVE ORDERING (inherited, accepted window — same as handleSubscribeRaw's
/// add-then-replay): subscribeRender appends the conn to e.render_subscribers
/// (releasing e.mutex) BEFORE pushFullFramesTo writes the seed. onRender runs on
/// the session owning thread under e.mutex independently and takes no
/// registry_mutex, so it can write a NEWER grid_frame/mode_frame to this conn
/// before the OLDER seed arrives. This is harmless: grid_frame/mode_frame are
/// ABSOLUTE full-state snapshots (not deltas), so the worst case is newer→older→
/// newer, self-healing on the next tick. If ever tightened, do it in BOTH tees
/// together.
fn handleSubscribeRender(self: *Server, conn: *Conn, session_id: u64) !void {
    self.registry_mutex.lock();
    defer self.registry_mutex.unlock();
    const e = self.sessions.get(session_id) orelse return; // unknown id: ignore
    if (!sessionLive(e)) return; // torn down: ignore
    try self.subscribeRender(conn, e);
    try self.pushFullFramesTo(conn, e);
}

/// Allocate a fresh, unique, non-zero, RANDOM session id. CALLER HOLDS
/// registry_mutex (reads the registry to reject the astronomically-unlikely live
/// collision). Random rather than sequential so a stale id from a dead host
/// instance effectively never matches a live one — an unknown id then always
/// degrades to a clean fresh spawn instead of a false reattach. 0 is skipped (the
/// "unattached" sentinel).
pub fn allocSessionId(self: *Server) u64 {
    while (true) {
        const id = std.crypto.random.int(u64);
        if (id == 0) continue;
        if (self.sessions.contains(id)) continue;
        return id;
    }
}

/// Spawn a fresh Session, register it, and start its dedicated owning thread.
/// CALLER MUST HOLD registry_mutex (findings SR-1 / ZM1): the only caller,
/// handleAttach, holds it across the whole spawn+dereference so a concurrent
/// Close cannot fetchRemove+free the entry mid-attach.
fn spawnSession(
    self: *Server,
    working_directory: ?[]const u8,
    initial_input: ?[]const u8,
) !*SessionEntry {
    const id = self.allocSessionId();

    // SLICE 11: seed the spawn-opts (cwd + initial_input) into Session.Options.
    // Session.create dupes them into the session config's arena, so the borrowed
    // slices (from the decoded Attach frame, still alive in handleClientFrame)
    // only need to outlive this call. `null` => the config's finalize defaults
    // stand ($HOME cwd / no initial input).
    const session = try Session.create(self.alloc, .{
        .working_directory = working_directory,
        .initial_input = initial_input,
    });
    errdefer session.destroy();

    const e = try self.alloc.create(SessionEntry);
    errdefer self.alloc.destroy(e);
    e.* = .{
        .server = self,
        .session_id = id,
        .session = session,
    };

    // Wire the render-tick push + child-exit hooks BEFORE start so the very
    // first tick can broadcast.
    session.on_render_ctx = e;
    session.on_render = onRender;
    session.on_child_exited_ctx = e;
    session.on_child_exited = onChildExited;
    session.on_search_event_ctx = e;
    session.on_search_event = onSearchEvent;
    session.on_surface_event_ctx = e;
    session.on_surface_event = onSurfaceEvent;
    session.on_selection_text_ctx = e;
    session.on_selection_text = onSelectionText;
    session.on_at_prompt_ctx = e;
    session.on_at_prompt = onAtPrompt;
    session.on_raw_output_ctx = e;
    session.on_raw_output = onRawOutput;
    session.on_process_info_ctx = e;
    session.on_process_info = onProcessInfo;

    // registry_mutex is held by the caller (handleAttach), so put/remove here
    // must NOT re-lock it (would deadlock).
    try self.sessions.put(id, e);
    // If anything below fails, the entry must come back OUT of the registry
    // before the errdefers above free `session`/`e` — otherwise the registry
    // would hold a dangling pointer that deinit/lookup later dereferences
    // (finding spawn-thread-fail-registry-leak). This errdefer is registered
    // AFTER the put so it only fires when the put succeeded.
    errdefer _ = self.sessions.remove(id);

    // The owning thread runs start -> runRenderLoop -> park -> destroy on one
    // thread (Phase-1 invariant). reply Attached is sent by the caller after
    // this.
    e.thread = try std.Thread.spawn(.{}, sessionOwnerThread, .{e});
    return e;
}

fn sessionOwnerThread(e: *SessionEntry) void {
    // This thread is the SOLE owner of Session.destroy() (Phase-1 invariant:
    // render loop + destroy share a thread). It never removes/frees the
    // SessionEntry — that is the closer's job (handleClose/deinit), gated so
    // exactly one of {Close, deinit} frees the entry. See SessionEntry's doc.

    if (e.session.start()) {
        // Started OK; run the render loop until the child exits OR a teardown
        // notifies render_stop.
        e.session.runRenderLoop() catch |err| {
            log.warn("session render loop err={}", .{err});
        };
        // The render loop returned. Two cases:
        //   1. Natural child exit (no teardown yet): the Session stays VALID
        //      and registered so a reattach can recover the viewport + deliver
        //      the buffered ChildExited (plan §4.8). Park below; do NOT destroy
        //      here (that would dangle the registry entry — finding F1).
        //   2. Teardown-driven (Close/deinit notified render_stop): teardown is
        //      requested; the park below returns immediately.
        e.mutex.lock();
        e.child_dead = true;
        // Idle-leak fix: anchor the reaper grace window at child-death. buffered_child_exited
        // was already recorded by onChildExited during renderTick (before render_stop.notify
        // returned the render loop), so the anchor never precedes the buffered exit (a
        // within-grace reattach always replays it). A child that exits while ALREADY detached
        // has no subscriber to later drop, so this is its anchor; an attached one re-anchors
        // at last-detach. e.server.monoNowMs() is lock-free (no new lock order under e.mutex).
        e.dead_at_ms = e.server.monoNowMs();
        e.mutex.unlock();
    } else |err| {
        log.err("session start failed err={}", .{err});
        // start() failed before the render loop ran. The Session is unusable,
        // so flip session_alive=false (finding SR-R2-3) — matching the
        // documented lifecycle/sessionLive/teardownEntry contract — so no
        // dispatch (.input/.resize/.focus) or attach passes the sessionLive()
        // gate and dereferences a session whose IO thread never came up
        // (enqueuing into a mailbox nothing drains). With session_alive=false,
        // teardownEntry correctly skips render_stop.notify() for the never-run
        // render loop. We still defer the actual destroy() to after the park,
        // exactly like the normal path, so destroy() (which deinits
        // render_stop) ALWAYS happens-after the closer's set() — the
        // single-owner teardown ordering that fixes the notify-vs-deinit race.
        e.mutex.lock();
        e.child_dead = true;
        e.session_alive = false;
        // Idle-leak fix: mark this a start-FAILED orphan (reapable via reapEligible's
        // !session_alive && start_failed branch) and anchor its grace window, so the
        // reaper reclaims it after grace instead of leaking the parked owner until deinit.
        e.start_failed = true;
        e.dead_at_ms = e.server.monoNowMs();
        e.mutex.unlock();
    }

    // Block until the closer (handleClose/deinit) requests teardown. teardownEntry
    // removes the entry from the registry + clears subscribers BEFORE setting
    // this event, so by the time we wake no other thread can reach `e`.
    e.teardown.wait();

    // Destroy on THIS thread (Phase-1 invariant: render loop + destroy share a
    // thread; destroy's assert is skipped when runRenderLoop never ran). Runs
    // exactly once (one closer owns the entry via the registry fetchRemove).
    e.session.destroy();
    e.mutex.lock();
    e.session_alive = false;
    e.mutex.unlock();
}

/// Render-tick push callback (runs on the session owning thread). Serializes a
/// ModeFrame then a GridFrame (ModeFrame applied before/atomically-with the
/// GridFrame, plan §2.1) and writes both to every GRID subscriber AND, in a
/// second loop within the same e.mutex critical section, to every read-only
/// RENDER subscriber (Layer 1) — same mode/grid locals, reusing the same
/// per-conn closed-check.
fn onRender(ctx: *anyopaque, session: *Session, snapshot: *const RenderState.Snapshot) void {
    const e: *SessionEntry = @ptrCast(@alignCast(ctx));

    // Build the ModeFrame under the render mutex (reads terminal modes/flags).
    //
    // ACCEPTED Phase-2a window (finding SI-3): the `snapshot` was captured
    // earlier in Session.renderTick under render_mutex (T1) and the lock was
    // released before this callback ran; we RE-lock here to read the modes
    // (T2). The IO thread can mutate the terminal between T1 and T2, so the
    // broadcast ModeFrame may reflect terminal state strictly newer than the
    // grid it accompanies — the opposite of §2.1's "mode no later than grid".
    // Tolerated for Phase 2a: no GUI consumes these frames yet, and a mode flip
    // landing precisely between two back-to-back lock acquisitions on the owning
    // thread is rare. Phase-2b FOLLOWUP: sample the ModeFrame in the SAME
    // render_mutex critical section that captures the snapshot (extend the
    // on_render callback to carry the ModeFrame, as pushFullFrames already does
    // by capturing both under one lock), so mode + grid share one point-in-time
    // read.
    const mode: protocol.ModeFrame = blk: {
        session.render_mutex.lock();
        defer session.render_mutex.unlock();
        break :blk protocol.ModeFrame.fromTerminal(e.session_id, &session.io.terminal);
    };

    const grid: protocol.GridFrame = .{ .session_id = e.session_id, .snapshot = snapshot.* };

    e.mutex.lock();
    defer e.mutex.unlock();
    for (e.subscribers.items) |conn| {
        if (conn.closed.load(.acquire)) continue;
        conn.writeFramed(.mode_frame, mode);
        conn.writeFramed(.grid_frame, grid);
    }
    // Layer 1: fan the SAME mode+grid frames out to read-only RENDER subscribers.
    // Same e.mutex critical section, same mode/grid locals built once above. A conn
    // on BOTH lists would receive the pair twice; in practice the mirror conn is on
    // render_subscribers only (it never attaches), so no duplication occurs.
    //
    // Layer 2 prereq A (HARD FOLLOW-UP, NOW IMPLEMENTED): the render-sub delivery is
    // NON-BLOCKING — `renderOutPush` enqueues the pre-encoded frame onto a per-conn
    // bounded ring (drop-OLDEST on overflow, safe because grid/mode are absolute
    // snapshots) and a dedicated per-conn drain thread (`renderDrainLoop`) flushes
    // it with blocking writes OFF e.mutex. So a wedged REMOTE render subscriber (a
    // phone over a tailnet) can no longer head-of-line-block the primary GUI
    // `subscribers` above, stall this session's render thread, or delay
    // teardownEntry. The PRIMARY `subscribers` path above intentionally RETAINS the
    // SR-4 single-fast-local-peer blocking-write contract (a single fast local GUI);
    // only `render_subscribers` got the bounded-drop path. The read-only gate
    // (Conn.isRenderOnlySubscriber) remains conn-local + lock-free.
    for (e.render_subscribers.items) |conn| {
        if (conn.closed.load(.acquire)) continue;
        conn.renderOutEnsure(); // lazy-spawn the drain thread (idempotent)
        conn.renderOutPush(.mode_frame, mode);
        conn.renderOutPush(.grid_frame, grid);
    }
}

/// Child-exit callback (runs on the session owning thread). Pushes ChildExited
/// to subscribers if any, else buffers it for delivery on reattach.
fn onChildExited(ctx: *anyopaque, session: *Session, exit_code: u32, runtime_ms: u64) void {
    _ = session;
    const e: *SessionEntry = @ptrCast(@alignCast(ctx));
    const ce: protocol.ChildExited = .{
        .session_id = e.session_id,
        .exit_code = exit_code,
        .runtime_ms = runtime_ms,
    };

    e.mutex.lock();
    defer e.mutex.unlock();
    // ALWAYS record the exit (finding SR3-3) so a later reattach on a fresh
    // conn can learn the child is dead — even when the child exited while a
    // subscriber was attached (that subscriber gets it live below, but the
    // record must persist for future reattaches). deliverBufferedExit replays
    // this on every (re)attach; it is not consumed.
    e.buffered_child_exited = ce;
    for (e.subscribers.items) |conn| {
        if (conn.closed.load(.acquire)) continue;
        conn.writeFramed(.child_exited, ce);
    }
    // Layer 2 (Agent Dashboard, fix M2): also notify read-only RENDER subscribers
    // that the child exited. The COMMON Agent-Dashboard case is the agent process
    // exits while THIS host stays alive — without this a mirror would get no frame,
    // its socket would stay open (markMirrorEnded only fires on EOF/read-error), and
    // it would show a stale frozen frame forever and never declare "ended". We REUSE
    // the existing `child_exited` frame (additive — no new frame type) and deliver it
    // via the NON-BLOCKING bounded-drop render path (renderOutPush), NOT a blocking
    // write under e.mutex, so a slow/wedged mirror can never stall onChildExited.
    // child_exited carries no grid/mode state, so the drop-oldest ring is safe: the
    // mirror's client converts it to markMirrorEnded (does NOT close — it owns no
    // pty). The session stays alive host-side; buffered-exit replay for real ATTACH
    // reconnects is unchanged (above). A conn on BOTH lists is exceptional (a mirror
    // never attaches); a duplicate child_exited is idempotent client-side (fire-once).
    //
    // CAP-HEADROOM (why child_exited survives the drop-oldest ring): child_exited is
    // the LAST meaningful frame because the session stops rendering after the child
    // exits — render_stop.notify() fires in the SAME renderTick that drained this exit
    // (Session.renderTick), so no further renderTick pushes grid frames after it. The
    // single post-exit tick pushes at most {child_exited, mode_frame, grid_frame} = 3
    // frames, well within CAP (=4), so even an undrained ring cannot evict child_exited
    // here. INVARIANT for future changes: keep the per-tick render push count <= CAP-1
    // so a trailing grid_frame can never drop child_exited (which would silently lose
    // the "ended" signal — the exact bug this fix repairs).
    for (e.render_subscribers.items) |conn| {
        if (conn.closed.load(.acquire)) continue;
        conn.renderOutEnsure(); // lazy-spawn the drain thread (idempotent)
        conn.renderOutPush(.child_exited, ce);
    }
    // RAW subscribers (the web monitor's `/stream` source — subscribe_raw /
    // raw_output) ALSO need the exit. Unlike attach + render subscribers above,
    // a raw subscriber ONLY ever receives `raw_output`, so when the child dies
    // it would otherwise get NO further frame and NO socket EOF (this host stays
    // alive, the conn stays open) — its client's blocking read would hang
    // forever and the browser xterm view would freeze on stale content with no
    // fallback. This was the bug behind "monitor froze while AFK, input still
    // worked": input rides a separate live path, but the raw stream silently
    // stalled. We REUSE the existing `child_exited` frame (additive — no new
    // frame type, no minor bump; child_exited predates raw subscriptions so any
    // raw subscriber's negotiated version groks the tag) so WebMonitorHostClient
    // can end the stream and the page falls back to the live snapshot poll. The
    // blocking writeFramed matches the attach-subscriber path (child_exited is
    // small + one-shot); a raw subscriber never also attaches, so this is its
    // ONLY exit signal, and a duplicate is harmless (the client ends on the first).
    for (e.raw_subscribers.items) |conn| {
        if (conn.closed.load(.acquire)) continue;
        conn.writeFramed(.child_exited, ce);
    }
}

/// Search-status callback (runs on the session's SEARCH thread). Frames a
/// search_total / search_selected event to subscribers, mirroring onChildExited's
/// subscriber-broadcast shape. The match HIGHLIGHTS ride the grid_frame; this
/// carries only the n/total status. NOT buffered for reattach: a reattach gets a
/// fresh full frame (with highlights) via pushFullFrames, and the GUI recomputes
/// status from the live search state in Slice 4.
fn onSearchEvent(ctx: *anyopaque, session: *Session, event: Session.SearchEvent) void {
    _ = session;
    const e: *SessionEntry = @ptrCast(@alignCast(ctx));

    e.mutex.lock();
    defer e.mutex.unlock();
    for (e.subscribers.items) |conn| {
        if (conn.closed.load(.acquire)) continue;
        switch (event) {
            .total => |t| conn.writeFramed(.search_total, protocol.SearchTotal{
                .session_id = e.session_id,
                .present = @intFromBool(t != null),
                .total = if (t) |v| @intCast(v) else 0,
            }),
            .selected => |s| conn.writeFramed(.search_selected, protocol.SearchSelected{
                .session_id = e.session_id,
                .present = @intFromBool(s != null),
                .idx = if (s) |v| @intCast(v) else 0,
            }),
        }
    }
}

/// Slice B1 selection-text callback. Frames a `selection_text` event to every
/// subscriber, mirroring onRender/onSearchEvent's broadcast shape. `text` BORROWS
/// the caller's buffer (Session frees it after this returns), so `writeFramed` ->
/// `encode` must copy it synchronously here — which it does per subscriber.
///
/// LOCK DISCIPLINE (findings SEL-1 / SEL-LOCK-1): this runs on the session
/// OWNING thread, from Session.renderTick (which drains the selection text staged
/// by selectDrag/selectClear), holding ONLY the session-local `e.mutex` here —
/// NOT the app-global `registry_mutex`. Like onRender, the owning thread is
/// joined by teardownEntry, so it never races the registry teardown, and a slow
/// subscriber's blocking write only stalls THIS session (the documented SR-4
/// single-GUI contract), never head-of-line-blocks dispatch for other sessions.
///
/// NOT buffered for reattach: a reattach gets row.selection (the highlight) via
/// pushFullFrames; the selection TEXT cache re-seeds on the next drag. Matches
/// onSearchEvent's no-buffer policy.
fn onSelectionText(ctx: *anyopaque, session: *Session, present: bool, text: []const u8) void {
    _ = session;
    const e: *SessionEntry = @ptrCast(@alignCast(ctx));

    e.mutex.lock();
    defer e.mutex.unlock();
    for (e.subscribers.items) |conn| {
        if (conn.closed.load(.acquire)) continue;
        conn.writeFramed(.selection_text, protocol.SelectionText{
            .session_id = e.session_id,
            .present = present,
            .text = text,
        });
    }
}

/// Phase D at-prompt callback (runs on the session owning thread from renderTick,
/// off registry_mutex — same blocking-write discipline as onSelectionText). Frames
/// the authoritative at-prompt bit to every subscriber so the GUI can cache it for
/// needsConfirmQuit.
fn onAtPrompt(ctx: *anyopaque, session: *Session, at_prompt: bool) void {
    _ = session;
    const e: *SessionEntry = @ptrCast(@alignCast(ctx));

    e.mutex.lock();
    defer e.mutex.unlock();
    for (e.subscribers.items) |conn| {
        if (conn.closed.load(.acquire)) continue;
        conn.writeFramed(.at_prompt, protocol.AtPrompt{
            .session_id = e.session_id,
            .at_prompt = at_prompt,
        });
    }
}

/// fork (minor 3): does a conn want `process_info`? Pure predicate so the gating
/// rule is unit-testable independent of constructing a Conn. The frame's tag is
/// not in an older GUI's FrameType enum, so emit it ONLY to peers that advertised
/// minor >= 3 (see the Conn.negotiated_minor / protocol minor-3 comments).
pub fn processInfoAllowed(negotiated_minor: u16) bool {
    return negotiated_minor >= 3;
}

/// fork (minor 4): does a conn want the `foreground_pid` frame? Same compat model
/// as processInfoAllowed: emit ONLY to peers that advertised minor >= 4 (an older
/// GUI has no `foreground_pid` tag and treats an unknown tag as fatal).
pub fn foregroundPidAllowed(negotiated_minor: u16) bool {
    return negotiated_minor >= 4;
}

/// fork (minor 3) foreground-process callback. Runs on the session OWNING thread
/// from renderTick, off registry_mutex — same blocking-write discipline as
/// onAtPrompt. Frames the resolved foreground process name + command to every
/// subscriber that NEGOTIATED minor >= 3 (the compat gate: an older GUI's
/// FrameType enum has no `process_info` tag and its read loop treats an unknown
/// tag as fatal, so it must never be sent one). The `name`/`command` slices are
/// BORROWED (owned by renderTick, freed after this returns) — `writeFramed` ->
/// `encode` copies them synchronously per subscriber, before this returns.
fn onProcessInfo(ctx: *anyopaque, session: *Session, pid: u64, name: []const u8, command: []const u8) void {
    _ = session;
    const e: *SessionEntry = @ptrCast(@alignCast(ctx));

    e.mutex.lock();
    defer e.mutex.unlock();
    for (e.subscribers.items) |conn| {
        if (conn.closed.load(.acquire)) continue;
        // Compat gate: skip peers that didn't negotiate minor 3 — they cannot
        // decode this tag (see processInfoAllowed).
        if (processInfoAllowed(conn.negotiated_minor)) {
            conn.writeFramed(.process_info, protocol.ProcessInfo{
                .session_id = e.session_id,
                .name = name,
                .command = command,
            });
        }
        // minor 4: also ship the RAW foreground pid so the GUI can walk the
        // process subtree locally and classify the agent (the host can't — it
        // lacks the agent set; see ForegroundPid). `pid` is the tcgetpgrp leader.
        if (foregroundPidAllowed(conn.negotiated_minor)) {
            conn.writeFramed(.foreground_pid, protocol.ForegroundPid{
                .session_id = e.session_id,
                .pid = pid,
            });
        }
    }
}

/// H1 (Phase 2b) RAW-output callback. Runs on the session's IO THREAD (invoked
/// from Termio.processOutputLocked via Session.rawOutputObserver, under the
/// session's render_mutex), with `buf` BORROWING the IO read buffer (valid only
/// during this call). Frames a `raw_output` to every RAW subscriber, mirroring
/// onSurfaceEvent's broadcast shape — `writeFramed` -> `encode` copies `buf`
/// synchronously per subscriber, before this returns.
///
/// LOCK DISCIPLINE: holds ONLY the session-local `e.mutex` here (NOT
/// registry_mutex). Unlike onRender/onSelectionText (which run on the owning
/// render-loop thread), this runs on the IO thread, so a wedged RAW subscriber's
/// blocking write head-of-line-blocks the IO thread (the pty drain) for THIS
/// session only — accepted under the same SR-4 single/local fast-peer contract
/// as the existing subscribers (the web monitor peer is LOCAL/fast). NOT
/// buffered beyond the ring (the ring already covers replay-on-reconnect).
fn onRawOutput(ctx: *anyopaque, session: *Session, buf: []const u8) void {
    _ = session;
    const e: *SessionEntry = @ptrCast(@alignCast(ctx));

    e.mutex.lock();
    defer e.mutex.unlock();
    for (e.raw_subscribers.items) |conn| {
        if (conn.closed.load(.acquire)) continue;
        conn.writeFramed(.raw_output, protocol.RawOutput{
            .session_id = e.session_id,
            .bytes = buf,
        });
    }
}

/// Slice 6 SurfaceEvent callback (runs on the session owning thread, invoked
/// SYNCHRONOUSLY from Session's app-queue drain while `msg` — including any owned
/// WriteReq bytes — is still alive). Builds a `surface_event` frame from the
/// forwarded `apprt.surface.Message` and writes it to every subscriber, mirroring
/// onChildExited/onSearchEvent's broadcast shape.
///
/// EXCLUDED variants return `error.NotForwarded` from `SurfaceEvent.fromMessage`;
/// we simply DROP those (no frame) so the channel forwards exactly the §4.5
/// subset. `fromMessage` BORROWS `msg` (its byte-slice variants alias the live
/// message), so the SurfaceEvent must be encoded here, synchronously, before this
/// returns — which `writeFramed` -> `encode` does per subscriber.
///
/// NOT buffered for reattach: these are live terminal events (title/bell/colors/
/// cwd/etc.); a reattach gets fresh full state via pushFullFrames and the live
/// stream resumes. Matches onSearchEvent's no-buffer policy.
fn onSurfaceEvent(ctx: *anyopaque, session: *Session, msg: *const @import("../apprt.zig").surface.Message) void {
    _ = session;
    const e: *SessionEntry = @ptrCast(@alignCast(ctx));

    const ev = protocol.SurfaceEvent.fromMessage(e.session_id, msg) catch |err| switch (err) {
        // An EXCLUDED variant reached the drain; the host deliberately does not
        // forward it (it has a dedicated path or is GUI-/config-side). Drop it.
        error.NotForwarded => return,
    };

    e.mutex.lock();
    defer e.mutex.unlock();
    for (e.subscribers.items) |conn| {
        if (conn.closed.load(.acquire)) continue;
        conn.writeFramed(.surface_event, ev);
    }
}

/// --- Slice 3c: host-side OSC8 hover links ---
///
/// Compute the OSC8 link-cell set for the hover and reply to the REQUESTING
/// `conn` (not all subscribers — each GUI has its own mouse) with a LinkFrame.
/// `present=false` or a missing/torn-down session => an empty LinkFrame so the
/// GUI deterministically clears its OSC8 overlay (never a silent no-op).
///
/// Lock order mirrors `.input`/`.set_search`: hold `registry_mutex` across the
/// whole dereference (finding F3 TOCTOU) so a concurrent Close/deinit can't
/// free the entry while we read its terminal. The link computation takes
/// `render_mutex` (Session.hoverLink reads the live terminal via
/// RenderState.update), which is a distinct lock; the canonical order is
/// registry_mutex outermost, then per-session locks, so this adds no deadlock
/// risk. The reply write happens AFTER we drop both locks (writeFramed can
/// block on a slow peer; see the BLOCKING-WRITE CONTRACT).
fn handleHover(self: *Server, conn: *Conn, hover: protocol.Hover) !void {
    const alloc = self.alloc;

    // NOTE (known-low, deliberate): unlike the brief `.input`/`.set_search`
    // arms — which take `registry_mutex` only long enough to look up the entry
    // and enqueue a mailbox message — this arm holds `registry_mutex` across the
    // full `hoverLink` (RenderState.update + linkCells). Holding it keeps the
    // SessionEntry alive against the teardown path (which removes from the
    // registry under this same lock) without a separate liveness handshake. The
    // compute is bounded (one viewport's link match) and hover is low-frequency
    // (ctrl/super held), so the head-of-line cost to other registry lookups is
    // accepted rather than risk a use-after-free by releasing the lock mid-
    // compute. Revisit if hover ever becomes hot.
    //
    // Build the link cells under both locks, then release before writing.
    var cells: []protocol.LinkFrame.Cell = &.{};
    defer if (cells.len > 0) alloc.free(cells);

    if (hover.present) compute: {
        self.registry_mutex.lock();
        defer self.registry_mutex.unlock();
        const e = self.sessions.get(hover.session_id) orelse break :compute;
        if (!sessionLive(e)) break :compute;

        const mods: @import("../input.zig").Mods = @bitCast(hover.mods);
        const viewport: @import("../terminal/main.zig").point.Coordinate = .{
            .x = hover.viewport_x,
            .y = hover.viewport_y,
        };

        e.session.render_mutex.lock();
        defer e.session.render_mutex.unlock();
        var set = e.session.hoverLink(alloc, viewport, mods) catch |err| {
            log.warn("hoverLink failed err={}", .{err});
            break :compute;
        };
        defer set.deinit(alloc);
        cells = protocol.LinkFrame.cellsFromSet(alloc, &set) catch |err| {
            log.warn("link cell projection failed err={}", .{err});
            break :compute;
        };
    }

    // Reply to the requester (empty cells == "no link / clear overlay").
    conn.writeFramed(.link_frame, protocol.LinkFrame{
        .session_id = hover.session_id,
        .cells = cells,
    });
}

/// Push a full GridFrame + ModeFrame to all subscribers immediately (used on
/// (re)attach so a freshly-subscribed GUI gets state without waiting a tick).
fn pushFullFrames(self: *Server, e: *SessionEntry) !void {
    _ = self;
    const session = e.session;

    // Capture the snapshot AND the ModeFrame in a SINGLE render_mutex critical
    // section (finding SI-3) so mode and grid share one point-in-time read and
    // the §2.1 "mode applied before/atomically-with the grid" pairing holds by
    // construction. Two separate lock acquisitions would let the IO thread
    // mutate the terminal between them, yielding a ModeFrame strictly newer
    // than the grid it accompanies.
    const captured = blk: {
        session.render_mutex.lock();
        defer session.render_mutex.unlock();
        // Route through captureSnapshotLocked (not the bare Snapshot.capture)
        // so any active host search highlights are flattened into row.highlights
        // for a freshly-(re)attached GUI too (no-op when no search is active).
        // We already hold render_mutex here.
        const snap = session.captureSnapshotLocked(session.alloc) catch |err| {
            log.warn("attach snapshot failed err={}", .{err});
            return;
        };
        break :blk .{
            .snapshot = snap,
            .mode = protocol.ModeFrame.fromTerminal(e.session_id, &session.io.terminal),
            // Phase D: seed the at-prompt bit so a freshly-(re)attached GUI has it
            // immediately (the steady-state push only fires on a FLIP, which may
            // not happen for a long time after attach). Read in the same critical
            // section as the snapshot/mode for a coherent point-in-time view.
            .at_prompt = session.io.terminal.cursorIsAtPrompt(),
            // CWD-INHERIT (reattach seed): the steady-state pwd push only fires
            // on OSC 7 (next prompt), so a freshly-(re)attached GUI wouldn't learn
            // the session's current cwd until then — a split made right after a
            // GUI restart+reattach would inherit $HOME. Capture the live pwd here
            // (same critical section, coherent with the grid) and push it below
            // so the GUI's mirror is seeded immediately. DUPE it: getPwd()
            // returns a slice into the terminal buffer, valid only under this
            // lock, but the writes happen after we release it. null/empty pwd =>
            // skip (GUI keeps $HOME default). Freed after the write loop.
            .pwd = if (session.io.terminal.getPwd()) |p|
                session.alloc.dupe(u8, p) catch null
            else
                null,
        };
    };
    var snapshot = captured.snapshot;
    defer snapshot.deinit(session.alloc);
    defer if (captured.pwd) |p| session.alloc.free(p);

    const mode = captured.mode;
    const grid: protocol.GridFrame = .{ .session_id = e.session_id, .snapshot = snapshot };

    e.mutex.lock();
    defer e.mutex.unlock();

    // fork (minor 3): process_info reattach seed. The steady-state push fires
    // ONLY when renderTick observes a foreground-pid CHANGE, and prev_fg_pid is
    // Session-lifetime state that SURVIVES detach/reattach — so a GUI relaunch to
    // a session whose foreground pid is unchanged (the headline reattach-while-
    // `claude`-keeps-running case) would otherwise never re-push, leaving the new
    // GUI's name/command null indefinitely. Resolve the live foreground pid here
    // (same reasoning as the at_prompt/pwd seeds above) and push it to the newly-
    // attaching subscribers below, gated on negotiated_minor >= 3.
    //
    // The foreground pid is read via getProcessInfo (touches only the pty fd, no
    // render_mutex) and resolve() does sysctl(KERN_PROCARGS2)+libproc proc_name —
    // done OFF render_mutex (already released) so it never blocks the IO thread,
    // but NOTE it DOES run under both e.mutex and the caller's registry_mutex
    // (see handleAttach), lengthening that serialized critical section by a
    // bounded syscall pair on attach (rare). It is resolved LAZILY inside the
    // loop on the FIRST minor>=3 subscriber and memoized, so an old-GUI-only
    // attach (all subscribers minor<=2, the OLD-GUI+NEW-host compat case) does
    // ZERO sysctl/libproc work. null pid / failed resolve => skip (the new GUI is
    // then seeded by the first post-attach pid change, as before).
    var proc: ?proc_info.ProcInfo = null;
    var proc_resolved = false;
    var fg_pid: u64 = 0; // raw foreground pid, for the minor-4 foreground_pid seed
    defer if (proc) |p| {
        session.alloc.free(p.name);
        session.alloc.free(p.command);
    };

    for (e.subscribers.items) |conn| {
        if (conn.closed.load(.acquire)) continue;
        conn.writeFramed(.mode_frame, mode);
        conn.writeFramed(.grid_frame, grid);
        conn.writeFramed(.at_prompt, protocol.AtPrompt{
            .session_id = e.session_id,
            .at_prompt = captured.at_prompt,
        });
        // CWD-INHERIT (reattach seed): push the live pwd captured above so the
        // GUI mirror has the session's real cwd immediately on attach. The GUI's
        // pwd_change handler both seeds its local terminal (so new splits inherit
        // correctly) and updates the window proxy-icon/title. Skipped when no pwd
        // is known (captured.pwd == null).
        if (captured.pwd) |p| conn.writeFramed(.surface_event, protocol.SurfaceEvent{
            .session_id = e.session_id,
            .payload = .{ .pwd_change = p },
        });
        // process_info reattach seed (gated minor >= 3, like onProcessInfo's
        // steady-state broadcast). Resolve lazily on the first minor>=3 conn so
        // an old-GUI-only attach does no sysctl/libproc work; skipped when the
        // pid was unresolvable.
        if (processInfoAllowed(conn.negotiated_minor)) {
            if (!proc_resolved) {
                proc_resolved = true;
                if (session.io.getProcessInfo(.foreground_pid)) |fg| {
                    fg_pid = fg;
                    proc = proc_info.resolve(session.alloc, fg);
                }
            }
            if (proc) |p| conn.writeFramed(.process_info, protocol.ProcessInfo{
                .session_id = e.session_id,
                .name = p.name,
                .command = p.command,
            });
        }
        // minor 4 foreground-pid reattach seed: ship the raw fg pid (resolved
        // lazily in the >=3 block above — foregroundPidAllowed implies
        // processInfoAllowed, so fg_pid is set before this runs; 0 if none) so a
        // freshly-attached GUI can walk the subtree immediately. Gated >= 4.
        if (foregroundPidAllowed(conn.negotiated_minor)) {
            conn.writeFramed(.foreground_pid, protocol.ForegroundPid{
                .session_id = e.session_id,
                .pid = fg_pid,
            });
        }
    }
}

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
    // Layer 2 prereq A: the seed is NON-BLOCKING — `renderOutPush` enqueues onto the
    // same per-conn bounded ring the live onRender path uses, drained by the conn's
    // dedicated drain thread OFF the locks. So although the caller
    // (handleSubscribeRender) holds registry_mutex (the app-global lock) here, a
    // wedged REMOTE render subscriber can NO LONGER head-of-line-block registry-wide
    // work (every session lookup/attach/close) for the seed write. The frame ENCODE
    // (protocol.encodeFrame, O(grid)) still runs under registry_mutex — same cost the
    // old blocking writeFramed paid, not a regression — but the leaf-mutex append is
    // O(1) and, crucially, the BLOCKING SOCKET WRITE (the thing that actually stalled)
    // now happens off-lock on the drain thread. Lazy-spawn the drain thread here too (under
    // registry_mutex — brief, leaf-only new thread, no lock-order edge). BEST-EFFORT:
    // a snapshot-capture failure logs + returns above and an enqueue drop is
    // self-healing, so the conn stays registered regardless (a later live onRender
    // tick re-delivers); the subscription never hinges on this seed.
    conn.renderOutEnsure();
    conn.renderOutPush(.mode_frame, captured.mode);
    conn.renderOutPush(.grid_frame, grid);
}

fn deliverBufferedExit(self: *Server, e: *SessionEntry) void {
    _ = self;
    e.mutex.lock();
    defer e.mutex.unlock();
    if (e.buffered_child_exited) |ce| {
        for (e.subscribers.items) |conn| {
            if (conn.closed.load(.acquire)) continue;
            conn.writeFramed(.child_exited, ce);
        }
        // Do NOT clear (finding SR3-3): once the child is dead it stays dead,
        // and EVERY (re)attach — including a third, fourth, … fresh conn — must
        // be able to learn it. Clearing here would make the record consume-once,
        // so a later reattach after this one detaches would receive no
        // ChildExited and the GUI could not tell the child is dead — the exact
        // SR3-3 harm, one reattach deferred. The record is permanent until the
        // entry is Closed (the documented "replayed indefinitely" invariant on
        // SessionEntry.buffered_child_exited).
    }
}

fn handleClose(self: *Server, conn: *Conn, session_id: u64) !void {
    var entry: ?*SessionEntry = null;
    {
        self.registry_mutex.lock();
        defer self.registry_mutex.unlock();
        // Layer 1 read-only gate: a render-ONLY conn (the mirror) must never
        // close (destroy) the real session. Conn-local membership check (no
        // e.mutex), BEFORE fetchRemove tears it down.
        if (conn.isRenderOnlySubscriber(session_id)) {
            log.debug("dropping close from render-only conn session={d}", .{session_id});
            return;
        }
        if (self.sessions.fetchRemove(session_id)) |kv| entry = kv.value;
    }
    // fetchRemove hands the entry to exactly one caller, so Close-vs-Close and
    // Close-vs-deinit can never both tear down the same entry.
    const e = entry orelse return;
    self.teardownEntry(e);
}

/// Tear down a SessionEntry that has ALREADY been removed from the registry
/// (so no concurrent dispatch/attach can find it). Drops subscribers, signals
/// the owning thread to destroy the Session on its own thread (Phase-1
/// invariant), joins it, then frees the entry. Exactly one caller per entry
/// (guaranteed by the registry fetchRemove). Fixes F1/F2/notify-race: the
/// teardown is requested via the `teardown` event + render_stop, and the owner
/// thread is the sole party that touches render_stop after this point.
fn teardownEntry(self: *Server, e: *SessionEntry) void {
    // Drop subscribers so the render-tick push (onRender) stops touching them.
    // H1 (Phase 2b): drop RAW subscribers in the SAME critical section so the
    // IO-thread onRawOutput broadcast (which iterates e.raw_subscribers under
    // e.mutex) stops touching them too, before any Conn is freed.
    {
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
    }

    // Ask the owning thread to tear down. ORDER MATTERS (fixes the
    // render-stop-notify-vs-deinit-race):
    //
    //   1. notify render_stop — breaks the render loop if it is still running.
    //      (If the child already exited, the loop has returned and the owner is
    //      parked on teardown.wait(); this notify just wakes a now-idle async,
    //      harmless.)
    //   2. THEN set `teardown` — releases the owner from teardown.wait().
    //
    // The owner thread ALWAYS reaches teardown.wait() before it can call
    // Session.destroy() (which deinits render_stop). Because we set() the event
    // only AFTER notify() returns, the external notify() strictly
    // happens-before the owner's destroy()/render_stop.deinit() — they can
    // never run concurrently on the same async. The owner is the sole party
    // that deinits render_stop.
    //
    // EXCEPTION: if start() failed, the owner parked with session_alive=false
    // (finding SR-R2-3) and will destroy the Session (deinit'ing render_stop)
    // on its own thread right after we release the park. We must NOT touch
    // render_stop in that case — just release the park.
    const alive = blk: {
        e.mutex.lock();
        defer e.mutex.unlock();
        e.teardown_requested = true;
        break :blk e.session_alive;
    };
    if (alive) {
        e.session.render_stop.notify() catch |err|
            log.warn("render_stop notify failed err={}", .{err});
    }
    e.teardown.set();

    // Join the owning thread (it runs Session.destroy on its own thread), then
    // free the entry. After join the owner has exited, so freeing is safe.
    if (e.thread) |t| t.join();
    self.alloc.destroy(e);
}

/// Tear down the server: stop accepting, quiesce read threads, tear down
/// sessions, then free conns.
///
/// ORDER MATTERS — two distinct ordering constraints, both load-bearing:
///
///  (1) Registry safety (fixes ZM-DEINIT-RACE): connection read threads must
///      stop touching `self.sessions` BEFORE the registry is drained/deinit'd.
///      A read thread already inside dispatch() does not re-check `running`, so
///      flipping `running=false` does not stop an in-flight dispatch — it can
///      still `self.sessions.get(...)` (UAF after sessions.deinit) or, via
///      handleAttach->spawnSession, `self.sessions.put(...)` AFTER the drain
///      loop (leak + UAF). So we first shut every conn fd and WAIT until every
///      read thread has fully exited (i.e. `self.conns` is empty). On exit a
///      read thread runs unsubscribeAll() and then migrates itself off `conns`
///      (readLoop), so an empty `conns` proves no read thread can reach either
///      `self.sessions` or any subscriber list again. Only then do we drain the
///      registry + call sessions.deinit().
///
///  (2) Conn-free safety (fixes F2): a Conn must only be FREED after every
///      session owner thread is joined. A session owner can be mid-onRender,
///      iterating `e.subscribers` and writing to Conn fds, right up until it is
///      joined. Read threads unsubscribe before migrating (so a quiesced read
///      thread no longer appears in any subscriber list), but we still defer the
///      reaper's free of `dead_conns` until after the session drain joins all
///      owner threads, keeping the F2 invariant intact by construction.
pub fn deinit(self: *Server) void {
    self.running.store(false, .release);

    // Closing the listen fd unblocks the accept thread.
    posix.close(self.listen_fd);
    if (self.accept_thread) |t| t.join();

    // Idle-leak fix: stop + join the SESSION reaper before draining the registry, so it
    // is never mid-teardownEntry (which frees an entry) when the drain loop runs. Clear
    // the running flag FIRST (so the woken thread observes it via the event's
    // release/acquire), then set the ONE-SHOT shutdown event, then join. Even an
    // interleaving with the conn-quiesce spin or the drain would be race-free (the reaper
    // touches only self.sessions + teardownEntry, never conns, and every reap goes through
    // the single-owner fetchRemove gate the drain also uses), but join-before-drain keeps
    // it clean.
    self.session_reaper_running.store(false, .release);
    self.session_reaper_event.set();
    if (self.session_reaper_thread) |t| t.join();

    // QUIESCE read threads BEFORE touching the registry (constraint 1). Shut
    // every live conn's fd so its read thread breaks out of read()/dispatch,
    // unsubscribes, and self-migrates from `conns` to `dead_conns`.
    {
        self.conns_mutex.lock();
        defer self.conns_mutex.unlock();
        for (self.conns.items) |conn| {
            conn.closed.store(true, .release);
            posix.shutdown(conn.fd, .both) catch {};
        }
    }
    // Spin until `conns` is empty: every read thread has exited its dispatch
    // loop and unsubscribed, so none can touch `self.sessions` (or any
    // subscriber list) past this point. We must NOT signal the reaper to FREE
    // the migrated Conns yet — owner threads (still live until the session
    // drain below) must not race a freed Conn (constraint 2); the reaper is told
    // to drain only after sessions are torn down.
    while (true) {
        self.conns_mutex.lock();
        const remaining = self.conns.items.len;
        self.conns_mutex.unlock();
        if (remaining == 0) break;
        std.Thread.yield() catch {};
    }

    // Now no read thread survives to touch the registry: drain all remaining
    // sessions (clears subscribers, joins owner threads, frees entries) and
    // deinit the map. Drain under the mutex so we don't race a concurrent
    // handleClose for the same entry (fetchRemove hands each entry to exactly
    // one of {Close, deinit}); with read threads gone, no new put can occur.
    while (true) {
        var entry: ?*SessionEntry = null;
        {
            self.registry_mutex.lock();
            defer self.registry_mutex.unlock();
            var it = self.sessions.iterator();
            if (it.next()) |kv| {
                const id = kv.key_ptr.*;
                entry = kv.value_ptr.*;
                _ = self.sessions.remove(id);
            }
        }
        const e = entry orelse break;
        self.teardownEntry(e);
    }
    self.sessions.deinit();

    // Tell the reaper to drain `dead_conns` and exit, then join it. By now
    // `conns` is already empty (we spun on it above) and every exited read
    // thread has migrated its Conn into `dead_conns`, so the reaper drains those
    // and then observes BOTH lists empty and returns. This is safe w.r.t. F2:
    // all session owner threads were joined by the session drain above, so no
    // onRender can reference a Conn that the reaper is about to free. We post
    // once here to cover the already-quiet case (no conns at deinit); each
    // read-thread exit also posted the signal.
    self.reaper_running.store(false, .release);
    self.reaper_signal.post();
    if (self.reaper_thread) |t| t.join();

    self.dead_conns.deinit(self.alloc);
    self.conns.deinit(self.alloc);

    posix.unlink(self.path) catch {};
    self.alloc.free(self.path);

    const alloc = self.alloc;
    alloc.destroy(self);
}
