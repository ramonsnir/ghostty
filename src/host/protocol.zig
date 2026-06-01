//! Phase 2a wire protocol: length-prefixed binary frames over an AF_UNIX
//! SOCK_STREAM connection between the headless ghostty-host and a GUI client.
//!
//! ## Framing
//!
//! Each frame on the wire is:
//!
//!     [u32 BE length][1 byte FrameType tag][length-1 bytes payload]
//!
//! The 4-byte length prefix is BIG-ENDIAN and covers `tag + payload` (i.e.
//! `len == 1 + payload.len`). See `writeFrame` / `FrameReader`.
//!
//! ## Endianness split (deliberate deviation, documented for Phase 2b)
//!
//! The plan §2 specifies the length prefix as 4-byte BE. We honor that for the
//! prefix ONLY (`writeU32BE`/`readU32BE`). EVERY in-frame scalar field is
//! LITTLE-ENDIAN so we can reuse the Phase-1 `RenderState.zig` serializer
//! helpers (`writeInt`/`readInt`/`writeRGB`/`readRGB`) verbatim, including the
//! GridFrame payload which IS the `Snapshot.serialize` byte form. A Phase-2b
//! GUI client MUST match this split: BE length prefix, LE in-frame scalars.
//!
//! ## Frame structs
//!
//! Each frame type is a `struct` with:
//!   - `encode(self, alloc) ![]u8`   -> payload bytes (NOT including tag/len)
//!   - `decode(alloc, payload) !Self`
//!   - `deinit(self, alloc) void`    (frees any owned slices)
//!
//! `writeFrame(w, tag, payload)` prepends the BE length + tag. A `FrameReader`
//! reassembles complete frames from arbitrary partial socket reads.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const RenderState = @import("RenderState.zig");
const terminalpkg = @import("../terminal/main.zig");

pub const PROTOCOL_VERSION_MAJOR: u16 = 1;
pub const PROTOCOL_VERSION_MINOR: u16 = 0;

/// Maximum on-wire frame length (the value of the BE length prefix, i.e.
/// tag + payload). Bounds per-connection buffer growth and the speculative
/// allocation in `readBytes`: a corrupt/oversized length prefix (up to ~4 GiB)
/// from a desynced or buggy local peer would otherwise force `FrameReader.buf`
/// to grow unboundedly (DoS-against-self) and `readBytes` to attempt a huge
/// allocation before any bounds check. 64 MiB is comfortably above the largest
/// plausible GridFrame (a full grid + style/grapheme/selection tables) yet far
/// below the address-space-exhausting end of u32. On overrun the decode path
/// returns `error.InvalidFrame`, which `Server.readLoop` already treats as a
/// clean connection close. (finding P6 / framereader-no-len-cap.)
pub const MAX_FRAME_LEN: u32 = 64 * 1024 * 1024;

/// The frame type tag. One byte, first byte of every frame's payload region
/// (after the BE length prefix).
pub const FrameType = enum(u8) {
    hello,
    hello_ack,
    attach,
    attached,
    detach,
    close,
    input,
    resize,
    focus,
    grid_frame,
    mode_frame,
    child_exited,
    ping,
    pong,
};

/// A decoded but not-yet-typed frame: the tag plus the raw payload bytes
/// (payload does NOT include the tag byte). The payload slice is owned by the
/// FrameReader's internal buffer until the next `next` call mutates it, so
/// callers MUST copy/decode it before calling `next` again. (decode functions
/// copy what they need.)
pub const Frame = struct {
    tag: FrameType,
    payload: []const u8,
};

// --- BE length-prefix helpers (prefix only; in-frame scalars are LE) ---

fn writeU32BE(w: anytype, v: u32) !void {
    try w.writeInt(u32, v, .big);
}

/// Write a complete frame: BE u32 length (= 1 + payload.len), the tag byte,
/// then the payload.
pub fn writeFrame(w: anytype, tag: FrameType, payload: []const u8) !void {
    // Producer/consumer size symmetry (finding PROTO-2): FrameReader.next
    // rejects any frame whose BE length prefix exceeds MAX_FRAME_LEN with
    // error.InvalidFrame (which closes the connection). Without this guard the
    // host could serialize a frame (e.g. a GridFrame at extreme grid
    // dimensions, > 64 MiB but < 4 GiB) that any conforming peer — including
    // this same FrameReader — immediately rejects, dropping the connection
    // mid-session instead of failing visibly at the producer. Fail here so the
    // GridFrame producer (onRender/pushFullFrames) sees a logged drop rather
    // than a silent connection kill.
    //
    // Bound payload.len against the cap in usize BEFORE narrowing to u32
    // (finding PC-1): an oversized payload (> u32 range) would make the
    // @intCast illegal behavior — a panic in safe builds, a silent
    // truncation/wrap in the shipped ReleaseFast lib — which would corrupt
    // `len` before the FrameTooLarge guard could fire and write a bogus BE
    // prefix, permanently desyncing the framed stream. `payload.len + 1`
    // cannot overflow usize for any real slice, and once it is <=
    // MAX_FRAME_LEN the @intCast to u32 is always in range.
    if (payload.len + 1 > MAX_FRAME_LEN) return error.FrameTooLarge;
    const len: u32 = @intCast(1 + payload.len);
    try writeU32BE(w, len);
    try w.writeByte(@intFromEnum(tag));
    try w.writeAll(payload);
}

/// Encode `tag`+`frame.encode(alloc)` into a freshly-allocated framed byte
/// buffer (BE length prefix + tag + payload). Caller owns the result. This is
/// the convenience used by the Server's broadcast path and the tests.
pub fn encodeFrame(alloc: Allocator, tag: FrameType, frame: anytype) ![]u8 {
    const payload = try frame.encode(alloc);
    defer alloc.free(payload);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    try writeFrame(buf.writer(alloc), tag, payload);
    return buf.toOwnedSlice(alloc);
}

/// A partial-read-tolerant frame reassembler. Feed it arbitrary chunks of
/// socket bytes via `push`; pull complete frames via `next`. Models its buffer
/// on the Phase-1 ArrayList usage in RenderState.zig.
pub const FrameReader = struct {
    buf: std.ArrayList(u8) = .empty,
    /// How many bytes at the front of `buf` have been consumed by completed
    /// frames and can be compacted away.
    consumed: usize = 0,

    pub fn deinit(self: *FrameReader, alloc: Allocator) void {
        self.buf.deinit(alloc);
        self.* = undefined;
    }

    /// Append raw socket bytes.
    pub fn push(self: *FrameReader, alloc: Allocator, bytes: []const u8) !void {
        try self.buf.appendSlice(alloc, bytes);
    }

    /// Return the next complete frame, or null if fewer than `4 + len` bytes
    /// are buffered. On success, exactly one frame's bytes are consumed. The
    /// returned `payload` aliases the internal buffer and is valid only until
    /// the next `next`/`push` call.
    pub fn next(self: *FrameReader, alloc: Allocator) !?Frame {
        _ = alloc;

        // Compact AT THE START (not after slicing the payload): the returned
        // payload aliases self.buf, so we must never move/clear the buffer
        // after computing it within the same call. Compaction here keeps the
        // returned payload valid until the next next()/push() call (the
        // documented lifetime).
        if (self.consumed > 0) {
            if (self.consumed >= self.buf.items.len) {
                self.buf.clearRetainingCapacity();
                self.consumed = 0;
            } else if (self.consumed > 64 * 1024) {
                const rem = self.buf.items.len - self.consumed;
                std.mem.copyForwards(
                    u8,
                    self.buf.items[0..rem],
                    self.buf.items[self.consumed..],
                );
                self.buf.shrinkRetainingCapacity(rem);
                self.consumed = 0;
            }
        }

        const avail = self.buf.items[self.consumed..];
        if (avail.len < 4) return null;

        const len = std.mem.readInt(u32, avail[0..4], .big);
        if (len < 1) return error.InvalidFrame;
        // Bound the claimed length BEFORE waiting for that many bytes, so a
        // corrupt prefix can't drive unbounded buffer growth (finding P6).
        if (len > MAX_FRAME_LEN) return error.InvalidFrame;
        const total = 4 + @as(usize, len);
        if (avail.len < total) return null;

        const tag_byte = avail[4];
        const tag = std.meta.intToEnum(FrameType, tag_byte) catch
            return error.InvalidFrameType;
        const payload = avail[5..total];

        self.consumed += total;

        return .{ .tag = tag, .payload = payload };
    }
};

// --- LE scalar helpers (mirror RenderState.zig wire stability) ---

fn writeInt(w: anytype, comptime T: type, v: T) !void {
    try w.writeInt(T, v, .little);
}

fn readInt(r: anytype, comptime T: type) !T {
    return r.readInt(T, .little);
}

fn writeBool(w: anytype, v: bool) !void {
    try w.writeByte(@intFromBool(v));
}

fn readBool(r: anytype) !bool {
    return (try r.readByte()) != 0;
}

/// Write a length-prefixed byte slice (u32 LE length + bytes).
fn writeBytes(w: anytype, bytes: []const u8) !void {
    // Bound the length BEFORE narrowing to u32 (finding PCR-1), mirroring the
    // PC-1 guard in writeFrame. A slice longer than u32 range would make the
    // @intCast illegal behavior — a panic in safe builds, a silent
    // truncation/wrap in ReleaseFast — writing a length prefix smaller than the
    // bytes writeAll emits, permanently desyncing the framed stream. A single
    // field can never exceed the whole-frame cap, so bound against MAX_FRAME_LEN.
    if (bytes.len > MAX_FRAME_LEN) return error.FrameTooLarge;
    try writeInt(w, u32, @intCast(bytes.len));
    try w.writeAll(bytes);
}

/// Read a length-prefixed byte slice from a `fixedBufferStream` reader. Caller
/// owns the returned slice. `fbs` is the stream backing `r`; we validate the
/// claimed length against the bytes actually remaining in the payload BEFORE
/// allocating, so a corrupt/oversized inner length can't trigger a large
/// speculative allocation (finding P6). Returns `error.InvalidFrame` on
/// overrun.
///
/// INVARIANT (finding PROTO-3): the bound used for the anti-DoS speculative-
/// allocation guard is `fbs.buffer.len - fbs.pos`, i.e. the bytes remaining in
/// the WHOLE payload — NOT a field-local bound. This is tight ONLY because the
/// length-prefixed slice must be the LAST decoded field of its frame (so
/// "remaining payload" == "bytes for this slice"). Both current callers honor
/// this: Hello.decode (identity_bundle_id is last) and Input.decode (bytes is
/// last). If a future frame places a writeBytes-encoded slice BEFORE other
/// fields, this guard would become permissive (it would accept an over-claimed
/// length up to the trailing fields' size — the actual over-read is still
/// caught by readNoEof below, but the speculative alloc would no longer be
/// bounded to the true field size). In that case make the bound field-local
/// (or cap at MAX_FRAME_LEN regardless of position). NOTE: there is
/// deliberately NO debug assert on the trailing-field position here — the
/// `len` value is attacker-controlled (see the SI-ASSERT-PANIC note in the
/// body), so the invariant must be enforced at the PRODUCER, not asserted on
/// untrusted wire input.
fn readBytes(alloc: Allocator, fbs: anytype, r: anytype) ![]u8 {
    const len = try readInt(r, u32);
    const remaining = fbs.buffer.len - fbs.pos;
    // Trailing-field invariant: a well-formed slice consumes ALL remaining
    // payload bytes (len == remaining); a corrupt over-claim is len > remaining
    // (rejected just below). len < remaining would mean trailing fields after
    // this slice — a layout violation — but `len` is attacker-controlled, so we
    // must NOT assert on it: a peer that UNDER-claims the inner length would
    // otherwise panic (unreachable) the whole multi-session host pre-auth in
    // safe builds (finding SI-ASSERT-PANIC). An under-claim is harmless given
    // the trailing-field invariant (the extra bytes are simply left unconsumed),
    // and the over-claim guard below already bounds the speculative allocation
    // against the true remaining payload. A future non-trailing writeBytes
    // placement must be guarded at the PRODUCER, not on this attacker-supplied
    // length. Malformed peer input therefore returns error.InvalidFrame (a clean
    // connection close), never a process abort.
    if (len > remaining) return error.InvalidFrame;
    const out = try alloc.alloc(u8, len);
    errdefer alloc.free(out);
    try r.readNoEof(out);
    return out;
}

// --- Frame structs ---

pub const Hello = struct {
    protocol_version_major: u16 = PROTOCOL_VERSION_MAJOR,
    protocol_version_minor: u16 = PROTOCOL_VERSION_MINOR,
    /// Owned by this struct (freed by deinit).
    identity_bundle_id: []const u8 = &.{},

    pub fn encode(self: Hello, alloc: Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(alloc);
        const w = buf.writer(alloc);
        try writeInt(w, u16, self.protocol_version_major);
        try writeInt(w, u16, self.protocol_version_minor);
        try writeBytes(w, self.identity_bundle_id);
        return buf.toOwnedSlice(alloc);
    }

    pub fn decode(alloc: Allocator, payload: []const u8) !Hello {
        var fbs = std.io.fixedBufferStream(payload);
        const r = fbs.reader();
        const major = try readInt(r, u16);
        const minor = try readInt(r, u16);
        const id = try readBytes(alloc, &fbs, r);
        return .{
            .protocol_version_major = major,
            .protocol_version_minor = minor,
            .identity_bundle_id = id,
        };
    }

    pub fn deinit(self: *Hello, alloc: Allocator) void {
        alloc.free(self.identity_bundle_id);
        self.* = undefined;
    }
};

pub const HelloAck = struct {
    protocol_version_major: u16 = PROTOCOL_VERSION_MAJOR,
    protocol_version_minor: u16 = PROTOCOL_VERSION_MINOR,
    host_pid: i32,
    host_start_epoch: i64,

    pub fn encode(self: HelloAck, alloc: Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(alloc);
        const w = buf.writer(alloc);
        try writeInt(w, u16, self.protocol_version_major);
        try writeInt(w, u16, self.protocol_version_minor);
        try writeInt(w, i32, self.host_pid);
        try writeInt(w, i64, self.host_start_epoch);
        return buf.toOwnedSlice(alloc);
    }

    pub fn decode(_: Allocator, payload: []const u8) !HelloAck {
        var fbs = std.io.fixedBufferStream(payload);
        const r = fbs.reader();
        return .{
            .protocol_version_major = try readInt(r, u16),
            .protocol_version_minor = try readInt(r, u16),
            .host_pid = try readInt(r, i32),
            .host_start_epoch = try readInt(r, i64),
        };
    }

    pub fn deinit(self: *HelloAck, _: Allocator) void {
        self.* = undefined;
    }
};

/// Attach to an existing session (session_id present) or spawn a fresh one
/// (null). Phase 2a carries no spawn_opts; the host uses default Options.
/// FOLLOWUP (Phase 2b): add a `spawn_opts` field carrying initial dims / cwd /
/// command so the GUI can drive the spawn.
pub const Attach = struct {
    session_id: ?u64 = null,

    pub fn encode(self: Attach, alloc: Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(alloc);
        const w = buf.writer(alloc);
        if (self.session_id) |id| {
            try w.writeByte(1);
            try writeInt(w, u64, id);
        } else {
            try w.writeByte(0);
        }
        return buf.toOwnedSlice(alloc);
    }

    pub fn decode(_: Allocator, payload: []const u8) !Attach {
        var fbs = std.io.fixedBufferStream(payload);
        const r = fbs.reader();
        const present = (try r.readByte()) != 0;
        if (!present) return .{ .session_id = null };
        return .{ .session_id = try readInt(r, u64) };
    }

    pub fn deinit(self: *Attach, _: Allocator) void {
        self.* = undefined;
    }
};

pub const Attached = struct {
    session_id: u64,
    cols: u16,
    rows: u16,

    pub fn encode(self: Attached, alloc: Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(alloc);
        const w = buf.writer(alloc);
        try writeInt(w, u64, self.session_id);
        try writeInt(w, u16, self.cols);
        try writeInt(w, u16, self.rows);
        return buf.toOwnedSlice(alloc);
    }

    pub fn decode(_: Allocator, payload: []const u8) !Attached {
        var fbs = std.io.fixedBufferStream(payload);
        const r = fbs.reader();
        return .{
            .session_id = try readInt(r, u64),
            .cols = try readInt(r, u16),
            .rows = try readInt(r, u16),
        };
    }

    pub fn deinit(self: *Attached, _: Allocator) void {
        self.* = undefined;
    }
};

/// A simple {session_id} frame, shared layout for Detach/Close.
fn SessionIdFrame(comptime tag: FrameType) type {
    _ = tag;
    return struct {
        const Self = @This();
        session_id: u64,

        pub fn encode(self: Self, alloc: Allocator) ![]u8 {
            var buf: std.ArrayList(u8) = .empty;
            errdefer buf.deinit(alloc);
            try writeInt(buf.writer(alloc), u64, self.session_id);
            return buf.toOwnedSlice(alloc);
        }

        pub fn decode(_: Allocator, payload: []const u8) !Self {
            var fbs = std.io.fixedBufferStream(payload);
            return .{ .session_id = try readInt(fbs.reader(), u64) };
        }

        pub fn deinit(self: *Self, _: Allocator) void {
            self.* = undefined;
        }
    };
}

pub const Detach = SessionIdFrame(.detach);
pub const Close = SessionIdFrame(.close);

pub const Input = struct {
    session_id: u64,
    /// Phase-2b FOLLOWUP (finding SI-1): round-trips on the wire but the
    /// Phase-2a Server.dispatch .input arm does not yet apply it — the Termio
    /// write mailbox has no per-write linefeed bit (linefeed is governed by
    /// Termio.flags.linefeed_mode set via a separate message). See the .input
    /// arm in Server.zig for the deferral rationale.
    linefeed: bool = false,
    /// Owned by this struct (freed by deinit).
    bytes: []const u8 = &.{},

    pub fn encode(self: Input, alloc: Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(alloc);
        const w = buf.writer(alloc);
        try writeInt(w, u64, self.session_id);
        try writeBool(w, self.linefeed);
        try writeBytes(w, self.bytes);
        return buf.toOwnedSlice(alloc);
    }

    pub fn decode(alloc: Allocator, payload: []const u8) !Input {
        var fbs = std.io.fixedBufferStream(payload);
        const r = fbs.reader();
        const session_id = try readInt(r, u64);
        const linefeed = try readBool(r);
        const bytes = try readBytes(alloc, &fbs, r);
        return .{ .session_id = session_id, .linefeed = linefeed, .bytes = bytes };
    }

    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.bytes);
        self.* = undefined;
    }
};

/// Resize carries enough to rebuild a `renderer.Size` (see size.zig: screen
/// {width,height}, cell {width,height}, padding {l,r,t,b}).
pub const Resize = struct {
    session_id: u64,
    cols: u16,
    rows: u16,
    cell_width: u32,
    cell_height: u32,
    padding_l: u32 = 0,
    padding_r: u32 = 0,
    padding_t: u32 = 0,
    padding_b: u32 = 0,
    screen_w: u32,
    screen_h: u32,

    pub fn encode(self: Resize, alloc: Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(alloc);
        const w = buf.writer(alloc);
        try writeInt(w, u64, self.session_id);
        try writeInt(w, u16, self.cols);
        try writeInt(w, u16, self.rows);
        try writeInt(w, u32, self.cell_width);
        try writeInt(w, u32, self.cell_height);
        try writeInt(w, u32, self.padding_l);
        try writeInt(w, u32, self.padding_r);
        try writeInt(w, u32, self.padding_t);
        try writeInt(w, u32, self.padding_b);
        try writeInt(w, u32, self.screen_w);
        try writeInt(w, u32, self.screen_h);
        return buf.toOwnedSlice(alloc);
    }

    pub fn decode(_: Allocator, payload: []const u8) !Resize {
        var fbs = std.io.fixedBufferStream(payload);
        const r = fbs.reader();
        return .{
            .session_id = try readInt(r, u64),
            .cols = try readInt(r, u16),
            .rows = try readInt(r, u16),
            .cell_width = try readInt(r, u32),
            .cell_height = try readInt(r, u32),
            .padding_l = try readInt(r, u32),
            .padding_r = try readInt(r, u32),
            .padding_t = try readInt(r, u32),
            .padding_b = try readInt(r, u32),
            .screen_w = try readInt(r, u32),
            .screen_h = try readInt(r, u32),
        };
    }

    pub fn deinit(self: *Resize, _: Allocator) void {
        self.* = undefined;
    }
};

pub const Focus = struct {
    session_id: u64,
    focused: bool,

    pub fn encode(self: Focus, alloc: Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(alloc);
        const w = buf.writer(alloc);
        try writeInt(w, u64, self.session_id);
        try writeBool(w, self.focused);
        return buf.toOwnedSlice(alloc);
    }

    pub fn decode(_: Allocator, payload: []const u8) !Focus {
        var fbs = std.io.fixedBufferStream(payload);
        const r = fbs.reader();
        return .{
            .session_id = try readInt(r, u64),
            .focused = try readBool(r),
        };
    }

    pub fn deinit(self: *Focus, _: Allocator) void {
        self.* = undefined;
    }
};

/// Mirrors apprt.surface.Message.ChildExited (exit_code: u32, runtime_ms: u64).
pub const ChildExited = struct {
    session_id: u64,
    exit_code: u32,
    runtime_ms: u64,

    pub fn encode(self: ChildExited, alloc: Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(alloc);
        const w = buf.writer(alloc);
        try writeInt(w, u64, self.session_id);
        try writeInt(w, u32, self.exit_code);
        try writeInt(w, u64, self.runtime_ms);
        return buf.toOwnedSlice(alloc);
    }

    pub fn decode(_: Allocator, payload: []const u8) !ChildExited {
        var fbs = std.io.fixedBufferStream(payload);
        const r = fbs.reader();
        return .{
            .session_id = try readInt(r, u64),
            .exit_code = try readInt(r, u32),
            .runtime_ms = try readInt(r, u64),
        };
    }

    pub fn deinit(self: *ChildExited, _: Allocator) void {
        self.* = undefined;
    }
};

/// Empty-payload liveness frames.
fn EmptyFrame() type {
    return struct {
        const Self = @This();
        pub fn encode(_: Self, alloc: Allocator) ![]u8 {
            return alloc.alloc(u8, 0);
        }
        pub fn decode(_: Allocator, _: []const u8) !Self {
            return .{};
        }
        pub fn deinit(self: *Self, _: Allocator) void {
            self.* = undefined;
        }
    };
}

pub const Ping = EmptyFrame();
pub const Pong = EmptyFrame();

/// The linchpin frame: a session id plus the expanded RenderState.Snapshot.
/// The payload after session_id is exactly the `Snapshot.serialize` byte form
/// (LE scalars). decode reads session_id then `Snapshot.deserialize`s the rest.
///
/// Ownership: the `snapshot` is owned by this struct after decode; `encode`
/// borrows the caller's snapshot (does not free it). Call `deinit` after
/// decode to free the snapshot's pools.
pub const GridFrame = struct {
    session_id: u64,
    snapshot: RenderState.Snapshot,
    /// True if the snapshot is owned by this struct (set by decode) and must
    /// be freed by deinit. encode-side GridFrames borrow the snapshot.
    owns_snapshot: bool = false,

    pub fn encode(self: GridFrame, alloc: Allocator) ![]u8 {
        const snap_bytes = try self.snapshot.serialize(alloc);
        defer alloc.free(snap_bytes);

        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(alloc);
        const w = buf.writer(alloc);
        try writeInt(w, u64, self.session_id);
        try w.writeAll(snap_bytes);
        return buf.toOwnedSlice(alloc);
    }

    pub fn decode(alloc: Allocator, payload: []const u8) !GridFrame {
        if (payload.len < 8) return error.InvalidFrame;
        const session_id = std.mem.readInt(u64, payload[0..8], .little);
        const snapshot = try RenderState.Snapshot.deserialize(alloc, payload[8..]);
        return .{ .session_id = session_id, .snapshot = snapshot, .owns_snapshot = true };
    }

    pub fn deinit(self: *GridFrame, alloc: Allocator) void {
        if (self.owns_snapshot) self.snapshot.deinit(alloc);
        self.* = undefined;
    }
};

/// The ~14-field input-mode mirror (plan §2.1). A flat fixed-width struct.
///
/// FOLLOWUP / Read-verified note: the boolean modes are sourced from
/// `terminal.modes.get(.<name>)` and verified against `src/terminal/modes.zig`
/// (alt_esc_prefix, cursor_keys, keypad_keys, backarrow_key_mode,
/// ignore_keypad_with_numlock, bracketed_paste, disable_keyboard,
/// mouse_alternate_scroll, alt_screen). `mouse_event`/`mouse_format` are NOT
/// single modes — they live on `Terminal.flags` as `mouse.Event`/`mouse.Format`
/// (modes.zig comment: "you can't get the right event/format based on modes
/// alone"), so we read them from `t.flags`. `mouse_shift_capture` and
/// `modify_other_keys_2` likewise live on `t.flags`. `kitty_flags` is the
/// active-screen-resolved `Screen.kitty_keyboard.current().int()` (u5).
/// `alt_screen_active` is `t.screens.active_key == .alternate`.
pub const ModeFrame = struct {
    session_id: u64,
    alt_esc_prefix: bool = false,
    cursor_keys: bool = false,
    keypad_keys: bool = false,
    backarrow_key_mode: bool = false,
    ignore_keypad_with_numlock: bool = false,
    bracketed_paste: bool = false,
    disable_keyboard: bool = false,
    mouse_alternate_scroll: bool = false,
    /// mouse.Event as a u8 enum index.
    mouse_event: u8 = 0,
    /// mouse.Format as a u8 enum index.
    mouse_format: u8 = 0,
    /// tri-state: 0=null, 1=false, 2=true (Terminal.flags.mouse_shift_capture).
    mouse_shift_capture: u8 = 0,
    modify_other_keys_2: bool = false,
    /// active-screen-resolved kitty keyboard flags (u5 stored in a u8).
    kitty_flags: u8 = 0,
    alt_screen_active: bool = false,

    /// Build a ModeFrame by reading the live terminal. The caller MUST hold
    /// the render mutex (this reads terminal modes/flags).
    pub fn fromTerminal(session_id: u64, t: *const terminalpkg.Terminal) ModeFrame {
        return .{
            .session_id = session_id,
            .alt_esc_prefix = t.modes.get(.alt_esc_prefix),
            .cursor_keys = t.modes.get(.cursor_keys),
            .keypad_keys = t.modes.get(.keypad_keys),
            .backarrow_key_mode = t.modes.get(.backarrow_key_mode),
            .ignore_keypad_with_numlock = t.modes.get(.ignore_keypad_with_numlock),
            .bracketed_paste = t.modes.get(.bracketed_paste),
            .disable_keyboard = t.modes.get(.disable_keyboard),
            .mouse_alternate_scroll = t.modes.get(.mouse_alternate_scroll),
            .mouse_event = @intFromEnum(t.flags.mouse_event),
            .mouse_format = @intFromEnum(t.flags.mouse_format),
            .mouse_shift_capture = @intFromEnum(t.flags.mouse_shift_capture),
            .modify_other_keys_2 = t.flags.modify_other_keys_2,
            .kitty_flags = t.screens.active.kitty_keyboard.current().int(),
            .alt_screen_active = t.screens.active_key == .alternate,
        };
    }

    pub fn encode(self: ModeFrame, alloc: Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(alloc);
        const w = buf.writer(alloc);
        try writeInt(w, u64, self.session_id);
        try writeBool(w, self.alt_esc_prefix);
        try writeBool(w, self.cursor_keys);
        try writeBool(w, self.keypad_keys);
        try writeBool(w, self.backarrow_key_mode);
        try writeBool(w, self.ignore_keypad_with_numlock);
        try writeBool(w, self.bracketed_paste);
        try writeBool(w, self.disable_keyboard);
        try writeBool(w, self.mouse_alternate_scroll);
        try w.writeByte(self.mouse_event);
        try w.writeByte(self.mouse_format);
        try w.writeByte(self.mouse_shift_capture);
        try writeBool(w, self.modify_other_keys_2);
        try w.writeByte(self.kitty_flags);
        try writeBool(w, self.alt_screen_active);
        return buf.toOwnedSlice(alloc);
    }

    pub fn decode(_: Allocator, payload: []const u8) !ModeFrame {
        var fbs = std.io.fixedBufferStream(payload);
        const r = fbs.reader();
        return .{
            .session_id = try readInt(r, u64),
            .alt_esc_prefix = try readBool(r),
            .cursor_keys = try readBool(r),
            .keypad_keys = try readBool(r),
            .backarrow_key_mode = try readBool(r),
            .ignore_keypad_with_numlock = try readBool(r),
            .bracketed_paste = try readBool(r),
            .disable_keyboard = try readBool(r),
            .mouse_alternate_scroll = try readBool(r),
            .mouse_event = try r.readByte(),
            .mouse_format = try r.readByte(),
            .mouse_shift_capture = try r.readByte(),
            .modify_other_keys_2 = try readBool(r),
            .kitty_flags = try r.readByte(),
            .alt_screen_active = try readBool(r),
        };
    }

    pub fn deinit(self: *ModeFrame, _: Allocator) void {
        self.* = undefined;
    }
};
