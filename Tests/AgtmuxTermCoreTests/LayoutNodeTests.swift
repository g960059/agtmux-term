import XCTest
@testable import AgtmuxTermCore

final class LayoutNodeTests: XCTestCase {
    private func makeLeaf(paneID: String = "%1") -> LeafPane {
        LeafPane(tmuxPaneID: paneID, sessionName: "s", source: "local", linkedSession: .creating)
    }

    func testLeavesOnSingleLeaf() {
        let leaf = makeLeaf()
        let node = LayoutNode.leaf(leaf)
        XCTAssertEqual(node.leaves.map(\.tmuxPaneID), ["%1"])
    }

    func testSplitLeaf() {
        let original = makeLeaf(paneID: "%1")
        let node = LayoutNode.leaf(original)
        let newLeaf = makeLeaf(paneID: "%2")
        let result = node.splitLeaf(id: original.id, axis: .horizontal, newLeaf: newLeaf)
        XCTAssertNotNil(result)
        guard case .split(let c) = result else { return XCTFail("Expected split") }
        XCTAssertEqual(c.axis, .horizontal)
    }

    func testRemovingLeafFromSplit() {
        let a = makeLeaf(paneID: "%1")
        let b = makeLeaf(paneID: "%2")
        let container = SplitContainer(axis: .horizontal, ratio: 0.5,
                                       first: .leaf(a), second: .leaf(b))
        let node = LayoutNode.split(container)
        let result = node.removingLeaf(id: a.id)
        XCTAssertNotNil(result)
        guard case .leaf(let remaining) = result else { return XCTFail("Expected leaf") }
        XCTAssertEqual(remaining.tmuxPaneID, "%2")
    }

    func testRemovingOnlyLeafReturnsNil() {
        let leaf = makeLeaf()
        let node = LayoutNode.leaf(leaf)
        XCTAssertNil(node.removingLeaf(id: leaf.id))
    }

    // MARK: - Regression tests

    /// Regression: placePane() must call replacing(), not splitLeaf().
    ///
    /// Before fix: splitLeaf(id:axis:newLeaf:) was used → layout accumulated splits
    ///   (1/2 blank + 1/2 tile → 1/2 blank + 1/4 tile + 1/4 tile → ...).
    /// After fix: replacing(leafID:with:) is used → in-place substitution, tile count stays 1.
    func testReplacingLeafYieldsSingleLeaf() {
        let initial = makeLeaf(paneID: "%1")
        let replacement = makeLeaf(paneID: "%2")
        let node = LayoutNode.leaf(initial)

        let result = node.replacing(leafID: initial.id, with: .leaf(replacement))
        XCTAssertNotNil(result, "replacing() must return non-nil for a known leaf ID")
        guard case .leaf(let leaf) = result else {
            return XCTFail("replacing() returned a split — regression: placePane() is accumulating splits")
        }
        XCTAssertEqual(leaf.tmuxPaneID, "%2")
    }

    /// Confirms that calling replacing() a second time also yields a single leaf (not a nested split).
    func testTwoReplacementsDoNotAccumulateSplits() {
        let first  = makeLeaf(paneID: "%1")
        let second = makeLeaf(paneID: "%2")
        let third  = makeLeaf(paneID: "%3")
        var node = LayoutNode.leaf(first)

        // First pane selection
        node = node.replacing(leafID: first.id, with: .leaf(second)) ?? node
        // Second pane selection (should replace, not split)
        guard let focusedID = node.leafIDs.first else { return XCTFail() }
        node = node.replacing(leafID: focusedID, with: .leaf(third)) ?? node

        XCTAssertEqual(node.leaves.count, 1, "Two pane selections must keep exactly 1 tile")
        XCTAssertEqual(node.leaves.first?.tmuxPaneID, "%3")
    }

    func testLeafIDsOrder() {
        let a = makeLeaf(paneID: "%1")
        let b = makeLeaf(paneID: "%2")
        let c = makeLeaf(paneID: "%3")
        let inner = SplitContainer(axis: .horizontal, ratio: 0.5, first: .leaf(b), second: .leaf(c))
        let outer = SplitContainer(axis: .horizontal, ratio: 0.5, first: .leaf(a), second: .split(inner))
        let node = LayoutNode.split(outer)
        XCTAssertEqual(node.leaves.map(\.tmuxPaneID), ["%1", "%2", "%3"])
    }
}
