const std = @import("std");
const Allocator = std.mem.Allocator;
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const MessageData = @import("../datastruct/main.zig").MessageData;

/// The messages that can be sent to an IO thread.
///
/// This is not a tiny structure (~40 bytes at the time of writing this comment),
/// but the messages are IO thread sends are also very few. At the current size
/// we can queue 26,000 messages before consuming a MB of RAM.
pub const Message = union(enum) {
    /// Represents a write request. Magic number comes from the largest
    /// other union value. It can be upped if we add a larger union member
    /// in the future.
    pub const WriteReq = MessageData(u8, 38);

    /// Request a color scheme report is sent to the pty.
    color_scheme_report: struct {
        /// Force write the current color scheme
        force: bool,
    },

    /// Purposely crash the renderer. This is used for testing and debugging.
    /// See the "crash" binding action.
    crash: void,

    /// The derived configuration to update the implementation with. This
    /// is allocated via the allocator and is expected to be freed when done.
    change_config: struct {
        alloc: Allocator,
        ptr: *termio.Termio.DerivedConfig,
    },

    /// Activate or deactivate the inspector.
    inspector: bool,

    /// Resize the window.
    resize: renderer.Size,

    /// Request a size report is sent to the pty ([in-band
    /// size report, mode 2048](https://gist.github.com/rockorager/e695fb2924d36b2bcf1fff4a3704bd83) and
    /// [XTWINOPS](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html#h4-Functions-using-CSI-_-ordered-by-the-final-character-lparen-s-rparen:CSI-Ps;Ps;Ps-t.1EB0)).
    size_report: SizeReport,

    /// Clear the screen.
    clear_screen: struct {
        /// Include clearing the history
        history: bool,
    },

    /// Scroll the viewport
    scroll_viewport: terminal.Terminal.ScrollViewport,

    /// Selection scrolling. If this is set to true then the termio
    /// thread starts a timer that will trigger a `selection_scroll_tick`
    /// message back to the surface. This ping/pong is because the
    /// surface thread doesn't have access to an event loop from libghostty.
    selection_scroll: bool,

    /// Jump forward/backward n prompts.
    jump_to_prompt: isize,

    /// Slice B1: GUI->host drag-select. Carries only the VIEWPORT geometry of
    /// the current drag selection (anchor + head cells + rectangle flag); the
    /// Client fills in the session_id when building the wire frame. Under .exec
    /// this is a no-op (the Surface drives the local terminal selection
    /// directly); under .client the Client sends a `selection_drag` frame.
    selection_drag: SelectionDrag,

    /// Slice B1: GUI->host clear the selection. .exec no-op; .client sends a
    /// `selection_clear` frame.
    selection_clear: void,

    /// Slice B2: GUI->host word/line/all select-point. Carries a single click
    /// POINT (viewport coords) plus a granularity mode; the Client fills in the
    /// session_id when building the wire frame. Under .exec this is a no-op (the
    /// Surface drives the local terminal selection directly); under .client the
    /// Client sends a `selection_point` frame.
    selection_point: SelectionPoint,

    /// Send this when a synchronized output mode is started. This will
    /// start the timer so that the output mode is disabled after a
    /// period of time so that a bad actor can't hang the terminal.
    start_synchronized_output: void,

    /// Enable or disable linefeed mode (mode 20).
    linefeed_mode: bool,

    /// The surface gained or lost focus.
    focused: bool,

    /// Write where the data fits in the union.
    write_small: WriteReq.Small,

    /// Write where the data pointer is stable.
    write_stable: WriteReq.Stable,

    /// Write where the data is allocated and must be freed.
    write_alloc: WriteReq.Alloc,

    /// Return a write request for the given data. This will use
    /// write_small if it fits or write_alloc otherwise. This should NOT
    /// be used for stable pointers which can be manually set to write_stable.
    pub fn writeReq(alloc: Allocator, data: anytype) !Message {
        return switch (try WriteReq.init(alloc, data)) {
            .stable => unreachable,
            .small => |v| Message{ .write_small = v },
            .alloc => |v| Message{ .write_alloc = v },
        };
    }

    /// The types of size reports that we support.
    pub const SizeReport = terminal.size_report.Style;

    /// Slice B1: the VIEWPORT geometry of a drag selection. Plain scalars (no
    /// protocol import here) — the Client maps these onto the wire
    /// `protocol.SelectionDrag`, filling session_id from its atomic load.
    pub const SelectionDrag = struct {
        anchor_x: u16,
        anchor_y: u16,
        head_x: u16,
        head_y: u16,
        rectangle: bool,
    };

    /// Slice B2: a single click POINT (viewport coords) plus a granularity mode
    /// for word/line/all select. Plain scalars (no protocol import here) — the
    /// Client maps these onto the wire `protocol.SelectionPoint`, filling
    /// session_id from its atomic load. `mode` matches protocol.SelectionPoint's
    /// mode_word/mode_line/mode_all constants.
    pub const SelectionPoint = struct {
        x: u16,
        y: u16,
        mode: u8,

        /// Granularity mode constants. Kept in lock-step with
        /// `protocol.SelectionPoint.mode_word/mode_line/mode_all` (the Client
        /// copies `mode` onto the wire frame verbatim). Mirrored here so GUI
        /// call sites (Surface.zig) can name the mode without importing the
        /// host protocol module.
        pub const mode_word: u8 = 0;
        pub const mode_line: u8 = 1;
        pub const mode_all: u8 = 2;
    };
};

test {
    std.testing.refAllDecls(@This());
}

test {
    // Ensure we don't grow our IO message size without explicitly wanting to.
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 40), @sizeOf(Message));
}
