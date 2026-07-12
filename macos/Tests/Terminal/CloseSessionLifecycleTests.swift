import AppKit
import Testing
@testable import Ghostty

// (ramon fork) Close-session lifecycle (Feature A) — Swift-side pure decisions.
//
// The end-to-end wire behavior (threadExit sends `protocol.Close` only on a
// deliberate close of an attached, non-mirror, non-quitting client) is proven by
// the Zig lifecycle tests in `src/termio/client_difftest.zig`. Here we cover the
// GUI-side decisions that are pure + injectable — extracted precisely so they can
// be tested without a live libghostty surface / controller / NSApp:
//   * which leaves a close marks (moves excluded via a held-elsewhere predicate),
//   * the last-window-close -> DETACH prediction matrix, and
//   * that leaf enumeration includes zoom-hidden splits (tab/window fan-out).
struct CloseSessionLifecycleTests {
    // MARK: leavesToMarkForClose — move exclusion

    @Test func marksEveryLeafWhenNoneHeldElsewhere() {
        let a = MockView(), b = MockView(), c = MockView()
        let result = BaseTerminalController.leavesToMarkForClose([a, b, c]) { _ in false }
        #expect(result.map(\.id) == [a, b, c].map(\.id))
    }

    @Test func skipsLeavesHeldByAnotherController() {
        // A MOVE reparented `b` into another live controller — it must NOT be
        // marked (its session is alive elsewhere). `a`/`c` are a genuine close.
        let a = MockView(), b = MockView(), c = MockView()
        let result = BaseTerminalController.leavesToMarkForClose([a, b, c]) { v in
            v.id == b.id
        }
        #expect(result.map(\.id) == [a.id, c.id])
    }

    @Test func marksNothingWhenAllHeldElsewhere() {
        // The move-empties-source case: every leaf was reparented, so a close of
        // the emptied tab marks nothing (the rev.4 hole guard, predicate form).
        let a = MockView(), b = MockView()
        let result = BaseTerminalController.leavesToMarkForClose([a, b]) { _ in true }
        #expect(result.isEmpty)
    }

    // MARK: closingLeaves — the PRIMARY move-exclusion (deliberateClose gate)

    @Test func deliberateCloseCarriesItsLeaves() {
        // A deliberate close (close_surface / the confirm-free fast path) passes
        // deliberateClose:true, so removeSurfaceNode carries the leaves as
        // closingViews -> replaceSurfaceTree marks them for destruction.
        let a = MockView(), b = MockView()
        let result = BaseTerminalController.closingLeaves(
            deliberateClose: true, leaves: [a, b])
        #expect(result?.map(\.id) == [a.id, b.id])
    }

    @Test func moveRemovalCarriesNilSoNothingIsEverMarked() {
        // A MOVE removal (move_split_to_new_tab / pull_marked_split / merge_tabs /
        // swap_split / drag-drop / queue retile) takes the DEFAULT
        // deliberateClose:false, so closingViews is nil -> replaceSurfaceTree
        // marks NOTHING and the reparented live view's session is never destroyed.
        // This is the invariant most likely to regress silently.
        let a = MockView(), b = MockView()
        let result = BaseTerminalController.closingLeaves(
            deliberateClose: false, leaves: [a, b])
        #expect(result == nil)
    }

    // MARK: windowCloseWouldTerminate — last-window DETACH matrix

    @Test func lastWindowTriggersTerminationOnlyWhenQuittingAndNoneRemain() {
        // (shouldQuit, remainingCount) -> detach?
        #expect(BaseTerminalController_windowWouldTerminate(true, 0) == true)
        #expect(BaseTerminalController_windowWouldTerminate(true, 1) == false)
        #expect(BaseTerminalController_windowWouldTerminate(true, 3) == false)
        #expect(BaseTerminalController_windowWouldTerminate(false, 0) == false)
        #expect(BaseTerminalController_windowWouldTerminate(false, 2) == false)
    }

    private func BaseTerminalController_windowWouldTerminate(
        _ quit: Bool, _ remaining: Int
    ) -> Bool {
        TerminalController.windowCloseWouldTerminate(
            shouldQuitAfterLastWindowClosed: quit,
            remainingTerminalWindowCount: remaining)
    }

    // MARK: leaf enumeration includes zoom-hidden splits

    @Test func rootLeavesIncludeZoomHiddenSplit() throws {
        // A tab/window close fans out to EVERY leaf, including one hidden under a
        // sibling's zoom. `root.leaves()` is what markLeavesForClose iterates, so
        // this proves a zoom-hidden session is still marked for destruction.
        let (base, v1, v2) = try SplitTreeTests.makeHorizontalSplit()
        let zoomedNode = base.root?.node(view: v2)
        let zoomed = SplitTree<MockView>(root: base.root, zoomed: zoomedNode)
        #expect(zoomed.zoomed != nil) // v1 is hidden under v2's zoom
        let leafIDs = Set((zoomed.root?.leaves() ?? []).map(\.id))
        #expect(leafIDs == Set([v1.id, v2.id]))
    }

    // MARK: closeMarkOperations — the recorder seam (mark -> clear -> re-mark)

    // A recorder that "applies" the phase ops exactly as the shipped
    // `applyCloseMark` does (running the pure `closeMarkOperations` decision),
    // but records (id, close) instead of touching a live surface's session. This
    // proves the full deliberate-close -> undo -> redo ordering, and the
    // MOVE-never-marks rule, without a live controller/surface.
    private func record(
        _ phases: [(BaseTerminalController.CloseMarkPhase, [MockView]?)],
        heldElsewhere: (MockView) -> Bool = { _ in false }
    ) -> [(id: MockView.ID, close: Bool)] {
        var log: [(id: MockView.ID, close: Bool)] = []
        for (phase, views) in phases {
            for op in BaseTerminalController.closeMarkOperations(
                phase, closingViews: views, heldElsewhere: heldElsewhere
            ) {
                log.append((id: op.view.id, close: op.close))
            }
        }
        return log
    }

    @Test func recorderSeesMarkThenClearThenRemark() {
        // The load-bearing sequence: a DELIBERATE close marks every leaf; UNDO
        // (restoring the live views) clears every mark; REDO re-marks. If the
        // undo-clear ever regressed, an undo-restored LIVE session would keep its
        // close-mark and be DESTROYED on a later teardown (data loss).
        let a = MockView(), b = MockView()
        let log = record([
            (.set, [a, b]),   // deliberate close
            (.undo, [a, b]),  // undo restores the live views
            (.redo, [a, b]),  // redo re-applies the close
        ])
        #expect(log.map { $0.close } == [true, true, false, false, true, true])
        #expect(log.map { $0.id } == [a.id, b.id, a.id, b.id, a.id, b.id])
    }

    @Test func moveMarksNothingInEveryPhase() {
        // A MOVE passes nil closing views, so NOTHING is marked/cleared in any
        // phase — the reparented live view is never touched.
        for phase: BaseTerminalController.CloseMarkPhase in [.set, .undo, .redo] {
            let ops = BaseTerminalController.closeMarkOperations(
                phase, closingViews: [MockView]?.none, heldElsewhere: { _ in false })
            #expect(ops.isEmpty)
        }
    }

    @Test func setAndRedoSkipLeafHeldElsewhere() {
        // .set / .redo apply the move-exclusion: a leaf a concurrent move already
        // reparented elsewhere is NOT marked for destruction.
        let a = MockView(), b = MockView()
        for phase: BaseTerminalController.CloseMarkPhase in [.set, .redo] {
            let ops = BaseTerminalController.closeMarkOperations(
                phase, closingViews: [a, b], heldElsewhere: { $0.id == b.id })
            #expect(ops.map { $0.view.id } == [a.id])
            #expect(ops.allSatisfy { $0.close })
        }
    }

    @Test func undoClearsUnconditionallyEvenWhenHeldElsewhere() {
        // The undo-clear does NOT apply the held-elsewhere filter: clearing is the
        // data-loss-safe direction, and clearing a never-set mark is a safe no-op.
        let a = MockView(), b = MockView()
        let ops = BaseTerminalController.closeMarkOperations(
            .undo, closingViews: [a, b], heldElsewhere: { _ in true })
        #expect(ops.map { $0.view.id } == [a.id, b.id])
        #expect(ops.allSatisfy { !$0.close })
    }

    // MARK: controller-level move-empties-source + close-mark guards (Feature A)

    @Test func moveEmptiedSourceNeverMarksLeaves() {
        // The replaceSurfaceTree empty-tree branch (reached ONLY by a move that
        // emptied the source tab) passes this constant as closeTabImmediately's
        // markLeaves. It is the SOLE protection against destroying a moved-away
        // live session (the viewHeldByAnotherController backstop cannot catch the
        // reparented view yet — the destination install runs after the removal).
        // A regression flipping it to true would silently kill moved sessions.
        #expect(TerminalController.moveEmptiedSourceMarksLeaves == false)
    }

    @Test func shouldMarkLeavesOnCloseMatrix() {
        // (isMoveEmptiedSource, triggersAppTermination) -> mark?
        // Marks ONLY on a genuine deliberate close that does not terminate the app.
        #expect(TerminalController.shouldMarkLeavesOnClose(
            isMoveEmptiedSource: false, triggersAppTermination: false) == true)
        // A move never marks (protects a reparented live session).
        #expect(TerminalController.shouldMarkLeavesOnClose(
            isMoveEmptiedSource: true, triggersAppTermination: false) == false)
        // A last-window close that terminates the app detaches for reattach.
        #expect(TerminalController.shouldMarkLeavesOnClose(
            isMoveEmptiedSource: false, triggersAppTermination: true) == false)
        #expect(TerminalController.shouldMarkLeavesOnClose(
            isMoveEmptiedSource: true, triggersAppTermination: true) == false)
    }

    // MARK: commit-delay boundary (Feature A)

    @Test func closeCommitDelayIsUndoWindowPlusMargin() {
        // The deliberate-close commit fires strictly AFTER the undo window so ⌘Z
        // can no longer race it: undo-seconds + a fixed 0.5s margin, floored at 0.
        func approx(_ a: TimeInterval, _ b: TimeInterval) -> Bool { abs(a - b) < 1e-6 }
        #expect(approx(BaseTerminalController.closeCommitDelay(.seconds(30)), 30.5))
        #expect(approx(BaseTerminalController.closeCommitDelay(.seconds(0)), 0.5))
        #expect(approx(BaseTerminalController.closeCommitDelay(.milliseconds(500)), 1.0))
        // A degenerate negative duration floors to 0 before the margin.
        #expect(approx(BaseTerminalController.closeCommitDelay(.seconds(-5)), 0.5))
    }
}
