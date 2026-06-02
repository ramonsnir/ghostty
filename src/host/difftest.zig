//! Differential cell-by-cell fidelity test (plan §9 residual risks #1 and #2).
//!
//! This proves the host produces a viewport grid that is BYTE-IDENTICAL,
//! cell-by-cell, to what the in-process `.exec` renderer consumes — replacing
//! the planned "Phase-3 visual diff against in-process .exec" with a
//! deterministic, pure, fast cell diff (no shells, no sockets, no GPU).
//!
//! ## How a fixture is driven
//!
//! Each fixture is a fixed byte stream + a grid size. For each one we build
//! TWO independent `terminal.Terminal`s from the SAME bytes:
//!
//!   - REFERENCE: a Terminal fed the bytes through `Terminal.vtStream()`
//!     (`src/terminal/stream_terminal.zig`), then projected with
//!     `render.RenderState.update` — the EXACT source the `.exec` renderer's
//!     rebuildCells consumes (`src/terminal/render.zig`). This is held as the
//!     ground truth and is NOT re-projected.
//!
//!   - HOST: a SECOND Terminal fed the SAME bytes, projected to a core
//!     RenderState, then through the host projector
//!     (`RenderState.Snapshot.fromRenderState`) and the FULL wire round-trip
//!     (`serialize` -> `deserialize`), yielding the pointer-free mirror the
//!     `.client` renderer would consume.
//!
//! Two independent Terminals are used so neither side's `update`/`capture` can
//! perturb the other's dirty state.
//!
//! ### Why `vtStream` and not the literal `.exec` socket path
//!
//! `.exec` feeds child output through `StreamHandler` (`stream_handler.zig`),
//! which mutates the SAME `terminal.Terminal` and only adds IO-side effects
//! (queueRender, DCS/message replies). For GRID state the in-process
//! equivalent is `Terminal.vtStream()` -> `stream_terminal.zig`, which
//! dispatches the full VT/CSI/SGR/OSC parser (including set_mode/reset_mode,
//! alt-screen, erase) into the Terminal. This is the exact path render.zig's
//! own tests use. It is sound for grid fidelity; the literal `.exec` socket
//! path is covered separately by `test.zig`'s "host socket integration".
//!
//! ## What is compared (primary assertion: `Snapshot.eqlRenderState`)
//!
//! The deserialized HOST mirror is compared against the REFERENCE core
//! RenderState, re-reading the RenderState's own fields, across every field the
//! renderer draws: dims; colors/palette (reverse-video pre-applied); per-cell
//! raw packed page.Cell (content_tag, codepoint, wide/spacer, style_id,
//! protected, hyperlink); per-cell grapheme run; per-cell StylePod (gated on
//! the populated-cell condition — `rs` cell .style is undefined for default
//! cells); cursor (active+viewport coord, style, visual_style, visible,
//! blinking, password_input, cell); per-row dirty/selection/highlights; frame
//! dirty.
//!
//! ## Known-placeholder exclusions (NOT silently omitted)
//!
//! The Phase-2a placeholder header bits are NOT derivable from a viewport-only
//! RenderState and are hard-coded by `fromRenderState`
//! (RenderState.zig:451-456): `scrolled_to_bottom`, `synchronized_output`, the
//! `scrollbar` triple, `cursor_blink_visible`. `eqlRenderState` does NOT read
//! them from the RenderState (there is nothing to read); instead this test
//! ASSERTS them at their known constants on the mirror, so the placeholder
//! contract is pinned and can never mask a real per-cell divergence.
//!
//! `dirty` is asserted as `.full` (not excluded): every fixture's first
//! `update` trips the dimension-mismatch redraw branch (render.zig:292-296),
//! so `dirty == .full` on both sides. The `.partial` projection path has its
//! own round-trip test (test.zig "partial") and is out of 2a scope.

const std = @import("std");
const testing = std.testing;

const terminalpkg = @import("../terminal/main.zig");
const render = @import("../terminal/render.zig");
const color = @import("../terminal/color.zig");
const Selection = @import("../terminal/Selection.zig");
const point = @import("../terminal/point.zig");
const RenderStateCore = render.RenderState;

const RenderState = @import("RenderState.zig");
const Snapshot = RenderState.Snapshot;
const StylePod = RenderState.StylePod;

/// Per-fixture knobs. The defaults reproduce the original byte-stream-only
/// behavior; the optional fields let a fixture exercise comparison legs that a
/// pure VT byte stream cannot reach (findings DR-3, ZS-1, ZS-2):
///   - `colors`: seed real default bg/fg/cursor before streaming, so e.g. the
///     reverse-video (DECSCNM) swap actually fires (render.zig:333-339 only
///     swaps when BOTH bg and fg resolve non-null) and so cursor_color
///     round-trips a non-null value.
///   - `select_viewport`: after streaming, set a selection on each Terminal's
///     active screen over the given inclusive viewport rectangle, so the
///     per-row `selection` leg compares real ranges instead of null-vs-null.
///   - `scroll_top`: after streaming, scroll the viewport to the top so the
///     cursor row leaves the viewport and `cursor.viewport` projects null
///     (the render.zig "cursor out of viewport" branch).
const Opts = struct {
    colors: ?terminalpkg.Terminal.Colors = null,
    /// Inclusive viewport-relative selection rectangle {x0,y0,x1,y1}, or null.
    select_viewport: ?[4]u16 = null,
    scroll_top: bool = false,
};

/// Run the full differential pipeline for one byte stream + grid size and
/// assert cell-by-cell fidelity + wire stability + placeholder pinning.
///
/// `name` is purely for failure output. Each call builds its own pair of
/// Terminals; nothing is shared across fixtures.
fn runFixture(
    name: []const u8,
    cols: u16,
    rows: u16,
    bytes: []const u8,
) !void {
    return runFixtureOpts(name, cols, rows, bytes, .{});
}

/// Build (and tear down) one Terminal: init (optionally with seeded colors),
/// feed `bytes` through the full VT parser, then apply any post-stream
/// programmatic ops (selection / scroll) the fixture requested.
fn buildTerminal(
    alloc: std.mem.Allocator,
    cols: u16,
    rows: u16,
    bytes: []const u8,
    opts: Opts,
) !terminalpkg.Terminal {
    var term = try terminalpkg.Terminal.init(alloc, .{
        .cols = cols,
        .rows = rows,
        .colors = opts.colors orelse .default,
    });
    errdefer term.deinit(alloc);
    {
        // The stream's handler holds a pointer to `term`; the caller keeps
        // `term` alive for the whole comparison. Feed the full parser path.
        var s = term.vtStream();
        defer s.deinit();
        s.nextSlice(bytes);
    }

    // A VT byte stream cannot create a selection, so set one programmatically
    // when requested — this is the only way the per-row selection leg sees
    // non-null data (finding DR-3).
    if (opts.select_viewport) |r| {
        const scr = term.screens.active;
        const p0 = scr.pages.pin(.{ .viewport = .{ .x = r[0], .y = r[1] } }) orelse
            return error.BadSelectionPin;
        const p1 = scr.pages.pin(.{ .viewport = .{ .x = r[2], .y = r[3] } }) orelse
            return error.BadSelectionPin;
        try scr.select(Selection.init(p0, p1, false));
    }

    // Scroll the viewport to the top so the cursor row leaves the viewport and
    // cursor.viewport projects null (finding DR-3).
    if (opts.scroll_top) term.scrollViewport(.{ .top = {} });

    return term;
}

fn runFixtureOpts(
    name: []const u8,
    cols: u16,
    rows: u16,
    bytes: []const u8,
    opts: Opts,
) !void {
    const alloc = testing.allocator;

    // --- REFERENCE: the renderer's literal input ---
    var term_ref = try buildTerminal(alloc, cols, rows, bytes, opts);
    defer term_ref.deinit(alloc);
    var rs_ref: RenderStateCore = .empty;
    defer rs_ref.deinit(alloc);
    try rs_ref.update(alloc, &term_ref);

    // --- HOST: capture -> serialize -> deserialize ---
    // A SECOND independent Terminal fed identically, so neither side's
    // update/capture can perturb the other's dirty state.
    var term_host = try buildTerminal(alloc, cols, rows, bytes, opts);
    defer term_host.deinit(alloc);
    var rs_host: RenderStateCore = .empty;
    defer rs_host.deinit(alloc);
    try rs_host.update(alloc, &term_host);

    var snap = try Snapshot.fromRenderState(alloc, &rs_host);
    defer snap.deinit(alloc);

    const wire = try snap.serialize(alloc);
    defer alloc.free(wire);

    var mirror = try Snapshot.deserialize(alloc, wire);
    defer mirror.deinit(alloc);

    // --- PRIMARY ASSERTION: host mirror vs renderer's RenderState input ---
    var mm: Snapshot.Mismatch = .{};
    if (!mirror.eqlRenderState(&rs_ref, &mm)) {
        std.debug.print(
            "\n[difftest:{s}] cell fidelity mismatch: field='{s}'",
            .{ name, mm.field },
        );
        if (mm.y) |y| std.debug.print(" y={d}", .{y});
        if (mm.x) |x| std.debug.print(" x={d}", .{x});
        std.debug.print(
            " expected=0x{x} actual=0x{x}\n",
            .{ mm.expected, mm.actual },
        );
        return error.CellFidelityMismatch;
    }

    // --- WIRE STABILITY (risk #2, pointer-free): re-serialize the mirror and
    // require byte-identical output. A fixed point proves no pointer identity
    // leaked into the bytes. ---
    const wire2 = try mirror.serialize(alloc);
    defer alloc.free(wire2);
    try testing.expectEqualSlices(u8, wire, wire2);

    // --- REDUNDANT CROSS-CHECK: pure Snapshot-vs-Snapshot equality path.
    // Project the REFERENCE RenderState into its own Snapshot and compare with
    // the deserialized mirror via the existing Snapshot.eql. This exercises the
    // full Snapshot equality routine end-to-end (incl. placeholder bits, which
    // are identical by construction on both sides). ---
    var ref_snap = try Snapshot.fromRenderState(alloc, &rs_ref);
    defer ref_snap.deinit(alloc);
    try testing.expect(ref_snap.eql(mirror));

    // --- KNOWN-PLACEHOLDER PINNING (documented exclusions; NOT compared to
    // RenderState because they are not derivable from it). Pin each at its
    // fromRenderState constant on the mirror so the placeholder contract holds
    // and never silently masks a real per-cell divergence. ---
    try testing.expectEqual(true, mirror.scrolled_to_bottom);
    try testing.expectEqual(false, mirror.synchronized_output);
    try testing.expectEqual(@as(u64, 0), mirror.scrollbar_total);
    try testing.expectEqual(@as(u64, 0), mirror.scrollbar_offset);
    try testing.expectEqual(@as(u64, 0), mirror.scrollbar_len);
    try testing.expectEqual(true, mirror.cursor_blink_visible);

    // dirty is asserted .full (not excluded): first update always full-redraws.
    try testing.expectEqual(RenderStateCore.Dirty.full, mirror.dirty);
}

test "host difftest F1 plain text + wrap + scroll into scrollback" {
    // cols=10,rows=3. "ABCDEFGHIJKLMNOPQR" wraps at col 10, then several
    // CRLF+text push the first rows into scrollback so the viewport shows
    // scrolled content. Exercises codepoint cells, wrap-continuation flags in
    // the packed Cell, and viewport-after-scroll projection.
    try runFixture(
        "F1",
        10,
        3,
        "ABCDEFGHIJKLMNOPQR\r\nrow2\r\nrow3\r\nrow4\r\nrow5",
    );
}

test "host difftest F2 SGR named 16 + 256-color + flags + reset" {
    // cols=24,rows=2. Named 16-color fg (palette tag), 256-color (palette idx
    // 208), bold+italic+underline+strikethrough flags, default-reset.
    try runFixture(
        "F2",
        24,
        2,
        "\x1b[31mRED\x1b[0m \x1b[38;5;208m256\x1b[0m \x1b[1;3;4;9mBISU\x1b[0m",
    );
}

test "host difftest F3 truecolor fg+bg + inverse attr + reset" {
    // cols=20,rows=2. 24-bit fg AND bg (rgb tag), SGR 7 inverse flag on the
    // style (distinct from DECSCNM), default reset.
    try runFixture(
        "F3",
        20,
        2,
        "\x1b[38;2;10;20;30m\x1b[48;2;200;100;50mTRUE\x1b[7mREV\x1b[0m",
    );
}

test "host difftest F4 cursor positioning + erase-in-line" {
    // cols=12,rows=4. CUP to (2,3), erase-in-line to EOL, then CUU/CUD
    // movement; exercises cursor active+viewport coordinate projection and
    // erased (blank) cells.
    try runFixture(
        "F4",
        12,
        4,
        "line0\r\nline1\r\nline2\x1b[2;3HX\x1b[K\x1b[1;1H\x1b[1B\x1b[2A",
    );
}

test "host difftest F5 wide CJK + combining + ZWJ grapheme clusters" {
    // cols=12,rows=2. 你好! (two wide CJK = 4 cells w/ spacer_tail) then a
    // combining acute + a man-ZWJ emoji. Exercises wide flag + spacer_tail in
    // the packed Cell, content_tag codepoint_grapheme, and the inline
    // grapheme-run u21 copy + round-trip.
    try runFixture(
        "F5",
        12,
        2,
        "\xe4\xbd\xa0\xe5\xa5\xbd!\r\ne\u{0301}\u{1f468}\u{200d}\u{1f469}",
    );
}

test "host difftest F6 reverse-video / DECSCNM swaps bg/fg" {
    // cols=10,rows=2. Set DECSCNM (mode 5 reverse_colors) and write text.
    //
    // render.zig:333-339 only performs the bg/fg swap when BOTH
    // t.colors.background AND .foreground resolve non-null. Terminal.init's
    // default Colors leaves them .unset (get() -> null), so with the default
    // colors the swap NEVER fires and bg/fg stay at RenderState.empty's
    // {0,0,0}/{0xff,0xff,0xff} defaults — making the assertion pass vacuously
    // (both sides equally fail to swap). So we SEED distinct real default
    // bg/fg (finding ZS-1) so the swap actually fires, and additionally PIN
    // below that the swap was observed (mirror.background == FG seed,
    // mirror.foreground == BG seed), not merely that both sides agree.
    // We also seed a cursor color so cursor_color round-trips a non-null value
    // at least once on the differential path (finding ZS-2).
    const bg_seed: color.RGB = .{ .r = 0x10, .g = 0x20, .b = 0x30 };
    const fg_seed: color.RGB = .{ .r = 0xc0, .g = 0xd0, .b = 0xe0 };
    const cursor_seed: color.RGB = .{ .r = 0xff, .g = 0x00, .b = 0x00 };
    const opts: Opts = .{ .colors = .{
        .background = .init(bg_seed),
        .foreground = .init(fg_seed),
        .cursor = .init(cursor_seed),
        .palette = .default,
    } };
    try runFixtureOpts("F6", 10, 2, "\x1b[?5hNORMAL", opts);

    // Pin the swap directly (independent of the differential equality): build
    // the same state, project, and confirm the SWAP was observed end-to-end
    // through projection + wire round-trip — so this fixture can FAIL if
    // reverse-video color projection ever regressed.
    const alloc = testing.allocator;
    var term = try buildTerminal(alloc, 10, 2, "\x1b[?5hNORMAL", opts);
    defer term.deinit(alloc);
    var rs: RenderStateCore = .empty;
    defer rs.deinit(alloc);
    try rs.update(alloc, &term);

    var snap = try Snapshot.fromRenderState(alloc, &rs);
    defer snap.deinit(alloc);
    const wire = try snap.serialize(alloc);
    defer alloc.free(wire);
    var mirror = try Snapshot.deserialize(alloc, wire);
    defer mirror.deinit(alloc);

    // DECSCNM swap: viewport background takes the FOREGROUND seed and vice
    // versa. cursor_color carries the seeded value (non-null branch).
    try testing.expect(mirror.background.eql(fg_seed));
    try testing.expect(mirror.foreground.eql(bg_seed));
    try testing.expect(mirror.cursor_color != null);
    try testing.expect(mirror.cursor_color.?.eql(cursor_seed));
}

test "host difftest F7 alt-screen TUI shape (1049h)" {
    // cols=20,rows=5. Enter alt screen (1049h), clear, draw a boxed TUI shape;
    // the captured snapshot must reflect the ACTIVE (alt) screen, not the
    // primary buffer underneath (render.zig:268 s=t.screens.active).
    try runFixture(
        "F7",
        20,
        5,
        "primary text\r\n\x1b[?1049h\x1b[2J\x1b[H+-----+\r\n|  X  |\r\n+-----+",
    );
}

test "host difftest F7b alt-screen exit (1049l) restores primary" {
    // Sibling sub-case: exit alt screen and confirm primary content returns
    // through the active-screen-resolved projection.
    try runFixture(
        "F7b",
        20,
        5,
        "primary text\r\n\x1b[?1049h\x1b[2J\x1b[H+-----+\r\n|  X  |\r\n+-----+\x1b[?1049l",
    );
}

test "host difftest F8 synthetic vim-like full-screen redraw" {
    // cols=40,rows=10. Enter alt screen, clear, a reverse-video status line,
    // ~6 rows of mixed text incl. tilde-prefixed empty lines (vim style), a
    // 24-bit-colored token, a CJK word, final CUP to a mid-screen edit
    // position. The longest realistic stream; exercises modes + SGR + cursor +
    // wide cells together end-to-end.
    const seq =
        "\x1b[?1049h\x1b[2J\x1b[H" ++
        "\x1b[7m  NORMAL  main.zig                                \x1b[0m\r\n" ++
        "const std = \x1b[38;2;220;160;40m@import\x1b[0m(\"std\");\r\n" ++
        "// \xe4\xbd\xa0\xe5\xa5\xbd comment\r\n" ++
        "pub fn main() void {}\r\n" ++
        "~\r\n~\r\n~\r\n~\r\n" ++
        "\x1b[10;1H\x1b[7m:wq\x1b[0m" ++
        "\x1b[2;14H";
    try runFixture("F8", 40, 10, seq);
}

test "host difftest F9 active-screen selection range" {
    // cols=12,rows=3. Three rows of text, then a programmatic selection over a
    // viewport rectangle (rows 0-1, a mid-line span). A VT byte stream cannot
    // set a selection, so without this the per-row `selection` leg only ever
    // compares null-vs-null (finding DR-3). render.zig populates row.selection
    // only when the active screen has a selection, so this drives the real
    // selection projection + wire round-trip across both sides.
    try runFixtureOpts(
        "F9",
        12,
        3,
        "row0text\r\nrow1text\r\nrow2text",
        .{ .select_viewport = .{ 2, 0, 5, 1 } },
    );
}

test "host difftest row.raw negative perturbation" {
    // Prove the new per-row `row.raw` leg of eqlRenderState actually bites: a
    // bit flipped in a serialized row's page.Row flag bits must surface as a
    // "row.raw" mismatch (not silently pass like the pre-fix Snapshot did).
    //
    // We self-locate row 0's raw page.Row u64 by VALUE in the serialized bytes
    // (not a magic offset) and flip the low bit of byte 4 of that u64. In the
    // LE layout the low u32 (bytes 0-3) is the `cells` Offset and the boolean
    // flag bits begin at bit 32 (byte 4, low bit = `wrap`). The source row has
    // wrap=0, so setting it makes the deserialized mirror's row.raw differ from
    // the live RenderState — a pure-flag perturbation that leaves the embedded
    // `cells` Offset intact (frame stays structurally valid).
    const alloc = testing.allocator;
    const cols: u16 = 10;
    const rows: u16 = 3;
    const bytes = "ABCDEFGHIJKLMNOPQR\r\nrow2\r\nrow3\r\nrow4\r\nrow5";

    var term_ref = try buildTerminal(alloc, cols, rows, bytes, .{});
    defer term_ref.deinit(alloc);
    var rs_ref: RenderStateCore = .empty;
    defer rs_ref.deinit(alloc);
    try rs_ref.update(alloc, &term_ref);

    var snap = try Snapshot.fromRenderState(alloc, &rs_ref);
    defer snap.deinit(alloc);
    try testing.expect(snap.row_data.len > 0);

    const wire = try snap.serialize(alloc);
    defer alloc.free(wire);

    const target_raw: u64 = @bitCast(snap.row_data[0].raw);
    var raw_le: [8]u8 = undefined;
    std.mem.writeInt(u64, &raw_le, target_raw, .little);
    const raw_off = std.mem.indexOf(u8, wire, &raw_le) orelse
        return error.RowRawNotFoundInFrame;
    // Set the `wrap` flag bit (byte 4, bit 0), which the source row has clear.
    wire[raw_off + 4] |= 0x01;

    var mirror = try Snapshot.deserialize(alloc, wire);
    defer mirror.deinit(alloc);

    var mm: Snapshot.Mismatch = .{};
    try testing.expect(!mirror.eqlRenderState(&rs_ref, &mm));
    try testing.expectEqualStrings("row.raw", mm.field);
    try testing.expect(mm.y != null);
}

test "host difftest F10 scrolled-up viewport -> cursor.viewport null" {
    // cols=10,rows=3. Push content into scrollback (so there IS scrollback),
    // then scroll the viewport to the TOP. The cursor stays on the last
    // (bottom) logical row, which is no longer inside the viewport, so
    // render.zig leaves cursor.viewport null (the "cursor out of viewport"
    // branch). Without this every fixture keeps the cursor pinned in-viewport
    // and that null-projection branch of the cursor_viewport leg is never
    // exercised (finding DR-3).
    try runFixtureOpts(
        "F10",
        10,
        3,
        "r0\r\nr1\r\nr2\r\nr3\r\nr4\r\nr5",
        .{ .scroll_top = true },
    );
}
