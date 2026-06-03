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

const posix = std.posix;

const Session = @import("Session.zig");
const RenderState = @import("RenderState.zig");
const protocol = @import("protocol.zig");
const Server = @import("Server.zig");
const Client = @import("../termio/Client.zig");

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

    // Attach (present + null).
    {
        const orig: protocol.Attach = .{ .session_id = 99 };
        const framed = try protocol.encodeFrame(alloc, .attach, orig);
        defer alloc.free(framed);
        const tag = try feedOneByteAtATime(alloc, framed, &payload);
        try testing.expectEqual(protocol.FrameType.attach, tag);
        const dec = try protocol.Attach.decode(alloc, payload.items);
        try testing.expectEqual(orig.session_id, dec.session_id);
    }
    {
        const orig: protocol.Attach = .{ .session_id = null };
        const framed = try protocol.encodeFrame(alloc, .attach, orig);
        defer alloc.free(framed);
        const tag = try feedOneByteAtATime(alloc, framed, &payload);
        try testing.expectEqual(protocol.FrameType.attach, tag);
        const dec = try protocol.Attach.decode(alloc, payload.items);
        try testing.expectEqual(@as(?u64, null), dec.session_id);
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
