import Foundation
import Testing
@testable import Ghostty

/// Unit tests for the SAFE Claude-agent-hooks installer: the pure merge/detect
/// helpers (idempotency, preserving existing entries, fresh creation, malformed
/// handling), the auto-offer truth table, and a temp-HOME end-to-end `install()`.
struct AgentHooksInstallerTests {

    // MARK: - Helpers

    /// All six event names, for assertions.
    private var allEvents: [String] {
        AgentHooksInstaller.hookEvents.map { $0.name }
    }

    /// Make a temp HOME dir; caller cleans up.
    private func makeTempHome() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty-hooks-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    // MARK: - mergeHooks: create from empty

    @Test func mergeCreatesFromEmpty() {
        let (out, result) = AgentHooksInstaller.mergeHooks(
            into: [:], wasCreated: true)

        #expect(result.created)
        #expect(Set(result.added) == Set(allEvents))
        #expect(result.skipped.isEmpty)
        #expect(result.changed)

        // The merged object has all six events under "hooks", each with our cmd.
        let hooks = out["hooks"] as? [String: Any]
        #expect(hooks != nil)
        for event in AgentHooksInstaller.hookEvents {
            let arr = hooks?[event.name] as? [Any]
            #expect(arr?.count == 1)
            #expect(AgentHooksInstaller.arrayContainsOurHook(arr ?? []))
        }
    }

    @Test func mergeCreatesPreToolUseWithMatcher() {
        let (out, _) = AgentHooksInstaller.mergeHooks(into: [:], wasCreated: true)
        let hooks = out["hooks"] as? [String: Any]
        let arr = hooks?["PreToolUse"] as? [Any]
        let entry = arr?.first as? [String: Any]
        #expect(entry?["matcher"] as? String == "*")

        // A non-tool event carries NO matcher key.
        let stopArr = hooks?["Stop"] as? [Any]
        let stopEntry = stopArr?.first as? [String: Any]
        #expect(stopEntry?["matcher"] == nil)
    }

    @Test func mergeUsesCorrectStatePerEvent() {
        let (out, _) = AgentHooksInstaller.mergeHooks(into: [:], wasCreated: true)
        let hooks = out["hooks"] as? [String: Any]

        func command(_ event: String) -> String? {
            let arr = hooks?[event] as? [Any]
            let entry = arr?.first as? [String: Any]
            let inner = entry?["hooks"] as? [Any]
            let h = inner?.first as? [String: Any]
            return h?["command"] as? String
        }

        #expect(command("UserPromptSubmit")?.hasSuffix(" working") == true)
        #expect(command("PreToolUse")?.hasSuffix(" working") == true)
        #expect(command("Notification")?.hasSuffix(" waiting") == true)
        #expect(command("Stop")?.hasSuffix(" idle") == true)
        #expect(command("SessionStart")?.hasSuffix(" working") == true)
        #expect(command("SessionEnd")?.hasSuffix(" idle") == true)
        // The command references the installed script path.
        #expect(command("Stop")?.contains(AgentHooksInstaller.scriptMarker) == true)
    }

    // MARK: - mergeHooks: preserve existing user entries

    @Test func mergePreservesExistingUserEntries() {
        // A user already has a CUSTOM (non-ours) Stop hook + an unrelated
        // top-level key. Both must survive, and our Stop entry must be APPENDED.
        let userStop: [String: Any] = [
            "hooks": [
                ["type": "command", "command": "echo my-own-stop-hook"] as [String: Any]
            ] as [Any]
        ]
        let settings: [String: Any] = [
            "model": "claude-sonnet",
            "hooks": [
                "Stop": [userStop] as [Any]
            ] as [String: Any],
        ]

        let (out, result) = AgentHooksInstaller.mergeHooks(into: settings)

        // Unrelated top-level key preserved.
        #expect(out["model"] as? String == "claude-sonnet")

        let hooks = out["hooks"] as? [String: Any]
        let stopArr = hooks?["Stop"] as? [Any]
        // The user's original entry is still there + ours appended.
        #expect(stopArr?.count == 2)
        // The user's entry survives unchanged.
        let firstInner = (stopArr?.first as? [String: Any])?["hooks"] as? [Any]
        let firstCmd = (firstInner?.first as? [String: Any])?["command"] as? String
        #expect(firstCmd == "echo my-own-stop-hook")
        // Ours got added.
        #expect(result.added.contains("Stop"))
        #expect(AgentHooksInstaller.arrayContainsOurHook(stopArr ?? []))
    }

    // MARK: - mergeHooks: idempotent

    @Test func mergeIsIdempotent() {
        // First merge creates everything.
        let (once, r1) = AgentHooksInstaller.mergeHooks(into: [:], wasCreated: true)
        #expect(Set(r1.added) == Set(allEvents))

        // Second merge on the already-merged object adds NOTHING, skips all.
        let (twice, r2) = AgentHooksInstaller.mergeHooks(into: once)
        #expect(r2.added.isEmpty)
        #expect(Set(r2.skipped) == Set(allEvents))
        #expect(!r2.changed)

        // No event grows a duplicate entry.
        let hooks = twice["hooks"] as? [String: Any]
        for event in allEvents {
            let arr = hooks?[event] as? [Any]
            #expect(arr?.count == 1)
        }
    }

    @Test func mergeSkipsOnlyAlreadyInstalledEvents() {
        // Pre-install just Stop; the other five should be added.
        var settings: [String: Any] = [:]
        let stopEntry = AgentHooksInstaller.entry(
            for: AgentHooksInstaller.hookEvents.first { $0.name == "Stop" }!)
        settings["hooks"] = ["Stop": [stopEntry] as [Any]] as [String: Any]

        let (_, result) = AgentHooksInstaller.mergeHooks(into: settings)
        #expect(result.skipped == ["Stop"])
        #expect(Set(result.added) == Set(allEvents).subtracting(["Stop"]))
    }

    // MARK: - hooksInstalled detection

    @Test func hooksInstalledFalseForEmpty() {
        #expect(!AgentHooksInstaller.hooksInstalled(settings: [:]))
        #expect(!AgentHooksInstaller.hooksInstalled(
            settings: ["hooks": [:] as [String: Any]]))
    }

    @Test func hooksInstalledFalseForOtherHooksOnly() {
        let settings: [String: Any] = [
            "hooks": [
                "Stop": [
                    ["hooks": [["type": "command", "command": "echo not-ours"]
                               as [String: Any]] as [Any]] as [String: Any]
                ] as [Any]
            ] as [String: Any]
        ]
        #expect(!AgentHooksInstaller.hooksInstalled(settings: settings))
    }

    @Test func hooksInstalledTrueWhenPresent() {
        let (merged, _) = AgentHooksInstaller.mergeHooks(into: [:], wasCreated: true)
        #expect(AgentHooksInstaller.hooksInstalled(settings: merged))
    }

    @Test func hooksInstalledTrueWithAnySingleEvent() {
        // Even one of our events present counts as installed.
        var settings: [String: Any] = [:]
        let nEntry = AgentHooksInstaller.entry(
            for: AgentHooksInstaller.hookEvents.first { $0.name == "Notification" }!)
        settings["hooks"] = ["Notification": [nEntry] as [Any]] as [String: Any]
        #expect(AgentHooksInstaller.hooksInstalled(settings: settings))
    }

    // MARK: - shouldAutoOfferHooks truth table

    @Test func autoOfferTruthTable() {
        // Offer ONLY when feature enabled AND not installed AND not asked.
        #expect(AgentHooksInstaller.shouldAutoOfferHooks(
            featureEnabled: true, installed: false, alreadyAsked: false))

        #expect(!AgentHooksInstaller.shouldAutoOfferHooks(
            featureEnabled: false, installed: false, alreadyAsked: false))
        #expect(!AgentHooksInstaller.shouldAutoOfferHooks(
            featureEnabled: true, installed: true, alreadyAsked: false))
        #expect(!AgentHooksInstaller.shouldAutoOfferHooks(
            featureEnabled: true, installed: false, alreadyAsked: true))
        #expect(!AgentHooksInstaller.shouldAutoOfferHooks(
            featureEnabled: false, installed: true, alreadyAsked: true))
    }

    // MARK: - readSettings: malformed handling

    @Test func readSettingsThrowsOnMalformed() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let path = AgentHooksInstaller.settingsPath(home: home)
        try FileManager.default.createDirectory(
            atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path,
            withIntermediateDirectories: true)
        try Data("{ this is not json".utf8).write(to: URL(fileURLWithPath: path))

        #expect(throws: AgentHooksInstaller.InstallError.self) {
            _ = try AgentHooksInstaller.readSettings(path: path)
        }
    }

    @Test func readSettingsNilWhenAbsent() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let path = AgentHooksInstaller.settingsPath(home: home)
        let result = try AgentHooksInstaller.readSettings(path: path)
        #expect(result == nil)
    }

    @Test func readSettingsThrowsWhenNotObject() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let path = AgentHooksInstaller.settingsPath(home: home)
        try FileManager.default.createDirectory(
            atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path,
            withIntermediateDirectories: true)
        try Data("[1,2,3]".utf8).write(to: URL(fileURLWithPath: path))
        #expect(throws: AgentHooksInstaller.InstallError.self) {
            _ = try AgentHooksInstaller.readSettings(path: path)
        }
    }

    // MARK: - install(): end to end in a temp HOME

    @Test func installCreatesScriptAndSettings() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(atPath: home) }

        let result = try AgentHooksInstaller.install(home: home)
        #expect(result.scriptWritten)
        #expect(result.merge.created)
        #expect(result.backupPath == nil)

        // Script exists, is executable, and is byte-identical to the embedded.
        let scriptPath = AgentHooksInstaller.scriptPath(home: home)
        #expect(FileManager.default.isExecutableFile(atPath: scriptPath))
        let onDisk = try String(contentsOfFile: scriptPath, encoding: .utf8)
        #expect(onDisk == AgentHooksInstaller.hookScript + "\n")
        #expect(onDisk.hasPrefix("#!/usr/bin/env bash"))

        // settings.json exists, is valid JSON, hooks detected.
        let settingsPath = AgentHooksInstaller.settingsPath(home: home)
        let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj != nil)
        #expect(AgentHooksInstaller.hooksInstalled(settings: obj ?? [:]))
    }

    @Test func installIsIdempotentAndBacksUp() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(atPath: home) }

        _ = try AgentHooksInstaller.install(home: home)
        // Second install: nothing to add, all skipped, no second write/backup.
        let second = try AgentHooksInstaller.install(home: home)
        #expect(second.merge.added.isEmpty)
        #expect(Set(second.merge.skipped) == Set(allEvents))
        #expect(!second.merge.changed)
        #expect(second.backupPath == nil)
    }

    @Test func installPreservesExistingAndBacksUp() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(atPath: home) }

        // Seed a pre-existing settings.json with an unrelated key + custom hook.
        let settingsPath = AgentHooksInstaller.settingsPath(home: home)
        try FileManager.default.createDirectory(
            atPath: URL(fileURLWithPath: settingsPath)
                .deletingLastPathComponent().path,
            withIntermediateDirectories: true)
        let seed: [String: Any] = [
            "model": "claude-sonnet",
            "hooks": [
                "Stop": [
                    ["hooks": [["type": "command", "command": "echo keep-me"]
                               as [String: Any]] as [Any]] as [String: Any]
                ] as [Any]
            ] as [String: Any],
        ]
        let seedData = try JSONSerialization.data(withJSONObject: seed)
        try seedData.write(to: URL(fileURLWithPath: settingsPath))

        let result = try AgentHooksInstaller.install(home: home)
        #expect(!result.merge.created)
        #expect(result.merge.added.contains("Stop"))  // ours appended alongside
        #expect(result.backupPath != nil)
        // Backup preserves the original bytes.
        if let bp = result.backupPath {
            let backupData = try Data(contentsOf: URL(fileURLWithPath: bp))
            #expect(backupData == seedData)
        }

        // The new settings preserves the unrelated key + the user's custom hook.
        let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["model"] as? String == "claude-sonnet")
        let stopArr = (obj?["hooks"] as? [String: Any])?["Stop"] as? [Any]
        #expect(stopArr?.count == 2)
    }

    @Test func installRefusesMalformedSettings() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let settingsPath = AgentHooksInstaller.settingsPath(home: home)
        try FileManager.default.createDirectory(
            atPath: URL(fileURLWithPath: settingsPath)
                .deletingLastPathComponent().path,
            withIntermediateDirectories: true)
        let bad = "{ broken json"
        try Data(bad.utf8).write(to: URL(fileURLWithPath: settingsPath))

        #expect(throws: AgentHooksInstaller.InstallError.self) {
            _ = try AgentHooksInstaller.install(home: home)
        }
        // The malformed file is NOT overwritten.
        let after = try String(contentsOfFile: settingsPath, encoding: .utf8)
        #expect(after == bad)
    }
}
