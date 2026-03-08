import XCTest
@testable import AgtmuxTerm
import AgtmuxTermCore

final class WorkbenchV2NavigationSyncResolverTests: XCTestCase {
    func testRequiresRetryWhileObservedRenderedTargetStillMismatchesDesiredPane() {
        let desired = ActivePaneRef(
            target: .local,
            sessionName: "shared",
            windowID: "@2",
            paneID: "%9"
        )
        let observed = ActivePaneRef(
            target: .local,
            sessionName: "shared",
            windowID: "@1",
            paneID: "%1"
        )
        let liveTarget = WorkbenchV2TerminalLiveTarget(
            sessionName: "shared",
            windowID: "@1",
            paneID: "%1"
        )

        XCTAssertTrue(
            WorkbenchV2NavigationSyncResolver.shouldApplyNavigationIntent(
                desiredPaneRef: desired,
                observedPaneRef: observed,
                liveTarget: liveTarget
            ),
            "same-session retarget must keep retrying until the rendered tmux client reports the requested pane"
        )
    }

    func testSkipsRetryOnceObservedRenderedTargetMatchesDesiredPane() {
        let desired = ActivePaneRef(
            target: .local,
            sessionName: "shared",
            windowID: "@2",
            paneID: "%9"
        )
        let observed = ActivePaneRef(
            target: .local,
            sessionName: "shared",
            windowID: "@2",
            paneID: "%9"
        )
        let liveTarget = WorkbenchV2TerminalLiveTarget(
            sessionName: "shared",
            windowID: "@2",
            paneID: "%9"
        )

        XCTAssertFalse(
            WorkbenchV2NavigationSyncResolver.shouldApplyNavigationIntent(
                desiredPaneRef: desired,
                observedPaneRef: observed,
                liveTarget: liveTarget
            ),
            "once rendered-client truth converges, navigation retries must stop"
        )
    }

    func testRequiresRetryWhenRenderedClientRotatesToUnknownLiveTarget() {
        let desired = ActivePaneRef(
            target: .local,
            sessionName: "shared",
            windowID: "@2",
            paneID: "%9"
        )

        XCTAssertTrue(
            WorkbenchV2NavigationSyncResolver.shouldApplyNavigationIntent(
                desiredPaneRef: desired,
                observedPaneRef: nil,
                liveTarget: nil
            ),
            "if the rendered client tty/generation rotates and live target is not yet observed, the app must retry exact-client navigation"
        )
    }
}
