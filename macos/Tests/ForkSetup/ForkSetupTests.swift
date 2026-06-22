import Foundation
import Testing
@testable import Ghostty

/// Unit tests for the pure decision units of the fork-only first-launch setup:
/// the host-LaunchAgent `plan(...)` state machine (whose safety rules protect a
/// hand-managed host from being clobbered), the LaunchAgent plist shape, the
/// config-seed gating, and the ownership-marker reader.
struct ForkSetupTests {

    // A representative spec used across the planner tests.
    private func spec(bundleID: String = "com.mitchellh.ghostty-ramon") -> ForkSetup.LaunchAgentSpec {
        ForkSetup.makeSpec(
            bundleURL: URL(fileURLWithPath: "/Applications/Ghostty (ramon).app"),
            bundleID: bundleID,
            home: "/Users/colleague")
    }

    // MARK: - plan(): the safety-critical state machine

    @Test func planSkipsWhenNoBundledHost() {
        // Dev/local builds (incl. Ramon's locally-built Release) have no bundled
        // host -> we must never run launchctl. This is the primary safety gate.
        let p = ForkSetup.plan(
            bundledHostExists: false,
            existingPlistFileExists: true,
            existingPlistManagedBy: "com.mitchellh.ghostty-ramon",
            installedVersion: "1",
            bundleVersion: "2",
            agentRunning: false,
            spec: spec())
        #expect(p == .skipNoBundledHost)
    }

    @Test func planInstallsOnCleanMachine() {
        // No plist present + a bundled host -> fresh install.
        let s = spec()
        let p = ForkSetup.plan(
            bundledHostExists: true,
            existingPlistFileExists: false,
            existingPlistManagedBy: nil,
            installedVersion: nil,
            bundleVersion: "100",
            agentRunning: false,
            spec: s)
        #expect(p == .install(s))
    }

    @Test func planSkipsExternallyManagedPlist() {
        // A plist exists with NO ownership marker (Ramon's hand-rolled agent, or
        // any third party) -> leave it strictly alone, even with a bundled host.
        let p = ForkSetup.plan(
            bundledHostExists: true,
            existingPlistFileExists: true,
            existingPlistManagedBy: nil,
            installedVersion: nil,
            bundleVersion: "100",
            agentRunning: true,   // even if something is running, not ours -> skip
            spec: spec())
        #expect(p == .skipExternallyManaged)
    }

    @Test func planSkipsPlistManagedByDifferentBundle() {
        // A marker that isn't OURS (e.g. a different fork identity) is still
        // treated as "not ours" -> skip.
        let p = ForkSetup.plan(
            bundledHostExists: true,
            existingPlistFileExists: true,
            existingPlistManagedBy: "com.mitchellh.ghostty-ramon.debug",
            installedVersion: "100",
            bundleVersion: "100",
            agentRunning: false,
            spec: spec(bundleID: "com.mitchellh.ghostty-ramon"))
        #expect(p == .skipExternallyManaged)
    }

    @Test func planUpToDateWhenOursAndVersionMatches() {
        let p = ForkSetup.plan(
            bundledHostExists: true,
            existingPlistFileExists: true,
            existingPlistManagedBy: "com.mitchellh.ghostty-ramon",
            installedVersion: "100",
            bundleVersion: "100",
            agentRunning: true,
            spec: spec())
        #expect(p == .upToDate)
    }

    @Test func planReloadsOursWhenVersionChangedEvenIfRunning() {
        // The LWCR gotcha: a new bundle version means a new host cdhash, so we must
        // reload (bootout+bootstrap) to re-derive launchd's requirement — even
        // though the OLD host is still running (that's exactly the update case).
        let s = spec()
        let p = ForkSetup.plan(
            bundledHostExists: true,
            existingPlistFileExists: true,
            existingPlistManagedBy: "com.mitchellh.ghostty-ramon",
            installedVersion: "100",
            bundleVersion: "101",
            agentRunning: true,
            spec: s)
        #expect(p == .reload(s))
    }

    @Test func planAdoptsRunningHostWhenNoRecordedVersion() {
        // SAFETY: we own the plist, never recorded a version (lost/cleared
        // UserDefaults), but a healthy host is ALREADY running. We must NOT bootout
        // (that would kill its RAM-only sessions) — adopt it instead.
        let s = spec()
        let p = ForkSetup.plan(
            bundledHostExists: true,
            existingPlistFileExists: true,
            existingPlistManagedBy: "com.mitchellh.ghostty-ramon",
            installedVersion: nil,
            bundleVersion: "100",
            agentRunning: true,
            spec: s)
        #expect(p == .adoptRunning(s))
    }

    @Test func planReloadsWhenNoRecordedVersionAndNotRunning() {
        // No recorded version AND the host isn't running -> safe to (re)bootstrap;
        // there are no live sessions to lose.
        let s = spec()
        let p = ForkSetup.plan(
            bundledHostExists: true,
            existingPlistFileExists: true,
            existingPlistManagedBy: "com.mitchellh.ghostty-ramon",
            installedVersion: nil,
            bundleVersion: "100",
            agentRunning: false,
            spec: s)
        #expect(p == .reload(s))
    }

    // MARK: - LaunchAgentSpec shape

    @Test func specDerivesPathsFromBundle() {
        let s = spec()
        #expect(s.label == "com.mitchellh.ghostty-ramon.host")
        #expect(s.managingBundleID == "com.mitchellh.ghostty-ramon")
        #expect(s.hostBinaryPath == "/Applications/Ghostty (ramon).app/Contents/MacOS/ghostty-host")
        #expect(s.resourcesDir == "/Applications/Ghostty (ramon).app/Contents/Resources/ghostty")
        #expect(s.socketPath == "/Users/colleague/.ghostty-ramon-host.sock")
        #expect(s.logPath == "/Users/colleague/Library/Logs/ghostty-ramon-host.log")
    }

    @Test func labelDerivesFromBundleID() {
        #expect(ForkSetup.launchAgentLabel(bundleID: "com.mitchellh.ghostty-ramon")
                == "com.mitchellh.ghostty-ramon.host")
        #expect(ForkSetup.launchAgentLabel(bundleID: "com.mitchellh.ghostty-ramon.debug")
                == "com.mitchellh.ghostty-ramon.debug.host")
    }

    @Test func plistDictionaryHasRequiredKeysAndMarker() {
        let dict = spec().plistDictionary
        #expect(dict["Label"] as? String == "com.mitchellh.ghostty-ramon.host")
        // The ownership marker is what makes future reloads safe.
        #expect(dict[ForkSetup.managedKey] as? String == "com.mitchellh.ghostty-ramon")
        #expect(dict["RunAtLoad"] as? Bool == true)
        #expect(dict["KeepAlive"] as? Bool == true)
        #expect(dict["ProcessType"] as? String == "Interactive")
        let args = dict["ProgramArguments"] as? [String]
        #expect(args == [
            "/Applications/Ghostty (ramon).app/Contents/MacOS/ghostty-host",
            "--listen=/Users/colleague/.ghostty-ramon-host.sock",
        ])
        let env = dict["EnvironmentVariables"] as? [String: String]
        #expect(env?["GHOSTTY_RESOURCES_DIR"]
                == "/Applications/Ghostty (ramon).app/Contents/Resources/ghostty")
    }

    @Test func plistDataRoundTripsAndCarriesMarker() throws {
        // plistData() must produce a parseable plist that still carries the marker,
        // so a later launch's readPlistMarker recognizes it as ours.
        let data = spec().plistData()
        let obj = try PropertyListSerialization.propertyList(from: data, format: nil)
        let dict = try #require(obj as? [String: Any])
        #expect(dict[ForkSetup.managedKey] as? String == "com.mitchellh.ghostty-ramon")
        #expect(dict["Label"] as? String == "com.mitchellh.ghostty-ramon.host")
    }

    // MARK: - readPlistMarker (ownership detection, IO via temp files)

    @Test func readPlistMarkerReportsAbsentFile() {
        let path = NSTemporaryDirectory() + "ghostty-forksetup-missing-\(UUID().uuidString).plist"
        let (exists, managedBy) = ForkSetup.readPlistMarker(plistPath: path, fileManager: .default)
        #expect(exists == false)
        #expect(managedBy == nil)
    }

    @Test func readPlistMarkerReadsOurMarker() throws {
        let path = NSTemporaryDirectory() + "ghostty-forksetup-ours-\(UUID().uuidString).plist"
        try spec().plistData().write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }
        let (exists, managedBy) = ForkSetup.readPlistMarker(plistPath: path, fileManager: .default)
        #expect(exists == true)
        #expect(managedBy == "com.mitchellh.ghostty-ramon")
    }

    @Test func readPlistMarkerTreatsUnmarkedPlistAsNotOurs() throws {
        // Simulate Ramon's hand-rolled plist (valid plist, no marker key).
        let path = NSTemporaryDirectory() + "ghostty-forksetup-external-\(UUID().uuidString).plist"
        let external: [String: Any] = [
            "Label": "com.mitchellh.ghostty-ramon.host",
            "ProgramArguments": ["/Users/ramon/.local/bin/ghostty-host", "--listen=/x"],
            "KeepAlive": true,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: external, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }
        let (exists, managedBy) = ForkSetup.readPlistMarker(plistPath: path, fileManager: .default)
        #expect(exists == true)
        #expect(managedBy == nil)
    }

    @Test func readPlistMarkerTreatsGarbageAsNotOurs() throws {
        let path = NSTemporaryDirectory() + "ghostty-forksetup-garbage-\(UUID().uuidString).plist"
        try Data("not a plist".utf8).write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }
        let (exists, managedBy) = ForkSetup.readPlistMarker(plistPath: path, fileManager: .default)
        #expect(exists == true)        // present...
        #expect(managedBy == nil)      // ...but unreadable -> not ours -> don't touch
    }

    // MARK: - config seed gating + substitution

    @Test func configSeedSkippedWhenFileExists() {
        #expect(ForkSetup.configSeedContents(fileExists: true, home: "/Users/colleague") == nil)
    }

    @Test func configSeedSubstitutesHomeIntoSocketPath() throws {
        let seed = try #require(ForkSetup.configSeedContents(fileExists: false, home: "/Users/colleague"))
        // The pty-host socket must be an absolute path under the real home.
        #expect(seed.contains("pty-host = /Users/colleague/.ghostty-ramon-host.sock"))
        // The placeholder must be fully substituted.
        #expect(!seed.contains("__HOME__"))
    }

    @Test func configSeedHasNoSecretsOrPersonalPaths() throws {
        let seed = try #require(ForkSetup.configSeedContents(fileExists: false, home: "/Users/colleague"))
        // Sanitization invariants: no other user's home, no live secrets, and the
        // open shell-exec MCP server is NOT enabled by default.
        #expect(!seed.contains("/Users/ramon"))
        #expect(!seed.contains("ExampleOS"))
        #expect(!seed.contains("acme-foods"))
        // mcp-listen / web-monitor-listen must be commented out (opt-in via `local`).
        for line in seed.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            #expect(!(t.hasPrefix("mcp-listen") && !t.hasPrefix("#")))
            #expect(!(t.hasPrefix("web-monitor-listen") && !t.hasPrefix("#")))
        }
        // It must still pull in the untracked local include + enable the agent dashboard
        // + enable fork auto-update checks.
        #expect(seed.contains("config-file = ?~/.config/ghostty-ramon/local"))
        #expect(seed.contains("agent-dashboard = true"))
        #expect(seed.contains("auto-update = check"))
    }
}
