// (ramon fork / Agent hooks) Pure, unit-testable helpers backing the MCP
// `POST /agent-state` route — the Claude Code hook ingest. Nothing here touches
// AppKit, a socket, or mutable state; the one impure call (the live process
// table) is behind an injectable `TTYResolver` seam so the matcher stays
// testable. The side-effecting handler lives in `MCPServer.handleAgentState`.
//
// Flow: the hook script POSTs `{tty,state,prompt?,tool?,message?}`; `parse`
// validates it into an `AgentStatePayload` (the shared value type declared in
// `AgentStateBridge.swift`), then `resolveSurface` maps the hook's tty to a live
// surface UUID by resolving each surface's foreground pid (the host-pushed
// minor-4 pid the dashboard already consumes) to its controlling tty via libproc
// and matching the normalized tty strings.

import Foundation
import Darwin

enum MCPAgentState {

    // MARK: - Body parsing (PURE)

    /// Parse the hook POST body. Returns nil on missing/unknown `state`, non-object
    /// JSON, a body that does not decode as UTF-8 JSON, OR a body carrying NEITHER a
    /// non-blank `tty` NOR a non-blank `nonce` (a body must identify its surface by one
    /// or the other). `prompt`/`tool`/`message` are optional; `prompt`/`message` are
    /// truncated to `maxStringLen` (default 2000) so an enormous prompt can't bloat the
    /// payload. `state` strings accepted: "working", "waiting", "idle" (case-insensitive).
    /// (suspend-resume) `claudeSessionId` (the `claude --resume <id>` token) and `cwd`
    /// are optional too — captured passively from the hook, both capped.
    ///
    /// (cloud-hosts D6) A REMOTE box's hook can't name a LOCAL tty, so it POSTs a
    /// `{nonce, state}` body with NO `tty`; the `/agent-state` route resolves the nonce
    /// to a surface via `RemoteAgentIdentity`. The local tty-walk path is kept as the
    /// fallback (a body with a `tty` and no `nonce`).
    static func parse(_ body: Data, maxStringLen: Int = 2000) -> AgentStatePayload? {
        guard !body.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: body),
              let dict = obj as? [String: Any]
        else { return nil }

        // tty: OPTIONAL now (the nonce path carries none). When present it must be
        // non-blank to count as an identifier.
        let tty: String? = {
            guard let raw = dict["tty"] as? String else { return nil }
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }()

        // nonce: OPTIONAL correlation id (cloud-hosts). Non-blank to count.
        let nonce: String? = {
            guard let raw = dict["nonce"] as? String else { return nil }
            let n = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return n.isEmpty ? nil : n
        }()

        // A body must identify its surface by a tty OR a nonce — reject one with neither.
        guard tty != nil || nonce != nil else { return nil }

        // state: required, one of working/waiting/idle (case-insensitive).
        guard let stateRaw = dict["state"] as? String,
              let state = AgentState(rawValue: stateRaw.lowercased())
        else { return nil }

        // Optional string fields. prompt/message are truncated to `maxStringLen`;
        // `tool` is a short tool name, so it gets a modest fixed cap (256) just to
        // keep a pathological value from riding into `lastTool`/the tile footer.
        func optionalString(_ key: String, cap: Int) -> String? {
            guard let s = dict[key] as? String, !s.isEmpty else { return nil }
            guard s.count > cap else { return s }
            return String(s.prefix(cap))
        }

        // (suspend-resume) claudeSessionId + cwd ride EVERY Claude hook event and are
        // captured passively. Modest caps: a session id is short; a path is bounded.
        return AgentStatePayload(
            tty: tty,
            state: state,
            prompt: optionalString("prompt", cap: maxStringLen),
            tool: optionalString("tool", cap: 256),
            message: optionalString("message", cap: maxStringLen),
            nonce: nonce,
            claudeSessionId: optionalString("claudeSessionId", cap: 256),
            cwd: optionalString("cwd", cap: 4096))
    }

    // MARK: - tty normalization + match (PURE)

    /// Canonicalize a tty string for comparison. Lowercases, strips a leading
    /// "/dev/", then ensures the device-class prefix: if what remains does NOT
    /// already start with "tty" or "pts", prefix "tty".
    /// Concretely: "/dev/ttys004" -> "ttys004", "ttys004" -> "ttys004",
    /// "s004" (the `ps -o tty=` short form on some macOS) -> "ttys004".
    /// devname() returns e.g. "ttys004"; `ps -o tty=` returns "ttys004" on modern
    /// macOS but historically "s004", so we normalize both to the "ttysNNN" form.
    static func normalizeTTY(_ tty: String) -> String {
        var s = tty.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("/dev/") {
            s = String(s.dropFirst("/dev/".count))
        }
        if s.hasPrefix("tty") || s.hasPrefix("pts") {
            return s
        }
        return "tty" + s
    }

    /// True iff two tty strings name the same device after normalization. A blank
    /// (post-normalize "tty") never matches, so two missing ttys don't collide.
    static func ttyMatches(_ a: String, _ b: String) -> Bool {
        let na = normalizeTTY(a)
        let nb = normalizeTTY(b)
        guard na != "tty", nb != "tty" else { return false }
        return na == nb
    }

    // MARK: - proc → tty seam (injectable so the matcher is testable)

    /// Thin seam over the single libproc call. Production reads the live process
    /// table; tests inject a closure mapping pid -> tty name.
    typealias TTYResolver = (pid_t) -> String?

    /// Production resolver: proc_pidinfo(PROC_PIDTBSDINFO).pbi_e_tdev -> devname().
    /// Returns nil when the pid has no controlling tty or the call fails. Uses the
    /// same libproc family `AgentDetector.LibprocEnumerator` already uses.
    static func liveTTYResolver(_ pid: pid_t) -> String? {
        var bi = proc_bsdinfo()
        let sz = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bi, sz) == sz else { return nil }
        // e_tdev is the controlling-terminal device. The Darwin `proc_bsdinfo`
        // struct names this field literally `e_tdev` (it is one of the few
        // fields without the `pbi_` prefix — its sibling `pbi_ppid`, which
        // AgentDetector reads, KEEPS the prefix, so don't trust a "matching"
        // parallel). The SPEC's pinned `pbi_e_tdev` was a typo — that spelling
        // would not compile. A pid with no controlling tty reports NODEV
        // (UInt32.max) or 0; either means "no tty". `e_tdev` is UInt32;
        // reinterpret its bits as the Int32 `dev_t` devname() expects.
        let raw = bi.e_tdev
        guard raw != 0 && raw != UInt32.max else { return nil }
        let tdev = dev_t(bitPattern: raw)
        guard let c = devname(tdev, S_IFCHR) else { return nil }   // "ttys004"
        return String(cString: c)
    }

    /// PURE match (given the resolver): given the hook's tty and a snapshot of
    /// (uuid, foregroundPID), return the first surface whose foreground pid
    /// resolves (via `resolver`) to a tty that matches the hook's tty. `resolver`
    /// defaults to `liveTTYResolver`.
    ///
    /// Staleness note: the snapshot's pids come from the host-pushed foregroundPID,
    /// which can lag reality by a poll. A pid that exited and was recycled would
    /// resolve to whatever tty now owns it — but to mis-attribute, that recycled pid
    /// would have to land on the EXACT tty of another live surface, and since each
    /// Ghostty surface has its own PTY that is effectively impossible. A pid resolving
    /// to a tty that matches no hook tty simply yields nil (caller answers 200), never
    /// a wrong-surface attribution. So the worst case is a missed update, not a misfire.
    static func resolveSurface(
        forTTY hookTTY: String,
        surfaces: [(uuid: UUID, pid: pid_t)],
        resolver: TTYResolver = liveTTYResolver
    ) -> UUID? {
        for s in surfaces {
            guard let tty = resolver(s.pid) else { continue }
            if ttyMatches(hookTTY, tty) { return s.uuid }
        }
        return nil
    }

    // MARK: - Robust subtree tty resolution (login/session-leader foreground pid)

    /// PURE robust resolve, used as a FALLBACK when `resolveSurface` finds no match: for
    /// each surface, DESCEND its foreground pid's subtree (via `childrenMap`) and match any
    /// descendant's tty against `hookTTY`. This handles a foreground pid that is a `login`
    /// session leader (or other wrapper) whose OWN `proc_pidinfo().e_tdev` does not resolve
    /// to the pty — a descendant (zsh / the pool bash / claude) shares the surface's pty
    /// tty and resolves fine. Stops at the FIRST descendant that matches. Each surface's
    /// login subtree is disjoint (its own session), so a subtree match is unique to that
    /// surface. Bounded by `maxDepth` + a visited set (cycle-safe). `resolver`/`childrenMap`
    /// are injectable so this is unit-testable without the live process table.
    static func resolveSurfaceViaSubtree(
        forTTY hookTTY: String,
        surfaces: [(uuid: UUID, pid: pid_t)],
        childrenMap: [pid_t: [pid_t]],
        resolver: TTYResolver = liveTTYResolver,
        maxDepth: Int = 6
    ) -> UUID? {
        let target = normalizeTTY(hookTTY)
        guard target != "tty" else { return nil }
        for s in surfaces {
            if subtreeHasTTY(s.pid, target: target, childrenMap: childrenMap,
                             resolver: resolver, maxDepth: maxDepth) {
                return s.uuid
            }
        }
        return nil
    }

    /// DFS `root`'s subtree (through `childrenMap`) for a pid whose normalized tty equals
    /// `target`. Bounded depth; a visited set guards against a pathological cycle.
    private static func subtreeHasTTY(
        _ root: pid_t, target: String, childrenMap: [pid_t: [pid_t]],
        resolver: TTYResolver, maxDepth: Int
    ) -> Bool {
        var stack: [(pid: pid_t, depth: Int)] = [(root, 0)]
        var visited = Set<pid_t>()
        while let (pid, depth) = stack.popLast() {
            guard visited.insert(pid).inserted else { continue }
            if let tty = resolver(pid), normalizeTTY(tty) == target { return true }
            if depth < maxDepth {
                for c in childrenMap[pid] ?? [] { stack.append((c, depth + 1)) }
            }
        }
        return false
    }

    /// Build a `ppid -> [children]` map from the full process table via
    /// `proc_listpids(PROC_ALL_PIDS)` + `proc_pidinfo(PROC_PIDTBSDINFO).pbi_ppid` — the
    /// reliable method (mirrors `AgentDetector.LibprocEnumerator.childrenMap`;
    /// `proc_listchildpids` is unreliable on macOS). ~one `proc_pidinfo` per process, so
    /// the caller CACHES it (`cachedChildrenMap`) — this runs only on the fallback path.
    static func childrenMap() -> [pid_t: [pid_t]] {
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard needed > 0 else { return [:] }
        let cap = Int(needed) / MemoryLayout<pid_t>.size + 16
        var pids = [pid_t](repeating: 0, count: cap)
        let got = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids,
                                Int32(cap * MemoryLayout<pid_t>.size))
        guard got > 0 else { return [:] }
        let count = Int(got) / MemoryLayout<pid_t>.size
        var map: [pid_t: [pid_t]] = [:]
        for i in 0..<count {
            let p = pids[i]
            guard p > 0 else { continue }
            var bi = proc_bsdinfo()
            let sz = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(p, PROC_PIDTBSDINFO, 0, &bi, sz) == sz else { continue }
            map[pid_t(bi.pbi_ppid), default: []].append(p)
        }
        return map
    }

    /// A short-TTL cache over `childrenMap()` so a burst of hook events (which hit the
    /// fallback path together) shares ONE full process-table scan. Thread-safe.
    private static let childrenMapLock = NSLock()
    private static var childrenMapCache: (map: [pid_t: [pid_t]], at: Date)?
    private static let childrenMapTTL: TimeInterval = 1.5
    static func cachedChildrenMap(now: Date = Date()) -> [pid_t: [pid_t]] {
        childrenMapLock.lock()
        defer { childrenMapLock.unlock() }
        if let c = childrenMapCache, now.timeIntervalSince(c.at) < childrenMapTTL {
            return c.map
        }
        let m = childrenMap()
        childrenMapCache = (m, now)
        return m
    }
}
