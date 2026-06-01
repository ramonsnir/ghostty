//! Barrel module for the ghostty-host tree. Pulls in the host submodules so
//! their tests are reachable, and is the single import point referenced from
//! src/main_ghostty.zig's test block (so `-Dtest-filter=host` finds the host
//! tests) and from src/main_host.zig.

const Session = @import("Session.zig");
const RenderState = @import("RenderState.zig");
const protocol = @import("protocol.zig");
const Server = @import("Server.zig");

test {
    _ = Session;
    _ = RenderState;
    _ = protocol;
    _ = Server;
    _ = @import("test.zig");
}
