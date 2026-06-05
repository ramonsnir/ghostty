//! Host integration tests (Phase 1). The named tests required by the
//! Phase 1 acceptance criteria live here:
//!   - "host session spawn+diff" (real child + IO thread + wakeup + diff)
//!   - "RenderState round-trip (serialize->deserialize->equal)"
//! Plus a fast synchronous unit test of the render-sink diff path.
//! All test names contain the literal "host" so `-Dtest-filter=host` matches.

const std = @import("std");
const testing = std.testing;

const terminalpkg = @import("../terminal/main.zig");
const inputpkg = @import("../input.zig");
const apprt = @import("../apprt.zig");
const render = @import("../terminal/render.zig");
const RenderStateCore = render.RenderState;
const renderer = @import("../renderer.zig");
const renderer_size = @import("../renderer/size.zig");

const posix = std.posix;

const Session = @import("Session.zig");
const RenderState = @import("RenderState.zig");
const protocol = @import("protocol.zig");
const Server = @import("Server.zig");
const Client = @import("../termio/Client.zig");
const CoreSurface = @import("../Surface.zig");

test "host session spawn+diff" {
    const alloc = testing.allocator;

    // Create AND start a Session: this spawns the real pty + child shell
    // (Termio.threadEnter), runs the libxev IO thread, and arms the render
    // loop so child output flowing over the pty wakes renderer_wakeup ->
    // renderWakeupCallback -> renderTick. This exercises the full load-bearing
    // Phase 1 path, not a synchronous shortcut.
    const session = try Session.create(alloc, .{ .cols = 80, .rows = 24 });
    defer session.destroy();

    // Invariant: no GPU, no inspector.
    try testing.expect(session.renderer_state.inspector == null);

    try session.start();
    // stop() is idempotent with destroy(); calling it here ensures the IO
    // thread is joined before we assert/teardown even on the happy path.
    defer session.stop();

    // Drive a deterministic command so the child produces known output over
    // the pty regardless of the shell's prompt/startup. The trailing newline
    // submits it.
    try session.sendInput("printf 'HELLO_HOST_MARKER\\n'\n");

    // Poll the render loop to quiescence: pump the loop (no_wait), which
    // dispatches any pending renderer_wakeup completion -> renderWakeupCallback
    // -> renderTick (the real GPU-free render path). The IO thread notifies
    // renderer_wakeup whenever child output lands on the emulator. We sleep
    // briefly between pumps to let the IO thread read the pty. Bounded so a
    // regression in spawn/IO-thread/wakeup wiring can't hang the test.
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        try session.tickRenderLoop();
        if (session.total_changed_rows > 0) break;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    // Real child output (the shell prompt and/or the echoed command/result)
    // must have flowed over the pty, woken the render loop, and produced a
    // non-empty RenderState diff via the wakeup callback.
    try testing.expect(session.total_changed_rows > 0);

    // Host-boundary contract: across a real session's lifetime so far, Termio
    // must have pushed nothing onto the renderer mailbox beyond the two
    // sanctioned kinds. Any new push kind would have landed in the drain's
    // `else` arm and bumped this counter.
    try testing.expectEqual(@as(usize, 0), session.unexpected_renderer_count);
}

test "host session synchronous render-sink diff" {
    const alloc = testing.allocator;

    // A fast unit test of the render-sink diff path that does NOT spawn a
    // child or run the IO thread: it writes bytes directly into the emulator
    // and calls renderTick on this thread. Complements the spawn+diff test
    // above (which covers the real pty/IO/wakeup path).
    const session = try Session.create(alloc, .{ .cols = 40, .rows = 10 });
    defer session.destroy();

    // Invariant: no GPU, no inspector.
    try testing.expect(session.renderer_state.inspector == null);

    // First render tick: terminal is blank, so the diff (vs. no previous
    // snapshot) should be empty.
    const first = try session.renderTick();
    try testing.expectEqual(@as(usize, 0), first);

    // Feed "input" by writing bytes directly into the terminal, simulating
    // child output landing on the emulator. We hold the renderer mutex like
    // the IO thread would.
    {
        session.render_mutex.lock();
        defer session.render_mutex.unlock();
        try session.io.terminal.printString("hello host");
    }

    // Second render tick: the changed row must produce a non-empty diff.
    const second = try session.renderTick();
    try testing.expect(second > 0);
}

test "RenderState round-trip (serialize->deserialize->equal) host" {
    const alloc = testing.allocator;

    // Build a real terminal and write content (including a multi-codepoint
    // grapheme to exercise the grapheme path).
    var term = try terminalpkg.Terminal.init(alloc, .{ .cols = 20, .rows = 5 });
    defer term.deinit(alloc);

    try term.printString("abc 123");
    term.carriageReturn();
    try term.linefeed();
    // A base + combining mark forms a grapheme cluster in one cell.
    try term.printString("e\u{0301}!"); // é (e + COMBINING ACUTE) then !

    // Build a core RenderState and project it into a Snapshot.
    var rs: RenderStateCore = .empty;
    defer rs.deinit(alloc);
    try rs.update(alloc, &term);

    var snap = try RenderState.Snapshot.fromRenderState(alloc, &rs);
    defer snap.deinit(alloc);

    // Serialize -> deserialize -> equal.
    const bytes = try snap.serialize(alloc);
    defer alloc.free(bytes);

    var restored = try RenderState.Snapshot.deserialize(alloc, bytes);
    defer restored.deinit(alloc);

    try testing.expect(snap.eql(restored));

    // And the reverse: a re-serialization of the restored snapshot must be
    // byte-identical (stable wire form).
    const bytes2 = try restored.serialize(alloc);
    defer alloc.free(bytes2);
    try testing.expectEqualSlices(u8, bytes, bytes2);

    // Sanity: the grapheme cell survived the round-trip.
    var found_grapheme = false;
    for (restored.row_data) |row| {
        for (row.cells) |c| {
            if (c.grapheme.len > 0) found_grapheme = true;
        }
    }
    try testing.expect(found_grapheme);
}

test "host deserialize drops an out-of-range highlight tag (untrusted-wire @enumFromInt UB guard)" {
    // Reproduce-first guard for a render-hot-path crash: the renderer maps the
    // wire highlight tag via `@enumFromInt(hl.tag)` onto a 2-value enum, so a
    // corrupt / version-skewed frame carrying tag >= 2 is illegal behavior (UB in
    // the ReleaseFast lib). deserialize must DROP an out-of-range tag (keeping the
    // rest of the frame) so the stored mirror only ever holds valid tags. Also
    // checks the span bookkeeping: dropping a highlight must NOT shift the next
    // row's highlights (the shared-pool offset uses the actually-appended count).
    const alloc = testing.allocator;

    var term = try terminalpkg.Terminal.init(alloc, .{ .cols = 20, .rows = 5 });
    defer term.deinit(alloc);

    var rs: RenderStateCore = .empty;
    defer rs.deinit(alloc);
    try rs.update(alloc, &term);

    var snap = try RenderState.Snapshot.fromRenderState(alloc, &rs);
    defer snap.deinit(alloc);
    try testing.expect(snap.row_data.len >= 2);

    // Inject highlights directly onto two rows. snap.deinit frees the
    // highlight_pool (not these per-row slices), so pointing row.highlights at
    // these stack arrays is safe. Row 0: valid(1), INVALID(2), valid(0). Row 1: a
    // single valid highlight that must survive intact at the right offset.
    var hl0 = [_]RenderState.Highlight{
        .{ .tag = 1, .range = .{ 0, 2 } },
        .{ .tag = 2, .range = .{ 3, 5 } }, // out of range -> must be dropped
        .{ .tag = 0, .range = .{ 6, 8 } },
    };
    var hl1 = [_]RenderState.Highlight{
        .{ .tag = 1, .range = .{ 1, 4 } },
    };
    snap.row_data[0].highlights = &hl0;
    snap.row_data[1].highlights = &hl1;

    const bytes = try snap.serialize(alloc);
    defer alloc.free(bytes);
    var restored = try RenderState.Snapshot.deserialize(alloc, bytes);
    defer restored.deinit(alloc);

    // Row 0: the tag==2 highlight is dropped; the two valid ones remain in order.
    try testing.expectEqual(@as(usize, 2), restored.row_data[0].highlights.len);
    try testing.expectEqual(@as(u8, 1), restored.row_data[0].highlights[0].tag);
    try testing.expectEqual(@as(u8, 0), restored.row_data[0].highlights[1].tag);
    // Row 1: intact (the drop didn't corrupt the next row's pool offset).
    try testing.expectEqual(@as(usize, 1), restored.row_data[1].highlights.len);
    try testing.expectEqual(@as(u8, 1), restored.row_data[1].highlights[0].tag);
    try testing.expectEqual([2]u16{ 1, 4 }, restored.row_data[1].highlights[0].range);
}

test "host cursor-only move pushes (Slice 8): rows identical, cursor differs => printDiff==0 but cursorEql=false; identical => no push" {
    const alloc = testing.allocator;

    // A terminal with some content on one line. The cursor lands after the
    // printed text.
    var term = try terminalpkg.Terminal.init(alloc, .{ .cols = 20, .rows = 5 });
    defer term.deinit(alloc);
    try term.printString("hello world");

    // Snapshot A: cursor at end-of-text.
    var rs_a: RenderStateCore = .empty;
    defer rs_a.deinit(alloc);
    try rs_a.update(alloc, &term);
    var snap_a = try RenderState.Snapshot.fromRenderState(alloc, &rs_a);
    defer snap_a.deinit(alloc);

    // Move the cursor LEFT several columns WITHOUT changing any cell content
    // (the arrow-key case). Rows are byte-identical; only the cursor moves.
    term.cursorLeft(7);

    var rs_b: RenderStateCore = .empty;
    defer rs_b.deinit(alloc);
    try rs_b.update(alloc, &term);
    var snap_b = try RenderState.Snapshot.fromRenderState(alloc, &rs_b);
    defer snap_b.deinit(alloc);

    // The cursor genuinely moved.
    try testing.expect(snap_a.cursor_x != snap_b.cursor_x);

    // No ROW changed: this is exactly the bug condition where the old gate
    // (changed>0 or search_dirty) would have suppressed the frame.
    const changed = try RenderState.printDiff(alloc, snap_a, snap_b);
    try testing.expectEqual(@as(usize, 0), changed);

    // The widened gate's cursor predicate fires: cursorEql is false, so
    // `changed > 0 or force_push or cursor_changed` is true => frame pushes.
    try testing.expect(!snap_a.cursorEql(snap_b));

    // Negative / idle case: a snapshot compared against ITSELF (same rows,
    // same cursor) has changed==0 AND cursorEql==true, so the gate stays
    // closed — confirms a fully-idle identical snapshot pushes nothing.
    var snap_b2 = try RenderState.Snapshot.fromRenderState(alloc, &rs_b);
    defer snap_b2.deinit(alloc);
    const changed_idle = try RenderState.printDiff(alloc, snap_b, snap_b2);
    try testing.expectEqual(@as(usize, 0), changed_idle);
    try testing.expect(snap_b.cursorEql(snap_b2));
}

test "host session shuts down on child exit with no trailing output" {
    // Regression test for the child-exit shutdown gap: a child that exits
    // delivers .child_exited ONLY via the surface mailbox (none.App.wakeup is
    // a no-op for the headless host), which does NOT notify renderer_wakeup.
    // Without the poll timer, a shell that exits with no trailing pty output
    // would leave the .child_exited message undrained and runRenderLoop would
    // block forever. With the timer, renderTick is driven periodically, the
    // message is drained, render_stop is notified, and the loop stops.
    const alloc = testing.allocator;

    const session = try Session.create(alloc, .{ .cols = 80, .rows = 24 });
    defer session.destroy();
    try testing.expect(session.renderer_state.inspector == null);

    // Short interval so the test resolves quickly. (Production uses 100ms.)
    session.poll_interval_ms = 5;

    try session.start();
    defer session.stop();

    // Ask the shell to exit. `exec` replaces the shell process so it tears the
    // pty down promptly; the trailing newline submits the line.
    try session.sendInput("exec true\n");

    // Drive the render loop via no_wait ticks. Each tick dispatches any expired
    // poll-timer completion -> pollTimerCallback -> renderTick, which drains the
    // app queue. When .child_exited is seen, render_stop is notified and
    // renderStopCallback sets loop_stopped. Bounded so a regression that breaks
    // the poll-driven shutdown fails the test instead of hanging it.
    var i: usize = 0;
    while (i < 400) : (i += 1) {
        try session.tickRenderLoop();
        if (session.loop_stopped) break;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    // The child exit must have deterministically stopped the render loop.
    try testing.expect(session.loop_stopped);
}

test "host renderer-mailbox drain handles only resize and reset_cursor_blink" {
    // Behavioral guard for the host-boundary contract (plan §6/§9 risk #9):
    // the drain must classify the two sanctioned renderer messages correctly
    // and route anything else to the unexpected-counter canary. This pins the
    // drain's behavior; the source-grep test below pins Termio's emit set.
    const alloc = testing.allocator;

    const session = try Session.create(alloc, .{ .cols = 20, .rows = 5 });
    defer session.destroy();

    // Push the two sanctioned kinds plus one deliberately-unexpected kind
    // directly onto the stub renderer mailbox, then drain via renderTick.
    _ = session.renderer_mailbox.push(.{ .resize = session.size }, .{ .forever = {} });
    _ = session.renderer_mailbox.push(.{ .reset_cursor_blink = {} }, .{ .forever = {} });
    // A kind Termio never pushes; the drain must count it as unexpected (the
    // runtime canary that catches a future Termio regression).
    _ = session.renderer_mailbox.push(.{ .macos_display_id = 0 }, .{ .forever = {} });

    _ = try session.renderTick();

    try testing.expectEqual(@as(usize, 1), session.renderer_resize_count);
    try testing.expectEqual(@as(usize, 1), session.renderer_reset_cursor_blink_count);
    try testing.expectEqual(@as(usize, 1), session.unexpected_renderer_count);
}

test "host Termio pushes only resize and reset_cursor_blink to renderer mailbox" {
    // Static guard for the host-boundary contract: assert at the SOURCE level
    // that src/termio/Termio.zig contains exactly the two sanctioned
    // `renderer_mailbox.push` call sites (.resize and .reset_cursor_blink),
    // and that StreamHandler.rendererMessageWriter (the only other pusher) is
    // dead code with zero call sites. A future Termio change that adds a third
    // live push kind, or that revives rendererMessageWriter, fails HERE rather
    // than only surfacing as a runtime warning. Satisfies plan §9 risk #9's
    // named "Zig test that greps/asserts the renderer-mailbox push set".
    const termio_src = @embedFile("../termio/Termio.zig");
    const stream_src = @embedFile("../termio/stream_handler.zig");

    // Termio.zig has exactly two push sites, and they are the sanctioned kinds.
    try testing.expectEqual(@as(usize, 2), countOccurrences(termio_src, "renderer_mailbox.push"));
    try testing.expect(std.mem.indexOf(u8, termio_src, ".resize = size") != null);
    try testing.expect(std.mem.indexOf(u8, termio_src, ".reset_cursor_blink = {}") != null);

    // stream_handler.zig's pushes live only inside rendererMessageWriter, which
    // is dead code: its identifier appears exactly once (its own definition),
    // i.e. zero call sites.
    try testing.expectEqual(@as(usize, 1), countOccurrences(stream_src, "rendererMessageWriter"));
}

test "host search slice 3b leaves .exec GUI search untouched" {
    // Slice 3b is purely ADDITIVE: the host GAINS search; the GUI KEEPS its
    // own GUI-side search for .exec. Static guard that Surface.zig still owns
    // its own terminal.search.Thread (the GUI search engine) and that the
    // backend selection at the documented site is still hardcoded `.exec`.
    // A regression that relocated the GUI search to the host, or flipped the
    // Surface backend to .client, fails HERE.
    const surface_src = @embedFile("../Surface.zig");

    // The GUI still constructs its own search Thread state.
    try testing.expect(std.mem.indexOf(u8, surface_src, "search: ?Search = null") != null);
    try testing.expect(std.mem.indexOf(u8, surface_src, "state: terminal.search.Thread") != null);
    // The GUI still spawns the search thread itself.
    try testing.expect(std.mem.indexOf(u8, surface_src, "terminal.search.Thread.threadMain") != null);
    // SLICE 4: the Surface backend is now SELECTABLE — `.exec` when `pty-host`
    // is null (today's behavior), `.client` when it is set. The Slice-3-era
    // "hardcoded .exec / never .client" guard was intentionally relaxed here;
    // selection lives in the documented io-backend block keyed off
    // `config.@"pty-host"`. We still pin that BOTH arms exist so a regression
    // that drops either backend (e.g. removing .client, or losing the .exec
    // fallback) fails HERE, and that the GUI search ownership above is intact.
    try testing.expect(std.mem.indexOf(u8, surface_src, ".exec = io_exec") != null);
    try testing.expect(std.mem.indexOf(u8, surface_src, ".client = io_client") != null);
    try testing.expect(std.mem.indexOf(u8, surface_src, "config.@\"pty-host\"") != null);

    // And the GUI renderer still GATES updateHighlightsFlattened behind the
    // live-pin predicate (Slice 3a), i.e. the host did not un-gate it.
    const generic_src = @embedFile("../renderer/generic.zig");
    try testing.expect(std.mem.indexOf(u8, generic_src, "usesLivePinPaths() and") != null);

    // Pin the GUI's private HighlightTag enum ordering (finding
    // SEARCH-TAG-CONST-2): the host hardcodes search_match=0 /
    // search_match_selected=1 (Session.zig:Session.highlight_tag_search_match*) because
    // that enum is a private const nested in the Renderer(...) generic and
    // cannot be imported. A reorder/insert there would silently remap
    // host-produced row.highlights to the wrong color on the client with no
    // compile error. Assert the declaration order so such a reorder fails HERE.
    const tag_decl = "const HighlightTag = enum(u8) {";
    const tag_at = std.mem.indexOf(u8, generic_src, tag_decl) orelse
        return error.HighlightTagDeclMissing;
    const sm = std.mem.indexOfPos(u8, generic_src, tag_at, "search_match") orelse
        return error.SearchMatchVariantMissing;
    const sms = std.mem.indexOfPos(u8, generic_src, tag_at, "search_match_selected") orelse
        return error.SearchMatchSelectedVariantMissing;
    // search_match (host const 0) must be declared before search_match_selected
    // (host const 1).
    try testing.expect(sm < sms);
}

test "client backend selection seam (slice 4)" {
    // SLICE 4 selection seam, asserted statically against Surface.zig source
    // (the init path needs a full app/window context and is not unit-testable
    // headlessly — the live render is the documented human smoke). This pins
    // the THREE load-bearing properties of the selection + wiring:
    //
    //   1. Selection is keyed off `config.@"pty-host"` (null => .exec, the
    //      byte-for-byte-unchanged default; set => .client).
    //   2. The `.client` arm builds the Client via `termio.Client.init` and
    //      does NOT call `termio.Exec.init` inside it — i.e. selecting .client
    //      forks NO shell subprocess. We pin this by requiring the branch to be
    //      an `if (config.@"pty-host")` whose then-arm constructs the Client and
    //      whose else-arm constructs Exec (so Exec.init is only reachable when
    //      pty-host is null).
    //   3. The mirror/link wiring takes the FINAL post-move address inside
    //      `self.io.backend` (the lifetime-critical part), NOT a pre-move local.
    const surface_src = @embedFile("../Surface.zig");

    // (1) selection keyed off the config key, with both backend arms present.
    const sel = std.mem.indexOf(u8, surface_src, "if (config.@\"pty-host\")") orelse
        return error.PtyHostSelectionMissing;
    const client_init = std.mem.indexOf(u8, surface_src, "termio.Client.init(alloc") orelse
        return error.ClientInitMissing;
    const exec_init = std.mem.indexOf(u8, surface_src, "termio.Exec.init(alloc") orelse
        return error.ExecInitMissing;

    // (2) Client.init is in the then-arm and Exec.init is in the else-arm:
    // both must appear AFTER the `if (config.@"pty-host")`, and Client.init
    // (then) must precede Exec.init (else). This makes Exec.init — the call
    // that forks the pty child — unreachable when .client is selected.
    try testing.expect(client_init > sel);
    try testing.expect(exec_init > client_init);

    // Forward-mapped host session id (Slice 5a): the Client config's
    // session_id is now derived from the surface-config session id via the
    // shared sentinel mapping (0 => null/fresh, non-zero => reattach), so
    // the reattach request can reach the Client.
    try testing.expect(std.mem.indexOf(
        u8,
        surface_src,
        ".session_id = termio.Client.sessionIdFromConfig(req_session_id)",
    ) != null);
    // Shared render mutex threaded into the Client config (Slice 3d).
    try testing.expect(std.mem.indexOf(u8, surface_src, ".render_mutex = mutex") != null);

    // (3) lifetime-critical wiring: the mirror/link pointers are taken from the
    // FINAL post-move home `self.io.backend` (the `.client => |*c|` capture),
    // NOT from the pre-move `io_client` local.
    const wire = std.mem.indexOf(u8, surface_src, "switch (self.io.backend)") orelse
        return error.MirrorWireSwitchMissing;
    const mirror_at = std.mem.indexOfPos(u8, surface_src, wire, "self.renderer_state.mirror = &c.render_state") orelse
        return error.MirrorWireMissing;
    const links_at = std.mem.indexOfPos(u8, surface_src, wire, "self.renderer_state.link_cells = &c.osc8_links") orelse
        return error.LinkWireMissing;
    try testing.expect(mirror_at > wire);
    try testing.expect(links_at > wire);
    // Must NOT wire from the pre-move local (would dangle after the union move).
    try testing.expect(std.mem.indexOf(u8, surface_src, "mirror = &io_client") == null);
}

/// Feed `framed` to a FrameReader one byte at a time, asserting `next` returns
/// null until the final byte, then a single complete frame. Returns the
/// decoded {tag,payload}; the payload is copied into `out_payload` (caller-
/// owned) since the reader's slice is invalidated on the next call.
fn feedOneByteAtATime(
    alloc: std.mem.Allocator,
    framed: []const u8,
    out_payload: *std.ArrayList(u8),
) !protocol.FrameType {
    var reader: protocol.FrameReader = .{};
    defer reader.deinit(alloc);

    for (framed, 0..) |b, i| {
        try reader.push(alloc, framed[i .. i + 1]);
        _ = b;
        const f = try reader.next(alloc);
        if (i + 1 < framed.len) {
            try testing.expect(f == null);
        } else {
            try testing.expect(f != null);
            out_payload.clearRetainingCapacity();
            try out_payload.appendSlice(alloc, f.?.payload);
            // No further frame buffered.
            try testing.expect((try reader.next(alloc)) == null);
            return f.?.tag;
        }
    }
    return error.NoFrame;
}

test "host protocol frame round-trip + partial read" {
    const alloc = testing.allocator;

    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(alloc);

    // Helper closure pattern: encode -> writeFrame -> feed one byte at a time
    // -> decode -> compare. We do each frame type explicitly so we can assert
    // field-equality (including owned byte slices).

    // Hello.
    {
        const orig: protocol.Hello = .{
            .protocol_version_major = 1,
            .protocol_version_minor = 7,
            .identity_bundle_id = "com.mitchellh.ghostty-ramon",
        };
        const framed = try protocol.encodeFrame(alloc, .hello, orig);
        defer alloc.free(framed);
        const tag = try feedOneByteAtATime(alloc, framed, &payload);
        try testing.expectEqual(protocol.FrameType.hello, tag);
        var dec = try protocol.Hello.decode(alloc, payload.items);
        defer dec.deinit(alloc);
        try testing.expectEqual(orig.protocol_version_major, dec.protocol_version_major);
        try testing.expectEqual(orig.protocol_version_minor, dec.protocol_version_minor);
        try testing.expectEqualStrings(orig.identity_bundle_id, dec.identity_bundle_id);
    }

    // HelloAck.
    {
        const orig: protocol.HelloAck = .{
            .protocol_version_major = 1,
            .protocol_version_minor = 0,
            .host_pid = 4242,
            .host_start_epoch = 1717250000,
        };
        const framed = try protocol.encodeFrame(alloc, .hello_ack, orig);
        defer alloc.free(framed);
        const tag = try feedOneByteAtATime(alloc, framed, &payload);
        try testing.expectEqual(protocol.FrameType.hello_ack, tag);
        const dec = try protocol.HelloAck.decode(alloc, payload.items);
        try testing.expectEqual(orig, dec);
    }

    // Attach (present + null), no working_directory.
    {
        const orig: protocol.Attach = .{ .session_id = 99 };
        const framed = try protocol.encodeFrame(alloc, .attach, orig);
        defer alloc.free(framed);
        const tag = try feedOneByteAtATime(alloc, framed, &payload);
        try testing.expectEqual(protocol.FrameType.attach, tag);
        var dec = try protocol.Attach.decode(alloc, payload.items);
        defer dec.deinit(alloc);
        try testing.expectEqual(orig.session_id, dec.session_id);
        try testing.expectEqual(@as(?[]const u8, null), dec.working_directory);
    }
    {
        const orig: protocol.Attach = .{ .session_id = null };
        const framed = try protocol.encodeFrame(alloc, .attach, orig);
        defer alloc.free(framed);
        const tag = try feedOneByteAtATime(alloc, framed, &payload);
        try testing.expectEqual(protocol.FrameType.attach, tag);
        var dec = try protocol.Attach.decode(alloc, payload.items);
        defer dec.deinit(alloc);
        try testing.expectEqual(@as(?u64, null), dec.session_id);
        try testing.expectEqual(@as(?[]const u8, null), dec.working_directory);
    }
    // Attach with working_directory (spawn-opt present).
    {
        const orig: protocol.Attach = .{
            .session_id = null,
            .working_directory = "/Users/ramon/git/ghostty",
        };
        const framed = try protocol.encodeFrame(alloc, .attach, orig);
        defer alloc.free(framed);
        const tag = try feedOneByteAtATime(alloc, framed, &payload);
        try testing.expectEqual(protocol.FrameType.attach, tag);
        var dec = try protocol.Attach.decode(alloc, payload.items);
        defer dec.deinit(alloc);
        try testing.expectEqual(@as(?u64, null), dec.session_id);
        try testing.expect(dec.working_directory != null);
        try testing.expectEqualStrings(
            orig.working_directory.?,
            dec.working_directory.?,
        );
    }
    // Attach reattach (session_id present) WITH a working_directory: still
    // round-trips on the wire (the host ignores it on reattach, but the codec
    // must carry both fields together).
    {
        const orig: protocol.Attach = .{
            .session_id = 42,
            .working_directory = "/tmp/proj",
        };
        const framed = try protocol.encodeFrame(alloc, .attach, orig);
        defer alloc.free(framed);
        const tag = try feedOneByteAtATime(alloc, framed, &payload);
        try testing.expectEqual(protocol.FrameType.attach, tag);
        var dec = try protocol.Attach.decode(alloc, payload.items);
        defer dec.deinit(alloc);
        try testing.expectEqual(orig.session_id, dec.session_id);
        try testing.expectEqualStrings(
            orig.working_directory.?,
            dec.working_directory.?,
        );
    }

    // Attached.
    {
        const orig: protocol.Attached = .{ .session_id = 7, .cols = 80, .rows = 24 };
        const framed = try protocol.encodeFrame(alloc, .attached, orig);
        defer alloc.free(framed);
        const tag = try feedOneByteAtATime(alloc, framed, &payload);
        try testing.expectEqual(protocol.FrameType.attached, tag);
        const dec = try protocol.Attached.decode(alloc, payload.items);
        try testing.expectEqual(orig, dec);
    }

    // Detach / Close.
    {
        const orig: protocol.Detach = .{ .session_id = 11 };
        const framed = try protocol.encodeFrame(alloc, .detach, orig);
        defer alloc.free(framed);
        const tag = try feedOneByteAtATime(alloc, framed, &payload);
        try testing.expectEqual(protocol.FrameType.detach, tag);
        const dec = try protocol.Detach.decode(alloc, payload.items);
        try testing.expectEqual(orig.session_id, dec.session_id);
    }
    {
        const orig: protocol.Close = .{ .session_id = 12 };
        const framed = try protocol.encodeFrame(alloc, .close, orig);
        defer alloc.free(framed);
        const tag = try feedOneByteAtATime(alloc, framed, &payload);
        try testing.expectEqual(protocol.FrameType.close, tag);
        const dec = try protocol.Close.decode(alloc, payload.items);
        try testing.expectEqual(orig.session_id, dec.session_id);
    }

    // Input (owned bytes).
    {
        const orig: protocol.Input = .{
            .session_id = 3,
            .linefeed = true,
            .bytes = "printf 'X'\n",
        };
        const framed = try protocol.encodeFrame(alloc, .input, orig);
        defer alloc.free(framed);
        const tag = try feedOneByteAtATime(alloc, framed, &payload);
        try testing.expectEqual(protocol.FrameType.input, tag);
        var dec = try protocol.Input.decode(alloc, payload.items);
        defer dec.deinit(alloc);
        try testing.expectEqual(orig.session_id, dec.session_id);
        try testing.expectEqual(orig.linefeed, dec.linefeed);
        try testing.expectEqualStrings(orig.bytes, dec.bytes);
    }

    // Resize.
    {
        const orig: protocol.Resize = .{
            .session_id = 5,
            .cols = 120,
            .rows = 40,
            .cell_width = 9,
            .cell_height = 18,
            .padding_l = 1,
            .padding_r = 2,
            .padding_t = 3,
            .padding_b = 4,
            .screen_w = 1080,
            .screen_h = 720,
        };
        const framed = try protocol.encodeFrame(alloc, .resize, orig);
        defer alloc.free(framed);
        const tag = try feedOneByteAtATime(alloc, framed, &payload);
        try testing.expectEqual(protocol.FrameType.resize, tag);
        const dec = try protocol.Resize.decode(alloc, payload.items);
        try testing.expectEqual(orig, dec);
    }

    // Focus.
    {
        const orig: protocol.Focus = .{ .session_id = 6, .focused = true };
        const framed = try protocol.encodeFrame(alloc, .focus, orig);
        defer alloc.free(framed);
        const tag = try feedOneByteAtATime(alloc, framed, &payload);
        try testing.expectEqual(protocol.FrameType.focus, tag);
        const dec = try protocol.Focus.decode(alloc, payload.items);
        try testing.expectEqual(orig, dec);
    }

    // ChildExited.
    {
        const orig: protocol.ChildExited = .{
            .session_id = 8,
            .exit_code = 137,
            .runtime_ms = 123456,
        };
        const framed = try protocol.encodeFrame(alloc, .child_exited, orig);
        defer alloc.free(framed);
        const tag = try feedOneByteAtATime(alloc, framed, &payload);
        try testing.expectEqual(protocol.FrameType.child_exited, tag);
        const dec = try protocol.ChildExited.decode(alloc, payload.items);
        try testing.expectEqual(orig, dec);
    }

    // Ping / Pong (empty payload).
    {
        const orig: protocol.Ping = .{};
        const framed = try protocol.encodeFrame(alloc, .ping, orig);
        defer alloc.free(framed);
        const tag = try feedOneByteAtATime(alloc, framed, &payload);
        try testing.expectEqual(protocol.FrameType.ping, tag);
        _ = try protocol.Ping.decode(alloc, payload.items);
    }
    {
        const orig: protocol.Pong = .{};
        const framed = try protocol.encodeFrame(alloc, .pong, orig);
        defer alloc.free(framed);
        const tag = try feedOneByteAtATime(alloc, framed, &payload);
        try testing.expectEqual(protocol.FrameType.pong, tag);
        _ = try protocol.Pong.decode(alloc, payload.items);
    }

    // ModeFrame.
    {
        const orig: protocol.ModeFrame = .{
            .session_id = 9,
            .alt_esc_prefix = true,
            .cursor_keys = true,
            .bracketed_paste = true,
            .mouse_event = 2,
            .mouse_format = 3,
            .mouse_shift_capture = 2,
            .modify_other_keys_2 = true,
            .kitty_flags = 0b10101,
            .alt_screen_active = true,
        };
        const framed = try protocol.encodeFrame(alloc, .mode_frame, orig);
        defer alloc.free(framed);
        const tag = try feedOneByteAtATime(alloc, framed, &payload);
        try testing.expectEqual(protocol.FrameType.mode_frame, tag);
        const dec = try protocol.ModeFrame.decode(alloc, payload.items);
        try testing.expectEqual(orig, dec);
    }

    // --- Slice 3b: search frames. ---

    // SetSearch (owned query; trailing-field readBytes path). Test empty,
    // typical, and a long query.
    for ([_][]const u8{ "", "foo", "a very long search query " ** 8 }) |q| {
        const orig: protocol.SetSearch = .{ .session_id = 21, .opts = 0, .query = q };
        const framed = try protocol.encodeFrame(alloc, .set_search, orig);
        defer alloc.free(framed);
        const tag = try feedOneByteAtATime(alloc, framed, &payload);
        try testing.expectEqual(protocol.FrameType.set_search, tag);
        var dec = try protocol.SetSearch.decode(alloc, payload.items);
        defer dec.deinit(alloc);
        try testing.expectEqual(orig.session_id, dec.session_id);
        try testing.expectEqual(orig.opts, dec.opts);
        try testing.expectEqualStrings(orig.query, dec.query);
    }

    // SearchNav (next + prev).
    for ([_]u8{ 0, 1 }) |dir| {
        const orig: protocol.SearchNav = .{ .session_id = 22, .dir = dir };
        const framed = try protocol.encodeFrame(alloc, .search_nav, orig);
        defer alloc.free(framed);
        const tag = try feedOneByteAtATime(alloc, framed, &payload);
        try testing.expectEqual(protocol.FrameType.search_nav, tag);
        const dec = try protocol.SearchNav.decode(alloc, payload.items);
        try testing.expectEqual(orig, dec);
    }

    // ClearSearch.
    {
        const orig: protocol.ClearSearch = .{ .session_id = 23 };
        const framed = try protocol.encodeFrame(alloc, .clear_search, orig);
        defer alloc.free(framed);
        const tag = try feedOneByteAtATime(alloc, framed, &payload);
        try testing.expectEqual(protocol.FrameType.clear_search, tag);
        const dec = try protocol.ClearSearch.decode(alloc, payload.items);
        try testing.expectEqual(orig.session_id, dec.session_id);
    }

    // SearchTotal (present + null).
    for ([_]protocol.SearchTotal{
        .{ .session_id = 24, .present = 1, .total = 7 },
        .{ .session_id = 24, .present = 0, .total = 0 },
    }) |orig| {
        const framed = try protocol.encodeFrame(alloc, .search_total, orig);
        defer alloc.free(framed);
        const tag = try feedOneByteAtATime(alloc, framed, &payload);
        try testing.expectEqual(protocol.FrameType.search_total, tag);
        const dec = try protocol.SearchTotal.decode(alloc, payload.items);
        try testing.expectEqual(orig, dec);
    }

    // SearchSelected (present + null).
    for ([_]protocol.SearchSelected{
        .{ .session_id = 25, .present = 1, .idx = 3 },
        .{ .session_id = 25, .present = 0, .idx = 0 },
    }) |orig| {
        const framed = try protocol.encodeFrame(alloc, .search_selected, orig);
        defer alloc.free(framed);
        const tag = try feedOneByteAtATime(alloc, framed, &payload);
        try testing.expectEqual(protocol.FrameType.search_selected, tag);
        const dec = try protocol.SearchSelected.decode(alloc, payload.items);
        try testing.expectEqual(orig, dec);
    }

    // GridFrame: build a real Snapshot, wrap, partial-read, decode, Snapshot.eql.
    {
        var term = try terminalpkg.Terminal.init(alloc, .{ .cols = 12, .rows = 4 });
        defer term.deinit(alloc);
        try term.printString("abc 123");
        term.carriageReturn();
        try term.linefeed();
        try term.printString("e\u{0301}!"); // grapheme

        var rs: RenderStateCore = .empty;
        defer rs.deinit(alloc);
        try rs.update(alloc, &term);

        var snap = try RenderState.Snapshot.fromRenderState(alloc, &rs);
        defer snap.deinit(alloc);

        const gf: protocol.GridFrame = .{ .session_id = 42, .snapshot = snap };
        const framed = try protocol.encodeFrame(alloc, .grid_frame, gf);
        defer alloc.free(framed);
        const tag = try feedOneByteAtATime(alloc, framed, &payload);
        try testing.expectEqual(protocol.FrameType.grid_frame, tag);
        var dec = try protocol.GridFrame.decode(alloc, payload.items);
        defer dec.deinit(alloc);
        try testing.expectEqual(@as(u64, 42), dec.session_id);
        try testing.expect(snap.eql(dec.snapshot));
    }

    // Slice 3c: Hover (GUI->host).
    {
        const mods = inputpkg.ctrlOrSuper(.{});
        const orig: protocol.Hover = .{
            .session_id = 77,
            .viewport_x = 13,
            .viewport_y = 4,
            .mods = mods.int(),
            .present = true,
        };
        const framed = try protocol.encodeFrame(alloc, .hover, orig);
        defer alloc.free(framed);
        const tag = try feedOneByteAtATime(alloc, framed, &payload);
        try testing.expectEqual(protocol.FrameType.hover, tag);
        const decoded = try protocol.Hover.decode(alloc, payload.items);
        try testing.expectEqual(orig, decoded);
        // The mods byte round-trips back to the same Mods value.
        const back: inputpkg.Mods = @bitCast(decoded.mods);
        try testing.expect(back.equal(mods));
    }

    // Slice 3c: LinkFrame (host->GUI), non-empty + empty.
    {
        const cells = [_]protocol.LinkFrame.Cell{
            .{ .x = 0, .y = 0 },
            .{ .x = 5, .y = 2 },
            .{ .x = 6, .y = 2 },
        };
        const orig: protocol.LinkFrame = .{ .session_id = 9, .cells = &cells };
        const framed = try protocol.encodeFrame(alloc, .link_frame, orig);
        defer alloc.free(framed);
        const tag = try feedOneByteAtATime(alloc, framed, &payload);
        try testing.expectEqual(protocol.FrameType.link_frame, tag);
        var decoded = try protocol.LinkFrame.decode(alloc, payload.items);
        defer decoded.deinit(alloc);
        try testing.expectEqual(@as(u64, 9), decoded.session_id);
        try testing.expectEqual(@as(usize, 3), decoded.cells.len);
        try testing.expectEqual(cells[0], decoded.cells[0]);
        try testing.expectEqual(cells[1], decoded.cells[1]);
        try testing.expectEqual(cells[2], decoded.cells[2]);
    }
    {
        const orig: protocol.LinkFrame = .{ .session_id = 9, .cells = &.{} };
        const framed = try protocol.encodeFrame(alloc, .link_frame, orig);
        defer alloc.free(framed);
        const tag = try feedOneByteAtATime(alloc, framed, &payload);
        try testing.expectEqual(protocol.FrameType.link_frame, tag);
        var decoded = try protocol.LinkFrame.decode(alloc, payload.items);
        defer decoded.deinit(alloc);
        try testing.expectEqual(@as(usize, 0), decoded.cells.len);
    }

    // --- Slice 7: scroll-via-host frames. ---

    // ScrollViewport: top / bottom / delta (positive + negative), each
    // round-tripping the core ScrollViewport union via fromTarget/toTarget.
    {
        const targets = [_]terminalpkg.Terminal.ScrollViewport{
            .top,
            .bottom,
            .{ .delta = 25 },
            .{ .delta = -300 },
        };
        for (targets) |t| {
            const orig = protocol.ScrollViewport.fromTarget(77, t);
            const framed = try protocol.encodeFrame(alloc, .scroll_viewport, orig);
            defer alloc.free(framed);
            const tag = try feedOneByteAtATime(alloc, framed, &payload);
            try testing.expectEqual(protocol.FrameType.scroll_viewport, tag);
            const dec = try protocol.ScrollViewport.decode(alloc, payload.items);
            try testing.expectEqual(orig, dec);
            try testing.expectEqual(@as(u64, 77), dec.session_id);
            // The recovered union must equal the original target.
            const got = dec.toTarget().?;
            try testing.expectEqual(t, got);
        }
    }
    // ScrollViewport: an unknown kind byte decodes but toTarget() yields null
    // (drop, not panic) — guards the host dispatch against a desynced peer.
    {
        const bad: protocol.ScrollViewport = .{ .session_id = 1, .kind = 99, .delta = 0 };
        const framed = try protocol.encodeFrame(alloc, .scroll_viewport, bad);
        defer alloc.free(framed);
        const tag = try feedOneByteAtATime(alloc, framed, &payload);
        try testing.expectEqual(protocol.FrameType.scroll_viewport, tag);
        const dec = try protocol.ScrollViewport.decode(alloc, payload.items);
        try testing.expectEqual(@as(?terminalpkg.Terminal.ScrollViewport, null), dec.toTarget());
    }

    // JumpToPrompt: positive + negative deltas.
    for ([_]i64{ 1, -1, 5, -42 }) |d| {
        const orig: protocol.JumpToPrompt = .{ .session_id = 13, .delta = d };
        const framed = try protocol.encodeFrame(alloc, .jump_to_prompt, orig);
        defer alloc.free(framed);
        const tag = try feedOneByteAtATime(alloc, framed, &payload);
        try testing.expectEqual(protocol.FrameType.jump_to_prompt, tag);
        const dec = try protocol.JumpToPrompt.decode(alloc, payload.items);
        try testing.expectEqual(orig, dec);
    }
}

test "host scroll_viewport repins the host terminal -> next captured GridFrame differs (Slice 7)" {
    const alloc = testing.allocator;

    // Synchronous host-side test (no IO thread / no child): drive the host
    // terminal directly, then exercise the EXACT scroll the Server dispatch +
    // Termio/Exec backend apply on the host (decode a scroll_viewport frame ->
    // toTarget() -> terminal.scrollViewport), and assert the captured snapshot's
    // viewport changes. This is the host half of the contract: a scroll_viewport
    // frame scrolls the host terminal and the next GridFrame reflects a
    // different viewport.
    const session = try Session.create(alloc, .{ .cols = 20, .rows = 10 });
    defer session.destroy();

    // Fill well past the 10-row viewport so there's real scrollback: 30 lines
    // "L00".."L29". The viewport then shows the LAST 10 (L20..L29); the top of
    // scrollback is L00.
    {
        session.render_mutex.lock();
        defer session.render_mutex.unlock();
        var i: usize = 0;
        while (i < 30) : (i += 1) {
            var lb: [8]u8 = undefined;
            const line = try std.fmt.bufPrint(&lb, "L{d:0>2}", .{i});
            try session.io.terminal.printString(line);
            session.io.terminal.carriageReturn();
            try session.io.terminal.linefeed();
        }
    }

    // Baseline snapshot: viewport at the bottom -> shows newest, NOT the oldest.
    {
        session.render_mutex.lock();
        defer session.render_mutex.unlock();
        var snap = try session.captureSnapshotLocked(alloc);
        defer snap.deinit(alloc);
        try testing.expect(try snapshotContainsMarker(alloc, &snap, "L29"));
        try testing.expect(!try snapshotContainsMarker(alloc, &snap, "L00"));
    }

    // Apply a scroll_viewport(top) frame EXACTLY as the host path does: decode
    // the wire frame, recover the union via toTarget(), and scroll the host
    // terminal (Termio.scrollViewport -> Exec.scrollViewport ultimately calls
    // terminal.scrollViewport under the render mutex).
    {
        const orig = protocol.ScrollViewport.fromTarget(1, .top);
        const framed = try protocol.encodeFrame(alloc, .scroll_viewport, orig);
        defer alloc.free(framed);
        var rdr: protocol.FrameReader = .{};
        defer rdr.deinit(alloc);
        try rdr.push(alloc, framed);
        const f = (try rdr.next(alloc)).?;
        const dec = try protocol.ScrollViewport.decode(alloc, f.payload);
        const target = dec.toTarget().?;

        session.render_mutex.lock();
        defer session.render_mutex.unlock();
        session.io.terminal.scrollViewport(target);
    }

    // After scrolling to the top of scrollback the captured viewport must now
    // show the OLDEST content and no longer the newest -> a different viewport.
    {
        session.render_mutex.lock();
        defer session.render_mutex.unlock();
        var snap = try session.captureSnapshotLocked(alloc);
        defer snap.deinit(alloc);
        try testing.expect(try snapshotContainsMarker(alloc, &snap, "L00"));
        try testing.expect(!try snapshotContainsMarker(alloc, &snap, "L29"));
    }
}

test "protocol SelectionDrag/Clear/Text round-trip (host client) Slice B1" {
    const alloc = testing.allocator;

    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(alloc);

    // SelectionDrag: fixed-width, all fields incl. rectangle flag.
    {
        const orig: protocol.SelectionDrag = .{
            .session_id = 77,
            .anchor_x = 3,
            .anchor_y = 1,
            .head_x = 9,
            .head_y = 4,
            .rectangle = true,
        };
        const framed = try protocol.encodeFrame(alloc, .selection_drag, orig);
        defer alloc.free(framed);
        const tag = try feedOneByteAtATime(alloc, framed, &payload);
        try testing.expectEqual(protocol.FrameType.selection_drag, tag);
        const dec = try protocol.SelectionDrag.decode(alloc, payload.items);
        try testing.expectEqual(orig, dec);
    }

    // SelectionClear: bare session id.
    {
        const orig: protocol.SelectionClear = .{ .session_id = 88 };
        const framed = try protocol.encodeFrame(alloc, .selection_clear, orig);
        defer alloc.free(framed);
        const tag = try feedOneByteAtATime(alloc, framed, &payload);
        try testing.expectEqual(protocol.FrameType.selection_clear, tag);
        const dec = try protocol.SelectionClear.decode(alloc, payload.items);
        try testing.expectEqual(orig.session_id, dec.session_id);
    }

    // SelectionText present=true (text is the trailing field).
    {
        const orig: protocol.SelectionText = .{
            .session_id = 5,
            .present = true,
            .text = "hello selection",
        };
        const framed = try protocol.encodeFrame(alloc, .selection_text, orig);
        defer alloc.free(framed);
        const tag = try feedOneByteAtATime(alloc, framed, &payload);
        try testing.expectEqual(protocol.FrameType.selection_text, tag);
        var dec = try protocol.SelectionText.decode(alloc, payload.items);
        defer dec.deinit(alloc);
        try testing.expectEqual(orig.session_id, dec.session_id);
        try testing.expectEqual(true, dec.present);
        try testing.expectEqualStrings(orig.text, dec.text);
    }

    // SelectionText cleared (present=false, empty text) round-trips.
    {
        const orig: protocol.SelectionText = .{ .session_id = 6, .present = false };
        const framed = try protocol.encodeFrame(alloc, .selection_text, orig);
        defer alloc.free(framed);
        const tag = try feedOneByteAtATime(alloc, framed, &payload);
        try testing.expectEqual(protocol.FrameType.selection_text, tag);
        var dec = try protocol.SelectionText.decode(alloc, payload.items);
        defer dec.deinit(alloc);
        try testing.expectEqual(@as(u64, 6), dec.session_id);
        try testing.expectEqual(false, dec.present);
        try testing.expectEqualStrings("", dec.text);
    }
}

// Captures the most recent on_selection_text callback for the host selectDrag
// test. Single-threaded synchronous test, so a plain struct is sufficient.
const SelTextCapture = struct {
    present: bool = false,
    text: std.ArrayListUnmanaged(u8) = .empty,
    fired: bool = false,

    fn cb(ctx: *anyopaque, _: *Session, present: bool, text: []const u8) void {
        const self: *SelTextCapture = @ptrCast(@alignCast(ctx));
        self.present = present;
        self.fired = true;
        self.text.clearRetainingCapacity();
        // testing.allocator is fine here; deinit below frees it.
        self.text.appendSlice(testing.allocator, text) catch unreachable;
    }
};

test "host selectDrag selects the right cells -> row.selection + selectionString -> selection_text (client) Slice B1" {
    const alloc = testing.allocator;

    const session = try Session.create(alloc, .{ .cols = 20, .rows = 5 });
    defer session.destroy();

    // Write known content on the first row so we can assert the selected text.
    {
        session.render_mutex.lock();
        defer session.render_mutex.unlock();
        try session.io.terminal.printString("ABCDEFGHIJ");
    }

    var capture: SelTextCapture = .{};
    defer capture.text.deinit(alloc);
    session.on_selection_text_ctx = &capture;
    session.on_selection_text = SelTextCapture.cb;

    // Drag-select columns 2..5 (inclusive) of viewport row 0 -> "CDEF".
    try session.selectDrag(.{ .x = 2, .y = 0 }, .{ .x = 5, .y = 0 }, false);

    // selectDrag STAGES the selection text (findings SEL-1 / SEL-LOCK-1); it does
    // NOT fire the broadcast callback synchronously under registry_mutex anymore.
    // The owning thread's renderTick drains + emits it off the app-global lock.
    try testing.expect(!capture.fired);
    try testing.expect(session.sel_text_dirty);

    // (a) renderTick drains the staged text and fires the callback off
    // registry_mutex, alongside the forced GridFrame (selection_dirty).
    _ = try session.renderTick();
    try testing.expect(capture.fired);
    try testing.expect(capture.present);
    try testing.expectEqualStrings("CDEF", capture.text.items);
    // Staging consumed: the pending flag/text are cleared after the drain.
    try testing.expect(!session.sel_text_dirty);
    try testing.expect(session.sel_text == null);

    // (b) The captured Snapshot carries row.selection on row 0 spanning [2,5].
    {
        session.render_mutex.lock();
        defer session.render_mutex.unlock();
        var snap = try session.captureSnapshotLocked(alloc);
        defer snap.deinit(alloc);
        const sel = snap.row_data[0].selection;
        try testing.expect(sel != null);
        try testing.expectEqual(@as(u16, 2), sel.?[0]);
        try testing.expectEqual(@as(u16, 5), sel.?[1]);
    }

    // selection_dirty was set so a render tick would force-push the frame.
    // (Verified indirectly: the snapshot above already carries the selection.)

    // Clearing drops the selection and stages a cleared selection_text; the
    // renderTick drain then emits it (present=false) off registry_mutex.
    capture.fired = false;
    try session.selectClear();
    try testing.expect(!capture.fired);
    try testing.expect(session.sel_text_dirty);
    _ = try session.renderTick();
    try testing.expect(capture.fired);
    try testing.expect(!capture.present);
    {
        session.render_mutex.lock();
        defer session.render_mutex.unlock();
        var snap = try session.captureSnapshotLocked(alloc);
        defer snap.deinit(alloc);
        try testing.expect(snap.row_data[0].selection == null);
    }
}

test "protocol SelectionPoint round-trip + toMode + bounds (host client) Slice B2" {
    const alloc = testing.allocator;

    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(alloc);

    // Fixed-width round-trip across all three granularity modes.
    inline for (.{
        protocol.SelectionPoint.mode_word,
        protocol.SelectionPoint.mode_line,
        protocol.SelectionPoint.mode_all,
    }) |mode| {
        const orig: protocol.SelectionPoint = .{
            .session_id = 42,
            .x = 7,
            .y = 3,
            .mode = mode,
        };
        const framed = try protocol.encodeFrame(alloc, .selection_point, orig);
        defer alloc.free(framed);
        const tag = try feedOneByteAtATime(alloc, framed, &payload);
        try testing.expectEqual(protocol.FrameType.selection_point, tag);
        const dec = try protocol.SelectionPoint.decode(alloc, payload.items);
        try testing.expectEqual(orig, dec);
        try testing.expect(dec.toMode() != null);
    }

    // toMode() returns null for an unknown mode byte (desynced/garbage peer) so
    // the dispatcher drops it rather than panicking on an illegal enum cast.
    {
        const bad: protocol.SelectionPoint = .{ .session_id = 1, .mode = 99 };
        try testing.expect(bad.toMode() == null);
    }

    // decode of a too-short payload errors (no panic): drop the 1-byte mode.
    {
        const orig: protocol.SelectionPoint = .{ .session_id = 9, .x = 1, .y = 2, .mode = 0 };
        const framed = try protocol.encodeFrame(alloc, .selection_point, orig);
        defer alloc.free(framed);
        const tag = try feedOneByteAtATime(alloc, framed, &payload);
        try testing.expectEqual(protocol.FrameType.selection_point, tag);
        // Lop off the trailing mode byte -> short payload.
        const truncated = payload.items[0 .. payload.items.len - 1];
        try testing.expectError(error.EndOfStream, protocol.SelectionPoint.decode(alloc, truncated));
    }
}

test "protocol ClearScreen round-trip + bounds (host client) Phase D" {
    const alloc = testing.allocator;

    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(alloc);

    // history true + false both round-trip (fixed-width [u64][u8]).
    inline for (.{ true, false }) |hist| {
        const orig: protocol.ClearScreen = .{ .session_id = 123, .history = hist };
        const framed = try protocol.encodeFrame(alloc, .clear_screen, orig);
        defer alloc.free(framed);
        const tag = try feedOneByteAtATime(alloc, framed, &payload);
        try testing.expectEqual(protocol.FrameType.clear_screen, tag);
        const dec = try protocol.ClearScreen.decode(alloc, payload.items);
        try testing.expectEqual(orig, dec);
    }

    // A too-short payload (missing the history byte) errors rather than panics.
    {
        const orig: protocol.ClearScreen = .{ .session_id = 7, .history = true };
        const framed = try protocol.encodeFrame(alloc, .clear_screen, orig);
        defer alloc.free(framed);
        const tag = try feedOneByteAtATime(alloc, framed, &payload);
        try testing.expectEqual(protocol.FrameType.clear_screen, tag);
        const truncated = payload.items[0 .. payload.items.len - 1];
        try testing.expectError(error.EndOfStream, protocol.ClearScreen.decode(alloc, truncated));
    }

    // Reset: bare session id round-trips.
    {
        const orig: protocol.Reset = .{ .session_id = 555 };
        const framed = try protocol.encodeFrame(alloc, .reset, orig);
        defer alloc.free(framed);
        const tag = try feedOneByteAtATime(alloc, framed, &payload);
        try testing.expectEqual(protocol.FrameType.reset, tag);
        const dec = try protocol.Reset.decode(alloc, payload.items);
        try testing.expectEqual(orig.session_id, dec.session_id);
    }

    // AtPrompt: at_prompt true + false round-trip; short payload errors.
    inline for (.{ true, false }) |ap| {
        const orig: protocol.AtPrompt = .{ .session_id = 909, .at_prompt = ap };
        const framed = try protocol.encodeFrame(alloc, .at_prompt, orig);
        defer alloc.free(framed);
        const tag = try feedOneByteAtATime(alloc, framed, &payload);
        try testing.expectEqual(protocol.FrameType.at_prompt, tag);
        const dec = try protocol.AtPrompt.decode(alloc, payload.items);
        try testing.expectEqual(orig, dec);
    }
    {
        const orig: protocol.AtPrompt = .{ .session_id = 1, .at_prompt = true };
        const framed = try protocol.encodeFrame(alloc, .at_prompt, orig);
        defer alloc.free(framed);
        const tag = try feedOneByteAtATime(alloc, framed, &payload);
        try testing.expectEqual(protocol.FrameType.at_prompt, tag);
        const truncated = payload.items[0 .. payload.items.len - 1];
        try testing.expectError(error.EndOfStream, protocol.AtPrompt.decode(alloc, truncated));
    }
}

// Captures the most recent on_at_prompt callback for the Phase D at-prompt test.
const AtPromptCapture = struct {
    fired: bool = false,
    value: bool = false,

    fn cb(ctx: *anyopaque, _: *Session, at_prompt: bool) void {
        const self: *AtPromptCapture = @ptrCast(@alignCast(ctx));
        self.fired = true;
        self.value = at_prompt;
    }
};

test "host on_at_prompt fires only on a flip of cursorIsAtPrompt (Phase D)" {
    const alloc = testing.allocator;

    const session = try Session.create(alloc, .{ .cols = 20, .rows = 5 });
    defer session.destroy();

    var cap: AtPromptCapture = .{};
    session.on_at_prompt_ctx = &cap;
    session.on_at_prompt = AtPromptCapture.cb;

    // First tick: a fresh terminal is NOT at a prompt (semantic_content=.output).
    // prev_at_prompt is null, so the first tick always fires (seeds the GUI).
    _ = try session.renderTick();
    try testing.expect(cap.fired);
    try testing.expectEqual(false, cap.value);

    // No state change -> the bit doesn't flip -> no push (no per-tick spam).
    cap.fired = false;
    _ = try session.renderTick();
    try testing.expect(!cap.fired);

    // Mark the cursor as being at a prompt (what shell-integration OSC 133 does
    // on the real host terminal). The next tick observes the flip and fires(true).
    {
        session.render_mutex.lock();
        defer session.render_mutex.unlock();
        session.io.terminal.screens.active.cursor.semantic_content = .prompt;
    }
    _ = try session.renderTick();
    try testing.expect(cap.fired);
    try testing.expectEqual(true, cap.value);

    // Flip back to output (a command starts running) -> fires(false).
    cap.fired = false;
    {
        session.render_mutex.lock();
        defer session.render_mutex.unlock();
        session.io.terminal.screens.active.cursor.semantic_content = .output;
    }
    _ = try session.renderTick();
    try testing.expect(cap.fired);
    try testing.expectEqual(false, cap.value);
}

test "host selectPoint word + line snap on the real terminal -> selection_text (client) Slice B2" {
    const alloc = testing.allocator;

    const session = try Session.create(alloc, .{ .cols = 20, .rows = 5 });
    defer session.destroy();

    // "hello world": cols 0-4 "hello", 5 space, 6-10 "world".
    {
        session.render_mutex.lock();
        defer session.render_mutex.unlock();
        try session.io.terminal.printString("hello world");
    }

    var capture: SelTextCapture = .{};
    defer capture.text.deinit(alloc);
    session.on_selection_text_ctx = &capture;
    session.on_selection_text = SelTextCapture.cb;

    // WORD: a click at col 8 (inside "world") snaps to the whole word.
    try session.selectPoint(8, 0, protocol.SelectionPoint.mode_word);
    // Staged, not broadcast synchronously (SEL-1 / SEL-LOCK-1) — same as selectDrag.
    try testing.expect(!capture.fired);
    try testing.expect(session.sel_text_dirty);
    _ = try session.renderTick();
    try testing.expect(capture.fired);
    try testing.expect(capture.present);
    try testing.expectEqualStrings("world", capture.text.items);
    // Staging consumed after the drain.
    try testing.expect(!session.sel_text_dirty);
    try testing.expect(session.sel_text == null);
    // The viewport highlight rides row.selection on row 0.
    {
        session.render_mutex.lock();
        defer session.render_mutex.unlock();
        var snap = try session.captureSnapshotLocked(alloc);
        defer snap.deinit(alloc);
        const sel = snap.row_data[0].selection;
        try testing.expect(sel != null);
        try testing.expectEqual(@as(u16, 6), sel.?[0]);
        try testing.expectEqual(@as(u16, 10), sel.?[1]);
    }

    // LINE: a click anywhere on row 0 snaps to the whole line; the text contains
    // the full line content.
    capture.fired = false;
    try session.selectPoint(0, 0, protocol.SelectionPoint.mode_line);
    _ = try session.renderTick();
    try testing.expect(capture.fired);
    try testing.expect(capture.present);
    try testing.expect(std.mem.indexOf(u8, capture.text.items, "hello world") != null);
}

test "host selectPoint all spans SCROLLBACK -> copy text without R3 (client) Slice B2" {
    const alloc = testing.allocator;

    // Small viewport, lots of lines -> the oldest lines live in scrollback,
    // OUTSIDE the viewport mirror. This proves select-all COPY works without R3
    // (the host's selectAll + selectionString cover the full screen); only the
    // HIGHLIGHT is viewport-limited (deferred).
    const session = try Session.create(alloc, .{ .cols = 20, .rows = 4 });
    defer session.destroy();
    {
        session.render_mutex.lock();
        defer session.render_mutex.unlock();
        var i: usize = 0;
        while (i < 30) : (i += 1) {
            var lb: [8]u8 = undefined;
            const line = try std.fmt.bufPrint(&lb, "L{d:0>2}", .{i});
            try session.io.terminal.printString(line);
            session.io.terminal.carriageReturn();
            try session.io.terminal.linefeed();
        }
    }

    var capture: SelTextCapture = .{};
    defer capture.text.deinit(alloc);
    session.on_selection_text_ctx = &capture;
    session.on_selection_text = SelTextCapture.cb;

    // mode_all ignores x/y; selects the full screen incl scrollback.
    try session.selectPoint(0, 0, protocol.SelectionPoint.mode_all);
    _ = try session.renderTick();
    try testing.expect(capture.fired);
    try testing.expect(capture.present);
    // The oldest line (L00) is in SCROLLBACK (viewport shows only the last 4),
    // yet it is present in the select-all copy text. And a recent line too.
    try testing.expect(std.mem.indexOf(u8, capture.text.items, "L00") != null);
    try testing.expect(std.mem.indexOf(u8, capture.text.items, "L29") != null);
}

test "host SurfaceEvent frame round-trip across representative variants (Slice 6)" {
    // encode -> partial-read -> decode -> equal, across a void variant, a bool,
    // an enum, the set_title fixed buffer, a WriteReq-bearing one (pwd_change),
    // color_change, and progress_report. Mirrors the protocol round-trip harness.
    const alloc = testing.allocator;
    const SurfaceEvent = protocol.SurfaceEvent;

    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(alloc);

    // Helper: encode an apprt.surface.Message into a SurfaceEvent, partial-read,
    // decode, and return the owned decoded event (caller deinits).
    const H = struct {
        fn roundtrip(
            a: std.mem.Allocator,
            buf: *std.ArrayList(u8),
            session_id: u64,
            msg: apprt.surface.Message,
        ) !SurfaceEvent {
            const ev = try SurfaceEvent.fromMessage(session_id, &msg);
            const framed = try protocol.encodeFrame(a, .surface_event, ev);
            defer a.free(framed);
            const tag = try feedOneByteAtATime(a, framed, buf);
            try testing.expectEqual(protocol.FrameType.surface_event, tag);
            return try SurfaceEvent.decode(a, buf.items);
        }
    };

    // ring_bell (void).
    {
        var dec = try H.roundtrip(alloc, &payload, 1, .{ .ring_bell = {} });
        defer dec.deinit(alloc);
        try testing.expectEqual(@as(u64, 1), dec.session_id);
        try testing.expect(dec.payload == .ring_bell);
    }

    // start_command (void).
    {
        var dec = try H.roundtrip(alloc, &payload, 2, .{ .start_command = {} });
        defer dec.deinit(alloc);
        try testing.expect(dec.payload == .start_command);
    }

    // password_input (bool).
    {
        var dec = try H.roundtrip(alloc, &payload, 3, .{ .password_input = true });
        defer dec.deinit(alloc);
        try testing.expectEqual(true, dec.payload.password_input);
    }

    // stop_command (?u8): present + null.
    {
        var dec = try H.roundtrip(alloc, &payload, 4, .{ .stop_command = 42 });
        defer dec.deinit(alloc);
        try testing.expectEqual(@as(?u8, 42), dec.payload.stop_command);
    }
    {
        var dec = try H.roundtrip(alloc, &payload, 4, .{ .stop_command = null });
        defer dec.deinit(alloc);
        try testing.expectEqual(@as(?u8, null), dec.payload.stop_command);
    }

    // set_title ([256]u8 fixed buffer): NUL-terminated prefix preserved exactly.
    {
        var title: [256]u8 = [_]u8{0} ** 256;
        const text = "hello title";
        @memcpy(title[0..text.len], text);
        var dec = try H.roundtrip(alloc, &payload, 5, .{ .set_title = title });
        defer dec.deinit(alloc);
        try testing.expectEqualSlices(u8, &title, &dec.payload.set_title);
    }

    // report_title (enum).
    {
        var dec = try H.roundtrip(alloc, &payload, 6, .{ .report_title = .csi_21_t });
        defer dec.deinit(alloc);
        try testing.expectEqual(apprt.surface.Message.ReportTitleStyle.csi_21_t, dec.payload.report_title);
    }

    // set_mouse_shape (enum(c_int)).
    {
        var dec = try H.roundtrip(alloc, &payload, 7, .{ .set_mouse_shape = .pointer });
        defer dec.deinit(alloc);
        try testing.expectEqual(terminalpkg.MouseShape.pointer, dec.payload.set_mouse_shape);
    }

    // desktop_notification (two fixed NUL-terminated buffers).
    {
        var t: [63:0]u8 = [_:0]u8{0} ** 63;
        var b: [255:0]u8 = [_:0]u8{0} ** 255;
        @memcpy(t[0..5], "Title");
        @memcpy(b[0..4], "Body");
        var dec = try H.roundtrip(alloc, &payload, 8, .{ .desktop_notification = .{ .title = t, .body = b } });
        defer dec.deinit(alloc);
        try testing.expectEqualSlices(u8, t[0 .. t.len + 1], dec.payload.desktop_notification.title[0 .. t.len + 1]);
        try testing.expectEqualSlices(u8, b[0 .. b.len + 1], dec.payload.desktop_notification.body[0 .. b.len + 1]);
    }

    // color_change (Target + RGB), across all three Target shapes.
    {
        const cases = [_]terminalpkg.osc.color.Target{
            .{ .palette = 7 },
            .{ .special = .bold },
            .{ .dynamic = .cursor },
        };
        for (cases) |target| {
            const rgb: terminalpkg.color.RGB = .{ .r = 0x12, .g = 0x34, .b = 0x56 };
            var dec = try H.roundtrip(alloc, &payload, 9, .{ .color_change = .{ .target = target, .color = rgb } });
            defer dec.deinit(alloc);
            try testing.expectEqual(target, dec.payload.color_change.target);
            try testing.expect(rgb.eql(dec.payload.color_change.color));
        }
    }

    // progress_report (State enum + ?u8): present + null.
    {
        var dec = try H.roundtrip(alloc, &payload, 10, .{ .progress_report = .{ .state = .set, .progress = 73 } });
        defer dec.deinit(alloc);
        try testing.expectEqual(terminalpkg.osc.Command.ProgressReport.State.set, dec.payload.progress_report.state);
        try testing.expectEqual(@as(?u8, 73), dec.payload.progress_report.progress);
    }
    {
        var dec = try H.roundtrip(alloc, &payload, 10, .{ .progress_report = .{ .state = .remove, .progress = null } });
        defer dec.deinit(alloc);
        try testing.expectEqual(@as(?u8, null), dec.payload.progress_report.progress);
    }

    // pwd_change (WriteReq byte slice): small + large (alloc) reconstruct paths.
    {
        const pwd = "/Users/ramon/git/ghostty";
        const req = try apprt.surface.Message.WriteReq.init(alloc, @as([]const u8, pwd));
        defer req.deinit();
        var dec = try H.roundtrip(alloc, &payload, 11, .{ .pwd_change = req });
        defer dec.deinit(alloc);
        try testing.expectEqualStrings(pwd, dec.payload.pwd_change);
        // toMessage reconstructs a small WriteReq (<=255) carrying the same bytes.
        const reinjected = try dec.toMessage(alloc);
        try testing.expectEqualStrings(pwd, reinjected.pwd_change.slice());
    }
    {
        const big = "x" ** 600; // forces the .alloc reconstruct path
        const req = try apprt.surface.Message.WriteReq.init(alloc, @as([]const u8, big));
        defer req.deinit();
        var dec = try H.roundtrip(alloc, &payload, 11, .{ .pwd_change = req });
        defer dec.deinit(alloc);
        try testing.expectEqualStrings(big, dec.payload.pwd_change);
        var reinjected = try dec.toMessage(alloc);
        defer reinjected.pwd_change.deinit();
        try testing.expect(reinjected.pwd_change == .alloc);
        try testing.expectEqualStrings(big, reinjected.pwd_change.slice());
    }

    // clipboard_write (Clipboard enum + WriteReq bytes).
    {
        const data = "clipboard payload";
        const req = try apprt.surface.Message.WriteReq.init(alloc, @as([]const u8, data));
        defer req.deinit();
        var dec = try H.roundtrip(alloc, &payload, 12, .{ .clipboard_write = .{
            .clipboard_type = .selection,
            .req = req,
        } });
        defer dec.deinit(alloc);
        try testing.expectEqual(apprt.Clipboard.selection, dec.payload.clipboard_write.clipboard_type);
        try testing.expectEqualStrings(data, dec.payload.clipboard_write.bytes);
    }

    // clipboard_read (Clipboard enum).
    {
        var dec = try H.roundtrip(alloc, &payload, 13, .{ .clipboard_read = .standard });
        defer dec.deinit(alloc);
        try testing.expectEqual(apprt.Clipboard.standard, dec.payload.clipboard_read);
    }
}

test "host SurfaceEvent fromMessage rejects EXCLUDED variants (Slice 6)" {
    // The excluded set must NOT be forwarded (each has a dedicated path or is
    // GUI-/config-side). fromMessage returns error.NotForwarded so the host drain
    // drops them rather than framing them.
    const SurfaceEvent = protocol.SurfaceEvent;
    const excluded = [_]apprt.surface.Message{
        .{ .close = {} },
        .{ .child_exited = .{ .exit_code = 0, .runtime_ms = 0 } },
        .{ .renderer_health = .healthy },
        .{ .present_surface = {} },
        .{ .selection_scroll_tick = true },
        .{ .search_total = 3 },
        .{ .search_selected = 1 },
    };
    for (excluded) |msg| {
        try testing.expectError(error.NotForwarded, SurfaceEvent.fromMessage(1, &msg));
    }
}

// --- Slice 6 host-side forward (drain -> on_surface_event -> surface_event) ---

const SurfaceForwardCapture = struct {
    /// The last forwarded message, copied as a freshly-built SurfaceEvent (no
    /// owned bytes for the variants this test uses, so no deinit needed).
    last: ?protocol.SurfaceEvent = null,
    count: usize = 0,

    fn cb(ctx: *anyopaque, _: *Session, msg: *const apprt.surface.Message) void {
        const self: *SurfaceForwardCapture = @ptrCast(@alignCast(ctx));
        self.count += 1;
        // Mirror the Server's onSurfaceEvent: build the SurfaceEvent from the
        // forwarded message. EXCLUDED variants would error.NotForwarded, but the
        // drain only invokes this for non-child_exited messages and the test
        // pushes a forwarded variant.
        self.last = protocol.SurfaceEvent.fromMessage(7, msg) catch null;
    }
};

test "host drain forwards a non-child_exited surface message as a surface_event (Slice 6)" {
    // Push a forwardable surface message (ring_bell) onto the app queue, drive a
    // render tick (which drains the queue), and assert the Session's
    // on_surface_event hook fired with a message that builds a surface_event
    // frame round-tripping to the same variant. This is the host half of the
    // SurfaceEvent channel — the same drain path child_exited uses, but for the
    // general forwarded set.
    const alloc = testing.allocator;

    const session = try Session.create(alloc, .{ .cols = 20, .rows = 5 });
    defer session.destroy();

    var cap: SurfaceForwardCapture = .{};
    session.on_surface_event_ctx = &cap;
    session.on_surface_event = SurfaceForwardCapture.cb;

    // Enqueue a forwardable surface message exactly as the StreamHandler would
    // (a ring_bell). The surface pointer is stored only (never dereferenced by
    // the drain); use the Session's own heap surface.
    _ = session.app_queue.push(.{ .surface_message = .{
        .surface = session.surface,
        .message = .{ .ring_bell = {} },
    } }, .{ .forever = {} });

    // Drive a tick; the drain runs and invokes on_surface_event for the message.
    _ = try session.renderTick();

    try testing.expectEqual(@as(usize, 1), cap.count);
    try testing.expect(cap.last != null);
    try testing.expectEqual(@as(u64, 7), cap.last.?.session_id);
    try testing.expect(cap.last.?.payload == .ring_bell);

    // And the built event frames + round-trips back to ring_bell.
    const framed = try protocol.encodeFrame(alloc, .surface_event, cap.last.?);
    defer alloc.free(framed);
    var payload2: std.ArrayList(u8) = .empty;
    defer payload2.deinit(alloc);
    const tag = try feedOneByteAtATime(alloc, framed, &payload2);
    try testing.expectEqual(protocol.FrameType.surface_event, tag);
    var dec = try protocol.SurfaceEvent.decode(alloc, payload2.items);
    defer dec.deinit(alloc);
    try testing.expect(dec.payload == .ring_bell);
}

test "host drain does NOT forward child_exited over surface_event (no double-delivery, Slice 6)" {
    // child_exited keeps its DEDICATED ChildExited frame + render-stop path; it
    // must NOT also be handed to on_surface_event. Wire BOTH hooks and assert the
    // child-exit hook fires while the surface-event hook does NOT.
    const alloc = testing.allocator;

    const session = try Session.create(alloc, .{ .cols = 20, .rows = 5 });
    defer session.destroy();

    var cap: SurfaceForwardCapture = .{};
    session.on_surface_event_ctx = &cap;
    session.on_surface_event = SurfaceForwardCapture.cb;

    const ChildCapture = struct {
        fired: bool = false,
        fn cb(ctx: *anyopaque, _: *Session, _: u32, _: u64) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.fired = true;
        }
    };
    var child_cap: ChildCapture = .{};
    session.on_child_exited_ctx = &child_cap;
    session.on_child_exited = ChildCapture.cb;

    _ = session.app_queue.push(.{ .surface_message = .{
        .surface = session.surface,
        .message = .{ .child_exited = .{ .exit_code = 0, .runtime_ms = 0 } },
    } }, .{ .forever = {} });

    _ = try session.renderTick();

    // The dedicated child-exit hook fired; the general SurfaceEvent hook did not.
    try testing.expect(child_cap.fired);
    try testing.expectEqual(@as(usize, 0), cap.count);
}

/// Encode a frame and write it to a client fd (BE length prefix + tag + payload).
fn clientSend(
    alloc: std.mem.Allocator,
    fd: posix.socket_t,
    tag: protocol.FrameType,
    frame: anytype,
) !void {
    const bytes = try protocol.encodeFrame(alloc, tag, frame);
    defer alloc.free(bytes);
    var off: usize = 0;
    while (off < bytes.len) {
        off += try posix.write(fd, bytes[off..]);
    }
}

/// Render a Snapshot's full viewport text and return true if it contains the
/// marker. Reuses the Phase-1 row-text concept (codepoint + grapheme).
fn snapshotContainsMarker(
    alloc: std.mem.Allocator,
    snap: *const RenderState.Snapshot,
    marker: []const u8,
) !bool {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(alloc);
    const w = text.writer(alloc);
    var buf: [4]u8 = undefined;
    for (snap.row_data) |row| {
        for (row.cells) |c| {
            const cp = c.raw.content.codepoint;
            if (c.raw.content_tag == .codepoint or c.raw.content_tag == .codepoint_grapheme) {
                if (cp != 0) {
                    if (std.unicode.utf8Encode(@intCast(cp), &buf)) |n| {
                        try w.writeAll(buf[0..n]);
                    } else |_| {}
                }
                for (c.grapheme) |g| {
                    if (std.unicode.utf8Encode(@intCast(g), &buf)) |n| {
                        try w.writeAll(buf[0..n]);
                    } else |_| {}
                }
            }
        }
        try w.writeByte('\n');
    }
    return std.mem.indexOf(u8, text.items, marker) != null;
}

/// A small client-side frame pump: nonblocking-ish read into a FrameReader and
/// return the next decoded frame of `want_tag` within a bounded poll, or null.
const ClientReader = struct {
    reader: protocol.FrameReader = .{},

    fn deinit(self: *ClientReader, alloc: std.mem.Allocator) void {
        self.reader.deinit(alloc);
    }

    /// Pull the next frame of any type. Returns the decoded {tag,payload};
    /// the payload is copied into `out_payload`. Returns null on EOF.
    /// Propagates `error.WouldBlock` when the recv times out (so the caller's
    /// bounded poll loop can retry without hanging on a wiring regression).
    fn next(
        self: *ClientReader,
        alloc: std.mem.Allocator,
        fd: posix.socket_t,
        out_payload: *std.ArrayList(u8),
    ) !?protocol.FrameType {
        var buf: [16 * 1024]u8 = undefined;
        while (true) {
            if (try self.reader.next(alloc)) |f| {
                out_payload.clearRetainingCapacity();
                try out_payload.appendSlice(alloc, f.payload);
                return f.tag;
            }
            const n = try posix.read(fd, &buf); // error.WouldBlock on timeout
            if (n == 0) return null;
            try self.reader.push(alloc, buf[0..n]);
        }
    }
};

/// Set a short recv timeout so a missing frame fails the bounded poll loop
/// (error.WouldBlock) instead of blocking forever.
fn setRecvTimeout(fd: posix.socket_t) void {
    const tv = posix.timeval{ .sec = 0, .usec = 100 * 1000 };
    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
}

/// Bound for the frame-scan loops below: how many `pollNext(tries=4)` rounds to
/// wait for an expected frame. 50 × 4 × 100ms RCVTIMEO ≈ 20s worst case — ample
/// for child-shell echo under heavy parallel build load, yet ~9× below a 180s
/// no-output watchdog. The previous bound (400) allowed ~160s of near-silent
/// looping, which under load tripped the workflow watchdog and masqueraded as a
/// hang; this fails fast with a clear assertion instead.
const FRAME_SCAN_ITERS = 50;

/// Poll up to `tries` recv-timeouts for the next frame; WouldBlock -> retry.
/// Returns the tag (payload in out_payload), or null if EOF / exhausted tries.
fn pollNext(
    rdr: *ClientReader,
    alloc: std.mem.Allocator,
    fd: posix.socket_t,
    out_payload: *std.ArrayList(u8),
    tries: usize,
) !?protocol.FrameType {
    var i: usize = 0;
    while (i < tries) : (i += 1) {
        const r = rdr.next(alloc, fd, out_payload) catch |err| {
            if (err == error.WouldBlock) continue;
            return err;
        };
        return r; // tag or null(EOF)
    }
    return null;
}

test "host socket integration: attach, input, gridframe marker, reattach" {
    const alloc = testing.allocator;

    // Temp AF_UNIX path under the OS temp dir, cleaned up.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);
    const sock_path = try std.fmt.allocPrint(alloc, "{s}/h.sock", .{dir_path});
    defer alloc.free(sock_path);

    // Start the Server.
    const server = try Server.init(alloc, sock_path);
    defer server.deinit();
    try server.start();

    // Connect a REAL client fd.
    const client = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(client);
    try connectUnix(client, sock_path);
    // Bound the test: a recv timeout turns a wiring regression into a failed
    // read (error.WouldBlock -> our poll loop bound) instead of a hang.
    setRecvTimeout(client);

    var rdr: ClientReader = .{};
    defer rdr.deinit(alloc);
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(alloc);

    // Hello handshake.
    try clientSend(alloc, client, .hello, protocol.Hello{
        .identity_bundle_id = "test.client",
    });
    {
        const tag = (try pollNext(&rdr, alloc, client, &payload, 50)).?;
        try testing.expectEqual(protocol.FrameType.hello_ack, tag);
        const ack = try protocol.HelloAck.decode(alloc, payload.items);
        try testing.expectEqual(protocol.PROTOCOL_VERSION_MAJOR, ack.protocol_version_major);
    }

    // Attach (spawn).
    try clientSend(alloc, client, .attach, protocol.Attach{ .session_id = null });
    var session_id: u64 = 0;
    {
        // The Attached frame is sent; GridFrame/ModeFrame may interleave before
        // it from the immediate push, so scan until we see Attached.
        var i: usize = 0;
        var got = false;
        while (i < FRAME_SCAN_ITERS) : (i += 1) {
            const tag = (try pollNext(&rdr, alloc, client, &payload, 4)) orelse continue;
            if (tag == .attached) {
                const a = try protocol.Attached.decode(alloc, payload.items);
                session_id = a.session_id;
                got = true;
                break;
            }
        }
        try testing.expect(got);
        try testing.expect(session_id != 0);
    }

    // Send Input that makes the child echo a known marker.
    const marker = "HELLO_HOST_MARKER";
    try clientSend(alloc, client, .input, protocol.Input{
        .session_id = session_id,
        .bytes = "printf 'HELLO_HOST_MARKER\\n'\n",
    });

    // Read frames until a GridFrame whose viewport contains the marker.
    {
        var i: usize = 0;
        var found = false;
        while (i < FRAME_SCAN_ITERS) : (i += 1) {
            const tag = (try pollNext(&rdr, alloc, client, &payload, 4)) orelse continue;
            if (tag != .grid_frame) continue;
            var gf = try protocol.GridFrame.decode(alloc, payload.items);
            defer gf.deinit(alloc);
            if (try snapshotContainsMarker(alloc, &gf.snapshot, marker)) {
                found = true;
                break;
            }
        }
        try testing.expect(found);
    }

    // Detach (child stays alive).
    try clientSend(alloc, client, .detach, protocol.Detach{ .session_id = session_id });

    // Re-Attach with the SAME session_id on a fresh client fd.
    const client2 = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(client2);
    try connectUnix(client2, sock_path);
    setRecvTimeout(client2);
    var rdr2: ClientReader = .{};
    defer rdr2.deinit(alloc);

    try clientSend(alloc, client2, .hello, protocol.Hello{ .identity_bundle_id = "test.client2" });
    {
        const tag = (try pollNext(&rdr2, alloc, client2, &payload, 50)).?;
        try testing.expectEqual(protocol.FrameType.hello_ack, tag);
    }
    try clientSend(alloc, client2, .attach, protocol.Attach{ .session_id = session_id });

    // The reattach must reply with an Attached frame carrying the SAME
    // session_id (plan §5 step 3; finding P2 — the reattach path used to skip
    // this), AND the immediate full GridFrame must still carry the marker
    // (same child alive — the Session was never stopped). Frames may interleave,
    // so scan for both.
    {
        var i: usize = 0;
        var found_grid = false;
        var found_attached = false;
        while (i < FRAME_SCAN_ITERS) : (i += 1) {
            const tag = (try pollNext(&rdr2, alloc, client2, &payload, 4)) orelse continue;
            switch (tag) {
                .attached => {
                    const a = try protocol.Attached.decode(alloc, payload.items);
                    try testing.expectEqual(session_id, a.session_id);
                    found_attached = true;
                },
                .grid_frame => {
                    var gf = try protocol.GridFrame.decode(alloc, payload.items);
                    defer gf.deinit(alloc);
                    if (try snapshotContainsMarker(alloc, &gf.snapshot, marker)) {
                        found_grid = true;
                    }
                },
                else => {},
            }
            if (found_grid and found_attached) break;
        }
        try testing.expect(found_attached);
        try testing.expect(found_grid);
    }

    // Host-boundary canary: across this session's life, Termio pushed nothing
    // beyond the two sanctioned renderer messages.
    {
        const e = server.lookupForTest(session_id).?;
        try testing.expectEqual(@as(usize, 0), e.session.unexpected_renderer_count);
    }

    // Close the session, tearing it down.
    try clientSend(alloc, client2, .close, protocol.Close{ .session_id = session_id });
    // Give the close a moment to process before server.deinit teardown.
    std.Thread.sleep(50 * std.time.ns_per_ms);
}

test "host RenderState partial-frame round-trip + blank-row merge contract" {
    // Finding P1/F2: the .partial wire path was shipped but never exercised.
    // Build a FULL snapshot from a real terminal, re-frame it as .partial with
    // only SOME rows marked dirty, then serialize -> deserialize and assert the
    // documented merge contract:
    //   - the partial wire form round-trips (dirty flag + listed dirty rows),
    //   - listed (dirty) rows are reproduced exactly,
    //   - NON-listed rows come back BLANK (the deserialize reconstructs them so
    //     a Phase-2b GUI must MERGE dirty rows over its prior viewport, never
    //     replace row_data wholesale — which would erase non-dirty rows).
    const alloc = testing.allocator;

    var term = try terminalpkg.Terminal.init(alloc, .{ .cols = 10, .rows = 4 });
    defer term.deinit(alloc);
    // Distinct content per row so we can tell which survived.
    try term.printString("ROW0aaaa");
    term.carriageReturn();
    try term.linefeed();
    try term.printString("ROW1bbbb");
    term.carriageReturn();
    try term.linefeed();
    try term.printString("ROW2cccc");
    term.carriageReturn();
    try term.linefeed();
    try term.printString("ROW3dddd");

    var rs: RenderStateCore = .empty;
    defer rs.deinit(alloc);
    try rs.update(alloc, &term);

    var full = try RenderState.Snapshot.fromRenderState(alloc, &rs);
    defer full.deinit(alloc);
    try testing.expect(full.row_data.len == 4);

    // Re-frame as partial: mark rows 1 and 3 dirty, rows 0 and 2 clean.
    full.dirty = .partial;
    for (full.row_data, 0..) |*row, y| row.dirty = (y == 1 or y == 3);

    const bytes = try full.serialize(alloc);
    defer alloc.free(bytes);

    var restored = try RenderState.Snapshot.deserialize(alloc, bytes);
    defer restored.deinit(alloc);

    // The wire form is stable: re-serializing the restored partial is identical.
    const bytes2 = try restored.serialize(alloc);
    defer alloc.free(bytes2);
    try testing.expectEqualSlices(u8, bytes, bytes2);

    // The dirty flag and dimensions round-trip.
    try testing.expectEqual(@as(u16, 4), restored.rows);
    try testing.expect(restored.dirty == .partial);

    // Listed (dirty) rows 1 and 3 are reproduced exactly; non-listed rows 0 and
    // 2 come back BLANK (not the source content) — the merge contract.
    for (restored.row_data, 0..) |row, y| {
        if (y == 1 or y == 3) {
            try testing.expect(row.dirty);
            try testing.expect(row.eql(full.row_data[y]));
        } else {
            // Non-listed rows come back blank, NOT the original ROW0/ROW2
            // content — this is the merge contract: a partial frame carries
            // only dirty rows, so a GUI must merge them over its prior viewport
            // rather than replace row_data wholesale. Assert the row no longer
            // matches the source AND that every cell carries no printable
            // codepoint (a reconstructed-blank cell).
            try testing.expect(!row.dirty);
            try testing.expect(!row.eql(full.row_data[y]));
            for (row.cells) |c| {
                try testing.expectEqual(@as(u21, 0), c.raw.content.codepoint);
            }
        }
    }
}

test "host Server tears down a naturally-exited session cleanly (F1)" {
    // Finding F1 / selfexit-dangling-session: drive a child to self-exit
    // THROUGH the Server (the normal "shell exited" path), then exercise the
    // two formerly-UAF paths: (a) reattach to the same id recovers a valid
    // GridFrame + the buffered ChildExited, and (b) Server.deinit tears the
    // self-exited session down with NO use-after-free / leak. Runs under the
    // testing allocator so a leak or double-free fails the test.
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);
    const sock_path = try std.fmt.allocPrint(alloc, "{s}/h.sock", .{dir_path});
    defer alloc.free(sock_path);

    const server = try Server.init(alloc, sock_path);
    defer server.deinit();
    try server.start();

    const client = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(client);
    try connectUnix(client, sock_path);
    setRecvTimeout(client);

    var rdr: ClientReader = .{};
    defer rdr.deinit(alloc);
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(alloc);

    try clientSend(alloc, client, .hello, protocol.Hello{ .identity_bundle_id = "f1" });
    _ = (try pollNext(&rdr, alloc, client, &payload, 50)).?;

    // Attach (spawn) and learn the session_id.
    try clientSend(alloc, client, .attach, protocol.Attach{ .session_id = null });
    var session_id: u64 = 0;
    {
        var i: usize = 0;
        while (i < FRAME_SCAN_ITERS) : (i += 1) {
            const tag = (try pollNext(&rdr, alloc, client, &payload, 4)) orelse continue;
            if (tag == .attached) {
                session_id = (try protocol.Attached.decode(alloc, payload.items)).session_id;
                break;
            }
        }
        try testing.expect(session_id != 0);
    }

    // Make the child exit on its own (the common case). `exec true` replaces
    // the shell so the pty tears down and child_exited fires through the
    // Server's owner thread.
    try clientSend(alloc, client, .input, protocol.Input{
        .session_id = session_id,
        .bytes = "exec true\n",
    });

    // We should receive a ChildExited frame on this (still-subscribed) client.
    {
        var i: usize = 0;
        var got = false;
        while (i < FRAME_SCAN_ITERS) : (i += 1) {
            const tag = (try pollNext(&rdr, alloc, client, &payload, 4)) orelse continue;
            if (tag == .child_exited) {
                const ce = try protocol.ChildExited.decode(alloc, payload.items);
                try testing.expectEqual(session_id, ce.session_id);
                got = true;
                break;
            }
        }
        try testing.expect(got);
    }

    // The entry must STILL be registered with a valid Session (NOT destroyed by
    // the owner thread) so reattach can recover it (plan §4.8). Reattach with
    // the same id on a fresh client and assert we get an Attached reply — this
    // dereferences e.session (formerly a freed pointer on the self-exit path).
    const client2 = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(client2);
    try connectUnix(client2, sock_path);
    setRecvTimeout(client2);
    var rdr2: ClientReader = .{};
    defer rdr2.deinit(alloc);

    try clientSend(alloc, client2, .hello, protocol.Hello{ .identity_bundle_id = "f1b" });
    _ = (try pollNext(&rdr2, alloc, client2, &payload, 50)).?;
    try clientSend(alloc, client2, .attach, protocol.Attach{ .session_id = session_id });
    {
        var i: usize = 0;
        var got_attached = false;
        // SR3-3: the child exited while a PRIOR subscriber (client) was
        // attached; that subscriber got ChildExited live. A fresh reattach must
        // STILL learn the child is dead via deliverBufferedExit (the record is
        // not consumed-once). Assert client2 receives BOTH Attached and a
        // ChildExited replayed from buffered_child_exited.
        var got_child_exited = false;
        while (i < FRAME_SCAN_ITERS) : (i += 1) {
            const tag = (try pollNext(&rdr2, alloc, client2, &payload, 4)) orelse continue;
            if (tag == .attached) {
                try testing.expectEqual(session_id, (try protocol.Attached.decode(alloc, payload.items)).session_id);
                got_attached = true;
            } else if (tag == .child_exited) {
                try testing.expectEqual(session_id, (try protocol.ChildExited.decode(alloc, payload.items)).session_id);
                got_child_exited = true;
            }
            if (got_attached and got_child_exited) break;
        }
        try testing.expect(got_attached);
        try testing.expect(got_child_exited);
    }

    // Do NOT send Close: let server.deinit tear down the self-exited session.
    // The deinit teardown path (render_stop notify + owner-thread join + entry
    // free) must not UAF the already-child-dead Session.
}

test "host Server rejects a stateful frame before the Hello handshake (PROTO-1)" {
    // Finding PROTO-1: the major-version gate lives in the .hello case, but it
    // is only load-bearing if NO stateful frame is processed before a
    // compatible Hello. Send Attach FIRST (no Hello) and assert: (a) the server
    // closes the conn (the client read hits EOF, no Attached arrives), and
    // (b) NO session was spawned — proven by a second, properly-handshaked
    // client whose spawn gets session_id == 1 (the very first id; a pre-Hello
    // Attach spawn would have consumed id 1).
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);
    const sock_path = try std.fmt.allocPrint(alloc, "{s}/h.sock", .{dir_path});
    defer alloc.free(sock_path);

    const server = try Server.init(alloc, sock_path);
    defer server.deinit();
    try server.start();

    // Client 1: Attach BEFORE Hello -> conn must be closed, no Attached.
    {
        const client = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        defer posix.close(client);
        try connectUnix(client, sock_path);
        setRecvTimeout(client);

        try clientSend(alloc, client, .attach, protocol.Attach{ .session_id = null });

        var rdr: ClientReader = .{};
        defer rdr.deinit(alloc);
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(alloc);

        // The server closes the conn on the pre-handshake frame, so we must see
        // EOF (null) and NEVER an Attached frame.
        var i: usize = 0;
        var saw_attached = false;
        var saw_eof = false;
        while (i < 100) : (i += 1) {
            const tag = pollNext(&rdr, alloc, client, &payload, 4) catch break;
            if (tag) |t| {
                if (t == .attached) saw_attached = true;
            } else {
                saw_eof = true;
                break;
            }
        }
        try testing.expect(!saw_attached);
        try testing.expect(saw_eof);
    }

    // Client 2: proper handshake then spawn. If the pre-Hello Attach above had
    // (wrongly) spawned a session, next_session_id would now be 2; a correct
    // gate leaves it at 1.
    {
        const client = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        defer posix.close(client);
        try connectUnix(client, sock_path);
        setRecvTimeout(client);

        var rdr: ClientReader = .{};
        defer rdr.deinit(alloc);
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(alloc);

        try clientSend(alloc, client, .hello, protocol.Hello{ .identity_bundle_id = "ok" });
        {
            const tag = (try pollNext(&rdr, alloc, client, &payload, 50)).?;
            try testing.expectEqual(protocol.FrameType.hello_ack, tag);
        }
        try clientSend(alloc, client, .attach, protocol.Attach{ .session_id = null });
        var session_id: u64 = 0;
        var i: usize = 0;
        while (i < FRAME_SCAN_ITERS) : (i += 1) {
            const tag = (try pollNext(&rdr, alloc, client, &payload, 4)) orelse continue;
            if (tag == .attached) {
                session_id = (try protocol.Attached.decode(alloc, payload.items)).session_id;
                break;
            }
        }
        try testing.expectEqual(@as(u64, 1), session_id);

        // Tidy up so deinit teardown is quiet.
        try clientSend(alloc, client, .close, protocol.Close{ .session_id = session_id });
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }
}

test "host Server reports live (post-resize) dims in Attached on reattach (SR-2/SF1)" {
    // Findings SR-2 / SF1: Attached{cols,rows} must report the CURRENT grid, not
    // the immutable spawn-time opts. Spawn (default 80x24), Resize to a larger
    // grid, detach, reattach, and assert the reattach Attached carries the
    // post-resize dims (not 80x24).
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);
    const sock_path = try std.fmt.allocPrint(alloc, "{s}/h.sock", .{dir_path});
    defer alloc.free(sock_path);

    const server = try Server.init(alloc, sock_path);
    defer server.deinit();
    try server.start();

    const client = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(client);
    try connectUnix(client, sock_path);
    setRecvTimeout(client);

    var rdr: ClientReader = .{};
    defer rdr.deinit(alloc);
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(alloc);

    try clientSend(alloc, client, .hello, protocol.Hello{ .identity_bundle_id = "rs" });
    _ = (try pollNext(&rdr, alloc, client, &payload, 50)).?;

    try clientSend(alloc, client, .attach, protocol.Attach{ .session_id = null });
    var session_id: u64 = 0;
    var spawn_cols: u16 = 0;
    var spawn_rows: u16 = 0;
    {
        var i: usize = 0;
        while (i < FRAME_SCAN_ITERS) : (i += 1) {
            const tag = (try pollNext(&rdr, alloc, client, &payload, 4)) orelse continue;
            if (tag == .attached) {
                const a = try protocol.Attached.decode(alloc, payload.items);
                session_id = a.session_id;
                spawn_cols = a.cols;
                spawn_rows = a.rows;
                break;
            }
        }
        try testing.expect(session_id != 0);
    }

    // Resize the session to a NEW grid. The host computes cols/rows from
    // screen_w/h divided by cell_width/height, so pick exact multiples.
    const new_cols: u16 = 100;
    const new_rows: u16 = 40;
    const cw: u32 = 8;
    const ch: u32 = 16;
    try clientSend(alloc, client, .resize, protocol.Resize{
        .session_id = session_id,
        .cols = new_cols,
        .rows = new_rows,
        .cell_width = cw,
        .cell_height = ch,
        .screen_w = new_cols * cw,
        .screen_h = new_rows * ch,
    });

    // Give the resize message time to flow through the Termio mailbox into the
    // live terminal before we reattach + read the dims.
    std.Thread.sleep(100 * std.time.ns_per_ms);

    // Detach + reattach on a fresh client; the reattach Attached must report the
    // live (resized) grid, NOT the spawn default.
    try clientSend(alloc, client, .detach, protocol.Detach{ .session_id = session_id });

    const client2 = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(client2);
    try connectUnix(client2, sock_path);
    setRecvTimeout(client2);
    var rdr2: ClientReader = .{};
    defer rdr2.deinit(alloc);

    try clientSend(alloc, client2, .hello, protocol.Hello{ .identity_bundle_id = "rs2" });
    _ = (try pollNext(&rdr2, alloc, client2, &payload, 50)).?;
    try clientSend(alloc, client2, .attach, protocol.Attach{ .session_id = session_id });
    {
        var i: usize = 0;
        var got = false;
        while (i < FRAME_SCAN_ITERS) : (i += 1) {
            const tag = (try pollNext(&rdr2, alloc, client2, &payload, 4)) orelse continue;
            if (tag == .attached) {
                const a = try protocol.Attached.decode(alloc, payload.items);
                try testing.expectEqual(session_id, a.session_id);
                // The reattach must report the live resized grid, not opts.
                try testing.expectEqual(new_cols, a.cols);
                try testing.expectEqual(new_rows, a.rows);
                got = true;
                break;
            }
        }
        try testing.expect(got);
    }

    try clientSend(alloc, client2, .close, protocol.Close{ .session_id = session_id });
    std.Thread.sleep(50 * std.time.ns_per_ms);
}

test "host Server reaps disconnected connections (P4/F5)" {
    // Findings P4 / F5: a disconnected GUI's Conn (fd + struct + thread handle)
    // must be reaped, not leaked until Server.deinit. Open + close N client
    // connections against a live server and assert the server's live-conns list
    // returns to baseline (0) — i.e. each disconnect was reaped. Under the
    // testing allocator a failure to free would also surface as a leak.
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);
    const sock_path = try std.fmt.allocPrint(alloc, "{s}/h.sock", .{dir_path});
    defer alloc.free(sock_path);

    const server = try Server.init(alloc, sock_path);
    defer server.deinit();
    try server.start();

    var n: usize = 0;
    while (n < 8) : (n += 1) {
        const c = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        try connectUnix(c, sock_path);
        setRecvTimeout(c);
        // Hello + wait for the hello_ack so the server has fully accepted +
        // set up the connection (its read thread is running) before we
        // disconnect. This avoids racing the server's setsockopt during
        // setupConn against a peer that has already gone away.
        try clientSend(alloc, c, .hello, protocol.Hello{ .identity_bundle_id = "churn" });
        var crdr: ClientReader = .{};
        var cpayload: std.ArrayList(u8) = .empty;
        _ = (try pollNext(&crdr, alloc, c, &cpayload, 50)) orelse {};
        crdr.deinit(alloc);
        cpayload.deinit(alloc);
        // Close the client fd -> server read thread hits EOF -> conn reaped.
        posix.close(c);
    }

    // Poll until the server's live-conns list drains back to 0 (the reaper has
    // joined + freed every disconnected conn). Bounded so a reaping regression
    // fails instead of hanging.
    var i: usize = 0;
    var live: usize = 1;
    while (i < 200) : (i += 1) {
        live = server.connCountForTest();
        if (live == 0) break;
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    try testing.expectEqual(@as(usize, 0), live);
}

/// Connect a client fd to an AF_UNIX path (shared by the Server tests).
/// Mirrors Server.makeAddr's PathTooLong guard (finding PROTO-5): without it a
/// long temp dir (a deep DARWIN_USER_TEMP_DIR on a CI runner) would overflow
/// the fixed sockaddr_un.path stack buffer silently instead of failing
/// cleanly, masking a regression or producing a confusing connect failure.
fn connectUnix(fd: posix.socket_t, path: []const u8) !void {
    var addr: posix.sockaddr.un = undefined;
    addr.family = posix.AF.UNIX;
    if (path.len >= addr.path.len) return error.PathTooLong;
    @memcpy(addr.path[0..path.len], path);
    addr.path[path.len] = 0;
    try posix.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, idx, needle)) |pos| {
        count += 1;
        idx = pos + needle.len;
    }
    return count;
}

// --- Slice 3b: host-side search ---

const PageList = terminalpkg.PageList;
const Flattened = terminalpkg.highlight.Flattened;

/// Build a single-row `Flattened` highlight covering active-screen row `y`,
/// columns `[x0, x1]` (inclusive). Models the flattened highlight the real
/// search engine produces for a one-row, contiguous match — the precise shape
/// `updateHighlightsFlattened` consumes (one chunk whose [start,end) brackets
/// the row, with top_x/bot_x as the column bounds). Caller owns the result
/// (call `deinit`).
fn buildRowHighlight(
    alloc: std.mem.Allocator,
    t: *terminalpkg.Terminal,
    y: u16,
    x0: u16,
    x1: u16,
) !Flattened {
    const p = t.screens.active.pages.pin(.{ .active = .{ .x = x0, .y = y } }) orelse
        return error.NoPin;
    var chunks: std.MultiArrayList(Flattened.Chunk) = .empty;
    errdefer chunks.deinit(alloc);
    try chunks.append(alloc, .{
        .node = p.node,
        .serial = p.node.serial,
        .start = p.y,
        .end = p.y + 1,
    });
    return .{ .chunks = chunks, .top_x = x0, .bot_x = x1 };
}

/// Find a row in a Snapshot carrying a highlight with the given tag, and assert
/// its range. Returns the matching row index.
fn expectHighlight(
    snap: RenderState.Snapshot,
    tag: u8,
    range: [2]u16,
) !usize {
    for (snap.row_data, 0..) |row, y| {
        for (row.highlights) |h| {
            if (h.tag == tag and h.range[0] == range[0] and h.range[1] == range[1]) {
                return y;
            }
        }
    }
    return error.HighlightNotFound;
}

fn countHighlights(snap: RenderState.Snapshot, tag: u8) usize {
    var n: usize = 0;
    for (snap.row_data) |row| {
        for (row.highlights) |h| {
            if (h.tag == tag) n += 1;
        }
    }
    return n;
}

test "host search produces row highlights on grid frame" {
    // Deterministic injection test of captureSnapshotLocked's flatten step:
    // store a synthetically-built Flattened (the exact shape the real search
    // engine produces for a one-row match) on the Session, then assert
    // captureSnapshotLocked projects it into row.highlights with the
    // search_match tag and the right column range. No async search thread, so
    // the assertion is timing-independent.
    const alloc = testing.allocator;

    const session = try Session.create(alloc, .{ .cols = 40, .rows = 10 });
    defer session.destroy();

    {
        session.render_mutex.lock();
        defer session.render_mutex.unlock();
        try session.io.terminal.printString("foo bar foo");
    }

    // Build two "foo" highlights on row 0: cols [0,2] and [8,10].
    var hl0 = try buildRowHighlight(alloc, &session.io.terminal, 0, 0, 2);
    var hl1 = try buildRowHighlight(alloc, &session.io.terminal, 0, 8, 10);
    // The stored matches must live in a Session-owned arena (captureSnapshot
    // reads session.search_matches under render_mutex). Stash them like the
    // callback would.
    {
        var arena: std.heap.ArenaAllocator = .init(alloc);
        const a = arena.allocator();
        const matches = try a.alloc(Flattened, 2);
        matches[0] = try hl0.clone(a);
        matches[1] = try hl1.clone(a);
        hl0.deinit(alloc);
        hl1.deinit(alloc);
        session.render_mutex.lock();
        session.search_match_arena = arena;
        session.search_matches = matches;
        session.render_mutex.unlock();
    }

    var snap = blk: {
        session.render_mutex.lock();
        defer session.render_mutex.unlock();
        break :blk try session.captureSnapshotLocked(alloc);
    };
    defer snap.deinit(alloc);

    const tag = 0; // HighlightTag.search_match
    try testing.expectEqual(@as(usize, 2), countHighlights(snap, tag));
    _ = try expectHighlight(snap, tag, .{ 0, 2 });
    _ = try expectHighlight(snap, tag, .{ 8, 10 });
}

test "host hoverLink computes OSC8 link cells (Slice 3c)" {
    // Feed a Session terminal an OSC8 hyperlink, then assert Session.hoverLink
    // (which reuses RenderState.linkCells against the live host terminal)
    // returns the link's cell set when the ctrl/super mods are held, and an
    // empty set off the link / without mods. Synchronous, timing-independent.
    const alloc = testing.allocator;

    const session = try Session.create(alloc, .{ .cols = 10, .rows = 5 });
    defer session.destroy();

    {
        session.render_mutex.lock();
        defer session.render_mutex.unlock();
        var s = session.io.terminal.vtStream();
        defer s.deinit();
        // "LINK" (4 cells) at row 0, cols 0..3, all carrying the hyperlink.
        s.nextSlice("\x1b]8;;http://example.com\x1b\\LINK\x1b]8;;\x1b\\");
    }

    const mods = inputpkg.ctrlOrSuper(.{});

    // Hover at (0,0) WITH mods => the 4 link cells.
    {
        session.render_mutex.lock();
        defer session.render_mutex.unlock();
        var cells = try session.hoverLink(alloc, .{ .x = 0, .y = 0 }, mods);
        defer cells.deinit(alloc);
        try testing.expectEqual(@as(usize, 4), cells.count());
        try testing.expect(cells.contains(.{ .x = 0, .y = 0 }));
        try testing.expect(cells.contains(.{ .x = 1, .y = 0 }));
        try testing.expect(cells.contains(.{ .x = 2, .y = 0 }));
        try testing.expect(cells.contains(.{ .x = 3, .y = 0 }));
    }

    // Hover at a NON-link cell => empty.
    {
        session.render_mutex.lock();
        defer session.render_mutex.unlock();
        var cells = try session.hoverLink(alloc, .{ .x = 5, .y = 0 }, mods);
        defer cells.deinit(alloc);
        try testing.expectEqual(@as(usize, 0), cells.count());
    }

    // Hover ON the link but WITHOUT the link mods => empty (gate matches the
    // GUI's .exec branch at generic.zig:1310).
    {
        session.render_mutex.lock();
        defer session.render_mutex.unlock();
        var cells = try session.hoverLink(alloc, .{ .x = 0, .y = 0 }, .{});
        defer cells.deinit(alloc);
        try testing.expectEqual(@as(usize, 0), cells.count());
    }
}

test "host search selected highlight uses the selected tag" {
    // captureSnapshotLocked applies the selected match with the
    // search_match_selected tag (1) so it wins over the plain match tag (0),
    // mirroring the GUI flatten order.
    const alloc = testing.allocator;

    const session = try Session.create(alloc, .{ .cols = 40, .rows = 10 });
    defer session.destroy();

    {
        session.render_mutex.lock();
        defer session.render_mutex.unlock();
        try session.io.terminal.printString("foo bar foo");
    }

    var sel = try buildRowHighlight(alloc, &session.io.terminal, 0, 8, 10);
    {
        var arena: std.heap.ArenaAllocator = .init(alloc);
        const a = arena.allocator();
        const cloned = try sel.clone(a);
        sel.deinit(alloc);
        session.render_mutex.lock();
        session.search_selected_arena = arena;
        session.search_selected = cloned;
        session.render_mutex.unlock();
    }

    var snap = blk: {
        session.render_mutex.lock();
        defer session.render_mutex.unlock();
        break :blk try session.captureSnapshotLocked(alloc);
    };
    defer snap.deinit(alloc);

    try testing.expectEqual(@as(usize, 1), countHighlights(snap, 1));
    _ = try expectHighlight(snap, 1, .{ 8, 10 });
}

test "host clear search removes highlights" {
    // After highlights are stored, clearSearch (no active thread here) frees
    // them, and a fresh captureSnapshotLocked yields zero search_match rows.
    const alloc = testing.allocator;

    const session = try Session.create(alloc, .{ .cols = 40, .rows = 10 });
    defer session.destroy();

    {
        session.render_mutex.lock();
        defer session.render_mutex.unlock();
        try session.io.terminal.printString("foo bar foo");
    }

    var hl0 = try buildRowHighlight(alloc, &session.io.terminal, 0, 0, 2);
    {
        var arena: std.heap.ArenaAllocator = .init(alloc);
        const a = arena.allocator();
        const matches = try a.alloc(Flattened, 1);
        matches[0] = try hl0.clone(a);
        hl0.deinit(alloc);
        session.render_mutex.lock();
        session.search_match_arena = arena;
        session.search_matches = matches;
        session.render_mutex.unlock();
    }

    // Sanity: present before clear.
    {
        var snap = blk: {
            session.render_mutex.lock();
            defer session.render_mutex.unlock();
            break :blk try session.captureSnapshotLocked(alloc);
        };
        defer snap.deinit(alloc);
        try testing.expectEqual(@as(usize, 1), countHighlights(snap, 0));
    }

    // clearSearch (no thread is active, so it just drops stored highlights +
    // marks search_dirty + notifies the wakeup).
    session.clearSearch();
    try testing.expect(session.search_dirty);

    {
        var snap = blk: {
            session.render_mutex.lock();
            defer session.render_mutex.unlock();
            break :blk try session.captureSnapshotLocked(alloc);
        };
        defer snap.deinit(alloc);
        try testing.expectEqual(@as(usize, 0), countHighlights(snap, 0));
    }
}

test "host search emits total/selected events over the socket" {
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);
    const sock_path = try std.fmt.allocPrint(alloc, "{s}/hs.sock", .{dir_path});
    defer alloc.free(sock_path);

    const server = try Server.init(alloc, sock_path);
    defer server.deinit();
    try server.start();

    const client = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(client);
    try connectUnix(client, sock_path);
    setRecvTimeout(client);

    var rdr: ClientReader = .{};
    defer rdr.deinit(alloc);
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(alloc);

    try clientSend(alloc, client, .hello, protocol.Hello{ .identity_bundle_id = "search.client" });
    {
        const tag = (try pollNext(&rdr, alloc, client, &payload, 50)).?;
        try testing.expectEqual(protocol.FrameType.hello_ack, tag);
    }

    try clientSend(alloc, client, .attach, protocol.Attach{ .session_id = null });
    var session_id: u64 = 0;
    {
        var i: usize = 0;
        while (i < FRAME_SCAN_ITERS) : (i += 1) {
            const tag = (try pollNext(&rdr, alloc, client, &payload, 4)) orelse continue;
            if (tag == .attached) {
                session_id = (try protocol.Attached.decode(alloc, payload.items)).session_id;
                break;
            }
        }
        try testing.expect(session_id != 0);
    }

    // Make the child echo deterministic content so the search has matches.
    try clientSend(alloc, client, .input, protocol.Input{
        .session_id = session_id,
        .bytes = "printf 'NEEDLE_X NEEDLE_X\\n'\n",
    });
    {
        // Wait until a grid frame carries the marker (so the content is on the
        // emulator before we search).
        var i: usize = 0;
        var found = false;
        while (i < FRAME_SCAN_ITERS) : (i += 1) {
            const tag = (try pollNext(&rdr, alloc, client, &payload, 4)) orelse continue;
            if (tag != .grid_frame) continue;
            var gf = try protocol.GridFrame.decode(alloc, payload.items);
            defer gf.deinit(alloc);
            if (try snapshotContainsMarker(alloc, &gf.snapshot, "NEEDLE_X")) {
                found = true;
                break;
            }
        }
        try testing.expect(found);
    }

    // SetSearch -> expect a search_total with present=1, total>=1.
    try clientSend(alloc, client, .set_search, protocol.SetSearch{
        .session_id = session_id,
        .query = "NEEDLE_X",
    });
    {
        var i: usize = 0;
        var got_total = false;
        while (i < FRAME_SCAN_ITERS) : (i += 1) {
            const tag = (try pollNext(&rdr, alloc, client, &payload, 4)) orelse continue;
            if (tag != .search_total) continue;
            const st = try protocol.SearchTotal.decode(alloc, payload.items);
            try testing.expectEqual(session_id, st.session_id);
            if (st.present == 1 and st.total >= 1) {
                got_total = true;
                break;
            }
        }
        try testing.expect(got_total);
    }

    // SearchNav next -> expect a search_selected with present=1.
    try clientSend(alloc, client, .search_nav, protocol.SearchNav{
        .session_id = session_id,
        .dir = 0,
    });
    {
        var i: usize = 0;
        var got_sel = false;
        while (i < FRAME_SCAN_ITERS) : (i += 1) {
            const tag = (try pollNext(&rdr, alloc, client, &payload, 4)) orelse continue;
            if (tag != .search_selected) continue;
            const ss = try protocol.SearchSelected.decode(alloc, payload.items);
            try testing.expectEqual(session_id, ss.session_id);
            if (ss.present == 1) {
                got_sel = true;
                break;
            }
        }
        try testing.expect(got_sel);
    }

    try clientSend(alloc, client, .close, protocol.Close{ .session_id = session_id });
    std.Thread.sleep(50 * std.time.ns_per_ms);
}

test "host search integration: real search thread flattens row highlights" {
    // End-to-end through the REAL host search thread: feed content, drive
    // setSearch with a matching needle, pump the render loop until the search
    // callback has stored matches, then assert captureSnapshotLocked projects
    // them. Bounded so a wiring regression fails fast rather than hanging.
    const alloc = testing.allocator;

    const session = try Session.create(alloc, .{ .cols = 40, .rows = 10 });
    defer session.destroy();
    try session.start();
    defer session.stop();

    {
        session.render_mutex.lock();
        defer session.render_mutex.unlock();
        try session.io.terminal.printString("alpha beta alpha");
    }

    try session.setSearch("alpha");

    // Wait (bounded) for the search thread to feed + notify viewport_matches,
    // which stores session.search_matches.
    var found = false;
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        {
            session.render_mutex.lock();
            defer session.render_mutex.unlock();
            if (session.search_matches.len > 0) found = true;
        }
        if (found) break;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    try testing.expect(found);

    var snap = blk: {
        session.render_mutex.lock();
        defer session.render_mutex.unlock();
        break :blk try session.captureSnapshotLocked(alloc);
    };
    defer snap.deinit(alloc);

    // Two "alpha" occurrences on row 0 -> two search_match highlights.
    try testing.expect(countHighlights(snap, 0) >= 1);
}

test "host search to client mirror end-to-end (real thread -> wire -> rehydrate -> clear)" {
    // Single continuous flow closing the seam that findings HSC-1 + the GATE
    // caveat called out: a REAL host search thread produces row.highlights,
    // those EXACT ranges ride a GridFrame across the wire, a real Client
    // rehydrates them into its mirror, and a real clearSearch -> cleared
    // GridFrame removes them from the mirror. No injected/synthetic Flattened
    // and no locally-rebuilt projection: the Snapshot the client consumes is
    // the one the genuine search thread produced.
    const alloc = testing.allocator;

    const session = try Session.create(alloc, .{ .cols = 40, .rows = 10 });
    defer session.destroy();
    try session.start();
    defer session.stop();

    // "needle" at cols [0,5] and [7,12] on row 0 (two occurrences).
    {
        session.render_mutex.lock();
        defer session.render_mutex.unlock();
        try session.io.terminal.printString("needle needle");
    }

    try session.setSearch("needle");

    // Bounded wait for the real search thread to store viewport matches.
    var found = false;
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        {
            session.render_mutex.lock();
            defer session.render_mutex.unlock();
            if (session.search_matches.len > 0) found = true;
        }
        if (found) break;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    try testing.expect(found);

    var client = try Client.init(alloc, .{});
    defer client.deinit();

    // Capture the REAL search Snapshot and ship it as a GridFrame.
    {
        var snap = blk: {
            session.render_mutex.lock();
            defer session.render_mutex.unlock();
            break :blk try session.captureSnapshotLocked(alloc);
        };
        defer snap.deinit(alloc);

        // Host projection carried at least one search_match (tag 0).
        try testing.expect(countHighlights(snap, 0) >= 1);

        // Collect the exact ranges the host produced so we can assert the
        // client mirror carries the SAME ranges (not just "some" highlight).
        var host_ranges: std.ArrayList([2]u16) = .empty;
        defer host_ranges.deinit(alloc);
        for (snap.row_data) |row| {
            for (row.highlights) |h| {
                if (h.tag == Session.highlight_tag_search_match) {
                    try host_ranges.append(alloc, h.range);
                }
            }
        }
        try testing.expect(host_ranges.items.len >= 1);

        const gf: protocol.GridFrame = .{ .session_id = 1, .snapshot = snap };
        const payload = try gf.encode(alloc);
        defer alloc.free(payload);
        try client.handleFrame(alloc, .grid_frame, payload);

        // Every host-produced search_match range must be present in the mirror
        // with the same tag, on the same row.
        const mirror = client.render_state.row_data.slice();
        const mirror_hls = mirror.items(.highlights);
        for (host_ranges.items) |want| {
            var saw = false;
            for (mirror_hls) |hls| {
                for (hls.items) |h| {
                    if (h.tag == Session.highlight_tag_search_match and
                        h.range[0] == want[0] and h.range[1] == want[1])
                    {
                        saw = true;
                    }
                }
            }
            try testing.expect(saw);
        }
    }

    // ClearSearch over the REAL clear path: tears down the search thread and
    // swaps matches out under render_mutex. The next captured Snapshot carries
    // no search highlights, and that cleared GridFrame removes them from the
    // mirror on reuse.
    session.clearSearch();
    {
        var snap = blk: {
            session.render_mutex.lock();
            defer session.render_mutex.unlock();
            break :blk try session.captureSnapshotLocked(alloc);
        };
        defer snap.deinit(alloc);
        try testing.expectEqual(@as(usize, 0), countHighlights(snap, 0));

        const gf: protocol.GridFrame = .{ .session_id = 1, .snapshot = snap };
        const payload = try gf.encode(alloc);
        defer alloc.free(payload);
        try client.handleFrame(alloc, .grid_frame, payload);

        const mirror = client.render_state.row_data.slice();
        for (mirror.items(.highlights)) |hls| {
            try testing.expectEqual(@as(usize, 0), hls.items.len);
        }
    }
}

test "host Server applies the AUTHORITATIVE wire grid on resize, not the raw screen_w/h derived grid (Slice 9, grid_matches_wire)" {
    // Slice 9 — DISTINGUISHING test (fails before the fix, passes after) that
    // drives the resize THROUGH THE REAL SERVER PATH (socket -> Server.dispatch
    // .resize arm -> Termio mailbox -> live terminal on the IO thread), then
    // observes the host-applied grid via the reattach Attached{cols,rows}
    // (Server.liveDims reads session.io.terminal.cols/rows).
    //
    // What the fix guarantees: the host resizes to the AUTHORITATIVE wire
    // {cols, rows} the GUI rendered at, reconstructed via Resize.toSize()
    // (screen = cols*cell + padding so size.grid() reproduces {cols, rows}).
    // The previous host code instead rebuilt the Size from the raw wire
    // screen_w/h and let size.grid() = (screen - padding)/cell RE-DERIVE the
    // grid from pixels. For a well-formed frame those agree (the client derives
    // both from one renderer.Size), so to expose the divergence we send an
    // INCONSISTENT frame: authoritative {100, 40} but a screen_w/h consistent
    // with a much smaller {20, 10} grid (cell 8x16, no padding). This models a
    // peer that sends a transient/garbled screen_w/h while the cols/rows it
    // actually rendered at remain authoritative.
    //
    //   BEFORE the fix: host derives grid from screen_w/h -> applies 20x10
    //                   (Attached reports 20x10 != 100x40) -> FAIL.
    //   AFTER  the fix: host applies the wire {100, 40}
    //                   (Attached reports 100x40) -> PASS.
    //
    // A revert of ONLY Server.zig:564 (back to raw screen_w/h) also fails here,
    // because the assertion is taken off the live terminal AFTER the Server
    // dispatch + Termio mailbox actually applied the resize.
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);
    const sock_path = try std.fmt.allocPrint(alloc, "{s}/h.sock", .{dir_path});
    defer alloc.free(sock_path);

    const server = try Server.init(alloc, sock_path);
    defer server.deinit();
    try server.start();

    const client = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(client);
    try connectUnix(client, sock_path);
    setRecvTimeout(client);

    var rdr: ClientReader = .{};
    defer rdr.deinit(alloc);
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(alloc);

    try clientSend(alloc, client, .hello, protocol.Hello{ .identity_bundle_id = "rs" });
    _ = (try pollNext(&rdr, alloc, client, &payload, 50)).?;

    try clientSend(alloc, client, .attach, protocol.Attach{ .session_id = null });
    var session_id: u64 = 0;
    {
        var i: usize = 0;
        while (i < FRAME_SCAN_ITERS) : (i += 1) {
            const tag = (try pollNext(&rdr, alloc, client, &payload, 4)) orelse continue;
            if (tag == .attached) {
                const a = try protocol.Attached.decode(alloc, payload.items);
                session_id = a.session_id;
                break;
            }
        }
        try testing.expect(session_id != 0);
    }

    // AUTHORITATIVE wire grid the GUI rendered at: 100x40, cell 8x16, no padding.
    const auth_cols: u16 = 100;
    const auth_rows: u16 = 40;
    const cw: u32 = 8;
    const ch: u32 = 16;
    // INCONSISTENT screen_w/h: consistent with a SMALLER 20x10 grid (not 1x1, so
    // the shrink stays a legitimate non-degenerate resize either way). If the
    // host (pre-fix) derives from these pixels it lands on 20x10, not 100x40.
    const raw_cols: u32 = 20;
    const raw_rows: u32 = 10;
    try clientSend(alloc, client, .resize, protocol.Resize{
        .session_id = session_id,
        .cols = auth_cols,
        .rows = auth_rows,
        .cell_width = cw,
        .cell_height = ch,
        .screen_w = raw_cols * cw, // -> size.grid() = 20 cols (pre-fix path)
        .screen_h = raw_rows * ch, // -> size.grid() = 10 rows (pre-fix path)
    });

    // Let the resize flow through the Termio mailbox into the live terminal.
    std.Thread.sleep(100 * std.time.ns_per_ms);

    // Detach + reattach on a fresh client; the reattach Attached reports the
    // LIVE host grid (Server.liveDims -> terminal.cols/rows), i.e. the grid the
    // Server actually applied. It MUST equal the authoritative wire grid.
    try clientSend(alloc, client, .detach, protocol.Detach{ .session_id = session_id });

    const client2 = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    defer posix.close(client2);
    try connectUnix(client2, sock_path);
    setRecvTimeout(client2);
    var rdr2: ClientReader = .{};
    defer rdr2.deinit(alloc);

    try clientSend(alloc, client2, .hello, protocol.Hello{ .identity_bundle_id = "rs2" });
    _ = (try pollNext(&rdr2, alloc, client2, &payload, 50)).?;
    try clientSend(alloc, client2, .attach, protocol.Attach{ .session_id = session_id });
    {
        var i: usize = 0;
        var got = false;
        while (i < FRAME_SCAN_ITERS) : (i += 1) {
            const tag = (try pollNext(&rdr2, alloc, client2, &payload, 4)) orelse continue;
            if (tag == .attached) {
                const a = try protocol.Attached.decode(alloc, payload.items);
                try testing.expectEqual(session_id, a.session_id);
                // grid_matches_wire: the applied grid is the authoritative wire
                // grid, NOT the raw-screen-derived 20x10.
                try testing.expectEqual(auth_cols, a.cols);
                try testing.expectEqual(auth_rows, a.rows);
                got = true;
                break;
            }
        }
        try testing.expect(got);
    }

    try clientSend(alloc, client2, .close, protocol.Close{ .session_id = session_id });
    std.Thread.sleep(50 * std.time.ns_per_ms);
}

test "host resize preserves scrollback content (Slice 9, acceptance)" {
    // Slice 9 ACCEPTANCE: a resize through the host fix function (Resize.toSize
    // -> Termio's size.grid() -> terminal.resize, byte-for-byte what
    // Termio.resize applies, Termio.zig:469-486) must PRESERVE scrollback. This
    // is deterministic (no IO thread / no child): we drive the host terminal
    // directly, mirroring the Slice 7 scroll_viewport test.
    //
    // The frame here is a WELL-FORMED one a real Client.resize would emit:
    // cols/rows are derived from the same screen the client puts in screen_w/h
    // (so cols == grid(screen).columns). We resize 80x24 -> 80x50 (a taller
    // window). The early scrollback line must remain reachable at the top of
    // history -- a resize must never erase scrollback (upstream .exec behavior;
    // this asserts the .client/host path matches it).
    const alloc = testing.allocator;

    const session = try Session.create(alloc, .{ .cols = 80, .rows = 24 });
    defer session.destroy();

    // Feed 120 lines "L000".."L119" so ~96 land in scrollback (viewport=24).
    {
        session.render_mutex.lock();
        defer session.render_mutex.unlock();
        var i: usize = 0;
        while (i < 120) : (i += 1) {
            var lb: [8]u8 = undefined;
            const line = try std.fmt.bufPrint(&lb, "L{d:0>3}", .{i});
            try session.io.terminal.printString(line);
            session.io.terminal.carriageReturn();
            try session.io.terminal.linefeed();
        }
    }

    // Sanity: the oldest line is reachable by scrolling to the top of history.
    {
        session.render_mutex.lock();
        defer session.render_mutex.unlock();
        session.io.terminal.scrollViewport(.top);
        var snap = try session.captureSnapshotLocked(alloc);
        defer snap.deinit(alloc);
        try testing.expect(try snapshotContainsMarker(alloc, &snap, "L000"));
        session.io.terminal.scrollViewport(.bottom);
    }

    // Build a WELL-FORMED Resize frame the way Client.resize does: derive the
    // wire cols/rows from the SAME screen we put in screen_w/h, so the frame is
    // internally consistent (cols == grid(screen_w/h).columns), exactly what a
    // real client emits. Target grid: 80x50 (cell 8x16, no padding).
    const cw: u32 = 8;
    const ch: u32 = 16;
    const target_cols: u16 = 80;
    const target_rows: u16 = 50;
    const wire = protocol.Resize{
        .session_id = 1,
        .cols = target_cols,
        .rows = target_rows,
        .cell_width = cw,
        .cell_height = ch,
        .screen_w = @as(u32, target_cols) * cw, // consistent with cols
        .screen_h = @as(u32, target_rows) * ch, // consistent with rows
    };

    // Round-trip the frame and apply the EXACT size the Server .resize arm
    // builds (Resize.toSize) through Termio's grid derivation to the terminal.
    {
        const framed = try protocol.encodeFrame(alloc, .resize, wire);
        defer alloc.free(framed);
        var rdr: protocol.FrameReader = .{};
        defer rdr.deinit(alloc);
        try rdr.push(alloc, framed);
        const f = (try rdr.next(alloc)).?;
        var dec = try protocol.Resize.decode(alloc, f.payload);
        defer dec.deinit(alloc);

        const size = dec.toSize();
        const grid = size.grid();
        // grid_matches_wire: the reconstructed grid is the authoritative wire grid.
        try testing.expectEqual(target_cols, grid.columns);
        try testing.expectEqual(target_rows, grid.rows);

        session.render_mutex.lock();
        defer session.render_mutex.unlock();
        try session.io.terminal.resize(alloc, grid.columns, grid.rows);
    }

    // ACCEPTANCE: the oldest scrollback line must still be reachable after the
    // resize -- a resize must never erase the terminal content + scrollback.
    {
        session.render_mutex.lock();
        defer session.render_mutex.unlock();
        session.io.terminal.scrollViewport(.top);
        var snap = try session.captureSnapshotLocked(alloc);
        defer snap.deinit(alloc);
        try testing.expect(try snapshotContainsMarker(alloc, &snap, "L000"));
    }
}

// SLICE 11 (cwd-inherit): a spawn-opt working_directory on Session.Options must
// override the config's finalize-time default ($HOME) so the fresh child
// terminal starts there. We assert at the config boundary (deterministic): after
// create, the session config's working-directory equals the requested path —
// this is the exact value Exec.init reads (Session.zig:~337) to set the child's
// cwd, so a correct config value proves the spawn directory.
test "host session create honors spawn-opt working_directory" {
    const alloc = testing.allocator;

    // Use a real, existing directory so the value is plausible end-to-end.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);

    const session = try Session.create(alloc, .{
        .cols = 80,
        .rows = 24,
        .working_directory = dir,
    });
    defer session.destroy();

    // The config's working-directory is now an explicit `.path` equal to the
    // requested dir (NOT the finalize $HOME default). This is the exact slice
    // Exec.init consumes to set the child cwd.
    const wd = session.config.@"working-directory" orelse
        return error.WorkingDirectoryUnset;
    const wd_path = wd.value() orelse return error.WorkingDirectoryNotPath;
    try testing.expectEqualStrings(dir, wd_path);
}

// SLICE 11 (negative): a NULL working_directory must preserve pre-Slice-11
// behavior — the host's finalize default stands and is NOT clobbered with an
// explicit path. finalize() resolves the default to either `.home` (no explicit
// path) or leaves it null; in neither case should it become an explicit `.path`
// equal to some spawn-opt (there was none). We assert the absence of a
// spawn-opt override: value() is null (the .home/.inherit/null cases), i.e. no
// explicit path was injected.
test "host session create with null working_directory keeps default" {
    const alloc = testing.allocator;

    const session = try Session.create(alloc, .{
        .cols = 80,
        .rows = 24,
        // working_directory defaults to null (no spawn-opt).
    });
    defer session.destroy();

    // No explicit path was injected: either the field is null, or finalize set
    // it to .home / .inherit (both => value() == null). The key property is that
    // Slice 11 did NOT fabricate a `.path`, so today's $HOME-default behavior is
    // intact.
    if (session.config.@"working-directory") |wd| {
        try testing.expectEqual(@as(?[]const u8, null), wd.value());
    }
}

// --- Slice 12: reattach scrollback survival across a degenerate resize ---

// Resolve a `protocol.Resize` to the (columns, rows) the host would actually
// apply to the terminal, by walking the SAME two-step host path as
// `Termio.resize`: `Resize.toSize()` -> `renderer.Size.grid()`. This is the
// pure-resolution slice of the host resize dispatch (Server.dispatch's .resize
// arm calls `resize.toSize()` and queues it; Termio.resize then does
// `const grid_size = size.grid(); try self.terminal.resize(grid.columns,
// grid.rows)`). The Slice-12 mechanism test uses this to PROVE a degenerate
// frame resolves to a collapse grid (so dropping it is mandatory).
fn hostResolveResizeGrid(r: protocol.Resize) renderer_size.GridSize {
    return r.toSize().grid();
}

// Stand up a Server on a fresh unix socket, connect a client, complete the
// hello+attach handshake, and return the live server, the connected client fd,
// the assigned session_id, and the SessionEntry. Resizes/scrollback are then
// driven THROUGH THE REAL HOST PATH (clientSend(.resize) -> Server.dispatch ->
// Termio mailbox -> live terminal), and read back off `entry.session` — so the
// production guard in Server.dispatch (NOT a test-local copy) decides whether a
// degenerate frame collapses the terminal. Caller must `posix.close(client)`,
// `server.deinit()`, and free `sock_path`/`dir_path` (returned via `out_*`).
const HostHarness = struct {
    server: *Server,
    client: posix.socket_t,
    session_id: u64,
    entry: *Server.SessionEntry,
    rdr: ClientReader = .{},
    payload: std.ArrayList(u8) = .empty,

    fn deinit(self: *HostHarness, alloc: std.mem.Allocator) void {
        self.rdr.deinit(alloc);
        self.payload.deinit(alloc);
    }
};

fn hostHarnessAttach(
    alloc: std.mem.Allocator,
    server: *Server,
    sock_path: []const u8,
) !HostHarness {
    const client = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    errdefer posix.close(client);
    try connectUnix(client, sock_path);
    setRecvTimeout(client);

    var h: HostHarness = .{
        .server = server,
        .client = client,
        .session_id = 0,
        .entry = undefined,
    };
    errdefer h.deinit(alloc);

    try clientSend(alloc, client, .hello, protocol.Hello{ .identity_bundle_id = "rs" });
    _ = (try pollNext(&h.rdr, alloc, client, &h.payload, 50)).?;

    try clientSend(alloc, client, .attach, protocol.Attach{ .session_id = null });
    {
        var i: usize = 0;
        while (i < FRAME_SCAN_ITERS) : (i += 1) {
            const tag = (try pollNext(&h.rdr, alloc, client, &h.payload, 4)) orelse continue;
            if (tag == .attached) {
                const a = try protocol.Attached.decode(alloc, h.payload.items);
                h.session_id = a.session_id;
                break;
            }
        }
        try testing.expect(h.session_id != 0);
    }

    server.registry_mutex.lock();
    defer server.registry_mutex.unlock();
    h.entry = server.sessions.get(h.session_id) orelse return error.SessionMissing;
    return h;
}

// Feed `count` numbered lines "L000".."L<count-1>" into the live host terminal
// under render_mutex, so most land in scrollback above the active viewport.
// "L000" is the oldest and is reachable only from history — it is the line the
// reattach-collapse bug erases.
fn feedScrollback(h: *HostHarness, count: usize) !void {
    const t = &h.entry.session.io.terminal;
    h.entry.session.render_mutex.lock();
    defer h.entry.session.render_mutex.unlock();
    var buf: [16]u8 = undefined;
    var line: usize = 0;
    while (line < count) : (line += 1) {
        const s = try std.fmt.bufPrint(&buf, "L{d:0>3}", .{line});
        try t.printString(s);
        t.carriageReturn();
        try t.linefeed();
    }
}

// True iff the marker is present anywhere in the live host terminal's screen
// (active + history), read under render_mutex.
fn hostScreenContains(h: *HostHarness, alloc: std.mem.Allocator, marker: []const u8) !bool {
    h.entry.session.render_mutex.lock();
    defer h.entry.session.render_mutex.unlock();
    const dump = try h.entry.session.io.terminal.screens.active.dumpStringAlloc(
        alloc,
        .{ .screen = .{} },
    );
    defer alloc.free(dump);
    return std.mem.indexOf(u8, dump, marker) != null;
}

// True iff the marker is present in the live host terminal's VIEWPORT (the
// currently-displayed rows only — what a GridFrame snapshot would carry), read
// under render_mutex via captureSnapshotLocked. Distinguishes "viewport pinned
// at bottom" (marker absent) from "viewport scrolled to history" (marker
// present) — i.e. where the viewport actually sits, independent of whether a
// frame was pushed over the wire.
fn hostViewportContains(h: *HostHarness, alloc: std.mem.Allocator, marker: []const u8) !bool {
    h.entry.session.render_mutex.lock();
    defer h.entry.session.render_mutex.unlock();
    var snap = try h.entry.session.captureSnapshotLocked(alloc);
    defer snap.deinit(alloc);
    return snapshotContainsMarker(alloc, &snap, marker);
}

// Snapshot the live host terminal's grid (cols, rows) under render_mutex.
fn hostGrid(h: *HostHarness) struct { cols: u16, rows: u16 } {
    h.entry.session.render_mutex.lock();
    defer h.entry.session.render_mutex.unlock();
    const t = &h.entry.session.io.terminal;
    return .{ .cols = @intCast(t.cols), .rows = @intCast(t.rows) };
}

// A well-formed Resize the GUI would send for an 80xN window with 8x16 cells
// and zero padding. screen_w/h are kept consistent with cols/rows so the frame
// is "healthy" (matches what a real client emits).
fn wellFormedResize(cols: u16, rows: u16) protocol.Resize {
    const cw: u32 = 8;
    const ch: u32 = 16;
    return .{
        .session_id = 1,
        .cols = cols,
        .rows = rows,
        .cell_width = cw,
        .cell_height = ch,
        .screen_w = @as(u32, cols) * cw,
        .screen_h = @as(u32, rows) * ch,
    };
}

// REPRODUCER (Slice 12): on reattach the GUI can momentarily report a 0/near-0
// grid for a restored tab before layout/font-metrics settle, then the real
// restored size. The host must NOT collapse the terminal to a 1x1 grid on the
// transient frame (which reflows away scrollback); the early scrollback line
// must survive the degenerate-then-real Resize sequence.
//
// This drives the resize THROUGH THE REAL HOST PATH — clientSend(.resize)
// frames over the socket -> Server.dispatch's .resize arm -> Termio mailbox ->
// the live terminal on the IO thread — then reads the result back off the live
// session. So the PRODUCTION guard in Server.dispatch (Server.zig), not a copy
// in the test, decides the degenerate frame's fate. It is genuinely
// fail-before/pass-after w.r.t. that guard:
//   GUARD PRESENT  (fix): degenerate {0,0} is dropped; the terminal stays at
//                  the well-formed grid and "L000" survives -> PASS.
//   GUARD REMOVED (pre-fix): the degenerate frame resolves (toSize -> grid,
//                  @max(1,...) floor) to a 1x1 collapse grid; terminal.resize
//                  reflows the screen down to one row, discarding scrollback
//                  (and, with real history present, underflow-panics
//                  PageList.resizeCols) -> FAIL (asserts/crashes).
test "host reattach: degenerate-then-real Resize preserves scrollback (Slice 12)" {
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);
    const sock_path = try std.fmt.allocPrint(alloc, "{s}/h.sock", .{dir_path});
    defer alloc.free(sock_path);

    const server = try Server.init(alloc, sock_path);
    defer server.deinit();
    try server.start();

    var h = try hostHarnessAttach(alloc, server, sock_path);
    defer h.deinit(alloc);
    defer posix.close(h.client);

    // Feed ~120 numbered lines into the LIVE host terminal so ~96 land in
    // scrollback above the active viewport. "L000" is the oldest line.
    try feedScrollback(&h, 120);

    // Sanity: "L000" is present in the live screen (history + active) BEFORE any
    // resize. This is the line the bug erases.
    try testing.expect(try hostScreenContains(&h, alloc, "L000"));

    // The reattach transient, sent over the wire as the GUI would:
    //   FIRST a sequence of degenerate frames — a tab momentarily reporting a
    //         degenerate grid before layout/font-metrics settle. We exercise
    //         not just the literal {0,0} but also a {1,1} and the mixed
    //         {1,24}/{80,1} cases (MF-1): {1,1} has both dims NONZERO so a
    //         wire-value-only guard would pass it through, yet it resolves to a
    //         1x1 collapse grid that underflow-PANICS PageList.resizeCols during
    //         the column reflow with real history present. The resolved-grid
    //         guard must drop all of them.
    //   THEN  the real restored size (80x50).
    // Each goes through Server.dispatch; we sleep so the Termio mailbox applies
    // it on the IO thread before the next step (same pattern as the Slice-9
    // real-path test).
    const degenerates = [_][2]u16{ .{ 0, 0 }, .{ 1, 1 }, .{ 1, 24 }, .{ 80, 1 } };
    for (degenerates) |d| {
        try clientSend(alloc, h.client, .resize, blk: {
            var r = wellFormedResize(d[0], d[1]);
            r.session_id = h.session_id;
            break :blk r;
        });
        std.Thread.sleep(60 * std.time.ns_per_ms);
    }

    try clientSend(alloc, h.client, .resize, blk: {
        var r = wellFormedResize(80, 50);
        r.session_id = h.session_id;
        break :blk r;
    });
    std.Thread.sleep(100 * std.time.ns_per_ms);

    // degenerate_dim_not_applied: the live grid is the WELL-FORMED restored
    // size, never the degenerate frame's 1x1 collapse. (Pre-fix, the degenerate
    // frame collapses the grid to 1x1 — or panics during its reflow — so this
    // readback is also a fail-before/pass-after signal independent of content.)
    const grid = hostGrid(&h);
    try testing.expectEqual(@as(u16, 80), grid.cols);
    try testing.expectEqual(@as(u16, 50), grid.rows);

    // ACCEPTANCE: the oldest scrollback line survived the degenerate-then-real
    // sequence on the live host terminal.
    try testing.expect(try hostScreenContains(&h, alloc, "L000"));
}

// Slice-9 guardrail (must NOT regress): a well-formed shrink-then-grow resize
// driven through the SAME real host path applies the authoritative wire
// {cols, rows} and preserves scrollback content, just like .exec's
// terminal.resize across a normal reflow. The Slice-12 guard must keep
// well-formed frames (both dims nonzero) flowing through untouched.
test "host reattach: well-formed resize preserves scrollback + applies wire grid (Slice 9 guard)" {
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);
    const sock_path = try std.fmt.allocPrint(alloc, "{s}/h.sock", .{dir_path});
    defer alloc.free(sock_path);

    const server = try Server.init(alloc, sock_path);
    defer server.deinit();
    try server.start();

    var h = try hostHarnessAttach(alloc, server, sock_path);
    defer h.deinit(alloc);
    defer posix.close(h.client);

    try feedScrollback(&h, 120);
    try testing.expect(try hostScreenContains(&h, alloc, "L000"));

    // A legitimate shrink (80x10) then grow (100x50), each well-formed: both
    // must flow through the guard and be APPLIED (not dropped).
    try clientSend(alloc, h.client, .resize, blk: {
        var r = wellFormedResize(80, 10);
        r.session_id = h.session_id;
        break :blk r;
    });
    std.Thread.sleep(100 * std.time.ns_per_ms);

    try clientSend(alloc, h.client, .resize, blk: {
        var r = wellFormedResize(100, 50);
        r.session_id = h.session_id;
        break :blk r;
    });
    std.Thread.sleep(100 * std.time.ns_per_ms);

    // Wire grid is authoritative: terminal ends at the last frame's {cols,rows}.
    const grid = hostGrid(&h);
    try testing.expectEqual(@as(u16, 100), grid.cols);
    try testing.expectEqual(@as(u16, 50), grid.rows);

    // Scrollback content survives a normal reflow.
    try testing.expect(try hostScreenContains(&h, alloc, "L000"));
}

// A degenerate RESOLVED grid must never reach terminal.resize. The host's
// dispatch guard gates on the RESOLVED grid (Resize.toSize().grid()) against the
// GUI's own minimum terminal size (CoreSurface.min_window_{width,height}_cells,
// 10x4) — not the raw wire {cols,rows}. This documents that every degenerate
// transient (the literal {0,0}, a {1,1} with both dims nonzero, and the mixed
// {1,24}/{80,1} cases) resolves BELOW that floor, so the host recognizes and
// drops it. Gating on the wire value alone (cols==0 or rows==0) would let the
// {1,1} case through to the PageList.resizeCols underflow panic (MF-1).
test "host reattach: degenerate Resize resolves below the min-window floor the host drops (Slice 12)" {
    const min_w = CoreSurface.min_window_width_cells;
    const min_h = CoreSurface.min_window_height_cells;
    const degenerates = [_][2]u16{ .{ 0, 0 }, .{ 1, 1 }, .{ 1, 24 }, .{ 80, 1 }, .{ 0, 24 }, .{ 80, 0 } };
    for (degenerates) |d| {
        const grid = hostResolveResizeGrid(wellFormedResize(d[0], d[1]));
        // Below the floor in at least one dimension => the dispatch drops it.
        try testing.expect(grid.columns < min_w or grid.rows < min_h);
    }
    // A well-formed restored size resolves AT/ABOVE the floor in both dims, so
    // the guard lets it through (Slice 9 not regressed).
    const ok = hostResolveResizeGrid(wellFormedResize(80, 50));
    try testing.expect(ok.columns >= min_w and ok.rows >= min_h);
}

// --- 2nd reattach-scrollback mechanism: well-formed reattach Resize + scroll ---
//
// Scan the wire for the FIRST GridFrame whose snapshot contains `marker`, within
// a bounded poll. Returns true if such a frame arrives. Unlike hostScreenContains
// (which reads the live host terminal directly), this asserts on what the GUI
// ACTUALLY RECEIVES over the socket — the GridFrame snapshot it renders. The bug
// is "scroll-up shows nothing in the GUI", so the contract that matters is the
// content of the pushed GridFrame, not the host terminal's internal state.
fn wireGridFrameContains(
    alloc: std.mem.Allocator,
    rdr: *ClientReader,
    fd: posix.socket_t,
    payload: *std.ArrayList(u8),
    marker: []const u8,
) !bool {
    var i: usize = 0;
    while (i < FRAME_SCAN_ITERS) : (i += 1) {
        const tag = (try pollNext(rdr, alloc, fd, payload, 4)) orelse continue;
        if (tag != .grid_frame) continue;
        var gf = try protocol.GridFrame.decode(alloc, payload.items);
        defer gf.deinit(alloc);
        if (try snapshotContainsMarker(alloc, &gf.snapshot, marker)) return true;
    }
    return false;
}

// Drain whatever frames are currently queued on `fd` (best-effort, bounded) so a
// subsequent wireGridFrameContains observes only frames produced AFTER this
// point — e.g. so a scroll's fresh GridFrame is not confused with the pre-scroll
// pushFullFrames frame still sitting in the socket buffer.
fn wireDrain(
    alloc: std.mem.Allocator,
    rdr: *ClientReader,
    fd: posix.socket_t,
    payload: *std.ArrayList(u8),
) !void {
    var i: usize = 0;
    while (i < FRAME_SCAN_ITERS) : (i += 1) {
        _ = (try pollNext(rdr, alloc, fd, payload, 2)) orelse return;
    }
}

// Reattach a fresh client fd to an EXISTING session_id over the real socket,
// completing hello + attach(existing). Drives Server.handleAttach's
// existing-session branch (subscribe + Attached + pushFullFrames). Returns the
// connected fd; caller owns it (posix.close) and the returned reader. Asserts
// the reattach Attached carries the same session_id.
fn reattachExisting(
    alloc: std.mem.Allocator,
    sock_path: []const u8,
    session_id: u64,
    rdr: *ClientReader,
    payload: *std.ArrayList(u8),
) !posix.socket_t {
    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    errdefer posix.close(fd);
    try connectUnix(fd, sock_path);
    setRecvTimeout(fd);

    try clientSend(alloc, fd, .hello, protocol.Hello{ .identity_bundle_id = "reattach" });
    {
        const tag = (try pollNext(rdr, alloc, fd, payload, 50)).?;
        try testing.expectEqual(protocol.FrameType.hello_ack, tag);
    }
    try clientSend(alloc, fd, .attach, protocol.Attach{ .session_id = session_id });
    {
        var i: usize = 0;
        var got = false;
        while (i < FRAME_SCAN_ITERS) : (i += 1) {
            const tag = (try pollNext(rdr, alloc, fd, payload, 4)) orelse continue;
            if (tag == .attached) {
                const a = try protocol.Attached.decode(alloc, payload.items);
                try testing.expectEqual(session_id, a.session_id);
                got = true;
                break;
            }
        }
        try testing.expect(got);
    }
    return fd;
}

// END-TO-END POSITIVE SANITY + NEGATIVE CONTROL (2nd reattach-scrollback
// mechanism — NOT Slice 12's degenerate resize). This test does NOT, on its own,
// reproduce the bug fail-before/pass-after: with the viewport_dirty force-push
// REVERTED it still PASSES (verified by experiment), because here the final
// scroll-to-top produces a viewport that DIFFERS from the resize-time
// prev_snapshot, so renderTick's `changed>0` arm pushes the frame regardless of
// the fix. The GENUINE fail-before/pass-after reproducer of this mechanism is the
// next test ("host reattach: resize-while-scrolled ...", the M1 variant), whose
// final scroll is a redundant scroll-to-top that yields changed==0 and is
// suppressed without the fix. Keep this test as the broad end-to-end guard:
//   - it drives the FULL reattach sequence over the real socket,
//   - it proves M1 is NOT the mechanism (scrollback survives every well-formed
//     reattach resize, host-side), and
//   - it carries the NEGATIVE CONTROL (pre-scroll, the bottom-pinned wire frame
//     must NOT contain L000) that makes the post-scroll positive meaningful.
//
// Live smoke being modeled: after a GUI quit+relaunch (reattach), the shell
// PROCESS + state survive, but the SCROLLBACK appears gone — scrolling up shows
// nothing — with ZERO degenerate resizes. Two candidate mechanisms:
//   (M1) the WELL-FORMED reattach Resize reflows scrollback away (shrink / cols
//        change / resize-while-scrolled differs from Slice 9's grow case).
//   (M2) the post-reattach ScrollViewport -> repin -> GridFrame push fails to
//        SURFACE the host scrollback to the GUI (the push gate). << FOUND
//
// Sequence (asserting on the WIRE GridFrame the GUI actually receives):
//   (a) attach (spawn) client1, feed ~120 lines so ~96 land in scrollback,
//   (b) DETACH client1 (real .detach frame; child stays alive),
//   (c) REATTACH on a fresh client2 with the existing session_id (drives
//       handleAttach existing-session branch + pushFullFrames),
//   (d) apply a WELL-FORMED reattach Resize over the wire — a same-size (80x24)
//       frame, then different sizes (100x30, then 80x40); each must PRESERVE
//       scrollback host-side (the M1 question — answered NO here),
//   (e) NEGATIVE CONTROL: the bottom-pinned wire frame must NOT carry L000,
//   (f) issue ScrollViewport(.top) over the wire and assert "L000" (the oldest
//       scrollback line) is reachable in the resulting GridFrame.
test "host reattach->resize->scroll end-to-end sanity: scrollback survives every well-formed resize + is scrollable on the wire (M1 ruled out; positive+negative control)" {
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);
    const sock_path = try std.fmt.allocPrint(alloc, "{s}/h.sock", .{dir_path});
    defer alloc.free(sock_path);

    const server = try Server.init(alloc, sock_path);
    defer server.deinit();
    try server.start();

    // (a) attach (spawn) client1 + feed scrollback.
    var h = try hostHarnessAttach(alloc, server, sock_path);
    defer h.deinit(alloc);
    var client1_open = true;
    defer if (client1_open) posix.close(h.client);

    try feedScrollback(&h, 120);
    try testing.expect(try hostScreenContains(&h, alloc, "L000"));

    // (b) DETACH client1 (the real .detach frame), then close its fd — modeling
    // the GUI quitting. The child stays alive; the entry keeps its scrollback.
    try clientSend(alloc, h.client, .detach, protocol.Detach{ .session_id = h.session_id });
    std.Thread.sleep(30 * std.time.ns_per_ms);
    posix.close(h.client);
    client1_open = false;

    // (c) REATTACH on a fresh client2 with the existing session_id (drives
    // handleAttach's existing-session branch -> subscribe + Attached +
    // pushFullFrames). The immediate pushFullFrames carries the BOTTOM viewport
    // (newest), so the oldest line is NOT in it yet — we must scroll to reach it.
    var rdr2: ClientReader = .{};
    defer rdr2.deinit(alloc);
    var payload2: std.ArrayList(u8) = .empty;
    defer payload2.deinit(alloc);
    const client2 = try reattachExisting(alloc, sock_path, h.session_id, &rdr2, &payload2);
    defer posix.close(client2);

    // Host-side sanity post-reattach: the host terminal STILL holds the
    // scrollback (handleAttach does not touch it).
    try testing.expect(try hostScreenContains(&h, alloc, "L000"));

    // (d) WELL-FORMED reattach Resize over the wire. The original session is
    // 80x24 (hostHarnessAttach spawns default Options). We exercise a SAME-size
    // frame first, then a DIFFERENT size (a cols+rows change that is a GROW on
    // cols but the kind of well-formed restore-time resize the GUI sends), then a
    // shrink-rows variant. All well-formed (>= the min-window floor), so Slice 12
    // does not drop them; each must PRESERVE scrollback (the M1 question).
    const reattach_sizes = [_][2]u16{ .{ 80, 24 }, .{ 100, 30 }, .{ 80, 40 } };
    for (reattach_sizes) |sz| {
        try clientSend(alloc, client2, .resize, blk: {
            var r = wellFormedResize(sz[0], sz[1]);
            r.session_id = h.session_id;
            break :blk r;
        });
        std.Thread.sleep(80 * std.time.ns_per_ms);
    }

    // After the well-formed reattach resizes, the host terminal MUST still hold
    // the oldest scrollback line (M1 check, host-side). If this fails, M1 is the
    // mechanism (a well-formed reattach resize reflowed scrollback away).
    try testing.expect(try hostScreenContains(&h, alloc, "L000"));

    // NEGATIVE CONTROL: BEFORE scrolling, the viewport is pinned at the bottom
    // (newest), so the most recent pushed GridFrame must NOT contain the oldest
    // line "L000". This proves the positive assertion below is genuinely
    // exercising the scroll path (the oldest line only appears after scrolling),
    // not a frame that happened to already carry it. We scan a fresh post-resize
    // frame for L000 and require its ABSENCE.
    try testing.expect(!try wireGridFrameContains(alloc, &rdr2, client2, &payload2, "L000"));

    // Drain any remaining resize-induced GridFrames so the next read observes the
    // post-scroll frame.
    try wireDrain(alloc, &rdr2, client2, &payload2);

    // (e) ScrollViewport(.top) over the wire — the GUI scrolling up after
    // reattach. Routed through Server.dispatch's .scroll_viewport arm ->
    // Session.scrollViewport -> Termio mailbox -> terminal.scrollViewport, then
    // the owning thread's renderTick ships a fresh GridFrame of the scrolled
    // viewport.
    try clientSend(alloc, client2, .scroll_viewport, blk: {
        var sv = protocol.ScrollViewport.fromTarget(0, .top);
        sv.session_id = h.session_id;
        break :blk sv;
    });
    std.Thread.sleep(120 * std.time.ns_per_ms);

    // (f) ACCEPTANCE: the GridFrame the GUI receives after scrolling to the top
    // MUST contain "L000". This is the exact thing the live smoke reported as
    // broken ("scrolling up shows nothing"). If the host path is correct, the
    // wire frame surfaces the oldest scrollback line.
    try testing.expect(try wireGridFrameContains(alloc, &rdr2, client2, &payload2, "L000"));

    // Clean up: close the session.
    try clientSend(alloc, client2, .close, protocol.Close{ .session_id = h.session_id });
    std.Thread.sleep(50 * std.time.ns_per_ms);
}

// GENUINE REPRODUCER of the 2nd reattach-scrollback mechanism (M2: the host
// push gate suppresses the post-reattach scroll frame). VERIFIED fail-before/
// pass-after: with the `viewport_dirty` force-push in Session.renderTick disabled
// this test FAILS at the final wire assertion (line ~"wireGridFrameContains ...
// L000"); with the fix in place it PASSES. (Confirmed by experiment: temporarily
// gating the force-push off makes ONLY this test fail; the end-to-end sanity test
// above still passes, which is why THIS test — not that one — is the reproducer.)
//
// Why this one reproduces and the sanity test above does not: the order is
// scroll-to-top FIRST, then a well-formed reattach resize WHILE scrolled, then a
// REDUNDANT scroll-to-top. That last scroll lands on a viewport whose rows EQUAL
// the prev_snapshot left by the prior tick, so renderTick computes `changed==0`.
// Without the force-push the push gate (`changed>0 || force_push || cursor_changed`)
// SUPPRESSES the frame and the GUI "scrolls up and sees nothing" — exactly the
// live smoke. The host viewport itself is correct (asserted via
// hostViewportContains below); only the wire push was gated out. The fix sets
// `viewport_dirty` on every scroll/jump and converts it to force_push, so an
// explicit GUI scroll always ships its frame.
//
// Also the only test covering RESIZE-WHILE-SCROLLED (Slice 9 resizes at the
// BOTTOM): it additionally asserts the well-formed resize does NOT erase
// scrollback nor re-pin the viewport off the oldest line (M1 ruled out here too).
test "host reattach: resize-while-scrolled then redundant scroll surfaces scrollback on the wire (2nd mechanism repro; fail-before/pass-after for the push-gate fix)" {
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);
    const sock_path = try std.fmt.allocPrint(alloc, "{s}/h.sock", .{dir_path});
    defer alloc.free(sock_path);

    const server = try Server.init(alloc, sock_path);
    defer server.deinit();
    try server.start();

    var h = try hostHarnessAttach(alloc, server, sock_path);
    defer h.deinit(alloc);
    var client1_open = true;
    defer if (client1_open) posix.close(h.client);

    try feedScrollback(&h, 120);
    try testing.expect(try hostScreenContains(&h, alloc, "L000"));

    // Detach client1 (GUI quit).
    try clientSend(alloc, h.client, .detach, protocol.Detach{ .session_id = h.session_id });
    std.Thread.sleep(30 * std.time.ns_per_ms);
    posix.close(h.client);
    client1_open = false;

    // Reattach client2 (existing session).
    var rdr2: ClientReader = .{};
    defer rdr2.deinit(alloc);
    var payload2: std.ArrayList(u8) = .empty;
    defer payload2.deinit(alloc);
    const client2 = try reattachExisting(alloc, sock_path, h.session_id, &rdr2, &payload2);
    defer posix.close(client2);

    // Scroll to the TOP FIRST (viewport now on the oldest content)...
    try clientSend(alloc, client2, .scroll_viewport, blk: {
        var sv = protocol.ScrollViewport.fromTarget(0, .top);
        sv.session_id = h.session_id;
        break :blk sv;
    });
    std.Thread.sleep(80 * std.time.ns_per_ms);
    try testing.expect(try hostScreenContains(&h, alloc, "L000"));

    // ...THEN apply a well-formed reattach resize WHILE scrolled (the order
    // Slice 9 does not exercise). Use a different size (100x30) to also cover the
    // cols-change reflow path.
    try clientSend(alloc, client2, .resize, blk: {
        var r = wellFormedResize(100, 30);
        r.session_id = h.session_id;
        break :blk r;
    });
    std.Thread.sleep(100 * std.time.ns_per_ms);

    // The oldest scrollback line must STILL be in the host terminal after the
    // resize-while-scrolled reflow (a resize must never erase scrollback).
    try testing.expect(try hostScreenContains(&h, alloc, "L000"));
    // The viewport stayed scrolled (the resize did NOT re-pin to bottom): the
    // host viewport itself still shows the oldest line. The bug is purely in
    // SURFACING it to the GUI over the wire (the push gate), proven below.
    try testing.expect(try hostViewportContains(&h, alloc, "L000"));

    // And a scroll-to-top after the resize must surface it on the WIRE again
    // (whatever the resize did to the viewport pin, the GUI can still reach the
    // oldest line). Drain first so we read a fresh post-scroll frame.
    try wireDrain(alloc, &rdr2, client2, &payload2);
    try clientSend(alloc, client2, .scroll_viewport, blk: {
        var sv = protocol.ScrollViewport.fromTarget(0, .top);
        sv.session_id = h.session_id;
        break :blk sv;
    });
    std.Thread.sleep(120 * std.time.ns_per_ms);
    // FAIL-BEFORE / PASS-AFTER: without the viewport_dirty force-push (the fix),
    // this scroll's resulting viewport equals the stale prev_snapshot, so
    // renderTick's `changed==0` gate SUPPRESSES the frame and no GridFrame with
    // "L000" ever arrives — even though the host viewport (asserted above) shows
    // it. With the fix, the scroll forces the push and the GUI receives it.
    try testing.expect(try wireGridFrameContains(alloc, &rdr2, client2, &payload2, "L000"));

    try clientSend(alloc, client2, .close, protocol.Close{ .session_id = h.session_id });
    std.Thread.sleep(50 * std.time.ns_per_ms);
}

// CRITIC-GAP DIAGNOSTIC (mechanism-completeness, NOT a fix gate). The live smoke
// is "FIRST scroll up shows nothing on ALL tabs after reattach". This test models
// EXACTLY that minimal gesture — a single, plain ScrollViewport(.top) as the very
// first navigation after reattach, with NO prior scroll and NO redundant
// re-scroll — and asserts the host DOES surface the oldest scrollback line on the
// wire.
//
// PURPOSE: localize the residual smoke component. The host push-gate fix
// (viewport_dirty force-push) demonstrably closes the REDUNDANT-scroll gap (the
// reproducer test above is fail-before/pass-after). But a plain first scroll-up
// from a bottom-pinned reattach lands on a viewport that DIFFERS from the
// (bottom) prev_snapshot, so renderTick's `changed>0` arm pushes it REGARDLESS of
// the fix. This test therefore PASSES WITH OR WITHOUT the fix — VERIFIED by
// disabling the force-push (only the redundant-scroll reproducer fails; this test
// and the end-to-end sanity test still pass).
//
// CONCLUSION it nails down: the host-side first-scroll-after-reattach path is
// CORRECT — it is NOT a host mechanism for "first scroll up shows nothing". Hence
// the residual smoke component (if the redundant-scroll fix does not fully
// explain the field report) is GUI-SIDE, not host-side. Precise GUI-side
// next-steps to investigate are documented in the agent report:
//   (1) does the GUI even SEND a ScrollViewport on the first wheel/key after
//       reattach, or is its scroll handler gated on a restored/stale local
//       scroll-position state that makes the first gesture a no-op send?
//   (2) does the GUI apply the post-reattach pushFullFrames frame as the new
//       viewport baseline, or does it keep a restored (pre-quit) scroll offset
//       that swallows the first scroll delta before it becomes a wire send?
// Both are Swift (TerminalView / SurfaceView scroll handling) — out of this
// Zig-only scope, hence left as a documented follow-up, not a host change.
test "host reattach: a PLAIN first scroll-up (no prior/redundant scroll) surfaces scrollback on the wire — host first-scroll path is correct (critic-gap diagnostic; passes with AND without the push-gate fix)" {
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);
    const sock_path = try std.fmt.allocPrint(alloc, "{s}/h.sock", .{dir_path});
    defer alloc.free(sock_path);

    const server = try Server.init(alloc, sock_path);
    defer server.deinit();
    try server.start();

    var h = try hostHarnessAttach(alloc, server, sock_path);
    defer h.deinit(alloc);
    var client1_open = true;
    defer if (client1_open) posix.close(h.client);

    try feedScrollback(&h, 120);
    try testing.expect(try hostScreenContains(&h, alloc, "L000"));

    // Detach client1 (GUI quit) — the viewport is pinned at the BOTTOM and the
    // last tick-pushed prev_snapshot reflects that bottom viewport.
    try clientSend(alloc, h.client, .detach, protocol.Detach{ .session_id = h.session_id });
    std.Thread.sleep(30 * std.time.ns_per_ms);
    posix.close(h.client);
    client1_open = false;

    // Reattach client2 (existing session) — pushFullFrames sends the BOTTOM
    // viewport (no L000 yet); prev_snapshot is untouched (still the bottom).
    var rdr2: ClientReader = .{};
    defer rdr2.deinit(alloc);
    var payload2: std.ArrayList(u8) = .empty;
    defer payload2.deinit(alloc);
    const client2 = try reattachExisting(alloc, sock_path, h.session_id, &rdr2, &payload2);
    defer posix.close(client2);

    // NEGATIVE CONTROL: the bottom-pinned reattach frame must NOT carry L000.
    try testing.expect(!try wireGridFrameContains(alloc, &rdr2, client2, &payload2, "L000"));
    try wireDrain(alloc, &rdr2, client2, &payload2);

    // THE MINIMAL SMOKE GESTURE: a single, plain first scroll-to-top. No prior
    // scroll, no resize-while-scrolled, no redundant re-scroll. The resulting
    // viewport (top, showing L000) DIFFERS from the bottom prev_snapshot, so the
    // host pushes it via the ordinary `changed>0` arm — independent of the fix.
    try clientSend(alloc, client2, .scroll_viewport, blk: {
        var sv = protocol.ScrollViewport.fromTarget(0, .top);
        sv.session_id = h.session_id;
        break :blk sv;
    });
    std.Thread.sleep(120 * std.time.ns_per_ms);

    // The host MUST surface L000 on the wire for a plain first scroll-up. (Passes
    // with AND without the push-gate fix — proving the host first-scroll path is
    // correct and the residual smoke is GUI-side, see the docstring.)
    try testing.expect(try wireGridFrameContains(alloc, &rdr2, client2, &payload2, "L000"));

    try clientSend(alloc, client2, .close, protocol.Close{ .session_id = h.session_id });
    std.Thread.sleep(50 * std.time.ns_per_ms);
}

