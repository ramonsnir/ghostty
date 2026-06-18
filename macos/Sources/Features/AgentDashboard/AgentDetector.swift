import Foundation
import Darwin

/// (ramon fork / Agent Dashboard, Layer 3) The kind of CLI agent detected
/// running inside a terminal surface's foreground process subtree.
///
/// `rawValue` is the matched executable basename (e.g. `claude`, `codex`) so the
/// UI can render the badge label directly and arbitrary configured commands
/// work without a fixed enum.
struct AgentKind: Equatable, Hashable {
    /// The matched executable basename (lowercased for display stability is NOT
    /// applied — we keep the configured spelling).
    let command: String

    init(_ command: String) {
        self.command = command
    }
}

/// A snapshot of the process tree, injectable so the pure matcher is testable
/// without libproc. Keyed by pid; each entry carries the process's executable
/// basename and its direct children's pids.
typealias ProcSnapshot = [pid_t: (name: String, children: [pid_t])]

/// Abstracts the libproc syscalls so `matchAgent` can be unit-tested with
/// fixtures. The production implementation walks the live process table; tests
/// inject a fixed `ProcSnapshot`.
protocol ProcEnumerator {
    /// Build a snapshot rooted at `rootPID` covering it and its descendants
    /// (bounded). Implementations should cap depth/visited to stay cheap and
    /// cycle-safe.
    func snapshot(rootPID: pid_t) -> ProcSnapshot
}

/// The depth-bounded, cycle-safe pure matcher. PURE: no syscalls, no globals —
/// drives entirely off `snapshot`. Returns the first agent command found,
/// searching the root then descending breadth-first up to `maxDepth`.
///
/// - direct hit: `rootPID`'s basename is in `commands`.
/// - child hit: a descendant (e.g. shell -> node -> claude) matches.
/// - depth is bounded by `maxDepth` (default 4); a `visited` set defends against
///   cycles / self-referential trees and caps total work.
func matchAgent(
    rootPID: pid_t,
    snapshot: ProcSnapshot,
    commands: Set<String>,
    maxDepth: Int = 4
) -> AgentKind? {
    guard !commands.isEmpty else { return nil }

    var visited = Set<pid_t>()
    // Queue of (pid, depth). BFS so a shallower match wins deterministically.
    var queue: [(pid: pid_t, depth: Int)] = [(rootPID, 0)]
    var head = 0

    while head < queue.count {
        let (pid, depth) = queue[head]
        head += 1

        if visited.contains(pid) { continue }
        visited.insert(pid)
        // Defensive cap on total nodes walked (huge/looping trees).
        guard visited.count <= 4096 else { break }

        guard let entry = snapshot[pid] else { continue }

        // basename test. `entry.name` is already a basename in fixtures; the
        // libproc impl normalizes to a basename (preferring the exe path basename
        // when proc_name is truncated at MAXCOMLEN) before storing it here.
        let base = (entry.name as NSString).lastPathComponent
        if commands.contains(base) {
            return AgentKind(base)
        }

        if depth < maxDepth {
            for child in entry.children where !visited.contains(child) {
                queue.append((child, depth + 1))
            }
        }
    }

    return nil
}

/// Production libproc-backed enumerator. Reads the live process table via
/// `proc_listchildren` / `proc_name` / `proc_pidpath`. Never called from tests
/// (those inject `ProcSnapshot` directly through `matchAgent`).
struct LibprocEnumerator: ProcEnumerator {
    func snapshot(rootPID: pid_t, maxDepth: Int) -> ProcSnapshot {
        var result: ProcSnapshot = [:]
        var visited = Set<pid_t>()
        var queue: [(pid: pid_t, depth: Int)] = [(rootPID, 0)]
        var head = 0

        while head < queue.count {
            let (pid, depth) = queue[head]
            head += 1
            if visited.contains(pid) { continue }
            visited.insert(pid)
            guard visited.count <= 4096 else { break }

            let name = Self.processBasename(pid)
            let children: [pid_t] = depth < maxDepth ? Self.children(of: pid) : []
            result[pid] = (name: name, children: children)
            for c in children where !visited.contains(c) {
                queue.append((c, depth + 1))
            }
        }
        return result
    }

    func snapshot(rootPID: pid_t) -> ProcSnapshot {
        snapshot(rootPID: rootPID, maxDepth: 4)
    }

    /// Prefer the exe path basename (full, not truncated) over proc_name (capped
    /// at MAXCOMLEN). Falls back to proc_name, then "".
    private static func processBasename(_ pid: pid_t) -> String {
        var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let pathLen = proc_pidpath(pid, &pathBuf, UInt32(MAXPATHLEN))
        if pathLen > 0 {
            let path = String(cString: pathBuf)
            if !path.isEmpty {
                return (path as NSString).lastPathComponent
            }
        }

        var nameBuf = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        let nameLen = proc_name(pid, &nameBuf, UInt32(nameBuf.count))
        if nameLen > 0 {
            return String(cString: nameBuf)
        }
        return ""
    }

    private static func children(of pid: pid_t) -> [pid_t] {
        // `proc_listchildpids` (like the other `proc_list*` calls) takes a buffer
        // size in BYTES and returns the number of BYTES written (NOT a pid count);
        // its sizing call (null buffer) returns the needed byte count. We size the
        // buffer in pids from that byte count (with a little slack for races where
        // a child is forked between the two calls), then convert the returned byte
        // count back to a pid count. Every length is clamped to the buffer capacity
        // so the slice is memory-safe regardless of how the OS interprets the call.
        let pidSize = MemoryLayout<pid_t>.size
        let neededBytes = proc_listchildpids(pid, nil, 0)
        guard neededBytes > 0 else { return [] }
        // Convert bytes -> pid capacity, add a few slots of slack, and cap.
        let cap = min(Int(neededBytes) / pidSize + 8, 4096)
        guard cap > 0 else { return [] }
        var buf = [pid_t](repeating: 0, count: cap)
        let gotBytes = proc_listchildpids(pid, &buf, Int32(cap * pidSize))
        guard gotBytes > 0 else { return [] }
        let count = min(Int(gotBytes) / pidSize, cap)
        return Array(buf[0..<count]).filter { $0 > 0 }
    }
}

/// (ramon fork / Agent Dashboard, Layer 3) The off-main detection poller. Polls
/// every ~2s on a dedicated `.utility` queue, walking each surface's foreground
/// process subtree behind a `ProcEnumerator`. Reads the surface snapshot on main
/// (value types only) via an injected provider; publishes `[UUID: AgentKind]`
/// back on main through `onResults`. Paused while the panel is hidden.
final class AgentDetector {
    /// The configured command set (exe basenames). Read once at construction
    /// (relaunch to change, matching the WebMonitor stance).
    private let commands: Set<String>
    private let enumerator: ProcEnumerator
    private let queue = DispatchQueue(label: "agent-dashboard.detector", qos: .utility)
    private let interval: TimeInterval

    /// Published on main with the latest results.
    var onResults: (([UUID: AgentKind]) -> Void)?

    private var timer: DispatchSourceTimer?
    private var snapshotProvider: (() -> [(uuid: UUID, pid: pid_t)])?

    /// Per-UUID cache keyed by foregroundPID: skip re-walking a stable surface.
    private var cache: [UUID: (pid: pid_t, kind: AgentKind?)] = [:]

    init(
        commands: Set<String>,
        enumerator: ProcEnumerator = LibprocEnumerator(),
        interval: TimeInterval = 2.0
    ) {
        self.commands = commands
        self.enumerator = enumerator
        self.interval = interval
    }

    /// Begin polling. `snapshotProvider` is invoked on MAIN (the tick hops there
    /// via `DispatchQueue.main.sync`); the walk runs off-main on `queue`.
    ///
    /// `snapshotProvider`/`timer`/`cache` are ALL confined to `queue` — `resume`
    /// and `pause` hop onto it before touching them, and `tick()` runs on it — so
    /// there is no cross-queue field race (no lock needed).
    func resume(snapshotProvider: @escaping () -> [(uuid: UUID, pid: pid_t)]) {
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
            commands: commands,
            enumerator: enumerator
        )
        cache = nextCache

        DispatchQueue.main.async { [weak self] in self?.onResults?(results) }
    }

    /// PURE per-tick resolution, factored out of `tick()` so the cache behavior
    /// (skip-walk on unchanged pid, re-walk on pid change, drop vanished ids) is
    /// unit-testable with an injected enumerator + fixed snapshot. Returns the
    /// published results and the next cache. No syscalls of its own — all process
    /// walks go through `enumerator`.
    static func resolve(
        snapshot: [(uuid: UUID, pid: pid_t)],
        cache: [UUID: (pid: pid_t, kind: AgentKind?)],
        commands: Set<String>,
        enumerator: ProcEnumerator
    ) -> (results: [UUID: AgentKind], cache: [UUID: (pid: pid_t, kind: AgentKind?)]) {
        var results: [UUID: AgentKind] = [:]
        var nextCache: [UUID: (pid: pid_t, kind: AgentKind?)] = [:]
        for (uuid, pid) in snapshot {
            if let cached = cache[uuid], cached.pid == pid {
                nextCache[uuid] = cached
                if let kind = cached.kind { results[uuid] = kind }
                continue
            }
            let procSnapshot = enumerator.snapshot(rootPID: pid)
            let kind = matchAgent(rootPID: pid, snapshot: procSnapshot, commands: commands)
            nextCache[uuid] = (pid, kind)
            if let kind { results[uuid] = kind }
        }
        return (results, nextCache)
    }
}
