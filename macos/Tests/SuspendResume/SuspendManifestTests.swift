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

    // MARK: - One-time re-attach seed (Fix 2)

    @Test func parsesReattachSeedKeyedByUppercasedUUID() {
        let json = """
        { "surfaces": {
            "2a14d41b-f26f-48cf-8572-ab1b262438da": {
                "claudeSessionId": "6f0b1d10-7915-4e94-900f-91553c1f117a",
                "cwd": "/Users/example/project", "agentKind": "claude",
                "title": "PR #7124 implementation details" }
        } }
        """.data(using: .utf8)!
        let seed = SuspendManifest.parseReattachSeed(json)
        // Key is uppercased so it matches Foundation's UUID.uuidString.
        let m = seed["2A14D41B-F26F-48CF-8572-AB1B262438DA"]
        #expect(m?.claudeSessionId == "6f0b1d10-7915-4e94-900f-91553c1f117a")
        #expect(m?.cwd == "/Users/example/project")
        #expect(m?.agentKind == "claude")
        #expect(m?.resumeInputLine == "claude-pool --resume 6f0b1d10-7915-4e94-900f-91553c1f117a\n")
    }

    @Test func reattachSeedDefaultsAgentKindToClaude() {
        let json = """
        { "surfaces": { "AAAAAAAA-0000-0000-0000-000000000000": {
            "claudeSessionId": "sess-1", "cwd": "/x" } } }
        """.data(using: .utf8)!
        let seed = SuspendManifest.parseReattachSeed(json)
        #expect(seed["AAAAAAAA-0000-0000-0000-000000000000"]?.agentKind == "claude")
        #expect(seed["AAAAAAAA-0000-0000-0000-000000000000"]?.poolCommand == "claude-pool")
    }

    @Test func reattachSeedSkipsEntriesMissingIdOrCwd() {
        let json = """
        { "surfaces": {
            "AAAAAAAA-0000-0000-0000-000000000000": { "claudeSessionId": "", "cwd": "/x" },
            "BBBBBBBB-0000-0000-0000-000000000000": { "claudeSessionId": "ok", "cwd": "" },
            "CCCCCCCC-0000-0000-0000-000000000000": { "claudeSessionId": "ok", "cwd": "/x" }
        } }
        """.data(using: .utf8)!
        let seed = SuspendManifest.parseReattachSeed(json)
        // Only the fully-specified entry survives (the others could never resume safely).
        #expect(seed.count == 1)
        #expect(seed["CCCCCCCC-0000-0000-0000-000000000000"] != nil)
    }

    @Test func reattachSeedFailsOpenOnGarbageOrMissing() {
        #expect(SuspendManifest.parseReattachSeed(Data("not json".utf8)).isEmpty)
        #expect(SuspendManifest.parseReattachSeed(Data("{}".utf8)).isEmpty)
        // A missing file path yields an empty map (no crash, no behavior change).
        #expect(SuspendManifest.loadReattachSeed(path: "/nonexistent/seed.json").isEmpty)
    }
}
