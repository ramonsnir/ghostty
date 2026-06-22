import Foundation
import Testing
@testable import Ghostty

/// Unit tests for the PURE Phase-3 destructive-reply gate (`MCPSafety`). The gate
/// is implemented + tested NOW but is UNUSED in Phase 2 (the user-tapped Approve
/// is the authorization; nothing calls this on the Phase-2 path). These tests pin
/// the decision so Phase 3 can wire it in with confidence.
struct MCPSafetyTests {

    // MARK: - isAffirmativeReply

    @Test func bareAffirmativesDetected() {
        for s in ["y", "yes", "YES", "ok", "Okay", "do it", "go ahead", "approve",
                  "confirm", "proceed", "1", "yep", "sure"] {
            #expect(MCPSafety.isAffirmativeReply(s), "expected affirmative: \(s)")
        }
    }

    @Test func trailingPunctuationStripped() {
        #expect(MCPSafety.isAffirmativeReply("yes!"))
        #expect(MCPSafety.isAffirmativeReply("y."))
        #expect(MCPSafety.isAffirmativeReply("approve "))
    }

    @Test func nonAffirmativesNotDetected() {
        for s in ["no", "n", "wait", "let me check first",
                  "yes, but only the test files", "delete only the temp dir",
                  "", "  "] {
            #expect(!MCPSafety.isAffirmativeReply(s), "did not expect affirmative: \(s)")
        }
    }

    // MARK: - isDestructiveReply

    @Test func affirmativeOverDangerousScreenIsDestructive() {
        let screen = "About to run: rm -rf /Users/x/project\nProceed? (y/N)"
        #expect(MCPSafety.isDestructiveReply("y", screen: screen))
        #expect(MCPSafety.isDestructiveReply("yes", screen: screen))
    }

    @Test func variedDangerousContextsFlagged() {
        #expect(MCPSafety.isDestructiveReply("yes", screen: "git push --force to main?"))
        #expect(MCPSafety.isDestructiveReply("approve", screen: "DROP TABLE users; confirm?"))
        #expect(MCPSafety.isDestructiveReply("ok", screen: "Confirm payment of $4,000?"))
        #expect(MCPSafety.isDestructiveReply("1", screen: "Deleting 12 files. This cannot be undone."))
    }

    @Test func dangerousMatchIsCaseInsensitive() {
        #expect(MCPSafety.isDestructiveReply("yes", screen: "GIT PUSH -F origin"))
    }

    @Test func affirmativeOverInnocuousScreenIsNotDestructive() {
        let screen = "Run the test suite now? (y/N)"
        #expect(!MCPSafety.isDestructiveReply("y", screen: screen))
        #expect(!MCPSafety.isDestructiveReply("yes", screen: screen))
    }

    @Test func nonAffirmativeReplyIsNeverDestructive() {
        // A typed-out instruction is not a one-key approval — never flagged here,
        // even over a dangerous screen.
        let screen = "About to rm -rf the build dir. Proceed?"
        #expect(!MCPSafety.isDestructiveReply("only delete node_modules", screen: screen))
        #expect(!MCPSafety.isDestructiveReply("no, keep the build dir", screen: screen))
    }
}
