import XCTest
@testable import AgtmuxTermCore

final class TmuxLayoutConverterTests: XCTestCase {
    private func pane(_ num: Int, session: String = "s") -> AgtmuxPane {
        AgtmuxPane(source: "local", paneId: "%\(num)", sessionName: session, windowId: "@1")
    }

    func testSingleLeaf() {
        let layout = "c1e7a,220x50,0,0,1"
        let result = TmuxLayoutConverter.convert(layoutString: layout, windowPanes: [pane(1)], source: "local")
        XCTAssertNotNil(result)
        guard case .leaf(let leaf) = result else { return XCTFail("Expected leaf") }
        XCTAssertEqual(leaf.tmuxPaneID, "%1")
    }

    func testHorizontalSplit() {
        let layout = "c1e7a,220x50,0,0{110x50,0,0,1,109x50,111,0,2}"
        let result = TmuxLayoutConverter.convert(layoutString: layout, windowPanes: [pane(1), pane(2)], source: "local")
        guard case .split(let c) = result else { return XCTFail("Expected split") }
        XCTAssertEqual(c.axis, .horizontal)
        XCTAssertEqual(c.ratio, 0.5, accuracy: 0.01)
    }

    func testVerticalSplit() {
        let layout = "abcde,220x50,0,0[220x25,0,0,1,220x24,0,26,2]"
        let result = TmuxLayoutConverter.convert(layoutString: layout, windowPanes: [pane(1), pane(2)], source: "local")
        guard case .split(let c) = result else { return XCTFail("Expected split") }
        XCTAssertEqual(c.axis, .vertical)
    }

    func testMissingPaneReturnsNil() {
        let layout = "c1e7a,220x50,0,0,99"
        XCTAssertNil(TmuxLayoutConverter.convert(layoutString: layout, windowPanes: [], source: "local"))
    }

    func testMalformedLayoutReturnsNil() {
        XCTAssertNil(TmuxLayoutConverter.convert(layoutString: "notvalid", windowPanes: [], source: "local"))
    }

    func testRatioIsClamped() {
        let layout = "abcde,220x50,0,0{1x50,0,0,1,218x50,2,0,2}"
        let result = TmuxLayoutConverter.convert(layoutString: layout, windowPanes: [pane(1), pane(2)], source: "local")
        guard case .split(let c) = result else { return XCTFail("Expected split") }
        XCTAssertGreaterThanOrEqual(c.ratio, 0.1)
        XCTAssertLessThanOrEqual(c.ratio, 0.9)
    }
}
