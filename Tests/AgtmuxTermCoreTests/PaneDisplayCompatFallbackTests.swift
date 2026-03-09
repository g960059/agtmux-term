import XCTest
@testable import AgtmuxTermCore

final class PaneDisplayCompatFallbackTests: XCTestCase {
    func testMapsLegacyActivityStateToPrimaryState() {
        XCTAssertEqual(PaneDisplayCompatFallback.primaryState(from: .running), .running)
        XCTAssertEqual(PaneDisplayCompatFallback.primaryState(from: .waitingApproval), .waitingApproval)
        XCTAssertEqual(PaneDisplayCompatFallback.primaryState(from: .waitingInput), .waitingUserInput)
        XCTAssertEqual(PaneDisplayCompatFallback.primaryState(from: .error), .error)
        XCTAssertEqual(PaneDisplayCompatFallback.primaryState(from: .idle), .idle)
        XCTAssertEqual(PaneDisplayCompatFallback.primaryState(from: .unknown), .inactive)
    }

    func testMapsLegacyActivityStateToNeedsAttention() {
        XCTAssertFalse(PaneDisplayCompatFallback.needsAttention(from: .running))
        XCTAssertTrue(PaneDisplayCompatFallback.needsAttention(from: .waitingApproval))
        XCTAssertTrue(PaneDisplayCompatFallback.needsAttention(from: .waitingInput))
        XCTAssertTrue(PaneDisplayCompatFallback.needsAttention(from: .error))
        XCTAssertFalse(PaneDisplayCompatFallback.needsAttention(from: .idle))
        XCTAssertFalse(PaneDisplayCompatFallback.needsAttention(from: .unknown))
    }

    func testManagedFreshnessTextUsesLegacyAgeCollapseButRunningStaysNil() {
        let idlePane = AgtmuxPane(
            source: "local",
            paneId: "%3",
            sessionName: "demo",
            windowId: "@1",
            activityState: .waitingInput,
            presence: .managed,
            provider: .codex,
            currentCmd: "node",
            ageSecs: 18
        )
        let runningPane = AgtmuxPane(
            source: "local",
            paneId: "%4",
            sessionName: "demo",
            windowId: "@1",
            activityState: .running,
            presence: .managed,
            provider: .codex,
            currentCmd: "node",
            ageSecs: 18
        )

        XCTAssertEqual(PaneDisplayCompatFallback.freshnessText(for: idlePane), "18s")
        XCTAssertNil(PaneDisplayCompatFallback.freshnessText(for: runningPane))
        XCTAssertTrue(PaneDisplayCompatFallback.needsAttention(for: idlePane))
        XCTAssertFalse(PaneDisplayCompatFallback.needsAttention(for: runningPane))
    }
}
