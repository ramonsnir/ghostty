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

pub fn main() !void {
    std.log.info("ghostty-host starting (Phase 1: headless, no IPC)", .{});

    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Initialize global process state (resources dir, etc.). The child shell
    // needs GHOSTTY_RESOURCES_DIR/TERMINFO for the ghostty terminfo entry.
    try global.state.init();
    defer global.state.deinit();

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
