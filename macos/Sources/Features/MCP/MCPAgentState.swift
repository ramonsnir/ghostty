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

    /// Parse the hook POST body. Returns nil on missing/blank `tty`, missing/unknown
    /// `state`, non-object JSON, or a body that does not decode as UTF-8 JSON.
    /// `prompt`/`tool`/`message` are optional; `prompt`/`message` are truncated to
    /// `maxStringLen` (default 2000) so an enormous prompt can't bloat the payload.
    /// `state` strings accepted: "working", "waiting", "idle" (case-insensitive).
    static func parse(_ body: Data, maxStringLen: Int = 2000) -> AgentStatePayload? {
        guard !body.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: body),
              let dict = obj as? [String: Any]
        else { return nil }

        // tty: required, non-blank.
        guard let ttyRaw = dict["tty"] as? String else { return nil }
        let tty = ttyRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tty.isEmpty else { return nil }

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

        return AgentStatePayload(
            tty: tty,
            state: state,
            prompt: optionalString("prompt", cap: maxStringLen),
            tool: optionalString("tool", cap: 256),
            message: optionalString("message", cap: maxStringLen))
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
}
