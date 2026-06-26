import Foundation
import Testing
@testable import Ghostty

/// Unit tests for the pure JSONL line builder behind the bell/attention diagnostics
/// trace. The actual fs append is best-effort and untestable in isolation; the line
/// format is the contract a later analysis pass parses, so it's pinned here.
struct BellDiagnosticsTests {

    private func parse(_ line: String) throws -> [String: Any] {
        #expect(line.hasSuffix("\n"))
        let data = Data(line.utf8)
        let obj = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return obj
    }

    @Test func lineCarriesReservedFieldsAndPayload() throws {
        let line = BellDiagnostics.line(
            event: "ring",
            fields: ["surface": "ABC", "focused": true],
            nowIso: "2026-06-26T12:00:00.000Z")
        let obj = try parse(line)
        #expect(obj["ts"] as? String == "2026-06-26T12:00:00.000Z")
        #expect(obj["src"] as? String == "gui")
        #expect(obj["ev"] as? String == "ring")
        #expect(obj["surface"] as? String == "ABC")
        #expect(obj["focused"] as? Bool == true)
    }

    @Test func reservedKeysWinOverFields() throws {
        // A caller can't accidentally override ts/src/ev via the payload.
        let line = BellDiagnostics.line(
            event: "attention",
            fields: ["src": "evil", "ev": "evil", "ts": "evil", "on": false],
            nowIso: "T")
        let obj = try parse(line)
        #expect(obj["src"] as? String == "gui")
        #expect(obj["ev"] as? String == "attention")
        #expect(obj["ts"] as? String == "T")
        #expect(obj["on"] as? Bool == false)
    }

    @Test func keysAreSortedForDeterministicOutput() {
        let line = BellDiagnostics.line(
            event: "clear",
            fields: ["zeta": 1, "alpha": 2],
            nowIso: "T")
        // sortedKeys → alpha, ev, src, ts, zeta in that order.
        #expect(line == "{\"alpha\":2,\"ev\":\"clear\",\"src\":\"gui\",\"ts\":\"T\",\"zeta\":1}\n")
    }

    @Test func nonSerializableFieldsDegradeToEmptyObject() {
        // A Date is not a JSON primitive → JSONSerialization rejects it → "{}\n",
        // never a crash on the bell path.
        let line = BellDiagnostics.line(
            event: "ring", fields: ["bad": Date()], nowIso: "T")
        #expect(line == "{}\n")
    }
}
