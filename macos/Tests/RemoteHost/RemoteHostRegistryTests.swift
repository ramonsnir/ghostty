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

    // MARK: - (Phase 6) Command-override entries (`pty-remote-host-command`)

    @Test func parseCommandSplitsNameOnFirstEqualsAndTrims() {
        let c = RemoteHostRegistry.parseCommand(line: "  cloud-1  =  gcp_ssh cloud-1 --  ")
        #expect(c?.name == "cloud-1")
        #expect(c?.command == "gcp_ssh cloud-1 --")
    }

    @Test func parseCommandKeepsColonsAndEqualsInTemplateVerbatim() {
        // The command remainder is NOT field-split — a `:` / `=` / spaces are all preserved.
        let c = RemoteHostRegistry.parseCommand(
            line: "box = wrapper --zone=us-a --tunnel a:b -- ssh")
        #expect(c?.name == "box")
        #expect(c?.command == "wrapper --zone=us-a --tunnel a:b -- ssh")
    }

    @Test func parseCommandRejectsMalformedAndReserved() {
        #expect(RemoteHostRegistry.parseCommand(line: "no-equals-here") == nil)   // no '='
        #expect(RemoteHostRegistry.parseCommand(line: " = gcp_ssh x --") == nil)  // empty name
        #expect(RemoteHostRegistry.parseCommand(line: "cloud-1 =    ") == nil)     // empty command
        #expect(RemoteHostRegistry.parseCommand(line: "local = gcp_ssh x --") == nil)  // reserved
        #expect(RemoteHostRegistry.parseCommand(line: "LOCAL = gcp_ssh x --") == nil)  // case-insensitive
    }

    @Test func parseCommandsBuildsMapLastDuplicateWins() {
        let map = RemoteHostRegistry.parseCommands(lines: [
            "cloud-1 = wrapper-a cloud-1 --",
            "garbage-no-equals",                     // skipped
            "cloud-1 = wrapper-b cloud-1 --",        // duplicate → wins
            "cloud-2 = wrapper-c cloud-2 --",
        ])
        #expect(map.count == 2)
        #expect(map["cloud-1"] == "wrapper-b cloud-1 --")
        #expect(map["cloud-2"] == "wrapper-c cloud-2 --")
    }

    @Test func builderPairsCommandOntoMatchingHostAndLeavesOthersNil() {
        let reg = RemoteHostRegistry.parse(
            lines: [
                "cloud-1 = label-1 : ~/a.sock",
                "cloud-2 = user@c.example.ts.net : ~/c.sock",
            ],
            commandLines: [
                "cloud-1 = gcp_ssh cloud-1 --",
                // A command whose name has NO host line is simply never consumed.
                "ghost = wrapper ghost --",
            ])
        #expect(reg.count == 2)
        // cloud-1 gets the override; its ssh-target stays as the label; the remote socket
        // path still comes from the host line.
        #expect(reg["cloud-1"]?.transportCommand == "gcp_ssh cloud-1 --")
        #expect(reg["cloud-1"]?.sshTarget == "label-1")
        #expect(reg["cloud-1"]?.remoteSocketPath == "~/a.sock")
        // cloud-2 has no override → nil (default ssh ControlMaster transport, byte-identical).
        #expect(reg["cloud-2"]?.transportCommand == nil)
        // The unmatched command produced no phantom entry.
        #expect(reg["ghost"] == nil)
    }

    @Test func builderWithoutCommandLinesLeavesEveryTransportCommandNil() {
        // Back-compat: the single-argument builder (name/label-only callers) must leave every
        // entry with transportCommand == nil (default ssh path, unchanged).
        let reg = RemoteHostRegistry.parse(lines: [
            "cloud-1 = user@a.example.ts.net : ~/a.sock",
            "cloud-2 = user@c.example.ts.net : ~/c.sock : /tmp/c.sock",
        ])
        #expect(reg.count == 2)
        #expect(reg["cloud-1"]?.transportCommand == nil)
        #expect(reg["cloud-2"]?.transportCommand == nil)
    }
}
