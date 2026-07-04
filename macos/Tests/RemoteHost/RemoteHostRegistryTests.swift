import Foundation
import Testing
@testable import Ghostty

/// (ramon fork / cloud-hosts) Unit tests for the SOLE home of the `pty-remote-host` line
/// grammar: `RemoteHostRegistry.parse(line:)` / `parse(lines:)`.
struct RemoteHostRegistryTests {

    // MARK: - Happy path

    @Test func parsesSpacedSeparatorTwoFields() {
        let e = RemoteHostRegistry.parse(
            line: "cloud-1 = user@cloud-1.example.ts.net : ~/.ghostty-ramon-host.sock")
        #expect(e?.name == "cloud-1")
        #expect(e?.sshTarget == "user@cloud-1.example.ts.net")
        #expect(e?.remoteSocketPath == "~/.ghostty-ramon-host.sock")
        #expect(e?.localSocketPath == nil)
    }

    @Test func parsesOptionalLocalSocketThirdField() {
        let e = RemoteHostRegistry.parse(
            line: "cloud-1 = user@example.ts.net : ~/.ghostty-ramon-host.sock : /tmp/gr-1.sock")
        #expect(e?.name == "cloud-1")
        #expect(e?.sshTarget == "user@example.ts.net")
        #expect(e?.remoteSocketPath == "~/.ghostty-ramon-host.sock")
        #expect(e?.localSocketPath == "/tmp/gr-1.sock")
    }

    @Test func userAtHostStaysIntact() {
        // A bare `:` inside `user@host:port` must NOT split (only spaced " : " does).
        let e = RemoteHostRegistry.parse(
            line: "box = user@host.example.ts.net : /run/gr.sock")
        #expect(e?.sshTarget == "user@host.example.ts.net")
        #expect(e?.remoteSocketPath == "/run/gr.sock")
    }

    @Test func ipv6TargetStaysIntact() {
        // IPv6 literal has bare `::` — must survive because the separator is spaced.
        let e = RemoteHostRegistry.parse(
            line: "v6 = user@fd00::1 : ~/.ghostty-ramon-host.sock")
        #expect(e?.name == "v6")
        #expect(e?.sshTarget == "user@fd00::1")
        #expect(e?.remoteSocketPath == "~/.ghostty-ramon-host.sock")
    }

    @Test func equalsFreeSocketPathIsFine() {
        // Only the FIRST '=' splits the name; the socket fields have no '='.
        let e = RemoteHostRegistry.parse(line: "n = host.example.ts.net : /var/run/gr.sock")
        #expect(e?.name == "n")
        #expect(e?.sshTarget == "host.example.ts.net")
        #expect(e?.remoteSocketPath == "/var/run/gr.sock")
    }

    @Test func trimsEveryField() {
        let e = RemoteHostRegistry.parse(
            line: "   spaced   =    user@example.ts.net    :    ~/sock    ")
        #expect(e?.name == "spaced")
        #expect(e?.sshTarget == "user@example.ts.net")
        #expect(e?.remoteSocketPath == "~/sock")
    }

    // MARK: - Reserved + malformed → nil

    @Test func localNameIsReserved() {
        #expect(RemoteHostRegistry.parse(line: "local = user@example.ts.net : ~/sock") == nil)
        // Case-insensitive.
        #expect(RemoteHostRegistry.parse(line: "LOCAL = user@example.ts.net : ~/sock") == nil)
    }

    @Test func noEqualsIsMalformed() {
        #expect(RemoteHostRegistry.parse(line: "user@example.ts.net : ~/sock") == nil)
    }

    @Test func emptyNameIsMalformed() {
        #expect(RemoteHostRegistry.parse(line: " = user@example.ts.net : ~/sock") == nil)
    }

    @Test func missingSocketIsMalformed() {
        // Only the ssh-target after the name → fewer than 2 fields.
        #expect(RemoteHostRegistry.parse(line: "n = user@example.ts.net") == nil)
    }

    @Test func emptyRequiredFieldIsMalformed() {
        #expect(RemoteHostRegistry.parse(line: "n =  : ~/sock") == nil)
        #expect(RemoteHostRegistry.parse(line: "n = user@example.ts.net : ") == nil)
    }

    @Test func tooManyFieldsIsMalformed() {
        #expect(RemoteHostRegistry.parse(line: "n = a : b : c : d") == nil)
    }

    // MARK: - Registry building

    @Test func buildsRegistrySkippingMalformedAndReserved() {
        let reg = RemoteHostRegistry.parse(lines: [
            "cloud-1 = user@a.example.ts.net : ~/a.sock",
            "local = user@b.example.ts.net : ~/b.sock",  // reserved → skipped
            "garbage-no-equals",                          // malformed → skipped
            "cloud-2 = user@c.example.ts.net : ~/c.sock : /tmp/c.sock",
        ])
        #expect(reg.count == 2)
        #expect(reg["cloud-1"]?.sshTarget == "user@a.example.ts.net")
        #expect(reg["cloud-2"]?.localSocketPath == "/tmp/c.sock")
        #expect(reg["local"] == nil)
    }

    @Test func lastDuplicateWins() {
        let reg = RemoteHostRegistry.parse(lines: [
            "dup = user@old.example.ts.net : ~/old.sock",
            "dup = user@new.example.ts.net : ~/new.sock",
        ])
        #expect(reg.count == 1)
        #expect(reg["dup"]?.sshTarget == "user@new.example.ts.net")
    }
}
