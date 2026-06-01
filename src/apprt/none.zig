const std = @import("std");
const Allocator = std.mem.Allocator;

const internal_os = @import("../os/main.zig");
const apprt = @import("../apprt.zig");
pub const resourcesDir = internal_os.resourcesDir;

pub const App = struct {
    /// No-op wakeup. The headless host (ghostty-host) drains its mailboxes
    /// directly, so nothing needs waking. This exists so that the surface
    /// mailbox push path (App.Mailbox.push -> rt_app.wakeup) compiles and
    /// is a pure no-op in a headless `app_runtime=.none` executable.
    pub fn wakeup(_: *const App) void {}

    /// Always return false as there is no apprt to communicate with.
    pub fn performIpc(
        _: Allocator,
        _: apprt.ipc.Target,
        comptime action: apprt.ipc.Action.Key,
        _: apprt.ipc.Action.Value(action),
    ) !bool {
        return false;
    }
};
pub const Surface = struct {};
