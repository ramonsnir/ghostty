//! Darwin `SCM_RIGHTS` message passing over an `AF_UNIX` `SOCK_STREAM` socket:
//! send a small header alongside 0..N file descriptors, in one `sendmsg`.
//!
//! This is the transport primitive for the **host handoff** (see
//! `HOST-HANDOFF.md`): the session-less supervisor and its workers exchange
//! control frames — some of which carry a live pty master fd — over an inherited
//! `socketpair`. fds cannot be inherited between sibling workers and `execve`
//! drops the `FD_CLOEXEC` pty masters, so `SCM_RIGHTS` is the only way to move a
//! live master between these processes.
//!
//! ## Framing model
//!
//! The control channel uses a FIXED-SIZE header for every frame. The receiver
//! always `recvMsg`s exactly that header size: the first `recvmsg` picks up any
//! ancillary fds (delivered with the sending `sendmsg`'s first data byte) plus up
//! to `header_buf.len` header bytes; a partial header is then filled with plain
//! reads (no further ancillary). Because the iovec is bounded to the header size,
//! a `recvMsg` NEVER over-reads into a trailing variable-length blob — the caller
//! reads the blob from the stream separately. This is the standard way to frame
//! fd-passing over a boundary-less `SOCK_STREAM`.
//!
//! Zig 0.15.2's std exposes `std.posix.sendmsg` and `std.c.recvmsg`, but its
//! `cmsghdr`/`CMSG_*`/`SCM` are aliased to Solaris only — so the Darwin control-
//! message layout and the `CMSG_SPACE`/`CMSG_LEN` math are hand-rolled here. macOS
//! aligns cmsg regions to 4 bytes (`__DARWIN_ALIGN32`), NOT `sizeof(size_t)`.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

comptime {
    // The cmsg ABI below is Darwin-specific (12-byte header, 4-byte alignment).
    if (builtin.os.tag != .macos) @compileError("fdpass is macOS-only (Darwin cmsg ABI)");
}

/// Ancillary level for socket-level control messages (`std.c.SOL.SOCKET` on Darwin).
const SOL_SOCKET: c_int = 0xffff;
/// Ancillary type: the control message carries rights (fds). Not exposed by Zig
/// std for Darwin (`std.c.SCM` is Solaris-only).
const SCM_RIGHTS: c_int = 0x01;

/// The most fds we will pass in a single message. A handoff moves at most one
/// master per session; 64 is a comfortable ceiling that keeps the control buffer
/// a fixed, stack-friendly size.
pub const MAX_FDS = 64;

/// Darwin `struct cmsghdr` (`<sys/socket.h>`): a 12-byte header immediately
/// followed by the control data. `len` (`cmsg_len`) counts header + data
/// (`CMSG_LEN`), NOT the padded space.
const cmsghdr = extern struct {
    len: posix.socklen_t, // cmsg_len  (u32)
    level: c_int, // cmsg_level
    type: c_int, // cmsg_type
};

comptime {
    // Darwin's CMSG macros assume exactly this 12-byte, 4-byte-aligned layout.
    std.debug.assert(@sizeOf(cmsghdr) == 12);
    std.debug.assert(@alignOf(cmsghdr) == 4);
    std.debug.assert(@sizeOf(posix.fd_t) == 4); // c_int
}

/// `__DARWIN_ALIGN32`: round up to a 4-byte boundary.
inline fn align32(n: usize) usize {
    return (n + 3) & ~@as(usize, 3);
}

/// `CMSG_SPACE(payload_len)`: total control-buffer bytes for one cmsg whose data
/// region is `payload_len` bytes (padded header + padded data).
inline fn cmsgSpace(payload_len: usize) usize {
    return align32(@sizeOf(cmsghdr)) + align32(payload_len);
}

/// `CMSG_LEN(payload_len)`: the value stored in `cmsg_len` — padded header plus
/// the UNpadded data length.
inline fn cmsgLen(payload_len: usize) usize {
    return align32(@sizeOf(cmsghdr)) + payload_len;
}

/// Byte offset of the fd array within the control buffer (`CMSG_DATA`).
const DATA_OFFSET = align32(@sizeOf(cmsghdr));
/// Fixed control-buffer size, sized for the maximum fd count.
const CONTROL_BUF_SIZE = cmsgSpace(MAX_FDS * @sizeOf(posix.fd_t));

pub const SendError = posix.SendMsgError || error{ShortSend};

pub const RecvError = error{
    /// The peer closed (EOF) before or partway through the header.
    Closed,
    /// The control data did not fit and was truncated (`MSG_CTRUNC`); some fds
    /// were dropped. Fatal — a partial fd set is unsafe. Any fds that did land
    /// are closed before returning.
    ControlTruncated,
    /// Ancillary data was present but was not a single well-formed
    /// `SOL_SOCKET`/`SCM_RIGHTS` cmsg carrying a whole number of fds within the
    /// caller's `fds_out` cap.
    UnexpectedControlMessage,
    WouldBlock,
    ConnectionResetByPeer,
    SocketNotConnected,
} || posix.UnexpectedError;

/// The result of `recvMsg`: how many header bytes and fds arrived. `header_len`
/// equals the requested `header_buf.len` on success (the header is filled
/// exactly); `fd_count` is 0 for a frame that carried no fds.
pub const RecvResult = struct {
    header_len: usize,
    fd_count: usize,
};

/// Send `header` (>=1 byte; Darwin requires a non-empty iovec to carry ancillary
/// data reliably) over `sock`, optionally attaching `fds` (0..=`MAX_FDS`) as a
/// single `SCM_RIGHTS` control message. With no fds this is a plain framed write.
/// Blocks until sent. A short write on the header is a fatal `error.ShortSend`
/// (won't happen for the tiny fixed headers this channel uses on a socketpair).
pub fn sendMsg(sock: posix.socket_t, header: []const u8, fds: []const posix.fd_t) SendError!void {
    std.debug.assert(header.len >= 1);
    std.debug.assert(fds.len <= MAX_FDS);

    var iov = [_]posix.iovec_const{.{ .base = header.ptr, .len = header.len }};

    var control: [CONTROL_BUF_SIZE]u8 align(@alignOf(cmsghdr)) = undefined;
    var control_ptr: ?*const anyopaque = null;
    var control_len: posix.socklen_t = 0;
    if (fds.len > 0) {
        const data_len = fds.len * @sizeOf(posix.fd_t);
        const hdr: *cmsghdr = @ptrCast(@alignCast(&control));
        hdr.* = .{
            .len = @intCast(cmsgLen(data_len)),
            .level = SOL_SOCKET,
            .type = SCM_RIGHTS,
        };
        @memcpy(control[DATA_OFFSET..][0..data_len], std.mem.sliceAsBytes(fds));
        control_ptr = &control;
        control_len = @intCast(cmsgSpace(data_len));
    }

    const msg: posix.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = control_ptr,
        .controllen = control_len,
        .flags = 0,
    };

    const n = try posix.sendmsg(sock, &msg, 0);
    if (n != header.len) return error.ShortSend;
}

/// Receive one framed message: fill `header_buf` EXACTLY (blocking) and collect
/// up to `fds_out.len` fds. The first `recvmsg` picks up any ancillary fds plus
/// whatever header bytes are available; a partial header is completed with plain
/// reads. Because the iovec is bounded to `header_buf.len`, this never consumes a
/// trailing blob — read that from `sock` afterwards. On `MSG_CTRUNC` the fds that
/// arrived are closed and `error.ControlTruncated` is returned.
pub fn recvMsg(sock: posix.socket_t, header_buf: []u8, fds_out: []posix.fd_t) RecvError!RecvResult {
    std.debug.assert(header_buf.len >= 1);
    std.debug.assert(fds_out.len <= MAX_FDS);

    var iov = [_]posix.iovec{.{ .base = header_buf.ptr, .len = header_buf.len }};
    var control: [CONTROL_BUF_SIZE]u8 align(@alignOf(cmsghdr)) = undefined;

    var msg: posix.msghdr = .{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = &control,
        .controllen = @intCast(cmsgSpace(MAX_FDS * @sizeOf(posix.fd_t))),
        .flags = 0,
    };

    const n = try recvmsgRetry(sock, &msg);
    if (n == 0) return error.Closed;

    const fd_count = try extractFdsOptional(&msg, fds_out);

    if ((msg.flags & @as(i32, posix.MSG.CTRUNC)) != 0) {
        for (fds_out[0..fd_count]) |fd| posix.close(fd);
        return error.ControlTruncated;
    }

    // The fds rode the first recvmsg. Fill any remaining header bytes with plain
    // reads (no more ancillary data can arrive for this frame).
    var got: usize = @intCast(n);
    while (got < header_buf.len) {
        const m = posix.read(sock, header_buf[got..]) catch |err| switch (err) {
            error.WouldBlock => return error.WouldBlock,
            error.ConnectionResetByPeer => return error.ConnectionResetByPeer,
            error.SocketNotConnected => return error.SocketNotConnected,
            else => {
                // Close the fds we already took so a truncated-header frame does
                // not leak them.
                for (fds_out[0..fd_count]) |fd| posix.close(fd);
                return error.Closed;
            },
        };
        if (m == 0) {
            for (fds_out[0..fd_count]) |fd| posix.close(fd);
            return error.Closed; // EOF mid-header
        }
        got += m;
    }

    return .{ .header_len = got, .fd_count = fd_count };
}

/// Parse the `SCM_RIGHTS` cmsg (if any) out of a received `msghdr`, copying its
/// fds into `out`. Returns 0 when the frame carried no ancillary data (a plain
/// header-only frame); errors only on a malformed control message.
fn extractFdsOptional(msg: *const posix.msghdr, out: []posix.fd_t) error{UnexpectedControlMessage}!usize {
    const control = msg.control orelse return 0;
    const cl: usize = msg.controllen;
    if (cl == 0) return 0;
    if (cl < cmsgLen(@sizeOf(posix.fd_t))) return error.UnexpectedControlMessage;

    const hdr: *const cmsghdr = @ptrCast(@alignCast(control));
    if (hdr.level != SOL_SOCKET or hdr.type != SCM_RIGHTS) return error.UnexpectedControlMessage;

    const hlen: usize = hdr.len;
    if (hlen < DATA_OFFSET or hlen > cl) return error.UnexpectedControlMessage;
    const data_len = hlen - DATA_OFFSET;
    if (data_len % @sizeOf(posix.fd_t) != 0) return error.UnexpectedControlMessage;
    const count = data_len / @sizeOf(posix.fd_t);
    if (count > out.len) return error.UnexpectedControlMessage;
    if (count == 0) return 0;

    const base: [*]const u8 = @ptrCast(control);
    @memcpy(std.mem.sliceAsBytes(out[0..count]), base[DATA_OFFSET .. DATA_OFFSET + data_len]);
    return count;
}

/// `recvmsg` with `EINTR` retry, translating the errno set we can hit on a
/// blocking `AF_UNIX` stream socket.
fn recvmsgRetry(sock: posix.socket_t, msg: *posix.msghdr) RecvError!usize {
    while (true) {
        const rc = std.c.recvmsg(sock, msg, 0);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .CONNRESET => return error.ConnectionResetByPeer,
            .NOTCONN => return error.SocketNotConnected,
            .BADF => unreachable, // caller passed a live socket
            .FAULT => unreachable, // buffers are in our address space
            .INVAL => unreachable, // msghdr is well-formed
            .NOTSOCK => unreachable, // caller passed a socket
            else => |e| return posix.unexpectedErrno(e),
        }
    }
}

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

test "sendMsg/recvMsg round-trips a header + a live fd over a socketpair" {
    const testing = std.testing;

    const sv = try testSocketpair();
    defer posix.close(sv[0]);
    defer posix.close(sv[1]);

    // Send the READ end of a pipe across with a header; then prove the fd names
    // the same kernel object by writing to our write end and reading it back.
    const pipe_fds = try posix.pipe();
    defer posix.close(pipe_fds[1]);

    const header = [_]u8{ 0xAB, 1, 2, 3, 4, 5, 6, 7 };
    try sendMsg(sv[0], &header, &.{pipe_fds[0]});
    posix.close(pipe_fds[0]); // the sender no longer needs its copy

    var hbuf: [8]u8 = undefined;
    var fds: [1]posix.fd_t = undefined;
    const r = try recvMsg(sv[1], &hbuf, &fds);
    try testing.expectEqual(@as(usize, 8), r.header_len);
    try testing.expectEqual(@as(usize, 1), r.fd_count);
    try testing.expectEqualSlices(u8, &header, &hbuf);

    const got = fds[0];
    defer posix.close(got);
    const payload = "hi";
    try testing.expectEqual(payload.len, try posix.write(pipe_fds[1], payload));
    var buf: [8]u8 = undefined;
    const rn = try posix.read(got, &buf);
    try testing.expectEqualStrings(payload, buf[0..rn]);
}

test "sendMsg/recvMsg round-trips a header with NO fds" {
    const testing = std.testing;

    const sv = try testSocketpair();
    defer posix.close(sv[0]);
    defer posix.close(sv[1]);

    const header = [_]u8{ 0x11, 0x22, 0x33, 0x44 };
    try sendMsg(sv[0], &header, &.{});

    var hbuf: [4]u8 = undefined;
    var fds: [1]posix.fd_t = undefined;
    const r = try recvMsg(sv[1], &hbuf, &fds);
    try testing.expectEqual(@as(usize, 4), r.header_len);
    try testing.expectEqual(@as(usize, 0), r.fd_count);
    try testing.expectEqualSlices(u8, &header, &hbuf);
}

test "recvMsg fills a fixed header exactly and leaves a trailing blob on the stream" {
    const testing = std.testing;

    const sv = try testSocketpair();
    defer posix.close(sv[0]);
    defer posix.close(sv[1]);

    // A fixed 6-byte header (carrying an fd), immediately followed by a blob
    // written as ordinary stream bytes. recvMsg must consume ONLY the 6 header
    // bytes so the blob reads back intact.
    const pipe_fds = try posix.pipe();
    defer posix.close(pipe_fds[0]);
    defer posix.close(pipe_fds[1]);

    const header = [_]u8{ 0x01, 0, 0, 0, 0, 42 };
    const blob = "the quick brown fox";
    try sendMsg(sv[0], &header, &.{pipe_fds[0]});
    try testing.expectEqual(blob.len, try posix.write(sv[0], blob));

    var hbuf: [6]u8 = undefined;
    var fds: [1]posix.fd_t = undefined;
    const r = try recvMsg(sv[1], &hbuf, &fds);
    try testing.expectEqualSlices(u8, &header, &hbuf);
    try testing.expectEqual(@as(usize, 1), r.fd_count);
    posix.close(fds[0]);

    var blob_buf: [64]u8 = undefined;
    const bn = try posix.read(sv[1], blob_buf[0..blob.len]);
    try testing.expectEqualStrings(blob, blob_buf[0..bn]);
}

test "recvMsg reports EOF as Closed" {
    const testing = std.testing;

    const sv = try testSocketpair();
    defer posix.close(sv[1]);

    posix.close(sv[0]); // peer gone → EOF on the next recv
    var hbuf: [4]u8 = undefined;
    var fds: [1]posix.fd_t = undefined;
    try testing.expectError(error.Closed, recvMsg(sv[1], &hbuf, &fds));
}
