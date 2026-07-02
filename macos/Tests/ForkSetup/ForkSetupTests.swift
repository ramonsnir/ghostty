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
            installedReloadIdentity: "1.3.0",
            currentReloadIdentity: "1.4.0",
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
            installedReloadIdentity: nil,
            currentReloadIdentity: "1.4.0",
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
            installedReloadIdentity: nil,
            currentReloadIdentity: "1.4.0",
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
            installedReloadIdentity: "1.4.0",
            currentReloadIdentity: "1.4.0",
            agentRunning: false,
            spec: spec(bundleID: "com.mitchellh.ghostty-ramon"))
        #expect(p == .skipExternallyManaged)
    }

    // MARK: - plan(): reload-identity gate (protocol version + epoch, NOT the binary hash)

    @Test func planUpToDateWhenOursAndIdentityMatches() {
        // THE FIX: a GUI-only update keeps the reload identity stable (same protocol
        // version + epoch) even though the host BINARY recompiled to a new cdhash. The
        // notarized host's LWCR is identity-pinned, so no bootout is needed and the
        // host's RAM-only sessions are preserved -> .upToDate.
        let p = ForkSetup.plan(
            bundledHostExists: true,
            existingPlistFileExists: true,
            existingPlistManagedBy: "com.mitchellh.ghostty-ramon",
            installedReloadIdentity: "1.4.0",
            currentReloadIdentity: "1.4.0",
            agentRunning: true,
            spec: spec())
        #expect(p == .upToDate)
    }

    @Test func planRevivesDeadHostWhenIdentityMatches() {
        // Recorded-current identity but NOT running (booted out / crash-looped / plist
        // half-removed): NON-destructively revive on relaunch (no bootout, since the
        // LWCR is still satisfied) instead of being stranded on .upToDate.
        let s = spec()
        let p = ForkSetup.plan(
            bundledHostExists: true,
            existingPlistFileExists: true,
            existingPlistManagedBy: "com.mitchellh.ghostty-ramon",
            installedReloadIdentity: "1.4.0",
            currentReloadIdentity: "1.4.0",
            agentRunning: false,
            spec: s)
        #expect(p == .revive(s))
    }

    @Test func planReloadsWhenProtocolMinorChangedEvenIfRunning() {
        // A real wire-protocol change (minor bump) means the running old host can't
        // serve the new GUI -> reload (bootout+bootstrap), even though it's up.
        let s = spec()
        let p = ForkSetup.plan(
            bundledHostExists: true,
            existingPlistFileExists: true,
            existingPlistManagedBy: "com.mitchellh.ghostty-ramon",
            installedReloadIdentity: "1.4.0",
            currentReloadIdentity: "1.5.0",
            agentRunning: true,
            spec: s)
        #expect(p == .reload(s))
    }

    @Test func planReloadsWhenEpochBumped() {
        // The manual override: same protocol version, but `host_reload_epoch` bumped
        // (a host-internal fix colleagues must actually run) -> reload.
        let s = spec()
        let p = ForkSetup.plan(
            bundledHostExists: true,
            existingPlistFileExists: true,
            existingPlistManagedBy: "com.mitchellh.ghostty-ramon",
            installedReloadIdentity: "1.4.0",
            currentReloadIdentity: "1.4.1",
            agentRunning: true,
            spec: s)
        #expect(p == .reload(s))
    }

    @Test func planAdoptsRunningHostWhenNoRecordedIdentity() {
        // The hash->identity UPGRADE transition (and lost-defaults): we own the plist,
        // never recorded an identity, but a healthy host is ALREADY running. Because the
        // LWCR is identity-pinned we must NOT bootout (that would kill its RAM-only
        // sessions) — adopt it (record the identity, no restart). This is the key
        // improvement over the old hash gate, which force-reloaded on this transition.
        let s = spec()
        let p = ForkSetup.plan(
            bundledHostExists: true,
            existingPlistFileExists: true,
            existingPlistManagedBy: "com.mitchellh.ghostty-ramon",
            installedReloadIdentity: nil,
            currentReloadIdentity: "1.4.0",
            agentRunning: true,
            spec: s)
        #expect(p == .adoptRunning(s))
    }

    @Test func planRevivesWhenNoRecordedIdentityAndNotRunning() {
        // No recorded identity AND the host isn't running -> non-destructive revive
        // (bootstrap, no bootout); there are no live sessions to lose, and no reload is
        // warranted (the LWCR is identity-pinned).
        let s = spec()
        let p = ForkSetup.plan(
            bundledHostExists: true,
            existingPlistFileExists: true,
            existingPlistManagedBy: "com.mitchellh.ghostty-ramon",
            installedReloadIdentity: nil,
            currentReloadIdentity: "1.4.0",
            agentRunning: false,
            spec: s)
        #expect(p == .revive(s))
    }

    @Test func decodeReloadIdentityUnpacksMajorMinorEpoch() {
        // (major << 32) | (minor << 16) | epoch, matching embedded.zig's packing.
        #expect(ForkSetup.decodeReloadIdentity((1 << 32) | (4 << 16) | 0) == "1.4.0")
        #expect(ForkSetup.decodeReloadIdentity((1 << 32) | (4 << 16) | 1) == "1.4.1")
        #expect(ForkSetup.decodeReloadIdentity((2 << 32) | (0 << 16) | 0) == "2.0.0")
        #expect(ForkSetup.decodeReloadIdentity(0) == "0.0.0")
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

    // MARK: - planShimInstall(): PATH shim install gate

    @Test func shimSkipsWhenNoBundledShim() {
        // Dev/local builds (incl. Ramon's locally-built Release) bundle no shim ->
        // must never overwrite a hand-installed ~/.local/bin/ghostty-mcp.
        #expect(ForkSetup.planShimInstall(
            bundledShimExists: false, installedShimExists: true,
            installedVersion: "1", bundleVersion: "2") == .skipNoBundledShim)
        // Even with nothing installed, no bundled shim still means do nothing.
        #expect(ForkSetup.planShimInstall(
            bundledShimExists: false, installedShimExists: false,
            installedVersion: nil, bundleVersion: "2") == .skipNoBundledShim)
    }

    @Test func shimInstallsOnCleanMachine() {
        // Bundled shim, nothing on PATH yet -> install.
        #expect(ForkSetup.planShimInstall(
            bundledShimExists: true, installedShimExists: false,
            installedVersion: nil, bundleVersion: "5") == .install)
    }

    @Test func shimUpToDateWhenPresentAndVersionMatches() {
        #expect(ForkSetup.planShimInstall(
            bundledShimExists: true, installedShimExists: true,
            installedVersion: "5", bundleVersion: "5") == .upToDate)
    }

    @Test func shimReinstallsOnVersionChange() {
        // A Sparkle update bumps CFBundleVersion -> ship the new shim.
        #expect(ForkSetup.planShimInstall(
            bundledShimExists: true, installedShimExists: true,
            installedVersion: "5", bundleVersion: "6") == .install)
    }

    @Test func shimReinstallsWhenFileMissingDespiteRecordedVersion() {
        // Recorded version matches but the colleague deleted the file -> reinstall.
        #expect(ForkSetup.planShimInstall(
            bundledShimExists: true, installedShimExists: false,
            installedVersion: "5", bundleVersion: "5") == .install)
    }

    // MARK: - planCLIInstall(): ghostty-ramon CLI launcher install gate

    @Test func cliSkipsWhenNoBundledBinary() {
        // Dev/local builds with no bundled multitool -> do nothing, even if a file
        // already occupies the PATH target.
        #expect(ForkSetup.planCLIInstall(
            bundledBinaryExists: false, installedFileExists: true, installedIsOurs: true,
            installedVersion: "1", bundleVersion: "2") == .skipNoBundledBinary)
        #expect(ForkSetup.planCLIInstall(
            bundledBinaryExists: false, installedFileExists: false, installedIsOurs: false,
            installedVersion: nil, bundleVersion: "2") == .skipNoBundledBinary)
    }

    @Test func cliInstallsOnCleanMachine() {
        // Bundled multitool, nothing on PATH yet -> install.
        #expect(ForkSetup.planCLIInstall(
            bundledBinaryExists: true, installedFileExists: false, installedIsOurs: false,
            installedVersion: nil, bundleVersion: "5") == .install)
    }

    @Test func cliUpToDateWhenOursAndVersionMatches() {
        #expect(ForkSetup.planCLIInstall(
            bundledBinaryExists: true, installedFileExists: true, installedIsOurs: true,
            installedVersion: "5", bundleVersion: "5") == .upToDate)
    }

    @Test func cliReinstallsOnVersionChange() {
        // A Sparkle update bumps CFBundleVersion / relocates the app -> re-point.
        #expect(ForkSetup.planCLIInstall(
            bundledBinaryExists: true, installedFileExists: true, installedIsOurs: true,
            installedVersion: "5", bundleVersion: "6") == .install)
    }

    @Test func cliReinstallsWhenFileMissingDespiteRecordedVersion() {
        // Recorded version matches but the colleague deleted the symlink -> reinstall.
        #expect(ForkSetup.planCLIInstall(
            bundledBinaryExists: true, installedFileExists: false, installedIsOurs: false,
            installedVersion: "5", bundleVersion: "5") == .install)
    }

    @Test func cliSkipsPreExistingNonManagedFile() {
        // SAFETY: a foreign file/symlink already at ~/.local/bin/ghostty-ramon (one
        // we did NOT create) must never be clobbered, even on a version mismatch.
        #expect(ForkSetup.planCLIInstall(
            bundledBinaryExists: true, installedFileExists: true, installedIsOurs: false,
            installedVersion: nil, bundleVersion: "5") == .skipExternallyManaged)
        // ...even if a stale recorded version happens to match the bundle version.
        #expect(ForkSetup.planCLIInstall(
            bundledBinaryExists: true, installedFileExists: true, installedIsOurs: false,
            installedVersion: "5", bundleVersion: "5") == .skipExternallyManaged)
    }

    // MARK: - shouldShowWelcome(): first-run welcome predicate

    @Test func welcomeShownOnFirstLaunch() {
        // Never recorded -> fire it exactly once.
        #expect(ForkSetup.shouldShowWelcome(alreadyShown: false) == true)
    }

    @Test func welcomeNeverShownAgain() {
        // Already recorded -> never fire again (idempotent).
        #expect(ForkSetup.shouldShowWelcome(alreadyShown: true) == false)
    }

    // MARK: - planMCPRegister(): Claude Code MCP registration

    @Test func mcpRegisterSkipsWhenAlreadyRecorded() {
        // A recorded success short-circuits before any probing — and wins even if
        // the other inputs would otherwise say "register".
        #expect(ForkSetup.planMCPRegister(
            alreadyRecorded: true, claudeFound: true, shimExists: true,
            alreadyRegistered: false) == .skipAlreadyRecorded)
    }

    @Test func mcpRegisterSkipsWhenNoClaude() {
        // No `claude` on PATH yet -> defer WITHOUT recording (retry next launch).
        #expect(ForkSetup.planMCPRegister(
            alreadyRecorded: false, claudeFound: false, shimExists: true,
            alreadyRegistered: false) == .skipNoClaude)
    }

    @Test func mcpRegisterSkipsWhenNoShim() {
        // claude present but the shim isn't installed yet -> defer (retry next launch).
        #expect(ForkSetup.planMCPRegister(
            alreadyRecorded: false, claudeFound: true, shimExists: false,
            alreadyRegistered: false) == .skipNoShim)
    }

    @Test func mcpRegisterSkipsWhenAlreadyRegistered() {
        // A pre-existing `ghostty` server is left strictly alone (never clobbered).
        #expect(ForkSetup.planMCPRegister(
            alreadyRecorded: false, claudeFound: true, shimExists: true,
            alreadyRegistered: true) == .skipAlreadyRegistered)
    }

    @Test func mcpRegisterRunsOnCleanMachine() {
        // claude + shim present, nothing registered yet -> register (user scope).
        #expect(ForkSetup.planMCPRegister(
            alreadyRecorded: false, claudeFound: true, shimExists: true,
            alreadyRegistered: false) == .register)
    }

    // MARK: - resolveClaude(): robust claude-CLI resolution

    @Test func claudeCandidatesIncludeCommonLocations() {
        let paths = ForkSetup.claudeCandidatePaths(home: "/Users/colleague")
        // The official native installer's location must be FIRST — that's the spot a
        // real colleague machine had when the login-shell probe whiffed (PATH only in
        // .zshrc). Homebrew + nix locations must also be covered.
        #expect(paths.first == "/Users/colleague/.local/bin/claude")
        #expect(paths.contains("/opt/homebrew/bin/claude"))
        #expect(paths.contains("/usr/local/bin/claude"))
        #expect(paths.contains("/Users/colleague/.claude/local/claude"))
    }

    @Test func firstExecutablePicksFirstMatchInOrder() {
        let paths = ForkSetup.claudeCandidatePaths(home: "/Users/c")
        // Only the Homebrew path "exists" -> it's chosen even though it's not first.
        let onlyBrew = ForkSetup.firstExecutablePath(paths) { $0 == "/opt/homebrew/bin/claude" }
        #expect(onlyBrew == "/opt/homebrew/bin/claude")
        // The native-installer path takes priority when BOTH it and brew "exist".
        let both = ForkSetup.firstExecutablePath(paths) {
            $0 == "/Users/c/.local/bin/claude" || $0 == "/opt/homebrew/bin/claude"
        }
        #expect(both == "/Users/c/.local/bin/claude")
    }

    @Test func firstExecutableNilWhenNoneExist() {
        #expect(ForkSetup.firstExecutablePath(["/a", "/b"]) { _ in false } == nil)
    }

    // MARK: - seed template: new onboarding content

    @Test func configSeedHasQuickStartAndCheatSheetPointer() throws {
        let seed = try #require(ForkSetup.configSeedContents(fileExists: false, home: "/Users/colleague"))
        // The top-of-file quick start must point at the concrete cheat sheet, NOT
        // tell the colleague to browse the command palette.
        #expect(seed.contains("QUICK START"))
        #expect(seed.contains("ghostty-ramon +list-keybinds"))
        #expect(seed.contains("ONBOARDING.md"))
    }

    @Test func configSeedAgentQueueCommentedOptIn() throws {
        let seed = try #require(ForkSetup.configSeedContents(fileExists: false, home: "/Users/colleague"))
        // agent-queue must be present (reconciling the example drift) but COMMENTED
        // out — never enabled by default.
        #expect(seed.contains("#agent-queue = true"))
        for line in seed.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            #expect(!(t.hasPrefix("agent-queue") && !t.hasPrefix("#")))
        }
    }

    @Test func configSeedFocusedBellIsVisualOnly() throws {
        let seed = try #require(ForkSetup.configSeedContents(fileExists: false, home: "/Users/colleague"))
        // The focused bell must NOT beep (no audible `system`); it is visual-only.
        #expect(seed.contains("bell-features-focused = no-system,no-attention,no-title"))
    }

    @Test func configSeedProjectDirectoryCommentedOut() throws {
        let seed = try #require(ForkSetup.configSeedContents(fileExists: false, home: "/Users/colleague"))
        // project-directory must be commented out (so an unconfigured colleague
        // doesn't get a half-empty ctrl+a>f palette) — but the project selector
        // keybind (now a COMMENTED example) + the explanatory comment stay.
        for line in seed.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            #expect(!(t.hasPrefix("project-directory") && !t.hasPrefix("#")))
        }
        #expect(seed.contains("#project-directory = ~/git"))
        // The whole ctrl+a layer (incl. this keybind) is commented out now: the
        // project-selector keybind appears ONLY as a commented example.
        #expect(seed.contains("#keybind = ctrl+a>f=toggle_project_selector"))
    }

    @Test func configSeedHasNoActiveKeybindsButHasCommentedCtrlALayer() throws {
        let seed = try #require(ForkSetup.configSeedContents(fileExists: false, home: "/Users/colleague"))
        // No ACTIVE keybind lines: every `keybind = ` is commented with a leading
        // `#` (the whole personal ctrl+a layer is offered as an example, not imposed).
        for line in seed.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            #expect(!(t.hasPrefix("keybind") && !t.hasPrefix("#")))
        }
        // But the commented ctrl+a prefix layer IS present, under a header marking
        // it optional, so a colleague can adopt it.
        #expect(seed.contains("#keybind = ctrl+a>"))
        #expect(seed.contains("OPTIONAL"))
    }

    @Test func configSeedHasSpotlightSettingAndCommentedKeybind() throws {
        let seed = try #require(ForkSetup.configSeedContents(fileExists: false, home: "/Users/colleague"))
        // The tile-top-pin duration is an ACTIVE setting (like agent-dashboard itself).
        #expect(seed.contains("agent-dashboard-spotlight-seconds = 10"))
        // The pin keybind is offered COMMENTED (opt-in), and uses shift+p (ctrl+a>p is
        // previous_tab), so it must not be an active `keybind = ` line.
        #expect(seed.contains("#keybind = ctrl+a>shift+p=spotlight_dashboard_split"))
    }

    // MARK: - local secrets: planLocalSecretsInstall + token generation

    @Test func localSecretsCreatesWhenFileAbsent() {
        // No `local` file yet -> create it (with both lines + a header).
        #expect(ForkSetup.planLocalSecretsInstall(localExists: false, hasToken: false) == .create)
        // localExists is the dominant gate: absent always means create.
        #expect(ForkSetup.planLocalSecretsInstall(localExists: false, hasToken: true) == .create)
    }

    @Test func localSecretsSkipsWhenTokenPresent() {
        // SAFETY: a live shell-execution credential is NEVER rotated by a re-run.
        #expect(ForkSetup.planLocalSecretsInstall(localExists: true, hasToken: true) == .skipHasToken)
    }

    @Test func localSecretsAppendsWhenFileExistsWithoutToken() {
        // An existing file (e.g. with web-monitor-listen) but no mcp-token -> append.
        #expect(ForkSetup.planLocalSecretsInstall(localExists: true, hasToken: false) == .append)
    }

    @Test func localHasMCPTokenDetectsActiveLineOnly() {
        // An active token line counts...
        #expect(ForkSetup.localHasMCPToken("mcp-token = abc123") == true)
        #expect(ForkSetup.localHasMCPToken("  mcp-token=abc123  ") == true)
        #expect(ForkSetup.localHasMCPToken("web-monitor-listen = 100.0.0.1:8787\nmcp-token = deadbeef") == true)
        // ...a commented example does NOT (so the seed's `#mcp-token` never blocks us).
        #expect(ForkSetup.localHasMCPToken("#mcp-token = <generate...>") == false)
        #expect(ForkSetup.localHasMCPToken("# mcp-token = x") == false)
        // ...and an empty / unrelated file does not.
        #expect(ForkSetup.localHasMCPToken("") == false)
        #expect(ForkSetup.localHasMCPToken("web-monitor-listen = 100.0.0.1:8787") == false)
        // A key that merely starts with the same prefix must not match.
        #expect(ForkSetup.localHasMCPToken("mcp-token-extra = x") == false)
    }

    @Test func generateMCPTokenIsRandomLongHex() {
        let a = ForkSetup.generateMCPToken()
        let b = ForkSetup.generateMCPToken()
        // Sufficiently long: >= 48 hex chars (the spec floor); default is 32 bytes
        // -> 64 hex chars.
        #expect(a.count >= 48)
        #expect(a.count == 64)
        // Pure lowercase hex.
        #expect(a.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        // Real CSPRNG output -> two draws differ (never a constant).
        #expect(a != b)
    }

    @Test func localSecretsBlocksCarryListenAndToken() {
        let token = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        let create = ForkSetup.localSecretsFileContents(token: token)
        // The created file carries a machine-local-secrets header + both lines, and
        // localHasMCPToken recognizes its own output (idempotency closes the loop).
        #expect(create.contains("mcp-listen = 127.0.0.1:8765"))
        #expect(create.contains("mcp-token = \(token)"))
        #expect(ForkSetup.localHasMCPToken(create) == true)

        let block = ForkSetup.localSecretsAppendBlock(token: token)
        #expect(block.contains("mcp-listen = 127.0.0.1:8765"))
        #expect(block.contains("mcp-token = \(token)"))
        #expect(ForkSetup.localHasMCPToken(block) == true)
    }
}
