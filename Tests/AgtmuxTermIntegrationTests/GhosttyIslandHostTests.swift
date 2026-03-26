import XCTest
import AppKit
@testable import AgtmuxTerm

@MainActor
final class GhosttyIslandHostTests: XCTestCase {
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

    func testHostContainerDidAttachVisibleViewRestoresFocusForVisibleFocusedController() throws {
        let controller = GhosttyIslandViewController(
            surfaceID: UUID(),
            poolKey: "%401",
            attachCommand: nil,
            surfaceContext: nil,
            visiblePaneIdentity: "local|@1|%401|"
        )
        controller.loadViewIfNeeded()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let root = NSView(frame: window.contentView?.bounds ?? .zero)
        root.addSubview(controller.view)
        window.contentView = root
        let terminalView = try XCTUnwrap(controller.view.subviews.first as? GhosttyTerminalView)

        controller.update(
            attachCommand: nil,
            surfaceContext: nil,
            visiblePaneIdentity: "local|@1|%401|",
            isFocused: true,
            focusRestoreNonce: 1
        )
        window.makeFirstResponder(root)

        controller.hostContainerDidAttachVisibleView()

        XCTAssertTrue(window.firstResponder === terminalView)
    }
}
