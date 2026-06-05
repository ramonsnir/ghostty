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

const log = std.log.scoped(.host_server);

/// 1 MiB socket buffers so a full grid frame never short-writes (plan §2).
const SOCKET_BUF: c_int = 1 * 1024 * 1024;

alloc: Allocator,

/// The bound, listening AF_UNIX socket.
listen_fd: posix.socket_t,
/// The bound socket path, owned (unlinked on deinit).
path: []const u8,

/// Registry of live sessions, keyed by host-assigned session_id.
sessions: std.AutoHashMap(u64, *SessionEntry),
registry_mutex: std.Thread.Mutex = .{},
next_session_id: u64 = 1,

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

host_pid: i32,
host_start_epoch: i64,

accept_thread: ?std.Thread = null,
running: std.atomic.Value(bool) = .init(true),

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
};

/// A single GUI connection.
pub const Conn = struct {
    server: *Server,
    fd: posix.socket_t,
    reader: protocol.FrameReader = .{},
    /// session_ids this conn is subscribed to (so disconnect can unsubscribe).
    subscribed: std.AutoHashMap(u64, void),
    /// Serializes writes to this fd across the read thread (Pong/Attached/etc)
    /// and the various render threads (GridFrame/ModeFrame broadcast).
    write_mutex: std.Thread.Mutex = .{},
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
};

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
    };

    return self;
}

/// Spawn the accept + reaper threads. Returns immediately.
pub fn start(self: *Server) !void {
    self.reaper_thread = try std.Thread.spawn(.{}, reaperLoop, .{self});
    self.accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
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
    posix.close(conn.fd);
    conn.subscribed.deinit();
    conn.reader.deinit(self.alloc);
    self.alloc.destroy(conn);
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
    _ = std.posix.system.setsockopt(
        fd,
        posix.SOL.SOCKET,
        opt,
        std.mem.asBytes(&SOCKET_BUF),
        @sizeOf(c_int),
    );
}

fn setupConn(self: *Server, fd: posix.socket_t) !void {
    // Raise socket buffers (best-effort; never fatal — see setSockBuf).
    setSockBuf(fd, posix.SO.SNDBUF);
    setSockBuf(fd, posix.SO.RCVBUF);

    const conn = try self.alloc.create(Conn);
    errdefer self.alloc.destroy(conn);
    conn.* = .{
        .server = self,
        .fd = fd,
        .subscribed = std.AutoHashMap(u64, void).init(self.alloc),
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
        posix.close(conn.fd);
        conn.subscribed.deinit();
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
            conn.writeFramed(.hello_ack, protocol.HelloAck{
                .host_pid = self.host_pid,
                .host_start_epoch = self.host_start_epoch,
            });
        },

        .attach => {
            var attach = try protocol.Attach.decode(alloc, frame.payload);
            defer attach.deinit(alloc);
            // SLICE 11: carry the spawn-opt cwd through to the spawn path.
            // `working_directory` is borrowed from the decoded frame (freed by
            // `attach.deinit` above); handleAttach/spawnSession use it
            // synchronously to seed Session.Options before this returns, and
            // Session.create dupes it into the session config's arena — no
            // lifetime extension needed past this call.
            try self.handleAttach(conn, attach.session_id, attach.working_directory);
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
                if (sessionLive(e)) e.session.reset();
            }
        },

        .detach => {
            var detach = try protocol.Detach.decode(alloc, frame.payload);
            defer detach.deinit(alloc);
            self.registry_mutex.lock();
            defer self.registry_mutex.unlock();
            if (self.sessions.get(detach.session_id)) |e| {
                e.removeSubscriber(conn);
                _ = conn.subscribed.remove(detach.session_id);
                // Child stays alive (Session NOT stopped).
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
                if (sessionLive(e)) e.session.navSearch(nav.dir);
            }
        },

        .clear_search => {
            var clear = try protocol.ClearSearch.decode(alloc, frame.payload);
            defer clear.deinit(alloc);
            self.registry_mutex.lock();
            defer self.registry_mutex.unlock();
            if (self.sessions.get(clear.session_id)) |e| {
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
        .hello_ack, .attached, .grid_frame, .mode_frame, .child_exited, .pong, .search_total, .search_selected, .link_frame, .surface_event, .selection_text, .at_prompt => {
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
    // id) honors the Attach's spawn-opt cwd; a LIVE reattach above returned
    // before reaching here, so it never applies the cwd (the existing session
    // keeps its own). `null` => host default ($HOME), today's behavior.
    const e = try self.spawnSession(working_directory);
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

/// Spawn a fresh Session, register it, and start its dedicated owning thread.
/// CALLER MUST HOLD registry_mutex (findings SR-1 / ZM1): the only caller,
/// handleAttach, holds it across the whole spawn+dereference so a concurrent
/// Close cannot fetchRemove+free the entry mid-attach.
fn spawnSession(self: *Server, working_directory: ?[]const u8) !*SessionEntry {
    const id = self.next_session_id;
    self.next_session_id += 1;

    // SLICE 11: seed the spawn-opt cwd into Session.Options. Session.create
    // dupes it into the session config's arena, so the borrowed slice (from the
    // decoded Attach frame, still alive in handleClientFrame) only needs to
    // outlive this call. `null` => the config's $HOME finalize default stands.
    const session = try Session.create(self.alloc, .{
        .working_directory = working_directory,
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
/// GridFrame, plan §2.1) and writes both to every subscriber.
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
        };
    };
    var snapshot = captured.snapshot;
    defer snapshot.deinit(session.alloc);

    const mode = captured.mode;
    const grid: protocol.GridFrame = .{ .session_id = e.session_id, .snapshot = snapshot };

    e.mutex.lock();
    defer e.mutex.unlock();
    for (e.subscribers.items) |conn| {
        if (conn.closed.load(.acquire)) continue;
        conn.writeFramed(.mode_frame, mode);
        conn.writeFramed(.grid_frame, grid);
        conn.writeFramed(.at_prompt, protocol.AtPrompt{
            .session_id = e.session_id,
            .at_prompt = captured.at_prompt,
        });
    }
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
    _ = conn;
    var entry: ?*SessionEntry = null;
    {
        self.registry_mutex.lock();
        defer self.registry_mutex.unlock();
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
    {
        e.mutex.lock();
        e.subscribers.deinit(self.alloc);
        e.subscribers = .empty;
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
