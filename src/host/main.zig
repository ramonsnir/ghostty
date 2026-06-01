//! Barrel module for the ghostty-host tree. Pulls in the host submodules so
//! their tests are reachable, and is the single import point referenced from
//! src/main_ghostty.zig's test block (so `-Dtest-filter=host` finds the host
//! tests) and from src/main_host.zig.

const Session = @import("Session.zig");
const RenderState = @import("RenderState.zig");

test {
    _ = Session;
    _ = RenderState;
    _ = @import("test.zig");
}
