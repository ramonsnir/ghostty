import Foundation
import OSLog
import UserNotifications

/// (ramon fork) First-launch setup for COLLEAGUE distribution builds.
///
/// Two independent, idempotent jobs, safe to run on every launch:
///
///   1. **Config seed** — write a sanitized default `~/.config/ghostty-ramon/config`
///      if (and only if) the file is absent, so the fork's keybinds/features work
///      out of the box on a fresh machine. We never overwrite an existing config.
///
///   2. **Host LaunchAgent** — install (and version-reload) a launchd user
///      LaunchAgent that supervises the `ghostty-host` binary BUNDLED inside the
///      app (`Contents/MacOS/ghostty-host`), so the pty-host backend works with no
///      manual terminal setup. The agent is `RunAtLoad`+`KeepAlive`, exactly like
///      the hand-rolled one documented in CLAUDE.md.
///
/// ── CRITICAL SAFETY ───────────────────────────────────────────────────────────
/// This must NEVER disturb a host LaunchAgent that a developer manages by hand
/// (Ramon's own dev setup uses the SAME label `com.mitchellh.ghostty-ramon.host`
/// pointing at `~/.local/bin/ghostty-host`). Two guards make that impossible:
///
///   * We only manage the agent when a `ghostty-host` is actually bundled in the
///     app. Local dev builds (ReleaseLocal/Debug, and Ramon's locally-built
///     Release) do NOT bundle the host — only the CI release workflow copies it
///     in — so on Ramon's machine this code takes the `.skipNoBundledHost` path
///     and never runs `launchctl` at all.
///
///   * Any plist WE write carries an ownership marker (`GhosttyAppManaged` = our
///     bundle id). We refuse to touch a pre-existing plist that lacks our marker
///     (`.skipExternallyManaged`), so even if a future build DID bundle the host,
///     a hand-managed plist is left strictly alone.
///
/// The LWCR gotcha (CLAUDE.md): a bundled host gets a NEW code identity (cdhash)
/// on every release, so after a Sparkle update we must `bootout`+`bootstrap`
/// (never `kill`) to make launchd re-derive its launch requirement. That is the
/// `.reload` path, triggered when the recorded install version != the running
/// bundle version.
enum ForkSetup {
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty-ramon",
        category: "fork-setup")

    /// UserDefaults key: the CFBundleVersion the host LaunchAgent was last
    /// (successfully) installed/reloaded for. Drives version-aware reload.
    static let kInstalledHostVersion = "forkSetup.hostLaunchAgentVersion"

    /// Top-level plist key marking a LaunchAgent plist as written by this app.
    /// Value is the managing bundle id. launchd ignores unknown keys.
    static let managedKey = "GhosttyAppManaged"

    // MARK: - Config seed (pure)

    /// The bytes to seed into `~/.config/ghostty-ramon/config`, or nil if seeding
    /// should be skipped because the file already exists. `home` replaces the
    /// `__HOME__` placeholder in the pty-host socket path (launchd/the apprt need
    /// an absolute path; `~` is not expanded inside the socket value here).
    static func configSeedContents(fileExists: Bool, home: String) -> String? {
        guard !fileExists else { return nil }
        return seedTemplate.replacingOccurrences(of: "__HOME__", with: home)
    }

    // MARK: - Host LaunchAgent (pure)

    /// The launchd label for the app-managed host agent, derived from the bundle
    /// id so each fork identity gets its own (Release → `…ghostty-ramon.host`).
    static func launchAgentLabel(bundleID: String) -> String {
        "\(bundleID).host"
    }

    /// A fully-resolved LaunchAgent definition. All fields are absolute paths
    /// (launchd does not expand `~` or env vars in ProgramArguments).
    struct LaunchAgentSpec: Equatable {
        let label: String
        let managingBundleID: String
        let hostBinaryPath: String
        let socketPath: String
        let resourcesDir: String
        let logPath: String

        var plistDictionary: [String: Any] {
            [
                "Label": label,
                ForkSetup.managedKey: managingBundleID,
                "ProgramArguments": [hostBinaryPath, "--listen=\(socketPath)"],
                "EnvironmentVariables": ["GHOSTTY_RESOURCES_DIR": resourcesDir],
                "RunAtLoad": true,
                "KeepAlive": true,
                "ProcessType": "Interactive",
                "StandardOutPath": logPath,
                "StandardErrorPath": logPath,
            ]
        }

        /// Serialized XML plist bytes. Force-unwrap is safe: the dictionary
        /// contains only plist-legal value types (String/Bool/[String]/[String:String]).
        func plistData() -> Data {
            try! PropertyListSerialization.data(
                fromPropertyList: plistDictionary, format: .xml, options: 0)
        }
    }

    /// Build the spec from the running bundle. The host lives at
    /// `Contents/MacOS/ghostty-host`; resources at `Contents/Resources/ghostty`.
    /// Socket + log paths follow the fork convention under `home`.
    static func makeSpec(bundleURL: URL, bundleID: String, home: String) -> LaunchAgentSpec {
        LaunchAgentSpec(
            label: launchAgentLabel(bundleID: bundleID),
            managingBundleID: bundleID,
            hostBinaryPath: bundleURL.appendingPathComponent("Contents/MacOS/ghostty-host").path,
            socketPath: "\(home)/.ghostty-ramon-host.sock",
            resourcesDir: bundleURL.appendingPathComponent("Contents/Resources/ghostty").path,
            logPath: "\(home)/Library/Logs/ghostty-ramon-host.log")
    }

    enum Plan: Equatable {
        /// No `ghostty-host` bundled in the app → dev/local build → do nothing.
        case skipNoBundledHost
        /// A plist exists at the target path that we did NOT write → leave it alone.
        case skipExternallyManaged
        /// No plist yet → write it + bootstrap.
        case install(LaunchAgentSpec)
        /// We own the plist and the bundle version changed → rewrite + reload
        /// (bootout+bootstrap) so launchd re-derives the LWCR for the new binary.
        case reload(LaunchAgentSpec)
        /// We own the plist and the version matches → nothing to do.
        case upToDate
        /// We own the plist, the version matches, but the host is not running
        /// (booted out / crash-looped past KeepAlive / plist half-removed). Revive
        /// it NON-DESTRUCTIVELY (bootstrap if needed + kickstart) — the cdhash is
        /// unchanged so there is NO bootout, and a transient running-probe
        /// false-negative therefore can't kill a live host's RAM-only sessions.
        case revive(LaunchAgentSpec)
        /// We own the plist, never recorded a version (lost/never-written
        /// UserDefaults key), but a healthy host is ALREADY running — adopt it by
        /// recording the current version. Crucially this does NOT bootout, so we
        /// never destroy a running host's (RAM-only) sessions on a mere bookkeeping
        /// gap. (Rewriting the plist on disk is harmless and keeps it current.)
        case adoptRunning(LaunchAgentSpec)
    }

    /// Pure decision for the host LaunchAgent. See type doc for the safety rules.
    /// - Parameters:
    ///   - existingPlistManagedBy: the `GhosttyAppManaged` value found in the
    ///     existing plist, or nil if the file is absent OR present-but-unreadable
    ///     OR present-without-our-marker (all of which mean "not ours").
    /// - Parameter agentRunning: whether the LaunchAgent is currently loaded AND
    ///   running (a live pid). Only consulted to AVOID a destructive reload when
    ///   the version bookkeeping was lost but the host is healthy.
    static func plan(
        bundledHostExists: Bool,
        existingPlistFileExists: Bool,
        existingPlistManagedBy: String?,
        installedVersion: String?,
        bundleVersion: String,
        agentRunning: Bool,
        spec: LaunchAgentSpec
    ) -> Plan {
        guard bundledHostExists else { return .skipNoBundledHost }
        if existingPlistFileExists {
            // Only ever touch a plist we ourselves wrote (marker == our bundle id).
            guard existingPlistManagedBy == spec.managingBundleID else {
                return .skipExternallyManaged
            }
            if installedVersion == bundleVersion {
                // Version matches. Healthy host → nothing to do. A host that is
                // recorded-current yet NOT running (booted out, crash-looped past
                // KeepAlive, plist half-removed) is revived NON-DESTRUCTIVELY: the
                // cdhash is unchanged, so we never bootout (which would also be the
                // only way a transient running-probe false-negative could kill a
                // live host's sessions) — we just bootstrap-if-needed + kickstart.
                return agentRunning ? .upToDate : .revive(spec)
            }
            // Version differs or is unknown. A genuine version change (recorded
            // version present-and-different) means a new binary/cdhash → reload is
            // mandatory. But when we never recorded a version (nil) yet a healthy
            // host is already running, a reload would bootout+kill its RAM-only
            // sessions for nothing — adopt the running host instead.
            if installedVersion == nil && agentRunning { return .adoptRunning(spec) }
            return .reload(spec)
        }
        return .install(spec)
    }

    // MARK: - Execution (impure)

    /// Run both setup jobs. Call OFF the main thread (it does file IO and shells
    /// out to `launchctl`). Idempotent; safe on every launch.
    static func perform(
        bundle: Bundle = .main,
        defaults: UserDefaults = .ghostty,
        fileManager: FileManager = .default
    ) {
        let home = NSHomeDirectory()
        // Gate ALL distribution setup on "is a ghostty-host bundled in this app?".
        // Only CI release builds bundle it; dev/ReleaseLocal/Debug builds (and a
        // locally-built Release) do not. This keeps the config seed and the host
        // LaunchAgent SYMMETRIC: a developer's machine never has the colleague
        // config authored under it (which would point pty-host at a socket no dev
        // build serves), and the three identities never race to write it.
        let bundledHost = bundle.bundleURL.appendingPathComponent("Contents/MacOS/ghostty-host").path
        guard fileManager.isExecutableFile(atPath: bundledHost) else {
            logger.debug("no bundled ghostty-host (dev/local build); skipping fork distribution setup")
            return
        }
        seedConfigIfNeeded(home: home, fileManager: fileManager)
        manageHostLaunchAgentIfNeeded(bundle: bundle, defaults: defaults, home: home, fileManager: fileManager)
    }

    private static func seedConfigIfNeeded(home: String, fileManager: FileManager) {
        let configPath = "\(home)/.config/ghostty-ramon/config"
        guard let contents = configSeedContents(
            fileExists: fileManager.fileExists(atPath: configPath), home: home)
        else { return }
        let dir = (configPath as NSString).deletingLastPathComponent
        do {
            try fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try contents.write(toFile: configPath, atomically: true, encoding: .utf8)
            // First run: the seeded config enables the pty-host backend, but config
            // was already loaded (in-process backend) before this seed ran, so it
            // takes effect on the NEXT launch. Tell the user a relaunch unlocks the
            // hosted features rather than leaving them guessing on first run.
            logger.info("seeded default fork config at \(configPath, privacy: .public); relaunch to activate the pty-host backend")
            notify(
                title: "Welcome to Ghostty (ramon)",
                body: "Set up your config. Quit and reopen once to enable hosted sessions (live previews + session survival).")
        } catch {
            logger.warning("failed to seed fork config: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func manageHostLaunchAgentIfNeeded(
        bundle: Bundle, defaults: UserDefaults, home: String, fileManager: FileManager
    ) {
        guard let bundleID = bundle.bundleIdentifier else { return }
        let bundleVersion = (bundle.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
        let spec = makeSpec(bundleURL: bundle.bundleURL, bundleID: bundleID, home: home)
        let bundledHostExists = fileManager.isExecutableFile(atPath: spec.hostBinaryPath)

        let plistPath = "\(home)/Library/LaunchAgents/\(spec.label).plist"
        let target = "gui/\(getuid())/\(spec.label)"
        let (fileExists, managedBy) = readPlistMarker(plistPath: plistPath, fileManager: fileManager)

        // Probe "is the host already running?" when the plist is ours — every
        // ours-path consumes it: it decides revive-vs-upToDate (version matches)
        // and adopt-vs-reload (version unknown). hostRunning returns fast when the
        // host is up (one launchctl print, no sleeps); it only spends its backoff
        // budget when the host is down — which is exactly when we want to act.
        let ours = fileExists && managedBy == spec.managingBundleID
        let agentRunning = ours ? hostRunning(target: target) : false

        let decision = plan(
            bundledHostExists: bundledHostExists,
            existingPlistFileExists: fileExists,
            existingPlistManagedBy: managedBy,
            installedVersion: defaults.string(forKey: kInstalledHostVersion),
            bundleVersion: bundleVersion,
            agentRunning: agentRunning,
            spec: spec)

        switch decision {
        case .skipNoBundledHost:
            logger.debug("no bundled ghostty-host; leaving host LaunchAgent unmanaged")
        case .skipExternallyManaged:
            logger.info("host LaunchAgent at \(plistPath, privacy: .public) is externally managed; not touching it")
        case .upToDate:
            logger.debug("host LaunchAgent already installed for version \(bundleVersion, privacy: .public)")
        case .adoptRunning(let spec):
            // Healthy host already running but no recorded version (lost defaults):
            // record the version and refresh the plist on disk — NO bootout, so the
            // running host's sessions survive.
            try? spec.plistData().write(to: URL(fileURLWithPath: plistPath), options: .atomic)
            defaults.set(bundleVersion, forKey: kInstalledHostVersion)
            logger.info("adopted already-running host LaunchAgent \(spec.label, privacy: .public); recorded version \(bundleVersion, privacy: .public) without restart")
        case .install(let spec):
            installAndBootstrap(spec: spec, plistPath: plistPath, bundleVersion: bundleVersion,
                                defaults: defaults, fileManager: fileManager, bootout: false, verb: "installed")
        case .reload(let spec):
            installAndBootstrap(spec: spec, plistPath: plistPath, bundleVersion: bundleVersion,
                                defaults: defaults, fileManager: fileManager, bootout: true, verb: "reloaded")
        case .revive(let spec):
            installAndBootstrap(spec: spec, plistPath: plistPath, bundleVersion: bundleVersion,
                                defaults: defaults, fileManager: fileManager, bootout: false, verb: "revived")
        }
    }

    /// Write the plist and (re)bring-up the agent.
    /// - Parameter bootout: when true (a genuine version change → new cdhash) the
    ///   old job is booted out first so launchd re-derives the LWCR. When false
    ///   (fresh install / revive of a same-version host) we NEVER bootout — so a
    ///   transient running-probe false-negative can't kill a live host. `kickstart`
    ///   then guarantees a loaded-but-stopped job starts (it never restarts a
    ///   running one, lacking `-k`).
    private static func installAndBootstrap(
        spec: LaunchAgentSpec, plistPath: String, bundleVersion: String,
        defaults: UserDefaults, fileManager: FileManager, bootout: Bool, verb: String
    ) {
        let dir = (plistPath as NSString).deletingLastPathComponent
        do {
            try fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try spec.plistData().write(to: URL(fileURLWithPath: plistPath), options: .atomic)
        } catch {
            logger.error("failed writing host LaunchAgent plist: \(error.localizedDescription, privacy: .public)")
            return
        }

        let uid = getuid()
        let domain = "gui/\(uid)"
        let target = "\(domain)/\(spec.label)"

        // Boot out the old job ONLY on a genuine version change, so launchd
        // re-derives the LWCR for the new binary's cdhash (the CLAUDE.md gotcha).
        // `bootout` is ASYNCHRONOUS — the job may still be tearing down — so an
        // immediate `bootstrap` can fail transiently (rc 5 / EBUSY). Retry with a
        // short backoff; break as soon as a bootstrap returns success.
        if bootout { _ = runLaunchctl(["bootout", target]) }
        for attempt in 0..<5 {
            if runLaunchctl(["bootstrap", domain, plistPath]) == 0 { break }
            if attempt < 4 { Thread.sleep(forTimeInterval: 0.25) }
        }
        // Ensure a loaded-but-stopped job actually runs (revive case). No `-k`, so
        // this never restarts/kills an already-running host.
        _ = runLaunchctl(["kickstart", target])

        // Authoritative check after teardown has settled: is the agent actually
        // RUNNING (a live pid), not merely loaded? A bootstrap can report a benign
        // non-zero (e.g. "already bootstrapped") while the job is up; conversely a
        // KeepAlive job stuck in an LWCR crash-loop (exit 78) is "loaded" yet never
        // healthy. We require a live `pid = N`, polling briefly to allow RunAtLoad
        // to spawn. (A crash-loop is unlikely for our OWN bundled host since its
        // LWCR was just re-derived, but this keeps the recorded-success bar honest.)
        let loaded = hostRunning(target: target)
        if loaded {
            defaults.set(bundleVersion, forKey: kInstalledHostVersion)
            logger.info("\(verb, privacy: .public) host LaunchAgent \(spec.label, privacy: .public) for version \(bundleVersion, privacy: .public)")
        } else {
            // The old job was booted out and the new one would not load: the host
            // is OFFLINE (terminals will be empty) until the next relaunch. Leave
            // the recorded version stale so the next launch retries, AND surface it
            // — a silent debug log would leave the colleague staring at blank panes.
            logger.error("host LaunchAgent \(spec.label, privacy: .public) failed to bootstrap; the terminal host is OFFLINE until relaunch")
            notify(
                title: "Ghostty host unavailable",
                body: "The terminal host service didn't start. Quit and reopen Ghostty (ramon). If it persists, check ~/Library/Logs/ghostty-ramon-host.log.")
        }
    }

    /// Post a best-effort, user-visible ALERT notification. The message is always
    /// in the log too. We request `.alert` ourselves rather than relying on
    /// AppDelegate (which requests `.badge` only) — a title/body banner needs
    /// alert authorization to render, and the host-offline banner is the whole
    /// point of surfacing the failure. Best-effort: silently no-ops if declined.
    private static func notify(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .badge]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let req = UNNotificationRequest(
                identifier: "fork-setup-" + UUID().uuidString, content: content, trigger: nil)
            center.add(req, withCompletionHandler: nil)
        }
    }

    /// Read the ownership marker from an existing plist.
    /// Returns (fileExists, managedBy). managedBy is nil when the file is absent,
    /// unreadable, not a plist dict, or lacks our marker — all "not ours".
    static func readPlistMarker(
        plistPath: String, fileManager: FileManager
    ) -> (exists: Bool, managedBy: String?) {
        guard fileManager.fileExists(atPath: plistPath) else { return (false, nil) }
        guard let data = fileManager.contents(atPath: plistPath),
              let obj = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = obj as? [String: Any]
        else { return (true, nil) }
        return (true, dict[managedKey] as? String)
    }

    /// Poll `launchctl print` for a live `pid = N`, allowing RunAtLoad a moment to
    /// spawn. "Running" (has a pid), not merely "loaded", is the success bar.
    private static func hostRunning(target: String) -> Bool {
        for attempt in 0..<5 {
            let result = runLaunchctlCapturing(["print", target])
            if result.status == 0,
               result.stdout.range(of: #"pid = \d+"#, options: .regularExpression) != nil {
                return true
            }
            if attempt < 4 { Thread.sleep(forTimeInterval: 0.25) }
        }
        return false
    }

    private struct LaunchctlResult { let status: Int32; let stdout: String }

    /// Run `/bin/launchctl` with args; capture stdout + exit status. stderr is
    /// logged at debug on failure. Best-effort: never throws.
    @discardableResult
    private static func runLaunchctlCapturing(_ args: [String]) -> LaunchctlResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
            // Read stdout before stderr; `launchctl print` for a single job is well
            // under the 64KB pipe buffer, so sequential reads won't deadlock.
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus != 0,
               let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !msg.isEmpty {
                logger.debug("launchctl \(args.first ?? "", privacy: .public): \(msg, privacy: .public)")
            }
            return LaunchctlResult(
                status: process.terminationStatus,
                stdout: String(data: outData, encoding: .utf8) ?? "")
        } catch {
            logger.error("failed to run launchctl: \(error.localizedDescription, privacy: .public)")
            return LaunchctlResult(status: -1, stdout: "")
        }
    }

    @discardableResult
    private static func runLaunchctl(_ args: [String]) -> Int32 {
        runLaunchctlCapturing(args).status
    }

    // MARK: - Seed template

    /// Sanitized, portable, secret-free default fork config. `__HOME__` is
    /// substituted with the user's home dir at seed time. Mirrors
    /// example/ghostty-ramon/config but with personal project launchers commented
    /// out, the pty-host socket parameterized, and the open mcp-listen disabled
    /// (a colleague opts in via the untracked `local` include + a token).
    static let seedTemplate = """
    # Ghostty fork (ramon) — fork-only config (auto-seeded on first launch)
    #
    # Loaded ONLY by the forked build ("Ghostty (ramon)"), layered on top of the
    # shared ~/.config/ghostty/config. Fork-only keybinds + keys live here so an
    # official Ghostty never sees them. Safe to edit — it is not overwritten on
    # later launches.
    #
    # SECRETS / PER-MACHINE values do NOT belong here — put them in the untracked
    # ~/.config/ghostty-ramon/local, pulled in just below.
    config-file = ?~/.config/ghostty-ramon/local

    # --- Auto-update ---------------------------------------------------------
    # Check for fork updates and notify (does not auto-install). The feed is
    # pinned to the fork's own GitHub Releases. Set `download` to also fetch
    # automatically, or `off` to disable.
    auto-update = check

    # --- Fork split/tab commands (edit combos to taste) ----------------------
    keybind = ctrl+cmd+shift+f=flip_split:horizontal
    #keybind = ctrl+cmd+shift+v=flip_split:vertical
    #keybind = ctrl+cmd+shift+h=toggle_split_direction:horizontal
    #keybind = ctrl+cmd+shift+u=toggle_split_direction:vertical
    #keybind = ctrl+cmd+shift+t=move_split_to_new_tab
    #keybind = ctrl+cmd+shift+right=merge_tabs:next_horizontal
    #keybind = ctrl+cmd+shift+down=merge_tabs:next_vertical
    #keybind = ctrl+cmd+shift+left=merge_tabs:previous_horizontal
    #keybind = ctrl+cmd+shift+up=merge_tabs:previous_vertical

    # --- tmux-shaped prefix layer for fork-specific actions -----------------
    keybind = ctrl+a>q=mark_split
    keybind = ctrl+a>shift+q=clear_split_mark
    keybind = ctrl+a>m=pull_marked_split:auto
    keybind = ctrl+a>shift+!=move_split_to_new_tab

    # One-key project launchers — open a new tab with cwd set to a project.
    # Personal examples; uncomment + edit to your own repo paths.
    #keybind = ctrl+a>g=new_tab:~/git/your-project
    #keybind = ctrl+a>i=new_tab:~/git/another-project

    # Dynamic project selector: opens a fuzzy palette of the immediate subdirs of
    # each `project-directory`; selecting one opens it in a new tab. Point this at
    # wherever you keep your repos.
    project-directory = ~/git
    keybind = ctrl+a>f=toggle_project_selector

    # Agent Dashboard (fork-only): a panel of live mini-previews of every split
    # running a CLI agent (claude/codex) across all tabs/windows; click to jump.
    # `ctrl+a>d` toggles it. NOTE: live previews appear only once the HOSTED
    # backend is active — i.e. after the one-time relaunch below (pty-host) — so on
    # the very first run the panel may open empty/metadata-only until you relaunch.
    agent-dashboard = true
    agent-dashboard-commands = claude,codex
    keybind = ctrl+a>d=toggle_agent_dashboard

    # --- tmux pane/split bindings --------------------------------------------
    keybind = ctrl+a>shift+%=new_split:right
    keybind = ctrl+a>shift+@=new_split:right
    keybind = ctrl+a>shift+"=new_split:down
    keybind = ctrl+a>left=goto_split:left
    keybind = ctrl+a>right=goto_split:right
    keybind = ctrl+a>up=goto_split:up
    keybind = ctrl+a>down=goto_split:down
    keybind = ctrl+a>o=goto_split:next
    keybind = ctrl+a>;=goto_split:previous
    keybind = ctrl+a>x=close_surface
    keybind = ctrl+a>z=toggle_split_zoom
    keybind = ctrl+a>space=equalize_splits
    keybind = ctrl+a>shift+{=swap_split:previous
    keybind = ctrl+a>shift+}=swap_split:next
    keybind = repeatable:ctrl+a>h=resize_split:left,10
    keybind = repeatable:ctrl+a>j=resize_split:down,10
    keybind = repeatable:ctrl+a>k=resize_split:up,10
    keybind = repeatable:ctrl+a>l=resize_split:right,10
    keybind = repeatable:ctrl+a>shift+h=resize_split:left,50
    keybind = repeatable:ctrl+a>shift+j=resize_split:down,50
    keybind = repeatable:ctrl+a>shift+k=resize_split:up,50
    keybind = repeatable:ctrl+a>shift+l=resize_split:right,50

    # --- tmux window/tab bindings --------------------------------------------
    keybind = ctrl+a>c=new_tab
    keybind = ctrl+a>n=next_tab
    keybind = ctrl+a>p=previous_tab
    keybind = ctrl+a>shift+&=close_tab
    keybind = ctrl+a>,=prompt_tab_title
    keybind = ctrl+a>w=toggle_tab_overview
    keybind = ctrl+a>1=goto_tab:1
    keybind = ctrl+a>2=goto_tab:2
    keybind = ctrl+a>3=goto_tab:3
    keybind = ctrl+a>4=goto_tab:4
    keybind = ctrl+a>5=goto_tab:5
    keybind = ctrl+a>6=goto_tab:6
    keybind = ctrl+a>7=goto_tab:7
    keybind = ctrl+a>8=goto_tab:8
    keybind = ctrl+a>9=goto_tab:9

    # --- tmux misc -----------------------------------------------------------
    keybind = ctrl+a>ctrl+a=goto_last_surface
    keybind = ctrl+a>shift+:=toggle_command_palette
    keybind = ctrl+a>r=reload_config

    # --- Bell: quieter when in focus -----------------------------------------
    # In focus: sound only (system beep), no dock attention, no title bell.
    bell-features-focused = system,no-attention,no-title

    # --- PTY host: emulation-on-host (always-on) -----------------------------
    # Selects the out-of-process `.client` backend: emulation + the live shell run
    # in a long-lived ghostty-host daemon (auto-installed + supervised by a launchd
    # LaunchAgent on first launch), so sessions SURVIVE A GUI QUIT/RELAUNCH.
    # NOTE: this takes effect on the SECOND launch — the first launch installs the
    # host and runs the in-process backend; relaunch once for hosted sessions.
    pty-host = __HOME__/.ghostty-ramon-host.sock

    # --- Web monitor (fork-only, OFF by default) ---------------------------------
    # Watch/drive splits from a phone over Tailscale. See WEB-MONITOR.md. The bind
    # address (this Mac's Tailscale IP) + token go in the untracked
    # ~/.config/ghostty-ramon/local. Empty/absent = off.
    # web-monitor-listen = 100.x.y.z:8787
    # web-monitor-token = <generate with: openssl rand -hex 24>

    # --- MCP server (fork-only, OFF by default) ----------------------------------
    # GUI-embedded MCP server for agent control. The token is a SHELL-EXECUTION
    # credential, so enable this only WITH a token, in the untracked
    # ~/.config/ghostty-ramon/local:
    #   mcp-listen = 127.0.0.1:8765
    #   mcp-token  = <generate with: openssl rand -hex 24>

    """
}

