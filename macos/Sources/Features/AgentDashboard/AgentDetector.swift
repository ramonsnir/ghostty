import Foundation

/// (ramon fork / Agent Dashboard, Layer 3) The kind of CLI agent detected
/// running as a terminal surface's foreground process.
///
/// `command` is the matched executable basename (e.g. `claude`, `codex`) so the
/// UI can render the badge label directly and arbitrary configured commands work
/// without a fixed enum.
struct AgentKind: Equatable, Hashable {
    let command: String
    init(_ command: String) { self.command = command }
}

/// Interpreters whose argv0 is the *runtime*, not the agent — so for these we
/// also scan the command's remaining tokens for an agent basename. Catches a
/// node-wrapped agent (e.g. Codex: foreground process is `node`, command is
/// `node /…/bin/codex`). Native agents (Claude is a Mach-O binary) match
/// directly on the foreground process name and never need this.
private let agentInterpreters: Set<String> = [
    "node", "deno", "bun", "python", "python3", "ruby",
]

private func basename(_ s: String) -> String { (s as NSString).lastPathComponent }
private func basename(_ s: Substring) -> String { (String(s) as NSString).lastPathComponent }

/// The PURE agent matcher. Drives off the HOST-RESOLVED foreground process name +
/// command line — NOT a local process-tree walk. This is the load-bearing fix for
/// the pty-host backend: under `.client` the agent runs on `ghostty-host`, not the
/// GUI, so the surface has no GUI-local pid (`ghostty_surface_foreground_pid` is 0)
/// and a libproc walk finds nothing. The host instead resolves the foreground
/// process name + command and pushes them (the same data the MCP `list_surfaces`
/// poll uses); `SurfaceView.foregroundProcessName` / `.foregroundCommand` surface
/// them and work under BOTH `.client` (host-resolved) and `.exec` (local).
///
/// Match order (first hit wins, basename-compared):
///   1. foreground process basename ∈ `commands` (e.g. `claude`, or a native
///      `codex` binary);
///   2. the command's argv0 basename ∈ `commands`;
///   3. the foreground process (or argv0) is a known INTERPRETER and a later
///      command token's basename ∈ `commands` (node-wrapped agents).
///
/// Returns nil when both inputs are unavailable (e.g. an old host that hasn't
/// pushed process info yet) — the surface simply isn't classified as an agent.
func matchAgent(processName: String?, command: String?, commands: Set<String>) -> AgentKind? {
    guard !commands.isEmpty else { return nil }

    // 1) foreground process basename.
    if let n = processName, !n.isEmpty {
        let b = basename(n)
        if commands.contains(b) { return AgentKind(b) }
    }

    // Tokenize the command line (whitespace-split — adequate for our exe paths).
    let tokens = (command ?? "").split(whereSeparator: { $0 == " " || $0 == "\t" })

    // 2) argv0 basename.
    if let first = tokens.first {
        let b = basename(first)
        if commands.contains(b) { return AgentKind(b) }
    }

    // 3) interpreter-wrapped: the runtime is foreground/argv0; scan the rest. This
    //    is gated on a known interpreter so a stray path arg (e.g. `vim notes/codex`)
    //    does NOT false-match.
    let procBase = processName.map(basename) ?? ""
    let argv0Base = tokens.first.map(basename) ?? ""
    if agentInterpreters.contains(procBase) || agentInterpreters.contains(argv0Base) {
        for tok in tokens.dropFirst() {
            let b = basename(tok)
            if commands.contains(b) { return AgentKind(b) }
        }
    }

    return nil
}

/// (ramon fork / Agent Dashboard, Layer 3) The off-main detection poller. Polls
/// every ~2s on a dedicated `.utility` queue. Reads a per-surface snapshot of the
/// HOST-RESOLVED foreground process name + command on MAIN (value types only) via
/// an injected provider; publishes `[UUID: AgentKind]` back on main through
/// `onResults`. Paused while the panel is hidden.
final class AgentDetector {
    /// One surface's value-type detection inputs (host-resolved; pty-host-safe).
    struct SurfaceProc: Equatable {
        let uuid: UUID
        let processName: String?
        let command: String?
        init(uuid: UUID, processName: String?, command: String?) {
            self.uuid = uuid
            self.processName = processName
            self.command = command
        }
    }

    /// Cache key: re-match only when the resolved name OR command changes.
    struct ProcKey: Equatable {
        let processName: String?
        let command: String?
    }

    /// The configured command set (exe basenames). Read once at construction
    /// (relaunch to change, matching the WebMonitor stance).
    private let commands: Set<String>
    private let queue = DispatchQueue(label: "agent-dashboard.detector", qos: .utility)
    private let interval: TimeInterval

    /// Published on main with the latest results.
    var onResults: (([UUID: AgentKind]) -> Void)?

    private var timer: DispatchSourceTimer?
    private var snapshotProvider: (() -> [SurfaceProc])?

    /// Per-UUID cache keyed by (processName, command): skip re-matching a stable
    /// surface; re-match when either changes.
    private var cache: [UUID: (key: ProcKey, kind: AgentKind?)] = [:]

    init(commands: Set<String>, interval: TimeInterval = 2.0) {
        self.commands = commands
        self.interval = interval
    }

    /// Begin polling. `snapshotProvider` is invoked on MAIN (the tick hops there
    /// via `DispatchQueue.main.sync`); matching runs off-main on `queue`.
    ///
    /// `snapshotProvider`/`timer`/`cache` are ALL confined to `queue` — `resume`
    /// and `pause` hop onto it before touching them, and `tick()` runs on it — so
    /// there is no cross-queue field race (no lock needed).
    func resume(snapshotProvider: @escaping () -> [SurfaceProc]) {
        queue.async { [weak self] in
            guard let self else { return }
            self.snapshotProvider = snapshotProvider
            guard self.timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now(), repeating: self.interval)
            t.setEventHandler { [weak self] in self?.tick() }
            self.timer = t
            t.resume()
        }
    }

    func pause() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    private func tick() {
        guard let provider = snapshotProvider else { return }
        // Snapshot the live surfaces on main (value types only).
        let snapshot = DispatchQueue.main.sync { provider() }

        let (results, nextCache) = AgentDetector.resolve(
            snapshot: snapshot,
            cache: cache,
            commands: commands
        )
        cache = nextCache

        DispatchQueue.main.async { [weak self] in self?.onResults?(results) }
    }

    /// PURE per-tick resolution, factored out of `tick()` so the cache behavior
    /// (skip-match on unchanged name/command, re-match on change, drop vanished
    /// ids) is unit-testable with a fixed snapshot. No syscalls.
    static func resolve(
        snapshot: [SurfaceProc],
        cache: [UUID: (key: ProcKey, kind: AgentKind?)],
        commands: Set<String>
    ) -> (results: [UUID: AgentKind], cache: [UUID: (key: ProcKey, kind: AgentKind?)]) {
        var results: [UUID: AgentKind] = [:]
        var nextCache: [UUID: (key: ProcKey, kind: AgentKind?)] = [:]
        for s in snapshot {
            let key = ProcKey(processName: s.processName, command: s.command)
            if let cached = cache[s.uuid], cached.key == key {
                nextCache[s.uuid] = cached
                if let kind = cached.kind { results[s.uuid] = kind }
                continue
            }
            let kind = matchAgent(processName: s.processName, command: s.command, commands: commands)
            nextCache[s.uuid] = (key, kind)
            if let kind { results[s.uuid] = kind }
        }
        return (results, nextCache)
    }
}
