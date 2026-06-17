//! Host-side RenderState projection (Phase 1 + Phase 2a expansion).
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
//!
//! ## Phase 2a §2.1 GridFrame expansion
//!
//! Beyond Phase 1's rows/cols/colors/cursor/grapheme set, the Snapshot now
//! carries, toward a faithful §2.1 GridFrame round-trip:
//!   - `dirty` (false|partial|full) + per-row `dirty` flag with row-index
//!     framing (partial frames ship only dirty rows; reattach uses `.full`).
//!   - the full 256-entry `palette`, `cursor_color`, and the full cursor
//!     projection (visual_style, password_input, viewport, cursor_style POD).
//!   - a per-cell `StylePod` (a wire-stable 16-field projection of
//!     terminal.style.Style, NOT a bitcast of the private PackedStyle).
//!   - per-row `selection` + `highlights`.
//!   - header bits scrolled_to_bottom / synchronized_output / scrollbar triple
//!     / cursor_blink_visible.
//!
//! ### Documented §2.1 followups (NOT silently dropped)
//!
//!   - `scrolled_to_bottom`, `synchronized_output`, the `scrollbar` triple, and
//!     `cursor_blink_visible` are NOT derivable from the viewport-only
//!     RenderState: the scroll/scrollbar values are computed host-side in
//!     `src/renderer/generic.zig` per plan §1.1, and synchronized_output is a
//!     terminal mode read host-side. Phase 2a sets placeholders
//!     (scrolled_to_bottom=true, synchronized_output=false, scrollbar={0,0,0},
//!     cursor_blink_visible=true) that round-trip faithfully. Wiring these to
//!     real host-tick computation (`terminal.modes.get(.synchronized_output)`
//!     plus the scrollbar triple) is Phase 2b/3 work.
//!   - A deduped `u16 style_id -> POD` style table (§2.1 `nstyles`) is replaced
//!     in Phase 2a by an inline per-cell `StylePod`: simpler and correct,
//!     slightly larger wire. The dedup table is a Phase-2b size optimization.
//!   - The LinkFrame / ImageFrame / SurfaceEvent channels are Phase 3.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const renderer = @import("../renderer.zig");
const terminalpkg = @import("../terminal/main.zig");
const render = @import("../terminal/render.zig");
const page = @import("../terminal/page.zig");
const color = @import("../terminal/color.zig");
const cursorpkg = @import("../terminal/cursor.zig");
const stylepkg = @import("../terminal/style.zig");
const sgr = @import("../terminal/sgr.zig");
const RenderState = render.RenderState;

const log = std.log.scoped(.host_render);

/// A wire-stable, field-by-field projection of terminal.style.Style. We do NOT
/// bitcast the private `PackedStyle` (`style.zig` keeps it `const`/unexported);
/// instead we mirror the explicit public field set used by
/// `src/terminal/c/style.zig`'s `fromStyle`: fg/bg/underline `Color`, the 8
/// bool flags, and the underline enum.
pub const StylePod = struct {
    pub const ColorTag = enum(u8) { none = 0, palette = 1, rgb = 2 };

    pub const Color = struct {
        tag: ColorTag = .none,
        palette: u8 = 0,
        rgb: color.RGB = .{},

        fn fromColor(c: stylepkg.Style.Color) Color {
            return switch (c) {
                .none => .{ .tag = .none },
                .palette => |idx| .{ .tag = .palette, .palette = idx },
                .rgb => |rgb| .{ .tag = .rgb, .rgb = rgb },
            };
        }

        fn eql(a: Color, b: Color) bool {
            if (a.tag != b.tag) return false;
            return switch (a.tag) {
                .none => true,
                .palette => a.palette == b.palette,
                .rgb => a.rgb.eql(b.rgb),
            };
        }

        /// Compare this projected Color DIRECTLY against a source
        /// `terminal.style.Style.Color` union — by union tag + payload, NOT by
        /// routing the source through `fromColor` first. Part of the
        /// cross-path style assertion (finding DR-1): a `fromColor` mis-map
        /// would no longer be masked because we read the union's own tag and
        /// payload here.
        fn eqlSrc(self: Color, c: stylepkg.Style.Color) bool {
            return switch (c) {
                .none => self.tag == .none,
                .palette => |idx| self.tag == .palette and self.palette == idx,
                .rgb => |rgb| self.tag == .rgb and self.rgb.eql(rgb),
            };
        }

        fn write(self: Color, w: anytype) !void {
            try w.writeByte(@intFromEnum(self.tag));
            try w.writeByte(self.palette);
            try writeRGB(w, self.rgb);
        }

        fn read(r: anytype) !Color {
            const tag = try r.readByte();
            const pal = try r.readByte();
            const rgb = try readRGB(r);
            // Fail closed on an unknown tag, matching every other deserialize
            // validator (InvalidDirty / InvalidCursorStyle / InvalidRowIndex /
            // InvalidCodepoint / GridTooLarge): a corrupt/desynced/hostile frame
            // must return a clean error, never silently coerce to .none and
            // mask the corruption (finding PCR3-2).
            return .{
                .tag = std.meta.intToEnum(ColorTag, tag) catch
                    return error.InvalidColorTag,
                .palette = pal,
                .rgb = rgb,
            };
        }
    };

    fg_color: Color = .{},
    bg_color: Color = .{},
    underline_color: Color = .{},
    bold: bool = false,
    italic: bool = false,
    faint: bool = false,
    blink: bool = false,
    inverse: bool = false,
    invisible: bool = false,
    strikethrough: bool = false,
    overline: bool = false,
    underline: u8 = 0,

    pub fn fromStyle(s: stylepkg.Style) StylePod {
        return .{
            .fg_color = .fromColor(s.fg_color),
            .bg_color = .fromColor(s.bg_color),
            .underline_color = .fromColor(s.underline_color),
            .bold = s.flags.bold,
            .italic = s.flags.italic,
            .faint = s.flags.faint,
            .blink = s.flags.blink,
            .inverse = s.flags.inverse,
            .invisible = s.flags.invisible,
            .strikethrough = s.flags.strikethrough,
            .overline = s.flags.overline,
            .underline = @intFromEnum(s.flags.underline),
        };
    }

    /// Compare this projected StylePod field-by-field DIRECTLY against the
    /// source `terminal.style.Style` the renderer actually reads — NOT against
    /// `fromStyle(s)`. This deliberately breaks the self-reference: if
    /// `fromStyle` ever drops or mis-maps a Style field, the mirror it built no
    /// longer matches the raw Style and this returns false. Used by the
    /// differential fidelity test (difftest.zig) so the per-cell / cursor style
    /// legs are a true cross-path comparison against the renderer's input
    /// (finding DR-1). Mirrors the exact public Style surface `Style.eql`
    /// compares (fg/bg/underline Color + the 16-bit Flags).
    pub fn eqlStyle(self: StylePod, s: stylepkg.Style) bool {
        return self.fg_color.eqlSrc(s.fg_color) and
            self.bg_color.eqlSrc(s.bg_color) and
            self.underline_color.eqlSrc(s.underline_color) and
            self.bold == s.flags.bold and
            self.italic == s.flags.italic and
            self.faint == s.flags.faint and
            self.blink == s.flags.blink and
            self.inverse == s.flags.inverse and
            self.invisible == s.flags.invisible and
            self.strikethrough == s.flags.strikethrough and
            self.overline == s.flags.overline and
            self.underline == @intFromEnum(s.flags.underline);
    }

    pub fn eql(a: StylePod, b: StylePod) bool {
        return a.fg_color.eql(b.fg_color) and
            a.bg_color.eql(b.bg_color) and
            a.underline_color.eql(b.underline_color) and
            a.bold == b.bold and
            a.italic == b.italic and
            a.faint == b.faint and
            a.blink == b.blink and
            a.inverse == b.inverse and
            a.invisible == b.invisible and
            a.strikethrough == b.strikethrough and
            a.overline == b.overline and
            a.underline == b.underline;
    }

    fn write(self: StylePod, w: anytype) !void {
        try self.fg_color.write(w);
        try self.bg_color.write(w);
        try self.underline_color.write(w);
        try w.writeByte(@intFromBool(self.bold));
        try w.writeByte(@intFromBool(self.italic));
        try w.writeByte(@intFromBool(self.faint));
        try w.writeByte(@intFromBool(self.blink));
        try w.writeByte(@intFromBool(self.inverse));
        try w.writeByte(@intFromBool(self.invisible));
        try w.writeByte(@intFromBool(self.strikethrough));
        try w.writeByte(@intFromBool(self.overline));
        try w.writeByte(self.underline);
    }

    fn read(r: anytype) !StylePod {
        const fg_color = try Color.read(r);
        const bg_color = try Color.read(r);
        const underline_color = try Color.read(r);
        const bold = (try r.readByte()) != 0;
        const italic = (try r.readByte()) != 0;
        const faint = (try r.readByte()) != 0;
        const blink = (try r.readByte()) != 0;
        const inverse = (try r.readByte()) != 0;
        const invisible = (try r.readByte()) != 0;
        const strikethrough = (try r.readByte()) != 0;
        const overline = (try r.readByte()) != 0;
        // `underline` rides the wire as the raw u8 index of `sgr.Attribute.Underline`
        // (an enum(u3), valid members 0..5). The mirror's `rehydrateStyle`
        // (src/termio/Client.zig) feeds it straight into `@enumFromInt(pod.underline)`,
        // which is checked-illegal-behavior for an out-of-range value — a panic in
        // safe builds and UNDEFINED BEHAVIOR in the ReleaseFast .mirror lib. So a
        // corrupt / desynced / version-skewed frame carrying underline in {6..255}
        // MUST fail closed HERE, exactly like the dirty / cursor_visual_style /
        // ColorTag / codepoint validators do, instead of being projected into UB.
        // The producer only ever emits 0..5 (via fromStyle's @intFromEnum), so this
        // never trips on a legitimate host-produced frame.
        const underline_byte = try r.readByte();
        _ = std.meta.intToEnum(sgr.Attribute.Underline, underline_byte) catch
            return error.InvalidUnderline;
        return .{
            .fg_color = fg_color,
            .bg_color = bg_color,
            .underline_color = underline_color,
            .bold = bold,
            .italic = italic,
            .faint = faint,
            .blink = blink,
            .inverse = inverse,
            .invisible = invisible,
            .strikethrough = strikethrough,
            .overline = overline,
            .underline = underline_byte,
        };
    }
};

/// A single cell in the snapshot: the raw page.Cell (a packed u64, pointer-
/// free) plus any grapheme codepoints copied inline plus the style projection.
pub const Cell = struct {
    raw: page.Cell,
    grapheme: []const u21 = &.{},
    style: StylePod = .{},

    pub fn eql(a: Cell, b: Cell) bool {
        const ai: u64 = @bitCast(a.raw);
        const bi: u64 = @bitCast(b.raw);
        if (ai != bi) return false;
        if (a.grapheme.len != b.grapheme.len) return false;
        if (!std.mem.eql(u21, a.grapheme, b.grapheme)) return false;
        return a.style.eql(b.style);
    }
};

/// A highlight within a row (mirrors render.RenderState.Highlight).
pub const Highlight = struct {
    tag: u8,
    range: [2]u16,
};

/// Number of valid highlight tags — MUST stay in lock-step with the cardinality
/// of `HighlightTag` in `src/renderer/generic.zig` (currently `search_match`=0,
/// `search_match_selected`=1). `deserialize` rejects any wire tag >= this so the
/// render-time `@enumFromInt(hl.tag)` can never hit an illegal value (UB in the
/// ReleaseFast lib). If HighlightTag gains a variant, bump this.
const highlight_tag_count: u8 = 2;

/// A single row in the snapshot.
pub const Row = struct {
    cells: []Cell,
    dirty: bool = false,
    selection: ?[2]u16 = null,
    highlights: []Highlight = &.{},
    /// The raw page.Row (a packed struct(u64), pointer-free — its only
    /// sub-field, `cells: Offset(Cell)`, is a relative page offset, not a
    /// pointer). The Slice-3 renderer reads its flag bits (wrap,
    /// wrap_continuation, grapheme, styled, hyperlink, semantic_prompt,
    /// kitty_virtual_placeholder) via `row_data.items(.raw)`
    /// (generic.zig:2366), so the Snapshot must carry it. Round-tripped as a
    /// u64 bitcast, exactly like the per-cell `Cell.raw`. Default is the
    /// all-zero page.Row (its first field `cells: Offset(Cell)` has no struct
    /// default, so we bitcast 0 rather than `.{}`).
    raw: page.Row = @bitCast(@as(u64, 0)),

    pub fn eql(a: Row, b: Row) bool {
        {
            const ai: u64 = @bitCast(a.raw);
            const bi: u64 = @bitCast(b.raw);
            if (ai != bi) return false;
        }
        if (a.dirty != b.dirty) return false;
        if (!std.meta.eql(a.selection, b.selection)) return false;
        if (a.highlights.len != b.highlights.len) return false;
        for (a.highlights, b.highlights) |ha, hb| {
            if (ha.tag != hb.tag) return false;
            if (ha.range[0] != hb.range[0] or ha.range[1] != hb.range[1]) return false;
        }
        if (a.cells.len != b.cells.len) return false;
        for (a.cells, b.cells) |ca, cb| {
            if (!ca.eql(cb)) return false;
        }
        return true;
    }
};

/// A self-contained, pointer-free (PageList.Pin-stripped) projection of a
/// terminal's viewport RenderState. See the file header for the §2.1 field
/// coverage and documented followups.
pub const Snapshot = struct {
    rows: u16,
    cols: u16,

    /// Frame dirty state (false|partial|full). On a `.partial` frame only the
    /// dirty rows are serialized (each prefixed by its row index); on `.full`
    /// all rows; on `.false` none. Deserialize always reconstructs a full
    /// `rows`-length row_data (non-listed rows default blank — fine for Phase
    /// 2a since reattach always sends a `.full` frame, plan §5 step 2).
    dirty: RenderState.Dirty = .full,

    /// Colors (reverse-video already applied by RenderState.update).
    background: color.RGB,
    foreground: color.RGB,
    cursor_color: ?color.RGB = null,
    palette: color.Palette,

    /// Cursor projection (pointer-free fields only).
    cursor_x: u16,
    cursor_y: u32,
    cursor_visible: bool,
    cursor_blinking: bool,
    cursor_password_input: bool = false,
    cursor_visual_style: cursorpkg.Style = .block,
    cursor_viewport: ?CursorViewport = null,
    cursor_style: StylePod = .{},
    /// The cursor cell as a raw page.Cell bitcast.
    cursor_cell: page.Cell,

    /// Placeholder header bits — see file header followups. These round-trip
    /// faithfully but are NOT yet wired to real host-tick computation.
    scrolled_to_bottom: bool = true,
    synchronized_output: bool = false,
    scrollbar_total: u64 = 0,
    scrollbar_offset: u64 = 0,
    scrollbar_len: u64 = 0,
    cursor_blink_visible: bool = true,

    /// The viewport rows, top to bottom. Length == rows.
    row_data: []Row,

    /// Backing storage for all grapheme codepoints, so we can free in one shot.
    /// May be empty.
    grapheme_pool: []u21,

    /// Backing storage for all highlights, freed in one shot like grapheme_pool.
    /// May be empty.
    highlight_pool: []Highlight,

    pub const CursorViewport = struct {
        x: u16,
        y: u16,
        wide_tail: bool,
    };

    /// Capture a Snapshot from a live renderer.State. The caller MUST hold
    /// `state.mutex` for the duration of this call: it runs RenderState.update
    /// (which reads the terminal) and copies all needed data out.
    ///
    /// PHASE-2a SCOPE NOTE (findings P1 / F2): because this builds a FRESH
    /// `.empty` RenderState on every call, `update` always trips its
    /// dimension-mismatch redraw branch (rows/cols go 0 -> real on the first
    /// update) and forces `dirty == .full`. So every Snapshot the live host
    /// captures — both the per-tick push (Session.renderTick) and the (re)attach
    /// push (Server.pushFullFrames) — is FULL. The `.partial` serialize/
    /// deserialize codec exists and is exercised by an explicit round-trip test
    /// (see test.zig "partial"), but the running host does NOT yet emit `.partial`
    /// frames: real per-tick diffing (persisting a RenderState across ticks so
    /// `update` can produce `.partial`) is deferred to Phase 2b/3. Until then,
    /// note the `.partial` deserialize contract: non-listed rows are reconstructed
    /// BLANK, so a Phase-2b GUI mirror MUST treat a partial frame as a MERGE of
    /// the listed dirty rows over its prior viewport, never a wholesale row_data
    /// replacement (which would erase non-dirty rows).
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

        const src = rs.row_data.slice();
        const src_cells = src.items(.cells);
        const src_dirty = src.items(.dirty);
        const src_sel = src.items(.selection);
        const src_hl = src.items(.highlights);
        const src_raw = src.items(.raw);

        // Count grapheme codepoints and highlights so we can allocate pools once.
        var grapheme_total: usize = 0;
        var highlight_total: usize = 0;
        for (0..rs.row_data.len) |y| {
            const cells = src_cells[y];
            const cell_slice = cells.slice();
            for (cell_slice.items(.grapheme), cell_slice.items(.raw)) |g, raw| {
                if (raw.content_tag == .codepoint_grapheme) grapheme_total += g.len;
            }
            highlight_total += src_hl[y].items.len;
        }

        const grapheme_pool = try alloc.alloc(u21, grapheme_total);
        errdefer alloc.free(grapheme_pool);

        const highlight_pool = try alloc.alloc(Highlight, highlight_total);
        errdefer alloc.free(highlight_pool);

        const row_data = try alloc.alloc(Row, rows);
        errdefer alloc.free(row_data);

        var g_off: usize = 0;
        var h_off: usize = 0;
        var allocated_rows: usize = 0;
        errdefer for (0..allocated_rows) |y| alloc.free(row_data[y].cells);

        for (0..rows) |y| {
            const out_cells = try alloc.alloc(Cell, cols);
            row_data[y] = .{ .cells = out_cells };
            allocated_rows += 1;

            // Rows beyond row_data.len shouldn't happen (update guarantees
            // row_data.len == rows), but be defensive.
            if (y >= rs.row_data.len) {
                for (out_cells) |*c| c.* = .{ .raw = .{} };
                continue;
            }

            const cells = src_cells[y];
            const cell_slice = cells.slice();
            const raws = cell_slice.items(.raw);
            const graphemes = cell_slice.items(.grapheme);
            const styles = cell_slice.items(.style);

            for (0..cols) |x| {
                if (x >= cells.len) {
                    out_cells[x] = .{ .raw = .{} };
                    continue;
                }
                const raw = raws[x];

                // Style projection. THREE cases, in priority order:
                //
                //   1. bg_color_rgb / bg_color_palette cells: the bg color lives
                //      in `raw.content` (a blank cell with a background, produced
                //      by Screen.blankCell -> Style.bgCell). DERIVE the StylePod
                //      directly from `raw.content`, NEVER from `styles[x]`.
                //
                //      WHY (root cause of the rare load-dependent grid_frame decode
                //      failure / error.InvalidColorTag): the renderer's
                //      RenderState.update only populates `cells_style[x]` inside its
                //      `if (row.managedMemory()) { ... }` block (render.zig:506),
                //      and `managedMemory() == styled or hyperlink or grapheme`
                //      (page.zig). A bg_color blank cell has style_id==0 and does
                //      NOT set row.styled (Screen.clearCells even CLEARS it on a
                //      full-width clear), so a row of only bg_color cells is
                //      NON-managed: `update` skips the loop and `cells_style[x]` for
                //      that cell is left UNDEFINED (MultiArrayList.resize does not
                //      zero new fields). The renderer never reads it (it derives the
                //      bg from raw.content at draw time, exactly as below), but the
                //      mirror used to read it via fromStyle(styles[x]) -> garbage
                //      color union tag -> serialize emits a garbage ColorTag byte ->
                //      decode trips error.InvalidColorTag. Idle the reused arena
                //      memory was usually zero (benign), so it only bit under load.
                //      Deriving from raw.content makes the producer emit a valid,
                //      correct StylePod for these cells regardless of arena state,
                //      and matches what the renderer itself populates for a bg_color
                //      cell on a managed row (render.zig:536-549).
                //
                //   2. style_id > 0 cells: always live on a `styled` (== managed)
                //      row, so `styles[x]` IS populated by update. Read it.
                //
                //   3. everything else (default cells): no style; all-default POD.
                const style_pod: StylePod = blk: {
                    // Guard the `else => {}` fallthrough below: it is correct ONLY
                    // while the sole COLOR-carrying content tags are the two handled
                    // here. If page.ContentTag ever gains another variant whose color
                    // lives in `raw.content` (like bg_color_*), it would silently
                    // route through `else` to the `styles[x]` path and could
                    // reintroduce the exact undefined-style-slot read this fix
                    // eliminated. This comptime assert fails the build if the tag set
                    // changes, forcing a deliberate re-audit against render.zig's
                    // draw-time color mapping (render.zig:536-549).
                    comptime std.debug.assert(@typeInfo(page.Cell.ContentTag).@"enum".fields.len == 4);
                    switch (raw.content_tag) {
                        .bg_color_rgb => break :blk .{ .bg_color = .{
                            .tag = .rgb,
                            .rgb = .{
                                .r = raw.content.color_rgb.r,
                                .g = raw.content.color_rgb.g,
                                .b = raw.content.color_rgb.b,
                            },
                        } },
                        .bg_color_palette => break :blk .{ .bg_color = .{
                            .tag = .palette,
                            .palette = raw.content.color_palette,
                        } },
                        else => {},
                    }
                    if (raw.style_id > 0) break :blk StylePod.fromStyle(styles[x]);
                    break :blk .{};
                };

                if (raw.content_tag == .codepoint_grapheme) {
                    const g = graphemes[x];
                    const dst = grapheme_pool[g_off .. g_off + g.len];
                    @memcpy(dst, g);
                    g_off += g.len;
                    out_cells[x] = .{ .raw = raw, .grapheme = dst, .style = style_pod };
                } else {
                    out_cells[x] = .{ .raw = raw, .style = style_pod };
                }
            }

            // Per-row dirty + selection + raw page.Row (u64, pointer-free).
            row_data[y].dirty = src_dirty[y];
            row_data[y].raw = src_raw[y];
            if (src_sel[y]) |s| row_data[y].selection = .{ s[0], s[1] };

            // Per-row highlights into the shared pool.
            const hls = src_hl[y].items;
            const hl_dst = highlight_pool[h_off .. h_off + hls.len];
            for (hls, hl_dst) |src_h, *dst_h| {
                dst_h.* = .{ .tag = src_h.tag, .range = .{ src_h.range[0], src_h.range[1] } };
            }
            row_data[y].highlights = hl_dst;
            h_off += hls.len;
        }

        const cursor_viewport: ?CursorViewport = if (rs.cursor.viewport) |v| .{
            .x = v.x,
            .y = v.y,
            .wide_tail = v.wide_tail,
        } else null;

        return .{
            .rows = rows,
            .cols = cols,
            .dirty = rs.dirty,
            .background = rs.colors.background,
            .foreground = rs.colors.foreground,
            .cursor_color = rs.colors.cursor,
            .palette = rs.colors.palette,
            .cursor_x = rs.cursor.active.x,
            .cursor_y = rs.cursor.active.y,
            .cursor_visible = rs.cursor.visible,
            .cursor_blinking = rs.cursor.blinking,
            .cursor_password_input = rs.cursor.password_input,
            .cursor_visual_style = rs.cursor.visual_style,
            .cursor_viewport = cursor_viewport,
            .cursor_style = StylePod.fromStyle(rs.cursor.style),
            .cursor_cell = rs.cursor.cell,
            // Placeholder header bits (see file header followups).
            .scrolled_to_bottom = true,
            .synchronized_output = false,
            .scrollbar_total = 0,
            .scrollbar_offset = 0,
            .scrollbar_len = 0,
            .cursor_blink_visible = true,
            .row_data = row_data,
            .grapheme_pool = grapheme_pool,
            .highlight_pool = highlight_pool,
        };
    }

    pub fn deinit(self: *Snapshot, alloc: Allocator) void {
        for (self.row_data) |row| alloc.free(row.cells);
        alloc.free(self.row_data);
        alloc.free(self.grapheme_pool);
        alloc.free(self.highlight_pool);
        self.* = undefined;
    }

    /// Content equality (PageList.Pin already stripped by construction).
    pub fn eql(a: Snapshot, b: Snapshot) bool {
        if (a.rows != b.rows or a.cols != b.cols) return false;
        if (a.dirty != b.dirty) return false;
        if (!std.meta.eql(a.background, b.background)) return false;
        if (!std.meta.eql(a.foreground, b.foreground)) return false;
        if (!std.meta.eql(a.cursor_color, b.cursor_color)) return false;
        if (!std.mem.eql(color.RGB, &a.palette, &b.palette)) return false;
        if (a.cursor_x != b.cursor_x or a.cursor_y != b.cursor_y) return false;
        if (a.cursor_visible != b.cursor_visible) return false;
        if (a.cursor_blinking != b.cursor_blinking) return false;
        if (a.cursor_password_input != b.cursor_password_input) return false;
        if (a.cursor_visual_style != b.cursor_visual_style) return false;
        if (!std.meta.eql(a.cursor_viewport, b.cursor_viewport)) return false;
        if (!a.cursor_style.eql(b.cursor_style)) return false;
        {
            const ai: u64 = @bitCast(a.cursor_cell);
            const bi: u64 = @bitCast(b.cursor_cell);
            if (ai != bi) return false;
        }
        if (a.scrolled_to_bottom != b.scrolled_to_bottom) return false;
        if (a.synchronized_output != b.synchronized_output) return false;
        if (a.scrollbar_total != b.scrollbar_total) return false;
        if (a.scrollbar_offset != b.scrollbar_offset) return false;
        if (a.scrollbar_len != b.scrollbar_len) return false;
        if (a.cursor_blink_visible != b.cursor_blink_visible) return false;
        if (a.row_data.len != b.row_data.len) return false;
        for (a.row_data, b.row_data) |ra, rb| {
            if (!ra.eql(rb)) return false;
        }
        return true;
    }

    /// Cursor-only equality over the RENDER-AFFECTING cursor fields. Used by
    /// Session.renderTick (Slice 8) to widen the per-tick push gate so a
    /// cursor-only move (arrow keys change NO rows => printDiff-changed==0)
    /// still pushes a frame and the GUI mirror's cursor follows.
    ///
    /// DELIBERATELY EXCLUDES `cursor_blink_visible`: it is a hard-coded
    /// placeholder (always true, Slice 2/2a) and the real blink on/off is
    /// GUI-LOCAL (renderer blink timer), so it is not in the snapshot and must
    /// not gate pushes — including it would change nothing today but could
    /// reintroduce idle spam if it were ever wired to a host-side timer. Every
    /// field compared here changes only on a genuine cursor move/visibility/
    /// style change, so an idle session with a steady cursor compares equal and
    /// pushes nothing.
    pub fn cursorEql(a: Snapshot, b: Snapshot) bool {
        if (a.cursor_x != b.cursor_x or a.cursor_y != b.cursor_y) return false;
        if (a.cursor_visible != b.cursor_visible) return false;
        if (a.cursor_blinking != b.cursor_blinking) return false;
        if (a.cursor_password_input != b.cursor_password_input) return false;
        if (a.cursor_visual_style != b.cursor_visual_style) return false;
        if (!std.meta.eql(a.cursor_viewport, b.cursor_viewport)) return false;
        {
            const ai: u64 = @bitCast(a.cursor_cell);
            const bi: u64 = @bitCast(b.cursor_cell);
            if (ai != bi) return false;
        }
        return true;
    }

    /// A precise mismatch reporter for `eqlRenderState`. When a comparison
    /// fails, the first mismatch is recorded here (the test side dumps it).
    /// This keeps `eqlRenderState` a pure read-only comparison (no stderr
    /// spew, no host-state mutation) while still giving callers a precise
    /// coordinate + field for failure output.
    pub const Mismatch = struct {
        field: []const u8 = "",
        /// Cell coordinate, when the mismatch is per-cell (else null).
        y: ?usize = null,
        x: ?usize = null,
        /// Optional u64 expected/actual (e.g. raw page.Cell bitcast).
        expected: u64 = 0,
        actual: u64 = 0,
    };

    /// Compare this Snapshot (the deserialized HOST mirror) against the core
    /// `render.RenderState` the .exec renderer literally consumes, field by
    /// field, for everything the renderer draws. This is the primary fidelity
    /// assertion of the differential test: it validates the host PROJECTION
    /// against the renderer's input (not merely serialize/deserialize
    /// symmetry).
    ///
    /// This is READ-ONLY over both the Snapshot and the RenderState; it
    /// mutates no host state and touches no host invariant (no .exec, inspector
    /// stays null, mailbox untouched). It is a pure comparison fn placed beside
    /// `eql` so review is trivial.
    ///
    /// Style reads on the RenderState are GATED on the exact populated-cell
    /// condition `fromRenderState` uses (style_id > 0 or bg_color_rgb/palette):
    /// `rs` cell `.style` is undefined for default cells (render.zig:223), so
    /// reading it there would be UB. The placeholder header bits
    /// (scrolled_to_bottom, synchronized_output, scrollbar triple,
    /// cursor_blink_visible) are NOT read from `rs` — they are not derivable
    /// from a viewport-only RenderState and are pinned to their constants
    /// separately by the test.
    pub fn eqlRenderState(
        self: Snapshot,
        rs: *const RenderState,
        out: ?*Mismatch,
    ) bool {
        const fail = struct {
            fn f(o: ?*Mismatch, m: Mismatch) bool {
                if (o) |p| p.* = m;
                return false;
            }
        }.f;

        // Dims.
        if (self.rows != rs.rows) return fail(out, .{ .field = "rows", .expected = rs.rows, .actual = self.rows });
        if (self.cols != rs.cols) return fail(out, .{ .field = "cols", .expected = rs.cols, .actual = self.cols });

        // Colors / palette (reverse-video already applied by update).
        if (!self.background.eql(rs.colors.background)) return fail(out, .{ .field = "background" });
        if (!self.foreground.eql(rs.colors.foreground)) return fail(out, .{ .field = "foreground" });
        if (!std.meta.eql(self.cursor_color, rs.colors.cursor)) return fail(out, .{ .field = "cursor_color" });
        if (!std.mem.eql(color.RGB, &self.palette, &rs.colors.palette)) return fail(out, .{ .field = "palette" });

        // Cursor.
        if (self.cursor_x != rs.cursor.active.x) return fail(out, .{ .field = "cursor_x", .expected = rs.cursor.active.x, .actual = self.cursor_x });
        if (self.cursor_y != rs.cursor.active.y) return fail(out, .{ .field = "cursor_y", .expected = rs.cursor.active.y, .actual = self.cursor_y });
        if (self.cursor_visible != rs.cursor.visible) return fail(out, .{ .field = "cursor_visible" });
        if (self.cursor_blinking != rs.cursor.blinking) return fail(out, .{ .field = "cursor_blinking" });
        if (self.cursor_password_input != rs.cursor.password_input) return fail(out, .{ .field = "cursor_password_input" });
        if (self.cursor_visual_style != rs.cursor.visual_style) return fail(out, .{ .field = "cursor_visual_style" });
        {
            const rv: ?CursorViewport = if (rs.cursor.viewport) |v| .{ .x = v.x, .y = v.y, .wide_tail = v.wide_tail } else null;
            if (!std.meta.eql(self.cursor_viewport, rv)) return fail(out, .{ .field = "cursor_viewport" });
        }
        // cursor.style is always valid post-update (render.zig:312). Compare
        // the mirror's StylePod DIRECTLY against the raw terminal.style.Style
        // (not against fromStyle(...)), so a dropped/mis-mapped Style field in
        // the projection fails the diff instead of cancelling on both sides
        // (finding DR-1).
        if (!self.cursor_style.eqlStyle(rs.cursor.style)) return fail(out, .{ .field = "cursor_style" });
        {
            const e: u64 = @bitCast(rs.cursor.cell);
            const a: u64 = @bitCast(self.cursor_cell);
            if (e != a) return fail(out, .{ .field = "cursor_cell", .expected = e, .actual = a });
        }

        // dirty framing.
        if (self.dirty != rs.dirty) return fail(out, .{ .field = "dirty" });

        // Per-row + per-cell.
        const src = rs.row_data.slice();
        const src_cells = src.items(.cells);
        const src_dirty = src.items(.dirty);
        const src_sel = src.items(.selection);
        const src_hl = src.items(.highlights);
        const src_raw = src.items(.raw);

        if (self.row_data.len != rs.rows) return fail(out, .{ .field = "row_data.len" });

        for (0..self.rows) |y| {
            const mrow = self.row_data[y];

            // Per-row raw page.Row (u64 bitcast). The renderer reads the row's
            // flag bits via row_data.items(.raw); compare them cross-path here.
            {
                const e: u64 = @bitCast(src_raw[y]);
                const a: u64 = @bitCast(mrow.raw);
                if (e != a) return fail(out, .{ .field = "row.raw", .y = y, .expected = e, .actual = a });
            }

            // Per-row dirty.
            if (mrow.dirty != src_dirty[y]) return fail(out, .{ .field = "row.dirty", .y = y });

            // Per-row selection.
            const rsel: ?[2]u16 = if (src_sel[y]) |s| .{ s[0], s[1] } else null;
            if (!std.meta.eql(mrow.selection, rsel)) return fail(out, .{ .field = "row.selection", .y = y });

            // Per-row highlights.
            const rhls = src_hl[y].items;
            if (mrow.highlights.len != rhls.len) return fail(out, .{ .field = "row.highlights.len", .y = y });
            for (mrow.highlights, rhls) |mh, rh| {
                if (mh.tag != rh.tag or mh.range[0] != rh.range[0] or mh.range[1] != rh.range[1])
                    return fail(out, .{ .field = "row.highlight", .y = y });
            }

            // Per-cell.
            const cells = src_cells[y];
            const cell_slice = cells.slice();
            const raws = cell_slice.items(.raw);
            const graphemes = cell_slice.items(.grapheme);
            const styles = cell_slice.items(.style);

            if (mrow.cells.len != self.cols) return fail(out, .{ .field = "row.cells.len", .y = y });

            for (0..self.cols) |x| {
                const mcell = mrow.cells[x];

                // The RenderState row may be narrower than cols in pathological
                // cases; fromRenderState treats those as blank. Mirror that.
                const r_raw: page.Cell = if (x < cells.len) raws[x] else .{};

                // raw packed cell (content_tag, codepoint, wide/spacer,
                // style_id, protected, hyperlink).
                {
                    const e: u64 = @bitCast(r_raw);
                    const a: u64 = @bitCast(mcell.raw);
                    if (e != a) return fail(out, .{ .field = "cell.raw", .y = y, .x = x, .expected = e, .actual = a });
                }

                // grapheme run.
                if (r_raw.content_tag == .codepoint_grapheme) {
                    const g: []const u21 = if (x < cells.len) graphemes[x] else &.{};
                    if (!std.mem.eql(u21, mcell.grapheme, g)) return fail(out, .{ .field = "cell.grapheme", .y = y, .x = x });
                } else {
                    if (mcell.grapheme.len != 0) return fail(out, .{ .field = "cell.grapheme(nonempty)", .y = y, .x = x });
                }

                // style — validated to match what `fromRenderState` PRODUCES,
                // case-for-case (the same three-way switch), so the cross-path
                // legs stay honest:
                //
                //   - bg_color cells: the projection derives bg_color from
                //     `raw.content` (NOT from styles[x], which is UNDEFINED on a
                //     non-managed bg_color row — see fromRenderState's comment /
                //     the root-cause note). Validate the mirror against that same
                //     content-derived StylePod, so the difftest exercises the real
                //     producer path and never reads the undefined styles[x].
                //   - style_id > 0 cells (always on a managed row, so styles[x] IS
                //     populated): compare the mirror's StylePod DIRECTLY against the
                //     raw terminal.style.Style (NOT fromStyle(styles[x])) — the
                //     cross-path leg that breaks the self-reference so a dropped /
                //     mis-mapped field fails the diff (finding DR-1).
                //   - default cells: the renderer reads no style; require all-default.
                switch (r_raw.content_tag) {
                    .bg_color_rgb => {
                        const want: StylePod = .{ .bg_color = .{
                            .tag = .rgb,
                            .rgb = .{
                                .r = r_raw.content.color_rgb.r,
                                .g = r_raw.content.color_rgb.g,
                                .b = r_raw.content.color_rgb.b,
                            },
                        } };
                        if (!mcell.style.eql(want)) return fail(out, .{ .field = "cell.style(bg_rgb)", .y = y, .x = x });
                    },
                    .bg_color_palette => {
                        const want: StylePod = .{ .bg_color = .{
                            .tag = .palette,
                            .palette = r_raw.content.color_palette,
                        } };
                        if (!mcell.style.eql(want)) return fail(out, .{ .field = "cell.style(bg_palette)", .y = y, .x = x });
                    },
                    else => {
                        if (x < cells.len and r_raw.style_id > 0) {
                            if (!mcell.style.eqlStyle(styles[x])) return fail(out, .{ .field = "cell.style", .y = y, .x = x });
                        } else {
                            if (!mcell.style.eql(.{})) return fail(out, .{ .field = "cell.style(default)", .y = y, .x = x });
                        }
                    },
                }
            }
        }

        return true;
    }

    /// Serialize this snapshot into a flat, pointer-free byte buffer. The
    /// caller owns the returned slice. This is the GridFrame payload (after the
    /// session_id) in the Phase 2 wire format; PageList.Pin is already stripped.
    pub fn serialize(self: Snapshot, alloc: Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(alloc);
        const w = buf.writer(alloc);

        // Header.
        try writeInt(w, u16, self.rows);
        try writeInt(w, u16, self.cols);
        try w.writeByte(@intFromEnum(self.dirty));
        try writeRGB(w, self.background);
        try writeRGB(w, self.foreground);
        // cursor color (present-flag + RGB).
        if (self.cursor_color) |c| {
            try w.writeByte(1);
            try writeRGB(w, c);
        } else {
            try w.writeByte(0);
        }
        // palette: 256 * RGB.
        for (self.palette) |c| try writeRGB(w, c);

        // Cursor projection.
        try writeInt(w, u16, self.cursor_x);
        try writeInt(w, u32, self.cursor_y);
        try w.writeByte(@intFromBool(self.cursor_visible));
        try w.writeByte(@intFromBool(self.cursor_blinking));
        try w.writeByte(@intFromBool(self.cursor_password_input));
        try w.writeByte(@intFromEnum(self.cursor_visual_style));
        if (self.cursor_viewport) |v| {
            try w.writeByte(1);
            try writeInt(w, u16, v.x);
            try writeInt(w, u16, v.y);
            try w.writeByte(@intFromBool(v.wide_tail));
        } else {
            try w.writeByte(0);
        }
        try self.cursor_style.write(w);
        try writeInt(w, u64, @bitCast(self.cursor_cell));

        // Placeholder header bits.
        try w.writeByte(@intFromBool(self.scrolled_to_bottom));
        try w.writeByte(@intFromBool(self.synchronized_output));
        try writeInt(w, u64, self.scrollbar_total);
        try writeInt(w, u64, self.scrollbar_offset);
        try writeInt(w, u64, self.scrollbar_len);
        try w.writeByte(@intFromBool(self.cursor_blink_visible));

        // Row framing. We serialize the row count actually written: for .full
        // all rows; for .partial only dirty rows (prefixed by row index); for
        // .false zero rows. Each emitted row is prefixed by its u16 index in
        // all cases so the deserializer can place it.
        var emit_count: u16 = 0;
        switch (self.dirty) {
            .false => emit_count = 0,
            .partial => {
                for (self.row_data) |row| {
                    if (row.dirty) emit_count += 1;
                }
            },
            .full => emit_count = @intCast(self.row_data.len),
        }
        try writeInt(w, u16, emit_count);

        for (self.row_data, 0..) |row, y| {
            const emit = switch (self.dirty) {
                .false => false,
                .partial => row.dirty,
                .full => true,
            };
            if (!emit) continue;
            // PROTO-4: the row wire form is header-implied, not self-describing
            // at the row level — serializeRow writes exactly row.cells.len cells
            // with no per-row count prefix, and deserialize reads exactly
            // `cols` cells per emitted row from the header. That round-trips
            // only when every emitted row is exactly `cols` wide. The sole
            // constructor (fromRenderState) guarantees this, but a future
            // partial-frame / resize-in-flight builder that produced a row with
            // cells.len != cols would silently desync the byte stream (over- or
            // under-running every subsequent field) with no boundary error.
            // Assert here so that latent corruption fails loudly instead.
            std.debug.assert(row.cells.len == self.cols);
            try writeInt(w, u16, @intCast(y));
            try serializeRow(w, row);
        }

        return buf.toOwnedSlice(alloc);
    }

    fn serializeRow(w: anytype, row: Row) !void {
        try w.writeByte(@intFromBool(row.dirty));
        // selection.
        if (row.selection) |s| {
            try w.writeByte(1);
            try writeInt(w, u16, s[0]);
            try writeInt(w, u16, s[1]);
        } else {
            try w.writeByte(0);
        }
        // highlights.
        try writeInt(w, u16, @intCast(row.highlights.len));
        for (row.highlights) |h| {
            try w.writeByte(h.tag);
            try writeInt(w, u16, h.range[0]);
            try writeInt(w, u16, h.range[1]);
        }
        // raw page.Row (u64 bitcast, pointer-free). Written here, after the
        // highlights block and BEFORE the per-cell loop; deserialize reads it
        // at the identical position so the PROTO-4 header-implied row stream
        // stays in sync.
        //
        // This is an additive GridFrame wire change. protocol.PROTOCOL_VERSION_MINOR
        // is documentary/defensive only (a default field value in Hello/HelloAck,
        // never validated against the GridFrame body on either side), so it is not
        // touched here: both peers are built from the same tree, and the additive
        // field round-trips regardless of the advertised minor. Decode/rehydrate
        // and the fidelity tests are unaffected.
        try writeInt(w, u64, @bitCast(row.raw));
        // cells.
        for (row.cells) |cell| {
            try writeInt(w, u64, @bitCast(cell.raw));
            try cell.style.write(w);
            try writeInt(w, u16, @intCast(cell.grapheme.len));
            for (cell.grapheme) |cp| try writeInt(w, u32, cp);
        }
    }

    /// Deserialize a snapshot from a flat byte buffer produced by serialize.
    /// The caller owns the returned Snapshot (call deinit). Non-listed rows
    /// (when the frame was .partial or .false) are reconstructed blank.
    pub fn deserialize(alloc: Allocator, bytes: []const u8) !Snapshot {
        var fbs = std.io.fixedBufferStream(bytes);
        const r = fbs.reader();

        const rows = try readInt(r, u16);
        const cols = try readInt(r, u16);
        const dirty = std.meta.intToEnum(RenderState.Dirty, try r.readByte()) catch
            return error.InvalidDirty;
        const background = try readRGB(r);
        const foreground = try readRGB(r);
        const cursor_color: ?color.RGB = if ((try r.readByte()) != 0)
            try readRGB(r)
        else
            null;

        var palette: color.Palette = undefined;
        for (&palette) |*c| c.* = try readRGB(r);

        const cursor_x = try readInt(r, u16);
        const cursor_y = try readInt(r, u32);
        const cursor_visible = (try r.readByte()) != 0;
        const cursor_blinking = (try r.readByte()) != 0;
        const cursor_password_input = (try r.readByte()) != 0;
        const cursor_visual_style = std.meta.intToEnum(cursorpkg.Style, try r.readByte()) catch
            return error.InvalidCursorStyle;
        const cursor_viewport: ?CursorViewport = if ((try r.readByte()) != 0) .{
            .x = try readInt(r, u16),
            .y = try readInt(r, u16),
            .wide_tail = (try r.readByte()) != 0,
        } else null;
        const cursor_style = try StylePod.read(r);
        const cursor_cell: page.Cell = @bitCast(try readInt(r, u64));

        const scrolled_to_bottom = (try r.readByte()) != 0;
        const synchronized_output = (try r.readByte()) != 0;
        const scrollbar_total = try readInt(r, u64);
        const scrollbar_offset = try readInt(r, u64);
        const scrollbar_len = try readInt(r, u64);
        const cursor_blink_visible = (try r.readByte()) != 0;

        // Pools accumulated into temporary lists then copied once.
        var g_list: std.ArrayList(u21) = .empty;
        errdefer g_list.deinit(alloc);
        var h_list: std.ArrayList(Highlight) = .empty;
        errdefer h_list.deinit(alloc);

        // Bound the blank-grid pre-allocation against the wire-frame size cap
        // (findings SR-5 / ZM2 / SR3-1 / ZM-R3-1). deserialize allocates a full
        // rows*cols blank Cell grid from the unvalidated u16/u16 header BEFORE
        // reading any row payload; a corrupt/desynced frame could claim
        // rows=cols=65535 (~4.3e9 cells, hundreds of GB) inside a frame whose
        // total length is still under the 64 MiB wire cap.
        //
        // The bound must be on the IN-MEMORY pre-allocation, not on emitted-cell
        // wire bytes: a .partial or .false frame legitimately describes a large
        // rows*cols grid while emitting few or zero rows, so its payload can be
        // tiny even though we still pre-allocate every blank Cell. An
        // emitted-wire-bytes bound (the old MIN_CELL_BYTES=8 heuristic) therefore
        // under-counts the .partial/.false case and left the pre-alloc bounded to
        // ~7x the wire cap (8.4M cells * ~48 B/Cell ~= 400 MB) instead of to the
        // cap itself. Bound the actual bytes we are about to allocate
        // (rows*cols*@sizeOf(Cell)) to the wire-frame cap so a malformed header
        // can never amplify beyond a single frame's worth of memory, regardless
        // of dirty state. This self-corrects if Cell grows. (The host doesn't
        // decode GridFrame today — dispatch ignores it — but this is the frozen
        // protocol surface and the Phase-2b GUI-side decode path; matches the
        // readBytes pre-alloc guard in protocol.zig.) 64 MiB is hardcoded here
        // (rather than importing protocol.MAX_FRAME_LEN) to avoid a
        // protocol<->RenderState import cycle; keep the two in sync.
        const MAX_FRAME_PAYLOAD: u64 = 64 * 1024 * 1024;
        const cell_count: u64 = @as(u64, rows) * @as(u64, cols);
        if (cell_count * @as(u64, @sizeOf(Cell)) > MAX_FRAME_PAYLOAD) return error.GridTooLarge;

        const row_data = try alloc.alloc(Row, rows);
        errdefer alloc.free(row_data);

        // Initialize every row blank (so non-listed rows are valid).
        var allocated_rows: usize = 0;
        errdefer for (0..allocated_rows) |y| alloc.free(row_data[y].cells);
        for (0..rows) |y| {
            const cells = try alloc.alloc(Cell, cols);
            for (cells) |*c| c.* = .{ .raw = .{} };
            row_data[y] = .{ .cells = cells };
            allocated_rows += 1;
        }

        // Patch tracking for grapheme + highlight slices.
        const GSpan = struct { row: usize, col: usize, off: usize, len: usize };
        const HSpan = struct { row: usize, off: usize, len: usize };
        var gspans: std.ArrayList(GSpan) = .empty;
        defer gspans.deinit(alloc);
        var hspans: std.ArrayList(HSpan) = .empty;
        defer hspans.deinit(alloc);

        const emit_count = try readInt(r, u16);
        var e: usize = 0;
        while (e < emit_count) : (e += 1) {
            const y = try readInt(r, u16);
            if (y >= rows) return error.InvalidRowIndex;

            const row_dirty = (try r.readByte()) != 0;
            const selection: ?[2]u16 = if ((try r.readByte()) != 0) .{
                try readInt(r, u16),
                try readInt(r, u16),
            } else null;

            const hcount = try readInt(r, u16);
            const h_start = h_list.items.len;
            var h: usize = 0;
            while (h < hcount) : (h += 1) {
                const tag = try r.readByte();
                const r0 = try readInt(r, u16);
                const r1 = try readInt(r, u16);
                // The highlight tag is an untrusted wire byte. The renderer maps
                // it via `@enumFromInt` onto a 2-value enum (HighlightTag in
                // renderer/generic.zig); a value >= highlight_tag_count would be
                // illegal behavior there — a checked panic in safe builds and
                // UNDEFINED BEHAVIOR in the ReleaseFast production lib, on the
                // render hot path. DROP an out-of-range highlight here (still
                // reading r0/r1 to stay byte-aligned) so the stored mirror only
                // ever holds valid tags; a corrupt/desynced/version-skewed frame
                // loses just that one highlight, not the whole grid. (The only
                // PRODUCER, the host search flatten, always emits valid tags, so
                // this never fires for well-formed frames / the difftest.)
                if (tag >= highlight_tag_count) continue;
                try h_list.append(alloc, .{ .tag = tag, .range = .{ r0, r1 } });
            }
            // Use the COUNT ACTUALLY APPENDED (not hcount) for the span len, since
            // invalid tags above were skipped — otherwise the span would over-read
            // into the next row's highlights in the shared pool.
            const happended = h_list.items.len - h_start;
            if (happended > 0) try hspans.append(alloc, .{
                .row = y,
                .off = h_start,
                .len = happended,
            });

            // raw page.Row (u64 bitcast), read at the same position serialize
            // wrote it: after highlights, before the per-cell loop.
            const row_raw: page.Row = @bitCast(try readInt(r, u64));

            const cells = row_data[y].cells;
            for (0..cols) |x| {
                const raw: page.Cell = @bitCast(try readInt(r, u64));
                const style = try StylePod.read(r);
                const glen = try readInt(r, u16);
                const off = g_list.items.len;
                var gi: usize = 0;
                while (gi < glen) : (gi += 1) {
                    // Grapheme codepoints are serialized as u32 but stored as
                    // u21. A corrupt/desynced/hostile frame can carry any u32
                    // here; bound it before narrowing so an out-of-range value
                    // fails closed (error.InvalidCodepoint) like the dirty /
                    // cursor-style / row-index / grid-size validators above,
                    // rather than panicking (safe builds) or silently
                    // truncating (ReleaseFast) on the @intCast.
                    const cp32 = try readInt(r, u32);
                    if (cp32 > std.math.maxInt(u21)) return error.InvalidCodepoint;
                    const cp: u21 = @intCast(cp32);
                    try g_list.append(alloc, cp);
                }
                cells[x] = .{ .raw = raw, .style = style };
                if (glen > 0) try gspans.append(alloc, .{
                    .row = y,
                    .col = x,
                    .off = off,
                    .len = glen,
                });
            }

            row_data[y].dirty = row_dirty;
            row_data[y].selection = selection;
            row_data[y].raw = row_raw;
        }

        const grapheme_pool = try g_list.toOwnedSlice(alloc);
        errdefer alloc.free(grapheme_pool);
        const highlight_pool = try h_list.toOwnedSlice(alloc);
        errdefer alloc.free(highlight_pool);

        for (gspans.items) |s| {
            row_data[s.row].cells[s.col].grapheme = grapheme_pool[s.off .. s.off + s.len];
        }
        for (hspans.items) |s| {
            row_data[s.row].highlights = highlight_pool[s.off .. s.off + s.len];
        }

        return .{
            .rows = rows,
            .cols = cols,
            .dirty = dirty,
            .background = background,
            .foreground = foreground,
            .cursor_color = cursor_color,
            .palette = palette,
            .cursor_x = cursor_x,
            .cursor_y = cursor_y,
            .cursor_visible = cursor_visible,
            .cursor_blinking = cursor_blinking,
            .cursor_password_input = cursor_password_input,
            .cursor_visual_style = cursor_visual_style,
            .cursor_viewport = cursor_viewport,
            .cursor_style = cursor_style,
            .cursor_cell = cursor_cell,
            .scrolled_to_bottom = scrolled_to_bottom,
            .synchronized_output = synchronized_output,
            .scrollbar_total = scrollbar_total,
            .scrollbar_offset = scrollbar_offset,
            .scrollbar_len = scrollbar_len,
            .cursor_blink_visible = cursor_blink_visible,
            .row_data = row_data,
            .grapheme_pool = grapheme_pool,
            .highlight_pool = highlight_pool,
        };
    }
};

/// Whether row `y` of `cur` differs from `prev` (the per-row predicate shared
/// by `countChanges` and `printDiff` so the server-mode count and the Phase-1
/// print can never drift apart). With no previous snapshot, a row counts as
/// changed iff it has any non-blank cell.
fn rowChanged(prev: ?Snapshot, cur: Snapshot, y: usize) bool {
    const row = cur.row_data[y];
    if (prev) |p| {
        if (y >= p.row_data.len) return true;
        return !row.eql(p.row_data[y]);
    }
    for (row.cells) |c| {
        if (!isBlank(c)) return true;
    }
    return false;
}

/// Count changed rows between `prev` and `cur` WITHOUT printing anything. This
/// is the I/O-free half of `printDiff`: server mode only needs the count to
/// feed Session.renderTick's push gate, and the Phase-1 stdout render dump that
/// `printDiff` emits is pure noise there (it bypasses std.log, so it can't be
/// filtered by log level — the fix is to not emit it off the harness path).
pub fn countChanges(prev: ?Snapshot, cur: Snapshot) usize {
    var changed: usize = 0;
    for (0..cur.row_data.len) |y| {
        if (rowChanged(prev, cur, y)) changed += 1;
    }
    return changed;
}

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

    // Determine, per row, whether it changed (shared predicate with
    // countChanges so the count and the print stay in lockstep).
    for (cur.row_data, 0..) |row, y| {
        if (!rowChanged(prev, cur, y)) continue;
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
