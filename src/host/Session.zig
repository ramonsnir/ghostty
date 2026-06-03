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
const inputpkg = @import("../input.zig");
const configpkg = @import("../config.zig");
const Config = configpkg.Config;
const internal_os = @import("../os/main.zig");
const Surface = @import("../Surface.zig");

const RenderState = @import("RenderState.zig");
/// The core terminal RenderState (the transient flatten target). Distinct from
/// the host `RenderState` module above, which is the pointer-free Snapshot
/// projection.
const RenderStateCore = @import("../terminal/render.zig").RenderState;

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

/// The host's search thread + OS thread handle, mirroring `Surface.Search`
/// (`Surface.zig:199-216`).
const HostSearch = struct {
    state: terminalpkg.search.Thread,
    thread: std.Thread,

    pub fn deinit(self: *HostSearch) void {
        self.state.stop.notify() catch |err| log.err(
            "error notifying host search thread to stop, may stall err={}",
            .{err},
        );
        self.thread.join();
        self.state.deinit();
    }
};

/// A search status event surfaced to the Server so it can frame it to GUI
/// subscribers. Mirrors the GUI's `search_total` / `search_selected` surface
/// messages (`Surface.zig:1167-1178`). `null` totals/indices encode the
/// "search cleared" state.
pub const SearchEvent = union(enum) {
    total: ?usize,
    selected: ?usize,
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

/// --- Slice 3b: host-side search ---
///
/// The host's own search engine, mirroring the GUI's `Surface.search`
/// (`Surface.zig:174`). Created lazily on the first non-empty `setSearch`,
/// parented to `self.io.terminal` and sharing `self.render_mutex` (the same
/// lock `renderTick`/capture take), so its `feed`/`select` are serialized
/// against snapshot capture exactly as on the GUI side. Torn down by
/// `clearSearch`/empty `setSearch`. Fork/host-only: gives `.client` sessions
/// search highlights without touching `.exec`'s GUI-side search.
search: ?HostSearch = null,

/// Deep-cloned viewport matches from the last `viewport_matches` callback,
/// backed by `search_match_arena`. Read under `render_mutex` by
/// `captureSnapshotLocked` to flatten into the transient RenderState. Callback
/// memory is valid only during the call (Thread.zig:483-484), so we clone like
/// the GUI does (`Surface.zig:1458-1459`).
search_match_arena: ?std.heap.ArenaAllocator = null,
search_matches: []terminalpkg.highlight.Flattened = &.{},

/// Deep-cloned selected match from the last `selected_match` callback, backed
/// by `search_selected_arena`. Applied with the `search_match_selected` tag so
/// it wins over plain matches (matching the GUI flatten order in generic.zig).
search_selected_arena: ?std.heap.ArenaAllocator = null,
search_selected: ?terminalpkg.highlight.Flattened = null,

/// Set by the search callback to force the next renderTick to push a frame even
/// when no cells changed (a pure search command mutates highlights, not cells).
/// Cleared after the push in renderTick.
search_dirty: bool = false,

/// Phase 3b search status events. Set by the Server so search_total/
/// search_selected can be framed to subscribers. Invoked from the host search
/// callback (which runs on the search thread). null in the standalone path.
on_search_event_ctx: ?*anyopaque = null,
on_search_event: ?*const fn (ctx: *anyopaque, self: *Session, event: SearchEvent) void = null,

/// Slice 6 general SurfaceEvent channel. Set by the Server so each FORWARDED
/// `apprt.surface.Message` drained from the app queue (everything the host's
/// StreamHandler emits except the dedicated/excluded variants) can be
/// serialized into a `surface_event` frame and pushed to subscribers, mirroring
/// onChildExited/onSearchEvent. Invoked SYNCHRONOUSLY from the app-queue drain
/// in renderTick (the message — including any owned WriteReq bytes — is alive
/// only for the duration of the callback), so the callback must serialize/copy
/// before returning. null in the Phase-1/standalone path (unchanged behavior).
on_surface_event_ctx: ?*anyopaque = null,
on_surface_event: ?*const fn (ctx: *anyopaque, self: *Session, msg: *const apprt.surface.Message) void = null,

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

/// --- Slice 3b: host-side search ---
///
/// HighlightTag values MUST match the GUI renderer's `HighlightTag` enum
/// (`src/renderer/generic.zig:234-236`) so `rebuildRow` maps the host-produced
/// row.highlights identically on the client (search_match -> .search,
/// search_match_selected -> .search_selected).
pub const highlight_tag_search_match: u8 = 0;
pub const highlight_tag_search_match_selected: u8 = 1;

/// Start or replace the search needle. An empty `query` clears the search (same
/// as `clearSearch`). Mirrors `Surface.zig:4968-5013`. The search thread is
/// created lazily, parented to this Session's terminal and sharing
/// `render_mutex`.
pub fn setSearch(self: *Session, query: []const u8) !void {
    if (query.len == 0) {
        self.clearSearch();
        return;
    }

    const s: *HostSearch = if (self.search) |*s| s else init: {
        self.search = .{
            .state = try .init(self.alloc, .{
                .mutex = &self.render_mutex,
                .terminal = &self.io.terminal,
                .event_cb = &hostSearchCallback,
                .event_userdata = self,
            }),
            .thread = undefined,
        };
        const s: *HostSearch = &self.search.?;
        errdefer {
            s.state.deinit();
            self.search = null;
        }

        s.thread = try .spawn(
            .{},
            terminalpkg.search.Thread.threadMain,
            .{&s.state},
        );
        s.thread.setName("host-search") catch {};

        break :init s;
    };

    _ = s.state.mailbox.push(
        .{ .change_needle = try .init(self.alloc, query) },
        .forever,
    );
    s.state.wakeup.notify() catch {};
}

/// Navigate the search selection. `dir` 0=next, 1=prev. No-op if no active
/// search. Mirrors `Surface.zig:5015-5025`.
pub fn navSearch(self: *Session, dir: u8) void {
    const s: *HostSearch = if (self.search) |*s| s else return;
    _ = s.state.mailbox.push(
        .{ .select = if (dir == 0) .next else .prev },
        .forever,
    );
    s.state.wakeup.notify() catch {};
}

/// --- Slice 7: scroll-via-host ---
///
/// Repin the host terminal's viewport on behalf of a .client GUI. Routed
/// through the host Termio mailbox exactly like .resize/.focus: the IO thread
/// applies it via Termio.scrollViewport (backend .exec -> local terminal
/// scroll) and then notifies renderer_wakeup after the drain, so the next host
/// render tick ships a GridFrame of the scrolled viewport. No extra wakeup
/// here (the Thread drain handles it).
pub fn scrollViewport(
    self: *Session,
    scroll: terminalpkg.Terminal.ScrollViewport,
) void {
    self.io.queueMessage(.{ .scroll_viewport = scroll }, .unlocked);
}

/// Jump the host terminal's viewport to a prompt by `delta`. Same routing as
/// scrollViewport.
pub fn jumpToPrompt(self: *Session, delta: isize) void {
    self.io.queueMessage(.{ .jump_to_prompt = delta }, .unlocked);
}

/// Clear the active search: tear down the search thread and drop stored
/// highlights. Forces a render so the highlight-free GridFrame ships. Mirrors
/// `Surface.zig:4999-5002`.
///
/// Runs on the per-connection READ thread (via Server.dispatch's .clear_search
/// / empty-query .set_search arms), concurrently with the owning thread's
/// renderTick -> captureSnapshotLocked, which reads `search_matches` /
/// `search_selected` and iterates their arena-backed `Flattened` chunks under
/// `render_mutex`. We therefore tear the search thread down FIRST (so no
/// callback can race), then swap the stored matches out and set `search_dirty`
/// UNDER `render_mutex` (deinit'ing the detached arenas outside the lock),
/// mirroring the callback's locked-swap pattern. Without the lock this would be
/// a use-after-free against a mid-flatten render tick (finding SEARCH-RACE-1).
pub fn clearSearch(self: *Session) void {
    if (self.search) |*s| {
        s.deinit();
        self.search = null;
    }
    self.clearSearchHighlightsLocked();
    self.renderer_wakeup.notify() catch {};
}

/// Detach the stored cloned matches/selected arenas under `render_mutex`, then
/// deinit the detached arenas OUTSIDE the lock. Sets `search_dirty` within the
/// locked region so the cleared-highlights frame still ships. Safe against the
/// render-loop reader (captureSnapshotLocked). The SEARCH-thread callback must
/// be torn down (joined) before calling this so it can't concurrently re-store
/// matches; clearSearch guarantees that ordering.
fn clearSearchHighlightsLocked(self: *Session) void {
    var old_match: ?std.heap.ArenaAllocator = null;
    var old_sel: ?std.heap.ArenaAllocator = null;
    {
        self.render_mutex.lock();
        defer self.render_mutex.unlock();
        old_match = self.search_match_arena;
        self.search_match_arena = null;
        self.search_matches = &.{};
        old_sel = self.search_selected_arena;
        self.search_selected_arena = null;
        self.search_selected = null;
        // Force a frame so the cleared highlights reach subscribers, even if
        // no cell changed.
        self.search_dirty = true;
    }
    if (old_match) |*a| a.deinit();
    if (old_sel) |*a| a.deinit();
}

/// Free the stored cloned matches/selected arenas WITHOUT taking `render_mutex`.
/// ONLY safe to call from the owning thread AFTER the render loop has stopped
/// (destroy()), where no render tick and no search callback can race. Use
/// `clearSearchHighlightsLocked` from any other context.
fn clearSearchHighlights(self: *Session) void {
    if (self.search_match_arena) |*a| a.deinit();
    self.search_match_arena = null;
    self.search_matches = &.{};
    if (self.search_selected_arena) |*a| a.deinit();
    self.search_selected_arena = null;
    self.search_selected = null;
}

/// Search-thread event callback. Runs on the host search thread (same
/// constraints as `Surface.searchCallback`, `Surface.zig:1435`). Deep-clones
/// the flattened matches into Session-owned arenas, marks `search_dirty`, wakes
/// the render loop, and surfaces total/selected status via `on_search_event`.
fn hostSearchCallback(event: terminalpkg.search.Thread.Event, ud: ?*anyopaque) void {
    const self: *Session = @ptrCast(@alignCast(ud.?));
    self.hostSearchCallback_(event) catch |err| {
        log.warn("error in host search callback err={}", .{err});
    };
}

fn hostSearchCallback_(
    self: *Session,
    event: terminalpkg.search.Thread.Event,
) !void {
    switch (event) {
        .viewport_matches => |matches_unowned| {
            // Clone OUTSIDE the render_mutex (the clone allocates; the callback
            // owns the source only during this call). Then swap the stored
            // matches in under render_mutex so captureSnapshotLocked (which
            // reads them) never observes a half-swapped state. This mirrors the
            // GUI's mailbox decoupling, here collapsed to a brief lock since the
            // search thread shares render_mutex with capture anyway.
            var arena: std.heap.ArenaAllocator = .init(self.alloc);
            errdefer arena.deinit();
            const alloc = arena.allocator();

            const matches = try alloc.dupe(terminalpkg.highlight.Flattened, matches_unowned);
            for (matches) |*m| m.* = try m.clone(alloc);

            var old_arena: ?std.heap.ArenaAllocator = null;
            {
                self.render_mutex.lock();
                defer self.render_mutex.unlock();
                old_arena = self.search_match_arena;
                self.search_match_arena = arena;
                self.search_matches = matches;
                self.search_dirty = true;
            }
            if (old_arena) |*a| a.deinit();

            self.renderer_wakeup.notify() catch {};
        },

        .selected_match => |selected_| {
            var new_arena: ?std.heap.ArenaAllocator = null;
            var new_selected: ?terminalpkg.highlight.Flattened = null;
            var emit: SearchEvent = .{ .selected = null };

            if (selected_) |sel| {
                var arena: std.heap.ArenaAllocator = .init(self.alloc);
                errdefer arena.deinit();
                const alloc = arena.allocator();
                new_selected = try sel.highlight.clone(alloc);
                new_arena = arena;
                emit = .{ .selected = sel.idx };
            }

            var old_arena: ?std.heap.ArenaAllocator = null;
            {
                self.render_mutex.lock();
                defer self.render_mutex.unlock();
                old_arena = self.search_selected_arena;
                self.search_selected_arena = new_arena;
                self.search_selected = new_selected;
                self.search_dirty = true;
            }
            if (old_arena) |*a| a.deinit();

            if (self.on_search_event) |cb| {
                cb(self.on_search_event_ctx.?, self, emit);
            }
            self.renderer_wakeup.notify() catch {};
        },

        .total_matches => |total| {
            if (self.on_search_event) |cb| {
                cb(self.on_search_event_ctx.?, self, .{ .total = total });
            }
        },

        .quit => {
            var old_match: ?std.heap.ArenaAllocator = null;
            var old_sel: ?std.heap.ArenaAllocator = null;
            {
                self.render_mutex.lock();
                defer self.render_mutex.unlock();
                old_match = self.search_match_arena;
                self.search_match_arena = null;
                self.search_matches = &.{};
                old_sel = self.search_selected_arena;
                self.search_selected_arena = null;
                self.search_selected = null;
                self.search_dirty = true;
            }
            if (old_match) |*a| a.deinit();
            if (old_sel) |*a| a.deinit();

            if (self.on_search_event) |cb| {
                cb(self.on_search_event_ctx.?, self, .{ .total = null });
                cb(self.on_search_event_ctx.?, self, .{ .selected = null });
            }
            self.renderer_wakeup.notify() catch {};
        },

        .complete => {},
    }
}

/// Capture a Snapshot, applying any stored host search highlights into the
/// transient RenderState BEFORE projecting to the pointer-free Snapshot. The
/// caller MUST hold `render_mutex` (this runs RenderState.update against the
/// live terminal and reads live pins via updateHighlightsFlattened).
///
/// This is the load-bearing step that turns search-match pin-ranges into
/// row.highlights on the host (the GUI does this under `.exec` but cannot under
/// `.client`). The flatten order mirrors the GUI renderer (generic.zig:1381):
/// selected first (so it wins), then the plain matches.
pub fn captureSnapshotLocked(self: *Session, alloc: Allocator) !RenderState.Snapshot {
    var rs: RenderStateCore = .empty;
    defer rs.deinit(alloc);
    try rs.update(alloc, self.renderer_state.terminal);

    // Apply stored host search highlights (no-op when there is no search).
    if (self.search_selected) |sel| {
        try rs.updateHighlightsFlattened(
            alloc,
            highlight_tag_search_match_selected,
            &.{sel},
        );
    }
    if (self.search_matches.len > 0) {
        try rs.updateHighlightsFlattened(
            alloc,
            highlight_tag_search_match,
            self.search_matches,
        );
    }

    return try RenderState.Snapshot.fromRenderState(alloc, &rs);
}

/// --- Slice 3c: host-side OSC8 hover links ---
///
/// Compute the OSC8 hyperlink-cell set for a hover at viewport `(x, y)`,
/// REUSING `RenderState.linkCells` (the same routine the GUI runs under
/// `.exec`) against the host's live terminal — the OSC8 lookup dereferences
/// row pins, which exist only on the host (the client mirror's pins are the
/// poisoned sentinel). Returns an EMPTY set when the hover mods don't include
/// the ctrl/super link gate, or when there is no link under the cell.
///
/// The caller MUST hold `render_mutex` (this reads the live terminal via
/// `RenderState.update`, exactly like `captureSnapshotLocked`). The returned
/// CellSet is owned by the caller and must be freed with `alloc`.
///
/// Regex links are intentionally NOT computed here: `Set.renderCellMap`
/// matches viewport CELL TEXT (no pin/Terminal deref), so it stays GUI-side
/// and already works against the client mirror (see generic.zig:1341).
pub fn hoverLink(
    self: *Session,
    alloc: Allocator,
    viewport: terminalpkg.point.Coordinate,
    mods: inputpkg.Mods,
) !RenderStateCore.CellSet {
    // Apply the same mods gate the GUI uses under `.exec` (generic.zig:1310):
    // OSC8 links only highlight while the ctrl/super link modifier is held.
    if (!mods.equal(inputpkg.ctrlOrSuper(.{}))) return .empty;

    var rs: RenderStateCore = .empty;
    defer rs.deinit(alloc);
    try rs.update(alloc, self.renderer_state.terminal);

    // linkCells validates the viewport point against its own bounds and
    // returns empty for out-of-range / non-link cells.
    return try rs.linkCells(alloc, viewport);
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
                    // child_exited keeps its DEDICATED path (its own ChildExited
                    // frame + render-stop); it is NOT forwarded over the general
                    // SurfaceEvent channel (no double-delivery).
                    if (self.on_child_exited) |cb| {
                        cb(self.on_child_exited_ctx.?, self, ce.exit_code, ce.runtime_ms);
                    }
                    log.info("child exited; stopping render loop", .{});
                    self.render_stop.notify() catch |err| log.warn(
                        "error notifying render loop stop err={}",
                        .{err},
                    );
                } else if (self.on_surface_event) |cb| {
                    // Slice 6: forward EVERY OTHER surface message over the
                    // general SurfaceEvent channel. The callback serializes it
                    // SYNCHRONOUSLY (the message — including any owned WriteReq
                    // bytes — is alive only here) and pushes a surface_event
                    // frame to subscribers. The Server's onSurfaceEvent filters
                    // the EXCLUDED variants (change_config/close/renderer_health/
                    // present_surface/selection_scroll_tick/scrollbar/search_*)
                    // via SurfaceEvent.fromMessage's NotForwarded — those stay
                    // ignored (NOT log-dropped) here, no double-delivery with the
                    // dedicated search frames. No-op in the standalone path.
                    cb(self.on_surface_event_ctx.?, self, &sm.message);
                }
            },
            else => log.debug("app message: {s}", .{@tagName(msg)}),
        }
    }

    // Build the current snapshot under the mutex. Route through
    // captureSnapshotLocked so any stored host search highlights are flattened
    // into row.highlights before projection (no-op when no search is active).
    //
    // Read-and-clear `search_dirty` INSIDE this same critical section (finding
    // SD-RACE-1): the search-thread callbacks and clearSearch write it `=true`
    // under render_mutex, so reading/clearing it here under the same lock makes
    // every access to it synchronized and closes the lost-flag window (a
    // callback that fires after capture but before the clear can no longer have
    // its flag dropped without its matches being in the captured snapshot).
    var force_push = false;
    var snapshot = blk: {
        self.render_mutex.lock();
        defer self.render_mutex.unlock();
        force_push = self.search_dirty;
        self.search_dirty = false;
        break :blk try self.captureSnapshotLocked(self.alloc);
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
    //
    // Slice 3b: a pure search command mutates row.highlights but no cells, so
    // `changed` may still be > 0 because Snapshot.Row.eql compares highlights
    // (RenderState.zig:281-282) — but the diff can also be 0 when the search is
    // CLEARED and the cleared frame must still ship. `force_push` (the
    // read-and-clear of `search_dirty` captured under render_mutex above) forces
    // the push in that case so the highlight delta reaches subscribers.
    if (changed > 0 or force_push) {
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

    // Tear down the host search thread (joins it) BEFORE freeing the terminal
    // it searches, then drop any stored cloned highlights.
    if (self.search) |*s| {
        s.deinit();
        self.search = null;
    }
    self.clearSearchHighlights();

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
