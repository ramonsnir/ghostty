//! Host integration tests (Phase 1). The named tests required by the
//! Phase 1 acceptance criteria live here:
//!   - "host session spawn+diff" (real child + IO thread + wakeup + diff)
//!   - "RenderState round-trip (serialize->deserialize->equal)"
//! Plus a fast synchronous unit test of the render-sink diff path.
//! All test names contain the literal "host" so `-Dtest-filter=host` matches.

const std = @import("std");
const testing = std.testing;

const terminalpkg = @import("../terminal/main.zig");
const render = @import("../terminal/render.zig");
const RenderStateCore = render.RenderState;

const posix = std.posix;

const Session = @import("Session.zig");
const RenderState = @import("RenderState.zig");
const protocol = @import("protocol.zig");
const Server = @import("Server.zig");

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
        while (i < 400) : (i += 1) {
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
        while (i < 400) : (i += 1) {
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
        while (i < 400) : (i += 1) {
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
        while (i < 400) : (i += 1) {
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
        while (i < 400) : (i += 1) {
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
        while (i < 400) : (i += 1) {
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
        while (i < 400) : (i += 1) {
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
        while (i < 400) : (i += 1) {
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
        while (i < 400) : (i += 1) {
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
