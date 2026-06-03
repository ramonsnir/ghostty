//! Client implements a termio backend that talks to an out-of-process pty
//! host (the "ptyhost") instead of owning a subprocess + pty directly the way
//! `Exec` does. This is the `.client` arm of the termio backend union.
//!
//! ## Slice 2 status (Phase 2b-1)
//!
//! The Client is now FUNCTIONALLY REAL INTERNALLY, but still NOT selectable
//! (Surface.zig hardcodes `.exec`) and NOT wired to the renderer (Slice 3).
//! It owns a GUI-side MIRROR of the terminal's render state:
//!
//!   - `render_state`: a `terminal.RenderState` (the draw source the renderer
//!     will later read), rehydrated from decoded `GridFrame`s — the inverse of
//!     the host-side `Snapshot.fromRenderState`.
//!   - `mode`: the flat ~14-field `protocol.ModeFrame` input-mode mirror.
//!   - `images`: a `renderer/image.zig` `State` mirror slot (stays `.empty`
//!     this slice — no ImageFrame on the wire until Phase 3).
//!
//! All three are held under the mutex returned by `renderMutex()` (see the
//! `owned_mutex` / `render_mutex` fields). Slice 3d RECONCILED the lock
//! domains: when the renderer-state mutex is supplied (via `Config.render_mutex`
//! or `setRenderMutex`), the Client guards these mirrors under THAT SAME
//! `*std.Thread.Mutex` the renderer reads them under, so writer (read-thread
//! `handleFrame`) and reader (render-thread `updateFrame` `copyFrom`) are fully
//! serialized on one lock. When no external mutex is supplied (standalone
//! construction, e.g. the decode tests) an embedded `owned_mutex` is used.
//!
//! The DECODE path (`handleFrame`, driven off `FrameReader`) is unit-testable
//! WITHOUT a live socket (see `client_difftest.zig`'s fidelity fixtures). The
//! SEND/connect/read-thread paths (`threadEnter` / `threadExit` / `queueWrite`
//! / `resize` / `focusGained`) are also REAL and are now exercised over a real
//! AF_UNIX socket by `client_difftest.zig`'s lifecycle tests: T1
//! (`connectAndAttach` -> `threadExit` leaks no fd), T2/T3 (forced
//! connect-/Attach-send failure unwind cleanly), and the Resize wire-fidelity
//! test (`connectAndAttach` + `resize`, asserting the host reconstruction of
//! the emitted Resize frame == the source `Size`) — all driven against a
//! capturing `TestListener` plus the blocking read thread. They reuse the same
//! xev write-side plumbing as `Exec` (an `xev.Stream` over the connected
//! AF_UNIX fd on `td.loop`, with a `SegmentedPool`-backed write request/buffer
//! pool) plus a blocking read thread that drives the FrameReader, symmetric
//! with `Exec.ReadThread`.
const Client = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const posix = std.posix;
const xev = @import("../global.zig").xev;
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const internal_os = @import("../os/main.zig");
const fastmem = @import("../fastmem.zig");
const SegmentedPool = @import("../datastruct/main.zig").SegmentedPool;
const ProcessInfo = @import("../pty.zig").ProcessInfo;

const render = @import("../terminal/render.zig");
const protocol = @import("../host/protocol.zig");
const HostRenderState = @import("../host/RenderState.zig");
const Snapshot = HostRenderState.Snapshot;
// GAP FIX: there is no `renderer.image.State`. `src/renderer.zig` exports an
// unrelated `State` (renderer/State.zig); the image `State` lives in
// renderer/image.zig and is only pulled into the renderer file-locally. The
// mirror slot must reference this path directly.
const imagepkg = @import("../renderer/image.zig");

const log = std.log.scoped(.io_client);

/// SLICE-3-BLOCKING: a clearly-invalid sentinel `PageList.Pin` for client
/// mirror rows. `render.RenderState.Row.pin` (render.zig:181) is a *List.Node
/// POINTER into the HOST's PageList — it CANNOT cross the wire and is
/// meaningless in the client mirror. We must NOT leave it `undefined`: copying
/// an undefined Pin is UB, and the row MultiArrayList copies row fields on
/// resize/shrink. Instead every mirror row gets this DEFINED, deliberately-bogus
/// pin. `garbage = true` marks it invalid in the source's own vocabulary
/// (PageList.zig:5129-5134), and `node` is a recognizable non-null sentinel so
/// any accidental deref (a Slice-3 regression) traps loudly at a known address
/// instead of wandering through wild memory. NOTHING in Slice 2 reads it; see
/// the SLICE-3-BLOCKING invariant on `rehydrate`.
const invalid_pin: terminal.PageList.Pin = .{
    .node = @ptrFromInt(0xdead_0000_dead_0000),
    .x = 0,
    .y = 0,
    .garbage = true,
};

/// The preallocation size for the write request pool. Must be a power of 2.
/// Mirrors `Exec`/`backend.zig`.
const WRITE_REQ_PREALLOC = std.math.pow(usize, 2, 5);

/// General-purpose allocator. Owns the mirror pools + reader buffer.
gpa: Allocator,

/// The attach/session configuration (socket path + optional session id).
config: Config,

// --- the draw-source mirror (Slice 3 will let the renderer read this) ---

/// Guards the three mirrors below.
///
/// SLICE 3d (lock-domain reconciliation): the mirrors (`render_state`,
/// `osc8_links`, plus `mode`/`child_exited`) are READ by the renderer's
/// `updateFrame` under the renderer-state mutex (`renderer.State.mutex`, a
/// heap-owned `*std.Thread.Mutex` created in `Surface.init`) and WRITTEN by the
/// read thread in `handleFrame`. To make those two the SAME lock, the Client
/// guards every write through `renderMutex()`, which returns either an
/// externally-supplied renderer-state mutex (`render_mutex`, set via
/// `Config.render_mutex` or `setRenderMutex`) or, absent one, `&owned_mutex`.
///
/// POINTER-LIFETIME SAFETY: `render_mutex` is left `null` by `init()` (which
/// returns a `Client` BY VALUE — taking `&self.owned_mutex` there would dangle
/// once the value is moved to its final home). It is resolved in `renderMutex()`
/// (by which point the Client is always behind a stable `*Client`), or set
/// eagerly by `setRenderMutex` / `initTerminal` once the Client is at its final
/// address. The owned fallback pointer is therefore only ever taken on a Client
/// that already has its final address — never on the by-value `init()` return.
///
/// SINGLE-WRITER RESOLUTION (finding 3d-lifetime-1): `renderMutex()` resolves
/// the field with a plain (non-atomic) write, so it must NOT be the first caller
/// from two threads at once. `connectAndAttach` forces resolution
/// (`_ = self.renderMutex();`) once, while still single-threaded, BEFORE spawning
/// the read thread, so every later caller (`handleFrame` on the read thread,
/// `childExitedAbnormally`) sees an already-resolved field and only reads it.
/// The lazy path in `renderMutex()` is thus only ever hit pre-spawn (or in
/// single-threaded standalone/decode tests) — it is NOT relied upon to be
/// race-free under concurrency.
owned_mutex: std.Thread.Mutex = .{},

/// The effective guard pointer. `null` until first resolved by `renderMutex()`
/// (or set by `setRenderMutex`). Points at either an external renderer-state
/// mutex (shared with the renderer) or at `&self.owned_mutex`. See the
/// pointer-lifetime note on `owned_mutex`.
render_mutex: ?*std.Thread.Mutex = null,

/// The rehydrated `terminal.RenderState` mirror — the draw source. Populated
/// by `rehydrate` from decoded GridFrames.
render_state: render.RenderState = .empty,

/// The flat input-mode mirror, updated wholesale from each ModeFrame.
mode: protocol.ModeFrame = .{ .session_id = 0 },

/// --- Slice 3c: host-computed OSC8 hover links ---
///
/// The current OSC8 link-cell set, decoded from the most recent LinkFrame. The
/// host computes this (its pins are live) and ships the coordinate set; the
/// GUI renderer reads it INSTEAD of `RenderState.linkCells` under `.client`
/// (the mirror's pins are poisoned). Regex links are NOT here — they stay
/// GUI-side via `Set.renderCellMap` against the mirror cell text. Held under
/// `mutex` like `render_state`. Owned by this Client (freed in deinit).
osc8_links: render.RenderState.CellSet = .empty,

/// The renderer image-state mirror slot. Stays `.empty` this slice (no
/// ImageFrame channel until Phase 3); exists so Slice 3 has the slot.
images: imagepkg.State = .empty,

// --- session / liveness state recorded from frames ---

/// Set on `.attached`; 0 = not yet attached.
///
/// CONCURRENCY (finding #4): this field is touched by two threads — the read
/// thread WRITES it in `handleFrame` (`.attached`), and the IO thread READS it
/// UNLOCKED on the input hot path (`queueWrite`/`focusGained`). It is therefore
/// an `std.atomic.Value(u64)` (NOT a plain `u64`) so the two sides never race
/// at the type level; a plain field would be UB regardless of any lock the
/// writer happens to hold, because the readers are deliberately lock-free.
/// The happens-before is store-release (writer) -> load-acquire (readers):
///   - WRITER: `session_id.store(id, .release)` in `handleFrame` (also under
///     `mutex`, but the readers do NOT take `mutex`, so the release/acquire
///     pair — not the lock — is what synchronizes them).
///   - READERS: `session_id.load(.acquire)` in `queueWrite`/`focusGained`,
///     with NO lock held.
/// Taking the heavy `mutex` (held during full `rehydrate`) per keystroke is
/// undesirable, so this lock-free acquire/release pair synchronizes the two
/// sides instead. 0 is a safe "unattached" sentinel because host session ids
/// start at 1 (`src/host/Server.zig` `next_session_id = 1`).
session_id: std.atomic.Value(u64) = .init(0),

/// Set on `.child_exited`.
child_exited: ?ChildExited = null,

// --- last-known sizes so the first Resize after Attach is correct ---
grid_size: renderer.GridSize = .{},
screen_size: renderer.ScreenSize = .{ .width = 0, .height = 0 },

// --- wire plumbing (only meaningful once threadEnter connects) ---

/// Reassembles complete frames from arbitrary partial socket reads. Reused
/// GUI-side exactly as the host uses it.
reader: protocol.FrameReader = .{},

/// The connected AF_UNIX fd, set by `threadEnter`. Owned by `threadExit`
/// (closed there).
socket_fd: ?posix.fd_t = null,

pub const ChildExited = struct {
    exit_code: u32,
    runtime_ms: u64,
};

/// Configuration for the client backend: how to reach the ptyhost.
pub const Config = struct {
    /// AF_UNIX socket path of the ptyhost. The caller's slice is borrowed only
    /// for the duration of `init`, which DUPES it into Client-owned memory (see
    /// `init`/`deinit`); the stored copy in `Client.config.socket_path` is owned
    /// by the Client and freed in `deinit`. This duping is required because the
    /// IO/read thread reads `socket_path` later (in `connectAndAttach` ->
    /// `connectUnix`), long after the borrowed source (e.g. a conditional-state
    /// config clone in `Surface.init`) may have been freed — without the dupe
    /// that is a use-after-free.
    socket_path: []const u8 = &.{},

    /// If non-null, attach to this existing session; otherwise spawn a fresh
    /// one (Attach.session_id == null).
    session_id: ?u64 = null,

    /// SLICE 3d: the renderer-state mutex (`renderer.State.mutex`) the GUI
    /// renderer reads the mirror under. When supplied, the Client guards its
    /// mirror writes under THIS same lock, reconciling the writer/reader lock
    /// domains (see the `owned_mutex` field). Heap-owned by `Surface.init` and
    /// outlives the Client. `null` => the Client uses its embedded
    /// `owned_mutex` instead (standalone construction / decode tests). Plumbed
    /// from `Surface.init`; only exercised once Slice 4 selects `.client`.
    render_mutex: ?*std.Thread.Mutex = null,
};

/// Initialize the client state. This will NOT connect; it only sets up the
/// internal state necessary to start it later (mirrors `Exec.init`).
///
/// OWNERSHIP: `cfg.socket_path` is borrowed only for the duration of this call.
/// We DUPE it into Client-owned memory (freed in `deinit`) so the stored copy
/// outlives the caller's slice. The borrowed slice in `Surface.init` is often a
/// conditional-state config clone freed when `Surface.init` returns, while the
/// read thread reads `socket_path` LATER in `connectAndAttach`; storing the
/// borrowed slice by value would be a use-after-free (`.exec` dodges this by
/// duping its borrowed cwd in `Exec.init`). Duping empty (`&.{}`) is fine. The
/// dupe survives the by-value return — it is heap memory, not a pointer into
/// the returned `Client`.
pub fn init(alloc: Allocator, cfg: Config) !Client {
    const socket_path = try alloc.dupe(u8, cfg.socket_path);
    errdefer alloc.free(socket_path);

    var owned_cfg = cfg;
    owned_cfg.socket_path = socket_path;

    return .{
        .gpa = alloc,
        .config = owned_cfg,
    };
}

/// Return the effective guard mutex, resolving it on first use.
///
/// SLICE 3d: prefers an externally-supplied renderer-state mutex
/// (`render_mutex`, from `Config.render_mutex` / `setRenderMutex`); falls back
/// to the embedded `owned_mutex`. The fallback address `&self.owned_mutex` is
/// only taken here, on a `*Client` that already has its final address — never
/// on the by-value `init()` return (see the `owned_mutex` field doc). All lock
/// sites go through this so writer and reader share one lock once an external
/// mutex is wired.
///
/// The first resolution performs a plain (non-atomic) field write, so it must
/// run single-threaded: `connectAndAttach` forces it before the read thread is
/// spawned (finding 3d-lifetime-1). All later concurrent callers hit the
/// already-resolved fast path and only read.
fn renderMutex(self: *Client) *std.Thread.Mutex {
    if (self.render_mutex) |m| return m;
    // Prefer a config-supplied external mutex; otherwise fall back to the
    // embedded owned mutex. Resolved lazily here (rather than in `init`, which
    // returns by value) so `&self.owned_mutex` is only ever taken on a stable
    // `*Client` — never on the by-value `init()` return (no dangling pointer).
    const m = self.config.render_mutex orelse &self.owned_mutex;
    self.render_mutex = m;
    return m;
}

/// Set the external renderer-state mutex the Client guards its mirror under
/// (Slice 3d). Must be called with the Client at its FINAL address (the backend
/// union slot, after `Termio.init` has moved it in) and BEFORE the read thread
/// is spawned (`threadEnter`/`connectAndAttach`), so the very first
/// `handleFrame` already locks the shared mutex. Idempotent re-points are fine
/// as long as no lock is currently held through the old pointer.
pub fn setRenderMutex(self: *Client, m: *std.Thread.Mutex) void {
    self.render_mutex = m;
}

pub fn deinit(self: *Client) void {
    self.render_state.deinit(self.gpa);
    self.images.deinit(self.gpa);
    self.osc8_links.deinit(self.gpa);
    self.reader.deinit(self.gpa);
    // `config.socket_path` is OWNED (duped from the caller's borrowed slice in
    // `init`); free it here. Freeing the empty-default dupe (`&.{}` -> a
    // zero-length owned slice) is safe. `mode` is POD; the remaining `config`
    // fields hold no owned heap memory.
    self.gpa.free(self.config.socket_path);
}

/// Call to initialize the terminal state as necessary for this backend.
/// Mirrors `Exec.initTerminal`'s grid/screen seeding; there is no subprocess
/// pwd to set on the client side (the host owns the child).
pub fn initTerminal(self: *Client, term: *terminal.Terminal) void {
    self.grid_size = .{ .columns = term.cols, .rows = term.rows };
    self.screen_size = .{ .width = term.width_px, .height = term.height_px };

    // SLICE 3d: seed the shared guard mutex from the config-supplied
    // renderer-state mutex, if any. Safe to set here even though `initTerminal`
    // runs on the pre-move backend copy in `Termio.init`: `render_mutex` is an
    // EXTERNAL pointer (heap-owned by Surface), not into `self`, so it survives
    // the union move into the final backend slot. The owned fallback is NOT
    // taken here (that would dangle across the move); it is resolved lazily by
    // `renderMutex()` on the final-address `*Client` when no external mutex is
    // supplied.
    if (self.config.render_mutex) |m| self.render_mutex = m;
}

pub fn threadEnter(
    self: *Client,
    alloc: Allocator,
    io: *termio.Termio,
    td: *termio.Termio.ThreadData,
) !void {
    // `alloc` is unused here (the host owns the subprocess; we only connect a
    // socket). The write/buffer pools allocate lazily via td.alloc in
    // sendFrame. `io` is forwarded to the read thread for crash metadata.
    _ = alloc;

    // Thin wrapper over the narrow lifecycle helper. We forward only what the
    // helper actually touches — `td.alloc` (the pool allocator), `td.loop` (the
    // xev loop the write stream queues onto), and `&td.backend.client` (the
    // backend slot it installs into). Narrowing the parameter surface (vs.
    // passing the full `*Termio.ThreadData`) lets the lifecycle/error-unwind be
    // unit-tested with a stack `ThreadData` + a built (un-run) `xev.Loop`,
    // without standing up a renderer state / mailboxes / running loop. See the
    // T2 (connect-failure) and T3 (forced Attach-send-failure, finding #2)
    // regression tests in `client_difftest.zig`.
    td.backend = .{ .client = undefined };
    try self.connectAndAttach(td.alloc, td.loop, &td.backend.client, io);
}

/// The full connect -> pipe -> stream -> install -> Attach -> spawn lifecycle,
/// extracted from `threadEnter` so its error-unwind (finding #2) is unit
/// testable in isolation. The body is verbatim from the prior inline
/// `threadEnter`; only the parameter surface is narrowed:
///   - `alloc`  — the pool allocator (was `td.alloc`).
///   - `loop`   — the xev loop the write stream queues onto (was `td.loop`).
///   - `client_td` — the backend slot this installs the lifecycle state into
///     (was `&td.backend.client`). The caller must have already tagged the
///     union as `.client` (its contents are written here).
///   - `io`     — forwarded to the read thread for crash metadata.
///
/// On ANY error this returns with NO live thread and every fd it opened closed
/// exactly once (the fd/pipe[0]/pipe[1]/stream/pool errdefers below), because
/// the only thread spawn is the LAST fallible step. See finding #2.
///
/// `pub` only so the lifecycle regression tests (`client_difftest.zig`
/// T1/T2/T3) can drive it with a stack `ThreadData` + an un-run `xev.Loop`;
/// production callers go through `threadEnter`. T3 forces the Attach send to
/// fail (FailingAllocator on this `alloc`) to exercise the post-pipe/pre-spawn
/// unwind this reordering establishes.
pub fn connectAndAttach(
    self: *Client,
    alloc: Allocator,
    loop: *xev.Loop,
    client_td: *ThreadData,
    io: *termio.Termio,
) !void {
    // Connect to the ptyhost over AF_UNIX SOCK_STREAM.
    const fd = try connectUnix(self.config.socket_path);
    errdefer posix.close(fd);
    self.socket_fd = fd;

    // Create our quit pipe for the read thread (pipe[0]=read, pipe[1]=write).
    const pipe = try internal_os.pipe();
    errdefer posix.close(pipe[0]);
    errdefer posix.close(pipe[1]);

    // Setup our write stream over the connected socket.
    var stream = xev.Stream.initFd(fd);
    errdefer stream.deinit();

    // Install our thread-local backend state. `read_thread` is left undefined
    // for now: the read thread is spawned LAST (after the fallible Attach send)
    // so that no error path tears down fd/pipe/stream while a live, unjoined
    // thread is touching them. `sendFrameRaw` below only reaches through
    // `client_td.{write_stream,write_*_pool,write_queue}` + `loop` + `alloc`,
    // so it does not need `read_thread`.
    client_td.* = .{
        .write_stream = stream,
        .read_thread = undefined,
        .read_thread_pipe = pipe[1],
        .read_thread_fd = fd,
    };

    // OOM-LEAK FIX: the write_req_pool / write_buf_pool live inside
    // client_td and are normally freed by ThreadData.deinit. But that
    // deinit is only armed by `defer cb.data.deinit()` in Thread.threadMain_
    // (Thread.zig:268), which is registered AFTER `try io.threadEnter(...)`
    // (Thread.zig:267) succeeds — so it does NOT run when threadEnter returns
    // an error. The very next step (the Attach sendFrame) is the first thing
    // that touches those pools: a `getGrow` that grows a pool's heap segments
    // and then fails on a LATER getGrow/encodeFrame would return an error from
    // threadEnter with the grown segments leaked. This errdefer frees exactly
    // (and ONLY) the two pools on any error from here on, mirroring the pool
    // half of ThreadData.deinit; it deliberately does NOT touch fd/pipe/stream
    // (each already covered by its own errdefer above) so there is no
    // double-close/double-deinit. The pools allocate from `alloc`, the same
    // allocator sendFrameRaw's getGrow uses, so this frees the right arena. On
    // the SUCCESS path this errdefer is disarmed and ThreadData.deinit owns the
    // pools as before — no double free.
    errdefer {
        client_td.write_req_pool.deinit(alloc);
        client_td.write_buf_pool.deinit(alloc);
    }

    // Send the Attach frame to (re)attach or spawn a session BEFORE spawning
    // the read thread. This is NOT a synchronous socket write: sendFrameRaw
    // (like sendFrame) only ENQUEUES the write on client_td's single-producer
    // write queue via queueWrite on `loop`; the actual socket write happens
    // asynchronously when the IO thread's xev loop runs (the loop is not
    // running yet — threadEnter has not returned). The guarantee we get is
    // ORDERING: the Attach is enqueued first, before the read-thread spawn and
    // before any later Input/Resize/Focus frame, so it is first in the write
    // queue and the host therefore observes it before any subsequent frame.
    // Doing it before the spawn also means a failed Attach unwinds via the
    // fd/pipe[0]/pipe[1]/stream errdefers above with NO live thread touching
    // any fd (no race, no double-close).
    try sendFrameRaw(client_td, loop, alloc, .attach, protocol.Attach{
        .session_id = self.config.session_id,
    });

    // SLICE 3d (finding 3d-lifetime-1): RESOLVE the effective guard mutex now,
    // while still single-threaded, BEFORE the read thread exists. `renderMutex()`
    // resolves `render_mutex` lazily with a plain (non-atomic) field write; if
    // that first write happened concurrently from the read thread (`handleFrame`)
    // and another thread (`childExitedAbnormally`), it would be a data race on
    // the field — benign by outcome (both compute the same pointer) but still UB.
    // Forcing resolution here, before any concurrent caller can exist, guarantees
    // the field is already set by the time those callers run, so they hit the
    // `if (self.render_mutex) |m| return m;` fast path and never write. (When an
    // external mutex was supplied via Config/setRenderMutex it is already set, so
    // this is a no-op then; this matters for the owned-fallback path.)
    _ = self.renderMutex();

    // Spawn the blocking read thread that drives the FrameReader. This is the
    // last fallible step; if it fails, the fd/pipe/stream errdefers above run
    // and (since no thread was created) close each fd exactly once.
    //
    // Note: with Attach sent above, a failed spawn leaves a brief "half-attach"
    // window — the host has accepted the Attach but our client is torn down.
    // Acceptable for Slice 2: the host sees the connection drop and reaps the
    // session; no GUI state survives. Slice 3 should be aware of this window.
    const read_thread = try std.Thread.spawn(
        .{},
        ReadThread.threadMainPosix,
        .{ self, fd, io, pipe[0] },
    );
    client_td.read_thread = read_thread;
    read_thread.setName("io-client-reader") catch {};
}

pub fn threadExit(self: *Client, td: *termio.Termio.ThreadData) void {
    _ = self;
    std.debug.assert(td.backend == .client);
    const client = &td.backend.client;

    // Tell the read thread to quit. BrokenPipe means it already closed, which
    // is exactly what we wanted.
    _ = posix.write(client.read_thread_pipe, "x") catch |err| switch (err) {
        error.BrokenPipe => {},
        else => log.warn(
            "error writing to read thread quit pipe err={}",
            .{err},
        ),
    };

    client.read_thread.join();

    // Close the socket fd. The write_stream wraps the same fd; we close it
    // exactly once here (write_stream.deinit in ThreadData.deinit does not
    // close on this xev backend's Stream — see Exec, which closes the pty fds
    // via the subprocess, not the stream). Closing the connected socket tears
    // down our side of the connection.
    posix.close(client.read_thread_fd);
}

pub fn focusGained(
    self: *Client,
    td: *termio.Termio.ThreadData,
    focused: bool,
) !void {
    try self.sendFrame(td, .focus, protocol.Focus{
        .session_id = self.session_id.load(.acquire),
        .focused = focused,
    });
}

pub fn resize(
    self: *Client,
    td: *termio.Termio.ThreadData,
    size: renderer.Size,
) !void {
    // Record the latest known sizes (mirror state), then send a real Resize
    // frame on the write stream using `td` — same pattern as queueWrite /
    // focusGained, and session_id read via the same unlocked atomic load.
    const grid_size = size.grid();
    self.grid_size = grid_size;
    self.screen_size = size.terminal();

    // CAUTION: screen_w/screen_h carry the FULL padded screen (size.screen),
    // NOT size.terminal(). size.terminal() is screen.subPadding(padding) —
    // already padding-stripped — and the host reconstructs a renderer.Size by
    // setting .screen = {screen_w, screen_h} and re-deriving grid/terminal via
    // subPadding. Sending the padding-removed value alongside the padding_*
    // fields would subtract padding twice, yielding a too-small grid/terminal
    // on every resize with nonzero padding. size.screen round-trips exactly.
    try self.sendFrame(td, .resize, protocol.Resize{
        .session_id = self.session_id.load(.acquire),
        .cols = grid_size.columns,
        .rows = grid_size.rows,
        .cell_width = size.cell.width,
        .cell_height = size.cell.height,
        .padding_l = size.padding.left,
        .padding_r = size.padding.right,
        .padding_t = size.padding.top,
        .padding_b = size.padding.bottom,
        .screen_w = size.screen.width,
        .screen_h = size.screen.height,
    });
}

pub fn queueWrite(
    self: *Client,
    alloc: Allocator,
    td: *termio.Termio.ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    _ = alloc;
    // One Input frame per call carries the whole buffer; the host applies it
    // to the session's write mailbox. Chunking is a possible optimization but
    // not required for correctness.
    try self.sendFrame(td, .input, protocol.Input{
        .session_id = self.session_id.load(.acquire),
        .linefeed = linefeed,
        .bytes = data,
    });
}

pub fn childExitedAbnormally(
    self: *Client,
    gpa: Allocator,
    t: *terminal.Terminal,
    exit_code: u32,
    runtime_ms: u64,
) !void {
    _ = gpa;
    _ = t;
    const m = self.renderMutex();
    m.lock();
    defer m.unlock();
    self.child_exited = .{ .exit_code = exit_code, .runtime_ms = runtime_ms };
}

/// Get information about the process(es) attached to the backend.
///
/// The client does not own a local process (the host does), so this always
/// returns `null` ("not available"), an explicitly supported result.
pub fn getProcessInfo(self: *Client, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
    _ = self;
    return null;
}

// --- DECODE entry point (unit-testable, NO socket) ---

/// Handle one decoded frame: dispatch on the tag and fold it into the mirror
/// state. Held under `renderMutex()` — the SAME `*std.Thread.Mutex` Slice 3's
/// renderer reads the mirror under (Slice 3d lock-domain reconciliation), or
/// the embedded `owned_mutex` when no external mutex was supplied. `alloc` is
/// used for any per-frame decode allocations and for the rehydrated
/// RenderState's owned memory.
pub fn handleFrame(
    self: *Client,
    alloc: Allocator,
    tag: protocol.FrameType,
    payload: []const u8,
) !void {
    const m = self.renderMutex();
    m.lock();
    defer m.unlock();

    switch (tag) {
        .grid_frame => {
            // decode sets owns_snapshot=true; the Snapshot's pools are freed
            // by gf.deinit. rehydrate dupes what the mirror keeps into its own
            // per-row arenas / general-alloc cell lists.
            var gf = try protocol.GridFrame.decode(alloc, payload);
            defer gf.deinit(alloc);
            try self.rehydrate(alloc, gf.snapshot);
        },

        .mode_frame => {
            // POD; replace the mirror wholesale.
            self.mode = try protocol.ModeFrame.decode(alloc, payload);
        },

        .attached => {
            // Atomic store (even though we hold the guard mutex here): the
            // UNLOCKED IO-thread readers in queueWrite/focusGained synchronize
            // against this store, not against the mutex. Independent of the
            // Slice 3d shared-mutex change — the lock-free path is untouched.
            self.session_id.store(
                (try protocol.Attached.decode(alloc, payload)).session_id,
                .release,
            );
        },

        .child_exited => {
            const ce = try protocol.ChildExited.decode(alloc, payload);
            self.child_exited = .{
                .exit_code = ce.exit_code,
                .runtime_ms = ce.runtime_ms,
            };
        },

        .link_frame => {
            // Replace the OSC8 link set wholesale. An empty `cells` clears it
            // (the host sends empty when there is no link / the mods aren't
            // held / present=false). Rebuild into a fresh map so a shrinking
            // set drops stale coords. Keys are stored in `self.gpa` (the
            // Client owns them; freed in deinit / on the next replace).
            var lf = try protocol.LinkFrame.decode(alloc, payload);
            defer lf.deinit(alloc);
            self.osc8_links.clearRetainingCapacity();
            try self.osc8_links.ensureUnusedCapacity(self.gpa, lf.cells.len);
            for (lf.cells) |c| {
                self.osc8_links.putAssumeCapacity(.{ .x = c.x, .y = c.y }, {});
            }
        },

        // Everything else is either a request-direction frame (the GUI sends
        // these, never receives them) or a liveness frame we don't model yet.
        else => log.debug("client ignoring frame tag={}", .{tag}),
    }
}

/// Rehydrate a `terminal.Style` from a host-side `StylePod` projection — the
/// inverse of `StylePod.fromStyle`. Lives here (GUI side) rather than on the
/// host `StylePod` so the host file (`src/host/RenderState.zig`) stays
/// untouched: the Snapshot owns the serialize/diff direction; the Client owns
/// the rehydrate direction. `StylePod`'s fields (the per-color tag/palette/rgb
/// projection + the 8 bool flags + the u8 underline enum index) are all public,
/// so this reads them directly. Each `Color` maps back to the source
/// `terminal.Style.Color` union by tag; `.none` ignores the (unused) payload so
/// it round-trips exactly with `fromColor`. The private `_padding` of Flags is
/// the only non-projected bit and is always zero on a real Style, so
/// `rehydrateStyle(StylePod.fromStyle(s))` reproduces every field `Style.eql`
/// compares (fg/bg/underline Color + the 16-bit Flags).
fn rehydrateColor(c: HostRenderState.StylePod.Color) terminal.Style.Color {
    return switch (c.tag) {
        .none => .none,
        .palette => .{ .palette = c.palette },
        .rgb => .{ .rgb = c.rgb },
    };
}

fn rehydrateStyle(pod: HostRenderState.StylePod) terminal.Style {
    return .{
        .fg_color = rehydrateColor(pod.fg_color),
        .bg_color = rehydrateColor(pod.bg_color),
        .underline_color = rehydrateColor(pod.underline_color),
        .flags = .{
            .bold = pod.bold,
            .italic = pod.italic,
            .faint = pod.faint,
            .blink = pod.blink,
            .inverse = pod.inverse,
            .invisible = pod.invisible,
            .strikethrough = pod.strikethrough,
            .overline = pod.overline,
            .underline = @enumFromInt(pod.underline),
        },
    };
}

/// Rehydrate a decoded `Snapshot` into `self.render_state` — the inverse of
/// `Snapshot.fromRenderState`. Writes the Snapshot's pointer-free fields back
/// into a `terminal.RenderState`, populating the per-row MultiArrayList rows
/// exactly the way `render.RenderState.update` does (per-row arena
/// promote/reset; cells via the GENERAL allocator; graphemes arena-duped;
/// highlights via the general allocator).
///
/// Caller MUST hold the guard returned by `renderMutex()` (handleFrame does).
///
/// ⚠️ SLICE-3-BLOCKING INVARIANT — client mirror pins are INVALID.
/// `render.RenderState.Row.pin` (PageList.Pin, render.zig:181) is a
/// *List.Node pointer into the HOST's PageList; it does not and cannot cross
/// the wire, so every mirror row's pin is the deliberately-bogus `invalid_pin`
/// sentinel (`garbage = true`, node = 0xdead…). The renderer READS pin in two
/// paths — `RenderState.linkCells` (render.zig:808, via generic.zig:1256 on
/// ctrl/super OSC8-hover, `row_pins[vp.y].node.data`) and
/// `RenderState.updateHighlightsFlattened` (render.zig:658, via
/// generic.zig:1319/1330 on search highlights, reads `row_pin.node`/`.y`) —
/// and dereferences `pin.node`. Feeding THIS mirror to either path is a
/// guaranteed wild-pointer crash. Slice 3 MUST make both paths client-safe
/// (host-compute the OSC8 link-cell set + search highlights per the Phase-3
/// plan, or disable them under the .client backend) BEFORE wiring the renderer
/// to this mirror. Do NOT relax this without doing that.
///
/// PARTIAL/MERGE note: `Snapshot.deserialize` reconstructs non-listed rows
/// BLANK on `.partial`/`.false` frames. Slice 2's host only ever emits `.full`
/// (RenderState.zig capture builds a fresh `.empty` RenderState so `update`
/// always forces `dirty == .full`), so we treat the snapshot as a wholesale
/// replacement here. A FUTURE `.partial` frame MUST be MERGED over the prior
/// mirror (per the deserialize contract), never blindly replaced — deferred
/// with the host's partial-emit work.
fn rehydrate(self: *Client, alloc: Allocator, snap: Snapshot) !void {
    const rs = &self.render_state;

    // Scalars / colors / cursor — all POD on both sides.
    rs.rows = snap.rows;
    rs.cols = snap.cols;
    rs.dirty = snap.dirty;

    // `screen` is not on the wire (a documented Slice-2 gap; the Slice-3
    // renderer does not read rs.screen). Leave it as-is. viewport_pin /
    // selection_cache stay null (Pin is deliberately stripped).
    rs.viewport_pin = null;
    rs.selection_cache = null;

    rs.colors = .{
        .background = snap.background,
        .foreground = snap.foreground,
        .cursor = snap.cursor_color,
        .palette = snap.palette,
    };

    rs.cursor.active = .{ .x = snap.cursor_x, .y = snap.cursor_y };
    rs.cursor.cell = snap.cursor_cell;
    rs.cursor.visible = snap.cursor_visible;
    rs.cursor.blinking = snap.cursor_blinking;
    rs.cursor.password_input = snap.cursor_password_input;
    rs.cursor.visual_style = snap.cursor_visual_style;
    rs.cursor.viewport = if (snap.cursor_viewport) |v| .{
        .x = v.x,
        .y = v.y,
        .wide_tail = v.wide_tail,
    } else null;
    // cursor.style is always valid post-update; fromRenderState always emits a
    // StylePod for the cursor, so this always round-trips.
    rs.cursor.style = rehydrateStyle(snap.cursor_style);

    // --- Rows / cells (the only managed memory). ---

    // Resize the row MultiArrayList to match, init-ing any NEW rows exactly
    // like render.zig:357-367 and deinit-ing dropped rows' arena+cells on
    // shrink (render.zig:368-379) to avoid leaks.
    if (rs.row_data.len != snap.rows) {
        if (rs.row_data.len < snap.rows) {
            const old_len = rs.row_data.len;
            try rs.row_data.resize(alloc, snap.rows);
            var slice = rs.row_data.slice();
            for (old_len..snap.rows) |y| {
                slice.set(y, .{
                    .arena = .{},
                    // `pin` is a host pointer that never crosses the wire; seed
                    // it to the DEFINED `invalid_pin` sentinel (NOT undefined —
                    // the row list copies fields on resize/shrink, and copying
                    // undefined is UB). The per-row loop reasserts it each decode.
                    .pin = invalid_pin,
                    // `raw` IS on the wire and is overwritten unconditionally
                    // by the per-row loop below; init undefined here (the loop
                    // assigns it before any reader sees this row).
                    .raw = undefined,
                    .cells = .empty,
                    .dirty = true,
                    .selection = null,
                    .highlights = .empty,
                });
            }
        } else {
            const slice = rs.row_data.slice();
            for (
                slice.items(.arena)[snap.rows..],
                slice.items(.cells)[snap.rows..],
            ) |state, *cells| {
                var arena: ArenaAllocator = state.promote(alloc);
                arena.deinit();
                cells.deinit(alloc);
            }
            rs.row_data.shrinkRetainingCapacity(snap.rows);
        }
    }

    const row_data = rs.row_data.slice();
    const row_arenas = row_data.items(.arena);
    const row_cells = row_data.items(.cells);
    const row_dirties = row_data.items(.dirty);
    const row_sels = row_data.items(.selection);
    const row_highlights = row_data.items(.highlights);
    const row_raws = row_data.items(.raw);
    const row_pins = row_data.items(.pin);

    for (0..snap.rows) |y| {
        const src_row = snap.row_data[y];

        // Promote the per-row arena, reset it if it held prior content
        // (render.zig:465-471). `raw` IS on the wire (the Slice-3 renderer
        // reads its flag bits via row_data.items(.raw)) and is set from the
        // snapshot below. `pin` IS renderer-read (render.zig:808 linkCells,
        // render.zig:658 updateHighlightsFlattened) but is a *List.Node pointer
        // into the HOST's PageList — it cannot be serialized, so the mirror
        // holds the deliberately-invalid `invalid_pin` sentinel (set below).
        // See the SLICE-3-BLOCKING invariant on this function.
        var arena = row_arenas[y].promote(alloc);
        defer row_arenas[y] = arena.state;
        // On row REUSE, reset the per-row arena AND discard the stale
        // arena-backed selection/highlights handles (render.zig:469-474). The
        // highlights ArrayList was appended from this arena on the prior
        // decode, so after arena.reset(.retain_capacity) its backing buffer is
        // logically freed and the arena will hand that same region back out to
        // the next arena allocation (e.g. the grapheme dupes below). Setting it
        // to .empty drops the dangling capacity so the rebuild reallocates
        // fresh; clearRetainingCapacity would retain the stale pointer and
        // alias the grapheme dupes -> silent corruption on frame 2+.
        if (row_cells[y].len > 0) {
            _ = arena.reset(.retain_capacity);
            row_sels[y] = null;
            row_highlights[y] = .empty;
        }
        const arena_alloc = arena.allocator();

        // Cells use the GENERAL allocator (render.zig:484-492), NOT the arena.
        const cells = &row_cells[y];
        try cells.resize(alloc, snap.cols);
        const cells_slice = cells.slice();
        const cells_raw = cells_slice.items(.raw);
        const cells_grapheme = cells_slice.items(.grapheme);
        const cells_style = cells_slice.items(.style);

        for (0..snap.cols) |x| {
            const src = src_row.cells[x];
            cells_raw[x] = src.raw;
            // Write style even for default cells (the field is only meaningful
            // for populated cells per render.zig:222, but writing the
            // all-default rehydrateStyle is harmless and keeps it never-undefined).
            cells_style[x] = rehydrateStyle(src.style);
            if (src.raw.content_tag == .codepoint_grapheme) {
                cells_grapheme[x] = try arena_alloc.dupe(u21, src.grapheme);
            }
        }

        row_dirties[y] = src_row.dirty;
        row_sels[y] = if (src_row.selection) |s| .{ s[0], s[1] } else null;
        // The raw page.Row (flag bits the Slice-3 renderer reads). Carried on
        // the wire as of Slice 2's row.raw fix; overwrites the undefined left
        // by the grow branch / prior decode.
        row_raws[y] = src_row.raw;
        // `pin` is a host pointer; never valid in the mirror. Reassert the
        // invalid sentinel every decode so REUSED rows can't keep a stale prior
        // value. See the SLICE-3-BLOCKING invariant on this function.
        row_pins[y] = invalid_pin;

        // Highlights MUST be allocated from the per-row arena: RenderState.deinit
        // (render.zig:247-256) frees row highlights ONLY via arena.deinit() — it
        // never calls highlights.deinit(alloc) — so the general allocator would
        // leak. render.zig's updateHighlightsFlattened appends from the same
        // per-row arena. The list was reset to .empty above on row reuse, so this
        // append always allocates fresh from the post-reset arena.
        for (src_row.highlights) |h| {
            try row_highlights[y].append(arena_alloc, .{
                .tag = h.tag,
                .range = .{ h.range[0], h.range[1] },
            });
        }
    }

    // Cheap debug-gated guard documenting the SLICE-3-BLOCKING invariant at
    // runtime: every mirror row pin must be the invalid sentinel. Compiled out
    // entirely outside safety builds. O(rows), no allocation.
    if (std.debug.runtime_safety) {
        for (row_pins[0..snap.rows]) |p| {
            std.debug.assert(p.garbage);
            std.debug.assert(p.node == invalid_pin.node);
        }
    }
}

// --- SEND helpers ---

/// Encode `frame` (tag + payload) into a framed byte buffer and queue it onto
/// the write stream. The framed bytes are copied into the write-buffer pool
/// before queueing, so the transient encode buffer can be freed immediately.
fn sendFrame(
    self: *Client,
    td: *termio.Termio.ThreadData,
    tag: protocol.FrameType,
    frame: anytype,
) !void {
    _ = self;
    std.debug.assert(td.backend == .client);
    try sendFrameRaw(&td.backend.client, td.loop, td.alloc, tag, frame);
}

/// The actual encode + queue, narrowed to the fields it touches so the connect
/// lifecycle (and its tests) can call it without a full `*Termio.ThreadData`.
fn sendFrameRaw(
    client: *ThreadData,
    loop: *xev.Loop,
    alloc: Allocator,
    tag: protocol.FrameType,
    frame: anytype,
) !void {
    const framed = try protocol.encodeFrame(alloc, tag, frame);
    defer alloc.free(framed);

    // Chunk into pooled buffers exactly like Exec.queueWrite (without the
    // linefeed CR->CRLF rewrite, which is carried in the Input frame's
    // linefeed bit instead and applied host-side).
    var i: usize = 0;
    while (i < framed.len) {
        const req = try client.write_req_pool.getGrow(alloc);
        const buf = try client.write_buf_pool.getGrow(alloc);
        const max = @min(framed.len, i + buf.len);
        fastmem.copy(u8, buf, framed[i..max]);
        const slice = buf[0 .. max - i];
        i = max;

        client.write_stream.queueWrite(
            loop,
            &client.write_queue,
            req,
            .{ .slice = slice },
            ThreadData,
            client,
            writeCallback,
        );
    }
}

fn writeCallback(
    client_: ?*ThreadData,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.Stream,
    _: xev.WriteBuffer,
    r: xev.WriteError!usize,
) xev.CallbackAction {
    const client = client_.?;
    client.write_req_pool.put();
    client.write_buf_pool.put();
    _ = r catch |err| {
        log.err("client write error: {}", .{err});
        return .disarm;
    };
    return .disarm;
}

// --- connect helper ---

/// Connect to an AF_UNIX SOCK_STREAM socket at `path`. Returns the connected
/// fd. Caller owns the fd.
fn connectUnix(path: []const u8) !posix.fd_t {
    const fd = try posix.socket(
        posix.AF.UNIX,
        posix.SOCK.STREAM | posix.SOCK.CLOEXEC,
        0,
    );
    errdefer posix.close(fd);

    const addr = try std.net.Address.initUnix(path);
    try posix.connect(fd, &addr.any, addr.getOsSockLen());
    return fd;
}

// --- read thread ---

const ReadThread = struct {
    /// Blocking recv loop, symmetric with `Exec.ReadThread.threadMainPosix`.
    /// Reads from the socket, pushes bytes into the client's FrameReader, and
    /// drains complete frames through `handleFrame`. Polls the quit pipe so
    /// `threadExit` can stop it.
    fn threadMainPosix(
        client: *Client,
        fd: posix.fd_t,
        io: *termio.Termio,
        quit: posix.fd_t,
    ) void {
        _ = io;
        defer posix.close(quit);

        if (builtin.os.tag.isDarwin()) {
            internal_os.macos.pthread_setname_np(&"io-client-reader".*);
        }

        // Non-blocking so we can tight-loop reads and only poll the quit fd
        // when the socket would block.
        if (posix.fcntl(fd, posix.F.GETFL, 0)) |flags| {
            _ = posix.fcntl(
                fd,
                posix.F.SETFL,
                flags | @as(u32, @bitCast(posix.O{ .NONBLOCK = true })),
            ) catch {};
        } else |_| {}

        var pollfds: [2]posix.pollfd = .{
            .{ .fd = fd, .events = posix.POLL.IN, .revents = undefined },
            .{ .fd = quit, .events = posix.POLL.IN, .revents = undefined },
        };

        var buf: [1024]u8 = undefined;
        while (true) {
            while (true) {
                const n = posix.read(fd, &buf) catch |err| switch (err) {
                    error.NotOpenForReading, error.InputOutput => {
                        log.info("client reader exiting", .{});
                        return;
                    },
                    error.WouldBlock => break,
                    else => {
                        log.err("client reader error err={}", .{err});
                        return;
                    },
                };
                if (n == 0) break;

                // Push + drain complete frames into the mirror.
                client.reader.push(client.gpa, buf[0..n]) catch |err| {
                    log.err("client reader push failed err={}", .{err});
                    return;
                };
                while (true) {
                    const frame = client.reader.next(client.gpa) catch |err| {
                        log.err("client frame decode failed err={}", .{err});
                        return;
                    } orelse break;
                    client.handleFrame(
                        client.gpa,
                        frame.tag,
                        frame.payload,
                    ) catch |err| {
                        log.err("client handleFrame failed err={}", .{err});
                        return;
                    };
                }
            }

            _ = posix.poll(&pollfds, -1) catch |err| {
                log.warn("client reader poll failed, exiting err={}", .{err});
                return;
            };

            if (pollfds[1].revents & posix.POLL.IN != 0) return;
        }
    }
};

/// The thread local data for the client implementation. Mirrors
/// `Exec.ThreadData`'s write-side shape for the union arm.
pub const ThreadData = struct {
    /// The data stream is the main IO for the socket (write side).
    write_stream: xev.Stream,

    /// Pool of available write requests; put back when done.
    write_req_pool: SegmentedPool(xev.WriteRequest, WRITE_REQ_PREALLOC) = .{},

    /// Pool of available write buffers.
    write_buf_pool: SegmentedPool([64]u8, WRITE_REQ_PREALLOC) = .{},

    /// The write queue for the data stream.
    write_queue: xev.WriteQueue = .{},

    /// Reader thread state.
    read_thread: std.Thread,
    read_thread_pipe: posix.fd_t,
    read_thread_fd: posix.fd_t,

    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        // Close the quit-pipe write end (the read end, read_thread_fd, is
        // closed in threadExit alongside the reader-thread teardown). This
        // mirrors Exec.ThreadData.deinit, which closes its read_thread_pipe
        // here; without it each threadEnter->threadExit cycle leaks one fd.
        posix.close(self.read_thread_pipe);

        self.write_req_pool.deinit(alloc);
        self.write_buf_pool.deinit(alloc);
        self.write_stream.deinit();
    }
};
