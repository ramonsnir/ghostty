//! FORK(host-handoff): the session-less SUPERVISOR — a tiny launchd job that owns
//! the GUI listen socket forever, keeps exactly one live `ghostty-host` WORKER
//! serving on it, holds a dup of every session's pty master (SIGHUP insurance +
//! handoff source), and BROKERS a zero-downtime handoff from an old worker (v1)
//! to a new one (v2) so a `ghostty-host` upgrade no longer loses RAM-only
//! sessions.
//!
//! ## One binary, three modes
//!
//! The supervisor and the worker are the SAME `ghostty-host` binary in different
//! argv modes (see `main_host.zig`): `--supervise` runs THIS file; the workers it
//! spawns run `--handoff-worker --listen-fd=3 --control-fd=4`. The supervisor
//! binds the listen socket ONCE (`Server.bindListenSocket`) and hands the SAME
//! listener fd to each successive worker by fd-inheritance (dup2 → fd 3 across a
//! fork/exec), so a worker swap never unbinds/rebinds the path (no accept race).
//!
//! ## The control channel
//!
//! Each worker gets an inherited `socketpair` (the supervisor keeps `super_end`,
//! the worker gets `worker_end` dup2'd to fd 4). Over it the worker announces its
//! sessions (`register_master` + an `SCM_RIGHTS` dup of the pty master) and the
//! supervisor drives the handoff (`freeze_all` → `session_state`… → `adopt`… →
//! ack-gate → `shutdown` | `unfreeze`). The wire codec is `handoff_protocol.zig`
//! over `fdpass.zig` — Darwin-cmsg-only, so every handoff body here is macOS-only
//! (gated `if (comptime builtin.os.tag == .macos)`; a no-op / `error.Unsupported`
//! off macOS so the `src/host` tree still compiles on the Linux cloud box).
//!
//! ## The BROKER (the tested core)
//!
//! `brokerHandoff` is the pure protocol dance, factored to take the two
//! control-channel fds + the master registry so a unit test can drive it with two
//! `socketpair`s while playing BOTH mock workers. It NEVER leaves a window where
//! neither worker serves: on a healthy ack-gate it `shutdown`s v1 (v2 is live); on
//! ANY failed ack / timeout it `unfreeze`s v1 (the incumbent re-adopts + resumes)
//! and reports an error so the wrapper kills the stillborn v2.
//!
//! ## Handoff triggers
//!
//! Two things ASK for a handoff, both funneled to the reader/broker thread so the
//! broker never runs re-entrantly and there is never a second reader on the control
//! socket:
//!
//!   1. **SIGHUP** — the "a new build is installed, upgrade the worker" nudge
//!      (`kill(supervisor_pid, SIGHUP)`; how a later ForkSetup step drives an
//!      upgrade). The handler is async-signal-safe: it ONLY sets an atomic flag and
//!      writes one byte to the existing `reader_wake` self-pipe. The reader thread
//!      does the actual broker work on wake (never the signal handler).
//!   2. **Exec-path staleness self-check** — folded into the reader's `poll`
//!      timeout (no busy loop). Every `STALENESS_CHECK_INTERVAL_MS` the reader asks
//!      macOS `libproc` `proc_pidpath` for the live worker's CURRENT exec path; if
//!      that no longer resolves (the exec file was unlinked — `ENOENT`, exactly the
//!      EPERM-bug condition) OR no longer equals the canonical worker path (the
//!      bundle moved / was replaced), it hands off to a v2 spawned from the
//!      RE-RESOLVED canonical path — so afterwards the live worker again executes a
//!      path that resolves (the EPERM fix). It also `proc_pidpath`s the supervisor's
//!      OWN pid and just warns if IT is stale (a stable supervisor install is a
//!      deploy concern — it does NOT self-exec here).
//!
//! Both re-resolve the canonical path AT TRIGGER TIME (`--worker=` if configured,
//! else the supervisor's own `selfExePath`) and COALESCE: a handoff already in
//! flight is never re-entered; piled-up SIGHUPs collapse to one follow-up via the
//! swap-to-false flag. The pure staleness DECISION (`workerPathStale`) and the
//! `proc_pidpath` helper (`workerExecPath`) are unit-tested; the SIGHUP delivery +
//! timer-driven firing are smoke-only.
//!
//! ## Out of scope (this cut)
//!
//! A worker CRASH loses that worker's sessions for now (see `handleWorkerCrash`).

const Supervisor = @This();

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Allocator = std.mem.Allocator;

const Server = @import("Server.zig");

/// FORK(host-handoff): the handoff codec + fd-passing, gated to macOS exactly like
/// `Server.handoff` — an empty struct off macOS, and every reference lives inside
/// an `if (comptime builtin.os.tag == .macos)` block (never analyzed off macOS),
/// so the Darwin-only `@compileError` in these modules is never tripped on Linux.
const codec = if (builtin.os.tag == .macos) struct {
    pub const proto = @import("handoff_protocol.zig");
    pub const fdpass = @import("fdpass.zig");
} else struct {};

/// FORK(host-handoff): macOS `libproc` — the exec-path staleness self-check's only
/// external dependency. Gated to macOS exactly like `codec` (an empty struct off
/// macOS), so the `proc_pidpath` extern symbol is never REFERENCED and thus never
/// link-required on the Linux cloud-box host build.
const libproc = if (builtin.os.tag == .macos) struct {
    /// `int proc_pidpath(int pid, void *buffer, uint32_t buffersize)` — writes the
    /// process's CURRENT executable path into `buffer`, returning the byte length on
    /// success or 0 on failure (errno set; `ENOENT` when the exec file was
    /// unlinked). From `<libproc.h>` / `<sys/proc_info.h>`.
    pub extern "c" fn proc_pidpath(pid: c_int, buffer: [*]u8, buffersize: u32) c_int;
} else struct {};

/// `PROC_PIDPATHINFO_MAXSIZE` from `<sys/proc_info.h>` — the buffer `proc_pidpath`
/// wants. A plain constant (safe on every target); the extern above is macOS-gated.
pub const PROC_PIDPATHINFO_MAXSIZE: usize = 4 * 1024;

const log = std.log.scoped(.host_supervisor);

// ===========================================================================
// FORK(host-handoff): SIGHUP trigger state. `--supervise` is the sole process
// role, so exactly ONE Supervisor exists per process and a file-level global is
// the right home for the state the async-signal-safe handler touches. The handler
// may ONLY set an atomic + write a byte to a self-pipe — no alloc, no logging, no
// handoff work — so the broker always runs on the reader thread, never in signal
// context. `g_sighup_wake_fd` mirrors the live supervisor's `reader_wake[1]`;
// `g_sighup_pending` is the coalescing flag the reader swaps to false on consume.
// ===========================================================================

var g_sighup_wake_fd: std.atomic.Value(posix.fd_t) = .init(-1);
var g_sighup_pending: std.atomic.Value(bool) = .init(false);

/// FORK(host-handoff): the SIGHUP handler. Async-signal-safe ONLY: set the
/// coalescing flag + nudge the reader's `poll` via a 1-byte self-pipe write. errno
/// is saved/restored so a signal landing between an interrupted syscall and its
/// errno check does not clobber it.
fn sighupHandler(_: i32) callconv(.c) void {
    const saved_errno = std.c._errno().*;
    g_sighup_pending.store(true, .release);
    const fd = g_sighup_wake_fd.load(.acquire);
    if (fd >= 0) _ = posix.write(fd, &[_]u8{1}) catch {};
    std.c._errno().* = saved_errno;
}

/// FORK(host-handoff): install the SIGHUP handler. Called from `run()` AFTER
/// `reader_wake` is created and its write end published to `g_sighup_wake_fd`, so a
/// signal that arrives immediately has a valid fd to nudge. macOS-only (the whole
/// supervisor is); a no-op elsewhere.
fn installSighupHandler() void {
    if (comptime builtin.os.tag != .macos) return;
    var sa: posix.Sigaction = .{
        .handler = .{ .handler = sighupHandler },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.HUP, &sa, null);
}

// ===========================================================================
// FORK(host-handoff): exec-path staleness self-check — pure decision + libproc
// resolver. The worker is spawned from the canonical path, so after any triggered
// handoff the live worker executes a path that resolves (the EPERM fix).
// ===========================================================================

/// FORK(host-handoff): the PURE staleness decision (unit-tested). A worker is stale
/// when its CURRENT exec path can no longer be resolved (`resolved == null` —
/// `proc_pidpath` failed / `ENOENT`, i.e. the exec file was unlinked) OR when the
/// resolved path no longer matches the canonical worker path (the bundle moved /
/// was replaced). Pure (only `std.mem.eql`), so it runs on every target.
pub fn workerPathStale(resolved: ?[]const u8, canonical: []const u8) bool {
    const path = resolved orelse return true;
    return !std.mem.eql(u8, path, canonical);
}

/// FORK(host-handoff): resolve `pid`'s CURRENT executable path via macOS
/// `proc_pidpath`. Returns `null` when the path can't be resolved — most importantly
/// `ENOENT`, exactly the "exec file was unlinked" condition behind the EPERM bug.
/// `buf` is caller-owned and must be at least `PROC_PIDPATHINFO_MAXSIZE`; the
/// returned slice points into it. macOS-only (returns `null` elsewhere).
pub fn workerExecPath(pid: posix.pid_t, buf: []u8) ?[]const u8 {
    if (comptime builtin.os.tag != .macos) return null;
    std.debug.assert(buf.len >= PROC_PIDPATHINFO_MAXSIZE);
    const n = libproc.proc_pidpath(@intCast(pid), buf.ptr, @intCast(buf.len));
    if (n <= 0) return null; // 0 = failure (errno set; ENOENT = exec path unlinked)
    return buf[0..@intCast(n)];
}

/// Default ceiling on how long the broker waits for any single worker response
/// (a freeze frame, an adopt ack, a ready). A hung/deadlocked successor must ABORT
/// the handoff (→ `unfreeze` the incumbent) rather than wedge the supervisor
/// forever. Generous: a real freeze+serialize of large scrollback is well under a
/// second, but a loaded machine mid-deploy can be slow.
pub const DEFAULT_BROKER_TIMEOUT_MS: i32 = 10_000;

/// FORK(host-handoff): how often the reader loop re-runs the exec-path staleness
/// self-check. It is ALSO the reader's `poll` timeout, so an idle control channel
/// still wakes to run the check on this cadence — the check is "folded into the
/// poll timeout", never a busy loop.
pub const STALENESS_CHECK_INTERVAL_MS: i32 = 5_000;
const STALENESS_CHECK_INTERVAL_NS: u64 = @as(u64, @intCast(STALENESS_CHECK_INTERVAL_MS)) * std.time.ns_per_ms;

// ===========================================================================
// Master registry — the supervisor's per-session pty-master dups + child pids.
// Populated from workers' `register_master` announcements; the source of the
// `adopt` fd + child pid during a handoff. Supervisor-lifetime: entries persist
// across worker swaps (a handoff re-points the ACTIVE control channel, not the
// masters), and are dropped only on `unregister_master` (an explicit session
// close) or supervisor teardown.
// ===========================================================================

/// One registered session: the supervisor's OWN dup of the pty master (kept open
/// so a worker crash does not SIGHUP the child) + the child pid (handed to a
/// successor in `adopt`).
pub const MasterEntry = struct {
    master_fd: posix.fd_t,
    child_pid: posix.pid_t,
};

/// A thread-safe `session_id -> MasterEntry` map. The reader thread inserts/drops;
/// the broker reads. Its own mutex is a leaf (no other lock taken while held).
pub const MasterRegistry = struct {
    map: std.AutoHashMap(u64, MasterEntry),
    mutex: std.Thread.Mutex = .{},

    pub fn init(alloc: Allocator) MasterRegistry {
        return .{ .map = std.AutoHashMap(u64, MasterEntry).init(alloc) };
    }

    /// Close every held master fd and free the map. Call on supervisor teardown or
    /// a worker crash (the children are gone / owned by a successor).
    pub fn deinit(self: *MasterRegistry) void {
        self.mutex.lock();
        var it = self.map.iterator();
        while (it.next()) |kv| posix.close(kv.value_ptr.master_fd);
        self.mutex.unlock();
        self.map.deinit();
    }

    /// Insert (or replace) the entry for `id`. If an entry already exists (a
    /// double `register_master`), its old fd is closed first so it does not leak.
    pub fn put(self: *MasterRegistry, id: u64, entry: MasterEntry) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.map.fetchRemove(id)) |old| posix.close(old.value.master_fd);
        try self.map.put(id, entry);
    }

    /// Look up the entry for `id` (a copy — the fd is a shared kernel handle).
    pub fn get(self: *MasterRegistry, id: u64) ?MasterEntry {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.map.get(id);
    }

    /// Drop + close the master for `id` (an `unregister_master`). No-op if absent.
    pub fn remove(self: *MasterRegistry, id: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.map.fetchRemove(id)) |old| posix.close(old.value.master_fd);
    }

    /// Close + drop EVERY entry (a worker crash: the masters this worker owned are
    /// gone). Keeps the map allocated for reuse.
    pub fn clear(self: *MasterRegistry) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.map.iterator();
        while (it.next()) |kv| posix.close(kv.value_ptr.master_fd);
        self.map.clearRetainingCapacity();
    }

    pub fn count(self: *MasterRegistry) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.map.count();
    }
};

// ===========================================================================
// Argv parsing — pure, cross-platform, unit-testable (no process spawning).
// ===========================================================================

/// The three fork-added run modes plus the two pre-existing ones, resolved from
/// argv. `main_host.zig` builds the arg slice from real argv and dispatches on
/// this; a test builds a literal slice and asserts the parse.
pub const Mode = union(enum) {
    /// `--supervise --listen=<path> [--worker=<path>]`
    supervise: struct { listen_path: []const u8, worker_path: ?[]const u8 },
    /// `--handoff-worker --listen-fd=<N> --control-fd=<M> [--listen=<path>]`
    handoff_worker: WorkerArgs,
    /// The pre-existing standalone `--listen=<path>` (or bare positional) Server.
    listen: []const u8,
    /// The pre-existing Phase-1 stdout-diff harness (no recognized args).
    stdout_diff,
};

/// Parsed `--handoff-worker` fds. `listen_path` is informational (the listener at
/// `listen_fd` is already bound; the worker only uses the path for logging).
pub const WorkerArgs = struct {
    listen_fd: posix.fd_t,
    control_fd: posix.fd_t,
    listen_path: ?[]const u8 = null,
};

const ParseError = error{
    /// A `--supervise`/`--handoff-worker` flag was present but a required
    /// companion arg (`--listen=`, `--listen-fd=`, `--control-fd=`) was missing or
    /// non-numeric.
    MissingRequiredArg,
    InvalidFdArg,
};

fn argValue(arg: []const u8, comptime key: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, arg, key)) return arg[key.len..];
    return null;
}

/// Resolve the run mode from `args` (argv WITHOUT argv[0]). The two fork modes win
/// over the pre-existing paths because `--supervise`/`--handoff-worker` argv also
/// carry `--listen=`, which must NOT be mistaken for the standalone Server. Pure —
/// no process/global state touched — so it is directly unit-tested.
pub fn parseMode(args: []const []const u8) ParseError!Mode {
    var supervise = false;
    var handoff_worker = false;
    var listen_path: ?[]const u8 = null;
    var worker_path: ?[]const u8 = null;
    var listen_fd: ?posix.fd_t = null;
    var control_fd: ?posix.fd_t = null;
    var bare_positional: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--supervise")) {
            supervise = true;
        } else if (std.mem.eql(u8, arg, "--handoff-worker")) {
            handoff_worker = true;
        } else if (argValue(arg, "--listen=")) |v| {
            listen_path = v;
        } else if (argValue(arg, "--worker=")) |v| {
            worker_path = v;
        } else if (argValue(arg, "--listen-fd=")) |v| {
            listen_fd = std.fmt.parseInt(posix.fd_t, v, 10) catch return error.InvalidFdArg;
        } else if (argValue(arg, "--control-fd=")) |v| {
            control_fd = std.fmt.parseInt(posix.fd_t, v, 10) catch return error.InvalidFdArg;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            bare_positional = arg;
        }
    }

    if (handoff_worker) {
        return .{ .handoff_worker = .{
            .listen_fd = listen_fd orelse return error.MissingRequiredArg,
            .control_fd = control_fd orelse return error.MissingRequiredArg,
            .listen_path = listen_path,
        } };
    }
    if (supervise) {
        return .{ .supervise = .{
            .listen_path = listen_path orelse return error.MissingRequiredArg,
            .worker_path = worker_path,
        } };
    }
    // Pre-existing behavior, byte-for-byte: `--listen=<path>` or a bare positional
    // path → standalone Server; otherwise the Phase-1 stdout-diff harness.
    if (listen_path orelse bare_positional) |p| return .{ .listen = p };
    return .stdout_diff;
}

// ===========================================================================
// Supervisor lifecycle.
// ===========================================================================

alloc: Allocator,

/// The bound, listening AF_UNIX socket. Owned by the supervisor for its whole
/// life; dup2'd into each worker's fd 3. FD_CLOEXEC is set (it reaches a worker
/// via dup2, not raw inheritance), so it never leaks as a stray fd into an exec'd
/// worker.
listen_fd: posix.socket_t,
/// The socket path, owned (freed on deinit). The supervisor keeps it bound across
/// worker swaps; only IT unlinks it (on deinit), never a worker.
socket_path: []const u8,
/// `--worker=<path>`-resolvable ghostty-host binary to exec in worker mode,
/// null-terminated for `execveZ`. Defaults to the supervisor's own resolved exec
/// path (`std.fs.selfExePath`) — same-binary, different mode.
worker_path_z: [:0]u8,
/// FORK(host-handoff): true iff `--worker=` was explicitly configured. When true
/// the canonical worker path is that fixed configured path (`worker_path_z`); when
/// false it is the supervisor's own current `selfExePath`, RE-RESOLVED at each
/// trigger so a triggered handoff always spawns v2 from the live binary.
worker_path_explicit: bool = false,
/// Pre-built `"--listen=<path>"` argv entry (null-terminated), so `spawnWorker`
/// does no allocation between fork and exec (UB) — it is built once at init.
listen_arg_z: [:0]u8,

/// The supervisor's per-session pty-master dups.
registry: MasterRegistry,

/// The control channel to the CURRENTLY-live worker + that worker's pid. Written
/// only on the reader thread (initial spawn, crash-restart, handoff commit).
active_super_end: posix.socket_t = -1,
active_worker_pid: posix.pid_t = -1,

/// The reader/broker thread: the SOLE owner of `active_super_end`. It handles
/// `register_master`/`unregister_master`, detects a worker crash (channel EOF),
/// and runs `brokerHandoff` INLINE when `handoff()` posts a request (so there is
/// never a second reader competing for the same control socket).
reader_thread: ?std.Thread = null,
/// Self-pipe to wake the reader out of its `poll` (a posted handoff request or a
/// shutdown). `[0]` = read end (polled), `[1]` = write end.
reader_wake: [2]posix.fd_t = .{ -1, -1 },
reader_mutex: std.Thread.Mutex = .{},
reader_cond: std.Thread.Condition = .{},

/// A pending handoff posted by `handoff()` for the reader thread to execute.
handoff_request: ?HandoffRequest = null,
/// Set by the reader thread once it has executed the posted handoff; wakes the
/// `handoff()` caller waiting on `reader_cond`.
handoff_done: bool = false,
handoff_result: HandoffError!void = {},

/// FORK(host-handoff): monotonic timestamp of the last exec-path staleness check,
/// so the reader runs it at most once per `STALENESS_CHECK_INTERVAL_MS` no matter
/// how often `poll` returns. Owned by the reader thread. `null` before the first.
last_staleness_check: ?std.time.Instant = null,

/// Cleared to stop the reader thread + break `run`'s park.
running: std.atomic.Value(bool) = .init(true),

const HandoffRequest = struct {
    v2_super_end: posix.socket_t,
    v2_pid: posix.pid_t,
    timeout_ms: i32,
};

/// A freshly forked+exec'd worker: the pid to reap + the control channel to it.
const SpawnedWorker = struct {
    pid: posix.pid_t,
    super_end: posix.socket_t,
};

/// Bind the listen socket (owned forever) and resolve the worker binary. Does NOT
/// spawn a worker or start threads — `run()` does that. macOS-only (the handoff
/// rides Darwin cmsg); returns `error.Unsupported` elsewhere.
pub fn init(alloc: Allocator, socket_path: []const u8, worker_path: ?[]const u8) !*Supervisor {
    if (comptime builtin.os.tag != .macos) {
        log.warn("--supervise is macOS-only (the handoff rides the Darwin SCM_RIGHTS cmsg ABI)", .{});
        return error.Unsupported;
    }

    const self = try alloc.create(Supervisor);
    errdefer alloc.destroy(self);

    const path_dup = try alloc.dupe(u8, socket_path);
    errdefer alloc.free(path_dup);

    // Resolve the worker binary: an explicit `--worker=` or the supervisor's own
    // exec path (same binary, `--handoff-worker` mode). NUL-terminate for execveZ.
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const worker_path_resolved = worker_path orelse try std.fs.selfExePath(&exe_buf);
    const worker_path_z = try alloc.dupeZ(u8, worker_path_resolved);
    errdefer alloc.free(worker_path_z);

    const listen_arg_z = try std.fmt.allocPrintSentinel(alloc, "--listen={s}", .{socket_path}, 0);
    errdefer alloc.free(listen_arg_z);

    const fd = try Server.bindListenSocket(socket_path);
    errdefer posix.close(fd);
    // The listener reaches a worker via dup2→fd 3, never raw inheritance, so mark
    // it CLOEXEC: a forked-but-not-yet-dup2'd worker never leaks a stray listener.
    setCloexec(fd);

    self.* = .{
        .alloc = alloc,
        .listen_fd = fd,
        .socket_path = path_dup,
        .worker_path_z = worker_path_z,
        .worker_path_explicit = worker_path != null,
        .listen_arg_z = listen_arg_z,
        .registry = MasterRegistry.init(alloc),
    };
    return self;
}

pub fn deinit(self: *Supervisor) void {
    self.running.store(false, .release);
    // Wake + join the reader thread (it owns active_super_end).
    if (self.reader_thread) |t| {
        self.wakeReader();
        t.join();
        self.reader_thread = null;
    }
    // FORK(host-handoff): stop the SIGHUP handler from touching the wake fd we are
    // about to close (the handler becomes a no-op once the fd reads back < 0), and
    // restore the default disposition so a late signal can't reach a torn-down
    // supervisor.
    if (comptime builtin.os.tag == .macos) {
        g_sighup_wake_fd.store(-1, .release);
        var dfl: posix.Sigaction = .{
            .handler = .{ .handler = posix.SIG.DFL },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        posix.sigaction(posix.SIG.HUP, &dfl, null);
    }
    if (self.reader_wake[0] != -1) posix.close(self.reader_wake[0]);
    if (self.reader_wake[1] != -1) posix.close(self.reader_wake[1]);

    // Kill + reap the live worker (if any); its sessions cannot survive without a
    // supervisor to broker them.
    if (comptime builtin.os.tag == .macos) {
        if (self.active_worker_pid > 0) {
            posix.kill(self.active_worker_pid, posix.SIG.KILL) catch {};
            _ = posix.waitpid(self.active_worker_pid, 0);
        }
        if (self.active_super_end != -1) posix.close(self.active_super_end);
    }

    self.registry.deinit();
    posix.close(self.listen_fd);
    posix.unlink(self.socket_path) catch {};
    self.alloc.free(self.socket_path);
    self.alloc.free(self.worker_path_z);
    self.alloc.free(self.listen_arg_z);
    const alloc = self.alloc;
    alloc.destroy(self);
}

/// Spawn the initial worker + the reader thread, then park until `running` clears.
/// This is the launchd entrypoint body (`main_host.zig`'s `--supervise` branch).
pub fn run(self: *Supervisor) !void {
    if (comptime builtin.os.tag != .macos) return error.Unsupported;

    self.reader_wake = try posix.pipe();

    // FORK(host-handoff): publish the reader wake fd, THEN install the SIGHUP
    // handler — a SIGHUP now nudges the reader thread to broker a handoff to the
    // re-resolved canonical worker (the "a new build is installed" trigger). Order
    // matters: the handler must find a valid fd if a signal arrives immediately.
    g_sighup_wake_fd.store(self.reader_wake[1], .release);
    installSighupHandler();

    const w = try self.spawnWorker(self.worker_path_z);
    self.active_super_end = w.super_end;
    self.active_worker_pid = w.pid;
    log.info("supervisor: worker {d} serving on {s}", .{ w.pid, self.socket_path });

    self.reader_thread = try std.Thread.spawn(.{}, readerLoop, .{self});

    // Park. A future SIGTERM handler flips `running`; `deinit` tears down. The
    // handoff TRIGGERS (SIGHUP + the periodic exec-path staleness self-check) run on
    // the reader thread — see `readerLoop` / `triggerSelfHandoff`.
    while (self.running.load(.acquire)) std.Thread.sleep(1 * std.time.ns_per_s);
}

/// FORK(host-handoff): fork+exec a worker in `--handoff-worker` mode. The listener
/// reaches it at fd 3 and the fresh control socket at fd 4 by the dup2 dance in
/// `childExecWorker` (fd-inheritance across execve). The parent keeps `super_end`
/// (its control channel to this worker) and the supervisor's own `listen_fd`.
fn spawnWorker(self: *Supervisor, worker_path_z: [:0]const u8) !SpawnedWorker {
    if (comptime builtin.os.tag != .macos) return error.Unsupported;

    var sv: [2]posix.fd_t = undefined;
    if (std.c.socketpair(@intCast(posix.AF.UNIX), @intCast(posix.SOCK.STREAM), 0, &sv) != 0) {
        return error.SocketpairFailed;
    }
    const super_end = sv[0];
    const worker_end = sv[1];
    // super_end is the supervisor's private end and MUST NOT leak into the exec'd
    // worker (a leaked copy would keep the socket open and defeat crash EOF
    // detection); worker_end reaches the worker via dup2→fd 4, not raw inherit.
    // CLOEXEC on both, cleared by dup2 only on the fd 4 target in the child.
    setCloexec(super_end);
    setCloexec(worker_end);

    // Build argv BEFORE fork (allocation between fork and exec is UB). Every entry
    // is a stable NUL-terminated string that outlives the child (self-owned or a
    // literal).
    const argv = [_:null]?[*:0]const u8{
        worker_path_z.ptr,
        "--handoff-worker",
        "--listen-fd=3",
        "--control-fd=4",
        self.listen_arg_z.ptr,
    };

    const pid = posix.fork() catch |err| {
        posix.close(super_end);
        posix.close(worker_end);
        return err;
    };

    if (pid == 0) {
        // CHILD: never returns (execve or _exit). No allocation, no defers.
        childExecWorker(self.listen_fd, worker_end, worker_path_z.ptr, &argv);
    }

    // PARENT.
    posix.close(worker_end);
    return .{ .pid = pid, .super_end = super_end };
}

/// FORK(host-handoff): the child half of `spawnWorker` — async-signal-safe (no
/// allocation, no locks). Places the listener at fd 3 and the control socket at
/// fd 4 with FD_CLOEXEC CLEARED (so both survive execve), then execs the worker.
/// The dup-out-of-the-way-first pattern (`F_DUPFD` → ≥10) makes the two dup2s
/// collision-proof even if `listen_fd`/`ctrl_fd` already occupy 3 or 4.
fn childExecWorker(
    listen_fd: posix.fd_t,
    ctrl_fd: posix.fd_t,
    path: [*:0]const u8,
    argv: *const [5:null]?[*:0]const u8,
) noreturn {
    // Move both sources above the 3/4 target range (F_DUPFD returns the lowest fd
    // ≥ arg, always with CLOEXEC CLEARED — the copies survive exec until we dup2).
    // fcntl returns usize; narrow to fd_t up front so dup2/close both take it.
    const t_listen: posix.fd_t = @intCast(posix.fcntl(listen_fd, posix.F.DUPFD, 10) catch posix.exit(126));
    const t_ctrl: posix.fd_t = @intCast(posix.fcntl(ctrl_fd, posix.F.DUPFD, 10) catch posix.exit(126));
    // dup2 clears CLOEXEC on the NEW fd, so fd 3 / fd 4 survive execve.
    posix.dup2(t_listen, 3) catch posix.exit(126);
    posix.dup2(t_ctrl, 4) catch posix.exit(126);
    posix.close(t_listen);
    posix.close(t_ctrl);
    // Belt-and-suspenders: explicitly clear CLOEXEC on the targets (dup2 already
    // did, but a future dup3/O_CLOEXEC change must not silently break inheritance).
    clearCloexec(3);
    clearCloexec(4);
    // execveZ only RETURNS on failure (its return type is the error set itself).
    // In a post-fork child there is nothing safe to do but die; encode the failure
    // class in the exit code (127 = binary not found, else 126). No logging/alloc
    // here — that is not async-signal-safe after fork.
    const exec_err = posix.execveZ(path, argv, std.c.environ);
    posix.exit(if (exec_err == error.FileNotFound) 127 else 126);
}

fn setCloexec(fd: posix.fd_t) void {
    const flags = posix.fcntl(fd, posix.F.GETFD, 0) catch return;
    _ = posix.fcntl(fd, posix.F.SETFD, flags | posix.FD_CLOEXEC) catch {};
}

fn clearCloexec(fd: posix.fd_t) void {
    const flags = posix.fcntl(fd, posix.F.GETFD, 0) catch return;
    if (flags & posix.FD_CLOEXEC != 0) {
        _ = posix.fcntl(fd, posix.F.SETFD, flags & ~@as(usize, posix.FD_CLOEXEC)) catch {};
    }
}

/// Wake the reader thread out of its `poll` (a posted handoff request or a stop).
fn wakeReader(self: *Supervisor) void {
    if (self.reader_wake[1] == -1) return;
    _ = posix.write(self.reader_wake[1], &[_]u8{1}) catch {};
}

// ===========================================================================
// The reader/broker thread — sole owner of `active_super_end`.
// ===========================================================================

fn readerLoop(self: *Supervisor) void {
    // Wrap the WHOLE body in `if (comptime macos)` (Server.zig's discipline): off
    // macOS the block is comptime-dead and its `codec.proto` references are never
    // analyzed, so the `src/host` tree still compiles on the Linux cloud box even
    // though `run` references this function.
    if (comptime builtin.os.tag == .macos) {
        while (self.running.load(.acquire)) {
            var pfds = [_]posix.pollfd{
                .{ .fd = self.active_super_end, .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = self.reader_wake[0], .events = posix.POLL.IN, .revents = 0 },
            };
            // FORK(host-handoff): a FINITE timeout (not -1) so the exec-path
            // staleness self-check still runs when the control channel is idle —
            // folded into the poll timeout, never a busy loop.
            _ = posix.poll(&pfds, STALENESS_CHECK_INTERVAL_MS) catch continue;
            if (!self.running.load(.acquire)) return;

            // FORK(host-handoff): (A) periodic exec-path staleness self-check
            // (time-gated to once per interval regardless of poll frequency). A
            // stale worker triggers a self-handoff to the re-resolved canonical
            // path; then re-poll on the FRESH channel (this iteration's `pfds` now
            // reference the retired worker's fd).
            if (self.stalenessCheckDue()) {
                if (self.checkWorkerStalenessAndMaybeHandoff()) continue;
            }

            // (B) Wake pipe: a SIGHUP self-handoff, a posted external handoff, or a
            // stop.
            if (pfds[1].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR) != 0) {
                var drain: [64]u8 = undefined;
                _ = posix.read(self.reader_wake[0], &drain) catch {};
                if (!self.running.load(.acquire)) return;
                // FORK(host-handoff): SIGHUP -> self-handoff to the canonical worker
                // path. Coalesced: many piled-up signals collapse into one via the
                // swap-to-false flag. Then service any external `handoff()` post
                // (a no-op if none) so both triggers can be honored in one wake.
                if (g_sighup_pending.swap(false, .acq_rel)) {
                    self.triggerSelfHandoff(null);
                }
                self.serviceHandoffRequest();
                continue;
            }

            // (C) Control frame from the live worker.
            if (pfds[0].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR) != 0) {
                var fds: [1]posix.fd_t = undefined;
                const r = codec.proto.recvFrame(self.active_super_end, &fds) catch |err| {
                    // Channel closed / errored: the live worker died UNEXPECTEDLY (a
                    // handoff shutdown is handled inline in `serviceHandoffRequest`,
                    // which swaps the channel before returning here — so a failure in
                    // the steady-state loop is always a crash).
                    log.warn("worker {d} control channel error ({}); respawning", .{ self.active_worker_pid, err });
                    self.handleWorkerCrash();
                    continue;
                };
                self.handleWorkerFrame(r.frame, &fds, r.fd_count);
            }
        }
    }
}

/// Handle one worker→supervisor announcement. Only `register_master` /
/// `unregister_master` are expected on the steady-state channel; any handoff
/// response frame is consumed inline by the broker, never here.
fn handleWorkerFrame(self: *Supervisor, frame: codec.proto.Frame, fds: []posix.fd_t, fd_count: usize) void {
    if (comptime builtin.os.tag != .macos) return;
    switch (frame.tag) {
        .register_master => {
            if (fd_count < 1) {
                log.warn("register_master session={d} without a master fd; ignoring", .{frame.session_id});
                return;
            }
            self.registry.put(frame.session_id, .{
                .master_fd = fds[0],
                .child_pid = @intCast(frame.aux),
            }) catch |err| {
                log.warn("register_master store failed session={d} err={}", .{ frame.session_id, err });
                posix.close(fds[0]);
            };
        },
        .unregister_master => {
            self.registry.remove(frame.session_id);
        },
        else => {
            for (fds[0..fd_count]) |fd| posix.close(fd);
            log.warn("supervisor: unexpected worker frame tag {} on the steady-state channel", .{frame.tag});
        },
    }
}

/// Execute a handoff request posted by `handoff()` INLINE on the reader thread (so
/// no second reader competes for `active_super_end`). On SUCCESS the live worker
/// becomes v2 (channel + pid swapped, predecessor reaped); on ABORT the incumbent
/// keeps serving (the broker already `unfreeze`d it) and v2 is killed.
fn serviceHandoffRequest(self: *Supervisor) void {
    if (comptime builtin.os.tag != .macos) return;
    const req = blk: {
        self.reader_mutex.lock();
        defer self.reader_mutex.unlock();
        const r = self.handoff_request;
        self.handoff_request = null;
        break :blk r;
    } orelse return;

    const result = brokerHandoff(
        self.alloc,
        self.active_super_end,
        req.v2_super_end,
        &self.registry,
        req.timeout_ms,
    );

    self.finishHandoff(req.v2_super_end, req.v2_pid, result);

    self.reader_mutex.lock();
    self.handoff_result = result;
    self.handoff_done = true;
    self.reader_cond.signal();
    self.reader_mutex.unlock();
}

/// FORK(host-handoff): commit a successful handoff (swap the active channel to v2,
/// reap the retired v1) or clean up an aborted one (kill the stillborn v2). Shared
/// by the external `handoff()` path (`serviceHandoffRequest`) and the self-triggered
/// SIGHUP/staleness path (`triggerSelfHandoff`). Runs on the reader thread — the
/// sole writer of `active_super_end`/`active_worker_pid`.
fn finishHandoff(
    self: *Supervisor,
    v2_super_end: posix.socket_t,
    v2_pid: posix.pid_t,
    result: HandoffError!void,
) void {
    if (comptime builtin.os.tag != .macos) return;
    if (result) |_| {
        // SUCCESS: v2 is live. The broker already `shutdown` v1; reap it, drop the
        // old channel, and commit v2 as the active worker. The master registry
        // ENTRIES are unchanged (still-valid dups) — the handoff re-points the
        // active control channel, it does not re-register the masters.
        _ = posix.waitpid(self.active_worker_pid, 0);
        posix.close(self.active_super_end);
        self.active_super_end = v2_super_end;
        self.active_worker_pid = v2_pid;
        log.info("handoff committed: worker {d} now serving", .{v2_pid});
    } else |err| {
        // ABORT: the incumbent (v1) survives (the broker `unfreeze`d it). Kill the
        // stillborn v2 and drop its channel; `active_*` stay pointed at v1.
        log.warn("handoff aborted ({}); incumbent {d} resumes", .{ err, self.active_worker_pid });
        posix.kill(v2_pid, posix.SIG.KILL) catch {};
        _ = posix.waitpid(v2_pid, 0);
        posix.close(v2_super_end);
    }
}

/// FORK(host-handoff): true once per `STALENESS_CHECK_INTERVAL_MS`. Consults +
/// advances the reader-owned `last_staleness_check` clock so the staleness check
/// runs on a fixed cadence no matter how often `poll` returns. A clock error just
/// returns true (run the check) — the poll timeout still bounds the frequency.
fn stalenessCheckDue(self: *Supervisor) bool {
    const now = std.time.Instant.now() catch return true;
    if (self.last_staleness_check) |last| {
        if (now.since(last) < STALENESS_CHECK_INTERVAL_NS) return false;
    }
    self.last_staleness_check = now;
    return true;
}

/// FORK(host-handoff): resolve the canonical worker path AT TRIGGER TIME. An
/// explicit `--worker=` is a fixed configured path (reuse the init-resolved
/// `worker_path_z`); otherwise re-resolve the supervisor's OWN current exec path
/// (`selfExePath`) — the live binary IS the canonical current ghostty-host, so a
/// handoff spawned from it always executes a path that resolves. The returned slice
/// is either `worker_path_z` (explicit) or points into `buf` (selfExePath).
fn resolveCanonicalWorker(self: *Supervisor, buf: []u8) ![]const u8 {
    if (self.worker_path_explicit) return self.worker_path_z;
    return std.fs.selfExePath(buf);
}

/// FORK(host-handoff): the exec-path staleness self-check body (the EPERM-fix
/// trigger). Warns if the supervisor's OWN exec path is gone (a deploy concern — it
/// does NOT self-exec), then compares the live worker's `proc_pidpath` against the
/// re-resolved canonical path via the pure `workerPathStale`. On stale, hand off to
/// a v2 spawned from the canonical path. Returns true iff a handoff fired (so the
/// reader loop re-polls on the fresh channel). Reader thread only.
fn checkWorkerStalenessAndMaybeHandoff(self: *Supervisor) bool {
    if (comptime builtin.os.tag != .macos) return false;

    // Supervisor self-check: warn-only. A stable supervisor install is a deploy
    // concern; self-exec is deliberately out of scope here.
    var sup_buf: [PROC_PIDPATHINFO_MAXSIZE]u8 = undefined;
    if (workerExecPath(std.c.getpid(), &sup_buf) == null) {
        log.warn("supervisor's own exec path no longer resolves (binary unlinked); a supervisor upgrade is a deploy concern — not self-exec'ing", .{});
    }

    // Worker exec-path staleness.
    var canon_buf: [std.fs.max_path_bytes]u8 = undefined;
    const canonical = self.resolveCanonicalWorker(&canon_buf) catch |err| {
        // Can't resolve the canonical path -> nothing to compare against; skip
        // rather than churn a handoff we can't target.
        log.warn("staleness check: cannot resolve canonical worker path ({}); skipping", .{err});
        return false;
    };
    var worker_buf: [PROC_PIDPATHINFO_MAXSIZE]u8 = undefined;
    const resolved = workerExecPath(self.active_worker_pid, &worker_buf);

    if (!workerPathStale(resolved, canonical)) return false;

    log.info("worker {d} exec path stale (resolved={?s} canonical={s}); handing off to a fresh worker", .{ self.active_worker_pid, resolved, canonical });
    self.triggerSelfHandoff(canonical);
    return true;
}

/// FORK(host-handoff): broker a handoff to a fresh worker spawned from the canonical
/// path, with NO external `handoff()` caller waiting — the SIGHUP + staleness
/// triggers both land here. Re-resolves the canonical path (or uses `canonical_opt`
/// when the caller already resolved it) BEFORE the fork, spawns v2, runs the broker
/// inline, and commits/aborts via `finishHandoff`. On any pre-broker failure the
/// incumbent keeps serving untouched. Reader thread only.
fn triggerSelfHandoff(self: *Supervisor, canonical_opt: ?[]const u8) void {
    if (comptime builtin.os.tag != .macos) return;

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const canonical = canonical_opt orelse (self.resolveCanonicalWorker(&buf) catch |err| {
        log.warn("self-handoff: cannot resolve canonical worker path ({}); skipping", .{err});
        return;
    });
    // NUL-terminate for execveZ. Allocated in the PARENT before the fork (allocation
    // between fork and exec is UB), freed after spawnWorker returns.
    const canonical_z = self.alloc.dupeZ(u8, canonical) catch {
        log.warn("self-handoff: OOM building the worker path; skipping", .{});
        return;
    };
    defer self.alloc.free(canonical_z);

    const w = self.spawnWorker(canonical_z) catch |err| {
        log.warn("self-handoff: spawn successor failed ({}); incumbent {d} keeps serving", .{ err, self.active_worker_pid });
        return;
    };

    const result = brokerHandoff(self.alloc, self.active_super_end, w.super_end, &self.registry, DEFAULT_BROKER_TIMEOUT_MS);
    self.finishHandoff(w.super_end, w.pid, result);

    // Reset the staleness clock so a just-committed handoff (the worker is now
    // fresh) does not immediately re-trigger the check on the next loop.
    self.last_staleness_check = std.time.Instant.now() catch null;
}

/// FORK(host-handoff): the live worker crashed. FIRST CUT: a crash loses that
/// worker's sessions — close the held masters (SIGHUP-ing the now-orphaned
/// children) and bring up a fresh EMPTY worker so the GUI can reconnect and
/// respawn. Runs on the reader thread.
/// TODO(host-handoff): crash-recovery could re-adopt the held masters into the
/// fresh worker with BLANK terminals (the children survive as long as the
/// supervisor holds their masters), turning a crash into a soft reflow instead of
/// a session loss. Deferred — kept simple + correct for this cut.
fn handleWorkerCrash(self: *Supervisor) void {
    if (comptime builtin.os.tag != .macos) return;
    self.registry.clear();
    posix.close(self.active_super_end);
    _ = posix.waitpid(self.active_worker_pid, 0);
    self.active_super_end = -1;
    self.active_worker_pid = -1;

    const w = self.spawnWorker(self.worker_path_z) catch |err| {
        log.err("crash-restart: respawn failed err={}; supervisor idling", .{err});
        return;
    };
    self.active_super_end = w.super_end;
    self.active_worker_pid = w.pid;
    log.info("crash-restart: worker {d} serving (empty)", .{w.pid});
}

/// FORK(host-handoff): request a zero-downtime handoff to a fresh worker running
/// `new_worker_path` (or the configured worker binary if null). Spawns v2, then
/// posts the broker to the reader thread (the sole owner of `active_super_end`)
/// and blocks for the outcome. Returns `error.HandoffAborted` if the successor was
/// unhealthy (the incumbent kept serving). Callable from any thread.
pub fn handoff(self: *Supervisor, new_worker_path: ?[:0]const u8) HandoffError!void {
    if (comptime builtin.os.tag != .macos) return error.Unsupported;

    const w = self.spawnWorker(new_worker_path orelse self.worker_path_z) catch {
        return error.HandoffSpawnFailed;
    };

    self.reader_mutex.lock();
    self.handoff_request = .{
        .v2_super_end = w.super_end,
        .v2_pid = w.pid,
        .timeout_ms = DEFAULT_BROKER_TIMEOUT_MS,
    };
    self.handoff_done = false;
    self.reader_mutex.unlock();

    self.wakeReader();

    self.reader_mutex.lock();
    defer self.reader_mutex.unlock();
    while (!self.handoff_done) self.reader_cond.wait(&self.reader_mutex);
    return self.handoff_result;
}

// ===========================================================================
// The BROKER — the unit-tested protocol dance.
// ===========================================================================

pub const HandoffError = error{
    /// The health-ack gate failed (a nacked adopt or a response timeout). The
    /// incumbent was `unfreeze`d and keeps serving; the caller kills the successor.
    HandoffAborted,
    /// Spawning the successor process failed (fork/exec) — nothing was frozen.
    HandoffSpawnFailed,
    /// The supervisor is not macOS (no handoff transport).
    Unsupported,
    /// A control-channel send/recv/blob error against a worker (fatal to this
    /// handoff; the caller treats it like an abort but cannot cleanly `unfreeze`).
    ProtocolError,
    OutOfMemory,
};

/// FORK(host-handoff): the pure handoff protocol dance, factored out of the
/// process spawning so a unit test can drive it with two `socketpair`s while
/// playing BOTH mock workers (`v1_ctrl`/`v2_ctrl`) against a fake `registry`.
///
///   1. `freeze_all` → v1; collect `session_state{id, blob}`… until `freeze_done`.
///   2. For each frozen session look up its master dup + child pid in `registry`
///      and `adopt{id, blob_len, child_pid}` + the master (SCM_RIGHTS) + blob → v2.
///      (SCM_RIGHTS does NOT consume the supervisor's fd — it keeps holding it.)
///   3. HEALTH-ACK GATE: collect `adopt_ack{ok}` + `ready{count}` from v2. SUCCESS
///      iff EVERY session acked ok AND a `ready` reached the freeze count → send
///      `shutdown` to v1 (it exits; v2 is live). Otherwise ABORT → `unfreeze` v1
///      (it re-adopts + resumes) and return `error.HandoffAborted`. A nacked adopt
///      aborts IMMEDIATELY (no need to wait for the rest); a per-response timeout
///      also aborts. NEVER a window where neither worker serves.
///
/// On SUCCESS returns void (v1 got `shutdown`); on the health-gate failure returns
/// `error.HandoffAborted` (v1 got `unfreeze`). A raw transport failure surfaces as
/// `error.ProtocolError` (best-effort `unfreeze` first).
pub fn brokerHandoff(
    alloc: Allocator,
    v1_ctrl: posix.fd_t,
    v2_ctrl: posix.fd_t,
    registry: *MasterRegistry,
    timeout_ms: i32,
) HandoffError!void {
    // The WHOLE dance lives inside `if (comptime macos)` so its `codec.proto`
    // references (+ the handoff-typed helpers it calls) are never analyzed off
    // macOS — the `src/host` tree still compiles on the Linux cloud box.
    if (comptime builtin.os.tag != .macos) return error.Unsupported;
    const proto = codec.proto;

    // ---- 1. Freeze v1: collect the serialized sessions. -------------------
    const Frozen = struct { id: u64, blob: []u8 };
    var frozen: std.ArrayList(Frozen) = .empty;
    defer {
        for (frozen.items) |f| alloc.free(f.blob);
        frozen.deinit(alloc);
    }

    proto.sendFrame(v1_ctrl, .{ .tag = .freeze_all }, &.{}) catch return error.ProtocolError;

    while (true) {
        var fds: [1]posix.fd_t = undefined;
        const r = recvFrameTimeout(v1_ctrl, timeout_ms, &fds) catch {
            // v1 is unresponsive mid-freeze. We cannot cleanly resume it, but try:
            unfreezeQuietly(v1_ctrl);
            return error.ProtocolError;
        };
        // freeze frames carry no fd; close any stray one so it can't leak.
        for (fds[0..r.fd_count]) |fd| posix.close(fd);
        switch (r.frame.tag) {
            .session_state => {
                const blob = proto.readBlob(v1_ctrl, alloc, r.frame.aux) catch |err| {
                    unfreezeQuietly(v1_ctrl);
                    return if (err == error.OutOfMemory) error.OutOfMemory else error.ProtocolError;
                };
                frozen.append(alloc, .{ .id = r.frame.session_id, .blob = blob }) catch {
                    alloc.free(blob);
                    unfreezeQuietly(v1_ctrl);
                    return error.OutOfMemory;
                };
            },
            .freeze_done => break,
            else => {
                unfreezeQuietly(v1_ctrl);
                return error.ProtocolError;
            },
        }
    }

    const count = frozen.items.len;

    // ---- 2. Adopt each frozen session into v2. ----------------------------
    for (frozen.items) |f| {
        const entry = registry.get(f.id) orelse {
            // A frozen session with no held master is unrecoverable on v2 (nothing
            // to adopt). Abort: resume the incumbent.
            log.warn("handoff: no registered master for frozen session {d}; aborting", .{f.id});
            return abortUnfreeze(v1_ctrl);
        };
        // SCM_RIGHTS duplicates the fd into v2; the supervisor keeps holding its
        // own copy (insurance + a source for a future handoff), so do NOT close it.
        proto.sendFrame(v2_ctrl, .{
            .tag = .adopt,
            .session_id = f.id,
            .aux = f.blob.len,
            .aux2 = @intCast(entry.child_pid),
        }, &.{entry.master_fd}) catch return abortUnfreeze(v1_ctrl);
        proto.writeBlob(v2_ctrl, f.blob) catch return abortUnfreeze(v1_ctrl);
    }

    // ---- 3. Health-ack gate: collect acks + a ready from v2. --------------
    var ok_acks: usize = 0;
    var acks_seen: usize = 0;
    var ready_reached: bool = (count == 0); // a 0-session handoff needs no ready.
    while (acks_seen < count or !ready_reached) {
        var fds: [1]posix.fd_t = undefined;
        const r = recvFrameTimeout(v2_ctrl, timeout_ms, &fds) catch {
            // A hung/slow successor: abort, resume the incumbent.
            return abortUnfreeze(v1_ctrl);
        };
        for (fds[0..r.fd_count]) |fd| posix.close(fd);
        switch (r.frame.tag) {
            .adopt_ack => {
                acks_seen += 1;
                if (r.frame.aux == 1) {
                    ok_acks += 1;
                } else {
                    // A nacked adopt: the successor could not take a session. Abort
                    // NOW (do not wait for the remaining acks) and resume v1.
                    return abortUnfreeze(v1_ctrl);
                }
            },
            .ready => {
                if (r.frame.aux >= count) ready_reached = true;
            },
            else => {
                // An unexpected frame from the successor: treat as unhealthy.
                return abortUnfreeze(v1_ctrl);
            },
        }
    }

    // Gate: EVERY session acked ok AND the successor reached the freeze count.
    if (ok_acks == count and ready_reached) {
        // SUCCESS — the successor is serving. The predecessor may exit(0) now.
        proto.sendFrame(v1_ctrl, .{ .tag = .shutdown }, &.{}) catch return error.ProtocolError;
        return;
    }
    return abortUnfreeze(v1_ctrl);
}

/// Send `unfreeze` to v1 (resume the incumbent) and report the handoff aborted.
/// The single ABORT exit so "never a window where neither serves" holds: v1 is
/// told to resume before we return the error the caller uses to kill v2.
fn abortUnfreeze(v1_ctrl: posix.fd_t) HandoffError {
    if (comptime builtin.os.tag == .macos) {
        codec.proto.sendFrame(v1_ctrl, .{ .tag = .unfreeze }, &.{}) catch
            return error.ProtocolError;
    }
    return error.HandoffAborted;
}

/// Best-effort `unfreeze` when the broker is bailing on a transport error (no
/// return value threaded — the caller already has its error).
fn unfreezeQuietly(v1_ctrl: posix.fd_t) void {
    if (comptime builtin.os.tag == .macos) {
        codec.proto.sendFrame(v1_ctrl, .{ .tag = .unfreeze }, &.{}) catch {};
    }
}

/// `recvFrame` with a `poll`-based timeout so a hung worker aborts the handoff
/// instead of wedging the broker forever. A timeout is `error.Timeout`.
fn recvFrameTimeout(
    fd: posix.fd_t,
    timeout_ms: i32,
    fds_out: []posix.fd_t,
) (codec.proto.RecvFrameError || error{Timeout})!codec.proto.RecvResult {
    var pfds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
    const n = posix.poll(&pfds, timeout_ms) catch return error.Timeout;
    if (n == 0) return error.Timeout;
    return codec.proto.recvFrame(fd, fds_out);
}
