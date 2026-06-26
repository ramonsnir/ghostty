import Foundation

/// (ramon fork / Bell Attention v2) Append-only JSONL diagnostics for the bell →
/// attention lifecycle.
///
/// WHY: bells/promotions can feel random ("why did it just fire?", "why didn't it fire
/// an hour ago?"). This records the full per-surface timeline to ONE file shared with
/// the Agent Manager sidecar (which appends its own `classify`/`alert` lines), so a
/// single read reconstructs what happened and when. The GUI records `ring` (every bell,
/// with focus), `attention` (every set_attention, with the sidecar's reason + whether it
/// was applied or suppressed by focus), and `clear` (focus cleared a pending bell/attn).
///
/// Off by default (config `bell-diagnostics`); each call site checks the flag and passes
/// already-extracted PRIMITIVES (no AppKit types) so this file stays pure Foundation and
/// needs no Xcode target exclusion. Best-effort: any fs error is swallowed, never thrown
/// into the bell/focus path. Writes happen on a background queue with an O_APPEND fd so
/// GUI and sidecar appends interleave atomically at line granularity.
enum BellDiagnostics {
    /// `~/Library/Logs/ghostty-ramon-bell-diagnostics.jsonl` — mirrors the host /
    /// agent-manager log locations. Kept in sync with the sidecar's `diagPath()`.
    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ghostty-ramon-bell-diagnostics.jsonl")
    }

    private static let queue = DispatchQueue(
        label: "com.mitchellh.ghostty-ramon.bell-diagnostics")

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// PURE: build one JSONL line for `event` with `fields`. `src` is always "gui";
    /// `ts`/`src`/`ev` are reserved and overwrite any same-named entry in `fields`.
    /// Keys are sorted so the output is deterministic (testable). Returns "{}\n" if the
    /// fields aren't JSON-serializable (best-effort — never crashes a bell). Exposed for
    /// tests.
    static func line(event: String, fields: [String: Any], nowIso: String) -> String {
        var obj = fields
        obj["ts"] = nowIso
        obj["src"] = "gui"
        obj["ev"] = event
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8)
        else { return "{}\n" }
        return s + "\n"
    }

    /// Append one event. No-op for the caller's hot path beyond formatting a string and
    /// dispatching; the actual write is off the main thread. Callers MUST gate on
    /// `config.bellDiagnostics` before calling (so a disabled feature does zero work).
    static func record(_ event: String, _ fields: [String: Any]) {
        let text = line(event: event, fields: fields, nowIso: iso.string(from: Date()))
        queue.async { append(text) }
    }

    private static func append(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        let url = fileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // O_APPEND so concurrent GUI + sidecar writes don't clobber each other.
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = write(fd, base, data.count)
        }
    }
}
