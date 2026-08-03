//! ghostty-host: the headless emulation-on-host process (Phase 1).
//!
//! Phase 1 is a single-session, no-IPC harness: it links the Ghostty core,
//! spins up ONE terminal session (terminal.Terminal + termio.Termio +
//! termio.Exec over a real pty + a real child shell) driven by termio.Thread's
//! libxev loop, and replaces the GPU renderer with a host-side render sink
//! that runs RenderState.update and prints diffs to stdout. No GPU, no apprt
//! embedded App/Surface, no IPC.
//!
//! This file MUST live at src/ root so the core `@import("...")` module paths
//! resolve; the rest of the host lives under src/host/ and is reached via
//! `@import("host/...")` from here.

const std = @import("std");
const builtin = @import("builtin");

const global = @import("global.zig");
const Session = @import("host/Session.zig");
const Server = @import("host/Server.zig");
// FORK(host-handoff): the supervisor + the pure argv mode parser. Analyzable on
// every target (its macOS-only handoff bodies are comptime-gated), so importing it
// here does not break the Linux cloud-box host build.
const Supervisor = @import("host/Supervisor.zig");

const log = std.log.scoped(.host_main);

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Initialize global process state (resources dir, etc.). The child shell
    // needs GHOSTTY_RESOURCES_DIR/TERMINFO for the ghostty terminfo entry.
    try global.state.init();
    defer global.state.deinit();

    // FORK(host-handoff): dispatch the two new argv modes FIRST — `--supervise`
    // and `--handoff-worker` argv also carry `--listen=`, which must NOT be
    // mistaken for the pre-existing standalone Server. Everything else falls
    // through to the byte-for-byte-unchanged legacy paths below.
    {
        const raw = try std.process.argsAlloc(alloc);
        defer std.process.argsFree(alloc, raw);
        var arg_list = try alloc.alloc([]const u8, raw.len -| 1);
        defer alloc.free(arg_list);
        for (raw[1..], 0..) |a, i| arg_list[i] = a;
        switch (try Supervisor.parseMode(arg_list)) {
            .supervise => |s| {
                try runSupervise(alloc, s.listen_path, s.worker_path);
                return;
            },
            .handoff_worker => |w| {
                try runHandoffWorker(alloc, w);
                return;
            },
            // .listen / .stdout_diff fall through to the legacy paths, unchanged.
            else => {},
        }
    }

    // Parse args: `--listen=<path>` (or a bare positional socket path) runs the
    // Phase 2a transport Server; otherwise keep the EXACT Phase-1 single-session
    // stdout-diff path so nothing regresses.
    if (try listenPath(alloc)) |path| {
        defer alloc.free(path);
        try runServer(alloc, path);
        return;
    }

    try runStdoutDiff(alloc);
}

/// FORK(host-handoff): `--supervise` — the session-less supervisor. Binds the
/// listen socket forever, keeps one live worker on it, holds every pty master, and
/// brokers handoffs. macOS-only (rides the Darwin cmsg handoff); logs + exits
/// otherwise. Blocks (`run` parks) until the process is killed.
fn runSupervise(alloc: std.mem.Allocator, listen_path: []const u8, worker_path: ?[]const u8) !void {
    if (comptime builtin.os.tag != .macos) {
        log.warn("--supervise is unsupported off macOS (the handoff rides the Darwin SCM_RIGHTS ABI)", .{});
        return;
    }
    std.log.info("ghostty-host starting (supervisor: {s})", .{listen_path});
    const sup = try Supervisor.init(alloc, listen_path, worker_path);
    defer sup.deinit();
    try sup.run();
}

/// FORK(host-handoff): `--handoff-worker` — worker mode. The supervisor already
/// bound + inherited the listener (fd `w.listen_fd`) and a control socket (fd
/// `w.control_fd`); adopt them, serve, and run the control loop until a `shutdown`
/// frame (or the supervisor dropping the channel) ends it, then exit(0). macOS-only
/// (the control loop rides the Darwin cmsg codec); logs + exits otherwise.
fn runHandoffWorker(alloc: std.mem.Allocator, w: Supervisor.WorkerArgs) !void {
    if (comptime builtin.os.tag != .macos) {
        log.warn("--handoff-worker is unsupported off macOS (the control loop rides the Darwin SCM_RIGHTS ABI)", .{});
        return;
    }
    std.log.info("ghostty-host starting (worker: listen-fd={d} control-fd={d})", .{ w.listen_fd, w.control_fd });

    // The listener is already bound; owns_path=false so this worker never unlinks
    // the path the supervisor keeps bound across worker swaps.
    const server = try Server.initFromListenFd(alloc, w.listen_path orelse "", w.listen_fd, false);
    defer server.deinit();
    try server.start();
    try server.startControlLoop(w.control_fd);

    // Block until the control loop thread exits — set by a `shutdown` frame
    // (control_running → false) or the supervisor dropping the control channel
    // (recvFrame → Closed breaks the loop). `deinit` (defer) then cleans up.
    server.joinControlLoop();
    std.log.info("ghostty-host worker: control loop ended; exiting", .{});
}

/// Resolve the socket path from argv: `--listen=<path>` or a bare positional
/// path. Returns null if no listen arg was given (Phase-1 mode). Caller owns
/// the returned slice.
fn listenPath(alloc: std.mem.Allocator) !?[]u8 {
    var it = try std.process.argsWithAllocator(alloc);
    defer it.deinit();
    _ = it.next(); // argv[0]
    while (it.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--listen=")) {
            return try alloc.dupe(u8, arg["--listen=".len..]);
        }
        if (!std.mem.startsWith(u8, arg, "-")) {
            return try alloc.dupe(u8, arg);
        }
    }
    return null;
}

/// Phase 2a: run the transport Server, accepting GUI connections forever.
fn runServer(alloc: std.mem.Allocator, path: []const u8) !void {
    std.log.info("ghostty-host starting (Phase 2a: serving on {s})", .{path});
    const server = try Server.init(alloc, path);
    defer server.deinit();
    try server.start();
    std.log.info("ghostty-host: server listening, accepting connections", .{});

    // Block forever (until killed). The accept + per-connection + per-session
    // threads do the work. A future SIGTERM handler can flip server.running.
    while (true) std.Thread.sleep(60 * std.time.ns_per_s);
}

/// Phase 1 (preserved verbatim): single-session, no-IPC stdout-diff harness.
fn runStdoutDiff(alloc: std.mem.Allocator) !void {
    std.log.info("ghostty-host starting (Phase 1: headless, no IPC)", .{});

    const session = try Session.create(alloc, .{});
    defer session.destroy();

    try session.start();
    std.log.info("ghostty-host: session started, running render loop", .{});

    // Run the host render loop on this thread. Blocks until the session is
    // stopped: renderTick drains the app queue and, on a child-exit surface
    // message, notifies render_stop, which makes run(.until_done) return.
    // Shutdown is poll-driven: child exit arrives on the surface mailbox
    // (none.App.wakeup is a no-op, no renderer_wakeup), so the Session's
    // periodic poll_timer is what guarantees the queued .child_exited message
    // is drained and the loop terminates even when the shell exits with no
    // trailing pty output.
    // (No SIGINT handler yet; Ctrl-C reaches the child shell over the pty, and
    // when that shell exits the child-exit path above terminates the loop.)
    try session.runRenderLoop();

    std.log.info("ghostty-host: shutting down", .{});
}

// Pull the host tree into the test binary so `-Dtest-filter=host` reaches the
// host tests. (This is also referenced from src/main_ghostty.zig's test block.)
test {
    _ = @import("host/main.zig");
}
