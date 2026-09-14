import Foundation
import Testing
@testable import Ghostty

/// (ramon fork / suspend-resume) Unit tests for the Resume manifest — chiefly the
/// shell-safety guard on `resumeInputLine` and the pool-command mapping.
struct SuspendManifestTests {

    private func manifest(id: String, kind: String = "claude") -> SuspendManifest {
        SuspendManifest(
            claudeSessionId: id, cwd: "/Users/example/project", agentKind: kind,
            title: "work", lastPrompt: "do the thing", suspendedAt: Date(timeIntervalSince1970: 0))
    }

    @Test func buildsClaudeResumeLine() {
        let m = manifest(id: "abc123-DEF-456_78")
        #expect(m.poolCommand == "claude-pool")
        #expect(m.resumeInputLine == "claude-pool --resume abc123-DEF-456_78\n")
    }

    @Test func codexUsesCodexPool() {
        let m = manifest(id: "roll-01", kind: "codex")
        #expect(m.poolCommand == "codex-pool")
        #expect(m.resumeInputLine == "codex-pool --resume roll-01\n")
    }

    @Test func parsesResumeIdFromCommand() {
        #expect(SuspendManifest.resumeId(
            fromCommand: "bash /x/claude-pool --resume 6d768f90-612f-4c34-8d9f-2e1d9c6568f8")
            == "6d768f90-612f-4c34-8d9f-2e1d9c6568f8")
        // codex uses bare `resume <id>`
        #expect(SuspendManifest.resumeId(
            fromCommand: "bash /x/codex-pool resume 01a0869a-63e1-7940-be97-f31e77812cfa")
            == "01a0869a-63e1-7940-be97-f31e77812cfa")
        // fresh split (no --resume) → nil, never guessed
        #expect(SuspendManifest.resumeId(fromCommand: "bash /x/claude-pool") == nil)
        #expect(SuspendManifest.resumeId(fromCommand: "") == nil)
        // an unsafe token after --resume is rejected (never rides into the shell)
        #expect(SuspendManifest.resumeId(fromCommand: "claude --resume ;rm-rf") == nil)
    }

    @Test func rejectsUnsafeSessionIds() {
        // Anything outside [A-Za-z0-9-_] must yield nil so nothing can ride into the shell.
        for bad in ["id; rm -rf ~", "id with space", "id$(whoami)", "id&", "id\nwhoami", "id`x`", "id/../x", ""] {
            #expect(manifest(id: bad).resumeInputLine == nil, "expected nil for \(bad.debugDescription)")
        }
    }

    @Test func codableRoundTrips() throws {
        let m = manifest(id: "sess-1")
        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(SuspendManifest.self, from: data)
        #expect(back == m)
    }

    @Test func settingsDefaults() {
        // Threshold floors to 2 when unset/<1 (UserDefaults.integer default is 0).
        let d = UserDefaults.standard
        let key = "suspendIdleBusinessDays"
        let saved = d.object(forKey: key)
        d.removeObject(forKey: key)
        #expect(SuspendSettings.businessDays == 2)
        d.set(5, forKey: key)
        #expect(SuspendSettings.businessDays == 5)
        // restore
        if let saved { d.set(saved, forKey: key) } else { d.removeObject(forKey: key) }
    }
}
