//! FORK(host-handoff): small generic (de)serialization helpers shared by the
//! terminal `serialize`/`deserialize` methods used for host process handoff.
//!
//! These are deliberately minimal and same-build only: POD values are written
//! as their raw in-memory bytes (`asBytes`), which is exactly what makes the
//! handoff a "same version" contract. A magic + layout fingerprint guard is
//! written up front by `host/session_transfer.zig` and asserted on read so a
//! mismatched build fails loudly instead of corrupting state.
//!
//! The `writer`/`reader` are generic (`anytype`) to match the idiom already
//! used by `src/host/protocol.zig`: a writer with `writeInt`/`writeByte`/
//! `writeAll` (e.g. `std.ArrayList(u8).writer(alloc)`) and a reader with
//! `readInt`/`readByte`/`readNoEof` (e.g. `std.io.fixedBufferStream(...).reader()`).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Error returned when a length-prefixed blob claims more bytes than the
/// caller-supplied sanity bound allows. Same-build handoff is trusted, but we
/// still bound speculative allocations so a truncated/garbled stream fails
/// cleanly rather than attempting a huge allocation.
pub const Error = error{
    SerialBlobTooLarge,
};

/// Write a pointer-free POD value as its raw little-endian-host bytes.
///
/// SAME-BUILD CONTRACT: this is only valid because both ends are the identical
/// binary, so struct layout, enum tags, and endianness match exactly. Never use
/// this for a type containing a pointer/slice (the pointer would be meaningless
/// on the other side) — those get explicit field-wise handling.
pub inline fn writePod(writer: anytype, value: anytype) !void {
    const T = @TypeOf(value);
    comptime assertPointerFree(T);
    var v = value;
    try writer.writeAll(std.mem.asBytes(&v));
}

/// Read a pointer-free POD value written by `writePod`.
pub inline fn readPod(comptime T: type, reader: anytype) !T {
    comptime assertPointerFree(T);
    var v: T = undefined;
    try reader.readNoEof(std.mem.asBytes(&v));
    return v;
}

/// Write an optional POD value: a presence byte followed by the payload when
/// present.
pub inline fn writeOptPod(writer: anytype, value: anytype) !void {
    if (value) |v| {
        try writer.writeByte(1);
        try writePod(writer, v);
    } else {
        try writer.writeByte(0);
    }
}

/// Read an optional POD value written by `writeOptPod`.
pub inline fn readOptPod(comptime T: type, reader: anytype) !?T {
    const present = (try reader.readByte()) != 0;
    if (!present) return null;
    return try readPod(T, reader);
}

/// Write a length-prefixed byte slice (u64 LE length + raw bytes).
pub fn writeBytes(writer: anytype, bytes: []const u8) !void {
    try writer.writeInt(u64, @intCast(bytes.len), .little);
    try writer.writeAll(bytes);
}

/// Read a length-prefixed byte slice written by `writeBytes`. The caller owns
/// the returned slice. `max` bounds the claimed length to avoid an unbounded
/// speculative allocation on a corrupt stream.
pub fn readBytes(alloc: Allocator, reader: anytype, max: usize) ![]u8 {
    const len = try reader.readInt(u64, .little);
    if (len > max) return Error.SerialBlobTooLarge;
    const out = try alloc.alloc(u8, @intCast(len));
    errdefer alloc.free(out);
    try reader.readNoEof(out);
    return out;
}

/// Write a length-prefixed array of pointer-free POD elements as raw bytes.
pub fn writePodSlice(writer: anytype, comptime T: type, items: []const T) !void {
    comptime assertPointerFree(T);
    try writer.writeInt(u64, @intCast(items.len), .little);
    if (items.len > 0) try writer.writeAll(std.mem.sliceAsBytes(items));
}

/// Read a length-prefixed array of pointer-free POD elements written by
/// `writePodSlice`. The caller owns the returned slice.
pub fn readPodSlice(
    alloc: Allocator,
    reader: anytype,
    comptime T: type,
    max: usize,
) ![]T {
    comptime assertPointerFree(T);
    const len = try reader.readInt(u64, .little);
    if (len > max) return Error.SerialBlobTooLarge;
    const out = try alloc.alloc(T, @intCast(len));
    errdefer alloc.free(out);
    if (len > 0) try reader.readNoEof(std.mem.sliceAsBytes(out));
    return out;
}

/// Compile-time guard: reject any type that (recursively) contains a pointer,
/// so `writePod` can never silently serialize a meaningless address. This is
/// the safety net behind the same-build raw-bytes strategy.
fn assertPointerFree(comptime T: type) void {
    switch (@typeInfo(T)) {
        .pointer => @compileError("serial.writePod: type '" ++ @typeName(T) ++ "' contains a pointer; handle it explicitly"),
        .optional => |o| assertPointerFree(o.child),
        .array => |a| assertPointerFree(a.child),
        .vector => |v| assertPointerFree(v.child),
        .@"struct" => |s| for (s.fields) |f| assertPointerFree(f.type),
        .@"union" => |u| for (u.fields) |f| assertPointerFree(f.type),
        else => {},
    }
}
