// (ramon fork / Agent Manager) The Swift glue that spawns + supervises the
// TypeScript Agent SDK sidecar (`macos/agent-manager/`, NOT in the xcodeproj).
// The sidecar is the brain (it drives Ghostty's MCP server as a tool provider);
// this controller is its lifecycle owner: it decides whether to start at all
// (the §8 SELF-DISABLE gate), spawns the `node` process, supervises it with a
// bounded restart backoff, and tears it down on quit. Fork-only, OFF by default.
//
// Phase 0 SCOPE: round-trip plumbing only. There is NO manager/coordinator LLM
// logic here, no autonomous send, no summarization — the sidecar is a skeleton
// that proves a surface read + an annotation write round-trips back to the tile.
// The two TESTABLE units (the start decision + the restart backoff) are PURE
// static helpers, unit-tested in `AgentManagerControllerTests`.
//
// THREADING: everything that touches `Process` runs on a dedicated background
// serial queue (never main), mirroring the off-main lifecycle of the other fork
// servers. The controller itself is created on main (AppDelegate) and reads the
// `Ghostty.Config` getters on main before hopping off.
//
// VISIBILITY DEPENDENCY: agent-manager produces a VISIBLE effect only when
// `agent-dashboard` is ALSO enabled. The sidecar's annotations (and the
// `list_surfaces` `notes`/`agentState` enrichment) land on `AgentDashboardModel`,
// which the GUI only creates when the dashboard is on. So with agent-manager on
// but agent-dashboard off, the gate still passes and the sidecar runs and writes
// annotations — but they have no model to render and no tile to appear in (honest
// absence, no crash). The two are deliberately decoupled in the start gate (the §8
// truth table is enable + mcp-listen + mcp-token + node, NOT agent-dashboard) so
// the gate stays a stable, testable contract; the dependency is documented here
// and in the design doc instead of folded into the gate.

import Foundation
import os

final class AgentManagerController {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty",
        category: "agent-manager")

    /// Whether the master enable is set. Captured on main at init.
    private let enabled: Bool
    /// The configured MCP bind spec (`addr:port`) — the sidecar's only transport.
    /// Empty ⇒ Agent Manager self-disables (no MCP, no brain).
    private let mcpListen: String
    /// The MCP shared secret. Must be non-empty for the sidecar to authenticate.
    private let mcpToken: String
    /// An absolute `node` path from config, or nil to fall back to a login-shell
    /// probe (`PATH` is not inherited by a GUI app — see §8 GOTCHA).
    private let configuredNodePath: String?

    /// (ramon fork / Bell Attention) When true the controller arms the sidecar's
    /// bell-promotion pass via `GHOSTTY_BELL_FILTER=1` (else it stays a no-op and the
    /// sidecar does no bell-edge work). Captured on main at init.
    private let bellFilterEnabled: Bool
    /// (Agent Queue Supervisor §8a/§15) Master enable for the sidecar's queue
    /// supervisor "pass 3". Captured on main at init. When true the controller
    /// arms the sidecar via `GHOSTTY_AGENT_QUEUE=1` (else pass 3 stays a no-op).
    private let agentQueueEnabled: Bool
    /// The configured queue templates dir (nil ⇒ the sidecar's built-in default).
    /// Plumbed verbatim so the palette's discovery dir and the sidecar's loader
    /// never desync.
    private let agentQueueTemplatesDir: String?
    /// The global fleet-wide concurrency cap across all queue runs (default 8).
    private let agentQueueMaxTotal: UInt32

    /// The directory the sidecar lives in (`<app>/Contents/Resources/agent-manager`
    /// in a bundle; the source tree's `macos/agent-manager` during dev). Resolved
    /// lazily because it is only needed once we've decided to start.
    private let sidecarDir: URL

    /// The MCP server's per-identity port offset, so the sidecar connects to THIS
    /// build's MCP port (Release +0 / ReleaseLocal +1 / Debug +2), matching how
    /// `MCPServer` shifts its own bind. Captured on main at init.
    private let mcpPortOffset: UInt16

    // INVARIANT: the `Process` and all supervision state below are touched ONLY
    // on this dedicated serial queue, never main.
    private let queue = DispatchQueue(label: "com.mitchellh.ghostty-ramon.agent-manager")
    private var process: Process?
    /// Consecutive crash count, driving the restart backoff. Reset to 0 on a
    /// process that ran past `restartHealthyRunInterval` before exiting.
    private var restartCount = 0
    /// A scheduled restart work item, cancelled on teardown.
    private var pendingRestart: DispatchWorkItem?
    /// Set true by `teardown()` so a queued restart / termination handler does not
    /// resurrect the sidecar after the app is quitting.
    private var stopped = false

    /// A process that exits in under this many seconds is treated as a crash
    /// (counts toward the backoff). One that ran longer is "healthy" — its exit
    /// resets the backoff so a long-lived sidecar that finally dies restarts fast.
    static let restartHealthyRunInterval: TimeInterval = 30
    /// Hard ceiling on consecutive restarts before we give up (until next launch).
    static let restartMaxAttempts = 8

    init(ghostty: Ghostty.App) {
        self.enabled = ghostty.config.agentManagerEnabled
        self.mcpListen = ghostty.config.mcpListen
        self.mcpToken = ghostty.config.mcpToken
        self.configuredNodePath = ghostty.config.agentManagerNodePath
        self.bellFilterEnabled = ghostty.config.agentManagerBellFilter
        self.agentQueueEnabled = ghostty.config.agentQueueEnabled
        self.agentQueueTemplatesDir = ghostty.config.agentQueueTemplatesDir
        self.agentQueueMaxTotal = ghostty.config.agentQueueMaxTotal
        self.mcpPortOffset = MCPServer.portOffset(forBundleID: Bundle.main.bundleIdentifier)
        self.sidecarDir = Self.resolveSidecarDir()
    }

    // MARK: - Lifecycle

    /// Entry point (called on main by AppDelegate). Hops off-main IMMEDIATELY so
    /// the node probe (a login-shell spawn) never blocks the main thread, then
    /// runs the §8 self-disable gate: on a "no", logs EXACTLY ONE info line and
    /// stays fully dormant (no spawn). All config inputs were captured on main at
    /// init, so this closure touches no main-only state.
    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            // Check the CHEAP, side-effect-free conditions FIRST so the default
            // (overwhelmingly common) off-fork stays FULLY DORMANT — never spawning
            // the login-shell node probe just to discover it's disabled. The node
            // probe runs only once at-least-one-feature + mcp-listen + mcp-token are
            // all green. The sidecar is shared infra: launch it when EITHER the
            // summarizer (agent-manager) OR the queue (agent-queue) is enabled.
            guard self.enabled || self.agentQueueEnabled,
                  !self.mcpListen.isEmpty, !self.mcpToken.isEmpty else {
                self.logger.info("Agent Manager/Queue disabled: \(Self.sidecarDisabledReason(managerEnabled: self.enabled, queueEnabled: self.agentQueueEnabled, mcpListen: self.mcpListen, mcpToken: self.mcpToken, nodePath: nil), privacy: .public)")
                return
            }
            let nodePath = self.resolveNodePath()
            let should = Self.sidecarShouldStart(
                managerEnabled: self.enabled, queueEnabled: self.agentQueueEnabled,
                mcpListen: self.mcpListen, mcpToken: self.mcpToken, nodePath: nodePath)
            guard should, let nodePath else {
                // EXACTLY ONE info-level line stating WHY we're dormant (never an
                // error / notification — a disabled sidecar is a normal state).
                self.logger.info("Agent Manager/Queue disabled: \(Self.sidecarDisabledReason(managerEnabled: self.enabled, queueEnabled: self.agentQueueEnabled, mcpListen: self.mcpListen, mcpToken: self.mcpToken, nodePath: nodePath), privacy: .public)")
                return
            }
            self.spawnLocked(nodePath: nodePath)
        }
    }

    /// Tear down the sidecar on app quit. Async on the queue (never `queue.sync`
    /// from main) so a spawn/termination handler in flight can't deadlock.
    func teardown() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.pendingRestart?.cancel()
            self.pendingRestart = nil
            if let p = self.process, p.isRunning {
                p.terminate()
            }
            self.process = nil
        }
    }

    // MARK: - Spawn / supervise (queue only)

    /// Launch one sidecar instance. Wires a termination handler that schedules a
    /// bounded-backoff restart unless we've been torn down. Runs on `queue`.
    private func spawnLocked(nodePath: String) {
        guard !stopped, process == nil else { return }

        let entry = sidecarDir.appendingPathComponent("dist/index.js")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: nodePath)
        proc.arguments = [entry.path]
        proc.currentDirectoryURL = sidecarDir
        proc.environment = childEnvironment(nodePath: nodePath)

        let startedAt = Date()
        proc.terminationHandler = { [weak self] p in
            guard let self else { return }
            // Hop back onto our serial queue: terminationHandler fires on an
            // arbitrary thread, and all supervision state is queue-confined.
            self.queue.async {
                self.handleExitLocked(ranFor: Date().timeIntervalSince(startedAt), status: p.terminationStatus)
            }
        }

        do {
            try proc.run()
            self.process = proc
            logger.info("Agent Manager sidecar started (pid \(proc.processIdentifier, privacy: .public))")
        } catch {
            // A failed launch is itself a crash for backoff purposes.
            logger.error("Agent Manager sidecar failed to launch: \(String(describing: error), privacy: .public)")
            handleExitLocked(ranFor: 0, status: -1)
        }
    }

    /// Process-exit handler (queue only): decide whether the run was healthy,
    /// update the backoff counter, and schedule a restart unless we've stopped or
    /// hit the attempt ceiling.
    private func handleExitLocked(ranFor: TimeInterval, status: Int32) {
        process = nil
        guard !stopped else { return }

        if ranFor >= Self.restartHealthyRunInterval {
            restartCount = 0  // a long, healthy run resets the backoff
        } else {
            restartCount += 1
        }

        guard restartCount <= Self.restartMaxAttempts else {
            logger.error("Agent Manager sidecar exited \(Self.restartMaxAttempts, privacy: .public)x without a healthy run — giving up until next launch")
            return
        }

        let delay = Self.restartDelay(forAttempt: restartCount)
        logger.notice("Agent Manager sidecar exited (status \(status, privacy: .public), ran \(Int(ranFor), privacy: .public)s) — restarting in \(delay, privacy: .public)s (attempt \(self.restartCount, privacy: .public))")
        // Re-resolve node for the restart (it could have moved). If it no longer
        // resolves, stand down rather than spawn a path known NOT to be executable
        // (which would just fail to launch and burn a backoff attempt) — matching
        // start()'s gate, which refuses on a nil resolve.
        guard let nodePath = resolveNodePath() else {
            logger.notice("Agent Manager: node no longer resolves — not restarting the sidecar")
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.spawnLocked(nodePath: nodePath) }
        pendingRestart = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// The env the sidecar reads (mirrors `mcp-shim`'s contract). `GHOSTTY_MCP_URL`
    /// carries the per-identity port; `GHOSTTY_AGENT_MANAGER=1` makes the agent-state
    /// hook early-exit (no hook recursion); `PATH` is extended with the node dir so
    /// the SDK's own child spawns can find node. The two FEATURE loops the shared
    /// sidecar runs are armed INDEPENDENTLY by pure, unit-testable helpers: the Haiku
    /// SUMMARIZER via `applySummarizerEnv` (`GHOSTTY_SUMMARIZER`, gated on agent-manager)
    /// and the QUEUE supervisor via `applyAgentQueueEnv` (§8a/§15, gated on agent-queue).
    /// Each is set/stripped on its own enable so one feature can run with the other off.
    private func childEnvironment(nodePath: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["GHOSTTY_MCP_URL"] = Self.mcpURL(listen: mcpListen, offset: mcpPortOffset)
        env["GHOSTTY_MCP_TOKEN"] = mcpToken
        env["GHOSTTY_AGENT_MANAGER"] = "1"
        // (ramon fork / Bell Attention) Arm the sidecar's bell-promotion pass when
        // the feature is on; absent ⇒ the sidecar does no bell-edge work.
        if bellFilterEnabled { env["GHOSTTY_BELL_FILTER"] = "1" }
        let nodeDir = (nodePath as NSString).deletingLastPathComponent
        if !nodeDir.isEmpty {
            let existing = env["PATH"] ?? ""
            env["PATH"] = existing.isEmpty ? nodeDir : "\(nodeDir):\(existing)"
        }
        env = Self.applySummarizerEnv(into: env, enabled: enabled)
        env = Self.applyAgentQueueEnv(
            into: env,
            enabled: agentQueueEnabled,
            templatesDir: agentQueueTemplatesDir,
            maxTotal: agentQueueMaxTotal)
        return env
    }

    /// (Agent Manager) Layer the SUMMARIZER enable onto the sidecar env. PURE +
    /// unit-tested. The Haiku tile summarizer runs in the sidecar ONLY when
    /// `agent-manager` is enabled; the queue supervisor is armed independently
    /// (`applyAgentQueueEnv`). So the shared sidecar can run the queue ALONE with the
    /// (Haiku-billing) summarizer fully silent. We set the flag EXPLICITLY both ways —
    /// `enabled` ⇒ `GHOSTTY_SUMMARIZER=1`, disabled ⇒ `GHOSTTY_SUMMARIZER=0` — rather
    /// than stripping it (unlike `applyAgentQueueEnv`). This is deliberate for
    /// BACK-COMPAT: the summarizer was previously UNCONDITIONAL (no env), so the
    /// sidecar treats an ABSENT flag as ON. An OLD GUI that respawns a NEW `dist`
    /// (transient during an upgrade) sets no flag ⇒ summarizer stays on (no
    /// regression); only this NEW GUI, with agent-manager off, writes the explicit
    /// `0` that turns it off. An explicit `0` also defeats a stray inherited `1`.
    static func applySummarizerEnv(into env: [String: String], enabled: Bool) -> [String: String] {
        var env = env
        env["GHOSTTY_SUMMARIZER"] = enabled ? "1" : "0"
        return env
    }

    /// (Agent Queue Supervisor §8a/§15) Layer the queue-supervisor env onto the
    /// sidecar's environment. PURE + unit-tested. When `enabled` is false the env
    /// is returned UNCHANGED (and any stray inherited `GHOSTTY_AGENT_QUEUE*` keys
    /// are stripped so a disabled controller can't accidentally arm pass 3 via the
    /// parent process environment). When enabled it sets:
    ///   - `GHOSTTY_AGENT_QUEUE=1` (the master enable the sidecar's pass-3 gate reads),
    ///   - `GHOSTTY_AGENT_QUEUE_TEMPLATES_DIR` (only when a non-empty templates dir is
    ///     configured — absent ⇒ the sidecar falls back to its built-in default, which
    ///     matches the palette's default discovery dir, so they never desync). A `~`-prefixed
    ///     dir is TILDE-EXPANDED here (same `expandingTildeInPath` the palette's
    ///     `discoverTemplates` uses), so the palette and the sidecar resolve the SAME
    ///     absolute dir — the sidecar does no `~` expansion of its own (Node `path.join`
    ///     would treat `~` as a literal relative segment),
    ///   - `GHOSTTY_AGENT_QUEUE_MAX_TOTAL` (the global fleet cap, as a decimal string).
    static func applyAgentQueueEnv(
        into env: [String: String],
        enabled: Bool,
        templatesDir: String?,
        maxTotal: UInt32
    ) -> [String: String] {
        var env = env
        guard enabled else {
            // Defensively drop any inherited queue keys: a disabled supervisor must
            // never arm pass 3, even if the parent process happened to export them.
            env.removeValue(forKey: "GHOSTTY_AGENT_QUEUE")
            env.removeValue(forKey: "GHOSTTY_AGENT_QUEUE_TEMPLATES_DIR")
            env.removeValue(forKey: "GHOSTTY_AGENT_QUEUE_MAX_TOTAL")
            return env
        }
        env["GHOSTTY_AGENT_QUEUE"] = "1"
        env["GHOSTTY_AGENT_QUEUE_MAX_TOTAL"] = String(maxTotal)
        if let dir = templatesDir, !dir.isEmpty {
            // Expand `~` to an absolute path so this matches the palette's
            // `discoverTemplates` (which also `expandingTildeInPath`s) and the sidecar —
            // which does NO tilde expansion — resolves the identical dir. (An already-
            // absolute path passes through unchanged.)
            env["GHOSTTY_AGENT_QUEUE_TEMPLATES_DIR"] = (dir as NSString).expandingTildeInPath
        } else {
            // No explicit dir ⇒ let the sidecar's built-in default win; ensure no
            // stale inherited value points it elsewhere.
            env.removeValue(forKey: "GHOSTTY_AGENT_QUEUE_TEMPLATES_DIR")
        }
        return env
    }

    // MARK: - node resolution

    /// Resolve the `node` binary: the configured absolute path if it exists, else
    /// a login-shell probe (a GUI app does not inherit the shell `PATH`). Returns
    /// nil when neither yields an executable. Cheap; called at start + each restart.
    private func resolveNodePath() -> String? {
        if let p = configuredNodePath, FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        return Self.probeNodeViaLoginShell()
    }

    /// Run the user's login shell to print `node`'s resolved path (so the GUI sees
    /// the same `node` the terminal would). Best-effort + bounded; returns nil on
    /// any failure.
    private static func probeNodeViaLoginShell() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        // -l so the login shell sources the user's PATH; `command -v` is POSIX.
        proc.arguments = ["-l", "-c", "command -v node"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return nil
        }
        guard proc.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    /// Where the sidecar lives. In a packaged app it is bundled under
    /// `Contents/Resources/agent-manager`; during dev it is the source-tree sibling
    /// `macos/agent-manager` (derived from this file's path at compile time). The
    /// bundled location wins when present.
    private static func resolveSidecarDir() -> URL {
        if let res = Bundle.main.resourceURL {
            let bundled = res.appendingPathComponent("agent-manager")
            if FileManager.default.fileExists(atPath: bundled.path) {
                return bundled
            }
        }
        // Dev fallback: this file is macos/Sources/Features/AgentManager/<this>.swift,
        // so the sidecar is ../../../agent-manager relative to it.
        let thisFile = URL(fileURLWithPath: #filePath)
        return thisFile
            .deletingLastPathComponent()  // AgentManager
            .deletingLastPathComponent()  // Features
            .deletingLastPathComponent()  // Sources
            .deletingLastPathComponent()  // macos
            .appendingPathComponent("agent-manager")
    }

    // MARK: - Pure helpers (unit-tested)

    /// The §8 SELF-DISABLE gate (HARD requirement, unit-tested). The sidecar is
    /// SHARED INFRA for two independent features — the Haiku SUMMARIZER (agent-manager)
    /// and the QUEUE supervisor (agent-queue) — so it starts when EITHER is enabled,
    /// not only agent-manager. All of: at least one feature is on; an MCP bind address
    /// is configured (the sidecar's only transport); an MCP token is set (the sidecar
    /// must authenticate); AND a `node` binary resolved. Any false ⇒ stay dormant.
    /// Which feature(s) actually RUN inside the launched sidecar is decided separately
    /// by the per-feature env flags (`applySummarizerEnv` / `applyAgentQueueEnv`), so
    /// the two work independently — e.g. agent-queue on + agent-manager off launches the
    /// sidecar with the queue armed and the (Haiku-billing) summarizer fully silent.
    static func sidecarShouldStart(
        managerEnabled: Bool, queueEnabled: Bool,
        mcpListen: String?, mcpToken: String?, nodePath: String?
    ) -> Bool {
        guard managerEnabled || queueEnabled else { return false }
        guard let listen = mcpListen, !listen.isEmpty else { return false }
        guard let token = mcpToken, !token.isEmpty else { return false }
        guard let node = nodePath, !node.isEmpty else { return false }
        return true
    }

    /// The single human-readable reason the gate refused, for the one info line.
    /// Order matches `sidecarShouldStart` so the first failing condition wins.
    static func sidecarDisabledReason(
        managerEnabled: Bool, queueEnabled: Bool,
        mcpListen: String?, mcpToken: String?, nodePath: String?
    ) -> String {
        if !managerEnabled && !queueEnabled { return "agent-manager and agent-queue are both off" }
        if (mcpListen ?? "").isEmpty { return "mcp-listen is not set" }
        if (mcpToken ?? "").isEmpty { return "mcp-token is not set" }
        if (nodePath ?? "").isEmpty { return "node could not be resolved" }
        return "unknown"
    }

    /// Bounded exponential restart backoff (unit-tested). attempt 1 ⇒ 1s, then
    /// doubles (2, 4, 8, …) and is clamped at `restartDelayMax`. Pure over the
    /// attempt number so the supervision policy is testable without spawning.
    static let restartDelayBase: TimeInterval = 1
    static let restartDelayMax: TimeInterval = 30
    static func restartDelay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt >= 1 else { return restartDelayBase }
        // 2^(attempt-1) without risking Double overflow for large attempts: cap
        // the exponent so the shift stays well within range, then clamp.
        let exp = min(attempt - 1, 16)
        let delay = restartDelayBase * pow(2.0, Double(exp))
        return min(delay, restartDelayMax)
    }

    /// Build the `GHOSTTY_MCP_URL` the sidecar connects to: the configured
    /// `mcp-listen` host:port with the per-identity offset applied, as an
    /// `http://…/mcp` URL. Pure + testable. A `0.0.0.0`/`*`/empty host is
    /// rewritten to loopback (the sidecar always connects locally — the bind
    /// wildcard is not a reachable client host). Falls back to the default
    /// loopback URL when the spec can't be parsed.
    static let mcpDefaultPort: UInt16 = 8765
    static func mcpURL(listen: String, offset: UInt16) -> String {
        guard let shifted = MCPServer.applyPortOffset(MCPServer.parseListen(listen), offset: offset) else {
            // Unparseable spec: fall back to the loopback default, but STILL apply
            // the per-identity offset so a ReleaseLocal/Debug sidecar targets its
            // own MCP port (8766/8767), not the Release port — never silently
            // mis-targeting another identity's server.
            let port = mcpDefaultPort &+ offset
            return "http://127.0.0.1:\(port)/mcp"
        }
        var host = shifted.host
        if host.isEmpty || host == "0.0.0.0" || host == "*" || host == "::" {
            host = "127.0.0.1"
        }
        // Bracket a bare IPv6 host for the URL authority.
        let authorityHost = host.contains(":") ? "[\(host)]" : host
        return "http://\(authorityHost):\(shifted.port)/mcp"
    }
}
