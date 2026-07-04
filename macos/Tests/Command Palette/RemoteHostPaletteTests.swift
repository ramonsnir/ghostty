import Foundation
import Testing
import GhosttyKit
@testable import Ghostty

/// (ramon fork / cloud-hosts) Unit tests for the remote-host picker palette's
/// pure option-building helper (`sortedEntries(from:)`), which parses the raw
/// `pty-remote-host` lines (via `RemoteHostRegistry`) and orders them for
/// display. The fuzzy match itself lives in the shared `CommandPaletteView`
/// (already covered), so these focus on the palette's own list-building +
/// empty-state behavior.
struct RemoteHostPaletteTests {

    // MARK: - sortedEntries

    @Test func emptyLinesYieldNoEntries() {
        // Drives the informational "No remote hosts configured" row.
        #expect(RemoteHostPaletteView.sortedEntries(from: []).isEmpty)
    }

    @Test func allMalformedOrReservedYieldNoEntries() {
        let lines = [
            "no-equals-sign",                 // no '=' at all
            "local = user@box : ~/x.sock",    // reserved name
            " = user@box : ~/x.sock",         // empty name
            "cloud-x = onlyonefield",         // only 1 field
        ]
        #expect(RemoteHostPaletteView.sortedEntries(from: lines).isEmpty)
    }

    @Test func singleValidLineParses() {
        let entries = RemoteHostPaletteView.sortedEntries(
            from: ["cloud-1 = user@cloud-1.example.ts.net : ~/.ghostty-ramon-host.sock"])
        #expect(entries.count == 1)
        #expect(entries.first?.name == "cloud-1")
        #expect(entries.first?.sshTarget == "user@cloud-1.example.ts.net")
        #expect(entries.first?.remoteSocketPath == "~/.ghostty-ramon-host.sock")
        #expect(entries.first?.localSocketPath == nil)
    }

    @Test func multipleEntriesSortedCaseInsensitivelyByName() {
        let lines = [
            "zephyr = user@zephyr.example.ts.net : ~/h.sock",
            "Alpha = user@alpha.example.ts.net : ~/h.sock",
            "cloud-2 = user@cloud-2.example.ts.net : ~/h.sock",
        ]
        let names = RemoteHostPaletteView.sortedEntries(from: lines).map(\.name)
        #expect(names == ["Alpha", "cloud-2", "zephyr"])
    }

    @Test func malformedLinesDroppedValidKept() {
        let lines = [
            "cloud-1 = user@cloud-1.example.ts.net : ~/h.sock",
            "garbage line with no equals",
            "local = user@box : ~/h.sock",  // reserved
            "cloud-2 = user@cloud-2.example.ts.net : ~/h.sock : /tmp/gr-c2.sock",
        ]
        let entries = RemoteHostPaletteView.sortedEntries(from: lines)
        #expect(entries.map(\.name) == ["cloud-1", "cloud-2"])
        // The 3-field entry carries an explicit local socket path.
        #expect(entries.last?.localSocketPath == "/tmp/gr-c2.sock")
    }
}
