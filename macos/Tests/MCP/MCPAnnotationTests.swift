import Foundation
import Testing
@testable import Ghostty

/// Unit tests for the PURE `set_surface_annotation` arguments parser
/// (`AgentAnnotationPayload.fromArguments`) and the AppKit-free dispatch paths
/// (missing id / empty body → invalidParams). The main-hopping `applyAnnotation`
/// handler is exercised only for its pre-hop validation here (it resolves a surface
/// on main, which is covered by the integration build, not a unit test).
struct MCPAnnotationTests {

    // MARK: - fromArguments (PURE)

    @Test func parsesSummaryOnly() {
        // A summary-only payload carries ONLY summary; every other field is nil (a
        // PARTIAL update — needsUser nil, not false, so a merge won't clobber a prior true).
        let p = AgentAnnotationPayload.fromArguments(["summary": "Running tests"])
        #expect(p?.annotation.summary == "Running tests")
        #expect(p?.annotation.phase == nil)
        #expect(p?.annotation.needsUser == nil)   // absent ⇒ nil (partial update)
    }

    @Test func parsesAllFields() {
        let p = AgentAnnotationPayload.fromArguments([
            "summary": "Waiting on a decision",
            "phase": "testing",
            "needsUser": true,
        ])
        #expect(p?.annotation.summary == "Waiting on a decision")
        #expect(p?.annotation.phase == "testing")
        #expect(p?.annotation.needsUser == true)
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

    @Test func blankSummaryWithPhaseAccepted() {
        // A blank summary + a real phase ⇒ valid (summary nil, phase set).
        let p = AgentAnnotationPayload.fromArguments(["summary": "  ", "phase": "testing"])
        #expect(p?.annotation.summary == nil)
        #expect(p?.annotation.phase == "testing")
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
        // An empty/whitespace phase collapses to nil rather than "".
        let p = AgentAnnotationPayload.fromArguments(["summary": "ok", "phase": ""])
        #expect(p?.annotation.phase == nil)
    }

    @Test func wrongTypedNeedsUserBecomesNil() {
        // needsUser non-bool ⇒ nil; does NOT reject the call (summary OK).
        let p = AgentAnnotationPayload.fromArguments(["summary": "ok", "needsUser": "yes"])
        #expect(p != nil)
        #expect(p?.annotation.needsUser == nil)
    }

    @Test func needsUserFalseExplicitlyKept() {
        // An explicit `needsUser: false` is a real value (NOT absent) — it should
        // survive as false, so a deliberate "no longer needs user" can be merged.
        let p = AgentAnnotationPayload.fromArguments(["summary": "ok", "needsUser": false])
        #expect(p?.annotation.needsUser == false)
    }

    // MARK: - merging (PURE)

    @Test func mergeOverlaysProvidedFieldsOnly() {
        // A summary-only update preserves a prior phase/needsUser/queue tag.
        let base = AgentAnnotation(summary: "old summary", phase: "coding",
                                   needsUser: true, queueKey: "ENG-1")
        let sumUpdate = AgentAnnotation(summary: "new summary")
        let merged = base.merging(sumUpdate)
        #expect(merged.summary == "new summary")
        #expect(merged.phase == "coding")          // preserved
        #expect(merged.needsUser == true)          // preserved (NOT clobbered to nil)
        #expect(merged.queueKey == "ENG-1")        // preserved
    }

    @Test func mergeNeedsUserNilPreservesPrior() {
        // The needsUser merge wrinkle: an update omitting needsUser must not reset
        // a prior true; an explicit false CAN override.
        let base = AgentAnnotation(summary: "s", needsUser: true)
        let omit = AgentAnnotation(summary: "s2")
        #expect(base.merging(omit).needsUser == true)
        let explicitFalse = AgentAnnotation(needsUser: false)
        #expect(base.merging(explicitFalse).needsUser == false)
    }

    // MARK: - Agent Queue: queue annotation fields (parse + merge)

    @Test func parseQueueFieldsAlone() {
        // The supervisor tags a tile at dispatch with queueKey/queueName/queueUrl
        // and NO summary — that must be a VALID partial annotation.
        let p = AgentAnnotationPayload.fromArguments([
            "id": UUID().uuidString,
            "queueKey": "ENG-123",
            "queueName": "my-team backlog",
            "queueUrl": "https://example.test/ENG-123",
        ])
        #expect(p != nil)
        #expect(p?.annotation.queueKey == "ENG-123")
        #expect(p?.annotation.queueName == "my-team backlog")
        #expect(p?.annotation.queueUrl == "https://example.test/ENG-123")
        // Untouched fields stay nil (partial update).
        #expect(p?.annotation.summary == nil)
    }

    @Test func parseQueueFieldsTrimAndBlankReject() {
        // Blank queue strings are treated as absent (same trim semantics as summary).
        let blank = AgentAnnotationPayload.fromArguments([
            "id": UUID().uuidString, "queueKey": "   ",
        ])
        #expect(blank == nil)  // no other field ⇒ empty body ⇒ reject
        let trimmed = AgentAnnotationPayload.fromArguments([
            "id": UUID().uuidString, "queueName": "  backlog  ",
        ])
        #expect(trimmed?.annotation.queueName == "backlog")
    }

    @Test func mergeQueueFieldsSurviveSummaryOnlyUpdate() {
        // A queue tag set at dispatch must survive a later summary-only update
        // (the summarizer never touches queue fields).
        let tagged = AgentAnnotation(
            queueKey: "ENG-9", queueName: "backlog", queueUrl: "https://x.test/9")
        let summaryUpdate = AgentAnnotation(summary: "Implementing fix")
        let merged = tagged.merging(summaryUpdate)
        #expect(merged.summary == "Implementing fix")
        #expect(merged.queueKey == "ENG-9")        // preserved
        #expect(merged.queueName == "backlog")     // preserved
        #expect(merged.queueUrl == "https://x.test/9")  // preserved
    }

    // MARK: - (keep) the keep verdict

    @Test func parseKeepTrueAndFalse() {
        // The supervisor stamps the keep verdict (a real boolean) — present-as-bool ⇒ that
        // bool; it is a valid update on its own.
        let on = AgentAnnotationPayload.fromArguments(["id": UUID().uuidString, "keep": true])
        #expect(on?.annotation.queueKeep == true)
        let off = AgentAnnotationPayload.fromArguments(["id": UUID().uuidString, "keep": false])
        #expect(off?.annotation.queueKeep == false)
    }

    @Test func keepOnlyAcceptedAndNonBoolBecomesNil() {
        // keep alone is a valid partial update; a non-bool keep ⇒ nil (and, with no other
        // field, the whole body is rejected as empty).
        #expect(AgentAnnotationPayload.fromArguments(["keep": true])?.annotation.queueKeep == true)
        #expect(AgentAnnotationPayload.fromArguments(["summary": "ok", "keep": "yes"])?.annotation.queueKeep == nil)
        #expect(AgentAnnotationPayload.fromArguments(["keep": "yes"]) == nil) // non-bool + nothing else ⇒ empty
    }

    @Test func mergeKeepNilPreservesPriorElseOverwrites() {
        // A summary-only update (keep nil) preserves a prior keep; an explicit keep overwrites.
        let kept = AgentAnnotation(queueKey: "K-1", queueKeep: true)
        #expect(kept.merging(AgentAnnotation(summary: "x")).queueKeep == true) // preserved
        #expect(kept.merging(AgentAnnotation(queueKeep: false)).queueKeep == false) // overwritten
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
        // send_key's pre-hop validation).
        let server = MCPServer(listen: "127.0.0.1:8765", token: "")
        switch MCPTools.dispatch(name: "set_surface_annotation",
                                 arguments: ["id": UUID().uuidString], server: server) {
        case .invalidParams: break
        default: Issue.record("expected .invalidParams for empty annotation body")
        }
    }
}
