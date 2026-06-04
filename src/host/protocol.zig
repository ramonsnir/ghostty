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
const renderer = @import("../renderer.zig");
const terminalpkg = @import("../terminal/main.zig");
const point = terminalpkg.point;
const apprt = @import("../apprt.zig");
const color = terminalpkg.color;
const osccolor = terminalpkg.osc.color;

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
    // --- Slice 3b: host-side search ---
    // GUI->host search commands (host decodes + handles in 3b; the GUI sends
    // them in Slice 4).
    set_search,
    search_nav,
    clear_search,
    // host->GUI search status events (host emits in 3b; the GUI consumes in
    // Slice 4). The actual match HIGHLIGHTS ride the existing grid_frame as
    // row.highlights — these two carry only the n/total status.
    search_total,
    search_selected,
    // --- Slice 3c: host-side OSC8 hover links ---
    // GUI->host: report the current hover viewport cell + mods + present flag.
    // host->GUI: the OSC8 link-cell coordinate set for that hover (empty when
    // no link / present=false / mods not held). Regex links stay GUI-side
    // (renderCellMap matches viewport cell text against the mirror), so they
    // are NOT carried on the wire — only OSC8 links, which require host pins.
    hover,
    link_frame,
    // --- Slice 6: the general SurfaceEvent channel ---
    // host->GUI: a forwarded `apprt.surface.Message` (title, bell, OSC52
    // clipboard, pwd_change, dynamic colors, desktop notifications, progress,
    // mouse-shape, shell command-tracking, password-input). The host's
    // StreamHandler emits these; under `.client` the host re-frames them here
    // and the GUI re-injects them into its surface mailbox so the existing
    // Surface drain handles them identically to `.exec`. child_exited and the
    // search counts have dedicated frames and are NOT carried here.
    surface_event,
    // --- Slice 7: scroll-via-host ---
    // GUI->host: repin the host terminal's viewport. Under .client the GUI's
    // local terminal is unused (the renderer draws the host-fed mirror), so
    // scroll must be a request to the host, which owns the real scrollback;
    // the scrolled viewport arrives on the next grid_frame. scroll_viewport
    // encodes terminal.Terminal.ScrollViewport (top/bottom/delta); jump_to_prompt
    // carries a signed prompt delta.
    scroll_viewport,
    jump_to_prompt,
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
/// "remaining payload" == "bytes for this slice"). All current callers honor
/// this: Hello.decode (identity_bundle_id is last), Input.decode (bytes is
/// last), and Attach.decode (working_directory is the last field, after the
/// optional session_id). If a future frame places a writeBytes-encoded slice BEFORE other
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
/// (null). Phase 2a carried no spawn_opts; the host used default Options.
///
/// SPAWN-OPT (Phase 2b, Slice 11): `working_directory` is a spawn-opt — it is
/// only meaningful when `session_id == null` (a fresh spawn). On a REATTACH
/// (session_id present) the host IGNORES it (the existing session keeps its
/// cwd). When null the host uses its default ($HOME via passwd), preserving
/// pre-Slice-11 behavior. It is the LAST encoded field so its length-prefixed
/// `readBytes` honors the trailing-field invariant (see `readBytes`).
pub const Attach = struct {
    session_id: ?u64 = null,

    /// Optional spawn-opt cwd for a FRESH session. Owned by this struct when
    /// non-null (freed by deinit; decode allocates it). `null` => host default.
    working_directory: ?[]const u8 = null,

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
        // Optional working_directory: present-byte then a length-prefixed
        // string. LAST field so readBytes' trailing-field invariant holds.
        if (self.working_directory) |wd| {
            try w.writeByte(1);
            try writeBytes(w, wd);
        } else {
            try w.writeByte(0);
        }
        return buf.toOwnedSlice(alloc);
    }

    pub fn decode(alloc: Allocator, payload: []const u8) !Attach {
        var fbs = std.io.fixedBufferStream(payload);
        const r = fbs.reader();
        const sid_present = (try r.readByte()) != 0;
        const session_id: ?u64 = if (sid_present) try readInt(r, u64) else null;
        const wd_present = (try r.readByte()) != 0;
        const working_directory: ?[]const u8 = if (wd_present)
            try readBytes(alloc, &fbs, r)
        else
            null;
        return .{ .session_id = session_id, .working_directory = working_directory };
    }

    pub fn deinit(self: *Attach, alloc: Allocator) void {
        if (self.working_directory) |wd| alloc.free(wd);
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

    /// Reconstruct the `renderer.Size` the host resize path applies (Slice 9).
    /// The host derives the terminal grid via `Termio.resize` -> `size.grid()`
    /// = (screen - padding) / cell. This helper builds a Size whose `grid()`
    /// yields exactly the AUTHORITATIVE wire {cols, rows} the GUI rendered at,
    /// by setting `screen` = cols*cell + padding so the (screen-padding)/cell
    /// derivation reproduces {cols, rows} exactly, while keeping the wire
    /// cell/padding for the downstream pixel math (terminal width_px/height_px,
    /// size reports).
    ///
    /// Why trust the wire {cols, rows} over the raw wire screen_w/h: the grid
    /// the GUI actually rendered at IS {cols, rows} (the client computes it via
    /// the very same `size.grid()` before sending — see `Client.resize`), so it
    /// is the authoritative source of truth. For a well-formed frame the two
    /// agree exactly (screen_w/h and cols/rows both come from one client-side
    /// `renderer.Size`, so re-deriving the grid from screen_w/h would yield the
    /// same integers — the previous host code did exactly that and was correct
    /// for every frame a healthy client emits). Deriving from {cols, rows}
    /// instead makes the host authoritative-grid driven rather than
    /// pixel-derived: if a peer ever sends an INCONSISTENT frame (cols/rows that
    /// disagree with screen_w/h — e.g. a transient/garbled mid-drag screen, a
    /// buggy peer, or a future protocol change), the host resizes to the grid
    /// the peer says it rendered at instead of collapsing to a re-derived
    /// (possibly near-1x1) grid. The raw wire screen_w/h is intentionally NOT
    /// used for the grid derivation. `.exec`'s own resize path is untouched —
    /// this helper is host/.client only.
    pub fn toSize(self: Resize) renderer.Size {
        // Guard a degenerate cell so `size.grid()`'s float division (and the
        // screen reconstruction below) can't divide/scale by zero.
        const cell_w: u32 = if (self.cell_width == 0) 1 else self.cell_width;
        const cell_h: u32 = if (self.cell_height == 0) 1 else self.cell_height;
        return .{
            .screen = .{
                .width = @as(u32, self.cols) * cell_w + self.padding_l + self.padding_r,
                .height = @as(u32, self.rows) * cell_h + self.padding_t + self.padding_b,
            },
            .cell = .{ .width = cell_w, .height = cell_h },
            .padding = .{
                .left = self.padding_l,
                .right = self.padding_r,
                .top = self.padding_t,
                .bottom = self.padding_b,
            },
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

/// GUI->host: scroll the session's viewport. Encodes
/// `terminal.Terminal.ScrollViewport` as a 1-byte kind tag (0=top, 1=bottom,
/// 2=delta) plus a signed i64 `delta` field. For top/bottom the delta is 0 and
/// ignored; for delta it carries the (sign-extended) isize delta. The on-wire
/// width is i64 so the frame is host-pointer-width independent (isize is 32-bit
/// on some targets); the host re-narrows via @intCast.
pub const ScrollViewport = struct {
    session_id: u64,
    /// 0=top, 1=bottom, 2=delta. Matches `kindFrom`/`toTarget` below.
    kind: u8 = 0,
    delta: i64 = 0,

    pub const kind_top: u8 = 0;
    pub const kind_bottom: u8 = 1;
    pub const kind_delta: u8 = 2;

    /// Build a frame from the core union (GUI/client side).
    pub fn fromTarget(
        session_id: u64,
        target: terminalpkg.Terminal.ScrollViewport,
    ) ScrollViewport {
        return switch (target) {
            .top => .{ .session_id = session_id, .kind = kind_top, .delta = 0 },
            .bottom => .{ .session_id = session_id, .kind = kind_bottom, .delta = 0 },
            .delta => |d| .{
                .session_id = session_id,
                .kind = kind_delta,
                .delta = @intCast(d),
            },
        };
    }

    /// Recover the core union (host side). Returns null for an unknown kind
    /// byte (a desynced/buggy peer) so the dispatcher can drop it rather than
    /// panic.
    pub fn toTarget(self: ScrollViewport) ?terminalpkg.Terminal.ScrollViewport {
        return switch (self.kind) {
            kind_top => .top,
            kind_bottom => .bottom,
            kind_delta => .{ .delta = @intCast(self.delta) },
            else => null,
        };
    }

    pub fn encode(self: ScrollViewport, alloc: Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(alloc);
        const w = buf.writer(alloc);
        try writeInt(w, u64, self.session_id);
        try w.writeByte(self.kind);
        try writeInt(w, i64, self.delta);
        return buf.toOwnedSlice(alloc);
    }

    pub fn decode(_: Allocator, payload: []const u8) !ScrollViewport {
        var fbs = std.io.fixedBufferStream(payload);
        const r = fbs.reader();
        return .{
            .session_id = try readInt(r, u64),
            .kind = try r.readByte(),
            .delta = try readInt(r, i64),
        };
    }

    pub fn deinit(self: *ScrollViewport, _: Allocator) void {
        self.* = undefined;
    }
};

/// GUI->host: jump the session's viewport to a prompt by `delta` (negative =
/// toward older prompts). i64 on the wire for host-pointer-width independence.
pub const JumpToPrompt = struct {
    session_id: u64,
    delta: i64 = 0,

    pub fn encode(self: JumpToPrompt, alloc: Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(alloc);
        const w = buf.writer(alloc);
        try writeInt(w, u64, self.session_id);
        try writeInt(w, i64, self.delta);
        return buf.toOwnedSlice(alloc);
    }

    pub fn decode(_: Allocator, payload: []const u8) !JumpToPrompt {
        var fbs = std.io.fixedBufferStream(payload);
        const r = fbs.reader();
        return .{
            .session_id = try readInt(r, u64),
            .delta = try readInt(r, i64),
        };
    }

    pub fn deinit(self: *JumpToPrompt, _: Allocator) void {
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

// --- Slice 3b: host-side search frames ---

/// GUI->host: start/replace the search needle for a session. An empty `query`
/// is equivalent to ClearSearch (the host tears down its search and clears
/// highlights). `opts` is reserved for future search options (case sensitivity,
/// regex, etc.) and is currently always 0.
///
/// `query` is the LAST field so the trailing-field `readBytes` invariant
/// (see readBytes' doc) holds: a well-formed frame's query consumes ALL
/// remaining payload bytes.
pub const SetSearch = struct {
    session_id: u64,
    opts: u8 = 0,
    /// Owned by this struct (freed by deinit).
    query: []const u8 = &.{},

    pub fn encode(self: SetSearch, alloc: Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(alloc);
        const w = buf.writer(alloc);
        try writeInt(w, u64, self.session_id);
        try w.writeByte(self.opts);
        try writeBytes(w, self.query);
        return buf.toOwnedSlice(alloc);
    }

    pub fn decode(alloc: Allocator, payload: []const u8) !SetSearch {
        var fbs = std.io.fixedBufferStream(payload);
        const r = fbs.reader();
        const session_id = try readInt(r, u64);
        const opts = try r.readByte();
        const query = try readBytes(alloc, &fbs, r);
        return .{ .session_id = session_id, .opts = opts, .query = query };
    }

    pub fn deinit(self: *SetSearch, alloc: Allocator) void {
        alloc.free(self.query);
        self.* = undefined;
    }
};

/// GUI->host: move the search selection. `dir` is 0=next, 1=prev.
pub const SearchNav = struct {
    session_id: u64,
    dir: u8 = 0,

    pub fn encode(self: SearchNav, alloc: Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(alloc);
        const w = buf.writer(alloc);
        try writeInt(w, u64, self.session_id);
        try w.writeByte(self.dir);
        return buf.toOwnedSlice(alloc);
    }

    pub fn decode(_: Allocator, payload: []const u8) !SearchNav {
        var fbs = std.io.fixedBufferStream(payload);
        const r = fbs.reader();
        return .{
            .session_id = try readInt(r, u64),
            .dir = try r.readByte(),
        };
    }

    pub fn deinit(self: *SearchNav, _: Allocator) void {
        self.* = undefined;
    }
};

/// GUI->host: clear the active search for a session (tear down the host search
/// thread + drop highlights). Same shape as Detach/Close.
pub const ClearSearch = SessionIdFrame(.clear_search);

/// host->GUI: the total match count changed. `present`=0 means the count is
/// null (search cleared); `present`=1 means `total` is meaningful. Mirrors the
/// GUI's `?usize` search_total event.
pub const SearchTotal = struct {
    session_id: u64,
    present: u8 = 0,
    total: u64 = 0,

    pub fn encode(self: SearchTotal, alloc: Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(alloc);
        const w = buf.writer(alloc);
        try writeInt(w, u64, self.session_id);
        try w.writeByte(self.present);
        try writeInt(w, u64, self.total);
        return buf.toOwnedSlice(alloc);
    }

    pub fn decode(_: Allocator, payload: []const u8) !SearchTotal {
        var fbs = std.io.fixedBufferStream(payload);
        const r = fbs.reader();
        return .{
            .session_id = try readInt(r, u64),
            .present = try r.readByte(),
            .total = try readInt(r, u64),
        };
    }

    pub fn deinit(self: *SearchTotal, _: Allocator) void {
        self.* = undefined;
    }
};

/// host->GUI: the selected match index changed. `present`=0 means the selection
/// is null; `present`=1 means `idx` is meaningful. Mirrors the GUI's `?usize`
/// search_selected event.
pub const SearchSelected = struct {
    session_id: u64,
    present: u8 = 0,
    idx: u64 = 0,

    pub fn encode(self: SearchSelected, alloc: Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(alloc);
        const w = buf.writer(alloc);
        try writeInt(w, u64, self.session_id);
        try w.writeByte(self.present);
        try writeInt(w, u64, self.idx);
        return buf.toOwnedSlice(alloc);
    }

    pub fn decode(_: Allocator, payload: []const u8) !SearchSelected {
        var fbs = std.io.fixedBufferStream(payload);
        const r = fbs.reader();
        return .{
            .session_id = try readInt(r, u64),
            .present = try r.readByte(),
            .idx = try readInt(r, u64),
        };
    }

    pub fn deinit(self: *SearchSelected, _: Allocator) void {
        self.* = undefined;
    }
};

// --- Slice 3c: host-side OSC8 hover links ---

/// GUI->host: the current OSC8 hover state for a session. `viewport_x`/
/// `viewport_y` is the viewport cell under the mouse; `mods` is the
/// `inputpkg.Mods` byte representation (so the host can apply the same
/// ctrl/super gate the GUI uses under `.exec`); `present` is false when the
/// mouse has left the surface (or there is otherwise no hover), in which case
/// the host replies with an empty LinkFrame.
pub const Hover = struct {
    session_id: u64,
    viewport_x: u16 = 0,
    viewport_y: u16 = 0,
    /// `inputpkg.Mods.int()` (its u16 backing representation), shipped whole so
    /// the host can `@bitCast` it back to `Mods` and apply the same
    /// `ctrlOrSuper` gate the GUI uses under `.exec`. See Session.hoverLink.
    mods: u16 = 0,
    present: bool = false,

    pub fn encode(self: Hover, alloc: Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(alloc);
        const w = buf.writer(alloc);
        try writeInt(w, u64, self.session_id);
        try writeInt(w, u16, self.viewport_x);
        try writeInt(w, u16, self.viewport_y);
        try writeInt(w, u16, self.mods);
        try writeBool(w, self.present);
        return buf.toOwnedSlice(alloc);
    }

    pub fn decode(_: Allocator, payload: []const u8) !Hover {
        var fbs = std.io.fixedBufferStream(payload);
        const r = fbs.reader();
        return .{
            .session_id = try readInt(r, u64),
            .viewport_x = try readInt(r, u16),
            .viewport_y = try readInt(r, u16),
            .mods = try readInt(r, u16),
            .present = try readBool(r),
        };
    }

    pub fn deinit(self: *Hover, _: Allocator) void {
        self.* = undefined;
    }
};

/// host->GUI: the OSC8 link-cell coordinate set for the most recent Hover.
/// Empty `cells` means "no OSC8 link here" (the GUI clears its OSC8 link
/// overlay). Each cell is a (viewport x, viewport y) pair — the keys of the
/// host's `RenderState.CellSet` (`render.zig:948`).
pub const LinkFrame = struct {
    session_id: u64,
    /// Owned by this struct (freed by deinit). Decoded as a flat array of
    /// (x:u16, y:u16) pairs.
    cells: []const Cell = &.{},

    pub const Cell = struct { x: u16, y: u16 };

    pub fn encode(self: LinkFrame, alloc: Allocator) ![]u8 {
        // Bound the cell count BEFORE narrowing to u32 (mirrors writeBytes'
        // PCR-1 guard): a CellSet larger than u32 range would make the
        // @intCast illegal behavior. Each cell is 4 bytes, so the cap is in
        // cells, not bytes.
        if (self.cells.len > MAX_FRAME_LEN / 4) return error.FrameTooLarge;
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(alloc);
        const w = buf.writer(alloc);
        try writeInt(w, u64, self.session_id);
        try writeInt(w, u32, @intCast(self.cells.len));
        for (self.cells) |c| {
            try writeInt(w, u16, c.x);
            try writeInt(w, u16, c.y);
        }
        return buf.toOwnedSlice(alloc);
    }

    pub fn decode(alloc: Allocator, payload: []const u8) !LinkFrame {
        var fbs = std.io.fixedBufferStream(payload);
        const r = fbs.reader();
        const session_id = try readInt(r, u64);
        const count = try readInt(r, u32);
        // Bound the claimed count against the bytes actually remaining BEFORE
        // allocating (finding P6 / readBytes parallel): each cell is 4 bytes.
        const remaining = fbs.buffer.len - fbs.pos;
        if (@as(usize, count) * 4 > remaining) return error.InvalidFrame;
        const cells = try alloc.alloc(Cell, count);
        errdefer alloc.free(cells);
        for (cells) |*c| {
            c.x = try readInt(r, u16);
            c.y = try readInt(r, u16);
        }
        return .{ .session_id = session_id, .cells = cells };
    }

    pub fn deinit(self: *LinkFrame, alloc: Allocator) void {
        alloc.free(self.cells);
        self.* = undefined;
    }

    /// Convert the host's `RenderState.CellSet` (the linkCells result) into a
    /// freshly-allocated array of wire Cells. Caller owns the result. Used by
    /// the host to build a LinkFrame from `Session.hoverLink`'s CellSet.
    pub fn cellsFromSet(
        alloc: Allocator,
        set: *const terminalpkg.RenderState.CellSet,
    ) ![]Cell {
        // These are VIEWPORT coordinates from linkCells, so x < cols and
        // y < viewport rows — both far below maxInt(u16). `Coordinate.y` is
        // nonetheless a wider type (it can address history rows in other
        // contexts), so guard the narrowing rather than `@intCast` (which would
        // panic in safe builds) — defensively drop any coord that does not fit
        // a u16 wire field instead of trusting the invariant blindly.
        var out = try std.ArrayList(Cell).initCapacity(alloc, set.count());
        errdefer out.deinit(alloc);
        var it = set.iterator();
        while (it.next()) |entry| {
            const x = std.math.cast(u16, entry.key_ptr.x) orelse continue;
            const y = std.math.cast(u16, entry.key_ptr.y) orelse continue;
            out.appendAssumeCapacity(.{ .x = x, .y = y });
        }
        return out.toOwnedSlice(alloc);
    }
};

// --- Slice 6: the general SurfaceEvent channel ---

/// Write/read a `MessageData`-style byte slice payload (the WriteReq bytes of
/// `pwd_change` / `clipboard_write`). On the wire these are length-prefixed
/// bytes (`writeBytes`/`readBytes`), identical in shape to Input.bytes. The
/// `apprt.surface.Message.WriteReq` is reconstructed on the GUI side from the
/// decoded slice via `writeReqFromBytes` (a `.small` for <=255, else `.alloc`).
const WriteReq = apprt.surface.Message.WriteReq;

/// Reconstruct an `apprt.surface.Message.WriteReq` from a decoded byte slice.
/// `<=255` bytes -> a `.small` (copies into the inline buffer; no allocation,
/// no ownership transfer). Larger -> a `.alloc` duped from `alloc` (owned by the
/// reconstructed WriteReq; the caller's downstream surface drain frees it via
/// the message's own deinit, exactly as `.exec` does). Mirrors the host-side
/// shape of `pwd_change`/`clipboard_write` (a `WriteReq` whose `.slice()` is the
/// bytes regardless of small/stable/alloc variant).
fn writeReqFromBytes(alloc: Allocator, bytes: []const u8) !WriteReq {
    if (bytes.len <= WriteReq.Small.Max) {
        var buf: WriteReq.Small.Array = undefined;
        @memcpy(buf[0..bytes.len], bytes);
        return .{ .small = .{ .data = buf, .len = @intCast(bytes.len) } };
    }
    const dup = try alloc.dupe(u8, bytes);
    return .{ .alloc = .{ .alloc = alloc, .data = dup } };
}

/// host->GUI: a forwarded `apprt.surface.Message`. Carries the session id, a
/// variant tag, and the per-variant payload. Built host-side from a drained
/// surface message via `fromMessage`; reconstructed GUI-side into an
/// `apprt.surface.Message` via `toMessage` for re-injection into the surface
/// mailbox.
///
/// OWNERSHIP: decode() may allocate owned bytes for the `pwd_change` /
/// `clipboard_write` variants (the WriteReq payload); `deinit` frees them.
/// `toMessage` MOVES those bytes into the reconstructed WriteReq (which the
/// downstream surface drain then owns), so a decoded SurfaceEvent that has been
/// converted via `toMessage` must NOT also be `deinit`'d for those bytes — see
/// `toMessage`'s doc. encode() borrows the source message (does not free it).
///
/// The serialized variant set MIRRORS the host StreamHandler's forwarded subset
/// (plan §4.5). EXCLUDED (never forwarded; see Session's drain): change_config,
/// close, child_exited (dedicated ChildExited frame), renderer_health,
/// present_surface, selection_scroll_tick, scrollbar, search_total,
/// search_selected.
pub const SurfaceEvent = struct {
    session_id: u64,
    payload: Payload,

    /// One-byte wire tag selecting the payload variant. Stable on the wire;
    /// append new variants at the END.
    pub const Tag = enum(u8) {
        ring_bell,
        start_command,
        password_input,
        stop_command,
        set_title,
        report_title,
        set_mouse_shape,
        desktop_notification,
        color_change,
        progress_report,
        pwd_change,
        clipboard_write,
        clipboard_read,
    };

    /// The decoded payload. Mirrors the forwarded `apprt.surface.Message`
    /// variants. Byte-slice-bearing variants (`pwd_change`/`clipboard_write`)
    /// own their bytes after decode (freed by `deinit` unless moved by
    /// `toMessage`).
    pub const Payload = union(Tag) {
        ring_bell: void,
        start_command: void,
        password_input: bool,
        stop_command: ?u8,
        set_title: [256]u8,
        report_title: apprt.surface.Message.ReportTitleStyle,
        set_mouse_shape: terminalpkg.MouseShape,
        desktop_notification: struct {
            title: [63:0]u8,
            body: [255:0]u8,
        },
        color_change: osccolor.ColoredTarget,
        progress_report: terminalpkg.osc.Command.ProgressReport,
        /// Owned bytes after decode (the WriteReq slice).
        pwd_change: []const u8,
        clipboard_write: struct {
            clipboard_type: apprt.Clipboard,
            /// Owned bytes after decode (the WriteReq slice).
            bytes: []const u8,
        },
        clipboard_read: apprt.Clipboard,
    };

    /// Build a SurfaceEvent (borrowing the message) from a drained
    /// `apprt.surface.Message`. Returns `error.NotForwarded` for any EXCLUDED
    /// variant so the host drain can keep ignoring those (it never forwards
    /// them). The byte-slice variants copy the WriteReq's `.slice()` (valid only
    /// while the source message is alive — the host serializes synchronously in
    /// the drain), so the returned SurfaceEvent's slices ALIAS the source
    /// message; `encode` reads them immediately and the result is not retained.
    pub fn fromMessage(session_id: u64, msg: *const apprt.surface.Message) error{NotForwarded}!SurfaceEvent {
        const payload: Payload = switch (msg.*) {
            .ring_bell => .{ .ring_bell = {} },
            .start_command => .{ .start_command = {} },
            .password_input => |v| .{ .password_input = v },
            .stop_command => |v| .{ .stop_command = v },
            .set_title => |v| .{ .set_title = v },
            .report_title => |v| .{ .report_title = v },
            .set_mouse_shape => |v| .{ .set_mouse_shape = v },
            .desktop_notification => |v| .{ .desktop_notification = .{
                .title = v.title,
                .body = v.body,
            } },
            .color_change => |v| .{ .color_change = v },
            .progress_report => |v| .{ .progress_report = v },
            // Capture the WriteReq variants BY POINTER (`|*v|`): `WriteReq.slice()`
            // for the `.small` variant returns a slice into the WriteReq's INLINE
            // buffer, so a by-value capture would alias the switch's stack-local
            // COPY (dangling once the switch expression ends). By pointer, the
            // slice aliases the ORIGINAL message storage, which stays alive for
            // the synchronous fromMessage->encode in the drain (per this fn's doc).
            .pwd_change => |*v| .{ .pwd_change = v.slice() },
            .clipboard_write => |*v| .{ .clipboard_write = .{
                .clipboard_type = v.clipboard_type,
                .bytes = v.req.slice(),
            } },
            .clipboard_read => |v| .{ .clipboard_read = v },

            // EXCLUDED — never forwarded over the SurfaceEvent channel. Each has
            // its own handling (see Session's drain doc): child_exited rides a
            // dedicated ChildExited frame + render-stop; search_total/selected
            // ride dedicated frames; change_config (config flows separately),
            // close (surface-internal), renderer_health (no host GPU),
            // present_surface / selection_scroll_tick / scrollbar (GUI-side).
            .change_config,
            .close,
            .child_exited,
            .renderer_health,
            .present_surface,
            .selection_scroll_tick,
            .scrollbar,
            .search_total,
            .search_selected,
            => return error.NotForwarded,
        };
        return .{ .session_id = session_id, .payload = payload };
    }

    /// Reconstruct an `apprt.surface.Message` for re-injection into the GUI's
    /// surface mailbox. For the byte-slice variants this MOVES the decoded owned
    /// bytes into a reconstructed WriteReq (via `writeReqFromBytes`): a `.small`
    /// copies them (the SurfaceEvent still owns the originals, freed by
    /// `deinit`), while `.alloc` would re-dupe. To keep ownership simple and
    /// match the `.exec` mailbox contract (the surface drain owns + frees the
    /// WriteReq), `writeReqFromBytes` always COPIES (small) or DUPES (alloc), so
    /// the decoded SurfaceEvent's own bytes are still freed by `deinit` and the
    /// reconstructed message independently owns its copy. `alloc` is used for the
    /// `.alloc` WriteReq dupe.
    pub fn toMessage(self: *const SurfaceEvent, alloc: Allocator) !apprt.surface.Message {
        return switch (self.payload) {
            .ring_bell => .{ .ring_bell = {} },
            .start_command => .{ .start_command = {} },
            .password_input => |v| .{ .password_input = v },
            .stop_command => |v| .{ .stop_command = v },
            .set_title => |v| .{ .set_title = v },
            .report_title => |v| .{ .report_title = v },
            .set_mouse_shape => |v| .{ .set_mouse_shape = v },
            .desktop_notification => |v| .{ .desktop_notification = .{
                .title = v.title,
                .body = v.body,
            } },
            .color_change => |v| .{ .color_change = v },
            .progress_report => |v| .{ .progress_report = v },
            .pwd_change => |bytes| .{ .pwd_change = try writeReqFromBytes(alloc, bytes) },
            .clipboard_write => |v| .{ .clipboard_write = .{
                .clipboard_type = v.clipboard_type,
                .req = try writeReqFromBytes(alloc, v.bytes),
            } },
            .clipboard_read => |v| .{ .clipboard_read = v },
        };
    }

    pub fn encode(self: SurfaceEvent, alloc: Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(alloc);
        const w = buf.writer(alloc);
        try writeInt(w, u64, self.session_id);
        try w.writeByte(@intFromEnum(@as(Tag, self.payload)));
        switch (self.payload) {
            .ring_bell, .start_command => {},
            .password_input => |v| try writeBool(w, v),
            .stop_command => |v| {
                try writeBool(w, v != null);
                try w.writeByte(if (v) |b| b else 0);
            },
            .set_title => |v| {
                // Zero the tail past the NUL terminator before sending so we
                // never serialize UNINITIALIZED buffer bytes over the wire
                // (the title is the NUL-terminated prefix; the tail is don't-
                // care to the GUI but would otherwise leak nondeterministic
                // process memory). Wire size + decode are unchanged (256 bytes).
                var t = v;
                const n = std.mem.indexOfScalar(u8, &t, 0) orelse t.len;
                @memset(t[n..], 0);
                try w.writeAll(&t);
            },
            .report_title => |v| try writeEnum(w, v),
            .set_mouse_shape => |v| try writeEnum(w, v),
            .desktop_notification => |v| {
                // Serialize the full fixed buffers incl. the sentinel slot
                // (64 + 256 bytes); decode reads them back verbatim. Zero each
                // buffer's tail past its NUL first (same rationale as set_title:
                // no uninitialized bytes on the wire).
                var title = v.title;
                var body = v.body;
                const tn = std.mem.indexOfScalar(u8, title[0..], 0) orelse title.len;
                const bn = std.mem.indexOfScalar(u8, body[0..], 0) orelse body.len;
                @memset(title[tn..title.len], 0);
                @memset(body[bn..body.len], 0);
                try w.writeAll(title[0 .. title.len + 1]);
                try w.writeAll(body[0 .. body.len + 1]);
            },
            .color_change => |v| {
                try writeTarget(w, v.target);
                try writeRGB(w, v.color);
            },
            .progress_report => |v| {
                try writeEnum(w, v.state);
                try writeBool(w, v.progress != null);
                try w.writeByte(if (v.progress) |p| p else 0);
            },
            .pwd_change => |bytes| try writeBytes(w, bytes),
            .clipboard_write => |v| {
                try writeEnum(w, v.clipboard_type);
                try writeBytes(w, v.bytes);
            },
            .clipboard_read => |v| try writeEnum(w, v),
        }
        return buf.toOwnedSlice(alloc);
    }

    pub fn decode(alloc: Allocator, payload: []const u8) !SurfaceEvent {
        var fbs = std.io.fixedBufferStream(payload);
        const r = fbs.reader();
        const session_id = try readInt(r, u64);
        const tag = std.meta.intToEnum(Tag, try r.readByte()) catch
            return error.InvalidFrame;
        const p: Payload = switch (tag) {
            .ring_bell => .{ .ring_bell = {} },
            .start_command => .{ .start_command = {} },
            .password_input => .{ .password_input = try readBool(r) },
            .stop_command => blk: {
                const present = try readBool(r);
                const b = try r.readByte();
                break :blk .{ .stop_command = if (present) b else null };
            },
            .set_title => blk: {
                var v: [256]u8 = undefined;
                try r.readNoEof(&v);
                break :blk .{ .set_title = v };
            },
            .report_title => .{ .report_title = try readEnum(r, apprt.surface.Message.ReportTitleStyle) },
            .set_mouse_shape => .{ .set_mouse_shape = try readEnum(r, terminalpkg.MouseShape) },
            .desktop_notification => blk: {
                var title: [63:0]u8 = undefined;
                try r.readNoEof(title[0 .. title.len + 1]);
                var body: [255:0]u8 = undefined;
                try r.readNoEof(body[0 .. body.len + 1]);
                break :blk .{ .desktop_notification = .{ .title = title, .body = body } };
            },
            .color_change => blk: {
                const target = try readTarget(r);
                const rgb = try readRGB(r);
                break :blk .{ .color_change = .{ .target = target, .color = rgb } };
            },
            .progress_report => blk: {
                const state = try readEnum(r, terminalpkg.osc.Command.ProgressReport.State);
                const present = try readBool(r);
                const b = try r.readByte();
                break :blk .{ .progress_report = .{
                    .state = state,
                    .progress = if (present) b else null,
                } };
            },
            .pwd_change => .{ .pwd_change = try readBytes(alloc, &fbs, r) },
            .clipboard_write => blk: {
                const ct = try readEnum(r, apprt.Clipboard);
                const bytes = try readBytes(alloc, &fbs, r);
                break :blk .{ .clipboard_write = .{ .clipboard_type = ct, .bytes = bytes } };
            },
            .clipboard_read => .{ .clipboard_read = try readEnum(r, apprt.Clipboard) },
        };
        return .{ .session_id = session_id, .payload = p };
    }

    pub fn deinit(self: *SurfaceEvent, alloc: Allocator) void {
        switch (self.payload) {
            .pwd_change => |bytes| alloc.free(bytes),
            .clipboard_write => |v| alloc.free(v.bytes),
            else => {},
        }
        self.* = undefined;
    }
};

// --- SurfaceEvent serialization helpers ---

/// Serialize any enum as its integer value in a fixed i64 wire field. Covers
/// `enum(c_int)` (MouseShape / ProgressReport.State), small unsized enums
/// (ReportTitleStyle), and `apprt.Clipboard` (whose backing is u2 in the
/// headless `.none` runtime and c_int under GTK) uniformly. decode validates
/// the value against the enum via `std.meta.intToEnum`.
fn writeEnum(w: anytype, v: anytype) !void {
    try writeInt(w, i64, @intFromEnum(v));
}

fn readEnum(r: anytype, comptime E: type) !E {
    const raw = try readInt(r, i64);
    const Int = @typeInfo(E).@"enum".tag_type;
    const narrowed = std.math.cast(Int, raw) orelse return error.InvalidFrame;
    return std.meta.intToEnum(E, narrowed) catch return error.InvalidFrame;
}

/// Serialize `terminal.color.RGB` (a packed struct(u24) of r,g,b u8) as three
/// raw bytes. protocol.zig has no RGB helper of its own (the RenderState ones
/// are file-private there), so define a local pair matching that 3-byte shape.
fn writeRGB(w: anytype, rgb: color.RGB) !void {
    try w.writeByte(rgb.r);
    try w.writeByte(rgb.g);
    try w.writeByte(rgb.b);
}

fn readRGB(r: anytype) !color.RGB {
    return .{ .r = try r.readByte(), .g = try r.readByte(), .b = try r.readByte() };
}

/// Serialize a `terminal.osc.color.Target` union (palette: u8 / special:
/// enum(u3) / dynamic: enum(u5)). One tag byte + one value byte.
fn writeTarget(w: anytype, t: osccolor.Target) !void {
    switch (t) {
        .palette => |idx| {
            try w.writeByte(0);
            try w.writeByte(idx);
        },
        .special => |s| {
            try w.writeByte(1);
            try w.writeByte(@intFromEnum(s));
        },
        .dynamic => |d| {
            try w.writeByte(2);
            try w.writeByte(@intFromEnum(d));
        },
    }
}

fn readTarget(r: anytype) !osccolor.Target {
    const kind = try r.readByte();
    const v = try r.readByte();
    return switch (kind) {
        0 => .{ .palette = v },
        1 => .{ .special = std.meta.intToEnum(color.Special, v) catch return error.InvalidFrame },
        2 => .{ .dynamic = std.meta.intToEnum(color.Dynamic, v) catch return error.InvalidFrame },
        else => error.InvalidFrame,
    };
}
