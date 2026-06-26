const builtin = @import("builtin");
const std = @import("std");
const inputpkg = @import("../input.zig");
const state = &@import("../global.zig").state;
const String = @import("../main_c.zig").String;
const help_strings = @import("help_strings");

const Config = @import("Config.zig");
const c_get = @import("c_get.zig");
const edit = @import("edit.zig");
const Key = @import("key.zig").Key;

const log = std.log.scoped(.config);

/// Create a new configuration filled with the initial default values.
export fn ghostty_config_new() ?*Config {
    const result = state.alloc.create(Config) catch |err| {
        log.err("error allocating config err={}", .{err});
        return null;
    };

    result.* = Config.default(state.alloc) catch |err| {
        log.err("error creating config err={}", .{err});
        state.alloc.destroy(result);
        return null;
    };

    return result;
}

export fn ghostty_config_free(ptr: ?*Config) void {
    if (ptr) |v| {
        v.deinit();
        state.alloc.destroy(v);
    }
}

/// Deep clone the configuration.
export fn ghostty_config_clone(self: *Config) ?*Config {
    const result = state.alloc.create(Config) catch |err| {
        log.err("error allocating config err={}", .{err});
        return null;
    };

    result.* = self.clone(state.alloc) catch |err| {
        log.err("error cloning config err={}", .{err});
        state.alloc.destroy(result);
        return null;
    };

    return result;
}

/// Load the configuration from the CLI args.
export fn ghostty_config_load_cli_args(self: *Config) void {
    self.loadCliArgs(state.alloc) catch |err| {
        log.err("error loading config err={}", .{err});
    };
}

/// Load the configuration from the default file locations. This
/// is usually done first. The default file locations are locations
/// such as the home directory.
export fn ghostty_config_load_default_files(self: *Config) void {
    self.loadDefaultFiles(state.alloc) catch |err| {
        log.err("error loading config err={}", .{err});
    };
}

/// Load the configuration from a specific file path.
/// The path must be null-terminated.
export fn ghostty_config_load_file(self: *Config, path: [*:0]const u8) void {
    const path_slice = std.mem.span(path);
    self.loadFile(state.alloc, path_slice) catch |err| {
        log.err("error loading config from file path={s} err={}", .{ path_slice, err });
    };
}

/// Load the configuration from the user-specified configuration
/// file locations in the previously loaded configuration. This will
/// recursively continue to load up to a built-in limit.
export fn ghostty_config_load_recursive_files(self: *Config) void {
    self.loadRecursiveFiles(state.alloc) catch |err| {
        log.err("error loading config err={}", .{err});
    };
}

export fn ghostty_config_finalize(self: *Config) void {
    self.finalize() catch |err| {
        log.err("error finalizing config err={}", .{err});
    };
}

export fn ghostty_config_get(
    self: *Config,
    ptr: *anyopaque,
    key_str: [*]const u8,
    len: usize,
) bool {
    @setEvalBranchQuota(10_000);
    const key = std.meta.stringToEnum(Key, key_str[0..len]) orelse return false;
    return c_get.get(self, key, ptr);
}

export fn ghostty_config_trigger(
    self: *Config,
    str: [*]const u8,
    len: usize,
) inputpkg.Binding.Trigger.C {
    return config_trigger_(self, str[0..len]) catch |err| err: {
        log.err("error finding trigger err={}", .{err});
        break :err .{};
    };
}

fn config_trigger_(
    self: *Config,
    str: []const u8,
) !inputpkg.Binding.Trigger.C {
    const action = try inputpkg.Binding.Action.parse(str);
    const trigger: inputpkg.Binding.Trigger = self.keybind.set.getTrigger(action) orelse .{};
    return trigger.cval();
}

export fn ghostty_config_diagnostics_count(self: *Config) u32 {
    return @intCast(self._diagnostics.items().len);
}

export fn ghostty_config_get_diagnostic(self: *Config, idx: u32) Diagnostic {
    const items = self._diagnostics.items();
    if (idx >= items.len) return .{};
    const message = self._diagnostics.precompute.messages.items[idx];
    return .{ .message = message.ptr };
}

export fn ghostty_config_open_path() String {
    const path = edit.openPath(state.alloc) catch |err| {
        log.err("error opening config in editor err={}", .{err});
        return .empty;
    };

    return .fromSlice(path);
}

/// Sync with ghostty_diagnostic_s
const Diagnostic = extern struct {
    message: [*:0]const u8 = "",
};

// (ramon fork) Config-knowledge introspection — read-only docs/discovery for the
// MCP "knowledge" tools. These do NOT need a *Config; they read the generated
// `help_strings` (the same doc text `+explain-config` uses) plus the static Key
// enum. The fork marker that identifies a fork-only key is the leading
// "(ramon fork)" on its doc comment (see src/config/Config.zig). All returned
// `[*:0]const u8` pointers are STATIC (help_strings literals / @tagName), so the
// caller must NOT free them.

/// The fork marker prefix on a fork-only config key's doc comment.
const fork_marker = "(ramon fork)";

/// Sync with ghostty_config_key_doc_s.
const KeyDoc = extern struct {
    /// The static doc text for the key (help_strings), "" if the key is unknown
    /// or has no doc. NUL-terminated, STATIC — do not free.
    doc: [*:0]const u8 = "",
    /// True if the key exists in the Key enum.
    known: bool = false,
    /// True if the doc begins with the fork marker ("(ramon fork)").
    fork_only: bool = false,
};

/// Sync with ghostty_config_key_info_s.
const KeyInfo = extern struct {
    /// The key name (e.g. "font-size"). NUL-terminated, STATIC — do not free.
    /// "" when the index is out of range.
    name: [*:0]const u8 = "",
    /// The key's doc text (help_strings), "" if none. NUL-terminated, STATIC.
    doc: [*:0]const u8 = "",
    /// True if the doc begins with the fork marker ("(ramon fork)").
    fork_only: bool = false,
};

/// Look up the doc text for a single config key by name. Returns `known=false`
/// (with doc="") for an unknown key. The doc is the SAME text `+explain-config`
/// prints. PURE (no *Config needed).
export fn ghostty_config_describe_key(
    key_str: [*]const u8,
    len: usize,
) KeyDoc {
    @setEvalBranchQuota(10_000);
    const name = key_str[0..len];
    const key = std.meta.stringToEnum(Key, name) orelse return .{};
    const doc = keyDoc(key);
    return .{
        .doc = doc,
        .known = true,
        .fork_only = std.mem.startsWith(u8, std.mem.span(doc), fork_marker),
    };
}

/// The number of config keys (the Key enum's field count). Pair with
/// `ghostty_config_key_at` to enumerate every key (count/index pattern, like
/// the diagnostics API).
export fn ghostty_config_key_count() u32 {
    return @intCast(std.meta.fields(Key).len);
}

/// Return the name + doc + fork-only flag for the key at `idx` (0-based, in Key
/// enum order). Out-of-range ⇒ an empty record (name=""). PURE.
export fn ghostty_config_key_at(idx: u32) KeyInfo {
    const fields = std.meta.fields(Key);
    if (idx >= fields.len) return .{};
    // Map the runtime index onto the enum tag at comptime so we can fetch the
    // static @tagName + help_strings doc for it.
    inline for (fields, 0..) |field, i| {
        if (i == idx) {
            const key = @field(Key, field.name);
            const doc = keyDoc(key);
            return .{
                .name = field.name,
                .doc = doc,
                .fork_only = std.mem.startsWith(u8, std.mem.span(doc), fork_marker),
            };
        }
    }
    unreachable;
}

/// Resolve a Key's help_strings doc text. "" if the key has no doc decl. The
/// returned slice is a static [:0]const u8 literal. Mirrors
/// `explain_config.zig`'s explainOption switch.
fn keyDoc(key: Key) [*:0]const u8 {
    switch (key) {
        inline else => |tag| {
            const field_name = @tagName(tag);
            return if (@hasDecl(help_strings.Config, field_name))
                @field(help_strings.Config, field_name)
            else
                "";
        },
    }
}

test "ghostty_config_get: bool" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.maximize = true;

    var out = false;
    const key = "maximize";
    try testing.expect(ghostty_config_get(&cfg, &out, key, key.len));
    try testing.expect(out);
}

test "ghostty_config_get: enum" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.@"window-theme" = .dark;

    var out: [*:0]const u8 = undefined;
    const key = "window-theme";
    try testing.expect(ghostty_config_get(&cfg, @ptrCast(&out), key, key.len));
    const str = std.mem.sliceTo(out, 0);
    try testing.expectEqualStrings("dark", str);
}

test "ghostty_config_get: optional null returns false" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.@"unfocused-split-fill" = null;

    var out: Config.Color.C = undefined;
    const key = "unfocused-split-fill";
    try testing.expect(!ghostty_config_get(&cfg, @ptrCast(&out), key, key.len));
}

test "ghostty_config_get: unknown key returns false" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();

    var out = false;
    const key = "not-a-real-key";
    try testing.expect(!ghostty_config_get(&cfg, &out, key, key.len));
}

test "ghostty_config_get: optional string null returns true" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.title = null;

    var out: ?[*:0]const u8 = undefined;
    const key = "title";
    try testing.expect(ghostty_config_get(&cfg, @ptrCast(&out), key, key.len));
    try testing.expect(out == null);
}

test "ghostty_config_get: float" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.@"background-opacity" = 0.42;

    var out: f64 = 0;
    const key = "background-opacity";
    try testing.expect(ghostty_config_get(&cfg, &out, key, key.len));
    try testing.expectApproxEqAbs(@as(f64, 0.42), out, 0.000001);
}

test "ghostty_config_get: struct cval conversion" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.background = .{ .r = 12, .g = 34, .b = 56 };

    var out: Config.Color.C = undefined;
    const key = "background";
    try testing.expect(ghostty_config_get(&cfg, @ptrCast(&out), key, key.len));
    try testing.expectEqual(@as(u8, 12), out.r);
    try testing.expectEqual(@as(u8, 34), out.g);
    try testing.expectEqual(@as(u8, 56), out.b);
}

test "ghostty_config_trigger: default keybind" {
    const testing = std.testing;

    var cfg = try Config.default(testing.allocator);
    defer cfg.deinit();

    // Default commands should be fetchable through config_trigger_
    {
        const trigger = try config_trigger_(&cfg, "open_config");
        try testing.expectEqual(.unicode, trigger.tag);
        try testing.expectEqual(@as(u32, ','), trigger.key.unicode);
    }
    {
        const trigger = try config_trigger_(&cfg, "reload_config");
        try testing.expectEqual(.unicode, trigger.tag);
        try testing.expectEqual(@as(u32, ','), trigger.key.unicode);
    }
    // Performable bindings are not tracked in the reverse map,
    // so config_trigger_ should return a default (empty) trigger.
    if (comptime builtin.target.os.tag.isDarwin()) {
        const next = try config_trigger_(&cfg, "navigate_search:next");
        try testing.expectEqual(.physical, next.tag);
        try testing.expectEqual(.unidentified, next.key.physical);

        const prev = try config_trigger_(&cfg, "navigate_search:previous");
        try testing.expectEqual(.physical, prev.tag);
        try testing.expectEqual(.unidentified, prev.key.physical);
    }
    {
        const trigger = try config_trigger_(&cfg, "adjust_selection:left");
        try testing.expectEqual(.physical, trigger.tag);
        try testing.expectEqual(.unidentified, trigger.key.physical);
    }
}

test "ghostty_config_describe_key: known upstream key" {
    const testing = std.testing;
    const key = "font-size";
    const out = ghostty_config_describe_key(key, key.len);
    try testing.expect(out.known);
    try testing.expect(!out.fork_only);
    // It has a real doc (non-empty).
    try testing.expect(std.mem.span(out.doc).len > 0);
}

test "ghostty_config_describe_key: fork-only key is flagged" {
    const testing = std.testing;
    const key = "agent-dashboard";
    const out = ghostty_config_describe_key(key, key.len);
    try testing.expect(out.known);
    try testing.expect(out.fork_only);
    try testing.expect(std.mem.startsWith(u8, std.mem.span(out.doc), fork_marker));
}

test "ghostty_config_describe_key: unknown key" {
    const testing = std.testing;
    const key = "not-a-real-key";
    const out = ghostty_config_describe_key(key, key.len);
    try testing.expect(!out.known);
    try testing.expect(!out.fork_only);
    try testing.expectEqualStrings("", std.mem.span(out.doc));
}

test "ghostty_config_key_count and key_at enumerate all keys" {
    const testing = std.testing;
    const count = ghostty_config_key_count();
    try testing.expectEqual(@as(u32, std.meta.fields(Key).len), count);
    try testing.expect(count > 0);

    // Every index in range yields a non-empty name; at least one fork-only key
    // is present in the enumeration (the fork adds several).
    var saw_fork = false;
    var saw_font_size = false;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const info = ghostty_config_key_at(i);
        const name = std.mem.span(info.name);
        try testing.expect(name.len > 0);
        if (info.fork_only) saw_fork = true;
        if (std.mem.eql(u8, name, "font-size")) saw_font_size = true;
    }
    try testing.expect(saw_fork);
    try testing.expect(saw_font_size);
}

test "ghostty_config_key_at: out of range is empty" {
    const testing = std.testing;
    const count = ghostty_config_key_count();
    const info = ghostty_config_key_at(count);
    try testing.expectEqualStrings("", std.mem.span(info.name));
    try testing.expect(!info.fork_only);
}
