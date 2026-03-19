import XCTest
@testable import AgtmuxTerm

final class WorkbenchGhosttyIslandTests: XCTestCase {
    func testPaneRetargetRefreshSchedulesForSameSurfaceVisiblePaneChange() {
        XCTAssertTrue(
            GhosttyIslandViewController.shouldSchedulePaneRetargetPresentationRefresh(
                previousVisiblePaneIdentity: "shared|@1|%1|",
                nextVisiblePaneIdentity: "shared|@1|%2|",
                commandChanged: false
            )
        )
    }

    func testPaneRetargetRefreshDoesNotScheduleWhenCommandChanges() {
        XCTAssertFalse(
            GhosttyIslandViewController.shouldSchedulePaneRetargetPresentationRefresh(
                previousVisiblePaneIdentity: "shared|@1|%1|",
                nextVisiblePaneIdentity: "shared|@1|%2|",
                commandChanged: true
            )
        )
    }

    func testPaneRetargetRefreshDoesNotScheduleForStableOrMissingVisiblePaneIdentity() {
        XCTAssertFalse(
            GhosttyIslandViewController.shouldSchedulePaneRetargetPresentationRefresh(
                previousVisiblePaneIdentity: "shared|@1|%1|",
                nextVisiblePaneIdentity: "shared|@1|%1|",
                commandChanged: false
            )
        )
        XCTAssertFalse(
            GhosttyIslandViewController.shouldSchedulePaneRetargetPresentationRefresh(
                previousVisiblePaneIdentity: "shared|@1|%1|",
                nextVisiblePaneIdentity: nil,
                commandChanged: false
            )
        )
    }
}
