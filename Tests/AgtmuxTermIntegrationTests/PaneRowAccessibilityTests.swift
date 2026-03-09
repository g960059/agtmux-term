import XCTest
@testable import AgtmuxTerm
import AgtmuxTermCore

final class PaneRowAccessibilityTests: XCTestCase {
    func testManagedPaneSummaryIncludesProviderActivityAndFreshness() {
        let pane = AgtmuxPane(
            source: "local",
            paneId: "%7",
            sessionName: "demo",
            windowId: "@1",
            activityState: .waitingInput,
            presence: .managed,
            provider: .codex,
            currentCmd: "node",
            ageSecs: 12
        )

        XCTAssertEqual(
            PaneRowAccessibility.summary(for: pane, isSelected: true),
            "selection=selected, presence=managed, provider=codex, activity=waiting_input, freshness=12s"
        )
    }

    func testUnmanagedRunningPaneSummaryFailsClosedToNoneFreshness() {
        let pane = AgtmuxPane(
            source: "local",
            paneId: "%1",
            sessionName: "demo",
            windowId: "@1",
            activityState: .unknown,
            presence: .unmanaged,
            provider: nil,
            currentCmd: "zsh",
            ageSecs: nil
        )

        XCTAssertEqual(
            PaneRowAccessibility.summary(for: pane, isSelected: false),
            "selection=unselected, presence=unmanaged, provider=none, activity=unknown, freshness=none"
        )
    }
}
