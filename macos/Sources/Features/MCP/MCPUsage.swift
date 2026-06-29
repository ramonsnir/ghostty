import Foundation

/// (ramon fork / Agent Manager) Haiku usage / budget aggregation for the
/// `get_haiku_usage` MCP tool.
///
/// The Agent Manager sidecar appends one JSONL line per Haiku call to
/// `~/Library/Logs/ghostty-ramon-haiku-usage.jsonl` (see `agent-manager/src/usage.ts`),
/// tagged with the FEATURE that triggered it (`summarizer` / `bell-classify`) and the
/// billed ACCOUNT. Because it is an on-disk file, totals SURVIVE GUI/sidecar restarts.
/// This type reads that file and aggregates the last N hours per feature / per account.
///
/// The heavy lifting (`aggregate`) is a PURE function over the raw lines + cutoff, so it
/// is unit-tested without touching the filesystem; `query` is the thin IO wrapper the
/// dispatch calls.
enum MCPUsage {
    /// Shared usage file — kept in sync with the sidecar's `usagePath()`.
    static func fileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ghostty-ramon-haiku-usage.jsonl")
    }

    /// ISO-8601 with fractional seconds + `Z`, byte-compatible with JavaScript
    /// `Date.toISOString()` (which the sidecar uses for `ts`). Matching the format
    /// makes the lexicographic `ts >= sinceIso` comparison correct.
    static func isoString(from date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    /// One group's running totals.
    private struct Acc {
        var calls = 0
        var inputTokens = 0
        var outputTokens = 0
        var cacheReadTokens = 0
        var cacheCreationTokens = 0
        var costUsd = 0.0

        mutating func add(_ o: [String: Any]) {
            calls += 1
            inputTokens += Self.int(o["inputTokens"])
            outputTokens += Self.int(o["outputTokens"])
            cacheReadTokens += Self.int(o["cacheReadTokens"])
            cacheCreationTokens += Self.int(o["cacheCreationTokens"])
            costUsd += Self.dbl(o["costUsd"])
        }

        static func int(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? 0 }
        static func dbl(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? 0 }

        /// JSON dict for this group. Cost rounded to 6 decimals for readable output.
        func json(extra: [String: Any]) -> [String: Any] {
            var d: [String: Any] = [
                "calls": calls,
                "inputTokens": inputTokens,
                "outputTokens": outputTokens,
                "cacheReadTokens": cacheReadTokens,
                "cacheCreationTokens": cacheCreationTokens,
                "costUsd": (costUsd * 1_000_000).rounded() / 1_000_000,
            ]
            for (k, v) in extra { d[k] = v }
            return d
        }
    }

    /// PURE: aggregate JSONL `lines` whose `ts >= sinceIso` into a grand total plus
    /// per-feature and per-account breakdowns (each sorted by cost, descending).
    /// Blank, unparseable, ts-less, and pre-cutoff lines are skipped.
    static func aggregate(lines: [String], sinceIso: String) -> [String: Any] {
        var total = Acc()
        var byFeature: [String: Acc] = [:]
        var byAccount: [String: Acc] = [:]

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let ts = obj["ts"] as? String, ts >= sinceIso
            else { continue }

            let feature = (obj["feature"] as? String) ?? "unknown"
            let account = (obj["account"] as? String) ?? "unknown"
            total.add(obj)
            byFeature[feature, default: Acc()].add(obj)
            byAccount[account, default: Acc()].add(obj)
        }

        let featureRows = byFeature
            .sorted { $0.value.costUsd > $1.value.costUsd }
            .map { $0.value.json(extra: ["feature": $0.key]) }
        let accountRows = byAccount
            .sorted { $0.value.costUsd > $1.value.costUsd }
            .map { $0.value.json(extra: ["account": $0.key]) }

        return [
            "since": sinceIso,
            "total": total.json(extra: [:]),
            "byFeature": featureRows,
            "byAccount": accountRows,
        ]
    }

    /// Read the usage file and aggregate the last `hours`. `now` is injectable for
    /// tests. A missing/unreadable file yields zeroed totals (not an error).
    static func query(hours: Double, now: Date = Date()) -> [String: Any] {
        let sinceIso = isoString(from: now.addingTimeInterval(-hours * 3600))
        let text = (try? String(contentsOf: fileURL(), encoding: .utf8)) ?? ""
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        var payload = aggregate(lines: lines, sinceIso: sinceIso)
        payload["hours"] = hours
        return payload
    }
}
