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
            PaneRowAccessibility.summary(for: pane, presentation: nil, isSelected: true),
            "selection=selected, presence=managed, provider=codex, primary=waiting_user_input, freshness=12s"
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
            PaneRowAccessibility.summary(for: pane, presentation: nil, isSelected: false),
            "selection=unselected, presence=unmanaged, provider=none, primary=inactive, freshness=none"
        )
    }

    func testPresentationSummaryUsesCompletedIdleAndDegradedFreshness() {
        let pane = AgtmuxPane(
            source: "local",
            paneId: "%12",
            sessionName: "workbench",
            windowId: "@5",
            activityState: .idle,
            presence: .managed,
            provider: .codex,
            currentCmd: "zsh",
            ageSecs: 18
        )
        let snapshot = AgtmuxSyncV3PaneSnapshot(
            sessionName: "workbench",
            windowID: "@5",
            sessionKey: "codex:%12",
            paneID: "%12",
            paneInstanceID: AgtmuxSyncV3PaneInstanceID(
                paneId: "%12",
                generation: 7,
                birthTs: Date(timeIntervalSince1970: 1_778_822_994)
            ),
            provider: .codex,
            presence: .managed,
            agent: AgtmuxSyncV3AgentState(lifecycle: .completed),
            thread: AgtmuxSyncV3ThreadState(
                lifecycle: .idle,
                blocking: .none,
                execution: .none,
                flags: AgtmuxSyncV3ThreadFlags(reviewMode: false, subagentActive: false),
                turn: AgtmuxSyncV3TurnState(
                    outcome: .completed,
                    sequence: 4,
                    startedAt: Date(timeIntervalSince1970: 1_778_822_990),
                    completedAt: Date(timeIntervalSince1970: 1_778_823_000)
                )
            ),
            pendingRequests: [],
            attention: AgtmuxSyncV3AttentionSummary(
                activeKinds: [.completion],
                highestPriority: .completion,
                unresolvedCount: 1,
                generation: 4,
                latestAt: Date(timeIntervalSince1970: 1_778_823_010)
            ),
            freshness: AgtmuxSyncV3FreshnessSummary(
                snapshot: .stale,
                blocking: .fresh,
                execution: .fresh
            ),
            providerRaw: nil,
            updatedAt: Date(timeIntervalSince1970: 1_778_823_000)
        )
        let presentation = PanePresentationState(snapshot: snapshot)

        XCTAssertEqual(
            PaneRowAccessibility.summary(for: pane, presentation: presentation, isSelected: true),
            "selection=selected, presence=managed, provider=codex, primary=completed_idle, freshness=none"
        )
    }
}
