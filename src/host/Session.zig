//! Session is the Phase 1 single-session host harness. It owns one
//! terminal.Terminal + termio.Termio (.exec backend over a real pty +
//! child shell) + termio.Thread (libxev IO loop), plus the host-side render
//! sink that replaces the GPU renderer: a real renderer.State (inspector=null,
//! NO GPU), an xev.Async renderer_wakeup waited on a separate host render
//! loop, a stub renderer.Thread.Mailbox drained for {.resize,.reset_cursor_blink}
//! only, and an App.Mailbox-shaped queue drained (logged) for surface messages.
//!
//! No IPC, no apprt.embedded, no renderer impl, no Inspector. See the Phase 1
//! plan in .claude/plans/ptyhost-implementation-plan.md (§3.3, §7).
//!
//! Lifecycle: `create` (allocates a stable *Session and constructs everything,
//! including Termio) -> `start` (spawns the IO thread + arms the render loop)
//! -> `runRenderLoop` / `tickRenderLoop` -> `stop` -> `destroy`.

const Session = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const xev = @import("../global.zig").xev;
const global = @import("../global.zig");
const termio = @import("../termio.zig");
const renderer = @import("../renderer.zig");
const apprt = @import("../apprt.zig");
const App = @import("../App.zig");
const terminalpkg = @import("../terminal/main.zig");
const configpkg = @import("../config.zig");
const Config = configpkg.Config;
const internal_os = @import("../os/main.zig");
const Surface = @import("../Surface.zig");

const RenderState = @import("RenderState.zig");

const log = std.log.scoped(.host_session);

pub const Options = struct {
    /// Initial grid dimensions for the fabricated renderer.Size. The GUI
    /// computes real font metrics later; Phase 1 fabricates a fixed grid.
    cols: u16 = 80,
    rows: u16 = 24,

    /// Fixed cell size in pixels (fabricated; only used for width_px/height_px).
    cell_width: u32 = 8,
    cell_height: u32 = 16,
};

alloc: Allocator,
opts: Options,

/// The full config, owned by the session.
config: Config,

/// The fabricated size for the terminal grid.
size: renderer.Size,

/// The core terminal IO. Owns the terminal + child + StreamHandler.
io: termio.Termio,

/// The IO thread (libxev loop). Spawned in start(), joined in stop().
io_thread: termio.Thread,
io_thr: ?std.Thread = null,

/// The shared render state. inspector MUST stay null (no Inspector, no GPU).
render_mutex: std.Thread.Mutex = .{},
renderer_state: renderer.State,

/// The renderer wakeup. Notified from the IO thread; waited on the host
/// render loop.
renderer_wakeup: xev.Async,

/// The stub renderer mailbox. Drained handling ONLY .resize and
/// .reset_cursor_blink.
renderer_mailbox: *renderer.Thread.Mailbox,

/// The App.Mailbox-shaped queue, drained (Phase 1: logged) for the
/// apprt.surface.Message set.
app_queue: *App.Mailbox.Queue,

/// The headless apprt App value (zero-size, no-op wakeup).
rt_app: apprt.App = .{},

/// A heap *Surface used only for the surface_mailbox crash metadata. We set
/// only .size; the rest stays undefined (only read on crash).
surface: *Surface,

/// The host render loop (separate from the IO thread's private loop).
render_loop: xev.Loop,
wakeup_c: xev.Completion = .{},
render_stop: xev.Async,
render_stop_c: xev.Completion = .{},

/// A periodic poll timer that runs renderTick on a fixed interval. This is
/// the deterministic shutdown driver: a child-exit surface message is
/// delivered via the surface mailbox (App.Mailbox.push -> none.App.wakeup,
/// a no-op for the headless host), which does NOT notify renderer_wakeup. A
/// shell that exits with no trailing pty output therefore never wakes the
/// render loop via output, so without this timer the queued .child_exited
/// message would sit undrained forever and run(.until_done) would block
/// after the child died. The timer guarantees the app_queue is drained (and
/// thus child-exit observed -> render_stop notified) within one interval.
poll_timer: xev.Timer,
poll_timer_c: xev.Completion = .{},

/// Interval for poll_timer in milliseconds. Phase-1 shutdown is poll-driven;
/// this bounds the worst-case latency from child exit to host shutdown.
poll_interval_ms: u64 = 100,

/// The previous RenderState snapshot, for diffing.
prev_snapshot: ?RenderState.Snapshot = null,

/// Phase 2a render-tick push hook. Set by the Server so it can serialize and
/// broadcast a GridFrame (+ ModeFrame) to subscribers on each tick. Invoked at
/// the END of renderTick with the just-captured Snapshot (still owned by the
/// session; the callback must NOT free it). null in the Phase-1 stdout-diff
/// path, so the default behavior is unchanged.
on_render_ctx: ?*anyopaque = null,
on_render: ?*const fn (ctx: *anyopaque, self: *Session, snapshot: *const RenderState.Snapshot) void = null,

/// Phase 2a child-exit signal. Set by the Server to observe a .child_exited
/// surface message (with exit_code/runtime_ms) in addition to the existing
/// render_stop notify. Invoked from renderTick when the app queue drains a
/// .child_exited message. null in the Phase-1 path (unchanged behavior).
on_child_exited_ctx: ?*anyopaque = null,
on_child_exited: ?*const fn (ctx: *anyopaque, self: *Session, exit_code: u32, runtime_ms: u64) void = null,

/// Total changed rows across all render ticks. Bumped by renderTick; lets a
/// test observe that the wakeup-driven render path actually produced a diff
/// even though renderTick's return value is consumed inside the callback.
total_changed_rows: usize = 0,

/// Counts of renderer-mailbox messages the drain has handled, by class. Lets
/// a test assert the host-boundary contract that Termio pushes ONLY
/// {.resize, .reset_cursor_blink} (plan §6/§9 risk #9): unexpected_renderer
/// MUST stay 0. Any new Termio push kind would land in the `else` arm and
/// fail that assertion (the source-grep test in test.zig is the static
/// companion to this runtime counter).
renderer_resize_count: usize = 0,
renderer_reset_cursor_blink_count: usize = 0,
unexpected_renderer_count: usize = 0,

/// Set true by renderStopCallback when the render loop has been told to stop
/// (via render_stop, including the child-exit path). Lets a test observe that
/// shutdown actually fired without blocking on runRenderLoop.
loop_stopped: bool = false,

started: bool = false,

/// The thread id that called runRenderLoop, recorded so destroy() can assert
/// the render loop is not concurrently running on another thread (Phase 1
/// invariant: render loop and destroy() share a thread). null if the blocking
/// runRenderLoop was never used (e.g. tests that only call tickRenderLoop).
render_loop_thread: ?std.Thread.Id = null,

/// Create a fully-constructed Session at a stable heap address. This builds
/// Termio (which spawns the child only at threadEnter, not here) but does NOT
/// spawn the IO thread; call start() for that.
pub fn create(alloc: Allocator, opts: Options) !*Session {
    const self = try alloc.create(Session);
    errdefer alloc.destroy(self);

    // Default config: deterministic, never errors on fork-only keys.
    var config = try Config.default(alloc);
    errdefer config.deinit();

    const size: renderer.Size = .{
        .screen = .{
            .width = @as(u32, opts.cols) * opts.cell_width,
            .height = @as(u32, opts.rows) * opts.cell_height,
        },
        .cell = .{ .width = opts.cell_width, .height = opts.cell_height },
        .padding = .{},
    };

    const surface = try alloc.create(Surface);
    errdefer alloc.destroy(surface);
    surface.size = size;

    const renderer_mailbox = try renderer.Thread.Mailbox.create(alloc);
    errdefer renderer_mailbox.destroy(alloc);

    const app_queue = try App.Mailbox.Queue.create(alloc);
    errdefer app_queue.destroy(alloc);

    var renderer_wakeup = try xev.Async.init();
    errdefer renderer_wakeup.deinit();

    var io_thread = try termio.Thread.init(alloc);
    errdefer io_thread.deinit();

    var render_loop = try xev.Loop.init(.{});
    errdefer render_loop.deinit();
    var render_stop = try xev.Async.init();
    errdefer render_stop.deinit();
    const poll_timer = try xev.Timer.init();
    errdefer poll_timer.deinit();

    // Initialize all the by-value fields. renderer_state pointers that refer
    // back into self are set AFTER this assignment (self is now stable).
    self.* = .{
        .alloc = alloc,
        .opts = opts,
        .config = config,
        .size = size,
        .io = undefined,
        .io_thread = io_thread,
        .renderer_state = .{
            .mutex = undefined,
            .terminal = undefined,
            .inspector = null,
        },
        .renderer_wakeup = renderer_wakeup,
        .renderer_mailbox = renderer_mailbox,
        .app_queue = app_queue,
        .surface = surface,
        .render_loop = render_loop,
        .render_stop = render_stop,
        .poll_timer = poll_timer,
    };

    // Wire the self-referential renderer_state mutex now that self is stable.
    self.renderer_state.mutex = &self.render_mutex;

    // Build Termio. This separate block ({}) is important because the
    // errdefers for env / io_exec / io_mailbox / DerivedConfig must be scoped
    // so they disarm exactly when Termio.init takes ownership of them, leaving
    // only `errdefer self.io.deinit()` (below the block) armed for the tail.
    // Mirrors Surface.zig:645-694.
    {
        // Build the environment for the child.
        var env = internal_os.getEnvMap(alloc) catch
            std.process.EnvMap.init(alloc);
        errdefer env.deinit();
        env.remove("GHOSTTY_LOG");

        // termio.Exec.init takes ownership of `env` (a shallow EnvMap copy
        // sharing the same backing storage). Once it succeeds, freeing env is
        // io_exec's job; the env errdefer above only covers the pre-init window.
        var io_exec = try termio.Exec.init(alloc, .{
            .command = self.config.command,
            .env = env,
            .env_override = self.config.env,
            .shell_integration = self.config.@"shell-integration",
            .shell_integration_features = self.config.@"shell-integration-features",
            .cursor_blink = self.config.@"cursor-style-blink",
            .working_directory = if (self.config.@"working-directory") |wd| wd.value() else null,
            .resources_dir = global.state.resources_dir.host(),
            .term = self.config.term,
            .rt_pre_exec_info = .init(&self.config),
            .rt_post_fork_info = .init(&self.config),
        });
        errdefer io_exec.deinit();

        var io_mailbox = try termio.Mailbox.initSPSC(alloc);
        errdefer io_mailbox.deinit(alloc);

        // Build the DerivedConfig into a named local with its own errdefer so a
        // Termio.init failure after it is allocated doesn't leak it. Termio
        // takes ownership only on success (its final self.* assignment).
        var derived = try termio.Termio.DerivedConfig.init(alloc, &self.config);
        errdefer derived.deinit();

        // Build Termio: constructs the terminal into self.io.
        try termio.Termio.init(&self.io, alloc, .{
            .size = size,
            .full_config = &self.config,
            .config = derived,
            .backend = .{ .exec = io_exec },
            .mailbox = io_mailbox,
            .renderer_state = &self.renderer_state,
            .renderer_wakeup = renderer_wakeup,
            .renderer_mailbox = renderer_mailbox,
            .surface_mailbox = .{
                .surface = surface,
                .app = .{ .rt_app = &self.rt_app, .mailbox = app_queue },
            },
        });
    }
    // Outside the block, Termio has taken ownership of env / io_exec /
    // io_mailbox / DerivedConfig, so a single self.io.deinit() errdefer covers
    // the tail (and any future fallible statement added after this point).
    errdefer self.io.deinit();

    // Point renderer_state at the terminal Termio.init just moved into self.
    // Mirror of Surface.zig:616 (set AFTER Termio.init).
    self.renderer_state.terminal = &self.io.terminal;

    // Hard invariant: inspector stays null.
    std.debug.assert(self.renderer_state.inspector == null);

    return self;
}

/// Arm the render loop's async handlers and spawn the IO thread (which starts
/// the child shell at threadEnter).
pub fn start(self: *Session) !void {
    std.debug.assert(!self.started);

    self.renderer_wakeup.wait(
        &self.render_loop,
        &self.wakeup_c,
        Session,
        self,
        renderWakeupCallback,
    );
    self.render_stop.wait(
        &self.render_loop,
        &self.render_stop_c,
        Session,
        self,
        renderStopCallback,
    );

    // Arm the periodic poll timer. This re-arms itself in its callback, so
    // (like renderer_wakeup) it keeps the loop's `active` count >= 1; the
    // ONLY thing that breaks run(.until_done) is renderStopCallback's
    // loop.stop(). It is the deterministic shutdown driver (see poll_timer's
    // field doc): it guarantees a queued .child_exited message is drained
    // within poll_interval_ms even when the child emits no trailing output.
    self.poll_timer.run(
        &self.render_loop,
        &self.poll_timer_c,
        self.poll_interval_ms,
        Session,
        self,
        pollTimerCallback,
    );

    self.io_thr = try std.Thread.spawn(
        .{},
        termio.Thread.threadMain,
        .{ &self.io_thread, &self.io },
    );
    self.io_thr.?.setName("io") catch {};

    self.started = true;
}

/// Send input bytes to the child (queues a write via the termio mailbox).
/// Safe to call from any thread (it goes through the mailbox).
pub fn sendInput(self: *Session, data: []const u8) !void {
    self.io.queueMessage(
        try termio.Message.writeReq(self.alloc, data),
        .unlocked,
    );
}

/// Run the host render loop on the calling thread. Blocks until render_stop
/// is notified (via stop(), or a child-exit message drained by renderTick),
/// at which point renderStopCallback calls loop.stop() and run(.until_done)
/// returns. Child exit is observed deterministically: the periodic poll_timer
/// drains the app_queue every poll_interval_ms even when the dead child
/// produced no trailing pty output to wake renderer_wakeup.
///
/// IMPORTANT: stop()/destroy() do NOT join a render-loop thread. The render
/// loop MUST run on the same thread that later calls destroy() (Phase 1 runs
/// it on the main thread, and destroy() is reached only after this returns).
/// If the loop is ever moved off-thread, stop() must store + join its
/// std.Thread handle before destroy() frees render_loop/wakeup_c/self.
pub fn runRenderLoop(self: *Session) !void {
    self.render_loop_thread = std.Thread.getCurrentId();
    _ = try self.render_loop.run(.until_done);
}

/// Drive render-loop iterations without blocking. Used by tests.
pub fn tickRenderLoop(self: *Session) !void {
    _ = try self.render_loop.run(.no_wait);
}

fn renderStopCallback(
    self_: ?*Session,
    l: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch {};
    if (self_) |self| self.loop_stopped = true;
    // Stop the loop itself. renderer_wakeup always re-arms (.rearm), so its
    // completion keeps `active` >= 1 forever; setting the loop's stopped flag
    // is the ONLY way to break run(.until_done). Without this, render_stop
    // would merely disarm this one completion and the loop would never return.
    l.stop();
    return .disarm;
}

fn renderWakeupCallback(
    self_: ?*Session,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch return .rearm;
    const self = self_ orelse return .rearm;
    _ = self.renderTick() catch |err| blk: {
        log.warn("error during render tick err={}", .{err});
        break :blk 0;
    };
    return .rearm;
}

fn pollTimerCallback(
    self_: ?*Session,
    l: *xev.Loop,
    c: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    // A cancellation (timer torn down) is the only error worth bailing on.
    _ = r catch return .disarm;
    const self = self_ orelse return .disarm;

    // Run a tick so a queued .child_exited message (which never notifies
    // renderer_wakeup; see poll_timer's doc) is always observed and shuts
    // the loop down. renderTick may call render_stop.notify() during this
    // call; renderStopCallback's loop.stop() is what actually breaks the run.
    _ = self.renderTick() catch |err| {
        log.warn("error during poll render tick err={}", .{err});
    };

    // Re-arm for the next interval. xev.Timer is one-shot, so this manual
    // requeue is what makes it periodic (mirrors renderer/Thread.zig).
    self.poll_timer.run(
        l,
        c,
        self.poll_interval_ms,
        Session,
        self,
        pollTimerCallback,
    );
    return .disarm;
}

/// One render tick: drain the renderer + app mailboxes, run RenderState.update
/// under the mutex, diff against the previous snapshot, and print the diff.
/// Returns the number of changed rows in the diff (for tests).
pub fn renderTick(self: *Session) !usize {
    // Drain the stub renderer mailbox: ONLY .resize and .reset_cursor_blink.
    while (self.renderer_mailbox.pop()) |msg| {
        switch (msg) {
            .resize => |sz| {
                self.renderer_resize_count += 1;
                log.debug("renderer mailbox: resize {}x{}", .{
                    sz.grid().columns,
                    sz.grid().rows,
                });
            },
            .reset_cursor_blink => {
                self.renderer_reset_cursor_blink_count += 1;
                log.debug("renderer mailbox: reset_cursor_blink", .{});
            },
            // Host-boundary contract canary: Termio must push nothing beyond
            // the two kinds above. A nonzero count here is a contract breach.
            else => {
                self.unexpected_renderer_count += 1;
                log.warn(
                    "unexpected renderer message in host: {s}",
                    .{@tagName(msg)},
                );
            },
        }
    }

    // Drain the app (surface message) queue: Phase 1 logs only, except that a
    // child-exit message stops the render loop so the host shuts down cleanly
    // (otherwise runRenderLoop would spin forever on a dead session).
    while (self.app_queue.pop()) |msg| {
        switch (msg) {
            .surface_message => |sm| {
                log.debug("surface message: {s}", .{@tagName(sm.message)});
                if (sm.message == .child_exited) {
                    const ce = sm.message.child_exited;
                    // Phase 2a: surface the child-exit details to the Server
                    // (buffer-or-deliver a ChildExited frame) in addition to
                    // the render-loop stop below. No-op in the Phase-1 path.
                    if (self.on_child_exited) |cb| {
                        cb(self.on_child_exited_ctx.?, self, ce.exit_code, ce.runtime_ms);
                    }
                    log.info("child exited; stopping render loop", .{});
                    self.render_stop.notify() catch |err| log.warn(
                        "error notifying render loop stop err={}",
                        .{err},
                    );
                }
            },
            else => log.debug("app message: {s}", .{@tagName(msg)}),
        }
    }

    // Build the current snapshot under the mutex.
    var snapshot = blk: {
        self.render_mutex.lock();
        defer self.render_mutex.unlock();
        break :blk try RenderState.Snapshot.capture(
            self.alloc,
            &self.renderer_state,
        );
    };
    errdefer snapshot.deinit(self.alloc);

    const changed = try RenderState.printDiff(self.alloc, self.prev_snapshot, snapshot);

    if (self.prev_snapshot) |*prev| prev.deinit(self.alloc);
    self.prev_snapshot = snapshot;

    // Phase 2a render-tick push: hand the just-captured snapshot to the Server
    // (if wired) so it can serialize + broadcast a GridFrame + ModeFrame. The
    // snapshot stays owned by self.prev_snapshot; the callback must not free it.
    // No-op in the Phase-1 stdout-diff path (on_render == null).
    //
    // Gate on `changed > 0` (finding SR-3): renderTick is driven by the
    // periodic poll_timer (~10 Hz in production) as well as real output, and
    // every captured Snapshot is currently .full, so pushing unconditionally
    // would broadcast a full GridFrame + ModeFrame to every subscriber ~10
    // times/sec on a completely idle session — a steady-state bandwidth/CPU
    // drain and a divergence from the frozen cadence contract (plan §2.2:
    // render-tick only when output marked something dirty). A freshly-attached
    // GUI still gets immediate state because (re)attach pushes a full frame via
    // Server.pushFullFrames independent of the tick; only redundant idle ticks
    // are suppressed. FOLLOWUP (Phase 2b): persist a RenderState across ticks so
    // capture can emit .partial and the poll-timer path stops forcing .full.
    if (changed > 0) {
        if (self.on_render) |cb| {
            cb(self.on_render_ctx.?, self, &self.prev_snapshot.?);
        }
    }

    self.total_changed_rows += changed;
    return changed;
}

/// Stop the session: signal the IO thread + render loop, join the IO thread.
/// Idempotent.
pub fn stop(self: *Session) void {
    if (!self.started) return;
    self.started = false;

    self.io_thread.stop.notify() catch |err| {
        log.warn("error notifying io thread stop err={}", .{err});
    };
    if (self.io_thr) |thr| {
        thr.join();
        self.io_thr = null;
    }

    self.render_stop.notify() catch |err| {
        log.warn("error notifying render loop stop err={}", .{err});
    };
}

/// Tear down everything and free the Session. Must be called after stop()
/// (or without ever calling start()).
pub fn destroy(self: *Session) void {
    // Phase 1 invariant: if the blocking render loop was used, destroy() must
    // run on that same thread (it isn't joined in stop()). It has by then
    // returned, so getCurrentId() must match. See runRenderLoop's doc comment.
    if (self.render_loop_thread) |tid| {
        std.debug.assert(tid == std.Thread.getCurrentId());
    }

    if (self.started) self.stop();

    self.io.deinit();
    if (self.prev_snapshot) |*s| s.deinit(self.alloc);

    self.poll_timer.deinit();
    self.render_stop.deinit();
    self.render_loop.deinit();
    self.io_thread.deinit();
    self.renderer_wakeup.deinit();
    self.app_queue.destroy(self.alloc);
    self.renderer_mailbox.destroy(self.alloc);
    self.alloc.destroy(self.surface);
    self.config.deinit();

    const alloc = self.alloc;
    alloc.destroy(self);
}
