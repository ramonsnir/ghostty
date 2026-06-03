//! Differential cell-by-cell fidelity test for the `.client` decode path
//! (Phase 2b Slice 2).
//!
//! This is the GUI-side mirror of `src/host/difftest.zig`. Where the host
//! difftest proves the host PROJECTION (`fromRenderState` -> `serialize` ->
//! `deserialize`) is cell-identical to the renderer's RenderState input, this
//! test proves the FULL Phase-2b loop:
//!
//!     fromRenderState -> serialize -> encodeFrame (BE len + tag + session_id +
//!     snapshot bytes) -> FrameReader (split-push, partial-read tolerant) ->
//!     GridFrame.decode -> Snapshot.deserialize -> Client.rehydrate (into a
//!     real terminal.RenderState mirror) -> re-project the mirror via
//!     fromRenderState -> compare (eqlRenderState) against an independent
//!     reference RenderState
//!
//! is cell-by-cell identical to what the in-process `.exec` renderer literally
//! consumes — with NO shells, NO sockets, NO GPU.
//!
//! ## Why re-project the mirror through the audited comparator
//!
//! The rehydrated mirror is a `terminal.RenderState`. Rather than write a brand
//! new RenderState<->RenderState comparator, we re-project the mirror through
//! the same `Snapshot.fromRenderState` the host uses, then assert it with the
//! already-audited `Snapshot.eqlRenderState` against the independent reference
//! RenderState. This reuses the proven cross-path comparator (which bitcasts
//! raw cells and gates style reads on the populated condition) and additionally
//! proves the rehydrated RenderState round-trips byte-stably.
//!
//! ## Raw style cross-check (independent of the re-projection)
//!
//! Re-projecting the mirror through `fromRenderState` puts `fromStyle`/`fromColor`
//! on BOTH sides of the style comparison, so a mis-mapping shared symmetrically
//! by `rehydrateStyle` (its inverse) would cancel and stay invisible. To close
//! that gap (the host difftest compares the deserialized Snapshot DIRECTLY, raw
//! to raw) each fixture additionally compares the mirror's RAW
//! `terminal.style.Style` — the cursor style and every populated cell's style —
//! against the reference RenderState via `Style.eql`, WITHOUT routing the mirror
//! through `fromStyle`. This proves `rehydrateStyle`/`rehydrateColor`
//! independently of the projection that produced the wire bytes.
//!
//! ## Negative perturbation (proves the diff bites)
//!
//! A single byte inside an emitted cell's packed `raw` u64 is flipped in the
//! framed bytes. The target offset is NOT a magic constant: we read the
//! reference snapshot's row-0 cell-0 `raw` value, bitcast it to its LE byte
//! pattern, and locate that pattern in the framed payload — so the flip is
//! self-locating and cannot silently drift onto an uncompared header field if
//! the wire layout changes. We then flip the low (codepoint) byte and assert the
//! outcome is clean-decode + a mismatch whose `field` is a cell field with a
//! non-null x/y, proving the divergence landed on the row-cell decode path (not
//! some incidental header byte) and that the fidelity assertion is not vacuous.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const testing = std.testing;

const xev = @import("../global.zig").xev;
const renderer = @import("../renderer.zig");
const terminalpkg = @import("../terminal/main.zig");
const render = @import("../terminal/render.zig");
const RenderStateCore = render.RenderState;
const Selection = @import("../terminal/Selection.zig");
const Style = @import("../terminal/style.zig").Style;

const termio = @import("../termio.zig");
const HostRenderState = @import("../host/RenderState.zig");
const Snapshot = HostRenderState.Snapshot;
const protocol = @import("../host/protocol.zig");
const Client = @import("Client.zig");
const inputpkg = @import("../input.zig");
const LinkSet = @import("../renderer/link.zig").Set;
const apprt = @import("../apprt.zig");
const App = @import("../App.zig");

/// Per-fixture knobs, mirroring difftest.zig's Opts so the client test can
/// reach the same comparison legs a pure VT byte stream cannot (findings DF-4):
///   - `select_viewport`: set a selection on the active screen over the given
///     inclusive viewport rectangle, so rehydrate's per-row `selection` non-null
///     branch (Client.zig:502) is exercised instead of only null-vs-null.
///   - `scroll_top`: scroll the viewport to the top so the cursor row leaves the
///     viewport and `cursor.viewport` projects null, exercising rehydrate's
///     cursor.viewport else-branch (Client.zig:418-422).
const Opts = struct {
    /// Inclusive viewport-relative selection rectangle {x0,y0,x1,y1}, or null.
    select_viewport: ?[4]u16 = null,
    scroll_top: bool = false,
};

/// Build one Terminal: init, feed `bytes` through the full VT parser, then apply
/// any requested post-stream programmatic ops. (Mirrors difftest.zig's
/// buildTerminal; that helper is file-private there.)
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
        .colors = .default,
    });
    errdefer term.deinit(alloc);
    {
        var s = term.vtStream();
        defer s.deinit();
        s.nextSlice(bytes);
    }

    // A VT byte stream cannot create a selection; set one programmatically so
    // the per-row selection leg sees non-null data (finding DF-4).
    if (opts.select_viewport) |r| {
        const scr = term.screens.active;
        const p0 = scr.pages.pin(.{ .viewport = .{ .x = r[0], .y = r[1] } }) orelse
            return error.BadSelectionPin;
        const p1 = scr.pages.pin(.{ .viewport = .{ .x = r[2], .y = r[3] } }) orelse
            return error.BadSelectionPin;
        try scr.select(Selection.init(p0, p1, false));
    }

    // Scroll the viewport to the top so the cursor leaves it and
    // cursor.viewport projects null (finding DF-4).
    if (opts.scroll_top) term.scrollViewport(.{ .top = {} });

    return term;
}

/// Compare the mirror's RAW `terminal.style.Style` (cursor + every populated
/// cell) DIRECTLY against the reference RenderState's raw styles, WITHOUT
/// routing the mirror through `fromStyle`. Re-projection (runClientFixture's
/// primary leg) puts `fromStyle` on both sides, so a mis-map shared by
/// `rehydrateStyle`/`fromStyle` would cancel; this leg breaks that
/// self-reference and exercises rehydrateStyle/rehydrateColor independently of
/// the projection that produced the wire bytes (finding DF-3). The populated-
/// cell gate matches eqlRenderState (RenderState.zig:694-697): the renderer's
/// per-cell `.style` is undefined for default cells, so we only read it where
/// the raw cell is populated.
fn assertRawStyleFidelity(
    name: []const u8,
    mirror: *const RenderStateCore,
    rs_ref: *const RenderStateCore,
) !void {
    // Cursor style is always valid post-update on both sides.
    if (!mirror.cursor.style.eql(rs_ref.cursor.style)) {
        std.debug.print(
            "\n[client difftest:{s}] raw cursor.style mismatch\n",
            .{name},
        );
        return error.RawStyleFidelityMismatch;
    }

    const m_rows = mirror.row_data.slice();
    const r_rows = rs_ref.row_data.slice();
    try testing.expectEqual(r_rows.len, m_rows.len);
    const m_cells = m_rows.items(.cells);
    const r_cells = r_rows.items(.cells);

    for (0..r_rows.len) |y| {
        const mc = m_cells[y].slice();
        const rc = r_cells[y].slice();
        const r_raw = rc.items(.raw);
        const m_style = mc.items(.style);
        const r_style = rc.items(.style);
        try testing.expectEqual(rc.len, mc.len);
        for (0..rc.len) |x| {
            const populated = r_raw[x].style_id > 0 or
                r_raw[x].content_tag == .bg_color_rgb or
                r_raw[x].content_tag == .bg_color_palette;
            if (!populated) continue;
            if (!m_style[x].eql(r_style[x])) {
                std.debug.print(
                    "\n[client difftest:{s}] raw cell.style mismatch y={d} x={d}\n",
                    .{ name, y, x },
                );
                return error.RawStyleFidelityMismatch;
            }
        }
    }
}

/// Run the full client decode pipeline for one byte stream + grid size and
/// assert cell-by-cell fidelity of the rehydrated mirror against an
/// independent reference RenderState.
fn runClientFixture(
    name: []const u8,
    cols: u16,
    rows: u16,
    bytes: []const u8,
) !void {
    return runClientFixtureOpts(name, cols, rows, bytes, .{});
}

fn runClientFixtureOpts(
    name: []const u8,
    cols: u16,
    rows: u16,
    bytes: []const u8,
    opts: Opts,
) !void {
    const alloc = testing.allocator;

    // --- REFERENCE: the renderer's literal input (never routed through the
    // client). ---
    var term_ref = try buildTerminal(alloc, cols, rows, bytes, opts);
    defer term_ref.deinit(alloc);
    var rs_ref: RenderStateCore = .empty;
    defer rs_ref.deinit(alloc);
    try rs_ref.update(alloc, &term_ref);

    // --- HOST PRODUCER: an independent Terminal -> RenderState -> Snapshot ->
    // framed GridFrame bytes (the literal BE-len + tag + payload wire form). ---
    const framed = try buildFramed(alloc, cols, rows, bytes, opts);
    defer alloc.free(framed);

    // --- CLIENT DECODE via the FrameReader path (proves reader -> handleFrame,
    // not just GridFrame.decode). Split the frame to exercise reassembly. ---
    var client = try Client.init(alloc, .{});
    defer client.deinit();

    try client.reader.push(alloc, framed[0..3]);
    try client.reader.push(alloc, framed[3..]);
    while (try client.reader.next(alloc)) |frame| {
        try client.handleFrame(alloc, frame.tag, frame.payload);
    }

    // --- PRIMARY ASSERTION: re-project the mirror through the audited
    // comparator and compare against the independent reference RenderState. ---
    var mirror_snap = try Snapshot.fromRenderState(alloc, &client.render_state);
    defer mirror_snap.deinit(alloc);

    var mm: Snapshot.Mismatch = .{};
    if (!mirror_snap.eqlRenderState(&rs_ref, &mm)) {
        std.debug.print(
            "\n[client difftest:{s}] cell fidelity mismatch: field='{s}'",
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

    // --- RAW STYLE CROSS-CHECK: compare the mirror's raw terminal.Style
    // directly (no re-projection) so rehydrateStyle/rehydrateColor are proven
    // independently of fromStyle (finding DF-3). ---
    try assertRawStyleFidelity(name, &client.render_state, &rs_ref);

    // --- CROSS-CHECK: pure Snapshot-vs-Snapshot equality (exercises the full
    // Snapshot.eql incl. placeholder bits). ---
    var ref_snap = try Snapshot.fromRenderState(alloc, &rs_ref);
    defer ref_snap.deinit(alloc);
    try testing.expect(ref_snap.eql(mirror_snap));
}

/// Build the framed GridFrame wire bytes for a fixture: independent Terminal ->
/// RenderState -> Snapshot.fromRenderState -> encodeFrame. Caller owns the
/// returned slice.
fn buildFramed(
    alloc: std.mem.Allocator,
    cols: u16,
    rows: u16,
    bytes: []const u8,
    opts: Opts,
) ![]u8 {
    var term_host = try buildTerminal(alloc, cols, rows, bytes, opts);
    defer term_host.deinit(alloc);
    var rs_host: RenderStateCore = .empty;
    defer rs_host.deinit(alloc);
    try rs_host.update(alloc, &term_host);

    var snap = try Snapshot.fromRenderState(alloc, &rs_host);
    defer snap.deinit(alloc);

    // encode-side GridFrame borrows the snapshot (owns_snapshot=false).
    const gf = protocol.GridFrame{
        .session_id = 0,
        .snapshot = snap,
        .owns_snapshot = false,
    };
    return try protocol.encodeFrame(alloc, .grid_frame, gf);
}

// --- Slice 3a: renderer source-selection + pin-gating wiring ---

test "client renderer source-selection + pin-gating (Slice 3a)" {
    // T2 (Slice 3a, GPU-free): prove the renderer's `updateFrame` correctly
    // (a) SELECTS the host mirror as its draw source when `state.mirror != null`
    //     (vs. the `RenderState.update(terminal)` arm when it's null), and
    // (b) GATES the two pin-dereferencing paths (linkCells,
    //     updateHighlightsFlattened) OFF under a mirror — which is what protects
    //     the mirror's poisoned `invalid_pin` row pins from ever being
    //     dereferenced this phase.
    //
    // updateFrame itself needs a GPU-backed renderer Self, so this exercises the
    // exact branch PREDICATES updateFrame uses (`state.mirror == null`) at the
    // smallest GPU-free unit, plus proves copyFrom (the mirror arm's body) lands
    // a faithful owned copy and that the gated calls would otherwise touch the
    // sentinel pins. The end-to-end GPU draw is deferred to the human smoke.
    const alloc = testing.allocator;

    // --- Build a populated mirror via the real client decode pipeline (pins ==
    // invalid_pin), exactly as the fidelity fixtures do. ---
    const cols: u16 = 10;
    const rows: u16 = 3;
    const bytes = "ABCD\r\nEFGH";

    const framed = try buildFramed(alloc, cols, rows, bytes, .{});
    defer alloc.free(framed);

    var client = try Client.init(alloc, .{});
    defer client.deinit();
    try client.reader.push(alloc, framed);
    while (try client.reader.next(alloc)) |frame| {
        try client.handleFrame(alloc, frame.tag, frame.payload);
    }
    try testing.expect(client.render_state.rows == rows);

    // Sanity: the mirror's row pins ARE the poisoned sentinel. This is the
    // hazard the gate exists to avoid; dereferencing `.node` is UB by design.
    {
        const mirror_rows = client.render_state.row_data.slice();
        const pins = mirror_rows.items(.pin);
        for (pins) |p| {
            try testing.expectEqual(
                @as(usize, 0xdead_0000_dead_0000),
                @intFromPtr(p.node),
            );
            try testing.expect(p.garbage);
        }
    }

    var mutex: std.Thread.Mutex = .{};

    // --- (a) SOURCE SELECTION. updateFrame branches on `state.mirror`: a
    // non-null mirror => copyFrom(mirror); null => update(terminal). We assert
    // the predicate AND that the mirror arm's body (copyFrom) produces an owned
    // draw source equal to the mirror. ---
    {
        // The .client construction: terminal is unused under a mirror, but the
        // field is non-optional, so point it at a throwaway live terminal. The
        // assertion is that the MIRROR is selected, never `terminal`.
        var dummy_term = try buildTerminal(alloc, cols, rows, "", .{});
        defer dummy_term.deinit(alloc);

        const state_client: renderer.State = .{
            .mutex = &mutex,
            .terminal = &dummy_term,
            .mirror = &client.render_state,
        };
        // The exact predicate updateFrame uses to pick the mirror arm.
        try testing.expect(state_client.mirror != null);

        // Drive the mirror arm's body: copyFrom into a renderer-owned local.
        var local: RenderStateCore = .empty;
        defer local.deinit(alloc);
        try local.copyFrom(alloc, state_client.mirror.?);

        // The chosen draw source equals the mirror (re-projected through the
        // audited comparator), and is independently owned (different backing).
        var local_snap = try Snapshot.fromRenderState(alloc, &local);
        defer local_snap.deinit(alloc);
        var mirror_snap = try Snapshot.fromRenderState(alloc, &client.render_state);
        defer mirror_snap.deinit(alloc);
        try testing.expect(local_snap.eql(mirror_snap));
        try testing.expect(local.row_data.bytes != client.render_state.row_data.bytes);
    }

    // --- The .exec construction: mirror == null => update(terminal) arm. ---
    {
        var term_exec = try buildTerminal(alloc, cols, rows, bytes, .{});
        defer term_exec.deinit(alloc);
        const state_exec: renderer.State = .{
            .mutex = &mutex,
            .terminal = &term_exec,
        };
        // .exec selects the update(terminal) arm.
        try testing.expect(state_exec.mirror == null);

        // Drive the .exec arm's body to confirm it is the live-terminal path.
        var local: RenderStateCore = .empty;
        defer local.deinit(alloc);
        try local.update(alloc, state_exec.terminal);
        try testing.expectEqual(@as(@TypeOf(local.rows), rows), local.rows);
    }

    // --- (b) PIN GATING. The two pin-dereferencing paths in updateFrame —
    // RenderState.linkCells (OSC8 hover links, generic.zig ~1307) and
    // RenderState.updateHighlightsFlattened (search highlights, generic.zig
    // ~1378/1389) — both index `row_data.items(.pin)` and deref `pin.node`.
    // Under a client mirror those pins are the poisoned `invalid_pin` sentinel
    // (asserted above at "Sanity:"), so dereferencing them is UB by design.
    //
    // Both call sites are gated by `state.usesLivePinPaths()` — the SAME pure
    // predicate the renderer evaluates (renderer/State.zig), reused here so this
    // test pins the renderer's actual gate rather than re-deriving the literal.
    // If a future edit inverts/removes either gate, `usesLivePinPaths()` is the
    // shared truth: the renderer would change behavior in lockstep with what
    // this asserts. We verify the predicate is FALSE under a mirror (the gates
    // skip the pin paths) and TRUE under .exec (the gates run them).
    //
    // We deliberately do NOT call linkCells/updateHighlightsFlattened on the
    // mirror: doing so is precisely the sentinel-deref UB the gate prevents, and
    // the GPU-bound remainder of updateFrame's body is deferred to the human
    // ReleaseLocal smoke test (no headless GPU here).
    {
        const state_client: renderer.State = .{
            .mutex = &mutex,
            .terminal = undefined, // never read under a mirror
            .mirror = &client.render_state,
        };
        // The renderer's exact gate predicate. Under a mirror it is false, so
        // both `if (!state.usesLivePinPaths()) break :osc8 .empty;` and
        // `if (state.usesLivePinPaths() and ...)` skip the pin paths.
        try testing.expect(!state_client.usesLivePinPaths());

        // And it is the negation of "has a mirror" — i.e. the pin paths run
        // iff there is NO mirror. Tie this to the sentinel hazard: the pins we
        // would have dereferenced are the poisoned ones, confirming what the
        // gate is actually protecting.
        try testing.expect(state_client.mirror != null);
        const gated_pins = state_client.mirror.?.row_data.slice().items(.pin);
        for (gated_pins) |p| {
            try testing.expectEqual(
                @as(usize, 0xdead_0000_dead_0000),
                @intFromPtr(p.node),
            );
        }

        // Under .exec (mirror == null) the same predicate is TRUE: the pin
        // paths run, which is today's unchanged behavior. (terminal is required
        // by the field but never read by usesLivePinPaths.)
        var dummy_term_b = try buildTerminal(alloc, cols, rows, "", .{});
        defer dummy_term_b.deinit(alloc);
        const state_exec: renderer.State = .{
            .mutex = &mutex,
            .terminal = &dummy_term_b,
        };
        try testing.expect(state_exec.usesLivePinPaths());
    }
}

// --- Fixtures (byte streams copied verbatim from host/difftest.zig). ---

test "client decode fidelity F1 plain text + wrap + scroll" {
    try runClientFixture(
        "F1",
        10,
        3,
        "ABCDEFGHIJKLMNOPQR\r\nrow2\r\nrow3\r\nrow4\r\nrow5",
    );
}

test "client decode fidelity F2 SGR named + 256-color + flags + reset" {
    // Exercises Client.rehydrateStyle (palette + rgb colors + 4 flags).
    try runClientFixture(
        "F2",
        24,
        2,
        "\x1b[31mRED\x1b[0m \x1b[38;5;208m256\x1b[0m \x1b[1;3;4;9mBISU\x1b[0m",
    );
}

test "client decode fidelity F5 wide CJK + combining + ZWJ grapheme" {
    // Exercises the grapheme-run u21 arena dupe in rehydrate.
    try runClientFixture(
        "F5",
        12,
        2,
        "\xe4\xbd\xa0\xe5\xa5\xbd!\r\ne\u{0301}\u{1f468}\u{200d}\u{1f469}",
    );
}

test "client decode fidelity F3 truecolor fg+bg + inverse attr + reset" {
    // Exercises rehydrateColor's .rgb branch (24-bit fg AND bg) plus the
    // inverse flag — the rgb color leg the palette/named fixtures don't reach.
    try runClientFixture(
        "F3",
        20,
        2,
        "\x1b[38;2;10;20;30m\x1b[48;2;200;100;50mTRUE\x1b[7mREV\x1b[0m",
    );
}

test "client decode fidelity F7 alt-screen TUI shape (1049h)" {
    // Exercises active-screen resolution (the mirror must reflect the alt
    // screen, not the primary buffer underneath).
    try runClientFixture(
        "F7",
        20,
        5,
        "primary text\r\n\x1b[?1049h\x1b[2J\x1b[H+-----+\r\n|  X  |\r\n+-----+",
    );
}

test "client decode fidelity F9 active-screen selection range" {
    // A VT byte stream cannot set a selection, so without this the per-row
    // selection leg only ever compares null-vs-null. Drives rehydrate's
    // non-null selection branch (Client.zig:502) against an independent
    // reference (finding DF-4).
    try runClientFixtureOpts(
        "F9",
        12,
        3,
        "row0text\r\nrow1text\r\nrow2text",
        .{ .select_viewport = .{ 2, 0, 5, 1 } },
    );
}

test "client decode fidelity F10 scrolled-up viewport -> cursor.viewport null" {
    // Push content into scrollback then scroll to the TOP so the cursor row
    // leaves the viewport and cursor.viewport projects null — exercising
    // rehydrate's cursor.viewport else-branch (Client.zig:418-422), never
    // reached by the in-viewport fixtures (finding DF-4).
    try runClientFixtureOpts(
        "F10",
        10,
        3,
        "r0\r\nr1\r\nr2\r\nr3\r\nr4\r\nr5",
        .{ .scroll_top = true },
    );
}

test "client decode fidelity negative perturbation" {
    const alloc = testing.allocator;

    // F1: plain "ABC..." so row-0 cell-0 raw encodes a distinctive printable
    // codepoint ('A' = 0x41) whose LE byte pattern we can search for in the
    // framed payload — making the perturbation offset self-locating rather than
    // a magic constant that can silently drift onto an uncompared header field
    // (findings DF-2/ZM-3/C2-3).
    const cols: u16 = 10;
    const rows: u16 = 3;
    const bytes = "ABCDEFGHIJKLMNOPQR\r\nrow2\r\nrow3\r\nrow4\r\nrow5";

    // Reference RenderState (clean) for the comparison.
    var term_ref = try buildTerminal(alloc, cols, rows, bytes, .{});
    defer term_ref.deinit(alloc);
    var rs_ref: RenderStateCore = .empty;
    defer rs_ref.deinit(alloc);
    try rs_ref.update(alloc, &term_ref);

    const framed = try buildFramed(alloc, cols, rows, bytes, .{});
    defer alloc.free(framed);

    // Locate the first emitted cell's packed `raw` u64 by VALUE, not by a
    // hand-computed header size. Read the reference snapshot's row-0 cell-0 raw,
    // bitcast to its LE byte pattern, and find that 8-byte run in the framed
    // payload. (We search the whole frame; the codepoint cell raw is a unique,
    // non-zero, non-default pattern unlikely to collide with the header.)
    var ref_snap = try Snapshot.fromRenderState(alloc, &rs_ref);
    defer ref_snap.deinit(alloc);
    try testing.expect(ref_snap.row_data.len > 0);
    try testing.expect(ref_snap.row_data[0].cells.len > 0);
    const cell0_raw: u64 = @bitCast(ref_snap.row_data[0].cells[0].raw);
    var raw_le: [8]u8 = undefined;
    std.mem.writeInt(u64, &raw_le, cell0_raw, .little);

    const raw_off = std.mem.indexOf(u8, framed, &raw_le) orelse
        return error.CellRawNotFoundInFrame;
    // Flip the low byte of that u64 (the codepoint byte): decode stays
    // structurally valid and the divergence must land on a row cell's `raw`.
    framed[raw_off] +%= 1;

    // Feed the mutated frame through the SAME path.
    var client = try Client.init(alloc, .{});
    defer client.deinit();

    try client.reader.push(alloc, framed);

    // Drain frames; a structural corruption may surface as a decode error from
    // next() or handleFrame(). Track whether the frame decoded cleanly.
    const decoded = blk: {
        while (true) {
            const frame = (client.reader.next(alloc) catch break :blk false) orelse
                break;
            client.handleFrame(alloc, frame.tag, frame.payload) catch
                break :blk false;
        }
        break :blk true;
    };

    // Flipping a row cell's raw codepoint byte keeps the frame structurally
    // valid, so decode MUST succeed and the re-projected mirror MUST differ —
    // and specifically on a cell field at a concrete (x,y). Asserting the field
    // identity (not merely "some field differed") proves the perturbation
    // landed on the row-cell decode path, so the test cannot silently become
    // vacuous if the wire layout shifts.
    try testing.expect(decoded);
    var mirror_snap = try Snapshot.fromRenderState(alloc, &client.render_state);
    defer mirror_snap.deinit(alloc);
    var mm: Snapshot.Mismatch = .{};
    try testing.expect(!mirror_snap.eqlRenderState(&rs_ref, &mm));
    try testing.expect(std.mem.startsWith(u8, mm.field, "cell."));
    try testing.expect(mm.x != null);
    try testing.expect(mm.y != null);
}

test "client decode fidelity row.raw negative perturbation" {
    // Symmetric to the cell perturbation above, but targets the per-row
    // page.Row carried on the wire as of the row.raw fix. Proves (a) rehydrate
    // populates the mirror's row.raw from the wire (else the re-projected
    // mirror's row.raw would be a stale/zero default and this would fail to
    // pinpoint "row.raw"), and (b) eqlRenderState's new row.raw leg is
    // non-vacuous through the full client loop.
    const alloc = testing.allocator;
    const cols: u16 = 10;
    const rows: u16 = 3;
    const bytes = "ABCDEFGHIJKLMNOPQR\r\nrow2\r\nrow3\r\nrow4\r\nrow5";

    var term_ref = try buildTerminal(alloc, cols, rows, bytes, .{});
    defer term_ref.deinit(alloc);
    var rs_ref: RenderStateCore = .empty;
    defer rs_ref.deinit(alloc);
    try rs_ref.update(alloc, &term_ref);

    const framed = try buildFramed(alloc, cols, rows, bytes, .{});
    defer alloc.free(framed);

    // Self-locate row 0's raw u64 by VALUE in the framed bytes.
    var ref_snap = try Snapshot.fromRenderState(alloc, &rs_ref);
    defer ref_snap.deinit(alloc);
    try testing.expect(ref_snap.row_data.len > 0);

    const target_raw: u64 = @bitCast(ref_snap.row_data[0].raw);
    var raw_le: [8]u8 = undefined;
    std.mem.writeInt(u64, &raw_le, target_raw, .little);
    const raw_off = std.mem.indexOf(u8, framed, &raw_le) orelse
        return error.RowRawNotFoundInFrame;
    // Set the `wrap` flag bit (byte 4, bit 0 of the row.raw u64), which the
    // source row has clear. In the LE layout the low u32 is the `cells` Offset
    // and the flag bits begin at bit 32 (byte 4), so this is a pure-flag
    // perturbation that leaves the offset intact — the frame stays
    // structurally valid and decode must succeed.
    framed[raw_off + 4] |= 0x01;

    var client = try Client.init(alloc, .{});
    defer client.deinit();
    try client.reader.push(alloc, framed);
    const decoded = blk: {
        while (true) {
            const frame = (client.reader.next(alloc) catch break :blk false) orelse
                break;
            client.handleFrame(alloc, frame.tag, frame.payload) catch
                break :blk false;
        }
        break :blk true;
    };

    try testing.expect(decoded);
    var mirror_snap = try Snapshot.fromRenderState(alloc, &client.render_state);
    defer mirror_snap.deinit(alloc);
    var mm: Snapshot.Mismatch = .{};
    try testing.expect(!mirror_snap.eqlRenderState(&rs_ref, &mm));
    try testing.expectEqualStrings("row.raw", mm.field);
    try testing.expect(mm.y != null);
}

test "client decode fidelity repeated decode (arena reset / row reuse / shrink)" {
    // The rehydrate code has three branches that ONLY run on a second-or-later
    // decode into the same mirror: the per-row arena reset(.retain_capacity)
    // REUSE branch (Client.zig:478), the row-SHRINK promote+deinit branch
    // (Client.zig:448-459), and prior-row carry-over on GROW. A single decode
    // per fresh Client never exercises any of them. Feed several GridFrames of
    // varying row counts (and styled/grapheme content) into ONE Client under
    // testing.allocator (which fails on leak / double-free), then assert
    // fidelity after the FINAL decode — proving the highlights/arena reuse path
    // does not alias or corrupt across frames (findings ZM-2; regression guard
    // for the highlights .empty reset fix, DF-1/ZM-1/C2-1).
    const alloc = testing.allocator;

    const Frame = struct {
        cols: u16,
        rows: u16,
        bytes: []const u8,
    };
    // Order matters: each transition hits a distinct rehydrate branch.
    //   F5(2 rows, wide/grapheme)  -> seeds populated arena-backed rows
    //   F2(2 rows, SGR styles)     -> row REUSE + arena reset on same row count
    //   1 row                      -> row SHRINK (deinit dropped row arena/cells)
    //   F7(5 rows, alt-screen)     -> row GROW + reuse of carried rows
    const frames = [_]Frame{
        .{ .cols = 12, .rows = 2, .bytes = "\xe4\xbd\xa0\xe5\xa5\xbd!\r\ne\u{0301}\u{1f468}\u{200d}\u{1f469}" },
        .{ .cols = 24, .rows = 2, .bytes = "\x1b[31mRED\x1b[0m \x1b[38;5;208m256\x1b[0m \x1b[1;3;4;9mBISU\x1b[0m" },
        .{ .cols = 8, .rows = 1, .bytes = "tiny" },
        .{ .cols = 20, .rows = 5, .bytes = "primary text\r\n\x1b[?1049h\x1b[2J\x1b[H+-----+\r\n|  X  |\r\n+-----+" },
    };

    var client = try Client.init(alloc, .{});
    defer client.deinit();

    inline for (frames) |f| {
        const framed = try buildFramed(alloc, f.cols, f.rows, f.bytes, .{});
        defer alloc.free(framed);
        try client.reader.push(alloc, framed);
        while (try client.reader.next(alloc)) |frame| {
            try client.handleFrame(alloc, frame.tag, frame.payload);
        }
    }

    // Independent reference for the FINAL frame; the mirror must match it
    // exactly despite all the in-place row reuse/shrink/grow that preceded it.
    const last = frames[frames.len - 1];
    var term_ref = try buildTerminal(alloc, last.cols, last.rows, last.bytes, .{});
    defer term_ref.deinit(alloc);
    var rs_ref: RenderStateCore = .empty;
    defer rs_ref.deinit(alloc);
    try rs_ref.update(alloc, &term_ref);

    var mirror_snap = try Snapshot.fromRenderState(alloc, &client.render_state);
    defer mirror_snap.deinit(alloc);
    var mm: Snapshot.Mismatch = .{};
    if (!mirror_snap.eqlRenderState(&rs_ref, &mm)) {
        std.debug.print(
            "\n[client difftest:repeated] mismatch after final decode: field='{s}'",
            .{mm.field},
        );
        if (mm.y) |y| std.debug.print(" y={d}", .{y});
        if (mm.x) |x| std.debug.print(" x={d}", .{x});
        std.debug.print("\n", .{});
        return error.CellFidelityMismatch;
    }
    try assertRawStyleFidelity("repeated", &client.render_state, &rs_ref);
}

// =============================================================================
// Lifecycle / concurrency regression tests (workstream B-lifecycle).
//
// These cover the file-descriptor accounting (#1: the quit-pipe write-end leak)
// and the forced-Attach-failure unwind (#2: no live thread / no double-close /
// no fd leak on the error path). They drive the REAL connect/spawn lifecycle
// (`Client.connectAndAttach` + `Client.threadExit` + `Client.ThreadData.deinit`)
// against a minimal in-process AF_UNIX accept loop — no Server, no renderer
// state, no running xev loop. The xev loop is built (not run): `sendFrameRaw`
// only ENQUEUES a write completion onto it, so the Attach bytes need never be
// flushed for the lifecycle accounting to be exercised.
// =============================================================================

/// A bare AF_UNIX listener + one-shot accept thread, on a unique /tmp path.
/// Mirrors the bind/listen in `src/host/Server.zig:238-269` but without the
/// session machinery: it exists only to make `connectUnix` succeed and to drain
/// whatever the client writes so the socket buffer never wedges.
const TestListener = struct {
    tmp: testing.TmpDir,
    path: []u8,
    listen_fd: posix.fd_t,
    accept_thread: ?std.Thread = null,
    /// The accepted connection fd, set by the accept thread. Read only after
    /// `join()`.
    accepted_fd: ?posix.fd_t = null,

    /// Optional capture sink. When set (via `startCapturing`), the accept
    /// thread APPENDS everything it reads from the connection into `capture`
    /// (instead of draining-and-discarding as `start`/`acceptOne` do), so a
    /// test can decode the exact bytes the client wrote on the wire. Only the
    /// accept thread mutates `capture` (until joined), and tests read it only
    /// AFTER `joinAccept`, so no lock is needed — `joinAccept`'s thread join
    /// is the happens-before that publishes the buffer to the test thread.
    /// The allocator is stored so the accept thread can grow the buffer.
    capture: ?*std.ArrayList(u8) = null,
    capture_alloc: std.mem.Allocator = undefined,

    fn init(alloc: std.mem.Allocator) !TestListener {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
        defer alloc.free(dir_path);
        const path = try std.fmt.allocPrint(alloc, "{s}/c.sock", .{dir_path});
        errdefer alloc.free(path);

        const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        errdefer posix.close(fd);
        posix.unlink(path) catch {};

        var addr: posix.sockaddr.un = undefined;
        addr.family = posix.AF.UNIX;
        if (path.len >= addr.path.len) return error.PathTooLong;
        @memcpy(addr.path[0..path.len], path);
        addr.path[path.len] = 0;
        try posix.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));
        try posix.listen(fd, 1);

        return .{ .tmp = tmp, .path = path, .listen_fd = fd };
    }

    /// Spawn a background thread that accepts ONE connection and drains it
    /// until EOF (so the client's queued Attach write never blocks). The
    /// accepted fd is closed by `deinit` after `join`.
    fn start(self: *TestListener) !void {
        self.accept_thread = try std.Thread.spawn(.{}, acceptOne, .{self});
    }

    /// Like `start`, but the accept thread CAPTURES every byte it reads into
    /// `sink` (until the client closes its end / EOF) so the test can decode
    /// the exact frames the client put on the wire. `sink` must outlive the
    /// listener and be read only after `joinAccept`. Used by the Resize
    /// wire-fidelity test (finding #5) to recover the Resize frame the real
    /// `Client.resize` -> `sendFrame` path emitted.
    fn startCapturing(
        self: *TestListener,
        alloc: std.mem.Allocator,
        sink: *std.ArrayList(u8),
    ) !void {
        self.capture = sink;
        self.capture_alloc = alloc;
        self.accept_thread = try std.Thread.spawn(.{}, acceptOne, .{self});
    }

    fn acceptOne(self: *TestListener) void {
        const conn = posix.accept(self.listen_fd, null, null, 0) catch return;
        var buf: [256]u8 = undefined;
        // Drain until the client closes its end (EOF) or errors. In capture
        // mode, append each chunk to the sink; on append OOM we stop capturing
        // but keep draining so the client write side never wedges (the test
        // then fails when it cannot find the expected frame).
        while (true) {
            const n = posix.read(conn, &buf) catch break;
            if (n == 0) break;
            if (self.capture) |sink| {
                sink.appendSlice(self.capture_alloc, buf[0..n]) catch {
                    self.capture = null;
                };
            }
        }
        // Close OUR side here (not in deinit) so that, once the accept thread
        // is joined, the listener contributes a STABLE fd count (just
        // listen_fd) to the fd-leak probe — the per-connection fd is a harness
        // artifact, not part of the client lifecycle under test.
        posix.close(conn);
    }

    /// Join the one-shot accept thread. After this returns the listener holds
    /// only `listen_fd` open (the accepted connection has been closed), so the
    /// fd-count probe sees a stable listener contribution.
    fn joinAccept(self: *TestListener) void {
        if (self.accept_thread) |t| {
            t.join();
            self.accept_thread = null;
        }
    }

    fn deinit(self: *TestListener, alloc: std.mem.Allocator) void {
        self.joinAccept();
        posix.close(self.listen_fd);
        alloc.free(self.path);
        self.tmp.cleanup();
    }
};

/// Count currently-open file descriptors in `[0, limit)` by probing each with
/// the raw `fcntl(F.GETFD)` syscall (the same liveness probe concept used in
/// `pty.zig:156` / `Command.zig:398`): a live fd returns the flags (>= 0), a
/// closed one returns -1 with EBADF. We call the raw syscall rather than
/// `std.posix.fcntl` because the latter treats EBADF as `unreachable` (it is
/// for normal callers, but EBADF is exactly the expected "fd is closed" signal
/// here). The absolute count is uninteresting; only the DELTA across a
/// lifecycle cycle matters, so a fixed small range is sufficient (the lifecycle
/// opens a socket + a pipe pair, all low-numbered).
fn countOpenFds(limit: posix.fd_t) usize {
    var count: usize = 0;
    var fd: posix.fd_t = 0;
    while (fd < limit) : (fd += 1) {
        const rc = std.c.fcntl(fd, posix.F.GETFD, @as(c_int, 0));
        if (rc >= 0) count += 1;
    }
    return count;
}

const FD_PROBE_LIMIT: posix.fd_t = 256;

test "client lifecycle T1 threadEnter->threadExit leaks no fd" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = testing.allocator;

    var listener = try TestListener.init(alloc);
    defer listener.deinit(alloc);
    try listener.start();

    // Build (do NOT run) a real xev loop; sendFrameRaw only enqueues onto it.
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var client = try Client.init(alloc, .{ .socket_path = listener.path });
    defer client.deinit();

    // A stack ThreadData slot for the lifecycle; only `alloc` + `backend` are
    // touched by threadExit / ThreadData.deinit (the rest of Termio.ThreadData
    // is never read on the teardown path).
    var td: termio.Termio.ThreadData = undefined;
    td.alloc = alloc;
    td.loop = &loop;

    // The fd baseline must be taken AFTER the listener + loop are established
    // (those fds persist across the cycle) and BEFORE the lifecycle opens its
    // own socket/pipe — so the delta isolates exactly the lifecycle's fds.
    const before = countOpenFds(FD_PROBE_LIMIT);

    // Full connect -> Attach -> spawn read thread.
    td.backend = .{ .client = undefined };
    try client.connectAndAttach(alloc, &loop, &td.backend.client, undefined);

    // Full teardown: write quit byte + join read thread + close socket fd
    // (threadExit), then close pipe[1] + deinit pools + stream (ThreadData
    // .deinit). The read thread closes pipe[0] on exit.
    client.threadExit(&td);
    td.backend.deinit(alloc);

    // The client has now closed its socket end, so the accept thread reads EOF,
    // closes its connection fd, and exits. Join it before counting so the
    // listener's per-connection fd (a harness artifact) is gone and the
    // listener contributes the same single `listen_fd` it did at `before`.
    listener.joinAccept();

    const after = countOpenFds(FD_PROBE_LIMIT);

    // No net fd change: socket fd, quit-pipe read end (pipe[0]) AND write end
    // (pipe[1], the #1 fix) all closed exactly once. A re-introduced
    // read_thread_pipe / socket / pipe[0] leak surfaces here as a positive
    // delta.
    try testing.expectEqual(before, after);
}

test "client lifecycle T2 forced connect failure unwinds cleanly (earliest step)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = testing.allocator;

    // Point at a socket path that cannot connect (no listener bound there) so
    // `connectUnix` — the FIRST fallible lifecycle step — fails. This drives
    // the earliest error-unwind point: the fd/pipe/stream/pool errdefers must
    // NOT have run anything (connect failed before any of them armed) and, in
    // particular, NO read thread was spawned (the spawn is the LAST step).
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);
    const bad_path = try std.fmt.allocPrint(alloc, "{s}/nope.sock", .{dir_path});
    defer alloc.free(bad_path);

    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var client = try Client.init(alloc, .{ .socket_path = bad_path });
    defer client.deinit();

    var td: termio.Termio.ThreadData = undefined;
    td.alloc = alloc;
    td.loop = &loop;

    const before = countOpenFds(FD_PROBE_LIMIT);

    // The Attach lifecycle MUST fail (connect to a nonexistent socket).
    td.backend = .{ .client = undefined };
    const result = client.connectAndAttach(alloc, &loop, &td.backend.client, undefined);
    try testing.expectError(error.FileNotFound, result);

    // No fd leaked on the error path: connectUnix's own errdefer closed the
    // socket it opened, and no pipe/stream/thread was created. (A double-close
    // would instead surface as a later EBADF, and running under
    // testing.allocator catches any pool double-free / leak.)
    const after = countOpenFds(FD_PROBE_LIMIT);
    try testing.expectEqual(before, after);

    // NO read thread was spawned, so there is nothing to join and no teardown
    // is required — proving the "no live, unjoined thread on the error path"
    // invariant (#2). We deliberately do NOT call threadExit/ThreadData.deinit:
    // the backend union was left `.client = undefined` (connectAndAttach
    // returned before installing it), and joining a never-spawned thread would
    // be UB. `client.deinit()` (deferred) frees only the decode-side mirror,
    // which the failed lifecycle never touched.
    //
    // This T2 case exercises only the EARLIEST unwind point (connect fails
    // before pipe/stream/pool are created). The post-pipe/pre-spawn unwind that
    // finding #2's reorder actually establishes — connect+pipe+stream succeed,
    // Attach send fails, every fd torn down with NO live thread — is exercised
    // by T3 below.
}

test "client lifecycle T3 forced Attach-send failure unwinds cleanly (finding #2)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = testing.allocator;

    // This is the regression test finding #2's reorder is actually about. Unlike
    // T2 (connect fails first, before any errdefer arms), here we let connect +
    // pipe + stream + pool-install all SUCCEED and force ONLY the Attach send to
    // fail. That drives the exact post-pipe/pre-spawn unwind #2 established:
    //
    //   * connectUnix (posix.socket/connect), internal_os.pipe (posix.pipe), and
    //     xev.Stream.initFd are all NON-allocating, so they complete normally.
    //   * The FIRST allocation on the path is `encodeFrame(alloc, .attach, ...)`
    //     inside sendFrameRaw (Client.zig). connectAndAttach already takes `alloc`
    //     as its first parameter and threads that SAME `alloc` into sendFrameRaw,
    //     so a FailingAllocator with `fail_index = 0` makes the Attach send — and
    //     nothing before it — fail. No signature change required.
    //
    // The invariants under test (all from finding #2):
    //   * NO read thread is live during teardown: the spawn is the LAST step and
    //     is never reached, so there is nothing to join and no fd/stream is torn
    //     down out from under a running thread.
    //   * Every fd opened (socket, pipe[0], pipe[1]) is closed EXACTLY once by
    //     the fd/pipe/stream errdefers (a double-close would surface as a later
    //     EBADF and perturb the fd count; a missed close as a positive delta).
    //   * The write-pool errdefer (the OOM-leak half of #2) runs and frees the
    //     pools, and `testing.allocator` (the FailingAllocator's backing) would
    //     flag any pool double-free or leak.
    var listener = try TestListener.init(alloc);
    defer listener.deinit(alloc);
    try listener.start();

    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var client = try Client.init(alloc, .{ .socket_path = listener.path });
    defer client.deinit();

    var td: termio.Termio.ThreadData = undefined;
    td.alloc = alloc;
    td.loop = &loop;

    // Fail the very first allocation (the Attach encodeFrame). The backing
    // allocator is testing.allocator, so connect/pipe/stream — which allocate
    // nothing — proceed, and the pool/leak accounting is still checked.
    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    const failing_alloc = failing.allocator();

    // Baseline AFTER listener + loop, BEFORE the lifecycle opens its socket/pipe.
    const before = countOpenFds(FD_PROBE_LIMIT);

    // connect + pipe + stream + pool-install succeed; the Attach send fails.
    td.backend = .{ .client = undefined };
    const result = client.connectAndAttach(failing_alloc, &loop, &td.backend.client, undefined);
    try testing.expectError(error.OutOfMemory, result);

    // The failure was actually induced by the injected allocator (not some
    // unrelated error), and it landed on the VERY FIRST allocation — i.e. the
    // Attach encodeFrame, since connect/pipe/stream allocate nothing. (On an
    // induced failure FailingAllocator returns null WITHOUT bumping alloc_index,
    // so alloc_index stays at the fail_index of 0.)
    try testing.expect(failing.has_induced_failure);
    try testing.expectEqual(@as(usize, 0), failing.alloc_index);

    // The errdefers ran on a real connection: closing the client's socket end
    // makes the accept thread read EOF and close its per-connection fd. Join it
    // (as in T1) so the listener contributes the same single listen_fd as at
    // `before`, isolating the lifecycle's own fds in the delta.
    listener.joinAccept();

    const after = countOpenFds(FD_PROBE_LIMIT);

    // No fd leaked and none double-closed: socket, pipe[0] and pipe[1] (the #1
    // fix) all closed exactly once by connectAndAttach's errdefers, with no live
    // thread involved. A regression in the errdefer chain (a missed close, a
    // double-close, or — if the spawn were moved back ahead of the Attach send —
    // a live thread torn down here) surfaces as a non-zero delta or an EBADF.
    try testing.expectEqual(before, after);

    // As in T2: connectAndAttach returned before installing a usable backend
    // (`.client` is still effectively torn down) and spawned no thread, so we
    // deliberately do NOT call threadExit/ThreadData.deinit (no thread to join,
    // and the pools were already freed by the pool errdefer). `client.deinit()`
    // (deferred) frees only the decode-side mirror.
}

// --- handleFrame arm coverage (finding #6) ---
//
// The .mode_frame / .attached / .child_exited arms of handleFrame were never
// exercised by any test. These drive each arm directly via the same
// encode-payload-then-handleFrame pattern the decode-fidelity fixtures use:
// build the protocol struct, encode its per-frame payload, feed it straight to
// handleFrame(tag, payload), and assert the resulting mirror state. No socket,
// no thread — pure handleFrame calls under self.mutex, on testing.allocator so
// any leak / double-free fails the test.

test "client handleFrame .mode_frame replaces the mode mirror" {
    const alloc = testing.allocator;
    var client = try Client.init(alloc, .{});
    defer client.deinit();

    // The mirror starts at the default ModeFrame (session_id 0, all flags off).
    try testing.expectEqual(@as(u64, 0), client.mode.session_id);
    try testing.expect(!client.mode.bracketed_paste);
    try testing.expect(!client.mode.alt_screen_active);

    const mf: protocol.ModeFrame = .{
        .session_id = 7,
        .bracketed_paste = true,
        .cursor_keys = true,
        .mouse_event = 2,
        .mouse_format = 1,
        .mouse_shift_capture = 2,
        .modify_other_keys_2 = true,
        .kitty_flags = 3,
        .alt_screen_active = true,
    };
    const p = try mf.encode(alloc);
    defer alloc.free(p);
    try client.handleFrame(alloc, .mode_frame, p);

    // Wholesale replace: every field matches the non-default frame.
    try testing.expectEqual(@as(u64, 7), client.mode.session_id);
    try testing.expect(client.mode.bracketed_paste);
    try testing.expect(client.mode.cursor_keys);
    try testing.expectEqual(@as(u8, 2), client.mode.mouse_event);
    try testing.expectEqual(@as(u8, 1), client.mode.mouse_format);
    try testing.expectEqual(@as(u8, 2), client.mode.mouse_shift_capture);
    try testing.expect(client.mode.modify_other_keys_2);
    try testing.expectEqual(@as(u8, 3), client.mode.kitty_flags);
    try testing.expect(client.mode.alt_screen_active);
}

test "client handleFrame .attached sets session_id" {
    const alloc = testing.allocator;
    var client = try Client.init(alloc, .{});
    defer client.deinit();

    // session_id starts at 0 (the unlocked atomic the IO thread reads).
    try testing.expectEqual(@as(u64, 0), client.session_id.load(.acquire));

    const at: protocol.Attached = .{ .session_id = 42, .cols = 80, .rows = 24 };
    const p = try at.encode(alloc);
    defer alloc.free(p);
    try client.handleFrame(alloc, .attached, p);

    try testing.expectEqual(@as(u64, 42), client.session_id.load(.acquire));
}

test "client handleFrame .child_exited records exit_code + runtime_ms" {
    const alloc = testing.allocator;
    var client = try Client.init(alloc, .{});
    defer client.deinit();

    // No child has exited yet.
    try testing.expect(client.child_exited == null);

    const ce: protocol.ChildExited = .{
        .session_id = 1,
        .exit_code = 137,
        .runtime_ms = 12345,
    };
    const p = try ce.encode(alloc);
    defer alloc.free(p);
    try client.handleFrame(alloc, .child_exited, p);

    // The arm maps only exit_code + runtime_ms onto Client.ChildExited; it
    // intentionally drops session_id, so we assert exactly those two fields.
    try testing.expect(client.child_exited != null);
    try testing.expectEqual(@as(u32, 137), client.child_exited.?.exit_code);
    try testing.expectEqual(@as(u64, 12345), client.child_exited.?.runtime_ms);
}

// --- Slice 6: SurfaceEvent re-inject into the surface mailbox ---
//
// handleFrame's .surface_event arm DESERIALIZES a forwarded apprt.surface.Message
// and re-injects it into the Client's captured surface_mailbox (the same field
// Slice 5d captured for child_exited). The GUI's existing Surface drain then
// handles it identically to .exec. These tests build a CAPTURING mailbox (a real
// App.Mailbox.Queue + a zero-size headless apprt.App), drive handleFrame with an
// encoded surface_event payload, and assert the exact apprt.surface.Message that
// lands in the queue. A null mailbox (the decode-fidelity default) must be a
// no-op — proven by the last case.

/// Build a capturing surface mailbox over a freshly-created queue. The `surface`
/// pointer is only STORED by the mailbox/Message (never dereferenced by `push`),
/// so a bogus aligned sentinel is safe. Caller owns the returned queue (destroy
/// it with `q.destroy(alloc)`).
fn captureMailbox(alloc: std.mem.Allocator, rt_app: *apprt.App) !struct {
    queue: *App.Mailbox.Queue,
    mailbox: apprt.surface.Mailbox,
} {
    const q = try App.Mailbox.Queue.create(alloc);
    return .{
        .queue = q,
        .mailbox = .{
            // Never dereferenced by push (it only stores the pointer in the
            // surface_message); a recognizable aligned sentinel stands in for a
            // real *Surface in this socket-/surface-free unit test.
            .surface = @ptrFromInt(@alignOf(@import("../Surface.zig"))),
            .app = .{ .rt_app = rt_app, .mailbox = q },
        },
    };
}

/// Drain exactly one surface_message from the capture queue, asserting one is
/// present, and return the apprt.surface.Message.
fn drainOne(q: *App.Mailbox.Queue) !apprt.surface.Message {
    const msg = q.pop() orelse return error.NoMessage;
    try testing.expect(msg == .surface_message);
    return msg.surface_message.message;
}

test "client handleFrame .surface_event re-injects simple variants into the mailbox" {
    const alloc = testing.allocator;
    var rt_app: apprt.App = .{};
    var client = try Client.init(alloc, .{});
    defer client.deinit();

    const cap = try captureMailbox(alloc, &rt_app);
    defer cap.queue.destroy(alloc);
    client.surface_mailbox = cap.mailbox;

    // Helper: encode a SurfaceEvent from an apprt.surface.Message, feed it through
    // handleFrame, and return the re-injected message drained from the queue.
    const H = struct {
        fn run(
            a: std.mem.Allocator,
            c: *Client,
            q: *App.Mailbox.Queue,
            src: apprt.surface.Message,
        ) !apprt.surface.Message {
            const ev = try protocol.SurfaceEvent.fromMessage(99, &src);
            const p = try ev.encode(a);
            defer a.free(p);
            try c.handleFrame(a, .surface_event, p);
            return try drainOne(q);
        }
    };

    // ring_bell (void).
    {
        const got = try H.run(alloc, &client, cap.queue, .{ .ring_bell = {} });
        try testing.expect(got == .ring_bell);
    }

    // password_input (bool).
    {
        const got = try H.run(alloc, &client, cap.queue, .{ .password_input = true });
        try testing.expect(got == .password_input);
        try testing.expectEqual(true, got.password_input);
    }

    // set_mouse_shape (enum).
    {
        const got = try H.run(alloc, &client, cap.queue, .{ .set_mouse_shape = .text });
        try testing.expect(got == .set_mouse_shape);
        try testing.expectEqual(terminalpkg.MouseShape.text, got.set_mouse_shape);
    }

    // set_title (fixed buffer).
    {
        var title: [256]u8 = [_]u8{0} ** 256;
        @memcpy(title[0..4], "tab1");
        const got = try H.run(alloc, &client, cap.queue, .{ .set_title = title });
        try testing.expect(got == .set_title);
        try testing.expectEqualSlices(u8, &title, &got.set_title);
    }

    // color_change (Target + RGB).
    {
        const rgb: terminalpkg.color.RGB = .{ .r = 1, .g = 2, .b = 3 };
        const got = try H.run(alloc, &client, cap.queue, .{ .color_change = .{
            .target = .{ .dynamic = .foreground },
            .color = rgb,
        } });
        try testing.expect(got == .color_change);
        try testing.expect(rgb.eql(got.color_change.color));
        try testing.expectEqual(
            @as(terminalpkg.osc.color.Target, .{ .dynamic = .foreground }),
            got.color_change.target,
        );
    }
}

test "client handleFrame .surface_event re-injects a pwd_change WriteReq into the mailbox" {
    const alloc = testing.allocator;
    var rt_app: apprt.App = .{};
    var client = try Client.init(alloc, .{});
    defer client.deinit();

    const cap = try captureMailbox(alloc, &rt_app);
    defer cap.queue.destroy(alloc);
    client.surface_mailbox = cap.mailbox;

    const pwd = "/Users/ramon/git/ghostty-phase2b";
    const src_req = try apprt.surface.Message.WriteReq.init(alloc, @as([]const u8, pwd));
    defer src_req.deinit();
    const src = apprt.surface.Message{ .pwd_change = src_req };

    const ev = try protocol.SurfaceEvent.fromMessage(99, &src);
    const p = try ev.encode(alloc);
    defer alloc.free(p);
    try client.handleFrame(alloc, .surface_event, p);

    // The re-injected message carries a reconstructed WriteReq whose bytes equal
    // the source pwd. The WriteReq the surface drain receives is owned by it; in
    // this test we own it and must free it (a `<=255` pwd is a `.small`, so deinit
    // is a no-op, but call it for symmetry with the real drain contract).
    var got = try drainOne(cap.queue);
    try testing.expect(got == .pwd_change);
    try testing.expectEqualStrings(pwd, got.pwd_change.slice());
    got.pwd_change.deinit();
}

test "client handleFrame .surface_event with null mailbox is a no-op" {
    // The decode-fidelity default: no surface_mailbox captured (threadEnter
    // bypassed). The arm must still DECODE (and free any owned bytes) without
    // pushing anywhere — no crash, no leak (testing.allocator catches a leak).
    const alloc = testing.allocator;
    var client = try Client.init(alloc, .{});
    defer client.deinit();
    try testing.expect(client.surface_mailbox == null);

    // A WriteReq-bearing variant exercises the decode allocation + deinit path
    // under the null-mailbox branch (no toMessage call -> the decoded bytes must
    // be freed by the arm's `ev.deinit`).
    const data = "x" ** 600; // forces the .alloc decode path
    const req = try apprt.surface.Message.WriteReq.init(alloc, @as([]const u8, data));
    defer req.deinit();
    const src = apprt.surface.Message{ .pwd_change = req };
    const ev = try protocol.SurfaceEvent.fromMessage(99, &src);
    const p = try ev.encode(alloc);
    defer alloc.free(p);
    try client.handleFrame(alloc, .surface_event, p);
    // No assertion beyond "did not crash / did not leak" — the testing allocator
    // fails the test on any leak from the decoded-but-undelivered bytes.
}

// --- Resize wire fidelity (finding #5) ---
//
// Finding #5 added the real `Client.resize`, whose load-bearing decision (the
// CAUTION block at Client.zig:362-368) is that `screen_w/screen_h` carry the
// FULL padded `size.screen`, NOT the padding-stripped `size.terminal()`: the
// host rebuilds a `renderer.Size` by setting `.screen = {screen_w,screen_h}`
// and re-deriving grid/terminal via `subPadding`, so sending the already-
// stripped terminal size would subtract padding TWICE. That decision was
// verified only by code reading. The lifecycle tests (T1/T3) exercise the send
// MECHANISM via the Attach frame, but nothing exercised the Resize PAYLOAD
// construction or the screen-vs-terminal choice end-to-end.
//
// This test closes that gap with a real round-trip through the actual
// `Client.resize` -> `sendFrame` -> `sendFrameRaw` -> xev write-stream path:
//
//   1. A capturing TestListener accepts the client connection and records every
//      wire byte the client emits.
//   2. `connectAndAttach` connects + enqueues the Attach frame; we then call the
//      REAL `Client.resize(td, size)` with a size that has NONZERO padding (so
//      screen != terminal() and the double-subtraction bug would be visible).
//   3. We pump the (un-running) xev loop with `.no_wait` to flush the enqueued
//      writes to the socket, then tear the client down so the listener reads EOF.
//   4. We parse the captured bytes with a real `FrameReader`, find the `.resize`
//      frame, decode it, and reconstruct a `renderer.Size` EXACTLY as the host
//      does in Server.zig:555-564.
//   5. We assert the reconstructed Size equals the source Size — screen, cell,
//      padding all round-trip — AND that the reconstructed `terminal()` matches
//      the source `terminal()`. The latter is the specific guard against the
//      double-padding-subtraction regression: with nonzero padding,
//      `screen != terminal()`, so had `Client.resize` put `terminal()` into
//      screen_w/h the reconstructed terminal() would come out too small by the
//      padding and this assertion would fail.
test "client resize emits a Resize frame whose host reconstruction == source Size" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = testing.allocator;

    var listener = try TestListener.init(alloc);
    defer listener.deinit(alloc);

    // Capture sink for the wire bytes; read only after joinAccept.
    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(alloc);
    try listener.startCapturing(alloc, &captured);

    // Build (do NOT run to completion) a real xev loop; sendFrameRaw enqueues
    // onto it and we flush with .no_wait below.
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var client = try Client.init(alloc, .{ .socket_path = listener.path });
    defer client.deinit();

    // Force a known, non-zero session id so the wire payload is non-default and
    // we can additionally assert it round-trips. handleFrame's .attached arm is
    // the production path; here we set it directly (no host to send Attached).
    client.session_id.store(99, .release);

    var td: termio.Termio.ThreadData = undefined;
    td.alloc = alloc;
    td.loop = &loop;

    // Full connect -> Attach-enqueue -> spawn read thread (the real lifecycle).
    td.backend = .{ .client = undefined };
    try client.connectAndAttach(alloc, &loop, &td.backend.client, undefined);

    // The SOURCE size: NONZERO padding on every side so screen != terminal().
    // Cell + screen chosen so grid divides exactly (cols/rows are independently
    // carried on the wire, but keeping them exact mirrors a real resize).
    //   screen 824x424, padding l/r/t/b = 4/8/12/16, cell 8x16
    //   terminal = {824-(4+8), 424-(12+16)} = {812, 396}
    const source: renderer.Size = .{
        .screen = .{ .width = 824, .height = 424 },
        .cell = .{ .width = 8, .height = 16 },
        .padding = .{ .left = 4, .right = 8, .top = 12, .bottom = 16 },
    };
    // Sanity: the fixture must actually have screen != terminal(), else the
    // double-subtraction guard below would be vacuous.
    try testing.expect(!source.screen.equals(source.terminal()));

    // The REAL send path under test.
    try client.resize(&td, source);

    // Flush the enqueued writes (Attach + Resize) to the socket. The completion
    // is async; .no_wait runs ready completions without blocking. Pump a few
    // times to cover both frames' write completions.
    var pumps: usize = 0;
    while (pumps < 16) : (pumps += 1) try loop.run(.no_wait);

    // Tear down the client: closes the socket so the capture thread reads EOF
    // and the (now-drained) wire bytes are published to us on join.
    client.threadExit(&td);
    td.backend.deinit(alloc);
    listener.joinAccept();

    // Parse the captured wire bytes and find the Resize frame.
    var reader: protocol.FrameReader = .{};
    defer reader.deinit(alloc);
    try reader.push(alloc, captured.items);

    var got: ?protocol.Resize = null;
    while (try reader.next(alloc)) |frame| {
        if (frame.tag == .resize) {
            got = try protocol.Resize.decode(alloc, frame.payload);
            break;
        }
    }
    try testing.expect(got != null);
    const r = got.?;

    // The non-screen scalars round-trip verbatim.
    try testing.expectEqual(@as(u64, 99), r.session_id);
    try testing.expectEqual(source.grid().columns, r.cols);
    try testing.expectEqual(source.grid().rows, r.rows);
    try testing.expectEqual(source.cell.width, r.cell_width);
    try testing.expectEqual(source.cell.height, r.cell_height);
    try testing.expectEqual(source.padding.left, r.padding_l);
    try testing.expectEqual(source.padding.right, r.padding_r);
    try testing.expectEqual(source.padding.top, r.padding_t);
    try testing.expectEqual(source.padding.bottom, r.padding_b);

    // THE load-bearing field: screen_w/h must be the FULL padded screen.
    try testing.expectEqual(source.screen.width, r.screen_w);
    try testing.expectEqual(source.screen.height, r.screen_h);

    // Reconstruct a renderer.Size EXACTLY as the host does (Server.zig:555-564).
    const reconstructed: renderer.Size = .{
        .screen = .{ .width = r.screen_w, .height = r.screen_h },
        .cell = .{ .width = r.cell_width, .height = r.cell_height },
        .padding = .{
            .left = r.padding_l,
            .right = r.padding_r,
            .top = r.padding_t,
            .bottom = r.padding_b,
        },
    };

    // Full Size identity: screen, cell, padding all match the source.
    try testing.expect(reconstructed.screen.equals(source.screen));
    try testing.expectEqual(source.cell.width, reconstructed.cell.width);
    try testing.expectEqual(source.cell.height, reconstructed.cell.height);
    try testing.expect(reconstructed.padding.eql(source.padding));

    // The specific double-padding-subtraction guard: the host re-derives
    // terminal() via subPadding, so it must equal the SOURCE terminal(). Had
    // Client.resize sent terminal() into screen_w/h, this reconstructed
    // terminal() would be short by one padding span on each axis and fail.
    try testing.expect(reconstructed.terminal().equals(source.terminal()));
    // And the re-derived grid matches what the client put in cols/rows.
    try testing.expectEqual(r.cols, reconstructed.grid().columns);
    try testing.expectEqual(r.rows, reconstructed.grid().rows);
}

test "client scrollViewport/jumpToPrompt SEND frames (Slice 7), not a local scroll" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = testing.allocator;

    var listener = try TestListener.init(alloc);
    defer listener.deinit(alloc);

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(alloc);
    try listener.startCapturing(alloc, &captured);

    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var client = try Client.init(alloc, .{ .socket_path = listener.path });
    defer client.deinit();
    client.session_id.store(99, .release);

    var td: termio.Termio.ThreadData = undefined;
    td.alloc = alloc;
    td.loop = &loop;
    td.backend = .{ .client = undefined };
    try client.connectAndAttach(alloc, &loop, &td.backend.client, undefined);

    // The real send paths under test: a delta scroll, a top scroll, a bottom
    // scroll, and a prompt jump. Each must produce a wire frame (the .client
    // backend NEVER touches a local terminal — there is none in this fixture).
    try client.scrollViewport(&td, .{ .delta = -7 });
    try client.scrollViewport(&td, .top);
    try client.scrollViewport(&td, .bottom);
    try client.jumpToPrompt(&td, -3);

    var pumps: usize = 0;
    while (pumps < 16) : (pumps += 1) try loop.run(.no_wait);

    client.threadExit(&td);
    td.backend.deinit(alloc);
    listener.joinAccept();

    // Parse the wire: collect the scroll_viewport + jump_to_prompt frames.
    var reader: protocol.FrameReader = .{};
    defer reader.deinit(alloc);
    try reader.push(alloc, captured.items);

    var scrolls: std.ArrayList(protocol.ScrollViewport) = .empty;
    defer scrolls.deinit(alloc);
    var jumps: std.ArrayList(protocol.JumpToPrompt) = .empty;
    defer jumps.deinit(alloc);
    while (try reader.next(alloc)) |frame| {
        switch (frame.tag) {
            .scroll_viewport => try scrolls.append(
                alloc,
                try protocol.ScrollViewport.decode(alloc, frame.payload),
            ),
            .jump_to_prompt => try jumps.append(
                alloc,
                try protocol.JumpToPrompt.decode(alloc, frame.payload),
            ),
            else => {},
        }
    }

    // Three scroll_viewport frames (delta/top/bottom), recovering the exact
    // union targets, all carrying the forced session id.
    try testing.expectEqual(@as(usize, 3), scrolls.items.len);
    for (scrolls.items) |s| try testing.expectEqual(@as(u64, 99), s.session_id);
    try testing.expectEqual(
        @as(terminalpkg.Terminal.ScrollViewport, .{ .delta = -7 }),
        scrolls.items[0].toTarget().?,
    );
    try testing.expectEqual(
        @as(terminalpkg.Terminal.ScrollViewport, .top),
        scrolls.items[1].toTarget().?,
    );
    try testing.expectEqual(
        @as(terminalpkg.Terminal.ScrollViewport, .bottom),
        scrolls.items[2].toTarget().?,
    );

    // One jump_to_prompt frame with the signed delta intact.
    try testing.expectEqual(@as(usize, 1), jumps.items.len);
    try testing.expectEqual(@as(u64, 99), jumps.items[0].session_id);
    try testing.expectEqual(@as(i64, -3), jumps.items[0].delta);
}

test "client vs exec: exec backend scrollViewport scrolls the LOCAL terminal (Slice 7, byte-for-byte path)" {
    const alloc = testing.allocator;

    // The .exec backend scroll must scroll the LOCAL terminal synchronously —
    // the pre-Slice-7 behavior. Build a real terminal with scrollback, wire a
    // minimal ThreadData carrying a renderer.State that points at it (exactly
    // what Exec.scrollViewport reaches through: td.renderer_state.{mutex,terminal}),
    // and assert the viewport moves.
    var term = try terminalpkg.Terminal.init(alloc, .{ .cols = 20, .rows = 10 });
    defer term.deinit(alloc);
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        var lb: [8]u8 = undefined;
        const line = try std.fmt.bufPrint(&lb, "L{d:0>2}", .{i});
        try term.printString(line);
        term.carriageReturn();
        try term.linefeed();
    }

    var mutex: std.Thread.Mutex = .{};
    var rstate: renderer.State = .{ .mutex = &mutex, .terminal = &term };

    var exec_backend: termio.Exec = undefined;
    var td: termio.Termio.ThreadData = undefined;
    td.alloc = alloc;
    td.renderer_state = &rstate;
    td.backend = .{ .exec = undefined };

    // Capture the viewport's top-left codepoint before/after a top scroll. At
    // the bottom the viewport shows the newest lines; after .top it shows the
    // oldest scrollback row. The top-left pin's row must change.
    const before = term.screens.active.pages.getTopLeft(.viewport);
    exec_backend.scrollViewport(&td, .top);
    const after_top = term.screens.active.pages.getTopLeft(.viewport);
    try testing.expect(!std.meta.eql(before, after_top));

    // And .bottom returns it to the active-area top (the pre-scroll viewport).
    exec_backend.scrollViewport(&td, .bottom);
    const after_bottom = term.screens.active.pages.getTopLeft(.viewport);
    try testing.expect(std.meta.eql(before, after_bottom));
    try testing.expect(!std.meta.eql(after_top, after_bottom));
}

// --- Slice 3b: host search highlights rehydrate into the client mirror ---
//
// The host's captureSnapshotLocked runs updateHighlightsFlattened on a real
// RenderState to turn search-match pin-ranges into row.highlights, then projects
// to a Snapshot. This test reproduces that exact projection (real
// updateHighlightsFlattened on a live RenderState), pushes the Snapshot through
// the wire (GridFrame.encode -> Client.handleFrame .grid_frame), and asserts the
// search highlights land in the client mirror's row.highlights with the same
// tag + range. This is the post-3a draw source the renderer reads, so it proves
// the end-to-end host-search -> wire -> mirror chain that gives .client sessions
// search highlights. A trailing ClearSearch-equivalent (a highlight-free frame)
// then confirms the mirror highlights are removed.
test "client rehydrates host search highlights" {
    const alloc = testing.allocator;

    const cols: u16 = 40;
    const rows: u16 = 5;

    // Live terminal with two "foo" occurrences on row 0.
    var term = try buildTerminal(alloc, cols, rows, "foo bar foo", .{});
    defer term.deinit(alloc);

    // Build a real RenderState and inject search-match highlights exactly like
    // the host's captureSnapshotLocked: one Flattened per "foo" (cols [0,2] and
    // [8,10]) applied with the search_match tag (0).
    var rs: RenderStateCore = .empty;
    defer rs.deinit(alloc);
    try rs.update(alloc, &term);

    var hl0 = try clientBuildRowHighlight(alloc, &term, 0, 0, 2);
    defer hl0.deinit(alloc);
    var hl1 = try clientBuildRowHighlight(alloc, &term, 0, 8, 10);
    defer hl1.deinit(alloc);
    try rs.updateHighlightsFlattened(alloc, 0, &.{ hl0, hl1 });

    var snap = try Snapshot.fromRenderState(alloc, &rs);
    defer snap.deinit(alloc);

    // Sanity: the host projection carried the highlights.
    var host_hl_count: usize = 0;
    for (snap.row_data) |row| host_hl_count += row.highlights.len;
    try testing.expectEqual(@as(usize, 2), host_hl_count);

    // Wire: GridFrame.encode -> Client.handleFrame .grid_frame -> mirror.
    var client = try Client.init(alloc, .{});
    defer client.deinit();

    {
        const gf: protocol.GridFrame = .{ .session_id = 1, .snapshot = snap };
        const payload = try gf.encode(alloc);
        defer alloc.free(payload);
        try client.handleFrame(alloc, .grid_frame, payload);
    }

    // The mirror's row 0 must carry both highlights (tag 0, the same ranges).
    {
        const mirror = client.render_state.row_data.slice();
        const hls = mirror.items(.highlights)[0];
        try testing.expectEqual(@as(usize, 2), hls.items.len);
        var saw_0 = false;
        var saw_8 = false;
        for (hls.items) |h| {
            try testing.expectEqual(@as(u8, 0), h.tag);
            if (h.range[0] == 0 and h.range[1] == 2) saw_0 = true;
            if (h.range[0] == 8 and h.range[1] == 10) saw_8 = true;
        }
        try testing.expect(saw_0 and saw_8);
    }

    // ClearSearch removal: a fresh frame with NO highlights (what the host ships
    // after clearSearch) must clear the mirror's row.highlights on reuse.
    {
        var rs2: RenderStateCore = .empty;
        defer rs2.deinit(alloc);
        try rs2.update(alloc, &term);
        var snap2 = try Snapshot.fromRenderState(alloc, &rs2);
        defer snap2.deinit(alloc);

        const gf2: protocol.GridFrame = .{ .session_id = 1, .snapshot = snap2 };
        const payload2 = try gf2.encode(alloc);
        defer alloc.free(payload2);
        try client.handleFrame(alloc, .grid_frame, payload2);

        const mirror = client.render_state.row_data.slice();
        for (mirror.items(.highlights)) |hls| {
            try testing.expectEqual(@as(usize, 0), hls.items.len);
        }
    }
}

/// Build a single-row `Flattened` covering active-screen row `y`, cols [x0,x1]
/// inclusive — the shape updateHighlightsFlattened consumes for a one-row match.
fn clientBuildRowHighlight(
    alloc: std.mem.Allocator,
    t: *terminalpkg.Terminal,
    y: u16,
    x0: u16,
    x1: u16,
) !terminalpkg.highlight.Flattened {
    const p = t.screens.active.pages.pin(.{ .active = .{ .x = x0, .y = y } }) orelse
        return error.NoPin;
    var chunks: std.MultiArrayList(terminalpkg.highlight.Flattened.Chunk) = .empty;
    errdefer chunks.deinit(alloc);
    try chunks.append(alloc, .{
        .node = p.node,
        .serial = p.node.serial,
        .start = p.y,
        .end = p.y + 1,
    });
    return .{ .chunks = chunks, .top_x = x0, .bot_x = x1 };
}

// --- Slice 3c: host-computed OSC8 link decode + GUI-side regex links ---

test "client decodes LinkFrame into the OSC8 link CellSet (Slice 3c)" {
    // The host computes OSC8 links (its pins are live) and ships the coordinate
    // set on a LinkFrame; the Client decodes it into `osc8_links`. Prove a
    // non-empty LinkFrame populates the right coords and an empty one clears it.
    const alloc = testing.allocator;

    var client = try Client.init(alloc, .{});
    defer client.deinit();

    // Non-empty: 4 contiguous cells (the "LINK" hyperlink shape from the host
    // hoverLink test).
    {
        const cells = [_]protocol.LinkFrame.Cell{
            .{ .x = 0, .y = 0 },
            .{ .x = 1, .y = 0 },
            .{ .x = 2, .y = 0 },
            .{ .x = 3, .y = 0 },
        };
        const lf: protocol.LinkFrame = .{ .session_id = 1, .cells = &cells };
        const framed = try protocol.encodeFrame(alloc, .link_frame, lf);
        defer alloc.free(framed);
        try client.reader.push(alloc, framed);
        while (try client.reader.next(alloc)) |frame| {
            try client.handleFrame(alloc, frame.tag, frame.payload);
        }
        try testing.expectEqual(@as(usize, 4), client.osc8_links.count());
        try testing.expect(client.osc8_links.contains(.{ .x = 0, .y = 0 }));
        try testing.expect(client.osc8_links.contains(.{ .x = 3, .y = 0 }));
        try testing.expect(!client.osc8_links.contains(.{ .x = 4, .y = 0 }));
    }

    // Empty LinkFrame clears the set (host sends empty on no-link / no-mods).
    {
        const lf: protocol.LinkFrame = .{ .session_id = 1, .cells = &.{} };
        const framed = try protocol.encodeFrame(alloc, .link_frame, lf);
        defer alloc.free(framed);
        try client.reader.push(alloc, framed);
        while (try client.reader.next(alloc)) |frame| {
            try client.handleFrame(alloc, frame.tag, frame.payload);
        }
        try testing.expectEqual(@as(usize, 0), client.osc8_links.count());
    }
}

test "client regex links match against the mirror cell text (Slice 3c)" {
    // Regex links stay GUI-side: Set.renderCellMap matches viewport CELL TEXT
    // (no pin/Terminal deref), so it works against the client mirror. Build a
    // mirror via the real decode pipeline (its pins are the poisoned sentinel),
    // then run renderCellMap against it and confirm the matches land — proving
    // the regex-stays-GUI-side claim end to end on a mirror.
    const alloc = testing.allocator;

    const cols: u16 = 10;
    const rows: u16 = 3;
    // Row 0: "1ABCD2EFGH"; row 1: "3IJKL" (same shape as link.zig's test).
    const bytes = "1ABCD2EFGH\r\n3IJKL";

    const framed = try buildFramed(alloc, cols, rows, bytes, .{});
    defer alloc.free(framed);

    var client = try Client.init(alloc, .{});
    defer client.deinit();
    try client.reader.push(alloc, framed);
    while (try client.reader.next(alloc)) |frame| {
        try client.handleFrame(alloc, frame.tag, frame.payload);
    }

    // The mirror's pins are the poisoned sentinel — renderCellMap must NOT
    // touch them (it reads cell text only). Confirm the hazard is present.
    {
        const pins = client.render_state.row_data.slice().items(.pin);
        for (pins) |p| {
            try testing.expectEqual(
                @as(usize, 0xdead_0000_dead_0000),
                @intFromPtr(p.node),
            );
        }
    }

    var set = try LinkSet.fromConfig(alloc, &.{
        .{ .regex = "AB", .action = .{ .open = {} }, .highlight = .{ .always = {} } },
        .{ .regex = "EF", .action = .{ .open = {} }, .highlight = .{ .always = {} } },
    });
    defer set.deinit(alloc);

    var result: render.RenderState.CellSet = .empty;
    defer result.deinit(alloc);
    // Run against the MIRROR (client.render_state), exactly as generic.zig:1341
    // does for both backends. No mouse point / no mods needed for `.always`.
    try set.renderCellMap(alloc, &result, &client.render_state, null, .{});

    // "AB" at cols 1-2 row 0; "EF" at cols 6-7 row 0.
    try testing.expect(result.contains(.{ .x = 1, .y = 0 }));
    try testing.expect(result.contains(.{ .x = 2, .y = 0 }));
    try testing.expect(!result.contains(.{ .x = 0, .y = 0 }));
    try testing.expect(result.contains(.{ .x = 6, .y = 0 }));
    try testing.expect(result.contains(.{ .x = 7, .y = 0 }));
}

// --- Slice 3d: shared-mutex lock-domain reconciliation ---
//
// Slice 3d makes the Client guard its mirror writes under the SAME
// `*std.Thread.Mutex` the renderer reads the mirror under (shared by pointer
// via `Client.Config.render_mutex`). These two tests prove:
//
//   1. STRUCTURAL: when an external mutex is supplied via Config, the Client's
//      effective guard IS that exact object (pointer identity), not its
//      embedded `owned_mutex`. (And, conversely, no-config => owned fallback.)
//   2. CONCURRENCY: hammering `handleFrame` (the mirror WRITER) on one thread
//      while another thread locks the SAME mutex and reads `render_state` (the
//      reader's role, as `updateFrame`'s copyFrom does) yields no torn read —
//      the reader always observes a fully-applied frame (one of the known
//      whole-grid states), never a half-applied mixture. Over many iterations
//      this exercises the serialization the shared mutex provides.
test "client Slice 3d external mutex is the effective guard (structural)" {
    const alloc = testing.allocator;

    var shared: std.Thread.Mutex = .{};

    // With an external mutex supplied, the first lock resolves the effective
    // guard to THAT object — not the embedded owned_mutex.
    var client = try Client.init(alloc, .{ .render_mutex = &shared });
    defer client.deinit();

    // A handleFrame (a no-op .mode_frame here) takes the guard, resolving it.
    const mf: protocol.ModeFrame = .{ .session_id = 1 };
    const p = try mf.encode(alloc);
    defer alloc.free(p);
    try client.handleFrame(alloc, .mode_frame, p);

    try testing.expect(client.render_mutex != null);
    try testing.expectEqual(
        @intFromPtr(&shared),
        @intFromPtr(client.render_mutex.?),
    );
    // It is NOT the owned fallback.
    try testing.expect(client.render_mutex.? != &client.owned_mutex);

    // Conversely: no external mutex => the owned fallback is used.
    var client2 = try Client.init(alloc, .{});
    defer client2.deinit();
    try client2.handleFrame(alloc, .mode_frame, p);
    try testing.expectEqual(
        @intFromPtr(&client2.owned_mutex),
        @intFromPtr(client2.render_mutex.?),
    );
}

test "client Slice 3d shared mutex serializes writer/reader (no torn read)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    // A thread-safe allocator: handleFrame allocates on the writer thread; the
    // reader thread does not allocate (it only reads scalars under the lock),
    // but wrap to be safe against any incidental allocation.
    var tsa: std.heap.ThreadSafeAllocator = .{ .child_allocator = testing.allocator };
    const alloc = tsa.allocator();

    // A LARGE grid (many rows × many cells) so each `rehydrate` write spans a
    // wide, easily-observable window: with the lock removed the reader reliably
    // catches the writer mid-grid (validated by commenting out handleFrame's
    // m.lock()/unlock() — the test then fails with error.TornRead). A 2×8 grid
    // writes too few cells for the tear window to be observable.
    const cols: u16 = 128;
    const rows: u16 = 48;

    // Two DISTINCT whole-grid frames, each UNIFORM across every cell:
    //   - frame A: every cell == 'A'
    //   - frame B: every cell == 'B'
    // The only two consistent whole-grid states the reader may ever observe are
    // "all A" and "all B". A torn read (the writer caught partway through
    // `rehydrate`, with the shared lock missing/broken) leaves a MIXTURE of 'A'
    // and 'B' cells, which the reader detects directly in the cell content that
    // actually varies between frames.
    const buf_a = try alloc.alloc(u8, @as(usize, cols) * rows + (rows - 1) * 2);
    defer alloc.free(buf_a);
    const buf_b = try alloc.alloc(u8, buf_a.len);
    defer alloc.free(buf_b);
    {
        var off: usize = 0;
        for (0..rows) |y| {
            if (y != 0) {
                buf_a[off] = '\r';
                buf_b[off] = '\r';
                buf_a[off + 1] = '\n';
                buf_b[off + 1] = '\n';
                off += 2;
            }
            for (0..cols) |_| {
                buf_a[off] = 'A';
                buf_b[off] = 'B';
                off += 1;
            }
        }
        std.debug.assert(off == buf_a.len);
    }

    const framed_a = try buildFramed(alloc, cols, rows, buf_a, .{});
    defer alloc.free(framed_a);
    const framed_b = try buildFramed(alloc, cols, rows, buf_b, .{});
    defer alloc.free(framed_b);

    // THE shared mutex — exactly the renderer-state-mutex sharing Slice 4 wires.
    var shared: std.Thread.Mutex = .{};

    var client = try Client.init(alloc, .{ .render_mutex = &shared });
    defer client.deinit();

    const iters: usize = 4000;

    // Cross-thread done flag: the reader spins reading for the ENTIRE duration
    // the writer is alternating frames (rather than a fixed iteration count that
    // might finish before the writer warms up), so reader scans maximally overlap
    // writer rehydrates — the condition under which a missing lock tears.
    var done = std.atomic.Value(bool).init(false);

    const Reader = struct {
        c: *Client,
        m: *std.Thread.Mutex,
        done: *std.atomic.Value(bool),
        err: ?anyerror = null,
        contended: bool = false,
        scans: usize = 0,

        // Read one cell's codepoint (0 for a blank/non-codepoint cell). The
        // mirror cells' `.raw` is the `page.Cell`; populated codepoint cells
        // carry the glyph in `content.codepoint`.
        fn cellCodepoint(rs: *const RenderStateCore, y: usize, x: usize) u21 {
            const raws = rs.row_data.slice().items(.cells)[y].slice().items(.raw);
            const cell = raws[x];
            return switch (cell.content_tag) {
                .codepoint, .codepoint_grapheme => cell.content.codepoint,
                else => 0,
            };
        }

        fn run(ctx: *@This()) void {
            const A: u21 = 'A';
            const B: u21 = 'B';
            // Spin until the writer signals done; do one extra pass after so the
            // final settled frame is also checked.
            while (true) {
                const last = ctx.done.load(.acquire);

                // Try-lock first to observe contention with the writer at
                // runtime (a non-fatal corroboration that reader and writer
                // fight over THIS object). Contention is timing-dependent, so
                // it is NOT asserted (see the structural pointer-identity
                // assertion after the join, which is the real proof); we only
                // record it for diagnostics.
                {
                    if (!ctx.m.tryLock()) {
                        ctx.contended = true;
                        ctx.m.lock();
                    }
                    defer ctx.m.unlock();

                    const rs = &ctx.c.render_state;
                    if (rs.rows != 0) {
                        ctx.scans += 1;

                        // Dimensions are invariant across both frames, but check
                        // them anyway so a dimension tear (were one possible)
                        // would still surface.
                        if (rs.rows != rows or rs.cols != cols) {
                            ctx.err = error.TornRead;
                            return;
                        }
                        if (rs.row_data.len != rs.rows) {
                            ctx.err = error.TornRowCount;
                            return;
                        }

                        // CONSISTENCY — the real torn-read proof, on the CONTENT
                        // that varies between frames. Require EVERY cell to equal
                        // the reference cell's codepoint, itself one of the two
                        // whole-frame glyphs. Any 'A'/'B' mixture means the reader
                        // observed the writer partway through `rehydrate` — i.e.
                        // the shared lock failed. The reference cell is read LAST
                        // (bottom-right) and the scan runs in REVERSE row order,
                        // while the writer fills rows front-to-back, so a missing
                        // lock reliably yields a half-applied (mixed) grid here.
                        const last_y = rs.rows - 1;
                        const first = cellCodepoint(rs, last_y, rs.cols - 1);
                        if (first != A and first != B) {
                            ctx.err = error.TornRead;
                            return;
                        }
                        var y: usize = rs.rows;
                        rowscan: while (y > 0) {
                            y -= 1;
                            var x: usize = rs.cols;
                            while (x > 0) {
                                x -= 1;
                                if (cellCodepoint(rs, y, x) != first) {
                                    ctx.err = error.TornRead;
                                    break :rowscan;
                                }
                            }
                        }
                        if (ctx.err != null) return;
                    }
                }

                if (last) break; // writer was already done before this pass
            }
        }
    };

    // Pre-decode each frame's (tag,payload) ONCE into stable owned buffers, so
    // the writer loop below does NOTHING but call `handleFrame` (i.e. the
    // `rehydrate` cell-write). Keeping decode/alloc OUT of the timed loop makes
    // the cell-write the dominant fraction of each writer iteration, so the
    // reader's scan reliably overlaps the writer mid-rehydrate when the lock is
    // absent (the regression we guard against), while the lock present still
    // fully serializes them.
    const Decoded = struct {
        tag: protocol.FrameType,
        payload: []u8,
    };
    var decoded_a: Decoded = undefined;
    var decoded_b: Decoded = undefined;
    {
        inline for (.{ .{ framed_a, &decoded_a }, .{ framed_b, &decoded_b } }) |pair| {
            var reader: protocol.FrameReader = .{};
            defer reader.deinit(alloc);
            try reader.push(alloc, pair[0]);
            const frame = (try reader.next(alloc)).?;
            // `frame.payload` borrows the reader's reassembly buffer; copy it out
            // so it outlives this scope (reader.deinit frees that buffer).
            pair[1].* = .{ .tag = frame.tag, .payload = try alloc.dupe(u8, frame.payload) };
        }
    }
    defer alloc.free(decoded_a.payload);
    defer alloc.free(decoded_b.payload);

    var reader_ctx: Reader = .{ .c = &client, .m = &shared, .done = &done };
    const reader_thread = try std.Thread.spawn(.{}, Reader.run, .{&reader_ctx});

    // WRITER: alternate the two frames through handleFrame (locks `shared`).
    var i: usize = 0;
    var write_err: ?anyerror = null;
    while (i < iters) : (i += 1) {
        const d = if (i % 2 == 0) decoded_a else decoded_b;
        client.handleFrame(alloc, d.tag, d.payload) catch |e| {
            write_err = e;
            break;
        };
    }
    done.store(true, .release);

    reader_thread.join();

    if (write_err) |e| return e;
    if (reader_ctx.err) |e| return e;

    // After the run the mirror is a fully-applied rows×cols grid.
    try testing.expectEqual(rows, client.render_state.rows);
    try testing.expectEqual(cols, client.render_state.cols);

    // STRUCTURAL (deterministic) PROOF that the supplied mutex IS the effective
    // guard the Client locks: pointer identity. This is the real "the supplied
    // mutex is the one used" guarantee — it holds regardless of thread timing.
    try testing.expectEqual(
        @intFromPtr(&shared),
        @intFromPtr(client.render_mutex.?),
    );
    // `contended` (the reader saw tryLock fail because the writer held the lock)
    // is a timing-dependent corroboration, NOT a structural guarantee: under
    // thread starvation it could legitimately stay false despite correct code.
    // It is therefore observed, never asserted (the pointer-identity check above
    // and the value-based torn-read check above are the deterministic proofs).
    if (!reader_ctx.contended) {
        std.debug.print(
            "\n[client difftest] note: shared mutex was never observed contended " ++
                "(timing); serialization still proven by torn-read + pointer identity\n",
            .{},
        );
    }
    // The reader must actually have scanned applied frames under the lock —
    // otherwise the torn-read consistency check above was never exercised.
    try testing.expect(reader_ctx.scans > 0);
}

// --- Slice 4: socket_path ownership (use-after-free regression) ---

test "client owns its socket_path (UAF regression)" {
    // REGRESSION (Slice-4 finding #1): `Client.init` must DUPE its
    // `cfg.socket_path` into Client-owned memory. In production the borrowed
    // slice is frequently a conditional-state config CLONE in `Surface.init`
    // that is freed (`defer config_.deinit()`) as soon as `Surface.init`
    // returns — while the IO/read thread reads `socket_path` LATER, in
    // `connectAndAttach` -> `connectUnix(self.config.socket_path)`. If the
    // Client stored the borrowed slice by value, that later read would be a
    // use-after-free (fires intermittently — only when conditional state is
    // active, e.g. a light/dark theme).
    //
    // This proves the dupe is REAL and INDEPENDENT of the source buffer:
    // construct the Client from a heap source slice, then FREE + SCRIBBLE that
    // source before anything reads `config.socket_path`, and assert the stored
    // copy is unchanged (distinct backing memory, still equal to the expected
    // path — i.e. what `connectUnix` would see is valid). No socket needed.
    const alloc = testing.allocator;

    const expected = "/tmp/ghostty-ptyhost-uaf-regression.sock";

    // Heap-allocate the SOURCE slice so we can free it out from under the
    // Client (a stack literal could not model the conditional-state-clone
    // lifetime this regression is about).
    const source = try alloc.dupe(u8, expected);

    var client = try Client.init(alloc, .{ .socket_path = source });
    defer client.deinit();

    // The stored copy must be DISTINCT backing memory (a real dupe, not the
    // borrowed slice aliased by value).
    try testing.expect(client.config.socket_path.ptr != source.ptr);
    try testing.expectEqualStrings(expected, client.config.socket_path);

    // Now FREE + SCRIBBLE the source, exactly as `Surface.init` frees the
    // conditional-state clone before the read thread connects. (Scribble first,
    // then free, so the bytes are clobbered regardless of allocator reuse.)
    @memset(source, 0xAA);
    alloc.free(source);

    // The Client's OWN copy is untouched — `connectUnix` would still see the
    // correct, valid path. Without the dupe, this read would be a UAF.
    try testing.expectEqualStrings(expected, client.config.socket_path);
}

test "client owns empty default socket_path (no UAF, no double-free)" {
    // The empty-default path (`&.{}`, the `Config` default when no `pty-host`
    // is configured) must also be duped and freed safely: `alloc.dupe(u8,
    // &.{})` yields a zero-length OWNED slice, and `deinit`'s `free` of it is a
    // no-op-safe free. Proves the empty case neither leaks nor double-frees
    // (the testing allocator would flag either).
    const alloc = testing.allocator;
    var client = try Client.init(alloc, .{});
    defer client.deinit();
    try testing.expectEqual(@as(usize, 0), client.config.socket_path.len);
}
