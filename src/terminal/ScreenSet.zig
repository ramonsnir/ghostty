/// A ScreenSet holds multiple terminal screens. This is initially created
/// to handle simple primary vs alternate screens, but could be extended
/// in the future to handle N screens.
///
/// One of the goals of this is to allow lazy initialization of screens
/// as needed. The primary screen is always initialized, but the alternate
/// screen may not be until first used.
const ScreenSet = @This();

const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const lib = @import("lib.zig");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Screen = @import("Screen.zig");
// FORK(host-handoff): shared (de)serialization helpers.
const serial = @import("serial.zig");

/// The possible keys for screens in the screen set.
pub const Key = lib.Enum(lib.target, &.{
    "primary",
    "alternate",
});

/// The key value of the currently active screen. Useful for simple
/// comparisons, e.g. "is this screen the primary screen".
active_key: Key,

/// The active screen pointer.
active: *Screen,

/// All screens that are initialized.
all: std.EnumMap(Key, *Screen),

/// Monotonic generation counter for each screen key. This changes whenever a
/// screen is removed so external handles can distinguish a newly initialized
/// screen from stale references into destroyed screen storage.
generations: std.EnumMap(Key, usize),

pub fn init(
    alloc: Allocator,
    opts: Screen.Options,
) Allocator.Error!ScreenSet {
    // We need to initialize our initial primary screen
    const screen = try alloc.create(Screen);
    errdefer alloc.destroy(screen);
    screen.* = try .init(alloc, opts);
    return .{
        .active_key = .primary,
        .active = screen,
        .all = .init(.{ .primary = screen }),
        .generations = .initFull(0),
    };
}

pub fn deinit(self: *ScreenSet, alloc: Allocator) void {
    // Destroy all initialized screens
    var it = self.all.iterator();
    while (it.next()) |entry| {
        entry.value.*.deinit();
        alloc.destroy(entry.value.*);
    }
}

/// Get the screen for the given key, if it is initialized.
pub fn get(self: *const ScreenSet, key: Key) ?*Screen {
    return self.all.get(key);
}

/// Get the current generation for the given screen key.
pub fn generation(self: *const ScreenSet, key: Key) usize {
    return self.generations.get(key).?;
}

/// Get the screen for the given key, initializing it if necessary.
pub fn getInit(
    self: *ScreenSet,
    alloc: Allocator,
    key: Key,
    opts: Screen.Options,
) Allocator.Error!*Screen {
    if (self.get(key)) |screen| return screen;
    const screen = try alloc.create(Screen);
    errdefer alloc.destroy(screen);
    screen.* = try .init(alloc, opts);
    self.all.put(key, screen);
    return screen;
}

/// Remove a key from the set. The primary screen cannot be removed (asserted).
pub fn remove(
    self: *ScreenSet,
    alloc: Allocator,
    key: Key,
) void {
    assert(key != .primary);
    if (self.all.fetchRemove(key)) |screen| {
        self.generations.put(key, self.generation(key) +% 1);
        screen.deinit();
        alloc.destroy(screen);
    }
}

/// Switch the active screen to the given key. Requires that the
/// screen is initialized.
pub fn switchTo(self: *ScreenSet, key: Key) void {
    self.active_key = key;
    self.active = self.all.get(key).?;
}

/// FORK(host-handoff): serialize the screen set (active key, per-key
/// generations, the always-present primary screen, and the optional alternate
/// screen) for a same-build session handoff.
pub fn serialize(self: *const ScreenSet, writer: anytype) !void {
    try serial.writePod(writer, self.active_key);
    try writer.writeInt(u64, self.generation(.primary), .little);
    try writer.writeInt(u64, self.generation(.alternate), .little);

    // Primary is always initialized.
    try self.get(.primary).?.serialize(writer);

    // Alternate is lazily initialized.
    if (self.get(.alternate)) |alt| {
        try writer.writeByte(1);
        try alt.serialize(writer);
    } else {
        try writer.writeByte(0);
    }
}

/// FORK(host-handoff): rebuild a screen set written by `serialize`. The returned
/// set owns its screens and must be `deinit`ed.
pub fn deserialize(alloc: Allocator, reader: anytype) !ScreenSet {
    const active_key = try serial.readPod(Key, reader);
    const gen_primary: usize = @intCast(try reader.readInt(u64, .little));
    const gen_alternate: usize = @intCast(try reader.readInt(u64, .little));

    const primary = try alloc.create(Screen);
    errdefer alloc.destroy(primary);
    primary.* = try Screen.deserialize(alloc, reader);
    errdefer primary.deinit();

    var all: std.EnumMap(Key, *Screen) = .init(.{ .primary = primary });

    if ((try reader.readByte()) != 0) {
        const alt = try alloc.create(Screen);
        errdefer alloc.destroy(alt);
        alt.* = try Screen.deserialize(alloc, reader);
        errdefer alt.deinit();
        all.put(.alternate, alt);
    }

    var generations: std.EnumMap(Key, usize) = .initFull(0);
    generations.put(.primary, gen_primary);
    generations.put(.alternate, gen_alternate);

    return .{
        .active_key = active_key,
        .active = all.get(active_key).?,
        .all = all,
        .generations = generations,
    };
}

test ScreenSet {
    const alloc = testing.allocator;
    var set: ScreenSet = try .init(alloc, .default);
    defer set.deinit(alloc);
    try testing.expectEqual(.primary, set.active_key);
    try testing.expectEqual(@as(usize, 0), set.generation(.primary));
    try testing.expectEqual(@as(usize, 0), set.generation(.alternate));

    // Initialize a secondary screen
    _ = try set.getInit(alloc, .alternate, .default);
    try testing.expectEqual(@as(usize, 0), set.generation(.alternate));

    set.switchTo(.alternate);
    try testing.expectEqual(.alternate, set.active_key);
}

test "ScreenSet generations" {
    const alloc = testing.allocator;
    var set: ScreenSet = try .init(alloc, .default);
    defer set.deinit(alloc);

    try testing.expectEqual(@as(usize, 0), set.generation(.primary));
    try testing.expectEqual(@as(usize, 0), set.generation(.alternate));

    // A no-op removal doesn't change the generation.
    set.remove(alloc, .alternate);
    try testing.expectEqual(@as(usize, 0), set.generation(.alternate));

    // Initializing a screen doesn't change the generation.
    _ = try set.getInit(alloc, .alternate, .default);
    try testing.expectEqual(@as(usize, 0), set.generation(.alternate));

    const alternate_generation = set.generation(.alternate);
    set.remove(alloc, .alternate);
    try testing.expectEqual(alternate_generation +% 1, set.generation(.alternate));

    // Reinitializing keeps the generation from the last removal, so stale
    // handles can distinguish the new screen from the destroyed screen.
    _ = try set.getInit(alloc, .alternate, .default);
    try testing.expectEqual(alternate_generation +% 1, set.generation(.alternate));
    try testing.expectEqual(@as(usize, 0), set.generation(.primary));
}
