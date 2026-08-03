//! FORK(host-handoff): top-level session-state transfer for `ghostty-host`.
//!
//! A running `ghostty-host` process can hand a live terminal session's full
//! emulation state to a successor process built from the IDENTICAL binary. This
//! module is the thin orchestrator around `terminal.Terminal.serialize` /
//! `deserialize`: it frames the state with a MAGIC and a layout FINGERPRINT so a
//! mismatched build fails loudly instead of decoding garbage.
//!
//! This is a SAME-VERSION contract: both ends are the same build, so we do not
//! need (and do not attempt) cross-version schema compatibility. What we DO
//! guarantee is full fidelity — the rebuilt Terminal is equal to the original,
//! down to scrollback, cursor style, selection, charsets, kitty graphics, and
//! the Glyph Protocol glossary.
//!
//! Platform-neutral: the host is built on both macOS and the Linux cloud box,
//! and this file must compile on all targets (it contains no OS-specific code).
//!
//! The `writer`/`reader` are generic (matching `src/host/protocol.zig`): a
//! writer with `writeInt`/`writeByte`/`writeAll` and a reader with
//! `readInt`/`readByte`/`readNoEof`. Tests round-trip through an in-memory
//! `std.ArrayList(u8)` / `std.io.fixedBufferStream`.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const terminal = @import("../terminal/main.zig");
const Terminal = terminal.Terminal;
const Screen = terminal.Screen;

/// Stream identifier + wire version. Bytes read "GHOSTHH" + version 0x01. Bump
/// the trailing byte on any incompatible change to the framing itself (the
/// per-type layout is additionally guarded by the fingerprint below).
pub const MAGIC: u64 = 0x47_48_4f_53_54_48_48_01;

pub const Error = error{
    /// The stream did not begin with `MAGIC` (not a handoff blob, or corrupt).
    HandoffBadMagic,
    /// The stream was produced by a build whose in-memory type layout differs
    /// from ours. Same-build handoff is required; refuse rather than corrupt.
    HandoffLayoutMismatch,
};

/// A compact fingerprint of the in-memory layout of the types whose raw bytes
/// ride the wire (page memory, cells, pins, etc.). Any struct-size drift
/// between the two builds — the exact thing that would silently corrupt a
/// raw-bytes transfer — changes this and is rejected on read.
fn layoutFingerprint() [10]u32 {
    return .{
        @sizeOf(Terminal),
        @sizeOf(terminal.Screen),
        @sizeOf(terminal.PageList),
        @sizeOf(terminal.Page),
        @sizeOf(terminal.page.Row),
        @sizeOf(terminal.Cell),
        @sizeOf(terminal.Pin),
        @sizeOf(terminal.Style),
        @sizeOf(terminal.modes.ModePacked),
        @sizeOf(terminal.PageList.Pin),
    };
}

/// Serialize a full terminal session to `writer` (magic + fingerprint + state).
pub fn serialize(t: *const Terminal, writer: anytype) !void {
    try writer.writeInt(u64, MAGIC, .little);
    for (layoutFingerprint()) |v| try writer.writeInt(u32, v, .little);
    try t.serialize(writer);
}

/// Rebuild a full terminal session written by `serialize`. The returned
/// terminal owns all its memory and must be `deinit`ed with `alloc`.
pub fn deserialize(alloc: Allocator, reader: anytype) !Terminal {
    const magic = try reader.readInt(u64, .little);
    if (magic != MAGIC) return Error.HandoffBadMagic;
    for (layoutFingerprint()) |expected| {
        const got = try reader.readInt(u32, .little);
        if (got != expected) return Error.HandoffLayoutMismatch;
    }
    return try Terminal.deserialize(alloc, reader);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Serialize `t` to an in-memory buffer and deserialize a fresh Terminal from
/// it. The caller owns the returned Terminal.
fn roundTrip(alloc: Allocator, t: *const Terminal) !Terminal {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try serialize(t, buf.writer(alloc));

    var fbs = std.io.fixedBufferStream(buf.items);
    return try deserialize(alloc, fbs.reader());
}

/// Assert that two screens have identical full contents INCLUDING scrollback.
fn expectScreenContentsEqual(alloc: Allocator, a: *const Screen, b: *const Screen) !void {
    const sa = try a.dumpStringAlloc(alloc, .{ .screen = .{ .x = 0, .y = 0 } });
    defer alloc.free(sa);
    const sb = try b.dumpStringAlloc(alloc, .{ .screen = .{ .x = 0, .y = 0 } });
    defer alloc.free(sb);
    try testing.expectEqualStrings(sa, sb);
}

/// Assert the two terminals are equal across the state a session cares about.
fn expectTerminalsEqual(alloc: Allocator, a: *const Terminal, b: *const Terminal) !void {
    // Dimensions.
    try testing.expectEqual(a.cols, b.cols);
    try testing.expectEqual(a.rows, b.rows);
    try testing.expectEqual(a.width_px, b.width_px);
    try testing.expectEqual(a.height_px, b.height_px);

    // Scalar emulation state.
    try testing.expectEqual(a.status_display, b.status_display);
    try testing.expectEqual(a.scrolling_region, b.scrolling_region);
    try testing.expect(std.meta.eql(a.modes, b.modes));
    try testing.expectEqual(a.mouse_shape, b.mouse_shape);
    try testing.expect(std.meta.eql(a.flags, b.flags));
    try testing.expectEqual(a.previous_char, b.previous_char);
    try testing.expect(std.meta.eql(a.colors, b.colors));

    // Title / pwd.
    try testing.expectEqualStrings(a.title.items, b.title.items);
    try testing.expectEqualStrings(a.pwd.items, b.pwd.items);

    // Active screen.
    try testing.expectEqual(a.screens.active_key, b.screens.active_key);

    // Primary screen: contents (incl. scrollback), cursor, selection.
    const ap = a.screens.get(.primary).?;
    const bp = b.screens.get(.primary).?;
    try expectScreenContentsEqual(alloc, ap, bp);
    try expectCursorsEqual(ap, bp);
    try expectSelectionsEqual(ap, bp);
    try testing.expect(std.meta.eql(ap.charset, bp.charset));

    // Alternate screen must survive iff it existed.
    try testing.expectEqual(a.screens.get(.alternate) != null, b.screens.get(.alternate) != null);
    if (a.screens.get(.alternate)) |aa| {
        const ba = b.screens.get(.alternate).?;
        try expectScreenContentsEqual(alloc, aa, ba);
        try expectCursorsEqual(aa, ba);
        try expectSelectionsEqual(aa, ba);
    }
}

fn expectCursorsEqual(a: *const Screen, b: *const Screen) !void {
    try testing.expectEqual(a.cursor.x, b.cursor.x);
    try testing.expectEqual(a.cursor.y, b.cursor.y);
    try testing.expectEqual(a.cursor.pending_wrap, b.cursor.pending_wrap);
    try testing.expectEqual(a.cursor.cursor_style, b.cursor.cursor_style);
    try testing.expectEqual(a.cursor.style_id, b.cursor.style_id);
    try testing.expect(std.meta.eql(a.cursor.style, b.cursor.style));
    try testing.expectEqual(a.cursor.hyperlink_id, b.cursor.hyperlink_id);
}

fn expectSelectionsEqual(a: *const Screen, b: *const Screen) !void {
    try testing.expectEqual(a.selection == null, b.selection == null);
    if (a.selection) |asel| {
        const bsel = b.selection.?;
        try testing.expectEqual(asel.rectangle, bsel.rectangle);
        // Compare the endpoint locations LOGICALLY (the node pointers legitimately
        // differ between the two terminals; the screen coordinates must match).
        try testing.expectEqual(
            a.pages.pointFromPin(.screen, asel.bounds.tracked.start.*),
            b.pages.pointFromPin(.screen, bsel.bounds.tracked.start.*),
        );
        try testing.expectEqual(
            a.pages.pointFromPin(.screen, asel.bounds.tracked.end.*),
            b.pages.pointFromPin(.screen, bsel.bounds.tracked.end.*),
        );
    }
}

test "session_transfer: empty terminal round-trips" {
    const alloc = testing.allocator;
    var t = try Terminal.init(alloc, .{ .cols = 80, .rows = 24 });
    defer t.deinit(alloc);

    var t2 = try roundTrip(alloc, &t);
    defer t2.deinit(alloc);

    try expectTerminalsEqual(alloc, &t, &t2);
}

test "session_transfer: active-area-only content round-trips" {
    const alloc = testing.allocator;
    var t = try Terminal.init(alloc, .{ .cols = 20, .rows = 5 });
    defer t.deinit(alloc);

    try t.printString("hello world");

    var t2 = try roundTrip(alloc, &t);
    defer t2.deinit(alloc);

    try expectTerminalsEqual(alloc, &t, &t2);
}

test "session_transfer: scrollback + title + modes + region + alt + cursor + selection" {
    const alloc = testing.allocator;
    var t = try Terminal.init(alloc, .{ .cols = 16, .rows = 4 });
    defer t.deinit(alloc);

    // Push well beyond the active viewport so rows land in scrollback.
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        var buf: [32]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "row-{d:0>3}\n", .{i});
        try t.printString(line);
    }

    // Title + pwd.
    try t.setTitle("my session");
    try t.pwd.appendSlice(alloc, "/home/user/project");

    // Flip some modes and a scrolling region.
    t.modes.set(.reverse_colors, true);
    t.modes.set(.cursor_keys, true);
    t.setTopAndBottomMargin(2, 3);

    // Move the cursor somewhere specific.
    t.setCursorPos(2, 5);

    // Make a selection on the primary screen.
    if (t.screens.active.selectAll()) |sel| try t.screens.active.select(sel);

    // Switch to the alternate screen, write there, and stay on it.
    _ = try t.switchScreen(.alternate);
    try t.printString("ALT SCREEN CONTENT\nsecond alt line");

    // Set previous_char AFTER all printing (print() overwrites it).
    t.previous_char = 'x';

    var t2 = try roundTrip(alloc, &t);
    defer t2.deinit(alloc);

    try expectTerminalsEqual(alloc, &t, &t2);

    // Spot-check specific carried state.
    try testing.expectEqual(.alternate, t2.screens.active_key);
    try testing.expect(t2.modes.get(.reverse_colors));
    try testing.expect(t2.modes.get(.cursor_keys));
    try testing.expectEqualStrings("my session", t2.getTitle().?);
    try testing.expectEqualStrings("/home/user/project", t2.pwd.items);
    try testing.expectEqual(@as(?u21, 'x'), t2.previous_char);
    try testing.expectEqual(@as(terminal.size.CellCountInt, 1), t2.scrolling_region.top);
    try testing.expectEqual(@as(terminal.size.CellCountInt, 2), t2.scrolling_region.bottom);

    // The source primary screen must have actually held a selection (test
    // integrity); the round-trip preserves it (checked by expectTerminalsEqual).
    try testing.expect(t.screens.get(.primary).?.selection != null);
}

test "session_transfer: return to primary after alternate preserves both" {
    const alloc = testing.allocator;
    var t = try Terminal.init(alloc, .{ .cols = 12, .rows = 4 });
    defer t.deinit(alloc);

    try t.printString("primary line one\nprimary line two");
    _ = try t.switchScreen(.alternate);
    try t.printString("on the alt screen");
    _ = try t.switchScreen(.primary);

    var t2 = try roundTrip(alloc, &t);
    defer t2.deinit(alloc);

    try expectTerminalsEqual(alloc, &t, &t2);
    try testing.expectEqual(.primary, t2.screens.active_key);
    try testing.expect(t2.screens.get(.alternate) != null);
}

test "session_transfer: wide and grapheme cells round-trip" {
    const alloc = testing.allocator;
    var t = try Terminal.init(alloc, .{ .cols = 20, .rows = 5 });
    defer t.deinit(alloc);

    // Enable grapheme clustering so combined sequences share a cell.
    t.modes.set(.grapheme_cluster, true);

    // Wide CJK, a flag emoji (regional indicators), and a skin-tone emoji.
    try t.printString("你好 世界\n");
    try t.printString("flag: \u{1F1FA}\u{1F1F8}\n");
    try t.printString("wave: \u{1F44B}\u{1F3FD}\n");

    var t2 = try roundTrip(alloc, &t);
    defer t2.deinit(alloc);

    try expectTerminalsEqual(alloc, &t, &t2);
}

test "session_transfer: no-scrollback terminal round-trips" {
    const alloc = testing.allocator;
    var t = try Terminal.init(alloc, .{ .cols = 10, .rows = 3, .max_scrollback = 0 });
    defer t.deinit(alloc);

    try t.printString("aaa\nbbb\nccc\nddd\neee");

    var t2 = try roundTrip(alloc, &t);
    defer t2.deinit(alloc);

    try testing.expect(t2.screens.active.no_scrollback);
    try expectTerminalsEqual(alloc, &t, &t2);
}

test "session_transfer: bad magic is rejected" {
    const alloc = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, &[_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 });

    var fbs = std.io.fixedBufferStream(buf.items);
    try testing.expectError(Error.HandoffBadMagic, deserialize(alloc, fbs.reader()));
}

test "session_transfer: layout-fingerprint mismatch is rejected" {
    const alloc = testing.allocator;
    var t = try Terminal.init(alloc, .{ .cols = 8, .rows = 2 });
    defer t.deinit(alloc);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try serialize(&t, buf.writer(alloc));

    // Corrupt the first fingerprint word (immediately after the 8-byte magic).
    buf.items[8] +%= 1;

    var fbs = std.io.fixedBufferStream(buf.items);
    try testing.expectError(Error.HandoffLayoutMismatch, deserialize(alloc, fbs.reader()));
}
