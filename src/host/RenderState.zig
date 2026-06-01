//! Host-side RenderState projection (Phase 1).
//!
//! This builds a pointer-free, self-contained Snapshot of a terminal's
//! `RenderState` (the viewport grid) suitable for (a) diffing between frames
//! and printing the diff to stdout (the GPU-free renderer-thread replacement),
//! and (b) round-tripping through a flat byte buffer (the basis of the Phase 2
//! wire format). The serializer STRIPS the `PageList.Pin` identity
//! (`viewport_pin` and per-row `pin`) which is not safe to compare across
//! terminal mutations; frames are compared by content only.
//!
//! The projection is pointer-free because the only managed member of a
//! `page.Cell` is its grapheme data, which `RenderState.update` arena-
//! duplicates; we copy the grapheme codepoints inline so the Snapshot owns
//! all its memory.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const renderer = @import("../renderer.zig");
const terminalpkg = @import("../terminal/main.zig");
const render = @import("../terminal/render.zig");
const page = @import("../terminal/page.zig");
const color = @import("../terminal/color.zig");
const RenderState = render.RenderState;

const log = std.log.scoped(.host_render);

/// A single cell in the snapshot: the raw page.Cell (a packed u64, pointer-
/// free) plus any grapheme codepoints copied inline.
pub const Cell = struct {
    raw: page.Cell,
    grapheme: []const u21 = &.{},

    pub fn eql(a: Cell, b: Cell) bool {
        const ai: u64 = @bitCast(a.raw);
        const bi: u64 = @bitCast(b.raw);
        if (ai != bi) return false;
        if (a.grapheme.len != b.grapheme.len) return false;
        return std.mem.eql(u21, a.grapheme, b.grapheme);
    }
};

/// A single row in the snapshot.
pub const Row = struct {
    cells: []Cell,

    fn eql(a: Row, b: Row) bool {
        if (a.cells.len != b.cells.len) return false;
        for (a.cells, b.cells) |ca, cb| {
            if (!ca.eql(cb)) return false;
        }
        return true;
    }
};

/// A self-contained, pointer-free (PageList.Pin-stripped) projection of a
/// terminal's viewport RenderState.
pub const Snapshot = struct {
    rows: u16,
    cols: u16,

    /// Colors (reverse-video already applied by RenderState.update).
    background: color.RGB,
    foreground: color.RGB,

    /// Cursor projection (pointer-free fields only).
    cursor_x: u16,
    cursor_y: u32,
    cursor_visible: bool,
    cursor_blinking: bool,
    /// The cursor cell as a raw page.Cell bitcast.
    cursor_cell: page.Cell,

    /// The viewport rows, top to bottom. Length == rows.
    row_data: []Row,

    /// Backing storage for all grapheme codepoints, so we can free in one shot.
    /// May be empty.
    grapheme_pool: []u21,

    /// Capture a Snapshot from a live renderer.State. The caller MUST hold
    /// `state.mutex` for the duration of this call: it runs RenderState.update
    /// (which reads the terminal) and copies all needed data out.
    pub fn capture(alloc: Allocator, state: *const renderer.State) !Snapshot {
        // Build a transient RenderState, update it from the terminal, then
        // project it into our pointer-free form. We keep the RenderState local
        // so its arena memory is freed when we're done.
        var rs: RenderState = .empty;
        defer rs.deinit(alloc);
        try rs.update(alloc, state.terminal);

        return try fromRenderState(alloc, &rs);
    }

    /// Project a populated RenderState into a Snapshot. Exposed for tests.
    pub fn fromRenderState(alloc: Allocator, rs: *const RenderState) !Snapshot {
        const rows: u16 = rs.rows;
        const cols: u16 = rs.cols;

        // Count grapheme codepoints so we can allocate the pool once.
        var grapheme_total: usize = 0;
        const src = rs.row_data.slice();
        const src_cells = src.items(.cells);
        for (0..rs.row_data.len) |y| {
            const cells = src_cells[y];
            const cell_slice = cells.slice();
            for (cell_slice.items(.grapheme), cell_slice.items(.raw)) |g, raw| {
                if (raw.content_tag == .codepoint_grapheme) grapheme_total += g.len;
            }
        }

        const grapheme_pool = try alloc.alloc(u21, grapheme_total);
        errdefer alloc.free(grapheme_pool);

        const row_data = try alloc.alloc(Row, rows);
        errdefer alloc.free(row_data);

        var g_off: usize = 0;
        var allocated_rows: usize = 0;
        errdefer for (0..allocated_rows) |y| alloc.free(row_data[y].cells);

        for (0..rows) |y| {
            const out_cells = try alloc.alloc(Cell, cols);
            row_data[y] = .{ .cells = out_cells };
            allocated_rows += 1;

            // Rows beyond row_data.len shouldn't happen (update guarantees
            // row_data.len == rows), but be defensive.
            if (y >= rs.row_data.len) {
                for (out_cells) |*c| c.* = .{ .raw = .{}, .grapheme = &.{} };
                continue;
            }

            const cells = src_cells[y];
            const cell_slice = cells.slice();
            const raws = cell_slice.items(.raw);
            const graphemes = cell_slice.items(.grapheme);

            for (0..cols) |x| {
                if (x >= cells.len) {
                    out_cells[x] = .{ .raw = .{}, .grapheme = &.{} };
                    continue;
                }
                const raw = raws[x];
                if (raw.content_tag == .codepoint_grapheme) {
                    const g = graphemes[x];
                    const dst = grapheme_pool[g_off .. g_off + g.len];
                    @memcpy(dst, g);
                    g_off += g.len;
                    out_cells[x] = .{ .raw = raw, .grapheme = dst };
                } else {
                    out_cells[x] = .{ .raw = raw, .grapheme = &.{} };
                }
            }
        }

        return .{
            .rows = rows,
            .cols = cols,
            .background = rs.colors.background,
            .foreground = rs.colors.foreground,
            .cursor_x = rs.cursor.active.x,
            .cursor_y = rs.cursor.active.y,
            .cursor_visible = rs.cursor.visible,
            .cursor_blinking = rs.cursor.blinking,
            .cursor_cell = rs.cursor.cell,
            .row_data = row_data,
            .grapheme_pool = grapheme_pool,
        };
    }

    pub fn deinit(self: *Snapshot, alloc: Allocator) void {
        for (self.row_data) |row| alloc.free(row.cells);
        alloc.free(self.row_data);
        alloc.free(self.grapheme_pool);
        self.* = undefined;
    }

    /// Content equality (PageList.Pin already stripped by construction).
    pub fn eql(a: Snapshot, b: Snapshot) bool {
        if (a.rows != b.rows or a.cols != b.cols) return false;
        if (!std.meta.eql(a.background, b.background)) return false;
        if (!std.meta.eql(a.foreground, b.foreground)) return false;
        if (a.cursor_x != b.cursor_x or a.cursor_y != b.cursor_y) return false;
        if (a.cursor_visible != b.cursor_visible) return false;
        if (a.cursor_blinking != b.cursor_blinking) return false;
        {
            const ai: u64 = @bitCast(a.cursor_cell);
            const bi: u64 = @bitCast(b.cursor_cell);
            if (ai != bi) return false;
        }
        if (a.row_data.len != b.row_data.len) return false;
        for (a.row_data, b.row_data) |ra, rb| {
            if (!ra.eql(rb)) return false;
        }
        return true;
    }

    /// Serialize this snapshot into a flat, pointer-free byte buffer. The
    /// caller owns the returned slice. This is the basis of the Phase 2 wire
    /// format; the PageList.Pin is already stripped (never captured).
    pub fn serialize(self: Snapshot, alloc: Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(alloc);
        const w = buf.writer(alloc);

        try writeInt(w, u16, self.rows);
        try writeInt(w, u16, self.cols);
        try writeRGB(w, self.background);
        try writeRGB(w, self.foreground);
        try writeInt(w, u16, self.cursor_x);
        try writeInt(w, u32, self.cursor_y);
        try w.writeByte(@intFromBool(self.cursor_visible));
        try w.writeByte(@intFromBool(self.cursor_blinking));
        try writeInt(w, u64, @bitCast(self.cursor_cell));

        for (self.row_data) |row| {
            for (row.cells) |cell| {
                try writeInt(w, u64, @bitCast(cell.raw));
                try writeInt(w, u16, @intCast(cell.grapheme.len));
                for (cell.grapheme) |cp| try writeInt(w, u32, cp);
            }
        }

        return buf.toOwnedSlice(alloc);
    }

    /// Deserialize a snapshot from a flat byte buffer produced by serialize.
    /// The caller owns the returned Snapshot (call deinit).
    pub fn deserialize(alloc: Allocator, bytes: []const u8) !Snapshot {
        var fbs = std.io.fixedBufferStream(bytes);
        const r = fbs.reader();

        const rows = try readInt(r, u16);
        const cols = try readInt(r, u16);
        const background = try readRGB(r);
        const foreground = try readRGB(r);
        const cursor_x = try readInt(r, u16);
        const cursor_y = try readInt(r, u32);
        const cursor_visible = (try r.readByte()) != 0;
        const cursor_blinking = (try r.readByte()) != 0;
        const cursor_cell: page.Cell = @bitCast(try readInt(r, u64));

        // First pass to count grapheme codepoints would require seeking; we
        // instead build into a temporary list then copy into a single pool.
        var g_list: std.ArrayList(u21) = .empty;
        errdefer g_list.deinit(alloc);

        const row_data = try alloc.alloc(Row, rows);
        errdefer alloc.free(row_data);

        var allocated_rows: usize = 0;
        errdefer for (0..allocated_rows) |y| alloc.free(row_data[y].cells);

        // We must record grapheme (offset,len) per cell so we can patch the
        // slices after the pool is finalized.
        const Span = struct { row: usize, col: usize, off: usize, len: usize };
        var spans: std.ArrayList(Span) = .empty;
        defer spans.deinit(alloc);

        for (0..rows) |y| {
            const cells = try alloc.alloc(Cell, cols);
            row_data[y] = .{ .cells = cells };
            allocated_rows += 1;

            for (0..cols) |x| {
                const raw: page.Cell = @bitCast(try readInt(r, u64));
                const glen = try readInt(r, u16);
                const off = g_list.items.len;
                for (0..glen) |_| {
                    const cp: u21 = @intCast(try readInt(r, u32));
                    try g_list.append(alloc, cp);
                }
                cells[x] = .{ .raw = raw, .grapheme = &.{} };
                if (glen > 0) try spans.append(alloc, .{
                    .row = y,
                    .col = x,
                    .off = off,
                    .len = glen,
                });
            }
        }

        const grapheme_pool = try g_list.toOwnedSlice(alloc);
        errdefer alloc.free(grapheme_pool);

        for (spans.items) |s| {
            row_data[s.row].cells[s.col].grapheme = grapheme_pool[s.off .. s.off + s.len];
        }

        return .{
            .rows = rows,
            .cols = cols,
            .background = background,
            .foreground = foreground,
            .cursor_x = cursor_x,
            .cursor_y = cursor_y,
            .cursor_visible = cursor_visible,
            .cursor_blinking = cursor_blinking,
            .cursor_cell = cursor_cell,
            .row_data = row_data,
            .grapheme_pool = grapheme_pool,
        };
    }
};

/// Print the diff between an optional previous snapshot and the current one.
/// Returns the number of changed rows (the diff size). When there is no
/// previous snapshot, every non-blank row counts as changed.
///
/// The real `ghostty-host` binary writes the diff to stdout (the GPU-free
/// renderer-thread replacement). Under `zig build test`, however, the test
/// runner speaks a binary IPC protocol with the build runner over stdout
/// (`--listen=-`); any raw byte we write there corrupts that framing and
/// deadlocks the build runner in `Server.receiveMessage`. So in test builds
/// we emit to stderr instead, which the protocol leaves alone. The acceptance
/// ("emits RenderState diffs") holds on both channels.
///
/// The per-row line is accumulated into a heap `std.ArrayList(u8)` (reused
/// across rows) rather than a fixed stack buffer, so a wide row or a row of
/// multi-codepoint grapheme clusters (combining marks) is rendered in full
/// instead of being silently truncated at a fixed ceiling. Takes the
/// Allocator so it can own that line buffer; called from Session.renderTick
/// with the session allocator.
pub fn printDiff(alloc: Allocator, prev: ?Snapshot, cur: Snapshot) !usize {
    const out = if (builtin.is_test)
        std.fs.File.stderr()
    else
        std.fs.File.stdout();

    var changed: usize = 0;

    // Reused per-row line buffer. Grows to the widest row; never truncates.
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(alloc);

    // Determine, per row, whether it changed.
    for (cur.row_data, 0..) |row, y| {
        const row_changed = blk: {
            if (prev) |p| {
                if (y >= p.row_data.len) break :blk true;
                break :blk !row.eql(p.row_data[y]);
            }
            // No previous: a row counts as changed if it has any non-blank cell.
            for (row.cells) |c| {
                if (!isBlank(c)) break :blk true;
            }
            break :blk false;
        };
        if (!row_changed) continue;
        changed += 1;

        // Render the row's text into the line buffer and print it.
        line.clearRetainingCapacity();
        const w = line.writer(alloc);
        w.print("[row {d:>3}] ", .{y}) catch {};
        for (row.cells) |c| {
            renderCellText(w, c) catch {};
        }
        out.writeAll(line.items) catch {};
        out.writeAll("\n") catch {};
    }

    return changed;
}

fn isBlank(c: Cell) bool {
    if (c.raw.content_tag != .codepoint) return false;
    return c.raw.content.codepoint == 0 or c.raw.content.codepoint == ' ';
}

fn renderCellText(w: anytype, c: Cell) !void {
    switch (c.raw.content_tag) {
        .codepoint => {
            const cp = c.raw.content.codepoint;
            if (cp == 0) {
                try w.writeByte(' ');
            } else {
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(@intCast(cp), &buf) catch {
                    try w.writeByte('?');
                    return;
                };
                try w.writeAll(buf[0..n]);
            }
        },
        .codepoint_grapheme => {
            const cp = c.raw.content.codepoint;
            var buf: [4]u8 = undefined;
            if (std.unicode.utf8Encode(@intCast(cp), &buf)) |n| {
                try w.writeAll(buf[0..n]);
            } else |_| {}
            for (c.grapheme) |g| {
                if (std.unicode.utf8Encode(@intCast(g), &buf)) |n| {
                    try w.writeAll(buf[0..n]);
                } else |_| {}
            }
        },
        .bg_color_palette, .bg_color_rgb => try w.writeByte(' '),
    }
}

// --- little-endian primitive helpers (kept explicit for wire stability) ---

fn writeInt(w: anytype, comptime T: type, v: T) !void {
    try w.writeInt(T, v, .little);
}

fn readInt(r: anytype, comptime T: type) !T {
    return r.readInt(T, .little);
}

fn writeRGB(w: anytype, rgb: color.RGB) !void {
    try w.writeByte(rgb.r);
    try w.writeByte(rgb.g);
    try w.writeByte(rgb.b);
}

fn readRGB(r: anytype) !color.RGB {
    return .{
        .r = try r.readByte(),
        .g = try r.readByte(),
        .b = try r.readByte(),
    };
}
