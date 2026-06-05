const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const ProcessInfo = @import("../pty.zig").ProcessInfo;

// The preallocation size for the write request pool. This should be big
// enough to satisfy most write requests. It must be a power of 2.
const WRITE_REQ_PREALLOC = std.math.pow(usize, 2, 5);

/// The kinds of backends.
pub const Kind = enum { exec, client };

/// Configuration for the various backend types.
pub const Config = union(Kind) {
    /// Exec uses posix exec to run a command with a pty.
    exec: termio.Exec.Config,

    /// Client talks to an out-of-process pty host. Slice 1 stub; not yet
    /// selectable (see termio/Client.zig).
    client: termio.Client.Config,
};

/// Backend implementations. A backend is responsible for owning the pty
/// behavior and providing read/write capabilities.
pub const Backend = union(Kind) {
    exec: termio.Exec,
    client: termio.Client,

    pub fn deinit(self: *Backend) void {
        switch (self.*) {
            .exec => |*exec| exec.deinit(),
            .client => |*client| client.deinit(),
        }
    }

    pub fn initTerminal(self: *Backend, t: *terminal.Terminal) void {
        switch (self.*) {
            .exec => |*exec| exec.initTerminal(t),
            .client => |*client| client.initTerminal(t),
        }
    }

    pub fn threadEnter(
        self: *Backend,
        alloc: Allocator,
        io: *termio.Termio,
        td: *termio.Termio.ThreadData,
    ) !void {
        switch (self.*) {
            .exec => |*exec| try exec.threadEnter(alloc, io, td),
            .client => |*client| try client.threadEnter(alloc, io, td),
        }
    }

    pub fn threadExit(self: *Backend, td: *termio.Termio.ThreadData) void {
        switch (self.*) {
            .exec => |*exec| exec.threadExit(td),
            .client => |*client| client.threadExit(td),
        }
    }

    pub fn focusGained(
        self: *Backend,
        td: *termio.Termio.ThreadData,
        focused: bool,
    ) !void {
        switch (self.*) {
            .exec => |*exec| try exec.focusGained(td, focused),
            .client => |*client| try client.focusGained(td, focused),
        }
    }

    pub fn resize(
        self: *Backend,
        td: *termio.Termio.ThreadData,
        size: renderer.Size,
    ) !void {
        switch (self.*) {
            // Exec keeps its grid/screen API and does not need td.
            .exec => |*exec| try exec.resize(size.grid(), size.terminal()),
            // Client needs td (to send a Resize frame on the write stream)
            // and the full size (cell/padding/screen all round-trip the wire).
            .client => |*client| try client.resize(td, size),
        }
    }

    pub fn queueWrite(
        self: *Backend,
        alloc: Allocator,
        td: *termio.Termio.ThreadData,
        data: []const u8,
        linefeed: bool,
    ) !void {
        switch (self.*) {
            .exec => |*exec| try exec.queueWrite(alloc, td, data, linefeed),
            .client => |*client| try client.queueWrite(alloc, td, data, linefeed),
        }
    }

    /// Scroll the viewport. For .exec this scrolls the LOCAL terminal
    /// synchronously (byte-for-byte identical to the pre-Slice-7 behavior);
    /// for .client it sends a `scroll_viewport` frame to the host, which
    /// repins ITS terminal and ships the scrolled viewport on the next
    /// GridFrame (the local mirror terminal is unused under .client).
    pub fn scrollViewport(
        self: *Backend,
        td: *termio.Termio.ThreadData,
        scroll: terminal.Terminal.ScrollViewport,
    ) !void {
        switch (self.*) {
            .exec => |*exec| exec.scrollViewport(td, scroll),
            .client => |*client| try client.scrollViewport(td, scroll),
        }
    }

    /// Jump the viewport to a prompt by `delta` (negative = up). Same .exec
    /// (local, synchronous) vs .client (frame to host) split as scrollViewport.
    pub fn jumpToPrompt(
        self: *Backend,
        td: *termio.Termio.ThreadData,
        delta: isize,
    ) !void {
        switch (self.*) {
            .exec => |*exec| exec.jumpToPrompt(td, delta),
            .client => |*client| try client.jumpToPrompt(td, delta),
        }
    }

    /// Slice B1: drag-select routing. Under .exec the Surface drives the local
    /// terminal's selection directly, so this is a no-op (the message is never
    /// enqueued under .exec — but be defensive). Under .client it forwards the
    /// viewport geometry to the host via a `selection_drag` frame.
    pub fn selectionDrag(
        self: *Backend,
        td: *termio.Termio.ThreadData,
        drag: termio.Message.SelectionDrag,
    ) !void {
        switch (self.*) {
            .exec => {},
            .client => |*client| try client.selectionDrag(td, drag),
        }
    }

    /// Slice B1: selection-clear routing. .exec no-op; .client sends a
    /// `selection_clear` frame.
    pub fn selectionClear(
        self: *Backend,
        td: *termio.Termio.ThreadData,
    ) !void {
        switch (self.*) {
            .exec => {},
            .client => |*client| try client.selectionClear(td),
        }
    }

    /// Slice B2: word/line/all select-point routing. Under .exec the Surface
    /// drives the local terminal's selection directly, so this is an inert
    /// no-op (the message is never enqueued under .exec — but be defensive).
    /// Under .client it forwards the click point + granularity to the host via
    /// a `selection_point` frame.
    pub fn selectionPoint(
        self: *Backend,
        td: *termio.Termio.ThreadData,
        pt: termio.Message.SelectionPoint,
    ) !void {
        switch (self.*) {
            .exec => {},
            .client => |*client| try client.selectionPoint(td, pt),
        }
    }

    pub fn childExitedAbnormally(
        self: *Backend,
        gpa: Allocator,
        t: *terminal.Terminal,
        exit_code: u32,
        runtime_ms: u64,
    ) !void {
        switch (self.*) {
            .exec => |*exec| try exec.childExitedAbnormally(
                gpa,
                t,
                exit_code,
                runtime_ms,
            ),
            .client => |*client| try client.childExitedAbnormally(
                gpa,
                t,
                exit_code,
                runtime_ms,
            ),
        }
    }

    /// Get information about the process(es) attached to the backend. Returns
    /// `null` if there was an error getting the information or the information
    /// is not available on a particular platform.
    pub fn getProcessInfo(self: *Backend, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
        return switch (self.*) {
            .exec => |*exec| exec.getProcessInfo(info),
            .client => |*client| client.getProcessInfo(info),
        };
    }
};

/// Termio thread data. See termio.ThreadData for docs.
pub const ThreadData = union(Kind) {
    exec: termio.Exec.ThreadData,
    client: termio.Client.ThreadData,

    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        switch (self.*) {
            .exec => |*exec| exec.deinit(alloc),
            .client => |*client| client.deinit(alloc),
        }
    }

    pub fn changeConfig(self: *ThreadData, config: *termio.DerivedConfig) void {
        _ = self;
        _ = config;
    }
};
