//! FORK(host-handoff): the supervisor↔worker CONTROL protocol.
//!
//! A separate, private channel from the GUI↔worker wire protocol
//! (`protocol.zig`) — kept apart so the GUI protocol stays byte-stable while this
//! internal channel evolves freely. It runs over an inherited `socketpair`
//! between the session-less supervisor (the launchd job) and each worker
//! (`ghostty-host`), and it is the path over which a live pty master fd + a
//! serialized `terminal.Terminal` move during a handoff.
//!
//! ## Framing
//!
//! Every frame is a FIXED-SIZE 24-byte header (so the receiver can always
//! `recvMsg` exactly one header, picking up any `SCM_RIGHTS` fd, without
//! over-reading a trailing blob — see `fdpass.zig`), optionally followed by:
//!   - a passed fd (an `SCM_RIGHTS` pty master), and/or
//!   - a variable-length BLOB read from the stream (`aux` = its byte length).
//!
//! Header layout (little-endian; same-build channel, no cross-version concern):
//!   [0]      tag (Tag)
//!   [1..8]   reserved (zero)
//!   [8..16]  session_id (u64)
//!   [16..24] aux (u64): blob length / count / ok-flag, per tag
//!   [24..32] aux2 (u64): child pid (adopt), else zero
//!
//! macOS-only (it builds on `fdpass`, whose Darwin cmsg ABI is macOS-only). The
//! handoff is local-first; a Linux worker on the cloud box does not use it yet.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Allocator = std.mem.Allocator;

const fdpass = @import("fdpass.zig");

comptime {
    if (builtin.os.tag != .macos) @compileError("handoff_protocol is macOS-only (rides fdpass)");
}

pub const HEADER_SIZE = 32;

/// A sanity ceiling on a serialized-session blob (a session's full scrollback is
/// single-digit to low-tens of MB). Bounds `readBlob`'s allocation so a corrupt
/// `aux` cannot request an arbitrary allocation.
pub const MAX_BLOB_LEN: u64 = 256 * 1024 * 1024;

pub const Tag = enum(u8) {
    /// W→S: a worker announces a new session's pty master (fd attached) so the
    /// supervisor holds a dup (SIGHUP insurance + handoff source). `session_id`,
    /// `aux` = child pid.
    register_master = 1,
    /// W→S: a session closed; drop the supervisor's dup. `session_id`.
    unregister_master = 2,
    /// S→W: begin handoff — freeze + serialize every session.
    freeze_all = 3,
    /// W→S: one serialized session. `session_id`, `aux` = blob length; the blob
    /// (a `session_transfer` stream) follows on the socket.
    session_state = 4,
    /// W→S: all sessions serialized. `aux` = count.
    freeze_done = 5,
    /// S→W: adopt a handed-off session. `session_id`, `aux` = blob length,
    /// `aux2` = child pid; a pty master fd is attached and the blob follows on
    /// the socket.
    adopt = 6,
    /// W→S: adoption result. `session_id`, `aux` = 1 (ok) / 0 (failed).
    adopt_ack = 7,
    /// W→S: the successor adopted every session and is healthy. `aux` = count.
    ready = 8,
    /// S→W: the predecessor may exit(0) now — the successor is serving.
    shutdown = 9,
    /// S→W: the handoff ABORTED (the successor never came up / never acked). The
    /// predecessor must un-freeze — re-adopt its frozen sessions from the state it
    /// kept — and resume serving. This is the "incumbent survives a failed
    /// successor" path. (Named `unfreeze`; `resume` is a Zig keyword.)
    unfreeze = 10,
};

pub const Frame = struct {
    tag: Tag,
    session_id: u64 = 0,
    /// blob length (session_state / adopt) / count (freeze_done / ready) /
    /// ok-flag (adopt_ack) / child pid (register_master).
    aux: u64 = 0,
    /// child pid (adopt); zero otherwise.
    aux2: u64 = 0,

    pub fn encode(self: Frame) [HEADER_SIZE]u8 {
        var buf = [_]u8{0} ** HEADER_SIZE;
        buf[0] = @intFromEnum(self.tag);
        std.mem.writeInt(u64, buf[8..16], self.session_id, .little);
        std.mem.writeInt(u64, buf[16..24], self.aux, .little);
        std.mem.writeInt(u64, buf[24..32], self.aux2, .little);
        return buf;
    }

    pub fn decode(buf: *const [HEADER_SIZE]u8) error{InvalidFrameTag}!Frame {
        const tag = std.meta.intToEnum(Tag, buf[0]) catch return error.InvalidFrameTag;
        return .{
            .tag = tag,
            .session_id = std.mem.readInt(u64, buf[8..16], .little),
            .aux = std.mem.readInt(u64, buf[16..24], .little),
            .aux2 = std.mem.readInt(u64, buf[24..32], .little),
        };
    }
};

pub const RecvResult = struct {
    frame: Frame,
    /// Number of fds attached (0 or 1 for this protocol); the fd, if any, is in
    /// `fds_out[0]`.
    fd_count: usize,
};

pub const SendError = fdpass.SendError;
pub const RecvFrameError = fdpass.RecvError || error{InvalidFrameTag};
pub const BlobError = error{ Closed, BlobTooLarge } || posix.WriteError || posix.ReadError || Allocator.Error;

/// Send one control frame, optionally attaching `fds` (a pty master). A trailing
/// blob (for `session_state`/`adopt`) is the caller's responsibility via
/// `writeBlob` immediately after.
pub fn sendFrame(sock: posix.socket_t, frame: Frame, fds: []const posix.fd_t) SendError!void {
    const hdr = frame.encode();
    try fdpass.sendMsg(sock, &hdr, fds);
}

/// Receive one control frame, collecting any attached fd into `fds_out` (pass a
/// 1-element buffer). Any trailing blob is the caller's to read (`readBlob`,
/// `frame.aux` bytes). On a bad tag the attached fd (if any) is closed.
pub fn recvFrame(sock: posix.socket_t, fds_out: []posix.fd_t) RecvFrameError!RecvResult {
    var hdr: [HEADER_SIZE]u8 = undefined;
    const r = try fdpass.recvMsg(sock, &hdr, fds_out);
    const frame = Frame.decode(&hdr) catch |err| {
        for (fds_out[0..r.fd_count]) |fd| posix.close(fd);
        return err;
    };
    return .{ .frame = frame, .fd_count = r.fd_count };
}

/// Write a blob (a serialized session) to the socket, handling short writes.
pub fn writeBlob(sock: posix.socket_t, bytes: []const u8) BlobError!void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = try posix.write(sock, bytes[off..]);
        if (n == 0) return error.Closed;
        off += n;
    }
}

/// Read a `len`-byte blob (the length came from `frame.aux`) into a fresh
/// allocation the caller owns. Rejects an implausibly large length up front.
pub fn readBlob(sock: posix.socket_t, alloc: Allocator, len: u64) BlobError![]u8 {
    if (len > MAX_BLOB_LEN) return error.BlobTooLarge;
    const buf = try alloc.alloc(u8, @intCast(len));
    errdefer alloc.free(buf);
    var off: usize = 0;
    while (off < buf.len) {
        const n = try posix.read(sock, buf[off..]);
        if (n == 0) return error.Closed;
        off += n;
    }
    return buf;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn testSocketpair() ![2]posix.fd_t {
    var sv: [2]posix.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(
        @intCast(posix.AF.UNIX),
        @intCast(posix.SOCK.STREAM),
        0,
        &sv,
    ));
    return sv;
}

test "handoff_protocol: Frame encode/decode round-trips every tag" {
    const testing = std.testing;
    inline for (.{
        Tag.register_master, Tag.unregister_master, Tag.freeze_all,
        Tag.session_state,   Tag.freeze_done,       Tag.adopt,
        Tag.adopt_ack,       Tag.ready,             Tag.shutdown,
        Tag.unfreeze,
    }) |tag| {
        const f: Frame = .{ .tag = tag, .session_id = 0xDEAD_BEEF_1234_5678, .aux = 0x99, .aux2 = 0x4321 };
        const bytes = f.encode();
        const g = try Frame.decode(&bytes);
        try testing.expectEqual(f.tag, g.tag);
        try testing.expectEqual(f.session_id, g.session_id);
        try testing.expectEqual(f.aux, g.aux);
        try testing.expectEqual(f.aux2, g.aux2);
    }
}

test "handoff_protocol: decode rejects an unknown tag" {
    const testing = std.testing;
    var bytes = [_]u8{0} ** HEADER_SIZE;
    bytes[0] = 0xFE; // not a valid Tag
    try testing.expectError(error.InvalidFrameTag, Frame.decode(&bytes));
}

test "handoff_protocol: a fieldless frame (freeze_all) round-trips over a socket" {
    const testing = std.testing;
    const sv = try testSocketpair();
    defer posix.close(sv[0]);
    defer posix.close(sv[1]);

    try sendFrame(sv[0], .{ .tag = .freeze_all }, &.{});
    var fds: [1]posix.fd_t = undefined;
    const r = try recvFrame(sv[1], &fds);
    try testing.expectEqual(Tag.freeze_all, r.frame.tag);
    try testing.expectEqual(@as(usize, 0), r.fd_count);
}

test "handoff_protocol: register_master carries a live pty master fd" {
    const testing = std.testing;
    const sv = try testSocketpair();
    defer posix.close(sv[0]);
    defer posix.close(sv[1]);

    const pipe_fds = try posix.pipe();
    defer posix.close(pipe_fds[1]);
    try sendFrame(sv[0], .{ .tag = .register_master, .session_id = 777 }, &.{pipe_fds[0]});
    posix.close(pipe_fds[0]);

    var fds: [1]posix.fd_t = undefined;
    const r = try recvFrame(sv[1], &fds);
    try testing.expectEqual(Tag.register_master, r.frame.tag);
    try testing.expectEqual(@as(u64, 777), r.frame.session_id);
    try testing.expectEqual(@as(usize, 1), r.fd_count);

    // Prove it's the same object.
    const got = fds[0];
    defer posix.close(got);
    try testing.expectEqual(@as(usize, 3), try posix.write(pipe_fds[1], "abc"));
    var buf: [3]u8 = undefined;
    try testing.expectEqual(@as(usize, 3), try posix.read(got, &buf));
    try testing.expectEqualStrings("abc", &buf);
}

test "handoff_protocol: a sequence of frames + a blob-bearing frame stays in sync" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const sv = try testSocketpair();
    defer posix.close(sv[0]);
    defer posix.close(sv[1]);

    // Sender: freeze_all, then session_state{id, blob}, then freeze_done{count}.
    const blob = "SERIALIZED-SESSION-STATE-BYTES";
    try sendFrame(sv[0], .{ .tag = .freeze_all }, &.{});
    try sendFrame(sv[0], .{ .tag = .session_state, .session_id = 42, .aux = blob.len }, &.{});
    try writeBlob(sv[0], blob);
    try sendFrame(sv[0], .{ .tag = .freeze_done, .aux = 1 }, &.{});

    // Receiver reads them back IN ORDER — the fixed header framing must not let
    // the blob desync the following frame.
    var fds: [1]posix.fd_t = undefined;

    const r1 = try recvFrame(sv[1], &fds);
    try testing.expectEqual(Tag.freeze_all, r1.frame.tag);

    const r2 = try recvFrame(sv[1], &fds);
    try testing.expectEqual(Tag.session_state, r2.frame.tag);
    try testing.expectEqual(@as(u64, 42), r2.frame.session_id);
    const got_blob = try readBlob(sv[1], alloc, r2.frame.aux);
    defer alloc.free(got_blob);
    try testing.expectEqualStrings(blob, got_blob);

    const r3 = try recvFrame(sv[1], &fds);
    try testing.expectEqual(Tag.freeze_done, r3.frame.tag);
    try testing.expectEqual(@as(u64, 1), r3.frame.aux);
}

test "handoff_protocol: readBlob rejects an oversized length" {
    const testing = std.testing;
    const sv = try testSocketpair();
    defer posix.close(sv[0]);
    defer posix.close(sv[1]);
    try testing.expectError(error.BlobTooLarge, readBlob(sv[1], testing.allocator, MAX_BLOB_LEN + 1));
}
