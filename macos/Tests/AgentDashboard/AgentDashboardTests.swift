import AppKit
import Darwin
import Testing
@testable import Ghostty

// MARK: - AgentMirrorPreview geometry (pure)

struct AgentMirrorGeometryTests {
    @Test func framesFullHostGridAndPinsBottom() {
        // Realistic host grid (120x40, 14x30 backing px) on a 560x220 full-width
        // row at 2x backing.
        let g = AgentMirrorPreview.geometry(
            cols: 120, rows: 40, cellW: 14, cellH: 30, backing: 2,
            container: CGSize(width: 560, height: 220), referenceColumns: 120)
        // Natural size is the FULL host grid in points — NOT collapsed (the bug
        // that made the preview empty / one row produced a tiny naturalH here).
        #expect(abs(g.naturalW - 840) < 0.5)   // 120*14/2
        #expect(abs(g.naturalH - 600) < 0.5)   // 40*30/2
        // With referenceColumns == cols, the full width is filled (scale fits).
        #expect(abs(g.scale - 560.0 / 840.0) < 0.001)
        // The scaled content is TALLER than the row, so the top is clipped and
        // the agent's latest (bottom) rows are what's shown.
        #expect(g.naturalH * g.scale > 220)
    }

    @Test func fallsBackToContainerWhenGridUnknown() {
        // Before the first host frame (grid/cell == 0): no collapse, scale is a
        // no-op so the view fills the container rather than vanishing.
        let g = AgentMirrorPreview.geometry(
            cols: 0, rows: 0, cellW: 0, cellH: 0, backing: 2,
            container: CGSize(width: 560, height: 220))
        #expect(g.naturalW == 560)
        #expect(g.naturalH == 220)
        #expect(g.scale == 1)
    }

    @Test func zeroBackingDoesNotDivideByZero() {
        let g = AgentMirrorPreview.geometry(
            cols: 80, rows: 24, cellW: 16, cellH: 32, backing: 0,
            container: CGSize(width: 400, height: 200))
        // backing 0 is treated as 2; naturalW = 80*16/2 = 640.
        #expect(abs(g.naturalW - 640) < 0.5)
        #expect(g.scale > 0)
    }

    @Test func uniformScaleAcrossSplitsOfDifferentWidths() {
        // Two splits with DIFFERENT column counts but the same cell/backing must
        // get the SAME scale (uniform cell size), with `referenceColumns` (here
        // 120) filling the width. The narrow split's content is narrower than the
        // row (pads right); the wide split's overflows (horizontal scroll).
        let container = CGSize(width: 560, height: 220)
        let narrow = AgentMirrorPreview.geometry(
            cols: 80, rows: 24, cellW: 14, cellH: 30, backing: 2,
            container: container, referenceColumns: 120)
        let wide = AgentMirrorPreview.geometry(
            cols: 240, rows: 50, cellW: 14, cellH: 30, backing: 2,
            container: container, referenceColumns: 120)
        // Same uniform scale regardless of the split's own width.
        #expect(abs(narrow.scale - wide.scale) < 0.0001)
        #expect(abs(narrow.scale - 560.0 / (120.0 * 14.0 / 2.0)) < 0.001)
        // Narrow content fits within the row; wide content overflows → scroll.
        #expect(narrow.scaledW < container.width)
        #expect(wide.scaledW > container.width)
        // Exactly `referenceColumns` columns spans the width.
        let refWidth = AgentMirrorPreview.geometry(
            cols: 120, rows: 24, cellW: 14, cellH: 30, backing: 2,
            container: container, referenceColumns: 120).scaledW
        #expect(abs(refWidth - container.width) < 0.5)
    }
}

// MARK: - AgentMirrorPreview.bottomAnchorOffset (pure; skip empty trailing rows)

struct BottomAnchorOffsetTests {
    @Test func zeroWhenNoTrailingBlanks() {
        // A full screen (no trailing blanks) is unchanged — plain bottom-anchor.
        let off = AgentMirrorPreview.bottomAnchorOffset(
            skipRows: 0, rows: 40, cellH: 30, backing: 2, scale: 0.5)
        #expect(off == 0)
    }

    @Test func shiftsDownByBlankRegionHeight() {
        // 10 blank trailing rows of a 40-row grid: shift down by 10 scaled rows.
        // Per-row scaled height = (cellH / backing) * scale = (30/2)*0.5 = 7.5.
        let off = AgentMirrorPreview.bottomAnchorOffset(
            skipRows: 10, rows: 40, cellH: 30, backing: 2, scale: 0.5)
        #expect(abs(off - 75) < 0.0001)   // 10 * 7.5
    }

    @Test func clampsToKeepOneRowAnchored() {
        // An all-blank screen clamps to rows-1 so a single row stays in view
        // rather than the whole (empty) grid scrolling out.
        let bk: CGFloat = 2, cellH: CGFloat = 30, scale: CGFloat = 0.5
        let scaledRowH = (cellH / bk) * scale
        let off = AgentMirrorPreview.bottomAnchorOffset(
            skipRows: 24, rows: 24, cellH: cellH, backing: bk, scale: scale)
        #expect(abs(off - CGFloat(23) * scaledRowH) < 0.0001)
    }

    @Test func zeroForDegenerateInputs() {
        // No cell size / no scale / single-row grid → no offset (never NaN/inf).
        #expect(AgentMirrorPreview.bottomAnchorOffset(
            skipRows: 5, rows: 40, cellH: 0, backing: 2, scale: 0.5) == 0)
        #expect(AgentMirrorPreview.bottomAnchorOffset(
            skipRows: 5, rows: 40, cellH: 30, backing: 2, scale: 0) == 0)
        #expect(AgentMirrorPreview.bottomAnchorOffset(
            skipRows: 1, rows: 1, cellH: 30, backing: 2, scale: 0.5) == 0)
    }

    @Test func zeroBackingTreatedAsTwo() {
        // backing 0 is treated as 2 (matches `geometry`), so no divide-by-zero.
        let off = AgentMirrorPreview.bottomAnchorOffset(
            skipRows: 4, rows: 40, cellH: 30, backing: 0, scale: 0.5)
        #expect(abs(off - 4 * (30.0 / 2.0) * 0.5) < 0.0001)
    }
}

// MARK: - AgentMirrorPreview.chromeTrailingSkip (pure; skip blanks + footer)

struct ChromeTrailingSkipTests {
    // A full-width horizontal rule, as Claude Code draws the input box border.
    private static let rule = String(repeating: "─", count: 60)

    @Test func skipsClaudeCodeInputBoxAndModeLines() {
        // Real Claude Code footer shape: content, then ─/❯/─ input box, then two
        // status/mode lines. Everything from the top rule down is skipped so the
        // last CONTENT line ("last content line") lands at the bottom.
        let rows = [
            "  some earlier output",
            "  last content line",
            Self.rule,                       // input box top border
            "❯ ",                            // empty prompt interior
            Self.rule,                       // input box bottom border
            "  🟢 ctx:63%",                  // status line
            "  ⏵⏵ auto mode on (shift+tab to cycle) · PR #1762",  // mode line
        ]
        // Skip the 5 footer rows (top rule … last mode line); keep both content.
        #expect(AgentMirrorPreview.chromeTrailingSkip(rows: rows) == 5)
    }

    @Test func prologueInteriorPadIsNoBreakSpace() {
        // REGRESSION: the real prompt line is "❯\u{00A0}" — the pad after ❯ is a
        // NO-BREAK SPACE (U+00A0), not a normal space. An interior check that only
        // treats U+0020/U+0009 as whitespace reads it as content and never skips
        // the footer (the "nothing changed" bug). With Unicode-whitespace handling
        // the footer is skipped exactly as with a normal space.
        let rows = [
            "  last content line",
            Self.rule,
            "❯\u{00A0}",                     // ❯ + NO-BREAK SPACE (as Claude Code emits)
            Self.rule,
            "  ⏵⏵ auto mode on",
        ]
        #expect(AgentMirrorPreview.chromeTrailingSkip(rows: rows) == 4)
        #expect(AgentMirrorPreview.isEmptyInteriorRow("❯\u{00A0}"))
        #expect(AgentMirrorPreview.isBlankRow("\u{00A0}\u{00A0}"))
    }

    @Test func skipsFooterWithTrailingBlankRows() {
        // Same footer but with trailing blank rows after the mode line: blanks +
        // footer are all skipped.
        let rows = [
            "  content",
            Self.rule, "❯ ", Self.rule,
            "  ⏵⏵ auto mode on",
            "", "",
        ]
        #expect(AgentMirrorPreview.chromeTrailingSkip(rows: rows) == 6)
    }

    @Test func tallContentBoxKeepsFilledRowsTrimsChrome() {
        // A fully-filled tall box (every interior row has text) keeps ALL its
        // content rows; only the help line + bottom border below them are trimmed.
        var rows = ["  ✻ Waiting for 1 dynamic workflow to finish", ""]
        rows.append(" ╭ Phases " + String(repeating: "─", count: 40) + "╮")  // tall box top
        for _ in 0..<12 { rows.append(" │  some live workflow row" + String(repeating: " ", count: 10) + "│") }
        rows.append(" ╰" + String(repeating: "─", count: 48) + "╯")          // tall box bottom
        rows.append(" ↑↓ select · x stop workflow · p pause · esc back · s save")
        // Skip = help line + bottom border (2); the 12 filled rows are kept.
        #expect(AgentMirrorPreview.chromeTrailingSkip(rows: rows) == 2)
    }

    @Test func workflowViewerSkipsEmptyBoxTail() {
        // The real /workflows viewer: filled phase rows at the TOP, then many
        // EMPTY interior cells, the bottom border, and the help line. The empty
        // tail + border + help are skipped so the FILLED rows fill the preview;
        // the last filled row ("│ 3 Implement … │") is the new bottom.
        var rows = [
            "  …prior conversation…",
            "✻ Waiting for 1 dynamic workflow to finish",
            String(repeating: "─", count: 100),               // separator rule
            " swe-dev",
            " Software development … 6/7 agents · 22m17s",
            "",
            " ╭ Phases ──────────────┬ Design · 5 agents " + String(repeating: "─", count: 30) + "╮",
            " │   ✔ Preflight    2/2 │  ✔ design ✍️   …  │",     // filled
            " │ ❯ 2 Design       4/5 │  ✔ design 🔎   …  │",     // filled
            " │   3 Implement+Test   │                  │",     // filled (left col has text)
        ]
        for _ in 0..<10 { rows.append(" │                      │                  │") }  // empty interior
        rows.append(" ╰──────────────────────┴" + String(repeating: "─", count: 18) + "╯")  // bottom border
        rows.append(" ↑↓ select · x stop workflow · p pause · esc back · s save")           // help
        // Skip = help(1) + bottom border(1) + 10 empty interior = 12.
        #expect(AgentMirrorPreview.chromeTrailingSkip(rows: rows) == 12)
    }

    @Test func permissionPromptBoxKeepsQuestionTrimsBorder() {
        // A small box whose interior has a real question/options keeps the
        // question + options; only the bottom border below them is trimmed.
        let rows = [
            "  Edit file src/main.zig?",
            Self.rule,
            "❯ 1. Yes",
            "  2. No, and tell Claude what to do differently",
            Self.rule,
        ]
        // Skip = just the bottom border (1); the Yes/No options are kept.
        #expect(AgentMirrorPreview.chromeTrailingSkip(rows: rows) == 1)
    }

    @Test func onlyTrailingBlanksWhenNoFooter() {
        // No input box at the bottom → only trailing blank rows are skipped.
        let rows = ["  line a", "  line b", "", "", ""]
        #expect(AgentMirrorPreview.chromeTrailingSkip(rows: rows) == 3)
    }

    @Test func allBlankSkipsEverything() {
        #expect(AgentMirrorPreview.chromeTrailingSkip(rows: ["", "", ""]) == 3)
        #expect(AgentMirrorPreview.chromeTrailingSkip(rows: []) == 0)
    }

    @Test func doesNotSkipBoxBuriedUnderManyStatusLines() {
        // If the input box is more than maxStatusLines (3) above the last content,
        // it's not treated as the bottom footer (avoids eating content).
        let rows = [
            "  content",
            Self.rule, "❯ ", Self.rule,
            "  s1", "  s2", "  s3", "  s4",   // 4 status-ish lines (> maxStatusLines)
        ]
        #expect(AgentMirrorPreview.chromeTrailingSkip(rows: rows) == 0)
    }

    @Test func skipsBlankGapAboveFooterOnSparseScreen() {
        // Real near-empty Claude Code session: a small banner + exchange at the
        // TOP, a big blank gap, then the input-box footer pinned at the bottom
        // (the bottom border carries the claude-pool status, still a rule). The
        // footer AND the whole gap are skipped so "✻ Baked for 4s" lands at the
        // bottom — not a blank row mid-gap.
        var rows = [
            "",
            " ▐▛███▜▌   Claude Code v2.1.186",
            "▝▜█████▛▘  Opus 4.8 (1M context)",
            "  ▘▘ ▝▝    ~/git/ghostty",
            "",
            "❯ 2 + 2",
            "",
            "⏺ 4",
            "",
            "✻ Baked for 4s",
        ]
        for _ in 0..<28 { rows.append("") }                       // big blank gap
        rows.append(Self.rule)                                     // input box top
        rows.append("❯ ")                                          // empty prompt
        rows.append("▶ [claude-pool] pool: active=three " + Self.rule)  // bottom rule + status
        rows.append("  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents")
        // Everything from row 10 (first gap blank) down is dropped; "✻ Baked
        // for 4s" (index 9) is the new bottom.
        #expect(AgentMirrorPreview.chromeTrailingSkip(rows: rows) == rows.count - 10)
    }

    @Test func ruleRowDetectionIgnoresAsciiDashes() {
        // ASCII '-' (markdown table separators etc.) is NOT a box rule, so a row
        // of ASCII dashes is treated as content, not an input-box border.
        let rows = [
            "  content",
            String(repeating: "-", count: 60),  // ASCII dashes — not a rule
            "  more content",
        ]
        #expect(AgentMirrorPreview.chromeTrailingSkip(rows: rows) == 0)
    }
}

// MARK: - AgentMirrorPreview.backgroundShellCount (pure; Claude Code footer)

struct BackgroundShellCountTests {
    // Grounded in the REAL footers captured from a live "background build" session
    // (the case this feature was built for).
    @Test func autoModeFooterReportsOneShell() {
        let rows = [
            "  some agent output",
            "─────────────────────────────────────────",
            "❯ ",
            "─────────────────────────────────────────",
            "  ⏵⏵ auto mode on · 1 shell · ← for age…",
        ]
        #expect(AgentMirrorPreview.backgroundShellCount(rows: rows) == 1)
    }

    @Test func spinnerFooterReportsOneShell() {
        let rows = ["✻ Crunched for 1m 48s · 1 shell still running"]
        #expect(AgentMirrorPreview.backgroundShellCount(rows: rows) == 1)
    }

    @Test func pluralShellsParsed() {
        #expect(AgentMirrorPreview.backgroundShellCount(
            rows: ["  ⏵⏵ auto mode on · 2 shells · ← for age…"]) == 2)
    }

    @Test func noIndicatorIsZero() {
        let rows = [
            "  some agent output",
            "  ⏵⏵ auto mode on · ← for age…",   // no shell token
        ]
        #expect(AgentMirrorPreview.backgroundShellCount(rows: rows) == 0)
    }

    @Test func wordShellWithoutCountIsZero() {
        // "shell" in content with no preceding digit must NOT match.
        #expect(AgentMirrorPreview.backgroundShellCount(
            rows: ["wrote a shell script", "ran the shell"]) == 0)
        // A letter immediately before "shell" (no number) is not a count.
        #expect(AgentMirrorPreview.shellCount(inStatusLine: "myshell") == nil)
    }

    @Test func onlyTrailingRowsScanned() {
        // A "1 shell" far ABOVE the scan window (footer) is ignored — the indicator
        // only ever lives in the bottom status line.
        var rows = ["history: 1 shell started earlier"]
        rows.append(contentsOf: Array(repeating: "  content", count: 12))
        #expect(AgentMirrorPreview.backgroundShellCount(rows: rows) == 0)
    }

    @Test func boxInteriorContentNotMistaken() {
        // A filled box-interior row carrying "shell" is NOT a status line (it has
        // box-drawing borders), so it never counts.
        let rows = ["│ run 3 shell tests │"]
        #expect(AgentMirrorPreview.backgroundShellCount(rows: rows) == 0)
    }
}

// MARK: - matchAgent pure logic

struct AgentDetectorTests {
    /// Helper: build a ProcSnapshot from (pid, name, children) tuples.
    private func snap(_ entries: [(pid_t, String, [pid_t])]) -> ProcSnapshot {
        var out: ProcSnapshot = [:]
        for (pid, name, children) in entries {
            out[pid] = (name: name, children: children)
        }
        return out
    }

    @Test func directHit() {
        let s = snap([(100, "claude", [])])
        #expect(matchAgent(rootPID: 100, snapshot: s, commands: ["claude", "codex"]) == AgentKind("claude"))
    }

    @Test func childHitShellNodeClaude() {
        // shell(100) -> node(200) -> claude(300)
        let s = snap([
            (100, "zsh", [200]),
            (200, "node", [300]),
            (300, "claude", []),
        ])
        #expect(matchAgent(rootPID: 100, snapshot: s, commands: ["claude"]) == AgentKind("claude"))
    }

    @Test func depthCapStopsWalk() {
        // Chain deeper than maxDepth=2: the claude at depth 3 must NOT be found.
        let s = snap([
            (1, "a", [2]),
            (2, "b", [3]),
            (3, "c", [4]),
            (4, "claude", []),
        ])
        #expect(matchAgent(rootPID: 1, snapshot: s, commands: ["claude"], maxDepth: 2) == nil)
        // With enough depth it IS found.
        #expect(matchAgent(rootPID: 1, snapshot: s, commands: ["claude"], maxDepth: 4) == AgentKind("claude"))
    }

    @Test func cycleVisitedCapTerminates() {
        // Self-referential / cyclic tree must terminate and return nil.
        let s = snap([
            (1, "a", [2]),
            (2, "b", [1, 2]), // points back at 1 and itself
        ])
        #expect(matchAgent(rootPID: 1, snapshot: s, commands: ["claude"]) == nil)
    }

    @Test func prefersPathBasename() {
        // The fixture stores a full path; matchAgent basenames it.
        let s = snap([(100, "/opt/homebrew/bin/codex", [])])
        #expect(matchAgent(rootPID: 100, snapshot: s, commands: ["codex"]) == AgentKind("codex"))
    }

    @Test func noMatchReturnsNil() {
        let s = snap([
            (100, "zsh", [200]),
            (200, "vim", []),
        ])
        #expect(matchAgent(rootPID: 100, snapshot: s, commands: ["claude", "codex"]) == nil)
    }

    @Test func configurableCommandSet() {
        let s = snap([(100, "claude", [])])
        // Only watching codex: claude should NOT match.
        #expect(matchAgent(rootPID: 100, snapshot: s, commands: ["codex"]) == nil)
        let s2 = snap([(100, "codex", [])])
        #expect(matchAgent(rootPID: 100, snapshot: s2, commands: ["codex"]) == AgentKind("codex"))
    }

    @Test func emptyCommandsNeverMatches() {
        let s = snap([(100, "claude", [])])
        #expect(matchAgent(rootPID: 100, snapshot: s, commands: []) == nil)
    }

    @Test func bfsShallowerMatchWins() {
        // claude at depth 1, codex at depth 2 under one root. BFS must return the
        // SHALLOWER match (claude) deterministically — a DFS would surface codex
        // and break the documented "shallower wins" contract.
        let s = snap([
            (1, "zsh", [2]),
            (2, "claude", [3]),
            (3, "codex", []),
        ])
        #expect(matchAgent(rootPID: 1, snapshot: s, commands: ["claude", "codex"]) == AgentKind("claude"))
    }

    @Test func bfsShallowerWinsAcrossBranches() {
        // Two matches at different depths on separate branches: depth-1 codex must
        // beat depth-2 claude regardless of dictionary/child ordering.
        let s = snap([
            (1, "zsh", [2, 3]),
            (2, "codex", []),       // depth 1
            (3, "node", [4]),
            (4, "claude", []),      // depth 2
        ])
        #expect(matchAgent(rootPID: 1, snapshot: s, commands: ["claude", "codex"]) == AgentKind("codex"))
    }
}

// MARK: - AgentDetector cache / resolve logic

/// Counting fake: records how many times each rootPID was walked, so we can
/// assert the cache skips a re-walk when the pid is unchanged.
private final class CountingEnumerator: ProcEnumerator {
    var byPID: [pid_t: ProcSnapshot]
    private(set) var walkCount: [pid_t: Int] = [:]
    init(_ byPID: [pid_t: ProcSnapshot]) { self.byPID = byPID }
    func snapshot(rootPID: pid_t) -> ProcSnapshot {
        walkCount[rootPID, default: 0] += 1
        return byPID[rootPID] ?? [:]
    }
}

struct AgentDetectorCacheTests {
    @Test func cacheHitSkipsRewalk() {
        let a = UUID()
        let claudeTree: ProcSnapshot = [100: (name: "claude", children: [])]
        let en = CountingEnumerator([100: claudeTree])

        // First tick: cold cache -> one walk, claude detected.
        let (r1, c1) = AgentDetector.resolve(
            snapshot: [(a, 100)], cache: [:], commands: ["claude"], enumerator: en)
        #expect(r1[a] == AgentKind("claude"))
        #expect(en.walkCount[100] == 1)

        // Second tick: same pid -> cache hit, NO re-walk.
        let (r2, _) = AgentDetector.resolve(
            snapshot: [(a, 100)], cache: c1, commands: ["claude"], enumerator: en)
        #expect(r2[a] == AgentKind("claude"))
        #expect(en.walkCount[100] == 1) // unchanged
    }

    @Test func cacheMissOnPIDChangeRewalks() {
        let a = UUID()
        let en = CountingEnumerator([
            100: [100: (name: "claude", children: [])],
            200: [200: (name: "vim", children: [])],
        ])
        let (_, c1) = AgentDetector.resolve(
            snapshot: [(a, 100)], cache: [:], commands: ["claude"], enumerator: en)
        #expect(en.walkCount[100] == 1)

        // Foreground pid changed (100 -> 200): must re-walk, and now no agent.
        let (r2, _) = AgentDetector.resolve(
            snapshot: [(a, 200)], cache: c1, commands: ["claude"], enumerator: en)
        #expect(en.walkCount[200] == 1)
        #expect(r2[a] == nil)
    }

    @Test func negativeResultRewalksWhenAgentAppearsUnderStablePID() {
        // Regression: the claude-accounts pool keeps a stable foreground pid (a
        // `bash …/claude-pool` leader) and spawns the `claude` child LATER. A
        // nil result must NOT be cached, or the agent stays invisible forever
        // (the pid never changes, so a pid-keyed cache would never re-walk).
        let a = UUID()
        let en = CountingEnumerator([
            // Tick 1: leader present, NO agent child yet.
            100: [100: (name: "bash", children: [])],
        ])
        let (r1, c1) = AgentDetector.resolve(
            snapshot: [(a, 100)], cache: [:], commands: ["claude"], enumerator: en)
        #expect(r1[a] == nil)
        #expect(en.walkCount[100] == 1)

        // The pool starts claude under the SAME leader pid.
        en.byPID[100] = [
            100: (name: "bash", children: [200]),
            200: (name: "/Users/ramon/.local/share/claude/versions/2.1.181", children: []),
        ]
        let (r2, _) = AgentDetector.resolve(
            snapshot: [(a, 100)], cache: c1, commands: ["claude"], enumerator: en)
        #expect(r2[a] == AgentKind("claude")) // now detected
        #expect(en.walkCount[100] == 2)       // re-walked despite the stable pid
    }

    @Test func vanishedIDDroppedFromCache() {
        let a = UUID(), b = UUID()
        let en = CountingEnumerator([
            100: [100: (name: "claude", children: [])],
            200: [200: (name: "codex", children: [])],
        ])
        let (_, c1) = AgentDetector.resolve(
            snapshot: [(a, 100), (b, 200)], cache: [:],
            commands: ["claude", "codex"], enumerator: en)
        #expect(c1.count == 2)

        // b's surface vanished: next snapshot has only a -> next cache drops b.
        let (r2, c2) = AgentDetector.resolve(
            snapshot: [(a, 100)], cache: c1, commands: ["claude", "codex"], enumerator: en)
        #expect(c2.keys.contains(a))
        #expect(!c2.keys.contains(b))
        #expect(r2[b] == nil)
    }
}

// MARK: - Hide / auto-unhide state machine + persistence

@MainActor
struct AgentDashboardModelTests {
    private func live(_ ids: [UUID]) -> [AgentDashboardModel.LiveSurface] {
        ids.map { id in
            .init(id: id, view: nil, title: "t", pwd: "/x", sessionID: 0)
        }
    }

    /// Like `live(_:)` but with explicit (uuid, sessionID) pairs — needed for the
    /// agent-state persistence, which is keyed by the stable host session id.
    private func live(_ pairs: [(UUID, UInt64)]) -> [AgentDashboardModel.LiveSurface] {
        pairs.map { (id, sid) in
            .init(id: id, view: nil, title: "t", pwd: "/x", sessionID: sid)
        }
    }

    /// Seed the detector results so the given ids are treated as agents — the
    /// dashboard is agent-only (LOCKED), so an entry only exists for a split the
    /// detector matched. Tests that assert `entries` contains an id MUST first
    /// mark it as an agent here.
    private func agents(_ ids: [UUID]) -> [UUID: AgentKind] {
        Dictionary(uniqueKeysWithValues: ids.map { ($0, AgentKind("claude")) })
    }

    @Test func hideAddsAndPersists() {
        let store = InMemoryHideStore()
        let model = AgentDashboardModel(store: store)
        let a = UUID()
        model.rebuild(live: live([a]))
        model.applyAgents(agents([a]))               // a is a detected agent
        #expect(model.entries.map(\.id).contains(a))

        model.hide(a)
        #expect(model.hidden.contains(a))
        #expect(store.load().contains(a))           // persisted
        #expect(!model.entries.map(\.id).contains(a)) // dropped from grid
    }

    @Test func nonAgentNeverShown() {
        // LOCKED "agent-only": a live split with NO detected agent must never
        // produce a tile, so spec §2.6 state-2 stays reachable.
        let store = InMemoryHideStore()
        let model = AgentDashboardModel(store: store)
        let plainShell = UUID()
        model.rebuild(live: live([plainShell]))      // no applyAgents → not an agent
        #expect(model.entries.isEmpty)
        // It IS a live terminal (state-1 vs state-2 discriminator)…
        #expect(model.liveIDs.contains(plainShell))
        // …but it is NOT in the agent universe.
        #expect(!model.liveAgentIDs.contains(plainShell))
    }

    @Test func bellAutoUnhides() {
        let store = InMemoryHideStore()
        let model = AgentDashboardModel(store: store)
        let a = UUID()
        model.rebuild(live: live([a]))
        model.applyAgents(agents([a]))
        model.hide(a)
        #expect(model.hidden.contains(a))

        // Bell false->true must unhide.
        model.applyBells([a: true])
        #expect(!model.hidden.contains(a))
        #expect(!store.load().contains(a))          // persistence updated
        #expect(model.entries.first?.bell == true)
    }

    @Test func hideWhileRingingReUnhides() {
        // LOCKED #1: a RINGING agent must never stay hidden. Sequence: agent
        // rings -> applyBells sets bells[a]=true; user hides it WHILE ringing;
        // detector republishes the SAME (still true) bell -> the agent must be
        // unhidden again (not stranded by the false->true-only transition logic).
        let store = InMemoryHideStore()
        let model = AgentDashboardModel(store: store)
        let a = UUID()
        model.rebuild(live: live([a]))
        model.applyAgents(agents([a]))

        model.applyBells([a: true])     // a starts ringing
        model.hide(a)                   // user hides it while ringing
        #expect(model.hidden.contains(a))

        // Same bell republished (no transition): the ringing agent must reappear.
        model.applyBells([a: true])
        #expect(!model.hidden.contains(a))
        #expect(!store.load().contains(a))
        #expect(model.entries.map(\.id).contains(a))
    }

    @Test func bellFalseKeepsHidden() {
        // Negative complement of the auto-unhide path (LOCKED #1 / spec §4.2):
        // a hidden agent that is NOT ringing must STAY hidden through applyBells.
        // Guards against a refactor that unhides on mere PRESENCE in the bell dict
        // rather than on truth — such a regression would pass every positive test.
        let store = InMemoryHideStore()
        let model = AgentDashboardModel(store: store)
        let a = UUID()
        model.rebuild(live: live([a]))
        model.applyAgents(agents([a]))
        model.hide(a)
        #expect(model.hidden.contains(a))

        // bell present but false: must NOT unhide.
        model.applyBells([a: false])
        #expect(model.hidden.contains(a))
        #expect(store.load().contains(a))
        #expect(!model.entries.map(\.id).contains(a))

        // bell dict omitting `a` entirely: must NOT unhide.
        model.applyBells([:])
        #expect(model.hidden.contains(a))
        #expect(store.load().contains(a))
        #expect(!model.entries.map(\.id).contains(a))
    }

    @Test func agentVanishedDropsTile() {
        // A previously-detected agent quits (surface stays). The next applyAgents
        // without that id must drop its tile.
        let store = InMemoryHideStore()
        let model = AgentDashboardModel(store: store)
        let a = UUID()
        model.rebuild(live: live([a]))
        model.applyAgents(agents([a]))
        #expect(model.entries.map(\.id).contains(a))

        // Agent process exits but the surface remains a live (non-agent) split.
        model.applyAgents([:])
        #expect(!model.entries.map(\.id).contains(a))
        #expect(model.liveIDs.contains(a))          // still a live terminal
        #expect(!model.liveAgentIDs.contains(a))    // no longer an agent
    }

    @Test func detectorDropReconcileRemovesTile() {
        // FAITHFUL to production reconciliation: a tile is built ONLY while the
        // detector reports the agent live (rebuildEntriesFromCurrentState filters
        // on `agents[id] != nil`). When a claude/codex process exits, the next
        // detector poll returns nil for that id and applyAgents is called WITHOUT
        // it — the tile must VANISH on that reconcile (LOCKED: finished agents
        // vanish immediately; there is no "ended" tile state). This drives the
        // removal the way production does, not by artificially keeping the agent
        // alive.
        let store = InMemoryHideStore()
        let model = AgentDashboardModel(store: store)
        let a = UUID()
        model.rebuild(live: live([a]))
        model.applyAgents(agents([a]))            // detector reports a live
        #expect(model.entries.map(\.id).contains(a))

        // Underlying surface stays live (still a terminal split) but the detector
        // no longer reports it as an agent: tile is removed on reconcile.
        model.applyAgents([:])
        #expect(!model.entries.map(\.id).contains(a))
        #expect(model.liveIDs.contains(a))        // still a live terminal
        #expect(!model.liveAgentIDs.contains(a))  // but no longer an agent

        // Still-live & still-detected agents remain normal live tiles — only the
        // detector dropping an id removes it (re-seed after rebuild drops stale).
        let b = UUID()
        model.rebuild(live: live([a, b]))
        model.applyAgents(agents([b]))
        #expect(model.entries.map(\.id).contains(b))
        #expect(!model.entries.map(\.id).contains(a))
    }

    @Test func rebuildDoesNotUnhide() {
        // Variant b: a panel-open rebuild re-evaluates live agents but NEVER
        // clears the hide set.
        let store = InMemoryHideStore()
        let model = AgentDashboardModel(store: store)
        let a = UUID()
        model.rebuild(live: live([a]))
        model.applyAgents(agents([a]))
        model.hide(a)
        // Multiple rebuilds (no bell) keep it hidden. Re-seed agents each rebuild
        // (rebuild drops stale agent state for vanished ids; a stays live).
        model.rebuild(live: live([a]))
        model.applyAgents(agents([a]))
        model.rebuild(live: live([a]))
        model.applyAgents(agents([a]))
        #expect(model.hidden.contains(a))
        #expect(!model.entries.map(\.id).contains(a))
    }

    @Test func showAllClears() {
        let store = InMemoryHideStore()
        let model = AgentDashboardModel(store: store)
        let a = UUID(), b = UUID()
        model.rebuild(live: live([a, b]))
        model.applyAgents(agents([a, b]))
        model.hide(a)
        model.hide(b)
        #expect(model.hidden.count == 2)
        model.showAll()
        #expect(model.hidden.isEmpty)
        #expect(store.load().isEmpty)
    }

    @Test func hiddenCountAmongLive() {
        // `gone` is hidden in the store but not live: the chip count must reflect
        // only the hidden ids that are still live agents (a, b), not the stale
        // `gone` carried over from a previous launch.
        let a = UUID(), b = UUID(), gone = UUID()
        let store = InMemoryHideStore([a, b, gone])
        let model = AgentDashboardModel(store: store)
        model.rebuild(live: live([a, b]))
        model.applyAgents(agents([a, b]))
        // Counted over the agent subset: a and b are hidden live agents; `gone`
        // is excluded because it isn't live.
        #expect(model.hiddenCount(among: model.liveAgentIDs) == 2)
        #expect(model.hidden.contains(gone)) // still persisted, just not counted
    }

    @Test func hiddenCountIgnoresNonAgents() {
        // A hidden NON-agent split must not inflate the "N hidden" chip.
        let store = InMemoryHideStore()
        let model = AgentDashboardModel(store: store)
        let agent = UUID(), plainShell = UUID()
        model.rebuild(live: live([agent, plainShell]))
        model.applyAgents(agents([agent]))           // only `agent` is detected
        model.hide(agent)
        model.hide(plainShell)                        // hidden, but not an agent
        #expect(model.hiddenCount(among: model.liveAgentIDs) == 1)
        #expect(model.hiddenAgents.map(\.id) == [agent])
    }

    @Test func persistenceRoundTrip() {
        // Model A hides `a` -> store retains it -> fresh model B starts hidden.
        let store = InMemoryHideStore()
        let a = UUID()
        let modelA = AgentDashboardModel(store: store)
        modelA.rebuild(live: live([a]))
        modelA.applyAgents(agents([a]))
        modelA.hide(a)

        let modelB = AgentDashboardModel(store: store)
        #expect(modelB.hidden.contains(a))
        modelB.rebuild(live: live([a]))
        modelB.applyAgents(agents([a]))
        #expect(!modelB.entries.map(\.id).contains(a)) // still hidden after relaunch
    }
}

// MARK: - UserDefaultsHideStore (the REAL persistence backend)

/// Exercises the PRODUCTION `UserDefaultsHideStore` (not the in-memory fake), so
/// the actual UUID->String->UUID serialization that backs the LOCKED
/// persist-across-launches decision is covered: the `set([uuidString])` /
/// `stringArray(forKey:)` round-trip, the `compactMap { UUID(uuidString:) }`
/// parse, and the empty-array / absent-key edges. Each test uses a throwaway
/// suite so it never touches the real fork defaults domain.
struct UserDefaultsHideStoreTests {
    /// A fresh, isolated UserDefaults suite that is removed after the closure.
    private func withTempDefaults(_ body: (UserDefaults) -> Void) {
        let suite = "agent-dashboard.test.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("could not create temp UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }

    @Test func saveLoadRoundTrip() {
        withTempDefaults { defaults in
            let store = UserDefaultsHideStore(defaults: defaults)
            let a = UUID(), b = UUID()
            store.save([a, b])
            #expect(store.load() == [a, b])

            // A second store over the SAME suite (simulating a relaunch) reads it.
            let reopened = UserDefaultsHideStore(defaults: defaults)
            #expect(reopened.load() == [a, b])
        }
    }

    @Test func loadDefaultsToEmptyWhenAbsent() {
        withTempDefaults { defaults in
            let store = UserDefaultsHideStore(defaults: defaults)
            // Absent key -> empty set, never a crash.
            #expect(store.load().isEmpty)
        }
    }

    @Test func saveEmptyClearsPersistedSet() {
        withTempDefaults { defaults in
            let store = UserDefaultsHideStore(defaults: defaults)
            store.save([UUID()])
            #expect(!store.load().isEmpty)
            // "Show all" persists an empty set -> a relaunch starts visible.
            store.save([])
            #expect(store.load().isEmpty)
        }
    }

    @Test func malformedStringsAreDropped() {
        withTempDefaults { defaults in
            // A corrupted/legacy defaults entry must not crash load(); only the
            // parseable UUIDs survive the compactMap.
            let good = UUID()
            defaults.set([good.uuidString, "not-a-uuid", ""], forKey: UserDefaultsHideStore.key)
            let store = UserDefaultsHideStore(defaults: defaults)
            #expect(store.load() == [good])
        }
    }

    @Test func usesTheDocumentedDefaultsKey() {
        // Pin the key so a rename can't silently orphan everyone's saved hide set.
        #expect(UserDefaultsHideStore.key == "agentDashboardHiddenIDs")
    }
}

// MARK: - Config default substitution (agent-dashboard-commands)

struct AgentDashboardConfigTests {
    @Test func emptyParsedYieldsDefault() {
        // The Zig field defaults EMPTY; the user-facing default lives in the
        // Swift getter. An unset/empty key must substitute [claude, codex].
        #expect(Ghostty.Config.resolveAgentDashboardCommands([]) == ["claude", "codex"])
    }

    @Test func nonEmptyParsedPassesThrough() {
        // A configured set must pass through verbatim (no default injection).
        #expect(Ghostty.Config.resolveAgentDashboardCommands(["aider"]) == ["aider"])
        #expect(Ghostty.Config.resolveAgentDashboardCommands(["claude", "codex", "aider"])
            == ["claude", "codex", "aider"])
    }

    @Test func defaultMatchesPublishedConstant() {
        #expect(Ghostty.Config.agentDashboardCommandsDefault == ["claude", "codex"])
    }
}

// MARK: - Sort order + bell-frame derivation

@MainActor
struct AgentDashboardSortTests {
    private func entry(_ id: UUID, bell: Bool) -> AgentEntry {
        .init(id: id, realView: nil, title: "t", pwd: "/x", agent: nil,
              bell: bell, hidden: false, sessionID: 0,
              agentState: nil, lastTool: nil, lastPrompt: nil, hookBacked: false,
              annotation: nil,
              backgroundShells: 0)
    }

    @Test func bellFirst() {
        // Two non-bell + one bell; bell must come first regardless of UUID order.
        let ring = UUID()
        let q1 = UUID()
        let q2 = UUID()
        let entries = [entry(q1, bell: false), entry(q2, bell: false), entry(ring, bell: true)]
        let sorted = AgentDashboardModel.sorted(entries)
        #expect(sorted.first?.id == ring)
    }

    @Test func uuidTieBreakStable() {
        // No bells, no lastSeen: order is deterministic by uuidString.
        let ids = (0..<4).map { _ in UUID() }
        let entries = ids.map { entry($0, bell: false) }
        let sorted = AgentDashboardModel.sorted(entries).map(\.id)
        let expected = ids.sorted { $0.uuidString < $1.uuidString }
        #expect(sorted == expected)
    }

    @Test func livenessSecondaryKey() {
        // Among non-bell tiles, more-recently-seen comes first.
        let older = UUID(), newer = UUID()
        let entries = [entry(older, bell: false), entry(newer, bell: false)]
        let lastSeen: [UUID: Date] = [
            older: Date(timeIntervalSince1970: 1),
            newer: Date(timeIntervalSince1970: 100),
        ]
        let sorted = AgentDashboardModel.sorted(entries, lastSeen: lastSeen).map(\.id)
        #expect(sorted == [newer, older])
    }

    @Test func bellOutranksLiveness() {
        // A just-rang tile beats a more-recently-active non-bell tile.
        let ringOld = UUID(), busyNew = UUID()
        let entries = [entry(busyNew, bell: false), entry(ringOld, bell: true)]
        let lastSeen: [UUID: Date] = [
            ringOld: Date(timeIntervalSince1970: 1),
            busyNew: Date(timeIntervalSince1970: 100),
        ]
        let sorted = AgentDashboardModel.sorted(entries, lastSeen: lastSeen).map(\.id)
        #expect(sorted.first == ringOld)
    }

    // MARK: - Manual order (ramon fork / Agent Dashboard)

    private func entry(_ id: UUID, session: UInt64, bell: Bool = false, waiting: Bool = false) -> AgentEntry {
        .init(id: id, realView: nil, title: "t", pwd: "/x", agent: nil,
              bell: bell, hidden: false, sessionID: session,
              agentState: waiting ? .waiting : nil,
              lastTool: nil, lastPrompt: nil, hookBacked: false,
              annotation: nil,
              backgroundShells: 0)
    }

    @Test func manualRankOrdersPlacedTiles() {
        // All placed (sessions present in manualRank), no attention, equal
        // recency: order follows the manual rank, NOT UUID.
        let a = UUID(), b = UUID(), c = UUID()
        let entries = [entry(a, session: 10), entry(b, session: 20), entry(c, session: 30)]
        let rank: [UInt64: Int] = [30: 0, 10: 1, 20: 2]
        let sorted = AgentDashboardModel.sorted(entries, manualRank: rank).map(\.sessionID)
        #expect(sorted == [30, 10, 20])
    }

    @Test func unplacedTileFloatsAbovePlaced() {
        // A tile with no manual rank (a freshly-appeared agent) sorts ABOVE the
        // placed ones — the "new agents at top" choice.
        let a = UUID(), b = UUID(), fresh = UUID()
        let entries = [entry(a, session: 1), entry(b, session: 2), entry(fresh, session: 99)]
        let rank: [UInt64: Int] = [1: 0, 2: 1]   // 99 is unplaced
        let sorted = AgentDashboardModel.sorted(entries, manualRank: rank).map(\.sessionID)
        #expect(sorted == [99, 1, 2])
    }

    @Test func attentionOutranksManualOrder() {
        // A waiting tile placed LAST in the manual order still floats to the top.
        let a = UUID(), b = UUID(), wait = UUID()
        let entries = [
            entry(a, session: 1),
            entry(b, session: 2),
            entry(wait, session: 3, waiting: true),
        ]
        let rank: [UInt64: Int] = [1: 0, 2: 1, 3: 2]
        let sorted = AgentDashboardModel.sorted(entries, manualRank: rank)
        #expect(sorted.first?.id == wait)
    }

    @Test func sessionZeroIsNeverPlaced() {
        // A sessionless tile (id 0) is treated as unplaced even if a rank for 0
        // somehow exists — it can't be ordered stably, so it floats up (unplaced)
        // and never sorts by the bogus rank.
        let zero = UUID(), placed = UUID()
        let entries = [entry(placed, session: 5), entry(zero, session: 0)]
        let rank: [UInt64: Int] = [0: 9, 5: 0]
        let sorted = AgentDashboardModel.sorted(entries, manualRank: rank).map(\.sessionID)
        #expect(sorted == [0, 5])
    }
}

// MARK: - Manual order: model round-trip (ramon fork / Agent Dashboard)

@MainActor
struct AgentDashboardManualOrderModelTests {
    private func live(_ pairs: [(UUID, UInt64)]) -> [AgentDashboardModel.LiveSurface] {
        pairs.map { .init(id: $0.0, view: nil, title: "t", pwd: "/x", sessionID: $0.1) }
    }
    private func agents(_ ids: [UUID]) -> [UUID: AgentKind] {
        Dictionary(uniqueKeysWithValues: ids.map { ($0, AgentKind("claude")) })
    }

    @Test func setManualOrderPersistsAndReorders() {
        let store = InMemoryOrderStore()
        let model = AgentDashboardModel(store: InMemoryHideStore(), orderStore: store)
        let a = UUID(), b = UUID(), c = UUID()
        model.rebuild(live: live([(a, 1), (b, 2), (c, 3)]))
        model.applyAgents(agents([a, b, c]))
        model.setManualOrder([3, 1, 2])
        #expect(model.manualOrder == [3, 1, 2])
        #expect(store.load() == [3, 1, 2])           // persisted
        #expect(model.entries.map(\.sessionID) == [3, 1, 2])
        #expect(model.hasManualOrder)
    }

    @Test func sessionlessTilesDroppedFromOrder() {
        let store = InMemoryOrderStore()
        let model = AgentDashboardModel(store: InMemoryHideStore(), orderStore: store)
        model.setManualOrder([0, 5, 0, 7])
        #expect(model.manualOrder == [5, 7])
        #expect(store.load() == [5, 7])
    }

    @Test func resetOrderClearsAndPersists() {
        let store = InMemoryOrderStore([9, 8, 7])
        let model = AgentDashboardModel(store: InMemoryHideStore(), orderStore: store)
        #expect(model.manualOrder == [9, 8, 7])      // loaded from the store at init
        #expect(model.hasManualOrder)
        model.resetOrder()
        #expect(model.manualOrder.isEmpty)
        #expect(store.load().isEmpty)
        #expect(!model.hasManualOrder)
    }

    @Test func newAgentFloatsAbovePlacedAfterRebuild() {
        let store = InMemoryOrderStore()
        let model = AgentDashboardModel(store: InMemoryHideStore(), orderStore: store)
        let a = UUID(), b = UUID()
        model.rebuild(live: live([(a, 1), (b, 2)]))
        model.applyAgents(agents([a, b]))
        model.setManualOrder([1, 2])
        #expect(model.entries.map(\.sessionID) == [1, 2])
        // A new agent (session 3) appears: it's unplaced, so it floats to the top.
        let c = UUID()
        model.rebuild(live: live([(a, 1), (b, 2), (c, 3)]))
        model.applyAgents(agents([a, b, c]))
        #expect(model.entries.map(\.sessionID) == [3, 1, 2])
    }
}

// MARK: - Hook agent-state model transitions (ramon fork / Agent hooks)

@MainActor
struct AgentDashboardHookStateTests {
    private func live(_ ids: [UUID]) -> [AgentDashboardModel.LiveSurface] {
        ids.map { .init(id: $0, view: nil, title: "t", pwd: "/x", sessionID: 0) }
    }

    // (id, sessionID) overload — for tests that need a non-zero host session id
    // (e.g. agent-state persistence keyed by session id). Mirrors the same
    // helper in the other model test structs.
    private func live(_ pairs: [(UUID, UInt64)]) -> [AgentDashboardModel.LiveSurface] {
        pairs.map { (id, sid) in .init(id: id, view: nil, title: "t", pwd: "/x", sessionID: sid) }
    }

    private func agents(_ ids: [UUID]) -> [UUID: AgentKind] {
        Dictionary(uniqueKeysWithValues: ids.map { ($0, AgentKind("claude")) })
    }

    private func payload(
        _ state: AgentState, tool: String? = nil, prompt: String? = nil, message: String? = nil
    ) -> AgentStatePayload {
        .init(tty: "ttys004", state: state, prompt: prompt, tool: tool, message: message)
    }

    @Test func hookBackedInsertedOnFirstEvent() {
        let model = AgentDashboardModel(store: InMemoryHideStore())
        let a = UUID()
        model.rebuild(live: live([a]))
        model.applyAgents(agents([a]))
        #expect(!model.hookBacked.contains(a))

        model.applyAgentState(a, payload(.working))
        #expect(model.hookBacked.contains(a))
        #expect(model.agentStates[a] == .working)
        #expect(model.entries.first(where: { $0.id == a })?.hookBacked == true)
        #expect(model.entries.first(where: { $0.id == a })?.agentState == .working)
    }

    @Test func workingToWaitingReturnsTrueAndUnhides() {
        let store = InMemoryHideStore()
        let model = AgentDashboardModel(store: store)
        let a = UUID()
        model.rebuild(live: live([a]))
        model.applyAgents(agents([a]))

        // Enter working, then hide the tile.
        _ = model.applyAgentState(a, payload(.working))
        model.hide(a)
        #expect(model.hidden.contains(a))

        // working -> waiting: enters waiting (returns true) AND auto-unhides.
        let entered = model.applyAgentState(a, payload(.waiting, message: "approve?"))
        #expect(entered == true)
        #expect(!model.hidden.contains(a))
        #expect(!store.load().contains(a))            // persistence updated
        #expect(model.agentStates[a] == .waiting)
        #expect(model.entries.map(\.id).contains(a))  // reappears
    }

    @Test func nilToWaitingEntersWaiting() {
        // First event is .waiting (prev == nil): still the entering edge.
        let model = AgentDashboardModel(store: InMemoryHideStore())
        let a = UUID()
        model.rebuild(live: live([a]))
        model.applyAgents(agents([a]))
        let entered = model.applyAgentState(a, payload(.waiting, message: "input?"))
        #expect(entered == true)
        #expect(model.agentStates[a] == .waiting)
    }

    @Test func backgroundBusyWaitingIsNotAnAttentionEdge() {
        // (ramon fork / Agent hooks) Entering `.waiting` while a background shell is
        // running is DEMOTED: it is NOT an attention edge (returns false, so the
        // controller fires no push) and does NOT auto-unhide. The state is still
        // recorded as `.waiting` and the entry carries the shell count for the chip.
        let store = InMemoryHideStore()
        let model = AgentDashboardModel(store: store)
        let a = UUID()
        model.rebuild(live: live([a]))
        model.applyAgents(agents([a]))
        _ = model.applyAgentState(a, payload(.working))
        model.hide(a)

        // working -> waiting WITH a background shell: demoted.
        let entered = model.applyAgentState(a, payload(.waiting, message: "?"),
                                            backgroundShells: 1)
        #expect(entered == false)              // no push edge
        #expect(model.hidden.contains(a))      // NOT auto-unhidden
        #expect(model.agentStates[a] == .waiting)
    }

    @Test func waitingAfterBackgroundWorkAndWakeIsAnAttentionEdge() {
        // The realistic recovery flow: a demoted waiting (background shell running)
        // → the shell completes and WAKES the agent (Claude Code injects a
        // task-notification → `working`) → the agent finishes and GENUINELY waits
        // (no shells). That last transition has prev == .working, so it IS an
        // attention edge and fires the push. (A bare demoted-waiting → genuine-waiting
        // with NO intervening wake is deliberately NOT a fresh edge — prev is already
        // `.waiting` — but in practice the shell's completion always wakes the agent.)
        let model = AgentDashboardModel(store: InMemoryHideStore())
        let a = UUID()
        model.rebuild(live: live([a]))
        model.applyAgents(agents([a]))
        #expect(model.applyAgentState(a, payload(.waiting, message: "a"),
                                      backgroundShells: 1) == false)   // demoted, no edge
        _ = model.applyAgentState(a, payload(.working, tool: "Bash"))  // shell woke it
        #expect(model.applyAgentState(a, payload(.waiting, message: "b"),
                                      backgroundShells: 0) == true)     // genuine edge
    }

    @Test func entriesCarryBackgroundShellCountViaReader() {
        // The injected reader drives the entry's `backgroundShells` for the chip/sort.
        let model = AgentDashboardModel(store: InMemoryHideStore())
        let a = UUID()
        model.backgroundShellReader = { _ in 2 }
        model.rebuild(live: live([a]))
        model.applyAgents(agents([a]))
        _ = model.applyAgentState(a, payload(.waiting, message: "?"))
        #expect(model.entries.first(where: { $0.id == a })?.backgroundShells == 2)
    }

    @Test func nonWaitingEntriesHaveZeroBackgroundShells() {
        // A working tile never pays the viewport read — its count is always 0 even
        // if the reader would report shells.
        let model = AgentDashboardModel(store: InMemoryHideStore())
        let a = UUID()
        model.backgroundShellReader = { _ in 3 }
        model.rebuild(live: live([a]))
        model.applyAgents(agents([a]))
        _ = model.applyAgentState(a, payload(.working))
        #expect(model.entries.first(where: { $0.id == a })?.backgroundShells == 0)
    }

    @Test func waitingRepublishDoesNotReEnter() {
        // A second .waiting with the SAME message is coalesced (no transition):
        // returns false, so the controller does not re-post attention/push.
        let model = AgentDashboardModel(store: InMemoryHideStore())
        let a = UUID()
        model.rebuild(live: live([a]))
        model.applyAgents(agents([a]))
        #expect(model.applyAgentState(a, payload(.waiting, message: "input?")) == true)
        // Identical republish: coalesced, returns false.
        #expect(model.applyAgentState(a, payload(.waiting, message: "input?")) == false)
        #expect(model.agentStates[a] == .waiting)
    }

    @Test func coalescedWaitingRepublishDoesNotReUnhideHiddenTile() {
        // LOCKED, deliberately counterintuitive (AgentDashboardController.swift
        // applyAgentState): a COALESCED identical `.waiting` republish does NOT
        // re-unhide a manually-hidden tile — weaker than applyBells' re-unhide on
        // every republish, because a Notification fires ONCE (not continuously like
        // a bell). So the user CAN re-hide a still-waiting tile. This is the only
        // safeguard against a future "fix" that makes waiting re-unhide on republish.
        let store = InMemoryHideStore()
        let model = AgentDashboardModel(store: store)
        let a = UUID()
        model.rebuild(live: live([a]))
        model.applyAgents(agents([a]))

        // Enter waiting (the edge auto-unhides if hidden; here it isn't hidden yet).
        #expect(model.applyAgentState(a, payload(.waiting, message: "input?")) == true)
        // User hides the still-waiting tile.
        model.hide(a)
        #expect(model.hidden.contains(a))

        // Identical `.waiting` republish: coalesced (returns false) AND — the locked
        // bit — does NOT re-unhide. Distinguishes this from the working->waiting
        // auto-unhide path tested in workingToWaitingReturnsTrueAndUnhides.
        #expect(model.applyAgentState(a, payload(.waiting, message: "input?")) == false)
        #expect(model.hidden.contains(a))            // STAYS hidden (locked)
        #expect(store.load().contains(a))            // persistence still has it
    }

    @Test func waitingWithNewMessageStaysWaitingButDoesNotReEnter() {
        // prev == .waiting, new message differs: NOT coalesced (message changed),
        // but the entering-waiting edge is prev != .waiting, so it returns false.
        let model = AgentDashboardModel(store: InMemoryHideStore())
        let a = UUID()
        model.rebuild(live: live([a]))
        model.applyAgents(agents([a]))
        #expect(model.applyAgentState(a, payload(.waiting, message: "first")) == true)
        #expect(model.applyAgentState(a, payload(.waiting, message: "second")) == false)
        #expect(model.lastMessage[a] == "second")
    }

    @Test func coalesceUnchangedWorkingNoRebuild() {
        // Repeated PreToolUse(working) with no field changes must coalesce. The
        // GENUINE proof the rebuild was skipped is the early-return value `r == false`
        // (the early-return at applyAgentState returns BEFORE rebuilding). The id
        // array-compare below is only a sanity check that nothing was added/removed;
        // it does NOT prove "no rebuild thrash" (ids would match even if a full
        // rebuild ran, and AgentEntry isn't Equatable so a value compare isn't
        // possible) — the `r == false` assertion is the load-bearing one.
        let model = AgentDashboardModel(store: InMemoryHideStore())
        let a = UUID()
        model.rebuild(live: live([a]))
        model.applyAgents(agents([a]))
        _ = model.applyAgentState(a, payload(.working, tool: "Bash"))
        let before = model.entries

        // Same state + same tool -> coalesced: returns false (early return, no rebuild).
        let r = model.applyAgentState(a, payload(.working, tool: "Bash"))
        #expect(r == false)                            // the genuine no-rebuild signal
        #expect(model.entries.map(\.id) == before.map(\.id))  // sanity: membership unchanged
        #expect(model.entries.first?.lastTool == "Bash")
    }

    @Test func newToolUpdatesEntryNotCoalesced() {
        // working -> working but a DIFFERENT tool: not coalesced; lastTool updates.
        let model = AgentDashboardModel(store: InMemoryHideStore())
        let a = UUID()
        model.rebuild(live: live([a]))
        model.applyAgents(agents([a]))
        _ = model.applyAgentState(a, payload(.working, tool: "Bash"))
        let r = model.applyAgentState(a, payload(.working, tool: "Read"))
        #expect(r == false)                       // not entering waiting
        #expect(model.lastTool[a] == "Read")
        #expect(model.entries.first?.lastTool == "Read")
    }

    @Test func nilFieldLeavesPreviousValue() {
        // tool is only present on PreToolUse; a later .idle (tool nil) must LEAVE
        // the sticky lastTool/lastPrompt rather than wiping them.
        let model = AgentDashboardModel(store: InMemoryHideStore())
        let a = UUID()
        model.rebuild(live: live([a]))
        model.applyAgents(agents([a]))
        _ = model.applyAgentState(a, payload(.working, tool: "Bash", prompt: "do it"))
        _ = model.applyAgentState(a, payload(.idle))
        #expect(model.agentStates[a] == .idle)
        #expect(model.lastTool[a] == "Bash")
        #expect(model.lastPrompt[a] == "do it")
    }

    @Test func waitingToIdleDoesNotEnterWaiting() {
        let model = AgentDashboardModel(store: InMemoryHideStore())
        let a = UUID()
        model.rebuild(live: live([a]))
        model.applyAgents(agents([a]))
        _ = model.applyAgentState(a, payload(.waiting, message: "?"))
        let r = model.applyAgentState(a, payload(.idle))
        #expect(r == false)
        #expect(model.agentStates[a] == .idle)
    }

    @Test func entryProjectionCarriesHookFields() {
        let model = AgentDashboardModel(store: InMemoryHideStore())
        let a = UUID()
        model.rebuild(live: live([a]))
        model.applyAgents(agents([a]))
        _ = model.applyAgentState(a, payload(.working, tool: "Grep", prompt: "find foo"))
        let e = model.entries.first { $0.id == a }
        #expect(e?.agentState == .working)
        #expect(e?.lastTool == "Grep")
        #expect(e?.lastPrompt == "find foo")
        #expect(e?.hookBacked == true)
    }

    @Test func hooklessEntryHasNilState() {
        // A detected agent that never POSTed a hook has nil agentState + false
        // hookBacked (the idleSeconds heuristic, if any, is NOT muted).
        let model = AgentDashboardModel(store: InMemoryHideStore())
        let a = UUID()
        model.rebuild(live: live([a]))
        model.applyAgents(agents([a]))
        let e = model.entries.first { $0.id == a }
        #expect(e?.agentState == nil)
        #expect(e?.hookBacked == false)
        #expect(e?.lastTool == nil)
    }

    @Test func dropStalePrunesHookState() {
        // A closed surface's hook state is dropped on rebuild(live:) exactly like
        // bells/agents/lastSeen.
        let model = AgentDashboardModel(store: InMemoryHideStore())
        let a = UUID(), b = UUID()
        model.rebuild(live: live([a, b]))
        model.applyAgents(agents([a, b]))
        _ = model.applyAgentState(a, payload(.waiting, message: "?"))
        _ = model.applyAgentState(b, payload(.working, tool: "Bash"))
        #expect(model.hookBacked.contains(a))
        #expect(model.hookBacked.contains(b))

        // a's surface vanishes: its hook state must be pruned, b's kept.
        model.rebuild(live: live([b]))
        #expect(!model.hookBacked.contains(a))
        #expect(model.agentStates[a] == nil)
        #expect(model.lastMessage[a] == nil)
        #expect(model.hookBacked.contains(b))
        #expect(model.agentStates[b] == .working)
        #expect(model.lastTool[b] == "Bash")
    }

    @Test func waitingSortsFirstViaAttentionKey() {
        // A .waiting (no bell) tile floats above a plain working tile via the
        // attention-first sort key (bell OR waiting).
        let waiting = UUID(), working = UUID()
        let store = InMemoryHideStore()
        let model = AgentDashboardModel(store: store)
        model.rebuild(live: live([waiting, working]))
        model.applyAgents(agents([waiting, working]))
        _ = model.applyAgentState(working, payload(.working))
        _ = model.applyAgentState(waiting, payload(.waiting, message: "?"))
        #expect(model.entries.first?.id == waiting)
    }

    // MARK: - Annotations (ramon fork / Agent Manager)

    private func annotation(_ summary: String) -> AgentAnnotation {
        .init(summary: summary, phase: nil, needsUser: nil)
    }

    @Test func applyAnnotationStoresAndRendersSummary() {
        let model = AgentDashboardModel(store: InMemoryHideStore())
        let a = UUID()
        model.rebuild(live: live([a]))
        model.applyAgents(agents([a]))

        model.applyAnnotation(a, annotation("Running test suite"))
        #expect(model.annotations[a]?.summary == "Running test suite")
        #expect(model.entries.first(where: { $0.id == a })?.annotation?.summary == "Running test suite")
    }

    @Test func applyAnnotationMergesPartialUpdates() {
        // Two independent partial updates — a summary then a phase — MERGE: each
        // preserves the other's field rather than clobbering it.
        let model = AgentDashboardModel(store: InMemoryHideStore())
        let a = UUID()
        model.rebuild(live: live([a]))
        model.applyAgents(agents([a]))

        model.applyAnnotation(a, AgentAnnotation(summary: "Implementing fix"))
        model.applyAnnotation(a, AgentAnnotation(phase: "testing"))
        #expect(model.annotations[a]?.summary == "Implementing fix")  // preserved
        #expect(model.annotations[a]?.phase == "testing")            // added
        // A later summary-only update keeps the phase.
        model.applyAnnotation(a, annotation("Running tests"))
        #expect(model.annotations[a]?.summary == "Running tests")
        #expect(model.annotations[a]?.phase == "testing")
    }

    @Test func annotationPrunedForVanishedSurface() {
        // A closed surface's annotation is dropped on rebuild(live:) like the other
        // per-id state (in-memory only — nothing persisted, just no leak).
        let model = AgentDashboardModel(store: InMemoryHideStore())
        let a = UUID(), b = UUID()
        model.rebuild(live: live([a, b]))
        model.applyAgents(agents([a, b]))
        model.applyAnnotation(a, annotation("a-note"))
        model.applyAnnotation(b, annotation("b-note"))

        model.rebuild(live: live([b]))
        #expect(model.annotations[a] == nil)
        #expect(model.annotations[b]?.summary == "b-note")
    }

    @Test func hookSnapshotCarriesStateAndNotes() {
        let model = AgentDashboardModel(store: InMemoryHideStore())
        let a = UUID()
        model.rebuild(live: live([(a, 11)]))
        model.applyAgents(agents([a]))
        _ = model.applyAgentState(a, payload(.working, tool: "Bash", prompt: "do it"))
        model.applyAnnotation(a, annotation("Implementing fix"))

        let snap = model.hookSnapshot()
        #expect(snap[a]?.agentState == "working")
        #expect(snap[a]?.lastTool == "Bash")
        #expect(snap[a]?.lastPrompt == "do it")
        #expect(snap[a]?.notes == "Implementing fix")
    }

    @Test func hookSnapshotIncludesDetectedAgentButOmitsUnknownSurface() {
        // A DETECTED agent with no hook event/annotation still appears in the
        // snapshot carrying ONLY its agentKind (Phase 2 `agentKind` enrichment:
        // `hookSnapshot()` unions `agents.keys`, so the MCP shaper can report
        // agentKind even without hooks). A surface that is neither a detected
        // agent nor hook-backed is omitted (honest absence).
        let model = AgentDashboardModel(store: InMemoryHideStore())
        let a = UUID(), b = UUID()
        model.rebuild(live: live([a, b]))
        model.applyAgents(agents([a]))          // a is a detected agent; b is not
        let snap = model.hookSnapshot()
        #expect(snap[a]?.agentKind == "claude") // present, agentKind only
        #expect(snap[a]?.agentState == nil)
        #expect(snap[b] == nil)                 // not an agent, no hook → omitted
    }
}

// MARK: - Attention-first sort key (bell OR waiting)

@MainActor
struct AgentDashboardWaitingSortTests {
    private func entry(
        _ id: UUID, bell: Bool, state: AgentState?, backgroundShells: Int = 0
    ) -> AgentEntry {
        .init(id: id, realView: nil, title: "t", pwd: "/x", agent: nil,
              bell: bell, hidden: false, sessionID: 0,
              agentState: state, lastTool: nil, lastPrompt: nil, hookBacked: state != nil,
              annotation: nil,
              backgroundShells: backgroundShells)
    }

    @Test func waitingBeatsWorking() {
        let waiting = UUID(), working = UUID()
        let sorted = AgentDashboardModel.sorted([
            entry(working, bell: false, state: .working),
            entry(waiting, bell: false, state: .waiting),
        ])
        #expect(sorted.first?.id == waiting)
    }

    @Test func bellAndWaitingBothFloatAboveQuiet() {
        let bellOnly = UUID(), waitingOnly = UUID(), quiet = UUID()
        let sorted = AgentDashboardModel.sorted([
            entry(quiet, bell: false, state: .working),
            entry(bellOnly, bell: true, state: .idle),
            entry(waitingOnly, bell: false, state: .waiting),
        ]).map(\.id)
        // Both attention tiles precede the quiet one; quiet is last.
        #expect(sorted.last == quiet)
    }

    @Test func backgroundBusyWaitingIsDemotedFromAttention() {
        // (ramon fork / Agent hooks) A `.waiting` tile with a live background shell
        // is DEMOTED — it is waiting on its own work, not the user. Fixed UUIDs make
        // the tiebreak deterministic: working < bgWaiting lexically.
        let working = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let bgWaiting = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        // Genuine waiting (no shells) floats above working regardless of UUID.
        let genuine = AgentDashboardModel.sorted([
            entry(working, bell: false, state: .working),
            entry(bgWaiting, bell: false, state: .waiting, backgroundShells: 0),
        ]).map(\.id)
        #expect(genuine.first == bgWaiting)        // attention beats uuid
        // Background-busy waiting is demoted → not attention → falls to UUID order,
        // so the working tile (smaller UUID) is now first.
        let demoted = AgentDashboardModel.sorted([
            entry(working, bell: false, state: .working),
            entry(bgWaiting, bell: false, state: .waiting, backgroundShells: 1),
        ]).map(\.id)
        #expect(demoted.first == working)
    }

    @Test func bellStillFloatsEvenWithBackgroundShell() {
        // A bell is a real event: it floats the tile even if a background shell runs.
        let ring = UUID(), quiet = UUID()
        let sorted = AgentDashboardModel.sorted([
            entry(quiet, bell: false, state: .working),
            entry(ring, bell: true, state: .waiting, backgroundShells: 2),
        ]).map(\.id)
        #expect(sorted.first == ring)
    }

    @Test func idleBeatsWorking() {
        // (ramon fork / Agent hooks) An idle agent (free for new work) sorts
        // above a working one. Fixed UUIDs make the tiebreak deterministic:
        // working < idle lexically, so without the idle tier working would win.
        let working = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let idle = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let sorted = AgentDashboardModel.sorted([
            entry(working, bell: false, state: .working),
            entry(idle, bell: false, state: .idle),
        ]).map(\.id)
        #expect(sorted.first == idle)
    }

    @Test func attentionStillOutranksIdle() {
        // Idle floats above working, but a waiting tile (attention) still floats
        // above idle.
        let idle = UUID(), working = UUID(), waiting = UUID()
        let sorted = AgentDashboardModel.sorted([
            entry(idle, bell: false, state: .idle),
            entry(working, bell: false, state: .working),
            entry(waiting, bell: false, state: .waiting),
        ]).map(\.id)
        #expect(sorted == [waiting, idle, working])
    }

    @Test func manualOrderStillOutranksIdle() {
        // An explicit manual rank takes precedence over idle-above-working: the
        // idle tier only orders equal-rank peers. A working tile placed first
        // stays first despite an idle peer placed second.
        let working = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let idle = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let entries = [
            AgentEntry(id: working, realView: nil, title: "t", pwd: "/x", agent: nil,
                       bell: false, hidden: false, sessionID: 10, agentState: .working,
                       lastTool: nil, lastPrompt: nil, hookBacked: true, annotation: nil,
                       backgroundShells: 0),
            AgentEntry(id: idle, realView: nil, title: "t", pwd: "/x", agent: nil,
                       bell: false, hidden: false, sessionID: 20, agentState: .idle,
                       lastTool: nil, lastPrompt: nil, hookBacked: true, annotation: nil,
                       backgroundShells: 0),
        ]
        let rank: [UInt64: Int] = [10: 0, 20: 1]
        let sorted = AgentDashboardModel.sorted(entries, manualRank: rank).map(\.id)
        #expect(sorted == [working, idle])
    }
}

// MARK: - unzoomIfHidden decision (pure transform over SplitTree)

struct UnzoomDecisionTests {
    /// Exercises the SHIPPED decision `BaseTerminalController.unzoomedIfHidden`
    /// (not a clone), so a regression in the production guard / root-preservation
    /// fails the gate. The helper returns `nil` for a no-op; the test treats that
    /// as "tree unchanged".
    private func unzoomed(_ tree: SplitTree<MockView>, target: MockView) -> SplitTree<MockView> {
        BaseTerminalController.unzoomedIfHidden(tree, target: target) ?? tree
    }

    @Test func notZoomedIsNoOp() throws {
        let (tree, v1, _) = try SplitTreeTests.makeHorizontalSplit()
        #expect(tree.zoomed == nil)
        // No-op path returns nil from the production helper.
        #expect(BaseTerminalController.unzoomedIfHidden(tree, target: v1) == nil)
        let result = unzoomed(tree, target: v1)
        #expect(result.zoomed == nil)
        #expect(result.root == tree.root) // unchanged
    }

    @Test func targetInZoomedSubtreeIsNoOp() throws {
        let (base, _, v2) = try SplitTreeTests.makeHorizontalSplit()
        // Zoom onto v2's leaf node.
        let node = base.root?.node(view: v2)
        let zoomed = SplitTree<MockView>(root: base.root, zoomed: node)
        #expect(zoomed.zoomed != nil)
        // Target IS the zoomed split -> preserve the zoom (no-op → nil).
        #expect(BaseTerminalController.unzoomedIfHidden(zoomed, target: v2) == nil)
        let result = unzoomed(zoomed, target: v2)
        #expect(result.zoomed != nil)
    }

    @Test func targetHiddenUnderZoomClears() throws {
        let (base, v1, v2) = try SplitTreeTests.makeHorizontalSplit()
        // Zoom onto v2; target v1 is hidden -> clear zoom, preserve root.
        let node = base.root?.node(view: v2)
        let zoomed = SplitTree<MockView>(root: base.root, zoomed: node)
        let result = unzoomed(zoomed, target: v1)
        #expect(result.zoomed == nil)
        #expect(result.root == base.root) // ratios/structure unchanged
    }
}

// MARK: - Agent-state persistence across GUI restart (ramon fork / hooks)

@MainActor
struct AgentStatePersistenceTests {
    private func live(_ pairs: [(UUID, UInt64)]) -> [AgentDashboardModel.LiveSurface] {
        pairs.map { (id, sid) in .init(id: id, view: nil, title: "t", pwd: "/x", sessionID: sid) }
    }
    private func agents(_ ids: [UUID]) -> [UUID: AgentKind] {
        Dictionary(uniqueKeysWithValues: ids.map { ($0, AgentKind("claude")) })
    }
    private func rec(_ state: String, updated: Double = Date().timeIntervalSince1970) -> PersistedAgentState {
        PersistedAgentState(state: state, tool: nil, prompt: nil, message: nil, updated: updated)
    }
    private func payload(_ s: AgentState, tool: String? = nil) -> AgentStatePayload {
        AgentStatePayload(tty: "ttys1", state: s, prompt: nil, tool: tool, message: nil)
    }

    // MARK: pure prune

    @Test func prunesByAge() {
        let now = Date()
        let nowS = now.timeIntervalSince1970
        let out = AgentDashboardModel.prune(
            [1: rec("working", updated: nowS), 2: rec("idle", updated: nowS - 100_000)],
            now: now, maxAge: 3600, maxCount: 256)
        #expect(out[1] != nil)
        #expect(out[2] == nil)   // older than maxAge dropped
    }

    @Test func prunesByCountKeepingNewest() {
        let nowS = Date().timeIntervalSince1970
        var map: [UInt64: PersistedAgentState] = [:]
        for i in 0..<10 { map[UInt64(i)] = rec("idle", updated: nowS - Double(i)) }
        let out = AgentDashboardModel.prune(map, now: Date(), maxAge: 1_000_000, maxCount: 3)
        #expect(out.count == 3)
        #expect(out[0] != nil && out[1] != nil && out[2] != nil) // newest (closest to now)
        #expect(out[9] == nil)
    }

    // MARK: store round trip (UInt64 keys survive JSON string-keying)

    @Test func userDefaultsStoreRoundTripsUInt64Keys() {
        let suite = "ghostty-test-agentstate-roundtrip"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        defer { d.removePersistentDomain(forName: suite) }
        let store = UserDefaultsAgentStateStore(defaults: d)
        let r = PersistedAgentState(state: "waiting", tool: "Bash", prompt: "hi", message: "approve?", updated: 123)
        store.save([42: r])
        #expect(store.load()[42] == r)
    }

    // MARK: hydrate on rebuild

    @Test func hydratesPersistedStateOntoFreshUUIDBySessionID() {
        let sid: UInt64 = 7
        let model = AgentDashboardModel(
            store: InMemoryHideStore(),
            agentStateStore: InMemoryAgentStateStore([sid: rec("waiting")]))
        let id = UUID()                              // a FRESH uuid (post-restart)
        model.applyAgents(agents([id]))
        model.rebuild(live: live([(id, sid)]))
        #expect(model.agentStates[id] == .waiting)   // restored onto the new uuid
        let entry = model.entries.first { $0.id == id }
        #expect(entry?.agentState == .waiting)       // and the tile shows it
        #expect(entry?.hookBacked == true)           // hook-authoritative
    }

    @Test func hydrateSkipsZeroSession() {
        let model = AgentDashboardModel(
            store: InMemoryHideStore(),
            agentStateStore: InMemoryAgentStateStore([5: rec("idle")]))
        let id = UUID()
        model.applyAgents(agents([id]))
        model.rebuild(live: live([(id, 0)]))         // sessionID 0 → never hydrated
        #expect(model.agentStates[id] == nil)
    }

    @Test func noCrossSessionContamination() {
        let a = UUID(), b = UUID()
        let model = AgentDashboardModel(
            store: InMemoryHideStore(),
            agentStateStore: InMemoryAgentStateStore([1: rec("working"), 2: rec("idle")]))
        model.applyAgents(agents([a, b]))
        model.rebuild(live: live([(a, 1), (b, 2)]))
        #expect(model.agentStates[a] == .working)
        #expect(model.agentStates[b] == .idle)
    }

    // MARK: write-through

    @Test func writeThroughPersistsBySessionID() {
        let sid: UInt64 = 99
        let store = InMemoryAgentStateStore()
        let model = AgentDashboardModel(store: InMemoryHideStore(), agentStateStore: store)
        let id = UUID()
        model.applyAgents(agents([id]))
        model.rebuild(live: live([(id, sid)]))       // populate `live` so the sid resolves
        model.applyAgentState(id, payload(.working, tool: "Bash"))
        #expect(store.load()[sid]?.state == "working")
        #expect(store.load()[sid]?.tool == "Bash")
    }

    @Test func writeThroughSkipsWhenSessionUnknown() {
        let store = InMemoryAgentStateStore()
        let model = AgentDashboardModel(store: InMemoryHideStore(), agentStateStore: store)
        // No rebuild → `live` empty → session id unknown → nothing persisted.
        model.applyAgentState(UUID(), payload(.working))
        #expect(store.load().isEmpty)
    }

    // MARK: live hook overrides a restored state

    @Test func liveHookOverridesHydratedState() {
        let sid: UInt64 = 3
        let store = InMemoryAgentStateStore([sid: rec("working")])
        let model = AgentDashboardModel(store: InMemoryHideStore(), agentStateStore: store)
        let id = UUID()
        model.applyAgents(agents([id]))
        model.rebuild(live: live([(id, sid)]))
        #expect(model.agentStates[id] == .working)        // hydrated
        let entered = model.applyAgentState(id, payload(.waiting))
        #expect(entered == true)                          // working→waiting edge fires
        #expect(model.agentStates[id] == .waiting)        // live wins over restored
        #expect(store.load()[sid]?.state == "waiting")    // and is persisted
    }

    // MARK: prune-on-load re-saves

    @Test func pruneOnLoadDropsAncientAndResaves() {
        let store = InMemoryAgentStateStore([1: rec("idle", updated: 0)])  // 1970 → ancient
        _ = AgentDashboardModel(store: InMemoryHideStore(), agentStateStore: store)
        #expect(store.load().isEmpty)    // pruned + re-saved at init
    }
}

// MARK: - Panel pin (window level)

@MainActor
struct AgentDashboardPanelTests {
    @Test func defaultPanelIsNormalLevel() {
        // Unpinned (default): normal stacking so other windows can cover it, and
        // a non-activating overlay panel (clicking it doesn't steal activation).
        let panel = AgentDashboardPanel()
        #expect(panel.level == .normal)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
    }

    @Test func pinnedPanelFloatsAboveOtherWindows() {
        // `agent-dashboard-pin = true` → floating level (native always-on-top),
        // while the AX subrole stays a standard window (the pin is the level,
        // not the subrole).
        let panel = AgentDashboardPanel(pinned: true)
        #expect(panel.level == .floating)
        #expect(panel.accessibilitySubrole() == .standardWindow)
    }

    @Test func pinnedPanelIsActivatingSoWindowManagersCanTargetIt() {
        // Pinned drops `.nonactivatingPanel` so the panel can become the
        // frontmost app's focused window — which is what Rectangle/Rectangle Pro
        // keyboard shortcuts act on. It must still never become `main`.
        let panel = AgentDashboardPanel(pinned: true)
        #expect(!panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
    }
}

// MARK: - Origin grouping + filter (ramon fork / Agent Queue, §11)

@MainActor
struct AgentDashboardOriginTests {
    /// A tile carrying an optional queue annotation (origin = queueName, else
    /// `(other)`), with a given session for stable identity.
    private func entry(
        _ id: UUID, session: UInt64,
        queueName: String? = nil, queueKey: String? = nil, queueUrl: String? = nil,
        bell: Bool = false, waiting: Bool = false
    ) -> AgentEntry {
        let ann: AgentAnnotation? = (queueName != nil || queueKey != nil || queueUrl != nil)
            ? AgentAnnotation(queueKey: queueKey, queueName: queueName, queueUrl: queueUrl)
            : nil
        return .init(id: id, realView: nil, title: "t", pwd: "/x", agent: AgentKind("claude"),
                     bell: bell, hidden: false, sessionID: session,
                     agentState: waiting ? .waiting : nil,
                     lastTool: nil, lastPrompt: nil, hookBacked: false,
                     annotation: ann,
                     backgroundShells: 0)
    }

    // MARK: pure origin/grouping/filter

    @Test func originIsQueueNameElseOther() {
        let q = entry(UUID(), session: 1, queueName: "backlog")
        let n = entry(UUID(), session: 2)
        let blank = entry(UUID(), session: 3, queueName: "")  // empty name → (other)
        #expect(AgentDashboardModel.origin(of: q) == "backlog")
        #expect(AgentDashboardModel.origin(of: n) == AgentDashboardModel.otherOrigin)
        #expect(AgentDashboardModel.origin(of: blank) == AgentDashboardModel.otherOrigin)
    }

    @Test func knownOriginsCollectsDistinct() {
        let es = [
            entry(UUID(), session: 1, queueName: "alpha"),
            entry(UUID(), session: 2, queueName: "beta"),
            entry(UUID(), session: 3),                          // (other)
            entry(UUID(), session: 4, queueName: "alpha"),      // dup
        ]
        #expect(AgentDashboardModel.knownOrigins(in: es)
            == ["alpha", "beta", AgentDashboardModel.otherOrigin])
    }

    @Test func groupByOriginPutsOtherLastAndSortsQueues() {
        let es = [
            entry(UUID(), session: 1),                          // (other)
            entry(UUID(), session: 2, queueName: "Zeta"),
            entry(UUID(), session: 3, queueName: "alpha"),
        ]
        let sections = AgentDashboardModel.groupByOrigin(es)
        #expect(sections.map(\.id) == ["alpha", "Zeta", AgentDashboardModel.otherOrigin])
        #expect(sections.last?.isOther == true)
        #expect(sections.first?.count == 1)
    }

    @Test func groupByOriginPreservesInputOrderWithinSection() {
        // Input order (the global sort) is preserved inside each section.
        let a = entry(UUID(), session: 10, queueName: "q")
        let b = entry(UUID(), session: 20, queueName: "q")
        let sections = AgentDashboardModel.groupByOrigin([a, b])
        #expect(sections.count == 1)
        #expect(sections[0].entries.map(\.sessionID) == [10, 20])
    }

    @Test func applyOriginFilterDropsExcluded() {
        let es = [
            entry(UUID(), session: 1, queueName: "alpha"),
            entry(UUID(), session: 2, queueName: "beta"),
            entry(UUID(), session: 3),                          // (other)
        ]
        let kept = AgentDashboardModel.applyOriginFilter(es, excluded: ["beta"])
        #expect(kept.map(\.sessionID) == [1, 3])
        // Empty exclusion is identity.
        #expect(AgentDashboardModel.applyOriginFilter(es, excluded: []).count == 3)
    }

    // MARK: model instance: filter state, persistence, sections

    private func live(_ pairs: [(UUID, UInt64)]) -> [AgentDashboardModel.LiveSurface] {
        pairs.map { .init(id: $0.0, view: nil, title: "t", pwd: "/x", sessionID: $0.1) }
    }
    private func agents(_ ids: [UUID]) -> [UUID: AgentKind] {
        Dictionary(uniqueKeysWithValues: ids.map { ($0, AgentKind("claude")) })
    }

    @Test func toggleOriginPersistsAndFiltersSections() {
        let filterStore = InMemoryOriginFilterStore()
        let model = AgentDashboardModel(
            store: InMemoryHideStore(), originFilterStore: filterStore)
        let a = UUID(), b = UUID()
        model.rebuild(live: live([(a, 1), (b, 2)]))
        model.applyAgents(agents([a, b]))
        model.applyAnnotation(a, AgentAnnotation(queueName: "alpha"))
        model.applyAnnotation(b, AgentAnnotation(queueName: "beta"))

        // Both origins visible.
        #expect(model.knownOrigins == ["alpha", "beta"])
        #expect(model.sections.map(\.id) == ["alpha", "beta"])

        // Exclude beta → only alpha's tiles remain; persisted.
        model.toggleOrigin("beta")
        #expect(model.excludedOrigins == ["beta"])
        #expect(filterStore.load() == ["beta"])
        #expect(model.sections.map(\.id) == ["alpha"])
        // The filter bar still offers beta (knownOrigins is the unfiltered set).
        #expect(model.knownOrigins == ["alpha", "beta"])

        // Re-include via showAllOrigins → both back; persisted clear.
        model.showAllOrigins()
        #expect(model.excludedOrigins.isEmpty)
        #expect(filterStore.load().isEmpty)
        #expect(model.sections.map(\.id) == ["alpha", "beta"])
    }

    @Test func soloExclusionIsolatesAndToggles() {
        // Pure helper: solo X → exclude all others; solo X again (already isolated) → clear.
        let known: Set<String> = ["alpha", "beta", "(other)"]
        let isolated = AgentDashboardModel.soloExclusion("alpha", known: known, current: [])
        #expect(isolated == ["beta", "(other)"])
        // Tapping the already-soloed origin clears (show all).
        #expect(AgentDashboardModel.soloExclusion("alpha", known: known, current: isolated) == [])
        // Soloing a different origin re-isolates to it.
        #expect(AgentDashboardModel.soloExclusion("beta", known: known, current: isolated) == ["alpha", "(other)"])
    }

    @Test func soloOriginPersistsAndFiltersSections() {
        let filterStore = InMemoryOriginFilterStore()
        let model = AgentDashboardModel(
            store: InMemoryHideStore(), originFilterStore: filterStore)
        let a = UUID(), b = UUID()
        model.rebuild(live: live([(a, 1), (b, 2)]))
        model.applyAgents(agents([a, b]))
        model.applyAnnotation(a, AgentAnnotation(queueName: "alpha"))
        model.applyAnnotation(b, AgentAnnotation(queueName: "beta"))

        // Solo alpha → only alpha shown (beta excluded); persisted.
        model.soloOrigin("alpha")
        #expect(model.excludedOrigins == ["beta"])
        #expect(model.sections.map(\.id) == ["alpha"])
        // Solo alpha again → show all.
        model.soloOrigin("alpha")
        #expect(model.excludedOrigins.isEmpty)
        #expect(model.sections.map(\.id) == ["alpha", "beta"])
    }

    @Test func excludedFilterLoadsFromStoreAtInit() {
        let model = AgentDashboardModel(
            store: InMemoryHideStore(),
            originFilterStore: InMemoryOriginFilterStore(["muted"]))
        #expect(model.excludedOrigins == ["muted"])
    }

    @Test func filterIsViewOnly_excludedStillInEntries() {
        // The origin filter is a VIEW filter: `entries` (the attention/auto-unhide
        // universe) keeps the excluded tile; only `sections` (the displayed,
        // grouped, filtered view) drops it — so an excluded-but-ringing agent is
        // never muted.
        let model = AgentDashboardModel(
            store: InMemoryHideStore(),
            originFilterStore: InMemoryOriginFilterStore(["beta"]))
        let a = UUID(), b = UUID()
        model.rebuild(live: live([(a, 1), (b, 2)]))
        model.applyAgents(agents([a, b]))
        model.applyAnnotation(a, AgentAnnotation(queueName: "alpha"))
        model.applyAnnotation(b, AgentAnnotation(queueName: "beta"))
        // entries keeps BOTH (the model's attention universe is unfiltered).
        #expect(Set(model.entries.map(\.sessionID)) == [1, 2])
        // sections drops the excluded beta tile.
        #expect(model.sections.flatMap { $0.entries }.map(\.sessionID) == [1])
    }
}

/// (ramon fork / Agent Queue, §11 health) Tests for the queue-health pieces: the
/// status apply/clear, the present-queue empty-section grouping (so the bar shows with
/// no/all-hidden tiles), and the pure header text formatting.
@MainActor
struct AgentQueueHealthTests {
    private func status(
        _ name: String, present: Bool = true, phase: String = "running",
        queued: Int = 0, listOk: Bool = true, active: Int = 0, dispatched: Int = 0,
        maxItems: Int? = nil, next: [QueueStatus.Item] = [], running: [QueueStatus.Item] = []
    ) -> QueueStatus {
        .init(queueName: name, present: present, phase: phase, queued: queued,
              listOk: listOk, active: active, dispatched: dispatched,
              maxItems: maxItems, next: next, running: running)
    }

    // MARK: - groupByOrigin present-queue injection

    @Test func presentQueueGetsEmptySectionWhenNoTiles() {
        // The "scary blank" / all-hidden fix: a present queue with NO entries still
        // produces a section (so its bar/header renders).
        let sections = AgentDashboardModel.groupByOrigin([], presentQueues: ["ExampleOS"])
        #expect(sections.map(\.id) == ["ExampleOS"])
        #expect(sections.first?.entries.isEmpty == true)
    }

    @Test func presentQueueNotDuplicatedAndOtherExcluded() {
        // A present queue that already has tiles isn't duplicated; `(other)` is never
        // injected as a queue even if (defensively) passed in.
        let e = AgentEntry(id: UUID(), realView: nil, title: "t", pwd: "/x", agent: nil,
                           bell: false, hidden: false, sessionID: 1,
                           agentState: nil, lastTool: nil, lastPrompt: nil, hookBacked: false,
                           annotation: AgentAnnotation(queueName: "ExampleOS"),
                           backgroundShells: 0)
        let sections = AgentDashboardModel.groupByOrigin(
            [e], presentQueues: ["ExampleOS", AgentDashboardModel.otherOrigin])
        #expect(sections.map(\.id) == ["ExampleOS"])      // no dup, no (other) injected
        #expect(sections.first?.entries.count == 1)
    }

    // MARK: - applyQueueStatus store / clear + sections

    @Test func applyStoresAndClearsByPresence() {
        let model = AgentDashboardModel(store: InMemoryHideStore())
        model.applyQueueStatus(status("ExampleOS", queued: 5))
        #expect(model.queueStatuses["ExampleOS"]?.queued == 5)
        // A present:false report removes it.
        model.applyQueueStatus(status("ExampleOS", present: false))
        #expect(model.queueStatuses["ExampleOS"] == nil)
    }

    @Test func sectionsShowPresentQueueWithNoTiles() {
        // No agents at all, but a queue reported present → sections has its header section.
        let model = AgentDashboardModel(store: InMemoryHideStore())
        model.applyQueueStatus(status("ExampleOS", queued: 3))
        #expect(model.entries.isEmpty)
        #expect(model.sections.map(\.id) == ["ExampleOS"])
    }

    // MARK: - QueueHealthFormat.progressText (dispatched/cap; ∞ = unlimited)

    @Test func progressTextShowsDispatchedOverCap() {
        #expect(QueueHealthFormat.progressText(status("Q", dispatched: 2, maxItems: 3)) == "2/3")
    }

    @Test func progressTextUnlimitedCapIsInfinity() {
        #expect(QueueHealthFormat.progressText(status("Q", dispatched: 4, maxItems: nil)) == "4/∞")
    }

    // MARK: - applyQueueStatus carries next/running items (for the dropdowns)

    @Test func surfaceIDResolvesByQueueNameAndKey() {
        let model = AgentDashboardModel(store: InMemoryHideStore())
        let a = UUID(), b = UUID()
        model.applyAnnotation(a, AgentAnnotation(queueKey: "EX-1", queueName: "ExampleOS"))
        model.applyAnnotation(b, AgentAnnotation(queueKey: "EX-2", queueName: "ExampleOS"))
        #expect(model.surfaceID(forQueue: "ExampleOS", key: "EX-2") == b)
        #expect(model.surfaceID(forQueue: "ExampleOS", key: "NOPE") == nil)   // unknown key
        #expect(model.surfaceID(forQueue: "Other", key: "EX-1") == nil)      // wrong queue
    }

    @Test func applyKeepsNextAndRunningItems() {
        let model = AgentDashboardModel(store: InMemoryHideStore())
        model.applyQueueStatus(status(
            "ExampleOS", queued: 1, active: 1,
            next: [QueueStatus.Item(key: "EX-2", title: "Wait", url: "https://linear.app/x/EX-2")],
            running: [QueueStatus.Item(key: "EX-1", title: "Run", url: "https://linear.app/x/EX-1")]))
        #expect(model.queueStatuses["ExampleOS"]?.next.first?.url == "https://linear.app/x/EX-2")
        #expect(model.queueStatuses["ExampleOS"]?.running.first?.key == "EX-1")
    }
}
