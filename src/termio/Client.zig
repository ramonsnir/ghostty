//! Client implements a termio backend that talks to an out-of-process pty
//! host (the "ptyhost") instead of owning a subprocess + pty directly the way
//! `Exec` does. This is the `.client` arm of the termio backend union.
//!
//! Slice 1 status: this is a STUB. It exists so that `.client` is a valid,
//! compiling backend variant that mirrors `termio.Exec`'s method signatures.
//! Nothing selects `.client` yet (Surface.zig still hardcodes `.exec`), so the
//! method bodies are intentionally minimal and side-effect-free. The real
//! socket/protocol/decode implementation lands in Slice 2.
const Client = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const ProcessInfo = @import("../pty.zig").ProcessInfo;

/// Initialize the client state. This will NOT start it, this only sets up the
/// internal state necessary to start it later (mirrors `Exec.init`).
///
/// Slice 1 stub — real impl in Slice 2. Once there is real state to construct
/// this will gain a `Config` parameter and an allocator like `Exec.init`; for
/// now there is nothing to hold.
pub fn init() Client {
    return .{};
}

/// Slice 1 stub — real impl in Slice 2. No owned resources yet, so nothing to
/// release.
pub fn deinit(self: *Client) void {
    _ = self;
}

/// Call to initialize the terminal state as necessary for this backend.
///
/// Slice 1 stub — real impl in Slice 2. The real version mirrors
/// `Exec.initTerminal`: set the initial pwd and seed the grid/screen size.
pub fn initTerminal(self: *Client, term: *terminal.Terminal) void {
    _ = self;
    _ = term;
}

/// Slice 1 stub — real impl in Slice 2. The real version connects to the
/// ptyhost and spins up the read side. Returning an error keeps this safe:
/// if `.client` were ever (incorrectly) selected this slice, thread startup
/// fails loudly rather than silently doing the wrong thing.
pub fn threadEnter(
    self: *Client,
    alloc: Allocator,
    io: *termio.Termio,
    td: *termio.Termio.ThreadData,
) !void {
    _ = self;
    _ = alloc;
    _ = io;
    _ = td;
    return error.NotImplemented;
}

/// Slice 1 stub — real impl in Slice 2. The real version tears down the
/// connection / read thread. Void return: nothing owned yet, so a no-op.
pub fn threadExit(self: *Client, td: *termio.Termio.ThreadData) void {
    _ = self;
    _ = td;
}

/// Slice 1 stub — real impl in Slice 2. Focus changes will be forwarded to the
/// host; nothing to do yet.
pub fn focusGained(
    self: *Client,
    td: *termio.Termio.ThreadData,
    focused: bool,
) !void {
    _ = self;
    _ = td;
    _ = focused;
}

/// Slice 1 stub — real impl in Slice 2. Resizes will be forwarded to the host.
pub fn resize(
    self: *Client,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
) !void {
    _ = self;
    _ = grid_size;
    _ = screen_size;
}

/// Slice 1 stub — real impl in Slice 2. The real version frames `data` and
/// sends it to the host. Returning an error keeps a (mis)selected `.client`
/// from silently dropping user input.
pub fn queueWrite(
    self: *Client,
    alloc: Allocator,
    td: *termio.Termio.ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    _ = self;
    _ = alloc;
    _ = td;
    _ = data;
    _ = linefeed;
    return error.NotImplemented;
}

/// Slice 1 stub — real impl in Slice 2. Mirrors the `Backend` arm's call shape;
/// note this method is currently never analyzed (the `Backend` wrapper has no
/// callers), so the signature here just has to match for when it is.
pub fn childExitedAbnormally(
    self: *Client,
    gpa: Allocator,
    t: *terminal.Terminal,
    exit_code: u32,
    runtime_ms: u64,
) !void {
    _ = self;
    _ = gpa;
    _ = t;
    _ = exit_code;
    _ = runtime_ms;
}

/// Get information about the process(es) attached to the backend.
///
/// Slice 1 stub — real impl in Slice 2. Returns `null` ("not available"),
/// which is an explicitly supported result of this API.
pub fn getProcessInfo(self: *Client, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
    _ = self;
    return null;
}

/// The thread local data for the client implementation. Mirrors
/// `Exec.ThreadData`'s shape for the union arm; empty in Slice 1.
///
/// Slice 1 stub — real impl in Slice 2.
pub const ThreadData = struct {
    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        _ = self;
        _ = alloc;
    }
};

/// Configuration for the client backend. Empty in Slice 1; mirrors
/// `Exec.Config`'s role as the `Config` union arm.
///
/// Slice 1 stub — real impl in Slice 2.
pub const Config = struct {};
