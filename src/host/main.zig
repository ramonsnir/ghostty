//! Barrel module for the ghostty-host tree. Pulls in the host submodules so
//! their tests are reachable, and is the single import point referenced from
//! src/main_ghostty.zig's test block (so `-Dtest-filter=host` finds the host
//! tests) and from src/main_host.zig.

const builtin = @import("builtin");
const Session = @import("Session.zig");
const RenderState = @import("RenderState.zig");
const protocol = @import("protocol.zig");
const Server = @import("Server.zig");
const Supervisor = @import("Supervisor.zig");

test {
    _ = Session;
    _ = RenderState;
    _ = protocol;
    _ = Server;
    // FORK(host-handoff): the supervisor + its pure argv mode parser (analyzable on
    // every target; handoff bodies are macOS-gated).
    _ = Supervisor;
    _ = @import("test.zig");
    _ = @import("difftest.zig");
    // FORK(host-handoff): session-state serialize/deserialize round-trip tests.
    _ = @import("session_transfer.zig");
    // fdpass + handoff_protocol are macOS-only (hand-rolled Darwin cmsg ABI);
    // referencing them on other targets (the Linux cloud-box host) would trip
    // their platform @compileError, so gate — the untaken comptime branch isn't
    // analyzed.
    if (builtin.os.tag == .macos) {
        _ = @import("fdpass.zig");
        _ = @import("handoff_protocol.zig");
    }
}
