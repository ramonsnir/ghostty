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
const apprt = @import("../apprt.zig");
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

/// Layer 2 (mirror role): poll cadence for the read loop. The mirror polls with a
/// FINITE timeout (not poll(-1)) so the loop stays responsive to the quit pipe and
/// can re-evaluate periodically; .attach uses poll(-1) unchanged.
///
/// SESSION-GONE DETECTION (corrected, vs. the prior silence-heuristic): the mirror
/// declares the session terminated ONLY on a GENUINE socket signal — EOF (the host
/// process died / the conn dropped) or a read error. It does NOT terminate on mere
/// frame SILENCE. The host suppresses grid/mode frames on an idle session (the
/// renderTick push-gate is `changed>0 || force_push || cursor_changed`) and does
/// NOT close the per-render-subscriber socket on session-gone (teardownEntry only
/// clears render_subscribers). A perfectly-alive agent sitting IDLE at a prompt —
/// the Agent Dashboard's PRIMARY target (an agent "waiting for input" emits no
/// output by definition) — therefore sends zero frames for arbitrarily long. A
/// silence timeout would mis-declare exactly that headline case as terminated.
/// Treating silence as death is wrong; only a genuine socket-level death is. On an
/// explicit host-side Close of a still-running host process (rare for the
/// dashboard's live-agent target) the socket stays open and the mirror keeps
/// showing the last frame — non-destructive (the mirror owns nothing real) and
/// re-derived on the model's next refresh. A host-side liveness/keepalive frame
/// that would also cover the keep-open-Close case cleanly is a Layer-3 followup
/// (it is an additive host protocol change, out of Layer-2 scope).
const MIRROR_POLL_TIMEOUT_MS: i32 = 1000;

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

/// The GUI renderer's wakeup, copied from `Termio.renderer_wakeup` in
/// `connectAndAttach`. After the read thread decodes a VISIBLE frame
/// (GridFrame / LinkFrame) into the mirror, it `notify()`s this so the renderer
/// thread draws PROMPTLY — exactly what `.exec` does via `queueRender`
/// (Termio.zig:504/542/618). Without it the renderer only redraws on a slow
/// fallback, which is the ~hundreds-of-ms input lag the first live smoke showed.
/// `null` under standalone construction (decode tests), where there is no
/// renderer to wake; the notify is then a no-op.
renderer_wakeup: ?xev.Async = null,

/// The surface mailbox, copied from `Termio.surface_mailbox` in `threadEnter`.
/// When the read thread decodes a `.child_exited` frame (the host detected the
/// child exit and sent a ChildExited protocol frame), it pushes a
/// `child_exited` `apprt.surface.Message` onto this mailbox so `Surface.childExited`
/// runs and the tab closes/shows-exited per `wait-after-command` — exactly what
/// `.exec` does from its IO thread (Exec.zig:291). Without it the `.client`
/// surface decodes+stores the exit but never delivers it, so the tab hangs.
/// `null` under standalone construction (decode/lifecycle tests, which bypass
/// `threadEnter`), where there is no surface to notify; the push is then a
/// no-op — same pattern as `renderer_wakeup`.
surface_mailbox: ?apprt.surface.Mailbox = null,

/// The flat input-mode mirror, updated wholesale from each ModeFrame.
mode: protocol.ModeFrame = .{ .session_id = 0 },

/// PHASE A (audit R2): the SAME local `terminal.Terminal` the GUI's
/// key/mouse/paste encode paths read input modes off of (`io.terminal` in
/// `Surface.zig`). Under `.client` that terminal is never fed VT, so its modes
/// would stay at defaults — vim/tmux/less arrows, mouse reporting, kitty
/// keyboard, keypad, bracketed paste, etc. all broken. The host ships the real
/// modes in a `ModeFrame`; `handleFrame`'s `.mode_frame` arm now APPLIES the
/// decoded modes onto THIS terminal (under the shared `renderMutex()`, the same
/// lock the encode reads take), so the encode paths read correct values. Set by
/// `setLocalTerminal` from `Surface.init` on the FINAL-address `*Client` (the
/// post-move backend slot) with `&self.io.terminal` — NOT by `initTerminal`,
/// which runs pre-move and would capture a dead stack address (see
/// `R2-DANGLING-TERMINAL`). `null` in standalone/decode tests that bypass it,
/// where the apply is a safe no-op. POINTER: owned by the Surface (the backend
/// reads it, never frees it), exactly like `Exec`'s relationship to
/// `io.terminal`.
local_terminal: ?*terminal.Terminal = null,

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
/// are random non-zero u64s (`allocSessionId` in `src/host/Server.zig`).
session_id: std.atomic.Value(u64) = .init(0),

/// Set on `.child_exited`.
child_exited: ?ChildExited = null,

/// Layer 2 (mirror role): set once when the mirror declares the session gone
/// (genuine EOF / read error on the socket — NOT a silence timeout). Guarded by
/// renderMutex(); idempotent fire-once (markMirrorEnded checks it). The renderer
/// does NOT read this in Layer 2 (it keeps drawing the frozen last frame); the
/// operative signal is the synthetic child_exited surface message markMirrorEnded
/// pushes. The flag/lock are forward-compatible for a Layer-3 renderer that draws
/// an explicit terminated overlay. Never set under .attach.
mirror_ended: bool = false,

/// Phase D: the host's authoritative at-prompt bit (cursorIsAtPrompt on its real
/// terminal), updated on every `.at_prompt` frame (pushed on change + seeded on
/// attach). A lock-free atomic so `Surface.needsConfirmQuit` can read it on the
/// apprt/main thread at close time without taking any lock. Defaults false =>
/// "not at a prompt" => confirm-close defaults to warning (the SAFE default
/// before the first frame arrives).
at_prompt: std.atomic.Value(bool) = .init(false),

// --- Slice B1: cached host selection text ---
//
// The host owns the real terminal + scrollback, so under .client the GUI's
// local terminal selection is meaningless. The host ships the current selection
// TEXT in a `selection_text` frame whenever its selection changes; we cache it
// here so ⌘C / copy_on_select / hasSelection can read it with NO sync round-trip.
// Both fields are guarded by `renderMutex()` (handleFrame holds it on write; the
// Surface read accessors take the renderer mutex, which IS this lock under
// .client). The selection HIGHLIGHT itself rides the grid_frame's row.selection;
// this cache is purely the copy/enablement text.
selection_text: std.ArrayListUnmanaged(u8) = .empty,
selection_present: bool = false,

// --- fork: host-resolved foreground process name + command (minor 3) ---
//
// Under .client the GUI mirror cannot read the foreground process locally (the
// PTY lives in the host). The host resolves the foreground process name + full
// command line from the foreground pid (libproc/sysctl) and pushes them in a
// `process_info` frame; we cache them here so a synchronous Surface getter
// (driven by the MCP `list_surfaces` poll) can read them with NO sync round-trip.
// Both fields are guarded by `renderMutex()` (handleFrame holds it on write; the
// Surface read accessors take the renderer mutex, which IS this lock under
// .client) — same discipline as `selection_text` above. Variable-length strings,
// so a guarded ArrayList rather than a lock-free atomic.
fg_process_name: std.ArrayListUnmanaged(u8) = .empty,
fg_command: std.ArrayListUnmanaged(u8) = .empty,
// fork (minor 4): the host's RAW foreground pid (tcgetpgrp leader), pushed via
// the `foreground_pid` frame, so the GUI can walk the process subtree locally
// and classify the agent. Lock-free atomic (a single u64; read in
// getProcessInfo without the guard mutex). 0 == no foreground process.
fg_pid: std.atomic.Value(u64) = .init(0),

/// fork: wall-clock ms (std.time.milliTimestamp) of the last APPLIED grid_frame
/// (a real screen change). Stamped ONLY in the `.grid_frame` arm — NOT on
/// pong/keepalive/mode/at_prompt/selection_text/etc., because the host suppresses
/// redundant idle frames and cursor blink is local, so a grid_frame's arrival IS
/// real activity. Read lock-free by `Surface.idleMillis` (the at_prompt pattern).
/// 0 = no frame applied yet (=> idle unknown). Coarse signal; ms granularity is
/// plenty for "seconds since the screen last changed". Wall-clock (not monotonic)
/// can step on an NTP slew, so `idleMillis` clamps a negative delta to 0 (see
/// there); a forward step transiently inflates idle — acceptable for a coarse
/// signal, and self-corrects on the next grid_frame.
///
/// COARSENESS / one-time resets: the Client sees only "a grid_frame arrived",
/// not the host's `changed` count, so a few NON-content frames also stamp here
/// and momentarily reset idle to ~0: (1) the host's reattach/spawn-fresh SEED
/// frame (`pushFullFrames`) on a GUI reattach, (2) a `force_push` on a mode/
/// alternate-screen flip, and (3) a `cursor_changed`-only push (e.g. an arrow
/// key moving the cursor with no cell change). All are one-time and self-
/// correcting (idle resumes growing from the next steady tick), and the field
/// is documented as a coarse "seconds since the screen last changed" signal, so
/// this is accepted rather than gating on `changed>0` (which the Client cannot
/// see — it would require a separate host signal). A GUI reattach therefore
/// shows idle ~0 briefly even if the session was long idle.
last_activity_ms: std.atomic.Value(i64) = .init(0),

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

    /// Layer 2 (Agent Dashboard): the backend ROLE (see `Role`). Default
    /// `.attach` keeps today's behavior byte-for-byte. `.mirror` makes this a
    /// read-only render mirror of `session_id` (which must then be non-null).
    /// A SCALAR copied by value through `init` and the backend-union move — no
    /// pointer hazard, no post-move pointer to recapture.
    role: Role = .attach,

    /// SLICE 11: spawn-opt working directory for a FRESH session (cwd-inherit,
    /// the `.client` analog of `.exec`'s `working_directory`). The caller's
    /// slice (e.g. `config.@"working-directory".value()` in `Surface.init`) is
    /// borrowed only for the duration of `init`, which DUPES it (when non-null)
    /// into Client-owned memory — EXACTLY like `socket_path` — because the read
    /// thread reads it LATER in `connectAndAttach` (to build the Attach frame),
    /// long after the borrowed source may have been freed. The stored copy is
    /// owned by the Client and freed in `deinit`. `null` => no cwd opt (the host
    /// uses its $HOME default, today's behavior). Only meaningful on a spawn
    /// (session_id == null); the host ignores it on reattach.
    working_directory: ?[]const u8 = null,

    /// Spawn-opt initial input for a FRESH session (the `.client` analog of the
    /// input `.exec` would feed via `Termio`'s ThreadEnterState). Carried in the
    /// Attach — NOT via a post-attach `.input` frame — because a fresh spawn's
    /// host-assigned session id isn't known until the `Attached` reply arrives,
    /// so an Input frame queued at threadEnter would carry session_id 0 and the
    /// host would drop it (the `new_tab_command` "no command" bug). The bytes are
    /// the escaped `.raw` form from the GUI's `config.input`; the host stores
    /// them back into its session config.input and un-escapes once on delivery.
    /// Borrowed for the duration of `init` (which DUPES it into Client-owned
    /// memory — same lifetime reasoning as socket_path/working_directory); the
    /// stored copy is freed in `deinit`. `null` => no initial input. Only
    /// meaningful on a spawn (session_id == null); the host ignores it on reattach.
    initial_input: ?[]const u8 = null,

    /// SLICE 3d: the renderer-state mutex (`renderer.State.mutex`) the GUI
    /// renderer reads the mirror under. When supplied, the Client guards its
    /// mirror writes under THIS same lock, reconciling the writer/reader lock
    /// domains (see the `owned_mutex` field). Heap-owned by `Surface.init` and
    /// outlives the Client. `null` => the Client uses its embedded
    /// `owned_mutex` instead (standalone construction / decode tests). Plumbed
    /// from `Surface.init`; only exercised once Slice 4 selects `.client`.
    render_mutex: ?*std.Thread.Mutex = null,
};

/// Forward-map a surface-config host session id (a `u64` carried from the
/// apprt `Surface.Options.session_id` through the apprt surface) into a
/// `Config.session_id` (the `?u64` the Client uses for its `Attach`):
/// 0 => null (spawn a FRESH host session, today's behavior), any non-zero
/// id => `Some(id)` (reattach to that existing host session). Host session
/// ids are random non-zero u64s (`allocSessionId` in `src/host/Server.zig`),
/// so 0 is a safe "none/fresh" sentinel. Single source of truth for this sentinel
/// mapping; `Surface.init` calls this when it builds the `.client` config.
pub fn sessionIdFromConfig(id: u64) ?u64 {
    return if (id == 0) null else id;
}

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

    // SLICE 11: dupe the optional spawn-opt cwd into Client-owned memory too
    // (same lifetime reasoning as socket_path — the read thread reads it later
    // in connectAndAttach). `null` stays null (no dupe, host default).
    const working_directory: ?[]const u8 = if (cfg.working_directory) |wd|
        try alloc.dupe(u8, wd)
    else
        null;
    errdefer if (working_directory) |wd| alloc.free(wd);

    // Dupe the optional spawn-opt initial input too (same lifetime reasoning as
    // working_directory — the read thread reads it later in connectAndAttach).
    const initial_input: ?[]const u8 = if (cfg.initial_input) |ii|
        try alloc.dupe(u8, ii)
    else
        null;
    errdefer if (initial_input) |ii| alloc.free(ii);

    var owned_cfg = cfg;
    owned_cfg.socket_path = socket_path;
    owned_cfg.working_directory = working_directory;
    owned_cfg.initial_input = initial_input;

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

/// (ramon fork / Agent Dashboard) The SOURCE host grid this mirror is rendering —
/// the cols/rows last decoded from a `grid_frame` into `render_state`, NOT the
/// frame-derived `grid_size` (which tracks the dashboard tile, not the host). Used
/// by the dashboard preview as a last-resort size when the REAL split's surfaceSize
/// is unavailable (the real split is hidden under a sibling's zoom, so it isn't
/// laid out). `null` for a non-mirror Client or before the first grid_frame
/// (render_state still `.empty`, rows/cols == 0). Read under `renderMutex()` (the
/// renderer-state mutex once reconciled) so it can't tear against the read thread's
/// `rehydrate`.
pub fn mirrorSourceGrid(self: *Client) ?MirrorGrid {
    if (self.config.role != .mirror) return null;
    const m = self.renderMutex();
    m.lock();
    defer m.unlock();
    const rs = &self.render_state;
    if (rs.cols == 0 or rs.rows == 0) return null;
    return .{ .cols = rs.cols, .rows = rs.rows };
}

/// (ramon fork) The mirror's source host grid — a NAMED struct so the Surface
/// forwarder and the C export share one type (anonymous structs aren't
/// cross-signature compatible in Zig).
pub const MirrorGrid = struct { cols: u16, rows: u16 };

/// Set the local terminal that `handleFrame`'s `.mode_frame` arm applies the
/// host's real input modes onto (Phase A / audit R2). MUST be called with the
/// Client at its FINAL address (the backend union slot, after `Termio.init`
/// has moved it in) and with `t` == the final `&io.terminal` — the EXACT
/// terminal the GUI encode paths read (`key_encode.Options.fromTerminal`,
/// `paste.Options.fromTerminal`, the mouse-reporting gates). Setting this from
/// `initTerminal` would capture the pre-move stack-local terminal address,
/// which dangles across `Termio.init`'s by-value move; this setter parallels
/// `setRenderMutex` and the mirror/link_cells re-pointing in `Surface.init`.
/// `null` (never called) leaves `handleFrame`'s apply a safe no-op.
pub fn setLocalTerminal(self: *Client, t: *terminal.Terminal) void {
    self.local_terminal = t;
}

pub fn deinit(self: *Client) void {
    self.render_state.deinit(self.gpa);
    self.images.deinit(self.gpa);
    self.osc8_links.deinit(self.gpa);
    self.selection_text.deinit(self.gpa);
    self.fg_process_name.deinit(self.gpa);
    self.fg_command.deinit(self.gpa);
    self.reader.deinit(self.gpa);
    // `config.socket_path` is OWNED (duped from the caller's borrowed slice in
    // `init`); free it here. Freeing the empty-default dupe (`&.{}` -> a
    // zero-length owned slice) is safe. `mode` is POD; the remaining `config`
    // fields hold no owned heap memory.
    self.gpa.free(self.config.socket_path);
    // SLICE 11: `config.working_directory` is OWNED when non-null (duped in
    // `init`); free it here. `null` (the default / no-cwd-opt case) frees
    // nothing.
    if (self.config.working_directory) |wd| self.gpa.free(wd);
    // `config.initial_input` is OWNED when non-null (duped in `init`); free it
    // here. `null` (the no-input default) frees nothing.
    if (self.config.initial_input) |ii| self.gpa.free(ii);
}

/// Call to initialize the terminal state as necessary for this backend.
/// Mirrors `Exec.initTerminal`'s grid/screen seeding; there is no subprocess
/// pwd to set on the client side (the host owns the child).
pub fn initTerminal(self: *Client, term: *terminal.Terminal) void {
    self.grid_size = .{ .columns = term.cols, .rows = term.rows };
    self.screen_size = .{ .width = term.width_px, .height = term.height_px };

    // PHASE A (audit R2): do NOT capture `term` here for `local_terminal`.
    // `initTerminal` runs on the PRE-MOVE backend copy inside `Termio.init`,
    // and `term` is the stack-local `var term` (Termio.zig:241) that
    // `Termio.init` then COPIES BY VALUE into `self.terminal` (Termio.zig:300,
    // a distinct FINAL address) before its stack frame is reclaimed. Capturing
    // `&term` here would store a dead pre-move stack address — both a no-op
    // against the terminal the encode paths actually read (`self.io.terminal`
    // == the final `&Termio.terminal`) AND a use-after-scope when written
    // through in `handleFrame`. Instead `local_terminal` is set from
    // `Surface.init` via `setLocalTerminal(&self.io.terminal)` on the
    // FINAL-address `*Client` (the backend union slot, after the move),
    // mirroring how the mirror/link_cells pointers are re-taken there. This is
    // the same lifetime hazard the author avoided for `render_mutex` below
    // (external pointer, survives the move) — `local_terminal` must point at
    // the final terminal, which only exists after the move.

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
    // Capture the GUI renderer's wakeup HERE (the real entry, where `io` is
    // valid) rather than in `connectAndAttach` — the lifecycle tests call
    // `connectAndAttach` directly with an `undefined` io (it historically
    // touched only `client_td`), so dereferencing io there would crash them.
    // Tests bypass threadEnter, leaving `renderer_wakeup` null => handleFrame's
    // notify is a no-op for them. The read thread (spawned in connectAndAttach)
    // notify()s this on each visible frame so the renderer draws promptly.
    self.renderer_wakeup = io.renderer_wakeup;

    // Capture the surface mailbox HERE too (same reasoning as renderer_wakeup:
    // `io` is valid only at the real entry; the lifecycle tests call
    // `connectAndAttach` directly with an `undefined` io). Tests bypass
    // threadEnter, leaving `surface_mailbox` null => handleFrame's child_exited
    // push is a no-op for them. On a real .client surface the read thread pushes
    // a `child_exited` apprt.surface.Message through this on the ChildExited
    // frame so Surface.childExited closes the tab (mirrors .exec / Exec.zig:291).
    self.surface_mailbox = io.surface_mailbox;

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
    // HANDSHAKE FIRST: the host rejects every stateful frame (including Attach)
    // until it receives a compatible-major Hello (Server's `handshaked` gate;
    // it closes the conn on "frame attach before Hello handshake"). Enqueue
    // Hello BEFORE Attach so it is ahead in the single-producer write queue and
    // the host observes the handshake first. `protocol.Hello{}` carries the
    // current PROTOCOL_VERSION_MAJOR/MINOR defaults; identity_bundle_id is left
    // empty (the host only gates on major-version compatibility) and is encoded
    // by value (no ownership transfer). Found by the first live ReleaseLocal
    // smoke — the socket integration test sent Hello-then-Attach, so it never
    // caught that connectAndAttach skipped the Hello.
    try sendFrameRaw(client_td, loop, alloc, .hello, protocol.Hello{});

    // Layer 2 (mirror role): a READ-ONLY render mirror SUBSCRIBE_RENDERs an
    // existing session instead of attaching. It NEVER sends Attach (which would
    // spawn/reattach + own the session). The Hello above is sent for BOTH roles;
    // ONLY the next frame differs. CRITICAL: do NOT early-return here — the
    // `_ = self.renderMutex();` resolution + read-thread spawn tail below MUST run
    // for both roles so `threadExit`'s join is valid.
    if (self.config.role == .mirror) {
        // session_id MUST be present (Surface only builds a mirror with a non-zero
        // id); if absent, log + send nothing (a no-op mirror), never spawn. Seed
        // the session_id atomic so ghostty_surface_session_id() is correct for the
        // mirror (no .attached reply arrives for a render-sub). Single-threaded
        // here (read thread not spawned yet), so the plain store is safe.
        if (self.config.session_id) |sid| {
            try sendFrameRaw(client_td, loop, alloc, .subscribe_render, protocol.SubscribeRender{
                .session_id = sid,
            });
            self.session_id.store(sid, .release);
        } else {
            log.warn("mirror role with no session_id; not subscribing (no-op mirror)", .{});
        }
    } else {
        // .attach (existing behavior, byte-for-byte):
        // SLICE 11: carry the spawn-opt cwd in the Attach. The host applies it only
        // on a fresh spawn (session_id == null) and ignores it on reattach; `null`
        // here preserves the host's $HOME default. `working_directory` is borrowed
        // by-reference into the frame for the encode — sendFrameRaw encodes
        // synchronously here on the IO thread before returning, and the slice is
        // Client-owned (duped in init), so no ownership transfer is needed.
        // initial_input rides the same Attach as a second spawn-opt: a fresh spawn's
        // host-assigned session id isn't known until the Attached reply, so a
        // post-attach `.input` frame would carry session_id 0 and be dropped. Same
        // borrow-by-reference-for-the-synchronous-encode reasoning as
        // working_directory (Client-owned, duped in init).
        try sendFrameRaw(client_td, loop, alloc, .attach, protocol.Attach{
            .session_id = self.config.session_id,
            .working_directory = self.config.working_directory,
            .initial_input = self.config.initial_input,
        });
    }

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
    // Layer 2 (mirror role): a READ-ONLY render mirror never reports focus.
    if (self.config.role == .mirror) return;
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
    // Layer 2 (mirror role): a READ-ONLY render mirror NEVER drives session size.
    // Suppress the Resize frame entirely (host also gates via
    // isRenderOnlySubscriber — defense in depth). The host grid is authoritative;
    // the mirror renders whatever cols/rows the host pushes. Return BEFORE the
    // local size record so the mirror is fully inert (Layer 3 scales the tile from
    // the host grid; it does not resize the mirror).
    if (self.config.role == .mirror) return;
    // Record the latest known sizes (mirror state), then send a real Resize
    // frame on the write stream using `td` — same pattern as queueWrite /
    // focusGained, and session_id read via the same unlocked atomic load.
    const grid_size = size.grid();
    self.grid_size = grid_size;
    self.screen_size = size.terminal();

    // screen_w/screen_h carry the FULL padded screen (size.screen), NOT
    // size.terminal() (which is screen.subPadding(padding), already
    // padding-stripped). Send the full padded screen so the wire fields stay
    // self-consistent with the padding_* fields. The host no longer derives
    // the grid from screen_w/h: as of Slice 9 it reconstructs the grid from the
    // AUTHORITATIVE wire {cols, rows} via Resize.toSize() (screen = cols*cell +
    // padding), so screen_w/h round-trips for completeness / size reports but
    // is not the basis for the grid derivation — the historic
    // double-subtract-padding hazard on screen_w/h no longer applies to the
    // grid.
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
    // Layer 2 (mirror role): a READ-ONLY render mirror feeds NO input to the real
    // session (inline-reply is a future Layer-3 add relaxing ONLY this method,
    // never resize).
    if (self.config.role == .mirror) return;
    // One Input frame per call carries the whole buffer; the host applies it
    // to the session's write mailbox. Chunking is a possible optimization but
    // not required for correctness.
    try self.sendFrame(td, .input, protocol.Input{
        .session_id = self.session_id.load(.acquire),
        .linefeed = linefeed,
        .bytes = data,
    });
}

/// Send a `scroll_viewport` frame. The local mirror terminal is unused under
/// .client, so scrolling it would be a silent no-op; instead the host repins
/// ITS terminal (which owns the real scrollback) and the next GridFrame
/// reflects the scrolled viewport. Fire-and-forget on the write stream — same
/// pattern/thread as queueWrite/focusGained/resize (session_id via the same
/// unlocked atomic load).
pub fn scrollViewport(
    self: *Client,
    td: *termio.Termio.ThreadData,
    scroll: terminal.Terminal.ScrollViewport,
) !void {
    // Layer 2 (mirror role): a READ-ONLY render mirror never drives the session.
    if (self.config.role == .mirror) return;
    try self.sendFrame(td, .scroll_viewport, protocol.ScrollViewport.fromTarget(
        self.session_id.load(.acquire),
        scroll,
    ));
}

/// Phase D: send a `clear_screen` frame (⌘K). The local mirror is empty, so the
/// host runs Termio.clearScreen on ITS real terminal (clears scrollback / erases
/// above the cursor / sends FF to the shell at a prompt). Same fire-and-forget
/// write path as scrollViewport.
pub fn clearScreen(
    self: *Client,
    td: *termio.Termio.ThreadData,
    history: bool,
) !void {
    // Layer 2 (mirror role): a READ-ONLY render mirror never drives the session.
    if (self.config.role == .mirror) return;
    try self.sendFrame(td, .clear_screen, protocol.ClearScreen{
        .session_id = self.session_id.load(.acquire),
        .history = history,
    });
}

/// Phase D: send a `reset` frame. The local mirror is empty, so the host runs
/// terminal.fullReset() on ITS real terminal. Same fire-and-forget write path as
/// scrollViewport.
pub fn reset(
    self: *Client,
    td: *termio.Termio.ThreadData,
) !void {
    // Layer 2 (mirror role): a READ-ONLY render mirror never drives the session.
    if (self.config.role == .mirror) return;
    try self.sendFrame(td, .reset, protocol.Reset{
        .session_id = self.session_id.load(.acquire),
    });
}

/// Send a `jump_to_prompt` frame. Same .client routing rationale as
/// scrollViewport: the host jumps ITS terminal's viewport to the prompt.
pub fn jumpToPrompt(
    self: *Client,
    td: *termio.Termio.ThreadData,
    delta: isize,
) !void {
    // Layer 2 (mirror role): a READ-ONLY render mirror never drives the session.
    if (self.config.role == .mirror) return;
    try self.sendFrame(td, .jump_to_prompt, protocol.JumpToPrompt{
        .session_id = self.session_id.load(.acquire),
        .delta = @intCast(delta),
    });
}

/// Slice B1: send a `selection_drag` frame. The host maps the viewport coords
/// to pins on ITS terminal, runs select(), and ships row.selection (highlight)
/// on the next GridFrame plus a `selection_text` with the selected text. Same
/// fire-and-forget write path as scrollViewport.
pub fn selectionDrag(
    self: *Client,
    td: *termio.Termio.ThreadData,
    drag: termio.Message.SelectionDrag,
) !void {
    // Layer 2 (mirror role): a READ-ONLY render mirror never drives the session.
    if (self.config.role == .mirror) return;
    try self.sendFrame(td, .selection_drag, protocol.SelectionDrag{
        .session_id = self.session_id.load(.acquire),
        .anchor_x = drag.anchor_x,
        .anchor_y = drag.anchor_y,
        .head_x = drag.head_x,
        .head_y = drag.head_y,
        .rectangle = drag.rectangle,
    });
}

/// Slice B1: send a `selection_clear` frame. The host runs select(null) and
/// ships a cleared selection_text + a row.selection-free GridFrame.
pub fn selectionClear(
    self: *Client,
    td: *termio.Termio.ThreadData,
) !void {
    // Layer 2 (mirror role): a READ-ONLY render mirror never drives the session.
    if (self.config.role == .mirror) return;
    try self.sendFrame(td, .selection_clear, protocol.SelectionClear{
        .session_id = self.session_id.load(.acquire),
    });
}

/// Slice B2: send a `selection_point` frame. The host maps the viewport point
/// to a pin on ITS terminal and runs selectWord/selectLine (or selectAll, which
/// ignores the point), then ships row.selection (highlight) on the next
/// GridFrame plus a `selection_text` with the selected text. For mode_all the
/// GUI sends x=0,y=0 and the host ignores them. Same fire-and-forget write path
/// as selectionDrag.
pub fn selectionPoint(
    self: *Client,
    td: *termio.Termio.ThreadData,
    pt: termio.Message.SelectionPoint,
) !void {
    // Layer 2 (mirror role): a READ-ONLY render mirror never drives the session.
    if (self.config.role == .mirror) return;
    try self.sendFrame(td, .selection_point, protocol.SelectionPoint{
        .session_id = self.session_id.load(.acquire),
        .x = pt.x,
        .y = pt.y,
        .mode = pt.mode,
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

/// CALLER MUST HOLD renderMutex(). Fire-once core: marks the mirror ended, sets the
/// local child_exited parity field, pushes the synthetic child_exited surface
/// message + wakes the renderer. Returns true if it fired (false if already ended).
/// Lets handleFrame's .child_exited mirror arm — which ALREADY holds renderMutex()
/// for its whole switch — signal session-gone WITHOUT re-locking the non-recursive
/// mutex (which would self-deadlock). The mailbox push + renderer notify run UNDER
/// renderMutex here; that is SAFE and matches the existing real .child_exited /
/// .grid_frame arms, which already push the mailbox + notify under the same held
/// lock (the mailbox queue + wakeup eventfd are their own synchronization, not
/// ordered under renderMutex). See `markMirrorEnded` for the full mirror-role
/// session-gone semantics; this is the no-self-lock core both callers share.
fn markMirrorEndedLocked(self: *Client) bool {
    if (self.mirror_ended) return false; // fire-once
    self.mirror_ended = true;
    // Parity with the real .child_exited arm: set the local field too so any code
    // that later reads self.child_exited on a timed-out/ended mirror sees a value
    // (the surface-mailbox push is the operative signal). Held under renderMutex().
    self.child_exited = .{ .exit_code = 0, .runtime_ms = 0 };
    if (self.surface_mailbox) |mb| _ = mb.push(.{
        .child_exited = .{ .exit_code = 0, .runtime_ms = 0 },
    }, .{ .forever = {} });
    if (self.renderer_wakeup) |*w| w.notify() catch {};
    return true;
}

/// Layer 2 (mirror role): declare the mirrored session gone and signal the surface
/// with a quiescent terminated state. Self-locking wrapper: called from the read
/// thread on a GENUINE socket signal — EOF (host process died / conn dropped),
/// read-error, or fatal-decode in the mirror branch — where renderMutex is NOT held,
/// so it takes the guard, then delegates to `markMirrorEndedLocked`. (The
/// host-forwarded child_exited path, FIX M2, instead calls the locked core directly
/// from handleFrame, which already holds renderMutex.) NEVER fired on frame silence
/// (an idle-but-alive agent must not be misdeclared dead; see MIRROR_POLL_TIMEOUT_MS).
/// Idempotent (fire-once). Does NOT close or mutate anything real — the mirror owns
/// no pty; this only dims the preview. Synthetic exit_code 0 since a mirror cannot
/// know the real exit code. Reuses the surface mailbox the real .child_exited arm
/// uses, but `Surface.childExited` BRANCHES on `Surface.isMirror()`: for a mirror it
/// RETURNS WITHOUT self.close() (and without the abnormal-exit GUI action) — it writes
/// NO text into the local terminal, since a `.client` mirror's renderer draws from
/// `renderer_state.mirror` (the host-fed frame), never from the local terminal, so the
/// frozen last host frame simply persists (Layer 3 dims it). Thus a genuine EOF — e.g.
/// a routine ghostty-host restart — leaves a persistent terminated tile instead of
/// tearing the surface down. `pub` so the difftest harness (a sibling file) can
/// unit-test the fire-once signal contract directly.
pub fn markMirrorEnded(self: *Client) void {
    const m = self.renderMutex();
    m.lock();
    defer m.unlock();
    _ = self.markMirrorEndedLocked();
}

/// Get information about the process(es) attached to the backend.
///
/// The client does not own a local process (the host does), so this always
/// returns `null` ("not available"), an explicitly supported result.
pub fn getProcessInfo(self: *Client, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
    // Under .client only the foreground pid is mirrored — the host pushes it via
    // the minor-4 `foreground_pid` frame (no local PTY here). Other ProcessInfo
    // variants are not carried over the wire, so they remain null.
    if (info == .foreground_pid) {
        const v = self.fg_pid.load(.acquire);
        return if (v == 0) null else v;
    }
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
            // fork: stamp last-activity. A grid_frame is the only frame that
            // represents a REAL screen change (the host suppresses redundant idle
            // frames; cursor blink is local), so Surface.idleMillis measures the
            // gap since this. Lock-free store; ms granularity is plenty for idle.
            self.last_activity_ms.store(std.time.milliTimestamp(), .release);
            // Wake the GUI renderer so it draws this frame promptly (else it
            // only redraws on a slow fallback -> input lag). notify() is a quick
            // cross-thread signal; doing it under the render mutex is a tiny
            // window (the woken renderer briefly waits for this unlock).
            if (self.renderer_wakeup) |*w| w.notify() catch {};
        },

        .mode_frame => {
            // POD; replace the mirror wholesale.
            const decoded = try protocol.ModeFrame.decode(alloc, payload);
            self.mode = decoded;

            // PHASE A (audit R2): APPLY the decoded modes onto the local
            // terminal so the GUI's key/mouse/paste encode paths read the
            // host's REAL input modes instead of stuck defaults. We already
            // hold the shared `renderMutex()` here, which is the SAME lock the
            // encode reads take (Surface.zig locks `renderer_state.mutex`
            // around `fromTerminal`/the mouse gates) — so no new locking and the
            // apply is synchronized with those reads. This is `.client`-only by
            // construction (this code never runs under `.exec`). No-op when
            // `local_terminal` is null (standalone/decode tests bypass initTerminal).
            if (self.local_terminal) |t| {
                const mf = decoded;
                // The 8 bool modes -> ModeState.set(.<name>, bool). Names
                // verified against the ModeFrame.fromTerminal source reads.
                t.modes.set(.alt_esc_prefix, mf.alt_esc_prefix);
                t.modes.set(.cursor_keys, mf.cursor_keys);
                t.modes.set(.keypad_keys, mf.keypad_keys);
                t.modes.set(.backarrow_key_mode, mf.backarrow_key_mode);
                t.modes.set(.ignore_keypad_with_numlock, mf.ignore_keypad_with_numlock);
                t.modes.set(.bracketed_paste, mf.bracketed_paste);
                t.modes.set(.disable_keyboard, mf.disable_keyboard);
                t.modes.set(.mouse_alternate_scroll, mf.mouse_alternate_scroll);

                // The mouse-reporting + modify_other_keys cluster lives on
                // t.flags (not modes). The u8/u2 wire fields are the enum
                // indices written by fromTerminal's @intFromEnum, so for a
                // well-formed host they round-trip exactly. They are, however,
                // UNTRUSTED wire bytes: the target enums are EXHAUSTIVE with
                // narrow backing (mouse.Event/.Format are u3 with valid 0..4,
                // mouse_shift_capture is u2 with valid 0..2), so a raw
                // @enumFromInt on an out-of-range byte from a corrupt / desynced
                // / version-skewed peer is illegal behavior (checked panic in
                // safe builds, UB in the ReleaseFast lib). The protocol layer's
                // contract is that untrusted wire integers must NEVER abort the
                // process — they degrade to error.InvalidFrame, treated as a
                // clean connection close (FrameReader.next, readEnum, etc.). So
                // validate via intToEnum and mirror that convention here.
                t.flags.mouse_event = std.meta.intToEnum(
                    @TypeOf(t.flags.mouse_event),
                    mf.mouse_event,
                ) catch return error.InvalidFrame;
                t.flags.mouse_format = std.meta.intToEnum(
                    @TypeOf(t.flags.mouse_format),
                    mf.mouse_format,
                ) catch return error.InvalidFrame;
                t.flags.mouse_shift_capture = std.meta.intToEnum(
                    @TypeOf(t.flags.mouse_shift_capture),
                    mf.mouse_shift_capture,
                ) catch return error.InvalidFrame;
                t.flags.modify_other_keys_2 = mf.modify_other_keys_2;

                // Kitty keyboard: set the ACTIVE screen's flag stack so
                // `current().int()` == mf.kitty_flags — exactly what
                // `key_encode`/`fromTerminal` read
                // (`t.screens.active.kitty_keyboard.current().int()`). The wire
                // u8 holds a u5 Flags bit-pattern; @bitCast it back to Flags and
                // `set(.set, …)` overwrites the current stack slot (vs. push,
                // which would mutate the stack depth). The host already resolved
                // the value for ITS active screen, and fromTerminal reads the
                // local active screen, so no active_key switch is needed.
                //
                // UNTRUSTED wire byte: kitty_flags is a u8 carrying a u5 from a
                // well-formed host. A narrowing @intCast(u5) would be illegal
                // behavior if a corrupt/skewed peer set any high bit (>31). The
                // @bitCast to Flags is total (every u5 is a valid packed
                // struct(u5)), so only the narrowing is unsafe. Reject high bits
                // to mirror the protocol's "malformed wire int -> InvalidFrame
                // -> clean close" convention (same as the mouse casts above).
                if (mf.kitty_flags > std.math.maxInt(u5)) return error.InvalidFrame;
                t.screens.active.kitty_keyboard.set(
                    .set,
                    @bitCast(@as(u5, @intCast(mf.kitty_flags))),
                );

                // RESIDUAL (documented, MEDIUM audit item): alt_screen_active is
                // intentionally NOT applied. Switching the local terminal's
                // active screen requires mutating `t.screens.active_key`, which
                // is tied to DECSET 1049 handling + screen-swap assertions and is
                // unsafe to set directly here. The only behavior that still reads
                // the local active_key under .client is the alt-screen
                // wheel->arrow scroll translation; everything else covered above
                // (all HIGH items + kitty) is now correct. A future slice can
                // address alt-screen via the mirror's alt flag.
            }
        },

        .attached => {
            const att = try protocol.Attached.decode(alloc, payload);
            // Reattach-miss signal: if we asked to reattach to a SPECIFIC session
            // (a non-null, non-zero persisted id) but the host handed back a
            // DIFFERENT id, our session was gone (closed, or the host restarted)
            // and the host spawned a FRESH one. With random host ids a stale id
            // never false-matches, so a differing id reliably means "miss." Surface
            // it (a blank fresh shell presented as if it were the restored session
            // is the sharpest "lost work" edge) instead of silently swapping ids.
            if (self.config.session_id) |requested| {
                if (requested != 0 and att.session_id != requested) {
                    log.warn(
                        "reattach miss: requested session_id={d} not found on host; spawned fresh session_id={d} (prior session closed or host restarted)",
                        .{ requested, att.session_id },
                    );
                }
            }
            // Atomic store (even though we hold the guard mutex here): the
            // UNLOCKED IO-thread readers in queueWrite/focusGained synchronize
            // against this store, not against the mutex. Independent of the
            // Slice 3d shared-mutex change — the lock-free path is untouched.
            self.session_id.store(att.session_id, .release);
        },

        .child_exited => {
            const ce = try protocol.ChildExited.decode(alloc, payload);
            if (self.config.role == .mirror) {
                // Layer 2 FIX (M2): the host forwarded a child_exited to this render
                // subscriber because the real agent exited while ghostty-host stays
                // alive (the host now ALSO broadcasts child_exited to
                // render_subscribers — see src/host/Server.zig onChildExited). A
                // mirror owns NO pty and must NOT take the attach close path.
                // markMirrorEndedLocked (we ALREADY hold renderMutex here, so we
                // CANNOT call the self-locking markMirrorEnded wrapper without a
                // self-deadlock) sets the quiescent terminated state + signals the
                // surface; Surface.childExited's mirror guard renders it WITHOUT
                // self.close(). Fire-once: a repeat child_exited is a no-op (the
                // field is set inside the locked core only on first fire, so a repeat
                // never overwrites it with a stale-but-unmirrored value). `ce` is
                // decoded above (validates the frame) but intentionally unused here —
                // a mirror cannot know/forward the real exit code; {0,0} matches the
                // EOF/timeout path.
                _ = self.markMirrorEndedLocked();
            } else {
                // .attach (existing behavior, byte-for-byte): record + deliver to the
                // surface so Surface.childExited runs the normal close/show-exited
                // flow — exactly what .exec does from its IO thread (Exec.zig:291).
                // Without this a real .client tab HANGS on `exit`.
                // `protocol.ChildExited`'s fields match
                // `apprt.surface.Message.ChildExited` (exit_code: u32, runtime_ms:
                // u64). No-op when `surface_mailbox` is null (decode/lifecycle tests
                // bypass threadEnter).
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
            // Link highlights are visible state; wake the renderer (see grid_frame).
            if (self.renderer_wakeup) |*w| w.notify() catch {};
        },

        .surface_event => {
            // Slice 6: a forwarded `apprt.surface.Message` (title, bell, OSC52
            // clipboard, pwd_change, dynamic colors, desktop notifications,
            // progress, mouse-shape, shell command-tracking, password-input).
            // DESERIALIZE and re-inject into the surface mailbox — the existing
            // Surface drain then handles it identically to `.exec`. Mirrors the
            // child_exited push above; same null-mailbox no-op (decode tests
            // bypass threadEnter -> surface_mailbox is null).
            //
            // OWNERSHIP: `toMessage` COPIES/DUPES the WriteReq-bearing payloads
            // (pwd_change/clipboard_write) into a freshly-owned WriteReq the
            // surface drain then owns; the decoded SurfaceEvent's own bytes are
            // freed by `ev.deinit(alloc)`. The response-bearing variants
            // (clipboard_read / report_title) ride the surface's normal termio
            // path back to the host over the Input channel — no reply frame here.
            var ev = try protocol.SurfaceEvent.decode(alloc, payload);
            defer ev.deinit(alloc);

            // CWD-INHERIT FIX: under .client the terminal emulation (and thus
            // OSC 7 / `setPwd`) runs on the HOST, so the GUI-side local mirror
            // terminal's pwd is never updated. `Surface.pwd()` reads exactly
            // this local terminal (`io.terminal`), and new-split/new-tab cwd
            // inheritance (`newSurfaceOptions` -> `core_surface.pwd()`) depends
            // on it — without this, every hosted split/tab defaulted to $HOME.
            // Mirror the host's pwd onto the local terminal here so the read
            // accessor returns the live cwd. We hold the guard mutex (taken in
            // handleFrame), which IS the renderer_state.mutex `Surface.pwd()`
            // locks, so this write is correctly synchronized with that read. An
            // empty pwd resets it (matches stream_handler.reportPwd's reset).
            // OOM is non-fatal: the pwd just stays stale (no crash).
            if (ev.payload == .pwd_change) {
                if (self.local_terminal) |t| t.setPwd(ev.payload.pwd_change) catch |err|
                    log.warn("failed to mirror host pwd onto local terminal err={}", .{err});
            }

            if (self.surface_mailbox) |mb| {
                const msg = try ev.toMessage(alloc);
                _ = mb.push(msg, .{ .forever = {} });
            }
        },

        .selection_text => {
            // Slice B1: the host's current selection text. Replace the cache
            // wholesale (present=false clears it). We hold the guard mutex here
            // (handleFrame took it), the SAME lock the Surface read accessors
            // take via the renderer mutex under .client, so the copy/enablement
            // reads see a consistent {present, text}. NOT visible render state
            // (the highlight rides grid_frame's row.selection), so no renderer
            // wakeup is needed.
            var st = try protocol.SelectionText.decode(alloc, payload);
            defer st.deinit(alloc);
            self.selection_present = st.present;
            self.selection_text.clearRetainingCapacity();
            if (st.present) {
                try self.selection_text.appendSlice(self.gpa, st.text);
            }
        },

        .at_prompt => {
            // Phase D: the host's authoritative at-prompt bit. Store into the
            // lock-free atomic that Surface.needsConfirmQuit reads on the apprt
            // thread. Not visible render state, so no renderer wakeup needed.
            var ap = try protocol.AtPrompt.decode(alloc, payload);
            defer ap.deinit(alloc);
            self.at_prompt.store(ap.at_prompt, .release);
        },

        .process_info => {
            // fork (minor 3): the host's resolved foreground process name +
            // command. Replace the cache wholesale. We hold the guard mutex here
            // (handleFrame took it), the SAME lock the Surface read accessors take
            // via the renderer mutex under .client, so a poll sees a consistent
            // {name, command}. Not visible render state, so no renderer wakeup.
            var pi = try protocol.ProcessInfo.decode(alloc, payload);
            defer pi.deinit(alloc);
            self.fg_process_name.clearRetainingCapacity();
            try self.fg_process_name.appendSlice(self.gpa, pi.name);
            self.fg_command.clearRetainingCapacity();
            try self.fg_command.appendSlice(self.gpa, pi.command);
        },

        .foreground_pid => {
            // fork (minor 4): the host's RAW foreground pid for GUI-side subtree
            // walking. Lock-free atomic store (getProcessInfo reads it without the
            // guard mutex); 0 == no foreground process.
            var fp = try protocol.ForegroundPid.decode(alloc, payload);
            defer fp.deinit(alloc);
            self.fg_pid.store(fp.pid, .release);
        },

        // Everything else is either a request-direction frame (the GUI sends
        // these, never receives them) or a liveness frame we don't model yet.
        else => log.debug("client ignoring frame tag={}", .{tag}),
    }
}

/// Phase D: the host's authoritative at-prompt bit (see the `at_prompt` field).
/// Read by Surface.needsConfirmQuit under .client. Lock-free.
pub fn cursorIsAtPrompt(self: *const Client) bool {
    return self.at_prompt.load(.acquire);
}

/// Slice B1: does the host have a selection cached? Caller MUST hold the guard
/// returned by `renderMutex()` (the Surface read sites take the renderer mutex,
/// which IS that lock under .client). Drives `Surface.hasSelection` (Copy-menu
/// enablement) under .client.
pub fn hasCachedSelection(self: *const Client) bool {
    return self.selection_present;
}

/// Slice B1: a freshly-allocated NUL-terminated copy of the cached host
/// selection text, or null when no selection is present. Caller owns the result
/// and MUST hold the guard returned by `renderMutex()` (same lock discipline as
/// hasCachedSelection). Mirrors `Screen.selectionString`'s `[:0]const u8` return
/// so the Surface copy path is uniform across backends.
pub fn copyCachedSelectionText(self: *const Client, alloc: Allocator) !?[:0]const u8 {
    if (!self.selection_present) return null;
    return try alloc.dupeZ(u8, self.selection_text.items);
}

/// fork: the host's resolved foreground process name (e.g. "claude"), or "" if
/// none has been pushed yet (old host / pre-first-frame). Caller MUST hold the
/// guard returned by `renderMutex()` (the Surface read site takes the renderer
/// mutex, which IS that lock under .client) — same discipline as the selection
/// accessors. Borrowed slice valid only while the lock is held.
pub fn foregroundProcessName(self: *const Client) []const u8 {
    return self.fg_process_name.items;
}

/// fork: the host's resolved foreground command line (e.g. "claude --resume"),
/// or "" if none yet. Same lock discipline as `foregroundProcessName`.
pub fn foregroundCommand(self: *const Client) []const u8 {
    return self.fg_command.items;
}

/// fork: ms since the last applied grid_frame (a real screen change), or null if
/// no frame has been applied yet. Lock-free (reads the `last_activity_ms`
/// atomic). Drives `Surface.idleMillis`.
pub fn idleMillis(self: *const Client) ?i64 {
    const last = self.last_activity_ms.load(.acquire);
    // 0 is overloaded: "no frame applied yet" AND the (epoch-only, 1970)
    // milliTimestamp()==0 sentinel. The latter is purely theoretical — a frame
    // would have to apply at the Unix epoch — so treating 0 as "unknown" is safe.
    if (last == 0) return null;
    // Wall-clock (milliTimestamp) is not monotonic: a backward NTP step makes
    // `now - last` negative. Clamp to 0 (report "just active") rather than let a
    // negative i64 reach the Swift idleSeconds getter, which maps ms<0 -> nil and
    // would otherwise surface a clock blip as "idle unknown".
    const delta = std.time.milliTimestamp() - last;
    return if (delta < 0) 0 else delta;
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
            // `pod.underline` is the raw u8 enum index of sgr.Attribute.Underline
            // (enum(u3), valid 0..5). `@enumFromInt` on an out-of-range value is
            // checked-illegal-behavior (panic in safe builds, UB in the ReleaseFast
            // .mirror lib), so it must never see a garbage byte. It cannot: every
            // StylePod reaching rehydrateStyle is produced by `Snapshot.deserialize`
            // (-> StylePod.read), which fails closed with error.InvalidUnderline on
            // any byte outside 0..5 (RenderState.zig) — the same untrusted-wire
            // @enumFromInt discipline applied to ColorTag / dirty / cursor_visual_style.
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

        // Layer 2 (mirror role): a read-only mirror declares the session gone ONLY
        // on a genuine socket signal — EOF (n==0) or a read error — NOT on frame
        // silence (see MIRROR_POLL_TIMEOUT_MS: an idle-but-alive agent sends zero
        // frames, so silence must not be treated as death). It polls with a FINITE
        // timeout (not poll(-1)) only to stay responsive to the quit pipe; on a
        // timeout wake it simply re-loops. The .attach role keeps poll(-1) + its
        // existing EOF/error handling byte-for-byte unchanged: every mirror-specific
        // branch below is gated on `is_mirror`.
        const is_mirror = client.config.role == .mirror;
        const poll_timeout: i32 = if (is_mirror) MIRROR_POLL_TIMEOUT_MS else -1;

        var buf: [1024]u8 = undefined;
        while (true) {
            while (true) {
                const n = posix.read(fd, &buf) catch |err| switch (err) {
                    error.NotOpenForReading, error.InputOutput => {
                        log.info("client reader exiting", .{});
                        // Layer 2 (mirror role): a genuine session-gone on a mirror
                        // (conn dropped / host died). Signal the terminated state.
                        if (is_mirror) client.markMirrorEnded();
                        return;
                    },
                    error.WouldBlock => break,
                    else => {
                        log.err("client reader error err={}", .{err});
                        if (is_mirror) client.markMirrorEnded();
                        return;
                    },
                };
                if (n == 0) {
                    // EOF. Under .attach this is the existing reattach/disconnect
                    // break; under a mirror it is genuine session-gone -> signal.
                    if (is_mirror) {
                        client.markMirrorEnded();
                        return;
                    }
                    break;
                }

                // Push + drain complete frames into the mirror.
                client.reader.push(client.gpa, buf[0..n]) catch |err| {
                    log.err("client reader push failed err={}", .{err});
                    // Layer 2 (mirror role): a fatal push failure ends this read
                    // thread; for a mirror that is session-gone, so signal the
                    // terminated state (symmetric with the EOF/read-error paths).
                    if (is_mirror) client.markMirrorEnded();
                    return;
                };
                while (true) {
                    const frame = client.reader.next(client.gpa) catch |err| {
                        log.err("client frame decode failed err={}", .{err});
                        // Layer 2 (mirror role): a fatal decode failure (e.g.
                        // error.InvalidFrame from a corrupt frame) ends this read
                        // thread; for a mirror that is session-gone, so signal it.
                        if (is_mirror) client.markMirrorEnded();
                        return;
                    } orelse break;
                    client.handleFrame(
                        client.gpa,
                        frame.tag,
                        frame.payload,
                    ) catch |err| {
                        log.err("client handleFrame failed err={}", .{err});
                        // Layer 2 (mirror role): a fatal handleFrame failure (e.g.
                        // error.InvalidFrame via the mouse/kitty intToEnum guards on
                        // a corrupt mode_frame) ends this read thread; for a mirror
                        // that is session-gone, so signal the terminated state.
                        if (is_mirror) client.markMirrorEnded();
                        return;
                    };
                }
            }

            _ = posix.poll(&pollfds, poll_timeout) catch |err| {
                log.warn("client reader poll failed, exiting err={}", .{err});
                // Layer 2 (mirror role): a poll() error (rare) ends this read thread
                // just like EOF / read-error / fatal-decode; for a mirror that is
                // session-gone, so signal the terminated state (symmetric with the
                // other read-thread exit paths — otherwise the tile would freeze on
                // its last frame and never declare "ended").
                if (is_mirror) client.markMirrorEnded();
                return;
            };

            if (pollfds[1].revents & posix.POLL.IN != 0) return;

            // Layer 2 (mirror role): a poll TIMEOUT (no socket activity) is NOT a
            // session-gone signal — an idle-but-alive agent legitimately sends no
            // frames. We simply re-loop. Genuine session-gone is detected only by
            // EOF / read-error in the inner read loop above, which call
            // markMirrorEnded. (No silence-based terminate; see MIRROR_POLL_TIMEOUT_MS.)
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

// Slice 5a forward-mapping test. Named to match both the `client` and
// `config` test filters. Asserts the surface-config host session id is
// forward-mapped onto the Client's `Attach` session id with the 0 => fresh
// sentinel: 0 => null (spawn a FRESH host session, unchanged behavior),
// non-zero => Some(id) (reattach to that existing host session). This is
// the pure mapping `Surface.init` applies when it builds the `.client`
// backend config (`Client.sessionIdFromConfig(req_session_id)`), where
// `req_session_id` is `rt_surface.session_id` == `Options.session_id` ==
// the C `ghostty_surface_config_s.session_id`. The remaining wiring (the C
// struct field is copied into apprt `Options`, then onto the apprt surface,
// then read by `Surface.init`) is type-checked by the build and covered by
// the Slice-5c human smoke (an actual reattach from the macOS GUI).
test "client/config: forward-map surface session_id into Client.Config.session_id" {
    const testing = std.testing;

    // 0 is the none/fresh sentinel: maps to a null Attach session_id, i.e.
    // spawn a fresh host session (today's behavior, .exec & .client alike).
    try testing.expectEqual(@as(?u64, null), sessionIdFromConfig(0));

    // Any non-zero id requests reattach to that exact host session.
    try testing.expectEqual(@as(?u64, 1), sessionIdFromConfig(1));
    try testing.expectEqual(@as(?u64, 42), sessionIdFromConfig(42));
    try testing.expectEqual(
        @as(?u64, std.math.maxInt(u64)),
        sessionIdFromConfig(std.math.maxInt(u64)),
    );

    // And the mapped value lands on the actual Client.Config field the
    // Attach is sent from (Client.zig connectAndAttach reads cfg.session_id).
    const fresh: Config = .{ .session_id = sessionIdFromConfig(0) };
    try testing.expectEqual(@as(?u64, null), fresh.session_id);
    const reattach: Config = .{ .session_id = sessionIdFromConfig(7) };
    try testing.expectEqual(@as(?u64, 7), reattach.session_id);
}

// Slice 5b reverse-mapping test. Named to match both the `client` and
// `config` filters. Asserts the host-ASSIGNED session id flows back OUT of a
// `.client` backend via the same lock-free atomic the accessor reads. This is
// the load-bearing half of `Surface.sessionId` (src/Surface.zig):
//   switch (self.io.backend) { .client => |*c| c.session_id.load(.acquire), .exec => 0 }
// We build a real `termio.Backend` union (not a stub) holding a `.client`,
// reproduce the accessor's exact switch over it, and assert:
//   - default (no Attached frame yet) => 0 (the unattached sentinel; host ids
//     start at 1), so an unattached client reads as 0 just like `.exec`.
//   - after the host assigns an id (modeled by the same `.release` store
//     `handleFrame` performs on the Attached frame) => that exact id.
// The trivial `.exec => 0` constant arm (no client-union deref) is enforced by
// the build's exhaustive switch and exercised by the Slice-5c human smoke (a
// real reattach from the macOS GUI reading `ghostty_surface_session_id`).
test "client/config: reverse-map host-assigned session_id out of .client backend" {
    const testing = std.testing;

    var backend: termio.Backend = .{
        .client = try Client.init(testing.allocator, .{}),
    };
    defer backend.deinit();

    // The accessor's exact switch (mirrors Surface.sessionId).
    const read = struct {
        fn sessionId(b: *termio.Backend) u64 {
            return switch (b.*) {
                .client => |*c| c.session_id.load(.acquire),
                .exec => 0,
            };
        }
    }.sessionId;

    // Freshly-built client has not received its Attached frame: 0 = unattached.
    try testing.expectEqual(@as(u64, 0), read(&backend));

    // Model the host assigning an id (same store-release `handleFrame` does on
    // the Attached frame); the accessor must read it back lock-free.
    backend.client.session_id.store(99, .release);
    try testing.expectEqual(@as(u64, 99), read(&backend));

    backend.client.session_id.store(std.math.maxInt(u64), .release);
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), read(&backend));
}

// Slice 5d exit-hang fix. Named to match the `client` filter. Asserts that
// decoding a ChildExited protocol frame through `handleFrame`, with a
// surface_mailbox set on the Client, DELIVERS a `child_exited`
// apprt.surface.Message onto that mailbox — the bit that was missing and left
// the .client tab hanging on `exit` (the .exec arm pushes the same message from
// its IO thread, Exec.zig:291, which drives Surface.childExited -> close/
// show-exited per wait-after-command). We use the smallest REAL mechanism: a
// genuine `apprt.surface.Mailbox` over a real `App.Mailbox.Queue` (BlockingQueue)
// backed by a no-op headless `apprt.App` (`.none` wakeup), then drain the queue
// and assert the pushed message's tag + exit_code/runtime_ms round-trip the
// frame. The `.surface` pointer is only STORED into the wrapped message (never
// dereferenced by `Mailbox.push`), so a sentinel pointer is sufficient.
test "client: child_exited frame delivers child_exited surface message" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const App = @import("../App.zig");
    const CoreSurface = @import("../Surface.zig");

    // A real app-side mailbox queue we can drain after the push.
    const queue = try App.Mailbox.Queue.create(alloc);
    defer queue.destroy(alloc);

    // A no-op headless apprt App (its wakeup is a pure no-op under
    // app_runtime=.none — the build artifact for tests). Heap-stable so the
    // App.Mailbox can hold a *apprt.App to it.
    var rt_app: apprt.App = undefined;

    // The Surface pointer is only stored into the wrapped surface_message, never
    // dereferenced by Mailbox.push, so a sentinel is fine here. This is the CORE
    // `src/Surface.zig` type (what apprt.surface.Mailbox.surface is typed as),
    // NOT the apprt-runtime Surface.
    const surface_sentinel: *CoreSurface = @ptrFromInt(@alignOf(CoreSurface));

    var client = try Client.init(alloc, .{});
    defer client.deinit();
    client.surface_mailbox = .{
        .surface = surface_sentinel,
        .app = .{ .rt_app = &rt_app, .mailbox = queue },
    };

    // Encode a real ChildExited frame payload and decode it through handleFrame.
    const ce: protocol.ChildExited = .{
        .session_id = 7,
        .exit_code = 42,
        .runtime_ms = 1234,
    };
    const payload = try ce.encode(alloc);
    defer alloc.free(payload);
    try client.handleFrame(alloc, .child_exited, payload);

    // The stored mirror state is updated (decode half, unchanged behavior)...
    try testing.expect(client.child_exited != null);
    try testing.expectEqual(@as(u32, 42), client.child_exited.?.exit_code);
    try testing.expectEqual(@as(u64, 1234), client.child_exited.?.runtime_ms);

    // ...AND the surface message was DELIVERED (the 5d fix). Drain the queue
    // and assert it's a child_exited carrying the frame's fields.
    const msg = queue.pop() orelse return error.NoMessagePushed;
    try testing.expect(msg == .surface_message);
    try testing.expect(msg.surface_message.surface == surface_sentinel);
    try testing.expect(msg.surface_message.message == .child_exited);
    try testing.expectEqual(
        @as(u32, 42),
        msg.surface_message.message.child_exited.exit_code,
    );
    try testing.expectEqual(
        @as(u64, 1234),
        msg.surface_message.message.child_exited.runtime_ms,
    );
}

// Slice 5d: with no surface_mailbox set (standalone/decode construction, the
// state of every lifecycle/decode test which bypasses threadEnter), the
// child_exited push is a pure no-op and decoding still updates the mirror —
// proving the new push doesn't regress the headless path.
test "client: child_exited frame with null surface_mailbox is a no-op push" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var client = try Client.init(alloc, .{});
    defer client.deinit();
    try testing.expectEqual(@as(?apprt.surface.Mailbox, null), client.surface_mailbox);

    const ce: protocol.ChildExited = .{
        .session_id = 3,
        .exit_code = 0,
        .runtime_ms = 5,
    };
    const payload = try ce.encode(alloc);
    defer alloc.free(payload);

    // No mailbox => push branch is skipped; decode still folds into the mirror.
    try client.handleFrame(alloc, .child_exited, payload);
    try testing.expect(client.child_exited != null);
    try testing.expectEqual(@as(u32, 0), client.child_exited.?.exit_code);
    try testing.expectEqual(@as(u64, 5), client.child_exited.?.runtime_ms);
}

// Slice B1: decoding a selection_text frame caches the host selection so
// hasCachedSelection / copyCachedSelectionText return it (the GUI copy path
// reads this, no sync round-trip), and a cleared frame resets the cache.
test "client: selection_text frame caches host selection text + clear resets" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var client = try Client.init(alloc, .{});
    defer client.deinit();

    // Initially empty.
    try testing.expect(!client.hasCachedSelection());
    try testing.expectEqual(@as(?[:0]const u8, null), try client.copyCachedSelectionText(alloc));

    // Present=true frame -> cache holds the text.
    {
        const st: protocol.SelectionText = .{
            .session_id = 1,
            .present = true,
            .text = "hi there",
        };
        const payload = try st.encode(alloc);
        defer alloc.free(payload);
        try client.handleFrame(alloc, .selection_text, payload);
    }
    try testing.expect(client.hasCachedSelection());
    {
        const got = (try client.copyCachedSelectionText(alloc)).?;
        defer alloc.free(got);
        try testing.expectEqualStrings("hi there", got);
    }

    // A second present frame replaces (not appends) the cached text.
    {
        const st: protocol.SelectionText = .{
            .session_id = 1,
            .present = true,
            .text = "x",
        };
        const payload = try st.encode(alloc);
        defer alloc.free(payload);
        try client.handleFrame(alloc, .selection_text, payload);
    }
    {
        const got = (try client.copyCachedSelectionText(alloc)).?;
        defer alloc.free(got);
        try testing.expectEqualStrings("x", got);
    }

    // present=false clears the cache.
    {
        const st: protocol.SelectionText = .{ .session_id = 1, .present = false };
        const payload = try st.encode(alloc);
        defer alloc.free(payload);
        try client.handleFrame(alloc, .selection_text, payload);
    }
    try testing.expect(!client.hasCachedSelection());
    try testing.expectEqual(@as(?[:0]const u8, null), try client.copyCachedSelectionText(alloc));
}

test "client: at_prompt frame updates cached cursorIsAtPrompt (Phase D)" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var client = try Client.init(alloc, .{});
    defer client.deinit();

    // Safe default before any frame: not at a prompt => needsConfirmQuit warns.
    try testing.expect(!client.cursorIsAtPrompt());

    inline for (.{ true, false, true }) |v| {
        const ap: protocol.AtPrompt = .{ .session_id = 1, .at_prompt = v };
        const payload = try ap.encode(alloc);
        defer alloc.free(payload);
        try client.handleFrame(alloc, .at_prompt, payload);
        try testing.expectEqual(v, client.cursorIsAtPrompt());
    }
}

// fork: decoding a process_info frame caches the host-resolved foreground name +
// command so the Surface getters (driven by MCP list_surfaces) read them with no
// round-trip; a second frame REPLACES (not appends) the cache; empty strings clear.
test "client: process_info frame caches foreground name + command" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var client = try Client.init(alloc, .{});
    defer client.deinit();

    // The accessors borrow under renderMutex() (handleFrame writes under it); the
    // sanctioned call pattern holds the guard across the read, so mirror that here
    // even though the test is single-threaded. A tiny helper takes the lock,
    // compares the borrowed slices, and drops it.
    const Read = struct {
        fn check(c: *Client, want_name: []const u8, want_cmd: []const u8) !void {
            const m = c.renderMutex();
            m.lock();
            defer m.unlock();
            try testing.expectEqualStrings(want_name, c.foregroundProcessName());
            try testing.expectEqualStrings(want_cmd, c.foregroundCommand());
        }
    };

    // Initially empty (no frame pushed yet).
    try Read.check(&client, "", "");

    {
        const pi: protocol.ProcessInfo = .{
            .session_id = 1,
            .name = "claude",
            .command = "claude --resume",
        };
        const payload = try pi.encode(alloc);
        defer alloc.free(payload);
        try client.handleFrame(alloc, .process_info, payload);
    }
    try Read.check(&client, "claude", "claude --resume");

    // A second frame replaces (not appends) the cache.
    {
        const pi: protocol.ProcessInfo = .{
            .session_id = 1,
            .name = "nvim",
            .command = "nvim x",
        };
        const payload = try pi.encode(alloc);
        defer alloc.free(payload);
        try client.handleFrame(alloc, .process_info, payload);
    }
    try Read.check(&client, "nvim", "nvim x");

    // Empty strings clear the cache.
    {
        const pi: protocol.ProcessInfo = .{ .session_id = 1 };
        const payload = try pi.encode(alloc);
        defer alloc.free(payload);
        try client.handleFrame(alloc, .process_info, payload);
    }
    try Read.check(&client, "", "");
}

// fork: idleMillis is null until a grid_frame is applied, and ONLY a grid_frame
// stamps activity — an at_prompt frame (or any non-grid frame) must NOT reset it.
test "client: idleMillis stamped by grid_frame only" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var client = try Client.init(alloc, .{});
    defer client.deinit();

    // No frame applied yet => unknown.
    try testing.expectEqual(@as(?i64, null), client.idleMillis());

    // A non-grid frame must NOT stamp activity (idle stays unknown).
    {
        const ap: protocol.AtPrompt = .{ .session_id = 1, .at_prompt = true };
        const payload = try ap.encode(alloc);
        defer alloc.free(payload);
        try client.handleFrame(alloc, .at_prompt, payload);
    }
    try testing.expectEqual(@as(?i64, null), client.idleMillis());

    // A REAL grid_frame MUST stamp activity. Build a tiny 1x1 terminal, project
    // it into a Snapshot, wrap it in a GridFrame, encode, and feed the wire bytes
    // through handleFrame so the `.grid_frame` arm's `last_activity_ms.store` is
    // exercised in-unit (a future refactor that drops the store from that arm now
    // fails here, not only in the host integration test). idle transitions
    // null -> non-null.
    {
        var term = try terminal.Terminal.init(alloc, .{ .cols = 1, .rows = 1 });
        defer term.deinit(alloc);
        try term.printString("x");

        var rs: render.RenderState = .empty;
        defer rs.deinit(alloc);
        try rs.update(alloc, &term);

        var snap = try Snapshot.fromRenderState(alloc, &rs);
        defer snap.deinit(alloc);

        const gf: protocol.GridFrame = .{ .session_id = 1, .snapshot = snap };
        const payload = try gf.encode(alloc);
        defer alloc.free(payload);
        try client.handleFrame(alloc, .grid_frame, payload);
    }
    const idle = client.idleMillis();
    try testing.expect(idle != null);
    try testing.expect(idle.? >= 0);
}

// fork: a backward wall-clock step (NTP slew) makes `now - last` negative;
// idleMillis must clamp it to 0, not surface a negative i64 (which the Swift
// idleSeconds getter would map to nil / "unknown").
test "client: idleMillis clamps a backward clock step to 0" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var client = try Client.init(alloc, .{});
    defer client.deinit();

    // Stamp the activity time in the FUTURE relative to milliTimestamp(), so the
    // delta `now - last` is negative — the backward-clock-step shape.
    client.last_activity_ms.store(std.time.milliTimestamp() + 10_000, .release);
    const idle = client.idleMillis();
    try testing.expect(idle != null);
    try testing.expectEqual(@as(i64, 0), idle.?);
}
