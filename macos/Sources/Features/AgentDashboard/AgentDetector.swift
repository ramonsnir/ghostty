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

        // PATH-COMPONENT test. The libproc impl stores the FULL exe path; we match
        // if ANY path component equals a configured command. This catches both a
        // clean basename (`/…/bin/codex` -> "codex") AND a versioned/wrapped
        // install whose basename is NOT the command — Claude's exe is
        // `/…/share/claude/versions/2.1.181` (basename "2.1.181"), but "claude" is
        // a path component. (Fixtures store a bare basename, which is a one-element
        // path and matches the same way.)
        for comp in entry.name.split(separator: "/") where commands.contains(String(comp)) {
            return AgentKind(String(comp))
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
        // Robust child enumeration: `proc_listchildpids` is unreliable on macOS
        // (its NULL-sizing call and byte-count contract don't behave), so build a
        // ppid -> [children] map ONCE from the full pid list via proc_pidinfo
        // parent links, then BFS from rootPID. `name` is the FULL exe path
        // (matchAgent does path-component matching), since a versioned install's
        // basename isn't the command name.
        let childrenOf = Self.childrenMap()
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

            let children: [pid_t] = depth < maxDepth ? (childrenOf[pid] ?? []) : []
            result[pid] = (name: Self.exePath(pid), children: children)
            for c in children where !visited.contains(c) {
                queue.append((c, depth + 1))
            }
        }
        return result
    }

    func snapshot(rootPID: pid_t) -> ProcSnapshot {
        snapshot(rootPID: rootPID, maxDepth: 4)
    }

    /// The full executable path (proc_pidpath), or proc_name, or "". NOT
    /// basenamed — matchAgent matches on path components (a versioned install
    /// like `/…/claude/versions/2.1.181` has the command only as a component).
    private static func exePath(_ pid: pid_t) -> String {
        var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        if proc_pidpath(pid, &pathBuf, UInt32(MAXPATHLEN)) > 0 {
            let path = String(cString: pathBuf)
            if !path.isEmpty { return path }
        }
        var nameBuf = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        if proc_name(pid, &nameBuf, UInt32(nameBuf.count)) > 0 {
            return String(cString: nameBuf)
        }
        return ""
    }

    /// Build pid -> [direct child pids] from the live process table. Uses
    /// proc_listpids(PROC_ALL_PIDS) + proc_pidinfo(PROC_PIDTBSDINFO) parent links
    /// — reliable, unlike proc_listchildpids. ~one proc_pidinfo per process; only
    /// invoked when a surface's foreground pid CHANGES (the resolve cache skips
    /// stable surfaces), so it is not a per-tick cost.
    private static func childrenMap() -> [pid_t: [pid_t]] {
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard needed > 0 else { return [:] }
        let cap = Int(needed) / MemoryLayout<pid_t>.size + 64
        var pids = [pid_t](repeating: 0, count: cap)
        let got = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(cap * MemoryLayout<pid_t>.size))
        guard got > 0 else { return [:] }
        let count = min(Int(got) / MemoryLayout<pid_t>.size, cap)
        var map: [pid_t: [pid_t]] = [:]
        let sz = Int32(MemoryLayout<proc_bsdinfo>.size)
        for i in 0..<count {
            let p = pids[i]
            if p <= 0 { continue }
            var bi = proc_bsdinfo()
            guard proc_pidinfo(p, PROC_PIDTBSDINFO, 0, &bi, sz) == sz else { continue }
            let ppid = pid_t(bi.pbi_ppid)
            map[ppid, default: []].append(p)
        }
        return map
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
    /// (skip-walk on a POSITIVE unchanged pid, re-walk otherwise, drop vanished
    /// ids) is unit-testable with an injected enumerator + fixed snapshot.
    /// Returns the published results and the next cache. No syscalls of its own —
    /// all process walks go through `enumerator`.
    ///
    /// NEGATIVE (non-agent) results are deliberately NOT cached across ticks. A
    /// long-lived foreground process can spawn an agent CHILD later WITHOUT its
    /// pid changing — e.g. the claude-accounts pool keeps `bash …/claude-pool` as
    /// the stable tty foreground-group leader (`tcgetpgrp`) and starts/replaces
    /// the `claude` child underneath it. Caching the nil from a walk that ran
    /// before the child existed would hide that agent FOREVER (the pid never
    /// changes, so a pid-keyed cache never re-walks). So we only fast-path a
    /// surface already POSITIVELY identified at the same pid; everything else is
    /// re-walked each tick. (codex doesn't hit the bug because its `node` leader
    /// has the codex child from the start — its first walk is already positive.)
    static func resolve(
        snapshot: [(uuid: UUID, pid: pid_t)],
        cache: [UUID: (pid: pid_t, kind: AgentKind?)],
        commands: Set<String>,
        enumerator: ProcEnumerator
    ) -> (results: [UUID: AgentKind], cache: [UUID: (pid: pid_t, kind: AgentKind?)]) {
        var results: [UUID: AgentKind] = [:]
        var nextCache: [UUID: (pid: pid_t, kind: AgentKind?)] = [:]
        for (uuid, pid) in snapshot {
            // Fast-path ONLY a stable, already-positive surface. A nil-cached
            // surface (same pid, no agent yet) falls through and re-walks.
            if let cached = cache[uuid], cached.pid == pid, let kind = cached.kind {
                nextCache[uuid] = cached
                results[uuid] = kind
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
