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

    // MARK: - plan(): the safety-critical state machine (two-identity gate)

    // Convenience wrapper over the (now two-identity) planner. Defaults model the
    // common "our plist, bundled host present" case; each test overrides what it
    // exercises. `spec()` is deterministic, so a fresh one compares equal (Equatable)
    // to the one plan() carries in .install/.reload/etc.
    private func plan(
        supInstalled: String?, sup: String,
        workerInstalled: String?, worker: String,
        running: Bool,
        bundledHost: Bool = true,
        plistExists: Bool = true,
        managedBy: String? = "com.mitchellh.ghostty-ramon",
        // Defaults to a supervisor plist (the steady state); the plain-host → supervisor
        // migration cases pass `runsSupervisor: false`. Only consulted in the
        // no-recorded-supervisor-identity branch.
        runsSupervisor: Bool = true
    ) -> ForkSetup.Plan {
        ForkSetup.plan(
            bundledHostExists: bundledHost,
            existingPlistFileExists: plistExists,
            existingPlistManagedBy: managedBy,
            existingPlistRunsSupervisor: runsSupervisor,
            installedSupervisorIdentity: supInstalled,
            currentSupervisorIdentity: sup,
            installedWorkerIdentity: workerInstalled,
            currentWorkerIdentity: worker,
            agentRunning: running,
            spec: spec())
    }

    @Test func planSkipsWhenNoBundledHost() {
        // Dev/local builds (incl. Ramon's locally-built Release) have no bundled
        // host -> we must never run launchctl. This is the primary safety gate.
        #expect(plan(supInstalled: "1", sup: "2", workerInstalled: "3.0", worker: "4.0",
                     running: false, bundledHost: false) == .skipNoBundledHost)
    }

    @Test func planInstallsOnCleanMachine() {
        // No plist present + a bundled host -> fresh install.
        #expect(plan(supInstalled: nil, sup: "1", workerInstalled: nil, worker: "4.0",
                     running: false, plistExists: false, managedBy: nil) == .install(spec()))
    }

    @Test func planSkipsExternallyManagedPlist() {
        // A plist exists with NO ownership marker (Ramon's hand-rolled agent, or
        // any third party) -> leave it strictly alone, even with a bundled host.
        // Even if something is running, not ours -> skip.
        #expect(plan(supInstalled: nil, sup: "1", workerInstalled: nil, worker: "4.0",
                     running: true, managedBy: nil) == .skipExternallyManaged)
    }

    @Test func planSkipsPlistManagedByDifferentBundle() {
        // A marker that isn't OURS (e.g. a different fork identity) is still
        // treated as "not ours" -> skip.
        #expect(plan(supInstalled: "1", sup: "1", workerInstalled: "4.0", worker: "4.0",
                     running: false, managedBy: "com.mitchellh.ghostty-ramon.debug")
                == .skipExternallyManaged)
    }

    // MARK: - plan(): two-identity reload gate (supervisor vs worker)

    @Test func planUpToDateWhenBothIdentitiesMatch() {
        // A GUI-only update keeps BOTH identities stable (same protocol major/minor +
        // epoch) even though the host BINARY recompiled to a new cdhash -> .upToDate,
        // no bootout, sessions preserved.
        #expect(plan(supInstalled: "1", sup: "1", workerInstalled: "4.0", worker: "4.0",
                     running: true) == .upToDate)
    }

    @Test func planRevivesDeadHostWhenBothIdentitiesMatch() {
        // Both recorded-current but NOT running (booted out / crash-looped / plist
        // half-removed): NON-destructively revive on relaunch (no bootout) instead of
        // being stranded on .upToDate.
        #expect(plan(supInstalled: "1", sup: "1", workerInstalled: "4.0", worker: "4.0",
                     running: false) == .revive(spec()))
    }

    @Test func planHandsOffWorkerWhenWorkerMinorChangedAndRunning() {
        // THE SPLIT: a protocol-MINOR bump changes ONLY the worker identity (supervisor
        // unchanged). With a RUNNING supervisor this is a NON-destructive worker handoff
        // (SIGHUP), NOT a bootout -> .handoffWorker; sessions survive.
        #expect(plan(supInstalled: "1", sup: "1", workerInstalled: "4.0", worker: "5.0",
                     running: true) == .handoffWorker(spec()))
    }

    @Test func planHandsOffWorkerWhenEpochBumpedAndRunning() {
        // Same protocol version, but `host_reload_epoch` bumped -> the epoch lives in
        // the WORKER identity, so a running supervisor is SIGHUP-handed-off (common
        // host-internal fix delivered without killing sessions) -> .handoffWorker.
        #expect(plan(supInstalled: "1", sup: "1", workerInstalled: "4.0", worker: "4.1",
                     running: true) == .handoffWorker(spec()))
    }

    @Test func planRevivesWhenWorkerChangedButNotRunning() {
        // Worker identity changed but no supervisor is running -> nothing to SIGHUP;
        // revive brings the supervisor up (it then spawns a fresh worker at the current
        // build). No bootout, and there are no live sessions to lose.
        #expect(plan(supInstalled: "1", sup: "1", workerInstalled: "4.0", worker: "5.0",
                     running: false) == .revive(spec()))
    }

    @Test func planReloadsWhenSupervisorIdentityChangedAndRunning() {
        // A SUPERVISOR-identity change (first cut: a protocol MAJOR bump) means the
        // supervisor binary / its launchd contract changed -> the RARE destructive
        // bootout+bootstrap so launchd re-derives the LWCR, even though it's up.
        #expect(plan(supInstalled: "1", sup: "2", workerInstalled: "4.0", worker: "0.0",
                     running: true) == .reload(spec()))
    }

    @Test func planReloadsWhenSupervisorChangedEvenIfNotRunning() {
        // Supervisor identity changed and the host is down: still .reload (bootout is a
        // harmless no-op on a dead job; bootstrap brings up the new supervisor binary).
        #expect(plan(supInstalled: "1", sup: "2", workerInstalled: "4.0", worker: "0.0",
                     running: false) == .reload(spec()))
    }

    @Test func planReloadDominatesWhenBothIdentitiesChangedAndRunning() {
        // Supervisor AND worker both changed at once -> the supervisor reload dominates
        // (a fresh supervisor re-establishes the whole job); no partial worker handoff.
        #expect(plan(supInstalled: "1", sup: "2", workerInstalled: "4.0", worker: "5.1",
                     running: true) == .reload(spec()))
    }

    @Test func planAdoptsRunningSupervisorWhenNoRecordedIdentityAndPlistIsSupervisor() {
        // Lost-defaults recovery for a GENUINE supervisor: we own the plist, it ALREADY
        // runs `--supervise`, a healthy supervisor is running, but the identity record
        // was wiped. Because the LWCR is identity-pinned we must NOT bootout (that would
        // kill its RAM-only sessions) -> adopt it (record both identities, no restart).
        #expect(plan(supInstalled: nil, sup: "1", workerInstalled: nil, worker: "4.0",
                     running: true, runsSupervisor: true) == .adoptRunning(spec()))
    }

    @Test func planReloadsWhenNoRecordedIdentityAndExistingPlistIsPlainHostAndRunning() {
        // THE MIGRATION FIX: an old (pre-supervisor) build wrote a PLAIN `--listen` plist
        // + only the single-key identity, so both new identity keys are absent AND the
        // plist has no `--supervise`. A plain host is running. This is the ONE-TIME
        // plain-host -> supervisor switchover -> `.reload` (bootout the plain host,
        // bootstrap the supervisor). Adopting here would leave a plain host under a
        // supervisor plist and a later `.handoffWorker` would SIGHUP-KILL it.
        #expect(plan(supInstalled: nil, sup: "1", workerInstalled: nil, worker: "4.0",
                     running: true, runsSupervisor: false) == .reload(spec()))
    }

    @Test func planRevivesWhenNoRecordedIdentityAndPlainPlistNotRunning() {
        // Plain pre-supervisor plist, no recorded identity, but nothing is running ->
        // nothing to lose, so bring the supervisor up NON-DESTRUCTIVELY (`.revive`,
        // bootout:false) rather than a destructive reload.
        #expect(plan(supInstalled: nil, sup: "1", workerInstalled: nil, worker: "4.0",
                     running: false, runsSupervisor: false) == .revive(spec()))
    }

    @Test func planRevivesWhenNoRecordedIdentityAndSupervisorPlistNotRunning() {
        // No recorded identity, the plist ALREADY runs `--supervise`, but the supervisor
        // isn't running -> non-destructive revive (bootstrap, no bootout); no live
        // sessions to lose.
        #expect(plan(supInstalled: nil, sup: "1", workerInstalled: nil, worker: "4.0",
                     running: false, runsSupervisor: true) == .revive(spec()))
    }

    // MARK: - plistRunsSupervisor(): supervisor-vs-plain-host discrimination

    @Test func plistRunsSupervisorDetectsSuperviseFlag() {
        // The supervisor plist's args carry `--supervise`; a plain pre-supervisor host's
        // don't. nil/empty/plain all read as "not a supervisor".
        #expect(ForkSetup.plistRunsSupervisor(
            ["/A/Contents/MacOS/ghostty-host", "--supervise", "--listen=/x"]) == true)
        #expect(ForkSetup.plistRunsSupervisor(
            ["/A/Contents/MacOS/ghostty-host", "--listen=/x"]) == false)
        #expect(ForkSetup.plistRunsSupervisor(["/A/Contents/MacOS/ghostty-host"]) == false)
        #expect(ForkSetup.plistRunsSupervisor([]) == false)
        #expect(ForkSetup.plistRunsSupervisor(nil) == false)
    }

    @Test func planTreatsNilWorkerWithMatchingSupervisorAsUpToDate() {
        // Defensive/impossible state (we always record both together): supervisor
        // recorded + matching, worker identity NOT recorded -> up-to-date when running
        // (never a spurious handoff), revive when down.
        #expect(plan(supInstalled: "1", sup: "1", workerInstalled: nil, worker: "4.0",
                     running: true) == .upToDate)
        #expect(plan(supInstalled: "1", sup: "1", workerInstalled: nil, worker: "4.0",
                     running: false) == .revive(spec()))
    }

    @Test func decodeReloadIdentityUnpacksMajorMinorEpoch() {
        // (major << 32) | (minor << 16) | epoch, matching embedded.zig's packing.
        #expect(ForkSetup.decodeReloadIdentity((1 << 32) | (4 << 16) | 0) == "1.4.0")
        #expect(ForkSetup.decodeReloadIdentity((1 << 32) | (4 << 16) | 1) == "1.4.1")
        #expect(ForkSetup.decodeReloadIdentity((2 << 32) | (0 << 16) | 0) == "2.0.0")
        #expect(ForkSetup.decodeReloadIdentity(0) == "0.0.0")
    }

    @Test func decodeReloadIdentitiesCarvesSupervisorMajorAndWorkerMinorEpoch() {
        // FIRST-CUT SPLIT: supervisor = protocol MAJOR (rare -> destructive reload);
        // worker = protocol MINOR + host_reload_epoch (common -> SIGHUP handoff). Both
        // decoded from the SAME packed value as decodeReloadIdentity (no new C export).
        let a = ForkSetup.decodeReloadIdentities((1 << 32) | (4 << 16) | 0)
        #expect(a.supervisor == "1")
        #expect(a.worker == "4.0")
        // A MINOR bump moves the WORKER identity, supervisor unchanged.
        let b = ForkSetup.decodeReloadIdentities((1 << 32) | (5 << 16) | 0)
        #expect(b.supervisor == "1")   // same supervisor -> handoff, not reload
        #expect(b.worker == "5.0")
        // An EPOCH bump moves the WORKER identity, supervisor unchanged.
        let c = ForkSetup.decodeReloadIdentities((1 << 32) | (4 << 16) | 1)
        #expect(c.supervisor == "1")
        #expect(c.worker == "4.1")
        // A MAJOR bump moves the SUPERVISOR identity -> destructive reload.
        let d = ForkSetup.decodeReloadIdentities((2 << 32) | (0 << 16) | 0)
        #expect(d.supervisor == "2")
        #expect(d.worker == "0.0")
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
        // (ramon fork / host-handoff) The launchd job now runs the SUPERVISOR.
        let args = dict["ProgramArguments"] as? [String]
        #expect(args == [
            "/Applications/Ghostty (ramon).app/Contents/MacOS/ghostty-host",
            "--supervise",
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

    @Test func readPlistExtractsSupervisorProgramArgumentsEndToEnd() throws {
        // Round-trip: our own written plist -> readPlist surfaces the marker AND the
        // ProgramArguments, and plistRunsSupervisor recognizes its own `--supervise`.
        // This closes the migration loop (a plist WE wrote is a supervisor plist).
        let path = NSTemporaryDirectory() + "ghostty-forksetup-args-\(UUID().uuidString).plist"
        try spec().plistData().write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }
        let (exists, managedBy, args) = ForkSetup.readPlist(plistPath: path, fileManager: .default)
        #expect(exists == true)
        #expect(managedBy == "com.mitchellh.ghostty-ramon")
        #expect(args?.contains("--supervise") == true)
        #expect(ForkSetup.plistRunsSupervisor(args) == true)
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
