import Foundation
import GhosttyKit
import OSLog
import Security
import UserNotifications

/// (ramon fork) First-launch setup for COLLEAGUE distribution builds.
///
/// Seven independent, idempotent jobs, safe to run on every launch:
///
///   1. **Config seed** — write a sanitized default `~/.config/ghostty-ramon/config`
///      if (and only if) the file is absent, so the fork's keybinds/features work
///      out of the box on a fresh machine. We never overwrite an existing config.
///
///   2. **Local secrets** — auto-provision the untracked, machine-local
///      `~/.config/ghostty-ramon/local` with `mcp-listen = 127.0.0.1:8765` and a
///      freshly-generated CSPRNG `mcp-token`, so the MCP server (and everything
///      that needs the token — the `ghostty-mcp` shim, the Claude agent-state
///      hooks, the agent dashboard chips / queue / manager) works out of the box
///      without the colleague hand-writing a token. Idempotent + NEVER clobbers:
///      if `local` already sets `mcp-token` we leave it strictly alone; if `local`
///      is absent we create it; if it exists without `mcp-token` we APPEND the two
///      lines. The seeded config already pulls `local` in via an optional include.
///
///   3. **Host LaunchAgent** — install (and version-reload) a launchd user
///      LaunchAgent that supervises the `ghostty-host` binary BUNDLED inside the
///      app (`Contents/MacOS/ghostty-host`), so the pty-host backend works with no
///      manual terminal setup. The agent is `RunAtLoad`+`KeepAlive`, exactly like
///      the hand-rolled one documented in CLAUDE.md.
///
///   4. **MCP shim** — install the bundled `ghostty-mcp` stdio shim onto PATH at
///      `~/.local/bin/ghostty-mcp` so an MCP client can reach the in-GUI server.
///
///   5. **`ghostty-ramon` CLI** — install a launcher onto PATH at
///      `~/.local/bin/ghostty-ramon` pointing at the app's multitool binary
///      (`Contents/MacOS/ghostty`), so a colleague can run discovery commands like
///      `ghostty-ramon +list-keybinds`. (NOT named `ghostty`, to avoid colliding
///      with an official ghostty CLI.) Symlink, so it always tracks the app.
///
///   6. **First-run welcome** — a ONE-TIME notification (idempotent via a persisted
///      bool) pointing the colleague at discovery (`ghostty-ramon +list-keybinds` /
///      ONBOARDING.md), since they won't scroll the command palette to find the
///      fork's features.
///
///   7. **MCP registration** — register the Ghostty MCP server with Claude Code
///      (`claude mcp add ghostty --scope user -- ~/.local/bin/ghostty-mcp`) so a
///      fresh `claude` session can actually SEE it. Without this the colleague has
///      the shim + token + bind on disk but Claude Code knows nothing about it, so
///      the very tool they'd use to finish setup is missing. Idempotent: skips when
///      already recorded, when `claude`/the shim aren't present yet (retries later),
///      and never clobbers a pre-existing `ghostty` server. Runs in `performDeferred`
///      AFTER the shim install (job 4).
///
/// ── LAUNCH ORDERING (pty-host first-launch reliability) ─────────────────────────
/// The host-CRITICAL jobs (config seed, local secrets, host LaunchAgent) are split
/// out into `performHostSetup()`, which the AppDelegate runs SYNCHRONOUSLY and EARLY
/// (before any window/`.client` surface is created) so the bundled `ghostty-host` is
/// reliably installed + bootstrapped + RUNNING before a surface tries to connect to
/// its socket — eliminating the blank-pane race. The non-critical jobs (shim, CLI,
/// welcome) stay in `performDeferred()`, run off-main, since they don't gate surface
/// connection. (See the note on `perform(...)`.) NOTE: pty-host still only takes
/// EFFECT on the SECOND launch, because the GUI reads `pty-host` from the config in
/// `Ghostty.App.init()` (the AppDelegate constructor) — strictly BEFORE any launch
/// callback runs — so the freshly-seeded value isn't seen until the next launch.
/// What `performHostSetup()` buys is that on every launch where pty-host IS
/// configured, the host is up before surfaces connect (no race), without a risky
/// mid-launch backend-switching config reload.
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

    /// UserDefaults key: the host RELOAD IDENTITY the LaunchAgent was last
    /// (re)loaded for — `ghostty_host_reload_identity()` decoded to "major.minor.epoch"
    /// (protocol version + the GUI-side `host_reload_epoch`). The RELOAD decision keys
    /// off THIS, not the bundle version and NOT the binary hash. The notarized host's
    /// launchd LWCR is pinned to the Developer-ID identity (identifier + Team ID), NOT
    /// the cdhash (verified empirically), so a new same-identity host build satisfies
    /// the existing requirement and loads on the next natural restart with no bootout.
    /// We therefore only bootout-reload (which kills the host's RAM-only sessions) when
    /// the protocol/epoch actually changed — i.e. the running host can't serve the new
    /// GUI, or a host-internal fix must run. A GUI-only update keeps the identity
    /// stable ⇒ no reload ⇒ sessions preserved. (Replaced the former binary-hash key
    /// `forkSetup.hostLaunchAgentBinaryHash`, which reloaded on any recompile even when
    /// behavior was unchanged.)
    static let kInstalledHostReloadIdentity = "forkSetup.hostLaunchAgentReloadIdentity"

    /// UserDefaults key: the CFBundleVersion the `ghostty-mcp` shim was last
    /// installed to `~/.local/bin` for. Drives version-aware reinstall.
    static let kInstalledShimVersion = "forkSetup.mcpShimVersion"

    /// UserDefaults key: the CFBundleVersion the `ghostty-ramon` CLI launcher was
    /// last installed to `~/.local/bin` for. Drives version-aware reinstall.
    static let kInstalledCLIVersion = "forkSetup.cliLauncherVersion"

    /// UserDefaults key: whether the one-time first-run welcome notification has
    /// already been shown. Idempotent — shown at most once per UserDefaults domain.
    static let kWelcomeShown = "forkSetup.welcomeShown"

    /// UserDefaults key: whether we've successfully registered the Ghostty MCP
    /// server with Claude Code (`claude mcp add ghostty`). Set ONLY on success (or
    /// when an entry already exists), so we keep retrying across launches until
    /// `claude` is present + the shim is installed, but never fight a colleague who
    /// later removes the registration by hand.
    static let kMCPRegistered = "forkSetup.mcpRegisteredWithClaude"

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

    // MARK: - Local secrets (mcp-listen / mcp-token) (pure)

    /// The localhost MCP bind seeded into `local`. The MCPServer applies a
    /// per-identity port offset on top (Release +0 → 8765), so this exact value is
    /// correct for the installed colleague build.
    static let mcpListenDefault = "127.0.0.1:8765"

    /// Decision for provisioning the untracked, machine-local
    /// `~/.config/ghostty-ramon/local` with an MCP listen + token. NEVER clobbers a
    /// token a colleague (or a prior run) already wrote.
    enum LocalSecretsPlan: Equatable {
        /// `local` already sets `mcp-token` → leave the whole file strictly alone.
        case skipHasToken
        /// `local` is absent → create it with a header comment + both lines.
        case create
        /// `local` exists but has NO `mcp-token` → APPEND the two lines (don't
        /// rewrite the file, so any other machine-local keys are preserved).
        case append
    }

    /// Pure decision for the local-secrets file. The cleanest safe behavior:
    /// presence of a `mcp-token` is the idempotency key (re-running never rotates a
    /// live shell-execution credential); an existing file without one is appended to
    /// rather than rewritten (preserves a colleague's other `local` keys, e.g.
    /// `web-monitor-listen`).
    static func planLocalSecretsInstall(localExists: Bool, hasToken: Bool) -> LocalSecretsPlan {
        if !localExists { return .create }
        if hasToken { return .skipHasToken }
        return .append
    }

    /// True iff `contents` already sets a non-comment `mcp-token` (so we must not
    /// add another). Matches a line whose first non-whitespace token is `mcp-token`
    /// — a commented `#mcp-token = …` does NOT count (it's the seed example).
    static func localHasMCPToken(_ contents: String) -> Bool {
        for raw in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            // Key/value lines are `key = value`; match the key token exactly.
            let key = line.split(separator: "=", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespaces) ?? ""
            if key == "mcp-token" { return true }
        }
        return false
    }

    /// Generate a cryptographically-strong MCP token: 32 random bytes (well above
    /// the 16-byte / 32-hex-char floor) rendered as lowercase hex (64 chars). Uses
    /// `SecRandomCopyBytes` (the system CSPRNG); falls back to the also-CSPRNG
    /// `UInt64.random` only if that ever fails (it effectively never does), so the
    /// returned value is always a real random token, never a constant.
    static func generateMCPToken(byteCount: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        if status != errSecSuccess {
            // Fallback (should not happen): SystemRandomNumberGenerator is a CSPRNG.
            var rng = SystemRandomNumberGenerator()
            for i in 0..<byteCount { bytes[i] = UInt8.random(in: 0...255, using: &rng) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// The full file body to CREATE when `local` is absent: a short header marking
    /// it as machine-local secrets, plus the two lines.
    static func localSecretsFileContents(token: String) -> String {
        """
        # Ghostty fork (ramon) — machine-local secrets (auto-provisioned on first launch).
        #
        # This file is UNTRACKED and pulled in by the seeded config via an optional
        # include. Put SECRETS and PER-MACHINE values here, NOT in the tracked config.
        # Safe to edit. The mcp-token below is a SHELL-EXECUTION credential (the MCP
        # tools spawn tabs + run commands) — rotate it if it ever leaks.
        \(localSecretsAppendBlock(token: token))
        """
    }

    /// The block to APPEND when `local` exists but has no `mcp-token`. A leading
    /// blank line + a brief marker keep it readable when tacked onto existing keys.
    static func localSecretsAppendBlock(token: String) -> String {
        """
        # --- MCP server (auto-provisioned) ---
        mcp-listen = \(mcpListenDefault)
        mcp-token = \(token)
        """
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
        installedReloadIdentity: String?,
        currentReloadIdentity: String,
        agentRunning: Bool,
        spec: LaunchAgentSpec
    ) -> Plan {
        guard bundledHostExists else { return .skipNoBundledHost }
        if existingPlistFileExists {
            // Only ever touch a plist we ourselves wrote (marker == our bundle id).
            guard existingPlistManagedBy == spec.managingBundleID else {
                return .skipExternallyManaged
            }
            // PRIMARY gate: the host RELOAD IDENTITY (protocol version + epoch), NOT
            // the binary hash and NOT the bundle version. The notarized host's launchd
            // LWCR is pinned to the Developer-ID identity (identifier + Team ID), not
            // the cdhash (verified) — so a new same-identity host satisfies the existing
            // requirement and loads on the next natural restart with no bootout. We
            // therefore reload (bootout+bootstrap, which KILLS the host's RAM-only
            // sessions) ONLY when the protocol/epoch changed — i.e. the running old host
            // can't serve the new GUI, or a host-internal fix must actually run. A
            // GUI-only release keeps the identity stable ⇒ sessions preserved. Bump the
            // protocol version or `host_reload_epoch` (embedded.zig) to force a reload.
            if let recorded = installedReloadIdentity {
                if recorded == currentReloadIdentity {
                    // Identity unchanged. Healthy → nothing to do; a recorded-but-
                    // not-running host (booted out / plist half-removed) is revived
                    // NON-DESTRUCTIVELY (no bootout — the LWCR is still satisfied).
                    return agentRunning ? .upToDate : .revive(spec)
                }
                return .reload(spec)  // protocol/epoch changed → deliver the new host
            }
            // No recorded identity: first launch under identity-gating (upgrading from
            // a hash-keyed build — every existing colleague hits this exactly once), or
            // lost defaults. Because the LWCR is identity-pinned, this transition is
            // NON-DESTRUCTIVE — record the identity WITHOUT reloading. A running host is
            // adopted; a not-running one is revived (bootstrap, no bootout). This is a
            // strict improvement over the old hash gate's one-last-version-reload, which
            // needlessly killed sessions on the upgrade.
            return agentRunning ? .adoptRunning(spec) : .revive(spec)
        }
        return .install(spec)
    }

    // MARK: - MCP shim install (pure)

    /// Decision for installing the bundled `ghostty-mcp` shim onto PATH
    /// (`~/.local/bin/ghostty-mcp`). Symmetric with the host plan: gated on a
    /// bundled shim existing (only CI release builds bundle it), so a dev/local
    /// build never touches a hand-installed `~/.local/bin/ghostty-mcp`.
    enum ShimPlan: Equatable {
        /// No `ghostty-mcp` bundled in the app → dev/local build → do nothing.
        case skipNoBundledShim
        /// Installed file is present AND recorded for this exact bundle version.
        case upToDate
        /// Missing on PATH, or recorded for a different version → (re)install.
        case install
    }

    /// Pure decision for the PATH shim. Reinstalls when the on-disk copy is
    /// missing (covers a manual delete) OR the recorded version differs from the
    /// running bundle (covers a Sparkle update shipping a new shim) — otherwise a
    /// no-op so steady-state launches don't rewrite the file.
    static func planShimInstall(
        bundledShimExists: Bool,
        installedShimExists: Bool,
        installedVersion: String?,
        bundleVersion: String
    ) -> ShimPlan {
        guard bundledShimExists else { return .skipNoBundledShim }
        if installedShimExists && installedVersion == bundleVersion { return .upToDate }
        return .install
    }

    // MARK: - ghostty-ramon CLI launcher install (pure)

    /// Decision for installing the `ghostty-ramon` CLI launcher onto PATH
    /// (`~/.local/bin/ghostty-ramon` → the app's `Contents/MacOS/ghostty` multitool).
    /// Mirrors `ShimPlan` exactly: gated on the multitool binary actually being
    /// present in the bundle, version-gated, and refusing to clobber a pre-existing
    /// NON-managed file (one we did not author — e.g. a hand-rolled launcher).
    enum CLIPlan: Equatable {
        /// No `Contents/MacOS/ghostty` multitool in the app → do nothing.
        case skipNoBundledBinary
        /// A file is already at the target that we did NOT create (not our symlink
        /// to this app's binary) → leave it strictly alone.
        case skipExternallyManaged
        /// Installed launcher is present, ours, AND recorded for this exact version.
        case upToDate
        /// Missing on PATH, or recorded for a different version → (re)install.
        case install
    }

    /// Pure decision for the CLI launcher. Reinstalls when the on-disk launcher is
    /// missing (covers a manual delete) OR the recorded version differs from the
    /// running bundle (covers a Sparkle update relocating the app) — otherwise a
    /// no-op. NEVER clobbers a pre-existing file that isn't ours.
    /// - Parameters:
    ///   - bundledBinaryExists: the app's `Contents/MacOS/ghostty` multitool exists.
    ///   - installedFileExists: a file/symlink already occupies the PATH target.
    ///   - installedIsOurs: that existing entry is one WE created (a symlink whose
    ///     destination is the running app's multitool binary). nil/false when the
    ///     target is absent or a foreign file.
    ///   - installedVersion: the recorded install version, or nil.
    ///   - bundleVersion: the running bundle's CFBundleVersion.
    static func planCLIInstall(
        bundledBinaryExists: Bool,
        installedFileExists: Bool,
        installedIsOurs: Bool,
        installedVersion: String?,
        bundleVersion: String
    ) -> CLIPlan {
        guard bundledBinaryExists else { return .skipNoBundledBinary }
        // A foreign file already at the target → never overwrite it.
        if installedFileExists && !installedIsOurs { return .skipExternallyManaged }
        // Ours and current → nothing to do. (Requires the file to still exist; a
        // recorded version with a deleted file falls through to .install below.)
        if installedFileExists && installedIsOurs && installedVersion == bundleVersion {
            return .upToDate
        }
        return .install
    }

    // MARK: - First-run welcome (pure)

    /// Pure predicate: should the one-time first-run welcome notification fire?
    /// True exactly once — the first launch where it hasn't been recorded as shown.
    /// (The caller has already gated on a bundled host, i.e. the distribution path.)
    static func shouldShowWelcome(alreadyShown: Bool) -> Bool {
        !alreadyShown
    }

    // MARK: - MCP registration with Claude Code (pure)

    /// Decision for auto-registering the Ghostty MCP server with Claude Code via
    /// `claude mcp add ghostty --scope user -- <shim>`. Without this, a DMG colleague
    /// has the shim + token + `mcp-listen` on disk but Claude Code knows nothing about
    /// it, so a brand-new `claude` session shows NO Ghostty MCP — and the very tool
    /// they'd reach for to finish setup is missing. This closes that gap.
    enum MCPRegisterPlan: Equatable {
        /// We already recorded a successful registration → never re-add (respects a
        /// colleague who later `claude mcp remove`s it).
        case skipAlreadyRecorded
        /// `claude` CLI not found on PATH (yet) → skip WITHOUT recording, so a later
        /// launch retries once `claude` is installed.
        case skipNoClaude
        /// The `ghostty-mcp` shim isn't on PATH (yet) → skip WITHOUT recording; the
        /// shim install is a sibling deferred job, so retry next launch.
        case skipNoShim
        /// A server named `ghostty` is ALREADY registered with Claude Code → leave it
        /// strictly alone (don't clobber a hand-managed entry) but record so we stop
        /// probing on every launch.
        case skipAlreadyRegistered
        /// All clear → run `claude mcp add` (user scope).
        case register
    }

    /// Pure decision for MCP registration. Order matters: a recorded success short-
    /// circuits before we shell out at all; otherwise we only register when `claude`
    /// is present, the shim is on PATH, and no `ghostty` server is already registered.
    /// - Parameters:
    ///   - alreadyRecorded: the persisted success bool (`kMCPRegistered`).
    ///   - claudeFound: a `claude` executable was resolved on the login-shell PATH.
    ///   - shimExists: `~/.local/bin/ghostty-mcp` exists (our sibling job installed it).
    ///   - alreadyRegistered: `claude mcp get ghostty` reports an existing entry.
    static func planMCPRegister(
        alreadyRecorded: Bool,
        claudeFound: Bool,
        shimExists: Bool,
        alreadyRegistered: Bool
    ) -> MCPRegisterPlan {
        if alreadyRecorded { return .skipAlreadyRecorded }
        guard claudeFound else { return .skipNoClaude }
        guard shimExists else { return .skipNoShim }
        if alreadyRegistered { return .skipAlreadyRegistered }
        return .register
    }

    // MARK: - Execution (impure)

    /// Run ALL setup jobs (host-critical THEN deferred). Idempotent; safe on every
    /// launch. Kept for callers/tests that want the whole thing in one call; the
    /// AppDelegate instead calls `performHostSetup()` synchronously+early and
    /// `performDeferred()` off-main (see the type doc's LAUNCH ORDERING note).
    static func perform(
        bundle: Bundle = .main,
        defaults: UserDefaults = .ghostty,
        fileManager: FileManager = .default
    ) {
        guard performHostSetup(bundle: bundle, defaults: defaults, fileManager: fileManager) else { return }
        performDeferred(bundle: bundle, defaults: defaults, fileManager: fileManager)
    }

    /// HOST-CRITICAL jobs that must complete BEFORE any `.client` surface connects:
    /// seed the config, provision the machine-local secrets, and install/bootstrap
    /// the host LaunchAgent. Intended to be called SYNCHRONOUSLY and EARLY in launch
    /// (before window/surface creation) so the bundled `ghostty-host` is reliably
    /// running by the time a surface dials its socket — eliminating the blank-pane
    /// race. It still does file IO and shells out to `launchctl`; in the common
    /// steady state (host already up, version unchanged) it returns fast (one
    /// `launchctl print`), and only the first-install / version-change path spends
    /// the bootstrap retry budget — exactly when the host would otherwise be down.
    ///
    /// Returns true iff a host is bundled (the distribution path) and the deferred
    /// jobs should follow; false on a dev/local build (no bundled host → no-op).
    @discardableResult
    static func performHostSetup(
        bundle: Bundle = .main,
        defaults: UserDefaults = .ghostty,
        fileManager: FileManager = .default
    ) -> Bool {
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
            return false
        }
        seedConfigIfNeeded(home: home, fileManager: fileManager)
        seedLocalSecretsIfNeeded(home: home, fileManager: fileManager)
        manageHostLaunchAgentIfNeeded(bundle: bundle, defaults: defaults, home: home, fileManager: fileManager)
        return true
    }

    /// NON-critical jobs that do NOT gate surface connection: the `ghostty-mcp`
    /// shim, the `ghostty-ramon` CLI launcher, the Claude Code MCP registration, and
    /// the one-time welcome. Safe to run off-main AFTER `performHostSetup()` (it shells
    /// out to the login shell for the MCP registration). Caller is responsible for the
    /// bundled-host gate (call only when `performHostSetup()` returned true).
    static func performDeferred(
        bundle: Bundle = .main,
        defaults: UserDefaults = .ghostty,
        fileManager: FileManager = .default
    ) {
        let home = NSHomeDirectory()
        installShimIfNeeded(bundle: bundle, defaults: defaults, home: home, fileManager: fileManager)
        installCLILauncherIfNeeded(bundle: bundle, defaults: defaults, home: home, fileManager: fileManager)
        // Must follow installShimIfNeeded — it registers the just-installed shim with
        // Claude Code so a fresh `claude` session can see the Ghostty MCP server.
        registerMCPWithClaudeIfNeeded(defaults: defaults, home: home, fileManager: fileManager)
        showWelcomeIfNeeded(defaults: defaults)
    }

    /// Auto-provision `~/.config/ghostty-ramon/local` with `mcp-listen` + a CSPRNG
    /// `mcp-token` so MCP-dependent features work out of the box. Idempotent + never
    /// clobbers an existing token (see `planLocalSecretsInstall`).
    private static func seedLocalSecretsIfNeeded(home: String, fileManager: FileManager) {
        let localPath = "\(home)/.config/ghostty-ramon/local"
        let localExists = fileManager.fileExists(atPath: localPath)
        let existing = localExists ? ((try? String(contentsOfFile: localPath, encoding: .utf8)) ?? "") : ""
        let plan = planLocalSecretsInstall(
            localExists: localExists, hasToken: localHasMCPToken(existing))
        switch plan {
        case .skipHasToken:
            logger.debug("~/.config/ghostty-ramon/local already sets mcp-token; leaving it")
        case .create:
            let body = localSecretsFileContents(token: generateMCPToken())
            let dir = (localPath as NSString).deletingLastPathComponent
            do {
                try fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try body.write(toFile: localPath, atomically: true, encoding: .utf8)
                // The token is a shell-execution credential — never log its value.
                logger.info("created ~/.config/ghostty-ramon/local with an mcp-listen + a generated mcp-token")
            } catch {
                logger.warning("failed to create local secrets file: \(error.localizedDescription, privacy: .public)")
            }
        case .append:
            // Preserve any existing keys: append, don't rewrite. Ensure a separating
            // newline so we never glue onto a trailing non-newline-terminated line.
            let sep = existing.isEmpty || existing.hasSuffix("\n") ? "\n" : "\n\n"
            let block = sep + localSecretsAppendBlock(token: generateMCPToken()) + "\n"
            do {
                let handle = FileHandle(forWritingAtPath: localPath)
                if let handle {
                    defer { try? handle.close() }
                    handle.seekToEndOfFile()
                    handle.write(Data(block.utf8))
                } else {
                    // Fallback: rewrite existing + block (still no clobber of a token,
                    // since .append only runs when there is none).
                    try (existing + block).write(toFile: localPath, atomically: true, encoding: .utf8)
                }
                logger.info("appended mcp-listen + a generated mcp-token to ~/.config/ghostty-ramon/local")
            } catch {
                logger.warning("failed to append local secrets: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Install the bundled `ghostty-mcp` stdio shim onto PATH at
    /// `~/.local/bin/ghostty-mcp` so an MCP client (`claude mcp add ghostty --
    /// ghostty-mcp`) can reach the in-GUI MCP server. Idempotent + version-aware.
    ///
    /// Safety: gated (via `planShimInstall`) on a shim actually being BUNDLED, which
    /// only CI release builds do — so on a dev machine (no bundled shim) this never
    /// runs and a hand-installed `~/.local/bin/ghostty-mcp` is left untouched. The
    /// caller already early-returns unless a host is bundled, so this is reached
    /// only on distribution builds anyway; the bundled-shim guard is belt-and-braces.
    ///
    /// We byte-copy via `Data.write(.atomic)` (temp + rename in the dest dir) rather
    /// than `copyItem`, because copyItem would propagate the bundle's quarantine
    /// xattr to the loose copy; a file we author carries none, so the signed Mach-O
    /// passes Gatekeeper on exec.
    private static func installShimIfNeeded(
        bundle: Bundle, defaults: UserDefaults, home: String, fileManager: FileManager
    ) {
        let bundledShim = bundle.bundleURL.appendingPathComponent("Contents/MacOS/ghostty-mcp").path
        let targetDir = "\(home)/.local/bin"
        let target = "\(targetDir)/ghostty-mcp"
        let bundleVersion = (bundle.infoDictionary?["CFBundleVersion"] as? String) ?? "0"

        let plan = planShimInstall(
            bundledShimExists: fileManager.isExecutableFile(atPath: bundledShim),
            installedShimExists: fileManager.fileExists(atPath: target),
            installedVersion: defaults.string(forKey: kInstalledShimVersion),
            bundleVersion: bundleVersion)

        switch plan {
        case .skipNoBundledShim:
            logger.debug("no bundled ghostty-mcp (dev/local build); leaving PATH shim unmanaged")
        case .upToDate:
            logger.debug("ghostty-mcp shim already installed for version \(bundleVersion, privacy: .public)")
        case .install:
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: bundledShim))
                try fileManager.createDirectory(atPath: targetDir, withIntermediateDirectories: true)
                let targetURL = URL(fileURLWithPath: target)
                try data.write(to: targetURL, options: .atomic)
                try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target)
                defaults.set(bundleVersion, forKey: kInstalledShimVersion)
                logger.info("installed ghostty-mcp shim at \(target, privacy: .public) for version \(bundleVersion, privacy: .public)")
            } catch {
                // Non-fatal: MCP is an opt-in power feature. Leave the recorded
                // version stale so the next launch retries; the colleague can also
                // register the shim from its bundled path by hand.
                logger.warning("failed to install ghostty-mcp shim: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Install the `ghostty-ramon` CLI launcher onto PATH at
    /// `~/.local/bin/ghostty-ramon`, pointing at the app's multitool binary
    /// (`Contents/MacOS/ghostty`). A SYMLINK is preferred (it always tracks the
    /// installed app — no rewrite needed when the app moves on update), so the
    /// colleague can run discovery commands like `ghostty-ramon +list-keybinds`.
    /// Idempotent + version-aware, with the SAME safety gates as the MCP shim:
    ///
    ///   * Acts only when the multitool binary is actually BUNDLED (the caller has
    ///     already early-returned unless a host is bundled, so this is reached only
    ///     on distribution builds; this guard is belt-and-braces).
    ///   * NEVER clobbers a pre-existing NON-managed file at the target — only a
    ///     symlink we ourselves created (one whose destination is THIS app's
    ///     multitool binary) is replaced.
    ///
    /// CRITICAL: the name is `ghostty-ramon`, NOT `ghostty`, so it can't collide
    /// with an official ghostty CLI already on the colleague's PATH.
    private static func installCLILauncherIfNeeded(
        bundle: Bundle, defaults: UserDefaults, home: String, fileManager: FileManager
    ) {
        let multitool = bundle.bundleURL.appendingPathComponent("Contents/MacOS/ghostty").path
        let targetDir = "\(home)/.local/bin"
        let target = "\(targetDir)/ghostty-ramon"
        let bundleVersion = (bundle.infoDictionary?["CFBundleVersion"] as? String) ?? "0"

        // "Ours" iff the target is a symlink whose resolved destination is this
        // app's multitool binary. A regular file, a dangling/foreign symlink, or a
        // symlink pointing elsewhere all read as NOT ours → we leave it alone.
        let installedFileExists = fileExistsOrSymlink(target, fileManager: fileManager)
        let installedIsOurs = symlinkPointsAt(target, expected: multitool, fileManager: fileManager)

        let plan = planCLIInstall(
            bundledBinaryExists: fileManager.isExecutableFile(atPath: multitool),
            installedFileExists: installedFileExists,
            installedIsOurs: installedIsOurs,
            installedVersion: defaults.string(forKey: kInstalledCLIVersion),
            bundleVersion: bundleVersion)

        switch plan {
        case .skipNoBundledBinary:
            logger.debug("no bundled ghostty multitool; leaving ghostty-ramon CLI unmanaged")
        case .skipExternallyManaged:
            logger.info("a non-managed file occupies \(target, privacy: .public); not installing ghostty-ramon CLI")
        case .upToDate:
            logger.debug("ghostty-ramon CLI already installed for version \(bundleVersion, privacy: .public)")
        case .install:
            do {
                try fileManager.createDirectory(atPath: targetDir, withIntermediateDirectories: true)
                // Replace only an entry that is OURS (planCLIInstall guarantees we
                // never reach .install over a foreign file). Removing first lets the
                // symlink be re-pointed at a relocated app after an update.
                if installedFileExists && installedIsOurs {
                    // Let a removal failure surface in the catch below (named cause in
                    // the log) rather than masking it behind a "file exists" symlink error.
                    try fileManager.removeItem(atPath: target)
                }
                try fileManager.createSymbolicLink(atPath: target, withDestinationPath: multitool)
                defaults.set(bundleVersion, forKey: kInstalledCLIVersion)
                logger.info("installed ghostty-ramon CLI at \(target, privacy: .public) -> \(multitool, privacy: .public)")
            } catch {
                // Non-fatal: the launcher is a discovery convenience. Leave the
                // recorded version stale so the next launch retries.
                logger.warning("failed to install ghostty-ramon CLI: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// True if a file OR symlink (incl. a dangling one) exists at `path`.
    /// `fileExists` follows symlinks (a dangling symlink reads as absent), so we
    /// also check the link attributes to catch a broken/foreign symlink we must not
    /// overwrite.
    private static func fileExistsOrSymlink(_ path: String, fileManager: FileManager) -> Bool {
        if fileManager.fileExists(atPath: path) { return true }
        return (try? fileManager.attributesOfItem(atPath: path)) != nil
    }

    /// True iff `path` is a symlink whose destination (resolved relative to its own
    /// directory if relative) equals `expected`. Used to recognize a launcher WE
    /// created so a reinstall replaces only our own symlink, never a foreign file.
    private static func symlinkPointsAt(
        _ path: String, expected: String, fileManager: FileManager
    ) -> Bool {
        guard let dest = try? fileManager.destinationOfSymbolicLink(atPath: path) else {
            return false
        }
        let resolved: String
        if (dest as NSString).isAbsolutePath {
            resolved = dest
        } else {
            let dir = (path as NSString).deletingLastPathComponent
            resolved = (dir as NSString).appendingPathComponent(dest)
        }
        return (resolved as NSString).standardizingPath == (expected as NSString).standardizingPath
    }

    /// Fire the one-time first-run welcome notification (idempotent via a persisted
    /// bool). Reuses `notify()` and points the colleague at discovery — they won't
    /// scroll the command palette, so we name the concrete cheat-sheet entrypoints.
    private static func showWelcomeIfNeeded(defaults: UserDefaults) {
        guard shouldShowWelcome(alreadyShown: defaults.bool(forKey: kWelcomeShown)) else {
            return
        }
        // Record BEFORE firing so a notify failure / permission prompt can't cause
        // it to re-fire on every launch; the welcome is a one-shot nicety.
        defaults.set(true, forKey: kWelcomeShown)
        logger.info("first-run welcome: pointing the colleague at ghostty-ramon +list-keybinds / ONBOARDING.md")
        notify(
            title: "Welcome to Ghostty (ramon)",
            body: "Run 'ghostty-ramon +list-keybinds' or see ONBOARDING.md for the keybind cheat sheet.")
    }

    /// Register the Ghostty MCP server with Claude Code so a fresh `claude` session
    /// sees it — `claude mcp add ghostty --scope user -- ~/.local/bin/ghostty-mcp`.
    /// Without this, a DMG colleague has the shim + token + `mcp-listen` on disk, but
    /// Claude Code knows nothing about it, so the very tool they'd reach for to finish
    /// setup is absent from a new session. The shim reads the token from `local` at
    /// runtime, so this registration carries NO secret.
    ///
    /// Idempotent + safe: a recorded success skips all probing; we only register when
    /// `claude` is on PATH and the shim is installed; we NEVER clobber a pre-existing
    /// `ghostty` server (a hand-managed entry is left strictly alone); success/already-
    /// registered is persisted so we stop probing, while a transient failure (claude or
    /// shim not yet present, `claude mcp add` non-zero) is left UNrecorded so the next
    /// launch retries. `--scope user` makes it global (every Claude Code session, any cwd).
    private static func registerMCPWithClaudeIfNeeded(
        defaults: UserDefaults, home: String, fileManager: FileManager
    ) {
        // Cheap gate first: a recorded success skips ALL shelling-out.
        if defaults.bool(forKey: kMCPRegistered) {
            logger.debug("Ghostty MCP already registered with Claude Code; skipping")
            return
        }
        let shimPath = "\(home)/.local/bin/ghostty-mcp"
        let shimExists = fileManager.isExecutableFile(atPath: shimPath)
        // Resolve `claude` robustly — the GUI launches with a pristine launchd PATH,
        // so a plain login-shell `command -v claude` MISSES installs whose PATH entry
        // lives in `.zshrc` (e.g. the common `~/.local/bin/claude`). See resolveClaude.
        let claudePath = resolveClaude(home: home, fileManager: fileManager)
        let alreadyRegistered = (claudePath != nil && shimExists)
            ? ghosttyMCPRegistered(claudePath: claudePath!) : false

        switch planMCPRegister(
            alreadyRecorded: false,
            claudeFound: claudePath != nil,
            shimExists: shimExists,
            alreadyRegistered: alreadyRegistered
        ) {
        case .skipAlreadyRecorded:
            break  // unreachable (early-returned above); kept for an exhaustive switch.
        case .skipNoClaude:
            logger.debug("claude CLI not found (PATH or known install locations); deferring MCP registration")
        case .skipNoShim:
            logger.debug("ghostty-mcp shim not yet on PATH; deferring MCP registration to a later launch")
        case .skipAlreadyRegistered:
            defaults.set(true, forKey: kMCPRegistered)
            logger.info("Claude Code already has a 'ghostty' MCP server; leaving it untouched")
        case .register:
            guard let claude = claudePath else { return }  // claudeFound implies non-nil
            // Run via an INTERACTIVE login shell using the RESOLVED absolute path: the
            // absolute path means we don't depend on PATH to FIND claude, and `-i`
            // (sources .zshrc) gives claude the full env (e.g. node) it needs to RUN.
            let cmd = "\(shellQuote(claude)) mcp add ghostty --scope user -- \(shellQuote(shimPath))"
            let status = loginShellStatus(cmd, interactive: true)
            if status == 0 {
                defaults.set(true, forKey: kMCPRegistered)
                logger.info("registered Ghostty MCP server with Claude Code (user scope)")
            } else {
                // Non-fatal: leave UNrecorded so the next launch retries. The colleague
                // can also register by hand (ONBOARDING.md documents the command).
                logger.warning("`claude mcp add ghostty` failed (status \(status ?? -1, privacy: .public)); will retry next launch")
            }
        }
    }

    /// The well-known absolute install locations for the `claude` CLI, in priority
    /// order. Checked BEFORE any shell probe so resolution is immune to the GUI's
    /// pristine PATH — `~/.local/bin/claude` (the official native installer) is by far
    /// the most common and is exactly what a colleague's machine had when the
    /// login-shell probe failed. Pure (unit-tested).
    static func claudeCandidatePaths(home: String) -> [String] {
        [
            "\(home)/.local/bin/claude",          // official native installer (most common)
            "\(home)/.claude/local/claude",       // older "local" install layout
            "/opt/homebrew/bin/claude",           // Homebrew (Apple Silicon)
            "/usr/local/bin/claude",              // Homebrew (Intel) / manual
            "/run/current-system/sw/bin/claude",  // nix
        ]
    }

    /// Pure: first path in `paths` for which `isExecutable` is true, or nil. Injectable
    /// predicate so the selection order is unit-testable without touching the disk.
    static func firstExecutablePath(_ paths: [String], isExecutable: (String) -> Bool) -> String? {
        paths.first(where: isExecutable)
    }

    /// Resolve an absolute path to the `claude` CLI, robust to the GUI's pristine
    /// launchd PATH. Order: (1) well-known absolute locations (no subprocess); (2) a
    /// LOGIN shell `command -v` (sources .zprofile/.zshenv); (3) an INTERACTIVE login
    /// shell `command -v` (also sources .zshrc — where many installs put the PATH).
    /// Returns nil if `claude` genuinely can't be found. A printf MARKER isolates the
    /// path from any banner text a noisy .zshrc prints on stdout.
    private static func resolveClaude(home: String, fileManager: FileManager) -> String? {
        if let p = firstExecutablePath(
            claudeCandidatePaths(home: home),
            isExecutable: fileManager.isExecutableFile(atPath:)
        ) {
            return p
        }
        let marker = "__GHOSTTY_CLAUDE__"
        for interactive in [false, true] {
            let (status, output) = runLoginShell(
                "printf '\(marker)%s\\n' \"$(command -v claude 2>/dev/null)\"",
                interactive: interactive)
            guard status == 0 else { continue }
            for line in output.split(separator: "\n") where line.hasPrefix(marker) {
                let path = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
                if !path.isEmpty, fileManager.isExecutableFile(atPath: String(path)) {
                    return String(path)
                }
            }
        }
        return nil
    }

    /// True iff Claude Code already has a server named `ghostty` registered (so we
    /// never clobber a hand-managed entry). Uses the resolved absolute claude path.
    private static func ghosttyMCPRegistered(claudePath: String) -> Bool {
        loginShellStatus("\(shellQuote(claudePath)) mcp get ghostty >/dev/null 2>&1",
                         interactive: true) == 0
    }

    /// POSIX single-quote a path so it survives `sh -c` intact (defensive — macOS home
    /// dirs don't contain quotes, but never string-splice an unquoted path into a shell).
    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Run a command in the user's login shell, returning its exit status (nil if the
    /// shell couldn't launch or it timed out). `-l` sources the user's PATH (a GUI app
    /// doesn't inherit the terminal PATH); `interactive` adds `-i` so `.zshrc` is also
    /// sourced (where many tools put PATH). A bounded timeout means a hung/interactive
    /// `.zshrc` can't wedge the deferred-setup thread; stdin is /dev/null so a prompt
    /// gets EOF instead of blocking. Output is discarded.
    private static func loginShellStatus(_ command: String, interactive: Bool) -> Int32? {
        runLoginShell(command, interactive: interactive).status
    }

    /// Run a command in the user's login shell and capture stdout (small outputs only).
    /// Returns (status, stdout); status is nil on launch failure or timeout. Combined
    /// short flags: `-lc` / `-ilc`. stderr discarded, stdin = /dev/null, 20s timeout.
    private static func runLoginShell(
        _ command: String, interactive: Bool, timeout: TimeInterval = 20
    ) -> (status: Int32?, output: String) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        proc.arguments = [interactive ? "-ilc" : "-lc", command]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        let sem = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in sem.signal() }
        do {
            try proc.run()
        } catch {
            return (nil, "")
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            proc.terminate()
            _ = sem.wait(timeout: .now() + 2)
            return (nil, "")
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        return (proc.terminationStatus, String(decoding: data, as: UTF8.self))
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
            // takes effect on the NEXT launch. We log this (and SHARING.md + the
            // seed comments cover it) rather than firing a notification here, which
            // would force a permission prompt on the benign success path —
            // notify() is reserved for the real host-offline failure.
            logger.info("seeded default fork config at \(configPath, privacy: .public); relaunch to activate the pty-host backend")
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

        // The lib-reported reload identity (protocol version + epoch) drives the reload
        // decision — see kInstalledHostReloadIdentity. Read once here; the same string
        // is recorded on every acting branch.
        let currentReloadIdentity = hostReloadIdentityString()

        let decision = plan(
            bundledHostExists: bundledHostExists,
            existingPlistFileExists: fileExists,
            existingPlistManagedBy: managedBy,
            installedReloadIdentity: defaults.string(forKey: kInstalledHostReloadIdentity),
            currentReloadIdentity: currentReloadIdentity,
            agentRunning: agentRunning,
            spec: spec)

        switch decision {
        case .skipNoBundledHost:
            logger.debug("no bundled ghostty-host; leaving host LaunchAgent unmanaged")
        case .skipExternallyManaged:
            logger.info("host LaunchAgent at \(plistPath, privacy: .public) is externally managed; not touching it")
        case .upToDate:
            logger.debug("host LaunchAgent already loaded for reload identity \(currentReloadIdentity, privacy: .public)")
        case .adoptRunning(let spec):
            // Healthy host already running but no recorded reload identity (upgrading
            // from a hash-keyed build, or lost defaults): record the identity + refresh
            // the plist on disk — NO bootout, so the running host's sessions survive.
            // Recording it here means future GUI-only updates compare equal and never
            // reload. (Safe on the hash→identity upgrade because the LWCR is
            // identity-pinned — the running old host keeps serving.)
            try? spec.plistData().write(to: URL(fileURLWithPath: plistPath), options: .atomic)
            defaults.set(bundleVersion, forKey: kInstalledHostVersion)
            defaults.set(currentReloadIdentity, forKey: kInstalledHostReloadIdentity)
            logger.info("adopted already-running host LaunchAgent \(spec.label, privacy: .public); recorded reload identity \(currentReloadIdentity, privacy: .public) without restart")
        case .install(let spec):
            installAndBootstrap(spec: spec, plistPath: plistPath, bundleVersion: bundleVersion,
                                reloadIdentity: currentReloadIdentity, defaults: defaults, fileManager: fileManager,
                                bootout: false, verb: "installed")
        case .reload(let spec):
            installAndBootstrap(spec: spec, plistPath: plistPath, bundleVersion: bundleVersion,
                                reloadIdentity: currentReloadIdentity, defaults: defaults, fileManager: fileManager,
                                bootout: true, verb: "reloaded")
        case .revive(let spec):
            installAndBootstrap(spec: spec, plistPath: plistPath, bundleVersion: bundleVersion,
                                reloadIdentity: currentReloadIdentity, defaults: defaults, fileManager: fileManager,
                                bootout: false, verb: "revived")
        }
    }

    /// The bundled host's reload identity as "major.minor.epoch", decoded from the
    /// lib's packed `ghostty_host_reload_identity()` (protocol version + the GUI-side
    /// `host_reload_epoch`). The value the reload gate compares — see
    /// kInstalledHostReloadIdentity. Not the host BINARY's identity: it's the lib's,
    /// which is exactly what we want (the lib and the bundled host are built together).
    static func hostReloadIdentityString() -> String {
        decodeReloadIdentity(ghostty_host_reload_identity())
    }

    /// Pure decode of the packed reload identity → "major.minor.epoch". Split out so
    /// the bit-unpacking is unit-testable without the lib call.
    static func decodeReloadIdentity(_ packed: UInt64) -> String {
        let major = (packed >> 32) & 0xFFFF
        let minor = (packed >> 16) & 0xFFFF
        let epoch = packed & 0xFFFF
        return "\(major).\(minor).\(epoch)"
    }

    /// Write the plist and (re)bring-up the agent.
    /// - Parameter bootout: when true (a genuine version change → new cdhash) the
    ///   old job is booted out first so launchd re-derives the LWCR. When false
    ///   (fresh install / revive of a same-version host) we NEVER bootout — so a
    ///   transient running-probe false-negative can't kill a live host. `kickstart`
    ///   then guarantees a loaded-but-stopped job starts (it never restarts a
    ///   running one, lacking `-k`).
    private static func installAndBootstrap(
        spec: LaunchAgentSpec, plistPath: String, bundleVersion: String, reloadIdentity: String,
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
        // bootout teardown of many live sessions can take several seconds, so give
        // bootstrap a generous, escalating retry budget (~6s) before giving up.
        for attempt in 0..<8 {
            if runLaunchctl(["bootstrap", domain, plistPath]) == 0 { break }
            if attempt < 7 { Thread.sleep(forTimeInterval: Double(attempt + 1) * 0.2) }
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
            // Record the reload identity so subsequent GUI-only updates (protocol/epoch
            // unchanged) compare equal and skip the reload, preserving live sessions.
            defaults.set(reloadIdentity, forKey: kInstalledHostReloadIdentity)
            logger.info("\(verb, privacy: .public) host LaunchAgent \(spec.label, privacy: .public) for reload identity \(reloadIdentity, privacy: .public)")
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
    /// example/ghostty-ramon/config but FEATURE-FIRST for a colleague: the personal
    /// tmux-style `ctrl+a` keybind layer is COMMENTED OUT (offered as a ready-made
    /// example, not imposed), project launchers are commented, the pty-host socket
    /// is parameterized, and the open mcp/web-monitor binds are disabled (a
    /// colleague opts in via the untracked `local` include + a token).
    static let seedTemplate = """
    # ============================================================================
    # QUICK START — what this fork adds, and how to reach it
    #
    # You do NOT need any special keybindings to use this fork. Its additions are:
    #   • Agent Dashboard — a panel of live previews of every split running a CLI
    #     agent (claude/codex); it opens on its own (agent-dashboard = true). Toggle
    #     it from the Command Palette → "Toggle Agent Dashboard".
    #   • Split & tab power-tools — flip / swap / merge splits, eject a pane to a
    #     tab, mark & pull a split, "go to last split", a fuzzy project picker, and
    #     more. Every one is in the Command Palette: press cmd+shift+p (or use the
    #     View ▸ Command Palette menu) and type "split", "tab", "project", "agent".
    #   • Optional power features (OFF by default): MCP server, Web monitor, Agent
    #     Queue / Manager — see their sections below and ONBOARDING.md.
    #
    # See everything with:  ghostty-ramon +list-keybinds  (currently-active binds)
    #                       ghostty-ramon +show-config --default --docs  (all keys)
    #
    # KEYBINDINGS: I personally drive all of the above from a tmux-style `ctrl+a`
    # prefix — that's MY muscle memory (it deliberately shadows readline's ctrl+a),
    # NOT something you need. My full layout is at the BOTTOM of this file, COMMENTED
    # OUT: uncomment it to adopt my bindings, or bind the same actions to your own
    # keys. The cheat sheet is in ONBOARDING.md.
    # ============================================================================
    #
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

    # --- Features (settings, not keybindings) --------------------------------
    # Project picker (Command Palette → "Open Project…"): point this at wherever
    # you keep your repos; each immediate subdir becomes a new-tab target. Left
    # commented so an unconfigured machine doesn't get an empty picker:
    #project-directory = ~/git

    # Agent Dashboard (fork-only): a panel of live mini-previews of every split
    # running a CLI agent (claude/codex) across all tabs/windows; click to jump.
    # It opens on its own; toggle it from the Command Palette → "Toggle Agent
    # Dashboard". NOTE: live previews appear only once the HOSTED backend is active
    # — i.e. after the one-time relaunch below (pty-host) — so on the very first run
    # the panel may open empty/metadata-only until you relaunch.
    agent-dashboard = true
    agent-dashboard-commands = claude,codex
    # How long "Spotlight Split at Top of Agent Dashboard" (spotlight_dashboard_split) keeps a
    # split spotlighted at the top (seconds; 0 = until you pin another split).
    agent-dashboard-spotlight-seconds = 10

    # Agent Queue (fork-only, OPT-IN — left OFF by default). Turns the dashboard
    # into an active supervisor that launches one CLI agent per work item from a
    # JSON template. Requires `node` on PATH, the Claude Code agent-state hooks
    # installed, and a queue template (see AGENT-QUEUE.md). Uncomment to enable:
    #agent-queue = true

    # Hero agents (fork-only): a HERO is a load-bearing queue item that competes
    # for YOUR ATTENTION, not a machine slot — it lives in its own tab, is never
    # auto-closed, and pushes a distinct glyph when it needs you. This is a
    # FLEET-WIDE ceiling on live heroes across ALL queue runs, orthogonal to
    # concurrency / maxItems / agent-queue-max-total. Default 2 (a discipline
    # limit); 0 disables hero dispatch. See HERO-AGENTS.md. Uncomment to override:
    #agent-queue-hero-max = 2

    # (My tmux-style `ctrl+a` keybindings live at the BOTTOM of this file, commented
    # out. None are required — the same actions are all in the Command Palette.)

    # --- Bell -----------------------------------------------------------------
    # Out of focus (backgrounded window / non-focused split / another Space): full
    # alerting. (bell-features is an upstream key; seeded here, in the fork-only
    # path, so it's set without touching the shared ~/.config/ghostty/config.)
    bell-features = system,attention,title,border
    # In focus: VISUAL-ONLY — no audible beep (no-system), no dock attention, no
    # title bell. Gentler default, close to upstream's silent-when-focused behavior;
    # add `system` back if you want a beep while the ringing split is focused.
    bell-features-focused = no-system,no-attention,no-title

    # --- PTY host: emulation-on-host (always-on) -----------------------------
    # Selects the out-of-process `.client` backend: emulation + the live shell run
    # in a long-lived ghostty-host daemon (auto-installed + supervised by a launchd
    # LaunchAgent on first launch), so sessions SURVIVE A GUI QUIT/RELAUNCH.
    # NOTE: this takes effect on the SECOND launch — the first launch installs the
    # host and runs the in-process backend; relaunch once for hosted sessions.
    # Session survival needs macOS to restore windows on quit (the window archive
    # carries each surface's host session id); with pty-host set, the fork forces
    # that on automatically, so you do NOT need `window-save-state = always`. Set
    # `window-save-state = never` only if you deliberately want NO reattach.
    pty-host = __HOME__/.ghostty-ramon-host.sock

    # --- Web monitor (fork-only, OFF by default) ---------------------------------
    # Watch/drive splits from a phone over Tailscale. See WEB-MONITOR.md.
    # SUPPORTED SETUP: bind LOOPBACK and front it with HTTPS via `tailscale serve`
    # (required to reach it from a phone at all — the server speaks plain HTTP to
    # loopback only). Do NOT bind a Tailscale IP / 0.0.0.0 directly (unsupported:
    # plain HTTP, breaks Web Push). Empty/absent = off.
    #   web-monitor-listen = 127.0.0.1:18787
    #   web-monitor-token  = <generate with: openssl rand -hex 24>
    # then: tailscale serve --bg --https=8787 127.0.0.1:18787

    # --- MCP server (fork-only) --------------------------------------------------
    # GUI-embedded MCP server for agent control. The token is a SHELL-EXECUTION
    # credential. On first launch the fork AUTO-PROVISIONS a localhost bind + a
    # random token into the untracked ~/.config/ghostty-ramon/local:
    #   mcp-listen = 127.0.0.1:8765
    #   mcp-token  = <random, generated for this machine>
    # (so MCP-dependent features — the dashboard chips, the agent queue/manager,
    # and the `ghostty-mcp` shim — work out of the box). To rotate the token, edit
    # that file. The `ghostty-mcp` stdio shim is installed to ~/.local/bin on first
    # launch; connect a local agent with:
    #   claude mcp add ghostty -- "$HOME/.local/bin/ghostty-mcp"
    # (the shim reads the token from ~/.config/ghostty-ramon/local). See MCP-SERVER.md.

    # ============================================================================
    # OPTIONAL: my personal tmux-style `ctrl+a` keybindings — ALL COMMENTED OUT.
    #
    # None of these are required; they're my muscle memory from years on tmux. Each
    # line binds a fork ACTION (the part after `=`). To adopt my whole layout,
    # uncomment this block; or copy individual actions onto keys you prefer. Heads
    # up: `ctrl+a` shadows readline's start-of-line — a deliberate tmux-ism. Every
    # action here is also in the Command Palette, so you can skip all of this and
    # still use the fork.
    # ----------------------------------------------------------------------------
    # Split reorganization (fork-only actions), on a non-prefix combo:
    #keybind = ctrl+cmd+shift+f=flip_split:horizontal
    #keybind = ctrl+cmd+shift+v=flip_split:vertical
    #keybind = ctrl+cmd+shift+h=toggle_split_direction:horizontal
    #keybind = ctrl+cmd+shift+u=toggle_split_direction:vertical
    #keybind = ctrl+cmd+shift+t=move_split_to_new_tab
    #keybind = ctrl+cmd+shift+right=merge_tabs:next_horizontal
    #keybind = ctrl+cmd+shift+down=merge_tabs:next_vertical
    #keybind = ctrl+cmd+shift+left=merge_tabs:previous_horizontal
    #keybind = ctrl+cmd+shift+up=merge_tabs:previous_vertical
    #
    # tmux-shaped `ctrl+a` prefix layer — fork-specific actions:
    #keybind = ctrl+a>q=mark_split
    #keybind = ctrl+a>shift+q=clear_split_mark
    #keybind = ctrl+a>m=pull_marked_split:auto
    #keybind = ctrl+a>shift+!=move_split_to_new_tab
    #keybind = ctrl+a>f=toggle_project_selector
    #keybind = ctrl+a>d=toggle_agent_dashboard
    #keybind = ctrl+a>shift+d=hide_dashboard_split
    # Spotlight the focused split at the top of the dashboard (find "the agent I'm
    # looking at"). shift+p because ctrl+a>p is previous_tab.
    #keybind = ctrl+a>shift+p=spotlight_dashboard_split
    #keybind = ctrl+a>ctrl+shift+p=spotlight_dashboard_split
    # One-key project launchers — open a new tab with cwd set to a project:
    #keybind = ctrl+a>g=new_tab:~/git/your-project
    #keybind = ctrl+a>i=new_tab:~/git/another-project
    # Panes / splits:
    #keybind = ctrl+a>shift+%=new_split:right
    #keybind = ctrl+a>shift+@=new_split:right
    #keybind = ctrl+a>shift+"=new_split:down
    #keybind = ctrl+a>left=goto_split:left
    #keybind = ctrl+a>right=goto_split:right
    #keybind = ctrl+a>up=goto_split:up
    #keybind = ctrl+a>down=goto_split:down
    #keybind = ctrl+a>o=goto_split:next
    #keybind = ctrl+a>;=goto_split:previous
    #keybind = ctrl+a>x=close_surface
    #keybind = ctrl+a>z=toggle_split_zoom
    #keybind = ctrl+a>space=equalize_splits
    #keybind = ctrl+a>shift+{=swap_split:previous
    #keybind = ctrl+a>shift+}=swap_split:next
    #keybind = repeatable:ctrl+a>h=resize_split:left,10
    #keybind = repeatable:ctrl+a>j=resize_split:down,10
    #keybind = repeatable:ctrl+a>k=resize_split:up,10
    #keybind = repeatable:ctrl+a>l=resize_split:right,10
    #keybind = repeatable:ctrl+a>shift+h=resize_split:left,50
    #keybind = repeatable:ctrl+a>shift+j=resize_split:down,50
    #keybind = repeatable:ctrl+a>shift+k=resize_split:up,50
    #keybind = repeatable:ctrl+a>shift+l=resize_split:right,50
    # Tabs / windows:
    #keybind = ctrl+a>c=new_tab
    #keybind = ctrl+a>n=next_tab
    #keybind = ctrl+a>p=previous_tab
    #keybind = ctrl+a>shift+&=close_tab
    #keybind = ctrl+a>,=prompt_tab_title
    #keybind = ctrl+a>w=toggle_tab_overview
    #keybind = ctrl+a>1=goto_tab:1
    #keybind = ctrl+a>2=goto_tab:2
    #keybind = ctrl+a>3=goto_tab:3
    #keybind = ctrl+a>4=goto_tab:4
    #keybind = ctrl+a>5=goto_tab:5
    #keybind = ctrl+a>6=goto_tab:6
    #keybind = ctrl+a>7=goto_tab:7
    #keybind = ctrl+a>8=goto_tab:8
    #keybind = ctrl+a>9=goto_tab:9
    # Misc:
    #keybind = ctrl+a>ctrl+a=goto_last_surface
    #keybind = ctrl+a>shift+:=toggle_command_palette
    #keybind = ctrl+a>r=reload_config

    """
}

