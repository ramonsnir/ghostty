import Foundation
import Testing
@testable import Ghostty

/// (ramon fork / suspend-resume) Unit tests for the on-disk transcript recovery — the pure
/// cores (dir encoding, session-id shape, newest-transcript pick, claude subtree find).
struct TranscriptResolverTests {

    @Test func encodeProjectDirMatchesClaudeScheme() {
        #expect(TranscriptResolver.encodeProjectDir("/Users/ramon/git/NoetiveOS") == "-Users-ramon-git-NoetiveOS")
        #expect(TranscriptResolver.encodeProjectDir("/Users/ramon/.config/x") == "-Users-ramon--config-x")
        #expect(TranscriptResolver.encodeProjectDir("Ghostty (ramon).app") == "Ghostty--ramon--app")
    }

    @Test func isSessionIdShape() {
        #expect(TranscriptResolver.isSessionId("4e667a95-0125-4631-ba83-f7a935e851a2"))
        #expect(!TranscriptResolver.isSessionId("not-an-id"))
        #expect(!TranscriptResolver.isSessionId("4e667a950125463 ba83f7a935e851a2"))  // space
        #expect(!TranscriptResolver.isSessionId("zzzzzzzz-0125-4631-ba83-f7a935e851a2")) // non-hex
    }

    @Test func newestSessionIdPicksNewestTranscript() {
        let entries: [(name: String, mtime: Double)] = [
            ("6f0b1d10-7915-4e94-900f-91553c1f117a.jsonl", 100),
            ("4e667a95-0125-4631-ba83-f7a935e851a2.jsonl", 200),  // newest
            ("notes.txt", 300),                                   // not a transcript
        ]
        #expect(TranscriptResolver.newestSessionId(entries: entries) == "4e667a95-0125-4631-ba83-f7a935e851a2")
    }

    @Test func newestSessionIdEmptyWhenNoTranscript() {
        #expect(TranscriptResolver.newestSessionId(entries: [("readme.md", 1), ("x.log", 2)]) == nil)
    }

    @Test func claudePidFoundInSubtree() {
        // 100 (login) → 101 (bash pool) → 102 (claude). exePathOf identifies claude by basename.
        let children: [pid_t: [pid_t]] = [100: [101], 101: [102]]
        let exe: (pid_t) -> String = { pid in
            pid == 102 ? "/Users/ramon/.local/bin/claude" : "/bin/bash"
        }
        #expect(TranscriptResolver.claudePid(under: 100, childrenMap: children, exePathOf: exe) == 102)
    }

    @Test func claudePidNilWhenNoClaude() {
        let children: [pid_t: [pid_t]] = [100: [101]]
        let exe: (pid_t) -> String = { _ in "/bin/zsh" }
        #expect(TranscriptResolver.claudePid(under: 100, childrenMap: children, exePathOf: exe) == nil)
    }
}
