import AppKit
import Testing
@testable import Ghostty

class MockView: NSView, Codable, Identifiable {
    let id: UUID

    init(id: UUID = UUID()) {
        self.id = id
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    enum CodingKeys: CodingKey { case id }

    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        super.init(frame: .zero)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
    }
}

struct SplitTreeTests {
    /// Creates a two-view horizontal split tree (view1 | view2).
    static func makeHorizontalSplit() throws -> (SplitTree<MockView>, MockView, MockView) {
        let view1 = MockView()
        let view2 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)
        return (tree, view1, view2)
    }

    /// Creates a two-view horizontal split tree (view1 | view2).
    private func makeHorizontalSplit() throws -> (SplitTree<MockView>, MockView, MockView) {
        try Self.makeHorizontalSplit()
    }

    // MARK: - Empty and Non-Empty

    @Test func emptyTreeIsEmpty() {
        let tree = SplitTree<MockView>()
        #expect(tree.isEmpty)
    }

    @Test func nonEmptyTreeIsNotEmpty() {
        let view1 = MockView()
        let tree = SplitTree<MockView>(view: view1)
        #expect(!tree.isEmpty)
    }

    @Test func isNotSplit() {
        let view1 = MockView()
        let tree = SplitTree<MockView>(view: view1)
        #expect(!tree.isSplit)
    }

    @Test func isSplit() throws {
        let (tree, _, _) = try makeHorizontalSplit()
        #expect(tree.isSplit)
    }

    // MARK: - Contains and Find

    @Test func treeContainsView() {
        let view = MockView()
        let tree = SplitTree<MockView>(view: view)
        #expect(tree.contains(.leaf(view: view)))
    }

    @Test func treeDoesNotContainView() {
        let view = MockView()
        let tree = SplitTree<MockView>()
        #expect(!tree.contains(.leaf(view: view)))
    }

    @Test func findsInsertedView() throws {
        let (tree, view1, _) = try makeHorizontalSplit()
        #expect((tree.find(id: view1.id) != nil))
    }

    @Test func doesNotFindUninsertedView() {
        let view1 = MockView()
        let view2 = MockView()
        let tree = SplitTree<MockView>(view: view1)
        #expect((tree.find(id: view2.id) == nil))
    }

    // MARK: - Removing and Replacing

    @Test func treeDoesNotContainRemovedView() throws {
        var (tree, view1, view2) = try makeHorizontalSplit()
        tree = tree.removing(.leaf(view: view1))
        #expect(!tree.contains(.leaf(view: view1)))
        #expect(tree.contains(.leaf(view: view2)))
    }

    @Test func removingNonexistentNodeLeavesTreeUnchanged() {
        let view1 = MockView()
        let view2 = MockView()
        let tree = SplitTree<MockView>(view: view1)
        let result = tree.removing(.leaf(view: view2))
        #expect(result.contains(.leaf(view: view1)))
        #expect(!result.isEmpty)
    }

    @Test func replacingViewShouldRemoveAndInsertView() throws {
        let view1 = MockView()
        let view2 = MockView()
        let view3 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)
        #expect(tree.contains(.leaf(view: view2)))
        let result = try tree.replacing(node: .leaf(view: view2), with: .leaf(view: view3))
        #expect(result.contains(.leaf(view: view1)))
        #expect(!result.contains(.leaf(view: view2)))
        #expect(result.contains(.leaf(view: view3)))
    }

    @Test func replacingViewWithItselfShouldBeAValidOperation() throws {
        let (tree, view1, view2) = try makeHorizontalSplit()
        let result = try tree.replacing(node: .leaf(view: view2), with: .leaf(view: view2))
        #expect(result.contains(.leaf(view: view1)))
        #expect(result.contains(.leaf(view: view2)))
    }

    // MARK: - Focus Target

    @Test func focusTargetOnEmptyTreeReturnsNil() {
        let tree = SplitTree<MockView>()
        let view = MockView()
        let target = tree.focusTarget(for: .next, from: .leaf(view: view))
        #expect(target == nil)
    }

    @Test func focusTargetShouldFindNextFocusedNode() throws {
        let (tree, view1, view2) = try makeHorizontalSplit()
        let target = tree.focusTarget(for: .next, from: .leaf(view: view1))
        #expect(target === view2)
    }

    @Test func focusTargetShouldFindItselfWhenOnlyView() throws {
        let view1 = MockView()
        let tree = SplitTree<MockView>(view: view1)

        let target = tree.focusTarget(for: .next, from: .leaf(view: view1))
        #expect(target === view1)
    }

    // When there's no next view, wraps around to the first
    @Test func focusTargetShouldHandleWrappingForNextNode() throws {
        let (tree, view1, view2) = try makeHorizontalSplit()
        let target = tree.focusTarget(for: .next, from: .leaf(view: view2))
        #expect(target === view1)
    }

    @Test func focusTargetShouldFindPreviousFocusedNode() throws {
        let (tree, view1, view2) = try makeHorizontalSplit()
        let target = tree.focusTarget(for: .previous, from: .leaf(view: view2))
        #expect(target === view1)
    }

    @Test func focusTargetShouldFindSpatialFocusedNode() throws {
        let (tree, view1, view2) = try makeHorizontalSplit()
        let target = tree.focusTarget(for: .spatial(.left), from: .leaf(view: view2))
        #expect(target === view1)
    }

    // Fork: spatial navigation cycles at the edge. With three panes in a row,
    // moving right from the rightmost wraps to the leftmost, and moving left
    // from the leftmost wraps to the rightmost.
    @Test func focusTargetSpatialWrapsAtRightEdge() throws {
        let v1 = MockView()
        let v2 = MockView()
        let v3 = MockView()
        var tree = SplitTree<MockView>(view: v1)
        tree = try tree.inserting(view: v2, at: v1, direction: .right)
        tree = try tree.inserting(view: v3, at: v2, direction: .right)
        // Row is v1 | v2 | v3 left-to-right.
        #expect(tree.focusTarget(for: .spatial(.right), from: .leaf(view: v3)) === v1)
        #expect(tree.focusTarget(for: .spatial(.left), from: .leaf(view: v1)) === v3)
    }

    @Test func focusTargetSpatialWrapsAtVerticalEdge() throws {
        let v1 = MockView()
        let v2 = MockView()
        var tree = SplitTree<MockView>(view: v1)
        tree = try tree.inserting(view: v2, at: v1, direction: .down)
        // Column is v1 over v2.
        #expect(tree.focusTarget(for: .spatial(.down), from: .leaf(view: v2)) === v1)
        #expect(tree.focusTarget(for: .spatial(.up), from: .leaf(view: v1)) === v2)
    }

    // A single pane has nothing to wrap to.
    @Test func focusTargetSpatialNoWrapWhenSinglePane() throws {
        let view1 = MockView()
        let tree = SplitTree<MockView>(view: view1)
        #expect(tree.focusTarget(for: .spatial(.right), from: .leaf(view: view1)) == nil)
    }

    // MARK: - Equalized

    @Test func equalizedAdjustsRatioByLeafCount() throws {
        let view1 = MockView()
        let view2 = MockView()
        let view3 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)
        tree = try tree.inserting(view: view3, at: view2, direction: .right)

        guard case .split(let before) = tree.root else {
            Issue.record("unexpected node type")
            return
        }
        #expect(abs(before.ratio - 0.5) < 0.001)

        let equalized = tree.equalized()

        if case .split(let s) = equalized.root {
            #expect(abs(s.ratio - 1.0/3.0) < 0.001)
        }
    }

    // MARK: - Resizing

    @Test(arguments: [
        // (resizeDirection, insertDirection, bounds, pixels, expectedRatio)
        (SplitTree<MockView>.Spatial.Direction.right, SplitTree<MockView>.NewDirection.right,
         CGRect(x: 0, y: 0, width: 1000, height: 500), UInt16(100), 0.6),
        (.left, .right,
         CGRect(x: 0, y: 0, width: 1000, height: 500), UInt16(50), 0.45),
        (.down, .down,
         CGRect(x: 0, y: 0, width: 500, height: 1000), UInt16(200), 0.7),
        (.up, .down,
         CGRect(x: 0, y: 0, width: 500, height: 1000), UInt16(50), 0.45),
    ])
    func resizingAdjustsRatio(
        resizeDirection: SplitTree<MockView>.Spatial.Direction,
        insertDirection: SplitTree<MockView>.NewDirection,
        bounds: CGRect,
        pixels: UInt16,
        expectedRatio: Double
    ) throws {
        let view1 = MockView()
        let view2 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: insertDirection)

        let resized = try tree.resizing(node: .leaf(view: view1), by: pixels, in: resizeDirection, with: bounds)

        guard case .split(let s) = resized.root else {
            Issue.record("unexpected node type")
            return
        }
        #expect(abs(s.ratio - expectedRatio) < 0.001)
    }

    // MARK: - Flip (mirror) split

    // Nested layout for the walk-up tests:  view1 | (view2 / view3)
    //   root: horizontal { left: view1, right: vertical { view2, view3 } }
    private func makeNestedTree() throws -> (SplitTree<MockView>, MockView, MockView, MockView) {
        let view1 = MockView()
        let view2 = MockView()
        let view3 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)
        tree = try tree.inserting(view: view3, at: view2, direction: .down)
        return (tree, view1, view2, view3)
    }

    @Test func flippingSplitSwapsSides() throws {
        let (tree, view1, view2) = try makeHorizontalSplit()
        let flipped = try tree.flippingSplit(containing: view1, orientation: .horizontal)
        guard case .split(let s) = flipped.root else {
            Issue.record("unexpected node type")
            return
        }
        #expect(s.direction == .horizontal)
        #expect(s.left == .leaf(view: view2))
        #expect(s.right == .leaf(view: view1))
    }

    @Test func flippingSplitInvertsRatioToKeepDividerInPlace() throws {
        let (tree, view1, _) = try makeHorizontalSplit()
        // Skew the root split so the inversion is observable.
        let skewed = try tree.replacing(node: tree.root!, with: tree.root!.resizing(to: 0.3))
        let flipped = try skewed.flippingSplit(containing: view1, orientation: .horizontal)
        guard case .split(let s) = flipped.root else {
            Issue.record("unexpected node type")
            return
        }
        #expect(abs(s.ratio - 0.7) < 0.001)
    }

    @Test func flippingSplitTwiceRestoresOriginal() throws {
        let (tree, view1, view2) = try makeHorizontalSplit()
        let skewed = try tree.replacing(node: tree.root!, with: tree.root!.resizing(to: 0.3))
        let twice = try skewed
            .flippingSplit(containing: view1, orientation: .horizontal)
            .flippingSplit(containing: view1, orientation: .horizontal)
        guard case .split(let s) = twice.root else {
            Issue.record("unexpected node type")
            return
        }
        #expect(s.left == .leaf(view: view1))
        #expect(s.right == .leaf(view: view2))
        #expect(abs(s.ratio - 0.3) < 0.001)
    }

    @Test func flippingWithNoEnclosingSplitOfOrientationThrows() {
        let view = MockView()
        let tree = SplitTree<MockView>(view: view)
        // Use do/catch rather than #expect(throws:) because the latter requires
        // a @Sendable closure, and MockView (an NSView) is main-actor-isolated.
        var threw = false
        do {
            _ = try tree.flippingSplit(containing: view, orientation: .horizontal)
        } catch {
            threw = true
        }
        #expect(threw)
    }

    @Test func flipTargetsInnerSplitForMatchingOrientation() throws {
        let (tree, view1, view2, view3) = try makeNestedTree()

        // From view3, the nearest VERTICAL enclosing split is the inner one.
        let flipped = try tree.flippingSplit(containing: view3, orientation: .vertical)

        guard case .split(let root) = flipped.root else {
            Issue.record("unexpected root node type")
            return
        }
        // Outer split untouched.
        #expect(root.direction == .horizontal)
        #expect(root.left == .leaf(view: view1))
        // Inner split swapped.
        guard case .split(let inner) = root.right else {
            Issue.record("unexpected inner node type")
            return
        }
        #expect(inner.direction == .vertical)
        #expect(inner.left == .leaf(view: view3))
        #expect(inner.right == .leaf(view: view2))
    }

    @Test func flipWalksUpToOuterSplitByOrientation() throws {
        let (tree, view1, view2, view3) = try makeNestedTree()

        // From view3, the nearest HORIZONTAL enclosing split is the OUTER one,
        // reached by walking past the inner vertical split.
        let flipped = try tree.flippingSplit(containing: view3, orientation: .horizontal)

        guard case .split(let root) = flipped.root else {
            Issue.record("unexpected root node type")
            return
        }
        // Outer split swapped: the vertical pair moves to the left, view1 to the right.
        #expect(root.direction == .horizontal)
        #expect(root.right == .leaf(view: view1))
        // Inner split unchanged, now on the left.
        guard case .split(let inner) = root.left else {
            Issue.record("unexpected inner node type")
            return
        }
        #expect(inner.direction == .vertical)
        #expect(inner.left == .leaf(view: view2))
        #expect(inner.right == .leaf(view: view3))
    }

    // MARK: - Toggle split direction

    @Test func togglingDirectionFlipsOrientation() throws {
        let (tree, view1, view2) = try makeHorizontalSplit()
        let toggled = try tree.togglingSplitDirection(containing: view1, orientation: .horizontal)
        guard case .split(let s) = toggled.root else {
            Issue.record("unexpected node type")
            return
        }
        #expect(s.direction == .vertical)
        // Sides and ratio are preserved.
        #expect(s.left == .leaf(view: view1))
        #expect(s.right == .leaf(view: view2))
        #expect(abs(s.ratio - 0.5) < 0.001)
    }

    @Test func togglingDirectionAndBackRestoresOriginal() throws {
        let (tree, view1, _) = try makeHorizontalSplit()
        // The first toggle finds the horizontal split and makes it vertical; the
        // second must target the now-vertical split to restore it.
        let back = try tree
            .togglingSplitDirection(containing: view1, orientation: .horizontal)
            .togglingSplitDirection(containing: view1, orientation: .vertical)
        guard case .split(let s) = back.root else {
            Issue.record("unexpected node type")
            return
        }
        #expect(s.direction == .horizontal)
    }

    @Test func togglingWalksUpToOuterSplitByOrientation() throws {
        let (tree, _, view2, view3) = try makeNestedTree()

        // From view3, toggling the nearest HORIZONTAL split targets the OUTER one.
        let toggled = try tree.togglingSplitDirection(containing: view3, orientation: .horizontal)

        guard case .split(let root) = toggled.root else {
            Issue.record("unexpected root node type")
            return
        }
        // Outer split re-oriented to vertical; inner split untouched.
        #expect(root.direction == .vertical)
        guard case .split(let inner) = root.right else {
            Issue.record("unexpected inner node type")
            return
        }
        #expect(inner.direction == .vertical)
        #expect(inner.left == .leaf(view: view2))
        #expect(inner.right == .leaf(view: view3))
    }

    @Test func togglingWithNoEnclosingSplitOfOrientationThrows() {
        let view = MockView()
        let tree = SplitTree<MockView>(view: view)
        var threw = false
        do {
            _ = try tree.togglingSplitDirection(containing: view, orientation: .horizontal)
        } catch {
            threw = true
        }
        #expect(threw)
    }

    // MARK: - Swap split (exchange leaf positions)

    @Test func swappingSwapsTwoLeavesByNext() throws {
        let (tree, view1, view2) = try makeHorizontalSplit()
        let swapped = try tree.swappingLeaf(of: view1, with: .next)
        guard case .split(let s) = swapped.root else {
            Issue.record("unexpected node type")
            return
        }
        #expect(s.left == .leaf(view: view2))
        #expect(s.right == .leaf(view: view1))
    }

    @Test func swappingPreservesRatio() throws {
        let (tree, view1, _) = try makeHorizontalSplit()
        // Skew the root split so we'd notice a ratio change (flip would
        // invert it; swap must not).
        let skewed = try tree.replacing(node: tree.root!, with: tree.root!.resizing(to: 0.3))
        let swapped = try skewed.swappingLeaf(of: view1, with: .next)
        guard case .split(let s) = swapped.root else {
            Issue.record("unexpected node type")
            return
        }
        #expect(abs(s.ratio - 0.3) < 0.001)
    }

    @Test func swappingTwiceRestoresOriginal() throws {
        let (tree, view1, view2) = try makeHorizontalSplit()
        let twice = try tree
            .swappingLeaf(of: view1, with: .next)
            .swappingLeaf(of: view1, with: .next)
        guard case .split(let s) = twice.root else {
            Issue.record("unexpected node type")
            return
        }
        #expect(s.left == .leaf(view: view1))
        #expect(s.right == .leaf(view: view2))
    }

    @Test func swappingByPreviousWrapsToOpposite() throws {
        let (tree, view1, view2) = try makeHorizontalSplit()
        // previous from view1 wraps to view2 (single-split tree of two leaves).
        let swapped = try tree.swappingLeaf(of: view1, with: .previous)
        guard case .split(let s) = swapped.root else {
            Issue.record("unexpected node type")
            return
        }
        #expect(s.left == .leaf(view: view2))
        #expect(s.right == .leaf(view: view1))
    }

    @Test func swappingAcrossNestedSplitSwapsOnlyTheLeaves() throws {
        // Layout: view1 | (view2 / view3)
        let (tree, view1, view2, view3) = try makeNestedTree()
        // Spatially `right` from view1 lands on view2 (top of the right column).
        let swapped = try tree.swappingLeaf(of: view1, with: .spatial(.right))

        guard case .split(let root) = swapped.root else {
            Issue.record("unexpected root node type")
            return
        }
        #expect(root.direction == .horizontal)
        // Outer left now holds view2 (the previous top-right leaf).
        #expect(root.left == .leaf(view: view2))
        // Inner vertical split kept its structure; view1 took view2's slot.
        guard case .split(let inner) = root.right else {
            Issue.record("unexpected inner node type")
            return
        }
        #expect(inner.direction == .vertical)
        #expect(inner.left == .leaf(view: view1))
        #expect(inner.right == .leaf(view: view3))
    }

    @Test func swappingOnSingleLeafTreeThrows() {
        let view = MockView()
        let tree = SplitTree<MockView>(view: view)
        var threw = false
        do {
            _ = try tree.swappingLeaf(of: view, with: .next)
        } catch {
            threw = true
        }
        #expect(threw)
    }

    @Test func swappingWithSpatialDeadEndThrows() throws {
        let (tree, view1, _) = try makeHorizontalSplit()
        // No pane to the left of view1; spatial swap should refuse.
        var threw = false
        do {
            _ = try tree.swappingLeaf(of: view1, with: .spatial(.left))
        } catch {
            threw = true
        }
        #expect(threw)
    }

    // MARK: - Combine (merge tabs)

    @Test func combinedPlacesOtherOnSecondByDefault() throws {
        let a = MockView()
        let b = MockView()
        let merged = SplitTree<MockView>(view: a)
            .combined(with: SplitTree<MockView>(view: b), direction: .horizontal)
        guard case .split(let s) = merged.root else {
            Issue.record("expected a split root")
            return
        }
        #expect(s.direction == .horizontal)
        #expect(s.left == .leaf(view: a))
        #expect(s.right == .leaf(view: b))
    }

    @Test func combinedCanPlaceOtherFirst() throws {
        let a = MockView()
        let b = MockView()
        let merged = SplitTree<MockView>(view: a)
            .combined(with: SplitTree<MockView>(view: b), direction: .vertical, otherOnSecond: false)
        guard case .split(let s) = merged.root else {
            Issue.record("expected a split root")
            return
        }
        #expect(s.direction == .vertical)
        #expect(s.left == .leaf(view: b))
        #expect(s.right == .leaf(view: a))
    }

    @Test func combinedPreservesSubtrees() throws {
        // Combine a two-pane horizontal split with a single pane.
        let (treeA, a1, a2) = try makeHorizontalSplit()
        let b = MockView()
        let merged = treeA.combined(with: SplitTree<MockView>(view: b), direction: .vertical)
        guard case .split(let root) = merged.root else {
            Issue.record("expected split root")
            return
        }
        #expect(root.direction == .vertical)
        #expect(root.right == .leaf(view: b))
        // The original A split is preserved on the left.
        guard case .split(let left) = root.left else {
            Issue.record("expected nested split")
            return
        }
        #expect(left.left == .leaf(view: a1))
        #expect(left.right == .leaf(view: a2))
    }

    @Test func combinedWithEmptyReturnsOther() {
        let a = MockView()
        let nonEmpty = SplitTree<MockView>(view: a)
        let empty = SplitTree<MockView>()
        // Empty combined with non-empty yields the non-empty tree unchanged.
        let r1 = empty.combined(with: nonEmpty, direction: .horizontal)
        #expect(r1.contains(.leaf(view: a)))
        #expect(!r1.isSplit)
        // Non-empty combined with empty yields self unchanged.
        let r2 = nonEmpty.combined(with: empty, direction: .horizontal)
        #expect(r2.contains(.leaf(view: a)))
        #expect(!r2.isSplit)
    }

    // MARK: - Codable

    @Test func encodingAndDecodingPreservesTree() throws {
        let (tree, view1, view2) = try makeHorizontalSplit()
        let data = try JSONEncoder().encode(tree)
        let decoded = try JSONDecoder().decode(SplitTree<MockView>.self, from: data)
        #expect(decoded.find(id: view1.id) != nil)
        #expect(decoded.find(id: view2.id) != nil)
        #expect(decoded.isSplit)
    }

    @Test func encodingAndDecodingPreservesZoomedPath() throws {
        let (tree, _, view2) = try makeHorizontalSplit()
        let treeWithZoomed = SplitTree<MockView>(root: tree.root, zoomed: .leaf(view: view2))

        let data = try JSONEncoder().encode(treeWithZoomed)
        let decoded = try JSONDecoder().decode(SplitTree<MockView>.self, from: data)

        #expect(decoded.zoomed != nil)
        if case .leaf(let zoomedView) = decoded.zoomed! {
            #expect(zoomedView.id == view2.id)
        } else {
            Issue.record("unexpected node type")
        }
    }

    // MARK: - Collection Conformance

    @Test func treeIteratesLeavesInOrder() throws {
        let view1 = MockView()
        let view2 = MockView()
        let view3 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)
        tree = try tree.inserting(view: view3, at: view2, direction: .right)

        #expect(tree.startIndex == 0)
        #expect(tree.endIndex == 3)
        #expect(tree.index(after: 0) == 1)

        #expect(tree[0] === view1)
        #expect(tree[1] === view2)
        #expect(tree[2] === view3)

        var ids: [UUID] = []
        for view in tree {
            ids.append(view.id)
        }
        #expect(ids == [view1.id, view2.id, view3.id])
    }

    @Test func emptyTreeCollectionProperties() {
        let tree = SplitTree<MockView>()

        #expect(tree.startIndex == 0)
        #expect(tree.endIndex == 0)

        var count = 0
        for _ in tree {
            count += 1
        }
        #expect(count == 0)
    }

    // MARK: - Structural Identity

    @Test func structuralIdentityIsReflexive() throws {
        let (tree, _, _) = try makeHorizontalSplit()
        #expect(tree.structuralIdentity == tree.structuralIdentity)
    }

    @Test func structuralIdentityComparesShapeNotRatio() throws {
        let (tree, view1, _) = try makeHorizontalSplit()

        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let resized = try tree.resizing(node: .leaf(view: view1), by: 100, in: .right, with: bounds)
        #expect(tree.structuralIdentity == resized.structuralIdentity)
    }

    @Test func structuralIdentityForDifferentStructures() throws {
        let view1 = MockView()
        let view2 = MockView()
        let view3 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)

        let expanded = try tree.inserting(view: view3, at: view2, direction: .down)
        #expect(tree.structuralIdentity != expanded.structuralIdentity)
    }

    @Test func structuralIdentityIdentifiesDifferentOrdersShapes() throws {
        let (tree, _, _) = try makeHorizontalSplit()

        let (otherTree, _, _) = try makeHorizontalSplit()
        #expect(tree.structuralIdentity != otherTree.structuralIdentity)
    }

    // MARK: - View Bounds

    @Test func viewBoundsReturnsLeafViewSize() {
        let view1 = MockView()
        view1.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        let tree = SplitTree<MockView>(view: view1)

        let bounds = tree.viewBounds()
        #expect(bounds.width == 500)
        #expect(bounds.height == 300)
    }

    @Test func viewBoundsReturnsZeroForEmptyTree() {
        let tree = SplitTree<MockView>()
        let bounds = tree.viewBounds()

        #expect(bounds.width == 0)
        #expect(bounds.height == 0)
    }

    @Test func viewBoundsHorizontalSplit() throws {
        let view1 = MockView()
        let view2 = MockView()
        view1.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        view2.frame = NSRect(x: 0, y: 0, width: 200, height: 500)
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)

        let bounds = tree.viewBounds()
        #expect(bounds.width == 600)
        #expect(bounds.height == 500)
    }

    @Test func viewBoundsVerticalSplit() throws {
        let view1 = MockView()
        let view2 = MockView()
        view1.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        view2.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .down)

        let bounds = tree.viewBounds()
        #expect(bounds.width == 500)
        #expect(bounds.height == 600)
    }

    // MARK: - Node

    @Test func nodeFindsLeaf() {
        let view1 = MockView()
        let tree = SplitTree<MockView>(view: view1)

        let node = tree.root?.node(view: view1)
        #expect(node != nil)
        #expect(node == .leaf(view: view1))
    }

    @Test func nodeFindsLeavesInSplitTree() throws {
        let (tree, view1, view2) = try makeHorizontalSplit()

        #expect(tree.root?.node(view: view1) == .leaf(view: view1))
        #expect(tree.root?.node(view: view2) == .leaf(view: view2))
    }

    @Test func nodeReturnsNilForMissingView() {
        let view1 = MockView()
        let view2 = MockView()

        let tree = SplitTree<MockView>(view: view1)
        #expect(tree.root?.node(view: view2) == nil)
    }

    @Test func resizingUpdatesRatio() throws {
        let (tree, _, _) = try makeHorizontalSplit()

        guard case .split(let s) = tree.root else {
            Issue.record("unexpected node type")
            return
        }

        let resized = SplitTree<MockView>.Node.split(s).resizing(to: 0.7)
        guard case .split(let resizedSplit) = resized else {
            Issue.record("unexpected node type")
            return
        }
        #expect(abs(resizedSplit.ratio - 0.7) < 0.001)
    }

    @Test func resizingLeavesLeafUnchanged() {
        let view1 = MockView()
        let tree = SplitTree<MockView>(view: view1)

        guard let root = tree.root else {
            Issue.record("expected non-empty tree")
            return
        }
        let resized = root.resizing(to: 0.7)
        #expect(resized == root)
    }

    // MARK: - Spatial

    @Test(arguments: [
        (SplitTree<MockView>.Spatial.Direction.left, SplitTree<MockView>.NewDirection.right),
        (.right, .right),
        (.up, .down),
        (.down, .down),
    ])
    func doesBorderEdge(
        side: SplitTree<MockView>.Spatial.Direction,
        insertDirection: SplitTree<MockView>.NewDirection
    ) throws {
        let view1 = MockView()
        let view2 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: insertDirection)

        let spatial = tree.root!.spatial(within: CGSize(width: 1000, height: 500))

        // view1 borders left/up; view2 borders right/down
        let (borderView, nonBorderView): (MockView, MockView) =
            (side == .right || side == .down) ? (view2, view1) : (view1, view2)
        #expect(spatial.doesBorder(side: side, from: .leaf(view: borderView)))
        #expect(!spatial.doesBorder(side: side, from: .leaf(view: nonBorderView)))
    }

    // MARK: - Calculate View Bounds

    @Test func calculatesViewBoundsForSingleLeaf() {
        let view1 = MockView()
        let tree = SplitTree<MockView>(view: view1)

        guard let root = tree.root else {
            Issue.record("expected non-empty tree")
            return
        }

        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let result = root.calculateViewBounds(in: bounds)
        #expect(result.count == 1)
        #expect(result[0].view === view1)
        #expect(result[0].bounds == bounds)
    }

    @Test func calculatesViewBoundsHorizontalSplit() throws {
        let (tree, view1, view2) = try makeHorizontalSplit()

        guard let root = tree.root else {
            Issue.record("expected non-empty tree")
            return
        }

        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let result = root.calculateViewBounds(in: bounds)
        #expect(result.count == 2)

        let leftBounds = result.first { $0.view === view1 }!.bounds
        let rightBounds = result.first { $0.view === view2 }!.bounds
        #expect(leftBounds == CGRect(x: 0, y: 0, width: 500, height: 500))
        #expect(rightBounds == CGRect(x: 500, y: 0, width: 500, height: 500))
    }

    @Test func calculatesViewBoundsVerticalSplit() throws {
        let view1 = MockView()
        let view2 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .down)

        guard let root = tree.root else {
            Issue.record("expected non-empty tree")
            return
        }

        let bounds = CGRect(x: 0, y: 0, width: 500, height: 1000)
        let result = root.calculateViewBounds(in: bounds)
        #expect(result.count == 2)

        let topBounds = result.first { $0.view === view1 }!.bounds
        let bottomBounds = result.first { $0.view === view2 }!.bounds
        #expect(topBounds == CGRect(x: 0, y: 500, width: 500, height: 500))
        #expect(bottomBounds == CGRect(x: 0, y: 0, width: 500, height: 500))
    }

    @Test func calculateViewBoundsCustomRatio() throws {
        let (tree, view1, view2) = try makeHorizontalSplit()

        guard case .split(let s) = tree.root else {
            Issue.record("unexpected node type")
            return
        }

        let resizedRoot = SplitTree<MockView>.Node.split(s).resizing(to: 0.3)
        let container = CGRect(x: 0, y: 0, width: 1000, height: 400)
        let result = resizedRoot.calculateViewBounds(in: container)
        #expect(result.count == 2)

        let leftBounds = result.first { $0.view === view1 }!.bounds
        let rightBounds = result.first { $0.view === view2 }!.bounds
        #expect(leftBounds.width == 300)   // 0.3 * 1000
        #expect(rightBounds.width == 700)   // 0.7 * 1000
        #expect(rightBounds.minX == 300)
    }

    @Test func calculateViewBoundsGrid() throws {
        let view1 = MockView()
        let view2 = MockView()
        let view3 = MockView()
        let view4 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)
        tree = try tree.inserting(view: view3, at: view1, direction: .down)
        tree = try tree.inserting(view: view4, at: view2, direction: .down)
        guard let root = tree.root else {
            Issue.record("expected non-empty tree")
            return
        }
        let container = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let result = root.calculateViewBounds(in: container)
        #expect(result.count == 4)

        let b1 = result.first { $0.view === view1 }!.bounds
        let b2 = result.first { $0.view === view2 }!.bounds
        let b3 = result.first { $0.view === view3 }!.bounds
        let b4 = result.first { $0.view === view4 }!.bounds
        #expect(b1 == CGRect(x: 0, y: 400, width: 500, height: 400))   // top-left
        #expect(b2 == CGRect(x: 500, y: 400, width: 500, height: 400)) // top-right
        #expect(b3 == CGRect(x: 0, y: 0, width: 500, height: 400))     // bottom-left
        #expect(b4 == CGRect(x: 500, y: 0, width: 500, height: 400))   // bottom-right
    }

    @Test(arguments: [
        (SplitTree<MockView>.Spatial.Direction.right, SplitTree<MockView>.NewDirection.right),
        (.left, .right),
        (.down, .down),
        (.up, .down),
    ])
    func slotsFromNode(
        direction: SplitTree<MockView>.Spatial.Direction,
        insertDirection: SplitTree<MockView>.NewDirection
    ) throws {
        let view1 = MockView()
        let view2 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: insertDirection)

        let spatial = tree.root!.spatial(within: CGSize(width: 1000, height: 500))

        // look from view1 toward view2 for right/down, from view2 toward view1 for left/up
        let (fromView, expectedView): (MockView, MockView) =
            (direction == .right || direction == .down) ? (view1, view2) : (view2, view1)
        let slots = spatial.slots(in: direction, from: .leaf(view: fromView))
        #expect(slots.count == 1)
        #expect(slots[0].node == .leaf(view: expectedView))
    }

    @Test func slotsGridFromTopLeft() throws {
        let view1 = MockView()
        let view2 = MockView()
        let view3 = MockView()
        let view4 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)
        tree = try tree.inserting(view: view3, at: view1, direction: .down)
        tree = try tree.inserting(view: view4, at: view2, direction: .down)
        let spatial = tree.root!.spatial(within: CGSize(width: 1000, height: 800))
        let rightSlots = spatial.slots(in: .right, from: .leaf(view: view1))
        let downSlots = spatial.slots(in: .down, from: .leaf(view: view1))
        // slots() returns both split nodes and leaves; split nodes can tie on distance
        #expect(rightSlots.contains { $0.node == .leaf(view: view2) })
        #expect(downSlots.contains { $0.node == .leaf(view: view3) })
    }

    @Test func slotsGridFromBottomRight() throws {
        let view1 = MockView()
        let view2 = MockView()
        let view3 = MockView()
        let view4 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)
        tree = try tree.inserting(view: view3, at: view1, direction: .down)
        tree = try tree.inserting(view: view4, at: view2, direction: .down)
        let spatial = tree.root!.spatial(within: CGSize(width: 1000, height: 800))
        let leftSlots = spatial.slots(in: .left, from: .leaf(view: view4))
        let upSlots = spatial.slots(in: .up, from: .leaf(view: view4))
        #expect(leftSlots.contains { $0.node == .leaf(view: view3) })
        #expect(upSlots.contains { $0.node == .leaf(view: view2) })
    }

    @Test func slotsReturnsEmptyWhenNoNodesInDirection() throws {
        let (tree, view1, view2) = try makeHorizontalSplit()

        let spatial = tree.root!.spatial(within: CGSize(width: 1000, height: 500))
        #expect(spatial.slots(in: .left, from: .leaf(view: view1)).isEmpty)
        #expect(spatial.slots(in: .right, from: .leaf(view: view2)).isEmpty)
        #expect(spatial.slots(in: .up, from: .leaf(view: view1)).isEmpty)
        #expect(spatial.slots(in: .down, from: .leaf(view: view2)).isEmpty)
    }

    // Set/Dictionary usage is the only path that exercises StructuralIdentity.hash(into:)
    @Test func structuralIdentityHashableBehavior() throws {
        let (tree, _, _) = try makeHorizontalSplit()
        let id = tree.structuralIdentity

        #expect(id == id)

        var seen: Set<SplitTree<MockView>.StructuralIdentity> = []
        seen.insert(id)
        seen.insert(id)
        #expect(seen.count == 1)

        var cache: [SplitTree<MockView>.StructuralIdentity: String] = [:]
        cache[id] = "two-pane"
        #expect(cache[id] == "two-pane")
    }

    @Test func nodeStructuralIdentityInSet() throws {
        let (tree, _, _) = try makeHorizontalSplit()

        guard case .split(let s) = tree.root else {
            Issue.record("unexpected node type")
            return
        }

        var nodeIds: Set<SplitTree<MockView>.Node.StructuralIdentity> = []
        nodeIds.insert(tree.root!.structuralIdentity)
        nodeIds.insert(s.left.structuralIdentity)
        nodeIds.insert(s.right.structuralIdentity)
        #expect(nodeIds.count == 3)
    }

    @Test func nodeStructuralIdentityDistinguishesLeaves() throws {
        let (tree, _, _) = try makeHorizontalSplit()

        guard case .split(let s) = tree.root else {
            Issue.record("unexpected node type")
            return
        }

        var nodeIds: Set<SplitTree<MockView>.Node.StructuralIdentity> = []
        nodeIds.insert(s.left.structuralIdentity)
        nodeIds.insert(s.right.structuralIdentity)
        #expect(nodeIds.count == 2)
    }

    // MARK: - Hidden-split bell (ramon fork)

    /// Builds a 3-leaf tree where v2/v3 form a sub-split:
    ///   root = .split(left: .leaf(v1), right: .split(left: .leaf(v2), right: .leaf(v3)))
    /// Leaf pixel bounds keyed by view identity, for asserting grid-cap fixture geometry
    /// directly (so a layout regression is caught at the slot level, not only via direction).
    /// Reads the SAME `spatial(within:).slots` that `largestLeafSplit` consumes (Y-down, left
    /// child = top), so asserted rects match exactly what the production decision sees — NOT
    /// `calculateViewBounds`, which uses the inverted-Y convention.
    private func leafRects(
        _ tree: SplitTree<MockView>, within bounds: CGSize
    ) -> [ObjectIdentifier: CGRect] {
        guard let root = tree.root else { return [:] }
        var out: [ObjectIdentifier: CGRect] = [:]
        for slot in root.spatial(within: bounds).slots {
            guard case .leaf(let view) = slot.node else { continue }
            out[ObjectIdentifier(view)] = slot.bounds
        }
        return out
    }

    private func makeThreeLeafTree() throws -> (SplitTree<MockView>, MockView, MockView, MockView) {
        let v1 = MockView()
        let v2 = MockView()
        let v3 = MockView()
        var tree = SplitTree<MockView>(view: v1)
        tree = try tree.inserting(view: v2, at: v1, direction: .right)
        tree = try tree.inserting(view: v3, at: v2, direction: .down)
        return (tree, v1, v2, v3)
    }

    @Test func hasBellOutsideZoomFalseWhenNotZoomed() throws {
        let (tree, v1, v2, v3) = try makeThreeLeafTree()
        #expect(tree.zoomed == nil)
        #expect(tree.hasBellOutsideZoom(bells: [v1.id: true, v2.id: true, v3.id: true]) == false)
    }

    @Test func hasBellOutsideZoomFalseWhenRingerInsideZoom() throws {
        let (tree, v1, _, _) = try makeThreeLeafTree()
        let zoomedTree = SplitTree(root: tree.root, zoomed: .leaf(view: v1))
        #expect(zoomedTree.hasBellOutsideZoom(bells: [v1.id: true]) == false)
    }

    @Test func hasBellOutsideZoomTrueWhenRingerOutsideZoom() throws {
        let (tree, v1, v2, _) = try makeThreeLeafTree()
        let zoomedTree = SplitTree(root: tree.root, zoomed: .leaf(view: v1))
        #expect(zoomedTree.hasBellOutsideZoom(bells: [v2.id: true]) == true)
    }

    @Test func hasBellOutsideZoomMultipleClearsToLast() throws {
        let (tree, v1, v2, v3) = try makeThreeLeafTree()
        let zoomedTree = SplitTree(root: tree.root, zoomed: .leaf(view: v1))
        #expect(zoomedTree.hasBellOutsideZoom(bells: [v2.id: true, v3.id: true]) == true)
        #expect(zoomedTree.hasBellOutsideZoom(bells: [v2.id: false, v3.id: true]) == true)
        #expect(zoomedTree.hasBellOutsideZoom(bells: [v2.id: false, v3.id: false]) == false)
    }

    @Test func hasBellOutsideZoomIgnoresInsideRingerWithOutsideQuiet() throws {
        let (tree, v1, v2, _) = try makeThreeLeafTree()
        guard case .split(let rootSplit) = tree.root else {
            Issue.record("expected root to be a split")
            return
        }
        let subSplit = rootSplit.right
        let zoomedTree = SplitTree(root: tree.root, zoomed: subSplit)
        #expect(zoomedTree.hasBellOutsideZoom(bells: [v2.id: true]) == false)
        #expect(zoomedTree.hasBellOutsideZoom(bells: [v2.id: true, v1.id: true]) == true)
    }

    @Test func zoomedLeavesReturnsSubtreeLeaves() throws {
        let (tree, _, v2, v3) = try makeThreeLeafTree()
        guard case .split(let rootSplit) = tree.root else {
            Issue.record("expected root to be a split")
            return
        }
        let subSplit = rootSplit.right
        let zoomedTree = SplitTree(root: tree.root, zoomed: subSplit)
        #expect(Set(zoomedTree.zoomedLeaves().map(\.id)) == [v2.id, v3.id])
    }

    @Test func zoomedLeavesEmptyWhenNotZoomed() throws {
        let (tree, _, _, _) = try makeThreeLeafTree()
        #expect(tree.zoomed == nil)
        #expect(tree.zoomedLeaves().isEmpty)
    }

    @Test func hasBellOutsideZoomSingleAndEmptyTree() {
        let v1 = MockView()
        let single = SplitTree(root: .leaf(view: v1), zoomed: .leaf(view: v1))
        #expect(single.hasBellOutsideZoom(bells: [v1.id: true]) == false)

        let empty = SplitTree<MockView>()
        #expect(empty.hasBellOutsideZoom(bells: [:]) == false)
        #expect(empty.zoomedLeaves().isEmpty)
    }

    // MARK: - largestLeafSplit (Agent Queue balanced BSP)

    @Test func largestLeafSplitEmptyTreeIsNil() {
        let tree = SplitTree<MockView>()
        #expect(tree.largestLeafSplit(within: CGSize(width: 1600, height: 1000)) == nil)
    }

    @Test func largestLeafSplitSingleLeafFollowsAspect() {
        let v1 = MockView()
        let tree = SplitTree(view: v1)
        // Wide bounds → split right; tall bounds → split down (full-tab leaf either way).
        let wide = tree.largestLeafSplit(within: CGSize(width: 1600, height: 1000))
        #expect(wide?.view === v1)
        #expect(wide?.direction == .right)
        let tall = tree.largestLeafSplit(within: CGSize(width: 800, height: 1200))
        #expect(tall?.view === v1)
        #expect(tall?.direction == .down)
    }

    @Test func largestLeafSplitTwoColumnsEachTallSplitsDown() throws {
        // [v1 | v2], each half-width of a wide tab → 800×1000 (taller than wide). Equal
        // area → first leaf (v1); its longer side is vertical → split DOWN.
        let (tree, v1, _) = try Self.makeHorizontalSplit()
        let pick = tree.largestLeafSplit(within: CGSize(width: 1600, height: 1000))
        #expect(pick?.view === v1)
        #expect(pick?.direction == .down)
    }

    @Test func largestLeafSplitPicksTheBiggestPane() throws {
        // [v1 | [v2 / v3]] within 1600×1000: v1 = 800×1000 (area 800k); v2,v3 = 800×500
        // (400k each). The biggest is v1 → split along its longer (vertical) side → DOWN.
        let v1 = MockView(), v2 = MockView(), v3 = MockView()
        var tree = SplitTree(view: v1)
        tree = try tree.inserting(view: v2, at: v1, direction: .right)
        tree = try tree.inserting(view: v3, at: v2, direction: .down)
        let pick = tree.largestLeafSplit(within: CGSize(width: 1600, height: 1000))
        #expect(pick?.view === v1)
        #expect(pick?.direction == .down)
    }

    @Test func largestLeafSplitZeroBoundsIsNil() {
        let tree = SplitTree(view: MockView())
        #expect(tree.largestLeafSplit(within: .zero) == nil)
    }

    // MARK: - largestLeafSplit grid cap (Agent Queue §12 grid-constrained BSP)

    @Test func gridBackCompatZeroCapsEqualsAspect() throws {
        // The existing 3-leaf [v1 | [v2/v3]] fixture: largest is v1 (800×1000), longer side
        // vertical ⇒ .down. maxCols:0,maxRows:0 must equal the no-arg pure-aspect result.
        let v1 = MockView(), v2 = MockView(), v3 = MockView()
        var tree = SplitTree(view: v1)
        tree = try tree.inserting(view: v2, at: v1, direction: .right)
        tree = try tree.inserting(view: v3, at: v2, direction: .down)
        let bounds = CGSize(width: 1600, height: 1000)
        let capped = tree.largestLeafSplit(within: bounds, maxCols: 0, maxRows: 0)
        #expect(capped?.view === v1)
        #expect(capped?.direction == .down)
    }

    @Test func gridCapAbsentViaWrapperEqualsAspect() throws {
        // The no-arg wrapper must produce the identical (view, direction) as maxCols:0,maxRows:0.
        let v1 = MockView(), v2 = MockView(), v3 = MockView()
        var tree = SplitTree(view: v1)
        tree = try tree.inserting(view: v2, at: v1, direction: .right)
        tree = try tree.inserting(view: v3, at: v2, direction: .down)
        let bounds = CGSize(width: 1600, height: 1000)
        let wrapper = tree.largestLeafSplit(within: bounds)
        let explicit = tree.largestLeafSplit(within: bounds, maxCols: 0, maxRows: 0)
        #expect(wrapper?.view === v1)
        #expect(wrapper?.view === explicit?.view)
        #expect(wrapper?.direction == explicit?.direction)
        #expect(wrapper?.direction == .down)
    }

    @Test func gridUltrawideThirdPaneStillRight() throws {
        // A | B (1920 | 1920) within 3840×1010; 2 columns < cap 3 ⇒ still add a column.
        let a = MockView(), b = MockView()
        var tree = SplitTree(view: a)
        tree = try tree.inserting(view: b, at: a, direction: .right)
        let pick = tree.largestLeafSplit(
            within: CGSize(width: 3840, height: 1010), maxCols: 3, maxRows: 2)
        #expect(pick?.view === a) // area tie ⇒ first in DFS
        #expect(pick?.direction == .right)
    }

    @Test func gridUltrawideFourthPaneStacksRow() throws {
        // A; B right of A; C right of A ⇒ tree (A|C)|B. Slots: A 0,0,960,1010 ·
        // C 960,0,960,1010 · B 1920,0,1920,1010. Largest area = B (1920×1010). B's row band
        // has 3 cols {0,960,1920} = colCap ⇒ canRight=false; B's col band has 1 row<2 ⇒
        // canDown ⇒ stack a row under B (NOT a 4th column).
        let a = MockView(), b = MockView(), c = MockView()
        var tree = SplitTree(view: a)
        tree = try tree.inserting(view: b, at: a, direction: .right)
        tree = try tree.inserting(view: c, at: a, direction: .right)
        let pick = tree.largestLeafSplit(
            within: CGSize(width: 3840, height: 1010), maxCols: 3, maxRows: 2)
        #expect(pick?.view === b)
        #expect(pick?.direction == .down)
    }

    @Test func gridFifthPaneSplitsSecondColumn() throws {
        // A; B right of A; C right of A; D below B ⇒ tree (A|C)|(B/D). Slots: A 0,0,960,1010 ·
        // C 960,0,960,1010 · B 1920,0,1920,505 · D 1920,505,1920,505 — all area 969,600 (4-way
        // tie) ⇒ best=A (DFS-first). A's row band has 3 cols (capped, canRight=false) but its
        // col band has 1 row<2 ⇒ canDown ⇒ .down.
        let a = MockView(), b = MockView(), c = MockView(), d = MockView()
        var tree = SplitTree(view: a)
        tree = try tree.inserting(view: b, at: a, direction: .right)
        tree = try tree.inserting(view: c, at: a, direction: .right)
        tree = try tree.inserting(view: d, at: b, direction: .down)
        let pick = tree.largestLeafSplit(
            within: CGSize(width: 3840, height: 1010), maxCols: 3, maxRows: 2)
        #expect(pick?.view === a)
        #expect(pick?.direction == .down)
    }

    @Test func gridBothCappedLeafIsSkipped() throws {
        // A; C right of A; B right of C; D below A ⇒ tree (A/D)|(C|B). Slots all area 969,600
        // (4-way tie): A 0,0,1920,505 · D 0,505,1920,505 · C 1920,0,960,1010 · B 2880,0,960,1010.
        // DFS order A, D, C, B. A is BOTH-capped (row band 3 cols, col band 2 rows) ⇒ SKIPPED;
        // D both-capped ⇒ skipped; C's col band has 1 row<2 ⇒ selected, .down. NOT (A,.right).
        let a = MockView(), b = MockView(), c = MockView(), d = MockView()
        var tree = SplitTree(view: a)
        tree = try tree.inserting(view: c, at: a, direction: .right)
        tree = try tree.inserting(view: b, at: c, direction: .right)
        tree = try tree.inserting(view: d, at: a, direction: .down)
        let pick = tree.largestLeafSplit(
            within: CGSize(width: 3840, height: 1010), maxCols: 3, maxRows: 2)
        #expect(pick?.view === c)
        #expect(pick?.direction == .down)
    }

    @Test func gridCols1Stacks() throws {
        // A | B (each 800×1000) within 1600×1000; colCap=1 ⇒ row band already 2≥1 cols ⇒
        // never .right ⇒ stack (.down). maxRows:0 ⇒ rows unbounded.
        let a = MockView(), b = MockView()
        var tree = SplitTree(view: a)
        tree = try tree.inserting(view: b, at: a, direction: .right)
        let pick = tree.largestLeafSplit(
            within: CGSize(width: 1600, height: 1000), maxCols: 1, maxRows: 0)
        #expect(pick?.view === a)
        #expect(pick?.direction == .down)
    }

    @Test func gridCols1SingleLeaf() {
        // A lone wide leaf with colCap=1 must be forced to .down (a 2nd column is forbidden).
        let v1 = MockView()
        let tree = SplitTree(view: v1)
        let pick = tree.largestLeafSplit(
            within: CGSize(width: 1600, height: 1000), maxCols: 1, maxRows: 0)
        #expect(pick?.view === v1)
        #expect(pick?.direction == .down)
    }

    @Test func gridRows1Columns() throws {
        // A / B (each 1000×800) within 1000×1600; rowCap=1 ⇒ col band already 2≥1 rows ⇒
        // never .down ⇒ add a column (.right). maxCols:0 ⇒ cols unbounded.
        let a = MockView(), b = MockView()
        var tree = SplitTree(view: a)
        tree = try tree.inserting(view: b, at: a, direction: .down)
        let pick = tree.largestLeafSplit(
            within: CGSize(width: 1000, height: 1600), maxCols: 0, maxRows: 1)
        #expect(pick?.view === a)
        #expect(pick?.direction == .right)
    }

    @Test func gridRows1SingleLeaf() {
        // A lone tall leaf with rowCap=1 must be forced to .right (a 2nd row is forbidden).
        let v1 = MockView()
        let tree = SplitTree(view: v1)
        let pick = tree.largestLeafSplit(
            within: CGSize(width: 800, height: 1200), maxCols: 0, maxRows: 1)
        #expect(pick?.view === v1)
        #expect(pick?.direction == .right)
    }

    @Test func gridSingleLeafFollowsAspectWithCaps() {
        // Caps ≥1 + a single leaf ⇒ both axes legal ⇒ pure aspect.
        let v1 = MockView()
        let tree = SplitTree(view: v1)
        let wide = tree.largestLeafSplit(
            within: CGSize(width: 1600, height: 1000), maxCols: 3, maxRows: 2)
        #expect(wide?.view === v1)
        #expect(wide?.direction == .right)
        let tall = tree.largestLeafSplit(
            within: CGSize(width: 800, height: 1200), maxCols: 3, maxRows: 2)
        #expect(tall?.view === v1)
        #expect(tall?.direction == .down)
    }

    @Test func gridTallWindowWalkRespectsRows() throws {
        // Tall analog of the ultrawide walk, grid 2 cols × 3 rows in a 1000×1600 window. Rebuild
        // the tree at each returned (view, dir); assert the layout never exceeds 2 cols / 3 rows.
        let bounds = CGSize(width: 1000, height: 1600)
        let a = MockView()
        var tree = SplitTree(view: a)
        // Step 1: single leaf A 1000×1600, taller ⇒ aspect .down, allowed ⇒ A,.down.
        let s1 = tree.largestLeafSplit(within: bounds, maxCols: 2, maxRows: 3)
        #expect(s1?.view === a)
        #expect(s1?.direction == .down)
        let b = MockView()
        tree = try tree.inserting(view: b, at: a, direction: .down)
        // Now A 0,0,1000,800 / B 0,800,1000,800. Step 2: tie ⇒ best=A (DFS-first). A is wider
        // (1000>800) ⇒ aspect .right; col band 1 row<3 and row band 1 col<2 ⇒ both legal ⇒
        // .right.
        let s2 = tree.largestLeafSplit(within: bounds, maxCols: 2, maxRows: 3)
        #expect(s2?.view === a)
        #expect(s2?.direction == .right)
        let c = MockView()
        tree = try tree.inserting(view: c, at: a, direction: .right)
        // Now A 0,0,500,800 · C 500,0,500,800 · B 0,800,1000,800. Largest = B (1000×800,
        // area 800k > A,C 400k). B's row band (Y 800..1600) overlaps only B ⇒ 1 col<2 ⇒
        // canRight; B is wider ⇒ aspect .right ⇒ B,.right.
        let s3 = tree.largestLeafSplit(within: bounds, maxCols: 2, maxRows: 3)
        #expect(s3?.view === b)
        #expect(s3?.direction == .right)
    }

    @Test func gridEveryLeafCappedFallsBackToAspect() throws {
        // Filled 2×2: A; B right of A; C below A; D below B ⇒ four 800×500 quadrants.
        // A 0,0,800,500 · C 0,500,800,500 · B 800,0,800,500 · D 800,500,800,500. EVERY leaf is
        // both-capped (2 cols, 2 rows) ⇒ loop falls through; defensive fallback = largest (A,
        // DFS-first on the tie) + aspect (800≥500 ⇒ .right).
        let a = MockView(), b = MockView(), c = MockView(), d = MockView()
        var tree = SplitTree(view: a)
        tree = try tree.inserting(view: b, at: a, direction: .right)
        tree = try tree.inserting(view: c, at: a, direction: .down)
        tree = try tree.inserting(view: d, at: b, direction: .down)
        let pick = tree.largestLeafSplit(
            within: CGSize(width: 1600, height: 1000), maxCols: 2, maxRows: 2)
        #expect(pick?.view === a)
        #expect(pick?.direction == .right)
    }

    @Test func gridEpsilonOverlapRobustness() throws {
        // Clean 2×2 quadrant geometry, built so two leaves genuinely SHARE a minX (one
        // sub-split column) and two share another minX — exactly the case position-dedup must
        // collapse. Build: B right of A; C below A; D below B ⇒ tree (A/C)|(B/D), four 800×500
        // quadrants:
        //   A 0,0,800,500 · C 0,500,800,500 · B 800,0,800,500 · D 800,500,800,500.
        // A & C share minX=0 (column 1); B & D share minX=800 (column 2). With caps 2×2 every
        // leaf is both-capped (its row band has 2 distinct columns AFTER dedup, its col band 2
        // rows) ⇒ the loop skips them all and falls back to largest (A, DFS-first on the 4-way
        // area tie) + aspect (800≥500 ⇒ .right). Epsilon position-dedup is what collapses each
        // shared-minX pair to ONE column here (raw distinct-value counting would too on exact
        // floats; the count flip that a BROKEN dedup would cause is exercised directly by
        // gridStackedColumnDedupFlipsDirection below). Assert the documented slot geometry then
        // the result.
        let a = MockView(), b = MockView(), c = MockView(), d = MockView()
        var tree = SplitTree(view: a)
        tree = try tree.inserting(view: b, at: a, direction: .right)
        tree = try tree.inserting(view: c, at: a, direction: .down)
        tree = try tree.inserting(view: d, at: b, direction: .down)
        let bounds = CGSize(width: 1600, height: 1000)
        // Verify the slot geometry up front so a layout regression is caught directly.
        let rects = leafRects(tree, within: bounds)
        #expect(rects[ObjectIdentifier(a)] == CGRect(x: 0, y: 0, width: 800, height: 500))
        #expect(rects[ObjectIdentifier(c)] == CGRect(x: 0, y: 500, width: 800, height: 500))
        #expect(rects[ObjectIdentifier(b)] == CGRect(x: 800, y: 0, width: 800, height: 500))
        #expect(rects[ObjectIdentifier(d)] == CGRect(x: 800, y: 500, width: 800, height: 500))
        let pick = tree.largestLeafSplit(within: bounds, maxCols: 2, maxRows: 2)
        #expect(pick?.view === a)
        #expect(pick?.direction == .right)
    }

    @Test func gridStackedColumnDedupFlipsDirection() throws {
        // THE dedup→cap→direction branch: a candidate leaf whose ROW BAND contains a SUB-SPLIT
        // column (two leaves stacked in rows, sharing one minX) where position-dedup is the only
        // thing keeping the band UNDER the column cap. Build B right of A; C below B ⇒ tree
        // A|(B/C) in a 2000×1000 window:
        //   A 0,0,1000,1000 · B 1000,0,1000,500 · C 1000,500,1000,500.
        // A is the largest leaf (1,000,000 vs 500,000) and SQUARE ⇒ aspect .right. caps 3×2.
        // A's row band (Y 0..1000) overlaps A, B, C with minX {0, 1000, 1000}:
        //   • CORRECT position-dedup ⇒ 2 distinct columns ⇒ canRight = 2<3 = true.
        //   • BROKEN dedup (counting leaves, not positions) ⇒ 3 ⇒ canRight = 3<3 = FALSE.
        // A's col band (X 0..1000) overlaps only A ⇒ 1 row ⇒ canDown = 1<2 = true (both cases).
        // aspect .right ⇒ direction(.right, canRight, canDown):
        //   • CORRECT (canRight=true)  ⇒ .right   ← asserted here
        //   • BROKEN  (canRight=false) ⇒ .down    (the flip a regression would produce)
        // So this fixture FAILS if the stacked column is not deduped to a single column — the
        // coverage gap reviewers flagged for gridEpsilonOverlapRobustness.
        let a = MockView(), b = MockView(), c = MockView()
        var tree = SplitTree(view: a)
        tree = try tree.inserting(view: b, at: a, direction: .right)
        tree = try tree.inserting(view: c, at: b, direction: .down)
        let bounds = CGSize(width: 2000, height: 1000)
        let rects = leafRects(tree, within: bounds)
        #expect(rects[ObjectIdentifier(a)] == CGRect(x: 0, y: 0, width: 1000, height: 1000))
        #expect(rects[ObjectIdentifier(b)] == CGRect(x: 1000, y: 0, width: 1000, height: 500))
        #expect(rects[ObjectIdentifier(c)] == CGRect(x: 1000, y: 500, width: 1000, height: 500))
        let pick = tree.largestLeafSplit(within: bounds, maxCols: 3, maxRows: 2)
        #expect(pick?.view === a)
        #expect(pick?.direction == .right)
    }
}
