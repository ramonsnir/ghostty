import Foundation
import Testing
@testable import Ghostty

/// Unit tests for the PURE `set_surface_annotation` arguments parser
/// (`AgentAnnotationPayload.fromArguments`) and the AppKit-free dispatch paths
/// (missing id / missing summary → invalidParams). The main-hopping
/// `applyAnnotation` handler is exercised only for its pre-hop validation here (it
/// resolves a surface on main, which is covered by the integration build, not a
/// unit test).
struct MCPAnnotationTests {

    // MARK: - fromArguments (PURE)

    @Test func parsesSummaryOnly() {
        let p = AgentAnnotationPayload.fromArguments(["summary": "Running tests"])
        #expect(p?.annotation.summary == "Running tests")
        #expect(p?.annotation.suggestion == nil)
        #expect(p?.annotation.phase == nil)
        #expect(p?.annotation.needsUser == false)   // default when absent
        #expect(p?.annotation.confidence == nil)
    }

    @Test func parsesAllFields() {
        let p = AgentAnnotationPayload.fromArguments([
            "summary": "Waiting on a decision",
            "suggestion": "Approve the migration",
            "phase": "testing",
            "needsUser": true,
            "confidence": 0.8,
        ])
        #expect(p?.annotation.summary == "Waiting on a decision")
        #expect(p?.annotation.suggestion == "Approve the migration")
        #expect(p?.annotation.phase == "testing")
        #expect(p?.annotation.needsUser == true)
        #expect(p?.annotation.confidence == 0.8)
    }

    @Test func missingSummaryRejected() {
        #expect(AgentAnnotationPayload.fromArguments([:]) == nil)
        #expect(AgentAnnotationPayload.fromArguments(["suggestion": "x"]) == nil)
    }

    @Test func blankSummaryRejected() {
        // Whitespace-only summary is treated as missing (the tile would show blank).
        #expect(AgentAnnotationPayload.fromArguments(["summary": "   \n "]) == nil)
        #expect(AgentAnnotationPayload.fromArguments(["summary": ""]) == nil)
    }

    @Test func summaryTrimmed() {
        let p = AgentAnnotationPayload.fromArguments(["summary": "  hi  "])
        #expect(p?.annotation.summary == "hi")
    }

    @Test func nonStringSummaryRejected() {
        // A number/bool summary is not a String ⇒ rejected (not coerced).
        #expect(AgentAnnotationPayload.fromArguments(["summary": 42]) == nil)
        #expect(AgentAnnotationPayload.fromArguments(["summary": true]) == nil)
    }

    @Test func blankOptionalsBecomeNil() {
        // An empty/whitespace suggestion/phase collapses to nil rather than "".
        let p = AgentAnnotationPayload.fromArguments([
            "summary": "ok", "suggestion": "  ", "phase": "",
        ])
        #expect(p?.annotation.suggestion == nil)
        #expect(p?.annotation.phase == nil)
    }

    @Test func wrongTypedOptionalsBecomeNilOrDefault() {
        // needsUser non-bool ⇒ default false; confidence non-number ⇒ nil;
        // suggestion non-string ⇒ nil. None of these reject the call (summary OK).
        let p = AgentAnnotationPayload.fromArguments([
            "summary": "ok", "needsUser": "yes", "confidence": "high", "suggestion": 7,
        ])
        #expect(p != nil)
        #expect(p?.annotation.needsUser == false)
        #expect(p?.annotation.confidence == nil)
        #expect(p?.annotation.suggestion == nil)
    }

    @Test func integerConfidenceCoerces() {
        // A JSON integer arrives as NSNumber and coerces to Double.
        let p = AgentAnnotationPayload.fromArguments(["summary": "ok", "confidence": 1])
        #expect(p?.annotation.confidence == 1.0)
    }

    // MARK: - dispatch (AppKit-free validation paths)

    @Test func dispatchMissingIdInvalidParams() {
        let server = MCPServer(listen: "127.0.0.1:8765", token: "")
        switch MCPTools.dispatch(name: "set_surface_annotation",
                                 arguments: ["summary": "x"], server: server) {
        case .invalidParams: break
        default: Issue.record("expected .invalidParams for missing id")
        }
    }

    @Test func dispatchBadIdInvalidParams() {
        let server = MCPServer(listen: "127.0.0.1:8765", token: "")
        switch MCPTools.dispatch(name: "set_surface_annotation",
                                 arguments: ["id": "not-a-uuid", "summary": "x"], server: server) {
        case .invalidParams: break
        default: Issue.record("expected .invalidParams for malformed id")
        }
    }

    @Test func dispatchMissingSummaryInvalidParams() {
        // A valid id but no summary fails fast BEFORE any main hop (mirrors
        // send_key's pre-hop validation).
        let server = MCPServer(listen: "127.0.0.1:8765", token: "")
        switch MCPTools.dispatch(name: "set_surface_annotation",
                                 arguments: ["id": UUID().uuidString], server: server) {
        case .invalidParams: break
        default: Issue.record("expected .invalidParams for missing summary")
        }
    }
}
