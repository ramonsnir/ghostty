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
        // (Phase 2) A summary-only payload carries ONLY summary; every other field
        // is nil (a PARTIAL update — needsUser nil, not false, so a merge won't
        // clobber a prior true).
        let p = AgentAnnotationPayload.fromArguments(["summary": "Running tests"])
        #expect(p?.annotation.summary == "Running tests")
        #expect(p?.annotation.suggestion == nil)
        #expect(p?.annotation.phase == nil)
        #expect(p?.annotation.needsUser == nil)   // absent ⇒ nil (partial update)
        #expect(p?.annotation.confidence == nil)
    }

    @Test func parsesSuggestionOnly() {
        // (Phase 2) summary is no longer required: a suggestion-only payload is
        // valid and carries ONLY the suggestion.
        let p = AgentAnnotationPayload.fromArguments(["suggestion": "Approve the migration"])
        #expect(p?.annotation.suggestion == "Approve the migration")
        #expect(p?.annotation.summary == nil)
        #expect(p?.annotation.needsUser == nil)
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

    @Test func emptyBodyRejected() {
        // No updatable field at all ⇒ rejected.
        #expect(AgentAnnotationPayload.fromArguments([:]) == nil)
        #expect(AgentAnnotationPayload.fromArguments(["id": "x"]) == nil)
    }

    @Test func phaseOnlyAccepted() {
        // Any single updatable field is enough — even phase alone.
        let p = AgentAnnotationPayload.fromArguments(["phase": "testing"])
        #expect(p?.annotation.phase == "testing")
        #expect(p?.annotation.summary == nil)
    }

    @Test func needsUserOnlyAccepted() {
        // needsUser alone (as a bool) is a valid partial update.
        let p = AgentAnnotationPayload.fromArguments(["needsUser": true])
        #expect(p?.annotation.needsUser == true)
        #expect(p?.annotation.summary == nil)
    }

    @Test func blankSummaryWithNoOtherFieldRejected() {
        // A whitespace-only summary collapses to nil; with no other field present
        // the body is empty ⇒ rejected.
        #expect(AgentAnnotationPayload.fromArguments(["summary": "   \n "]) == nil)
        #expect(AgentAnnotationPayload.fromArguments(["summary": ""]) == nil)
    }

    @Test func blankSummaryWithSuggestionAccepted() {
        // A blank summary + a real suggestion ⇒ valid (summary nil, suggestion set).
        let p = AgentAnnotationPayload.fromArguments(["summary": "  ", "suggestion": "go"])
        #expect(p?.annotation.summary == nil)
        #expect(p?.annotation.suggestion == "go")
    }

    @Test func summaryTrimmed() {
        let p = AgentAnnotationPayload.fromArguments(["summary": "  hi  "])
        #expect(p?.annotation.summary == "hi")
    }

    @Test func nonStringSummaryTreatedAsAbsent() {
        // A number/bool summary is not a String ⇒ treated as absent; with no other
        // field the body is empty ⇒ rejected.
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

    @Test func wrongTypedOptionalsBecomeNil() {
        // needsUser non-bool ⇒ nil; confidence non-number ⇒ nil; suggestion
        // non-string ⇒ nil. None reject the call (summary OK).
        let p = AgentAnnotationPayload.fromArguments([
            "summary": "ok", "needsUser": "yes", "confidence": "high", "suggestion": 7,
        ])
        #expect(p != nil)
        #expect(p?.annotation.needsUser == nil)
        #expect(p?.annotation.confidence == nil)
        #expect(p?.annotation.suggestion == nil)
    }

    @Test func integerConfidenceCoerces() {
        // A JSON integer arrives as NSNumber and coerces to Double.
        let p = AgentAnnotationPayload.fromArguments(["summary": "ok", "confidence": 1])
        #expect(p?.annotation.confidence == 1.0)
    }

    @Test func needsUserFalseExplicitlyKept() {
        // An explicit `needsUser: false` is a real value (NOT absent) — it should
        // survive as false, so a deliberate "no longer needs user" can be merged.
        let p = AgentAnnotationPayload.fromArguments(["summary": "ok", "needsUser": false])
        #expect(p?.annotation.needsUser == false)
    }

    // MARK: - merging (PURE)

    @Test func mergeOverlaysProvidedFieldsOnly() {
        // A summary-only update preserves a prior suggestion; a suggestion-only
        // update preserves a prior summary.
        let base = AgentAnnotation(summary: "old summary", suggestion: "old sug",
                                   phase: "coding", needsUser: true, confidence: 0.5)
        let sumUpdate = AgentAnnotation(summary: "new summary", suggestion: nil,
                                        phase: nil, needsUser: nil, confidence: nil)
        let merged = base.merging(sumUpdate)
        #expect(merged.summary == "new summary")
        #expect(merged.suggestion == "old sug")    // preserved
        #expect(merged.phase == "coding")          // preserved
        #expect(merged.needsUser == true)          // preserved (NOT clobbered to nil)
        #expect(merged.confidence == 0.5)          // preserved
    }

    @Test func mergeSuggestionPreservesSummary() {
        let base = AgentAnnotation(summary: "Implementing fix", suggestion: nil,
                                   phase: nil, needsUser: nil, confidence: nil)
        let sugUpdate = AgentAnnotation(summary: nil, suggestion: "Approve it",
                                        phase: nil, needsUser: nil, confidence: nil)
        let merged = base.merging(sugUpdate)
        #expect(merged.summary == "Implementing fix")
        #expect(merged.suggestion == "Approve it")
    }

    @Test func mergeNeedsUserNilPreservesPrior() {
        // The needsUser merge wrinkle: an update omitting needsUser must not reset
        // a prior true; an explicit false CAN override.
        let base = AgentAnnotation(summary: "s", suggestion: nil, phase: nil,
                                   needsUser: true, confidence: nil)
        let omit = AgentAnnotation(summary: "s2", suggestion: nil, phase: nil,
                                   needsUser: nil, confidence: nil)
        #expect(base.merging(omit).needsUser == true)
        let explicitFalse = AgentAnnotation(summary: nil, suggestion: nil, phase: nil,
                                            needsUser: false, confidence: nil)
        #expect(base.merging(explicitFalse).needsUser == false)
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

    @Test func dispatchEmptyBodyInvalidParams() {
        // A valid id but NO updatable field fails fast BEFORE any main hop (mirrors
        // send_key's pre-hop validation). (Phase 2: summary is no longer required,
        // but an entirely empty body still rejects.)
        let server = MCPServer(listen: "127.0.0.1:8765", token: "")
        switch MCPTools.dispatch(name: "set_surface_annotation",
                                 arguments: ["id": UUID().uuidString], server: server) {
        case .invalidParams: break
        default: Issue.record("expected .invalidParams for empty annotation body")
        }
    }
}
