import Foundation
import Testing
@testable import Ghostty

/// Unit tests for the pure Haiku usage aggregator behind the `get_haiku_usage`
/// MCP tool. No filesystem: `aggregate` is exercised on synthetic JSONL lines.
struct MCPUsageTests {
    /// Build one usage JSONL line the way the sidecar would.
    private func line(
        ts: String, feature: String, account: String,
        inp: Int, out: Int, cr: Int, cc: Int, cost: Double
    ) -> String {
        let o: [String: Any] = [
            "ts": ts, "feature": feature, "account": account,
            "model": "claude-haiku-4-5",
            "inputTokens": inp, "outputTokens": out,
            "cacheReadTokens": cr, "cacheCreationTokens": cc, "costUsd": cost,
        ]
        let d = try! JSONSerialization.data(withJSONObject: o)
        return String(data: d, encoding: .utf8)!
    }

    @Test func aggregatesPerFeatureAndAccountAboveCutoff() {
        let lines = [
            line(ts: "2026-06-28T12:00:00.000Z", feature: "summarizer", account: "dev",
                 inp: 10, out: 20, cr: 100, cc: 200, cost: 0.01),
            line(ts: "2026-06-28T12:05:00.000Z", feature: "summarizer", account: "dev",
                 inp: 5, out: 5, cr: 0, cc: 0, cost: 0.002),
            line(ts: "2026-06-28T12:10:00.000Z", feature: "bell-classify", account: "ambient",
                 inp: 1, out: 2, cr: 3, cc: 4, cost: 0.05),
        ]
        let r = MCPUsage.aggregate(lines: lines, sinceIso: "2026-06-28T11:00:00.000Z")

        let total = r["total"] as! [String: Any]
        #expect(total["calls"] as? Int == 3)
        #expect(total["inputTokens"] as? Int == 16)
        #expect(abs((total["costUsd"] as! Double) - 0.062) < 1e-9)

        // byFeature sorted by cost desc → bell-classify (0.05) first.
        let byFeature = r["byFeature"] as! [[String: Any]]
        #expect(byFeature.first?["feature"] as? String == "bell-classify")
        let summ = byFeature.first { $0["feature"] as? String == "summarizer" }!
        #expect(summ["calls"] as? Int == 2)
        #expect(summ["inputTokens"] as? Int == 15)
        #expect(summ["cacheCreationTokens"] as? Int == 200)

        let byAccount = r["byAccount"] as! [[String: Any]]
        let dev = byAccount.first { $0["account"] as? String == "dev" }!
        #expect(dev["calls"] as? Int == 2)
        #expect((byAccount.first { $0["account"] as? String == "ambient" }!)["calls"] as? Int == 1)
    }

    @Test func excludesPreCutoffAndJunkLines() {
        let lines = [
            line(ts: "2026-06-28T10:00:00.000Z", feature: "summarizer", account: "dev",
                 inp: 99, out: 0, cr: 0, cc: 0, cost: 9.0), // before cutoff
            "not json",
            "   ",
            "{\"feature\":\"x\"}", // no ts
            line(ts: "2026-06-28T12:00:00.000Z", feature: "summarizer", account: "dev",
                 inp: 7, out: 0, cr: 0, cc: 0, cost: 0.1),
        ]
        let r = MCPUsage.aggregate(lines: lines, sinceIso: "2026-06-28T11:00:00.000Z")
        let total = r["total"] as! [String: Any]
        #expect(total["calls"] as? Int == 1)
        #expect(total["inputTokens"] as? Int == 7)
    }

    @Test func emptyYieldsZeroTotals() {
        let r = MCPUsage.aggregate(lines: [], sinceIso: "2026-06-28T11:00:00.000Z")
        let total = r["total"] as! [String: Any]
        #expect(total["calls"] as? Int == 0)
        #expect(total["costUsd"] as? Double == 0)
        #expect((r["byFeature"] as! [[String: Any]]).isEmpty)
        #expect((r["byAccount"] as! [[String: Any]]).isEmpty)
    }

    /// The cutoff format must be byte-identical to JS `Date.toISOString()` so the
    /// lexicographic `ts >= sinceIso` comparison is correct.
    @Test func isoStringMatchesJSToISOFormat() {
        #expect(MCPUsage.isoString(from: Date(timeIntervalSince1970: 0)) == "1970-01-01T00:00:00.000Z")
    }
}
