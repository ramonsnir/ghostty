import Foundation
import Testing
@testable import Ghostty

/// Unit tests for the SAFE Codex-agent-hooks installer — the Codex twin of
/// `AgentHooksInstallerTests`. Covers the pure merge/detect helpers (idempotency,
/// preserving existing entries, fresh creation, malformed handling), the auto-offer
/// truth table, and a temp-HOME end-to-end `install()` into `~/.codex/hooks.json`.
struct CodexHooksInstallerTests {

    // MARK: - Helpers

    private var allEvents: [String] {
        CodexHooksInstaller.hookEvents.map { $0.name }
    }

    private func makeTempHome() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty-codex-hooks-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    // MARK: - Event set + shape

    @Test func hookEventsAreTheCodexSix() {
        // The Codex set uses PermissionRequest (not Claude's Notification) and starts
        // with SessionStart; the exact set + state mapping is load-bearing.
        #expect(Set(allEvents) == Set([
            "SessionStart", "UserPromptSubmit", "PreToolUse",
            "PermissionRequest", "Stop", "SessionEnd",
        ]))
    }

    @Test func mergeCreatesFromEmpty() {
        let (out, result) = CodexHooksInstaller.mergeHooks(into: [:], wasCreated: true)
        #expect(result.created)
        #expect(Set(result.added) == Set(allEvents))
        #expect(result.skipped.isEmpty)
        #expect(result.changed)

        let hooks = out["hooks"] as? [String: Any]
        #expect(hooks != nil)
        for event in CodexHooksInstaller.hookEvents {
            let arr = hooks?[event.name] as? [Any]
            #expect(arr?.count == 1)
            #expect(CodexHooksInstaller.arrayContainsOurHook(arr ?? []))
        }
    }

    @Test func preToolUseCarriesRegexMatcher() {
        let (out, _) = CodexHooksInstaller.mergeHooks(into: [:], wasCreated: true)
        let hooks = out["hooks"] as? [String: Any]
        let entry = (hooks?["PreToolUse"] as? [Any])?.first as? [String: Any]
        // Codex matchers are REGEXES — match-all is ".*", NOT Claude's glob "*".
        #expect(entry?["matcher"] as? String == ".*")

        // A non-tool event carries NO matcher key.
        let stopEntry = (hooks?["Stop"] as? [Any])?.first as? [String: Any]
        #expect(stopEntry?["matcher"] == nil)
    }

    @Test func mergeUsesCorrectStatePerEvent() {
        let (out, _) = CodexHooksInstaller.mergeHooks(into: [:], wasCreated: true)
        let hooks = out["hooks"] as? [String: Any]

        func command(_ event: String) -> String? {
            let arr = hooks?[event] as? [Any]
            let entry = arr?.first as? [String: Any]
            let inner = entry?["hooks"] as? [Any]
            let h = inner?.first as? [String: Any]
            return h?["command"] as? String
        }

        #expect(command("SessionStart")?.hasSuffix(" working") == true)
        #expect(command("UserPromptSubmit")?.hasSuffix(" working") == true)
        #expect(command("PreToolUse")?.hasSuffix(" working") == true)
        #expect(command("PermissionRequest")?.hasSuffix(" waiting") == true)
        #expect(command("Stop")?.hasSuffix(" idle") == true)
        #expect(command("SessionEnd")?.hasSuffix(" idle") == true)
        #expect(command("Stop")?.contains(CodexHooksInstaller.scriptMarker) == true)
        // The command points at the codex-hooks dir, not claude-hooks.
        #expect(command("Stop")?.contains("codex-hooks/ghostty-agent-state.sh") == true)
    }

    // MARK: - preserve / idempotent

    @Test func mergePreservesExistingUserEntries() {
        let userStop: [String: Any] = [
            "hooks": [
                ["type": "command", "command": "echo my-own-stop-hook"] as [String: Any]
            ] as [Any]
        ]
        let settings: [String: Any] = [
            "model": "gpt-5-codex",
            "hooks": ["Stop": [userStop] as [Any]] as [String: Any],
        ]

        let (out, result) = CodexHooksInstaller.mergeHooks(into: settings)
        #expect(out["model"] as? String == "gpt-5-codex")

        let stopArr = (out["hooks"] as? [String: Any])?["Stop"] as? [Any]
        #expect(stopArr?.count == 2)
        let firstInner = (stopArr?.first as? [String: Any])?["hooks"] as? [Any]
        let firstCmd = (firstInner?.first as? [String: Any])?["command"] as? String
        #expect(firstCmd == "echo my-own-stop-hook")
        #expect(result.added.contains("Stop"))
        #expect(CodexHooksInstaller.arrayContainsOurHook(stopArr ?? []))
    }

    @Test func mergeIsIdempotent() {
        let (once, r1) = CodexHooksInstaller.mergeHooks(into: [:], wasCreated: true)
        #expect(Set(r1.added) == Set(allEvents))

        let (twice, r2) = CodexHooksInstaller.mergeHooks(into: once)
        #expect(r2.added.isEmpty)
        #expect(Set(r2.skipped) == Set(allEvents))
        #expect(!r2.changed)

        let hooks = twice["hooks"] as? [String: Any]
        for event in allEvents {
            #expect((hooks?[event] as? [Any])?.count == 1)
        }
    }

    // MARK: - detection

    @Test func hooksInstalledFalseForEmpty() {
        #expect(!CodexHooksInstaller.hooksInstalled(settings: [:]))
        #expect(!CodexHooksInstaller.hooksInstalled(settings: ["hooks": [:] as [String: Any]]))
    }

    @Test func hooksInstalledIgnoresClaudeMarkerInWrongDir() {
        // A claude-hooks command in a Codex file must NOT read as our Codex hook —
        // the marker includes the `codex-hooks/` path segment specifically for this.
        let settings: [String: Any] = [
            "hooks": [
                "Stop": [
                    ["hooks": [["type": "command",
                                "command": "~/.config/ghostty-ramon/claude-hooks/ghostty-agent-state.sh idle"]
                               as [String: Any]] as [Any]] as [String: Any]
                ] as [Any]
            ] as [String: Any]
        ]
        #expect(!CodexHooksInstaller.hooksInstalled(settings: settings))
    }

    @Test func hooksInstalledTrueWhenPresent() {
        let (merged, _) = CodexHooksInstaller.mergeHooks(into: [:], wasCreated: true)
        #expect(CodexHooksInstaller.hooksInstalled(settings: merged))
    }

    // MARK: - auto-offer truth table

    @Test func autoOfferTruthTable() {
        #expect(CodexHooksInstaller.shouldAutoOfferHooks(
            featureEnabled: true, installed: false, alreadyAsked: false))
        #expect(!CodexHooksInstaller.shouldAutoOfferHooks(
            featureEnabled: false, installed: false, alreadyAsked: false))
        #expect(!CodexHooksInstaller.shouldAutoOfferHooks(
            featureEnabled: true, installed: true, alreadyAsked: false))
        #expect(!CodexHooksInstaller.shouldAutoOfferHooks(
            featureEnabled: true, installed: false, alreadyAsked: true))
    }

    // MARK: - malformed handling

    @Test func readSettingsThrowsOnMalformed() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let path = CodexHooksInstaller.settingsPath(home: home)
        try FileManager.default.createDirectory(
            atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path,
            withIntermediateDirectories: true)
        try Data("{ this is not json".utf8).write(to: URL(fileURLWithPath: path))
        #expect(throws: CodexHooksInstaller.InstallError.self) {
            _ = try CodexHooksInstaller.readSettings(path: path)
        }
    }

    // MARK: - install() end to end

    @Test func settingsPathIsCodexHooksJson() {
        #expect(CodexHooksInstaller.settingsPath(home: "/tmp/h") == "/tmp/h/.codex/hooks.json")
        #expect(CodexHooksInstaller.scriptPath(home: "/tmp/h")
            == "/tmp/h/.config/ghostty-ramon/codex-hooks/ghostty-agent-state.sh")
    }

    @Test func installCreatesScriptAndHooksJson() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(atPath: home) }

        let result = try CodexHooksInstaller.install(home: home)
        #expect(result.scriptWritten)
        #expect(result.merge.created)
        #expect(result.backupPath == nil)

        // Script exists, is executable, and is byte-identical to the embedded copy
        // (the self-containment invariant the generator guarantees).
        let scriptPath = CodexHooksInstaller.scriptPath(home: home)
        #expect(FileManager.default.isExecutableFile(atPath: scriptPath))
        let onDisk = try String(contentsOfFile: scriptPath, encoding: .utf8)
        #expect(onDisk == CodexHooksInstaller.hookScript + "\n")
        #expect(onDisk.hasPrefix("#!/usr/bin/env bash"))
        // The embedded script POSTs the codex kind + carries the codex mapping.
        #expect(onDisk.contains(#""kind":"codex""#))

        // hooks.json exists, is valid JSON, hooks detected.
        let settingsPath = CodexHooksInstaller.settingsPath(home: home)
        let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj != nil)
        #expect(CodexHooksInstaller.hooksInstalled(settings: obj ?? [:]))
    }

    @Test func installIsIdempotentAndBacksUp() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(atPath: home) }

        _ = try CodexHooksInstaller.install(home: home)
        let second = try CodexHooksInstaller.install(home: home)
        #expect(second.merge.added.isEmpty)
        #expect(Set(second.merge.skipped) == Set(allEvents))
        #expect(!second.merge.changed)
        #expect(second.backupPath == nil)
    }

    @Test func installRefusesMalformedHooksJson() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let settingsPath = CodexHooksInstaller.settingsPath(home: home)
        try FileManager.default.createDirectory(
            atPath: URL(fileURLWithPath: settingsPath).deletingLastPathComponent().path,
            withIntermediateDirectories: true)
        let bad = "{ broken json"
        try Data(bad.utf8).write(to: URL(fileURLWithPath: settingsPath))

        #expect(throws: CodexHooksInstaller.InstallError.self) {
            _ = try CodexHooksInstaller.install(home: home)
        }
        // The malformed file is NOT overwritten.
        let after = try String(contentsOfFile: settingsPath, encoding: .utf8)
        #expect(after == bad)
    }
}
